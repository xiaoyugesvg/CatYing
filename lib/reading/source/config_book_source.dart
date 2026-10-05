// 配置驱动的小说源引擎：按 BookSiteConfig（CSS 选择器）实现
// 搜索 / 详情 / 目录 / 正文 全部抓取逻辑。
//
// 与漫画源 ConfigMangaSource 同款体系：Dio + html 包解析，支持 GBK/GB2312
// 编码、正文翻页、Cloudflare 站走 WebView 抓渲染后 HTML。
// 不执行任何 JS 规则（Legado @js: 等一概不碰）——规则全在 CSS 选择器里。

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart';

import 'book_site_config.dart';
import 'webview_image_fetcher.dart';
import 'global_proxy.dart';

/// config 源不支持搜索时抛出（UI 提示用 URL 兜底入口）。
class BookUnsupportedSearchError implements Exception {
  final String message;
  BookUnsupportedSearchError(this.message);
  @override
  String toString() => message;
}

/// 配置驱动的单本小说（搜索结果 / 详情共用）。
class BookSiteResult {
  const BookSiteResult({
    required this.title,
    this.author = '',
    this.cover = '',
    this.bookUrl = '',
    this.intro = '',
    this.lastChapter = '',
  });

  final String title;
  final String author;
  final String cover;
  final String bookUrl;
  final String intro;
  final String lastChapter;

  BookSiteResult copyWith({
    String? title,
    String? author,
    String? cover,
    String? bookUrl,
    String? intro,
    String? lastChapter,
  }) => BookSiteResult(
    title: title ?? this.title,
    author: author ?? this.author,
    cover: cover ?? this.cover,
    bookUrl: bookUrl ?? this.bookUrl,
    intro: intro ?? this.intro,
    lastChapter: lastChapter ?? this.lastChapter,
  );
}

/// 配置驱动的单章。
class BookSiteChapter {
  const BookSiteChapter({required this.name, required this.url});
  final String name;
  final String url;
}

/// 配置驱动的小说源。
class ConfigBookSource {
  final BookSiteConfig site;

  /// 单源代理 "host:port"，空串 = 直连。
  final String proxy;

  ConfigBookSource(this.site, {this.proxy = ''});

  /// id 派生规则与漫画源 config 源一致（currentBookSourceId 依赖）。
  String get id => 'config:${site.name}';

  String get name => site.name;

  void _log(String message) => debugPrint('[ConfigBookSource:$name] $message');

  late final Dio _dio = _createDio();

  Dio _createDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        followRedirects: true,
      ),
    );
    final p = proxy.trim();
    if (p.isNotEmpty) {
      applyProxy(dio, p);
    } else {
      // 单源未配代理 → 回退全局代理（通用设置 → 网络代理）
      applyGlobalProxy(dio);
    }
    return dio;
  }

  Map<String, String> get _uaHeaders => {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    ...site.header,
  };

  /// 相对 URL（或完整 URL）解析为绝对 URL，base 默认站点首页。
  String _resolveUrl(String idOrUrl, [String? base]) {
    if (idOrUrl.startsWith('http://') || idOrUrl.startsWith('https://')) {
      return idOrUrl;
    }
    return Uri.parse(base ?? site.url).resolve(idOrUrl).toString();
  }

  /// 抓 HTML（支持编码 + WebView 兜底）。
  Future<String> _fetchHtml(String url) async {
    if (site.useWebViewFetch) {
      return WebViewImageFetcher().fetchHtml(url);
    }
    final resp = await _dio.get<List<int>>(
      url,
      options: Options(
        headers: _uaHeaders,
        responseType: ResponseType.bytes,
      ),
    );
    final bytes = resp.data ?? const <int>[];
    final enc = (site.pageEncoding ?? 'utf-8').toLowerCase();
    if (enc == 'gb2312' || enc == 'gbk') {
      return gbk_bytes.decode(bytes);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 关键词按源编码 percent-encode。
  String _encodeQuery(String q) {
    final enc = (site.searchEncoding ?? 'utf-8').toLowerCase();
    if (enc == 'gb2312' || enc == 'gbk') {
      final sb = StringBuffer();
      for (final b in gbk_bytes.encode(q)) {
        sb.write('%');
        sb.write(b.toRadixString(16).padLeft(2, '0'));
      }
      return sb.toString();
    }
    return Uri.encodeQueryComponent(q);
  }

  // ── 搜索 ─────────────────────────────────────────────────────

  /// 用源搜索（返回书籍列表）。
  Future<List<BookSiteResult>> search(String query, {int page = 1}) async {
    final tpl = site.searchUrl;
    if (tpl == null || tpl.isEmpty) {
      throw BookUnsupportedSearchError('源「${site.name}」暂不支持搜索');
    }
    var url = tpl
        .replaceAll('{q}', _encodeQuery(query))
        .replaceAll('{page}', (page + site.searchPageStart - 1).toString());
    if (!url.startsWith('http')) url = _resolveUrl(url);
    final html = await _fetchHtml(url);
    final doc = parse(html);
    final out = <BookSiteResult>[];
    final resultDom = site.searchResultDom;
    if (resultDom != null && resultDom.isNotEmpty) {
      for (final r in doc.querySelectorAll(resultDom)) {
        final title = _elText(r, site.searchTitleDom);
        if (title.isEmpty) continue;
        final href = site.searchBookUrlDom != null &&
            site.searchBookUrlDom!.isNotEmpty
            ? (_elAttr(r, site.searchBookUrlDom, 'href') ?? '')
            : (r.attributes['href'] ?? '');
        String cover = '';
        if (site.searchCoverDom != null && site.searchCoverDom!.isNotEmpty) {
          cover = _imgUrl(r.querySelector(site.searchCoverDom!)) ?? '';
          if (cover.isNotEmpty && !cover.startsWith('http')) {
            cover = _resolveUrl(cover, url);
          }
        }
        out.add(
          BookSiteResult(
            title: title,
            author: _elText(r, site.searchAuthorDom),
            cover: cover,
            bookUrl: href.isEmpty ? '' : _resolveUrl(href, url),
            intro: _elText(r, site.searchIntroDom),
            lastChapter: _elText(r, site.searchLastChapterDom),
          ),
        );
      }
    }
    _log('搜索「$query」: ${out.length} 条');
    return out;
  }

  // ── 详情 ─────────────────────────────────────────────────────

  /// 书籍详情（从详情页 HTML 提取封面/简介/作者/最新章节）。
  Future<BookSiteResult> bookInfo(BookSiteResult base) async {
    final url = _resolveUrl(base.bookUrl);
    final html = await _fetchHtml(url);
    final doc = parse(html);

    String title = base.title;
    if (site.bookNameDom != null && site.bookNameDom!.isNotEmpty) {
      final el = doc.querySelector(site.bookNameDom!);
      if (el != null && el.text.trim().isNotEmpty) title = el.text.trim();
    }
    String cover = base.cover;
    if (site.bookCoverDom != null && site.bookCoverDom!.isNotEmpty) {
      final el = doc.querySelector(site.bookCoverDom!);
      if (el != null) {
        final u = _imgUrl(el);
        if (u != null && u.isNotEmpty) cover = u;
      }
    }
    if (cover.isNotEmpty && !cover.startsWith('http')) {
      cover = _resolveUrl(cover, url);
    }
    String author = base.author;
    if (site.bookAuthorDom != null && site.bookAuthorDom!.isNotEmpty) {
      final el = doc.querySelector(site.bookAuthorDom!);
      if (el != null) author = el.text.trim();
    }
    String intro = base.intro;
    if (site.bookDescDom != null && site.bookDescDom!.isNotEmpty) {
      final el = doc.querySelector(site.bookDescDom!);
      if (el != null) {
        final c = el.attributes['content']?.trim();
        final t = el.text.trim();
        intro = (c != null && c.isNotEmpty) ? c : t;
      }
    }
    String lastChapter = base.lastChapter;
    if (site.bookLastChapterDom != null &&
        site.bookLastChapterDom!.isNotEmpty) {
      final el = doc.querySelector(site.bookLastChapterDom!);
      if (el != null) lastChapter = el.text.trim();
    }
    return base.copyWith(
      title: title,
      cover: cover,
      author: author,
      intro: intro,
      lastChapter: lastChapter,
    );
  }

  // ── 目录 ─────────────────────────────────────────────────────

  /// 目录（支持分页合并）。
  Future<List<BookSiteChapter>> toc(String bookUrl) async {
    final detailUrl = _resolveUrl(bookUrl);
    final html = await _fetchHtml(detailUrl);
    final doc = parse(html);
    final chapters = <BookSiteChapter>[];
    final seen = <String>{};

    _parseToc(doc, detailUrl, chapters, seen);

    // 分页目录
    if (site.tocPageUrl != null &&
        site.tocPageUrl!.isNotEmpty &&
        site.tocPageCountDom != null &&
        site.tocPageCountDom!.isNotEmpty) {
      String base = detailUrl;
      if (site.tocPageBaseDom != null && site.tocPageBaseDom!.isNotEmpty) {
        final el = doc.querySelector(site.tocPageBaseDom!);
        final c = el?.attributes['content'];
        if (c != null && c.isNotEmpty) base = c;
      }
      base = base.replaceFirst(RegExp(r'[?&]page=\d+'), '');
      final pageCount = _maxPage(doc, site.tocPageCountDom!);
      for (var p = 2; p <= pageCount; p++) {
        final pageUrl = site.tocPageUrl!
            .replaceAll('{base}', base)
            .replaceAll('{page}', p.toString());
        try {
          final before = chapters.length;
          _parseToc(parse(await _fetchHtml(pageUrl)), pageUrl, chapters, seen);
          if (chapters.length == before) break;
        } catch (e) {
          _log('目录第 $p 页失败: $e');
          break;
        }
      }
    }
    if (site.tocOrder == 0) {
      chapters.sort((a, b) => b.name.compareTo(a.name));
    }
    _log('目录: $detailUrl, ${chapters.length} 章');
    return chapters;
  }

  void _parseToc(
    Document doc,
    String pageUrl,
    List<BookSiteChapter> chapters,
    Set<String> seen,
  ) {
    final linkDom = site.tocLinkDom;
    if (linkDom == null || linkDom.isEmpty) return;
    for (final a in doc.querySelectorAll(linkDom)) {
      final href = a.attributes['href'] ?? '';
      if (href.isEmpty || href.startsWith('javascript:')) continue;
      if (site.tocUrlPattern != null &&
          site.tocUrlPattern!.isNotEmpty &&
          !href.contains(site.tocUrlPattern!)) {
        continue;
      }
      final chapterUrl = _resolveUrl(href, pageUrl);
      if (!seen.add(chapterUrl)) continue;
      String name = a.text.trim();
      if (name.isEmpty && site.tocNameDom != null && site.tocNameDom!.isNotEmpty) {
        final ne = a.querySelector(site.tocNameDom!);
        if (ne != null) name = ne.text.trim();
      }
      if (name.isEmpty) continue;
      chapters.add(BookSiteChapter(name: name, url: chapterUrl));
    }
  }

  // ── 正文 ─────────────────────────────────────────────────────

  /// 正文文本（contentDom 提取 + removeDoms 去噪 + 翻页合并）。
  Future<String> content(String chapterUrl) async {
    final url = _resolveUrl(chapterUrl);
    final buf = StringBuffer();
    var cur = url;
    for (var p = 0; p < site.contentMaxPages; p++) {
      String html;
      try {
        html = await _fetchHtml(cur);
      } catch (e) {
        _log('正文第 $p 页失败: $e');
        break;
      }
      final doc = parse(html);
      final contentDom = site.contentDom;
      Element? box;
      if (contentDom != null && contentDom.isNotEmpty) {
        box = doc.querySelector(contentDom);
      }
      if (box == null) break;
      // 去噪：克隆节点后移除广告/脚本等容器
      if (site.contentRemoveDoms != null &&
          site.contentRemoveDoms!.isNotEmpty) {
        for (final sel in site.contentRemoveDoms!.split(RegExp(r'\s+'))) {
          if (sel.isEmpty) continue;
          for (final rm in box.querySelectorAll(sel)) {
            rm.remove();
          }
        }
      }
      // 取 <br>/<p> 换行文本
      final text = _textWithBreaks(box);
      if (text.trim().isEmpty && p == 0) break;
      buf.write(text.trim());
      // 翻页
      if (site.contentNextDom == null || site.contentNextDom!.isEmpty) break;
      final next = doc.querySelector(site.contentNextDom!);
      final nh = next?.attributes['href'] ?? '';
      if (nh.isEmpty || nh.startsWith('javascript:')) break;
      final nu = _resolveUrl(nh, cur);
      if (nu == cur || buf.length > 2_000_000) break; // 防循环
      cur = nu;
    }
    return buf.toString();
  }

  /// 取元素文本，<br>/<p> 处补换行。
  String _textWithBreaks(Element el) {
    final sb = StringBuffer();
    void walk(Node node) {
      if (node is Element) {
        if (node.localName == 'br') {
          sb.write('\n');
          return;
        }
        if (node.localName == 'p' ||
            node.localName == 'div' ||
            node.localName == 'li') {
          sb.write('\n');
        }
        for (final c in node.nodes) {
          walk(c);
        }
      } else if (node is Text) {
        sb.write(node.text);
      }
    }

    for (final c in el.nodes) {
      walk(c);
    }
    return sb.toString();
  }

  // ── 工具 ─────────────────────────────────────────────────────

  String _elText(Element el, String? selector) {
    if (selector == null || selector.isEmpty) return '';
    return el.querySelector(selector)?.text.trim() ?? '';
  }

  String? _elAttr(Element el, String? selector, String attr) {
    if (selector == null || selector.isEmpty) return null;
    return el.querySelector(selector)?.attributes[attr];
  }

  /// 取图片真实 URL（依次试 src/data-src/data-original/data-lazy-src/data-url）。
  String? _imgUrl(Element? img) {
    if (img == null) return null;
    for (final attr in const [
      'src',
      'data-src',
      'data-original',
      'data-lazy-src',
      'data-url',
    ]) {
      final v = img.attributes[attr];
      if (v != null &&
          v.isNotEmpty &&
          !v.startsWith('data:') &&
          !v.startsWith('blob:')) {
        return v;
      }
    }
    return img.attributes['src'];
  }

  /// 从分页容器内取最大页码数字。
  int _maxPage(Document doc, String selector) {
    final el = doc.querySelector(selector);
    if (el == null) return 1;
    var max = 1;
    for (final m in RegExp(r'\d+').allMatches(el.text)) {
      final n = int.tryParse(m.group(0)!) ?? 0;
      if (n > max) max = n;
    }
    return max;
  }
}
