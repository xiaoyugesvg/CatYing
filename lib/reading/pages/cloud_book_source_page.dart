// 云书源网页版：直接用 WebView 嵌入 qread 服务端网页（如 xs.muiu.site）。
// qread 网页端自带完整 UI（登录 / 源分类 / 搜索 / 详情 / 目录 / 阅读器），
// 云模式书源界面即该网站本身，App 只做承载与入口。
// 桌面端（webview_flutter 无平台实现）降级外部浏览器。

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/qread_api.dart';

class CloudBookSourcePage extends StatefulWidget {
  /// 服务端网页地址；为空时默认取已配置的 qread 服务端地址。
  final String? url;
  final String title;

  const CloudBookSourcePage({super.key, this.url, this.title = '云书源'});

  @override
  State<CloudBookSourcePage> createState() => _CloudBookSourcePageState();
}

class _CloudBookSourcePageState extends State<CloudBookSourcePage> {
  late final WebViewController _controller;
  bool _loading = true;
  int _progress = 0;
  bool _loadFailed = false;

  String get _target {
    if (widget.url != null && widget.url!.trim().isNotEmpty) {
      return widget.url!.trim();
    }
    final cfg = QreadServerConfig.instance;
    if (cfg.isConfigured) return cfg.normalizedBase;
    return 'https://xs.muiu.site/';
  }

  @override
  void initState() {
    super.initState();
    // 桌面端无 webview_flutter 平台实现，降级到外部浏览器
    if (!Platform.isAndroid && !Platform.isIOS) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openExternal());
      return;
    }
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          onPageStarted: (_) {
            if (mounted) {
              setState(() {
                _loading = true;
                _loadFailed = false;
              });
            }
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (e) {
            if (mounted) {
              setState(() {
                _loading = false;
                _loadFailed = true;
              });
            }
          },
        ),
      );
    _load();
  }

  Future<void> _load() async {
    final uri = Uri.tryParse(_target);
    if (uri == null || !uri.hasScheme) {
      _toast('服务端地址无效：$_target');
      return;
    }
    try {
      await _controller.loadRequest(uri);
    } catch (e) {
      _toast('加载失败：$e');
    }
  }

  Future<void> _openExternal() async {
    final uri = Uri.tryParse(_target);
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
  Widget build(BuildContext context) {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: const Center(child: Text('已用外部浏览器打开')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: '在外部浏览器打开',
            icon: const Icon(Icons.open_in_new),
            onPressed: _openExternal,
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _controller.reload();
            },
          ),
        ],
      ),
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
          if (_loadFailed)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.cloud_off, size: 48),
                  const SizedBox(height: 12),
                  const Text('网页加载失败'),
                  const SizedBox(height: 4),
                  Text(
                    _target,
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: () {
                      setState(() => _loadFailed = false);
                      _controller.reload();
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
