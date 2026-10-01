import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import '../../services/live_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../common/theme.dart';
import '../../models/movie.dart';
import '../../models/vod_info.dart';
import '../../models/player_engine.dart';
import '../../services/api_config.dart';
import '../../services/spider_service.dart';
import '../../widgets/vod_card.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import '../../models/cache_store.dart';
import '../../models/cache_ttl.dart';
import '../../services/background_service.dart';
import '../../services/tmdb_service.dart';
import '../../services/player_fullscreen_controller.dart';
import '../../services/player_prefs.dart';
import '../../services/main_tab_controller.dart';
import '../../widgets/glass.dart';
import '../../widgets/common_widgets.dart';
import '../../widgets/app_player.dart';
import '../../widgets/ios_av_player.dart';
import '../../widgets/mpv_app_player.dart';
import '../../widgets/video_player.dart';
import '../../widgets/video_player_pip.dart';
import '../../widgets/window_fullscreen.dart';
import '../play/webview_player_page.dart';
import '../search/controller.dart' show TvSearchController;
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

  /// 「快搜」tab 专用的独立搜索控制器。
  ///
  /// 为什么不复用全局的 TvSearchController：那是搜索页的状态源，
  /// 详情页拿它搜索会把搜索页正在展示的结果覆盖掉，返回搜索页就变样了。
  /// 这里直接 new 一个实例（不走 Get.put，因此不会覆盖全局注册），
  /// 生命周期跟详情页一致。
  ///
  /// ⚠️ 不走 GetX 注册，`onInit` 就**不会**自动触发（GetX 是在 `_onStart`
  /// 里调的），所以这里手动调一次 —— 否则 searchHistory 会停在半初始化状态，
  /// 而 `search()` 会写它。
  final _quickSearch = _createQuickSearch();

  static TvSearchController _createQuickSearch() {
    final c = TvSearchController();
    c.onInit();
    return c;
  }

  bool _isDescriptionExpanded = false;

  /// 已为哪个关键词跑过快搜：切换 tab 不重复请求，除非用户点了别的关键词
  String? _quickSearchDoneFor;

  /// 快搜输入框（用户可直接改词）
  final _quickSearchInput = TextEditingController();
  double _lastPersistedProgress = 0;

  /// 持有 Player 实例，全屏/普通模式之间复用同一实例，避免状态丢失
  AppPlayer? _player;

  /// 播放地址解析超时：URL 一直拿不到时给出提示，避免无限转圈
  Timer? _playerErrorTimer;
  /// 持有 VideoController 实例，与上面 _player 配套使用，跨全屏/普通模式共享，
  /// 保证 ANGLE surface / texture 通道在 OS 全屏切换时不被重建。
  
  String? _lastPlayerUrl;
  String? _lastPlayerHeadersKey;
  /// 是否已排队 post-frame 重建 Player，防止 build 内重复 schedule
  bool _playerRecreateScheduled = false;
  SharedPreferences? _prefs;
  int? _prefsPlayTypeVod;
  Worker? _engineWorker;
  Worker? _decodeWorker;
  Worker? _bufferWorker;
  /// 详情页样式开关（默认/刮削版）变化时重建，无需退出重进
  Worker? _layoutWorker;

  /// MPV 选项变更时热更新当前实例
  void _applyMpvOptions() {
    final p = _player;
    if (p is MpvAppPlayer) {
      p.applyOptions(
        decode: _effectiveDecodeMode,
        buffer: PlayerPrefs.instance.bufferMode.value,
      );
    }
  }

  /// 实际生效的解码模式。
  ///
  /// 「播放器 → 硬件加速」是一个更直观的总开关：关掉它就是软解，
  /// 优先级高于细分的「视频解码（MPV）」。两者取更"软"的那个，
  /// 避免出现"关了硬件加速却还在硬解"的矛盾状态。
  VideoDecodeMode get _effectiveDecodeMode {
    if (!PlayerPrefs.instance.hardwareAccel.value) {
      return VideoDecodeMode.software;
    }
    return PlayerPrefs.instance.decodeMode.value;
  }

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
    // 设置切换内核：立刻换播放器
    _engineWorker = ever(PlayerPrefs.instance.vodEngine, (_) => _onEngineChanged());
    _decodeWorker = ever(PlayerPrefs.instance.decodeMode, (_) => _applyMpvOptions());
    _bufferWorker = ever(PlayerPrefs.instance.bufferMode, (_) => _applyMpvOptions());
    // 「硬件加速」总开关变化时同样热更新
    // 设置页切换「详情页样式」后立即生效（Obx 里只读值不建立依赖，
    // 不监听的话必须退出重进详情页才会换布局）
    _layoutWorker = ever(
      PlayerPrefs.instance.scrapedDetailLayout,
      (_) {
        if (mounted) setState(() {});
      },
    );
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _prefs = prefs;
      await PlayerPrefs.instance.load();
      _prefsPlayTypeVod =
          PlayerPrefs.instance.vodEngine.value.value;
    } catch (e) { /* ignore */ }
  }

  /// 设置里切换内核 → 立刻换播放器（丢弃旧实例重建）
  void _onEngineChanged() {
    if (!mounted) return;
    final e = PlayerPrefs.instance.vodEngine.value;
    _prefsPlayTypeVod = e.value;
    final old = _player;
    _player = null;
    _lastPlayerUrl = '';
    _lastPlayerHeadersKey = '';
    old?.dispose();
    setState(() {});
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

    // 旧版缓存（30 天内写入的）没有 similar/recommendations 字段 —— 直接读缓存
    // 会让「类似作品」永远空着。先探一下缓存是否缺字段，缺则本次强制联网重取，
    // 重新写入完整响应后就不会再走这条路（判定依据是 TMDB 是否返回过该键，
    // 因此本身就无类似作品的条目也不会被反复请求）。
    var forceNetwork = false;
    try {
      final cached = CacheStore.instance.getJsonCache(
        'tmdb:${TmdbService.cacheKey(info.name, '')}',
        ttl: CacheTtl.tmdb,
      );
      if (cached != null && cached.isNotEmpty) {
        forceNetwork = !cached.containsKey('similar');
      }
    } catch (_) {}

    final ok = await tmdb.enrich(info, forceNetwork: forceNetwork);
    if (ok && mounted) {
      setState(() {});
    }
  }

  /// 手动从 TMDB 候选中选择（解决同名剧匹配错）
  Future<void> _showTmdbPickDialog() async {
    final tmdb = TmdbService.instance;
    final info = _controller.vodInfo.value;
    if (info == null) return;
    if (!tmdb.configured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在 设置 → 元数据 填写 TMDB API Key')),
      );
      return;
    }
    final title = TmdbService.cleanTitle(info.name);
    final year = TmdbService.extractYear(info.note, info.year);
    final cands = await tmdb.searchCandidates(title, year);
    if (!mounted) return;
    if (cands.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('TMDB 无匹配结果')),
      );
      return;
    }
    await showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.backgroundPrimary,
      builder: (ctx) => kbSheet(ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text('选择刮削结果',
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ...cands.map((c) {
            final it = c.$2;
            final name = (it['title'] ?? it['name'] ?? '').toString();
            final date = (it['release_date'] ?? it['first_air_date'] ?? '')
                .toString();
            final typeLabel = c.$1 == 'movie' ? '电影' : '剧集';
            return ListTile(
              title: Text(name, style: TextStyle(color: AppTheme.textPrimary)),
              subtitle: Text('$typeLabel · $date',
                  style: TextStyle(color: AppTheme.textTertiary)),
              onTap: () async {
                Navigator.pop(ctx);
                final ok = await tmdb.applyCandidate(info, c.$1, it);
                if (ok && mounted) setState(() {});
              },
            );
          }),
        ],
      )),
    );
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

  /// Spider 源手动换源/选择正确结果：
  /// 用当前片名在当前 Spider 源内重新搜索，列出候选（同名剧/不同年份），
  /// 选中后重新加载详情（修复"Spider 源详情直接取第一个结果、匹配错无法手动选"）
  Future<void> _showSpiderPickDialog() async {
    final info = _controller.vodInfo.value;
    if (info == null) return;
    final spiderInfo = SpiderService.instance.getCurrentSpiderInfo();
    if (spiderInfo.$1.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前源不是 Spider 源，无法搜索候选')),
      );
      return;
    }
    // 用片名在当前源搜索（search 不修改当前 Spider 上下文，只发请求）
    final res = await SpiderService.instance
        .search(spiderInfo.$1, spiderInfo.$2, spiderInfo.$3, info.name);
    if (!mounted) return;
    if (res == null || res['list'] is! List) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('搜索候选失败，请重试')),
      );
      return;
    }
    final List<Video> cands = [];
    for (final e in (res['list'] as List)) {
      if (e is! Map) continue;
      try {
        final v = Video.fromJson(Map<String, dynamic>.from(e));
        // spider 搜索结果通常没有 sourceKey，补上当前源
        cands.add(Video(
          id: v.id,
          name: v.name,
          pic: v.pic,
          note: v.note,
          year: v.year,
          area: v.area,
          director: v.director,
          actor: v.actor,
          des: v.des,
          sourceKey: info.sourceKey,
        ));
      } catch (_) {/* 单条解析失败跳过 */}
    }
    // 排除当前正在看的条目
    cands.removeWhere((v) => v.id == info.id);
    if (cands.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前源没有其他候选结果')),
      );
      return;
    }
    await showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.backgroundPrimary,
      builder: (ctx) => kbSheet(ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Text('选择正确结果',
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text('当前源：${info.name} 的候选（同名剧/不同版本）',
              style: TextStyle(color: AppTheme.textTertiary, fontSize: 12)),
          const SizedBox(height: 4),
          ...cands.map((c) {
            final extra = <String>[
              if (c.year.isNotEmpty) c.year,
              if (c.note.isNotEmpty) c.note,
            ].join(' · ');
            return ListTile(
              title: Text(c.name, style: TextStyle(color: AppTheme.textPrimary)),
              subtitle: extra.isNotEmpty
                  ? Text(extra, style: TextStyle(color: AppTheme.textTertiary))
                  : null,
              onTap: () async {
                Navigator.pop(ctx);
                await _controller.loadDetail(c);
                if (mounted) setState(() {});
                _saveHistoryForCurrentEpisode();
              },
            );
          }),
        ],
      )),
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
    // 退出页先落一次进度，避免暂停中返回丢进度（_persistHistoryIfNeeded 只在播放中写）
    try {
      _persistHistoryIfNeeded(force: true);
    } catch (_) {}
    _engineWorker?.dispose();
    _decodeWorker?.dispose();
    _bufferWorker?.dispose();
    _layoutWorker?.dispose();
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
    _playerErrorTimer?.cancel();
    _playerErrorTimer = null;
    _player?.dispose();
    _player = null;

    // 快搜 tab 的临时资源：输入框控制器 + 独立搜索控制器（含其 Rx 与历史加载）
    _quickSearchInput.dispose();
    try {
      _quickSearch.onClose();
      _quickSearch.dispose();
    } catch (_) {}

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
  /// open/创建一律走 post-frame，避免在 build 里动 native Player。
  ///
  /// 排队中的 open 参数（build 内不直接调 Player.open）
  String _pendingOpenUrl = '';
  Map<String, String> _pendingOpenHeaders = const {};
  Duration? _pendingOpenStart;
  String _pendingOpenHeadersKey = '';

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

    // 记下最新要播的媒体；真正的 open/创建放到 post-frame
    // 不要提前写 _lastPlayerUrl，否则 _playerMatches 会误判「已就绪」
    _pendingOpenUrl = url;
    _pendingOpenHeaders = headers;
    _pendingOpenStart = start;
    _pendingOpenHeadersKey = headersKey;

    if (!_playerRecreateScheduled) {
      _playerRecreateScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _playerRecreateScheduled = false;
        if (!mounted) return;
        final u = _pendingOpenUrl;
        if (u.isEmpty) return;
        _createPlayerAndOpen(
          u,
          _pendingOpenHeaders,
          _pendingOpenHeadersKey,
          _pendingOpenStart,
        );
        setState(() {});
      });
    }
    // 排队中：若目标尚未绑定则视为未就绪（UI 显示 loading）
    return _player != null && _playerMatches(url, headersKey);
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
      _player!.open(AppMedia(url, httpHeaders: headers, start: start));
      return;
    }
    // 按引擎创建：iOS 默认 IosAvPlayer（与小窗共用 AVPlayer）；MPV 备用
    final engine = PlayerPrefs.instance.vodEngine.value;
    if (engine == PlayerEngine.mpv) {
      final mpv = MpvAppPlayer(config: const AppConfig(title: 'TVBox'));
      mpv.applyOptions(
        decode: _effectiveDecodeMode,
        buffer: PlayerPrefs.instance.bufferMode.value,
      );
      _player = mpv;
    } else if (Platform.isIOS) {
      _player = IosAvPlayer(config: const AppConfig(title: 'TVBox'));
    } else {
      _player = AppPlayer(config: const AppConfig(title: 'TVBox'));
    }
    _lastPlayerUrl = url;
    _lastPlayerHeadersKey = headersKey;
    _player!.open(AppMedia(url, httpHeaders: headers, start: start));
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
            // ⚠️ 这里**不能**再放 AppBar（哪怕是空的、透明的）。
            //
            // 原实现有一个 backgroundColor: transparent + leading: SizedBox.shrink()
            // 的"空 AppBar"，配 extendBodyBehindAppBar: true。它看似无害，实则
            // **仍有真实高度（toolbar 56 + 状态栏 insets ≈ 100px）且位于 body 之上**，
            // 于是把播放器顶栏整条盖住、吞掉所有点击 ——
            // 表现为「竖屏点顶栏按钮（听剧/弹幕/画中画/投屏/更多）全部无反应，
            // 横屏正常」（横屏走 immersive 分支，appBar 为 null，所以没事）。
            //
            // 顶栏返回键由播放器自己的 _buildHeaderBar 提供，状态栏高度也由
            // _buildBody 内的 SizedBox 自行预留，所以这个 AppBar 本就多余。
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
          borderColor: AppTheme.glassBorder,
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
              // 「史藏」= 历史 + 收藏（原两项合并）
              _floatingNavItem(
                Icons.schedule_outlined, Icons.schedule, '史藏', 1, current),
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

      // 刮削版详情页（设置页可切换）：海报沉浸式布局，展示 TMDB 演职人员与
      // 类似作品。仅在已刮削出数据时启用，否则回退默认版，避免开开关后一片空白。
      final scrapedReady = info.castList.isNotEmpty ||
          info.similarList.isNotEmpty ||
          info.rating > 0 ||
          info.runtime > 0;
      if (PlayerPrefs.instance.scrapedDetailLayout.value && scrapedReady) {
        return _buildScrapedBody(info, isFull: isFull, isPip: isPip);
      }

      // 悬浮导航栏占位高度: 滚动内容底部少量留白, 让最后一项
      // (选集/简介) 滚动到底时能完全滚出悬浮栏上方 (真悬浮, 非全局预留)
      final mediaPad = MediaQuery.of(context).padding;
      final bottomInset = mediaPad.bottom;
      // 与直播页一致：状态栏高度黑边，状态栏压在黑边上，不与画面重叠
      final topBar = mediaPad.top > 0 ? mediaPad.top : 0.0;
      const navFloatGap = 8.0;
      const navBarHeight = 51.0;
      final navReserve = bottomInset + navFloatGap + navBarHeight + 22.0;

      // 正常模式：视频 + 视频信息 + 选集 + 简介
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 0. 状态栏高度黑边（与直播播放器上方一致）
            if (topBar > 0)
              SizedBox(
                height: topBar,
                child: const ColoredBox(color: Colors.black),
              ),

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

  // MARK: - 刮削版详情页布局

  /// 刮削版详情页：海报沉浸式头图 + 标题/元数据/继续播放 + 操作按钮
  /// + 播放器卡片 + 播放源/清晰度/合集 + 演职人员 + 类似作品。
  ///
  /// 与默认版是两套独立布局，由设置页「详情页样式」开关切换；
  /// 未刮削出数据时 _buildBody 不会走到这里（自动回退默认版）。
  Widget _buildScrapedBody(VodInfo info,
      {required bool isFull, required bool isPip}) {
    final mediaPad = MediaQuery.of(context).padding;
    const navFloatGap = 8.0;
    const navBarHeight = 51.0;
    final navReserve =
        mediaPad.bottom + navFloatGap + navBarHeight + 22.0;

    // 头图：按「海报展示样式」在候选池里挑（固定 / 随机 / 轮播）。
    // 未刮削到多张海报时回落原图，不会显示空白。
    final baseHero = info.pic.trim();
    final heroUrl = baseHero.isEmpty
        ? baseHero
        : TmdbService.instance.pickPoster(info.id, baseHero);
    final year = info.year.trim();
    final typeName = info.typeName.trim();
    final runtime = info.runtime;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ===== 头图区：海报铺满 + 底部渐隐到页面背景 =====
          SizedBox(
            height: 340,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (heroUrl.isNotEmpty)
                  CachedNetworkImage(
                    imageUrl: heroUrl,
                    fit: BoxFit.cover,
                    memCacheWidth: 900,
                    placeholder: (_, __) =>
                        ColoredBox(color: AppTheme.backgroundSecondary),
                    errorWidget: (_, __, ___) =>
                        ColoredBox(color: AppTheme.backgroundSecondary),
                  )
                else
                  ColoredBox(color: AppTheme.backgroundSecondary),
                // 顶部压暗，保证返回按钮可见
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.55),
                        Colors.black.withValues(alpha: 0.15),
                        Colors.black.withValues(alpha: 0.75),
                        AppTheme.backgroundPrimary.withValues(alpha: 0.98),
                      ],
                      stops: const [0.0, 0.30, 0.72, 1.0],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ===== 标题 + 元数据 + 继续播放（上移覆盖头图底部，形成融入感）=====
          Transform.translate(
            offset: const Offset(0, -26),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  info.name,
                  textAlign: TextAlign.center,
                  // 视频名称**只允许一行**，超长省略（不允许跨行）
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontTitle2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: AppTheme.spacingSM),
                // 元数据行：年份 · 类型 · 时长（能力范围内尽量还原参考图）
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: AppTheme.spacingSM,
                  runSpacing: AppTheme.spacingXS,
                  children: [
                    if (year.isNotEmpty) MetadataPill(text: year),
                    if (typeName.isNotEmpty) MetadataPill(text: typeName),
                    if (runtime > 0) MetadataPill(text: '$runtime 分钟'),
                    if (info.rating > 0)
                      MetadataPill(text: 'TMDB ${info.rating.toStringAsFixed(1)}'),
                  ],
                ),
                const SizedBox(height: AppTheme.spacingMD),
                // 继续播放按钮
                if (_controller.playUrl.value != null) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppTheme.spacingLG),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppTheme.backgroundSecondary,
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusMD),
                      ),
                      child: Padding(
                        padding:
                            const EdgeInsets.symmetric(vertical: 12),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.play_arrow,
                                color: AppTheme.textPrimary, size: 22),
                            const SizedBox(width: 6),
                            Text(
                              '继续播放',
                              style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: AppTheme.fontSubhead,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppTheme.spacingMD),
                ],
                // 操作按钮行：重刮削 / 快搜 / 收藏 / 更多
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _scrapedActionButton(
                      icon: Icons.search,
                      label: '快搜',
                      // 跳到全局搜索页（默认版里是「快搜」tab，刮削版没有 tab 栏）
                      onTap: () => Get.toNamed('/search', arguments: info.name),
                    ),
                    const SizedBox(width: AppTheme.spacingXL),
                    _scrapedActionButton(
                      icon: Icons.auto_awesome,
                      label: '刮削',
                      onTap: _showTmdbPickDialog,
                    ),
                    const SizedBox(width: AppTheme.spacingXL),
                    _scrapedFavoriteButton(info),
                    const SizedBox(width: AppTheme.spacingXL),
                    _scrapedActionButton(
                      icon: Icons.more_horiz,
                      label: '更多',
                      onTap: _showScrapedMoreSheet,
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ===== 播放器卡片 =====
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.spacingLG),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppTheme.radiusMD),
              child: _buildPlayerWidget(isFull: isFull, isPip: isPip),
            ),
          ),

          // ===== 播放源 / 清晰度 / 合集 =====
          _buildPlaybackCard(),

          // ===== 演职人员 =====
          _buildCastSection(info),

          // ===== 类似作品 =====
          _buildSimilarSection(info),

          // ===== 简介 =====
          if (info.des.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppTheme.spacingLG, AppTheme.spacingMD, AppTheme.spacingLG, 0),
              child: AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionHeader(title: '简介', icon: Icons.notes),
                    const SizedBox(height: AppTheme.spacingSM),
                    Text(
                      info.des,
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: AppTheme.fontCaption,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          SizedBox(height: navReserve),
        ],
      ),
    );
  }

  /// 刮削版圆形操作按钮（图标 + 文字）
  Widget _scrapedActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppTheme.backgroundTertiary,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: AppTheme.textSecondary, size: 20),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              color: AppTheme.textTertiary,
              fontSize: AppTheme.fontFootnote,
            ),
          ),
        ],
      ),
    );
  }

  /// 刮削版收藏按钮（图标随收藏态变化）
  Widget _scrapedFavoriteButton(VodInfo info) {
    return Obx(() {
      final isCollected =
          CacheStore.instance.isCollected(info.id, info.sourceKey);
      return _scrapedActionButton(
        icon: isCollected ? Icons.favorite : Icons.favorite_border,
        label: isCollected ? '已收藏' : '收藏',
        onTap: () async {
          if (isCollected) {
            await CacheStore.instance.removeCollect(info.id, info.sourceKey);
          } else {
            await CacheStore.instance.addCollect(info.toVideo());
          }
        },
      );
    });
  }

  /// 刮削版「更多」：把默认版里的推荐/快搜入口收纳进底部弹窗
  void _showScrapedMoreSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => kbSheet(SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.recommend_outlined,
                  color: AppTheme.textSecondary),
              title: Text('相似推荐',
                  style: TextStyle(color: AppTheme.textPrimary)),
              onTap: () {
                Navigator.pop(ctx);
                _controller.loadRecommended();
                _controller.detailTabIndex.value = 1;
              },
            ),
            ListTile(
              leading: Icon(Icons.tune,
                  color: AppTheme.textSecondary),
              title: Text('切换到默认详情页',
                  style: TextStyle(color: AppTheme.textPrimary)),
              onTap: () async {
                Navigator.pop(ctx);
                await PlayerPrefs.instance.setScrapedDetailLayout(false);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      )),
    );
  }

  // MARK: - 播放器

  /// 播放器区域 - 始终在 tree 中同一位置，避免 VideoPlayerWidget 被重建
  /// 16:9 容器内放视频；如果父容器充满（immersive 模式），则视频也充满父容器
  /// 全屏切换由 detail view 自己管理的 Overlay + EnterNativeFullscreen/ExitNativeFullscreen
  /// 通道处理（见 _enterFullScreenRoute / _exitFullScreenRoute）。
  /// PiP 互斥由 widget 内部的 _togglePiP / _onUserToggleFullscreen 处理。

  Widget _buildPlayerArea() {
    // 关键：相关 Rx 都在 Obx 内读取，选集/换源/全屏才能触发 rebuild
    return Obx(() {
      final isFull = _controller.isFullScreen.value;
      final isPip = VideoPlayerPip.instance.activeNotifier.value;
      final url = _controller.playUrl.value;
      // 选集变化也要重建（角标/标题/切集参数）
      final _ = _controller.selectedEpisodeIndex.value;
      final __ = _controller.playbackSessionId.value;
      final ___ = _controller.selectedFlag.value;
      if (url != null && url.isNotEmpty) {
        _playerErrorTimer?.cancel();
        _playerErrorTimer = null;
        return _buildPlayerWidget(isFull: isFull, isPip: isPip);
      } else if (_controller.errorMessage.value != null) {
        // 解析失败（Spider 地址解析失败 / 上下文缺失等）：必须给出可见提示，
        // 旧逻辑在这里只渲染转圈 → 用户看到无限 loading，既无文案也无重试入口。
        _playerErrorTimer?.cancel();
        _playerErrorTimer = null;
        return AspectRatio(
          aspectRatio: 4 / 3,
          child: Container(
            color: Colors.black,
            child: AppError(
              message: _controller.errorMessage.value!,
              onRetry: () => _controller.retryCurrentEpisode(),
            ),
          ),
        );
      } else {
        // 正在播放但 URL 尚未就绪：超时后置错误，避免永久转圈
        _playerErrorTimer ??= Timer(const Duration(seconds: 15), () {
          _playerErrorTimer = null;
          if (!mounted) return;
          if ((_controller.playUrl.value ?? '').isEmpty) {
            _controller.setPlaybackError('播放地址获取超时，请点重试或切换其他线路');
          }
        });
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
  /// 播放器（4:3 容器）在当前屏宽下的实际高度，用作播放设置弹窗的高度上限。
  ///
  /// 需求：设置面板不能超出播放器底部、盖住下方「简介/推荐/快搜」tab 栏。
  /// 弹窗从屏幕底部弹出，只能靠限高让它"止步"在播放器范围内。
  ///
  /// 下限 220 是给横屏/小屏兜底（否则面板太矮没法操作）。
  double _playerSheetMaxHeight(BuildContext context) {
    final size = MediaQuery.of(context).size;
    // 与 _buildPlayerArea 的左右 padding 一致（spacingLG × 2）
    final width = size.width - AppTheme.spacingLG * 2;
    final h = width * 3 / 4; // aspectRatio: 4/3
    return h.clamp(220.0, 560.0);
  }

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

    // 播放内核：AVPlayer 为主，MPV 备用，Webview 管网页播放页。
    final engine = PlayerPrefs.instance.vodEngine.value;
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
    if (!playerReady || _player == null || _player == null) {
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
       // 跨全屏/普通模式共享同一个 controller
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
      topBarTopPadding: 8.0,
      // 播放设置弹窗限高到播放器高度，避免盖住下方 tab 栏
      sheetMaxHeight: _playerSheetMaxHeight(context),
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
      onEnded: () {
        // AVPlayer 内核可关「自动下一集」；手动点下一集不受限
        if (PlayerPrefs.instance.vodEngine.value == PlayerEngine.avplayer &&
            !PlayerPrefs.instance.avAutoNext.value) {
          return;
        }
        _playNextEpisode();
      },
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
      // 播放器错误（原生 onError / 加载失败）以前无处可去，只表现为白转圈；
      // 这里接进控制器的错误态，详情页即可显示文案 + 重试。
      onError: () => _controller.setPlaybackError('播放失败，请点重试或切换其他线路'),
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
        // 刮削中提示
        Obx(() {
          if (!TmdbService.instance.isWorking.value) {
            return const SizedBox.shrink();
          }
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            // 整行居中（原来 Row 默认左对齐，跟 tab 栏不对齐显得歪）
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text('正在刮削元数据…',
                    style: TextStyle(
                        color: AppTheme.textTertiary, fontSize: 12)),
              ],
            ),
          );
        }),
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
                  // 演职人员 / 类似作品只在「刮削版详情页」展示
                  // （设置 → 详情页样式），避免两套布局内容重复。
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
                  } else if (index == 2) {
                    // 快搜：切进来就自动用片名跑一次多源搜索
                    _runQuickSearch(_controller.vodInfo.value?.name ?? '');
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
                    // Spider 源：手动换源/选择正确结果（同名剧匹配错时）
                    Obx(() {
                      if (!_controller.isSpiderSource) {
                        return const SizedBox.shrink();
                      }
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _showSpiderPickDialog,
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
                          child: const Icon(Icons.swap_horiz,
                              size: 18, color: AppTheme.accentColor),
                        ),
                      );
                    }),
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

  // MARK: - TMDB 刮削增强区（演职人员 / 类似作品）

  /// 演职人员区：横向头像卡（头像 + 演员名 + 角色名）
  ///
  /// 数据来自 TMDB credits（含 profile_path / character），未刮削时 castList
  /// 为空则整段隐藏，不影响原有布局。
  Widget _buildCastSection(VodInfo info) {
    if (info.castList.isEmpty) return const SizedBox.shrink();
    final tmdb = TmdbService.instance;
    return Obx(() {
      if (!tmdb.showCast.value) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.fromLTRB(
            AppTheme.spacingLG, AppTheme.spacingMD, 0, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: AppTheme.spacingLG),
              child: const SectionHeader(
                  title: '演职人员', icon: Icons.people_alt_outlined),
            ),
            const SizedBox(height: AppTheme.spacingSM),
            SizedBox(
              height: 148,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(right: AppTheme.spacingLG),
                itemCount: info.castList.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(width: AppTheme.spacingMD),
                itemBuilder: (context, index) =>
                    _CastMemberCard(member: info.castList[index]),
              ),
            ),
          ],
        ),
      );
    });
  }

  /// 类似作品区：横向海报卡（海报 + 评分角标 + 年份 + 片名）
  ///
  /// 点击后用当前源的 key + TMDB 片名跳详情（与「推荐」tab 同策略），
  /// 由详情页在当前源里再搜一次 —— 只有能搜到的条目才真正可播。
  Widget _buildSimilarSection(VodInfo info) {
    if (info.similarList.isEmpty) return const SizedBox.shrink();
    final tmdb = TmdbService.instance;
    return Obx(() {
      if (!tmdb.showSimilar.value) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.fromLTRB(
            AppTheme.spacingLG, AppTheme.spacingMD, 0, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: AppTheme.spacingLG),
              child: const SectionHeader(
                  title: '类似作品', icon: Icons.local_movies_outlined),
            ),
            const SizedBox(height: AppTheme.spacingSM),
            SizedBox(
              height: 208,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(right: AppTheme.spacingLG),
                itemCount: info.similarList.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(width: AppTheme.spacingMD),
                itemBuilder: (context, index) => _SimilarCard(
                  item: info.similarList[index],
                  onTap: () {
                    final item = info.similarList[index];
                    Get.toNamed(
                      '/detail',
                      arguments: Video(
                        id: item.id,
                        name: item.title,
                        pic: item.posterUrl,
                        year: item.year,
                        sourceKey: info.sourceKey,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      );
    });
  }

  /// 推荐 tab - 同类型影片网格
  ///
  /// 加载中若有旧结果（每次切 tab 都会重新拉），继续显示旧结果 + 顶部细进度条，
  /// 而不是整块换成转圈 —— 否则每次切回来都闪一下白，体验比"稍旧"更差。
  Widget _buildRecommendTab() {
    return Obx(() {
      final items = _controller.recommended;
      final loading = _controller.isRecommendLoading.value;

      if (items.isEmpty) {
        if (loading) {
          return const SizedBox(
            height: 200,
            child: Center(child: AppLoading(message: '加载推荐中...')),
          );
        }
        return const SizedBox(
          height: 120,
          child: Center(child: AppError(message: '暂无推荐')),
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (loading)
            SizedBox(
              height: 2,
              child: LinearProgressIndicator(
                minHeight: 2,
                backgroundColor: Colors.transparent,
                color: AppTheme.accentColor,
              ),
            ),
          // ⚠️ 网格高度必须与 VodCard 内部一致：
          //   卡片真实高 = 宽 × posterHeightRatio(0.72) + 文字区(~30)
          // 原来写 childAspectRatio: 0.62（等于高 = 宽 / 0.62 = 宽 × 1.61），
          // 比卡片实际需要的（宽 × 0.72 + 30）高出一大截 → 推荐卡片被拉长、
          // 封面区域比例失真（你截图里看到的就是这个）。
          LayoutBuilder(
            builder: (context, constraints) {
              const cols = 3;
              final cardW = (constraints.maxWidth -
                      AppTheme.spacingLG * 2 -
                      AppTheme.cardSpacing * (cols - 1)) /
                  cols;
              final ratio = cardW / (cardW * 0.72 + 30);
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.spacingLG, vertical: 6),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  childAspectRatio: ratio,
                  mainAxisSpacing: AppTheme.cardSpacing,
                  crossAxisSpacing: AppTheme.cardSpacing,
                ),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final video = items[index];
                  return VodCard(
                    video: video,
                    // 与上面的 ratio 配套
                    posterHeightRatio: 0.72,
                    onTap: () => Get.toNamed('/detail', arguments: video),
                  );
                },
              );
            },
          ),
        ],
      );
    });
  }

  /// 快搜 tab —— 直接展示多源搜索结果（不再只是"关键词 chip 跳搜索页"）。
  ///
  /// 交互对齐搜索页参考图：
  ///   输入框（可改词）→ 横向源芯片（源名 + 命中条数）→ 当前源的结果网格。
  /// 数据来自本页独立的 [_quickSearch] 控制器，与搜索页互不干扰。
  Widget _buildQuickSearchTab() {
    final info = _controller.vodInfo.value;
    // 建议关键词：片名 / 演员 / 类型 —— 点一下就用它重搜
    final suggest = <String>[
      if (info != null && info.name.isNotEmpty) info.name,
      if (info != null && info.actor.isNotEmpty)
        ...info.actor.split(',').map((a) => a.trim()).where((a) => a.isNotEmpty).take(3),
      if (info != null && info.typeName.isNotEmpty) info.typeName,
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacingLG),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---------- 搜索输入框 ----------
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _quickSearchInput,
                  style: TextStyle(
                      color: AppTheme.textPrimary, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: '搜索影片',
                    hintStyle: TextStyle(
                        color: AppTheme.textTertiary, fontSize: 13),
                    prefixIcon: Icon(Icons.search,
                        size: 18, color: AppTheme.textTertiary),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.06),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (v) => _runQuickSearch(v, force: true),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () =>
                    _runQuickSearch(_quickSearchInput.text, force: true),
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: AppTheme.accentColor,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.search,
                      size: 20, color: Colors.white),
                ),
              ),
            ],
          ),

          // ---------- 建议关键词 ----------
          if (suggest.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: AppTheme.spacingSM,
              runSpacing: AppTheme.spacingSM,
              children: suggest
                  .map((k) => SelectableChip(
                        title: k,
                        isSelected: _quickSearchDoneFor == k,
                        onTap: () {
                          _quickSearchInput.text = k;
                          _runQuickSearch(k, force: true);
                        },
                      ))
                  .toList(),
            ),
          ],

          const SizedBox(height: 12),

          // ---------- 源芯片 + 结果 ----------
          Obx(() {
            final sites = _quickSearch.activeSites;
            final selectedKey = _quickSearch.selectedSiteKey.value;
            final searching = _quickSearch.isSearching.value;

            if (sites.isEmpty) {
              return SizedBox(
                height: 140,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (searching)
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: AppTheme.accentColor),
                          )
                        else
                          Icon(Icons.search_off,
                              size: 26, color: AppTheme.textTertiary),
                        const SizedBox(height: 10),
                        // 原来这里恒显示「搜索中...」：没有可用搜索源时也转圈，
                        // 看着像卡死。分三种情况给明确提示。
                        Text(
                          searching
                              ? '正在准备搜索源…'
                              : '没有可用的搜索源\n请在 设置 → 订阅与数据源 检查接口是否加载成功',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: AppTheme.textTertiary,
                              fontSize: 13,
                              height: 1.5),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }

            final results = selectedKey == null
                ? <Video>[]
                : (_quickSearch.resultsBySite[selectedKey] ?? <Video>[]);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 源芯片（带命中条数）
                SizedBox(
                  height: 40,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      if (searching)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Center(
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 1.5,
                                      color: AppTheme.accentColor),
                                ),
                                const SizedBox(width: 6),
                                Text('搜索中',
                                    style: TextStyle(
                                        color: AppTheme.textTertiary,
                                        fontSize: 12)),
                              ],
                            ),
                          ),
                        ),
                      ...sites.map((site) {
                        final sel = selectedKey == site.key;
                        final count =
                            _quickSearch.resultCount[site.key] ?? 0;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _quickSearch.selectSite(site.key),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 7),
                              decoration: BoxDecoration(
                                color: sel
                                    ? AppTheme.accentColor
                                        .withValues(alpha: 0.22)
                                    : Colors.white.withValues(alpha: 0.06),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: sel
                                      ? AppTheme.accentColor
                                          .withValues(alpha: 0.55)
                                      : Colors.white24,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    site.name,
                                    style: TextStyle(
                                      color: sel
                                          ? AppTheme.textPrimary
                                          : AppTheme.textSecondary,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                  if (count > 0) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: AppTheme.accentColor
                                            .withValues(alpha: 0.20),
                                        borderRadius:
                                            BorderRadius.circular(9),
                                      ),
                                      child: Text(
                                        '$count',
                                        style: TextStyle(
                                          color: AppTheme.accentColor,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                    ],
                  ),
                ),

                const SizedBox(height: 8),

                if (results.isEmpty)
                  SizedBox(
                    height: 120,
                    child: Center(
                      child: Text(
                        searching
                            ? '正在搜索各源...'
                            : (_quickSearchDoneFor == null
                                ? '输入关键词开始搜索'
                                : '该源没有相关结果'),
                        style: TextStyle(
                            color: AppTheme.textTertiary, fontSize: 13),
                      ),
                    ),
                  )
                else
                  LayoutBuilder(
                    builder: (context, constraints) {
                      // 与推荐区同一套算法：网格高度必须跟 VodCard 配套
                      // （卡片高 = 宽 × 0.72 + 文字区），否则卡片被拉长、封面失真。
                      const cols = 3;
                      final cardW = (constraints.maxWidth -
                              AppTheme.spacingLG * 2 -
                              AppTheme.cardSpacing * (cols - 1)) /
                          cols;
                      final ratio = cardW / (cardW * 0.72 + 30);
                      return GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: cols,
                          childAspectRatio: ratio,
                          mainAxisSpacing: AppTheme.cardSpacing,
                          crossAxisSpacing: AppTheme.cardSpacing,
                        ),
                        itemCount: results.length,
                        itemBuilder: (context, i) {
                          final v = results[i];
                          return VodCard(
                            video: v,
                            posterHeightRatio: 0.72,
                            onTap: () =>
                                Get.toNamed('/detail', arguments: v),
                          );
                        },
                      );
                    },
                  ),
              ],
            );
          }),
        ],
      ),
    );
  }

  /// 跑一次快搜。
  ///
  /// [force] = false 时，同一关键词只搜一次（切 tab 回来不重复打网络）。
  Future<void> _runQuickSearch(String rawKeyword, {bool force = false}) async {
    final kw = rawKeyword.trim();
    if (kw.isEmpty) return;
    if (!force && _quickSearchDoneFor == kw) return;
    _quickSearchDoneFor = kw;
    if (_quickSearchInput.text != kw) _quickSearchInput.text = kw;
    _quickSearch.keyword.value = kw;
    await _quickSearch.search();
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

  // MARK: - 播放线路 / 清晰度 / 选集（统一在 _buildPlaybackCard 内渲染）

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
            // 清晰度：三段式卡片之前把 hasQuality 算出来了却没渲染，
            // 导致 qualityOptions（HLS master 解析出的多档码率）用户完全点不到。
            if (hasQuality) ...[
              const SizedBox(height: AppTheme.spacingMD),
              Divider(height: 1, color: AppTheme.borderLight),
              const SizedBox(height: AppTheme.spacingMD),
              const SectionHeader(title: '清晰度', icon: Icons.auto_awesome),
              const SizedBox(height: AppTheme.spacingSM),
              Obx(() => SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: _controller.qualityOptions.map((option) {
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
    // force（退出页）时即便暂停也要写，否则暂停返回会丢进度
    if (!force && !_controller.isPlaying.value) return;
    final progress = (currentProgress ?? _controller.currentPlaybackSeconds()).clamp(0.0, double.infinity).toDouble();
    if (!progress.isFinite) return;

    if (!force && (progress - _lastPersistedProgress).abs() < 5) {
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

/// 演职人员卡片（头像 + 演员名 + 角色名）
class _CastMemberCard extends StatelessWidget {
  final VodCastMember member;

  const _CastMemberCard({required this.member});

  @override
  Widget build(BuildContext context) {
    final url = member.avatarUrl;
    return SizedBox(
      width: 76,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ClipOval(
            child: SizedBox(
              width: 68,
              height: 68,
              child: url.isEmpty
                  ? _avatarPlaceholder()
                  : CachedNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.cover,
                      memCacheWidth: 160,
                      placeholder: (_, __) => _avatarPlaceholder(),
                      errorWidget: (_, __, ___) => _avatarPlaceholder(),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            member.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontCaption,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (member.character.isNotEmpty)
            Text(
              member.character,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontFootnote,
              ),
            ),
        ],
      ),
    );
  }

  /// 无头像时的首字占位
  Widget _avatarPlaceholder() {
    return ColoredBox(
      color: AppTheme.backgroundTertiary,
      child: Center(
        child: Text(
          member.name.isNotEmpty ? member.name.characters.first : '?',
          style: TextStyle(
            color: AppTheme.textTertiary,
            fontSize: AppTheme.fontHeadline,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// 类似作品卡片（海报 + 评分角标 + 年份 + 片名）
class _SimilarCard extends StatelessWidget {
  final VodSimilarItem item;
  final VoidCallback onTap;

  const _SimilarCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final poster = item.posterUrl;
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 112,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppTheme.radiusMD),
              child: SizedBox(
                height: 160,
                width: 112,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 注意：AppTheme.backgroundTertiary 是 getter（跟随明暗主题），
                    // 不是编译期常量，因此这里不能用 const ColoredBox。
                    poster.isEmpty
                        ? ColoredBox(color: AppTheme.backgroundTertiary)
                        : CachedNetworkImage(
                            imageUrl: poster,
                            fit: BoxFit.cover,
                            memCacheWidth: 224,
                            placeholder: (_, __) =>
                                ColoredBox(color: AppTheme.backgroundTertiary),
                            errorWidget: (_, __, ___) =>
                                ColoredBox(color: AppTheme.backgroundTertiary),
                          ),
                    // 评分角标（右上）
                    if (item.hasRating)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.62),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Text(
                            item.voteAverage.toStringAsFixed(1),
                            style: const TextStyle(
                              color: Color(0xFFFFC107),
                              fontSize: AppTheme.fontFootnote,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontCaption,
              ),
            ),
            if (item.year.isNotEmpty)
              Text(
                item.year,
                style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontFootnote,
                ),
              ),
          ],
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