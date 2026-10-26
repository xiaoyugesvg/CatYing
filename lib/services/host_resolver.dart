// lib/services/host_resolver.dart
//
// 把 TVBox 配置里的 `hosts`（域名→IP 覆盖表）与 `doh`（DoH 服务器）真正接到
// 网络层的 DNS 解析上。
//
// - hosts 覆盖：命中即返回，等价于系统 hosts 文件
// - DoH：用 JSON 接口（`https://<doh-host>/dns-query?name=...&type=A`，
//   带 `accept: application/dns-json`）解析 A 记录
// - 都没有 / 失败 → 返回 null，调用方（socket connectionFactory）回退系统 DNS
//
// 线程安全：同一 host 并发只发一次 DoH 请求（_inflight 去重），结果带 TTL 缓存。
import 'dart:async';

import 'package:dio/dio.dart';

import 'package:tvbox/models/app_config.dart';
import 'package:tvbox/services/app_log.dart';

class _CacheEntry {
  final String ip;
  final DateTime expireAt;
  _CacheEntry(this.ip, this.expireAt);

  bool get expired => DateTime.now().isAfter(expireAt);
}

class HostResolver {
  HostResolver._internal();
  static final HostResolver instance = HostResolver._internal();

  /// 解析结果内存缓存 TTL
  static const Duration _cacheTtl = Duration(minutes: 10);

  /// DoH 请求超时
  static const Duration _dohTimeout = Duration(seconds: 5);

  /// hosts 覆盖表（域名小写 → IP）
  final Map<String, String> _hosts = {};

  /// DoH 服务器地址（仅 host，如 dns.google）
  final List<String> _dohServers = [];

  /// 成功解析的缓存
  final Map<String, _CacheEntry> _cache = {};

  /// 同一 host 的进行中请求（去重）
  final Map<String, Future<String?>> _inflight = {};

  /// 是否配置了任何规则。没有时调用方可直接跳过，保证零行为变化。
  bool get hasRules => _hosts.isNotEmpty || _dohServers.isNotEmpty;

  /// 载入规则（通常在配置解析时调用一次）。重复调用会整体替换。
  void load({List<String>? hosts, List<DoHConfig>? doh}) {
    _hosts.clear();
    _dohServers.clear();
    _cache.clear();
    _inflight.clear();

    if (hosts != null) {
      for (final raw in hosts) {
        _parseHostLine(raw);
      }
    }
    if (doh != null) {
      for (final d in doh) {
        final host = _dohHostFromUrl(d.url);
        if (host != null && host.isNotEmpty && !_dohServers.contains(host)) {
          _dohServers.add(host);
        }
      }
    }
    AppLog.instance.log(
        '[DNS] rules loaded: hosts=${_hosts.length}, doh=${_dohServers.length}');
  }

  /// 只查 hosts 覆盖表，**绝不触发 DoH**（同步、零副作用）。
  ///
  /// 给 [shouldUseSystemDns] 为 true 的 host 用：既能享受用户手写的 hosts
  /// 覆盖，又不会在连接 DoH 服务器自身时再次发起 DoH 查询。
  String? lookupHosts(String host) {
    final h = host.trim();
    if (h.isEmpty) return null;
    final ip = _hosts[h.toLowerCase()];
    return (ip == null || ip.isEmpty) ? null : ip;
  }

  /// 该 host 是否应该**跳过** hosts/DoH 覆盖，直接走系统 DNS。
  ///
  /// 三类必须放行（否则会出问题，不是优化）：
  /// 1. **回环地址**（`localhost` / `127.x` / `::1`）——本机 Node spider、
  ///    drpy 宿主、内嵌 python 服务都跑在回环上，任何改写都会连不上；
  /// 2. **IP 字面量**——本来就没有解析这一步，改写无意义；
  /// 3. **DoH 服务器自己的域名**——`resolve()` 内部要发 DoH 请求，
  ///    而那个请求的连接同样会走本解析器 → 不加这条会 **自递归死锁**
  ///    （外层 `_inflight` 等待内层，内层又等待外层同一个 future）。
  bool shouldUseSystemDns(String host) {
    final h = host.trim().toLowerCase();
    if (h.isEmpty || h == 'localhost') return true;
    if (h.startsWith('127.')) return true;
    if (h == '::1' || h == '[::1]' || h == '0.0.0.0') return true;
    if (_isIp(h)) return true;
    for (final server in _dohServers) {
      if (server.toLowerCase() == h) return true;
    }
    return false;
  }

  /// 解析 host：先查 hosts 覆盖 → 再查缓存 → 再走 DoH；都没有/失败返回 null。
  Future<String?> resolve(String host) async {
    final h = host.trim();
    if (h.isEmpty) return null;
    final key = h.toLowerCase();

    // 1) hosts 覆盖表
    final overridden = _hosts[key];
    if (overridden != null && overridden.isNotEmpty) {
      AppLog.instance.log('[DNS] hosts hit $h -> $overridden');
      return overridden;
    }

    // 没有 DoH 服务器时无法继续（返回 null → 系统 DNS）
    if (_dohServers.isEmpty) return null;

    // 2) 内存缓存
    final cached = _cache[key];
    if (cached != null && !cached.expired) {
      return cached.ip;
    }

    // 3) DoH（并发去重）
    final existing = _inflight[key];
    if (existing != null) return existing;

    final future = _resolveViaDoh(h, key);
    _inflight[key] = future;
    return future;
  }

  Future<String?> _resolveViaDoh(String host, String key) async {
    final dio = Dio(BaseOptions(
      connectTimeout: _dohTimeout,
      receiveTimeout: _dohTimeout,
      headers: {'accept': 'application/dns-json'},
    ));
    try {
      for (final server in _dohServers) {
        try {
          final url = 'https://$server/dns-query'
              '?name=${Uri.encodeQueryComponent(host)}&type=A';
          final res = await dio.get<dynamic>(
            url,
            options: Options(
              responseType: ResponseType.json,
              validateStatus: (s) => s != null && s >= 200 && s < 300,
            ),
          );
          final ip = _extractA(res.data);
          if (ip != null && ip.isNotEmpty) {
            _cache[key] = _CacheEntry(ip, DateTime.now().add(_cacheTtl));
            AppLog.instance.log('[DNS] doh resolved $host -> $ip (via $server)');
            return ip;
          }
        } catch (e) {
          AppLog.instance.log('[DNS] doh $server failed for $host: $e');
        }
      }
      AppLog.instance.log('[DNS] doh all servers failed for $host');
      return null;
    } finally {
      dio.close(force: true);
      _inflight.remove(key);
    }
  }

  /// 从 DoH JSON 响应里取第一条 A 记录（type==1）的 data。
  static String? _extractA(dynamic data) {
    if (data is! Map) return null;
    final answers = data['Answer'] ?? data['answer'];
    if (answers is! List) return null;
    for (final a in answers) {
      if (a is! Map) continue;
      final type = a['type'] ?? a['Type'];
      final t = type is int ? type : int.tryParse('$type');
      if (t != 1) continue;
      final d = a['data'] ?? a['Data'];
      if (d is String && d.isNotEmpty) return d;
    }
    return null;
  }

  /// 解析一行 hosts。支持：
  ///   · `域名:IP`（TVBox 常见，如 `raw.githubusercontent.com:185.199.108.133`）
  ///   · `IP 域名`（空格分隔，如 `185.199.108.133 raw.githubusercontent.com`）
  ///   · `IP:域名`（冒号分隔，IP 在前）
  void _parseHostLine(String raw) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) return;

    String left;
    String right;
    if (line.contains(RegExp(r'\s'))) {
      final parts =
          line.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
      if (parts.length < 2) return;
      left = parts[0];
      right = parts[1];
    } else {
      final idx = line.indexOf(':');
      if (idx <= 0) return;
      left = line.substring(0, idx).trim();
      right = line.substring(idx + 1).trim();
    }
    if (left.isEmpty || right.isEmpty) return;

    final leftIsIp = _isIp(left);
    final rightIsIp = _isIp(right);

    String domain;
    String ip;
    if (leftIsIp && !rightIsIp) {
      ip = left;
      domain = right;
    } else if (rightIsIp && !leftIsIp) {
      domain = left;
      ip = right;
    } else {
      // 两边都是域名 / 都是 IP → 无法判定，忽略
      return;
    }
    _hosts[domain.toLowerCase()] = ip;
  }

  /// 粗略判断是否 IP 字面量（IPv4 / IPv6）。
  static bool _isIp(String s) {
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(s)) return true;
    if (s.contains(':')) return true; // IPv6
    return false;
  }

  /// 从 DoH url 里取服务器 host（如 `https://dns.google/dns-query` → `dns.google`）。
  static String? _dohHostFromUrl(String? url) {
    final u = (url ?? '').trim();
    if (u.isEmpty) return null;
    var parsed = Uri.tryParse(u);
    if (parsed == null || parsed.host.isEmpty) {
      parsed = Uri.tryParse('https://$u');
    }
    if (parsed == null || parsed.host.isEmpty) return null;
    return parsed.host;
  }
}
