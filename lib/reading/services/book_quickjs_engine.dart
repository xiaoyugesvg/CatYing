// lib/reading/services/book_quickjs_engine.dart
//
// 书源规则引擎的 **QuickJS 实验实现**（2026-10-21）。
//
// ── 它跑的是什么 ──────────────────────────────────────────────
// 不是重写规则引擎，而是把 Node 侧同一份 `book_source.js` + `book_rule.js`
// （含 cheerio / crypto-js）通过 esbuild 打成 `assets/js/book_engine_qjs.js`，
// 配上 `qjs_shims/`（axios→宿主 HTTP、vm→new Function、crypto→crypto-js、
// Buffer→Uint8Array）在 QuickJS 里执行。
//
// ── 在链路里的位置 ────────────────────────────────────────────
// 现有顺序：Dart 原生引擎 → Python 引擎 → **QuickJS（本引擎，可选）** → Node。
// 默认 `node`（保持现状）；切到 `auto`/`quickjs` 时：
//   · auto    → QuickJS 返回 null / 抛异常就继续回落 Node
//   · quickjs → 失败直接返回错误（便于对比测试）
//
// ⚠️ QuickJS 的 vm 垫片对 `jsLib` 的顶层声明做了回写，但与真 Node vm
//    仍有差异（无 timeout、无真正隔离）。所以定位是「实验」，
//    Node 永远保留为兜底。

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:quickjs_engine/quickjs_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/reading/quickjs/book_js_prelude.dart';

class BookQuickJsEngine {
  BookQuickJsEngine._();
  static final BookQuickJsEngine instance = BookQuickJsEngine._();

  static const String _prefKey = 'reader_book_engine'; // node | auto | quickjs
  static const String _bundleAsset = 'assets/js/book_engine_qjs.js';
  static const Duration _callTimeout = Duration(seconds: 32);

  final mode = ValueNotifier<String>('node');

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 25),
    followRedirects: true,
  ));

  // ── runtime 池（2026-10-21 第一批）────────────────────────────
  //
  // 之前是**单 runtime 跨所有书源复用**：
  //   · 上一个源的 jsLib 顶层函数/全局变量会残留到下一个源
  //   · 一条慢规则阻塞整个队列（所有源一起等）
  //
  // 现在按**源**分桶，最多 2 个 runtime：
  //   · 同源请求仍串行（QuickJS 单线程）
  //   · 不同源可并行（各自一个 runtime + 各自队列）
  //   · 切换源时旧 runtime 保留在池里（LRU 淘汰时销毁）——
  //     只要池里还有位置，回到旧源不用重新解析 460KB bundle
  //   · 单次调用超时 → **销毁该 runtime**，避免脏状态继续被使用
  static const int _maxRuntimes = 2;
  static const Duration _idleEvict = Duration(minutes: 10);

  final List<_PooledRuntime> _pool = [];
  String? _bundle;
  Future<void>? _initFuture;
  bool _broken = false;
  /// 读取偏好（幂等）。UI 与 `_call` 都可以 await 它。
  Future<void> ensureInit() {
    return _initFuture ??= _doInit();
  }

  Future<void> _doInit() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(_prefKey);
      if (v == 'node' || v == 'auto' || v == 'quickjs') mode.value = v!;
    } catch (_) {}
  }

  Future<void> setMode(String v) async {
    if (v != 'node' && v != 'auto' && v != 'quickjs') return;
    mode.value = v;
    // 切回 Node 时释放 QuickJS 占的内存
    if (v == 'node') disposeAll();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, v);
    } catch (e) {
      debugPrint('[BookQJS] 保存引擎设置失败: $e');
    }
  }

  /// 执行一个书源 action。
  ///
  /// 返回 Map = 成功（与 Node `/book/source` 同形）；
  /// 返回 null = 本引擎不可用/失败（调用方按 engine 设置决定是否回落 Node）。
  Future<Map<String, dynamic>?> call(
    String action,
    Map<String, dynamic> payload,
  ) async {
    if (_broken) return null;
    await ensureInit();
    final sourceKey = _sourceKeyOf(payload);
    _PooledRuntime? pooled;
    try {
      pooled = await _acquire(sourceKey);
      if (pooled == null) return null;
      final p = pooled;
      return await p.enqueue(() => _runCall(p.rt, action, payload));
    } on _QuickJsTimeout {
      // 超时 = 脚本可能死循环/状态不可信 → 销毁这个 runtime，下次重建
      if (pooled != null) {
        debugPrint('[BookQJS] $action 超时，销毁 runtime（${pooled.sourceKey}）');
        _dropRuntime(pooled);
      }
      return null;
    } catch (e) {
      debugPrint('[BookQJS] 调用失败：$e');
      return null;
    }
  }

  /// 当前请求属于哪个书源（用于 runtime 分桶 / 换源隔离）。
  ///
  /// `bookSourceUrl` 是 Legado 源的稳定主键；没有时退回源名。
  String _sourceKeyOf(Map<String, dynamic> payload) {
    final src = payload['source'];
    if (src is Map) {
      final u = (src['bookSourceUrl'] ?? src['url'] ?? '').toString().trim();
      if (u.isNotEmpty) return u;
      final n = (src['bookSourceName'] ?? src['name'] ?? '').toString().trim();
      if (n.isNotEmpty) return n;
    }
    return 'default';
  }

  /// 取一个可用 runtime：同源复用 → 空闲回收 → LRU 淘汰 → 新建。
  Future<_PooledRuntime?> _acquire(String sourceKey) async {
    for (final p in _pool) {
      if (p.sourceKey == sourceKey) {
        p.touch();
        return p;
      }
    }
    _evictIdle();
    while (_pool.length >= _maxRuntimes) {
      // 只淘汰**空闲**的 runtime：正在跑的已经 dispose 了会让调用方莫名失败。
      // 两个都在忙时允许临时超限（第三个创建出来，下次空闲时再回收）。
      final evictable = _pool.where((p) => !p.busy).toList();
      if (evictable.isEmpty) break;
      final oldest =
          evictable.reduce((a, b) => a.lastUsed.isBefore(b.lastUsed) ? a : b);
      _pool.remove(oldest);
      oldest.dispose();
      debugPrint('[BookQJS] 淘汰 runtime（${oldest.sourceKey}）');
    }
    final rt = await _createRuntime();
    if (rt == null) return null;
    final pooled = _PooledRuntime(sourceKey, rt);
    _pool.add(pooled);
    debugPrint('[BookQJS] 新建 runtime（源：$sourceKey，池 ${_pool.length}/$_maxRuntimes）');
    return pooled;
  }

  /// 回收长时间没用的 runtime（内存紧张时先释放）
  void _evictIdle() {
    final now = DateTime.now();
    _pool.removeWhere((p) {
      final idle = !p.busy && now.difference(p.lastUsed) > _idleEvict;
      if (idle) p.dispose();
      return idle;
    });
  }

  void _dropRuntime(_PooledRuntime pooled) {
    _pool.remove(pooled);
    pooled.dispose();
  }

  /// 释放所有 runtime（切回 Node 引擎 / 退出时调用）
  void disposeAll() {
    for (final p in _pool) {
      p.dispose();
    }
    _pool.clear();
  }

  Future<JavascriptRuntime?> _createRuntime() async {
    final bundle = _bundle ??= await rootBundle.loadString(_bundleAsset);
    if (bundle.trim().isEmpty) {
      _broken = true;
      return null;
    }
    final runtime = getJavascriptRuntime(
      xhr: false,
      extraArgs: const {
        'timeout': 30000,
        // 池里最多 2 个，单个压到 96MB，避免 iOS 上双 runtime 占太多
        'memoryLimit': 96 * 1024 * 1024,
      },
    );
    runtime.onMessage('book_http', _hostHttp);

    final pre = runtime.evaluate(bookJsPrelude);
    if (pre.isError) {
      debugPrint('[BookQJS] prelude 失败：${pre.stringResult}');
      runtime.dispose();
      _broken = true;
      return null;
    }
    final loaded = runtime.evaluate(bundle);
    if (loaded.isError) {
      debugPrint('[BookQJS] bundle 失败：${loaded.stringResult}');
      runtime.dispose();
      _broken = true;
      return null;
    }
    debugPrint('[BookQJS] 引擎就绪（bundle ${bundle.length} 字符）');
    return runtime;
  }

  Future<Map<String, dynamic>?> _runCall(
    JavascriptRuntime rt,
    String action,
    Map<String, dynamic> payload,
  ) async {
    final started = rt.evaluate(
      '__bookCall(${jsonEncode(action)}, ${jsonEncode(jsonEncode(payload))})',
    );
    if (started.isError) return null;

    final sw = Stopwatch()..start();
    while (true) {
      rt.executePendingJob();
      final state = rt.evaluate('__bookState').stringResult;
      if (state == 'ok') {
        final raw = rt.evaluate('__bookValue').stringResult;
        if (raw.isEmpty || raw == 'undefined' || raw == 'null') return null;
        try {
          final decoded = jsonDecode(raw);
          return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
        } catch (_) {
          return null;
        }
      }
      if (state == 'err') {
        debugPrint('[BookQJS] ${rt.evaluate('__bookError').stringResult}');
        return null;
      }
      if (sw.elapsed > _callTimeout) {
        throw const _QuickJsTimeout();
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<Map<String, dynamic>> _hostHttp(dynamic raw) async {
    final m = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    final url = (m['url'] ?? '').toString();
    if (url.isEmpty) throw StateError('empty url');
    final headers = <String, String>{};
    if (m['headers'] is Map) {
      (m['headers'] as Map).forEach((k, v) => headers[k.toString()] = v.toString());
    }
    final method = (m['method'] ?? 'GET').toString().toUpperCase();
    final body = (m['data'] ?? '').toString();
    final isBytes = (m['responseType'] ?? 'text').toString() == 'arraybuffer';
    final timeoutMs =
        (m['timeoutMs'] is num) ? (m['timeoutMs'] as num).toInt() : 25000;

    final resp = await _dio.request<dynamic>(
      url,
      data: body.isEmpty ? null : body,
      options: Options(
        method: method,
        headers: headers,
        responseType: isBytes ? ResponseType.bytes : ResponseType.plain,
        receiveTimeout: Duration(milliseconds: timeoutMs),
        validateStatus: (_) => true,
      ),
    );

    final data = resp.data;
    final bytes = data is List<int> ? data : null;
    return {
      'status': resp.statusCode ?? 0,
      'headers': {
        for (final e in resp.headers.map.entries) e.key: e.value.join(','),
      },
      'bodyText': bytes == null ? (resp.data?.toString() ?? '') : '',
      'bodyBase64': bytes == null ? '' : base64Encode(bytes),
      'responseType': isBytes ? 'arraybuffer' : 'text',
    };
  }
}

/// 单次调用超时（用于区分「脚本报错」和「脚本卡死」）
class _QuickJsTimeout implements Exception {
  const _QuickJsTimeout();
}

/// 池里的一个 QuickJS 实例：同一个 runtime 的调用必须串行。
class _PooledRuntime {
  _PooledRuntime(this.sourceKey, this.rt);

  final String sourceKey;
  final JavascriptRuntime rt;

  DateTime lastUsed = DateTime.now();
  bool busy = false;
  Future<void> _tail = Future<void>.value();

  void touch() => lastUsed = DateTime.now();

  Future<T> enqueue<T>(Future<T> Function() fn) {
    final completer = Completer<T>();
    busy = true;
    _tail = _tail.then((_) async {
      try {
        completer.complete(await fn());
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        busy = false;
        lastUsed = DateTime.now();
      }
    });
    return completer.future;
  }

  void dispose() {
    try {
      rt.dispose();
    } catch (_) {
      // 已销毁 / 底层异常都忽略
    }
  }
}

