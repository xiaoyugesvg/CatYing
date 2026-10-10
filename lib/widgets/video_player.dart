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
import 'stall_detector.dart';
import '../services/audio_focus.dart';
import 'app_toast.dart';
import '../pages/settings/sub/danmu_settings_page.dart';
import '../models/player_engine.dart';
import '../services/player_prefs.dart';
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

  /// 底部工具栏距底部的间距（默认 0 贴底；媒体库播放器传大一点让整栏往上挪）
  final double bottomBarBottomPadding;

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

  /// 抖音模式（短剧模式）下，无剧集可切（电影）时的上/下一部电影回调。
  /// 有剧集时切集走 [onPlayNext]/[onPlayPrevious]，电影时用这两个。
  final VoidCallback? onDramaNextMovie;
  final VoidCallback? onDramaPrevMovie;
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
    this.bottomBarBottomPadding = 0.0,

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
    this.onDramaNextMovie,
    this.onDramaPrevMovie,
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

  // ── 加载卡死检测（复核发现的严重缺口）────────────────────────────
  //
  // 原来**媒体加载完全没有超时**：
  //   · 弹幕 HTTP 有 8s/12s 超时，但 `_player.open(...)` **一处超时都没有**
  //   · 采集源给的 CDN 直链挂起（不发数据也不断开）时，
  //     media_kit **不会**抛 error 事件 → `_isBuffering` 永远为 true
  //     → **转圈无限转**，用户不知道是"在加载"还是"坏了" ✗
  //   · 更糟的是：详情页的重试按钮**只在 `onError` 被调用后才出现**
  //     → 连接挂起时**连重试按钮都不出来** ✗
  //
  // 现在自己数：缓冲中且**播放位置连续 N 秒没前进** → 判为卡死，
  // 换成一条**可点重试**的提示（不依赖 media_kit 的 error 事件 ✓）。

  /// 「加载卡死」判定（纯逻辑，见 `stall_detector.dart` 的说明）。
  ///
  /// 抽成独立类是为了**可测**：这个 State 依赖 media_kit 原生库，
  /// 测试里构造不出来，判定逻辑埋在里面就没法验证。
  final StallDetector _stall = StallDetector();

  /// 卡死检测定时器（每秒 tick 一次）
  Timer? _stallTimer;

  /// 当前是否已判定卡死（给 UI 用的镜像，避免每帧问 detector）
  bool _loadStalled = false;

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
  /// 正在加载的弹幕地址（去重锁）。
  ///
  /// ⚠️ 为什么不用 bool 锁 ✗：换集时"旧集请求还在飞"，bool 锁会把**新集**
  ///   的加载直接挡掉 ✗，且旧请求结束时 gen 已过期、锁清不掉 → **永久卡死** ✗✗。
  ///   用"地址"做锁：同地址不重复发 ✓，换集（地址变了）照常放行 ✓。
  String? _danmuInFlightUrl;

  /// 弹幕**设置**是否已从 prefs 读出来（`_loadDanmuSettings` 是异步的）。
  /// 首帧它还是 false，此时不能因为 `_danmuApiUrl` 为空就显示成"未配置"
  /// ——否则按钮会先暗一下再变亮（读盘可能跨帧）。
  bool _danmuSettingsReady = false;
  String _danmuApiUrl = '';

  /// 弹幕服务来源（设置页「弹幕服务来源」）：local / builtin / remote。
  /// 播放器按来源解析最终地址（见 `_resolveDanmuUrl`）。
  String _danmuSource = 'remote';

  /// 按来源解析最终弹幕地址：
  ///   · local   → 本机弹幕服务（固定地址）
  ///   · builtin → 订阅下发的弹幕地址（目前订阅无下发机制，回退远程）
  ///   · remote  → 用户在设置页填的地址
  String _resolveDanmuUrl(String raw, String source) {
    if (source == 'local') return 'http://127.0.0.1:11402';
    return raw;
  }

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
  /// 弹幕显示区域：弹幕可用高度占整个播放器的比例（0.25 ~ 1.0）。
  /// 由外层用 FractionallySizedBox 限制高度，这里只用于轨道数推算。
  double _danmuAreaRatio = 1.0;

  /// 弹幕顶部间距（占视频高度百分比）—— 避开顶部标题栏
  double _danmuTopPadding = 0.0;
  /// 弹幕底部间距（占视频高度百分比）—— 避开底部控制栏
  double _danmuBottomPadding = 0.0;

  /// 行间距系数（1.0 ~ 3.0），影响轨道纵向间距
  double _danmuLineSpacing = 1.6;

  /// 描边宽度（0 ~ 3）
  double _danmuStrokeWidth = 1.5;

  /// 字体粗细
  FontWeight _danmuFontWeight = FontWeight.w500;

  /// 弹幕延迟（秒）：正数=晚出现，负数=提前
  double _danmuDelaySeconds = 0.0;

  /// 弹幕颜色模式：'builtin' 自带色 / 'white' 统一白色 / 'custom' 自定义
  String _danmuColorMode = 'builtin';
  /// 自定义弹幕颜色（colorMode='custom' 时生效）
  Color _danmuCustomColor = Colors.white;

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

  /// 弹幕**结果**缓存（进程内）：key 与 `_danmuEpCache` 同构（片名|年份|集号）。
  /// 同一集重进时直接返回，连 `comment/$episodeId` 都不用发 → 秒出。
  static final Map<String, List<DanmuItem>> _danmuTitleListCache = {};

  late VideoFitType _videoFit;
  double _volume = 1.0;
  // 应用内亮度遮罩：1.0 = 不遮（系统亮度）。默认不要半黑。
  double _brightness = 1.0;

  /// 内部追踪 native fullscreen 状态（与 mpv / OS 窗口同步）
  bool _isNativeFullscreen = false;

  /// iOS / 移动端 immersive 状态（WindowFullScreen 在 iOS 是 no-op）
  bool _isImmersive = false;

  /// 短剧模式：纯竖屏全屏（锁 portraitUp，画面按原比例居中带黑边，
  /// 类似媒体库播放器的竖屏）。开启时 _isImmersive/_isNativeFullscreen
  /// 同样为 true（复用全屏布局/状态栏逻辑）。
  bool _dramaMode = false;

  /// 抖音模式：纯竖屏全屏 + 中间滑动切集 + 右侧竖排切换胶囊
  /// （↟ 上一集 / ⏩ / ↡ 下一集，抖音风格操作栏）。
  /// 与短剧模式互斥；同样复用全屏布局/状态栏逻辑。
  bool _douyinMode = false;

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

    // 启动"加载卡死"检测（缓冲期间每秒看位置有没有前进）
    _startStallWatch();

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
        if (error.isEmpty) return;
        // ── 🔴 错误内容必须写日志（复核发现它原来被完全丢掉）──────────
        // `onError` 是**无参**的 `VoidCallback`，所以错误详情到不了 UI；
        // 而这里原来连日志都不打 ⇒ 现场**没有任何可排查的证据** ✗
        AppLog.instance.log('[video_player] stream error: $error');
        // 出错时把"卡死"提示收起来（下面那个可点重试的提示会接管）
        if (mounted && _loadStalled) {
          setState(() => _loadStalled = false);
        }
        widget.onError?.call();
      }),
    );

    _playerSubs.add(
      _player.stream.playing.listen((playing) {
        if (mounted) {
          setState(() {
            _isPlaying = playing;
            // ── 🟡 只在**确实没在缓冲**时才清（修"转圈闪现"）──────────
            //
            // 原来**无条件**清 ✗：缓冲中 `playing` 变 true 时会把转圈
            // 提前抹掉（直到下一个 buffering 事件才纠正）→ 视觉上闪一下。
            // 现在读一次 player 的真实缓冲状态再决定 ✓
            if (!_player.state.buffering) {
              _isBuffering = false;
            }
            // 暂停时常显控制条；开播后再按空闲隐藏
            if (!playing) {
              _showControls = true;
            }
          });
          if (playing) {
            _scheduleHideControls();
            widget.onPlaying?.call();
            _applyPendingResumeSeek();
            // ── 🔴 开播时**重读**弹幕地址，再试一次加载（修一个真 bug）──
            //
            // 用户实测反馈：「填进去，弹幕不显示」（**所有片都不显示**）。
            //
            // 根因是**时序**：`_loadDanmuSettings()` 只在 `initState` 那条路径
            // 调一次（`:582`）→ `_danmuApiUrl` 一辈子只读一次 ✗ 于是：
            //   ① 先开播（那时还没填地址）→ `_danmuApiUrl = ''`
            //   ② 再去设置里填地址 → 存进 prefs ✓，但**运行中的播放器不重读** ✗
            //   ③ 下面那句判断又被 `_danmuApiUrl.isNotEmpty` **挡住** ✗
            //   ⇒ 播放器永远不知道地址存在 ⇒ **一条弹幕都不加载** ✗
            //（这也解释了为什么"重启 App 后就能显示"。）
            //
            // 现在：**每次开播都重读一次地址**（读 prefs 很便宜，且只在
            // `playing` 变 true 时触发）✓；地址**变了**就清掉 `_danmuLoaded`
            // 允许重新拉取 ✓
            if (!_danmuLoaded) {
              _refreshDanmuApiUrlIfNeeded().then((_) {
                if (mounted && !_danmuLoaded && _danmuApiUrl.isNotEmpty) {
                  _ensureDanmuLoaded(urlOverride: widget.url);
                }
              });
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

        // ── 🟡 清缓冲标志必须进 setState（修"靠巧合消失"）────────────
        //
        // 原来是在 setState **外面**赋值 ✗ —— 而这个监听回调里
        // **根本没有 setState**。它之所以"看起来能消失"，
        // 是因为 `_positionVN` 是个 `ValueNotifier`，它一变会让
        // **进度条那一带**局部重建，中间那个转圈恰好在受影响范围内
        // ⇒ **靠巧合工作** ✗：一旦把转圈挪到别的子树就会卡住不消失。
        //
        // 现在：位置真的有前进（>0）时就明确重建一次 ✓。
        // ⚠️ 只在标志确实要变时才 setState，避免每 20ms 都整树重建。
        if (_isBuffering && position > Duration.zero) {
          setState(() => _isBuffering = false);
        }

        // 告诉卡死检测"位置有前进"（内部会按整秒去重）
        _stall.markProgress(position.inSeconds);

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

          // ── 🔴 周期性检测「弹幕地址」是否刚被改过（修一个真 bug）────
          //
          // 用户反馈：「填进去，弹幕不显示」（所有片都不显示）。
          // 完整根因：**播放器自己就能打开弹幕设置页**
          //（`:4390` 的 `Get.to(DanmuSettingsPage)`）——
          // 也就是用户常常是"**正在播着的时候**去填地址"的 ✗
          // 而 `_danmuApiUrl` 只在 `initState` 读一次 →
          // 填完地址后当前这次播放**永远不会加载弹幕** ✗
          //
          // 这里借"每秒一次的位置回调"做一次便宜的检测：
          // 地址变了 → `_danmuLoaded` 被清掉 → 立刻重新拉一次 ✓
          // （只读一个 prefs key，开销可忽略；`_refreshDanmuApiUrlIfNeeded`
          //   内部有"没变就直接 return"的短路 ✓）
          if (!_danmuLoaded) {
            _refreshDanmuApiUrlIfNeeded().then((_) {
              if (mounted && !_danmuLoaded && _danmuApiUrl.isNotEmpty) {
                _ensureDanmuLoaded(urlOverride: widget.url);
              }
            });
          }
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
        // 换集是新一次加载 → 清掉上一集的"卡死"判定
        _loadStalled = false;
      });
      _resetStallWatch();
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
    // 新一次加载开始 → 复位"卡死"计时（否则上一集的计时会立刻误报）
    _resetStallWatch();
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

  /// 轻量重读「弹幕 API 地址」；**地址变了**就把 `_danmuLoaded` 清掉，
  /// 让本次播放能重新拉一次弹幕。
  ///
  /// 为什么需要它：用户常常是**先开播、后去设置里填地址**的
  ///（见 `playing` 监听里那段说明）。只读一次会造成"填了不生效"。
  ///
  /// ⚠️ 只重读**地址**这一项，不重读字号/速度等样式 ——
  ///    那些在播放中被改时本来就会即时生效，重读反而可能覆盖用户的临时调整。
  Future<void> _refreshDanmuApiUrlIfNeeded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final src = prefs.getString('danmu_source') ?? 'remote';
      _danmuSource = src;
      final latest = _resolveDanmuUrl(
          (prefs.getString('danmu_api_url') ?? '').trim(), src);
      if (latest == _danmuApiUrl) return;
      _danmuApiUrl = latest;
      // 地址变了 → 之前"已加载过"的结论作废，允许重新拉
      _danmuLoaded = false;
      AppLog.instance.log('[video_player] danmu api url 变为: '
          '${latest.isEmpty ? "（空）" : latest}');
    } catch (e) {
      AppLog.instance.log('[video_player] 重读弹幕地址失败: $e');
    }
  }

  /// 读取弹幕配置（设置页配置的 Logvr-danmu / 弹弹play 兼容 API 地址）
  Future<void> _loadDanmuSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _danmuSource = prefs.getString('danmu_source') ?? 'remote';
      _danmuApiUrl = _resolveDanmuUrl(
          (prefs.getString('danmu_api_url') ?? '').trim(), _danmuSource);
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
      // 弹幕上下边距（避开功能栏）
      _danmuTopPadding =
          (prefs.getDouble('danmu_top_padding') ?? 0.0).clamp(0.0, 0.5);
      _danmuBottomPadding =
          (prefs.getDouble('danmu_bottom_padding') ?? 0.0).clamp(0.0, 0.5);
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
      // 弹幕颜色模式：builtin / white / custom（默认自带色）
      _danmuColorMode = prefs.getString('danmu_color_mode') ?? 'builtin';
      final customColorVal = prefs.getInt('danmu_custom_color');
      if (customColorVal != null) {
        _danmuCustomColor = Color(customColorVal);
      }
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

    // ✅ 用户 2026-10-08：「半天不出来」—— 原来 `_danmuLoaded = true`
    //   放在**请求之前** ✗：一旦网络波动请求失败，整个播放会话都不会再重试，
    //   用户看到的就是"永远 0 条弹幕" ✗✗。
    //   现在：请求成功 / 明确 0 条才置位 ✓；失败则留着让下次还能重试 ✓。
    //   ⚠️ 去重：**同一个地址**正在加载时不重复发 ✓（换集地址不同 → 照常放行 ✓）。
    if (_danmuInFlightUrl == url) return;
    _danmuInFlightUrl = url;
    try {
      await _doLoadDanmu(url, loadGen);
    } finally {
      if (_danmuInFlightUrl == url) _danmuInFlightUrl = null;
    }
  }

  /// 实际发请求 + 兜底链路。抽出来是因为上面那层只负责"要不要加载"的闸门。
  Future<void> _doLoadDanmu(String url, int loadGen) async {
    // 片名 / 集数：url 匹配失败时用于「按片名兜底匹配」
    final title = (widget.videoTitle ?? '').trim();
    final epName = (widget.currentEpisodeName ?? '').trim();
    // url 命中不到时是否还值得用片名兜底（仅 http(s) 播放地址）
    final titleFallbackUsable = title.isNotEmpty && url.startsWith('http');

    final base = _danmuApiBase();
    // ✅ 修复：前面已经有 `?url=`，这里统一用 `&` 接 format
    //   （原来 titleFallbackUsable=true 时会拼成 ?url=xxx?format=json —— 两个问号 ✗）
    final api =
        '$base/api/v2/comment?url=${Uri.encodeQueryComponent(url)}&format=json';
    // 记录实际请求（含被匹配的视频地址）：该服务只支持 commentId / url，
    // 「查不到弹幕」时唯一能核对的证据就是这条请求 URL。
    AppLog.instance.log('[video_player] danmu request: $api');

    // ✅ 2026-10-08「半天不出来」：URL 探测 与 片名搜索 **并行发出** ✓
    //   原来 URL 探测返回 0 条后才串行发搜索 ✗ → 白白多等一整轮往返 ✓。
    //   两者互不依赖（搜索只用片名 ✓），并行后兜底链路少 1 个 RTT ✓。
    //   ⚠️ 只有 `titleFallbackUsable` 时才发搜索，避免无谓请求 ✓。
    final urlFuture = _danmuGetText(api);
    Future<String>? searchFuture;
    if (titleFallbackUsable) {
      var clean = TmdbService.cleanTitle(title);
      if (clean.isEmpty) clean = title;
      searchFuture = _danmuGetText(
        '$base/api/v2/search/anime?keyword=${Uri.encodeQueryComponent(clean)}',
      );
    }

    var list = await parseDanmuBodyAsync(await urlFuture);

    // ---- 按片名兜底 ----
    // 该弹幕服务的 url 匹配要求播放地址与库里索引的**标准平台地址**完全一致；
    // spider 源给的多是 CDN 直链（带签名/会变），几乎必然 0 条。
    // 服务同时提供 搜索→分集→弹幕 三步链路，此处作为兜底。
    var danmuSource = 'url';
    if (list.isEmpty && titleFallbackUsable) {
      list = await _danmuFetchByTitle(
        base,
        title,
        epName,
        url,
        searchFuture: searchFuture,
      );
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
    if (!mounted || loadGen != _danmuLoadGen) return;
    setState(() {
      _danmus = list;
      // ✅ 有结果（哪怕 0 条）才标记"已加载"，失败不算 —— 失败了还能重试
      _danmuLoaded = true;
    });
  }

  // ============================================================
  // 加载卡死检测
  // ============================================================

  /// 启动卡死检测：缓冲期间每秒看一次"播放位置有没有前进"。
  ///
  /// 为什么不靠 media_kit 的 error 事件：
  ///   **连接挂起**（服务器收下请求但不发数据、也不断开）在多数
  ///   播放内核里**不会**产生 error 事件 —— 它只是永远不 ready。
  ///   这时候用户看到的是"转圈无限转"，而且详情页的重试按钮
  ///   （它挂在 `onError` 回调上）**根本不会出现** ✗
  ///
  /// 所以这里自己数时间：只要"在缓冲 + 位置 N 秒没动"就判卡死。
  void _startStallWatch() {
    _stallTimer?.cancel();
    _stallTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final justStalled = _stall.tick(
        buffering: _isBuffering,
        playing: _isPlaying,
      );
      if (justStalled) {
        AppLog.instance.log(
          '[video_player] 加载卡死：缓冲中已 '
          '${_stall.idleFor(DateTime.now()).inSeconds}s 位置未前进 '
          '（url=${widget.url}）',
        );
        setState(() {
          _loadStalled = true;
          // ── 🔴 必须**强制显示控制条**（否则提示根本看不见）──────────
          //
          // 那个"加载超时 / 点这里重试"的提示挂在
          // `_buildCenterSeekButtons()` 里，而它只在
          // `_showControls && !_isLocked` 时渲染（见 build 里那处）。
          //
          // 播放中途卡死时，控制条**往往已经自动隐藏了**（`_hideTimer` 到期）
          // → 提示不显示 → 用户还是只看到"画面冻住" ✗
          // 所以判定卡死时顺手把控制条拉出来 ✓
          _showControls = true;
        });
        // 并且取消待执行的"自动隐藏"，否则 2~3 秒后提示又被藏掉
        _hideTimer?.cancel();
      } else if (!_stall.stalled && _loadStalled) {
        // detector 已经不认为卡死了（缓冲结束 / 位置恢复）→ 收回提示
        setState(() => _loadStalled = false);
      }
    });
  }

  /// 新的媒体开始加载时复位卡死检测（换集/重试/新 URL 都要调）。
  void _resetStallWatch() {
    _stall.reset();
    _loadStalled = false;
  }

  /// 卡死提示上的「重试」：重新打开当前媒体。
  ///
  /// 不依赖详情页那个重试按钮（它只在 `onError` 时出现），
  /// 所以"连接挂起"这种**没有 error 事件**的情况也能恢复 ✓
  void _retryLoad() {
    AppLog.instance.log('[video_player] 用户点重试加载: ${widget.url}');
    setState(() {
      _isBuffering = true;
      _loadStalled = false;
      // 重试后要让用户看到转圈与控制条（否则像点了没反应）
      _showControls = true;
      _position = Duration.zero;
      _duration = Duration.zero;
      _positionVN.value = Duration.zero;
      _durationVN.value = Duration.zero;
    });
    _resetStallWatch();
    // 重试期间别把控制条自动藏掉
    _hideTimer?.cancel();
    if (_ownsPlayer) {
      _openMedia();
    } else {
      // 外部 Player：父级负责 open，这里只做兜底 seek
      _persisted.resumeApplied = false;
      _scheduleResumeSeek();
    }
  }

  /// 弹幕请求**共用**的 HttpClient（连接复用）。
  ///
  /// 原来每个请求都 new 一个 client 再 `close(force: true)` ✗ —— 而兜底
  /// 链路一次要发 3~4 个请求（搜索/番剧/分集/弹幕）✓，每次重做 TCP+TLS
  /// 握手是「出来慢」的一部分 ✓。常驻一个 client + keep-alive 复用 socket
  /// 即可省掉后续几次握手 ✓。生命周期跟随本 widget（见 [dispose]）。
  HttpClient? _danmuHttpClient;

  HttpClient get _danmuClient =>
      _danmuHttpClient ??=
          (HttpClient()..connectionTimeout = const Duration(seconds: 6));

  /// 取文本（弹幕接口专用；失败返回空串，不抛）
  ///
  /// ⚠️ 超时从 12s 收到 8s：弹幕是**锦上添花**的功能 ✓，
  ///   而兜底链路最多要串 4 个请求 ✗ → 12s 时最坏要等近 1 分钟才出弹幕 ✗✗
  ///   （用户反馈「半天不出来」的主因之一 ✓）。8s 足够正常网络往返 ✓，
  ///   慢到 8s 还没回的接口本来也基本拉不到数据 ✓。
  Future<String> _danmuGetText(String api) async {
    final client = _danmuClient;
    try {
      final http = await client
          .getUrl(Uri.parse(api))
          .timeout(const Duration(seconds: 8));
      http.headers.set('User-Agent', 'NewTv/1.0');
      final res = await http.close().timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        AppLog.instance.log(
          '[video_player] danmu HTTP ${res.statusCode} ($api)',
        );
        return '';
      }
      return await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      AppLog.instance.log('[video_player] danmu request fail: $e');
      return '';
    }
  }

  /// 片名 → 弹幕的兜底链路：搜索番剧 → 取分集 → 取弹幕。
  ///
  /// 解析结果按「片名|年份|集号」缓存（进程内），避免每一集都跑 3 次请求：
  /// 该服务有速率限制，实测密集请求会返回 429。
  ///
  /// ✅ 2026-10-08「半天不出来」优化：
  ///   · [searchFuture] —— 调用方可以**并行**发起「搜索番剧」，
  ///     这样 URL 探测失败时不用再等一整轮往返 ✓（省 1 个 RTT ✓）。
  ///   · `_danmuTitleListCache` —— 同一集**重进**时直接命中缓存 ✓，
  ///     连 `comment/$episodeId` 都不用发 ✓。
  Future<List<DanmuItem>> _danmuFetchByTitle(
    String base,
    String title,
    String episodeName,
    String videoUrl, {
    Future<String>? searchFuture,
  }) async {
    // 片名清洗：优先复用 TMDB 的清洗规则（去「更新至N集/第N季/4K/中字」等噪音）
    var clean = TmdbService.cleanTitle(title);
    // 该服务搜索对「【】」等括号敏感，直接搜原始标题命中率反而更高
    if (clean.isEmpty) clean = title;
    // 年份用于缓存键隔离（同名不同年的剧不要互相串缓存）
    final year = TmdbService.extractYear('', '');

    final cacheKey =
        '${clean.toLowerCase()}|${year ?? ''}|${widget.selectedEpisodeIndex}';
    // ✅ 先看"整集弹幕"缓存：命中就秒出（不用再走 search→bangumi→comment）
    final cachedList = _danmuTitleListCache[cacheKey];
    if (cachedList != null) {
      AppLog.instance.log(
        '[video_player] danmu title-fallback 结果缓存命中: $cacheKey',
      );
      return cachedList;
    }
    final cached = _danmuEpCache[cacheKey];
    if (cached != null) {
      AppLog.instance.log(
        '[video_player] danmu title-fallback episodeId 命中: $cacheKey',
      );
      final list = await _danmuFetchComments(base, cached);
      if (list.isNotEmpty) _danmuTitleListCache[cacheKey] = list;
      return list;
    }

    // ① 搜索番剧（若调用方已并行发起，直接复用那个 future，省一轮往返）
    final String searchBody;
    if (searchFuture != null) {
      searchBody = await searchFuture;
    } else {
      final searchUrl =
          '$base/api/v2/search/anime'
          '?keyword=${Uri.encodeQueryComponent(clean)}';
      searchBody = await _danmuGetText(searchUrl);
    }
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
    final list = await _danmuFetchComments(base, episodeId);
    // ✅ 存"整集弹幕"结果缓存 → 重进同一集秒出
    if (list.isNotEmpty) _danmuTitleListCache[cacheKey] = list;
    return list;
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
    return parseDanmuBodyAsync(body);
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
      await prefs.setDouble('danmu_top_padding', _danmuTopPadding);
      await prefs.setDouble('danmu_bottom_padding', _danmuBottomPadding);
      await prefs.setBool('danmu_sync_speed', _danmuSyncSpeed);
      await prefs.setString('danmu_color_mode', _danmuColorMode);
      await prefs.setInt('danmu_custom_color', _danmuCustomColor.value);
      await prefs.setDouble('danmu_line_spacing', _danmuLineSpacing);
      await prefs.setDouble('danmu_stroke_width', _danmuStrokeWidth);
      await prefs.setInt('danmu_font_weight', _danmuFontWeight.value);
      await prefs.setDouble('danmu_delay_seconds', _danmuDelaySeconds);
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

  /// 持久化快进/快退步长（5 / 10 / 15 / 30 秒）
  Future<void> _persistSeekStep() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('play_time_step', _userSeekStep);
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

  // ============================================================
  // 短剧模式：纯竖屏全屏（按钮参考弹幕：「短」字）
  // ============================================================

  Future<void> _toggleDramaMode() async {
    if (VideoPlayerPip.instance.isActive) {
      await VideoPlayerPip.instance.exit();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (_dramaMode) {
      await _exitDramaMode();
    } else {
      await _enterDramaMode();
    }
  }

  /// 进入短剧模式：锁竖屏 + immersive 全屏（与直播播放器同款轻量实现：
  /// SystemUiController 沉浸 + 方向锁，不走系统全屏转场，视频不停）。
  /// 画面按当前画幅比例居中（横视频上下黑边），类似媒体库播放器竖屏。
  Future<void> _enterDramaMode() async {
    AppLog.instance.log('=== _enterDramaMode: start ===');
    // 若正处于横屏全屏，先退出还原方向，避免方向锁冲突
    if (WindowFullScreen.instance.isActive || _isImmersive) {
      await _exitFullScreen();
    }
    // 与抖音模式互斥
    _douyinMode = false;
    if (mounted) {
      setState(() {
        _dramaMode = true;
        _isImmersive = true;
        _isNativeFullscreen = true;
        _persisted.isImmersive = true;
        _persisted.isNativeFullscreen = true;
      });
    } else {
      _dramaMode = true;
      _isImmersive = true;
      _isNativeFullscreen = true;
      _persisted.isImmersive = true;
      _persisted.isNativeFullscreen = true;
    }
    widget.onFullScreenChanged?.call(true);
    // 直播同款：SystemUiController 沉浸 + 锁竖屏
    await SystemUiController.enter(
      'videoDrama',
      mode: SystemUiMode.immersiveSticky,
      orientations: Platform.isIOS
          ? const [DeviceOrientation.portraitUp]
          : null,
      overlayStyle: SystemUiOverlayStyle.light,
    );
    try {
      if (!_player.state.playing) {
        await AudioFocus.request('video');
        await _player.play();
      }
    } catch (e) {
      AppLog.instance.log('[video_player] swallowed: $e');
    }
  }

  Future<void> _exitDramaMode() async {
    AppLog.instance.log('=== _exitDramaMode: start ===');
    // 先**同步**清掉短剧模式并刷新按钮/布局：
    // 系统栏还原/方向解锁是异步的，await 它会让视觉退出被拖住
    // —— 表现就是"点了闪一下但模式不退"。先 setState 立即退出模式。
    if (mounted) {
      setState(() {
        _dramaMode = false;
        _isImmersive = false;
        _isNativeFullscreen = false;
        _persisted.isImmersive = false;
        _persisted.isNativeFullscreen = false;
      });
    } else {
      _dramaMode = false;
      _isImmersive = false;
      _isNativeFullscreen = false;
      _persisted.isImmersive = false;
      _persisted.isNativeFullscreen = false;
    }
    widget.onFullScreenChanged?.call(false);
    // 直播同款：SystemUiController.exit 还原进入前方向/系统栏
    await SystemUiController.exit('videoDrama');
    try {
      if (!_player.state.playing) {
        await AudioFocus.request('video');
        await _player.play();
      }
    } catch (e) {
      AppLog.instance.log('[video_player] swallowed: $e');
    }
  }

  /// 抖音模式切换（点「抖」进入/退出）
  Future<void> _toggleDouyinMode() async {
    if (VideoPlayerPip.instance.isActive) {
      await VideoPlayerPip.instance.exit();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (_douyinMode) {
      await _exitDouyinMode();
    } else {
      await _enterDouyinMode();
    }
  }

  /// 进入抖音模式：锁竖屏 + immersive 全屏（与直播播放器同款轻量实现）。
  /// 画面按当前画幅比例居中（横视频上下黑边），与短剧模式互斥。
  /// 区别：抖音模式右侧有竖排切换胶囊（↟ 上一集/⏩/↡ 下一集），
  /// 短剧模式只有中间滑动切集。
  Future<void> _enterDouyinMode() async {
    AppLog.instance.log('=== _enterDouyinMode: start ===');
    // 若正处于横屏全屏，先退出还原方向，避免方向锁冲突
    if (WindowFullScreen.instance.isActive || _isImmersive) {
      await _exitFullScreen();
    }
    _dramaMode = false;
    if (mounted) {
      setState(() {
        _douyinMode = true;
        _isImmersive = true;
        _isNativeFullscreen = true;
        _persisted.isImmersive = true;
        _persisted.isNativeFullscreen = true;
      });
    } else {
      _douyinMode = true;
      _isImmersive = true;
      _isNativeFullscreen = true;
      _persisted.isImmersive = true;
      _persisted.isNativeFullscreen = true;
    }
    widget.onFullScreenChanged?.call(true);
    // 直播同款：SystemUiController 沉浸 + 锁竖屏
    await SystemUiController.enter(
      'videoDouyin',
      mode: SystemUiMode.immersiveSticky,
      orientations: Platform.isIOS
          ? const [DeviceOrientation.portraitUp]
          : null,
      overlayStyle: SystemUiOverlayStyle.light,
    );
    try {
      if (!_player.state.playing) {
        await AudioFocus.request('video');
        await _player.play();
      }
    } catch (e) {
      AppLog.instance.log('[video_player] swallowed: $e');
    }
  }

  Future<void> _exitDouyinMode() async {
    AppLog.instance.log('=== _exitDouyinMode: start ===');
    // 同 _exitDramaMode：先同步清模式刷新，再异步还原系统栏/方向
    if (mounted) {
      setState(() {
        _douyinMode = false;
        _isImmersive = false;
        _isNativeFullscreen = false;
        _persisted.isImmersive = false;
        _persisted.isNativeFullscreen = false;
      });
    } else {
      _douyinMode = false;
      _isImmersive = false;
      _isNativeFullscreen = false;
      _persisted.isImmersive = false;
      _persisted.isNativeFullscreen = false;
    }
    widget.onFullScreenChanged?.call(false);
    // 直播同款：SystemUiController.exit 还原进入前方向/系统栏
    await SystemUiController.exit('videoDouyin');
    try {
      if (!_player.state.playing) {
        await AudioFocus.request('video');
        await _player.play();
      }
    } catch (e) {
      AppLog.instance.log('[video_player] swallowed: $e');
    }
  }

  /// 顶栏返回键：全屏/沉浸态先退出全屏（还原方向锁），再执行页面返回。
  ///
  /// 修复：旧实现（全屏时直接 `widget.onBack`）会把 iOS 横屏方向锁
  /// （'videoFullscreen' landscape）带出全屏——返回详情页后整个 App
  /// 滞留横屏，且短剧/抖音模式也不会被清理。
  Future<void> _handleHeaderBack() async {
    final currentlyFull = WindowFullScreen.instance.isActive || _isImmersive;
    if (currentlyFull) {
      await _exitFullScreen();
    }
    widget.onBack?.call();
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
    // 进入横屏全屏时退出短剧/抖音模式（方向/布局冲突）
    _dramaMode = false;
    _douyinMode = false;
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
    // 任何方式退出全屏都同步退出短剧/抖音模式。
    // 状态清理必须**同步 setState 刷新**（iOS 上 WindowFullScreen.exit /
    // unlockOrientations 都是异步/空操作，不等它们视觉上也要立刻退出，
    // 否则出现"闪一下但布局还是全屏/模式还在"）。
    if (mounted) {
      setState(() {
        _dramaMode = false;
        _douyinMode = false;
        _isImmersive = false;
        _isNativeFullscreen = false;
        _persisted.isImmersive = false;
        _persisted.isNativeFullscreen = false;
      });
    } else {
      _dramaMode = false;
      _douyinMode = false;
      _isImmersive = false;
      _isNativeFullscreen = false;
      _persisted.isImmersive = false;
      _persisted.isNativeFullscreen = false;
    }
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
      // ⚠️ 退出全屏必须**强制回竖屏**：
      // unlockOrientations 恢复的是"允许集合"（竖屏 + 左右横屏都允许），
      // 设备当前物理方向是横屏的话会**滞留横屏** —— 表现为退出全屏后
      // 整个界面还是横屏。影视 App 常态竖屏（播放器全屏才横屏），
      // 所以退出后显式锁死竖屏，iOS 会立即转回竖屏。
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
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
    _stallTimer?.cancel();

    // 还原「优先横屏」强制过的方向，避免退出播放器后整个 App 卡在横屏
    if (_landscapeForcedByPref) {
      _landscapeForcedByPref = false;
      SystemUiController.unlockOrientations('videoLandscapePref');
    }
    _batteryStateSub?.cancel();
    // 释放弹幕请求的常驻 HttpClient（连接复用的另一半，见 _danmuClient）
    _danmuHttpClient?.close(force: true);
    _danmuHttpClient = null;
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

        // 缓冲/暂停状态图标统一由画面中间层显示（_buildCenterSeekButtons 正中），
        // 这里不再单独放缓冲圈，避免与中间层重复

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
        // 锁定按钮：仅全屏/沉浸/抖音模式显示（内嵌播放器不显示，
        // 避免占左侧垂直居中位导致中间层快退按钮被迫下移不对称）
        if ((_isNativeFullscreen || _isImmersive) &&
            (_showControls || _isLocked))
          _buildLockButton(),

        // 画面中间：左右两侧快退/快进（与控件同步显隐，锁定态隐藏）
        if (_showControls && !_isLocked) _buildCenterSeekButtons(),

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

  /// 弹幕颜色选择 chip（播放内设置面板用）
  Widget _danmuColorChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    Color? colorDot,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.accentColor.withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected
                ? AppTheme.accentColor
                : Colors.white.withValues(alpha: 0.12),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (colorDot != null) ...[
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: colorDot,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white30, width: 1),
                ),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : Colors.white70,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 弹出自定义颜色选择器（播放内设置面板用，与设置页同一套调色板）
  Future<Color?> _pickCustomDanmuColor() async {
    const palette = [
      Colors.white,
      Colors.red,
      Colors.orange,
      Colors.amber,
      Colors.yellow,
      Colors.green,
      Colors.cyan,
      Colors.blue,
      Colors.purpleAccent,
      Colors.pink,
    ];
    Color selected = _danmuCustomColor;
    return showDialog<Color>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text('选择弹幕颜色',
              style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 260,
            child: GridView.builder(
              shrinkWrap: true,
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 10,
                  ),
              itemCount: palette.length,
              itemBuilder: (_, i) {
                final c = palette[i];
                final isSel = c.value == selected.value;
                return GestureDetector(
                  onTap: () => setDialogState(() => selected = c),
                  child: Container(
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isSel
                            ? AppTheme.accentColor
                            : Colors.white10,
                        width: isSel ? 3 : 1,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消',
                  style: TextStyle(color: Colors.white60)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(selected),
              child: Text('确定',
                  style: TextStyle(color: AppTheme.accentColor)),
            ),
          ],
        ),
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
      topPadding: _danmuTopPadding,
      bottomPadding: _danmuBottomPadding,
      // 弹幕颜色：builtin=null(自带), white=白, custom=自定义
      forceColor: switch (_danmuColorMode) {
        'white' => Colors.white,
        'custom' => _danmuCustomColor,
        _ => null,
      },
    );
    // 显示区域：
    //   · 有 topPadding/bottomPadding 时 → 外层铺满，DanmuLayer 内部按比例定位
    //     （弹幕严格限制在上下功能栏之间）
    //   · 否则回退到旧的 areaRatio（只从顶部往下算）
    final usePadding = _danmuTopPadding > 0.001 || _danmuBottomPadding > 0.001;
    if (usePadding) {
      return Positioned.fill(child: IgnorePointer(child: layer));
    }
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
              _dramaPanDy = 0;
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
                // 短剧/抖音模式（竖屏全屏）：垂直滑动只用于切集
                // （onPanEnd 判定方向），不走亮度/音量手势，避免跟切集冲突
                if (_dramaMode || _douyinMode) {
                  _dramaPanDy += dy;
                  return;
                }
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
              // 短剧/抖音模式：垂直滑动结束判定方向 → 切换集数/影片
              if ((_dramaMode || _douyinMode) &&
                  _gesturePanAxis == PanAxis.vertical) {
                final dy = _dramaPanDy;
                _dramaPanDy = 0;
                if (dy < -60) {
                  _dramaSwitchTo(forward: false); // 上滑 → 上一集/上一部
                } else if (dy > 60) {
                  _dramaSwitchTo(forward: true); // 下滑 → 下一集/下一部
                }
                _gesturePanAxis = null;
                return;
              }
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

  /// 抖音模式下滑动累计位移：上滑（负值）= 上一集/上一部，下滑 = 下一集/下一部
  double _dramaPanDy = 0;

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
            // ⚠️ 全屏/沉浸态必须先退全屏再返回：旧实现全屏时直接 onBack，
            // 横屏方向锁（'videoFullscreen' landscape）无人解锁 →
            // 返回后详情页/整个界面滞留横屏。
            _iconButton(
              icon: Icons.arrow_back_ios_new,
              size: 17,
              onTap: _handleHeaderBack,
            ),

            // 网速/缓冲状态：紧跟返回键右侧（用户要求）
            if (_alwaysShowSpeed && _netSpeedText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 8, right: 6),
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

            const Spacer(),

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
      // 底栏贴底（控件区贴近画面底边）
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
                        ? (_volume < 0.33
                            ? Icons.volume_down
                            : Icons.volume_up)
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
                        _scheduleHideControls();
                        setState(() => _showEpisodeSheet = true);
                      },
                    ),
                  // 弹幕开关：已在底部功能栏（**常显**，不再按是否配置弹幕源隐藏 ——
                  // 隐藏会让用户完全看不到这个功能。未配置时点击会引导去设置页）
                  _danmuToggleButton(),
                  // 播放器核心切换（循环切换当前平台可用的引擎）
                  _engineSwitchButton(),
                  // 短剧模式：纯竖屏全屏
                  _dramaModeButton(),
                  _douyinModeButton(),
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
    // 横屏时面板更紧凑：屏幕宽但纵向空间少，面板占比太大会压视频。
    // 竖屏保持原尺寸；横屏：列数+2、字号略小、整体收窄。
    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;
    final crossAxisCount = isLandscape ? 7 : 5;
    final gridHeight = isLandscape ? 64.0 : 84.0;
    final titleFont = isLandscape ? 13.0 : AppTheme.fontHeadline;
    final itemFont = isLandscape ? 11.0 : AppTheme.fontSubhead;
    final panelMaxHeight = isLandscape ? 104.0 : 130.0;
    final titlePadTop = isLandscape ? 10.0 : 16.0;
    final gridPadTop = isLandscape ? 2.0 : 4.0;
    final gridPadBottom = isLandscape ? 8.0 : 10.0;

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
              constraints: BoxConstraints(maxHeight: panelMaxHeight),
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, titlePadTop, 16, 8),
                    child: Row(
                      children: [
                        Text(
                          '选集',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: titleFont,
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
                    height: gridHeight,
                    child: GridView.builder(
                      padding: EdgeInsets.fromLTRB(16, gridPadTop, 16, gridPadBottom),
                      gridDelegate:
                          SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: crossAxisCount,
                            crossAxisSpacing: 6,
                            mainAxisSpacing: 6,
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
                                fontSize: itemFont,
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

                              // ---- 弹幕颜色 ----
                              const SizedBox(height: 14),
                              Row(
                                children: [
                                  _danmuColorChip(
                                    label: '自带色',
                                    selected: _danmuColorMode == 'builtin',
                                    onTap: () {
                                      refresh(() =>
                                          _danmuColorMode = 'builtin');
                                      _persistDanmuStyle();
                                    },
                                  ),
                                  const SizedBox(width: 8),
                                  _danmuColorChip(
                                    label: '白色',
                                    selected: _danmuColorMode == 'white',
                                    onTap: () {
                                      refresh(
                                          () => _danmuColorMode = 'white');
                                      _persistDanmuStyle();
                                    },
                                  ),
                                  const SizedBox(width: 8),
                                  _danmuColorChip(
                                    label: '自定义',
                                    selected: _danmuColorMode == 'custom',
                                    colorDot: _danmuCustomColor,
                                    onTap: () async {
                                      final c =
                                          await _pickCustomDanmuColor();
                                      if (c == null) return;
                                      refresh(() {
                                        _danmuColorMode = 'custom';
                                        _danmuCustomColor = c;
                                      });
                                      _persistDanmuStyle();
                                    },
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

                              // ---- 顶部间距（避开标题栏）----
                              _DanmuSliderRow(
                                label: '顶部间距',
                                valueText:
                                    '${(_danmuTopPadding * 100).round()}%',
                                value: _danmuTopPadding,
                                min: 0.0,
                                max: 0.3,
                                divisions: 30,
                                onChanged: (v) {
                                  refresh(() => _danmuTopPadding = v);
                                  _persistDanmuStyle();
                                },
                              ),

                              // ---- 底部间距（避开控制栏）----
                              _DanmuSliderRow(
                                label: '底部间距',
                                valueText:
                                    '${(_danmuBottomPadding * 100).round()}%',
                                value: _danmuBottomPadding,
                                min: 0.0,
                                max: 0.3,
                                divisions: 30,
                                onChanged: (v) {
                                  refresh(() => _danmuBottomPadding = v);
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
                            const _SettingsRowLabel('跳转步长'),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: const [5, 10, 15, 30].map((s) {
                                return _SeekStepChip(
                                  seconds: s,
                                  selected: _effectiveSeekStep == s,
                                  onTap: () {
                                    refresh(() {
                                      _userSeekStep = s;
                                      _persistSeekStep();
                                    });
                                  },
                                );
                              }).toList(),
                            ),
                            const SizedBox(height: 16),
                            const Divider(color: Colors.white12, height: 0),
                            const SizedBox(height: 16),
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
      // 顶栏渐变减淡（black87 → 55% 黑）：不再是一块明显的灰色长条，
      // 更通透、与纯黑播放画面融为一体；可读性由按钮自身玻璃底保证
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.55),
            Colors.transparent,
          ],
        ),
      ),
      child: Padding(
        // 顶栏避让状态栏（功能栏高度 contentH=38）：
        // - 竖屏内嵌（默认详情页播放器，pad.top>0）：外层（详情页）已垫
        //   一条与状态栏等高的黑条（已减半），不重复加 pad.top，留 4px 呼吸，
        //   并按下移 **1 个功能栏高度**（+38）要求整体下移；本轮再往上
        //   收 8px（38→30），即"再往上移动一点点"。
        // - 纯竖屏全屏（短剧/抖音，immersive 下 pad.top=0）：贴顶，仅 8px
        //   呼吸（总间距 = topBarTopPadding 8 + 8 = 16，用户既定 8+8=16）
        // - 横屏全屏（pad.top=0）：8，总间距 16（top 8 + 8），比原 24
        //   更贴顶，本轮再往上收 8px。
        padding: EdgeInsets.only(
          top: top +
              (pad.top > 0
                  ? 4 + 30
                  : (_dramaMode || _douyinMode ? 8 : 8)),
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
      // 底栏渐变同样减淡（black87 → 55% 黑），和顶栏对称、贴近周边黑底
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black.withValues(alpha: 0.55),
          ],
        ),
      ),
      child: Padding(
        // 底栏默认贴底（bottom 0，全屏时自然对齐屏幕物理底边）；
        // 媒体库播放器可传 bottomBarBottomPadding 让整栏往上挪一点。
        padding: EdgeInsets.only(
          bottom: widget.bottomBarBottomPadding,
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
    bool circular = false,
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
              borderRadius: BorderRadius.circular(
                circular ? (side - 4) / 2 : (filled ? 12 : 10),
              ),
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

  /// 播放器核心切换按钮 —— 点击循环切换当前平台可用的引擎（AVPlayer / MPV / Webview）。
  /// 切换后保存偏好，下次播放/下一集生效。
  /// （运行时热切换内核代价太高：不同引擎的 player 实例类型完全不同，
  ///  硬切会导致状态/流监听器错乱，得不偿失。）
  Widget _engineSwitchButton() {
    final available = PlayerEngine.availableEngines;
    if (available.length <= 1) return const SizedBox.shrink();
    return Obx(() {
      final current = PlayerPrefs.instance.vodEngine.value;
      final shortLabel = switch (current) {
        PlayerEngine.avplayer => 'AV',
        PlayerEngine.mpv => 'MPV',
        PlayerEngine.webview => 'WEB',
      };
      return _iconButton(
        icon: Icons.memory,
        size: 20,
        width: 42,
        onTap: () => _safeTap(() async {
          final idx = available.indexOf(current);
          final next = available[(idx + 1) % available.length];
          await PlayerPrefs.instance.setEngine(next);
          AppToast.message(
            '已切换到 ${next.title}，下一集或重新播放生效',
            duration: const Duration(seconds: 2),
          );
        }),
        child: Text(
          shortLabel,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            height: 1.0,
          ),
        ),
      );
    });
  }

  /// 短剧模式按钮 —— 样式参考弹幕按钮：圆角方块内一个「短」字，
  /// 开启时右下角带绿色对勾角标。点击进入**纯竖屏全屏**（锁 portraitUp，
  /// 画面按原比例居中带黑边），再点退出。
  Widget _dramaModeButton() {
    return _iconButton(
      icon: Icons.smart_display,
      size: 20,
      width: 38,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Text(
            '短',
            style: TextStyle(
              color: _dramaMode
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.72),
              fontSize: AppTheme.fontHeadline,
              fontWeight: FontWeight.w600,
              height: 1.0,
            ),
          ),
          // 开启角标：绿色对勾（与弹幕一致）
          if (_dramaMode)
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
      onTap: () => _safeTap(() => _toggleDramaMode()),
    );
  }

  /// 抖音模式按钮 —— 与「短」同款：圆角方块内一个「抖」字，
  /// 开启时右下角带对勾角标。点击进入**纯竖屏全屏 + 右侧切换胶囊**
  /// （↟ 上一集 / ⏩ / ↡ 下一集，抖音风格），再点退出。
  Widget _douyinModeButton() {
    return _iconButton(
      icon: Icons.smart_display,
      size: 20,
      width: 38,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Text(
            '抖',
            style: TextStyle(
              color: _douyinMode
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.72),
              fontSize: AppTheme.fontHeadline,
              fontWeight: FontWeight.w600,
              height: 1.0,
            ),
          ),
          // 开启角标：对勾（与「短」一致）
          if (_douyinMode)
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
      onTap: () => _safeTap(() => _toggleDouyinMode()),
    );
  }

  /// 画面中间层：快退/快进跳转按钮（步长可配置）。
  /// 与顶栏/底栏同步显隐（跟随 [_showControls] 与锁定态）。
  /// 2026-10-03：以**视频画面正中心为对称轴**、左右对称拉开距离
  /// （约中心两侧 33% 屏宽处，间距 = 上次 27% × 1.2，不贴边缘也不贴中心）；
  /// 中间区域留白给双击暂停/手势。
  /// 抖音模式（[_douyinMode]）下，右侧变为靠右缘竖排：⏩ + ↑（上一集/上一部）+ ↓（下一集/下一部）；
  /// 短剧模式（[_dramaMode]）无右侧胶囊，保持左右对称（纯滑动切集）。
  Widget _buildCenterSeekButtons() {
    return Positioned.fill(
      child: Stack(
        children: [
          // 正中：缓冲加载圈 / 暂停图标（加载不挡点击；暂停图标可点恢复播放）
          Positioned.fill(
            child: Align(
              alignment: Alignment.center,
              child: _audioMode
                  ? const SizedBox.shrink()
                  // ── 🔴 卡死优先于转圈（复核补的缺口）─────────────────
                  //
                  // 原来这里只有"转圈"这一态：连接挂起时转圈**无限转**，
                  // 用户分不清"在加载"还是"坏了"；而详情页的重试按钮
                  // 只在 `onError` 时出现 → 挂起时**连重试都没有** ✗
                  //
                  // 现在：缓冲中且位置 N 秒没前进 → 换成**可点重试**的提示 ✓
                  : _loadStalled
                      ? GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _safeTap(_retryLoad),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 18, vertical: 14),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.error_outline_rounded,
                                    color: Colors.white, size: 30),
                                const SizedBox(height: 8),
                                const Text('加载超时',
                                    style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(height: 4),
                                Text('点了没反应？点这里重试',
                                    style: TextStyle(
                                        color: Colors.white
                                            .withValues(alpha: 0.85),
                                        fontSize: 12)),
                              ],
                            ),
                          ),
                        )
                      : _isBuffering
                          ? const SizedBox(
                              width: 52,
                              height: 52,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 3,
                              ),
                            )
                          : !_isPlaying
                              ? GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => _safeTap(_togglePlayPause),
                                  child: Container(
                                    width: 60,
                                    height: 60,
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.35),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.pause_rounded,
                                  color: Colors.white,
                                  size: 38,
                                ),
                              ),
                            )
                          : const SizedBox.shrink(),
            ),
          ),
          // 左：快退 —— 以画面中心为对称轴（中心左侧约 33% 屏宽处）
          Positioned.fill(
            child: Align(
              alignment: const Alignment(-0.33, 0),
              child: _seekStepButton(forward: false),
            ),
          ),
          // 右：快进 —— 非抖音模式与左侧对称（中心右侧约 33% 屏宽处）；
          // 抖音模式靠右缘竖排（↟ 上一集 / ⏩ / ↡ 下一集）
          Positioned.fill(
            child: Align(
              alignment: _douyinMode
                  ? const Alignment(1, 0)
                  : const Alignment(0.33, 0),
              child: _douyinMode
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 上一集 / 上一部电影（胶囊：双箭头 + 文字）
                        _dramaSwitchChip(
                          icon: Icons.keyboard_double_arrow_up,
                          label: widget.episodeNames.isNotEmpty
                              ? '上一集'
                              : '上一部',
                          onTap: () =>
                              _safeTap(() => _dramaSwitchTo(forward: false)),
                        ),
                        const SizedBox(height: 10),
                        _seekStepButton(forward: true),
                        const SizedBox(height: 10),
                        // 下一集 / 下一部电影
                        _dramaSwitchChip(
                          icon: Icons.keyboard_double_arrow_down,
                          label: widget.episodeNames.isNotEmpty
                              ? '下一集'
                              : '下一部',
                          onTap: () =>
                              _safeTap(() => _dramaSwitchTo(forward: true)),
                        ),
                      ],
                    )
                  : _seekStepButton(forward: true),
            ),
          ),
        ],
      ),
    );
  }

  /// 抖音模式切换胶囊按钮：半透明白玻璃底 + 圆角 + 双箭头 + 文字标签，
  /// 与画面中间层的 ⏪⏩ 同一风格（比纯图标更易识别是"切集"）。
  Widget _dramaSwitchChip({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.25),
            width: 0.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.92),
                fontSize: AppTheme.fontCaption,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 抖音模式切换集数/影片：
  /// · 有剧集（canPlayNext/canPlayPrevious）→ 走 onPlayNext/onPlayPrevious（播放器内无缝切集）
  /// · 无剧集（电影）→ 走 onDramaNextMovie/onDramaPrevMovie（由详情页提供推荐队列）
  void _dramaSwitchTo({required bool forward}) {
    if (forward) {
      if (widget.canPlayNext && widget.onPlayNext != null) {
        widget.onPlayNext!();
        return;
      }
      widget.onDramaNextMovie?.call();
    } else {
      if (widget.canPlayPrevious && widget.onPlayPrevious != null) {
        widget.onPlayPrevious!();
        return;
      }
      widget.onDramaPrevMovie?.call();
    }
  }

  /// 快进/快退跳转按钮（步长可配置 5/10/15/30 秒）。
  /// 步长=10 时用系统自带 replay_10/forward_10 圆形图标（与参考图一致）；
  /// 其他步长用 replay/forward + 右下角数字角标，所见即所跳。
  /// 2026-10-03：框改圆形；图标尺寸 = 上次(44) × 0.8 = 35；
  /// 与中心间距 = 上次(±0.275) × 1.2 = ±0.33。
  Widget _seekStepButton({required bool forward}) {
    final step = _effectiveSeekStep;
    final base = forward ? Icons.forward : Icons.replay;
    final ten = forward ? Icons.forward_10 : Icons.replay_10;
    return _iconButton(
      icon: step == 10 ? ten : base,
      size: 35,
      // 圆形背景缩到 54（原 76 比图标大太多）：图标 35 + 每边 ~9px 内边距，
      // 比例从 2:1 收到 ~1.5:1，视觉更贴
      width: 54,
      height: 54,
      circular: true,
      child: step == 10
          ? null
          : Stack(
              alignment: Alignment.center,
              children: [
                Icon(base, color: Colors.white, size: 35),
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: Text(
                    '$step',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      height: 1,
                    ),
                  ),
                ),
              ],
            ),
      onTap: () => _safeTap(
        () => _seekRelative(Duration(seconds: forward ? step : -step)),
      ),
    );
  }
}

/// 播放器设置面板里的「跳转步长」选择 chip（与倍速 chips 同款样式）
class _SeekStepChip extends StatelessWidget {
  final int seconds;
  final bool selected;
  final VoidCallback onTap;

  const _SeekStepChip({
    required this.seconds,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.accentColor
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          '$seconds 秒',
          style: TextStyle(
            color: selected ? Colors.white : Colors.white70,
            fontSize: AppTheme.fontFootnote,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
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
