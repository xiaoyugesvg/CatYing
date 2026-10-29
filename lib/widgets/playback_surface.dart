import 'package:flutter/material.dart';

import 'package:tvbox/pages/play/webview_player_page.dart';
import 'package:tvbox/services/play_route.dart'
    show kAudioExtensions, looksLikeDirectMedia;

/// 统一的「网页地址」判定与网页播放页构造。
///
/// ── 两件事，别混用 ──────────────────────────────────────────────
/// · [needsWebFallback]：这个地址是不是**网页**（而不是媒体直链）。
///   影视模块（详情 / 短剧 / 媒体库）拿它做**负向判定** —— 是网页就拒绝播放
///   （2026-10-29 用户要求：影视模块不内嵌 WebView）。
/// · [webFallback]：构造全屏网页播放页。只有 RSS / 小程序 / 海阔等模块会用它。
///
/// 判定规则（三处播放页统一口径）：
///   · 非 http(s) 地址（如 `id`、`txvip://`）→ **不是**网页（交原生播放器报错，
///     而不是塞进 WebView）；
///   · 命中影视直链后缀 → 不是网页；
///   · 命中音频直链后缀 → 不是网页；
///   · 其余 http(s) → 视为网页播放页（player 页 / 网页端地址）。
class PlaybackSurface {
  PlaybackSurface._();

  /// 该地址是不是「网页」（而非媒体直链）。
  static bool needsWebFallback(String url) {
    final trimmed = url.trim();
    final lower = trimmed.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return false;
    }
    if (looksLikeDirectMedia(trimmed)) return false;
    for (final ext in kAudioExtensions) {
      if (lower.contains(ext)) return false;
    }
    return true;
  }

  /// 构造网页播放页（全屏独立页）。
  static Widget webFallback({
    required String url,
    String? title,
    bool forceLandscape = true,
  }) {
    return WebviewPlayerPage(
      url: url,
      title: title,
      forceLandscape: forceLandscape,
    );
  }
}
