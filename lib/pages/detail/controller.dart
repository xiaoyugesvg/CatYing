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
import 'package:tvbox/services/play_context_store.dart';
import 'package:tvbox/services/play_pipeline.dart';
import 'package:tvbox/services/player_prefs.dart';
import 'package:tvbox/services/ad_filter_service.dart';
import 'package:tvbox/services/play_url_sanitizer.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/webhome/webhtv_site_health_page.dart';
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

  /// 正在取播放地址（详情页据此显示"取址中"，且**不**启动 15 秒
  /// "地址获取超时"计时）。
  final isResolving = false.obs;

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
    super.onClose();
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
    _resetAutoSwitch(); // 用户主动切线路 → 自动计数清零、看门狗停

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
    _resetAutoSwitch(); // 用户主动换集 → 自动计数清零、看门狗停

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
    _resetAutoSwitch(); // 恢复播放（换集/换线路）→ 自动计数清零、看门狗停

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
    // P2-1：播放中首次拿到进度 → 启动卡顿看门狗（停滞 20s 自动恢复）
    if (isPlaying.value && (playUrl.value ?? '').isNotEmpty) {
      _ensureStallWatchdog();
    }
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
    // P1-2：同 flag 内候选顺延后仍未恢复 → 自动换下一条 flag（最多 6 次）
    if (_advanceToNextFlag()) return;
    // 走到这里 = 所有线路都试过了，把原因写给用户（isPlaying 置否、看门狗停）
    errorMessage.value = _withPageHint(message);
    isPlaying.value = false;
    _stopStallWatchdog(); // P2-1
  }

  /// 本次取址是否「按 Spider / JS 源的解析结果直接当直链」（`trustMedia`）。
  ///
  /// 只用于**失败文案**：这类地址常常没有 `.m3u8/.mp4` 后缀（token / 跳转端点），
  /// 取址时按用户 2026-10-29 的决定直接交给播放器；但如果它其实是个网页，
  /// 播放器只会报「播放失败 / 超时」，用户看不出原因。这里记一笔，
  /// 让报错时能补一句提示。
  bool _spiderTrustedMedia = false;

  /// 「按直链信任、但可能仍是网页」的失败提示（用户 2026-10-29 同意加）。
  ///
  /// 单独抽成常量：[classifyPlaybackError] 要先把它剥掉再分类，否则这句里的
  /// 「地址」会让所有播放失败都被归成「地址无效」。
  static const String _kTrustedMediaPageHint =
      '（这个地址可能仍是网页而不是直链，建议换线路）';

  /// 给「按直链信任、但可能仍是网页」的失败补一句提示。
  ///
  /// 只在**当前地址确实不像直链**时才加，避免误导真正的死链 / 403：
  ///   · 不是 http(s)（`x5://` / `magnet:` 之类）→ 不加（本来就不是网页）；
  ///   · 已经是 `.m3u8/.mp4…` → 不加（播放器认得出，失败就是源的问题）；
  ///   · 本来就是「网页地址被拒」那条文案 → 不加（重复）。
  String _withPageHint(String message) {
    if (!_spiderTrustedMedia) return message;
    if (message == kMovieWebUrlRejected) return message;
    final u = (playUrl.value ?? '').trim().toLowerCase();
    if (!u.startsWith('http')) return message;
    if (looksLikeDirectMedia(u)) return message;
    return '$message\n$_kTrustedMediaPageHint';
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

  /// ─────────────────────────── P1-2 / P1-3 / P2-1 ───────────────────────────

  /// 自动换线路（flag/源线）重试上限：同一集最多自动切 6 条线路再放弃。
  int _autoFlagSwitches = 0;
  static const int _maxAutoFlagSwitches = 6;
  final Set<String> _triedFlags = <String>{};

  /// P1-2：同 flag 内候选已全部失败 → 自动切到下一条**未试过**的 flag，
  /// 最多切 [_maxAutoFlagSwitches] 次。返回 true 表示已切走（恢复播放）。
  bool _advanceToNextFlag() {
    final info = vodInfo.value;
    if (info == null) return false;
    if (_autoFlagSwitches >= _maxAutoFlagSwitches) return false;
    final flags = info.playFlags;
    if (flags.length <= 1) return false;
    final curIdx = flags.indexOf(selectedFlag.value);
    for (var step = 1; step < flags.length; step++) {
      final nextFlag = flags[(curIdx + step) % flags.length];
      if (nextFlag == selectedFlag.value) continue;
      if (_triedFlags.contains(nextFlag)) continue;
      final episodes = info.playUrlMap[nextFlag] ?? [];
      if (episodes.isEmpty) continue;
      _triedFlags.add(nextFlag);
      _autoFlagSwitches++;
      AppLog.instance.log(
          '[Play] 自动换线路(第$_autoFlagSwitches/$_maxAutoFlagSwitches) → $nextFlag');
      selectedFlag.value = nextFlag;
      info.playFlag = nextFlag;
      _rememberFlag(nextFlag);
      _failedPlayUrls.clear(); // 新线路重新给机会
      final targetIndex =
          selectedEpisodeIndex.value.clamp(0, episodes.length - 1);
      selectedEpisodeIndex.value = targetIndex;
      info.playIndex = targetIndex;
      final episodeURL = episodes[targetIndex].url;
      updateQualityOptions(episodeURL, resetSelection: true);
      if (isSpiderSource) {
        _resolveSpiderPlayUrl(flag: nextFlag, id: episodeURL);
      } else {
        playHeaders.clear();
        unawaited(_startPlayback(episodeURL));
      }
      return true;
    }
    return false;
  }

  /// P1-3：把播放错误文案归到 5 类，返回可操作建议（未命中返回 null）。
  ///
  /// 命中优先级：地址解析 → 超时 → 403/404/防盗链 → 地址无效 → 解码/播放器。
  String? classifyPlaybackError(String msg) {
    // 先剥掉「可能仍是网页」那句提示：里面的「地址」会把所有失败都归成
    // 「地址无效」（见 [_kTrustedMediaPageHint]）。
    final m = msg.replaceAll(_kTrustedMediaPageHint, '').toLowerCase();
    if (m.contains('解析') || m.contains('parse')) {
      return '播放地址解析失败，可换线路或换源';
    }
    if (m.contains('超时') ||
        m.contains('timeout') ||
        m.contains('timed out')) {
      return '网络超时，可换线路或检查网络后重试';
    }
    if (m.contains('403') ||
        m.contains('404') ||
        m.contains('防盗链') ||
        m.contains('forbidden') ||
        m.contains('not found') ||
        m.contains('拦截') ||
        m.contains('禁止')) {
      return '源地址失效或被拦截，请换一条线路';
    }
    if (m.contains('不是完整链接') ||
        m.contains('地址') ||
        m.contains('url') ||
        m.contains('无效') ||
        m.contains('http')) {
      return '该源返回的地址无效，请切换其他线路';
    }
    if (m.contains('解码') ||
        m.contains('播放') ||
        m.contains('player') ||
        m.contains('codec') ||
        m.contains('黑屏')) {
      return '播放器无法解码，可换线路或换播放内核';
    }
    return null;
  }

  /// 复位自动换线路计数 / 已试集合 / 卡顿看门狗。
  /// 用户**主动**切线路、换集、重试、恢复播放时调用 —— 用户已接管，
  /// 自动计数清零、看门狗停掉（避免误判）。
  void _resetAutoSwitch() {
    _autoFlagSwitches = 0;
    _triedFlags.clear();
    _stopStallWatchdog();
  }

  /// P2-1：卡顿看门狗。播放中若 20s 内进度无任何推进（疑似卡顿/死链），
  /// 自动触发一次换线路恢复（走 [setPlaybackError] 的顺延/换 flag 逻辑），
  /// 避免用户干等一块"播着但不动"的黑屏。
  static const Duration _stallWindow = Duration(seconds: 20);
  double _stallBaselinePos = 0;
  Timer? _stallWatchdog;

  void _ensureStallWatchdog() {
    if (_stallWatchdog != null) return;
    _stallBaselinePos = currentPlaybackSeconds();
    _stallWatchdog = Timer.periodic(_stallWindow, (_) => _checkStall());
  }

  void _stopStallWatchdog() {
    _stallWatchdog?.cancel();
    _stallWatchdog = null;
    _stallBaselinePos = 0; // 归零基线：下次播放重新校准，避免旧基线误判卡顿
  }

  void _checkStall() {
    if (!isPlaying.value || (playUrl.value ?? '').isEmpty) {
      _stopStallWatchdog();
      return;
    }
    final pos = currentPlaybackSeconds();
    // 进度有推进 → 健康，刷新基准
    if (pos - _stallBaselinePos > 0.5) {
      _stallBaselinePos = pos;
      return;
    }
    // 之前已播到某位置（>1s）却 20s 无推进 → 判定卡顿死链
    if (_stallBaselinePos > 1) {
      AppLog.instance
          .w('[Play] 检测到播放卡顿（20s 无进度推进），尝试自动恢复');
      _stopStallWatchdog();
      setPlaybackError('播放卡顿（长时间无进度推进），已尝试自动换线路');
    }
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
    _resetAutoSwitch(); // 用户手动重试 → 自动计数清零、看门狗停
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

    if (episode.url.startsWith('/')) {
      _resolveSpiderPlayUrl(flag: flag, id: episode.url);
    } else {
      unawaited(_startPlayback(episode.url));
    }
  }

  /// 「换线路」：切到下一条未试过的播放线路并重解当前集。
  void switchToNextFlag() {
    if (_advanceToNextFlag()) return;
    AppToast.message('没有其它可用的播放线路');
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

    unawaited(_resolveSpiderPlayUrlInner(token: token, flag: flag, id: id));
  }

  /// 真正的取址协程：上下文恢复 → getPlayUrl → 统一播放管线。
  ///
  /// 上下文恢复放在最前面，是这次重构的核心：原实现只要
  /// `_currentSpider == null` 就直接报「Spider 上下文缺失」，
  /// 而回前台 / 从历史进详情 / 换线路都会把它清空 ⇒ 必现黑屏。
  Future<void> _resolveSpiderPlayUrlInner({
    required String token,
    required String flag,
    required String id,
  }) async {
    // 取址期间就挂上"解析中"标记：详情页据此**不启动** 15 秒"地址获取超时"
    //  ——Spider 的 getPlayUrl 最坏可达 60 秒，原来这期间 isResolving 还是 false，
    //  首帧就会建出 15 秒计时器 ⇒ 正常解析中被误报"播放地址获取超时"。
    isResolving.value = true;
    try {
      final spiderInfo = await _ensureSpiderContext();
      if (_spiderResolveToken != token) return;

      // **2026-09-26 修复**：从历史/收藏直接进入 Spider 源详情时，
      // 上下文可能恢复不出来。此时不再请求 Spider 服务（路径会是非法
      // / /type/play），而是降级为把集数 URL 当作直链直接播放。
      if (spiderInfo.key.isEmpty) {
        final looksLikeUrl =
            id.startsWith('http://') || id.startsWith('https://');
        if (!looksLikeUrl) {
          // 不是直链，播了也是黑屏：给出可操作的提示，而不是静默失败
          errorMessage.value = '无法恢复该源的播放上下文，请切换线路或重新进入该源';
          isPlaying.value = false;
          return;
        }
        playUrl.value = id;
        playHeaders.value = <String, String>{};
        playbackSessionId.value = _newUuid();
        isPlaying.value = true;
        return;
      }

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

        if (resolvedUrl != null && resolvedUrl.isNotEmpty) {
          // 先剥掉 `类型|哈希|真实URL` 包裹（如 `tencent|54e3…|https://…`），
          // 再补全相对路径 —— 顺序反了会把整串拼到站点域名后面（2026-10-28）。
          resolvedUrl = sanitizePlayUrl(resolvedUrl);
          // 相对播放地址 → 用源 api 的 host 补成绝对
          resolvedUrl = _absolutizePlayUrl(resolvedUrl);

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
          // ── 统一播放判定（直链 → 原生播放器；网页 → 影视模块不播）──
          final resolution = PlayPipeline.instance.resolve(
            resolvedUrl,
            headers: headers,
            apiBase: spiderInfo.api,
            // Spider / JS 源已把真实播放地址解析出来了：直接当媒体交给
            // 原生播放器，不再用「后缀」去猜它是不是网页（用户 2026-10-29）。
            trustMedia: true,
          );
          if (_spiderResolveToken != token) return;
          final playCandidate = resolution.url;
          // 记下这次是「按 Spider 直链信任」还是普通直链，供失败文案用
          _spiderTrustedMedia = resolution.isMedia;
          headers = Map<String, String>.from(resolution.headers);
          playHeaders.value = headers;
          if (resolution.isPage) {
            // 影视模块不允许网页播放（2026-10-29）：交给 setPlaybackError 的
            // 既有机制先顺延候选 / 换线路，全试完再把原因写给用户。
            AppLog.instance
                .log('[Play] Spider 网页地址，影视模块不播网页: $playCandidate');
            setPlaybackError(kMovieWebUrlRejected);
            return;
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
  }

  /// 确保 Spider 播放上下文可用（本次重构的关键修复）。
  ///
  /// 顺序：
  ///   ① 当前会话上下文**就是本视频的源** → 直接用；
  ///   ② 当前订阅/本地源里能查到该源 → 按配置重建（api/ext 最准）；
  ///   ③ 配置里已没有该源（历史/收藏/换过订阅）→ 从 [PlayContextStore]
  ///      的持久化记录恢复（冷启动、杀进程后依然有效）。
  /// 都恢复不出来才返回空上下文，由调用方走"直链兜底 / 明确报错"。
  Future<({String key, int type, String api, String ext})>
      _ensureSpiderContext() async {
    final sourceKey = vodInfo.value?.sourceKey ?? '';
    final normalized = PlayContextStore.normalizeKey(sourceKey);
    final current = SpiderService.instance.getCurrentSpiderInfo();

    if (current.key.isNotEmpty &&
        (sourceKey.isEmpty ||
            current.key == normalized ||
            current.key == sourceKey)) {
      return current;
    }

    // ① 配置里能查到 → 用最新配置重建
    final bean = sourceKey.isEmpty ? null : ApiConfig.instance.getSource(sourceKey);
    if (bean != null) {
      final engineKey = PlayContextStore.normalizeKey(bean.key);
      PlayContextStore.instance.rememberBean(bean);
      SpiderService.instance.setCurrentSpider(engineKey, bean.type, bean.api,
          ext: bean.ext, jar: bean.jar);
      try {
        await SpiderService.instance
            .initSpider(engineKey, bean.type, bean.api, ext: bean.ext ?? '');
      } catch (e) {
        AppLog.instance.log('[Play] 重建上下文时 initSpider 失败: $e');
      }
      AppLog.instance.log('[Play] 播放上下文已按配置重建: $sourceKey');
      return SpiderService.instance.getCurrentSpiderInfo();
    }

    // ② 配置里没有 → 从持久化记录恢复
    final stored = await PlayContextStore.instance.lookup(sourceKey);
    if (stored == null || !stored.usable) {
      AppLog.instance.log('[Play] 无法恢复播放上下文: sourceKey=$sourceKey');
      return (key: '', type: 0, api: '', ext: '');
    }
    SpiderService.instance.setCurrentSpider(
        stored.engineKey, stored.type, stored.api,
        ext: stored.ext, jar: stored.jar);
    try {
      await SpiderService.instance.initSpider(
          stored.engineKey, stored.type, stored.api,
          ext: stored.ext);
    } catch (e) {
      AppLog.instance.log('[Play] 恢复上下文时 initSpider 失败: $e');
    }
    AppLog.instance.log(
        '[Play] 播放上下文已从本地恢复: ${stored.sourceKey} (type=${stored.type})');
    return SpiderService.instance.getCurrentSpiderInfo();
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
  /// 普通链路（CMS / 直链）也要防"旧结果顶掉新集"：取流是 await 的，
  /// 快速连点两集时，先发起那次回来后会**无条件**写 `playUrl` —— 表现就是
  /// "点了下一集，画面又跳回上一集"。Spider 链路早有 `_spiderResolveToken`，
  /// 这里补上同一套。
  String _playbackStartToken = '';

  /// 取流/播放入口统一入口：在 [_selectedPlayableURL] 基础上接入广告过滤。
  ///
  /// - 命中广告黑名单 → 回退到 fallback（沿用既有回退语义，不抛弃原地址）；
  /// - 否则原样使用该地址（直链交原生播放器；网页地址**不播**）。
  ///
  /// 无 ads/rules 时，方法内不产生 await，行为与原来的同步赋值一致。
  Future<void> _startPlayback(String fallback) async {
    final token = _newUuid();
    _playbackStartToken = token;
    // 走这里的都是普通视频链路（CMS 源 / 直链），形态复位成"视频"
    contentMode.value = PlayContentMode.video;
    // 普通链路不走 `trustMedia`：地址形态由 PlayPipeline 正常判定，
    // 失败时也就不需要「可能仍是网页」那句提示（见 [_withPageHint]）。
    _spiderTrustedMedia = false;
    var candidate = _selectedPlayableURL(fallback: fallback);
    // 先剥掉 `类型|哈希|真实URL` 包裹（TVBox 社区源常见）：必须在补全**之前**，
    // 否则会被当成相对路径拼到站点域名后面，彻底解不出真实地址（2026-10-28）。
    candidate = sanitizePlayUrl(candidate);
    // 相对播放地址 → 用源 api 的 host 补成绝对
    candidate = _absolutizePlayUrl(candidate);

    if (AdFilterService.instance.isBlocked(candidate) &&
        candidate != fallback) {
      candidate = fallback;
    }

    // ── 统一播放判定：直链 → 原生播放器；网页 → 拒绝（影视不播网页）──────
    isResolving.value = true;
    late PlayResolution resolution;
    try {
      resolution = PlayPipeline.instance.resolve(
        candidate,
        headers: playHeaders,
        apiBase: SpiderService.instance.getCurrentSpiderInfo().api,
      );
    } finally {
      // 只有"仍是本次"才清（期间又切集 ⇒ 标记归新一次管，别提前清掉）
      if (_playbackStartToken == token) isResolving.value = false;
    }

    // 期间又切了集/换了线路 ⇒ 这次作废（否则会把新集的地址覆盖掉）
    if (_playbackStartToken != token) return;

    candidate = resolution.url;
    playHeaders.value = Map<String, String>.from(resolution.headers);
    if (resolution.isPage) {
      // 影视模块不允许网页播放（2026-10-29）：不内嵌 WebView，按"这条线路
      // 播不了"处理 —— 先自动顺延同集其它候选 / 下一条线路，全试完才提示。
      AppLog.instance.log('[Play] 网页地址，影视模块不播网页: $candidate');
      setPlaybackError(kMovieWebUrlRejected);
      return;
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
