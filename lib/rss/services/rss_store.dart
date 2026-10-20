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
    var needPersist = false;
    try {
      final p = await SharedPreferences.getInstance();
      seeded = p.getBool(_kSeeded) == true;
      final raw = p.getString(_kSources) ?? '';
      if (raw.isNotEmpty) {
        // 历史数据里可能残留**同一地址的多条记录**（早期导入不去重）。
        // 不去重的话会出现：删掉一条 → 另一条同名 URL 还在 → 重新导入
        // 一直提示「这些源都已经有了」（用户 2026-10-20 反馈）。
        final parsed = parseRssSources(raw);
        _sources = _dedupeByUrl(parsed);
        if (_sources.length != parsed.length) needPersist = true;
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
    } else if (needPersist) {
      // 去重后的结果写回，避免每次启动都再算一遍
      await _persist();
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
      final key = _normUrl(s.url);
      if (key.isNotEmpty &&
          _sources.any((e) => _normUrl(e.url) == key)) {
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
    _removeIds({id});
    if (_selectedId == id) {
      _selectedId = _sources.isEmpty ? '' : _sources.first.id;
    }
    await _persist();
  }

  /// 批量删除（管理页多选栏用）—— 只写一次盘。
  Future<void> removeAll(Iterable<String> ids) async {
    final set = ids.toSet();
    if (set.isEmpty) return;
    _removeIds(set);
    if (set.contains(_selectedId)) {
      _selectedId = _sources.isEmpty ? '' : _sources.first.id;
    }
    await _persist();
  }

  /// 真正从内存列表里摘掉这些 id，**并连带删掉同地址的残余记录**。
  ///
  /// 早期版本的导入没做 URL 去重，库里可能留着同一地址的两条（其中一条
  /// 在源切换面板里看不到，因为面板只列启用中的源）⇒ 用户删掉看得见的那条
  /// 再重新导入，仍会提示「这些源都已经有了」。
  void _removeIds(Set<String> ids) {
    final urls = <String>{};
    for (final s in _sources) {
      if (!ids.contains(s.id)) continue;
      final k = _normUrl(s.url);
      if (k.isNotEmpty) urls.add(k);
    }
    _sources.removeWhere((s) {
      if (ids.contains(s.id)) return true;
      final k = _normUrl(s.url);
      return k.isNotEmpty && urls.contains(k);
    });
  }

  /// 同一 URL 只保留第一条（空 URL 的不参与去重，原样保留）。
  static List<RssSource> _dedupeByUrl(List<RssSource> list) {
    final seen = <String>{};
    final out = <RssSource>[];
    for (final s in list) {
      final k = _normUrl(s.url);
      if (k.isEmpty || seen.add(k)) out.add(s);
    }
    return out;
  }

  /// 地址归一（仅用于去重比较）：去空白、末尾 `/`，scheme/host 小写。
  static String _normUrl(String u) {
    var s = u.trim();
    if (s.isEmpty) return '';
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    try {
      final p = Uri.parse(s);
      if (p.hasScheme && p.host.isNotEmpty) {
        return p
            .replace(
              scheme: p.scheme.toLowerCase(),
              host: p.host.toLowerCase(),
            )
            .toString();
      }
    } catch (_) {}
    return s;
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

  /// 整条覆盖保存（编辑页用）：按 id 原位替换。
  ///
  /// 与 [rename] 的区别是**所有字段**都可改（规则 / 请求头 / 分类），
  /// 站点改版后用户能直接修规则，不必删源重导。
  Future<void> saveSource(RssSource s) async {
    final i = _sources.indexWhere((e) => e.id == s.id);
    if (i < 0) return;
    _sources[i] = s;
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

  /// 只重排传入 id 所在的坑位（源切换面板里按住拖动用）。
  ///
  /// 面板可能只显示「已启用 + 搜索命中」的子集，直接按绝对下标重排会动到
  /// 看不见的源；这里与书源仓/海阔同一套做法：可见的按新顺序填回原坑位。
  Future<void> reorderWithin(List<String> visibleIds) async {
    if (visibleIds.isEmpty) return;
    final wanted = visibleIds.toSet();
    final byId = {for (final s in _sources) s.id: s};
    final queue = List<String>.from(visibleIds);
    final next = <RssSource>[];
    var qi = 0;
    for (final s in _sources) {
      if (wanted.contains(s.id)) {
        final moved = byId[queue[qi++]];
        if (moved != null) next.add(moved);
      } else {
        next.add(s);
      }
    }
    _sources = next;
    await _persist();
  }

  /// 修改分组（`sourceGroup`）
  Future<void> setGroup(String id, String group) async {
    final i = _sources.indexWhere((s) => s.id == id);
    if (i < 0) return;
    _sources[i] = _sources[i].copyWith(group: group.trim());
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
