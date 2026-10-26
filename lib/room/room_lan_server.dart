import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:tvbox/room/room_models.dart';

/// 局域网房间服务 —— 房主手机自己当服务器。
///
/// 和 watch-room-server 的差别：
///   · 用 `dart:io` 的 HttpServer + WebSocket，不依赖任何外部部署
///   · 房间只在同一局域网内可见（没有公网房间列表）
///   · 事件语义保持一致：房主广播状态、任何人都能 seek/play/pause
///
/// 线协议（JSON）：
///   → welcome / members / chat / system / state / change / seek / play /
///     pause / cleared / error
///   ← chat / state / change / seek / play / pause / clear
class LanRoomServer {
  LanRoomServer({
    required this.roomName,
    required this.hostName,
    this.password = '',
    this.port = 9527,
  });

  final String roomName;
  final String hostName;
  final String password;
  final int port;

  /// 房主凭证：带它连进来的客户端才被认作房主（房主页自己持有）
  final String hostToken = _randomHex(16);

  final DateTime startedAt = DateTime.now();
  final String roomId = _randomId(6);

  HttpServer? _http;
  StreamSubscription<HttpRequest>? _sub;

  final Map<String, _LanPeer> _peers = {};
  String? _hostCid;

  /// 最近一次房主广播的状态：中途进来的人靠它立刻对齐
  PlayState? _state;

  final List<RoomChatMessage> _history = [];

  bool get isRunning => _http != null;

  Future<void> start() async {
    if (_http != null) return;
    final http = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _http = http;
    _sub = http.listen(_handle, onError: (_) {});
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    for (final p in _peers.values.toList()) {
      try {
        await p.ws.close(4001, '房间已关闭');
      } catch (_) {}
    }
    _peers.clear();
    _hostCid = null;
    final http = _http;
    _http = null;
    try {
      await http?.close(force: true);
    } catch (_) {}
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    if (path == '/info') {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'roomId': roomId,
        'name': roomName,
        'host': hostName,
        'password': password.isNotEmpty,
        'members': _peers.length,
        'startedAt': startedAt.millisecondsSinceEpoch,
      }));
      await req.response.close();
      return;
    }
    if (path != '/ws' || !WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }

    final q = req.uri.queryParameters;
    final isHost = (q['host'] ?? '') == hostToken;
    if (!isHost && password.isNotEmpty && (q['password'] ?? '') != password) {
      final ws = await WebSocketTransformer.upgrade(req);
      ws.add(jsonEncode({'t': 'error', 'message': '房间密码错误'}));
      await ws.close(4003, 'bad password');
      return;
    }

    final ws = await WebSocketTransformer.upgrade(req);
    final rawName = (q['name'] ?? '').trim();
    _attach(ws, rawName.isEmpty ? '访客' : rawName, asHost: isHost);
  }

  void _attach(WebSocket ws, String name, {required bool asHost}) {
    final cid = _randomHex(6);
    if (asHost && _hostCid == null) _hostCid = cid;
    final host = cid == _hostCid;
    _peers[cid] = _LanPeer(ws: ws, name: name);

    ws.add(jsonEncode({
      't': 'welcome',
      'cid': cid,
      'host': host,
      'room': {
        'id': roomId,
        'name': roomName,
        'description': '局域网房间',
        // 不回传明文密码：客户端只需要知道"有没有密码"
        'hasPassword': password.isNotEmpty,
        'isPublic': false,
        'roomType': 'sync',
        'ownerName': hostName,
        'memberCount': _peers.length,
        'createdAt': startedAt.millisecondsSinceEpoch,
        'currentState': _state?.toJson(),
      },
      'members': _memberJson(),
      'history': _history.map((e) => e.toJson()).toList(),
      'state': _state?.toJson(),
    }));

    _broadcast({'t': 'members', 'members': _memberJson()});
    _system('$name 加入了房间');

    ws.listen(
      (data) => _onMessage(cid, data),
      onDone: () => _detach(cid),
      onError: (_) => _detach(cid),
      cancelOnError: true,
    );
  }

  void _detach(String cid) {
    final peer = _peers.remove(cid);
    if (peer == null) return;
    if (_hostCid == cid) _hostCid = null;
    _broadcast({'t': 'members', 'members': _memberJson()});
    _system('${peer.name} 离开了房间');
  }

  void _onMessage(String cid, dynamic raw) {
    final peer = _peers[cid];
    if (peer == null) return;
    Map<String, dynamic> m;
    try {
      final decoded = jsonDecode(raw.toString());
      if (decoded is! Map) return;
      m = decoded.cast<String, dynamic>();
    } catch (_) {
      return;
    }

    final fromHost = cid == _hostCid;
    try {
      _handleMessage(cid, peer, m, fromHost: fromHost);
    } catch (e) {
      // 非本 App 客户端可能发来任意 JSON：单条消息处理失败不能让异常
      // 冒到 WebSocket 回调的 zone（未捕获异常会污染整个房间服务）
      try {
        peer.ws.add(jsonEncode({'t': 'error', 'message': '消息处理失败'}));
      } catch (_) {}
      // ignore: avoid_print
      print('[LanRoom] 消息处理失败: $e');
    }
  }

  void _handleMessage(
    String cid,
    _LanPeer peer,
    Map<String, dynamic> m, {
    required bool fromHost,
  }) {
    switch (m['t']) {
      case 'chat':
        final text = (m['text'] ?? '').toString().trim();
        if (text.isEmpty) return;
        final msg = RoomChatMessage(
          id: '${DateTime.now().microsecondsSinceEpoch}',
          userId: cid,
          userName: peer.name,
          content: text.length > 500 ? text.substring(0, 500) : text,
          timestamp: DateTime.now().millisecondsSinceEpoch,
        );
        _pushHistory(msg);
        _broadcast({'t': 'chat', 'message': msg.toJson()});
        break;
      case 'state':
        if (!fromHost) return;
        final st = m['state'];
        if (st is! Map) return;
        _state = PlayState.fromJson(st.cast<String, dynamic>());
        _broadcast({'t': 'state', 'state': _state!.toJson()}, except: cid);
        break;
      case 'change':
        if (!fromHost) return;
        final st = m['state'];
        if (st is! Map) return;
        _state = PlayState.fromJson(st.cast<String, dynamic>());
        _broadcast({'t': 'change', 'state': _state!.toJson()}, except: cid);
        break;
      case 'seek':
        final sec = (m['seconds'] as num?)?.toDouble() ?? 0;
        _broadcast({'t': 'seek', 'seconds': sec}, except: cid);
        break;
      case 'play':
        _broadcast({'t': 'play'}, except: cid);
        break;
      case 'pause':
        _broadcast({'t': 'pause'}, except: cid);
        break;
      case 'clear':
        if (!fromHost) return;
        _state = null;
        _broadcast({'t': 'cleared'}, except: cid);
        break;
      case 'ping':
        peer.ws.add(jsonEncode({'t': 'pong'}));
        break;
    }
  }

  void _system(String text) {
    final msg = RoomChatMessage(
      id: 'sys-${DateTime.now().microsecondsSinceEpoch}',
      userId: '',
      userName: '',
      content: text,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      system: true,
    );
    _pushHistory(msg);
    _broadcast({'t': 'system', 'text': text});
  }

  void _pushHistory(RoomChatMessage msg) {
    _history.add(msg);
    if (_history.length > 100) _history.removeAt(0);
  }

  List<Map<String, dynamic>> _memberJson() => [
        for (final e in _peers.entries)
          {
            'id': e.key,
            'name': e.value.name,
            'isOwner': e.key == _hostCid,
          },
      ];

  void _broadcast(Map<String, dynamic> msg, {String? except}) {
    final payload = jsonEncode(msg);
    for (final e in _peers.entries) {
      if (e.key == except) continue;
      try {
        e.value.ws.add(payload);
      } catch (_) {}
    }
  }

  /// 本机所有可用的局域网 IPv4（给房主页面展示"让朋友填这个地址"）
  static Future<List<String>> localIPv4() async {
    try {
      final list = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final out = <String>[];
      for (final iface in list) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('169.254.')) continue;
          if (!out.contains(ip)) out.add(ip);
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  static String _randomHex(int bytes) {
    final r = Random.secure();
    final sb = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      sb.write(r.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static String _randomId(int len) {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final r = Random.secure();
    return List.generate(len, (_) => chars[r.nextInt(chars.length)]).join();
  }
}

class _LanPeer {
  _LanPeer({required this.ws, required this.name});
  final WebSocket ws;
  final String name;
}
