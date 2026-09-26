import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' hide Video;
import '../../common/theme.dart';
import '../../common/constants.dart';
import '../../services/player_fullscreen_controller.dart';
import '../../widgets/video_player_pip.dart';
import '../../widgets/window_fullscreen.dart';
import '../../widgets/glass.dart';
import '../../services/app_log.dart';
import '../../models/live_models.dart';
import '../../models/movie.dart';

/// 通用视频播放器（详情页 / 直播页共用）
///
/// 播放核心：media_kit（libmpv）
/// - 详情页点播：media_kit 渲染到 Flutter 纹理
/// - 直播：media_kit 渲染到 Flutter 纹理
///
/// 画中画：iOS 双播放器通道（见 VideoPlayerPip / PipManager）
/// - 主播放器暂停后原生 AVPlayer 起系统悬浮窗，PiP 结束恢复主播放器续播
///
/// 听剧模式：隐藏画面只保留音频，可后台/息屏继续播放
class VideoPlayerWidget extends StatefulWidget {
  const VideoPlayerWidget({
    super.key,
    required this.player,
    this.controller,
    required this.url,
    this.headers,
    this.resumeSeconds = 0,
    this.videoTitle,
    this.currentEpisodeName,
    this.episodeNames = const [],
    this.selectedEpisodeIndex = 0,
    this.canPlayNext = false,
    this.canPlayPrevious = false,
    this.isPipMode = false,
    this.showAudioModeButton = false,
    this.skipIntroSeconds = 0,
    this.skipOutroSeconds = 0,
    this.onPlayNext,
    this.onPlayPrevious,
    this.onSelectEpisode,
    this.onPositionChanged,
    this.onEnded,
    this.onFullScreenChanged,
    this.onBack,
    this.onSetSkipIntro,
    this.onSetSkipOutro,
  });

  /// 播放器实例（由外部持有，页面间共享）
  final Player player;

  /// VideoController 实例（跨全屏/普通模式共享，保证 ANGLE texture 通道不被重建）
  final VideoController? controller;

  /// 播放地址
  final String url;

  /// 自定义请求头
  final Map<String, String>? headers;

  /// 续播秒数（>0 时从该位置开始播放）
  final double resumeSeconds;

  /// 视频标题
  final String? videoTitle;

  /// 当前集数名称
  final String? currentEpisodeName;

  /// 集数名称列表
  final List<String> episodeNames;

  /// 当前选中集数索引
  final int selectedEpisodeIndex;

  /// 是否可以播下一集
  final bool canPlayNext;

  /// 是否可以播上一集
  final bool canPlayPrevious;

  /// 是否处于 PiP 模式（隐藏控制条等）
  final bool isPipMode;

  /// 是否显示"听剧模式"按钮（点播页开启；直播页有自己的听剧入口，不传）
  final bool showAudioModeButton;

  /// 跳过片头秒数
  final double skipIntroSeconds;

  /// 跳过片尾秒数
  final double skipOutroSeconds;

  /// 播下一集
  final VoidCallback? onPlayNext;

  /// 播上一集
  final VoidCallback? onPlayPrevious;

  /// 选集播放
  final ValueChanged<int>? onSelectEpisode;

  /// 播放进度变化
  final ValueChanged<Duration>? onPositionChanged;

  /// 播放结束
  final VoidCallback? onEnded;

  /// 全屏状态变化（true=进入全屏，false=退出全屏）
  final ValueChanged<bool>? onFullScreenChanged;

  /// 返回
  final VoidCallback? onBack;

  /// 设置跳过片头
  final ValueChanged<double>? onSetSkipIntro;

  /// 设置跳过片尾
  final ValueChanged<double>? onSetSkipOutro;

  @override
  State<VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget>
    with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController _controller;

  // 状态
  bool _isBuffering = false;
  bool _showControls = true;
  bool _isLocked = false;
  bool _isNativeFullscreen = false;
  double _brightness = 1.0;
  double _volume = 1.0;
  double _playbackSpeed = 1.0;
  bool _isLongPressingFast = false;
  bool _isLongPressSpeedLocked = false;
  double _longPressLockUpwardThreshold = 200;
  bool _showVolumeIndicator = false;
  bool _showBrightnessIndicator = false;
  bool _showForwardSeek = false;
  bool _showBackwardSeek = false;
  bool _isPipMode = false;
  bool _isDescriptionExpanded = false;
  bool _showEpisodeSheet = false;
  bool _showSettingsSheet = false;
  bool _audioMode = false;
  String _gestureHorizontalHint = '';
  Timer? _hideControlsTimer;
  int _videoRebuildKey = 0;
  bool _autoPipInFlight = false;

  // 播放位置监听
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<bool>? _playingSub;

  String get _displayTitle {
    return widget.currentEpisodeName?.isNotEmpty == true
        ? widget.currentEpisodeName!
        : (widget.videoTitle ?? '');
  }

  @override
  void initState() {
    super.initState();
    _player = widget.player;
    _controller = widget.controller ?? VideoController(_player);
    _isPipMode = widget.isPipMode;
    WidgetsBinding.instance.addObserver(this);
    _initPlayerListeners();
    _openMedia();
    if (widget.resumeSeconds > 0) {
      Future.microtask(() {
        try {
          _player.seek(Duration(seconds: widget.resumeSeconds.toInt()));
        } catch (_) {}
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positionSub?.cancel();
    _bufferingSub?.cancel();
    _durationSub?.cancel();
    _stateSub?.cancel();
    _playingSub?.cancel();
    _hideControlsTimer?.cancel();
    // 离开页面时退出 PiP
    if (VideoPlayerPip.instance.isActive) {
      VideoPlayerPip.instance.exit();
    }
    if (WindowFullScreen.instance.isActive) {
      WindowFullScreen.instance.exit();
    }
    VideoPlayerPip.instance.detachPlayer();
    super.dispose();
  }

  // ============================================================
  // 播放器初始化
  // ============================================================

  void _initPlayerListeners() {
    _positionSub = _player.stream.position.listen((pos) {
      if (mounted) {
        widget.onPositionChanged?.call(pos);
      }
    });
    _bufferingSub = _player.stream.buffering.listen((isBuffering) {
      if (mounted) setState(() => _isBuffering = isBuffering);
    });
    _durationSub = _player.stream.duration.listen((dur) {});
    _stateSub = _player.stream.state.listen((state) {
      if (mounted) {
        // 播放结束 → 自动下一集
        if (state.playing == false &&
            state.position >= state.duration &&
            state.duration > Duration.zero) {
          widget.onEnded?.call();
        }
      }
    });
    _playingSub = _player.stream.playing.listen((playing) {
      if (mounted && playing) {
        // 开始播放时自动隐藏控制条
        _scheduleHideControls();
      }
    });
  }

  void _openMedia() {
    try {
      final headers = widget.headers;
      if (headers != null && headers.isNotEmpty) {
        _player.open(Media(widget.url, httpHeaders: headers));
      } else {
        _player.open(Media(widget.url));
      }
    } catch (_) {}
  }

  // ============================================================
  // 生命周期（自动 PiP）
  // ============================================================

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // iOS：播放中退到后台（按 Home / 切到其他 App）自动进入系统画中画小窗，
    // 视频悬浮继续播放。回前台时 PiP 小窗仍在角落，由系统/用户关闭时
    // onStopped 回调恢复主播放器续播。
    if (state == AppLifecycleState.paused) {
      _autoEnterPipOnBackground();
    }
  }

  /// iOS：退后台自动进入画中画小窗（静默，失败不打扰用户）
  Future<void> _autoEnterPipOnBackground() async {
    if (!Platform.isIOS) return;
    // 已在 PiP / 自动触发进行中 → 跳过
    if (VideoPlayerPip.instance.isIosActive) return;
    if (_autoPipInFlight) return;
    // 未在播放（暂停/结束）→ 不进 PiP
    if (!_player.state.playing) return;

    final playUrl = _player.state.playlist.medias.isNotEmpty
        ? _player.state.playlist.medias.last.uri
        : widget.url;
    if (playUrl.isEmpty) return;

    // 设备不支持（模拟器返回 false）→ 静默跳过
    bool supported;
    try {
      supported = await VideoPlayerPip.instance.isIosPipSupported();
    } catch (_) {
      supported = false;
    }
    if (!supported) return;

    _autoPipInFlight = true;
    final currentPos = _player.state.position;
    // **修复自动 PiP 无声**: 与手动路径一致, 进入系统 PiP 前先暂停
    // 主播放器(mpv)释放 audio session, AVPlayer 出声后才无感切换。
    try {
      _player.pause();
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 120));
    try {
      final entered = await VideoPlayerPip.instance.enterIos(
        url: playUrl,
        headers: widget.headers,
        position: currentPos,
        onStarted: () {
          // 主播放器已暂停, 保留空实现兼容旧回调语义
        },
        onStopped: () {
          // PiP 被系统关闭 / 用户点"返回App"：恢复主播放器续播
          if (!mounted) return;
          final resume = VideoPlayerPip.instance.iosLastPosition;
          if (resume > Duration.zero) {
            try {
              _player.seek(resume);
            } catch (_) {}
          }
          try {
            _player.play();
          } catch (_) {}
        },
      );
      // 启动成功：主播放器已先暂停（PiP 出声无冲突）；
      // 失败（entered=false）则恢复主播放器继续播，静默不打扰
      if (!entered) {
        try {
          _player.play();
        } catch (_) {}
      }
    } finally {
      _autoPipInFlight = false;
    }
  }

  // ============================================================
  // 画中画（手动）
  // ============================================================

  Future<void> _togglePiP() async {
    // iOS 端：系统级画中画（双播放器方案）
    if (Platform.isIOS) {
      // 已在 PiP：退出并恢复主播放器
      if (VideoPlayerPip.instance.isIosActive) {
        final resume = VideoPlayerPip.instance.iosLastPosition;
        await VideoPlayerPip.instance.exitIos();
        if (resume > Duration.zero) {
          try {
            _player.seek(resume);
          } catch (_) {}
        }
        try {
          _player.play();
        } catch (_) {}
        return;
      }
      // 设备不支持（模拟器返回 false）
      final supported = await VideoPlayerPip.instance.isIosPipSupported();
      if (!supported) {
        _showMessage('当前设备不支持画中画（真机可用）');
        return;
      }
      // 取当前实际播放地址（清晰度切换后以 player 为准）
      final playUrl = _player.state.playlist.medias.isNotEmpty
          ? _player.state.playlist.medias.last.uri
          : widget.url;
      if (playUrl.isEmpty) {
        _showMessage('当前没有可用的播放地址');
        return;
      }
      final currentPos = _player.state.position;
      // **修复自动/手动 PiP 无声**: 启动系统 PiP 前先暂停主播放器(mpv),
      // 释放 AVAudioSession 独占, AVPlayer 启动后才能正常出声。
      // 之前等 onStarted 才暂停 mpv, 此时 mpv 仍占着 audio session,
      // 系统 PiP 小窗(原生 AVPlayer) 会无声(画面正常但没声音)。
      try {
        _player.pause();
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final entered = await VideoPlayerPip.instance.enterIos(
        url: playUrl,
        headers: widget.headers,
        position: currentPos,
        onStarted: () {
          // 系统 PiP 悬浮窗真正出现 → 主播放器已暂停, 不再重复暂停
          // (保留空实现, 兼容旧回调语义)
        },
        onStopped: () {
          // PiP 被系统关闭 / 用户点"返回App"：恢复主播放器续播
          if (!mounted) return;
          final resume = VideoPlayerPip.instance.iosLastPosition;
          if (resume > Duration.zero) {
            try {
              _player.seek(resume);
            } catch (_) {}
          }
          try {
            _player.play();
          } catch (_) {}
        },
      );
      if (!entered) {
        // 原生侧启动失败（源未就绪 / 加载失败 / 超时），提示用户；
        // 主播放器之前已暂停, 失败后恢复继续播
        try {
          _player.play();
        } catch (_) {}
        _showMessage('画中画启动失败，请稍后重试');
      }
      // 启动成功：主播放器已先暂停（PiP 出声无冲突）
      return;
    }
    // 互斥：如果当前是全屏状态，先 await 退出全屏再进入 PiP
    if (WindowFullScreen.instance.isActive || _isNativeFullscreen) {
      await _exitFullScreen();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // 附加当前 Player 到 PiP 模块（不创建新实例，保留播放状态）
    VideoPlayerPip.instance.attachPlayer(_player);
    await VideoPlayerPip.instance.toggle();
  }

  // ============================================================
  // 听剧模式
  // ============================================================

  /// 切换听剧模式：隐藏画面只留音频，可后台/息屏继续播放。
  /// 进入时隐藏普通控制条（覆盖层自带退出按钮）；退出时恢复。
  void _toggleAudioMode() {
    setState(() {
      _audioMode = !_audioMode;
      if (_audioMode) {
        _showControls = false;
      } else {
        _showControls = true;
        _scheduleHideControls();
      }
    });
  }

  /// 听剧模式全屏音频层：全黑背景 + 旋转音乐图标 + 片名 + 退出按钮。
  /// 播放器（media_kit）继续在底层运行，仅隐藏画面，音频持续输出。
  Widget _buildAudioModeOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _PipAudioModeMusicIcon(size: 44, color: Colors.white70),
              const SizedBox(height: 28),
              if (_displayTitle.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Text(
                    _displayTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
              const SizedBox(height: 10),
              Text(
                '听剧模式 · 后台可继续播放',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 40),
              GestureDetector(
                onTap: _toggleAudioMode,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.2),
                      width: 0.5,
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.tv, color: Colors.white, size: 15),
                      SizedBox(width: 8),
                      Text(
                        '退出听剧模式',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 视频画面
        Positioned.fill(
          child: Video(
            key: ValueKey('video_$_videoRebuildKey'),
            controller: _controller,
            controls: null,
            fit: BoxFit.contain,
          ),
        ),

        // 亮度遮罩
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              color: Colors.black.withValues(alpha: 1.0 - _brightness),
            ),
          ),
        ),

        // 缓冲指示器
        if (_isBuffering)
          const Center(
            child: SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 3,
              ),
            ),
          ),

        // 手势层（覆盖整个区域，识别单击/双击/长按/拖动）
        Positioned.fill(child: _buildGestureLayer()),

        // 顶部水平拖动提示
        if (_gestureHorizontalHint.isNotEmpty)
          Positioned(
            top: 60,
            left: 0,
            right: 0,
            child: Center(
              child: _GestureHintBubble(text: _gestureHorizontalHint),
            ),
          ),

        // 顶部导航栏
        if (_showControls && !_isLocked) _buildHeaderBar(),

        // 锁定按钮
        if (_showControls || _isLocked) _buildLockButton(),

        // 底部控制区域
        if (_showControls && !_isLocked) _buildBottomControls(),

        // 跳过片头/片尾按钮
        if (!_isLocked) _buildSkipButtons(),

        // 音量指示器
        if (_showVolumeIndicator) _buildVolumeIndicator(),
        if (_showBrightnessIndicator) _buildBrightnessIndicator(),
        if (_showForwardSeek || _showBackwardSeek)
          _buildSeekIndicator(_showForwardSeek),

        // 长按倍速提示
        if (_isLongPressingFast || _isLongPressSpeedLocked)
          _buildLongPressSpeedHint(),

        // 剧集选择覆盖层
        if (_showEpisodeSheet) _buildEpisodeOverlay(),

        // 设置弹窗
        if (_showSettingsSheet) _buildSettingsSheet(),

        // 听剧模式覆盖层（隐藏画面、保留音频）
        // **关键修复**: 必须放在手势层之上(Stack 最顶层)。
        // 之前放在手势层下面, 全屏手势层 Positioned.fill 会吞掉
        // 覆盖层上"退出听剧模式"按钮的所有点击 —— 这就是听剧模式
        // 退不出去的直接原因。
        if (_audioMode) _buildAudioModeOverlay(),
      ],
    );
  }

  // ============================================================
  // 手势处理层
  // ============================================================

  Widget _buildGestureLayer() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onLongPressStart: (details) {
            if (_isLocked) return;
            if (_isLongPressSpeedLocked) {
              setState(() {
                _isLongPressSpeedLocked = false;
                _isLongPressingFast = false;
              });
              _player.setRate(_playbackSpeed);
              return;
            }
            _player.setRate(_playbackSpeed * 2);
            setState(() => _isLongPressingFast = true);
          },
          onLongPressMoveUpdate: (details) {
            if (_isLocked) return;
            if (_isLongPressSpeedLocked) return;
            if (details.offsetFromOrigin.dy < -_longPressLockUpwardThreshold) {
              setState(() => _isLongPressSpeedLocked = true);
            }
          },
          onLongPressEnd: (_) {
            if (_isLocked) return;
            if (_isLongPressSpeedLocked) {
              setState(() => _isLongPressingFast = false);
              return;
            }
            _player.setRate(_playbackSpeed);
            setState(() => _isLongPressingFast = false);
          },
          onTap: () {
            if (_isLocked) return;
            setState(() {
              _showControls = !_showControls;
            });
            if (_showControls) {
              _scheduleHideControls();
            }
          },
          onDoubleTap: () {
            if (_isLocked) return;
            _togglePlayPause();
          },
          onVerticalDragStart: (details) {
            if (_isLocked) return;
            _dragStartX = details.localPosition.dx;
            _dragStartY = details.localPosition.dy;
            _dragStartBrightness = _brightness;
            _dragStartVolume = _volume;
            _dragStartTime = _player.state.position;
            _isVerticalDrag = true;
            _isHorizontalDrag = false;
          },
          onVerticalDragUpdate: (details) {
            if (_isLocked) return;
            if (_isVerticalDrag) {
              if (_dragStartX < width * 0.5) {
                // 左侧滑动调亮度
                final delta = -details.delta.dy / 200;
                setState(() {
                  _brightness = (_dragStartBrightness + delta).clamp(0.2, 1.0);
                  _showBrightnessIndicator = true;
                });
              } else {
                // 右侧滑动调音量
                final delta = -details.delta.dy / 200;
                setState(() {
                  _volume = (_dragStartVolume + delta).clamp(0.0, 1.0);
                  _showVolumeIndicator = true;
                });
                try {
                  _player.setVolume(_volume);
                } catch (_) {}
              }
            }
          },
          onVerticalDragEnd: (_) {
            _isVerticalDrag = false;
            Future.delayed(const Duration(milliseconds: 800), () {
              if (mounted) {
                setState(() {
                  _showVolumeIndicator = false;
                  _showBrightnessIndicator = false;
                });
              }
            });
          },
          onHorizontalDragStart: (details) {
            if (_isLocked) return;
            _dragStartX = details.localPosition.dx;
            _dragStartTime = _player.state.position;
            _isVerticalDrag = false;
            _isHorizontalDrag = true;
          },
          onHorizontalDragUpdate: (details) {
            if (_isLocked) return;
            if (_isHorizontalDrag) {
              final delta = details.delta.dx / width;
              setState(() {
                _showForwardSeek = delta > 0;
                _showBackwardSeek = delta < 0;
              });
            }
          },
          onHorizontalDragEnd: (_) {
            if (_isLocked) return;
            if (_isHorizontalDrag) {
              setState(() {
                _showForwardSeek = false;
                _showBackwardSeek = false;
              });
            }
            _isHorizontalDrag = false;
          },
        );
      },
    );
  }

  double _dragStartX = 0;
  double _dragStartY = 0;
  double _dragStartBrightness = 1.0;
  double _dragStartVolume = 1.0;
  Duration _dragStartTime = Duration.zero;
  bool _isVerticalDrag = false;
  bool _isHorizontalDrag = false;

  // ============================================================
  // 控制条
  // ============================================================

  void _scheduleHideControls() {
    _hideControlsTimer?.cancel();
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && !_isLocked && !_audioMode) {
        setState(() => _showControls = false);
      }
    });
  }

  void _togglePlayPause() {
    if (_player.state.playing) {
      _player.pause();
    } else {
      _player.play();
    }
    setState(() {});
  }

  void _showMessage(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ============================================================
  // 全屏
  // ============================================================

  Future<void> _enterFullScreen() async {
    if (_isNativeFullscreen) return;
    _isNativeFullscreen = true;
    if (mounted) setState(() {});
    widget.onFullScreenChanged?.call(true);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    if (widget.controller != null) {
      try {
        widget.controller!.enterFullscreen();
      } catch (_) {}
    }
  }

  Future<void> _exitFullScreen() async {
    if (!_isNativeFullscreen) return;
    _isNativeFullscreen = false;
    if (mounted) setState(() {});
    widget.onFullScreenChanged?.call(false);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (widget.controller != null) {
      try {
        widget.controller!.exitFullscreen();
      } catch (_) {}
    }
  }

  void _buildSkipButtons() {}
  void _buildVolumeIndicator() {}
  void _buildBrightnessIndicator() {}
  void _buildSeekIndicator(bool forward) {}
  void _buildLongPressSpeedHint() {}
  void _buildEpisodeOverlay() {}
  void _buildSettingsSheet() {}
  Widget _buildHeaderBar() => const SizedBox.shrink();
  Widget _buildLockButton() => const SizedBox.shrink();
  Widget _buildBottomControls() => const SizedBox.shrink();
}

/// 听剧模式旋转音乐图标（装饰动画）
class _PipAudioModeMusicIcon extends StatefulWidget {
  final double size;
  final Color color;
  const _PipAudioModeMusicIcon({required this.size, required this.color});

  @override
  State<_PipAudioModeMusicIcon> createState() => _PipAudioModeMusicIconState();
}

class _PipAudioModeMusicIconState extends State<_PipAudioModeMusicIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: Icon(Icons.music_note, size: widget.size, color: widget.color),
    );
  }
}
