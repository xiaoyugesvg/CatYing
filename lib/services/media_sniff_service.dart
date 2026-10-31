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
// ── 四层采集（2026-10-31 按实测补齐）────────────────────────────
//   ① 网络层：XHR / fetch / media.src / performance；
//   ② 变量层：播放器对象里的 url（`config.url` / `art.option.url` …）；
//   ③ console 层：脚本解密完自己打印的地址；
//   ④ iframe 层：壳页嵌播放器时，读 iframe 的 src 当**下一层**去跟。
//
// 为什么必须有 ②③④：用户实测 `jx.muiu.site` 那条链，播放器把解密后的
// 地址存进 JS 变量，交给 hls.js 之前就报 `Unsupported playback format:
// m3u8` —— **一个网络请求都没发**。只钩网络一条都抓不到；真正暴露地址的
// 是它自己那句 `console.log('解密原始链接：', url)`。
// 而地址又在 **cross-origin iframe** 里，主 frame 读不到它的变量，
// 只能读到 iframe 的 src —— 所以顺着 src 一层层当顶层页重新加载。
// 这条路绕开了「注入所有 frame」（`webview_flutter` 没暴露这个能力，
// 只能改原生）。
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

/// 一次嗅探的完整结果（探针页要展示"抓到了什么"，所以不能只回首选）
class SniffResult {
  const SniffResult({
    this.best,
    this.candidates = const [],
    this.frames = const [],
    this.logs = const [],
  });

  /// 首选媒体地址（null = 没嗅到）
  final String? best;

  /// 所有候选（按分数降序）
  final List<SniffCandidate> candidates;

  /// 跟过的 iframe 地址（按发现顺序）
  final List<String> frames;

  /// 原始事件日志（新的在前）
  final List<String> logs;

  bool get ok => best != null && best!.isNotEmpty;
}

class MediaSniffService {
  MediaSniffService._();
  static final MediaSniffService instance = MediaSniffService._();

  /// 默认嗅探预算。比探针页（24s）短 —— 正式链路里用户已经等了一段
  /// HTTP 解析，再让他干等太久不合适。
  static const Duration defaultBudget = Duration(seconds: 12);

  /// 预热：页面 onPageFinished 后再等这么久才开始采信结果。
  ///
  /// 太短会抓到前贴片广告的 mp4（很多站点首屏就是广告播放器）；
  /// 太长又白等。1.5s 是「主播放器通常已经起来」的量级。
  static const Duration _warmup = Duration(milliseconds: 1500);

  /// 最多顺几层 iframe。
  ///
  /// 实测那条链是：`jx.muiu.site` → `ckplayer.vip/jiexi` → `jx.php` →
  /// `789jiexi.net/jiexi.php`（这一层才出地址）。3 层够覆盖常见壳站，
  /// 再多基本是广告跳转了。
  static const int _maxHops = 3;

  /// 每一层最少给的时间（不然刚加载完就换层，等于白跳）
  static const Duration _minHop = Duration(seconds: 3);

  /// 每一层最多等这么久。
  ///
  /// **不再按剩余层数平摊** —— 早期版本是 `剩余 ÷ 剩余层数`（20s ÷ 3 ≈ 6.6s），
  /// 实测把 `ckplayer.vip/jiexi` 砍在 6.7s，而它要 **8.5s** 才把地址打印出来，
  /// 差 1.8 秒整条链就废了。层数是我们自己假想的上限，真实链子常常只有 2 层，
  /// 平摊等于把预算浪费在根本不存在的层上。
  static const Duration _hopCap = Duration(seconds: 10);

  WebViewController? _controller;
  OverlayEntry? _entry;

  /// 每次嗅探换一个新的收集器，避免上一集的地址污染这一集
  SnifferCollector? _collector;

  /// 外部要求中止（探针页的「停止」）。
  ///
  /// 只置一个标志位，循环下一轮就跳出去 —— 不用 Future 取消那一套：
  /// 真正要停的是 WebView 里的页面，靠收工时导航到 `about:blank`。
  bool _cancelRequested = false;

  /// 串行闸门：共用一个隐形 WebView，并发导航会互相打断
  Future<void> _queue = Future<void>.value();

  bool get available => _controller != null;

  /// 要求中止当前（或排队中的）嗅探。已经抓到的结果仍会正常返回。
  void cancel() => _cancelRequested = true;

  /// 嗅探并返回**首选媒体地址**（没有则 null）。
  Future<String?> sniff(
    String pageUrl, {
    Map<String, String> headers = const {},
    Duration budget = defaultBudget,
    void Function(String message)? onProgress,
  }) async {
    final r = await sniffDetailed(
      pageUrl,
      headers: headers,
      budget: budget,
      onProgress: onProgress,
    );
    return r.best;
  }

  /// 嗅探并返回**完整结果**（探针页用：要展示候选列表和跟过的 iframe）
  Future<SniffResult> sniffDetailed(
    String pageUrl, {
    Map<String, String> headers = const {},
    Duration budget = defaultBudget,
    void Function(String message)? onProgress,
  }) {
    final url = pageUrl.trim();
    if (!url.startsWith('http')) return Future.value(const SniffResult());
    // 每次新的一轮都把中止位清掉（上一轮点过「停止」不该影响这一轮）
    _cancelRequested = false;

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
        return const SniffResult();
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    }();
  }

  Future<SniffResult> _run(
    String url, {
    required Map<String, String> headers,
    required Duration budget,
    void Function(String message)? onProgress,
  }) async {
    if (!await _ensureController()) {
      AppLog.instance.log('[Sniff] 隐形 WebView 不可用（App 未就绪），跳过嗅探');
      return const SniffResult();
    }
    final c = _controller!;
    final collector = SnifferCollector();
    _collector = collector;

    final deadline = DateTime.now().add(budget);
    final visited = <String>{};
    var target = url;
    String? best;

    try {
      for (var hop = 0; hop < _maxHops; hop++) {
        if (target.isEmpty || DateTime.now().isAfter(deadline)) break;
        if (_cancelRequested) break;
        visited.add(target);
        onProgress?.call(
          hop == 0
              ? '正在嗅探页面里的播放地址…'
              : '顺着 iframe 再探一层（第 ${hop + 1} 层）…',
        );
        AppLog.instance.log('[Sniff] 第 ${hop + 1} 层: $target');

        if (!await _load(c, target, headers)) break;

        final hopDeadline = _hopDeadline(deadline);
        final hopStarted = DateTime.now();
        var warm = false;
        final warmTimer = Timer(_warmup, () => warm = true);
        try {
          while (DateTime.now().isBefore(hopDeadline)) {
            if (_cancelRequested) break;
            await _inject(c);
            final b = collector.best;
            if (warm && b != null && b.isMedia) {
              best = b.url;
              break;
            }
            // 本层已经暴露出可跟的 iframe，自己却一条候选都没有
            // → 别把 [_hopCap] 白等完，省下的时间留给下一层。
            // 实测 `jx.muiu.site` 就是这种壳页：地址在 iframe 里，主 frame 永远等不到。
            if (DateTime.now().difference(hopStarted) >= _minHop &&
                collector.count == 0 &&
                collector.nextFrame(visited) != null) {
              AppLog.instance.log('[Sniff] 本层无候选但露出 iframe，提前跟下一层');
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 300));
          }
        } finally {
          warmTimer.cancel();
        }
        if (best != null) break;

        // 这一层没有媒体地址 → 顺着 iframe 再下一层
        final next = collector.nextFrame(visited);
        if (next == null) break;
        AppLog.instance.log('[Sniff] 跟到下一层: $next');
        target = next;
      }
    } finally {
      _collector = null;
      // 收工必须把页面停掉：否则隐形 WebView 里的播放器还在拉流 / 占音频
      unawaited(_quiet(c));
    }

    // 兜底：循环结束时可能刚好抓到一条（还没到 warm 也算）
    if (best == null) {
      final b = collector.best;
      if (b != null && b.isMedia) best = b.url;
    }

    if (best != null) {
      AppLog.instance.log('[Sniff] 命中: $best');
    } else {
      AppLog.instance.log(
        '[Sniff] 未嗅到媒体地址（候选 ${collector.count} 条，'
        '跟过 ${collector.frames.length} 个 iframe）: $url',
      );
    }
    return SniffResult(
      best: best,
      candidates: collector.sorted,
      frames: collector.frames,
      logs: collector.logs,
    );
  }

  /// 每一层的时间片：最多 [_hopCap]，且不超过剩余预算
  DateTime _hopDeadline(DateTime deadline) {
    final left = deadline.difference(DateTime.now());
    if (left <= Duration.zero) return DateTime.now();
    return DateTime.now().add(_hopCap < left ? _hopCap : left);
  }

  Future<bool> _load(
    WebViewController c,
    String url,
    Map<String, String> headers,
  ) async {
    final h = <String, String>{
      for (final e in headers.entries)
        if (e.key.trim().isNotEmpty && e.value.trim().isNotEmpty)
          e.key: e.value,
    };
    try {
      if (h.isEmpty) {
        await c.loadRequest(Uri.parse(url));
      } else {
        await c.loadRequest(Uri.parse(url), headers: h);
      }
      return true;
    } catch (e) {
      AppLog.instance.log('[Sniff] 加载失败 $url: $e');
      return false;
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
