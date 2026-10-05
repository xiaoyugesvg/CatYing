// 书源详情页（Nexhub 引擎接入）：加载书籍详情与章节目录。
// 布局参考 cmbok 图书详情页（封面+信息+简介+章节列表），
// 目录用 getChapterList 的 onBatch 渐进回调（首屏快显 + 后台续抓）。

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../novel_source/model/book_source.dart';
import '../novel_source/model/xiaoshuo_book.dart';
import '../novel_source/model/xiaoshuo_book_chapter.dart';
import '../novel_source/web_book/web_book.dart';
import '../services/shuyuan_source_store.dart';
import '../theme/jelly_theme.dart';
import 'shuyuan_reader_page.dart';

class ShuyuanBookDetailPage extends StatefulWidget {
  final String bookUrl;
  final String name;
  final String? bookSourceUrl;

  const ShuyuanBookDetailPage({
    super.key,
    required this.bookUrl,
    required this.name,
    this.bookSourceUrl,
  });

  @override
  State<ShuyuanBookDetailPage> createState() => _ShuyuanBookDetailPageState();
}

class _ShuyuanBookDetailPageState extends State<ShuyuanBookDetailPage> {
  final WebBook _webBook = WebBook();
  XiaoshuoBookSource? _source;
  XiaoshuoBook? _book;
  bool _loadingInfo = true;
  bool _loadingToc = true;
  String? _error;
  final List<XiaoshuoBookChapter> _chapters = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final srcUrl = widget.bookSourceUrl;
    XiaoshuoBookSource? source;
    if (srcUrl != null && srcUrl.isNotEmpty) {
      source = ShuyuanSourceStore.instance.sourceByUrl(srcUrl)?.toBookSource();
    }
    // 未带源 URL（聚搜结果）时，按 bookUrl 在启用源里找第一个可解析详情的源。
    source ??= _guessSource();
    if (source == null) {
      setState(() {
        _loadingInfo = false;
        _loadingToc = false;
        _error = '未找到可用书源';
      });
      return;
    }
    _source = source;

    try {
      final book = await _webBook.getBookInfo(
        source: source,
        bookUrl: widget.bookUrl,
      );
      if (mounted) setState(() {
        _book = book;
        _loadingInfo = false;
      });
      await _webBook.getChapterList(
        source: source,
        book: book,
        onBatch: (batch) {
          if (!mounted) return;
          setState(() {
            _chapters.addAll(batch);
            if (_loadingToc) _loadingToc = false;
          });
        },
      );
      if (mounted) setState(() => _loadingToc = false);
    } catch (e) {
      if (mounted) setState(() {
        _loadingInfo = false;
        _loadingToc = false;
        _error = '加载失败: $e';
      });
    }
  }

  /// 聚搜结果没有源信息时，遍历启用源，优先命中 exploreUrl 与 bookUrl 同域者。
  XiaoshuoBookSource? _guessSource() {
    final sources = ShuyuanSourceStore.instance.toBookSources();
    if (sources.isEmpty) return null;
    try {
      final host = Uri.parse(widget.bookUrl).host;
      for (final s in sources) {
        if (Uri.tryParse(s.bookSourceUrl)?.host == host) return s;
      }
    } catch (_) {}
    return sources.first;
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

  void _openReader(int index) {
    final source = _source;
    final book = _book;
    if (source == null || book == null) return;
    if (_chapters.isEmpty) {
      _toast('暂无章节');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ShuyuanReaderPage(
          source: source,
          book: book,
          chapters: List.unmodifiable(_chapters),
          initialIndex: index.clamp(0, _chapters.length - 1),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final book = _book;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (_chapters.isNotEmpty)
            TextButton(
              onPressed: () => _openReader(0),
              child: const Text('开始阅读'),
            ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.error_outline_rounded,
                      size: 48,
                      color: JellyTheme.textSecondary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: JellyTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_loadingInfo)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 60),
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  )
                else if (book != null) ...[
                  _buildInfoCard(isDark, book),
                  const SizedBox(height: 16),
                  _buildTocHeader(isDark),
                  const SizedBox(height: 4),
                  ..._buildChapterTiles(isDark),
                ],
              ],
            ),
    );
  }

  Widget _buildInfoCard(bool isDark, XiaoshuoBook book) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 96,
              height: 128,
              child: book.coverUrl == null || book.coverUrl!.isEmpty
                  ? _coverPlaceholder(book.name)
                  : CachedNetworkImage(
                      imageUrl: book.coverUrl!,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => _coverPlaceholder(book.name),
                    ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  book.name.isNotEmpty ? book.name : widget.name,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                  ),
                ),
                if (book.author.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    '作者：${book.author}',
                    style: TextStyle(
                      fontSize: 13,
                      color: JellyTheme.textSecondary,
                    ),
                  ),
                ],
                if (book.kind != null && book.kind!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '分类：${book.kind}',
                    style: TextStyle(
                      fontSize: 13,
                      color: JellyTheme.textSecondary,
                    ),
                  ),
                ],
                if (book.bookStatus != null && book.bookStatus!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '状态：${book.bookStatus}',
                    style: TextStyle(
                      fontSize: 13,
                      color: JellyTheme.textSecondary,
                    ),
                  ),
                ],
                if (book.lastChapter != null && book.lastChapter!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '更新：${book.lastChapter}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: JellyTheme.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _coverPlaceholder(String name) {
    return Container(
      color: JellyTheme.primary.withValues(alpha: 0.12),
      alignment: Alignment.center,
      child: Text(
        name.isNotEmpty ? name[0] : '书',
        style: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.bold,
          color: JellyTheme.primary,
        ),
      ),
    );
  }

  Widget _buildTocHeader(bool isDark) {
    return Row(
      children: [
        Text(
          '章节目录',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.bold,
            color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
          ),
        ),
        const SizedBox(width: 8),
        if (_loadingToc)
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        const Spacer(),
        Text(
          '共 ${_chapters.length} 章',
          style: TextStyle(fontSize: 12, color: JellyTheme.textSecondary),
        ),
      ],
    );
  }

  List<Widget> _buildChapterTiles(bool isDark) {
    if (_chapters.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Center(
            child: Text(
              _loadingToc ? '正在加载目录…' : '未解析到章节目录',
              style: TextStyle(
                fontSize: 13,
                color: JellyTheme.textSecondary,
              ),
            ),
          ),
        ),
      ];
    }
    return [
      for (var i = 0; i < _chapters.length; i++)
        _buildChapterTile(isDark, i),
    ];
  }

  Widget _buildChapterTile(bool isDark, int index) {
    final ch = _chapters[index];
    final title = ch.title.isNotEmpty ? ch.title : '第 ${index + 1} 章';
    return InkWell(
      onTap: () => _openReader(index),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: JellyTheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              alignment: Alignment.center,
              child: Text(
                '${index + 1}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: JellyTheme.primary,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: JellyTheme.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
