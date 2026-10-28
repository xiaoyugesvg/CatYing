import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/ad_block_service.dart';
import 'package:tvbox/services/player_prefs.dart';
import 'package:tvbox/services/play_url_sanitizer.dart';
import 'package:tvbox/services/sniff_filter.dart';
import 'package:tvbox/services/web_sniff_service.dart';
import 'package:tvbox/pages/play/sniff_player_page.dart';
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

  /// 内嵌模式右上角的「嗅探」入口（2026-10-28）：网页兜底播放没有 VideoPlayerWidget
  /// 底栏，用户看不到嗅探/解析入口 —— 而「解析站 IP 超限」这类页面恰恰最需要
  /// 换线路。传了就显示右上角浮钮。
  final VoidCallback? onSniff;

  /// 内嵌模式右上角的「解析」入口。
  final VoidCallback? onSwitchParse;

  /// 后台嗅探到可播放直链时回调（**同页**切原生播放器，不弹新页面）。
  ///
  /// 详情页内嵌模式传它：网页先照常加载（播放器一定出来），后台嗅探到
  /// m3u8/mp4 后由详情页把 playUrl 换成直链 —— 全程同一个页面，不再
  /// 「详情页 → 嗅探页 → 播放器页」三层跳转（用户 2026-10-28 要求）。
  final void Function(String url)? onMediaFound;

  const WebviewPlayerPage({
    super.key,
    required this.url,
    this.title,
    this.embedded = false,
    this.forceLandscape = true,
    this.onSniff,
    this.onSwitchParse,
    this.onMediaFound,
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

  // ── 后台嗅探（2026-10-28）──
  //
  // 详情页内嵌网页播放器时，网页照常显示（播放器一定出来），同时后台
  // 注入与嗅探页同一套 hook 脚本，抓到 m3u8/mp4 就回调 onMediaFound，
  // 由详情页**同页**切原生播放器 —— 不再跳独立嗅探页。
  bool _sniffing = false;
  Timer? _sniffTimer;
  int _sniffTries = 0;
  bool _mediaReported = false;

  /// XHR/fetch 上报的无后缀候选（第 5 轮统一做 MIME 复核）
  final List<String> _unverified = <String>[];

  /// 正在做 MIME 复核的地址（防重复探测）
  final Set<String> _mimeProbing = <String>{};

  /// **实际载入的地址**（`_load` 里 sanitize / 补协议之后的形态）。
  ///
  /// MIME 复核要拿它当 `Referer` —— 不能用 `widget.url`：那是源给的原始串，
  /// 可能带 `tencent|hash|` 前缀或只有路径，拿它当 Referer 会被站点拒。
  String _loadedUrl = '';

  /// 网络层兜底是否已发起（每份文档一次，见 [_httpSniffFallback]）
  bool _httpSniffStarted = false;

  /// 换文档 / 换集时把上一页的嗅探中间状态清干净。
  ///
  /// 🔴 不清 `_unverified` 会串集：上一页攒下的无后缀候选还留在列表里，
  /// 新一集做 MIME 复核时可能命中**上一集**的直链，播出来的内容是错的。
  void _resetSniffState() {
    _unverified.clear();
    _mimeProbing.clear();
    _sniffTries = 0;
    _httpSniffStarted = false;
  }

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
      // 后台嗅探上报通道（与嗅探页共用同一套 hook 脚本）
      ..addJavaScriptChannel(
        'SniffMedia',
        onMessageReceived: (msg) => _onChannelMessage(msg.message),
      )
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
            // 新文档开始：上一页的嗅探结果作废，重新来过
            _stopSniffing();
            _resetSniffState();
            _mediaReported = false;
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
            // 页面就绪 → 后台嗅探（命中后由详情页同页切原生播放器）
            _startSniffing();
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
    // 先剥掉 `类型|哈希|真实URL` 包裹（TVBox 社区源常见，如
    // `tencent|54e3…|https://v.qq.com/…`）：否则 webview_flutter 的
    // loadRequest 会抛 `Missing scheme in uri`，被全局 ErrorWidget
    // 捕成「界面渲染出错」整页报错（用户 2026-10-28 截图）。
    var url = sanitizePlayUrl(raw);
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
    _loadedUrl = url;
    _controller.loadRequest(uri);
  }

  // ============================================================
  // 后台嗅探（2026-10-28）
  //
  // 详情页内嵌网页播放器时：网页照常显示（播放器一定出来），同时后台
  // 跑与嗅探页**同一套** hook / 轮询脚本。抓到 m3u8/mp4 就回调
  // [WebviewPlayerPage.onMediaFound]，由详情页同页切原生播放器。
  // ============================================================

  void _startSniffing() {
    if (_sniffing || _mediaReported || !mounted) return;
    // 没有上层可切（独立全屏页）或 JS 被关掉时不做后台嗅探
    if (widget.onMediaFound == null) return;
    if (!PlayerPrefs.instance.webviewEnableJs.value) return;
    // 「自动嗅探」总开关（默认关）：影视端（详情 / 短剧 / 媒体库）内嵌网页
    // 也遵守 —— 关掉后网页照常显示、不再后台自动嗅探切原生；需要时用户点
    // 「嗅」按钮走独立嗅探页（P1-1 深层语义，2026-10-28）。
    if (!PlayerPrefs.instance.sniffEnabled.value) return;
    _sniffing = true;
    _sniffTries = 0;
    _sniffTimer?.cancel();
    // 🔴 必须**串行**：`hookScript` 负责建 `window.__sniff`，
    // `sniffScript` 一上来就调它。原来两个 runJavaScript 并发发出，
    // sniffScript 有可能先执行 → `__sniff` undefined → catchError 里把
    // `_sniffing` 置回 false，这一页就再也不嗅了（静默失效）。
    _controller
        .runJavaScript(SniffPlayerPage.hookScript)
        .then((_) => _controller.runJavaScript(SniffPlayerPage.sniffScript))
        .then((_) {
          if (!mounted || _mediaReported) return;
          _sniffTimer = Timer.periodic(
            const Duration(milliseconds: 1500),
            (_) => _pollSniff(),
          );
        })
        .catchError((_) {
          _sniffing = false;
        });
  }

  void _pollSniff() {
    _controller
        .runJavaScriptReturningResult('window.__sniff.all()')
        .then((result) {
      if (!mounted || _mediaReported) return;
      final candidates = _candidatesOf(result);
      // 一次拿全部候选，过 SniffFilter（后缀 + 黑/白名单）——
      // 先按"整片优先"排序：`.m3u8` 主列表排在 `.ts` 切片前面，
      // 否则可能只拿到某一小段（播几秒就结束）。见 `SniffFilter.rankCandidates`。
      for (final u in SniffFilter.rankCandidates(candidates)) {
        if (SniffFilter.acceptSniffUrl(u)) {
          _reportMedia(u);
          return;
        }
      }
      _sniffTries++;
      // 每 4 轮（约 6 秒）对"藏起后缀"的候选做一次 MIME 复核。
      // 原来只在第 5 轮触发**一次** —— 若候选在第 6 轮之后才冒出来，
      // 就再也不会被复核（典型：播放器先拉广告、十几秒后才拉正片）。
      if (_sniffTries >= 5 && _sniffTries % 4 == 1) {
        unawaited(_mimeFallback(candidates));
      }
      // ── 网络层兜底（跨域 iframe 的唯一出路）────────────────────
      //
      // 🔴 这是**新的主链路**（详情页内嵌网页播放器）之前完全缺失的一环：
      // webview_flutter 4.x 的 `runJavaScript` 没有 allFrames，注入脚本只能
      // 作用于主 frame；而解析站的播放器**几乎都是跨域 iframe** ——
      // 主 frame 里根本没有媒体地址，JS 侧扫到停轮询也不会命中。
      // 旧的独立嗅探页（`SniffPlayerPage`）一直有这条兜底，迁移到内嵌
      // 播放器时漏了，表现为"解析站明明能播，内嵌播放器却一直停在网页上"。
      //
      // JS 侧扫了约 9 秒仍一无所获，就交给 Dart 侧发 HTTP 去取页面 +
      // iframe 的 HTML 再扫（Dart 没有同源策略）。
      if (_sniffTries >= 6) unawaited(_httpSniffFallback());
      // 12 轮（18 秒）还没结果就停轮询，别一直空转。
      // ⚠️ `SniffMedia` 通道不受它影响 —— 之后页面自己上报的仍会处理。
      if (_sniffTries >= 12) _stopSniffing();
    }).catchError((_) {
      // JS 侧直接不可用（页面禁注入 / `__sniff` 没建成）→ 直接走网络层兜底
      unawaited(_httpSniffFallback());
      _stopSniffing();
    });
  }

  /// 跨域 iframe 的**网络层兜底嗅探**（思路与 `SniffPlayerPage` 的同名方法一致）。
  ///
  /// 每份文档只跑一次：它会真发若干个 HTTP 请求（最多 8 个页面 + 6 次 MIME
  /// 探测），重复跑只会拖慢切原生播放器的时机。
  Future<void> _httpSniffFallback() async {
    if (_httpSniffStarted || _mediaReported || !mounted) return;
    final page = _loadedUrl.isNotEmpty ? _loadedUrl : widget.url;
    if (!page.startsWith('http')) return;
    _httpSniffStarted = true;
    AppLog.instance.log('[WebviewPlayer] JS 侧未命中 → 转网络层兜底嗅探: $page');
    try {
      final hit = await WebSniffService.instance.findMediaUrl(
        page,
        referer: page,
      );
      if (hit == null || !mounted) return;
      // 没有影视后缀的命中是 MIME 兜底验证过的，这里把"已验证"告诉过滤器，
      // 否则会被后缀规则再挡一次。
      _reportMedia(hit, verified: !SniffFilter.isDirectMedia(hit));
    } catch (e) {
      AppLog.instance.log('[WebviewPlayer] 网络层兜底失败: $e');
    }
  }

  /// 把 JS `__sniff.all()` 的返回（iOS/Android 可能是 List 或 JSON 字符串）
  /// 解析成候选列表（不做规则过滤）。
  List<String> _candidatesOf(dynamic result) {
    final candidates = <String>[];
    if (result is List) {
      candidates.addAll(result.map((e) => '$e'));
      return candidates;
    }
    final raw = '$result'.trim();
    if (raw.isEmpty || raw == 'null' || raw == '[]') return candidates;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        candidates.addAll(decoded.map((e) => '$e'));
      } else if (decoded is String) {
        candidates.add(decoded);
      }
    } catch (_) {
      if (raw.startsWith('http')) candidates.add(raw.replaceAll('"', ''));
    }
    return candidates;
  }

  /// hook 通过 `SniffMedia` 通道实时上报的候选。
  void _onChannelMessage(String raw) {
    if (raw.isEmpty || _mediaReported || widget.onMediaFound == null) return;
    if (raw.startsWith('t:')) {
      // 可信来源（video/audio/source 的 src）：可能没有后缀，MIME 复核
      final u = raw.substring(2);
      if (SniffFilter.acceptSniffUrl(u)) {
        _reportMedia(u);
        return;
      }
      if (!SniffFilter.isDirectMedia(u)) unawaited(_verifyMime(u));
      return;
    }
    if (raw.startsWith('u:')) {
      // XHR/fetch 的无后缀候选：攒着，第 5 轮统一批量复核
      final u = raw.substring(2);
      if (SniffFilter.isDirectMedia(u)) {
        _reportMedia(u);
        return;
      }
      if (!_unverified.contains(u) && _unverified.length < 24) {
        _unverified.add(u);
      }
      return;
    }
    // 带影视后缀的候选：直接过规则
    _reportMedia(raw);
  }

  Future<void> _verifyMime(String u) async {
    if (_mediaReported || _mimeProbing.contains(u)) return;
    _mimeProbing.add(u);
    try {
      final ok = await WebSniffService.instance
          .looksLikeMediaByMime(u, referer: _loadedUrl);
      if (ok && mounted) _reportMedia(u, verified: true);
    } finally {
      _mimeProbing.remove(u);
    }
  }

  Future<void> _mimeFallback(List<String> candidates) async {
    if (_mediaReported || !mounted) return;
    final batch = <String>{
      ...candidates.where((u) => !SniffFilter.isDirectMedia(u)),
      ..._unverified.where((u) => !SniffFilter.isDirectMedia(u)),
    }.take(8).toList();
    if (batch.isEmpty) return;
    final checks = await Future.wait(
      batch.map((u) =>
          WebSniffService.instance.looksLikeMediaByMime(u, referer: _loadedUrl)),
    );
    for (var i = 0; i < checks.length; i++) {
      if (checks[i] && mounted) {
        _reportMedia(batch[i], verified: true);
        return;
      }
    }
  }

  /// 命中直链 → 先停网页媒体（防双声），再回调详情页切原生播放器。
  void _reportMedia(String url, {bool verified = false}) {
    if (_mediaReported || !mounted) return;
    if (!SniffFilter.acceptSniffUrl(url, mediaVerified: verified)) return;
    _mediaReported = true;
    _stopSniffing();
    _pauseWebMedia();
    AppLog.instance.log(
        '[WebviewPlayer] 后台嗅探命中${verified ? '（MIME 复核）' : ''}: $url');
    widget.onMediaFound?.call(url);
  }

  void _pauseWebMedia() {
    try {
      _controller.runJavaScript(
        'try{document.querySelectorAll("video,audio").forEach(function(m){try{m.pause();m.muted=true;}catch(e){}});}catch(e){}',
      );
    } catch (_) {}
  }

  void _stopSniffing() {
    _sniffing = false;
    _sniffTimer?.cancel();
    _sniffTimer = null;
  }

  @override
  void didUpdateWidget(covariant WebviewPlayerPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换集 / 换清晰度 / 换线路时 URL 变化 → 重新加载
    if (oldWidget.url != widget.url) {
      _stopSniffing();
      _resetSniffState();
      _mediaReported = false;
      setState(() {
        _loadingProgress = 0;
        _failed = false; // 换集/换线路：复位失败态
      });
      _load(widget.url);
    }
  }

  @override
  void dispose() {
    _stopSniffing();
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

  /// 内嵌模式右上角「嗅探 / 解析」两个浮钮（2026-10-28：拆成两个独立按钮，
  /// 无论开关是否打开都常驻显示）。
  Widget _sniffParseButtons() {
    final children = <Widget>[];
    if (widget.onSniff != null) {
      children.add(_roundFab(
        label: '嗅',
        color: const Color(0xFF4c8dff),
        onTap: widget.onSniff!,
      ));
    }
    if (widget.onSwitchParse != null) {
      children.add(_roundFab(
        label: '解',
        color: const Color(0xFFffd54a),
        onTap: widget.onSwitchParse!,
      ));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: children
          .map((w) => Padding(padding: const EdgeInsets.only(bottom: 8), child: w))
          .toList(),
    );
  }

  Widget _roundFab({
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
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
          child: Stack(
            children: [
              Positioned.fill(child: body),
              // 网页兜底播放没有底栏 → 右上角补「嗅探 / 解析」两个入口
              if (widget.onSniff != null || widget.onSwitchParse != null)
                Positioned(
                  top: 6,
                  right: 6,
                  child: _sniffParseButtons(),
                ),
            ],
          ),
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
