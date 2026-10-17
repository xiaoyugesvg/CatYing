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

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../common/constants.dart';
import '../reading/source/global_proxy.dart';
import 'app_log.dart';
import 'sniff_filter.dart';

class WebSniffService {
  WebSniffService._();
  static final WebSniffService instance = WebSniffService._();

  static const Duration _timeout = Duration(seconds: 8);

  /// 最多取多少个页面（含各级 iframe）—— 防止在复杂站点上爬成蜘蛛
  static const int _maxPages = 8;

  /// iframe 递归层数（0 = 只看首页，1 = 首页 + 其 iframe）
  static const int _maxDepth = 2;

  /// 没有影视后缀的候选，最多探测多少个（并发；防止对复杂站点发几十个请求）
  static const int _maxMimeProbes = 6;

  /// 单次 MIME 探测的超时（只取响应头，不能拖慢整个嗅探）
  static const Duration _mimeTimeout = Duration(seconds: 4);

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

  /// 从 [pageUrl] 出发找**第一个可播放的媒体直链**；找不到返回 null。
  ///
  /// [referer] 一般传页面地址自身（部分站点校验 Referer 才给页面）。
  Future<String?> findMediaUrl(String pageUrl, {String? referer}) async {
    final start = pageUrl.trim();
    if (!_isHttp(start)) return null;

    final visited = <String>{};
    var frontier = <String>[start];
    var depth = 0;
    var fetched = 0;
    // 没有影视后缀的候选（`/play?id=…`、`/stream/abc` 这类）。
    // 等所有页面扫完仍无后缀命中时，再用服务端 Content-Type 兜底验证。
    final probeCandidates = <String>[];

    while (frontier.isNotEmpty && depth <= _maxDepth && fetched < _maxPages) {
      final next = <String>[];
      for (final url in frontier) {
        if (fetched >= _maxPages) break;
        if (!visited.add(url)) continue;
        fetched++;

        final html = await _get(url, referer: referer);
        if (html == null || html.isEmpty) continue;

        // ① 页面本身（含内联 JS）里就有媒体直链？
        for (final u in _findMediaUrls(html)) {
          if (SniffFilter.acceptSniffUrl(u)) {
            AppLog.instance.log('[WebSniff] 命中（第 $fetched 个页面）: $u');
            return u;
          }
        }
        // ② 没有后缀、但形似媒体的地址先记下来（MIME 兜底用）
        for (final u in _findProbeCandidates(html, base: url)) {
          if (!probeCandidates.contains(u)) probeCandidates.add(u);
        }
        // ③ 抠 iframe / frame 的 src —— 跨域也在 HTML 里，照样读得到
        next.addAll(_findFrameUrls(html, base: url));
      }
      frontier = next;
      depth++;
    }

    // ④ MIME 兜底：扩展名被藏起来的直链，用**响应头**而不是后缀判断
    //（思路对齐 res-sniffer 的默认嗅探插件：按 Content-Type 识别媒体）
    final hit = await _probeByMime(probeCandidates, referer: referer);
    if (hit != null) {
      AppLog.instance.log('[WebSniff] MIME 命中: $hit');
      return hit;
    }
    return null;
  }

  /// 并发探测前 [max] 个候选，按**原顺序**取第一个 Content-Type 是媒体的。
  Future<String?> _probeByMime(List<String> candidates, {String? referer}) async {
    if (candidates.isEmpty) return null;
    final batch = candidates.take(_maxMimeProbes).toList();
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

  /// 用 `Content-Type` 判断这个地址是不是媒体（不下载内容，只取响应头）。
  ///
  /// 只发一个带 `Range: bytes=0-0` 的 GET：响应头一到就取消响应体，
  /// 对 m3u8 也只读几十字节，不会把整段视频拉下来。
  ///
  /// 判定口径（对齐 res-sniffer 的默认插件 + 常见 CDN）：
  ///   `video/*` / `audio/*` / `*mpegurl` / `dash+xml` / `ms-sstr`。
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
            'Range': 'bytes=0-0',
            if (referer != null && referer.isNotEmpty) 'Referer': referer,
          },
          // 403/404/5xx 也要拿到响应头而不是抛异常
          validateStatus: (_) => true,
        ),
      );
      body = resp.data;
      return _isMediaMime(resp.headers.value('content-type') ?? '');
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

  // ============================================================
  // 内部
  // ============================================================

  Future<String?> _get(String url, {String? referer}) async {
    try {
      final resp = await _client.get<String>(
        url,
        options: Options(headers: {
          if (referer != null && referer.isNotEmpty) 'Referer': referer,
        }),
      );
      return resp.data;
    } catch (e) {
      AppLog.instance.log('[WebSniff] 取页面失败 $url: $e');
      return null;
    }
  }

  /// 扫出文本里所有带**当前生效后缀清单**的媒体直链。
  ///
  /// 后缀串取自 [SniffFilter.mediaExtAlternation]（全项目唯一来源）。
  static List<String> _findMediaUrls(String text) {
    final re = RegExp(
      "https?://[^\\s\"'<>\\\\]+?\\.(?:${SniffFilter.mediaExtAlternation})"
      "(?:[?#][^\\s\"'<>\\\\]*)?",
      caseSensitive: false,
    );
    final out = <String>[];
    for (final m in re.allMatches(text)) {
      final u = m.group(0);
      if (u != null && u.isNotEmpty) out.add(u);
    }
    return out;
  }

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

    for (final m in _probeAttrRe.allMatches(html)) {
      take(m.group(1) ?? '');
    }
    for (final m in _probeJsonRe.allMatches(html)) {
      take(m.group(1) ?? '');
    }
    return out;
  }

  static List<String> _findFrameUrls(String html, {required String base}) {
    final out = <String>[];
    for (final m in _frameRe.allMatches(html)) {
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
