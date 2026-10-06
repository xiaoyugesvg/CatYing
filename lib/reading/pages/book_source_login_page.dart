// 书源登录页 —— 对齐备份3.0 book_source_login_page（参考图 IMG_8113 / IMG_8114）。
//
// 单页形态：Cookie 回显框（网页登录自动采集）+ 说明 + 清除登录态 / 网页登录。
// 「清除登录态」= 把 Cookie 从 header 里摘掉；「网页登录」= 内嵌 WebView 登录后采集 Cookie。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../common/theme.dart';
import '../novel_source/model/book_source.dart';
import '../novel_source/shuyuan_source_service.dart';
import '../services/shuyuan_source_store.dart';
import '../theme/jelly_theme.dart';

class BookSourceLoginPage extends StatefulWidget {
  const BookSourceLoginPage({super.key, required this.source});

  final XiaoshuoBookSource source;

  @override
  State<BookSourceLoginPage> createState() => _BookSourceLoginPageState();
}

class _BookSourceLoginPageState extends State<BookSourceLoginPage> {
  final _ctrl = TextEditingController();
  String _status = '';

  /// 从书源 header（JSON 字符串）里读 Cookie。
  String _currentCookie() {
    try {
      final h = jsonDecode(widget.source.header ?? '{}');
      if (h is Map) {
        final c = h['Cookie'];
        if (c is String) return c;
      }
    } catch (_) {}
    return '';
  }

  @override
  void initState() {
    super.initState();
    final c = _currentCookie();
    _ctrl.text = c;
    if (c.isNotEmpty) {
      _status = '已保存 Cookie（${c.length} 字符）';
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 保存 Cookie 到书源 header 并写回 store（覆盖式 addSource）。
  Future<void> _save(String cookie) async {
    final trimmed = cookie.trim();
    final entry = ShuyuanSourceStore.instance.sourceByUrl(widget.source.bookSourceUrl);
    if (entry == null) {
      if (!mounted) return;
      _toast('书源不存在，可能已被删除');
      return;
    }
    // header 是 JSON 字符串：解析后设/删 Cookie 键。
    String? nextHeader;
    try {
      final h = jsonDecode(entry.header ?? '{}');
      if (h is Map) {
        if (trimmed.isEmpty) {
          h.remove('Cookie');
        } else {
          h['Cookie'] = trimmed;
        }
        nextHeader = jsonEncode(h);
      }
    } catch (_) {
      // header 不是合法 JSON：非空 Cookie 时降级为整体覆盖。
      nextHeader = trimmed.isEmpty ? null : jsonEncode({'Cookie': trimmed});
    }
    final updated = ShuyuanSource(
      bookSourceName: entry.bookSourceName,
      bookSourceUrl: entry.bookSourceUrl,
      bookSourceType: entry.bookSourceType,
      bookSourceGroup: entry.bookSourceGroup,
      bookSourceComment: entry.bookSourceComment,
      enabled: entry.enabled,
      searchUrl: entry.searchUrl,
      exploreUrl: entry.exploreUrl,
      header: nextHeader,
      tocUrl: entry.tocUrl,
      ruleSearch: entry.ruleSearch,
      ruleBookInfo: entry.ruleBookInfo,
      ruleToc: entry.ruleToc,
      ruleContent: entry.ruleContent,
      ruleExplore: entry.ruleExplore,
      filters: entry.filters,
      homeSections: entry.homeSections,
    );
    await ShuyuanSourceStore.instance.addSource(updated);
    if (!mounted) return;
    setState(() {
      _ctrl.text = trimmed;
      _status = trimmed.isEmpty ? '已清除登录态' : '已保存';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_status), duration: const Duration(seconds: 1)),
    );
  }

  /// 「网页登录」→ 打开内嵌浏览器，登录后采集 Cookie。
  Future<void> _webLogin() async {
    final loginUrl = widget.source.loginUrl?.trim() ?? '';
    final home = widget.source.bookSourceUrl.trim();
    if (loginUrl.isEmpty) {
      // 没有登录地址就退到站点首页 —— 多数站点的登录入口在首页
      if (home.isEmpty) {
        _toast('这个书源没有填写源地址，无法网页登录');
        return;
      }
      await _openWeb(home);
      return;
    }
    await _openWeb(loginUrl);
  }

  Future<void> _openWeb(String url) async {
    final cookie = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => WebLoginPage(
          url: url,
          title: widget.source.bookSourceName,
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
                      '⚡📂${widget.source.bookSourceName}登录',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.w600,
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
                                fontSize: AppTheme.fontSubhead,
                                height: 1.5,
                                color: label),
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
                    onPressed: _webLogin,
                    style: FilledButton.styleFrom(
                      backgroundColor:
                          isDark ? Colors.white : JellyTheme.primary,
                      foregroundColor:
                          isDark ? JellyTheme.backgroundDark : Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 40, vertical: 14),
                    ),
                    child: const Text('网页登录'),
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

/// 网页登录页（参考图 IMG_8114）。
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

  /// 点「完成」：把 Cookie 取出来。
  Future<void> _done() async {
    String cookie = '';
    try {
      // WebView 的 document.cookie 只有**当前域**的 Cookie。
      // 跨子域（如 passport.xxx.com 登录后回 www.xxx.com）拿不全 ——
      // 这是 WebView 的固有限制。
      final v = await _c.runJavaScriptReturningResult('document.cookie');
      cookie = v.toString().replaceAll('"', '').trim();
    } catch (_) {
      cookie = '';
    }
    if (!mounted) return;
    if (cookie.isEmpty) {
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
        backgroundColor:
            isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
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
              fontSize: AppTheme.fontHeadline,
              fontWeight: FontWeight.w600,
              color: label),
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
                      style:
                          TextStyle(fontSize: AppTheme.fontBody, color: label)),
                  const SizedBox(height: 6),
                  Text('可能是源地址不通，或站点需要代理',
                      style: TextStyle(
                          fontSize: AppTheme.fontFootnote,
                          color: JellyTheme.textSecondary)),
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
