/// Legado（开源阅读）/ 异次元 规则的漫画源适配器。
///
/// 复用阅读模块已有的书源规则引擎（`AnalyzeRule` / `AnalyzeUrl` / `WebBook`）：
///   · `class./id./tag.` 选择器、链式选择、XPath、JSONPath
///   · `@js:` 内嵌脚本（QuickJS）
///   · `@Header:{...}` 单规则请求头
///   · `##正则##替换`
///   · Base64 / gzip / zlib 响应（由 AnalyzeUrl 的浏览器指纹适配器处理）
///
/// 与 `ConfigMangaSource` 的区别：后者只有 CSS/DOM 配置，本类直接吃 Legado
/// 的 `ruleSearch / ruleBookInfo / ruleToc / ruleContent` 四段规则。
library;

import 'dart:convert';

import 'package:html/parser.dart' as html_parser;

import 'models.dart';
import '../novel_source/analyze/analyze_rule.dart';
import '../novel_source/analyze/analyze_url.dart';
import '../novel_source/analyze/cookie_store.dart';
import '../novel_source/analyze/js_engine.dart';
import '../novel_source/model/book_source.dart';
import '../novel_source/model/search_book.dart';
import '../novel_source/model/xiaoshuo_book.dart';
import '../novel_source/model/xiaoshuo_book_chapter.dart';
import '../novel_source/web_book/web_book.dart';
import '../utils/html_text.dart';
import 'manga_source.dart';

/// 老式「扁平」Legado 规则（`ruleChapterList` / `ruleBookContent` / …）
/// → 新式嵌套规则（`ruleToc.chapterList` / `ruleContent.content` / …）。
///
/// 小说链路把扁平源交给 Node 引擎（那边有 `normalizeLegadoSource`），但
/// **漫画链路只走 Dart 的 `XiaoshuoBookSource`**，而它只读嵌套结构 ⇒
/// 内置的「看漫画」「漫小肆」这类扁平源在漫画模块里此前拿不到任何规则
/// （详情空白、章节为空、取图 0 张）。这里补齐同一套映射。
Map<String, dynamic> normalizeLegadoComicRules(Map<String, dynamic> raw) {
  final out = Map<String, dynamic>.from(raw);

  String? str(String key) {
    final v = raw[key];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    return null;
  }

  /// 只在嵌套项缺失时补，显式写好的新式规则优先。
  void put(String section, String key, String? value) {
    if (value == null || value.isEmpty) return;
    final cur = out[section];
    final map = cur is Map
        ? Map<String, dynamic>.from(cur)
        : <String, dynamic>{};
    final exist = map[key];
    if (exist is String && exist.trim().isNotEmpty) return;
    map[key] = value;
    out[section] = map;
  }

  // 搜索
  final searchUrl = str('ruleSearchUrl');
  if (searchUrl != null &&
      (out['searchUrl'] is! String ||
          (out['searchUrl'] as String).trim().isEmpty)) {
    out['searchUrl'] = searchUrl;
  }
  put('ruleSearch', 'bookList', str('ruleSearchList'));
  put('ruleSearch', 'name', str('ruleSearchName'));
  put('ruleSearch', 'author', str('ruleSearchAuthor'));
  put('ruleSearch', 'kind', str('ruleSearchKind'));
  put('ruleSearch', 'lastChapter', str('ruleSearchLastChapter'));
  put('ruleSearch', 'coverUrl', str('ruleSearchCoverUrl'));
  put('ruleSearch', 'bookUrl', str('ruleSearchNoteUrl'));

  // 发现：老版 ruleFindUrl 的 `标题::地址\n…` 与新 exploreUrl 同格式
  final findUrl = str('ruleFindUrl');
  if (findUrl != null &&
      (out['exploreUrl'] == null || '${out['exploreUrl']}'.trim().isEmpty)) {
    out['exploreUrl'] = findUrl;
  }

  // 详情
  put('ruleBookInfo', 'name', str('ruleBookName'));
  put('ruleBookInfo', 'author', str('ruleBookAuthor'));
  put('ruleBookInfo', 'kind', str('ruleBookKind') ?? str('ruleKind'));
  put(
    'ruleBookInfo',
    'intro',
    str('ruleIntroduce') ?? str('ruleBookIntroduce'),
  );
  put('ruleBookInfo', 'coverUrl', str('ruleCoverUrl'));
  put('ruleBookInfo', 'lastChapter', str('ruleBookLastChapter'));
  put('ruleBookInfo', 'tocUrl', str('ruleChapterUrl'));

  // 目录
  put('ruleToc', 'chapterList', str('ruleChapterList'));
  put('ruleToc', 'chapterName', str('ruleChapterName'));
  put('ruleToc', 'chapterUrl', str('ruleContentUrl'));
  put('ruleToc', 'nextTocUrl', str('ruleChapterUrlNext'));

  // 正文（漫画里就是图片地址规则）
  put('ruleContent', 'content', str('ruleBookContent'));
  put('ruleContent', 'nextContentUrl', str('ruleContentUrlNext'));

  // 详情页 URL 正则
  final urlPattern = str('ruleBookUrlPattern');
  if (urlPattern != null &&
      (out['bookUrlPattern'] == null ||
          '${out['bookUrlPattern']}'.trim().isEmpty)) {
    out['bookUrlPattern'] = urlPattern;
  }

  return out;
}

class LegadoComicMangaSource extends MangaSource {
  LegadoComicMangaSource(this.source);

  /// 直接从书源原始 JSON 构造（会自动做扁平 → 嵌套归一化）。
  factory LegadoComicMangaSource.fromRaw(Map<String, dynamic> raw) =>
      LegadoComicMangaSource(
        XiaoshuoBookSource.fromJson(normalizeLegadoComicRules(raw)),
      );

  final XiaoshuoBookSource source;
  final WebBook _web = WebBook();

  Map<String, String> _imageHeaders = const {};
  String? _imageReferer;

  @override
  String get id => 'legado:${source.bookSourceUrl}';

  @override
  String get name => source.bookSourceName.trim().isEmpty
      ? 'Legado 漫画'
      : source.bookSourceName;

  /// 站点地址（长按源 →「登录 / 浏览器验证」用；Legado 源取 bookSourceUrl）
  @override
  String get homeUrl => source.bookSourceUrl;

  @override
  String get group => (source.bookSourceGroup ?? '').trim();

  @override
  String get lang => 'zh';

  @override
  bool get supportsLatest => (source.exploreUrl ?? '').trim().isNotEmpty;

  @override
  bool get supportsCategories => (source.exploreUrl ?? '').trim().isNotEmpty;

  @override
  Map<String, String> get imageHeaders => {
    ..._sourceHeaders(),
    ..._imageHeaders,
  };

  @override
  String? get referer => _imageReferer ?? source.bookSourceUrl;

  @override
  String? refererForChapter(CChapter chapter) =>
      _imageReferer ?? chapter.url ?? source.bookSourceUrl;

  /// 源级 header（Legado 的 `header` 字段，JSON 字符串）
  Map<String, String> _sourceHeaders() {
    final raw = source.header?.trim();
    if (raw == null || raw.isEmpty) return const {};
    try {
      final m = jsonDecode(raw);
      if (m is Map) {
        return m.map((k, v) => MapEntry('$k', '$v'));
      }
    } catch (_) {}
    return const {};
  }

  void _bindJs() {
    try {
      SourceCookieStore.instance.enabled = source.enabledCookieJar;
      JsEngine.shared.setActiveSource(
        source.bookSourceUrl.isNotEmpty
            ? source.bookSourceUrl
            : source.bookSourceName,
        source.jsLib,
      );
    } catch (_) {}
  }

  // ── 列表 ────────────────────────────────────────────────

  @override
  Future<MangasPage> search(
    String query, {
    int page = 0,
    FilterList filters = const FilterList(),
  }) async {
    final books = await _web.searchBook(
      source: source,
      key: query,
      page: page + 1,
    );
    return MangasPage(
      items: books.map(_toCManga).toList(),
      hasNextPage: books.isNotEmpty,
    );
  }

  @override
  Future<MangasPage> getPopular({int page = 0}) => _explore(null, page);

  @override
  Future<MangasPage> getLatestUpdates({int page = 0}) => _explore(null, page);

  Future<MangasPage> _explore(String? categoryUrl, int page) async {
    final cats = _web.getExploreCategories(source);
    if (cats.isEmpty) {
      return const MangasPage(items: [], hasNextPage: false);
    }
    final target = (categoryUrl == null || categoryUrl.isEmpty)
        ? cats.first.url
        : categoryUrl;
    final books = await _web.exploreCategory(
      source: source,
      categoryUrl: target,
      page: page + 1,
    );
    return MangasPage(
      items: books.map(_toCMangaFromBook).toList(),
      hasNextPage: books.isNotEmpty,
    );
  }

  @override
  Future<List<FilterGroup>> fetchCategories() async {
    final cats = _web.getExploreCategories(source);
    if (cats.isEmpty) return const [];
    return [
      FilterGroup(
        key: 'explore',
        title: '分类',
        options: [
          for (var i = 0; i < cats.length; i++)
            FilterOption(
              value: cats[i].url,
              name: cats[i].name.isEmpty ? '分类 ${i + 1}' : cats[i].name,
            ),
        ],
        selected: FilterOption(
          value: cats.first.url,
          name: cats.first.name.isEmpty ? '分类 1' : cats.first.name,
        ),
      ),
    ];
  }

  @override
  Future<MangasPage> getCategoryList(
    List<FilterGroup> groups, {
    int page = 0,
  }) {
    String? url;
    for (final g in groups) {
      if (g.key != 'explore') continue;
      url = g.selected?.value;
    }
    return _explore(url, page);
  }

  CManga _toCManga(SearchBook b) {
    return CManga(
      id: b.bookUrl,
      sourceId: id,
      title: cleanSourceTitle(b.name),
      cover: b.coverUrl ?? '',
      author: cleanSourceTitle(b.author),
      description: b.kind,
      tags: _splitTags(b.kind),
      url: b.bookUrl,
    );
  }

  CManga _toCMangaFromBook(XiaoshuoBook b) {
    return CManga(
      id: b.bookUrl,
      sourceId: id,
      title: cleanSourceTitle(b.name),
      cover: b.coverUrl ?? '',
      author: cleanSourceTitle(b.author),
      description: _cleanIntro(b.intro),
      tags: _splitTags(b.kind),
      url: b.bookUrl,
    );
  }

  /// 简介清洗：部分源的简介字段本身是**转义后的 HTML**
  /// （例如 `&lt;span class="title"&gt;简介：&lt;/span&gt;`），
  /// 直接展示就会在详情页看到一坨标签 ⇒ 先反解再按 HTML 取纯文本。
  String? _cleanIntro(String? raw) {
    final s = raw?.trim() ?? '';
    if (s.isEmpty) return null;
    var text = s;
    if (text.contains('<') || text.contains('&lt;')) {
      try {
        final doc = html_parser.parse(text);
        text = doc.documentElement?.text ?? text;
      } catch (_) {}
      // 源里可能是**二次转义**的 HTML（解析一次后仍是标签文本），再剥一层
      text = text.replaceAll(RegExp(r'<[^>]*>'), '');
    }
    // 统一走公共简介清洗：去掉「返回 / 目录 / 站点名 / 纯网址符号」行。
    text = cleanIntroText(
      text
          .replaceAll(RegExp(r'^简介\s*[:：]\s*'), '')
          .replaceAll(RegExp(r'\s+'), ' '),
    );
    return text.isEmpty ? null : text;
  }

  List<String>? _splitTags(String? raw) {
    final s = raw?.trim() ?? '';
    if (s.isEmpty) return null;
    final list = s
        .split(RegExp(r'[,，/|]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return list.isEmpty ? null : list;
  }

  // ── 详情 / 章节 ──────────────────────────────────────────

  @override
  Future<({CManga manga, List<CChapter> chapters})> getMangaDetailsAndChapters(
    CManga manga,
  ) async {
    _bindJs();
    final detailUrl = manga.id.isNotEmpty ? manga.id : (manga.url ?? '');
    final book = await _web.getBookInfo(source: source, bookUrl: detailUrl);
    final chapters = await _web.getChapterList(source: source, book: book);

    final list = <CChapter>[];
    for (var i = 0; i < chapters.length; i++) {
      final c = chapters[i];
      final url = c.getAbsoluteURL(redirectUrl: detailUrl);
      if (url.isEmpty) continue;
      final chapterName = cleanChapterTitle(c.title);
      list.add(
        CChapter(
          id: url,
          sourceId: id,
          mangaId: manga.id,
          name: chapterName.isEmpty ? '第${i + 1}话' : chapterName,
          url: url,
          order: i,
        ),
      );
    }

    return (
      manga: manga.copyWith(
        id: manga.id,
        sourceId: id,
        title: cleanSourceTitle(book.name).isEmpty
            ? manga.title
            : cleanSourceTitle(book.name),
        cover: (book.coverUrl ?? '').trim().isEmpty
            ? manga.cover
            : book.coverUrl!.trim(),
        author: cleanSourceTitle(book.author).isEmpty
            ? manga.author
            : cleanSourceTitle(book.author),
        description: _cleanIntro(book.intro) ?? manga.description,
        status: (book.bookStatus ?? '').trim().isEmpty
            ? manga.status
            : book.bookStatus,
        tags: _splitTags(book.kind) ?? manga.tags,
        url: detailUrl,
        totalChapters: list.length,
        initialized: true,
      ),
      chapters: list,
    );
  }

  @override
  Future<CManga> getMangaDetails(CManga manga) async =>
      (await getMangaDetailsAndChapters(manga)).manga;

  @override
  Future<List<CChapter>> getChapterList(CManga manga) async =>
      (await getMangaDetailsAndChapters(manga)).chapters;

  // ── 取图 ────────────────────────────────────────────────

  @override
  Future<List<String>> getChapterImages(CManga manga, CChapter chapter) async {
    _bindJs();
    final chapterUrl = chapter.url ?? chapter.id;
    final contentRule = source.getContentRule();
    final rawRule = contentRule.content ?? '';
    final (ruleStr, ruleHeaders) = _splitRuleHeader(rawRule);

    final book = XiaoshuoBook(
      bookUrl: manga.id,
      name: manga.title,
      author: manga.author ?? '',
      tocUrl: manga.id,
    );
    final ch = XiaoshuoBookChapter(
      bookUrl: manga.id,
      url: chapterUrl,
      title: chapter.name,
    );

    final analyzeUrl = AnalyzeUrl(
      url: chapterUrl,
      baseUrl: source.bookSourceUrl,
      source: source,
      chapter: ch,
    );
    var body = await analyzeUrl.getStrResponse(
      headers: ruleHeaders.isEmpty ? null : ruleHeaders,
    );
    if (body.isEmpty) return const [];

    // ruleContent.sourceRegex：与书源引擎同口径，先从整页截出正文片段。
    // 很多漫画脚本靠它把 `<body>` 缩到图片容器，不处理会一条图都取不到
    // （症状：同一个脚本在书源能看，漫画源 0 张图）。
    final srcRe = contentRule.sourceRegex?.trim() ?? '';
    if (srcRe.isNotEmpty) {
      try {
        final m = RegExp(srcRe, dotAll: true).firstMatch(body);
        if (m != null) {
          body = m.groupCount >= 1 ? (m.group(1) ?? m.group(0)!) : m.group(0)!;
        }
      } catch (_) {
        // 非法正则忽略，保持原文
      }
    }

    final rule = AnalyzeRule(book: book, chapter: ch)
      ..setContent(body, chapterUrl)
      ..setBaseUrl(chapterUrl)
      ..setRedirectUrl(chapterUrl);

    // 规则结果既可能是图片 URL 列表，也可能是 <img> HTML / JSON。
    // 声明了 subContent 时：先按 content 取容器，再在每个容器里跑 subContent。
    List<String> values;
    final subRule = contentRule.subContent?.trim() ?? '';
    if (subRule.isNotEmpty && ruleStr.isNotEmpty) {
      values = <String>[];
      final containers = rule.getElements(ruleStr);
      for (final el in containers) {
        final sub = AnalyzeRule(book: book, chapter: ch)
          ..setContent(el, chapterUrl)
          ..setBaseUrl(chapterUrl)
          ..setRedirectUrl(chapterUrl);
        values.addAll(sub.getStringList(subRule));
      }
      if (values.isEmpty) values = rule.getStringList(ruleStr);
    } else {
      values = rule.getStringList(ruleStr);
    }
    var urls = _extractImageUrls(values, chapterUrl);

    // imageDecode：对每个图片 URL 执行源声明的解码 JS（legado 同名能力）
    final decode = contentRule.imageDecode?.trim() ?? '';
    if (decode.isNotEmpty) {
      urls = urls.map((u) {
        final d = JsEngine.shared.eval(decode, bindings: {'result': u});
        return d.trim().isEmpty ? u : d.trim();
      }).toList();
    }

    // 章节级请求头（@Header）用于图片防盗链
    if (ruleHeaders.isNotEmpty) {
      _imageHeaders = Map<String, String>.from(ruleHeaders);
      final ref = ruleHeaders.entries
          .where((e) => e.key.toLowerCase() == 'referer')
          .map((e) => e.value)
          .firstOrNull;
      if (ref != null && ref.isNotEmpty) {
        _imageReferer = ref;
        _imageHeaders.removeWhere((k, _) => k.toLowerCase() == 'referer');
      }
    }

    return urls;
  }

  /// 从规则结果里提取图片 URL：支持纯 URL / 多行 / JSON / `<img>` HTML。
  List<String> _extractImageUrls(List<String> values, String baseUrl) {
    final out = <String>[];
    final seen = <String>{};

    void add(String raw) {
      var u = raw.trim();
      if (u.isEmpty) return;
      if ((u.startsWith('"') && u.endsWith('"')) ||
          (u.startsWith("'") && u.endsWith("'"))) {
        u = u.substring(1, u.length - 1).trim();
      }
      if (u.isEmpty) return;
      if (u.startsWith('//')) u = 'https:$u';
      if (!u.startsWith('http://') && !u.startsWith('https://')) {
        final resolved = Uri.tryParse(baseUrl)?.resolve(u).toString();
        if (resolved == null) return;
        u = resolved;
      }
      if (!u.startsWith('http')) return;
      if (seen.add(u)) out.add(u);
    }

    for (final value in values) {
      final t = value.trim();
      if (t.isEmpty) continue;

      // JSON 数组 / 对象
      if (t.startsWith('[') || t.startsWith('{')) {
        try {
          final obj = jsonDecode(t);
          final list = obj is List ? obj : [obj];
          for (final e in list) {
            if (e is String) {
              add(e);
            } else if (e is Map) {
              final u = e['url'] ?? e['src'] ?? e['image'] ?? e['data-src'];
              if (u != null) add('$u');
            }
          }
          continue;
        } catch (_) {
          // 不是 JSON，继续按 HTML / 文本处理
        }
      }

      // HTML 片段
      if (t.contains('<img')) {
        try {
          final doc = html_parser.parse(t);
          for (final img in doc.querySelectorAll('img')) {
            final u =
                img.attributes['data-src'] ??
                img.attributes['data-original'] ??
                img.attributes['data-lazy-src'] ??
                img.attributes['data-url'] ??
                img.attributes['src'];
            if (u != null) add(u);
          }
          continue;
        } catch (_) {}
      }

      // 多行文本
      if (t.contains('\n')) {
        for (final line in t.split('\n')) {
          final s = line.trim();
          if (s.startsWith('http') || s.startsWith('//') || s.startsWith('/')) {
            add(s);
          }
        }
        continue;
      }

      add(t);
    }
    return out;
  }

  /// 剥离规则里的 `@Header:{...}`，返回剩余规则与请求头。
  (String, Map<String, String>) _splitRuleHeader(String raw) {
    final m = RegExp(r'@Header:\s*\{', caseSensitive: false).firstMatch(raw);
    if (m == null) return (raw, const {});
    final start = raw.indexOf('{', m.start);
    if (start < 0) return (raw, const {});

    var depth = 0;
    String? quote;
    var end = -1;
    for (var i = start; i < raw.length; i++) {
      final c = raw[i];
      if (quote != null) {
        if (c == quote) quote = null;
        continue;
      }
      if (c == "'" || c == '"') {
        quote = c;
        continue;
      }
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) {
          end = i;
          break;
        }
      }
    }
    if (end <= start) return (raw, const {});

    final inner = raw.substring(start + 1, end);
    final headers = <String, String>{};
    for (final mm in RegExp(
      r'([A-Za-z0-9_\-]+)\s*:\s*([^,}]+)',
    ).allMatches(inner)) {
      headers[mm.group(1)!] = mm
          .group(2)!
          .trim()
          .replaceAll(RegExp(r'''^['"]|['"]$'''), '');
    }
    final cleaned = (raw.substring(0, m.start) + raw.substring(end + 1)).trim();
    return (cleaned, headers);
  }
}
