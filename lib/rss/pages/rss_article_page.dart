// lib/rss/pages/rss_article_page.dart
//
// 文章正文页：封面 + 标题 + 来源·时间 + 正文（纯文本，块级换行）。
// 右上角「用网页打开」兜底（正文提取失败 / 想看图 / 想评论时用）。

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../common/theme.dart';
import '../../miniapp/pages/mini_app_player_page.dart';
import '../../pages/play/sniff_player_page.dart';
import '../../services/ad_block_service.dart';
import '../../services/third_party_nav_guard.dart';
import '../../widgets/ad_block_bubble.dart';
import '../models/rss_article.dart';
import '../models/rss_source.dart';
import '../services/rss_reader.dart';
import '../../reading/services/tts_service.dart';

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

  /// 正文像「影视详情页」（线路 / 第 x 集 / 播放方式）⇒ 提供在线播放入口。
  bool _videoLike = false;

  /// 详情页里解析出的线路 / 集数（解析不到时退回网页播放）。
  List<RssVideoLine> _videoLines = const [];
  int _lineIdx = 0;
  bool _resolving = false;

  /// 正文页图片数：图集型文章（秀人岛 / 凹凸吧 / 下厨房步骤图）文字提取
  /// 出来几乎没有内容，默认直接显示原网页。
  int _imageCount = 0;
  bool _webMode = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 朗读正文（2026-10-22，Legado 订阅源同款能力）
  Future<void> _toggleTts() async {
    final t = TtsService.instance;
    if (t.isSpeaking.value) {
      await t.stop();
      return;
    }
    final plain = _text.trim();
    if (plain.isEmpty) return;
    await t.speak(plain);
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await RssReader.fetchContent(widget.source, widget.article);
    if (!mounted) return;
    final videoLike = !r.isHtml && _looksVideo(r.text);
    // 图集页（图片多）或正文几乎没提取出来 ⇒ 直接看原网页，和浏览器一致。
    final weakText = !r.isHtml && r.text.trim().length < 60;
    setState(() {
      _text = r.text;
      _cover = widget.article.hasImage ? widget.article.image : r.image;
      _isHtml = r.isHtml;
      _videoLike = videoLike;
      _imageCount = r.imageCount;
      _webMode = !videoLike && (r.imageCount >= 8 || weakText);
      _loading = false;
    });
    if (_videoLike) _loadVideoLines();
  }

  /// 另外抓一次详情页 HTML，把线路 / 分集链接抠出来（不阻塞正文显示）。
  Future<void> _loadVideoLines() async {
    try {
      final lines =
          await RssReader.fetchVideoLines(widget.source, widget.article);
      if (!mounted || lines.isEmpty) return;
      setState(() {
        _videoLines = lines;
        _lineIdx = 0;
      });
    } catch (_) {}
  }

  Future<void> _playEpisode(RssVideoEpisode ep) async {
    if (_resolving) return;
    setState(() => _resolving = true);
    // 不用模态弹窗：系统返回键可能把弹窗提前 pop 掉，之后下面那次 pop 就会
    // 误关正文页。用 SnackBar + 卡片里的小转圈表示进度，最多等 20 秒。
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('正在解析播放地址…'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
    String? direct;
    try {
      direct = await RssReader.resolvePlayUrl(widget.source, ep.url)
          .timeout(const Duration(seconds: 20));
    } catch (_) {}
    if (!mounted) return;
    setState(() => _resolving = false);

    final title = '${widget.article.title} ${ep.title}';
    final headers = RssReader.playHeaders(widget.source);
    final playUrl = direct?.trim() ?? '';
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => playUrl.isNotEmpty
            ? MiniAppPlayerPage(url: playUrl, title: title, headers: headers)
            // 拿不到直链（加密/JS 拼接）→ 打开播放页嗅探
            : SniffPlayerPage(url: ep.url, title: title, headers: headers),
      ),
    );
  }

  /// 视频详情页特征：有「线路」+ 集数（电影则看「线路」+ 演职员信息），
  /// 或正文里直接出现媒体地址。
  static bool _looksVideo(String text) {
    final t = text.toLowerCase();
    if (t.contains('.m3u8') || t.contains('<video') || t.contains('<iframe')) {
      return true;
    }
    final hasLine = text.contains('线路') ||
        text.contains('播放列表') ||
        text.contains('播放地址');
    if (!hasLine) return false;
    final hasEpisode =
        RegExp(r'第\s*\d+\s*[集话期]').hasMatch(text) || text.contains('更新至第');
    final hasMeta =
        text.contains('类型') && (text.contains('主演') || text.contains('导演'));
    return hasEpisode || hasMeta;
  }

  void _openPlayPage() {
    final a = widget.article;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SniffPlayerPage(url: a.link, title: a.title),
      ),
    );
  }

  /// 影视详情页的播放入口：打开原网页（可点线路/集数），
  /// 页面里的视频地址由嗅探页自动抓出来交给原生播放器。
  Widget _playEntry() {
    return InkWell(
      onTap: _openPlayPage,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppTheme.accentColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: AppTheme.accentColor.withValues(alpha: 0.35),
            width: 0.6,
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.play_circle_fill_rounded,
                size: 24, color: AppTheme.accentColor),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '在线播放',
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.accentColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '打开原网页选线路/集数，自动嗅探视频地址',
                    style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      color: AppTheme.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 20, color: AppTheme.textTertiary),
          ],
        ),
      ),
    );
  }

  /// 分集卡片：线路切换 + 集数按钮（点一集直接解析直链播放）。
  Widget _videoCard() {
    final lines = _videoLines;
    if (lines.isEmpty) return const SizedBox.shrink();
    final idx = _lineIdx >= lines.length ? lines.length - 1 : _lineIdx;
    final line = lines[idx];
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderLight, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.play_circle_fill_rounded,
                  size: 20, color: AppTheme.accentColor),
              const SizedBox(width: 8),
              Text(
                '在线播放',
                style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              const Spacer(),
              if (_resolving)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppTheme.accentColor),
                )
              else
                Text(
                  '${line.episodes.length} 集',
                  style: TextStyle(
                    fontSize: AppTheme.fontCaption,
                    color: AppTheme.textTertiary,
                  ),
                ),
            ],
          ),
          if (lines.length > 1) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (var i = 0; i < lines.length; i++)
                  GestureDetector(
                    onTap: () => setState(() => _lineIdx = i),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: i == idx
                            ? AppTheme.accentColor.withValues(alpha: 0.16)
                            : (dark
                                ? Colors.white.withValues(alpha: 0.06)
                                : Colors.black.withValues(alpha: 0.04)),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: i == idx
                              ? AppTheme.accentColor.withValues(alpha: 0.5)
                              : Colors.transparent,
                          width: 0.6,
                        ),
                      ),
                      child: Text(
                        lines[i].name,
                        style: TextStyle(
                          fontSize: AppTheme.fontCaption,
                          fontWeight: i == idx
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: i == idx
                              ? AppTheme.accentColor
                              : AppTheme.textSecondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final ep in line.episodes)
                GestureDetector(
                  onTap: _resolving ? null : () => _playEpisode(ep),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 7),
                    decoration: BoxDecoration(
                      color: AppTheme.accentColor.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: AppTheme.accentColor.withValues(alpha: 0.30),
                        width: 0.6,
                      ),
                    ),
                    child: Text(
                      ep.title,
                      style: TextStyle(
                        fontSize: AppTheme.fontFootnote,
                        color: AppTheme.accentColor,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
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
          // 朗读正文（纯文本模式；HTML/网页模式没有可朗读正文）
          Obx(() {
            final speaking = TtsService.instance.isSpeaking.value;
            return IconButton(
              tooltip: speaking ? '停止朗读' : '朗读正文',
              icon: Icon(
                speaking ? Icons.stop_circle_outlined : Icons.volume_up_rounded,
                size: 20,
                color: AppTheme.textSecondary,
              ),
              onPressed:
                  (_loading || _webMode || _isHtml || _text.trim().isEmpty)
                      ? null
                      : _toggleTts,
            );
          }),
          // 正文 / 网页切换：图集型文章默认网页；其它文章也能手动切过去看原文
          IconButton(
            tooltip: _webMode
                ? '看正文'
                : (_imageCount > 0 ? '看网页（$_imageCount 张图）' : '看网页'),
            icon: Icon(
              _webMode ? Icons.article_outlined : Icons.language_rounded,
              size: 20,
              color: AppTheme.textSecondary,
            ),
            onPressed: _loading
                ? null
                : () => setState(() => _webMode = !_webMode),
          ),
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
          : _webMode
              // 图集 / 正文提取为空：直接内嵌原网页（站点自己的 JS、图片、
              // 防盗链都按浏览器行为走，和「用网页打开」看到的一致）。
              ? _RssPageView(
                  key: ValueKey('rss_page_${a.link}'),
                  url: a.link,
                )
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
                if (_videoLines.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _videoCard(),
                ] else if (_videoLike) ...[
                  const SizedBox(height: 14),
                  _playEntry(),
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

/// 内嵌原网页（图集型文章 / 正文提取为空时用）。
///
/// 直接 `loadRequest`，而不是把抓下来的 HTML 塞给 WebView —— 站点自己的
/// JS、Cookie、防盗链（凹凸吧的图片会校验 Sec-Fetch）都按浏览器行为走。
class _RssPageView extends StatefulWidget {
  const _RssPageView({super.key, required this.url});

  final String url;

  @override
  State<_RssPageView> createState() => _RssPageViewState();
}

class _RssPageViewState extends State<_RssPageView> {
  late final WebViewController _c;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    _c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(AppTheme.backgroundPrimary)
      ..setUserAgent(
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
        'Mobile/15E148 Safari/604.1',
      )
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
        onPageFinished: (url) => _injectAds(url),
        // 跳第三方站点先弹窗确认（默认禁止，见「设置 → 广告管理」）
        onNavigationRequest: (req) => ThirdPartyNavGuard.decide(
          context,
          target: req.url,
          siteUrl: widget.url,
        ),
      ));
    AdBlockService.attach(_c);
    AdBlockService.instance.ensureLoaded();
    _c.loadRequest(Uri.parse(widget.url));
  }

  void _injectAds(String url) {
    final target = url.isEmpty ? widget.url : url;
    AdBlockService.instance.injectInto(_c, target);
    for (final ms in const [1200, 3000, 6000]) {
      Future<void>.delayed(Duration(milliseconds: ms), () {
        if (mounted) AdBlockService.instance.injectInto(_c, target);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        WebViewWidget(controller: _c),
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
            _injectAds(url.isEmpty ? widget.baseUrl : url),
      ));
    // 挂 JS 通道必须在加载之前
    AdBlockService.attach(_c);
    AdBlockService.instance.ensureLoaded();
    _c.loadHtmlString(widget.html, baseUrl: widget.baseUrl);
    _injectAds(widget.baseUrl);
  }

  /// 去广告注入 + 延迟补注入。
  ///
  /// 用户 2026-10-20：「广告也去不掉」（主要指 RSS）。很多广告是在正文脚本
  /// 跑完之后才插进 DOM 的，只在 `onPageFinished` 注入一次抓不到；这里在
  /// 1.2s / 3s / 6s 再补几次，覆盖延迟加载的广告位。
  void _injectAds(String url) {
    AdBlockService.instance.injectInto(_c, url);
    for (final ms in const [1200, 3000, 6000]) {
      Future<void>.delayed(Duration(milliseconds: ms), () {
        if (mounted) AdBlockService.instance.injectInto(_c, url);
      });
    }
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
          _injectAdsDelayed(url);
          _refreshNavState();
        },
        // 跳第三方站点先弹窗确认（默认禁止，见「设置 → 广告管理」）
        onNavigationRequest: (req) => ThirdPartyNavGuard.decide(
          context,
          target: req.url,
          siteUrl: widget.url,
        ),
      ));
    AdBlockService.attach(_c);
    AdBlockService.instance.ensureLoaded();
    _c.loadRequest(Uri.parse(widget.url));
  }

  /// 去广告注入 + 延迟补注入（覆盖脚本跑完后才插进来的广告位）。
  void _injectAdsDelayed(String url) {
    final target = url.isEmpty ? widget.url : url;
    AdBlockService.instance.injectInto(_c, target);
    for (final ms in const [1200, 3000, 6000]) {
      Future<void>.delayed(Duration(milliseconds: ms), () {
        if (mounted) AdBlockService.instance.injectInto(_c, target);
      });
    }
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
