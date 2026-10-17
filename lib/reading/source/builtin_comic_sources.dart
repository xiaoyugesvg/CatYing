import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'global_proxy.dart';
import 'manga_source.dart';
import 'models.dart';

/// 内置漫画源（随包提供，不需要用户导入）。
///
/// 首批：**瓜子漫画**（guazimanhua.com，纯服务端渲染，无需登录/加密）。
/// 其余站点（包子/漫画柜/嬉皮/卡拉/番茄/漫小肆）与 Aidoku 中文源
/// 需要各自的接口逆向或解码器，后续按站点逐个补到这里。
List<MangaSource> builtinComicSources() => [
      GuaZiMangaSource(),
    ];

/// 源名称去重：同名时依次追加 `（2）`、`（3）`…
String uniqueSourceName(String base, Iterable<String> existing) {
  final names = existing.toSet();
  if (!names.contains(base)) return base;
  var i = 2;
  while (names.contains('$base（$i）')) {
    i++;
  }
  return '$base（$i）';
}

/// 瓜子漫画：PHP 服务端渲染 + img.guazicdn.com 图床（无防盗链）。
///
/// 站点结构（2026-10 实测）：
///   · 搜索 / 分类：`/category.php?keyword=<q>&page=N`
///     → `article.card`（a.cover-wrap[href] / img.cover[src] / h3 a 标题 / .meta 作者·标签）
///   · 详情：`/comic.php?id=<id>`
///     → JSON-LD `@graph` 的 `ComicStory`（name/author/genre/image/description）
///     → 章节目录 `div.all-chapter-grid a[href*="chapter.php?id="]`（**倒序**，需反转）
///   · 章节图：`/chapter.php?id=<cid>` → `img.reading-image[data-page]`（DOM 顺序即页序）
class GuaZiMangaSource extends MangaSource {
  static const _sourceId = 'builtin_guazi';
  static const _base = 'https://www.guazimanhua.com';
  static const _ua =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148';

  late final Dio _dio = _buildDio();

  Dio _buildDio() {
    final d = Dio(BaseOptions(
      baseUrl: _base,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      headers: {
        'User-Agent': _ua,
        'Accept-Language': 'zh-CN,zh;q=0.9',
      },
    ));
    applyGlobalProxy(d);
    return d;
  }

  @override
  String get id => _sourceId;

  @override
  String get name => '瓜子漫画';

  @override
  String get lang => 'zh';

  @override
  bool get supportsLatest => true;

  @override
  bool get supportsCategories => false;

  @override
  Map<String, String> get imageHeaders => {'User-Agent': _ua};

  @override
  String? get referer => '$_base/';

  @override
  Future<MangasPage> search(
    String query, {
    int page = 0,
    FilterList filters = const FilterList(),
  }) {
    final q = query.trim();
    return _list(query: q.isEmpty ? null : q, page: page);
  }

  @override
  Future<MangasPage> getPopular({int page = 0}) => _list(page: page);

  @override
  Future<MangasPage> getLatestUpdates({int page = 0}) => _list(page: page);

  Future<MangasPage> _list({String? query, int page = 0}) async {
    final res = await _dio.get(
      '/category.php',
      queryParameters: {
        if (query != null && query.isNotEmpty) 'keyword': query,
        if (page > 0) 'page': page + 1,
      },
    );
    final doc = html_parser.parse('${res.data}');
    final items = <CManga>[];
    for (final card in doc.querySelectorAll('article.card')) {
      final coverA = card.querySelector('a.cover-wrap');
      final href = coverA?.attributes['href'] ?? '';
      final mid = RegExp(r'id=(\d+)').firstMatch(href)?.group(1) ?? '';
      if (mid.isEmpty) continue;
      final img = card.querySelector('img.cover');
      final title = card.querySelector('h3 a')?.text.trim() ?? '';
      final meta = card.querySelector('.meta')?.text.trim() ?? '';
      final parts = meta
          .split('·')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      final score =
          double.tryParse(card.querySelector('.score')?.text.trim() ?? '');
      items.add(CManga(
        id: mid,
        sourceId: _sourceId,
        title: title.isEmpty ? (img?.attributes['alt'] ?? '') : title,
        cover: img?.attributes['src'] ?? '',
        author: parts.isNotEmpty ? parts.first : null,
        tags: parts.length > 1 ? parts.sublist(1) : null,
        rating: score,
        url: '$_base/comic.php?id=$mid',
      ));
    }
    return MangasPage(items: items, hasNextPage: items.isNotEmpty);
  }

  @override
  Future<CManga> getMangaDetails(CManga manga) async {
    final doc = await _getDoc('/comic.php', {'id': manga.id});
    final story = _findLdType(doc, 'ComicStory');
    final title = (story?['name'] ?? '').toString().trim();
    final cover = (story?['image'] ?? '').toString().trim();
    final authorObj = story?['author'];
    String? author;
    if (authorObj is Map) {
      author = (authorObj['name'] ?? '').toString().trim();
    } else if (authorObj is List && authorObj.isNotEmpty) {
      author = (authorObj.first is Map
              ? (authorObj.first as Map)['name']
              : authorObj.first)
          ?.toString()
          .trim();
    }
    final genre = story?['genre'];
    final tags = genre is List
        ? genre.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList()
        : null;
    final desc = (story?['description'] ?? '').toString().trim();
    return manga.copyWith(
      title: title.isEmpty ? manga.title : title,
      cover: cover.isEmpty ? manga.cover : cover,
      author: author?.isEmpty == true ? manga.author : author,
      description: desc.isEmpty ? null : desc,
      tags: tags,
      totalChapters: doc
          .querySelectorAll('.all-chapter-grid a[href*="chapter.php?id="]')
          .length,
      initialized: true,
    );
  }

  @override
  Future<List<CChapter>> getChapterList(CManga manga) async {
    final doc = await _getDoc('/comic.php', {'id': manga.id});
    // DOM 是**最新在前**（倒序）→ 反转得到阅读顺序
    final anchors = doc
        .querySelectorAll('.all-chapter-grid a[href*="chapter.php?id="]')
        .toList()
        .reversed
        .toList();
    final out = <CChapter>[];
    for (var i = 0; i < anchors.length; i++) {
      final a = anchors[i];
      final href = a.attributes['href'] ?? '';
      final cid = RegExp(r'id=(\d+)').firstMatch(href)?.group(1) ?? '';
      if (cid.isEmpty) continue;
      final name = a.text.trim();
      out.add(CChapter(
        id: cid,
        sourceId: _sourceId,
        mangaId: manga.id,
        name: name.isEmpty ? '第${i + 1}话' : name,
        url: '$_base/chapter.php?id=$cid',
        order: i,
      ));
    }
    return out;
  }

  @override
  Future<List<String>> getChapterImages(CManga manga, CChapter chapter) async {
    final url = chapter.url ?? '$_base/chapter.php?id=${chapter.id}';
    final res = await _dio.get(
      url,
      options: Options(headers: {'Referer': manga.url ?? '$_base/'}),
    );
    final doc = html_parser.parse('${res.data}');
    final imgs = doc.querySelectorAll('img.reading-image').toList();
    // data-page 是 1..N；没有时保持 DOM 顺序
    imgs.sort((a, b) {
      final pa = int.tryParse(a.attributes['data-page'] ?? '') ?? 0;
      final pb = int.tryParse(b.attributes['data-page'] ?? '') ?? 0;
      return pa.compareTo(pb);
    });
    return imgs
        .map((e) => e.attributes['src'] ?? '')
        .where((e) => e.startsWith('http'))
        .toList();
  }

  @override
  String? refererForChapter(CChapter chapter) =>
      chapter.url ?? '$_base/';

  Future<dom.Document> _getDoc(
    String path,
    Map<String, dynamic> query,
  ) async {
    final res = await _dio.get(
      path,
      queryParameters: query,
      options: Options(headers: {'Referer': '$_base/'}),
    );
    return html_parser.parse('${res.data}');
  }

  /// 在页面所有 `application/ld+json` 里找指定 @type 的节点
  /// （兼容 `@graph` 数组与直接对象两种写法）。
  Map<String, dynamic>? _findLdType(dom.Document doc, String type) {
    for (final script in doc.querySelectorAll(
      'script[type="application/ld+json"]',
    )) {
      final raw = script.text.trim();
      if (raw.isEmpty) continue;
      try {
        final decoded = _decodeJson(raw);
        for (final node in _ldNodes(decoded)) {
          if (node['@type'] == type) return node;
        }
      } catch (_) {}
    }
    return null;
  }

  dynamic _decodeJson(String raw) => jsonDecode(raw);

  Iterable<Map<String, dynamic>> _ldNodes(dynamic decoded) sync* {
    if (decoded is Map) {
      final m = Map<String, dynamic>.from(decoded);
      final graph = m['@graph'];
      if (graph is List) {
        for (final g in graph) {
          if (g is Map) yield Map<String, dynamic>.from(g);
        }
      } else {
        yield m;
      }
    } else if (decoded is List) {
      for (final e in decoded) {
        if (e is Map) yield Map<String, dynamic>.from(e);
      }
    }
  }
}
