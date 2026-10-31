// lib/services/media_sniff_service.dart
//
// 后台（隐形）WebView 嗅探 —— 把「页面里 JS 拼出来的媒体地址」抓出来。
//
// ── 和已有两个东西的分工 ──────────────────────────────────────
//   · `MediaResolver`：纯 HTTP，抓 HTML / 打解析接口。**快**，但拿不到
//     SPA 页面里 JS 生成的地址；
//   · `SnifferProbePage`（dev）：手动测试页，用户点一下才跑；
//   · **本文件**：把探针页那套搬进正式链路，由 `MediaResolver` 兜底调用。
//     页面真的加载、播放器真的跑起来，才抓得到地址。
//
// ── 三条硬约束（沿用用户 2026-10-29 的原始要求）─────────────────
//   1. **不打断播放器**：1×1 透明、IgnorePointer、挂在 root Overlay 上，
//      不弹页面、不抢焦点；
//   2. **不出声**：注入 `kSilenceMediaJs` 强制静音（嗅探必须让播放器跑起来，
//      否则没有网络请求；但绝不能让用户听到陌生页面的声音）；
//   3. **到点就收**：拿到首选地址立刻返回，不傻等满预算；收工后把页面
//      导航到 `about:blank`，把还在跑的播放器彻底停掉。
//
// ⚠️ iOS 限制：WebKit 只允许一个「真的渲染」的 WebView 跑 JS，`Offstage`
//    不挂平台视图 ⇒ JS 不执行。所以这里和 `WebViewFetchService` 一样，
//    必须用 Overlay + 1×1 真实尺寸（不能用 0 尺寸，也不能用 Offstage）。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/sniffer_hook_js.dart';
import 'package:tvbox/services/webview_sniffer.dart';
import 'package:tvbox/widgets/video_player_pip.dart';

class MediaSniffService {
  MediaSniffService._();
  static final MediaSniffService instance = MediaSniffService._();

  /// 默认嗅探预算。比探针页（20s）短 —— 正式链路里用户已经等了一段
  /// HTTP 解析，再让他干等 20s 不合适。
  static const Duration defaultBudget = Duration(seconds: 10);

  /// 预热：页面 onPageFinished 后再等这么久才开始采信结果。
  ///
  /// 太短会抓到前贴片广告的 mp4（很多站点首屏就是广告播放器）；
  /// 太长又白等。1.5s 是「主播放器通常已经起来」的量级。
  static const Duration _warmup = Duration(milliseconds: 1500);

  WebViewController? _controller;
  OverlayEntry? _entry;

  /// 每次嗅探换一个新的收集器，避免上一集的地址污染这一集
  SnifferCollector? _collector;

  /// 串行闸门：共用一个隐形 WebView，并发导航会互相打断
  Future<void> _queue = Future<void>.value();

  bool get available => _controller != null;

  /// 嗅探 [pageUrl]，返回**首选媒体地址**（没有则 null）。
  ///
  /// 只返回带已知媒体后缀的地址（`MediaSniffer.isMediaUrl`）—— 把网页
  /// 丢给播放器只会白卡，不如老实返回 null 让上层换线路。
  Future<String?> sniff(
    String pageUrl, {
    Map<String, String> headers = const {},
    Duration budget = defaultBudget,
    void Function(String message)? onProgress,
  }) {
    final url = pageUrl.trim();
    if (!url.startsWith('http')) return Future.value(null);

    final prev = _queue;
    final gate = Completer<void>();
    _queue = gate.future;
    return () async {
      try {
        await prev;
      } catch (_) {
        // 上一次失败不影响本次
      }
      try {
        return await _run(
          url,
          headers: headers,
          budget: budget,
          onProgress: onProgress,
        );
      } catch (e) {
        AppLog.instance.w('[Sniff] 嗅探异常 $url: $e');
        return null;
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    }();
  }

  Future<String?> _run(
    String url, {
    required Map<String, String> headers,
    required Duration budget,
    void Function(String message)? onProgress,
  }) async {
    if (!await _ensureController()) {
      AppLog.instance.log('[Sniff] 隐形 WebView 不可用（App 未就绪），跳过嗅探');
      return null;
    }
    final c = _controller!;
    final collector = SnifferCollector();
    _collector = collector;

    onProgress?.call('正在嗅探页面里的播放地址…');

    final h = <String, String>{
      for (final e in headers.entries)
        if (e.key.trim().isNotEmpty && e.value.trim().isNotEmpty)
          e.key: e.value,
    };

    var warm = false;
    final warmTimer = Timer(_warmup, () => warm = true);
    final deadline = DateTime.now().add(budget);

    try {
      try {
        if (h.isEmpty) {
          await c.loadRequest(Uri.parse(url));
        } else {
          await c.loadRequest(Uri.parse(url), headers: h);
        }
      } catch (e) {
        AppLog.instance.log('[Sniff] 加载失败 $url: $e');
        return null;
      }

      // 轮询：持续注入（早期请求也不放过），拿到首选就立刻收工
      while (DateTime.now().isBefore(deadline)) {
        await _inject(c);
        final best = collector.best;
        if (warm && best != null && best.isMedia) {
          AppLog.instance.log('[Sniff] 命中（${best.kind} / ${best.via}）: ${best.url}');
          return best.url;
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }

      // 到点：有媒体候选就交出去，否则算失败
      final best = collector.best;
      if (best != null && best.isMedia) {
        AppLog.instance.log('[Sniff] 到点取次优（${best.kind}）: ${best.url}');
        return best.url;
      }
      AppLog.instance
          .log('[Sniff] 未嗅到媒体地址（共 ${collector.count} 条候选）: $url');
      return null;
    } finally {
      warmTimer.cancel();
      _collector = null;
      // 收工必须把页面停掉：否则隐形 WebView 里的播放器还在拉流 / 占音频
      unawaited(_quiet(c));
    }
  }

  /// 收工：导航到空白页，彻底停掉页面里还在跑的播放器
  Future<void> _quiet(WebViewController c) async {
    try {
      await c.loadRequest(Uri.parse('about:blank'));
    } catch (_) {}
  }

  Future<void> _inject(WebViewController c) async {
    try {
      await c.runJavaScript(kSnifferHookJs);
      await c.runJavaScript(kSilenceMediaJs);
    } catch (_) {
      // 页面还没就绪时求值会抛错，下一轮再试
    }
  }

  void _onMessage(String raw) {
    final collector = _collector;
    if (collector == null) return;
    try {
      final m = jsonDecode(raw);
      if (m is Map) {
        collector.add(
          (m['url'] ?? '').toString(),
          kind: (m['kind'] ?? '').toString(),
          via: (m['via'] ?? '').toString(),
        );
      }
    } catch (_) {}
  }

  // ============================================================
  // 隐形 WebView 的创建
  // ============================================================

  Future<bool> _ensureController() async {
    if (_controller != null) return true;
    final overlay = VideoPlayerPip.navigatorKey.currentState?.overlay;
    if (overlay == null) return false;

    final c = WebViewController();
    _controller = c;
    c
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setUserAgent(kChromeMobileUA)
      ..addJavaScriptChannel('CatSniff', onMessageReceived: (m) {
        _onMessage(m.message);
      })
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          unawaited(_inject(c));
        },
        onPageFinished: (_) {
          unawaited(_inject(c));
        },
      ));

    // 1×1 透明但**真的渲染**（Offstage / 0 尺寸都不挂平台视图，JS 不跑）
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
    AppLog.instance.log('[Sniff] 隐形 WebView 已挂载（1×1 Overlay）');
    return true;
  }

  /// 释放隐形 WebView（App 退出 / 长时间不用时调用）
  void dispose() {
    try {
      _entry?.remove();
    } catch (_) {}
    _entry = null;
    _controller = null;
    _collector = null;
  }
}
