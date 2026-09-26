import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 网页播放器页 - 全屏 WebView 加载网页播放页
///
/// 用途：当源返回的播放地址是**网页播放器页**（如第三方解析页、
/// `/player/?url=`、`parse=1` 的网页端地址）而非 m3u8/mp4 直链时，
/// 用 WebView 加载网页上的播放器兜底播放。
/// 对应 catmovie（CxiaoyuN/movie）的 WebviewView 实现：
/// 强制横屏 + 黑色背景 + JS 无限制 + 左上角浮动返回按钮。
class WebviewPlayerPage extends StatefulWidget {
  final String url;
  final String? title;

  const WebviewPlayerPage({
    super.key,
    required this.url,
    this.title,
  });

  @override
  State<WebviewPlayerPage> createState() => _WebviewPlayerPageState();
}

class _WebviewPlayerPageState extends State<WebviewPlayerPage> {
  late final WebViewController _controller;
  int _loadingProgress = 0;

  @override
  void initState() {
    super.initState();
    // 网页播放页强制横屏（视频播放体验）
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _initController(widget.url);
  }

  void _initController(String url) {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) {
              setState(() {
                _loadingProgress = progress;
              });
            }
          },
          onPageStarted: (url) {
            if (mounted) {
              setState(() {
                _loadingProgress = 0;
              });
            }
          },
          onWebResourceError: (error) {
            // 仅打印错误，不弹 dialog（避免遮挡；用户在加载条上能看到失败）
            debugPrint(
                '[WebviewPlayer] 资源错误: ${error.errorCode} ${error.description} url=${error.url}');
          },
        ),
      )
      ..loadRequest(Uri.parse(url));
  }

  @override
  void didUpdateWidget(covariant WebviewPlayerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换集 / 换清晰度 / 换线路时 URL 变化 → 重新加载
    if (oldWidget.url != widget.url) {
      _controller.loadRequest(Uri.parse(widget.url));
    }
  }

  @override
  void dispose() {
    // 恢复允许竖屏 + 横屏
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      floatingActionButton: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: Colors.black38,
        ),
        margin: const EdgeInsets.symmetric(vertical: 9),
        child: IconButton(
          icon: const BackButtonIcon(),
          color: Colors.white,
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () {
            Navigator.maybePop(context);
          },
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.startTop,
      body: Column(
        children: [
          // 加载进度条
          if (_loadingProgress > 0 && _loadingProgress < 100)
            LinearProgressIndicator(
              value: _loadingProgress / 100.0,
              minHeight: 2,
              backgroundColor: Colors.white12,
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
            ),
          Expanded(
            child: WebViewWidget(controller: _controller),
          ),
        ],
      ),
    );
  }
}
