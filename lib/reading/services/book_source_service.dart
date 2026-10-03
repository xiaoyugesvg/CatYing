import 'dart:async';
import 'dart:convert';

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../services/nodejs_manager.dart';
import '../models/book_source.dart';
import '../source/book_site_config.dart';
import '../source/config_book_source.dart';

/// 书源搜索到的一本书。
///
/// 字段跟着 Legado 的 `ruleSearch` 规则走（name/author/bookUrl/coverUrl/intro/
/// kind/lastChapter/wordCount），抓不到的留空字符串 —— 界面上按空值处理，
/// 比"用假数据填充"好排查。
class BookSourceResult {
  const BookSourceResult({
    required this.source,
    required this.name,
    this.author = '',
    this.bookUrl = '',
    this.coverUrl = '',
    this.intro = '',
    this.kind = '',
    this.lastChapter = '',
    this.wordCount = '',
  });

  final BookSource source;
  final String name;
  final String author;
  final String bookUrl;
  final String coverUrl;
  final String intro;
  final String kind;
  final String lastChapter;
  final String wordCount;

  /// 跨源去重用的键：书名 + 作者。
  ///
  /// 为什么不用 bookUrl：同一个书在不同源上 URL 必然不同，
  /// 而去重的目的是"让用户看到一本书一次"，所以必须用内容特征。
  String get identityKey =>
      '${name.trim()}::${author.trim()}'.toLowerCase();

  /// 同一本书在不同源上的"同名"判定（换源时用）
  bool sameBookAs(BookSourceResult other) {
    final a = name.trim().toLowerCase();
    final b = other.name.trim().toLowerCase();
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;
    // 书名包含也算（有的源带"（精校版）"之类后缀）
    return a.contains(b) || b.contains(a);
  }

  static BookSourceResult? fromJson(Map<String, dynamic> j, BookSource src) {
    final name = (j['name'] ?? '').toString().trim();
    if (name.isEmpty) return null;
    return BookSourceResult(
      source: src,
      name: name,
      author: (j['author'] ?? '').toString().trim(),
      bookUrl: (j['bookUrl'] ?? '').toString().trim(),
      coverUrl: (j['coverUrl'] ?? '').toString().trim(),
      intro: (j['intro'] ?? '').toString().trim(),
      kind: (j['kind'] ?? '').toString().trim(),
      lastChapter: (j['lastChapter'] ?? '').toString().trim(),
      wordCount: (j['wordCount'] ?? '').toString().trim(),
    );
  }

  @override
  String toString() => 'BookSourceResult($name / ${source.name})';
}

/// 书源目录里的一章
class BookSourceChapter {
  const BookSourceChapter({required this.name, required this.url});

  final String name;
  final String url;

  static BookSourceChapter? fromJson(Map<String, dynamic> j) {
    final name = (j['name'] ?? '').toString().trim();
    final url = (j['url'] ?? '').toString().trim();
    if (name.isEmpty || url.isEmpty) return null;
    return BookSourceChapter(name: name, url: url);
  }
}

/// 单个书源的搜索状态（UI 要按源展示成功/失败/耗时）
class SourceSearchState {
  SourceSearchState({required this.source});

  final BookSource source;
  bool done = false;
  bool ok = false;
  String? error;
  int count = 0;
  Duration? elapsed;

  String get label => source.name;
}

/// 书源服务：Dart 侧调度 Node 里的 Legado 引擎。
///
/// ── 为什么把执行放在 Node ──────────────────────────────────────
/// Legado 书源的规则里有 `@js:` / `<js>...</js>`，本质是**执行用户提供的 JS**。
/// cmbok V2.0.7 用 `quickjs_engine`（已从 2.0.8 IPA 证实）来做这件事。
/// 我们这边已经有 Node 运行时 + 一个沙箱化的 Legado 引擎
/// （`book_source.js` + `book_rule.js`），复用它即可，不必再引入 QuickJS。
///
/// ── 并发策略 ──────────────────────────────────────────────────
/// 一个书源一次搜索要发网络请求 + 跑规则，单源几百毫秒到几秒。
/// 用户导入几十个源时**必须并发**，否则要等到天荒地老。
/// 但也不能无限并发（会打爆内存 / 被目标站限流），所以用信号量限流。
class BookSourceService {
  BookSourceService._();
  static final BookSourceService instance = BookSourceService._();

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 30),
    // 书源抓的是任意站点的 HTML，可能很大
    maxRedirects: 5,
  ));

  bool _portWarned = false;

  // ============================================================
  // 响应缓存 + 并发去重
  // ============================================================

  final Map<String, _BsCacheEntry> _cache = {};

  /// 进行中的同 key 请求（并发去重）。
  ///
  /// 为什么需要：搜索页的"换源"和详情页会**同时对同一个源发详情请求**
  /// （用户在详情页点换源，底层会对多个源并发搜）。没去重就会重复抓同一个页面。
  final Map<String, Future<dynamic>> _inflight = {};

  /// 「详情」和「目录」缓存 5 分钟。
  ///
  /// 为什么不缓存搜索：搜索结果用户期望是实时的，
  /// 而且搜索关键词组合无穷，缓存命中率极低、只会白占内存。
  /// 为什么不缓存正文：正文体积大（几千字），缓存几十章就吃掉几十 MB。
  /// 正文的缓存在**阅读器里**做（带 LRU 上限），那里才知道该留哪几章。
  static const Duration _detailTtl = Duration(minutes: 5);
  static const Duration _tocTtl = Duration(minutes: 5);

  /// 缓存容量上限
  static const int _cacheLimit = 40;

  String _key(String action, String id) => '$action::$id';

  Future<dynamic> _callCached(
    Map<String, dynamic> body,
    String cacheKey,
    Duration ttl,
  ) async {
    final hit = _cache[cacheKey];
    if (hit != null) {
      if (!hit.isExpired) return hit.data;
      _cache.remove(cacheKey);
    }
    final running = _inflight[cacheKey];
    if (running != null) return running;

    final future = _call(body);
    _inflight[cacheKey] = future;
    future.whenComplete(() => _inflight.remove(cacheKey));

    final data = await future;
    // 只缓存成功结果，失败不缓存（否则"重试"拿到同一个失败）
    if (data is Map && data['ok'] != false) {
      _cache[cacheKey] = _BsCacheEntry(data, DateTime.now().add(ttl));
      _evictIfNeeded();
    }
    return data;
  }

  void _evictIfNeeded() {
    if (_cache.length <= _cacheLimit) return;
    final sorted = _cache.entries.toList()
      ..sort((a, b) => a.value.expireAt.compareTo(b.value.expireAt));
    for (var i = 0; i < sorted.length - _cacheLimit; i++) {
      _cache.remove(sorted[i].key);
    }
  }

  /// 清缓存（换源/重试时用）
  void clearCache() => _cache.clear();

  /// 同时进行的单源搜索数上限。
  ///
  /// 8 是个折中：足够快（40 个源 ≈ 5 批），又不会把 Node 的事件循环
  /// 和内存压垮（每个源要持有整页 HTML 做 DOM 解析）。
  static const int maxConcurrent = 8;

  Future<dynamic> _call(Map<String, dynamic> body) async {
    final port = NodeJSManager.instance.managementPort;
    if (port <= 0) {
      if (!_portWarned) {
        _portWarned = true;
        debugPrint('[BookSource] Node 管理端口未就绪');
      }
      return {'ok': false, 'error': '后台服务未就绪，请稍后重试'};
    }
    try {
      final res = await _dio.post(
        'http://127.0.0.1:$port/book/source',
        data: body,
        options: Options(contentType: Headers.jsonContentType),
      );
      return res.data;
    } catch (e) {
      return {'ok': false, 'error': '请求失败：${_short(e)}'};
    }
  }

  String _short(Object e) {
    if (e is DioException) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return '网络超时';
      }
      return e.message ?? e.toString();
    }
    return e.toString();
  }

  Map<String, dynamic> _asMap(dynamic raw) =>
      raw is Map ? raw.cast<String, dynamic>() : <String, dynamic>{};

  // ============================================================
  // 单源操作
  // ============================================================

  /// 明文 config 源 → Dart 侧 ConfigBookSource 引擎。
  ///
  /// config 源（type=config）不走 Node/Legado，直接按 CSS 选择器抓取。
  ConfigBookSource _configSource(BookSource source) {
    final c = (source.raw['config'] as Map).cast<String, dynamic>();
    return ConfigBookSource(
      BookSiteConfig.fromJson(c),
      proxy: source.raw['proxy']?.toString() ?? '',
    );
  }

  /// 用**一个**书源搜索。
  Future<({bool ok, String? error, List<BookSourceResult> list})> searchOne(
    BookSource source,
    String keyword, {
    int page = 1,
  }) async {
    // ── config 明文源：Dart 侧引擎 ─────────────────────────────
    if (source.isConfig) {
      try {
        final list = await _configSource(source).search(keyword, page: page);
        return (
          ok: true,
          error: null,
          list: list
              .map(
                (r) => BookSourceResult(
                  source: source,
                  name: r.title,
                  author: r.author,
                  bookUrl: r.bookUrl,
                  coverUrl: r.cover,
                  intro: r.intro,
                  lastChapter: r.lastChapter,
                ),
              )
              .toList(),
        );
      } catch (e) {
        return (ok: false, error: e.toString(), list: const <BookSourceResult>[]);
      }
    }
    // ── Legado 源：Node 引擎 ───────────────────────────────────
    final raw = await _call({
      'action': 'bsSearch',
      'source': source.raw,
      'keyword': keyword,
      'page': page,
    });
    final m = _asMap(raw);
    if (m['ok'] == false) {
      return (
        ok: false,
        error: (m['error'] ?? '未知错误').toString(),
        list: const <BookSourceResult>[],
      );
    }
    final items = m['list'];
    final out = <BookSourceResult>[];
    if (items is List) {
      for (final e in items) {
        if (e is Map) {
          final r = BookSourceResult.fromJson(e.cast<String, dynamic>(), source);
          if (r != null) out.add(r);
        }
      }
    }
    return (ok: true, error: null, list: out);
  }

  /// 书籍详情（详情页用；失败时返回 null 由 UI 退回搜索页已有字段）
  Future<Map<String, dynamic>?> bookInfo(
      BookSource source, String bookUrl) async {
    // ── config 明文源：Dart 侧引擎 ─────────────────────────────
    if (source.isConfig) {
      try {
        final info = await _configSource(source)
            .bookInfo(BookSiteResult(title: '', bookUrl: bookUrl));
        return {
          'name': info.title,
          'author': info.author,
          'coverUrl': info.cover,
          'intro': info.intro,
          'lastChapter': info.lastChapter,
        };
      } catch (_) {
        return null;
      }
    }
    final raw = await _callCached(
      {
        'action': 'bsBookInfo',
        'source': source.raw,
        'bookUrl': bookUrl,
      },
      _key('bsBookInfo', '${source.id}|$bookUrl'),
      _detailTtl,
    );
    final m = _asMap(raw);
    if (m['ok'] == false) return null;
    final info = m['info'];
    return info is Map ? info.cast<String, dynamic>() : null;
  }

  /// 目录
  Future<({bool ok, String? error, List<BookSourceChapter> list})> toc(
    BookSource source,
    String tocUrl,
  ) async {
    // ── config 明文源：Dart 侧引擎 ─────────────────────────────
    if (source.isConfig) {
      try {
        final list = await _configSource(source).toc(tocUrl);
        return (
          ok: true,
          error: null,
          list: list
              .map((c) => BookSourceChapter(name: c.name, url: c.url))
              .toList(),
        );
      } catch (e) {
        return (
          ok: false,
          error: e.toString(),
          list: const <BookSourceChapter>[],
        );
      }
    }
    final raw = await _callCached(
      {
        'action': 'bsToc',
        'source': source.raw,
        'tocUrl': tocUrl,
      },
      _key('bsToc', '${source.id}|$tocUrl'),
      _tocTtl,
    );
    final m = _asMap(raw);
    if (m['ok'] == false) {
      return (
        ok: false,
        error: (m['error'] ?? '未知错误').toString(),
        list: const <BookSourceChapter>[],
      );
    }
    final items = m['list'];
    final out = <BookSourceChapter>[];
    if (items is List) {
      for (final e in items) {
        if (e is Map) {
          final c = BookSourceChapter.fromJson(e.cast<String, dynamic>());
          if (c != null) out.add(c);
        }
      }
    }
    return (ok: true, error: null, list: out);
  }

  /// 正文。
  ///
  /// ── 两种形态（Legado 的 bookSourceType）────────────────────────
  ///   · 小说（0）：`content` 是文字，`images` 为空
  ///   · **漫画（2）：`images` 是图片 URL 列表，`content` 为空**
  ///
  /// ⚠️ 我原来只返回 content，把漫画的 images 丢了 → 漫画源一片空白。
  /// 所以这里两个都返回，由阅读器按 `images.isNotEmpty` 决定怎么渲染。
  Future<({bool ok, String? error, String content, List<String> images})>
      content(
    BookSource source,
    String chapterUrl,
  ) async {
    // ── config 明文源：Dart 侧引擎（正文纯文字，无图片）──────
    if (source.isConfig) {
      try {
        final text = await _configSource(source).content(chapterUrl);
        return (ok: true, error: null, content: text, images: const <String>[]);
      } catch (e) {
        return (
          ok: false,
          error: e.toString(),
          content: '',
          images: const <String>[],
        );
      }
    }
    final raw = await _call({
      'action': 'bsContent',
      'source': source.raw,
      'chapterUrl': chapterUrl,
    });
    // 引擎可能直接返回字符串，也可能包成 {ok, content} 或 {ok,type,images}
    if (raw is String) {
      return (ok: true, error: null, content: raw, images: const <String>[]);
    }
    final m = _asMap(raw);
    if (m['ok'] == false) {
      return (
        ok: false,
        error: (m['error'] ?? '未知错误').toString(),
        content: '',
        images: const <String>[],
      );
    }

    // ⚠️ 漫画书源（bookSourceType=2）的正文是**图片列表**，不是文字。
    // 引擎返回 `{ok:true, type:'images', images:[...]}` ——
    // 我原来只读 `m['content']`，把 images 直接丢掉了，
    // 于是所有漫画源在阅读器里都是一片空白（还不报错）。
    final imgs = m['images'];
    if (imgs is List && imgs.isNotEmpty) {
      return (
        ok: true,
        error: null,
        content: '',
        images: imgs.map((e) => e.toString()).where((e) => e.isNotEmpty).toList(),
      );
    }

    final c = m['content'] ?? m['text'] ?? '';
    return (
      ok: true,
      error: null,
      content: c.toString(),
      images: const <String>[],
    );
  }

  // ============================================================
  // 多源并发搜索
  // ============================================================

  /// 跨多个书源并发搜索。
  ///
  /// [onSourceDone] 每完成一个源回调一次 —— UI 可以"边搜边显示"，
  /// 不必等 40 个源全跑完（体验差别很大）。
  /// [onSourceResults] 带上该源的**结果列表**。
  /// 为什么单独一个回调：state 里只有条数，UI 要"边搜边显示"就必须拿到结果本身。
  /// [shouldStop] 返回 true 时停止调度剩余源（用户点了返回/换关键词）。
  Future<({List<BookSourceResult> results, List<SourceSearchState> states})>
      searchAll(
    List<BookSource> sources,
    String keyword, {
    void Function(SourceSearchState state)? onSourceDone,
    void Function(SourceSearchState state, List<BookSourceResult> list)?
        onSourceResults,
    bool Function()? shouldStop,
    int perSourceLimit = 20,
  }) async {
    final states = <SourceSearchState>[];
    final all = <BookSourceResult>[];
    final pending = List<BookSource>.of(sources);
    final active = <Future<void>>[];

    Future<void> runOne(BookSource src) async {
      final st = SourceSearchState(source: src);
      final sw = Stopwatch()..start();
      var got = <BookSourceResult>[];
      try {
        final r = await searchOne(src, keyword);
        st
          ..done = true
          ..ok = r.ok
          ..error = r.error
          ..count = r.list.length;
        if (r.ok) {
          // 单源结果过多时截断：一本书 20 条通常够了，
          // 再多会把聚合列表淹掉（同一个源常重复收录同一本书的不同卷）
          got = r.list.take(perSourceLimit).toList();
          all.addAll(got);
        }
      } catch (e) {
        st
          ..done = true
          ..ok = false
          ..error = e.toString();
      } finally {
        sw.stop();
        st.elapsed = sw.elapsed;
        states.add(st);
        onSourceResults?.call(st, got);
        onSourceDone?.call(st);
      }
    }

    // 信号量限流：始终保持 maxConcurrent 个在跑
    while (pending.isNotEmpty || active.isNotEmpty) {
      if (shouldStop != null && shouldStop()) break;
      while (active.length < maxConcurrent && pending.isNotEmpty) {
        final src = pending.removeAt(0);
        late Future<void> f;
        f = runOne(src).whenComplete(() => active.remove(f));
        active.add(f);
      }
      if (active.isEmpty) break;
      await Future.any(List<Future<void>>.of(active));
    }
    return (results: all, states: states);
  }

  // ============================================================
  // 书源体检（V2.0.7 的「书源体检」功能）
  // ============================================================

  /// 对一个书源做体检：搜索 → 详情 → 目录 → 正文，逐级验证。
  ///
  /// 为什么逐级测而不是只测搜索：
  /// 很多坏源**搜索是好的**（列表页能抓），但详情/目录/正文的规则写错了。
  /// 只测搜索会给出"可用"的假结论，用户点进去才发现看不了。
  Future<BookSourceHealth> healthCheck(
    BookSource source, {
    String keyword = '测试',
  }) async {
    final sw = Stopwatch()..start();
    final notes = <String>[];

    // 1) 搜索
    final s = await searchOne(source, keyword);
    if (!s.ok) {
      sw.stop();
      return BookSourceHealth(
        source: source,
        level: BookSourceHealthLevel.dead,
        detail: '搜索失败：${s.error}',
        elapsed: sw.elapsed,
      );
    }
    if (s.list.isEmpty) {
      sw.stop();
      // 搜到 0 条不一定是坏源（可能这个词确实没有），标为"可疑"
      return BookSourceHealth(
        source: source,
        level: BookSourceHealthLevel.suspect,
        detail: '搜索返回 0 条（关键词「$keyword」可能确实无结果）',
        elapsed: sw.elapsed,
      );
    }
    notes.add('搜索 ${s.list.length} 条');

    final first = s.list.first;

    // 2) 详情
    final info = await bookInfo(source, first.bookUrl);
    if (info == null) {
      sw.stop();
      return BookSourceHealth(
        source: source,
        level: BookSourceHealthLevel.partial,
        detail: '搜索可用，但详情规则无效（${notes.join('，')}）',
        elapsed: sw.elapsed,
      );
    }
    notes.add('详情 OK');

    // 3) 目录（详情里带的 tocUrl 优先，否则用 bookUrl）
    final tocUrl = (info['tocUrl'] ?? first.bookUrl).toString();
    final t = await toc(source, tocUrl);
    if (!t.ok || t.list.isEmpty) {
      sw.stop();
      return BookSourceHealth(
        source: source,
        level: BookSourceHealthLevel.partial,
        detail: '详情可用，但目录规则无效（${notes.join('，')}）',
        elapsed: sw.elapsed,
      );
    }
    notes.add('目录 ${t.list.length} 章');

    // 4) 正文（抽第一章）
    final c = await content(source, t.list.first.url);
    sw.stop();
    if (!c.ok || c.content.trim().isEmpty) {
      return BookSourceHealth(
        source: source,
        level: BookSourceHealthLevel.partial,
        detail: '目录可用，但正文规则无效（${notes.join('，')}）',
        elapsed: sw.elapsed,
      );
    }
    notes.add('正文 ${c.content.length} 字');

    return BookSourceHealth(
      source: source,
      level: BookSourceHealthLevel.healthy,
      detail: notes.join('，'),
      elapsed: sw.elapsed,
    );
  }

  /// 批量体检（并发限流同搜索）
  Future<List<BookSourceHealth>> healthCheckAll(
    List<BookSource> sources, {
    void Function(BookSourceHealth h)? onOne,
    bool Function()? shouldStop,
    String keyword = '测试',
  }) async {
    final out = <BookSourceHealth>[];
    final pending = List<BookSource>.of(sources);
    final active = <Future<void>>[];

    Future<void> runOne(BookSource src) async {
      BookSourceHealth h;
      try {
        h = await healthCheck(src, keyword: keyword);
      } catch (e) {
        h = BookSourceHealth(
          source: src,
          level: BookSourceHealthLevel.dead,
          detail: '体检异常：$e',
          elapsed: Duration.zero,
        );
      }
      out.add(h);
      onOne?.call(h);
    }

    while (pending.isNotEmpty || active.isNotEmpty) {
      if (shouldStop != null && shouldStop()) break;
      while (active.length < maxConcurrent && pending.isNotEmpty) {
        final src = pending.removeAt(0);
        late Future<void> f;
        f = runOne(src).whenComplete(() => active.remove(f));
        active.add(f);
      }
      if (active.isEmpty) break;
      await Future.any(List<Future<void>>.of(active));
    }
    return out;
  }

  /// 导出书源为 JSON（分享用）
  String exportSources(List<BookSource> sources) => const JsonEncoder.withIndent(
        '  ',
      ).convert(sources.map((s) => s.toJson()).toList());

  // ============================================================
  // 书源登录（V2.0.7 的「书源登录」）
  // ============================================================

  /// 表单登录：POST 到登录接口，取回 Cookie。
  ///
  /// 拿到的 Cookie 由调用方写进书源的 `header`（引擎会自动带上）。
  Future<({bool ok, String? cookie, String? error})> loginWithForm({
    required String url,
    required Map<String, String> fields,
    String method = 'POST',
    String contentType = 'application/x-www-form-urlencoded',
    Map<String, String>? headers,
  }) async {
    final raw = await _call({
      'action': 'bsLogin',
      'url': url,
      'method': method,
      'body': fields,
      'contentType': contentType,
      'headers': headers,
    });
    final m = _asMap(raw);
    if (m['ok'] != true) {
      return (ok: false, cookie: null, error: (m['error'] ?? '登录失败').toString());
    }
    return (ok: true, cookie: m['cookie']?.toString(), error: null);
  }

  /// 下载一张图片的字节（图片模式「保存到相册」用）。
  ///
  /// ⚠️ 必须**带上书源的 header**（Referer / User-Agent）——
  /// 大多数漫画/插图图床有防盗链，裸请求会 403。
  /// 所以我们复用引擎自己的 dio，而不是另起一个 HttpClient。
  ///
  /// 返回 null 表示失败（失败原因不在这里抛，调用方给用户提示就行）。
  Future<Uint8List?> fetchBytes(BookSource source, String url) async {
    if (url.trim().isEmpty) return null;
    try {
      final res = await _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: _headersOf(source),
          // 图片可能较大，给长一点的接收超时
          receiveTimeout: const Duration(seconds: 30),
          // 有些图床对 3xx 跳转后的 URL 才给图，dio 默认跟随
          followRedirects: true,
          validateStatus: (s) => s != null && s >= 200 && s < 400,
        ),
      );
      final d = res.data;
      if (d == null || d.isEmpty) return null;
      return Uint8List.fromList(d);
    } catch (_) {
      return null;
    }
  }

  /// 取书源的请求头（header 字段是 JSON 文本或 Map 两种形态都吃）
  Map<String, String> _headersOf(BookSource source) {
    final h = source.raw['header'];
    Map<dynamic, dynamic>? m;
    if (h is Map) {
      m = h;
    } else if (h is String && h.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(h);
        if (decoded is Map) m = decoded;
      } catch (_) {}
    }
    if (m == null) return const {};
    return {
      for (final e in m.entries) '${e.key}': '${e.value}',
    };
  }

  /// 把 Cookie 写进书源的 header（其它自定义头保留）。
  ///
  /// [cookie] 传空字符串表示**退出登录**（移除 Cookie 头）。
  BookSource applyCookie(BookSource source, String cookie) {
    final raw = Map<String, dynamic>.of(source.raw);
    final header = Map<String, dynamic>.of(
      (raw['header'] is Map)
          ? (raw['header'] as Map).cast<String, dynamic>()
          : <String, dynamic>{},
    );
    final c = cookie.trim();
    if (c.isEmpty) {
      header.remove('Cookie');
      header.remove('cookie');
    } else {
      // 统一写成 Cookie（大写 C）—— 引擎按原样透传，大小写必须和站点约定一致，
      // 而 HTTP 头本身不区分大小写，所以用最常见的写法
      header.remove('cookie');
      header['Cookie'] = c;
    }
    if (header.isEmpty) {
      raw.remove('header');
    } else {
      raw['header'] = header;
    }
    return BookSource(raw: raw, id: source.id);
  }

  /// 读当前书源已保存的 Cookie（没有就返回空串）
  String currentCookie(BookSource source) {
    final h = source.raw['header'];
    if (h is! Map) return '';
    final v = h['Cookie'] ?? h['cookie'];
    return v?.toString() ?? '';
  }
}

/// 体检结论等级
enum BookSourceHealthLevel {
  /// 搜索/详情/目录/正文四级全通
  healthy,

  /// 搜索通了但后续某级规则坏了（能搜到、看不了）
  partial,

  /// 搜索 0 条（可能只是关键词无结果）
  suspect,

  /// 搜索就失败
  dead,
}

/// 一个书源的体检结果
class BookSourceHealth {
  const BookSourceHealth({
    required this.source,
    required this.level,
    required this.detail,
    required this.elapsed,
  });

  final BookSource source;
  final BookSourceHealthLevel level;
  final String detail;
  final Duration elapsed;

  String get levelText => switch (level) {
        BookSourceHealthLevel.healthy => '可用',
        BookSourceHealthLevel.partial => '部分可用',
        BookSourceHealthLevel.suspect => '可疑',
        BookSourceHealthLevel.dead => '失效',
      };

  /// 折成 0~1 的分数，供排序（好源排前面）
  double get score => switch (level) {
        BookSourceHealthLevel.healthy => 1.0,
        BookSourceHealthLevel.partial => 0.6,
        BookSourceHealthLevel.suspect => 0.3,
        BookSourceHealthLevel.dead => 0.0,
      };
}

/// 书源缓存条目
class _BsCacheEntry {
  _BsCacheEntry(this.data, this.expireAt);
  final dynamic data;
  final DateTime expireAt;
  bool get isExpired => DateTime.now().isAfter(expireAt);
}
