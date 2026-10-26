import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/hiker/models/hiker_source.dart';
import 'package:tvbox/hiker/services/hiker_prefs.dart';

/// 「海阔」源仓库。
///
/// ── 为什么源存**文件**而不是 prefs（重要）──────────────────────────
/// 海阔「导出全部」的 JSON 有**好几 MB**（用户那份 115 个源 = 6.4MB）。
/// 如果塞进 `SharedPreferences`（iOS 上是 NSUserDefaults 的 plist）：
///   · 每次写都要序列化整块，plist 会臃肿；
///   · `PrefsMirror` 每 15s 全量快照一次 ⇒ **每 15s 把 6MB 写两遍**。
/// 所以源头数据放 `<Documents>/hiker/sources.json`，prefs 里只存几个
/// **小键**（当前源 id / 禁用列表 / 规则变量）。
///
/// 本模块**刻意不进** `PrefsMirror` 的阅读/音乐白名单，避免与既有模块耦合。
class HikerStore extends ChangeNotifier {
  HikerStore._();
  static final HikerStore instance = HikerStore._();

  static const String _kCurrent = 'hiker_current_v1';
  static const String _kDisabled = 'hiker_disabled_v1';
  static const String _kVars = 'hiker_vars_v1';

  /// 每个源的**用户配置**（海阔里的 `config`）—— 规则里 `config.xxx` 读的就是它。
  /// 这是让"依赖源配置的规则"能跑起来的唯一办法（海阔里也是用户手填）。
  static const String _kConfigs = 'hiker_configs_v1';

  final List<HikerSource> _sources = [];
  final Set<String> _disabled = {};
  final Map<String, Map<String, dynamic>> _vars = {};
  final Map<String, Map<String, dynamic>> _configs = {};

  String _currentId = '';
  bool _loaded = false;

  List<HikerSource> get sources => List.unmodifiable(_sources);
  bool get loaded => _loaded;
  String get currentId => _currentId;

  HikerSource? get current {
    for (final s in _sources) {
      if (s.id == _currentId) return s;
    }
    return _sources.isEmpty ? null : _sources.first;
  }

  bool isEnabled(HikerSource s) => !_disabled.contains(s.id);
  int get enabledCount => _sources.where(isEnabled).length;

  /// 能被 Phase 1 引擎实际跑起来的源数量
  int get usableCount => _sources.where((s) => s.usable).length;

  /// 「海阔」的数据根目录：`<Documents>/hiker`
  ///（源列表 `sources.json`、文件系统 `files/`、自带资源 `builtin/` 都在这下面）
  static Future<Directory?> rootDir() async {
    try {
      final d = await getApplicationDocumentsDirectory();
      final dir = Directory('${d.path}/hiker');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    } catch (e) {
      AppLog.instance.log('[Hiker] 取目录失败: $e');
      return null;
    }
  }

  Future<File?> _file() async {
    try {
      final dir = await rootDir();
      if (dir == null) return null;
      return File('${dir.path}/sources.json');
    } catch (e) {
      AppLog.instance.log('[Hiker] 取目录失败: $e');
      return null;
    }
  }

  Future<void> load() async {
    if (_loaded) return;
    try {
      final f = await _file();
      if (f != null) {
        // 读源列表：主文件坏了就回退 `.bak`（每次成功保存都会留一份）
        final list = await _readSourcesWithFallback(f);
        if (list != null) {
          _sources
            ..clear()
            ..addAll(list);
        }
      }
      final prefs = await SharedPreferences.getInstance();
      _currentId = prefs.getString(_kCurrent) ?? '';
      _disabled
        ..clear()
        ..addAll(prefs.getStringList(_kDisabled) ?? const []);
      final varsRaw = prefs.getString(_kVars);
      if (varsRaw != null && varsRaw.isNotEmpty) {
        final d = jsonDecode(varsRaw);
        if (d is Map) {
          _vars.clear();
          d.forEach((k, v) {
            if (v is Map) _vars[k.toString()] = Map<String, dynamic>.from(v);
          });
        }
      }
      final cfgRaw = prefs.getString(_kConfigs);
      if (cfgRaw != null && cfgRaw.isNotEmpty) {
        final d = jsonDecode(cfgRaw);
        if (d is Map) {
          _configs.clear();
          d.forEach((k, v) {
            if (v is Map) _configs[k.toString()] = Map<String, dynamic>.from(v);
          });
        }
      }
    } catch (e) {
      // ⚠️ 失败**不置 `_loaded`**：原来这里置位后，本次启动内所有 `load()`
      //   都会直接 return ⇒ 界面永远"没有源"，只能重启 App 才恢复。
      //   现在留给下次调用重试（读数失败通常是暂时的）。
      AppLog.instance.log('[Hiker] 加载失败（下次进入模块会重试）: $e');
      return;
    }
    _loaded = true;
    notifyListeners();
  }

  /// 读源列表：主文件解析失败时回退 `.bak`
  Future<List<HikerSource>?> _readSourcesWithFallback(File f) async {
    final primary = await _tryReadSources(f);
    if (primary != null) return primary;
    final bak = File('${f.path}.bak');
    final fromBak = await _tryReadSources(bak);
    if (fromBak != null) {
      AppLog.instance.log(
        '[Hiker] sources.json 损坏/不可读，已从 .bak 恢复 ${fromBak.length} 个源',
      );
      return fromBak;
    }
    return null;
  }

  /// 解析一个源文件；不存在/为空/损坏一律返回 null（不抛）
  Future<List<HikerSource>?> _tryReadSources(File f) async {
    try {
      if (!await f.exists()) return null;
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return null;
      final d = jsonDecode(raw);
      if (d is! List) return null;
      return [
        for (final e in d)
          if (e is Map) HikerSource(Map<String, dynamic>.from(e)),
      ];
    } catch (_) {
      return null;
    }
  }

  /// 原子写：先写 `.tmp` 再 rename 覆盖（同目录 rename 是原子的），
  /// 覆盖前把上一份留成 `.bak` —— 否则写盘途中被杀会留下**半截 JSON**，
  /// 下次加载解析失败 ⇒ 用户自己导入的源全没了（只剩内置源），全程无提示。
  Future<void> _saveFile() async {
    final f = await _file();
    if (f == null) return;
    final tmp = File('${f.path}.tmp');
    try {
      await tmp.writeAsString(
        jsonEncode(_sources.map((s) => s.raw).toList()),
        flush: true,
      );
      if (await f.exists()) {
        try {
          await f.copy('${f.path}.bak');
        } catch (e) {
          AppLog.instance.log('[Hiker] 备份 sources.json 失败（不影响本次保存）: $e');
        }
      }
      await tmp.rename(f.path);
    } catch (e) {
      AppLog.instance.log('[Hiker] 写文件失败: $e');
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  Future<void> _savePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCurrent, _currentId);
      await prefs.setStringList(_kDisabled, _disabled.toList());
      await prefs.setString(_kVars, jsonEncode(_vars));
      await prefs.setString(_kConfigs, jsonEncode(_configs));
    } catch (e) {
      AppLog.instance.log('[Hiker] 写设置失败: $e');
    }
  }

  /// 导入一段海阔 JSON（数组 / `{data:[]}` / 单对象）。
  /// 按 `标题+作者` 去重：已存在的**更新**，新的**追加**。
  /// 返回 (新增, 更新, 总数)。
  Future<(int, int, int)> importFromText(String text) =>
      importSources(HikerSource.parseList(text));

  /// 导入**已解析**的源（内置源安装走这条，省一次 JSON 解析）
  Future<(int, int, int)> importSources(List<HikerSource> parsed) async {
    if (parsed.isEmpty) return (0, 0, _sources.length);
    var added = 0;
    var updated = 0;
    for (final s in parsed) {
      final i = _sources.indexWhere((e) => e.id == s.id);
      if (i >= 0) {
        _sources[i] = s;
        updated++;
      } else {
        _sources.add(s);
        added++;
      }
    }
    if (_currentId.isEmpty && _sources.isNotEmpty)
      _currentId = _sources.first.id;
    await _saveFile();
    await _savePrefs();
    notifyListeners();
    return (added, updated, _sources.length);
  }

  Future<void> remove(String id) async {
    _sources.removeWhere((s) => s.id == id);
    _disabled.remove(id);
    _vars.remove(id);
    // 源配置也要一起删：否则是永久孤儿，将来重新导入同名同作者的源会"复活"旧配置
    _configs.remove(id);
    if (_currentId == id) {
      _currentId = _sources.isEmpty ? '' : _sources.first.id;
    }
    await _saveFile();
    await _savePrefs();
    notifyListeners();
  }

  /// 按 [visibleIds] 的新顺序重排（长按拖动后调用）。
  ///
  /// 只动传入的这些源：它们在列表里占的**坑位**不变，坑内按新顺序填充；
  /// 未传入的（被筛选/搜索隐藏的）保持原位置 —— 这样搜索状态下拖动
  /// 也不会打乱其它源。
  Future<void> reorder(List<String> visibleIds) async {
    if (visibleIds.isEmpty) return;
    final wanted = visibleIds.toSet();
    final byId = {for (final s in _sources) s.id: s};
    final queue = List<String>.from(visibleIds);
    final next = <HikerSource>[];
    var qi = 0;
    for (final s in _sources) {
      if (wanted.contains(s.id)) {
        final id = queue[qi++];
        final moved = byId[id];
        if (moved != null) next.add(moved);
      } else {
        next.add(s);
      }
    }
    _sources
      ..clear()
      ..addAll(next);
    await _saveFile();
    notifyListeners();
  }

  Future<void> clearAll() async {
    _sources.clear();
    _disabled.clear();
    _vars.clear();
    // 源配置也要清（与 remove() 同一口径）—— 否则"清空全部源"后 prefs 里还留着
    // 各源的 config，将来重新导入同名同作者的源会把旧配置"复活"
    _configs.clear();
    _currentId = '';
    await _saveFile();
    await _savePrefs();
    notifyListeners();
  }

  Future<void> setEnabled(String id, bool v) async {
    if (v) {
      _disabled.remove(id);
    } else {
      _disabled.add(id);
      // 停用的正是当前源 ⇒ 顺延到第一个仍启用的源（与 RSS / 影视的换源语义一致），
      // 否则首页会继续跑一个用户已经停用的源。
      if (_currentId == id) {
        final next = _sources.where(isEnabled).toList();
        if (next.isNotEmpty) _currentId = next.first.id;
      }
    }
    await _savePrefs();
    notifyListeners();
  }

  Future<void> setCurrent(String id) async {
    if (_currentId == id) return;
    _currentId = id;
    await _savePrefs();
    notifyListeners();
  }

  /// 源的规则变量（`setMyVar` 写回的），Phase 1 只做读写，不做跨设备同步
  Map<String, dynamic> varsOf(String sourceId) => _vars[sourceId] ?? const {};

  Future<void> saveVars(String sourceId, Map<String, dynamic> vars) async {
    if (sourceId.isEmpty) return;
    _vars[sourceId] = Map<String, dynamic>.from(vars);
    await _savePrefs();
  }

  /// 变量**有变化**才落盘，返回是否写了。
  ///
  /// ⚠️ 判据必须是"变了"，不能写成 `vars.isNotEmpty` —— 规则把变量全删光
  ///（典型是"退出登录"或 `onClose` 清理）时结果是空表，`isNotEmpty` 会把这次
  /// 清空吞掉，下次运行仍读到已过期的登录态 / 残留变量。
  Future<bool> saveVarsIfChanged(
    String sourceId,
    Map<String, dynamic> before,
    Map<String, dynamic> after,
  ) async {
    if (_sameVars(before, after)) return false;
    await saveVars(sourceId, after);
    return true;
  }

  /// 两个变量表是否等价（值按字符串比，够用于"有没有被规则改动"）
  static bool _sameVars(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k)) return false;
      if ('${b[k]}' != '${a[k]}') return false;
    }
    return true;
  }

  /// 清掉某个源的规则变量（规则乱了 / 想重新开始时的"重置"）
  Future<void> clearVars(String sourceId) async {
    if (_vars.remove(sourceId) == null) return;
    await _savePrefs();
    notifyListeners();
  }

  Future<void> clearAllVars() async {
    if (_vars.isEmpty) return;
    _vars.clear();
    await _savePrefs();
    notifyListeners();
  }

  /// 某个源的**用户配置**（对应规则里的 `config.xxx`）
  Map<String, dynamic> configOf(String sourceId) =>
      _configs[sourceId] ?? const {};

  Future<void> saveConfig(String sourceId, Map<String, dynamic> cfg) async {
    if (sourceId.isEmpty) return;
    _configs[sourceId] = Map<String, dynamic>.from(cfg);
    await _savePrefs();
    notifyListeners();
  }

  /// 全部分组名（设置页按分组筛选 / 管理页分组标题用）
  List<String> get groups {
    final s = <String>{};
    for (final x in _sources) {
      s.add(x.groupLabel);
    }
    final l = s.toList()..sort();
    return l;
  }

  /// 按「海阔设置 → 源排序」排好的列表（界面统一用它，避免各处各排）
  List<HikerSource> get sortedSources {
    final l = List<HikerSource>.from(_sources);
    switch (HikerPrefs.instance.sortBy) {
      case 'name':
        l.sort((a, b) => a.title.compareTo(b.title));
        break;
      case 'usable':
        l.sort((a, b) {
          final c = (a.usable ? 0 : 1).compareTo(b.usable ? 0 : 1);
          return c != 0 ? c : a.title.compareTo(b.title);
        });
        break;
      default:
        break; // 导入顺序
    }
    return l;
  }

  /// 分组 + 启用筛选后的源（管理页列表用）
  List<HikerSource> filterSources({
    String group = '',
    bool enabledOnly = false,
  }) {
    return sortedSources
        .where((s) => group.isEmpty || s.groupLabel == group)
        .where((s) => !enabledOnly || isEnabled(s))
        .toList();
  }
}
