import 'dart:async';
import 'dart:convert';
import 'dart:math' show Random;

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:tvbox/models/movie.dart';
import 'package:tvbox/models/vod_info.dart';
import 'package:tvbox/models/cache_store.dart';
import 'package:tvbox/models/cache_ttl.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/services/source_service.dart';
import 'package:tvbox/services/spider_service.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/network_manager.dart';
import 'package:tvbox/services/play_route.dart';
import 'package:tvbox/services/sniff_filter.dart';
import 'package:tvbox/services/player_prefs.dart';
import 'package:tvbox/services/ad_filter_service.dart';
import 'package:tvbox/services/parse_service.dart';
import 'package:tvbox/services/parse_store.dart';
import 'package:tvbox/services/play_url_sanitizer.dart';
import 'package:tvbox/services/web_sniff_service.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/webhome/webhtv_site_health_page.dart';
import 'package:tvbox/pages/play/sniff_player_page.dart';
import 'package:tvbox/pages/detail/simple_image_reader_page.dart';
import 'package:tvbox/pages/detail/simple_text_reader_page.dart';

class PlaybackQualityOption {
  static const String autoIdentifier = 'auto';

  final String id;
  final String name;
  final String url;

  const PlaybackQualityOption({
    required this.id,
    required this.name,
    required this.url,
  });

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'url': url};

  factory PlaybackQualityOption.fromJson(Map<String, dynamic> json) {
    return PlaybackQualityOption(
      id: json['id'] as String? ?? autoIdentifier,
      name: json['name'] as String? ?? '',
      url: json['url'] as String? ?? '',
    );
  }

  bool get isAuto => id == autoIdentifier;

  static PlaybackQualityOption auto(String url) {
    return PlaybackQualityOption(
      id: autoIdentifier,
      name: '自动',
      url: url,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaybackQualityOption &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// 当前集解析出来的**内容形态**。
///
/// - [video]    普通视频（走播放器）
/// - [pictures] 图片列表（漫画 / 图源，`pics://`）→ 看图阅读器
/// - [text]     正文（小说源，`novel://`）→ 书籍阅读器
///
/// 非 [video] 时详情页**不占**那块 4:3 播放区（用户 2026-10-14）。
enum PlayContentMode { video, pictures, text }

class DetailController extends GetxController with WidgetsBindingObserver {
  final vodInfo = Rx<VodInfo?>(null);
  final isLoading = false.obs;
  final errorMessage = Rx<String?>(null);
  final selectedFlag = ''.obs;
  final selectedEpisodeIndex = 0.obs;
  final isPlaying = false.obs;
  final playUrl = Rx<String?>(null);

  /// **正在自动嗅探的网页地址**（非空 = 已弹起嗅探页）。
  ///
  /// 为什么需要它（用户 2026-10-15「嗅探容易影响播放」）：
  ///   · 详情页播放区**不再**同时挂内嵌 WebView —— 否则和嗅探页各加载一份
  ///     同一网页，双份解码/双份声音，返回后底层还在跑（这是最主要的影响）；
  ///   · 也用它做**去重**：已有嗅探页在栈中就不再 push 新页，避免"自动下一集"
  ///     每集都叠一层嗅探页、返回要连按多次。
  final sniffingUrl = Rx<String?>(null);

  /// 正在走解析接口取地址（详情页据此显示"解析中"，且**不**启动 15 秒
  /// "地址获取超时"计时 —— 解析慢时误报错误会打断用户观看）。
  final isResolving = false.obs;

  /// 内嵌网页播放器**正在后台嗅探**（用户 2026-10-28 20:53）。
  ///
  /// 网页兜底播放时，网页在后台嗅探直链。这件事以前**完全不可见** ——
  /// 用户点播放后只看到一块网页/纯黑，不知道 App 在嗅探，更不知道
  /// 嗅探可能失败、要换线路。这个标志让详情页播放区显示
  /// 「正在嗅探视频地址…」，链路可见。
  final isWebSniffing = false.obs;

  /// 后台嗅探**放弃**（未命中）标记：详情页据此把「正在嗅探视频地址…」
  /// 的转圈浮层换成「未嗅探到直链，可点换线路」的静态提示，几秒后自动消失。
  final sniffGaveUp = false.obs;
  Timer? _sniffGaveUpTimer;

  /// **已确认是媒体、但地址没有影视后缀**的那一条地址（空串 = 无）。
  ///
  /// 为什么需要它（2026-10-28 复核发现的断点）：
  /// 解析接口经常直接给出 `http://xx/nm_free.php?url=…` 这种地址 ——
  /// 响应体就是 `#EXTM3U`，AVPlayer 完全能播，但**地址本身没有 `.m3u8`**。
  /// 详情页的 [_isWebPageUrl] 靠后缀判定，会把这种地址当网页塞进 WebView，
  /// 打开的是一个 m3u8 文本页 → 白解析、黑屏。
  /// 这里记下"已经用 Content-Type / 首字节确认过是媒体"的地址，
  /// 详情页据此**跳过** WebView，直接交给原生播放器。
  final confirmedMediaUrl = ''.obs;

  final playHeaders = <String, String>{}.obs;
  final playbackSessionId = ''.obs;
  final resumeSeconds = 0.0.obs;
  final qualityOptions = <PlaybackQualityOption>[].obs;
  final selectedQualityId = PlaybackQualityOption.autoIdentifier.obs;

  /// 是否处于全屏模式 - 对应 Swift isFullScreenMode
  final isFullScreen = false.obs;

  /// 跳过片头秒数（0 表示关闭）- 对应 Swift skipIntroSeconds
  final skipIntroSeconds = 0.obs;

  /// 跳过片尾秒数（0 表示关闭）- 对应 Swift skipOutroSeconds
  final skipOutroSeconds = 0.obs;

  /// 推荐 tab 数据（同类型/关键词推荐）
  final recommended = <Video>[].obs;
  final isRecommendLoading = false.obs;

  /// 加载中又被请求时置位，本轮结束后补跑一次
  bool _recommendPending = false;

  /// 单源搜索超时。超过就丢弃该源的结果，不等它。
  ///
  /// 原实现（和 SourceService.searchAll）用 Future.wait 等**所有**源，
  /// 一个慢源就拖死整次加载 —— 这是「推荐加载慢」的主因。
  static const Duration _recommendPerSourceTimeout = Duration(seconds: 6);

  /// 每轮并发搜索的源数量上限。
  /// 推荐只是辅助内容，不值得把全部源都打一遍（接口多有限流）。
  static const int _recommendSourceCount = 3;

  /// 详情页 tab 索引: 0=简介, 1=推荐, 2=快搜
  final detailTabIndex = 0.obs;

  // ============================================================
  // 内容形态（视频 / 图片 / 正文）
  // ============================================================

  /// 当前集解析出来的内容形态 —— 由 `playerContent` 返回的协议决定：
  /// `novel://` → 正文；`pics://` / `mange://` → 图片；其余 → 视频。
  final contentMode = PlayContentMode.video.obs;

  /// 已知为「非视频内容源」的 sourceKey（小说 / 漫画源），落 prefs。
  ///
  /// 为什么需要它：内容形态只能在 `playerContent` 返回后才知道，但用户
  /// **再次**进入这类源的详情页时，不该再先黑底转圈 15 秒（然后报"播放地址
  /// 获取超时"）—— 记住它，一开始就不占那块 4:3 播放区（用户 2026-10-14）。
  static const String _kNonVideoKeys = 'non_video_source_keys';
  final nonVideoSourceKeys = <String>{}.obs;

  /// 详情页是否**不占**那块 4:3 播放区（非视频内容）。
  bool get isNonVideoContent =>
      contentMode.value != PlayContentMode.video ||
      nonVideoSourceKeys.contains(vodInfo.value?.sourceKey ?? '');

  Future<void> _loadNonVideoSources() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getStringList(_kNonVideoKeys) ?? const <String>[];
      if (keys.isNotEmpty) nonVideoSourceKeys.addAll(keys);
    } catch (e) {
      AppLog.instance.w('[Detail] 读非视频源记录失败: $e');
    }
  }

  Future<void> _rememberNonVideoSource() async {
    final key = vodInfo.value?.sourceKey ?? '';
    if (key.isEmpty || nonVideoSourceKeys.contains(key)) return;
    nonVideoSourceKeys.add(key);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kNonVideoKeys, nonVideoSourceKeys.toList());
    } catch (e) {
      AppLog.instance.w('[Detail] 写非视频源记录失败: $e');
    }
  }

  /// 加载推荐（固定「同类型」+ 多源并发 + 每源超时）。
  ///
  /// 做法（用户拍板：同类型的影视随便都可以，不要搞复杂）：
  /// - **关键词固定用「类型」（typeName）**：不再随机抽"地区/演员"——
  ///   那些宽泛词在源内过滤下经常 0 条，结果是推荐五花八门、效果差；
  ///   类型是唯一能稳定命中"同类型"的锚点。
  /// - 无类型标签（部分电影）→ 用片名兜底搜一次；
  /// - 随机抽 N 个可搜索源并发搜索，单源超时即弃；
  /// - 结果按 id 去重后再洗牌。
  ///
  /// 加载期间**保留旧结果**（不先清空），避免切 tab 时闪一下白。
  Future<void> loadRecommended() async {
    if (isRecommendLoading.value) {
      // 正在加载时又被请求（用户快速切走再切回）：
      // 记一笔，等本轮结束后再跑一次，否则这次切回来内容不会换新。
      _recommendPending = true;
      return;
    }
    final info = vodInfo.value;
    if (info == null) return;

    isRecommendLoading.value = true;
    try {
      // ---- 关键词：固定用「类型」；无类型 → 片名兜底 ----
      final keyword = info.typeName.trim().isNotEmpty
          ? info.typeName.trim()
          : info.name.trim();
      if (keyword.isEmpty) return;

      // ---- 源：随机抽 N 个并发搜，单源超时即弃 ----
      final pool = ApiConfig.instance
          .getSearchableSources()
          .where((s) => s.isSupportedInSwift)
          .toList();
      if (pool.isEmpty) return;
      pool.shuffle(Random());
      final picked = pool.take(_recommendSourceCount).toList();

      final found = <Video>[];
      final seen = <String>{info.id};
      final futures = <Future<List<Video>>>[];
      for (final src in picked) {
        futures.add(
          SourceService.instance
              .search(src, keyword)
              .timeout(_recommendPerSourceTimeout)
              .catchError((Object e) {
            AppLog.instance.log(
                '[Recommend] 源 ${src.name} 搜索"$keyword"失败/超时: $e');
            return <Video>[];
          }),
        );
      }
      for (final list in await Future.wait(futures)) {
        for (final v in list) {
          if (v.id.isEmpty || !seen.add(v.id)) continue;
          found.add(v);
        }
      }

      // ---- 洗牌：同类型里"随便"排，顺序也随机 ----
      found.shuffle(Random());
      if (!isClosed) {
        recommended.value = found.take(30).toList();
        AppLog.instance.log(
            '[Recommend] 关键词="$keyword" 源=${picked.map((s) => s.name).join("/")} 结果=${found.length} 条');
      }
    } catch (e) {
      AppLog.instance.log('[Recommend] loadRecommended 异常: $e');
    } finally {
      isRecommendLoading.value = false;
      // 加载期间又来过的请求 → 补跑一次，保证"每次切回来都换新"
      if (_recommendPending) {
        _recommendPending = false;
        if (!isClosed) {
          // 不 await：让当前调用先返回，避免把调用方也拖住
          Future<void>.microtask(loadRecommended);
        }
      }
    }
  }

  double _realtimeProgressSeconds = 0;

  String _qualityBaseEpisodeURL = '';
  final Map<String, List<PlaybackQualityOption>> _qualityOptionCache = {};
  String _qualityResolveToken = '';
  String _spiderResolveToken = '';

  /// 切换全屏模式 - 对应 Swift onToggleFullScreen
  void toggleFullScreen() {
    isFullScreen.value = !isFullScreen.value;
  }

  /// 设置跳过片头秒数
  Future<void> setSkipIntroSeconds(int seconds) async {
    skipIntroSeconds.value = seconds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('skip_intro_seconds', seconds);
  }

  /// 设置跳过片尾秒数
  Future<void> setSkipOutroSeconds(int seconds) async {
    skipOutroSeconds.value = seconds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('skip_outro_seconds', seconds);
  }

  /// 加载持久化的跳过时间
  Future<void> loadSkipDurations() async {
    final prefs = await SharedPreferences.getInstance();
    skipIntroSeconds.value = prefs.getInt('skip_intro_seconds') ?? 0;
    skipOutroSeconds.value = prefs.getInt('skip_outro_seconds') ?? 0;
  }

  @override
  void onInit() {
    super.onInit();
    loadSkipDurations();
    // 非视频源记录（小说 / 漫画源）：读出来后再次进入这些源就不占 4:3 播放区
    _loadNonVideoSources();
    // 监听 lifecycle：应用从后台/锁屏切回前台时强制重置 isLoading
    // 并重新加载详情（避免旧 dio in-flight 请求卡住 isLoading）
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    // 详情页销毁：清掉嗅探会话残留，避免下次打开详情页被误判为"正在嗅探"
    sniffingUrl.value = null;
    SniffPlayerPage.pendingUrl.value = null;
    if (_sniffCloseHooked) {
      SniffPlayerPage.closedTick.removeListener(_onSniffPageClosed);
    }
    super.onClose();
  }

  /// 是否已挂上"嗅探页关闭"监听（只挂一次）
  bool _sniffCloseHooked = false;

  void _hookSniffPageClosed() {
    if (_sniffCloseHooked) return;
    _sniffCloseHooked = true;
    SniffPlayerPage.closedTick.addListener(_onSniffPageClosed);
  }

  /// 嗅探页**关闭**了（无论是不是本页 push 的）⇒ 结束"嗅探中"态。
  ///
  /// ⚠️ 为什么不能只靠 `_autoSniff` 里那次 `await Get.to(...)`：
  ///   嗅探页被**复用重载**时（`pendingUrl`），await 对应的那次早已返回，
  ///   没人再清 `sniffingUrl` ⇒ 详情页播放区会**永久**停在
  ///   "正在嗅探视频地址…"的黑底占位上（不报错、不超时，只能退出重进）。
  void _onSniffPageClosed() {
    if (isClosed) return;
    final u = sniffingUrl.value;
    if (u == null) return; // 已经收尾过（首次 push 那条路径也会清）
    sniffingUrl.value = null;
    // 从嗅探页返回：改用网页本身兜底（原行为：能直接看网页）
    if ((playUrl.value ?? '').isEmpty) {
      playUrl.value = u;
      playbackSessionId.value = _newUuid();
      isPlaying.value = true;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 作废后台期间可能仍在飞的详情请求
      _detailLoadToken++;
      isLoading.value = false;
      final info = vodInfo.value;
      // 如果之前已经加载过详情但因为 dio 死连接而 vodInfo 是 null 或 playUrl 是 null，
      // 在切回前台时主动重新触发一次加载/解析
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (isClosed) return;
        // 优先解析播放 URL（如果 detail 已有但 playUrl 没解析出来）
        if (info != null && playUrl.value == null) {
          final episode = info.currentEpisode;
          if (episode != null) {
            updateQualityOptions(episode.url, resetSelection: false);
            if (isSpiderSource) {
              _resolveSpiderPlayUrl(flag: selectedFlag.value, id: episode.url);
            }
          }
        }
      });
    }
  }

  List<Episode> get currentEpisodes =>
      vodInfo.value?.playUrlMap[selectedFlag.value] ?? [];

  List<String> get flags => vodInfo.value?.playFlags ?? [];

  bool get hasQualityChoices => qualityOptions.length > 1;

  bool get isSpiderSource {
    final sourceKey = vodInfo.value?.sourceKey;
    if (sourceKey == null) return false;
    return ApiConfig.instance.getSource(sourceKey)?.isSpiderSource ?? false;
  }

  /// 本页能不能「换源」（在当前源内重新搜索、挑正确结果）。
  ///
  /// ⚠️ 与 [isSpiderSource]（= `type == 3`，**播放入口分流**在用）**分开**：
  ///   那个判据决定"播放地址走 Spider 取址还是 CMS 直取"，不能动。
  ///   这个只决定"详情页那个 🔁 按钮显不显示"。
  ///
  /// 为什么不能继续用 `type == 3`（用户 2026-10-15：
  /// 「默认详情页里面那个换源按钮是不是没了？」）：
  ///   · 换源弹窗（`_showSpiderPickDialog`）自己的前置条件只有一条 ——
  ///     **当前有可用的 Spider 上下文 key**（key 为空才提示"当前源不是 Spider 源"）；
  ///   · 而 `type == 4` 的 TVBox / 远程接口线路**同样是脚本引擎在跑**
  ///     （日志实证：`setCurrentSpider: key=…, type=4` + `/spider/<key>/4/…`），
  ///     换源对它一样有用，却因为 type≠3 被整块隐藏了；
  ///   · 另外从历史/收藏进来时 `sourceKey` 可能已不在当前订阅的线路表里
  ///     （`getSource` 返回 null）⇒ `isSpiderSource` 也被动变 false，按钮消失。
  /// 所以这里改成与弹窗**同一个口径**：脚本引擎驱动的源（3/4）且当前 key 非空。
  bool get canSwitchSourceInPage {
    final t = ApiConfig.instance.getSource(vodInfo.value?.sourceKey ?? '')?.type;
    if (t != null && t != 3 && t != 4) return false; // CMS(0/1) 等：本页换源不适用
    return SpiderService.instance.getCurrentSpiderInfo().key.trim().isNotEmpty;
  }

  /// 详情加载代次：切页/切片时递增，过期响应直接丢弃
  int _detailLoadToken = 0;

  Future<void> loadDetail(Video video) async {
    final source = ApiConfig.instance.getSource(video.sourceKey) ??
        ApiConfig.instance.homeSourceBean.value;
    if (source == null) return;

    final token = ++_detailLoadToken;
    isLoading.value = true;
    errorMessage.value = null;

    try {
      final info = await SourceService.instance.getDetail(source, video.id);
      if (token != _detailLoadToken || isClosed) return;
      if (info != null) {
        // ── Webhtv 站点健康：详情加载成功（Webhtv → 站点健康排序）
        SiteHealthStore.instance.record(source.key, 'detail', true);
        vodInfo.value = info;
        // 恢复上次选择的播放源（线路）：用户要求每次重进详情页都用
        // 上次选的源，而不是每次都回到第一个。源更新链接后旧 flag
        // 不在 playFlags 里，自然回退到第一个。
        final remembered = await _rememberedFlag();
        if (remembered != null && info.playFlags.contains(remembered)) {
          info.playFlag = remembered;
        }
        selectedFlag.value = info.playFlag;
        selectedEpisodeIndex.value = info.playIndex;
        resumeSeconds.value = 0;
        _realtimeProgressSeconds = 0;

        final episode = info.currentEpisode;
        if (episode != null) {
          updateQualityOptions(episode.url, resetSelection: true);
        } else {
          resetQualityState();
        }
      }
    } catch (e) {
      SiteHealthStore.instance.record(source.key, 'detail', false);
      if (token == _detailLoadToken) {
        errorMessage.value = e.toString();
      }
    }

    if (token == _detailLoadToken) {
      isLoading.value = false;
    }
  }

  static const _playFlagPrefix = 'play_flag_';

  /// 记住当前选择的播放源（线路）：下次重进详情页恢复。
  /// 键 = `play_flag_{sourceKey}|{id}`；「清除全部缓存」时统一重置。
  Future<void> _rememberFlag(String flag) async {
    final info = vodInfo.value;
    if (info == null || info.sourceKey.isEmpty || flag.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_playFlagPrefix${info.sourceKey}|${info.id}', flag);
    } catch (_) {}
  }

  /// 读取上次选择的播放源；无记忆 / 源已变更时返回 null（调用方回退第一个）。
  Future<String?> _rememberedFlag() async {
    final info = vodInfo.value;
    if (info == null || info.sourceKey.isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('$_playFlagPrefix${info.sourceKey}|${info.id}');
    } catch (_) {
      return null;
    }
  }

  void selectFlag(String flag) {
    if (selectedFlag.value == flag) return;

    // 先记住当前进度：切线路/换源的语义是「换条线路接着看这一集」，
    // 不是从头开始。与 selectQuality 用同一套进度快照（currentPlaybackSeconds）。
    final progress = currentPlaybackSeconds();
    final keepSeconds = progress > 0 ? progress : 0.0;
    final currentIndex = selectedEpisodeIndex.value;

    isPlaying.value = false;
    playUrl.value = null;
    playHeaders.clear();
    _failedPlayUrls.clear(); // 换源线路：失败记录清零

    selectedFlag.value = flag;
    vodInfo.value?.playFlag = flag;
    // 记住源选择：下次重进详情页恢复（清除全部缓存时重置）
    _rememberFlag(flag);
    // 恢复到刚才的位置，而不是清零
    resumeSeconds.value = keepSeconds;
    _realtimeProgressSeconds = keepSeconds;

    final episodes = vodInfo.value?.playUrlMap[flag] ?? [];
    if (episodes.isEmpty) {
      selectedEpisodeIndex.value = 0;
      vodInfo.value?.playIndex = 0;
      resetQualityState();
      return;
    }

    final targetIndex = currentIndex.clamp(0, episodes.length - 1);
    selectedEpisodeIndex.value = targetIndex;
    vodInfo.value?.playIndex = targetIndex;
    final episodeURL = episodes[targetIndex].url;
    updateQualityOptions(episodeURL, resetSelection: true);

    // ⚠️ 这里**不能**按「切换前是否在播」提前 return。
    // 旧实现在暂停状态下切线路会直接返回：playUrl 停在 null → 播放区永远转圈，
    // 15 秒后被超时兜底报成「播放地址获取超时」。而用户点另一条线路的语义就是
    // 「换条线路接着看」，所以与 selectEpisode 保持一致：解析到地址就开播。
    if (isSpiderSource) {
      _resolveSpiderPlayUrl(flag: flag, id: episodeURL);
    } else {
      playHeaders.clear();
      unawaited(_startPlayback(episodeURL));
    }
  }

  void selectEpisode(int index) {
    final episodes = currentEpisodes;
    if (index < 0 || index >= episodes.length) return;
    // 同一集且已在播才忽略；换集永远要触发
    final sameEp = selectedEpisodeIndex.value == index && isPlaying.value;
    if (sameEp) return;

    isPlaying.value = false;
    playUrl.value = null;
    playHeaders.clear();
    resumeSeconds.value = 0;
    _realtimeProgressSeconds = 0;
    _failedPlayUrls.clear(); // 换集：失败记录清零，新集重新给机会

    selectedEpisodeIndex.value = index;
    vodInfo.value?.playIndex = index;

    final episode = vodInfo.value?.currentEpisode;
    if (episode != null) {
      final shouldResetQuality = _qualityBaseEpisodeURL != episode.url;
      updateQualityOptions(episode.url, resetSelection: shouldResetQuality);

      if (isSpiderSource) {
        _resolveSpiderPlayUrl(flag: selectedFlag.value, id: episode.url);
      } else {
        playHeaders.clear();
        unawaited(_startPlayback(episode.url));
      }
    }
  }

  void applyPlaybackState(VodPlaybackState state) {
    final info = vodInfo.value;
    if (info == null || info.playFlags.isEmpty) return;

    final fallbackFlag =
        info.playFlag.isEmpty ? info.playFlags[0] : info.playFlag;
    final targetFlag =
        info.playFlags.contains(state.flag) ? state.flag : fallbackFlag;

    selectedFlag.value = targetFlag;
    info.playFlag = targetFlag;

    final episodes = info.playUrlMap[targetFlag] ?? [];
    if (episodes.isEmpty) return;

    final targetIndex = state.episodeIndex.clamp(0, episodes.length - 1);
    selectedEpisodeIndex.value = targetIndex;
    info.playIndex = targetIndex;
    _failedPlayUrls.clear(); // 恢复播放（换集/换线路）：失败记录清零

    final progress = state.progressSeconds > 0 ? state.progressSeconds : 0.0;
    resumeSeconds.value = progress;
    _realtimeProgressSeconds = progress;
    final episodeURL = episodes[targetIndex].url;
    updateQualityOptions(episodeURL, resetSelection: true);

    if (isSpiderSource) {
      _resolveSpiderPlayUrl(flag: targetFlag, id: episodeURL);
    } else {
      unawaited(_startPlayback(episodeURL));
    }
  }

  void selectQuality(PlaybackQualityOption option) {
    if (!qualityOptions.contains(option)) return;
    selectedQualityId.value = option.id;
    if (!isPlaying.value) return;

    final targetURL =
        option.url.isEmpty ? _qualityBaseEpisodeURL : option.url;
    if (targetURL.isEmpty || playUrl.value == targetURL) return;

    final progress = currentPlaybackSeconds();
    resumeSeconds.value = progress > 0 ? progress : 0;
    _realtimeProgressSeconds = resumeSeconds.value;
    playUrl.value = targetURL;
    playbackSessionId.value = _newUuid();
  }

  void updatePlaybackProgress(double seconds) {
    if (!seconds.isFinite) return;
    _realtimeProgressSeconds = seconds > 0 ? seconds : 0;
  }

  double currentPlaybackSeconds() {
    return _realtimeProgressSeconds > resumeSeconds.value
        ? _realtimeProgressSeconds
        : resumeSeconds.value;
  }

  void commitPlaybackProgressSnapshot() {
    final snapshot = _realtimeProgressSeconds > 0 ? _realtimeProgressSeconds : 0;
    if ((snapshot - resumeSeconds.value).abs() >= 1) {
      resumeSeconds.value = snapshot.toDouble();
    }
  }

  /// 播放器侧上报的错误（原生 onError / 播放失败 / 地址解析超时）
  ///
  /// 播放器错误以前只走到 DetailView 的空回调，用户看到的是白转圈。
  /// 这里统一落进 errorMessage，由详情页错误态渲染。
  ///
  /// 2026-10-15：直链 403/404/超时**先自动顺延**同集的其它候选地址
  /// （多清晰度 / 多线路，见 [updateQualityOptions]），全部试完才把错误
  /// 抛给界面 —— 原来一失败就要用户手动切线路。
  void setPlaybackError(String message) {
    // ── Webhtv 站点健康：播放失败记一笔（只有"失败"这一半，见站点健康页说明）
    SiteHealthStore.instance.record(
      SpiderService.instance.getCurrentSpiderInfo().key,
      'play',
      false,
    );
    if ((playUrl.value ?? '').isNotEmpty && _advanceToNextCandidate()) return;
    errorMessage.value = message;
    isPlaying.value = false;
  }

  /// 本集内已被判定失败的地址（按 URL 去重，防止在多个同址候选间打转）
  final Set<String> _failedPlayUrls = <String>{};

  /// 顺延到下一条未试过的候选地址；没有则返回 false。
  bool _advanceToNextCandidate() {
    final current = playUrl.value ?? '';
    if (current.isNotEmpty) _failedPlayUrls.add(current);

    final next = qualityOptions.firstWhereOrNull(
        (o) => o.url.isNotEmpty && !_failedPlayUrls.contains(o.url));
    if (next == null) return false;

    AppLog.instance.log(
        '[Play] 播放失败 → 自动换线路「${next.name}」: ${next.url}');
    selectedQualityId.value = next.id;
    playUrl.value = next.url;
    playbackSessionId.value = _newUuid();
    isPlaying.value = true;
    return true;
  }

  /// 播放/解析失败后用户点「重试」：重新解析当前集的播放地址。
  ///
  /// 与「重新加载详情」不同 —— 详情通常已经加载成功（vodInfo 非空），
  /// 失败只发生在拿到播放地址这一步，所以这里只重解地址，不重拉详情。
  void retryCurrentEpisode() {
    final info = vodInfo.value;
    if (info == null) {
      isLoading.value = false;
      return;
    }
    errorMessage.value = null;
    playUrl.value = null;
    isPlaying.value = false;
    // 复位"解析中"标记：避免上一次解析异常退出后标志悬挂，
    // 导致详情页永不报"地址获取超时"而卡在转圈。
    isResolving.value = false;
    _failedPlayUrls.clear(); // 用户手动重试：允许重新尝试所有候选

    final flag = selectedFlag.value;
    final episodes = info.playUrlMap[flag] ?? [];
    final index = selectedEpisodeIndex.value;
    if (index < 0 || index >= episodes.length) {
      errorMessage.value = '当前线路没有可播放的剧集';
      return;
    }
    final episode = episodes[index];
    if (episode.url.isEmpty) {
      errorMessage.value = '当前剧集地址为空，请切换其他线路';
      return;
    }
    // 用户点「重试」= 要重新解析：先让这个地址的解析缓存失效。
    // 解析出的 m3u8 常带时效签名，若还命中 10 分钟内的旧缓存，会陷入
    // "点重试 → 同一个坏地址 → 再失败" 的死循环（2026-10-15 深挖发现）。
    ParseService.instance.invalidate(episode.url);

    if (episode.url.startsWith('/')) {
      _resolveSpiderPlayUrl(flag: flag, id: episode.url);
    } else {
      unawaited(_startPlayback(episode.url));
    }
  }

  // ============================================================
  // 底栏「嗅探 / 解析」按钮
  // ============================================================

  /// 当前集从 Spider 拿到的**原始**播放地址（未经解析 / 嗅探）。
  /// 「嗅探」按钮用它 —— 已经解析成直链后再嗅探没有意义。
  String _rawPlayUrl = '';
  String get rawPlayUrl => _rawPlayUrl;

  /// 用户是否**主动**在「解析 / 嗅探」面板里选过解析线路（2026-10-28）。
  ///
  /// 为什么需要：Spider / 聚合源常自带一个解析地址（`parse:1`，如
  /// `…/jiexi.php?url=<爱奇艺页面>`），旧逻辑会**跳过 App 自己的解析**
  /// 直接打开它 —— 那个解析站一旦「IP 使用次数超限」，用户就彻底没法播。
  /// 用户在面板里选了线路，就表示「用我的解析线路」，这里据此强制走
  /// [ParseService]（并把解析站地址里 `url=` 的内层原始地址取出来重新解）。
  bool _forceUserParse = false;

  /// 从解析站地址里取出内层原始地址（`?url=` / `?v=`），取不到原样返回。
  ///
  /// 例：`https://www.playm3u8.cn/jiexi.php?url=https://v.qq.com/x/1.html`
  /// → `https://v.qq.com/x/1.html`。这样换成用户的线路时，解的是**原始页面**
  /// 而不是「解析站的解析结果」。
  String _innerUrlOf(String url) {
    try {
      final uri = Uri.tryParse(url.trim());
      if (uri == null) return url;
      for (final k in const ['url', 'v', 'vid', 'link', 'u']) {
        final inner = uri.queryParameters[k];
        if (inner != null && inner.trim().isNotEmpty) {
          final v = inner.trim();
          if (v.startsWith('http://') || v.startsWith('https://')) return v;
        }
      }
    } catch (_) {}
    return url;
  }

  /// 底栏「嗅探」：**手动**入口，打开独立嗅探页（可换解析 / 重新嗅探）。
  ///
  /// ⚠️ 自动流程（源返回网页播放页时）**不再**走这里，也不再 push 任何
  /// 新页面：网页直接内嵌在详情页播放区里加载，后台嗅探命中后同页切原生
  /// 播放器（见 [onWebviewMediaFound]）。这里只服务用户显式点「嗅」的场景。
  void openSniff() {
    final url = sanitizePlayUrl(
        _rawPlayUrl.isNotEmpty ? _rawPlayUrl : (playUrl.value ?? ''));
    if (!url.startsWith('http')) {
      AppToast.message('当前地址不是网页，无法嗅探');
      return;
    }
    // 手动嗅探页关闭后收尾「嗅探中」标记（自动流程已不再 push 本页）
    _hookSniffPageClosed();
    // 底层正挂着网页播放器时，先让播放区让位：否则本页与嗅探页各跑一份
    // 同一个网页（双份解码/声音）。底层是原生直链时不打断（继续播）。
    final current = playUrl.value ?? '';
    if (current.isNotEmpty && !_looksLikeDirectMedia(current)) {
      sniffingUrl.value = url;
    }
    Get.to(() => SniffPlayerPage(
          url: url,
          title: vodInfo.value?.name,
          headers:
              playHeaders.isEmpty ? null : Map<String, String>.from(playHeaders),
        ));
  }

  /// 内嵌网页播放器**后台嗅探**到直链 → 同页切原生播放器（2026-10-28）。
  ///
  /// 用户要求：「后台嗅探出来用我的播放器播放，不要重新给个页面」。
  /// 这里只改 `playUrl`，详情页播放区会从 [WebviewPlayerPage] 换成
  /// `AppPlayer`，全程停在详情页，不 push 任何新页面。
  void onWebviewMediaFound(String url) {
    if (url.isEmpty) return;
    final h = <String, String>{...playHeaders};
    if (PlayerPrefs.instance.sniffSendReferer.value) {
      final page = playUrl.value ?? '';
      if (page.isNotEmpty && page != url) h.putIfAbsent('Referer', () => page);
    }
    AppLog.instance.log('[Play] 网页后台嗅探命中 → 原生播放器: $url');
    if (h.isNotEmpty) playHeaders.value = h;
    sniffingUrl.value = null;
    isWebSniffing.value = false;
    _clearSniffGaveUp();
    // 嗅探命中 = 已确认是媒体：即使地址没后缀也直接交原生播放器
    confirmedMediaUrl.value = url;
    playUrl.value = url;
    playbackSessionId.value = _newUuid();
    isPlaying.value = true;
  }

  /// 后台嗅探**放弃**（轮询到上限仍未命中）→ 浮层换静态提示。
  /// 4 秒后自动消失，避免一直占着播放区。
  void onWebviewSniffGaveUp() {
    if (sniffGaveUp.value) return;
    sniffGaveUp.value = true;
    _sniffGaveUpTimer?.cancel();
    _sniffGaveUpTimer = Timer(const Duration(seconds: 4), () {
      // GetxController 没有 mounted，用 isClosed 判断是否已被销毁
      if (!isClosed && sniffGaveUp.value) sniffGaveUp.value = false;
    });
  }

  void _clearSniffGaveUp() {
    _sniffGaveUpTimer?.cancel();
    if (sniffGaveUp.value) sniffGaveUp.value = false;
  }

  /// 解析结果落播放地址时，按「播放带 Referer」开关补一次 Referer（P2-2）。
  ///
  /// 原来只有「嗅探命中」（[onWebviewMediaFound]）会补 Referer；解析链路只在
  /// 解析接口自带 `ext.header` 时才带 —— 用户在设置里打开的「播放带 Referer」
  /// 对解析结果不生效。这里统一：开关打开时用「解析前的原始页面地址」当
  /// Referer（防盗链最常校验的正是它），已有 Referer 时不覆盖。
  void _applySniffReferer(Map<String, String> headers, String pageUrl) {
    if (!PlayerPrefs.instance.sniffSendReferer.value) return;
    final page = pageUrl.trim();
    if (page.isEmpty) return;
    headers.putIfAbsent('Referer', () => page);
  }

  /// 底栏「解析」选中某条线路后：记住选择，并用新线路**重解当前集**。
  /// 传空串 = 自动（按列表顺序依次尝试）。
  ///
  /// 2026-10-28：同时置 `_forceUserParse` —— 用户既然主动选了线路，
  /// 即使是「源自带解析地址」的聚合源，也要改用**用户的解析管理**重解。
  Future<void> selectParseLine(String url) async {
    await ParseStore.instance.setActive(url);
    ApiConfig.instance.parseBeanList.value = ParseStore.instance.list;
    // 用户主动选线路 = 明确要用解析：解析总开关若关着，顺手打开，
    // 否则 ParseService.enabled 为 false，选了也不生效（2026-10-28）。
    if (!PlayerPrefs.instance.parseEnabled.value) {
      await PlayerPrefs.instance.setParseEnabled(true);
    }
    // 选过线路 = 以后都优先用自己的线路（持久化，重启后仍然生效）；
    // 想改回"尊重脚本内置解析"在面板里把开关打开即可（2026-10-28）。
    if (PlayerPrefs.instance.preferScriptParse.value) {
      await PlayerPrefs.instance.setPreferScriptParse(false);
    }
    _forceUserParse = true;
    AppLog.instance.log('[Parse] 切换解析线路 → ${url.isEmpty ? '自动' : url}');
    retryCurrentEpisode();
  }

  bool playNext() {
    final info = vodInfo.value;
    if (info == null) return false;
    final episodes = info.currentEpisodes;
    if (selectedEpisodeIndex.value + 1 < episodes.length) {
      selectEpisode(selectedEpisodeIndex.value + 1);
      return true;
    }
    return false;
  }

  bool playPrevious() {
    if (selectedEpisodeIndex.value > 0) {
      selectEpisode(selectedEpisodeIndex.value - 1);
      return true;
    }
    return false;
  }

  void _resolveSpiderPlayUrl({required String flag, required String id}) {
    final token = _newUuid();
    _spiderResolveToken = token;

    // 每次重解都先按"视频"假设 —— 真正形态等 playerContent 返回后按协议定：
    //   novel:// → 正文；pics:// / mange:// → 图片；其余 → 视频。
    // （内容形态决定详情页要不要占那块 4:3 播放区）
    contentMode.value = PlayContentMode.video;

    // 获取当前 Spider 的 key/type/api/ext
    final spiderInfo = SpiderService.instance.getCurrentSpiderInfo();
    // **2026-09-26 修复**：从历史/收藏直接进入 Spider 源详情时，
    // 当前 Spider 上下文可能未设置（key 为空）。此时不再请求
    // Spider 服务（路径会是非法 / /type/play），而是降级为把
    // 集数 URL 当作直链直接播放，避免进入详情页崩溃/黑屏。
    if (spiderInfo.key.isEmpty) {
      final looksLikeUrl =
          id.startsWith('http://') || id.startsWith('https://');
      if (!looksLikeUrl) {
        // 不是直链，播了也是黑屏：给出可操作的提示，而不是静默失败
        errorMessage.value = 'Spider 上下文缺失，无法解析播放地址（请从首页重新进入该源）';
        isPlaying.value = false;
        return;
      }
      playUrl.value = id;
      playHeaders.value = <String, String>{};
      playbackSessionId.value = _newUuid();
      isPlaying.value = true;
      return;
    }

    () async {
      // 取址期间就挂上"解析中"标记：详情页据此**不启动** 15 秒"地址获取超时"
      //  ——Spider 的 getPlayUrl 最坏可达 60 秒，原来这期间 isResolving 还是 false，
      //  首帧就会建出 15 秒计时器 ⇒ 正常解析中被误报"播放地址获取超时"。
      isResolving.value = true;
      try {
        final result =
            await SpiderService.instance.getPlayUrl(
          spiderInfo.key, spiderInfo.type, spiderInfo.api,
          flag, id,
          ext: spiderInfo.ext);

        if (_spiderResolveToken != token) return;
        if (result == null) {
          errorMessage.value = 'Spider播放地址解析失败';
          return;
        }

        var headers = <String, String>{};
        if (result['header'] != null) {
          final headerDict = result['header'];
          if (headerDict is Map<String, String>) {
            headers = headerDict;
          } else if (headerDict is Map) {
            for (final entry in headerDict.entries) {
              headers[entry.key.toString()] = entry.value.toString();
            }
          }
        }

        String? resolvedUrl;
        final urlValue = result['url'];        if (urlValue is String && urlValue.isNotEmpty) {
          resolvedUrl = urlValue;
        } else if (urlValue is List) {
          for (int i = 0; i < urlValue.length - 1; i += 2) {
            if (i + 1 >= urlValue.length) break;
            final urlStr = urlValue[i + 1].toString();
            if (urlStr.isNotEmpty) {
              resolvedUrl = urlStr;
              break;
            }
          }
        }

        if (_spiderResolveToken != token) return;

        // ── 源声明的播放形态（CatVod 约定）──────────────────────────
        //   `parse == 0` → `url` 就是**可直接播放的直链**
        //   `parse == 1` → `url` 是**需要解析/嗅探的网页**
        //   （`jx` 是同一语义的旧字段，两个都认；缺失按"未声明"处理）
        //
        // 🔴 原来这两个字段**完全没读**，只按"地址有没有影视后缀"猜。
        // 两头都会错：
        //   · `parse:0` + 无后缀直链 —— 典型是解析接口直接吐 m3u8 文本
        //     （`nm_free.php?url=…`）。被判成网页 → 塞进 WebView 嗅探 →
        //     打开的是 m3u8 文本页，**必然失败**；
        //   · `parse:1` + 网页恰好落在主流站点域名下 → App 又用自己的
        //     解析接口解一遍，可能把源已经给好的地址解歪。
        final parseFlag = _intFlag(result['parse']);
        final jxFlag = _intFlag(result['jx']);
        final sourceWantsParse = parseFlag == 1 || jxFlag == 1;
        final sourceSaysDirect = !sourceWantsParse && parseFlag == 0;

        if (resolvedUrl != null && resolvedUrl.isNotEmpty) {
          // 先剥掉 `类型|哈希|真实URL` 包裹（如 `tencent|54e3…|https://…`），
          // 再补全相对路径 —— 顺序反了会把整串拼到站点域名后面（2026-10-28）。
          resolvedUrl = sanitizePlayUrl(resolvedUrl);
          // 相对播放地址 → 用源 api 的 host 补成绝对（方案 B，见 [_absolutizePlayUrl]）
          resolvedUrl = _absolutizePlayUrl(resolvedUrl);
          // 记下 Spider 给的地址（底栏「嗅探」按钮要用）—— 记**补全后**的形态，
          // 否则嗅探页/播放器拿到相对路径同样加载不了
          _rawPlayUrl = resolvedUrl;
          // **按内容分流①：正文协议**（小说源，`novel://{title,content}`）
          // —— 这类源给出的"播放地址"其实是整章正文，交给播放器只会黑屏，
          // 所以直接进简易书籍阅读器。
          final novel = parseNovelUrl(resolvedUrl);
          if (novel != null && novel.content.trim().isNotEmpty) {
            contentMode.value = PlayContentMode.text;
            unawaited(_rememberNonVideoSource());
            playUrl.value = resolvedUrl;
            playHeaders.value = headers;
            playbackSessionId.value = _newUuid();
            isPlaying.value = true;
            AppLog.instance.log(
                '[Play] 正文协议 → 书籍阅读器（${novel.content.length} 字）');
            SimpleTextReaderPage.open(
              content: novel.content,
              bookName: vodInfo.value?.name ?? '',
              chapterName: novel.title.isNotEmpty
                  ? novel.title
                  : (vodInfo.value?.currentEpisode?.name ?? ''),
            );
            return;
          }
          // **按内容分流②：图片列表协议**（漫画 / 图源，`pics://` / `mange://…`）
          // —— 这类源给出的"播放地址"其实是整章图片，交给播放器只会黑屏，
          // 所以直接进简易看图阅读器（用户 2026-10-14）。
          // playUrl 仍记下这个地址（`contentMode` 已置为非视频 → 详情页那块
          // 4:3 播放区直接不占面积）。
          final pictures = parseImageListUrl(resolvedUrl);
          if (pictures != null && pictures.isNotEmpty) {
            contentMode.value = PlayContentMode.pictures;
            unawaited(_rememberNonVideoSource());
            playUrl.value = resolvedUrl;
            playHeaders.value = headers;
            playbackSessionId.value = _newUuid();
            isPlaying.value = true;
            AppLog.instance.log(
                '[Play] 图片列表协议 → 看图阅读器（${pictures.length} 张）');
            SimpleImageReaderPage.open(
              title: vodInfo.value?.name ?? '',
              images: pictures,
              chapterName: vodInfo.value?.currentEpisode?.name ?? '',
              headers: headers,
            );
            return;
          }
          // 播放地址分流（按站点性质决定要不要先解析）：
          //   ① **优爱腾芒B 等主流正版站** —— 有防盗链/加密，直接嗅探拿到的
          //      地址通常播不了 ⇒ **先用解析接口解一遍**；解析结果无论
          //      "直链"还是"新的网页地址"都采用（新的网页再交给嗅探兜底）；
          //   ② **其它站点** —— 不做解析，**直接交给 WebView 嗅探**从页面上
          //      抓媒体地址（省一次请求，也避免被解析接口解歪）。
          var playCandidate = resolvedUrl;
          // 2026-10-15：是否解析改由 SniffFilter 统一判定（内置主流站点 +
          // 用户在「播放设置 → 嗅探设置」里追加的域名，减去屏蔽域名）。
          // 2026-10-28：不再要求用户先打开「解析总开关」——只要配了解析接口，
          // 遇到网页播放页就**自动用解析接口解一次**（用户说的「内置牛马解析」
          // 那种：解析链接 + 官方播放页 → 直接返回 m3u8）。
          // 源声明 parse=1 时解的是它 `?url=` 里的**原始官方页**，避免套娃；
          // 解析失败会原样落回网页（内嵌网页播放器兜底），不比改动前差。
          final userForced =
              _forceUserParse || !PlayerPrefs.instance.preferScriptParse.value;
          final canAppParse = ParseService.instance.enabled ||
              ParseService.instance.hasParsers;
          // 本次地址是否来自 App 的解析接口 —— 决定后面要不要再做一次
          // "响应类型确认"（解析接口爱给无后缀直链，见 `confirmedMediaUrl`）。
          var parsedByApp = false;
          // 解析前的原始页面地址：MIME 确认无后缀直链时当 Referer 用
          //（防盗链解析站校验 Referer 才放行，2026-10-28 深挖）。
          String? appParseReferer;
          if (!_looksLikeDirectMedia(playCandidate) &&
              (sourceWantsParse ||
                  SniffFilter.shouldParse(playCandidate) ||
                  userForced) &&
              canAppParse) {
            isResolving.value = true;
            try {
              final target = (sourceWantsParse || userForced)
                  ? _innerUrlOf(playCandidate)
                  : playCandidate;
              appParseReferer = target;
              final outcome = await ParseService.instance.parseOutcome(
                target,
                only: userForced ? ParseStore.instance.activeBean : null,
              );
              if (outcome != null && outcome.url.isNotEmpty) {
                AppLog.instance.log(
                    '[Play] 「${outcome.sourceName}」解析 → ${outcome.url}'
                    '（${outcome.direct ? "直链" : "仍为网页，转嗅探"}）');
                playCandidate = outcome.url;
                parsedByApp = true;
                // 解析接口自带的请求头（防盗链）随地址一起带上；
                // 源自己给的 header 更具体，不覆盖（2026-10-15）。
                final h = outcome.headers;
                if (h != null && h.isNotEmpty) {
                  headers = {...h, ...headers};
                }
                // 「播放带 Referer」开关打开时，解析结果也补 Referer（P2-2）
                _applySniffReferer(headers, target);
              } else {
                AppLog.instance.log('[Play] 解析接口未命中，转直接嗅探');
              }
            } finally {
              isResolving.value = false;
            }
          }
          if (_spiderResolveToken != token) return;
          playHeaders.value = headers;

          // ── 源声明「这是直链」(parse:0) 但地址没有影视后缀 ──────────
          //
          // 典型：解析接口直接返回 m3u8 文本（`xxx/nm_free.php?url=…`），
          // 地址本身没有 `.m3u8`。按后缀判定会把它当网页丢给嗅探页，
          // 而嗅探页是用 WebView 打开它 —— 打开一个 m3u8 文本页，
          // 什么都播不出来。
          //
          // 这里用**响应类型 + 开头字节**确认一次（`#EXTM3U` / `ftyp`）：
          //   · 是媒体 → 直接交给播放器（本次修复的主要收益）；
          //   · 不是 / 探测失败 → 退回原来的嗅探逻辑，**不比改动前差**。
          var directConfirmed = _looksLikeDirectMedia(playCandidate);
          // 源声明 parse=0，或者地址是**解析接口刚给的** → 都值得确认一次：
          // 解析站常把 m3u8 塞在 `xxx.php?url=…` 这种无后缀地址后面，
          // 光看后缀会误判成网页（2026-10-28）。
          if (!directConfirmed && (sourceSaysDirect || parsedByApp)) {
            isResolving.value = true;
            try {
              // ⚠️ 解析接口刚给的地址 → 带上解析前的原始页面当 Referer：
              // 防盗链解析站（校验 Host/Referer 才放行）不带头会直接 403，
              // Content-Type 拿不到、字节也读不到 → 无后缀直链被误判成网页
              // （2026-10-28 深挖）。
              directConfirmed = await WebSniffService.instance
                  .looksLikeMediaByMime(playCandidate,
                      referer: parsedByApp ? appParseReferer : null);
            } finally {
              if (_spiderResolveToken == token) isResolving.value = false;
            }
            if (_spiderResolveToken != token) return;
            if (directConfirmed) {
              AppLog.instance.log(
                  '[Play] 响应类型确认是媒体 → 直链播放: $playCandidate');
              // 无后缀直链：让详情页别把它当网页塞 WebView
              confirmedMediaUrl.value = playCandidate;
            }
          }

          // ── 网页地址：直接交给内嵌网页播放器（2026-10-28 用户要求）──────
          //   · 不再要求先开「嗅探总开关」——别拿开关卡人；
          //   · 播放不了也要把播放器加载出来（内嵌 WebView 先显示网页）；
          //   · 嗅探在**后台**做，命中 m3u8 后同页切原生播放器，不跳独立页。
          // 所以这里既不发错误提示、也不 push 嗅探页，直接落到下面的
          // `playUrl = playCandidate`（详情页据此挂内嵌 WebviewPlayerPage，
          // 由它后台嗅探并经 onWebviewMediaFound 切回原生播放器）。
          if (!directConfirmed) {
            AppLog.instance.log(
                '[Play] 网页播放页 → 内嵌网页播放器（后台嗅探）: $playCandidate');
          }
          // ── 地址形态兜底（用户 2026-10-15）────────────────────────────
          // 既不是绝对 URL、又补不出 base ⇒ 交给播放器只会白卡 15 秒再弹
          // "加载超时"（实测 `vodplay/223052-1-1.html`）。走 setPlaybackError
          // 的既有机制：先自动顺延同集其它候选，全试完才把原因写给用户。
          if (!_isPlayableShape(playCandidate)) {
            AppLog.instance
                .w('[Play] Spider 播放地址不是完整链接，已拦截: $playCandidate');
            setPlaybackError('该源返回的播放地址不是完整链接：$playCandidate'
                '（源没给域名，也无法用站点地址补全，请切换线路）');
            return;
          }
          playUrl.value = playCandidate;
          playbackSessionId.value = _newUuid();
          isPlaying.value = true;
        } else {
          errorMessage.value = 'Spider播放地址解析失败';
        }
      } catch (e) {
        if (_spiderResolveToken != token) return;
        errorMessage.value = 'Spider播放解析错误: $e';
      } finally {
        // 只有"仍是本次取址"时才清标记（期间又切了集 ⇒ 由新一次接管）
        if (_spiderResolveToken == token) isResolving.value = false;
      }
    }();
  }

  String _selectedPlayableURL({required String fallback}) {
    final selected = qualityOptions
        .firstWhereOrNull((o) => o.id == selectedQualityId.value)
        ?.url;
    if (selected != null && selected.isNotEmpty) {
      return selected;
    }
    return fallback;
  }

  /// 是否已是已知直链媒体（后缀命中）——是则无需再过解析接口。
  ///
  /// 2026-10-15：统一委托 [SniffFilter.isDirectMedia]，它按**用户可自定义**的
  /// 「影视直链后缀」清单判定（空则用出厂 13 种）。原来这里只认 6 种，
  /// `.webm/.mov/.m4s/.mpd/.avi` 等能直接播的地址会被误判成"网页"→ 送去解析
  /// 或被弹去嗅探页，等于白白打断一次播放。
  bool _looksLikeDirectMedia(String url) => SniffFilter.isDirectMedia(url);

  /// 读 `playerContent` 里的 `parse` / `jx` 标志（CatVod 约定）→ int。
  ///
  /// 各家源给的类型五花八门：`1` / `"1"` / `true` / 缺失。
  /// **缺失返回 -1**（不是 0）—— 0 在 CatVod 里是"这是直链"的**明确声明**，
  /// 而"没给这个字段"完全是另一回事，混为一谈会让老源全被当成 parse=0。
  int _intFlag(Object? v) {
    if (v == null) return -1;
    if (v is bool) return v ? 1 : 0;
    if (v is num) return v.toInt();
    final s = v.toString().trim().toLowerCase();
    if (s.isEmpty) return -1;
    if (s == 'true') return 1;
    if (s == 'false') return 0;
    return int.tryParse(s) ?? -1;
  }

  /// 能直接交给播放器/阅读器的**地址形态白名单前缀**。
  ///
  /// ⚠️ 不能只看 `Uri.tryParse(url).hasScheme`：源给的"地址"里常含非法 URI 字符
  /// （`novel://{"title":…}` 这种正文内联、路径带空格、中文未编码…），
  /// `tryParse` 会直接返回 null ⇒ 被误判成"相对路径"→ 要么被拦下、要么被
  /// 拼进站点域名里**拼坏**（实测 `novel://{...}` 就踩这个）。
  /// 所以先按前缀白名单放行，再用 hasScheme 兜住自定义 scheme。
  static const List<String> _kPlayablePrefixes = [
    'http://', 'https://', 'rtmp://', 'rtsp://', 'mms://',
    'x5://', 'novel://', 'pics://', 'mange://', 'manga://',
    'magnet:', 'ed2k://', 'thunder://', 'ftp://', 'file://',
  ];

  /// 是不是"能交给播放器"的地址形态（有 scheme）。
  ///
  /// 裸相对路径（实测 `vodplay/223052-1-1.html`，连 http 都没有）**绝不能**交给
  /// 播放器：原生播放器解析不了 ⇒ `stream error: Operation Stopped` ⇒ 又因为
  /// 既不报 `onError` 也不推进位置，用户只会看到"加载超时 / 点这里重试"卡满
  /// 15 秒（用户 2026-10-15，日志实证）。
  static bool _isPlayableShape(String url) {
    final raw = url.trim();
    if (raw.isEmpty) return false;
    final lower = raw.toLowerCase();
    for (final p in _kPlayablePrefixes) {
      if (lower.startsWith(p)) return true;
    }
    // 兜住白名单之外的合法 scheme（如 `xiaohongshu://…`）
    final u = Uri.tryParse(raw);
    return u != null && u.hasScheme;
  }

  /// 把**相对播放地址**补成绝对 URL（用户 2026-10-15，方案 B）。
  ///
  /// ── 为什么要补 ───────────────────────────────────────────────────
  /// 部分源（实测整包 TVBox / MacCMS 采集站那条线路）的 `play` 返回的是
  /// **相对路径**，如 `vodplay/223052-1-1.html` —— 连 scheme 都没有；
  /// 而 [DetailView._isWebPageUrl] 对无 scheme 的地址返回 false
  /// ⇒ 连"交给 WebView 兜底"都轮不到，直接被丢进原生播放器白卡。
  ///
  /// ── base 为什么取"源 api 的 origin" ───────────────────────────────
  /// 这是 TVBox 的既有约定：相对播放地址按**站点 host** 解析。MacCMS 的
  /// 前台播放页与采集接口**同域**（`https://<host>/vodplay/<id>-<s>-<n>.html`），
  /// 实测该线路的 api 正是 `https://box.miuu.site/api/...`，与 `vodplay/...` 同域。
  ///
  /// ⚠️ 必须取 **origin**、不能是 api 的目录：实测按目录解析会得到
  /// `/api/tvbox/source/vodplay/223052-1-1.html`（错），
  /// 按 origin 才是 `/vodplay/223052-1-1.html`（对）—— 已用 Dart 实跑核对过。
  ///
  /// 补不出来（api 自己都不是绝对地址）时**原样返回**，交给调用方的形态兜底
  /// 给明确提示，而不是让播放器白卡 15 秒。
  String _absolutizePlayUrl(String raw) {
    final s = raw.trim();
    if (s.isEmpty || _isPlayableShape(s)) return s;
    final base = SpiderService.instance.getCurrentSpiderInfo().api.trim();
    if (base.isEmpty) return s;
    final bu = Uri.tryParse(base);
    if (bu == null || !bu.hasScheme) return s; // base 也不绝对：补不了，别硬猜
    try {
      final origin = '${bu.scheme}://${bu.authority}/';
      // 协议相对（`//host/x`）也会被 resolve 正确补上 scheme
      final fixed = Uri.parse(origin).resolve(s).toString();
      if (fixed != s) {
        AppLog.instance.log('[Play] 相对播放地址补全: $s → $fixed（站点 $origin）');
      }
      return fixed;
    } catch (_) {
      return s;
    }
  }

  /// `_startPlayback` 的代次号。
  ///
  /// 普通链路（CMS / 直链）也要防"旧结果顶掉新集"：解析接口是 await 的，
  /// 快速连点两集时，先发起那次回来后会**无条件**写 `playUrl` —— 表现就是
  /// "点了下一集，画面又跳回上一集"。Spider 链路早有 `_spiderResolveToken`，
  /// 这里补上同一套。
  String _playbackStartToken = '';

  /// 取流/播放入口统一入口：在 [_selectedPlayableURL] 基础上接入广告过滤与解析接口。
  ///
  /// - 命中广告黑名单 → 回退到 fallback（沿用既有回退语义，不抛弃原地址）；
  /// - 非直链媒体后缀且解析器可用 → 走 parses 接口，成功替换、失败保持原地址。
  ///
  /// 无 ads/rules 且无 parses 时，方法内不产生 await，行为与原来的同步赋值一致。
  Future<void> _startPlayback(String fallback) async {
    final token = _newUuid();
    _playbackStartToken = token;
    // 走这里的都是普通视频链路（CMS 源 / 直链），形态复位成"视频"
    contentMode.value = PlayContentMode.video;
    var candidate = _selectedPlayableURL(fallback: fallback);
    // 先剥掉 `类型|哈希|真实URL` 包裹（TVBox 社区源常见）：必须在补全**之前**，
    // 否则会被当成相对路径拼到站点域名后面，彻底解不出真实地址（2026-10-28）。
    candidate = sanitizePlayUrl(candidate);
    // 相对播放地址 → 用源 api 的 host 补成绝对（方案 B，见 [_absolutizePlayUrl]）
    candidate = _absolutizePlayUrl(candidate);

    if (AdFilterService.instance.isBlocked(candidate) &&
        candidate != fallback) {
      candidate = fallback;
    }

    // 2026-10-15：是否解析统一由 SniffFilter 判定（内置主流站点 +
    // 用户追加域名 - 屏蔽域名）。
    // 2026-10-28：不再要求先打开「解析总开关」——只要配了解析接口，遇到
    // 网页播放页就自动用解析接口解一次（「内置牛马解析」那种直接出 m3u8）。
    // 用户在面板里主动选过线路、或关掉「脚本内置解析优先」时强制走用户线路。
    final userForced =
        _forceUserParse || !PlayerPrefs.instance.preferScriptParse.value;
    final canAppParse =
        ParseService.instance.enabled || ParseService.instance.hasParsers;
    var parsedByApp = false;
    if (!_looksLikeDirectMedia(candidate) &&
        (SniffFilter.shouldParse(candidate) || userForced) &&
        canAppParse) {
      // 解析期间挂"解析中"标记：详情页据此显示文案，且不启动 15 秒
      // "地址获取超时"计时（解析慢时误报错误会打断观看）。
      isResolving.value = true;
      try {
        final target = userForced ? _innerUrlOf(candidate) : candidate;
        final outcome = await ParseService.instance.parseOutcome(
          target,
          only: userForced ? ParseStore.instance.activeBean : null,
        );
        // 期间又切了集 / 换了线路 ⇒ 这次结果作废（别把新集顶回去）
        if (_playbackStartToken != token) return;
        if (outcome != null && outcome.url.isNotEmpty) {
          // 直链直接播；解析出的是另一个网页播放页 → 换它继续走自动嗅探
          candidate = outcome.url;
          parsedByApp = true;
          // 解析接口的请求头（防盗链）随地址带上；已有的（源给的）优先
          final h = outcome.headers;
          final merged = <String, String>{...?h, ...playHeaders};
          // 「播放带 Referer」开关打开时，解析结果也补 Referer（P2-2）
          _applySniffReferer(merged, target);
          playHeaders.value = merged;
        }
      } finally {
        // 只有"仍是本次"才清（期间又切集 ⇒ 标记归新一次管，别提前清掉）
        if (_playbackStartToken == token) isResolving.value = false;
      }
    }

    // 期间又切了集/换了线路 ⇒ 这次作废（否则会把新集的地址覆盖掉）
    if (_playbackStartToken != token) return;

    // ── 解析接口给的地址：确认它到底是不是媒体 ────────────────────────
    // 解析站常把 m3u8 塞在 `xxx.php?url=…` 这种**无后缀**地址后面，
    // 光看后缀会判成网页 → 塞进 WebView 打开一个 m3u8 文本页（黑屏）。
    // 这里用 Content-Type + 首字节确认一次，是媒体就直接交给原生播放器。
    if (parsedByApp && !_looksLikeDirectMedia(candidate)) {
      isResolving.value = true;
      try {
        final ok = await WebSniffService.instance
            .looksLikeMediaByMime(candidate);
        if (_playbackStartToken != token) return;
        if (ok) {
          confirmedMediaUrl.value = candidate;
          AppLog.instance.log('[Play] 解析结果是媒体（无后缀）→ 直链播放: $candidate');
        }
      } finally {
        if (_playbackStartToken == token) isResolving.value = false;
      }
    }

    // 仍是网页地址 → 直接内嵌网页播放器加载（**不**跳独立嗅探页）。
    // 内嵌的 WebviewPlayerPage 会在后台嗅探，命中 m3u8 后经
    // onWebviewMediaFound 同页切原生播放器（2026-10-28 用户要求：
    // 「播放不了也把播放器加载出来」「后台嗅探用我的播放器播」）。
    if (!_looksLikeDirectMedia(candidate) &&
        confirmedMediaUrl.value != candidate) {
      AppLog.instance.log('[Play] 网页地址 → 内嵌网页播放器后台嗅探: $candidate');
    }

    // ── 地址形态兜底（用户 2026-10-15）────────────────────────────────
    // 既不是绝对 URL、又补不出 base ⇒ 交给播放器只会白卡 15 秒再弹"加载超时"。
    // 走 setPlaybackError 的既有机制：先自动顺延同集其它候选，全试完才报原因。
    if (!_isPlayableShape(candidate)) {
      AppLog.instance
          .w('[Play] 播放地址不是完整链接，已拦截（不丢给播放器）: $candidate');
      setPlaybackError('该源返回的播放地址不是完整链接：$candidate'
          '（源没给域名，也无法用站点地址补全，请切换线路）');
      return;
    }
    playUrl.value = candidate;
    playbackSessionId.value = _newUuid();
    isPlaying.value = true;
  }

  void resetQualityState() {
    _qualityBaseEpisodeURL = '';
    qualityOptions.clear();
    selectedQualityId.value = PlaybackQualityOption.autoIdentifier;
    _qualityResolveToken = _newUuid();
  }

  void updateQualityOptions(String episodeURL, {required bool resetSelection}) {
    final trimmedEpisodeURL = episodeURL.trim();
    if (trimmedEpisodeURL.isEmpty) {
      resetQualityState();
      return;
    }

    final autoOption = PlaybackQualityOption.auto(trimmedEpisodeURL);
    final previousSelected = selectedQualityId.value;

    _qualityBaseEpisodeURL = trimmedEpisodeURL;
    if (resetSelection) {
      selectedQualityId.value = PlaybackQualityOption.autoIdentifier;
    }

    qualityOptions.value = [autoOption];

    if (_qualityOptionCache.containsKey(trimmedEpisodeURL)) {
      final cached = _qualityOptionCache[trimmedEpisodeURL]!;
      qualityOptions.value = cached;
      if (resetSelection ||
          !cached.any((o) => o.id == selectedQualityId.value)) {
        selectedQualityId.value = PlaybackQualityOption.autoIdentifier;
      } else if (previousSelected != selectedQualityId.value &&
          cached.any((o) => o.id == previousSelected)) {
        selectedQualityId.value = previousSelected;
      }
      return;
    }

    // 磁盘缓存：同一视频二次进入秒出清晰度
    // key 用 md5，避免 String.hashCode 碰撞串到别的视频
    final diskKey = 'quality:${_qualityCacheKey(trimmedEpisodeURL)}';
    try {
      final disk = CacheStore.instance.getJsonListCache(
        diskKey,
        ttl: CacheTtl.quality,
      );
      if (disk != null && disk.isNotEmpty) {
        final cached = disk
            .whereType<Map>()
            .map((e) => PlaybackQualityOption.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        _qualityOptionCache[trimmedEpisodeURL] = cached;
        qualityOptions.value = cached;
        return;
      }
    } catch (_) {}

    final token = _newUuid();
    _qualityResolveToken = token;

    () async {
      final resolved = await _resolveQualityOptions(trimmedEpisodeURL);
      if (_qualityResolveToken != token ||
          _qualityBaseEpisodeURL != trimmedEpisodeURL) {
        return;
      }
      if (resolved.isEmpty) return;

      _qualityOptionCache[trimmedEpisodeURL] = resolved;
      try {
        await CacheStore.instance.setJsonCache(
          'quality:${_qualityCacheKey(trimmedEpisodeURL)}',
          resolved.map((e) => e.toJson()).toList(),
        );
      } catch (e) {
        AppLog.instance.log('[Detail] quality disk cache read fail: $e');
      }
      qualityOptions.value = resolved;

      if (resetSelection) {
        // 全局默认画质：设置为"最高"时选首个非自动档
        // （_parseMasterPlaylist 按 高度/带宽 降序，第 1 个非 auto 即最高）
        if (PlayerPrefs.instance.defaultQuality.value == 1) {
          final top = resolved.firstWhereOrNull((o) => !o.isAuto);
          selectedQualityId.value =
              top?.id ?? PlaybackQualityOption.autoIdentifier;
        } else {
          selectedQualityId.value = PlaybackQualityOption.autoIdentifier;
        }
      } else if (resolved.any((o) => o.id == selectedQualityId.value)) {
        // 当前选择仍有效，保持不变
      } else if (resolved.any((o) => o.id == previousSelected)) {
        selectedQualityId.value = previousSelected;
      } else {
        selectedQualityId.value = PlaybackQualityOption.autoIdentifier;
      }
    }();
  }

  Future<List<PlaybackQualityOption>> _resolveQualityOptions(
      String episodeURL) async {
    if (!_looksLikeHLSURL(episodeURL)) return [];
    try {
      final playlist =
          await NetworkManager.instance.getString(episodeURL);
      return _parseMasterPlaylist(playlist, masterURL: episodeURL);
    } catch (e) {
      AppLog.instance.log('[Detail] resolve quality options fail: $e');
      return [];
    }
  }

  bool _looksLikeHLSURL(String url) {
    final lowercased = url.toLowerCase();
    if (lowercased.contains('.m3u8')) return true;
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final ext = uri.path.split('.').last.toLowerCase();
    return ext == 'm3u8' || ext == 'm3u';
  }

  List<PlaybackQualityOption> _parseMasterPlaylist(
    String content, {
    required String masterURL,
  }) {
    if (!content.toLowerCase().contains('#EXT-X-STREAM-INF')) return [];

    final lines = content.split(RegExp(r'\r?\n'));
    final variants = <_HLSVariant>[];
    var index = 0;

    while (index < lines.length) {
      final line = lines[index].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF:')) {
        index++;
        continue;
      }

      final attributeString =
          line.substring('#EXT-X-STREAM-INF:'.length);
      final attributes = _parseAttributeMap(attributeString);

      String? uri;
      var nextIndex = index + 1;
      while (nextIndex < lines.length) {
        final candidate = lines[nextIndex].trim();
        if (candidate.isEmpty) {
          nextIndex++;
          continue;
        }
        if (candidate.startsWith('#')) {
          nextIndex++;
          continue;
        }
        uri = candidate;
        break;
      }

      if (uri != null && uri.isNotEmpty) {
        final resolvedURL = _resolveRelativeURL(uri, masterURL);
        final name = attributes['NAME']?.trim();
        final bandwidth = int.tryParse(attributes['BANDWIDTH'] ?? '');
        int? height;
        final resolution = attributes['RESOLUTION'];
        if (resolution != null) {
          final parts = resolution.split('x');
          if (parts.length == 2) {
            height = int.tryParse(parts[1]);
          }
        }

        variants.add(_HLSVariant(
          url: resolvedURL,
          name: (name != null && name.isNotEmpty) ? name : null,
          height: height,
          bandwidth: bandwidth,
        ));
      }

      index = nextIndex + 1;
    }

    if (variants.isEmpty) return [];

    // 去重
    final seenURLs = <String>{};
    final deduped = <_HLSVariant>[];
    for (final variant in variants) {
      if (seenURLs.add(variant.url)) {
        deduped.add(variant);
      }
    }

    // 排序：高度降序 > 带宽降序 > URL 升序
    deduped.sort((lhs, rhs) {
      final lhsHeight = lhs.height ?? -1;
      final rhsHeight = rhs.height ?? -1;
      if (lhsHeight != rhsHeight) return rhsHeight.compareTo(lhsHeight);
      final lhsBandwidth = lhs.bandwidth ?? -1;
      final rhsBandwidth = rhs.bandwidth ?? -1;
      if (lhsBandwidth != rhsBandwidth) {
        return rhsBandwidth.compareTo(lhsBandwidth);
      }
      return lhs.url.compareTo(rhs.url);
    });

    final displayNameCount = <String, int>{};
    final options = <PlaybackQualityOption>[];
    for (var i = 0; i < deduped.length; i++) {
      final variant = deduped[i];
      String baseName;
      if (variant.name != null && variant.name!.isNotEmpty) {
        baseName = variant.name!;
      } else if (variant.height != null) {
        baseName = '${variant.height}p';
      } else if (variant.bandwidth != null && variant.bandwidth! > 0) {
        baseName = '${variant.bandwidth! ~/ 1000}K';
      } else {
        baseName = '清晰度${i + 1}';
      }

      final newCount = (displayNameCount[baseName] ?? 0) + 1;
      displayNameCount[baseName] = newCount;
      final finalName = newCount > 1 ? '$baseName $newCount' : baseName;

      final option = PlaybackQualityOption(
        id: variant.url,
        name: finalName,
        url: variant.url,
      );
      if (option.url.isNotEmpty && option.url != masterURL) {
        options.add(option);
      }
    }

    if (options.length < 2) return [];

    final merged = <PlaybackQualityOption>[
      PlaybackQualityOption.auto(masterURL),
      ...options,
    ];
    return merged;
  }

  Map<String, String> _parseAttributeMap(String raw) {
    final result = <String, String>{};
    final pairs = _splitAttributes(raw);
    for (final pair in pairs) {
      final components = pair.split('=');
      if (components.length < 2) continue;
      final key = components[0].trim();
      var value = components.sublist(1).join('=').trim();
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      if (key.isNotEmpty) {
        result[key] = value;
      }
    }
    return result;
  }

  List<String> _splitAttributes(String raw) {
    final parts = <String>[];
    final buffer = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < raw.length; i++) {
      final char = raw[i];
      if (char == '"') {
        inQuotes = !inQuotes;
        buffer.write(char);
        continue;
      }

      if (char == ',' && !inQuotes) {
        final item = buffer.toString().trim();
        if (item.isNotEmpty) {
          parts.add(item);
        }
        buffer.clear();
        continue;
      }

      buffer.write(char);
    }

    final tail = buffer.toString().trim();
    if (tail.isNotEmpty) {
      parts.add(tail);
    }
    return parts;
  }

  String _resolveRelativeURL(String uri, String baseURL) {
    final baseUri = Uri.tryParse(baseURL);
    if (baseUri == null) return uri;
    // 如果已经是绝对 URL，直接返回
    if (uri.startsWith('http://') || uri.startsWith('https://')) return uri;
    final resolved = baseUri.resolve(uri);
    return resolved.toString();
  }

  void saveRecord() {
    final info = vodInfo.value;
    if (info == null) return;
    // 暂停时也要能落进度，否则「暂停 → 返回」会丢观看记录
    final progress = currentPlaybackSeconds();
    final episode = currentEpisodes.isNotEmpty &&
            selectedEpisodeIndex.value < currentEpisodes.length
        ? currentEpisodes[selectedEpisodeIndex.value]
        : null;

    final playNote = episode != null
        ? '${selectedFlag.value} - ${episode.name}'
        : '';

    CacheStore.instance.addRecord(
      Video(
        id: info.id,
        name: info.name,
        pic: info.pic,
        sourceKey: info.sourceKey,
      ),
      playNote,
      playbackState: VodPlaybackState(
        flag: selectedFlag.value,
        episodeIndex: selectedEpisodeIndex.value,
        progressSeconds: progress,
      ),
    );
  }

  static const _uuid = Uuid();

  String _newUuid() {
    return _uuid.v4();
  }

  /// 清晰度磁盘缓存 key：对 URL 做 md5，避免 hashCode 碰撞
  static String _qualityCacheKey(String episodeURL) {
    return md5.convert(utf8.encode(episodeURL)).toString();
  }
}

class _HLSVariant {
  final String url;
  final String? name;
  final int? height;
  final int? bandwidth;

  const _HLSVariant({
    required this.url,
    this.name,
    this.height,
    this.bandwidth,
  });
}
