// lib/rss/services/rss_reader.dart
//
// RSS **抓取 + 解析**。
//
// 两条链路（与 Legado 一致，用户给的"少数派"样本走 ①，"少数派 RSS / 小众软件"
// 走 ②）：
//   ① 源里写了规则（`ruleArticles` + `ruleTitle/ruleLink/...`）
//        → 复用**阅读模块那套 legado 规则引擎**（`AnalyzeRule`：`@css/@xpath/
//          @json/@js/##/{{}}` 全支持，不用重写一套）
//   ② 源里没规则
//        → 按标准 **RSS 2.0 `<item>` / Atom `<entry>`** 用 `package:xml` 直接解
//
// 正文：有 `ruleContent` 就用规则取；没写就抓文章页 + 简易正文提取（去脚本/
// 样式/导航，按块级标签换行）—— 不追求完美，取不到就让用户"用网页打开" ✓。

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import 'package:tvbox/reading/novel_source/analyze/analyze_rule.dart';
import 'package:tvbox/reading/novel_source/analyze/cookie_store.dart';
import 'package:tvbox/reading/novel_source/analyze/js_engine.dart';
import 'package:tvbox/reading/source/global_proxy.dart';
import 'package:tvbox/rss/models/rss_article.dart';
import 'package:tvbox/rss/models/rss_source.dart';
import 'package:tvbox/rss/services/rss_store.dart';

/// 抓一页的结果：文章列表 + 下一页地址（空 = 到底了）+ 是否"其实是个网页"。
typedef RssFetchResult = ({List<RssArticle> articles, String nextUrl, bool siteLike});

/// 视频详情页里的一集。
class RssVideoEpisode {
  const RssVideoEpisode({required this.title, required this.url});

  final String title;
  final String url;
}

/// 视频详情页里的一条播放线路（苹果 CMS 的 `sid`）。
class RssVideoLine {
  const RssVideoLine({required this.name, required this.episodes});

  final String name;
  final List<RssVideoEpisode> episodes;
}

class RssReader {
  RssReader._();

  /// 抓一页文章。返回 (文章列表, 下一页地址)。
  ///
  /// 分页两种（对齐 Legado 订阅源文档第 3 节）：
  ///   · 列表页地址带 `{{page}}` / `{{(page-1)*10}}` ⇒ 用 [page] 递增翻页；
  ///   · 配了 `ruleNextPage`（**规则里没有 `{{page}}`**，只在列表页上求值，
  ///     拿"下一页的地址"）⇒ 靠 [pageUrl] 接力翻页。
  /// [pageUrl] 非空时**直接抓它**（上拉加载更多时传上一页返回的 nextUrl）。
  static Future<RssFetchResult> fetchArticles(
    RssSource source, {
    RssChannel? channel,
    int page = 1,
    String? pageUrl,
    bool ignoreCache = false,
  }) async {
    final ch = channel ?? source.channels.first;
    final target = (pageUrl != null && pageUrl.trim().isNotEmpty)
        ? pageUrl.trim()
        : resolveUrl(ch.url, source.url, page, source: source);
    // Legado 的 `sortUrl` 允许 `地址,{"method":"POST","body":"..."}` 这种写法
    // （秀人岛 / 下厨房的搜索分类），以前整串当 URL ⇒ 请求必失败。
    final spec = splitRequestSpec(target);
    final url = spec.url;
    String body;
    try {
      body = await _body(
        source,
        url,
        ignoreCache: ignoreCache,
        method: spec.method,
        postBody: spec.body,
        extraHeaders: spec.headers,
      );
    } on RssHttpException catch (e) {
      // Cloudflare / 防盗链质询：直连（纯 HTTP）一律 403/503，但内置 WebView
      // 会执行 JS、带 Cookie，能正常打开 ⇒ 直接交给「内嵌网页」，
      // 而不是甩一行错误（用户 2026-10-20：「为啥能打开网页」）。
      if (e.statusCode == 403 || e.statusCode == 429 || e.statusCode == 503) {
        return (articles: const <RssArticle>[], nextUrl: '', siteLike: true);
      }
      rethrow;
    }
    var arts = _blacklist(source, parseArticles(source, body, url));
    // 规则**全部失效**（站点改版 / 换域名）时按页面结构兜底。
    // 用户 2026-10-20：「嗨漫之家看不了，但网页能打开」—— 站点从
    // acgmhx.com 换到 acgmhn.com，旧的 `class.grid-item` 选择器一条都命中不了。
    if (arts.isEmpty && source.hasRules && body.contains('<')) {
      final generic = _blacklist(source, _genericHtmlList(source, body, url));
      if (generic.isNotEmpty) arts = generic;
    }
    var effectiveBody = body;
    var effectiveUrl = url;

    // ── 站点地址自动发现 feed（用户 2026-10-20：「RSS 兼容性总是不够」）──
    // 很多订阅地址其实是**普通网页**（带 `<link rel="alternate" type="application/rss+xml">`），
    // 以前一律落到「内嵌网页」；这里先按标准方式找 feed 并改抓它，
    // 能出文章就正常展示列表，找不到才继续走网页兜底。
    if (!source.hasRules && arts.isEmpty && body.contains('<')) {
      final feed = discoverFeedUrl(body, url);
      if (feed != null && feed != url) {
        try {
          final feedBody = await _body(source, feed, ignoreCache: ignoreCache);
          final feedArts =
              _blacklist(source, parseArticles(source, feedBody, feed));
          if (feedArts.isNotEmpty) {
            arts = feedArts;
            effectiveBody = feedBody;
            effectiveUrl = feed;
          }
        } catch (_) {
          // feed 取不到就保持原样（继续走网页兜底）
        }
      }
    }

    // `preload`：列表就绪后**预取第一条的正文**进缓存 —— 用户在列表里最可能
    // 点开第一条；配合 `cacheFirst` 就是"点开秒开"。
    if (source.preload && page == 1 && arts.isNotEmpty) {
      unawaited(fetchContent(source, arts.first).catchError(
          (_) => (text: '', image: '', isHtml: false, imageCount: 0)));
    }

    return (
      articles: arts,
      nextUrl: _nextPageUrl(source, effectiveBody, effectiveUrl),
      // 兜底判定"这个地址其实是个网页"：**没有列表规则** + 一条文章都没解析出来
      // + 返回体不像 feed（没有 <rss>/<feed>/<channel>/<item> 标签）。
      // ⇒ 用户那份 txt 里 5 条站点型源（源仓库 / Yiove / 使用文档…）即使丢了
      //   `singleUrl` 标记也能被认出来，交给上层**内嵌网页直开**，
      //   而不是甩一句"没有抓到内容"（用户 2026-10-15 反复报的那句）。
      siteLike: arts.isEmpty && !_looksLikeFeed(body) && body.contains('<'),
    );
  }

  /// 从 HTML 里发现 RSS/Atom feed 地址：
  ///   `<link rel="alternate" type="application/rss+xml" href="/feed">`
  ///   `<link rel="alternate" type="application/atom+xml" href="/atom.xml">`
  static String? discoverFeedUrl(String html, String base) {
    final head = html.length > 200000 ? html.substring(0, 200000) : html;
    final tagRe = RegExp(r'<link\b[^>]*>', caseSensitive: false);
    for (final m in tagRe.allMatches(head)) {
      final tag = m.group(0)!;
      final type =
          RegExp(r'type\s*=\s*["'']([^"'']+)["'']', caseSensitive: false)
              .firstMatch(tag)
              ?.group(1)
              ?.toLowerCase() ??
          '';
      if (!type.contains('rss+xml') && !type.contains('atom+xml')) continue;
      final href =
          RegExp(r'href\s*=\s*["'']([^"'']+)["'']', caseSensitive: false)
              .firstMatch(tag)
              ?.group(1)
              ?.trim() ??
          '';
      if (href.isEmpty) continue;
      final abs = _absUrl(href, base);
      if (abs.startsWith('http')) return abs;
    }
    return null;
  }

  /// 返回体像不像订阅源（RSS 2.0 / Atom / JSON Feed）。
  static bool _looksLikeFeed(String body) {
    if (body.isEmpty) return false;
    final t = body.trimLeft();
    if (t.startsWith('{') || t.startsWith('[')) {
      final head = t.length > 4096 ? t.substring(0, 4096) : t;
      return RegExp(r'"(items|articles|list)"\s*:').hasMatch(head);
    }
    final head = body.length > 4096 ? body.substring(0, 4096) : body;
    return RegExp(r'<\s*(rss|feed|channel|item|entry)[\s>]',
            caseSensitive: false)
        .hasMatch(head);
  }

  /// 把**已抓到的页面内容**按源解析成文章列表（不联网，便于测试与复用）。
  ///
  /// 两条链路严格按 Legado 订阅源文档第 3 节分流：
  ///   · `ruleArticles` 为空 ⇒ 标准 RSS/Atom 默认规则；
  ///   · 非空 ⇒ 规则引擎。
  static List<RssArticle> parseArticles(
          RssSource source, String body, String pageUrl) =>
      source.hasRules
          ? _parseByRules(source, body, pageUrl)
          : _parseStandardFeed(source, body, pageUrl);

  /// 通用 HTML 列表兜底（**只在规则产出 0 条时**使用）。
  ///
  /// 站点改版后旧选择器全失效的情况很常见（例：嗨漫之家把
  /// `class.grid-item` 换成了 `ul#list > li`）。这里按"结构化列表"的通用
  /// 特征提取：容器子项都有链接 + 图片/标题，**至少 4 条才采纳**，
  /// 避免把导航/推荐位当成文章列表。
  static List<RssArticle> _genericHtmlList(
      RssSource source, String body, String pageUrl) {
    dom.Document doc;
    try {
      doc = html_parser.parse(body);
    } catch (_) {
      return const [];
    }

    const selectors = <String>[
      'ul#list > li',
      'ul.list > li',
      '.list > li',
      'article',
    ];
    List<dom.Element> items = const [];
    for (final sel in selectors) {
      try {
        final els = doc.querySelectorAll(sel);
        if (els.length >= 4) {
          items = els;
          break;
        }
      } catch (_) {/* 选择器不支持就试下一个 */}
    }
    if (items.isEmpty) return const [];

    final out = <RssArticle>[];
    final seen = <String>{};
    for (final el in items) {
      final a = el.querySelector('a[href]');
      if (a == null) continue;
      var href = (a.attributes['href'] ?? '').trim();
      if (href.isEmpty ||
          href.startsWith('#') ||
          href.toLowerCase().startsWith('javascript')) {
        continue;
      }
      href = _absUrl(href, pageUrl);
      if (href.isEmpty || !seen.add(href)) continue;

      final img = el.querySelector('img');
      final imgSrc = (img?.attributes['data-src'] ??
              img?.attributes['data-original'] ??
              img?.attributes['src'] ??
              '')
          .trim();
      final title = (img?.attributes['alt'] ??
              a.attributes['title'] ??
              el.querySelector('.title')?.text ??
              a.text)
          .trim();
      if (title.isEmpty) continue;

      out.add(RssArticle(
        title: title,
        link: href,
        image: _absUrl(imgSrc, pageUrl),
        sourceId: source.id,
        sourceName: source.name,
      ));
    }
    return out.length >= 4 ? out : const [];
  }

  /// 黑名单过滤（URL 命中就跳过）。
  static List<RssArticle> _blacklist(RssSource source, List<RssArticle> list) {
    final bl = source.contentBlacklist.trim();
    if (bl.isEmpty) return list;
    try {
      final re = RegExp(bl);
      return list.where((a) => !re.hasMatch(a.link)).toList();
    } catch (_) {
      return list.where((a) => !a.link.contains(bl)).toList();
    }
  }

  /// 建一个绑定当前源的规则求值器（源身份 + cookie jar + jsLib，Legado 同款）。
  ///
  /// ⚠️ `enabledCookieJar` 是 Legado 订阅源文档里的字段：控制**本源**的 Cookie
  /// 是否被 `java.ajax` / `cookie.*` 规则读写。跟阅读模块一样，必须在求值前
  /// 按当前源设置（`SourceCookieStore` 是进程级单例，会被下一个源覆盖）。
  ///
  /// ⚠️ `jsLib` 同理必须在**跑规则之前**注入 JS 上下文：规则里调用的工具函数
  /// （`source.getLoginInfoMap()` 之类）都写在 jsLib 里，不注入就是
  /// `ReferenceError`，而它会被 JS 引擎**吞成空串** ⇒ 表现成"规则不生效"。
  static AnalyzeRule _ruleFor(RssSource source, String body, String pageUrl) {
    SourceCookieStore.instance.enabled = source.enabledCookieJar;
    try {
      JsEngine.shared.setActiveSource(
        source.url.isNotEmpty ? source.url : source.name,
        source.jsLib,
      );
    } catch (_) {
      // 注入失败不影响规则本身（与阅读模块同一处理）
    }
    // 源备注（`sourceComment`）：清渠社这类源的 JS 会读
    // `source.sourceComment` 决定图片 CDN 编号；不绑定就是 `undefined` ⇒ 整个
    // 图片规则抛 TypeError（连带封面全空）。
    try {
      JsEngine.shared
          .eval('source.sourceComment = ${jsonEncode(source.sourceComment)};');
    } catch (_) {
      // JS 引擎不可用时忽略（规则本身也会走空值兜底）
    }
    // 把**落盘的登录信息**回灌给 JS 侧：`SourceVariableStore` 是内存态，重启会丢，
    // 而源在规则里会用 `source.getLoginInfoMap()` 读它来选源站 / 带鉴权参数。
    final li = source.loginInfo.trim();
    if (li.isNotEmpty) {
      try {
        AnalyzeRule().getString('@js:source.putLoginInfo(${jsonEncode(li)});""');
      } catch (_) {/* 回灌失败不影响主流程 */}
    }
    return AnalyzeRule()
      ..setContent(body, pageUrl)
      // 规则里可能用 source.getVariable(...) / java.put，需要源身份做分组
      ..bookSourceUrl = source.url;
  }

  /// 求**分类列表**（异步；`sortUrl` 是规则时要跑规则引擎）。
  ///
  /// 文档里 `sortUrl` 有两种：纯文本 `名称::url` 清单，或**一段规则**
  /// （用户 2026-10-15 给的「影视聚合(资源站)」就是一整段 `<js>`：它自己
  /// `java.ajax` 拉站点分类再拼成 `名称::url`）。不求值 ⇒ 一个分类都出不来 ✗。
  static Future<List<RssChannel>> loadChannels(RssSource source) async {
    if (!source.sortUrlIsRule) return source.channels;
    var body = '';
    // `@css:` / `$.` 这类规则需要页面内容；`<js>` 型自己 ajax，不需要。
    // ⚠️ 源地址本身可能是 `<js></js>` 这种"空 JS"，不能当 URL 抓。
    if (source.url.startsWith('http')) {
      try {
        body = await _get(source.url, source);
      } catch (_) {
        // 取不到就用空内容跑规则（`<js>` 型不受影响）
      }
    }
    try {
      final text =
          _ruleFor(source, body, source.url).getString(source.sortUrl).trim();
      if (text.isEmpty) return source.channels;
      return RssSource.parseChannelLines(text,
          fallbackName: source.name, fallbackUrl: source.url);
    } catch (_) {
      return source.channels;
    }
  }

  // ── 登录（`loginUi` / `loginUrl` + jsLib 钩子）─────────────────

  /// 当前源的登录信息（落盘副本；空 = 还没配过）。
  ///
  /// 值可能是字符串（select/text）或**布尔**（toggle）—— 保持原类型不动，
  /// 否则 `!!formData["调试模式"]` 会把 "false" 也判成 true。
  static Map<String, dynamic> loginInfo(RssSource source) {
    final raw = source.loginInfo.trim();
    if (raw.isEmpty) return const {};
    try {
      final d = jsonDecode(raw);
      if (d is Map) return Map<String, dynamic>.from(d);
    } catch (_) {}
    return const {};
  }

  /// 保存登录信息：**先落盘**（跨重启），再调源自己的 jsLib 钩子。
  ///
  /// 约定名 `upLoginData`（社区订阅源/书源通用写法：它内部会
  /// `source.setLoginInfoMap(...)` 做二次加工）；没有这个函数时退回直接写 map。
  static Future<void> saveLogin(
      RssSource source, Map<String, dynamic> values) async {
    final json = jsonEncode(values);
    await RssStore.instance.setLoginInfo(source.id, json);
    try {
      final js = '(typeof upLoginData === "function" '
          '? upLoginData($json) '
          ': source.setLoginInfoMap($json)), "";';
      _ruleFor(source, '', source.url).getString('@js:$js');
    } catch (_) {/* 钩子失败不影响"值已落盘" */}
  }

  /// `showWebLog` 用的 JS 运行日志（最近若干条）。
  static List<String> webLogs(RssSource source) {
    try {
      final raw = _ruleFor(source, '', source.url)
          .getString('@js:JSON.stringify(__webLogs||[])');
      final d = jsonDecode(raw);
      if (d is List) return d.map((e) => '$e').toList();
    } catch (_) {}
    return const [];
  }

  /// 清空 JS 日志缓冲。
  static void clearWebLogs(RssSource source) {
    try {
      _ruleFor(source, '', source.url).getString('@js:__webLogs.length=0;""');
    } catch (_) {}
  }

  // ── 响应体缓存（`cacheFirst` / `preload`）──────────────────────

  /// key = 源 id + 解析后的地址 → 响应体。**有界**（超出按插入顺序丢最旧）。
  static final Map<String, String> _bodyCache = {};

  /// 清掉响应体缓存（「设置 → 缓存管理 → RSS」用）。
  ///
  /// 纯内存（随进程消失），清掉只影响"下次要重新抓一次"，不动任何订阅数据。
  static void clearBodyCache() => _bodyCache.clear();

  /// 本进程内已做过 `loginUrl` 预访问的源（Legado 的登录态检查）
  static final Set<String> _loginPreflighted = {};

  /// `searchUrl` 求值（2026-10-22，Legado 兼容）
  ///
  /// 支持两类写法：
  ///   · 模板：`https://site/search?q={{key}}`（`{{key}}`/`{{keyword}}`/
  ///     `{{searchKey}}`/`{{searchPage}}` 都会被替换，关键字自动 URL 编码）
  ///   · 脚本：`<js>…</js>` 或 `@js:`，由源自己的 jsLib 生成最终地址
  ///     （返回字符串可以直接带 `,{"method":"POST","body":"…"}` 描述）
  static String searchUrlFor(RssSource source, String keyword) {
    final tpl = source.searchUrl.trim();
    if (tpl.isEmpty) return '';
    final kw = Uri.encodeComponent(keyword.trim());
    var s = tpl
        .replaceAll('{{key}}', kw)
        .replaceAll('{{keyword}}', kw)
        .replaceAll('{{searchKey}}', kw)
        .replaceAll('{{searchPage}}', '1')
        .replaceAll('{{page}}', '1');
    var script = '';
    if (s.startsWith('@js:')) {
      script = s;
    } else if (s.startsWith('<js>') && s.endsWith('</js>')) {
      script = '@js:${s.substring(4, s.length - 5)}';
    }
    if (script.isNotEmpty) {
      try {
        final r = _ruleFor(source, '', source.url).getString(script).trim();
        if (r.isNotEmpty) s = r;
      } catch (_) {
        // JS 出错就退回原串（大概率请求失败，但至少把错误暴露出来）
      }
    }
    return s;
  }

  /// 取响应体：命中缓存就直接用（仅当 `cacheFirst` 且未强制刷新），否则抓取并回填。
  static Future<String> _body(
    RssSource source,
    String url, {
    bool ignoreCache = false,
    String method = 'GET',
    String? postBody,
    Map<String, String>? extraHeaders,
  }) async {
    final m = method.trim().isEmpty ? 'GET' : method.trim().toUpperCase();
    final key = '${source.id}|$m|$url|${postBody ?? ''}';
    if (source.cacheFirst && !ignoreCache) {
      final hit = _bodyCache[key];
      if (hit != null) return hit;
    }
    final body = await _get(
      url,
      source,
      method: m,
      postBody: postBody,
      extraHeaders: extraHeaders,
    );
    _bodyCache[key] = body;
    if (_bodyCache.length > 80) _bodyCache.remove(_bodyCache.keys.first);
    return body;
  }

  /// 求"下一页地址"：只在配了 `ruleNextPage` 时有效。
  ///
  /// 文档：该规则的结果必须是字符串、**无页数 `{{page}}`**（想加一页要用 JS）
  /// ⇒ 只能拿**当前列表页**的内容去算下一页地址，再接力抓取。
  /// 拿不到 / 和当前页同址（防自环）⇒ 返回 ''（调用方据此判定"到底了"）。
  static String _nextPageUrl(RssSource source, String body, String pageUrl) {
    final np = (source.ruleNextPage ?? '').trim();
    if (np.isEmpty) return '';
    try {
      final s = _ruleFor(source, body, pageUrl).getString(np).trim();
      if (s.isEmpty) return '';
      final abs = _absUrl(s, pageUrl);
      return abs == pageUrl ? '' : abs;
    } catch (_) {
      return '';
    }
  }

  /// 规则链路。
  ///
  /// ⚠️ 列表**必须**用 `getElements` + 逐条 `setContent(元素)` —— 与阅读模块
  /// `book_list.dart` 同一套写法，不能用 `getStringList`：
  ///   · HTML 源：`ruleArticles` 是**元素选择器**（文档例 `id.content@h3`，
  ///     末段仍是 tag 选择器）；`getStringList` 会把末段当成"取值方法"（去取
  ///     名为 `h3` 的属性）⇒ **0 条**（实测）。
  ///   · JSON 源：`getStringList` 返回的是 Dart map 字符串（`{title: A}`），
  ///     不是合法 JSON ⇒ 后续 `$.title` 全空（实测）；直接传 Map 则命中。
  static List<RssArticle> _parseByRules(
      RssSource source, String body, String pageUrl) {
    final out = <RssArticle>[];
    final ar = _ruleFor(source, body, pageUrl);

    final items = ar.getElements(source.ruleArticles ?? '');
    for (final item in items) {
      // 逐条求值：把内容换成当前条目（Element / JSON 对象 / 字符串都直接可收）
      ar.setContent(item, pageUrl);
      var title = _clean(ar.getString(source.ruleTitle));
      var link = _clean(ar.getString(source.ruleLink, isUrl: true));
      final image = _absUrl(_clean(ar.getString(source.ruleImage)), pageUrl);
      var date = _clean(ar.getString(source.rulePubDate));
      // ⚠️ 描述**不能**走 `_clean`（那是去标签的）：文档第 5/6 步里
      //   `ruleDescription` 常被作者当成**整页正文模板**（用户给的
      //   「影视聚合(资源站)」就是一整页 HLS 播放器 HTML）。原始 HTML 要留给
      //   正文页渲染，列表只用它去标签后的纯文本。
      final rawDesc = ar.getString(source.ruleDescription);
      if (link.isEmpty) continue;
      link = _absUrl(link, pageUrl);
      if (title.isEmpty) title = link;
      out.add(RssArticle(
        title: title,
        link: link,
        image: image,
        pubDate: friendlyTime(date),
        description: _stripHtml(rawDesc),
        contentHtml: rawDesc.contains('<') ? rawDesc : '',
        sourceId: source.id,
        sourceName: source.name,
      ));
    }
    return out;
  }

  /// 标准 RSS / Atom 链路（无规则）。
  static List<RssArticle> _parseStandardFeed(
      RssSource source, String body, String pageUrl) {
    final out = <RssArticle>[];
    // JSON Feed / 常见 JSON 接口（用户 2026-10-20：「RSS 里面好多错误，
    // 兼容性不够」）：不少「订阅源」给的其实是 JSON 而不是 XML。
    final trimmed = body.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      final jsonArts = _parseJsonFeed(source, body, pageUrl);
      if (jsonArts.isNotEmpty) return jsonArts;
    }
    XmlDocument? doc;
    try {
      doc = XmlDocument.parse(body);
    } catch (_) {
      // 大量站点输出的 RSS 不是合法 XML（裸 `&`、控制字符、裸 HTML 标签）
      // → 先修复再解析；还不行就按 <item>/<entry> 正则兜底
      try {
        doc = XmlDocument.parse(_repairXml(body));
      } catch (_) {
        doc = null;
      }
    }
    // RSS 2.0 用 item、Atom 用 entry；有些站还会带命名空间前缀
    final nodes = <XmlElement>[
      if (doc != null) ...doc.findAllElements('item'),
      if (doc != null) ...doc.findAllElements('entry'),
      if (doc == null) ..._regexItems(body),
    ];
    for (final n in nodes) {
      final title = _txt(n, 'title');
      var link = _linkOf(n);
      if (link.isEmpty) link = _txt(n, 'guid');
      if (link.isEmpty) continue;
      link = _absUrl(link, pageUrl);
      final desc = _txt(n, 'description').isNotEmpty
          ? _txt(n, 'description')
          : (_txt(n, 'summary').isNotEmpty
              ? _txt(n, 'summary')
              : _txt(n, 'content'));
      final date = _txt(n, 'pubDate').isNotEmpty
          ? _txt(n, 'pubDate')
          : (_txt(n, 'published').isNotEmpty
              ? _txt(n, 'published')
              : _txt(n, 'updated'));
      // ── feed 自带全文（用户 2026-10-15：「不再白抓、也不会因为反爬变成空」）──
      //   ① `<content:encoded>`：RSS 扩展里**就是全文**，有就优先用；
      //   ② `<description>`：只有当它**带 HTML 标签且够长**时才当全文
      //     （很多源只给一小段摘要，那种仍走"抓原文页"那条老路）。
      //   命中就预置进 contentHtml ⇒ fetchContent 直接用它、不再抓 link。
      //   （源设了 `articleStyle == 1`（纯文字）时不走这条，见 fetchContent。）
      //
      //   ⚠️ 两种写法都要认：CDATA（`<![CDATA[<p>…]]>`，innerXml 原样）
      //   与被转义的 HTML（`&lt;p&gt;`，innerXml 是实体、innerText 才是真标签）。
      String pickHtml(String raw, String text) {
        final re = RegExp(r'<[a-zA-Z][^>]*>');
        if (re.hasMatch(raw)) return raw;
        if (re.hasMatch(text)) return text;
        return '';
      }

      final encHtml = pickHtml(_rawOf(n, const ['encoded']), _txt(n, 'encoded'));
      final descRaw = _rawOf(n, const ['description', 'summary', 'content']);
      final descHtml = pickHtml(descRaw, _txt(n, 'description').isNotEmpty
          ? _txt(n, 'description')
          : (_txt(n, 'summary').isNotEmpty
              ? _txt(n, 'summary')
              : _txt(n, 'content')));
      final feedFullHtml = encHtml.isNotEmpty
          ? encHtml
          : (_stripHtml(descHtml).length > 200 ? descHtml : '');
      out.add(RssArticle(
        title: title.isEmpty ? link : title,
        link: link,
        image: _imageOf(n, pageUrl),
        pubDate: friendlyTime(date),
        description: _stripHtml(desc),
        contentHtml: feedFullHtml,
        sourceId: source.id,
        sourceName: source.name,
      ));
    }
    return out;
  }

  /// JSON Feed 1.x / 常见 JSON 列表接口 → 文章列表。
  ///
  /// 支持的形态（按优先级找列表）：
  ///   · 根就是数组；
  ///   · `{items:[…]}`（JSON Feed 标准）；
  ///   · `{data:[…]}` / `{list:[…]}` / `{result:[…]}` / `{articles:[…]}`；
  ///   · `{data:{list:[…]}}` 这类再套一层的。
  static List<RssArticle> _parseJsonFeed(
      RssSource source, String body, String pageUrl) {
    final out = <RssArticle>[];
    dynamic root;
    try {
      root = jsonDecode(body);
    } catch (_) {
      return out;
    }
    List<dynamic>? items;
    if (root is List) {
      items = root;
    } else if (root is Map) {
      for (final k in const ['items', 'data', 'list', 'result', 'articles']) {
        final v = root[k];
        if (v is List) {
          items = v;
          break;
        }
        if (v is Map) {
          for (final k2 in const ['items', 'list', 'data', 'articles']) {
            final v2 = v[k2];
            if (v2 is List) {
              items = v2;
              break;
            }
          }
          if (items != null) break;
        }
      }
    }
    if (items == null) return out;

    String pick(Map m, List<String> keys) {
      for (final k in keys) {
        final v = m[k];
        if (v is String && v.trim().isNotEmpty) return v.trim();
        if (v is num) return '$v';
      }
      return '';
    }

    for (final e in items) {
      if (e is! Map) continue;
      final m = e.cast<dynamic, dynamic>();
      var link = pick(m, const [
        'url', 'link', 'external_url', 'html_url', 'url_str', 'href',
      ]);
      if (link.isEmpty) continue;
      link = _absUrl(link, pageUrl);
      final title = pick(m, const ['title', 'name', 'headline']);
      final image = _absUrl(
        pick(m, const [
          'image', 'banner_image', 'cover', 'pic', 'thumbnail', 'img',
        ]),
        pageUrl,
      );
      final date = pick(m, const [
        'date_published', 'date_modified', 'pubDate', 'published',
        'created_at', 'time', 'date',
      ]);
      final rawContent = pick(m, const [
        'content_html', 'content', 'description', 'summary', 'content_text',
      ]);
      out.add(RssArticle(
        title: title.isEmpty ? link : title,
        link: link,
        image: image,
        pubDate: friendlyTime(date),
        description: _stripHtml(rawContent),
        contentHtml: rawContent.contains('<') ? rawContent : '',
        sourceId: source.id,
        sourceName: source.name,
      ));
    }
    return out;
  }

  /// 修复「不是合法 XML」的常见问题：BOM、前置杂字符、控制字符、HTML 命名实体、裸 `&`。
  static String _repairXml(String s) {
    var out = _stripBom(s);
    // XML 声明必须位于文档最前面；有些源在它前面还塞了注释/空白 ⇒ 直接删掉声明
    //（声明本身对解析没有必要）
    out = out.replaceFirst(RegExp(r'<\?xml[^>]*\?>', caseSensitive: false), '');
    // 第一个 '<' 之前的 BOM/说明文字会让解析器报 "Unexpected character"
    final lt = out.indexOf('<');
    if (lt > 0) out = out.substring(lt);
    out = out.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');
    // ⚠️ 最常见的「XML 解析直接失败」原因：标题/摘要里写了 `&nbsp;` `&hellip;`
    //   这类 **HTML 命名实体**，而 XML 只认 amp/lt/gt/quot/apos 五个
    //   ⇒ 解析器抛 "undefined entity"，整篇 feed 变 0 条。
    //   认识的换成字符，不认识的一律转义成字面量（至少不整篇失败）。
    const xmlSafe = {'amp', 'lt', 'gt', 'quot', 'apos'};
    const htmlNamed = {
      'nbsp': ' ',
      'hellip': '…',
      'mdash': '—',
      'ndash': '–',
      'ldquo': '“',
      'rdquo': '”',
      'lsquo': '‘',
      'rsquo': '’',
      'middot': '·',
      'copy': '©',
      'reg': '®',
      'times': '×',
      'divide': '÷',
      'bull': '•',
      'deg': '°',
    };
    out = out.replaceAllMapped(
      RegExp(r'&([a-zA-Z][a-zA-Z0-9]*);'),
      (m) {
        final name = m.group(1)!;
        if (xmlSafe.contains(name)) return m.group(0)!;
        final ch = htmlNamed[name.toLowerCase()];
        return ch ?? '&amp;$name;';
      },
    );
    out = out.replaceAllMapped(
      RegExp(r'&(?!(?:#\d+|#x[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);)'),
      (_) => '&amp;',
    );
    return out;
  }

  /// XML 彻底解析不了时的兜底：按 `<item>` / `<entry>` 块逐个提取。
  static List<XmlElement> _regexItems(String body) {
    final out = <XmlElement>[];
    final re = RegExp(
      r'<(item|entry)\b[^>]*>[\s\S]*?</\1\s*>',
      caseSensitive: false,
    );
    for (final m in re.allMatches(body)) {
      try {
        final doc = XmlDocument.parse('<x>${_repairXml(m.group(0)!)}</x>');
        final el = doc.rootElement.children.whereType<XmlElement>().first;
        out.add(el);
      } catch (_) {
        // 单条坏掉就跳过，不影响其它条目
      }
    }
    return out;
  }

  /// 取正文。返回 (内容, 文章里的第一张图, 是不是 HTML, 正文页图片数量)。
  ///
  /// [isHtml] 为 true 时 `text` 字段装的是**原始 HTML**，调用方要用网页渲染
  /// （用户给的「影视聚合(资源站)」整页就是个 HLS 播放器模板）。
  ///
  /// [imageCount] 用来识别「图集型」文章（秀人岛 / 凹凸吧 / 下厨房步骤图）：
  /// 这类页面文字提取出来几乎没内容，直接显示原网页体验最好。
  static Future<
      ({String text, String image, bool isHtml, int imageCount})> fetchContent(
      RssSource source, RssArticle article) async {
    // `articleStyle`：官方文档没写清 0/1/2/3 的语义，这里按"1 最像纯文字 /
    //   ≥2 最像富媒体模板"的常见用法映射，0 = 按产出内容自动判断。
    //   真机实测发现对不上时，只需改这三行。
    final forceText = source.articleStyle == 1;
    final forceHtml = source.articleStyle >= 2;
    try {
      // 列表阶段规则已经产出正文 HTML（`ruleDescription` 当模板用）⇒ 直接用，
      // 不必再抓一次文章页（它的 link 多半只是个接口地址，抓了也没内容）。
      if (!forceText && article.contentHtml.trim().isNotEmpty) {
        return (
          text: article.contentHtml,
          image: _firstImage(article.contentHtml, article.link),
          isHtml: true,
          imageCount: _countContentImages(article.contentHtml),
        );
      }
      final body = await _body(source, article.link);
      final imageCount = _countContentImages(body);
      if (source.hasRules && (source.ruleContent ?? '').trim().isNotEmpty) {
        final out = _ruleFor(source, body, article.link)
            .getString(source.ruleContent);
        if (out.contains('<') && !forceText) {
          return (
            text: out,
            image: _firstImage(out, article.link),
            isHtml: true,
            imageCount: imageCount,
          );
        }
        final text = _stripHtml(out);
        if (text.trim().length > 40) {
          return (
            text: forceHtml ? out : text,
            image: _firstImage(out, article.link),
            isHtml: forceHtml,
            imageCount: imageCount,
          );
        }
      }
      // 正文多页（Legado 兼容，2026-10-22）：页面里有明确的「下一页」链接时
      // 继续抓并拼接，最多再抓 3 页（防死循环 / 误把列表页翻到底）。
      var text = extractArticleText(body);
      var pages = 0;
      var next = _nextContentUrl(body, article.link);
      while (next != null && pages < 3) {
        pages++;
        try {
          final nb = await _body(source, next);
          final more = extractArticleText(nb);
          if (more.trim().isEmpty) break;
          text = '$text\n\n$more';
          final nn = _nextContentUrl(nb, next);
          if (nn == null || nn == next) break;
          next = nn;
        } catch (_) {
          break;
        }
      }
      return (
        text: text,
        image: _firstImage(body, article.link),
        isHtml: false,
        imageCount: imageCount,
      );
    } catch (e) {
      return (
        text: '正文抓取失败：${_short(e)}',
        image: '',
        isHtml: false,
        imageCount: 0,
      );
    }
  }

  /// 正文页的「下一页」地址（正文分页用）。
  ///
  /// 只认**明确的翻页语义**：`rel=next`，或文本恰好是「下一页 / 下页 / next」
  /// （允许带 » › … 之类装饰）；且必须与原页同域，避免把"相关推荐"当成下一页。
  static String? _nextContentUrl(String html, String pageUrl) {
    try {
      final doc = html_parser.parse(html);
      final host = Uri.tryParse(pageUrl)?.host ?? '';
      for (final a in doc.querySelectorAll('a[href]')) {
        final href = (a.attributes['href'] ?? '').trim();
        if (href.isEmpty ||
            href.startsWith('#') ||
            href.toLowerCase().startsWith('javascript')) {
          continue;
        }
        final rel = (a.attributes['rel'] ?? '').toLowerCase();
        final t = a.text
            .trim()
            .toLowerCase()
            .replaceAll(RegExp(r'[\s»›…\.\-—>]+'), '');
        final isNext = rel.split(RegExp(r'\s+')).contains('next') ||
            t == '下一页' ||
            t == '下页' ||
            t == '下一頁' ||
            t == 'next';
        if (!isNext) continue;
        final abs = _absUrl(href, pageUrl);
        if (abs.isEmpty || abs == pageUrl) continue;
        final h = Uri.tryParse(abs)?.host ?? '';
        if (host.isNotEmpty && h.isNotEmpty && h != host) continue;
        return abs;
      }
    } catch (_) {}
    return null;
  }

  /// 正文页里的图片数量（图集判定用）。
  ///
  /// 除了常规 `<img>`，还认 `#imgData` 这种「base64 路径清单」
  /// （凹凸吧 109 张图就是它，页面里几乎没有可直接用的 `<img>`）。
  static int _countContentImages(String html) {
    var n = 0;
    try {
      final data = RegExp(
        r'''id=["']imgData["'][^>]*value=["']([^"']+)["']''',
        caseSensitive: false,
      ).firstMatch(html);
      if (data != null) {
        n += data
            .group(1)!
            .split('|')
            .where((e) => e.trim().isNotEmpty)
            .length;
      }
    } catch (_) {}
    try {
      final doc = html_parser.parse(html);
      for (final img in doc.querySelectorAll('img')) {
        final a = img.attributes;
        final src = (a['data-original'] ??
                a['data-src'] ??
                a['data-lazy-src'] ??
                a['src'] ??
                '')
            .trim();
        if (src.isEmpty || src.startsWith('data:')) continue;
        final cls = (a['class'] ?? '').toLowerCase();
        if (cls.contains('logo') || cls.contains('avatar')) continue;
        final w = int.tryParse(a['width'] ?? '') ?? 0;
        final h = int.tryParse(a['height'] ?? '') ?? 0;
        if ((w > 0 && w < 200) || (h > 0 && h < 200)) continue;
        final lower = src.toLowerCase();
        if (!(lower.startsWith('http') ||
            lower.startsWith('//') ||
            lower.startsWith('/'))) {
          continue;
        }
        if (lower.endsWith('.svg') || lower.contains('/icon')) continue;
        final path = lower.split('?').first;
        final isImg = path.endsWith('.jpg') ||
            path.endsWith('.jpeg') ||
            path.endsWith('.png') ||
            path.endsWith('.webp') ||
            path.endsWith('.avif') ||
            path.endsWith('.bmp') ||
            path.contains('loadimage');
        if (isImg) n++;
      }
    } catch (_) {}
    return n;
  }

  // ── 视频类源：详情页分集 / 播放页直链 ───────────────────────────

  /// 从视频详情页 HTML 里抠出「线路 → 集数」。
  ///
  /// 覆盖苹果 CMS / 海洋 CMS 常见的 `/index.php/vod/play/id/…/sid/…/nid/….html`
  /// 链接（樱花动漫这类源只写了列表规则，正文规则为空，以前只能当纯文本看）。
  /// 找不到分集时返回空列表，调用方退回「网页播放」。
  static Future<List<RssVideoLine>> fetchVideoLines(
      RssSource source, RssArticle article) async {
    final body = await _get(article.link, source);
    final groups = <String, List<RssVideoEpisode>>{};
    final seen = <String>{};
    final re = RegExp(
      r'''<a\b[^>]*?href\s*=\s*(?:"([^"]*)"|'([^']*)')[^>]*>([\s\S]*?)</a>''',
      caseSensitive: false,
    );
    for (final m in re.allMatches(body)) {
      final href = (m.group(1) ?? m.group(2) ?? '').trim();
      if (href.isEmpty || href.startsWith('javascript:')) continue;
      if (!_looksPlayLink(href)) continue;
      final label = _stripHtml(m.group(3) ?? '').trim();
      if (label.isEmpty || label.length > 24) continue;
      final abs = _absUrl(href, article.link);
      if (abs.isEmpty || !seen.add(abs)) continue;
      final sid = _playSid(abs);
      final key = sid.isEmpty ? '线路' : '线路$sid';
      groups.putIfAbsent(key, () => <RssVideoEpisode>[]).add(
            RssVideoEpisode(title: label, url: abs),
          );
    }
    if (groups.isEmpty) return const [];
    final keys = groups.keys.toList()
      ..sort((a, b) {
        final na = int.tryParse(RegExp(r'\d+').firstMatch(a)?.group(0) ?? '');
        final nb = int.tryParse(RegExp(r'\d+').firstMatch(b)?.group(0) ?? '');
        return (na ?? 0).compareTo(nb ?? 0);
      });
    final lines = [
      for (final k in keys)
        RssVideoLine(name: k, episodes: groups[k]!.take(300).toList()),
    ];
    final total = lines.fold<int>(0, (n, l) => n + l.episodes.length);
    return total == 0 ? const [] : lines;
  }

  static bool _looksPlayLink(String href) {
    final h = href.toLowerCase();
    if (h.contains('vod/play') || h.contains('vod-play')) return true;
    return h.contains('/play/') && (h.contains('sid') || h.contains('nid'));
  }

  static String _playSid(String url) {
    final m = RegExp(r'/sid/(\d+)').firstMatch(url) ??
        RegExp(r'[?&]sid=(\d+)').firstMatch(url);
    return m?.group(1) ?? '';
  }

  /// 播放页 → 视频直链（苹果 CMS 的 `player_aaaa` 配置里通常直接带 m3u8）。
  ///
  /// 解析不到（加密 / JS 动态拼地址）返回 null，调用方退回嗅探播放。
  static Future<String?> resolvePlayUrl(
      RssSource source, String pageUrl) async {
    try {
      final body = await _get(pageUrl, source);
      final cfg = _playerConfig(body);
      if (cfg != null) {
        final enc = cfg['encrypt'];
        final encrypted = enc == 1 || enc == '1' || enc == true;
        final u = (cfg['url'] ?? '').toString().trim();
        if (!encrypted && u.startsWith('http')) return u;
      }
      // 兜底：整页里直接出现的 m3u8/mp4
      final m = RegExp(
        r'''https?:(?:\\/\\/|//)[^\s"'<>\\]+?\.(?:m3u8|mp4|flv|mkv)(?:\?[^\s"'<>\\]*)?''',
        caseSensitive: false,
      ).firstMatch(body);
      return m?.group(0)?.replaceAll(r'\/', '/');
    } catch (_) {
      return null;
    }
  }

  /// 取 `player_aaaa = {...}` 里的 JSON（字段里有嵌套对象，必须括号配对扫描）。
  static Map<String, dynamic>? _playerConfig(String body) {
    final at = body.indexOf('player_aaaa');
    if (at < 0) return null;
    final eq = body.indexOf('=', at);
    if (eq < 0) return null;
    final start = body.indexOf('{', eq);
    if (start < 0) return null;
    var depth = 0;
    var inStr = false;
    var esc = false;
    for (var i = start; i < body.length; i++) {
      final c = body[i];
      if (inStr) {
        if (esc) {
          esc = false;
        } else if (c == '\\') {
          esc = true;
        } else if (c == '"') {
          inStr = false;
        }
      } else if (c == '"') {
        inStr = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) {
          try {
            final d = jsonDecode(body.substring(start, i + 1));
            return d is Map ? Map<String, dynamic>.from(d) : null;
          } catch (_) {
            return null;
          }
        }
      }
    }
    return null;
  }

  /// 播放直链要带的请求头（源 header 里的 Referer / UA / Cookie 等）。
  static Map<String, String> playHeaders(RssSource source) =>
      Map<String, String>.from(_headers(source));

  // ── 网络 ────────────────────────────────────────────────────────

  static Future<String> _get(
    String url,
    RssSource source, {
    String method = 'GET',
    String? postBody,
    Map<String, String>? extraHeaders,
  }) async {
    final headers = _headers(source);
    // `地址,{"method":"POST","body":"...","headers":{...}}` 里的自定义请求头
    // （秀人岛 / 下厨房这类源）优先于源级 header。
    if (extraHeaders != null) {
      for (final e in extraHeaders.entries) {
        final k = e.key.trim();
        if (k.isNotEmpty) headers[k] = e.value;
      }
    }
    final m = method.trim().isEmpty ? 'GET' : method.trim().toUpperCase();
    final bodyText = postBody ?? '';
    // ── `loginUrl` 登录态预访问（Legado 兼容，2026-10-22）─────────────
    // 不少订阅源必须**先访问一次登录/校验地址**才会下发会话 Cookie
    // （legado 的 loginUrl 就是干这个的）。这里每个源每进程只做一次，
    // 失败不阻塞主请求（有的源登录页本身就会 4xx）。
    final loginUrl = source.loginUrl.trim();
    if (loginUrl.isNotEmpty) {
      final lk = '${source.id}|$loginUrl';
      if (_loginPreflighted.add(lk)) {
        try {
          await _get(loginUrl, source);
        } catch (_) {
          // 忽略：预访问失败时仍尝试正常抓取
        }
      }
    }
    // 站点常见的防盗链判断：没有 Referer 直接 403（用户 2026-10-20 截图里的
    // DioException 403 就是这一类）。补一个同源 Referer。
    headers.putIfAbsent('Referer', () => _originOf(url));
    headers.putIfAbsent(
      'Accept',
      () => 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    );
    // ── Cookie jar（`enabledCookieJar`）──────────────────────────
    // 规则引擎里的 `java.ajax` 一直带着源的 cookie，而这里直接抓取原来**完全没带**
    // ⇒ 需要登录态/校验 cookie 的源必然 403 或空内容。现在补上：
    // 发请求带 `Cookie`，收响应吸收 `Set-Cookie`（与规则链共用同一个 jar）。
    SourceCookieStore.instance.enabled = source.enabledCookieJar;
    if (source.enabledCookieJar) {
      final cookie = SourceCookieStore.instance.getCookie(url);
      if (cookie.isNotEmpty) headers.putIfAbsent('Cookie', () => cookie);
    }
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      // ⚠️ 取**字节**自己解编码：中文站/RSS 常见 GBK，Dio 默认按 utf8 解会整篇乱码
      responseType: ResponseType.bytes,
      followRedirects: true,
    ));
    // ⚠️ **必须**套全局代理（「设置 → 网络代理」）—— 全项目 27 处请求都这么做
    //   （书源 / 漫画源 / z-library / 豆瓣…）。RSS 原来漏了这一句 ⇒ 用户开了
    //   代理后 RSS **每个源都失败**，报的就是 `DioException [unknown]: null`
    //   （用户 2026-10-15 实测）。
    applyGlobalProxy(dio);
    try {
      Future<Response<List<int>>> send(Map<String, String> h) {
        final bodyless = m == 'GET' || m == 'HEAD' || bodyText.isEmpty;
        // 请求体裁剪：JSON 直接用 application/json，其余按表单（legado 默认）。
        final t = bodyText.trimLeft();
        final json = t.startsWith('{') || t.startsWith('[');
        return dio.request<List<int>>(
          url,
          data: bodyless ? null : bodyText,
          // 4xx 不抛异常：交给下面决定是换头重试还是抛出可读错误
          options: Options(
            method: m,
            headers: h,
            contentType: bodyless
                ? null
                : (json ? Headers.jsonContentType : Headers.formUrlEncodedContentType),
            validateStatus: (s) => s != null && s < 500,
          ),
        );
      }
      var resp = await send(headers);
      var status = resp.statusCode ?? 0;
      if (status == 400 ||
          status == 401 ||
          status == 403 ||
          status == 406 ||
          status == 429) {
        // 换一套「桌面浏览器」身份再试一次：不少站点只放行 PC UA + Referer
        final retry = Map<String, String>.from(headers)
          ..['User-Agent'] = _desktopUa
          ..['Referer'] = _originOf(url)
          ..['Accept-Language'] = 'zh-CN,zh;q=0.9,en;q=0.8';
        resp = await send(retry);
        status = resp.statusCode ?? 0;
      }
      if (status >= 400) {
        throw RssHttpException(status, _originOf(url), url: url);
      }
      // 吸收登录/校验 cookie，后续请求（含规则引擎里的 java.ajax）共用
      if (source.enabledCookieJar) {
        SourceCookieStore.instance
            .ingestResponseHeader(url, resp.headers.value('set-cookie'));
      }
      return _decode(resp.data ?? const <int>[],
          resp.headers.value('content-type') ?? '');
    } finally {
      dio.close(force: true);
    }
  }

  static const String _desktopUa =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// `https://host/path` → `https://host/`
  static String _originOf(String url) {
    try {
      final u = Uri.parse(url.trim());
      if (u.hasScheme && u.host.isNotEmpty) return '${u.scheme}://${u.host}/';
    } catch (_) {}
    return '';
  }

  /// 按 charset 解码（content-type → 页面内 `charset=` → 兜底 utf8 / gbk）。
  ///
  /// 与阅读模块 `XiaoshuoHttp` 同一套思路：GBK 的 RSS/站点还不少，
  /// 直接 `utf8.decode` 会乱码，规则自然也就匹配不上了。
  static String _decode(List<int> bytes, String contentType) {
    if (bytes.isEmpty) return '';
    String? cs;
    final m = RegExp(r'charset=([^\s;]+)', caseSensitive: false)
        .firstMatch(contentType);
    if (m != null) cs = m.group(1);
    if (cs == null) {
      final head = bytes.length > 4096 ? bytes.sublist(0, 4096) : bytes;
      final ascii = String.fromCharCodes(head.map((b) => b < 128 ? b : 0x20));
      final i = ascii.toLowerCase().indexOf('charset=');
      if (i != -1) {
        cs = RegExp(r'^([a-zA-Z0-9_-]+)')
            .firstMatch(ascii.substring(i + 8).trimLeft())
            ?.group(1);
      }
    }
    final lower = (cs ?? '').toLowerCase();
    if (lower.contains('gb') || lower.contains('big5')) {
      try {
        return _stripBom(gbk.decode(bytes, allowMalformed: true));
      } catch (_) {/* 解不了就走下面的 utf8 兜底 */}
    }
    final utf8Str = utf8.decode(bytes, allowMalformed: true);
    // 出现替换字符 ⇒ 多半不是 utf8（GBK 的典型表现），再试一次 gbk
    if (utf8Str.contains('\uFFFD')) {
      try {
        final g = gbk.decode(bytes, allowMalformed: true);
        if (!g.contains('\uFFFD')) return _stripBom(g);
      } catch (_) {}
    }
    return _stripBom(utf8Str);
  }

  /// 去掉 UTF-8 BOM（`\uFEFF`）—— 带 BOM 的 XML/JSON 会让解析器**直接失败**，
  /// 表现成「没抓到内容」。
  static String _stripBom(String s) =>
      s.startsWith('\uFEFF') ? s.substring(1) : s;

  static Map<String, String> _headers(RssSource source) {
    final h = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 '
              '(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
    };
    final raw = source.header.trim();
    if (raw.isEmpty) return h;
    // Legado 同款：`header` 可以是 JSON 字符串，也可以是 `@js:` 动态求值
    // （返回 JSON 字符串）。yckceo / 影视聚合这类源的 header 全是 `@js:`，
    // 不执行就只剩默认 UA ⇒ 源站缺签名/UA 直接拒（表现 DioException unknown）。
    var jsonStr = raw;
    if (raw.startsWith('@js:')) {
      try {
        final evaluated = _ruleFor(source, '', source.url).getString(raw).trim();
        if (evaluated.isNotEmpty) jsonStr = evaluated;
      } catch (_) {/* 求值失败就用原值（大概率也解不出 JSON，等于没 header）*/}
    }
    try {
      final d = jsonDecode(jsonStr);
      if (d is Map) {
        d.forEach((k, v) => h['$k'] = '$v');
      }
    } catch (_) {}
    return h;
  }

  // ── URL / 时间 / HTML 工具 ──────────────────────────────────────

  /// 这个地址是否是"按页号翻页"的模板（含引用 `page` 的 `{{…}}` 表达式）。
  ///
  /// 认 `{{page}}` 和 `{{(page-1)*10}}` 两种写法 —— 后者不含字面子串
  /// `{{page}}`，所以必须按整段表达式里的 `page` 标识符判断，不能 `contains`。
  static bool isPagedUrl(String url) =>
      RegExp(r'\{\{[^}]*\bpage\b[^}]*\}\}').hasMatch(url);

  /// 渲染分类地址：`{{page}}` + `{{(page-1)*10}}` 这类**算术表达式**。
  ///
  /// 只认 `page`/`关键词` 与 `+ - * / ( )` 数字运算（够覆盖分享出来的源），
  /// 不引 JS —— 待求值表达式是数据，不是代码，没必要为此拉起 JS 引擎。
  static String resolveUrl(String template, String base, int page,
      {RssSource? source}) {
    var u = template.trim();
    if (u.isEmpty) u = base;
    final m = RegExp(r'\{\{([^}]*)\}\}');
    u = u.replaceAllMapped(m, (match) {
      final expr = match.group(1)!.trim();
      if (expr == 'page') return '$page';
      if (expr == 'key' || expr == 'keyword') return '';
      final v = _evalArith(expr, page);
      if (v != null) return '$v';
      // 非算术表达式（`{{source.getVariable("token")}}` 这类）交给 JS 引擎，
      // 与 Legado 的 sortUrl 语义一致；求值失败退回空串。
      if (source != null) {
        try {
          final js = expr.replaceAll(RegExp(r'\bpage\b'), '$page');
          return _ruleFor(source, '', base)
              .getString('@js:$js')
              .trim();
        } catch (_) {/* 落空串 */}
      }
      return '';
    });
    if (u.startsWith('http')) return u;
    return _absUrl(u, base);
  }

  /// 拆 `地址,{"method":"POST","body":"a=1","headers":{…}}`（Legado 写法）。
  ///
  /// 秀人岛 / 下厨房的搜索分类把 POST 参数直接写在 `sortUrl` 里，以前整串当
  /// URL 抓 ⇒ 必然失败。没有逗号+JSON 尾巴时按纯地址返回。
  static ({String url, String method, String body, Map<String, String> headers})
      splitRequestSpec(String raw) {
    final t = raw.trim();
    const noHeaders = <String, String>{};
    final m = RegExp(r'^([\s\S]*?),\s*(\{[\s\S]*\})$').firstMatch(t);
    if (m == null) {
      return (url: t, method: 'GET', body: '', headers: noHeaders);
    }
    final urlPart = m.group(1)!.trim();
    try {
      final d = jsonDecode(m.group(2)!);
      if (d is Map) {
        final method = (d['method'] ?? 'GET').toString().trim().toUpperCase();
        final body = (d['body'] ?? '').toString();
        final hs = <String, String>{};
        final bh = d['headers'];
        if (bh is Map) bh.forEach((k, v) => hs['$k'] = '$v');
        return (
          url: urlPart,
          method: method.isEmpty ? 'GET' : method,
          body: body,
          headers: hs,
        );
      }
    } catch (_) {/* 不是合法 JSON ⇒ 当纯地址 */}
    return (url: t, method: 'GET', body: '', headers: noHeaders);
  }

  /// 极简算术求值（只允许 `page` 和数字 + `+-*/()`）。
  static num? _evalArith(String expr, int page) {
    final s = expr.replaceAll('page', '$page').replaceAll(' ', '');
    if (s.isEmpty || !RegExp(r'^[0-9+\-*/().]+$').hasMatch(s)) return null;
    try {
      return _Parser(s).parse();
    } catch (_) {
      return null;
    }
  }

  /// 把 `1600000000`（unix 秒/毫秒）变成可读时间；已经是文本的原样返回。
  static String friendlyTime(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return '';
    if (!RegExp(r'^\d{9,13}$').hasMatch(t)) return t;
    var ms = int.parse(t);
    if (t.length <= 10) ms *= 1000; // 秒 → 毫秒
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final diff = now.difference(d);
    String two(int n) => n.toString().padLeft(2, '0');
    if (diff.inMinutes < 1 && !diff.isNegative) return '刚刚';
    if (diff.inMinutes < 60 && !diff.isNegative) return '${diff.inMinutes}分钟前';
    if (diff.inHours < 24 && !diff.isNegative) {
      return '${two(d.hour)}:${two(d.minute)}';
    }
    if (diff.inDays < 2 && !diff.isNegative) {
      return '昨天 ${two(d.hour)}:${two(d.minute)}';
    }
    if (d.year == now.year) return '${two(d.month)}-${two(d.day)}';
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  static String _absUrl(String u, String base) {
    final t = u.trim();
    if (t.isEmpty) return '';
    if (t.startsWith('http')) return t;
    if (t.startsWith('//')) return 'https:$t';
    try {
      return Uri.parse(base).resolve(t).toString();
    } catch (_) {
      return t;
    }
  }

  static String _clean(String s) => s
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .trim();

  /// HTML → 纯文本（按块级标签换行）。列表摘要/正文都用它。
  static String _stripHtml(String html) {
    final t = html.trim();
    if (t.isEmpty) return '';
    if (!t.contains('<')) return t;
    try {
      final doc = html_parser.parse(t);
      doc
          .querySelectorAll('script,style,noscript,iframe,svg,form,video,audio')
          .forEach((e) => e.remove());
      final buf = StringBuffer();
      _walk(doc.body ?? doc.documentElement, buf);
      return _tidy(buf.toString());
    } catch (_) {
      return _tidy(t.replaceAll(RegExp(r'<[^>]+>'), ''));
    }
  }

  static const Set<String> _blockTags = {
    'p', 'div', 'section', 'article', 'li', 'br', 'h1', 'h2', 'h3', 'h4', 'h5',
    'blockquote', 'tr', 'figure', 'figcaption', 'pre',
  };

  static void _walk(dom.Node? node, StringBuffer buf) {
    if (node == null) return;
    for (final child in node.nodes) {
      if (child is dom.Text) {
        final t = child.text.replaceAll(RegExp(r'[ \t\u00a0]+'), ' ');
        if (t.trim().isNotEmpty) buf.write(t.trim());
      } else if (child is dom.Element) {
        final tag = (child.localName ?? '').toLowerCase();
        final block = _blockTags.contains(tag);
        if (block && buf.isNotEmpty && !buf.toString().endsWith('\n')) {
          buf.write('\n');
        }
        if (tag == 'img') {
          // 图片不参与纯文本，但保留一个占位换行，避免文字挤在一起
          continue;
        }
        _walk(child, buf);
        if (block) buf.write('\n');
      }
    }
  }

  static String _tidy(String s) => s
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r' *\n *'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();

  /// 正文提取：去脚本/样式/导航/页脚，取文字最多的那个块。
  static String extractArticleText(String html) {
    try {
      final doc = html_parser.parse(html);
      doc
          .querySelectorAll(
              'script,style,noscript,iframe,svg,form,nav,header,footer,aside')
          .forEach((e) => e.remove());
      dom.Element? best;
      var bestLen = 0;
      for (final sel in ['article', 'main', '.content', '#content', '.post', 'body']) {
        for (final el in doc.querySelectorAll(sel)) {
          final len = el.text.trim().length;
          if (len > bestLen) {
            bestLen = len;
            best = el;
          }
        }
        if (best != null && bestLen > 200) break;
      }
      final buf = StringBuffer();
      _walk(best ?? doc.body ?? doc.documentElement, buf);
      final text = _tidy(buf.toString());
      return text.isEmpty ? '（这个页面没能提取出正文，可用"用网页打开"看原文）' : text;
    } catch (e) {
      return '正文提取失败：${_short(e)}';
    }
  }

  /// 第一张 http 图片（正文配图）。
  static String _firstImage(String html, String base) {
    try {
      final doc = html_parser.parse(html);
      for (final img in doc.querySelectorAll('img')) {
        final src = (img.attributes['src'] ?? img.attributes['data-src'] ?? '').trim();
        if (src.startsWith('http')) return src;
        if (src.startsWith('/')) {
          final u = _absUrl(src, base);
          if (u.startsWith('http')) return u;
        }
      }
    } catch (_) {}
    return '';
  }

  // ── XML 小工具 ──────────────────────────────────────────────────

  static String _txt(XmlElement n, String tag) {
    for (final e in n.children.whereType<XmlElement>()) {
      if (e.name.local.toLowerCase() == tag.toLowerCase()) {
        return (e.innerText).trim();
      }
    }
    return '';
  }

  /// 取子元素的**原始内部 XML**（保留 HTML 标签）。
  ///
  /// [tags] 按优先级依次尝试；`content:encoded` 这样的带前缀标签按**本地名**
  /// （`encoded`）匹配即可命中。
  static String _rawOf(XmlElement n, List<String> tags) {
    for (final tag in tags) {
      for (final e in n.children.whereType<XmlElement>()) {
        if (e.name.local.toLowerCase() == tag.toLowerCase()) {
          final s = e.innerXml.trim();
          if (s.isNotEmpty) return _unwrapCdata(s);
        }
      }
    }
    return '';
  }

  /// 去掉 `<![CDATA[ … ]]>` 外壳。
  ///
  /// `innerXml` 会把 CDATA 原样序列化成 `<![CDATA[<p>…</p>]]>`；不剥掉的话
  /// 正文 HTML 塞给 WebView 会被当成「伪注释」→ 正文整段不显示（兼容性坑）。
  static String _unwrapCdata(String s) {
    var out = s.trim();
    final m = RegExp(r'^<!\[CDATA\[([\s\S]*)\]\]>$').firstMatch(out);
    if (m != null) out = m.group(1)!;
    out = out.replaceAll('<![CDATA[', '').replaceAll(']]>', '');
    return out.trim();
  }

  /// Atom 的 link 在属性里：`<link rel="alternate" href="..."/>`
  static String _linkOf(XmlElement n) {
    final direct = _txt(n, 'link');
    if (direct.isNotEmpty) return direct;
    for (final e in n.children.whereType<XmlElement>()) {
      if (e.name.local.toLowerCase() != 'link') continue;
      final rel = (e.getAttribute('rel') ?? 'alternate').toLowerCase();
      if (rel == 'alternate' || rel.isEmpty) {
        return (e.getAttribute('href') ?? '').trim();
      }
    }
    return '';
  }

  static String _imageOf(XmlElement n, String base) {
    // enclosure / media:content / media:thumbnail / <image>
    for (final e in n.children.whereType<XmlElement>()) {
      final tag = e.name.local.toLowerCase();
      if (tag == 'enclosure' || tag == 'content' || tag == 'thumbnail') {
        final u = (e.getAttribute('url') ?? e.getAttribute('href') ?? '').trim();
        if (u.isNotEmpty) return _absUrl(u, base);
      }
    }
    final desc = _txt(n, 'description').isNotEmpty
        ? _txt(n, 'description')
        : _txt(n, 'content');
    return _firstImage(desc, base);
  }

  static String _short(Object e) {
    final s = e.toString().replaceAll('\n', ' ');
    return s.length > 80 ? s.substring(0, 80) : s;
  }
}

/// HTTP 状态异常（可读文案：不再把 DioException 原文甩到界面上）。
class RssHttpException implements Exception {
  RssHttpException(this.statusCode, this.origin, {this.url = ''});

  final int statusCode;
  final String origin;

  /// 完整请求地址（排障用：同一站点不同路径失败原因可能不同）
  final String url;

  String get hint {
    switch (statusCode) {
      case 401:
      case 403:
        return '站点拒绝访问（$statusCode）—— 可能需要登录、换 UA 或代理';
      case 404:
        return '地址不存在（404）';
      case 429:
        return '请求太频繁（429），稍后再试';
      default:
        return '请求失败（$statusCode）';
    }
  }

  @override
  String toString() => url.isEmpty ? hint : '$hint（$url）';
}

/// 极简算术求值器（递归下降；只允许数字与 `+ - * / ( )`）。
class _Parser {
  _Parser(this.s);

  final String s;
  int i = 0;

  num parse() {
    final v = _expr();
    // ⚠️ 只能在**最顶层**校验"整串用完"：`_expr` 会被括号递归调用，
    // 那时游标停在 `)` 上，在此处校验会把 `(page-1)*10` 整条判成非法 ✗
    if (i != s.length) throw const FormatException('bad expr');
    return v;
  }

  num _expr() {
    var v = _term();
    while (i < s.length && (s[i] == '+' || s[i] == '-')) {
      final op = s[i++];
      final r = _term();
      v = op == '+' ? v + r : v - r;
    }
    return v;
  }

  num _term() {
    var v = _factor();
    while (i < s.length && (s[i] == '*' || s[i] == '/')) {
      final op = s[i++];
      final r = _factor();
      if (op == '*') {
        v = v * r;
      } else {
        if (r == 0) throw const FormatException('div by zero');
        v = v / r;
      }
    }
    return v;
  }

  num _factor() {
    if (s[i] == '(') {
      i++;
      final v = _expr();
      if (i < s.length && s[i] == ')') i++;
      return v;
    }
    if (s[i] == '-') {
      i++;
      return -_factor();
    }
    final start = i;
    while (i < s.length && (RegExp(r'[0-9.]').hasMatch(s[i]))) {
      i++;
    }
    if (start == i) throw const FormatException('bad number');
    return num.parse(s.substring(start, i));
  }
}
