import 'dart:math' show min;
import 'dart:ui';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import '../models/book.dart';
import '../models/comic.dart';
import '../services/book_favorites_service.dart';
import '../services/book_view_mode.dart';
import '../services/favorites_service.dart';
import '../services/shelf_update_service.dart';
import '../services/view_mode.dart';
import '../theme/jelly_theme.dart';
import '../widgets/jelly_book_card.dart';
import '../widgets/jelly_expandable_search.dart';
import '../widgets/jelly_select_badge.dart';
import '../services/settings_service.dart';
import '../utils/list_pagination.dart';
import '../widgets/jelly_comic_card.dart';
import '../widgets/jelly_comic_list_tile.dart';
import '../widgets/jelly_nav_bar.dart';
import '../widgets/jelly_search_bar.dart';
import '../widgets/jelly_segmented_toggle.dart';
import '../widgets/staggered_entrance.dart';
import '../widgets/source_cover_image.dart';
import 'book_detail_page.dart';
import 'comic_detail_page.dart';
import '../../common/theme.dart';
import '../../widgets/app_page_header.dart';

/// 收藏页面（顶部 Tab：漫画收藏 / 图书收藏）
class FavoritesPage extends StatefulWidget {
  /// 是否为当前激活的 tab（用于触发收藏卡片入场动画）
  final bool isActive;

  /// 是否显示返回按钮（从"我的"页面入口进入时为 true）
  final bool showBackButton;

  /// 图书收藏独立页模式（从图书页聚合菜单进入）：
  /// 标题「图书收藏」+ 顶部搜索框，只显示图书收藏，无漫画/图书切换。
  final bool bookOnly;

  /// 漫画收藏独立页模式（从漫画页聚合菜单进入，参考图 IMG_8402）：
  /// 标题「漫画收藏」+ 顶部搜索框「搜索漫画」+ 漫画收藏列表。
  final bool comicOnly;

  const FavoritesPage({
    super.key,
    this.isActive = false,
    this.showBackButton = false,
    this.bookOnly = false,
    this.comicOnly = false,
  });

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage>
    with TickerProviderStateMixin {
  late TabController _tabController;

  // 多选模式
  bool _isSelecting = false;
  final Set<String> _selectedIds = {};

  // 搜索浮层
  bool _searchVisible = false;
  late final AnimationController _searchAnim;
  final TextEditingController _favSearchController = TextEditingController();
  String _favQuery = '';

  @override
  void initState() {
    super.initState();
    final tabs = SettingsService().effectiveContentTabs();
    final initialIdx = min(
      SettingsService().defaultContentTabIndex(),
      tabs.length - 1,
    );
    _tabController = TabController(
      length: tabs.length,
      vsync: this,
      initialIndex: initialIdx,
    );
    _tabController.addListener(_onTabChanged);
    SettingsService().addListener(_onContentTabsChanged);
    _searchAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
  }

  /// 上一次的 tab 下标（用于识别**滑动**切 tab，见 [_onTabChanged]）
  int _lastTabIndex = 0;

  void _onTabChanged() {
    // 切换 tab 时退出多选，避免不同类型 id 混乱
    // 🔴 原来只看 `_tabController.indexIsChanging` ✗ —— 那个标记**只在"点击"切换时为
    // true** ✓（SDK 里是先减计数再 notifyListeners ✓，**滑动只走 index setter** ✓）
    // → **手指滑动切 tab 时多选态不退出** ✓ → 漫画与图书的 id 混在同一个
    // `_selectedIds` 里 ✓，而删除只按**当前 tab 的类型**执行 ✓
    // → **静默少删，还提示"删除成功"** ✗（用户以为都删了 ✓）。
    // 这里改为按"**下标真的变了**"判定 ✓：点击和滑动都会命中 ✓
    final idx = _tabController.index;
    if (idx != _lastTabIndex) {
      _lastTabIndex = idx;
      if (_selectedIds.isNotEmpty) {
        setState(() {
          _isSelecting = false;
          _selectedIds.clear();
        });
      }
    }
  }

  /// 显示设置变化（跟随导航栏/默认显示/导航栏可见 tab）时，按需重建 TabController
  void _onContentTabsChanged() {
    if (!mounted) return;
    final newLen = SettingsService().effectiveContentTabs().length;
    if (newLen != _tabController.length) {
      final oldIndex = _tabController.index;
      _tabController.removeListener(_onTabChanged);
      _tabController.dispose();
      _tabController = TabController(
        length: newLen,
        vsync: this,
        initialIndex: min(oldIndex, newLen - 1),
      );
      _tabController.addListener(_onTabChanged);
    }
    setState(() {});
  }

  /// 当前 tab 是否为漫画（动态 tab 顺序下不依赖固定 index）
  bool get _isComicTab {
    final tabs = SettingsService().effectiveContentTabs();
    final idx = _tabController.index.clamp(0, tabs.length - 1);
    return tabs[idx] == NavTab.manga;
  }

  @override
  void dispose() {
    SettingsService().removeListener(_onContentTabsChanged);
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _searchAnim.dispose();
    _favSearchController.dispose();
    super.dispose();
  }

  /// 通用圆形图标按钮（浅灰底 + 近黑图标）—— 与书架页同款。
  ///
  Widget _buildSearchButton({double size = 50}) {
    final iconSize = size <= 40 ? 20.0 : 22.0;
    return Material(
      color: JellyTheme.primary,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _openSearch,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(
            Icons.search_rounded,
            color: Colors.white,
            size: iconSize,
          ),
        ),
      ),
    );
  }

  void _openSearch([String? initial]) {
    // 顶栏胶囊提交时带入关键词，直接出结果
    if (initial != null && initial.trim().isNotEmpty) {
      _favSearchController.text = initial;
      _favQuery = initial;
    }
    setState(() => _searchVisible = true);
    _searchAnim.forward();
  }

  void _closeSearch() {
    _searchAnim.reverse().then((_) {
      if (mounted) {
        _favSearchController.clear();
        setState(() {
          _searchVisible = false;
          _favQuery = '';
        });
      }
    });
  }

  void _openDetail(Comic comic) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => ComicDetailPage(comic: comic)),
    );
  }

  String _formatPopular(int popular) {
    if (popular >= 10000) return '${(popular / 10000).toStringAsFixed(1)}万';
    return popular.toString();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final contentTabs = SettingsService().effectiveContentTabs();
    // 胶囊切换改小：原按"半屏宽均分"太占地方（用户嫌标题边图标太大），
    // 固定段宽 40（两段共 90），配合 height 40 整体小一号
    final tabSegWidth = 40.0;
    return PopScope(
      canPop: !_isSelecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isSelecting) _exitSelection();
      },
      child: Scaffold(
        backgroundColor: (widget.showBackButton ||
                widget.bookOnly ||
                widget.comicOnly)
            ? null
            : Colors.transparent,
        appBar: (widget.showBackButton ||
                widget.bookOnly ||
                widget.comicOnly)
            ? AppBar(
                title: Text(widget.bookOnly
                    ? '图书收藏'
                    : (widget.comicOnly ? '漫画收藏' : '收藏')),
                // 独立收藏页标题居中（参考图 IMG_8470）
                centerTitle: true,
                actions: [
                  // 聚合模式（从漫画/图书/书源页 push 进来，showBackButton=true）：
                  // 标题行在 AppBar 下方会隐藏，所以把漫画/图书切换胶囊 + 搜索按钮放进 AppBar
                  if (!widget.bookOnly && !widget.comicOnly) ...[
                    if (contentTabs.length >= 2)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: AnimatedBuilder(
                          animation: _tabController.animation!,
                          builder: (context, _) => JellySegmentedToggle(
                            index: _tabController.animation!.value,
                            onChanged: (i) => _tabController.animateTo(i),
                            height: 36,
                            segmentWidth: 40,
                            segments: contentTabs
                                .map(
                                  (t) => JellySegmentData(
                                    icon: t == NavTab.manga
                                        ? Icons.palette_rounded
                                        : Icons.book_rounded,
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: _buildSearchButton(size: 36),
                    ),
                  ],
                ],
              )
            : null,
        body: widget.bookOnly
            ? _buildBookOnlyBody(isDark)
            : widget.comicOnly
                ? _buildComicOnlyBody(isDark)
                : Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SafeArea(
                  top: !widget.showBackButton,
                  bottom: false,
                  child: SizedBox(
                    // 高度跟着布局走：原来是"标题行 + 控件行"两行(105)，
                    // 现在只有一行。搜索换成了可展开胶囊（高 50），
                    // 行高 = headerTop(8) + 50 = 58。
                    height: contentTabs.length < 2
                        ? 0.0
                        : (widget.showBackButton ? 0.0 : 58.0),
                    child: Stack(
                      children: [
                        // ── 标题行（按截图：收藏 [漫画|图书] ······ (搜索)）──
                        //
                        // 原来这里是「标题 + JellySlidingActions（搜索/历史/下载/源仓库）」
                        // 的滑动图标组，而胶囊切换在**第二行居中**。
                        // 用户截图里是**一行**：标题 / 胶囊在左，右侧只有 1 个搜索圆按钮。
                        //
                        // ⚠️ 顺带修了一个真 bug：原来滑动组里的搜索动作写成
                        //   `onPressed: () => _buildSearchButton(size: 36)`
                        // —— 调用的是"构建按钮"而非"打开搜索"，
                        // 点了什么都不会发生（只 new 了一个不挂载的 Widget）。
                        if (!widget.showBackButton)
                          Positioned(
                            top: AppTheme.headerTop,
                            left: AppTheme.headerSide,
                            right: AppTheme.headerSide,
                            child: Row(
                              children: [
                                AppPageTitle('收藏', isDark: isDark),
                                const SizedBox(width: AppTheme.headerTitleGap),
                                // 胶囊切换挪进标题行（与书架页同一位置）
                                if (contentTabs.length >= 2)
                                  AnimatedBuilder(
                                    animation: _tabController.animation!,
                                    builder: (context, _) =>
                                        JellySegmentedToggle(
                                          index:
                                              _tabController.animation!.value,
                                          // 收藏页没有 _switchTab，
                                          // 原来第二行控件组也是直接 animateTo
                                          onChanged: (i) =>
                                              _tabController.animateTo(i),
                                          // 改小：高度 40、段宽 40
                                          height: 40,
                                          segmentWidth: tabSegWidth,
                                          segments: contentTabs
                                              .map(
                                                (t) => JellySegmentData(
                                                  icon: t == NavTab.manga
                                                      ? Icons.palette_rounded
                                                      : Icons.book_rounded,
                                                ),
                                              )
                                              .toList(),
                                        ),
                                  ),
                                // 搜索：与首页右上角同款小胶囊（收起=圆钮，
                                // 点击展开、图标在左、提示「搜索收藏」），
                                // 提交直接进搜索浮层出结果；
                                // 用户 2026-10-07：改**靠左**（原来右对齐 ✗）
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: FractionallySizedBox(
                                      widthFactor: 0.6,
                                      alignment: Alignment.centerLeft,
                                      child: JellyExpandableSearch(
                                        controller: _favSearchController,
                                        hintText: '搜索收藏',
                                        onSubmitted: (v) => _openSearch(v),
                                        onChanged: (v) => setState(() {}),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        // 第二行已删除：胶囊与搜索都挪进标题行（按用户截图）。
                        // 保留这个注释是为了说明"这里曾经有一行"，
                        // 避免以后有人以为漏写了控件组。
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: contentTabs
                        .map(
                          (t) => t == NavTab.manga
                              ? _ComicFavoritesTab(
                                  isActive: widget.isActive,
                                  isSelecting: _isSelecting,
                                  selectedIds: _selectedIds,
                                  onSelect: _onSelect,
                                )
                              : _BookFavoritesTab(
                                  isSelecting: _isSelecting,
                                  selectedIds: _selectedIds,
                                  onSelect: _onSelect,
                                ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ),
            if (_searchVisible) _buildSearchOverlay(),
            if (_isSelecting)
              Positioned(
                left: 20,
                right: 20,
                bottom: SettingsService().navFloating
                    ? JellyNavBar.floatingTotalHeight + 8
                    : 16.0,
                child: Center(child: _buildSelectionBar(isDark)),
              ),
          ],
        ),
      ),
    );
  }

  // ===== 图书收藏独立页（bookOnly）=====

  /// 参考目标界面 IMG_8395：标题「图书收藏」+ 顶部全宽搜索框 + 图书收藏列表
  Widget _buildBookOnlyBody(bool isDark) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: JellySearchBar(
            controller: _favSearchController,
            hintText: '搜索图书',
            onChanged: (v) => setState(() {}),
            onCleared: () => setState(() {}),
          ),
        ),
        Expanded(
          child: _BookFavoritesTab(
            isSelecting: _isSelecting,
            selectedIds: _selectedIds,
            onSelect: _onSelect,
            keyword: _favSearchController.text.trim(),
          ),
        ),
      ],
    );
  }

  // ===== 漫画收藏独立页（comicOnly）=====

  /// 参考目标界面 IMG_8402：标题「漫画收藏」+ 顶部搜索框「搜索漫画」+ 漫画收藏列表
  Widget _buildComicOnlyBody(bool isDark) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: JellySearchBar(
            controller: _favSearchController,
            hintText: '搜索漫画',
            onChanged: (v) => setState(() {}),
            onCleared: () => setState(() {}),
          ),
        ),
        Expanded(
          child: _ComicFavoritesTab(
            isActive: widget.isActive,
            isSelecting: _isSelecting,
            selectedIds: _selectedIds,
            onSelect: _onSelect,
            keyword: _favSearchController.text.trim(),
          ),
        ),
      ],
    );
  }

  // ===== 多选模式 =====

  void _onSelect(String id) {
    setState(() {
      if (!_isSelecting) {
        _isSelecting = true;
        _selectedIds
          ..clear()
          ..add(id);
      } else if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _exitSelection() {
    setState(() {
      _isSelecting = false;
      _selectedIds.clear();
    });
  }

  void _selectAll() {
    final isComic = _isComicTab;
    setState(() {
      _selectedIds
        ..clear()
        ..addAll(
          isComic
              ? FavoritesService().comics.map((c) => c.id)
              : BookFavoritesService().books.map((b) => b.id),
        );
    });
  }

  Future<void> _removeSelected() async {
    if (_selectedIds.isEmpty) return;
    final isComic = _isComicTab;
    final count = _selectedIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消收藏'),
        content: Text('确定取消收藏选中的 $count 项吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (isComic) {
      await FavoritesService().removeMany(_selectedIds);
    } else {
      await BookFavoritesService().removeMany(_selectedIds);
    }
    if (mounted) _exitSelection();
  }

  Widget _buildSelectionBar(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.12),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              '已选 ${_selectedIds.length} 项',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppTheme.fontBody,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
              ),
            ),
          ),
          const SizedBox(width: 12),
          TextButton(onPressed: _selectAll, child: const Text('全选')),
          const SizedBox(width: 4),
          FilledButton(
            onPressed: _selectedIds.isEmpty ? null : _removeSelected,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('取消'),
                SizedBox(width: 4),
                Icon(Icons.favorite_border_rounded, size: 18),
              ],
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: _exitSelection,
            icon: const Icon(Icons.close_rounded),
            tooltip: '退出多选',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }

  /// 搜索浮层：高斯模糊蒙版 + 居中搜索框/结果（带出场动画）
  Widget _buildSearchOverlay() {
    return Positioned.fill(
      child: Stack(
        children: [
          // 高斯模糊蒙版（点击关闭）
          Positioned.fill(
            child: GestureDetector(
              onTap: _closeSearch,
              behavior: HitTestBehavior.opaque,
              child: FadeTransition(
                opacity: _searchAnim,
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: Container(color: Colors.black.withValues(alpha: 0.2)),
                ),
              ),
            ),
          ),
          // 居中搜索框 + 结果（缩放淡入）
          Center(
            child: FadeTransition(
              opacity: _searchAnim,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.92, end: 1.0).animate(
                  CurvedAnimation(
                    parent: _searchAnim,
                    curve: Curves.easeOutBack,
                  ),
                ),
                child: _buildSearchContent(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchContent() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final q = _favQuery.trim().toLowerCase();
    final comics = FavoritesService().comics
        .where(
          (c) =>
              q.isEmpty ||
              c.title.toLowerCase().contains(q) ||
              (c.alias?.toLowerCase().contains(q) ?? false) ||
              (c.author?.toLowerCase().contains(q) ?? false),
        )
        .toList();
    final books = BookFavoritesService().books
        .where(
          (b) =>
              q.isEmpty ||
              b.title.toLowerCase().contains(q) ||
              (b.author?.toLowerCase().contains(q) ?? false),
        )
        .toList();
    // 交错合并漫画/图书，使两者都有机会展示；再限制前 10 条
    final all = <dynamic>[];
    var ci = 0, bi = 0;
    while (ci < comics.length || bi < books.length) {
      if (ci < comics.length) {
        all.add(comics[ci]);
        ci++;
      }
      if (bi < books.length) {
        all.add(books[bi]);
        bi++;
      }
    }
    const maxResults = 10;
    final limited = all.take(maxResults).toList();
    final hasMore = all.length > maxResults;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          JellySearchBar(
            controller: _favSearchController,
            hintText: '搜索收藏',
            autofocus: true,
            onChanged: (v) => setState(() => _favQuery = v),
            onCleared: () => setState(() => _favQuery = ''),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: MediaQuery.of(context).size.height * 0.4,
            child: Material(
              color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
              borderRadius: BorderRadius.circular(20),
              clipBehavior: Clip.antiAlias,
              child: all.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          '无匹配结果',
                          style: TextStyle(color: JellyTheme.textSecondary),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: limited.length + (hasMore ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index == limited.length) {
                          return Padding(
                            padding: const EdgeInsets.all(12),
                            child: Center(
                              child: Text(
                                '仅显示前 $maxResults 条，共 ${all.length} 条',
                                style: TextStyle(
                                  color: JellyTheme.textSecondary,
                                  fontSize: AppTheme.fontFootnote,
                                ),
                              ),
                            ),
                          );
                        }
                        final item = limited[index];
                        if (item is Comic) return _buildComicResultTile(item);
                        return _buildBookResultTile(item as Book);
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComicResultTile(Comic comic) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SourceCoverImage(
          url: comic.cover,
          width: 40,
          height: 56,
          fit: BoxFit.cover,
          placeholder: (c, u) => Container(
              color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
              width: 40,
              height: 56),
          errorWidget: (c, u, e) => Container(
            color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
            width: 40,
            height: 56,
            child: Icon(Icons.broken_image,
                size: 20, color: JellyTheme.textSecondary),
          ),
        ),
      ),
      title: Text(comic.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          comic.author,
          comic.alias,
          if (comic.popular != null && comic.popular! > 0)
            '🔥${_formatPopular(comic.popular!)}',
        ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: AppTheme.fontFootnote),
      ),
      trailing: Icon(
        Icons.palette_rounded,
        size: 18,
        color: isDark ? Colors.white24 : Colors.black26,
      ),
      onTap: () {
        _closeSearch();
        _openDetail(comic);
      },
    );
  }

  Widget _buildBookResultTile(Book book) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: (book.cover ?? '').isEmpty
            ? Container(
                color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
                width: 40,
                height: 56,
                child: Icon(
                  Icons.menu_book_rounded,
                  size: 20,
                  color: JellyTheme.textSecondary,
                ),
              )
            : CachedNetworkImage(
                imageUrl: book.cover!,
                width: 40,
                height: 56,
                fit: BoxFit.cover,
                placeholder: (c, u) => Container(
                    color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
                    width: 40,
                    height: 56),
                errorWidget: (c, u, e) => Container(
                  color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
                  width: 40,
                  height: 56,
                  child: Icon(
                    Icons.broken_image,
                    size: 20,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ),
      ),
      title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          book.author,
          book.extension?.toUpperCase(),
        ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: AppTheme.fontFootnote),
      ),
      trailing: Icon(
        Icons.book_rounded,
        size: 18,
        color: isDark ? Colors.white24 : Colors.black26,
      ),
      onTap: () {
        _closeSearch();
        _openBookDetail(book);
      },
    );
  }

  /// 打开图书详情（不传搜索结果 -> 详情页以作者搜索推荐）
  void _openBookDetail(Book book) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => BookDetailPage(book: book)),
    );
  }
}

/// 漫画收藏（跟随搜索页视图模式，列数自适应 + 置顶按钮）
class _ComicFavoritesTab extends StatefulWidget {
  final bool isActive;
  final bool isSelecting;
  final Set<String> selectedIds;
  final ValueChanged<String> onSelect;

  /// 搜索关键词（漫画收藏独立页传入；主页 tab 不传 = 显示全部）
  final String keyword;

  const _ComicFavoritesTab({
    this.isActive = false,
    this.isSelecting = false,
    this.selectedIds = const {},
    this.keyword = '',
    required this.onSelect,
  });

  @override
  State<_ComicFavoritesTab> createState() => _ComicFavoritesTabState();
}

class _ComicFavoritesTabState extends State<_ComicFavoritesTab> {
  final ScrollController _scrollController = ScrollController();
  bool _showBackToTop = false;
  int _session = 0; // 首次切到收藏 tab 时 +1，触发卡片瀑布入场动画
  bool _hasShownEntrance = false; // 是否已播过首次入场动画
  int _displayCount = ListPagination.pageSize; // 滚动懒加载：当前渲染条数

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // 设置开启「启动时检查书架更新」时后台扫描收藏漫画（服务内有冷却与互斥）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ShelfUpdateService.instance.scanShelfAndFavorites();
    });
  }

  @override
  void didUpdateWidget(covariant _ComicFavoritesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 仅首次切到收藏 tab 时重播入场动画，之后切回不再触发（避免闪烁）
    if (widget.isActive && !oldWidget.isActive && !_hasShownEntrance) {
      _hasShownEntrance = true;
      setState(() => _session++);
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final total = FavoritesService().comics.length;
    if (ListPagination.shouldLoadMore(_scrollController) &&
        _displayCount < total) {
      setState(
        () =>
            _displayCount = min(_displayCount + ListPagination.pageSize, total),
      );
      return;
    }
    final show = _scrollController.position.pixels > 300;
    if (show != _showBackToTop) setState(() => _showBackToTop = show);
  }

  void _scrollToTop() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        FavoritesService(),
        ViewMode(),
        ShelfUpdateService.instance,
      ]),
      builder: (context, _) {
        final all = FavoritesService().comics;
        final kw = widget.keyword.trim().toLowerCase();
        final comics = kw.isEmpty
            ? all
            : all
                .where((c) => c.title.toLowerCase().contains(kw))
                .toList();
        final isGrid = ViewMode().isGrid;
        if (comics.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.favorite_border_rounded,
                  size: 48,
                  color: JellyTheme.textSecondary,
                ),
                const SizedBox(height: 16),
                Text('还没有收藏的漫画',
                    style: TextStyle(color: JellyTheme.textSecondary)),
              ],
            ),
          );
        }
        return Column(
          children: [
            ListPaginationCountBar(total: comics.length, unit: '本'),
            Expanded(
              child: Stack(
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final cols = _adaptiveCols(
                        constraints.maxWidth,
                        min: isGrid ? 2 : 1,
                        target: isGrid ? 170 : 360,
                        max: isGrid ? 6 : 4,
                      );
                      return MasonryGridView.count(
                        controller: _scrollController,
                        padding: EdgeInsets.only(
                          top: 4,
                          left: 12,
                          right: 12,
                          bottom: 12 + JellyNavBar.contentBottomAvoid,
                        ),
                        crossAxisCount: cols,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 12,
                        itemCount: min(comics.length, _displayCount),
                        itemBuilder: (context, index) {
                          final comic = comics[index];
                          final selected = widget.selectedIds.contains(
                            comic.id,
                          );
                          final card = isGrid
                              ? JellyComicCard(
                                  comic: comic,
                                  heroTag: comicCoverHeroTag('fav', comic),
                                  onTap: widget.isSelecting
                                      ? () => widget.onSelect(comic.id)
                                      : () => _openDetail(context, comic),
                                  onLongPress: () => widget.onSelect(comic.id),
                                  showSourceBadge: true,
                                  updateCount: ShelfUpdateService.instance
                                      .newChapters(
                                          ShelfUpdateService.keyForComic(
                                              comic.pathWord)),
                                )
                              : JellyComicListTile(
                                  comic: comic,
                                  heroTag: comicCoverHeroTag('fav', comic),
                                  onTap: widget.isSelecting
                                      ? () => widget.onSelect(comic.id)
                                      : () => _openDetail(context, comic),
                                  onLongPress: () => widget.onSelect(comic.id),
                                  showSourceBadge: true,
                                );
                          return StaggeredEntrance(
                            key: ValueKey('${_session}_${comic.id}'),
                            index: index,
                            child: Stack(
                              children: [
                                card,
                                if (widget.isSelecting)
                                  Positioned(
                                    top: 4,
                                    right: 4,
                                    child: JellySelectBadge(selected: selected),
                                  ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                  // 置顶按钮
                  if (_showBackToTop && !widget.isSelecting)
                    ListenableBuilder(
                      listenable: SettingsService(),
                      builder: (context, _) {
                        final bottomOffset = SettingsService().navFloating
                            ? JellyNavBar.floatingTotalHeight + 8
                            : 16.0;
                        return Positioned(
                          bottom: bottomOffset,
                          right: 16,
                          child: AnimatedScale(
                            scale: _showBackToTop ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
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
                        );
                      },
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  static int _adaptiveCols(
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

  static void _openDetail(BuildContext context, Comic comic) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ComicDetailPage(
          comic: comic,
          heroTag: comicCoverHeroTag('fav', comic),
        ),
      ),
    );
  }
}

/// 图书收藏（跟随搜索页视图模式，列数自适应 + 置顶按钮）
class _BookFavoritesTab extends StatefulWidget {
  final bool isSelecting;
  final Set<String> selectedIds;
  final ValueChanged<String> onSelect;

  /// 搜索过滤关键词（图书收藏独立页顶部搜索框联动）
  final String keyword;

  const _BookFavoritesTab({
    this.isSelecting = false,
    this.selectedIds = const {},
    required this.onSelect,
    this.keyword = '',
  });

  @override
  State<_BookFavoritesTab> createState() => _BookFavoritesTabState();
}

class _BookFavoritesTabState extends State<_BookFavoritesTab> {
  final ScrollController _scrollController = ScrollController();
  bool _showBackToTop = false;
  int _displayCount = ListPagination.pageSize; // 滚动懒加载：当前渲染条数

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 关键词过滤后的收藏图书列表（空关键词 = 全部）
  List<Book> _filteredBooks() {
    final all = BookFavoritesService().books;
    final kw = widget.keyword.trim().toLowerCase();
    if (kw.isEmpty) return all;
    return all
        .where((b) =>
            b.title.toLowerCase().contains(kw) ||
            (b.author?.toLowerCase().contains(kw) ?? false))
        .toList();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final total = _filteredBooks().length;
    if (ListPagination.shouldLoadMore(_scrollController) &&
        _displayCount < total) {
      setState(
        () =>
            _displayCount = min(_displayCount + ListPagination.pageSize, total),
      );
      return;
    }
    final show = _scrollController.position.pixels > 300;
    if (show != _showBackToTop) setState(() => _showBackToTop = show);
  }

  void _scrollToTop() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _openDetail(Book book) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            BookDetailPage(book: book, heroTag: bookCoverHeroTag('fav', book)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([BookFavoritesService(), BookViewMode()]),
      builder: (context, _) {
        final books = _filteredBooks();
        final isGrid = BookViewMode().isGrid;
        final kw = widget.keyword.trim();
        if (books.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  kw.isEmpty
                      ? Icons.favorite_border_rounded
                      : Icons.search_off_rounded,
                  size: 48,
                  color: JellyTheme.textSecondary,
                ),
                const SizedBox(height: 16),
                Text(
                  kw.isEmpty ? '还没有收藏的图书' : '未找到匹配的图书',
                  style: TextStyle(color: JellyTheme.textSecondary),
                ),
              ],
            ),
          );
        }
        return Column(
          children: [
            ListPaginationCountBar(total: books.length, unit: '本'),
            Expanded(
              child: Stack(
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final cols = _adaptiveCols(
                        constraints.maxWidth,
                        min: isGrid ? 2 : 1,
                        target: isGrid ? 170 : 360,
                        max: isGrid ? 6 : 4,
                      );
                      return MasonryGridView.count(
                        controller: _scrollController,
                        padding: EdgeInsets.only(
                          top: 4,
                          left: 12,
                          right: 12,
                          bottom: 12 + JellyNavBar.contentBottomAvoid,
                        ),
                        crossAxisCount: cols,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 12,
                        itemCount: min(books.length, _displayCount),
                        itemBuilder: (context, index) {
                          final book = books[index];
                          final selected = widget.selectedIds.contains(book.id);
                          final card = JellyBookCard(
                            book: book,
                            isGrid: isGrid,
                            heroTag: bookCoverHeroTag('fav', book),
                            onTap: widget.isSelecting
                                ? () => widget.onSelect(book.id)
                                : () => _openDetail(book),
                            onLongPress: () => widget.onSelect(book.id),
                          );
                          return StaggeredEntrance(
                            key: ValueKey('book_${book.id}'),
                            index: index,
                            child: Stack(
                              children: [
                                card,
                                if (widget.isSelecting)
                                  Positioned(
                                    top: 4,
                                    right: 4,
                                    child: JellySelectBadge(selected: selected),
                                  ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                  if (_showBackToTop && !widget.isSelecting)
                    ListenableBuilder(
                      listenable: SettingsService(),
                      builder: (context, _) {
                        final bottomOffset = SettingsService().navFloating
                            ? JellyNavBar.floatingTotalHeight + 8
                            : 16.0;
                        return Positioned(
                          bottom: bottomOffset,
                          right: 16,
                          child: AnimatedScale(
                            scale: _showBackToTop ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
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
                        );
                      },
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  static int _adaptiveCols(
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
}
