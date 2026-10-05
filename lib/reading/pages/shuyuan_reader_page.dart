// 书源正文阅读器（Nexhub 引擎接入）：逐章抓取并渲染网页正文。
//
// 功能：上一章 / 下一章、章节目录弹层、字号调节、亮/暗背景切换、
// 正文图文混排（NovelTextBlock / NovelImageBlock）。
// 进阶排版（行距/翻页模式等）与 cmbok 阅读设置体系对齐，后续迭代。

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../novel_source/model/book_source.dart';
import '../novel_source/model/xiaoshuo_book.dart';
import '../novel_source/model/xiaoshuo_book_chapter.dart';
import '../novel_source/novel_block.dart';
import '../novel_source/web_book/web_book.dart';
import '../theme/jelly_theme.dart';

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
  late int _index;
  late double _fontSize;
  bool _darkBg = false;

  bool _loading = false;
  String? _error;
  List<NovelBlock> _blocks = [];
  String _chapterTitle = '';

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _fontSize = 16.0;
    _loadChapter(_index);
  }

  Future<void> _loadChapter(int index) async {
    if (index < 0 || index >= widget.chapters.length) return;
    setState(() {
      _index = index;
      _loading = true;
      _error = null;
      _blocks = [];
      _chapterTitle =
          widget.chapters[index].title.isNotEmpty ? widget.chapters[index].title : '第 ${index + 1} 章';
    });
    try {
      final result = await _webBook.getContent(
        source: widget.source,
        chapterUrl: widget.chapters[index].url,
        originalBook: widget.book,
      );
      if (!mounted) return;
      setState(() {
        _blocks = result.blocks.isNotEmpty ? result.blocks : _textBlocks(result.content);
        _loading = false;
        if (result.error != null && _blocks.isEmpty) {
          _error = result.error;
        }
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

  void _showToc() {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (context, scrollController) => Column(
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
                    selectedTileColor: JellyTheme.primary.withValues(alpha: 0.12),
                    title: Text(
                      widget.chapters[i].title.isNotEmpty
                          ? widget.chapters[i].title
                          : '第 ${i + 1} 章',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        color: selected
                            ? JellyTheme.primary
                            : (Theme.of(context).brightness == Brightness.dark
                                ? Colors.white
                                : JellyTheme.textPrimaryLight),
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.normal,
                      ),
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
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = _darkBg ? const Color(0xFF1A1A1A) : (isDark ? const Color(0xFF121212) : const Color(0xFFF7F4EC));
    final textColor = _darkBg ? Colors.white : (isDark ? Colors.white : const Color(0xFF3A3A3A));
    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: bgColor,
        title: Text(
          _chapterTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          IconButton(
            tooltip: '字号',
            icon: const Icon(Icons.text_fields_rounded, size: 20),
            onPressed: () => _showFontSheet(textColor),
          ),
          IconButton(
            tooltip: '目录',
            icon: const Icon(Icons.list_rounded, size: 20),
            onPressed: _showToc,
          ),
        ],
      ),
      body: _buildBody(bgColor, textColor),
    );
  }

  void _showFontSheet(Color textColor) {
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '字号 ${_fontSize.round()}',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.remove_rounded, size: 20),
                  onPressed: () {
                    if (_fontSize > 12) {
                      setState(() => _fontSize -= 1);
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
                    onChanged: (v) => setState(() => _fontSize = v),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add_rounded, size: 20),
                  onPressed: () {
                    if (_fontSize < 28) {
                      setState(() => _fontSize += 1);
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ChoiceChip(
                  label: const Text('亮'),
                  selected: !_darkBg,
                  onSelected: (_) => setState(() => _darkBg = false),
                ),
                const SizedBox(width: 10),
                ChoiceChip(
                  label: const Text('暗'),
                  selected: _darkBg,
                  onSelected: (_) => setState(() => _darkBg = true),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(Color bgColor, Color textColor) {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(strokeWidth: 2.5, color: JellyTheme.primary),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline_rounded, size: 44, color: JellyTheme.textSecondary),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: JellyTheme.textSecondary),
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
          style: TextStyle(fontSize: 14, color: JellyTheme.textSecondary),
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            itemCount: _blocks.length,
            itemBuilder: (context, i) => _buildBlock(_blocks[i], textColor),
          ),
        ),
        _buildBottomBar(textColor),
      ],
    );
  }

  Widget _buildBlock(NovelBlock block, Color textColor) {
    if (block is NovelTextBlock) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Text(
          block.text,
          style: TextStyle(
            fontSize: _fontSize,
            height: 1.7,
            color: block.isHeading ? JellyTheme.primary : textColor,
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
              style: TextStyle(fontSize: 12, color: JellyTheme.textSecondary),
            ),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildBottomBar(Color textColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: _darkBg
            ? const Color(0xFF222222)
            : (Theme.of(context).brightness == Brightness.dark
                ? const Color(0xFF1E1E1E)
                : const Color(0xFFEFEAE0)),
        border: Border(
          top: BorderSide(
            color: JellyTheme.primary.withValues(alpha: 0.15),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              tooltip: '上一章',
              icon: const Icon(Icons.skip_previous_rounded, size: 22),
              color: _index > 0 ? textColor : JellyTheme.textSecondary,
              onPressed: _index > 0 ? () => _loadChapter(_index - 1) : null,
            ),
            IconButton(
              tooltip: '目录',
              icon: const Icon(Icons.list_rounded, size: 22),
              color: textColor,
              onPressed: _showToc,
            ),
            Text(
              '${_index + 1}/${widget.chapters.length}',
              style: TextStyle(fontSize: 12, color: textColor),
            ),
            IconButton(
              tooltip: '下一章',
              icon: const Icon(Icons.skip_next_rounded, size: 22),
              color: _index < widget.chapters.length - 1
                  ? textColor
                  : JellyTheme.textSecondary,
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
