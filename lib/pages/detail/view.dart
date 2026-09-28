import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../../services/live_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'package:media_kit/media_kit.dart';
import '../../common/constants.dart';
import 'package:path_provider/path_provider.dart';
import 'package:media_kit_video/media_kit_video.dart' hide Video;
import 'dart:ui' show ImageFilter;
import '../../common/theme.dart';
import '../../models/movie.dart';
import '../../models/vod_info.dart';
import '../../models/player_engine.dart';
import '../../services/api_config.dart';
import '../../widgets/vod_card.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import '../../models/cache_store.dart';
import '../../services/background_service.dart';
import '../../services/tmdb_service.dart';
import '../../services/player_fullscreen_controller.dart';
import '../../services/main_tab_controller.dart';
import '../../widgets/glass.dart';
import '../../widgets/common_widgets.dart';
import '../../widgets/video_player.dart';
import '../../widgets/video_player_pip.dart';
import '../../widgets/window_fullscreen.dart';
import '../play/webview_player_page.dart';
import 'controller.dart';
import 'episode_list.dart';

/// 详情页 - 对应 Swift DetailView
class DetailPage extends StatefulWidget {
  DetailPage({super.key});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {

  /// 每次进入详情页强制重建 controller（兼容旧版 GetX，无 force 参数）：
  /// 先删除旧实例再重新 put，确保 vodInfo/isPlaying/playUrl 不残留上次状态，
  /// 避免"进详情页像重启/显示旧视频"。
  final _controller = _rebuildController();

  /// 强制重建 DetailController：Get.put 默认复用已存在实例，
  /// 先 Get.delete 再 put，保证每次进入详情页都是全新实例。
  static DetailController _rebuildController() {
    if (Get.isRegistered<DetailController>()) {
      Get.delete<DetailController>();
    }
    return Get.put(DetailController());
  }
  bool _isDescriptionExpanded = false;
  double _lastPersistedProgress = 0;

  /// 持有 Player 实例，全屏/普通模式之间复用同一实例，避免状态丢失
  Player? _player;
  /// 持有 VideoController 实例，与上面 _player 配套使用，跨全屏/普通模式共享，
  /// 保证 ANGLE surface / texture 通道在 OS 全屏切换时不被重建。
  VideoController? _videoController;
  String? _lastPlayerUrl;
  String? _lastPlayerHeadersKey;
  /// 是否已排队 post-frame 重建 Player，防止 build 内重复 schedule
  bool _playerRecreateScheduled = false;
  SharedPreferences? _prefs;
  int? _prefsPlayTypeVod;

  /// VideoPlayerWidget 状态变化回调（mpv native fullscreen 状态变化时）
  /// true=进入 native 全屏，false=退出 native 全屏
  void _onFullScreenChanged(bool isFull) {
    if (!mounted) return;
    _controller.isFullScreen.value = isFull;
    // **2026-07-09**: 同步全局全屏状态, 让 app.dart 根 Scaffold 的
    // 底栏(首页/历史/收藏/设置) 在全屏时隐藏
    if (isFull) {
      PlayerFullscreenController.instance.enter('detail');
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    } else {
      PlayerFullscreenController.instance.exit('detail');
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  @override
  void initState() {
    super.initState();
    // 打开点播时停掉直播，避免双路声音
    LiveService.pauseLivePlayer?.call();
    _loadPrefs();
    _loadDetailIfNeeded();
    // 监听 PiP 状态变化，确保退出 PiP 时退出全屏（互斥）
    VideoPlayerPip.instance.activeNotifier.addListener(_onPipChanged);
    // 监听 WindowFullScreen 状态变化：作为冗余同步通道，
    // 保证 WindowFullScreen.toggle 后 isFullScreen Rx 一定被同步
    WindowFullScreen.instance.activeNotifier.addListener(_onFullScreenActiveChanged);
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _prefs = prefs;
      _prefsPlayTypeVod = prefs.getInt(AppConstants.playTypeVod);
    } catch (_) {}
  }

  void _loadDetailIfNeeded() {
    final video = Get.arguments;
    if (video != null && video is Video) {
      _controller.loadDetail(video).then((_) {
        // 有历史则恢复续播；无历史则直接自动播放当前选集第一集
        final restored = _restorePlaybackFromHistory();
        if (!restored && _controller.currentEpisodes.isNotEmpty) {
          _controller.selectEpisode(_controller.selectedEpisodeIndex.value);
        }
        _refreshCollectState();
        // TMDB 智能刮削（设置里可关）
        _enrichFromTmdb();
      });
    }
  }

  void _onPipChanged() {
    if (mounted) setState(() {});
  }

  /// TMDB 智能刮削：配置了 Key 且开启自动时，补全海报/简介/演职员
  Future<void> _enrichFromTmdb() async {
    final tmdb = TmdbService.instance;
    if (!tmdb.configured || !tmdb.autoScrape.value) return;
    final info = _controller.vodInfo.value;
    if (info == null) return;
    final ok = await tmdb.enrich(info);
    if (ok && mounted) {
      setState(() {});
    }
  }

  /// 手动点击刮削（无视自动开关，仍需配置 Key）
  Future<void> _manualScrapeFromTmdb() async {
    final tmdb = TmdbService.instance;
    if (!tmdb.configured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在 设置 → 元数据 填写 TMDB API Key')),
      );
      return;
    }
    final info = _controller.vodInfo.value;
    if (info == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('正在刮削 TMDB 元数据...')),
    );
    final ok = await tmdb.enrich(info);
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? '刮削完成，已更新海报/简介/演职员' : '未匹配到 TMDB 条目')),
    );
  }

  /// 冗余同步通道：WindowFullScreen 状态变化时同步 detail view 的 Rx
  /// （与 onFullScreenChanged 回调功能相同，作为兜底）
  void _onFullScreenActiveChanged() {
    if (!mounted) return;
    final isFull = WindowFullScreen.instance.isActive;
    if (_controller.isFullScreen.value != isFull) {
      _controller.isFullScreen.value = isFull;
    }
  }

  @override
  void dispose() {
    VideoPlayerPip.instance.activeNotifier.removeListener(_onPipChanged);
    WindowFullScreen.instance.activeNotifier.removeListener(_onFullScreenActiveChanged);
    // 退出页面时关闭 PiP，恢复窗口
    if (VideoPlayerPip.instance.isActive) {
      VideoPlayerPip.instance.exit();
    }
    // 退出页面时退出全屏，恢复窗口
    if (WindowFullScreen.instance.isActive) {
      WindowFullScreen.instance.exit();
    }
    VideoPlayerPip.instance.detachPlayer();
    _player?.dispose();
    _player = null;
    _videoController = null;
    super.dispose();
  }

  /// 确保 player 已创建并打开当前 url
  /// 同一 url+headers 不重复创建
  ///
  /// **startPosition 续播**：传 `Duration` 给 `Media.start` 参数，
  /// 让 libmpv 在 player open 时**直接**从续播位置开始解码，
  /// 避免 "先从 0 播几秒再回退" 的现象。对应 Swift 的
  /// `mediaPlayerStateChanged → state=.playing → applyPendingSeekIfNeeded`
  /// 模式，但 libmpv 端做更彻底 (根本不会经过 0 位置)。
  /// - 传 null / 0 → 从 0 开始（冷启动 / 切换集数）
  /// - 传 > 0 → 从该秒数开始（续播）
  /// 当前 Player 是否已绑定到目标 URL/headers
  bool _playerMatches(String url, String headersKey) {
    return _player != null &&
        _lastPlayerUrl == url &&
        _lastPlayerHeadersKey == headersKey;
  }

  String _headersKey(Map<String, String> headers) {
    return headers.entries.map((e) => '${e.key}=${e.value}').join('&');
  }

  /// 确保 Player 可用并指向 (url, headers)。
  ///
  /// **复用同一个 Player**（与直播页一致）：换集/换清晰度只 `open` 新媒体，
  /// 不 dispose 重建 —— 否则 VideoPlayerWidget 同 key 复用 State 时仍绑着
  /// 已销毁的旧 Player，画面灰屏/黑屏（截图里播放器空白的根因）。
  /// 仅首次创建时走 post-frame，避免在 build 里构造 native Player。
  bool _ensurePlayer(
    String url,
    Map<String, String> headers, {
    double? startPosition,
  }) {
    final headersKey = _headersKey(headers);
    final start = (startPosition != null && startPosition > 0)
        ? Duration(seconds: startPosition.toInt())
        : null;

    // 已有 Player 且 URL/headers 未变 → 直接就绪
    if (_player != null && _playerMatches(url, headersKey)) {
      return true;
    }

    // 已有 Player，只是换了源 → 在同一个 Player 上 open 新媒体
    if (_player != null && _videoController != null) {
      _lastPlayerUrl = url;
      _lastPlayerHeadersKey = headersKey;
      _player!.open(Media(url, httpHeaders: headers, start: start));
      return true;
    }

    // 首次创建：副作用放到 post-frame
    if (_playerRecreateScheduled) {
      return false;
    }
    _playerRecreateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _playerRecreateScheduled = false;
      if (!mounted) return;
      _createPlayerAndOpen(url, headers, headersKey, start);
      setState(() {});
    });
    return false;
  }

  void _createPlayerAndOpen(
    String url,
    Map<String, String> headers,
    String headersKey,
    Duration? start,
  ) {
    if (_player != null) {
      // 并发兜底：期间已被创建则只换源
      _lastPlayerUrl = url;
      _lastPlayerHeadersKey = headersKey;
      _player!.open(Media(url, httpHeaders: headers, start: start));
      return;
    }
    // mpv 磁盘缓存：点播视频缓存到应用 Cache 目录, 下次播放同 URL 直接复用,
    // 解决"每次打开都要重新下载"。缓存目录与设置页"清除缓存"统计目录一致。
    _player = Player(configuration: const PlayerConfiguration(title: 'TVBox'));
    // 同步创建 VideoController，确保 player 与 controller 一一对应
    _videoController = VideoController(_player!);
    _lastPlayerUrl = url;
    _lastPlayerHeadersKey = headersKey;
    _player!.open(Media(url, httpHeaders: headers, start: start));
  }

  @override
  Widget build(BuildContext context) {
    // 关键：isFull / isPip 必须在 Obx 内读取，Rx 变化才能触发 rebuild
    // 否则在 _exitFullScreenRoute 里 _controller.isFullScreen.value = false
    // 不会触发顶层 build，immersive 永远停留在 true（AppBar 永远隐藏）
    return Obx(() {
      final isFull = _controller.isFullScreen.value;
      final isPip = VideoPlayerPip.instance.activeNotifier.value;
      final immersive = isFull || isPip;

      // 背景层放到 Scaffold 外层: 普通模式下全局背景贯穿整个页面
      // (含 AppBar 毛玻璃区域), 修复详情页背景与全局不一致的问题;
      // 沉浸(全屏/PiP)模式保持视频黑底。
      return Stack(
        children: [
          if (!immersive)
            Positioned.fill(
              child: BackgroundService.instance
                  .buildBackground(overlayAlpha: 0.3),
            ),
          Scaffold(
            backgroundColor: Colors.transparent,
            extendBodyBehindAppBar: !immersive,
            appBar: immersive
                ? null
                : AppBar(
                    leading: IconButton(
                      icon: const Icon(Icons.chevron_left,
                          color: Colors.white, size: 28),
                      onPressed: () => Get.back(),
                    ),
                    // 返回行完全透明：盖在播放器上方，不挡播放器顶栏功能
                    backgroundColor: Colors.transparent,
                    elevation: 0,
                    surfaceTintColor: Colors.transparent,
                    flexibleSpace: const SizedBox.shrink(),
                  ),
            body: immersive
                // 全屏/沉浸: 视频黑底, 不需要背景层
                ? Container(
                    color: Colors.black,
                    child: _buildBody(),
                  )
                // 普通模式: 播放器贴顶（不再预留 AppBar/状态栏高度）
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildBody(),
                      _buildFloatingNavBar(context),
                    ],
                  ),
          ),
        ],
      );
    });
  }

  /// 详情页底部悬浮导航栏 - 与根 ContentView 悬浮栏同款
  /// 详情页是 Get.toNamed push 的独立路由, 盖在根界面之上;
  /// 这里复刻同一套 GlassPanel 悬浮栏, 让详情页也能一键切回主 tab。
  Widget _buildFloatingNavBar(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    const navSideGap = 32.0;
    const navFloatGap = 8.0;
    return Positioned(
      left: navSideGap,
      right: navSideGap,
      bottom: bottomInset + navFloatGap,
      child: Obx(() {
        final current = MainTabController.instance.selectedTab.value;
        return GlassPanel(
          radius: 30,
          // **真悬浮轻玻璃 (2026-09-26)**：与首页底栏同款 glassTintClear
          // (alpha≈2%)，毛玻璃+细描边+高光，内容滚过其下依旧清晰可见。
          blur: true,
          tint: AppTheme.glassTintClear,
          borderColor: Colors.white.withValues(alpha: 0.10),
          borderWidth: 0.8,
          highlightStrength: 0.2,
          shadow: true,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _floatingNavItem(
                Icons.home_outlined, Icons.home, '首页', 0, current),
              // 直播：第 5 个 tab（选中联动高亮，修复详情页直播写死高亮）
              _floatingNavItem(
                Icons.live_tv, Icons.live_tv, '直播', 4, current),
              _floatingNavItem(
                Icons.schedule_outlined, Icons.schedule, '历史', 1, current),
              _floatingNavItem(
                Icons.favorite_border, Icons.favorite, '收藏', 2, current),
              _floatingNavItem(
                Icons.settings_outlined, Icons.settings, '设置', 3, current),
            ],
          ),
        );
      }),
    );
  }

  Widget _floatingNavItem(
      IconData icon, IconData activeIcon, String label, int index, int current) {
    final isSelected = current == index;
    return GestureDetector(
      onTap: () {
        // 切 tab 并返回根界面
        MainTabController.instance.select(index);
        Get.back();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.accentColor.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isSelected ? activeIcon : icon,
              size: 18,
              color: isSelected
                  ? AppTheme.accentColor
                  : Colors.white.withValues(alpha: 0.35),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: isSelected
                    ? AppTheme.accentColor
                    : Colors.white.withValues(alpha: 0.35),
              ),
            ),
          ],
        ),
      ),
    );
  }
  /// build 的 body 部分（视频区域 + 信息 + 选集 + 简介）
  /// isFull / isPip 必须在本方法内自己读 Rx，闭包捕获的旧值会让全屏态卡死
  Widget _buildBody() {
    return Obx(() {
      // 关键：这里再读一次 isFullScreen / activeNotifier，让本 Obx 监听它们
      // 外层 Obx rebuild 时本 Obx 也会跟着 rebuild
      final isFull = _controller.isFullScreen.value;
      final isPip = VideoPlayerPip.instance.activeNotifier.value;
      // 兜底：如果 Rx 与 WindowFullScreen 状态不一致，以 WindowFullScreen 为准
      final actualFull = isFull || WindowFullScreen.instance.isActive;
      final immersive = actualFull || isPip;

      if (_controller.isLoading.value && _controller.vodInfo.value == null) {
        return const AppLoading();
      }

      if (_controller.errorMessage.value != null &&
          _controller.vodInfo.value == null) {
        return AppError(
          message: _controller.errorMessage.value!,
          onRetry: () {
            final video = Get.arguments;
            if (video != null && video is Video) {
              _controller.loadDetail(video);
            }
          },
        );
      }

      final info = _controller.vodInfo.value;
      if (info == null) return const SizedBox.shrink();

      // 全屏 / PiP 模式：只显示视频（视频始终在 tree 中同一位置）
      if (immersive) {
        return _buildPlayerArea();
      }

      // 悬浮导航栏占位高度: 滚动内容底部少量留白, 让最后一项
      // (选集/简介) 滚动到底时能完全滚出悬浮栏上方 (真悬浮, 非全局预留)
      final bottomInset = MediaQuery.of(context).padding.bottom;
      const navFloatGap = 8.0;
      const navBarHeight = 51.0;
      final navReserve = bottomInset + navFloatGap + navBarHeight + 22.0;

      // 正常模式：视频 + 视频信息 + 选集 + 简介
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. 播放器 - 对应 Swift PlayerView
            // **进详情即显示播放界面**：不依赖 isPlaying，只要 vodInfo 就绪
            // 就渲染播放器容器；URL 未就绪时 _buildPlayerArea 内部显示
            // 4:3 加载占位，解析完成后自动出画面（不再"先进文字后出视频"）
            _buildPlayerArea(),

            // 2. 视频信息区：简介/推荐/快搜 tab
            //    （简介 tab 内含 播放源/画质/合集 线路列表卡片；推荐/快搜 不显示）
            _buildVideoInfo(),

            // 底部间距 - 预留悬浮导航栏高度, 让内容能完整滚出悬浮栏
            // (不再被底部悬浮菜单栏挡住最后一行内容)
            SizedBox(height: navReserve),
          ],
        ),
      );
    });
  }

  // MARK: - 播放器

  /// 播放器区域 - 始终在 tree 中同一位置，避免 VideoPlayerWidget 被重建
  /// 16:9 容器内放视频；如果父容器充满（immersive 模式），则视频也充满父容器
  /// 全屏切换由 detail view 自己管理的 Overlay + EnterNativeFullscreen/ExitNativeFullscreen
  /// 通道处理（见 _enterFullScreenRoute / _exitFullScreenRoute）。
  /// PiP 互斥由 widget 内部的 _togglePiP / _onUserToggleFullscreen 处理。

  Widget _buildPlayerArea() {
    // 关键：isFull/isPip/playUrl 都在同一个 Obx 内读取，
    // 任何一个变化都会触发 rebuild，_buildPlayerWidget 内能拿到最新值
    return Obx(() {
      final isFull = _controller.isFullScreen.value;
      final isPip = VideoPlayerPip.instance.activeNotifier.value;
      final url = _controller.playUrl.value;
      if (url != null && url.isNotEmpty) {
        return _buildPlayerWidget(isFull: isFull, isPip: isPip);
      } else {
        // 正在播放但 URL 尚未就绪
        // 4:3 容器: 比 16:9 更高, 上下控制条间距拉开, 视频画面不再被压成细缝
        return AspectRatio(
          aspectRatio: 4 / 3,
          child: Container(
            color: Colors.black,
            child: const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
          ),
        );
      }
    });
  }

  /// 创建并返回播放器 widget
  /// 视频组件本身不感知全屏/普通模式，全屏由 VideoState 内部处理
  /// isFull/isPip 必须由 _buildPlayerArea 在 Obx 内传入，
  /// 否则 Rx 变化时这里还是用闭包捕获的旧值，导致全屏态无法退出
  Widget _buildPlayerWidget({required bool isFull, required bool isPip}) {
    final url = _controller.playUrl.value!;
    // 网页播放器页（非直链媒体 URL）→ 用 WebView 兜底播放
    // （对应 catmovie WebviewView：第三方解析页 / parse=1 网页端 / player 页）
    if (_isWebPageUrl(url)) {
      // 内嵌模式: 4:3 固定高度(内部处理), 避免 Column 内高度塌陷致有声无画面
      return WebviewPlayerPage(
        url: url,
        title: _controller.vodInfo.value?.name,
        embedded: true,
      );
    }
    final headers = _controller.playHeaders.isNotEmpty
        ? Map<String, String>.from(_controller.playHeaders)
        : const <String, String>{};

    // **播放内核 (2026-09-27)**：核心只保留 MPV / KSPlayer / UPlayer / Webview。
    // AVPlayer(video_player) 内核已移除。设置中选 Webview 引擎时直接走网页播放页；
    // KSPlayer/UPlayer 由对应原生内核播放（未完成桥接时兜底回 MPV，见 _ensurePlayer）。
    final engine = Platform.isIOS
        ? PlayerEngine.fromStoredValue(_prefsPlayTypeVod ?? 0)
        : PlayerEngine.mpv;
    if (engine == PlayerEngine.webview) {
      // 同上: 内嵌模式
      return WebviewPlayerPage(
        url: url,
        title: _controller.vodInfo.value?.name,
        embedded: true,
      );
    }

    // 把续播位置透传给 _ensurePlayer, 让 libmpv 通过 Media.start 参数
    // 直接从续播位置开始解码, 避免 "先从 0 播几秒再回退" 的现象。
    // _ensurePlayer 内部把 dispose/open 放到 post-frame，这里不阻塞 build。
    final playerReady = _ensurePlayer(
      url,
      headers,
      startPosition: _controller.resumeSeconds.value,
    );
    if (!playerReady || _player == null || _videoController == null) {
      // 与正常播放器同高（4:3），避免加载态与出画后高度跳动
      return AspectRatio(
        aspectRatio: 4 / 3,
        child: Container(
          color: Colors.black,
          child: const Center(
            child: CircularProgressIndicator(color: Colors.white),
          ),
        ),
      );
    }

    final info = _controller.vodInfo.value;
    final episode = info?.currentEpisode;
    final widget = VideoPlayerWidget(
      // ObjectKey 跟随 Player 实例：万一重建 Player，State 会整体 remount，
      // 不会残留绑在已 dispose Player 上的 controller/纹理（灰屏）
      key: ObjectKey(_player),
      player: _player,
      controller: _videoController, // 跨全屏/普通模式共享同一个 controller
      initialVideoFit: VideoFitType.contain, // 4:3 容器 + 黑框适配: 画面按原始比例完整显示, 上下黑边
      url: url,
      headers: headers.isEmpty ? null : headers,
      resumeSeconds: _controller.resumeSeconds.value,
      videoTitle: info?.name,
      currentEpisodeName: episode?.name,
      episodeNames: _controller.currentEpisodes
          .map((e) => e.name)
          .toList(),
      selectedEpisodeIndex: _controller.selectedEpisodeIndex.value,
      canPlayNext: _controller.selectedEpisodeIndex.value <
          _controller.currentEpisodes.length - 1,
      canPlayPrevious: _controller.selectedEpisodeIndex.value > 0,
      isPipMode: isPip,
      showAudioModeButton: true,
      skipIntroSeconds: _controller.skipIntroSeconds.value,
      skipOutroSeconds: _controller.skipOutroSeconds.value,
      onPlayNext: () => _playNextEpisode(),
      onPlayPrevious: () => _playPreviousEpisode(),
      onSelectEpisode: (index) {
        _controller.selectEpisode(index);
        _saveHistoryForCurrentEpisode();
      },
      onPositionChanged: (pos) =>
          _handlePlaybackProgress(pos.inSeconds.toDouble()),
      onEnded: () => _playNextEpisode(),
      // native fullscreen 状态变化回调：同步 detail view 的 immersive 模式
      onFullScreenChanged: _onFullScreenChanged,
      onBack: () {
        // 处于 PiP 模式时，返回键先退出 PiP 恢复原窗口
        if (VideoPlayerPip.instance.isActive) {
          VideoPlayerPip.instance.exit();
          return;
        }
        Get.back();
      },
      onSetSkipIntro: (s) => _controller.setSkipIntroSeconds(s),
      onSetSkipOutro: (s) => _controller.setSkipOutroSeconds(s),
    );

    // immersive 模式（native 全屏 / PiP）：视频填满父容器
    // 正常模式：4:3 容器 (比 16:9 更高, 上下控制条间距拉开,
    // 视频画面可视区域约翻倍, 修复"上下菜单栏挨着近"的问题)
    if (isFull || isPip) {
      return SizedBox.expand(child: widget);
    }
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: widget,
    );
  }

  /// 判断播放 URL 是否为"网页播放器页"（需 WebView 兜底）而非直链媒体。
  ///
  /// 规则：
  /// - 非 http/https（如 rtmp/rtsp）→ 不是网页，走原生播放器
  /// - 含常见媒体扩展名（m3u8/mp4/flv/ts 等）→ 直链，走原生播放器
  /// - 其余 http(s) URL → 视为网页播放页（解析页 / player 页 / 网页端地址）
  static const List<String> _directMediaExtensions = [
    '.m3u8', '.m3u', '.mp4', '.flv', '.ts', '.mkv', '.avi', '.mov',
    '.webm', '.rmvb', '.rm', '.wmv', '.mp3', '.aac', '.ogg', '.flac',
  ];

  bool _isWebPageUrl(String url) {
    final lower = url.trim().toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return false;
    }
    for (final ext in _directMediaExtensions) {
      if (lower.contains(ext)) {
        return false;
      }
    }
    return true;
  }

  // MARK: - 视频信息区

  /// 视频信息区 - 兰香如故式三 tab 布局（2026-09-26）
  /// 顶部「简介/推荐/快搜」tab；简介 tab 为左海报 + 右信息卡
  /// （名称大字 / 出品方 / 右上角收藏 / 下方简介收起展开）
  /// + 下方 播放源/画质/合集 线路列表卡片（仅简介 tab 显示）。
  Widget _buildVideoInfo() {
    final info = _controller.vodInfo.value;
    if (info == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶部 tab 栏：简介 / 推荐 / 快搜
        _buildDetailTabBar(),
        const SizedBox(height: AppTheme.spacingMD),
        Obx(() {
          switch (_controller.detailTabIndex.value) {
            case 1:
              return _buildRecommendTab();
            case 2:
              return _buildQuickSearchTab();
            default:
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildIntroTab(info),
                  const SizedBox(height: AppTheme.spacingMD),
                  // 线路列表卡片只在简介 tab 出现（参考图）
                  _buildPlaybackCard(),
                ],
              );
          }
        }),
      ],
    );
  }

  /// 顶部 tab 栏（简介/推荐/快搜）- 对应参考图 segmentedTab
  Widget _buildDetailTabBar() {
    const tabs = ['简介', '推荐', '快搜'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingLG),
      child: Container(
        height: 36,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Row(
          children: List.generate(tabs.length, (index) {
            final selected = _controller.detailTabIndex.value == index;
            return Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  _controller.detailTabIndex.value = index;
                  if (index == 1) {
                    _controller.loadRecommended();
                  }
                },
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected
                        ? AppTheme.accentColor.withValues(alpha: 0.16)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    tabs[index],
                    style: TextStyle(
                      color: selected ? AppTheme.textPrimary : AppTheme.textTertiary,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  /// 简介 tab - 左海报 + 右信息卡（对应参考图兰香如故）
  /// 海报必须给死宽度：Row + AspectRatio 无宽度约束会塌成 0（内容「缺失」）。
  Widget _buildIntroTab(VodInfo info) {
    final sourceName = ApiConfig.instance.getSource(info.sourceKey)?.name ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingLG),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧大海报 - 固定宽 112，3:4
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: 112,
              height: 149,
              child: info.pic.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: info.pic,
                      fit: BoxFit.cover,
                      placeholder: (_, __) => Container(
                        color: AppTheme.backgroundTertiary,
                        alignment: Alignment.center,
                        child: Icon(Icons.movie_outlined,
                            color: AppTheme.textTertiary, size: 28),
                      ),
                      errorWidget: (_, __, ___) => Container(
                        color: AppTheme.backgroundTertiary,
                        alignment: Alignment.center,
                        child: Icon(Icons.broken_image_outlined,
                            color: AppTheme.textTertiary, size: 28),
                      ),
                    )
                  : Container(
                      color: AppTheme.backgroundTertiary,
                      alignment: Alignment.center,
                      child: Icon(Icons.movie_outlined,
                          color: AppTheme.textTertiary, size: 28),
                    ),
            ),
          ),
          const SizedBox(width: AppTheme.spacingLG),
          // 右侧信息卡
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 名称大字 + 右上角收藏
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        info.name.isEmpty ? '未知片名' : info.name,
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontTitle2,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppTheme.spacingSM),
                    // 手动 TMDB 刮削
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _manualScrapeFromTmdb,
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: AppTheme.backgroundTertiary,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: AppTheme.borderLight,
                          ),
                        ),
                        child: const Icon(Icons.auto_fix_high,
                            size: 18, color: AppTheme.accentColor),
                      ),
                    ),
                    const SizedBox(width: AppTheme.spacingSM),
                    _buildCollectIconButton(),
                  ],
                ),
                const SizedBox(height: AppTheme.spacingSM),
                // 出品方胶囊 - 对应参考图「奇优影院」
                if (sourceName.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppTheme.accentColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: AppTheme.accentColor.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.theaters_outlined,
                            size: 12, color: AppTheme.accentColor),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            sourceName,
                            style: const TextStyle(
                              color: AppTheme.accentColor,
                              fontSize: AppTheme.fontCaption,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: AppTheme.spacingSM),
                // 元数据（导演/演员/年份/地区）
                _buildMetadataFlow(info),
                const SizedBox(height: AppTheme.spacingSM),
                // 简介 - 2 行收起 / 点击展开
                if (info.des.isNotEmpty)
                  _buildInlineDescription(info)
                else
                  Text(
                    '暂无简介内容',
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 推荐 tab - 同类型影片网格
  Widget _buildRecommendTab() {
    return Obx(() {
      if (_controller.isRecommendLoading.value) {
        return const SizedBox(
          height: 200,
          child: Center(child: AppLoading(message: '加载推荐中...')),
        );
      }
      final items = _controller.recommended;
      if (items.isEmpty) {
        return const SizedBox(
          height: 120,
          child: Center(child: AppError(message: '暂无推荐')),
        );
      }
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingLG),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          childAspectRatio: 0.62,
          mainAxisSpacing: AppTheme.cardSpacing,
          crossAxisSpacing: AppTheme.cardSpacing,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final video = items[index];
          return VodCard(
            video: video,
            onTap: () => Get.toNamed('/detail', arguments: video),
          );
        },
      );
    });
  }

  /// 快搜 tab - 快捷搜索入口（关键词直达全局搜索）
  Widget _buildQuickSearchTab() {
    final info = _controller.vodInfo.value;
    final keywords = <String>[
      if (info != null && info.name.isNotEmpty) info.name,
      if (info != null && info.actor.isNotEmpty)
        ...info.actor.split(',').where((a) => a.trim().isNotEmpty).take(3),
      if (info != null && info.typeName.isNotEmpty) info.typeName,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingLG),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '快速搜索',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontHeadline,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppTheme.spacingMD),
          Wrap(
            spacing: AppTheme.spacingSM,
            runSpacing: AppTheme.spacingSM,
            children: keywords.map((keyword) {
              return SelectableChip(
                title: keyword,
                isSelected: false,
                onTap: () {
                  Get.toNamed('/search', arguments: keyword);
                },
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  /// 收藏按钮（小图标版）- 前置在视频名称前
  /// 点击切换收藏状态，图标随状态变化（实心=已收藏 / 空心=未收藏）
  Widget _buildCollectIconButton() {
    return Obx(() {
      final info = _controller.vodInfo.value;
      if (info == null) return const SizedBox.shrink();
      final isCollected =
          CacheStore.instance.isCollected(info.id, info.sourceKey);

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () async {
          if (isCollected) {
            await CacheStore.instance.removeCollect(info.id, info.sourceKey);
          } else {
            await CacheStore.instance.addCollect(info.toVideo());
          }
        },
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: isCollected
                ? AppTheme.accentColor.withValues(alpha: 0.14)
                : AppTheme.backgroundTertiary,
            shape: BoxShape.circle,
            border: Border.all(
              color: isCollected
                  ? AppTheme.accentColor.withValues(alpha: 0.4)
                  : AppTheme.borderLight,
              width: 0.8,
            ),
          ),
          child: Icon(
            isCollected ? Icons.favorite : Icons.favorite_border,
            size: 18,
            color: isCollected ? AppTheme.accentColor : AppTheme.textSecondary,
          ),
        ),
      );
    });
  }

  /// 影片简介（内联版）- 并入名称卡片，2 行收起 / 点击展开全文
  /// 展开/收起按钮缩为右下角小文本+箭头，不再居中占整行，
  /// 压缩卡片高度，简介框不再过大 (2026-09-26)
  Widget _buildInlineDescription(VodInfo info) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedCrossFade(
          firstChild: Text(
            info.des,
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontBody,
              height: 1.5,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          secondChild: Text(
            info.des,
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontBody,
              height: 1.5,
            ),
          ),
          crossFadeState: _isDescriptionExpanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 250),
        ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () =>
              setState(() => _isDescriptionExpanded = !_isDescriptionExpanded),
          child: Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(top: AppTheme.spacingXS),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _isDescriptionExpanded ? '收起' : '展开',
                    style: const TextStyle(
                      color: AppTheme.accentColor,
                      fontSize: AppTheme.fontFootnote,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Icon(
                    _isDescriptionExpanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 14,
                    color: AppTheme.accentColor,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 元数据流 - 对应 Swift metadataFlow
  Widget _buildMetadataFlow(VodInfo info) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 药丸行 - 对应 Swift HStack(metadataPill)
        Wrap(
          spacing: AppTheme.spacingSM,
          runSpacing: AppTheme.spacingXS,
          children: [
            if (info.year.isNotEmpty) MetadataPill(text: info.year),
            if (info.typeName.isNotEmpty) MetadataPill(text: info.typeName),
            if (info.area.isNotEmpty) MetadataPill(text: info.area),
          ],
        ),
        const SizedBox(height: AppTheme.spacingSM),

        // 导演 - 对应 Swift director row
        if (info.director.isNotEmpty) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 36,
                child: Text(
                  '导演',
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  info.director,
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: AppTheme.fontCaption,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.spacingSM),
        ],

        // 演员 - 对应 Swift actor row
        if (info.actor.isNotEmpty) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 36,
                child: Text(
                  '演员',
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  info.actor,
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: AppTheme.fontCaption,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 播放按钮 - 对应 Swift playButton (仅未播放且有 vodInfo 时显示)
  Widget _buildPlayButton() {
    return Obx(() {
      if (_controller.isPlaying.value || _controller.vodInfo.value == null) {
        return const SizedBox.shrink();
      }
      return GestureDetector(
        onTap: () {
          _controller.selectEpisode(0);
          _saveHistoryForCurrentEpisode();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: AppTheme.spacingMD),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF5CB67B), Color(0xFF7DCEA0)],
            ),
            borderRadius: BorderRadius.circular(AppTheme.radiusMD),
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.play_arrow, color: Colors.white, size: 18),
              SizedBox(width: AppTheme.spacingSM),
              Text(
                '播放',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  // MARK: - 线路选择

  /// 线路选择 - 对应 Swift flagSelector (AppCard)
  Widget _buildFlagSelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingLG, AppTheme.spacingMD, AppTheme.spacingLG, 0),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: '播放线路', icon: Icons.settings_input_antenna),
            const SizedBox(height: AppTheme.spacingSM),
            Obx(() => SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _controller.flags.map((flag) {
                      final isSelected =
                          _controller.selectedFlag.value == flag;
                      return Padding(
                        padding: const EdgeInsets.only(right: AppTheme.spacingSM),
                        child: _PillChip(
                          title: flag,
                          isSelected: isSelected,
                          onTap: () {
                            _controller.selectFlag(flag);
                            if (_controller.isPlaying.value) {
                              _saveHistoryForCurrentEpisode();
                            }
                          },
                        ),
                      );
                    }).toList(),
                  ),
                )),
          ],
        ),
      ),
    );
  }

  /// 播放线路 + 清晰度 + 选集播放 —— 合并成一张独立卡片（三段式底部）
  Widget _buildPlaybackCard() {
    // 有一条也显示，对齐参考图（播放源/画质/合集完整三段）
    final hasFlag = _controller.flags.isNotEmpty;
    final hasQuality = _controller.qualityOptions.isNotEmpty;
    final hasEpisodes = _controller.currentEpisodes.isNotEmpty;
    if (!hasFlag && !hasQuality && !hasEpisodes) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingLG, AppTheme.spacingMD, AppTheme.spacingLG, 0),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasFlag) ...[
              const SectionHeader(title: '播放源', icon: Icons.settings_input_antenna),
              const SizedBox(height: AppTheme.spacingSM),
              Obx(() => SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: _controller.flags.map((flag) {
                        final isSelected =
                            _controller.selectedFlag.value == flag;
                        return Padding(
                          padding: const EdgeInsets.only(right: AppTheme.spacingSM),
                          child: _PillChip(
                            title: flag,
                            isSelected: isSelected,
                            onTap: () {
                              _controller.selectFlag(flag);
                              if (_controller.isPlaying.value) {
                                _saveHistoryForCurrentEpisode();
                              }
                            },
                          ),
                        );
                      }).toList(),
                    ),
                  )),
            ],
            if (hasEpisodes) ...[
              const SizedBox(height: AppTheme.spacingMD),
              Divider(height: 1, color: AppTheme.borderLight),
              const SizedBox(height: AppTheme.spacingMD),
              const SectionHeader(title: '合集', icon: Icons.list),
              const SizedBox(height: AppTheme.spacingSM),
              Obx(() => EpisodeListView(
                    episodeNames: _controller.currentEpisodes
                        .map((e) => e.name)
                        .toList(),
                    selectedIndex: _controller.selectedEpisodeIndex.value,
                    onEpisodeTap: (index) {
                      _controller.selectEpisode(index);
                      _saveHistoryForCurrentEpisode();
                    },
                  )),
            ],
          ],
        ),
      ),
    );
  }

  // MARK: - 清晰度选择

  /// 清晰度选择 - 对应 Swift qualitySelector (AppCard)
  Widget _buildQualitySelector() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingLG, AppTheme.spacingMD, AppTheme.spacingLG, 0),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: '视频清晰度', icon: Icons.auto_awesome),
            const SizedBox(height: AppTheme.spacingSM),
            Obx(() => SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children:
                        _controller.qualityOptions.map((option) {
                      final isSelected =
                          _controller.selectedQualityId.value == option.id;
                      return Padding(
                        padding: const EdgeInsets.only(right: AppTheme.spacingSM),
                        child: _PillChip(
                          title: option.name,
                          isSelected: isSelected,
                          onTap: () {
                            _controller.selectQuality(option);
                            if (_controller.isPlaying.value) {
                              _saveHistoryForCurrentEpisode();
                            }
                          },
                        ),
                      );
                    }).toList(),
                  ),
                )),
          ],
        ),
      ),
    );
  }

  // MARK: - 选集播放

  /// 选集播放 - 对应 Swift episodeSection
  Widget _buildEpisodeList() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingLG, AppTheme.spacingMD, AppTheme.spacingLG, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: '选集播放', icon: Icons.list),
          const SizedBox(height: AppTheme.spacingSM),
          Obx(() => EpisodeListView(
                episodeNames: _controller.currentEpisodes
                    .map((e) => e.name)
                    .toList(),
                selectedIndex: _controller.selectedEpisodeIndex.value,
                onEpisodeTap: (index) {
                  _controller.selectEpisode(index);
                  _saveHistoryForCurrentEpisode();
                },
              )),
        ],
      ),
    );
  }

  // MARK: - 播放控制逻辑

  /// 对应 Swift saveHistoryForCurrentEpisode
  void _saveHistoryForCurrentEpisode({double? progressOverride}) {
    final info = _controller.vodInfo.value;
    if (info == null) return;

    final episodeName = info.currentEpisode?.name.trim() ?? '';
    final episodeLabel = episodeName.isEmpty
        ? '第${_controller.selectedEpisodeIndex.value + 1}集'
        : episodeName;
    final progress = (progressOverride ?? _controller.currentPlaybackSeconds()).clamp(0.0, double.infinity).toDouble();
    final timeLabel = progress > 0 ? _formatDuration(progress) : '';
    final playNote = timeLabel.isEmpty ? episodeLabel : '$episodeLabel $timeLabel';

    final playbackState = VodPlaybackState(
      flag: _controller.selectedFlag.value,
      episodeIndex: _controller.selectedEpisodeIndex.value,
      progressSeconds: progress,
    );

    CacheStore.instance.addRecord(
      info.toVideo(),
      playNote,
      playbackState: playbackState,
    );
  }

  /// 对应 Swift handlePlaybackProgress
  void _handlePlaybackProgress(double seconds) {
    _controller.updatePlaybackProgress(seconds);
    _persistHistoryIfNeeded(force: false, currentProgress: seconds);
  }

  /// 对应 Swift persistHistoryIfNeeded
  void _persistHistoryIfNeeded({required bool force, double? currentProgress}) {
    if (!_controller.isPlaying.value) return;
    final progress = (currentProgress ?? _controller.currentPlaybackSeconds()).clamp(0.0, double.infinity).toDouble();
    if (!progress.isFinite) return;

    if (!force && (progress - _lastPersistedProgress).abs() < 20) {
      return;
    }

    _lastPersistedProgress = progress;
    _saveHistoryForCurrentEpisode(progressOverride: progress);
  }

  /// 对应 Swift restorePlaybackFromHistory
  /// 返回是否成功恢复了历史（无历史/参数缺失返回 false）
  bool _restorePlaybackFromHistory() {
    final video = Get.arguments;
    if (video == null || video is! Video) return false;

    final playbackState = CacheStore.instance.getPlaybackState(
      video.id,
      video.sourceKey,
    );
    if (playbackState == null) return false;

    _controller.applyPlaybackState(playbackState);
    _lastPersistedProgress = playbackState.progressSeconds.clamp(0.0, double.infinity).toDouble();
    return true;
  }

  /// 对应 Swift refreshCollectState
  void _refreshCollectState() {
    // 收藏状态通过 Obx 实时读取，无需额外操作
  }

  /// 对应 Swift playNextEpisodeIfNeeded
  void _playNextEpisode() {
    final moved = _controller.playNext();
    if (moved) {
      _saveHistoryForCurrentEpisode();
    }
  }

  /// 对应 Swift playPreviousEpisode
  void _playPreviousEpisode() {
    final moved = _controller.playPrevious();
    if (moved) {
      _saveHistoryForCurrentEpisode();
    }
  }

  String _formatDuration(double seconds) {
    final h = (seconds ~/ 3600);
    final m = ((seconds % 3600) ~/ 60);
    final s = (seconds.toInt() % 60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

/// 药丸选择芯片 - 对应 Swift pillChip
class _PillChip extends StatelessWidget {
  final String title;
  final bool isSelected;
  final VoidCallback onTap;

  const _PillChip({
    required this.title,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacingLG,
          vertical: AppTheme.spacingSM,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.accentColor.withValues(alpha: 0.12)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          title,
          style: TextStyle(
            color: isSelected ? AppTheme.accentColor : AppTheme.textSecondary,
            fontSize: AppTheme.fontFootnote,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

/// VodInfo 扩展 - 转换为 Video
/// 详情页自动播放: 无历史时自动调用 selectEpisode, 直接播放当前选集第一集
/// (进入详情页即播放, 不再需要点击绿色播放按钮)
extension VodInfoExt on VodInfo {
  Video toVideo() => Video(
        id: id,
        name: name,
        pic: pic,
        note: note,
        year: year,
        area: area,
        director: director,
        actor: actor,
        des: des,
        sourceKey: sourceKey,
      );
}