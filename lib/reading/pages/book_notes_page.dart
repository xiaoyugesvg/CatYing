import 'package:flutter/material.dart';

import '../services/reader_notes_service.dart';
import '../theme/jelly_theme.dart';

/// 全书库划线笔记：按书分组 → 每本书的划线/批注列表。
///
/// 用户 2026-10-17：「笔记要单独（一个入口），不要和阅读历程放一起」
/// —— 从原 `NotesAndJourneyPage` 里拆出来，独立成页。
class BookNotesPage extends StatefulWidget {
  const BookNotesPage({super.key});

  @override
  State<BookNotesPage> createState() => BookNotesPageState();
}

class BookNotesPageState extends State<BookNotesPage> {
  @override
  void initState() {
    super.initState();
    ReaderNotesService.instance.init();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final card = isDark ? JellyTheme.cardDark : JellyTheme.cardLight;
    final groups = ReaderNotesService.instance.bookGroups();
    final total = groups.fold<int>(0, (s, g) => s + g.count);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('我的笔记'),
        actions: [
          if (groups.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  '$total 条',
                  style: TextStyle(
                      fontSize: 13, color: JellyTheme.textSecondary),
                ),
              ),
            ),
        ],
      ),
      body: groups.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.edit_note_rounded,
                      size: 56,
                      color: isDark ? Colors.white24 : Colors.black26),
                  const SizedBox(height: 14),
                  Text(
                    '还没有任何笔记',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color:
                          isDark ? Colors.white : JellyTheme.textPrimaryLight,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '在阅读器里长按段落即可划线、写批注',
                    style: TextStyle(
                        fontSize: 13,
                        color: JellyTheme.textSecondary,
                        height: 1.6),
                  ),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              itemCount: groups.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                final g = groups[i];
                final notes = ReaderNotesService.instance
                    .forBook(g.sourceId, g.bookName);
                return _BookNoteGroup(
                  isDark: isDark,
                  card: card,
                  sourceName: g.sourceId.contains('config:')
                      ? g.sourceId.replaceFirst('config:', '')
                      : '',
                  bookName: g.bookName,
                  count: g.count,
                  notes: notes,
                );
              },
            ),
    );
  }
}

class _BookNoteGroup extends StatefulWidget {
  const _BookNoteGroup({
    required this.isDark,
    required this.card,
    required this.sourceName,
    required this.bookName,
    required this.count,
    required this.notes,
  });

  final bool isDark;
  final Color card;
  final String sourceName;
  final String bookName;
  final int count;
  final List<ReaderNote> notes;

  @override
  State<_BookNoteGroup> createState() => _BookNoteGroupState();
}

class _BookNoteGroupState extends State<_BookNoteGroup> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final labelColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Container(
      decoration: BoxDecoration(
        color: widget.card,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.bookName,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: labelColor,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${widget.sourceName.isEmpty ? '' : '${widget.sourceName} · '}'
                          '${widget.count} 条',
                          style: TextStyle(
                              fontSize: 12, color: JellyTheme.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: JellyTheme.textSecondary,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Column(
                children: [
                  for (final n in widget.notes)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: JellyTheme.primary.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(12),
                        border: Border(
                          left: BorderSide(color: Color(n.color), width: 3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            n.chapterName.isEmpty
                                ? '第${n.chapterIndex + 1}章'
                                : n.chapterName,
                            style: TextStyle(
                                fontSize: 12, color: JellyTheme.textSecondary),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            n.text,
                            style: TextStyle(
                                fontSize: 13,
                                color: labelColor,
                                height: 1.5),
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (n.hasNote) ...[
                            const SizedBox(height: 4),
                            Text(
                              '批注：${n.note}',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Color(n.color),
                                  height: 1.4),
                            ),
                          ],
                          Align(
                            alignment: Alignment.centerRight,
                            child: GestureDetector(
                              onTap: () async {
                                await ReaderNotesService.instance.remove(n.id);
                                if (mounted) setState(() {});
                              },
                              child: Text('删除',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: JellyTheme.textSecondary)),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
