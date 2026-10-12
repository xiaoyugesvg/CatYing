import 'dart:math' show min;

import 'package:flutter/material.dart';
import '../models/book.dart';
import '../models/book_source.dart';
import '../models/comic.dart';
import '../services/book_favorites_service.dart';
import '../services/book_reading_progress_service.dart';
import '../services/book_source_service.dart';
import '../services/browse_history_service.dart';
import '../services/favorites_service.dart';
import '../services/reading_progress_service.dart';
import '../source/source_manager.dart';
import '../theme/jelly_theme.dart';
import '../utils/list_pagination.dart';
import '../widgets/jelly_book_card.dart' show bookCoverHeroTag;
import '../widgets/jelly_search_bar.dart';
import '../widgets/jelly_segmented_toggle.dart';
import '../widgets/source_cover_image.dart';
import '../../common/theme.dart';
import 'book_detail_page.dart';
import 'book_source_detail_page.dart';
import 'comic_detail_page.dart';

/// 足迹（浏览历史）页。
///
/// 顶部行：漫画 / 图书 分段切换 + 搜索框 + 管理按钮；
/// 下方：「共 N 条」计数 + 卡片列表。
/// 数据来源保持 [BrowseHistoryService]（漫画/图书浏览记录），只调整 UI 呈现。
class BrowseHistoryPage extends StatefulWidget {
  /// true：从「我的」进入（分段默认漫画）；false：足迹入口（分段默认图书）。
  final bool showTabs;

  /// 图书足迹模式（默认选中图书分段）。
  final bool bookOnly;

  const BrowseHistoryPage({
    super.key,
    this.showTabs = true,
    this.bookOnly = false,
  });

  @override
  State<BrowseHistoryPage> createState() => _BrowseHistoryPageState();
}

class _BrowseHistoryPageState extends State<BrowseHistoryPage> {
  static const _pageSize = 20;

  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  /// 0 = 漫画，1 = 图书
  late int _segment;
  String _keyword = '';
  int _displayCount = _pageSize;

  @override
  void initState() {
    super.initState();
    _segment = widget.bookOnly ? 1 : (widget.showTabs ? 0 : 1);
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  bool get _isComic => _segment == 0;

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final total = _isComic
        ? _filteredComics().length
        : _filteredBooks().length;
    if (ListPagination.shouldLoadMore(_scrollController) &&
        _displayCount < total) {
      setState(() => _displayCount += _pageSize);
    }
  }

  /// 漫画记录过滤（按名称/作者/别名）
  List<Comic> _filteredComics() {
    final comics = BrowseHistoryService().comics;
    if (_keyword.trim().isEmpty) return comics;
    final kw = _keyword.trim().toLowerCase();
    return comics
        .where(
          (c) =>
              c.title.toLowerCase().contains(kw) ||
              (c.author ?? '').toLowerCase().contains(kw) ||
              (c.alias ?? '').toLowerCase().contains(kw),
        )
        .toList();
  }

  /// 图书记录过滤（按书名/作者/来源名）
  List<Book> _filteredBooks() {
    final books = BrowseHistoryService().books;
    if (_keyword.trim().isEmpty) return books;
    final kw = _keyword.trim().toLowerCase();
    return books
        .where(
          (b) =>
              b.title.toLowerCase().contains(kw) ||
              (b.author ?? '').toLowerCase().contains(kw) ||
              (b.sourceName ?? '').toLowerCase().contains(kw),
        )
        .toList();
  }

  void _onKeywordChanged(String v) {
    setState(() {
      _keyword = v;
      _displayCount = _pageSize;
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    });
  }

  void _onCleared() {
    _searchController.clear();
    setState(() {
      _keyword = '';
      _displayCount = _pageSize;
    });
  }

  void _onSegmentChanged(int i) {
    if (i == _segment) return;
    setState(() {
      _segment = i;
      _displayCount = _pageSize;
      if (_scrollController.hasClients) _scrollController.jumpTo(0);
    });
  }

  /// 漫画已读百分比：优先按已读章节数/总章节数；读完记 100%；无数据记 0%。
  int _comicProgress(Comic c) {
    final p = ReadingProgressService().getProgress(c.pathWord);
    if (p == null) return 0;
    if (p.finished) return 100;
    final total = c.totalChapters;
    if (total != null && total > 0) {
      return ((p.seenChapterIds.length / total) * 100).clamp(0, 100).toInt();
    }
    return 0;
  }

  /// 图书已读百分比：页维度（与阅读器 HUD 一致）；取不到记 0%。
  int _bookProgress(Book b) {
    final p = BookReadingProgressService().getProgress(b.id);
    if (p == null || p.pageTotal <= 0) return 0;
    return (((p.pageIndex + 1) / p.pageTotal) * 100).clamp(0, 100).toInt();
  }

  void _openComic(Comic comic) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ComicDetailPage(
          comic: comic,
          heroTag: comicCoverHeroTag('history', comic),
        ),
      ),
    );
  }

  void _openBook(Book book) {
    // 书源体系的书：回到书源详情页继续阅读（源已删则兜底 zlib 详情页）
    if (book.isBookSource) {
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
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BookDetailPage(
          book: book,
          heroTag: bookCoverHeroTag('history', book),
        ),
      ),
    );
  }

  /// 按存的 sourceId 找回书源（兼容旧记录：sourceId 缺失时按源名匹配）；
  /// 源已删除时返回 null（兜底走 zlib 详情页）
  BookSource? _matchBookSource(Book book) {
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.showTabs ? '浏览记录' : '足迹'),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          BrowseHistoryService(),
          FavoritesService(),
          BookFavoritesService(),
          ReadingProgressService(),
          BookReadingProgressService(),
        ]),
        builder: (context, _) {
          final comics = _filteredComics();
          final books = _filteredBooks();
          final total = _isComic ? comics.length : books.length;
          return Column(
            children: [
              _buildSearchRow(),
              ListPaginationCountBar(total: total, unit: '条'),
              Expanded(
                child: total == 0
                    ? _buildEmpty(
                        text: _keyword.trim().isEmpty ? '暂无浏览记录' : '没有找到相关记录',
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                        itemCount: min(total, _displayCount),
                        itemBuilder: (context, index) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _isComic
                                ? _buildComicCard(comics[index], context)
                                : _buildBookCard(books[index], context),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 顶部行：分段切换 + 搜索框 + 管理按钮
  Widget _buildSearchRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Row(
        children: [
          JellySegmentedToggle(
            index: _segment.toDouble(),
            onChanged: _onSegmentChanged,
            segmentWidth: 34,
            height: 44,
            segments: const [
              JellySegmentData(icon: Icons.palette_rounded),
              JellySegmentData(icon: Icons.menu_book_rounded),
            ],
          ),
          const SizedBox(width: 8),
          Expanded(
            child: JellySearchBar(
              controller: _searchController,
              hintText: _isComic ? '搜索漫画' : '搜索图书',
              onChanged: _onKeywordChanged,
              onCleared: _onCleared,
            ),
          ),
          const SizedBox(width: 8),
          _buildManageButton(),
        ],
      ),
    );
  }

  /// 方形管理按钮（点击清理当前分段的浏览记录）
  Widget _buildManageButton() {
    return Material(
      color: JellyTheme.primary,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showCleanSheet(isComic: _isComic),
        child: const SizedBox(
          width: 44,
          height: 44,
          child: Icon(Icons.folder_rounded, color: Colors.white, size: 22),
        ),
      ),
    );
  }

  Widget _buildComicCard(Comic comic, BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? JellyTheme.cardDark : JellyTheme.cardLight;
    final hasSource = comic.sourceId != null && comic.sourceId!.isNotEmpty;
    final sourceName = hasSource
        ? SourceManager().getSource(comic.sourceId!)?.name
        : null;
    return _HistoryCard(
      cover: Hero(
        tag: comicCoverHeroTag('history', comic),
        child: Stack(
          fit: StackFit.expand,
          children: [
            SourceCoverImage(
              url: comic.cover,
              httpHeaders: coverHeaders(comic.sourceId),
              fit: BoxFit.cover,
              memCacheWidth: 200,
              placeholder: (c, u) => ColoredBox(
                color: cardColor,
                child: Center(
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: JellyTheme.primary,
                  ),
                ),
              ),
              errorWidget: (c, u, e) => ColoredBox(
                color: cardColor,
                child: Icon(
                  Icons.broken_image,
                  color: JellyTheme.textSecondary,
                ),
              ),
            ),
            if (sourceName != null && sourceName.isNotEmpty)
              _overlayTag(sourceName),
          ],
        ),
      ),
      title: comic.title,
      author: comic.author,
      progressText: '已读 ${_comicProgress(comic)}%',
      online: hasSource,
      favorite: _HeartButton(
        listenable: FavoritesService(),
        isFav: () => FavoritesService().isFavorite(comic.id),
        onToggle: () => FavoritesService().toggle(comic),
      ),
      onTap: () => _openComic(comic),
    );
  }

  Widget _buildBookCard(Book book, BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark ? JellyTheme.cardDark : JellyTheme.cardLight;
    final coverUrl = book.cover ?? '';
    final sourceName = book.sourceName;
    return _HistoryCard(
      cover: Hero(
        tag: bookCoverHeroTag('history', book),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (coverUrl.isEmpty)
              ColoredBox(
                color: cardColor,
                child: Icon(
                  Icons.menu_book_rounded,
                  color: JellyTheme.textSecondary,
                ),
              )
            else
              SourceCoverImage(
                url: coverUrl,
                fit: BoxFit.cover,
                memCacheWidth: 200,
                placeholder: (c, u) => ColoredBox(
                  color: cardColor,
                  child: Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: JellyTheme.primary,
                    ),
                  ),
                ),
                errorWidget: (c, u, e) => ColoredBox(
                  color: cardColor,
                  child: Icon(
                    Icons.broken_image,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ),
            if (sourceName != null && sourceName.isNotEmpty)
              _overlayTag(sourceName),
          ],
        ),
      ),
      title: book.title,
      author: book.author,
      progressText: '已读 ${_bookProgress(book)}%',
      online: book.isBookSource || (book.readOnlineUrl?.isNotEmpty ?? false),
      favorite: _HeartButton(
        listenable: BookFavoritesService(),
        isFav: () => BookFavoritesService().isFavorite(book.id),
        onToggle: () => BookFavoritesService().toggle(book),
      ),
      onTap: () => _openBook(book),
    );
  }

  /// 封面左上角来源名标签（半透明灰底白字）
  Widget _overlayTag(String name) {
    return Positioned(
      top: 2,
      left: 2,
      right: 2,
      child: Align(
        alignment: Alignment.topLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 9,
              color: Colors.white,
              height: 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  /// 清理选项：所有 / 一周前 / 一月前
  void _showCleanSheet({required bool isComic}) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        Widget option(String label, int? beforeTs) => ListTile(
          title: Text(label),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () {
            Navigator.pop(ctx);
            _confirmClean(isComic: isComic, beforeTs: beforeTs, label: label);
          },
        );
        final now = DateTime.now().millisecondsSinceEpoch;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              option('所有', null),
              option('一周前', now - const Duration(days: 7).inMilliseconds),
              option('一月前', now - const Duration(days: 30).inMilliseconds),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmClean({
    required bool isComic,
    required int? beforeTs,
    required String label,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清理浏览记录'),
        content: Text('确定清理「$label」的${isComic ? '漫画' : '图书'}浏览记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (isComic) {
      await BrowseHistoryService().clearComics(beforeTs: beforeTs);
    } else {
      await BrowseHistoryService().clearBooks(beforeTs: beforeTs);
    }
  }
}

/// 足迹卡片（横向：封面 + 信息 + ONLINE + 收藏）
class _HistoryCard extends StatelessWidget {
  const _HistoryCard({
    required this.cover,
    required this.title,
    required this.author,
    required this.progressText,
    required this.online,
    required this.favorite,
    required this.onTap,
  });

  final Widget cover;
  final String title;
  final String? author;
  final String progressText;
  final bool online;
  final Widget favorite;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final subColor = isDark ? Colors.white54 : JellyTheme.textSecondary;
    final hasAuthor = author != null && author!.isNotEmpty;

    return Material(
      color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(width: 60, height: 80, child: cover),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.w700,
                        color: titleColor,
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (hasAuthor)
                      Text(
                        author!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTheme.fontFootnote,
                          color: subColor,
                        ),
                      ),
                    if (hasAuthor) const SizedBox(height: 6),
                    Text(
                      progressText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTheme.fontCaption,
                        color: subColor,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (online)
                    Text(
                      'ONLINE',
                      style: TextStyle(
                        fontSize: AppTheme.fontCaption - 2,
                        color: subColor,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                  const SizedBox(height: 12),
                  favorite,
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 心形收藏按钮（复用现有收藏服务）
class _HeartButton extends StatelessWidget {
  const _HeartButton({
    required this.listenable,
    required this.isFav,
    required this.onToggle,
  });

  final Listenable listenable;
  final bool Function() isFav;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) {
        final fav = isFav();
        return GestureDetector(
          onTap: onToggle,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, anim) =>
                  ScaleTransition(scale: anim, child: child),
              child: Icon(
                fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                key: ValueKey(fav),
                color: fav ? JellyTheme.error : JellyTheme.primary,
                size: 22,
              ),
            ),
          ),
        );
      },
    );
  }
}

Widget _buildEmpty({String text = '暂无浏览记录'}) {
  return Center(
    child: Text(
      text,
      style: TextStyle(
        fontSize: AppTheme.fontBody,
        color: JellyTheme.textSecondary,
      ),
    ),
  );
}
