import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../common/system_ui.dart';
import '../../miniapp/pages/mini_app_player_page.dart';
import '../../services/api_config.dart';
import '../../services/app_log.dart';
import '../../services/parse_service.dart';
import '../../services/player_prefs.dart';

/// 嗅探播放页 - WebView 加载网页播放器页 + 主动嗅探视频地址
///
/// 用途：解析接口（parses）返回的是**网页播放器页**（type 0 嗅探类解析站 /
/// `/player/?url=` / `parse=1` 的网页端地址）时：
/// 1. WebView 加载该网页；
/// 2. 注入 JS 主动嗅探页面里的 video/audio 与 m3u8/mp4/flv/ts/mkv 链接
///    （含 iframe 同源探测）；
/// 3. 嗅探到直链 → 自动切原生播放器（media_kit/mpv）播放；
/// 4. 底部提供「重新嗅探 / 换解析接口」，全部解析站未命中也能留在网页里直接看。
class SniffPlayerPage extends StatefulWidget {
  final String url;
  final String? title;

  const SniffPlayerPage({super.key, required this.url, this.title});

  @override
  State<SniffPlayerPage> createState() => _SniffPlayerPageState();
}

class _SniffPlayerPageState extends State<SniffPlayerPage> {
  late final WebViewController _controller;
  int _loadingProgress = 0;

  bool _sniffing = false;
  int _sniffTries = 0;
  Timer? _sniffTimer;
  String _hint = '正在嗅探页面里的视频地址…';
  int _parseIndex = -1;
  bool _autoSwitched = false;
  String? _sniffedUrl;

  static const String _sniffJs = '''
(function(){
  var found = [], seen = {};
  function push(u){ if(u && !seen[u] && /^https?:\\/\\//i.test(u)){ seen[u]=1; found.push(u); } }
  function grab(){
    try{
      document.querySelectorAll('video,audio').forEach(function(m){ push(m.currentSrc || m.src); });
      var html = document.documentElement ? document.documentElement.outerHTML : '';
      var re = /https?:\\/\\/[^\\s"'<>\\\\]+?\\.(?:m3u8|mp4|flv|ts|mkv|m3u)(?:\\?[^\\s"'<>\\\\]*)?/gi;
      var m;
      while((m = re.exec(html)) !== null) push(m[0]);
      var frames = document.querySelectorAll('iframe');
      for(var i=0;i<frames.length;i++){
        try{
          var fd = frames[i].contentDocument;
          if(fd){
            fd.querySelectorAll('video,audio').forEach(function(x){ push(x.currentSrc || x.src); });
            var fh = fd.documentElement ? fd.documentElement.outerHTML : '';
            re.lastIndex = 0;
            while((m = re.exec(fh)) !== null) push(m[0]);
          }
        }catch(e){}
      }
    }catch(e){}
  }
  window.__sniff = {
    scan: function(){ grab(); return found.length; },
    get: function(){ grab(); return found.length ? found[0] : ''; },
    all: function(){ grab(); return found.slice(0, 10); }
  };
  var tries = 0;
  var timer = setInterval(function(){
    grab();
    if(found.length || ++tries >= 8){ clearInterval(timer); }
  }, 1200);
})();
''';

  @override
  void initState() {
    super.initState();
    if (PlayerPrefs.instance.webviewForceLandscape.value) {
      SystemUiController.enter(
        'sniffPlayer',
        mode: SystemUiMode.edgeToEdge,
        orientations: const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ],
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
      ..setBackgroundColor(const Color(0xFF000000))
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
            _stopSniffing();
            if (mounted) {
              setState(() {
                _loadingProgress = 0;
                _sniffedUrl = null;
                _hint = '正在嗅探页面里的视频地址…';
              });
            }
          },
          onPageFinished: (url) {
            if (mounted) {
              setState(() {
                _loadingProgress = 100;
              });
            }
            if (enableJs) {
              _startSniffing();
            }
          },
          onWebResourceError: (error) {
            AppLog.instance.log(
                '[SniffPlayer] 资源错误: ${error.errorCode} ${error.description} url=${error.url}');
          },
        ),
      )
      ..loadRequest(Uri.parse(url));
  }

  // ── 嗅探 ──

  void _startSniffing() {
    if (_sniffing || !mounted) return;
    _sniffing = true;
    _sniffTries = 0;
    _sniffTimer?.cancel();
    // 先注入嗅探脚本，页面已加载完成，脚本内部会立即扫一轮 + 轮询
    _controller.runJavaScript(_sniffJs).then((_) {
      _sniffTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
        _pollSniff();
      });
    }).catchError((_) {
      _sniffing = false;
      if (mounted) {
        setState(() {
          _hint = '嗅探脚本注入失败，可试试换解析接口或在网页内直接观看';
        });
      }
    });
  }

  void _pollSniff() {
    _controller
        .runJavaScriptReturningResult('window.__sniff.get()')
        .then((result) {
      if (!mounted) return;
      final raw = '$result'.replaceAll('"', '').trim();
      if (raw.isNotEmpty && raw.startsWith('http')) {
        _onSniffed(raw);
        return;
      }
      _sniffTries++;
      if (_sniffTries >= 8) {
        _stopSniffing();
        if (mounted) {
          setState(() {
            _hint = '未嗅探到视频地址，可换解析接口或在网页内直接观看';
          });
        }
      }
    }).catchError((_) {
      _stopSniffing();
    });
  }

  void _onSniffed(String url) {
    _stopSniffing();
    if (!mounted || _autoSwitched) return;
    _autoSwitched = true;
    setState(() {
      _sniffedUrl = url;
      _hint = '已嗅探到视频，正在用原生播放器播放';
    });
    // 切原生播放器（本页留在栈里，返回可继续看网页）
    Get.to(() => MiniAppPlayerPage(url: url, title: widget.title ?? '嗅探播放'));
  }

  void _stopSniffing() {
    _sniffing = false;
    _sniffTimer?.cancel();
    _sniffTimer = null;
  }

  // ── 换解析接口 ──

  Future<void> _switchParser() async {
    final list = ApiConfig.instance.parseBeanList
        .where((p) => p.url.trim().isNotEmpty && (p.type == 0 || p.type == 1))
        .toList();
    if (list.isEmpty) {
      if (mounted) {
        setState(() {
          _hint = '没有可用解析接口';
        });
      }
      return;
    }
    _parseIndex = (_parseIndex + 1) % list.length;
    final bean = list[_parseIndex];
    if (mounted) {
      setState(() {
        _hint = '正在用「${bean.name}」解析…';
      });
    }
    final outcome = await ParseService.instance.parseOutcome(
      widget.url,
      only: bean,
    );
    if (!mounted) return;
    if (outcome != null && outcome.url.isNotEmpty) {
      if (outcome.direct) {
        _autoSwitched = true;
        setState(() {
          _sniffedUrl = outcome.url;
          _hint = '「${bean.name}」解析到直链，正在播放';
        });
        Get.to(() => MiniAppPlayerPage(
            url: outcome.url, title: widget.title ?? '解析播放'));
      } else {
        _autoSwitched = false;
        setState(() {
          _hint = '「${bean.name}」返回网页，正在加载并嗅探';
        });
        _controller.loadRequest(Uri.parse(outcome.url));
      }
    } else {
      setState(() {
        _hint = '「${bean.name}」未命中，换个解析接口试试';
      });
    }
  }

  // ── UI ──

  @override
  void dispose() {
    _stopSniffing();
    try {
      _controller.runJavaScript(
          'try{document.querySelectorAll("video,audio").forEach(function(m){m.pause&&m.pause();});}catch(e){}');
    } catch (_) {}
    if (PlayerPrefs.instance.webviewForceLandscape.value) {
      SystemUiController.exit('sniffPlayer');
    }
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
                WebViewWidget(controller: _controller),
                // 嗅探结果浮标
                if (_sniffedUrl != null)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 8,
                    child: Material(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        child: Row(
                          children: [
                            const Icon(Icons.movie_outlined,
                                color: Colors.white70, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _sniffedUrl!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 12),
                              ),
                            ),
                            TextButton(
                              onPressed: () {
                                Get.to(() => MiniAppPlayerPage(
                                    url: _sniffedUrl!,
                                    title: widget.title ?? '嗅探播放'));
                              },
                              child: const Text('播放',
                                  style: TextStyle(color: Colors.white)),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 底部操作栏
          Container(
            color: Colors.black87,
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).padding.bottom + 4,
              top: 4,
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.refresh, color: Colors.white70),
                  tooltip: '重新嗅探',
                  onPressed: () {
                    _autoSwitched = false;
                    setState(() {
                      _sniffedUrl = null;
                      _hint = '正在嗅探页面里的视频地址…';
                    });
                    _startSniffing();
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.swap_horiz, color: Colors.white70),
                  tooltip: '换解析接口',
                  onPressed: _switchParser,
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      _hint,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
