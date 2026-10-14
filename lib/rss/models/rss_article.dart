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
    this.contentHtml = '',
  });

  final String title;
  final String link;
  final String image;

  /// 原始时间文本（各源格式不一：`2026-10-15 08:30` / `昨天 12:00` / ISO8601）。
  /// 不做解析、原样显示 —— 各站格式太杂，硬解反而容易显示错 ✗。
  final String pubDate;

  /// 摘要（**已去标签的纯文本**，列表里显示两行用）。
  final String description;

  /// 规则产出的**原始 HTML 正文**（`ruleDescription` / `ruleContent` 含标签时）。
  ///
  /// Legado 文档第 5/6 步：`ruleDescription` 存在就"解析到这里结束"，作者常把
  /// 它当成**整页正文模板**（用户 2026-10-15 给的「影视聚合(资源站)」就是一整页
  /// HLS 播放器 HTML）。所以这层 HTML 要**原样留给正文页渲染**，不能在列表就
  /// 用 `_stripHtml` 抹成纯文本 ✗。
  final String contentHtml;

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
        contentHtml: contentHtml,
      );
}
