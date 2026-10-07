import 'dart:async';
import 'dart:convert';

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/book_source.dart';
// ✅ **Legado → BookSiteConfig 转换**（本轮重构 ✓）：让书源**先走 Dart（含 WebView 兜底 ✓）**，
//   失败 / 含 `@js:` 才回落 Node 引擎 ✓（Node 那段保持原样 ✓ 只增不减 ✓）
import '../source/global_proxy.dart';
import '../utils/source_fail_text.dart';
import 'book_source_dart_engine.dart';

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

/// 书源发现/分类浏览的一个分类（exploreUrl 解析结果）
class ExploreCategory {
  const ExploreCategory({required this.title, required this.url});

  final String title;
  final String url;

  @override
  String toString() => 'ExploreCategory($title)';
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

  /// 壳模式：已连接 qread 服务端时，详情/目录/正文由服务端执行规则。
 
  /// 构造书源服务用的 Dio，并**挂上「网络代理」**（本轮接上 ✓）。
  ///
  /// ⚠️ 本文件**早就 import 了 `global_proxy`** ✓✓（`:13` ✓，因为它自己就有
  /// `_isNetError` 的判据说明 ✓）—— 所以这里**只差"挂上去"这一步** ✓。
  /// 手法 ✓：原来是**字段初始化** ✗（没法先构造再调用 ✓）→ 改成**具名构造** ✓，
  /// 与 `zlibrary_service._createDio()` / `download_service._createImageDio()` 同款 ✓ 不发明机制 ✗。
  /// ℹ️ 安全依据 ✓（已读源码确认 ✓）：本处**无自定义适配器** ✗✓（只有超时 + 重定向上限 ✓）
  /// · 代理**关闭** ✓ → 返回 false ✓ **一字不改** ✓（与从前完全一致 ✓✓）
  static Dio _createDio() {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      // 书源抓的是任意站点的 HTML，可能很大
      maxRedirects: 5,
    ));
    applyGlobalProxy(dio);
    return dio;
  }

  final _dio = _createDio();

  /// 本地 Node mgmt 调用专用 Dio：**永不挂全局代理**。
  ///
  /// 🔴 为什么必须独立 ✗：[_createDio] 给所有请求挂上了 `applyGlobalProxy` ✗，
  /// 而 Node 引擎的 mgmt 地址是 `http://127.0.0.1:<port>/book/source` **本地回环** ✗。
  /// 一旦用户开了全局代理，`findProxy` 对**所有 URI**（含 127.0.0.1）都返回
  /// `PROXY host:port` ✗✗ → 明文 HTTP 请求被代理**劫持到 HTTPS 端口** ✗ →
  /// 返回 Cloudflare `400 The plain HTTP request was sent to HTTPS port` ✗ →
  /// App 里表现为「接口 500 / 节点不可用」✗（用户不开代理时正常、开代理就炸 ✓）。
  /// ⇒ 本地回环调用必须**排除代理** ✓（与 NodeJSManager._localHttpDio 同口径 ✓）。
 
 
 
  /// 最近一次体检结果缓存（按源 id）。
  ///
  /// 「退出页面不中断」：体检页退出后批量任务继续跑，结果写到这里；
  /// 下次再进体检页先读这里续显，不丢进度。
  final Map<String, BookSourceHealth> healthCache = {};

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
  static const int maxConcurrent = 10;

  Future<dynamic> _call(Map<String, dynamic> body) async {
    // [PATCH-9] 先试 **Dart 原生 legado 引擎**（含 `@js:`/`<js>` 规则 + 同步宿主桥）。
    // 返回 null（动作未接管 / 空结果 / 异常）⇒ 回落 Node 引擎，现行为不变。
    // 背景：本层原先是「含 JS 的源必须走 Node」（`legadoNeedsNode`），
    // 而 Dart 侧现在已有 quickjs 引擎与宿主方法表（补丁 0005/0007/0008）。
    final dartHandled = await BookSourceDartEngine.instance.handle(body);
    if (dartHandled != null) return dartHandled;
    // [PATCH-24] 旧 Node 引擎回退已移除：书源现在**只**由本地 Dart legado 引擎执行
    //（含 `@js:` 规则 —— quickjs 原生库已随包编出）。云端壳模式（QreadApi）与
    // config 转换引擎（ConfigBookSource/legadoToConfig）的调用点也已删除。
    // ⚠️ Node 侧车本身仍保留给 视频/音乐/直播（36 处调用），这里只断了"书源回落"。
    return {
      'ok': false,
      'error': '本地引擎未接管该动作（动作：${body['action']}）——旧 Node 书源引擎已移除',
    };
  }

 
  Map<String, dynamic> _asMap(dynamic raw) =>
      raw is Map ? raw.cast<String, dynamic>() : <String, dynamic>{};

  // ============================================================
  // 单源操作
  // ============================================================

  /// 明文 config 源 → Dart 侧 ConfigBookSource 引擎。
  ///
  /// config 源（type=config）不走 Node/Legado，直接按 CSS 选择器抓取。
 
  /// 这个源能否走 **Dart 引擎** ✓（本轮重构 ✓）
  ///
  /// · `isConfig`（config 明文源 ✓）⇒ 一直可以 ✓
  /// · **Legado 源** ⇒ 只要规则里**没有 `@js:`/`<js>`** ✓ 就能（`legadoToConfig` 能转 ✓）
  ///   ⚠️ Dart 跑不了 JS ✗ ⇒ 含 JS 规则的源**必须**留给 Node 引擎 ✓（`legadoNeedsNode` 判 ✓）
  ///
  /// 6 个入口（搜索 ✓ 分类列表 ✓ 分类页 ✓ 详情 ✓ 目录 ✓ 正文 ✓）统一用本方法做门槛 ✓
  /// ⇒ 一次改动把**全部链路**对 Legado 源开放 ✓（不再各写一份 ✗）
 
  /// 用**一个**书源搜索。
  Future<({bool ok, String? error, List<BookSourceResult> list})> searchOne(
    BookSource source,
    String keyword, {
    int page = 1,
  }) async {
    // ── config 明文源：Dart 侧引擎 ─────────────────────────────
     // ── ✅ **先走 Dart（含 WebView 兜底）**，失败才回落 Node 引擎 ──────────────
    // 为什么 ✓：Node 的网络栈被不少站点拒 ✗（实测 `HTTP 400` ✓ `read ECONNRESET` ✓
    //   `socket hang up` ✓ `SSL alert 40` ✓ `certificate has expired` ✓）——
    //   这些**不是源失效** ✗（源真死会是 DNS 失败/404 ✓），是**网络栈/防护**问题 ✓。
    //   而 Dart 侧 `ConfigBookSource` 是**完整实现** ✓：搜索 ✓ 详情 ✓ 目录分页 ✓ 正文 ✓
    //   + `useWebViewFetch` ⇒ `WebViewImageFetcher` ✓（**真浏览器栈** ✓ 反爬/Cloudflare 能过 ✓）
    //   ⇒ 与母项目同款网络栈 ✓（这正是"别人 631 基本都能用"的原因 ✓）
    // 安全 ✓：`legadoNeedsNode()` 命中 `@js:` ⇒ 直接用下面的 Node ✓；
    //   抛错/空结果 ⇒ **也回落 Node** ✓（现行为不变 ✓）；Node 引擎代码**一行未动** ✓
     // ── Legado 源：Node 引擎（回落路径 ✓ 原样保留 ✓）──────────────────
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

  /// 发现/分类浏览的分类列表（exploreUrl + ruleExplore，对应书源页「必读榜」等）
  ///
  /// [source] 未传 categoryUrl → Node 侧解析 exploreUrl 返回分类数组。
  Future<({bool ok, String? error, List<ExploreCategory> categories})>
      exploreCategories(BookSource source) async {
    // 🔴 **只有 config 明文源真的没有分类浏览** ✓（它的 CSS 配置体里压根没有
    //   explore 这一类字段 ✓）。**Legado 源要走 Node 引擎的 explore** ✓——
    //   Node 侧 `explore()` 支持 `exploreUrl` / `ruleExploreUrl` /
    //   `ruleExplore.url` ✓，甚至**没配 exploreUrl 时会自动抓站点首页导航**
    //   探测真实分类 ✓（book_source.js:841-864 ✓）。
    //   原来这里用 `_canUseDart` 当门槛 ✗ ⇒ 不含 `@js:` 的 Legado 源全被
    //   拦在这里 ✗ ⇒ 用户点分类**永远**看到「未配置分类浏览」✗（= 用户报的
    //   那个报错 ✓）—— 而把 Legado 源交给 Node 就能真出分类 ✓。
    if (source.isConfig) {
      return (
        ok: false,
        error: '该源为 config 明文源，未配置分类浏览：可直接用搜索找书',
        categories: const <ExploreCategory>[],
      );
    }
    final data = await _callCached(
      {'action': 'bsExplore', 'source': source.raw, 'categoryUrl': null},
      _key('bsExploreCats', source.id),
      _detailTtl,
    );
    final m = _asMap(data);
    if (m['ok'] != true) {
      return (
        ok: false,
        error: (m['error'] ?? '获取分类失败').toString(),
        categories: const <ExploreCategory>[],
      );
    }
    final raw = m['categories'];
    final cats = <ExploreCategory>[];
    if (raw is List) {
      for (final it in raw) {
        if (it is Map) {
          final j = it.cast<String, dynamic>();
          final title = (j['title'] ?? '').toString().trim();
          final url = (j['url'] ?? '').toString().trim();
          if (title.isEmpty || url.isEmpty) continue;
          cats.add(ExploreCategory(title: title, url: url));
        }
      }
    }
    return (ok: true, error: null, categories: cats);
  }

  /// 分类页的书籍列表（ruleExplore 解析，对应分类网格内容）
  Future<({bool ok, String? error, List<BookSourceResult> list})>
      exploreBooks(BookSource source, String categoryUrl) async {
    // 同 exploreCategories：只有 config 明文源才真的没有分类浏览 ✓，
    // Legado 源一律交给 Node 引擎（它有完整的 ruleExplore 解析 ✓）。
    if (source.isConfig) {
      return (
        ok: false,
        error: '该源为 config 明文源，未配置分类浏览：可直接用搜索找书',
        list: const <BookSourceResult>[],
      );
    }
    final data = await _callCached(
      {'action': 'bsExplore', 'source': source.raw, 'categoryUrl': categoryUrl},
      _key('bsExploreBooks', '${source.id}::$categoryUrl'),
      _detailTtl,
    );
    final m = _asMap(data);
    if (m['ok'] != true) {
      return (
        ok: false,
        error: (m['error'] ?? '加载分类失败').toString(),
        list: const <BookSourceResult>[],
      );
    }
    final raw = m['list'];
    final out = <BookSourceResult>[];
    if (raw is List) {
      for (final it in raw) {
        if (it is Map) {
          final r =
              BookSourceResult.fromJson(it.cast<String, dynamic>(), source);
          if (r != null) out.add(r);
        }
      }
    }
    return (ok: true, error: null, list: out);
  }

  /// 书籍详情（详情页用；失败时返回 null 由 UI 退回搜索页已有字段）
  Future<Map<String, dynamic>?> bookInfo(
      BookSource source, String bookUrl) async {
    return (await bookInfoChecked(source, bookUrl)).info;
  }

  /// 详情（带错误原因）。
  ///
  /// 普通调用用 [bookInfo]（失败返回 null）；体检需要区分
  /// 「网络不通 / 解析失败」，用本方法拿 error。
  Future<({Map<String, dynamic>? info, String? error})> bookInfoChecked(
      BookSource source, String bookUrl) async {
    // ── 壳模式：qread 服务端执行 ruleBookInfo（解决本地引擎 @js: 垫片/500）──
     // ── config 明文源：Dart 侧引擎 ─────────────────────────────
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
    if (m['ok'] == false) {
      return (info: null, error: (m['error'] ?? '未知错误').toString());
    }
    final info = m['info'];
    return (
      info: info is Map ? info.cast<String, dynamic>() : null,
      error: null,
    );
  }

  /// 目录
  Future<({bool ok, String? error, List<BookSourceChapter> list})> toc(
    BookSource source,
    String tocUrl,
  ) async {
    // ── 壳模式：qread 服务端执行 ruleToc ─────────────────────
     // ── config 明文源：Dart 侧引擎 ─────────────────────────────
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
    // ── 壳模式：qread 服务端执行 ruleContent（含翻页聚合/净化）──
     // ── config 明文源：Dart 侧引擎（正文纯文字，无图片）──────
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

  /// 判断异常是否为「网络不通」（超时/拒连/DNS/连接失败/服务器返回错误码）。
  ///
  /// 体检按阶段细分「网络不通 / 解析失败」用：网络类 → 可代理复检；
  /// 解析/规则类 → 复检无意义，直接判失败。
  ///
  /// ✅ **判据已统一到 `utils/source_fail_text.dart`** ✓✓ —— 本函数与体检页的
  /// `_isNetworkError` 原来是**两份手写判据** ✗（体检页那段注释里写着「两处必须同步」✗）。
  /// 现在两处都只从 `describeSourceFail` 的**同一套分类**推导 ✓。
  ///
  /// ⚠️ **映射有意"三合一"** ✗✓：`DioException.badResponse`（403/500/502 ✓）在统一表里
  /// 会按码归到 `denied` / `apiBroken` ✓，而本函数的语义是"**网络/服务类**"✓ →
  /// 所以这三类**一并算网络** ✓✓，与改造前**完全等价** ✓（旧实现里 `badResponse` 也返回 true ✓）。
  /// 若这里只认 `network` ✗，403 会掉进"解析失败" ✗✗ —— 正是注释里记录过的老 bug（223 源误判 ✗）。
  static bool _isNetError(Object? e) {
    if (e == null) return false;
    final kind = describeSourceFail(e, what: '该源').kind;
    return kind == SourceFailKind.network ||
        kind == SourceFailKind.denied ||
        kind == SourceFailKind.apiBroken;
  }

  /// 对一个书源做体检：搜索 → 详情 → 目录 → 正文，逐级验证。
  ///
  /// 为什么逐级测而不是只测搜索：
  /// 很多坏源**搜索是好的**（列表页能抓），但详情/目录/正文的规则写错了。
  /// 只测搜索会给出"可用"的假结论，用户点进去才发现看不了。
  ///
  /// 关键词用大众小说名（默认「斗破苍穹」）：几乎所有中文书源都有，
  /// 命中率高、结果稳定 —— 搜 0 条基本可判定解析失败，而不是"词太冷"。
  ///
  /// 失败分类对齐原版 Cmbok（search/detail/toc/content 阶段 ×
  /// ok/network/parseFail）：网络类 → dead（体检页归「网络不通」）；
  /// 解析/规则类 → partial（体检页归「解析失败」）。
  Future<BookSourceHealth> healthCheck(
    BookSource source, {
    String keyword = '斗破苍穹',
    bool retryWithProxy = true,
  }) async {
    final sw = Stopwatch()..start();
    final notes = <String>[];

    // 1) 搜索（取书：确认书源里有没有这本书的名称/结果）
    final s = await searchOne(source, keyword);
    if (!s.ok) {
      sw.stop();
      final net = _isNetError(s.error);
      final h = BookSourceHealth(
        source: source,
        level: BookSourceHealthLevel.dead,
        detail: '搜索失败：${s.error}',
        elapsed: sw.elapsed,
      );
      // 网络不通才代理复检（解析失败代理也无济于事）
      return net ? await _retryWithProxy(h, keyword: keyword) : h;
    }
    if (s.list.isEmpty) {
      sw.stop();
      // 大众书名都搜不到 → 解析失败（不是"词太冷"）
      return BookSourceHealth(
        source: source,
        level: BookSourceHealthLevel.partial,
        detail: '解析失败：搜索「$keyword」返回 0 条',
        elapsed: sw.elapsed,
      );
    }
    notes.add('搜索 ${s.list.length} 条');

    final first = s.list.first;

    // 2) 详情（书的名称/作者/简介等）
    final r = await bookInfoChecked(source, first.bookUrl);
    if (r.info == null) {
      sw.stop();
      final net = _isNetError(r.error);
      final h = BookSourceHealth(
        source: source,
        level: net
            ? BookSourceHealthLevel.dead
            : BookSourceHealthLevel.partial,
        detail:
            '详情${net ? '网络不通' : '解析失败'}：${r.error ?? '规则无效'}',
        elapsed: sw.elapsed,
      );
      return net ? await _retryWithProxy(h, keyword: keyword) : h;
    }
    notes.add('详情 OK');

    // 3) 目录（章节列表）
    final tocUrl = (r.info!['tocUrl'] ?? first.bookUrl).toString();
    final t = await toc(source, tocUrl);
    if (!t.ok || t.list.isEmpty) {
      sw.stop();
      final net = _isNetError(t.error);
      final h = BookSourceHealth(
        source: source,
        level: net
            ? BookSourceHealthLevel.dead
            : BookSourceHealthLevel.partial,
        detail:
            '目录${net ? '网络不通' : '解析失败'}：${t.error ?? '规则无效'}',
        elapsed: sw.elapsed,
      );
      return net ? await _retryWithProxy(h, keyword: keyword) : h;
    }
    notes.add('目录 ${t.list.length} 章');

    // 4) 正文（抽第一章，确认能读到字）
    final c = await content(source, t.list.first.url);
    sw.stop();
    if (!c.ok || c.content.trim().isEmpty) {
      final net = _isNetError(c.error);
      final h = BookSourceHealth(
        source: source,
        level: net
            ? BookSourceHealthLevel.dead
            : BookSourceHealthLevel.partial,
        detail:
            '正文${net ? '网络不通' : '解析失败'}：${c.error ?? '正文为空'}',
        elapsed: sw.elapsed,
      );
      return net ? await _retryWithProxy(h, keyword: keyword) : h;
    }
    notes.add('正文 ${c.content.length} 字');

    return BookSourceHealth(
      source: source,
      level: BookSourceHealthLevel.healthy,
      detail: notes.join('，'),
      elapsed: sw.elapsed,
    );
  }

  /// 首次体检失败（搜索就挂）且全局代理开启时，带代理复检一遍。
  ///
  /// 对齐原版 Cmbok 体检文案「失败源会自动用代理档案复检一遍」：
  /// 很多源站直连不通、走代理能通，一次失败就判死太冤。
  /// 只复检一次、不递归；复检结果更好则用复检结果，否则保留首次结论。
  Future<BookSourceHealth> _retryWithProxy(
    BookSourceHealth h, {
    required String keyword,
  }) async {
    final proxy = globalProxyDisplay();
    if (proxy == null) return h;
    if (h.source.raw['proxy']?.toString().isNotEmpty ?? false) return h;
    final proxied = BookSource(
      raw: () {
        final m = Map<String, dynamic>.of(h.source.raw);
        m['proxy'] = proxy;
        return m;
      }(),
      id: h.source.id,
    );
    final h2 = await healthCheck(
      proxied,
      keyword: keyword,
      retryWithProxy: false,
    );
    if (h2.level.index < h.level.index) {
      return BookSourceHealth(
        source: h.source,
        level: h2.level,
        detail: '${h2.detail}（代理复检通过）',
        elapsed: h2.elapsed,
      );
    }
    return h;
  }

  /// 批量体检（并发限流同搜索）
  Future<List<BookSourceHealth>> healthCheckAll(
    List<BookSource> sources, {
    void Function(BookSourceHealth h)? onOne,
    bool Function()? shouldStop,
    String keyword = '斗破苍穹',
    int concurrency = maxConcurrent,
  }) async {
    final out = <BookSourceHealth>[];
    final pending = List<BookSource>.of(sources);
    final active = <Future<void>>[];
    final limit = concurrency.clamp(1, 12);

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
      while (active.length < limit && pending.isNotEmpty) {
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
