// Z-Library 网页登录页：在应用内 WebView 里登录官网，然后把**会话回灌**给
// `ZlibraryService`（eapi 请求随后带着该会话走）。
//
// ── 为什么需要它（依据）──────────────────────────────────────────
// 1. 你现有的 `zlibrary_auth_page.dart` 是**邮箱密码表单**，走
//    `POST /eapi/user/login`。这条路径要求 eapi 可直连、且账号密码给 App——
//    实测不少网络环境下 eapi 会被 Cloudflare/地区策略挡住（403/挑战页），
//    于是"登录不了 ⇒ 整个图书功能不可用"。
//
// 2. `icodebase-cn/aiset-zlibrary`（MIT）的做法是**浏览器登录一次、复用会话**
//    （Playwright 持久化上下文 + `storage_state.json`）；本页把同一思路搬进 App：
//    WebView 里登录一次 → 取出会话 Cookie → 交给 Dart 侧的 Dio。
//
// 3. 官方 eapi 文档（`baroxyton/zlibrary-eapi-documentation`）明确写着：
//    > In some cases, it may also be necessary to provide the login as the
//    > cookies `remix_userid` and `remix_userkey`
//    ⇒ 只要拿到这两个 Cookie，**无需邮箱密码**即可让所有 eapi 请求变成已登录态。
//
// ── 实现取舍（如实标注）─────────────────────────────────────────
// · 会话从 `document.cookie` 读取。**HttpOnly 的 Cookie 读不到** —— 若
//   `remix_userid`/`remix_userkey` 恰好是 HttpOnly，本页会提示改用账号登录。
//   （`webview_flutter` 的原生 `WebViewCookieManager.getCookies` 能读 HttpOnly，
//    但各平台实现参差；这里先用跨平台一致的方式，失败再让用户走表单。）
// · 不做自动填表：z-library 登录页有验证码/人机校验，自动填容易触发风控。
//   本页只提供"登录 → 取会话"的手动流程（与 aiset-zlibrary 的"手动登录后回车"一致）。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:tvbox/reading/services/zlibrary_service.dart';

class ZlibraryWebLoginPage extends StatefulWidget {
  const ZlibraryWebLoginPage({super.key, required this.domain});

  /// 不带 scheme 的域名（如 `zh.zlib.li`）；内部补 `https://`
  final String domain;

  @override
  State<ZlibraryWebLoginPage> createState() => _ZlibraryWebLoginPageState();
}

class _ZlibraryWebLoginPageState extends State<ZlibraryWebLoginPage> {
  late final WebViewController _controller;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  String get _base => widget.domain.startsWith('http')
      ? widget.domain
      : 'https://${widget.domain}';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() => _loading = true),
          onPageFinished: (_) => setState(() => _loading = false),
          onWebResourceError: (e) {
            if (mounted) setState(() => _error = '${e.description}');
          },
        ),
      )
      ..loadRequest(Uri.parse('$_base/'));
  }

  /// 读取 `document.cookie` 并把会话回灌给 ZlibraryService。
  Future<void> _captureSession() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final raw = await _controller.runJavaScriptReturningResult('document.cookie');
      var cookie = raw.toString();
      // iOS 会把结果包成 JSON 字符串（带引号），去掉外层引号
      if (cookie.length >= 2 && cookie.startsWith('"') && cookie.endsWith('"')) {
        try {
          cookie = jsonDecode(cookie) as String;
        } catch (_) {/* 保持原样 */}
      }
      debugPrint('[Zlibrary网页登录] document.cookie 长度=${cookie.length}');
      final ok = await ZlibraryService().applyWebSession(cookie);
      if (!mounted) return;
      if (ok) {
        Navigator.of(context).pop(true);
        return;
      }
      setState(() {
        _error = cookie.isEmpty
            ? '未读到任何 Cookie：可能尚未登录成功'
            : '读到了 Cookie，但里面没有 remix_userid / remix_userkey。\n'
                '这两个字段可能是 HttpOnly（JS 读不到）⇒ 请改用邮箱密码登录，'
                '或在浏览器里确认站点把登录态放在哪。';
      });
    } catch (e) {
      if (mounted) setState(() => _error = '读取会话失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('网页登录（${widget.domain}）'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _captureSession,
            child: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('我已登录'),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Text(
              '在下面的网页里正常登录 Z-Library；登录成功后点右上角「我已登录」，'
              'App 会取出该会话用于图书搜索/推荐/下载（不需要把密码交给 App）。',
              style: TextStyle(fontSize: 12),
            ),
          ),
          if (_error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              color: Theme.of(context).colorScheme.errorContainer,
              child: Text(_error!, style: const TextStyle(fontSize: 12)),
            ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
