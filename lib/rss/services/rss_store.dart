// lib/rss/services/rss_store.dart
//
// RSS 订阅源仓库：订阅源的增删改 / 启用 / 排序 / 导入，以及"当前选中的源"。
//
// 持久化与其它模块同一套：SharedPreferences + `PrefsMirror.snapshotSoon()`
// （每 15s / 进后台写文件镜像，plist 整域丢失时能恢复）。

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/prefs_mirror.dart';
import '../models/rss_source.dart';

class RssStore {
  RssStore._();
  static final RssStore instance = RssStore._();

  static const String _kSources = 'rss_sources';
  static const String _kSelected = 'rss_selected';
  static const String _kSeeded = 'rss_seeded';

  /// 源列表 / 选中项变化时自增 —— 页面监听它重建。
  final ValueNotifier<int> tick = ValueNotifier<int>(0);

  List<RssSource> _sources = [];
  String _selectedId = '';
  bool _loaded = false;

  bool get loaded => _loaded;
  List<RssSource> get sources => List<RssSource>.unmodifiable(_sources);

  /// 参与列表/刷新循环的源（停用的不算）。
  List<RssSource> get enabledSources =>
      _sources.where((s) => s.enabled).toList();

  String get selectedId => _selectedId;

  RssSource? byId(String id) {
    for (final s in _sources) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 当前选中的源（找不到 ⇒ 第一条；一条都没有 ⇒ null）。
  RssSource? get current {
    final hit = byId(_selectedId);
    if (hit != null) return hit;
    return _sources.isEmpty ? null : _sources.first;
  }

  Future<void> load() async {
    var seeded = false;
    try {
      final p = await SharedPreferences.getInstance();
      seeded = p.getBool(_kSeeded) == true;
      final raw = p.getString(_kSources) ?? '';
      if (raw.isNotEmpty) {
        _sources = parseRssSources(raw);
      }
      _selectedId = (p.getString(_kSelected) ?? '').trim();
    } catch (_) {
      // 读失败按"没配置"起步
    }

    // 首次安装：播种内置源（**只播一次** —— 用户全删了不该又冒出来）
    if (_sources.isEmpty && !seeded) {
      _sources = List<RssSource>.of(kBuiltinRssSources);
      _selectedId = _sources.first.id;
      await _persist(seeded: true);
    }
    if (_selectedId.isEmpty || byId(_selectedId) == null) {
      _selectedId = _sources.isEmpty ? '' : _sources.first.id;
      await _persist();
    }
    _loaded = true;
    _bump();
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
      // 写失败不抛（内存已更新，本次会话仍生效）
    }
    PrefsMirror.snapshotSoon();
    _bump();
  }

  void _bump() => tick.value++;

  Future<void> select(String id) async {
    if (byId(id) == null) return;
    _selectedId = id;
    await _persist();
  }

  /// 批量导入。返回 (新增数, 跳过数)。重复按 `sourceUrl` 判。
  Future<({int added, int skipped})> addAll(List<RssSource> list) async {
    var added = 0, skipped = 0;
    for (final s in list) {
      if (_sources.any((e) => e.url == s.url)) {
        skipped++;
        continue;
      }
      var name = s.name, n = 2;
      while (_sources.any((e) => e.name == name)) {
        name = '${s.name}$n';
        n++;
      }
      _sources.add(RssSource(
        id: 'rss_${DateTime.now().microsecondsSinceEpoch}_$added',
        name: name,
        url: s.url,
        group: s.group,
        icon: s.icon,
        sortUrl: s.sortUrl,
        ruleArticles: s.ruleArticles,
        ruleTitle: s.ruleTitle,
        ruleLink: s.ruleLink,
        ruleImage: s.ruleImage,
        rulePubDate: s.rulePubDate,
        ruleDescription: s.ruleDescription,
        ruleContent: s.ruleContent,
        ruleNextPage: s.ruleNextPage,
        header: s.header,
        enabled: s.enabled,
        enabledCookieJar: s.enabledCookieJar,
        singleUrl: s.singleUrl,
        loadWithBaseUrl: s.loadWithBaseUrl,
        contentBlacklist: s.contentBlacklist,
      ));
      added++;
    }
    if (_selectedId.isEmpty && _sources.isNotEmpty) {
      _selectedId = _sources.first.id;
    }
    await _persist();
    return (added: added, skipped: skipped);
  }

  Future<void> remove(String id) async {
    _sources.removeWhere((s) => s.id == id);
    if (_selectedId == id) {
      _selectedId = _sources.isEmpty ? '' : _sources.first.id;
    }
    await _persist();
  }

  /// 批量删除（管理页多选栏用）—— 只写一次盘。
  Future<void> removeAll(Iterable<String> ids) async {
    final set = ids.toSet();
    if (set.isEmpty) return;
    _sources.removeWhere((s) => set.contains(s.id));
    if (set.contains(_selectedId)) {
      _selectedId = _sources.isEmpty ? '' : _sources.first.id;
    }
    await _persist();
  }

  /// 批量启用/停用（管理页多选栏用）—— 只写一次盘。
  Future<void> setEnabledAll(Iterable<String> ids, bool enabled) async {
    final set = ids.toSet();
    if (set.isEmpty) return;
    for (var i = 0; i < _sources.length; i++) {
      if (!set.contains(_sources[i].id)) continue;
      _sources[i] = _sources[i].copyWith(enabled: enabled);
    }
    // 停用了"当前选中"的那个 ⇒ 顺延到第一个还启用的源
    if (!enabled && set.contains(_selectedId)) {
      final next = _sources.where((s) => s.enabled).toList();
      _selectedId = next.isEmpty ? '' : next.first.id;
    }
    await _persist();
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final i = _sources.indexWhere((s) => s.id == id);
    if (i < 0) return;
    _sources[i] = _sources[i].copyWith(enabled: enabled);
    if (!enabled && _selectedId == id) {
      final next = _sources.where((s) => s.enabled).toList();
      _selectedId = next.isEmpty ? '' : next.first.id;
    }
    await _persist();
  }

  Future<void> rename(String id, String name) async {
    final i = _sources.indexWhere((s) => s.id == id);
    if (i < 0 || name.trim().isEmpty) return;
    _sources[i] = _sources[i].copyWith(name: name.trim());
    await _persist();
  }

  /// 写入某源的**登录信息**（`loginUi` 表单值的 JSON 字符串）。
  ///
  /// 落盘是为了跨重启保住用户的选择（如「影视聚合(资源站)」的"选影视源站"）；
  /// JS 侧 `SourceVariableStore` 是内存态，所以求值前由 `RssReader` 回灌。
  Future<void> setLoginInfo(String id, String json) async {
    final i = _sources.indexWhere((s) => s.id == id);
    if (i < 0) return;
    _sources[i] = _sources[i].copyWith(loginInfo: json);
    await _persist();
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _sources.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex < 0) newIndex = 0;
    if (newIndex >= _sources.length) newIndex = _sources.length - 1;
    final item = _sources.removeAt(oldIndex);
    _sources.insert(newIndex, item);
    await _persist();
  }

  /// 恢复内置源（已存在的按 url 去重补回）。返回补回条数。
  Future<int> restoreBuiltins() async {
    var added = 0;
    for (final b in kBuiltinRssSources) {
      if (_sources.any((s) => s.url == b.url)) continue;
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

/// 内置订阅源（首次安装播种 / 「导入默认」用）。
///
/// 三个都**实测过能出数据**（2026-10-15）：
///   · 少数派（规则版）—— 用户给的那份样本，JSON 接口 + 规则，验证"规则引擎"链路 ✓
///   · 少数派 RSS —— 标准 RSS XML，验证"无规则自动解析"链路 ✓
///   · 小众软件 —— 标准 RSS XML ✓
const List<RssSource> kBuiltinRssSources = [
  RssSource(
    id: 'builtin_rss_sspai_rule',
    name: '少数派',
    url: 'https://sspai.com/',
    group: '内置',
    sortUrl: '全部::https://sspai.com/api/v1/article/matrix/page/get'
        '?offset={{(page-1)*10}}&limit=10&created_at=',
    ruleArticles: r'$.data',
    ruleTitle: r'$.title',
    ruleLink: r'$.id@js:"/post/"+result',
    ruleImage: r'$.banner',
    rulePubDate: r'$.released_time',
    ruleDescription: r'$.summary',
    loadWithBaseUrl: true,
  ),
  RssSource(
    id: 'builtin_rss_sspai_xml',
    name: '少数派 RSS',
    url: 'https://sspai.com/feed',
    group: '内置',
  ),
  RssSource(
    id: 'builtin_rss_appinn',
    name: '小众软件',
    url: 'https://www.appinn.com/feed/',
    group: '内置',
  ),
];
