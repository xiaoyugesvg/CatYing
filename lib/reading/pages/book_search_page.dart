import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../../widgets/common_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/book.dart';
import '../models/book_category.dart';
import '../models/book_source.dart';
import '../models/search_result.dart';
import '../services/book_download_service.dart';
import '../../services/main_tab_controller.dart';
import '../services/book_view_mode.dart';
import '../services/browse_history_service.dart';
import '../services/search_history_service.dart';
import '../services/zlibrary_service.dart';
import '../theme/jelly_theme.dart';
import '../services/settings_service.dart';
import '../widgets/jelly_book_card.dart';
import '../widgets/jelly_nav_bar.dart';
import '../widgets/jelly_ring_button.dart';
import '../widgets/jelly_expandable_search.dart';
import '../widgets/jelly_pull_cord.dart';
import '../widgets/guide_overlay.dart';
import '../widgets/jelly_segmented_toggle.dart';
import '../widgets/staggered_entrance.dart';
import 'book_detail_page.dart';
import 'book_source_repo_page.dart';
import 'book_source_search_page.dart';
import 'douban_ranking_page.dart';
import 'browse_history_page.dart';
import 'download_page.dart';
import 'favorites_page.dart';
import 'zlibrary_auth_page.dart';
import '../../common/theme.dart';
import '../../widgets/app_icon_button.dart';
import '../../widgets/app_page_header.dart';

/// 日志工具
void _log(String message) {
  if (kDebugMode) {
    print('[BookSearchPage] $message');
  }
}

/// 豆瓣图床反爬头：无 Referer/手机 UA 会返回 HTTP 418（实测），
/// 热门推荐封面必须带上。
const _doubanImageHeaders = <String, String>{
  'User-Agent':
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
          'Mobile/15E148 Safari/604.1',
  'Referer': 'https://m.douban.com/',
};

/// 图书搜索页面（果冻风，布局同漫画搜索 + 格式筛选 + 右上角 z-library 登录头像）
class BookSearchPage extends StatefulWidget {
  /// 是否为当前激活的 tab（用于触发结果瀑布入场动画）
  final bool isActive;

  /// 是否显示返回按钮（从"我的"页面入口进入时为 true）
  final bool showBackButton;

  const BookSearchPage({
    super.key,
    this.isActive = false,
    this.showBackButton = false,
  });

  @override
  State<BookSearchPage> createState() => _BookSearchPageState();
}

class _BookSearchPageState extends State<BookSearchPage>
    with TickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();

  // 网格/列表视图切换控制器（参考下载页：滑块与 TabBarView 由同一 animation 驱动，1:1 同步）
  late final TabController _tabController;

  // 两种视图各自独立的滚动控制器，避免切换时冲突卡死
  final ScrollController _gridScrollController = ScrollController();
  final ScrollController _listScrollController = ScrollController();

  SearchResult<Book> _result = SearchResult.empty();
  bool _isLoading = false;
  bool _isSearching = false;
  String _keyword = '';
  bool _guideShown = false; // 新手引导已展示标记

  // 分类额外过滤条件：年份/语言仅分类模式用；格式 _filterExtensions 与搜索页小标签
  // 同源联动，关键词/分类模式都用，跨模式保留。
  bool _categoryMode = false; // 分类浏览模式（与关键词搜索互斥）
  BookCategory? _selectedCategory; // 当前选中的子分类
  bool _categorySheetOpening = false; // 分类弹窗防连点守卫
  int? _filterYearFrom;
  int? _filterYearTo;
  List<String> _filterLanguages = [];
  List<String> _filterExtensions = [];

  bool _showBackToTop = false;
  bool _historyVisible = false;
  List<String> _history = [];
  int _searchSession = 0;
  String? _errorMsg; // 搜索异常信息
  /// z-library 可用性上一状态（仅状态变化才弹通知；null=尚未初始化）
  bool? _wasUnavailable;

  /// 热门推荐流（豆瓣 book_hot，不依赖 z-library）——进页即拉，
  /// 供未搜索/无结果时直接展示热门书籍网格。
  List<Book> _hotBooks = [];
  bool _hotLoading = false;
  bool _hotFailed = false;

  ScrollController get _activeScrollController =>
      _tabController.index == 0 ? _gridScrollController : _listScrollController;

  bool get _showHistory => _historyVisible && _searchController.text.isEmpty;

  @override
  void initState() {
    super.initState();
    _log('页面初始化');
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: BookViewMode().isGrid ? 0 : 1,
    );
    _tabController.addListener(_onTabChanged);
    _gridScrollController.addListener(() => _onScroll(_gridScrollController));
    _listScrollController.addListener(() => _onScroll(_listScrollController));
    BookViewMode().addListener(_onViewModeChangedExternal);
    ZlibraryService().addListener(_onServiceChanged);
    BookDownloadService().addListener(_onServiceChanged);
    _wasUnavailable = ZlibraryService().isUnavailable;
    _loadHistory();
    _ensureCategories();
    _maybeTriggerGuide();
    _loadHotBooks();
  }

  /// 首次激活时展示图书页新手引导（仅一次）
  void _maybeTriggerGuide() {
    if (_guideShown || !widget.isActive) return;
    _guideShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) maybeShowGuide(context, GuideGroups.book);
    });
  }

  @override
  void didUpdateWidget(covariant BookSearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) _maybeTriggerGuide();
  }

  @override
  void dispose() {
    _log('页面销毁');
    BookViewMode().removeListener(_onViewModeChangedExternal);
    ZlibraryService().removeListener(_onServiceChanged);
    BookDownloadService().removeListener(_onServiceChanged);
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _searchController.dispose();
    _gridScrollController.dispose();
    _listScrollController.dispose();
    super.dispose();
  }

  void _onServiceChanged() {
    if (!mounted) return;
    final unavailable = ZlibraryService().isUnavailable;
    final prev = _wasUnavailable;
    _wasUnavailable = unavailable;
    // 仅状态变化才弹通知（恢复/受限）
    if (prev != null && prev != unavailable) {
      _notifyAvailability(unavailable);
    }
    setState(() {});
  }

  void _notifyAvailability(bool unavailable) {
    final msg = unavailable
        ? '所有 z-library 节点不可用，图书功能暂不可用，请等待恢复'
        : 'z-library 节点已恢复可用';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: unavailable
              ? const Duration(seconds: 8)
              : const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _loadHistory() async {
    final h = await SearchHistoryService.load(key: 'book_search_history');
    _log('加载搜索历史: ${h.length} 条');
    if (mounted) setState(() => _history = h);
  }

  /// 分类目录：缓存为空且域名就绪时后台拉取一次。
  /// 成功后 ZlibraryService.notifyListeners 触发 _onServiceChanged 重建，分类按钮自动显示。
  Future<void> _ensureCategories() async {
    if (BookCategories.groups.isNotEmpty) return;
    if (ZlibraryService().isUnavailable) return;
    try {
      await ZlibraryService().fetchCategories();
    } catch (e) {
      _log('后台拉取分类失败: $e');
    }
  }

  /// 拉豆瓣热门榜（book_hot）作主页推荐流，不依赖 z-library。
  ///
  /// 失败静默（只置 _hotFailed），不阻塞搜索/分类等其它入口。
  Future<void> _loadHotBooks() async {
    if (_hotLoading) return;
    _hotLoading = true;
    _hotFailed = false;
    if (mounted) setState(() {});
    try {
      final dio = Dio(BaseOptions(
        headers: {
          'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
                  'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
                  'Mobile/15E148 Safari/604.1',
          'Referer': 'https://m.douban.com/book/chart/',
        },
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 12),
      ));
      final r = await dio.get(
        'https://m.douban.com/rexxar/api/v2/subject_collection/book_hot/items',
        queryParameters: {'start': 0, 'count': 20},
      );
      final data = r.data;
      final raw = (data is Map) ? data['subject_collection_items'] : null;
      final list = <Book>[];
      if (raw is List) {
        for (final e in raw) {
          if (e is! Map) continue;
          final j = e.cast<String, dynamic>();
          final title = (j['title'] ?? '').toString().trim();
          if (title.isEmpty) continue;
          final sub = (j['card_subtitle'] ?? '').toString().trim();
          final author =
              sub.split('/').first.trim(); // "作者 / 年份 / 出版社"
          list.add(Book(
            id: 'douban-${j['id'] ?? title}',
            hash: '',
            title: title,
            author: author,
            cover: _doubanCoverOf(j),
            year: sub.split('/').length > 1
                ? sub.split('/')[1].trim()
                : null,
            description: (j['description'] ?? '').toString().trim(),
            publisher: sub.split('/').length > 2
                ? sub.split('/')[2].trim()
                : null,
          ));
        }
      }
      if (!mounted) return;
      setState(() {
        _hotBooks = list;
        _hotFailed = list.isEmpty;
      });
    } catch (e) {
      _log('热门推荐拉取失败: $e');
      if (mounted) setState(() => _hotFailed = true);
    } finally {
      _hotLoading = false;
      if (mounted) setState(() {});
    }
  }

  /// 豆瓣 cover 兼容字符串与对象两种形态（对象是 {url,...}）。
  static String _doubanCoverOf(Map<String, dynamic> j) {
    final c = j['cover'];
    if (c is String) return c;
    if (c is Map) {
      final u = c['url'];
      if (u is String && u.isNotEmpty) return u;
    }
    return '';
  }

  Future<void> _addHistory(String keyword) async {
    final h = await SearchHistoryService.add(
      keyword,
      key: 'book_search_history',
    );
    if (mounted) setState(() => _history = h);
  }

  Future<void> _removeHistory(String keyword) async {
    final h = await SearchHistoryService.remove(
      keyword,
      key: 'book_search_history',
    );
    if (mounted) setState(() => _history = h);
  }

  Future<void> _clearHistory() async {
    final h = await SearchHistoryService.clear(key: 'book_search_history');
    if (mounted) setState(() => _history = h);
  }

  void _onScroll(ScrollController controller) {
    if (!controller.hasClients) return;
    final pixels = controller.position.pixels;
    final max = controller.position.maxScrollExtent;
    final nearBottom = pixels >= max - 200 && max > 0;
    if (nearBottom) {
      _log('onScroll 触底: pixels=$pixels, max=$max, hasMore=${_result.hasMore}');
      _loadMore();
    }
    final show = pixels > 300;
    if (show != _showBackToTop) {
      setState(() => _showBackToTop = show);
    }
  }

  /// 执行一次搜索（来自提交或历史记录点击）
  Future<void> _runSearch(String keyword) async {
    _log('runSearch: "$keyword"');
    FocusScope.of(context).unfocus();
    _keyword = keyword;
    _searchController.text = keyword;
    _searchController.selection = TextSelection.collapsed(
      offset: keyword.length,
    );
    setState(() {
      _historyVisible = false;
      _errorMsg = null;
    });
    // 关键词搜索退出分类模式
    if (keyword.trim().isNotEmpty) _exitCategoryMode();
    // 未登录时默认使用内置账号搜索（不受"使用内置账号"开关限制），无需弹登录框
    _addHistory(keyword);
    _doSearch();
  }

  Future<void> _doSearch({bool loadMore = false}) async {
    _log('开始搜索, loadMore=$loadMore, isLoading=$_isLoading, keyword=$_keyword');

    // 分类模式走 WebView 抓 HTML
    if (_categoryMode && _selectedCategory != null) {
      await _doCategorySearch(loadMore: loadMore);
      return;
    }

    if (_isLoading) return;
    if (!loadMore && _keyword.trim().isEmpty) return;

    setState(() {
      _isLoading = true;
      _errorMsg = null;
      if (!loadMore) _isSearching = true;
    });

    try {
      final page = loadMore ? _result.currentPage + 1 : 1;
      final newResult = await ZlibraryService().search(
        _keyword,
        extensions: _filterExtensions.isEmpty ? null : _filterExtensions,
        page: page,
      );
      _log('API返回: ${newResult.items.length} 条, 总数: ${newResult.total}');

      if (mounted) {
        setState(() {
          if (loadMore) {
            _result = SearchResult<Book>(
              items: [..._result.items, ...newResult.items],
              total: newResult.total,
              currentPage: newResult.currentPage,
              totalPages: newResult.totalPages,
            );
          } else {
            _result = newResult;
            _searchSession++;
          }
        });
      }
    } on ZlibraryException catch (e) {
      _log('搜索业务异常: ${e.code} ${e.message}');
      if (mounted) setState(() => _errorMsg = _friendlyError(e));
    } catch (e) {
      _log('搜索异常: $e');
      if (mounted) setState(() => _errorMsg = '搜索失败，请检查网络或稍后重试');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isSearching = false;
        });
      }
    }
  }

  String _friendlyError(ZlibraryException e) {
    switch (e.code) {
      case 'no_account':
        return '没有可用的内置账号，请登录自有账号';
      case 'no_login':
        return '登录已失效，请重新登录';
      case 'unavailable':
        return '图书功能暂不可用，请等待恢复';
      case 'rate_limited':
        return '请求过于频繁，请稍后再试';
      default:
        return e.message;
    }
  }

  // -------------------- 分类筛选（仿漫画搜索 search_page.dart）--------------------

  /// 分类筛选按钮（视图切换右边；分类表为空则隐藏）。
  bool get _hasActiveFilters =>
      _filterYearFrom != null ||
      _filterYearTo != null ||
      _filterLanguages.isNotEmpty ||
      _filterExtensions.isNotEmpty;

  Widget _buildCategoryButton(bool isDark) {
    if (ZlibraryService().isUnavailable) return const SizedBox.shrink();
    final active = _categoryMode;
    final hasFilter = _hasActiveFilters;
    return GestureDetector(
      onTap: () => _openCategorySheet(isDark),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: active
                  ? JellyTheme.primary
                  : (isDark ? JellyTheme.cardDark : JellyTheme.cardLight),
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(
              Icons.tune_rounded,
              size: 20,
              color: active
                  ? Colors.white
                  : (isDark ? Colors.white70 : JellyTheme.textSecondary),
            ),
          ),
          if (hasFilter)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Colors.redAccent,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 打开分类筛选弹窗（主分类 → 子分类两级，底部重置/确定）。
  /// 打开分类筛选弹窗（主分类 -> 子分类 + 年份/语言/格式过滤，底部重置/确定）。
  /// 打开分类筛选弹窗（主分类 -> 子分类 + 年份/语言/格式过滤，底部重置/确定）。
  Future<void> _openCategorySheet(bool isDark) async {
    if (_categorySheetOpening) return;
    _categorySheetOpening = true;
    FocusScope.of(context).unfocus();
    try {
      if (!BookCategories.supported) {
        // 缓存为空：先拉取一次（首拉失败的重试入口）
        _showTip('正在加载分类...');
        try {
          await ZlibraryService().fetchCategories(force: true);
        } catch (e) {
          _log('打开分类弹窗前拉取失败: $e');
        }
        if (!mounted) return;
        if (!BookCategories.supported) {
          _showTip('分类加载失败，请稍后重试');
          return;
        }
      }
      final result = await showModalBottomSheet<_BookCategorySheetResult?>(
        context: context,
        isScrollControlled: true,
        backgroundColor:
            isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) => kbSheet(_BookCategorySheet(
          isDark: isDark,
          initialCategory: _selectedCategory,
          initialYearFrom: _filterYearFrom,
          initialYearTo: _filterYearTo,
          initialLanguages: _filterLanguages,
          initialExtensions: _filterExtensions,
        )),
      );
      if (result is _BookCategorySheetResult && mounted) {
        _applyCategory(result);
      }
    } finally {
      _categorySheetOpening = false;
    }
  }

  /// 应用分类选择：切分类模式、清空搜索框、按分类列出。
  void _applyCategory(_BookCategorySheetResult r) {
    FocusScope.of(context).unfocus();
    _selectedCategory = r.category;
    _categoryMode = true;
    _filterYearFrom = r.yearFrom;
    _filterYearTo = r.yearTo;
    _filterLanguages = List.of(r.languages);
    _filterExtensions = List.of(r.extensions);
    _keyword = '';
    _searchController.clear();
    setState(() {
      _result = SearchResult.empty();
      _historyVisible = false;
      _errorMsg = null;
    });
    _doCategorySearch();
  }

  /// 退出分类模式（搜索框输入关键词时调用）。
  /// 格式 `_filterExtensions` 跨模式保留（与搜索页小标签联动）；年份/语言仅分类模式用，清空。
  void _exitCategoryMode() {
    if (!_categoryMode) return;
    _categoryMode = false;
    _selectedCategory = null;
    _filterYearFrom = null;
    _filterYearTo = null;
    _filterLanguages = [];
  }

  /// 分类浏览搜索（走 WebView 抓 HTML，分页复用 _result）。
  Future<void> _doCategorySearch({bool loadMore = false}) async {
    _log('开始分类搜索, loadMore=$loadMore, category=$_selectedCategory');
    if (_isLoading) return;
    if (_selectedCategory == null) return;
    setState(() {
      _isLoading = true;
      _errorMsg = null;
      if (!loadMore) _isSearching = true;
    });
    try {
      final page = loadMore ? _result.currentPage + 1 : 1;
      final newResult = await ZlibraryService().searchInCategory(
        _selectedCategory!,
        keyword: _keyword.trim().isEmpty ? null : _keyword.trim(),
        page: page,
        yearFrom: _filterYearFrom,
        yearTo: _filterYearTo,
        languages: _filterLanguages.isEmpty ? null : _filterLanguages,
        extensions: _filterExtensions.isEmpty ? null : _filterExtensions,
      );
      _log('分类返回: ${newResult.items.length} 条, 总数: ${newResult.total}');
      if (mounted) {
        setState(() {
          if (loadMore) {
            _result = SearchResult<Book>(
              items: [..._result.items, ...newResult.items],
              total: newResult.total,
              currentPage: newResult.currentPage,
              totalPages: newResult.totalPages,
            );
          } else {
            _result = newResult;
            _searchSession++;
          }
        });
      }
    } on ZlibraryException catch (e) {
      _log('分类搜索业务异常: ${e.code} ${e.message}');
      if (mounted) setState(() => _errorMsg = _friendlyError(e));
    } catch (e) {
      _log('分类搜索异常: $e');
      if (mounted) setState(() => _errorMsg = '分类搜索失败，请检查网络或稍后重试');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isSearching = false;
        });
      }
    }
  }

  void _loadMore() {
    _log(
      'loadMore 触发: hasMore=${_result.hasMore}, isLoading=$_isLoading, '
      'currentPage=${_result.currentPage}, totalPages=${_result.totalPages}, '
      'items=${_result.items.length}',
    );
    if (_result.hasMore && !_isLoading) {
      if (_categoryMode) {
        _doCategorySearch(loadMore: true);
      } else {
        _doSearch(loadMore: true);
      }
    }
  }

  void _scrollToTop() {
    final controller = _activeScrollController;
    if (controller.hasClients) {
      controller.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// tab 停稳后回写 BookViewMode（持久化 + 供图书收藏页/显示设置页联动）；幂等判断防循环
  void _onTabChanged() {
    if (!_tabController.indexIsChanging) {
      final isGrid = _tabController.index == 0;
      if (BookViewMode().isGrid != isGrid) BookViewMode().set(isGrid);
    }
    final c = _activeScrollController;
    final show = c.hasClients && c.position.pixels > 300;
    if (show != _showBackToTop) {
      _showBackToTop = show;
      if (mounted) setState(() {});
    }
  }

  /// 外部（显示设置页等）改了 BookViewMode -> 同步 tab；幂等判断防循环
  void _onViewModeChangedExternal() {
    if (!mounted) return;
    final target = BookViewMode().isGrid ? 0 : 1;
    if (_tabController.index != target) {
      _tabController.animateTo(target);
    }
  }

  // -------------------- 详情 --------------------

  /// 拉绳「卷帘」：弹出书源层（第一层=当前模式，第二层=已导入书源列表）。
  /// 点选源 → 单源搜索页；长按源标签 → 登录管理；底部可进书源仓库。
  void _showSourceLayerSheet(bool isDark) {
    final store = BookSourceStore.instance;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return Container(
          decoration: BoxDecoration(
            color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.2)
                        : Colors.black.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '切换书源',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? Colors.white
                            : JellyTheme.textPrimaryLight,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '长按书源可登录管理账号；点选书源进入该书源搜索',
                      style: TextStyle(
                        fontSize: 12,
                        color: JellyTheme.textSecondary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                // 第一层：z-library 图书搜索（当前模式）
                ListTile(
                  leading: Icon(
                    Icons.auto_stories_rounded,
                    color: JellyTheme.primary,
                  ),
                  title: const Text('z-library 图书搜索'),
                  subtitle: const Text('当前模式：按书名/作者/ISBN 搜索'),
                  trailing: Icon(
                    Icons.check_circle_rounded,
                    color: JellyTheme.primary,
                    size: 20,
                  ),
                  onTap: () => Navigator.pop(sheetCtx),
                ),
                // 第二层：已导入书源列表
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '已导入书源（${store.enabled.length}）',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: JellyTheme.textSecondary,
                      ),
                    ),
                  ),
                ),
                if (store.enabled.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '暂无书源，去书源仓库导入 Legado 书源',
                        style: TextStyle(
                          fontSize: 12,
                          color: JellyTheme.textSecondary,
                        ),
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      children: [
                        for (final src in store.enabled)
                          ListTile(
                            dense: true,
                            leading: Icon(
                              Icons.library_books_outlined,
                              color: JellyTheme.primary,
                            ),
                            title: Text(src.name),
                            subtitle: Text(
                              '搜索「${_keyword.trim().isEmpty ? '输入关键词' : _keyword.trim()}」',
                            ),
                            onTap: () {
                              Navigator.pop(sheetCtx);
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => BookSourceSearchPage(
                                    initialKeyword: _keyword.trim(),
                                    initialSourceId: src.id,
                                  ),
                                ),
                              );
                            },
                            onLongPress: () {
                              Navigator.pop(sheetCtx);
                              _showTip('书源「${src.name}」：可在书源仓库管理登录');
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => const BookSourceRepoPage(),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.settings_suggest_outlined, size: 18),
                      label: const Text('管理书源'),
                      onPressed: () {
                        Navigator.pop(sheetCtx);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const BookSourceRepoPage(),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openDetail(Book book) async {
    FocusScope.of(context).unfocus(); // 进详情前先收起键盘与历史弹层
    // 分类页来源（hash 是 dl/{slug}，无 eapi hash）：先搜索匹配 bookId 拿 eapi hash
    var target = book;
    if (book.hash.startsWith('dl/')) {
      final matched = await _matchBookBySearch(book);
      if (!mounted) return;
      if (matched == null) {
        _showTip('未找到匹配图书，无法下载');
        return;
      }
      target = matched;
    }
    if (!mounted) return;
    BrowseHistoryService().recordBook(target); // 记录浏览（去重置顶，仅搜索页入口记录）
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BookDetailPage(
          book: target,
          heroTag: bookCoverHeroTag('search', target),
          searchResults: _result.items,
        ),
      ),
    );
  }

  /// 分类页来源的书（hash 是 dl/{slug}）通过 eapi 搜索匹配 bookId，拿 eapi hash。
  /// 用 title + extension + language + year 组合搜索提高准确性，优先 bookId 匹配。
  Future<Book?> _matchBookBySearch(Book book) async {
    // 命中缓存直接返回，避免同一本分类书重复点击反复搜索
    final cached = ZlibraryService().categoryMatchCache(book.id);
    if (cached != null) {
      _log('命中分类匹配缓存: ${book.id} hash=${cached.hash}');
      return cached;
    }
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: JellyTheme.primary),
              const SizedBox(width: 16),
              const Text('正在匹配图书...'),
            ],
          ),
        ),
      ),
    );
    try {
      final year = int.tryParse(book.year ?? '');
      _log(
        '分类书搜索匹配: title="${book.title}", ext=${book.extension}, '
        'lang=${book.language}, year=$year, id=${book.id}',
      );
      final result = await ZlibraryService().search(
        book.title,
        extensions: (book.extension == null || book.extension!.isEmpty)
            ? null
            : [book.extension!],
        languages: book.language,
        yearFrom: year,
        yearTo: year,
        limit: 20,
      );
      _log('分类书搜索返回 ${result.items.length} 条');
      // 优先 bookId 匹配（z-library bookId 全局唯一）
      for (final b in result.items) {
        if (b.id == book.id) {
          _log('bookId 匹配成功: ${b.id} hash=${b.hash}');
          ZlibraryService().setCategoryMatchCache(b);
          return b;
        }
      }
      // 备选：title+year+language+extension 组合匹配
      for (final b in result.items) {
        if (b.title == book.title &&
            b.year == book.year &&
            b.language == book.language &&
            b.extension == book.extension) {
          _log('组合匹配成功: ${b.id} hash=${b.hash}');
          ZlibraryService().setCategoryMatchCache(b);
          return b;
        }
      }
      _log('未匹配到图书');
      return null;
    } catch (e) {
      _log('分类书搜索匹配失败: $e');
      return null;
    } finally {
      if (mounted) Navigator.pop(context); // 关 loading
    }
  }

  void _showTip(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  // -------------------- 头像 / 登录 --------------------

  Future<void> _onAvatarTap() async {
    final z = ZlibraryService();
    if (z.isLoggedIn) {
      // 已登录：弹出账号信息 + 退出登录
      await _showLogoutDialog(z);
      return;
    }
    // 未登录：弹登录框
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const ZlibraryAuthPage()),
    );
    if (ok == true && mounted) {
      _showTip('登录成功');
    }
  }

  /// 已登录账号弹窗：展示账号信息 + 今日下载配额 + 退出登录（果冻风）
  Future<void> _showLogoutDialog(ZlibraryService z) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final limit = z.serverDownloadsLimit ?? ZlibraryService.loggedDailyLimit;
    final used = z.loggedCountToday;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          decoration: BoxDecoration(
            color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
            borderRadius: BorderRadius.circular(20),
            boxShadow: JellyTheme.jellyShadows(
              color: JellyTheme.primary,
              blurRadius: 30,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 头像（与顶栏一致：主色圆底 + user.png）
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: JellyTheme.primary,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Image.asset(
                    'assets/icons/user.png',
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Icon(
                      Icons.person_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                z.username.isEmpty ? z.email : z.username,
                style: TextStyle(
                  fontSize: AppTheme.fontTitle3,
                  fontWeight: FontWeight.w700,
                  color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                ),
              ),
              if (z.username.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  z.email,
                  style: TextStyle(
                    fontSize: AppTheme.fontSubhead,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
              const SizedBox(height: 16),
              // 今日下载配额
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: JellyTheme.primary.withValues(
                    alpha: isDark ? 0.18 : 0.08,
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.menu_book_rounded,
                      size: 18,
                      color: JellyTheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '今日下载  $used / $limit 本',
                      style: TextStyle(
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w600,
                        color: isDark
                            ? Colors.white70
                            : JellyTheme.textPrimaryLight,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // 退出后回退提示
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 15,
                    color: JellyTheme.accent,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '退出后将回退内置账号（${ZlibraryService.builtinDailyLimit} 本/天）',
                      style: TextStyle(
                        fontSize: AppTheme.fontFootnote,
                        color: JellyTheme.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              // 按钮区
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        style: TextButton.styleFrom(
                          foregroundColor: JellyTheme.primary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: const Text(
                          '取消',
                          style: TextStyle(
                            fontSize: AppTheme.fontHeadline,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _LogoutButton(
                      onTap: () => Navigator.pop(ctx, 'logout'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (action == 'logout' && mounted) {
      await z.logout();
      _showTip('已退出登录');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: widget.showBackButton ? null : Colors.transparent,
      appBar: widget.showBackButton
          ? AppBar(
              title: const Text('图书'),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Transform.translate(
                    offset: const Offset(0, 4),
                    child: _buildAvatar(isDark),
                  ),
                ),
              ],
            )
          : null,
      floatingActionButton: ListenableBuilder(
        listenable: SettingsService(),
        builder: (context, _) {
          final fabOffset = SettingsService().navFloating
              ? JellyNavBar.floatingTotalHeight + 8
              : 0.0;
          return Padding(
            padding: EdgeInsets.only(bottom: fabOffset),
            child: _buildBackToTopButton(),
          );
        },
      ),
      body: Column(
        children: [
          SafeArea(
            top: !widget.showBackButton,
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
              child: Column(
                children: [
                  // ── 标题行（按截图：一行放下全部控件）──────────────
                  //   图书 ⋮拉绳  [搜索图书]  (视图切换)  (下载) ··· 其他
                  //
                  // 原来是**两行**：第一行「标题 + 拉绳 + 滑动图标组 + 头像」，
                  // 第二行「搜索框 + 视图切换」。截图里是一行，
                  // 所以把搜索框、视图切换、下载都并进来。
                  //
                  // 拉绳紧跟标题（截图位置），不再被 Spacer 推到右侧。
                  if (!widget.showBackButton)
                    Row(
                      children: [
                        AppPageTitle('图书', isDark: isDark),
                        const SizedBox(width: 4),
                        // 「拉绳」：标题右边那根挂着的小绳（点它切到书源）。
                        // 它是**挂饰**不是普通按钮，所以不带底色、
                        // 也不参与右侧图标的横排/展开逻辑。
                        JellyPullCord(
                          // ⚠️ 必须限高：绳子的 CustomPaint 自然高 50，
                          // 不限的话这一行会被撑到 50px，同排的搜索框/圆图标
                          // 垂直错位、圆环还会探出压到搜索框上。
                          height: 40,
                          tooltip: '切换书源',
                          onTap: () => _showSourceLayerSheet(isDark),
                        ),
                        const SizedBox(width: 10),
                        // 搜索框占据剩余宽度（Expanded 让右侧图标始终贴边）
                        Expanded(child: _buildSearchBar(isDark)),
                        const SizedBox(width: 8),
                        // 指环切换菜单：视图/下载/分类/常用操作收敛成一个环按钮
                        //（z-library 头像保留在右侧作为登录入口）
                        JellyRingButton(
                          isDark: isDark,
                          tooltip: '切换菜单',
                          menuBuilder: (ctx) => JellyRingMenuPanel(
                            isDark: isDark,
                            title: '切换菜单',
                            children: [
                              // 视图切换（网格/列表）
                              JellyRingMenuRow(
                                isDark: isDark,
                                label: '视图',
                                child: _buildViewToggle(isDark),
                              ),
                              // 分类筛选（年份/语言/格式）
                              JellyRingMenuRow(
                                isDark: isDark,
                                label: '分类筛选',
                                child: _buildCategoryButton(isDark),
                              ),
                              // 已下载的图书（跳书架）
                              JellyRingMenuRow(
                                isDark: isDark,
                                label: '已下载的图书',
                                child: _buildCircleIcon(
                                  isDark: isDark,
                                  icon: Icons.file_download_outlined,
                                  tooltip: '已下载的图书',
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    MainTabController.instance.select(
                                      MainTabController.bookshelfTabIndex,
                                    );
                                  },
                                ),
                              ),
                              const Divider(
                                  height: 12, indent: 20, endIndent: 20),
                              // 常用操作
                              JellyRingMenuActions(
                                isDark: isDark,
                                actions: [
                                  (
                                    icon: Icons.history_rounded,
                                    label: '浏览记录',
                                    onTap: () {
                                      Navigator.pop(ctx);
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              const BrowseHistoryPage(
                                                  showTabs: false),
                                        ),
                                      );
                                    },
                                  ),
                                  (
                                    icon: Icons.favorite_rounded,
                                    label: '收藏',
                                    onTap: () {
                                      Navigator.pop(ctx);
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => const FavoritesPage(),
                                        ),
                                      );
                                    },
                                  ),
                                  (
                                    icon: Icons.file_download_rounded,
                                    label: '下载',
                                    onTap: () {
                                      Navigator.pop(ctx);
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => const DownloadPage(),
                                        ),
                                      );
                                    },
                                  ),
                                  (
                                    icon: Icons.leaderboard_rounded,
                                    label: '豆瓣排行',
                                    onTap: () {
                                      Navigator.pop(ctx);
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => const DoubanRankingPage(),
                                        ),
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        _buildAvatar(isDark),
                      ],
                    ),
                  // 第二行（搜索框 + 视图切换 + 分类按钮）已删除 ——
                  // 它们都并进了上面那一个标题行（按用户截图的一行布局）。
                  const SizedBox(height: 6),
                  // 格式小标签（常见类型）
                  _buildFormatChips(isDark),
                ],
              ),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  /// 右上角头像（登录态显示用户图标，未登录显示登录图标）
  /// 搜索框（标题行内用 Expanded 撑开）
  ///
  /// ── 圆形图标 → 点击展开的小胶囊 ──────────────────────────────
  /// 原来是**常驻长条** `JellySearchBar`，占掉一整行宽度。
  /// 用户给的参考图是：收起只留一个圆形搜索图标，点一下才伸长成输入框。
  /// 统一用阅读自己的 [JellyExpandableSearch]（Jelly 配色，图标在左，
  /// 提示「搜索图书」），与漫画/书架/收藏页同款交互。
  Widget _buildSearchBar(bool isDark) {
    return JellyExpandableSearch(
      controller: _searchController,
      hintText: '搜索图书',
      onFocusChange: (f) => setState(() {
        if (f && _searchController.text.isEmpty) {
          _historyVisible = true;
        }
      }),
      onSubmitted: (value) => _runSearch(value),
      onChanged: (value) => setState(() {}),
    );
  }

  /// 网格 / 列表 视图切换。
  ///
  /// ⚠️ 这里原来接的是 `_tabController` —— **那是分类标签的控制器**
  /// （推荐/全部/EPUB…，length 2）。点视图切换只会让分类标签换一个，
  /// 网格/列表**根本没变**（真 bug）。
  ///
  /// 视图模式有独立的状态与持久化：`BookViewMode().isGrid`
  /// （services/book_view_mode.dart）。这里改接它，并且用
  /// ListenableBuilder 监听 —— 否则别处改了模式本按钮不会跟着动。
  Widget _buildViewToggle(bool isDark) {
    return ListenableBuilder(
      listenable: BookViewMode(),
      builder: (context, _) => JellySegmentedToggle(
        index: BookViewMode().isGrid ? 0 : 1,
        onChanged: (i) => BookViewMode().set(i == 0),
        segments: const [
          JellySegmentData(icon: Icons.grid_view_rounded),
          JellySegmentData(icon: Icons.view_list_rounded),
        ],
      ),
    );
  }

  /// 通用圆形图标按钮（浅灰底 + 近黑图标）—— 与书架/收藏页同款
  /// 顶栏圆形图标按钮。
  ///
  /// ⚠️ 实现已抽到 [AppIconButton]（B 档：图标按钮统一）——
  /// 原来这个方法在 **4 个页面里各写了一份**，实现逐字雷同。
  /// 这里留薄委托，调用点不动。
  Widget _buildCircleIcon({
    required bool isDark,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    double size = 36,
  }) {
    return AppIconButton(
      icon: icon,
      tooltip: tooltip,
      onTap: onTap,
      isDark: isDark,
      size: size,
    );
  }

  Widget _buildAvatar(bool isDark) {
    final z = ZlibraryService();
    final logged = z.isLoggedIn;
    // 登录态：限额优先用服务端实际值（/eapi/user/profile），未取到回退硬编码
    final limit = z.isLoggedIn
        ? (z.serverDownloadsLimit ?? ZlibraryService.loggedDailyLimit)
        : ZlibraryService.builtinDailyLimit;
    final used = z.isLoggedIn ? z.loggedCountToday : z.builtinCountToday;
    return Column(
      children: [
        Material(
          color: logged
              ? JellyTheme.primary
              : (isDark ? JellyTheme.cardDark : JellyTheme.cardLight),
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _onAvatarTap,
            child: SizedBox(
              width: 36,
              height: 36,
              child: Center(
                child: logged
                    ? Image.asset(
                        'assets/icons/user.png',
                        width: 30,
                        height: 30,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Icon(
                          Icons.person_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      )
                    : Icon(
                        Icons.person_rounded,
                        color: isDark ? Colors.white70 : JellyTheme.primary,
                        size: 20,
                      ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          logged ? '$used/$limit' : '未登录',
          style: TextStyle(
            fontSize: AppTheme.fontCaption,
            color: isDark ? Colors.white54 : JellyTheme.textSecondary,
          ),
        ),
      ],
    );
  }

  /// 格式小标签（常见类型，整体水平居中；超出可横向滚动）
  Widget _buildFormatChips(bool isDark) {
    final chips = <Widget>[];
    for (var i = 0; i < BookFormat.common.length; i++) {
      if (i > 0) chips.add(const SizedBox(width: 8));
      chips.add(_buildFormatChip(BookFormat.common[i], isDark));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          // 上下留白，避免标签阴影被裁切
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.max,
              children: chips,
            ),
          ),
        );
      },
    );
  }

  Widget _buildFormatChip(BookFormat f, bool isDark) {
    final isAll = f.value == null;
    final selected = isAll
        ? _filterExtensions.isEmpty
        : _filterExtensions.contains(f.value);
    return GestureDetector(
      onTap: () {
        setState(() {
          if (isAll) {
            _filterExtensions.clear();
          } else {
            final v = f.value!;
            if (_filterExtensions.contains(v)) {
              _filterExtensions.remove(v);
            } else {
              _filterExtensions.add(v);
            }
          }
        });
        // 切换格式后按当前模式自动重新搜索（类型标签与分类弹窗同源联动）
        if (_categoryMode && _selectedCategory != null) {
          _doCategorySearch();
        } else if (_keyword.trim().isNotEmpty) {
          _doSearch();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? JellyTheme.primary
              : (isDark ? JellyTheme.cardDark : JellyTheme.cardLight),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Text(
          f.label,
          style: TextStyle(
            fontSize: AppTheme.fontFootnote,
            fontWeight: FontWeight.w600,
            color: selected
                ? Colors.white
                : (isDark ? Colors.white70 : JellyTheme.textSecondary),
          ),
        ),
      ),
    );
  }

  /// 悬浮返回顶部按钮
  Widget _buildBackToTopButton() {
    return AnimatedScale(
      scale: _showBackToTop ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: IgnorePointer(
        ignoring: !_showBackToTop,
        child: AnimatedOpacity(
          opacity: _showBackToTop ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          child: Material(
            color: JellyTheme.primary,
            shape: const CircleBorder(),
            elevation: 4,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _scrollToTop,
              child: const SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  Icons.arrow_upward_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    // 分类模式下不显示搜索历史
    if (_showHistory && !_categoryMode) return _buildHistory();

    if (_isSearching) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: JellyTheme.primary),
            const SizedBox(height: 16),
            Text('正在筛选...',
                style: TextStyle(color: JellyTheme.textSecondary)),
          ],
        ),
      );
    }

    // 搜索异常
    if (_errorMsg != null && _result.items.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cloud_off_rounded, size: 64, color: JellyTheme.textSecondary),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _errorMsg!,
                textAlign: TextAlign.center,
                style: TextStyle(color: JellyTheme.textSecondary),
              ),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () =>
                  _categoryMode ? _doCategorySearch() : _doSearch(),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }

    // 无结果（关键词或分类模式均适用）
    if (_result.items.isEmpty &&
        (_keyword.isNotEmpty || _categoryMode) &&
        !_isSearching) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off_rounded,
                size: 64, color: JellyTheme.textSecondary),
            const SizedBox(height: 16),
            Text('没有找到相关图书',
                style: TextStyle(color: JellyTheme.textSecondary)),
          ],
        ),
      );
    }

    // 未搜索 = 初始界面（分类模式除外）。
    //
    // ⚠️ 文案按 cmbok V2.0.8 截图对齐：进页面时是在**拉推荐**，
    // 所以显示「正在获取推荐...」+ 转圈，而不是"请输入关键词"。
    // 拉取结束（_isSearching 结束）仍无数据时，退回可操作的提示 ——
    // 否则用户会以为一直卡在加载中。
    if (_result.items.isEmpty && _keyword.isEmpty && !_categoryMode) {
      if (_isSearching) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: JellyTheme.primary),
              const SizedBox(height: 16),
              Text(
                '正在获取推荐...',
                style: TextStyle(color: JellyTheme.textSecondary),
              ),
            ],
          ),
        );
      }
      // 热门推荐流（豆瓣 book_hot）：有数据直接铺网格，不依赖 z-library
      if (_hotBooks.isNotEmpty) return _buildHotGrid();
      if (_hotLoading) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: JellyTheme.primary),
              const SizedBox(height: 16),
              Text('正在加载热门书籍...',
                  style: TextStyle(color: JellyTheme.textSecondary)),
            ],
          ),
        );
      }
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.book_rounded, size: 64, color: JellyTheme.textSecondary),
            const SizedBox(height: 16),
            Text(_hotFailed ? '热门书籍加载失败' : '暂无推荐内容',
                style: TextStyle(color: JellyTheme.textSecondary)),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: _loadHotBooks,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重新获取'),
            ),
          ],
        ),
      );
    }

    // 结果：网格/列表用 TabBarView 横向滑动切换（参考下载页，滑块与内容 1:1 同步）
    return TabBarView(
      controller: _tabController,
      children: [_buildGridView(), _buildListView()],
    );
  }

  /// 搜索历史面板
  Widget _buildHistory() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final labelColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return GestureDetector(
      onTap: () => setState(() => _historyVisible = false),
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Text(
                  '搜索历史',
                  style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w600,
                    color: labelColor,
                  ),
                ),
                const Spacer(),
                if (_history.isNotEmpty)
                  TextButton(
                    onPressed: _clearHistory,
                    child: const Text('清空', style: TextStyle(fontSize: AppTheme.fontSubhead)),
                  ),
              ],
            ),
          ),
          if (_history.isEmpty)
            Padding(
              padding: const EdgeInsets.all(40),
              child: Center(
                child: Text('暂无搜索历史',
                    style: TextStyle(color: JellyTheme.textSecondary)),
              ),
            )
          else
            ..._history.map(
              (kw) => ListTile(
                leading:
                    Icon(Icons.history_rounded, color: JellyTheme.textSecondary),
                title: Text(kw),
                trailing: IconButton(
                  icon: Icon(
                    Icons.close_rounded,
                    color: JellyTheme.textSecondary,
                    size: 18,
                  ),
                  onPressed: () => _removeHistory(kw),
                ),
                onTap: () => _runSearch(kw),
              ),
            ),
        ],
      ),
    );
  }

  Key _entranceKey(int index, {required bool isGrid}) =>
      ValueKey('${isGrid}_${_searchSession}_$index');

  int _adaptiveColumns(
    double width, {
    required int min,
    int max = 6,
    double target = 170,
  }) {
    final available = width - 40;
    var cols = (available / target).floor();
    if (cols < min) cols = min;
    if (cols > max) cols = max;
    return cols;
  }

  Widget _buildGridView() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = _adaptiveColumns(
          constraints.maxWidth,
          min: 2,
          target: 170,
        );
        return MasonryGridView.count(
          controller: _gridScrollController,
          padding: EdgeInsets.only(
            top: 4,
            left: 12,
            right: 12,
            bottom: 12 + JellyNavBar.contentBottomAvoid,
          ),
          crossAxisCount: cols,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          itemCount: _result.items.length + (_result.hasMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == _result.items.length) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: CircularProgressIndicator(color: JellyTheme.primary),
                ),
              );
            }
            final book = _result.items[index];
            return StaggeredEntrance(
              key: _entranceKey(index, isGrid: true),
              index: index,
              child: JellyBookCard(
                book: book,
                isGrid: true,
                heroTag: bookCoverHeroTag('search', book),
                onTap: () => _openDetail(book),
              ),
            );
          },
        );
      },
    );
  }

  /// 热门推荐网格（豆瓣热榜）：封面 + 书名，点击打开豆瓣图书页。
  Widget _buildHotGrid() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = _adaptiveColumns(
          constraints.maxWidth,
          min: 2,
          target: 170,
        );
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                child: Row(
                  children: [
                    Text(
                      '热门书籍',
                      style: TextStyle(
                        fontSize: AppTheme.fontTitle3,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? Colors.white
                            : JellyTheme.textPrimaryLight,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '豆瓣热榜 · 点击看详情',
                      style: TextStyle(
                          fontSize: AppTheme.fontFootnote,
                          color: JellyTheme.textSecondary),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '刷新热门',
                      onPressed: _hotLoading ? null : _loadHotBooks,
                      icon: Icon(
                        Icons.refresh_rounded,
                        size: 20,
                        color: JellyTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.only(
                left: 12,
                right: 12,
                bottom: 12 + JellyNavBar.contentBottomAvoid,
              ),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 3 / 4.55,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final book = _hotBooks[index];
                    return JellyBookCard(
                      book: book,
                      isGrid: true,
                      heroTag: bookCoverHeroTag('hot', book),
                      coverHeaders: _doubanImageHeaders,
                      onTap: () => _openDoubanBook(book),
                    );
                  },
                  childCount: _hotBooks.length,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 打开豆瓣图书详情页（系统浏览器；id 形如 douban-26943161）。
  Future<void> _openDoubanBook(Book book) async {
    final doubanId =
        book.id.startsWith('douban-') ? book.id.substring(7) : book.id;
    final uri = Uri.parse('https://book.douban.com/subject/$doubanId/');
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('无法打开豆瓣页面'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ));
    }
  }

  Widget _buildListView() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = _adaptiveColumns(
          constraints.maxWidth,
          min: 1,
          target: 360,
          max: 4,
        );
        return MasonryGridView.count(
          controller: _listScrollController,
          padding: EdgeInsets.only(
            top: 4,
            left: 12,
            right: 12,
            bottom: 12 + JellyNavBar.contentBottomAvoid,
          ),
          crossAxisCount: cols,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          itemCount: _result.items.length + (_result.hasMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == _result.items.length) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: CircularProgressIndicator(color: JellyTheme.primary),
                ),
              );
            }
            final book = _result.items[index];
            return StaggeredEntrance(
              key: _entranceKey(index, isGrid: false),
              index: index,
              child: JellyBookCard(
                book: book,
                isGrid: false,
                heroTag: bookCoverHeroTag('search', book),
                onTap: () => _openDetail(book),
              ),
            );
          },
        );
      },
    );
  }
}

/// 退出登录按钮：危险色实心 + 按压缩放反馈
class _LogoutButton extends StatefulWidget {
  final VoidCallback onTap;
  const _LogoutButton({required this.onTap});

  @override
  State<_LogoutButton> createState() => _LogoutButtonState();
}

class _LogoutButtonState extends State<_LogoutButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            color: JellyTheme.error,
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Center(
            child: Text(
              '退出登录',
              style: TextStyle(
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 分类筛选弹窗返回结果。
/// 分类筛选弹窗内容（独立 StatefulWidget，管理 TextEditingController 生命周期）。
/// 控制器在 initState 创建、dispose 销毁，避免弹窗退出动画期间过早 dispose
/// 触发 InheritedElement._dependents 非空断言。
class _BookCategorySheet extends StatefulWidget {
  final bool isDark;
  final BookCategory? initialCategory;
  final int? initialYearFrom;
  final int? initialYearTo;
  final List<String> initialLanguages;
  final List<String> initialExtensions;

  const _BookCategorySheet({
    required this.isDark,
    required this.initialCategory,
    required this.initialYearFrom,
    required this.initialYearTo,
    required this.initialLanguages,
    required this.initialExtensions,
  });

  @override
  State<_BookCategorySheet> createState() => _BookCategorySheetState();
}

class _BookCategorySheetState extends State<_BookCategorySheet> {
  late final List<String> _selLanguages;
  late final List<String> _selExtensions;
  int _selectedGroupIdx = -1;
  BookCategory? _selectedChild;
  int? _yearFrom;
  int? _yearTo;
  bool _refreshing = false;
  final GlobalKey _selectedTabKey = GlobalKey();

  /// 年份候选项：null（不限）+ 当前年份倒序到 1900。
  List<int?> get _yearOptions => [
    null,
    ...List.generate(
      DateTime.now().year - 1900 + 1,
      (i) => DateTime.now().year - i,
    ),
  ];

  @override
  void initState() {
    super.initState();
    _selLanguages = List<String>.from(widget.initialLanguages);
    _selExtensions = List<String>.from(widget.initialExtensions);
    _selectedChild = widget.initialCategory;
    _yearFrom = widget.initialYearFrom;
    _yearTo = widget.initialYearTo;
    if (widget.initialCategory != null) {
      for (var i = 0; i < BookCategories.groups.length; i++) {
        if (BookCategories.groups[i].children.any(
          (c) => c.id == widget.initialCategory!.id,
        )) {
          _selectedGroupIdx = i;
          break;
        }
      }
    }
    // 打开弹窗时把已选中的主分类标签滚到居中（重进可见）
    if (_selectedGroupIdx >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _selectedTabKey.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(ctx, alignment: 0.5);
        }
      });
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  void _confirm() {
    FocusScope.of(context).unfocus();
    Navigator.pop(
      context,
      _BookCategorySheetResult(
        groupIdx: _selectedGroupIdx,
        category: _selectedChild!,
        yearFrom: _yearFrom,
        yearTo: _yearTo,
        languages: List.of(_selLanguages),
        extensions: List.of(_selExtensions),
      ),
    );
  }

  void _reset() {
    setState(() {
      _selectedGroupIdx = -1;
      _selectedChild = null;
      _selLanguages.clear();
      _selExtensions.clear();
      _yearFrom = null;
      _yearTo = null;
    });
  }

  /// 强制重新抓取分类目录（站点分类结构变化时手动刷新）。
  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await ZlibraryService().fetchCategories(force: true);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('分类刷新失败，请稍后重试'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
      }
    } finally {
      if (mounted) {
        setState(() {
          _refreshing = false;
          // 刷新后组数可能变化，选中越界则重置
          if (_selectedGroupIdx >= BookCategories.groups.length) {
            _selectedGroupIdx = -1;
            _selectedChild = null;
          }
        });
      }
    }
  }

  Widget _yearDropdown({
    required int? value,
    required String hint,
    required Color labelColor,
    required Color chipColor,
    required ValueChanged<int?> onChanged,
  }) {
    return Container(
      width: 104,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: chipColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int?>(
          value: value,
          isExpanded: true,
          isDense: true,
          hint: Text(hint, style: const TextStyle(fontSize: AppTheme.fontFootnote)),
          style: TextStyle(fontSize: AppTheme.fontFootnote, color: labelColor),
          items: _yearOptions
              .map(
                (y) => DropdownMenuItem<int?>(
                  value: y,
                  child: Text(y?.toString() ?? '不限'),
                ),
              )
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final labelColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final chipColor = isDark
        ? JellyTheme.cardDark
        : JellyTheme.primary.withValues(alpha: 0.08);
    final chipTextColor = isDark ? Colors.white70 : JellyTheme.textSecondary;
    // 通用 chip（子分类/语言/格式复用）
    Widget chip(String label, bool selected, VoidCallback onTap) =>
        GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: selected ? JellyTheme.primary : chipColor,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: AppTheme.fontFootnote,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                color: selected ? Colors.white : chipTextColor,
              ),
            ),
          ),
        );
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.72,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 标题栏
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 4),
              child: Row(
                children: [
                  Text(
                    '分类筛选',
                    style: TextStyle(
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.bold,
                      color: labelColor,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: _refreshing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded),
                    onPressed: _refreshing ? null : _refresh,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () {
                      FocusScope.of(context).unfocus();
                      Navigator.pop(context);
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            const SizedBox(height: 10),
            // 主分类标签栏（横向滚动，单选）
            SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                cacheExtent: double.maxFinite,
                itemCount: BookCategories.groups.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, gi) {
                  final g = BookCategories.groups[gi];
                  final selected = gi == _selectedGroupIdx;
                  return GestureDetector(
                    key: selected ? _selectedTabKey : null,
                    onTap: () => setState(() {
                      if (_selectedGroupIdx == gi) {
                        _selectedGroupIdx = -1;
                        _selectedChild = null;
                      } else {
                        _selectedGroupIdx = gi;
                        _selectedChild = null;
                      }
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: selected ? JellyTheme.primary : chipColor,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Center(
                        child: Text(
                          g.title,
                          style: TextStyle(
                            fontSize: AppTheme.fontSubhead,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: selected ? Colors.white : chipTextColor,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            const Divider(height: 1),
            // 子分类 + 年份/语言/格式过滤条件（整体可滚动，过滤条件始终常驻）
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '子分类',
                      style: TextStyle(
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w600,
                        color: labelColor,
                      ),
                    ),
                    const SizedBox(height: 6),
                    _selectedGroupIdx < 0
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              '请选择主分类',
                              style: TextStyle(
                                fontSize: AppTheme.fontFootnote,
                                color: chipTextColor,
                              ),
                            ),
                          )
                        : Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: BookCategories
                                .groups[_selectedGroupIdx]
                                .children
                                .map(
                                  (c) => chip(
                                    c.zhName,
                                    _selectedChild != null &&
                                        _selectedChild!.id == c.id,
                                    () => setState(() => _selectedChild = c),
                                  ),
                                )
                                .toList(),
                          ),
                    const SizedBox(height: 16),
                    Text(
                      '年份',
                      style: TextStyle(
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w600,
                        color: labelColor,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _yearDropdown(
                          value: _yearFrom,
                          hint: '起始',
                          labelColor: labelColor,
                          chipColor: chipColor,
                          onChanged: (v) => setState(() => _yearFrom = v),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: Text('–'),
                        ),
                        _yearDropdown(
                          value: _yearTo,
                          hint: '结束',
                          labelColor: labelColor,
                          chipColor: chipColor,
                          onChanged: (v) => setState(() => _yearTo = v),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '语言',
                      style: TextStyle(
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w600,
                        color: labelColor,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: BookCategoryFilters.languages.map((lang) {
                        final selected = _selLanguages.contains(lang.value);
                        return chip(
                          lang.label,
                          selected,
                          () => setState(() {
                            if (selected) {
                              _selLanguages.remove(lang.value);
                            } else {
                              _selLanguages.add(lang.value);
                            }
                          }),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '格式',
                      style: TextStyle(
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w600,
                        color: labelColor,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: BookCategoryFilters.extensions.map((ext) {
                        final selected = _selExtensions.contains(ext);
                        return chip(
                          ext,
                          selected,
                          () => setState(() {
                            if (selected) {
                              _selExtensions.remove(ext);
                            } else {
                              _selExtensions.add(ext);
                            }
                          }),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            // ── 底部按钮：重置 / 确认（按截图：两个等宽并排的圆角按钮）──
            //
            // 原来是「TextButton(重置) + Spacer + FilledButton(确定)」——
            // 左文字按钮、右实心按钮、大小不一。
            // 截图里是两个**等宽**的圆角按钮并排：
            //   左=重置（描边/浅底），右=确认（实心；未选子分类时禁用并
            //   把文案换成「请选择子分类」）
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                children: [
                  // 重置
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _reset,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: BorderSide(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.22)
                              : Colors.black.withValues(alpha: 0.16),
                        ),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        foregroundColor: labelColor,
                      ),
                      child: const Text('重置'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 确认
                  Expanded(
                    child: FilledButton(
                      onPressed: _selectedChild != null ? _confirm : null,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(
                        // 没选子分类时说清"缺什么"，而不是让按钮灰着不解释
                        _selectedChild != null ? '确定' : '请选择子分类',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BookCategorySheetResult {
  final int groupIdx;
  final BookCategory category;
  final int? yearFrom;
  final int? yearTo;
  final List<String> languages;
  final List<String> extensions;
  const _BookCategorySheetResult({
    required this.groupIdx,
    required this.category,
    this.yearFrom,
    this.yearTo,
    this.languages = const [],
    this.extensions = const [],
  });
}
