import 'dart:convert';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import '../services/app_log.dart';
import 'cache_ttl.dart';
import 'movie.dart';

String makeVodBusinessKey(String vodId, String sourceKey) {
  final normalizedVodId = vodId.trim();
  final normalizedSourceKey = sourceKey.trim();
  return '$normalizedSourceKey::$normalizedVodId';
}

class VodPlaybackState {
  String flag;
  int episodeIndex;
  double progressSeconds;

  VodPlaybackState({
    required this.flag,
    required this.episodeIndex,
    required this.progressSeconds,
  });

  Map<String, dynamic> toJson() => {
        'flag': flag,
        'episodeIndex': episodeIndex,
        'progressSeconds': progressSeconds,
      };

  factory VodPlaybackState.fromJson(Map<String, dynamic> json) {
    return VodPlaybackState(
      flag: json['flag'] as String? ?? '',
      episodeIndex: json['episodeIndex'] as int? ?? 0,
      progressSeconds: (json['progressSeconds'] as num?)?.toDouble() ?? 0,
    );
  }
}

class VodCollect {
  String bizKey;
  String vodId;
  String vodName;
  String vodPic;
  String sourceKey;
  DateTime updateTime;

  VodCollect({
    required this.vodId,
    required this.vodName,
    required this.vodPic,
    required this.sourceKey,
  })  : bizKey = makeVodBusinessKey(vodId, sourceKey),
        updateTime = DateTime.now();

  factory VodCollect.fromJson(Map<String, dynamic> json) {
    final collect = VodCollect(
      vodId: json['vodId'] as String? ?? '',
      vodName: json['vodName'] as String? ?? '',
      vodPic: json['vodPic'] as String? ?? '',
      sourceKey: json['sourceKey'] as String? ?? '',
    );
    if (json['bizKey'] != null) {
      collect.bizKey = json['bizKey'] as String;
    }
    if (json['updateTime'] != null) {
      collect.updateTime = DateTime.parse(json['updateTime'] as String);
    }
    return collect;
  }

  Map<String, dynamic> toJson() => {
        'bizKey': bizKey,
        'vodId': vodId,
        'vodName': vodName,
        'vodPic': vodPic,
        'sourceKey': sourceKey,
        'updateTime': updateTime.toIso8601String(),
      };

  String get id => bizKey;
}

class VodRecord {
  String bizKey;
  String vodId;
  String vodName;
  String vodPic;
  String sourceKey;
  String playNote;
  String dataJson;
  DateTime updateTime;

  VodRecord({
    required this.vodId,
    required this.vodName,
    required this.vodPic,
    required this.sourceKey,
    this.playNote = '',
    this.dataJson = '',
  })  : bizKey = makeVodBusinessKey(vodId, sourceKey),
        updateTime = DateTime.now();

  factory VodRecord.fromJson(Map<String, dynamic> json) {
    final record = VodRecord(
      vodId: json['vodId'] as String? ?? '',
      vodName: json['vodName'] as String? ?? '',
      vodPic: json['vodPic'] as String? ?? '',
      sourceKey: json['sourceKey'] as String? ?? '',
      playNote: json['playNote'] as String? ?? '',
      dataJson: json['dataJson'] as String? ?? '',
    );
    if (json['bizKey'] != null) {
      record.bizKey = json['bizKey'] as String;
    }
    if (json['updateTime'] != null) {
      record.updateTime = DateTime.parse(json['updateTime'] as String);
    }
    return record;
  }

  Map<String, dynamic> toJson() => {
        'bizKey': bizKey,
        'vodId': vodId,
        'vodName': vodName,
        'vodPic': vodPic,
        'sourceKey': sourceKey,
        'playNote': playNote,
        'dataJson': dataJson,
        'updateTime': updateTime.toIso8601String(),
      };

  String get id => bizKey;
}

class CacheItem {
  String key;
  String value;
  DateTime updateTime;

  CacheItem({required this.key, required this.value})
      : updateTime = DateTime.now();

  factory CacheItem.fromJson(Map<String, dynamic> json) {
    final item = CacheItem(
      key: json['key'] as String? ?? '',
      value: json['value'] as String? ?? '',
    );
    if (json['updateTime'] != null) {
      item.updateTime = DateTime.parse(json['updateTime'] as String);
    }
    return item;
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'value': value,
        'updateTime': updateTime.toIso8601String(),
      };
}

class CacheStore {
  static final CacheStore _instance = CacheStore._internal();
  static CacheStore get instance => _instance;
  CacheStore._internal();

  static const String _collectsBoxName = 'vod_collects';
  static const String _recordsBoxName = 'vod_records';
  static const String _cacheItemsBoxName = 'cache_items';

  final favorites = <VodCollect>[].obs;
  final records = <VodRecord>[].obs;

  Box<dynamic>? _collectsBox;
  Box<dynamic>? _recordsBox;
  Box<dynamic>? _cacheItemsBox;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    _collectsBox = await Hive.openBox(_collectsBoxName);
    _recordsBox = await Hive.openBox(_recordsBoxName);
    _cacheItemsBox = await Hive.openBox(_cacheItemsBoxName);

    favorites.value = _loadFromBox<VodCollect>(_collectsBox!);
    records.value = _loadFromBox<VodRecord>(_recordsBox!);

    _initialized = true;
  }

  /// 单条写入（key = bizKey），避免全量 clear+put
  Future<void> _putBoxItem<T>(Box<dynamic> box, String key, T item) async {
    try {
      await box.put(key, (item as dynamic).toJson());
    } catch (e) {
      AppLog.instance.log('cache put fail: ' + e.toString());
    }
  }

  Future<void> _deleteBoxItem(Box<dynamic> box, String key) async {
    try {
      await box.delete(key);
    } catch (e) {
      AppLog.instance.log('cache del fail: ' + e.toString());
    }
  }

  /// 按 (vodId, sourceKey) 删除所有历史遗留箱内条目
  ///
  /// 老版本写入时 bizKey 可能为空串（箱键就是空串）或用旧格式，此时用新算出的
  /// `bizKey` 调 box.delete 删不掉 → 该条目残留在磁盘上，下次启动 _loadFromBox
  /// 又把它读回内存，表现为「用户删掉的收藏/历史自己复活了」。
  /// 这里按箱内实际内容匹配 (vodId, sourceKey) 一并删除。
  Future<void> _deleteBoxItemsByVodKey(
    Box<dynamic> box,
    String vodId,
    String sourceKey,
  ) async {
    try {
      final stale = <dynamic>[];
      for (final k in box.keys) {
        final raw = box.get(k);
        if (raw is! Map) continue;
        final itemVodId = raw['vodId']?.toString() ?? '';
        final itemSourceKey = raw['sourceKey']?.toString() ?? '';
        if (itemVodId == vodId && itemSourceKey == sourceKey) {
          stale.add(k);
        }
      }
      for (final k in stale) {
        await box.delete(k);
      }
    } catch (e) {
      AppLog.instance.log('cache del-by-vod fail: ' + e.toString());
    }
  }

  T _fromJson<T>(Map<String, dynamic> json) {
    if (T == VodCollect) return VodCollect.fromJson(json) as T;
    if (T == VodRecord) return VodRecord.fromJson(json) as T;
    throw UnsupportedError('unsupported type ' + T.toString());
  }

  List<T> _loadFromBox<T>(Box<dynamic> box) {
    final out = <T>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw is Map) {
        try {
          // ignore: avoid_dynamic_calls
          out.add(_fromJson<T>(Map<String, dynamic>.from(raw)));
        } catch (e) {
          AppLog.instance.log('cache parse fail: ' + e.toString());
        }
      }
    }
    return out;
  }


  Future<void> addCollect(Video video) async {
    final vodId = video.id;
    final sourceKey = video.sourceKey;
    final bizKey = makeVodBusinessKey(vodId, sourceKey);

    final items = List<VodCollect>.from(favorites);
    final matchedIndices = <int>[];
    for (int i = 0; i < items.length; i++) {
      if (items[i].bizKey == bizKey ||
          (items[i].bizKey.isEmpty &&
              items[i].vodId == vodId &&
              items[i].sourceKey == sourceKey)) {
        matchedIndices.add(i);
      }
    }

    if (matchedIndices.isNotEmpty) {
      final firstIndex = matchedIndices.first;
      items[firstIndex].bizKey = bizKey;
      items[firstIndex].vodName = video.name;
      items[firstIndex].vodPic = video.pic;
      items[firstIndex].updateTime = DateTime.now();
      // Remove duplicates (keep first, remove rest in reverse order)
      for (final index in matchedIndices.reversed.where((i) => i != firstIndex)) {
        items.removeAt(index);
      }
    } else {
      final collect = VodCollect(
        vodId: vodId,
        vodName: video.name,
        vodPic: video.pic,
        sourceKey: sourceKey,
      );
      items.insert(0, collect);
    }

    favorites.value = items;
    final toSave = items.firstWhereOrNull(
        (e) => e.bizKey == bizKey || (e.vodId == vodId && e.sourceKey == sourceKey));
    if (toSave != null) {
      await _putBoxItem(_collectsBox!, bizKey, toSave);
    }
  }

  Future<void> removeCollect(String vodId, String sourceKey) async {
    final bizKey = makeVodBusinessKey(vodId, sourceKey);
    favorites.removeWhere((item) =>
        item.bizKey == bizKey ||
        (item.bizKey.isEmpty &&
            item.vodId == vodId &&
            item.sourceKey == sourceKey));
    await _deleteBoxItem(_collectsBox!, bizKey);
    // 清掉旧键/空键遗留的同一条目，否则重启后会从箱里读回来（"删除后复活"）
    await _deleteBoxItemsByVodKey(_collectsBox!, vodId, sourceKey);
  }

  bool isCollected(String vodId, String sourceKey) {
    final bizKey = makeVodBusinessKey(vodId, sourceKey);
    return favorites.any((item) =>
        item.bizKey == bizKey ||
        (item.bizKey.isEmpty &&
            item.vodId == vodId &&
            item.sourceKey == sourceKey));
  }

  Future<void> addRecord(
    Video video,
    String playNote, {
    VodPlaybackState? playbackState,
  }) async {
    final vodId = video.id;
    final sourceKey = video.sourceKey;
    final encodedState = _encodePlaybackState(playbackState);
    final bizKey = makeVodBusinessKey(vodId, sourceKey);

    final items = List<VodRecord>.from(records);
    final matchedIndices = <int>[];
    for (int i = 0; i < items.length; i++) {
      if (items[i].bizKey == bizKey ||
          (items[i].bizKey.isEmpty &&
              items[i].vodId == vodId &&
              items[i].sourceKey == sourceKey)) {
        matchedIndices.add(i);
      }
    }

    if (matchedIndices.isNotEmpty) {
      final firstIndex = matchedIndices.first;
      items[firstIndex].bizKey = bizKey;
      items[firstIndex].playNote = playNote;
      if (encodedState != null) {
        items[firstIndex].dataJson = encodedState;
      }
      items[firstIndex].updateTime = DateTime.now();
      // Remove duplicates (keep first, remove rest in reverse order)
      for (final index in matchedIndices.reversed.where((i) => i != firstIndex)) {
        items.removeAt(index);
      }
    } else {
      final record = VodRecord(
        vodId: vodId,
        vodName: video.name,
        vodPic: video.pic,
        sourceKey: sourceKey,
        playNote: playNote,
      );
      if (encodedState != null) {
        record.dataJson = encodedState;
      }
      items.insert(0, record);
    }

    records.value = items;
    final toSave = items.firstWhereOrNull(
        (e) => e.bizKey == bizKey || (e.vodId == vodId && e.sourceKey == sourceKey));
    if (toSave != null) {
      await _putBoxItem(_recordsBox!, bizKey, toSave);
    }
  }

  VodPlaybackState? getPlaybackState(String vodId, String sourceKey) {
    final bizKey = makeVodBusinessKey(vodId, sourceKey);
    final record = records.firstWhereOrNull((item) =>
        item.bizKey == bizKey ||
        (item.bizKey.isEmpty &&
            item.vodId == vodId &&
            item.sourceKey == sourceKey));
    if (record == null || record.dataJson.isEmpty) return null;
    return _decodePlaybackState(record.dataJson);
  }

  Future<void> clearHistory() async {
    records.value = [];
    await _recordsBox!.clear();
  }

  Future<void> removeRecord(String vodId, String sourceKey) async {
    final bizKey = makeVodBusinessKey(vodId, sourceKey);
    records.removeWhere((item) =>
        item.bizKey == bizKey ||
        (item.bizKey.isEmpty &&
            item.vodId == vodId &&
            item.sourceKey == sourceKey));
    await _deleteBoxItem(_recordsBox!, bizKey);
    // 同 removeCollect：清理旧键/空键遗留条目，避免重启后历史复活
    await _deleteBoxItemsByVodKey(_recordsBox!, vodId, sourceKey);
  }

  /// 业务缓存条目上限（LRU 淘汰）。
  ///
  /// 实测单条体积：分类列表 30 条/页约 24KB（去掉简介后约 11KB），
  /// TMDB 详情响应（含 cast/similar）约 30~60KB。
  /// 100 条 ≈ 1.1~6MB，已足够覆盖「首页 10 个分类 + 常用筛选组合」；
  /// 原来 200 条在最坏情况下会到 10MB+，且这些内容都在 Documents 下（用户可见）。
  static const int _maxCacheItems = 100;

  Future<void> setCacheItem(String key, String value) async {
    final box = _cacheItemsBox!;
    final item = CacheItem(key: key, value: value);
    await box.put(key, item.toJson());
    // 容量上限 + LRU 淘汰
    if (box.length > _maxCacheItems) {
      final keys = box.keys.toList();
      final entries = <String, DateTime>{};
      for (final k in keys) {
        final raw = box.get(k);
        if (raw is Map) {
          final ts = raw['updateTime'];
          entries[k.toString()] = ts != null
              ? DateTime.tryParse(ts.toString()) ?? DateTime.fromMillisecondsSinceEpoch(0)
              : DateTime.fromMillisecondsSinceEpoch(0);
        }
      }
      final sorted = entries.keys.toList()
        ..sort((a, b) => entries[a]!.compareTo(entries[b]!));
      final overflow = box.length - _maxCacheItems;
      for (var i = 0; i < overflow && i < sorted.length; i++) {
        await box.delete(sorted[i]);
      }
    }
  }

  String? getCacheItem(String key) {
    final raw = _cacheItemsBox!.get(key);
    if (raw is Map) {
      return raw['value'] as String?;
    }
    return null;
  }

  /// 带 TTL 的缓存读取：过期返回 null
  String? getCacheItemFresh(String key, {Duration ttl = CacheTtl.fallback}) {
    final items = _loadCacheItems();
    final item = items.firstWhereOrNull((item) => item.key == key);
    if (item == null) return null;
    if (DateTime.now().difference(item.updateTime) > ttl) return null;
    return item.value;
  }

  /// JSON 对象缓存（列表/配置通用）
  Future<void> setJsonCache(String key, Object? json) async {
    try {
      await setCacheItem(key, jsonEncode(json));
    } catch (e) { /* ignore */ }
  }

  Map<String, dynamic>? getJsonCache(
    String key, {
    Duration ttl = CacheTtl.fallback,
  }) {
    try {
      final raw = getCacheItemFresh(key, ttl: ttl);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return null;
    } catch (_) {
      return null;
    }
  }

  List<dynamic>? getJsonListCache(
    String key, {
    Duration ttl = CacheTtl.fallback,
  }) {
    try {
      final raw = getCacheItemFresh(key, ttl: ttl);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> removeCacheItem(String key) async {
    await _cacheItemsBox!.delete(key);
  }

  /// 业务缓存（cache_items box）占用的近似字节数。
  ///
  /// 这些内容存在 Hive 文件里（含首页分类列表、详情缓存、TMDB 响应），
  /// 之前「缓存大小」只统计了图片/临时目录，导致显示值明显偏小。
  int cacheItemsByteSize() {
    final box = _cacheItemsBox;
    if (box == null) return 0;
    var total = 0;
    for (final k in box.keys) {
      final raw = box.get(k);
      if (raw is Map) {
        final v = raw['value'];
        if (v is String) total += v.length;
      }
    }
    return total;
  }

  /// 业务缓存条目数（用于设置页展示「N 项」）
  int cacheItemsCount() {
    final box = _cacheItemsBox;
    if (box == null) return 0;
    return box.length;
  }

  /// 清空业务缓存：首页分类列表 / 详情缓存 / TMDB 刮削缓存。
  ///
  /// **不动**收藏（vod_collects）与观看历史（vod_records）—— 那两个是用户数据，
  /// 有各自的清理入口。清空后相关页面下次会重新联网获取。
  Future<void> clearItemsCache() async {
    try {
      await _cacheItemsBox?.clear();
      AppLog.instance.log('[CacheStore] business cache cleared');
    } catch (e) {
      AppLog.instance.log('[CacheStore] clearItemsCache fail: $e');
    }
  }

  List<CacheItem> _loadCacheItems() {
    final box = _cacheItemsBox!;
    final items = <CacheItem>[];
    for (var i = 0; i < box.length; i++) {
      final raw = box.getAt(i);
      if (raw != null && raw is Map) {
        items.add(CacheItem.fromJson(Map<String, dynamic>.from(raw)));
      }
    }
    return items;
  }

  Future<void> _saveCacheItems(List<CacheItem> items) async {
    final box = _cacheItemsBox!;
    await box.clear();
    for (int i = 0; i < items.length; i++) {
      await box.put(i, items[i].toJson());
    }
  }

  static String? _encodePlaybackState(VodPlaybackState? state) {
    if (state == null) return null;
    return jsonEncode(state.toJson());
  }

  static VodPlaybackState? _decodePlaybackState(String json) {
    try {
      return VodPlaybackState.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }
}
