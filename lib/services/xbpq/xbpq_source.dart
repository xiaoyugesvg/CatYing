// lib/services/xbpq/xbpq_source.dart
//
// XBPQ 取数层（分类 / 列表 / 搜索）—— 对齐 huoyi `provider_xbpq.go` 的
// `xbpqExtractItems` / `xbpqItemField` / `xbpqJSONList` / `xbpqJSONField`
// / `xbpqCleanText` / `xbpqRuleCategories` / `xbpqCategoryURL` / `xbpqCatalog`
// / `xbpqSearch` / `xbpqItemsToCatalog`。
//
// 输出形态：**直接是 TVBox JSON 协议**（`{list:[{vod_id,vod_name,...}]}`），
// 这样接进 CatYing 现有链路（`SourceService` / `SpiderService`）时不需要
// 任何模型转换 —— P5 只是把 `type: xbpq` 分发到这里。

import 'dart:convert';

import 'package:html/dom.dart';

import 'package:tvbox/services/xbpq/xbpq_cut.dart';
import 'package:tvbox/services/xbpq/xbpq_rule.dart';
import 'package:tvbox/services/xbpq/xbpq_selector.dart';
import 'package:tvbox/services/xbpq/xbpq_url.dart';
import 'package:tvbox/services/xbpq/xbpq_util.dart';

/// 一个列表条目。
///
/// 两种来源：选择器模式给 [node]（条目节点，字段在子树里查）；
/// 截取模式只给 [text]（条目 HTML 片段，字段靠 `&&` 再截）。
/// [doc] 是整页文档 —— 个别站把字段放在条目节点外，需要回整页兜底。
class XbpqItem {
  const XbpqItem({this.text = '', this.node, this.doc});

  final String text;
  final Element? node;
  final Document? doc;
}

/// 抓取函数签名。
///
/// 取数层**不认识网络**：真实抓取由 `XbpqHttp.fetch` 在集成层注入
/// （`XbpqSource(fetcher: XbpqHttp.fetch)`），所以本文件是纯 Dart，
/// 可以离线自检。
typedef XbpqFetcher = Future<String> Function(
  String raw,
  String referer,
  String agent,
);

class XbpqSource {
  XbpqSource({required this.fetcher});

  final XbpqFetcher fetcher;

  // ============================================================
  // 分类
  // ============================================================

  static final RegExp _categoryIdPattern =
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9_/-]{0,79}$');

  /// 解析规则「分类」字段：`name$id#name$id`，`||` 分行，`空` 忽略。
  ///
  /// 子分类行形如 `1--动作片$5#喜剧片$6`（主分类 ID + `--` + 子分类名），
  /// 子分类 ID 独立成项，名称只用子分类名。
  static List<Map<String, String>> categories(XbpqRule rule) {
    final raw = rule.field(const ['分类']);
    if (raw.isEmpty) return const <Map<String, String>>[];

    final out = <Map<String, String>>[];
    final seen = <String>{};
    void add(String id, String name) {
      if (id.isEmpty || name.isEmpty || seen.contains(id)) return;
      seen.add(id);
      out.add({'type_id': id, 'type_name': name});
    }

    // 先扫所有行，子分类攒起来挂到主分类后面。
    final subs = <(String, String, String)>[];
    for (var line in raw.split('||')) {
      line = line.trim();
      if (line.isEmpty || line == '空') continue;
      for (final entry in line.split('#')) {
        final cut = entry.indexOf(r'$');
        if (cut < 0) continue;
        final name = cleanText(entry.substring(0, cut));
        final id = entry.substring(cut + 1).trim();

        final dash = name.indexOf('--');
        if (dash >= 0) {
          final main = name.substring(0, dash);
          final subName = name.substring(dash + 2);
          if (_categoryIdPattern.hasMatch(main)) {
            if (subName.isNotEmpty) subs.add((main, id, subName));
            continue;
          }
        }
        if (_categoryIdPattern.hasMatch(id) && name.isNotEmpty) add(id, name);
      }
    }
    for (final sub in subs) {
      if (seen.contains(sub.$2)) continue;
      seen.add(sub.$2);
      out.add({'type_id': sub.$2, 'type_name': sub.$3});
    }
    return out;
  }

  /// 渲染分类页地址（含翻页）。
  static String categoryUrl(
    XbpqRule rule,
    String base,
    String categoryId,
    int page,
  ) {
    var template = rule.field(const ['分类url', '分类Url']);
    if (template.isEmpty) return '';

    final values = <String, String>{
      'cateId': categoryId,
      'catePg': page.toString(),
      'handurl': '$base/',
      'limit': '20',
      'area': '',
      'class': '',
      'lang': '',
      'year': '',
      'letter': '',
      'by': '',
    };
    // 规则里 `#` 后面是「二级分类」的写法，一级列表用前半段。
    if (template.contains('#') && template.contains('二级')) {
      template = template.substring(0, template.indexOf('#'));
    }
    return XbpqUrl.cleanEmptySegments(XbpqUrl.render(template, base, values));
  }

  // ============================================================
  // 条目抽取
  // ============================================================

  /// 抓一页并抽取条目；抓取失败抛 [XbpqException]。
  Future<List<XbpqItem>> extractItems(
    XbpqRule rule,
    String base,
    String pageUrl,
    String prefix,
  ) async {
    final result = await _extract(rule, base, pageUrl, prefix);
    final error = result.$2;
    if (error != null) throw XbpqException(error);
    return result.$1;
  }

  /// (条目, 错误信息)。搜索要「这一页失败就换下一个候选」，所以错误不抛。
  Future<(List<XbpqItem>, String?)> _extract(
    XbpqRule rule,
    String base,
    String pageUrl,
    String prefix,
  ) async {
    final String body;
    try {
      body = await fetcher(pageUrl, '$base/', rule.userAgent);
    } on XbpqException catch (e) {
      return (const <XbpqItem>[], e.message);
    } catch (e) {
      return (const <XbpqItem>[], '$e');
    }
    if (body.trim().isEmpty) {
      return (const <XbpqItem>[], '站点返回空页面');
    }

    final arrayPattern = rule.field([_p(prefix, '数组'), '数组']);

    // JSON 数组模式：先按「二次截取」缩小范围，再按路径迭代。
    if (arrayPattern.startsWith('j:')) {
      var scoped = body;
      final region = rule.field([_p(prefix, '二次截取'), '二次截取']);
      if (region.startsWith('j:')) {
        final cut = XbpqCut.jsonPathRaw(body, region);
        if (cut.isNotEmpty) scoped = cut;
      }
      final items = XbpqCut
          .jsonArrayItems(scoped, arrayPattern)
          .map((text) => XbpqItem(text: text))
          .toList();
      if (items.isNotEmpty) return (items, null);
    }

    if (arrayPattern.isEmpty) {
      final jsonItems = _jsonList(body);
      return (jsonItems, null);
    }

    final document = XbpqSelector.parseDocument(body);

    // 选择器数组模式：条目直接是节点，字段在子树里查。
    if (arrayPattern.startsWith('p:') || arrayPattern.startsWith('jsoup:')) {
      final spec = XbpqSelector.parse(arrayPattern);
      if (spec == null) return (const <XbpqItem>[], null);
      final items = XbpqSelector
          .selectNodes(document, spec)
          .map((node) => XbpqItem(
                node: node,
                doc: document,
                text: XbpqSelector.renderHtml(node),
              ))
          .toList();
      return (items, null);
    }

    // 截取模式：二次截取先行，再按「数组」pattern 迭代切段。
    var scope = body;
    final region = rule.field([_p(prefix, '二次截取'), '二次截取']);
    if (region.isNotEmpty) {
      final cut = XbpqCut.cutOnce(scope, region);
      if (cut.isNotEmpty) scope = cut;
    }

    var items = XbpqCut
        .list(scope, arrayPattern)
        .map((text) => XbpqItem(text: text, doc: document))
        .toList();

    // 通用兜底：pattern 与站点结构不符时，试几个最常见的容器。
    if (items.isEmpty) {
      for (final fallback in const [
        '<li&&</li>',
        '<a &&</a>',
        '<article&&</article>',
        'class="item"&&</div>',
        'class="card"&&</div>',
      ]) {
        final extra = XbpqCut.list(scope, fallback);
        if (extra.isEmpty) continue;
        items = extra
            .map((text) => XbpqItem(text: text, doc: document))
            .toList();
        break;
      }
    }

    if (items.isEmpty) return (_jsonList(body), null);
    return (items, null);
  }

  static String _p(String prefix, String name) => '$prefix$name';

  /// 页面里嵌着 MacCMS 风格 JSON 数组时直接解析（兜底）。
  static List<XbpqItem> _jsonList(String body) {
    final start = body.indexOf('[{');
    if (start < 0) return const <XbpqItem>[];

    // 页面里 JSON 后面还有 `];</script>` 之类尾巴，Go 的 Decoder 会停在第一个
    // 完整值；Dart 的 jsonDecode 要求整串合法，所以先按括号配对切出来。
    final end = _balancedEnd(body, start);
    if (end < 0) return const <XbpqItem>[];

    dynamic payload;
    try {
      payload = jsonDecode(body.substring(start, end));
    } catch (_) {
      return const <XbpqItem>[];
    }

    final List<dynamic> rows;
    if (payload is List) {
      rows = payload;
    } else if (payload is Map) {
      var found = const <dynamic>[];
      for (final key in const ['list', 'data', 'result', 'rows']) {
        final value = payload[key];
        if (value is List) {
          found = value;
          break;
        }
      }
      rows = found;
    } else {
      return const <XbpqItem>[];
    }

    final items = <XbpqItem>[];
    for (final row in rows) {
      if (row is! Map) continue;
      try {
        items.add(XbpqItem(text: jsonEncode(row)));
      } catch (_) {
        continue;
      }
    }
    return items;
  }

  /// 从 start 处的 `[`/`{` 找到配对的结束位置（跳过字符串里的括号）。
  static int _balancedEnd(String source, int start) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < source.length; i++) {
      final c = source[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (c == r'\') {
          escaped = true;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }
      if (c == '"') {
        inString = true;
        continue;
      }
      if (c == '[' || c == '{') {
        depth++;
      } else if (c == ']' || c == '}') {
        depth--;
        if (depth == 0) return i + 1;
      }
    }
    return -1;
  }

  // ============================================================
  // 字段抽取
  // ============================================================

  /// 在条目上应用一个字段 pattern。
  ///
  /// 三条路径：选择器（`p:`/`jsoup:`）→ JSON 字段（条目是 JSON 时）→
  /// 截取（`&&` / `||` / `+` …）。
  static String itemField(XbpqItem item, String pattern) {
    if (pattern.isEmpty || item.text.isEmpty) return '';

    if (pattern.startsWith('p:') || pattern.startsWith('jsoup:')) {
      final node = item.node;
      if (node == null) return XbpqSelector.firstString(item.text, pattern);

      final spec = XbpqSelector.parse(pattern);
      if (spec == null) return '';
      var nodes = XbpqSelector.selectNodes(node, spec);
      final doc = item.doc;
      // 条目节点外的兄弟容器：回整页找同选择器，再按 within 收回到本条目。
      if (nodes.isEmpty && doc != null) {
        nodes = XbpqSelector.selectNodes(doc, spec);
      }
      for (final candidate in nodes) {
        if (!XbpqSelector.within(candidate, node)) continue;
        return XbpqSelector.valueOf(candidate, spec);
      }
      if (nodes.isNotEmpty) return XbpqSelector.valueOf(nodes.first, spec);
      return '';
    }

    // 形如 `"vod_name":"&&"` 的 JSON 字段截取。
    if (pattern.contains('"') && item.text.contains('{')) {
      final value = _jsonField(item.text, pattern);
      if (value.isNotEmpty) return value;
    }
    return XbpqCut.cutOnce(item.text, pattern);
  }

  /// 条目是 JSON 对象时按字段名取值（大小写不敏感）。
  static String _jsonField(String itemJson, String pattern) {
    dynamic node;
    try {
      node = jsonDecode(itemJson);
    } catch (_) {
      return '';
    }
    if (node is! Map) return '';

    var key = XbpqCut.cutOnce(pattern, '"&&"');
    if (key.isEmpty) {
      key = pattern
          .replaceAll('"', '')
          .replaceAll(':', '')
          .replaceAll('&&', '')
          .replaceAll('+', '')
          .trim();
    }
    final lower = key.toLowerCase();
    for (final entry in node.entries) {
      if (entry.key.toString().trim().toLowerCase() == lower) {
        return XbpqUtil.stringValue(entry.value);
      }
    }
    return '';
  }

  // ============================================================
  // 文本清洗
  // ============================================================

  static final RegExp _tagPattern = RegExp(r'<[^>]*>', dotAll: true);

  /// 去标签与实体噪音，空白折叠成单空格。
  static String cleanText(String value) {
    var out = value.replaceAll(_tagPattern, '');
    out = out
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#13;', '')
        .replaceAll('\t', ' ');
    return out.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).join(' ').trim();
  }

  // ============================================================
  // 列表 / 搜索（TVBox JSON 协议形态）
  // ============================================================

  static final RegExp _numericCategory = RegExp(r'^/?(\d{1,6})(?:\.html)?$');

  /// 分类列表。
  ///
  /// [category] 支持 `2` / `/2` / `2.html` / 路径式 `tv` 等形态；空则取第一个分类。
  Future<Map<String, dynamic>> categoryContent({
    required XbpqRule rule,
    required String base,
    String category = '',
    int page = 1,
  }) async {
    var categoryId = category.trim();
    final matched = _numericCategory
        .firstMatch(categoryId.replaceFirst(RegExp(r'^/+'), ''));
    if (matched != null) categoryId = matched.group(1)!;

    if (categoryId.isEmpty) {
      final list = categories(rule);
      if (list.isNotEmpty) categoryId = list.first['type_id'] ?? '';
    }

    final pageUrl = categoryUrl(rule, base, categoryId, page);
    if (pageUrl.isEmpty) throw const XbpqException('规则缺少分类url');

    final prefix = categoryId.isEmpty ? '' : '列表';
    final result = await _extract(rule, base, pageUrl, prefix);
    final items = result.$1;
    if (items.isEmpty) {
      final error = result.$2;
      if (error != null) throw XbpqException('规则列表页抓取失败：$error');
      throw XbpqException('规则未抽取到列表条目（${_mismatchHint(rule, prefix)}）');
    }

    final videos = _toVideos(
      items: items,
      pageUrl: pageUrl,
      rule: rule,
      titleNames: ['标题', _p(prefix, '标题')],
      linkNames: ['链接', _p(prefix, '链接')],
      pictureNames: [_p(prefix, '图片'), '图片', '主图', '封面图'],
      remarkNames: ['副标题', _p(prefix, '副标题'), '备注'],
    );
    if (videos.isEmpty) {
      throw const XbpqException('规则抽取的条目缺少标题或链接');
    }

    return {
      'page': page,
      'pagecount': page + 1,
      'limit': 20,
      'total': 0,
      'list': videos,
    };
  }

  /// 搜索。[query] 是原始关键词（内部自己做 URL 编码）。
  Future<Map<String, dynamic>> search({
    required XbpqRule rule,
    required String base,
    required String query,
  }) async {
    final template = rule.field(const ['搜索url', '搜索Url']);
    if (template.isEmpty) throw const XbpqException('规则缺少搜索url');

    // 站点有的要 query 编码（`%E5%89%A7`），有的要路径编码，两个候选都试。
    final encoded = Uri.encodeQueryComponent(query);
    final pathEscaped = Uri.encodeComponent(query);
    final candidates = [
      template.replaceAll('{wd}', encoded),
      template.replaceAll('{wd}', pathEscaped),
    ];

    String? lastError;
    for (final candidate in candidates) {
      final spec = XbpqUrl.splitSpec(candidate);
      if (spec.address.isEmpty) continue;
      // 地址里还留着 `{wd}` 说明这个候选不适用（模板把 {wd} 写在别处）。
      if (spec.address.contains('{wd}')) continue;

      final pageUrl = XbpqUrl.render(spec.address, base, {'wd': encoded});
      var body = spec.body;
      if (spec.method.isNotEmpty && body.contains('{wd}')) {
        body = body.replaceAll('{wd}', query);
      }
      final composed = XbpqUrl.composeSpec(pageUrl, spec.method, body);

      var result = await _extract(rule, base, composed, '搜索');
      // 搜索字段没写全的规则退回通用字段。
      if (result.$1.isEmpty) {
        result = await _extract(rule, base, composed, '');
      }
      if (result.$1.isEmpty) {
        lastError = result.$2 != null
            ? '搜索页抓取失败：${result.$2}'
            : '搜索页未抽取到结果（${_mismatchHint(rule, '搜索')}）';
        continue;
      }

      final videos = _toVideos(
        items: result.$1,
        pageUrl: pageUrl,
        rule: rule,
        titleNames: ['搜索标题', '标题'],
        linkNames: ['搜索链接', '链接'],
        pictureNames: ['搜索图片', '图片', '主图', '封面图'],
        remarkNames: ['搜索副标题', '副标题'],
      );
      if (videos.isEmpty) {
        lastError = '搜索抽取的条目缺少标题或链接';
        continue;
      }
      return {'page': 1, 'pagecount': 1, 'limit': videos.length, 'list': videos};
    }

    throw XbpqException(lastError ?? '搜索规则不可用');
  }

  /// 首页：分类 + 第一页列表（列表失败不影响分类，首页仍可用）。
  Future<Map<String, dynamic>> homeContent({
    required XbpqRule rule,
    required String base,
  }) async {
    final classList = categories(rule)
        .map((e) => {'type_id': e['type_id'], 'type_name': e['type_name']})
        .toList();

    var videos = const <Map<String, dynamic>>[];
    try {
      final first = classList.isEmpty ? '' : (classList.first['type_id'] ?? '');
      final content =
          await categoryContent(rule: rule, base: base, category: first);
      videos = (content['list'] as List).cast<Map<String, dynamic>>();
    } catch (_) {
      // 首页列表拿不到就只给分类，用户点分类还能再试。
    }
    return {'class': classList, 'list': videos};
  }

  /// 条目 → TVBox `Video` 形态。
  List<Map<String, dynamic>> _toVideos({
    required List<XbpqItem> items,
    required String pageUrl,
    required XbpqRule rule,
    required List<String> titleNames,
    required List<String> linkNames,
    required List<String> pictureNames,
    required List<String> remarkNames,
  }) {
    final numericId = rule.field(const ['详情url', '详情页url']).isNotEmpty;
    final titlePattern = rule.field(titleNames);
    final linkPattern = rule.field(linkNames);
    final picturePattern = rule.field(pictureNames);
    final remarkPattern = rule.field(remarkNames);

    final videos = <Map<String, dynamic>>[];
    for (final item in items) {
      final title = cleanText(itemField(item, titlePattern));
      final link = XbpqUrl.joinLink(pageUrl, itemField(item, linkPattern));
      if (title.isEmpty || link.isEmpty || !link.startsWith('http')) continue;

      videos.add({
        'vod_id': XbpqUrl.idFromLink(link, numericId),
        'vod_name': title,
        'vod_pic': XbpqUrl.joinLink(pageUrl, itemField(item, picturePattern)),
        'vod_remarks': cleanText(itemField(item, remarkPattern)),
      });
    }
    return videos;
  }

  /// 条数为 0 时带出实际生效的 pattern，方便对照站点 HTML 排查。
  static String _mismatchHint(XbpqRule rule, String prefix) {
    var pattern = rule.field([_p(prefix, '数组'), '数组']).trim();
    if (pattern.isEmpty) return '规则没有「${_p(prefix, '数组')}」字段';
    pattern = cleanText(pattern);
    if (pattern.length > 80) pattern = '${pattern.substring(0, 80)}…';
    return '数组「$pattern」没有匹配到站点结构';
  }
}
