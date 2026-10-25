import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'app_log.dart';

/// 一个站点的 Cloudflare 会话（`cf_clearance` + 同域其他 cookie）
class CfEntry {
  const CfEntry({
    required this.cookies,
    required this.ua,
    required this.savedAt,
  });

  final Map<String, String> cookies;

  /// 验证时用的 User-Agent。
  ///
  /// ⚠️ `cf_clearance` **与 UA + 出口 IP 绑定**：验证用什么 UA，后续请求就必须
  /// 用什么 UA，否则 CF 判定不匹配 → 依然 403。所以这里必须存下来，
  /// 由 [CfSession.userAgent] 统一回给爬虫。
  final String ua;

  /// 保存时间（毫秒）。仅用于展示"几天前验证的"，不作为硬过期依据
  /// —— CF 的通行证有效期由服务端说了算，本地猜不准，靠 403 探测失效。
  final int savedAt;

  Map<String, dynamic> toJson() => {
    'cookies': cookies,
    'ua': ua,
    'savedAt': savedAt,
  };

  static CfEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final ck = raw['cookies'];
    if (ck is! Map) return null;
    return CfEntry(
      cookies: ck.map((k, v) => MapEntry('$k', '$v')),
      ua: (raw['ua'] as String?) ?? CfSession.defaultUa,
      savedAt: (raw['savedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Cloudflare 会话缓存（**用户手动验证一次，之后自动复用**）。
///
/// 设计目标（用户 2026-10-25 要求）：
///   · 只在"没有可用 cookie / 已失效"时才弹验证页，**绝不每次请求都弹**；
///   · 验证结果落盘，跨重启、跨模块共用；
///   · Python 侧直接读同一个 JSON 文件注入 —— 不改任何 py 源脚本。
///
/// 落盘位置：`<Documents>/nodejs-project/runtime/cf_cookies.json`
/// （与 AppLog 的 runtime 目录一致，Python 侧可用 `~/Documents/...` 直接读到）
class CfSession {
  CfSession._();
  static final CfSession instance = CfSession._();

  /// 统一 UA：验证页与爬虫必须一致（cf_clearance 绑定 UA）
  static const String defaultUa =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) '
      'Version/17.0 Mobile/15E148 Safari/604.1';

  static const String _fileName = 'cf_cookies.json';

  final Map<String, CfEntry> _cache = <String, CfEntry>{};
  bool _loaded = false;
  File? _file;

  /// 供 Python 侧读取的绝对路径（写入时也用它）
  String? get filePath => _file?.path;

  Future<File?> _ensureFile() async {
    if (_file != null) return _file;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/nodejs-project/runtime');
      if (!await dir.exists()) await dir.create(recursive: true);
      _file = File('${dir.path}/$_fileName');
      return _file;
    } catch (e) {
      AppLog.instance.log('[CfSession] 初始化目录失败: $e');
      return null;
    }
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    final f = await _ensureFile();
    if (f == null || !await f.exists()) return;
    try {
      final raw = jsonDecode(await f.readAsString());
      if (raw is Map && raw['hosts'] is Map) {
        (raw['hosts'] as Map).forEach((k, v) {
          final e = CfEntry.fromJson(v);
          if (e != null && e.cookies.isNotEmpty) _cache['$k'] = e;
        });
      }
      AppLog.instance.log('[CfSession] 已加载 ${_cache.length} 个站点会话');
    } catch (e) {
      AppLog.instance.log('[CfSession] 读取缓存失败: $e');
    }
  }

  /// 原子写盘（先写临时文件再 rename），避免 Python 侧读到半个 JSON
  Future<void> _persist() async {
    final f = await _ensureFile();
    if (f == null) return;
    try {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'version': 1,
          'hosts': _cache.map((k, v) => MapEntry(k, v.toJson())),
        }),
        flush: true,
      );
      await tmp.rename(f.path);
    } catch (e) {
      AppLog.instance.log('[CfSession] 写缓存失败: $e');
    }
  }

  /// 从任意 URL / 裸 host 里取规范化的 host（小写、去端口）
  static String hostOf(String urlOrHost) {
    var s = urlOrHost.trim();
    if (s.isEmpty) return '';
    if (!s.contains('://')) s = 'https://$s';
    final u = Uri.tryParse(s);
    if (u == null) return '';
    return u.host.toLowerCase();
  }

  /// 该 host 是否有缓存会话
  Future<bool> has(String host) async {
    await _ensureLoaded();
    return _cache[host.toLowerCase()] != null;
  }

  /// 取 Cookie 请求头值（无缓存 → 空串）
  Future<String> cookieHeader(String host) async {
    await _ensureLoaded();
    final e = _cache[host.toLowerCase()];
    if (e == null || e.cookies.isEmpty) return '';
    return e.cookies.entries.map((x) => '${x.key}=${x.value}').join('; ');
  }

  /// 取该 host 应使用的 UA（无缓存 → [defaultUa]）
  Future<String> userAgent(String host) async {
    await _ensureLoaded();
    return _cache[host.toLowerCase()]?.ua ?? defaultUa;
  }

  /// 保存一次用户验证结果
  Future<void> save(
    String host,
    Map<String, String> cookies, {
    String? ua,
  }) async {
    final h = host.toLowerCase();
    if (h.isEmpty || cookies.isEmpty) return;
    await _ensureLoaded();
    _cache[h] = CfEntry(
      cookies: cookies,
      ua: ua ?? defaultUa,
      savedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _persist();
    AppLog.instance.log('[CfSession] 已保存 $h 的 ${cookies.length} 个 cookie');
  }

  /// 标记失效（收到 403 挑战时调用）。只删该 host，不影响其他站点。
  Future<void> invalidate(String host) async {
    final h = host.toLowerCase();
    await _ensureLoaded();
    if (_cache.remove(h) == null) return;
    await _persist();
    AppLog.instance.log('[CfSession] 已失效 $h');
  }

  /// 已缓存的站点列表（给"设置 → 验证过的站点"用）
  Future<List<String>> hosts() async {
    await _ensureLoaded();
    return _cache.keys.toList()..sort();
  }

  /// 该 host 的验证时间（null = 没有）
  Future<DateTime?> savedAt(String host) async {
    await _ensureLoaded();
    final t = _cache[host.toLowerCase()]?.savedAt ?? 0;
    return t > 0 ? DateTime.fromMillisecondsSinceEpoch(t) : null;
  }

  Future<void> clearAll() async {
    await _ensureLoaded();
    _cache.clear();
    await _persist();
  }
}
