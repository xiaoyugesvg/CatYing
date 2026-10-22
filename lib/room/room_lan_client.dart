import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 局域网房间客户端：一条 WebSocket，收 JSON 消息。
///
/// [address] 支持：
///   · `192.168.1.5`          → ws://192.168.1.5:9527/ws
///   · `192.168.1.5:9527`     → ws://192.168.1.5:9527/ws
///   · `http://…` / `ws://…`  → 自动换 scheme 并补 `/ws`
class LanRoomClient {
  LanRoomClient({
    required this.address,
    required this.name,
    this.password = '',
    this.hostToken = '',
  });

  static const int defaultPort = 9527;

  final String address;
  final String name;
  final String password;
  final String hostToken;

  WebSocket? _ws;
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get events => _events.stream;

  bool get connected => _ws != null;

  static Uri buildUri(
    String address, {
    required String name,
    String password = '',
    String hostToken = '',
  }) {
    var input = address.trim();
    if (input.isEmpty) throw const FormatException('请填写房间地址');
    input = input.replaceAll(RegExp(r'\s+'), '');
    if (!input.contains('://')) input = 'ws://$input';

    final uri = Uri.parse(input);
    final scheme = uri.scheme == 'https' || uri.scheme == 'wss' ? 'wss' : 'ws';
    var path = uri.path;
    if (path.isEmpty || path == '/') path = '/ws';
    if (!path.endsWith('/ws')) {
      path = path.endsWith('/') ? '${path}ws' : '$path/ws';
    }
    return uri.replace(
      scheme: scheme,
      port: uri.hasPort ? uri.port : defaultPort,
      path: path,
      queryParameters: {
        'name': name,
        if (password.isNotEmpty) 'password': password,
        if (hostToken.isNotEmpty) 'host': hostToken,
      },
    );
  }

  Future<void> connect() async {
    final uri = buildUri(
      address,
      name: name,
      password: password,
      hostToken: hostToken,
    );
    // 局域网地址绝不能走系统代理：代理会把 `Connection: Upgrade` 改写成
    // `close`（实测 Windows 上配了 HTTP_PROXY 时握手必失败）。这里强制直连。
    final direct = HttpClient()..findProxy = (_) => 'DIRECT';
    WebSocket ws;
    try {
      ws = await WebSocket.connect(uri.toString(), customClient: direct)
          .timeout(const Duration(seconds: 10));
    } finally {
      // socket 已交给 WebSocket，关掉 client 只释放连接池
      direct.close(force: false);
    }
    ws.pingInterval = const Duration(seconds: 15);
    _ws = ws;
    ws.listen(
      (frame) {
        if (frame is! String) return;
        try {
          final decoded = jsonDecode(frame);
          if (decoded is Map && !_events.isClosed) {
            _events.add(decoded.cast<String, dynamic>());
          }
        } catch (_) {}
      },
      onDone: () {
        _ws = null;
        // close() 会先关 controller，再收到 onDone —— 不判断会抛
        // "Cannot add new events after calling close"
        if (!_events.isClosed) _events.add({'t': 'closed'});
      },
      onError: (Object e) {
        _ws = null;
        if (!_events.isClosed) _events.add({'t': 'error', 'message': '$e'});
      },
      cancelOnError: true,
    );
  }

  void send(Map<String, dynamic> msg) {
    final ws = _ws;
    if (ws == null) return;
    try {
      ws.add(jsonEncode(msg));
    } catch (_) {}
  }

  Future<void> close() async {
    final ws = _ws;
    _ws = null;
    try {
      await ws?.close();
    } catch (_) {}
    if (!_events.isClosed) await _events.close();
  }
}
