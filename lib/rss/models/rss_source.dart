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
    this.jsLib = '',
    this.style = '',
    this.articleStyle = 0,
    this.searchUrl = '',
    this.loginUrl = '',
    this.loginUi = '',
    this.loginInfo = '',
    this.preload = false,
    this.cacheFirst = false,
    this.showWebLog = false,
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

  // ── 文档里其余会被真正用到的字段（用户 2026-10-15 指出「没按规范实现」）──

  /// 源级 JS 库（`jsLib`）：规则里调用的工具函数（如 `upLoginData`）写在这里，
  /// **必须先注入 JS 上下文再跑规则**，否则 ReferenceError 被吞成空串
  /// （阅读模块 `WebBook._bindJsLib` 就是这么做的）。
  final String jsLib;

  /// 正文样式（`style`）：规则产出的 HTML 要额外挂的 CSS。
  final String style;

  /// 阅读样式类型（`articleStyle`）：0=默认文字，其余多为富文本/媒体模板。
  final int articleStyle;

  /// 搜索地址模板（`searchUrl`，可为 `<js>` / 带 `{{key}}`）—— 目前未接搜索 UI，
  /// 但字段要留住，免得导入再导出被抹掉。
  final String searchUrl;

  /// 登录检查 / 登录地址（`loginUrl`）。
  final String loginUrl;

  /// 登录界面描述（`loginUi`，JSON 数组：select / toggle / text…）。
  final String loginUi;

  /// 本源的**登录信息**（用户填的 `loginUi` 表单值，JSON 对象字符串）。
  ///
  /// Legado 把登录信息存在源自己身上；JS 侧 `SourceVariableStore` 是**内存态**
  /// （重启即丢），所以这里再落一份盘，规则求值前回灌给 JS
  /// （`source.putLoginInfo`）—— 用户的"选影视源站"才能跨重启生效。
  final String loginInfo;

  /// 预加载（`preload`）：列表就绪后预取**第一条正文**进缓存。
  final bool preload;

  /// 缓存优先（`cacheFirst`）：列表/正文优先读缓存；用户点「刷新」时强制走网络。
  final bool cacheFirst;

  /// 显示 JS 运行日志（`showWebLog`）—— 排障用。
  final bool showWebLog;

  /// 解析出分类列表；一个都没有 ⇒ 用源主页兜底（`singleUrl` 型）。
  ///
  /// ⚠️ 只处理**纯文本**形式（`名称::url` 多行 / `&&`）。当 `sortUrl` 是**规则**
  /// （`<js>` / `@js:` / `$.` …，见 [sortUrlIsRule]）时这里返回的是兜底分类，
  /// 真正求值要走 `RssReader.loadChannels()`（异步、需要 JS 引擎）。
  List<RssChannel> get channels =>
      parseChannelLines(sortUrl, fallbackName: name, fallbackUrl: url);

  /// `sortUrl` 是不是**规则**（而不是"`名称::url`"的纯文本清单）。
  bool get sortUrlIsRule {
    final t = sortUrl.trim();
    if (t.isEmpty) return false;
    return t.startsWith('<js>') ||
        t.startsWith('@js:') ||
        t.startsWith('@css:') ||
        t.startsWith('@xpath:') ||
        t.startsWith('@json:') ||
        t.startsWith('@@') ||
        t.startsWith(r'$.') ||
        t.startsWith(r'$[') ||
        t.startsWith('//');
  }

  /// 把"分类清单文本"拆成分类（`名称::url`，多行或 `&&` 分隔）。
  ///
  /// ⚠️ 只按 **换行** 和 **`&&`** 拆：千万不能按单个 `&` 拆，否则地址里的
  /// `?a=1&b=2` 会被拦腰截断 ✗。
  static List<RssChannel> parseChannelLines(
    String raw, {
    required String fallbackName,
    required String fallbackUrl,
  }) {
    final t0 = raw.trim();
    if (t0.isEmpty) return [RssChannel(fallbackName, fallbackUrl)];
    final out = <RssChannel>[];
    for (final line in t0.split(RegExp(r'\n+|&&'))) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final i = t.lastIndexOf('::');
      if (i <= 0) {
        // 没写 `名称::`，整条当 URL
        if (t.startsWith('http') || t.startsWith('/')) {
          out.add(RssChannel(fallbackName, t));
        }
        continue;
      }
      final title = t.substring(0, i).trim();
      final u = t.substring(i + 2).trim();
      if (u.isEmpty) continue;
      out.add(RssChannel(title.isEmpty ? fallbackName : title, u));
    }
    if (out.isEmpty) out.add(RssChannel(fallbackName, fallbackUrl));
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

  /// 「站点型」源：Legado 的 `singleUrl`（源本身就是**一个站**，不是 RSS 列表）
  /// 且**没有列表规则** ⇒ 它没有文章列表，只能当网页看。
  ///
  /// 用户 2026-10-15 导入的那份 txt（源仓库 / Yiove / 喵公子 / 使用文档…）
  /// 全是这种：能导入 ✓，但抓不出文章（本来就设计成"直开站点"）。
  bool get isSiteOnly => singleUrl && !hasRules;

  RssSource copyWith(
          {String? name,
          String? group,
          bool? enabled,
          String? sortUrl,
          String? loginInfo}) =>
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
        jsLib: jsLib,
        style: style,
        articleStyle: articleStyle,
        searchUrl: searchUrl,
        loginUrl: loginUrl,
        loginUi: loginUi,
        loginInfo: loginInfo ?? this.loginInfo,
        preload: preload,
        cacheFirst: cacheFirst,
        showWebLog: showWebLog,
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
        'jsLib': jsLib,
        'style': style,
        'articleStyle': articleStyle,
        'searchUrl': searchUrl,
        'loginUrl': loginUrl,
        'loginUi': loginUi,
        'loginInfo': loginInfo,
        'preload': preload,
        'cacheFirst': cacheFirst,
        'showWebLog': showWebLog,
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
      jsLib: _s(j['jsLib']),
      style: _s(j['style']),
      articleStyle: int.tryParse(_s(j['articleStyle'])) ?? 0,
      searchUrl: _s(j['searchUrl']),
      loginUrl: _s(j['loginUrl']),
      loginUi: _s(j['loginUi']),
      loginInfo: _s(j['loginInfo']),
      preload: j['preload'] == true,
      cacheFirst: j['cacheFirst'] == true,
      showWebLog: j['showWebLog'] == true,
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

