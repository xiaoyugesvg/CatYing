// lib/rss/pages/rss_article_page.dart
//
// 文章正文页：封面 + 标题 + 来源·时间 + 正文（纯文本，块级换行）。
// 右上角「用网页打开」兜底（正文提取失败 / 想看图 / 想评论时用）。

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../common/theme.dart';
import '../models/rss_article.dart';
import '../models/rss_source.dart';
import '../services/rss_reader.dart';

class RssArticlePage extends StatefulWidget {
  const RssArticlePage({super.key, required this.source, required this.article});

  final RssSource source;
  final RssArticle article;

  @override
  State<RssArticlePage> createState() => _RssArticlePageState();
}

class _RssArticlePageState extends State<RssArticlePage> {
  bool _loading = true;
  String _text = '';
  String _cover = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await RssReader.fetchContent(widget.source, widget.article);
    if (!mounted) return;
    setState(() {
      _text = r.text;
      _cover = widget.article.hasImage ? widget.article.image : r.image;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.article;
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text(
          a.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style:
              TextStyle(color: AppTheme.textPrimary, fontSize: AppTheme.fontSubhead),
        ),
        actions: [
          IconButton(
            tooltip: '用网页打开',
            icon: Icon(Icons.open_in_browser_rounded,
                size: 20, color: AppTheme.textSecondary),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => _WebViewPage(url: a.link, title: a.title),
              ),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.fromLTRB(18, 6, 18, 40),
              children: [
                Text(
                  a.title,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontTitle2,
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      [a.sourceName, a.pubDate]
                          .where((e) => e.trim().isNotEmpty)
                          .join(' · '),
                      style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontCaption),
                    ),
                  ],
                ),
                if (_cover.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: CachedNetworkImage(
                      imageUrl: _cover,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                SelectableText(
                  _text,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontBody,
                    height: 1.75,
                  ),
                ),
                const SizedBox(height: 24),
                Center(
                  child: TextButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            _WebViewPage(url: a.link, title: a.title),
                      ),
                    ),
                    icon: const Icon(Icons.open_in_browser_rounded, size: 16),
                    label: const Text('用网页打开原文'),
                  ),
                ),
              ],
            ),
    );
  }
}

/// 极简网页查看页（RSS 模块自带，不依赖小程序 / 网页模块的宿主）。
class _WebViewPage extends StatefulWidget {
  const _WebViewPage({required this.url, required this.title});

  final String url;
  final String title;

  @override
  State<_WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<_WebViewPage> {
  late final WebViewController _c;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    _c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(AppTheme.backgroundPrimary)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: AppTheme.textPrimary, fontSize: AppTheme.fontSubhead),
        ),
      ),
      body: Column(
        children: [
          if (_progress > 0 && _progress < 100)
            LinearProgressIndicator(
              value: _progress / 100,
              minHeight: 2,
              backgroundColor: AppTheme.borderLight,
              valueColor: AlwaysStoppedAnimation<Color>(AppTheme.accentColor),
            ),
          Expanded(child: WebViewWidget(controller: _c)),
        ],
      ),
    );
  }
}
