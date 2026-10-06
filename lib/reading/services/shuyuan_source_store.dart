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

  /// 启用源列表缓存。内置书源可达数千条，`sources` 会被 UI 在构建期反复读取，
  /// 若每次都 `where().toList()` 过滤全表就是 O(n)——调用 n 次即 O(n²)（实测
  /// 3907 个源时直接卡死闪退）。这里按需计算一次，任何写操作（[_save]）后失效。
  List<ShuyuanSource>? _enabledCache;

  List<ShuyuanSource> get sources {
    final cached = _enabledCache;
    if (cached != null) return cached;
    final list = List<ShuyuanSource>.unmodifiable(
      _sources.where((s) => s.enabled),
    );
    _enabledCache = list;
    return list;
  }

  /// 全部源（含停用），仓库页展示用。
  List<ShuyuanSource> get allSources => List.unmodifiable(_sources);

  bool get initialized => _initialized;

  Future<void> init() async {
    if (_initialized) return;
    _box = await Hive.openBox<dynamic>(_boxName);
    final raw = _box!.get('list', defaultValue: <dynamic>[]) as List;
    _sources.clear();
    _enabledCache = null;
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
    _enabledCache = null; // 启用集合可能变化，作废缓存
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
    // 用 Set 做去重：内置书源可达数千条，逐条 `_sources.any(...)` 是 O(n²)，
    // 首次导入 3907 条时约 760 万次比较，明显拖慢启动。
    final existing = <String>{for (final s in _sources) s.bookSourceUrl};
    for (final src in parsed) {
      if (!src.isValid) {
        skipped++;
        continue;
      }
      if (existing.contains(src.bookSourceUrl)) {
        skipped++;
        continue;
      }
      _sources.add(src);
      existing.add(src.bookSourceUrl);
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

  /// 重排书源顺序（体检页「一键优化」置顶可用源用）：
  /// 传入的 url 列表按顺序排到最前，其余保持原相对顺序在后。
  Future<void> reorder(List<String> firstUrls) async {
    final front = <ShuyuanSource>[];
    for (final u in firstUrls) {
      ShuyuanSource? found;
      for (final s in _sources) {
        if (s.bookSourceUrl == u) {
          found = s;
          break;
        }
      }
      if (found != null && !front.contains(found)) front.add(found);
    }
    final rest =
        _sources.where((s) => !front.contains(s)).toList();
    _sources
      ..clear()
      ..addAll(front)
      ..addAll(rest);
    await _save();
  }

  /// 清空全部书源（仓库页「清空」用）。
  Future<void> clearAll() async {
    _sources.clear();
    await _save();
  }

  /// 全部启用 / 全部停用（仓库页「全部启动 / 全部关闭」用）。
  Future<void> setAllEnabled(bool enabled) async {
    for (var i = 0; i < _sources.length; i++) {
      final old = _sources[i];
      if (old.enabled == enabled) continue;
      _sources[i] = _rebuildWithEnabled(old, enabled);
    }
    await _save();
  }

  /// 按启用状态重建一个源（ShuyuanSource 不可变，逐字段复制）。
  ShuyuanSource _rebuildWithEnabled(ShuyuanSource s, bool enabled) {
    return ShuyuanSource(
      bookSourceName: s.bookSourceName,
      bookSourceUrl: s.bookSourceUrl,
      bookSourceType: s.bookSourceType,
      bookSourceGroup: s.bookSourceGroup,
      bookSourceComment: s.bookSourceComment,
      enabled: enabled,
      searchUrl: s.searchUrl,
      exploreUrl: s.exploreUrl,
      header: s.header,
      tocUrl: s.tocUrl,
      ruleSearch: s.ruleSearch,
      ruleBookInfo: s.ruleBookInfo,
      ruleToc: s.ruleToc,
      ruleContent: s.ruleContent,
      ruleExplore: s.ruleExplore,
      filters: s.filters,
      homeSections: s.homeSections,
    );
  }

  /// 启用 / 停用。
  Future<void> setEnabled(String bookSourceUrl, bool enabled) async {
    final idx = _sources.indexWhere((s) => s.bookSourceUrl == bookSourceUrl);
    if (idx < 0) return;
    _sources[idx] = _rebuildWithEnabled(_sources[idx], enabled);
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
