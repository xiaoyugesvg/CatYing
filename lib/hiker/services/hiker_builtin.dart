import 'dart:io';

import 'package:flutter/services.dart' show AssetManifest, rootBundle;

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
/// 注意：UI 上的「可用 / 不可用」是 [HikerSource.usable] 的**静态**判定，
/// 有假阴性（`𝟕𝐌𝐌𝐓𝐕`、`星集Media` 等被判不可用但实际能跑），所以它只作为
/// 标签展示，**不再用来阻止加载**（见 hiker_home_page 的 `_load`）。
///
/// 因此这份清单代表"当前引擎能力的真实边界"，而不是宣传口径。
class HikerBuiltin {
  HikerBuiltin._();

  static const String kAsset = 'assets/hiker/builtin.json';

  /// 随包分发的「海阔 App 自带资源」目录（源文件取自 [hikerView] 的
  /// `app/src/main/assets/`：home.js / inject.js / theme.js / css.js …）。
  ///
  /// 规则里的 `hiker://assets/xxx` 读的就是这里 —— 海阔把它们放在 **App 的
  /// assets** 里，我们这边落地成真实文件（见 [installAssets]）。
  static const String kFilesAsset = 'assets/hiker/files/';

  /// [kFilesAsset] 的兜底清单（枚举 asset 失败时用；正常走 `AssetManifest`）
  static const List<String> kFilesFallback = [
    'home.js',
    'home.json',
    'homeSubView.json',
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

  /// 首次进入模块、仓库为空时自动装一份（让海阔"开箱可用"）
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
      for (final name in await _assetNames()) {
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
  static Future<List<String>> _assetNames() async {
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
