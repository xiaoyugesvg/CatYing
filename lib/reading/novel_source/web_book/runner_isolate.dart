/// 书源求值的 **worker isolate 池**（对应上游 2.0.8 的
/// `web_book/runner_pool.dart` + `killable_isolate.dart`）。
///
/// ── 为什么必须有它 ────────────────────────────────────────────
/// `SyncHttpBridge` 用 `SyncHttpClient`（阻塞 socket）实现 legado 的
/// `java.ajax` 同步语义，**在主 isolate 上跑会卡 UI**，最坏情况（网络挂死且
/// `sync_http` 无超时能力）会触发系统 watchdog 杀掉 App。所以那里有一道闸门：
///
/// ```dart
/// static bool allowBlockingOnCurrentIsolate = false;   // 默认关
/// ```
///
/// 本文件负责**在 worker isolate 内把闸门打开**，从而让 `java.ajax` 真正可用，
/// 同时保证阻塞只发生在 worker 里。
///
/// ── 2026-10-23 改为**常驻池**（原来每个动作 spawn 一个）──────────
/// 旧实现每次调用都 `Isolate.spawn` + 新建 quickjs runtime + 重新注入
/// `jsStandardPolyfills` / 繁简转换 / legado 宿主预置（几十万字符），
/// 还要每次都 `rootBundle.loadString(fetch.js)`。搜索结果并发 10 个源 =
/// 10 套 isolate × runtime 同时常驻，冷启动开销全压在每次搜索上。
///
/// 现在：
/// · worker **常驻复用**（最多 `maxWorkers` 个），runtime / 预置脚本 /
///   HTTP 缓存都只付一次代价；
/// · `fetch.js` 在主 isolate **只读一次**（`_fetchJsCache`）；
/// · 并发超过池容量时**排队**，而不是无限 spawn；
/// · 仍然保留「超时即杀」：`sync_http` 没有超时能力，超时后该 worker 可能
///   卡在阻塞 socket 上 ⇒ kill 掉并从池里移除，下次自动补一个新的。
///
/// ── 为什么不会无限递归 ───────────────────────────────────────
/// worker 内部调用 `WebBook.searchBook(...)`，而 `web_book.dart` 里判断
/// `BookSourceRunner.enabled` 决定是否走 isolate。**静态变量是 per-isolate 的**：
/// 新建的 worker 里 `enabled` 是初始值 `false`，所以 worker 走原始同步实现。
///
/// ── 已知取舍（如实标注）──────────────────────────────────────
/// · `getChapterList` 的 `onBatch` 回调**无法跨 isolate**，isolate 路径丢弃它，
///   只返回最终完整列表（调用方若依赖"首屏快显"需保留主 isolate 路径）。
/// · 常驻 worker 里的 cookie / HTTP 缓存会跨请求保留（per-isolate 静态）。
///   这是池化的收益（同站连查更快），但也意味着不同书源共享同一个 worker 的
///   进程级缓存；缓存均按 URL / 域名分键，不会串源规则。
/// · 超时值默认 60s（一章正文可能要多次翻页抓取）。可按书源调。
library;

import 'dart:async';
import 'dart:isolate';

import '../analyze/http_proxy.dart';
import '../analyze/sync_http_bridge.dart';
import '../model/book_source.dart';
import '../model/search_book.dart';
import '../model/xiaoshuo_book.dart';
import '../model/xiaoshuo_book_chapter.dart';
import '../novel_block.dart';
import 'web_book.dart'; // 已 export 'web_book_types.dart'
import 'dart:ui' show DartPluginRegistrant, RootIsolateToken;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart'
    show BackgroundIsolateBinaryMessenger, rootBundle;
// [FIX-JS-ISOLATE] worker 里 quickjs 的 fetch 扩展要读 JS 资源，而
// `rootBundle` 走 `ServicesBinding.instance`（binding 是 per-isolate 的）
// ⇒ 后台 isolate 里必然抛「Binding has not yet been initialized」✗
// 正解：**主 isolate 先把字符串读出来**，经 spawn 参数带进去，
// worker 侧用 `preloadFetchJs` 填进那个包的静态字段（见 fetch.dart 的说明）。
import 'package:quickjs_engine/extensions/fetch.dart'
    show kFetchJsAssetPath, kBundledFetchJs, preloadFetchJs;

/// 一次 isolate 执行的返回。
class RunnerResult {
  const RunnerResult({required this.ok, this.data, this.error});

  final bool ok;
  final Object? data;
  final String? error;

  bool get isTimeout => !ok && error == 'timeout';

  @override
  String toString() =>
      ok ? 'RunnerResult(ok, $data)' : 'RunnerResult(fail: $error)';
}

/// 书源链路 isolate 池（进程级单例）。
class BookSourceRunner {
  BookSourceRunner._();
  static final BookSourceRunner instance = BookSourceRunner._();

  /// 是否让 `WebBook` 的公开入口走 isolate。
  ///
  /// **默认 false** ⇒ 行为与打补丁前完全一致（零风险）。
  /// 打开后：`java.ajax` 等同步宿主调用才真正生效（因为闸门在 worker 里被打开）。
  static bool enabled = false;

  /// 默认超时：一章正文可能需要多次"下一页"抓取，给足时间。
  static const Duration defaultTimeout = Duration(seconds: 60);

  /// 常驻 worker 上限。
  ///
  /// 4 个：一次聚搜 40 个源时是 10 批而不是 40 个 runtime；
  /// 单个 worker 里 quickjs runtime 会复用，所以 4 个也够快。
  static const int maxWorkers = 4;

  /// worker 启动握手超时（spawn + binding 初始化）
  static const Duration _spawnTimeout = Duration(seconds: 20);

  final List<_Worker> _idle = [];
  final List<_Worker> _all = [];
  final List<Completer<_Worker>> _waiters = [];

  /// 正在 spawn 的数量：spawn 是异步的，`_all.length` 会滞后，
  /// 不单独计数的话并发 acquire 会超过 [maxWorkers]。
  int _spawning = 0;
  int _nextId = 1;

  /// 空闲 worker 的回收阈值。
  ///
  /// 常驻 worker 里是一个完整的 quickjs runtime（几十 MB），用户不搜索时
  /// 没必要一直占着内存。空闲超过 10 分钟就回收；下次要用时再 spawn
  /// （代价是一次握手 + fetch.js 注入，已经在 `_fetchJsCache` 里缓存过）。
  static const Duration _idleTtl = Duration(minutes: 10);
  Timer? _reapTimer;

  void _scheduleReap() {
    _reapTimer ??= Timer.periodic(
      const Duration(minutes: 1),
      (_) => _reapIdle(),
    );
  }

  void _reapIdle() {
    if (_idle.isEmpty) {
      _reapTimer?.cancel();
      _reapTimer = null;
      return;
    }
    final now = DateTime.now();
    for (final w in List<_Worker>.of(_idle)) {
      if (w.busy || w.dead) continue;
      if (now.difference(w.lastUsed) <= _idleTtl) continue;
      _idle.remove(w);
      _kill(w, '空闲超时回收');
    }
  }

  /// fetch.js 源码只在主 isolate 读一次（原来每次 run 都读 bundle）。
  static String? _fetchJsCache;

  static Future<String> _loadFetchJs() async {
    final cached = _fetchJsCache;
    if (cached != null) return cached;
    String js;
    try {
      js = await rootBundle.loadString(kFetchJsAssetPath);
    } catch (_) {
      // iOS 打包时这条包资源偶发不在 asset manifest 里（日志里那句
      // `Unable to load asset: "packages/quickjs_engine/assets/js/fetch.js"`）。
      // 用内置常量顶上：内容等价，还能省掉 worker 侧的重复失败与日志噪音。
      js = kBundledFetchJs;
    }
    _fetchJsCache = js;
    return js;
  }

  /// 在 worker isolate 里执行一次书源动作。
  ///
  /// [action] ∈ `search` / `bookInfo` / `toc` / `content` / `exploreBooks`
  /// [payload] 必须是 JSON 可编码的（含 `source`）。
  Future<RunnerResult> run(
    String action,
    Map<String, dynamic> payload, {
    Duration? timeout,
  }) async {
    _Worker? w;
    try {
      w = await _acquire();
      // ⚠️ worker 没有 cmd 端口 = 它其实已经废了。原来 `w.cmd?.send` 是空操作，
      //   于是调用方会**干等到 60s 超时**才失败（搜索页一直转圈）。就地判死。
      final cmd = w.cmd;
      if (cmd == null) {
        _onWorkerGone(w, 'worker 未就绪（无命令端口）');
        return const RunnerResult(ok: false, error: 'worker 未就绪');
      }
      final rid = w.nextRequestId();
      final done = Completer<Map<String, Object?>>();
      w.pending[rid] = done;
      cmd.send(<Object?>[rid, action, payload]);

      Map<String, Object?> msg;
      try {
        msg = await done.future.timeout(
          timeout ?? defaultTimeout,
          onTimeout: () =>
              const <String, Object?>{'ok': false, 'error': 'timeout'},
        );
      } finally {
        w.pending.remove(rid);
      }
      if (msg['error'] == 'timeout') {
        // sync_http 没有超时能力：超时后 worker 可能永远卡在阻塞 socket 上
        // ⇒ 必须杀，并且不能放回池里
        _kill(w, 'timeout');
      }
      return RunnerResult(
        ok: msg['ok'] == true,
        data: msg['data'],
        error: msg['error']?.toString(),
      );
    } catch (e) {
      return RunnerResult(ok: false, error: '$e');
    } finally {
      if (w != null) _release(w);
    }
  }

  // ── 池管理 ───────────────────────────────────────────────────

  Future<_Worker> _acquire() async {
    // 取一个空闲 worker
    while (_idle.isNotEmpty) {
      final w = _idle.removeLast();
      if (!w.dead) {
        w.busy = true;
        return w;
      }
    }
    if (_all.length + _spawning < maxWorkers) {
      _spawning++;
      try {
        final w = await _spawn();
        _all.add(w);
        w.busy = true;
        return w;
      } finally {
        _spawning--;
      }
    }
    // 池满：排队等释放
    final c = Completer<_Worker>();
    _waiters.add(c);
    return c.future;
  }

  void _release(_Worker w) {
    w.busy = false;
    if (w.dead) {
      _pump();
      return;
    }
    w.touch();
    if (_waiters.isNotEmpty) {
      final c = _waiters.removeAt(0);
      w.busy = true;
      c.complete(w);
      return;
    }
    _idle.add(w);
    _scheduleReap();
    _pump();
  }

  /// 把空闲 worker 分给等待者；不够就补 spawn。
  void _pump() {
    while (_waiters.isNotEmpty && _idle.isNotEmpty) {
      final w = _idle.removeLast();
      if (w.dead) continue;
      final c = _waiters.removeAt(0);
      w.busy = true;
      c.complete(w);
    }
    if (_waiters.isNotEmpty && _all.length + _spawning < maxWorkers) {
      final c = _waiters.removeAt(0);
      _spawning++;
      _spawn().then((w) {
        _all.add(w);
        w.busy = true;
        if (!c.isCompleted) c.complete(w);
      }).catchError((Object e) {
        if (!c.isCompleted) c.completeError(e);
      }).whenComplete(() {
        _spawning--;
        _pump();
      });
    }
  }

  void _onWorkerGone(_Worker w, String reason) {
    if (w.dead) return;
    w.dead = true;
    _idle.remove(w);
    _all.remove(w);
    // 该 worker 上还挂着的请求：立刻失败，别让调用方等满 60s
    for (final c in w.pending.values) {
      if (!c.isCompleted) {
        c.complete(<String, Object?>{'ok': false, 'error': reason});
      }
    }
    w.pending.clear();
    w.closePorts();
    debugPrint('[书源/worker] ${w.id} 退出：$reason');
    _pump();
  }

  void _kill(_Worker w, String reason) {
    _onWorkerGone(w, reason);
    w.isolate?.kill(priority: Isolate.immediate);
  }

  Future<_Worker> _spawn() async {
    final id = _nextId++;
    final handshake = ReceivePort();
    final reply = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();

    // 代理必须在**主 isolate**（= 本方法所在）启动：worker 里发起同步请求会
    // 阻塞自身事件循环，代理若同在 worker 就永远无法响应（死锁）。
    final proxyPort = await LegadoHttpProxy.ensureStarted();
    final fetchJs = await _loadFetchJs();

    final worker = _Worker(
      id: id,
      handshake: handshake,
      reply: reply,
      errors: errorPort,
      exits: exitPort,
    );

    Isolate? isolate;
    try {
      isolate = await Isolate.spawn<List<Object?>>(
        _workerMain,
        <Object?>[
          handshake.sendPort,
          reply.sendPort,
          proxyPort,
          // [FIX-JS-ISOLATE] 仍然带上 token：万一将来还有别的插件通道
          // 需要它（`BackgroundIsolateBinaryMessenger`），留着无副作用
          RootIsolateToken.instance,
          fetchJs,
        ],
        debugName: 'book-source-runner-$id',
        onError: errorPort.sendPort, // worker 内未捕获异常 → [error, stack]
        onExit: exitPort.sendPort, // worker 结束 → null
      );
      worker.isolate = isolate;

      // 握手：worker 把自己的命令端口发回来
      final cmd = await handshake.first.timeout(_spawnTimeout);
      if (cmd is! SendPort) throw StateError('worker 握手返回了意外类型');
      worker.cmd = cmd;

      reply.listen((m) {
        if (m is! List || m.length < 2) return;
        final rid = m[0];
        if (rid is! int) return;
        final c = worker.pending.remove(rid);
        final body = m[1];
        c?.complete(
          body is Map
              ? body.cast<String, Object?>()
              : <String, Object?>{
                  'ok': false,
                  'error': 'worker 返回了意外类型: ${body.runtimeType}',
                },
        );
      });
      errorPort.listen((e) {
        final detail = (e is List && e.isNotEmpty) ? e.first : e;
        _onWorkerGone(worker, 'worker 异常: $detail');
      });
      exitPort.listen((_) => _onWorkerGone(worker, 'worker 已退出'));
      return worker;
    } catch (e) {
      isolate?.kill(priority: Isolate.immediate);
      worker.closePorts();
      rethrow;
    }
  }

  // ── 便捷封装（返回强类型，供 `web_book.dart` 的 isolate 分支调用）──

  Future<List<SearchBook>> searchBook({
    required XiaoshuoBookSource source,
    required String key,
    int page = 1,
    Duration? timeout,
  }) async {
    final r = await run('search', {
      'source': source.toJson(),
      'key': key,
      'page': page,
    }, timeout: timeout);
    if (!r.ok) throw Exception('书源搜索失败(isolate): ${r.error}');
    return _decodeList(r.data, SearchBook.fromJson);
  }

  Future<XiaoshuoBook> getBookInfo({
    required XiaoshuoBookSource source,
    required String bookUrl,
    Duration? timeout,
  }) async {
    final r = await run('bookInfo', {
      'source': source.toJson(),
      'bookUrl': bookUrl,
    }, timeout: timeout);
    if (!r.ok) throw Exception('书源详情失败(isolate): ${r.error}');
    return XiaoshuoBook.fromJson(_asMap(r.data));
  }

  Future<List<XiaoshuoBookChapter>> getChapterList({
    required XiaoshuoBookSource source,
    required XiaoshuoBook book,
    Duration? timeout,
  }) async {
    final r = await run('toc', {
      'source': source.toJson(),
      'book': book.toJson(),
    }, timeout: timeout);
    if (!r.ok) throw Exception('书源目录失败(isolate): ${r.error}');
    return _decodeList(r.data, XiaoshuoBookChapter.fromJson);
  }

  Future<List<XiaoshuoBook>> exploreBooks({
    required XiaoshuoBookSource source,
    required String categoryUrl,
    int page = 1,
    Duration? timeout,
  }) async {
    final r = await run('exploreBooks', {
      'source': source.toJson(),
      'categoryUrl': categoryUrl,
      'page': page,
    }, timeout: timeout);
    if (!r.ok) throw Exception('书源发现页失败(isolate): ${r.error}');
    return _decodeList(r.data, XiaoshuoBook.fromJson);
  }

  Future<BookContentResult> getContent({
    required XiaoshuoBookSource source,
    required String chapterUrl,
    XiaoshuoBook? originalBook,
    Duration? timeout,
  }) async {
    final r = await run('content', {
      'source': source.toJson(),
      'chapterUrl': chapterUrl,
      if (originalBook != null) 'originalBook': originalBook.toJson(),
    }, timeout: timeout);
    if (!r.ok) throw Exception('书源正文失败(isolate): ${r.error}');
    return _contentFromJson(_asMap(r.data));
  }

  static Map<String, dynamic> _asMap(Object? v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return v.cast<String, dynamic>();
    throw Exception('isolate 返回的不是对象: ${v.runtimeType}');
  }

  static List<T> _decodeList<T>(
    Object? data,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    if (data is! List) return <T>[];
    return data
        .whereType<Map>()
        .map((e) => fromJson(e.cast<String, dynamic>()))
        .toList();
  }
}

/// 一个常驻 worker 的运行态。
class _Worker {
  _Worker({
    required this.id,
    required this.handshake,
    required this.reply,
    required this.errors,
    required this.exits,
  });

  final int id;
  final ReceivePort handshake;
  final ReceivePort reply;
  final ReceivePort errors;
  final ReceivePort exits;

  Isolate? isolate;
  SendPort? cmd;
  bool busy = false;
  bool dead = false;

  /// 未完成请求：rid → completer
  final Map<int, Completer<Map<String, Object?>>> pending = {};

  int _rid = 0;
  int nextRequestId() => ++_rid;

  DateTime lastUsed = DateTime.now();
  void touch() => lastUsed = DateTime.now();

  void closePorts() {
    handshake.close();
    reply.close();
    errors.close();
    exits.close();
  }
}

/// worker isolate 入口：**打开闸门**后等待任务，结果 JSON 化回传。
///
/// ⚠️ 这里是整个方案的关键一步：`SyncHttpBridge.allowBlockingOnCurrentIsolate = true`
/// 只在这个 isolate 里生效（静态变量 per-isolate），所以阻塞不会落到 UI 线程。
///
/// 返回类型必须是 **`void`**（不是 `Future<void>`）：`Isolate.spawn` 要求
/// `void Function(T)`；`async` 函数写 `void` 返回是合法且惯用的。
void _workerMain(List<Object?> args) async {
  final handshake = args[0] as SendPort;
  final toMain = args[1] as SendPort;
  final proxyPort = args.length > 2 ? (args[2] as int? ?? 0) : 0;
  final token = args.length > 3 ? args[3] : null;
  final fetchJs = args.length > 4 ? args[4] as String? : null;

  // ★ 闸门只在此 isolate 打开（主 isolate 永远保持 false）
  SyncHttpBridge.allowBlockingOnCurrentIsolate = true;
  // 本机同步代理端口（主 isolate 启动，经 spawn 参数传入 —— 静态变量 per-isolate）
  SyncHttpBridge.proxyPort = proxyPort;

  // [FIX-JS-ISOLATE] 把主 isolate 传来的 fetch.js 源码存好。
  // ⚠️ 必须在创建 runtime 之前做：`getJavascriptRuntime()` 内部会
  //    `runtime.enableFetch()`，那时就要用这个静态字段了。
  if (!preloadFetchJs(fetchJs)) {
    debugPrint('[BookSourceRunner] 未收到预加载的 fetch.js，将走兜底路径');
  }

  if (token is RootIsolateToken) {
    try {
      // ⚠️ 这两句**必须配套**：只调 messenger 不够 ✗ —— `rootBundle` 走的是
      // `ServicesBinding.instance`（binding 本身 ✗），实测只加 messenger 时
      // quickjs 的 fetch 扩展仍抛「Binding has not yet been initialized」✗。
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
      DartPluginRegistrant.ensureInitialized();
    } catch (_) {
      // 拿不到绑定（纯 dart:io / flutter test 环境）时**不能崩** ✗：
      // JsEngine 侧另有兜底（从磁盘读 fetch.js / 用内置常量）。
    }
  }

  // ── 长驻：接收任务 → 执行 → 回包，直到被 kill ────────────────
  final cmdPort = ReceivePort();
  handshake.send(cmdPort.sendPort);

  cmdPort.listen((m) async {
    if (m is! List || m.length < 3) return;
    final rid = m[0];
    if (rid is! int) return;
    final action = '${m[1]}';
    final payload = m[2] is Map
        ? (m[2] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    try {
      final data = await _execute(action, payload);
      toMain.send(<Object?>[
        rid,
        <String, Object?>{'ok': true, 'data': data},
      ]);
    } catch (e, st) {
      toMain.send(<Object?>[
        rid,
        <String, Object?>{'ok': false, 'error': '$e', 'stack': '$st'},
      ]);
    }
  });
}

/// worker 内的动作实现（结果必须是可跨 isolate 传输的 JSON 结构）。
Future<Object?> _execute(String action, Map<String, dynamic> payload) async {
  final rawSource = payload['source'];
  if (rawSource is! Map) throw Exception('缺少 source');
  final source = XiaoshuoBookSource.fromJson(
    rawSource.cast<String, dynamic>(),
  );
  final wb = WebBook();

  switch (action) {
    case 'search':
      final list = await wb.searchBook(
        source: source,
        key: payload['key']?.toString() ?? '',
        page: payload['page'] is int ? payload['page'] as int : 1,
      );
      return _jsonSafe(list);
    case 'bookInfo':
      final book = await wb.getBookInfo(
        source: source,
        bookUrl: payload['bookUrl']?.toString() ?? '',
      );
      return _jsonSafe(book);
    case 'toc':
      final book = XiaoshuoBook.fromJson(
        (payload['book'] as Map).cast<String, dynamic>(),
      );
      // onBatch 无法跨 isolate：isolate 路径只回最终完整列表
      final chapters = await wb.getChapterList(source: source, book: book);
      return _jsonSafe(chapters);
    case 'exploreBooks':
      // [PATCH-13] 发现页分类列表（bsExplore + categoryUrl）
      final books = await wb.exploreCategory(
        source: source,
        categoryUrl: payload['categoryUrl']?.toString() ?? '',
        page: payload['page'] is int ? payload['page'] as int : 1,
      );
      return _jsonSafe(books);
    case 'content':
      final ob = payload['originalBook'];
      final result = await wb.getContent(
        source: source,
        chapterUrl: payload['chapterUrl']?.toString() ?? '',
        originalBook:
            ob is Map ? XiaoshuoBook.fromJson(ob.cast<String, dynamic>()) : null,
      );
      return _contentToJson(result);
    default:
      throw Exception('未知动作: $action');
  }
}

// ── BookContentResult 的手工 JSON 编解码 ────────────────────────
//
// 为什么不用通用 `_jsonSafe`：`BookContentResult` / `NovelBlock` **都没有**
// `toJson/fromJson`（已核实：`web_book_types.dart` 与 `novel_block.dart`），
// 走通用路径会把 `blocks` 退化成字符串 ⇒ 阅读器新链路读 `blocks` 渲染
// ⇒ **正文空白**。所以这里显式编码为
// `{'content':…, 'error':…, 'blocks':[{'t':'img'|'text',…}]}`。
//
// 块类型构造签名（已核实）：
//   `NovelTextBlock(String text, {bool isHeading = false})`
//   `NovelImageBlock(String url, {String? style})`

Map<String, Object?> _contentToJson(BookContentResult r) => <String, Object?>{
      'content': r.content,
      'error': r.error,
      'blocks': r.blocks.map<Object?>((b) {
        if (b is NovelImageBlock) {
          return <String, Object?>{'t': 'img', 'url': b.url, 'style': b.style};
        }
        if (b is NovelTextBlock) {
          return <String, Object?>{'t': 'text', 'text': b.text, 'h': b.isHeading};
        }
        return <String, Object?>{'t': 'text', 'text': '$b', 'h': false};
      }).toList(),
    };

BookContentResult _contentFromJson(Map<String, dynamic> m) {
  final blocks = <NovelBlock>[];
  final raw = m['blocks'];
  if (raw is List) {
    for (final e in raw) {
      if (e is! Map) continue;
      if ('${e['t']}' == 'img') {
        final url = e['url']?.toString() ?? '';
        if (url.isEmpty) continue;
        blocks.add(NovelImageBlock(url, style: e['style']?.toString()));
      } else {
        blocks.add(NovelTextBlock(
          e['text']?.toString() ?? '',
          isHeading: e['h'] == true,
        ));
      }
    }
  }
  return BookContentResult(
    content: m['content']?.toString() ?? '',
    blocks: blocks,
    error: m['error']?.toString(),
  );
}

/// 尽力把结果转成可跨 isolate 传输的结构：优先 `toJson()`，
/// 缺失时退化为字符串，**绝不抛异常**（否则调用方只能等超时）。
Object? _jsonSafe(Object? v) {
  if (v == null || v is String || v is num || v is bool) return v;
  if (v is List) return v.map(_jsonSafe).toList();
  if (v is Map) {
    return v.map((k, val) => MapEntry('$k', _jsonSafe(val)));
  }
  try {
    final d = v as dynamic;
    return d.toJson();
  } catch (_) {
    return '$v';
  }
}
