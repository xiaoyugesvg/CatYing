import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 小说书源（Legado / 阅读 3.0 格式）的模型与存储。
///
/// ── 这份东西的来历（重要）─────────────────────────────────────
/// 老桌面版猫影有完整的 Legado 书源体系（`book_source.js` 528 行引擎 +
/// `book_service.dart` 485 行 + 427 行管理页）。按早期需求"删除现有书源"
/// 时被删掉了，而 **cmbok 本身没有替代品** —— cmbok 的图书只有
/// Z-Library（单一图书库，要账号），没有"一个 JSON 描述一个小说站"的模型。
///
/// 所以这里是**重新建**的数据层，不是"把 UI 接上已有的功能"。
///
/// ── 为什么 raw 存整份 JSON 而不是解出字段 ──────────────────────
/// Legado 书源字段非常多（ruleSearch / ruleBookInfo / ruleToc / ruleContent
/// 各自下面还有几十个子字段，还允许用户自定义变量）。逐个解成强类型字段
/// 既冗长又容易漏，**保留原始 Map**，由执行引擎在需要时按需取。
/// 只有展示与管理需要的几个字段（name / url / enabled / group / order）
/// 提出来做便捷访问。
class BookSource {
  /// 原始 JSON（Legado 书源就是一份 JSON）
  final Map<String, dynamic> raw;

  /// 稳定 id：优先用 Legado 的 bookSourceUrl，没有就退回 name
  final String id;

  const BookSource({required this.raw, required this.id});

  // ── 展示/管理用的便捷访问 ──────────────────────────────────

  String get name =>
      (raw['bookSourceName'] ?? raw['name'] ?? '未命名书源').toString();

  String get url =>
      (raw['bookSourceUrl'] ?? raw['url'] ?? '').toString();

  String get group =>
      (raw['bookSourceGroup'] ?? raw['group'] ?? '未分组').toString();

  int get order {
    final v = raw['customOrder'] ?? raw['order'];
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  bool get enabled => raw['enabled'] != false;

  /// 书源类型（Legado 有小说/漫画/音源等）
  String get type => (raw['bookSourceType'] ?? raw['type'] ?? '').toString();

  /// 是否只用于搜索（Legado 的 enabledExplore 之类）
  String get comment =>
      (raw['bookSourceComment'] ?? raw['comment'] ?? '').toString();

  /// 按**点分路径**读字段，如 `ruleSearch.name` / `enabled` / `header`。
  ///
  /// 路径写法与编辑页的 7 个 tab 一一对应（字段名取自真实书源 JSON，
  /// 不是猜的 —— 见对话里那份 `不死神王书城` 样例）：
  ///   基础：bookSourceName / bookSourceUrl / bookSourceGroup /
  ///         bookSourceComment / header / enabled / enabledExplore /
  ///         enabledCookieJar
  ///   搜索：searchUrl + ruleSearch.{name,author,bookList,bookUrl,
  ///         checkKeyWord,intro,lastChapter,wordCount}
  ///   发现：exploreUrl + ruleExplore.*
  ///   详情：ruleBookInfo.*
  ///   目录：ruleToc.*
  ///   正文：ruleContent.*
  ///
  /// 中间层不存在时返回 null（不会造出空对象 —— 那会让导出的 JSON
  /// 多出一堆 `"ruleBookInfo": {}`，用户看着莫名其妙）。
  dynamic readPath(String path) {
    final parts = path.split('.');
    dynamic cur = raw;
    for (final p in parts) {
      if (cur is Map && cur.containsKey(p)) {
        cur = cur[p];
      } else {
        return null;
      }
    }
    return cur;
  }

  /// 按点分路径写字段（中间层不存在会自动创建 Map）。
  ///
  /// 返回新实例（BookSource 不可变）；路径非法时返回原实例。
  BookSource writePath(String path, dynamic value) {
    final parts = path.split('.');
    if (parts.isEmpty) return this;
    final next = Map<String, dynamic>.from(raw);
    var cur = next;
    for (var i = 0; i < parts.length - 1; i++) {
      final p = parts[i];
      final child = cur[p];
      // 中间层不是 Map（或缺）就换成新 Map —— 否则写下去会抛
      final copy = child is Map ? Map<String, dynamic>.from(child) : <String, dynamic>{};
      cur[p] = copy;
      cur = copy;
    }
    if (value == null || (value is String && value.isEmpty)) {
      // 空值 = 删掉这个键，而不是留一个 ""。
      // 留空串会让书源引擎拿到 "" 当规则用，比"没这条规则"更容易出错。
      cur.remove(parts.last);
    } else {
      cur[parts.last] = value;
    }
    // ⚠️ id 由 bookSourceUrl 派生（见 _decode / id getter），
    // 所以改 url 时必须把 id 一起更新 —— 否则改完 URL 后
    // 这条书源的 id 还是旧的，删除/启用都会找错对象。
    final newId = (next['bookSourceUrl'] ?? next['url'] ?? next['bookSourceName'] ?? '')
        .toString();
    return BookSource(raw: next, id: newId.isEmpty ? id : newId);
  }

  BookSource copyWith({bool? enabled, int? order, String? group}) {
    final m = Map<String, dynamic>.of(raw);
    if (enabled != null) m['enabled'] = enabled;
    if (order != null) m['customOrder'] = order;
    if (group != null) m['bookSourceGroup'] = group;
    return BookSource(raw: m, id: id);
  }

  Map<String, dynamic> toJson() => raw;

  /// 宽松解析：只要是个带名字的 Map 就收。
  ///
  /// 为什么不严格：用户从各处收集来的书源格式五花八门，
  /// **严格校验等于用不了**。真正能不能跑由执行引擎决定，
  /// 这里负责"先收进来、能看能管"。
  static BookSource? fromJson(Map<String, dynamic> j) {
    final name = (j['bookSourceName'] ?? j['name'] ?? '').toString().trim();
    final url = (j['bookSourceUrl'] ?? j['url'] ?? '').toString().trim();
    // 名字和地址至少要有一个，否则没法展示也没法识别
    if (name.isEmpty && url.isEmpty) return null;
    final id = url.isNotEmpty ? url : name;
    return BookSource(raw: j, id: id);
  }

  @override
  bool operator ==(Object other) => other is BookSource && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'BookSource($name)';
}

/// 书源存储（持久化 + 增删改查）。
///
/// key 沿用老版本的 `book_sources_v1` —— 万一有用户从老版本升级过来，
/// 已导入的书源能直接被读出来，不用重新导一遍。
class BookSourceStore {
  BookSourceStore._();
  static final BookSourceStore instance = BookSourceStore._();

  static const _key = 'book_sources_v1';

  final List<BookSource> _items = [];
  List<BookSource> get all => List.unmodifiable(_items);
  List<BookSource> get enabled => _items.where((s) => s.enabled).toList();
  bool get isEmpty => _items.isEmpty;

  /// 变更通知（UI 监听）
  final revision = ValueNotifier<int>(0);

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        _items
          ..clear()
          ..addAll(_decode(raw));
      }
    } catch (e) {
      debugPrint('[BookSource] 加载失败: $e');
    }
    revision.value++;
  }

  /// 兼容三种落盘形态：数组 / 单个对象 / {"sources":[...]}
  List<BookSource> _decode(String raw) {
    final decoded = jsonDecode(raw);
    final out = <BookSource>[];
    void take(dynamic e) {
      if (e is! Map) return;
      final s = BookSource.fromJson(e.cast<String, dynamic>());
      if (s != null) out.add(s);
    }

    if (decoded is List) {
      for (final e in decoded) {
        take(e);
      }
    } else if (decoded is Map) {
      final m = decoded.cast<String, dynamic>();
      if (m['sources'] is List) {
        for (final e in (m['sources'] as List)) {
          take(e);
        }
      } else {
        take(m);
      }
    }
    return out;
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode(_items.map((s) => s.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[BookSource] 保存失败: $e');
    }
    revision.value++;
  }

  BookSource? byId(String id) {
    for (final s in _items) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 导入一批。**同 id 覆盖、新 id 追加**，不清空已有的。
  Future<({int added, int updated})> addAll(List<BookSource> list) async {
    var added = 0;
    var updated = 0;
    for (final s in list) {
      final i = _items.indexWhere((e) => e.id == s.id);
      if (i >= 0) {
        // 保留用户当前的启用状态与顺序，只更新配置本身
        final keep = _items[i];
        _items[i] = s.copyWith(enabled: keep.enabled, order: keep.order);
        updated++;
      } else {
        _items.add(s);
        added++;
      }
    }
    await _persist();
    return (added: added, updated: updated);
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final i = _items.indexWhere((e) => e.id == id);
    if (i < 0) return;
    _items[i] = _items[i].copyWith(enabled: enabled);
    await _persist();
  }

  /// 批量启停（"全选/全不选"用）
  /// 改某个书源的分组（「设置分组」用）。
  ///
  /// 直接替换成 `copyWith(group: g)` 的新实例并持久化 ——
  /// 与 [setEnabled] 同一模式（BookSource 是不可变的，改字段靠 copyWith）。
  /// 按点分路径改某个书源的字段（编辑页保存时用）。
  Future<void> updatePath(String id, String path, dynamic value) async {
    final i = _items.indexWhere((s) => s.id == id);
    if (i < 0) return;
    _items[i] = _items[i].writePath(path, value);
    revision.value++;
    await _persist();
  }

  /// 一次性写多个路径（避免每改一个字段就写一次盘）。
  Future<void> updatePaths(String id, Map<String, dynamic> values) async {
    final i = _items.indexWhere((s) => s.id == id);
    if (i < 0) return;
    var s = _items[i];
    values.forEach((k, v) => s = s.writePath(k, v));
    _items[i] = s;
    revision.value++;
    await _persist();
  }

  Future<void> setGroup(String id, String group) async {
    final i = _items.indexWhere((s) => s.id == id);
    if (i < 0) return;
    if (_items[i].group == group) return;
    _items[i] = _items[i].copyWith(group: group);
    revision.value++;
    await _persist();
  }

  Future<void> setAllEnabled(bool enabled) async {
    for (var i = 0; i < _items.length; i++) {
      _items[i] = _items[i].copyWith(enabled: enabled);
    }
    await _persist();
  }

  Future<void> remove(String id) async {
    _items.removeWhere((e) => e.id == id);
    await _persist();
  }

  Future<void> removeAll() async {
    _items.clear();
    await _persist();
  }

  /// 重新排序（把 [orderedIds] 的顺序写进 customOrder）。
  ///
  /// 顺序是有意义的：搜索结果按书源顺序展示，用户会把好用的源排前面。
  Future<void> reorder(List<String> orderedIds) async {
    for (var i = 0; i < orderedIds.length; i++) {
      final idx = _items.indexWhere((e) => e.id == orderedIds[i]);
      if (idx >= 0) _items[idx] = _items[idx].copyWith(order: i);
    }
    _items.sort((a, b) => a.order.compareTo(b.order));
    await _persist();
  }

  /// 按当前顺序返回（有 customOrder 就按它排，否则保持导入顺序）
  List<BookSource> sorted() {
    final list = List<BookSource>.of(_items);
    final hasOrder = list.any((e) => e.order != 0);
    if (hasOrder) {
      list.sort((a, b) {
        final c = a.order.compareTo(b.order);
        // order 相同或都为 0 时保持原顺序（稳定排序）
        return c != 0 ? c : list.indexOf(a).compareTo(list.indexOf(b));
      });
    }
    return list;
  }

  /// 按分组聚合（管理页按组展示）
  Map<String, List<BookSource>> grouped() {
    final out = <String, List<BookSource>>{};
    for (final s in sorted()) {
      out.putIfAbsent(s.group, () => []).add(s);
    }
    return out;
  }

  /// 导出为 Legado 可直接导入的 JSON 数组
  String exportJson() => const JsonEncoder.withIndent('  ')
      .convert(_items.map((s) => s.toJson()).toList());
}
