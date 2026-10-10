import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/bookshelf.dart';
import '../models/comic.dart';
import '../services/book_download_service.dart';
import '../services/book_reading_progress_service.dart';
import '../services/bookshelf_service.dart';
import '../services/browse_history_service.dart';
import '../services/download_service.dart';
import '../services/favorites_service.dart';
import '../services/reading_progress_service.dart';
import '../../common/theme.dart';
import '../../services/main_tab_controller.dart';
import '../services/settings_service.dart';
import '../source/adapter.dart';
import '../source/source_manager.dart';
import '../theme/jelly_theme.dart';
import '../widgets/bookshelf_icon.dart';
import '../widgets/jelly_nav_bar.dart';
import '../widgets/jelly_nav_rail.dart';
import '../widgets/notification_popup.dart';
import '../widgets/theme_background.dart';
import 'shell_embedded_page.dart';
import 'book_reader_page.dart';
import 'book_search_page.dart';
import 'bookshelf_page.dart';
import 'favorites_page.dart';
import 'me_page.dart';
import 'reader_page.dart';
import 'search_page.dart';

/// 主页面（果冻风底部导航）
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late NavTab _currentTab; // 当前选中的 tab

  /// 切 tab 的进场动画（0→1）：新 tab 内容**淡入 + 从点击方向轻微滑入** ✓
  /// ⚠️ 动画只作用在内容整块上，`IndexedStack` 本身不重建
  ///   ⇒ 各 tab 的状态（滚动位置 / 播放等）照常保留 ✓
  late final AnimationController _tabAnim;

  /// 进场方向：+1 = 从右滑入（切到右边的 tab），-1 = 从左滑入 ✓
  double _tabDir = 1;

  /// 书架页外部触发多选（底部导航「书架」上滑时自增，书架页监听进入多选模式）
  final ValueNotifier<int> _shelfSelectTrigger = ValueNotifier(0);

  // NavTab 与导航项、页面的映射
  static final Map<NavTab, JellyNavItem> _tabNavItems = {
    NavTab.manga: JellyNavItem(icon: Icons.palette_rounded, label: '漫画'),
    NavTab.book: JellyNavItem(icon: Icons.book_rounded, label: '图书'),
    NavTab.bookshelf: JellyNavItem(
      iconBuilder: (color, size) => BookshelfIcon(color: color, size: size),
      label: '书架',
    ),
    NavTab.favorites: JellyNavItem(icon: Icons.favorite_rounded, label: '收藏'),
    NavTab.me: JellyNavItem(icon: Icons.person_rounded, label: '我的'),
  };

  @override
  void initState() {
    super.initState();
    _currentTab = SettingsService().defaultHomePage.toNavTab();
    // 切 tab 动画：初始即"已落位"（value = 1），避免首帧就先淡入一次 ✓
    _tabAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..value = 1;
    // 监听设置变化（默认首页、可见 tab 变化时响应）
    SettingsService().addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    SettingsService().removeListener(_onSettingsChanged);
    _shelfSelectTrigger.dispose();
    _tabAnim.dispose();
    super.dispose();
  }

  void _onSettingsChanged() {
    final visible = SettingsService().visibleNavTabs;
    if (!visible.contains(_currentTab)) {
      // 当前 tab 被隐藏，切到第一个可见 tab
      setState(() => _currentTab = visible.first);
    }
  }

  /// tab 内容：`IndexedStack` **保各 tab 状态**（滚动位置等 ✓）+
  /// 切换时给整块内容一个**淡入 + 从点击方向轻微滑入**的进场动画 ✓。
  /// 内嵌子页（书源页 ↔ 图书页）与 tab 内容之间的**滑入 / 滑出**切换。
  /// 从 `build` 里抽出来：宽屏左侧竖栏与窄屏底部栏**两条路径共用同一份内容** ✓。
  Widget _embeddedOrTabs(int currentIndex, List<Widget> pages) {
    return ValueListenableBuilder<Widget?>(
      valueListenable: shellEmbeddedPage,
      builder: (_, embedded, __) {
        // ✅ 内嵌子页（书源页 ↔ 图书页）**滑入 / 滑出**，不再是"瞬间替换" ✓
        //   · 打开：内嵌页从右滑入，压在底下的 tab 内容**不动** ✓
        //   · 关闭：内嵌页向右滑出，tab 内容原地露出 ✓
        //   ⇒ 两层永不互相穿过（用户实测过"界面切换有点重叠"✗）
        final opening = embedded != null;
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          layoutBuilder: (current, previous) => Stack(
            fit: StackFit.expand,
            children: [
              ...previous,
              if (current != null) current,
            ],
          ),
          transitionBuilder: (child, anim) {
            // 只有**内嵌页**动：开 = 进场（正向），关 = 退场（反向）；
            // tab 内容始终不动 ✓
            final moves = opening
                ? anim.status != AnimationStatus.reverse
                : anim.status == AnimationStatus.reverse;
            if (!moves) return child;
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(1, 0),
                end: Offset.zero,
              ).animate(CurvedAnimation(
                parent: anim,
                curve: Curves.easeOutCubic,
                reverseCurve: Curves.easeInCubic,
              )),
              child: child,
            );
          },
          child: embedded ?? _tabContent(currentIndex, pages),
        );
      },
    );
  }

  Widget _tabContent(int currentIndex, List<Widget> pages) {
    return AnimatedBuilder(
      animation: _tabAnim,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_tabAnim.value);
        return Opacity(
          // 从 0.2 淡入（不从 0 —— 全透明会先闪一下空白 ✗）
          opacity: 0.2 + 0.8 * t,
          child: Transform.translate(
            offset: Offset(_tabDir * 24 * (1 - t), 0),
            child: child,
          ),
        );
      },
      child: IndexedStack(index: currentIndex, children: pages),
    );
  }

  /// 底部导航栏上滑回调：书架 tab 上滑唤起批量多选（参考 cmbok 引导）
  /// 导航项点击（底部胶囊栏 + 宽屏左侧竖栏**共用** ✓，避免两处逻辑各写一遍）
  void _onNavTap(int index, List<NavTab> visible, int currentIndex) {
    setState(() {
      // 切 tab 进场动画：按"往左 / 往右"给个方向 ✓
      if (index != currentIndex) {
        _tabDir = index > currentIndex ? 1 : -1;
        _tabAnim.forward(from: 0);
      }
      _currentTab = visible[index];
      // 内嵌页（书源页等）打开时，点导航栏要先退出内嵌页：
      // 否则 body 一直被 embedded 占据，界面切不过去
      // （用户 2026-10-06 反馈"书源页悬浮导航栏点击没反应"）
      if (shellEmbeddedPage.value != null) {
        shellEmbeddedPage.value = null;
      }
    });
  }

  void _onNavSlideUp(int index) {
    final visible = SettingsService().visibleNavTabs;
    if (index < 0 || index >= visible.length) return;
    final tab = visible[index];
    if (tab == NavTab.bookshelf) {
      _shelfSelectTrigger.value += 1;
    }
  }

  /// 底部导航栏长按回调：漫画 tab 续读最近漫画，图书 tab 续读最近图书
  void _onNavLongPress(int index) {
    final visible = SettingsService().visibleNavTabs;
    if (index < 0 || index >= visible.length) return;
    final tab = visible[index];
    switch (tab) {
      case NavTab.manga:
        _resumeLastComic();
        break;
      case NavTab.book:
        _resumeLastBook();
        break;
      case NavTab.me:
        // 长按「我的」= 返回影视。
        // 为什么放这里而不是加第 6 个 tab：
        //   阅读是独立模块，进来后影视底栏被 app.dart 的
        //   inEmbeddedModule 隐藏，需要一个出口；
        //   但加 tab 会把 5 项挤成 6 项、每项从 ~98px 掉到 ~65px，
        //   与用户截图不符。长按不占位置、也不怕误触。
        MainTabController.instance.backToVideo();
        break;
      case NavTab.bookshelf:
      case NavTab.favorites:
        // 其他 tab 暂无长按动作
        break;
    }
  }

  /// 续读最近阅读的漫画
  Future<void> _resumeLastComic() async {
    final recent = ReadingProgressService().getMostRecent();
    if (recent == null) {
      _showToast('暂无阅读记录');
      return;
    }
    final pathWord = recent.key;

    // 按优先级从本地查找 Comic 对象：书架 → 浏览历史 → 收藏
    Comic? comic = _findComicInShelf(pathWord);
    comic ??= _findComicInBrowseHistory(pathWord);
    comic ??= _findComicInFavorites(pathWord);

    if (comic == null) {
      _showToast('暂无阅读记录');
      return;
    }

    if (!mounted) return;
    await _openComicReader(comic);
  }

  /// 从书架 meta 中查找漫画
  Comic? _findComicInShelf(String pathWord) {
    final meta = BookshelfService().findItemMeta(
      pathWord,
      BookshelfItemType.comic,
    );
    if (meta == null) return null;
    try {
      return Comic.fromJson(jsonDecode(meta) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// 从浏览历史中查找漫画
  Comic? _findComicInBrowseHistory(String pathWord) {
    try {
      return BrowseHistoryService().comics.firstWhere(
            (c) => c.pathWord == pathWord || c.id == pathWord,
          );
    } catch (_) {
      return null;
    }
  }

  /// 从收藏中查找漫画
  Comic? _findComicInFavorites(String pathWord) {
    try {
      return FavoritesService().comics.firstWhere(
            (c) => c.pathWord == pathWord || c.id == pathWord,
          );
    } catch (_) {
      return null;
    }
  }

  /// 拉取漫画详情+章节后打开阅读器（续读章节或第一章）
  Future<void> _openComicReader(Comic comic) async {
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
      final source = (comic.sourceId != null && comic.sourceId!.isNotEmpty)
          ? (SourceManager().getSource(comic.sourceId!) ??
                SourceManager().current)
          : SourceManager().current;
      final details = await source.getMangaDetailsAndChapters(
        comicToCManga(comic, source.id),
      );
      final resultComic = cmangaToComic(details.manga);
      final groups = cchaptersToGroups(details.chapters);
      rootNav.pop();
      if (!mounted) return;

      // 章节按源站原始 order 排序，方向由源决定，统一「第1话在前」
      for (final g in groups) {
        g.chapters.sort(
          (a, b) =>
              chapterCompare(a.order, b.order, source.chapterOrderDescending),
        );
      }

      // 起始章节：续读章节；无记录则第一章
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
        if (!mounted) return;
        _showToast('暂无可读章节');
        return;
      }

      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderPage(
            comic: resultComic,
            chapter: start!,
            groups: groups,
            initialPage: initialPage,
          ),
        ),
      );
    } catch (e) {
      rootNav.pop();
      if (mounted) _showToast('打开失败：$e');
    }
  }

  /// 排序后首个非空分组的第一章
  ComicChapter? _firstChapter(List<ChapterGroup> groups) {
    for (final g in groups) {
      if (g.chapters.isNotEmpty) return g.chapters.first;
    }
    return null;
  }

  /// 续读最近阅读的图书
  Future<void> _resumeLastBook() async {
    final recent = BookReadingProgressService().getMostRecent();
    if (recent == null) {
      _showToast('暂无阅读记录');
      return;
    }
    final bookId = recent.key;
    final task = BookDownloadService().task(bookId);
    if (task == null || task.status != BookDownloadStatus.completed) {
      _showToast('该书尚未下载完成');
      return;
    }
    if (!mounted) return;
    await BookReaderPage.open(context, task);
  }

  void _showToast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  // 根据 tab 构建对应页面（isActive 由当前选中状态决定）
  Widget _buildPageFor(NavTab tab, bool isActive) {
    switch (tab) {
      case NavTab.manga:
        return SearchPage(isActive: isActive);
      case NavTab.book:
        return BookSearchPage(isActive: isActive);
      case NavTab.favorites:
        return FavoritesPage(isActive: isActive);
      case NavTab.bookshelf:
        return BookshelfPage(
          isActive: isActive,
          selectTrigger: _shelfSelectTrigger,
        );
      case NavTab.me:
        return MePage(isActive: isActive);
    }
  }

  @override
  Widget build(BuildContext context) {
    // ── V5：阅读模块终于套上了**自己的** Material 主题 ──────────────
    //
    // 在此之前 `JellyTheme.light / dark`（阅读的 ThemeData）**全工程 0 引用**，
    // 本页里所有"没写显式配色"的 Material 部件取的都是影视侧的
    // `AppTheme.lightTheme`。铁证：`me_page.dart` 那个没指定颜色的 `Switch`
    // 跟着 `AppTheme.accentColor`（影视调色板）走，而同模块
    // `reading_settings_page.dart` 的 Switch 写的是 `JellyTheme.primary` ——
    // 同一个控件两条取色链路。现在整棵阅读子树统一走阅读主题。
    //
    // ⚠️ 必须监听 `AppBrightness.isLight`：本页原先只监听 SettingsService，
    // 而 AppTheme / JellyTheme 的颜色 getter 读的是全局明暗（普通
    // ValueNotifier，改了**不通知任何 widget**），不监听就切明暗不重建。
    return ValueListenableBuilder<bool>(
      valueListenable: AppBrightness.isLight,
      builder: (context, isLight, _) => Theme(
        data: isLight ? JellyTheme.light : JellyTheme.dark,
        child: _buildRoot(context),
      ),
    );
  }

  /// 阅读模块的实际内容 —— 原来 [build] 里的全部逻辑，一行未改。
  ///
  /// 单独拆出来只是为了让上面那层 [Theme] 一眼可见：若把 60 行 build 体
  /// 整体再缩进一层，diff 会大得看不出真正改了什么。
  Widget _buildRoot(BuildContext context) {
    return ListenableBuilder(
      listenable: SettingsService(),
      builder: (context, _) {
        final visible = SettingsService().visibleNavTabs;
        // 保险：确保 _currentTab 在可见列表中
        if (!visible.contains(_currentTab)) {
          _currentTab = visible.first;
        }
        final currentIndex = visible.indexOf(_currentTab);

        final navItems = visible
            .map((t) => _tabNavItems[t]!)
            // 「影视」是**跳出阅读模块**的入口，不是阅读的 tab。
            // 为什么必须加：阅读自带 5-tab 悬浮栏，进入阅读后影视底栏会被隐藏
            // （见 app.dart 的 inEmbeddedModule），
            // 没有这条就**没有任何途径回到影视**。
            .toList();
        // ⚠️ 底栏**不追加**「影视」入口。
        // 用户的截图里阅读底栏就是 5 项（漫画/图书/书架/收藏/我的），
        // 加第 6 项会让每项宽度从 ~98px 掉到 ~65px，外观明显不同。
        // 回影视的入口改为**长按「我的」**（见 _onNavLongPress）——
        // 既不占位置，也不会误触。
        final pages = visible
            .map((t) => _buildPageFor(t, t == _currentTab))
            .toList(growable: false);

        final floating = SettingsService().navFloating;

        // 背景置于 Scaffold 外层全屏：键盘弹出时只压缩 Scaffold（前景避让），
        // 背景保持原尺寸被键盘自然遮挡，避免底部动画被顶到键盘上方、且随键盘逐帧重排卡顿
        // ✅ 宽屏（**只在 iPad 触发**：宽 ≥ 800 且短边 ≥ 600）→ 底部胶囊栏换成
        //   **左侧竖向悬浮栏**（参考 cmbok 的宽屏形态 ✓）。
        //   ⚠️ 为什么还要判短边：iPhone 横屏最宽能到 932（≥800 ✗ 会误触发），
        //   但它短边只有 ~430 ⇒ 用短边 ≥ 600 把 iPhone 排除掉，**只在 iPad 生效** ✓。
        final size = MediaQuery.sizeOf(context);
        final useRail = size.width >= 800 && size.shortestSide >= 600;
        return Stack(
          fit: StackFit.expand,
          children: [
            // 纯色底：纯色主题透出此色（背景全在外层不被键盘压缩；Scaffold 设透明避免遮挡）
            ColoredBox(color: Theme.of(context).scaffoldBackgroundColor),
            const RepaintBoundary(child: ThemeBackground()),
            Scaffold(
              backgroundColor: Colors.transparent,
              // 悬浮模式：extendBody 让内容延伸到底部，导航栏浮在内容上方
              extendBody: floating,
              body: Column(
                children: [
                  const NotificationPopup(),
                  Expanded(
                    child: useRail
                        // ✅ iPad（宽 ≥ 800 且短边 ≥ 600）：左侧竖栏 + 内容（内容自动让位 ✓）
                        ? Row(
                            children: [
                              JellyNavRail(
                                currentIndex: currentIndex,
                                onTap: (i) => _onNavTap(i, visible, currentIndex),
                                onLongPress: _onNavLongPress,
                                items: navItems,
                              ),
                              Expanded(
                                child: _embeddedOrTabs(currentIndex, pages),
                              ),
                            ],
                          )
                        : _embeddedOrTabs(currentIndex, pages),
                  ),
                ],
              ),
              // 果冻风底部导航（支持悬浮胶囊样式）
              // ✅ iPad 宽屏已改用左侧竖栏 ⇒ 这里返回 null（两者只显示一个 ✓）
              bottomNavigationBar: useRail
                  ? null
                  : JellyNavBar(
                      currentIndex: currentIndex,
                      floating: floating,
                      onTap: (index) => _onNavTap(index, visible, currentIndex),
                      onLongPress: _onNavLongPress,
                      onSlideUp: _onNavSlideUp,
                      items: navItems,
                    ),
            ),
          ],
        );
      },
    );
  }
}
