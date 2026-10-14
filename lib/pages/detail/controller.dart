import 'dart:async';
import 'dart:convert';
import 'dart:math' show Random;

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../../models/movie.dart';
import '../../models/vod_info.dart';
import '../../models/cache_store.dart';
import '../../models/cache_ttl.dart';
import '../../services/api_config.dart';
import '../../services/source_service.dart';
import '../../services/spider_service.dart';
import '../../services/app_log.dart';
import '../../services/network_manager.dart';
import '../../services/player_prefs.dart';
import '../../services/ad_filter_service.dart';
import '../../services/parse_service.dart';
import '../play/sniff_player_page.dart';

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

class DetailController extends GetxController with WidgetsBindingObserver {
  final vodInfo = Rx<VodInfo?>(null);
  final isLoading = false.obs;
  final errorMessage = Rx<String?>(null);
  final selectedFlag = ''.obs;
  final selectedEpisodeIndex = 0.obs;
  final isPlaying = false.obs;
  final playUrl = Rx<String?>(null);
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
  void setPlaybackError(String message) {
    errorMessage.value = message;
    isPlaying.value = false;
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
        final urlValue = result['url'];
        if (urlValue is String && urlValue.isNotEmpty) {
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
          // 2026-10-14：Spider 返回 http(s) 网页地址时，旧逻辑把非媒体后缀的
          // 地址一律当"网页播放页"丢给 WebView —— 用户点播放就直接弹出原网页。
          // 现在先过一遍配置里的解析接口尝试提取真实直链：拿到直链走原生播放；
          // 解析接口不可用 / 未命中 / 只解出网页时保持原地址，由播放区 WebView 兜底。
          var playCandidate = resolvedUrl;
          if (!_looksLikeDirectMedia(playCandidate) &&
              ParseService.instance.enabled) {
            final outcome =
                await ParseService.instance.parseOutcome(playCandidate);
            if (outcome != null && outcome.url.isNotEmpty && outcome.direct) {
              AppLog.instance.log(
                  '[Play] 解析接口「${outcome.sourceName}」提取直链成功 → ${outcome.url}');
              playCandidate = outcome.url;
            }
          }
          if (_spiderResolveToken != token) return;
          playUrl.value = playCandidate;
          playHeaders.value = headers;
          playbackSessionId.value = _newUuid();
          isPlaying.value = true;
        } else {
          errorMessage.value = 'Spider播放地址解析失败';
        }
      } catch (e) {
        if (_spiderResolveToken != token) return;
        errorMessage.value = 'Spider播放解析错误: $e';
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

  static const List<String> _directMediaExtensions = [
    '.m3u8',
    '.mp4',
    '.flv',
    '.ts',
    '.mkv',
    '.m3u',
  ];

  /// 是否已是已知直链媒体（后缀命中）——是则无需再过解析接口。
  bool _looksLikeDirectMedia(String url) {
    if (url.isEmpty) return false;
    final path = Uri.tryParse(url)?.path ?? url;
    final lower = path.toLowerCase();
    for (final ext in _directMediaExtensions) {
      if (lower.endsWith(ext)) return true;
    }
    return false;
  }

  /// 取流/播放入口统一入口：在 [_selectedPlayableURL] 基础上接入广告过滤与解析接口。
  ///
  /// - 命中广告黑名单 → 回退到 fallback（沿用既有回退语义，不抛弃原地址）；
  /// - 非直链媒体后缀且解析器可用 → 走 parses 接口，成功替换、失败保持原地址。
  ///
  /// 无 ads/rules 且无 parses 时，方法内不产生 await，行为与原来的同步赋值一致。
  Future<void> _startPlayback(String fallback) async {
    var candidate = _selectedPlayableURL(fallback: fallback);

    if (AdFilterService.instance.isBlocked(candidate) &&
        candidate != fallback) {
      candidate = fallback;
    }

    if (!_looksLikeDirectMedia(candidate) && ParseService.instance.enabled) {
      final outcome = await ParseService.instance.parseOutcome(candidate);
      if (outcome != null && outcome.url.isNotEmpty) {
        if (outcome.direct) {
          candidate = outcome.url;
        } else {
          // 解析接口返回的是网页播放页 → 交给嗅探播放页，避免直接播黑屏
          Get.to(() => SniffPlayerPage(url: outcome.url));
          return;
        }
      }
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
