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
        // ② 抠 iframe / frame 的 src —— 跨域也在 HTML 里，照样读得到
        next.addAll(_findFrameUrls(html, base: url));
      }
      frontier = next;
      depth++;
    }
    return null;
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
}
