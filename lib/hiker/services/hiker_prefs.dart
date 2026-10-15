import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/app_log.dart';

/// 「海阔」模块自己的偏好设置（独立键前缀，不碰其它模块）。
///
/// 为什么单独一个类：影视的 `PlayerPrefs` / 阅读的 `SettingsService` 都是
/// **各自模块**的偏好容器；海阔要"设置详细一点"，但也**不能**把键塞进别人
/// 的容器里（那正是"影响其它模块"）。
class HikerPrefs extends ChangeNotifier {
  HikerPrefs._();
  static final HikerPrefs instance = HikerPrefs._();

  static const String _kColumns = 'hiker_columns_v1';
  static const String _kShowDesc = 'hiker_show_desc_v1';
  static const String _kTimeoutSec = 'hiker_timeout_sec_v1';
  static const String _kMaxItems = 'hiker_max_items_v1';
  static const String _kShowRaw = 'hiker_show_raw_url_v1';
  static const String _kSortBy = 'hiker_source_sort_v1';
  static const String _kHistory = 'hiker_search_history_v1';

  static const List<int> columnOptions = [2, 3, 4];
  static const List<int> timeoutOptions = [15, 30, 45, 60, 90];
  static const List<int> maxItemOptions = [100, 300, 500, 1000];
  static const int historyMax = 20;

  int _columns = 3;
  bool _showDesc = true;
  int _timeoutSec = 45;
  int _maxItems = 300;
  bool _showRawUrl = false;
  String _sortBy = 'default';
  List<String> _history = [];

  int get columns => _columns;
  bool get showDesc => _showDesc;
  int get timeoutSec => _timeoutSec;
  int get maxItems => _maxItems;

  /// 详情页是否显示「条目地址 / 解析结果」原文（排查用，默认关）
  bool get showRawUrl => _showRawUrl;

  /// 源列表排序：default(导入顺序) / name(标题) / usable(可用优先)
  String get sortBy => _sortBy;
  String get sortLabel => switch (_sortBy) {
        'name' => '按标题',
        'usable' => '可用优先',
        _ => '导入顺序',
      };

  List<String> get searchHistory => List.unmodifiable(_history);

  bool _loaded = false;
  bool get loaded => _loaded;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final p = await SharedPreferences.getInstance();
      _columns = p.getInt(_kColumns) ?? 3;
      if (!columnOptions.contains(_columns)) _columns = 3;
      _showDesc = p.getBool(_kShowDesc) ?? true;
      _timeoutSec = p.getInt(_kTimeoutSec) ?? 45;
      if (!timeoutOptions.contains(_timeoutSec)) _timeoutSec = 45;
      _maxItems = p.getInt(_kMaxItems) ?? 300;
      if (!maxItemOptions.contains(_maxItems)) _maxItems = 300;
      _showRawUrl = p.getBool(_kShowRaw) ?? false;
      _sortBy = p.getString(_kSortBy) ?? 'default';
      _history = p.getStringList(_kHistory) ?? [];
    } catch (e) {
      AppLog.instance.log('[Hiker] 设置加载失败: $e');
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_kColumns, _columns);
      await p.setBool(_kShowDesc, _showDesc);
      await p.setInt(_kTimeoutSec, _timeoutSec);
      await p.setInt(_kMaxItems, _maxItems);
      await p.setBool(_kShowRaw, _showRawUrl);
      await p.setString(_kSortBy, _sortBy);
      await p.setStringList(_kHistory, _history);
    } catch (e) {
      AppLog.instance.log('[Hiker] 设置保存失败: $e');
    }
    notifyListeners();
  }

  /// 传给 Node 引擎的 `options`
  Map<String, dynamic> engineOptions() => {
        'timeoutMs': _timeoutSec * 1000,
        'maxItems': _maxItems,
      };

  Future<void> setColumns(int v) async {
    if (!columnOptions.contains(v) || _columns == v) return;
    _columns = v;
    await _save();
  }

  Future<void> setShowDesc(bool v) async {
    if (_showDesc == v) return;
    _showDesc = v;
    await _save();
  }

  Future<void> setTimeoutSec(int v) async {
    if (!timeoutOptions.contains(v) || _timeoutSec == v) return;
    _timeoutSec = v;
    await _save();
  }

  Future<void> setMaxItems(int v) async {
    if (!maxItemOptions.contains(v) || _maxItems == v) return;
    _maxItems = v;
    await _save();
  }

  Future<void> setShowRawUrl(bool v) async {
    if (_showRawUrl == v) return;
    _showRawUrl = v;
    await _save();
  }

  Future<void> setSortBy(String v) async {
    if (_sortBy == v) return;
    _sortBy = v;
    await _save();
  }

  // ── 搜索历史 ──────────────────────────────────────────

  Future<void> addHistory(String kw) async {
    final k = kw.trim();
    if (k.isEmpty) return;
    _history.remove(k);
    _history.insert(0, k);
    if (_history.length > historyMax) {
      _history = _history.sublist(0, historyMax);
    }
    await _save();
  }

  Future<void> removeHistory(String kw) async {
    _history.remove(kw);
    await _save();
  }

  Future<void> clearHistory() async {
    _history = [];
    await _save();
  }

  /// 把持久化的值渲染成一句说明（设置页副标题用）
  String get columnsLabel => '每行 $_columns 个';
  String get timeoutLabel => '$_timeoutSec 秒';
  String get maxItemsLabel => '$_maxItems 条';
}

/// 判定一段文本是否是合法 JSON 对象（源配置编辑保存前校验）
bool isJsonObjectText(String text) {
  final t = text.trim();
  if (t.isEmpty) return true; // 空 = 清空配置，允许
  try {
    final d = jsonDecode(t);
    return d is Map;
  } catch (_) {
    return false;
  }
}
