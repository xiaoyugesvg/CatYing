import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../services/app_log.dart';
import '../services/tmdb_service.dart';
import 'app_player.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart' show DragToMoveArea;
import '../common/theme.dart';
import '../common/system_ui.dart';
import 'video_player_pip.dart';
import 'window_fullscreen.dart';
import 'danmaku.dart';
import '../services/audio_focus.dart';
import 'app_toast.dart';
import '../pages/settings/sub/danmu_settings_page.dart';
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

  /// 播放设置弹窗的最大高度（父级传入播放器所在区域高度），见构造函数注释
  final double? sheetMaxHeight;

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

    /// 播放设置弹窗的最大高度（由父级传入播放器所在区域的高度）。
    ///
    /// 需求：设置面板不能超出播放器底部、盖住下方的简介/推荐 tab 栏。
    /// 弹窗本身是从屏幕底部弹出的，只能靠限高来"止步"在播放器范围内。
    /// null 时回退到屏幕高度的 72%。
    this.sheetMaxHeight,
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

  /// 弹幕**设置**是否已从 prefs 读出来（`_loadDanmuSettings` 是异步的）。
  /// 首帧它还是 false，此时不能因为 `_danmuApiUrl` 为空就显示成"未配置"
  /// ——否则按钮会先暗一下再变亮（读盘可能跨帧）。
  bool _danmuSettingsReady = false;
  String _danmuApiUrl = '';

  /// 弹幕拉取代次：换集时递增，过期响应直接丢弃
  int _danmuLoadGen = 0;
  double _danmuFontSize = 14;
  double _danmuOpacity = 1;
  double _danmuSpeed = 150;
  int _danmuTracks = 4;
  List<String> _danmuBlockWords = [];

  // ---- 按类型屏蔽（滚动 / 顶部 / 底部）----
  bool _danmuBlockScroll = false;
  bool _danmuBlockTop = false;
  bool _danmuBlockBottom = false;

  /// 显示区域：弹幕可见高度占播放器的比例（0.25 / 0.5 / 0.75 / 1.0）
  double _danmuAreaRatio = 1.0;

  /// 行间距系数（1.0 ~ 3.0），影响轨道纵向间距
  double _danmuLineSpacing = 1.6;

  /// 描边宽度（0 ~ 3）
  double _danmuStrokeWidth = 1.5;

  /// 字体粗细
  FontWeight _danmuFontWeight = FontWeight.w500;

  /// 弹幕延迟（秒）：正数=晚出现，负数=提前
  double _danmuDelaySeconds = 0.0;

  // ============================================================
  // 「设置 → 播放器」读入的行为开关（原先只存不读）
  // ============================================================

  /// 硬件加速（关 = 软解）
  bool _preferLandscape = false;

  /// 进度条显示总时长（false = 显示剩余时长）
  bool _showTotalDuration = true;

  /// 隐藏中央快进快退动画
  bool _hideCenterSeek = false;

  /// 进入后台暂停
  bool _pauseOnBackground = false;

  /// 跳过片头片尾时显示提示
  bool _skipHint = false;

  /// 切集时显示提示
  bool _switchEpisodeHint = false;

  /// 显示帧率与编码
  bool _showFpsCodec = false;

  /// 始终显示网速
  bool _alwaysShowSpeed = true;

  /// 长按倍速
  double _longPressSpeed = 3.0;

  /// 长按可滑动调节倍速
  bool _longPressAdjustable = true;

  /// 用户配置的快进快退秒数（覆盖默认 _seekStep）
  int _userSeekStep = 10;

  /// 实际使用的快进步长（优先用户配置）
  int get _effectiveSeekStep => _userSeekStep > 0 ? _userSeekStep : _seekStep;

  /// 顶部轻提示的自动清除定时器
  Timer? _hintClearTimer;

  /// 是否因「优先横屏」而强制了方向（退出播放器时要还原）
  bool _landscapeForcedByPref = false;

  /// 同步视频速度：倍速播放时弹幕滚动速度同比缩放
  bool _danmuSyncSpeed = false;

  /// 片名兜底匹配的解析缓存：'片名|年份|集号' → episodeId。
  ///
  /// 静态（跨实例/跨集复用）：兜底链路要 3 次请求，而该服务有速率限制
  /// （实测密集请求返回 429），逐集重跑会很快被限流。
  static final Map<String, int> _danmuEpCache = {};

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

  /// 双击位置：onDoubleTapDown 记下，onDoubleTap 里用来决定左/中/右行为。
  /// （onDoubleTap 自身不带坐标；而实际操作必须放在 onDoubleTap 里做，
  ///  否则单击要等双击超时才触发 —— 见手势层注释。）
  Offset? _doubleTapAt;

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

    // 注册到全局音频焦点协调器：音乐/直播要出声时会调这里的 pause()。
    //
    // ⚠️ 这里原来**完全没有互斥** —— 原来的 `LiveService.pauseLivePlayer`
    // 只覆盖「点播 ⇄ 直播」，音乐不在体系内，所以"看视频时音乐还在响"。
    // 现在三方都注册到 AudioFocus，任一方出声都让另两方闭嘴。
    // 用闭包而不是直接传方法引用：initState 时 `_player` 可能还没建好，
    // 闭包在真正被调用时才去取它。
    AudioFocus.register('video', () async {
      try {
        // 守卫：没在播就不动它（避免无谓的暂停调用打乱播放器状态）。
        // ⚠️ 字段名是 `state.playing`，不是 `state.isPlaying`
        //（`AppPlayerStateView` 上的 getter 就叫 playing）；
        // 另外 `_player` 是 `late final`（非空），不需要空判断。
        if (!_player.state.playing) return;
        await _player.pause();
      } catch (e) {
        /* 暂停失败不影响其它方 */
      }
    });

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

    _playerSubs.add(
      _player.stream.error.listen((error) {
        if (error.isNotEmpty) widget.onError?.call();
      }),
    );

    _playerSubs.add(
      _player.stream.playing.listen((playing) {
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
              _ensureDanmuLoaded(urlOverride: widget.url);
            }
            // iOS：前台预热原生 AVPlayer（静音预缓冲常驻），退后台/点 PiP 时
            // 原生立即启动系统悬浮窗，避免"后台等缓冲"导致 PiP 时灵时不灵
            if (Platform.isIOS) {
              final u = _player.state.playlist.medias.isNotEmpty
                  ? _player.state.playlist.medias.last.uri
                  : widget.url;
              if (u.isNotEmpty) {
                VideoPlayerPip.instance.prepareIos(
                  url: u,
                  headers: widget.headers,
                );
              }
            }
          }
        }
      }),
    );

    _playerSubs.add(
      _player.stream.buffering.listen((buffering) {
        if (!mounted) return;
        // 换集后 buffering=true 时必须能显示转圈，不能被旧的 _isPlaying/_position 挡住
        if (buffering != _isBuffering) {
          setState(() => _isBuffering = buffering);
        }
      }),
    );

    // 进度：只更新 ValueNotifier（进度条/时间局部重建），
    // 仅在跳过片头/片尾按钮可见性变化时才整树 setState
    _playerSubs.add(
      _player.stream.position.listen((position) {
        if (!mounted) return;
        _position = position;
        _positionVN.value = position;
        if (_isBuffering && position > Duration.zero) {
          _isBuffering = false;
        }
        final sec = position.inSeconds;
        if (sec != _lastNotifiedPositionSec) {
          final prevSkip = _skipVisibilityFor(
            _lastNotifiedPositionSec < 0 ? -1 : _lastNotifiedPositionSec,
          );
          final nextSkip = _skipVisibilityFor(sec);
          _lastNotifiedPositionSec = sec;
          if (prevSkip != nextSkip) {
            setState(() {});
          }
          widget.onPositionChanged?.call(position);
        }
      }),
    );

    _playerSubs.add(
      _player.stream.duration.listen((duration) {
        if (!mounted) return;
        _duration = duration;
        _durationVN.value = duration;
        setState(() {});
      }),
    );

    _playerSubs.add(
      _player.stream.completed.listen((completed) {
        if (completed) widget.onEnded?.call();
      }),
    );

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
    _loadPlayerPrefs();
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
            fontSize: AppTheme.fontSubhead,
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
            fontSize: AppTheme.fontCaption,
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
      // 「切集提示」：换到新的一集时在顶部轻提示（默认关闭）
      if (_switchEpisodeHint) {
        final ep = (widget.currentEpisodeName ?? '').trim();
        if (ep.isNotEmpty) {
          _showTransientHint('正在切换至 $ep');
        }
      }
      setState(() {
        _position = Duration.zero;
        _duration = Duration.zero;
        _positionVN.value = Duration.zero;
        _durationVN.value = Duration.zero;
        _isBuffering = true;
      });
      if (_danmuApiUrl.isNotEmpty) {
        // 传新集地址：此处 _openMedia() 还没执行，播放器里仍是上一集 URL
        _ensureDanmuLoaded(urlOverride: widget.url);
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
          '=== _scheduleResumeSeek: cur=$cur > target=$target, 用户已观看, 跳过 ===',
        );
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
          '=== _applyPendingResumeSeek: cur=$cur > target=$target, 用户已观看, 跳过 ===',
        );
        _pendingResumeSeconds = null;
        return;
      }
      if ((cur - target).abs() < const Duration(seconds: 2)) {
        AppLog.instance.log(
          '=== _applyPendingResumeSeek: 已在 $pending 附近, 跳过 ===',
        );
        _pendingResumeSeconds = null;
        return;
      }
    } catch (e) {
      AppLog.instance.log('[video_player] swallowed: $e');
    }
    _pendingResumeSeconds = null;
    try {
      _player.seek(target);
      AppLog.instance.log(
        '=== _applyPendingResumeSeek: 兜底 seek 到 ${pending}s ===',
      );
    } catch (e) {
      AppLog.instance.log('=== _applyPendingResumeSeek: 兜底 seek 失败: $e ===');
    }
  }

  /// 读取「设置 → 播放器」里用户配置的播放行为。
  ///
  /// 这些项之前只写进了 SharedPreferences 却没人读 → 改了没反应。
  /// 现在在播放器初始化时统一读入，并**立即应用**能当场生效的几项
  /// （倍速 / 画面填充 / 跳过秒数），其余在渲染与手势里按需读取。
  Future<void> _loadPlayerPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // ---- 开关类 ----
      // 注意：「硬件加速」由 detail 页的 _effectiveDecodeMode 统一处理
      // （关掉即软解，优先级高于细分解码项），播放器这里不再重复读。
      _preferLandscape = prefs.getBool('play_prefer_landscape') ?? false;
      _showTotalDuration = prefs.getBool('play_show_total') ?? true;
      _hideCenterSeek = prefs.getBool('play_hide_center_seek') ?? false;
      _pauseOnBackground = prefs.getBool('play_pause_background') ?? false;
      _skipHint = prefs.getBool('play_skip_hint') ?? false;
      _switchEpisodeHint = prefs.getBool('play_switch_episode_hint') ?? false;
      _showFpsCodec = prefs.getBool('play_show_fps_codec') ?? false;
      _alwaysShowSpeed = prefs.getBool('play_always_show_speed') ?? true;

      // ---- 数值类 ----
      _longPressSpeed = (prefs.getDouble('play_longpress_speed') ?? 3.0).clamp(
        1.5,
        5.0,
      );
      _longPressAdjustable = prefs.getBool('play_longpress_adjustable') ?? true;
      _userSeekStep = prefs.getInt('play_time_step') ?? 10;
      final fillMode = (prefs.getInt('play_video_fill') ?? 0).clamp(0, 2);
      final defaultSpeed = (prefs.getDouble('play_default_speed') ?? 1.0).clamp(
        0.5,
        3.0,
      );

      // ---- 立即应用：画面填充 ----
      _videoFit = switch (fillMode) {
        1 => VideoFitType.cover, // 裁剪铺满
        2 => VideoFitType.fill, // 拉伸铺满
        _ => VideoFitType.contain, // 原比例
      };

      // ---- 立即应用：默认倍速 ----
      // 仅当用户没在本次播放里手动调过倍速时才覆盖（_playbackSpeed 仍是 1.0）
      if ((_playbackSpeed - 1.0).abs() < 0.001 && defaultSpeed != 1.0) {
        _playbackSpeed = defaultSpeed;
        await _player.setRate(_playbackSpeed);
      }

      // ---- 立即应用：优先横屏 ----
      // 只在用户开了这个开关、且当前确实是竖屏时才请求，避免干扰
      // detail 页面自己的全屏/方向逻辑。
      if (_preferLandscape && !_isImmersive) {
        try {
          final size = MediaQuery.of(context).size;
          if (size.height > size.width) {
            await SystemUiController.lockOrientations('videoLandscapePref', const [
              DeviceOrientation.landscapeLeft,
              DeviceOrientation.landscapeRight,
            ]);
            _landscapeForcedByPref = true;
          }
        } catch (e) {
          AppLog.instance.log('[video_player] 优先横屏失败: $e');
        }
      }

      if (mounted) setState(() {});
    } catch (e) {
      AppLog.instance.log('[video_player] _loadPlayerPrefs 失败: $e');
    }
  }

  /// 读取弹幕配置（设置页配置的 Logvr-danmu / 弹弹play 兼容 API 地址）
  Future<void> _loadDanmuSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _danmuApiUrl = (prefs.getString('danmu_api_url') ?? '').trim();
      _danmuOn = prefs.getBool('danmu_enabled') ?? true;
      _danmuFontSize = (prefs.getDouble('danmu_font_size') ?? 14).clamp(
        10.0,
        28.0,
      );
      _danmuOpacity = (prefs.getDouble('danmu_opacity') ?? 1).clamp(0.2, 1.0);
      _danmuSpeed = (prefs.getDouble('danmu_speed') ?? 150).clamp(80.0, 240.0);
      _danmuTracks = (prefs.getInt('danmu_tracks') ?? 4).clamp(2, 8);
      _danmuBlockWords = prefs.getStringList('danmu_block_words') ?? const [];
      // 按类型屏蔽 / 显示区域 / 同步视频速度
      _danmuBlockScroll = prefs.getBool('danmu_block_scroll') ?? false;
      _danmuBlockTop = prefs.getBool('danmu_block_top') ?? false;
      _danmuBlockBottom = prefs.getBool('danmu_block_bottom') ?? false;
      _danmuAreaRatio = (prefs.getDouble('danmu_area_ratio') ?? 1.0).clamp(
        0.25,
        1.0,
      );
      _danmuSyncSpeed = prefs.getBool('danmu_sync_speed') ?? false;
      // 新增样式项
      _danmuLineSpacing = (prefs.getDouble('danmu_line_spacing') ?? 1.6).clamp(
        1.0,
        3.0,
      );
      _danmuStrokeWidth = (prefs.getDouble('danmu_stroke_width') ?? 1.5).clamp(
        0.0,
        3.0,
      );
      _danmuDelaySeconds = (prefs.getDouble('danmu_delay_seconds') ?? 0.0)
          .clamp(-5.0, 5.0);
      // 字体粗细存 weight 数值（400/500/600/700），未知值回落 w500
      final w = prefs.getInt('danmu_font_weight') ?? 500;
      _danmuFontWeight = switch (w) {
        400 => FontWeight.w400,
        600 => FontWeight.w600,
        700 => FontWeight.w700,
        _ => FontWeight.w500,
      };
      if (mounted) setState(() {});
      if (_danmuApiUrl.isNotEmpty) {
        // 显式传 widget.url：此方法是异步的，回来时播放器可能已经 open 了
        // 真实播放地址；不传的话依赖 playlist 取值，时序不稳定。
        _ensureDanmuLoaded(urlOverride: widget.url);
      }
    } catch (e) {
      AppLog.instance.log('[video_player] swallowed: $e');
    } finally {
      // ⚠️ 必须在 finally 里置位（并 setState 通知重建）：
      // 底部栏的弹幕按钮靠它区分"设置还没读出来"与"确实没配弹幕源"。
      // 若放在 try 末尾，读盘异常时按钮会永远停在"未加载"的中性态。
      _danmuSettingsReady = true;
      if (mounted) setState(() {});
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

  Future<void> _ensureDanmuLoaded({String? urlOverride}) async {
    if (_danmuLoaded || _danmuApiUrl.isEmpty) return;
    final loadGen = ++_danmuLoadGen;
    // ⚠️ 必须优先用调用方传入的新地址：
    // 换集分支里 _ensureDanmuLoaded() 在 _openMedia() **之前**执行，此时
    // _player.state.playlist 仍是上一集的 URL → 会把上一集的弹幕贴到新一集上。
    final url = (urlOverride != null && urlOverride.isNotEmpty)
        ? urlOverride
        : (_player.state.playlist.medias.isNotEmpty
              ? _player.state.playlist.medias.last.uri
              : widget.url);
    // 地址为空时不要置位 _danmuLoaded，否则该播放会话弹幕永久卡死
    if (url.isEmpty) return;
    _danmuLoaded = true;

    // 片名 / 集数：url 匹配失败时用于「按片名兜底匹配」
    final title = (widget.videoTitle ?? '').trim();
    final epName = (widget.currentEpisodeName ?? '').trim();
    // url 命中不到时是否还值得用片名兜底（仅 http(s) 播放地址）
    final titleFallbackUsable = title.isNotEmpty && url.startsWith('http');
    final silentUrl = titleFallbackUsable ? '?format=json' : '&format=json';

    final base = _danmuApiBase();
    final api =
        '$base/api/v2/comment?url=${Uri.encodeQueryComponent(url)}$silentUrl';
    // 记录实际请求（含被匹配的视频地址）：该服务只支持 commentId / url，
    // 「查不到弹幕」时唯一能核对的证据就是这条请求 URL。
    AppLog.instance.log('[video_player] danmu request: $api');
    var list = parseDanmuBody(await _danmuGetText(api));

    // ---- 按片名兜底 ----
    // 该弹幕服务的 url 匹配要求播放地址与库里索引的**标准平台地址**完全一致；
    // spider 源给的多是 CDN 直链（带签名/会变），几乎必然 0 条。
    // 服务同时提供 搜索→分集→弹幕 三步链路，此处作为兜底。
    var danmuSource = 'url';
    if (list.isEmpty && titleFallbackUsable) {
      list = await _danmuFetchByTitle(base, title, epName, url);
      if (list.isNotEmpty) danmuSource = 'title';
    }

    if (_danmuBlockWords.isNotEmpty) {
      list = list
          .where(
            (d) => !_danmuBlockWords.any(
              (w) => w.isNotEmpty && d.text.contains(w),
            ),
          )
          .toList();
    }
    AppLog.instance.log(
      '[video_player] danmu loaded: ${list.length} 条 (source=$danmuSource, title=$title)',
    );
    // 代次校验：快速换集时丢弃过期响应，避免旧集弹幕盖到新集上
    if (mounted && list.isNotEmpty && loadGen == _danmuLoadGen) {
      setState(() => _danmus = list);
    }
  }

  /// 取文本（弹幕接口专用；失败返回空串，不抛）
  Future<String> _danmuGetText(String api) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final http = await client
          .getUrl(Uri.parse(api))
          .timeout(const Duration(seconds: 12));
      http.headers.set('User-Agent', 'NewTv/1.0');
      final res = await http.close().timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) {
        AppLog.instance.log(
          '[video_player] danmu HTTP ${res.statusCode} ($api)',
        );
        return '';
      }
      return await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 12));
    } catch (e) {
      AppLog.instance.log('[video_player] danmu request fail: $e');
      return '';
    } finally {
      client.close(force: true);
    }
  }

  /// 片名 → 弹幕的兜底链路：搜索番剧 → 取分集 → 取弹幕。
  ///
  /// 解析结果按「片名|年份|集号」缓存（进程内），避免每一集都跑 3 次请求：
  /// 该服务有速率限制，实测密集请求会返回 429。
  Future<List<DanmuItem>> _danmuFetchByTitle(
    String base,
    String title,
    String episodeName,
    String videoUrl,
  ) async {
    // 片名清洗：优先复用 TMDB 的清洗规则（去「更新至N集/第N季/4K/中字」等噪音）
    var clean = TmdbService.cleanTitle(title);
    // 该服务搜索对「【】」等括号敏感，直接搜原始标题命中率反而更高
    if (clean.isEmpty) clean = title;
    // 年份用于缓存键隔离（同名不同年的剧不要互相串缓存）
    final year = TmdbService.extractYear('', '');

    final cacheKey =
        '${clean.toLowerCase()}|${year ?? ''}|${widget.selectedEpisodeIndex}';
    final cached = _danmuEpCache[cacheKey];
    if (cached != null) {
      AppLog.instance.log(
        '[video_player] danmu title-fallback cache hit: $cacheKey',
      );
      return _danmuFetchComments(base, cached);
    }

    // ① 搜索番剧
    final searchUrl =
        '$base/api/v2/search/anime'
        '?keyword=${Uri.encodeQueryComponent(clean)}';
    final searchBody = await _danmuGetText(searchUrl);
    if (searchBody.isEmpty) return const [];
    final animes = _danmuParseList(searchBody, 'animes');
    if (animes.isEmpty) {
      AppLog.instance.log('[video_player] danmu search 无结果: $clean');
      return const [];
    }

    // 只在「首条标题包含片名」时才采用，避免搜到同名无关内容就贴弹幕
    final firstName = (animes.first['animeTitle'] ?? '').toString().trim();
    if (firstName.isEmpty || !firstName.contains(clean)) {
      AppLog.instance.log(
        '[video_player] danmu search 首条不匹配，放弃: "$firstName" !~ "$clean"',
      );
      return const [];
    }
    final animeId = animes.first['animeId'];
    if (animeId == null) return const [];

    // ② 取分集列表
    final bgBody = await _danmuGetText('$base/api/v2/bangumi/$animeId');
    if (bgBody.isEmpty) return const [];
    final bangumi = _danmuParseMap(bgBody, 'bangumi');
    final episodes = (bangumi?['episodes'] as List?) ?? const [];
    if (episodes.isEmpty) return const [];

    // ③ 选集：优选用「当前集名」在分集标题里找，否则退回按集号顺序
    int episodeId = 0;
    if (episodeName.isNotEmpty) {
      for (final e in episodes) {
        if (e is! Map) continue;
        final t = (e['episodeTitle'] ?? '').toString();
        if (t.isNotEmpty && episodeName.contains(t)) {
          episodeId = (e['episodeId'] as num?)?.toInt() ?? 0;
          if (episodeId > 0) break;
        }
      }
    }
    if (episodeId == 0) {
      final idx = widget.selectedEpisodeIndex.clamp(0, episodes.length - 1);
      final e = episodes[idx];
      if (e is Map) episodeId = (e['episodeId'] as num?)?.toInt() ?? 0;
    }
    if (episodeId == 0) return const [];

    _danmuEpCache[cacheKey] = episodeId;
    AppLog.instance.log(
      '[video_player] danmu title-fallback 命中: "$firstName" episodeId=$episodeId',
    );
    return _danmuFetchComments(base, episodeId);
  }

  /// 用 episodeId 取弹幕（兜底链路的最后一步）
  Future<List<DanmuItem>> _danmuFetchComments(
    String base,
    int episodeId,
  ) async {
    final body = await _danmuGetText(
      '$base/api/v2/comment/$episodeId?format=json&duration=true',
    );
    if (body.isEmpty) return const [];
    return parseDanmuBody(body);
  }

  /// 解析 JSON 并取出指定 key 的数组（失败返回空）
  List<dynamic> _danmuParseList(String body, String key) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded[key] is List) {
        return decoded[key] as List;
      }
    } catch (_) {}
    return const [];
  }

  /// 解析 JSON 并取出指定 key 的对象（失败返回 null）
  Map<String, dynamic>? _danmuParseMap(String body, String key) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded[key] is Map) {
        return Map<String, dynamic>.from(decoded[key] as Map);
      }
    } catch (_) {}
    return null;
  }

  /// 持久化弹幕开关
  Future<void> _persistDanmuStyle() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('danmu_font_size', _danmuFontSize);
      await prefs.setDouble('danmu_opacity', _danmuOpacity);
      await prefs.setInt('danmu_tracks', _danmuTracks);
      await prefs.setDouble('danmu_speed', _danmuSpeed);
      // 新增项
      await prefs.setBool('danmu_block_scroll', _danmuBlockScroll);
      await prefs.setBool('danmu_block_top', _danmuBlockTop);
      await prefs.setBool('danmu_block_bottom', _danmuBlockBottom);
      await prefs.setDouble('danmu_area_ratio', _danmuAreaRatio);
      await prefs.setBool('danmu_sync_speed', _danmuSyncSpeed);
    } catch (e) {
      AppLog.instance.log('[video_player] persist danmu style: $e');
    }
  }

  // 弹幕发送功能已移除（2026-09-30）：Logvr-danmu / danmu_api 均为只读弹幕服务，
  // 只有 GET /api/v2/comment 获取接口，没有"发送单条弹幕"的 POST 端点，
  // 原 _showSendDanmuDialog / _sendDanmu 的 3 个候选端点必然 404/405，
  // 用户点一次只会收到失败提示，故整体下线（设置面板里的按钮也已移除）。

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

  /// 「始终显示网速」的展示文案。
  ///
  /// 说明：本项目在 iOS 上走 IosAvPlayer（共享原生 AVPlayer），
  /// 底层没有暴露实时下载带宽，**不能**凭空编一个 MB/s 数字。
  /// 这里改用播放器**确实拥有**的指标 —— 已缓冲提前量（秒）——
  /// 它同样是"网络够不够快"的真实信号：数字掉到 1~2 秒就说明要卡了。
  String get _netSpeedText {
    final bufferedAhead = _duration - _position;
    if (_duration <= Duration.zero || bufferedAhead <= Duration.zero) {
      return '';
    }
    final sec = bufferedAhead.inSeconds;
    // 提前量很小说明网络吃紧，用更醒目的颜色语义（此处只回文案）
    return '缓冲 ${sec}s';
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
      // ⚠️ 必须走 setState：原来是直接 `_showControls = ...`，
      // 赋值了但没触发重建 —— 锁定状态/选集面板下点击唤醒控制条时
      // UI 不刷新，表现为「点了没反应、进度条和上下栏不出现」。
      if (!_showControls) {
        setState(() => _showControls = true);
      }
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
    // 诊断用：与 _safeTap 的日志对照，可区分「点击落到视频层」还是「落到按钮」
    AppLog.instance.log(
      '[video_player] toggleControls show=${!_showControls} locked=$_isLocked',
    );
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
      AudioFocus.request('video');
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
      await SystemUiController.lockOrientations('videoFullscreen', const [
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
      AppLog.instance.log(
        '=== _enterFullScreen: WindowFullScreen enter OK ===',
      );
    } catch (e) {
      AppLog.instance.log(
        '=== _enterFullScreen: WindowFullScreen enter failed: $e ===',
      );
    }
    if (mounted) _onWindowFullScreenChanged();
    try {
      if (!_player.state.playing) {
        await AudioFocus.request('video');
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
      AppLog.instance.log(
        '=== _exitFullScreen: WindowFullScreen exit failed: $e ===',
      );
    }
    if (Platform.isIOS) {
      // 还原进入全屏前记录的方向，而不是无条件写死"竖屏+左右横屏"
      await SystemUiController.unlockOrientations('videoFullscreen');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (mounted) _onWindowFullScreenChanged();
    try {
      if (!_player.state.playing) {
        await AudioFocus.request('video');
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
    bool needSchedule = false;
    setState(() {
      _isLocked = !_isLocked;
      if (_isLocked) {
        _showControls = false;
      } else {
        _showControls = true;
        needSchedule = true;
      }
    });
    // _scheduleHideControls 内部会直接写 _showControls，不能放在 setState 回调里
    // （那等于在构建前做非幂等的状态写入 + 起 Timer，绕过框架的脏标记契约）。
    if (needSchedule) _scheduleHideControls();
  }

  void _skipIntro() {
    if (widget.skipIntroSeconds > 0) {
      _seekTo(Duration(seconds: widget.skipIntroSeconds));
      _scheduleHideControls();
      // 「跳过提示」：横幅与轻提示（默认关闭）
      if (_skipHint) _showTransientHint('已跳过片头 ${widget.skipIntroSeconds} 秒');
    }
  }

  void _skipOutro() {
    if (widget.skipOutroSeconds > 0 && _duration > Duration.zero) {
      _seekTo(_duration - Duration(seconds: widget.skipOutroSeconds));
      _scheduleHideControls();
      if (_skipHint) _showTransientHint('已跳过片尾 ${widget.skipOutroSeconds} 秒');
    }
  }

  /// 顶部轻提示（复用 _gestureHorizontalHint 的渲染通道，2 秒后自动消失）
  void _showTransientHint(String text) {
    if (!mounted) return;
    setState(() => _gestureHorizontalHint = text);
    _hintClearTimer?.cancel();
    _hintClearTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _gestureHorizontalHint = '');
    });
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
        // 归零累计快进/快退秒数：旧实现只加不减，连点 6 次 10 秒会显示
        // 「快进60秒」而不是本次操作的 10 秒（提示消失即代表本次操作结束）。
        _seekAccumulatedSeconds = 0;
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
    AudioFocus.unregister('video');
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
    _hintClearTimer?.cancel();

    // 还原「优先横屏」强制过的方向，避免退出播放器后整个 App 卡在横屏
    if (_landscapeForcedByPref) {
      _landscapeForcedByPref = false;
      SystemUiController.unlockOrientations('videoLandscapePref');
    }
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
            const Icon(
              Icons.picture_in_picture_alt,
              color: Colors.white70,
              size: 40,
            ),
            const SizedBox(height: 12),
            const Text(
              '正在画中画',
              style: TextStyle(
                color: Colors.white,
                fontSize: AppTheme.fontHeadline,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '小窗播放中，回到 App 可继续控制',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: AppTheme.fontFootnote,
              ),
            ),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: _togglePiP,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Text(
                  '回到 App 内播放',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: AppTheme.fontSubhead,
                  ),
                ),
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

  /// 「显示区域」滑条右侧文案
  String _danmuAreaLabel(double r) {
    if (r <= 0.26) return '1/4';
    if (r <= 0.51) return '半屏';
    if (r <= 0.76) return '3/4';
    return '满屏';
  }

  /// 「弹幕速度」滑条右侧文案
  String _danmuSpeedLabel(double v) {
    if (v < 120) return '极慢';
    if (v < 190) return '适中';
    return '极快';
  }

  /// 按类型屏蔽的方形 chip（选中=屏蔽该类型，按钮变暗 + 斜杠）
  Widget _danmuTypeChip({
    required String label,
    required IconData icon,
    required bool blocked,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 38,
              decoration: BoxDecoration(
                color: blocked
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.white.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: blocked
                      ? Colors.white.withValues(alpha: 0.10)
                      : Colors.white.withValues(alpha: 0.28),
                ),
              ),
              child: Center(
                child: Icon(
                  icon,
                  size: 18,
                  color: blocked
                      ? Colors.white.withValues(alpha: 0.3)
                      : Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 5),
            Text(
              label,
              style: TextStyle(
                color: blocked
                    ? Colors.white.withValues(alpha: 0.35)
                    : Colors.white.withValues(alpha: 0.85),
                fontSize: AppTheme.fontFootnote,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 弹幕设置里的复选框行（点击文字也可切换）
  Widget _danmuCheck({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(!value),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: Checkbox(
              value: value,
              activeColor: AppTheme.accentColor,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.4)),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              onChanged: (v) => onChanged(v ?? false),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: AppTheme.fontSubhead,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDanmuLayer() {
    // 同步视频速度：倍速播放时弹幕滚动同比缩放，保持与画面节奏一致
    final speed = _danmuSyncSpeed
        ? (_danmuSpeed * _playbackSpeed).clamp(40.0, 480.0)
        : _danmuSpeed;
    final layer = DanmuLayer(
      danmus: _danmus,
      // 弹幕延迟：正数表示"晚出现"，等价于把查询位置往回拨，
      // 这样同一时刻会取到更早的那批弹幕，视觉上就整体延后了。
      positionOf: () =>
          _player.state.position -
          Duration(milliseconds: (_danmuDelaySeconds * 1000).round()),
      fontSize: _danmuFontSize,
      opacity: _danmuOpacity,
      speed: speed,
      trackCount: _danmuTracks,
      blockScroll: _danmuBlockScroll,
      blockTop: _danmuBlockTop,
      blockBottom: _danmuBlockBottom,
      areaRatio: _danmuAreaRatio,
      lineSpacing: _danmuLineSpacing,
      strokeWidth: _danmuStrokeWidth,
      fontWeight: _danmuFontWeight,
      delaySeconds: _danmuDelaySeconds,
    );
    // 显示区域：把弹幕层限制在顶部若干比例内（其余区域不显示弹幕）
    if (_danmuAreaRatio >= 0.99) {
      return Positioned.fill(child: IgnorePointer(child: layer));
    }
    return Positioned.fill(
      child: Align(
        alignment: Alignment.topCenter,
        child: FractionallySizedBox(
          heightFactor: _danmuAreaRatio,
          widthFactor: 1,
          child: IgnorePointer(child: layer),
        ),
      ),
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
            // 长按倍速：用用户配置的倍速（原来写死 ×2）
            _player.setRate(_playbackSpeed * _longPressSpeed);
            setState(() => _isLongPressingFast = true);
          },
          onLongPressMoveUpdate: (details) {
            if (_isLocked) return;
            // 关闭「长按滑动调节倍速」后，上滑不再锁定倍速
            if (!_longPressAdjustable) return;
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
            // ⚠️ 双击跳转必须放在 onDoubleTap 里执行，**不能**放在 onDoubleTapDown。
            //
            // 原写法是 onDoubleTapDown 里直接跳转 + onDoubleTap: (){} 空实现。
            // 后果（已用 flutter_test 实测）：只要注册了 onDoubleTap，
            // 单击就必须等双击超时（约 300ms）才触发 onTap ——
            // 用户点一下觉得"没反应"，再点一下又被判成双击去跳转，
            // 于是进度条和上下功能栏一直不出现。
            //
            // 位置改从 onDoubleTapDown 传入（onDoubleTap 本身不带坐标）。
            onDoubleTapDown: (details) {
              _doubleTapAt = details.localPosition;
            },
            onDoubleTap: () {
              final pos = _doubleTapAt;
              if (pos == null) return;
              final x = pos.dx;
              if (x < width / 4) {
                _seekBy(-_effectiveSeekStep, isLeft: true);
              } else if (x > width * 3 / 4) {
                _seekBy(_effectiveSeekStep, isLeft: false);
              } else {
                _togglePlayPause();
              }
            },
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
                  _gestureSeekTemp = (_gestureSeekStartMs + deltaMs).clamp(
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

  /// 水平拖动 seek：手势起点的进度（ms）。拖动中目标 = 本值 + 累计位移换算，
  /// 不能对 _gestureSeekTemp 逐帧累加累计 delta（会变成平方漂移）。
  double _gestureSeekStartMs = 0;

  void _seekBy(int seconds, {required bool isLeft}) {
    if (_isLocked) return;
    final target = _player.state.position + Duration(seconds: seconds);
    _seekTo(target);
    setState(() {
      _seekAccumulatedSeconds += seconds;
      // 「隐藏中央快进快退」：只跳转，不显示中央动画
      if (_hideCenterSeek) {
        _showBackwardSeek = false;
        _showForwardSeek = false;
        return;
      }
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
                      fontSize: AppTheme.fontHeadline,
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
                  fontSize: AppTheme.fontFootnote,
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
                          fontSize: AppTheme.fontSubhead,
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
  ///
  /// 注意这里的诊断日志：顶栏按钮"点了没反应"时，需要区分两种可能——
  /// (a) 触摸根本没到达按钮（层级/命中测试被挡）
  /// (b) 触摸到了但 action 内部异常被吞
  /// 日志出现说明是 (b)；日志不出现说明是 (a)，那就要查命中测试。
  void _safeTap(FutureOr<void> Function() action) {
    AppLog.instance.log('[video_player] safeTap invoked');
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
            // 返回键：与右侧功能键同一套玻璃底衬，保持整条顶栏视觉一致
            _iconButton(
              icon: Icons.arrow_back_ios_new,
              size: 17,
              onTap: widget.onBack ?? () => Navigator.of(context).maybePop(),
            ),
            const Spacer(),

            // 缓冲状态：按你的要求放在**听剧图标前面**（原来在最右侧菜单位置）
            if (_alwaysShowSpeed && _netSpeedText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.network_check,
                      size: 12,
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                    const SizedBox(width: 3),
                    Text(
                      _netSpeedText,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.8),
                        fontSize: AppTheme.fontCaption,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),

            // 听剧模式（仅点播页显示）
            if (widget.showAudioModeButton)
              _iconButton(
                icon: _audioMode ? Icons.headphones : Icons.headphones_outlined,
                size: 20,
                width: 36,
                onTap: () => _safeTap(_toggleAudioMode),
              ),

            // 弹幕开关已移到**底部功能栏**（见 _buildBottomControls）

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

            if (_isNativeFullscreen) ...[
              const SizedBox(width: 4),
              _buildStatusBarInfo(),
            ],

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
      // 控件区尽量贴近画面底边（原来 bottom:2 + 渐变层又加了安全区
      // 底部内边距，导致进度条离底部很远，与下方简介 tab 之间留下大片黑条）。
      bottom: 0,
      left: 0,
      right: 0,
      child: _gradientBottomContainer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildProgressBar(),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 2),
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
                  // 弹幕开关：已在底部功能栏（**常显**，不再按是否配置弹幕源隐藏 ——
                  // 隐藏会让用户完全看不到这个功能。未配置时点击会引导去设置页）
                  _danmuToggleButton(),
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
    final showIntro =
        widget.skipIntroSeconds > 0 &&
        posSec > 0 &&
        posSec < widget.skipIntroSeconds;
    final showOutro =
        widget.skipOutroSeconds > 0 &&
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
                fontSize: AppTheme.fontFootnote,
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
                    fontSize: AppTheme.fontPageTitle,
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
                    fontSize: AppTheme.fontCaption,
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
                    if (locked) ...[
                      const Icon(
                        Icons.touch_app,
                        color: Colors.white70,
                        size: 11,
                      ),
                      const SizedBox(width: 3),
                      const Text(
                        '点击解除',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: AppTheme.fontCaption,
                        ),
                      ),
                    ] else ...[
                      const Icon(
                        Icons.arrow_upward,
                        color: Colors.white70,
                        size: 11,
                      ),
                      const SizedBox(width: 3),
                      const Text(
                        '上滑锁定',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: AppTheme.fontCaption,
                        ),
                      ),
                    ],
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
                          fontSize: AppTheme.fontSubhead,
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
                          fontSize: AppTheme.fontSubhead,
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
        final progress = totalMs > 0
            ? (currentMs / totalMs).clamp(0.0, 1.0)
            : 0.0;

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
                    fontSize: AppTheme.fontCaption,
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
                  // 「进度条显示总时长」关闭时改为显示剩余时长（前面带 -）
                  _duration <= Duration.zero
                      ? '--:--'
                      : _showTotalDuration
                      ? _formatDuration(_duration)
                      : '-${_formatDuration(_duration - _position)}',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.82),
                    fontSize: AppTheme.fontCaption,
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
    // 主操作：用 filled 的玻璃底，视觉权重高于两侧的切集按钮
    return _iconButton(
      icon: _isPlaying ? Icons.pause : Icons.play_arrow,
      size: 24,
      width: 46,
      filled: true,
      onTap: _togglePlayPause,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        child: Icon(
          _isPlaying ? Icons.pause : Icons.play_arrow,
          key: ValueKey(_isPlaying),
          color: Colors.white,
          size: 25,
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
                  fontSize: AppTheme.fontCaption,
                  fontFamily: 'monospace',
                ),
              ),
              Text(
                _duration > Duration.zero
                    ? _formatDuration(_duration)
                    : '--:--',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.82),
                  fontSize: AppTheme.fontCaption,
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
                  fontSize: AppTheme.fontSubhead,
                ),
              ),
              if (selected) ...[
                const Spacer(),
                Icon(Icons.check, color: AppTheme.accentColor, size: 16),
              ],
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
              fontSize: AppTheme.fontSubhead,
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
                  fontSize: AppTheme.fontSubhead,
                ),
              ),
              if (selected) ...[
                const Spacer(),
                Icon(Icons.check, color: AppTheme.accentColor, size: 16),
              ],
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
            style: const TextStyle(
              color: Colors.white,
              fontSize: AppTheme.fontSubhead,
            ),
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
              // 与内部网格高度配套（网格 84 + 标题行约 46）
              constraints: const BoxConstraints(maxHeight: 130),
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
                            fontSize: AppTheme.fontHeadline,
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
                  // 高度按"约一半"收紧：原来固定 168（面板总高约 249），
                  // 现在 84（面板总高约 130）。
                  // 集数多时不再显示滚动条，改为直接上下滑动（GridView 默认行为）。
                  SizedBox(
                    height: 84,
                    child: GridView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
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
                                fontSize: AppTheme.fontSubhead,
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
                  // 优先用父级给的播放器区域高度；没给就退回屏幕 72%。
                  // 目的是让面板**止步在播放器范围内**，不盖住下方 tab 栏。
                  maxHeight:
                      widget.sheetMaxHeight ??
                      MediaQuery.of(context).size.height * 0.72,
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
                              fontSize: AppTheme.fontHeadline,
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
                            // ===== 弹幕设置（按参考图重排）=====
                            Row(
                              children: [
                                const _SettingsRowLabel('弹幕'),
                                const Spacer(),
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
                              // ---- 按类型屏蔽：滚动 / 顶部 / 底部 ----
                              const SizedBox(height: 6),
                              Text(
                                '按类型屏蔽',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.6),
                                  fontSize: AppTheme.fontFootnote,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  _danmuTypeChip(
                                    label: '滚动',
                                    icon: Icons.format_align_left,
                                    blocked: _danmuBlockScroll,
                                    onTap: () {
                                      refresh(
                                        () => _danmuBlockScroll =
                                            !_danmuBlockScroll,
                                      );
                                      _persistDanmuStyle();
                                    },
                                  ),
                                  const SizedBox(width: 10),
                                  _danmuTypeChip(
                                    label: '顶部',
                                    icon: Icons.vertical_align_top,
                                    blocked: _danmuBlockTop,
                                    onTap: () {
                                      refresh(
                                        () => _danmuBlockTop = !_danmuBlockTop,
                                      );
                                      _persistDanmuStyle();
                                    },
                                  ),
                                  const SizedBox(width: 10),
                                  _danmuTypeChip(
                                    label: '底部',
                                    icon: Icons.vertical_align_bottom,
                                    blocked: _danmuBlockBottom,
                                    onTap: () {
                                      refresh(
                                        () => _danmuBlockBottom =
                                            !_danmuBlockBottom,
                                      );
                                      _persistDanmuStyle();
                                    },
                                  ),
                                ],
                              ),

                              // ---- 两个行为开关 ----
                              const SizedBox(height: 14),
                              Row(
                                children: [
                                  _danmuCheck(
                                    label: '防止弹幕重叠',
                                    // 轨数 ≥4 视为开启：轨数越多越不容易重叠
                                    value: _danmuTracks >= 4,
                                    onChanged: (v) {
                                      refresh(() => _danmuTracks = v ? 6 : 2);
                                      _persistDanmuStyle();
                                    },
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: _danmuCheck(
                                      label: '同步视频速度',
                                      value: _danmuSyncSpeed,
                                      onChanged: (v) {
                                        refresh(() => _danmuSyncSpeed = v);
                                        _persistDanmuStyle();
                                      },
                                    ),
                                  ),
                                ],
                              ),

                              // ---- 不透明度 ----
                              _DanmuSliderRow(
                                label: '不透明度',
                                valueText: '${(_danmuOpacity * 100).round()}%',
                                value: _danmuOpacity,
                                min: 0.2,
                                max: 1,
                                onChanged: (v) {
                                  refresh(() => _danmuOpacity = v);
                                  _persistDanmuStyle();
                                },
                              ),

                              // ---- 显示区域（限制弹幕可见高度）----
                              _DanmuSliderRow(
                                label: '显示区域',
                                valueText: _danmuAreaLabel(_danmuAreaRatio),
                                value: _danmuAreaRatio,
                                min: 0.25,
                                max: 1.0,
                                divisions: 3,
                                ticks: const ['1/4', '半屏', '3/4', '满屏'],
                                onChanged: (v) {
                                  refresh(() => _danmuAreaRatio = v);
                                  _persistDanmuStyle();
                                },
                              ),

                              // ---- 弹幕字号 ----
                              _DanmuSliderRow(
                                label: '弹幕字号',
                                valueText: '${_danmuFontSize.round()}px',
                                value: _danmuFontSize,
                                min: 10,
                                max: 28,
                                divisions: 18,
                                ticks: const ['小', '适中', '大'],
                                onChanged: (v) {
                                  refresh(() => _danmuFontSize = v);
                                  _persistDanmuStyle();
                                },
                              ),

                              // ---- 弹幕速度 ----
                              _DanmuSliderRow(
                                label: '弹幕速度',
                                valueText: _danmuSpeedLabel(_danmuSpeed),
                                value: _danmuSpeed,
                                min: 80,
                                max: 240,
                                divisions: 16,
                                ticks: const ['极慢', '适中', '极快'],
                                onChanged: (v) {
                                  refresh(() => _danmuSpeed = v);
                                  _persistDanmuStyle();
                                },
                              ),
                            ],
                            // 「发送弹幕」按钮已移除：所用弹幕服务（Logvr-danmu /
                            // danmu_api）只有 GET /api/v2/comment 获取接口，
                            // 没有发送单条弹幕的 POST 端点，原实现必然 404/405。
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
                                          : Colors.white.withValues(
                                              alpha: 0.08,
                                            ),
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: Text(
                                      _formatSpeed(s),
                                      style: TextStyle(
                                        color: selected
                                            ? Colors.white
                                            : Colors.white70,
                                        fontSize: AppTheme.fontFootnote,
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
                                          : Colors.white.withValues(
                                              alpha: 0.08,
                                            ),
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: Text(
                                      fit.desc,
                                      style: TextStyle(
                                        color: selected
                                            ? Colors.white
                                            : Colors.white70,
                                        fontSize: AppTheme.fontFootnote,
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
                              value: widget.skipIntroSeconds,
                              onChange: (v) => widget.onSetSkipIntro?.call(v),
                              presets: _skipPresets,
                              maxSeconds: _skipMaxSeconds,
                            ),
                            const SizedBox(height: 16),
                            const _SettingsRowLabel('跳过片尾'),
                            const SizedBox(height: 8),
                            _SkipSecondsEditor(
                              value: widget.skipOutroSeconds,
                              onChange: (v) => widget.onSetSkipOutro?.call(v),
                              presets: _skipPresets,
                              maxSeconds: _skipMaxSeconds,
                            ),
                            const SizedBox(height: 16),
                            // 「显示帧率与编码」开启后才展示播放信息
                            if (_showFpsCodec &&
                                _resolutionText.isNotEmpty) ...[
                              const _SettingsRowLabel('播放信息'),
                              const SizedBox(height: 8),
                              Text(
                                '分辨率: $_resolutionText',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: AppTheme.fontFootnote,
                                ),
                              ),
                              if (_bitrateText.isNotEmpty)
                                Text(
                                  '码率: $_bitrateText',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: AppTheme.fontFootnote,
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
        await AudioFocus.request('video');
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
          AudioFocus.request('video');
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
          AudioFocus.request('video');
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
      // 「进入后台暂停」：开了就暂停播放，否则按原逻辑自动进小窗
      if (_pauseOnBackground && _player.state.playing) {
        _player.pause();
        return;
      }
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

    // ⚠️ 必须在任何 await **之前**上锁：
    // 旧写法把 _autoPipInFlight = true 放在 await isIosPipSupported() 之后，
    // iOS 退后台时 inactive→paused 会连投两次，两次都能穿过上面的检查 →
    // 并发 enterIos() 覆盖 VideoPlayerPip 的单槽 _iosOnStarted，导致
    // 「小窗弹出了但 _pipActive 丢失」。下面用 try/finally 保证任何返回路径都解锁。
    _autoPipInFlight = true;
    try {
      bool supported;
      try {
        supported = await VideoPlayerPip.instance.isIosPipSupported();
      } catch (_) {
        supported = false;
      }
      if (!supported) return;

      final currentPos = _player.state.position;
      // 单实例：进小窗不暂停，与手动 PiP 相同
      if (!_player.isSharedIosAv) return;
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
          AudioFocus.request('video');
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
    AppToast.message(text, duration: const Duration(seconds: 3), isError: true);
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
        // 按你的要求把底部功能栏**整体下移**：
        // 原来还吃了安全区内边距（mediaPadding.bottom），但视频区本身并不
        // 贴到屏幕物理底边，这段内边距纯属多余 → 去掉后整栏往下走。
        padding: EdgeInsets.only(
          bottom: 0,
          left: mediaPadding.left,
          right: mediaPadding.right,
        ),
        child: child,
      ),
    );
  }

  /// 播放器功能按钮（顶栏 / 底栏共用）
  ///
  /// iOS 化的关键：图标不再"裸"放在视频上，而是坐进一个
  /// 「轻玻璃圆角方块」——半透明白底 + 0.5 细描边 + 圆角 10。
  /// 这样在亮/暗画面上都有一致的可读底衬，也不会像纯图标那样糊在一起。
  ///
  /// [filled] 用于主操作（播放/暂停），底色与图标都更重，视觉上排第一。
  Widget _iconButton({
    required IconData icon,
    required double size,
    double width = 38,
    double height = 38,
    required VoidCallback onTap,
    Widget? child,
    bool filled = false,
  }) {
    final side = height < 38 ? 38.0 : height;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: width < side ? side : width,
        height: side,
        child: Center(
          child: Container(
            width: side - 4,
            height: side - 4,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: filled ? 0.22 : 0.13),
              borderRadius: BorderRadius.circular(filled ? 12 : 10),
              border: Border.all(
                color: Colors.white.withValues(alpha: filled ? 0.34 : 0.18),
                width: 0.5,
              ),
            ),
            child:
                child ??
                Icon(icon, color: Colors.white, size: filled ? size + 2 : size),
          ),
        ),
      ),
    );
  }

  /// 底部功能栏的弹幕开关 —— 参考图样式：
  /// 圆角方块内一个「弹」字，开启时右下角带绿色对勾角标。
  /// 关闭时整体变暗（不用字幕图标，避免与系统字幕混淆）。
  ///
  /// ── ⚠️ 为什么现在**总是显示** ────────────────────────────────
  /// 原来它在底部栏的条件是 `if (_danmuApiUrl.isNotEmpty)`，
  /// 结果：**没配过弹幕 API 地址的用户完全看不到这个按钮** ——
  /// 既不知道播放器支持弹幕，也找不到入口去配。
  /// 用户实测反馈："这个红框位置不是说加个弹幕的开关图标么？"——
  /// 位置是对的（底部栏 播放/暂停 的右边、音量的左边），
  /// 但因为那个条件，它压根没渲染出来。
  ///
  /// 现在改成**常显**：没配地址时点它会明确告知并直达设置页，
  /// 而不是"什么都不发生"或"按钮消失"。
  Widget _danmuToggleButton() {
    final on = _danmuOn;
    final configured = _danmuApiUrl.isNotEmpty;
    // 设置还没读出来时，按"中性"显示（不显示成未配置的暗态）
    final ready = _danmuSettingsReady;
    return _iconButton(
      icon: Icons.subtitles,
      size: 20,
      width: 38,
      onTap: () => _safeTap(() async {
        if (ready && !configured) {
          // 没配弹幕源：说清原因 + 把用户送过去配，而不是静默无反应
          AppToast.message(
            '还没配置弹幕源：播放器设置 → 弹幕 → 填入弹幕 API 地址',
            duration: const Duration(seconds: 3),
            isError: true,
          );
          Get.to(() => const DanmuSettingsPage());
          return;
        }
        setState(() => _danmuOn = !_danmuOn);
        await _persistDanmuOn();
      }),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          // 注意：外层 _iconButton 已提供玻璃底，这里不再套一层带背景的
          // 容器（会变成双层底、边线重影）。关闭态用文字透明度区分。
          Text(
            '弹',
            style: TextStyle(
              // 没配弹幕源时更暗一档：和"已配置但关闭"区分开
              color: on && configured
                  ? Colors.white
                  : Colors.white.withValues(
                      alpha: !ready ? 0.4 : (configured ? 0.4 : 0.28)),
              fontSize: AppTheme.fontHeadline,
              fontWeight: FontWeight.w600,
              height: 1.0,
            ),
          ),
          // 开启角标：绿色对勾
          if (on && configured)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                width: 13,
                height: 13,
                decoration: BoxDecoration(
                  color: AppTheme.accentColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.black54, width: 1),
                ),
                child: const Icon(Icons.check, size: 9, color: Colors.white),
              ),
            ),
        ],
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

  /// 右侧数值文案（如 "100%" / "25px" / "适中"）。空则只显示左标签。
  final String? valueText;

  /// 滑条下方的刻度标注（如 ['1/4','半屏','3/4','满屏']），均匀分布。
  final List<String>? ticks;

  const _DanmuSliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.onChanged,
    this.valueText,
    this.ticks,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        // 左标签 + 右数值（对齐参考图：不透明度 …… 100%）
        Row(
          children: [
            _SettingsRowLabel(label),
            const Spacer(),
            if (valueText != null && valueText!.isNotEmpty)
              Text(
                valueText!,
                style: TextStyle(
                  color: AppTheme.accentColor,
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
        const SizedBox(height: 2),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            activeColor: AppTheme.accentColor,
            inactiveColor: Colors.white.withValues(alpha: 0.14),
            onChanged: onChanged,
          ),
        ),
        // 刻度行：两端对齐，中间均匀分布
        if (ticks != null && ticks!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: ticks!
                  .map(
                    (t) => Text(
                      t,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.45),
                        fontSize: AppTheme.fontCaption,
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
      ],
    );
  }
}
