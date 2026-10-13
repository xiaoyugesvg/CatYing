import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../common/theme.dart';
import '../../services/app_log.dart';
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

  @override
  void initState() {
    super.initState();
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
          },
          onPageFinished: (url) {
            // 每次页面加载完都注入 ant 桥，保证内部页面也有
            _controller.runJavaScript(AntBridge.injectScript);
          },
          onWebResourceError: (error) {
            AppLog.instance.log(
                '[MiniAppWeb] 资源错误: ${error.errorCode} ${error.description} url=${error.url}');
          },
        ),
      );
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
        await _controller.loadFile('$local/$_entry');
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
    // 再叠一层宿主标题栏很难看。只保留两样**不占内容高度**的东西：
    //   · 贴顶 2px 的加载进度条（只在加载中出现）
    //   · 左上角一个半透明小圆返回钮（浮在内容上）—— 不然没地方退出去
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Positioned.fill(child: WebViewWidget(controller: _controller)),
            if (_loadingProgress > 0 && _loadingProgress < 100)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(
                  value: _loadingProgress / 100.0,
                  minHeight: 2,
                  backgroundColor: AppTheme.borderLight,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(AppTheme.accentColor),
                ),
              ),
            Positioned(left: 6, top: 6, child: _floatBackButton()),
          ],
        ),
      ),
    );
  }

  /// 悬浮返回钮：不占内容高度、半透明，尽量不挡小程序自己的 UI
  Widget _floatBackButton() {
    return Material(
      color: Colors.black.withValues(alpha: 0.30),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.maybePop(context),
        child: const SizedBox(
          width: 34,
          height: 34,
          child: Icon(Icons.arrow_back_ios_new, size: 15, color: Colors.white),
        ),
      ),
    );
  }
}
