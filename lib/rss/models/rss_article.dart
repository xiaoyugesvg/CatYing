// lib/rss/models/rss_article.dart
//
// 一篇文章（列表项 / 正文都用它）。

/// 订阅源里的一篇文章。
class RssArticle {
  const RssArticle({
    required this.title,
    required this.link,
    this.image = '',
    this.pubDate = '',
    this.description = '',
    this.sourceId = '',
    this.sourceName = '',
  });

  final String title;
  final String link;
  final String image;

  /// 原始时间文本（各源格式不一：`2026-10-15 08:30` / `昨天 12:00` / ISO8601）。
  /// 不做解析、原样显示 —— 各站格式太杂，硬解反而容易显示错 ✗。
  final String pubDate;

  /// 摘要（可能含 HTML）。
  final String description;

  final String sourceId;
  final String sourceName;

  bool get hasImage => image.trim().startsWith('http');

  RssArticle copyWith({String? description, String? image}) => RssArticle(
        title: title,
        link: link,
        image: image ?? this.image,
        pubDate: pubDate,
        description: description ?? this.description,
        sourceId: sourceId,
        sourceName: sourceName,
      );
}
