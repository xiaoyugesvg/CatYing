/// 书源求值的 **worker isolate 执行器**（对应上游 2.0.8 的
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
/// 实测依据：224 条内置书源里 `java.ajax` 出现 **45 次 / 25 条源**。
///
/// ── 设计（照 `qsgy-edge/liber` 的 `content_processing.dart` 做法）──
/// · **每个动作 spawn 一个 isolate**（不是常驻池）：
///   简单、无泄漏、天然隔离缓存（`SyncHttpBridge.cache` / `HostBridge.cache`
///   在新 isolate 里是全新的，不会串会话）。
/// · **超时即杀**：`receive.first.timeout(...)` 触发后 `Isolate.kill(immediate)`
///   —— 这是 `sync_http` 没有超时能力时**唯一**的兜底手段。
/// · 输入输出全部 **JSON 往返**（模型都已有 `toJson/fromJson`），
///   因此不需要在 isolate 之间传递任意对象。
///
/// ── 为什么不会无限递归 ───────────────────────────────────────
/// worker 内部调用 `WebBook.searchBook(...)`，而 `web_book.dart` 里判断
/// `BookSourceRunner.enabled` 决定是否走 isolate。**静态变量是 per-isolate 的**：
/// 新建的 worker 里 `enabled` 是初始值 `false`，所以 worker 走的是原始同步实现。
///
/// ── 已知取舍（如实标注）──────────────────────────────────────
/// · `getChapterList` 的 `onBatch` 回调**无法跨 isolate**，isolate 路径丢弃它，
///   只返回最终完整列表（调用方若依赖"首屏快显"需保留主 isolate 路径）。
/// · 每个动作一次 spawn（约 10~50ms 开销 + JS 引擎冷启动）。上游用常驻
///   `runner_pool` 摊薄这个成本；若实测开销明显，再升级为池化。
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
import 'web_book.dart';   // 已 export 'web_book_types.dart'
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
    show kFetchJsAssetPath, preloadFetchJs;

/// 一次 isolate 执行的返回。
class RunnerResult {
  const RunnerResult({required this.ok, this.data, this.error});

  final bool ok;
  final Object? data;
  final String? error;

  bool get isTimeout => !ok && error == 'timeout';

  @override
  String toString() => ok ? 'RunnerResult(ok, $data)' : 'RunnerResult(fail: $error)';
}

/// 书源链路 isolate 执行器（进程级单例）。
class BookSourceRunner {
  BookSourceRunner._();
  static final BookSourceRunner instance = BookSourceRunner._();

  /// 是否让 `WebBook` 的公开入口走 isolate。
  ///
  /// **默认 false** ⇒ 行为与打补丁前完全一致（零风险）。
  /// 打开后：`java.ajax` 等同步宿主调用才真正生效（因为闸门在 worker 里被打开）。
  ///
  /// 建议接入点：App 启动或书源模块初始化处
  /// `BookSourceRunner.enabled = true;`
  static bool enabled = false;

  /// 默认超时：一章正文可能需要多次"下一页"抓取，给足时间。
  static const Duration defaultTimeout = Duration(seconds: 60);

  /// 在 worker isolate 里执行一次书源动作。
  ///
  /// [action] ∈ `search` / `bookInfo` / `toc` / `content`
  /// [payload] 必须是 JSON 可编码的（含 `source`）。
  Future<RunnerResult> run(
    String action,
    Map<String, dynamic> payload, {
    Duration? timeout,
  }) async {
    final receive = ReceivePort();
    Isolate? isolate;
    try {
      // 代理必须在**主 isolate**（= 本方法所在）启动：worker 里发起同步请求会
      // 阻塞自身事件循环，代理若同在 worker 就永远无法响应（死锁）。
      final proxyPort = await LegadoHttpProxy.ensureStarted();

      // ── [FIX-JS-ISOLATE 步骤①] 主 isolate 先把 fetch.js **读成字符串** ──
      //
      // ⚠️ 这一步是"能不能用 @js 规则"的**决定性环节**：
      //    worker 里 `rootBundle` 会因为"后台 isolate 没有 ServicesBinding"
      //    而抛异常（实测量 16 次 Unhandled exception）✗
      // ⇒ 老办法（传 RootIsolateToken + BackgroundIsolateBinaryMessenger
      //    + DartPluginRegistrant）**都绕不过**，因为 `rootBundle` 用的是
      //    binding **对象本身**，不是 messenger ✗
      // ⇒ 只有"主 isolate 读好、把字符串传进去"才成立 ✓
      //
      // ⚠️ 读失败**不能影响主流程**：这里 catch 住，worker 侧还有
      //    "磁盘兜底 / 内置常量"两级（见 fetch.dart）✓
      String? fetchJs;
      try {
        fetchJs = await rootBundle.loadString(kFetchJsAssetPath);
      } catch (e) {
        // 桌面/测试环境偶发取不到，交给 worker 的兜底路径
        // ignore: avoid_print
        debugPrint('[BookSourceRunner] 预加载 fetch.js 失败（有兜底）: $e');
      }

      isolate = await Isolate.spawn<List<Object?>>(
        _runnerMain,
        <Object?>[
          receive.sendPort,
          action,
          payload,
          proxyPort,
          // [FIX-JS-ISOLATE] 仍然带上 token：万一将来还有别的插件通道
          // 需要它（`BackgroundIsolateBinaryMessenger`），留着无副作用；
          // 但**fetch.js 的资源问题不靠它解决**（见上面的说明）。
          RootIsolateToken.instance,
          // 步骤①的产物：fetch.js 源码字符串（可能为 null → worker 走兜底）
          fetchJs,
        ],
        debugName: 'book-source-runner',
      );
      final msg = await receive.first.timeout(
        timeout ?? defaultTimeout,
        onTimeout: () => const <String, Object?>{'ok': false, 'error': 'timeout'},
      );
      if (msg is Map) {
        return RunnerResult(
          ok: msg['ok'] == true,
          data: msg['data'],
          error: msg['error']?.toString(),
        );
      }
      return RunnerResult(ok: false, error: 'isolate 返回了意外类型: ${msg.runtimeType}');
    } catch (e) {
      return RunnerResult(ok: false, error: '$e');
    } finally {
      // ⚠️ 必须杀：sync_http 无超时能力，超时后 isolate 仍可能卡在阻塞 socket 上
      isolate?.kill(priority: Isolate.immediate);
      receive.close();
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

/// worker isolate 入口：**打开闸门**后执行动作，结果 JSON 化回传。
///
/// ⚠️ 这里是整个方案的关键一步：`SyncHttpBridge.allowBlockingOnCurrentIsolate = true`
/// 只在这个 isolate 里生效（静态变量 per-isolate），所以阻塞不会落到 UI 线程。
///
/// 返回类型必须是 **`void`**（不是 `Future<void>`）：`Isolate.spawn` 要求
/// `void Function(T)`；`async` 函数写 `void` 返回是合法且惯用的。
void _runnerMain(List<Object?> args) async {
  final reply = args[0] as SendPort;
  final action = args[1] as String? ?? '';
  final payload = (args[2] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};

  // ★ 闸门只在此 isolate 打开（主 isolate 永远保持 false）
  SyncHttpBridge.allowBlockingOnCurrentIsolate = true;
  // 本机同步代理端口（主 isolate 启动，经 spawn 参数传入 —— 静态变量 per-isolate）
  SyncHttpBridge.proxyPort = args.length > 3 ? (args[3] as int? ?? 0) : 0;

  // [FIX-JS-ISOLATE] 打通本 isolate 的资源访问：quickjs 的 fetch 扩展会
  // `rootBundle.loadString(...)` 读 JS，而 `ServicesBinding.instance` 是
  // **per-isolate** 的 ✗ ⇒ 之前这里抛「Binding has not yet been initialized」，
  // 导致**所有 `@js` 规则（搜索 / 目录 / 正文）失败** ✗（发现页能用是因为它跑在主 isolate）。
  // 官方做法：主 isolate 取 `RootIsolateToken` 经 spawn 传进来，这里 ensureInitialized ✓。
  // ── [FIX-JS-ISOLATE 步骤①b] 把主 isolate 传来的 fetch.js 源码存好 ──
  //
  // ⚠️ 必须在**创建 runtime 之前**做：`getJavascriptRuntime()` 内部会
  //    `runtime.enableFetch()`，那时就要用这个静态字段了。
  // ⚠️ **静态字段是 per-isolate 的** ⇒ 每个 worker 都必须自己 preload 一次 ✓
  final preloaded = args.length > 5 ? args[5] as String? : null;
  final preloadOk = preloadFetchJs(preloaded);
  if (!preloadOk) {
    // 不崩：包的 fetch 扩展有磁盘/内置常量兜底
    // ignore: avoid_print
    debugPrint('[BookSourceRunner] 未收到预加载的 fetch.js，将走兜底路径');
  }

  if (args.length > 4 && args[4] is RootIsolateToken) {
    try {
      // ⚠️ 这两句**必须配套**：只调 messenger 不够 ✗ —— `rootBundle` 走的是
      // `ServicesBinding.instance`（binding 本身 ✗），实测只加 messenger 时
      // quickjs 的 fetch 扩展仍抛「Binding has not yet been initialized」✗。
      BackgroundIsolateBinaryMessenger.ensureInitialized(args[4] as RootIsolateToken);
      DartPluginRegistrant.ensureInitialized();
    } catch (_) {
      // 拿不到绑定（纯 dart:io / flutter test 环境）时**不能崩** ✗：
      // JsEngine 侧另有兜底（从磁盘读 fetch.js / 用内置常量）。
    }
  }

  void sendBack(Map<String, Object?> msg) {
    try {
      reply.send(msg);
    } catch (e) {
      // 兜底：结果里混入不可传输对象时，退化成纯文本错误，避免调用方一直等到超时
      try {
        reply.send(<String, Object?>{'ok': false, 'error': 'isolate 结果不可传输: $e'});
      } catch (_) {/* 已无法回传，让调用方走超时分支 */}
    }
  }

  try {
    final source = XiaoshuoBookSource.fromJson(
      (payload['source'] as Map).cast<String, dynamic>(),
    );
    final wb = WebBook();

    switch (action) {
      case 'search':
        final list = await wb.searchBook(
          source: source,
          key: payload['key']?.toString() ?? '',
          page: payload['page'] is int ? payload['page'] as int : 1,
        );
        sendBack(<String, Object?>{'ok': true, 'data': _jsonSafe(list)});
        return;
      case 'bookInfo':
        final book = await wb.getBookInfo(
          source: source,
          bookUrl: payload['bookUrl']?.toString() ?? '',
        );
        sendBack(<String, Object?>{'ok': true, 'data': _jsonSafe(book)});
        return;
      case 'toc':
        final book = XiaoshuoBook.fromJson(
          (payload['book'] as Map).cast<String, dynamic>(),
        );
        // onBatch 无法跨 isolate：isolate 路径只回最终完整列表
        final chapters = await wb.getChapterList(source: source, book: book);
        sendBack(<String, Object?>{'ok': true, 'data': _jsonSafe(chapters)});
        return;
      case 'exploreBooks':
        // [PATCH-13] 发现页分类列表（bsExplore + categoryUrl）
        final books = await wb.exploreCategory(
          source: source,
          categoryUrl: payload['categoryUrl']?.toString() ?? '',
          page: payload['page'] is int ? payload['page'] as int : 1,
        );
        sendBack(<String, Object?>{'ok': true, 'data': _jsonSafe(books)});
        return;
      case 'content':
        final ob = payload['originalBook'];
        final result = await wb.getContent(
          source: source,
          chapterUrl: payload['chapterUrl']?.toString() ?? '',
          originalBook:
              ob is Map ? XiaoshuoBook.fromJson(ob.cast<String, dynamic>()) : null,
        );
        sendBack(<String, Object?>{'ok': true, 'data': _contentToJson(result)});
        return;
      default:
        sendBack(<String, Object?>{'ok': false, 'error': '未知动作: $action'});
        return;
    }
  } catch (e, st) {
    sendBack(<String, Object?>{'ok': false, 'error': '$e', 'stack': '$st'});
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
