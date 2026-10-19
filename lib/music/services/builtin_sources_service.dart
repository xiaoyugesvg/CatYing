import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/third_party_source.dart';
import 'plugin_script_cache.dart';

/// 内置音源注册 + 自动更新服务。
///
/// ── 这是什么 ──────────────────────────────────────────────────
/// App 出厂自带一批**内置音源**（随包打包），让用户"装上就有源"，不用再
/// 到处找源码。分两个生态：
///
///   · **洛雪源**（kind='script'）
///     来源：`https://github.com/pdone/lx-music-source`（10 个主流源）
///     assets 目录：`assets/music/lx/*.js`
///
///   · **MusicFree 插件**（kind='musicfree'）
///     来源：`https://hebijunge.github.io/musicfree-plugins/plugins.json`
///     assets 目录：`assets/music/musicfree/*.plugin.js` + `.index.json`
///
/// ── 自动更新机制 ─────────────────────────────────────────────
///  · 启动时（[init]）先注册内置源（如果没有 / 用户删过则自动补回）
///  · 随后异步拉远端索引对比版本，有新版本则下载覆盖到本地并更新 Store
///  · 更新失败**静默**（不影响使用内置版本），只写日志
///
/// ── 与用户源的关系 ───────────────────────────────────────────
/// 内置源直接注入 `ThirdPartySourceStore`，`isBuiltin=true`。
/// 用户可以在管理页**编辑**（改配置）、**删除**（从列表移除）。
/// 删除的内置源在 App 重建（[init]）时会**自动重新注册并启用** ——
/// 这是"内置"的语义：删了也删不干净，重建就回来（和影视/阅读内置源一致）。
/// 但用户**禁用**的会保留禁用状态（尊重用户选择）。
class BuiltinSourcesService {
  BuiltinSourcesService._();
  static final BuiltinSourcesService instance = BuiltinSourcesService._();

  final _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 20),
    ),
  );

  bool _updating = false;

  /// 是否有"内置源"这个概念需要展示（管理页据此显示内置源区块提示）
  bool get hasBuiltins => true;

  /// 加载内置源并注册到 Store。
  ///
  /// 内置语义：**源始终应该在列表里**。所以每次启动都检查一遍，
  /// **缺失的**（首次启动 / 被用户删除）自动补回并启用；
  /// **已存在的**（用户编辑过脚本 / 禁用过开关）保持不动 ——
  /// 不覆盖用户的修改，也不把用户关掉的开关重新打开。
  /// [force] 为 true 时无条件用出厂版覆盖重写全部内置源（"恢复默认"）。
  Future<void> init({bool force = false}) async {
    // ✅ 用户 2026-10-07：**下架名单**里的 MusicFree 源全部去掉 ——
    //   第一批是名称带 dj/DJ 的；第二批是脚本里 `require('cheerio')` 的 6 个
    //   （相声评书 / 水晶舞曲 / 172Mix / 黑色音频 / 好听轻音乐 / 电音阁）。
    //   已有设备上 store 里可能还留着（init 只补"缺失"、不删"已存在"），
    //   所以每次启动先显式清一遍 ✓
    await _purgeBlockedMusicFreeSources();
    final lx = await _loadLxSources();
    final mf = await _loadMusicFreeSources();
    final all = [...lx, ...mf];
    if (all.isEmpty) return;

    final store = ThirdPartySourceStore.instance;
    if (force) {
      // 无条件写入：全删旧内置源后重加出厂版（用户"恢复默认"）
      final kept = store.all.where((s) => !s.isBuiltin).toList();
      await store.replaceAll([...kept, ...all]);
    } else {
      // 只补"缺失"的内置源；已存在的保留（含用户编辑/禁用状态）
      final need = all.where((s) => store.byId(s.id) == null).toList();
      if (need.isNotEmpty) {
        await store.addAll(need);
      }
    }
    // ✅ 2026-10-19：把**实测失效**的内置源关掉。
    //   init 只补"缺失"的、从不改"已存在"的 ⇒ 老设备里那些死源仍是启用状态，
    //   每次播放都先撞一次死源（试播超时 + 最后失败）。这里显式关一遍 ✓
    await _disableDeadBuiltinSources(force: force);
  }

  /// 异步检查远端更新（洛雪 + MusicFree）。无网络/失败时静默。
  ///
  /// ── 🔴 它现在还负责"**补齐缺失的内置插件**"（用户 2026 要求）──────
  /// 用户原话：「这些源全部要加进去」（指的是远端 `plugins.json` 里那 50 个）。
  ///
  /// 原实现只"升级已注册的"，所以随包没带的 40 个**永远不会出现** ✗
  /// 现在这个入口也会**注册缺失的**（见 [_updateMusicFreeSources]）。
  ///
  /// ⚠️ 调用方（`SettingsStore.init`）是 `unawaited(...)` 调的 ——
  ///    **不能**在这里做重活到阻塞 UI 的程度。下载总量 ~4 MB
  ///    但要落盘 + 全量重写 prefs，所以用 [_mfMaxDownloadsPerRun] 限流。
  Future<void> checkForUpdates({bool force = false}) async {
    if (_updating) return;
    _updating = true;
    try {
      await _updateLxSources();
      // `force`（"恢复默认"）时允许再跑一次补齐
      if (force) _backfilled = false;
      _forceBackfill = force;
      await _updateMusicFreeSources();
      _backfilled = true;
    } catch (e) {
      debugPrint('[BuiltinSources] 更新失败: $e');
    } finally {
      _updating = false;
    }
  }

  /// 当前已注册的 MusicFree 源数量（管理页/日志用）
  int get registeredMusicFreeCount =>
      ThirdPartySourceStore.instance.all.where((s) => s.isMusicFree).length;

  // ────────────────────────────────────────────────────────────
  // 洛雪源
  // ────────────────────────────────────────────────────────────

  /// 洛雪源清单（文件名 → 显示名），与 `assets/music/lx/` 目录一一对应，
  /// 也是远端拉取的相对路径。顺序即"用户看到/尝试"的优先级。
  /// 洛雪源远端更新基地址。用 ghproxy 加速前缀，国内网络能直连。
  /// 仓库：https://github.com/pdone/lx-music-source
  static const _lxRawBase =
      'https://ghproxy.net/raw.githubusercontent.com/pdone/lx-music-source/main';

  static const _lxCandidates = <({String path, String name})>[
    (path: 'sixyin', name: 'SixYin'),
    (path: 'huibq', name: 'Huibq'),
    (path: 'flower', name: 'Flower'),
    (path: 'lx', name: 'LX'),
    (path: 'changqing', name: 'ChangQing'),
    (path: 'huanyin', name: 'HuanYin'),
    (path: 'ikun', name: 'ikun'),
    (path: 'grass', name: 'Grass'),
    (path: 'juhe', name: 'JuheApi'),
    (path: 'qdy', name: 'QDY'),
    // ✅ 用户 2026-10-07 提供的两个洛雪(lx)音源，随包内置 ✓
    //   两者都用 `globalThis.lx.EVENT_NAMES`（Node 求值实测确认是 lx 格式，
    //   不是 MusicFree 插件）⇒ 走本列表而非 MusicFree 索引 ✓
    (path: 'dujia', name: '独家音源'),
    (path: 'quandouyao', name: '全豆要聚合'),
    // ✅ 2026-10-11 Node 沙箱实测验真（真实 HTTP + Range 首包 magic bytes 判定）：
    //   stellarwave 聚合源 tx 通道连续返回 QQ 官方 CDN 真 MP3（206/audio/mpeg）；
    //   HYWMusic 经自建 API 跳念心链路可出真 MP3（206，响应偶发偏慢，置后作备选）。
    //   同批送测的长青"修复版"(haitangw 全 404)、非常刀 v5(多平台全后端失败)、
    //   墨澜(返回 .mgg 加密格式普通播放器解不了) 均不可用，未内置。
    (path: 'stellarwave', name: 'StellarWave星澜'),
    (path: 'hywmusic', name: 'HYWMusic'),
  ];

  /// **失效源名单**（洛雪源 path）：后端已停服 ⇒ 注册时**默认禁用**，
  /// 避免用户误选、也避免每次试播先撞一次死源。
  ///
  /// 实测证据（2026-10-19，逐个打后端接口）：
  ///   · `stellarwave` —— 唯一后端 `ffapi.cn` 返回
  ///       `{"code":-1,"msg":"接口已经关闭！"}`（原注释里的"主用"源）
  ///   · `huanyin`     —— `music-dl.sayqz.com` TLS 握手失败；
  ///       `api.xcvts.cn` 咪咕搜索返回 `code:502 咪咕搜索接口均不可用`
  ///   · `ikun`        —— `api.ikunshare.com` TLS 连接失败
  ///   · `huibq`       —— `lxmusicapi.onrender.com` 503（Render 免费实例已下线）
  ///
  /// ⚠️ 仍然可用的源**不在此列**、保持启用：
  ///   `hywmusic`（`103.79.184.97` 实测 tx/wy 均返回真直链，卡密 200）
  static const Set<String> _deadLxPaths = {
    'stellarwave',
    'huanyin',
    'ikun',
    'huibq',
  };

  /// 命中失效源名单？（按洛雪源 path 判断）
  static bool _isDeadLx(String path) => _deadLxPaths.contains(path);

  Future<List<ThirdPartySource>> _loadLxSources() async {
    final out = <ThirdPartySource>[];
    for (final c in _lxCandidates) {
      try {
        final script = await rootBundle
            .loadString('assets/music/lx/${c.path}.js');
        if (script.trim().isEmpty) continue;
        out.add(ThirdPartySource(
          id: 'builtin_lx_${c.path}',
          name: c.name,
          kind: 'script',
          template: '',
          script: script,
          // ✅ 2026-10-19：失效源（后端已停服）默认**禁用** ⇒ 不参与试播
          enabled: !_isDeadLx(c.path),
          isBuiltin: true,
          updateUrl: '$_lxRawBase/${c.path}/latest.js',
        ));
      } catch (e) {
        debugPrint('[BuiltinSources] 加载洛雪源 ${c.name} 失败: $e');
      }
    }
    return out;
  }

  /// 从远端更新每个洛雪源到最新脚本（替换 script 内容）。
  Future<void> _updateLxSources() async {
    for (final c in _lxCandidates) {
      try {
        final resp =
            await _dio.get('$_lxRawBase/${c.path}/latest.js');
        final script = resp.data is String
            ? resp.data as String
            : (resp.data?.toString() ?? '');
        if (script.trim().isEmpty || script.length > 512 * 1024) continue;
        final store = ThirdPartySourceStore.instance;
        final cur = store.byId('builtin_lx_${c.path}');
        if (cur == null) continue;
        await store.upsert(cur.copyWith(script: script));
      } catch (e) {
        debugPrint('[BuiltinSources] 更新洛雪源 ${c.name} 失败: $e');
      }
    }
  }

  // ────────────────────────────────────────────────────────────
  // MusicFree 源
  // ────────────────────────────────────────────────────────────

  static const _mfIndexAsset = 'assets/music/musicfree/.index.json';
  static const _mfIndexRemote =
      'https://hebijunge.github.io/musicfree-plugins/plugins.json';
  static const _mfPluginDir = 'assets/music/musicfree/';

  /// 单个插件脚本的**大小上限**（超过就跳过，防被塞垃圾）
  ///
  /// 实测最大的 `agg-source.plugin` 约 1.7 MB，所以 2 MB 足够；
  /// 原来是 512 KB —— 那个值会**误杀** agg 这类大插件。
  static const _mfMaxScriptBytes = 2 * 1024 * 1024;

  /// 单次 [checkForUpdates] 最多**新增**多少个插件。
  ///
  /// 远端索引有 50 个（总计约 4.2 MB），一次全下 + 全量重写 prefs 会拖慢
  /// 启动。40 这个值让"首次安装"**一次就基本补齐**（随包带 10 个 → 补 40 个
  /// = 50 个），同时留一点余量给"以后索引继续变长"的情况。
  /// 没补完的**下次启动继续**（下好的已落文件缓存，不重复下）。
  static const _mfMaxDownloadsPerRun = 40;

  /// 是否已经跑过一次"补齐全量插件"（避免同一进程内重复跑）
  bool _backfilled = false;

  /// 本轮是否强制补齐（"恢复默认" / 用户手动点检查更新时置 true）
  bool _forceBackfill = false;

  /// 读取 assets 里的 MusicFree 插件索引（.index.json）。
  Future<List<Map<String, String>>> _mfIndexFromAssets() async {
    try {
      final raw = await rootBundle.loadString(_mfIndexAsset);
      return _parseMfIndex(raw);
    } catch (e) {
      debugPrint('[BuiltinSources] 读取 MusicFree 索引失败: $e');
      return const [];
    }
  }

  List<Map<String, String>> _parseMfIndex(String raw) {
    try {
      final obj = jsonDecode(raw);
      final plugins = (obj as Map)['plugins'];
      if (plugins is! List) return const [];
      return plugins
          .map((e) => e is Map ? e.cast<String, dynamic>() : null)
          .whereType<Map<String, dynamic>>()
          .map((e) => {
                'name': (e['name'] ?? '').toString(),
                'url': (e['url'] ?? '').toString(),
                'version': (e['version'] ?? '').toString(),
              })
          .where((e) => e['url']!.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('[BuiltinSources] 解析 MusicFree 索引失败: $e');
      return const [];
    }
  }

  /// 从**本地**（assets / 文件缓存）加载 MusicFree 内置源。
  ///
  /// ── 🔴 这里**不做网络下载**（重要）─────────────────────────────
  /// 启动路径上必须快：网络下载全部交给 [checkForUpdates]（异步、不 await）。
  /// 所以这里只解决"**已经拿到手的**脚本怎么变成内置源"：
  ///   ① 随包 `assets/music/musicfree/<file>` —— 出厂自带的
  ///   ② `PluginScriptCache` 文件缓存 —— 之前 [checkForUpdates] 下过并落盘的
  ///
  /// ⚠️ 索引取的是 **assets 里的 `.index.json`**。
  ///    远端索引（50 个）在 [checkForUpdates] 里处理 —— 那里才能联网。
  Future<List<ThirdPartySource>> _loadMusicFreeSources() async {
    final index = await _mfIndexFromAssets();
    final out = <ThirdPartySource>[];
    for (final entry in index) {
      final name = entry['name']!;
      // ✅ 用户 2026-10-07：**下架名单**里的源不注册（远端索引也走这道闸）
      //   第一批 dj/DJ；第二批 require('cheerio') 的 6 个 ✓
      if (_isBlockedName(name)) continue;
      final url = entry['url']!;
      final fileName = _fileNameFromUrl(url);
      // 稳定 id：用插件文件名作为 id 的一部分
      final id = 'builtin_mf_$fileName';
      try {
        // ① 先看随包 assets；② 再回落到文件缓存
        String? script;
        try {
          script = await rootBundle.loadString('$_mfPluginDir$fileName');
        } catch (_) {
          script = null;
        }
        script ??= await PluginScriptCache.instance.read(fileName);
        if (script != null && script.trim().isNotEmpty) {
          out.add(ThirdPartySource(
            id: id,
            name: name,
            kind: 'musicfree',
            template: '',
            script: script,
            enabled: true,
            isBuiltin: true,
            updateUrl: url,
          ));
        }
      } catch (e) {
        debugPrint('[BuiltinSources] 加载 MusicFree $name 失败: $e');
      }
    }
    return out;
  }

  /// 拉远端索引 + 下载脚本，**升级已有插件、并注册缺失的插件**。
  ///
  /// ── 🔴 原实现的缺口（用户 2026 要求"这些源全部要加进去"）──────────
  /// 原来这里只做"**升级**"：
  /// ```dart
  /// final cur = store.byId(id);
  /// if (cur == null) continue;   // 本地没有，不拉  ← 就是这一行
  /// ```
  /// 于是 `plugins.json` 里那 **50 个**插件，
  /// **只有随包 assets 里的 10 个**会被注册，其余 40 个**永远不会出现** ——
  /// 用户在管理页看到的永远是 10 个，而不是远端索引的 50 个 ✗
  ///（`_loadMusicFreeSources` 里那句注释"内容缺失时稍后在线拉"，
  ///  实际上"稍后"从未发生 —— 没有任何代码在做这件事）
  ///
  /// ── 现在的行为 ─────────────────────────────────────────────────
  ///   · **已有**（store 里有该 id）→ 拉最新脚本覆盖（原逻辑，保留）
  ///   · **缺失**（store 里没有）   → 下载脚本并**新增**一个内置源
  ///
  /// ⚠️ **不覆盖用户改动**：只对"store 里不存在"的 id 做新增；
  ///    已存在的仍走原来的 `copyWith(script:)` 升级路径 ——
  ///    也就是说用户改过的名字/开关/音质不会被这次批量注册冲掉。
  ///
  /// ⚠️ **单次上限**（[_mfMaxDownloadsPerRun]）：50 个插件的"首次全量"
  ///    要下 ~4 MB。全放在一次调用里、又紧接着下完立刻 `store.upsert`
  ///    （每次都全量重写 prefs JSON）会拖慢启动。所以一次最多补这么多，
  ///    剩下的**下次启动继续补**（已下好的会落进文件缓存，不重复下）。
  Future<void> _updateMusicFreeSources() async {
    List<Map<String, String>> remoteIndex;
    try {
      final resp = await _dio.get(_mfIndexRemote);
      remoteIndex = _parseMfIndex(resp.data?.toString() ?? '');
    } catch (e) {
      debugPrint('[BuiltinSources] 拉远端 MusicFree 索引失败: $e');
      return;
    }
    if (remoteIndex.isEmpty) return;

    final store = ThirdPartySourceStore.instance;
    // 本轮的"新增"先攒在内存里，最后**一次性** addAll ——
    // 每个都单独 upsert 的话，prefs 那份大 JSON 会被反复读+写，很浪费。
    final added = <ThirdPartySource>[];
    var downloads = 0;

    for (final entry in remoteIndex) {
      final name = entry['name']!;
      // ✅ 用户 2026-10-07：**下架名单**里的源既不升级也不新增
      //   （dj/DJ 一批 + require('cheerio') 一批）✓
      if (_isBlockedName(name)) continue;
      final url = entry['url']!;
      final fileName = _fileNameFromUrl(url);
      final id = 'builtin_mf_$fileName';
      final cur = store.byId(id);

      // ── 情况 A：已存在 → 拉新版本覆盖（保持既有语义）──────────────
      if (cur != null) {
        try {
          final resp = await _dio.get(url);
          final script = resp.data is String
              ? resp.data as String
              : (resp.data?.toString() ?? '');
          if (script.trim().isEmpty || script.length > _mfMaxScriptBytes) {
            continue;
          }
          // 顺手落一份文件缓存（下次冷启动读文件比读 prefs 快）
          await PluginScriptCache.instance.write(fileName, script);
          store.upsert(cur.copyWith(script: script));
        } catch (e) {
          debugPrint('[BuiltinSources] 更新 MusicFree $name 失败: $e');
        }
        continue;
      }

      // ── 情况 B：缺失 → 下载并**注册**（这就是原来缺的那一步）────────
      //
      // ⚠️ 如果本轮已经补齐过（`_backfilled`）且不是 force，就跳过 ——
      //    否则每次进设置页都重新扫一遍 50 个索引项（虽然后面会命中
      //    文件缓存、不会真下载，但没必要反复走这个循环）。
      if (_backfilled && !_forceBackfill) continue;
      if (downloads >= _mfMaxDownloadsPerRun) continue;
      try {
        // 先看文件缓存（上次下过、但 store 被用户删过的情况）
        var script = await PluginScriptCache.instance.read(fileName);
        if (script == null) {
          final resp = await _dio.get(url);
          script = resp.data is String
              ? resp.data as String
              : (resp.data?.toString() ?? '');
          if (script.trim().isEmpty || script.length > _mfMaxScriptBytes) {
            continue;
          }
          await PluginScriptCache.instance.write(fileName, script);
        }
        downloads++;
        added.add(ThirdPartySource(
          id: id,
          name: name,
          kind: 'musicfree',
          template: '',
          script: script,
          enabled: true,
          isBuiltin: true,
          updateUrl: url,
        ));
      } catch (e) {
        debugPrint('[BuiltinSources] 新增 MusicFree $name 失败: $e');
      }
    }

    if (added.isNotEmpty) {
      await store.addAll(added);
      debugPrint('[BuiltinSources] 新增 MusicFree 内置源 ${added.length} 个'
          '（本轮共处理 ${remoteIndex.length} 个索引项）');
    }
  }

  static String _fileNameFromUrl(String url) {
    final seg = Uri.tryParse(url)?.pathSegments ?? const [];
    return seg.isEmpty ? 'unknown' : seg.last;
  }

  /// **下架名单**：这些 MusicFree 源不再内置、也不再注册。
  ///
  /// 用户 2026-10-07 分两批下架：
  ///   · 第一批 —— 名称带 `dj/DJ` 的 DJ 类音源（`DJ多多 / 火龙DJ / djuu DJ /
  ///     SpaceDJ …`）。判据按**名称**而不是 url：像 `水晶舞曲` 当时 url 含
  ///     `dj14` 但名字里没有，所以那一轮保留了下来 ✓
  ///   · 第二批（本轮）—— 脚本里写 `const cheerio = require('cheerio')` 的
  ///     6 个源：`相声评书 / 水晶舞曲 / 172Mix / 黑色音频 / 好听轻音乐 /
  ///     电音阁`。这 6 个都靠 cheerio 解析 HTML 页面，按要求**一并去掉** ✓
  static const Set<String> _blockedNames = {
    '相声评书',
    '水晶舞曲',
    '172Mix',
    '黑色音频',
    '好听轻音乐',
    '电音阁',
  };

  /// 命中下架名单？`dj/DJ` 按包含判断（大小写不敏感），其余按**精确名称**判断。
  static bool _isBlockedName(String name) {
    if (name.toLowerCase().contains('dj')) return true;
    return _blockedNames.contains(name.trim());
  }

  /// 清掉**已经注册过**的下架 MusicFree 内置源 + 它们的脚本文件缓存。
  ///
  /// 为什么必须单独做这一步：上面的过滤只能挡住"**之后**注册"的源 ✗，
  /// 而已经装过 App 的设备里那些 DJ 源**还在 store 里** ✓
  /// （`init` 只为"缺失的"补源 ✓、不会删除"已存在的" ✗）
  /// ⇒ 不显式删一次，用户删不干净 ✓。
  Future<void> _purgeBlockedMusicFreeSources() async {
    try {
      final store = ThirdPartySourceStore.instance;
      final doomed = store.all
          .where((s) => s.isMusicFree && _isBlockedName(s.name))
          .toList();
      if (doomed.isEmpty) return;
      for (final s in doomed) {
        // 顺带删掉落盘的插件脚本（否则文件缓存会一直留着）
        final url = s.updateUrl.trim();
        if (url.isNotEmpty) {
          await PluginScriptCache.instance.delete(_fileNameFromUrl(url));
        }
        await store.remove(s.id);
      }
      debugPrint('[BuiltinSources] 已移除下架 MusicFree 源 ${doomed.length} 个');
    } catch (e) {
      debugPrint('[BuiltinSources] 移除下架 MusicFree 源失败: $e');
    }
  }

  /// 把已安装设备上遗留的**失效内置源**关掉（只关一次）。
  ///
  /// 为什么需要：`init` 只补"缺失"的源、**从不改"已存在"的** ⇒
  /// 老设备里 stellarwave / huanyin / ikun / huibq 仍是 `enabled: true`，
  /// 每次播放都会先撞一次死源（试播超时 + 最后才失败）✗
  ///
  /// ⚠️ 用 prefs 旗标保证**只关一次**：之后用户若手动把它们重新打开
  ///    （比如想再试一次源作者有没有修好），下次启动**不会**又被关掉 ✓
  ///
  /// [force] = true（"恢复默认"）时忽略旗标，关完再把旗标写回 true。
  static const _deadDisabledFlagKey = 'music.builtinDeadDisabled.v1';

  Future<void> _disableDeadBuiltinSources({bool force = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!force && prefs.getBool(_deadDisabledFlagKey) == true) return;
      final store = ThirdPartySourceStore.instance;
      var disabled = 0;
      for (final path in _deadLxPaths) {
        final id = 'builtin_lx_$path';
        final cur = store.byId(id);
        if (cur == null || !cur.enabled) continue;
        await store.setEnabled(id, false);
        disabled++;
      }
      await prefs.setBool(_deadDisabledFlagKey, true);
      if (disabled > 0) {
        debugPrint('[BuiltinSources] 已默认禁用失效内置源 $disabled 个');
      }
    } catch (e) {
      debugPrint('[BuiltinSources] 禁用失效内置源失败: $e');
    }
  }
}
