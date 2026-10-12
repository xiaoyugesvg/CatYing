import 'dart:math' show min;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common/theme.dart';
import '../models/book_source.dart';
import '../services/book_download_service.dart';
import '../services/book_reading_progress_service.dart';
import '../services/book_source_download_service.dart';
import '../services/book_source_service.dart';
import '../services/platform_service.dart';
import '../services/settings_service.dart';
import '../theme/jelly_theme.dart';
import '../utils/list_pagination.dart';
import '../widgets/jelly_search_bar.dart';
import 'book_reader_page.dart';
import 'book_source_detail_page.dart';

/// 下载记录页（参考目标界面 IMG_8397）：
/// 标题「下载记录」+ 搜索框 + 5 个状态 tab（下载中/已下载/失败/已暂停/已取消）
/// + 共 N 本统计 + 任务列表 / 空态「该状态下暂无记录」。
///
/// 从图书页聚合菜单「下载」进入；底部导航的「下载」管理页保持原样。
/// 数据只覆盖图书下载任务（[BookDownloadService]），漫画下载仍走主下载页。
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
    final total = _filtered().length;
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
        ]),
        builder: (context, _) {
          final tasks = _filtered();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 搜索行：搜索框 + 右侧文件夹图标（与漫画下载记录页一致）
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: JellySearchBar(
                        controller: _searchController,
                        hintText: '搜索图书',
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
              _buildStatusTabs(isDark),
              _buildSourceDownloads(isDark),
              ListPaginationCountBar(total: tasks.length, unit: '本'),
              Expanded(
                child: tasks.isEmpty
                    ? _buildEmpty()
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.fromLTRB(0, 4, 0, 16),
                        itemCount: min(tasks.length, _displayCount),
                        itemBuilder: (context, i) =>
                            _buildTaskTile(tasks[i], isDark),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildOpenDirButton(bool isDark) {
    return Material(
      color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
      shape: const CircleBorder(),
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

  /// 状态 tab：等分 5 列（与漫画下载记录页一致，参考图 IMG_8464）
  Widget _buildStatusTabs(bool isDark) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          for (var i = 0; i < _tabs.length; i++) ...[
            if (i > 0) const SizedBox(width: 4),
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() {
                  _statusIndex = i;
                  _displayCount = ListPagination.pageSize;
                }),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _statusIndex == i
                        ? JellyTheme.primary.withValues(alpha: 0.12)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _tabs[i],
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      fontWeight:
                          _statusIndex == i ? FontWeight.w700 : FontWeight.w500,
                      color: _statusIndex == i
                          ? JellyTheme.primary
                          : (isDark ? Colors.white70 : JellyTheme.textSecondary),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off_rounded, size: 48, color: JellyTheme.textSecondary),
          const SizedBox(height: 12),
          Text(
            '该状态下暂无记录',
            style: TextStyle(color: JellyTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskTile(BookDownloadTask t, bool isDark) {
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final card = Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            _buildCover(t.cover ?? '', isDark),
            const SizedBox(width: 10),
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
        width: 44,
        height: 60,
        fit: BoxFit.cover,
        placeholder: (c, u) => Container(
          color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
          width: 44,
          height: 60,
        ),
        errorBuilder: (c, e, s) => Container(
          color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
          width: 44,
          height: 60,
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
}
