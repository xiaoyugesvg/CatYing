import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'package:tvbox/reading/source/global_proxy.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/media_sniffer.dart';
import 'package:tvbox/services/parse_lines.dart';

/// 后台把「网页播放地址 / 解析接口链接」解析成**媒体直链**。
///
/// ── 三条硬约束（用户 2026-10-29 明确要求）──────────────────────
///   1. **全程在后台跑**：不起 WebView、不弹页面、不打断播放器；
///   2. **没有开关**：只要播放地址是网页形态，就直接解析，用户无感；
///   3. **给足时间**：网页/解析接口经常要 2~6 秒才吐地址，而且第一轮
///      常常空手（CDN 预热、接口排队），所以这里做**多轮重试 + 总预算**，
///      而不是一次失败就判死。
///
/// ── 解析顺序 ──────────────────────────────────────────────────
///   ① 直接抓页面 HTML，正则找 m3u8/mp4（最快，不依赖解析线路）；
///   ② 页面里嵌的 iframe / `?url=` 再跟一跳（很多"播放页"其实是个壳）；
///   ③ 解析线路（订阅 `parses` 或自定义）逐条试 —— 选中那条排最前；
///   ④ 以上都没拿到 ⇒ 在总预算内再重来一轮（最多 3 轮）。
///
/// 结果按页面地址缓存（同一集重进不再解析）。
class MediaResolver {
  MediaResolver._();
  static final MediaResolver instance = MediaResolver._();

  /// 默认总预算：足够跑完 3 轮 + 若干条解析线路，又不至于让用户干等
  static const Duration defaultBudget = Duration(seconds: 22);

  /// 单次 HTTP 超时上限
  static const Duration _requestTimeout = Duration(seconds: 8);

  /// 页面 → 媒体地址 缓存（按集缓存，重进不再解析）
  final Map<String, String> _cache = {};
  static const int _cacheLimit = 60;

  /// 正在解析的页面（同一地址并发请求合并，避免重复打接口）
  final Map<String, Future<String?>> _inflight = {};

  String? cached(String pageUrl) => _cache[pageUrl];

  void clearCache() => _cache.clear();

  /// 解析入口。返回 null = 没解析出来（调用方按"这条线路播不了"处理）。
  ///
  /// [onProgress] 可选：把"正在试第几条线路"回给调用方，用于界面上的
  /// 一行小字提示（不弹窗、不遮画面）。
  Future<String?> resolve(
    String pageUrl, {
    Map<String, String> headers = const {},
    Duration budget = defaultBudget,
    void Function(String message)? onProgress,
  }) {
    final url = pageUrl.trim();
    if (url.isEmpty) return Future.value(null);
    // 本来就是媒体直链：不需要解析
    if (MediaSniffer.isMediaUrl(url)) return Future.value(url);
    if (!url.startsWith('http')) return Future.value(null);

    final hit = _cache[url];
    if (hit != null) {
      AppLog.instance.log('[Resolve] 命中缓存: $url → $hit');
      return Future.value(hit);
    }
    final running = _inflight[url];
    if (running != null) return running;

    final task = _doResolve(
      url,
      headers: headers,
      budget: budget,
      onProgress: onProgress,
    );
    _inflight[url] = task;
    return task.whenComplete(() => _inflight.remove(url));
  }

  Future<String?> _doResolve(
    String pageUrl, {
    required Map<String, String> headers,
    required Duration budget,
    void Function(String message)? onProgress,
  }) async {
    final deadline = DateTime.now().add(budget);
    final dio = Dio(
      BaseOptions(
        connectTimeout: _requestTimeout,
        receiveTimeout: _requestTimeout,
        followRedirects: true,
        responseType: ResponseType.plain,
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    applyGlobalProxy(dio);

    String? found;
    try {
      // ── 最多 3 轮：第一轮常常空手，重试往往就有了 ──────────────
      for (var round = 1; round <= 3 && found == null; round++) {
        if (DateTime.now().isAfter(deadline)) break;
        if (round > 1) {
          // 轮间退避：给接口/CDN 一点时间
          await Future<void>.delayed(Duration(milliseconds: 400 * round));
          if (DateTime.now().isAfter(deadline)) break;
        }
        onProgress?.call(
          round == 1 ? '正在解析播放地址…' : '正在重试解析（第 $round 轮）…',
        );

        // ① 直接抓页面
        found = await _fromPage(dio, pageUrl, headers, deadline);
        if (found != null) break;

        // ② 解析线路
        final lines = ParseLineStore.instance.attemptOrder.take(6).toList();
        for (var i = 0; i < lines.length; i++) {
          if (DateTime.now().isAfter(deadline)) break;
          final line = lines[i];
          onProgress?.call('正在用「${line.name}」解析…');
          found = await _fromParseLine(dio, line, pageUrl, headers, deadline);
          if (found != null) {
            AppLog.instance.log(
              '[Resolve] 解析成功（${line.name}，第 $round 轮）: $found',
            );
            break;
          }
        }
      }
    } catch (e) {
      AppLog.instance.w('[Resolve] 解析异常: $e');
    } finally {
      dio.close(force: true);
    }

    if (found != null) {
      _cache[pageUrl] = found;
      if (_cache.length > _cacheLimit) {
        _cache.remove(_cache.keys.first);
      }
    } else {
      AppLog.instance.w('[Resolve] 解析失败（已用 ${budget.inSeconds}s 预算）: $pageUrl');
    }
    return found;
  }

  /// ① 抓页面本身（递归跟 iframe / `?url=` / 返回的网页地址）
  Future<String?> _fromPage(
    Dio dio,
    String pageUrl,
    Map<String, String> headers,
    DateTime deadline,
  ) =>
      _digUrl(dio, pageUrl, headers, deadline, 0);

  /// 链路最大跳数。
  ///
  /// 真实链路经常是三层：`解析接口 → ckplayer 壳页 → iframe 播放器 → m3u8`。
  /// 只跟一跳会停在壳页上，把**网页地址**当播放地址交给播放器 —— 用户看到的
  /// 就是「这个地址是网页而不是视频直链」（2026-10-30 截图里的
  /// `www.ckplayer.vip/jiexi/` 正是这一层）。给到 3 跳够用，再多就是死循环了。
  static const int _maxChainDepth = 3;

  /// 抓 [url] 并从中挖媒体直链（递归）。
  Future<String?> _digUrl(
    Dio dio,
    String url,
    Map<String, String> headers,
    DateTime deadline,
    int depth,
  ) async {
    if (depth > _maxChainDepth) return null;
    final body = await _get(dio, url, headers, deadline);
    if (body == null) return null;
    return _digBody(dio, body, url, headers, deadline, depth);
  }

  /// 从一段响应正文里挖媒体直链（递归）。
  ///
  /// 顺序（每一层都一样）：
  ///   ① JSON 里的 `url` / `data.url` / `playUrl` —— **必须真的是媒体地址**，
  ///      不是就当成"下一页"继续挖；
  ///   ② 正文里直接出现的 m3u8/mp4；
  ///   ③ iframe 的 src / `?url=` 参数指向的下一页。
  Future<String?> _digBody(
    Dio dio,
    String body,
    String baseUrl,
    Map<String, String> headers,
    DateTime deadline,
    int depth,
  ) async {
    // ① 解析接口绝大多数返回 JSON：`{"url": "https://..."}` / `{"data":{"url":...}}`
    final fromJson = _mediaFromJson(body);
    if (fromJson != null) {
      if (MediaSniffer.isMediaUrl(fromJson)) return fromJson;
      // 返回的是**另一个网页**（壳页）→ 继续往下挖，别把它当播放地址
      if (depth < _maxChainDepth) {
        final deeper =
            await _digUrl(dio, fromJson, headers, deadline, depth + 1);
        if (deeper != null) return deeper;
      }
    }

    // ② 正文里直接有媒体地址（绝大多数 CMS 播放页 / 解析页的 HTML 内嵌 JSON）
    final direct = _pickBest(MediaSniffer.extractFromText(body));
    if (direct != null) return direct;

    // ③ 壳页面：跟 iframe / `?url=`
    if (depth >= _maxChainDepth) return null;
    final nested = _nestedTarget(body);
    if (nested == null || nested == baseUrl) return null;
    return _digUrl(dio, nested, headers, deadline, depth + 1);
  }

  /// ③ 走一条解析线路
  ///
  /// 2026-10-30 补了两个**实战必需的**细节：
  ///   ① 带上线路自己的请求头（`parses[].ext.header`）—— 不少接口按 UA
  ///      决定给不给地址，用默认 UA 请求只会拿回一个空白页；
  ///   ② 原样拼接失败后**再用编码后的地址试一次** —— TVBox 各分支对
  ///      `type=0` 的约定不统一，有的要 `?url=<原样>`，有的要 URL 编码，
  ///      只试一种会有一半接口用不了。
  Future<String?> _fromParseLine(
    Dio dio,
    ParseLine line,
    String pageUrl,
    Map<String, String> headers,
    DateTime deadline,
  ) async {
    // 线路自带的头优先（UA 之类必须覆盖，否则接口不认）
    final merged = <String, String>{...headers, ...line.headers};

    final raw = line.apply(pageUrl);
    final first = await _fromOneUrl(dio, raw, merged, deadline);
    if (first != null) return first;

    final encoded = line.applyEncoded(pageUrl);
    if (encoded == raw) return null;
    return _fromOneUrl(dio, encoded, merged, deadline);
  }

  /// 请求一个已拼好的解析地址，并从响应里挖出媒体直链。
  ///
  /// 走 [_digUrl] 而不是只取一次 `url` 字段：解析接口返回的往往还是
  /// **网页**（ckplayer / jiexi 这类壳），只取一次就会把网页当播放地址。
  Future<String?> _fromOneUrl(
    Dio dio,
    String target,
    Map<String, String> headers,
    DateTime deadline,
  ) =>
      _digUrl(dio, target, headers, deadline, 0);

  /// 从 JSON 响应里取 `url` / `data.url` / `playUrl`
  String? _mediaFromJson(String body) {
    final text = body.trim();
    if (!text.startsWith('{') && !text.startsWith('[')) return null;
    try {
      final decoded = jsonDecode(text);
      final candidate = _deepUrl(decoded, 0);
      if (candidate == null) return null;
      final url = _decodeEscaped(candidate);
      if (MediaSniffer.isMediaUrl(url)) return url;
      // 解析接口有时给的是"另一个解析页"，也当成可用结果交给上层
      if (url.startsWith('http')) return url;
    } catch (_) {}
    return null;
  }

  String? _deepUrl(Object? node, int depth) {
    if (depth > 4 || node == null) return null;
    if (node is String) return null;
    if (node is List) {
      for (final e in node) {
        final r = _deepUrl(e, depth + 1);
        if (r != null) return r;
      }
      return null;
    }
    if (node is Map) {
      for (final key in const ['url', 'playUrl', 'play_url', 'src', 'link']) {
        final v = node[key];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
      for (final v in node.values) {
        final r = _deepUrl(v, depth + 1);
        if (r != null) return r;
      }
    }
    return null;
  }

  /// JSON 里常见 `https:\/\/a.b\/c.m3u8`，还原成正常地址
  String _decodeEscaped(String url) =>
      url.replaceAll(r'\/', '/').replaceAll(r'\u0026', '&').trim();

  /// 页面里的 iframe / `?url=` 目标
  String? _nestedTarget(String html) {
    final iframe = RegExp(
      r'''<iframe[^>]+src=["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(html);
    if (iframe != null) {
      final src = _decodeEscaped(iframe.group(1) ?? '');
      if (src.startsWith('http')) return src;
    }
    final param = RegExp(
      r'''(?:url|u|v|src)=([^&"'\s]+)''',
      caseSensitive: false,
    ).firstMatch(html);
    if (param != null) {
      var v = Uri.decodeComponent(_decodeEscaped(param.group(1) ?? ''));
      if (v.startsWith('http')) return v;
    }
    return null;
  }

  /// 候选里挑最优先的（m3u8 > mpd > mp4 > 其它）
  String? _pickBest(List<String> candidates) {
    if (candidates.isEmpty) return null;
    final ordered = [...candidates]
      ..sort((a, b) => MediaSniffer.score(a).compareTo(MediaSniffer.score(b)));
    return ordered.first;
  }

  Future<String?> _get(
    Dio dio,
    String url,
    Map<String, String> headers,
    DateTime deadline,
  ) async {
    final remaining = deadline.difference(DateTime.now());
    if (remaining.isNegative) return null;
    final timeout = remaining < _requestTimeout ? remaining : _requestTimeout;
    try {
      final resp = await dio.get<String>(
        url,
        options: Options(
          receiveTimeout: timeout,
          sendTimeout: timeout,
          headers: {
            'User-Agent':
                'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
                    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
                    'Mobile/15E148 Safari/604.1',
            ...headers,
          },
        ),
      );
      final data = resp.data;
      if (data == null) return null;
      return data;
    } catch (e) {
      AppLog.instance.log('[Resolve] 请求失败（继续下一条）: $url → $e');
      return null;
    }
  }
}
