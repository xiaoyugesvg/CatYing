import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 阅读模块**宫格列数**偏好（一排 3 / 4 / 5 个）。
///
/// 用户 2026-10-07 要求：
///   漫画、图书、书源 三个页面都要"宫格 / 列表"切换，
///   宫格还要能选一排 3 个 / 4 个 / 5 个。
///
/// 为什么单独抽一个服务：
///   · 漫画的宫格/列表状态在 `ViewMode`、图书在 `BookViewMode`、
///     书源在 `SourceViewMode` —— **三者各自独立**（互不影响观感）；
///   · 但"一排几个"是**跨页面的排版偏好** —— 用户在漫画页调成 4 列，
///     去图书页也希望是 4 列，所以列数**共享一份**。
class ReadingLayout extends ChangeNotifier {
  ReadingLayout._();
  static final ReadingLayout _instance = ReadingLayout._();
  factory ReadingLayout() => _instance;

  static const _key = 'reading_grid_columns';

  /// 允许的列数范围（UI 只提供 3 / 4 / 5 三档）
  static const int minColumns = 3;
  static const int maxColumns = 5;

  int _columns = 3;
  int get columns => _columns;

  /// 初始化：从本地读取列数偏好（默认 3 列）
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getInt(_key) ?? 3;
      _columns = v.clamp(minColumns, maxColumns);
    } catch (_) {}
    notifyListeners();
  }

  /// 设置列数（自动夹到 3~5）
  void setColumns(int c) {
    final v = c.clamp(minColumns, maxColumns);
    if (_columns == v) return;
    _columns = v;
    notifyListeners();
    _persist();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_key, _columns);
    } catch (_) {}
  }
}

/// 书源页视图模式（宫格 / 列表），独立于漫画 `ViewMode` 与图书 `BookViewMode`。
class SourceViewMode extends ChangeNotifier {
  SourceViewMode._();
  static final SourceViewMode _instance = SourceViewMode._();
  factory SourceViewMode() => _instance;

  static const _key = 'source_view_mode';

  bool _isGrid = true;
  bool get isGrid => _isGrid;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _isGrid = prefs.getBool(_key) ?? true;
    } catch (_) {}
    notifyListeners();
  }

  void set(bool isGrid) {
    if (_isGrid == isGrid) return;
    _isGrid = isGrid;
    notifyListeners();
    _persist();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, _isGrid);
    } catch (_) {}
  }
}
