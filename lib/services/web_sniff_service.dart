// lib/services/web_sniff_service.dart
//
// 网络层嗅探 —— V1 精简版（对齐 huoyi：只取入口页扫媒体直链）。
//
// 与旧版的差异（2026-10-29 重构）：
//   · 不再 BFS 递归 iframe（跨域 iframe 抓不到，交给 WebView 主 frame hook）；
//   · 不再 WebView 渲染兜底（SPA / CF 挑战页不处理）；
//   · 不再 MIME 探测（looksLikeMediaByMime 降级为后缀判定，不发网络请求）。
//
// 保留：入口页 HTML 抓取（2MB 上限）、媒体直链正则扫描、`\/` 反转义、
//       rank 取最优、SniffFilter 过滤。

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:tvbox/common/constants.dart';
import 'package:tvbox/reading/source/global_proxy.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/sniff_filter.dart';

/// 一次嗅探会话的候选池（保留：去重 + rank，调用方也可复用）。
class SniffSession {
  /// 已收下的候选（按出现顺序，已去重）。
  final List<String> candidates = [];

  /// 目前最优候选；无命中为 null。
  String? best;

  /// 最优候选的 rank（越小越好）。
  int bestRank = 1 << 20;

  /// 收一条候选；返回 true 表示"已经足够好，可以停止扫描"。
  bool offer(String raw) {
    final u = raw.trim();
    if (u.isEmpty) return false;
    if (!SniffFilter.acceptSniffUrl(u)) return false;
    if (!candidates.contains(u)) candidates.add(u);
    final r = SniffFilter.candidateRank(u);
    if (r < bestRank) {
      best = u;
      bestRank = r;
    }
    return bestRank <= 1;
  }

  /// 候选按"整片可能性"排序（调用方可依次尝试）。
  List<String> get ranked => SniffFilter.rankCandidates(candidates);

  bool get isEmpty => candidates.isEmpty;
}

class WebSniffService {
  WebSniffService._();
  static final WebSniffService instance = WebSniffService._();

  static const Duration _timeout = Duration(seconds: 8);

  /// 单页最多读多少字节（防止误把大文件当网页拉爆内存）。
  static const int _maxPageBytes = 2 * 1024 * 1024;

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

  /// 从 [pageUrl] 取入口页 HTML，扫出最可播的媒体直链；找不到返回 null。
  ///
  /// [referer] 一般传页面地址自身（部分站点校验 Referer 才给页面）。
  Future<String?> findMediaUrl(String pageUrl, {String? referer}) async {
    final start = pageUrl.trim();
    if (!_isHttp(start)) return null;
    // 入口本身就是媒体直链：直接返回，绝不当网页去 GET
    //（m3u8 正文里全是 `.ts` 切片，扫出来只会拿到其中一小段）
    if (SniffFilter.isDirectMedia(start)) return start;

    final html = await _get(start, referer: referer);
    if (html == null || html.isEmpty) return null;

    final hits = _findMediaUrls(html);
    if (hits.isEmpty) return null;
    return SniffFilter.rankCandidates(hits).first;
  }

  /// 地址是否是媒体。V1：纯后缀判定，不再发网络探测
  /// （保留方法签名，供 PlayPipeline / WebView 页调用）。
  Future<bool> looksLikeMediaByMime(String url, {String? referer}) async {
    return SniffFilter.isDirectMedia(url);
  }

  /// 候选排序（UI 的 `_mimeFallback` 复用）：路径带播放语义的先探。
  static const List<String> _probeHintWords = [
    'm3u8', 'playlist', 'master', 'index', 'hls', 'live',
    'stream', 'play', 'video', 'media', 'vod',
  ];

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
    ]..sort((a, b) {
        final byScore = b.$1.compareTo(a.$1); // 分高在前
        return byScore != 0 ? byScore : a.$2.compareTo(b.$2);
      });
    return [for (final e in indexed) e.$3];
  }

  // ============================================================
  // 内部
  // ============================================================

  /// 取一个网页的 HTML（**带上限**，见 [_maxPageBytes]）。
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
      final declared = int.tryParse(resp.headers.value('content-length') ?? '');
      if (declared != null && declared > _maxPageBytes) {
        AppLog.instance.log(
            '[WebSniff] 页面过大（$declared B > $_maxPageBytes），跳过: $url');
        return null;
      }
      final head = await _readHead(body!.stream, _maxPageBytes);
      // allowMalformed：GBK 等非 UTF-8 页面会解出乱码，但不会抛异常
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
  /// ⚠️ 必须先做一次 `\/` → `/` 的**反转义**：播放页里最关键的地址几乎都
  /// 藏在 `<script>` 的 JSON 字符串里，写作 `"https:\/\/cdn\/x\/index.m3u8"`。
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
  static String _unescapeSlashes(String text) =>
      text.contains('\\/') ? text.replaceAll('\\/', '/') : text;

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

  static bool _isHttp(String u) =>
      u.startsWith('http://') || u.startsWith('https://');

  // ============================================================
  // 单测钩子（纯解析部分不依赖网络）
  // ============================================================

  /// 仅供单测：扫文本里的媒体直链
  @visibleForTesting
  static List<String> debugFindMediaUrls(String text) => _findMediaUrls(text);
}
