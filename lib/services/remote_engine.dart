import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 远程引擎按哪一块用（用户 2026-10-25：分开关，各自可选本地/远程）
enum RemoteKind { tg, py, book }

/// 远程引擎（把内置 Node 的活儿交给自己的服务器）
///
/// 三条硬规则（用户明确要求）：
///   1. **默认全关** —— 填了地址 ≠ 启用，必须自己打开总开关才生效；
///   2. 总开关关掉时，App 里任何"引擎/远程"相关界面都不显示；
///   3. 分开关粒度：TG / py 源 / 书源 各自独立，没开的继续走本机。
class RemoteEngine extends ChangeNotifier {
  RemoteEngine._();
  static final RemoteEngine instance = RemoteEngine._();

  static const _kEnabled = 'remote.enabled';
  static const _kBase = 'remote.baseUrl';
  static const _kToken = 'remote.token';
  static const _kUseTg = 'remote.useTg';
  static const _kUsePy = 'remote.usePy';
  static const _kUseBook = 'remote.useBook';

  /// 总开关（默认 false）
  bool enabled = false;
  String baseUrl = '';
  String token = '';
  bool useTg = false;
  bool usePy = false;
  bool useBook = false;

  bool _loaded = false;
  bool get loaded => _loaded;

  /// 归一化后的基址（去掉末尾斜杠）
  String get normalizedBase {
    var b = baseUrl.trim();
    if (b.isEmpty) return '';
    b = b.replaceAll(RegExp(r'/+$'), '');
    if (!b.startsWith('http://') && !b.startsWith('https://')) {
      b = 'http://$b';
    }
    return b;
  }

  /// 这一块要不要走远程。**总开关没开就一律 null**（=走本机）
  String? baseFor(RemoteKind kind) {
    if (!enabled) return null;
    final b = normalizedBase;
    if (b.isEmpty) return null;
    final on = switch (kind) {
      RemoteKind.tg => useTg,
      RemoteKind.py => usePy,
      RemoteKind.book => useBook,
    };
    return on ? b : null;
  }

  Map<String, String> get headers =>
      token.trim().isEmpty ? const {} : {'X-Token': token.trim()};

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      enabled = p.getBool(_kEnabled) ?? false;
      baseUrl = p.getString(_kBase) ?? '';
      token = p.getString(_kToken) ?? '';
      useTg = p.getBool(_kUseTg) ?? false;
      usePy = p.getBool(_kUsePy) ?? false;
      useBook = p.getBool(_kUseBook) ?? false;
    } catch (e) {
      debugPrint('[RemoteEngine] 读取失败: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> save({
    bool? enabled,
    String? baseUrl,
    String? token,
    bool? useTg,
    bool? usePy,
    bool? useBook,
  }) async {
    if (enabled != null) this.enabled = enabled;
    if (baseUrl != null) this.baseUrl = baseUrl.trim();
    if (token != null) this.token = token.trim();
    if (useTg != null) this.useTg = useTg;
    if (usePy != null) this.usePy = usePy;
    if (useBook != null) this.useBook = useBook;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kEnabled, this.enabled);
      await p.setString(_kBase, this.baseUrl);
      await p.setString(_kToken, this.token);
      await p.setBool(_kUseTg, this.useTg);
      await p.setBool(_kUsePy, this.usePy);
      await p.setBool(_kUseBook, this.useBook);
    } catch (e) {
      debugPrint('[RemoteEngine] 保存失败: $e');
    }
    notifyListeners();
  }

  /// 连通性测试
  ///
  /// 分两种结果说清楚，避免"连上了但协议不对"被误判成成功：
  ///   · `/tg` + `tgStatus` 返回带 ok 的 JSON ⇒ **协议匹配**，可以直接用
  ///   · `/api/health` 能通但不是我们的契约 ⇒ **服务在线、协议不匹配**
  Future<({bool ok, String msg})> test() async {
    final b = normalizedBase;
    if (b.isEmpty) return (ok: false, msg: '先填地址');
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 10),
      headers: headers,
    ));
    try {
      final r = await dio.post(
        '$b/tg',
        data: {'action': 'tgStatus'},
        options: Options(
          contentType: Headers.jsonContentType,
          responseType: ResponseType.plain,
          validateStatus: (_) => true,
        ),
      );
      final body = r.data?.toString() ?? '';
      if (r.statusCode == 200) {
        try {
          final m = jsonDecode(body);
          if (m is Map && m.containsKey('ok')) {
            return (
              ok: true,
              msg: '连接成功 · 协议匹配（${r.statusCode}）'
            );
          }
        } catch (_) {}
      }
      return (
        ok: false,
        msg: '连上了但返回不是 Node 源协议（HTTP ${r.statusCode}）'
      );
    } on DioException catch (e) {
      // 退一步探测：是不是 phprun 那种面板（有 /api/health）
      try {
        final h = await dio.get('$b/api/health',
            options: Options(validateStatus: (_) => true));
        if (h.statusCode == 200) {
          return (
            ok: false,
            msg: '能连到服务，但那是面板端口，不是源端口（换 86xx 的任务端口试试）'
          );
        }
      } catch (_) {}
      return (ok: false, msg: _short(e));
    }
  }

  String _short(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
        return '超时：地址不通或被墙';
      case DioExceptionType.connectionError:
        return '连不上：检查地址/端口/是否只监听 127.0.0.1';
      default:
        return e.message ?? '请求失败';
    }
  }
}
