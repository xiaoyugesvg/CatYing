// lib/services/python_sources_service.dart
//
// Python 源文件管理 - 用户从仓库导入的 .py 源
// -----------------------------------------------------------------------------
// 目录约定（与 Node 源一致，Documents 可写）：
//   <Documents>/python-project/src/spider/video/<key>.py   影视源
//   <Documents>/python-project/src/spider/book/<key>.py    书源
//
// 内置源（assets/python-project/src/spider/...）随 python-home 打包进 bundle，
// 只读、不需同步；本服务只管「用户导入/编辑」的源：
//   写文件 → call('runner','install_source') 内存注册（reload 语义，立即生效）
//   删文件 → call('runner','remove_source')
//   启动时 → syncToEngine() 全量注册一遍（保证重启后仍可用）

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';
import 'network_manager.dart';
import 'python_manager.dart';

class PythonSourcesService {
  static final PythonSourcesService _instance =
      PythonSourcesService._internal();
  static PythonSourcesService get instance => _instance;

  PythonSourcesService._internal();

  /// 本会话内**已注册进引擎**的源（key = "kind/key"）。
  ///
  /// 用途：`PythonScriptSources` 判断"启动时的 [syncToEngine] 是不是已经把它注册过了"
  /// —— 注册过就不必再写一次文件 + 重新编译一遍模块。
  final Set<String> _registered = {};

  bool isRegisteredInSession(String kind, String key) =>
      _registered.contains('$kind/$key');

  /// 源根目录：<Documents>/python-project/src/spider
  Future<Directory> _spiderRoot() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/python-project/src/spider');
  }

  Directory _kindDir(String kind, Directory root) =>
      Directory('${root.path}/$kind');

  /// 列出本地已存在的 Python 源文件（不含内置 bundle 源）
  Future<List<({String kind, String key})>> listLocalSources() async {
    final root = await _spiderRoot();
    if (!await root.exists()) return [];
    final out = <({String kind, String key})>[];
    for (final kind in ['video', 'book']) {
      final dir = _kindDir(kind, root);
      if (!await dir.exists()) continue;
      await for (final f in dir.list()) {
        if (f is File && f.path.endsWith('.py')) {
          final name = f.uri.pathSegments.last;
          final key = name.substring(0, name.length - 3);
          if (key.isNotEmpty) {
            out.add((kind: kind, key: key));
          }
        }
      }
    }
    return out;
  }

  /// 启动同步：把 Documents 下所有 .py 源注册进 Python 引擎
  Future<void> syncToEngine() async {
    if (!PythonManager.instance.isIOS) return;
    final items = await listLocalSources();
    for (final item in items) {
      final code = await readSource(item.kind, item.key);
      if (code == null) continue;
      final r = await PythonManager.instance.call(
        'runner',
        'install_source',
        {'kind': item.kind, 'key': item.key, 'code': code},
      );
      if (!r.ok) {
        AppLog.instance.w('[Python] 源注册失败 ${item.kind}/${item.key}: ${r.error}');
      } else {
        _registered.add('${item.kind}/${item.key}');
      }
    }
    if (items.isNotEmpty) {
      AppLog.instance.log('[Python] 已同步 ${items.length} 个用户 Python 源');
    }
  }

  /// 读源文件内容
  Future<String?> readSource(String kind, String key) async {
    final root = await _spiderRoot();
    final file = File('${_kindDir(kind, root).path}/$key.py');
    if (!await file.exists()) return null;
    try {
      return await file.readAsString();
    } catch (e) {
      AppLog.instance.w('[Python] 读源失败 $kind/$key: $e');
      return null;
    }
  }

  /// 按源地址计算 key：`psrc_<md5(url) 前 12 位>`（同一 URL 恒同 key）。
  static String keyForUrl(String url) {
    final h = md5.convert(utf8.encode(url.trim())).toString();
    return 'psrc_${h.substring(0, 12)}';
  }

  /// 确保某个 .py 源（由 [url] 指定）已落盘并注册进引擎，返回模块 key；
  /// 失败返回 null。已有本地缓存直接用，没有才去 [url] 下载 ——
  /// 书源侧的 `pythonKey` 缺省时靠它把「带 .py 地址的书源」接进 CPython。
  Future<String?> ensureInstalled(String url, String kind) async {
    final u = url.trim();
    if (u.isEmpty) return null;
    final key = keyForUrl(u);
    if (isRegisteredInSession(kind, key)) return key;
    if (!PythonManager.instance.isIOS) return null;
    if (!await PythonManager.instance.ensureStarted()) {
      AppLog.instance.w('[Python] 引擎未就绪，无法注册 $u');
      return null;
    }
    var code = await readSource(kind, key);
    if (code == null || code.trim().isEmpty) {
      try {
        code = await NetworkManager.instance.getString(u);
      } catch (e) {
        AppLog.instance.w('[Python] 脚本下载失败 $u: $e');
        return null;
      }
      if (code.trim().isEmpty) return null;
    }
    final r = await installSource(kind, key, code);
    if (!r.ok) {
      AppLog.instance.w('[Python] 注册失败 $u: ${r.message}');
      return null;
    }
    AppLog.instance.log('[Python] 已就绪 $kind/$key ← $u');
    return key;
  }

  /// 写入并注册一个 Python 源（新建或更新）
  /// 返回 (ok, message)
  Future<({bool ok, String? message})> installSource(
    String kind,
    String key,
    String code,
  ) async {
    if (!PythonManager.instance.isIOS) {
      return (ok: false, message: 'Python 引擎仅支持 iOS');
    }
    final root = await _spiderRoot();
    final dir = _kindDir(kind, root);
    try {
      await dir.create(recursive: true);
      final file = File('${dir.path}/$key.py');
      await file.writeAsString(code, flush: true);
    } catch (e) {
      return (ok: false, message: '写文件失败: $e');
    }
    final r = await PythonManager.instance.call(
      'runner',
      'install_source',
      {'kind': kind, 'key': key, 'code': code},
    );
    if (!r.ok) {
      return (ok: false, message: r.error ?? '注册失败');
    }
    final detail = r.json as Map<String, dynamic>?;
    if (detail?['ok'] != true) {
      return (ok: false, message: detail?['message'] as String? ?? '注册失败');
    }
    _registered.add('$kind/$key');
    return (ok: true, message: null);
  }

  /// 删除并卸载一个 Python 源
  Future<({bool ok, String? message})> removeSource(String kind, String key) async {
    final root = await _spiderRoot();
    final file = File('${_kindDir(kind, root).path}/$key.py');
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      return (ok: false, message: '删文件失败: $e');
    }
    final r = await PythonManager.instance.call(
      'runner',
      'remove_source',
      {'kind': kind, 'key': key},
    );
    if (!r.ok) {
      return (ok: false, message: r.error ?? '卸载失败');
    }
    _registered.remove('$kind/$key');
    return (ok: true, message: null);
  }
}
