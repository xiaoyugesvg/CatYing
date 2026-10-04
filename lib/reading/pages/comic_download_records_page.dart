import 'dart:math' show min;

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common/theme.dart';
import '../models/comic.dart';
import '../services/download_service.dart';
import '../services/platform_service.dart';
import '../services/settings_service.dart';
import '../theme/jelly_theme.dart';
import '../utils/list_pagination.dart';
import '../widgets/jelly_search_bar.dart';
import 'reader_page.dart';

/// 漫画下载记录页（参考目标界面 IMG_8400）：
/// 标题「下载记录」+ 搜索框「搜索漫画」+ 5 个状态 tab
/// （下载中/已下载/失败/已暂停/已取消）+ 共 N 本统计 + 任务列表 / 空态「暂无下载任务」。
///
/// 从漫画页聚合菜单「下载」进入；底部导航的「下载」管理页（按漫画分组）保持原样。
/// 数据覆盖漫画下载任务（[DownloadService]）。
class ComicDownloadRecordsPage extends StatefulWidget {
  const ComicDownloadRecordsPage({super.key});

  @override
  State<ComicDownloadRecordsPage> createState() =>
      _ComicDownloadRecordsPageState();
}

class _ComicDownloadRecordsPageState extends State<ComicDownloadRecordsPage> {
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
  List<DownloadTask> _filtered() {
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
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _buildOpenDirButton(isDark),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: DownloadService(),
        builder: (context, _) {
          final tasks = _filtered();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: JellySearchBar(
                  controller: _searchController,
                  hintText: '搜索漫画',
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
              _buildStatusTabs(isDark),
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

  /// 状态 tab：文字胶囊（参考图：下载中/已下载/失败/已暂停/已取消）
  Widget _buildStatusTabs(bool isDark) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        itemCount: _tabs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final selected = _statusIndex == i;
          return GestureDetector(
            onTap: () => setState(() {
              _statusIndex = i;
              _displayCount = ListPagination.pageSize;
            }),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? JellyTheme.primary
                    : (isDark ? JellyTheme.cardDark : JellyTheme.cardLight),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Text(
                _tabs[i],
                style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected
                      ? Colors.white
                      : (isDark ? Colors.white : JellyTheme.textPrimaryLight),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.file_download_off_rounded,
              size: 56, color: JellyTheme.textSecondary),
          const SizedBox(height: 12),
          Text(
            '暂无下载任务',
            style: TextStyle(color: JellyTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskTile(DownloadTask t, bool isDark) {
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
            _buildCover(t.comicCover, isDark),
            const SizedBox(width: 10),
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
                  Row(
                    children: [
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
            _buildTaskActions(t),
          ],
        ),
      ),
    );

    switch (t.status) {
      case DownloadStatus.completed:
        return GestureDetector(
          onTap: () => _readChapter(t),
          child: card,
        );
      case DownloadStatus.failed:
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
        height: 64,
        fit: BoxFit.cover,
        placeholder: (c, u) => Container(
          color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
          width: 48,
          height: 64,
        ),
        errorBuilder: (c, e, s) => Container(
          color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
          width: 48,
          height: 64,
          child: Icon(Icons.auto_stories_rounded,
              size: 20, color: JellyTheme.textSecondary),
        ),
      ),
    );
  }

  Widget _buildTaskActions(DownloadTask t) {
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

  /// 阅读单个已下载章节（离线：仅本漫画已下载章节）
  void _readChapter(DownloadTask t) {
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

  Future<void> _showFailureDetail(DownloadTask t) async {
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

  String _statusText(DownloadTask t) {
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

  Color _statusColor(DownloadTask t) {
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
