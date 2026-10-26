import 'package:flutter/material.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/ad_block_service.dart';
import 'package:tvbox/services/player_prefs.dart';
import 'package:flutter/services.dart';
import 'package:tvbox/common/system_ui.dart';
import 'package:tvbox/widgets/ad_block_bubble.dart';
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

  /// 全屏页是否跟随「网页播放强制横屏」设置。
  ///
  /// 兜底打开的**普通网页**（海阔条目里的网页、站点首页/搜索页等）不该横屏：
  /// 那些页面是按竖屏排版的，横过来只露出一半（用户 2026-10-18 反馈）。
  final bool forceLandscape;

  const WebviewPlayerPage({
    super.key,
    required this.url,
    this.title,
    this.embedded = false,
    this.forceLandscape = true,
  });

  @override
  State<WebviewPlayerPage> createState() => _WebviewPlayerPageState();
}

class _WebviewPlayerPageState extends State<WebviewPlayerPage> {
  late final WebViewController _controller;
  int _loadingProgress = 0;

  /// 主文档加载失败（见 onWebResourceError）：给明确提示 + 重试，而不是纯黑
  bool _failed = false;
  String _failDesc = '';

  @override
  void initState() {
    super.initState();
    // 网页播放页强制横屏（仅全屏页；内嵌模式保持竖屏布局）
    if (!widget.embedded &&
        widget.forceLandscape &&
        PlayerPrefs.instance.webviewForceLandscape.value) {
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
        enableJs ? JavaScriptMode.unrestricted : JavaScriptMode.disabled,
      )
      ..setBackgroundColor(const Color(0x00000000))
      // 移动端 UA，部分解析站按 UA 下发 HTML5 播放器
      ..setUserAgent(
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
      )
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
                _failed = false; // 重试/跳转后先复位失败态
              });
            }
            // 去广告：抢在页面脚本之前注入（有些站点一加载就弹广告层），
            // 拿不到时机也没关系 —— onPageFinished 还会再补一次
            AdBlockService.instance.injectInto(_controller, url);
          },
          onPageFinished: (url) {
            // 补注：这时 DOM 已经在了，隐藏才真正生效
            AdBlockService.instance.injectInto(_controller, url);
          },
          onWebResourceError: (error) {
            // 只有**主文档**失败才提示（子资源失败很常见，不打扰用户）
            // ⚠️ 原来这里只打日志 ⇒ 解析返回的网页打不开时，4:3 播放区是
            //    一块纯黑：不转圈、不报错、没有重试入口（用户以为"卡死了"）。
            AppLog.instance.log(
              '[WebviewPlayer] 资源错误: ${error.errorCode} ${error.description} url=${error.url}',
            );
            if (error.isForMainFrame == true && mounted) {
              setState(() {
                _failed = true;
                _failDesc = _describeError(error);
              });
            }
          },
        ),
      );
    // 去广告：挂 JS 消息通道（必须在 loadRequest **之前** —— 页面一开始跑就可能回传）
    AdBlockService.attach(_controller);
    AdBlockService.instance.ensureLoaded();
    _load(widget.url);
  }

  /// 把 WKWebView 的错误码翻成人话。
  ///
  /// 101 = WebKitErrorCannotShowURL：WebKit 直接拒绝显示这个地址
  /// （不是网络问题，而是链接本身它不认，例如 `txvip://…`、`//host/x`、
  ///  空白/中文未编码）。用户截图里那条「101 The URL can't be shown」
  /// 就是它 —— 光看错误码根本不知道该怎么办。
  static String _describeError(WebResourceError error) {
    if (error.errorCode == 101) {
      return '这条线路的链接无法在网页中打开（格式不被支持）';
    }
    final desc = error.description.trim();
    return desc.isEmpty ? '错误码 ${error.errorCode}' : desc;
  }

  /// 载入前先规范化 URL：补协议、拦掉 WebView 肯定打不开的 scheme。
  ///
  /// 社区源的解析结果经常五花八门：`//cdn.x.com/a`、`www.x.com/a`、
  /// `intent://…`、`txvip://…`。直接 `loadRequest` 会得到 101，
  /// 与其让用户对着一串错误码发呆，不如先判一下。
  void _load(String raw) {
    var url = raw.trim();
    if (url.isEmpty) {
      setState(() {
        _failed = true;
        _failDesc = '这条线路没有返回播放地址';
      });
      return;
    }
    // 只有路径没有域名（`/play/123`）：WebView 无从下手，直接说清楚
    if (url.startsWith('/')) {
      setState(() {
        _failed = true;
        _failDesc = '这条线路只返回了路径，缺少域名：$raw';
      });
      return;
    }
    if (url.startsWith('//')) url = 'https:$url';
    if (!url.contains('://')) url = 'https://$url';
    // 中文 / 空格直接进 path 会被 WebKit 判 101，先做百分号编码
    if (url.codeUnits.any((c) => c > 127)) {
      try {
        url = Uri.encodeFull(url);
      } catch (_) {}
    }

    final uri = Uri.tryParse(url);
    final scheme = uri?.scheme.toLowerCase() ?? '';
    if (uri == null || (scheme != 'http' && scheme != 'https')) {
      setState(() {
        _failed = true;
        _failDesc = scheme.isEmpty
            ? '解析出的地址格式不对：$raw'
            : '不支持的链接类型「$scheme」，请在网页/浏览器里打开';
      });
      return;
    }
    _controller.loadRequest(uri);
  }

  @override
  void didUpdateWidget(covariant WebviewPlayerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换集 / 换清晰度 / 换线路时 URL 变化 → 重新加载
    if (oldWidget.url != widget.url) {
      setState(() {
        _loadingProgress = 0;
        _failed = false; // 换集/换线路：复位失败态
      });
      _load(widget.url);
    }
  }

  @override
  void dispose() {
    // 停掉页面媒体，避免 WebView 被销毁后声音残留
    try {
      _controller.runJavaScript(
        'try{document.querySelectorAll("video,audio").forEach(function(m){m.pause&&m.pause();});}catch(e){}',
      );
    } catch (_) {}
    // 恢复**进入前**的方向（原来无条件写死"竖屏+左右横屏"，
    // 会把别的页面设定的方向锁覆盖掉）
    if (!widget.embedded &&
        widget.forceLandscape &&
        PlayerPrefs.instance.webviewForceLandscape.value) {
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
          child: Stack(
            children: [
              Positioned.fill(child: WebViewWidget(controller: _controller)),
              // 去广告悬浮球：点它 → 点页面上的广告 → 存规则（下次打开自动隐藏）
              ListenableBuilder(
                listenable: AdBlockService.instance,
                builder: (_, __) => AdBlockService.instance.showBubble
                    ? AdBlockBubble(
                        controller: _controller,
                        pageUrl: widget.url,
                        // 内嵌（详情页 4:3 小窗）贴着右上角，别压住播放控件
                        margin: widget.embedded
                            ? const EdgeInsets.only(right: 8, top: 8)
                            : const EdgeInsets.only(right: 12, bottom: 96),
                      )
                    : const SizedBox.shrink(),
              ),
              // 主文档加载失败 → 明确提示 + 重试（而不是纯黑什么都不说）
              if (_failed)
                Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.public_off_rounded,
                              size: 34,
                              color: Colors.white54,
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              '这个网页打不开',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (_failDesc.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(
                                _failDesc,
                                maxLines: 2,
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                            const SizedBox(height: 14),
                            TextButton(
                              onPressed: () {
                                setState(() {
                                  _failed = false;
                                  _loadingProgress = 0;
                                });
                                _load(widget.url);
                              },
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
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
