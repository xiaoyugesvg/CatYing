// lib/services/play_pipeline.dart
//
// 统一播放判定（播放地址路由的**单一事实来源**）。
//
// 判定结果三种：
//   ① 媒体直链 → 交给 App 自己的原生播放器；
//   ② 网页地址 → `PlayKind.page`。**影视模块拿到 page 就拒绝播放**
//      （2026-10-29 用户要求：影视不内嵌 WebView）；小程序等模块可以自行
//      决定怎么用（例如交给网页播放页）。
//   ③ 漫画 / 小说协议 → 交给对应的简易阅读器。
//
// 不做任何地址提取：网页里的播放由网页自己完成。
library;

import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/play_route.dart';
import 'package:tvbox/services/play_url_sanitizer.dart';

/// 影视模块拒绝网页地址时的统一文案。
///
/// 影视模块（详情页 / 短剧 / 媒体库）只播媒体直链，**不允许**把网页地址
/// 内嵌进 WebView 播放（2026-10-29 用户要求）。其它模块（RSS / 小程序 /
/// 海阔 / 阅读 / 音乐）不受影响，仍可打开网页播放页。
const String kMovieWebUrlRejected =
    '这个地址是网页而不是视频直链，影视模块不支持网页播放，请切换线路或换源';

/// 取址结果的内容形态。
enum PlayKind {
  /// 可直接交给原生播放器
  media,

  /// 网页地址 —— 影视模块会拒绝播放；其它模块可自行处理
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

    AppLog.instance.log('[PlayPipeline] 判定为网页地址: $candidate');
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
