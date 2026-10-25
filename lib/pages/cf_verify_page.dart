import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/app_log.dart';
import '../services/cf_session.dart';

/// 「点一次，以后不用再点」的 Cloudflare 人机验证页。
///
/// 工作方式：
///   1. 用**统一 UA** 打开站点首页，页面会显示 CF 的"验证你是人类"；
///   2. 用户自己点一下（这是用户本人在访问，不是程序代过）；
///   3. 轮询检测到 `cf_clearance` 出现即自动保存并返回；
///   4. 之后所有模块（py 源 / 网页 / 图片）都复用这份 cookie，**不再弹窗**。
///
/// 返回值：true = 验证成功并已落盘；null/false = 用户取消。
class CfVerifyPage extends StatefulWidget {
  const CfVerifyPage({
    super.key,
    required this.url,
    required this.host,
    this.ua,
  });

  /// 要打开的地址（一般是站点首页，不是接口地址）
  final String url;

  /// 规范化 host（缓存键）
  final String host;

  /// 统一 UA（必须与爬虫一致，否则 cf_clearance 不生效）
  final String? ua;

  @override
  State<CfVerifyPage> createState() => _CfVerifyPageState();
}

class _CfVerifyPageState extends State<CfVerifyPage> {
  late final WebViewController _c;
  final WebViewCookieManager _cookies = WebViewCookieManager();
  Timer? _poll;
  bool _saving = false;
  String _hint = '请在下方页面完成验证，成功后会自动返回';

  @override
  void initState() {
    super.initState();
    _c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF141414));
    final ua = widget.ua ?? CfSession.defaultUa;
    // UA 必须与后续爬虫请求一致（cf_clearance 绑定 UA）
    _c.setUserAgent(ua);
    _c.setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (_) => _checkOnce(),
        onWebResourceError: (e) {
          AppLog.instance.log('[CfVerify] 资源错误: ${e.description}');
        },
      ),
    );
    _c.loadRequest(Uri.parse(widget.url));
    // CF 通过后会 set-cookie，轮询比"判断页面标题"更可靠
    _poll = Timer.periodic(const Duration(milliseconds: 1500), (_) => _checkOnce());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<Map<String, String>> _readCookies() async {
    final out = <String, String>{};
    try {
      final list = await _cookies.getCookies(domain: Uri.parse(widget.url));
      for (final c in list) {
        out[c.name] = c.value;
      }
    } catch (e) {
      AppLog.instance.log('[CfVerify] 取 cookie 失败: $e');
    }
    return out;
  }

  /// 检测到 cf_clearance 即视为通过，自动保存并返回
  Future<void> _checkOnce() async {
    if (_saving) return;
    final m = await _readCookies();
    if (!m.containsKey('cf_clearance')) {
      if (mounted && _hint.startsWith('请在下方')) return;
      return;
    }
    await _finish(m, auto: true);
  }

  Future<void> _finish(Map<String, String> cookies, {bool auto = false}) async {
    if (_saving) return;
    if (cookies.isEmpty) {
      setState(() => _hint = '还没有拿到 cookie，请先在页面里完成验证');
      return;
    }
    _saving = true;
    setState(() => _hint = auto ? '验证通过，正在保存…' : '正在保存…');
    await CfSession.instance.save(
      widget.host,
      cookies,
      ua: widget.ua ?? CfSession.defaultUa,
    );
    _poll?.cancel();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已记住 ${widget.host}，以后不用再验证'),
        duration: const Duration(seconds: 2),
      ),
    );
    Navigator.of(context).pop(true);
  }

  /// 用户手动点「完成」：把当前所有 cookie 都存下来（兼容非 cf_clearance 的挑战）
  Future<void> _manualFinish() async {
    final m = await _readCookies();
    if (m.isEmpty) {
      setState(() => _hint = '还没拿到 cookie，请先在页面里完成验证');
      return;
    }
    await _finish(m);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF141414),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B1B1F),
        elevation: 0,
        foregroundColor: Colors.white,
        title: Text(
          '验证 · ${widget.host}',
          style: const TextStyle(fontSize: 15),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : _manualFinish,
            child: const Text('完成', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: const Color(0xFF23232A),
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
            child: Text(
              _hint,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.72),
              ),
            ),
          ),
          Expanded(child: WebViewWidget(controller: _c)),
        ],
      ),
    );
  }
}

/// 需要验证时统一从这里弹（**已有缓存则直接返回 true，不弹**）
Future<bool> ensureCfSession(
  BuildContext context, {
  required String url,
  String? ua,
}) async {
  final host = CfSession.hostOf(url);
  if (host.isEmpty) return false;
  if (await CfSession.instance.has(host)) return true;
  if (!context.mounted) return false;
  final ok = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => CfVerifyPage(
        url: url,
        host: host,
        ua: ua,
      ),
    ),
  );
  return ok == true;
}
