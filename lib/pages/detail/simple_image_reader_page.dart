// lib/pages/detail/simple_image_reader_page.dart
//
// 简易看图阅读器 —— 给「图片列表协议」（`pics://` / `mange://…`）的漫画、
// 图源用。
//
// ── 为什么单独一个页面 ────────────────────────────────────────
// 猫源里的 py 漫画源（如包子漫画）`playerContent` 返回的**不是视频地址**，
// 而是整章图片拼成的 `pics://图1&&图2&&…`。这类内容丢给播放器只会黑屏，
// 所以要**按内容**识别出来直接进阅读器（不需要任何设置项）。
//
// ── 刻意做得很薄 ─────────────────────────────────────────────
// 只有「标题 + 图片的纵向滚动」。**但支持自动续章**（2026-10-16 补）：
// 海阔官方对 `pics://` 的行为是「下拉会尝试执行下一集的动态解析，实现自动下一章」
// （见官方 `help_link.json` 的 pics 说明）—— 这里等价实现为：
// 滑到底部时调 [SimpleImageReaderPage.onLoadNextChapter]，把新一页的图片**追加**在
// 同一列里继续往下滑。旧行为（只有一章、换章要返回详情页）已不再适用。

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// 一次「取下一章」的结果：新图片 + 再下一章的地址（空 = 到头了）
typedef NextChapterResult = ({List<String> images, String nextPage});

class SimpleImageReaderPage extends StatefulWidget {
  const SimpleImageReaderPage({
    super.key,
    required this.title,
    required this.images,
    this.chapterName = '',
    this.httpHeaders = const {},
    this.onLoadNextChapter,
  });

  /// 作品名（漫画名）
  final String title;

  /// 本章图片 URL（按顺序）
  final List<String> images;

  /// 章节名（可空）
  final String chapterName;

  /// 图片请求头（防盗链源用；空则不带）
  final Map<String, String> httpHeaders;

  /// **下拉自动下一章**：滑到底部附近时调用；返回空图片表示没有下一章了。
  /// 为 null 表示这个来源不支持（例如影视模块的 `pics://` 漫画源只给一章）。
  final Future<NextChapterResult> Function()? onLoadNextChapter;

  /// 便捷打开（走 GetX 路由，controller / view 都能调，避免两边各写一遍）。
  static void open({
    required String title,
    required List<String> images,
    String chapterName = '',
    Map<String, String> headers = const {},
    Future<NextChapterResult> Function()? onLoadNextChapter,
  }) {
    Get.to(
      () => SimpleImageReaderPage(
        title: title,
        images: images,
        chapterName: chapterName,
        httpHeaders: headers,
        onLoadNextChapter: onLoadNextChapter,
      ),
    );
  }

  @override
  State<SimpleImageReaderPage> createState() => _SimpleImageReaderPageState();
}

class _SimpleImageReaderPageState extends State<SimpleImageReaderPage> {
  final _scroll = ScrollController();

  /// 当前列表（本章 + 已自动续上的后续章节，拼在同一列里）
  late List<String> _images = List<String>.from(widget.images);

  bool _loading = false;

  /// 没有下一章了（源没给 nextPage，或返回空）
  bool _noMore = false;

  /// 上一次拉取失败（网络/规则报错）→ 底部给「重试」而不是"没有更多"
  bool _failed = false;

  /// 距底部多少像素就预加载（一屏多一点，滑到快到底时正好接上）
  static const double _prefetch = 800;

  bool get _canLoadMore =>
      widget.onLoadNextChapter != null && !_loading && !_noMore;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    if (widget.onLoadNextChapter != null && _images.isEmpty) {
      // 首次进来就是空章：直接试着拉下一章（有些源正文在 nextPage 上）
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadNext());
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || !_canLoadMore || _failed) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - _prefetch) _loadNext();
  }

  /// 拉下一章并**追加**到当前列（官方 `setNextPage` 的"下拉自动下一章"）
  Future<void> _loadNext() async {
    final cb = widget.onLoadNextChapter;
    if (cb == null || _loading || _noMore) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final r = await cb();
      if (!mounted) return;
      final add = <String>[];
      for (final u in r.images) {
        if (u.isEmpty || _images.contains(u) || add.contains(u)) continue;
        add.add(u);
      }
      setState(() {
        _loading = false;
        _images = [..._images, ...add];
        // 源没给 nextPage（或这章一张图都没出）⇒ 到头了
        if (r.nextPage.isEmpty || (add.isEmpty && r.images.isEmpty)) {
          _noMore = true;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final headers = widget.httpHeaders.isEmpty ? null : widget.httpHeaders;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: const TextStyle(fontSize: 15),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (widget.chapterName.isNotEmpty)
              Text(
                widget.chapterName,
                style: const TextStyle(fontSize: 11, color: Colors.white70),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(
                '${_images.length} 张',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ),
          ),
        ],
      ),
      body: _images.isEmpty
          ? Center(
              child: _loading
                  ? const CircularProgressIndicator(color: Colors.white24)
                  : const Text('（这一章没有图片）',
                      style: TextStyle(color: Colors.white70)),
            )
          : ListView.builder(
              controller: _scroll,
              padding: EdgeInsets.zero,
              // 末位多一项：续章状态条（加载中 / 没有更多 / 重试）
              itemCount: _images.length + (widget.onLoadNextChapter == null ? 0 : 1),
              itemBuilder: (context, i) {
                if (i >= _images.length) return _footer();
                return _ImageTile(url: _images[i], headers: headers);
              },
            ),
    );
  }

  /// 底部状态条：滑到这儿就自动续了，也能手点
  Widget _footer() {
    final String text;
    if (_loading) {
      text = '正在加载下一章…';
    } else if (_failed) {
      text = '下一章加载失败，点这里重试';
    } else if (_noMore) {
      text = '没有下一章了';
    } else {
      text = '继续下拉加载下一章';
    }
    return InkWell(
      onTap: (_loading || _noMore) ? null : _loadNext,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 22),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_loading) ...[
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white24),
              ),
              const SizedBox(width: 8),
            ],
            Text(
              text,
              style: const TextStyle(fontSize: 13, color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单张漫画页：占满宽度、按原比例显示（不裁切）。
class _ImageTile extends StatelessWidget {
  const _ImageTile({required this.url, this.headers});

  final String url;
  final Map<String, String>? headers;

  @override
  Widget build(BuildContext context) {
    return CachedNetworkImage(
      imageUrl: url,
      httpHeaders: headers,
      width: double.infinity,
      // fitWidth + 高度自适应：整页图片完整显示，不裁切（与封面同一原则）
      fit: BoxFit.fitWidth,
      // 加载前按常见漫画页比例占位，避免整页高度抖动
      placeholder: (_, __) => const AspectRatio(
        aspectRatio: 2 / 3,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white24,
            ),
          ),
        ),
      ),
      errorBuilder: (_, __, ___) => const AspectRatio(
        aspectRatio: 2 / 3,
        child: Center(
          child: Icon(Icons.broken_image_rounded,
              color: Colors.white38, size: 32),
        ),
      ),
    );
  }
}
