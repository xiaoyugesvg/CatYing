import 'dart:io';

import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/app_log.dart';
import '../models/hiker_source.dart';
import 'hiker_store.dart';

/// 「海阔」**内置源**（随包分发）。
///
/// ── 这份内置清单是怎么来的（重要）────────────────────────────────
/// 不是"挑几个看着像能用的"，而是**实跑筛出来的**：拿一份 115 个源的导出文件，
/// 逐个真跑 `home`，**只有真出内容的才写进** [kAsset]。
/// 其余跑不动的都有明确原因（依赖海阔内置页 `hiker://page/Apollo`、密文模块引用、
/// `pdfa`、需要 WebView 的懒规则等），见「海阔设置 → 说明」。
///
/// 2026-10-16 复核：115 个里实跑能出首页内容的是 **45 个**，已全部收进 [kAsset]
/// （当时只写了 25 个，漏掉 20 个 —— 早期引擎缺 `input`/`KEY` 等能力，误判成跑不动）。
/// 回归记录：45/45 有首页内容。
///
/// 2026-10-16 分三批下架了 31 个（成人导航 / 论坛 / 工具 / 实测「分类内容·搜索·详情·地址」
/// 拿不出东西的）⇒ 当时 **14 个**；已经装过老版本的用户由 [kRetiredIds] 清掉，见 [removeRetired]。
///
/// 2026-10-17 再次用同一份 114 源的导出逐个实跑 `home`：引擎补齐 `prerule` /
/// `initConfig` / `MY_URL` 原文 / `putVar2` 等能力后，能出首页内容的从 50 涨到 **67**。
/// 其中 27 个此前已在清单里，另外 23 个新增 ⇒ 现在 **57 个**。
/// ⚠️ 这批新增的只过了「首页有内容」这一关，没做上面的五项能力审核。
/// （曾一度把 [kRetiredIds] 里那 17 个也恢复进来，用户明确不要「潮流私密屋」这类源，已撤回。）
///
/// 口径说明：**「首页能出内容」不算数**。按「首页 / 分类内容 / 搜索 / 详情页 / 地址」
/// 逐项真跑审核（`assets/nodejs-project/scratch/_audit_caps.mjs`），保留 ≥3 分的；
/// 其中「网页吃瓜」本来被判 2 分，复核发现它第一层就能拿到 m3u8，是判据误伤，已留下。
///
/// 注意：UI 上的「可用 / 不可用」是 [HikerSource.usable] 的**静态**判定，
/// 有假阴性（静态判「不可用」但实际能跑的源），所以它只作为
/// 标签展示，**不再用来阻止加载**（见 hiker_home_page 的 `_load`）。
///
/// 因此这份清单代表"当前引擎能力的真实边界"，而不是宣传口径。
class HikerBuiltin {
  HikerBuiltin._();

  static const String kAsset = 'assets/hiker/builtin.json';

  /// 上次安装过的**内置清单指纹**（见 [installIfNeeded]）
  static const String _kStamp = 'hiker_builtin_stamp_v1';

  /// 已**下架**的内置源 id（`标题\u0001作者`，见 [HikerSource.id]）。
  ///
  /// ── 为什么需要这张表（用户 2026-10-16：「去掉潮流私密屋这个源」）──
  /// [install] 是**upsert**（补缺 + 更新），**从不删** —— 所以老用户升级后
  /// 那个源还留在仓库里，"内置清单里没有了"和"用户看不到"是两回事。
  /// 这里显式列出来，[installIfNeeded] 每次进来顺手清一遍（幂等，很快）。
  ///
  /// ⚠️ 按 id 删会连"用户自己导入的同一条源"一起删 —— 可接受：
  /// id 就是 `标题+作者`，即同一条源；既然 App 侧决定下架，就统一不留。
  static const List<String> kRetiredIds = [
    // 2026-10-16 第一批：成人导航 / 非影视工具 / 论坛
    '潮流私密屋\u0001时尚潮流',
    '查询IP地址\u0001R',
    '吾爱破解\u{1D525}\u0001Hood',
    // 2026-10-16 第二批：用户实测点进去拿不到内容
    '破解APP\u0001小棉袄🌞&永远の明日',
    '模板·Q\u0001发粪涂墙',
    '仙帝美图乐\u0001仙仙帝',
    '发哥专属\u0001发哥',
    '星集Media\u0001不知道叫啥好',
    '比价.拒绝套路\u0001小棉袄🌞',
    '色情导航\u0001Xiaohuihui',
    '集芳阁云搜\u0001',
    '聚涩吧\u0001',
    // 2026-10-16 第三批（宽松口径：实测「首页/分类内容/搜索/详情/地址」≤2 分的）
    '黄色仓库123\u0001FenMei',
    '大哥视频\u0001JiaYQAQ',
    '绿帽社\u0001KFC',
    '✨魔曰✨\u0001Aries',
    '漫小肆\u0001Sky&Guang',
    '新吾爱吃瓜网\u0001集&Aries',
  ];

  /// 清掉 [kRetiredIds] 里列出的源（幂等；不在仓库里的直接跳过）
  static Future<int> removeRetired() async {
    var n = 0;
    try {
      final store = HikerStore.instance;
      if (!store.loaded) await store.load();
      for (final id in kRetiredIds) {
        if (!store.sources.any((s) => s.id == id)) continue;
        await store.remove(id);
        n++;
        AppLog.instance.log(
            '[Hiker] 已移除下架的内置源：${id.split('\u0001').first}');
      }
    } catch (e) {
      AppLog.instance.log('[Hiker] 移除下架内置源失败: $e');
    }
    return n;
  }

  /// 随包分发的「海阔 App 自带资源」目录（源文件取自 [hikerView] 的
  /// `app/src/main/assets/`：home.js / inject.js / theme.js / css.js …）。
  ///
  /// 规则里的 `hiker://assets/xxx` 读的就是这里 —— 海阔把它们放在 **App 的
  /// assets** 里，我们这边落地成真实文件（见 [installAssets]）。
  static const String kFilesAsset = 'assets/hiker/files/';

  /// 随包的**远程 require 预置缓存**（文件名 = 源 URL 的 md5，与引擎
  /// `requireRemoteJs` 的缓存命名完全一致）。
  ///
  /// 来源：海阔真实数据目录的 `libs/`（用户 2026-10-17 提供）。
  /// 这三份是 mistywater/hiker 与 TTImika/hikerF 的公共脚本库 `f`
  /// 以及一个 ghproxy 地址模块；大量源 `$.require('https://…/f')` 依赖它们，
  /// 预置后首次运行/断网也能跑，不必先联网下载。
  static const String kLibsAsset = 'assets/hiker/libs/';

  static const List<String> kLibsFallback = [
    'bf28604c9bb18ed13508828e47c86074.js',
    '64c0dd017f760e1de685e19c79ce6b2b.js',
    '518cf6e05a14ae6e483012118e3910be.js',
  ];

  /// [kFilesAsset] 的兜底清单（枚举 asset 失败时用；正常走 `AssetManifest`）
  static const List<String> kFilesFallback = [
    'home.js',
    'home.json',
    'homeSubView.json',
    // 「我的主页」模板（assets/home.js）依赖的本地配置；源自用户导出的
    // 海阔数据目录 `rules/js/NewPlanConfigFile.js`（内容就是 JSON）。
    'NewPlanConfigFile.json',
    'inject.js',
    'Hikerurl.js',
    'empty.js',
    'mute.js',
    'css.js',
    'translate.js',
    'theme.js',
  ];

  static List<HikerSource>? _cache;

  /// 读取内置源（带内存缓存；资产缺失/损坏时返回空表，不影响其它功能）
  static Future<List<HikerSource>> load() async {
    final c = _cache;
    if (c != null) return c;
    try {
      final raw = await rootBundle.loadString(kAsset);
      final list = HikerSource.parseList(raw);
      _cache = list;
      return list;
    } catch (e) {
      AppLog.instance.log('[Hiker] 读取内置源失败: $e');
      _cache = const [];
      return const [];
    }
  }

  static Future<int> count() async => (await load()).length;

  /// 安装（或补齐/更新）内置源。
  ///
  /// 走 [HikerStore.importSources] 的 upsert 语义：已存在的按 id 更新、
  /// 缺的追加 —— 所以"手滑删了一个"再点一次就能补回来，也不会碰用户自己导入的源。
  static Future<(int, int, int)> install() async {
    final list = await load();
    if (list.isEmpty) return (0, 0, HikerStore.instance.sources.length);
    return HikerStore.instance.importSources(list);
  }

  /// 首次进入模块、仓库为空时自动装一份（让海阔"开箱可用"）。
  ///
  /// ⚠️ 只有"仓库为空"是不够的 —— 老用户升级后仓库**不空**（已有旧的 25 个），
  /// 于是新增的内置源永远不进来（用户 2026-10-16 就是踩了这个：文件里明明 45 个，
  /// 界面上还是 25 个）。所以改成按**清单指纹**判断：指纹变了就补装一次。
  ///
  /// 指纹存 prefs；[install] 是 upsert 语义（补缺 + 更新，不动用户自己导入的源）。
  static Future<void> installIfNeeded() async {
    final list = await load();
    if (list.isEmpty) return;
    // 先清下架源：**要放在指纹早退之前** —— 否则"清单没变"的老用户永远清不掉
    await removeRetired();
    final stamp = _fingerprint(list);
    String last = '';
    try {
      final prefs = await SharedPreferences.getInstance();
      last = prefs.getString(_kStamp) ?? '';
      // 指纹一致 ⇒ 清单没变：只在"从来没装过且仓库为空"时补一次
      if (last == stamp && HikerStore.instance.sources.isNotEmpty) return;
      if (last == stamp) {
        // 指纹一致 + 仓库为空 —— 用户是**主动清空**的，尊重它，不要自动复活
        AppLog.instance.log('[Hiker] 内置源已被清空且清单未变，跳过自动安装');
        return;
      }
      final (added, updated, total) = await install();
      await prefs.setString(_kStamp, stamp);
      if (added > 0 || updated > 0) {
        AppLog.instance.log(
            '[Hiker] 内置清单变化 → 补装 $added 个、更新 $updated 个（共 $total 个源）');
      }
    } catch (e) {
      AppLog.instance.log('[Hiker] 内置源自动补装失败: $e');
    }
  }

  /// 内置清单指纹：条数 + 每个源的 **id + 规则内容** 的有序 hash。
  ///
  /// ⚠️ 必须把规则正文也算进去（2026-10-17）：只算 id 的话，改了内置源的规则
  /// （例如 XO 改成自动取流）指纹不变 ⇒ [installIfNeeded] 直接早退，
  /// 老用户的仓库里永远还是旧规则，等于白改。
  /// 用确定性折叠而不是 `String.hashCode`（后者不保证跨进程稳定）。
  static String _fingerprint(List<HikerSource> list) {
    final ids = list
        .map((s) => '${s.id}\u0002${s.findRule}\u0002${s.detailFindRule}')
        .toList()
      ..sort();
    var h = 17;
    for (final c in ids.join('\u0001').codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return '${list.length}-$h';
  }

  /// 兼容旧调用点（等价于"只在空仓库时装一次"）
  @Deprecated('用 installIfNeeded：老用户升级后也需要补装新增的内置源')
  static Future<void> installIfEmpty() async {
    if (HikerStore.instance.sources.isNotEmpty) return;
    final (added, _, total) = await install();
    if (added > 0) {
      AppLog.instance.log('[Hiker] 已自动安装内置源 $added 个（共 $total 个）');
    }
  }

  /// 把 [kFilesAsset] 铺到 `<Documents>/hiker/builtin/`，
  /// 让规则里的 `hiker://assets/xxx` 能真的读到内容。
  ///
  /// ── 为什么要落地成真实文件 ────────────────────────────────────
  /// 规则是在 **Node** 里跑的，那边读文件走 `fs.readFileSync`，**拿不到
  /// Flutter 的 asset bundle**；而 iOS 上 asset 打包在 `Runner.app` 里、
  /// 路径不固定。所以进模块时把它释放到 Documents 下，Node 按 `assetsDir` 读。
  ///
  /// 幂等：目标已存在且**大小一致**就跳过（升级换包后大小变了会自动刷新）；
  /// [force] 用于「设置 → 释放内置资源」强制覆盖。
  static Future<int> installAssets({bool force = false}) async {
    var n = 0;
    try {
      final root = await HikerStore.rootDir();
      if (root == null) return 0;
      final dir = Directory('${root.path}/builtin');
      if (!await dir.exists()) await dir.create(recursive: true);
      for (final name in await assetNames()) {
        try {
          final data = await rootBundle.load('$kFilesAsset$name');
          final bytes = data.buffer
              .asUint8List(data.offsetInBytes, data.lengthInBytes);
          final f = File('${dir.path}/$name');
          if (!force && await f.exists() && await f.length() == bytes.length) {
            continue;
          }
          await f.writeAsBytes(bytes, flush: true);
          n++;
        } catch (e) {
          AppLog.instance.log('[Hiker] 释放自带资源 $name 失败: $e');
        }
      }
      if (n > 0) AppLog.instance.log('[Hiker] 已释放自带资源 $n 个 → ${dir.path}');
    } catch (e) {
      AppLog.instance.log('[Hiker] 释放自带资源失败: $e');
    }
    return n;
  }

  /// 把随包的远程 require 预置缓存铺到 `<Documents>/hiker/files/libs/`。
  ///
  /// 引擎的 `rc()/requireCache()` 缓存键就是「URL 的 md5 + .js」，
  /// 与这里的文件名完全一致；TTL 按 **mtime** 算（默认 24h），
  /// 所以每次进模块都刷新一下 mtime，避免隔天断网时缓存被判过期。
  ///
  /// 幂等：内容大小一致就只 touch；升级换包后大小变了会覆盖。
  static Future<int> installRequireLibs({bool force = false}) async {
    var n = 0;
    try {
      final root = await filesDir();
      if (root.isEmpty) return 0;
      final dir = Directory('$root/libs');
      if (!await dir.exists()) await dir.create(recursive: true);
      for (final name in await libAssetNames()) {
        // 只接受 md5.js，防目录里混进别的东西被当成缓存
        if (!RegExp(r'^[0-9a-f]{32}\.js$').hasMatch(name)) continue;
        try {
          final data = await rootBundle.load('$kLibsAsset$name');
          final bytes = data.buffer
              .asUint8List(data.offsetInBytes, data.lengthInBytes);
          final f = File('${dir.path}/$name');
          final same = !force &&
              await f.exists() &&
              await f.length() == bytes.length;
          if (!same) {
            await f.writeAsBytes(bytes, flush: true);
            n++;
          }
          // 刷新 TTL（rc() 看 mtime）
          try {
            await f.setLastModified(DateTime.now());
          } catch (_) {/* 个别文件系统不支持，忽略 */}
        } catch (e) {
          AppLog.instance.log('[Hiker] 释放预置 require 缓存 $name 失败: $e');
        }
      }
      if (n > 0) {
        AppLog.instance.log('[Hiker] 已释放预置 require 缓存 $n 个 → ${dir.path}');
      }
    } catch (e) {
      AppLog.instance.log('[Hiker] 释放预置 require 缓存失败: $e');
    }
    return n;
  }

  /// 枚举 [kLibsAsset] 下的文件名（AssetManifest 不可用时退回内置清单）
  static Future<List<String>> libAssetNames() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final names = manifest
          .listAssets()
          .where((k) => k.startsWith(kLibsAsset))
          .map((k) => k.substring(kLibsAsset.length))
          .where((n) => n.isNotEmpty && !n.contains('/'))
          .toList();
      if (names.isNotEmpty) return names;
    } catch (e) {
      AppLog.instance.log('[Hiker] 枚举预置 require 缓存失败，退回内置清单: $e');
    }
    return kLibsFallback;
  }

  /// `hiker://assets/*` 的**落地目录**（Node 侧 `assetsDir`）
  static Future<String> assetsDir() async {
    final root = await HikerStore.rootDir();
    return root == null ? '' : '${root.path}/builtin';
  }

  /// `hiker://files/*` 的**落地目录**（Node 侧 `filesDir`，规则可读写）
  static Future<String> filesDir() async {
    final root = await HikerStore.rootDir();
    return root == null ? '' : '${root.path}/files';
  }

  /// 枚举 [kFilesAsset] 下的文件名。
  /// 走 [AssetManifest] 自动列举（以后往目录里加文件不用改代码），
  /// 该 API 不可用/被裁剪时退回 [kFilesFallback]。
  ///
  /// 公开给「源诊断」用：规则里 `hiker://assets/x.js` 能命中的就不算缺。
  static Future<List<String>> assetNames() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final names = manifest
          .listAssets()
          .where((k) => k.startsWith(kFilesAsset))
          .map((k) => k.substring(kFilesAsset.length))
          .where((n) => n.isNotEmpty && !n.contains('/'))
          .toList();
      if (names.isNotEmpty) return names;
    } catch (e) {
      AppLog.instance.log('[Hiker] 枚举自带资源失败，退回内置清单: $e');
    }
    return kFilesFallback;
  }
}
