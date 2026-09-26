import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// 直播 AVPlayer 播放器 - 对应 tvbox-Swift LiveView 的 system(AVPlayer) 内核
///
/// 移植背景：mpv(media_kit) 对部分 HLS/TS 直播流会出现「有声音无画面」的黑屏，
/// 而同一路流交给系统 AVPlayer 能正常解码播放（画中画即走 AVPlayer 通道）。
/// tvbox-Swift 直播默认内核就是 system(AVPlayer)，这里忠实移植：
/// 直播页在 iOS 上使用 video_player(AVPlayer) 播放；播放失败通过 [onError]
/// 上报上层，由直播页的失败自动切线逻辑切换到下一条线路。
class LiveAVPlayer extends StatefulWidget {
  /// 播放地址（m3u8 / ts / mp4 等，video_player 支持的范围）
  final String url;

  /// 频道名（透传，预留）
  final String title;

  /// 播放失败回调（初始化失败或播放中出错），上层用于自动切线
  final VoidCallback? onError;

  /// 播放状态变化回调（true=正在播放）
  final ValueChanged<bool>? onPlayingChanged;

  /// 点击画面回调（例如唤醒频道信息）
  final VoidCallback? onTap;

  const LiveAVPlayer({
    super.key,
    required this.url,
    this.title = '',
    this.onError,
    this.onPlayingChanged,
    this.onTap,
  });

  @override
  State<LiveAVPlayer> createState() => _LiveAVPlayerState();
}

class _LiveAVPlayerState extends State<LiveAVPlayer> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _createController(widget.url);
  }

  @override
  void didUpdateWidget(LiveAVPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切台 / 切换线路时 url 变化，重建播放器
    if (oldWidget.url != widget.url) {
      _createController(widget.url);
    }
  }

  Future<void> _createController(String url) async {
    _disposeController();
    _failed = false;
    setState(() => _initialized = false);
    if (url.isEmpty) {
      return;
    }

    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    _controller = controller;

    // 播放中出错监听（解码失败 / 网络中断等）
    controller.addListener(() {
      if (!mounted || _controller != controller) return;
      if (controller.value.hasError && !_failed) {
        _failed = true;
        debugPrint('[LiveAVPlayer] playback error: $url');
        widget.onError?.call();
      }
    });

    try {
      await controller.initialize();
      if (!mounted || _controller != controller) return;
      setState(() => _initialized = true);
      // 直播实时性优先：循环播放，避免直播流到达片尾后停住
      controller.setLooping(true);
      await controller.play();
      if (mounted && _controller == controller) {
        widget.onPlayingChanged?.call(true);
      }
    } catch (e) {
      debugPrint('[LiveAVPlayer] init failed: $url, error: $e');
      if (!_failed) {
        _failed = true;
        widget.onError?.call();
      }
    }
  }

  void _disposeController() {
    final controller = _controller;
    _controller = null;
    // VideoPlayerController.dispose() 会自行移除监听，无需手动 removeListener
    controller?.dispose();
  }

  @override
  void dispose() {
    _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (!_initialized || controller == null || !controller.value.isInitialized) {
      // 加载中 / 失败重连中：纯黑底 + 轻量加载指示，避免白屏闪烁
      return Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Colors.white.withValues(alpha: 0.6),
          ),
        ),
      );
    }

    final aspectRatio = controller.value.aspectRatio;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: Center(
        child: AspectRatio(
          aspectRatio: aspectRatio > 0 ? aspectRatio : 16 / 9,
          child: VideoPlayer(controller),
        ),
      ),
    );
  }
}
