import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/book_source.dart';
import '../services/book_source_service.dart';
import '../theme/jelly_theme.dart';

/// 书源登录页（cmbok V2.0.7 的「书源登录」）。
///
/// ── 为什么需要登录 ────────────────────────────────────────────
/// 不少小说站把正文藏起来，未登录只能看到"请登录后阅读"。
/// 登录成功后我们拿到 Cookie，写进书源的 `header`，引擎发请求时会自动带上。
///
/// ── 为什么提供两种方式 ────────────────────────────────────────
///   · **Cookie 直填**：最通用。用户在系统浏览器里登录该站，
///     复制 Cookie 粘进来即可。不依赖站点的登录接口长什么样。
///   · **表单登录**：POST 账号密码到登录接口，自动收 Set-Cookie。
///     省事，但每个站的登录地址/字段名都不同，需要用户自己填。
///
/// 默认给出 Cookie 直填 —— 它对用户更"一定能成"，
/// 而表单登录更像"给愿意折腾的人用的快捷方式"。
class BookSourceLoginPage extends StatefulWidget {
  const BookSourceLoginPage({super.key, required this.source});

  final BookSource source;

  @override
  State<BookSourceLoginPage> createState() => _BookSourceLoginPageState();
}

class _BookSourceLoginPageState extends State<BookSourceLoginPage> {
  final store = BookSourceStore.instance;
  final svc = BookSourceService.instance;

  final _cookieCtrl = TextEditingController();
  final _loginUrlCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _userFieldCtrl = TextEditingController(text: 'username');
  final _passFieldCtrl = TextEditingController(text: 'password');

  int _tab = 0; // 0 = Cookie 直填，1 = 表单登录
  bool _busy = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    // 回填已登录的 Cookie，方便用户核对/替换
    _cookieCtrl.text = svc.currentCookie(widget.source);
    if (_cookieCtrl.text.isNotEmpty) {
      _status = '当前已保存 Cookie（${_cookieCtrl.text.length} 字符）';
    }
  }

  @override
  void dispose() {
    _cookieCtrl.dispose();
    _loginUrlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _userFieldCtrl.dispose();
    _passFieldCtrl.dispose();
    super.dispose();
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _card => _isDark ? JellyTheme.cardDark : JellyTheme.cardLight;
  Color get _titleColor =>
      _isDark ? Colors.white : JellyTheme.textPrimaryLight;

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(m),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
  }

  /// 把 Cookie 保存到书源
  Future<void> _saveCookie(String cookie) async {
    final updated = svc.applyCookie(widget.source, cookie);
    final r = await store.addAll([updated]);
    if (!mounted) return;
    _toast(r.updated > 0 ? '已保存登录状态' : '已保存');
    Navigator.pop(context, true);
  }

  Future<void> _doFormLogin() async {
    final url = _loginUrlCtrl.text.trim();
    if (url.isEmpty) {
      _toast('请填登录接口地址');
      return;
    }
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text;
    if (user.isEmpty || pass.isEmpty) {
      _toast('请填账号和密码');
      return;
    }
    setState(() {
      _busy = true;
      _status = '正在登录...';
    });
    final uf = _userFieldCtrl.text.trim();
    final pf = _passFieldCtrl.text.trim();
    final r = await svc.loginWithForm(
      url: url,
      fields: {
        (uf.isEmpty ? 'username' : uf): user,
        (pf.isEmpty ? 'password' : pf): pass,
      },
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = r.ok ? '登录成功，已获取 Cookie' : (r.error ?? '登录失败');
    });
    if (r.ok && r.cookie != null && r.cookie!.isNotEmpty) {
      _cookieCtrl.text = r.cookie!;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
          _isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
      appBar: AppBar(
        title: Text('书源登录',
            style: TextStyle(fontSize: 18, color: _titleColor)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          // 是哪个源在登录 —— 别让用户在多个源之间搞混
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(Icons.menu_book_rounded,
                    size: 20, color: JellyTheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.source.name,
                          style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                              color: _titleColor)),
                      Text(widget.source.url,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11.5,
                              color: JellyTheme.textSecondary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _tabBar(),
          const SizedBox(height: 14),
          if (_tab == 0) ..._cookieTab() else ..._formTab(),
          if (_status.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: JellyTheme.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded,
                      size: 16, color: JellyTheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_status,
                        style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: _titleColor)),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _tabBar() {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _tabBtn(0, 'Cookie 直填', Icons.cookie_rounded),
          _tabBtn(1, '表单登录', Icons.login_rounded),
        ],
      ),
    );
  }

  Widget _tabBtn(int i, String label, IconData icon) {
    final on = _tab == i;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _tab = i),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: on
                ? (_isDark ? Colors.white.withValues(alpha: 0.1) : Colors.white)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 16,
                  color: on ? JellyTheme.primary : JellyTheme.textSecondary),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: on ? FontWeight.w600 : FontWeight.normal,
                    color: on ? _titleColor : JellyTheme.textSecondary,
                  )),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _cookieTab() => [
        Text(
          '在系统浏览器里登录这个网站，然后复制 Cookie 粘到下面。\n'
          '这是最通用的方式：不依赖站点登录接口的具体形态。',
          style: TextStyle(
              fontSize: 12, height: 1.6, color: JellyTheme.textSecondary),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _cookieCtrl,
          maxLines: 6,
          minLines: 4,
          style: const TextStyle(fontSize: 12.5, height: 1.4),
          decoration: InputDecoration(
            hintText: '粘贴 Cookie，形如：\n'
                'PHPSESSID=abc123; token=xyz789',
            hintStyle:
                TextStyle(fontSize: 12.5, color: JellyTheme.textSecondary),
            filled: true,
            fillColor: _card,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            TextButton.icon(
              onPressed: () async {
                final d = await Clipboard.getData('text/plain');
                final t = d?.text;
                if (t != null && t.isNotEmpty) {
                  _cookieCtrl.text = t;
                  setState(() => _status = '已从剪贴板读取 ${t.length} 字符');
                }
              },
              icon: const Icon(Icons.content_paste_rounded, size: 16),
              label: const Text('读剪贴板'),
            ),
            const Spacer(),
            if (_cookieCtrl.text.isNotEmpty)
              TextButton(
                onPressed: () => _saveCookie(''),
                child: const Text('退出登录',
                    style: TextStyle(color: Colors.redAccent)),
              ),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _busy
                ? null
                : () {
                    final c = _cookieCtrl.text.trim();
                    if (c.isEmpty) {
                      _toast('请先粘贴 Cookie');
                      return;
                    }
                    _saveCookie(c);
                  },
            child: const Text('保存登录状态'),
          ),
        ),
      ];

  List<Widget> _formTab() => [
        Text(
          '填站点的登录接口与字段名，自动获取 Cookie。\n'
          '注意：每个站的登录地址和字段名都不同，需要自己确认。',
          style: TextStyle(
              fontSize: 12, height: 1.6, color: JellyTheme.textSecondary),
        ),
        const SizedBox(height: 12),
        _field('登录接口地址', _loginUrlCtrl, 'https://site.com/user/login',
            keyboard: TextInputType.url),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(child: _field('账号字段名', _userFieldCtrl, 'username')),
            const SizedBox(width: 10),
            Expanded(child: _field('密码字段名', _passFieldCtrl, 'password')),
          ],
        ),
        const SizedBox(height: 10),
        _field('账号', _userCtrl, ''),
        const SizedBox(height: 10),
        _field('密码', _passCtrl, '', obscure: true),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _busy ? null : _doFormLogin,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.login_rounded, size: 18),
            label: const Text('登录并获取 Cookie'),
          ),
        ),
        if (_cookieCtrl.text.isNotEmpty) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => _saveCookie(_cookieCtrl.text.trim()),
              child: const Text('保存已获取的 Cookie'),
            ),
          ),
        ],
      ];

  Widget _field(
    String label,
    TextEditingController ctrl,
    String hint, {
    TextInputType? keyboard,
    bool obscure = false,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 12, color: JellyTheme.textSecondary)),
          const SizedBox(height: 4),
          TextField(
            controller: ctrl,
            keyboardType: keyboard,
            obscureText: obscure,
            style: const TextStyle(fontSize: 13.5),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint.isEmpty ? null : hint,
              hintStyle:
                  TextStyle(fontSize: 13, color: JellyTheme.textSecondary),
              filled: true,
              fillColor: _card,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            ),
          ),
        ],
      );
}
