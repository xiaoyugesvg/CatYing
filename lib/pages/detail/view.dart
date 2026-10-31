import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:tvbox/services/live_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox/common/theme.dart';
import 'package:tvbox/common/system_ui.dart';
import 'package:tvbox/models/movie.dart';
import 'package:tvbox/models/vod_info.dart';
import 'package:tvbox/models/player_engine.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/services/spider_service.dart';
import 'package:tvbox/widgets/vod_card.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:tvbox/models/cache_store.dart';
import 'package:tvbox/models/cache_ttl.dart';
import 'package:tvbox/services/tmdb_service.dart';
import 'package:tvbox/services/detail_page_controller.dart';
import 'package:tvbox/services/player_fullscreen_controller.dart';
import 'package:tvbox/services/player_prefs.dart';
import 'package:tvbox/services/play_pipeline.dart' show kMovieWebUrlRejected;
import 'package:tvbox/widgets/playback_surface.dart';
import 'package:tvbox/widgets/common_widgets.dart';
import 'package:tvbox/widgets/app_player.dart';
import 'package:tvbox/widgets/ios_av_player.dart';
import 'package:tvbox/widgets/aether_player.dart';
import 'package:tvbox/widgets/mpv_app_player.dart';
import 'package:tvbox/widgets/video_player.dart';
import 'package:tvbox/widgets/video_player_pip.dart';
import 'package:tvbox/widgets/window_fullscreen.dart';
import 'package:tvbox/pages/drama/drama_player_page.dart';
import 'package:tvbox/pages/search/controller.dart' show TvSearchController;
import 'package:tvbox/pages/detail/controller.dart';
import 'package:tvbox/pages/detail/episode_list.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/widgets/parse_line_sheet.dart';
import 'package:tvbox/services/parse_lines.dart';
import 'package:tvbox/webhome/webhtv_playback_sync_service.dart';

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

  /// 当前 _player 实例是按哪个内核创建的。
  ///
  /// 用于让 ever(vodEngine) 与播放器内菜单的热切换**互斥**：
  /// 菜单热切换已按新内核重建并同步本字段，ever 回调随后触发时
  /// 发现内核一致直接跳过 —— 否则会把刚建好的新实例立刻 dispose，
  /// 再从过期续播位重建一次（表现为"切换不灵/跳进度/黑屏闪一下"）。
  PlayerEngine? _playerEngine;

  /// 热切换互斥标记。
  ///
  /// 「播放器内菜单」和「PlayerPrefs.vodEngine 的 ever 监听」是**两条并行
  /// 触发路径**：菜单里 `setEngine()` 会先改 Rx，ever 随即回调，而菜单自己
  /// 也会再调一次 `_onEngineHotSwap` ⇒ 两份热切换同时跑，各自 dispose/重建，
  /// 最后留下一个没挂视频层的孤儿实例（表现：切换没变化、只有声音没画面）。
  bool _engineSwapInFlight = false;

  /// 「正在切换内核」：期间播放器区域只渲染"加载中"空壳。
  ///
  /// iOS 上 AVPlayer 的画面是 `UiKitView`（原生视图），mpv / AetherPlayer 是
  /// Flutter `Texture`；原生视图的移除是异步的，同一帧里换掉会出现
  /// 「有声音没画面」。这个标记让 build 先不挂任何画面，等原生视图退场
  /// （见 `_waitPlatformViewDetach`）再创建新内核。
  bool _engineSwapping = false;

  /// 用户已选的字幕（跨内核热切换接力）。
  /// 各内核的字幕轨 id 不同，切换时按语言的 matchKey 把同一条字幕找回。
  SubtitleChoice? _subtitleChoice;

  /// 是否已排队 post-frame 重建 Player，防止 build 内重复 schedule
  bool _playerRecreateScheduled = false;
  Worker? _engineWorker;
  Worker? _decodeWorker;
  Worker? _bufferWorker;

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
      // 沉浸 + 视频黑底 → 浅色状态栏图标。
      // ⚠️ 方向**不传**：详情页全屏的方向由 `widgets/video_player.dart`
      // 自己管，这里传了会互相覆盖（V10）。
      SystemUiController.enter(
        'detail',
        mode: SystemUiMode.immersive,
        overlayStyle: SystemUiOverlayStyle.light,
      );
    } else {
      PlayerFullscreenController.instance.exit('detail');
      // 恢复**进入前**的系统栏状态，而不是写死 edgeToEdge
      SystemUiController.exit('detail');
    }
  }

  @override
  void initState() {
    super.initState();
    // 告诉全局底栏"详情页开了" —— 底栏是在 app.dart 全局渲染的，
    // 详情页要隐藏它只能通过这个响应式标志（详见 DetailPageController 注释）。
    // ⚠️ 用引用计数：详情页里还能再进详情页（点另一个视频），
    // 用 bool 的话内层 dispose 会提前把标志清掉，外层还在前台底栏就冒出来了。
    if (Get.isRegistered<DetailPageController>()) {
      DetailPageController.instance.enter();
    } else {
      Get.put(DetailPageController()).enter();
    }
    // 打开点播时停掉直播，避免双路声音
    LiveService.pauseLivePlayer?.call();
    _loadPrefs();
    _loadDetailIfNeeded();
    // 监听 PiP 状态变化，确保退出 PiP 时退出全屏（互斥）
    VideoPlayerPip.instance.activeNotifier.addListener(_onPipChanged);
    // 监听 WindowFullScreen 状态变化：作为冗余同步通道，
    // 保证 WindowFullScreen.toggle 后 isFullScreen Rx 一定被同步
    WindowFullScreen.instance.activeNotifier.addListener(
      _onFullScreenActiveChanged,
    );
    // 设置切换内核：立刻换播放器
    _engineWorker = ever(
      PlayerPrefs.instance.vodEngine,
      (_) => _onEngineChanged(),
    );
    _decodeWorker = ever(
      PlayerPrefs.instance.decodeMode,
      (_) => _applyMpvOptions(),
    );
    _bufferWorker = ever(
      PlayerPrefs.instance.bufferMode,
      (_) => _applyMpvOptions(),
    );
    // 媒体库布局已移除：无需监听「详情页样式」切换
  }

  Future<void> _loadPrefs() async {
    try {
      await SharedPreferences.getInstance();
      await PlayerPrefs.instance.load();
    } catch (e) {
      /* ignore */
    }
  }

  /// 设置里切换内核 → 立刻换播放器（与播放器内菜单共用热切换路径）。
  ///
  /// 与热切换互斥：_playerEngine 已是目标内核说明播放器内菜单刚重建过，
  /// 本回调（ever 异步触发）直接跳过，避免把新实例又 dispose 重建一次。
  ///
  /// ⚠️ 2026-10-19：必须 await dispose，否则旧引擎未死透就重建会导致
  ///   「黑屏但有声音」（与 _onEngineHotSwap 同一问题）。
  void _onEngineChanged() {
    if (!mounted) return;
    final engine = PlayerPrefs.instance.vodEngine.value;
    // 已经有一次热切换在跑（多半就是菜单那条路径触发的）→ 不再叠加
    if (_engineSwapInFlight) return;
    if (_player != null && _playerEngine == engine) return;
    _onEngineHotSwap(engine);
  }

  void _loadDetailIfNeeded() {
    final video = Get.arguments;
    if (video != null && video is Video) {
      _controller.loadDetail(video).then((_) {
        // 有历史则恢复续播；无历史则直接自动播放当前选集第一集。
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

  /// TMDB 智能刮削：配置了 Key 且开启自动时，补全海报/简介/演职员。
  ///
  /// TMDB 智能刮削：配置了 Key 且开启自动时，补全海报/简介/演职员。
  Future<void> _enrichFromTmdb() async {
    final tmdb = TmdbService.instance;
    if (!tmdb.configured) return;
    final info = _controller.vodInfo.value;
    if (info == null) return;
    // 受「自动刮削」开关控制
    if (!tmdb.autoScrape.value) return;

    // 旧版缓存（30 天内写入的）没有 similar/recommendations 字段 —— 直接读缓存
    // 会让「类似作品」永远空着。先探一下缓存是否缺字段，缺则本次强制联网重取，
    // 重新写入完整响应后就不会再走这条路（判定依据是 TMDB 是否返回过该键，
    // 因此本身就无类似作品的条目也不会被反复请求）。
    var forceNetwork = false;
    try {
      final cached = CacheStore.instance.getJsonCache(
        // ⚠️ 这里的 key **必须与 `TmdbService.enrich` 写入时用的 key 一致**
        //（`tmdb_service.dart` 里是 `cacheKey(info.name, year)`）。
        // 原来传的是**空年份** → 有年份的作品永远读不到缓存 → 下面
        // `forceNetwork = !cached.containsKey('similar')` 这个"旧缓存缺字段就
        // 强制联网重取"的探测**永不生效**（类似作品可能一直空着）。
        'tmdb:${TmdbService.cacheKey(
          info.name,
          TmdbService.extractYear(info.note, info.year)?.toString() ?? '',
        )}',
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
  ///
  /// 暂未接入入口（详情页当前用自动刮削）；保留实现供后续挂到更多菜单。
  // ignore: unused_element
  Future<void> _showTmdbPickDialog() async {
    final tmdb = TmdbService.instance;
    final info = _controller.vodInfo.value;
    if (info == null) return;
    if (!tmdb.configured) {
      AppToast.message('请先在 设置 → 元数据 填写 TMDB API Key');
      return;
    }
    final title = TmdbService.cleanTitle(info.name);
    final year = TmdbService.extractYear(info.note, info.year);
    final cands = await tmdb.searchCandidates(title, year);
    if (!mounted) return;
    if (cands.isEmpty) {
      AppToast.message('TMDB 无匹配结果');
      return;
    }
    await showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SheetGrabber(),
            _SheetHeader(
              title: '选择刮削结果',
              subtitle: '选中的条目会覆盖当前海报/简介/演职员',
              trailing: '${cands.length} 个',
            ),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.5,
              ),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                itemCount: cands.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (c, i) {
                  final it = cands[i].$2;
                  final name = (it['title'] ?? it['name'] ?? '').toString();
                  final date =
                      (it['release_date'] ?? it['first_air_date'] ?? '')
                          .toString();
                  final typeLabel = cands[i].$1 == 'movie' ? '电影' : '剧集';
                  return _SheetOptionTile(
                    title: name,
                    subtitle: '$typeLabel · $date',
                    onTap: () async {
                      Navigator.pop(ctx);
                      await tmdb.applyCandidate(info, cands[i].$1, it);
                      if (!mounted) return;
                      setState(() {});
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
  }

  /// 手动点击刮削（无视自动开关，仍需配置 Key）
  Future<void> _manualScrapeFromTmdb() async {
    final tmdb = TmdbService.instance;
    if (!tmdb.configured) {
      AppToast.message('请先在 设置 → 元数据 填写 TMDB API Key');
      return;
    }
    final info = _controller.vodInfo.value;
    if (info == null) return;
    AppToast.message('正在刮削 TMDB 元数据...');
    final ok = await tmdb.enrich(info);
    if (!mounted) return;
    setState(() {});
    AppToast.message(ok ? '刮削完成，已更新海报/简介/演职员' : '未匹配到 TMDB 条目');
  }

  /// Spider 源手动换源/选择正确结果：
  /// 用当前片名在当前 Spider 源内重新搜索，列出候选（同名剧/不同年份），
  /// 选中后重新加载详情（修复"Spider 源详情直接取第一个结果、匹配错无法手动选"）
  Future<void> _showSpiderPickDialog() async {
    final info = _controller.vodInfo.value;
    if (info == null) return;
    final spiderInfo = SpiderService.instance.getCurrentSpiderInfo();
    if (spiderInfo.key.isEmpty) {
      AppToast.message('当前源不是 Spider 源，无法搜索候选');
      return;
    }
    // 用片名在当前源搜索（search 不修改当前 Spider 上下文，只发请求）
    final res = await SpiderService.instance.search(
      spiderInfo.key,
      spiderInfo.type,
      spiderInfo.api,
      info.name,
      ext: spiderInfo.ext,
    );
    if (!mounted) return;
    if (res == null || res['list'] is! List) {
      AppToast.message('搜索候选失败，请重试');
      return;
    }
    final List<Video> cands = [];
    for (final e in (res['list'] as List)) {
      if (e is! Map) continue;
      try {
        final v = Video.fromJson(Map<String, dynamic>.from(e));
        // spider 搜索结果通常没有 sourceKey，补上当前源
        cands.add(
          Video(
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
          ),
        );
      } catch (_) {
        /* 单条解析失败跳过 */
      }
    }
    // 排除当前正在看的条目
    cands.removeWhere((v) => v.id == info.id);
    if (cands.isEmpty) {
      AppToast.message('当前源没有其他候选结果');
      return;
    }
    await showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SheetGrabber(),
            _SheetHeader(
              title: '换源',
              subtitle: '当前源里的同名候选，匹配错时可手动选择正确结果',
              trailing: '${cands.length} 个',
            ),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.5,
              ),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                itemCount: cands.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (c, i) {
                  final v = cands[i];
                  final extra = <String>[
                    if (v.year.isNotEmpty) v.year,
                    if (v.note.isNotEmpty) v.note,
                  ].join(' · ');
                  final subtitle =
                      extra.isNotEmpty ? extra : v.actor.replaceAll(',', ' / ');
                  return _SheetOptionTile(
                    leading: _CandidatePoster(url: v.pic),
                    title: v.name,
                    subtitle: subtitle,
                    onTap: () async {
                      Navigator.pop(ctx);
                      await _controller.loadDetail(v);
                      if (mounted) setState(() {});
                      _saveHistoryForCurrentEpisode();
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
    // 与 initState 的 enter() 配对：告诉全局底栏"详情页关了"。
    // 必须放在 dispose 的**最早处**：下面还有一堆收尾逻辑
    // （落进度、停播放器、注销监听）可能抛异常，
    // 万一中途中断就漏掉了 exit —— 底栏会一直藏着出不来。
    try {
      if (Get.isRegistered<DetailPageController>()) {
        DetailPageController.instance.exit();
      }
    } catch (_) {}
    // 🔴 停播放器必须放在 dispose 最前面：后面任何一步抛异常都不允许
    // 留下"页面没了、声音还在放"。尤其 FF(AetherPlayer) 核心：原生 close
    // 之后还有异步收尾，越早发越好。
    _player?.dispose();
    _player = null;
    // 全屏（横屏锁）态被 iOS 边缘滑动手势直接 pop 时，_handleHeaderBack
    // 的"先退全屏"不会执行 → 'videoFullscreen' 的横屏锁没人解 → 整个
    // App 滞留横屏（用户反馈"突然整个界面横屏过来"）。dispose 兜底：
    // 解锁并强制回竖屏（App 常态就是竖屏，全屏才横）。
    if (Platform.isIOS) {
      try {
        SystemUiController.unlockOrientations('videoFullscreen');
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
        ]);
      } catch (_) {}
    }
    // 退出页先落一次进度，避免暂停中返回丢进度（_persistHistoryIfNeeded 只在播放中写）
    try {
      _persistHistoryIfNeeded(force: true);
    } catch (_) {}
    _engineWorker?.dispose();
    _decodeWorker?.dispose();
    _bufferWorker?.dispose();
    VideoPlayerPip.instance.activeNotifier.removeListener(_onPipChanged);
    WindowFullScreen.instance.activeNotifier.removeListener(
      _onFullScreenActiveChanged,
    );
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
    // （_player 的 dispose 已提前到本函数最前面 —— 任何后续异常都不能拦住它）

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
    // 按引擎创建：iOS 默认 IosAvPlayer（与小窗共用 AVPlayer）；AetherPlayer 备用（全格式）；MPV 兜底
    final engine = PlayerPrefs.instance.vodEngine.value;
    if (engine == PlayerEngine.mpv) {
      final mpv = MpvAppPlayer(config: const AppConfig(title: 'TVBox'));
      mpv.applyOptions(
        decode: _effectiveDecodeMode,
        buffer: PlayerPrefs.instance.bufferMode.value,
      );
      _player = mpv;
    } else if (engine == PlayerEngine.aether && Platform.isIOS) {
      _player = AetherPlayer(config: const AppConfig(title: 'TVBox'));
    } else if (Platform.isIOS) {
      _player = IosAvPlayer(config: const AppConfig(title: 'TVBox'));
    } else {
      _player = AppPlayer(config: const AppConfig(title: 'TVBox'));
    }
    _playerEngine = engine;
    _lastPlayerUrl = url;
    _lastPlayerHeadersKey = headersKey;
    _player!.open(AppMedia(url, httpHeaders: headers, start: start));
  }

  /// 播放器核心热切换（VideoPlayerWidget.onEngineChanged）。
  ///
  /// 选中核心时偏好已保存；这里记住当前进度 → 释放旧引擎实例 →
  /// 按新偏好立刻重建并从原位置续播，不用等下一集。
  /// ObjectKey(_player) 会让 VideoPlayerWidget 整体 remount，状态干净。
  ///
  /// ⚠️ 2026-10-19：**必须 await dispose** —— AetherPlayer 的 close 是异步的
  ///   （原生层销毁解码线程、释放 Metal 资源都需要时间），不 await 就创建
  ///   新实例会导致旧引擎还没死透、新引擎就 open，表现为「黑屏但有声音」
  ///   （音频已起、视频层没挂上）。await 后等旧引擎完全退出再重建。
  Future<void> _onEngineHotSwap(PlayerEngine engine) async {
    // ── 互斥：菜单 + ever 监听是两条并行路径，只能有一次真正重建 ──────
    if (_engineSwapInFlight) return;
    _engineSwapInFlight = true;
    // 先记下目标内核：随后 ever 回调进来时会因 `_playerEngine == engine`
    // 直接跳过，不会再把刚建好的实例拆掉。
    _playerEngine = engine;
    try {
      await _doEngineHotSwap(engine);
    } finally {
      _engineSwapInFlight = false;
    }
  }

  Future<void> _doEngineHotSwap(PlayerEngine engine) async {
    final url = _controller.playUrl.value ?? '';
    if (url.isEmpty) return;
    final headers = _controller.playHeaders.isNotEmpty
        ? Map<String, String>.from(_controller.playHeaders)
        : const <String, String>{};
    final pos = _player?.state.position ?? Duration.zero;
    // 先暂停再 dispose：dispose 是异步的（AetherPlayer 要等解码线程退出、
    // 释放 Metal 资源），期间若继续播放，记录的进度会落后实际位置。
    if (_player?.state.playing == true) {
      await _player?.pause();
    }
    final old = _player;
    // 先置空：_createPlayerAndOpen 才会走「按新引擎重建」分支而非「只换源」
    _player = null;
    // 🔴 iOS 换内核"有声音没画面"的根因：
    //   AVPlayer 的画面是 `UiKitView`（原生 AVPlayerLayer），
    //   mpv / AetherPlayer 的画面是 Flutter `Texture`。iOS 上平台视图的移除是
    //   **异步**的 —— 如果同一帧里摘掉原生视图、挂上新纹理，原生视图还留在
    //   视图层级最上层把画面盖住，于是只剩声音；退出播放页重进（整页重建）才恢复。
    //   所以这里先渲染一帧"加载中"空壳，等原生视图真正退场再创建新内核。
    _engineSwapping = true;
    setState(() {});
    await old?.dispose();
    await _waitPlatformViewDetach();
    if (!mounted) return;
    _engineSwapping = false;
    _createPlayerAndOpen(
      url,
      headers,
      _headersKey(headers),
      pos > Duration.zero ? pos : null,
    );
    // 切换内核 = 重新加载一次：必须清掉上一次的错误态，否则详情页还停在
    // 「播放失败」遮罩上 —— 看起来就像"切换没生效"。
    _controller.errorMessage.value = null;
    _controller.isPlaying.value = true;
    setState(() {});
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
          // 壁纸层已上提到 `app.dart` 的 MaterialApp.builder（Navigator 之上）。
          // 这里不要再画一遍 —— 叠两层遮罩（0.3 + 0.3）会让整页明显变暗。
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
                : _buildBody(),
          ),
        ],
      );
    });
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

      // 底部留白：滚动内容底部留少量空间，避免最后一项贴底
      final mediaPad = MediaQuery.of(context).padding;
      final bottomInset = mediaPad.bottom;
      // 与直播页一致：状态栏高度黑边，状态栏压在黑边上，不与画面重叠
      final topBar = mediaPad.top > 0 ? mediaPad.top : 0.0;
      final bottomPadding = bottomInset + 32.0;

      // 正常模式：视频 + 视频信息 + 选集 + 简介
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 0. 状态栏区域
            //    · 视频：黑边（与上方播放画面连成一体，状态栏发浅色图标）
            //    · 非视频（书 / 漫）：**不留黑边** —— 播放区已经整块不占了，
            //      再压一条黑带会像"凭空多出来一条黑条"；这里只占高度、
            //      按明暗发深/浅色图标，让内容直接顶上去（用户 2026-10-14）。
            if (topBar > 0)
              _controller.isNonVideoContent
                  ? AnnotatedRegion<SystemUiOverlayStyle>(
                      value: AppBrightness.isLight.value
                          ? SystemUiOverlayStyle.dark
                          : SystemUiOverlayStyle.light,
                      child: SizedBox(height: topBar),
                    )
                  : AnnotatedRegion<SystemUiOverlayStyle>(
                      value: SystemUiOverlayStyle.light,
                      child: SizedBox(
                        height: topBar / 2,
                        child: const ColoredBox(color: Colors.black),
                      ),
                    ),

            // 1. 播放器 - 对应 Swift PlayerView
            // **进详情即显示播放界面**：不依赖 isPlaying，只要 vodInfo 就绪
            // 就渲染播放器容器；URL 未就绪时 _buildPlayerArea 内部显示
            // 4:3 加载占位，解析完成后自动出画面（不再"先进文字后出视频"）
            _buildPlayerArea(),

            // 2. 视频信息区：简介/推荐/快搜 tab
            //    （简介 tab 内含 播放源/画质/合集 线路列表卡片；推荐/快搜 不显示）
            _buildVideoInfo(),

            // 底部间距
            SizedBox(height: bottomPadding),
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
    // 关键：相关 Rx 都在 Obx 内读取，选集/换源/全屏才能触发 rebuild
    return Obx(() {
      final isFull = _controller.isFullScreen.value;
      final isPip = VideoPlayerPip.instance.activeNotifier.value;
      final url = _controller.playUrl.value;
      // 选集变化也要重建（角标/标题/切集参数）
      final _ = _controller.selectedEpisodeIndex.value;
      final _ = _controller.playbackSessionId.value;
      final _ = _controller.selectedFlag.value;
      // 非视频内容（小说 `novel://` / 漫画 `pics://`）：**整块 4:3 播放区不占面积**
      // —— 页面直接显示 封面 / 简介 / 作者 / 更新时间 / 播放列表（用户 2026-10-14）。
      // 已知非视频的源在**再次进入详情页时**也走这里（一开始就不占位）。
      if (_controller.isNonVideoContent) {
        _playerErrorTimer?.cancel();
        _playerErrorTimer = null;
        return const SizedBox.shrink();
      }
      // 🔴 错误态必须**排在 url 分支之前**（用户 2026-10-28 20:53 截图）。
      //
      // 原来顺序是「有 url → 播放器 / 否则 → 错误态」，于是：
      //   · Spider 取址失败时 `playUrl` 已被上一集残留占位 → 走 url 分支 →
      //     错误文案和「重试 / 嗅 / 解」按钮**全都不出现**，用户只看到一块黑屏；
      //   · 播放器 onError 报的错同理被吞掉。
      // 正确顺序：**先看有没有错误**，有错就显示错误态（带可操作按钮），
      // 没错误再谈播放。
      final errMsg = _controller.errorMessage.value;
      if (errMsg != null && errMsg.isNotEmpty) {
        _playerErrorTimer?.cancel();
        _playerErrorTimer = null;
        // P1-3：错误分类提示，给用户一个可操作建议
        final errHint = _controller.classifyPlaybackError(errMsg);
        return AspectRatio(
          aspectRatio: 4 / 3,
          child: Container(
            color: Colors.black,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline_rounded,
                    color: Colors.white70, size: 40),
                const SizedBox(height: 14),
                Text(
                  errMsg,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
                // P1-3：分类建议，给用户一个可操作方向
                if (errHint != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      errHint,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    _errorActionButton(
                      '重试',
                      Icons.refresh_rounded,
                      () => _controller.retryCurrentEpisode(),
                    ),
                    // 换线路：直接切到下一条可用播放线路（不再打开解析面板）。
                    _errorActionButton(
                      '换线路',
                      Icons.swap_horiz_rounded,
                      () => _controller.switchToNextFlag(),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      }
      if (url != null && url.isNotEmpty) {
        _playerErrorTimer?.cancel();
        _playerErrorTimer = null;
        return _buildPlayerWidget(isFull: isFull, isPip: isPip);
      } else {
        // 正在播但 URL 尚未就绪：超时后置错误，避免永久转圈。
        // ⚠️ 正在取址时不启动这个计时 —— 取流本身可能要好几秒，
        // 误报"播放地址获取超时"会把用户从观看里打断（用户 2026-10-15）。
        if (!_controller.isResolving.value) {
          _playerErrorTimer ??= Timer(const Duration(seconds: 15), () {
            _playerErrorTimer = null;
            if (!mounted) return;
            if ((_controller.playUrl.value ?? '').isEmpty) {
              _controller
                  .setPlaybackError('播放地址获取超时，请点重试或切换其他线路');
            }
          });
        }
        // 4:3 容器: 比 16:9 更高, 上下控制条间距拉开, 视频画面不再被压成细缝
        return AspectRatio(
          aspectRatio: 4 / 3,
          child: Container(
            color: Colors.black,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(color: Colors.white),
                  const SizedBox(height: 12),
                  // ── 阶段文案（用户 2026-10-28 20:53）────────────────────
                  // 原来只有 `isResolving` 为真时才显示「正在解析视频地址…」，
                  // 其它等待状态就是**一个光秃秃的转圈**（截图里就那样），
                  // 用户完全不知道 App 在干什么 —— 只看到"卡住了"。
                  // 现在按阶段给明确文案，并**把「嗅 / 解 / 换线路」按钮
                  // 直接摆在等待画面上**：等待期间用户就能自己换线路，
                  // 不用先等失败。
                  Text(
                    _loadingStageText(),
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 13, height: 1.4),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    alignment: WrapAlignment.center,
                    children: [
                      _errorActionButton(
                        '换线路',
                        Icons.swap_horiz_rounded,
                        () => _controller.switchToNextFlag(),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      }
    });
  }

  /// 等待播放地址期间的阶段文案。
  String _loadingStageText() {
    // 解析线路阶段有更具体的文案（"正在用「解析一」解析…"）就优先用它 ——
    // 网页地址解析可能要几秒，光说"正在获取播放地址"用户以为卡死了
    final hint = _controller.resolveHint;
    if (hint.isNotEmpty) return hint;
    if (_controller.isResolving.value) return '正在获取播放地址…';
    return '正在准备播放…';
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

  /// 等 iOS 原生视图（UiKitView）真正从视图层级退场。
  ///
  /// 平台视图的移除是异步的（要等原生层销毁 + 合成器回收），
  /// 留 250ms 覆盖一到两帧；其它平台没有平台视图，零开销。
  Future<void> _waitPlatformViewDetach() async {
    if (!Platform.isIOS) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  Widget _buildPlayerWidget({required bool isFull, required bool isPip}) {
    final url = _controller.playUrl.value!;
    // 内核切换过渡帧：只渲染空壳，**不要**在这里调 _ensurePlayer ——
    // 否则新实例会在原生视图还没退场时就建好，画面又会被盖住。
    if (_engineSwapping) {
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
    // 影视模块只播媒体直链（2026-10-29 用户要求）：网页地址**不内嵌 WebView**，
    // 给一条明确提示而不是把 HTML 丢给播放器（那只会白卡 15 秒再说"加载超时"）。
    // 正常流程里 controller 已经在取址阶段拦掉了网页地址，这里是历史记录 /
    // 续播等旁路进来的兜底。
    if (PlaybackSurface.needsWebFallback(url)) {
      return AspectRatio(
        aspectRatio: 4 / 3,
        child: Container(
          color: Colors.black,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: const Text(
            kMovieWebUrlRejected,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
          ),
        ),
      );
    }
    final headers = _controller.playHeaders.isNotEmpty
        ? Map<String, String>.from(_controller.playHeaders)
        : const <String, String>{};

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
      onEngineChanged: _onEngineHotSwap,
      // 切换解析线路：播放器只负责发信号，弹层 + 重新嗅探由本页做
      // （只有这一层还留着「原始播放页地址」）。
      onSwitchParseLine: _openParseLineSheet,
      // 字幕选择接力：重建（含热切换）后按 matchKey 还原同一条字幕
      subtitleChoice: _subtitleChoice,
      onSubtitleChoiceChanged: (c) => _subtitleChoice = c,
      // 跨全屏/普通模式共享同一个 controller
      initialVideoFit: VideoFitType.contain, // 4:3 容器 + 黑框适配: 画面按原始比例完整显示, 上下黑边
      url: url,
      headers: headers.isEmpty ? null : headers,
      resumeSeconds: _controller.resumeSeconds.value,
      videoTitle: info?.name,
      // 弹幕匹配优先用 TMDB 刮削名（更接近爱优腾/B站的索引标题），
      // 没刮削到就回落到 CMS 原名
      danmuTitle: (info != null && info.tmdbName.isNotEmpty)
          ? info.tmdbName
          : null,
      currentEpisodeName: episode?.name,
      episodeNames: _controller.currentEpisodes.map((e) => e.name).toList(),
      selectedEpisodeIndex: _controller.selectedEpisodeIndex.value,
      canPlayNext:
          _controller.selectedEpisodeIndex.value <
          _controller.currentEpisodes.length - 1,
      canPlayPrevious: _controller.selectedEpisodeIndex.value > 0,
      isPipMode: isPip,
      showAudioModeButton: true,
      // 播放设置弹窗限高到播放器高度，避免盖住下方 tab 栏
      sheetMaxHeight: _playerSheetMaxHeight(context),
      skipIntroSeconds: _controller.skipIntroSeconds.value,
      skipOutroSeconds: _controller.skipOutroSeconds.value,
      onPlayNext: () => _playNextEpisode(),
      onPlayPrevious: () => _playPreviousEpisode(),
      // 「短」按钮：跳到短剧专用页（媒体库等页面不传，用自己的竖屏 UI）
      onEnterDramaMode: _openDramaPlayer,
      // 抖音模式：无剧集（电影）时的上/下一部电影（走推荐队列）
      onDramaNextMovie: () => _switchMovieInQueue(delta: 1),
      onDramaPrevMovie: () => _switchMovieInQueue(delta: -1),
      onSelectEpisode: (index) {
        _controller.selectEpisode(index);
        _saveHistoryForCurrentEpisode();
      },
      onPositionChanged: (pos) =>
          _handlePlaybackProgress(pos.inSeconds.toDouble()),
      onEnded: () {
        // ── Webhtv 观影记录同步：自然完播上报 ──────────────────────
        // 放在自动下一集判定**之前**：无论是否开启自动下一集，
        // 本集确实播完了都要上报 `playback.ended`。
        _reportPlaybackEnded();
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

  /// 错误态下的操作按钮（重试 / 换线路），统一圆角样式，保证失败页也能
  /// 直接操作，不再"顶掉播放器导致死循环"（2026-10-28）。
  Widget _errorActionButton(String label, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.2),
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17, color: Colors.white),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
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
                Text(
                  '正在刮削元数据…',
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontFootnote,
                  ),
                ),
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
                  if (index == 2) {
                    // 快搜：恢复为详情页**内嵌**快搜（修改前原状）。
                    // 点击即自动用剧名搜索；结果在本 tab 内展示
                    // （多源芯片 + 与搜索页一致的结果列表），不再跳转搜索页。
                    _controller.detailTabIndex.value = 2;
                    final nm = _controller.vodInfo.value?.name ?? '';
                    if (nm.trim().isNotEmpty) {
                      _runQuickSearch(nm.trim());
                    }
                    return;
                  }
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
                      color: selected
                          ? AppTheme.textPrimary
                          : AppTheme.textTertiary,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: selected
                          ? FontWeight.w600
                          : FontWeight.normal,
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
                      // fill = 拉伸填满、**整张图都显示**（与首页/搜索页封面一致；
                      // cover 会把海报两侧裁掉 → 用户反馈"图片显示不全"）
                      fit: BoxFit.fill,
                      placeholder: (_, __) => Container(
                        color: AppTheme.backgroundTertiary,
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.movie_outlined,
                          color: AppTheme.textTertiary,
                          size: 28,
                        ),
                      ),
                      errorBuilder: (_, __, ___) => Container(
                        color: AppTheme.backgroundTertiary,
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.broken_image_outlined,
                          color: AppTheme.textTertiary,
                          size: 28,
                        ),
                      ),
                    )
                  : Container(
                      color: AppTheme.backgroundTertiary,
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.movie_outlined,
                        color: AppTheme.textTertiary,
                        size: 28,
                      ),
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
                    // Spider / 远程接口源：手动换源、选正确结果（同名剧匹配错时）
                    // ⚠️ 判据用 canSwitchSourceInPage（与换源弹窗同一口径），
                    //    不是 isSpiderSource（那个只管 type==3，是播放入口分流在用的）
                    Obx(() {
                      if (!_controller.canSwitchSourceInPage) {
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
                          child: Icon(
                            Icons.swap_horiz,
                            size: 18,
                            color: AppTheme.accentColor,
                          ),
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
                        child: Icon(
                          Icons.auto_fix_high,
                          size: 18,
                          color: AppTheme.accentColor,
                        ),
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
                      horizontal: 10,
                      vertical: 5,
                    ),
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
                        Icon(
                          Icons.theaters_outlined,
                          size: 12,
                          color: AppTheme.accentColor,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            sourceName,
                            style: TextStyle(
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
  // ignore: unused_element
  Widget _buildCastSection(VodInfo info) {
    if (info.castList.isEmpty) return const SizedBox.shrink();
    final tmdb = TmdbService.instance;
    return Obx(() {
      if (!tmdb.showCast.value) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingLG,
          AppTheme.spacingMD,
          0,
          0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: AppTheme.spacingLG),
              // 标题跟随外观主题（粗体 16）
              child: Row(
                children: [
                  Icon(Icons.people_alt_outlined,
                      size: 18, color: AppTheme.textSecondary),
                  const SizedBox(width: 6),
                  Text(
                    '演职员',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppTheme.spacingSM),
            SizedBox(
              height: 148,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(right: AppTheme.spacingLG),
                itemCount: info.castList.length,
                // 方案：演职员间距 16px
                separatorBuilder: (_, __) => const SizedBox(width: 16),
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
  // ignore: unused_element
  Widget _buildSimilarSection(VodInfo info) {
    if (info.similarList.isEmpty) return const SizedBox.shrink();
    final tmdb = TmdbService.instance;
    return Obx(() {
      if (!tmdb.showSimilar.value) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingLG,
          AppTheme.spacingMD,
          0,
          0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: AppTheme.spacingLG),
              // 标题跟随外观主题（粗体 16）
              child: Row(
                children: [
                  Icon(Icons.local_movies_outlined,
                      size: 18, color: AppTheme.textSecondary),
                  const SizedBox(width: 6),
                  Text(
                    '类似作品',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
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
              final cardW =
                  (constraints.maxWidth -
                      AppTheme.spacingLG * 2 -
                      AppTheme.cardSpacing * (cols - 1)) /
                  cols;
              final ratio = cardW / (cardW * 0.72 + 30);
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(
                  horizontal: AppTheme.spacingLG,
                  vertical: 6,
                ),
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
        ...info.actor
            .split(',')
            .map((a) => a.trim())
            .where((a) => a.isNotEmpty)
            .take(3),
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
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontBody,
                  ),
                  decoration: InputDecoration(
                    hintText: '搜索影片',
                    hintStyle: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontSubhead,
                    ),
                    prefixIcon: Icon(
                      Icons.search,
                      size: 18,
                      color: AppTheme.textTertiary,
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    // 透明底：去掉灰填充，透出外层容器/页面背景
                    filled: false,
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
                  child: const Icon(
                    Icons.search,
                    size: 20,
                    color: Colors.white,
                  ),
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
                  .map(
                    (k) => SelectableChip(
                      title: k,
                      isSelected: _quickSearchDoneFor == k,
                      onTap: () {
                        _quickSearchInput.text = k;
                        _runQuickSearch(k, force: true);
                      },
                    ),
                  )
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
                              strokeWidth: 2,
                              color: AppTheme.accentColor,
                            ),
                          )
                        else
                          Icon(
                            Icons.search_off,
                            size: 26,
                            color: AppTheme.textTertiary,
                          ),
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
                            fontSize: AppTheme.fontSubhead,
                            height: 1.5,
                          ),
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
                                    color: AppTheme.accentColor,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '搜索中',
                                  style: TextStyle(
                                    color: AppTheme.textTertiary,
                                    fontSize: AppTheme.fontFootnote,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ...sites.map((site) {
                        final sel = selectedKey == site.key;
                        final count = _quickSearch.resultCount[site.key] ?? 0;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _quickSearch.selectSite(site.key),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: sel
                                    ? AppTheme.accentColor.withValues(
                                        alpha: 0.22,
                                      )
                                    : AppTheme.backgroundTertiary,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: sel
                                      ? AppTheme.accentColor.withValues(
                                          alpha: 0.55,
                                        )
                                      : AppTheme.borderLight,
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
                                      fontSize: AppTheme.fontSubhead,
                                    ),
                                  ),
                                  if (count > 0) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppTheme.accentColor.withValues(
                                          alpha: 0.20,
                                        ),
                                        borderRadius: BorderRadius.circular(9),
                                      ),
                                      child: Text(
                                        '$count',
                                        style: TextStyle(
                                          color: AppTheme.accentColor,
                                          fontSize: AppTheme.fontCaption,
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
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontSubhead,
                        ),
                      ),
                    ),
                  )
                else
                  LayoutBuilder(
                    builder: (context, constraints) {
                      // 与推荐区同一套算法：网格高度必须跟 VodCard 配套
                      // （卡片高 = 宽 × 0.72 + 文字区），否则卡片被拉长、封面失真。
                      const cols = 3;
                      final cardW =
                          (constraints.maxWidth -
                              AppTheme.spacingLG * 2 -
                              AppTheme.cardSpacing * (cols - 1)) /
                          cols;
                      final ratio = cardW / (cardW * 0.72 + 30);
                      return GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
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
                            onTap: () => Get.toNamed('/detail', arguments: v),
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
      final isCollected = CacheStore.instance.isCollected(
        info.id,
        info.sourceKey,
      );

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
                    style: TextStyle(
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
            // 非视频内容（小说 / 漫画）额外显示 vod_remarks —— 来源常把
            // 「作者 / 更新时间」塞在这里，而影视链路没有对应展示位
            // （用户 2026-10-14：书/漫详情要直接看到作者与更新时间）。
            if (_controller.isNonVideoContent && info.note.isNotEmpty)
              MetadataPill(text: info.note),
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
  // ignore: unused_element
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
            gradient: LinearGradient(
              colors: [
                AppTheme.accentColor,
                AppTheme.accentColor.withValues(alpha: 0.75),
              ],
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

  /// 弹出「切换解析线路」并重解当前集。
  ///
  /// 两个入口共用：播放器底栏的「线路」按钮、播放源卡片里的「解析线路」段。
  /// 换完线路 `retryCurrentEpisode()` 会重走一遍取址 → 嗅探，播放器热替换地址。
  Future<void> _openParseLineSheet() async {
    final picked = await showParseLineSheet(context);
    if (picked == null || !mounted) return;
    if (picked == ParseLineStore.instance.selectedId) {
      AppToast.message('已经是这条线路了');
      return;
    }
    await _controller.switchParseLine(picked);
  }

  /// 播放线路 + 选集播放 —— 合并成一张独立卡片（三段式底部）
  /// （清晰度选择已按用户要求移除：HLS 解析仍自动进行，默认档位直接播放）
  Widget _buildPlaybackCard() {
    // 有一条也显示，对齐参考图（播放源/合集完整分段）
    final hasFlag = _controller.flags.isNotEmpty;
    final hasEpisodes = _controller.currentEpisodes.isNotEmpty;
    if (!hasFlag && !hasEpisodes) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.spacingLG,
        AppTheme.spacingMD,
        AppTheme.spacingLG,
        0,
      ),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasFlag) ...[
              const SectionHeader(
                title: '播放源',
                icon: Icons.settings_input_antenna,
              ),
              const SizedBox(height: AppTheme.spacingSM),
              Obx(
                () => SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: _controller.flags.map((flag) {
                      final isSelected = _controller.selectedFlag.value == flag;
                      return Padding(
                        padding: const EdgeInsets.only(
                          right: AppTheme.spacingSM,
                        ),
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
                ),
              ),
            ],
            // ── 解析线路（用户 2026-10-31）────────────────────────────
            // 「解析站不行就是我自己切换线路来」。这里**不列全部**线路：
            // 订阅里动辄 50+ 条，全铺开会把卡片撑爆，也会盖掉下面的合集。
            // 只显示当前这条 + 一个「换一条」，点开是共享的线路弹层。
            const SizedBox(height: AppTheme.spacingMD),
            Divider(height: 1, color: AppTheme.borderLight),
            const SizedBox(height: AppTheme.spacingMD),
            const SectionHeader(
              title: '解析线路',
              icon: Icons.alt_route_rounded,
            ),
            const SizedBox(height: AppTheme.spacingSM),
            AnimatedBuilder(
              animation: ParseLineStore.instance,
              builder: (_, __) {
                final store = ParseLineStore.instance;
                final name = store.selectedName;
                return Row(
                  children: [
                    Flexible(
                      child: _PillChip(
                        title: name,
                        isSelected: true,
                        onTap: _openParseLineSheet,
                      ),
                    ),
                    const SizedBox(width: AppTheme.spacingSM),
                    _PillChip(
                      title: '换一条',
                      isSelected: false,
                      onTap: _openParseLineSheet,
                    ),
                  ],
                );
              },
            ),
            if (hasEpisodes) ...[
              const SizedBox(height: AppTheme.spacingMD),
              Divider(height: 1, color: AppTheme.borderLight),
              const SizedBox(height: AppTheme.spacingMD),
              const SectionHeader(title: '合集', icon: Icons.list),
              const SizedBox(height: AppTheme.spacingSM),
              Obx(
                () => EpisodeListView(
                  episodeNames: _controller.currentEpisodes
                      .map((e) => e.name)
                      .toList(),
                  selectedIndex: _controller.selectedEpisodeIndex.value,
                  onEpisodeTap: (index) {
                    _controller.selectEpisode(index);
                    _saveHistoryForCurrentEpisode();
                  },
                ),
              ),
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
    final progress = (progressOverride ?? _controller.currentPlaybackSeconds())
        .clamp(0.0, double.infinity)
        .toDouble();
    final timeLabel = progress > 0 ? _formatDuration(progress) : '';
    final playNote = timeLabel.isEmpty
        ? episodeLabel
        : '$episodeLabel $timeLabel';

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

    // ── Webhtv 观影记录同步：上报进度 ─────────────────────────────
    // 这里是**唯一的进度落盘点**（周期进度 / 暂停退出 / 切集切线路前都汇聚于此），
    // 已覆盖文档要求的三个进度时机；自然完播另走 [onEnded] → `ended: true`。
    // ⚠️ 总时长字段暂未接（`durationMs: 0`），完播以 `completed: true` 表达。
    unawaited(WebhtvPlaybackSyncService.instance.reportProgress(
      siteKey: info.sourceKey,
      vodId: info.id,
      vodName: info.name,
      vodPic: info.pic,
      flag: _controller.selectedFlag.value,
      episodeName: episodeLabel,
      episodeUrl: info.currentEpisode?.url ?? '',
      episodeIndex: _controller.selectedEpisodeIndex.value,
      positionMs: (progress * 1000).round(),
    ));
  }

  /// 自然完播上报（`playback.ended`）——与自动下一集开关无关。
  void _reportPlaybackEnded() {
    final info = _controller.vodInfo.value;
    if (info == null) return;
    final episodeName = info.currentEpisode?.name.trim() ?? '';
    unawaited(WebhtvPlaybackSyncService.instance.reportProgress(
      siteKey: info.sourceKey,
      vodId: info.id,
      vodName: info.name,
      vodPic: info.pic,
      flag: _controller.selectedFlag.value,
      episodeName:
          episodeName.isEmpty ? '第${_controller.selectedEpisodeIndex.value + 1}集' : episodeName,
      episodeUrl: info.currentEpisode?.url ?? '',
      episodeIndex: _controller.selectedEpisodeIndex.value,
      positionMs: (_controller.currentPlaybackSeconds() * 1000).round(),
      ended: true,
    ));
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
    final progress = (currentProgress ?? _controller.currentPlaybackSeconds())
        .clamp(0.0, double.infinity)
        .toDouble();
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
    _lastPersistedProgress = playbackState.progressSeconds
        .clamp(0.0, double.infinity)
        .toDouble();
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

  /// 播放器「短」按钮：跳到短剧专用页（与短剧 tab 进去的 UI 完全一致）。
  /// 媒体库详情页 / 媒体库播放器不传这个回调，继续用它们自己的竖屏 UI。
  Future<void> _openDramaPlayer() async {
    final info = _controller.vodInfo.value;
    if (info == null) return;
    final p = _player;
    final resumeAt = p?.state.position ?? Duration.zero;
    p?.pause();
    await Get.to(() => DramaPlayerPage(
          video: Video(
            id: info.id,
            name: info.name,
            pic: info.pic,
            des: info.des,
            sourceKey: info.sourceKey,
          ),
          initialIndex: _controller.selectedEpisodeIndex.value,
          // 从播放器点进来的：就留在当前这一集，别按历史跳到别的集
          startFromHistory: false,
        ));
    if (!mounted) return;
    // ⚠️ iOS 的 AVPlayer / AetherPlayer 是**全进程共用一个原生播放器**：
    //    短剧页 open() 时已经把原生实例接管了，返回后本页手上的实例
    //    指向的还是短剧那一集（画面/进度全错）。
    //    这里用原地址 + 离开前的进度重新 open 一次，把播放器拿回来。
    final url = _controller.playUrl.value;
    final self = _player;
    if (self == null || url == null || url.isEmpty) return;
    final headers = _controller.playHeaders;
    self.open(AppMedia(
      url,
      httpHeaders:
          headers.isEmpty ? null : Map<String, String>.from(headers),
      start: resumeAt,
    ));
  }

  /// 抖音模式：电影无剧集可切时，从推荐队列切上一部/下一部电影。
  /// 目标影片打开新详情页播放（若当前片不在推荐列表，则取列表第一/最后一部）。
  void _switchMovieInQueue({required int delta}) {
    final items = _controller.recommended;
    if (items.isEmpty) return;
    final info = _controller.vodInfo.value;
    if (info == null) return;
    final idx = items.indexWhere((v) => v.id == info.id);
    final target = idx >= 0 ? idx + delta : (delta > 0 ? 0 : items.length - 1);
    if (target < 0 || target >= items.length) return;
    Get.toNamed('/detail', arguments: items[target]);
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
    // 与「换源」弹层里的选项行保持同一套选中语言：
    // 主题色浅底 + 细描边 + ✓，未选中为灰底无描边。
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.accentColor.withValues(alpha: 0.12)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(18),
          border: isSelected
              ? Border.all(
                  color: AppTheme.accentColor.withValues(alpha: 0.45),
                  width: 0.8,
                )
              : Border.all(color: AppTheme.borderLight, width: 0.6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isSelected) ...[
              Icon(Icons.check_rounded,
                  size: 13, color: AppTheme.accentColor),
              const SizedBox(width: 4),
            ],
            Text(
              title,
              style: TextStyle(
                color:
                    isSelected ? AppTheme.accentColor : AppTheme.textSecondary,
                fontSize: AppTheme.fontFootnote,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 详情页底部弹层的拖拽把手（换源弹层使用）
class _SheetGrabber extends StatelessWidget {
  const _SheetGrabber();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 10, bottom: 6),
      width: 40,
      height: 4,
      decoration: BoxDecoration(
        color: AppTheme.textTertiary.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

/// 详情页底部弹层的标题行（换源弹层使用）
class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.title, this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              if (trailing != null)
                Text(
                  trailing!,
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: 12,
                  ),
                ),
            ],
          ),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontFootnote,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 详情页底部弹层的统一选项行（换源候选项使用）
class _SheetOptionTile extends StatelessWidget {
  const _SheetOptionTile({
    required this.title,
    this.subtitle,
    this.leading,
    required this.onTap,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;

  /// 目前所有调用方都不需要"选中态"；保留字段让样式分支不动，恒 false。
  final bool selected = false;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? AppTheme.accentColor.withValues(alpha: 0.12)
          : AppTheme.backgroundTertiary,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: selected
                ? Border.all(
                    color: AppTheme.accentColor.withValues(alpha: 0.45),
                    width: 0.8,
                  )
                : null,
          ),
          child: Row(
            children: [
              if (leading != null) ...[
                leading!,
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: selected
                            ? AppTheme.accentColor
                            : AppTheme.textPrimary,
                        fontSize: AppTheme.fontBody,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                    if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontCaption,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.chevron_right_rounded,
                color: selected
                    ? AppTheme.accentColor
                    : AppTheme.textTertiary.withValues(alpha: 0.6),
                size: 19,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 换源候选的小海报（44×60；无图时回退电影图标）
class _CandidatePoster extends StatelessWidget {
  const _CandidatePoster({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final u = url.trim();
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 44,
        height: 60,
        child: u.isEmpty
            ? Container(
                color: AppTheme.backgroundSecondary,
                alignment: Alignment.center,
                child: Icon(
                  Icons.movie_outlined,
                  size: 20,
                  color: AppTheme.textTertiary,
                ),
              )
            : CachedNetworkImage(
                imageUrl: u,
                fit: BoxFit.cover,
                memCacheWidth: 120,
                placeholder: (_, __) =>
                    Container(color: AppTheme.backgroundSecondary),
                errorBuilder: (_, __, ___) => Container(
                  color: AppTheme.backgroundSecondary,
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.broken_image_outlined,
                    size: 18,
                    color: AppTheme.textTertiary,
                  ),
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
              // 参考图：头像直径 64
              width: 64,
              height: 64,
              child: url.isEmpty
                  ? _avatarPlaceholder()
                  : CachedNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.cover,
                      memCacheWidth: 160,
                      placeholder: (_, __) => _avatarPlaceholder(),
                      errorBuilder: (_, __, ___) => _avatarPlaceholder(),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            member.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            // 名字：主题主文字 12px
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (member.character.isNotEmpty)
            Text(
              member.character,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              // 角色名：主题弱文字 11px
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: 11,
              ),
            ),
        ],
      ),
    );
  }

  /// 无头像时的首字占位（跟随外观主题）
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
                            // 同上：封面统一拉伸显示，不裁切
                            fit: BoxFit.fill,
                            memCacheWidth: 224,
                            placeholder: (_, __) =>
                                ColoredBox(color: AppTheme.backgroundTertiary),
                            errorBuilder: (_, __, ___) =>
                                ColoredBox(color: AppTheme.backgroundTertiary),
                          ),
                    // 评分角标（右上）
                    if (item.hasRating)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
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
              // 片名：主题主文字
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontCaption,
              ),
            ),
            if (item.year.isNotEmpty)
              Text(
                item.year,
                // 年份：主题弱文字
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
