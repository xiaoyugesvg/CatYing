// 配置驱动的小说站点模型（明文 JSON + CSS 选择器，与漫画源 SiteConfig 同款体系）。
//
// 顶层 JSON: {"version":1,"sources":[{"type":"config","config":{...}}, ...]}
// - type=config: config 体即 BookSiteConfig 字段，id 派生为 config:${name}
//   （对齐 ConfigBookSource.id，currentBookSourceId 持久化依赖此一致性）
//
// 设计：搜索/详情/目录/正文全部由 CSS 选择器配置驱动，导入直接吃明文 json，
// 无任何加密/JS 规则（不兼容阅读 3.0/Legado 的 rule* 字段）。

/// 单个小说站点配置。
class BookSiteConfig {
  final String name;
  final String url;
  final String? icon;

  // ── 搜索 ─────────────────────────────────────────────────────
  /// 搜索 URL 模板：{q} 关键词、{page} 页码
  final String? searchUrl;
  final String? searchResultDom; // 搜索结果项选择器
  final String? searchTitleDom; // 书名
  final String? searchAuthorDom; // 作者
  final String? searchCoverDom; // 封面 img
  final String? searchBookUrlDom; // 详情链接选择器（空=结果项自身取 href）
  final String? searchIntroDom; // 简介
  final String? searchLastChapterDom; // 最新章节
  final String? searchEncoding; // 搜索关键词编码（gbk/gb2312/utf-8）
  final int searchPageStart; // {page} 起始页码（默认 1）

  // ── 详情页 ───────────────────────────────────────────────────
  final String? bookNameDom;
  final String? bookCoverDom;
  final String? bookAuthorDom;
  final String? bookDescDom;
  final String? bookLastChapterDom;

  // ── 目录 ─────────────────────────────────────────────────────
  final String? tocNameDom;
  final String? tocLinkDom;
  final String? tocUrlPattern; // 章节链接 href 必须包含的片段（空=不过滤）
  final String? tocPageUrl; // 目录分页模板 {base} + {page}
  final String? tocPageBaseDom; // 分页基础 URL 选择器（空=用详情页 URL）
  final String? tocPageCountDom; // 总页数选择器（取最大数字；空=不分页）
  final int tocOrder; // 0=倒序 1=正序

  // ── 正文 ─────────────────────────────────────────────────────
  final String? contentDom; // 正文容器
  final String? contentRemoveDoms; // 去噪选择器（空格分隔多个）
  final String? contentNextDom; // 正文下一页链接选择器
  final int contentMaxPages; // 正文翻页上限（防死循环，默认 10）

  // ── 通用 ─────────────────────────────────────────────────────
  final String? pageEncoding; // 页面响应编码（默认 utf-8；Empire CMS 站=gbk）
  final bool useWebViewFetch; // true=走 WebView 抓渲染后 HTML（Cloudflare 防护站）
  final Map<String, String> header; // 自定义请求头

  const BookSiteConfig({
    required this.name,
    required this.url,
    this.icon,
    this.searchUrl,
    this.searchResultDom,
    this.searchTitleDom,
    this.searchAuthorDom,
    this.searchCoverDom,
    this.searchBookUrlDom,
    this.searchIntroDom,
    this.searchLastChapterDom,
    this.searchEncoding,
    this.searchPageStart = 1,
    this.bookNameDom,
    this.bookCoverDom,
    this.bookAuthorDom,
    this.bookDescDom,
    this.bookLastChapterDom,
    this.tocNameDom,
    this.tocLinkDom,
    this.tocUrlPattern,
    this.tocPageUrl,
    this.tocPageBaseDom,
    this.tocPageCountDom,
    this.tocOrder = 1,
    this.contentDom,
    this.contentRemoveDoms,
    this.contentNextDom,
    this.contentMaxPages = 10,
    this.pageEncoding,
    this.useWebViewFetch = false,
    this.header = const {},
  });

  factory BookSiteConfig.fromJson(Map<String, dynamic> j) => BookSiteConfig(
    name: (j['name'] ?? '').toString(),
    url: (j['url'] ?? '').toString(),
    icon: j['icon'] as String?,
    searchUrl: j['search_url'] as String?,
    searchResultDom: j['search_result_dom'] as String?,
    searchTitleDom: j['search_title_dom'] as String?,
    searchAuthorDom: j['search_author_dom'] as String?,
    searchCoverDom: j['search_cover_dom'] as String?,
    searchBookUrlDom: j['search_book_url_dom'] as String?,
    searchIntroDom: j['search_intro_dom'] as String?,
    searchLastChapterDom: j['search_last_chapter_dom'] as String?,
    searchEncoding: j['search_encoding'] as String?,
    searchPageStart: (j['search_page_start'] as num?)?.toInt() ?? 1,
    bookNameDom: j['book_name_dom'] as String?,
    bookCoverDom: j['book_cover_dom'] as String?,
    bookAuthorDom: j['book_author_dom'] as String?,
    bookDescDom: j['book_desc_dom'] as String?,
    bookLastChapterDom: j['book_last_chapter_dom'] as String?,
    tocNameDom: j['toc_name_dom'] as String?,
    tocLinkDom: j['toc_link_dom'] as String?,
    tocUrlPattern: j['toc_url_pattern'] as String?,
    tocPageUrl: j['toc_page_url'] as String?,
    tocPageBaseDom: j['toc_page_base_dom'] as String?,
    tocPageCountDom: j['toc_page_count_dom'] as String?,
    tocOrder: (j['toc_order'] as num?)?.toInt() ?? 1,
    contentDom: j['content_dom'] as String?,
    contentRemoveDoms: j['content_remove_doms'] as String?,
    contentNextDom: j['content_next_dom'] as String?,
    contentMaxPages: (j['content_max_pages'] as num?)?.toInt() ?? 10,
    pageEncoding: j['page_encoding'] as String?,
    useWebViewFetch: (j['use_webview_fetch'] as bool?) ?? false,
    header: (j['header'] as Map?)?.map(
      (k, v) => MapEntry(k.toString(), v.toString()),
    ) ?? const {},
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'url': url,
    'icon': icon,
    'search_url': searchUrl,
    'search_result_dom': searchResultDom,
    'search_title_dom': searchTitleDom,
    'search_author_dom': searchAuthorDom,
    'search_cover_dom': searchCoverDom,
    'search_book_url_dom': searchBookUrlDom,
    'search_intro_dom': searchIntroDom,
    'search_last_chapter_dom': searchLastChapterDom,
    'search_encoding': searchEncoding,
    'search_page_start': searchPageStart,
    'book_name_dom': bookNameDom,
    'book_cover_dom': bookCoverDom,
    'book_author_dom': bookAuthorDom,
    'book_desc_dom': bookDescDom,
    'book_last_chapter_dom': bookLastChapterDom,
    'toc_name_dom': tocNameDom,
    'toc_link_dom': tocLinkDom,
    'toc_url_pattern': tocUrlPattern,
    'toc_page_url': tocPageUrl,
    'toc_page_base_dom': tocPageBaseDom,
    'toc_page_count_dom': tocPageCountDom,
    'toc_order': tocOrder,
    'content_dom': contentDom,
    'content_remove_doms': contentRemoveDoms,
    'content_next_dom': contentNextDom,
    'content_max_pages': contentMaxPages,
    'page_encoding': pageEncoding,
    'use_webview_fetch': useWebViewFetch,
    if (header.isNotEmpty) 'header': header,
  };
}
