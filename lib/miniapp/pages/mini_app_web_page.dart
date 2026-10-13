import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:webview_flutter/webview_flutter.dart';

import '../../common/theme.dart';
import '../../services/app_log.dart';
import '../services/ant_bridge.dart';

/// 小程序 WebView 页：加载内置资产 + 官方 ant SDK v4 桥注入。
///
/// - 读 `$assetRoot/manifest.json`（appId / name / permissions / entry）
/// - 页面加载完成后注入 `window.ant`（走 `AntBridge` channel）
/// - 相对路径页面跳转由 JS 侧 location 完成
class MiniAppWebPage extends StatefulWidget {
  /// 内置资产根目录（`assets/...` 相对 flutter assets 路径）
  final String assetRoot;

  /// 显式标题；不传则读 manifest 的 name
  final String? title;

  const MiniAppWebPage({super.key, required this.assetRoot, this.title});

  @override
  State<MiniAppWebPage> createState() => _MiniAppWebPageState();
}

class _MiniAppWebPageState extends State<MiniAppWebPage> {
  late final WebViewController _controller;
  int _loadingProgress = 0;
  String _title = '小程序';
  String _entry = 'index.html';

  @override
  void initState() {
    super.initState();
    _title = widget.title ?? '小程序';
    _initManifest();
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
      )
      ..loadFlutterAsset('${widget.assetRoot}/index.html');
  }

  /// 读 manifest.json：appId / permissions / name / entry
  Future<void> _initManifest() async {
    try {
      final raw = await rootBundle
          .loadString('${widget.assetRoot}/manifest.json');
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final appId = (map['appId'] ?? '').toString();
      final name = (map['name'] ?? '').toString();
      final entry = (map['entry'] ?? 'index.html').toString();
      final perms = (map['permissions'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[];
      AntBridge.configure(appId: appId, permissions: perms);
      if (mounted && widget.title == null && name.isNotEmpty) {
        setState(() => _title = name);
      }
      if (entry.isNotEmpty && entry != 'index.html') {
        _entry = entry;
        await _controller.loadFlutterAsset('${widget.assetRoot}/$entry');
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
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // 顶栏：返回 + 标题 + 刷新
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppTheme.spacingSM, AppTheme.spacingSM, 0, 0),
              child: Row(
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () => Navigator.maybePop(context),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(Icons.arrow_back_ios_new,
                          size: 18, color: AppTheme.textPrimary),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      _title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontTitle3,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.refresh,
                        size: 20, color: AppTheme.textPrimary),
                    onPressed: () => _controller.reload(),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
            if (_loadingProgress > 0 && _loadingProgress < 100)
              LinearProgressIndicator(
                value: _loadingProgress / 100.0,
                minHeight: 2,
                backgroundColor: AppTheme.borderLight,
                valueColor:
                    AlwaysStoppedAnimation<Color>(AppTheme.accentColor),
              ),
            Expanded(
              child: WebViewWidget(controller: _controller),
            ),
          ],
        ),
      ),
    );
  }
}
