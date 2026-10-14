// lib/rss/models/rss_source.dart
//
// 「RSS 订阅源」模型 —— 与**阅读 / Legado 的 RSS 源**同构（用户 2026-10-15 给的
// 「源仓库」「少数派」两份样本就是这个格式），这样：
//   · 别人分享的 RSS 源 JSON 能**直接导入** ✓
//   · 规则求值能**复用阅读模块那套 legado 引擎**（@css/@xpath/@json/@js/##/{{}}）✓
//
// 一个源有两种吃法（与 Legado 一致）：
//   · **无规则**：`sortUrl` 指向标准 RSS/Atom XML ⇒ 直接按 `<item>`/`<entry>` 解析
//   · **有规则**：`ruleArticles` + `ruleTitle/ruleLink/...` ⇒ 交给规则引擎求值
//     （可以是 JSON 接口、也可以是 HTML 页面）

import 'dart:convert';

import 'package:xml/xml.dart';

/// 一个订阅源里的**分类/频道**（`sortUrl` 里 `名称::url` 的一条）。
class RssChannel {
  const RssChannel(this.title, this.url);

  final String title;
  final String url;

  @override
  String toString() => '$title::<url>';
}

/// 一个 RSS 订阅源。
class RssSource {
  const RssSource({
    required this.id,
    required this.name,
    required this.url,
    this.group = '',
    this.icon = '',
    this.sortUrl = '',
    this.ruleArticles,
    this.ruleTitle,
    this.ruleLink,
    this.ruleImage,
    this.rulePubDate,
    this.ruleDescription,
    this.ruleContent,
    this.ruleNextPage,
    this.header = '',
    this.enabled = true,
    this.enabledCookieJar = true,
    this.singleUrl = false,
    this.loadWithBaseUrl = true,
    this.contentBlacklist = '',
  });

  /// 稳定 id（排序/选中用）。
  final String id;
  final String name;

  /// 源主页（`sourceUrl`）。
  final String url;

  /// 分组（`sourceGroup`）。
  final String group;

  final String icon;

  /// 分类列表原文（`名称::url`，可多行 / `&&` 分隔；可带 `{{page}}`）。
  final String sortUrl;

  // ── 规则（与 Legado RSS 同名）──
  final String? ruleArticles;
  final String? ruleTitle;
  final String? ruleLink;
  final String? ruleImage;
  final String? rulePubDate;
  final String? ruleDescription;
  final String? ruleContent;
  final String? ruleNextPage;

  /// 请求头（JSON 字符串，Legado 同款）。
  final String header;
  final bool enabled;
  final bool enabledCookieJar;

  /// `true` = 这个源就是一个站（没有分类列表），直接用 [url]。
  final bool singleUrl;

  final bool loadWithBaseUrl;

  /// 黑名单（正则/URL，命中就跳过该文章）。
  final String contentBlacklist;

  /// 解析出分类列表；一个都没有 ⇒ 用源主页兜底（`singleUrl` 型）。
  List<RssChannel> get channels {
    final raw = sortUrl.trim();
    if (raw.isEmpty) return [RssChannel(name, url)];
    final out = <RssChannel>[];
    // ⚠️ 只按 **换行** 和 **`&&`** 拆（Legado 的两种分隔符）。
    // 千万不能按单个 `&` 拆：地址里的 `?a=1&b=2` 会被拦腰截断 ✗
    for (final line in raw.split(RegExp(r'\n+|&&'))) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final i = t.lastIndexOf('::');
      if (i <= 0) {
        // 没写 `名称::`，整条当 URL
        if (t.startsWith('http') || t.startsWith('/')) {
          out.add(RssChannel(name, t));
        }
        continue;
      }
      final title = t.substring(0, i).trim();
      final u = t.substring(i + 2).trim();
      if (u.isEmpty) continue;
      out.add(RssChannel(title.isEmpty ? name : title, u));
    }
    if (out.isEmpty) out.add(RssChannel(name, url));
    return out;
  }

  /// 是否有列表规则 —— **判断"标准 RSS 源"的唯一标志**。
  ///
  /// Legado 订阅源文档（`mgz0227.github.io/The-tutorial-of-Legado/Rule/rss.html`
  /// 第 3 节）明确：`列表规则(ruleArticles)……判断是否是标准RSS的标志`。
  /// 因此这里**只看 `ruleArticles`**：为空 ⇒ 按标准 RSS/Atom 默认规则解析；
  /// 非空 ⇒ 走规则引擎。⚠️ 不能把 `ruleTitle` 也算进来 —— 只填了 `ruleTitle`
  /// 而没有 `ruleArticles` 的源，按文档仍属"标准 RSS 源"。
  bool get hasRules => (ruleArticles ?? '').trim().isNotEmpty;

  RssSource copyWith({String? name, String? group, bool? enabled, String? sortUrl}) =>
      RssSource(
        id: id,
        name: name ?? this.name,
        url: url,
        group: group ?? this.group,
        icon: icon,
        sortUrl: sortUrl ?? this.sortUrl,
        ruleArticles: ruleArticles,
        ruleTitle: ruleTitle,
        ruleLink: ruleLink,
        ruleImage: ruleImage,
        rulePubDate: rulePubDate,
        ruleDescription: ruleDescription,
        ruleContent: ruleContent,
        ruleNextPage: ruleNextPage,
        header: header,
        enabled: enabled ?? this.enabled,
        enabledCookieJar: enabledCookieJar,
        singleUrl: singleUrl,
        loadWithBaseUrl: loadWithBaseUrl,
        contentBlacklist: contentBlacklist,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'group': group,
        'icon': icon,
        'sortUrl': sortUrl,
        'ruleArticles': ruleArticles,
        'ruleTitle': ruleTitle,
        'ruleLink': ruleLink,
        'ruleImage': ruleImage,
        'rulePubDate': rulePubDate,
        'ruleDescription': ruleDescription,
        'ruleContent': ruleContent,
        'ruleNextPage': ruleNextPage,
        'header': header,
        'enabled': enabled,
        'enabledCookieJar': enabledCookieJar,
        'singleUrl': singleUrl,
        'loadWithBaseUrl': loadWithBaseUrl,
        'contentBlacklist': contentBlacklist,
      };

  /// 解析一份「Legado RSS 源」JSON。
  ///
  /// 字段名与阅读完全一致（`sourceName`/`sourceUrl`/`ruleArticles`…），
  /// 另外兼容 `name`/`url`/`title` 这些简写 —— 用户手写或别家分享的都能吃。
  static RssSource? fromJson(Map<String, dynamic> j, {int fallbackIndex = 0}) {
    final name = _s(j['sourceName'] ?? j['name'] ?? j['title']);
    final url = _s(j['sourceUrl'] ?? j['url'] ?? j['link']);
    if (name.isEmpty || url.isEmpty) return null;
    return RssSource(
      id: _s(j['id']).isEmpty
          ? 'rss_${url.hashCode.abs()}_$fallbackIndex'
          : _s(j['id']),
      name: name,
      url: url,
      group: _s(j['sourceGroup'] ?? j['group']),
      icon: _s(j['sourceIcon'] ?? j['icon']),
      sortUrl: _s(j['sortUrl'] ?? j['channels']),
      ruleArticles: _n(j['ruleArticles']),
      ruleTitle: _n(j['ruleTitle']),
      ruleLink: _n(j['ruleLink']),
      ruleImage: _n(j['ruleImage']),
      rulePubDate: _n(j['rulePubDate']),
      ruleDescription: _n(j['ruleDescription']),
      ruleContent: _n(j['ruleContent']),
      ruleNextPage: _n(j['ruleNextPage']),
      header: _s(j['header']),
      enabled: j['enabled'] != false,
      enabledCookieJar: j['enabledCookieJar'] != false,
      singleUrl: j['singleUrl'] == true,
      loadWithBaseUrl: j['loadWithBaseUrl'] != false,
      contentBlacklist: _s(j['contentBlacklist']),
    );
  }

  /// 从"一个裸 URL"造一个源（用户只丢了一条 RSS 地址时）。
  static RssSource fromUrl(String url, {String? name}) {
    final n = (name ?? '').trim();
    return RssSource(
      id: 'rss_${url.hashCode.abs()}',
      name: n.isEmpty ? _hostOf(url) : n,
      url: url,
    );
  }

  static String _hostOf(String url) {
    try {
      final h = Uri.parse(url).host;
      return h.isEmpty ? url : h;
    } catch (_) {
      return url;
    }
  }

  static String _s(dynamic v) => v == null ? '' : v.toString().trim();
  static String? _n(dynamic v) {
    final s = _s(v);
    return s.isEmpty ? null : s;
  }
}

/// 把一段文本解析成 RssSource 列表。
///
/// 支持：
///   · `{"sources":[...]}` 清单
///   · `[{...}]` 数组
///   · 单个对象（用户给的样本就是这种）
///   · 每行一个 URL 的纯文本 / `名称,URL`
/// 解析不出来返回空列表（调用方再决定报什么错）。
List<RssSource> parseRssSources(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return [];
  // ── OPML：RSS 阅读器导出的订阅列表（**RSS 圈子最常见的分享格式**）──
  //   `<outline text="名称" xmlUrl="https://…/feed"/>`（可嵌套分组）
  if (t.startsWith('<?xml') || t.contains('<opml') || t.contains('<outline')) {
    final opml = _parseOpml(t);
    if (opml.isNotEmpty) return opml;
  }
  if (t.startsWith('{') || t.startsWith('[')) {
    try {
      final d = jsonDecode(t);
      if (d is Map) {
        final arr = d['sources'] ?? d['items'] ?? d['list'];
        if (arr is List) {
          return _fromList(arr);
        }
        final one = RssSource.fromJson(Map<String, dynamic>.from(d));
        return one == null ? [] : [one];
      }
      if (d is List) return _fromList(d);
    } catch (_) {
      return [];
    }
  }
  // 纯文本：每行 `地址` 或 `名称,地址`
  final out = <RssSource>[];
  var i = 0;
  for (final line in t.split('\n')) {
    final s = line.trim();
    if (s.isEmpty || s.startsWith('#')) continue;
    if (!s.contains('http')) continue;
    final parts = s.split(RegExp(r'[,，|\s]+')).where((e) => e.isNotEmpty).toList();
    final url = parts.firstWhere((e) => e.contains('http'), orElse: () => '');
    if (url.isEmpty) continue;
    final name = parts.where((e) => e != url).join(' ').trim();
    out.add(RssSource.fromUrl(url, name: name.isEmpty ? null : name));
    i++;
    if (i > 500) break; // 防御：异常超长文本
  }
  return out;
}

/// 解析 OPML（RSS 阅读器导出的订阅列表）。
///
/// OPML 允许嵌套（分组下面再挂订阅），所以用 `findAllElements('outline')`
/// 递归取全部节点，只挑**带 `xmlUrl` 的**（不带的是分组标题）✓。
List<RssSource> _parseOpml(String xml) {
  final out = <RssSource>[];
  try {
    final doc = XmlDocument.parse(xml);
    for (final o in doc.findAllElements('outline')) {
      final u = (o.getAttribute('xmlUrl') ?? o.getAttribute('xmlurl') ?? '').trim();
      if (u.isEmpty) continue;
      final name =
          (o.getAttribute('text') ?? o.getAttribute('title') ?? '').trim();
      out.add(RssSource.fromUrl(u, name: name.isEmpty ? null : name));
    }
  } catch (_) {
    // 不是合法 XML ⇒ 当没解析出来，交给后面的分支
  }
  return out;
}

List<RssSource> _fromList(List arr) {
  final out = <RssSource>[];
  for (var i = 0; i < arr.length; i++) {
    final e = arr[i];
    if (e is! Map) continue;
    final s = RssSource.fromJson(Map<String, dynamic>.from(e), fallbackIndex: i);
    if (s != null) out.add(s);
  }
  return out;
}

/// 把源列表编码成 JSON（分享/导出用）。
///
/// 字段名与 Legado 订阅源一致（`RssSource.toJson`），对方既能用本 App 的
/// 「本地导入 / 网络导入」收回，也能直接贴进 Legado 的「订阅源」里。
String encodeRssSources(List<RssSource> list) =>
    const JsonEncoder.withIndent('  ')
        .convert(list.map((e) => e.toJson()).toList());

