// lib/reading/source/legado_to_config.dart
//
// ✅ **Legado 书源（扁平字段）→ `BookSiteConfig`（配置字段）**（本轮重构 ✓）
//
// 为什么需要它 ✗（这是"书源能不能用"的**最后一环** ✓）：
//   · 书源页原来**全部**交给 **Node 引擎**跑 ✗（`book_source_service.dart` 发
//     `bsSearch` / `bsExplore` / `bsBookInfo` / `bsToc` / `bsContent` ✓）
//   · 而 Node 引擎的网络栈（OpenSSL ✓）在不少站点上被**拒**✗：
//     实测到的失败 = `HTTP 400` ✓ `read ECONNRESET` ✓ `socket hang up` ✓
//     `SSL alert 40（握手被拒）`✓ `certificate has expired`✓
//     ⇒ 这些**不是源死了** ✗（源真死会是 DNS 失败/404 ✓），是**网络栈/防护**问题 ✓
//   · 而 **Dart 侧本来就有一套完整实现** ✓（`ConfigBookSource` ✓）：
//     搜索 ✓ 详情 ✓ 目录（含分页 ✓）✓ 正文 ✓ + **WebView 兜底** ✓
//     （`config_book_source.dart:134 if (site.useWebViewFetch) → WebViewImageFetcher().fetchHtml(url)`
//      ✓✓ —— 真浏览器栈 ✓ 反爬/Cloudflare 能过 ✓）
//     + 我此前修好的**双花括号占位符** ✓ 与**浏览器请求头** ✓
//   ⇒ ⇒ 只要把 Legado 源**转成 `BookSiteConfig`** ✓ 就能让书源**走 Dart** ✓
//     ⇒ 与母项目同款网络栈 ✓（这正是"别人 631 基本都能用"的原因 ✓）
//
// 用法 ✓：`ConfigBookSource(legadoToConfig(rawBookSourceJson)).search('剑来')`
//
// ℹ️ 复杂规则（`@js:` ✓ 嵌套 ✓）Dart 解析不了 ✗ ⇒ **由调用方回落 Node 引擎** ✓（不硬撑 ✓）
import 'book_site_config.dart';

/// 源的规则里是否**自己要求**走 WebView ✓
///
/// Legado 允许在规则 URL 后带内联配置 ✓，如
/// `https://site.com/search/{{key}},{"webView":true}` ✓
/// ⇒ 这种源**明确需要浏览器内核** ✓（真浏览器栈才拿得到内容 ✓）
/// ⇒ 只有它们才走 WebView ✓；其余**走直连**（Dio ✓ 快 ✓）
///
/// ⚠️ **为什么默认不能一律开 WebView** ✗（我此前写成默认 true ✗ 是错的 ✓）：
///   `WebViewImageFetcher` 的隐藏 WebView 需要 `buildHiddenWebView()` 挂进根 Stack ✓，
///   而**全仓库无人调用它** ✗（实测：只有定义 `:83` + 注释 `:11` ✓）
///   ⇒ 且单页 **30 秒超时** ✗（`webview_image_fetcher.dart:302/:392/:578` ✓）
///   ⇒ 一律走 WebView = **每次请求都可能卡 30 秒 / 失败** ✗ ⇒ 比不改还糟 ✗
bool _wantsWebView(Map<String, dynamic> json) {
  const keys = [
    'ruleSearchUrl',
    'ruleExploreUrl',
    'ruleBookInfoUrl',
    'ruleTocUrl',
    'ruleContentUrl',
    'ruleBookContent',
  ];
  for (final k in keys) {
    final v = json[k];
    if (v is String && v.contains('webView')) {
      // 宽松匹配 ✓：`{"webView":true}` / `"webView": true` / `webView:true` 都算 ✓
      if (v.contains('true')) return true;
    }
  }
  return false;
}

/// 把一个 **Legado 书源 JSON** 转成 `BookSiteConfig` ✓
///
/// [json] = 源文件里那一个源对象 ✓（键是 `bookSourceName` / `ruleSearchUrl` / … ✓）
/// [useWebView] = 是否走 WebView 抓渲染后 HTML ✓
///   · **默认（不传）= 按源自己的声明自动判断** ✓（`_wantsWebView` ✓）
///     ⇒ 只有写了 `{"webView":true}` 的源才走 ✓（那些源**必须**走 ✓ 否则拿不到内容 ✗）
///     ⇒ 其余走 **Dio 直连** ✓（快 ✓ —— 直连失败/空结果时，调用方还会**回落 Node** ✓ 兜底 ✓）
///   · 传 `true` / `false` 可覆盖 ✓
BookSiteConfig legadoToConfig(
  Map<String, dynamic> json, {
  bool? useWebView,
}) {
  final webView = useWebView ?? _wantsWebView(json);
  String? s(String key) {
    final v = json[key];
    if (v == null) return null;
    final t = v.toString().trim();
    return t.isEmpty ? null : t;
  }

  Map<String, String> hdr() {
    final raw = json['header'];
    if (raw is Map) {
      final out = <String, String>{};
      raw.forEach((k, v) {
        if (k == null || v == null) return;
        out[k.toString()] = v.toString();
      });
      return out;
    }
    return const {};
  }

  return BookSiteConfig(
    name: s('bookSourceName') ?? '',
    url: s('bookSourceUrl') ?? '',
    icon: null,
    // ── 搜索（Legado 扁平 → 配置字段 ✓ 一一对应 ✓）──────────────
    searchUrl: s('ruleSearchUrl'),
    searchResultDom: s('ruleSearchList'),
    searchTitleDom: s('ruleSearchName'),
    searchAuthorDom: s('ruleSearchAuthor'),
    searchCoverDom: s('ruleSearchCoverUrl'),
    searchBookUrlDom: s('ruleSearchNoteUrl'),
    searchIntroDom: s('ruleSearchIntroduce'),
    searchLastChapterDom: s('ruleSearchLastChapter'),
    // ── 详情 ──────────────────────────────────────────────
    bookNameDom: s('ruleBookName'),
    bookCoverDom: s('ruleCoverUrl'),
    bookAuthorDom: s('ruleBookAuthor'),
    bookDescDom: s('ruleIntroduce'),
    bookLastChapterDom: s('ruleBookLastChapter'),
    // ── 目录 ──────────────────────────────────────────────
    // ⚠️ 确认过的映射 ✓：`toc()` 内部走 `_parseToc` ✓，**列表项**选择器 = `tocLinkDom` ✓
    //   ⇒ `ruleChapterList`（列表 ✓）→ `tocLinkDom` ✓；`ruleChapterName`（章节名 ✓）→ `tocNameDom` ✓
    //   ℹ️ `ruleContentUrl`（章节链接规则 ✓）在常见形态（`tag.a@href` ✓）下
    //     由"列表项自身 href"天然满足 ✓；复杂形态 ⇒ 由调用方**回落 Node** ✓
    tocLinkDom: s('ruleChapterList'),
    tocNameDom: s('ruleChapterName'),
    // ── 正文 ──────────────────────────────────────────────
    contentDom: s('ruleBookContent'),
    // ── 网络 ──────────────────────────────────────────────
    pageEncoding: s('rulePageEncoding') ?? s('pageEncoding'),
    useWebViewFetch: webView,
    header: hdr(),
  );
}

/// 这个源是否**必须**走 Node 引擎 ✓（Dart 跑不了 `@js:` ✓ / 或规则明显是 JS ✓）
///
/// 调用方在"先 Dart、失败回落"之外，也可以用它在**动手前**判断 ✓ 省一次无谓请求 ✓
bool legadoNeedsNode(Map<String, dynamic> json) {
  const keys = [
    'ruleSearchUrl',
    'ruleSearchList',
    'ruleSearchName',
    'ruleSearchAuthor',
    'ruleSearchCoverUrl',
    'ruleSearchNoteUrl',
    'ruleBookName',
    'ruleBookAuthor',
    'ruleCoverUrl',
    'ruleIntroduce',
    'ruleBookLastChapter',
    'ruleChapterList',
    'ruleChapterName',
    'ruleContentUrl',
    'ruleBookContent',
  ];
  for (final k in keys) {
    final v = json[k];
    if (v is String && v.contains('@js:')) return true;
    if (v is String && v.contains('<js>')) return true;
  }
  return false;
}
