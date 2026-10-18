import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/book_source.dart';
import '../services/book_source_service.dart';
import '../theme/jelly_theme.dart';
import '../../common/theme.dart';

/// 换源页 —— 参考图 IMG_8482 / IMG_8483。
///
/// 确认态：说明区 + 「开始搜索」；
/// 搜索态：顶部实时进度「正在搜索 x/N 个源 · 找到 M 本」+ 结果列表边搜边插；
/// 点中一个结果后 pop 返回给详情页替换当前源。
class BookSourceSwitchPage extends StatefulWidget {
  const BookSourceSwitchPage({
    super.key,
    required this.bookName,
    required this.author,
    required this.sources,
    required this.currentSource,
  });

  final String bookName;
  final String author;
  final List<BookSource> sources;
  final BookSource currentSource;

  @override
  State<BookSourceSwitchPage> createState() => _BookSourceSwitchPageState();
}

class _BookSourceSwitchPageState extends State<BookSourceSwitchPage> {
  final store = BookSourceStore.instance;

  bool _searching = false;
  bool _done = false;
  int _doneCount = 0;
  final List<BookSourceResult> _results = [];

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _titleColor =>
      _isDark ? Colors.white : JellyTheme.textPrimaryLight;

  Future<void> _startSearch() async {
    setState(() {
      _searching = true;
      _done = false;
      _doneCount = 0;
      _results.clear();
    });
    await BookSourceService.instance.searchAll(
      widget.sources,
      widget.bookName,
      onSourceDone: (st) {
        if (!mounted) return;
        setState(() => _doneCount++);
      },
      onSourceResults: (st, list) {
        if (!mounted) return;
        if (list.isEmpty) return;
        setState(() {
          for (final r in list) {
            if (!_results.any((e) =>
                e.source.id == r.source.id &&
                e.bookUrl == r.bookUrl)) {
              _results.add(r);
            }
          }
        });
      },
      shouldStop: () => !mounted,
    );
    if (!mounted) return;
    setState(() {
      _searching = false;
      _done = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.sources.length;
    return Scaffold(
      backgroundColor:
          _isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(widget.bookName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: AppTheme.fontTitle3,
                      fontWeight: FontWeight.w700,
                      color: _titleColor)),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: JellyTheme.primary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('换源',
                  style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      color: JellyTheme.primary,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        actions: const [SizedBox(width: 4)],
      ),
      body: Column(
        children: [
          // ── 说明 / 进度区（与漫画聚搜页同一套卡片语言）──
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: _isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: (_isDark ? Colors.white : JellyTheme.primary)
                    .withValues(alpha: 0.06),
                width: 0.6,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('在其他书源里找同名书',
                    style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        fontWeight: FontWeight.w700,
                        color: _titleColor)),
                const SizedBox(height: 4),
                Text('按书名「${widget.bookName}」搜索',
                    style: TextStyle(
                        fontSize: AppTheme.fontFootnote,
                        color: JellyTheme.textSecondary)),
                const SizedBox(height: 2),
                Text(
                  _searching || _done
                      ? '正在搜索 $_doneCount/$total 个源 · 找到 ${_results.length} 本'
                      : '共 $total 个启用书源，一轮搜 50 个（同时 10 路）',
                  style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: _searching ? JellyTheme.primary : JellyTheme.textSecondary,
                      fontWeight:
                          _searching ? FontWeight.w600 : FontWeight.normal),
                ),
                if (_searching) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: total == 0 ? 0 : _doneCount / total,
                      color: JellyTheme.primary,
                      backgroundColor:
                          JellyTheme.textSecondary.withValues(alpha: 0.18),
                      minHeight: 4,
                    ),
                  ),
                ],
                if (!_searching && !_done) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: JellyTheme.primary,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: total == 0 ? null : _startSearch,
                      icon: const Icon(Icons.search_rounded, size: 18),
                      label: const Text('开始搜索',
                          style: TextStyle(
                              fontSize: AppTheme.fontBody,
                              color: Colors.white,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: _results.isEmpty
                ? _empty()
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                    itemCount: _results.length,
                    itemBuilder: (c, i) => _resultTile(_results[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _empty() {
    if (_searching) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('正在其它书源中查找...'),
          ],
        ),
      );
    }
    if (_done) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off_rounded,
                size: 48, color: Colors.orangeAccent),
            const SizedBox(height: 12),
            Text('其它书源里没找到《${widget.bookName}》',
                style: TextStyle(
                    fontSize: AppTheme.fontSubhead,
                    color: JellyTheme.textSecondary)),
          ],
        ),
      );
    }
    return Center(
      child: Text('点击「开始搜索」在其它书源中查找同名书',
          style: TextStyle(
              fontSize: AppTheme.fontSubhead,
              color: JellyTheme.textSecondary)),
    );
  }

  Widget _resultTile(BookSourceResult r) {
    final isCurrent = r.source.id == widget.currentSource.id;
    final isDark = _isDark;
    final cardColor = isDark ? JellyTheme.cardDark : JellyTheme.cardLight;
    final secondary = JellyTheme.textSecondary;
    final meta = <String>[
      if (r.author.isNotEmpty) r.author,
      if (r.lastChapter.isNotEmpty) '最新：${r.lastChapter}',
    ].join(' · ');
    final intro = r.intro.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: cardColor,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => Navigator.pop(context, r),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                // 封面：与漫画列表卡同一比例（3:4），无图时书图标兜底
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 72,
                    height: 96,
                    child: r.coverUrl.isEmpty
                        ? Container(
                            color: JellyTheme.primary.withValues(alpha: 0.1),
                            child: Icon(Icons.menu_book_rounded,
                                size: 26, color: JellyTheme.primary),
                          )
                        : CachedNetworkImage(
                            imageUrl: r.coverUrl,
                            fit: BoxFit.cover,
                            memCacheWidth: 200,
                            placeholder: (_, __) => Container(
                              color: JellyTheme.primary.withValues(alpha: 0.06),
                            ),
                            errorWidget: (_, __, ___) => Container(
                              color:
                                  JellyTheme.primary.withValues(alpha: 0.1),
                              child: Icon(Icons.menu_book_rounded,
                                  size: 26, color: JellyTheme.primary),
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              r.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: AppTheme.fontSubhead + 1,
                                  fontWeight: FontWeight.w700,
                                  color: _titleColor),
                            ),
                          ),
                          if (isCurrent)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: JellyTheme.primary
                                    .withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text('当前',
                                  style: TextStyle(
                                      fontSize: AppTheme.fontCaption,
                                      color: JellyTheme.primary,
                                      fontWeight: FontWeight.w600)),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      // 来源 / 分类胶囊：与漫画列表的「作者胶囊」同一套观感
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          _metaChip(r.source.name, JellyTheme.primary),
                          if (r.kind.trim().isNotEmpty)
                            _metaChip(r.kind.trim(), secondary),
                        ],
                      ),
                      if (meta.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: AppTheme.fontCaption,
                              color: secondary),
                        ),
                      ] else if (intro.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          intro,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: AppTheme.fontCaption,
                              color: secondary),
                        ),
                      ],
                      if (r.wordCount.trim().isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          r.wordCount.trim(),
                          style: TextStyle(
                              fontSize: AppTheme.fontCaption,
                              color: secondary.withValues(alpha: 0.8)),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right_rounded,
                    size: 20, color: secondary.withValues(alpha: 0.7)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 小胶囊（来源 / 分类）
  Widget _metaChip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: AppTheme.fontCaption,
          color: color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
