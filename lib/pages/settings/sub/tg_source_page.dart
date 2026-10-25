import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/theme.dart';
import '../../../services/app_log.dart';
import '../../../services/tg_service.dart';
import '../../../widgets/app_toast.dart';
import '../../../widgets/common_widgets.dart';
import 'settings_shared.dart';
import 'tg_channel_page.dart';

/// 设置 → 订阅管理 → Telegram 源
///
/// 流程只有三步：
///   1. 填 api_id / api_hash（my.telegram.org 免费申请）
///   2. 手机 Telegram 扫码（不需要验证码）
///   3. 选频道 / 手填群 ID → 出片
///
/// 这里**不碰协议**：数据全由内置 Node 的 `/tg` 返回。
class TgSourcePage extends StatefulWidget {
  const TgSourcePage({super.key});

  @override
  State<TgSourcePage> createState() => _TgSourcePageState();
}

class _TgSourcePageState extends State<TgSourcePage> {
  final TgService _tg = TgService.instance;

  final _apiIdCtrl = TextEditingController();
  final _apiHashCtrl = TextEditingController();
  final _proxyHostCtrl = TextEditingController();
  final _proxyPortCtrl = TextEditingController();
  final _peerCtrl = TextEditingController();
  final _pubCtrl = TextEditingController();

  bool _booting = true;
  bool _busy = false;
  bool _showAdvanced = false;

  Map<String, dynamic> _st = {};
  Map<String, dynamic> _qr = {};
  List<Map<String, dynamic>> _dialogs = [];
  List<Map<String, dynamic>> _saved = [];

  Timer? _pollTimer;

  bool get _configured => _st['configured'] == true;
  bool get _authorized => _st['authorized'] == true;
  String get _phase => (_qr['phase'] ?? 'idle') as String;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _apiIdCtrl.dispose();
    _apiHashCtrl.dispose();
    _proxyHostCtrl.dispose();
    _proxyPortCtrl.dispose();
    _peerCtrl.dispose();
    _pubCtrl.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    await _tg.loadSettings();
    _apiIdCtrl.text = _tg.apiId;
    _apiHashCtrl.text = _tg.apiHash;
    _proxyHostCtrl.text = _tg.proxyHost;
    _proxyPortCtrl.text = _tg.proxyPort;
    await _tg.pushConfig();
    await _refreshStatus();
    final saved = await _tg.channels();
    if (mounted) {
      setState(() {
        _saved = saved;
        _booting = false;
      });
    }
    if (_authorized) _loadDialogs();
  }

  Future<void> _refreshStatus() async {
    final r = await _tg.status();
    if (!mounted) return;
    setState(() => _st = r);
  }

  /// 真握手（会走网络）：用来验证 api / 代理 / 会话是否真的可用
  Future<void> _ping() async {
    setState(() => _busy = true);
    final r = await _tg.ping();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _st = r;
    });
    if (r['ok'] != true) {
      AppToast.message(r['error']?.toString() ?? '连接失败');
    } else {
      AppToast.message(r['authorized'] == true ? '已登录' : '连接正常，请扫码登录');
    }
    if (r['authorized'] == true) _loadDialogs();
  }

  Future<void> _saveConfig() async {
    if (_apiIdCtrl.text.trim().isEmpty || _apiHashCtrl.text.trim().isEmpty) {
      AppToast.message('api_id 和 api_hash 都要填');
      return;
    }
    setState(() => _busy = true);
    await _tg.saveSettings(
      apiId: _apiIdCtrl.text,
      apiHash: _apiHashCtrl.text,
      proxyHost: _proxyHostCtrl.text,
      proxyPort: _proxyPortCtrl.text,
    );
    await _tg.pushConfig();
    await _refreshStatus();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _startQr() async {
    setState(() {
      _busy = true;
      _qr = {'phase': 'waiting'};
    });
    final r = await _tg.startQr();
    if (!mounted) return;
    setState(() {
      _qr = r;
      _busy = false;
    });
    if (r['ok'] == false) {
      AppToast.message(r['error']?.toString() ?? '二维码获取失败');
      return;
    }
    _startPolling();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 1500), (t) async {
      if (!mounted) return;
      final r = await _tg.pollQr();
      if (!mounted) return;
      setState(() => _qr = r);
      final phase = r['phase'];
      if (phase == 'done') {
        t.cancel();
        await _refreshStatus();
        _loadDialogs();
        AppToast.message('登录成功');
      } else if (phase == 'error') {
        t.cancel();
      }
    });
  }

  Future<void> _submitPassword(String pw) async {
    final r = await _tg.submitPassword(pw);
    if (r['ok'] != true) AppToast.message(r['error']?.toString() ?? '提交失败');
  }

  Future<void> _loadDialogs() async {
    final r = await _tg.dialogs();
    if (!mounted) return;
    final items = (r['items'] as List?) ?? const [];
    setState(() {
      _dialogs = items
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    });
    if (r['ok'] != true) AppLog.instance.log('[TG] dialogs: ${r['error']}');
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('退出 Telegram'),
        content: const Text('会删除本地会话，下次需要重新扫码。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('退出', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _tg.logout();
    _qr = {};
    setState(() => _dialogs = []);
    await _refreshStatus();
  }

  // ── UI ───────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: 'TG 设置',
      children: [
        _section('连接'),
        _statusCard(),
        if (!_configured) _configCard(),
        if (_configured && !_authorized) ...[
          _section('登录（可选）'),
          _loginCard(),
        ],
        if (_authorized) ...[
          _section('我的频道'),
          _manualCard(),
          _channelsCard(),
        ],
        _section('公开频道'),
        _savedCard(),
        _hintCard(),
      ],
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
        child: Text(t,
            style: TextStyle(color: AppTheme.textTertiary, fontSize: 11.5)),
      );

  Widget _card(Widget child) =>
      Padding(padding: const EdgeInsets.only(bottom: 10), child: child);

  Widget _statusCard() {
    final name = (_st['me'] as Map?)?['name']?.toString() ?? '';
    return _card(AppCard(
      dense: true,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(
              _authorized ? Icons.verified_user : Icons.telegram,
              color: _authorized ? Colors.green : AppTheme.textTertiary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _authorized ? (name.isEmpty ? '已登录' : name) : '未登录',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _booting
                        ? '正在读取…'
                        : (_st['connected'] == true
                            ? '已连接 Telegram'
                            : '未连接（需要代理时请填写）'),
                    style: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (_authorized)
              TextButton(onPressed: _logout, child: const Text('退出')),
            if (!_authorized)
              TextButton(
                onPressed: _busy ? null : _ping,
                child: Text(_busy ? '连接中…' : '测试连接'),
              ),
            IconButton(
              tooltip: '高级设置',
              onPressed: () => setState(() => _showAdvanced = !_showAdvanced),
              icon: Icon(Icons.settings_outlined,
                  color: AppTheme.textTertiary, size: 20),
            ),
          ],
        ),
      ),
    ));
  }

  Widget _configCard() {
    return _card(AppCard(
      dense: true,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('第 1 步：填写应用凭据',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              '打开 my.telegram.org → API development tools，'
              '创建一个应用，把 api_id 和 api_hash 填到下面（免费，只需一次）。',
              style: TextStyle(color: AppTheme.textTertiary, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 12),
            _field(_apiIdCtrl, 'api_id（纯数字）', keyboard: TextInputType.number),
            const SizedBox(height: 8),
            _field(_apiHashCtrl, 'api_hash（32 位）'),
            if (_showAdvanced) ...[
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: _field(_proxyHostCtrl, 'SOCKS5 地址（可空）')),
                const SizedBox(width: 8),
                SizedBox(width: 96, child: _field(_proxyPortCtrl, '端口', keyboard: TextInputType.number)),
              ]),
              const SizedBox(height: 6),
              Text('若是系统级 VPN，这里留空即可；只开了 HTTP/SOCKS 代理时才需要填。',
                  style: TextStyle(color: AppTheme.textTertiary, fontSize: 11)),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _busy ? null : _saveConfig,
                child: Text(_busy ? '保存中…' : '保存并测试'),
              ),
            ),
          ],
        ),
      ),
    ));
  }

  Widget _loginCard() {
    final png = TgService.decodeQr((_qr['png'] ?? '') as String);
    final needPw = _phase == 'need_password';
    final waiting = _phase == 'waiting';
    final error = (_qr['error'] ?? '') as String;

    return _card(AppCard(
      dense: true,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('第 2 步：手机扫码登录',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              '手机 Telegram → 设置 → 设备 → 链接桌面设备 → 扫下面的码。'
              '不需要验证码，也不需要用主号。',
              style: TextStyle(color: AppTheme.textTertiary, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 14),
            Center(
              child: png == null
                  ? FilledButton.icon(
                      onPressed: _busy ? null : _startQr,
                      icon: const Icon(Icons.qr_code_2),
                      label: Text(_busy ? '生成中…' : '生成二维码'),
                    )
                  : Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Image.memory(
                        Uint8List.fromList(png),
                        width: 220,
                        height: 220,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => const SizedBox(
                            width: 220,
                            height: 220,
                            child: Center(child: Text('二维码渲染失败'))),
                      ),
                    ),
            ),
            if (waiting) ...[
              const SizedBox(height: 10),
              Center(
                child: Text('等待扫码…（过期会自动刷新）',
                    style: TextStyle(color: AppTheme.textTertiary, fontSize: 12)),
              ),
            ],
            if (needPw) ...[
              const SizedBox(height: 14),
              _PasswordBox(onSubmit: _submitPassword),
            ],
            if (error.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(error,
                  style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: _startQr,
                  child: const Text('重试'),
                ),
              ),
            ],
          ],
        ),
      ),
    ));
  }

  Widget _manualCard() {
    return _card(AppCard(
      dense: true,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('直接填群 / 频道',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _field(_peerCtrl, '@用户名 或 -100xxxxxxxxxx'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    final p = _peerCtrl.text.trim();
                    if (p.isEmpty) {
                      AppToast.message('先填群 ID 或用户名');
                      return;
                    }
                    Get.to(() => TgChannelPage(peer: p, title: p));
                  },
                  child: const Text('打开'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('频道的 @用户名、t.me 链接、或 -100 开头的数字 ID 都行。',
                style: TextStyle(color: AppTheme.textTertiary, fontSize: 11)),
          ],
        ),
      ),
    ));
  }

  Widget _channelsCard() {
    if (_dialogs.isEmpty) {
      return _card(AppCard(
        dense: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 26),
          child: Center(
            child: Text('没有读取到频道（或账号未加入任何群）',
                style: TextStyle(color: AppTheme.textTertiary, fontSize: 12)),
          ),
        ),
      ));
    }
    return _card(AppCard(
      dense: true,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text('我的群 / 频道',
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                ),
                IconButton(
                  onPressed: _loadDialogs,
                  icon: Icon(Icons.refresh,
                      size: 18, color: AppTheme.textTertiary),
                ),
              ],
            ),
          ),
          for (final d in _dialogs)
            ListTile(
              dense: true,
              leading: Icon(
                (d['type'] == 'channel') ? Icons.campaign_outlined : Icons.groups_outlined,
                color: AppTheme.accentOnSurface,
                size: 20,
              ),
              title: Text(
                (d['title'] ?? '').toString(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              ),
              subtitle: Text(
                [
                  if ((d['username'] ?? '').toString().isNotEmpty) '@${d['username']}',
                  (d['peer'] ?? '').toString(),
                ].join('  '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppTheme.textTertiary, fontSize: 11),
              ),
              trailing: Icon(Icons.chevron_right,
                  size: 18, color: AppTheme.textTertiary),
              onTap: () => Get.to(() => TgChannelPage(
                peer: (d['peer'] ?? '').toString(),
                title: (d['title'] ?? '').toString(),
              )),
            ),
        ],
      ),
    ));
  }

  /// 公开频道 / 收藏频道管理
  ///
  /// 公开频道**不需要登录**：贴 @用户名 就能在「TG」分类里看。
  /// 这里同时管登录模式收藏（只有标题/删除，不能再改模式）。
  Widget _savedCard() {
    return _card(AppCard(
      dense: true,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('不需要登录，贴频道名即可',
                style: TextStyle(color: AppTheme.textTertiary, fontSize: 12)),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _field(_pubCtrl, '@频道名 或 t.me/频道名')),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () async {
                    final p = _normalizePeer(_pubCtrl.text);
                    if (p.isEmpty) {
                      AppToast.message('先填频道名');
                      return;
                    }
                    await _tg.addChannel(p, title: p, mode: 'public');
                    _pubCtrl.clear();
                    final s = await _tg.channels();
                    if (!mounted) return;
                    setState(() => _saved = s);
                  },
                  child: const Text('添加'),
                ),
              ],
            ),
            if (_saved.isEmpty) ...[
              const SizedBox(height: 12),
              Text('还没有收藏的频道',
                  style: TextStyle(color: AppTheme.textTertiary, fontSize: 12)),
            ] else ...[
              const SizedBox(height: 8),
              for (final c in _saved) _savedRow(c),
            ],
          ],
        ),
      ),
    ));
  }

  Widget _savedRow(Map<String, dynamic> c) {
    final peer = (c['peer'] ?? '').toString();
    final mode = (c['mode'] ?? 'public').toString();
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => Get.to(() => TgChannelPage(
        peer: peer,
        title: (c['title'] ?? peer).toString(),
        mode: mode,
      )),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Icon(mode == 'login' ? Icons.lock_outline : Icons.public,
                size: 16, color: AppTheme.textTertiary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                (c['title'] ?? peer).toString(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              ),
            ),
            Text(mode == 'login' ? '登录' : '公开',
                style: TextStyle(color: AppTheme.textTertiary, fontSize: 10.5)),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '删除',
              icon: Icon(Icons.delete_outline,
                  size: 17, color: AppTheme.textTertiary),
              onPressed: () async {
                await _tg.removeChannel(peer);
                final s = await _tg.channels();
                if (!mounted) return;
                setState(() => _saved = s);
              },
            ),
          ],
        ),
      ),
    );
  }

  String _normalizePeer(String raw) {
    var p = raw.trim();
    p = p.replaceAll(RegExp(r'^https?://'), '');
    p = p.replaceAll(RegExp(r'^(www\.)?(t|telegram)\.me/'), '');
    p = p.replaceAll(RegExp(r'^s/'), '');
    p = p.replaceAll(RegExp(r'^@'), '');
    p = p.replaceAll(RegExp(r'[/?#].*$'), '');
    return p;
  }

  Widget _hintCard() {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 20),
      child: Text(
        '说明：只使用你自己的账号与已加入的频道；内容由频道决定。'
        '播放走本机回环代理，支持拖动进度条。',
        style: TextStyle(color: AppTheme.textTertiary, fontSize: 11, height: 1.6),
      ),
    );
  }

  Widget _field(TextEditingController c, String hint,
      {TextInputType? keyboard}) {
    return TextField(
      controller: c,
      keyboardType: keyboard,
      style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
        isDense: true,
        filled: true,
        fillColor: AppTheme.backgroundTertiary,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

/// 两步验证密码输入（只在账号强制 2FA 时出现）
class _PasswordBox extends StatefulWidget {
  const _PasswordBox({required this.onSubmit});
  final Future<void> Function(String) onSubmit;

  @override
  State<_PasswordBox> createState() => _PasswordBoxState();
}

class _PasswordBoxState extends State<_PasswordBox> {
  final _c = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('该账号启用了两步验证，请输入密码',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 12)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _c,
                obscureText: _obscure,
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                decoration: InputDecoration(
                  hintText: '两步验证密码',
                  hintStyle:
                      TextStyle(color: AppTheme.textTertiary, fontSize: 12),
                  isDense: true,
                  filled: true,
                  fillColor: AppTheme.backgroundTertiary,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(
                        _obscure ? Icons.visibility_off : Icons.visibility,
                        size: 18,
                        color: AppTheme.textTertiary),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => widget.onSubmit(_c.text),
              child: const Text('提交'),
            ),
          ],
        ),
      ],
    );
  }
}
