import 'package:flutter/material.dart';
import '../../services/app_log.dart';
import '../../services/player_prefs.dart';
import 'package:flutter/services.dart';
import '../../common/system_ui.dart';
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
  /// 内嵌模式：详情页播放器区域内嵌显示（4:3 固定高度，不强制横屏）。
  /// 默认 false = 全屏独立页（Scaffold + 横屏 + 浮动返回）。
  final bool embedded;

  const WebviewPlayerPage({
    super.key,
    required this.url,
    this.title,
    this.embedded = false,
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
    // 网页播放页强制横屏（仅全屏页；内嵌模式保持竖屏布局）
    if (!widget.embedded && PlayerPrefs.instance.webviewForceLandscape.value) {
      SystemUiController.enter(
        'webviewPlayer',
        mode: SystemUiMode.edgeToEdge,
        orientations: const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
        // 本页是黑底播放页 → 浅色状态栏图标
        overlayStyle: SystemUiOverlayStyle.light,
      );
    }
    _initController(widget.url);
  }

  void _initController(String url) {
    final enableJs = PlayerPrefs.instance.webviewEnableJs.value;
    _controller = WebViewController()
      ..setJavaScriptMode(
          enableJs ? JavaScriptMode.unrestricted : JavaScriptMode.disabled)
      ..setBackgroundColor(const Color(0x00000000))
      // 移动端 UA，部分解析站按 UA 下发 HTML5 播放器
      ..setUserAgent(
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1')
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
            AppLog.instance.log(
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
      _loadingProgress = 0;
      _controller.loadRequest(Uri.parse(widget.url));
    }
  }

  @override
  void dispose() {
    // 停掉页面媒体，避免 WebView 被销毁后声音残留
    try {
      _controller.runJavaScript(
          'try{document.querySelectorAll("video,audio").forEach(function(m){m.pause&&m.pause();});}catch(e){}');
    } catch (_) {}
    // 恢复**进入前**的方向（原来无条件写死"竖屏+左右横屏"，
    // 会把别的页面设定的方向锁覆盖掉）
    if (!widget.embedded && PlayerPrefs.instance.webviewForceLandscape.value) {
      SystemUiController.exit('webviewPlayer');
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
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
    );
    if (widget.embedded) {
      // 内嵌模式：4:3 固定高度（Column 内不会高度塌陷），无 Scaffold/返回按钮
      return AspectRatio(
        aspectRatio: 4 / 3,
        child: ColoredBox(
          color: Colors.black,
          child: body,
        ),
      );
    }
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
      body: body,
    );
  }
}
