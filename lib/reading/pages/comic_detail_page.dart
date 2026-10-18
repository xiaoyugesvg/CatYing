import 'dart:async';
import 'dart:convert';
import '../../widgets/common_widgets.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html_parser;
import '../models/comic.dart';
import '../source/adapter.dart';
import '../source/source_manager.dart';
import '../services/download_service.dart';
import '../models/bookshelf.dart';
import '../services/bookshelf_service.dart';
import '../services/shelf_update_service.dart';
import '../services/favorites_service.dart';
import '../services/reading_progress_service.dart';
import '../theme/jelly_theme.dart';
import '../widgets/download_chapter_sheet.dart';
import '../widgets/source_cover_image.dart';
import '../widgets/jelly_bookshelf_dialog.dart';
import '../widgets/jelly_score_badge.dart';
import '../widgets/theme_background_animation.dart';
import 'reader_page.dart';
import 'comic_aggregate_search_page.dart';
import 'search_page.dart';
import '../../common/theme.dart';

/// 日志工具
void _log(String message) {
  if (kDebugMode) {
    debugPrint('[ComicDetail] $message');
  }
}

/// 漫画详情页面
class ComicDetailPage extends StatefulWidget {
  final Comic comic;

  /// 封面 Hero 动画 tag（与来源页卡片一致；为空则不启用过渡动画）
  final String? heroTag;

  const ComicDetailPage({super.key, required this.comic, this.heroTag});

  @override
  State<ComicDetailPage> createState() => _ComicDetailPageState();
}

class _ComicDetailPageState extends State<ComicDetailPage> {
  /// 夜间模式次级文字色：`Colors.white70` 在深色底上偏灰（简介/作者/人气
  /// 看着发虚），统一提亮到 ~85% 白，保证与标题有层次但不牺牲可读性。
  static const Color _darkSecondary = Color(0xFFD9D9DE);

  final ScrollController _scrollController = ScrollController();

  late Comic _comic;
  List<ChapterGroup> _groups = [];
  bool _isLoading = true;
  String? _error;

  int _selectedGroupIndex = 0;
  bool _showAllChapters = false; // 当前分组是否展开全部章节
  bool _descExpanded = false; // 简介是否展开
  bool _descending = false; // 章节展示是否倒序（最新在前）
  bool _showBackToTop = false; // 是否显示返回顶部按钮

  /// 章节默认显示条数
  static const int _defaultVisibleChapters = 20;

  /// 触发返回顶部按钮的滚动阈值
  static const double _backToTopThreshold = 300;

  @override
  void initState() {
    super.initState();
    // 不从卡片带入状态/标签/简介，这些由详情页加载
    _comic = Comic(
      id: widget.comic.id,
      title: widget.comic.title,
      cover: widget.comic.cover,
      author: widget.comic.author,
      alias: widget.comic.alias,
      rating: widget.comic.rating,
      popular: widget.comic.popular,
      pathWord: widget.comic.pathWord,
      totalChapters: widget.comic.totalChapters,
      updateTime: widget.comic.updateTime,
      sourceId: widget.comic.sourceId,
    );
    _scrollController.addListener(_onScroll);
    DownloadService().addListener(_onDownloadChanged);
    ReadingProgressService().addListener(_onProgressChanged);
    _loadData();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    DownloadService().removeListener(_onDownloadChanged);
    ReadingProgressService().removeListener(_onProgressChanged);
    super.dispose();
  }

  /// 下载状态变化时刷新（更新章节已下载标记）
  void _onDownloadChanged() {
    if (mounted) setState(() {});
  }

  /// 阅读进度变化时刷新（更新“上次读到”章节的书签标识）
  void _onProgressChanged() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final show = _scrollController.position.pixels > _backToTopThreshold;
    if (show != _showBackToTop) {
      setState(() => _showBackToTop = show);
    }
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

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // 一次请求同时加载详情与章节（避免对 comic2 重复请求触发风控）
      // 优先用漫画自身所属源（书架含多源漫画，当前选中源未必匹配）；
      // 旧数据无 sourceId 时兜底当前源
      final source = (_comic.sourceId != null && _comic.sourceId!.isNotEmpty)
          ? (SourceManager().getSource(_comic.sourceId!) ??
                SourceManager().current)
          : SourceManager().current;
      final details = await source.getMangaDetailsAndChapters(
        comicToCManga(_comic, source.id),
      );
      final result = (
        comic: cmangaToComic(details.manga),
        groups: cchaptersToGroups(details.chapters),
      );
      final detail = result.comic;
      final groups = result.groups;
      _log(
        '详情加载完成: status=${detail.status}, tags=${detail.tags}, '
        'description长度=${detail.description?.length ?? 0}, '
        'author=${detail.author}, totalChapters=${detail.totalChapters}',
      );
      _log('章节加载完成: ${groups.length} 个分组');
      if (!mounted) return; // 连续返回时页面可能已销毁，丢弃结果

      setState(() {
        _comic = _comic.copyWith(
          description: detail.description,
          status: detail.status,
          totalChapters: detail.totalChapters,
          author: detail.author,
          alias: detail.alias,
          tags: detail.tags,
          rating: detail.rating,
          popular: detail.popular,
          updateTime: detail.updateTime,
          sourceId: detail.sourceId ?? source.id,
        );
        // 章节按源站原始 order 排序，方向由源决定，统一「第1话在前」；
        // 与下载管理页/离线阅读器顺序保持一致，避免阅读与下载顺序对不上
        for (final g in groups) {
          g.chapters.sort(
            (a, b) =>
                chapterCompare(a.order, b.order, source.chapterOrderDescending),
          );
        }
        _groups = groups;
        _selectedGroupIndex = 0;
        _showAllChapters = false;
      });
      // 回填书架快照：用所有分组章节之和作为 totalChapters（与下载范围一致），
      // 供书架判断下载完整度与显示。与收藏解耦，直接写各书架 meta。
      // 同时更新 _comic：detail 接口的 totalChapters 常缺失，改用分组之和，
      // 使后续下载面板携带可靠的 totalChapters 写入下载快照。
      _comic = _comic.copyWith(totalChapters: _totalChapters);
      await BookshelfService().updateItemMeta(
        _comic.pathWord,
        BookshelfItemType.comic,
        jsonEncode(_comic.toJson()),
      );
      // 用户打开详情 = 已阅当前全部章节 → 更新角标清零
      unawaited(
        ShelfUpdateService.instance.ack(
          ShelfUpdateService.keyForComic(_comic.pathWord),
          _totalChapters,
        ),
      );
    } catch (e) {
      _log('加载失败: $e');
      if (!mounted) return; // 页面已销毁，不更新 UI
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _onChapterTap(ComicChapter chapter) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            ReaderPage(comic: _comic, chapter: chapter, groups: _groups),
      ),
    );
  }

  /// 续读章节：从阅读进度取上次章节，在 _groups 中查找；无则 null（不显示续读按钮）
  ComicChapter? get _continueChapter {
    final rp = ReadingProgressService().getProgress(_comic.pathWord);
    if (rp == null) return null;
    for (final g in _groups) {
      for (final c in g.chapters) {
        if (c.id == rp.lastChapterId) return c;
      }
    }
    return null;
  }

  void _selectGroup(int index) {
    if (index == _selectedGroupIndex) return;
    setState(() {
      _selectedGroupIndex = index;
      _showAllChapters = false; // 切换分组重置展开状态
    });
  }

  /// 所有分组的章节总数
  int get _totalChapters =>
      _groups.fold<int>(0, (sum, g) => sum + g.chapters.length);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: _buildBackToTopButton(),
      body: Stack(
        fit: StackFit.expand,
        children: [
          const RepaintBoundary(child: ThemeBackgroundAnimation()),
          CustomScrollView(
            controller: _scrollController,
            slivers: [
              _buildAppBar(),
              // 头部信息使用入参 comic 立即渲染，不阻塞于加载
              _buildHeader(),
              if (_isLoading)
                _buildChapterLoading()
              else if (_error != null)
                _buildChapterError()
              else ...[
                _buildChapterSummary(),
                ..._buildChapterList(),
              ],
            ],
          ),
        ],
      ),
    );
  }

  SliverAppBar _buildAppBar() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return SliverAppBar(
      pinned: true,
      centerTitle: true,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      title: Text(
        '漫画详情',
        style: TextStyle(
          fontSize: AppTheme.fontHeadline,
          fontWeight: FontWeight.w600,
          color: titleColor,
        ),
      ),
      actions: [
        IconButton(
          tooltip: '更多',
          icon: Icon(Icons.chevron_right_rounded, color: titleColor),
          onPressed: _showMoreSheet,
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  /// 封面（带 Hero 共享元素过渡）
  Widget _buildCover(bool isDark) {
    final cover = Container(
      width: 110,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.08),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: AspectRatio(
          aspectRatio: 3 / 4,
          child: SourceCoverImage(
            url: _comic.cover,
            httpHeaders: coverHeaders(_comic.sourceId),
            fit: BoxFit.cover,
            placeholder: (c, u) => Container(
              color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
            ),
            errorWidget: (c, u, e) => Container(
              color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
              child: Icon(
                Icons.broken_image,
                size: 40,
                color: JellyTheme.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
    final tag = widget.heroTag;
    return tag == null ? cover : Hero(tag: tag, child: cover);
  }

  /// 章节加载中（头部信息已用入参渲染，仅章节区显示加载动画）
  SliverFillRemaining _buildChapterLoading() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: JellyTheme.primary),
            SizedBox(height: 16),
            Text(
              '加载中...',
              style: TextStyle(
                color: isDark ? _darkSecondary : JellyTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 章节加载失败
  SliverFillRemaining _buildChapterError() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 40, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              '加载失败: $_error',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark ? _darkSecondary : JellyTheme.textPrimaryLight,
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadData, child: const Text('重试')),
          ],
        ),
      ),
    );
  }

  /// 顶部头部区：左封面 + 右元信息，下方简介
  SliverToBoxAdapter _buildHeader() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final secondaryColor = isDark ? _darkSecondary : JellyTheme.textSecondary;

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 封面（Hero 共享元素过渡）
                _buildCover(isDark),
                const SizedBox(width: 14),
                // 元信息
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _comic.title,
                        style: TextStyle(
                          fontSize: AppTheme.fontTitle2,
                          fontWeight: FontWeight.bold,
                          color: titleColor,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      // 评分徽标
                      if (_comic.rating != null && _comic.rating! > 0) ...[
                        const SizedBox(height: 6),
                        JellyScoreBadge(comic: _comic, isDark: isDark),
                      ],
                      // 题材标签
                      if (_comic.tags != null && _comic.tags!.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: _comic.tags!
                              .take(4)
                              .map((t) => _buildTagChip(t, isDark))
                              .toList(),
                        ),
                      ],
                      // 作者（可点 → 搜索作者的其他漫画）
                      if (_comic.author != null &&
                          _comic.author!.trim().isNotEmpty) ...[
                        const SizedBox(height: 8),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _showAuthorSheet,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.person_outline,
                                size: 15,
                                color: secondaryColor,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  _comic.author!.trim(),
                                  style: TextStyle(
                                    fontSize: AppTheme.fontSubhead,
                                    color: secondaryColor,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      // 连载状态胶囊
                      if (_comic.status != null &&
                          _comic.status!.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _buildStatusChip(_comic.status!, isDark),
                      ],
                      // 热度/人气
                      if (_comic.popular != null && _comic.popular! > 0) ...[
                        const SizedBox(height: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.people_outline,
                              size: 15,
                              color: secondaryColor,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _formatPopular(_comic.popular!),
                              style: TextStyle(
                                fontSize: AppTheme.fontSubhead,
                                color: secondaryColor,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            // 收藏 / 书架 / 下载 胶囊按钮（右对齐）
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _buildFavoriteCapsule(),
                const SizedBox(width: 8),
                _buildBookshelfCapsule(),
                const SizedBox(width: 8),
                _buildCapsuleButton(
                  icon: Icons.download_for_offline,
                  label: '下载',
                  onTap: _openDownloadSheet,
                ),
              ],
            ),
            // 简介（漫画详情）
            if (_comic.description != null &&
                _comic.description!.isNotEmpty) ...[
              const SizedBox(height: 18),
              _buildSynopsis(titleColor, secondaryColor),
            ],
          ],
        ),
      ),
    );
  }

  /// 人气数值格式化（≥1万 显示「x.x万」）
  String _formatPopular(int popular) {
    if (popular >= 10000) {
      return '${(popular / 10000).toStringAsFixed(1)}万';
    }
    return popular.toString();
  }

  /// 胶囊按钮（左图标 + 右文字）。
  /// 不传 [color] 时用"三深灰按钮"样式（参考图 IMG_8471）；传强调色时文字白。
  Widget _buildCapsuleButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = color ??
        (isDark
            ? Colors.white.withValues(alpha: 0.14)
            : Colors.black.withValues(alpha: 0.10));
    final fg = color != null
        ? Colors.white
        : (isDark ? _darkSecondary : JellyTheme.textPrimaryLight);
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: fg),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  color: fg,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 续读胶囊按钮：跳到上次阅读章节（章节统计行右侧，有阅读进度时显示）
  Widget _buildContinueCapsule() {
    return _buildCapsuleButton(
      icon: Icons.play_arrow_rounded,
      label: '续读',
      color: JellyTheme.primary,
      onTap: () {
        final rp = ReadingProgressService().getProgress(_comic.pathWord);
        final chapter = _continueChapter;
        if (rp == null || chapter == null) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ReaderPage(
              comic: _comic,
              chapter: chapter,
              groups: _groups,
              initialPage: rp.lastPageIndex,
            ),
          ),
        );
      },
    );
  }

  /// 收藏胶囊按钮（跟随收藏状态切换图标/文案/颜色）
  Widget _buildFavoriteCapsule() {
    return ListenableBuilder(
      listenable: FavoritesService(),
      builder: (context, _) {
        final fav = FavoritesService().isFavorite(_comic.id);
        return _buildCapsuleButton(
          icon: fav ? Icons.favorite : Icons.favorite_border,
          label: fav ? '已收藏' : '收藏',
          color: fav ? const Color(0xFFFF8B94) : JellyTheme.primary,
          onTap: () {
            FavoritesService().toggle(_comic);
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  content: Text(fav ? '已取消收藏' : '已收藏'),
                  duration: const Duration(seconds: 2),
                  behavior: SnackBarBehavior.floating,
                ),
              );
          },
        );
      },
    );
  }

  /// 加入书架胶囊按钮
  Widget _buildBookshelfCapsule() {
    return ListenableBuilder(
      listenable: BookshelfService(),
      builder: (context, _) {
        final inShelf = BookshelfService()
            .getBookshelvesForItem(_comic.pathWord, BookshelfItemType.comic)
            .isNotEmpty;
        return _buildCapsuleButton(
          icon: inShelf
              ? Icons.library_books_rounded
              : Icons.library_add_rounded,
          label: inShelf ? '已加书架' : '书架',
          color: inShelf ? const Color(0xFF7C8CFF) : JellyTheme.primary,
          onTap: () async {
            final hasReadingProgress =
                ReadingProgressService().getProgress(_comic.pathWord) != null;
            final result = await showBookshelfDialog(
              context,
              itemId: _comic.pathWord,
              type: BookshelfItemType.comic,
              title: '加入书架',
              meta: jsonEncode(_comic.toJson()),
              disabledShelfIds: hasReadingProgress
                  ? null
                  : {BookshelfService.presetReading},
            );
            if (result != null && mounted) {
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(
                  SnackBar(
                    content: Text(
                      result.isEmpty ? '已从所有书架移除' : '已加入 ${result.length} 个书架',
                    ),
                    duration: const Duration(seconds: 2),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
            }
          },
        );
      },
    );
  }

  /// 打开下载章节选择弹窗（当前分组）
  void _openDownloadSheet() {
    if (_groups.isEmpty) return;
    final group = _groups[_selectedGroupIndex.clamp(0, _groups.length - 1)];
    if (group.chapters.isEmpty) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => kbSheet(DownloadChapterSheet(
        comic: _comic,
        chapters: group.chapters,
        groupName: group.name,
      )),
    );
  }

  /// 底部弹层：搜索作者的其他漫画（聚搜 / 当前漫画源 / 取消）
  Future<void> _showAuthorSheet() async {
    final author = _comic.author?.trim() ?? '';
    if (author.isEmpty) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final secondaryColor = isDark ? _darkSecondary : JellyTheme.textSecondary;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => kbSheet(
        Container(
          decoration: BoxDecoration(
            color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sheetHandle(),
              const SizedBox(height: 10),
              Text(
                '搜索作者的其他漫画',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.bold,
                  color: titleColor,
                ),
              ),
              const SizedBox(height: 14),
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.10)
                        : Colors.black.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    author,
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600,
                      color: secondaryColor,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: _sheetActionButton(
                      label: '聚搜',
                      filled: true,
                      onTap: () {
                        Navigator.of(sheetCtx).pop();
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ComicAggregateSearchPage(),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _sheetActionButton(
                      label: '当前漫画源',
                      onTap: () {
                        Navigator.of(sheetCtx).pop();
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const SearchPage(
                              isActive: true,
                              showBackButton: true,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _sheetActionButton(
                      label: '取消',
                      onTap: () => Navigator.of(sheetCtx).pop(),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 右上角「更多」弹层：换源 / 刷新章节
  void _showMoreSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => kbSheet(
        Container(
          decoration: BoxDecoration(
            color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sheetHandle(),
              const SizedBox(height: 4),
              ListTile(
                leading: Icon(Icons.swap_horiz_rounded, color: titleColor),
                title: Text(
                  '换源',
                  style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    color: titleColor,
                  ),
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ComicAggregateSearchPage(),
                    ),
                  );
                },
              ),
              ListTile(
                leading: Icon(Icons.refresh_rounded, color: titleColor),
                title: Text(
                  '刷新章节',
                  style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    color: titleColor,
                  ),
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _loadData();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 底部弹层顶部把手
  Widget _sheetHandle() {
    return Center(
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: JellyTheme.textSecondary.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }

  /// 作者弹层底部按钮（filled = 主色填充）
  Widget _sheetActionButton({
    required String label,
    required VoidCallback onTap,
    bool filled = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = filled
        ? JellyTheme.primary
        : (isDark
              ? Colors.white.withValues(alpha: 0.10)
              : Colors.black.withValues(alpha: 0.06));
    final fg = filled
        ? Colors.white
        : (isDark ? Colors.white : JellyTheme.textPrimaryLight);
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppTheme.fontBody,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusChip(String status, bool isDark) {
    final ongoing =
        status.contains('连载') || status.toLowerCase().contains('ongoing');
    final bg = ongoing
        ? JellyTheme.success
        : (isDark
              ? Colors.white.withValues(alpha: 0.12)
              : Colors.black.withValues(alpha: 0.06));
    final fg = ongoing
        ? Colors.white
        : (isDark ? _darkSecondary : JellyTheme.textSecondary);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        status,
        style: TextStyle(fontSize: AppTheme.fontFootnote, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }

  Widget _buildTagChip(String tag, bool isDark) {
    // 题材灰胶囊（参考图 IMG_8471）
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.10)
            : Colors.black.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        tag,
        style: TextStyle(
          fontSize: AppTheme.fontCaption,
          color: isDark ? _darkSecondary : JellyTheme.textSecondary,
        ),
      ),
    );
  }

  /// 简介兜底清洗：部分源（Venera 脚本 / Legado 转义 HTML）给的是富文本，
  /// 直接塞进 `Text` 会原样显示 `<span class="title">` 这类标签。
  String _plainSynopsis(String raw) {
    if (!raw.contains('<') && !raw.contains('&lt;')) return raw;
    var text = raw;
    try {
      text = html_parser.parse(raw).documentElement?.text ?? raw;
    } catch (_) {}
    // 二次转义（解析一次后仍是标签文本）再剥一层
    text = text.replaceAll(RegExp(r'<[^>]*>'), '');
    return text
        .replaceAll(RegExp(r'^简介\s*[:：]\s*'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Widget _buildSynopsis(Color titleColor, Color secondaryColor) {
    final desc = _plainSynopsis(_comic.description!);
    // 简介较长时提供展开/收起
    final likelyLong = desc.length > 60 || desc.contains('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '简介',
          style: TextStyle(
            fontSize: AppTheme.fontBody,
            fontWeight: FontWeight.w700,
            color: titleColor,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          desc,
          maxLines: _descExpanded ? null : 3,
          overflow: _descExpanded ? TextOverflow.clip : TextOverflow.ellipsis,
          style: TextStyle(fontSize: AppTheme.fontSubhead, height: 1.5, color: secondaryColor),
        ),
        if (likelyLong)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() => _descExpanded = !_descExpanded),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                _descExpanded ? '收起' : '展开',
                style: const TextStyle(fontSize: AppTheme.fontFootnote),
              ),
            ),
          ),
      ],
    );
  }

  /// 章节区头部行：标题 + 共N话 + 续读胶囊 + 刷新/排序按钮
  SliverToBoxAdapter _buildChapterSummary() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final secondaryColor = isDark ? _darkSecondary : JellyTheme.textSecondary;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Row(
          children: [
            Text(
              '章节',
              style: TextStyle(
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.bold,
                color: titleColor,
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, size: 18, color: secondaryColor),
            const SizedBox(width: 4),
            Text(
              '共 $_totalChapters 话',
              style: TextStyle(
                fontSize: AppTheme.fontSubhead,
                color: JellyTheme.textSecondary,
              ),
            ),
            if (_continueChapter != null) ...[
              const SizedBox(width: 10),
              _buildContinueCapsule(),
            ],
            const Spacer(),
            _buildIconAction(
              icon: Icons.refresh_rounded,
              tooltip: '刷新章节',
              onTap: _isLoading ? null : _loadData,
            ),
            _buildIconAction(
              icon: Icons.swap_vert_rounded,
              tooltip: _descending ? '正序' : '倒序',
              color: _descending ? JellyTheme.primary : null,
              onTap: () => setState(() => _descending = !_descending),
            ),
          ],
        ),
      ),
    );
  }

  /// 章节区头部的小图标按钮（紧凑）
  Widget _buildIconAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    Color? color,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = color ?? (isDark ? _darkSecondary : JellyTheme.textSecondary);
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, size: 20, color: fg),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
    );
  }

  /// 分组切换 + 章节列表
  List<Widget> _buildChapterList() {
    final slivers = <Widget>[];
    if (_groups.isEmpty) return slivers;

    // 分组选择器（有分组即显示，单分组时作为当前分组指示）
    if (_groups.isNotEmpty) {
      slivers.add(_buildGroupSelector());
    }

    final index = _selectedGroupIndex.clamp(0, _groups.length - 1);
    final group = _groups[index];
    final chapters = group.chapters;
    // 展示顺序：默认「第1话在前」，_descending 时反转为「最新在前」。
    // 列表已实体化，点击下标 i 即 display[i]，天然映射回真实章节。
    final display = _descending ? chapters.reversed.toList() : chapters;
    final lastReadId = ReadingProgressService()
        .getProgress(_comic.pathWord)
        ?.lastChapterId;
    final visibleCount = _showAllChapters
        ? display.length
        : display.length.clamp(0, _defaultVisibleChapters);
    final hasMore = display.length > _defaultVisibleChapters;

    slivers.add(
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4, // 4 列网格（参考图 IMG_8471）
            childAspectRatio: 1.9,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          delegate: SliverChildBuilderDelegate((context, index) {
            final chapter = display[index];
            final isDark = Theme.of(context).brightness == Brightness.dark;
            final downloaded = DownloadService().isChapterDownloaded(
              _comic.pathWord,
              chapter.id,
            );
            final isLastRead = lastReadId == chapter.id;
            return Stack(
              fit: StackFit.expand,
              children: [
                OutlinedButton(
                  onPressed: () => _onChapterTap(chapter),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 6,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    side: BorderSide(
                      color: isDark ? _darkSecondary : Colors.black38,
                    ),
                  ),
                  child: Text(
                    chapter.title,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: AppTheme.fontCaption,
                      height: 1.15,
                    ),
                  ),
                ),
                if (isLastRead)
                  Positioned(
                    left: 3,
                    top: 3,
                    child: Icon(
                      Icons.bookmark_rounded,
                      size: 12,
                      color: JellyTheme.blue,
                    ),
                  ),
                if (downloaded)
                  Positioned(
                    right: 3,
                    top: 3,
                    child: Icon(
                      Icons.check_circle,
                      size: 12,
                      color: JellyTheme.success,
                    ),
                  ),
              ],
            );
          }, childCount: visibleCount),
        ),
      ),
    );

    // 显示全部 / 收起
    if (hasMore) {
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Center(
              child: TextButton.icon(
                onPressed: () =>
                    setState(() => _showAllChapters = !_showAllChapters),
                icon: Icon(
                  _showAllChapters
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 18,
                ),
                label: Text(
                  _showAllChapters ? '收起' : '显示全部（共 ${chapters.length} 话）',
                ),
              ),
            ),
          ),
        ),
      );
    } else {
      slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 16)));
    }

    return slivers;
  }

  /// 横向可滚动的分组选择器
  SliverToBoxAdapter _buildGroupSelector() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: SizedBox(
          height: 38,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _groups.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final g = _groups[index];
              final selected = index == _selectedGroupIndex;
              return GestureDetector(
                onTap: () => _selectGroup(index),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: selected
                        ? JellyTheme.primary
                        : (isDark
                              ? Colors.white.withValues(alpha: 0.06)
                              : Colors.white),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: selected
                          ? JellyTheme.primary
                          : (isDark ? Colors.white24 : Colors.black12),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${g.name} (${g.chapters.length})',
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected
                          ? Colors.white
                          : (isDark
                                ? _darkSecondary
                                : JellyTheme.textSecondary),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// 悬浮返回顶部按钮（带出现/消失动画，同搜索页）
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
          // ⛔ **有意不同、不要"统一"成 `AppIconButton`** ✗✓（与 `bookshelf_page` /
          //   `book_search_page` / `download_page` 的返回顶部钮**同款** ✓）：
          //   它是**滚动出现的悬浮 FAB** ✓（`primary` + `elevation: 4` 醒目 ✓），
          //   不是顶栏同族圆钮 ✗ → 换"淡圆底"会几乎看不见 ✗✗
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
}
