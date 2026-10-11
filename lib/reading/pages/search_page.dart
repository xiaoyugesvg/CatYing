import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../models/comic.dart';
import '../models/search_result.dart';
import '../source/adapter.dart';
import '../source/config_manga_source.dart';
import '../source/manga_source.dart';
import '../source/models.dart';
import '../source/source_manager.dart';
import '../services/browse_history_service.dart';
import '../services/search_history_service.dart';
import '../services/view_mode.dart';
import '../services/reading_layout.dart';
import '../theme/jelly_theme.dart';
import '../services/settings_service.dart';
import '../widgets/jelly_comic_card.dart';
import '../widgets/jelly_nav_bar.dart';
import '../widgets/jelly_filter_sheet.dart';
// 删掉 3 个"从未被使用"的 import ✓（analyze 一直在报 unused_import ✗）：
// `jelly_ring_button.dart` · `jelly_segmented_toggle.dart` · `download_page.dart`
// → 删除后 `lib/reading` 的 warning 从 14 降到 **11** ✓
import '../widgets/jelly_comic_list_tile.dart';
import '../widgets/jelly_expandable_search.dart';
import '../widgets/jelly_search_bar.dart';
import '../widgets/guide_overlay.dart';
import '../widgets/jelly_icon_deck.dart';
import '../widgets/staggered_entrance.dart';
import 'browse_history_page.dart';
import 'comic_detail_page.dart';
// `ComicAggregateSearchPage`（漫画聚合搜索）在本文件 `_buildAggregateChip` 里用到，
// 之前缺了这一行 —— 于是 `:607 const ComicAggregateSearchPage()` 报
// "The name 'ComicAggregateSearchPage' isn't a class"。
import 'comic_aggregate_search_page.dart';
import 'comic_download_records_page.dart';
import 'favorites_page.dart';
import 'source_repo_page.dart';
import '../../common/theme.dart';
import '../../widgets/app_page_header.dart';

/// 日志工具
void _log(String message) {
  if (kDebugMode) {
    print('[SearchPage] $message');
  }
}

/// 单个漫画源的搜索状态快照（切源时保存/恢复，使每源保留各自上次结果）
class _SourceSearchState {
  SearchResult<Comic> result = SearchResult.empty();
  String keyword = '';
  List<FilterGroup> categoryGroups = [];
  bool categoriesLoaded = false;
  bool categoryMode = false;
  int searchSession = 0;
}

/// 板块流的一个板块（参考图 IMG_8579/8580：标题 + 3 列封面网格）
class _ComicHomeSection {
  _ComicHomeSection({required this.title, required this.groups});

  final String title;
  final List<FilterGroup> groups; // 该板块对应的分类组合（板块1=全默认）
  List<Comic> items = [];
  bool loading = false;
  String? error;
}

/// 漫画搜索页面（果冻风悬浮搜索框）
class SearchPage extends StatefulWidget {
  /// 是否为当前激活的 tab（用于触发结果瀑布入场动画）
  final bool isActive;

  /// 是否显示返回按钮（从"我的"页面入口进入时为 true）
  final bool showBackButton;

  const SearchPage({
    super.key,
    this.isActive = false,
    this.showBackButton = false,
  });

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> with TickerProviderStateMixin {
  final TextEditingController _searchController = TextEditingController();

  // 网格/列表视图切换控制器（参考下载页：滑块与 TabBarView 由同一 animation 驱动，1:1 同步）
  late final TabController _tabController;

  // 两种视图各自独立的滚动控制器，避免切换时冲突卡死
  final ScrollController _gridScrollController = ScrollController();
  final ScrollController _listScrollController = ScrollController();

  SearchResult<Comic> _result = SearchResult.empty();
  bool _isLoading = false;
  bool _isSearching = false;
  String _keyword = '';
  String _resultKeyword = ''; // 产生当前 _result 的词（与共享 _keyword 区分，用于缓存配对/防错配）

  bool _showBackToTop = false; // 是否显示返回顶部按钮
  bool _historyVisible = false; // 搜索历史面板是否可见
  List<String> _history = []; // 搜索历史
  int _searchSession = 0; // 每次新搜索 +1，用于触发瀑布动画

  List<FilterGroup> _categoryGroups = []; // 缓存的分类维度（首次拉取后复用）
  bool _categoriesLoaded = false; // 分类维度是否已拉取
  bool _categoryMode = false; // 分类浏览模式（与关键词搜索互斥）

  /// 板块流模式（参考图 IMG_8579/8580）：进源默认展示「最近更新」+ 分类板块流，
  /// 每板块 3 列封面网格，整页滚动懒加载
  bool _homeMode = false;
  List<_ComicHomeSection> _homeSections = [];
  int _homeLoaded = 0; // 已加载完成的板块数（懒加载指针）

  bool _pendingSearch = false; // 搜索中途切源/换词积压，待当前搜索结束后补搜
  bool _categorySheetOpening = false; // 分类筛选弹窗防连点守卫
  bool _guideShown = false; // 新手引导已展示标记

  // 各源独立的搜索状态缓存：切源时保存/恢复，使每个源保留自己的上次结果
  final Map<String, _SourceSearchState> _sourceStates = {};

  // 各源 chip 的 GlobalKey：切源后用 Scrollable.ensureVisible 把当前 chip 居中
  final Map<String, GlobalKey> _chipKeys = {};

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
      initialIndex: ViewMode().isGrid ? 0 : 1,
    );
    _tabController.addListener(_onTabChanged);
    _gridScrollController.addListener(() => _onScroll(_gridScrollController));
    _listScrollController.addListener(() => _onScroll(_listScrollController));
    ViewMode().addListener(_onViewModeChangedExternal);
    // 宫格列数变化（3/4/5）→ 重建网格；列数偏好是跨页面共享的（ReadingLayout）
    ReadingLayout().addListener(_onLayoutChanged);
    // 监听源变化：无源空状态下，云端更新 reload 后自动切回正常搜索界面。
    SourceManager().addListener(_onSourcesChanged);
    _loadHistory();
    // 启动恢复的选中源若靠右，首帧后滚到居中可见（复用切源逻辑）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureChipVisible(SourceManager().current);
    });
    // ✅ **进页面就自动加载"第一个源"的内容**（本轮 ✓ 用户原话：
    //   "漫画不是进去就显示，要他么的点击"✗）
    //   根因 ✗：`initState` 里**没有任何"加载内容"的调用** ✓ ——
    //     只有 `_loadHistory()`（那是**搜索历史** ✗ 不是内容 ✓）和 `_ensureChipVisible()`（只滚 chip 位置 ✗）
    //     ⇒ 所以进去只有空态「输入关键词开始搜索漫画」✗，**必须手动点一下源 chip** ✓ 才会加载 ✓
    //   修法 ✓：**复用** `_switchSource` 里那段现成逻辑（`:252-257` ✓）——
    //     它的注释本来就写着「选中单源即展示内容，而不是"输入关键词开始搜索"空态」✓✓
    //   ⚠️ 但**不能**直接调 `_switchSource(current)` ✗：`:235` 有 `if (src.id == current.id) return;`
    //      ⇒ **同源会提前 return** ✗✓（这正是最容易写错的地方 ✓）⇒ 直接调那个加载函数 ✓
    //   ℹ️ 条件与 `:252` 保持一致 ✓（无关键词 + 该源支持分类 ✓）⇒ 有历史关键词/不支持分类时**行为不变** ✓
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final src = SourceManager().current;
      if (_keyword.isEmpty && src.supportsCategories) {
        _autoLoadCategoryContent();
      }
    });
    _maybeTriggerGuide();
  }

  /// 首次激活时展示漫画页新手引导（仅一次）
  void _maybeTriggerGuide() {
    if (_guideShown || !widget.isActive) return;
    _guideShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) maybeShowGuide(context, GuideGroups.manga);
    });
  }

  @override
  void didUpdateWidget(covariant SearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) _maybeTriggerGuide();
  }

  @override
  void dispose() {
    _log('页面销毁');
    ViewMode().removeListener(_onViewModeChangedExternal);
    ReadingLayout().removeListener(_onLayoutChanged);
    SourceManager().removeListener(_onSourcesChanged);
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _searchController.dispose();
    _gridScrollController.dispose();
    _listScrollController.dispose();
    super.dispose();
  }

  /// 保存当前源的搜索状态到缓存（切源前调用）
  void _saveCurrentState(String sourceId) {
    _sourceStates[sourceId] = _SourceSearchState()
      ..result = _result
      ..keyword = _resultKeyword
      ..categoryGroups = _categoryGroups
      ..categoriesLoaded = _categoriesLoaded
      ..categoryMode = _categoryMode
      ..searchSession = _searchSession;
  }

  /// 恢复指定源缓存状态（切源后调用）；不触碰共享的 _keyword / 搜索框。
  /// 返回是否需要对当前源自动搜索（共享词非空且缓存不匹配时为 true）。
  bool _loadState(String sourceId) {
    final s = _sourceStates[sourceId];
    if (s != null) {
      _categoryGroups = s.categoryGroups;
      _categoriesLoaded = s.categoriesLoaded;
      _searchSession = s.searchSession;
      if (_keyword.isNotEmpty) {
        // 关键词模式：仅当缓存结果就是当前共享词搜出的才命中，否则待自动搜
        _categoryMode = false;
        if (s.keyword == _keyword) {
          _result = s.result;
          _resultKeyword = s.keyword;
          return false;
        } else {
          _result = SearchResult.empty();
          _resultKeyword = '';
          return true;
        }
      } else {
        // 无共享词：恢复分类态（分类模式下保留结果，否则空）
        _categoryMode = s.categoryMode;
        _result = s.categoryMode ? s.result : SearchResult.empty();
        _resultKeyword = '';
        return false;
      }
    } else {
      _result = SearchResult.empty();
      _categoryGroups = [];
      _categoriesLoaded = false;
      _categoryMode = false;
      _searchSession = 0;
      _resultKeyword = '';
      return _keyword.isNotEmpty;
    }
  }

  /// 切换当前源（chip/URL/滑动复用）：保存旧源、加载新源、按需自动搜索。
  /// 搜索框（_keyword）全局共享，切源不变。URL 兜底传 autoSearch:false 仅切源不搜。
  void _switchSource(MangaSource src, {bool autoSearch = true}) {
    FocusScope.of(context).unfocus(); // 切源/滑动属"其他情况"，主动失焦收起历史与键盘
    if (src.id == SourceManager().current.id) return; // 同源不处理
    _saveCurrentState(SourceManager().current.id); // 保存当前源状态
    SourceManager().setCurrent(src);
    final needSearch = _loadState(src.id); // 恢复该源缓存，不触碰共享搜索框
    final willSearch = needSearch && autoSearch;
    _homeMode = false; // 切源一律退出板块流（目标源内容由下方逻辑重建）
    if (mounted) setState(() => _isSearching = willSearch);
    // 切源后仅将当前源 chip 居中可见（不强制回顶，保留结果列表滚动位置）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureChipVisible(src);
    });
    if (willSearch) {
      if (_isLoading) {
        _pendingSearch = true; // 当前有搜索在进行，结束后补搜
      } else {
        _doSearch();
      }
    } else if (_keyword.isEmpty && src.supportsCategories) {
      // 无关键词且源支持分类：自动加载该源分类内容（对标书源页——
      // 选中单源即展示内容，而不是"输入关键词开始搜索"空态）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _autoLoadCategoryContent();
      });
    }
  }

  /// 切源后无关键词时自动加载该源的首页板块流（参考图 IMG_8579/8580：
  /// 「最近更新」+ 各分类板块，3 列封面网格整页滚动）。
  /// 源不支持分类 / 拉取失败 / 无分类维度时静默保持现状（不影响搜索）。
  Future<void> _autoLoadCategoryContent() async {
    if (_categorySheetOpening) return;
    final src = SourceManager().current;
    if (!src.supportsCategories) return;
    _categorySheetOpening = true;
    try {
      List<FilterGroup> groups;
      if (_categoriesLoaded && _categoryGroups.isNotEmpty) {
        groups = _categoryGroups;
      } else {
        groups = await src.fetchCategories();
        _categoryGroups = groups;
        _categoriesLoaded = true;
      }
      if (!mounted || groups.isEmpty) return;
      _buildHomeSections(groups);
    } catch (e) {
      _log('自动首页板块流失败: $e');
    } finally {
      _categorySheetOpening = false;
    }
  }

  /// 构建板块流：板块 1 = 默认列表（最近更新/全部），后续 = 第一个分类维度的
  /// 各选项（跳过「全部」）逐个成板块。构建后立即加载前 2 个板块。
  void _buildHomeSections(List<FilterGroup> groups) {
    final sections = <_ComicHomeSection>[];
    sections.add(_ComicHomeSection(title: '最近更新', groups: groups));
    if (groups.isNotEmpty) {
      final first = groups.first;
      for (final opt in first.options) {
        if (opt.isAll) continue;
        sections.add(
          _ComicHomeSection(
            title: opt.name,
            groups: [first.copyWith(selected: opt)],
          ),
        );
      }
    }
    if (sections.isEmpty) return;
    setState(() {
      _homeSections = sections;
      _homeLoaded = 0;
      _homeMode = true;
      _categoryMode = false;
      _result = SearchResult.empty();
      _resultKeyword = '';
      _keyword = '';
      _searchController.clear();
      _historyVisible = false;
    });
    _loadHomeSection(0);
    _loadHomeSection(1);
  }

  /// 加载单个板块（getCategoryList 第一页；已加载/加载中跳过）
  Future<void> _loadHomeSection(int i) async {
    if (i >= _homeSections.length) return;
    final s = _homeSections[i];
    if (s.loading || s.items.isNotEmpty) return;
    s.loading = true;
    if (mounted) setState(() {});
    try {
      final srcId = SourceManager().current.id;
      final page = await SourceManager().current.getCategoryList(
        s.groups,
        page: 0,
      );
      if (!mounted || SourceManager().current.id != srcId) return;
      s.items = page.items.map(cmangaToComic).toList();
      s.error = null;
    } catch (e) {
      _log('板块「${s.title}」加载失败: $e');
      s.error = '加载失败';
    } finally {
      s.loading = false;
      // 🔴 只有**真的加载成功**才推进懒加载指针 ✓：原来这里是**无条件**推进 ✗ →
      // 某个板块一旦失败，指针照样 +1 ✓ → 该板块**永远不会再被请求** ✓
      //（滚到底也不会 ✓），用户只能重启 App 或换源才能看到它 ✓。
      // 成功路径在 :335 会把 `s.error` 置 null ✓，所以用它判定即可 ✓；
      // 失败则不推进 → 下次滚到底会**重新请求同一个板块**（用户可自愈 ✓）
      if (s.error == null) {
        _homeLoaded = i + 1 > _homeLoaded ? i + 1 : _homeLoaded;
      }
      if (mounted) setState(() {});
    }
  }

  /// 板块流懒加载：滚动接近底部时加载下一板块
  void _loadMoreHomeSections() {
    if (_homeLoaded >= _homeSections.length) return;
    _loadHomeSection(_homeLoaded);
  }

  /// 板块流渲染：整页滚动，板块标题 + 3 列封面网格
  /// 「搜索源」弹窗里的一枚源 chip（**流式换行**排布，用户 2026-10-07：
  /// 原来是一行一个的列表，现在改成"一个接一个、满行自动换行"）✓
  Widget _quickSourceChip({
    required String name,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? JellyTheme.primary
              : JellyTheme.primary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          // 兜底：空名源用 '?' 占位
          name.isEmpty ? '?' : name,
          style: TextStyle(
            fontSize: AppTheme.fontSubhead,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? Colors.white : JellyTheme.primary,
          ),
        ),
      ),
    );
  }

  Widget _buildHomeSectionFlow() {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels > n.metrics.maxScrollExtent - 600) {
          _loadMoreHomeSections();
        }
        return false;
      },
      child: ListView(
        padding: EdgeInsets.only(bottom: 12 + JellyNavBar.contentBottomAvoid),
        children: [
          for (var i = 0; i < _homeSections.length; i++)
            _homeSectionBlock(i),
        ],
      ),
    );
  }

  /// 板块标题右侧的「刷新」小圆钮（参考 cmbok：它每个板块标题右侧都有 ✓）。
  /// 加载中显示转圈并置灰不可点 ✓。
  Widget _sectionRefreshButton(int i, _ComicHomeSection s) {
    final busy = s.loading;
    return IconButton(
      tooltip: '刷新「${s.title}」',
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      icon: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              Icons.refresh_rounded,
              size: 18,
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.white70
                  : JellyTheme.textSecondary,
            ),
      onPressed: busy ? null : () => _refreshHomeSection(i),
    );
  }

  /// 强制重拉某个板块（清空后走 `_loadHomeSection` 原有链路；**不动其它板块** ✓）
  Future<void> _refreshHomeSection(int i) async {
    if (i >= _homeSections.length) return;
    final s = _homeSections[i];
    if (s.loading) return;
    s.items = [];
    s.error = null;
    if (mounted) setState(() {});
    await _loadHomeSection(i);
    if (mounted) setState(() {});
  }

  Widget _homeSectionBlock(int i) {
    final s = _homeSections[i];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
          child: Row(
            children: [
              Text(
                s.title,
                style: TextStyle(
                  fontSize: AppTheme.fontTitle3,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).brightness == Brightness.dark
                      ? Colors.white
                      : JellyTheme.textPrimaryLight,
                ),
              ),
              const Spacer(),
              // ✅ 分区「刷新」小圆钮（参考 cmbok ✓）
              _sectionRefreshButton(i, s),
            ],
          ),
        ),
        if (s.loading && s.items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            ),
          )
        else if (s.error != null && s.items.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: Text(
                s.error!,
                style: TextStyle(
                    fontSize: AppTheme.fontSubhead,
                    color: JellyTheme.textSecondary),
              ),
            ),
          )
        else
          GridView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 12,
              childAspectRatio: 0.56,
            ),
            // ⚠️ 用户 2026-10-07：「漫画页和书源页里面的分类内容只要显示前6个就行」
            //   ⇒ 每个分类板块只预览**前 6 个**（3 列 = 2 行）✓
            itemCount: s.items.length > 6 ? 6 : s.items.length,
            itemBuilder: (c, j) {
              final comic = s.items[j];
              return JellyComicCard(
                comic: comic,
                heroTag: comicCoverHeroTag('home', comic),
                onTap: () => _onComicTap(comic),
                compact: true,
              );
            },
          ),
      ],
    );
  }

  /// 切源后将对应 chip 滚动到可视区中部（源较多时防当前 chip 跑出屏幕）
  void _ensureChipVisible(MangaSource src) {
    final ctx = _chipKeys[src.id]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.5,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  /// 当前源是否仍需按共享词搜索；用于 _pendingSearch 补搜前判断（避免重复/空词）
  void _maybeSearchCurrent() {
    if (_isLoading) return;
    final id = SourceManager().current.id;
    final cached = _sourceStates[id];
    if (_keyword.trim().isNotEmpty &&
        (cached == null || cached.keyword != _keyword)) {
      _doSearch();
    }
  }

  Future<void> _loadHistory() async {
    final h = await SearchHistoryService.load();
    _log('加载搜索历史: ${h.length} 条');
    if (mounted) setState(() => _history = h);
  }

  Future<void> _addHistory(String keyword) async {
    final h = await SearchHistoryService.add(keyword);
    _log('添加搜索历史 "$keyword" -> 共 ${h.length} 条');
    if (mounted) setState(() => _history = h);
  }

  Future<void> _removeHistory(String keyword) async {
    _log('删除搜索历史: $keyword');
    final h = await SearchHistoryService.remove(keyword);
    _log('删除后剩余 ${h.length} 条');
    if (mounted) setState(() => _history = h);
  }

  Future<void> _clearHistory() async {
    _log('清空搜索历史');
    final h = await SearchHistoryService.clear();
    if (mounted) setState(() => _history = h);
  }

  void _onScroll(ScrollController controller) {
    if (!controller.hasClients) return;
    final pixels = controller.position.pixels;
    final max = controller.position.maxScrollExtent;
    if (pixels >= max - 200 && max > 0) {
      _loadMore();
    }
    final show = pixels > 300;
    if (show != _showBackToTop) {
      setState(() => _showBackToTop = show);
    }
  }

  /// 执行一次搜索（来自提交或历史记录点击）
  void _runSearch(String keyword) {
    _log('runSearch: "$keyword"');
    FocusScope.of(context).unfocus();
    // URL 兜底：粘贴漫画详情页 URL -> 识别站点 -> 进详情（不作为关键词保存到源状态）
    if (keyword.startsWith('http://') || keyword.startsWith('https://')) {
      _searchController.text = keyword;
      _openByUrl(keyword);
      return;
    }
    _keyword = keyword;
    _categoryMode = false; // 关键词搜索退出分类模式
    _searchController.text = keyword;
    _searchController.selection = TextSelection.collapsed(
      offset: keyword.length,
    );
    setState(() {}); // 退出历史面板
    _addHistory(keyword);
    _doSearch();
  }

  Future<void> _doSearch({bool loadMore = false}) async {
    _log('开始搜索, loadMore=$loadMore, isLoading=$_isLoading, keyword=$_keyword');

    // loadMore 仅在无并发搜索时追加；新搜索遇忙则推迟（切源/换词中途）
    if (_isLoading) {
      if (!loadMore) _pendingSearch = true;
      _log('正在加载中，${loadMore ? "跳过 loadMore" : "推迟为新搜索"}');
      return;
    }
    if (!loadMore && _keyword.trim().isEmpty) {
      _log('关键词为空，跳过');
      return;
    }
    if (!loadMore) _homeMode = false; // 新搜索退出板块流

    final srcId = SourceManager().current.id;
    // 捕获本次搜索词：loadMore 用产生当前结果的词，新搜索用共享词；防止中途变化导致缓存错配
    final searchKw = loadMore ? _resultKeyword : _keyword;

    setState(() {
      _isLoading = true;
      if (!loadMore) _isSearching = true;
    });

    try {
      final page = loadMore ? _result.currentPage : 0;
      final mangasPage = await SourceManager().current.search(
        searchKw,
        page: page,
      );
      final newResult = mangasPageToSearchResult(
        mangasPage,
        currentPage: page + 1,
      );
      _log('API返回: ${newResult.items.length} 条, 总数: ${newResult.total}');
      final stillCurrent = SourceManager().current.id == srcId;

      if (loadMore) {
        final combined = SearchResult(
          items: [..._result.items, ...newResult.items],
          total: newResult.total,
          currentPage: newResult.currentPage,
          totalPages: newResult.totalPages,
        );
        if (stillCurrent) {
          _result = combined;
          if (_sourceStates[srcId] != null) {
            _sourceStates[srcId]!.result = combined;
          }
          if (mounted) setState(() {});
        }
        // 切走则丢弃本次 loadMore 结果（返回该源可再 loadMore）
      } else {
        // 写入被搜源缓存（无论是否仍为当前源）
        final s = _sourceStates[srcId] ?? _SourceSearchState()
          ..categoryGroups = _categoryGroups
          ..categoriesLoaded = _categoriesLoaded
          ..searchSession = _searchSession;
        s
          ..result = newResult
          ..keyword = searchKw
          ..categoryMode = false;
        _sourceStates[srcId] = s;
        // 仅当仍为当前源时刷新显示（切走则只更新缓存，不污染新源显示）
        if (stillCurrent && mounted) {
          setState(() {
            _result = newResult;
            _resultKeyword = searchKw;
            _searchSession++; // 新搜索 -> 触发瀑布动画
          });
        }
      }
    } on UnsupportedSearchError catch (e) {
      _log('不支持搜索: $e');
      if (mounted && SourceManager().current.id == srcId) _toast(e.message);
    } catch (e) {
      // 🔴 原来这里**只 `_log`** ✗ —— 而 `_log` 只在 `kDebugMode` 打印 ✓ →
      // release 下用户看到的是「**没有找到相关漫画**」✗：把"**请求失败**"
      // 当成了"**没有数据**" ✓，而且**没有任何重试入口** ✓
      //（对比上面 `UnsupportedSearchError` 分支是有 toast 的 ✓，属漏写 ✓）。
      // 现在给同样的可见提示 ✓，并沿用同一守卫（避免把别的源的失败报到这里 ✓）
      _log('搜索异常: $e');
      if (mounted && SourceManager().current.id == srcId) {
        _toast('搜索失败：请检查网络后重试');
      }
    } finally {
      _isLoading = false;
      if (mounted && SourceManager().current.id == srcId) {
        setState(() => _isSearching = false);
      }
      // 补搜：搜索中途切源/换词积压的请求
      if (_pendingSearch) {
        _pendingSearch = false;
        _maybeSearchCurrent();
      }
    }
  }

  void _loadMore() {
    if (_result.hasMore && !_isLoading) {
      if (_categoryMode) {
        _doCategorySearch(loadMore: true);
      } else {
        _doSearch(loadMore: true);
      }
    }
  }

  /// 返回顶部
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

  /// tab 停稳后回写 ViewMode（持久化 + 供收藏页/显示设置页联动）；幂等判断防循环
  void _onTabChanged() {
    if (!_tabController.indexIsChanging) {
      final isGrid = _tabController.index == 0;
      if (ViewMode().isGrid != isGrid) ViewMode().set(isGrid);
    }
    final c = _activeScrollController;
    final show = c.hasClients && c.position.pixels > 300;
    if (show != _showBackToTop) {
      _showBackToTop = show;
      if (mounted) setState(() {});
    }
  }

  /// 外部（显示设置页等）改了 ViewMode -> 同步 tab；幂等判断防循环
  void _onViewModeChangedExternal() {
    if (!mounted) return;
    final target = ViewMode().isGrid ? 0 : 1;
    // ⚠️ 必须同时判 `indexIsChanging`：动画进行中 index 仍是旧值，
    // 若此时用户又点了另一侧，index==target 会误判"已就位"不触发 animateTo，
    // 动画继续飞向旧目标 → 视图"切不回来"。动画中一律强制重定向。
    if (_tabController.index != target || _tabController.indexIsChanging) {
      _tabController.animateTo(target);
      // ⚠️ 兜底（用户 2026-10-07：「是漫画页不切换」）：
      //   本页在 IndexedStack 里、或动画期间被重建时，`animateTo` 有时
      //   **不推进**（TabBarView 未挂载/被回收）⇒ 表现就是"显示设置里改了
      //   漫画视图，漫画页却没变"✗。下一帧对一次：动画没跑且没到位就直接跳 ✓
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_tabController.indexIsChanging &&
            _tabController.index != target) {
          _tabController.index = target;
        }
      });
    }
  }

  /// 宫格列数变化（3/4/5）→ 重建（网格 crossAxisCount 读 ReadingLayout）
  void _onLayoutChanged() {
    if (mounted) setState(() {});
  }

  /// 源变化（云端更新 reload 等）-> 重建：无源空状态与正常搜索界面互切。
  void _onSourcesChanged() {
    if (!mounted) return;
    setState(() {});
  }

  // ========== 左右滑动：切源优先，末源过界切视图（参考书架） ==========

  // 用 Listener（原始指针事件）检测水平滑动，不参与手势仲裁，
  // 避免与内部纵向 ListView 抢手势导致"要滑两次"。
  Offset? _swipeStart;

  void _onSwipeDown(PointerDownEvent e) {
    _swipeStart = e.position;
  }

  void _onSwipeUp(PointerUpEvent e) {
    _handleSwipeEnd(e.position);
  }

  void _onSwipeCancel(PointerCancelEvent e) {
    _swipeStart = null;
  }

  void _handleSwipeEnd(Offset end) {
    final start = _swipeStart;
    _swipeStart = null;
    if (start == null) return;
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    // 明显水平为主且超过距离阈值才触发，避免误触纵向滚动/轻点
    if (dx.abs() < 50) return;
    if (dx.abs() <= dy.abs() * 1.3) return;
    if (dx < 0) {
      _swipeNext();
    } else {
      _swipePrev();
    }
  }

  /// 左滑（前进）：下一源；已是末源则切视图并回首源；列表末源到头无操作。
  /// 线性序列：网格A -> 网格B -> … -> 列表A -> 列表B
  void _swipeNext() {
    final sources = SourceManager().sources;
    final idx = sources.indexWhere((s) => s.id == SourceManager().current.id);
    if (idx >= 0 && idx < sources.length - 1) {
      _switchSource(sources[idx + 1]);
    } else if (_tabController.index == 0) {
      // 末源 + 网格 -> 切列表视图，回到首源
      _switchSource(sources.first);
      _tabController.animateTo(1);
    }
    // 列表末源 -> 无操作（线性序列末端）
  }

  /// 右滑（后退）：上一源；已是首源则切视图并回末源；网格首源到头无操作。
  void _swipePrev() {
    final sources = SourceManager().sources;
    final idx = sources.indexWhere((s) => s.id == SourceManager().current.id);
    if (idx > 0) {
      _switchSource(sources[idx - 1]);
    } else if (_tabController.index == 1) {
      // 首源 + 列表 -> 切网格视图，回到末源
      _switchSource(sources.last);
      _tabController.animateTo(0);
    }
    // 网格首源 -> 无操作（线性序列首端）
  }

  void _onComicTap(Comic comic) {
    FocusScope.of(context).unfocus(); // 进详情属"其他情况"，主动失焦收起历史与键盘
    BrowseHistoryService().recordComic(comic); // 记录浏览（去重置顶，仅搜索页入口记录）
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ComicDetailPage(
          comic: comic,
          heroTag: comicCoverHeroTag('search', comic),
        ),
      ),
    );
  }

  /// 漫画源切换小标签（横向滚动居中，样式同图书搜索页格式标签）
  /// 搜索框本体（不带外边距）—— 放在标题行的 Expanded 里。
  ///
  /// 原来是常驻长条 `JellySearchBar`，占掉一整行宽度。按用户要求改成
  /// 与首页右上角同款的小胶囊：收起 = 44 圆钮（搜索图标），点击展开成胶囊，
  /// 图标在左、提示「搜索漫画」。
  Widget _searchField() {
    return JellyExpandableSearch(
      controller: _searchController,
      hintText: '搜索漫画',
      // 用户 2026-10-07：宽度改成原来的三分之二（160 → 107）
      maxWidth: 107,
      onFocusChange: (f) => setState(() {
        if (f) {
          if (_searchController.text.isEmpty) {
            _historyVisible = true;
          }
        } else {
          // 失焦即收起历史（只有手动点击搜索框才获焦弹历史）
          _historyVisible = false;
        }
      }),
      onCleared: () => setState(() => _historyVisible = false),
      onSubmitted: (value) => _runSearch(value),
      onChanged: (value) => setState(() {}),
    );
  }

  Widget _buildSourceChips(bool isDark) {
    final sources = SourceManager().enabledSources;
    final currentId = SourceManager().current.id;
    final chips = <Widget>[];
    for (var i = 0; i < sources.length; i++) {
      if (i > 0) chips.add(const SizedBox(width: 8));
      final src = sources[i];
      final key = _chipKeys.putIfAbsent(src.id, () => GlobalKey());
      chips.add(_buildSourceChip(src, src.id == currentId, isDark, key: key));
    }
    return Row(
      children: [
        // 「聚搜」固定在第一位，不随源 chip 横向滑动（对齐参考图）
        _buildAggregateChip(isDark),
        const SizedBox(width: 8),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: chips,
            ),
          ),
        ),
        const SizedBox(width: 8),
        // 搜索源按钮（快速源列表弹窗）：源排最右侧
        // （用户 2026-10-06 反馈"漫画页少个搜索源"——与书源页 view_list 对齐）
        Material(
          color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _showQuickSourceSheet,
            child: SizedBox(
              width: 32,
              height: 32,
              // ✅ 用户 2026-10-07：与书源页统一成**向下箭头**（原来是 view_list ✗）
              child: Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 22,
                color: JellyTheme.textPrimaryLight,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 「聚搜」chip：跨所有启用漫画源并发聚合搜索
  ///
  /// ✅ 用户 2026-10-07：按钮**只留图标**（去掉"聚搜"文字），
  ///   与书源页的聚搜按钮同款；尺寸对齐同排的 32 圆钮。
  Widget _buildAggregateChip(bool isDark) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ComicAggregateSearchPage()),
      ),
      child: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
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
          Icons.auto_awesome_rounded,
          size: 16,
          color: JellyTheme.primary,
        ),
      ),
    );
  }

  /// 快速漫画源列表弹窗（「搜索源」输入框 + 源列表筛选 + 快速切换）
  /// 入口：源 chip 排最右侧的 view_list 按钮（用户 2026-10-06 反馈"少个搜索源"）
  Future<void> _showQuickSourceSheet() async {
    final sources = SourceManager().enabledSources;
    final isDark =
        Theme.of(context).brightness == Brightness.dark;
    final filter = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final kw = filter.text.trim().toLowerCase();
            final shown = kw.isEmpty
                ? sources
                : sources
                    .where((s) => s.name.toLowerCase().contains(kw))
                    .toList();
            return SafeArea(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.7,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: JellySearchBar(
                        controller: filter,
                        hintText: '搜索源',
                        onChanged: (_) => setSheetState(() {}),
                        onCleared: () => setSheetState(() {}),
                      ),
                    ),
                    // ⚠️ 用户 2026-10-07：「那个源搜索能不能是一个接一个呢，
                    //   一行接一行的，不要以列表形式呢」
                    //   ⇒ 由「一行一个的 ListTile 列表」改成**自动换行的 chip 流** ✓
                    //   （与参考图一致：源 chip 一个接一个、满行自动换行）
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final s in shown)
                              _quickSourceChip(
                                name: s.name,
                                selected: s.id == SourceManager().current.id,
                                onTap: () {
                                  Navigator.pop(ctx);
                                  if (s.id != SourceManager().current.id) {
                                    _switchSource(s);
                                  }
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    filter.dispose();
  }

  Widget _buildSourceChip(
    MangaSource src,
    bool selected,
    bool isDark, {
    required GlobalKey key,
  }) {
    final label = Text(
      src.name,
      style: TextStyle(
        fontSize: AppTheme.fontFootnote,
        fontWeight: FontWeight.w600,
        color: selected
            ? Colors.white
            : (isDark ? Colors.white70 : JellyTheme.textSecondary),
      ),
    );
    return GestureDetector(
      onTap: () => _switchSource(src),
      child: Container(
        key: key,
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
        // 需要魔法的源：右上角叠魔法小图标
        child: src.needsMagic
            ? Stack(
                clipBehavior: Clip.none,
                children: [
                  label,
                  Positioned(
                    top: -6,
                    right: -8,
                    child: Image.asset(
                      'assets/icons/magic_stick.png',
                      width: 12,
                      height: 12,
                    ),
                  ),
                ],
              )
            : label,
      ),
    );
  }

  /// URL 兜底：粘贴漫画详情页 URL -> 识别站点 -> 切源 -> 进详情页
  Future<void> _openByUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      _toast('URL 无效');
      return;
    }
    // 遍历已注册的配置源按 host 识别（取代硬编码 defaultSites，远端新增站点也能识别）
    MangaSource? matched;
    for (final s in SourceManager().sources) {
      if (s is! ConfigMangaSource) continue;
      final su = Uri.tryParse(s.site.url);
      if (su != null && su.host == uri.host) {
        matched = s;
        break;
      }
    }
    if (matched == null) {
      _toast('未识别到对应站点，请检查 URL');
      return;
    }
    _switchSource(matched, autoSearch: false);
    final comic = cmangaToComic(
      CManga(id: url, sourceId: matched.id, title: '加载中…'),
    );
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ComicDetailPage(
          comic: comic,
          heroTag: comicCoverHeroTag('search', comic),
        ),
      ),
    );
  }

  void _toast(String msg) {
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

  /// 视图切换按钮 —— **已按要求从顶栏移除**。
  ///
  /// 用户 2026-10-07：「这要筛选就行」「将视图按钮只在我的里面的显示设置里面就行」
  ///   ⇒ 漫画页顶栏只留**筛选**按钮 ✓
  ///   ⇒ 视图（列表 / 宫格·3/4/5 列）统一在
  ///      「我的 → 显示设置 → 漫画搜索页视图」里选 ✓
  ///      （那边调用同一个 `ReadingViewToggle.showSheet`，写的是
  ///        `ViewMode` + `ReadingLayout`；本页监听这两个，照旧实时联动 ✓）

  /// 分类筛选按钮（视图切换右边；不支持分类的源置灰）
  Widget _buildCategoryButton(bool isDark) {
    final source = SourceManager().current;
    final enabled = source.supportsCategories;
    final active = _categoryMode;
    return GestureDetector(
      onTap: enabled
          ? () => _openCategorySheet(isDark)
          : () => _toast('该源暂不支持分类筛选'),
      child: Container(
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
          color: enabled
              ? (active
                    ? Colors.white
                    : (isDark ? Colors.white70 : JellyTheme.textSecondary))
              : (isDark ? Colors.white24 : Colors.black26),
        ),
      ),
    );
  }

  /// 浏览历史按钮（进入浏览记录页，仅漫画）
  /// 打开分类筛选弹窗（多维度单选，多组叠加 AND，底部重置/确定）
  Future<void> _openCategorySheet(bool isDark) async {
    if (_categorySheetOpening) return; // 防连点：拉取/弹窗期间禁用
    _categorySheetOpening = true;
    FocusScope.of(context).unfocus(); // 分类按钮属"其他情况"，主动失焦收起历史与键盘
    try {
      final source = SourceManager().current;
      if (!source.supportsCategories) {
        _toast('该源暂不支持分类筛选');
        return;
      }
      // 首次拉取分类维度（缓存复用）
      if (!_categoriesLoaded) {
        setState(() => _isLoading = true);
        try {
          _categoryGroups = await source.fetchCategories();
          _categoriesLoaded = true;
        } catch (e) {
          _log('分类维度拉取失败: $e');
          _toast('分类加载失败');
          if (mounted) setState(() => _isLoading = false);
          return;
        }
        if (mounted) setState(() => _isLoading = false);
      }
      if (!mounted || _categoryGroups.isEmpty) return;

      // 弹窗内编辑副本（确认前不改动已有结果）
      var draft = _categoryGroups
          .map(
            (g) => FilterGroup(
              key: g.key,
              title: g.title,
              options: g.options,
              selected: g.selected,
            ),
          )
          .toList();

      final result = await showModalBottomSheet<List<FilterGroup>>(
        context: context,
        isScrollControlled: true,
        backgroundColor: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        shape: jellySheetShape,
        builder: (ctx) {
          final labelColor = isDark
              ? Colors.white
              : JellyTheme.textPrimaryLight;
          return StatefulBuilder(
            builder: (ctx, setSheetState) {
              // bottom: true（默认）→ 键盘弹起时按 viewInsets 避让输入框
              return SafeArea(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(ctx).size.height * 0.72,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 自绘把手（showModalBottomSheet 无 dragHandleColor 参数）
                      const JellySheetHandle(),
                      // 标题栏（顶部自带把手，不再压 Divider）
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 16, 10),
                        child: Row(
                          children: [
                            Text(
                              '分类筛选',
                              style: TextStyle(
                                fontSize: AppTheme.fontTitle3,
                                fontWeight: FontWeight.w700,
                                color: labelColor,
                              ),
                            ),
                            const Spacer(),
                            JellySheetCircleButton(
                              isDark: isDark,
                              icon: Icons.close_rounded,
                              onTap: () => Navigator.pop(ctx),
                            ),
                          ],
                        ),
                      ),
                      // 维度列表：每个维度一个小节（标题竖条 + 选项 chips）
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                          itemCount: draft.length,
                          itemBuilder: (_, gi) {
                            final g = draft[gi];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  JellySheetSectionTitle(
                                    title: g.title,
                                    isDark: isDark,
                                  ),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: g.options.map((o) {
                                      final selected =
                                          g.selected?.value == o.value ||
                                              (g.selected == null && o.isAll);
                                      return JellyFilterChip(
                                        label: o.name,
                                        selected: selected,
                                        onTap: () {
                                          setSheetState(() {
                                            draft[gi] = o.isAll
                                                ? g.copyWith(
                                                    clearSelected: true,
                                                  )
                                                : g.copyWith(selected: o);
                                          });
                                        },
                                      );
                                    }).toList(),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                      // 底部按钮：重置 / 确定（等宽并排，与图书页同款）
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () {
                                  setSheetState(() {
                                    for (var i = 0; i < draft.length; i++) {
                                      draft[i] = draft[i].copyWith(
                                        clearSelected: true,
                                      );
                                    }
                                  });
                                },
                                style: OutlinedButton.styleFrom(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 13),
                                  side: BorderSide(
                                    color: isDark
                                        ? Colors.white.withValues(alpha: 0.22)
                                        : Colors.black.withValues(alpha: 0.16),
                                  ),
                                  shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(14)),
                                  foregroundColor: labelColor,
                                ),
                                child: const Text('重置'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton(
                                onPressed: () => Navigator.pop(ctx, draft),
                                style: FilledButton.styleFrom(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 13),
                                  shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(14)),
                                  backgroundColor: JellyTheme.primary,
                                ),
                                child: const Text('确定'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );

      if (result is List<FilterGroup>) {
        _applyCategories(result);
      }
    } finally {
      _categorySheetOpening = false;
    }
  }

  /// 应用分类选择：切分类模式、清空搜索框、按分类列出
  void _applyCategories(List<FilterGroup> groups) {
    FocusScope.of(context).unfocus(); // 分类模式不聚焦搜索框，避免弹键盘
    _categoryGroups = groups;
    _categoryMode = true;
    _homeMode = false; // 分类弹窗确认 → 退出板块流进单分类浏览
    _keyword = '';
    _resultKeyword = '';
    _searchController.clear();
    setState(() {
      _result = SearchResult.empty();
      _historyVisible = false;
    });
    _doCategorySearch();
  }

  /// 分类浏览搜索（与关键词搜索互斥；分页复用 _result）
  Future<void> _doCategorySearch({bool loadMore = false}) async {
    _log('开始分类搜索, loadMore=$loadMore');
    if (_isLoading) return;
    final srcId = SourceManager().current.id;
    setState(() {
      _isLoading = true;
      if (!loadMore) _isSearching = true;
    });
    try {
      final page = loadMore ? _result.currentPage : 0;
      final mangasPage = await SourceManager().current.getCategoryList(
        _categoryGroups,
        page: page,
      );
      final newResult = mangasPageToSearchResult(
        mangasPage,
        currentPage: page + 1,
      );
      _log('分类返回: ${newResult.items.length} 条, 总数: ${newResult.total}');
      final stillCurrent = SourceManager().current.id == srcId;

      if (loadMore) {
        final combined = SearchResult(
          items: [..._result.items, ...newResult.items],
          total: newResult.total,
          currentPage: newResult.currentPage,
          totalPages: newResult.totalPages,
        );
        if (stillCurrent) {
          _result = combined;
          if (_sourceStates[srcId] != null) {
            _sourceStates[srcId]!.result = combined;
          }
          if (mounted) setState(() {});
        }
      } else {
        final s = _sourceStates[srcId] ?? _SourceSearchState()
          ..categoryGroups = _categoryGroups
          ..categoriesLoaded = _categoriesLoaded
          ..searchSession = _searchSession;
        s
          ..result = newResult
          ..keyword = ''
          ..categoryMode = true;
        _sourceStates[srcId] = s;
        if (stillCurrent && mounted) {
          setState(() {
            _result = newResult;
            _resultKeyword = '';
            _searchSession++;
          });
        }
      }
    } catch (e) {
      _log('分类搜索异常: $e');
      if (mounted && SourceManager().current.id == srcId && !loadMore) {
        _toast('分类加载失败');
      }
    } finally {
      _isLoading = false;
      if (mounted && SourceManager().current.id == srcId) {
        setState(() => _isSearching = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 无可用源（未从云端更新过）：整页空状态，引导去漫画源仓库添加云端地址。
    // State 监听 SourceManager（initState 注册），云端更新 reload 后自动 rebuild 切回正常搜索界面。
    if (SourceManager().enabledSources.isEmpty) {
      return Scaffold(
        backgroundColor: widget.showBackButton ? null : Colors.transparent,
        appBar: widget.showBackButton ? AppBar(title: const Text('漫画')) : null,
        body: SafeArea(child: _buildEmptySourceState(isDark)),
      );
    }
    return Scaffold(
      backgroundColor: widget.showBackButton ? null : Colors.transparent,
      appBar: widget.showBackButton
          ? AppBar(
              title: const Text('漫画'),
              actions: [
                // ⚠️ 用户 2026-10-07：筛选按钮单独拉出来，其余 4 个动作叠一起。
                //   AppBar 分支（showBackButton）同样处理，保证两处一致。
                _buildCategoryButton(
                    Theme.of(context).brightness == Brightness.dark),
                const SizedBox(width: 6),
                // ⚠️ 用户要求（本轮）：右上角由「并排滑动动作栏」改成**叠图标控件** ——
//   · 最前的**完整可见**（深色圆底）
//   · 后面各露出一部分，**左右滑动**循环切换最前
//   · **长按**竖向展开全部
//   原来的 `JellySlidingActions`（4 个并排）已整体替换，不再保留。
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
        MaterialPageRoute(builder: (_) => const ComicDownloadRecordsPage()),
      ),
    ),
    JellyIconDeckItem(
      icon: Icons.source_rounded,
      tooltip: '漫画源仓库',
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SourceRepoPage()),
      ),
    ),
  ],
),
                const SizedBox(width: 12),
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
              // 高度跟着布局走：原来是"标题行 + 居中的搜索行"两行(152)，
              // 现在只有一行。搜索换成了可展开胶囊（高 50），
              // 行高 = headerTop(8) + 50 = 58。
              height: widget.showBackButton ? 60 : 58,
              child: Stack(
                children: [
                  // ── 标题行（一行放下：标题 / 搜索框 / 图标组）────────
                  //
                  // 原来是两行：第一行「标题 + 滑动图标组」，
                  // 第二行「居中的搜索框」。按用户截图重排成一行。
                  //
                  // ⚠️ 漫画页**不加拉绳**：图书/书源那根拉绳是"切到另一个
                  // 搜索界面"的开关，而漫画页没有可切换的目标。
                  // （用户漫画截图里标题右侧那根竖线是 iOS 的页面指示器，
                  //   不是拉绳 —— 别误加。）
                  if (!widget.showBackButton)
                    Positioned(
                      top: AppTheme.headerTop,
                      left: AppTheme.headerSide,
                      right: AppTheme.headerSide,
                      child: Row(
                        children: [
                          AppPageTitle('漫画', isDark: isDark),
                          const SizedBox(width: AppTheme.headerTitleGap),
                          // ── 🔴 `Spacer` 而不是 `Expanded`（修"叠图标被裁"）──
                          //
                          // 原来包在 `Expanded` 里 ✗。`Expanded` 给的是 **tight 满宽**：
                          //   · 它把中间那一大段宽度**全占掉**（约 230px），
                          //   · 而 `_searchField()` 内部 `maxWidth: 107`，
                          //     于是胶囊只画 107px，**剩下的是空白**（用户截图里那大片空 ✓）
                          //   · 但"名额"已经被 `Expanded` 吃掉 ⇒ 右侧叠图标只能用零头
                          //     ⇒ 一路顶到屏幕边缘、后面的卡片被裁掉 ✗
                          //
                          // 改 `Spacer` 后：搜索框只占内容宽（107），
                          // `Spacer` 吃掉左侧空白，右侧图标组拿回足够宽度 ✓
                          //（图书页/书源页上一轮已是这个写法，漫画页当时漏了。）
                          const Spacer(),
                          _searchField(),
                          const SizedBox(width: 10),
                          // ⚠️ 用户 2026-10-07（第二轮修正）：
                          //   · **筛选按钮单独拉出来** ✓（不塞进滑动栏）
                          //   · 其余 4 个动作叠在一起、左右滑动轮换 ✓
                          _buildCategoryButton(isDark),
                          const SizedBox(width: 10),
                          // ⚠️ 用户要求（本轮）：右上角由「并排滑动动作栏」改成**叠图标控件** ——
//   · 最前的**完整可见**（深色圆底）
//   · 后面各露出一部分，**左右滑动**循环切换最前
//   · **长按**竖向展开全部
//   原来的 `JellySlidingActions`（4 个并排）已整体替换，不再保留。
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
        MaterialPageRoute(builder: (_) => const ComicDownloadRecordsPage()),
      ),
    ),
    JellyIconDeckItem(
      icon: Icons.source_rounded,
      tooltip: '漫画源仓库',
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SourceRepoPage()),
      ),
    ),
  ],
),
                        ],
                      ),
                    ),
                  // 第二行（搜索框 + 视图切换 + 分类按钮）已删除 ——
                  // 搜索框并进标题行（Expanded 撑开），
                  // 视图切换与分类按钮随图标组放在其右侧。
                ],
              ),
                ),
                // 源切换小标签：从 Stack 里移出（Stack 高仅 58，原来
                // top:50/52 的 chip 行超出被裁掉 → 源 tab 栏看不见），
                // 现在紧贴标题行下方常显（聚搜 + 各源 chip 横向滑动）
                ListenableBuilder(
                  listenable: SourceManager(),
                  builder: (context, _) => _buildSourceChips(isDark),
                ),
              ],
            ),
          ),
          Expanded(
            child: Listener(
              // translucent：空态/无结果等 Center 的空白区域也能命中，
              // 否则 deferToChild 下空白处不触发 onPointerDown 导致无法滑动切源
              behavior: HitTestBehavior.translucent,
              onPointerDown: _onSwipeDown,
              onPointerUp: _onSwipeUp,
              onPointerCancel: _onSwipeCancel,
              child: _buildBody(),
            ),
          ),
        ],
      ),
    );
  }

  /// 无可用源空状态：提示去漫画源仓库添加云端地址并更新。
  ///
  /// ── 为什么有两种文案（用户给了两张图，它们不矛盾而是两个场景）──
  /// cmbok 这里其实是**两种状态**，用户截图各拍到一种：
  ///   · **一个源都没有**（还没配过）
  ///       → 「暂无漫画源 / 请到「漫画源仓库」填入云端地址并更新」+「去添加漫画源」
  ///         这是"引导"，语气中性
  ///   · **有源但都连不上**（配过，但云端/密钥服务器拉不到）
  ///       → 「漫画源已锁定 / 未能连接密钥服务器，请检查网络后重启软件」+「去漫画源仓库」
  ///         这是"故障"，必须说清原因，否则用户以为自己没配
  ///
  /// 用**已注册源数量**区分：注册过就说明是"故障"而非"没配"。
  Widget _buildEmptySourceState(bool isDark) {
    // 已注册的源（含被停用的）—— 区分"没配过"和"配了但连不上"
    final registered = SourceManager().sources.length;
    final hasConfigured = registered > 0;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasConfigured
                  ? Icons.lock_outline_rounded
                  : Icons.cloud_off_rounded,
              size: 48,
              color: JellyTheme.textSecondary,
            ),
            const SizedBox(height: 16),
            Text(
              hasConfigured ? '漫画源已锁定' : '暂无漫画源',
              style: TextStyle(
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              hasConfigured
                  ? '漫画源已锁定：未能连接密钥服务器，请检查网络后重启软件'
                  : '请到「漫画源仓库」填入云端地址并更新',
              style: TextStyle(fontSize: AppTheme.fontSubhead, color: JellyTheme.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SourceRepoPage()),
              ),
              icon: Icon(
                hasConfigured
                    ? Icons.settings_rounded
                    : Icons.add_circle_outline_rounded,
                size: 18,
              ),
              label: Text(hasConfigured ? '去漫画源仓库' : '去添加漫画源'),
            ),
          ],
        ),
      ),
    );
  }

  /// 悬浮返回顶部按钮（带出现/消失动画）
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
          // ⛔ **有意不同、不要"统一"成 `AppIconButton`** ✗✓（全模块返回顶部钮的**最后 1 处** ✓，
          //   与 `bookshelf_page` / `book_search_page` / `download_page` / `comic_detail_page`
          //   的返回顶部钮**完全同款** ✓）：它是**滚动出现的悬浮 FAB** ✓
          //   （44×44 ✓ · `primary` + `elevation: 4` 醒目 ✓ · `onTap: _scrollToTop` ✓）
          //   → 换成顶栏那种"淡圆底"会让它在内容上**几乎看不见** ✗✗
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
    // 搜索框聚焦且为空 -> 显示搜索历史（分类模式下不显示历史）
    if (_showHistory && !_categoryMode) return _buildHistory();

    // 搜索/筛选中 -> 显示加载（文案区分关键词/分类）
    if (_isSearching) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: JellyTheme.primary),
            const SizedBox(height: 16),
            Text(
              _categoryMode ? '正在筛选...' : '正在搜索...',
              style: TextStyle(color: JellyTheme.textSecondary),
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
            Icon(
              Icons.search_off_rounded,
              size: 48,
              color: JellyTheme.textSecondary,
            ),
            const SizedBox(height: 16),
            Text(
              '没有找到相关漫画',
              style: TextStyle(color: JellyTheme.textSecondary),
            ),
          ],
        ),
      );
    }

    // 板块流模式（进源默认）：最近更新 + 分类板块整页滚动（参考图 8579/8580）
    if (_homeMode && _homeSections.isNotEmpty) {
      return _buildHomeSectionFlow();
    }

    // 未搜索 = 初始界面
    if (_result.items.isEmpty && _keyword.isEmpty && !_categoryMode) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.palette_rounded,
              size: 48,
              color: JellyTheme.textSecondary,
            ),
            const SizedBox(height: 16),
            Text(
              '输入关键词开始搜索漫画',
              style: TextStyle(color: JellyTheme.textSecondary),
            ),
          ],
        ),
      );
    }

    // 结果：网格/列表由分段开关/滑动切源过界驱动（TabBarView 自身禁横滑，
    // 左右滑动手势由外层 Listener 接管用于切源/切视图，参考书架）
    return TabBarView(
      controller: _tabController,
      physics: const NeverScrollableScrollPhysics(),
      children: [_buildGridView(), _buildListView()],
    );
  }

  /// 搜索历史面板
  Widget _buildHistory() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final labelColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    // 点击空白区域关闭历史面板（点历史项仍正常搜索：项的 onTap 优先）
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
                child: Text(
                  '暂无搜索历史',
                  style: TextStyle(color: JellyTheme.textSecondary),
                ),
              ),
            )
          else
            ..._history.map(
              (kw) => ListTile(
                leading: Icon(
                  Icons.history_rounded,
                  color: JellyTheme.textSecondary,
                ),
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

  /// 瀑布入场 key（新搜索时变化触发动画；isGrid 为各视图固定标记，
  /// 避免 tab 动画过程中 index 翻转导致 key 变化、元素重挂闪烁）
  Key _entranceKey(int index, {required bool isGrid}) =>
      ValueKey('${isGrid}_${_searchSession}_$index');

  /// 根据可用宽度自适应列数
  int _adaptiveColumns(
    double width, {
    required int min,
    int max = 6,
    double target = 170,
  }) {
    final available = width - 40; // 左右各 20 内边距
    var cols = (available / target).floor();
    if (cols < min) cols = min;
    if (cols > max) cols = max;
    return cols;
  }

  /// 网格视图（瀑布流；列数由用户偏好决定：一排 3 / 4 / 5 个）
  Widget _buildGridView() {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 用户偏好列数（ReadingLayout，默认 3）；不再按宽度自适应，
        // 保证"一排 3/4/5 个"所见即所得（用户 2026-10-07）
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
            final comic = _result.items[index];
            return StaggeredEntrance(
              key: _entranceKey(index, isGrid: true),
              index: index,
              child: JellyComicCard(
                comic: comic,
                heroTag: comicCoverHeroTag('search', comic),
                onTap: () => _onComicTap(comic),
                compact: true,
              ),
            );
          },
        );
      },
    );
  }

  /// 列表视图（横向卡片，列数自适应）
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
            final comic = _result.items[index];
            return StaggeredEntrance(
              key: _entranceKey(index, isGrid: false),
              index: index,
              child: JellyComicListTile(
                comic: comic,
                heroTag: comicCoverHeroTag('search', comic),
                onTap: () => _onComicTap(comic),
              ),
            );
          },
        );
      },
    );
  }
}
