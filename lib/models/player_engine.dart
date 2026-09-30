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
  webview(2, 'Webview播放器');

  final int value;
  final String title;

  const PlayerEngine(this.value, this.title);

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
  /// 按「本仓库真正支持的目标平台」过滤，避免 iOS 上出现选了就不可用的内核：
  /// - Apple（iOS / macOS）：avplayer 为默认主内核（与系统小窗共用同一 AVPlayer），
  ///   webview 用于网页播放页；mpv 在本仓库无 iOS/macOS 原生库，不列出。
  /// - Android：mpv + webview（无 AVPlayer）。
  /// - 桌面（Windows / Linux）：mpv（window_manager 小窗路径）。
  static List<PlayerEngine> get availableEngines {
    if (Platform.isIOS || Platform.isMacOS) {
      return const [PlayerEngine.avplayer, PlayerEngine.webview];
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
