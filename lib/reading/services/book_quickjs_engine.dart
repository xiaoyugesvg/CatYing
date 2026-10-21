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

import '../quickjs/book_js_prelude.dart';

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

  JavascriptRuntime? _runtime;
  String? _bundle;
  Future<void>? _initFuture;
  Future<void> _tail = Future<void>.value();
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
    try {
      final runtime = await _ensureRuntime();
      if (runtime == null) return null;
      return await _serial(() => _runCall(runtime, action, payload));
    } catch (e) {
      debugPrint('[BookQJS] 调用失败：$e');
      return null;
    }
  }

  Future<JavascriptRuntime?> _ensureRuntime() async {
    if (_runtime != null) return _runtime;
    final bundle = _bundle ??= await rootBundle.loadString(_bundleAsset);
    if (bundle.trim().isEmpty) {
      _broken = true;
      return null;
    }
    final runtime = getJavascriptRuntime(
      xhr: false,
      extraArgs: const {
        'timeout': 30000,
        'memoryLimit': 128 * 1024 * 1024,
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
    _runtime = runtime;
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
        debugPrint('[BookQJS] 超时（$action）');
        return null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// QuickJS 单线程：并发调用会串状态，必须排队。
  Future<T> _serial<T>(Future<T> Function() fn) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await fn());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
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
