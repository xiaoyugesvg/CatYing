import 'dart:math' show min;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common/theme.dart';
import '../models/book_source.dart';
import '../models/comic.dart';
import '../services/book_download_service.dart';
import '../services/book_reading_progress_service.dart';
import '../services/book_source_download_service.dart';
import '../services/book_source_service.dart';
import '../services/download_service.dart';
import '../services/platform_service.dart';
import '../services/settings_service.dart';
import '../theme/jelly_theme.dart';
import '../utils/list_pagination.dart';
import '../widgets/jelly_search_bar.dart';
import 'book_reader_page.dart';
import 'book_source_detail_page.dart';
import 'reader_page.dart';

/// 下载记录页（参考目标界面 IMG_8397）：
/// 分段切换（漫画 | 图书）+ 搜索框 + 5 个状态胶囊
/// （下载中/已下载/失败/已暂停/已取消）+ 共 N 本统计 + 任务列表 / 空态「该状态下暂无记录」。
///
/// 从图书页聚合菜单「下载」进入；底部导航的「下载」管理页保持原样。
/// 「图书」段 = 图书下载任务（[BookDownloadService]）；
/// 「漫画」段 = 漫画下载任务（[DownloadService]）。
class BookDownloadRecordsPage extends StatefulWidget {
  const BookDownloadRecordsPage({super.key});

  @override
  State<BookDownloadRecordsPage> createState() =>
      _BookDownloadRecordsPageState();
}

class _BookDownloadRecordsPageState extends State<BookDownloadRecordsPage> {
  static const _tabs = ['下载中', '已下载', '失败', '已暂停', '已取消'];

  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  String _keyword = '';
  int _statusIndex = 0;
  int _displayCount = ListPagination.pageSize;

  /// 分段：0=漫画，1=图书（默认图书，保持本页原有行为）
  int _segment = 1;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final total =
        _segment == 0 ? _filteredComic().length : _filtered().length;
    if (ListPagination.shouldLoadMore(_scrollController) &&
        _displayCount < total) {
      setState(
        () =>
            _displayCount = min(_displayCount + ListPagination.pageSize, total),
      );
    }
  }

  /// 按状态 tab + 关键词过滤后的任务（最新在前）
  List<BookDownloadTask> _filtered() {
    var tasks = BookDownloadService().tasks.values.toList().reversed.toList();
    switch (_statusIndex) {
      case 0:
        tasks = tasks
            .where(
              (t) =>
                  t.status == BookDownloadStatus.queued ||
                  t.status == BookDownloadStatus.downloading,
            )
            .toList();
      case 1:
        tasks = tasks
            .where((t) => t.status == BookDownloadStatus.completed)
            .toList();
      case 2:
        tasks = tasks
            .where((t) => t.status == BookDownloadStatus.failed)
            .toList();
      case 3:
        tasks = tasks
            .where((t) => t.status == BookDownloadStatus.paused)
            .toList();
      case 4:
        // 已取消：任务取消即移除，无持久化状态 → 该 tab 恒为空态
        tasks = const [];
    }
    final kw = _keyword.trim().toLowerCase();
    if (kw.isNotEmpty) {
      tasks = tasks
          .where(
            (t) =>
                t.title.toLowerCase().contains(kw) ||
                (t.author?.toLowerCase().contains(kw) ?? false),
          )
          .toList();
    }
    return tasks;
  }

  /// 漫画下载任务：按状态 tab + 关键词过滤（最新在前）——复用 [DownloadService]
  List<DownloadTask> _filteredComic() {
    var tasks = DownloadService().tasks.values.toList().reversed.toList();
    switch (_statusIndex) {
      case 0:
        tasks = tasks
            .where(
              (t) =>
                  t.status == DownloadStatus.queued ||
                  t.status == DownloadStatus.downloading,
            )
            .toList();
      case 1:
        tasks = tasks
            .where((t) => t.status == DownloadStatus.completed)
            .toList();
      case 2:
        tasks = tasks
            .where((t) => t.status == DownloadStatus.failed)
            .toList();
      case 3:
        tasks = tasks
            .where((t) => t.status == DownloadStatus.paused)
            .toList();
      case 4:
        // 已取消：任务取消即移除，无持久化状态 → 该 tab 恒为空态
        tasks = const [];
    }
    final kw = _keyword.trim().toLowerCase();
    if (kw.isNotEmpty) {
      tasks = tasks
          .where(
            (t) =>
                t.comicTitle.toLowerCase().contains(kw) ||
                t.chapterTitle.toLowerCase().contains(kw),
          )
          .toList();
    }
    return tasks;
  }

  Future<void> _openDownloadDir() async {
    final dir = await SettingsService.downloadBaseDir();
    final ok = await PlatformService.openDirectory(dir.path);
    if (ok) return;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('下载目录'),
        content: SelectableText(
          '无法直接打开文件管理器，请手动前往：\n${dir.path}',
          style: const TextStyle(fontSize: AppTheme.fontSubhead),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: dir.path));
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('复制路径'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: const Text('下载记录'),
        centerTitle: true,
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([
          BookDownloadService(),
          BookSourceDownloadService.instance.revision,
          DownloadService(),
        ]),
        builder: (context, _) {
          final isComic = _segment == 0;
          final comicTasks =
              isComic ? _filteredComic() : const <DownloadTask>[];
          final bookTasks = isComic ? const <BookDownloadTask>[] : _filtered();
          final count = isComic ? comicTasks.length : bookTasks.length;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 搜索行：分段切换（漫画|图书）+ 搜索框 + 右侧方形文件夹图标
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
                child: Row(
                  children: [
                    _buildSegmentSwitch(),
                    const SizedBox(width: 8),
                    Expanded(
                      child: JellySearchBar(
                        controller: _searchController,
                        hintText: isComic ? '搜索漫画' : '搜索图书',
                        onChanged: (v) => setState(() {
                          _keyword = v;
                          _displayCount = ListPagination.pageSize;
                        }),
                        onCleared: () => setState(() {
                          _keyword = '';
                          _displayCount = ListPagination.pageSize;
                        }),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _buildOpenDirButton(isDark),
                  ],
                ),
              ),
              _buildStatusTabs(isDark, count),
              if (!isComic) _buildSourceDownloads(isDark),
              // 「共 N 本」与上方状态区、下方列表拉开层次：淡分割线 + 留白
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
                child: Divider(
                  height: 1,
                  thickness: 1,
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.black.withValues(alpha: 0.05),
                ),
              ),
              ListPaginationCountBar(total: count, unit: '本'),
              Expanded(
                child: count == 0
                    ? _buildEmpty(isDark)
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(0, 4, 0, 16),
                        itemCount: isComic
                            ? min(comicTasks.length, _displayCount)
                            : min(bookTasks.length, _displayCount),
                        itemBuilder: (context, i) => isComic
                            ? _buildComicTaskTile(comicTasks[i], isDark)
                            : _buildTaskTile(bookTasks[i], isDark),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 分段切换：漫画（左）/ 图书（右）。选中项实底圆角高亮，未选中透明。
  Widget _buildSegmentSwitch() {
    return Container(
      height: 36,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildSegmentItem(0, Icons.auto_stories_rounded), // 漫画
          _buildSegmentItem(1, Icons.menu_book_rounded), // 图书
        ],
      ),
    );
  }

  Widget _buildSegmentItem(int index, IconData icon) {
    final selected = _segment == index;
    return GestureDetector(
      onTap: () => setState(() {
        _segment = index;
        _displayCount = ListPagination.pageSize;
      }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 34,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? JellyTheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          icon,
          size: 18,
          color: selected ? Colors.white : JellyTheme.textSecondary,
        ),
      ),
    );
  }

  Widget _buildOpenDirButton(bool isDark) {
    return Material(
      color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _openDownloadDir,
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(
            Icons.folder_open_rounded,
            size: 20,
            color: JellyTheme.textPrimaryLight,
          ),
        ),
      ),
    );
  }

  /// 书源「下载全书」区块：横滑卡片（封面 + 书名 + 源名·章数 + 删除）。
  /// 有记录才显示；点击卡片 → 回书源详情页继续阅读。
  Widget _buildSourceDownloads(bool isDark) {
    return FutureBuilder<List<BookSourceDownloadRecord>>(
      future: BookSourceDownloadService.instance.records(),
      builder: (context, snap) {
        final records = snap.data ?? const <BookSourceDownloadRecord>[];
        if (records.isEmpty) return const SizedBox.shrink();
        final titleColor =
            isDark ? Colors.white : JellyTheme.textPrimaryLight;
        final subColor = isDark ? Colors.white70 : JellyTheme.textSecondary;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
              child: Text(
                '书源下载',
                style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: FontWeight.w700,
                  color: titleColor,
                ),
              ),
            ),
            SizedBox(
              height: 96,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: records.length,
                separatorBuilder: (_, _) => const SizedBox(width: 10),
                itemBuilder: (context, i) {
                  final rec = records[i];
                  return _buildSourceDownloadCard(rec, isDark, titleColor,
                      subColor);
                },
              ),
            ),
            const SizedBox(height: 6),
          ],
        );
      },
    );
  }

  Widget _buildSourceDownloadCard(
    BookSourceDownloadRecord rec,
    bool isDark,
    Color titleColor,
    Color subColor,
  ) {
    return Material(
      color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openSourceDownload(rec),
        child: SizedBox(
          width: 210,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 48,
                    height: 66,
                    child: rec.cover.isEmpty
                        ? ColoredBox(
                            color: JellyTheme.primary.withValues(alpha: 0.15),
                            child: Icon(
                              Icons.menu_book_rounded,
                              size: 22,
                              color: JellyTheme.primary,
                            ),
                          )
                        : CachedNetworkImage(
                            imageUrl: rec.cover,
                            fit: BoxFit.cover,
                            errorWidget: (_, _, _) => ColoredBox(
                              color:
                                  JellyTheme.primary.withValues(alpha: 0.15),
                              child: Icon(
                                Icons.menu_book_rounded,
                                size: 22,
                                color: JellyTheme.primary,
                              ),
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        rec.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTheme.fontSubhead,
                          fontWeight: FontWeight.w600,
                          color: titleColor,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${rec.sourceName} · ${rec.chapterCount} 章',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTheme.fontFootnote,
                          color: subColor,
                        ),
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () async {
                    await BookSourceDownloadService.instance
                        .remove(rec.sourceId, rec.bookUrl);
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: subColor,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openSourceDownload(BookSourceDownloadRecord rec) {
    // 找回源：sourceId 优先，源名回退（兼容旧记录）；找不到 → 提示源已删除
    BookSource? src;
    if (rec.sourceId.isNotEmpty) {
      for (final s in BookSourceStore.instance.all) {
        if (s.id == rec.sourceId) {
          src = s;
          break;
        }
      }
    }
    if (src == null && rec.sourceName.isNotEmpty) {
      for (final s in BookSourceStore.instance.all) {
        if (s.name == rec.sourceName) {
          src = s;
          break;
        }
      }
    }
    if (src == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('该书源已不在仓库中，请重新导入后下载'),
          behavior: SnackBarBehavior.floating,
        ));
      return;
    }
    // 提升为非空局部量：`src` 在声明后被赋值过 ⇒ 在 `builder` 闭包内
    // 类型提升失效（仍视作 BookSource?）⇒ 必须另存一个 final 变量
    final source = src;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BookSourceDetailPage(
          result: BookSourceResult(
            source: source,
            name: rec.title,
            author: rec.author,
            bookUrl: rec.bookUrl,
            coverUrl: rec.cover,
          ),
        ),
      ),
    );
  }

  /// 状态标签行：5 个横向胶囊（选中实底高亮）+ 最右侧数字角标（当前选中状态条数）。
  Widget _buildStatusTabs(bool isDark, int count) {
    return SizedBox(
      height: 46,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Expanded(
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _tabs.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) =>
                    Center(child: _buildStatusPill(i, isDark)),
              ),
            ),
            const SizedBox(width: 10),
            _buildStatusBadge(count),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusPill(int i, bool isDark) {
    final selected = _statusIndex == i;
    // 未选中：淡色实底 + 细描边（两种主题下都能看清胶囊轮廓）
    final unselectedBg = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : JellyTheme.primary.withValues(alpha: 0.06);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : JellyTheme.primary.withValues(alpha: 0.18);
    return GestureDetector(
      onTap: () => setState(() {
        _statusIndex = i;
        _displayCount = ListPagination.pageSize;
      }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? JellyTheme.primary : unselectedBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? Colors.transparent : borderColor,
            width: 0.8,
          ),
        ),
        child: Text(
          _tabs[i],
          style: TextStyle(
            fontSize: AppTheme.fontSubhead,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected
                ? Colors.white
                : (isDark ? Colors.white70 : JellyTheme.textSecondary),
          ),
        ),
      ),
    );
  }

  /// 小数字角标：显示当前状态下的真实条数
  Widget _buildStatusBadge(int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: JellyTheme.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: AppTheme.fontCaption,
          fontWeight: FontWeight.w700,
          color: JellyTheme.primary,
        ),
      ),
    );
  }

  Widget _buildEmpty(bool isDark) {
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: JellyTheme.primary.withValues(alpha: isDark ? 0.12 : 0.08),
            ),
            child: Icon(
              Icons.inbox_rounded,
              size: 38,
              color: JellyTheme.primary.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '该状态下暂无记录',
            style: TextStyle(
              fontSize: AppTheme.fontBody,
              fontWeight: FontWeight.w600,
              color: titleColor,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '换个状态或关键词试试',
            style: TextStyle(
              fontSize: AppTheme.fontFootnote,
              color: JellyTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskTile(BookDownloadTask t, bool isDark) {
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final card = Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.05),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildCover(t.cover ?? '', isDark),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w700,
                      color: titleColor,
                    ),
                  ),
                  if (t.author != null && t.author!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      t.author!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTheme.fontFootnote,
                        color: JellyTheme.textSecondary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (t.extension != null && t.extension!.isNotEmpty) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: JellyTheme.primary.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            t.extension!.toUpperCase(),
                            style: TextStyle(
                              fontSize: AppTheme.fontCaption,
                              color: JellyTheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(
                          _statusText(t),
                          style: TextStyle(
                            fontSize: AppTheme.fontCaption,
                            color: _statusColor(t),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (t.status == BookDownloadStatus.downloading ||
                      t.status == BookDownloadStatus.queued) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: LinearProgressIndicator(
                        value: t.status == BookDownloadStatus.queued
                            ? null
                            : t.progress,
                        minHeight: 4,
                        backgroundColor:
                            (isDark ? Colors.white : Colors.black)
                                .withValues(alpha: 0.1),
                        color: JellyTheme.primary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            _buildTaskActions(t),
          ],
        ),
      ),
    );

    switch (t.status) {
      case BookDownloadStatus.completed:
        return GestureDetector(
          onTap: () => BookReaderPage.open(context, t),
          child: card,
        );
      case BookDownloadStatus.failed:
        return GestureDetector(
          onTap: () => _showFailureDetail(t),
          child: card,
        );
      default:
        return card;
    }
  }

  Widget _buildCover(String cover, bool isDark) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: CachedNetworkImage(
        imageUrl: cover,
        width: 48,
        height: 66,
        fit: BoxFit.cover,
        placeholder: (c, u) => Container(
          color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
          width: 48,
          height: 66,
        ),
        errorBuilder: (c, e, s) => Container(
          color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
          width: 48,
          height: 66,
          child: Icon(Icons.menu_book_rounded,
              size: 20, color: JellyTheme.textSecondary),
        ),
      ),
    );
  }

  Widget _buildTaskActions(BookDownloadTask t) {
    switch (t.status) {
      case BookDownloadStatus.queued:
      case BookDownloadStatus.downloading:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.pause_rounded, size: 20),
              tooltip: '暂停',
              visualDensity: VisualDensity.compact,
              onPressed: () => BookDownloadService().pauseTask(t.bookId),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 20),
              tooltip: '取消',
              visualDensity: VisualDensity.compact,
              onPressed: () => BookDownloadService().cancelTask(t.bookId),
            ),
          ],
        );
      case BookDownloadStatus.paused:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.play_arrow_rounded, size: 20),
              tooltip: '继续',
              visualDensity: VisualDensity.compact,
              onPressed: () => BookDownloadService().resumeTask(t.bookId),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 20),
              tooltip: '取消',
              visualDensity: VisualDensity.compact,
              onPressed: () => BookDownloadService().cancelTask(t.bookId),
            ),
          ],
        );
      case BookDownloadStatus.failed:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 20),
              tooltip: '重试',
              visualDensity: VisualDensity.compact,
              onPressed: () => BookDownloadService().retryTask(t.bookId),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 20),
              tooltip: '取消',
              visualDensity: VisualDensity.compact,
              onPressed: () => BookDownloadService().cancelTask(t.bookId),
            ),
          ],
        );
      case BookDownloadStatus.completed:
        return const SizedBox.shrink();
    }
  }

  Future<void> _showFailureDetail(BookDownloadTask t) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.title),
        content: Text(
          t.error?.isNotEmpty == true ? t.error! : '下载失败',
          style: const TextStyle(fontSize: AppTheme.fontSubhead),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  String _statusText(BookDownloadTask t) {
    switch (t.status) {
      case BookDownloadStatus.queued:
        return '排队中';
      case BookDownloadStatus.downloading:
        return '下载中 ${(t.progress * 100).toInt()}%';
      case BookDownloadStatus.completed:
        final p = BookReadingProgressService().getProgress(t.bookId);
        if (p == null) return '未读';
        if (p.pageTotal <= 0) return '已读';
        final pct = ((p.pageIndex + 1) / p.pageTotal * 100)
            .clamp(0, 100)
            .toInt();
        return '已读 $pct%';
      case BookDownloadStatus.failed:
        return '下载失败';
      case BookDownloadStatus.paused:
        return '已暂停';
    }
  }

  Color _statusColor(BookDownloadTask t) {
    switch (t.status) {
      case BookDownloadStatus.completed:
        return JellyTheme.primary;
      case BookDownloadStatus.failed:
        return JellyTheme.error;
      case BookDownloadStatus.downloading:
        return JellyTheme.primary;
      case BookDownloadStatus.queued:
      case BookDownloadStatus.paused:
        return JellyTheme.textSecondary;
    }
  }

  // ─────────────────────── 漫画段渲染（[DownloadService]） ───────────────────────

  Widget _buildComicTaskTile(DownloadTask t, bool isDark) {
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final card = Container(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.05),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildComicCover(t.comicCover, isDark),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t.chapterTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w700,
                      color: titleColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    t.comicTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: JellyTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Flexible(
                    child: Text(
                      _comicStatusText(t),
                      style: TextStyle(
                        fontSize: AppTheme.fontCaption,
                        color: _comicStatusColor(t),
                      ),
                    ),
                  ),
                  if (t.status == DownloadStatus.downloading ||
                      t.status == DownloadStatus.queued) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: LinearProgressIndicator(
                        value: t.status == DownloadStatus.queued
                            ? null
                            : (t.totalImages > 0
                                ? t.downloadedImages / t.totalImages
                                : 0),
                        minHeight: 4,
                        backgroundColor:
                            (isDark ? Colors.white : Colors.black)
                                .withValues(alpha: 0.1),
                        color: JellyTheme.primary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            _buildComicTaskActions(t),
          ],
        ),
      ),
    );

    switch (t.status) {
      case DownloadStatus.completed:
        return GestureDetector(
          onTap: () => _readComicChapter(t),
          child: card,
        );
      case DownloadStatus.failed:
        return GestureDetector(
          onTap: () => _showComicFailureDetail(t),
          child: card,
        );
      default:
        return card;
    }
  }

  Widget _buildComicCover(String cover, bool isDark) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: CachedNetworkImage(
        imageUrl: cover,
        width: 48,
        height: 66,
        fit: BoxFit.cover,
        placeholder: (c, u) => Container(
          color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
          width: 48,
          height: 66,
        ),
        errorBuilder: (c, e, s) => Container(
          color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
          width: 48,
          height: 66,
          child: Icon(Icons.auto_stories_rounded,
              size: 20, color: JellyTheme.textSecondary),
        ),
      ),
    );
  }

  Widget _buildComicTaskActions(DownloadTask t) {
    switch (t.status) {
      case DownloadStatus.queued:
      case DownloadStatus.downloading:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.pause_rounded, size: 20),
              tooltip: '暂停',
              visualDensity: VisualDensity.compact,
              onPressed: () => DownloadService().pauseTask(t.key),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 20),
              tooltip: '取消',
              visualDensity: VisualDensity.compact,
              onPressed: () => DownloadService().cancelTask(t.key),
            ),
          ],
        );
      case DownloadStatus.paused:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.play_arrow_rounded, size: 20),
              tooltip: '继续',
              visualDensity: VisualDensity.compact,
              onPressed: () => DownloadService().resumeTask(t.key),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 20),
              tooltip: '取消',
              visualDensity: VisualDensity.compact,
              onPressed: () => DownloadService().cancelTask(t.key),
            ),
          ],
        );
      case DownloadStatus.failed:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 20),
              tooltip: '重试',
              visualDensity: VisualDensity.compact,
              onPressed: () => DownloadService().retryTask(t.key),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 20),
              tooltip: '取消',
              visualDensity: VisualDensity.compact,
              onPressed: () => DownloadService().cancelTask(t.key),
            ),
          ],
        );
      case DownloadStatus.completed:
        return const SizedBox.shrink();
    }
  }

  /// 阅读单个已下载漫画章节（离线：仅本漫画已下载章节）
  void _readComicChapter(DownloadTask t) {
    final chapters = DownloadService().downloadedChapters(t.comicPathWord);
    final idx = chapters.indexWhere((c) => c.id == t.chapterId);
    if (idx < 0) return;
    final comic = Comic(
      id: t.comicPathWord,
      title: t.comicTitle,
      cover: t.comicCover,
      pathWord: t.comicPathWord,
      sourceId: t.sourceId,
    );
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
          chapter: chapters[idx],
          groups: [group],
          initialPage: 0,
        ),
      ),
    );
  }

  Future<void> _showComicFailureDetail(DownloadTask t) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.chapterTitle),
        content: Text(
          t.error?.isNotEmpty == true ? t.error! : '下载失败',
          style: const TextStyle(fontSize: AppTheme.fontSubhead),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  String _comicStatusText(DownloadTask t) {
    switch (t.status) {
      case DownloadStatus.queued:
        return '排队中';
      case DownloadStatus.downloading:
        final pct = t.totalImages > 0
            ? ((t.downloadedImages / t.totalImages) * 100).toInt()
            : 0;
        return '下载中 $pct%';
      case DownloadStatus.completed:
        return '已下载';
      case DownloadStatus.failed:
        return '下载失败';
      case DownloadStatus.paused:
        return '已暂停';
    }
  }

  Color _comicStatusColor(DownloadTask t) {
    switch (t.status) {
      case DownloadStatus.completed:
        return JellyTheme.primary;
      case DownloadStatus.failed:
        return JellyTheme.error;
      case DownloadStatus.downloading:
        return JellyTheme.primary;
      case DownloadStatus.queued:
      case DownloadStatus.paused:
        return JellyTheme.textSecondary;
    }
  }
}
