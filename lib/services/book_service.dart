import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';
import 'nodejs_manager.dart';

/// 一条「阅读 3.0」书源（只保留我们真正用到的字段）
///
/// Legado 的书源 JSON 有几十个字段，其中大部分（如 exploreUrl、
/// loginCheckJs、eventListener）需要浏览器内核或 Java 互操作，Node 里跑不了。
/// 这里**原样保留整个 JSON**（发给 Node 执行），另存几个常用字段供 UI 展示。
class BookSource {
  final Map<String, dynamic> raw;

  const BookSource(this.raw);

  String get name => (raw['bookSourceName'] ?? '未命名').toString();
  String get url => (raw['bookSourceUrl'] ?? '').toString();
  String get group => (raw['bookSourceGroup'] ?? '').toString();

  /// 0=小说 1=有声 2=漫画 3=文件
  int get type => (raw['bookSourceType'] as num?)?.toInt() ?? 0;
  bool get isComic => type == 2;
  bool get isAudio => type == 1;
  bool get enabled => raw['enabled'] != false;

  /// 稳定标识：用书源地址（Legado 也是这么去重的）
  String get key => url.trim().isEmpty ? name : url.trim();

  bool get hasSearch => (raw['searchUrl'] ?? '').toString().trim().isNotEmpty;

  static BookSource? fromJson(Map<String, dynamic> j) {
    if ((j['bookSourceName'] ?? '').toString().trim().isEmpty &&
        (j['bookSourceUrl'] ?? '').toString().trim().isEmpty) {
      return null;
    }
    return BookSource(j);
  }
}

/// 搜索结果里的一本书
class BookItem {
  final String name;
  final String author;
  final String bookUrl;
  final String coverUrl;
  final String intro;
  final String kind;
  final String lastChapter;

  /// 来自哪个书源
  final BookSource? source;

  const BookItem({
    required this.name,
    this.author = '',
    this.bookUrl = '',
    this.coverUrl = '',
    this.intro = '',
    this.kind = '',
    this.lastChapter = '',
    this.source,
  });

  static BookItem fromJson(Map<String, dynamic> j, BookSource? s) => BookItem(
        name: (j['name'] ?? '').toString(),
        author: (j['author'] ?? '').toString(),
        bookUrl: (j['bookUrl'] ?? '').toString(),
        coverUrl: (j['coverUrl'] ?? '').toString(),
        intro: (j['intro'] ?? '').toString(),
        kind: (j['kind'] ?? '').toString(),
        lastChapter: (j['lastChapter'] ?? '').toString(),
        source: s,
      );

  String get subtitle =>
      [author, if (source != null) source!.name].where((e) => e.isNotEmpty).join(' · ');
}

/// 一章节
class BookChapter {
  final String name;
  final String url;
  const BookChapter({required this.name, required this.url});

  static BookChapter fromJson(Map<String, dynamic> j) => BookChapter(
        name: (j['name'] ?? '').toString(),
        url: (j['url'] ?? '').toString(),
      );
}

/// 正文结果：小说=文本，漫画=图片列表
class ChapterContent {
  final String type; // 'text' | 'images'
  final String content;
  final List<String> images;

  const ChapterContent({
    required this.type,
    this.content = '',
    this.images = const [],
  });

  bool get isImages => type == 'images';
}

/// 书源服务：导入 / 管理 / 搜索 / 详情 / 目录 / 正文
///
/// 真正的规则解析在 Node 侧（`book_source.js` + `book_rule.js`），
/// Dart 只负责存书源、转发请求、把结果给 UI。
class BookService extends GetxService {
  static BookService get instance {
    if (!Get.isRegistered<BookService>()) {
      Get.put<BookService>(BookService(), permanent: true);
    }
    return Get.find<BookService>();
  }

  static const String _keySources = 'book_sources_v1';

  /// 已导入的书源
  final sources = <BookSource>[].obs;

  /// 搜索中
  final isSearching = false.obs;

  /// 最近一次错误
  final lastError = ''.obs;

  /// 搜索进度（已完成的源 / 总数），用于"搜了 3/12 个源"
  final searchDone = 0.obs;
  final searchTotal = 0.obs;

  /// 搜索结果
  final results = <BookItem>[].obs;

  /// 长超时 Dio：书源站点普遍慢，而且 Node 侧还要解析
  late final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 40),
    sendTimeout: const Duration(seconds: 20),
  ));

  @override
  void onInit() {
    super.onInit();
    load();
  }

  // ============================================================
  // 持久化
  // ============================================================

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_keySources);
    sources.clear();
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        final list = decoded is List ? decoded : [decoded];
        for (final e in list) {
          if (e is Map) {
            final s = BookSource.fromJson(e.cast<String, dynamic>());
            if (s != null) sources.add(s);
          }
        }
      } catch (e) {
        AppLog.instance.log('[BookService] 书源解析失败: $e');
      }
    }
    AppLog.instance.log('[BookService] 已加载 ${sources.length} 个书源');
  }

  Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keySources,
        jsonEncode(sources.map((s) => s.raw).toList()));
  }

  /// 启用中的书源
  List<BookSource> get enabledSources =>
      sources.where((s) => s.enabled && s.hasSearch).toList();

  bool get configured => enabledSources.isNotEmpty;

  // ============================================================
  // 导入 / 删除
  // ============================================================

  /// 导入书源 JSON 文本。支持：
  ///   · 单个对象 `{...}`
  ///   · 数组 `[{...},{...}]`（源站下载的格式）
  /// 返回 (成功导入数, 跳过数, 错误信息)
  Future<({int added, int skipped, String error})> importJson(String text) async {
    final t = text.trim();
    if (t.isEmpty) return (added: 0, skipped: 0, error: '内容为空');

    dynamic decoded;
    try {
      decoded = jsonDecode(t);
    } catch (e) {
      return (added: 0, skipped: 0, error: '不是合法 JSON：$e');
    }

    final list = decoded is List ? decoded : [decoded];
    var added = 0;
    var skipped = 0;

    for (final e in list) {
      if (e is! Map) {
        skipped++;
        continue;
      }
      final s = BookSource.fromJson(e.cast<String, dynamic>());
      if (s == null) {
        skipped++;
        continue;
      }
      // 按 bookSourceUrl 去重（与 Legado 一致）
      final idx = sources.indexWhere((x) => x.key == s.key);
      if (idx >= 0) {
        sources[idx] = s; // 覆盖更新
        skipped++;
      } else {
        sources.add(s);
        added++;
      }
    }
    await _persist();
    return (added: added, skipped: skipped, error: '');
  }

  /// 从 URL 下载书源 JSON（源站直链，如 yckceo.com/.../id/123.json）
  Future<({int added, int skipped, String error})> importFromUrl(
      String url) async {
    final u = url.trim();
    if (u.isEmpty) return (added: 0, skipped: 0, error: '请填写地址');
    try {
      final res = await _dio.get<String>(
        u,
        options: Options(responseType: ResponseType.plain),
      );
      return importJson(res.data ?? '');
    } on DioException catch (e) {
      return (added: 0, skipped: 0, error: '下载失败：${_humanize(e)}');
    } catch (e) {
      return (added: 0, skipped: 0, error: '下载失败：$e');
    }
  }

  /// 本地文件导入
  Future<({int added, int skipped, String error})> importFromFile(
      String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) {
        return (added: 0, skipped: 0, error: '文件不存在');
      }
      return importJson(await f.readAsString());
    } catch (e) {
      return (added: 0, skipped: 0, error: '读取失败：$e');
    }
  }

  Future<void> remove(String key) async {
    sources.removeWhere((s) => s.key == key);
    await _persist();
  }

  Future<void> clearAll() async {
    sources.clear();
    await _persist();
  }

  Future<void> setEnabled(BookSource s, bool on) async {
    final i = sources.indexWhere((x) => x.key == s.key);
    if (i < 0) return;
    sources[i].raw['enabled'] = on;
    sources.refresh();
    await _persist();
  }

  // ============================================================
  // Node 桥
  // ============================================================

  Future<({bool ok, Map<String, dynamic> data, String error})> _call(
    String action,
    BookSource source,
    Map<String, dynamic> extra,
  ) async {
    final port = NodeJSManager.instance.managementPort;
    if (port <= 0) {
      return (ok: false, data: <String, dynamic>{}, error: 'Node 服务未就绪（稍后重试）');
    }
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        'http://127.0.0.1:$port/book/source',
        data: {
          'action': action,
          'source': source.raw,
          ...extra,
        },
        options: Options(
          contentType: 'application/json',
          receiveTimeout: const Duration(seconds: 45),
        ),
      );
      final body = res.data ?? const <String, dynamic>{};
      final ok = body['ok'] == true;
      return (
        ok: ok,
        data: body,
        error: (body['error'] ?? '').toString(),
      );
    } on DioException catch (e) {
      return (ok: false, data: <String, dynamic>{}, error: _humanize(e));
    } catch (e) {
      return (ok: false, data: <String, dynamic>{}, error: '$e');
    }
  }

  // ============================================================
  // 搜索（多源并发）
  // ============================================================

  /// 在所有启用书源里搜书名。
  ///
  /// 并发跑、单源失败不影响其它源、结果按"书名完全匹配优先"排序。
  Future<List<BookItem>> search(String keyword, {int page = 1}) async {
    final kw = keyword.trim();
    if (kw.isEmpty) {
      lastError.value = '请输入关键词';
      return const [];
    }
    final list = enabledSources;
    if (list.isEmpty) {
      lastError.value = '还没有可用的书源（需要先导入书源 JSON）';
      return const [];
    }

    isSearching.value = true;
    lastError.value = '';
    results.clear();
    searchDone.value = 0;
    searchTotal.value = list.length;

    final collected = <BookItem>[];
    final errors = <String>[];

    await Future.wait(list.map((s) async {
      try {
        final r = await _call('search', s, {'keyword': kw, 'page': page})
            .timeout(const Duration(seconds: 45));
        if (r.ok) {
          final arr = r.data['list'];
          if (arr is List) {
            for (final it in arr) {
              if (it is Map) {
                collected.add(
                    BookItem.fromJson(it.cast<String, dynamic>(), s));
              }
            }
          }
        } else {
          errors.add('${s.name}: ${r.error}');
        }
      } catch (e) {
        errors.add('${s.name}: $e');
      } finally {
        searchDone.value = searchDone.value + 1;
        // 边出边显示：每个源返回就刷新一次列表
        results.assignAll(_rank(collected, kw));
      }
    }));

    isSearching.value = false;
    results.assignAll(_rank(collected, kw));
    if (collected.isEmpty && errors.isNotEmpty) {
      lastError.value = errors.first;
    }
    AppLog.instance.log(
        '[BookService] 搜索 "$kw"：${collected.length} 条 / ${list.length} 源，'
        '失败 ${errors.length}');
    return results;
  }

  /// 排序：书名完全等于关键词 → 开头是关键词 → 包含关键词 → 其它
  List<BookItem> _rank(List<BookItem> items, String kw) {
    final k = kw.toLowerCase();
    final out = List<BookItem>.from(items);
    int score(BookItem b) {
      final n = b.name.toLowerCase();
      if (n == k) return 0;
      if (n.startsWith(k)) return 1;
      if (n.contains(k)) return 2;
      return 3;
    }

    out.sort((a, b) {
      final d = score(a).compareTo(score(b));
      if (d != 0) return d;
      return a.name.length.compareTo(b.name.length);
    });
    return out;
  }

  // ============================================================
  // 详情 / 目录 / 正文
  // ============================================================

  /// 拿详情（主要是 tocUrl）
  Future<({String tocUrl, String intro, String coverUrl, String error})>
      bookInfo(BookSource source, String bookUrl) async {
    final r = await _call('info', source, {'bookUrl': bookUrl});
    if (!r.ok) return (tocUrl: '', intro: '', coverUrl: '', error: r.error);
    final info = r.data['info'];
    if (info is! Map) {
      return (tocUrl: '', intro: '', coverUrl: '', error: '详情返回格式异常');
    }
    return (
      tocUrl: (info['tocUrl'] ?? '').toString(),
      intro: (info['intro'] ?? '').toString(),
      coverUrl: (info['coverUrl'] ?? '').toString(),
      error: '',
    );
  }

  /// 拿目录
  Future<({List<BookChapter> chapters, String error})> toc(
      BookSource source, String tocUrl) async {
    final r = await _call('toc', source, {'tocUrl': tocUrl});
    if (!r.ok) return (chapters: const <BookChapter>[], error: r.error);
    final arr = r.data['list'];
    final out = <BookChapter>[];
    if (arr is List) {
      for (final e in arr) {
        if (e is Map) out.add(BookChapter.fromJson(e.cast<String, dynamic>()));
      }
    }
    return (chapters: out, error: '');
  }

  /// 拿正文（小说文本或漫画图片）
  Future<({ChapterContent? content, String error})> chapterContent(
      BookSource source, String chapterUrl) async {
    final r = await _call('content', source, {'chapterUrl': chapterUrl});
    if (!r.ok) return (content: null, error: r.error);
    final type = (r.data['type'] ?? 'text').toString();
    if (type == 'images') {
      final arr = r.data['images'];
      final imgs = <String>[];
      if (arr is List) {
        for (final e in arr) {
          final s = e.toString().trim();
          if (s.isNotEmpty) imgs.add(s);
        }
      }
      return (
        content: ChapterContent(type: 'images', images: imgs),
        error: '',
      );
    }
    return (
      content: ChapterContent(
        type: 'text',
        content: (r.data['content'] ?? '').toString(),
      ),
      error: '',
    );
  }

  static String _humanize(Object e) {
    final s = e.toString();
    if (s.contains('timeout')) return '连接超时';
    if (s.contains('SocketException')) return '网络不可达';
    if (s.contains('certificate')) return '证书错误';
    return '请求失败：${s.length > 60 ? "${s.substring(0, 60)}…" : s}';
  }
}
