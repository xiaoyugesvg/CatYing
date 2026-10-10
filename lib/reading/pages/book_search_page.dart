import 'package:flutter/foundation.dart';
// 删掉从未使用的 `package:dio/dio.dart` ✓（analyze 一直报 unused_import ✗，
// 本文件只用 `ZlibraryService` 发出的请求 ✓，没有直接用 Dio ✓）
import '../../widgets/common_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../models/book.dart';
import '../models/book_category.dart';
import '../models/search_result.dart';
import '../services/book_download_service.dart';
import '../services/book_view_mode.dart';
import '../services/browse_history_service.dart';
import '../services/reading_layout.dart';
import '../services/search_history_service.dart';
import '../services/zlibrary_service.dart';
import '../theme/jelly_theme.dart';
import '../services/settings_service.dart';
import '../widgets/jelly_book_card.dart';
import '../widgets/jelly_nav_bar.dart';
import '../widgets/jelly_icon_deck.dart';
import '../widgets/jelly_expandable_search.dart';
import '../widgets/jelly_pull_cord.dart';
import '../widgets/guide_overlay.dart';
import '../widgets/staggered_entrance.dart';
import 'book_detail_page.dart';
import 'book_source_search_page.dart';
import 'shell_embedded_page.dart';
import 'douban_ranking_page.dart';
import 'browse_history_page.dart';
import 'book_download_records_page.dart';
import 'favorites_page.dart';
import '../../common/theme.dart';
import '../../widgets/app_page_header.dart';

/// 日志工具
void _log(String message) {
  if (kDebugMode) {
    print('[BookSearchPage] $message');
  }
}

/// 图书搜索页面（果冻风，布局同漫画搜索 + 格式筛选 + 右上角 z-library 登录头像）
class BookSearchPage extends StatefulWidget {
  /// 是否为当前激活的 tab（用于触发结果瀑布入场动画）
  final bool isActive;

  /// 是否显示返回按钮（从"我的"页面入口进入时为 true）
  final bool showBackButton;

  /// 进入后预填并自动搜索的关键词（豆瓣排行「去找书」跳转用）
  final String? initialKeyword;

  const BookSearchPage({
    super.key,
    this.isActive = false,
    this.showBackButton = false,
    this.initialKeyword,
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

  // 首页推荐流（z-library「最受欢迎」）：打开图书页自动加载，
  // 不再让用户面对空态先选分类/搜索（用户 2026-10-06 要求恢复内容）。
  bool _homeLoading = false;
  String? _homeError;

  // 分类额外过滤条件：年份/语言仅分类模式用；格式 _filterExtensions 与搜索页小标签
  // 同源联动，关键词/分类模式都用，跨模式保留。
  bool _categoryMode = false; // 分类浏览模式（与关键词搜索互斥）
  BookCategory? _selectedCategory; // 当前选中的子分类
  bool _categorySheetOpening = false; // 分类弹窗防连点守卫
  int? _filterYearFrom;
  int? _filterYearTo;
  List<String> _filterLanguages = [];
  List<String> _filterExtensions = [];

  /// 格式筛选是否已由用户显式激活（点过任意格式标签 = true；点「推荐」回到
  /// 推荐流 = false）。用于让「推荐」圆钮与「全部」标签**互斥高亮**：
  /// 初始/推荐态 → 推荐钮亮、「全部」不亮；点了格式 → 推荐钮灭、所选格式亮。
  bool _formatActive = false;

  bool _showBackToTop = false;
  bool _historyVisible = false;
  List<String> _history = [];
  int _searchSession = 0;
  String? _errorMsg; // 搜索异常信息
  /// z-library 可用性上一状态（仅状态变化才弹通知；null=尚未初始化）
  bool? _wasUnavailable;

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
    // 宫格列数变化（3/4/5）→ 重建网格（跨页面共享偏好）
    ReadingLayout().addListener(_onLayoutChanged);
    ZlibraryService().addListener(_onServiceChanged);
    BookDownloadService().addListener(_onServiceChanged);
    _wasUnavailable = ZlibraryService().isUnavailable;
    _loadHistory();
    _ensureCategories();
    _loadHome();
    _maybeTriggerGuide();
    // 豆瓣排行「去找书」跳转：预填关键词并立即执行搜索
    // （首帧后触发，避免 initState 阶段 FocusScope 查询）
    final kw = widget.initialKeyword?.trim() ?? '';
    if (kw.isNotEmpty) {
      _searchController.text = kw;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _runSearch(kw);
      });
    }
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
    ReadingLayout().removeListener(_onLayoutChanged);
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

  /// 首页推荐流：打开图书页自动加载 z-library「最受欢迎」，
  /// 让用户一进来就有内容（不再空态逼用户先选分类/搜索）。
  Future<void> _loadHome() async {
    if (_homeLoading) return;
    setState(() {
      _homeLoading = true;
      _homeError = null;
    });
    try {
      // ✅ 用户 2026-10-10「默认推荐是中文」：推荐流默认带中文语言过滤，
      //    打开图书页看到的就是中文书（三级策略见 fetchHomeRecommendations）。
      final r = await ZlibraryService()
          .fetchHomeRecommendations(languages: const ['chinese']);
      if (!mounted) return;
      setState(() {
        _result = r;
        _homeLoading = false;
      });
      _log('首页推荐加载完成: ${r.items.length} 条');
    } on ZlibraryException catch (e) {
      if (!mounted) return;
      setState(() {
        _homeLoading = false;
        _homeError = _friendlyError(e);
      });
      _log('首页推荐加载失败: $_homeError');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _homeLoading = false;
        _homeError = '推荐加载失败';
      });
      _log('首页推荐异常: $e');
    }
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
    // 🔴 原来这里是 `if (ZlibraryService().isUnavailable) return SizedBox.shrink();`
    // ✗ —— 也就是"节点不可用"时**整个分类入口被删掉** ✓。
    // 而那个标记非常容易被误置（"拿到了 HTML 但解析出 0 条"也算不可用 ✗，
    // 见 zlibrary_service 的首页推荐路径），一旦置上：
    //   · 分类按钮**永久消失** ✗
    //   · 且**不会自愈**（只有某次搜索/推荐成功才会复位 ✗）
    //   → 用户既没有入口、也不知道为什么、更没法重试 ✗
    // 现在**始终保留按钮** ✓：点它照样会去取分类表（失败时由弹层自己提示 ✓），
    // 用户至少还有入口、不必重启或等自愈 ✓。
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

  /// 打开分类筛选弹窗（主分类 -> 子分类 + 年份/语言/格式过滤，底部重置/确定）。
  ///
  /// ✅ 用户 2026-10-10「点击筛选按钮没反应」——
  /// 原来点按钮后**先拉分类表再弹窗**：分类表走 WebView 抓取（串行队列、
  /// 单次 30s 超时 × 3 次重试，最坏一分多钟），期间 UI 只有 2 秒就消失的
  /// SnackBar → 观感就是"点了没反应" ✗。失败时同样只闪一条提示 ✗。
  /// 现在**点击立即弹窗**：加载中转圈 / 失败显示原因并可重试，全部在
  /// 弹窗内可见（见 [_CategorySheetGate]）✓。
  Future<void> _openCategorySheet(bool isDark) async {
    if (_categorySheetOpening) return;
    _categorySheetOpening = true;
    FocusScope.of(context).unfocus();
    try {
      final result = await showModalBottomSheet<_BookCategorySheetResult?>(
        context: context,
        isScrollControlled: true,
        backgroundColor:
            isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) => kbSheet(_CategorySheetGate(
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
    // ⚠️ 必须同时判 `indexIsChanging`：动画进行中 index 仍是旧值，
    // 若此时用户又点了另一侧，index==target 会误判"已就位"不触发 animateTo，
    // 动画继续飞向旧目标 → 视图"切不回来"。动画中一律强制重定向。
    if (_tabController.index != target || _tabController.indexIsChanging) {
      _tabController.animateTo(target);
      // ⚠️ 兜底（用户 2026-10-07：「图书没有切换」）：
      //   本页若正处在**没被显示**的 tab（IndexedStack 里）或被重建，
      //   `animateTo` 的动画有时不会推进（TabBarView 未挂载/被回收）
      //   ⇒ 表现为"显示设置里改了图书视图，图书页却没变"✗
      //   这里下一帧对一次：动画没在跑且还没到位就直接跳过去 ✓
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_tabController.indexIsChanging &&
            _tabController.index != target) {
          _tabController.index = target;
        }
      });
    }
  }

  /// 宫格列数变化（3/4/5）→ 重建网格（_buildGridView 读 ReadingLayout）
  void _onLayoutChanged() {
    if (mounted) setState(() {});
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: widget.showBackButton ? null : Colors.transparent,
      appBar: widget.showBackButton
          ? AppBar(
              title: const Text('图书'),
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
                        // ✅ 2026-10-10 用户："拉绳离字间距大一些"：4 -> 10
                        const SizedBox(width: 10),
                        // 「拉绳」：标题右边那根挂着的小绳。
                        // 点它**直接进入书源界面（书源搜索页）**——
                        // 原来是弹出「切换书源」两层弹层，按用户要求改成直进书源页；
                        // 书源仓库（导入/管理）在书源页的聚合菜单里。
                        JellyPullCord(
                          // ⚠️ 必须限高，否则绳子会把整行撑高、同排的搜索框/圆图标垂直错位。
                          // ⚠️ 2026-10-09：拉绳整体减半（绳自然高 20）⇒ 这里同步 40→20。
                          height: 20,
                          tooltip: '书源',
                          // 拉窗帘进入书源页：页面从顶部往下覆盖出现（窗帘放下），
                          // 返回时反向往上收起（窗帘拉回）
                          // ✅ **改成"外壳内嵌"**（本轮重构 ✓）—— 用户要的"**悬浮菜单栏**"
                          //   就是**底部那条 5 项胶囊导航栏** ✓（`home_page.dart` 的 `JellyNavBar` ✓）。
                          //   原来这里是 `Navigator.push` + `PageRouteBuilder`（380ms 下滑转场 ✓）
                          //   ⇒ **全屏推出** ✗ ⇒ 底栏被盖掉 ✗✓（用户截图："书源页没有底栏"✓）
                          //   ⇒ 现在把页面交给外壳渲染 ✓ ⇒ **底栏照常显示** ✓✓
                          //   ℹ️ 转场交给外壳的统一过渡（不再自定义 380ms 下滑 ✓ 与其它子页一致 ✓）
                          onTap: () =>
                              openEmbeddedPage(const BookSourceSearchPage()),
                        ),
                        const SizedBox(width: 10),
                        // ── 🔴 搜索框靠右（修用户反馈）────────────────
                        // 原来包在 `Expanded` 里 ✗ —— `Expanded` 是 tight 宽度，
                        // 搜索框在满宽里靠左 ⇒ 与右侧筛选按钮之间**空一大截** ✗
                        // 用户原话：「搜索框要靠右，右边的图标也要靠右，不要贴那么近」
                        //
                        // 改成 `Spacer` 之后：组件只占内容宽（`maxWidth`），
                        // 由 `Spacer` 吃掉左侧空白 ⇒ 胶囊自然贴到右侧 ✓，
                        // 再用 `SizedBox(width: 12)` 留出**不贴太近**的间距 ✓
                        //
                        // 实测对比：`Expanded` 包裹时胶囊停在可用区左缘、
                        // 与右侧图标空 46.8px ✗；`Spacer` 时间距正好 12px ✓
                        const Spacer(),
                        _buildSearchBar(isDark),
                        const SizedBox(width: 10),
                        // ⚠️ 用户 2026-10-07（第二轮修正）：
                        //   · **筛选按钮单独拉出来** ✓ —— 与漫画页/书源页一致，
                        //     直接是那个 tune 按钮（原来藏在「视图与分类」指环菜单里 ✗）
                        //   · 视图（列表/宫格）已统一收到「我的 → 显示设置」✓
                        //   · 其余 4 个动作叠在一起、左右滑动轮换 ✓
                        _buildCategoryButton(isDark),
                        const SizedBox(width: 10),
                        // ⚠️ 用户要求（本轮）：右上角由「并排滑动动作栏」改成**叠图标控件** ——
//   · 最前的**完整可见**（深色圆底）
//   · 后面各露出一部分，**左右滑动**循环切换最前
//   · **长按**竖向展开全部
//   原来的 `JellySlidingActions` 已整体替换（筛选按钮仍单独保留在它左边）。
JellyIconDeck(
  items: [
      JellyIconDeckItem(
        icon: Icons.history_rounded,
        tooltip: '浏览记录',
        onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const BrowseHistoryPage()),
      ),
      ),
      JellyIconDeckItem(
        icon: Icons.favorite_rounded,
        tooltip: '收藏',
        onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => const FavoritesPage(showBackButton: true),
        ),
      ),
      ),
      JellyIconDeckItem(
        icon: Icons.file_download_rounded,
        tooltip: '下载',
        onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const BookDownloadRecordsPage()),
      ),
      ),
      JellyIconDeckItem(
        icon: Icons.leaderboard_rounded,
        tooltip: '豆瓣排行',
        onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const DoubanRankingPage()),
      ),
      ),
  ],
),
                      ],
                    ),
                  // 第二行（搜索框 + 视图切换 + 分类按钮）已删除 ——
                  // 它们都并进了上面那一个标题行（按用户截图的一行布局）。
                  const SizedBox(height: 6),
                  // ── 推荐（固定左侧）+ 格式小标签 ─────────────────────
                  // 用户 2026-10-07：图书页要一个「推荐」按钮，
                  // **固定在漫画页「聚搜」按钮那个位置**（标签行最左、不随滚动）；
                  // 点它显示的内容 = 图书自身的推荐内容（z-library「最受欢迎」）✓
                  Row(
                    children: [
                      _recommendChip(isDark),
                      const SizedBox(width: 8),
                      Expanded(child: _buildFormatChips(isDark)),
                    ],
                  ),
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
      // 用户 2026-10-07：宽度改成原来的三分之二（200 → 133）
      maxWidth: 133,
      onFocusChange: (f) => setState(() {
        if (f && _searchController.text.isEmpty) {
          _historyVisible = true;
        }
      }),
      onSubmitted: (value) => _runSearch(value),
      onChanged: (value) => setState(() {}),
    );
  }

  /// 视图切换 —— **已按要求从顶栏移除**。
  ///
  /// 用户 2026-10-07：「将视图按钮只在我的里面的显示设置里面就行」
  ///   ⇒ 图书页顶栏只留**筛选**按钮 ✓
  ///   ⇒ 视图（列表 / 宫格·3/4/5 列）统一在
  ///      「我的 → 显示设置 → 图书搜索页视图」里选 ✓
  ///      （那边调用的是同一个 `ReadingViewToggle.showSheet`，
  ///        仍然写 `BookViewMode` + `ReadingLayout`，本页照旧实时联动 ✓）

  /// 「推荐」按钮 —— 固定在格式标签行**最左侧**（与漫画页「聚搜」按钮同款
  /// 位置与样式：32 圆钮、卡片底、主色图标，选中态用主色实心）。
  ///
  /// 用户 2026-10-07：「图书里面的那个要增加一个推荐按钮，要和漫画里面的
  /// 聚搜按钮一样固定在那里；推荐里面的就是图书的那个推荐内容」——
  /// 所以点它就是**回到推荐流**（z-library「最受欢迎」，与打开图书页默认加载的
  /// 是同一份数据 `_loadHome()`）。
  ///
  /// 高亮 = 推荐态：未激活格式筛选 且 无关键词/分类 且 推荐流已有内容。
  /// （与「全部」标签互斥 —— 修复"推荐钮 + 全部同时高亮"）
  Widget _recommendChip(bool isDark) {
    final active = !_formatActive &&
        !_categoryMode &&
        _keyword.isEmpty &&
        _result.items.isNotEmpty;
    return GestureDetector(
      onTap: _showRecommendations,
      child: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active
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
        child: Icon(
          Icons.local_fire_department_rounded,
          size: 17,
          color: active ? Colors.white : JellyTheme.primary,
        ),
      ),
    );
  }

  /// 回到「推荐」：清掉关键词 / 分类态，重新加载推荐流（z-library 最受欢迎）。
  Future<void> _showRecommendations() async {
    FocusScope.of(context).unfocus();
    _searchController.clear();
    setState(() {
      _result = SearchResult.empty();
      _keyword = '';
      _categoryMode = false;
      _selectedCategory = null;
      _errorMsg = null;
      _historyVisible = false;
      _formatActive = false; // 回到推荐态：「全部」标签取消高亮（与推荐钮互斥）
    });
    await _loadHome();
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
    // 「全部」只在高亮**激活了格式筛选且未选具体格式**时才亮；
    // 初始/推荐态（未激活）不亮 —— 避免与「推荐」圆钮同时高亮。
    final selected = isAll
        ? _formatActive && _filterExtensions.isEmpty
        : _formatActive && _filterExtensions.contains(f.value);
    return GestureDetector(
      onTap: () {
        setState(() {
          // 点任意格式标签 = 显式进入格式筛选态（「推荐」圆钮随之灭）
          _formatActive = true;
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
        } else if (_result.items.isNotEmpty) {
          // 初始/推荐模式：当前列表已有内容 → 本地按格式过滤，立即生效
          // （用户 2026-10-06 反馈"格式切换没有内容"：原来只弹提示不过滤）
          _applyLocalFormatFilter();
        } else {
          // 初始界面（无关键词、无分类、无内容）：格式筛选此时没有内容可作用，
          // 给一句明确反馈，避免"点了没反应"的错觉。
          _showTip('输入关键词或选择分类后，格式筛选生效');
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

  /// 本地按格式过滤当前列表（初始/推荐模式已有内容时，点格式标签立即生效，
  /// 无需重新请求；用户 2026-10-06 反馈"格式切换没有内容"）
  void _applyLocalFormatFilter() {
    final filtered = _result.items.where((b) {
      if (_filterExtensions.isEmpty) return true;
      final ext = b.extension?.trim().toUpperCase() ?? '';
      return _filterExtensions.contains(ext);
    }).toList();
    setState(() {
      _result = SearchResult<Book>(
        items: filtered,
        total: filtered.length,
        currentPage: 1,
        totalPages: filtered.isEmpty ? 0 : 1,
      );
    });
    if (filtered.isEmpty) {
      _showTip('当前列表没有「${_filterExtensions.join(' / ')}」格式的图书');
    }
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
          // ⛔ **有意不同、不要"统一"成 `AppIconButton`** ✗✓（与 `bookshelf_page` 那处同款 ✓）
          //   它是**返回顶部悬浮钮** ✓（`onTap: _scrollToTop` ✓），不是顶栏同族圆钮 ✓：
          //     · 44×44（悬浮 ✓）vs 顶栏 36×36 ✓
          //     · `primary` + `elevation: 4` = **醒目 FAB** ✓ —— 换"淡圆底"会几乎看不见 ✗
          //     · 随滚动 `AnimatedOpacity/IgnorePointer` 出现消失 ✓（顶栏钮不会 ✓）
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
            Icon(Icons.cloud_off_rounded, size: 48, color: JellyTheme.textSecondary),
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
                size: 48, color: JellyTheme.textSecondary),
            const SizedBox(height: 16),
            Text('没有找到相关图书',
                style: TextStyle(color: JellyTheme.textSecondary)),
          ],
        ),
      );
    }

    // 未搜索 = 初始界面（分类模式除外）。
    // 默认展示 z-library「最受欢迎」推荐流（打开即加载，不再空态逼用户选分类）；
    // 仅当推荐也加载失败时才显示轻量引导 + 重试。
    if (_result.items.isEmpty && _keyword.isEmpty && !_categoryMode) {
      if (_homeLoading) {
        return Center(
          child: CircularProgressIndicator(color: JellyTheme.primary),
        );
      }
      final error = _homeError;
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.auto_stories_rounded,
                size: 48, color: JellyTheme.textSecondary),
            const SizedBox(height: 16),
            Text(
              error ?? '搜索图书或选择分类开始浏览',
              style: TextStyle(color: JellyTheme.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: error != null
                  ? _loadHome
                  : () => _openCategorySheet(
                      Theme.of(context).brightness == Brightness.dark),
              icon: Icon(error != null
                  ? Icons.refresh_rounded
                  : Icons.category_rounded),
              label: Text(error != null ? '重试加载推荐' : '选择分类'),
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
        // 用户偏好列数（ReadingLayout，默认 3）：一排 3 / 4 / 5 个
        final cols = ReadingLayout().columns;
        return MasonryGridView.count(
          controller: _gridScrollController,
          padding: EdgeInsets.only(
            top: 4,
            left: 12,
            right: 12,
            bottom: 12 + JellyNavBar.contentBottomAvoid,
          ),
          crossAxisCount: cols,
          mainAxisSpacing: 8,
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
                showFavorite: false,
              ),
            );
          },
        );
      },
    );
  }

  /// 首页推荐网格（已按用户要求移除 —— 不再显示「推荐 / Z-Library 最受欢迎」区块）
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
          mainAxisSpacing: 8,
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
                showFavorite: false,
              ),
            );
          },
        );
      },
    );
  }
}

// 🔴 这里原来有一个 **44 行的 `_LogoutButton`**（危险色实心 + 按压缩放反馈 ✓）✗
// —— 已删除 ✓，依据是两重证据 ✓：
//   · `grep _LogoutButton` 全模块**只命中它自己的声明** ✓
//     （`class` / 构造器 / `createState` / `State` ✓，没有任何地方构造或引用它 ✓）
//   · 删除后跑**全仓** analyze 仍 `error=0` ✓✓（这才是独立证明 ✓；
//     光跑本文件的单文件闸门**证明不了** ✗ —— 今天 `unawaited` 那次就是教训 ✓）
// ⚠️ 另外 ✓：本页的登录入口在**设置页**（`:852` 附近 ✓），从来不经过这个按钮 ✓

/// 分类筛选弹窗返回结果。
/// 分类筛选弹窗内容（独立 StatefulWidget，管理 TextEditingController 生命周期）。
/// 控制器在 initState 创建、dispose 销毁，避免弹窗退出动画期间过早 dispose
/// 触发 InheritedElement._dependents 非空断言。
/// 分类弹窗的「装载门」：把分类表的加载状态装进弹窗里。
///
/// ✅ 用户 2026-10-10「点击筛选按钮没反应」——
/// 原来先 `fetchCategories` 再弹窗，WebView 抓取（串行队列 + 30s 超时 ×
/// 3 重试）期间只有 2 秒的 SnackBar，用户感知不到在加载 ✗。
/// 现在点击**立即弹窗**：
///   · 加载中 → 转圈 + 「正在加载分类...」（不再一闪而过）
///   · 失败   → 错误原因 + 「重试」按钮（不用退出弹窗重开）
///   · 成功   → 原地渲染 [_BookCategorySheet] ✓
class _CategorySheetGate extends StatefulWidget {
  final bool isDark;
  final BookCategory? initialCategory;
  final int? initialYearFrom;
  final int? initialYearTo;
  final List<String> initialLanguages;
  final List<String> initialExtensions;

  const _CategorySheetGate({
    required this.isDark,
    required this.initialCategory,
    required this.initialYearFrom,
    required this.initialYearTo,
    required this.initialLanguages,
    required this.initialExtensions,
  });

  @override
  State<_CategorySheetGate> createState() => _CategorySheetGateState();
}

class _CategorySheetGateState extends State<_CategorySheetGate> {
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _ensureCategories();
  }

  Future<void> _ensureCategories() async {
    if (BookCategories.supported) return; // 缓存可用，直接展示
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ZlibraryService().fetchCategories(force: true);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String get _errorText {
    final e = _error;
    if (e is ZlibraryException) return e.message;
    return '分类加载失败，请检查网络后重试';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return SizedBox(
        height: 240,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(strokeWidth: 2.5),
            const SizedBox(height: 16),
            Text('正在加载分类...',
                style: TextStyle(
                  fontSize: 14,
                  color: JellyTheme.textSecondary,
                )),
          ],
        ),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off_rounded,
                size: 36, color: JellyTheme.textSecondary),
            const SizedBox(height: 12),
            Text(_errorText,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: JellyTheme.textSecondary,
                )),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: _ensureCategories,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    return _BookCategorySheet(
      isDark: widget.isDark,
      initialCategory: widget.initialCategory,
      initialYearFrom: widget.initialYearFrom,
      initialYearTo: widget.initialYearTo,
      initialLanguages: widget.initialLanguages,
      initialExtensions: widget.initialExtensions,
    );
  }
}

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
