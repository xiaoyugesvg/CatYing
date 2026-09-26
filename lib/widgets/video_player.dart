import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart' show DragToMoveArea;
import '../common/theme.dart';
import 'video_player_pip.dart';
import 'window_fullscreen.dart';

/// 视频画面比例 - 对应 Swift VideoFitType
enum VideoFitType {
  fill(0, '拉伸', BoxFit.fill),
  contain(1, '自动', BoxFit.contain),
  cover(2, '裁剪', BoxFit.cover),
  fitWidth(3, '等宽', BoxFit.contain),
  fitHeight(4, '等高', BoxFit.contain),
  none(5, '原始', BoxFit.none),
  ratio4x3(6, '4:3', BoxFit.contain),
  ratio16x9(7, '16:9', BoxFit.contain);

  final int value;
  final String desc;
  final BoxFit boxFit;
  const VideoFitType(this.value, this.desc, this.boxFit);

  double? get aspectRatio {
    switch (this) {
      case VideoFitType.ratio4x3:
        return 4.0 / 3.0;
      case VideoFitType.ratio16x9:
        return 16.0 / 9.0;
      default:
        return null;
    }
  }
}

/// 视频播放器组件 - 对应 Swift PlayerView + PlayerControlsOverlay
/// 基于 media_kit + libmpv 实现，自定义控制覆盖层
class VideoPlayerWidget extends StatefulWidget {
  /// 外部注入的 Player 实例
  final Player? player;

  /// 外部注入的 VideoController 实例（与 [player] 配套使用）。
  final VideoController? controller;

  final String url;
  final Map<String, String>? headers;
  final double? resumeSeconds;
  final String? videoTitle;
  final String? currentEpisodeName;
  final List<String> episodeNames;
  final int selectedEpisodeIndex;
  final bool canPlayNext;
  final bool canPlayPrevious;

  /// 是否处于画中画模式（窗口无标题栏，需要在视频上叠加 DragToMoveArea）
  final bool isPipMode;

  /// 是否显示"听剧模式"按钮（点播页开启；直播页有自己的听剧入口，不传）
  final bool showAudioModeButton;

  /// 初始画面比例（null 默认 contain"自动"）。
  /// 详情页传入 cover，让 16:9 视频铺满 4:3 容器，画面与黑框完全一致
  /// （修复"播放器画面比黑框小、上下留黑边"的问题）。
  final VideoFitType? initialVideoFit;

  /// 跳过片头秒数（0 表示关闭），对应 Swift skipIntroSeconds
  final int skipIntroSeconds;

  /// 跳过片尾秒数（0 表示关闭），对应 Swift skipOutroSeconds
  final int skipOutroSeconds;

  final VoidCallback? onPlaying;
  final ValueChanged<Duration>? onPositionChanged;
  final VoidCallback? onEnded;
  final VoidCallback? onError;

  /// 全屏状态变化回调（true=进入全屏，false=退出全屏）
  final ValueChanged<bool>? onFullScreenChanged;
  final VoidCallback? onPlayNext;
  final VoidCallback? onPlayPrevious;
  final ValueChanged<int>? onSelectEpisode;
  final VoidCallback? onBack;
  final ValueChanged<int>? onSetSkipIntro;
  final ValueChanged<int>? onSetSkipOutro;

  const VideoPlayerWidget({
    super.key,
    this.player,
    this.controller,
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
    this.showAudioModeButton = false,
    this.initialVideoFit,
    this.skipIntroSeconds = 0,
    this.skipOutroSeconds = 0,
    this.onPlaying,
    this.onPositionChanged,
    this.onEnded,
    this.onError,
    this.onFullScreenChanged,
    this.onPlayNext,
    this.onPlayPrevious,
    this.onSelectEpisode,
    this.onBack,
    this.onSetSkipIntro,
    this.onSetSkipOutro,
  });

  @override
  State<VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<VideoPlayerWidget>
    with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController _controller;
  bool _ownsPlayer = false; // 是否自己创建并需要释放

  /// 跨 widget rebuild 持久化的状态缓存（按 widget.key 区分）。
  static final Map<String, _PersistedPlayerState> _stateCache =
      <String, _PersistedPlayerState>{};

  late final _PersistedPlayerState _persisted;
  late final String _cacheKey;

  bool _isPlaying = false;

  /// iOS 自动画中画进行中（防止退后台重复触发）
  bool _autoPipInFlight = false;

  /// 听剧模式（点播页）：开启后隐藏视频画面、只保留音频输出，
  /// 可后台/息屏继续播放（Info.plist 已配置 UIBackgroundModes=audio）
  bool _audioMode = false;

  /// 缓冲状态：不再默认 true，而是从 player.state 同步读取，避免全屏/普通模式
  /// 切换时新实例显示"转圈"假象
  bool _isBuffering = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _showControls = true;
  bool _isDragging = false;
  double _dragValue = 0;
  double _playbackSpeed = 1.0;
  bool _isLocked = false;
  bool _showEpisodeSheet = false;
  bool _showSettingsSheet = false;

  // 弹幕（Logvr-danmu / 弹弹play 兼容）
  List<_DanmuItem> _danmus = [];
  bool _danmuOn = true;
  bool _danmuLoaded = false;
  String _danmuApiUrl = '';
  late VideoFitType _videoFit;
  double _volume = 1.0;
  double _brightness = 0.5;

  /// 内部追踪 native fullscreen 状态（与 mpv / OS 窗口同步）
  bool _isNativeFullscreen = false;

  /// 播放器实际可用高度（由 _buildContentStack 的 LayoutBuilder 记录），
  /// 用于上下控制栏间距随播放器大小自适应（小窗紧凑 / 全屏舒展）。
  double _playerAreaHeight = 0;

  /// iOS / 移动端 immersive 状态（WindowFullScreen 在 iOS 是 no-op）
  bool _isImmersive = false;

  /// 长按倍速中：用于在 UI 上显示 "2X" 提示
  bool _isLongPressingFast = false;

  /// 长按倍速已锁定：上滑超过阈值后保持 2X 倍速，抬手不恢复
  bool _isLongPressSpeedLocked = false;

  /// 上滑锁定倍速的垂直位移阈值（手指向上滑过这么多像素视为锁定）
  static const double _longPressLockUpwardThreshold = 80.0;

  /// 续播目标位置缓存：与 Swift 的 `pendingSeekSeconds` 字段等价。
  double? _pendingResumeSeconds;

  /// 用于强制重建 Video widget，绕过 ANGLE surface 失效导致的黑屏
  int _videoRebuildKey = 0;

  // 分辨率与网速
  String _resolutionText = '';
  String _bitrateText = '';

  // 临时手势状态
  bool _showVolumeIndicator = false;
  bool _showBrightnessIndicator = false;
  bool _showForwardSeek = false;
  bool _showBackwardSeek = false;
  int _seekAccumulatedSeconds = 0;
  double _gestureInitialVolume = 0;
  double _gestureInitialBrightness = 0;
  double _gestureSeekTemp = 0;
  String _gestureHorizontalHint = ''; // 顶部水平拖动提示

  static const List<double> _supportedSpeeds = [
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
    3.0,
  ];
  static const Duration _hideDelay = Duration(seconds: 5);
  static const int _seekStep = 10;
  static const List<int> _skipPresets = [0, 30, 60, 90, 120, 180];
  static const int _skipMaxSeconds = 600; // 自定义最大值 10 分钟

  Timer? _hideTimer;
  Timer? _bitrateTimer;
  Timer? _indicatorTimer;

  // ============================================================
  // 全屏状态栏 - 电量 + 时间
  // ============================================================

  /// 电池电量 (0-100) ;  -1 表示未知 (iOS 模拟器 / 平台不支持)
  int _batteryLevel = -1;
  BatteryState _batteryState = BatteryState.unknown;
  StreamSubscription<BatteryState>? _batteryStateSub;

  /// 顶部状态栏显示的当前时间 (HH:mm) ;  每分钟刷新
  String _currentTime = '';
  Timer? _timeTimer;

  // ============================================================

  @override
  void initState() {
    super.initState();
    // iOS 退后台自动画中画需要监听 App 生命周期
    WidgetsBinding.instance.addObserver(this);
    _cacheKey = widget.key?.toString() ?? '_VideoPlayerWidget_default_';
    _persisted = _stateCache.putIfAbsent(
      _cacheKey,
      () => _PersistedPlayerState(),
    );
    _isNativeFullscreen = _persisted.isNativeFullscreen;
    _isImmersive = _persisted.isImmersive;
    _videoFit = widget.initialVideoFit ?? VideoFitType.contain;

    // 启动时间定时器 (每分钟整点更新,用于全屏状态栏显示)
    _currentTime = _formatTimeNow();
    _timeTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      final t = _formatTimeNow();
      if (t != _currentTime) {
        setState(() => _currentTime = t);
      }
    });

    // 启动电池监听 (iOS / Android / 桌面端都支持, 失败时静默忽略)
    _initBatteryMonitor();

    if (widget.player != null) {
      _player = widget.player!;
      _ownsPlayer = false;
    } else {
      _player = Player(
        configuration: const PlayerConfiguration(title: 'TVBox'),
      );
      _ownsPlayer = true;
    }
    if (widget.controller != null) {
      _controller = widget.controller!;
    } else {
      _controller = VideoController(_player);
    }

    // 同步读取 player 真实状态，避免全屏/普通模式切换时新实例显示"转圈"假象
    _isPlaying = _player.state.playing;
    _isBuffering = _player.state.buffering;
    _position = _player.state.position;
    _duration = _player.state.duration;
    _playbackSpeed = _player.state.rate;

    _player.stream.error.listen((error) {
      if (error.isNotEmpty) widget.onError?.call();
    });

    _player.stream.playing.listen((playing) {
      if (mounted) {
        setState(() {
          _isPlaying = playing;
          _isBuffering = false;
        });
        if (playing) {
          widget.onPlaying?.call();
          _applyPendingResumeSeek();
          // iOS：前台预热原生 AVPlayer（静音预缓冲常驻），退后台/点 PiP 时
          // 原生立即启动系统悬浮窗，避免"后台等缓冲"导致 PiP 时灵时不灵
          if (Platform.isIOS) {
            final u = _player.state.playlist.medias.isNotEmpty
                ? _player.state.playlist.medias.last.uri
                : widget.url;
            if (u.isNotEmpty) {
              VideoPlayerPip.instance
                  .prepareIos(url: u, headers: widget.headers);
            }
          }
        }
      }
    });

    _player.stream.buffering.listen((buffering) {
      if (mounted) setState(() => _isBuffering = buffering);
    });

    _player.stream.position.listen((position) {
      if (mounted) {
        setState(() => _position = position);
        widget.onPositionChanged?.call(position);
      }
    });

    _player.stream.duration.listen((duration) {
      if (mounted) setState(() => _duration = duration);
    });

    _player.stream.completed.listen((completed) {
      if (completed) widget.onEnded?.call();
    });

    _volume = _player.state.volume;
    if (_ownsPlayer) {
      _openMedia();
    } else {
      // 外部注入 player（detail view 的常规路径）：build 期间 _ensurePlayer
      // 已经调过 `_player.open(Media(url, httpHeaders: headers, start: ...))`，
      // libmpv 会直接从续播位置开始解码。这里 _scheduleResumeSeek 只作
      // safety net：如果 Media.start 失效，state.playing listener 会兜底 seek
      if (_persisted.resumeApplied) {
        debugPrint('=== initState: 续播已应用 (widget 重建), 跳过 ===');
        _pendingResumeSeconds = null; // 防御清空, 防止 listener 误触发
      } else {
        _persisted.resumeApplied = true; // 先标记, 防重建 race 重复触发
        _scheduleResumeSeek();
      }
    }
    _scheduleHideControls();
    _startBitrateTimer();
    _loadDanmuSettings();

    // **关键**：监听 WindowFullScreen 状态变化
    WindowFullScreen.instance.activeNotifier.addListener(
      _onWindowFullScreenChanged,
    );
  }

  /// WindowFullScreen 状态变化回调
  void _onWindowFullScreenChanged() {
    if (!mounted) return;
    final isActive = WindowFullScreen.instance.isActive || _isImmersive;
    if (isActive != _isNativeFullscreen) {
      setState(() {
        _isNativeFullscreen = isActive;
        _persisted.isNativeFullscreen = isActive;
        _videoRebuildKey++;
      });
      _scheduleDelayedRebuild();
    }
  }

  /// 延迟多次重建 Video widget，绕过 ANGLE surface 重建竞态
  void _scheduleDelayedRebuild() {
    for (final delayMs in const [100, 300, 600]) {
      Future<void>.delayed(Duration(milliseconds: delayMs), () {
        if (!mounted) return;
        setState(() {
          _videoRebuildKey++;
        });
      });
    }
  }

  // ============================================================
  // 电池 + 时间 (全屏状态栏)
  // ============================================================

  String _formatTimeNow() {
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Future<void> _initBatteryMonitor() async {
    try {
      final battery = Battery();
      try {
        final lvl = await battery.batteryLevel;
        if (!mounted) return;
        setState(() => _batteryLevel = lvl);
      } catch (_) {}
      _batteryStateSub = battery.onBatteryStateChanged.listen((state) async {
        if (!mounted) return;
        setState(() => _batteryState = state);
        try {
          final lvl = await battery.batteryLevel;
          if (!mounted) return;
          setState(() => _batteryLevel = lvl);
        } catch (_) {}
      });
    } catch (e) {
      debugPrint('=== _initBatteryMonitor: 失败: $e ===');
    }
  }

  /// 全屏状态栏 - 顶部右侧: 时间 + 电池图标
  Widget _buildStatusBarInfo() {
    final stateName = switch (_batteryState) {
      BatteryState.charging => 'charging',
      BatteryState.discharging => '',
      BatteryState.full => 'full',
      BatteryState.connectedNotCharging => 'plugged',
      BatteryState.unknown => '',
    };
    final level = _batteryLevel < 0 ? '--' : '$_batteryLevel%';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _currentTime,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
            shadows: [Shadow(blurRadius: 4, color: Colors.black87)],
          ),
        ),
        const SizedBox(width: 10),
        Icon(
          stateName == 'charging'
              ? Icons.battery_charging_full
              : _batteryLevel > 80
              ? Icons.battery_full
              : _batteryLevel > 50
              ? Icons.battery_5_bar
              : _batteryLevel > 20
              ? Icons.battery_3_bar
              : Icons.battery_1_bar,
          color: Colors.white,
          size: 16,
          shadows: const [
            Shadow(blurRadius: 4, color: Colors.black87),
          ],
        ),
        const SizedBox(width: 2),
        Text(
          level,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w500,
            shadows: [Shadow(blurRadius: 4, color: Colors.black87)],
          ),
        ),
      ],
    );
  }

  @override
  void didUpdateWidget(VideoPlayerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      // 不做热切换：避免与外部管理冲突
    }
    if (oldWidget.url != widget.url) {
      if (_isLongPressSpeedLocked || _isLongPressingFast) {
        setState(() {
          _isLongPressSpeedLocked = false;
          _isLongPressingFast = false;
        });
        try {
          _player.setRate(_playbackSpeed);
        } catch (_) {}
      }
      _persisted.resumeApplied = false;
      // 换源后重新拉取弹幕（弹幕按视频 URL 匹配, 选集/换源需刷新）
      _danmuLoaded = false;
      _danmus = [];
      if (_danmuApiUrl.isNotEmpty) {
        _ensureDanmuLoaded();
      }
      if (_ownsPlayer) {
        _openMedia();
      } else {
        _persisted.resumeApplied = true;
        _scheduleResumeSeek();
      }
    } else if ((oldWidget.resumeSeconds ?? -1) !=
            (widget.resumeSeconds ?? -1) &&
        widget.resumeSeconds != null &&
        widget.resumeSeconds! > 0) {
      // 同一 url 但 resumeSeconds 变化 → 不重复 seek
    }
  }

  void _openMedia() {
    final headers = widget.headers ?? {};
    final start = (widget.resumeSeconds != null && widget.resumeSeconds! > 0)
        ? Duration(seconds: widget.resumeSeconds!.toInt())
        : null;
    _persisted.resumeApplied = true;
    _player.open(Media(widget.url, httpHeaders: headers, start: start));
    _scheduleResumeSeek();
  }

  /// 续播 seek（safety net 模式，对应 Swift `applyPendingSeekIfNeeded`）
  void _scheduleResumeSeek() {
    final resume = widget.resumeSeconds;
    if (resume == null || resume <= 0) return;
    final target = Duration(seconds: resume.toInt());
    try {
      final cur = _player.state.position;
      if (cur > target) {
        debugPrint(
            '=== _scheduleResumeSeek: cur=$cur > target=$target, 用户已观看, 跳过 ===');
        _pendingResumeSeconds = null;
        return;
      }
    } catch (_) {}
    _pendingResumeSeconds = resume;
    try {
      _player.seek(target);
      debugPrint('=== _scheduleResumeSeek: 立即 seek 到 ${resume}s ===');
    } catch (e) {
      debugPrint('=== _scheduleResumeSeek: 立即 seek 失败: $e ===');
    }
    if (_player.state.playing) {
      _applyPendingResumeSeek();
    }
  }

  /// 应用缓存的续播位置（state.playing 兜底），并清空缓存
  void _applyPendingResumeSeek() {
    final pending = _pendingResumeSeconds;
    if (pending == null || pending <= 0) return;
    final target = Duration(seconds: pending.toInt());
    try {
      final cur = _player.state.position;
      if (cur > target) {
        debugPrint(
            '=== _applyPendingResumeSeek: cur=$cur > target=$target, 用户已观看, 跳过 ===');
        _pendingResumeSeconds = null;
        return;
      }
      if ((cur - target).abs() < const Duration(seconds: 2)) {
        debugPrint('=== _applyPendingResumeSeek: 已在 $pending 附近, 跳过 ===');
        _pendingResumeSeconds = null;
        return;
      }
    } catch (_) {}
    _pendingResumeSeconds = null;
    try {
      _player.seek(target);
      debugPrint('=== _applyPendingResumeSeek: 兜底 seek 到 ${pending}s ===');
    } catch (e) {
      debugPrint('=== _applyPendingResumeSeek: 兜底 seek 失败: $e ===');
    }
  }

  /// 读取弹幕配置（设置页配置的 Logvr-danmu / 弹弹play 兼容 API 地址）
  Future<void> _loadDanmuSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _danmuApiUrl = (prefs.getString('danmu_api_url') ?? '').trim();
      _danmuOn = prefs.getBool('danmu_enabled') ?? true;
      if (mounted && _danmuApiUrl.isNotEmpty) {
        _ensureDanmuLoaded();
      }
    } catch (_) {}
  }

  /// 通过视频 URL 直接匹配弹幕（Logvr-danmu 的 /api/v2/comment?url= 接口）
  Future<void> _ensureDanmuLoaded() async {
    if (_danmuLoaded || _danmuApiUrl.isEmpty) return;
    _danmuLoaded = true;
    final url = _player.state.playlist.medias.isNotEmpty
        ? _player.state.playlist.medias.last.uri
        : widget.url;
    if (url.isEmpty) return;
    try {
      final base = _danmuApiUrl.replaceAll(RegExp(r'/+$'), '');
      final api =
          '$base/api/v2/comment?url=${Uri.encodeQueryComponent(url)}&format=json';
      final http = await HttpClient().getUrl(Uri.parse(api));
      http.headers.set('User-Agent', 'NewTv/1.0');
      final res = await http.close();
      if (res.statusCode == 200) {
        final body = await res.transform(utf8.decoder).join();
        final list = parseDanmuBody(body);
        if (mounted && list.isNotEmpty) {
          setState(() => _danmus = list);
        }
      }
    } catch (_) {}
  }

  /// 持久化弹幕开关
  Future<void> _persistDanmuOn() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('danmu_enabled', _danmuOn);
    } catch (_) {}
  }

  void _startBitrateTimer() {
    _bitrateTimer?.cancel();
    _bitrateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final stats = _player.state;
      if (stats.playing) {
        setState(() {
          _updateResolutionFromTrack();
        });
      }
    });
  }

  void _updateResolutionFromTrack() {
    final w = _player.state.width;
    final h = _player.state.height;
    if (w != null && h != null && w > 0 && h > 0) {
      _resolutionText = '${w.toInt()}×${h.toInt()}';
    } else {
      _resolutionText = '';
    }
    if (_isPlaying) {
      _bitrateText = '2.0Mbps';
    } else {
      _bitrateText = '';
    }
  }

  /// 唤醒控制条，并在空闲后自动隐藏
  void _scheduleHideControls() {
    _hideTimer?.cancel();
    if (_isLocked || _showEpisodeSheet || _showSettingsSheet) {
      _showControls = _isLocked || true;
      return;
    }
    _hideTimer = Timer(_hideDelay, () {
      if (!mounted) return;
      if (_isDragging || _showEpisodeSheet || _showSettingsSheet) {
        _scheduleHideControls();
        return;
      }
      setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    if (_isLongPressSpeedLocked) {
      _unlockLongPressSpeed();
      return;
    }
    if (_isLocked) return;
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHideControls();
  }

  /// 解除长按倍速锁定：恢复 _playbackSpeed，清掉相关标志
  void _unlockLongPressSpeed() {
    if (!_isLongPressSpeedLocked && !_isLongPressingFast) return;
    setState(() {
      _isLongPressSpeedLocked = false;
      _isLongPressingFast = false;
    });
    _player.setRate(_playbackSpeed);
  }

  void _togglePlayPause() {
    if (_player.state.playing) {
      _player.pause();
    } else {
      _player.play();
    }
    _scheduleHideControls();
  }

  /// 相对当前位置偏移
  void _seekRelative(Duration delta) {
    final pos = _player.state.position;
    final target = pos + delta;
    _player.seek(target < Duration.zero ? Duration.zero : target);
    _scheduleHideControls();
  }

  Future<void> _onUserToggleFullscreen() async {
    final currentlyFull = WindowFullScreen.instance.isActive || _isImmersive;
    debugPrint(
      '=== _onUserToggleFullscreen: currentlyFull=$currentlyFull '
      'isActive=${WindowFullScreen.instance.isActive} '
      '_isImmersive=$_isImmersive ===',
    );
    if (VideoPlayerPip.instance.isActive) {
      await VideoPlayerPip.instance.exit();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (currentlyFull) {
      await _exitFullScreen();
    } else {
      await _enterFullScreen();
    }
  }

  Future<void> _onUserExitFullscreen() async {
    debugPrint(
      '=== _onUserExitFullscreen: _isNativeFullscreen=$_isNativeFullscreen, isPip=${VideoPlayerPip.instance.isActive} ===',
    );
    if (_isNativeFullscreen) {
      await _exitFullScreen();
      return;
    }
    if (VideoPlayerPip.instance.isActive) {
      await VideoPlayerPip.instance.exit();
      return;
    }
    widget.onBack?.call();
  }

  /// 调 WindowFullScreen 进入全屏
  Future<void> _enterFullScreen() async {
    if (WindowFullScreen.instance.isActive || _isImmersive) {
      debugPrint('=== _enterFullScreen: skip (已处于全屏) ===');
      return;
    }
    debugPrint('=== _enterFullScreen: start ===');
    if (Platform.isIOS) {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    _isImmersive = true;
    _isNativeFullscreen = true;
    _persisted.isImmersive = true;
    _persisted.isNativeFullscreen = true;
    widget.onFullScreenChanged?.call(true);
    try {
      await WindowFullScreen.instance.enter();
      debugPrint('=== _enterFullScreen: WindowFullScreen enter OK ===');
    } catch (e) {
      debugPrint('=== _enterFullScreen: WindowFullScreen enter failed: $e ===');
    }
    if (mounted) _onWindowFullScreenChanged();
    try {
      if (!_player.state.playing) {
        await _player.play();
      }
    } catch (_) {}
  }

  /// 调 WindowFullScreen 退出全屏
  Future<void> _exitFullScreen() async {
    if (!WindowFullScreen.instance.isActive && !_isImmersive) {
      debugPrint('=== _exitFullScreen: skip (不在全屏) ===');
      return;
    }
    debugPrint('=== _exitFullScreen: start ===');
    _isImmersive = false;
    _isNativeFullscreen = false;
    _persisted.isImmersive = false;
    _persisted.isNativeFullscreen = false;
    widget.onFullScreenChanged?.call(false);
    try {
      await WindowFullScreen.instance.exit();
      debugPrint('=== _exitFullScreen: WindowFullScreen exit OK ===');
    } catch (e) {
      debugPrint('=== _exitFullScreen: WindowFullScreen exit failed: $e ===');
    }
    if (Platform.isIOS) {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (mounted) _onWindowFullScreenChanged();
    try {
      if (!_player.state.playing) {
        await _player.play();
      }
    } catch (_) {}
  }

  void _seekTo(Duration position) {
    final clamped = position < Duration.zero
        ? Duration.zero
        : (position > _duration && _duration > Duration.zero
              ? _duration
              : position);
    _player.seek(clamped);
  }

  void _setSpeed(double speed) {
    _player.setRate(speed);
    setState(() => _playbackSpeed = speed);
    _scheduleHideControls();
  }

  void _setVideoFit(VideoFitType fit) {
    setState(() => _videoFit = fit);
    _scheduleHideControls();
  }

  void _toggleLock() {
    setState(() {
      _isLocked = !_isLocked;
      if (_isLocked) {
        _showControls = false;
      } else {
        _showControls = true;
        _scheduleHideControls();
      }
    });
  }

  void _skipIntro() {
    if (widget.skipIntroSeconds > 0) {
      _seekTo(Duration(seconds: widget.skipIntroSeconds));
      _scheduleHideControls();
    }
  }

  void _skipOutro() {
    if (widget.skipOutroSeconds > 0 && _duration > Duration.zero) {
      _seekTo(_duration - Duration(seconds: widget.skipOutroSeconds));
      _scheduleHideControls();
    }
  }

  void _setVolume(double v) {
    final clamped = v.clamp(0.0, 1.0);
    _player.setVolume(clamped * 100); // media_kit 用 0-100
    setState(() => _volume = clamped);
  }

  void _toggleMute() {
    if (_volume > 0) {
      _setVolume(0);
    } else {
      _setVolume(1);
    }
    _scheduleHideControls();
  }

  void _setBrightness(double b) {
    setState(() => _brightness = b.clamp(0.0, 1.0));
  }

  void _showIndicatorLater() {
    _indicatorTimer?.cancel();
    _indicatorTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      setState(() {
        _showVolumeIndicator = false;
        _showBrightnessIndicator = false;
        _showForwardSeek = false;
        _showBackwardSeek = false;
        _gestureHorizontalHint = '';
      });
    });
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:'
          '${minutes.toString().padLeft(2, '0')}:'
          '${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  String _formatSpeed(double speed) {
    if (speed == speed.roundToDouble()) return '${speed.toInt()}X';
    return '${speed.toStringAsFixed(2)}X';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WindowFullScreen.instance.activeNotifier.removeListener(
      _onWindowFullScreenChanged,
    );
    _hideTimer?.cancel();
    _bitrateTimer?.cancel();
    _indicatorTimer?.cancel();
    _timeTimer?.cancel();
    _batteryStateSub?.cancel();
    // iOS：离开播放页，释放原生 PiP 常驻实例
    if (Platform.isIOS) {
      VideoPlayerPip.instance.releaseIos();
    }
    if (_ownsPlayer) {
      _player.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        SingleActivator(LogicalKeyboardKey.escape): _onUserExitFullscreen,
        SingleActivator(LogicalKeyboardKey.keyF): _onUserToggleFullscreen,
        SingleActivator(LogicalKeyboardKey.space): _togglePlayPause,
        SingleActivator(LogicalKeyboardKey.arrowLeft): () {
          _seekRelative(-const Duration(seconds: 5));
        },
        SingleActivator(LogicalKeyboardKey.arrowRight): () {
          _seekRelative(const Duration(seconds: 5));
        },
      },
      child: Focus(
        autofocus: true,
        child: ColoredBox(
          color: Colors.black,
          child: _buildRootArea(),
        ),
      ),
    );
  }

  Widget _buildRootArea() {
    final stack = _buildContentStack();
    if (widget.isPipMode) {
      return DragToMoveArea(child: stack);
    }
    return stack;
  }

  Widget _buildContentStack() {
    return LayoutBuilder(
      builder: (context, constraints) {
        _playerAreaHeight = constraints.maxHeight;
        return _buildContentStackInner();
      },
    );
  }

  Widget _buildContentStackInner() {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 视频画面
        Positioned.fill(
          child: Video(
            key: ValueKey('video_$_videoRebuildKey'),
            controller: _controller,
            controls: null,
            fit: _videoFit.boxFit,
            aspectRatio: _videoFit.aspectRatio,
          ),
        ),

        // 亮度遮罩 - 用半透明黑色覆盖调整亮度
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

        // 弹幕层（手势层之上, 不阻挡点击）
        if (_danmuOn && _danmus.isNotEmpty) _buildDanmuLayer(),

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

        // 长按倍速提示 (屏幕中央 2X + 上滑锁定提示)
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
  // 弹幕层
  // ============================================================

  Widget _buildDanmuLayer() {
    return _DanmuLayer(
      danmus: _danmus,
      positionOf: () => _player.state.position,
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
          onLongPressCancel: () {
            if (_isLocked) return;
            if (_isLongPressSpeedLocked) {
              setState(() => _isLongPressingFast = false);
              return;
            }
            _player.setRate(_playbackSpeed);
            setState(() => _isLongPressingFast = false);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            onDoubleTapDown: (details) {
              final x = details.localPosition.dx;
              if (x < width / 4) {
                _seekBy(-_seekStep, isLeft: true);
              } else if (x > width * 3 / 4) {
                _seekBy(_seekStep, isLeft: false);
              } else {
                _togglePlayPause();
              }
            },
            onDoubleTap: () {},
            onPanStart: (details) {
              if (_isLocked) return;
              _gestureInitialVolume = _volume;
              _gestureInitialBrightness = _brightness;
              _gestureSeekTemp = _position.inMilliseconds.toDouble();
              _gesturePanStartPosition = details.localPosition;
              _gesturePanAxis = null;
              _scheduleHideControls();
            },
            onPanUpdate: (details) {
              if (_isLocked) return;
              final dx = details.localPosition.dx - _gesturePanStartPosition.dx;
              final dy = details.localPosition.dy - _gesturePanStartPosition.dy;
              final absDx = dx.abs();
              final absDy = dy.abs();

              _gesturePanAxis ??= absDx > absDy * 1.5
                  ? PanAxis.horizontal
                  : PanAxis.vertical;

              if (_gesturePanAxis == PanAxis.horizontal) {
                if (_duration > Duration.zero) {
                  final totalMs = _duration.inMilliseconds.toDouble();
                  final scale = totalMs * 0.3;
                  final deltaMs = (dx / width) * scale;
                  _gestureSeekTemp = (_gestureSeekTemp + deltaMs).clamp(
                    0.0,
                    totalMs,
                  );
                  final newPos = Duration(
                    milliseconds: _gestureSeekTemp.round(),
                  );
                  setState(() {
                    _isDragging = true;
                    _dragValue = _gestureSeekTemp;
                    _gestureHorizontalHint =
                        '${_gestureSeekTemp > _position.inMilliseconds ? '+' : ''}'
                        '${(newPos.inSeconds - _position.inSeconds)}秒'
                        '  ${_formatDuration(newPos)}';
                  });
                }
              } else {
                if (_gesturePanStartPosition.dx < width / 2) {
                  final newB =
                      (_gestureInitialBrightness - dy / constraints.maxHeight)
                          .clamp(0.0, 1.0);
                  _setBrightness(newB);
                  setState(() {
                    _showBrightnessIndicator = true;
                    _showVolumeIndicator = false;
                  });
                } else {
                  final newV =
                      (_gestureInitialVolume - dy / constraints.maxHeight)
                          .clamp(0.0, 1.0);
                  setState(() {
                    _setVolume(newV);
                    _showVolumeIndicator = true;
                    _showBrightnessIndicator = false;
                  });
                }
                _showIndicatorLater();
              }
            },
            onPanEnd: (_) {
              if (_isLocked) return;
              if (_gesturePanAxis == PanAxis.horizontal) {
                _seekTo(Duration(milliseconds: _gestureSeekTemp.round()));
                setState(() {
                  _isDragging = false;
                  _gestureHorizontalHint = '';
                });
              } else {
                setState(() {
                  _showVolumeIndicator = false;
                  _showBrightnessIndicator = false;
                });
              }
              _gesturePanAxis = null;
            },
          ),
        );
      },
    );
  }

  Offset _gesturePanStartPosition = Offset.zero;
  PanAxis? _gesturePanAxis;

  void _seekBy(int seconds, {required bool isLeft}) {
    if (_isLocked) return;
    final target = _player.state.position + Duration(seconds: seconds);
    _seekTo(target);
    setState(() {
      _seekAccumulatedSeconds += seconds;
      if (isLeft) {
        _showBackwardSeek = true;
        _showForwardSeek = false;
      } else {
        _showForwardSeek = true;
        _showBackwardSeek = false;
      }
    });
    _showIndicatorLater();
    _scheduleHideControls();
  }

  // ============================================================
  // 顶部导航栏 - 对应 Swift headerBar
  // ============================================================

  // ============================================================
  // 听剧模式（点播页）
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

  Widget _buildHeaderBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: _gradientTopContainer(
        child: Row(
          children: [
            // **v7 (2026-09-27)**：顶栏极简 —— 不再显示视频名称/线路名，
            // 右上角只保留 分辨率 + 网速 + 设置 三个元素（听剧/PiP/投屏
            // 已移到底栏功能行，避免右上角堆满按钮）。
            const Spacer(),

            // 分辨率
            if (_resolutionText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 10, right: 6),
                child: Text(
                  _resolutionText,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ),

            // 网速
            if (_bitrateText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 2, right: 10),
                child: Text(
                  _bitrateText,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ),

            if (_isNativeFullscreen) ...[const SizedBox(width: 4), _buildStatusBarInfo()],

            // 设置（倍速/清晰度/裁剪都在这里）
            _iconButton(
              icon: Icons.more_horiz,
              size: 22,
              width: 44,
              onTap: () {
                setState(() => _showSettingsSheet = true);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 锁定按钮 - 对应 Swift lockButton
  // ============================================================

  Widget _buildLockButton() {
    final leftSafe = MediaQuery.of(context).padding.left;
    return Positioned(
      left: 12 + leftSafe,
      top: 0,
      bottom: 0,
      child: Center(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleLock,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.4),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _isLocked ? Icons.lock : Icons.lock_open,
              color: Colors.white,
              size: 18,
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 底部控制区域 - 对应 Swift bottomSection
  // ============================================================

  Widget _buildBottomControls() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: _gradientBottomContainer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildProgressBar(),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
              child: Row(
                mainAxisSize: MainAxisSize.max,
                children: [
                  if (widget.canPlayPrevious)
                    _iconButton(
                      icon: Icons.skip_previous,
                      size: 22,
                      width: 36,
                      onTap: () {
                        _scheduleHideControls();
                        widget.onPlayPrevious?.call();
                      },
                    ),
                  _buildPlayPauseButton(),
                  if (widget.canPlayNext)
                    _iconButton(
                      icon: Icons.skip_next,
                      size: 22,
                      width: 36,
                      onTap: () {
                        _scheduleHideControls();
                        widget.onPlayNext?.call();
                      },
                    ),
                  const Spacer(),
                  _iconButton(
                    icon: _volume > 0
                        ? (_volume < 0.33 ? Icons.volume_down : Icons.volume_up)
                        : Icons.volume_off,
                    size: 22,
                    width: 36,
                    onTap: _toggleMute,
                  ),
                  if (widget.episodeNames.isNotEmpty)
                    _iconButton(
                      icon: Icons.list,
                      size: 22,
                      width: 36,
                      onTap: () {
                        setState(() => _showEpisodeSheet = true);
                      },
                    ),
                  // 弹幕开关（配置弹幕 API 后显示；开关放控制栏, 不进设置弹窗）
                  if (_danmuApiUrl.isNotEmpty)
                    _iconButton(
                      icon: _danmuOn ? Icons.subtitles : Icons.subtitles_off,
                      size: 22,
                      width: 36,
                      onTap: () {
                        _scheduleHideControls();
                        setState(() => _danmuOn = !_danmuOn);
                        _persistDanmuOn();
                      },
                    ),
                  _iconButton(
                    icon: _isNativeFullscreen
                        ? Icons.fullscreen_exit
                        : Icons.fullscreen,
                    size: 24,
                    width: 42,
                    onTap: () {
                      _scheduleHideControls();
                      _onUserToggleFullscreen();
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 跳过片头/片尾按钮
  // ============================================================

  Widget _buildSkipButtons() {
    final showIntro =
        widget.skipIntroSeconds > 0 &&
        _position.inSeconds > 0 &&
        _position.inSeconds < widget.skipIntroSeconds;
    final showOutro =
        widget.skipOutroSeconds > 0 &&
        _duration > Duration.zero &&
        _position.inSeconds > _duration.inSeconds - widget.skipOutroSeconds;

    if (!showIntro && !showOutro) return const SizedBox.shrink();

    return Positioned(
      top: 70,
      left: 0,
      right: 0,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            if (showIntro)
              _skipButton(
                text: '跳过片头',
                onTap: _skipIntro,
              ),
            const Spacer(),
            if (showOutro)
              _skipButton(
                text: '跳过片尾',
                onTap: _skipOutro,
              ),
          ],
        ),
      ),
    );
  }

  Widget _skipButton({required String text, required VoidCallback onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.skip_next, color: Colors.white, size: 14),
            const SizedBox(width: 4),
            Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 音量/亮度/进度指示器
  // ============================================================

  Widget _buildVolumeIndicator() {
    return Center(
      child: _IndicatorBadge(
        icon: _volume <= 0
            ? Icons.volume_off
            : (_volume < 0.5 ? Icons.volume_down : Icons.volume_up),
        text: '${(_volume * 100).round()}%',
      ),
    );
  }

  Widget _buildLongPressSpeedHint() {
    final speed = _playbackSpeed * 2;
    final speedLabel = _formatSpeed(speed);
    final locked = _isLongPressSpeedLocked;
    return Positioned(
      top: 48,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.28),
              borderRadius: BorderRadius.circular(24),
              border: locked
                  ? Border.all(color: AppTheme.accentColor, width: 1)
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  speedLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                    letterSpacing: 1.0,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  locked ? '已锁定' : '长按倍速中',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 0.5,
                  height: 12,
                  color: Colors.white.withValues(alpha: 0.35),
                ),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (locked) ...[const Icon(Icons.touch_app, color: Colors.white70, size: 11), const SizedBox(width: 3), const Text('点击解除', style: TextStyle(color: Colors.white70, fontSize: 9))] else ...[const Icon(Icons.arrow_upward, color: Colors.white70, size: 11), const SizedBox(width: 3), const Text('上滑锁定', style: TextStyle(color: Colors.white70, fontSize: 9))],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBrightnessIndicator() {
    return Center(
      child: _IndicatorBadge(
        icon: Icons.brightness_6,
        text: '${(_brightness * 100).round()}%',
      ),
    );
  }

  Widget _buildSeekIndicator(bool isForward) {
    return Positioned.fill(
      child: Row(
        children: [
          if (!isForward)
            Expanded(
              child: Container(
                color: Colors.black.withValues(alpha: 0.3),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        isForward ? Icons.fast_forward : Icons.fast_rewind,
                        color: Colors.white,
                        size: 36,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${isForward ? '快进' : '快退'}${_seekAccumulatedSeconds.abs()}秒',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (isForward)
            Expanded(
              child: Container(
                color: Colors.black.withValues(alpha: 0.3),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.fast_forward,
                        color: Colors.white,
                        size: 36,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '快进${_seekAccumulatedSeconds.abs()}秒',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ============================================================
  // 自定义进度条 - 对应 Swift PlayerProgressBar
  // ============================================================

  Widget _buildProgressBar() {
    final totalMs = _duration.inMilliseconds.toDouble();
    final currentMs = _isDragging
        ? _dragValue
        : _position.inMilliseconds.toDouble();
    final progress = totalMs > 0 ? (currentMs / totalMs).clamp(0.0, 1.0) : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      // 开始时间在进度条起点正下方, 结束时间在终点正下方
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(
              _formatDuration(
                _isDragging
                    ? Duration(milliseconds: _dragValue.round())
                    : _position,
              ),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
              textAlign: TextAlign.left,
            ),
          ),
          Expanded(
            child: SizedBox(
              height: 20,
              child: _ProgressBarGesture(
                progress: progress,
                onSeekToRatio: (ratio) {
                  if (totalMs > 0) {
                    final targetMs = ratio * totalMs;
                    _seekTo(Duration(milliseconds: targetMs.round()));
                  }
                },
                onDrag: (ratio) {
                  setState(() {
                    _isDragging = true;
                    _dragValue = ratio * totalMs;
                  });
                  _scheduleHideControls();
                },
                onDragEnd: () {
                  setState(() => _isDragging = false);
                  _scheduleHideControls();
                  // **修复拖动进度不生效 (2026-09-26)**：松手时用拖动预览值
                  // 真正执行 seek。之前只更新预览位置不跳转，滑动进度无效。
                  if (totalMs > 0) {
                    _seekTo(Duration(milliseconds: _dragValue.round()));
                  }
                },
              ),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              _duration > Duration.zero ? _formatDuration(_duration) : '--:--',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.82),
                fontSize: 11,
                fontFamily: 'monospace',
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 播放/暂停按钮
  // ============================================================

  Widget _buildPlayPauseButton() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _togglePlayPause,
      child: SizedBox(
        width: 42,
        height: 34,
        child: Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: Icon(
              _isPlaying ? Icons.pause : Icons.play_arrow,
              key: ValueKey(_isPlaying),
              color: Colors.white,
              size: 26,
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 时间显示（已移至进度条两端, 此方法保留未再被调用）
  // ============================================================

  Widget _buildTimeView() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _formatDuration(
              _isDragging
                  ? Duration(milliseconds: _dragValue.round())
                  : _position,
            ),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontFamily: 'monospace',
            ),
          ),
          Text(
            _duration > Duration.zero ? _formatDuration(_duration) : '--:--',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.82),
              fontSize: 10,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 倍速菜单（已收进设置弹窗, 保留兼容）
  // ============================================================

  Widget _buildSpeedMenu() {
    final displaySpeed = _isLongPressSpeedLocked
        ? _playbackSpeed * 2
        : _playbackSpeed;
    return PopupMenuButton<double>(
      tooltip: '倍速',
      offset: const Offset(0, -180),
      color: AppTheme.backgroundSecondary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMD),
      ),
      onSelected: (speed) {
        if (_isLongPressSpeedLocked) {
          _unlockLongPressSpeed();
        }
        _setSpeed(speed);
      },
      itemBuilder: (context) => _supportedSpeeds.map((speed) {
        final selected = (speed - _playbackSpeed).abs() < 0.01;
        return PopupMenuItem<double>(
          height: 32,
          value: speed,
          child: Row(
            children: [
              Text(
                _formatSpeed(speed),
                style: TextStyle(
                  color: selected ? AppTheme.accentColor : AppTheme.textPrimary,
                  fontSize: 13,
                ),
              ),
              if (selected) ...[const Spacer(), const Icon(Icons.check, color: AppTheme.accentColor, size: 16)],
            ],
          ),
        );
      }).toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        constraints: const BoxConstraints(minWidth: 38, minHeight: 30),
        child: Center(
          child: Text(
            _formatSpeed(displaySpeed),
            style: TextStyle(
              color: _isLongPressSpeedLocked
                  ? AppTheme.accentColor
                  : Colors.white,
              fontSize: 13,
              fontWeight: _isLongPressSpeedLocked
                  ? FontWeight.w700
                  : FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 画面比例菜单（已收进设置弹窗, 保留兼容）
  // ============================================================

  Widget _buildVideoFitMenu() {
    return PopupMenuButton<VideoFitType>(
      tooltip: '画面比例',
      offset: const Offset(0, -180),
      color: AppTheme.backgroundSecondary,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusMD),
      ),
      onSelected: _setVideoFit,
      itemBuilder: (context) => VideoFitType.values.map((fit) {
        final selected = fit == _videoFit;
        return PopupMenuItem<VideoFitType>(
          height: 32,
          value: fit,
          child: Row(
            children: [
              Text(
                fit.desc,
                style: TextStyle(
                  color: selected ? AppTheme.accentColor : AppTheme.textPrimary,
                  fontSize: 13,
                ),
              ),
              if (selected) ...[const Spacer(), const Icon(Icons.check, color: AppTheme.accentColor, size: 16)],
            ],
          ),
        );
      }).toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        constraints: const BoxConstraints(minWidth: 38, minHeight: 30),
        child: Center(
          child: Text(
            _videoFit.desc,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 剧集选择覆盖层
  // ============================================================

  Widget _buildEpisodeOverlay() {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _showEpisodeSheet = false),
              child: const SizedBox(height: 1, width: double.infinity),
            ),
            Container(
              constraints: const BoxConstraints(maxHeight: 240),
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
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
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () =>
                              setState(() => _showEpisodeSheet = false),
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(
                              Icons.close,
                              color: Colors.white70,
                              size: 18,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: 168,
                    child: GridView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 5,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                            childAspectRatio: 2.5,
                          ),
                      itemCount: widget.episodeNames.length,
                      itemBuilder: (context, index) {
                        final isSelected = index == widget.selectedEpisodeIndex;
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            widget.onSelectEpisode?.call(index);
                            setState(() => _showEpisodeSheet = false);
                          },
                          child: Container(
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? Colors.white.withValues(alpha: 0.25)
                                  : Colors.white.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              widget.episodeNames[index],
                              style: TextStyle(
                                color: isSelected
                                    ? Colors.white
                                    : Colors.white70,
                                fontSize: 13,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 设置弹窗
  // ============================================================

  Widget _buildSettingsSheet() {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _showSettingsSheet = false),
              child: const SizedBox(height: 1, width: double.infinity),
            ),
            Container(
              constraints: const BoxConstraints(maxHeight: 460),
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: const Color(0xE61C1C1E),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                    child: Row(
                      children: [
                        const Text(
                          '播放设置',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () =>
                              setState(() => _showSettingsSheet = false),
                          child: Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.08),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.close,
                              color: Colors.white70,
                              size: 15,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: 340,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _SettingsRowLabel('倍速'),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: _supportedSpeeds.map((s) {
                              final selected = (s - _playbackSpeed).abs() < 0.01;
                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _setSpeed(s),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? AppTheme.accentColor
                                        : Colors.white.withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Text(
                                    _formatSpeed(s),
                                    style: TextStyle(
                                      color: selected
                                          ? Colors.white
                                          : Colors.white70,
                                      fontSize: 12,
                                      fontWeight: selected
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                          const SizedBox(height: 16),
                          const _SettingsRowLabel('画面比例'),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: VideoFitType.values.map((fit) {
                              final selected = fit == _videoFit;
                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _setVideoFit(fit),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? AppTheme.accentColor
                                        : Colors.white.withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  child: Text(
                                    fit.desc,
                                    style: TextStyle(
                                      color: selected
                                          ? Colors.white
                                          : Colors.white70,
                                      fontSize: 12,
                                      fontWeight: selected
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                          const SizedBox(height: 16),
                          const _SettingsRowLabel('跳过片头'),
                          const SizedBox(height: 8),
                          _SkipSecondsEditor(
                            label: '片头',
                            value: widget.skipIntroSeconds,
                            onChange: (v) => widget.onSetSkipIntro?.call(v),
                            presets: _skipPresets,
                            maxSeconds: _skipMaxSeconds,
                          ),
                          const SizedBox(height: 16),
                          const _SettingsRowLabel('跳过片尾'),
                          const SizedBox(height: 8),
                          _SkipSecondsEditor(
                            label: '片尾',
                            value: widget.skipOutroSeconds,
                            onChange: (v) => widget.onSetSkipOutro?.call(v),
                            presets: _skipPresets,
                            maxSeconds: _skipMaxSeconds,
                          ),
                          const SizedBox(height: 16),
                          if (_resolutionText.isNotEmpty) ...[const _SettingsRowLabel('播放信息'), const SizedBox(height: 8), Text('分辨率: $_resolutionText', style: const TextStyle(color: Colors.white70, fontSize: 12)), if (_bitrateText.isNotEmpty) Text('网速: $_bitrateText', style: const TextStyle(color: Colors.white70, fontSize: 12))],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 画中画
  // ============================================================

  Future<void> _togglePiP() async {
    // iOS 端：系统级画中画（双播放器方案）
    if (Platform.isIOS) {
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
      final supported = await VideoPlayerPip.instance.isIosPipSupported();
      if (!supported) {
        _showMessage('当前设备不支持画中画（真机可用）');
        return;
      }
      final playUrl = _player.state.playlist.medias.isNotEmpty
          ? _player.state.playlist.medias.last.uri
          : widget.url;
      if (playUrl.isEmpty) {
        _showMessage('当前没有可用的播放地址');
        return;
      }
      final currentPos = _player.state.position;
      // **手动 PiP v6 (2026-09-27)**：
      // 1) 进入前**短暂暂停主播放器**（释放 AVAudioSession），
      //    让原生 AVPlayer 能更快满足 isPictureInPicturePossible，
      //    修复 iOS 前台手动启动"静默失败/点了没反应"（后台自动路径
      //    不受影响，原生 didEnterBackground 直接启动）。
      // 2) PiP 悬浮窗真实激活（onPipStarted）后保持主播放器暂停，
      //    由系统 AVPlayer 无缝接管画面与声音，切换不断声、不黑屏。
      // 3) 启动失败（含 possible 超时）→ 立即恢复主播放器播放。
      try {
        if (_player.state.playing) {
          _player.pause();
        }
      } catch (_) {}
      final entered = await VideoPlayerPip.instance.enterIos(
        url: playUrl,
        headers: widget.headers,
        position: currentPos,
        onStarted: () {
          // PiP 真实激活 → 主播放器保持暂停，AVPlayer 已接管（无缝）
          if (!mounted) return;
          try {
            if (_player.state.playing) {
              _player.pause();
            }
          } catch (_) {}
        },
        onStopped: () {
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
        try {
          _player.play();
        } catch (_) {}
        _showMessage('画中画启动失败，请稍后重试');
      }
      return;
    }
    if (WindowFullScreen.instance.isActive || _isNativeFullscreen) {
      await _exitFullScreen();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    VideoPlayerPip.instance.attachPlayer(_player);
    await VideoPlayerPip.instance.toggle();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused) {
      _autoEnterPipOnBackground();
    }
  }

  /// iOS：退后台自动进入画中画小窗（静默，失败不打扰用户）
  Future<void> _autoEnterPipOnBackground() async {
    if (!Platform.isIOS) return;
    if (VideoPlayerPip.instance.isIosActive) return;
    if (_autoPipInFlight) return;
    if (!_player.state.playing) return;

    final playUrl = _player.state.playlist.medias.isNotEmpty
        ? _player.state.playlist.medias.last.uri
        : widget.url;
    if (playUrl.isEmpty) return;

    bool supported;
    try {
      supported = await VideoPlayerPip.instance.isIosPipSupported();
    } catch (_) {
      supported = false;
    }
    if (!supported) return;

    _autoPipInFlight = true;
    final currentPos = _player.state.position;
    // **丝滑切换 v2 (2026-09-26)**：退后台自动进 PiP 同样不提前暂停主播放器，
    // AVPlayer 无缝接管；悬浮窗真实激活后暂停主播放器，避免双路声音/无声。
    try {
      final entered = await VideoPlayerPip.instance.enterIos(
        url: playUrl,
        headers: widget.headers,
        position: currentPos,
        onStarted: () {
          // PiP 真实激活 → 立即暂停主播放器，AVPlayer 已接管（无缝）
          if (!mounted) return;
          try {
            if (_player.state.playing) {
              _player.pause();
            }
          } catch (_) {}
        },
        onStopped: () {
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
        try {
          _player.play();
        } catch (_) {}
      }
    } finally {
      _autoPipInFlight = false;
    }
  }

  /// 投屏入口（DLNA/UPnP）
  Future<void> _toggleCast() async {
    final playUrl = _player.state.playlist.medias.isNotEmpty
        ? _player.state.playlist.medias.last.uri
        : widget.url;
    if (playUrl.isEmpty) {
      _showMessage('投屏：当前没有可投屏的视频地址');
      return;
    }
    Get.toNamed(
      '/dlna',
      parameters: {
        'url': playUrl,
        'title': _displayTitle.isNotEmpty
            ? _displayTitle
            : (widget.videoTitle ?? ''),
      },
    );
  }

  /// 用 ScaffoldMessenger 显示一条提示
  void _showMessage(String text) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(text),
        duration: const Duration(seconds: 3),
        backgroundColor: Colors.black87,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ============================================================
  // 通用辅助方法
  // ============================================================

  String get _displayTitle {
    final t = widget.videoTitle ?? '';
    final e = widget.currentEpisodeName ?? '';
    if (e.isNotEmpty) return '$t - $e';
    return t;
  }

  Widget _gradientTopContainer({required Widget child}) {
    final mediaPadding = MediaQuery.of(context).padding;
    // **v8 (2026-09-27)**：恢复"最开始的播放器UI布局"(fd08e78)，
    // 顶栏按钮距底部 30 留白，与底栏间距拉开，不挤在一起。
    final bottomPad = 30.0;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(
          top: 18 + mediaPadding.top,
          left: 8 + mediaPadding.left,
          right: 8 + mediaPadding.right,
          bottom: bottomPad,
        ),
        child: child,
      ),
    );
  }

  Widget _gradientBottomContainer({required Widget child}) {
    final mediaPadding = MediaQuery.of(context).padding;
    // **v8 (2026-09-27)**：恢复"最开始的播放器UI布局"(fd08e78)，
    // 底栏按钮距顶部 26 留白，与顶栏间距拉开，不挤在一起。
    final topPad = 26.0;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black87],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(
          top: topPad,
          bottom: 8 + mediaPadding.bottom,
          left: 8 + mediaPadding.left,
          right: 8 + mediaPadding.right,
        ),
        child: child,
      ),
    );
  }

  Widget _iconButton({
    required IconData icon,
    required double size,
    double width = 36,
    double height = 30,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: width,
        height: height,
        child: Center(
          child: Icon(icon, color: Colors.white, size: size),
        ),
      ),
    );
  }
}

enum PanAxis { horizontal, vertical }

// ============================================================
// 进度条拖动手势
// ============================================================

class _ProgressBarGesture extends StatelessWidget {
  final double progress;
  final void Function(double ratio) onSeekToRatio;
  final void Function(double ratio) onDrag;
  final VoidCallback onDragEnd;

  const _ProgressBarGesture({
    required this.progress,
    required this.onSeekToRatio,
    required this.onDrag,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            final ratio = (details.localPosition.dx / w).clamp(0.0, 1.0);
            onDrag(ratio);
            onSeekToRatio(ratio);
          },
          onHorizontalDragStart: (details) {
            final ratio = (details.localPosition.dx / w).clamp(0.0, 1.0);
            onDrag(ratio);
          },
          onHorizontalDragUpdate: (details) {
            final ratio = (details.localPosition.dx / w).clamp(0.0, 1.0);
            onDrag(ratio);
          },
          onHorizontalDragEnd: (_) => onDragEnd(),
          child: CustomPaint(
            size: Size(w, 26),
            painter: _ProgressBarPainter(progress: progress),
          ),
        );
      },
    );
  }
}

class _ProgressBarPainter extends CustomPainter {
  final double progress;
  _ProgressBarPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    const trackHeight = 3.5;
    const thumbRadius = 7.0;

    final trackRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, centerY - trackHeight / 2, size.width, trackHeight),
      Radius.circular(trackHeight / 2),
    );
    canvas.drawRRect(
      trackRect,
      Paint()..color = Colors.white.withValues(alpha: 0.2),
    );

    if (progress > 0) {
      final progressRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          0,
          centerY - trackHeight / 2,
          size.width * progress,
          trackHeight,
        ),
        Radius.circular(trackHeight / 2),
      );
      canvas.drawRRect(progressRect, Paint()..color = Colors.white);
    }

    final thumbX = (size.width * progress).clamp(
      thumbRadius,
      size.width - thumbRadius,
    );
    canvas.drawCircle(
      Offset(thumbX, centerY),
      thumbRadius,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_ProgressBarPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

// ============================================================
// 通用 UI 组件
// ============================================================

class _IndicatorBadge extends StatelessWidget {
  final IconData icon;
  final String text;
  const _IndicatorBadge({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(40),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 28),
          const SizedBox(height: 6),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _GestureHintBubble extends StatelessWidget {
  final String text;
  const _GestureHintBubble({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

/// 跨 widget rebuild 持久化的 player 状态（静态缓存的值对象）
class _PersistedPlayerState {
  bool isNativeFullscreen = false;
  bool isImmersive = false;
  /// 续播是否已应用：跨 widget Element 重建持久化。
  bool resumeApplied = false;
}

class _SettingsRowLabel extends StatelessWidget {
  final String text;
  const _SettingsRowLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 13,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

/// 跳过片头/片尾时间编辑器
class _SkipSecondsEditor extends StatefulWidget {
  final String label;
  final int value;
  final ValueChanged<int> onChange;
  final List<int> presets;
  final int maxSeconds;

  const _SkipSecondsEditor({
    required this.label,
    required this.value,
    required this.onChange,
    required this.presets,
    required this.maxSeconds,
  });

  @override
  State<_SkipSecondsEditor> createState() => _SkipSecondsEditorState();
}

class _SkipSecondsEditorState extends State<_SkipSecondsEditor> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toString());
    _focusNode = FocusNode();
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        _submit();
      }
    });
  }

  @override
  void didUpdateWidget(covariant _SkipSecondsEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !_focusNode.hasFocus) {
      _controller.text = widget.value.toString();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      _controller.text = widget.value.toString();
      setState(() => _errorText = null);
      return;
    }
    final n = int.tryParse(text);
    if (n == null) {
      setState(() => _errorText = '请输入数字');
      return;
    }
    if (n < 0) {
      setState(() => _errorText = '不能小于 0');
      return;
    }
    if (n > widget.maxSeconds) {
      setState(() => _errorText = '不能超过 ${widget.maxSeconds} 秒');
      return;
    }
    setState(() => _errorText = null);
    if (n != widget.value) {
      widget.onChange(n);
    }
  }

  void _applyPreset(int s) {
    _controller.text = s.toString();
    setState(() => _errorText = null);
    widget.onChange(s);
    _focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _errorText != null
                        ? Colors.red
                        : Colors.white.withValues(alpha: 0.1),
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Icon(
                        Icons.timer_outlined,
                        color: Colors.white70,
                        size: 16,
                      ),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.done,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                        cursorColor: AppTheme.accentColor,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 10),
                          isDense: true,
                          hintText: '秒',
                          hintStyle: TextStyle(
                            color: Colors.white24,
                            fontSize: 14,
                          ),
                        ),
                        onSubmitted: (_) {
                          _submit();
                          _focusNode.unfocus();
                        },
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        '秒',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _submit();
                _focusNode.unfocus();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.accentColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '应用',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
        if (_errorText != null) ...[const SizedBox(height: 4), Text(_errorText!, style: const TextStyle(color: Colors.red, fontSize: 11))],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: widget.presets.map((s) {
            final selected = widget.value == s;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _applyPreset(s),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: selected
                      ? AppTheme.accentColor
                      : Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  s == 0 ? '关闭' : '${s}秒',
                  style: TextStyle(
                    color: selected ? Colors.white : Colors.white70,
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

/// 听剧模式旋转音乐图标（装饰动画）
class _PipAudioModeMusicIcon extends StatefulWidget {
  final double size;
  final Color color;

  const _PipAudioModeMusicIcon({
    required this.size,
    required this.color,
  });

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
      duration: const Duration(seconds: 2),
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
      child: Icon(
        Icons.graphic_eq,
        size: widget.size,
        color: widget.color,
      ),
    );
  }
}

// ============================================================
// 弹幕（Logvr-danmu / 弹弹play / B站 XML 兼容解析与渲染）
// ============================================================

class _DanmuItem {
  final double time; // 秒
  final String text;
  final Color color;
  final int mode; // 1 滚动, 4 顶部, 5 底部
  _DanmuItem(this.time, this.text, this.color, this.mode);
}

/// 解析弹幕响应体：兼容
/// - Logvr-danmu / 弹弹play JSON（data 数组, 元素含 p/m 或 time/text 或 timepoint/ct/content 或 progress/mode/content）
/// - B站 XML（<d p="...">text</d>）
List<_DanmuItem> parseDanmuBody(String body) {
  final items = <_DanmuItem>[];
  try {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return items;
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      final decoded = jsonDecode(trimmed);
      List<dynamic> arr = [];
      if (decoded is List) {
        arr = decoded;
      } else if (decoded is Map) {
        if (decoded['data'] is List) arr = decoded['data'] as List;
        else if (decoded['comments'] is List) arr = decoded['comments'] as List;
        else if (decoded['danmaku'] is List) arr = decoded['danmaku'] as List;
      }
      for (final e in arr) {
        if (e is! Map) continue;
        double? t;
        String? text;
        var color = 0xFFFFFFFF;
        var mode = 1;
        // 新格式 progress/mode/content
        if (e['progress'] is num) t = (e['progress'] as num) / 1000.0;
        // DPlayer time/text
        if (e['time'] is num) t = (e['time'] as num).toDouble();
        if (e['time'] is String) t = double.tryParse(e['time'] as String);
        // 弹弹play t（毫秒）/ timepoint
        if (e['t'] is num) t = (e['t'] as num).toDouble();
        if (e['timepoint'] is num) t = (e['timepoint'] as num).toDouble();
        // p 属性（弹弹play: 时间,模式,颜色,...）
        final p = e['p'];
        if (p is String) {
          final parts = p.split(',');
          if (parts.isNotEmpty) {
            final pt = double.tryParse(parts[0].trim());
            if (pt != null) t = pt;
          }
          if (parts.length > 1) mode = int.tryParse(parts[1].trim()) ?? mode;
          if (parts.length > 2) {
            final c = int.tryParse(parts[2].trim());
            if (c != null) color = c | 0xFF000000;
          }
        }
        if (e['mode'] is num) mode = (e['mode'] as num).toInt();
        if (e['ct'] is num) mode = (e['ct'] as num).toInt();
        if (e['color'] is num) color = ((e['color'] as num).toInt() & 0xFFFFFF) | 0xFF000000;
        text = e['text']?.toString() ?? e['m']?.toString() ?? e['content']?.toString() ?? e['c']?.toString();
        if (t != null && text != null && text.isNotEmpty) {
          items.add(_DanmuItem(t, text, Color(color), mode));
        }
      }
    } else if (trimmed.startsWith('<')) {
      // B站 XML
      final re = RegExp(r'<d p="([^"]+)">([^<]+)</d>');
      for (final m in re.allMatches(trimmed)) {
        final parts = m.group(1)!.split(',');
        final t = double.tryParse(parts[0]);
        final mode = parts.length > 1 ? (int.tryParse(parts[1]) ?? 1) : 1;
        var color = 0xFFFFFFFF;
        if (parts.length > 3) {
          final c = int.tryParse(parts[3]);
          if (c != null) color = c | 0xFF000000;
        }
        if (t != null) items.add(_DanmuItem(t, m.group(2)!, Color(color), mode));
      }
    }
  } catch (_) {}
  return items;
}

class _ActiveDanmu {
  final _DanmuItem item;
  int track;
  double x; // 滚动弹幕当前 x
  double width;
  bool topFixed;
  bool bottomFixed;
  double remaining; // 顶部/底部固定显示剩余秒
  _ActiveDanmu(
    this.item, {
    this.track = 0,
    this.x = 0,
    this.width = 0,
    this.topFixed = false,
    this.bottomFixed = false,
    this.remaining = 4.0,
  });
}

/// 弹幕渲染层：按当前播放位置发射弹幕, 滚动/顶部/底部
class _DanmuLayer extends StatefulWidget {
  final List<_DanmuItem> danmus;
  final Duration Function() positionOf;
  const _DanmuLayer({required this.danmus, required this.positionOf});

  @override
  State<_DanmuLayer> createState() => _DanmuLayerState();
}

class _DanmuLayerState extends State<_DanmuLayer> {
  late List<_DanmuItem> _sorted;
  final List<_ActiveDanmu> _active = [];
  int _nextIndex = 0;
  int _nextTrack = 0;
  Timer? _timer;
  static const double _speed = 150.0; // px/s

  @override
  void initState() {
    super.initState();
    _sorted = List<_DanmuItem>.of(widget.danmus)
      ..sort((a, b) => a.time.compareTo(b.time));
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      final pos = widget.positionOf().inMilliseconds / 1000.0;
      while (_nextIndex < _sorted.length &&
          _sorted[_nextIndex].time <= pos + 0.25) {
        _spawn(_sorted[_nextIndex]);
        _nextIndex++;
      }
      for (final a in _active) {
        if (a.item.mode == 1) {
          a.x -= _speed * 0.1;
        } else {
          a.remaining -= 0.1;
        }
      }
      _active.removeWhere(
          (a) => a.item.mode == 1 ? a.x + a.width < -16 : a.remaining <= 0);
      setState(() {});
    });
  }

  void _spawn(_DanmuItem item) {
    if (item.mode == 4) {
      _active.add(_ActiveDanmu(item, topFixed: true));
    } else if (item.mode == 5) {
      _active.add(_ActiveDanmu(item, bottomFixed: true));
    } else {
      _active.add(_ActiveDanmu(item, track: _nextTrack));
      _nextTrack = (_nextTrack + 1) % 4;
    }
  }

  double _textWidth(String text, double fontSize) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w500),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;
          for (final a in _active) {
            if (a.item.mode == 1) {
              a.width = _textWidth(a.item.text, 14);
              if (a.x == 0) a.x = w.toDouble();
            }
          }
          return Stack(
            clipBehavior: Clip.none,
            children: [
              for (final a in _active)
                Positioned(
                  left: a.item.mode == 1 ? a.x : 0,
                  top: a.item.mode == 1
                      ? 12.0 + a.track * 28.0
                      : (a.topFixed ? 12.0 : h - 34.0),
                  child: Text(
                    a.item.text,
                    style: TextStyle(
                      color: a.item.color,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      shadows: const [
                        Shadow(blurRadius: 2, color: Colors.black87),
                      ],
                    ),
                    maxLines: 1,
                    softWrap: false,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
