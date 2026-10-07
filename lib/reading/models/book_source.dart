import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

/// 小说书源模型与存储。
///
/// 支持两种书源形态：
/// ── 明文 config 源（推荐）────────────────────────────────────
/// `{type:'config', config:{name,url,search_url,search_result_dom,...}}`，
/// 搜索/目录/正文全部 CSS 选择器配置驱动，由 Dart 侧 ConfigBookSource
/// 引擎执行（book_site_config.dart / config_book_source.dart）。
/// 导入直接吃明文 json，无加密、无 JS 规则 —— 与漫画源同款体验。
/// id 派生：`config:${config.name}`。
///
/// ── Legado / 阅读 3.0 源（兼容保留）─────────────────────────
/// `bookSourceName/bookSourceUrl/ruleSearch/...` 规则格式，由 Node 里的
/// Legado 引擎执行（book_source.js）。字段非常多，逐个解成强类型字段
/// 既冗长又容易漏，**保留原始 Map**，由执行引擎在需要时按需取。
class BookSource {
  /// 原始 JSON（config 源 = 顶层定义；Legado 源 = 一份规则 JSON）
  final Map<String, dynamic> raw;

  /// 稳定 id：config 源 = config:${name}；Legado 源优先 bookSourceUrl
  final String id;

  const BookSource({required this.raw, required this.id});

  /// 是否明文 config 源（type=config）。
  bool get isConfig => raw['type'] == 'config';

  Map<String, dynamic>? get _configBody =>
      isConfig && raw['config'] is Map
          ? (raw['config'] as Map).cast<String, dynamic>()
          : null;

  // ── 展示/管理用的便捷访问 ──────────────────────────────────

  String get name {
    final c = _configBody;
    if (c != null) {
      return (c['name'] ?? '未命名书源').toString();
    }
    return (raw['bookSourceName'] ?? raw['name'] ?? '未命名书源').toString();
  }

  String get url {
    final c = _configBody;
    if (c != null) {
      return (c['url'] ?? '').toString();
    }
    return (raw['bookSourceUrl'] ?? raw['url'] ?? '').toString();
  }

  String get group {
    final c = _configBody;
    if (c != null) {
      return (c['group'] ?? '未分组').toString();
    }
    return (raw['bookSourceGroup'] ?? raw['group'] ?? '未分组').toString();
  }

  int get order {
    final v = raw['customOrder'] ?? raw['order'];
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  bool get enabled => raw['enabled'] != false;

  /// 书源类型（Legado 有小说/漫画/音源等；config 源一律 0=小说）
  String get type {
    if (isConfig) return '0';
    return (raw['bookSourceType'] ?? raw['type'] ?? '').toString();
  }

  /// 是否只用于搜索（Legado 的 enabledExplore 之类）
  String get comment {
    final c = _configBody;
    if (c != null) {
      return (c['comment'] ?? '').toString();
    }
    return (raw['bookSourceComment'] ?? raw['comment'] ?? '').toString();
  }

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
    if (group != null) {
      // 🔴 config 型源的 group **读的是 `config.group`** ✗（见 getter :56-62 ✓），
      // 而这里不看源型、一律写**顶层** `bookSourceGroup` ✗ →
      // 对 config 源点「设置分组」：toast 说"已归入 X"、界面纹丝不动 ✓、
      // 下次启动比较 `_items[i].group == group` 恒不成立 ✓（Legado 源读写都是顶层键 ✓
      // 所以只有 config 源有这个病 ✓）。
      // 按源型分流：config 源写进 `config` 体内 ✓，其余源维持原样 ✓
      final c = _configBody;
      if (c != null) {
        m['config'] = <String, dynamic>{...c, 'group': group};
      } else {
        m['bookSourceGroup'] = group;
      }
    }
    return BookSource(raw: m, id: id);
  }

  Map<String, dynamic> toJson() => raw;

  /// 宽松解析：只要是个带名字的 Map 就收。
  ///
  /// 支持两种形态：
  ///   · 明文 config：`{type:'config', config:{name,url,...}}` → id=config:${name}
  ///   · Legado：`{bookSourceName/bookSourceUrl,...}` → id=bookSourceUrl
  ///
  /// 为什么不严格：用户从各处收集来的书源格式五花八门，
  /// **严格校验等于用不了**。真正能不能跑由执行引擎决定，
  /// 这里负责"先收进来、能看能管"。
  static BookSource? fromJson(Map<String, dynamic> j) {
    // config 明文源：{type:'config', config:{name,url,...}}
    if (j['type'] == 'config' && j['config'] is Map) {
      final c = (j['config'] as Map).cast<String, dynamic>();
      final name = (c['name'] ?? '').toString().trim();
      final url = (c['url'] ?? '').toString().trim();
      if (name.isEmpty && url.isEmpty) return null;
      return BookSource(raw: j, id: 'config:$name');
    }
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

  // 注：曾经还有个 `_kBundledInitDone = 'book_sources_bundled_init_done'` 常量，
  // 声明后**从未被读写** ✗（analyze 长期报 unused ✗）→ 已删除 ✓。
  // 它只是个 **prefs 键名常量** ✓，删掉**不影响**用户已有的数据 ✓
  //（那个键仍留在 prefs 里，只是没人再用它了 ✓）
  static const _key = 'book_sources_v1';
  // 出厂内置明文 config 书源（装上即有源，与漫画源同款兜底体验）
  static const _kBundledSourcesPath = 'assets/config/book_sources.json';
  // 出厂内置 Legado 书源包（精选 10 源；装上即有、与 cmbok 同体验）
  static const _kBundledLegadoPath = 'assets/config/legado_sources.json';
  // 内置源一次性初始化标记：首次启动补入内置源后置位，
  // 之后用户增删/改名/改规则均以用户状态为准，不再被内置重置。
  // （新版本已由 _kBundledFp 指纹机制接管；保留常量兼容旧数据。）
  // 内置源资产指纹：assets 内置文件内容变化（内置包更新/首次安装）时
  // 重新补入（同 id 跳过、不清已有）；指纹不变则永不重复补入，
  // 用户增删改不受影响。与漫画源 SourceConfigStore 同一套语义。
  static const _kBundledFp = 'book_sources_bundled_fp';
  // 旧内置残留清理标记：一次性。删除本地 prefs 里不在「当前内置」
  // （`book_sources.json` 里那批精选源）中的旧源
  //（旧版 224 条 legado 源包 / 更早的 763 精选包残留），
  // 仓库回到「只有当前内置」。
  //
  // ⚠️ 2026-10-07：**key 从 v1 换成 v2** ✓ —— 用户要求"其余书源去掉"：
  //   老设备上 `v1` 那次清理**早就跑过了** ✗ ⇒ 不换 key 就**永远不会再清** ✗
  //   ⇒ 那 224 条会一直留在仓库里 ✓。换成 v2 后本机制**再跑一次** ✓，
  //   把不在当前内置里的源全部清掉（清理前照旧先整份备份进 prefs ✓ 可人工恢复 ✓）。
  // 之后用户手动导入的新源不受影响。
  static const _kLegacyPruneDone = 'book_sources_legacy_prune_v2';

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
      // 出厂内置明文书源：装上即有（用户已导入同 id 则跳过，不清已有）
      await _loadBundled();
      // 旧内置残留清理：删除不在当前内置中的旧源（仅一次）。
      await _pruneLegacyBundled();
    } catch (e) {
      debugPrint('[BookSource] 加载失败: $e');
    }
    revision.value++;
  }

  /// 加载 assets 内置书源：明文 config 源（`book_sources.json`）
  /// + Legado 源包（`legado_sources.json`）。
  ///
  /// ⚠️ **现状已更正**（恢复 backup3 后重新内置 ✓）：
  ///   · `book_sources.json` ✓ 内容为空数组（config 源暂空，可用源见下）
  ///   · **`legado_sources.json` 已重新内置 224 条书源** ✓✓
  ///     （来源：cmbok 导出 224 条明文展开，UTF-8 无 BOM，首次安装/指纹变化时补入 ✓）
  ///   · **漫画源不受影响** ✓（`assets/config/sources.json` 16 个源原样保留 ✓）
  ///   ℹ️ 本方法对"空数组 / 文件缺失"**都安全** ✓：读取包在 `try` 里 ✓，
  ///     且逐文件读取走 [_loadBundledFile]（自带 `try`）✓ ⇒ 解析出 0 个源、**不抛异常** ✓
  /// 仅在**首次**启动补入（内置补入标记）；之后用户增删/
  /// 改名/改规则均以用户状态为准，内置源不再重复补入或重置。
  ///
  /// V2 指纹机制：以 assets 内容指纹为准 —— 指纹变化（内置包更新/
  /// 全新安装）才补入（同 id 跳过、不清已有）；指纹不变永不重复补入。
  Future<void> _loadBundled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 两个内置文件的合并指纹：任一文件内容变化都会触发补入。
      final textA = await rootBundle.loadString(_kBundledSourcesPath);
      final textB = await rootBundle.loadString(_kBundledLegadoPath);
      final fp = '${textA.length + textB.length}:'
          '${textA.hashCode ^ textB.hashCode}';
      if ((prefs.getString(_kBundledFp) ?? '') == fp) return;
      var added = 0;
      added += await _loadBundledFile(_kBundledSourcesPath);
      added += await _loadBundledFile(_kBundledLegadoPath);
      if (added > 0) {
        debugPrint('[BookSource] 内置书源补入 $added 个');
        await _persist();
      }
      await prefs.setString(_kBundledFp, fp);
    } catch (e) {
      debugPrint('[BookSource] 内置书源初始化失败: $e');
    }
  }

  /// 旧内置残留清理：删除本地 prefs 里不在「当前内置」id 集合中的旧源
  /// （旧版 763 精选包残留），仓库回到仅当前内置（224）。
  /// 用 SharedPreferences 标记保证仅执行一次（失败不置位，下次重试）；
  /// 之后用户手动导入的新源不受影响。
  Future<void> _pruneLegacyBundled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_kLegacyPruneDone) ?? false) return;
      final builtin = <String>{};
      for (final path in [_kBundledSourcesPath, _kBundledLegadoPath]) {
        final text = await rootBundle.loadString(path);
        final decoded = jsonDecode(text);
        void take(dynamic e) {
          if (e is! Map) return;
          final id = (e['bookSourceUrl'] as String?) ?? '';
          if (id.isNotEmpty) builtin.add(id);
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
      }
      final before = _items.length;
      // 🔴 原实现直接 `removeWhere(!builtin.contains(id))`：而 `builtin` 只收
      // `bookSourceUrl`（见上面 :289）→ **config 型源**（id = `config:<名字>`）
      // 和**用户自己导入的源**都不在其中 ✗ → 一旦这个"一次性"清理**重试**
      // （:277 注释明说"失败不置位，下次重试"），用户导入的源会被一并删掉，
      // 而且**没有任何恢复途径** ✗✗（注释 :278 承诺的"之后导入的新源不受影响"
      // 只在它成功跑过之后才成立 ✗）。
      //
      // 修法：删除前把**将被删除的条目整体备份**进 prefs（可人工恢复）✓；
      // 备份写不进去就**不删**——宁可留下旧内置残留，也不能不可恢复地删用户数据 ✓
      final doomed = _items.where((s) => !builtin.contains(s.id)).toList();
      if (doomed.isNotEmpty) {
        try {
          await prefs.setString(
            'book_sources_pruned_backup_v1',
            jsonEncode(doomed.map((s) => s.raw).toList()),
          );
          debugPrint('[BookSource] 已备份待清理的 ${doomed.length} 个源'
              '（键 book_sources_pruned_backup_v1），随后才执行清理');
        } catch (e) {
          debugPrint('[BookSource] 备份失败 → 跳过本次清理（不删任何源）: $e');
          return;
        }
      }
      _items.removeWhere((s) => !builtin.contains(s.id));
      if (_items.length != before) {
        debugPrint('[BookSource] 清理旧内置书源: $before -> ${_items.length}');
        await _persist();
      }
      await prefs.setBool(_kLegacyPruneDone, true);
      debugPrint('[BookSource] 旧内置书源清理完成');
    } catch (e) {
      debugPrint('[BookSource] 旧内置书源清理失败: $e');
    }
  }

  Future<int> _loadBundledFile(String path) async {
    try {
      final bundled = await rootBundle.loadString(path);
      final defs = <BookSource>[];
      void take(dynamic e) {
        if (e is! Map) return;
        final s = BookSource.fromJson(e.cast<String, dynamic>());
        if (s != null) defs.add(s);
      }

      final decoded = jsonDecode(bundled);
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
      var added = 0;
      for (final s in defs) {
        if (_items.any((e) => e.id == s.id)) continue;
        _items.add(s);
        added++;
      }
      return added;
    } catch (e) {
      debugPrint('[BookSource] 内置书源加载失败($path): $e');
      return 0;
    }
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
