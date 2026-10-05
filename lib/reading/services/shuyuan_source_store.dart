import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:hive_ce/hive.dart';

import '../novel_source/model/book_source.dart';
import '../novel_source/shuyuan_source_service.dart';

/// 书源存储服务（Nexhub 书源引擎的接入层）：
/// 负责书源列表的持久化（hive_ce box `shuyuan_sources`）、
/// 增删改查、导入解析（JSON / 包装 / NDJSON / 文本 / XML）、
/// 以及向 [XiaoshuoBookSource]（WebBook 消费模型）的转换。
class ShuyuanSourceStore extends ChangeNotifier {
  ShuyuanSourceStore._();
  static final ShuyuanSourceStore instance = ShuyuanSourceStore._();

  static const _boxName = 'shuyuan_sources';
  Box<dynamic>? _box;
  final List<ShuyuanSource> _sources = [];
  bool _initialized = false;

  List<ShuyuanSource> get sources =>
      List.unmodifiable(_sources.where((s) => s.enabled));

  /// 全部源（含停用），仓库页展示用。
  List<ShuyuanSource> get allSources => List.unmodifiable(_sources);

  bool get initialized => _initialized;

  Future<void> init() async {
    if (_initialized) return;
    _box = await Hive.openBox<dynamic>(_boxName);
    final raw = _box!.get('list', defaultValue: <dynamic>[]) as List;
    _sources.clear();
    for (final item in raw) {
      if (item is Map) {
        try {
          _sources.add(ShuyuanSource.fromJson(item.cast<String, dynamic>()));
        } catch (_) {}
      }
    }
    _initialized = true;
  }

  Future<void> _save() async {
    await _box?.put(
      'list',
      [for (final s in _sources) s.toJson()],
    );
    notifyListeners();
  }

  /// 导入一段书源文本（JSON 数组 / 单对象 / 包装 / NDJSON / XML）。
  /// 返回 [count, skipped]：成功导入数与跳过数。
  Future<({int count, int skipped})> importText(String text) async {
    final parsed = ShuyuanSourceService().parseSources(text);
    var count = 0;
    var skipped = 0;
    for (final src in parsed) {
      if (!src.isValid) {
        skipped++;
        continue;
      }
      if (_sources.any((s) => s.bookSourceUrl == src.bookSourceUrl)) {
        skipped++;
        continue;
      }
      _sources.add(src);
      count++;
    }
    await _save();
    return (count: count, skipped: skipped);
  }

  /// 导入一个书源对象（仓库页编辑后保存 / 单源导入）。
  Future<void> addSource(ShuyuanSource source) async {
    _sources.removeWhere((s) => s.bookSourceUrl == source.bookSourceUrl);
    _sources.add(source);
    await _save();
  }

  /// 删除书源。
  Future<void> removeSource(String bookSourceUrl) async {
    _sources.removeWhere((s) => s.bookSourceUrl == bookSourceUrl);
    await _save();
  }

  /// 启用 / 停用。
  Future<void> setEnabled(String bookSourceUrl, bool enabled) async {
    final idx = _sources.indexWhere((s) => s.bookSourceUrl == bookSourceUrl);
    if (idx < 0) return;
    final old = _sources[idx];
    _sources[idx] = ShuyuanSource(
      bookSourceName: old.bookSourceName,
      bookSourceUrl: old.bookSourceUrl,
      bookSourceType: old.bookSourceType,
      bookSourceGroup: old.bookSourceGroup,
      bookSourceComment: old.bookSourceComment,
      enabled: enabled,
      searchUrl: old.searchUrl,
      exploreUrl: old.exploreUrl,
      header: old.header,
      tocUrl: old.tocUrl,
      ruleSearch: old.ruleSearch,
      ruleBookInfo: old.ruleBookInfo,
      ruleToc: old.ruleToc,
      ruleContent: old.ruleContent,
      ruleExplore: old.ruleExplore,
      filters: old.filters,
      homeSections: old.homeSections,
    );
    await _save();
  }

  /// 按 URL 查源。
  ShuyuanSource? sourceByUrl(String bookSourceUrl) {
    for (final s in _sources) {
      if (s.bookSourceUrl == bookSourceUrl) return s;
    }
    return null;
  }

  /// 全部启用源转为 [XiaoshuoBookSource]（WebBook 消费）。
  List<XiaoshuoBookSource> toBookSources() =>
      [for (final s in _sources) if (s.enabled) s.toBookSource()];

  /// 导出全部源为 JSON 明文。
  String exportJson() => jsonEncode([
        for (final s in _sources) s.toJson(),
      ]);

  /// 首次启动预载：hive box 为空时尝试从 assets 内置书源文件导入。
  /// 内置文件只作兜底，导入后仍以用户编辑为准。
  Future<void> ensureBuiltinSources() async {
    if (_sources.isNotEmpty) return;
    try {
      final raw = await rootBundle.loadString(
        'assets/config/shuyuan_sources.json',
      );
      if (raw.trim().isEmpty) return;
      await importText(raw);
    } catch (_) {
      // assets 文件不存在或解析失败：静默跳过（用户可手动导入）。
    }
  }
}
