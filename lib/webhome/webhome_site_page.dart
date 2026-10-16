// lib/webhome/webhome_site_page.dart
//
// 站点「网页首页」渲染页 —— WebHomeTV 的核心玩法。
//
// ── 为什么要有这一页 ────────────────────────────────────────────
// 站点配置里写 `homePage: https://…/nostr.html`，意思就是"用**这个网页**当
// 这个站点的首页"。之前 `homePage` **只落库、没接渲染**（`webhtv_site_inject_page`
// 里自己都写着"⚠️ 本版只保存、尚未接入渲染"）⇒ 用户把 Nostr 这类站点导进来，
// 也永远看不到它那个首页。本页补上这一环（用户 2026-10-16：方案 3）。
//
// ── 桥 ─────────────────────────────────────────────────────────
// 与「网页」模块同一套（不另造一套）：
//   · `window.ant` = [AntBridge]（request / storage / player / source / ui…）
//   · `window.fm`  = [kWebHomeFmShim]（吃 FongMi 桥的页面用它）
// 所以页面里 `fm.play(...)`、`ant.player.open(...)`、`ant.request(...)` 都能用。
//
// ── 去广告 ─────────────────────────────────────────────────────
// 注入规则 + 小猫悬浮球，与其它 7 个 WebView 口径一致。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../common/theme.dart';
import '../miniapp/services/ant_bridge.dart';
import '../services/ad_block_service.dart';
import '../widgets/ad_block_bubble.dart';
import '../services/app_log.dart';
import 'web_home_fm_shim.dart';

class WebHomeSitePage extends StatefulWidget {
  const WebHomeSitePage({super.key, required this.url, required this.title});

  /// 站点配置里的 `homePage`
  final String url;

  /// 站点名（顶栏标题）
  final String title;

  @override
  State<WebHomeSitePage> createState() => _WebHomeSitePageState();
}

class _WebHomeSitePageState extends State<WebHomeSitePage> {
  static const List<String> _permissions = [
    'ui',
    'storage',
    'network',
    'player',
    'source',
  ];

  late final WebViewController _controller;
  int _progress = 0;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    AntBridge.configure(appId: 'webhome_site', permissions: _permissions);
    // `ant.exitMiniApp()` 让它返回上一页（与网页模块同一约定）
    AntBridge.onExitRequested = () {
      if (mounted) Navigator.of(context).maybePop();
    };
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(AppTheme.backgroundPrimary)
      ..addJavaScriptChannel(
        AntBridge.channelName,
        onMessageReceived: _onBridgeMessage,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          onPageStarted: (url) {
            if (mounted) {
              setState(() {
                _progress = 0;
                _failed = false;
              });
            }
            AdBlockService.instance.injectInto(_controller, url);
          },
          onPageFinished: (url) {
            // 站内跳转产生的新页面同样需要 window.ant / window.fm
            _controller
              ..runJavaScript(AntBridge.injectScript)
              ..runJavaScript(kWebHomeFmShim);
            AdBlockService.instance.injectInto(_controller, url);
          },
          onWebResourceError: (e) {
            AppLog.instance.log('[WebHomeSite] 资源错误 ${e.errorCode} ${e.description}');
            if (e.isForMainFrame == true && mounted) {
              setState(() => _failed = true);
            }
          },
        ),
      );
    AdBlockService.attach(_controller);
    AdBlockService.instance.ensureLoaded();
    _controller.loadRequest(Uri.parse(widget.url));
  }

  @override
  void dispose() {
    AntBridge.onExitRequested = null;
    super.dispose();
  }

  /// 桥回调：与网页模块/小程序宿主同一套协议（`AntBridge` 是静态共用）
  Future<void> _onBridgeMessage(JavaScriptMessage message) async {
    final raw = message.message;
    Map<String, dynamic>? req;
    try {
      req = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {}
    if (req == null || req['id'] == null) return;
    final id = req['id'];
    final resp = await AntBridge.handleMessage(raw);
    final map = jsonDecode(resp) as Map<String, dynamic>;
    final ok = map['ok'] == true;
    try {
      if (ok) {
        await _controller.runJavaScript(
          'window.__antResolve && window.__antResolve($id, ${jsonEncode(map['result'])});',
        );
      } else {
        await _controller.runJavaScript(
          'window.__antReject && window.__antReject($id, ${jsonEncode(map['error'])});',
        );
      }
    } catch (e) {
      AppLog.instance.log('[WebHomeSite] 桥回调失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundSecondary,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded,
              size: 18, color: AppTheme.textPrimary),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          widget.title.isEmpty ? '网页首页' : widget.title,
          style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontSubhead,
              fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: Icon(Icons.refresh_rounded,
                size: 20, color: AppTheme.textSecondary),
            onPressed: () => _controller.reload(),
          ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: WebViewWidget(controller: _controller),
          ),
          // 加载进度
          if (_progress < 100 && !_failed)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                value: _progress <= 0 ? null : _progress / 100,
                minHeight: 2,
                backgroundColor: Colors.transparent,
                color: AppTheme.accentColor,
              ),
            ),
          // 加载失败兜底（很多站点挂了直连不给内容）
          if (_failed)
            Positioned.fill(
              child: Container(
                color: AppTheme.backgroundPrimary.withValues(alpha: 0.94),
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_off_rounded,
                        size: 36, color: AppTheme.textTertiary),
                    const SizedBox(height: 10),
                    Text('这个网页首页打不开',
                        style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: AppTheme.fontSubhead)),
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: Text(
                        widget.url,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: AppTheme.fontCaption),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () {
                        setState(() => _failed = false);
                        _controller.reload();
                      },
                      child: Text('重试',
                          style: TextStyle(color: AppTheme.accentOnSurface)),
                    ),
                  ],
                ),
              ),
            ),
          // 去广告小猫悬浮球（与其它网页口径一致）
          ListenableBuilder(
            listenable: AdBlockService.instance,
            builder: (_, __) => AdBlockService.instance.showBubble
                ? AdBlockBubble(
                    controller: _controller,
                    pageUrl: widget.url,
                    margin: const EdgeInsets.only(right: 12, bottom: 32),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}
