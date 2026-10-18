import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common/theme.dart';
import '../../widgets/app_toast.dart';
import 'emby_api.dart';
import 'emby_models.dart';
import 'emby_store.dart';

/// 添加 / 编辑媒体服务器账号（VidHub 风格全屏表单页）。
///
/// 替代旧的 `_EmbyEditorDialog`（AlertDialog）。
class EmbyEditorPage extends StatefulWidget {
  const EmbyEditorPage({super.key, this.existing});

  final EmbyServer? existing;

  @override
  State<EmbyEditorPage> createState() => _EmbyEditorPageState();
}

class _EmbyEditorPageState extends State<EmbyEditorPage> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _user;
  late final TextEditingController _pass;

  bool _busy = false;
  bool _obscurePass = true;
  String? _error;

  /// 服务器类型：autoDetect / emby / jellyfin / plex
  String _type = 'autoDetect';

  static const _types = [
    ('autoDetect', '自动探测'),
    ('emby', 'Emby'),
    ('jellyfin', 'Jellyfin'),
    ('plex', 'Plex'),
  ];

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _url = TextEditingController(text: e?.baseUrl ?? '');
    _user = TextEditingController(text: e?.username ?? '');
    _pass = TextEditingController(text: e?.password ?? '');
    if (e != null) _type = e.type;
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _paste(TextEditingController ctrl) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      ctrl.text = data.text!.trim();
    }
  }

  Future<void> _save() async {
    if (_type == 'plex') {
      AppToast.show('暂不支持 Plex', '请使用 Emby 或 Jellyfin');
      return;
    }
    final url = _url.text.trim();
    final user = _user.text.trim();
    if (_type != 'plex' && url.isEmpty) {
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
    // autoDetect：先试 Emby authenticate，成功即视为 Emby
    final effectiveType = _type == 'autoDetect' ? 'emby' : _type;
    final server = EmbyServer(
      id: id,
      name: _name.text.trim().isEmpty
          ? (widget.existing?.name ?? Uri.tryParse(url)?.host ?? 'Emby')
          : _name.text.trim(),
      type: effectiveType,
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

  Widget _buildTypeChip(String value, String label) {
    final selected = _type == value;
    return GestureDetector(
      onTap: () => setState(() => _type = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppTheme.backgroundElevated : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AppTheme.textPrimary : AppTheme.textSecondary,
            fontSize: AppTheme.fontSubhead,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _buildInput({
    required String label,
    required TextEditingController controller,
    String? placeholder,
    bool obscureText = false,
    Widget? suffixIcon,
    TextInputType? keyboardType,
    bool autocorrect = true,
    VoidCallback? onSubmitted,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: AppTheme.fontFootnote,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: AppTheme.backgroundCard,
            borderRadius: BorderRadius.circular(AppTheme.radiusMD),
          ),
          child: TextField(
            controller: controller,
            obscureText: obscureText,
            keyboardType: keyboardType,
            autocorrect: autocorrect,
            onSubmitted: (_) => onSubmitted?.call(),
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontBody,
            ),
            decoration: InputDecoration(
              hintText: placeholder,
              hintStyle: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontBody,
              ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 14,
              ),
              suffixIcon: suffixIcon,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = _isEdit;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new,
            color: AppTheme.textPrimary,
            size: 20,
          ),
          onPressed: () => Navigator.pop(context),
        ),
        centerTitle: true,
        title: Text(
          isEdit ? '编辑账号' : '添加账号',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontHeadline,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 服务器类型
            Text(
              '服务器类型',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontFootnote,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: AppTheme.backgroundCard,
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.all(4),
              child: Row(
                children: _types
                    .map((t) => Expanded(child: _buildTypeChip(t.$1, t.$2)))
                    .toList(),
              ),
            ),
            const SizedBox(height: 20),

            // 服务器名称（用户 2026-10-18：账号列表里全是服务器域名，认不出是哪个；
            // 添加/编辑时都能在这里改名，列表卡片标题显示的就是它）
            _buildInput(
              label: '服务器名称',
              controller: _name,
              placeholder: '如 家庭影院、客厅 NAS（留空则用服务器地址）',
            ),
            const SizedBox(height: 16),

            // 服务器地址（Plex 隐藏）
            if (_type != 'plex') ...[
              _buildInput(
                label: '服务器地址',
                controller: _url,
                placeholder: '如 http://192.168.1.10:8096',
                keyboardType: TextInputType.url,
                autocorrect: false,
                suffixIcon: IconButton(
                  icon: Icon(
                    Icons.paste_outlined,
                    size: 18,
                    color: AppTheme.textTertiary,
                  ),
                  onPressed: () => _paste(_url),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // 用户名
            _buildInput(
              label: '用户名',
              controller: _user,
              autocorrect: false,
              suffixIcon: IconButton(
                icon: Icon(
                  Icons.paste_outlined,
                  size: 18,
                  color: AppTheme.textTertiary,
                ),
                onPressed: () => _paste(_user),
              ),
            ),
            const SizedBox(height: 16),

            // 密码
            _buildInput(
              label: '密码',
              controller: _pass,
              placeholder: '可留空',
              obscureText: _obscurePass,
              autocorrect: false,
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(
                      Icons.paste_outlined,
                      size: 18,
                      color: AppTheme.textTertiary,
                    ),
                    onPressed: () => _paste(_pass),
                  ),
                  IconButton(
                    icon: Icon(
                      _obscurePass
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 18,
                      color: AppTheme.textTertiary,
                    ),
                    onPressed: () =>
                        setState(() => _obscurePass = !_obscurePass),
                  ),
                ],
              ),
              onSubmitted: () => _busy ? null : _save(),
            ),
            const SizedBox(height: 24),

            // 错误提示
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _error!,
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: AppTheme.fontFootnote,
                  ),
                ),
              ),

            // 保存按钮
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                onPressed: _busy ? null : _save,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.arrow_forward, size: 18),
                label: Text(isEdit ? '重新登录并保存' : '登录并保存'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.accentColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMD),
                  ),
                  textStyle: const TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
