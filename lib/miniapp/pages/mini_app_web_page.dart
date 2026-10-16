import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:webview_flutter/webview_flutter.dart';

import '../../common/theme.dart';
import '../../services/ad_block_service.dart';
import '../../services/app_log.dart';
import '../../services/webview_page_color.dart';
import '../../widgets/ad_block_bubble.dart';
import '../services/ant_bridge.dart';

/// 小程序 WebView 页：加载远端/本地小程序页面 + 官方 ant SDK v4 桥注入。
///
/// - manifest 由服务层传入（`manifestJson`）或从本地目录读取
/// - 页面加载完成后注入 `window.ant`（走 `AntBridge` channel）
/// - 相对路径页面跳转由 JS 侧 location 完成
class MiniAppWebPage extends StatefulWidget {
  /// 在线站点型小程序：直接加载远端页面（市场里的 manifest.json 型）
  final String? remoteUrl;

  /// zip 安装的小程序：本地目录（页面从 `<localRoot>/<entry>` 加载）
  final String? localRoot;

  /// 已知的 manifest 内容（远程/本地安装时由服务层传入，省一次 IO）
  final String? manifestJson;

  const MiniAppWebPage({
    super.key,
    this.remoteUrl,
    this.localRoot,
    this.manifestJson,
  });

  @override
  State<MiniAppWebPage> createState() => _MiniAppWebPageState();
}

class _MiniAppWebPageState extends State<MiniAppWebPage> {
  late final WebViewController _controller;
  int _loadingProgress = 0;
  String _entry = 'index.html';

  /// 当前网页的**主色**（meta theme-color → body/html 背景色）。
  /// 用来把**状态栏那一条**刷成和网页一样的颜色（用户 2026-10-14 要求：
  /// 「包含小程序里面也是一样的」）；null = 没取到 ⇒ 那条透明、透出壁纸。
  Color? _pageColor;

  /// 探一次页面主色（有些页面的颜色是脚本随后才设的 ⇒ 加载后会补探一次）。
  Future<void> _probePageColor() async {
    final c = await probeWebViewPageColor(_controller);
    if (!mounted || c == null || c == _pageColor) return;
    setState(() => _pageColor = c);
  }

  @override
  void initState() {
    super.initState();
    // 网页里调 `ant.exitMiniApp()` → 关掉这一页（返回上一页）
    AntBridge.onExitRequested = () {
      if (mounted) Navigator.of(context).maybePop();
    };
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(AppTheme.backgroundPrimary)
      ..addJavaScriptChannel(AntBridge.channelName,
          onMessageReceived: _onBridgeMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) setState(() => _loadingProgress = progress);
          },
          onPageStarted: (url) {
            if (mounted) setState(() => _loadingProgress = 0);
            // 去广告：小程序内嵌网页里的广告层（站点型小程序最常见）
            AdBlockService.instance.injectInto(_controller, url);
          },
          onPageFinished: (url) {
            // 每次页面加载完都注入 ant 桥，保证内部页面也有
            _controller.runJavaScript(AntBridge.injectScript);
            // 去广告：DOM 就绪后补一次（抢注入常常拿不到时机）
            AdBlockService.instance.injectInto(_controller, url);
            // 顶栏跟随网页配色：立刻探一次 + 稍后补探一次（颜色常是异步设的）
            _probePageColor();
            Future<void>.delayed(const Duration(milliseconds: 600), () {
              if (mounted) _probePageColor();
            });
          },
          onWebResourceError: (error) {
            AppLog.instance.log(
                '[MiniAppWeb] 资源错误: ${error.errorCode} ${error.description} url=${error.url}');
          },
        ),
      );
    // 去广告：挂 JS 消息通道（必须在加载之前）
    AdBlockService.attach(_controller);
    AdBlockService.instance.ensureLoaded();
    // 先读 manifest（拿到 appId/permissions/entry），再按来源加载入口页
    _loadManifestThenEntry();
  }

  Future<void> _loadManifestThenEntry() async {
    await _initManifest();
    await _loadEntry();
  }

  /// 按来源加载入口页：远端 URL > 本地目录（zip 安装）
  Future<void> _loadEntry() async {
    try {
      final remote = widget.remoteUrl?.trim() ?? '';
      if (remote.isNotEmpty) {
        await _controller.loadRequest(Uri.parse(remote));
        return;
      }
      final local = widget.localRoot?.trim() ?? '';
      if (local.isNotEmpty) {
        // 🔴 2026-10-14 修（洞 O：entry 路径穿越读）：
        //   `_entry` 来自 manifest，可以写成 `../x.html` ⇒ 会把**小程序目录之外**
        //   的本地 HTML 加载进这个**注入了 ant 桥**的 WebView（能调 request /
        //   storage / player）。配合"解包 zip slip"（已在 mini_app_service 修掉）
        //   就是一条完整利用链，所以这里必须挡住。
        //   做法同 zip slip：规范化后校验仍在 localRoot 内，越界就拒绝加载。
        final base = local.endsWith('/') ? local : '$local/';
        final target = Uri.file('$base$_entry').normalizePath().toFilePath();
        if (target.startsWith(base)) {
          await _controller.loadFile(target);
        } else {
          AppLog.instance.log('[MiniAppWeb] 入口页越界，已拒绝加载: $_entry');
        }
      }
    } catch (e) {
      AppLog.instance.log('[MiniAppWeb] 入口页加载失败: $e');
    }
  }

  /// 读 manifest：优先用传入的文本（市场安装时服务层已取到）→ 本地目录
  Future<void> _initManifest() async {
    try {
      var raw = widget.manifestJson?.trim() ?? '';
      if (raw.isEmpty) {
        final local = widget.localRoot?.trim() ?? '';
        if (local.isNotEmpty) {
          final f = File('$local/manifest.json');
          if (await f.exists()) raw = await f.readAsString();
        }
      }
      if (raw.isEmpty) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final appId = (map['appId'] ?? '').toString();
      final entry = (map['entry'] ?? 'index.html').toString();
      final perms = (map['permissions'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[];
      AntBridge.configure(appId: appId, permissions: perms);
      if (entry.isNotEmpty) {
        // 入口页统一交给 _loadEntry 加载（assets / 本地 / 远端同一套）
        _entry = entry;
      }
    } catch (e) {
      AppLog.instance.log('[MiniAppWeb] manifest 解析失败: $e');
    }
  }

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
            'window.__antResolve && window.__antResolve($id, ${jsonEncode(map['result'])});');
      } else {
        await _controller.runJavaScript(
            'window.__antReject && window.__antReject($id, ${jsonEncode(map['error'])});');
      }
    } catch (e) {
      AppLog.instance.log('[MiniAppWeb] 桥回调失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // 用户 2026-10-13：「小程序打开界面不要顶栏」。
    // 去掉原来的「返回 + 标题 + 刷新」那一行 —— 很多小程序页面自带 header，
    // 再叠一层宿主标题栏很难看。
    // 用户 2026-10-13 追加：「已经有个返回了，去掉新增的那个返回按钮」
    //   ⇒ 连左上角那个悬浮返回圆钮也去掉，只保留**完全不占位**的贴顶进度条。
    //
    // 用户 2026-10-14：「顶栏要跟着不同页面的颜色变,和网页一样」⇒
    //   状态栏那一条刷成网页主色（取不到时透明，行为与改造前一致）。
    final topInset = MediaQuery.paddingOf(context).top;
    final pageColor = _pageColor;
    Widget page = Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      body: Column(
        children: [
          Container(height: topInset, color: pageColor),
          Expanded(
            // 只保留**左右**安全区（横屏刘海），上下自己管：
            // 上 = 上面那条颜色条，下 = 交给底栏/内容（与改造前的 SafeArea 同款行为）
            child: SafeArea(
              top: false,
              bottom: false,
              child: Stack(
                children: [
                  Positioned.fill(
                      child: WebViewWidget(controller: _controller)),
                  if (_loadingProgress > 0 && _loadingProgress < 100)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: LinearProgressIndicator(
                        value: _loadingProgress / 100.0,
                        minHeight: 2,
                        backgroundColor: AppTheme.borderLight,
                        valueColor: AlwaysStoppedAnimation<Color>(
                            AppTheme.accentColor),
                      ),
                    ),
                  // 去广告悬浮球：点它 → 点页面上的广告 → 存规则（重启后仍生效）
                  ListenableBuilder(
                    listenable: AdBlockService.instance,
                    builder: (_, __) => AdBlockService.instance.showBubble
                        ? AdBlockBubble(
                            controller: _controller,
                            pageUrl: widget.remoteUrl ?? '',
                            margin: const EdgeInsets.only(right: 12, bottom: 96),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    // 状态栏图标明暗跟着那条颜色走（否则浅色网页 + 深色主题时图标看不见）
    if (pageColor != null) {
      page = AnnotatedRegion<SystemUiOverlayStyle>(
        value: pageColor.computeLuminance() > 0.5
            ? SystemUiOverlayStyle.dark
            : SystemUiOverlayStyle.light,
        child: page,
      );
    }
    return page;
  }
}
