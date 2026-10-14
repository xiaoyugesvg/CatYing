// lib/services/parse_store.dart
//
// 解析线路（TVBox 的 `parses`）的**本地持久化 + 当前选中线路**。
//
// ── 解决什么（用户 2026-10-14）────────────────────────────────
// `ApiConfig.parseBeanList` 原来是「订阅里有什么就是什么」：换一个不带 parses
// 的订阅 → 整表清空，之前拉到的解析线路立刻消失，播放器上的「解析」按钮也就
// 没线路可切了。
// 这里把线路**落盘**（prefs + Documents 下的文件备份，与 api_url / 直播源
// 同一套思路），订阅下发的线路只**并入**、不覆盖、不清空；用户可在
// 设置 → 订阅管理 → 解析线路管理 里选线路 / 删除 / 手动添加。
//
// ── 与「直播源」的区别 ───────────────────────────────────────
// 直播源是「本地有就不让订阅覆盖」；解析线路是**累加**（不同订阅各有各的
// 线路，都留着才有得选），所以这里是 merge 语义。

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_config.dart';
import 'app_log.dart';

class ParseStore {
  ParseStore._();
  static final ParseStore instance = ParseStore._();

  static const String _kList = 'parse_line_list'; // StringList（每项一条 JSON）
  static const String _kActive = 'parse_active_url'; // 选中的线路 url
  static const String _backupName = 'parse_list.bak';

  final List<ParseBean> _list = [];
  String _activeUrl = '';
  bool _loaded = false;

  /// 全部线路（顺序即优先顺序）。
  ///
  /// 返回**可变副本**：调用方把它灌进 `ApiConfig.parseBeanList`（RxList），
  /// 而小程序注册/卸载会对那个 RxList 做增删 —— 给不可变视图会直接抛
  /// UnsupportedError。这里给副本，谁也不用担心改到内部状态。
  List<ParseBean> get list => List<ParseBean>.of(_list);

  /// 当前选中的线路 url（空串 = 自动：按顺序依次尝试）
  String get activeUrl => _activeUrl;

  /// 当前选中的线路；未选 / 已被删除 → null（调用方按"自动"处理）
  ParseBean? get activeBean {
    if (_activeUrl.isEmpty) return null;
    for (final b in _list) {
      if (b.url == _activeUrl) return b;
    }
    return null;
  }

  // ============================================================
  // 载入 / 落盘
  // ============================================================

  /// 启动时调用一次（须早于 ApiConfig 首次加载配置）。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      var raw = prefs.getStringList(_kList) ?? const <String>[];
      if (raw.isEmpty) raw = await _readBackup();
      _list
        ..clear()
        ..addAll(_decode(raw));
      _activeUrl = (prefs.getString(_kActive) ?? '').trim();
      // 选中的线路已经不在列表里（被删了 / 备份较旧）→ 回到"自动"
      if (_activeUrl.isNotEmpty && !_list.any((b) => b.url == _activeUrl)) {
        _activeUrl = '';
      }
      AppLog.instance.log('[ParseStore] 就绪：${_list.length} 条线路，'
          '选中=${_activeUrl.isEmpty ? "自动" : _activeUrl}');
    } catch (e) {
      AppLog.instance.log('[ParseStore] 读取失败: $e');
    }
  }

  Future<void> _save() async {
    final raw = _list.map(_encode).toList();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kList, raw);
      await prefs.setString(_kActive, _activeUrl);
    } catch (e) {
      AppLog.instance.log('[ParseStore] 写 prefs 失败: $e');
    }
    try {
      final f = await _backupFile();
      await f.writeAsString(jsonEncode(raw), flush: true);
    } catch (e) {
      AppLog.instance.log('[ParseStore] 写备份失败: $e');
    }
  }

  static Future<File> _backupFile() async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}/$_backupName');
  }

  Future<List<String>> _readBackup() async {
    try {
      final f = await _backupFile();
      if (!await f.exists()) return const [];
      final text = await f.readAsString();
      if (text.trim().isEmpty) return const [];
      final decoded = jsonDecode(text);
      if (decoded is List) return decoded.map((e) => e.toString()).toList();
    } catch (e) {
      AppLog.instance.log('[ParseStore] 读备份失败: $e');
    }
    return const [];
  }

  static String _encode(ParseBean b) => jsonEncode({
        'name': b.name,
        'url': b.url,
        'type': b.type,
        if (b.ext != null) 'ext': b.ext,
      });

  static List<ParseBean> _decode(List<String> raw) {
    final out = <ParseBean>[];
    for (final s in raw) {
      try {
        final j = jsonDecode(s);
        if (j is Map<String, dynamic>) {
          final b = ParseBean.fromJson(j);
          if (b.url.trim().isNotEmpty) out.add(b);
        }
      } catch (_) {
        // 坏记录跳过，别拖垮整份列表
      }
    }
    return out;
  }

  // ============================================================
  // 增删改 + 选线路
  // ============================================================

  /// 把订阅下发的线路**并入**本地：同 url 覆盖 name/type，不删本地已有的。
  /// 返回是否有变化（上层据此决定要不要刷新列表）。
  Future<bool> absorb(Iterable<ParseBean> incoming) async {
    if (!_loaded) await load();
    var changed = false;
    for (final b in incoming) {
      final url = b.url.trim();
      if (url.isEmpty) continue;
      final i = _list.indexWhere((x) => x.url == url);
      if (i < 0) {
        _list.add(ParseBean(name: b.name, url: url, type: b.type, ext: b.ext));
        changed = true;
      } else if (_list[i].name != b.name || _list[i].type != b.type) {
        _list[i] = ParseBean(name: b.name, url: url, type: b.type, ext: b.ext);
        changed = true;
      }
    }
    if (changed) await _save();
    return changed;
  }

  /// 手动新增 / 更新一条线路。
  Future<void> addOrUpdate(ParseBean bean) async {
    await absorb([bean]);
  }

  /// 删除一条线路；若删的正是选中项，选中态回到"自动"。
  Future<void> remove(String url) async {
    final i = _list.indexWhere((x) => x.url == url);
    if (i < 0) return;
    _list.removeAt(i);
    if (_activeUrl == url) _activeUrl = '';
    await _save();
  }

  /// 选中某条线路；传空串 = 自动（按顺序试全部）。
  Future<void> setActive(String url) async {
    final u = url.trim();
    _activeUrl = u.isEmpty ? '' : u;
    await _save();
  }
}
