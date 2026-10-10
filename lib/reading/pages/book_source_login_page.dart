import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/book_source.dart';
import '../novel_source/analyze/analyze_rule.dart';
import '../novel_source/analyze/js_engine.dart';
import '../novel_source/analyze/source_variable_store.dart';
import '../services/book_source_service.dart';
import '../theme/jelly_theme.dart';
import '../../common/theme.dart';

/// 书源登录（截图 IMG_8113）。
///
/// ── 与旧版的区别 ──────────────────────────────────────────────
/// 旧版是两个 tab（Cookie 直填 / 表单登录）。截图的形态是**单页**：
///
///   ⚡📂猫眼看书登录                                    ✕
///   ┌──────────────────────────────────────┐ ┌──┐
///   │ 网页登录后在此回显采集到的 Cookie      │ │📋│
///   └──────────────────────────────────────┘ └──┘
///   ┌───────────────────────────────────────────┐
///   │ Cookie、书源变量与登录请求会按此书源保存。 │
///   └───────────────────────────────────────────┘
///
///   清除登录态                      [ 网页登录 ]
///
/// 关键差别：**Cookie 框是"回显"用的**（从网页登录自动采集），
/// 不是让用户手填。表单登录那条路径被"网页登录"取代了 ——
/// 网页登录更通用（不依赖站点登录接口长什么样）。
///
/// 「清除登录态」= 把 Cookie 从 header 里摘掉（[applyCookie] 传空串）。
class BookSourceLoginPage extends StatefulWidget {
  const BookSourceLoginPage({super.key, required this.source});

  final BookSource source;

  @override
  State<BookSourceLoginPage> createState() => _BookSourceLoginPageState();
}

class _BookSourceLoginPageState extends State<BookSourceLoginPage> {
  final _ctrl = TextEditingController();
  final _svc = BookSourceService.instance;
  String _status = '';

  // ── JS 表单登录（legado loginUrl=<js> + loginUi 模式）──────────
  // 聚合源（如"光遇聚合"）的 loginUrl 不是网页而是 JS：用户按 loginUi
  // 填表单 → 提交时执行 JS → JS 里 source.putLoginInfo(header JSON)。
  // 这类源走"网页采 Cookie"没有意义（伪 URL 也打不开）。
  bool _isJsLogin = false;
  String _loginJs = '';
  List<Map<String, String>> _formFields = const [];
  final Map<String, TextEditingController> _formCtrls = {};

  @override
  void initState() {
    super.initState();
    final c = _svc.currentCookie(widget.source);
    _ctrl.text = c;
    if (c.isNotEmpty) {
      _status = '已保存 Cookie（${c.length} 字符）';
    }
    _initLoginMode();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    for (final c in _formCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// loginUrl 里的 JS：`<js>...</js>` 或 `@js:...`；纯 URL/网页登录返回 null。
  String? _extractJs(String loginUrl) {
    final s = loginUrl.trim();
    if (s.startsWith('<js>')) {
      final end = s.indexOf('</js>');
      return end > 4 ? s.substring(4, end) : s.substring(4);
    }
    if (s.startsWith('@js:')) return s.substring(4);
    return null;
  }

  /// 检测登录模式：loginUrl 是 JS → 渲染 loginUi 表单。
  void _initLoginMode() {
    final js = _extractJs(_loginUrlOf(widget.source));
    if (js == null) return;
    _isJsLogin = true;
    _loginJs = js;
    final fields = <Map<String, String>>[];
    final raw = (widget.source.readPath('loginUi') ?? '').toString().trim();
    if (raw.isNotEmpty) {
      try {
        final arr = jsonDecode(raw);
        if (arr is List) {
          for (final e in arr) {
            if (e is! Map) continue;
            final name = '${e['name'] ?? ''}'.trim();
            final type = '${e['type'] ?? 'text'}'.trim().toLowerCase();
            // button/verify 等非输入项跳过；只渲染 text/password
            if (name.isEmpty || type == 'button' || type == 'verify') continue;
            fields.add({'name': name, 'type': type});
          }
        }
      } catch (_) {
        // loginUi 非法 → 走兜底字段
      }
    }
    // 兜底：没写 loginUi 的 JS 登录源，给一个通用输入位（值会整体传给 JS）
    if (fields.isEmpty) {
      fields.add({'name': '登录信息', 'type': 'text'});
    }
    _formFields = fields;
    for (final f in fields) {
      _formCtrls[f['name']!] = TextEditingController();
    }
  }

  /// 执行 loginUrl JS 完成登录：result=表单 JSON；JS 内部 source.putLoginInfo。
  void _jsLogin() {
    final srcUrl =
        (widget.source.readPath('bookSourceUrl') ?? '').toString().trim();
    if (srcUrl.isEmpty) {
      _toast('源标识为空，无法保存登录信息');
      return;
    }
    final form = <String, String>{};
    _formCtrls.forEach((k, c) => form[k] = c.text);
    final formJson = jsonEncode(form);
    // jsLib 先注入（同源重复注入在 setActiveSource 里自动跳过）
    final lib = (widget.source.readPath('jsLib') ?? '').toString();
    try {
      JsEngine.shared.setActiveSource(srcUrl, lib);
    } catch (_) {/* 注入失败不阻塞：部分 JS 登录不依赖 jsLib */}
    var saved = '';
    try {
      AnalyzeRule()
        ..bookSourceUrl = srcUrl
        ..evalJs(_loginJs, formJson);
      final probe = AnalyzeRule()..bookSourceUrl = srcUrl;
      saved = probe.evalJs('source.getLoginInfo()', '');
    } catch (_) {
      saved = '';
    }
    // 兜底：JS 没把登录信息存进去（依赖 jsLib 失败/逻辑异常）→
    // 直接落表单 JSON，保证普通"读表单值"型登录源可用。
    if (saved.isEmpty) {
      SourceVariableStore.instance.box(srcUrl)['__login__'] = formJson;
      saved = formJson;
    }
    setState(() => _status = '已登录（${saved.length} 字符）');
    _toast('登录信息已保存');
  }

  /// 保存 Cookie 到书源 header
  Future<void> _save(String cookie) async {
    final next = _svc.applyCookie(widget.source, cookie);
    await BookSourceStoreBridge.save(next);
    if (!mounted) return;
    setState(() {
      _ctrl.text = cookie.trim();
      _status = cookie.trim().isEmpty ? '已清除登录态' : '已保存';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_status), duration: const Duration(seconds: 1)),
    );
  }

  /// 「网页登录」→ 打开内嵌浏览器，登录后采集 Cookie
  Future<void> _webLogin() async {
    final url = _loginUrlOf(widget.source);
    // 纯 URL 才能打开浏览器；伪 URL 源（如"光遇聚合"）/ JS 登录源不适用
    if (url.isEmpty) {
      // 没有登录地址就退到站点首页 —— 多数站点的登录入口在首页
      final home = widget.source.url;
      if (home.isEmpty || !home.startsWith('http')) {
        _toast('这个书源没有可用的网页登录地址');
        return;
      }
      await _openWeb(home);
      return;
    }
    if (!url.startsWith('http')) {
      _toast('该源的 loginUrl 是 JS 脚本，请在上方表单完成登录');
      return;
    }
    await _openWeb(url);
  }

  /// 登录地址：Legado 书源的 `loginUrl`，没有就用源地址
  String _loginUrlOf(BookSource s) {
    final v = s.readPath('loginUrl');
    return (v ?? '').toString().trim();
  }

  Future<void> _openWeb(String url) async {
    final cookie = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => WebLoginPage(
          url: url,
          title: widget.source.name,
        ),
      ),
    );
    if (cookie == null || cookie.isEmpty) return;
    await _save(cookie);
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), duration: const Duration(seconds: 2)),
      );

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final card = isDark ? JellyTheme.cardDark : JellyTheme.cardLight;
    return Scaffold(
      backgroundColor:
          isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
      body: SafeArea(
        child: Column(
          children: [
            // ── 标题行 ────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '⚡📂${widget.source.name}登录',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: AppTheme.fontTitle3,
                          fontWeight: FontWeight.w700,
                          color: label),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close_rounded,
                        size: 22, color: label),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                children: [
                  // ── JS 表单登录区（loginUrl=<js> 的源才显示）──────
                  if (_isJsLogin) ...[
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: card,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('JS 登录表单',
                              style: TextStyle(
                                  fontSize: AppTheme.fontSubhead,
                                  fontWeight: FontWeight.w700,
                                  color: label)),
                          const SizedBox(height: 4),
                          Text('该源使用脚本登录：按提示填写后点底部「登录」，'
                              '登录信息会保存到书源（JS 内可读取）。',
                              style: TextStyle(
                                  fontSize: AppTheme.fontFootnote,
                                  height: 1.5,
                                  color: JellyTheme.textSecondary)),
                          const SizedBox(height: 10),
                          for (final f in _formFields) ...[
                            TextField(
                              controller: _formCtrls[f['name']],
                              obscureText: f['type'] == 'password',
                              style: TextStyle(
                                  fontSize: AppTheme.fontSubhead, color: label),
                              decoration: InputDecoration(
                                isDense: true,
                                hintText: f['name'],
                                hintStyle: TextStyle(
                                    fontSize: AppTheme.fontSubhead,
                                    color: JellyTheme.textSecondary),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide(
                                      color: JellyTheme.textSecondary
                                          .withValues(alpha: 0.25)),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide(
                                      color: JellyTheme.primary),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  // ── Cookie 回显框 + 复制 ────────────────────
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: card,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _ctrl,
                            maxLines: 3,
                            minLines: 1,
                            style: TextStyle(
                                fontSize: AppTheme.fontSubhead, height: 1.5, color: label),
                            decoration: InputDecoration(
                              isDense: true,
                              filled: false,
                              hintText: '网页登录后在此回显采集到的 Cookie',
                              hintStyle: TextStyle(
                                  fontSize: AppTheme.fontSubhead,
                                  color: JellyTheme.textSecondary),
                              border: InputBorder.none,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton(
                          tooltip: '复制',
                          onPressed: () async {
                            await Clipboard.setData(
                                ClipboardData(text: _ctrl.text));
                            _toast('已复制 Cookie');
                          },
                          icon: Icon(Icons.copy_rounded,
                              size: 19, color: JellyTheme.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  // ── 说明框 ──────────────────────────────────
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: card,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'Cookie、书源变量与登录请求会按此书源保存。',
                      style: TextStyle(
                          fontSize: AppTheme.fontSubhead,
                          height: 1.6,
                          color: JellyTheme.textSecondary),
                    ),
                  ),
                  if (_status.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(_status,
                        style: TextStyle(
                            fontSize: AppTheme.fontSubhead,
                            color: JellyTheme.textSecondary)),
                  ],
                ],
              ),
            ),
            // ── 底部：清除登录态 · 网页登录 ──────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => _save(''),
                    child: Text('清除登录态',
                        style: TextStyle(
                            fontSize: AppTheme.fontBody,
                            color: JellyTheme.textSecondary)),
                  ),
                  const Spacer(),
                  FilledButton(
                    // JS 登录源：主按钮是「登录」（执行 loginUrl JS）；
                    // 网页源：主按钮是「网页登录」（WebView 采 Cookie）
                    onPressed: _isJsLogin ? _jsLogin : _webLogin,
                    style: FilledButton.styleFrom(
                      backgroundColor:
                          isDark ? Colors.white : JellyTheme.primary,
                      foregroundColor:
                          isDark ? JellyTheme.backgroundDark : Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 40, vertical: 14),
                    ),
                    child: Text(_isJsLogin ? '登录' : '网页登录'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 网页登录页（截图 IMG_8114）。
///
///   ‹  ⚡📂猫眼看书 · 网页登录   ⟳            [ 完成 ]
///
/// 用户在页面里登录站点，点「完成」时把 WebView 里的 Cookie 取出来
/// 返回给上一页。
class WebLoginPage extends StatefulWidget {
  const WebLoginPage({super.key, required this.url, required this.title});

  final String url;
  final String title;

  @override
  State<WebLoginPage> createState() => _WebLoginPageState();
}

class _WebLoginPageState extends State<WebLoginPage> {
  late final WebViewController _c;
  bool _loading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
          'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 '
          'Safari/604.1')
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() {
          _loading = true;
          _hasError = false;
        }),
        onPageFinished: (_) => setState(() => _loading = false),
        onWebResourceError: (e) {
          // 主框架错误才算失败；子资源（图片/广告）失败不提示
          if (e.isForMainFrame ?? false) {
            setState(() {
              _loading = false;
              _hasError = true;
            });
          }
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  /// 点「完成」：把 Cookie 取出来
  Future<void> _done() async {
    String cookie = '';
    try {
      // WebView 的 document.cookie 只有**当前域**的 Cookie。
      // 跨子域（如 passport.xxx.com 登录后回 www.xxx.com）拿不全 ——
      // 这是 WebView 的固有限制，不是这里能绕的。
      final v = await _c.runJavaScriptReturningResult('document.cookie');
      cookie = v.toString().replaceAll('"', '').trim();
    } catch (_) {
      cookie = '';
    }
    if (!mounted) return;
    if (cookie.isEmpty) {
      // 拿不到就如实说，不假装登录成功
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('没读到 Cookie。可能还没登录，或 Cookie 在其它子域下。'),
        duration: Duration(seconds: 3),
      ));
      return;
    }
    Navigator.pop(context, cookie);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Scaffold(
      backgroundColor:
          isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
      appBar: AppBar(
        centerTitle: true,
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: Icon(Icons.arrow_back_rounded, color: label),
        ),
        title: Text(
          '⚡📂${widget.title} · 网页登录',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: AppTheme.fontHeadline, fontWeight: FontWeight.w600, color: label),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: () => _c.reload(),
            icon: Icon(Icons.refresh_rounded, size: 22, color: label),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: _done,
              style: FilledButton.styleFrom(
                backgroundColor:
                    isDark ? Colors.white : JellyTheme.primary,
                foregroundColor:
                    isDark ? JellyTheme.backgroundDark : Colors.white,
              ),
              child: const Text('完成'),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _c),
          if (_loading)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (_hasError)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.wifi_off_rounded,
                      size: 40, color: label.withValues(alpha: 0.4)),
                  const SizedBox(height: 12),
                  Text('网页打不开',
                      style: TextStyle(fontSize: AppTheme.fontBody, color: label)),
                  const SizedBox(height: 6),
                  Text('可能是源地址不通，或站点需要代理',
                      style: TextStyle(
                          fontSize: AppTheme.fontFootnote, color: JellyTheme.textSecondary)),
                  const SizedBox(height: 14),
                  TextButton(
                    onPressed: () => _c.reload(),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 把改好的书源存回去。
///
/// 单独包一层是为了不把 `BookSourceStore` 直接散在各页面里 ——
/// 存书源的入口只有这里和编辑页，收口好排查。
class BookSourceStoreBridge {
  const BookSourceStoreBridge._();

  /// 用 updatePaths 逐字段写回整个 raw。
  ///
  /// ⚠️ 不能直接调 `updatePaths(id, s.raw)` —— 那个方法的语义是
  /// "按点分路径改若干字段"，传一个含嵌套 Map 的 raw 进去，
  /// 嵌套的 ruleSearch 等会被当成**单个值**覆盖（值类型对不上）。
  /// 所以这里展平成点分路径再写。
  static Future<void> save(BookSource s) async {
    final flat = <String, dynamic>{};
    void walk(String prefix, Map<dynamic, dynamic> m) {
      m.forEach((k, v) {
        final key = prefix.isEmpty ? '$k' : '$prefix.$k';
        if (v is Map) {
          walk(key, v);
        } else {
          flat[key] = v;
        }
      });
    }

    walk('', s.raw);
    await BookSourceStore.instance.updatePaths(s.id, flat);
  }
}
