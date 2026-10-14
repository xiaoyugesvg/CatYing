// lib/pages/detail/simple_text_reader_page.dart
//
// 简易书籍阅读器 —— 给「正文协议」（`novel://` / `book://` / `txt://`）的
// 小说源用。
//
// ── 为什么单独一个页面 ────────────────────────────────────────
// 猫源里的小说源（如速读谷）`playerContent` 返回的**不是视频地址**，而是
// `novel://{"title":"第x章","content":"正文…"}`。这类内容丢给播放器只会黑屏，
// 所以要**按内容**识别出来直接进阅读器（不需要任何设置项）。
//
// ── 刻意做得很薄 ─────────────────────────────────────────────
// 只有「标题 + 正文 + 字号加减」。章节切换交回影视详情页的「合集」列表，
// 这里不重复一套目录 UI（用户口径就是"简易"）。

import 'package:flutter/material.dart';
import 'package:get/get.dart';

class SimpleTextReaderPage extends StatefulWidget {
  const SimpleTextReaderPage({
    super.key,
    required this.content,
    this.bookName = '',
    this.chapterName = '',
  });

  /// 正文（纯文本）
  final String content;

  /// 书名（次标题）
  final String bookName;

  /// 章节名（主标题）
  final String chapterName;

  /// 便捷打开（走 GetX 路由，controller / view 都能调，避免两边各写一遍）。
  static void open({
    required String content,
    String bookName = '',
    String chapterName = '',
  }) {
    Get.to(
      () => SimpleTextReaderPage(
        content: content,
        bookName: bookName,
        chapterName: chapterName,
      ),
    );
  }

  @override
  State<SimpleTextReaderPage> createState() => _SimpleTextReaderPageState();
}

class _SimpleTextReaderPageState extends State<SimpleTextReaderPage> {
  final _scrollCtrl = ScrollController();
  double _fontSize = 17;

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.chapterName.trim().isNotEmpty
        ? widget.chapterName.trim()
        : (widget.bookName.trim().isNotEmpty ? widget.bookName.trim() : '正文');
    final sub = widget.chapterName.trim().isNotEmpty &&
            widget.bookName.trim().isNotEmpty
        ? widget.bookName.trim()
        : '';
    final text = widget.content.replaceAll('\r\n', '\n').trim();

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 15),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (sub.isNotEmpty)
              Text(
                sub,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).textTheme.bodySmall?.color,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '缩小字号',
            icon: const Icon(Icons.text_decrease_rounded),
            onPressed: () =>
                setState(() => _fontSize = (_fontSize - 1).clamp(12, 30)),
          ),
          IconButton(
            tooltip: '放大字号',
            icon: const Icon(Icons.text_increase_rounded),
            onPressed: () =>
                setState(() => _fontSize = (_fontSize + 1).clamp(12, 30)),
          ),
        ],
      ),
      body: text.isEmpty
          ? const Center(child: Text('（没有取到正文）'))
          : SingleChildScrollView(
              controller: _scrollCtrl,
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 40),
              child: SelectableText(
                text,
                style: TextStyle(fontSize: _fontSize, height: 1.8),
              ),
            ),
    );
  }
}
