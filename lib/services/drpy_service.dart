import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import 'app_log.dart';
import 'dio_factory.dart';
import 'nodejs_manager.dart';

/// drpy 标准源（TVBox `type:3` + `api=drpy2.min.js` + `ext=站点.js`）。
///
/// ── 为什么单独一层 ─────────────────────────────────────────────
/// drpy 的 `api` 只是**规则运行时**（一个 ESM 模块），不是能独立运行的
/// spider 服务；`ext` 才是站点规则。直接 `NodeJSManager.loadSource(api)`
/// 只会把运行时当整包源加载 → 没有 `/config`、没有 `/spider/...` → 线路全废。
///
/// 这里负责：
///   1. 下载运行时与站点脚本（Dart 侧下载，规避 Node 网络栈/鉴权差异）；
///   2. 随包读取模板库（模板继承 `模板:'mxpro'` 需要）；
///   3. POST 到 Node 的 `/drpy/load`，由 `drpy_host.js` 包成标准 CatVod 服务。
class DrpyService {
  DrpyService._();
  static final DrpyService instance = DrpyService._();

  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  final Dio _dio = buildDioWithDns(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 60),
  );

  static String? _runtimeAsset;
  static String? _mubanAsset;

  /// 去掉配置里常见的反引号/引号包裹
  static String _clean(String s) {
    var v = s.trim();
    const wraps = ['`', '"', "'"];
    while (v.isNotEmpty && wraps.contains(v[0])) {
      v = v.substring(1).trim();
    }
    while (v.isNotEmpty && wraps.contains(v[v.length - 1])) {
      v = v.substring(0, v.length - 1).trim();
    }
    return v;
  }

  /// 判断是不是 drpy 标准源。
  ///
  /// 认 `drpy2.min.js` / `drpy.min.js` / 路径里带 `drpy2` 的运行时；
  /// `ext` 必须非空（站点规则）。
  static bool isDrpySource(String api, String ext) {
    final a = _clean(api).toLowerCase();
    final e = _clean(ext);
    if (e.isEmpty) return false;
    // 运行时常见写法：drpy2.min.js / drpy.min.js / drpy3.min.js / libs/drpy2
    return a.contains('drpy');
  }

  /// 站点脚本的绝对地址（相对路径按 api 解析）
  static String resolveExt(String api, String ext) {
    final e = _clean(ext);
    if (e.isEmpty) return '';
    if (e.startsWith('http://') || e.startsWith('https://')) return e;
    try {
      return Uri.parse(_clean(api)).resolve(e).toString();
    } catch (_) {
      return e;
    }
  }

  Future<String> _readAsset(String key) async {
    try {
      return await rootBundle.loadString(key);
    } catch (e) {
      AppLog.instance.w('[drpy] 读取内置资源失败 $key: $e');
      return '';
    }
  }

  Future<String> _runtimeText() async {
    final cached = _runtimeAsset;
    if (cached != null && cached.isNotEmpty) return cached;
    final s = await _readAsset('assets/drpy/drpy2.min.js');
    _runtimeAsset = s;
    return s;
  }

  Future<String> _mubanText() async {
    final cached = _mubanAsset;
    if (cached != null) return cached;
    final s = await _readAsset('assets/drpy/muban.js');
    _mubanAsset = s;
    return s;
  }

  /// 下载文本（支持 URL 里的 `user:pass@` → Basic 鉴权）
  Future<String?> _download(String url) async {
    final u = _clean(url);
    if (u.isEmpty) return null;
    var target = u;
    final headers = <String, String>{
      'User-Agent': _ua,
      'Accept': '*/*',
    };
    try {
      final uri = Uri.parse(u);
      if (uri.userInfo.isNotEmpty) {
        headers['Authorization'] =
            'Basic ' + base64Encode(utf8.encode(uri.userInfo));
        target = uri.replace(userInfo: '').toString();
      }
    } catch (_) { /* 保留原地址 */ }
    try {
      final r = await _dio.get<List<int>>(
        target,
        options: Options(
          responseType: ResponseType.bytes,
          headers: headers,
          followRedirects: true,
          validateStatus: (s) => s != null && s >= 200 && s < 300,
        ),
      );
      final data = r.data;
      if (data == null || data.isEmpty) return null;
      return utf8.decode(data, allowMalformed: true);
    } catch (e) {
      AppLog.instance.w('[drpy] 下载失败 $target: $e');
      return null;
    }
  }

  /// 载入一个 drpy 源；成功后 Node 的 spider 端口会指向新服务。
  Future<({bool ok, String? error, String key, int port})> load({
    required String api,
    required String ext,
    required String key,
    String name = '',
  }) async {
    final extUrl = resolveExt(api, ext);
    if (extUrl.isEmpty) {
      return (ok: false, error: 'drpy 源缺少 ext 站点规则', key: '', port: 0);
    }
    final mgmt = NodeJSManager.instance.managementPort;
    if (mgmt <= 0) {
      return (ok: false, error: 'Node 管理端口未就绪', key: '', port: 0);
    }

    // 运行时可远程更新；下载失败退回随包版本（保证离线也能用）
    final remoteRuntime = await _download(_clean(api));
    final runtime = (remoteRuntime != null && remoteRuntime.trim().isNotEmpty)
        ? remoteRuntime
        : await _runtimeText();
    if (runtime.trim().isEmpty) {
      return (
        ok: false,
        error: 'drpy 运行时加载失败（内置资源缺失）',
        key: '',
        port: 0,
      );
    }

    final extText = await _download(extUrl);
    if (extText == null || extText.trim().isEmpty) {
      return (ok: false, error: '站点规则下载失败：$extUrl', key: '', port: 0);
    }

    final data = <String, dynamic>{
      'runtimeText': runtime,
      'extText': extText,
      'mubanText': await _mubanText(),
      'key': key.trim().isEmpty ? 'drpy' : key.trim(),
      'name': name,
      'dataDir': await NodeJSManager.instance.getDocumentsSourcePath(),
    };

    try {
      final resp = await _dio.post<String>(
        'http://127.0.0.1:$mgmt/drpy/load',
        data: jsonEncode(data),
        options: Options(
          contentType: Headers.jsonContentType,
          responseType: ResponseType.plain,
          receiveTimeout: const Duration(seconds: 90),
        ),
      );
      final raw = resp.data ?? '';
      final m = jsonDecode(raw);
      if (m is Map && m['ok'] == true) {
        final k = (m['key'] ?? data['key']).toString();
        final port = (m['port'] as num?)?.toInt() ?? 0;
        AppLog.instance.log('[drpy] 已载入 $extUrl（key=$k, port=$port）');
        return (ok: true, error: null, key: k, port: port);
      }
      final err = (m is Map ? m['error'] : null)?.toString() ?? '未知错误';
      return (ok: false, error: err, key: '', port: 0);
    } catch (e) {
      return (ok: false, error: 'drpy 载入请求失败：$e', key: '', port: 0);
    }
  }
}
