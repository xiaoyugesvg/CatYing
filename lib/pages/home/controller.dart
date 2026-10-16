import 'package:get/get.dart';
import '../../services/app_log.dart';
import '../../models/cache_store.dart';
import '../../models/cache_ttl.dart';
import '../../models/movie.dart';
import '../../models/movie_sort.dart';
import '../../services/api_config.dart';
import '../../services/source_service.dart';
import '../../reading/services/settings_service.dart';
import '../../webhome/webhtv_site_health_page.dart';

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
    // 监听主页源变化：立刻清掉旧源数据，避免幻灯片/列表还是上一个源
    ever(ApiConfig.instance.homeSourceBean, (source) {
      if (source != null) {
        homeVideos.clear();
        videos.clear();
        sorts.clear();
        selectedSort.value = null;
        selectedFilters.clear();
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
    var hasHomeCache = false;
    try {
      final cached = CacheStore.instance.getJsonListCache(cacheKey, ttl: CacheTtl.homeVideos);
      if (cached != null && cached.isNotEmpty) {
        homeVideos.value = cached
            .whereType<Map>()
            .map((e) => Video.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        hasHomeCache = true;
      }
    } catch (e) {
        AppLog.instance.log('[controller] swallowed: $e');
      }

    // 已有内容/缓存时后台刷新，不闪 Loading
    if (!hasHomeCache || videos.isEmpty) {
      isLoading.value = true;
    }
    errorMessage.value = null;

    try {
      final result = await SourceService.instance.getSort(source);
      sorts.value = result.$1;
      // ── Webhtv 站点健康：本次「首页/分类」加载成功（Webhtv → 站点健康排序）
      SiteHealthStore.instance.record(source.key, 'home', true);
      // ⚠️ 只在**非空**时才覆盖：py/js 脚本源的 home() 只返回分类、没有推荐列表，
      // 直接赋值会把上面刚读出来的「幻灯片缓存」清成空 → 顶部闪一下空白，
      // 然后再被 _fillBannerFromCategory 兜底填回来（用户会看到抖动）。
      if (result.$2.isNotEmpty) {
        homeVideos.value = result.$2;
        // 异步写缓存，不阻塞（列表页不显示简介 → 用 toJsonLite 省 56% 体积）
        CacheStore.instance.setJsonCache(
          cacheKey,
          result.$2.map((v) => v.toJsonLite()).toList(),
        );
      }

      // 默认选中第一个分类
      if (sorts.isNotEmpty) {
        selectedSort.value = sorts.first;
        selectedFilters.clear();
        currentPage.value = 1;
        hasMore.value = true;
        await _loadCategoryVideos(page: 1, sort: sorts.first);
        // 源没给推荐列表时用第一个分类兜底当幻灯片
        _fillBannerFromCategory(source.key);
      }
    } catch (e) {
      // ── Webhtv 站点健康：本次「首页/分类」加载失败
      SiteHealthStore.instance.record(source.key, 'home', false);
      errorMessage.value = _friendlyErrorMessage(e);
    }

    isLoading.value = false;
  }

  void selectSort(SortData sort) {
    if (selectedSort.value?.id == sort.id) return;
    selectedSort.value = sort;
    errorMessage.value = null;
    // 不要 clear：保留旧列表直到缓存/网络回来，避免整页 Loading 闪一下
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
    currentPage.value = 1;
    hasMore.value = true;
    _loadCategoryVideos(page: 1, sort: sort);
  }

  /// 列表请求序号：筛选/分类快速切换时丢弃过期响应
  int _listRequestId = 0;

  /// 上一次请求的「分类+筛选」签名；变了就跳过缓存强制走网络
  String _lastQuerySig = '';

  /// 缓存 key 必须带上筛选条件，否则会塞回错误列表
  String _catCacheKey(
      String sourceKey, String sortId, Map<String, String>? filters) {
    if (filters == null || filters.isEmpty) {
      return 'cat_videos:$sourceKey:$sortId';
    }
    final parts = filters.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final filterKey = parts.map((e) => '${e.key}=${e.value}').join('&');
    return 'cat_videos:$sourceKey:$sortId:$filterKey';
  }

  Future<void> _loadCategoryVideos({
    required int page,
    required SortData sort,
  }) async {
    final source = ApiConfig.instance.homeSourceBean.value;
    if (source == null) return;

    final requestId = ++_listRequestId;
    final filters = selectedFilters.isEmpty
        ? null
        : Map<String, String>.from(selectedFilters);
    final cacheKey = _catCacheKey(source.key, sort.id, filters);

    // 筛选/分类变化时**必须强制走网络**。
    //
    // 原因：命中缓存时下面会把 cacheHit 置为 true → 不显示 loading →
    // 界面上完全看不出"点过了"；若网络回包恰好与旧列表相同，列表也不动，
    // 用户就会认为"筛选点了没反应、内容不跟着换"。
    // 这里比较筛选签名，变了就跳过缓存，保证有加载反馈且拿到的是新结果。
    final sig = '${sort.id}|${cacheKey}';
    final filterChanged = _lastQuerySig != sig;
    _lastQuerySig = sig;

    // 第一页优先读缓存：立刻出片，网络刷新静默
    var cacheHit = false;
    if (page == 1 && !filterChanged) {
      try {
        final cached = CacheStore.instance.getJsonListCache(
          cacheKey,
          ttl: CacheTtl.categoryList,
        );
        if (cached != null && cached.isNotEmpty) {
          final list = cached
              .whereType<Map>()
              .map((e) => Video.fromJson(Map<String, dynamic>.from(e)))
              .toList();
          if (requestId == _listRequestId) {
            // 同 _loadCategoryVideos：RxList 要用 assignAll 才会通知 Obx
            videos.assignAll(list);
            cacheHit = true;
          }
        }
      } catch (e) {
        AppLog.instance.log('[controller] swallowed: $e');
      }
    }

    // 有缓存时只做后台刷新；无缓存才显示 Loading
    if (!cacheHit) {
      isLoading.value = true;
    }

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
        // 与缓存相同则不闪一下
        if (!cacheHit || !_sameVideoIds(videos, videoList)) {
          // ⚠️ 必须用 assignAll，不能写 `videos.value = videoList`：
          // videos 是 RxList，GetX 对它的通知走内部 listeners，
          // 直接替换 .value 时 Obx **不一定重建** —— 表现就是
          // "点了筛选、请求发了、数据也回来了，但列表纹丝不动"。
          // assignAll 就地更新，保证通知到所有 Obx。
          videos.assignAll(videoList);
        }
        if (videoList.isNotEmpty) {
          CacheStore.instance.setJsonCache(
            cacheKey,
            videoList.map((v) => v.toJsonLite()).toList(),
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
        // 缓存已有内容时，网络失败不打断浏览
        if (!cacheHit) {
          errorMessage.value = _friendlyErrorMessage(e);
        }
      }
    } finally {
      if (requestId == _listRequestId) {
        isLoading.value = false;
      }
    }
  }

  bool _sameVideoIds(List<Video> a, List<Video> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  /// 幻灯片兜底：部分源 —— **尤其 type=3 的 py / js 脚本源** —— 的 `home()`
  /// 只返回分类（`class`）、不带推荐列表（`list`）⇒ 首页顶部会空一块。
  ///
  /// 这里用**刚加载好的第一个分类**当幻灯片：
  ///   · 复用同一份数据 ⇒ **不额外发请求**（py 源走 CPython，一次请求不便宜）
  ///   · 顺手写进首页缓存 `home_videos:<源>` ⇒ 下次冷启动走缓存立刻有图
  ///
  /// 连分类列表都为空时什么都不做 —— 顶部由 `_buildContentArea` 整块隐藏。
  void _fillBannerFromCategory(String sourceKey) {
    if (homeVideos.isNotEmpty || videos.isEmpty) return;
    // 取**上限**张（9）：各样式实际用几张由 homeBannerItemCount 决定（6~9），
    // 显示时再裁 —— 这里多抓几张才能让"九宫格 / 双卡"这些样式够用
    final picks = videos.take(kHomeBannerMaxItems).toList();
    homeVideos.assignAll(picks);
    try {
      CacheStore.instance.setJsonCache(
        'home_videos:$sourceKey',
        picks.map((v) => v.toJsonLite()).toList(),
      );
    } catch (e) {
      AppLog.instance.log('[controller] 写幻灯片兜底缓存失败: $e');
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
    // 保留当前分类/筛选，下拉刷新只拉数据，不重置用户选择
    final keepSort = selectedSort.value;
    final keepFilters = Map<String, String>.from(selectedFilters);
    errorMessage.value = null;
    final source = ApiConfig.instance.homeSourceBean.value;
    if (source == null) return;

    isLoading.value = true;
    try {
      final result = await SourceService.instance.getSort(source);
      sorts.value = result.$1;
      // 同 loadSorts：只在非空时覆盖，别把兜底/缓存的幻灯片清掉
      if (result.$2.isNotEmpty) {
        homeVideos.value = result.$2;
        CacheStore.instance.setJsonCache(
          'home_videos:${source.key}',
          result.$2.map((v) => v.toJsonLite()).toList(),
        );
      }

      final sort = (keepSort != null &&
              sorts.any((s) => s.id == keepSort.id))
          ? keepSort
          : (sorts.isNotEmpty ? sorts.first : null);
      if (sort == null) {
        isLoading.value = false;
        return;
      }
      selectedSort.value = sort;
      selectedFilters
        ..clear()
        ..addAll(keepFilters);
      selectedFilters.refresh();
      currentPage.value = 1;
      hasMore.value = true;
      // 不清空旧列表：请求回来再替换，避免刷新时白屏
      await _loadCategoryVideos(page: 1, sort: sort);
      // 与 loadSorts 同一套兜底：源没给推荐列表就用第一个分类当幻灯片
      _fillBannerFromCategory(source.key);
    } catch (e) {
      errorMessage.value = _friendlyErrorMessage(e);
    }
    isLoading.value = false;
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
