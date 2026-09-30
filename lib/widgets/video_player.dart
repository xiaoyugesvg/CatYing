import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../services/app_log.dart';
import 'app_player.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart' show DragToMoveArea;
import '../common/theme.dart';
import 'video_player_pip.dart';
import 'window_fullscreen.dart';
import 'danmaku.dart';
part 'video_player_helpers.dart';

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
  final AppPlayer? player;

  /// 外部注入的 VideoController 实例（与 [player] 配套使用）。
  final AppPlayer? controller; // 兼容旧参数，已由 [player] 承载

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

  /// 顶部按钮栏距顶部的额外间距（默认 8，详情页可传大一点让按钮往下挪）
  final double topBarTopPadding;

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
    this.topBarTopPadding = 8.0,
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
  late final AppPlayer _player;
  late final AppPlayer _controller; // 与 _player 同一实例
  bool _ownsPlayer = false; // 是否自己创建并需要释放

  /// 跨 widget rebuild 持久化的状态缓存（按 widget.key 区分）。
  static final Map<String, _PersistedPlayerState> _stateCache =
      <String, _PersistedPlayerState>{};

  late final _PersistedPlayerState _persisted;
  late final String _cacheKey;

  bool _isPlaying = false;

  /// iOS 自动画中画进行中（防止退后台重复触发）
  bool _autoPipInFlight = false;

  /// 系统画中画激活中（App 内显示「正在画中画」）
  bool _pipActive = false;

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

  // 弹幕（Logvr-danmu / 弹弹play 兼容）
  List<DanmuItem> _danmus = [];
  bool _danmuOn = true;
  bool _danmuLoaded = false;
  String _danmuApiUrl = '';
  /// 弹幕拉取代次：换集时递增，过期响应直接丢弃
  int _danmuLoadGen = 0;
  double _danmuFontSize = 14;
  double _danmuOpacity = 1;
  double _danmuSpeed = 150;
  int _danmuTracks = 4;
  List<String> _danmuBlockWords = [];
  late VideoFitType _videoFit;
  double _volume = 1.0;
  // 应用内亮度遮罩：1.0 = 不遮（系统亮度）。默认不要半黑。
  double _brightness = 1.0;

  /// 内部追踪 native fullscreen 状态（与 mpv / OS 窗口同步）
  bool _isNativeFullscreen = false;

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

  /// player.stream 订阅统一持有，dispose 时取消，避免外部注入 Player 时泄漏
  final List<StreamSubscription<dynamic>> _playerSubs = [];

  /// 播放进度 / 总时长：高频更新走 ValueNotifier，避免 position stream 触发整树 setState
  final ValueNotifier<Duration> _positionVN = ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> _durationVN = ValueNotifier(Duration.zero);

  /// 上次回调 onPositionChanged 的秒，节流上层（历史落盘等）
  int _lastNotifiedPositionSec = -1;

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
      _player = AppPlayer(config: const AppConfig(title: 'TVBox'));
      _ownsPlayer = true;
    }
    _controller = _player;

    // 同步读取 player 真实状态，避免全屏/普通模式切换时新实例显示"转圈"假象
    _isPlaying = _player.state.playing;
    _isBuffering = _player.state.buffering;
    _position = _player.state.position;
    _duration = _player.state.duration;
    _positionVN.value = _position;
    _durationVN.value = _duration;
    _playbackSpeed = _player.state.rate;

    _playerSubs.add(_player.stream.error.listen((error) {
      if (error.isNotEmpty) widget.onError?.call();
    }));

    _playerSubs.add(_player.stream.playing.listen((playing) {
      if (mounted) {
        setState(() {
          _isPlaying = playing;
          _isBuffering = false;
          // 暂停时常显控制条；开播后再按空闲隐藏
          if (!playing) {
            _showControls = true;
          }
        });
        if (playing) {
          _scheduleHideControls();
          widget.onPlaying?.call();
          _applyPendingResumeSeek();
          // Spider 异步解析 URL 后才可匹配弹幕：开播时再试一次
          if (!_danmuLoaded && _danmuApiUrl.isNotEmpty) {
            _ensureDanmuLoaded();
          }
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
    }));

    _playerSubs.add(_player.stream.buffering.listen((buffering) {
      if (!mounted) return;
      // 换集后 buffering=true 时必须能显示转圈，不能被旧的 _isPlaying/_position 挡住
      if (buffering != _isBuffering) {
        setState(() => _isBuffering = buffering);
      }
    }));

    // 进度：只更新 ValueNotifier（进度条/时间局部重建），
    // 仅在跳过片头/片尾按钮可见性变化时才整树 setState
    _playerSubs.add(_player.stream.position.listen((position) {
      if (!mounted) return;
      _position = position;
      _positionVN.value = position;
      if (_isBuffering && position > Duration.zero) {
        _isBuffering = false;
      }
      final sec = position.inSeconds;
      if (sec != _lastNotifiedPositionSec) {
        final prevSkip = _skipVisibilityFor(
            _lastNotifiedPositionSec < 0 ? -1 : _lastNotifiedPositionSec);
        final nextSkip = _skipVisibilityFor(sec);
        _lastNotifiedPositionSec = sec;
        if (prevSkip != nextSkip) {
          setState(() {});
        }
        widget.onPositionChanged?.call(position);
      }
    }));

    _playerSubs.add(_player.stream.duration.listen((duration) {
      if (!mounted) return;
      _duration = duration;
      _durationVN.value = duration;
      setState(() {});
    }));

    _playerSubs.add(_player.stream.completed.listen((completed) {
      if (completed) widget.onEnded?.call();
    }));

    _volume = _player.state.volume;
    if (_ownsPlayer) {
      _openMedia();
    } else {
      // 外部注入 player（detail view 的常规路径）：build 期间 _ensurePlayer
      // 已经调过 `_player.open(AppMedia(url, httpHeaders: headers, start: ...))`，
      // libmpv 会直接从续播位置开始解码。这里 _scheduleResumeSeek 只作
      // safety net：如果 Media.start 失效，state.playing listener 会兜底 seek
      if (_persisted.resumeApplied) {
        AppLog.instance.log('=== initState: 续播已应用 (widget 重建), 跳过 ===');
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

  /// 延迟重建 Video widget，绕过 ANGLE surface 重建竞态。
  /// 用代次丢弃过期回调，避免多次切换叠多轮 rebuild。
  int _delayedRebuildGen = 0;

  void _scheduleDelayedRebuild() {
    final gen = ++_delayedRebuildGen;
    for (final delayMs in const [80, 250]) {
      Future<void>.delayed(Duration(milliseconds: delayMs), () {
        if (!mounted || gen != _delayedRebuildGen) return;
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
      } catch (e) {
        AppLog.instance.log('[video_player] swallowed: $e');
      }
      _batteryStateSub = battery.onBatteryStateChanged.listen((state) async {
        if (!mounted) return;
        setState(() => _batteryState = state);
        try {
          final lvl = await battery.batteryLevel;
          if (!mounted) return;
          setState(() => _batteryLevel = lvl);
        } catch (e) {
        AppLog.instance.log('[video_player] swallowed: $e');
      }
      });
    } catch (e) {
      AppLog.instance.log('=== _initBatteryMonitor: 失败: $e ===');
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
    // Player 实例变化时 State 不支持热切换（_player 为 late final）。
    // 调用方请用 ObjectKey(player) 驱动 remount；这里仅处理 URL/续播参数。
    if (oldWidget.url != widget.url) {
      if (_isLongPressSpeedLocked || _isLongPressingFast) {
        setState(() {
          _isLongPressSpeedLocked = false;
          _isLongPressingFast = false;
        });
        try {
          _player.setRate(_playbackSpeed);
        } catch (e) {
        AppLog.instance.log('[video_player] swallowed: $e');
      }
      }
      // 换集/换源：清掉上一集的进度与缓冲态，避免进度条/转圈残留
      _pendingResumeSeconds = null;
      _lastNotifiedPositionSec = -1;
      // 弹幕跟随剧集：清空并重新按新 URL 拉取（否则 _danmuLoaded 卡住永远不换）
      _danmuLoaded = false;
      _danmuLoadGen++;
      _danmus = [];
      setState(() {
        _position = Duration.zero;
        _duration = Duration.zero;
        _positionVN.value = Duration.zero;
        _durationVN.value = Duration.zero;
        _isBuffering = true;
      });
      if (_danmuApiUrl.isNotEmpty) {
        _ensureDanmuLoaded();
      }
      if (_ownsPlayer) {
        _openMedia();
      } else {
        // 外部 Player：父级已 open()，这里重置续播标记后再兜底 seek
        _persisted.resumeApplied = false;
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
    _player.open(AppMedia(widget.url, httpHeaders: headers, start: start));
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
        AppLog.instance.log(
            '=== _scheduleResumeSeek: cur=$cur > target=$target, 用户已观看, 跳过 ===');
        _pendingResumeSeconds = null;
        return;
      }
    } catch (e) {
        AppLog.instance.log('[video_player] swallowed: $e');
      }
    _pendingResumeSeconds = resume;
    try {
      _player.seek(target);
      AppLog.instance.log('=== _scheduleResumeSeek: 立即 seek 到 ${resume}s ===');
    } catch (e) {
      AppLog.instance.log('=== _scheduleResumeSeek: 立即 seek 失败: $e ===');
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
        AppLog.instance.log(
            '=== _applyPendingResumeSeek: cur=$cur > target=$target, 用户已观看, 跳过 ===');
        _pendingResumeSeconds = null;
        return;
      }
      if ((cur - target).abs() < const Duration(seconds: 2)) {
        AppLog.instance.log('=== _applyPendingResumeSeek: 已在 $pending 附近, 跳过 ===');
        _pendingResumeSeconds = null;
        return;
      }
    } catch (e) {
        AppLog.instance.log('[video_player] swallowed: $e');
      }
    _pendingResumeSeconds = null;
    try {
      _player.seek(target);
      AppLog.instance.log('=== _applyPendingResumeSeek: 兜底 seek 到 ${pending}s ===');
    } catch (e) {
      AppLog.instance.log('=== _applyPendingResumeSeek: 兜底 seek 失败: $e ===');
    }
  }

  /// 读取弹幕配置（设置页配置的 Logvr-danmu / 弹弹play 兼容 API 地址）
  Future<void> _loadDanmuSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _danmuApiUrl = (prefs.getString('danmu_api_url') ?? '').trim();
      _danmuOn = prefs.getBool('danmu_enabled') ?? true;
      _danmuFontSize = (prefs.getDouble('danmu_font_size') ?? 14).clamp(10.0, 28.0);
      _danmuOpacity = (prefs.getDouble('danmu_opacity') ?? 1).clamp(0.2, 1.0);
      _danmuSpeed = (prefs.getDouble('danmu_speed') ?? 150).clamp(80.0, 240.0);
      _danmuTracks = (prefs.getInt('danmu_tracks') ?? 4).clamp(2, 8);
      _danmuBlockWords =
          prefs.getStringList('danmu_block_words') ?? const [];
      if (mounted) setState(() {});
      if (_danmuApiUrl.isNotEmpty) {
        _ensureDanmuLoaded();
      }
    } catch (e) {
        AppLog.instance.log('[video_player] swallowed: $e');
      }
  }

  /// 通过视频 URL 直接匹配弹幕（Logvr-danmu 的 /api/v2/comment?url= 接口）

  /// Logvr-danmu 基址归一化：
  /// 支持 `host` / `host/{TOKEN}` / `host/{TOKEN}/api/v2`，最终用于拼 `/api/v2/...`
  String _danmuApiBase() {
    var b = _danmuApiUrl.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    if (b.endsWith('/api/v2')) {
      b = b.substring(0, b.length - '/api/v2'.length);
    }
    return b;
  }

  Future<void> _ensureDanmuLoaded() async {
    if (_danmuLoaded || _danmuApiUrl.isEmpty) return;
    _danmuLoaded = true;
    final loadGen = ++_danmuLoadGen;
    final url = _player.state.playlist.medias.isNotEmpty
        ? _player.state.playlist.medias.last.uri
        : widget.url;
    if (url.isEmpty) return;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8);
    try {
      final base = _danmuApiBase();
      final api =
          '$base/api/v2/comment?url=${Uri.encodeQueryComponent(url)}&format=json';
      final http = await client
          .getUrl(Uri.parse(api))
          .timeout(const Duration(seconds: 12));
      http.headers.set('User-Agent', 'NewTv/1.0');
      final res =
          await http.close().timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        final body = await res
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 12));
        var list = parseDanmuBody(body);
        if (_danmuBlockWords.isNotEmpty) {
          list = list
              .where((d) => !_danmuBlockWords
                  .any((w) => w.isNotEmpty && d.text.contains(w)))
              .toList();
        }
        // 代次校验：快速换集时丢弃过期响应，避免旧集弹幕盖到新集上
        if (mounted && list.isNotEmpty && loadGen == _danmuLoadGen) {
          setState(() => _danmus = list);
        }
      } else if (loadGen == _danmuLoadGen) {
        // 失败允许下次换集重试
        _danmuLoaded = false;
      }
    } catch (e) {
      if (loadGen == _danmuLoadGen) {
        _danmuLoaded = false;
      }
    } finally {
      client.close(force: true);
    }
  }

  /// 持久化弹幕开关
  Future<void> _persistDanmuStyle() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('danmu_font_size', _danmuFontSize);
      await prefs.setDouble('danmu_opacity', _danmuOpacity);
      await prefs.setInt('danmu_tracks', _danmuTracks);
      await prefs.setDouble('danmu_speed', _danmuSpeed);
    } catch (e) {
      AppLog.instance.log('[video_player] persist danmu style: $e');
    }
  }

  /// 发送弹幕到配置的 API（Logvr-danmu / 自定义 POST）
  Future<void> _showSendDanmuDialog() async {
    if (_danmuApiUrl.isEmpty) {
      _showMessage('请先在设置里配置弹幕 API');
      return;
    }
    final ctrl = TextEditingController();
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('发送弹幕', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 40,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: '输入弹幕内容…',
            hintStyle: TextStyle(color: Colors.white38),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () async {
              final text = ctrl.text.trim();
              Navigator.pop(ctx);
              if (text.isEmpty) return;
              await _sendDanmu(text);
            },
            child: const Text('发送',
                style: TextStyle(color: AppTheme.accentColor)),
          ),
        ],
      ),
    );
  }

  Future<void> _sendDanmu(String text) async {
    try {
      final base = _danmuApiBase();
      final videoUrl = _player.state.playlist.medias.isNotEmpty
          ? _player.state.playlist.medias.last.uri
          : widget.url;
      final t = _player.state.position.inMilliseconds / 1000.0;
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
      // Logvr-danmu / 同类服务：字段名不一，一次带上常用别名
      final payload = <String, dynamic>{
        'url': videoUrl,
        'video_url': videoUrl,
        'uri': videoUrl,
        'text': text,
        'content': text,
        'm': text,
        'time': t,
        't': (t * 1000).round(),
        'progress': (t * 1000).round(),
        'mode': 1,
        'color': 0xFFFFFF,
        'p': '$t,1,16777215,${DateTime.now().millisecondsSinceEpoch}',
      };
      final endpoints = <String>[
        '$base/api/v2/comment',
        '$base/api/comment',
        '$base/api/v2/send',
      ];
      int? code;
      String lastBody = '';
      for (final ep in endpoints) {
        try {
          final req = await client
              .postUrl(Uri.parse(ep))
              .timeout(const Duration(seconds: 8));
          req.headers.contentType = ContentType.json;
          req.headers.set('User-Agent', 'NewTv/1.0');
          req.write(jsonEncode(payload));
          final res = await req.close().timeout(const Duration(seconds: 8));
          lastBody = await res.transform(utf8.decoder).join();
          code = res.statusCode;
          if (res.statusCode >= 200 && res.statusCode < 300) {
            break;
          }
        } catch (e) {
          AppLog.instance.log('[video_player] send try $ep: $e');
        }
      }
      client.close(force: true);
      if (code != null && code >= 200 && code < 300) {
        _showMessage('弹幕已发送');
        setState(() {
          _danmus = [
            ..._danmus,
            DanmuItem(t, text, const Color(0xFFFFFFFF), 1),
          ];
        });
      } else {
        // Logvr-danmu / danmu_api 均为只读弹幕服务（只有 /api/v2/comment 获取接口，
        // 无发送接口）。明确提示"不支持发送"，而不是报 404/500 让用户误以为网络问题。
        _showMessage('当前弹幕服务不支持发送弹幕（仅支持获取）');
      }
    } catch (e) {
      AppLog.instance.log('[video_player] send danmu fail: $e');
      _showMessage('发送失败');
    }
  }

  Future<void> _persistDanmuOn() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('danmu_enabled', _danmuOn);
    } catch (e) {
        AppLog.instance.log('[video_player] swallowed: $e');
      }
  }

  void _startBitrateTimer() {
    _bitrateTimer?.cancel();
    _bitrateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (!_player.state.playing && _resolutionText.isEmpty) return;
      final beforeRes = _resolutionText;
      final beforeRate = _bitrateText;
      _updateResolutionFromTrack();
      if (_resolutionText != beforeRes || _bitrateText != beforeRate) {
        setState(() {});
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
    // 不写死假码率；media_kit 未暴露 estimated-bitrate 时保持空串
    _bitrateText = '';
  }

  /// 唤醒控制条，并在空闲后自动隐藏
  void _scheduleHideControls() {
    _hideTimer?.cancel();
    if (_isLocked || _showEpisodeSheet) {
      _showControls = _isLocked || true;
      return;
    }
    _hideTimer = Timer(_hideDelay, () {
      if (!mounted) return;
      if (_isDragging || _showEpisodeSheet) {
        _scheduleHideControls();
        return;
      }
      // 暂停/缓冲中保持控制条可见，避免只剩纹理灰屏、看起来像「播放器坏了」
      if (!_isPlaying || _isBuffering) {
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
    AppLog.instance.log(
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
    AppLog.instance.log(
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
      AppLog.instance.log('=== _enterFullScreen: skip (已处于全屏) ===');
      return;
    }
    AppLog.instance.log('=== _enterFullScreen: start ===');
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
      AppLog.instance.log('=== _enterFullScreen: WindowFullScreen enter OK ===');
    } catch (e) {
      AppLog.instance.log('=== _enterFullScreen: WindowFullScreen enter failed: $e ===');
    }
    if (mounted) _onWindowFullScreenChanged();
    try {
      if (!_player.state.playing) {
        await _player.play();
      }
    } catch (e) {
        AppLog.instance.log('[video_player] swallowed: $e');
      }
  }

  /// 调 WindowFullScreen 退出全屏
  Future<void> _exitFullScreen() async {
    if (!WindowFullScreen.instance.isActive && !_isImmersive) {
      AppLog.instance.log('=== _exitFullScreen: skip (不在全屏) ===');
      return;
    }
    AppLog.instance.log('=== _exitFullScreen: start ===');
    _isImmersive = false;
    _isNativeFullscreen = false;
    _persisted.isImmersive = false;
    _persisted.isNativeFullscreen = false;
    widget.onFullScreenChanged?.call(false);
    try {
      await WindowFullScreen.instance.exit();
      AppLog.instance.log('=== _exitFullScreen: WindowFullScreen exit OK ===');
    } catch (e) {
      AppLog.instance.log('=== _exitFullScreen: WindowFullScreen exit failed: $e ===');
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
    } catch (e) {
        AppLog.instance.log('[video_player] swallowed: $e');
      }
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
    for (final sub in _playerSubs) {
      sub.cancel();
    }
    _playerSubs.clear();
    _hideTimer?.cancel();
    _bitrateTimer?.cancel();
    _indicatorTimer?.cancel();
    _timeTimer?.cancel();
    _batteryStateSub?.cancel();
    _positionVN.dispose();
    _durationVN.dispose();
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
    return Stack(
      fit: StackFit.expand,
      children: [
        // 视频画面 — 外层强制黑底，纹理未就绪时不会露出系统灰/页面背景
        Positioned.fill(
          child: ColoredBox(
            color: Colors.black,
            child: AppVideoView(
              key: ValueKey('video_$_videoRebuildKey'),
              player: _player,
              fit: _videoFit.boxFit,
              aspectRatio: _videoFit.aspectRatio,
            ),
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
        // 缓冲圈：buffering 时显示（换集后旧状态不再挡转圈）
        if (_isBuffering && !_audioMode)
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
        // 顶栏与进度条同步显隐
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

        // 听剧模式覆盖层（隐藏画面、保留音频）
        if (_audioMode) _buildAudioModeOverlay(),
        // 系统画中画进行中：App 内提示 + 一键回到 App 内播放
        if (_pipActive) _buildPipActiveOverlay(),
      ],
    );
  }

  /// 「正在画中画」覆盖层
  Widget _buildPipActiveOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.55),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.picture_in_picture_alt,
                color: Colors.white70, size: 40),
            const SizedBox(height: 12),
            const Text(
              '正在画中画',
              style: TextStyle(color: Colors.white, fontSize: 15),
            ),
            const SizedBox(height: 6),
            Text(
              '小窗播放中，回到 App 可继续控制',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6), fontSize: 12),
            ),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: _togglePiP,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Text('回到 App 内播放',
                    style: TextStyle(color: Colors.white, fontSize: 13)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 弹幕层
  // ============================================================

  Widget _buildDanmuLayer() {
    return DanmuLayer(
      danmus: _danmus,
      positionOf: () => _player.state.position,
      fontSize: _danmuFontSize,
      opacity: _danmuOpacity,
      speed: _danmuSpeed,
      trackCount: _danmuTracks,
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
              _gestureSeekStartMs = _position.inMilliseconds.toDouble();
              _gestureSeekTemp = _gestureSeekStartMs;
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
                  // 目标 = 起点 + 本次累计位移；dx 已是从起点的累计值
                  _gestureSeekTemp =
                      (_gestureSeekStartMs + deltaMs).clamp(0.0, totalMs);
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
  /// 水平拖动 seek：手势起点的进度（ms）。拖动中目标 = 本值 + 累计位移换算，
  /// 不能对 _gestureSeekTemp 逐帧累加累计 delta（会变成平方漂移）。
  double _gestureSeekStartMs = 0;

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

  /// 顶栏按钮统一入口：避免 AVPlayer 路径异常把点击吞掉
  void _safeTap(FutureOr<void> Function() action) {
    _scheduleHideControls();
    Future<void>(() async {
      try {
        await action();
      } catch (e, st) {
        AppLog.instance.log('[video_player] tap failed: $e\n$st');
      }
    });
  }

  Widget _buildHeaderBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: _gradientTopContainer(
        child: Row(
          children: [
            // 返回与右侧功能键同一行（尺寸对齐直播页 38×38）
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onBack ?? () => Navigator.of(context).maybePop(),
              child: const SizedBox(
                width: 38,
                height: 38,
                child: Center(
                  child: Icon(
                    Icons.arrow_back_ios_new,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ),
            const Spacer(),

            // 听剧模式（仅点播页显示）
            if (widget.showAudioModeButton)
              _iconButton(
                icon: _audioMode ? Icons.headphones : Icons.headphones_outlined,
                size: 20,
                width: 36,
                onTap: () => _safeTap(_toggleAudioMode),
              ),

            // 弹幕开关（设置里配置弹幕 API 后显示）
            if (_danmuApiUrl.isNotEmpty)
              _iconButton(
                icon: _danmuOn ? Icons.subtitles : Icons.subtitles_off,
                size: 20,
                width: 36,
                onTap: () => _safeTap(() async {
                  setState(() => _danmuOn = !_danmuOn);
                  await _persistDanmuOn();
                }),
              ),

            // 画中画
            _iconButton(
              icon: Icons.picture_in_picture_alt,
              size: 20,
              width: 36,
              onTap: () => _safeTap(_togglePiP),
            ),

            // 投屏（AirPlay / DLNA 入口）
            _iconButton(
              icon: Icons.cast,
              size: 20,
              width: 36,
              onTap: () => _safeTap(_toggleCast),
            ),

            if (_isNativeFullscreen) ...[const SizedBox(width: 4), _buildStatusBarInfo()],

            // 设置
            _iconButton(
              icon: Icons.more_horiz,
              size: 22,
              width: 40,
              onTap: () => _safeTap(_openSettingsSheet),
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
      // 控件区整体下移一点，避免贴死画面底边
      bottom: 2,
      left: 0,
      right: 0,
      child: _gradientBottomContainer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildProgressBar(),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 5),
              child: Row(
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
                  // 播放设置入口仅保留标题栏右上角「…」，底部不放齿轮
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

  /// 跳过按钮可见性（0=无，1=片头，2=片尾，3=两者）
  int _skipVisibilityFor(int posSec) {
    if (posSec < 0) return 0;
    final showIntro = widget.skipIntroSeconds > 0 &&
        posSec > 0 &&
        posSec < widget.skipIntroSeconds;
    final showOutro = widget.skipOutroSeconds > 0 &&
        _duration > Duration.zero &&
        posSec > _duration.inSeconds - widget.skipOutroSeconds;
    return (showIntro ? 1 : 0) | (showOutro ? 2 : 0);
  }

  Widget _buildSkipButtons() {
    final vis = _skipVisibilityFor(_position.inSeconds);
    final showIntro = vis & 1 != 0;
    final showOutro = vis & 2 != 0;

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
    // 进度条/时间只响应 position/duration 变化，不随整树 setState 重建
    return ListenableBuilder(
      listenable: Listenable.merge([_positionVN, _durationVN]),
      builder: (context, _) {
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
                fontSize: 10,
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
                fontSize: 10,
                fontFamily: 'monospace',
              ),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
        );
      },
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
    return ListenableBuilder(
      listenable: Listenable.merge([_positionVN, _durationVN]),
      builder: (context, _) {
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
      },
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

  /// 打开播放设置 — 标准底部弹出：从下往上、不透明、可点外部/关闭/下滑关闭
  void _openSettingsSheet() {
    _scheduleHideControls();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      // 面板本体不透明；遮罩用 barrierColor
      backgroundColor: const Color(0xFF1E1E1E),
      barrierColor: Colors.black.withValues(alpha: 0.55),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            void refresh(VoidCallback fn) {
              setSheetState(fn);
              if (mounted) setState(() {});
            }

            return SafeArea(
              top: false,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.72,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 拖拽条
                    const SizedBox(height: 8),
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                      child: Row(
                        children: [
                          const Text(
                            '播放设置',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            onPressed: () => Navigator.of(sheetContext).pop(),
                            icon: const Icon(
                              Icons.close,
                              color: Colors.white70,
                              size: 20,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Expanded(
                                  child: _SettingsRowLabel('弹幕'),
                                ),
                                Switch(
                                  value: _danmuOn,
                                  activeColor: AppTheme.accentColor,
                                  onChanged: (v) {
                                    refresh(() {
                                      _danmuOn = v;
                                    });
                                    _persistDanmuOn();
                                  },
                                ),
                              ],
                            ),
                            if (_danmuOn) ...[
                              const SizedBox(height: 4),
                              _DanmuSliderRow(
                                label: '字号 ${_danmuFontSize.round()}',
                                value: _danmuFontSize,
                                min: 10,
                                max: 28,
                                onChanged: (v) {
                                  refresh(() => _danmuFontSize = v);
                                  _persistDanmuStyle();
                                },
                              ),
                              _DanmuSliderRow(
                                label:
                                    '透明度 ${(_danmuOpacity * 100).round()}%',
                                value: _danmuOpacity,
                                min: 0.2,
                                max: 1,
                                onChanged: (v) {
                                  refresh(() => _danmuOpacity = v);
                                  _persistDanmuStyle();
                                },
                              ),
                              _DanmuSliderRow(
                                label: '密度 ${_danmuTracks} 轨',
                                value: _danmuTracks.toDouble(),
                                min: 2,
                                max: 8,
                                divisions: 6,
                                onChanged: (v) {
                                  refresh(() => _danmuTracks = v.round());
                                  _persistDanmuStyle();
                                },
                              ),
                              _DanmuSliderRow(
                                label:
                                    '速度 ${_danmuSpeed.round()} px/s',
                                value: _danmuSpeed,
                                min: 80,
                                max: 240,
                                divisions: 16,
                                onChanged: (v) {
                                  refresh(() => _danmuSpeed = v);
                                  _persistDanmuStyle();
                                },
                              ),
                            ],
                            if (_danmuApiUrl.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _showSendDanmuDialog(),
                                child: Container(
                                  width: double.infinity,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 10),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: AppTheme.accentColor
                                        .withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Text('发送弹幕',
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600)),
                                ),
                              ),
                            ],
                            const Divider(color: Colors.white12, height: 16),
                            const _SettingsRowLabel('倍速'),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: _supportedSpeeds.map((s) {
                                final selected =
                                    (s - _playbackSpeed).abs() < 0.01;
                                return GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    refresh(() {
                                      _setSpeed(s);
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: selected
                                          ? AppTheme.accentColor
                                          : Colors.white
                                              .withValues(alpha: 0.08),
                                      borderRadius:
                                          BorderRadius.circular(16),
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
                                  onTap: () {
                                    refresh(() {
                                      _setVideoFit(fit);
                                    });
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: selected
                                          ? AppTheme.accentColor
                                          : Colors.white
                                              .withValues(alpha: 0.08),
                                      borderRadius:
                                          BorderRadius.circular(16),
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
                              onChange: (v) =>
                                  widget.onSetSkipIntro?.call(v),
                              presets: _skipPresets,
                              maxSeconds: _skipMaxSeconds,
                            ),
                            const SizedBox(height: 16),
                            const _SettingsRowLabel('跳过片尾'),
                            const SizedBox(height: 8),
                            _SkipSecondsEditor(
                              label: '片尾',
                              value: widget.skipOutroSeconds,
                              onChange: (v) =>
                                  widget.onSetSkipOutro?.call(v),
                              presets: _skipPresets,
                              maxSeconds: _skipMaxSeconds,
                            ),
                            const SizedBox(height: 16),
                            if (_resolutionText.isNotEmpty) ...[
                              const _SettingsRowLabel('播放信息'),
                              const SizedBox(height: 8),
                              Text(
                                '分辨率: $_resolutionText',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
  // ============================================================
  // 画中画
  // ============================================================

  /// 小窗关闭后回到 App：共用同一 AVPlayer，一般只需收起浮层。
  /// 仅当播放器不是 iOS 共享实例（如 MPV）时才 seek/续播。
  Future<void> _resumeAfterPip(Duration resume, String playUrl) async {
    if (!mounted) return;
    setState(() => _pipActive = false);
    final isSharedIos = _player.isSharedIosAv;
    if (!isSharedIos) {
      try {
        if (resume > Duration.zero) {
          await _player.seek(resume);
        }
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await _player.play();
      } catch (e) {
        AppLog.instance.log('[video_player] resume after pip failed: $e');
      }
    }
    // 为下次进小窗保持 layer 就绪
    if (Platform.isIOS && playUrl.isNotEmpty) {
      VideoPlayerPip.instance.prepareIos(
        url: playUrl,
        headers: widget.headers,
      );
    }
  }

  Future<void> _togglePiP() async {
    // iOS 端：系统级画中画（双播放器方案）
    if (Platform.isIOS) {
      if (VideoPlayerPip.instance.isIosActive) {
        final resume = VideoPlayerPip.instance.iosLastPosition;
        await VideoPlayerPip.instance.exitIos();
        setState(() => _pipActive = false);
        if (resume > Duration.zero) {
          try {
            _player.seek(resume);
          } catch (e) {
        AppLog.instance.log('[video_player] swallowed: $e');
      }
        }
        try {
          _player.play();
        } catch (e) {
        AppLog.instance.log('[video_player] swallowed: $e');
      }
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
      // 单实例 AVPlayer：进小窗不暂停，画面交给系统 PiP，视频连续
      if (Platform.isIOS && !_player.isSharedIosAv) {
        _showMessage('请把点播内核切换为「AVPlayer」后再使用小窗');
        return;
      }
      final entered = await VideoPlayerPip.instance.enterIos(
        url: playUrl,
        headers: widget.headers,
        position: currentPos,
        onStarted: () {
          if (!mounted) return;
          // 单实例：不暂停，画面由系统小窗接管
          setState(() => _pipActive = true);
        },
        onStopped: () {
          final resume = VideoPlayerPip.instance.iosLastPosition;
          _resumeAfterPip(resume, playUrl);
        },
      );
      if (!entered) {
        try {
          _player.play();
        } catch (e) {
        AppLog.instance.log('[video_player] swallowed: $e');
      }
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
    // 单实例：进小窗不暂停，与手动 PiP 相同
    if (!_player.isSharedIosAv) {
      _autoPipInFlight = false;
      return;
    }
    try {
      final entered = await VideoPlayerPip.instance.enterIos(
        url: playUrl,
        headers: widget.headers,
        position: currentPos,
        onStarted: () {
          if (!mounted) return;
          // 单实例：不暂停，画面由系统小窗接管
          setState(() => _pipActive = true);
        },
        onStopped: () {
          final resume = VideoPlayerPip.instance.iosLastPosition;
          _resumeAfterPip(resume, playUrl);
        },
      );
      if (!entered) {
        setState(() => _pipActive = false);
        try {
          _player.play();
        } catch (e) {
        AppLog.instance.log('[video_player] swallowed: $e');
      }
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
    final pad = MediaQuery.of(context).padding;
    // 与直播页顶栏一致：按钮 38 高，顶部间距由 topBarTopPadding 控制
    const contentH = 38.0;
    final top = widget.topBarTopPadding;
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
          top: top + (pad.top > 0 ? 0 : 8),
          left: 4 + pad.left,
          right: 4 + pad.right,
          bottom: 8,
        ),
        child: SizedBox(height: contentH, child: child),
      ),
    );
  }

  Widget _gradientBottomContainer({required Widget child}) {
    final mediaPadding = MediaQuery.of(context).padding;
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
          bottom: mediaPadding.bottom,
          left: mediaPadding.left,
          right: mediaPadding.right,
        ),
        child: child,
      ),
    );
  }

  Widget _iconButton({
    required IconData icon,
    required double size,
    double width = 38,
    double height = 38,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        // 与直播页 _VideoTopIcon 一致：38×38，图标 20
        width: width < 38 ? 38 : width,
        height: 38,
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



/// 设置面板里的弹幕样式滑条
class _DanmuSliderRow extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final ValueChanged<double> onChanged;

  const _DanmuSliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        _SettingsRowLabel(label),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          activeColor: AppTheme.accentColor,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
