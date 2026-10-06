// 书源正文阅读器（Nexhub 引擎接入）：逐章抓取并渲染网页正文。
//
// 功能（对齐 cmbok 阅读器基础能力 + 备份3.0 书源阅读器形态）：
//   - 排版：字号 / 行距 / 背景主题（亮·米黄·墨绿·暗黑）/ 翻页模式（连续·翻页）
//   - 续读：BookReadingProgressService 按 (源+书) 记忆章节，重新进入自动恢复
//   - 目录：底部弹层 + 当前章高亮 + 自动定位
//   - 听书：迷你控制栏（TtsService）+ 全屏听书页（TtsFullPlayerPage）
// 正文图文混排（NovelTextBlock / NovelImageBlock）。

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../novel_source/model/book_source.dart';
import '../novel_source/model/xiaoshuo_book.dart';
import '../novel_source/model/xiaoshuo_book_chapter.dart';
import '../novel_source/novel_block.dart';
import '../novel_source/web_book/web_book.dart';
import '../services/book_reading_progress_service.dart';
import '../services/tts_service.dart';
import '../theme/jelly_theme.dart';
import 'tts_full_player_page.dart';

/// 背景主题
class _BgTheme {
  final Color bg;
  final Color text;
  const _BgTheme(this.bg, this.text);
}

const _themes = <_BgTheme>[
  _BgTheme(Color(0xFFFFFDF8), Color(0xFF3A3A3A)), // 亮
  _BgTheme(Color(0xFFF5ECD9), Color(0xFF5B4F35)), // 米黄
  _BgTheme(Color(0xFFDDE8DD), Color(0xFF2F4A3C)), // 墨绿
  _BgTheme(Color(0xFF1A1A1A), Color(0xFFCFCFCF)), // 暗黑
];

const _lineHeights = <double>[1.5, 1.7, 1.9, 2.1];

class ShuyuanReaderPage extends StatefulWidget {
  final XiaoshuoBookSource source;
  final XiaoshuoBook book;
  final List<XiaoshuoBookChapter> chapters;
  final int initialIndex;

  const ShuyuanReaderPage({
    super.key,
    required this.source,
    required this.book,
    required this.chapters,
    required this.initialIndex,
  });

  @override
  State<ShuyuanReaderPage> createState() => _ShuyuanReaderPageState();
}

class _ShuyuanReaderPageState extends State<ShuyuanReaderPage> {
  final WebBook _webBook = WebBook();
  final TtsService _tts = TtsService.instance;
  late int _index;
  late double _fontSize;
  late double _lineHeight;
  late int _themeIndex;
  late bool _pagedMode;

  bool _loading = false;
  String? _error;
  List<NovelBlock> _blocks = [];
  String _chapterTitle = '';

  // 翻页模式下的分页结果
  List<List<NovelBlock>> _pages = [];
  final PageController _pageCtrl = PageController();
  bool _showControls = true; // 沉浸式：点击正文切换控制栏显隐（对齐漫画/图书阅读器）

  // 书签：bookId → 已标记章节下标
  final Set<int> _bookmarks = {};

  /// 续读记忆键：源 + 书
  String get _bookId => '${widget.source.bookSourceUrl}|${widget.book.bookUrl}';

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _fontSize = 16.5;
    _lineHeight = 1.8;
    _themeIndex = 0;
    _pagedMode = false;
    _loadPrefs();
    _loadBookmarks();
    // 续读：优先恢复上次章节
    final saved = BookReadingProgressService().getProgress(_bookId);
    if (saved != null &&
        saved.blockIndex >= 0 &&
        saved.blockIndex < widget.chapters.length) {
      _index = saved.blockIndex;
    }
    _loadChapter(_index);
  }

  Future<void> _loadPrefs() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final fs = sp.getDouble('shuyuan_reader_font');
      final lh = sp.getDouble('shuyuan_reader_line_height');
      final th = sp.getInt('shuyuan_reader_theme');
      final pm = sp.getBool('shuyuan_reader_paged');
      if (!mounted) return;
      setState(() {
        _fontSize = (fs ?? 16.5).clamp(12.0, 28.0);
        _lineHeight =
            _lineHeights.contains(lh) ? lh! : 1.8;
        _themeIndex = (th ?? 0).clamp(0, _themes.length - 1);
        _pagedMode = pm ?? false;
      });
    } catch (_) {
      // 忽略读失败，用默认值
    }
  }

  Future<void> _savePrefs() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setDouble('shuyuan_reader_font', _fontSize);
      await sp.setDouble('shuyuan_reader_line_height', _lineHeight);
      await sp.setInt('shuyuan_reader_theme', _themeIndex);
      await sp.setBool('shuyuan_reader_paged', _pagedMode);
    } catch (_) {}
  }

  // ── 书签 ──
  Future<void> _loadBookmarks() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString('shuyuan_reader_bookmarks_$_bookId');
      if (raw != null && raw.isNotEmpty) {
        _bookmarks.addAll(raw.split(',').map(int.parse));
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _saveBookmarks() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(
        'shuyuan_reader_bookmarks_$_bookId',
        _bookmarks.join(','),
      );
    } catch (_) {}
  }

  bool get _currentBookmarked => _bookmarks.contains(_index);

  void _toggleBookmark() {
    setState(() {
      if (_bookmarks.contains(_index)) {
        _bookmarks.remove(_index);
      } else {
        _bookmarks.add(_index);
      }
    });
    _saveBookmarks();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(_currentBookmarked ? '已加入书签' : '已移除书签'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
      ));
  }

  _BgTheme get _theme => _themes[_themeIndex];

  Future<void> _loadChapter(int index) async {
    if (index < 0 || index >= widget.chapters.length) return;
    setState(() {
      _index = index;
      _loading = true;
      _error = null;
      _blocks = [];
      _pages = [];
      _chapterTitle = widget.chapters[index].title.isNotEmpty
          ? widget.chapters[index].title
          : '第 ${index + 1} 章';
    });
    // 记录续读位置
    BookReadingProgressService().recordBlock(
      _bookId,
      index,
      0,
      widget.chapters.length,
    );
    try {
      final result = await _webBook.getContent(
        source: widget.source,
        chapterUrl: widget.chapters[index].url,
        originalBook: widget.book,
      );
      if (!mounted) return;
      setState(() {
        _blocks = result.blocks.isNotEmpty
            ? result.blocks
            : _textBlocks(result.content);
        _loading = false;
        if (result.error != null && _blocks.isEmpty) {
          _error = result.error;
        }
        if (_pagedMode) _pages = _paginate();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '正文加载失败: $e';
      });
    }
  }

  /// 旧字段兜底：把纯文本 content 拆成段落块。
  List<NovelBlock> _textBlocks(String content) {
    if (content.isEmpty) return const [];
    return [
      for (final line in content.split('\n'))
        if (line.trim().isNotEmpty) NovelTextBlock(line.trim()),
    ];
  }

  // ============================================================
  // 翻页分页（近似按视口容量切块；图片独立一页）
  // ============================================================

  List<List<NovelBlock>> _paginate() {
    if (_blocks.isEmpty) return const [];
    // 估算每页容量（中文宽度≈字号）
    final width = MediaQuery.sizeOf(context).width;
    final height = MediaQuery.sizeOf(context).height;
    final perLine = (width - 40) ~/ _fontSize;
    final linesPerPage = (height - 120) ~/ (_fontSize * _lineHeight);
    final capacity = (perLine * linesPerPage).clamp(100, 2000).toInt();

    final pages = <List<NovelBlock>>[];
    var page = <NovelBlock>[];
    var chars = 0;
    for (final block in _blocks) {
      if (block is NovelImageBlock) {
        if (page.isNotEmpty) {
          pages.add(List.of(page));
          page = [];
          chars = 0;
        }
        pages.add([block]);
        continue;
      }
      if (block is! NovelTextBlock) continue;
      final len = (block.text.length + 1);
      if (page.isNotEmpty && chars + len > capacity) {
        pages.add(List.of(page));
        page = [];
        chars = 0;
      }
      page.add(block);
      chars += len;
    }
    if (page.isNotEmpty) pages.add(page);
    return pages;
  }

  // ============================================================
  // 目录
  // ============================================================

  void _showToc() {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (context, scrollController) {
          // 打开后自动定位到当前章
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (scrollController.hasClients) {
              scrollController.jumpTo(
                ((_index * 48.0) - 200).clamp(0.0,
                    scrollController.position.maxScrollExtent),
              );
            }
          });
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Text(
                  '章节目录（${widget.chapters.length}）',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: widget.chapters.length,
                  itemBuilder: (context, i) {
                    final selected = i == _index;
                    return ListTile(
                      dense: true,
                      selected: selected,
                      selectedTileColor:
                          JellyTheme.primary.withValues(alpha: 0.12),
                      title: Row(
                        children: [
                          if (_bookmarks.contains(i)) ...[
                            Icon(Icons.bookmark_rounded,
                                size: 12, color: JellyTheme.primary),
                            const SizedBox(width: 5),
                          ],
                          Expanded(
                            child: Text(
                              widget.chapters[i].title.isNotEmpty
                                  ? widget.chapters[i].title
                                  : '第 ${i + 1} 章',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                color: selected
                                    ? JellyTheme.primary
                                    : (Theme.of(context).brightness ==
                                            Brightness.dark
                                        ? Colors.white
                                        : JellyTheme.textPrimaryLight),
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                        ],
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        _loadChapter(i);
                      },
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

  // ============================================================
  // 听书
  // ============================================================

  String get _chapterPlainText {
    final sb = StringBuffer();
    for (final b in _blocks) {
      if (b is NovelTextBlock) sb.writeln(b.text);
    }
    return sb.toString();
  }

  Future<void> _speakChapter() async {
    final text = _chapterPlainText.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('本章没有可朗读的文本'),
          duration: Duration(seconds: 1),
        ));
      return;
    }
    await _tts.speak(text);
  }

  void _openFullPlayer() {
    final segments = _blocks
        .whereType<NovelTextBlock>()
        .map((b) => b.text.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TtsFullPlayerPage(
          bookName: widget.book.name.isNotEmpty
              ? widget.book.name
              : widget.source.bookSourceName,
          author: widget.book.author,
          chapterName: _chapterTitle,
          segments: segments,
          coverUrl: widget.book.coverUrl,
          chapterNames: [
            for (final c in widget.chapters)
              c.title.isNotEmpty ? c.title : '第 ${widget.chapters.indexOf(c) + 1} 章',
          ],
          onSelectChapter: (i) {
            Navigator.pop(context);
            if (i >= 0 && i < widget.chapters.length) {
              _loadChapter(i);
            }
          },
        ),
      ),
    );
  }

  // ============================================================
  // 构建
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final theme = _theme;
    // 沉浸式布局（对齐漫画 reader_page / 图书 book_reader_page）：
    // 正文铺满全屏，顶栏与底栏淡入淡出，点击正文切换显隐。
    return Scaffold(
      backgroundColor: theme.bg,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: _handleTap,
        child: Stack(
          children: [
            Positioned.fill(child: _buildBody(theme)),
            // 顶栏（SafeArea 避开状态栏）
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                opacity: _showControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 180),
                child: IgnorePointer(
                  ignoring: !_showControls,
                  child: SafeArea(
                    bottom: false,
                    child: _buildTopBar(theme),
                  ),
                ),
              ),
            ),
            // 底栏（SafeArea 避开手势条）
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                opacity: _showControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 180),
                child: IgnorePointer(
                  ignoring: !_showControls,
                  child: SafeArea(
                    top: false,
                    child: _buildBottomBar(theme),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 点击正文：翻页模式下左/中/右三分区（上一页/切换控制栏/下一页），
  /// 滚动模式下任意点击切换控制栏。
  void _handleTap(TapUpDetails d) {
    if (_loading || _error != null || _blocks.isEmpty) return;
    if (_pagedMode && _pages.isNotEmpty) {
      final w = MediaQuery.of(context).size.width;
      final dx = d.globalPosition.dx;
      if (dx < w / 3) {
        if (_pageCtrl.hasClients && _pageCtrl.page! > 0) {
          _pageCtrl.previousPage(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          );
        }
        return;
      }
      if (dx > w * 2 / 3) {
        if (_pageCtrl.hasClients && _pageCtrl.page! < _pages.length - 1) {
          _pageCtrl.nextPage(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          );
        }
        return;
      }
    }
    setState(() => _showControls = !_showControls);
  }

  Widget _buildTopBar(_BgTheme theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.bg.withValues(alpha: 0.94),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回',
            icon: Icon(Icons.arrow_back_ios_new_rounded,
                size: 18, color: theme.text),
            onPressed: () => Navigator.pop(context),
          ),
          Expanded(
            child: Text(
              _chapterTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 15, color: theme.text),
            ),
          ),
          IconButton(
            tooltip: _currentBookmarked ? '移除书签' : '加入书签',
            icon: Icon(
              _currentBookmarked
                  ? Icons.bookmark_rounded
                  : Icons.bookmark_border_rounded,
              size: 20,
              color: _currentBookmarked ? JellyTheme.primary : theme.text,
            ),
            onPressed: _toggleBookmark,
          ),
          IconButton(
            tooltip: '排版',
            icon: Icon(Icons.format_size_rounded, size: 20, color: theme.text),
            onPressed: _showLayoutSheet,
          ),
          IconButton(
            tooltip: '目录',
            icon: Icon(Icons.list_rounded, size: 20, color: theme.text),
            onPressed: _showToc,
          ),
          IconButton(
            tooltip: '听书',
            icon: Icon(Icons.headphones_rounded, size: 20, color: theme.text),
            onPressed: _speakChapter,
          ),
        ],
      ),
    );
  }

  Widget _buildBody(_BgTheme theme) {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(
            strokeWidth: 2.5, color: JellyTheme.primary),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline_rounded,
                  size: 44, color: theme.text.withValues(alpha: 0.6)),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: theme.text),
              ),
              const SizedBox(height: 14),
              TextButton.icon(
                onPressed: () => _loadChapter(_index),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_blocks.isEmpty) {
      return Center(
        child: Text(
          '正文为空',
          style: TextStyle(fontSize: 14, color: theme.text),
        ),
      );
    }
    if (_pagedMode) {
      if (_pages.isEmpty) _pages = _paginate();
      return PageView.builder(
        controller: _pageCtrl,
        itemCount: _pages.length,
        onPageChanged: (_) {},
        itemBuilder: (context, pi) => ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            for (final b in _pages[pi]) _buildBlock(b, theme),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      itemCount: _blocks.length,
      itemBuilder: (context, i) => _buildBlock(_blocks[i], theme),
    );
  }

  Widget _buildBlock(NovelBlock block, _BgTheme theme) {
    if (block is NovelTextBlock) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text(
          block.text,
          style: TextStyle(
            fontSize: _fontSize,
            height: _lineHeight,
            color: block.isHeading ? JellyTheme.primary : theme.text,
            fontWeight: block.isHeading ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      );
    }
    if (block is NovelImageBlock) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: CachedNetworkImage(
            imageUrl: block.url,
            fit: BoxFit.contain,
            errorWidget: (_, __, ___) => Text(
              '[图片加载失败]',
              style: TextStyle(fontSize: 12, color: theme.text),
            ),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  // ── 排版面板：字号 / 行距 / 背景 / 翻页模式 ──
  void _showLayoutSheet() {
    final theme = _theme;
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Text(
                  '排版 · 字号 ${_fontSize.round()}',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 12),
              // 字号
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove_rounded, size: 20),
                    onPressed: () {
                      if (_fontSize > 12) {
                        setSheet(() => _fontSize -= 1);
                        setState(() {});
                        _savePrefs();
                      }
                    },
                  ),
                  Expanded(
                    child: Slider(
                      value: _fontSize,
                      min: 12,
                      max: 28,
                      divisions: 16,
                      label: '${_fontSize.round()}',
                      onChanged: (v) {
                        setSheet(() => _fontSize = v);
                        setState(() {});
                      },
                      onChangeEnd: (_) => _savePrefs(),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_rounded, size: 20),
                    onPressed: () {
                      if (_fontSize < 28) {
                        setSheet(() => _fontSize += 1);
                        setState(() {});
                        _savePrefs();
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // 行距
              _sectionLabel('行距'),
              const SizedBox(height: 6),
              Row(
                children: [
                  for (final lh in _lineHeights)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(
                          lh == 1.5 ? '紧凑' : lh == 1.7 ? '常规' : lh == 1.9 ? '宽松' : '超宽',
                          style: const TextStyle(fontSize: 12),
                        ),
                        selected: _lineHeight == lh,
                        onSelected: (_) {
                          setSheet(() => _lineHeight = lh);
                          setState(() {});
                          _savePrefs();
                        },
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              // 背景主题
              _sectionLabel('背景'),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (var i = 0; i < _themes.length; i++)
                    GestureDetector(
                      onTap: () {
                        setSheet(() => _themeIndex = i);
                        setState(() {});
                        _savePrefs();
                      },
                      child: Container(
                        width: 44,
                        height: 44,
                        margin: const EdgeInsets.only(right: 12),
                        decoration: BoxDecoration(
                          color: _themes[i].bg,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: _themeIndex == i
                                ? JellyTheme.primary
                                : Colors.black12,
                            width: _themeIndex == i ? 2 : 1,
                          ),
                        ),
                        child: Icon(
                          _themeIndex == i
                              ? Icons.check_rounded
                              : Icons.text_fields_rounded,
                          size: 18,
                          color: _themes[i].text,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              // 翻页模式
              _sectionLabel('翻页'),
              const SizedBox(height: 6),
              Row(
                children: [
                  ChoiceChip(
                    label: const Text('连续滚动'),
                    selected: !_pagedMode,
                    onSelected: (_) {
                      setSheet(() => _pagedMode = false);
                      setState(() {});
                      _savePrefs();
                    },
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('翻页'),
                    selected: _pagedMode,
                    onSelected: (_) {
                      setSheet(() => _pagedMode = true);
                      setState(() => _pages = _paginate());
                      _savePrefs();
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).brightness == Brightness.dark
            ? Colors.white54
            : JellyTheme.textSecondary,
      ),
    );
  }

  // ── 底部栏：设置 / 上一章 / 目录 / 页码 / 听书 / 下一章 ──
  Widget _buildBottomBar(_BgTheme theme) {
    return Container(
      decoration: BoxDecoration(
        color: theme.bg,
        border: Border(
          top: BorderSide(color: JellyTheme.primary.withValues(alpha: 0.15)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              tooltip: '排版',
              icon: Icon(Icons.tune_rounded, size: 20, color: theme.text),
              onPressed: _showLayoutSheet,
            ),
            IconButton(
              tooltip: '上一章',
              icon: Icon(Icons.skip_previous_rounded,
                  size: 22, color: theme.text),
              onPressed: _index > 0 ? () => _loadChapter(_index - 1) : null,
            ),
            IconButton(
              tooltip: '目录',
              icon: Icon(Icons.list_rounded, size: 22, color: theme.text),
              onPressed: _showToc,
            ),
            Text(
              '${_index + 1}/${widget.chapters.length}',
              style: TextStyle(fontSize: 12, color: theme.text),
            ),
            Obx(() {
              final speaking = _tts.isSpeaking.value;
              final paused = _tts.isPaused.value;
              return IconButton(
                tooltip: speaking ? '停止听书' : '听书',
                icon: Icon(
                  speaking
                      ? (paused
                          ? Icons.play_circle_outline_rounded
                          : Icons.stop_circle_outlined)
                      : Icons.headphones_rounded,
                  size: 22,
                  color: speaking ? JellyTheme.primary : theme.text,
                ),
                onPressed: speaking ? _tts.stop : _speakChapter,
              );
            }),
            IconButton(
              tooltip: '下一章',
              icon: Icon(Icons.skip_next_rounded, size: 22, color: theme.text),
              onPressed: _index < widget.chapters.length - 1
                  ? () => _loadChapter(_index + 1)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
