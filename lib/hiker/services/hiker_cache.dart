import 'dart:convert';
import 'dart:io';

import '../models/hiker_source.dart';
import 'hiker_store.dart';

/// 海阔列表的**本地缓存**。
///
/// 用户 2026-10-18：「每次进去加载好长时间」——
/// 海阔首页/分类的规则执行常常要抓多个网页、跑十几秒；如果每次进模块都
/// 重新跑一遍，体验很差。这里把**首页/分类第一页**的结果落到
/// `<Documents>/hiker/cache/`，下次进来先秒显示缓存，再后台刷新。
///
/// · 只缓存 page == 1（后续页意义不大，且条目多占空间）
/// · 默认 6 小时过期；过期后仍会先显示旧缓存，再等网络结果替换
/// · key = 源 id + 分类地址 + 页码，按 hash 命名
class HikerCache {
  HikerCache._();

  static const Duration maxAge = Duration(hours: 6);

  /// 最多保留的缓存文件数（超过按修改时间删最旧）
  static const int _keep = 40;

  static String keyOf(String sourceId, String cate, int page) =>
      '$sourceId\u0001$cate\u0001$page';

  static String _fileName(String key) {
    var h = 17;
    for (final c in key.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return 'list_${h.toRadixString(16)}.json';
  }

  static Future<Directory?> _dir() async {
    final root = await HikerStore.rootDir();
    if (root == null) return null;
    final dir = Directory('${root.path}/cache');
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
    } catch (_) {
      return null;
    }
    return dir;
  }

  /// 读取缓存。返回 null = 没有/已损坏。
  ///
  /// [allowExpired] = true 时过期缓存也返回（页面先展示旧数据）。
  static Future<({List<HikerItem> items, int savedAt})?> read(
    String key, {
    bool allowExpired = false,
  }) async {
    try {
      final dir = await _dir();
      if (dir == null) return null;
      final f = File('${dir.path}/${_fileName(key)}');
      if (!await f.exists()) return null;
      final decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map) return null;
      final savedAt = (decoded['savedAt'] as num?)?.toInt() ?? 0;
      final expired =
          DateTime.now().millisecondsSinceEpoch - savedAt >
          maxAge.inMilliseconds;
      if (expired && !allowExpired) return null;
      final list = decoded['items'];
      if (list is! List) return null;
      final items = <HikerItem>[];
      for (final e in list) {
        if (e is Map) {
          items.add(HikerItem.fromJson(Map<String, dynamic>.from(e)));
        }
      }
      if (items.isEmpty) return null;
      return (items: items, savedAt: savedAt);
    } catch (_) {
      return null;
    }
  }

  /// 写入缓存（只写 page == 1）。
  static Future<void> write(String key, List<HikerItem> items) async {
    if (items.isEmpty) return;
    try {
      final dir = await _dir();
      if (dir == null) return;
      final f = File('${dir.path}/${_fileName(key)}');
      await f.writeAsString(
        jsonEncode({
          'savedAt': DateTime.now().millisecondsSinceEpoch,
          'items': [for (final i in items) i.toJson()],
        }),
        flush: true,
      );
      await _prune(dir);
    } catch (_) {
      // 缓存失败不影响正常加载
    }
  }

  static Future<void> _prune(Directory dir) async {
    try {
      final files = await dir
          .list()
          .where((e) => e is File && e.path.endsWith('.json'))
          .cast<File>()
          .toList();
      if (files.length <= _keep) return;
      final stats = <(File, DateTime)>[];
      for (final f in files) {
        try {
          stats.add((f, (await f.stat()).modified));
        } catch (_) {}
      }
      stats.sort((a, b) => a.$2.compareTo(b.$2));
      for (var i = 0; i < stats.length - _keep; i++) {
        try {
          await stats[i].$1.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }
}
