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
// 只有「标题 + 一章图片的纵向滚动」。章节切换交回影视详情页的「合集」列表，
// 这里不重复一套目录 UI（用户口径就是"简易"）。

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class SimpleImageReaderPage extends StatelessWidget {
  const SimpleImageReaderPage({
    super.key,
    required this.title,
    required this.images,
    this.chapterName = '',
    this.httpHeaders = const {},
  });

  /// 作品名（漫画名）
  final String title;

  /// 本章图片 URL（按顺序）
  final List<String> images;

  /// 章节名（可空）
  final String chapterName;

  /// 图片请求头（防盗链源用；空则不带）
  final Map<String, String> httpHeaders;

  /// 便捷打开（走 GetX 路由，controller / view 都能调，避免两边各写一遍）。
  static void open({
    required String title,
    required List<String> images,
    String chapterName = '',
    Map<String, String> headers = const {},
  }) {
    Get.to(
      () => SimpleImageReaderPage(
        title: title,
        images: images,
        chapterName: chapterName,
        httpHeaders: headers,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final headers = httpHeaders.isEmpty ? null : httpHeaders;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 15),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (chapterName.isNotEmpty)
              Text(
                chapterName,
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
                '${images.length} 张',
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ),
          ),
        ],
      ),
      body: images.isEmpty
          ? const Center(
              child: Text('（这一章没有图片）',
                  style: TextStyle(color: Colors.white70)),
            )
          : ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: images.length,
              itemBuilder: (context, i) =>
                  _ImageTile(url: images[i], headers: headers),
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
      errorWidget: (_, __, ___) => const AspectRatio(
        aspectRatio: 2 / 3,
        child: Center(
          child: Icon(Icons.broken_image_rounded,
              color: Colors.white38, size: 32),
        ),
      ),
    );
  }
}
