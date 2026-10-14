// lib/webhome/web_home_prefs.dart
//
// 「网页首页」模块的配置（**独立于小程序体系**）。
//
// 用户 2026-10-14 之前：这里只存**一个**首页地址（为空 ⇒ 用内置示例页）。
// 之后升级成**一列网页源**：内置的、订阅导入的、本地文件导入的，
// 可以切换、可以拖动排序（见 [WebHomeSource]）。
//
// 持久化：prefs（`webhome_sources` / `webhome_selected`）+ 每次改完
// [PrefsMirror.snapshotSoon()]（立刻落盘 plist + 文件镜像），与其它设置同一套兜底。
//
// 兼容旧数据：老键 `webhome_url`（单个地址）在首次升级时**转成一条源**
// 「自定义首页」放进列表（不丢用户原来的配置），但**默认选中的是最新内置的
// 默认网页**（用户明确要求 `tmd.920410.xyz` 当默认）。

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../services/prefs_mirror.dart';
import 'web_home_source.dart';

class WebHomePrefs {
  WebHomePrefs._();
  static final WebHomePrefs instance = WebHomePrefs._();

  static const String _kSources = 'webhome_sources';
  static const String _kSelected = 'webhome_selected';

  /// 是否已经"播种"过内置源。
  ///
  /// 🔴 为什么要这个标记：用户把内置源**全删了**之后列表就是空的 ✗，
  ///    如果只按"列表为空"判断，重启会**又把内置全塞回来**（删不干净）✗。
  static const String _kSeeded = 'webhome_seeded';

  /// 旧版键：单个首页地址（只用于一次性迁移）。
  static const String _kLegacyUrl = 'webhome_url';

  List<WebHomeSource> _sources = [];
  String _selectedId = '';

  bool _loaded = false;
  bool get loaded => _loaded;

  List<WebHomeSource> get sources => List<WebHomeSource>.unmodifiable(_sources);

  String get selectedId => _selectedId;

  /// 当前选中的源（找不到就回落第一个）。
  WebHomeSource? get selected {
    for (final s in _sources) {
      if (s.id == _selectedId) return s;
    }
    return _sources.isEmpty ? null : _sources.first;
  }

  /// 给加载用：一定有一个源（列表为空时用内置第一条兜底，绝不返回 null）。
  WebHomeSource get current => selected ?? kBuiltinWebHomeSources.first;

  Future<void> load() async {
    var seeded = false;
    try {
      final p = await SharedPreferences.getInstance();
      seeded = p.getBool(_kSeeded) == true;
      final raw = p.getString(_kSources) ?? '';
      if (raw.isNotEmpty) {
        final list = <WebHomeSource>[];
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final e in decoded) {
            if (e is Map) {
              final s = WebHomeSource.fromJson(Map<String, dynamic>.from(e));
              if (s != null) list.add(s);
            }
          }
        }
        _sources = list;
      }
      _selectedId = (p.getString(_kSelected) ?? '').trim();
    } catch (_) {
      // 读失败按"没有配置"起步，不影响启动
    }

    // ── 首次升级 / 全新安装：播种内置 + 迁移旧的单个地址 ──
    // ⚠️ 只在**没播种过**时做：用户把源全删了（列表为空）时不该又冒出来。
    if (_sources.isEmpty && !seeded) {
      _sources = List<WebHomeSource>.of(kBuiltinWebHomeSources);
      final legacy = await _legacyUrl();
      if (legacy.isNotEmpty && !_sources.any((s) => s.value == legacy)) {
        _sources.add(WebHomeSource(
          id: 'legacy_url',
          name: '自定义首页',
          kind: WebHomeSourceKind.url,
          value: legacy,
        ));
      }
      // 默认选中 = 内置的第一条（默认网页 tmd.920410.xyz）
      _selectedId = _sources.first.id;
      await _persist(seeded: true);
    } else if (_selectedId.isEmpty ||
        !_sources.any((s) => s.id == _selectedId)) {
      _selectedId = _sources.isEmpty ? '' : _sources.first.id;
      await _persist();
    }

    _loaded = true;
    bumpWebHomeSources();
  }

  Future<String> _legacyUrl() async {
    try {
      final p = await SharedPreferences.getInstance();
      return (p.getString(_kLegacyUrl) ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  Future<void> _persist({bool seeded = false}) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
          _kSources, jsonEncode(_sources.map((s) => s.toJson()).toList()));
      if (seeded) await p.setBool(_kSeeded, true);
      if (_selectedId.isEmpty) {
        await p.remove(_kSelected);
      } else {
        await p.setString(_kSelected, _selectedId);
      }
    } catch (_) {
      // 写失败不抛：内存值已更新，本次会话仍生效
    }
    PrefsMirror.snapshotSoon();
    bumpWebHomeSources();
  }

  /// 切换当前网页。
  Future<void> select(String id) async {
    if (!_sources.any((s) => s.id == id)) return;
    _selectedId = id;
    await _persist();
  }

  /// 拖动排序（长按拖动，同 [ReorderableListView] 的语义）。
  Future<void> reorder(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _sources.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex < 0) newIndex = 0;
    if (newIndex >= _sources.length) newIndex = _sources.length - 1;
    final item = _sources.removeAt(oldIndex);
    _sources.insert(newIndex, item);
    await _persist();
  }

  /// 追加一条源（重名/重复地址不重复加）。
  /// 返回 true = 真的加进去了。
  Future<bool> add(WebHomeSource s) async {
    if (_sources.any((e) => e.value == s.value)) return false;
    var name = s.name;
    var n = 2;
    while (_sources.any((e) => e.name == name)) {
      name = '${s.name}$n';
      n++;
    }
    _sources.add(WebHomeSource(
      id: s.id.isEmpty ? 'ws_${DateTime.now().microsecondsSinceEpoch}' : s.id,
      name: name,
      kind: s.kind,
      value: s.value,
      builtin: s.builtin,
    ));
    await _persist();
    return true;
  }

  Future<void> rename(String id, String name) async {
    final i = _sources.indexWhere((s) => s.id == id);
    if (i < 0 || name.trim().isEmpty) return;
    _sources[i] = _sources[i].copyWith(name: name.trim());
    await _persist();
  }

  /// 删除一条源。若删的是当前选中项，自动切到剩下的第一条。
  Future<void> remove(String id) async {
    _sources.removeWhere((s) => s.id == id);
    if (_selectedId == id) {
      _selectedId = _sources.isEmpty ? '' : _sources.first.id;
    }
    await _persist();
  }

  /// 恢复内置源（已存在的按 value 去重补回；没动用户自己加的）。
  Future<int> restoreBuiltins() async {
    var added = 0;
    for (final b in kBuiltinWebHomeSources) {
      if (_sources.any((s) => s.value == b.value)) continue;
      _sources.add(b);
      added++;
    }
    if (_selectedId.isEmpty && _sources.isNotEmpty) {
      _selectedId = _sources.first.id;
    }
    await _persist();
    return added;
  }
}
