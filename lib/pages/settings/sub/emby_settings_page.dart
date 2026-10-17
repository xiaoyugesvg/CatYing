import 'package:flutter/material.dart';

import '../../../common/theme.dart';
import '../../../emby/emby_api.dart';
import '../../../emby/emby_models.dart';
import '../../../emby/emby_store.dart';
import '../../../widgets/app_toast.dart';
import 'settings_shared.dart';

/// 设置 → Emby 管理：多服务器添加 / 登录 / 切换 / 删除。
///
/// 说明：Emby 分类**默认不显示在底栏**，需要在「设置 → 菜单设置」里开启。
class EmbySettingsPage extends StatefulWidget {
  const EmbySettingsPage({super.key});

  @override
  State<EmbySettingsPage> createState() => _EmbySettingsPageState();
}

class _EmbySettingsPageState extends State<EmbySettingsPage> {
  final _store = EmbyStore.instance;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _store.load();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _openEditor([EmbyServer? existing]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _EmbyEditorDialog(existing: existing),
    );
    if (saved == true) {
      await _load();
      if (mounted) {
        AppToast.show(
          existing == null ? '已添加 Emby 服务器' : '已保存',
          '',
        );
      }
    }
  }

  Future<void> _delete(EmbyServer s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除服务器'),
        content: Text('确定删除「${s.name}」？仅删除本地配置，不会影响 Emby 服务端。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _store.remove(s.id);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final servers = _store.servers;
    return SettingsSubPage(
      title: 'Emby 管理',
      action: IconButton(
        tooltip: '添加服务器',
        icon: const Icon(Icons.add_rounded),
        onPressed: () => _openEditor(),
      ),
      children: [
        SettingsGroup(
          title: '服务器',
          hint: 'Emby 分类默认不显示在底栏：到「设置 → 菜单设置」把它打开即可。',
          children: [
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (servers.isEmpty)
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Icon(
                      Icons.dns_outlined,
                      size: 36,
                      color: AppTheme.textTertiary,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '还没有添加 Emby 服务器',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: AppTheme.fontFootnote,
                      ),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () => _openEditor(),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('添加服务器'),
                    ),
                  ],
                ),
              )
            else
              for (final s in servers) _serverTile(s),
          ],
        ),
        const SizedBox(height: AppTheme.spacingLG),
        SettingsGroup(
          title: '说明',
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Text(
                '· 支持 Emby 4.x（Jellyfin 同接口，多数场景也可用）。\n'
                '· 请填服务器根地址，例如 http://192.168.1.10:8096。\n'
                '· 登录信息只保存在本机；账号需要拥有对应媒体库的访问权限。\n'
                '· 播放使用视频直连（static），服务端不会转码；若个别编码无法播放，'
                '可在后续版本切换转码线路。',
                style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: AppTheme.fontFootnote,
                  height: 1.6,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _serverTile(EmbyServer s) {
    final active = s.id == _store.activeId;
    return ListTile(
      leading: Icon(
        active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: active ? AppTheme.accentColor : AppTheme.textTertiary,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              s.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontSubhead,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: s.isConfigured
                  ? AppTheme.accentColor.withValues(alpha: 0.12)
                  : AppTheme.backgroundSecondary,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              s.isConfigured ? '已登录' : '未登录',
              style: TextStyle(
                color: s.isConfigured
                    ? AppTheme.accentColor
                    : AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
              ),
            ),
          ),
        ],
      ),
      subtitle: Text(
        '${s.normalizedUrl}\n${s.username}',
        style: TextStyle(
          color: AppTheme.textTertiary,
          fontSize: AppTheme.fontCaption,
          height: 1.4,
        ),
      ),
      isThreeLine: true,
      onTap: () async {
        await _store.setActive(s.id);
        if (mounted) setState(() {});
      },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '编辑',
            icon: Icon(Icons.edit_outlined, color: AppTheme.textSecondary),
            onPressed: () => _openEditor(s),
          ),
          IconButton(
            tooltip: '删除',
            icon: Icon(Icons.delete_outline, color: AppTheme.textTertiary),
            onPressed: () => _delete(s),
          ),
        ],
      ),
    );
  }
}

/// 添加 / 编辑服务器弹窗：保存时真实请求一次登录接口。
class _EmbyEditorDialog extends StatefulWidget {
  const _EmbyEditorDialog({this.existing});

  final EmbyServer? existing;

  @override
  State<_EmbyEditorDialog> createState() => _EmbyEditorDialogState();
}

class _EmbyEditorDialogState extends State<_EmbyEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _user;
  late final TextEditingController _pass;

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _url = TextEditingController(text: e?.baseUrl ?? '');
    _user = TextEditingController(text: e?.username ?? '');
    _pass = TextEditingController(text: e?.password ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _url.text.trim();
    final user = _user.text.trim();
    if (url.isEmpty) {
      setState(() => _error = '请填写服务器地址');
      return;
    }
    if (user.isEmpty) {
      setState(() => _error = '请填写用户名');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final store = EmbyStore.instance;
    await store.load();
    final id = widget.existing?.id ?? EmbyServer.newId();
    final server = EmbyServer(
      id: id,
      name: _name.text.trim().isEmpty
          ? Uri.tryParse(url)?.host ?? 'Emby'
          : _name.text.trim(),
      baseUrl: url,
      username: user,
      password: _pass.text,
      deviceId: widget.existing?.deviceId.isNotEmpty == true
          ? widget.existing!.deviceId
          : store.deviceId,
    );
    try {
      final auth = await EmbyApi(server).authenticate();
      server.accessToken = auth.token;
      server.userId = auth.userId;
      await store.addOrUpdate(server);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is EmbyApiException ? e.message : '连接失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return AlertDialog(
      title: Text(isEdit ? '编辑 Emby 服务器' : '添加 Emby 服务器'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: '名称（可选）',
                hintText: '例如：家里的 Emby',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '服务器地址',
                hintText: 'http://192.168.1.10:8096',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _user,
              autocorrect: false,
              decoration: const InputDecoration(labelText: '用户名'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _pass,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密码'),
              onSubmitted: (_) => _busy ? null : _save(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _error!,
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: AppTheme.fontFootnote,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(isEdit ? '保存' : '登录并保存'),
        ),
      ],
    );
  }
}
