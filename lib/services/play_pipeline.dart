// lib/services/play_pipeline.dart
//
// 统一播放判定（播放地址路由的**单一事实来源**）。
//
// 只有两条路：
//   ① 影视直链 → 交给 App 自己的原生播放器；
//   ② 其它 http(s) 网页 → 交给 App 自己的内嵌网页播放器（WebviewPlayerPage）。
//
// 不做任何地址提取：网页里的播放由网页自己完成。
library;

import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/play_route.dart';
import 'package:tvbox/services/play_url_sanitizer.dart';

/// 取址结果的内容形态。
enum PlayKind {
  /// 可直接交给原生播放器
  media,

  /// 网页地址 —— 交给内嵌网页播放器
  page,

  /// `novel://` 正文
  novel,

  /// `pics://` 图片列表
  pictures,
}

class PlayResolution {
  final String url;
  final PlayKind kind;
  final Map<String, String> headers;

  const PlayResolution({
    required this.url,
    required this.kind,
    this.headers = const {},
  });

  bool get isMedia => kind == PlayKind.media;
  bool get isPage => kind == PlayKind.page;
}

class PlayPipeline {
  PlayPipeline._();
  static final PlayPipeline instance = PlayPipeline._();

  /// 清洗并判定 [rawUrl] 该怎么播。
  ///
  /// [apiBase] 用于把相对播放地址按源站 origin 补全。
  PlayResolution resolve(
    String rawUrl, {
    Map<String, String>? headers,
    String? apiBase,
  }) {
    final h = <String, String>{...?headers};
    final raw = rawUrl.trim();
    if (raw.isEmpty) {
      return PlayResolution(url: raw, kind: PlayKind.page, headers: h);
    }

    // ① 非视频协议：漫画 / 小说（交给阅读器）
    final novel = parseNovelUrl(raw);
    if (novel != null && novel.content.trim().isNotEmpty) {
      return PlayResolution(url: raw, kind: PlayKind.novel, headers: h);
    }
    final pictures = parseImageListUrl(raw);
    if (pictures != null && pictures.isNotEmpty) {
      return PlayResolution(url: raw, kind: PlayKind.pictures, headers: h);
    }

    // ② 清洗 + 补全
    var candidate = sanitizePlayUrl(raw);
    candidate = absolutize(candidate, apiBase);

    // ③ 直链 → 原生播放器
    if (looksLikeDirectMedia(candidate)) {
      return PlayResolution(url: candidate, kind: PlayKind.media, headers: h);
    }
    // 音频直链同样交给原生播放器
    final lower = candidate.toLowerCase();
    for (final ext in kAudioExtensions) {
      if (lower.contains(ext)) {
        return PlayResolution(url: candidate, kind: PlayKind.media, headers: h);
      }
    }

    AppLog.instance.log('[PlayPipeline] 网页地址 → 内嵌网页播放器: $candidate');
    return PlayResolution(url: candidate, kind: PlayKind.page, headers: h);
  }

  /// 相对播放地址按源站点的 **origin** 补全（TVBox 既有约定）。
  static String absolutize(String raw, String? apiBase) {
    final s = raw.trim();
    if (s.isEmpty || isPlayableShape(s)) return s;
    final base = (apiBase ?? '').trim();
    if (base.isEmpty) return s;
    final bu = Uri.tryParse(base);
    if (bu == null || !bu.hasScheme) return s;
    try {
      final origin = '${bu.scheme}://${bu.authority}/';
      return Uri.parse(origin).resolve(s).toString();
    } catch (_) {
      return s;
    }
  }

  /// 是否"能交给播放器"的地址形态（有 scheme，含内容协议）。
  static bool isPlayableShape(String url) {
    final raw = url.trim();
    if (raw.isEmpty) return false;
    final lower = raw.toLowerCase();
    for (final p in kPlayablePrefixes) {
      if (lower.startsWith(p)) return true;
    }
    final u = Uri.tryParse(raw);
    return u != null && u.hasScheme;
  }

  static const List<String> kPlayablePrefixes = [
    'http://', 'https://', 'rtmp://', 'rtsp://', 'mms://',
    'x5://', 'novel://', 'pics://', 'mange://', 'manga://',
    'magnet:', 'ed2k://', 'thunder://', 'ftp://', 'file://',
  ];
}
