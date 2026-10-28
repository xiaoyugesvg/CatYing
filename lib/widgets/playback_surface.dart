import 'package:flutter/material.dart';

import 'package:tvbox/pages/play/webview_player_page.dart';
import 'package:tvbox/services/play_route.dart' show kAudioExtensions;
import 'package:tvbox/services/sniff_filter.dart';

/// 统一的「播放区兜底」判定与构造（P0-1 抽取，2026-10-28）。
///
/// ── 为什么需要它 ────────────────────────────────────────────────
/// 三个播放页原来**各写一份**「网页地址 → 内嵌 WebviewPlayerPage」的判定
/// 与构造，规则长期漂移：
///   · 影视详情页：`_isWebPageUrl` + `confirmedMediaUrl` 例外 + 音频直链排除；
///   · 短剧页 / 媒体库页：只判 `!SniffFilter.isDirectMedia`（漏了音频直链、
///     漏了"已确认媒体"例外）；
/// 结果就是同样的地址在三处得到不同处理（有的进 WebView 黑屏、有的丢 header）。
/// 这里集中成一份，保证三处**行为一致**。
///
/// ⚠️ 本类只统一「要不要走网页兜底」+「怎么构造兜底页」这两件事；
/// 各页的**原生播放 UI**（详情/媒体库是 `VideoPlayerWidget`，短剧是抖音式
/// `AppVideoView`）本就不同，不强行合并 —— 那是各页的产品形态，不是重复代码。
class PlaybackSurface {
  PlaybackSurface._();

  /// 该地址是否应走「网页兜底」（内嵌 WebView 播放 + 后台嗅探）。
  ///
  /// 规则（与详情页历史行为一致，推广到三处）：
  ///   · 非 http(s) 地址（如 `id`、`txvip://`）→ **不是**网页，交原生播放器
  ///     （由播放器报 unsupported URL，而不是塞进 WebView）；
  ///   · [confirmedMediaUrl] = 已用 Content-Type / 首字节确认是媒体的**无后缀**
  ///     地址（解析站常见的 `xxx.php?url=…`）→ 交给原生播放器，别塞 WebView
  ///     打开 m3u8 文本页（黑屏）；
  ///   · 命中影视直链后缀 → 原生播放器；
  ///   · 命中音频直链后缀 → 原生播放器（与 parse_service 音频白名单同源）；
  ///   · 其余 http(s) → 视为网页播放页（解析页 / player 页 / 网页端地址）。
  static bool needsWebFallback(String url, {String? confirmedMediaUrl}) {
    final trimmed = url.trim();
    final lower = trimmed.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return false;
    }
    if (confirmedMediaUrl != null &&
        confirmedMediaUrl.isNotEmpty &&
        trimmed == confirmedMediaUrl) {
      return false;
    }
    if (SniffFilter.isDirectMedia(trimmed)) return false;
    for (final ext in kAudioExtensions) {
      if (lower.contains(ext)) return false;
    }
    return true;
  }

  /// 构造统一的网页兜底播放器（内嵌 / 全屏、嗅探 / 解析入口、命中回写）。
  ///
  /// [onMediaFound] 命中直链后由调用方写回自己的播放地址（三处写法不同，
  /// 但都只是"把地址换成直链"，所以这里只透传回调，不替调用方决定怎么写）。
  static Widget webFallback({
    required String url,
    String? title,
    bool embedded = false,
    bool forceLandscape = true,
    VoidCallback? onSniff,
    VoidCallback? onSwitchParse,
    void Function(String url)? onMediaFound,
  }) {
    return WebviewPlayerPage(
      url: url,
      title: title,
      embedded: embedded,
      forceLandscape: forceLandscape,
      onSniff: onSniff,
      onSwitchParse: onSwitchParse,
      onMediaFound: onMediaFound,
    );
  }
}
