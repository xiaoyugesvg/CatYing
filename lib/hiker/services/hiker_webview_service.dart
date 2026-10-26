import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/nodejs_manager.dart';
import 'package:tvbox/widgets/video_player_pip.dart';

/// 海阔的 **WebView 抓页桥**（Phase 2）。
///
/// ── 为什么需要它 ────────────────────────────────────────────────
/// 海阔规则里的 `fetchCodeByWebView(url, {checkJs})` / `$('').lazyRule(fn)`
/// 要开一个**真 WebView** 打开页面、等页面 JS 跑完，再把 DOM（或 `checkJs`
/// 的返回值）交回给规则。Node 侧没有 WebView，所以：
///   Node 抛 `NeedWebView` → 回环 HTTP `POST /hiker/webview` → **本服务** →
///   返回 HTML → Node 拿结果重放规则（见 hiker_engine.js 顶部说明）。
///
/// ── 为什么不影响其它模块 ────────────────────────────────────────
/// 只在「海阔」要用时才注册 `NodeJSManager.webViewFetcher` 这个**可空钩子**，
/// 并懒创建**一个 1×1 的隐形 WebView**（挂在 root Overlay 上）。
/// 海阔不用它，这里一个对象都不会建，其它模块完全无感。
class HikerWebViewService {
  HikerWebViewService._();
  static final HikerWebViewService instance = HikerWebViewService._();

  /// 注册到 Node 回环服务器的钩子（幂等；首次调用海阔引擎时执行）
  static void register() {
    NodeJSManager.webViewFetcher = (url, req) => instance._handle(url, req);
  }

  OverlayEntry? _entry;
  WebViewController? _controller;

  /// 当前这次导航要等的"加载完成"信号（**每次抓页新建一个**）。
  ///
  /// ⚠️ 不要把它做成"在 onPageStarted 里重建"的共享字段：`loadRequest` 返回与
  ///   `onPageStarted` 触发的先后顺序不固定，共享字段会在"先重建、后 await"的
  ///   情况下让我们**等一个没人会完成的 Completer** ⇒ 每次抓页都白等到超时。
  Completer<void>? _pending;

  /// 本次导航是否已开始 —— 用来**丢弃上一次导航迟到的 onPageFinished**。
  /// （队列虽然是串行的，但上一次页面的 finished 事件可能在我们 loadRequest
  ///  之后才到，共享的完成信号会被它提前触发，读到的是旧页面/半成品 DOM）
  bool _navStarted = false;

  String? _lastError;

  /// 串行闸门：同一时刻只跑一个抓页任务（共用一个 WebView，避免互相导航）
  Future<void> _queue = Future<void>.value();

  bool get ready => _controller != null;

  // ============================================================
  // 抓页
  // ============================================================

  Future<Map<String, dynamic>> _handle(String url, Map<String, dynamic> req) async {
    // 排队（前一个任务跑完再开始）
    final prev = _queue;
    final gate = Completer<void>();
    _queue = gate.future;
    try {
      await prev;
    } catch (_) {/* 前一个失败不影响本次 */}
    try {
      final timeoutMs = (req['timeoutMs'] as num?)?.toInt() ?? 15000;
      final checkJs = (req['checkJs'] ?? '').toString();
      final headers = <String, String>{};
      final h = req['headers'];
      if (h is Map) {
        h.forEach((k, v) => headers[k.toString()] = v.toString());
      }
      AppLog.instance.log('[Hiker] WebView 抓页: $url'
          '${checkJs.isEmpty ? '' : '（含 checkJs）'}');
      final html = await _fetch(
        url: url,
        timeoutMs: timeoutMs,
        checkJs: checkJs,
        headers: headers,
      );
      return {'ok': true, 'html': html};
    } catch (e) {
      AppLog.instance.log('[Hiker] WebView 抓页失败: $e');
      return {'ok': false, 'error': '$e'};
    } finally {
      if (!gate.isCompleted) gate.complete();
    }
  }

  Future<String> _fetch({
    required String url,
    required int timeoutMs,
    required String checkJs,
    required Map<String, String> headers,
  }) async {
    await _ensureController();
    final c = _controller!;

    // 每次抓页新建信号 + 复位"导航已开始"标记（见字段说明）
    final done = Completer<void>();
    _pending = done;
    _navStarted = false;
    _lastError = null;

    final uri = Uri.parse(url);
    try {
      if (headers.isEmpty) {
        await c.loadRequest(uri);
      } else {
        await c.loadRequest(uri, headers: headers);
      }

      try {
        await done.future.timeout(Duration(milliseconds: timeoutMs));
      } on TimeoutException {
        throw TimeoutException('WebView 等待页面加载超时（${timeoutMs}ms）');
      }
      if (_lastError != null) {
        throw Exception('页面加载失败：$_lastError');
      }

      // 页面加载完 ≠ JS 渲染完（很多站点是异步填 DOM），给一点缓冲
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // ── checkJs 是**门控**，不是取值 ────────────────────────────────
      // 官方文档原话：「只有 checkJs 执行返回内容不为 null 软件才会获取源码返回」
      // ⇒ 轮询它，等它有值了再抓 outerHTML；**返回值是整页源码**。
      //（我原先直接把 checkJs 的结果当源码返回 —— 与文档不符，已修正）
      if (checkJs.trim().isNotEmpty) {
        // checkJs 是函数源码（规则里用 `$.toString(()=>…)` 转的），也可能是表达式
        final expr = '(() => { const __v = ($checkJs); '
            'return typeof __v === "function" ? __v() : __v; })()';
        final deadline = DateTime.now().add(Duration(milliseconds: timeoutMs));
        var hit = false;
        while (DateTime.now().isBefore(deadline)) {
          try {
            if (_hasValue(await c.runJavaScriptReturningResult(expr))) {
              hit = true;
              break;
            }
          } catch (_) {
            // 目标元素还没出现时求值可能抛错 —— 继续等
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        if (!hit) {
          throw TimeoutException('checkJs 在 ${timeoutMs}ms 内始终没返回内容');
        }
      }

      final r = await c.runJavaScriptReturningResult('document.documentElement.outerHTML');
      return _jsToString(r);
    } finally {
      // 清掉本次信号：之后迟到的 onPageFinished 不会再完成一个陈旧的 Completer
      if (identical(_pending, done)) _pending = null;
    }
  }

  /// `runJavaScriptReturningResult` 给的是 **JSON 文本**（字符串带引号），
  /// 这里还原成普通字符串。
  String _jsToString(Object? r) {
    if (r == null) return '';
    final s = r.toString();
    if (s == 'null' || s == 'undefined') return '';
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      try {
        return (jsonDecode(s) as Object).toString();
      } catch (_) {/* 非标准 JSON，按原文返回 */}
    }
    return s;
  }

  /// checkJs 的"有值"判定（文档：返回内容不为 null 才算命中）
  bool _hasValue(Object? r) {
    if (r == null) return false;
    if (r is bool) return r; // 常见写法 `!!document.querySelector('#main a')`
    if (r is num) return true;
    return _jsToString(r).trim().isNotEmpty;
  }

  // ============================================================
  // 隐形 WebView 的创建与挂载
  // ============================================================

  Future<void> _ensureController() async {
    if (_controller != null) return;
    final overlay = VideoPlayerPip.navigatorKey.currentState?.overlay;
    if (overlay == null) {
      throw StateError('App 还没就绪（拿不到 Overlay），无法创建抓页 WebView');
    }
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          // 只置位，**不重建**完成信号（重建会让正在 await 的那次等不到）
          _navStarted = true;
        },
        onPageFinished: (_) {
          // 丢弃上一次导航迟到的 finished（那会让我们读到旧页面/半成品 DOM）
          if (!_navStarted) return;
          final p = _pending;
          if (p != null && !p.isCompleted) p.complete();
        },
        onWebResourceError: (e) {
          // 只有**主文档**失败才算失败（子资源失败很常见，不该拖垮整次抓取）
          if (e.isForMainFrame == true) {
            _lastError = '${e.errorCode} ${e.description}';
            final p = _pending;
            if (p != null && !p.isCompleted) p.complete();
          }
        },
      ));
    _controller = c;

    // 1×1、忽略触摸、贴在左上角 —— 这是"不可见但要真的渲染 JS"的常用做法。
    // ⚠️ 不能用 Offstage/Visibility(gone)：那样平台视图不会被挂载，JS 根本不跑。
    final entry = OverlayEntry(
      builder: (_) => Positioned(
        left: 0,
        top: 0,
        width: 1,
        height: 1,
        child: IgnorePointer(
          child: WebViewWidget(controller: c),
        ),
      ),
    );
    _entry = entry;
    overlay.insert(entry);
  }

  /// 释放（可选：给"设置 → 清空"之类的入口用；不调也没关系，就 1×1 而已）
  void dispose() {
    try {
      _entry?.remove();
    } catch (_) {}
    _entry = null;
    _controller = null;
    // 别让正在等加载的那次白等到超时
    final p = _pending;
    if (p != null && !p.isCompleted) p.complete();
    _pending = null;
  }
}
