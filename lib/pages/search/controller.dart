import 'dart:async';
import 'package:get/get.dart';
import '../../services/app_log.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/movie.dart';
import '../../models/source_bean.dart';
import '../../services/api_config.dart';
import '../../services/source_service.dart';
import '../../common/constants.dart';

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
    try {
      AppLog.instance.log('[SearchController] 搜索源 ${source.key}: 开始搜索 "$kw"');
      final videos = await SourceService.instance.search(source, kw);
      AppLog.instance.log('[SearchController] 搜索源 ${source.key}: 返回 ${videos.length} 条结果');
      if (_latestSearchRequestId != requestId) return;
      resultsBySite[source.key] = videos;
      resultCount[source.key] = videos.length;
    } catch (e) {
      AppLog.instance.log('[SearchController] 搜索源 ${source.key}: 搜索失败 $e');
      if (_latestSearchRequestId != requestId) return;
      resultsBySite[source.key] = [];
      resultCount[source.key] = 0;
    }
    searchingStatus[source.key] = false;
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
