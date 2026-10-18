import 'dart:async';
import 'dart:convert';

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
import '../../services/sniff_filter.dart';
import '../../services/web_sniff_service.dart';

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

  /// 上游给的请求头（Spider 源的 header / 小程序传入的 header）。
  ///
  /// 嗅探到直链后播放时带上 —— 有些 CDN 校验 Referer/UA，不带就 403。
  /// 解析接口自己的 header 优先级更高（更针对这次解析出的地址）。
  final Map<String, String>? headers;

  /// 嗅探期间（网页还在屏上）是否跟随「网页播放强制横屏」设置。
  ///
  /// 默认 true 保持影视链路原行为；海阔这类**普通网页兜底**传 false ——
  /// 站点页面是竖屏排版的，横过来只露一半（用户 2026-10-18）。
  /// 嗅探到直链切原生播放器后，方向由播放器自己接管。
  final bool forceLandscape;

  const SniffPlayerPage({
    super.key,
    required this.url,
    this.title,
    this.headers,
    this.forceLandscape = true,
  });

  /// 详情页在**已有嗅探页在栈中**时，用它把新地址推给当前这一页重载
  /// （而不是再 push 一层新页）。否则「自动下一集」每集都会叠一层嗅探页，
  /// 返回要连按多次 —— 用户 2026-10-15「嗅探容易影响播放」。
  static final ValueNotifier<String?> pendingUrl = ValueNotifier<String?>(null);

  /// 每次本页 **dispose** 自增一次（详情页据此收尾"嗅探中"标记）。
  ///
  /// 为什么需要：嗅探页被**复用重载**时，是"已存在的那一页"在跑，详情页那次
  /// `_autoSniff` 的 await 早就返回了 ⇒ 没人清 `sniffingUrl`，详情页会永久停在
  /// "正在嗅探视频地址…"占位上。用这个 tick 把"关闭"这个事实广播给上游。
  static final ValueNotifier<int> closedTick = ValueNotifier<int>(0);

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

  /// 网络层兜底（[WebSniffService]）是否已触发 —— 每轮嗅探只跑一次
  bool _httpSniffStarted = false;

  /// 正在做 MIME 复核的地址（防同一地址每轮重复探测）
  final Set<String> _mimeProbing = <String>{};

  /// 最近一轮 `__sniff.all()` 的候选（第 5 轮要做一次 MIME 兜底复核）
  List<String> _lastCandidates = const [];

  /// 当前正在嗅探的地址（复用本页重载时会变化）
  late String _currentUrl;

  /// 源头劫持脚本：在页面自身脚本运行**之前**注入，包住 XHR / fetch /
  /// media.src / setAttribute，只要页面去请求媒体地址就立刻回报。
  ///
  /// 为什么需要它：原来的嗅探只做 `document.querySelectorAll('video,audio')`
  /// + 扫 HTML 源码正则，够不到这三类最常见的情况 ——
  ///   · **iframe 里的播放器**：querySelector 跨不了 frame；
  ///   · **MSE / HLS.js 播放**：`video.src` 是 `blob:`，源码里也没有真实地址；
  ///   · **点了播放才加载**：首屏 HTML 里根本没有地址。
  /// 结果就是嗅探失败 → 只能停在网页里（用户看到的"打开都是 WebView"）。
  ///
  /// ⚠️ 2026-10-15：本脚本必须用 `allFrames: true` 注入到**每个 frame**。
  /// 解析站的播放器多是**跨域 iframe**：主 frame 读 `contentDocument` 会抛
  /// SecurityError，跨域 iframe 里的 video 与请求完全拿不到 —— 只注入主 frame
  /// 时嗅探必然失败（这是嗅探失败最常见的原因）。逐 frame 注入后，iframe 内的
  /// XHR/fetch/media.src 都会经 SniffMedia 通道上报到原生侧。
  static const String _hookTemplate = r'''
(function(){
  if (window.__sniffHooked) return;
  window.__sniffHooked = 1;
  // @EXT@ 由 Dart 侧按**用户当前生效的后缀清单**填入（见 _extAlternation），
  // 不再硬编码 —— 用户在「嗅探设置 → 影视直链后缀」加/删的后缀这里同步生效。
  var MEDIA = /\.(@EXT@)(\?|#|$)/i;
  var reported = {};
  function report(u, trusted){
    try{
      if (!u || typeof u !== 'string') return;
      if (!/^https?:\/\//i.test(u)) return;
      // 可信来源（video/audio 元素的 src）允许**没有后缀**：原生侧会用
      // 响应头 Content-Type 复核（`/play?id=…` 这类扩展名被藏起来的直链）。
      // XHR/fetch 仍然只收影视后缀，否则会把整页 API 请求都报上去。
      if (trusted !== 1 && !MEDIA.test(u)) return;
      if (reported[u]) return;
      reported[u] = 1;
      if (window.SniffMedia && window.SniffMedia.postMessage){
        window.SniffMedia.postMessage((trusted === 1 ? 't:' : '') + u);
      }
    }catch(e){}
  }
  try{
    var _open = XMLHttpRequest.prototype.open;
    XMLHttpRequest.prototype.open = function(m, u){
      try{ report(u); }catch(e){}
      return _open.apply(this, arguments);
    };
  }catch(e){}
  try{
    var _fetch = window.fetch;
    if (_fetch){
      window.fetch = function(input){
        try{ report(typeof input === 'string' ? input : (input && input.url)); }catch(e){}
        return _fetch.apply(this, arguments);
      };
    }
  }catch(e){}
  try{
    var d = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
    if (d && d.set){
      Object.defineProperty(HTMLMediaElement.prototype, 'src', {
        configurable: true, enumerable: true,
        get: function(){ return d.get.call(this); },
        set: function(v){ try{ report(v, 1); }catch(e){} return d.set.call(this, v); }
      });
    }
    var _setAttr = Element.prototype.setAttribute;
    Element.prototype.setAttribute = function(n, v){
      try{
        if (String(n).toLowerCase() === 'src') {
          var t = this && this.tagName ? String(this.tagName).toUpperCase() : '';
          // 只有媒体元素的 src 才是"可信候选"（img/script 的 src 不能算）
          report(v, (t === 'VIDEO' || t === 'AUDIO' || t === 'SOURCE') ? 1 : 0);
        }
      }catch(e){}
      return _setAttr.apply(this, arguments);
    };
  }catch(e){}
})();
''';

  /// 轮询嗅探脚本（注入主 frame）。
  ///
  /// ⚠️ 跨域 iframe 的技术边界（2026-10-15 实测确认）：webview_flutter 4.x 的
  /// `runJavaScript` **没有** allFrames 参数（那是 flutter_inappwebview 的能力），
  /// 脚本只能注入主 frame；而跨域 iframe 的 `contentDocument` 读取会抛
  /// SecurityError。因此**跨域 iframe 内部**由其自身脚本发起的媒体请求目前
  /// 抓不到 —— 只能靠下面三层手段尽量覆盖：
  ///   ① 主 frame 的 video/audio + 整页 HTML 正则（很多解析站主 frame 也会请求媒体）；
  ///   ② **同源 iframe 递归**（含嵌套 iframe）；
  ///   ③ **iframe 的 src/data-* 属性**（跨域也可读）—— 从中抠媒体地址，
  ///      兼容 `xxx?url=<媒体直链>` 这类包裹形式。
  /// 若将来跨域 iframe 站点占比高，需换用支持 allFrames / 资源拦截的
  /// WebView 实现（flutter_inappwebview），本脚本逻辑可原样复用。
  static const String _sniffTemplate = r'''
(function(){
  var found = [], seen = {};
  var MEDIA = /https?:\/\/[^\s"'<>\\]+?\.(?:@EXT@)(?:\?[^\s"'<>\\]*)?/gi;
  function push(u){ if(u && !seen[u] && /^https?:\/\//i.test(u)){ seen[u]=1; found.push(u); } }
  function pushMedia(text){
    if(!text) return;
    var m; MEDIA.lastIndex = 0;
    while((m = MEDIA.exec(text)) !== null){ push(m[0]); }
  }
  function scanDoc(doc, depth){
    if(!doc || depth > 2) return;
    try{
      doc.querySelectorAll('video,audio').forEach(function(m){ push(m.currentSrc || m.src); });
      pushMedia(doc.documentElement ? doc.documentElement.outerHTML : '');
      var frames = doc.querySelectorAll('iframe');
      for(var i=0;i<frames.length;i++){
        var f = frames[i];
        // 跨域 iframe 读不了 contentDocument，但 src / data-* 属性可读
        try{
          ['src','data-src','data-url','data-video','data-file','data-original'].forEach(function(a){
            var v = f.getAttribute && f.getAttribute(a);
            if(!v) return;
            push(v);
            try{ pushMedia(decodeURIComponent(v)); }catch(e2){ pushMedia(v); }
          });
        }catch(e){}
        // 同源 iframe → 递归（嵌套 iframe 一并覆盖）
        try{
          var fd = f.contentDocument;
          if(fd) scanDoc(fd, depth + 1);
        }catch(e){}
      }
    }catch(e){}
  }
  window.__sniff = {
    scan: function(){ scanDoc(document, 0); return found.length; },
    get: function(){ scanDoc(document, 0); return found.length ? found[0] : ''; },
    // 取足够多：前几个常是切片广告，原生侧会逐个过 SniffFilter 挑正片，
    // 截取太少会把排在后面的正片漏掉（2026-10-15）。
    all: function(){ scanDoc(document, 0); return found.slice(0, 30); }
  };
  var tries = 0;
  var timer = setInterval(function(){
    scanDoc(document, 0);
    // ⚠️ 不能"一抓到就停"：第一个命中的常是切片广告（/ads/x.m3u8 之类），
    // 提前停扫就轮不到正片。固定扫满 16 轮，候选全部交给原生侧
    // （SniffFilter：影视后缀 + 黑/白名单）挑选，2026-10-15。
    if(++tries >= 16){ clearInterval(timer); }
  }, 1200);
})();
''';

  /// 注入用的 hook 脚本（后缀按当前清单填入）
  static String get _hookJs =>
      _hookTemplate.replaceAll('@EXT@', SniffFilter.mediaExtAlternation);

  /// 注入用的轮询嗅探脚本（后缀按当前清单填入）
  static String get _sniffJs =>
      _sniffTemplate.replaceAll('@EXT@', SniffFilter.mediaExtAlternation);

  @override
  void initState() {
    super.initState();
    if (widget.forceLandscape &&
        PlayerPrefs.instance.webviewForceLandscape.value) {
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
    _currentUrl = widget.url;
    _initController(widget.url);
    // 详情页需要用本页换地址时（不再叠新页），通过 pendingUrl 通知
    SniffPlayerPage.pendingUrl.addListener(_onPendingUrl);
  }

  /// 详情页要求本页换地址重载（复用本页，避免嗅探页叠层）。
  void _onPendingUrl() {
    final next = SniffPlayerPage.pendingUrl.value;
    if (next == null || next.isEmpty || !mounted) return;
    SniffPlayerPage.pendingUrl.value = null;
    if (next == _currentUrl) return;
    AppLog.instance.log('[SniffPlayer] 复用本页重载新地址: $next');
    _currentUrl = next;
    _autoSwitched = false;
    _mimeProbing.clear();
    _lastCandidates = const [];
    setState(() {
      _sniffedUrl = null;
      _hint = '正在嗅探页面里的视频地址…';
    });
    _controller.loadRequest(
      Uri.parse(next),
      headers: widget.headers ?? const <String, String>{},
    );
  }

  void _initController(String url) {
    final enableJs = PlayerPrefs.instance.webviewEnableJs.value;
    _controller = WebViewController()
      // 劫持回报通道：webview_flutter 的 JavaScriptChannel 是随页面加载
      // 自动注入到 window 的，所以页面自身脚本一定能看到它。
      // 命中即自动切猫影原生播放器（_onSniffed 内部有 _autoSwitched 去重）。
      ..addJavaScriptChannel(
        'SniffMedia',
        onMessageReceived: (msg) {
          final raw = msg.message;
          if (raw.isEmpty) return;
          // `t:` 前缀 = 来自 video/audio 元素的**可信**候选，可能没有媒体后缀，
          // 需要原生侧用 Content-Type 复核（见 _onTrustedCandidate）。
          if (raw.startsWith('t:')) {
            _onTrustedCandidate(raw.substring(2));
          } else {
            _onSniffed(raw);
          }
        },
      )
      ..setJavaScriptMode(
        enableJs ? JavaScriptMode.unrestricted : JavaScriptMode.disabled,
      )
      ..setBackgroundColor(const Color(0xFF000000))
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
            _stopSniffing();
            // 抢在页面自身脚本执行前注入劫持脚本（漏掉的由页面完成后的轮询嗅探兜底）
            _controller.runJavaScript(_hookJs);
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
              '[SniffPlayer] 资源错误: ${error.errorCode} ${error.description} url=${error.url}',
            );
          },
        ),
      )
      ..loadRequest(
        Uri.parse(url),
        // 上游给的 header 也用于**加载网页本身**：部分播放页要求特定
        // Referer/UA 才返回内容（2026-10-15）
        headers: widget.headers ?? const <String, String>{},
      );
  }

  // ── 嗅探 ──

  void _startSniffing() {
    if (_sniffing || !mounted) return;
    _sniffing = true;
    _sniffTries = 0;
    // 每轮嗅探重置网络层兜底标记（「重新嗅探」/ 复用重载都会重新进来）
    _httpSniffStarted = false;
    _sniffTimer?.cancel();
    // 页面已完成 → 再补一次 hook 注入（幂等：脚本内有 window.__sniffHooked
    // 守卫）。onPageStarted 那次可能早于文档就绪而没被保留，补这一次保证
    // 页面自身脚本在 onPageFinished 之后发起的请求都能劫持到（2026-10-15）。
    _controller.runJavaScript(_hookJs);
    // 再注入嗅探脚本，脚本内部会立即扫一轮 + 轮询
    _controller
        .runJavaScript(_sniffJs)
        .then((_) {
          _sniffTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
            _pollSniff();
          });
        })
        .catchError((_) {
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
        .runJavaScriptReturningResult('window.__sniff.all()')
        .then((result) {
          if (!mounted) return;
          // 一次拿全部候选，在原生侧过 SniffFilter（后缀 + 黑/白名单）：
          // 第一个可能是广告，必须跳过广告继续挑正片，不能见一个就上。
          final candidates = _candidatesOf(result);
          _lastCandidates = candidates;
          for (final u in candidates) {
            if (SniffFilter.acceptSniffUrl(u)) {
              _onSniffed(u);
              return;
            }
          }
          _sniffTries++;
          // 第 5 轮（约 7.5 秒）还没结果 → 大概率播放器躲在**跨域 iframe** 里
          // （WebView 注入不到子 frame）。转"网络层兜底"：Dart 直接取页面与
          // iframe 的 HTML 扫媒体地址，Dart 发 HTTP 不受同源策略限制。
          if (_sniffTries == 5) {
            unawaited(_httpSniffFallback());
            // 顺带对"有 video 元素但地址没有后缀"的候选做一次 MIME 复核
            unawaited(_probeLastCandidates());
          }
          // 16 轮 × 1.5 秒 = 24 秒：慢页面 / 慢加载 / 需点播放才起播的站点
          // 之前 8 轮（12 秒）经常还没等到地址就放弃（2026-10-15）。
          if (_sniffTries >= 16) {
            _stopSniffing();
            if (mounted) {
              setState(() {
                _hint = '未嗅探到可播放的影视地址（可能被过滤规则排除），可在播放设置 → 嗅探设置里调整';
              });
            }
          }
        })
        .catchError((_) {
          _stopSniffing();
        });
  }

  /// 把 JS `__sniff.all()` 的返回（iOS/Android 可能是 List 或 JSON 字符串）
  /// 解析成候选列表（不做规则过滤）。
  List<String> _candidatesOf(dynamic result) {
    final candidates = <String>[];
    if (result is List) {
      candidates.addAll(result.map((e) => '$e'));
    } else {
      final raw = '$result'.trim();
      if (raw.isEmpty || raw == 'null' || raw == '[]') return const [];
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
    }
    return candidates;
  }

  /// 空后缀候选的 MIME 复核（来自页面里 video/audio 元素的 src）。
  ///
  /// 只用于**可信来源**：命中才切播放器；黑/白名单照旧生效
  /// （[SniffFilter.acceptSniffUrl] 的 `mediaVerified: true` 分支）。
  Future<void> _onTrustedCandidate(String url) async {
    if (!mounted || _autoSwitched) return;
    final u = url.trim();
    if (u.isEmpty) return;
    if (SniffFilter.acceptSniffUrl(u)) {
      _onSniffed(u);
      return;
    }
    // 有影视后缀却被规则挡住（黑/白名单）⇒ 尊重用户的过滤规则，不做兜底
    if (SniffFilter.isDirectMedia(u)) return;
    if (!_mimeProbing.add(u)) return;
    AppLog.instance.log('[SniffPlayer] 无后缀候选，MIME 复核: $u');
    final ok = await WebSniffService.instance.looksLikeMediaByMime(
      u,
      referer: _currentUrl,
    );
    _mimeProbing.remove(u);
    if (!ok || !mounted || _autoSwitched) return;
    if (!SniffFilter.acceptSniffUrl(u, mediaVerified: true)) return;
    setState(() => _hint = '按响应类型识别到视频，正在播放');
    _onSniffed(u, mediaVerified: true);
  }

  /// 第 5 轮兜底：把 `__sniff.all()` 里**没有影视后缀**的候选拿去问服务器
  /// 的 Content-Type（最多 6 个并发）。覆盖 `<video src="/play?id=…">` 这种
  /// 页面加载时就已经存在、不会触发 src setter 的写法。
  Future<void> _probeLastCandidates() async {
    if (!mounted || _autoSwitched) return;
    final batch = _lastCandidates
        .where((u) => !SniffFilter.isDirectMedia(u))
        .toSet()
        .take(6)
        .toList();
    if (batch.isEmpty) return;
    AppLog.instance.log('[SniffPlayer] MIME 兜底复核 ${batch.length} 个无后缀候选');
    final checks = await Future.wait(
      batch.map(
        (u) => WebSniffService.instance.looksLikeMediaByMime(
          u,
          referer: _currentUrl,
        ),
      ),
    );
    for (var i = 0; i < checks.length; i++) {
      if (!checks[i] || !mounted || _autoSwitched) continue;
      final u = batch[i];
      if (!SniffFilter.acceptSniffUrl(u, mediaVerified: true)) continue;
      setState(() => _hint = '按响应类型识别到视频，正在播放');
      _onSniffed(u, mediaVerified: true);
      return;
    }
  }

  void _onSniffed(String url, {bool mediaVerified = false}) {
    // 统一过嗅探规则（必须影视直链后缀 + 黑/白名单去广告）。
    // hook 实时上报的切片广告会在这里被挡住 —— 不停止轮询、不切播放器，
    // 继续等正片地址。
    // mediaVerified：地址没有后缀、但已用响应头确认是视频（见 _onTrustedCandidate）。
    if (!SniffFilter.acceptSniffUrl(url, mediaVerified: mediaVerified)) {
      AppLog.instance.log('[SniffPlayer] 候选被嗅探规则过滤: $url');
      return;
    }
    _stopSniffing();
    if (!mounted || _autoSwitched) return;
    _autoSwitched = true;
    setState(() {
      _sniffedUrl = url;
      _hint = '已嗅探到视频，正在用原生播放器播放';
    });
    // ⚠️ 切原生播放器前必须**先静音并暂停网页里的媒体**：本页只是被
    // 覆盖、并未销毁，网页里的 video 若在自动播放就会和原生播放器
    // **双份出声**（用户 2026-10-15「嗅探容易影响播放」）。
    _pauseWebMedia();
    // 切原生播放器（本页留在栈里，返回可继续看网页）
    Get.to(
      () => MiniAppPlayerPage(
        url: url,
        title: widget.title ?? '嗅探播放',
        headers: _playHeaders(),
      ),
    );
  }

  /// 暂停并静音 WebView 里的所有 video/audio（切原生播放器前调用，防双声）
  void _pauseWebMedia() {
    try {
      _controller.runJavaScript(
        'try{document.querySelectorAll("video,audio").forEach(function(m){try{m.pause();m.muted=true;}catch(e){}});}catch(e){}',
      );
    } catch (_) {}
  }

  /// 播放直链时要带的请求头。
  ///
  ///   · [widget.headers]：上游（Spider 源 / 小程序）给的 header（打底）；
  ///   · [extra]：解析接口自带的 header —— 更针对这次解析出的地址，覆盖上游；
  ///   · 「播放带 Referer」开关开启时补一条 `Referer: 当前网页地址` ——
  ///     部分 CDN 强制校验 Referer，不带就 403（用户 2026-10-15 拍板加的开关，
  ///     默认关闭）。已有 Referer 时不覆盖。
  Map<String, String>? _playHeaders([Map<String, String>? extra]) {
    final h = <String, String>{...?widget.headers, ...?extra};
    if (PlayerPrefs.instance.sniffSendReferer.value && _currentUrl.isNotEmpty) {
      h.putIfAbsent('Referer', () => _currentUrl);
    }
    return h.isEmpty ? null : h;
  }

  /// **跨域 iframe 的网络层兜底**（用户 2026-10-15）。
  ///
  /// WebView 里的注入脚本进不了跨域 iframe（webview_flutter 没有 allFrames），
  /// 但 Dart 侧发 HTTP 没有同源策略 —— 由 [WebSniffService] 取页面与其中
  /// iframe 的 HTML，在网络层扫媒体地址。命中后走正常的过滤与切播放器流程。
  Future<void> _httpSniffFallback() async {
    if (_httpSniffStarted || !mounted) return;
    _httpSniffStarted = true;
    AppLog.instance.log('[SniffPlayer] 转网络层兜底嗅探: $_currentUrl');
    try {
      final hit = await WebSniffService.instance.findMediaUrl(
        _currentUrl,
        referer: _currentUrl,
      );
      if (hit == null || !mounted) return;
      if (mounted) {
        setState(() => _hint = '已从页面 / iframe 里找到视频地址，正在播放');
      }
      // 没有影视后缀的命中是 MIME 兜底验证过的（Content-Type），
      // 这里把"已验证"告诉过滤器，否则会被后缀规则再挡一次。
      _onSniffed(hit, mediaVerified: !SniffFilter.isDirectMedia(hit));
    } catch (e) {
      AppLog.instance.log('[SniffPlayer] 网络层兜底失败: $e');
    }
  }

  void _stopSniffing() {
    _sniffing = false;
    _sniffTimer?.cancel();
    _sniffTimer = null;
  }

  // ── 换解析接口 ──

  Future<void> _switchParser() async {
    // 解析总开关关闭：parseOutcome(only:) 不经过 enabled 判定，这里手动拦一道
    if (!PlayerPrefs.instance.parseEnabled.value) return;
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
      // 用 _currentUrl 而不是 widget.url：本页可能已被"复用重载"到别的
      // 集数地址（详情页自动下一集时走 pendingUrl），拿最初的 widget.url
      // 会解析错集（2026-10-15 深挖发现）。
      _currentUrl,
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
        _pauseWebMedia(); // 同上：防网页与原生播放器双份出声
        // 解析接口自带的请求头 + 按开关补的 Referer 一并带上（防盗链）
        Get.to(
          () => MiniAppPlayerPage(
            url: outcome.url,
            title: widget.title ?? '解析播放',
            headers: _playHeaders(outcome.headers),
          ),
        );
      } else {
        _autoSwitched = false;
        setState(() {
          _hint = '「${bean.name}」返回网页，正在加载并嗅探';
        });
        _controller.loadRequest(
          Uri.parse(outcome.url),
          // 解析接口自带的 header 也用于加载这个网页
          headers: outcome.headers ?? const <String, String>{},
        );
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
    SniffPlayerPage.pendingUrl.removeListener(_onPendingUrl);
    // 本页已关闭：清掉可能残留的重载请求，避免干扰下一次打开
    SniffPlayerPage.pendingUrl.value = null;
    // 通知上游（详情页）"嗅探页已关闭"：详情页据此收尾 `sniffingUrl`。
    // ⚠️ 必须有这个信号：嗅探页**被复用重载**时（pendingUrl），详情页那次
    //    `_autoSniff` 的 await 早已返回，没人再把 sniffingUrl 清掉 ⇒
    //    详情页会永久停在"正在嗅探视频地址…"的黑底占位上。
    SniffPlayerPage.closedTick.value++;
    _stopSniffing();
    try {
      _controller.runJavaScript(
        'try{document.querySelectorAll("video,audio").forEach(function(m){m.pause&&m.pause();});}catch(e){}',
      );
    } catch (_) {}
    if (widget.forceLandscape &&
        PlayerPrefs.instance.webviewForceLandscape.value) {
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
                          horizontal: 12,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.movie_outlined,
                              color: Colors.white70,
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _sniffedUrl!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () {
                                _pauseWebMedia(); // 防双声
                                Get.to(
                                  () => MiniAppPlayerPage(
                                    url: _sniffedUrl!,
                                    title: widget.title ?? '嗅探播放',
                                    headers: _playHeaders(),
                                  ),
                                );
                              },
                              child: const Text(
                                '播放',
                                style: TextStyle(color: Colors.white),
                              ),
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
                // 解析总开关关闭时不显示「换解析接口」（2026-10-15）
                if (PlayerPrefs.instance.parseEnabled.value)
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
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 12,
                      ),
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
