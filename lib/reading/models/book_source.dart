import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 漫画源判据（编译一次，避免列表每次重建都重新编译正则）。
final RegExp _comicHintRe = RegExp(r'漫画|漫畫|comic|manga');

/// 正文规则里"像是在取图片列表"的强信号。
///
/// ⚠️ 故意**不含裸 `<img`**：小说正文规则也可能带 `<img>`（插图/净化脚本），
/// 这正是之前把小说误判成漫画源的来源（用户 2026-10-18）。
final RegExp _comicRuleStrongRe = RegExp(
  r'img\s*/?\s*@|//\s*img\s*/?\s*@|@data-original\b|@data-src\b|'
  r'@data-lazy-src\b|comic|manga|manhua|漫画|漫畫|'
  r'\.(?:images?|pics?|imgs?|imgList|imageList|chapterImages)\b',
  caseSensitive: false,
);

/// 无需再看章节名就能确定是漫画的强信号（懒加载图属性 / JSON 图片数组 / 类名）。
final RegExp _comicRuleDecisiveRe = RegExp(
  r'@data-original\b|@data-src\b|@data-lazy-src\b|comic|manga|manhua|漫画|漫畫|'
  r'\.(?:images?|pics?|imgs?|imgList|imageList|chapterImages)\b',
  caseSensitive: false,
);

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

  Map<String, dynamic>? get _configBody => isConfig && raw['config'] is Map
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

  /// 是否启用「发现」（Legado 的 enabledExplore：缺省 true，显式 false = 关闭）。
  /// 关闭发现的源**不在书源页展示**（书源页主体是发现页，点进去只会报
  /// "没有配置分类浏览"——用户 2026-10-11：「关闭了源的发现，源就不要再书源页展示」）。
  /// 搜索/聚搜不受此开关影响。
  bool get enabledExplore => raw['enabledExplore'] != false;

  /// 是否 Python 源（raw 带 pythonKey → CPython 引擎执行 search/bookInfo/toc/content）
  bool get isPythonSource => pythonKey.isNotEmpty;

  /// Python 源模块 key（对应 Documents 下 python-project/src/spider/book/<key>.py）
  String get pythonKey => (raw['pythonKey'] ?? '').toString().trim();

  /// 书源类型：`0`=小说 `1`=有声 `2`=漫画 `3`=文件（Legado 规范）。
  ///
  /// ⚠️ 不少流传的源把 `bookSourceType` 写成中文（`"漫画"`），而阅读器
  /// 判的是 **`'2'`**（`book_source_reader_page.dart` 的 `type == '2'`）
  /// ⇒ 中文类型会被当成文字源：整章拿到图片列表却按文字渲染 = 一片空白。
  /// 这里统一归一化成数字字符串。
  String get type {
    if (isConfig) return '0';
    final rawType = (raw['bookSourceType'] ?? raw['type'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    switch (rawType) {
      case '2':
      case '漫画':
      case 'manga':
      case 'comic':
        return '2';
      case '1':
      case '有声':
      case '音频':
      case 'audio':
        return '1';
      case '3':
      case '文件':
      case 'file':
        return '3';
      case '0':
      case '小说':
      case 'text':
      case 'novel':
        return '0';
      default:
        return rawType;
    }
  }

  /// 是否是漫画源（用于把漫画源从「书源」里彻底分开，用户 2026-10-18）。
  ///
  /// ── 判定策略（保守，宁可漏判也不误判）──────────────────────────
  ///   ① 显式 `bookSourceType: 2` → 漫画；
  ///   ② 显式 `bookSourceType: 0 / 1 / 3` → **小说/有声/文件，直接尊重作者，
  ///      不再猜**。这一条专门解决「正文规则带 `<img>` 的小说源被误判成漫画」；
  ///   ③ 只有**没写类型**的老脚本才做启发式：
  ///      · 名称 / 分组带「漫画 / comic / manga」→ 漫画；
  ///      · 正文规则是取图片列表写法（`img@src`、`//img/@src`、
  ///        `data-original` / `data-src`、JSON `.images[]`、类名带 comic/manhua）；
  ///      · 其中 `img@src` 这种**也可能只是取插图**的弱信号，还要求目录
  ///        章节名使用「话 / 話」，否则仍按小说处理。
  ///
  /// 裸 `<img` 不再作为判据 —— 小说正文规则/净化脚本里出现它太常见了。
  bool get isComicSource {
    if (isConfig) return false;

    final t = type;
    if (t == '2') return true;
    // 作者显式声明了小说/有声/文件：不猜，哪怕正文规则里有图片
    if (t == '0' || t == '1' || t == '3') return false;

    // ── 以下只对「没写 bookSourceType」的源生效 ─────────────────
    final hint = '$name $group'.toLowerCase();
    if (_comicHintRe.hasMatch(hint)) return true;

    final contentRule =
        (readPath('ruleContent.content') ?? raw['ruleBookContent'] ?? '')
            .toString()
            .trim();
    if (contentRule.isEmpty) return false;

    // 不是取图写法（比如 class.content@text / @html）就不是漫画
    if (!_comicRuleStrongRe.hasMatch(contentRule)) return false;

    // 懒加载图属性 / JSON 图片数组 / 类名带 comic → 直接判漫画
    if (_comicRuleDecisiveRe.hasMatch(contentRule)) return true;

    // 只剩 `img@src` 这类可能取插图的弱信号：目录用「第X话」才认
    final tocName = (readPath('ruleToc.chapterName') ?? '').toString();
    return RegExp(r'[话話]').hasMatch(tocName);
  }

  /// 这条源属于哪个仓：`book`（书源仓） / `comic`（漫源仓库）。
  ///
  /// 用户 2026-10-18：「我从哪个仓订阅就用哪个，书源仓库和漫源仓库的订阅
  /// 也不通用」—— 导入 / 订阅更新时会给源打 `_warehouse` 标记；
  /// 老数据没有标记 ⇒ 按类型推断（漫画源归漫源仓库，其余归书源仓）。
  String get warehouse {
    final v = (raw['_warehouse'] ?? '').toString().trim();
    if (v == 'book' || v == 'comic') return v;
    return isComicSource ? 'comic' : 'book';
  }

  bool get belongsToBook => warehouse == 'book';
  bool get belongsToComic => warehouse == 'comic';

  /// 打上仓库标记（不动 id / 其它字段）。
  BookSource withWarehouse(String w) {
    if (w != 'book' && w != 'comic') return this;
    if ((raw['_warehouse'] ?? '').toString() == w) return this;
    return BookSource(raw: {...raw, '_warehouse': w}, id: id);
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
      final copy = child is Map
          ? Map<String, dynamic>.from(child)
          : <String, dynamic>{};
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
    final newId =
        (next['bookSourceUrl'] ?? next['url'] ?? next['bookSourceName'] ?? '')
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

  /// 内置书源已全部移除（用户 2026-10-18：让自己填）。
  /// 这个键只用于**一次性清掉**旧版本播种进来的内置源，之后不再播种任何源。
  static const _kBuiltinRemovedKey = 'book_sources_builtin_removed_v1';

  final List<BookSource> _items = [];
  List<BookSource> get all => List.unmodifiable(_items);
  List<BookSource> get enabled => _items.where((s) => s.enabled).toList();
  bool get isEmpty => _items.isEmpty;

  /// 变更通知（UI 监听）
  final revision = ValueNotifier<int>(0);

  Future<void> init() async {
    // 只加载用户自己导入/仓库导入的源；不再播种任何内置源。
    // 老版本播种过「看漫画」「漫小肆」，这里一次性清掉。
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null && raw.isNotEmpty) {
        _items
          ..clear()
          ..addAll(_decode(raw));
      }
      await _removeLegacyBuiltins(prefs);
      await _removeMisroutedConfigs();
    } catch (e) {
      debugPrint('[BookSource] 加载失败: $e');
    }
    revision.value++;
  }

  /// 旧版把漫画配置包误当书源导入 → 书源仓库里出现漫画源。
  /// 配置源应只存在于 SourceConfigStore，这里把误入的配置源清掉。
  Future<void> _removeMisroutedConfigs() async {
    final hasConfig = _items.any((s) => s.isConfig);
    if (!hasConfig) return;
    _items.removeWhere((s) => s.isConfig);
    await _persist();
  }

  /// 清掉旧版本播种的内置源（只做一次；用户之后重新导入不会被误删）。
  Future<void> _removeLegacyBuiltins(SharedPreferences prefs) async {
    if (prefs.getBool(_kBuiltinRemovedKey) == true) return;
    const legacyUrls = {'https://m.manhuagui.com', 'https://www.jjmhw9.top'};
    final before = _items.length;
    _items.removeWhere((s) => legacyUrls.contains(s.url.trim()));
    if (_items.length != before) await _persist();
    await prefs.setBool(_kBuiltinRemovedKey, true);
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
  /// 导入时自动判定「发现」开关（用户 2026-10-12）：
  /// 源未显式声明 `enabledExplore` 时，按**引擎实际支持的发现规则**
  /// （`exploreUrl`，含 `@js:`/JSON 数组形式）有无自动开/关。
  ///
  /// ⚠️ 老版阅读 3.0 的 `ruleFindUrl`/`ruleFind*` 字段**不参与判定**——
  /// 当前引擎（Node legado / Dart WebBook）只认 `exploreUrl`+`ruleExplore`，
  /// 带 `ruleFindUrl` 的老源即使打开发现也解析不出分类，按"没有发现功能"处理。
  /// 源作者显式写了 `enabledExplore` 的尊重原值。
  static BookSource _applyAutoExplore(BookSource s) {
    if (s.isConfig) return s; // config 源无发现概念
    if (s.raw.containsKey('enabledExplore')) return s; // 显式声明 → 尊重
    final ex = s.raw['exploreUrl'];
    final hasExplore =
        (ex is String && ex.trim().isNotEmpty) ||
        (ex is Map || ex is List); // 非字符串形态（对象/数组）也视为有
    if (hasExplore == s.enabledExplore) return s; // 判定结果与缺省一致 → 原样
    final m = Map<String, dynamic>.of(s.raw);
    m['enabledExplore'] = hasExplore;
    return BookSource(raw: m, id: s.id);
  }

  Future<({int added, int updated})> addAll(List<BookSource> list) async {
    var added = 0;
    var updated = 0;
    for (final orig in list) {
      // 导入即自动判定「发现」开关：没有发现规则的源自动关闭发现
      // （书源页不展示该源，搜索/聚搜不受影响），避免点进发现只报
      // "没有配置分类浏览"。
      final s = _applyAutoExplore(orig);
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

  /// 只重排 [visibleIds] 这批源（仓库页拖动排序用）。
  ///
  /// 与 [reorder] 的区别：未传入的源（另一个仓 / 被搜索筛选隐藏的）
  /// **保持原位置**，只在它们占的坑位里按新顺序填充 —— 否则拖一次会把
  /// 另一个仓的顺序一起打乱。
  Future<void> reorderWithin(List<String> visibleIds) async {
    if (visibleIds.isEmpty) return;
    final wanted = visibleIds.toSet();
    final byId = {for (final s in _items) s.id: s};
    final queue = List<String>.from(visibleIds);
    final ordered = <BookSource>[];
    var qi = 0;
    // 以**当前显示顺序**（_items，仓库页 custom 模式直接用它）为基准，
    // 不用 sorted()：某些源可能还带着旧的 customOrder，混用会在第一次拖动时跳位。
    for (final s in List<BookSource>.of(_items)) {
      if (wanted.contains(s.id)) {
        final id = queue[qi++];
        final moved = byId[id];
        if (moved != null) ordered.add(moved);
      } else {
        ordered.add(s);
      }
    }
    // 统一重写 customOrder = 当前显示顺序
    for (var i = 0; i < ordered.length; i++) {
      if (ordered[i].order != i) ordered[i] = ordered[i].copyWith(order: i);
    }
    _items
      ..clear()
      ..addAll(ordered);
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
  String exportJson() => const JsonEncoder.withIndent(
    '  ',
  ).convert(_items.map((s) => s.toJson()).toList());
}
