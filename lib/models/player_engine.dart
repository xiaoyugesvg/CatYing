/// 播放器引擎类型 - 对应 Swift PlayerEngine
/// - avplayer：iOS 主内核（video_player / 系统 AVPlayer）
/// - mpv：备用内核（media_kit / libmpv），兼容桌面与部分流
/// - webview：网页播放页（WKWebView）

import 'dart:io';

/// 播放器引擎类型
enum PlayerEngine {
  /// AVPlayer 内核（video_player），iOS 默认主路径
  avplayer(0, 'AVPlayer播放器'),
  /// MPV 内核（media_kit + libmpv），保留备用
  mpv(1, 'MPV播放器'),
  /// Webview 内核（webview_flutter + WKWebView），用于网页播放页面
  webview(2, 'Webview播放器'),
  /// KSPlayer 内核（FFmpeg + Metal），iOS 第四核心「FF」：
  /// AVPlayer 吃不下的格式（MKV/ASS/多音轨等）全兼容，并自带小窗
  ksplayer(3, 'KSPlayer播放器'),
  /// AetherEngine 内核（FFmpeg 解复用 + VideoToolbox/dav1d 解码 + Metal），
  /// iOS 第五核心「AE」：vendored 本地包 ios/AetherEngine。
  /// 仅 iOS 17+ 开放（见 [aetherSupported]），第一版无画中画
  aether(4, 'Aether播放器');

  final int value;
  final String title;

  const PlayerEngine(this.value, this.title);

  /// Aether（第五核心）是否受当前系统支持：仅 iOS 17+。
  ///
  /// vendored 包的平台声明虽降到 16（构建需要），但 iOS 16 未实测过，
  /// 运行时收敛到 17+ 更稳：16 的机器上看不到该核心选项，
  /// 历史偏好里存过 AE 的低版本设备会在 PlayerPrefs.load 时回退 AVPlayer。
  static bool get aetherSupported {
    if (!Platform.isIOS) return false;
    // Platform.version 形如 "17.5.1 (Darwin ...)"，取首个主版本段
    final major = int.tryParse(Platform.version.split('.').first) ?? 0;
    return major >= 17;
  }

  /// 从持久化值恢复播放器选项，并自动兜底到可用引擎
  static PlayerEngine fromStoredValue(int rawValue) {
    // 兼容旧值：0 曾表示 mpv，现在默认 avplayer
    final engine =
        PlayerEngine.values.where((e) => e.value == rawValue).firstOrNull;
    if (engine == null) return PlayerEngine.avplayer;
    return engine;
  }

  /// 实际可供用户选择的播放器列表
  ///
  /// - Apple（iOS / macOS）：avplayer 为默认主内核（与系统小窗共用同一 AVPlayer），
  ///   ksplayer（KSPlayer/FFmpeg）为 iOS 备选内核（MKV 等全格式 + 自带小窗），
  ///   mpv（media_kit_libs_ios_video）为备用内核（支持 flv/ts/rtmp 等 AVPlayer
  ///   不支持的直播格式；默认不启用，用户在设置里切换），
  ///   webview 用于网页播放页。
  /// - Android：mpv + webview（无 AVPlayer）。
  /// - 桌面（Windows / Linux）：mpv（window_manager 小窗路径）。
  static List<PlayerEngine> get availableEngines {
    if (Platform.isIOS) {
      // 第五核心「AE」（AetherEngine）仅 iOS 17+ 开放，列表动态组装
      if (aetherSupported) {
        return const [
          PlayerEngine.avplayer,
          PlayerEngine.ksplayer,
          PlayerEngine.aether,
          PlayerEngine.mpv,
          PlayerEngine.webview,
        ];
      }
      return const [
        PlayerEngine.avplayer,
        PlayerEngine.ksplayer,
        PlayerEngine.mpv,
        PlayerEngine.webview,
      ];
    }
    if (Platform.isMacOS) {
      return const [PlayerEngine.avplayer, PlayerEngine.mpv, PlayerEngine.webview];
    }
    if (Platform.isAndroid) {
      return const [PlayerEngine.mpv, PlayerEngine.webview];
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
