import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'emby_models.dart';

/// Emby 多服务器配置存储（SharedPreferences）。
///
/// 与其它模块一致：变更后立刻写盘，并触发 [notifyListeners]。
class EmbyStore extends ChangeNotifier {
  EmbyStore._();
  static final EmbyStore instance = EmbyStore._();

  static const _kServers = 'emby_servers_v1';
  static const _kActive = 'emby_active_server_v1';
  static const _kDevice = 'emby_device_id_v1';

  final List<EmbyServer> _servers = [];
  List<EmbyServer> get servers => List.unmodifiable(_servers);

  String? _activeId;
  String? get activeId => _activeId;

  EmbyServer? get activeServer {
    if (_servers.isEmpty) return null;
    for (final s in _servers) {
      if (s.id == _activeId) return s;
    }
    return _servers.first;
  }

  String _deviceId = '';
  String get deviceId => _deviceId;

  Future<void>? _loading;

  Future<void> load() => _loading ??= _doLoad();

  Future<void> _doLoad() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _deviceId = prefs.getString(_kDevice) ?? '';
      if (_deviceId.isEmpty) {
        _deviceId = EmbyServer.newDeviceId();
        await prefs.setString(_kDevice, _deviceId);
      }
      final raw = prefs.getString(_kServers);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final e in decoded) {
            if (e is! Map) continue;
            try {
              final s = EmbyServer.fromJson(Map<String, dynamic>.from(e));
              if (s.id.isEmpty) continue;
              // 老记录可能没有 deviceId → 补当前设备 id
              if (s.deviceId.isEmpty) s.deviceId = _deviceId;
              _servers.add(s);
            } catch (_) {}
          }
        }
      }
      _activeId = prefs.getString(_kActive);
    } catch (e) {
      debugPrint('[Emby] 读取配置失败: $e');
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kServers,
        jsonEncode(_servers.map((s) => s.toJson()).toList()),
      );
      if (_activeId != null) {
        await prefs.setString(_kActive, _activeId!);
      } else {
        await prefs.remove(_kActive);
      }
    } catch (e) {
      debugPrint('[Emby] 保存配置失败: $e');
    }
    notifyListeners();
  }

  /// 新增或按 id 覆盖。返回实际保存的服务器。
  Future<EmbyServer> addOrUpdate(EmbyServer server) async {
    await load();
    final idx = _servers.indexWhere((s) => s.id == server.id);
    if (idx >= 0) {
      _servers[idx] = server;
    } else {
      _servers.add(server);
    }
    if (_activeId == null) _activeId = server.id;
    await _persist();
    return server;
  }

  Future<void> remove(String id) async {
    await load();
    _servers.removeWhere((s) => s.id == id);
    if (_activeId == id) {
      _activeId = _servers.isEmpty ? null : _servers.first.id;
    }
    await _persist();
  }

  /// 只改显示名称（不重新登录、不动 token）。
  Future<void> rename(String id, String name) async {
    await load();
    final idx = _servers.indexWhere((s) => s.id == id);
    if (idx < 0) return;
    _servers[idx].name = name.trim();
    await _persist();
  }

  Future<void> setActive(String id) async {
    await load();
    if (!_servers.any((s) => s.id == id)) return;
    _activeId = id;
    await _persist();
  }

  /// 登录成功后写回 token / userId。
  Future<void> updateAuth(
    String id, {
    required String accessToken,
    required String userId,
  }) async {
    await load();
    for (final s in _servers) {
      if (s.id == id) {
        s.accessToken = accessToken;
        s.userId = userId;
        break;
      }
    }
    await _persist();
  }
}
