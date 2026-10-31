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
/// 一层 iframe 的跟帧结果 —— 失败时用来回答「到底卡在哪一层」。
///
/// 为什么需要：嗅探失败原来只有一句「候选 0 条，跟过 2 个 iframe」，
/// 看不出是**加载失败**、**被 302 带走**、还是**页面里压根没有 iframe**。
/// 实测 `jx.muiu.site` 那条链时，只能靠 curl 一层层手打才定位到
/// 「`jx.php` 不带 Referer 会 302 回 `jiexi/`」—— 页面自己给不出任何线索。
class SniffHop {
  const SniffHop({
    required this.index,
    required this.url,
    required this.elapsed,
    required this.candidateCount,
    required this.frameCount,
    this.landedUrl,
    this.note = '',
  });

  /// 第几层（从 1 开始）
  final int index;

  /// 这一层请求的地址
  final String url;

  /// 这一层实际停留的地址（和 [url] 不同 ⇒ 被跳转了）
  final String? landedUrl;

  /// 这一层等了多久
  final Duration elapsed;

  /// 这一层结束时累计的候选数
  final int candidateCount;

  /// 这一层结束时累计的 iframe 数
  final int frameCount;

  /// 一句话结论（加载失败 / 提前跟下一层 / 等满时间片 / 跳转到…）
  final String note;

  /// 是否发生了跳转（302 / JS 重定向）
  bool get redirected {
    final l = landedUrl;
    if (l == null || l.isEmpty) return false;
    return !_sameTarget(l, url);
  }
}

/// 两个 URL 是不是「同一个页面」（忽略 query 里的随机参数）
bool _sameTarget(String a, String b) {
  try {
    final ua = Uri.parse(a);
    final ub = Uri.parse(b);
    return ua.host == ub.host && ua.path == ub.path;
  } catch (_) {
    return a == b;
  }
}

class SniffResult {
  const SniffResult({
    this.best,
    this.candidates = const [],
    this.frames = const [],
    this.logs = const [],
    this.hops = const [],
  });

  /// 首选媒体地址（null = 没嗅到）
  final String? best;

  /// 所有候选（按分数降序）
  final List<SniffCandidate> candidates;

  /// 跟过的 iframe 地址（按发现顺序）
  final List<String> frames;

  /// 原始事件日志（新的在前）
  final List<String> logs;

  /// 每一层的跟帧结果（按顺序）—— 失败定位用
  final List<SniffHop> hops;

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
  /// 4 层是实测出来的：`jx.muiu.site` → `ckplayer.vip/jiexi/` →
  /// `ckplayer.vip/jx.php` → `api-api.789jiexi.net`（真正出地址的那层）。
  /// 原来 3 层够不到最后一跳，日志里表现为「跟过 2 个 iframe 就放弃」。
  ///
  /// 2026-10-31 提到 6：用户给的 `bd.jx.cn` 那条链**正好**是 4 层
  /// （`bd.jx.cn` → `jiexi.bot.cd/` → `jiexi.bot.cd/jx/` → `123.129.229.14:4433`），
  /// 卡在上限边界上 —— 中间只要多一个中转页就整条废掉。多给两层不花时间：
  /// 链子短的时候循环会因为「没有可跟的 iframe」立刻退出，不存在白等。
  static const int _maxHops = 6;

  /// 每一层最少给的时间（不然刚加载完就换层，等于白跳）
  static const Duration _minHop = Duration(seconds: 3);

  /// 每一层最多等这么久。
  ///
  /// **不再按剩余层数平摊** —— 早期版本是 `剩余 ÷ 剩余层数`（20s ÷ 3 ≈ 6.6s），
  /// 实测把 `ckplayer.vip/jiexi` 砍在 6.7s，而它要 **8.5s** 才把地址打印出来，
  /// 差 1.8 秒整条链就废了。层数是我们自己假想的上限，真实链子常常只有 2 层，
  /// 平摊等于把预算浪费在根本不存在的层上。
  static const Duration _hopCap = Duration(seconds: 10);

  /// 确认是**最后一层**时，时间片放宽到这里。
  ///
  /// 怎么判断"最后一层"：本层已经没有可跟的 iframe，却还一条候选都没有 ——
  /// 说明地址只能从这一页里出来，再没有下一层可以兜底了，此时把时间给足。
  ///
  /// 为什么 10s 不够（2026-10-31 实测 `bd.jx.cn` 那条链的最后一层
  /// `https://123.129.229.14:4433`）：
  ///   · 页面要跑 `global.min.js` + 394KB 混淆过的 `khd_play.js`；
  ///   · 播放器是 Artplayer，地址放在实例上（`window.stray.ad.url`），
  ///     必须等它 `new` 出来才有；
  ///   · 前面的中转层还要先跑一个 437KB base64 内嵌的 Go WASM 才能拼出这一层的地址。
  /// 这类页面 10s 经常差一口气，放宽到 16s 才稳。
  static const Duration _lastHopCap = Duration(seconds: 16);

  WebViewController? _controller;

  /// 最近一次**主文档**加载失败的原因（`onWebResourceError` / `onHttpError` 写入）。
  ///
  /// 每层开始前清空。用它把"静默失败"变成分层诊断里的一行字 ——
  /// 没有它的时候，某一层加载失败看起来和"页面没地址"一模一样。
  String _lastMainFrameError = '';
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
    final hops = <SniffHop>[];
    var target = url;
    String? best;

    /// 记一层的结果（各个 break 点共用）。
    ///
    /// 顺手读一次 `currentUrl()` —— 这是**最有价值的一条诊断**：
    /// `jx.php` 不带 Referer 时会 302 回 `jiexi/`，落地地址和请求地址不一样。
    /// 以前这条线索完全看不到，只能靠 curl 手打才发现。
    ///
    /// [prevUrl] 是**上一层**请求的地址。落地地址等于它 ⇒ 说明这一层压根
    /// 没导航过去（TLS 失败 / 被拦 / 超时），而不是"被跳转"。
    /// 2026-10-31 实测 `bd.jx.cn` 第 4 层：日志写成「被跳转到
    /// jiexi.bot.cd/jx/」，看的人（包括我）都以为是重定向，其实是没加载起来。
    Future<void> recordHop({
      required int index,
      required String url,
      required Duration elapsed,
      required String note,
      String? prevUrl,
    }) async {
      String? landed;
      try {
        landed = await c.currentUrl();
      } catch (_) {}
      var n = note;
      if (landed != null && landed.isNotEmpty && !_sameTarget(landed, url)) {
        if (prevUrl != null && _sameTarget(landed, prevUrl)) {
          final why =
              _lastMainFrameError.isEmpty ? '' : '：$_lastMainFrameError';
          n = '这一层没加载起来，还停在上一层$why（$note）';
        } else {
          n = '被跳转到 ${_shorten(landed)}（$note）';
        }
      } else if (_lastMainFrameError.isNotEmpty && note == '加载失败') {
        n = '加载失败：$_lastMainFrameError';
      }
      hops.add(
        SniffHop(
          index: index,
          url: url,
          landedUrl: landed,
          elapsed: elapsed,
          candidateCount: collector.count,
          frameCount: collector.frames.length,
          note: n,
        ),
      );
    }

    // 上一层请求的地址（用来区分「被重定向」和「压根没导航过去」）
    var prevTarget = '';
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

        final prev = prevTarget.isEmpty ? null : prevTarget;
        prevTarget = target;
        _lastMainFrameError = '';

        if (!await _load(c, target, headers, viaLocation: hop > 0)) {
          await recordHop(
            index: hop + 1,
            url: target,
            elapsed: Duration.zero,
            note: '加载失败',
            prevUrl: prev,
          );
          break;
        }

        var hopDeadline = _hopDeadline(deadline);
        final hopStarted = DateTime.now();
        var warm = false;
        var nudged = false;
        var hit = false;
        var earlyHop = false;
        var siteDead = false;
        var stretched = false;
        final warmTimer = Timer(_warmup, () => warm = true);
        try {
          while (DateTime.now().isBefore(hopDeadline)) {
            if (_cancelRequested) break;
            // 主文档压根没加载起来（TLS 失败 / 被拦 / 超时）⇒ 再等也是白等。
            // 实测 `bd.jx.cn` 第 4 层就是这个样子：15 秒等下来 0 候选，
            // 日志里却看不出"页面根本没加载"。
            if (_lastMainFrameError.isNotEmpty && collector.count == 0) {
              AppLog.instance.log(
                '[Sniff] 第 ${hop + 1} 层主文档加载失败，提前收工：$_lastMainFrameError',
              );
              break;
            }
            await _inject(c);
            final b = collector.best;
            if (warm && b != null && b.isMedia) {
              best = b.url;
              hit = true;
              break;
            }
            // 页面可能要「用户点一下播放」才去取流 —— 隐形 WebView 里没人点，
            // 所以预热过后还一条候选都没有时，替它点一次。
            if (warm && !nudged && collector.count == 0) {
              nudged = true;
              await _nudge(c);
            }
            // 解析站**自己**报错（上游挂了 / 视频不存在）⇒ 地址永远不会出现，
            // 继续等就是白等。提前收工，让上层立刻换下一条线路。
            // 2026-10-31 实测：`api-api.789jiexi.net` 上游挂了以后，`api.php`
            // 对所有视频都回 `{"code":404,"msg":"请求上游解析接口失败"}`，
            // 页面走 `TheError()` —— 播放器根本不建，`stray.ad` / `<video>`
            // 一个都没有。这种情况下 25s 和 2s 的结果完全一样。
            if (warm && !siteDead && collector.count == 0) {
              siteDead = await _siteError(c);
              if (siteDead) {
                AppLog.instance
                    .log('[Sniff] 第 ${hop + 1} 层是解析站自己的错误页（上游不可用），提前收工');
                break;
              }
            }
            // 本层已经暴露出可跟的 iframe，自己却一条候选都没有
            // → 别把 [_hopCap] 白等完，省下的时间留给下一层。
            // 实测 `jx.muiu.site` 就是这种壳页：地址在 iframe 里，主 frame 永远等不到。
            // 反过来：**没有**可跟的 iframe 却还没候选 ⇒ 这就是最后一层，
            // 放宽到 [_lastHopCap]（WASM / 混淆播放器这类页面 10s 差一口气）。
            if (collector.count == 0 &&
                DateTime.now().difference(hopStarted) >= _minHop) {
              if (collector.nextFrame(visited) != null) {
                AppLog.instance.log('[Sniff] 本层无候选但露出 iframe，提前跟下一层');
                earlyHop = true;
                break;
              }
              if (!stretched) {
                stretched = true;
                final hard = DateTime.now().add(_lastHopCap);
                if (hard.isBefore(deadline)) {
                  hopDeadline = hard;
                } else {
                  hopDeadline = deadline;
                }
                AppLog.instance.log(
                  '[Sniff] 第 ${hop + 1} 层没有下一层可跟，时间片放宽到最后一层上限',
                );
              }
            }
            await Future<void>.delayed(const Duration(milliseconds: 300));
          }
        } finally {
          warmTimer.cancel();
        }

        final elapsed = DateTime.now().difference(hopStarted);
        final next = hit ? null : collector.nextFrame(visited);
        final String note;
        if (hit) {
          note = '命中地址';
        } else if (siteDead) {
          note = '解析站自己报错（上游不可用，换线路）';
        } else if (earlyHop) {
          note = '露出 iframe，提前跟下一层';
        } else if (next == null) {
          note = '没有可跟的 iframe（页面里没有 / 都跟过了）';
        } else {
          note = '等满 ${elapsed.inSeconds}s，继续下一层';
        }
        await recordHop(
          index: hop + 1,
          url: target,
          elapsed: elapsed,
          note: note,
          prevUrl: prev,
        );
        // 没命中才自检：命中了说明一切正常，没必要再探
        if (best == null) await _probeEnv(c, hop + 1);

        if (best != null) break;
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
        '跟过 ${collector.frames.length} 个 iframe，${hops.length} 层）: $url',
      );
      for (final h in hops) {
        AppLog.instance.log(
          '[Sniff]   ${h.index}. ${_shorten(h.url)} → ${h.note}',
        );
      }
    }
    return SniffResult(
      best: best,
      candidates: collector.sorted,
      frames: collector.frames,
      logs: collector.logs,
      hops: hops,
    );
  }

  /// 日志 / 界面里用的短地址（去掉 query，太长只看前缀）
  static String _shorten(String u) {
    try {
      final p = Uri.parse(u);
      final s = '${p.host}${p.path}';
      return s.length <= 60 ? s : '${s.substring(0, 57)}…';
    } catch (_) {
      return u.length <= 60 ? u : '${u.substring(0, 57)}…';
    }
  }

  /// 每一层的时间片：最多 [_hopCap]，且不超过剩余预算
  DateTime _hopDeadline(DateTime deadline) {
    final left = deadline.difference(DateTime.now());
    if (left <= Duration.zero) return DateTime.now();
    return DateTime.now().add(_hopCap < left ? _hopCap : left);
  }

  /// 加载一层页面。
  ///
  /// [viaLocation] 为 true 时用 `location.href` 跳转而不是 `loadRequest`，
  /// 这是**故意**的：
  ///
  /// 解析链靠 Referer 防直连。实测 `ckplayer.vip/jx.php`：
  ///   · 不带 Referer → `302` 回 `jiexi/?url=…`（而它已经在 visited 里）
  ///     ⇒ 跟帧循环原地打转，永远走不到真正出地址的 `789jiexi`
  ///   · 带任意 Referer → `200` + 759B，里面就是真 iframe
  ///
  /// 而 iOS 的 WKWebView 会**忽略** URLRequest 里自定义的 `Referer` header，
  /// 所以 `loadRequest(headers: {'Referer': …})` 在这条路上是无效的。
  /// `location.href` 是浏览器原生导航，Referer 由浏览器自动填成当前页面，
  /// 既符合真实用户行为，也绕开了上面那个限制。
  Future<bool> _load(
    WebViewController c,
    String url,
    Map<String, String> headers, {
    bool viaLocation = false,
  }) async {
    if (viaLocation) {
      try {
        // jsonEncode 保证引号 / 反斜杠被正确转义，避免拼出坏 JS
        await c.runJavaScript('window.location.href = ${jsonEncode(url)};');
        // 给导航一点时间真正开始，否则下面第一轮注入还打在旧文档上
        await Future<void>.delayed(const Duration(milliseconds: 250));
        return true;
      } catch (e) {
        AppLog.instance.log('[Sniff] 跳转失败 $url: $e');
        return false;
      }
    }
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

  /// 页面是不是「解析站**自己**的错误页」。
  ///
  /// ── 为什么要判这个（2026-10-31 实测）──────────────────────────
  /// `api-api.789jiexi.net` 的上游挂掉以后，`api.php` 对**任何**视频都返回
  /// `{"code":404,"msg":"请求上游解析接口失败"}`（本地 node 复现：用户那一集、
  /// 腾讯另一部、爱奇艺对照组，三条全一样，各重试 4 次）。
  ///
  /// 页面拿到非 200 就走 `TheError()`：播放器根本不建，`stray.ad` 不存在，
  /// `<video>` 也不存在 ⇒ **地址永远不会出现**。这时候把 [_hopCap] 等满
  /// 和等 2 秒的结果完全一样，区别只是用户多等 23 秒。
  ///
  /// 识别出来就提前收工，让上层立刻换下一条线路 —— 这是用户唯一能感知到的
  /// 修复：一条死线路 25s → 3s，三条线路加起来反而更快，而且能落到能用的那条。
  ///
  /// ⚠️ 只认「明确是错误页」的措辞，不认裸 `404`（正常页面里也常有 404 字样）。
  Future<bool> _siteError(WebViewController c) async {
    try {
      final raw = await c.runJavaScriptReturningResult(
        '(function(){try{'
        'var el=document.getElementById("error");'
        'if(el){var st=getComputedStyle(el);'
        'if(st.display!=="none"&&st.visibility!=="hidden"&&el.offsetHeight>0)return "1";}'
        'var t=((document.body&&document.body.innerText)||"").slice(0,3000);'
        'if(!t)return "0";'
        'if(/请求上游|解析失败|解析接口失败|暂时无法播放|该视频不存在|视频已失效|解析出错/.test(t))return "1";'
        'return "0";}catch(e){return "0";}})()',
      );
      return raw.toString().contains('1');
    } catch (_) {
      // 页面正在导航时求值会抛错 —— 当作"不是错误页"，交给正常流程
      return false;
    }
  }

  /// 注入后自检：hook 装上了吗？页面 JS 环境正常吗？明文有没有挂在实例上？
  ///
  /// 为什么必须有：`api-api.789jiexi.net` 那层 0 候选，但 curl 直接打它的
  /// `api.php` 是能出地址的（连 27 分钟前的旧 key 都能用）。说明问题不在
  /// 网络，而在「页面 JS 在 WebView 里到底跑没跑」或「hook 注入时机」——
  /// 这两件事以前日志里完全看不出来，只能靠猜。
  ///
  /// 输出示例：
  /// `hook=true jq=function cj=object stray=object cfg=object adUrl=https://…m3u8`
  Future<void> _probeEnv(WebViewController c, int hop) async {
    try {
      final raw = await c.runJavaScriptReturningResult(
        'JSON.stringify({'
        'hook:!!window.__catSniffInstalled,'
        'jq:typeof window.\$,'
        'cj:typeof window.CryptoJS,'
        'stray:typeof window.stray,'
        'cfg:typeof window.config,'
        'adUrl:((window.stray&&window.stray.ad&&window.stray.ad.url)||"").slice(0,120),'
        'frames:document.querySelectorAll("iframe").length'
        '})',
      );
      var s = raw.toString();
      // iOS 会把结果包成 JSON 字符串字面量（首尾引号 + 转义），先剥一层
      if (s.length > 1 && s.startsWith('"') && s.endsWith('"')) {
        try {
          final d = jsonDecode(s);
          if (d is String) s = d;
        } catch (_) {}
      }
      AppLog.instance.log('[Sniff] 第 $hop 层环境: $s');
    } catch (_) {
      // 页面正在导航时求值会抛错，忽略
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

  /// 替用户点一下播放（只在还没抓到任何候选时调用）
  Future<void> _nudge(WebViewController c) async {
    try {
      await c.runJavaScript(kAutoPlayNudgeJs);
      AppLog.instance.log('[Sniff] 页面没出地址，替用户点了一次播放');
    } catch (_) {
      // 同上，下一层再说
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
        // ── 🔴 主文档加载失败必须记下来（2026-10-31 补）──────────────
        //
        // 原来**没有**这两个回调 ⇒ 某一层导航失败时完全静默：
        // 日志里只剩「0 候选」，看不出是「页面没加载起来」还是
        // 「页面加载了但没地址」。实测 `bd.jx.cn` 那条链的第 4 层
        // （`https://123.129.229.14:4433`）就是这样 —— 日志显示
        // `frames:1 / jq:function / cj:undefined`，其实人还停在第 3 层，
        // 而分层诊断却写成「被跳转到 jiexi.bot.cd/jx/」，把排查带偏了。
        onWebResourceError: (e) {
          // 子资源（图片/广告）失败是常态，只关心主文档
          if (e.isForMainFrame == false) return;
          _lastMainFrameError = '${e.description}（${e.errorCode}）';
          AppLog.instance.w(
            '[Sniff] 主文档加载失败：$_lastMainFrameError → ${e.url}',
          );
        },
        onHttpError: (e) {
          final r = e.response;
          if (r == null || r.statusCode == null) return;
          if (r.statusCode! < 400) return;
          _lastMainFrameError = 'HTTP ${r.statusCode}';
          AppLog.instance.w('[Sniff] 主文档 HTTP ${r.statusCode}');
        },
      ));

    // ── 视口尺寸：**必须像真手机**（2026-10-31 改）──────────────────
    //
    // 原来是 1×1「透明但真的渲染」。问题不在渲染，在**布局尺寸**：
    //   · Artplayer / DPlayer / video.js / ckplayer 初始化时都会读
    //     `clientWidth` / `clientHeight`，容器太小时它们直接不建 `<video>`，
    //     或者建了也不 preload（iOS 对零面积元素的 video 尤其如此）；
    //   · 页面里 `if (w > 0)` 这类守卫很常见，1×1 会让整条初始化链走空。
    // 结果就是：页面自己的 `$.post` / 解密逻辑照跑（环境自检里
    // `stray`/`cfg` 都在），但地址始终不进播放器 ⇒ 候选恒为 0。
    //
    // 现在给 390×844 的正常手机视口，再用 1% 不透明度藏起来
    // （肉眼不可见，但保证视图真的被绘制 —— Offstage / 0 尺寸会让
    // 平台视图不挂载，JS 也就不跑了）。
    final entry = OverlayEntry(
      builder: (_) => Positioned(
        left: 0,
        top: 0,
        width: 390,
        height: 844,
        child: IgnorePointer(
          child: Opacity(
            opacity: 0.01,
            child: WebViewWidget(controller: c),
          ),
        ),
      ),
    );
    _entry = entry;
    overlay.insert(entry);
    AppLog.instance.log('[Sniff] 隐形 WebView 已挂载（390×844 · 1% 不透明度）');
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
