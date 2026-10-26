import 'dart:async';
import 'package:get/get.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox/models/movie.dart';
import 'package:tvbox/models/source_bean.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/services/source_service.dart';
import 'package:tvbox/common/constants.dart';

class TvSearchController extends GetxController {
  Timer? _debounce;
  final Map<String, List<Video>> _searchCache = {};

  /// 同时在跑的搜索轮次数。
  /// 旧写法只在 `_latestSearchRequestId == requestId` 时复位 isSearching，
  /// 连续两次搜索时前一轮的 requestId 已过期 → 永远不复位 → UI 卡在"搜索中"。
  int _activeSearches = 0;

  /// 输入防抖 400ms，避免逐字发请求
  void onKeywordChanged(String kw, Future<void> Function(String) run) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      if (kw.trim().isEmpty) return;
      run(kw.trim());
    });
  }

  @override
  void onClose() {
    _debounce?.cancel();
    _debounce = null;
    _searchCache.clear();
    super.onClose();
  }

  List<Video>? cachedSearch(String kw) => _searchCache[kw.trim()];

  void rememberSearch(String kw, List<Video> list) {
    final k = kw.trim();
    if (k.isEmpty) return;
    if (_searchCache.length > 50) _searchCache.clear();
    _searchCache[k] = list;
  }

  final keyword = ''.obs;
  final searchHistory = <String>[].obs;
  final resultsBySite = <String, List<Video>>{}.obs;
  final searchingStatus = <String, bool>{}.obs;
  final resultCount = <String, int>{}.obs;
  final activeSites = <SourceBean>[].obs;
  final selectedSiteKey = Rx<String?>(null);
  final isSearching = false.obs;

  String _latestSearchRequestId = '';

  /// 单源搜索超时。
  ///
  /// 取 12 秒：足够 spider 源转发一次，又不会让用户干等太久。
  /// 关键是**必须有** —— 没有超时就会因为一个卡住的源让整页永远"搜索中"。
  // 单源超时 8s：12s 太长了，一个卡住的源会把整个「快搜」拖到没法用。
  // 有结果的源通常 1~3s 就回，8s 足够，超时的直接跳过。
  static const Duration _perSourceTimeout = Duration(seconds: 8);

  /// 最近一次真正发起搜索的关键词，供防抖去重（避免回车 + 防抖各搜一遍）
  String _lastSearchedKeyword = '';

  /// 防抖路径调用：与已搜过的关键词相同则跳过
  Future<void> searchFromDebounce(String kw) async {
    final trimmed = kw.trim();
    if (trimmed.isEmpty) return;
    if (trimmed == _lastSearchedKeyword) return;
    keyword.value = trimmed;
    await search();
  }

  @override
  void onInit() {
    super.onInit();
    loadSearchHistory();
  }

  List<Video> get currentResults {
    final key = selectedSiteKey.value;
    if (key == null) return [];
    return resultsBySite[key] ?? [];
  }

  bool get isCurrentSiteSearching {
    final key = selectedSiteKey.value;
    if (key == null) return false;
    return searchingStatus[key] ?? false;
  }

  Future<void> search() async {
    final trimmed = keyword.value.trim();
    if (trimmed.isEmpty) return;

    final requestId = '${DateTime.now().microsecondsSinceEpoch}';
    _latestSearchRequestId = requestId;
    _lastSearchedKeyword = trimmed;

    // 并发计数：连续搜索时不能靠 requestId 复位，否则 isSearching 卡 true
    _activeSearches++;
    isSearching.value = true;

    addToHistory(trimmed);

    final sources = ApiConfig.instance.getSearchableSources();
    final validSources = sources
        .where((s) =>
            s.isSupportedInSwift && s.key != 'douban' && s.key != 'baseset')
        .toList();

    resultsBySite.clear();
    searchingStatus.clear();
    resultCount.clear();
    activeSites.value = validSources;

    if (selectedSiteKey.value == null ||
        !validSources.any((s) => s.key == selectedSiteKey.value)) {
      selectedSiteKey.value =
          validSources.isNotEmpty ? validSources.first.key : null;
    }

    for (final source in validSources) {
      searchingStatus[source.key] = true;
      resultCount[source.key] = 0;
    }

    // 并发搜索
    AppLog.instance.log('[SearchController] 开始搜索: "$trimmed", 可用源数=${validSources.length}');
    for (final s in validSources) {
      AppLog.instance.log('[SearchController] 源: key=${s.key}, type=${s.type}, api=${s.api}, isSpider=${s.isSpiderSource}');
    }

    final futures = <Future<void>>[];
    for (final source in validSources) {
      futures.add(_searchInSourceAndNotify(source, trimmed, requestId));
    }
    try {
      await Future.wait(futures);
    } finally {
      // 计数归零才熄"搜索中"：连续搜索时旧 requestId 已过期，
      // 若只按 requestId 复位，isSearching 会永久卡在 true。
      _activeSearches--;
      if (_activeSearches <= 0) {
        _activeSearches = 0;
        isSearching.value = false;
      }
    }
  }

  Future<void> _searchInSourceAndNotify(
      SourceBean source, String kw, String requestId) async {
    // ⚠️ 必须给单源加超时。
    //
    // 原来直接 `await SourceService.search(...)`：只要有一个源卡住（spider 源
    // 转发慢、接口不回包），`Future.wait` 就永远不返回 → `_activeSearches`
    // 不归零 → `isSearching` 永久停在 true →
    // 界面一直显示「搜索中」，而其它源其实早就返回了（结果也没落进
    // resultsBySite，因为赋值在 await 之后）。
    //
    // 这是「快搜一直搜索中、没有内容」的直接原因。
    try {
      AppLog.instance.log('[SearchController] 搜索源 ${source.key}: 开始搜索 "$kw"');
      final videos = await SourceService.instance
          .search(source, kw)
          .timeout(_perSourceTimeout);
      AppLog.instance.log('[SearchController] 搜索源 ${source.key}: 返回 ${videos.length} 条结果');
      // 过期请求丢弃结果，但 finally 仍要复位"搜索中"，否则 chip 永久转圈
      if (_latestSearchRequestId != requestId) return;
      resultsBySite[source.key] = videos;
      resultCount[source.key] = videos.length;
      // 结果到了就把用户带到"真有东西"的那个源。
      //
      // 原来默认选第一个源：只要它超时/为空，界面就一直显示「正在搜索各源...」，
      // 而其它源其实早就返回了结果 —— 这就是"快搜看着没内容/很慢"的主因。
      _autoPickBestSite();
    } on TimeoutException {
      AppLog.instance.log('[SearchController] 搜索源 ${source.key}: '
          '超时（${_perSourceTimeout.inSeconds}s），跳过');
      if (_latestSearchRequestId == requestId) {
        resultsBySite[source.key] = [];
        resultCount[source.key] = 0;
        _autoPickBestSite();
      }
    } catch (e) {
      AppLog.instance.log('[SearchController] 搜索源 ${source.key}: 搜索失败 $e');
      if (_latestSearchRequestId == requestId) {
        resultsBySite[source.key] = [];
        resultCount[source.key] = 0;
        _autoPickBestSite();
      }
    } finally {
      // 无论成功/失败/超时/过期都复位，保证该源 chip 不再转圈
      searchingStatus[source.key] = false;
    }
  }

  /// 自动切到"有结果"的源。
  ///
  /// 规则：当前选中的源已有结果就**不动**（尊重用户手动切源）；
  /// 否则挑一个结果最多的源切过去。
  void _autoPickBestSite() {
    final cur = selectedSiteKey.value;
    if (cur != null && (resultCount[cur] ?? 0) > 0) return;

    String? best;
    var bestCount = 0;
    for (final e in resultCount.entries) {
      final n = e.value;
      if (n > bestCount) {
        bestCount = n;
        best = e.key;
      }
    }
    if (best != null && bestCount > 0) {
      selectedSiteKey.value = best;
      AppLog.instance.log(
          '[SearchController] 自动切到有结果的源: $best ($bestCount 条)');
    }
  }

  Future<void> searchInSource(SourceBean source) async {
    final trimmed = keyword.value.trim();
    if (trimmed.isEmpty) return;

    searchingStatus[source.key] = true;
    resultCount[source.key] = 0;
    if (!activeSites.any((s) => s.key == source.key)) {
      activeSites.add(source);
    }
    selectedSiteKey.value = source.key;

    try {
      final videos = await SourceService.instance.search(source, trimmed);
      resultsBySite[source.key] = videos;
      resultCount[source.key] = videos.length;
    } catch (_) {
      resultsBySite[source.key] = [];
      resultCount[source.key] = 0;
    }
    searchingStatus[source.key] = false;
  }

  void selectSite(String key) {
    selectedSiteKey.value = key;
  }

  void loadSearchHistory() {
    _loadSearchHistoryAsync();
  }

  Future<void> _loadSearchHistoryAsync() async {
    final prefs = await SharedPreferences.getInstance();
    searchHistory.value = prefs.getStringList(AppConstants.searchHistory) ?? [];
  }

  Future<void> addToHistory(String kw) async {
    searchHistory.remove(kw);
    searchHistory.insert(0, kw);
    if (searchHistory.length > 20) {
      searchHistory.removeRange(20, searchHistory.length);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(AppConstants.searchHistory, searchHistory.toList());
  }

  Future<void> clearHistory() async {
    searchHistory.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppConstants.searchHistory);
  }
}
