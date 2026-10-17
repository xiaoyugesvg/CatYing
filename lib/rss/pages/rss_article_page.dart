// lib/rss/pages/rss_article_page.dart
//
// 文章正文页：封面 + 标题 + 来源·时间 + 正文（纯文本，块级换行）。
// 右上角「用网页打开」兜底（正文提取失败 / 想看图 / 想评论时用）。

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../common/theme.dart';
import '../../services/ad_block_service.dart';
import '../../widgets/ad_block_bubble.dart';
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

  /// 规则产出的正文是**整页 HTML**（Legado 文档里 `ruleDescription` /
  /// `ruleContent` 常被作者当成正文模板）⇒ 用 WebView 渲染，而不是当纯文本。
  bool _isHtml = false;

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
      _isHtml = r.isHtml;
      _loading = false;
    });
  }

  /// 把源的 `style`（订阅源文档字段）注入规则产出的 HTML。
  static String _injectStyle(String html, String css) {
    final c = css.trim();
    if (c.isEmpty) return html;
    final tag = '<style>\n$c\n</style>';
    final i = html.toLowerCase().indexOf('</head>');
    if (i >= 0) return html.replaceRange(i, i, tag);
    return '$tag\n$html';
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
                builder: (_) => RssWebViewPage(url: a.link, title: a.title),
              ),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : _isHtml
              // HTML 正文：整页渲染（模板内的 `<script>` / HLS 播放器都能跑）
              ? _RssHtmlView(
                  html: _injectStyle(_text, widget.source.style),
                  baseUrl: a.link.isNotEmpty ? a.link : widget.source.url,
                )
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
                            RssWebViewPage(url: a.link, title: a.title),
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

/// 用 WebView 渲染规则产出的 HTML 正文。
///
/// 订阅源文档里 `ruleDescription` / `ruleContent` 经常被作者当成**整页正文
/// 模板**（视频播放器、图文混排都用它），所以不能再当纯文本显示 ✗。
class _RssHtmlView extends StatefulWidget {
  const _RssHtmlView({required this.html, required this.baseUrl});

  final String html;
  final String baseUrl;

  @override
  State<_RssHtmlView> createState() => _RssHtmlViewState();
}

class _RssHtmlViewState extends State<_RssHtmlView> {
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
        // 去广告：正文里常带第三方脚本塞的广告层，DOM 就绪后再注入一次
        onPageFinished: (url) =>
            AdBlockService.instance.injectInto(_c, url.isEmpty ? widget.baseUrl : url),
      ));
    // 挂 JS 通道必须在加载之前
    AdBlockService.attach(_c);
    AdBlockService.instance.ensureLoaded();
    _c.loadHtmlString(widget.html, baseUrl: widget.baseUrl);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        WebViewWidget(controller: _c),
        // 去广告悬浮球：点它 → 点正文里的广告 → 存规则
        ListenableBuilder(
          listenable: AdBlockService.instance,
          builder: (_, __) => AdBlockService.instance.showBubble
              ? AdBlockBubble(
                  controller: _c,
                  pageUrl: widget.baseUrl,
                  margin: const EdgeInsets.only(right: 12, bottom: 96),
                )
              : const SizedBox.shrink(),
        ),
        if (_progress > 0 && _progress < 100)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(
              value: _progress / 100.0,
              minHeight: 2,
              backgroundColor: AppTheme.borderLight,
              valueColor: AlwaysStoppedAnimation<Color>(AppTheme.accentColor),
            ),
          ),
      ],
    );
  }
}

/// 极简网页查看页（RSS 模块自带，不依赖小程序 / 网页模块的宿主）。
class RssWebViewPage extends StatefulWidget {
  const RssWebViewPage({super.key, required this.url, required this.title});

  final String url;
  final String title;

  @override
  State<RssWebViewPage> createState() => _RssWebViewPageState();
}

class _RssWebViewPageState extends State<RssWebViewPage> {
  late final WebViewController _c;
  int _progress = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;

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
        // 去广告：网页源（站点型 RSS / 原文链接）里的广告层
        onPageStarted: (url) => AdBlockService.instance.injectInto(_c, url),
        onPageFinished: (url) {
          AdBlockService.instance.injectInto(_c, url);
          _refreshNavState();
        },
      ));
    AdBlockService.attach(_c);
    AdBlockService.instance.ensureLoaded();
    _c.loadRequest(Uri.parse(widget.url));
  }

  /// 刷新前进/后退按钮可用状态（页面跳转后调用）。
  Future<void> _refreshNavState() async {
    final b = await _c.canGoBack();
    final f = await _c.canGoForward();
    if (mounted) setState(() { _canGoBack = b; _canGoForward = f; });
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
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: WebViewWidget(controller: _c)),
                // 去广告悬浮球
                ListenableBuilder(
                  listenable: AdBlockService.instance,
                  builder: (_, __) => AdBlockService.instance.showBubble
                      ? AdBlockBubble(
                          controller: _c,
                          pageUrl: widget.url,
                          margin: const EdgeInsets.only(right: 12, bottom: 96),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ],
      ),
      // 底栏：返回上一页 / 刷新当前页 / 下一页（对齐浏览器常用导航）
      bottomNavigationBar: BottomAppBar(
        color: AppTheme.backgroundSecondary,
        elevation: 0,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _navBtn(
              icon: Icons.arrow_back_ios_new_rounded,
              label: '返回',
              enabled: _canGoBack,
              onTap: () async {
                if (await _c.canGoBack()) {
                  await _c.goBack();
                }
              },
            ),
            _navBtn(
              icon: Icons.refresh_rounded,
              label: '刷新',
              enabled: true,
              onTap: () => _c.reload(),
            ),
            _navBtn(
              icon: Icons.arrow_forward_ios_rounded,
              label: '前进',
              enabled: _canGoForward,
              onTap: () async {
                if (await _c.canGoForward()) {
                  await _c.goForward();
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 底栏按钮：图标在上、文字在下，禁用时置灰。
  Widget _navBtn({
    required IconData icon,
    required String label,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final color = enabled
        ? AppTheme.textPrimary
        : AppTheme.textTertiary.withValues(alpha: 0.4);
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 3),
            Text(label,
                style: TextStyle(fontSize: 11, color: color)),
          ],
        ),
      ),
    );
  }
}
