import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../common/theme.dart';
import '../miniapp/services/ant_bridge.dart';
import '../services/app_log.dart';
import '../services/main_tab_controller.dart';
import 'web_home_prefs.dart';

/// 「网页首页」模块 —— **独立于小程序体系**的一个 WebView 宿主。
///
/// ── 它是什么 ──────────────────────────────────────────────────
/// 加载**用户自己配的 HTML 首页**（未配置时用内置默认页
/// `assets/webhome/index.html`），并注入 `window.ant` SDK。
/// 于是网页里可以直接：
///   · `ant.source.search({siteKey, wd})` / `ant.source.detail(...)` 搜片取详情
///   · `ant.player.open({url, title})` 用猫影自己的播放器播放
///   · `ant.storage.*` 存数据（按 `webhome` 前缀隔离，与任何小程序都不冲突）
///   · `ant.request(...)` 发请求（本地 Dio，不受浏览器 CORS 限制）
///
/// ── 为什么只复用 `AntBridge` ──────────────────────────────────
/// JSAPI 底座是通用的，重写一遍没有意义；除此之外本模块**完全独立**：
/// 自己的目录（`lib/webhome/`）、自己的配置（[WebHomePrefs]）、
/// 自己的底栏入口（`NavFeature.webhome`），**不进入小程序列表**。
class WebHomePage extends StatefulWidget {
  const WebHomePage({super.key});

  @override
  State<WebHomePage> createState() => _WebHomePageState();
}

class _WebHomePageState extends State<WebHomePage> {
  /// 内置默认页（未配置地址时用）。⚠️ 必须与 `pubspec.yaml` 的 assets 声明一致。
  static const String _kBuiltinEntry = 'assets/webhome/index.html';

  /// 本模块固定的 appId（`ant.storage` 的分区前缀）—— 与会任何小程序都不同。
  static const String _appId = 'webhome';

  /// 放行的能力：这是**本模块自己**的内置页面（不是第三方小程序包），
  /// 所以权限由模块统一给定，不走 manifest。
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
    AntBridge.configure(appId: _appId, permissions: _permissions);
    // 网页里调 `ant.exitMiniApp()` → 切回影视首页 tab
    //（本模块是底栏 tab，没有"返回上一页"这回事）
    AntBridge.onExitRequested = () {
      if (!mounted) return;
      MainTabController.instance.select(MainTabController.videoTabIndex);
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
          },
          onPageFinished: (url) {
            // 每次加载完都注入：站内跳转产生的新页面同样需要 window.ant
            _controller.runJavaScript(AntBridge.injectScript);
          },
          onWebResourceError: (e) {
            AppLog.instance.log('[WebHome] 资源错误: ${e.errorCode} '
                '${e.description} url=${e.url}');
            // 只有**主文档**失败才提示（子资源失败很常见，不打扰用户）
            if (e.isForMainFrame == true && mounted) {
              setState(() => _failed = true);
            }
          },
        ),
      );
    _loadEntry();
  }

  /// 加载入口：配了地址就加载它，否则加载内置默认页。
  Future<void> _loadEntry() async {
    if (!WebHomePrefs.instance.loaded) {
      await WebHomePrefs.instance.load();
    }
    final url = WebHomePrefs.instance.url;
    try {
      if (url.isNotEmpty) {
        await _controller.loadRequest(Uri.parse(url));
      } else {
        await _controller.loadFlutterAsset(_kBuiltinEntry);
      }
    } catch (e) {
      AppLog.instance.log('[WebHome] 首页加载失败: $e');
      if (mounted) setState(() => _failed = true);
    }
  }

  /// 桥回调：与小程序宿主同一套协议（`AntBridge` 是静态的，两边共用）。
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
      AppLog.instance.log('[WebHome] 桥回调失败: $e');
    }
  }

  /// 配置首页地址（右上角小按钮 → 弹窗）。
  Future<void> _editUrl() async {
    final ctrl = TextEditingController(text: WebHomePrefs.instance.url);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: const Text('网页首页地址'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 1,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://example.com/home.html',
            helperText: '留空 = 使用内置默认页',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text('恢复默认'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    // null = 取消（不做任何事）；'' = 恢复内置默认页
    if (v == null) return;
    await WebHomePrefs.instance.setUrl(v);
    if (!mounted) return;
    setState(() => _failed = false);
    await _loadEntry();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Positioned.fill(child: WebViewWidget(controller: _controller)),

            // 贴顶加载进度（不占位，与小程序宿主一致）
            if (_progress > 0 && _progress < 100)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(
                  value: _progress / 100.0,
                  minHeight: 2,
                  backgroundColor: AppTheme.borderLight,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(AppTheme.accentColor),
                ),
              ),

            // 右上角：首页地址设置（低存在感的半透明小按钮）
            Positioned(
              top: 6,
              right: 8,
              child: Opacity(
                opacity: 0.55,
                child: IconButton(
                  tooltip: '网页首页地址',
                  iconSize: 20,
                  onPressed: _editUrl,
                  icon: Icon(Icons.tune_rounded,
                      color: AppTheme.textPrimary),
                ),
              ),
            ),

            // 主文档加载失败：给明确原因 + 重试/换地址入口（而不是白屏）
            if (_failed)
              Positioned.fill(
                child: ColoredBox(
                  color: AppTheme.backgroundPrimary,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.public_off_rounded,
                            size: 42, color: AppTheme.textSecondary),
                        const SizedBox(height: 12),
                        Text(
                          WebHomePrefs.instance.url.isEmpty
                              ? '内置首页未能加载'
                              : '网页首页打不开',
                          style: TextStyle(
                              color: AppTheme.textPrimary, fontSize: 15),
                        ),
                        const SizedBox(height: 6),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Text(
                            WebHomePrefs.instance.url.isEmpty
                                ? '可以先配置一个自己的 HTML 地址'
                                : WebHomePrefs.instance.url,
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: AppTheme.textSecondary, fontSize: 12),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            TextButton(
                              onPressed: () {
                                setState(() => _failed = false);
                                _loadEntry();
                              },
                              child: const Text('重试'),
                            ),
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: _editUrl,
                              child: const Text('设置地址'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
