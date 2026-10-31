import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/services/media_resolver.dart';
import 'package:tvbox/services/parse_lines.dart';
import 'package:tvbox/services/platform_domains.dart';
import 'package:tvbox/services/sniffer_hook_js.dart';
import 'package:tvbox/services/webview_sniffer.dart';
import 'package:tvbox/widgets/app_toast.dart';

/// 「解析 / 嗅探测试」页（独立测试用，验证 OK 再并入正式播放）。
///
/// 两种测试分开：
///   · **解析测试**：走现有 HTTP 解析（页面抓取 + 解析线路），看能不能直接出直链；
///   · **嗅探测试**：离屏 WebView 加载页面 + 注入 hook，抓页面里 JS 拼出的媒体地址。
///
/// 平台域名（爱奇艺/优酷/腾讯/芒果/B站/PPTV）建议先用「解析测试」走线路；
/// 其它普通播放页用「嗅探测试」直接抓。
class SnifferProbePage extends StatefulWidget {
  const SnifferProbePage({super.key});

  @override
  State<SnifferProbePage> createState() => _SnifferProbePageState();
}

class _SnifferProbePageState extends State<SnifferProbePage> {
  final _urlCtrl = TextEditingController(
      text:
          'https://jx.muiu.site/?url=https://v.qq.com/x/cover/mzc00200803dr6b/g4102ay41nf.html');
  final _collector = SnifferCollector();

  // ── 嗅探状态 ──
  WebViewController? _controller;
  Timer? _tick;
  Timer? _deadline;
  Timer? _loadWatchdog;
  Timer? _warmupTimer;
  bool _running = false;
  bool _warmupStarted = false;
  bool _sniffStarted = false;
  DateTime? _sniffStart;
  String _status = '待开始';
  String? _routeMode;

  // ── 解析状态 ──
  bool _parseRunning = false;
  String _parseStatus = '';
  String? _parseResult;

  /// 页面加载完成后先等一会儿，让线路 / 页面 JS 跑起来，再开始计时嗅探。
  static const Duration _warmup = Duration(seconds: 5);

  /// 正式嗅探窗口（从预热结束开始算，不把加载时间算进去）。
  static const Duration _budget = Duration(seconds: 20);

  /// 页面迟迟不触发 onPageFinished 时的兜底，避免一直卡在「加载中」。
  static const Duration _loadWatchdogTimeout = Duration(seconds: 15);

  @override
  void dispose() {
    _cancelTimers();
    _controller = null;
    _urlCtrl.dispose();
    super.dispose();
  }

  void _cancelTimers() {
    _tick?.cancel();
    _tick = null;
    _deadline?.cancel();
    _deadline = null;
    _loadWatchdog?.cancel();
    _loadWatchdog = null;
    _warmupTimer?.cancel();
    _warmupTimer = null;
  }

  // ── 解析测试：走现有 HTTP 解析（页面抓取 + 解析线路）─────────────────
  Future<void> _testParse() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      AppToast.show('先填链接', '');
      return;
    }
    setState(() {
      _parseRunning = true;
      _parseResult = null;
      _parseStatus = '准备解析…';
    });
    // 解析线路懒同步：没读过就先读，订阅里的 parses 也拉一次
    try {
      final store = ParseLineStore.instance;
      await store.load();
      if (store.isEmpty) await store.ensureSyncedFromConfig();
    } catch (_) {}
    try {
      final r = await MediaResolver.instance.resolve(
        url,
        // ── 2026-10-31 改：这里跑**完整链路**（抓页面 → 线路 → 嗅探兜底）──
        //
        // 上一版为了让两种测试可比，这里关掉了嗅探兜底。结果用户拿
        // `jx.muiu.site/?url=v.qq.com/...` 一点，3.8 秒就「解析失败」——
        // 而这条地址在电脑浏览器里是**能播的、猫爪也能抓到媒体**。
        // 原因是它必须执行页面 JS，纯 HTTP 抓 HTML 永远空手。
        //
        // 「解析测试」该回答的问题是「**真实播放能不能出地址**」，所以
        // 它必须和播放链路一致（`allowSniff` 默认就是 true）。想知道
        // 是哪一步通的，看上面那行状态文字（会显示"改用浏览器嗅探…"）。
        // 只想单独看嗅探抓到了什么，用「嗅探测试」。
        onProgress: (m) {
          if (mounted) setState(() => _parseStatus = m);
        },
      );
      if (!mounted) return;
      setState(() {
        _parseResult = r;
        _parseStatus = r == null
            ? '完整链路也没出直链（抓页面 + 线路 + 嗅探都试过了）'
            : '解析成功';
      });
    } catch (e) {
      if (mounted) setState(() => _parseStatus = '解析异常: $e');
    } finally {
      if (mounted) setState(() => _parseRunning = false);
    }
  }

  // ── 嗅探测试：离屏 WebView 加载页面 + 注入 hook ─────────────────────
  Future<void> _startSniff() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      AppToast.show('先填链接', '');
      return;
    }
    _cancelTimers();
    _collector.clear();
    _warmupStarted = false;
    _sniffStarted = false;
    _sniffStart = null;
    _routeMode = isVideoPlatformUrl(url)
        ? '平台链接：正在嗅探原页面（平台链接建议用「解析测试」走线路）'
        : '普通页面：直接嗅探抓取';
    setState(() {
      _running = true;
      _status = '加载页面…';
    });

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(kChromeMobileUA)
      ..addJavaScriptChannel('CatSniff', onMessageReceived: (msg) {
        _onJs(msg.message);
      })
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => _inject(),
        onPageFinished: (_) {
          _inject();
          _beginWarmup();
        },
        onProgress: (p) {
          if (mounted && !_warmupStarted) {
            setState(() => _status = '加载中 $p%');
          }
        },
      ));
    _controller = controller;
    setState(() {});
    try {
      await controller.loadRequest(Uri.parse(url));
    } catch (e) {
      if (mounted) setState(() => _status = '加载失败: $e');
    }

    // 全程持续注入（早期请求也不放过），但**计时从预热结束才开始**。
    _tick = Timer.periodic(const Duration(milliseconds: 800), (_) {
      _inject();
      if (mounted) _refreshStatus();
    });

    // 页面迟迟不结束加载 → 到点也进入预热，别一直卡着。
    _loadWatchdog = Timer(_loadWatchdogTimeout, _beginWarmup);
  }

  /// 页面加载完成（或兜底超时）后先等 [_warmup]，再开始正式嗅探计时。
  void _beginWarmup() {
    if (!_running || _warmupStarted) return;
    _warmupStarted = true;
    _loadWatchdog?.cancel();
    _loadWatchdog = null;
    if (mounted) {
      setState(() => _status = '页面已加载，等待线路/播放器就绪…');
    }
    _warmupTimer?.cancel();
    _warmupTimer = Timer(_warmup, _beginSniff);
  }

  void _beginSniff() {
    if (!_running || _sniffStarted) return;
    _sniffStarted = true;
    _sniffStart = DateTime.now();
    _deadline?.cancel();
    _deadline = Timer(_budget, () {
      _stopSniff('时间到（已抓 ${_collector.count} 条）');
    });
    if (mounted) setState(() => _status = '嗅探中…');
  }

  void _refreshStatus() {
    if (!_running) return;
    if (_sniffStarted && _sniffStart != null) {
      final left =
          _budget.inSeconds - DateTime.now().difference(_sniffStart!).inSeconds;
      final s = left < 0 ? 0 : left;
      setState(() => _status = '嗅探中… 剩余 ${s}s · 已抓 ${_collector.count} 条');
    } else if (_warmupStarted) {
      setState(() => _status = '等待线路就绪… 已抓 ${_collector.count} 条');
    } else {
      setState(() {});
    }
  }

  Future<void> _inject() async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.runJavaScript(kSnifferHookJs);
    } catch (_) {}
  }

  void _onJs(String raw) {
    try {
      final m = jsonDecode(raw);
      if (m is Map) {
        final ok = _collector.add(
          (m['url'] ?? '').toString(),
          kind: (m['kind'] ?? '').toString(),
          via: (m['via'] ?? '').toString(),
        );
        if (ok && mounted) setState(() {});
      }
    } catch (_) {}
  }

  void _stopSniff([String? msg]) {
    _cancelTimers();
    if (!mounted) return;
    setState(() {
      _running = false;
      _status = msg ?? '已停止（已抓 ${_collector.count} 条）';
    });
  }

  void _copy(String s) {
    Clipboard.setData(ClipboardData(text: s));
    AppToast.show('已复制', '');
  }

  @override
  Widget build(BuildContext context) {
    final best = _collector.best;
    return Scaffold(
      backgroundColor: AppTheme.backgroundSecondary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundSecondary,
        elevation: 0,
        title: const Text('解析 / 嗅探测试'),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _urlCtrl,
                      style:
                          TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                      decoration: InputDecoration(
                        labelText: '播放页 / 解析接口地址',
                        hintText: 'https://…',
                        isDense: true,
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: _parseRunning ? null : _testParse,
                          icon: const Icon(Icons.link_rounded, size: 18),
                          label: const Text('解析测试'),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: _running ? null : _startSniff,
                          icon: const Icon(Icons.travel_explore_rounded,
                              size: 18),
                          label: const Text('嗅探测试'),
                        ),
                        OutlinedButton(
                          onPressed: _running ? () => _stopSniff() : null,
                          child: const Text('停止'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        if (_running)
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        if (_running) const SizedBox(width: 8),
                        Expanded(
                          child: Text(_status,
                              style: TextStyle(
                                  color: AppTheme.textSecondary, fontSize: 12)),
                        ),
                        if (_running)
                          Text('已抓 ${_collector.count}',
                              style: TextStyle(
                                  color: AppTheme.textTertiary, fontSize: 12)),
                      ],
                    ),
                    if (_routeMode != null) ...[
                      const SizedBox(height: 4),
                      Text(_routeMode!,
                          style: TextStyle(
                              color: AppTheme.accentColor, fontSize: 11)),
                    ],
                    const SizedBox(height: 2),
                    Text(
                      '「解析测试」= 完整链路（抓页面 → 线路 → 嗅探兜底），'
                      '跟真实播放一致；「嗅探测试」= 只看嗅探抓到什么。'
                      '嗅探会在页面加载后等 ${_warmup.inSeconds}s 再计时。',
                      style: TextStyle(
                          color: AppTheme.textTertiary, fontSize: 11),
                    ),
                  ],
                ),
              ),
              // ── 解析测试结果 ──
              if (_parseStatus.isNotEmpty)
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: (_parseResult != null
                            ? AppTheme.accentColor
                            : AppTheme.textTertiary)
                        .withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      if (_parseRunning)
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        Icon(
                          _parseResult != null
                              ? Icons.check_circle_rounded
                              : Icons.info_outline_rounded,
                          size: 18,
                          color: _parseResult != null
                              ? AppTheme.accentColor
                              : AppTheme.textTertiary,
                        ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('解析测试 · $_parseStatus',
                                style: TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600)),
                            if (_parseResult != null) ...[
                              const SizedBox(height: 3),
                              Text(_parseResult!,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 12)),
                            ],
                          ],
                        ),
                      ),
                      if (_parseResult != null)
                        IconButton(
                          onPressed: () => _copy(_parseResult!),
                          icon: const Icon(Icons.copy_rounded, size: 18),
                          tooltip: '复制解析结果',
                        ),
                    ],
                  ),
                ),
              // ── 嗅探首选 ──
              if (best != null)
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.accentColor.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_rounded,
                          size: 18, color: AppTheme.accentColor),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(best.url,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: AppTheme.textPrimary, fontSize: 12)),
                      ),
                      IconButton(
                        onPressed: () => _copy(best.url),
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        tooltip: '复制首选地址',
                      ),
                    ],
                  ),
                ),
              Expanded(
                child: _collector.count == 0
                    ? Center(
                        child: Text('嗅探结果为空（点「嗅探测试」开始）',
                            style: TextStyle(color: AppTheme.textTertiary)),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        itemCount: _collector.sorted.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (c, i) {
                          final it = _collector.sorted[i];
                          final isBest = identical(it, best);
                          return Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: AppTheme.backgroundTertiary,
                              borderRadius: BorderRadius.circular(10),
                              border: isBest
                                  ? Border.all(
                                      color: AppTheme.accentColor, width: 0.8)
                                  : null,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: AppTheme.accentColor
                                        .withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(it.kind.isEmpty ? '?' : it.kind,
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: AppTheme.accentColor)),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(it.url,
                                          style: TextStyle(
                                              color: AppTheme.textPrimary,
                                              fontSize: 12)),
                                      const SizedBox(height: 3),
                                      Text(
                                          '${it.via} · score ${it.score}${it.isMedia ? " · 直链" : ""}',
                                          style: TextStyle(
                                              color: AppTheme.textTertiary,
                                              fontSize: 11)),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  onPressed: () => _copy(it.url),
                                  icon: const Icon(Icons.copy_rounded,
                                      size: 16),
                                  tooltip: '复制',
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
          // 离屏 WebView：8×8、几乎透明、不可点 —— 只负责把页面跑起来。
          if (_controller != null)
            Positioned(
              right: 0,
              bottom: 0,
              width: 8,
              height: 8,
              child: IgnorePointer(
                child: Opacity(
                  opacity: 0.01,
                  child: WebViewWidget(controller: _controller!),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
