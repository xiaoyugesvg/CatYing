/// 播放器引擎类型 - 对应 Swift PlayerEngine
/// - avplayer：iOS 主内核（video_player / 系统 AVPlayer）
/// - mpv：备用内核（media_kit / libmpv），兼容桌面与部分流
///
/// ⚠️ 影视模块**不提供 WebView 内核**（2026-10-29 用户要求）：影视只播媒体
/// 直链，网页地址一律不内嵌播放。WebView 播放页（`WebviewPlayerPage`）仍被
/// RSS / 小程序 / 海阔等模块直接使用，与内核选择无关。

import 'dart:io';

/// 播放器引擎类型
enum PlayerEngine {
  /// AVPlayer 内核（video_player），iOS 默认主路径
  avplayer(0, 'AVPlayer播放器'),
  /// MPV 内核（media_kit + libmpv），保留备用
  mpv(1, 'MPV播放器'),
  /// KSPlayer 内核（FFmpeg + Metal），iOS 第四核心「FF」：
  /// AVPlayer 吃不下的格式（MKV/ASS/多音轨等）全兼容，并自带小窗
  ksplayer(3, 'KSPlayer播放器'),
  /// AetherEngine 内核（FFmpeg demux + VideoToolbox 解码），iOS 第五核心「AE」：
  /// 与 KSPlayer 并存（用户 2026-11-01 要求）。HDR / Dolby Vision / Dolby Atmos
  /// 原生支持，自带小窗。
  ///
  /// ⚠️ 两个 FF 内核各带一整套 FFmpeg（KSPlayer→FFmpegKit 6.x，
  /// AetherEngine→FFmpegBuild 8.1），同名 C 符号在链接期只能有一套生效。
  /// 真机验证前不要假设两个内核都能正常出画。
  aether(4, 'Aether播放器');

  final int value;
  final String title;

  const PlayerEngine(this.value, this.title);

  /// 旧版本把 `2` 存成「Webview 播放器」内核（影视模块已移除该内核）。
  /// 读到这个历史值要落到平台默认内核，否则会卡在一个不存在的内核上。
  static const int _kLegacyWebviewValue = 2;

  /// 平台默认内核：Apple 用 AVPlayer（与小窗共用同一 AVPlayer），
  /// 其它平台用 MPV。
  static PlayerEngine get defaultEngine =>
      (Platform.isIOS || Platform.isMacOS)
          ? PlayerEngine.avplayer
          : PlayerEngine.mpv;

  /// 从持久化值恢复播放器选项，并自动兜底到可用引擎
  static PlayerEngine fromStoredValue(int rawValue) {
    // 兼容旧值：0 曾表示 mpv，现在默认 avplayer
    if (rawValue == _kLegacyWebviewValue) return defaultEngine;
    final engine =
        PlayerEngine.values.where((e) => e.value == rawValue).firstOrNull;
    if (engine == null) return defaultEngine;
    return engine;
  }

  /// 实际可供用户选择的播放器列表
  ///
  /// - Apple（iOS / macOS）：avplayer 为默认主内核（与系统小窗共用同一 AVPlayer），
  ///   ksplayer（KSPlayer/FFmpeg）为 iOS 备选内核（MKV 等全格式 + 自带小窗），
  ///   aether（AetherEngine/FFmpeg）为 iOS 第五内核（HDR/DV/Atmos + 自带小窗），
  ///   mpv（media_kit_libs_ios_video）为备用内核（支持 flv/ts/rtmp 等 AVPlayer
  ///   不支持的直播格式；默认不启用，用户在设置里切换）。
  /// - Android：mpv（无 AVPlayer）。
  /// - 桌面（Windows / Linux）：mpv（window_manager 小窗路径）。
  static List<PlayerEngine> get availableEngines {
    if (Platform.isIOS) {
      return const [
        PlayerEngine.avplayer,
        PlayerEngine.ksplayer,
        PlayerEngine.aether,
        PlayerEngine.mpv,
      ];
    }
    if (Platform.isMacOS) {
      return const [PlayerEngine.avplayer, PlayerEngine.mpv];
    }
    if (Platform.isAndroid) {
      return const [PlayerEngine.mpv];
    }
    return const [PlayerEngine.mpv];
  }
}

/// 视频解码模式（仅 mpv 内核生效）
enum VideoDecodeMode {
  auto(0, '自动'),
  hardware(1, '硬解码'),
  software(2, '软解码');

  final int value;
  final String title;

  const VideoDecodeMode(this.value, this.title);

  static VideoDecodeMode fromStoredValue(int rawValue) {
    return VideoDecodeMode.values.where((e) => e.value == rawValue).firstOrNull ??
        VideoDecodeMode.auto;
  }

  String? get mpvHardwareDecodeOption {
    switch (this) {
      case VideoDecodeMode.auto:
        return 'auto';
      case VideoDecodeMode.hardware:
        return 'auto-safe';
      case VideoDecodeMode.software:
        return 'no';
    }
  }
}

/// MPV 缓冲策略（仅 mpv 内核生效）
enum VLCBufferMode {
  lowLatency(0, '低延迟'),
  balanced(1, '均衡'),
  smooth(2, '流畅优先');

  final int value;
  final String title;

  const VLCBufferMode(this.value, this.title);

  static VLCBufferMode get defaultMode => VLCBufferMode.balanced;

  static VLCBufferMode fromStoredValue(int rawValue) {
    return VLCBufferMode.values.where((e) => e.value == rawValue).firstOrNull ??
        defaultMode;
  }

  bool get enableFrameDrop => this == VLCBufferMode.lowLatency;

  ({int network, int live, int file}) cacheConfig({required bool isLive}) {
    switch (this) {
      case VLCBufferMode.lowLatency:
        if (isLive) {
          return (network: 1200, live: 1200, file: 1600);
        }
        return (network: 1800, live: 1600, file: 2400);
      case VLCBufferMode.balanced:
        if (isLive) {
          return (network: 2600, live: 2600, file: 3200);
        }
        return (network: 6000, live: 5000, file: 6400);
      case VLCBufferMode.smooth:
        if (isLive) {
          return (network: 4200, live: 4200, file: 5200);
        }
        return (network: 8000, live: 6800, file: 8400);
    }
  }
}
