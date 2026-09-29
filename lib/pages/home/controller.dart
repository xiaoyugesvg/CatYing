import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import '../../models/cache_store.dart';
import '../../models/movie.dart';
import '../../models/movie_sort.dart';
import '../../services/api_config.dart';
import '../../services/app_log.dart';
import '../../services/app_state.dart';
import '../../services/source_service.dart';

class HomeController extends GetxController {
  final sorts = <SortData>[].obs;
  final selectedSort = Rx<SortData?>(null);
  final homeVideos = <Video>[].obs; // 轮播图用
  final videos = <Video>[].obs;
  final isLoading = false.obs;
  final currentPage = 1.obs;
  final hasMore = true.obs;
  final errorMessage = Rx<String?>(null);
  final selectedFilters = <String, String>{}.obs;

  List<SortFilter> get currentFilters {
    final sortId = selectedSort.value?.id;
    if (sortId == null) return [];
    return sorts.firstWhereOrNull((s) => s.id == sortId)?.filters ?? [];
  }

  @override
  void onInit() {
    super.onInit();
    // 监听主页源变化，自动重新加载
    ever(ApiConfig.instance.homeSourceBean, (source) {
      if (source != null) {
        refresh();
      }
    });

    // 首次加载
    loadSorts();
  }

  Future<void> loadSorts() async {
    final source = ApiConfig.instance.homeSourceBean.value;
    if (source == null) return;

    // 缓存优先：首页轮播立刻出片
    final cacheKey = 'home_videos:${source.key}';
    try {
      final cached = CacheStore.instance.getJsonListCache(cacheKey, ttl: const Duration(hours: 12));
      if (cached != null && cached.isNotEmpty) {
        homeVideos.value = cached
            .whereType<Map>()
            .map((e) => Video.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
    } catch (e) { /* ignore */ }

    isLoading.value = true;
    errorMessage.value = null;

    try {
      final result = await SourceService.instance.getSort(source);
      sorts.value = result.$1;
      homeVideos.value = result.$2;
      if (result.$2.isNotEmpty) {
        // 异步写缓存，不阻塞
        CacheStore.instance.setJsonCache(
          cacheKey,
          result.$2.map((v) => v.toJson()).toList(),
        );
      }

      // 默认选中第一个分类
      if (sorts.isNotEmpty) {
        selectedSort.value = sorts.first;
        selectedFilters.clear();
        currentPage.value = 1;
        hasMore.value = true;
        await _loadCategoryVideos(page: 1, sort: sorts.first);
      }
    } catch (e) {
      errorMessage.value = _friendlyErrorMessage(e);
    }

    isLoading.value = false;
  }

  void selectSort(SortData sort) {
    if (selectedSort.value?.id == sort.id) return;
    selectedSort.value = sort;
    errorMessage.value = null;
    videos.clear();
    currentPage.value = 1;
    hasMore.value = true;
    selectedFilters.clear();
    selectedFilters.refresh();

    _loadCategoryVideos(page: 1, sort: sort);
  }

  /// 选中/清除筛选，并刷新当前分类列表
  void selectFilter(String key, String value) {
    if (value.isEmpty) {
      selectedFilters.remove(key);
    } else {
      selectedFilters[key] = value;
    }
    selectedFilters.refresh();

    final sort = selectedSort.value;
    if (sort == null) return;
    videos.clear();
    currentPage.value = 1;
    hasMore.value = true;
    _loadCategoryVideos(page: 1, sort: sort);
  }

  /// 列表请求序号：筛选/分类快速切换时丢弃过期响应
  int _listRequestId = 0;

  Future<void> _loadCategoryVideos({
    required int page,
    required SortData sort,
  }) async {
    final source = ApiConfig.instance.homeSourceBean.value;
    if (source == null) return;

    final requestId = ++_listRequestId;
    final filters = selectedFilters.isEmpty ? null : Map<String, String>.from(selectedFilters);

    // 无筛选时才读缓存；带筛选的缓存 key 未区分条件，会塞回错误列表
    if (page == 1 && filters == null && videos.isEmpty) {
      final catCacheKey = 'cat_videos:${source.key}:${sort.id}';
      try {
        final cached = CacheStore.instance.getJsonListCache(
          catCacheKey,
          ttl: const Duration(hours: 6),
        );
        if (cached != null && cached.isNotEmpty) {
          videos.value = cached
              .whereType<Map>()
              .map((e) => Video.fromJson(Map<String, dynamic>.from(e)))
              .toList();
        }
      } catch (e) { /* ignore */ }
    }

    isLoading.value = true;

    try {
      final videoList = await SourceService.instance.getList(
        source,
        sort,
        page: page,
        filters: filters,
      );

      // 过期响应 / 分类已切换 → 丢弃
      if (requestId != _listRequestId || selectedSort.value?.id != sort.id) {
        return;
      }

      if (page == 1) {
        videos.value = videoList;
        // 只缓存「无筛选」的第一页
        if (videoList.isNotEmpty && filters == null) {
          CacheStore.instance.setJsonCache(
            'cat_videos:${source.key}:${sort.id}',
            videoList.map((v) => v.toJson()).toList(),
          );
        }
      } else {
        videos.addAll(videoList);
      }
      currentPage.value = page;
      hasMore.value = videoList.isNotEmpty;
      errorMessage.value = null;
    } catch (e) {
      if (requestId == _listRequestId && selectedSort.value?.id == sort.id) {
        errorMessage.value = _friendlyErrorMessage(e);
      }
    } finally {
      if (requestId == _listRequestId) {
        isLoading.value = false;
      }
    }
  }

  Future<void> loadMore() async {
    if (!hasMore.value || isLoading.value) return;
    final sort = selectedSort.value;
    if (sort == null) return;

    final nextPage = currentPage.value + 1;
    await _loadCategoryVideos(page: nextPage, sort: sort);
  }

  void loadMoreIfNeeded(Video currentItem) {
    if (!hasMore.value || isLoading.value) return;
    if (videos.isEmpty) return;
    if (videos.last.id != currentItem.id) return;
    final sort = selectedSort.value;
    if (sort == null) return;

    final nextPage = currentPage.value + 1;
    _loadCategoryVideos(page: nextPage, sort: sort);
  }

  Future<void> refresh() async {
    currentPage.value = 1;
    hasMore.value = true;
    videos.clear();
    errorMessage.value = null;
    await loadSorts();
  }

  String _friendlyErrorMessage(Object error) {
    final msg = error.toString();

    // DioException / 网络相关
    if (msg.contains('Connection refused') || msg.contains('connection refused')) {
      return '无法连接到本地服务，请稍后重试';
    }
    if (msg.contains('timed out') || msg.contains('TimedOut') || msg.contains('timeout')) {
      return '请求超时，请检查网络';
    }
    if (msg.contains('not connected') || msg.contains('No address associated')) {
      return '网络未连接，请检查网络设置';
    }
    if (msg.contains('Connection reset') || msg.contains('connection lost')) {
      return '网络连接中断，请稍后重试';
    }
    if (msg.contains('DNS') || msg.contains('dns')) {
      return 'DNS解析失败，请检查网络设置';
    }
    if (msg.contains('SocketException') || msg.contains('network')) {
      return '网络连接异常，请稍后重试';
    }

    return msg;
  }
}
