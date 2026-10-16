// 在线阅读 WebView 页：注入 z-library 登录 cookie 后加载 readOnlineUrl，
// 免去在外部浏览器重新登录。桌面端（webview_flutter 无平台实现）降级外部浏览器。

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../common/theme.dart';
import '../../services/ad_block_service.dart';
import '../../widgets/ad_block_bubble.dart';
import '../services/zlibrary_service.dart';

class OnlineReaderPage extends StatefulWidget {
  final String url;
  final String? title;

  const OnlineReaderPage({super.key, required this.url, this.title});

  @override
  State<OnlineReaderPage> createState() => _OnlineReaderPageState();
}

class _OnlineReaderPageState extends State<OnlineReaderPage> {
  late final WebViewController _controller;
  bool _loading = true;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    // ✅ 「在线阅读」要**全屏**（用户要求 ✓）：进页隐藏系统状态栏 / 导航条；
    //    退出时在 `dispose` 里恢复 ✓ —— 否则整个 App 会一直没有状态栏 ✗
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // 桌面端无 webview_flutter 平台实现，降级到外部浏览器（无 cookie，可能需重登）
    if (!Platform.isAndroid && !Platform.isIOS) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openExternal());
      return;
    }
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          // 🔴 下面四个回调里**只有这个漏了** `mounted` 检查 ✗ ——
          // `onPageStarted` / `onPageFinished` / `onWebResourceError`
          //（`:41 / :44 / :47` ✓）全都写了 `if (mounted)` ✓，属**漏写** ✗。
          // webview 的进度回调可能**在页面已销毁之后**才到达 ✓ →
          // 抛 `setState() called after dispose()` ✓
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          onPageStarted: (url) {
            if (mounted) setState(() => _loading = true);
            // 去广告：在线阅读页里的广告层
            AdBlockService.instance.injectInto(_controller, url);
          },
          onPageFinished: (url) {
            if (mounted) setState(() => _loading = false);
            // DOM 就绪后补注一次（抢注入常常拿不到时机）
            AdBlockService.instance.injectInto(_controller, url);
          },
          onWebResourceError: (e) {
            if (mounted) setState(() => _loading = false);
            _toast('加载失败：${e.description}');
          },
        ),
      );
    // 去广告：挂 JS 消息通道（必须在 loadRequest 之前）
    AdBlockService.attach(_controller);
    AdBlockService.instance.ensureLoaded();
    _injectCookieAndLoad();
  }

  /// 注入登录 cookie 后加载阅读页。cookie 必须在 loadRequest 之前 set；
  /// domain 带前导点以覆盖子域（remix cookie 可能 HttpOnly，必须走 cookieManager）。
  Future<void> _injectCookieAndLoad() async {
    final z = ZlibraryService();
    final domain = z.domain;
    final cookieManager = WebViewCookieManager();
    for (final entry in z.cookiesForWebview().entries) {
      await cookieManager.setCookie(
        WebViewCookie(
          name: entry.key,
          value: entry.value,
          domain: '.$domain',
          path: '/',
        ),
      );
    }
    try {
      await _controller.loadRequest(Uri.parse(widget.url));
    } catch (e) {
      _toast('链接无效：$e');
    }
  }

  Future<void> _openExternal() async {
    final uri = Uri.tryParse(widget.url);
    if (uri == null) {
      _toast('链接无效');
    } else {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  void dispose() {
    // 退出时把系统栏恢复回来（`immersiveSticky` 是全局的，不清会一直全屏 ✗）
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 桌面端占位（initState 已调度外部浏览器打开）
    if (!Platform.isAndroid && !Platform.isIOS) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title ?? '在线阅读')),
        body: const Center(child: Text('已用外部浏览器打开')),
      );
    }
    return Scaffold(
      // ✅ 不要顶栏、要**全屏**（用户要求）：Web 内容铺满整屏 ✓
      //    返回改由左上角那个**悬浮**小圆按钮（不占内容高度 ✓）
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                value: _progress > 0 ? _progress / 100 : null,
                minHeight: 2,
              ),
            ),
          // 去广告悬浮球：点它 → 点页面上的广告 → 存规则（重启后仍生效）
          ListenableBuilder(
            listenable: AdBlockService.instance,
            builder: (_, __) => AdBlockService.instance.showBubble
                ? AdBlockBubble(
                    controller: _controller,
                    pageUrl: widget.url,
                    margin: const EdgeInsets.only(right: 12, bottom: 96),
                  )
                : const SizedBox.shrink(),
          ),
          // 全屏后没有顶栏了 ⇒ 必须留一个能返回的入口 ✓
          Positioned(
            top: 0,
            left: 0,
            child: SafeArea(
              minimum: const EdgeInsets.all(8),
              child: Material(
                color: Colors.black.withValues(alpha: 0.35),
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => Navigator.of(context).maybePop(),
                  child: const SizedBox(
                    width: 40,
                    height: 40,
                    child: Icon(Icons.arrow_back_rounded,
                        size: 22, color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
