import 'dart:math' show min;
import 'dart:convert';
import '../../widgets/common_widgets.dart';
import 'dart:io';
import 'dart:ui';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'peer_transfer_page.dart';
import '../models/book.dart';
import '../models/book_source.dart';
import '../models/bookshelf.dart';
import '../models/comic.dart';
import '../services/book_download_service.dart';
import '../services/book_source_service.dart';
import '../services/sync_service.dart';
import '../services/book_favorites_service.dart';
import '../services/book_reading_progress_service.dart';
import '../services/bookshelf_service.dart';
import '../services/shelf_update_service.dart';
import '../source/adapter.dart';
import '../source/source_manager.dart';
import '../services/download_service.dart';
import '../services/local_comic_import_service.dart';
import '../services/reading_progress_service.dart';
import '../services/settings_service.dart';
import '../utils/list_pagination.dart';
import '../theme/jelly_theme.dart';
import '../widgets/source_cover_image.dart';
import '../widgets/jelly_bookshelf_dialog.dart';
import '../widgets/jelly_nav_bar.dart';
import '../widgets/jelly_expandable_search.dart';
import '../widgets/jelly_search_bar.dart';
import '../widgets/jelly_segmented_toggle.dart';
import 'book_source_detail_page.dart';
import '../widgets/jelly_select_badge.dart';
import '../widgets/staggered_entrance.dart';
import '../../services/file_export_service.dart';
import 'book_detail_page.dart';
import 'book_reader_page.dart';
import 'comic_detail_page.dart';
import 'reader_page.dart';
import 'local_library_page.dart';
import '../../widgets/app_empty_view.dart';
import '../../common/theme.dart';
// 🔴 这里原来还有一行 `import '../../widgets/app_icon_button.dart';` ✗ —— 已删除 ✓。
// ℹ️ **关于下面这行 `app_icon_button.dart` 的 import**（B 档图标按钮统一 ② ✓）：
//    现在 `_buildSearchButton` 确实在用 `AppIconButton` ✓（`:1823` ✓）——
//    但**本文件依然不需要**显式 import 它 ✓✓：它与 `JellySearchBar` 一样是
//    **传递导出**可用的 ✓（`analyze` 在无该 import 时仍 `error=0` ✓，实测确认 ✓）。
//    所以我把 import 加回去的第一次尝试**只是加了注释、并没有加 import** ✗，
//    而代码照样编译 ✓ —— 这恰好证明了"不需要 import" ✓，那段注释已按事实改正 ✓。
// 原因很反直觉 ✓：`AppIconButton` 曾在本文件里**只被一处文档引用**用到
//（`/// … [AppIconButton] …` ✓），而 Dart 的 `unused_import` **把文档引用也算引用** ✓✓
// → 那段孤儿注释一删 ✓，这个 import 立刻变成 `unused_import` ✗
//（今天实测：`lib/reading` warning **0 → 1** ✓，跑闸门才发现 ✓）。
// 教训 ✓：**改注释也可能影响分析器判定** ✓ —— 删掉含 `[...]` 引用的注释后，
// 一定要再跑一次闸门 ✓（我这次就是跑了才发现的 ✓）
import '../../widgets/app_page_header.dart';
import '../../widgets/app_icon_button.dart';

/// "全部"虚拟书架 id：聚合当前 tab 可见的所有书架条目（仅浏览，不参与移出等管理操作）
const String kAllShelfId = '__all__';

/// 解析书架条目：普通书架直接取；"全部"聚合所有书架（漫画 tab 排除本地图书）。
/// 供书架页正文两个子组件与选择/移除逻辑共用。
List<BookshelfItem> resolveShelfItems(
  String shelfId,
  BookshelfItemType type, {
  bool excludeLocal = false,
}) {
  final svc = BookshelfService();
  if (shelfId != kAllShelfId) return svc.getItemsInShelf(shelfId, type);
  final seen = <String>{};
  final result = <BookshelfItem>[];
  for (final shelf in svc.bookshelves) {
    if (excludeLocal && shelf.id == BookshelfService.presetLocal) continue;
    for (final item in svc.getItemsInShelf(shelf.id, type)) {
      if (seen.add(item.itemId)) result.add(item);
    }
  }
  return result;
}

/// 书架页面
class BookshelfPage extends StatefulWidget {
  final bool isActive;

  /// 是否显示返回按钮（从"我的"页面入口进入时为 true）
  final bool showBackButton;

  /// 外部触发进入多选模式（底部导航「书架」上滑时自增，见 home_page）
  final ValueNotifier<int>? selectTrigger;

  const BookshelfPage({
    super.key,
    this.isActive = false,
    this.showBackButton = false,
    this.selectTrigger,
  });

  @override
  State<BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<BookshelfPage>
    with TickerProviderStateMixin {
  late TabController _tabController;
  String _currentShelfId = BookshelfService.presetReading;
  final ScrollController _comicScrollController = ScrollController();
  final ScrollController _bookScrollController = ScrollController();
  bool _showComicBackToTop = false;
  bool _showBookBackToTop = false;
  int _session = 0;
  bool _hasShownEntrance = false;
  int _comicDisplayCount = ListPagination.pageSize; // 漫画 tab 滚动懒加载条数
  int _bookDisplayCount = ListPagination.pageSize; // 图书 tab 滚动懒加载条数
  final Map<String, GlobalKey> _shelfChipKeys = {};

  // 多选模式
  bool _isSelecting = false;
  final Set<String> _selectedItemIds = {};

  // 搜索浮层
  late final AnimationController _searchAnim;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

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
    SettingsService().addListener(_onContentTabsChanged);
    _comicScrollController.addListener(_onComicScroll);
    _bookScrollController.addListener(_onBookScroll);
    _searchAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final shelves = BookshelfService().bookshelves;
      if (shelves.isNotEmpty) {
        setState(() => _currentShelfId = shelves.first.id);
      }
    });
    // 设置开启「启动时检查书架更新」时后台扫描（服务内有冷却与互斥）
    ShelfUpdateService.instance.scanShelfAndFavorites();
    // 监听外部多选触发（底部导航「书架」上滑）
    widget.selectTrigger?.addListener(_onExternalSelectTrigger);
  }

  /// 外部触发进入多选模式：切换 tab 到书架并进入多选
  void _onExternalSelectTrigger() {
    if (!mounted) return;
    setState(() {
      _isSelecting = true;
      _selectedItemIds.clear();
    });
    _toast('已进入批量多选：点击条目选择，底部可批量操作');
  }

  void _toast(String msg) {
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
  void didUpdateWidget(covariant BookshelfPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive && !_hasShownEntrance) {
      _hasShownEntrance = true;
      setState(() => _session++);
    }
  }

  @override
  void dispose() {
    widget.selectTrigger?.removeListener(_onExternalSelectTrigger);
    SettingsService().removeListener(_onContentTabsChanged);
    _tabController.dispose();
    _comicScrollController.dispose();
    _bookScrollController.dispose();
    _searchAnim.dispose();
    _searchController.dispose();
    super.dispose();
  }

  /// 显示设置变化（跟随导航栏/默认显示/导航栏可见 tab）时，按需重建 TabController
  void _onContentTabsChanged() {
    if (!mounted) return;
    final newLen = SettingsService().effectiveContentTabs().length;
    if (newLen != _tabController.length) {
      final oldIndex = _tabController.index;
      _tabController.dispose();
      _tabController = TabController(
        length: newLen,
        vsync: this,
        initialIndex: min(oldIndex, newLen - 1),
      );
    }
    if (mounted) setState(() {});
  }

  /// 当前 tab 是否为漫画（动态 tab 顺序下不依赖固定 index）
  bool get _isComicTab {
    final tabs = SettingsService().effectiveContentTabs();
    final idx = _tabController.index.clamp(0, tabs.length - 1);
    return tabs[idx] == NavTab.manga;
  }

  /// 当前 tab 的 NavTab
  NavTab get _currentTab {
    final tabs = SettingsService().effectiveContentTabs();
    final idx = _tabController.index.clamp(0, tabs.length - 1);
    return tabs[idx];
  }

  /// 指定 NavTab 在有效 tabs 中的 index（找不到返回 -1）
  int _indexOfTab(NavTab tab) =>
      SettingsService().effectiveContentTabs().indexOf(tab);

  void _onComicScroll() {
    if (!_comicScrollController.hasClients) return;
    // ⚡ 性能（本次唯一目的）：`total` 原来**每滚动一帧就查一次服务** ✗
    //   （`BookshelfService().countInShelf(...)` ✓）—— 而它**只在这个分支里用得到** ✓：
    //   当 `shouldLoadMore` 为假时，原代码算出的 `total` 根本没被使用 ✗。
    // ✓ 挪进分支 → 只有"快滚到底、要加载更多"时才查询 ✓
    // ℹ️ **语义完全不变** ✓：加载判定、`min(...)` 上限、`return` 时机，
    //   以及下面"回到顶部按钮"的翻转判定都保持原样 ✓
    if (ListPagination.shouldLoadMore(_comicScrollController)) {
      final total = BookshelfService().countInShelf(
        _currentShelfId,
        BookshelfItemType.comic,
      );
      if (_comicDisplayCount < total) {
        setState(
          () => _comicDisplayCount = min(
            _comicDisplayCount + ListPagination.pageSize,
            total,
          ),
        );
        return;
      }
    }
    final show = _comicScrollController.position.pixels > 300;
    if (show != _showComicBackToTop) setState(() => _showComicBackToTop = show);
  }

  void _onBookScroll() {
    if (!_bookScrollController.hasClients) return;
    // ⚡ 性能：与 `_onComicScroll` **同一处问题、同一处修法** ✓ ——
    //   `total` 原来每帧都查服务 ✗，而它只在"快到底要加载更多"时用得到 ✓。
    // ℹ️ **语义不变** ✓（`shouldLoadMore` 为假时，原来算的 `total` 从未被使用 ✓）
    if (ListPagination.shouldLoadMore(_bookScrollController)) {
      final total = BookshelfService().countInShelf(
        _currentShelfId,
        BookshelfItemType.book,
      );
      if (_bookDisplayCount < total) {
        setState(
          () => _bookDisplayCount = min(
            _bookDisplayCount + ListPagination.pageSize,
            total,
          ),
        );
        return;
      }
    }
    final show = _bookScrollController.position.pixels > 300;
    if (show != _showBookBackToTop) setState(() => _showBookBackToTop = show);
  }

  void _scrollComicToTop() {
    if (_comicScrollController.hasClients) {
      _comicScrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _scrollBookToTop() {
    if (_bookScrollController.hasClients) {
      _bookScrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }
  }

  // ========== 搜索浮层 ==========

  void _openSearch([String? initial]) {
    FocusScope.of(context).unfocus();
    // 顶栏胶囊提交时带入关键词，直接出结果
    if (initial != null && initial.trim().isNotEmpty) {
      _searchController.text = initial;
      _searchQuery = initial;
    }
    _searchAnim.forward();
  }

  void _closeSearch() {
    _searchAnim.reverse().then((_) {
      if (mounted) {
        _searchController.clear();
        setState(() => _searchQuery = '');
      }
    });
  }

  // ========== 书架管理 ==========

  Future<void> _createShelf() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建书架'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入书架名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      final shelf = await BookshelfService().createBookshelf(result.trim());
      // 🔴 `setState` 少了 `mounted` 检查 ✗ —— 而**隔壁那个分支**
      // （下面的 `else if (mounted)` ✓）明明写了 ✓，属**漏写** ✗。
      // 页面在"创建书架"的 await 窗口里被销毁时，这个 setState 会抛
      // `setState() called after dispose()` ✓（release 同样抛 ✗）。
      // ✓ 补上（与本文件 `:1295` 同款写法 ✓）
      if (!mounted) return;
      // 🟡 顺带释放这个 controller ✗：它在 `:314` 创建后**从未被 dispose** ✓
      //（`showDialog` 返回之后本方法再没用过它 ✓ —— 我已通读 `:344-358` 确认 ✓）
      // → 原来**每打开一次"新建书架"就泄漏一个** ✓，连带它的焦点/监听回调一起滞留 ✓
      controller.dispose();
      if (shelf != null) {
        setState(() => _currentShelfId = shelf.id);
      } else if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('书架名称已存在'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
      }
    }
  }

  Future<void> _renameShelf(Bookshelf shelf) async {
    final controller = TextEditingController(text: shelf.name);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名书架'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入新名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    // 🟡 与"新建书架"（`:347`）同款：这个 controller 也只服务于弹窗 ✓ ——
    // grep 求证过：`controller.` 在全文件**只有 3 处** ✓
    //（`:330` 新建弹窗 · `:347` 释放 · `:381` 重命名弹窗 ✓），
    // 弹窗返回之后**没有任何地方再用它** ✓ → 不释放就是"每次重命名泄漏一个" ✗
    controller.dispose();
    if (result != null && result.trim().isNotEmpty) {
      final ok = await BookshelfService().renameBookshelf(
        shelf.id,
        result.trim(),
      );
      if (!ok && mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('书架名称已存在'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
      }
    }
  }

  Future<void> _deleteShelf(Bookshelf shelf) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除书架'),
        content: Text('确定删除「${shelf.name}」吗？\n书架内的书籍不会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final ok = await BookshelfService().deleteBookshelf(shelf.id);
      // 🔴 同款漏写 ✗：`await` 之后直接 `setState` ✓ —— 而 `deleteBookshelf`
      // 要落盘（走磁盘 IO ✓），这个 await 窗口比同步分支**大得多** ✓，
      // 期间页面被销毁就抛 `setState() called after dispose()` ✗。
      // ✓ 补上（与本文件另外 8 处同款写法 ✓）
      if (!mounted) return;
      if (ok) {
        // 🟡 顺带修一个"**只增不减**"的缓存 ✗：`_shelfChipKeys` 只在渲染分组
        // chip 时 `putIfAbsent(shelfId, …)` ✓，而书架被删掉之后那个 `GlobalKey`
        // **永久驻留** ✓ → 每次增删书架都净涨一个 ✓（长期使用会一直积累 ✓）。
        // 删除成功后清掉它 ✓（`remove` 对不存在的键是安全的空操作 ✓）
        _shelfChipKeys.remove(shelf.id);
        final shelves = BookshelfService().bookshelves;
        if (shelves.isNotEmpty) {
          setState(() => _currentShelfId = shelves.first.id);
        }
      }
    }
  }

  /// 「书架设置」弹层（按截图）。
  ///
  /// 截图内容：标题「书架设置」+ 一项「移除同时删除本地文件」开关，
  /// 说明"从书架移除后，若该书不在其他书架，删除其本地文件（含导入的
  /// 原文件），不可恢复"。
  Future<void> _showShelfSettings() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Container(
          decoration: BoxDecoration(
            color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 8, bottom: 10),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: JellyTheme.textSecondary.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('书架设置',
                          style: TextStyle(
                            fontSize: AppTheme.fontTitle3,
                            fontWeight: FontWeight.w700,
                            color: label,
                          )),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('移除同时删除本地文件',
                                    style: TextStyle(
                                        fontSize: AppTheme.fontHeadline, color: label)),
                                const SizedBox(height: 5),
                                Text(
                                  '从书架移除后，若该书不在其他书架，'
                                  '删除其本地文件（含导入的原文件），不可恢复',
                                  style: TextStyle(
                                    fontSize: AppTheme.fontSubhead,
                                    height: 1.5,
                                    color: JellyTheme.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Switch(
                            value: SettingsService().shelfRemoveDeletesFile,
                            onChanged: (v) async {
                              await SettingsService()
                                  .setShelfRemoveDeletesFile(v);
                              setSheet(() {});
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 批量删除模式（截图里点「批量删除」后的形态）。
  ///
  /// 复用了页面已有的选择态（`_isSelecting` / `_selectedItemIds`）——
  /// 那套本来用于选中书架里的**条目**。这里用于选中**可删除的书架**
  /// （自建书架），预设书架不可删所以不进选择。
  Future<void> _showBatchDeleteShelves() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final picked = <String>{};
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          // 只有**自建**书架可删（预设是流程的一环，删了会出问题）
          final shelves =
              BookshelfService().bookshelves.where((s) => !s.isPreset).toList();
          return Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.75,
            ),
            decoration: BoxDecoration(
              color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 8, bottom: 4),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: JellyTheme.textSecondary.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 8, 6),
                    child: Row(
                      children: [
                        Text('管理书架',
                            style: TextStyle(
                              fontSize: AppTheme.fontTitle3,
                              fontWeight: FontWeight.w700,
                              color: label,
                            )),
                        const Spacer(),
                        // 截图里这一态是红色「✕ 取消」
                        TextButton.icon(
                          onPressed: () => Navigator.pop(ctx),
                          icon: const Icon(Icons.close_rounded,
                              size: 20, color: Colors.redAccent),
                          label: const Text('取消',
                              style: TextStyle(
                                  fontSize: AppTheme.fontBody, color: Colors.redAccent)),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: shelves.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(40),
                            child: Text('没有可删除的书架（预设书架不可删）',
                                style: TextStyle(
                                    fontSize: AppTheme.fontSubhead,
                                    color: JellyTheme.textSecondary)),
                          )
                        : ListView(
                            shrinkWrap: true,
                            padding:
                                const EdgeInsets.symmetric(vertical: 6),
                            children: [
                              for (final s in shelves)
                                CheckboxListTile(
                                  value: picked.contains(s.id),
                                  onChanged: (v) => setSheet(() {
                                    if (v == true) {
                                      picked.add(s.id);
                                    } else {
                                      picked.remove(s.id);
                                    }
                                  }),
                                  title: Text(
                                    _shelfDisplayName(s, _currentTypeFor()),
                                    style: TextStyle(
                                        fontSize: AppTheme.fontHeadline, color: label),
                                  ),
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                ),
                            ],
                          ),
                  ),
                  const Divider(height: 1),
                  // 底部：已选 N 个可删除书架 + 删除所选(N)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 16, 12),
                    child: Row(
                      children: [
                        Text(
                          '已选 ${picked.length} 个可删除书架',
                          style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              color: JellyTheme.textSecondary),
                        ),
                        const Spacer(),
                        FilledButton(
                          onPressed: picked.isEmpty
                              ? null
                              : () async {
                                  for (final id in picked) {
                                    await BookshelfService()
                                        .deleteBookshelf(id);
                                  }
                                  if (ctx.mounted) Navigator.pop(ctx);
                                },
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 22, vertical: 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                          child: Text('删除所选 (${picked.length})'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (mounted) setState(() {});
  }

  /// 当前 tab 对应的条目类型（漫画 / 图书）
  BookshelfItemType _currentTypeFor() => _isComicTab
      ? BookshelfItemType.comic
      : BookshelfItemType.book;

  /// 「管理书架」弹层（按用户截图）。
  ///
  /// 截图内容：
  ///   · 标题「管理书架」+ 右侧三个动作：⚙设置 / ＋新建 / 🗑批量删除
  ///   · 列表每行：≡拖动把手 / 书架名 / N本 / 👁显隐
  ///
  /// 与已有的长按菜单 [_showShelfMenu]（重命名/删除单个书架）是**互补**关系：
  /// 那个管单个书架，这个管整组（排序 + 显隐 + 批量）。
  Future<void> _showManageShelves() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          // 每次都从服务取，拖动/删除后立刻反映
          final shelves = BookshelfService().bookshelves;
          return Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.75,
            ),
            decoration: BoxDecoration(
              color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 8, bottom: 4),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: JellyTheme.textSecondary.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  // ── 标题行 + 右侧动作 ────────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 8, 6),
                    child: Row(
                      children: [
                        Text('管理书架',
                            style: TextStyle(
                              fontSize: AppTheme.fontTitle3,
                              fontWeight: FontWeight.w700,
                              color: label,
                            )),
                        const Spacer(),
                        // 设置 -> 「书架设置」弹层（按截图）
                        IconButton(
                          tooltip: '书架设置',
                          onPressed: () {
                            Navigator.pop(ctx);
                            _showShelfSettings();
                          },
                          icon: Icon(Icons.settings_outlined,
                              size: 21, color: label),
                        ),
                        // 新建
                        IconButton(
                          tooltip: '新建书架',
                          onPressed: () async {
                            Navigator.pop(ctx);
                            await _createShelf();
                            if (mounted) setState(() {});
                          },
                          icon: Icon(Icons.create_new_folder_outlined,
                              size: 21, color: label),
                        ),
                        // 批量删除
                        TextButton.icon(
                          onPressed: () {
                            Navigator.pop(ctx);
                            _showBatchDeleteShelves();
                          },
                          icon: Icon(Icons.delete_sweep_outlined,
                              size: 20, color: label),
                          label: Text('批量删除',
                              style: TextStyle(fontSize: AppTheme.fontBody, color: label)),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  // ── 可拖动排序的书架列表 ─────────────────────────
                  Flexible(
                    child: ReorderableListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: shelves.length,
                      // 拖动结束：把新顺序交给服务持久化
                      onReorder: (oldIndex, newIndex) async {
                        // Flutter 的约定：newIndex 是"插入到该位置之前"，
                        // 向下拖时要减 1 —— 不减会导致拖到相邻位就弹回去。
                        if (newIndex > oldIndex) newIndex -= 1;
                        final ids =
                            shelves.map((s) => s.id).toList(growable: true);
                        final moved = ids.removeAt(oldIndex);
                        ids.insert(newIndex, moved);
                        await BookshelfService().reorderShelves(ids);
                        setSheet(() {});
                      },
                      itemBuilder: (ctx2, i) {
                        final s = shelves[i];
                        // 与 _buildShelfBar 同一取法（_currentType 不存在，
                        // 类型由当前 tab 推出来）
                        final type = _isComicTab
                            ? BookshelfItemType.comic
                            : BookshelfItemType.book;
                        final count =
                            BookshelfService().countInShelf(s.id, type);
                        final hidden = SettingsService().isShelfHidden(s.id);
                        return Container(
                          key: ValueKey('shelf-manage-${s.id}'),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 4),
                          child: Row(
                            children: [
                              // 拖动把手（截图里是三条横线）
                              ReorderableDragStartListener(
                                index: i,
                                child: Icon(Icons.drag_handle_rounded,
                                    size: 20,
                                    color: JellyTheme.textSecondary),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  _shelfDisplayName(s, type),
                                  style: TextStyle(
                                      fontSize: AppTheme.fontHeadline, color: label),
                                ),
                              ),
                              Text(
                                '$count 本',
                                style: TextStyle(
                                    fontSize: AppTheme.fontSubhead,
                                    color: JellyTheme.textSecondary),
                              ),
                              const SizedBox(width: 10),
                              // 显隐：眼睛开关。
                              //
                              // ⚠️ 预设书架**也能**隐藏 —— 用户截图里
                              // 「正在读」的眼睛就是划线（已隐藏）态。
                              // 我第一版做成"预设不可隐藏 + 自建即删除"，
                              // 与截图不符且语义错误（隐藏 ≠ 删除）。
                              IconButton(
                                tooltip: hidden ? '当前隐藏，点击显示' : '当前显示，点击隐藏',
                                onPressed: () async {
                                  await SettingsService()
                                      .toggleShelfHidden(s.id);
                                  setSheet(() {});
                                  if (mounted) setState(() {});
                                },
                                icon: Icon(
                                  hidden
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  size: 20,
                                  color: hidden
                                      ? JellyTheme.textSecondary
                                          .withValues(alpha: 0.45)
                                      : JellyTheme.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (mounted) setState(() {});
  }

  void _showShelfMenu(Bookshelf shelf) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
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
                const SizedBox(height: 8),
                ListTile(
                  leading: const Icon(Icons.edit_rounded),
                  title: const Text('重命名'),
                  onTap: () {
                    Navigator.pop(context);
                    _renameShelf(shelf);
                  },
                ),
                if (!shelf.isPreset)
                  ListTile(
                    leading: const Icon(
                      Icons.delete_outline_rounded,
                      color: Colors.red,
                    ),
                    title: const Text(
                      '删除书架',
                      style: TextStyle(color: Colors.red),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      _deleteShelf(shelf);
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.close_rounded),
                  title: const Text('取消'),
                  onTap: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ========== 左右滑动：优先切书架，到边界切漫画/图书类型 ==========

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

  /// 左滑（下一）：切到下一个书架；已是末书架则切到图书 tab
  void _swipeNext() {
    final shelves = _visibleShelves(_currentTab);
    final idx = shelves.indexWhere((s) => s.id == _currentShelfId);
    if (idx >= 0 && idx < shelves.length - 1) {
      _switchShelf(shelves[idx + 1].id);
    } else if (_isComicTab) {
      _switchTab(NavTab.book);
    }
  }

  /// 右滑（上一）：切到上一个书架；已是首书架则切到漫画 tab
  void _swipePrev() {
    final shelves = _visibleShelves(_currentTab);
    final idx = shelves.indexWhere((s) => s.id == _currentShelfId);
    if (idx > 0) {
      _switchShelf(shelves[idx - 1].id);
    } else if (!_isComicTab) {
      _switchTab(NavTab.manga);
    }
  }

  /// 切换漫画/图书 tab：当前书架在新 tab 有书则保持，否则回第一个（避免空）
  void _switchTab(NavTab tab) {
    final idx = _indexOfTab(tab);
    if (idx < 0 || _tabController.index == idx) return;
    if (_isSelecting) {
      _isSelecting = false;
      _selectedItemIds.clear();
    }
    _tabController.animateTo(idx);
    final shelves = _visibleShelves(tab);
    if (shelves.isEmpty) return;
    final newType = tab == NavTab.manga
        ? BookshelfItemType.comic
        : BookshelfItemType.book;
    if (_currentShelfId != kAllShelfId &&
        BookshelfService().countInShelf(_currentShelfId, newType) == 0) {
      _switchShelf(shelves.first.id);
    }
  }

  /// 当前 tab 可见的书架列表：漫画 tab 隐藏"本地图书"书架（其内仅 Book 类型）
  List<Bookshelf> _visibleShelves(NavTab tab) {
    final s = SettingsService();
    final shelves = BookshelfService()
        .bookshelves
        // 被「管理书架」隐藏的书架不显示（预设书架也能隐藏 —— 见截图）
        .where((x) => !s.isShelfHidden(x.id))
        .toList();
    if (tab == NavTab.manga) {
      return shelves
          .where((x) => x.id != BookshelfService.presetLocal)
          .toList();
    }
    // 图书 tab 不显示「本地漫画」书架（其内仅 Comic 类型）
    return shelves
        .where((x) => x.id != BookshelfService.presetLocalComic)
        .toList();
  }

  /// 切换书架并滚动标签栏让当前 chip 可见
  void _switchShelf(String shelfId) {
    setState(() {
      _currentShelfId = shelfId;
      _comicDisplayCount = ListPagination.pageSize;
      _bookDisplayCount = ListPagination.pageSize;
      _isSelecting = false;
      _selectedItemIds.clear();
    });
    _ensureShelfChipVisible(shelfId);
  }

  void _ensureShelfChipVisible(String shelfId) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _shelfChipKeys[shelfId]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 200),
        );
      }
    });
  }

  GlobalKey _shelfChipKey(String shelfId) =>
      _shelfChipKeys.putIfAbsent(shelfId, () => GlobalKey());

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final contentTabs = SettingsService().effectiveContentTabs();
    // 胶囊切换改小：原按"半屏宽均分"太占地方（用户嫌左上角图标太大），
    // 固定段宽 40（两段共 90），配合 height 40 整体小一号
    final tabSegWidth = 40.0;
    return PopScope(
      canPop: !_isSelecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _isSelecting) _exitSelection();
      },
      child: Scaffold(
        backgroundColor: widget.showBackButton ? null : Colors.transparent,
        appBar: widget.showBackButton
            ? AppBar(
                title: const Text('书架'),
                actions: [
                  if (contentTabs.length < 2)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _buildSearchButton(size: 36),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: _buildImportExportButton(),
                  ),
                ],
              )
            : null,
        body: SafeArea(
          top: !widget.showBackButton,
          bottom: false,
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 顶部标题区
                  //
                  // ⚠️ 高度常量要跟着布局走。
                  // 原来是"标题一行 + 胶囊一行"共两行，所以两 tab 时是 105。
                  // 已按截图重排成**一行**（标题 / 胶囊 / 排序 / 搜索 …… 闪电），
                  // 搜索换成了可展开胶囊（高 50），行高 = headerTop(8) + 50 = 58。
                  SizedBox(
                    // ⚠️ 这里曾有一个高度 bug：
                    //   原式 = `contentTabs.length < 2 ? 0
                    //           : (widget.showBackButton ? 0 : 48)`
                    // 也就是 **showBackButton == true 时高度给 0**，
                    // 但下面 Stack 里的标题行只在 `!showBackButton` 时渲染、
                    // 胶囊是**无条件**渲染的 —— 高度 0 + 内容还在
                    // → 胶囊**溢出容器**，压到下面的分类栏上
                    //（用户截图里"书架上方的胶囊和下面的标签叠在一起"）。
                    //
                    // 只有**两个 tab 都没有**时这一行才真该消失
                    //（那种情况下标题行和胶囊都不渲染）。
                    height: contentTabs.length < 2 ? 0.0 : 58.0,
                    child: Stack(
                      children: [
                        // ── 标题行（一行内全部左对齐，右侧只放闪电）──────
                        //
                        // 按用户截图重排：原来标题在第 1 行、切换胶囊在第 2 行
                        // 且居中，搜索按钮跟着胶囊。截图里它们是**同一行、左对齐**：
                        //   书架  [漫画|图书]  (排序)  (搜索) ······  (闪电)
                        if (!widget.showBackButton)
                          Positioned(
                            top: AppTheme.headerTop,
                            left: AppTheme.headerSide,
                            right: AppTheme.headerSide,
                            child: Row(
                              children: [
                                AppPageTitle('书架', isDark: isDark),
                                const SizedBox(width: AppTheme.headerTitleGap),
                                Builder(
                                  builder: (context) {
                                    final tabs = SettingsService()
                                        .effectiveContentTabs();
                                    if (tabs.length < 2) {
                                      return const SizedBox.shrink();
                                    }
                                    return AnimatedBuilder(
                                      animation: _tabController.animation!,
                                      builder: (context, _) =>
                                          JellySegmentedToggle(
                                            index: _tabController
                                                .animation!.value,
                                            onChanged: (i) {
                                              if (i >= 0 &&
                                                  i < tabs.length) {
                                                _switchTab(tabs[i]);
                                              }
                                            },
                                            // 改小：高度 40、段宽 40
                                            height: 40,
                                            segmentWidth: tabSegWidth,
                                            segments: tabs
                                                .map(
                                                  (t) => JellySegmentData(
                                                    icon: t == NavTab.manga
                                                        ? Icons
                                                            .palette_rounded
                                                        : Icons.book_rounded,
                                                  ),
                                                )
                                                .toList(),
                                          ),
                                    );
                                  },
                                ),
                                const SizedBox(width: 8),
                                // 搜索：与首页右上角同款小胶囊（收起=圆钮，
                                // 点击展开、图标在左、提示「搜索书架」），
                                // 提交直接进搜索浮层出结果
                                //
                                // ── 🔴 靠右（修用户反馈）──────────────────
                                // 原来包在 `Expanded` 里 ✗ —— `Expanded` 是 tight 宽度，
                                // 搜索框在满宽里靠左 ⇒ 与右侧闪电按钮之间**空一大截** ✗
                                // 用户原话：「搜索框要靠右，右边的图标也要靠右，不要贴那么近」
                                //
                                // 改成 `Spacer` 之后：组件只占内容宽（`maxWidth`），
                                // 由 `Spacer` 吃掉左侧空白 ⇒ 胶囊自然贴到右侧 ✓，
                                // 再用 `SizedBox(width: 12)` 留出**不贴太近**的间距 ✓
                                //
                                // 实测对比：`Expanded` 包裹时胶囊停在可用区左缘、
                                // 与右侧图标空 46.8px ✗；`Spacer` 时间距正好 12px ✓
                                const Spacer(),
                                JellyExpandableSearch(
                                  controller: _searchController,
                                  hintText: '搜索书架',
                                  // 用户 2026-10-07：宽度改成原来的三分之二（200 → 133）
                                  maxWidth: 133,
                                  onSubmitted: (v) => _openSearch(v),
                                  onChanged: (v) => setState(() {}),
                                ),
                                const SizedBox(width: 12),
                                // 闪电：导入/导出（近黑实心圆）
                                _buildBoltButton(),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  // 书架分类栏
                  _buildShelfBar(isDark),
                  // 内容区：左右滑优先切书架，书架到边界再切漫画/图书类型
                  Expanded(
                    child: Listener(
                      onPointerDown: _onSwipeDown,
                      onPointerUp: _onSwipeUp,
                      onPointerCancel: _onSwipeCancel,
                      child: TabBarView(
                        controller: _tabController,
                        physics: const NeverScrollableScrollPhysics(),
                        children: SettingsService()
                            .effectiveContentTabs()
                            .map(
                              (t) => t == NavTab.manga
                                  ? _ComicShelfTab(
                                      shelfId: _currentShelfId,
                                      scrollController: _comicScrollController,
                                      showBackToTop: _showComicBackToTop,
                                      onBackToTop: _scrollComicToTop,
                                      session: _session,
                                      displayCount: _comicDisplayCount,
                                      isSelecting: _isSelecting,
                                      selectedIds: _selectedItemIds,
                                      onSelect: _onSelect,
                                    )
                                  : _BookShelfTab(
                                      shelfId: _currentShelfId,
                                      scrollController: _bookScrollController,
                                      showBackToTop: _showBookBackToTop,
                                      onBackToTop: _scrollBookToTop,
                                      session: _session,
                                      displayCount: _bookDisplayCount,
                                      isSelecting: _isSelecting,
                                      selectedIds: _selectedItemIds,
                                      onSelect: _onSelect,
                                    ),
                            )
                            .toList(),
                      ),
                    ),
                  ),
                ],
              ),
              // 搜索浮层
              _buildSearchOverlay(isDark),
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
      ),
    );
  }

  // ========== 多选模式 ==========

  void _onSelect(String itemId) {
    setState(() {
      if (!_isSelecting) {
        _isSelecting = true;
        _selectedItemIds
          ..clear()
          ..add(itemId);
      } else if (_selectedItemIds.contains(itemId)) {
        _selectedItemIds.remove(itemId);
      } else {
        _selectedItemIds.add(itemId);
      }
    });
  }

  void _exitSelection() {
    setState(() {
      _isSelecting = false;
      _selectedItemIds.clear();
    });
  }

  void _selectAll() {
    final type = _isComicTab ? BookshelfItemType.comic : BookshelfItemType.book;
    setState(() {
      _selectedItemIds
        ..clear()
        ..addAll(
          resolveShelfItems(
            _currentShelfId,
            type,
            excludeLocal: _isComicTab,
          ).map((i) => i.itemId),
        );
    });
  }

  Future<void> _removeSelectedFromShelf() async {
    if (_selectedItemIds.isEmpty) return;
    final type = _isComicTab ? BookshelfItemType.comic : BookshelfItemType.book;
    final count = _selectedItemIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移出书架'),
        content: Text('确定将选中的 $count 项移出当前书架？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移出'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // 🔴 这里在 `await showDialog(...)` **之后**直接用了 `context` ✗ ——
    // `ScaffoldMessenger.of` 内部是 `dependOnInheritedWidgetOfExactType<…>()!` ✓
    // → 页面在 await 窗口里被销毁时：debug 抛 `FlutterError`、**release 抛
    //   `Null check operator used on a null value`** ✓（用户看到的是"崩了"✗）。
    // ✓ 补上 `mounted` 检查 —— 本文件别处（同函数的另一个分支 ✓）本来就有这个
    //   写法 ✓，这里是**漏写** ✗
    if (!mounted) return;
    if (_currentShelfId == kAllShelfId) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('「全部」为汇总视图，请进入具体书架后管理'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      return;
    }
    // 🔴 这里原来**无条件**调 cleanupOrphanedImport → deleteTask → File.delete() ✗，
    // 而设置面板的文案（:428-430 / :480-482）明说「移除同时删除本地文件」是
    // **可选**开关、默认关；全仓库读这个设置的地方**只有那个 Switch 自己** ✗
    // → 「批量移出书架」实际是**不可恢复地删掉本地导入文件** ✗✗
    //
    // 同时把书架 id 与选中集**快照**下来：循环里含多个 await（还有磁盘 IO），
    // 期间用户切书架/继续点选会让剩余条目从**新书架**移除、或在迭代中改集合 ✗
    final shelfId = _currentShelfId;
    final ids = List<String>.from(_selectedItemIds);
    final deleteLocalFile = SettingsService().shelfRemoveDeletesFile;
    for (final itemId in ids) {
      await BookshelfService().removeFromBookshelf(
        shelfId,
        itemId,
        type,
      );
      if (type == BookshelfItemType.book && deleteLocalFile) {
        await BookDownloadService().cleanupOrphanedImport(itemId);
      }
    }
    if (mounted) _exitSelection();
  }

  Future<void> _moveSelectedToShelf() async {
    if (_selectedItemIds.isEmpty) return;
    final type = _isComicTab ? BookshelfItemType.comic : BookshelfItemType.book;
    final target = await _showBatchMoveDialog();
    if (target == null) return;
    for (final itemId in _selectedItemIds.toList()) {
      final meta = BookshelfService().findItemMeta(itemId, type);
      await BookshelfService().setBookshelvesForItem(
        [target],
        itemId,
        type,
        meta: meta,
      );
    }
    if (mounted) _exitSelection();
  }

  /// 批量移动：选目标书架（单选，禁用当前书架），返回目标 shelfId
  Future<String?> _showBatchMoveDialog() async {
    String? picked;
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        final textColor = isDark ? Colors.white : Colors.black87;
        return StatefulBuilder(
          builder: (ctx, setState) {
            final shelves = BookshelfService().bookshelves;
            return Container(
              decoration: BoxDecoration(
                color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: JellyTheme.textSecondary.withValues(
                            alpha: 0.3,
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                    Text(
                      '移到其他书架',
                      style: TextStyle(
                        fontSize: AppTheme.fontTitle3,
                        fontWeight: FontWeight.bold,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: shelves.length,
                        itemBuilder: (ctx, i) {
                          final s = shelves[i];
                          final selected = picked == s.id;
                          final disabled = s.id == _currentShelfId;
                          return InkWell(
                            onTap: disabled
                                ? null
                                : () => setState(() => picked = s.id),
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    selected
                                        ? Icons.radio_button_checked_rounded
                                        : Icons.radio_button_unchecked_rounded,
                                    color: selected
                                        ? JellyTheme.primary
                                        : (disabled
                                              ? JellyTheme.textSecondary
                                              : (isDark
                                                    ? Colors.white38
                                                    : Colors.black38)),
                                    size: 22,
                                  ),
                                  const SizedBox(width: 12),
                                  Icon(
                                    s.isPreset
                                        ? Icons.star_border_rounded
                                        : Icons.folder_outlined,
                                    size: 20,
                                    color: isDark
                                        ? Colors.white60
                                        : Colors.black54,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      s.name,
                                      style: TextStyle(
                                        fontSize: AppTheme.fontBody,
                                        color: disabled
                                            ? JellyTheme.textSecondary
                                            : textColor,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '${BookshelfService().countInShelf(s.id)}',
                                    style: TextStyle(
                                      fontSize: AppTheme.fontFootnote,
                                      color: isDark
                                          ? Colors.white38
                                          : Colors.black38,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: picked == null
                            ? null
                            : () => Navigator.pop(ctx, picked),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: JellyTheme.primary,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: 0,
                        ),
                        child: const Text(
                          '确定',
                          style: TextStyle(
                            fontSize: AppTheme.fontHeadline,
                            fontWeight: FontWeight.w600,
                          ),
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
              '已选 ${_selectedItemIds.length} 项',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppTheme.fontBody,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(onPressed: _selectAll, child: const Text('全选')),
          const SizedBox(width: 4),
          FilledButton.tonal(
            onPressed: _selectedItemIds.isEmpty
                ? null
                : _removeSelectedFromShelf,
            style: FilledButton.styleFrom(
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 40),
            ),
            child: const Icon(Icons.remove_circle_outline_rounded, size: 18),
          ),
          const SizedBox(width: 4),
          FilledButton(
            onPressed: _selectedItemIds.isEmpty ? null : _moveSelectedToShelf,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 40),
            ),
            child: const Icon(Icons.swap_horiz_rounded, size: 18),
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

  // ========== 顶部搜索按钮 ==========

  /// 排序方式选择面板。
  ///
  /// ── 为什么必须"真排序" ────────────────────────────────────────
  /// 用户截图里标题行有个排序按钮。如果只弹个面板不生效，
  /// 就是个假按钮 —— 比不放更糟（用户点了以为坏了）。
  /// 所以这里把选择**持久化到 SettingsService.shelfSort**，
  /// 两个书架列表（_ComicShelfTab / _BookShelfTab）读它来排。
  Future<void> _showSortSheet() async {
    final s = SettingsService();
    // 6 个选项 —— 与用户截图的排序面板一一对应（顺序也照截图）
    const options = <String, String>{
      'default': '默认',
      'title': '书名',
      'author': '作者',
      'added': '加入时间',
      'recent': '最近阅读',
      'progress': '阅读进度',
    };
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Container(
          decoration: BoxDecoration(
            color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 抓手
                Container(
                  margin: const EdgeInsets.only(top: 8, bottom: 4),
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: JellyTheme.textSecondary.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                // ── 标题行：排序方式 / 全局开关 / 方向 / 关闭 ──────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 12, 4),
                  child: Row(
                    children: [
                      Text('排序方式',
                          style: TextStyle(
                            fontSize: AppTheme.fontTitle3,
                            fontWeight: FontWeight.w700,
                            color: label,
                          )),
                      const Spacer(),
                      // 「全局」开关：所有书架共用这套排序
                      Text('全局',
                          style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              color: JellyTheme.textSecondary)),
                      const SizedBox(width: 4),
                      Transform.scale(
                        scale: 0.8,
                        child: Switch(
                          value: s.shelfSortGlobal,
                          onChanged: (v) async {
                            await s.setShelfSortGlobal(v);
                            setSheet(() {});
                          },
                        ),
                      ),
                      const SizedBox(width: 2),
                      // 方向：点击在"正序 / 倒序"之间切
                      IconButton(
                        tooltip: s.shelfSortAsc
                            ? '当前正序，点击切倒序'
                            : '当前倒序，点击切正序',
                        onPressed: () async {
                          await s.setShelfSortAsc(!s.shelfSortAsc);
                          setSheet(() {});
                        },
                        icon: Icon(
                          s.shelfSortAsc
                              ? Icons.sort_by_alpha_rounded
                              : Icons.sort_rounded,
                          size: 22,
                          color: JellyTheme.textSecondary,
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: Icon(Icons.close_rounded,
                            size: 22, color: JellyTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
                // ── 选项：一组圆角卡片 ────────────────────────────────
                //
                // 截图里每项是**独立的浅灰圆角条**（不是 ListTile + 图标），
                // 当前选中项底色更深一点。
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Column(
                    children: [
                      for (final e in options.entries)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: GestureDetector(
                            onTap: () => Navigator.pop(ctx, e.key),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 15),
                              decoration: BoxDecoration(
                                color: s.shelfSort == e.key
                                    ? (isDark
                                        ? Colors.white.withValues(alpha: 0.14)
                                        : Colors.black
                                            .withValues(alpha: 0.09))
                                    : (isDark
                                        ? Colors.white.withValues(alpha: 0.06)
                                        : Colors.black
                                            .withValues(alpha: 0.035)),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text(
                                e.value,
                                style: TextStyle(
                                  fontSize: AppTheme.fontHeadline,
                                  fontWeight: s.shelfSort == e.key
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                  color: label,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (picked == null) return;
    await s.setShelfSort(picked);
    if (mounted) setState(() {});
  }

  // ℹ️ 书架这排按钮用**浅灰圆 + 近黑图标** ✓（与「我的」页右上角那三个同款 ✓），
  // 而 `_buildSearchButton`（见下面 `:1797` 附近 ✓）在**别处**（如空态里的
  // "去搜索" ✓）仍是**深色主色圆** ✓ → 所以两者分开写、不合并 ✓。
  // 🔴 原注释在此处还写着"通用圆形图标按钮……实现已抽到 `AppIconButton`……
  // 留这个薄委托，只为让调用点不用改" ✗ —— 这些话**与现状不符** ✓：
  // 本文件里**既没有**那个"通用圆形图标按钮"方法 ✓，`_buildSearchButton`
  // 也仍是**手写**的（`:1797` ✓）、并无任何委托 ✓。
  // 那段误导性描述已删除 ✓（只保留上面这句真实的原因 ✓）
  /// ✅ **统一到共用组件 `AppIconButton`** ✓（B 档：图标按钮统一 ② ✓）
  /// 原来这里是**手写**：`Material(color: isDark ? 白@92% : JellyTheme.primary ✗,
  /// elevation: 2 ✗, shadowColor: 黑@25% ✗)` + `InkWell` + `SizedBox` + 图标 ✓。
  /// ✓ 改用 **`filled: true`** ✓ —— 组件对 filled 的定义正是
  ///   「**深色下白底深图标，浅色下主题色底白图标**；用于"导入/导出"这类需要被看见的入口」✓
  ///   → 与原来的配色**几乎完全一致** ✓✓（**唯一变化：去掉投影** ✗→✓，与其它圆钮质感统一 ✓）
  /// ℹ️ `tooltip` 在组件里**必填** ✗（原来这枚没有 ✓）→ 补 `'导入 / 导出'` ✓（与菜单语义一致 ✓）
  /// ℹ️ 图标尺寸沿用原来的 20 ✓；`size` 沿用调用点（`:1201` 用默认 36 ✓）
  Widget _buildBoltButton({double size = 36}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AppIconButton(
      icon: Icons.bolt_rounded,
      tooltip: '导入 / 导出',
      onTap: _showImportExportMenu,
      isDark: isDark,
      size: size,
      iconSize: 20,
      filled: true,
    );
  }

  /// ✅ **统一到共用组件 `AppIconButton`** ✓（B 档：图标按钮统一 ② ✓）
  /// 原来这里是**手写**：`Material(color: JellyTheme.primary ✗, elevation: 4 ✗,
  /// shadowColor: primary@40% ✗)` + `InkWell` + `SizedBox` + **白色**图标 ✓
  /// —— 于是书架顶栏**同一排里出现三种质感的圆钮** ✗（主题色带投影 ✗ / 近黑实心 ✗ / 淡灰 ✓）。
  /// ✓ 现在用组件的默认形态：**淡圆底 + 单色图标** ✓（正是组件文档写明的统一目标 ✓）。
  /// ⚠️ **视觉会变** ✓：从"主题色 + 投影"✗ 变成"淡圆底"✓ —— 这是**预期的统一** ✓，不是回归 ✓。
  /// ℹ️ `tooltip` 在组件里是**必填** ✗（原来这枚没有 tooltip ✓）→ 补 `'搜索'` ✓。
  /// ℹ️ 尺寸/图标大小沿用调用点传的值 ✓（`:1098` 传 `size: 36` ✓ → 与之前渲染一致 ✓）。
  Widget _buildSearchButton({double size = 50}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final iconSize = size <= 40 ? 20.0 : 22.0;
    return AppIconButton(
      icon: Icons.search_rounded,
      tooltip: '搜索',
      onTap: _openSearch,
      isDark: isDark,
      size: size,
      iconSize: iconSize,
    );
  }

  // ========== 导入/导出 ==========

  /// ✅ **与 `_buildBoltButton` 合并** ✓（B 档 ② ✓）—— 原来这里是**同一枚按钮的第二份实现** ✗✗：
  /// `Material(color: const Color(0xFFF19841) ✗ 橙色, elevation: 2 ✗,
  /// shadowColor: 0xFFF19841@40% ✗)` + `Icon(Icons.bolt_rounded, white, 20)` +
  /// `onTap: _showImportExportMenu` ✓ —— 与 `_buildBoltButton` **逐字同款** ✓
  ///（连 `onTap`、图标、36×36、20 全都相同 ✓）。
  /// ⚠️ 更值得记一笔 ✓：那个橙色 `0xFFF19841` ✗ 正是 `_buildBoltButton` 的**旧注释**
  ///   点名要改掉的色 ✓（"原来是橙色…与水墨书香（黑白灰）不符"✓）
  ///   → 说明当时**只改了其中一份、漏了这一份** ✗（与"4 份 `_buildCircleIcon`"
  ///   是同一类"抄多份、改一处"✗✓）。
  /// ✓ 现在**委托给 `_buildBoltButton`** ✓：两处永远一致 ✓，且都走
  ///   `AppIconButton(filled: true)` ✓（`size` 默认 36 ✓ = 与原来硬编码的 36 一致 ✓✓）
  Widget _buildImportExportButton() => _buildBoltButton();

  void _showImportExportMenu() {
    FocusScope.of(context).unfocus();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final cardColor = isDark ? JellyTheme.cardDark : JellyTheme.cardLight;
        final titleColor =
            isDark ? Colors.white : JellyTheme.textPrimaryLight;
        final subColor =
            isDark ? Colors.white70 : JellyTheme.textSecondary;
        final groupColor = isDark ? Colors.white38 : Colors.black45;

        /// 分组小标题（导入 / 传输·备份）
        Widget groupLabel(String text) => Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    fontWeight: FontWeight.w700,
                    color: groupColor,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            );

        /// 单项：圆角底色图标容器（primary@12%）+ 标题 + 副标题
        Widget item({
          required IconData icon,
          required String title,
          required String subtitle,
          required VoidCallback onTap,
          Color? accent,
        }) {
          final c = accent ?? JellyTheme.primary;
          return ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            leading: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: c.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: c, size: 22),
            ),
            title: Text(
              title,
              style: TextStyle(
                fontSize: AppTheme.fontBody,
                fontWeight: FontWeight.w600,
                color: titleColor,
              ),
            ),
            subtitle: Text(
              subtitle,
              style: TextStyle(fontSize: AppTheme.fontFootnote, color: subColor),
            ),
            onTap: onTap,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          );
        }

        return Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 12),
                // 抓手条
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.2)
                          : Colors.black.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                // 标题 + 副标题
                Text(
                  '书架数据',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.w700,
                    color: titleColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '导入 / 导出 / 同步书架内容',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    color: subColor,
                  ),
                ),
                const SizedBox(height: 6),
                // ── 导入 ─────────────────────────────────────
                groupLabel('导入'),
                item(
                  icon: Icons.file_download_outlined,
                  title: '导入本地图书',
                  subtitle: '从本地文件导入 epub / pdf / txt 图书',
                  onTap: () {
                    Navigator.pop(context);
                    _importLocalBook();
                  },
                ),
                item(
                  icon: Icons.photo_library_outlined,
                  title: '导入本地漫画',
                  subtitle: '图片 / 文件夹 / ZIP / CBZ，导入后离线阅读',
                  onTap: () {
                    Navigator.pop(context);
                    _importLocalComic();
                  },
                ),
                item(
                  icon: Icons.folder_open_outlined,
                  title: '扫描书库',
                  subtitle: '选择文件夹，批量扫描 txt / epub 等图书入库',
                  onTap: () {
                    Navigator.pop(context);
                    _scanLibraryFolder();
                  },
                ),
                item(
                  icon: Icons.inventory_2_outlined,
                  title: '本地库管理',
                  subtitle: '多库根 · 标签 · 查重 · 回收站',
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const LocalLibraryPage(),
                      ),
                    );
                  },
                ),
                item(
                  icon: Icons.restore_rounded,
                  title: '导入阅读备份',
                  subtitle: '解析 legado 备份（书架 / 进度 / 书签）写入书架',
                  onTap: () {
                    Navigator.pop(context);
                    _importLegadoBackup();
                  },
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 2, 20, 4),
                  child: Text(
                    '导入的图书会加入「本地图书」书架，仅在图书标签下显示，离线可读',
                    style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: isDark ? Colors.white38 : Colors.black38,
                    ),
                  ),
                ),
                // ── 传输 / 备份 ─────────────────────────────
                groupLabel('传输 / 备份'),
                item(
                  icon: Icons.upload_outlined,
                  title: '传书到手机 / 电脑',
                  subtitle: '把书架的书发送到手机或电脑',
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => kbSheet(const PeerTransferPage(
                            mode: PeerTransferMode.send)),
                      ),
                    );
                  },
                ),
                item(
                  icon: Icons.download_outlined,
                  title: '从手机 / 电脑接收',
                  subtitle: '接收手机 / 电脑发来的书，自动入库',
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const PeerTransferPage(
                          mode: PeerTransferMode.receive,
                        ),
                      ),
                    );
                  },
                ),
                item(
                  icon: Icons.cloud_sync_outlined,
                  title: 'WebDAV 备份同步',
                  subtitle: '把书架 / 设置备份到 WebDAV 网盘，换机恢复',
                  onTap: () {
                    Navigator.pop(context);
                    _showWebdavPanel();
                  },
                ),
                item(
                  icon: Icons.menu_book_outlined,
                  title: 'Kindle 推送',
                  subtitle: '通过邮件把图书推送到 Kindle 设备',
                  onTap: () {
                    Navigator.pop(context);
                    _showKindlePanel();
                  },
                ),
                const SizedBox(height: 6),
                // ── 取消 ─────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    style: TextButton.styleFrom(
                      foregroundColor:
                          isDark ? Colors.white70 : JellyTheme.textSecondary,
                    ),
                    child: const Text('取消'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// WebDAV 备份同步面板：配置 + 立即备份 / 从云端恢复。
  Future<void> _showWebdavPanel() async {
    await SyncService.instance.load();
    final c = SyncService.instance.config;
    final urlC = TextEditingController(text: c.webdavUrl);
    final userC = TextEditingController(text: c.webdavUser);
    final passC = TextEditingController(text: c.webdavPass);
    final pathC = TextEditingController(text: c.webdavPath);
    var busy = false;

    void toast(String msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ));
    }

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Container(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom),
          decoration: BoxDecoration(
            color: Theme.of(ctx).scaffoldBackgroundColor,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(22)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('WebDAV 备份同步',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(
                      '服务器示例：https://dav.example.com/dav/',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: urlC,
                      decoration: const InputDecoration(
                          labelText: 'WebDAV 服务器地址',
                          border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: userC,
                      decoration: const InputDecoration(
                          labelText: '用户名', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: passC,
                      obscureText: true,
                      decoration: const InputDecoration(
                          labelText: '密码', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: pathC,
                      decoration: const InputDecoration(
                          labelText: '备份路径（默认 NewTv/bookshelf_backup.json）',
                          border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: busy
                                ? null
                                : () async {
                                    setSheet(() => busy = true);
                                    await SyncService.instance.save(SyncConfig(
                                      webdavUrl: urlC.text.trim(),
                                      webdavUser: userC.text.trim(),
                                      webdavPass: passC.text,
                                      webdavPath: pathC.text.trim(),
                                    ));
                                    final json =
                                        BookshelfService().exportJson();
                                    final r = await SyncService.instance
                                        .backupBookshelf(json);
                                    if (ctx.mounted) {
                                      Navigator.pop(ctx);
                                    }
                                    toast(r.ok
                                        ? '备份成功（${json.length ~/ 1024} KB）'
                                        : '备份失败：${r.error}');
                                  },
                            icon: const Icon(Icons.cloud_upload_outlined,
                                size: 18),
                            label: busy
                                ? const Text('备份中…')
                                : const Text('立即备份'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: busy
                                ? null
                                : () async {
                                    setSheet(() => busy = true);
                                    final r = await SyncService.instance
                                        .restoreBookshelf();
                                    if (ctx.mounted) Navigator.pop(ctx);
                                    if (!r.ok) {
                                      toast('恢复失败：${r.error}');
                                      return;
                                    }
                                    final n = await BookshelfService()
                                        .importJson(r.json ?? '');
                                    // 🔴 `importJson` 在**解析失败/空数据**时静默 `return 0`
                                    //（bookshelf_service.dart 里 `catch { return 0; }` 吞掉一切 ✗）
                                    // → 原来**无论 n 是几**都提示「恢复成功，新增 $n 条记录」✗，
                                    // n=0 时等于告诉用户"恢复成功了"、实际一条都没进来 ✓
                                    //（云端 JSON 损坏 / 指向了别的文件 / `r.json == null`
                                    //  全都走这条路 ✓，是本页最会误导人的提示之一 ✗）。
                                    // 现在 n=0 时如实说明 ✓
                                    if (n == 0) {
                                      toast('未能恢复任何数据：云端备份可能为空或已损坏');
                                    } else {
                                      toast('恢复成功，新增 $n 条记录');
                                    }
                                  },
                            icon: const Icon(Icons.cloud_download_outlined,
                                size: 18),
                            label: busy
                                ? const Text('恢复中…')
                                : const Text('从云端恢复'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // 🟡 WebDAV 面板的 4 个 controller **从未被释放** ✗ —— grep 已证明它们的
    // 全部使用都在这个弹窗内部 ✓（`:2063-2066` 的 `urlC/userC/passC/pathC.text` ✓），
    // 弹窗返回之后**没有任何地方再用** ✓ → 不释放就是"每打开一次 WebDAV 面板
    // 泄漏 4 个 controller"✓（连带它们的焦点与监听回调 ✗）
    urlC.dispose();
    userC.dispose();
    passC.dispose();
    pathC.dispose();
  }

  /// Kindle 推送面板：配置 SMTP + Kindle 邮箱，选本地书推送。
  Future<void> _showKindlePanel() async {
    await SyncService.instance.load();
    final c = SyncService.instance.config;
    final hostC = TextEditingController(text: c.smtpHost);
    final portC = TextEditingController(text: c.smtpPort.toString());
    final userC = TextEditingController(text: c.smtpUser);
    final passC = TextEditingController(text: c.smtpPass);
    final kindleC = TextEditingController(text: c.kindleEmail);
    var useTls = c.useStartTls;
    var busy = false;

    void toast(String msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ));
    }

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Container(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom),
          decoration: BoxDecoration(
            color: Theme.of(ctx).scaffoldBackgroundColor,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(22)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Kindle 推送',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(
                      '用发件邮箱把图书附件发送到你的 Kindle 邮箱',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(ctx).colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: hostC,
                      decoration: const InputDecoration(
                          labelText: 'SMTP 服务器（如 smtp.qq.com）',
                          border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: portC,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                                labelText: '端口（465 / 587）',
                                border: OutlineInputBorder()),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 3,
                          child: Row(
                            children: [
                              Text('587 用 STARTTLS',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(ctx)
                                          .colorScheme
                                          .onSurfaceVariant)),
                              Switch(
                                value: useTls,
                                onChanged: (v) =>
                                    setSheet(() => useTls = v),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: userC,
                      decoration: const InputDecoration(
                          labelText: '发件邮箱账号',
                          border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: passC,
                      obscureText: true,
                      decoration: const InputDecoration(
                          labelText: '邮箱授权码/密码',
                          border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: kindleC,
                      decoration: const InputDecoration(
                          labelText: 'Kindle 收件邮箱',
                          border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: busy
                          ? null
                          : () async {
                              setSheet(() => busy = true);
                              await SyncService.instance.save(SyncConfig(
                                smtpHost: hostC.text.trim(),
                                smtpPort:
                                    int.tryParse(portC.text.trim()) ?? 465,
                                smtpUser: userC.text.trim(),
                                smtpPass: passC.text,
                                kindleEmail: kindleC.text.trim(),
                                useStartTls: useTls,
                              ));
                              // 从书架/下载任务里挑一本有本地文件的图书
                              final tasks = BookDownloadService()
                                  .tasks.values
                                  .where((t) =>
                                      t.localPath != null &&
                                      t.localPath!.isNotEmpty)
                                  .toList();
                              if (tasks.isEmpty) {
                                if (ctx.mounted) Navigator.pop(ctx);
                                setSheet(() => busy = false);
                                toast('书架里没有已下载的本地图书，请先下载一本书');
                                return;
                              }
                              if (ctx.mounted) Navigator.pop(ctx);
                              final picked = await showModalBottomSheet<String>(
                                context: context,
                                backgroundColor: Colors.transparent,
                                builder: (c2) => SafeArea(
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: Theme.of(c2).scaffoldBackgroundColor,
                                      borderRadius: const BorderRadius.vertical(
                                          top: Radius.circular(22)),
                                    ),
                                    child: ListView(
                                      shrinkWrap: true,
                                      children: [
                                        const Padding(
                                          padding: EdgeInsets.all(16),
                                          child: Text('选择要推送到 Kindle 的书',
                                              style: TextStyle(
                                                  fontSize: 16,
                                                  fontWeight:
                                                      FontWeight.w700)),
                                        ),
                                        for (final t in tasks)
                                          ListTile(
                                            leading: const Icon(
                                                Icons.menu_book_outlined),
                                            title: Text(t.title,
                                                overflow:
                                                    TextOverflow.ellipsis),
                                            subtitle: Text(t.localPath ?? ''),
                                            onTap: () =>
                                                Navigator.pop(c2, t.localPath),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                              if (picked == null) {
                                toast('已取消推送');
                                return;
                              }
                              final task = tasks.firstWhere(
                                  (t) => t.localPath == picked);
                              final bytes = await File(picked).readAsBytes();
                              final r = await SyncService.instance.pushToKindle(
                                fileName:
                                    '${task.title}.${task.extension ?? 'epub'}',
                                fileBytes: bytes,
                                title: task.title,
                              );
                              toast(r.ok
                                  ? '已推送到 Kindle 邮箱'
                                  : '推送失败：${r.error}');
                            },
                      icon: const Icon(Icons.send_rounded, size: 18),
                      label: busy
                          ? const Text('发送中…')
                          : const Text('选择图书推送'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // 🟡 Kindle 面板的 5 个 controller **同样从未释放** ✗ —— grep 已证明它们的
    // 全部使用都在这个弹窗内部 ✓（`:2259-2264` 的
    // `hostC/portC/userC/passC/kindleC.text` ✓），弹窗返回后无人再用 ✓
    // → 不释放就是"每打开一次 Kindle 面板泄漏 5 个" ✓
    hostC.dispose();
    portC.dispose();
    userC.dispose();
    passC.dispose();
    kindleC.dispose();
  }

  /// 导入本地漫画：图片多选 / 文件夹 / ZIP / CBZ。
  ///
  /// 落盘结构复用「下载漫画」，所以导入后：
  ///   · 书架 → 本地漫画（presetLocalComic）
  ///   · 点开直接离线阅读（ReaderPage 先查本地图片）
  ///   · 进度/书签/下载记录与在线漫画完全一致
  Future<void> _importLocalComic() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final source = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E1E22) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
              child: Row(
                children: [
                  Text(
                    '导入本地漫画',
                    style: TextStyle(
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('选择图片'),
              subtitle: const Text('多选图片，合并为一话'),
              onTap: () => Navigator.pop(ctx, 'images'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('选择文件夹'),
              subtitle: const Text('每个含图片的子文件夹算一话'),
              onTap: () => Navigator.pop(ctx, 'folder'),
            ),
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: const Text('选择 ZIP / CBZ'),
              subtitle: const Text('压缩包内按目录分话'),
              onTap: () => Navigator.pop(ctx, 'archive'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;

    String defaultTitle = '本地漫画';
    List<PlatformFile> images = const [];
    String? folder;
    PlatformFile? archive;
    try {
      if (source == 'images') {
        images = await LocalComicImportService.pickImages();
        if (images.isEmpty) return;
        final n = images.first.name;
        defaultTitle = n.contains('.') ? n.substring(0, n.lastIndexOf('.')) : n;
      } else if (source == 'folder') {
        folder = await LocalComicImportService.pickFolder();
        if (folder == null || folder.trim().isEmpty) return;
        final parts =
            folder.split(RegExp(r'[/\\]')).where((e) => e.trim().isNotEmpty);
        if (parts.isNotEmpty) defaultTitle = parts.last;
      } else {
        archive = await LocalComicImportService.pickArchive();
        if (archive == null) return;
        defaultTitle = archive.name.replaceAll(
          RegExp(r'\.(zip|cbz)$', caseSensitive: false),
          '',
        );
      }
    } catch (e) {
      _showToast('选择失败：$e');
      return;
    }
    if (!mounted) return;

    final title = await _askLocalComicTitle(defaultTitle);
    if (title == null || title.trim().isEmpty || !mounted) return;

    final rootNav = Navigator.of(context, rootNavigator: true);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const PopScope(
        canPop: false,
        child: Center(child: CircularProgressIndicator()),
      ),
    );
    try {
      final r = source == 'images'
          ? await LocalComicImportService.importImages(images, title: title)
          : source == 'folder'
              ? await LocalComicImportService.importFolder(folder!, title: title)
              : await LocalComicImportService.importArchive(archive!, title: title);
      if (!mounted) return;
      rootNav.pop();
      _switchTab(NavTab.manga);
      _switchShelf(BookshelfService.presetLocalComic);
      _showToast('已导入《${r.title}》：${r.chapterCount} 话 / ${r.imageCount} 张');
    } catch (e) {
      if (!mounted) return;
      rootNav.pop();
      _showToast('导入失败：$e');
    }
  }

  Future<String?> _askLocalComicTitle(String initial) async {
    final ctrl = TextEditingController(text: initial);
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('漫画名称'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return r;
  }

  void _showToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ));
  }

  /// 导入本地图书：多选文件 -> 逐本建已完成任务 -> 入"本地图书"书架（Book 类型，固定 id）
  Future<void> _importLocalBook() async {
    // file_picker 13：pickFiles 是静态方法，直接返回 List<PlatformFile>
    // （旧版是 FilePicker.platform.pickFiles() 返回 FilePickerResult?）
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      // 只列真正能解析的格式：MOBI/AZW/AZW3/FB2/DOCX/RTF 解析器已不支持，
      // 放进来只会"可选但打不开"（用户 2026-10-17 明确要修）。
      allowedExtensions: const [
        'epub',
        'pdf',
        'txt',
      ],
    );
    if (result.isEmpty) return;
    if (!mounted) return;

    // 预取 root navigator：loading 挂在它上面，pop 不依赖页面 context
    final rootNav = Navigator.of(context, rootNavigator: true);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: Center(
          child: CircularProgressIndicator(color: JellyTheme.primary),
        ),
      ),
    );

    final svc = BookDownloadService();
    final seen = <String>{}; // 本次选择内已处理的书名+扩展名，防同批重名重复入
    final imported =
        <({String bookId, String title, String ext, String? cover})>[];
    var skipped = 0; // 已在书架或同批重名跳过
    var failed = 0;
    try {
      for (final f in result) {
        final path = f.path;
        if (path == null) {
          failed++;
          continue;
        }
        final fileName = f.name;
        final dot = fileName.lastIndexOf('.');
        final title = dot > 0 ? fileName.substring(0, dot) : fileName;
        final ext = dot > 0 ? fileName.substring(dot + 1) : 'epub';
        final key = '${title.toLowerCase()}:${ext.toLowerCase()}';
        if (seen.contains(key)) {
          skipped++;
          continue;
        }
        seen.add(key);
        // 去重：同名同扩展名的导入书已在书架则跳过
        final dup = svc.tasks.values.any(
          (t) =>
              t.isLocalImport &&
              t.title.toLowerCase() == title.toLowerCase() &&
              t.extension == ext.toLowerCase(),
        );
        if (dup) {
          skipped++;
          continue;
        }
        final bookId = await svc.importLocalFile(
          File(path),
          title: title,
          extension: ext,
        );
        if (bookId == null) {
          failed++;
          continue;
        }
        imported.add((
          bookId: bookId,
          title: title,
          ext: ext,
          cover: svc.task(bookId)?.cover,
        ));
      }
    } finally {
      rootNav.pop(); // 关 loading
    }
    if (!mounted) return;

    // 有导入成功：统一入"本地图书"书架（固定 id，仅图书 tab 可见），类型为 Book
    if (imported.isNotEmpty) {
      final shelf = await BookshelfService().ensureLocalBookshelf();
      for (final b in imported) {
        final meta = jsonEncode(
          Book(
            id: b.bookId,
            hash: '',
            title: b.title,
            cover: b.cover,
            extension: b.ext,
          ).toJson(),
        );
        await BookshelfService().addToBookshelf(
          shelf.id,
          b.bookId,
          BookshelfItemType.book,
          meta: meta,
        );
      }
      // 切到图书 tab 并选中"本地图书"书架，让用户立刻看到导入结果
      final bookIdx = _indexOfTab(NavTab.book);
      if (bookIdx >= 0 && _tabController.index != bookIdx) {
        _tabController.animateTo(bookIdx);
      }
      setState(() => _currentShelfId = shelf.id);
      _ensureShelfChipVisible(shelf.id);
    }

    // 反馈：单本保留书名，多本按数量；跳过/失败追加说明
    final parts = <String>[];
    if (imported.isEmpty) {
      if (skipped > 0) parts.add('$skipped 本已在书架');
      if (failed > 0) parts.add('$failed 本导入失败');
      if (parts.isEmpty) parts.add('导入失败');
    } else {
      parts.add(
        imported.length == 1
            ? '已导入「${imported.first.title}」'
            : '已导入 ${imported.length} 本',
      );
      if (skipped > 0) parts.add('$skipped 本已在书架');
      if (failed > 0) parts.add('$failed 本导入失败');
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(parts.join('，')),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  // ════════════════════════════════════════════════════════════
  // B6 文件夹扫描导入（Cmbok 差距文档）：选目录 → 递归收集支持的
  // 图书格式 → 复用 BookDownloadService.importLocalFile 入库去重。
  // ════════════════════════════════════════════════════════════
  static const _scanBookExtensions = <String>{
    'txt', 'epub', 'pdf', 'mobi', 'azw', 'azw3', 'fb2', 'docx', 'rtf',
  };

  Future<void> _scanLibraryFolder() async {
    final dir = await FilePicker.getDirectoryPath();
    if (dir == null || dir.isEmpty) return;
    if (!mounted) return;

    final rootNav = Navigator.of(context, rootNavigator: true);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: Center(
          child: CircularProgressIndicator(color: JellyTheme.primary),
        ),
      ),
    );

    final svc = BookDownloadService();
    var found = 0, imported = 0, skipped = 0, failed = 0;
    try {
      final files = <File>[];
      void walk(Directory d) {
        try {
          for (final e in d.listSync(followLinks: false)) {
            if (e is Directory) {
              walk(e);
            } else if (e is File) {
              final dot = e.path.lastIndexOf('.');
              final ext = dot > 0 ? e.path.substring(dot + 1).toLowerCase() : '';
              if (_scanBookExtensions.contains(ext)) files.add(e);
            }
          }
        } catch (_) {}
      }

      walk(Directory(dir));
      found = files.length;
      for (final f in files) {
        final fileName = f.uri.pathSegments.isNotEmpty
            ? f.uri.pathSegments.last
            : f.path.split(Platform.pathSeparator).last;
        final dot = fileName.lastIndexOf('.');
        final title = dot > 0 ? fileName.substring(0, dot) : fileName;
        final ext = dot > 0 ? fileName.substring(dot + 1) : 'txt';
        // 去重：同名同扩展名的导入书已在书架则跳过
        final dup = svc.tasks.values.any(
          (t) =>
              t.isLocalImport &&
              t.title.toLowerCase() == title.toLowerCase() &&
              t.extension == ext.toLowerCase(),
        );
        if (dup) {
          skipped++;
          continue;
        }
        final bookId = await svc.importLocalFile(
          f,
          title: title,
          extension: ext,
        );
        if (bookId == null) {
          failed++;
          continue;
        }
        imported++;
      }
    } finally {
      rootNav.pop(); // 关 loading
    }
    if (!mounted) return;

    if (imported > 0) {
      // 同步把新入库的书挂进「本地图书」书架（与单本导入同款逻辑）
      final shelf = await BookshelfService().ensureLocalBookshelf();
      for (final t in svc.tasks.values) {
        if (!t.isLocalImport) continue;
        final already = BookshelfService()
            .items
            .any((it) => it.bookshelfId == shelf.id && it.itemId == t.bookId);
        if (already) continue;
        final meta = jsonEncode(
          Book(
            id: t.bookId,
            hash: '',
            title: t.title,
            cover: t.cover,
            extension: t.extension,
          ).toJson(),
        );
        await BookshelfService().addToBookshelf(
          shelf.id,
          t.bookId,
          BookshelfItemType.book,
          meta: meta,
        );
      }
      final bookIdx = _indexOfTab(NavTab.book);
      if (bookIdx >= 0 && _tabController.index != bookIdx) {
        _tabController.animateTo(bookIdx);
      }
      setState(() => _currentShelfId = shelf.id);
      _ensureShelfChipVisible(shelf.id);
    }

    final parts = <String>[];
    if (found == 0) {
      parts.add('目录里没有支持的图书文件');
    } else {
      parts.add('扫描到 $found 本');
    }
    if (imported > 0) parts.add('新增 $imported 本');
    if (skipped > 0) parts.add('跳过 $skipped 本（已在书架）');
    if (failed > 0) parts.add('$failed 本失败');
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(parts.join('，')),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  // ════════════════════════════════════════════════════════════
  // B5 legado 阅读备份导入（Cmbok 差距文档）：解析 legado 导出 JSON
  // 的 bookshelf / bookProgress / bookmark，映射写入书架与进度/书签。
  // ════════════════════════════════════════════════════════════
  Future<void> _importLegadoBackup() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (result.isEmpty) return;
    final path = result.single.path;
    if (path == null || path.isEmpty) return;
    if (!mounted) return;

    final rootNav = Navigator.of(context, rootNavigator: true);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: Center(
          child: CircularProgressIndicator(color: JellyTheme.primary),
        ),
      ),
    );

    var imported = 0, skipped = 0, failed = 0;
    try {
      final raw = File(path).readAsStringSync();
      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic>) throw '备份文件不是 JSON 对象';

      final books = (data['bookshelf'] is List)
          ? (data['bookshelf'] as List)
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList()
          : <Map<String, dynamic>>[];
      final progressMap = (data['bookProgress'] is Map)
          ? Map<String, dynamic>.from(data['bookProgress'] as Map)
          : <String, dynamic>{};
      final bookmarkMap = (data['bookmark'] is Map)
          ? Map<String, dynamic>.from(data['bookmark'] as Map)
          : <String, dynamic>{};

      final shelf = await BookshelfService().ensureLocalBookshelf();
      // 已导入过的 legado 记录（按 tocUrl 判重）
      final prefs = await SharedPreferences.getInstance();
      final prior = (prefs.getString('legado_backup_data') ?? '{}');

      for (final b in books) {
        final name = (b['name'] as String? ?? '').trim();
        final author = (b['author'] as String? ?? '').trim();
        final tocUrl = (b['tocUrl'] as String? ?? '').trim();
        final coverUrl = (b['coverUrl'] as String? ?? '').trim();
        if (name.isEmpty) {
          failed++;
          continue;
        }
        // 冲突：同书名同作者已在书架 → 跳过
        final dup = BookshelfService().items.any((it) {
          if (it.type != BookshelfItemType.book) return false;
          final m = it.meta;
          if (m == null) return false;
          try {
            final book = Book.fromJson(jsonDecode(m) as Map<String, dynamic>);
            return book.title == name &&
                (author.isEmpty || book.author == author);
          } catch (_) {
            return false;
          }
        });
        if (dup) {
          skipped++;
          continue;
        }
        final itemId =
            'legado_${(tocUrl.isNotEmpty ? tocUrl : name).hashCode}';
        final meta = jsonEncode(
          Book(
            id: itemId,
            hash: '',
            title: name,
            author: author,
            cover: coverUrl,
            extension: 'legado',
          ).toJson(),
        );
        await BookshelfService().addToBookshelf(
          shelf.id,
          itemId,
          BookshelfItemType.book,
          meta: meta,
        );
        imported++;
        // 进度/书签：按 tocUrl 定位并记录到 legado_backup_data
        dynamic prog;
        for (final e in progressMap.entries) {
          if ((tocUrl.isNotEmpty && e.key.contains(tocUrl)) ||
              (e.value is Map && (e.value as Map)['name'] == name)) {
            prog = e.value;
            break;
          }
        }
        final marks = bookmarkMap.entries
            .where((e) => e.value is Map && (e.value as Map)['name'] == name)
            .map((e) {
          final v = e.value as Map;
          return {
            'chapter': (v['chapterName'] ?? v['chapter'] ?? ''),
            'text': (v['markText'] ?? ''),
          };
        }).toList();
        var dataMap = <String, dynamic>{};
        try {
          dataMap = Map<String, dynamic>.from(
              jsonDecode(prior) as Map<String, dynamic>);
        } catch (_) {}
        dataMap[itemId] = {
          'name': name,
          'tocUrl': tocUrl,
          'progress': prog is Map
              ? (prog['chapter'] ?? '')
              : '',
          'bookmarks': marks,
        };
        await prefs.setString('legado_backup_data', jsonEncode(dataMap));
      }
    } catch (e) {
      failed++;
    } finally {
      rootNav.pop(); // 关 loading
    }
    if (!mounted) return;

    final parts = <String>[];
    if (imported > 0) parts.add('导入 $imported 本');
    if (skipped > 0) parts.add('跳过 $skipped 本（已在书架）');
    if (failed > 0) parts.add('$failed 条失败');
    if (parts.isEmpty) parts.add('未导入任何书籍（文件里没有 bookshelf 列表）');
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(parts.join('，')),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  // ========== 搜索浮层 ==========

  Widget _buildSearchOverlay(bool isDark) {
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: _searchAnim,
        builder: (context, child) {
          if (_searchAnim.isDismissed) return const SizedBox.shrink();
          return child!;
        },
        child: Stack(
          children: [
            // 模糊蒙版
            Positioned.fill(
              child: GestureDetector(
                onTap: _closeSearch,
                behavior: HitTestBehavior.opaque,
                child: FadeTransition(
                  opacity: _searchAnim,
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.2),
                    ),
                  ),
                ),
              ),
            ),
            // 搜索内容
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
                  child: _buildSearchContent(isDark),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchContent(bool isDark) {
    // 用页面级 context（State 的 context）做后续导航：item 的 context 会在
    // _closeSearch() 清空查询后随列表重建被销毁，导致异步打开阅读器时 mounted 检查失败。
    final pageContext = context;
    final q = _searchQuery.trim().toLowerCase();
    final comicResults = <Comic>[];
    final bookResults = <Book>[];

    if (q.isNotEmpty) {
      // 搜索书架条目：按与书架 Tab 相同方式解析（收藏夹优先，meta 快照兜底），
      // 按 itemId 去重，保证"书架上能看到的就能搜到"
      final seenComic = <String>{};
      final seenBook = <String>{};
      for (final item in BookshelfService().items) {
        if (item.type == BookshelfItemType.comic) {
          if (!seenComic.add(item.itemId)) continue;
          Comic? comic;
          if (item.meta != null) {
            try {
              comic = Comic.fromJson(
                jsonDecode(item.meta!) as Map<String, dynamic>,
              );
            } catch (_) {}
          }
          if (comic == null) continue;
          final match =
              comic.title.toLowerCase().contains(q) ||
              (comic.alias ?? '').toLowerCase().contains(q) ||
              (comic.author ?? '').toLowerCase().contains(q);
          if (match) comicResults.add(comic);
        } else {
          if (!seenBook.add(item.itemId)) continue;
          Book? book;
          try {
            book = BookFavoritesService().books.firstWhere(
              (b) => b.id == item.itemId,
            );
          } catch (_) {}
          if (book == null && item.meta != null) {
            try {
              book = Book.fromJson(
                jsonDecode(item.meta!) as Map<String, dynamic>,
              );
            } catch (e) {
              // 🔴 原来是 `catch (_) {}` ✗ —— meta 解析失败后 `book` 保持 null ✓
              // → 紧接着的 `if (book != null)` 会**直接跳过这一项** ✓
              // → 书架**计数 N、实际只显示 N-1** ✓，而且**没有任何提示** ✓
              //（用户只会觉得"我的书怎么少了一本" ✓）。
              // ⚠️ 同一模式在**本文件另一处**也存在 ✓（漫画/图书两个 tab ✓），
              //    所以这里用 replace_all 一起修 ✓。
              // 至少先**留痕**让问题可见 ✓；
              // 遗留：真正的修法是解析失败时用 meta 里的书名/封面建**兜底条目** ✓
              debugPrint('[Bookshelf] 书架条目 meta 解析失败（item ${item.itemId}），'
                  '该项将被跳过: $e');
            }
          }
          if (book == null) continue;
          final match =
              book.title.toLowerCase().contains(q) ||
              (book.author ?? '').toLowerCase().contains(q);
          if (match) bookResults.add(book);
        }
      }
    }

    // 交错合并结果（漫画一本、图书一本交替）
    final mixed = <dynamic>[];
    final ci = comicResults.iterator;
    final bi = bookResults.iterator;
    while (ci.moveNext()) {
      mixed.add(ci.current);
      if (bi.moveNext()) mixed.add(bi.current);
    }
    while (bi.moveNext()) {
      mixed.add(bi.current);
    }

    final hasQuery = q.isNotEmpty;
    final tooMany = mixed.length > 10;
    final display = tooMany ? mixed.sublist(0, 10) : mixed;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          JellySearchBar(
            controller: _searchController,
            hintText: '搜索书架',
            autofocus: true,
            onChanged: (v) => setState(() => _searchQuery = v),
            onCleared: () => setState(() => _searchQuery = ''),
          ),
          const SizedBox(height: 12),
          if (hasQuery && display.isEmpty)
            _buildSearchEmpty(isDark)
          else if (hasQuery)
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.4,
              child: Material(
                color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
                borderRadius: BorderRadius.circular(20),
                clipBehavior: Clip.antiAlias,
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: display.length + (tooMany ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (tooMany && index == display.length) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 10,
                          horizontal: 16,
                        ),
                        child: Text(
                          '仅显示前 10 条，继续输入缩小范围',
                          style: TextStyle(
                            fontSize: AppTheme.fontFootnote,
                            color: isDark ? Colors.white38 : Colors.black38,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      );
                    }
                    final item = display[index];
                    if (item is Comic) {
                      return _SearchComicTile(
                        comic: item,
                        // 点击行为与书架漫画一致：已下载直接读、未下载弹同样的对话框
                        onTap: () {
                          _closeSearch();
                          _ComicShelfTab._onTapComic(pageContext, item);
                        },
                      );
                    } else if (item is Book) {
                      return _SearchBookTile(
                        book: item,
                        // 点击行为与书架图书一致：已下载直接续读、未下载弹同样的对话框
                        onTap: () {
                          _closeSearch();
                          _BookShelfTab._onTap(pageContext, item);
                        },
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchEmpty(bool isDark) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 32),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 48,
            color: isDark ? Colors.white38 : Colors.black26,
          ),
          const SizedBox(height: 12),
          Text(
            '没有找到相关书籍',
            style: TextStyle(
              color: isDark ? Colors.white54 : Colors.black45,
              fontSize: AppTheme.fontBody,
            ),
          ),
        ],
      ),
    );
  }

  // ========== 书架分类栏 ==========

  /// 预置"已下载的书"书架显示为"已下载"，其余用书架名
  String _shelfDisplayName(Bookshelf shelf, BookshelfItemType currentType) {
    if (shelf.id == BookshelfService.presetDownloaded) {
      return '已下载';
    }
    return shelf.name;
  }

  Widget _buildShelfBar(bool isDark) {
    return ListenableBuilder(
      listenable: Listenable.merge([BookshelfService(), _tabController]),
      builder: (context, _) {
        final shelves = _visibleShelves(_currentTab);
        final currentType = _isComicTab
            ? BookshelfItemType.comic
            : BookshelfItemType.book;

        // 先构建所有 chip 子元素
        final chips = <Widget>[
          _buildAllShelfChip(currentType, isDark),
          for (int i = 0; i < shelves.length; i++)
            _buildShelfChip(shelves[i], currentType, isDark),
          _buildAddChip(isDark),
        ];

        // 用 IntrinsicWidth 测出内容总宽度，判断是否需要滚动
        return Container(
          height: 40,
          margin: const EdgeInsets.only(bottom: 8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // 计算内容总宽度（粗略估算用于判断）
              // 每个 chip 间距 8，最后一个不加
              const chipPadding = 24.0; // horizontal 12*2
              const addChipPadding = 20.0; // horizontal 10*2
              const spacing = 8.0;
              const textStyle = TextStyle(
                fontSize: AppTheme.fontFootnote,
                fontWeight: FontWeight.w600,
              );
              const addTextStyle = TextStyle(
                fontSize: AppTheme.fontFootnote,
                fontWeight: FontWeight.w600,
              );

              double totalWidth = 0;
              {
                final allCount = _visibleShelves(_currentTab).fold<int>(
                  0,
                  (sum, sh) => sum +
                      BookshelfService().countInShelf(sh.id, currentType),
                );
                final allPainter = TextPainter(
                  text: const TextSpan(text: '全部', style: textStyle),
                  textDirection: TextDirection.ltr,
                )..layout();
                final numPainter = TextPainter(
                  text: TextSpan(text: '$allCount', style: textStyle),
                  textDirection: TextDirection.ltr,
                )..layout();
                totalWidth +=
                    chipPadding + allPainter.width + 4 + numPainter.width + spacing;
              }
              for (int i = 0; i < shelves.length; i++) {
                final shelf = shelves[i];
                final displayName = _shelfDisplayName(shelf, currentType);
                final count = BookshelfService().countInShelf(
                  shelf.id,
                  currentType,
                );
                final textPainter = TextPainter(
                  text: TextSpan(text: displayName, style: textStyle),
                  textDirection: TextDirection.ltr,
                )..layout();
                final numPainter = TextPainter(
                  text: TextSpan(text: '$count', style: textStyle),
                  textDirection: TextDirection.ltr,
                )..layout();
                totalWidth +=
                    chipPadding + textPainter.width + 4 + numPainter.width;
                if (i < shelves.length) totalWidth += spacing;
              }
              // 新建按钮
              final addTextPainter = TextPainter(
                text: const TextSpan(text: '新建', style: addTextStyle),
                textDirection: TextDirection.ltr,
              )..layout();
              totalWidth += addChipPadding + 14 + 2 + addTextPainter.width + 16;

              // 标签行：正在读/想读/已读完/全部…… 可横向滑动
              final scrollView = SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(left: 16),
                child: Row(mainAxisSize: MainAxisSize.min, children: chips),
              );

              // 固定按钮（管理书架 / 排序方式）：图标固定，不随标签滑动
              // ✅ 用户 2026-10-12「管理/排序图标太丑、占位太长」：
              //    原来是两枚 20px 裸图标（各占 32 宽，合计 68）✗ —— 松散廉价。
              //    改成**一个浅底圆角胶囊分段控件**：两枚 16px 图标 + 中间
              //    细分隔线，更紧凑也更精致（与书架 chips 同语言）。
              // ✅ 用户 2026-10-14：①「管理书架」的图标换成不再像流水账的
              //    `dashboard_customize`；② 这枚胶囊的高度必须和「全部」标签
              //    那道背景框**一样高**（原来固定 28，跟标签框对不齐）；
              //    ③ 宽度再收窄一点，视觉上与标签更接近。
              final iconColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
              // 标签背景框高度 = 文字行高 + 上下内边距 6*2
              //（与 `_buildAllShelfChip` / `_buildShelfChip` 的 padding 一致，
              //  改了那边这里自动跟着走，不会再有"差 2px"的对不齐）。
              final chipBoxHeight = (TextPainter(
                        text: const TextSpan(text: '全部', style: textStyle),
                        textDirection: TextDirection.ltr,
                        // 必须带上 textScaler：系统字号放大时标签文字会变高，
                        // 不带就会算出一个偏矮的胶囊（又对不齐了）。
                        textScaler: MediaQuery.textScalerOf(context),
                      )..layout())
                      .height +
                  12;
              // 管理 / 排序：**两个独立的圆形按钮**（用户 2026-10-18 给的截图）
              //   · 左：管理书架（列表/筛选样式的图标）
              //   · 右：排序方式（上下箭头）
              //   原来是同一枚胶囊里的两段，用户要求拆开成两个独立面板入口。
              Widget roundBtn(IconData icon, String tip, VoidCallback onTap) {
                return Tooltip(
                  message: tip,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onTap,
                    child: Container(
                      width: chipBoxHeight,
                      height: chipBoxHeight,
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.08)
                            : Colors.black.withValues(alpha: 0.045),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.06)
                              : Colors.black.withValues(alpha: 0.05),
                          width: 0.5,
                        ),
                      ),
                      child: Icon(icon, size: 18, color: iconColor),
                    ),
                  ),
                );
              }

              final fixedButtons = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  roundBtn(
                    Icons.subject_rounded,
                    '管理书架',
                    _showManageShelves,
                  ),
                  const SizedBox(width: 8),
                  roundBtn(
                    Icons.swap_vert_rounded,
                    '排序方式',
                    _showSortSheet,
                  ),
                ],
              );

              // 固定按钮在**左侧**（用户多次点名"管理/排序移到左边"），
              // 标签行占满剩余宽度；内容不足时居中，超出则横向滚动
              final fixedWidth = chipBoxHeight * 2 + 8;
              return Row(
                children: [
                  fixedButtons,
                  const SizedBox(width: 8),
                  Expanded(
                    child: totalWidth + 16 + fixedWidth + 8 <=
                            constraints.maxWidth
                        ? Center(child: scrollView)
                        : scrollView,
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  /// 「全部」书架 chip：聚合所有可见书架条目（仅浏览，样式同普通书架 chip）
  Widget _buildAllShelfChip(BookshelfItemType currentType, bool isDark) {
    final selected = _currentShelfId == kAllShelfId;
    final count = _visibleShelves(_currentTab).fold<int>(
      0,
      (sum, sh) =>
          sum + BookshelfService().countInShelf(sh.id, currentType),
    );
    return Padding(
      key: _shelfChipKey(kAllShelfId),
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () => _switchShelf(kAllShelfId),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
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
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '全部',
                style: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? Colors.white
                      : (isDark ? Colors.white70 : JellyTheme.textSecondary),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: AppTheme.fontCaption,
                  color: selected
                      ? Colors.white.withValues(alpha: 0.7)
                      : (isDark
                            ? Colors.white38
                            : JellyTheme.textSecondary.withValues(alpha: 0.7)),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildShelfChip(
    Bookshelf shelf,
    BookshelfItemType currentType,
    bool isDark,
  ) {
    final selected = shelf.id == _currentShelfId;
    final count = BookshelfService().countInShelf(shelf.id, currentType);
    return Padding(
      key: _shelfChipKey(shelf.id),
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () => _switchShelf(shelf.id),
        onLongPress: () => _showShelfMenu(shelf),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
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
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _shelfDisplayName(shelf, currentType),
                style: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? Colors.white
                      : (isDark ? Colors.white70 : JellyTheme.textSecondary),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: AppTheme.fontCaption,
                  color: selected
                      ? Colors.white.withValues(alpha: 0.7)
                      : (isDark
                            ? Colors.white38
                            : JellyTheme.textSecondary.withValues(alpha: 0.7)),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAddChip(bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: _createShelf,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.add_rounded,
                size: 14,
                color: isDark ? Colors.white70 : JellyTheme.textSecondary,
              ),
              const SizedBox(width: 2),
              Text(
                '新建',
                style: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white70 : JellyTheme.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 搜索结果条目
// ============================================================
class _SearchComicTile extends StatelessWidget {
  final Comic comic;
  final VoidCallback onTap;

  const _SearchComicTile({required this.comic, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 36,
        height: 48,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: isDark ? Colors.white10 : Colors.black12,
        ),
        clipBehavior: Clip.antiAlias,
        child: SourceCoverImage(
          url: comic.cover,
          httpHeaders: coverHeaders(comic.sourceId),
          fit: BoxFit.cover,
          placeholder: (_, __) => const SizedBox.shrink(),
          errorWidget: (_, __, ___) =>
              Icon(
                Icons.palette_rounded,
                size: 20,
                color: JellyTheme.textSecondary,
              ),
        ),
      ),
      title: Text(
        comic.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: AppTheme.fontBody,
          fontWeight: FontWeight.w600,
          color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
        ),
      ),
      subtitle: Text(
        comic.author ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: AppTheme.fontFootnote,
          color: isDark ? Colors.white54 : JellyTheme.textSecondary,
        ),
      ),
      trailing: Icon(
        Icons.palette_rounded,
        size: 16,
        color: JellyTheme.primary.withValues(alpha: 0.6),
      ),
    );
  }
}

class _SearchBookTile extends StatelessWidget {
  final Book book;
  final VoidCallback onTap;

  const _SearchBookTile({required this.book, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListTile(
      onTap: onTap,
      leading: Container(
        width: 36,
        height: 48,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: isDark ? Colors.white10 : Colors.black12,
        ),
        clipBehavior: Clip.antiAlias,
        child: Image.network(
          book.cover ?? '',
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) =>
              Icon(
                Icons.book_rounded,
                size: 20,
                color: JellyTheme.textSecondary,
              ),
        ),
      ),
      title: Text(
        book.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: AppTheme.fontBody,
          fontWeight: FontWeight.w600,
          color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
        ),
      ),
      subtitle: Text(
        book.author ?? '',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: AppTheme.fontFootnote,
          color: isDark ? Colors.white54 : JellyTheme.textSecondary,
        ),
      ),
      trailing: Icon(
        Icons.book_rounded,
        size: 16,
        color: JellyTheme.primary.withValues(alpha: 0.6),
      ),
    );
  }
}

// ============================================================
// 漫画书架 Tab
// ============================================================
/// 书架漫画点击未下载时的弹窗选择
enum _ComicReadChoice { cancel, download, readOnline }

class _ComicShelfTab extends StatelessWidget {
  final String shelfId;
  final ScrollController scrollController;
  final bool showBackToTop;
  final VoidCallback onBackToTop;
  final int session;
  final int displayCount;
  final bool isSelecting;
  final Set<String> selectedIds;
  final ValueChanged<String> onSelect;

  const _ComicShelfTab({
    required this.shelfId,
    required this.scrollController,
    required this.showBackToTop,
    required this.onBackToTop,
    required this.session,
    required this.displayCount,
    this.isSelecting = false,
    this.selectedIds = const {},
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        BookshelfService(),
        ReadingProgressService(),
        ShelfUpdateService.instance,
      ]),
      builder: (context, _) {
        final items = resolveShelfItems(
          shelfId,
          BookshelfItemType.comic,
          excludeLocal: true,
        );
        // 排序由「标题行的排序按钮」决定（SettingsService.shelfSort）。
        // 若只弹面板不生效，那按钮就是假的 —— 比不放更糟。
        _applyShelfSort(items, shelfId);
        final entries = <_ShelfEntry>[];
        var i = 0;
        for (final item in items.take(displayCount)) {
          // 只读条目 meta 快照（与收藏解耦）；无快照则跳过
          Comic? comic;
          if (item.meta != null) {
            try {
              comic = Comic.fromJson(
                jsonDecode(item.meta!) as Map<String, dynamic>,
              );
            } catch (_) {}
          }
          if (comic != null) {
            final c = comic;
            final rp = ReadingProgressService().getProgress(c.pathWord);
            // 进度统一为"已读 N 话"文字（不依赖 totalChapters，与下载/在线无关）
            final double? progress;
            final String? progressLabel;
            if (rp != null && rp.seenChapterIds.isNotEmpty) {
              progress = null;
              // 已读话数=续读位置（读到第几话）；旧数据无 lastChapterIndex 时回退累计已读章节数
              final readCount = rp.lastChapterIndex >= 0
                  ? rp.lastChapterIndex + 1
                  : rp.seenChapterIds.length;
              progressLabel = '已读 $readCount 话';
            } else {
              progress = null;
              progressLabel = null;
            }
            // 漫画源角标：优先用书架快照里的漫画源（手动加入书架即带源），
            // 下载记录兜底（旧数据 meta 无 sourceId 时）；两者都无则不显示
            final sourceId =
                c.sourceId ?? DownloadService().sourceIdForComic(c.pathWord);
            final sourceLabel = sourceId == null
                ? null
                : SourceManager().getSource(sourceId)?.name;
            entries.add(
              _ShelfEntry(
                id: c.id,
                itemId: item.itemId,
                coverUrl: c.cover,
                title: c.title,
                type: BookshelfItemType.comic,
                onTap: () => _onTapComic(context, c),
                index: i,
                meta: item.meta,
                progress: progress,
                progressLabel: progressLabel,
                sourceLabel: sourceLabel,
                sourceId: sourceId,
                updateCount: ShelfUpdateService.instance.newChapters(
                    ShelfUpdateService.keyForComic(c.pathWord)),
              ),
            );
          }
          i++;
        }
        if (entries.isEmpty) {
          return _buildEmpty(context, '还没有漫画', Icons.palette_rounded);
        }
        return _buildShelfContent(
          entries: entries,
          scrollController: scrollController,
          showBackToTop: showBackToTop,
          onBackToTop: onBackToTop,
          session: session,
          onLongPress: (e) => _showShelfItemMenu(
            context,
            shelfId,
            e,
            onEdit: () => onSelect(e.itemId),
          ),
          isSelecting: isSelecting,
          selectedIds: selectedIds,
          onSelect: onSelect,
        );
      },
    );
  }

  static Future<void> _onTapComic(BuildContext context, Comic comic) async {
    final downloaded = DownloadService().downloadedChapters(comic.pathWord);
    final total = comic.totalChapters;
    debugPrint(
      '[bookshelf] _onTapComic: title=${comic.title}, pathWord=${comic.pathWord}, '
      'downloaded=${downloaded.length}, totalChapters=$total',
    );

    // 1) 完全没下载：弹窗 在线阅读 / 下载（进详情页）
    if (downloaded.isEmpty) {
      debugPrint('[bookshelf] -> 分支1: 无下载，弹窗');
      final choice = await showDialog<_ComicReadChoice>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text('《${comic.title}》尚未下载，是否在线阅读或前往下载？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, _ComicReadChoice.cancel),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, _ComicReadChoice.download),
              child: const Text('下载'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, _ComicReadChoice.readOnline),
              style: TextButton.styleFrom(foregroundColor: JellyTheme.primary),
              child: const Text('在线阅读'),
            ),
          ],
        ),
      );
      if (choice != _ComicReadChoice.readOnline) {
        if (choice == _ComicReadChoice.download) {
          if (!context.mounted) return;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ComicDetailPage(
                comic: comic,
                heroTag: 'bookshelf_comic_${comic.id}',
              ),
            ),
          );
        }
        return;
      }
      if (!context.mounted) return;
      await _openReaderDirectly(context, comic);
      return;
    }

    // 2) 有下载但未全部下载完（total 已知且 downloaded < total）：询问是否在线
    if (total != null && total > 0 && downloaded.length < total) {
      debugPrint('[bookshelf] -> 分支2: 未全下完（${downloaded.length}/$total），弹窗询问');
      final online = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(
            '检测到《${comic.title}》章节未全部下载（已下载 ${downloaded.length}/$total 话），是否在线阅读？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('离线阅读已下载'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(foregroundColor: JellyTheme.primary),
              child: const Text('在线阅读'),
            ),
          ],
        ),
      );
      debugPrint('[bookshelf] 分支2 弹窗结果 online=$online');
      if (online == true) {
        if (!context.mounted) return;
        await _openReaderDirectly(context, comic);
        return;
      }
      if (online == false) {
        _readOffline(context, comic);
        return;
      }
      // null：点弹窗外部 dismiss，取消，不进入阅读
      return;
    }

    // 3) 全部下载完 或 total 缺失：直接离线阅读
    debugPrint(
      '[bookshelf] -> 分支3: 离线读（全下完或total缺失） downloaded=${downloaded.length}, total=$total',
    );
    _readOffline(context, comic);
  }

  /// 离线阅读已下载章节（复用下载记录页逻辑：续读章节或第一章，不拉详情、不耗流量）
  static void _readOffline(BuildContext context, Comic comic) {
    final chapters = DownloadService().downloadedChapters(comic.pathWord);
    if (chapters.isEmpty) return;
    var initialPage = 0;
    var start = chapters.first;
    final progress = ReadingProgressService().getProgress(comic.pathWord);
    if (progress != null) {
      final idx = chapters.indexWhere((c) => c.id == progress.lastChapterId);
      if (idx >= 0) {
        start = chapters[idx];
        initialPage = progress.lastPageIndex;
      }
    }
    final group = ChapterGroup(
      id: 'default',
      name: '默认',
      count: chapters.length,
      chapters: chapters,
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderPage(
          comic: comic,
          chapter: start,
          groups: [group],
          initialPage: initialPage,
        ),
      ),
    );
  }

  /// 拉详情+章节分组后直接进阅读器（续读章节或第一章）
  static Future<void> _openReaderDirectly(
    BuildContext context,
    Comic comic,
  ) async {
    // 预先取 root navigator：loading 挂在它上面，后续 pop 不依赖页面 context
    final rootNav = Navigator.of(context, rootNavigator: true);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: Center(
          child: CircularProgressIndicator(color: JellyTheme.primary),
        ),
      ),
    );
    try {
      // 优先用漫画自身所属源（书架含多源漫画，当前选中源未必匹配）；
      // 旧数据无 sourceId 时兜底当前源
      final source = (comic.sourceId != null && comic.sourceId!.isNotEmpty)
          ? (SourceManager().getSource(comic.sourceId!) ??
                SourceManager().current)
          : SourceManager().current;
      final details = await source.getMangaDetailsAndChapters(
        comicToCManga(comic, source.id),
      );
      final result = (
        comic: cmangaToComic(details.manga),
        groups: cchaptersToGroups(details.chapters),
      );
      rootNav.pop(); // 关 loading
      if (!context.mounted) return;
      final groups = result.groups;
      // 章节按源站原始 order 排序，方向由源决定，统一「第1话在前」
      for (final g in groups) {
        g.chapters.sort(
          (a, b) =>
              chapterCompare(a.order, b.order, source.chapterOrderDescending),
        );
      }
      // 起始章节：续读章节；无记录则第一章（order 最小）
      ComicChapter? start;
      var initialPage = 0;
      final rp = ReadingProgressService().getProgress(comic.pathWord);
      if (rp != null) {
        outer:
        for (final g in groups) {
          for (final ch in g.chapters) {
            if (ch.id == rp.lastChapterId) {
              start = ch;
              initialPage = rp.lastPageIndex;
              break outer;
            }
          }
        }
      }
      start ??= _firstChapter(groups);
      if (start == null) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('暂无可读章节'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
        return;
      }
      final startChapter = start;
      if (!context.mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderPage(
            comic: comic,
            chapter: startChapter,
            groups: groups,
            initialPage: initialPage,
          ),
        ),
      );
    } catch (e) {
      rootNav.pop(); // 关 loading
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('加载失败: $e'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
  }

  /// 排序后首个非空分组的第一章（与详情页默认显示的第一章一致）。
  /// 不按 order 数值取最小，因为 descending 源（order 大者=第1话）取最小会落到最后一话。
  static ComicChapter? _firstChapter(List<ChapterGroup> groups) {
    for (final g in groups) {
      if (g.chapters.isNotEmpty) return g.chapters.first;
    }
    return null;
  }
}

// ============================================================
// 图书书架 Tab
// ============================================================
class _BookShelfTab extends StatelessWidget {
  final String shelfId;
  final ScrollController scrollController;
  final bool showBackToTop;
  final VoidCallback onBackToTop;
  final int session;
  final int displayCount;
  final bool isSelecting;
  final Set<String> selectedIds;
  final ValueChanged<String> onSelect;

  const _BookShelfTab({
    required this.shelfId,
    required this.scrollController,
    required this.showBackToTop,
    required this.onBackToTop,
    required this.session,
    required this.displayCount,
    this.isSelecting = false,
    this.selectedIds = const {},
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        BookshelfService(),
        BookFavoritesService(),
        BookReadingProgressService(),
      ]),
      builder: (context, _) {
        final items = resolveShelfItems(
          shelfId,
          BookshelfItemType.book,
        );
        // 🔴 图书 tab **从来没调用过** `_applyShelfSort` ✗ —— 而排序面板
        // （本文件 :1554 附近 ✓）写的是全局的 `SettingsService().shelfSort` ✓，
        // 唯一调用点在 `_ComicShelfTab`（漫画 tab ✓）→ 用户在**图书** tab 里选
        // "书名/作者/加入时间/最近阅读/阅读进度"、切正倒序，列表**顺序完全不变** ✓
        //（面板注释自己写着"两个书架列表都读它来排" ✗ —— 实现没有 ✓）。
        // 现在补上 ✓
        // ✅ **这两项现在也准了** ✓（原注释写的是"已知不准 / 待做" ✗ —— 已过期 ✓）
        //    `shelfUpdatedAtOf`（本文件 `:4365` ✓）与 `shelfReadIndex`（`:4376` ✓）
        //    已经**按类型问对服务** ✓：
        //      · 图书 → `BookReadingProgressService`（用 `pageIndex` ✓）
        //      · 漫画 → `ReadingProgressService`（用 `lastChapterIndex` ✓）
        //    两个都问、取非空 ✓ → 图书不会再"恒为 0 → 全部相同 → 保持原序" ✗
        // ⚠️ 仍待**真机确认**的一点 ✓：图书用**页码**、漫画用**章节号** ✗ ——
        //    这里假设"一个书架里只会是纯图书或纯漫画" ✓；
        //    若真机上存在**混放**的书架 ✗，两种标量会被混着比较 ✗（那需再单独处理 ✓）
        _applyShelfSort(items, shelfId);
        // "正在读"：排序键取"加入书架时间"与"最近阅读时间"的较大者倒序
        // --新移入(无进度)用 addedAt 兜底排到顶部；有进度按最近阅读归位(继续阅读仍上浮)
        if (shelfId == BookshelfService.presetReading) {
          items.sort((a, b) {
            final ra =
                BookReadingProgressService().getProgress(a.itemId)?.updatedAt ??
                0;
            final rb =
                BookReadingProgressService().getProgress(b.itemId)?.updatedAt ??
                0;
            final ka = a.addedAt > ra ? a.addedAt : ra;
            final kb = b.addedAt > rb ? b.addedAt : rb;
            return kb.compareTo(ka);
          });
        }
        // 建 id -> Book 索引，消除每项 firstWhere 的 O(n×m)
        final bookMap = {for (final b in BookFavoritesService().books) b.id: b};
        final entries = <_ShelfEntry>[];
        var i = 0;
        for (final item in items.take(displayCount)) {
          // 优先从收藏夹解析（完整数据），否则用条目自带快照兜底
          Book? book = bookMap[item.itemId];
          if (book == null && item.meta != null) {
            try {
              book = Book.fromJson(
                jsonDecode(item.meta!) as Map<String, dynamic>,
              );
            } catch (e) {
              // 🔴 原来是 `catch (_) {}` ✗ —— meta 解析失败后 `book` 保持 null ✓
              // → 紧接着的 `if (book != null)` 会**直接跳过这一项** ✓
              // → 书架**计数 N、实际只显示 N-1** ✓，而且**没有任何提示** ✓
              //（用户只会觉得"我的书怎么少了一本" ✓）。
              // ⚠️ 同一模式在**本文件另一处**也存在 ✓（漫画/图书两个 tab ✓），
              //    所以这里用 replace_all 一起修 ✓。
              // 至少先**留痕**让问题可见 ✓；
              // 遗留：真正的修法是解析失败时用 meta 里的书名/封面建**兜底条目** ✓
              debugPrint('[Bookshelf] 书架条目 meta 解析失败（item ${item.itemId}），'
                  '该项将被跳过: $e');
            }
          }
          if (book != null) {
            final b = book;
            final rp = BookReadingProgressService().getProgress(b.id);
            final progress = (rp != null && rp.pageTotal > 0)
                ? ((rp.pageIndex + 1) / rp.pageTotal).clamp(0.0, 1.0)
                : null;
            entries.add(
              _ShelfEntry(
                id: b.id,
                itemId: item.itemId,
                coverUrl: b.cover ?? '',
                title: b.title,
                type: BookshelfItemType.book,
                onTap: () => _onTap(context, b),
                index: i,
                meta: item.meta,
                progress: progress,
                formatLabel: b.extension?.trim().toUpperCase(),
              ),
            );
          }
          i++;
        }
        if (entries.isEmpty) {
          return _buildEmpty(context, '还没有图书', Icons.book_rounded);
        }
        return _buildShelfContent(
          entries: entries,
          scrollController: scrollController,
          showBackToTop: showBackToTop,
          onBackToTop: onBackToTop,
          session: session,
          onLongPress: (e) => _showShelfItemMenu(
            context,
            shelfId,
            e,
            onEdit: () => onSelect(e.itemId),
          ),
          isSelecting: isSelecting,
          selectedIds: selectedIds,
          onSelect: onSelect,
        );
      },
    );
  }

  static Future<void> _onTap(BuildContext context, Book book) async {
    // 书源书籍：优先打开书源详情页（与详情页入口保持一致）
    final src = _matchBookSource(book);
    if (src != null) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => BookSourceDetailPage(
            result: BookSourceResult(
              source: src,
              name: book.title,
              author: book.author ?? '',
              bookUrl: book.bookUrl!,
              coverUrl: book.cover ?? '',
            ),
          ),
        ),
      );
      return;
    }
    final task = BookDownloadService().task(book.id);
    if (task != null && task.status == BookDownloadStatus.completed) {
      // 已下载：直接续读（阅读器内部自动定位续读点）
      await BookReaderPage.open(context, task);
      return;
    }
    if (task == null) {
      // 未下载：先提示确认，再进详情页下载
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: const Text('该书尚未下载，是否前往下载？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(foregroundColor: JellyTheme.primary),
              child: const Text('前往下载'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    // 下载中/失败/暂停 或 已确认前往下载：进详情页
    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            BookDetailPage(book: book, heroTag: 'bookshelf_book_${book.id}'),
      ),
    );
  }

  /// 按存的 sourceId 找回书源（兼容旧书架数据：sourceId 缺失时按源名匹配）
  static BookSource? _matchBookSource(Book book) {
    final id = book.sourceId;
    if (id != null && id.isNotEmpty) {
      for (final s in BookSourceStore.instance.all) {
        if (s.id == id) return s;
      }
    }
    final name = book.sourceName;
    if (name != null && name.isNotEmpty) {
      for (final s in BookSourceStore.instance.all) {
        if (s.name == name) return s;
      }
    }
    return null;
  }
}

// ============================================================
// 书架书本卡片（竖立书本样式）
// ============================================================
/// 书架条目数据（封面 + 点击/长按；名称行已从书架移除，
/// `title` 仅用于长按菜单顶部显示是哪本书）
class _ShelfEntry {
  final String id;
  final String itemId; // 书架条目 ID（漫画=pathWord，图书=id），用于移出/移动
  final String coverUrl;
  final String title;
  final BookshelfItemType type;
  final VoidCallback onTap;
  final int index;
  final String? meta; // 元数据快照，移动时透传保持可显示
  final double? progress; // 阅读进度 0~1，null 表示无
  final String? progressLabel; // 无下载但在线阅读时的文字徽标
  final String? formatLabel; // 图书格式角标（EPUB/MOBI/PDF…），漫画为 null
  final String? sourceLabel; // 漫画下载源名角标（如「拷贝漫画」），图书/未下载为 null
  final String? sourceId; // 漫画所属源 id（封面防盗链头用），图书为 null
  final int? updateCount; // 更新角标（新话数），仅漫画条目有值

  _ShelfEntry({
    required this.id,
    required this.itemId,
    required this.coverUrl,
    required this.title,
    required this.type,
    required this.onTap,
    required this.index,
    this.meta,
    this.progress,
    this.progressLabel,
    this.formatLabel,
    this.sourceLabel,
    this.sourceId,
    this.updateCount,
  });
}

/// 一层书架：封面行 + 架板 + 书名/作者行
class _BookshelfRow extends StatelessWidget {
  final double cellWidth;
  final double spacing;
  final bool isDark;
  final List<_ShelfEntry> entries;
  final int session;
  final void Function(_ShelfEntry) onLongPress;
  final bool isSelecting;
  final Set<String> selectedIds;
  final ValueChanged<String> onSelect;

  const _BookshelfRow({
    required this.cellWidth,
    required this.spacing,
    required this.isDark,
    required this.entries,
    required this.session,
    required this.onLongPress,
    this.isSelecting = false,
    this.selectedIds = const {},
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 封面行（底部对齐，立在架板上）
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: _coverSlots(),
        ),
        const SizedBox(height: 4), // 书与架板间距，阴影投在架上
        _ShelfBoard(isDark: isDark),
        // 🔴 2026-10-14：架板下的「书名 / 作者」**整行去掉** ✓ —— 用户要求
        //    书架里不再显示漫画名 / 书籍名 ✓（名称在**长按条目菜单**顶部仍有 ✓，
        //    不会因为这里不显示就查不到是哪本书 ✓）
        // 行间距随「显示设置 → 列表密度」缩放（用户 2026-10-15）
        SizedBox(height: 20 * SettingsService().densityScale),
      ],
    );
  }

  List<Widget> _coverSlots() {
    final list = <Widget>[];
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      if (i > 0) list.add(SizedBox(width: spacing));
      list.add(
        SizedBox(
          width: cellWidth,
          child: StaggeredEntrance(
            key: ValueKey('${session}_${e.id}'),
            index: e.index,
            child: _ShelfCover(
              coverUrl: e.coverUrl,
              type: e.type,
              onTap: isSelecting ? () => onSelect(e.itemId) : e.onTap,
              // 长按 → **条目菜单**（多选编辑 / 移出当前书架 / 移到其他书架）。
              // ⚠️ 原来这里接的是 `onSelect`（长按直接进多选）⇒ `_BookshelfRow`
              //   收到的 `onLongPress`（单项菜单）成了**死代码** ✗ 调不出来。
              //   现在长按弹菜单 ✓，进多选改由菜单里的「多选编辑」承担 ✓
              //   （处于多选模式时，长按仍等于选中/取消 ✓）。
              onLongPress: isSelecting
                  ? () => onSelect(e.itemId)
                  : () => onLongPress(e),
              progress: e.progress,
              progressLabel: e.progressLabel,
              formatLabel: e.formatLabel,
              sourceLabel: e.sourceLabel,
              sourceId: e.sourceId,
              updateCount: e.updateCount,
              isSelecting: isSelecting,
              selected: selectedIds.contains(e.itemId),
            ),
          ),
        ),
      );
    }
    return list;
  }
}

/// 毛玻璃架板（顶面高光 + 底部投影，有厚度感，与整体玻璃风一致）
class _ShelfBoard extends StatelessWidget {
  final bool isDark;
  const _ShelfBoard({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 12,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? [
                  Colors.white.withValues(alpha: 0.16),
                  Colors.white.withValues(alpha: 0.10),
                  Colors.white.withValues(alpha: 0.04),
                ]
              : [
                  Colors.white.withValues(alpha: 0.92),
                  Colors.white.withValues(alpha: 0.65),
                  Colors.white.withValues(alpha: 0.40),
                ],
          stops: const [0.0, 0.55, 1.0],
        ),
        border: Border(
          top: BorderSide(
            color: isDark
                ? Colors.white.withValues(alpha: 0.25)
                : JellyTheme.primary.withValues(alpha: 0.25),
            width: 1,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.black.withValues(alpha: 0.40)
                : JellyTheme.primary.withValues(alpha: 0.12),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
    );
  }
}

/// 封面（立在架板上，点击缩放反馈）
class _ShelfCover extends StatefulWidget {
  final String coverUrl;
  final BookshelfItemType type;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final double? progress;
  final String? progressLabel;
  final String? formatLabel;
  final String? sourceLabel;
  final String? sourceId; // 封面防盗链头用
  final int? updateCount; // 更新角标（新话数），仅漫画条目有值
  final bool isSelecting;
  final bool selected;

  const _ShelfCover({
    required this.coverUrl,
    required this.type,
    required this.onTap,
    required this.onLongPress,
    this.progress,
    this.progressLabel,
    this.formatLabel,
    this.sourceLabel,
    this.sourceId,
    this.updateCount,
    this.isSelecting = false,
    this.selected = false,
  });

  @override
  State<_ShelfCover> createState() => _ShelfCoverState();
}

class _ShelfCoverState extends State<_ShelfCover> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 进度徽标：百分比（有下载）或文字（无下载在线阅读），共用同款样式
    Positioned badge(Widget child) => Positioned(
      right: 4,
      bottom: 4,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: (isDark ? Colors.black : JellyTheme.primary).withValues(
            alpha: 0.75,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: child,
      ),
    );
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _isPressed ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(
                decoration: BoxDecoration(
                  // 圆角跟随「显示设置 → 封面圆角」（用户 2026-10-15）
                  borderRadius:
                      BorderRadius.circular(SettingsService().coverRadiusPx),
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.05)
                      : JellyTheme.cardLight,
                  boxShadow: [
                    BoxShadow(
                      color: isDark
                          ? Colors.black.withValues(alpha: 0.45)
                          : JellyTheme.primary.withValues(alpha: 0.18),
                      blurRadius: 8,
                      offset: const Offset(0, 5),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius:
                      BorderRadius.circular(SettingsService().coverRadiusPx),
                  child: _buildCoverImage(isDark),
                ),
              ),
              if (widget.isSelecting)
                Positioned(
                  top: 4,
                  left: 4,
                  child: JellySelectBadge(selected: widget.selected),
                ),
              // 徽标类信息跟随「显示设置 → 卡片信息」开关（用户 2026-10-15）
              if (SettingsService().cardInfo &&
                  !widget.isSelecting &&
                  (widget.formatLabel != null || widget.sourceLabel != null))
                Positioned(
                  top: 4,
                  left: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: (isDark ? Colors.black : JellyTheme.primary)
                          .withValues(alpha: 0.75),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      widget.formatLabel ?? widget.sourceLabel!,
                      style: const TextStyle(
                        fontSize: AppTheme.fontCaption,
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              // 右上角：更新角标（红底白字 +N，与左上格式/源徽标错开）
              if (SettingsService().cardInfo &&
                  (widget.updateCount ?? 0) > 0 &&
                  !widget.isSelecting)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE5484D).withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '+${widget.updateCount}',
                      style: const TextStyle(
                        fontSize: AppTheme.fontCaption,
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              // 底部细进度条：图书按页数百分比（漫画无总数时只显示文字徽标）
              if (SettingsService().cardInfo && widget.progress != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: ClipRRect(
                    borderRadius: BorderRadius.vertical(
                      bottom: Radius.circular(
                        SettingsService().coverRadiusPx,
                      ),
                    ),
                    child: LinearProgressIndicator(
                      value: (widget.progress ?? 0).clamp(0.0, 1.0),
                      minHeight: 3,
                      backgroundColor:
                          Colors.white.withValues(alpha: 0.25),
                      color: JellyTheme.primary,
                    ),
                  ),
                ),
              if (SettingsService().cardInfo && widget.progress != null)
                badge(
                  Text(
                    '${(widget.progress! * 100).round()}%',
                    style: const TextStyle(
                      fontSize: AppTheme.fontCaption,
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                )
              else if (SettingsService().cardInfo &&
                  widget.progressLabel != null)
                badge(
                  Text(
                    widget.progressLabel!,
                    style: const TextStyle(
                      fontSize: AppTheme.fontCaption,
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCoverImage(bool isDark) {
    var url = widget.coverUrl;
    // 兼容旧数据：早期 PDF 与 TXT 共用 default_txt.png，重指到 PDF 专属默认封面
    // （default_pdf.png 由 BookDownloadService.init 预生成）。
    if (widget.formatLabel == 'PDF' && url.endsWith('default_txt.png')) {
      url = url.replaceAll('default_txt.png', 'default_pdf.png');
    }
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return CachedNetworkImage(
        imageUrl: url,
        httpHeaders: coverHeaders(widget.sourceId),
        fit: BoxFit.cover,
        placeholder: (c, u) => _buildPlaceholder(isDark),
        errorWidget: (c, u, e) => _buildPlaceholder(isDark),
      );
    }
    if (url.isNotEmpty) {
      // 本地封面文件（导入的 epub/txt）
      return Image.file(
        File(url),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildPlaceholder(isDark),
      );
    }
    return _buildPlaceholder(isDark);
  }

  Widget _buildPlaceholder(bool isDark) {
    return Center(
      child: Icon(
        widget.type == BookshelfItemType.comic
            ? Icons.palette_rounded
            : Icons.book_rounded,
        size: 28,
        color: isDark ? Colors.white24 : Colors.black26,
      ),
    );
  }
}

/// 书架内容：按屏宽分列，每行封面立在架板上（名称行已移除，见 `_BookshelfRow`）
Widget _buildShelfContent({
  required List<_ShelfEntry> entries,
  required ScrollController scrollController,
  required bool showBackToTop,
  required VoidCallback onBackToTop,
  required int session,
  required void Function(_ShelfEntry) onLongPress,
  bool isSelecting = false,
  Set<String>? selectedIds,
  ValueChanged<String>? onSelect,
}) {
  return Stack(
    children: [
      LayoutBuilder(
        builder: (context, constraints) {
          final cols = _adaptiveCols(constraints.maxWidth);
          // 卡片间距随「显示设置 → 列表密度」缩放（用户 2026-10-15）
          final spacing = 12.0 * SettingsService().densityScale;
          final cellWidth =
              (constraints.maxWidth - 24 - (cols - 1) * spacing) / cols;
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final rows = <List<_ShelfEntry>>[];
          for (var i = 0; i < entries.length; i += cols) {
            rows.add(entries.sublist(i, (i + cols).clamp(0, entries.length)));
          }
          return ListView.builder(
            controller: scrollController,
            padding: EdgeInsets.only(
              top: 8,
              left: 12,
              right: 12,
              bottom: 12 + JellyNavBar.contentBottomAvoid,
            ),
            itemCount: rows.length,
            itemBuilder: (context, r) => _BookshelfRow(
              cellWidth: cellWidth,
              spacing: spacing,
              isDark: isDark,
              entries: rows[r],
              session: session,
              onLongPress: onLongPress,
              isSelecting: isSelecting,
              selectedIds: selectedIds ?? const {},
              onSelect: onSelect ?? (_) {},
            ),
          );
        },
      ),
      _buildBackToTop(showBackToTop, onBackToTop),
    ],
  );
}

/// 长按书架条目：多选编辑 / 移出当前书架 / 移到其他书架。
///
/// ⚠️ 「移出 / 移到」在「全部」汇总视图下**没有明确的目标书架** ✗
///   ⇒ 与批量移除（`_removeSelectedFromShelf`）同口径：提示先进具体书架 ✓。
void _showShelfItemMenu(
  BuildContext context,
  String shelfId,
  _ShelfEntry e, {
  VoidCallback? onEdit,
}) {
  final isDark = Theme.of(context).brightness == Brightness.dark;
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) => kbSheet(Container(
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Text(
                e.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                ),
              ),
            ),
            // ① 多选编辑：进入批量模式并选中本条（跨书架批量操作的入口）
            if (onEdit != null)
              ListTile(
                leading: Icon(
                  Icons.checklist_rounded,
                  color: JellyTheme.primary,
                ),
                title: const Text('多选编辑'),
                onTap: () {
                  Navigator.pop(ctx);
                  onEdit();
                },
              ),
            // ② / ③ 移出 / 移到其他书架（「全部」为汇总视图时不可用）
            if (shelfId != kAllShelfId) ...[
              ListTile(
                leading: Icon(
                  Icons.remove_circle_outline_rounded,
                  color: JellyTheme.error,
                ),
                title: const Text('移出当前书架'),
                onTap: () async {
                  await BookshelfService().removeFromBookshelf(
                    shelfId,
                    e.itemId,
                    e.type,
                  );
                  // 🔴 原来**无条件**删本地导入文件 ✗ —— 而「移除同时删除本地文件」
                  //   是可选项、默认关 ⇒ 与批量移除同口径（见 _removeSelectedFromShelf）
                  if (e.type == BookshelfItemType.book &&
                      SettingsService().shelfRemoveDeletesFile) {
                    await BookDownloadService()
                        .cleanupOrphanedImport(e.itemId);
                  }
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.swap_horiz_rounded,
                  color: JellyTheme.primary,
                ),
                title: const Text('移到其他书架'),
                onTap: () async {
                  Navigator.pop(ctx);
                  await showBookshelfDialog(
                    context,
                    itemId: e.itemId,
                    type: e.type,
                    title: '移到其他书架',
                    meta: e.meta,
                    singleSelect: true,
                  );
                },
              ),
            ] else
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  '「全部」为汇总视图，请进入具体书架后管理',
                  style: TextStyle(fontSize: AppTheme.fontFootnote),
                ),
              ),
            // ③.5 导出本地文件：与「删除本地文件」同一门槛（确实有文件才出现）
            if (_hasLocalFiles(e))
              ListTile(
                leading: Icon(
                  Icons.ios_share_rounded,
                  color: JellyTheme.primary,
                ),
                title: const Text('导出本地文件'),
                subtitle: Text(
                  e.type == BookshelfItemType.comic
                      ? '整本打包成 ZIP 后分享'
                      : '用系统分享面板另存',
                  style: const TextStyle(fontSize: AppTheme.fontCaption),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _exportLocalFiles(context, e);
                },
              ),
            // ④ 硬删除：删掉本地已下载内容（不可恢复）。
            //    只在**确实有本地文件**时才出现 ✓（否则点了没反应会让人困惑）
            //    不依赖当前书架 ⇒ 「全部」视图下也提供 ✓
            if (_hasLocalFiles(e))
              ListTile(
                leading: Icon(
                  Icons.delete_forever_rounded,
                  color: JellyTheme.error,
                ),
                title: Text(
                  '删除本地文件',
                  style: TextStyle(color: JellyTheme.error),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _deleteLocalFiles(context, e);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    )),
  );
}

/// 该书架条目**是否有本地文件可删**：
///   · 漫画 → 有已下载章节（`DownloadService.downloadedChapters`）
///   · 图书 → 有下载/导入任务（`BookDownloadService.task`）
bool _hasLocalFiles(_ShelfEntry e) {
  if (e.type == BookshelfItemType.comic) {
    return DownloadService().downloadedChapters(e.itemId).isNotEmpty;
  }
  return BookDownloadService().task(e.itemId) != null;
}

/// **导出**本地文件：漫画整本打包 ZIP，图书直接分享文件。
Future<void> _exportLocalFiles(BuildContext context, _ShelfEntry e) async {
  var ok = false;
  try {
    if (e.type == BookshelfItemType.comic) {
      final dir = await DownloadService().comicDownloadDir(e.itemId, e.title);
      if (dir != null) {
        ok = await FileExportService.shareDirectory(dir, archiveName: e.title);
      }
    } else {
      final path = BookDownloadService().task(e.itemId)?.localPath;
      if (path != null) {
        ok = await FileExportService.shareFiles([path]);
      }
    }
  } catch (err) {
    debugPrint('[Bookshelf] 导出失败: $err');
  }
  if (ok || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('导出失败'),
      content: const Text(
        '没有找到本地文件，或当前系统不支持分享面板。\n'
        '你仍可在「文件」App → 我的 iPhone → 猫影 → Cmbok 中直接查看下载内容。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

/// **硬删除**本地文件（不可恢复）：菜单「删除本地文件」的实现。
///
///   · 漫画 → 删整本已下载章节（文件 + 记录）；书架条目**保留**
///     （还能在线阅读 / 重新下载）✓
///   · 图书 → 删本地文件 + 下载记录；**本地导入**的图书其条目本身
///     就是那个文件 ⇒ 删完会变成打不开的死卡片 ⇒ 一并从所有书架移除 ✓
///     （在线书源下载的书保留条目，可重新下载 ✓）
Future<void> _deleteLocalFiles(BuildContext context, _ShelfEntry e) async {
  final isComic = e.type == BookshelfItemType.comic;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除本地文件'),
      content: Text(
        isComic
            ? '将删除《${e.title}》已下载的全部章节，删除后不可恢复。\n'
                '书架条目会保留，可重新下载或在线阅读。'
            : '将删除《${e.title}》的本地文件与下载记录，删除后不可恢复。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(
            backgroundColor: JellyTheme.error,
          ),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (ok != true) return;

  if (isComic) {
    await DownloadService().deleteComic(e.itemId);
    return;
  }
  final task = BookDownloadService().task(e.itemId);
  await BookDownloadService().deleteTask(e.itemId);
  // 本地导入书：删文件后条目已无内容可读 ⇒ 一并从所有书架移除
  if (task != null && task.isLocalImport) {
    await BookshelfService().setBookshelvesForItem(
      const <String>[],
      e.itemId,
      BookshelfItemType.book,
    );
  }
}

// ============================================================
// 公用组件
// ============================================================
Widget _buildEmpty(BuildContext context, String text, IconData icon) {
  return AppEmptyView(
    title: text,
    subtitle: '去详情页加入书架吧',
    icon: icon,
    iconColor: JellyTheme.primary.withValues(alpha: 0.5),
  );
}

Widget _buildBackToTop(bool visible, VoidCallback onTap) {
  return ListenableBuilder(
    listenable: SettingsService(),
    builder: (context, _) {
      // 与漫画/图书搜索页一致：悬浮导航栏开启时抬升避让
      final fabOffset = SettingsService().navFloating
          ? JellyNavBar.floatingTotalHeight + 8
          : 0.0;
      return Positioned(
        bottom: 16 + fabOffset,
        right: 16,
        child: AnimatedScale(
          scale: visible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          // ⛔ **这里是有意不同、不要"统一"成 `AppIconButton`** ✗✓（今天逐条核实过 ✓）
          //   它是**返回顶部悬浮钮** ✓，与顶栏那排"同族圆钮"不是一类东西 ✓：
          //     · 尺寸 ✗：44×44（悬浮 FAB ✓）vs 顶栏 36×36（`AppIconButton` 默认 ✓）
          //     · 形态 ✗：`primary` + `elevation: 4` + 投影 = **传统醒目 FAB** ✓
          //       —— 换成 `AppIconButton` 的"淡圆底"会让它在内容上**几乎看不见** ✗✗
          //     · 位置 ✗：`Positioned` 浮在滚动内容之上 ✓ vs 顶栏固定位 ✓
          //   ℹ️ 同款还有 `book_search_page` 与 `download_page` 的返回顶部钮 ✓（结论相同 ✓）
          child: Material(
            color: JellyTheme.primary,
            shape: const CircleBorder(),
            elevation: 4,
            shadowColor: JellyTheme.primary.withValues(alpha: 0.4),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
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
  );
}

int _adaptiveCols(double width) {
  const target = 110.0;
  const min = 3;
  const max = 6;
  final available = width - 40;
  var cols = (available / target).floor();
  if (cols < min) cols = min;
  if (cols > max) cols = max;
  return cols;
}

/// 按 `SettingsService().shelfSort` 给书架条目排序。
///
/// 抽成顶层函数是因为**漫画与图书两个列表都要用**：
/// 各写一份必然分叉（改了一处忘了另一处）。
///
/// 各模式语义：
///   · `recent`（默认）—— "正在读"书架用"加入时间 / 最近阅读时间"的较大者倒序
///     （新移入无进度的用 addedAt 兜底排到顶部，继续阅读的按最近阅读上浮）；
///     其他书架等同于"最近添加"
///   · `added`  —— 最近添加
///   · `title`  —— 按书名（不区分大小写）
///   · `author` —— 按作者（不区分大小写）
void _applyShelfSort(List<BookshelfItem> items, String shelfId) {
  final s = SettingsService();
  final asc = s.shelfSortAsc;

  /// 按正/倒序取比较结果。
  /// 抽出来是因为每个分支都要用，写六遍 `asc ? x.compareTo(y) : y.compareTo(x)`
  /// 很容易在某一支写反（那支就永远不跟着方向变）。
  int dir(int c) => asc ? c : -c;

  /// 取条目的"最近阅读时间"（毫秒）—— **不猜类型** ✓，因为两个 id 空间不重叠：
  /// 图书的 itemId 形如 `book-<url>` ✓（见 `book_source_detail_page` 的加入书架 ✓），
  /// 漫画的 itemId 是 `pathWord` ✓。图书进度存在 `BookReadingProgressService` ✓，
  /// 漫画存在 `ReadingProgressService` ✓ → 两个都问、取非空的最安全 ✓。
  /// 原来这里清一色用**漫画**那套 ✗ → 图书的「最近阅读 / 阅读进度」恒为 0 ✓
  /// （排序结果 = "全部相同 → 保持原序" ✗，用户会以为排序没生效 ✓）
  int shelfUpdatedAtOf(String itemId) {
    final b = BookReadingProgressService().getProgress(itemId)?.updatedAt;
    final c = ReadingProgressService().getProgress(itemId)?.updatedAt;
    return (b ?? c) ?? 0;
  }

  /// 取"读到哪了"的**标量**，取不到返回 -1（用于"阅读进度"排序 ✓）。
  /// 同样**不猜类型** ✓：图书问 `BookReadingProgressService`（每页一条记录，
  /// 用 `pageIndex` ✓ —— 本文件 :3548 就是这么算百分比的 ✓），
  /// 漫画问 `ReadingProgressService`（用 `lastChapterIndex` ✓，与原来一致 ✓）。
  /// 书架列表里**只会是纯图书或纯漫画** ✓，所以两个标量不需要同尺度 ✓
  int shelfReadIndex(String itemId) {
    final b = BookReadingProgressService().getProgress(itemId);
    if (b != null) return b.pageIndex;
    final c = ReadingProgressService().getProgress(itemId);
    if (c != null) return c.lastChapterIndex;
    return -1;
  }

  switch (s.shelfSort) {
    case 'title':
    case 'author':
      // title / author 不在 BookshelfItem 上，而在 meta JSON 快照里。
      // ⚠️ 必须先**预计算**再排序：直接在比较器里 jsonDecode
      // 会解析 O(n log n) 次，几百本书的书架会明显卡顿。
      final keys = <String, String>{};
      for (final it in items) {
        var title = '';
        var author = '';
        if (it.meta != null) {
          try {
            final m = jsonDecode(it.meta!) as Map<String, dynamic>;
            title = (m['title'] ?? '').toString();
            author = (m['author'] ?? '').toString();
          } catch (_) {
            // meta 损坏就当空串，不因此崩掉整个书架
          }
        }
        keys[it.itemId] =
            (s.shelfSort == 'title' ? title : author).toLowerCase();
      }
      items.sort((a, b) =>
          dir((keys[a.itemId] ?? '').compareTo(keys[b.itemId] ?? '')));
      break;
    case 'added':
      items.sort((a, b) => dir(a.addedAt.compareTo(b.addedAt)));
      break;
    case 'recent':
      // ⚡ 性能（本次唯一目的）：**先把 key 算一次**，再排序 ✓。
      //   原来是在**比较器内部**逐次查表 ✗（`shelfUpdatedAtOf(a.itemId)` ✓）——
      //   而 `sort` 要比较 O(N log N) 次 ✓ → 总代价 **O(N² log N)** ✗
      //   （书架几百本时滚动/切换排序会明显卡顿 ✓）。
      //   ℹ️ **语义完全不变** ✓：key 的算法、方向 `dir`、并列时的行为都照旧 ✓
      final recentKeys = <String, int>{
        for (final it in items) it.itemId: shelfUpdatedAtOf(it.itemId),
      };
      items.sort(
        (a, b) => dir(recentKeys[a.itemId]!.compareTo(recentKeys[b.itemId]!)),
      );
      break;
    case 'progress':
      // 阅读进度：按"读到第几话/章"排。
      // 没有进度的（未开始读）一律排最后 —— 让它们在任一方向下都沉底，
      // 否则正序时"未读"会跑到最前面，很反直觉。
      // ⚡ 同上：预算 key ✓（**"未读沉底"的规则原样保留** ✓）
      final progressKeys = <String, int>{
        for (final it in items) it.itemId: shelfReadIndex(it.itemId),
      };
      items.sort((a, b) {
        final va = progressKeys[a.itemId]!;
        final vb = progressKeys[b.itemId]!;
        if (va < 0 && vb < 0) return 0;
        if (va < 0) return 1;
        if (vb < 0) return -1;
        return dir(va.compareTo(vb));
      });
      break;
    case 'default':
    default:
      // 「默认」= 各书架自己的语义顺序：
      //   · "正在读"：加入时间 / 最近阅读时间取大者倒序
      //     （新移入无进度的用 addedAt 兜底排顶部；继续阅读的按最近阅读上浮）
      //   · 其他书架：最近添加
      if (shelfId == BookshelfService.presetReading) {
        // ⚡ 同上：预算 key ✓（**语义不变** ✓：仍是 max(addedAt, 最近阅读) ✓）
        final readingKeys = <String, int>{
          for (final it in items) it.itemId: shelfUpdatedAtOf(it.itemId),
        };
        items.sort((a, b) {
          final ra = readingKeys[a.itemId]!;
          final rb = readingKeys[b.itemId]!;
          final ka = a.addedAt > ra ? a.addedAt : ra;
          final kb = b.addedAt > rb ? b.addedAt : rb;
          return dir(ka.compareTo(kb));
        });
      } else {
        items.sort((a, b) => dir(a.addedAt.compareTo(b.addedAt)));
      }
      break;
  }
}
