// lib/services/local_js_sources.dart
//
// 「本地 JS 源」的落盘与管理 —— 与本地 Python 源（local_python_sources.dart）
// 同一套设计，只是引擎换成 Node（CatVod / drpy / TVBox type=3 脚本）。
// -----------------------------------------------------------------------------
// 目录（用户可直接把 .js 拷进来）：
//   <Documents>/local_js/local_js_sources.json   ← 清单（显示名/导入时间/使用次数）
//   <Documents>/local_js/ljs_*.js                ← 脚本本体
//
// 与 Python 本地源的关键差异：
//   · Python 是「一个 key 一个模块」常驻解释器，导入时要 install_source；
//   · Node 是**单源架构**（同一时刻只有一份 index.js），所以导入时**不做任何
//     引擎注册**，等真正被选中/访问时由 SpiderService → NodeJSManager.loadSource
//     按需把文件载入槽位（loadSource 内部识别 `ljs_*.js` 并解析成真实路径）。
//
// 因此本服务只负责「存文件 + 记清单」，不依赖 Node 是否已启动，也不会因为
// 引擎没起来而导入失败。

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/models/local_js_source.dart';
import 'package:tvbox/services/app_log.dart';

/// 判断一段脚本**不像** JS 影视源时返回原因；像源则返回 null。
///
/// 判定刻意**放宽**：出现任一入口特征就放行 —— 宁可漏判，也不要把写法特殊的
/// 正常源误杀掉。真正能不能跑，选中时 Node 载入会给出更准确的错误。
///
/// ⚠️ 2026-10-27 修（用户导入「官方聚合.js」被误判成网页）：
///   很多正常源会在**字符串或正则里**拼 HTML（典型：
///   `/<!doctype html|<html\b|<head\b/i.test(body)` 判断响应是不是网页）。
///   旧逻辑「全文出现 `<html` 就判成 HTML 网页」会把这些源直接误杀。
///   ⇒ 现在**先**认入口/导出特征，只有「完全没有 JS 入口、且文件**开头**就是
///   HTML 文档」才判成网页（那才是真的下载到了错误页）。
String? whyNotJsSource(String code) {
  final s = code.trim();
  if (s.isEmpty) return '脚本内容为空';

  // ① 先认「像不像 JS 源」：入口 / 导出 / CatVod 工厂特征任一命中即放行。
  if (_reEntry.hasMatch(s) || _reExport.hasMatch(s) || _reCatVod.hasMatch(s)) {
    return null;
  }

  // ② 没有任何 JS 入口特征，且**文件开头就是 HTML 文档** ⇒ 基本是错误页。
  final head = s.length > 512 ? s.substring(0, 512) : s;
  final lowerHead = head.toLowerCase();
  if (lowerHead.startsWith('<!doctype') || lowerHead.startsWith('<html')) {
    return '这是一段 HTML 网页，不是 JS 源脚本（可能下载到了错误页）。';
  }
  return '这不是 JS 影视源脚本：既没有 module.exports / export，'
      '也没有 homeContent / start 等入口。';
}

/// 常见入口函数名（CatVod / drpy / TVBox 三种写法都覆盖）
final RegExp _reEntry = RegExp(
  r'\b(homeContent|categoryContent|searchContent|detailContent|playerContent|'
  r'homeVideoContent|home|category|search|detail|play|start)\s*[:(=]',
);

/// 模块导出（CJS / ESM）
final RegExp _reExport = RegExp(r'module\.exports|exports\.[A-Za-z_$]|export\s+(default|function|const|class)');

/// CatVodOpen 的 createSpider 工厂写法
final RegExp _reCatVod = RegExp(r'createSpider');

class LocalJsSources {
  static final LocalJsSources _instance = LocalJsSources._internal();
  static LocalJsSources get instance => _instance;
  LocalJsSources._internal();

  final List<LocalJsSource> _sources = [];
  bool _loaded = false;

  List<LocalJsSource> get sources => List.unmodifiable(_sources);
  bool get hasAny => _sources.isNotEmpty;

  /// 本地 JS 源根目录：<Documents>/local_js（用户可直接把 .js 拷进来）
  Future<Directory> directory() async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/local_js');
  }

  Future<File> _manifest() async {
    final dir = await directory();
    return File('${dir.path}/local_js_sources.json');
  }

  /// 读取清单 + 与磁盘对账。
  ///
  /// 对账规则：
  ///   · 清单里有、文件没了 → 丢掉；
  ///   · 目录里有 `ljs_*.js`、清单里没有 → 补进来（手动拷入）。
  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;
    _loaded = true;
    _sources.clear();

    final dir = await directory();
    if (!await dir.exists()) await dir.create(recursive: true);

    final file = await _manifest();
    if (await file.exists()) {
      try {
        final raw = jsonDecode(await file.readAsString());
        if (raw is List) {
          for (final e in raw) {
            if (e is! Map) continue;
            final s = LocalJsSource.fromJson(Map<String, dynamic>.from(e));
            if (s.key.isEmpty) continue;
            if (!await File('${dir.path}/${s.key}.js').exists()) continue;
            if (_sources.any((x) => x.key == s.key)) continue;
            _sources.add(s);
          }
        }
      } catch (e) {
        AppLog.instance.w('[LocalJs] 清单解析失败: $e');
      }
    }

    try {
      await for (final f in dir.list()) {
        if (f is! File || !f.path.toLowerCase().endsWith('.js')) continue;
        final name = f.uri.pathSegments.last;
        final key = name.substring(0, name.length - 3);
        if (!key.startsWith('ljs_')) continue;
        if (_sources.any((x) => x.key == key)) continue;
        _sources.add(
          LocalJsSource(
            key: key,
            name: key,
            addedAt: f.statSync().modified.millisecondsSinceEpoch,
          ),
        );
      }
    } catch (e) {
      AppLog.instance.w('[LocalJs] 扫描目录失败: $e');
    }

    await _applyOrder();
    await _save();
  }

  static const String _kOrder = 'local_js_order_v1';
  List<String> _order = const [];

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

  /// 只重排传入的这批源，并持久化顺序。
  Future<void> reorderWithin(List<String> visibleKeys) async {
    if (visibleKeys.isEmpty) return;
    final wanted = visibleKeys.toSet();
    final byKey = {for (final s in _sources) s.key: s};
    final queue = List<String>.from(visibleKeys);
    final next = <LocalJsSource>[];
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

  /// 某条本地源的绝对路径（不保证存在）。
  Future<String> pathOf(String key) async {
    final dir = await directory();
    return '${dir.path}/$key.js';
  }

  /// 某条本地源的脚本文件是否存在。
  Future<bool> hasFile(String key) async {
    try {
      return await File(await pathOf(key)).exists();
    } catch (_) {
      return false;
    }
  }

  /// 导入一个 .js 文件。成功返回新建的源。
  Future<({bool ok, String? message, LocalJsSource? source})> importFile(
    String path, {
    String? displayName,
  }) async {
    try {
      final f = File(path);
      if (!await f.exists()) {
        return (ok: false, message: '文件不存在', source: null);
      }
      final name = displayName ?? f.uri.pathSegments.last;
      final code = await f.readAsString();
      return await importCode(code, displayName: name);
    } catch (e) {
      AppLog.instance.w('[LocalJs] 读取文件失败: $e');
      return (ok: false, message: e.toString(), source: null);
    }
  }

  /// 直接按字节导入（iOS 文件选择器给的是 bytes）
  Future<({bool ok, String? message, LocalJsSource? source})> importBytes(
    List<int> bytes, {
    String? displayName,
  }) {
    return importCode(
      utf8.decode(bytes, allowMalformed: true),
      displayName: displayName,
    );
  }

  /// 按脚本文本导入（核心逻辑）
  Future<({bool ok, String? message, LocalJsSource? source})> importCode(
    String code, {
    String? displayName,
    bool save = true,
  }) async {
    try {
      final why = whyNotJsSource(code);
      if (why != null) {
        return (ok: false, message: why, source: null);
      }
      await load();

      var base = (displayName ?? '本地 JS 源').trim();
      if (base.toLowerCase().endsWith('.js')) {
        base = base.substring(0, base.length - 3);
      }
      if (base.isEmpty) base = '本地 JS 源';
      var name = base;
      var n = 2;
      while (_sources.any((s) => s.name == name)) {
        name = '$base ($n)';
        n++;
      }

      final h = md5
          .convert(utf8.encode('$name|${DateTime.now().microsecondsSinceEpoch}'))
          .toString();
      final key = 'ljs_${h.substring(0, 12)}';

      final dir = await directory();
      if (!await dir.exists()) await dir.create(recursive: true);
      try {
        await File('${dir.path}/$key.js').writeAsString(code, flush: true);
      } catch (e) {
        return (ok: false, message: '写入 local_js 失败: $e', source: null);
      }

      final src = LocalJsSource(
        key: key,
        name: name,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      );
      _sources.add(src);
      if (save) await _save();
      AppLog.instance.log('[LocalJs] 已导入本地源 $key（$name）');
      return (ok: true, message: null, source: src);
    } catch (e) {
      AppLog.instance.w('[LocalJs] 导入失败: $e');
      return (ok: false, message: e.toString(), source: null);
    }
  }

  /// 批量导入（统一只写一次清单）
  Future<({int imported, int failed, List<String> errors})> importMany(
    List<({String name, String code})> items,
  ) async {
    if (items.isEmpty) {
      return (imported: 0, failed: 0, errors: const <String>[]);
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

  /// 批量导入一个目录下的所有 .js（默认递归）
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
        if (!lower.endsWith('.js')) continue;
        if (lower.contains('node_modules')) continue;
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
      return (imported: 0, failed: 0, errors: const <String>['目录里没有 .js 文件']);
    }
    return importMany(items);
  }

  /// 批量导入 zip 里的所有 .js（跳过 node_modules）
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
        if (!lower.endsWith('.js')) continue;
        if (lower.contains('node_modules/') || lower.contains('__macosx/')) {
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
      return (imported: 0, failed: 0, errors: const <String>['zip 里没有 .js 文件']);
    }
    return importMany(items);
  }

  /// 改名（只改清单，不动文件/key）
  Future<({bool ok, String? message})> rename(String key, String newName) async {
    final name = newName.trim();
    if (name.isEmpty) return (ok: false, message: '名称不能为空');
    await load();
    final i = _sources.indexWhere((s) => s.key == key);
    if (i < 0) return (ok: false, message: '源不存在');
    _sources[i] = LocalJsSource(
      key: _sources[i].key,
      name: name,
      addedAt: _sources[i].addedAt,
      usage: _sources[i].usage,
    );
    await _save();
    return (ok: true, message: null);
  }

  /// 删除：文件 + 清单一起清掉
  Future<({bool ok, String? message})> remove(String key) async {
    await load();
    try {
      final f = File(await pathOf(key));
      if (await f.exists()) await f.delete();
    } catch (_) {}
    _sources.removeWhere((s) => s.key == key);
    await _save();
    AppLog.instance.log('[LocalJs] 已删除本地源 $key');
    return (ok: true, message: null);
  }

  /// 清空全部本地源
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
      final f = File(await pathOf(key));
      if (!await f.exists()) return null;
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// 修改某条本地源的脚本内容（用户 2026-10-28「加个修改脚本的功能」）。
  ///
  /// JS 是**单源按需加载**架构（同一时刻 Node 槽位里只有一份 index.js），
  /// 这里只负责把文件写下去；下次选中 / 访问该源时 `loadSource` 会读新内容。
  /// 如果改的正是当前源，UI 层会顺手 `loadSource` 一次让它立即生效。
  Future<({bool ok, String? message})> saveCode(String key, String code) async {
    await load();
    final i = _sources.indexWhere((s) => s.key == key);
    if (i < 0) return (ok: false, message: '源不存在');
    final why = whyNotJsSource(code);
    if (why != null) return (ok: false, message: why);
    try {
      final dir = await directory();
      if (!await dir.exists()) await dir.create(recursive: true);
      await File('${dir.path}/$key.js').writeAsString(code, flush: true);
    } catch (e) {
      return (ok: false, message: '写入失败: $e');
    }
    AppLog.instance.log('[LocalJs] 已修改脚本 $key');
    return (ok: true, message: null);
  }

  /// 记录一次使用（用于「频率」排序）
  Future<void> bumpUsage(String key) async {
    final i = _sources.indexWhere((s) => s.key == key);
    if (i < 0) return;
    final s = _sources[i];
    _sources[i] = LocalJsSource(
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
      AppLog.instance.w('[LocalJs] 清单写入失败: $e');
    }
  }
}
