import 'dart:async';
import '../../widgets/common_widgets.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart'
    show VideoController, Video;

import '../../common/theme.dart';
import '../../common/system_ui.dart';
import '../../models/live_models.dart';
import '../../models/player_engine.dart';
import '../../services/app_log.dart';
import '../../services/epg_service.dart';
import '../../services/live_service.dart';
import '../../services/main_tab_controller.dart';
import '../../services/player_fullscreen_controller.dart';
import '../../services/player_prefs.dart';
import '../../widgets/app_player.dart';
import '../../widgets/ios_av_player.dart';
import '../../widgets/ks_player.dart';
import '../../widgets/video_player_pip.dart';
import 'controller.dart';
import '../../services/audio_focus.dart';
import '../../widgets/app_empty_view.dart';
import '../../widgets/app_toast.dart';
import '../../music/services/route_observer.dart' show MusicRouteObserver;

/// 直播主界面（对照参考图）
/// 上：视频区 + LIVE 角标 + 小窗/全屏
/// 下：播放源下拉 + 频道列表（TV 图标 + 状态）
class LivePage extends StatefulWidget {
  const LivePage({super.key});

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  final _controller = Get.put(LiveController());
  Player? _player;
  VideoController? _videoController;

  /// iOS：与点播共用 IosAvPlayer（AvEngine）
  IosAvPlayer? _avPlayer;

  /// iOS：KSPlayer（FF 核心）备用内核
  KSPlayer? _ksPlayer;

  /// iOS 是否启用 mpv 备用内核（播放器右上「核心」按钮可选；默认 AVPlayer，
  /// 遇到 flv/ts/rtmp 等 AVPlayer 不支持的流时可切到 mpv）。
  /// ⚠️ 读独立的 liveEngine 偏好 —— 不再与点播共用 vodEngine，
  /// 直播切内核不影响影视的内核选择。
  bool get _iosUseMpv =>
      Platform.isIOS &&
      PlayerPrefs.instance.liveEngine.value == PlayerEngine.mpv;

  /// iOS 是否启用 KSPlayer（FF）内核（全格式兼容：MKV/ASS 等）
  bool get _iosUseKs =>
      Platform.isIOS &&
      PlayerPrefs.instance.liveEngine.value == PlayerEngine.ksplayer;

  /// 直播可用内核：iOS = AVPlayer / KSPlayer / MPV（直播页没有 webview 播放路径）；
  /// 其它平台仅 mpv（media_kit），无可切换项。
  List<PlayerEngine> get _liveEngines {
    if (Platform.isIOS) {
      return const [PlayerEngine.avplayer, PlayerEngine.ksplayer, PlayerEngine.mpv];
    }
    return const [PlayerEngine.mpv];
  }

  bool _fullscreen = false;

  /// 短剧模式：纯竖屏全屏（复用 _fullscreen 全屏布局，方向锁 portraitUp）
  bool _dramaMode = false;

  /// 抖音模式：纯竖屏全屏（与短剧互斥；全屏布局同短剧）
  bool _douyinMode = false;
  bool _audioMode = false;
  String? _playError;

  /// 正在切台/加载流（显示播放器中间转圈）
  bool _switching = false;

  /// 加载遮罩兜底计时器
  Timer? _switchTimer;

  /// playing=true 后的**延迟确认**计时器：iOS AVPlayer 的 playing 常早于
  /// 画面帧渲染，立即撤遮罩会露出黑屏（用户实测：黑屏无加载提示）。
  /// 延迟 2.5s 后检查 position 是否真的前进，前进才撤「正在加载…」。
  Timer? _playingConfirmTimer;

  /// ── 控制栏自动隐藏（2026-10-02 补，对齐点播端）─────────────────
  /// 点播播放器有 `_showControls + _hideTimer` 自动隐藏，直播页漏做，
  /// 工具栏（LIVE 角标 / 右上功能钮 / 底部 iOS 控制条）永久常显。
  /// 现在：显示后 3 秒无操作自动隐藏，点击视频画面切换显隐。
  bool _controlsVisible = true;
  Timer? _controlsTimer;

  /// 「出画面」监听（position 前进即视为开播）
  StreamSubscription? _switchReadySub;
  StreamSubscription<dynamic>? _errSub;
  StreamSubscription<bool>? _playSub;
  Worker? _tabWorker;

  /// 直播子页面路由监听（push 时暂停 / pop 时恢复）
  VoidCallback? _liveRouteUnlisten;

  /// 是否已成功开过流（切回直播 tab 时用于"恢复播放"而非重新拉流）
  bool _everOpened = false;

  /// 最近一次 open 的地址与时间：短时间内同地址的重复调用（手势连发、
  /// autoplay/位置回调/动画回调重入）直接忽略，避免同一流被重复拆流。
  /// 多源多线路快速切换时，这些重复 open 会让原生侧拆流线程无谓叠加。
  String? _lastOpenUrl;
  DateTime? _lastOpenAt;
  static const _repeatOpenWindow = Duration(milliseconds: 800);

  @override
  void initState() {
    super.initState();
    // IndexedStack 会在 App 启动时构建所有 tab（含直播页）。
    // 只有当前选中「直播」tab 才自动开播，避免一打开软件就在播直播。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MainTabController.instance.selectedTab.value == 4) {
        _autoplayCurrent();
      }
    });
    // 离开直播 tab 时暂停；切回直播 tab 时若未在播则自动开播
    _tabWorker = ever(MainTabController.instance.selectedTab, (tab) {
      if (tab != 4) {
        // ⚠️ 两个内核都要停：iOS 实际在播的是 `_avPlayer`（AVPlayer），
        // 安卓才是 `_player`（media_kit）。旧代码只 pause `_player` →
        // iOS 上切走直播后声音还在后台继续响。
        // 系统小窗（PiP）激活时豁免：用户开着小窗切走，播放归系统悬浮窗管。
        if (VideoPlayerPip.instance.isIosActive) return;
        try {
          _player?.pause();
        } catch (e) {
          /* ignore */
        }
        try {
          _avPlayer?.pause();
        } catch (e) {
          /* ignore */
        }
        // ⚠️ 2026-10-14 补：FF 内核（`_ksPlayer`）原来在这漏了 —— 切走 tab
        //   后它仍会在后台出声。恢复分支本来就区分了 `_iosUseKs`，暂停却漏，
        //   属不对称遗漏。
        try {
          _ksPlayer?.pause();
        } catch (e) {
          /* ignore */
        }
      } else {
        // 切回直播：已在播就不动；已开过流但被暂停 → 直接恢复播放
        //（避免每次切回都重新 open 拉流闪断）；从没开过流才自动开播。
        //
        // ⚠️ 如果直播子页面还开着（push 进去没回来），不要恢复播放 ——
        //    用户还在子页面里，直播不该自己响起来。
        if (MusicRouteObserver.livePushedFrom.value > 0) return;
        final pPlaying = _player?.state.playing ?? false;
        final avPlaying = _avPlayer?.state.playing ?? false;
        if (pPlaying || avPlaying) return;
        if (!_everOpened) {
          _autoplayCurrent();
          return;
        }
        final useAv = Platform.isIOS && !_iosUseMpv && !_iosUseKs && _avPlayer != null;
        if (useAv) {
          // ⚠️ iOS 共享原生 AvEngine（AVPlayer 单例）：点播/音乐最后
          // open 过的话，原生 item 已被它们的内容覆盖，直接 play() 恢复的
          // 是**别人的画面和声音**（"打开直播结果还在播影视"）。
          // 这里一律重新 open 当前直播流，保证切回直播播的一定是直播。
          final want = _controller.currentChannel?.playUrl ?? '';
          if (want.isNotEmpty) {
            _playChannel(want);
            return;
          }
          unawaited(AudioFocus.request('live'));
          try {
            if (_iosUseKs) {
              _ksPlayer?.play();
            } else {
              _avPlayer?.play();
            }
          } catch (e) {
            _autoplayCurrent();
          }
        } else {
          unawaited(AudioFocus.request('live'));
          try {
            _player?.play();
          } catch (e) {
            _autoplayCurrent();
          }
        }
      }
    });
    // 点播/音乐要出声时会通过 AudioFocus 让直播暂停。
    //
    // ⚠️ 原来这里注册的是 `LiveService.pauseLivePlayer` ——
    // 那个回调**只覆盖「点播 ⇄ 直播」**，音乐完全没参与，
    // 于是"听音乐时打开视频"/"看视频时音乐还在响"两边一起出声。
    // 现在统一走 AudioFocus（三方都注册），任一方出声都会让另两方闭嘴。
    AudioFocus.register('live', () async {
      try {
        await _player?.pause();
      } catch (e) {
        /* 暂停失败不影响其它方，AudioFocus 会记日志 */
      }
      // ⚠️ 2026-10-14 补：iOS 上实际在播的是 `_avPlayer`（AVPlayer 内核）或
      //   `_ksPlayer`（FF 内核），`_player`（media_kit）在 iOS 这两条路径下
      //   **根本没开流** —— 原来只 pause 它，等于点播/音乐出声时**直播继续响**
      //   （正是"双声"）。这里把三个内核都停掉（没建实例的 `?.` 自然是空操作）。
      try {
        _avPlayer?.pause();
      } catch (_) {}
      try {
        _ksPlayer?.pause();
      } catch (_) {}
    });
    // 直播子页面 push/pop 监听：
    //   · push 进子页面 → 暂停直播（界面切走了还响着很烦）
    //   · pop 回直播根 → 恢复播放
    // 用 `addListener` + 手动移除，避免 ValueNotifier 泄漏。
    void onLiveRouteChanged() {
      if (!mounted) return;
      final pushed = MusicRouteObserver.livePushedFrom.value;
      if (pushed > 0) {
        // 进了子页面 → 暂停（PiP 激活时豁免）
        if (VideoPlayerPip.instance.isIosActive) return;
        try { _player?.pause(); } catch (_) {}
        try { _avPlayer?.pause(); } catch (_) {}
        // ⚠️ 2026-10-14 补：同切 tab，FF 内核也必须停（原来漏了）。
        try { _ksPlayer?.pause(); } catch (_) {}
      } else {
        // 回到直播根 → 恢复播放
        // 注意：只在"开过流且当前被暂停"时恢复，
        // 别在"本来就没开播"的状态下自动开播。
        if (!_everOpened) return;
        final pPlaying = _player?.state.playing ?? false;
        final avPlaying = _avPlayer?.state.playing ?? false;
        if (pPlaying || avPlaying) return;
        final useAv = Platform.isIOS && !_iosUseMpv && !_iosUseKs && _avPlayer != null;
        if (useAv) {
          // iOS 共享 AVPlayer：子页面里可能被点播/音乐覆盖了 item，
          // 直接 play 会播别人的内容 → 重新 open 直播流
          final want = _controller.currentChannel?.playUrl ?? '';
          if (want.isNotEmpty) {
            _playChannel(want);
            return;
          }
          try { _avPlayer?.play(); } catch (_) { _autoplayCurrent(); }
        } else {
          unawaited(AudioFocus.request('live'));
          try { _player?.play(); } catch (_) { _autoplayCurrent(); }
        }
      }
    }
    MusicRouteObserver.livePushedFrom.addListener(onLiveRouteChanged);
    _liveRouteUnlisten = () =>
        MusicRouteObserver.livePushedFrom.removeListener(onLiveRouteChanged);
  }

  @override
  void dispose() {
    AudioFocus.unregister('live');
    _liveRouteUnlisten?.call();
    _tabWorker?.dispose();
    _errSub?.cancel();
    _switchReadySub?.cancel();
    _playSub?.cancel();
    _switchTimer?.cancel();
    _playingConfirmTimer?.cancel();
    _controlsTimer?.cancel();
    _player?.dispose();
    _player = null;
    _avPlayer?.dispose();
    _avPlayer = null;
    _ksPlayer?.dispose();
    _ksPlayer = null;
    // 全屏（横屏锁）态下页面被直接销毁（iOS 边缘滑动手势 pop、异常路径）时，
    // _leaveFullscreenUi 不会执行 → 横屏锁与底栏隐藏没人解 → 整个 App 滞留
    // 横屏（与影视详情页同源的问题）。dispose 兜底：退出全屏态并强制回竖屏。
    // 用 _fullscreen 守卫：非全屏销毁时不动全局状态，避免误清上层页面的锁。
    if (_fullscreen) {
      _fullscreen = false;
      _dramaMode = false;
      _douyinMode = false;
      PlayerFullscreenController.instance.exit('live');
      try {
        unawaited(SystemUiController.exit('live'));
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
        ]);
      } catch (_) {}
    }
    _videoController = null;
    super.dispose();
  }

  /// 播放当前选中频道；无地址则跳过
  void _autoplayCurrent() {
    // 直播要出声了 → 让音乐/点播先闭嘴（用户能直接听到的"双声"问题）
    unawaited(AudioFocus.request('live'));
    final url = _controller.currentChannel?.playUrl ?? '';
    if (url.isEmpty) return;
    _playChannel(url);
  }

  void _playChannel(String url) {
    if (url.isEmpty) return;
    // 同地址在窗口内的重复 open 直接吞掉（切台手势连发、autoplay/回调重入）。
    // 不同地址的主动切台/换线路一律放行；800ms 后的手动重试也不受影响。
    final now = DateTime.now();
    if (_lastOpenUrl == url &&
        _lastOpenAt != null &&
        now.difference(_lastOpenAt!) < _repeatOpenWindow) {
      return;
    }
    _lastOpenUrl = url;
    _lastOpenAt = now;
    _everOpened = true;
    _playError = null;
    AppLog.instance.log('[live] 开播/切台: '
        '核心=${_iosUseKs ? 'KS(FF)' : (_iosUseMpv ? 'MPV' : (Platform.isIOS ? 'AVPlayer' : 'MPV'))} '
        'url=$url');
    // 直播要出声了 → 让点播/音乐先闭嘴（AudioFocus 三方互斥：
    // 任何开播/切台/恢复路径都必须声明焦点，缺一路就会"双声"）
    unawaited(AudioFocus.request('live'));
    // 切台时强制显示控制栏并重置自动隐藏计时
    _showControls();
    // 切台时先亮起「加载中」遮罩：新流从 open 到出画面有几百毫秒到几秒，
    // 期间老画面还在，没有反馈会让人以为点了没反应。
    _switching = true;
    _switchTimer?.cancel();
    // 兜底：最多显示 20 秒（真正就绪时由 position/buffering 监听提前清掉）
    _switchTimer = Timer(const Duration(seconds: 20), () {
      if (mounted && _switching) setState(() => _switching = false);
    });
    // 复用同一 Player，切台只 open 新地址，避免黑屏/闪断
    _player ??= Player(
      configuration: const PlayerConfiguration(title: '猫影直播'),
    );
    _videoController ??= VideoController(_player!);
    // HLS/FLV/TS/MP4/RTMP/RTSP：带全量请求头，提升 mp4 直链与 CDN 可播性
    String origin = '';
    String referer = '';
    try {
      final u = Uri.parse(url);
      if (u.hasScheme && u.host.isNotEmpty) {
        final base = '${u.scheme}://${u.host}${u.hasPort ? ':${u.port}' : ''}';
        origin = base;
        referer = '$base/';
      }
    } catch (e) {
      /* ignore */
    }
    final headers = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Connection': 'keep-alive',
      if (referer.isNotEmpty) 'Referer': referer,
      if (origin.isNotEmpty) 'Origin': origin,
    };
    if (_iosUseKs) {
      // KSPlayer（FF 核心，全格式）：与点播共用同一个 KSEngine 单例
      _player?.pause();
      _avPlayer?.pause();
      _ksPlayer ??= KSPlayer(config: const AppConfig(title: '猫影直播'));
      // live: true → 原生侧按格式路由内核（m3u8/mp4 走 AVPlayer，
      // flv/mkv/ts/rtmp 走打了野指针防御补丁的 FFmpeg）
      _ksPlayer!.open(AppMedia(url, httpHeaders: headers), live: true);
    } else if (Platform.isIOS && !_iosUseMpv) {
      // 默认 AVPlayer 内核（与点播一致，进出小窗/手势一致）
      _player?.pause(); // 若之前用 mpv 在播，先停掉避免双声
      // 切走 FF 核心不能只 pause：KS 层背后的 MEPlayer 拆流线程可能还在跑
      //（DVB 野流拆到一半），层不释放它会一直跑到崩。dispose 掉原生层，
      // 下次切回 FF 时 ??= 重建即可。
      _ksPlayer?.dispose();
      _ksPlayer = null;
      _avPlayer ??= IosAvPlayer(config: const AppConfig(title: '猫影直播'));
      _avPlayer!.open(AppMedia(url, httpHeaders: headers));
    } else {
      // 桌面/Android，或 iOS 切到 mpv 备用内核（通吃 flv/ts/rtmp）
      _avPlayer?.pause(); // iOS 切回 mpv 时停掉 AVPlayer 避免双声
      _ksPlayer?.dispose(); // 同上：连层一起释放，别留拆流线程在后台裸奔
      _ksPlayer = null;
      _player!.open(Media(url, httpHeaders: headers));
    }
    // 预热原生 PiP，否则点小窗时 AVPlayer 冷启动易失败/黑屏
    // （KSPlayer 小窗与前台共用同一实例，无需预热）
    if (Platform.isIOS && !_iosUseKs) {
      VideoPlayerPip.instance.prepareIos(url: url, headers: headers);
    }
    // 订阅播放错误，避免一直转圈无提示。
    // ⚠️ 必须监听**实际在播的那个播放器**：iOS 默认用 AVPlayer（_avPlayer），
    // 切到 mpv 或其它平台用 media_kit（_player）。旧写法一律挂 _player 的流 ——
    // iOS AVPlayer 路径下 _player 根本没开流，position/error 永远不触发，
    // 「正在加载…」只能等 20 秒兜底才消失（视频早就在播了）。
    _errSub?.cancel();
    _switchReadySub?.cancel();
    _playSub?.cancel();
    // ⚠️ 2026-10-14：这里**不能**再 cancel `_switchTimer` —— 它正是上面
    //   （`_switching = true` 之后）刚新建的 20 秒兜底计时器。原来这行把
    //   "上一轮的旧 timer"和"刚建的兜底"一起取消了 ⇒ 兜底永不触发 ⇒ 遇到
    //   "连上了但不发数据、也不报错"的挂起流时，中央「正在加载…」会**永久
    //   转圈**（且没有 error 事件，重试按钮也不出现，只能强杀页面）。
    //   旧 timer 已在上面单独 cancel 过，这里无需重复。
    _playingConfirmTimer?.cancel();
    final useAv = Platform.isIOS && !_iosUseMpv && !_iosUseKs && _avPlayer != null;
    // ⚠️ 不能用 `useAv ? _avPlayer!.stream : _player!.stream` 三元：
    // AppPlayerStreams（video_player）与 PlayerStream（media_kit）没有公共基类，
    // 三元会把它俩推断成 Object，.error/.position/.playing 全部 undefined（编译失败）。
    // 按实际在播内核分派，两个内核的 error=Stream<String> / position=Stream<Duration> /
    // playing=Stream<bool> 类型一致，共用同一套监听逻辑。
    final useKs = _iosUseKs && _ksPlayer != null;
    if (useKs) {
      final s = _ksPlayer!.stream;
      _bindPlaybackStreams(s.error, s.position, s.playing);
    } else if (useAv) {
      final s = _avPlayer!.stream;
      _bindPlaybackStreams(s.error, s.position, s.playing);
    } else {
      final s = _player!.stream;
      _bindPlaybackStreams(s.error, s.position, s.playing);
    }
    setState(() {});
  }

  /// 订阅播放器流：错误提示 + 「正在加载」遮罩撤销（position 前进 / playing=true）
  void _bindPlaybackStreams(
    Stream<String> errors,
    Stream<Duration> positions,
    Stream<bool> playings,
  ) {
    _errSub = errors.listen((msg) {
      if (!mounted) return;
      AppLog.instance.log('[live] 播放失败: '
          '核心=${_iosUseKs ? 'KS(FF)' : (_iosUseMpv ? 'MPV' : (Platform.isIOS ? 'AVPlayer' : 'MPV'))} '
          'url=$_lastOpenUrl 错误=$msg');
      setState(() {
        _playError = msg.isEmpty ? '播放失败，点此重试' : msg;
        _switching = false;
      });
    });
    // 出画面了就撤掉「加载中」遮罩（position 前进即视为已开播）
    _switchReadySub = positions.listen((pos) {
      if (!mounted) return;
      if (_switching && pos > Duration.zero) {
        _switchTimer?.cancel();
        setState(() => _switching = false);
      }
    });
    // 兜底：进入 playing 状态**延迟确认**再撤「加载中」遮罩。
    // ⚠️ 不能 playing=true 立即撤 —— iOS AVPlayer 的 playing 会早于画面帧
    // 渲染（HLS 解析 + 平台视图 attach），立即撤就是"黑屏但无加载提示"
    //（用户实测截图：画面全黑、无转圈、无报错）。
    // 延迟 2.5s 后再查一次 position：真的前进才撤；没前进继续等
    // position 流（或 20s 兜底），避免把黑屏当开播。
    _playSub = playings.listen((pl) {
      if (!mounted) return;
      if (_switching && pl) {
        _playingConfirmTimer?.cancel();
        _playingConfirmTimer = Timer(const Duration(milliseconds: 2500), () {
          _playingConfirmTimer = null;
          if (!mounted || !_switching) return;
          final useAvNow = Platform.isIOS && !_iosUseMpv && !_iosUseKs && _avPlayer != null;
          final pos = useAvNow
              ? (_avPlayer?.state.position ?? Duration.zero)
              : (_ksPlayer?.state.position ??
                  (_player?.state.position ?? Duration.zero));
          if (pos > Duration.zero) {
            _switchTimer?.cancel();
            setState(() => _switching = false);
          }
          // 未前进：保持「正在加载…」，由 positions 流或 20s 兜底接管
        });
      }
    });
  }

  /// 播放器核心选择菜单 —— 底部弹层列出直播可用的内核（iOS：AVPlayer / MPV），
  /// 当前使用中的内核打勾；点击某一项即切换。
  /// 直播没有 webview 播放路径，故列表不含 webview。
  /// 切换后**立即用新内核重新拉流**（直播是持续流，无需像点播那样等下一集）。
  Future<void> _showLiveEnginePicker() async {
    final engines = _liveEngines;
    if (engines.length <= 1) return;
    _showControls();
    final current = PlayerPrefs.instance.liveEngine.value;
    final picked = await showModalBottomSheet<PlayerEngine>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Row(
                children: [
                  Text(
                    '播放器核心',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            for (final engine in engines)
              ListTile(
                dense: true,
                leading: Icon(
                  Icons.memory,
                  color: AppTheme.textSecondary,
                  size: 20,
                ),
                title: Text(
                  engine.title,
                  style: TextStyle(
                    color: engine == current
                        ? AppTheme.accentColor
                        : AppTheme.textPrimary,
                    fontSize: AppTheme.fontSubhead,
                    fontWeight:
                        engine == current ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                subtitle: Text(
                  switch (engine) {
                    PlayerEngine.avplayer => '系统内核，HLS/MP4 兼容性好',
                    PlayerEngine.ksplayer => 'FFmpeg 内核，MKV 等全格式兼容',
                    _ => '支持 flv/ts/rtmp 等更多直播流',
                  },
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption,
                  ),
                ),
                trailing: engine == current
                    ? Icon(Icons.check, color: AppTheme.accentColor, size: 20)
                    : null,
                onTap: () => Navigator.pop(ctx, engine),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || picked == current) return;
    AppLog.instance.log('[live] 切换播放器核心: ${current.title} → ${picked.title}');
    await PlayerPrefs.instance.setLiveEngine(picked);
    if (!mounted) return;
    setState(() {}); // 刷新右上按钮的内核短标签
    // 立即用新内核重新拉流（无正在播放的频道时仅保存偏好）
    final url = _controller.currentChannel?.playUrl ?? '';
    if (url.isNotEmpty) {
      _playChannel(url);
    }
    AppToast.message('已切换到 ${picked.title}');
  }

  /// 控制栏显隐包装：隐藏时不可点击 + 200ms 淡出
  Widget _controlsWrap(Widget child) {
    return IgnorePointer(
      ignoring: !_controlsVisible,
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: child,
      ),
    );
  }

  /// 显示控制栏并重置 3 秒自动隐藏计时（切台/交互后调用）
  void _showControls() {
    _controlsTimer?.cancel();
    if (!_controlsVisible && mounted) {
      setState(() => _controlsVisible = true);
    }
    _controlsTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _controlsVisible) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  /// 点击视频画面：切换控制栏显隐（显示时重置计时）
  void _toggleControls() {
    if (_controlsVisible) {
      _controlsTimer?.cancel();
      setState(() => _controlsVisible = false);
    } else {
      _showControls();
    }
  }

  Future<void> _togglePip() async {
    final ch = _controller.currentChannel;
    final url = ch?.playUrl ?? '';
    if (url.isEmpty) {
      AppToast.message('请先选择频道');
      return;
    }
    try {
      final supported = await VideoPlayerPip.instance.isIosPipSupported();
      if (!supported) {
        AppToast.message('当前设备不支持系统小窗（需真机 iOS）');
        return;
      }
      final pos = _player?.state.position ?? Duration.zero;
      // 先预热原生 AVPlayer，再启动 PiP，降低“点了没小窗”的概率
      final pipHeaders = <String, String>{
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
      };
      await VideoPlayerPip.instance.prepareIos(url: url, headers: pipHeaders);
      // 单实例 AVPlayer：进/出小窗都不要 pause，否则小窗冻结/回 App 停播
      final ok = await VideoPlayerPip.instance.enterIos(
        url: url,
        headers: pipHeaders,
        position: pos,
        onStarted: () {
          // 系统接管同一 layer，无需暂停
        },
        onStopped: () {
          // 同一播放器继续播，只收 UI
          if (mounted) setState(() {});
        },
      );
      if (!ok) {
        AppToast.message('小窗启动失败');
      }
    } catch (e) {
      AppToast.message('小窗失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 全屏时纯黑；普通模式**透明**，与首页/史藏/设置/阅读一致 ——
      // 让 `app.dart` 里那层全局壁纸透出来。
      // 原来这里写的是不透明的 `AppTheme.backgroundPrimary`，于是
      // "同一排 tab，直播是米白、其它是壁纸色"，看起来像两个 App
      //（用户截图对比过）。
      backgroundColor: _fullscreen ? Colors.black : Colors.transparent,
      body: GetBuilder<LiveController>(
        builder: (c) {
          final groups = c.groups;
          final channels = c.channels;
          final current = c.currentChannel;
          final currentSourceName = c.currentSourceName;
          final currentGroupName = c.currentGroupName;
          // 视频层常驻 Stack 首位：全屏/普通切换只改高度，Video 永不重建
          // （修复直播全屏/横屏后"有声音没画面"——同一 VideoController
          //   被反复 attach/detach 时 media_kit 渲染层会黑屏）
          return LayoutBuilder(
            builder: (ctx, cons) {
              final pad = MediaQuery.of(ctx).padding;
              final topBar = _fullscreen ? 0.0 : (pad.top > 0 ? pad.top : 0.0);
              final videoHeight = _fullscreen
                  ? cons.maxHeight - topBar
                  : cons.maxWidth * 9 / 16;
              return Column(
                children: [
                  // 状态栏高度黑边：状态栏压在黑边上，不与画面重叠
                  if (topBar > 0)
                    // ⚠️ 这一条正好覆盖状态栏区域，所以在这里发"浅色图标"：
                    // 本页没有 AppBar，不标注的话会沿用上一条路由的样式，
                    // 浅色模式下就是"深色图标压黑边"，看不见。
                    AnnotatedRegion<SystemUiOverlayStyle>(
                      value: SystemUiOverlayStyle.light,
                      child: SizedBox(
                        height: topBar,
                        child: const ColoredBox(color: Colors.black),
                      ),
                    ),
                  // 视频层（全屏时吃掉剩余高度）
                  SizedBox(
                    height: videoHeight,
                    width: double.infinity,
                    child: _buildVideoLayer(c, current),
                  ),
                  // 非全屏：内容层（选择器 + 频道列表）
                  if (!_fullscreen)
                    Expanded(
                      child: Column(
                        children: [
                          Obx(() {
                            final err = LiveService.instance.error.value;
                            if (err == null) return const SizedBox.shrink();
                            final loading =
                                LiveService.instance.isLoading.value;
                            // 按你的要求：**不显示红色错误文案与「重试」文字**。
                            // 源加载失败时只在播放器/列表上方放一个圆形的
                            // 重试图标按钮（无文字），点它重新加载。
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                              child: Row(
                                children: [
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: loading
                                        ? null
                                        : () =>
                                              LiveService.instance.retryLast(),
                                    child: Container(
                                      width: 32,
                                      height: 32,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: AppTheme.accentColor.withValues(
                                          alpha: 0.14,
                                        ),
                                        border: Border.all(
                                          color: AppTheme.accentColor
                                              .withValues(alpha: 0.45),
                                          width: 0.8,
                                        ),
                                      ),
                                      child: loading
                                          ? SizedBox(
                                              width: 14,
                                              height: 14,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 1.8,
                                                color: AppTheme.accentColor,
                                              ),
                                            )
                                          : Icon(
                                              Icons.refresh_rounded,
                                              size: 18,
                                              color: AppTheme.accentColor,
                                            ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    loading ? '正在加载源…' : '加载失败',
                                    style: TextStyle(
                                      color: AppTheme.textTertiary,
                                      fontSize: AppTheme.fontFootnote,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
                          // 加载中细进度条（缓存已出列表时也能看到在刷新）
                          Obx(() {
                            if (!LiveService.instance.isLoading.value) {
                              return SizedBox(height: 2);
                            }
                            return Padding(
                              padding: EdgeInsets.fromLTRB(12, 4, 12, 0),
                              child: LinearProgressIndicator(
                                minHeight: 2,
                                color: AppTheme.accentColor,
                                // 原来写死 Colors.white12：浅色模式下进度槽
                                // 在白底上完全不可见。跟随主题三级色。
                                backgroundColor:
                                    AppTheme.textTertiary.withValues(alpha: 0.25),
                              ),
                            );
                          }),
                          const SizedBox(height: 8),
                          // 双层选择器：直播源 + 分组
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Row(
                              children: [
                                // 刷新按钮
                                GestureDetector(
                                  onTap: _onRefreshSource,
                                  child: Container(
                                    width: 38,
                                    height: 38,
                                    decoration: BoxDecoration(
                                      color: AppTheme.backgroundTertiary,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.refresh,
                                      color: AppTheme.textSecondary,
                                      size: 18,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // 直播源选择（左下拉）
                                Expanded(
                                  child: GestureDetector(
                                    onTap: () => _showSourcePicker(context, c),
                                    child: Container(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 9,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppTheme.backgroundTertiary,
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(
                                          color: AppTheme.accentColor
                                              .withValues(alpha: 0.3),
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.rss_feed,
                                            color: AppTheme.accentColor,
                                            size: 16,
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              currentSourceName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: AppTheme.accentColor,
                                                fontSize: AppTheme.fontSubhead,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                          Icon(
                                            Icons.arrow_drop_down,
                                            color: AppTheme.textSecondary,
                                            size: 18,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // 分组选择（右下拉）
                                Expanded(
                                  child: GestureDetector(
                                    onTap: groups.isEmpty
                                        ? null
                                        : () => _showGroupPicker(
                                            context,
                                            c,
                                            groups,
                                          ),
                                    child: Container(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 9,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppTheme.backgroundTertiary,
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.playlist_play,
                                            color: AppTheme.textSecondary,
                                            size: 16,
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              currentGroupName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: AppTheme.textPrimary,
                                                fontSize: AppTheme.fontSubhead,
                                              ),
                                            ),
                                          ),
                                          Icon(
                                            Icons.arrow_drop_down,
                                            color: AppTheme.textSecondary,
                                            size: 18,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          // 跨组搜索 + 只看收藏
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  onChanged: (v) {
                                    c.searchKeyword.value = v;
                                    c.update();
                                  },
                                  style: TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: AppTheme.fontSubhead,
                                  ),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    hintText: '搜索频道（跨分组）',
                                    hintStyle: TextStyle(
                                      color: AppTheme.textTertiary,
                                      fontSize: AppTheme.fontFootnote,
                                    ),
                                    prefixIcon: Icon(
                                      Icons.search,
                                      size: 18,
                                      color: AppTheme.textTertiary,
                                    ),
                                    // 透明底：去掉灰填充
                                    filled: false,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 8,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide.none,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: () => _showEpgSheet(context, c),
                                child: Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppTheme.backgroundTertiary,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    Icons.schedule,
                                    size: 18,
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Obx(() {
                                final onlyFav = c.showOnlyFavorites.value;
                                return GestureDetector(
                                  onTap: () {
                                    c.showOnlyFavorites.value = !onlyFav;
                                    c.update();
                                  },
                                  child: Container(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: onlyFav
                                          ? AppTheme.accentColor.withValues(
                                              alpha: 0.2,
                                            )
                                          : AppTheme.backgroundTertiary,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Icon(
                                      onlyFav ? Icons.star : Icons.star_border,
                                      size: 18,
                                      color: onlyFav
                                          ? AppTheme.accentColor
                                          : AppTheme.textSecondary,
                                    ),
                                  ),
                                );
                              }),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // 频道列表（占满宽度）
                          Expanded(
                            child: Obx(() {
                              // 切换直播源 / 分组时给明确反馈，
                              // 否则列表为空的那段时间就是一片黑，不知道在加载还是坏了。
                              final loading =
                                  LiveService.instance.isLoading.value;
                              if (loading && channels.isEmpty) {
                                return Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        width: 26,
                                        height: 26,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.4,
                                          color: AppTheme.accentColor,
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        '正在加载频道…',
                                        style: TextStyle(
                                          color: AppTheme.textSecondary,
                                          fontSize: AppTheme.fontSubhead,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '切换直播源需要几秒',
                                        style: TextStyle(
                                          color: AppTheme.textTertiary,
                                          fontSize: AppTheme.fontCaption,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }
                              if (groups.isEmpty) {
                                return _EmptyLive(
                                  onReload: () => _pickSource(context, c),
                                );
                              }
                              return Stack(
                                children: [
                                  _buildChannelList(c, channels),
                                  // 已有旧列表时：叠加一层半透明遮罩 + 转圈，
                                  // 让"正在换源"这件事可见，又不丢掉旧内容。
                                  if (loading)
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        child: Container(
                                          color: AppTheme.backgroundPrimary
                                              .withValues(alpha: 0.45),
                                          child: Center(
                                            child: SizedBox(
                                              width: 24,
                                              height: 24,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2.2,
                                                color: AppTheme.accentColor,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              );
                            }),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _pickSource(BuildContext context, LiveController c) async {
    // 导入直播源（m3u/txt URL）——左栏底部 + 号进入。
    // 与设置页一致：可填「源名称 + 地址」；始终追加新源（名称生效），
    // 不再出现「单源覆盖当前、名称被丢弃」的行为
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (ctx) {
        final nameCtrl = TextEditingController();
        final ctrl = TextEditingController();
        return AlertDialog(
          backgroundColor: AppTheme.backgroundSecondary,
          title: Text(
            '导入直播源',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontHeadline,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                style: TextStyle(color: AppTheme.textPrimary),
                decoration: InputDecoration(
                  hintText: '源名称（可留空，默认按序号命名）',
                  hintStyle: TextStyle(color: AppTheme.textTertiary),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: ctrl,
                style: TextStyle(color: AppTheme.textPrimary),
                decoration: InputDecoration(
                  hintText: 'm3u / txt 地址（麦优订阅 json.txt 链接自动识别）',
                  hintStyle: TextStyle(color: AppTheme.textTertiary),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(
                ctx,
                (nameCtrl.text.trim(), ctrl.text.trim()),
              ),
              child: const Text('加载'),
            ),
          ],
        );
      },
    );
    if (result == null || result.$2.isEmpty) return;
    final url = result.$2.trim();
    final name = result.$1.trim();
    // 始终走 addSource：追加新源（名称生效），而不是覆盖当前
    await c.addSource(url, name: name.isEmpty ? null : name);
    if (mounted) {
      c.selectGroup(0);
      _autoplayCurrent();
    }
  }

  /// 投屏入口（DLNA/UPnP）—— 与点播播放器同通道
  void _toggleCast() {
    final ch = _controller.currentChannel;
    final url = ch?.playUrl ?? '';
    if (url.isEmpty) {
      AppToast.message('请先选择频道');
      return;
    }
    Get.toNamed(
      '/dlna',
      parameters: {
        'url': url,
        'title': ch!.name,
      },
    );
  }

  void _toggleAudioMode() {
    // 若尚未开播，先起播再进听剧，否则只有壳没有声音
    if (!_audioMode && (_player == null || !_player!.state.playing)) {
      _autoplayCurrent();
    }
    setState(() => _audioMode = !_audioMode);
    // 进入听剧时保持播放（后台可续播由 UIBackgroundModes=audio 保证）
  }

  /// iOS 直播专用：本地静音状态（`AppPlayerStreams` 没有 volume 流，
  /// 所以静音按钮只能记在本地，初始音量从 `state.volume` 读）。
  bool _iosMuted = false;

  /// 直播底部工具栏（AV / FF / MPV 三个核心共用同一形态）。
  ///
  /// ── 为什么必须自己写 ──────────────────────────────────────────
  /// 移动端直播画面走原生平台视图（AVPlayer / KSEngine / media_kit），而
  /// media_kit 的 `AdaptiveVideoControls` 在手机上只调**系统音量**
  /// （volume_controller），底部根本没有音量按钮 —— 所以统一用这条自绘控制栏：
  /// 播放/暂停 + （有时长才显示）真实进度条 + 音量/静音。
  ///
  /// ── 直播的"进度条"该怎么显示 ──────────────────────────────────
  /// 直播流没有可 seek 的时长，画一根假进度条是欺骗：
  ///   · `duration > 0`（回看 / DVR 窗口）→ 显示真实进度条且可拖动
  ///   · 否则 → 不显示进度条
  /// 播放/暂停与静音对任何直播流都有意义，始终显示。
  ///
  /// ⚠️ 旧实现固定取 `_avPlayer!`：切到 FF / MPV 核心后这条栏仍在操作 AVPlayer
  /// 实例 → 静音/播放/拖动全部无效（`_avPlayer` 为 null 时还会空指针）。
  Widget _activeLiveControls() {
    final ks = _ksPlayer;
    if (_iosUseKs && ks != null) {
      return _buildLiveControls(
        playingStream: ks.stream.playing,
        playingInitial: ks.state.playing,
        durationStream: ks.stream.duration,
        durationInitial: ks.state.duration,
        positionStream: ks.stream.position,
        positionInitial: ks.state.position,
        onTogglePlay: () => ks.state.playing ? ks.pause() : ks.play(),
        onSeek: ks.seek,
        muted: _iosMuted,
        onToggleMute: _setLiveMuted,
      );
    }
    final av = _avPlayer;
    if (Platform.isIOS && !_iosUseMpv && !_iosUseKs && av != null) {
      return _buildLiveControls(
        playingStream: av.stream.playing,
        playingInitial: av.state.playing,
        durationStream: av.stream.duration,
        durationInitial: av.state.duration,
        positionStream: av.stream.position,
        positionInitial: av.state.position,
        onTogglePlay: () => av.state.playing ? av.pause() : av.play(),
        onSeek: av.seek,
        muted: _iosMuted,
        onToggleMute: _setLiveMuted,
      );
    }
    final mpv = _player;
    if (mpv != null) {
      return _buildLiveControls(
        playingStream: mpv.stream.playing,
        playingInitial: mpv.state.playing,
        durationStream: mpv.stream.duration,
        durationInitial: mpv.state.duration,
        positionStream: mpv.stream.position,
        positionInitial: mpv.state.position,
        onTogglePlay: () => mpv.state.playing ? mpv.pause() : mpv.play(),
        onSeek: mpv.seek,
        muted: _iosMuted,
        onToggleMute: _setLiveMuted,
      );
    }
    return const SizedBox.shrink();
  }

  /// 直播静音开关：作用于**当前在播核心**（AV / FF / MPV），并记住本地状态。
  void _setLiveMuted(bool muted) {
    setState(() => _iosMuted = muted);
    final v = muted ? 0.0 : 100.0;
    final ks = _ksPlayer;
    final av = _avPlayer;
    final mpv = _player;
    if (_iosUseKs && ks != null) {
      unawaited(ks.setVolume(v));
    } else if (_iosUseMpv && mpv != null) {
      unawaited(mpv.setVolume(v));
    } else if (av != null) {
      unawaited(av.setVolume(v));
    }
  }

  Widget _buildLiveControls({
    required Stream<bool> playingStream,
    required bool playingInitial,
    required Stream<Duration> durationStream,
    required Duration durationInitial,
    required Stream<Duration> positionStream,
    required Duration positionInitial,
    required VoidCallback onTogglePlay,
    required ValueChanged<Duration> onSeek,
    required bool muted,
    required ValueChanged<bool> onToggleMute,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 12, 6, 2),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black.withValues(alpha: 0.62),
          ],
        ),
      ),
      child: Row(
        children: [
          StreamBuilder<bool>(
            stream: playingStream,
            initialData: playingInitial,
            builder: (context, snap) {
              final playing = snap.data ?? false;
              return IconButton(
                iconSize: 22,
                color: Colors.white,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
                tooltip: playing ? '暂停' : '播放',
                icon: Icon(playing ? Icons.pause : Icons.play_arrow_rounded),
                onPressed: onTogglePlay,
              );
            },
          ),
          Expanded(
            child: StreamBuilder<Duration>(
              stream: durationStream,
              initialData: durationInitial,
              builder: (context, dSnap) {
                final dur = dSnap.data ?? Duration.zero;
                // 纯 HLS 直播流 duration ≤0（LIVE 无时长）→ 不给进度条
                // （直播不可 seek，画假条是误导）；去掉「● 直播」红点标识。
                if (dur <= Duration.zero) {
                  return const SizedBox.shrink();
                }
                // 其余（mp4 直链 / 点播类 m3u8 / DVR 回看等**有时长的流**）
                // → 保留真实进度条，可拖动 seek（用户拍板：进度条功能保留）
                return StreamBuilder<Duration>(
                  stream: positionStream,
                  initialData: positionInitial,
                  builder: (context, pSnap) {
                    final pos = pSnap.data ?? Duration.zero;
                    final v = (pos.inMilliseconds / dur.inMilliseconds)
                        .clamp(0.0, 1.0);
                    return Row(
                      children: [
                        Text(
                          _fmtClock(pos),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                        Expanded(
                          child: SliderTheme(
                            data: SliderThemeData(
                              trackHeight: 2.5,
                              thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 6,
                              ),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 12,
                              ),
                              activeTrackColor: Colors.white,
                              inactiveTrackColor:
                                  Colors.white.withValues(alpha: 0.3),
                              thumbColor: Colors.white,
                            ),
                            child: Slider(
                              value: v,
                              onChanged: (x) => onSeek(
                                Duration(
                                  milliseconds:
                                      (dur.inMilliseconds * x).round(),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Text(
                          _fmtClock(dur),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
          IconButton(
            iconSize: 20,
            color: Colors.white,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
            tooltip: muted ? '取消静音' : '静音',
            icon: Icon(
              muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
            ),
            onPressed: () => onToggleMute(!muted),
          ),
        ],
      ),
    );
  }

  /// mm:ss（超过 1 小时则 h:mm:ss）
  static String _fmtClock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  /// 全屏：只显示视频画面（横屏铺满），左上返回、右上频道名+退出全屏
  /// 视频层（常驻 Stack 首位）：全屏/普通切换只改外层高度，Video 永不重建
  /// 修复直播全屏后"有声音没画面"（同一 VideoController 反复 attach 黑屏）
  Widget _buildVideoLayer(LiveController c, LiveChannel? current) {
    final pad = MediaQuery.of(context).padding;
    // 画面已在状态栏黑边之下，控件只需少量上边距，不必再吃 safe-area
    final topInset = _fullscreen ? (pad.top > 0 ? pad.top : 12.0) : 8.0;

    // 🔴 iOS 上画面是**原生平台视图**（`AppVideoView` → AVPlayer / WKWebView）。
    // 平台视图由引擎单独合成到原生视图层级里，被 push 上去的 opaque 路由
    // （设置子页 / 数据源 / 播放器 / 缓存…）**不会**自动把它摘掉。
    // 用户实测：「打开直播再进设置，设置页里能看到直播界面」。
    // 所以只要本页所在路由不再是栈顶，就用 Offstage 把画面从图层树里摘掉
    //（引擎不再提交该平台视图的图层 → 原生视图被移除）。
    // 只隐藏画面，**不 dispose 播放器**，音频与播放进度都保留。
    final routeIsCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    final isIosAv = Platform.isIOS && !_iosUseMpv && !_iosUseKs && _avPlayer != null;
    final isIosKs = _iosUseKs && _ksPlayer != null;
    // media_kit 播放路径（iOS 切到 MPV / Android / 桌面）：底部控制栏改用自绘，
    // 让它也有音量/静音按钮（见 _activeLiveControls）。
    final isMpvPath = !isIosAv &&
        !isIosKs &&
        _player != null &&
        current != null;

    return Container(
      color: Colors.black,
      // 点击视频画面 = 切换控制栏显隐（对齐点播端交互）。
      // 按钮/滑块等子级手势会在竞技场中赢过这里，点击工具栏本身不误触。
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        child: Stack(
          fit: StackFit.expand,
          children: [
          // 视频层常驻（听剧时透明隐藏，不从树上摘掉，保证音轨不断、退出听剧能恢复画面）
          if (isIosAv || isIosKs || (_videoController != null && current != null))
            Offstage(
              offstage: !routeIsCurrent,
              child: Opacity(
                opacity: _audioMode ? 0.0 : 1.0,
                child: isIosAv
                    ? AppVideoView(player: _avPlayer!)
                    : isIosKs
                        ? AppVideoView(player: _ksPlayer!)
                        : Video(
                            controller: _videoController!,
                            // 底部控制栏改用 App 自绘（含音量/静音）：media_kit 的
                            // 内置控制在手机上只有系统音量手势、没有音量按钮。
                            controls: null,
                          ),
              ),
            )
          else
            Center(
              child: Icon(
                Icons.live_tv,
                // ── ⚠️ 必须是**白色**，不能跟主题走 ────────────────
                // 这个图标画在 `_buildVideoLayer` 的容器里，而那个容器是
                // **`color: Colors.black`（视频区永远是黑的）**。
                //
                // 原来用 `AppTheme.textTertiary`（= #8E8E93），
                // **浅色模式下对比度不足、看起来发灰不明显**
                // （用户实测："直播的播放按钮在浅色模式下应该是白色的"）。
                // 视频区的图标不该随全局明暗变 —— 背景永远是黑的。
                color: Colors.white.withValues(alpha: 0.72),
                size: 56,
              ),
            ),
          // 切台加载中：播放器正中间转圈（无文字干扰）
          if (_switching && !_audioMode && _playError == null)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.35),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 34,
                        height: 34,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.6,
                          color: Colors.white.withValues(alpha: 0.92),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '正在加载…',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: AppTheme.fontFootnote,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // 播放失败：**不显示红字/错误文案**，只在播放器正中间放一个
          // 重试图标按钮。点它重新拉流，成功就自动开始播。
          if (_playError != null && !_audioMode)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  final url = current?.playUrl ?? '';
                  if (url.isNotEmpty) {
                    setState(() => _playError = null);
                    _playChannel(url);
                  }
                },
                child: Container(
                  color: Colors.black.withValues(alpha: 0.45),
                  alignment: Alignment.center,
                  child: Container(
                    width: 64,
                    height: 64,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.14),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.5),
                        width: 1.4,
                      ),
                    ),
                    child: const Icon(
                      Icons.refresh_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ),
              ),
            ),
          // 直播：补上原生平台视图**缺失的底部工具栏**
          // （播放暂停 + 进度条 + 音量/静音），三个核心（AV/FF/MPV）统一。
          // 理由见 `_activeLiveControls` 的注释。
          if ((isIosAv || isIosKs || isMpvPath) && !_audioMode && routeIsCurrent)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _controlsWrap(_activeLiveControls()),
            ),
          if (_audioMode) _buildAudioModeOverlay(c, current),
          // 普通模式左上：返回 + LIVE 角标
          if (!_fullscreen)
            Positioned(
              top: topInset,
              left: 4 + pad.left,
              child: _controlsWrap(
                Row(
                  children: [
                    GestureDetector(
                      onTap: () {
                        if (MainTabController.instance.selectedTab.value == 4) {
                          MainTabController.instance.selectedTab.value = 0;
                        } else {
                          Get.back();
                        }
                      },
                      child: Container(
                        width: 40,
                        height: 40,
                        alignment: Alignment.center,
                        // 恒为黑底视频层：前景必须白色（浅色模式下
                        // AppTheme.textPrimary 是深色 → 返回键隐形）。
                        // 半透明黑圆底保证浅色/白色画面下也看得见。
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.22),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.14),
                          ),
                        ),
                        child: Icon(
                          Icons.arrow_back_ios_new,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // 全屏：左上返回（退出全屏并回首页/退路由）
          if (_fullscreen)
            Positioned(
              top: 8 + topInset,
              left: 8 + pad.left,
              child: _controlsWrap(
                GestureDetector(
                  onTap: () {
                    _toggleFullscreen();
                    if (MainTabController.instance.selectedTab.value == 4) {
                      MainTabController.instance.selectedTab.value = 0;
                    } else {
                      Get.back();
                    }
                  },
                  child: Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    // 同 _VideoTopIcon：黑底视频层上必须用白色，
                    // 半透明黑圆底保证浅色画面下可见。
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.22),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.14),
                      ),
                    ),
                    child: Icon(
                      Icons.arrow_back_ios_new,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
          // 右上：功能按钮（听剧/小窗/投屏/全屏）
          Positioned(
            top: topInset,
            right: 8 + pad.right,
            child: _controlsWrap(
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_fullscreen && current != null)
                    Container(
                      constraints: const BoxConstraints(maxWidth: 150),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      child: Text(
                        current.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: AppTheme.fontCaption,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  _VideoTopIcon(
                    icon: _audioMode
                        ? Icons.headphones
                        : Icons.headphones_outlined,
                    onTap: _toggleAudioMode,
                    tooltip: '听剧模式',
                  ),
                  _VideoTopIcon(
                    icon: Icons.picture_in_picture_alt,
                    onTap: _togglePip,
                    tooltip: '小窗播放',
                  ),
                  _VideoTopIcon(
                    icon: Icons.cast,
                    onTap: _toggleCast,
                    tooltip: '投屏',
                  ),
                  // 播放器核心切换：点击弹出菜单由用户选择（iOS：AVPlayer/MPV），
                  // 只有一个可用内核（Android/桌面）时不显示。样式同「短」「抖」按钮。
                  if (_liveEngines.length > 1)
                    Tooltip(
                      message: '播放器核心',
                      preferBelow: false,
                      child: GestureDetector(
                        onTap: _showLiveEnginePicker,
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          width: 38,
                          height: 38,
                          alignment: Alignment.center,
                          // 与右上功能钮同款背景：半透明黑圆底 + 细白描边
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.22),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.14),
                            ),
                          ),
                          child: Text(
                            switch (PlayerPrefs
                                .instance.liveEngine.value) {
                              PlayerEngine.avplayer => 'AV',
                              PlayerEngine.ksplayer => 'FF',
                              PlayerEngine.mpv => 'MPV',
                              PlayerEngine.webview => 'WEB',
                            },
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              height: 1.0,
                            ),
                          ),
                        ),
                      ),
                    ),
                  // 短剧模式：纯竖屏全屏（样式参考弹幕按钮「短」字）
                  Tooltip(
                    message: _dramaMode ? '退出短剧' : '短剧模式',
                    preferBelow: false,
                    child: GestureDetector(
                      onTap: _toggleDramaMode,
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        width: 38,
                        height: 38,
                        alignment: Alignment.center,
                        // 与右上功能钮同款背景：半透明黑圆底 + 细白描边，
                        // 亮/暗画面下都清晰（不再裸文字压视频）
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.22),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.14),
                          ),
                        ),
                        child: Text(
                          '短',
                          style: TextStyle(
                            color: _dramaMode
                                ? AppTheme.accentColor
                                : Colors.white,
                            fontSize: AppTheme.fontHeadline,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 抖音模式：纯竖屏全屏 + 右侧切换胶囊（「抖」字）
                  Tooltip(
                    message: _douyinMode ? '退出抖音' : '抖音模式',
                    preferBelow: false,
                    child: GestureDetector(
                      onTap: _toggleDouyinMode,
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        width: 38,
                        height: 38,
                        alignment: Alignment.center,
                        // 与「短」同款背景
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.22),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.14),
                          ),
                        ),
                        child: Text(
                          '抖',
                          style: TextStyle(
                            color: _douyinMode
                                ? AppTheme.accentColor
                                : Colors.white,
                            fontSize: AppTheme.fontHeadline,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                  _VideoTopIcon(
                    icon: _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    onTap: _toggleFullscreen,
                    tooltip: _fullscreen ? '退出全屏' : '全屏',
                  ),
                ],
              ),
            ),
          ),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioModeOverlay(LiveController c, LiveChannel? current) {
    final name = current?.name ?? '';
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.headphones, color: Colors.white70, size: 44),
            const SizedBox(height: 16),
            if (name.isNotEmpty)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    // 听剧模式整屏黑底（:972），必须白色
                    color: Colors.white,
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            const SizedBox(height: 6),
            Text(
              '听剧模式 · 后台可继续播放',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: AppTheme.fontCaption,
              ),
            ),
            const SizedBox(height: 18),
            GestureDetector(
              onTap: _toggleAudioMode,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  '退出听剧模式',
                  style: TextStyle(
                    // 同上：黑底
                    color: Colors.white,
                    fontSize: AppTheme.fontFootnote,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 左栏：直播源列表（参考图：一侧是直播源）——绿点=已加载，灰点=未下载
  /// 刷新当前直播源
  void _onRefreshSource() {
    final c = _controller;
    if (c.sources.isEmpty) {
      _pickSource(context, c);
      return;
    }
    // 刷新当前选中的源
    final index = c.selectedSourceIndex;
    if (index >= 0 && index < c.sources.length) {
      c.selectSource(index).then((_) {
        if (mounted) _autoplayCurrent();
      });
      AppToast.message('正在刷新直播源...', duration: const Duration(seconds: 1));
    }
  }

  /// 显示直播源选择弹窗 — 居中、不透明、过高可滚动
  ///
  /// ⚠️ 用户 2026-10-16：「只有这个，直播「选择直播源」这个不变」——
  /// 别把它跟海阔的源切换面板统一（那个走 `CardSourceSheet`）。
  Future<void> _showSourcePicker(BuildContext context, LiveController c) async {
    final srcs = LiveService.instance.sources;
    showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: AppTheme.backgroundSecondary,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 28,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.55,
              maxWidth: 360,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(20, 18, 12, 8),
                  child: Row(
                    children: [
                      Text(
                        '选择直播源',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _pickSource(context, c);
                        },
                        child: const Text('添加源'),
                      ),
                    ],
                  ),
                ),
                if (srcs.isEmpty)
                  Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      '还没有直播源，点击右上角添加',
                      style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontSubhead,
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      itemCount: srcs.length,
                      separatorBuilder: (_, __) =>
                          Divider(height: 1, color: AppTheme.borderLight),
                      itemBuilder: (_, i) {
                        final src = srcs[i];
                        final isActive = c.selectedSourceIndex == i;
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.play_circle_fill,
                            color: isActive
                                ? AppTheme.accentColor
                                : AppTheme.textTertiary,
                            size: 22,
                          ),
                          title: Text(
                            src.name,
                            style: TextStyle(
                              color: isActive
                                  ? AppTheme.accentColor
                                  : AppTheme.textPrimary,
                              fontSize: AppTheme.fontBody,
                            ),
                          ),
                          subtitle: Text(
                            isActive ? '当前播放' : src.statusText(),
                            style: TextStyle(
                              color: isActive
                                  ? AppTheme.accentColor.withValues(alpha: 0.7)
                                  : AppTheme.textTertiary,
                              fontSize: AppTheme.fontCaption,
                            ),
                          ),
                          trailing: isActive
                              ? Icon(
                                  Icons.check_circle,
                                  color: AppTheme.accentColor,
                                  size: 20,
                                )
                              : null,
                          onTap: () async {
                            Navigator.pop(ctx);
                            await c.selectSource(i);
                            if (mounted) _autoplayCurrent();
                          },
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 显示分组选择弹窗 — 居中、不透明、过高可滚动
  Future<void> _showGroupPicker(
    BuildContext context,
    LiveController c,
    List<LiveGroup> groups,
  ) async {
    showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: AppTheme.backgroundSecondary,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 28,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.55,
              maxWidth: 360,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(20, 18, 20, 10),
                  child: Text(
                    '选择分组',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    itemCount: groups.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, color: AppTheme.borderLight),
                    itemBuilder: (_, i) {
                      final g = groups[i];
                      final selected = c.selectedGroup == i;
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          Icons.playlist_play,
                          color: selected
                              ? AppTheme.accentColor
                              : AppTheme.textTertiary,
                          size: 22,
                        ),
                        title: Text(
                          g.name,
                          style: TextStyle(
                            color: selected
                                ? AppTheme.accentColor
                                : AppTheme.textPrimary,
                            fontSize: AppTheme.fontBody,
                          ),
                        ),
                        subtitle: Text(
                          '${g.channels.length} 个频道',
                          style: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: AppTheme.fontCaption,
                          ),
                        ),
                        trailing: selected
                            ? Icon(
                                Icons.check_circle,
                                color: AppTheme.accentColor,
                                size: 20,
                              )
                            : null,
                        onTap: () {
                          Navigator.pop(ctx);
                          c.selectGroup(i);
                          _autoplayCurrent();
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        );
      },
    );
  }

  // ignore: unused_element
  void _showAnnouncements(BuildContext context) {
    final list = LiveService.instance.announcements;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      builder: (ctx) => kbSheet(
        SafeArea(
          child: list.isEmpty
              ? Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    '暂无公告',
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontSubhead,
                    ),
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        '公告',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontHeadline,
                        ),
                      ),
                    ),
                    for (final item in list)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          Icons.tv,
                          color: AppTheme.textSecondary,
                          size: 20,
                        ),
                        title: Text(
                          item,
                          style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: AppTheme.fontSubhead,
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  Future<void> _toggleFullscreen() async {
    // 短剧/抖音模式点全屏按钮 → 退出模式全屏（还原方向）
    if (_dramaMode || _douyinMode) {
      await _leaveFullscreenUi();
      return;
    }
    if (_fullscreen) {
      await _leaveFullscreenUi();
      return;
    }
    await _enterFullscreenUi(portrait: false);
  }

  /// 短剧模式：纯竖屏全屏（复用全屏布局，方向锁 portraitUp）
  Future<void> _toggleDramaMode() async {
    if (_dramaMode) {
      await _leaveFullscreenUi();
      return;
    }
    // 若处于横屏全屏，先退出还原方向，再进竖屏
    if (_fullscreen) {
      await _leaveFullscreenUi();
    }
    await _enterFullscreenUi(portrait: true, douyin: false);
  }

  /// 抖音模式：纯竖屏全屏（与短剧互斥；进入时右侧切换胶囊）
  Future<void> _toggleDouyinMode() async {
    if (_douyinMode) {
      await _leaveFullscreenUi();
      return;
    }
    // 若处于横屏全屏，先退出还原方向，再进竖屏
    if (_fullscreen) {
      await _leaveFullscreenUi();
    }
    await _enterFullscreenUi(portrait: true, douyin: true);
  }

  /// 进入全屏（portrait=false 横屏 / portrait=true 竖屏短剧或抖音）
  Future<void> _enterFullscreenUi(
      {required bool portrait, bool douyin = false}) async {
    setState(() {
      _fullscreen = true;
      _dramaMode = portrait && !douyin;
      _douyinMode = portrait && douyin;
    });
    // 通知全局：全屏时隐藏底部悬浮导航栏
    PlayerFullscreenController.instance.enter('live');
    await SystemUiController.enter(
      'live',
      mode: SystemUiMode.immersiveSticky,
      // 横屏 = 左右横屏；竖屏短剧 = 仅竖屏
      orientations: Platform.isIOS
          ? (portrait
              ? const [DeviceOrientation.portraitUp]
              : const [
                  DeviceOrientation.landscapeLeft,
                  DeviceOrientation.landscapeRight,
                ])
          : null,
      // 视频黑底 → 浅色状态栏图标
      overlayStyle: SystemUiOverlayStyle.light,
    );
  }

  /// 退出全屏 / 短剧 / 抖音（还原**进入前**的方向与系统栏状态）
  Future<void> _leaveFullscreenUi() async {
    setState(() {
      _fullscreen = false;
      _dramaMode = false;
      _douyinMode = false;
    });
    PlayerFullscreenController.instance.exit('live');
    await SystemUiController.exit('live');
  }

  Future<void> _showEpgSheet(BuildContext context, LiveController c) async {
    final ch = c.currentChannel;
    if (ch == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.backgroundPrimary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.5,
          child: FutureBuilder<List<EpgProgram>>(
            future: EpgService.instance.programsFor(ch.name),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final list = snap.data ?? <EpgProgram>[];
              if (list.isEmpty) {
                return Center(
                  child: Text(
                    '暂无节目单\n请在 直播设置 里配置 EPG 地址',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                );
              }
              final now = DateTime.now();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      '节目单 · ${ch.name}',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final p = list[i];
                        final playing =
                            p.start != null &&
                            p.stop != null &&
                            now.isAfter(p.start!) &&
                            now.isBefore(p.stop!);
                        return ListTile(
                          dense: true,
                          title: Text(
                            p.title,
                            style: TextStyle(
                              color: playing
                                  ? AppTheme.accentColor
                                  : AppTheme.textPrimary,
                              fontWeight: playing
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                          trailing: Text(
                            EpgService.instance.formatTime(p.start),
                            style: TextStyle(
                              color: playing
                                  ? AppTheme.accentColor
                                  : AppTheme.textTertiary,
                              fontSize: AppTheme.fontFootnote,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildChannelList(LiveController c, List<LiveChannel> channels) {
    if (channels.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.tv_off, color: AppTheme.textTertiary, size: 48),
            SizedBox(height: 12),
            Text(
              '该分组暂无频道',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontSubhead,
              ),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 0), // 底部 padding 归 0（与首页统一）
      itemCount: channels.length,
      separatorBuilder: (_, __) =>
          Divider(height: 1, color: AppTheme.borderLight),
      itemBuilder: (_, i) {
        final ch = channels[i];
        final selected = c.selectedChannelIndex.value == i;
        final fav = c.isFavorite(ch);
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          title: Text(
            ch.name,
            style: TextStyle(
              color: selected ? AppTheme.accentColor : AppTheme.textPrimary,
              fontSize: AppTheme.fontHeadline,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
          subtitle: Text(
            ch.urls.isNotEmpty ? (ch.group) : '未下载',
            style: TextStyle(
              color: AppTheme.textTertiary,
              fontSize: AppTheme.fontCaption,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => c.toggleFavorite(ch),
                child: Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(
                    fav ? Icons.star : Icons.star_border,
                    color: fav ? AppTheme.accentColor : AppTheme.textTertiary,
                    size: 20,
                  ),
                ),
              ),
              SizedBox(width: 4),
              Icon(
                Icons.play_circle_fill,
                color: selected
                    ? AppTheme.accentColor
                    : AppTheme.textTertiary.withValues(alpha: 0.5),
                size: 22,
              ),
            ],
          ),
          onTap: () {
            c.selectChannel(i);
            _playChannel(ch.playUrl);
          },
        );
      },
    );
  }
}

class _LiveDot extends StatefulWidget {
  const _LiveDot();
  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
      child: Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          color: Colors.redAccent,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// 视频画面上的顶栏功能按钮（半透明黑底 + 白色图标，与点播播放器风格一致）
class _VideoTopIcon extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  const _VideoTopIcon({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      preferBelow: false,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          // ⚠️ 这几个按钮画在黑底视频层上：不能用跟随主题的
          // AppTheme.textPrimary（浅色模式下是深色 → 图标隐形）。
          // 同时必须加半透明黑圆底 —— 直播画面本身可能是浅色/白色，
          // 纯白图标直接压浅色画面 = 看不见（用户实测深色模式看不清）。
          // 黑圆底 + 白图标在任何画面上都清晰。
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.22),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

class _EmptyLive extends StatelessWidget {
  final VoidCallback onReload;
  const _EmptyLive({required this.onReload});

  @override
  Widget build(BuildContext context) {
    return AppEmptyView(
      icon: Icons.live_tv,
      title: '暂无直播频道',
      subtitle: '在订阅 JSON 的 lives 配置，或导入 m3u',
      iconColor: AppTheme.textTertiary,
      action: OutlinedButton(
        onPressed: onReload,
        child: Text('导入直播源', style: TextStyle(color: AppTheme.accentColor)),
      ),
    );
  }
}
