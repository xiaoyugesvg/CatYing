import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

import 'room_models.dart';

/// 播放同步事件（来自服务端，页面据此驱动播放器）
sealed class RoomPlayEvent {
  const RoomPlayEvent();
}

/// 房主广播的完整状态（含片源地址 / 进度 / 播放态）
class RoomPlayUpdated extends RoomPlayEvent {
  const RoomPlayUpdated(this.state);
  final PlayState state;
}

/// 切集 / 换片（房主）
class RoomPlayChanged extends RoomPlayEvent {
  const RoomPlayChanged(this.state);
  final PlayState state;
}

/// 有人拖了进度条（秒）
class RoomPlaySought extends RoomPlayEvent {
  const RoomPlaySought(this.seconds);
  final double seconds;
}

/// 播放 / 暂停
class RoomPlayToggled extends RoomPlayEvent {
  const RoomPlayToggled(this.playing);
  final bool playing;
}

/// 房主清空了片源
class RoomPlayCleared extends RoomPlayEvent {
  const RoomPlayCleared();
}

/// 「一起看」全局会话：一条 Socket.IO 连接 + 一个当前房间。
///
/// 服务端就是用户自己部署的 watch-room-server：
///   · 连接时把 AUTH_KEY 放在 handshake.auth.token 里（服务端强校验）
///   · 房间创建 / 加入都走 ack 回调
///   · 播放状态由房主用 `play:update` 定时广播；`play:seek/play/pause`
///     任何成员都能发，服务端转发给房间里的其他人
class RoomSession extends ChangeNotifier {
  RoomSession._();
  static final RoomSession instance = RoomSession._();

  static const _kServer = 'room.serverUrl';
  static const _kAuth = 'room.authKey';
  static const _kNickname = 'room.nickname';
  static const _kLastRoom = 'room.lastRoomId';

  IO.Socket? _socket;
  Timer? _heartbeatTimer;

  String serverUrl = '';
  String authKey = '';
  String nickname = '我';
  String lastRoomId = '';
  bool _prefsLoaded = false;

  bool connecting = false;
  bool connected = false;
  String? error;

  /// 事件监听只绑一次（socket 自动重连会再次触发 onConnect）
  bool _eventsBound = false;

  /// 大厅里的公开房间
  List<RoomInfo> rooms = const [];
  bool loadingRooms = false;

  /// 当前房间（null = 不在房间里）
  RoomInfo? room;
  List<RoomMemberInfo> members = const [];
  List<RoomChatMessage> messages = const [];
  PlayState? playState;
  bool isHost = false;

  /// 建房时服务端给的凭证：断线后用它可以恢复房主身份
  String _ownerToken = '';
  String _joinPassword = '';

  final _playEvents = StreamController<RoomPlayEvent>.broadcast();

  /// 页面订阅播放事件；大厅不关心
  Stream<RoomPlayEvent> get playEvents => _playEvents.stream;

  bool get inRoom => room != null;

  bool get configured => serverUrl.trim().isNotEmpty;

  Future<void> loadPrefs() async {
    if (_prefsLoaded) return;
    _prefsLoaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      serverUrl = p.getString(_kServer) ?? '';
      authKey = p.getString(_kAuth) ?? '';
      nickname = p.getString(_kNickname) ?? '我';
      lastRoomId = p.getString(_kLastRoom) ?? '';
    } catch (_) {}
    notifyListeners();
  }

  Future<void> saveConfig({required String url, required String key}) async {
    serverUrl = url.trim();
    authKey = key.trim();
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kServer, serverUrl);
      await p.setString(_kAuth, authKey);
    } catch (_) {}
  }

  Future<void> saveNickname(String v) async {
    final name = v.trim();
    if (name.isEmpty || name == nickname) return;
    nickname = name;
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kNickname, name);
    } catch (_) {}
  }

  // ── 连接 ─────────────────────────────────────────────────────

  /// 连接（已连上则直接返回 true）
  Future<bool> connect() async {
    if (_socket?.connected == true) return true;
    final url = serverUrl.trim();
    if (url.isEmpty) {
      error = '先填房间服务器地址';
      notifyListeners();
      return false;
    }
    if (authKey.trim().isEmpty) {
      error = '先填服务器的 AUTH_KEY（与服务端环境变量一致）';
      notifyListeners();
      return false;
    }
    connecting = true;
    error = null;
    notifyListeners();

    // 手动重连：先把上一条（可能还在自动重试的）连接彻底放掉
    try {
      _socket?.dispose();
    } catch (_) {}
    _socket = null;

    final socket = IO.io(
      url,
      IO.OptionBuilder()
          // 优先 WebSocket；服务器/Nginx 没开 upgrade 时回退 polling
          .setTransports(['websocket', 'polling'])
          .setAuth({'token': authKey.trim()})
          .disableAutoConnect()
          .enableReconnection()
          .build(),
    );
    _socket = socket;
    _eventsBound = false;

    final completer = Completer<bool>();
    void finish(bool ok) {
      if (!completer.isCompleted) completer.complete(ok);
    }

    socket.onConnect((_) {
      connecting = false;
      connected = true;
      error = null;
      _startHeartbeat();
      if (!_eventsBound) {
        _bindRoomEvents(socket);
        _eventsBound = true;
      } else if (room != null) {
        // 自动重连成功：服务端已把我们踢出房间，需要重新 join
        final id = room!.id;
        final pwd = _joinPassword;
        final owner = isHost;
        unawaited(joinRoom(roomId: id, password: pwd, asOwner: owner));
      }
      notifyListeners();
      finish(true);
    });

    socket.onConnectError((e) {
      connecting = false;
      connected = false;
      error = '连不上房间服务器：$e';
      notifyListeners();
      finish(false);
    });

    socket.onError((e) {
      error = '服务器错误：$e';
      notifyListeners();
    });

    socket.onDisconnect((_) {
      connected = false;
      connecting = false;
      _stopHeartbeat();
      if (inRoom) error = '与房间服务器的连接已断开';
      notifyListeners();
    });

    socket.on('error', (data) {
      final msg = '$data';
      error = msg == 'Unauthorized' ? 'AUTH_KEY 不正确' : msg;
      connecting = false;
      notifyListeners();
      finish(false);
    });

    socket.connect();
    final ok = await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => false,
    );
    if (!ok) {
      connecting = false;
      if (error == null) error = '连接超时：检查地址/端口/证书是否可访问';
      try {
        socket.dispose();
      } catch (_) {}
      if (identical(_socket, socket)) _socket = null;
      notifyListeners();
    }
    return ok;
  }

  void _bindRoomEvents(IO.Socket socket) {
    socket.on('room:member-joined', (data) {
      if (data is Map) {
        final m = RoomMemberInfo.fromJson(data.cast<String, dynamic>());
        members = [...members.where((e) => e.id != m.id), m];
        _appendSystem('${m.name} 加入了房间');
        notifyListeners();
      }
    });

    socket.on('room:member-left', (data) {
      final id = '$data';
      final left = members.where((e) => e.id == id).toList();
      members = members.where((e) => e.id != id).toList();
      if (left.isNotEmpty) _appendSystem('${left.first.name} 离开了房间');
      notifyListeners();
    });

    socket.on('room:deleted', (_) {
      room = null;
      members = const [];
      playState = null;
      isHost = false;
      error = '房间已被解散';
      _emit(const RoomPlayCleared());
      notifyListeners();
    });

    socket.on('play:update', (data) {
      if (data is! Map) return;
      final s = PlayState.fromJson(data.cast<String, dynamic>());
      playState = s;
      _emit(RoomPlayUpdated(s));
      notifyListeners();
    });

    socket.on('play:change', (data) {
      if (data is! Map) return;
      final s = PlayState.fromJson(data.cast<String, dynamic>());
      playState = s;
      _emit(RoomPlayChanged(s));
      notifyListeners();
    });

    socket.on('play:seek', (data) {
      final sec = double.tryParse('$data') ?? 0;
      _emit(RoomPlaySought(sec));
    });

    socket.on('play:play', (_) => _emit(const RoomPlayToggled(true)));
    socket.on('play:pause', (_) => _emit(const RoomPlayToggled(false)));

    socket.on('state:cleared', (_) {
      playState = null;
      _emit(const RoomPlayCleared());
      notifyListeners();
    });

    socket.on('chat:message', (data) {
      if (data is! Map) return;
      messages = [
        ...messages,
        RoomChatMessage.fromJson(data.cast<String, dynamic>()),
      ];
      if (messages.length > 300) {
        messages = messages.sublist(messages.length - 300);
      }
      notifyListeners();
    });
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    // 服务端房主 30 秒无心跳会清空片源、5 分钟掉房 ⇒ 15 秒一次足够稳
    _heartbeatTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _socket?.emit('heartbeat'));
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  // ── 大厅 ─────────────────────────────────────────────────────

  Future<void> refreshRooms() async {
    if (await connect() != true) return;
    loadingRooms = true;
    notifyListeners();
    final completer = Completer<void>();
    _socket?.emitWithAck('room:list', null, ack: (data) {
      final out = <RoomInfo>[];
      if (data is List) {
        for (final e in data) {
          if (e is Map) out.add(RoomInfo.fromJson(e.cast<String, dynamic>()));
        }
      }
      out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      rooms = out;
      loadingRooms = false;
      notifyListeners();
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future.timeout(const Duration(seconds: 8), onTimeout: () {
      loadingRooms = false;
      notifyListeners();
    });
  }

  // ── 建房 / 进房 ──────────────────────────────────────────────

  Future<bool> createRoom({
    required String name,
    String description = '',
    String password = '',
    bool isPublic = true,
  }) async {
    if (await connect() != true) return false;
    final completer = Completer<bool>();
    _socket?.emitWithAck('room:create', {
      'name': name.trim().isEmpty ? '一起看' : name.trim(),
      'description': description.trim(),
      'password': password.trim().isEmpty ? null : password.trim(),
      'isPublic': isPublic,
      'userName': nickname,
      'roomType': 'sync',
    }, ack: (data) {
      if (data is Map && data['success'] == true && data['room'] is Map) {
        _enterRoom(
          RoomInfo.fromJson((data['room'] as Map).cast<String, dynamic>()),
          isOwner: true,
          password: password.trim(),
        );
        if (!completer.isCompleted) completer.complete(true);
      } else {
        error = data is Map ? '${data['error'] ?? '创建房间失败'}' : '创建房间失败';
        notifyListeners();
        if (!completer.isCompleted) completer.complete(false);
      }
    });
    return completer.future.timeout(const Duration(seconds: 10), onTimeout: () {
      error = '创建房间超时：服务器没有响应';
      notifyListeners();
      return false;
    });
  }

  Future<bool> joinRoom({
    required String roomId,
    String password = '',
    bool asOwner = false,
  }) async {
    if (await connect() != true) return false;
    final id = roomId.trim().toUpperCase();
    if (id.isEmpty) {
      error = '请填写房间号';
      notifyListeners();
      return false;
    }
    final completer = Completer<bool>();
    _socket?.emitWithAck('room:join', {
      'roomId': id,
      'password': password.isEmpty ? null : password,
      'userName': nickname,
      if (asOwner && _ownerToken.isNotEmpty) 'ownerToken': _ownerToken,
    }, ack: (data) {
      if (data is Map && data['success'] == true && data['room'] is Map) {
        final info =
            RoomInfo.fromJson((data['room'] as Map).cast<String, dynamic>());
        final ms = data['members'];
        final list = <RoomMemberInfo>[];
        if (ms is List) {
          for (final e in ms) {
            if (e is Map) {
              list.add(RoomMemberInfo.fromJson(e.cast<String, dynamic>()));
            }
          }
        }
        _enterRoom(info, isOwner: asOwner, password: password, members: list);
        if (!completer.isCompleted) completer.complete(true);
      } else {
        error = data is Map ? '${data['error'] ?? '加入房间失败'}' : '加入房间失败';
        notifyListeners();
        if (!completer.isCompleted) completer.complete(false);
      }
    });
    return completer.future.timeout(const Duration(seconds: 10), onTimeout: () {
      error = '加入房间超时：服务器没有响应';
      notifyListeners();
      return false;
    });
  }

  void _enterRoom(
    RoomInfo info, {
    required bool isOwner,
    String password = '',
    List<RoomMemberInfo>? members,
  }) {
    room = info;
    isHost = isOwner;
    _joinPassword = password;
    if (isOwner && info.ownerToken.isNotEmpty) _ownerToken = info.ownerToken;
    playState = info.currentState;
    messages = const [];
    this.members = members ??
        [
          RoomMemberInfo(id: 'me', name: nickname, isOwner: isOwner),
        ];
    error = null;
    lastRoomId = info.id;
    _saveLastRoom(info.id);
    _appendSystem('你进入了房间「${info.name}」');
    notifyListeners();
  }

  Future<void> _saveLastRoom(String id) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kLastRoom, id);
    } catch (_) {}
  }

  Future<void> leaveRoom() async {
    if (room == null) return;
    _socket?.emit('room:leave');
    room = null;
    members = const [];
    messages = const [];
    playState = null;
    isHost = false;
    // 刻意**保留** _ownerToken / _joinPassword：服务端会给房主留 5 分钟，
    // 期间用同一房间号回来还能恢复房主身份（清了就只能当普通成员）。
    notifyListeners();
  }

  /// 断线重连后自动回到原房间（房主凭 token 恢复身份）
  Future<void> rejoin() async {
    final id = lastRoomId;
    if (id.isEmpty || room != null) return;
    await joinRoom(
      roomId: id,
      password: _joinPassword,
      asOwner: _ownerToken.isNotEmpty,
    );
  }

  // ── 播放控制 ─────────────────────────────────────────────────

  void sendChat(String text) {
    final t = text.trim();
    if (t.isEmpty || room == null) return;
    _socket?.emit('chat:message', {'content': t, 'type': 'text'});
  }

  /// 房主：定时广播完整状态
  void broadcastPlay(PlayState state) {
    if (!isHost || room == null) return;
    playState = state;
    _socket?.emit('play:update', state.toJson());
  }

  /// 房主：换片 / 切集
  void changePlay(PlayState state) {
    if (!isHost || room == null) return;
    playState = state;
    _socket?.emit('play:change', state.toJson());
    notifyListeners();
  }

  void sendSeek(double seconds) {
    if (room == null) return;
    _socket?.emit('play:seek', seconds);
  }

  void sendPlay() {
    if (room == null) return;
    _socket?.emit('play:play');
  }

  void sendPause() {
    if (room == null) return;
    _socket?.emit('play:pause');
  }

  /// 房主：清空片源
  void clearPlayback() {
    if (!isHost || room == null) return;
    playState = null;
    notifyListeners();
    _socket?.emitWithAck('state:clear', null, ack: (_) {});
  }

  // ── 工具 ─────────────────────────────────────────────────────

  void _appendSystem(String text) {
    messages = [
      ...messages,
      RoomChatMessage(
        id: 'sys-${DateTime.now().microsecondsSinceEpoch}',
        userId: '',
        userName: '',
        content: text,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        system: true,
      ),
    ];
  }

  void _emit(RoomPlayEvent e) {
    if (!_playEvents.isClosed) _playEvents.add(e);
  }

  @override
  void dispose() {
    _stopHeartbeat();
    try {
      _socket?.dispose();
    } catch (_) {}
    _socket = null;
    _playEvents.close();
    super.dispose();
  }
}
