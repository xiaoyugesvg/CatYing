// 书源详情页（Nexhub 引擎接入）：加载书籍详情与章节目录。// 布局对齐备份3.0 book_source_detail_page：左信息+右封面、四按钮
//（收藏/加入书架/阅读/下载）、简介展开收起、目录默认前 8 章、错误态可换源。// 目录用 getChapterList 的 onBatch 渐进回调
import 'dart:convert';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../models/book.dart';
import '../models/bookshelf.dart';
import '../novel_source/model/book_source.dart';
import '../novel_source/model/search_book.dart';
import '../novel_source/model/xiaoshuo_book.dart';
import '../novel_source/model/xiaoshuo_book_chapter.dart';
import '../novel_source/web_book/web_book.dart';
import '../services/book_download_service.dart';
import '../services/book_favorites_service.dart';
import '../services/shuyuan_source_store.dart';
import '../theme/jelly_theme.dart';
import '../widgets/jelly_bookshelf_dialog.dart';
import 'book_source_switch_page.dart';
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
  final BookFavoritesService _favorites = BookFavoritesService();
  XiaoshuoBookSource? _source;
  XiaoshuoBook? _book;
  bool _loadingInfo = true;
  bool _loadingToc = true;
  String? _error;
  final List<XiaoshuoBookChapter> _chapters = [];
  bool _descExpanded = false;
  bool _showAllChapters = false; // 鐩綍榛樿鍙樉绀哄墠 8 绔?
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
    await _load(source, widget.bookUrl);
  }

/// 用指定源加载详情与目录（换源后复用）。
  Future<void> _load(XiaoshuoBookSource source, String bookUrl) async {
    try {
      final book = await _webBook.getBookInfo(
        source: source,
        bookUrl: bookUrl,
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
        _error = '鍔犺浇澶辫触: $e';
      });
    }
  }

/// 换源：用书名去其它已启用源再搜一次，选中结果后重载详情。
  Future<void> _changeSource() async {
    final source = _source;
    if (source == null) return;
    final name = _book?.name.isNotEmpty == true ? _book!.name : widget.name;
    final author = _book?.author ?? '';
    final others = ShuyuanSourceStore.instance
        .toBookSources()
        .where((s) => s.enabled && s.bookSourceUrl != source.bookSourceUrl)
        .toList();
    if (others.isEmpty) {
      _toast('没有其它已启用的书源可换');
      return;
    }
    final picked = await Navigator.push<SearchBook>(
      context,
      MaterialPageRoute(
        builder: (_) => BookSourceSwitchPage(
          bookName: name,
          author: author,
          sources: others,
          currentSource: source,
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final newSrc = picked.bookSourceUrl != null
        ? ShuyuanSourceStore.instance
            .sourceByUrl(picked.bookSourceUrl!)
            ?.toBookSource()
        : null;
    if (newSrc == null) {
      _toast('目标书源不可用');
      return;
    }
    setState(() {
      _source = newSrc;
      _book = null;
      _chapters.clear();
      _loadingInfo = true;
      _loadingToc = true;
      _error = null;
    });
    await _load(newSrc, picked.bookUrl);
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
      backgroundColor:
          isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
      appBar: AppBar(
        backgroundColor:
            isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded,
              size: 20, color: isDark ? Colors.white : JellyTheme.textPrimaryLight),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          '书籍详情',
          style: TextStyle(
            fontSize: AppTheme.fontHeadline,
            fontWeight: FontWeight.w600,
            color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '换源',
            onPressed: _source == null || _chapters.isEmpty
                ? null
                : _changeSource,
            icon: Icon(
              Icons.swap_horiz_rounded,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          if (_chapters.isNotEmpty)
            TextButton(
              onPressed: () => _openReader(0),
              child: Text(
                '开始阅读',
                style: TextStyle(
                  fontSize: AppTheme.fontHeadline,
                  color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                ),
              ),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          if (_error == null && book != null) ...[
            _header(),
            const Divider(height: 1),
          ],
          Expanded(
            child: _error != null
                ? _errorView()
                : book == null
                    ? (_loadingInfo
                        ? const Center(
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          )
                        : const SizedBox.shrink())
                    : _tocArea(),
          ),
        ],
      ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded,
                size: 48, color: Colors.orangeAccent),
            const SizedBox(height: 14),
            Text(
              _error ?? '鍔犺浇澶辫触',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  color: JellyTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () {
                final s = _source;
                if (s == null) return;
                setState(() {
                  _loadingInfo = true;
                  _loadingToc = true;
                  _error = null;
                  _chapters.clear();
                });
                _load(s, widget.bookUrl);
              },
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('重试'),
            ),
            if (_source != null)
              TextButton.icon(
                onPressed: _changeSource,
                icon: const Icon(Icons.swap_horiz_rounded),
                label: const Text('换源'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final book = _book;
    final intro = (book?.intro ?? '').trim();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 左信息 + 右封面 ──
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book?.name.isNotEmpty == true ? book!.name : widget.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTheme.fontTitle3,
                        fontWeight: FontWeight.w700,
                        color: label,
                      ),
                    ),
                    if (book != null && book.author.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text('${book.author} 著',
                          style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              color: JellyTheme.textSecondary)),
                    ],
                    if (_source != null) ...[
                      const SizedBox(height: 6),
                      Text('来源：${_source!.bookSourceName}',
                          style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              color: JellyTheme.textSecondary)),
                    ],
                    if (_wordCountText.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(_wordCountText,
                          style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              color: JellyTheme.textSecondary)),
                    ],
                    if (_chapters.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color:
                                  JellyTheme.primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text('最新章节',
                                style: TextStyle(
                                    fontSize: AppTheme.fontCaption,
                                    color: JellyTheme.primary,
                                    fontWeight: FontWeight.w600)),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _chapters.last.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: AppTheme.fontSubhead,
                                  color: label,
                                  fontWeight: FontWeight.w500),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 84,
                  height: 112,
                  child: (book?.coverUrl == null || book!.coverUrl!.isEmpty)
                      ? Container(
                          color: JellyTheme.primary.withValues(alpha: 0.1),
                          child: Icon(Icons.menu_book_rounded,
                              size: 30, color: JellyTheme.primary),
                        )
                      : CachedNetworkImage(
                          imageUrl: book!.coverUrl!,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(
                            color: JellyTheme.primary.withValues(alpha: 0.1),
                            child: Icon(Icons.menu_book_rounded,
                                size: 30, color: JellyTheme.primary),
                          ),
                        ),
                ),
              ),
            ],
          ),
          // ── 四按钮：收藏 / 加入书架 / 阅读 / 下载 ──
          const SizedBox(height: 14),
          Row(
            children: [
              _actionCapsule(Icons.favorite_border_rounded, '收藏',
                  _toggleFavorite),
              const SizedBox(width: 8),
              _actionCapsule(
                  Icons.library_add_rounded, '加入书架', _addToBookshelf),
              const SizedBox(width: 8),
              _actionCapsule(Icons.play_arrow_rounded, '阅读',
                  _chapters.isEmpty ? null : () => _openReader(0)),
              const SizedBox(width: 8),
              _actionCapsule(Icons.download_for_offline_rounded, '下载',
                  _chapters.isEmpty ? null : _downloadBook),
            ],
          ),
          // ── 简介板块 ──
          if (intro.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('简介',
                style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w700,
                    color: label)),
            const SizedBox(height: 6),
            Text(
              intro,
              maxLines: _descExpanded ? null : 4,
              overflow: _descExpanded ? null : TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  height: 1.55,
                  color: JellyTheme.textSecondary),
            ),
            if (intro.length > 90 || intro.contains('\n'))
              GestureDetector(
                onTap: () => setState(() => _descExpanded = !_descExpanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    _descExpanded ? '收起' : '展开全部',
                    style: TextStyle(
                        fontSize: AppTheme.fontSubhead,
                        color: JellyTheme.primary,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ),
          ],
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  String get _wordCountText {
    final raw = (_book?.wordCount ?? '').toString();
    if (raw.isEmpty) return '';
    final n = int.tryParse(raw.replaceAll(RegExp(r'\D'), '')) ?? 0;
    if (n <= 0) return '$raw字';
    if (n >= 10000) {
      return '${(n / 10000).toStringAsFixed(n % 10000 == 0 ? 0 : 1)}万字';
    }
    return '$n字';
  }

/// 四按钮之一（深灰胶囊，对齐备份3.0）。
  Widget _actionCapsule(IconData icon, String label, VoidCallback? onTap) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final labelColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Expanded(
      child: Material(
        color: isDark
            ? Colors.white.withValues(alpha: 0.12)
            : Colors.black.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 15, color: labelColor.withValues(alpha: 0.85)),
                const SizedBox(width: 4),
                Text(label,
                    style: TextStyle(
                        fontSize: AppTheme.fontFootnote,
                        color: labelColor.withValues(alpha: 0.85),
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String get _favoriteId => 'book-${widget.bookUrl}';

  void _toggleFavorite() {
    final book = _book;
    final id = _favoriteId;
    final name = book?.name.isNotEmpty == true ? book!.name : widget.name;
    _favorites.toggle(Book.fromJson({
      'id': id,
      'hash': '',
      'title': name,
      'author': book?.author ?? '',
      'cover': book?.coverUrl ?? '',
      'sourceName': _source?.bookSourceName ?? '',
    }));
    setState(() {});
    _toast(_favorites.isFavorite(id) ? '已收藏「$name」' : '已取消收藏「$name」');
  }

  Future<void> _addToBookshelf() async {
    final book = _book;
    final result = await showBookshelfDialog(
      context,
      itemId: _favoriteId,
      type: BookshelfItemType.book,
      title: '加入书架',
      meta: jsonEncode({
        'id': _favoriteId,
        'hash': '',
        'title': book?.name.isNotEmpty == true ? book!.name : widget.name,
        'author': book?.author ?? '',
        'cover': book?.coverUrl ?? '',
        'sourceName': _source?.bookSourceName ?? '',
        'bookUrl': widget.bookUrl,
      }),
    );
    if (result != null && mounted) {
      _toast(result.isEmpty ? '已从所有书架移除' : '已加入 ${result.length} 本书架');
    }
  }

/// 下载全书：选择范围后交给 BookDownloadService（带进度，可取消）。
  Future<void> _downloadBook() async {
    final book = _book;
    if (book == null) return;
    final total = _chapters.length;
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor:
          Theme.of(context).brightness == Brightness.dark
              ? JellyTheme.cardDark
              : JellyTheme.cardLight,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('下载全书',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? Colors.white
                          : JellyTheme.textPrimaryLight)),
              const SizedBox(height: 6),
              Text('共 $total 章，保存为本地 TXT，可离线阅读',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: JellyTheme.textSecondary)),
              const SizedBox(height: 14),
              for (final (n, label) in [
                (100, '前 100 章'),
                (200, '前 200 章'),
                (total, '全部（$total 章）'),
              ]) ...[
                if (n <= total) ...[
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: JellyTheme.primary,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: () => Navigator.pop(ctx, n),
                    child: Text(label,
                        style: const TextStyle(
                            fontSize: AppTheme.fontBody,
                            color: Colors.white)),
                  ),
                  const SizedBox(height: 10),
                ],
              ],
              TextButton(
                onPressed: () => Navigator.pop(ctx, 0),
                child: const Text('取消'),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || picked <= 0 || !mounted) return;

// 走 BookDownloadService：与下载记录页共用同一套任务体系。
    await BookDownloadService().download(Book.fromJson({
      'id': _favoriteId,
      'hash': '',
      'title': book.name.isNotEmpty ? book.name : widget.name,
      'author': book.author,
      'cover': book.coverUrl,
    }));
    if (mounted) _toast('已加入下载队列，可在下载记录页查看进度');
  }

  Widget _tocArea() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    if (_loadingToc && _chapters.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: JellyTheme.primary),
            const SizedBox(height: 14),
            Text('正在获取目录...',
                style: TextStyle(
                    fontSize: AppTheme.fontSubhead,
                    color: JellyTheme.textSecondary)),
          ],
        ),
      );
    }
    if (_chapters.isEmpty) {
      return Center(
        child: Text('未解析到章节目录',
            style: TextStyle(
                fontSize: AppTheme.fontSubhead,
                color: JellyTheme.textSecondary)),
      );
    }
    final visibleCount =
        _showAllChapters ? _chapters.length : _chapters.length.clamp(0, 8);
    final hasMore = _chapters.length > 8;
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 90),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Row(
            children: [
              Text('章节目录',
                  style: TextStyle(
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.bold,
                      color: label)),
              const SizedBox(width: 8),
              Text('共 ${_chapters.length} 章',
                  style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: JellyTheme.textSecondary)),
            ],
          ),
        ),
        ...List.generate(visibleCount, (i) {
          final ch = _chapters[i];
          final title = ch.title.isNotEmpty ? ch.title : '第 ${i + 1} 章';
          return ListTile(
            dense: true,
            title: Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: AppTheme.fontBody, color: label)),
            onTap: () => _openReader(i),
          );
        }),
        if (hasMore)
          Center(
            child: TextButton.icon(
              onPressed: () =>
                  setState(() => _showAllChapters = !_showAllChapters),
              icon: Icon(
                _showAllChapters
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                size: 18,
              ),
              label: Text(_showAllChapters
                  ? '收起'
                  : '显示全部（共 ${_chapters.length} 章）'),
            ),
          ),
      ],
    );
  }
}

