// lib/services/webview_fetch_service.dart
//
// 通用 WKWebView 取页面 / 取 Cookie 通道（2026-10-21 第二批）。
//
// ── 解决什么 ──────────────────────────────────────────────────
//   · SPA 站：列表/详情要等页面 JS 执行完才有内容，纯 HTTP 只能拿到空壳
//   · Cloudflare 等挑战页：需要真浏览器执行 JS，过盾后拿 cf_clearance Cookie
//   · 需要页面内签名/加密的接口：在页面上下文里 eval 一段 JS
//
// ── 和 HikerWebViewService 的关系 ─────────────────────────────
// 海阔那个是「规则驱动的抓页桥」（checkJs 门控 + Node 回调），这里是一个
// **通用入口**：影视嗅探、书源、其它模块都能直接用，不依赖海阔引擎。
//
// ── iOS 限制（必须知道）────────────────────────────────────────
//   · 只能用 WebKit（App 不能自带 Chromium）
//   · Turnstile / CAPTCHA 有些需要用户点一下，隐藏 WebView 过不去
//   · Cookie 与 UA 绑定，拿 Cookie 时必须用同一 UA 去请求

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'app_log.dart';
import 'cf_session.dart';
import '../widgets/video_player_pip.dart';

/// 一次抓页的结果
class WebViewPage {
  const WebViewPage({
    required this.url,
    required this.html,
    required this.title,
    required this.challenged,
    required this.cookies,
  });

  final String url;
  final String html;
  final String title;

  /// 抓完仍像挑战页（5 秒盾 / Turnstile / JS 校验）
  final bool challenged;

  /// 该域下的 Cookie（含 HttpOnly，如 `cf_clearance`）
  final Map<String, String> cookies;
}

class WebViewFetchService {
  WebViewFetchService._();
  static final WebViewFetchService instance = WebViewFetchService._();

  WebViewController? _controller;
  OverlayEntry? _entry;

  /// 本次导航的完成信号（每次抓页新建，理由同 HikerWebViewService）
  Completer<void>? _pending;
  bool _navStarted = false;
  String? _lastError;

  /// 串行闸门：共用一个隐形 WebView，避免并发导航互相打断
  Future<void> _queue = Future<void>.value();

  bool get available => _controller != null;

  /// 页面是不是"挑战/壳页"（CF 5 秒盾、Turnstile、要求开 JS 等）
  static bool looksLikeChallenge(String html) {
    if (html.isEmpty) return false;
    final t = html.toLowerCase();
    const markers = [
      'just a moment',
      'cf-browser-verification',
      'cf_chl_opt',
      'cf-chl',
      'challenge-platform',
      'attention required! | cloudflare',
      'enable javascript and cookies to continue',
      'checking your browser before accessing',
      'ddos protection by',
    ];
    for (final m in markers) {
      if (t.contains(m)) return true;
    }
    return false;
  }

  /// 打开页面并取渲染后的 DOM + Cookie。
  ///
  /// [waitFor] 是**可选的门控 JS 表达式**（如 `document.querySelector('.list')`），
  /// 有值时轮询到它返回真/非空才开始取源码。
  /// 返回 null = WebView 不可用（App 未就绪）或加载失败。
  Future<WebViewPage?> fetchHtml(
    String url, {
    Map<String, String>? headers,
    String? waitFor,
    int timeoutMs = 20000,
    bool acceptChallenged = true,
  }) async {
    final prev = _queue;
    final gate = Completer<void>();
    _queue = gate.future;
    try {
      await prev;
    } catch (_) {/* 上一次失败不影响本次 */}
    try {
      return await _fetch(
        url,
        headers: headers,
        waitFor: waitFor,
        timeoutMs: timeoutMs,
        acceptChallenged: acceptChallenged,
      );
    } catch (e) {
      AppLog.instance.log('[WebViewFetch] 抓页失败 $url: $e');
      return null;
    } finally {
      if (!gate.isCompleted) gate.complete();
    }
  }

  Future<WebViewPage?> _fetch(
    String url, {
    Map<String, String>? headers,
    String? waitFor,
    required int timeoutMs,
    required bool acceptChallenged,
  }) async {
    if (!await _ensureController()) return null;
    final c = _controller!;

    final done = Completer<void>();
    _pending = done;
    _navStarted = false;
    _lastError = null;

    final uri = Uri.parse(url);
    final h = <String, String>{};
    headers?.forEach((k, v) {
      if (k.trim().isEmpty || v.trim().isEmpty) return;
      h[k] = v;
    });

    try {
      if (h.isEmpty) {
        await c.loadRequest(uri);
      } else {
        await c.loadRequest(uri, headers: h);
      }
      try {
        await done.future.timeout(Duration(milliseconds: timeoutMs));
      } on TimeoutException {
        throw TimeoutException('页面加载超时（${timeoutMs}ms）');
      }
      if (_lastError != null) {
        throw Exception('页面加载失败：$_lastError');
      }

      // 页面 load 完 ≠ JS 渲染完
      await Future<void>.delayed(const Duration(milliseconds: 600));

      if (waitFor != null && waitFor.trim().isNotEmpty) {
        final ok = await _waitJs(
          c,
          waitFor,
          Duration(milliseconds: timeoutMs),
        );
        if (!ok) throw TimeoutException('waitFor 在 ${timeoutMs}ms 内没有命中');
      }

      var html = _jsToString(
        await c.runJavaScriptReturningResult(
          'document.documentElement.outerHTML',
        ),
      );
      var challenged = looksLikeChallenge(html);

      // 挑战页：给它一点时间自己过盾（部分非交互式挑战会自动过）
      if (challenged && acceptChallenged) {
        final deadline = DateTime.now().add(
          Duration(milliseconds: (timeoutMs / 2).round()),
        );
        while (DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 700));
          html = _jsToString(
            await c.runJavaScriptReturningResult(
              'document.documentElement.outerHTML',
            ),
          );
          challenged = looksLikeChallenge(html);
          if (!challenged) break;
        }
      }

      final title = _jsToString(
        await c.runJavaScriptReturningResult('document.title'),
      );
      return WebViewPage(
        url: url,
        html: html,
        title: title,
        challenged: challenged,
        cookies: await cookiesFor(url),
      );
    } finally {
      if (identical(_pending, done)) _pending = null;
    }
  }

  /// 取某域名下的 Cookie（含 HttpOnly）。
  Future<Map<String, String>> cookiesFor(String url) async {
    final out = <String, String>{};
    final uri = Uri.tryParse(url);
    if (uri == null) return out;
    try {
      final list = await WebViewCookieManager().getCookies(domain: uri);
      for (final c in list) {
        out[c.name] = c.value;
      }
    } catch (e) {
      AppLog.instance.log('[WebViewFetch] 取 Cookie 失败: $e');
    }
    return out;
  }

  /// 拼成 `Cookie:` 请求头的值（空 → 空串）
  ///
  /// 优先读 [CfSession] 的持久缓存：用户验证过一次的站直接返回，
  /// **不再启动一次 WebView**（原来每次都现取，慢且会重复触发挑战页）。
  Future<String> cookieHeaderFor(String url) async {
    final host = CfSession.hostOf(url);
    if (host.isNotEmpty) {
      final cached = await CfSession.instance.cookieHeader(host);
      if (cached.isNotEmpty) return cached;
    }
    final m = await cookiesFor(url);
    return m.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// 在当前页面上下文里执行一段 JS（页面没加载过时返回 null）
  Future<String?> evalJs(String js) async {
    final c = _controller;
    if (c == null) return null;
    try {
      return _jsToString(await c.runJavaScriptReturningResult(js));
    } catch (e) {
      AppLog.instance.log('[WebViewFetch] evalJs 失败: $e');
      return null;
    }
  }

  Future<void> clearCookies() async {
    try {
      await WebViewCookieManager().clearCookies();
    } catch (_) {}
  }

  Future<bool> _waitJs(
    WebViewController c,
    String expr,
    Duration timeout,
  ) async {
    final wrapped = '(() => { const __v = ($expr); '
        'return typeof __v === "function" ? __v() : __v; })()';
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final r = await c.runJavaScriptReturningResult(wrapped);
        if (_truthy(r)) return true;
      } catch (_) {
        // 目标还没出现时求值可能抛错，继续等
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  bool _truthy(Object? r) {
    if (r == null) return false;
    if (r is bool) return r;
    if (r is num) return r != 0;
    final s = _jsToString(r).trim();
    return s.isNotEmpty && s != 'null' && s != 'undefined' && s != 'false';
  }

  String _jsToString(Object? r) {
    if (r == null) return '';
    final s = r.toString();
    if (s == 'null' || s == 'undefined') return '';
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      try {
        return (jsonDecode(s) as Object).toString();
      } catch (_) {}
    }
    return s;
  }

  // ============================================================
  // 隐形 WebView 的创建
  // ============================================================

  Future<bool> _ensureController() async {
    if (_controller != null) return true;
    final overlay = VideoPlayerPip.navigatorKey.currentState?.overlay;
    if (overlay == null) return false;

    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          _navStarted = true;
        },
        onPageFinished: (_) {
          if (!_navStarted) return;
          final p = _pending;
          if (p != null && !p.isCompleted) p.complete();
        },
        onWebResourceError: (e) {
          if (e.isForMainFrame == true) {
            _lastError = '${e.errorCode} ${e.description}';
            final p = _pending;
            if (p != null && !p.isCompleted) p.complete();
          }
        },
      ));
    _controller = c;

    // 1×1 隐形但**真的渲染**（Offstage 不挂平台视图，JS 不会执行）
    final entry = OverlayEntry(
      builder: (_) => Positioned(
        left: 0,
        top: 0,
        width: 1,
        height: 1,
        child: IgnorePointer(child: WebViewWidget(controller: c)),
      ),
    );
    _entry = entry;
    overlay.insert(entry);
    return true;
  }

  void dispose() {
    try {
      _entry?.remove();
    } catch (_) {}
    _entry = null;
    _controller = null;
    final p = _pending;
    if (p != null && !p.isCompleted) p.complete();
    _pending = null;
  }
}
