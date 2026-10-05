import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/third_party_source.dart';

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
  }

  /// 异步检查远端更新（洛雪 + MusicFree）。无网络/失败时静默。
  Future<void> checkForUpdates() async {
    if (_updating) return;
    _updating = true;
    try {
      await _updateLxSources();
      await _updateMusicFreeSources();
    } catch (e) {
      debugPrint('[BuiltinSources] 更新失败: $e');
    } finally {
      _updating = false;
    }
  }

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
  ];

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
          enabled: true,
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

  /// 从远端索引 + 对应插件脚本，加载/更新 MusicFree 内置源。
  Future<List<ThirdPartySource>> _loadMusicFreeSources() async {
    final index = await _mfIndexFromAssets();
    final out = <ThirdPartySource>[];
    for (final entry in index) {
      final name = entry['name']!;
      final url = entry['url']!;
      final fileName = _fileNameFromUrl(url);
      // 稳定 id：用插件文件名作为 id 的一部分
      final id = 'builtin_mf_$fileName';
      try {
        // 从 assets 读插件内容；没有则跳过（用索引注册但内容缺失时稍后在线拉）
        String? script;
        try {
          script = await rootBundle.loadString('$_mfPluginDir$fileName');
        } catch (_) {
          script = null;
        }
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

  /// 从远端索引对比并更新已内置的 MusicFree 插件版本。
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
    // 远端索引里有，且本 App 已注册过该 id → 拉新脚本替换
    for (final entry in remoteIndex) {
      final fileName = _fileNameFromUrl(entry['url']!);
      final id = 'builtin_mf_$fileName';
      final cur = store.byId(id);
      if (cur == null) continue; // 本地没有，不拉
      try {
        final resp = await _dio.get(entry['url']!);
        final script = resp.data is String
            ? resp.data as String
            : (resp.data?.toString() ?? '');
        if (script.trim().isEmpty || script.length > 512 * 1024) continue;
        store.upsert(cur.copyWith(script: script));
      } catch (e) {
        debugPrint('[BuiltinSources] 更新 MusicFree ${entry['name']} 失败: $e');
      }
    }
  }

  static String _fileNameFromUrl(String url) {
    final seg = Uri.tryParse(url)?.pathSegments ?? const [];
    return seg.isEmpty ? 'unknown' : seg.last;
  }
}
