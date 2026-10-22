import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/theme.dart';
import '../widgets/app_toast.dart';
import 'room_models.dart';
import 'room_page.dart';
import 'room_session.dart';

/// 「一起看」大厅：连房间服务器 → 看房间列表 / 建房 / 加入。
///
/// 底栏里的「一起看」tab（默认不启用，用户在「设置 → 主页页面」打开）。
///
/// 服务端就是 watch-room-server（Node + Socket.IO）：
///   填服务器地址 + 与服务端一致的 AUTH_KEY 即可，
///   房间的创建/加入/播放同步/聊天全部由服务端转发。
class RoomHomePage extends StatefulWidget {
  const RoomHomePage({super.key});

  @override
  State<RoomHomePage> createState() => _RoomHomePageState();
}

class _RoomHomePageState extends State<RoomHomePage> {
  final _session = RoomSession.instance;

  final _serverCtrl = TextEditingController();
  final _authCtrl = TextEditingController();
  final _nickCtrl = TextEditingController();
  final _joinCtrl = TextEditingController();

  bool _busy = false;
  bool _showServer = false;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSession);
    _session.loadPrefs().then((_) async {
      if (!mounted) return;
      setState(() {
        _serverCtrl.text = _session.serverUrl;
        _authCtrl.text = _session.authKey;
        _nickCtrl.text = _session.nickname;
        _joinCtrl.text = _session.lastRoomId;
        _showServer = !_session.configured;
      });
      if (_session.configured) {
        final ok = await _session.connect();
        if (ok && mounted) _session.refreshRooms();
      }
    });
  }

  @override
  void dispose() {
    _session.removeListener(_onSession);
    _serverCtrl.dispose();
    _authCtrl.dispose();
    _nickCtrl.dispose();
    _joinCtrl.dispose();
    super.dispose();
  }

  void _onSession() {
    if (mounted) setState(() {});
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _fg => _isDark ? Colors.white : AppTheme.textPrimary;
  Color get _sub => _isDark ? Colors.white60 : Colors.black54;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: Text('一起看',
            style: TextStyle(
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w600,
                color: _fg)),
        actions: [
          IconButton(
            tooltip: _session.connected ? '刷新房间列表' : '连接服务器',
            icon: Icon(
                _session.connected ? Icons.refresh_rounded : Icons.link_rounded,
                color: _fg),
            onPressed: _session.connected ? _session.refreshRooms : _connect,
          ),
          IconButton(
            tooltip: '服务器设置',
            icon: Icon(Icons.dns_outlined, color: _fg),
            onPressed: () => setState(() => _showServer = !_showServer),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
        children: [
          if (_session.inRoom) _activeCard() else ...[
            if (_showServer || !_session.configured) _serverCard(),
            if (_session.configured && !_showServer) _statusRow(),
            if (_session.inRoom == false && _session.configured) ...[
              const SizedBox(height: 12),
              _joinCard(),
              const SizedBox(height: 14),
              _roomsSection(),
            ],
          ],
          if (_session.error != null) ...[
            const SizedBox(height: 12),
            Text(_session.error!,
                style: TextStyle(
                    color: Colors.redAccent,
                    fontSize: AppTheme.fontFootnote,
                    height: 1.4)),
          ],
        ],
      ),
    );
  }

  Widget _card({required List<Widget> children}) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
          border: Border.all(
              color: _isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.06),
              width: 0.8),
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Widget _serverCard() => _card(children: [
        Row(
          children: [
            Icon(Icons.dns_outlined, size: 17, color: AppTheme.accentColor),
            const SizedBox(width: 7),
            Text('房间服务器',
                style: TextStyle(
                    color: _fg,
                    fontSize: AppTheme.fontSubhead,
                    fontWeight: FontWeight.w600)),
            const Spacer(),
            if (_session.connected)
              Row(children: [
                Icon(Icons.circle, size: 7, color: AppTheme.accentColor),
                const SizedBox(width: 4),
                Text('已连接',
                    style: TextStyle(
                        color: AppTheme.accentColor,
                        fontSize: AppTheme.fontCaption)),
              ]),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '填写你自己部署的 watch-room-server 地址和 AUTH_KEY。\n'
          '例如 https://room.example.com 或 http://192.168.1.5:3001',
          style: TextStyle(
              color: _sub, fontSize: AppTheme.fontCaption, height: 1.5),
        ),
        const SizedBox(height: 12),
        _fieldLabel('服务器地址'),
        TextField(
          controller: _serverCtrl,
          keyboardType: TextInputType.url,
          autocorrect: false,
          style: TextStyle(color: _fg, fontSize: AppTheme.fontSubhead),
          decoration: _dec('https://room.example.com'),
        ),
        const SizedBox(height: 10),
        _fieldLabel('AUTH_KEY（服务端环境变量）'),
        TextField(
          controller: _authCtrl,
          obscureText: true,
          style: TextStyle(color: _fg, fontSize: AppTheme.fontSubhead),
          decoration: _dec('与服务端 AUTH_KEY 完全一致'),
        ),
        const SizedBox(height: 10),
        _fieldLabel('我的昵称'),
        TextField(
          controller: _nickCtrl,
          style: TextStyle(color: _fg, fontSize: AppTheme.fontSubhead),
          decoration: _dec('房间里显示的名字'),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.accentColor,
              foregroundColor: Colors.white,
              minimumSize: const Size(0, 44),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusMD)),
            ),
            onPressed: (_busy || _session.connecting) ? null : _connect,
            icon: (_busy || _session.connecting)
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.link_rounded, size: 19),
            label: Text((_busy || _session.connecting) ? '连接中…' : '保存并连接'),
          ),
        ),
      ]);

  Widget _statusRow() => Row(
        children: [
          Icon(_session.connected ? Icons.cloud_done_outlined : Icons.cloud_off,
              size: 15, color: _sub),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _session.connected
                  ? '已连接 ${_session.serverUrl}'
                  : '未连接 ${_session.serverUrl}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: _sub, fontSize: AppTheme.fontCaption),
            ),
          ),
          if (!_session.connected)
            TextButton(
              onPressed: (_busy || _session.connecting) ? null : _connect,
              child: Text('连接',
                  style: TextStyle(fontSize: AppTheme.fontFootnote)),
            ),
        ],
      );

  Widget _joinCard() => _card(children: [
        Text('输入房间号加入',
            style: TextStyle(
                color: _fg,
                fontSize: AppTheme.fontSubhead,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _joinCtrl,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [LengthLimitingTextInputFormatter(8)],
                style: TextStyle(
                    color: _fg,
                    fontSize: AppTheme.fontSubhead,
                    letterSpacing: 1.5),
                decoration: _dec('如 A1B2C3'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: SizedBox(
                height: 42,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.accentColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppTheme.radiusMD)),
                  ),
                  onPressed: _busy ? null : () => _joinWith(_joinCtrl.text),
                  child: const Text('加入'),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: _busy ? null : _createDraft,
            icon: const Icon(Icons.add_rounded, size: 16),
            label: Text('创建房间',
                style: TextStyle(fontSize: AppTheme.fontFootnote)),
          ),
        ),
      ]);

  Widget _roomsSection() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('公开房间',
                  style: TextStyle(
                      color: _fg,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              if (_session.loadingRooms)
                const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.6))
              else
                Text('${_session.rooms.length}',
                    style: TextStyle(
                        color: AppTheme.accentColor,
                        fontSize: AppTheme.fontCaption)),
              const Spacer(),
              TextButton(
                onPressed: _session.loadingRooms
                    ? null
                    : () {
                        if (_session.connected) {
                          _session.refreshRooms();
                        } else {
                          _connect();
                        }
                      },
                child: Text('刷新',
                    style: TextStyle(fontSize: AppTheme.fontFootnote)),
              ),
            ],
          ),
          if (!_session.connected)
            _hint('还没连上服务器 —— 点「服务器设置」填地址和 AUTH_KEY')
          else if (_session.rooms.isEmpty && !_session.loadingRooms)
            _hint('服务器上还没有公开房间，点「创建房间」开一个')
          else
            ..._session.rooms.map(_roomTile),
        ],
      );

  Widget _roomTile(RoomInfo r) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _busy ? null : () => _joinWith(r.id, room: r),
        child: Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: _isDark
                ? Colors.white.withValues(alpha: 0.05)
                : Colors.black.withValues(alpha: 0.025),
            borderRadius: BorderRadius.circular(AppTheme.radiusMD),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppTheme.accentColor.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(
                    r.roomType == 'music'
                        ? Icons.music_note_rounded
                        : Icons.movie_outlined,
                    size: 18,
                    color: AppTheme.accentColor),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(r.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: _fg,
                                  fontSize: AppTheme.fontSubhead,
                                  fontWeight: FontWeight.w600)),
                        ),
                        if (r.hasPassword) ...[
                          const SizedBox(width: 4),
                          Icon(Icons.lock_outline, size: 12, color: _sub),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${r.ownerName} · ${r.memberCount} 人 · 房间号 ${r.id}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(color: _sub, fontSize: AppTheme.fontCaption),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: _sub),
            ],
          ),
        ),
      );

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(text,
            style: TextStyle(
                color: _sub, fontSize: AppTheme.fontFootnote, height: 1.5)),
      );

  Widget _activeCard() {
    final s = _session;
    final r = s.room!;
    return _card(children: [
      Row(
        children: [
          Icon(Icons.meeting_room_rounded,
              size: 18, color: AppTheme.accentColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(r.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: _fg,
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.w600)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppTheme.accentColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(s.isHost ? '房主' : '成员',
                style: TextStyle(
                    color: AppTheme.accentColor,
                    fontSize: AppTheme.fontCaption,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        '房间号 ${r.id} · ${s.members.length} 人'
        '${s.connected ? '' : ' · 连接已断开'}',
        style: TextStyle(color: _sub, fontSize: AppTheme.fontFootnote),
      ),
      if (s.playState != null) ...[
        const SizedBox(height: 4),
        Text('正在播放：${s.playState!.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: _sub, fontSize: AppTheme.fontCaption)),
      ],
      const SizedBox(height: 14),
      Row(
        children: [
          Expanded(
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.accentColor,
                foregroundColor: Colors.white,
                minimumSize: const Size(0, 42),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMD)),
              ),
              onPressed: _openRoom,
              child: Text(s.connected ? '进入房间' : '重新进入'),
            ),
          ),
          const SizedBox(width: 10),
          TextButton(
            onPressed: _leave,
            style: TextButton.styleFrom(
              foregroundColor: Colors.redAccent,
              minimumSize: const Size(0, 42),
            ),
            child: Text(s.isHost ? '解散房间' : '离开房间'),
          ),
        ],
      ),
      if (s.isHost) ...[
        const SizedBox(height: 6),
        Text('房间号 ${r.id} 分享给朋友，他们在「输入房间号加入」里填即可',
            style: TextStyle(color: _sub, fontSize: AppTheme.fontCaption)),
      ],
    ]);
  }

  Widget _fieldLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: TextStyle(color: _sub, fontSize: AppTheme.fontCaption)),
      );

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: _sub, fontSize: AppTheme.fontSubhead),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusMD),
          borderSide: BorderSide(
              color: _isDark ? Colors.white24 : Colors.black12, width: 0.8),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusMD),
          borderSide: BorderSide(
              color: _isDark ? Colors.white24 : Colors.black12, width: 0.8),
        ),
      );

  // ── 动作 ─────────────────────────────────────────────────────

  Future<void> _connect() async {
    FocusScope.of(context).unfocus();
    final url = _serverCtrl.text.trim();
    final key = _authCtrl.text.trim();
    if (url.isEmpty || key.isEmpty) {
      AppToast.show('服务器地址和 AUTH_KEY 都要填', '');
      return;
    }
    setState(() => _busy = true);
    await _session.saveConfig(url: url, key: key);
    await _session.saveNickname(_nickCtrl.text);
    final ok = await _session.connect();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _showServer = false;
    });
    if (ok) {
      _session.refreshRooms();
    } else {
      AppToast.show(_session.error ?? '连接失败', '');
    }
  }

  Future<void> _createDraft() async {
    final nameCtrl = TextEditingController(text: '${_session.nickname}的房间');
    final descCtrl = TextEditingController();
    final pwdCtrl = TextEditingController();
    var isPublic = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('创建房间'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: '房间名'),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: descCtrl,
                  decoration: const InputDecoration(labelText: '简介（可选）'),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: pwdCtrl,
                  decoration: const InputDecoration(labelText: '密码（可选）'),
                ),
                const SizedBox(height: 6),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('公开房间'),
                  subtitle: const Text('关闭后只能凭房间号加入'),
                  value: isPublic,
                  onChanged: (v) => setDlg(() => isPublic = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('创建')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) {
      nameCtrl.dispose();
      descCtrl.dispose();
      pwdCtrl.dispose();
      return;
    }
    setState(() => _busy = true);
    await _session.saveNickname(_nickCtrl.text);
    final success = await _session.createRoom(
      name: nameCtrl.text,
      description: descCtrl.text,
      password: pwdCtrl.text,
      isPublic: isPublic,
    );
    nameCtrl.dispose();
    descCtrl.dispose();
    pwdCtrl.dispose();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!success) {
      AppToast.show(_session.error ?? '创建失败', '');
      return;
    }
    _openRoom();
  }

  Future<void> _joinWith(String roomId, {RoomInfo? room}) async {
    FocusScope.of(context).unfocus();
    var pwd = '';
    // 列表里的公开房间可能带锁；手输房间号时先试无密码，报错再提示输入
    if (room != null && room.hasPassword) {
      final input = await _askPassword(room.name);
      if (input == null) return;
      pwd = input;
    }
    if (roomId.trim().isEmpty) {
      AppToast.show('先填房间号', '');
      return;
    }
    setState(() => _busy = true);
    await _session.saveNickname(_nickCtrl.text);
    var ok = await _session.joinRoom(roomId: roomId, password: pwd);
    if (!ok && pwd.isEmpty && mounted) {
      // 很可能是密码房：问一次密码再试
      final input = await _askPassword(roomId);
      if (input != null) {
        ok = await _session.joinRoom(roomId: roomId, password: input);
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      AppToast.show(_session.error ?? '加入失败', '');
      return;
    }
    _openRoom();
  }

  Future<String?> _askPassword(String name) async {
    final ctrl = TextEditingController();
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('房间有密码'),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          autofocus: true,
          decoration: InputDecoration(labelText: '输入「$name」的密码'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('加入')),
        ],
      ),
    );
    ctrl.dispose();
    if (r == null) return null;
    return r.trim();
  }

  Future<void> _openRoom() async {
    await Navigator.of(context).push(MaterialPageRoute(
      settings: const RouteSettings(name: 'room:page'),
      builder: (_) => const RoomPage(),
    ));
    if (mounted) setState(() {});
  }

  Future<void> _leave() async {
    final hosting = _session.isHost;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(hosting ? '解散房间？' : '离开房间？'),
        content: Text(hosting
            ? '离开后房主身份保留 5 分钟，期间可以用房间号回来；'
                '超过 5 分钟房间会被服务器删除。'
            : '离开后可以随时用房间号再进来。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: Text(hosting ? '离开' : '离开')),
        ],
      ),
    );
    if (ok == true) {
      await _session.leaveRoom();
      if (mounted) _session.refreshRooms();
    }
  }
}
