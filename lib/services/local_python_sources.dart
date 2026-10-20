import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/local_python_source.dart';
import 'app_log.dart';
import 'python_manager.dart';
import 'python_sources_service.dart';

/// 「本地 Python 源」的落盘与注册。
///
/// 目录（用户 2026-10-18：本地源单独放一个可自己拷贝脚本的文件夹）：
///   <Documents>/local_py/local_video_sources.json   ← 清单（显示名/导入时间/使用次数）
///   <Documents>/local_py/lp_*.py                    ← 脚本本体
///
/// 为什么不再放 `<Documents>/python-project/src/spider/video/`：
///   那个目录是「订阅/远端 py 源」的落盘位置，启动时由
///   [PythonSourcesService.syncToEngine] 全量扫描；本地源混在里面既容易被
///   订阅流程影响，也不方便用户自己拷贝脚本。现在本地源只从 `local_py/`
///   读取并单独注册，重启后由 [registerAll] 保证重新挂回引擎。
///
/// 设计要点（用户 2026-10-17）：
///   · 一条脚本一个 key，单独增删，不写进订阅 sites；
///   · 全部本地源在源切换面板里单独成组，不跟订阅线路混在一起；
///   · 清单与订阅解耦：换订阅/重启都不会丢。
class LocalPythonSources {
  static final LocalPythonSources _instance = LocalPythonSources._internal();
  static LocalPythonSources get instance => _instance;
  LocalPythonSources._internal();

  final List<LocalPythonSource> _sources = [];
  bool _loaded = false;

  List<LocalPythonSource> get sources => List.unmodifiable(_sources);
  bool get hasAny => _sources.isNotEmpty;

  /// 本地源根目录：<Documents>/local_py（用户可直接把 .py 拷进来）
  Future<Directory> directory() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/local_py');
  }

  /// 旧版目录（兼容迁移）：<Documents>/python-project/src/spider/video
  Future<Directory> _legacyDir() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/python-project/src/spider/video');
  }

  Future<File> _manifest() async {
    final dir = await directory();
    return File('${dir.path}/local_video_sources.json');
  }

  /// 读取清单 + 与磁盘对账。
  ///
  /// 对账规则：
  ///   · 清单里有、文件没了 → 丢掉（用户可能在别处删了）；
  ///   · 目录里有 `lp_*.py`、清单里没有 → 补进来（老数据/手动拷入）。
  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    _loaded = true;
    _sources.clear();

    final dir = await directory();
    if (!await dir.exists()) await dir.create(recursive: true);

    // 旧版把 lp_*.py 放在 python-project/src/spider/video：首次启动搬过来，
    // 避免用户升级后本地源全部消失。
    await _migrateLegacy(dir);

    final file = await _manifest();
    if (await file.exists()) {
      try {
        final raw = jsonDecode(await file.readAsString());
        if (raw is List) {
          for (final e in raw) {
            if (e is! Map) continue;
            final s = LocalPythonSource.fromJson(Map<String, dynamic>.from(e));
            if (s.key.isEmpty) continue;
            if (!await File('${dir.path}/${s.key}.py').exists()) continue;
            if (_sources.any((x) => x.key == s.key)) continue;
            _sources.add(s);
          }
        }
      } catch (e) {
        AppLog.instance.w('[LocalPy] 清单解析失败: $e');
      }
    }

    try {
      await for (final f in dir.list()) {
        if (f is! File || !f.path.endsWith('.py')) continue;
        final name = f.uri.pathSegments.last;
        final key = name.substring(0, name.length - 3);
        if (!key.startsWith('lp_')) continue;
        if (_sources.any((x) => x.key == key)) continue;
        _sources.add(
          LocalPythonSource(
            key: key,
            name: key,
            addedAt: f.statSync().modified.millisecondsSinceEpoch,
          ),
        );
      }
    } catch (e) {
      AppLog.instance.w('[LocalPy] 扫描目录失败: $e');
    }

    await _applyOrder();
    await _save();
  }

  static const String _kOrder = 'local_py_order_v1';
  List<String> _order = const [];

  /// 应用用户拖动出来的顺序（没排过的按导入时间）。
  Future<void> _applyOrder() async {
    try {
      final p = await SharedPreferences.getInstance();
      _order = p.getStringList(_kOrder) ?? const [];
    } catch (_) {
      _order = const [];
    }
    if (_order.isEmpty) {
      _sources.sort((a, b) => a.addedAt.compareTo(b.addedAt));
      return;
    }
    final idx = {for (var i = 0; i < _order.length; i++) _order[i]: i};
    _sources.sort((a, b) {
      final ia = idx[a.key];
      final ib = idx[b.key];
      if (ia != null && ib != null) return ia.compareTo(ib);
      if (ia != null) return -1;
      if (ib != null) return 1;
      return a.addedAt.compareTo(b.addedAt);
    });
  }

  /// 只重排传入的这批源（搜索/筛选时不影响其它源），并持久化顺序。
  Future<void> reorderWithin(List<String> visibleKeys) async {
    if (visibleKeys.isEmpty) return;
    final wanted = visibleKeys.toSet();
    final byKey = {for (final s in _sources) s.key: s};
    final queue = List<String>.from(visibleKeys);
    final next = <LocalPythonSource>[];
    var qi = 0;
    for (final s in _sources) {
      if (wanted.contains(s.key)) {
        final moved = byKey[queue[qi++]];
        if (moved != null) next.add(moved);
      } else {
        next.add(s);
      }
    }
    if (next.length != _sources.length) return;
    _sources
      ..clear()
      ..addAll(next);
    _order = _sources.map((s) => s.key).toList();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(_kOrder, _order);
    } catch (_) {}
    await _save();
  }

  /// 把旧目录里的 lp_*.py（含清单）搬到新目录。
  Future<void> _migrateLegacy(Directory target) async {
    try {
      final old = await _legacyDir();
      if (!await old.exists()) return;
      await for (final f in old.list()) {
        if (f is! File) continue;
        final name = f.uri.pathSegments.last;
        if (!name.startsWith('lp_') || !name.endsWith('.py')) continue;
        final dest = File('${target.path}/$name');
        if (await dest.exists()) continue;
        await f.copy(dest.path);
        // 迁移成功后删掉旧副本：否则 python-project 的启动同步会再注册一次同名模块
        try {
          await f.delete();
        } catch (_) {}
        AppLog.instance.log('[LocalPy] 已迁移旧本地源 $name');
      }
      // 旧清单：<Documents>/python-project/local_video_sources.json
      final docs = await getApplicationDocumentsDirectory();
      final oldManifest = File(
        '${docs.path}/python-project/local_video_sources.json',
      );
      final newManifest = File('${target.path}/local_video_sources.json');
      if (await oldManifest.exists() && !await newManifest.exists()) {
        await oldManifest.copy(newManifest.path);
      }
    } catch (e) {
      AppLog.instance.w('[LocalPy] 旧目录迁移失败: $e');
    }
  }

  /// 导入一个 .py 文件。成功返回新建的源。
  Future<({bool ok, String? message, LocalPythonSource? source})> importFile(
    String path, {
    String? displayName,
  }) async {
    try {
      final f = File(path);
      if (!await f.exists()) {
        return (ok: false, message: '文件不存在', source: null);
      }
      var name = displayName ?? f.uri.pathSegments.last;
      final code = await f.readAsString();
      return await importCode(code, displayName: name);
    } catch (e) {
      AppLog.instance.w('[LocalPy] 读取文件失败: $e');
      return (ok: false, message: e.toString(), source: null);
    }
  }

  /// 直接按字节导入（iOS 文件选择器给的是 bytes，path 可能为 null）
  Future<({bool ok, String? message, LocalPythonSource? source})> importBytes(
    List<int> bytes, {
    String? displayName,
  }) {
    return importCode(
      utf8.decode(bytes, allowMalformed: true),
      displayName: displayName,
    );
  }

  /// 按脚本文本导入（核心逻辑）
  ///
  /// [save] = false 用于批量导入：循环里不反复写清单，最后统一落一次盘。
  Future<({bool ok, String? message, LocalPythonSource? source})> importCode(
    String code, {
    String? displayName,
    bool save = true,
  }) async {
    try {
      if (code.trim().isEmpty) {
        return (ok: false, message: '脚本内容为空', source: null);
      }
      if (!PythonManager.instance.isIOS) {
        return (ok: false, message: 'Python 引擎仅支持 iOS', source: null);
      }
      if (!await PythonManager.instance.ensureStarted()) {
        return (
          ok: false,
          message:
              'Python 引擎启动失败（${PythonManager.instance.lastError.value ?? "详见日志"}）',
          source: null,
        );
      }

      await load();

      var base = (displayName ?? '本地源').trim();
      if (base.toLowerCase().endsWith('.py')) {
        base = base.substring(0, base.length - 3);
      }
      if (base.isEmpty) base = '本地源';
      var name = base;
      var n = 2;
      while (_sources.any((s) => s.name == name)) {
        name = '$base ($n)';
        n++;
      }

      final h = md5
          .convert(
            utf8.encode('$name|${DateTime.now().microsecondsSinceEpoch}'),
          )
          .toString();
      final key = 'lp_${h.substring(0, 12)}';

      // 1) 先落到本地源目录（<Documents>/local_py/<key>.py）
      final dir = await directory();
      if (!await dir.exists()) await dir.create(recursive: true);
      try {
        await File('${dir.path}/$key.py').writeAsString(code, flush: true);
      } catch (e) {
        return (ok: false, message: '写入 local_py 失败: $e', source: null);
      }

      // 2) 再注册进引擎（只做内存注册，不再往 python-project 写第二份）
      final r = await PythonSourcesService.instance.registerSource(
        'video',
        key,
        code,
      );
      if (!r.ok) {
        return (ok: false, message: '注册失败: ${r.message}', source: null);
      }

      final src = LocalPythonSource(
        key: key,
        name: name,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      );
      _sources.add(src);
      if (save) await _save();
      AppLog.instance.log('[LocalPy] 已导入本地源 $key（$name）');
      return (ok: true, message: null, source: src);
    } catch (e) {
      AppLog.instance.w('[LocalPy] 导入失败: $e');
      return (ok: false, message: e.toString(), source: null);
    }
  }

  /// 批量导入（统一只启动一次引擎、只写一次清单）
  Future<({int imported, int failed, List<String> errors})> importMany(
    List<({String name, String code})> items,
  ) async {
    if (items.isEmpty) {
      return (imported: 0, failed: 0, errors: const <String>[]);
    }
    if (!PythonManager.instance.isIOS) {
      return (
        imported: 0,
        failed: items.length,
        errors: const <String>['Python 引擎仅支持 iOS'],
      );
    }
    if (!await PythonManager.instance.ensureStarted()) {
      return (
        imported: 0,
        failed: items.length,
        errors: const <String>['Python 引擎启动失败'],
      );
    }
    await load();
    var imported = 0;
    var failed = 0;
    final errors = <String>[];
    for (final it in items) {
      final r = await importCode(it.code, displayName: it.name, save: false);
      if (r.ok) {
        imported++;
      } else {
        failed++;
        if (errors.length < 8) errors.add('${it.name}: ${r.message ?? "失败"}');
      }
    }
    if (imported > 0) await _save();
    return (imported: imported, failed: failed, errors: errors);
  }

  /// 批量导入一个目录下的所有 .py（默认递归），每个文件仍是一条独立本地源
  Future<({int imported, int failed, List<String> errors})> importDirectory(
    String path, {
    bool recursive = true,
  }) async {
    final items = <({String name, String code})>[];
    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        return (imported: 0, failed: 0, errors: const <String>['目录不存在']);
      }
      await for (final f in dir.list(
        recursive: recursive,
        followLinks: false,
      )) {
        if (f is! File) continue;
        final lower = f.path.toLowerCase();
        if (!lower.endsWith('.py')) continue;
        if (lower.contains('__pycache__')) continue;
        try {
          final code = await f.readAsString();
          if (code.trim().isEmpty) continue;
          items.add((name: f.uri.pathSegments.last, code: code));
        } catch (_) {
          // 单个文件读失败不影响其它文件
        }
      }
    } catch (e) {
      return (imported: 0, failed: 0, errors: ['扫描目录失败: $e']);
    }
    if (items.isEmpty) {
      return (imported: 0, failed: 0, errors: const <String>['目录里没有 .py 文件']);
    }
    return importMany(items);
  }

  /// 批量导入 zip 里的所有 .py（自动跳过 __MACOSX / __pycache__）
  Future<({int imported, int failed, List<String> errors})> importZip(
    List<int> bytes,
  ) async {
    final items = <({String name, String code})>[];
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final f in archive) {
        if (!f.isFile) continue;
        final name = f.name.replaceAll('\\', '/');
        final lower = name.toLowerCase();
        if (!lower.endsWith('.py')) continue;
        if (lower.contains('__macosx/') || lower.contains('__pycache__/')) {
          continue;
        }
        final data = f.content;
        if (data is! List<int> || data.isEmpty) continue;
        items.add((
          name: name.split('/').last,
          code: utf8.decode(data, allowMalformed: true),
        ));
      }
    } catch (e) {
      return (imported: 0, failed: 0, errors: ['zip 解析失败: $e']);
    }
    if (items.isEmpty) {
      return (imported: 0, failed: 0, errors: const <String>['zip 里没有 .py 文件']);
    }
    return importMany(items);
  }

  /// 改名（只改清单，不动文件/key）
  Future<({bool ok, String? message})> rename(
    String key,
    String newName,
  ) async {
    final name = newName.trim();
    if (name.isEmpty) return (ok: false, message: '名称不能为空');
    await load();
    final i = _sources.indexWhere((s) => s.key == key);
    if (i < 0) return (ok: false, message: '源不存在');
    _sources[i] = LocalPythonSource(
      key: _sources[i].key,
      name: name,
      addedAt: _sources[i].addedAt,
    );
    await _save();
    return (ok: true, message: null);
  }

  /// 删除：文件 + 引擎模块 + 清单一起清掉
  Future<({bool ok, String? message})> remove(String key) async {
    await load();
    final dir = await directory();
    try {
      final f = File('${dir.path}/$key.py');
      if (await f.exists()) await f.delete();
    } catch (_) {}
    final r = await PythonSourcesService.instance.unregisterSource(
      'video',
      key,
    );
    _sources.removeWhere((s) => s.key == key);
    await _save();
    if (!r.ok) {
      // 文件通常已经删掉了；引擎卸载失败只影响本次会话
      return (ok: false, message: r.message ?? '卸载失败（重启后彻底生效）');
    }
    AppLog.instance.log('[LocalPy] 已删除本地源 $key');
    return (ok: true, message: null);
  }

  /// 清空全部本地源（文件 + 引擎模块 + 清单）
  Future<int> clearAll() async {
    await load();
    final keys = _sources.map((s) => s.key).toList();
    for (final key in keys) {
      await remove(key);
    }
    return keys.length;
  }

  /// 读取某条本地源的脚本内容
  Future<String?> readCode(String key) async {
    try {
      final dir = await directory();
      final f = File('${dir.path}/$key.py');
      if (!await f.exists()) return null;
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// 确保某条本地源已注册进当前解释器（重启/引擎重建后自愈用）。
  Future<bool> ensureRegistered(String key) async {
    if (!PythonManager.instance.isIOS) return false;
    if (!await PythonManager.instance.ensureStarted()) return false;
    final code = await readCode(key);
    if (code == null || code.trim().isEmpty) return false;
    final r = await PythonSourcesService.instance.registerSource(
      'video',
      key,
      code,
    );
    if (!r.ok) {
      AppLog.instance.w('[LocalPy] 重新注册失败 $key: ${r.message}');
      return false;
    }
    return true;
  }

  /// 把所有本地源重新注册进引擎（用于「重新加载」按钮 / 重启后）
  Future<int> registerAll() async {
    await load();
    if (!PythonManager.instance.isIOS) return 0;
    if (!await PythonManager.instance.ensureStarted()) return 0;
    var ok = 0;
    for (final s in _sources) {
      final code = await readCode(s.key);
      if (code == null || code.trim().isEmpty) continue;
      final r = await PythonSourcesService.instance.registerSource(
        'video',
        s.key,
        code,
      );
      if (r.ok) ok++;
    }
    if (ok > 0) {
      AppLog.instance.log('[LocalPy] 已重新注册 $ok 个本地源');
    }
    return ok;
  }

  /// 记录一次使用（用于「频率」排序）
  Future<void> bumpUsage(String key) async {
    final i = _sources.indexWhere((s) => s.key == key);
    if (i < 0) return;
    final s = _sources[i];
    _sources[i] = LocalPythonSource(
      key: s.key,
      name: s.name,
      addedAt: s.addedAt,
      usage: s.usage + 1,
    );
    await _save();
  }

  Future<void> _save() async {
    try {
      final file = await _manifest();
      final dir = file.parent;
      if (!await dir.exists()) await dir.create(recursive: true);
      await file.writeAsString(
        jsonEncode(_sources.map((s) => s.toJson()).toList()),
        flush: true,
      );
    } catch (e) {
      AppLog.instance.w('[LocalPy] 清单写入失败: $e');
    }
  }
}
