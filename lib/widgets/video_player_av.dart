import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:video_player/video_player.dart';
import '../common/theme.dart';
import 'video_player_pip.dart';

/// AVPlayer 内核播放器（基于 video_player，iOS 系统播放器）
///
/// 解决 mpv(media_kit) 对部分 HLS/TS 流黑屏/转圈问题：
/// 同一路流交给系统 AVPlayer 能正常解码播放。
/// 与 VideoPlayerWidget(mpv) 保持同接口，详情页按设置的内核切换渲染。
///
/// 功能：
/// - 自动播放 + 续播位置
/// - 点击唤出/隐藏控制栏（顶栏：返回+标题；底栏：播放/暂停+进度+时间+选集+倍速+全屏）
/// - 倍速切换（0.5x-2.0x）
/// - 选集（上一集/下一集/选集网格）
/// - iOS 画中画（复用 PipManager 通道：暂停本 AVPlayer → 系统 AVPlayer 接管）
class AVPlayerPlayer extends StatefulWidget {
  final String url;
  final Map<String, String>? headers;
  final double? resumeSeconds;
  final String? videoTitle;
  final String? currentEpisodeName;
  final List<String> episodeNames;
  final int selectedEpisodeIndex;
  final bool canPlayNext;
  final bool canPlayPrevious;
  final bool isPipMode;
  final VoidCallback? onPlaying;
  final ValueChanged<Duration>? onPositionChanged;
  final VoidCallback? onEnded;
  final VoidCallback? onError;
  final ValueChanged<bool>? onFullScreenChanged;
  final VoidCallback? onPlayNext;
  final VoidCallback? onPlayPrevious;
  final ValueChanged<int>? onSelectEpisode;
  final VoidCallback? onBack;

  const AVPlayerPlayer({
    super.key,
    required this.url,
    this.headers,
    this.resumeSeconds,
    this.videoTitle,
    this.currentEpisodeName,
    this.episodeNames = const [],
    this.selectedEpisodeIndex = 0,
    this.canPlayNext = false,
    this.canPlayPrevious = false,
    this.isPipMode = false,
    this.onPlaying,
    this.onPositionChanged,
    this.onEnded,
    this.onError,
    this.onFullScreenChanged,
    this.onPlayNext,
    this.onPlayPrevious,
    this.onSelectEpisode,
    this.onBack,
  });

  @override
  State<AVPlayerPlayer> createState() => _AVPlayerPlayerState();
}

class _AVPlayerPlayerState extends State<AVPlayerPlayer> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _failed = false;
  bool _controlsVisible = true;
  Timer? _hideControlsTimer;
  double _lastSpeed = 1.0;
  bool _isFullscreen = false;
  bool _seeking = false;

  // ---- 进度条拖动状态 ----
  double _dragValue = 0;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _createController(widget.url);
  }

  @override
  void didUpdateWidget(AVPlayerPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _createController(widget.url);
    }
  }

  Future<void> _createController(String url) async {
    _disposeController();
    _failed = false;
    _initialized = false;
    _lastSpeed = 1.0;
    _isFullscreen = false;
    if (mounted) setState(() {});

    if (url.isEmpty) return;

    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: widget.headers ?? const {},
      );
      _controller = controller;

      controller.addListener(_onControllerUpdate);

      await controller.initialize();
      if (!mounted || _controller != controller) return;

      // 续播位置
      final resume = widget.resumeSeconds ?? 0;
      if (resume > 0 &&
          resume < (controller.value.duration.inSeconds - 5)) {
        await controller.seekTo(Duration(seconds: resume.toInt()));
      }

      await controller.setLooping(false);
      setState(() => _initialized = true);
      await controller.play();
      if (mounted && _controller == controller) {
        widget.onPlaying?.call();
      }
    } catch (e) {
      debugPrint('[AVPlayerPlayer] init failed: $url, $e');
      if (!_failed) {
        _failed = true;
        widget.onError?.call();
      }
    }
  }

  void _onControllerUpdate() {
    final controller = _controller;
    if (controller == null || !mounted) return;

    if (controller.value.hasError && !_failed) {
      _failed = true;
      debugPrint('[AVPlayerPlayer] playback error: ${controller.value.errorDescription}');
      widget.onError?.call();
      return;
    }

    if (_initialized && !_seeking) {
      widget.onPositionChanged?.call(controller.value.position);
    }

    // 播放结束 → 下一集
    if (controller.value.isInitialized &&
        controller.value.duration > Duration.zero &&
        controller.value.position >= controller.value.duration &&
        !controller.value.isPlaying &&
        _initialized) {
      widget.onEnded?.call();
    }

    if (mounted) setState(() {});
  }

  void _disposeController() {
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      controller.removeListener(_onControllerUpdate);
      controller.dispose();
    }
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _disposeController();
    super.dispose();
  }

  // ---------------- 控制逻辑 ----------------

  void _togglePlay() {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }
    _kickControls();
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    _kickControls();
  }

  void _kickControls() {
    _hideControlsTimer?.cancel();
    if (!_controlsVisible) return;
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  Future<void> _seekTo(double fraction) async {
    final controller = _controller;
    if (controller == null) return;
    final duration = controller.value.duration;
    if (duration <= Duration.zero) return;
    final target = Duration(
      milliseconds: (duration.inMilliseconds * fraction).round(),
    );
    await controller.seekTo(target);
    if (mounted) setState(() {});
  }

  Future<void> _setSpeed(double speed) async {
    _lastSpeed = speed;
    await _controller?.setPlaybackSpeed(speed);
    _kickControls();
  }

  Future<void> _toggleFullscreen() async {
    final next = !_isFullscreen;
    _isFullscreen = next;
    widget.onFullScreenChanged?.call(next);
    _kickControls();
  }

  Future<void> _enterPip() async {
    // iOS：复用 PipManager 系统画中画通道
    if (Platform.isIOS) {
      final controller = _controller;
      if (controller == null) return;
      if (VideoPlayerPip.instance.isIosActive) {
        await VideoPlayerPip.instance.exitIos();
        await controller.play();
        return;
      }
      final supported = await VideoPlayerPip.instance.isIosPipSupported();
      if (!supported) return;
      final position = controller.value.position;
      // 暂停本播放器释放 audio session，AVPlayer 无缝接管
      await controller.pause();
      final entered = await VideoPlayerPip.instance.enterIos(
        url: widget.url,
        headers: widget.headers,
        position: position,
        onStarted: () {},
        onStopped: () {
          if (!mounted) return;
          final resume = VideoPlayerPip.instance.iosLastPosition;
          if (resume > Duration.zero) {
            _controller?.seekTo(resume);
          }
          _controller?.play();
        },
      );
      if (!entered) {
        await controller.play();
      }
      return;
    }
    _toggleFullscreen();
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (!_initialized || controller == null || !controller.value.isInitialized) {
      // 加载中：纯黑底 + 轻量加载指示
      return Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: const SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: Colors.white70,
          ),
        ),
      );
    }

    final aspectRatio = controller.value.aspectRatio;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleControls,
      child: Stack(
        children: [
          // 视频画面
          Center(
            child: AspectRatio(
              aspectRatio: aspectRatio > 0 ? aspectRatio : 16 / 9,
              child: VideoPlayer(controller),
            ),
          ),
          // 顶部渐变 + 控制栏
          if (_controlsVisible) ...[
            _buildTopGradient(),
            _buildBottomControls(),
          ],
        ],
      ),
    );
  }

  Widget _buildTopGradient() {
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 10, 8, 24),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            // 返回
            _iconBtn(Icons.arrow_back_ios_new, () {
              if (widget.isPipMode && VideoPlayerPip.instance.isActive) {
                VideoPlayerPip.instance.exit();
                return;
              }
              widget.onBack?.call();
            }),
            const SizedBox(width: 8),
            // 标题（小字号，避免过大占空间）
            Expanded(
              child: Text(
                widget.videoTitle ?? '',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // 画中画
            if (Platform.isIOS)
              _iconBtn(Icons.picture_in_picture_alt, _enterPip),
            if (widget.isPipMode)
              _iconBtn(Icons.drag_handle, _toggleControls),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 24, 8, 6),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Colors.black87, Colors.transparent],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 进度条 + 时间
            _buildProgressRow(),
            const SizedBox(height: 8),
            // 功能按钮行
            Row(
              children: [
                // 上一集
                if (widget.canPlayPrevious)
                  _iconBtn(Icons.skip_previous, () {
                    _kickControls();
                    widget.onPlayPrevious?.call();
                  }),
                // 播放/暂停
                _iconBtn(
                  (_controller?.value.isPlaying ?? false)
                      ? Icons.pause
                      : Icons.play_arrow,
                  _togglePlay,
                ),
                // 下一集
                if (widget.canPlayNext)
                  _iconBtn(Icons.skip_next, () {
                    _kickControls();
                    widget.onPlayNext?.call();
                  }),
                const Spacer(),
                // 选集
                if (widget.episodeNames.isNotEmpty)
                  _iconBtn(Icons.list_alt, _showEpisodePicker),
                // 倍速
                _iconBtn(Icons.speed, _showSpeedPicker),
                // 全屏
                _iconBtn(
                  _isFullscreen
                      ? Icons.fullscreen_exit
                      : Icons.fullscreen,
                  _toggleFullscreen,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressRow() {
    final controller = _controller;
    final position = controller?.value.position ?? Duration.zero;
    final duration = controller?.value.duration ?? Duration.zero;
    final maxMs = duration.inMilliseconds.toDouble();
    final curMs = _isDragging
        ? _dragValue * maxMs
        : position.inMilliseconds.toDouble();
    final fraction = maxMs > 0 ? (curMs / maxMs).clamp(0.0, 1.0) : 0.0;

    return Row(
      children: [
        Text(
          _fmt(curMs > 0 ? Duration(milliseconds: curMs.round()) : position),
          style: const TextStyle(color: Colors.white70, fontSize: 11),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) {
                  final width = constraints.maxWidth;
                  if (width <= 0) return;
                  _seekTo((d.localPosition.dx / width).clamp(0.0, 1.0));
                },
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 2.5,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: AppTheme.accentColor,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: fraction,
                    onChangeStart: (v) {
                      _isDragging = true;
                      _dragValue = v;
                    },
                    onChanged: (v) {
                      setState(() => _dragValue = v);
                    },
                    onChangeEnd: (v) {
                      _isDragging = false;
                      _seekTo(v);
                      _kickControls();
                    },
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 8),
        Text(
          _fmt(duration),
          style: const TextStyle(color: Colors.white70, fontSize: 11),
        ),
      ],
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Widget _iconBtn(IconData icon, VoidCallback? onTap) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, color: Colors.white, size: 22),
      iconSize: 22,
      padding: const EdgeInsets.all(8),
      constraints: const BoxConstraints(minWidth: 44, minHeight: 38),
    );
  }

  // ---------------- 弹层 ----------------

  /// 选集弹窗（网格）
  void _showEpisodePicker() {
    _kickControls();
    final names = widget.episodeNames;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1E22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Row(
                  children: [
                    const Text(
                      '选集',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '共 ${names.length} 集',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.close,
                          color: Colors.white54, size: 18),
                      onPressed: () => Navigator.pop(ctx),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: GridView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1.6,
                  ),
                  itemCount: names.length,
                  itemBuilder: (ctx, index) {
                    final selected = index == widget.selectedEpisodeIndex;
                    return GestureDetector(
                      onTap: () {
                        Navigator.pop(ctx);
                        widget.onSelectEpisode?.call(index);
                      },
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: selected
                              ? AppTheme.accentColor.withValues(alpha: 0.25)
                              : Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: selected
                                ? AppTheme.accentColor
                                : Colors.transparent,
                            width: 1.2,
                          ),
                        ),
                        child: Text(
                          names[index],
                          style: TextStyle(
                            color: selected
                                ? AppTheme.accentColor
                                : Colors.white70,
                            fontSize: 11,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 倍速弹窗
  void _showSpeedPicker() {
    _kickControls();
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1C1E22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  '播放速度',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                children: speeds.map((s) {
                  final selected = (_lastSpeed - s).abs() < 0.01;
                  return GestureDetector(
                    onTap: () {
                      Navigator.pop(ctx);
                      _setSpeed(s);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 8),
                      decoration: BoxDecoration(
                        color: selected
                            ? AppTheme.accentColor.withValues(alpha: 0.25)
                            : Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: selected
                              ? AppTheme.accentColor
                              : Colors.transparent,
                        ),
                      ),
                      child: Text(
                        '${s}x',
                        style: TextStyle(
                          color: selected
                              ? AppTheme.accentColor
                              : Colors.white70,
                          fontSize: 13,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        );
      },
    );
  }
}
