/// 播放器引擎类型 - 对应 Swift PlayerEngine
/// iOS 上 mpv(media_kit) 对部分 HLS/TS 流存在黑屏/转圈渲染问题,
/// 而系统 AVPlayer(video_player) 可正常解码, 因此提供双内核切换。

/// 播放器引擎类型
enum PlayerEngine {
  /// MPV 内核（基于 media_kit + libmpv），功能最全（倍速/硬解/画中画）
  mpv(0, 'MPV播放器'),
  /// AVPlayer 内核（基于 video_player，iOS 系统播放器），
  /// 对 HLS/TS 直播与部分点播流兼容性最好，画面稳定不黑屏
  avplayer(1, 'AVPlayer播放器');

  final int value;
  final String title;

  const PlayerEngine(this.value, this.title);

  /// 从持久化值恢复播放器选项，并自动兜底到可用引擎
  static PlayerEngine fromStoredValue(int rawValue) {
    final engine = PlayerEngine.values.where((e) => e.value == rawValue).firstOrNull;
    if (engine == null) {
      return PlayerEngine.mpv;
    }
    return engine;
  }

  /// 实际可供用户选择的播放器列表
  static List<PlayerEngine> get availableEngines => PlayerEngine.values;
}

/// 视频解码模式
enum VideoDecodeMode {
  /// 自动策略，优先硬解，失败时用户可切换
  auto(0, '自动'),
  /// 强制硬解
  hardware(1, '硬解码'),
  /// 强制软解
  software(2, '软解码');

  final int value;
  final String title;

  const VideoDecodeMode(this.value, this.title);

  static VideoDecodeMode fromStoredValue(int rawValue) {
    return VideoDecodeMode.values
            .where((e) => e.value == rawValue)
            .firstOrNull ??
        VideoDecodeMode.auto;
  }

  /// MPV 媒体 hwdec 选项
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

/// MPV 缓冲策略
enum VLCBufferMode {
  /// 低延迟优先，适合直播但容错较低
  lowLatency(0, '低延迟'),
  /// 兼顾延迟与稳定性，作为默认策略
  balanced(1, '均衡'),
  /// 稳定流畅优先，允许更高缓冲
  smooth(2, '流畅优先');

  final int value;
  final String title;

  const VLCBufferMode(this.value, this.title);

  static VLCBufferMode get defaultMode => VLCBufferMode.balanced;

  static VLCBufferMode fromStoredValue(int rawValue) {
    return VLCBufferMode.values
            .where((e) => e.value == rawValue)
            .firstOrNull ??
        defaultMode;
  }

  bool get enableFrameDrop => this == VLCBufferMode.lowLatency;

  /// 根据直播/点播场景输出三类缓存值（单位毫秒）
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
