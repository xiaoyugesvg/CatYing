import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/models/import_conflict.dart';
import 'package:tvbox/models/local_js_source.dart';
import 'package:tvbox/services/app_log.dart';

/// 判断一段 JS **不像**影视源时返回原因；像源则返回 null。
///
/// 影视源只有这几种合法形态（与 `spider_engine` / drpy2 的路由一致）：
///   1. TVBox / 猫源 drpy2：`var rule = { title, home: async function(){} }`
///   2. drpy 单文件：`var spider = {...}` 或 `class Spider`
///   3. catvod / 订阅 JS：`homeContent` / `categoryContent` / `playerContent`
///
/// 判断刻意**放宽**：出现任一入口标记就放行 —— 宁可漏判，
/// 也不要把写法特殊的正常源误杀掉（与 `whyNotVideoSource`（PY）同一策略）。
String? whyNotJsVideoSource(String code) {
  if (_reJsSpiderClass.hasMatch(code) ||
      _reJsRuleObj.hasMatch(code) ||
      _reJsEntry.hasMatch(code)) {
    return null;
  }
  if (_reJsStandaloneServer.hasMatch(code)) {
    return '这不是影视源脚本，而是「独立服务型」脚本'
        '（自己起本地端口 / HTTP 服务）。'
        '它需要后台常驻运行，不能作为本地 JS 源导入。';
  }
  return '这不是影视源脚本：既没有 var rule / var spider / class Spider，'
      '也没有 home / homeContent 入口函数。';
}

final RegExp _reJsSpiderClass =
    RegExp(r'^\s*(?:export\s+)?class\s+Spider\b', multiLine: true);

/// `var rule = {` / `let rule = {` / `module.exports = {` / `var spider = {`
final RegExp _reJsRuleObj = RegExp(
  r'^\s*(?:var|let|const)\s+(?:rule|spider|Spider|catvod)\s*=\s*[\{`]',
  multiLine: true,
);

/// 入口函数：`home:` / `home =` / `home(` / `homeContent` / `async home`
final RegExp _reJsEntry = RegExp(
  r'(?:^|[\s,{;])(?:async\s+)?'
  r'(?:home|homeContent|categoryContent|searchContent|detailContent|'
  r'playerContent|category|search|detail|play)\s*[:=(]',
  multiLine: true,
);

/// 独立服务型脚本特征：自己起 HTTP 服务
final RegExp _reJsStandaloneServer = RegExp(
  r'http\.createServer|express\s*\(|require\([\x27"]http[\x27"]\)|'
  r'Fastify\s*\(|Koa\s*\(|new\s+Server\s*\(',
);

/// 「本地 JS 源」的落盘与清单管理。
///
/// 目录：
///   <Documents>/local_js/local_video_sources.json   ← 清单（显示名/导入时间/使用次数）
///   <Documents>/local_js/ljs_*.js                    ← 脚本本体
///
/// 与 PY 源的差别（重要）：
///   · **没有"注册进引擎"这一步** —— Node 侧按需 `loadSource('ljs_xxx.js')`，
///     `NodeJSPlatformIos._resolveLocalJsPath` 把它解析成真实文件后载入；
///   · 所以增删改只要**落盘 + 刷新 ApiConfig**，下一次切到该源时自然生效；
///   · 也正因为如此，删掉文件后 Node 那边不会残留模块（下次加载会失败并给出明确报错）。
///
/// 设计要点与 PY 完全一致（用户 2026-10-17 / 2026-10-29）：
///   · 一条脚本一个 key，单独增删，不写进订阅 sites；
///   · 全部本地源在源切换面板里**单独成组**，不跟订阅线路混在一起；
///   · 清单与订阅解耦：换订阅/重启都不会丢。
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
    return File('${dir.path}/local_video_sources.json');
  }

  /// 读取清单 + 与磁盘对账。
  ///
  /// 对账规则（与 PY 一致）：
  ///   · 清单里有、文件没了 → 丢掉（用户可能在别处删了）；
  ///   · 目录里有 `ljs_*.js`、清单里没有 → 补进来（老数据/手动拷入）。
  ///
  /// 读进临时列表、全部成功才替换：任何一步抛错都不会把已有清单清空
  /// （PY 那边 2026-10-29 踩过这个坑，这里一开始就按修好的写法来）。
  Future<void> load({bool force = false}) async {
    if (_loaded && !force) return;

    final dir = await directory();
    if (!await dir.exists()) await dir.create(recursive: true);

    final next = <LocalJsSource>[];

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
            if (next.any((x) => x.key == s.key)) continue;
            next.add(s);
          }
        }
      } catch (e) {
        AppLog.instance.w('[LocalJs] 清单解析失败: $e');
      }
    }

    try {
      await for (final f in dir.list()) {
        if (f is! File || !f.path.endsWith('.js')) continue;
        final name = f.uri.pathSegments.last;
        final key = name.substring(0, name.length - 3);
        if (!key.startsWith('ljs_')) continue;
        if (next.any((x) => x.key == key)) continue;
        next.add(
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

    _sources
      ..clear()
      ..addAll(next);
    _loaded = true;
    await _applyOrder();
    await _save();
  }

  static const String _kOrder = 'local_js_order_v1';
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

  /// 按脚本文本导入（核心逻辑）
  ///
  /// [save] = false 用于批量导入：循环里不反复写清单，最后统一落一次盘。
  ///
  /// [conflict] 只在**同名**时起作用：
  ///   · [ImportConflict.rename]（默认）= 原来的自动改名 `名字 (2)`；
  ///   · [ImportConflict.replace] = 覆盖同名源，**沿用旧 key**，只换脚本内容。
  Future<({bool ok, String? message, LocalJsSource? source})> importCode(
    String code, {
    String? displayName,
    bool save = true,
    ImportConflict conflict = ImportConflict.rename,
  }) async {
    try {
      if (code.trim().isEmpty) {
        return (ok: false, message: '脚本内容为空', source: null);
      }
      final why = whyNotJsVideoSource(code);
      if (why != null) {
        return (ok: false, message: why, source: null);
      }

      await load();

      var base = (displayName ?? '本地JS源').trim();
      if (base.toLowerCase().endsWith('.js')) {
        base = base.substring(0, base.length - 3);
      }
      if (base.isEmpty) base = '本地JS源';

      // ── 覆盖同名源 ────────────────────────────────────────────────
      // 沿用旧 key：文件路径、已选中的 key、分组顺序、使用次数全部不变，
      // 只把脚本内容换掉 —— 用户视角是"这个源更新了"。
      if (conflict == ImportConflict.replace) {
        final i = _sources.indexWhere((s) => s.name == base);
        if (i >= 0) {
          final old = _sources[i];
          final dir = await directory();
          if (!await dir.exists()) await dir.create(recursive: true);
          try {
            await File('${dir.path}/${old.key}.js')
                .writeAsString(code, flush: true);
          } catch (e) {
            return (ok: false, message: '写入 local_js 失败: $e', source: null);
          }
          if (save) await _save();
          AppLog.instance.log('[LocalJs] 已替换本地源 ${old.key}（${old.name}）');
          return (ok: true, message: null, source: old);
        }
        // 没找到同名 → 当成新源，走下面的正常流程
      }

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

  /// 按字节导入（iOS 文件选择器给的是 bytes，path 可能为 null）
  Future<({bool ok, String? message, LocalJsSource? source})> importBytes(
    List<int> bytes, {
    String? displayName,
  }) {
    return importCode(
      utf8.decode(bytes, allowMalformed: true),
      displayName: displayName,
    );
  }

  /// 这批条目里与**现有源同名**的显示名（已去掉 `.js`）。
  Future<List<String>> conflictingNames(Iterable<String> displayNames) async {
    final bases = <String>{};
    for (final raw in displayNames) {
      var b = raw.trim();
      if (b.toLowerCase().endsWith('.js')) {
        b = b.substring(0, b.length - 3);
      }
      if (b.isNotEmpty) bases.add(b);
    }
    if (bases.isEmpty) return const <String>[];
    await load();
    return _sources
        .where((s) => bases.contains(s.name))
        .map((s) => s.name)
        .toList();
  }

  /// 批量导入（只写一次清单）
  Future<({int imported, int failed, List<String> errors})> importMany(
    List<({String name, String code})> items, {
    ImportConflict conflict = ImportConflict.rename,
  }) async {
    if (items.isEmpty) {
      return (imported: 0, failed: 0, errors: const <String>[]);
    }
    await load();
    var imported = 0;
    var failed = 0;
    final errors = <String>[];
    for (final it in items) {
      final r = await importCode(
        it.code,
        displayName: it.name,
        save: false,
        conflict: conflict,
      );
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

  /// 扫描目录里的所有 `.js`（不落盘，供页面先做同名检测）。
  Future<List<({String name, String code})>> scanDirectory(
    String path, {
    bool recursive = true,
  }) async {
    final items = <({String name, String code})>[];
    final dir = Directory(path);
    if (!await dir.exists()) return items;
    await for (final f in dir.list(
      recursive: recursive,
      followLinks: false,
    )) {
      if (f is! File) continue;
      final lower = f.path.toLowerCase();
      if (!lower.endsWith('.js')) continue;
      if (lower.contains('node_modules/')) continue;
      try {
        final code = await f.readAsString();
        if (code.trim().isEmpty) continue;
        items.add((name: f.uri.pathSegments.last, code: code));
      } catch (_) {
        // 单个文件读失败不影响其它文件
      }
    }
    return items;
  }

  /// 解析 zip 里的所有 `.js`（不落盘）。解析失败会抛异常。
  List<({String name, String code})> scanZipBytes(List<int> bytes) {
    final items = <({String name, String code})>[];
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final f in archive) {
      if (!f.isFile) continue;
      final name = f.name.replaceAll('\\', '/');
      final lower = name.toLowerCase();
      if (!lower.endsWith('.js')) continue;
      if (lower.contains('__macosx/') || lower.contains('node_modules/')) {
        continue;
      }
      final data = f.content;
      if (data is! List<int> || data.isEmpty) continue;
      items.add((
        name: name.split('/').last,
        code: utf8.decode(data, allowMalformed: true),
      ));
    }
    return items;
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
    final dir = await directory();
    try {
      final f = File('${dir.path}/$key.js');
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
      final dir = await directory();
      final f = File('${dir.path}/$key.js');
      if (!await f.exists()) return null;
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// 修改某条本地源的脚本内容。
  ///
  /// JS 源没有"常驻模块"这回事：Node 每次 `loadSource` 都会把文件重新拷进
  /// 缓存目录再载入，所以只要写盘成功，下一次切到该源就是新代码。
  Future<({bool ok, String? message})> saveCode(String key, String code) async {
    await load();
    final i = _sources.indexWhere((s) => s.key == key);
    if (i < 0) return (ok: false, message: '源不存在');
    final why = whyNotJsVideoSource(code);
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

  /// 本地 JS 源是**按需载入**的，没有"注册"这一步。
  ///
  /// 保留这个方法是为了和 PY 页面的「重新加载」按钮保持同一套调用面：
  /// 返回当前可用的源数量，调用方再刷一次 ApiConfig 即可。
  Future<int> registerAll() async {
    await load();
    return _sources.length;
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
