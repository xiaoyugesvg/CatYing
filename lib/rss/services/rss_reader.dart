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

import '../../reading/novel_source/analyze/analyze_rule.dart';
import '../../reading/novel_source/analyze/cookie_store.dart';
import '../../reading/novel_source/analyze/js_engine.dart';
import '../../reading/source/global_proxy.dart';
import '../models/rss_article.dart';
import '../models/rss_source.dart';
import 'rss_store.dart';

/// 抓一页的结果：文章列表 + 下一页地址（空 = 到底了）+ 是否"其实是个网页"。
typedef RssFetchResult = ({List<RssArticle> articles, String nextUrl, bool siteLike});

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
    final url = (pageUrl != null && pageUrl.trim().isNotEmpty)
        ? pageUrl.trim()
        : resolveUrl(ch.url, source.url, page);
    final body = await _body(source, url, ignoreCache: ignoreCache);
    final arts = _blacklist(source, parseArticles(source, body, url));

    // `preload`：列表就绪后**预取第一条的正文**进缓存 —— 用户在列表里最可能
    // 点开第一条；配合 `cacheFirst` 就是"点开秒开"。
    if (source.preload && page == 1 && arts.isNotEmpty) {
      unawaited(fetchContent(source, arts.first).catchError(
          (_) => (text: '', image: '', isHtml: false)));
    }

    return (
      articles: arts,
      nextUrl: _nextPageUrl(source, body, url),
      // 兜底判定"这个地址其实是个网页"：**没有列表规则** + 一条文章都没解析出来
      // + 返回体不像 feed（没有 <rss>/<feed>/<channel>/<item> 标签）。
      // ⇒ 用户那份 txt 里 5 条站点型源（源仓库 / Yiove / 使用文档…）即使丢了
      //   `singleUrl` 标记也能被认出来，交给上层**内嵌网页直开**，
      //   而不是甩一句"没有抓到内容"（用户 2026-10-15 反复报的那句）。
      siteLike: !source.hasRules && arts.isEmpty && !_looksLikeFeed(body),
    );
  }

  /// 返回体像不像订阅源（RSS 2.0 / Atom）。
  static bool _looksLikeFeed(String body) {
    if (body.isEmpty) return false;
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

  /// 取响应体：命中缓存就直接用（仅当 `cacheFirst` 且未强制刷新），否则抓取并回填。
  static Future<String> _body(
    RssSource source,
    String url, {
    bool ignoreCache = false,
  }) async {
    final key = '${source.id}|$url';
    if (source.cacheFirst && !ignoreCache) {
      final hit = _bodyCache[key];
      if (hit != null) return hit;
    }
    final body = await _get(url, source);
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
    XmlDocument doc;
    try {
      doc = XmlDocument.parse(body);
    } catch (_) {
      return out;
    }
    // RSS 2.0 用 item、Atom 用 entry；有些站还会带命名空间前缀
    final nodes = <XmlElement>[
      ...doc.findAllElements('item'),
      ...doc.findAllElements('entry'),
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

  /// 取正文。返回 (内容, 文章里的第一张图, 是不是 HTML)。
  ///
  /// [isHtml] 为 true 时 `text` 字段装的是**原始 HTML**，调用方要用网页渲染
  /// （用户给的「影视聚合(资源站)」整页就是个 HLS 播放器模板）。
  static Future<({String text, String image, bool isHtml})> fetchContent(
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
        );
      }
      final body = await _body(source, article.link);
      if (source.hasRules && (source.ruleContent ?? '').trim().isNotEmpty) {
        final out = _ruleFor(source, body, article.link)
            .getString(source.ruleContent);
        if (out.contains('<') && !forceText) {
          return (
            text: out,
            image: _firstImage(out, article.link),
            isHtml: true,
          );
        }
        final text = _stripHtml(out);
        if (text.trim().length > 40) {
          return (
            text: forceHtml ? out : text,
            image: _firstImage(out, article.link),
            isHtml: forceHtml,
          );
        }
      }
      return (
        text: extractArticleText(body),
        image: _firstImage(body, article.link),
        isHtml: false,
      );
    } catch (e) {
      return (text: '正文抓取失败：${_short(e)}', image: '', isHtml: false);
    }
  }

  // ── 网络 ────────────────────────────────────────────────────────

  static Future<String> _get(String url, RssSource source) async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      // ⚠️ 取**字节**自己解编码：中文站/RSS 常见 GBK，Dio 默认按 utf8 解会整篇乱码
      responseType: ResponseType.bytes,
      followRedirects: true,
      headers: _headers(source),
    ));
    // ⚠️ **必须**套全局代理（「设置 → 网络代理」）—— 全项目 27 处请求都这么做
    //   （书源 / 漫画源 / z-library / 豆瓣…）。RSS 原来漏了这一句 ⇒ 用户开了
    //   代理后 RSS **每个源都失败**，报的就是 `DioException [unknown]: null`
    //   （用户 2026-10-15 实测）。
    applyGlobalProxy(dio);
    try {
      final resp = await dio.get<List<int>>(url);
      return _decode(resp.data ?? const <int>[],
          resp.headers.value('content-type') ?? '');
    } finally {
      dio.close(force: true);
    }
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
        return gbk.decode(bytes, allowMalformed: true);
      } catch (_) {/* 解不了就走下面的 utf8 兜底 */}
    }
    final utf8Str = utf8.decode(bytes, allowMalformed: true);
    // 出现替换字符 ⇒ 多半不是 utf8（GBK 的典型表现），再试一次 gbk
    if (utf8Str.contains('\uFFFD')) {
      try {
        final g = gbk.decode(bytes, allowMalformed: true);
        if (!g.contains('\uFFFD')) return g;
      } catch (_) {}
    }
    return utf8Str;
  }

  static Map<String, String> _headers(RssSource source) {
    final h = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 '
              '(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
    };
    final raw = source.header.trim();
    if (raw.isEmpty) return h;
    try {
      final d = jsonDecode(raw);
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
  static String resolveUrl(String template, String base, int page) {
    var u = template.trim();
    if (u.isEmpty) u = base;
    final m = RegExp(r'\{\{([^}]*)\}\}');
    u = u.replaceAllMapped(m, (match) {
      final expr = match.group(1)!.trim();
      if (expr == 'page') return '$page';
      if (expr == 'key' || expr == 'keyword') return '';
      final v = _evalArith(expr, page);
      return v == null ? '' : '$v';
    });
    if (u.startsWith('http')) return u;
    return _absUrl(u, base);
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
          if (s.isNotEmpty) return s;
        }
      }
    }
    return '';
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
