import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../services/tg_service.dart';
import '../../widgets/app_toast.dart';
import '../settings/sub/tg_channel_page.dart';
import '../settings/sub/tg_source_page.dart';

/// 「TG」分类页（底部菜单栏可选，**默认关闭**）
///
/// 两条入口并存：
///   · **公开频道**：贴一个 @用户名 / t.me 链接就能看，不用登录
///   · **我的频道**：扫码登录后，列出账号里加入的群 / 频道（含私有）
///
/// 页面本身不解析任何协议，全部交给内置 Node 的 `/tg`。
class TgHomePage extends StatefulWidget {
  const TgHomePage({super.key});

  @override
  State<TgHomePage> createState() => _TgHomePageState();
}

class _TgHomePageState extends State<TgHomePage> {
  final TgService _tg = TgService.instance;
  final TextEditingController _input = TextEditingController();

  bool _loading = true;
  bool _authorized = false;
  String _meName = '';
  List<Map<String, dynamic>> _saved = [];
  List<Map<String, dynamic>> _dialogs = [];

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    await _tg.loadSettings();
    await _tg.pushConfig();
    await _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final st = await _tg.status();
    final saved = await _tg.channels();
    if (!mounted) return;
    final authed = st['authorized'] == true;
    setState(() {
      _loading = false;
      _authorized = authed;
      _meName = ((st['me'] as Map?)?['name'] ?? '').toString();
      _saved = saved;
    });
    if (authed) {
      final r = await _tg.dialogs();
      if (!mounted) return;
      setState(() {
        _dialogs = ((r['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
      });
    } else {
      setState(() => _dialogs = []);
    }
  }

  Future<void> _openPublic() async {
    final raw = _input.text.trim();
    if (raw.isEmpty) {
      AppToast.message('先填频道 @用户名 或 t.me 链接');
      return;
    }
    final peer = raw
        .replaceAll(RegExp(r'^https?://'), '')
        .replaceAll(RegExp(r'^(www\.)?(t|telegram)\.me/'), '')
        .replaceAll(RegExp(r'^s/'), '')
        .replaceAll(RegExp(r'[/?#].*$'), '');
    if (peer.isEmpty) {
      AppToast.message('频道名解析失败');
      return;
    }
    await _tg.addChannel(peer, title: peer, mode: 'public');
    _input.clear();
    await _refresh();
    if (!mounted) return;
    Get.to(() => TgChannelPage(peer: peer, title: peer, mode: 'public'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 90),
            children: [
              _header(),
              const SizedBox(height: 14),
              _publicAdder(),
              const SizedBox(height: 18),
              _sectionTitle('收藏的频道', trailing: _saved.isEmpty ? null : '${_saved.length}'),
              if (_saved.isEmpty)
                _emptyLine('还没有收藏。上面贴一个公开频道就能直接看。')
              else
                ..._saved.map(_savedRow),
              const SizedBox(height: 18),
              _sectionTitle(
                '我的频道（需登录）',
                trailing: _authorized ? (_meName.isEmpty ? '已登录' : _meName) : null,
              ),
              if (!_authorized) _loginHint(),
              if (_authorized && _dialogs.isEmpty && !_loading)
                _emptyLine('这个账号还没有加入任何群 / 频道'),
              ..._dialogs.map(_dialogRow),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        Text('TG',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 26,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            )),
        const SizedBox(width: 8),
        Text('公开频道 + 自己的群',
            style: TextStyle(color: AppTheme.textTertiary, fontSize: 12)),
        const Spacer(),
        IconButton(
          tooltip: '刷新',
          onPressed: _loading ? null : _refresh,
          icon: Icon(Icons.refresh, color: AppTheme.textTertiary, size: 20),
        ),
        IconButton(
          tooltip: 'TG 设置',
          onPressed: () async {
            await Get.to(() => const TgSourcePage());
            await _refresh();
          },
          icon: Icon(Icons.settings_outlined,
              color: AppTheme.textTertiary, size: 20),
        ),
      ],
    );
  }

  Widget _publicAdder() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.public, color: AppTheme.accentOnSurface, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _input,
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _openPublic(),
              decoration: InputDecoration(
                hintText: '@频道名 或 t.me/频道名',
                hintStyle: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
                isDense: true,
                border: InputBorder.none,
              ),
            ),
          ),
          TextButton(onPressed: _openPublic, child: const Text('打开')),
        ],
      ),
    );
  }

  Widget _savedRow(Map<String, dynamic> c) {
    final peer = (c['peer'] ?? '').toString();
    final mode = (c['mode'] ?? 'public').toString();
    return Dismissible(
      key: ValueKey('saved_$peer'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: Colors.redAccent.withValues(alpha: 0.85),
        child: const Icon(Icons.delete_outline, color: Colors.white, size: 20),
      ),
      onDismissed: (_) async {
        await _tg.removeChannel(peer);
        await _refresh();
      },
      child: _row(
        icon: Icons.public,
        title: (c['title'] ?? peer).toString(),
        subtitle: '@$peer',
        badge: mode == 'login' ? '登录' : '公开',
        onTap: () => Get.to(() => TgChannelPage(
          peer: peer,
          title: (c['title'] ?? peer).toString(),
          mode: mode,
        )),
      ),
    );
  }

  Widget _dialogRow(Map<String, dynamic> d) {
    final peer = (d['peer'] ?? '').toString();
    final title = (d['title'] ?? peer).toString();
    return _row(
      icon: d['type'] == 'channel' ? Icons.campaign_outlined : Icons.groups_outlined,
      title: title,
      subtitle: '@${d['username'] ?? ''}'.trim() == '@' ? peer : '@${d['username']}  $peer',
      onTap: () => Get.to(() => TgChannelPage(peer: peer, title: title, mode: 'login')),
      onLongPress: () async {
        await _tg.addChannel(peer, title: title, mode: 'login');
        if (!mounted) return;
        AppToast.message('已加入 TG 收藏');
        await _refresh();
      },
    );
  }

  Widget _row({
    required IconData icon,
    required String title,
    required String subtitle,
    String? badge,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: AppTheme.backgroundCard,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(icon, size: 19, color: AppTheme.accentOnSurface),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: AppTheme.textTertiary, fontSize: 11),
                    ),
                  ],
                ),
              ),
              if (badge != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.backgroundTertiary,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(badge,
                      style: TextStyle(color: AppTheme.textTertiary, fontSize: 10)),
                ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 18, color: AppTheme.textTertiary),
            ],
          ),
        ),
      ),
    );
  }

  Widget _loginHint() {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Get.to(() => const TgSourcePage()),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.backgroundCard,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.qr_code_2, color: AppTheme.accentOnSurface, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '想看你自己加入的群 / 私有频道？点这里扫码登录（不需要验证码）',
                style: TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12, height: 1.4),
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: AppTheme.textTertiary),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text, {String? trailing}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(text,
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
          const Spacer(),
          if (trailing != null)
            Text(trailing,
                style: TextStyle(color: AppTheme.textTertiary, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _emptyLine(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text,
          style: TextStyle(
              color: AppTheme.textTertiary, fontSize: 12, height: 1.5)),
    );
  }
}
