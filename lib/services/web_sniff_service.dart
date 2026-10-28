// lib/services/web_sniff_service.dart
//
// WebView 之外的「网络层嗅探」—— 跨域 iframe 的兜底方案。
//
// ── 解决什么（用户 2026-10-15）────────────────────────────────
// 解析站的播放器**大多是跨域 iframe**。而 webview_flutter 4.x 的
// `runJavaScript` 没有 allFrames 参数（那是 flutter_inappwebview 的能力），
// 注入脚本只能作用于主 frame；跨域 iframe 的 `contentDocument` 又会抛
// SecurityError —— 于是 iframe 里的视频在 WebView 里**完全抓不到**。
//
// 但 **Dart 侧发 HTTP 没有同源策略**：iframe 的 `src` 在页面 HTML 里是可读的，
// 我们把它取回来自己请求、自己扫媒体地址，就能覆盖相当一部分这类站点：
//   1. 取当前页面 HTML → 扫媒体直链；
//   2. 抠出页面里的 iframe / frame 的 src（跨域也照样取得到）→ 递归取它们的
//      HTML 再扫（限层数、限页数）。
//
// ── 覆盖不到的情况 ───────────────────────────────────────────
// 地址由 JS **运行时**拼出来（atob 解码、接口返回后 setAttribute）——纯 HTTP
// 拿不到。这类只能靠 WebView 内 hook，或整体迁移到 flutter_inappwebview
// 做资源请求拦截（shouldInterceptRequest 能拿到所有 frame 的网络请求）。

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:tvbox/common/constants.dart';
import 'package:tvbox/reading/source/global_proxy.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/sniff_filter.dart';
import 'package:tvbox/services/webview_fetch_service.dart';

class WebSniffService {
  WebSniffService._();
  static final WebSniffService instance = WebSniffService._();

  static const Duration _timeout = Duration(seconds: 8);

  /// 最多取多少个页面（含各级 iframe）—— 防止在复杂站点上爬成蜘蛛
  static const int _maxPages = 8;

  /// iframe 递归层数（0 = 只看首页，1 = 首页 + 其 iframe）
  ///
  /// 解析站常见链路是「播放页 → 播放器 iframe → 真正的播放器 iframe」，
  /// 两层就够；给到 3 是为了留一点余量（2026-10-28 深挖）。
  static const int _maxDepth = 3;

  /// 最多用 **WebView 渲染兜底**几次。
  ///
  /// 每次渲染都要真开一个隐形 WKWebView 并等页面 JS 跑完（最长 20 秒）。
  /// 原来每个取不到内容的页面都会走一次 —— 一个 8 页面的站点全是 SPA 时，
  /// 最坏要 8 × 20 秒 = 两分半，用户看到的就是「嗅探卡死不动」。
  /// 现在只给最可能需要渲染的页面（入口页 + 它的直接 iframe）留 2 次名额，
  /// 其余纯 HTTP 拿不到就跳过（2026-10-28 深挖）。
  static const int _maxWebviewRenders = 2;

  /// 没有影视后缀的候选，最多探测多少个（并发；防止对复杂站点发几十个请求）
  static const int _maxMimeProbes = 6;

  /// 单次 MIME 探测的超时（只取响应头，不能拖慢整个嗅探）
  static const Duration _mimeTimeout = Duration(seconds: 4);

  /// 单页最多读多少字节。
  ///
  /// 🔴 原来 `_get` 用 `_client.get<String>(url)` —— dio 会把响应体**整个**
  /// 读进内存，没有任何上限。嗅探的输入是**用户/源给的任意网页**，其中
  /// 不乏几 MB 的压缩包目录页、几百 MB 的日志页，甚至一个误配的媒体直链
  /// （那不是网页，但 URL 会被当页面去取）。iOS 上直接 OOM 崩掉。
  /// 这里给 2 MB 上限：正常播放页远小于此，超了就截断（截断的 HTML 仍能
  /// 扫出前面的媒体地址，比整页丢掉更有用）。
  static const int _maxPageBytes = 2 * 1024 * 1024;

  /// MIME 探测时读多少个字节（`Range: bytes=0-127`）。
  ///
  /// 不能只读 1 字节：Content-Type 不明时（很多 CDN 把 m3u8 发成
  /// `application/octet-stream` 或 `text/plain`）只能靠**开头字节**判断。
  static const int _mimePeekBytes = 128;

  Dio? _dio;
  Dio get _client => _dio ??= _createDio();

  static Dio _createDio() {
    final dio = Dio(BaseOptions(
      connectTimeout: _timeout,
      receiveTimeout: _timeout,
      responseType: ResponseType.plain,
      headers: {'User-Agent': AppConstants.defaultUserAgent},
    ));
    try {
      // 与其它模块一致：必须套全局代理，否则开代理时直接请求失败
      applyGlobalProxy(dio);
    } catch (e) {
      AppLog.instance.log('[WebSniff] 代理配置失败: $e');
    }
    return dio;
  }

  /// 从 [pageUrl] 出发找**最可播的那个媒体直链**；找不到返回 null。
  ///
  /// [referer] 一般传页面地址自身（部分站点校验 Referer 才给页面）。
  ///
  /// 2026-10-28 深挖的三处行为修正（都在这个方法里）：
  ///   · **不再"第一个命中就交出去"**：原来按 HTML 里出现的先后取第一个
  ///     带后缀的地址，而 HLS 页面往往先出现几十条 `.ts` 切片、`.m3u8`
  ///     在更后面 —— 结果播几秒就结束。现在按
  ///     [SniffFilter.candidateRank] 边扫边比，只有拿到 m3u8（rank ≤ 1）
  ///     才提前收工，其余命中继续往后扫，最后取最优。
  ///   · **iframe 的 src 本身就是媒体直链时不再当网页抓**：`<iframe src="…/index.m3u8">`
  ///     原来会去 GET 这个 m3u8，再从正文里扫出某个 `.ts` 切片当结果。
  ///   · **iframe 的 Referer 用父页面**：不少播放器 iframe 会校验 Referer，
  ///     一直用顶层地址会被 403。
  Future<String?> findMediaUrl(String pageUrl, {String? referer}) async {
    final start = pageUrl.trim();
    if (!_isHttp(start)) return null;

    final visited = <String>{};
    // 队列元素 = (本页地址, 它的父页面地址) —— 父页面地址只用于 Referer
    var frontier = <(String, String?)>[(start, referer)];
    var depth = 0;
    var fetched = 0;
    var renders = 0;
    // 没有影视后缀的候选（`/play?id=…`、`/stream/abc` 这类）。
    // 等所有页面扫完仍无后缀命中时，再用服务端 Content-Type 兜底验证。
    final probeCandidates = <String>[];

    // 目前找到的最佳直链。rank 越小越可能播完整片（0 = m3u8 主列表）。
    String? best;
    var bestRank = 1 << 20;

    /// 收一条候选；返回 true 表示"已经足够好，可以停止扫描"。
    bool offer(String u) {
      if (!SniffFilter.acceptSniffUrl(u)) return false;
      final r = SniffFilter.candidateRank(u);
      if (r < bestRank) {
        best = u;
        bestRank = r;
      }
      // m3u8（主列表或普通列表）就是最终答案，没必要再扫后面的页面
      return bestRank <= 1;
    }

    while (frontier.isNotEmpty && depth <= _maxDepth && fetched < _maxPages) {
      final next = <(String, String?)>[];
      var stop = false;
      for (final (url, parent) in frontier) {
        if (fetched >= _maxPages || stop) break;
        if (!visited.add(url)) continue;

        // ① 这个地址本身就是一个媒体直链（入口就是 m3u8，或 iframe 的
        //    src 直接指向 m3u8）—— 绝不能当网页去 GET：m3u8 正文里全是
        //    `.ts` 切片，扫出来只会拿到其中一小段。
        if (SniffFilter.isDirectMedia(url)) {
          fetched++;
          if (offer(url)) {
            stop = true;
            break;
          }
          continue;
        }

        fetched++;
        final pageReferer = parent ?? referer;
        var html = await _get(url, referer: pageReferer);
        // ── 兜底：SPA / CF 挑战页交给 WKWebView 渲染后再扫 ──────────
        //
        // 纯 HTTP 拿到的是空壳（JS 还没跑）或「Just a moment」挑战页，
        // 这种页面里一个媒体链接都没有。用通用 WebView 通道打开，
        // 等 JS 渲染完（尽力等挑战自动过）再取 DOM。
        //
        // ⚠️ 名额有限（见 [_maxWebviewRenders]）：渲染很贵，不能每个页面都来一次。
        if ((html == null ||
                html.isEmpty ||
                WebViewFetchService.looksLikeChallenge(html)) &&
            renders < _maxWebviewRenders) {
          renders++;
          final page = await WebViewFetchService.instance.fetchHtml(
            url,
            headers: (pageReferer == null || pageReferer.isEmpty)
                ? null
                : {'Referer': pageReferer},
            timeoutMs: 15000,
          );
          if (page != null && page.html.isNotEmpty) {
            html = page.html;
            AppLog.instance.log('[WebSniff] WebView 渲染兜底: $url'
                '${page.challenged ? '（仍是挑战页）' : ''}');
          }
        }
        if (html == null || html.isEmpty) continue;

        // ② 页面本身（含内联 JS）里就有媒体直链？
        for (final u in _findMediaUrls(html)) {
          if (offer(u)) {
            stop = true;
            break;
          }
        }
        if (stop) break;
        // ③ 没有后缀、但形似媒体的地址先记下来（MIME 兜底用）
        for (final u in _findProbeCandidates(html, base: url)) {
          if (!probeCandidates.contains(u)) probeCandidates.add(u);
        }
        // ④ 抠 iframe / frame 的 src —— 跨域也在 HTML 里，照样读得到
        for (final f in _findFrameUrls(html, base: url)) {
          // 直接指向媒体的 iframe：当场收下，不要塞进队列当网页去抓
          //（塞进去的话，最外层 depth 用尽时还会漏掉它）
          if (SniffFilter.isDirectMedia(f)) {
            if (offer(f)) {
              stop = true;
              break;
            }
          } else {
            next.add((f, url));
          }
        }
        if (stop) break;
      }
      frontier = next;
      depth++;
      if (stop) break;
    }

    if (best != null) {
      AppLog.instance.log('[WebSniff] 命中（rank=$bestRank）: $best');
      return best;
    }

    // ⑤ MIME 兜底：扩展名被藏起来的直链，用**响应头**而不是后缀判断
    //（思路对齐 res-sniffer 的默认嗅探插件：按 Content-Type 识别媒体）
    final hit = await _probeByMime(probeCandidates, referer: referer);
    if (hit != null) {
      AppLog.instance.log('[WebSniff] MIME 命中: $hit');
      return hit;
    }
    return null;
  }

  /// 并发探测前 [max] 个候选，取第一个 Content-Type 是媒体的。
  ///
  /// 探测顺序不是页面里的先后顺序：路径里带播放语义的（`/hls/index`、
  /// `/live/xxx`、`/play/123`）先探，其余保持原顺序 —— 名额只有 6 个，
  /// 别被页面里的统计/埋点接口占满（2026-10-28 深挖）。
  Future<String?> _probeByMime(List<String> candidates, {String? referer}) async {
    if (candidates.isEmpty) return null;
    final batch = orderProbes(candidates).take(_maxMimeProbes).toList();
    final checks = await Future.wait(
      batch.map((u) => looksLikeMediaByMime(u, referer: referer)),
    );
    for (var i = 0; i < checks.length; i++) {
      if (!checks[i]) continue;
      final u = batch[i];
      if (SniffFilter.acceptSniffUrl(u, mediaVerified: true)) return u;
    }
    return null;
  }

  /// 路径里的"播放语义"关键词 —— 命中越多越优先探测。
  static const List<String> _probeHintWords = [
    'm3u8', 'playlist', 'master', 'index', 'hls', 'live',
    'stream', 'play', 'video', 'media', 'vod',
  ];

  /// MIME 探测顺序（稳定排序：同分保持原顺序）。
  ///
  /// 公开给 webview_player_page 的 `_mimeFallback` 复用 —— 两处批次名额都
  /// 很紧（6 / 8 个），页面统计/埋点接口（`/api/track`、`/stat?id=…`）若
  /// 排在前面会先把名额占满，真流就被挤掉（2026-10-28 深挖）。
  static List<String> orderProbes(List<String> candidates) {
    if (candidates.length < 2) return candidates;
    int score(String u) {
      final l = u.toLowerCase();
      var s = 0;
      for (final w in _probeHintWords) {
        if (l.contains(w)) s++;
      }
      return s;
    }

    final indexed = <(int, int, String)>[
      for (var i = 0; i < candidates.length; i++)
        (score(candidates[i]), i, candidates[i]),
    ];
    indexed.sort((a, b) {
      final byScore = b.$1.compareTo(a.$1); // 分高在前
      return byScore != 0 ? byScore : a.$2.compareTo(b.$2);
    });
    return [for (final e in indexed) e.$3];
  }

  /// 用 `Content-Type`（+ 开头字节）判断这个地址是不是媒体。
  ///
  /// 只发一个带 `Range: bytes=0-127` 的 GET：响应头一到就取消响应体，
  /// 最多读 128 字节，不会把整段视频拉下来。
  ///
  /// 判定口径（对齐 res-sniffer 的默认插件 + 常见 CDN）：
  ///   1. `video/*` / `audio/*` / `*mpegurl` / `dash+xml` / `ms-sstr` → 是；
  ///   2. Content-Type 不明或不可信（空 / `octet-stream` / `text/plain`）
  ///      → **看开头字节**：`#EXTM3U` = HLS 播放列表，`ftyp` = MP4。
  ///
  /// 第 2 步是 2026-10-27 补的：不少 CDN 把 m3u8 发成
  /// `application/octet-stream`（甚至 `text/plain`），只认 Content-Type
  /// 会把这些直链**全部漏掉** —— 而它们恰恰是最常见的"无后缀直链"。
  Future<bool> looksLikeMediaByMime(String url, {String? referer}) async {
    if (!_isHttp(url)) return false;
    ResponseBody? body;
    try {
      final resp = await _client.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          receiveTimeout: _mimeTimeout,
          sendTimeout: _mimeTimeout,
          headers: {
            'Range': 'bytes=0-${_mimePeekBytes - 1}',
            if (referer != null && referer.isNotEmpty) 'Referer': referer,
          },
          // 403/404/5xx 也要拿到响应头而不是抛异常
          validateStatus: (_) => true,
        ),
      );
      body = resp.data;
      final contentType = resp.headers.value('content-type') ?? '';
      if (_isMediaMime(contentType)) return true;
      // Content-Type 不可信时才去读字节（多读一次流，别浪费在网络正常的情况）
      if (!_mayHidePlaylist(contentType)) return false;
      final head = await _readHead(body!.stream, _mimePeekBytes);
      final byBytes = _looksLikeMediaBytes(head);
      if (byBytes) {
        AppLog.instance.log(
            '[WebSniff] 按开头字节识别为媒体（Content-Type="$contentType"）: $url');
      }
      return byBytes;
    } catch (e) {
      AppLog.instance.log('[WebSniff] MIME 探测失败 $url: $e');
      return false;
    } finally {
      // 立刻断开，避免把响应体（可能是整段视频）读完
      try {
        await body?.stream.listen(null).cancel();
      } catch (_) {}
    }
  }

  /// Content-Type → 是否媒体
  static bool _isMediaMime(String contentType) {
    final ct = contentType.toLowerCase();
    if (ct.isEmpty) return false;
    if (ct.startsWith('video/') || ct.startsWith('audio/')) return true;
    return ct.contains('mpegurl') ||
        ct.contains('dash+xml') ||
        ct.contains('ms-sstr');
  }

  /// 这种 Content-Type 下**媒体可能被藏起来**（需要看字节才能确定）。
  ///
  /// ⚠️ 不要包含 `text/html` —— 网页就是网页，读字节也救不回来，
  /// 放进来只会白白多读一次流。
  static bool _mayHidePlaylist(String contentType) {
    final ct = contentType.toLowerCase();
    if (ct.isEmpty) return true; // 没给 Content-Type 的服务器不少
    return ct.contains('octet-stream') || ct.startsWith('text/plain');
  }

  /// 开头字节 → 是否媒体。
  ///
  ///   · `#EXTM3U` —— HLS 播放列表（m3u8），最常见；
  ///   · `....ftyp` —— MP4 / MOV 的 box 头（偏移 4 处是 `ftyp`）；
  ///   · `#EXTINF` —— 少数不带 `#EXTM3U` 头的切片列表。
  static bool _looksLikeMediaBytes(List<int> head) {
    if (head.isEmpty) return false;
    // 只取前面一小段，避免把二进制转成巨大的字符串
    final text = String.fromCharCodes(
      head.length > 64 ? head.sublist(0, 64) : head,
    ).trimLeft();
    if (text.startsWith('#EXTM3U') || text.startsWith('#EXTINF')) return true;
    if (head.length >= 8) {
      final tag = String.fromCharCodes(head.sublist(4, 8));
      if (tag == 'ftyp') return true;
    }
    return false;
  }

  /// 从流里读最多 [max] 字节（读够就停，不把剩余内容拉下来）。
  ///
  /// ⚠️ `ResponseBody.stream` 是**单订阅**流：只能 listen 一次，
  /// 而且读够之后必须主动 `cancel()`，否则连接会一直挂着。
  static Future<List<int>> _readHead(Stream<List<int>> stream, int max) async {
    final buf = BytesBuilder(copy: false);
    final done = Completer<void>();
    late final StreamSubscription<List<int>> sub;
    sub = stream.listen(
      (chunk) {
        buf.add(chunk);
        if (buf.length >= max && !done.isCompleted) done.complete();
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (_) {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    // 短超时：读不到字节就当没读到，不能拖住整个嗅探
    await done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    try {
      await sub.cancel();
    } catch (_) {}
    final bytes = buf.takeBytes();
    return bytes.length > max ? bytes.sublist(0, max) : bytes;
  }

  // ============================================================
  // 内部
  // ============================================================

  /// 取一个网页的 HTML（**带上限**，见 [_maxPageBytes]）。
  ///
  /// 原来是 `_client.get<String>(url)`：dio 会把响应体整个读进内存，
  /// 而这里取的地址来自"用户/源给的任意页面"—— 撞上大文件就直接 OOM。
  /// 现在改成流式读 + 硬上限，超了截断（截断的 HTML 仍能扫出前面的地址）。
  Future<String?> _get(String url, {String? referer}) async {
    ResponseBody? body;
    try {
      final resp = await _client.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            if (referer != null && referer.isNotEmpty) 'Referer': referer,
          },
        ),
      );
      body = resp.data;
      // Content-Length 明显超大就干脆不读（省流量，也避免读一半再截断）
      final declared = int.tryParse(resp.headers.value('content-length') ?? '');
      if (declared != null && declared > _maxPageBytes) {
        AppLog.instance.log(
            '[WebSniff] 页面过大（$declared B > $_maxPageBytes），跳过: $url');
        return null;
      }
      final head = await _readHead(body!.stream, _maxPageBytes);
      // allowMalformed：GBK 等非 UTF-8 页面会解出乱码，但不会抛异常 ——
      // 乱码里照样能正则出 ASCII 的 http 地址，比直接放弃有用
      return utf8.decode(head, allowMalformed: true);
    } catch (e) {
      AppLog.instance.log('[WebSniff] 取页面失败 $url: $e');
      return null;
    } finally {
      try {
        await body?.stream.listen(null).cancel();
      } catch (_) {}
    }
  }

  /// 扫出文本里所有带**当前生效后缀清单**的媒体直链。
  ///
  /// 后缀串取自 [SniffFilter.mediaExtAlternation]（全项目唯一来源）。
  ///
  /// ⚠️ 必须先做一次 `\/` → `/` 的**反转义**：播放页里最关键的地址几乎都
  /// 藏在 `<script>` 的 JSON 字符串里，写作 `"https:\/\/cdn\/x\/index.m3u8"`。
  /// 正则的字符类排除了反斜杠（防止匹配到断行/转义），于是这类地址
  /// **一个都扫不出来** —— 这是"嗅探明明打开了却什么都抓不到"的常见原因
  /// （2026-10-28 深挖）。反转义只在副本上做，不改原文。
  static List<String> _findMediaUrls(String text) {
    final src = _unescapeSlashes(text);
    final re = RegExp(
      "https?://[^\\s\"'<>\\\\]+?\\.(?:${SniffFilter.mediaExtAlternation})"
      "(?:[?#][^\\s\"'<>\\\\]*)?",
      caseSensitive: false,
    );
    final out = <String>[];
    for (final m in re.allMatches(src)) {
      final u = m.group(0);
      if (u != null && u.isNotEmpty) out.add(u);
    }
    return out;
  }

  /// 把 JS/JSON 字符串里的 `\/` 还原成 `/`（只在副本上做，不改原文）。
  ///
  /// 见 [_findMediaUrls] 的说明：不做这一步，藏在 `<script>` 里的地址全扫不到。
  static String _unescapeSlashes(String text) =>
      text.contains('\\/') ? text.replaceAll('\\/', '/') : text;

  static final RegExp _frameRe = RegExp(
    r'''<(?:iframe|frame)\b[^>]*?\b(?:src|data-src)\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  );

  /// 「可能藏着媒体」的属性（video/source/audio 的 src、各种 data-*）
  static final RegExp _probeAttrRe = RegExp(
    r'''(?:src|data-src|data-url|data-video|data-play|data-file|data-original)'''
    r'''\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  );

  /// 内联 JS / JSON 里常见的播放地址键（`{url:'/play?id=1'}`）
  static final RegExp _probeJsonRe = RegExp(
    r'''["'](?:url|src|file|playUrl|play_url|videoUrl|video_url|video|m3u8|mp4)'''
    r'''["']\s*:\s*["']([^"']+)["']''',
    caseSensitive: false,
  );

  /// 明显不是媒体的后缀 —— 这些不进 MIME 探测队列
  static const List<String> _nonMediaExts = [
    '.js', '.css', '.json', '.html', '.htm', '.xml', '.txt',
    '.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.ico', '.bmp',
    '.woff', '.woff2', '.ttf', '.eot', '.map',
  ];

  /// 从页面里挑出**没有影视后缀、但可能是媒体直链**的候选。
  ///
  /// 只认明确的语义位置（video/source/audio 的 src、data-*、JS 里
  /// playUrl/videoUrl 之类的键），不做"全页面 http 链接"的泛匹配 ——
  /// 否则每页都会挑出几十个 API/CSS，再逐个探测会把站点打爆。
  static List<String> _findProbeCandidates(String html, {required String base}) {
    final out = <String>[];
    final seen = <String>{};
    void take(String raw) {
      final abs = _absolute(raw.trim(), base);
      if (abs == null) return;
      // 有影视后缀的走原路径（_findMediaUrls），这里只收"藏起来"的
      if (SniffFilter.isDirectMedia(abs)) return;
      final path = Uri.tryParse(abs)?.path.toLowerCase() ?? '';
      if (path.isEmpty || path.endsWith('/')) return;
      if (_nonMediaExts.any(path.endsWith)) return;
      if (!seen.add(abs)) return;
      out.add(abs);
    }

    final src = _unescapeSlashes(html);
    for (final m in _probeAttrRe.allMatches(src)) {
      take(m.group(1) ?? '');
    }
    for (final m in _probeJsonRe.allMatches(src)) {
      take(m.group(1) ?? '');
    }
    return out;
  }

  static List<String> _findFrameUrls(String html, {required String base}) {
    final out = <String>[];
    for (final m in _frameRe.allMatches(_unescapeSlashes(html))) {
      final abs = _absolute((m.group(1) ?? '').trim(), base);
      if (abs != null) out.add(abs);
    }
    return out;
  }

  /// 相对地址 → 绝对地址（iframe 的 src 常是 `/player?…` 这种）。
  static String? _absolute(String raw, String base) {
    if (raw.isEmpty) return null;
    if (raw.startsWith('//')) return 'https:$raw';
    if (_isHttp(raw)) return raw;
    if (raw.startsWith('data:') ||
        raw.startsWith('javascript:') ||
        raw.startsWith('about:')) {
      return null;
    }
    try {
      return Uri.parse(base).resolveUri(Uri.parse(raw)).toString();
    } catch (_) {
      return null;
    }
  }

  static bool _isHttp(String u) =>
      u.startsWith('http://') || u.startsWith('https://');

  // ============================================================
  // 单测钩子（纯解析部分不依赖网络）
  // ============================================================

  /// 仅供单测：扫文本里的媒体直链
  @visibleForTesting
  static List<String> debugFindMediaUrls(String text) => _findMediaUrls(text);

  /// 仅供单测：抠出 HTML 里的 iframe 地址（已解析成绝对地址）
  @visibleForTesting
  static List<String> debugFindFrameUrls(String html, String base) =>
      _findFrameUrls(html, base: base);

  /// 仅供单测：挑出"没有后缀、待 MIME 验证"的候选
  @visibleForTesting
  static List<String> debugFindProbeCandidates(String html, String base) =>
      _findProbeCandidates(html, base: base);

  /// 仅供单测：Content-Type 判定
  @visibleForTesting
  static bool debugIsMediaMime(String contentType) =>
      _isMediaMime(contentType);
}
