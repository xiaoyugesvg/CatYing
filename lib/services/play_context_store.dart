// lib/services/play_context_store.dart
//
// 播放上下文的**持久化仓库** —— 彻底干掉「Spider 上下文缺失」。
//
// ── 问题（用户 2026-10-29 截图）────────────────────────────────
// `SpiderService` 把当前源上下文放在一个**进程内单例字段**里：
//   · 只有首页/分类/详情的列表接口会写它；
//   · `invalidateSession()`（回前台时由场景恢复调用）会把它清空；
//   · 从历史 / 收藏 / 换线路直接进详情页时没人再写它。
// ⇒ 详情页拿到空上下文就报「Spider 上下文缺失，请从首页重新进入该源」，
//   用户只能退出去重进，播放链路直接断掉。
//
// ── 这里的做法 ───────────────────────────────────────────────
// 以**源 key** 为索引，把「引擎 key / type / api / ext / jar」落到
// SharedPreferences，内存 + 磁盘双层：
//   · 内存层给同步查询（`peek`），磁盘层给冷启动 / 杀进程后恢复（`lookup`）；
//   · 每次 `setCurrentSpider` 都顺手记一笔（见 SpiderService），
//     首页、分类、详情、搜索任何入口走过一次，这个源就永久可恢复；
//   · 详情页上下文为空 / 与实际源不匹配时，先按源 key 查这里再重建。
//
// 单条 JSON blob 存储（而不是每个源一个 key）：条数上限、批量写入、清理都简单。
library;

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/models/source_bean.dart';
import 'package:tvbox/services/app_log.dart';

/// 一个源的可复原播放上下文。
class PlayContext {
  /// 配置里的**原始** source key（可能带 `nodejs_` 前缀，用于和 vod.sourceKey 对齐）
  final String sourceKey;

  /// 引擎路由用的 key（去掉 `nodejs_` 前缀）
  final String engineKey;

  final int type;
  final String api;
  final String ext;
  final String jar;
  final int updatedAt;

  const PlayContext({
    required this.sourceKey,
    required this.engineKey,
    required this.type,
    required this.api,
    required this.ext,
    required this.jar,
    this.updatedAt = 0,
  });

  bool get usable => engineKey.trim().isNotEmpty;

  PlayContext copyWith({String? sourceKey, int? updatedAt}) => PlayContext(
        sourceKey: sourceKey ?? this.sourceKey,
        engineKey: engineKey,
        type: type,
        api: api,
        ext: ext,
        jar: jar,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'sourceKey': sourceKey,
        'engineKey': engineKey,
        'type': type,
        'api': api,
        'ext': ext,
        'jar': jar,
        'updatedAt': updatedAt,
      };

  static PlayContext? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final engineKey = (raw['engineKey'] ?? '').toString().trim();
    if (engineKey.isEmpty) return null;
    return PlayContext(
      sourceKey: (raw['sourceKey'] ?? '').toString(),
      engineKey: engineKey,
      type: (raw['type'] as num?)?.toInt() ?? 0,
      api: (raw['api'] ?? '').toString(),
      ext: (raw['ext'] ?? '').toString(),
      jar: (raw['jar'] ?? '').toString(),
      updatedAt: (raw['updatedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

class PlayContextStore {
  PlayContextStore._();
  static final PlayContextStore instance = PlayContextStore._();

  static const String _prefsKey = 'play_context_v1';
  static const int _maxEntries = 300;

  final Map<String, PlayContext> _memory = {};
  SharedPreferences? _prefs;
  Future<void>? _loading;
  Timer? _persistTimer;

  /// 归一化 key：`nodejs_xxx` 与 `xxx` 视为同一个源。
  static String normalizeKey(String key) {
    final k = key.trim();
    if (k.toLowerCase().startsWith('nodejs_')) return k.substring(7);
    return k;
  }

  Future<void> _ensureLoaded() {
    return _loading ??= () async {
      try {
        final p = await SharedPreferences.getInstance();
        _prefs = p;
        final raw = p.getString(_prefsKey);
        if (raw == null || raw.isEmpty) return;
        final decoded = jsonDecode(raw);
        if (decoded is! Map) return;
        decoded.forEach((k, v) {
          final ctx = PlayContext.fromJson(v);
          if (ctx == null) return;
          final key = k.toString();
          final existing = _memory[key];
          if (existing == null || ctx.updatedAt >= existing.updatedAt) {
            _memory[key] = ctx;
          }
        });
        AppLog.instance.log('[PlayCtx] 已恢复 ${_memory.length} 个源的播放上下文');
      } catch (e) {
        AppLog.instance.log('[PlayCtx] 读取失败: $e');
      }
    }();
  }

  /// 同步查询（只在已加载后可靠；用于不阻塞的展示/日志）。
  PlayContext? peek(String sourceKey) {
    final k = sourceKey.trim();
    if (k.isEmpty) return null;
    return _memory[k] ??
        _memory[normalizeKey(k)] ??
        _memory[k.toLowerCase()];
  }

  /// 异步查询：必要时先从磁盘加载。
  Future<PlayContext?> lookup(String sourceKey) async {
    await _ensureLoaded();
    return peek(sourceKey);
  }

  /// 记录一个源（来源：SourceBean）。
  void rememberBean(SourceBean bean) {
    final raw = bean.key.trim();
    if (raw.isEmpty) return;
    final engineKey = normalizeKey(raw);
    if (engineKey.isEmpty) return;
    final ctx = PlayContext(
      sourceKey: raw,
      engineKey: engineKey,
      type: bean.type,
      api: bean.api.trim(),
      ext: (bean.ext ?? '').trim(),
      jar: (bean.jar ?? '').trim(),
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _write(ctx);
  }

  /// 记录一次 Spider 上下文（来源：`SpiderService.setCurrentSpider`）。
  ///
  /// 调用方给的 [key] 可能已经被去过 `nodejs_` 前缀；这里两种形态都落一份，
  /// 保证无论详情页用哪个 key 查都能命中。
  void rememberSpider({
    required String key,
    required int type,
    required String api,
    required String ext,
    required String jar,
  }) {
    final raw = key.trim();
    if (raw.isEmpty) return;
    final engineKey = normalizeKey(raw);
    if (engineKey.isEmpty) return;
    final ctx = PlayContext(
      sourceKey: raw,
      engineKey: engineKey,
      type: type,
      api: api.trim(),
      ext: ext.trim(),
      jar: jar.trim(),
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _write(ctx);
    // 原始 key 与归一化 key 不是同一个串时，额外补一份带前缀的
    if (raw != engineKey) {
      _memory[raw] = ctx.copyWith(sourceKey: raw);
    } else {
      _memory['nodejs_$raw'] = ctx.copyWith(sourceKey: 'nodejs_$raw');
    }
  }

  void _write(PlayContext ctx) {
    _memory[ctx.engineKey] = ctx;
    _memory[ctx.sourceKey] = ctx;
    _schedulePersist();
  }

  /// 合并写（500ms 防抖）：首页/分类/详情连续切源时不会每次都落盘。
  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 500), _persist);
  }

  Future<void> _persist() async {
    try {
      await _ensureLoaded();
      final prefs = _prefs;
      if (prefs == null) return;
      // 超上限时淘汰最旧的（updatedAt 最小）
      if (_memory.length > _maxEntries) {
        final entries = _memory.entries.toList()
          ..sort((a, b) => a.value.updatedAt.compareTo(b.value.updatedAt));
        for (var i = 0; i < entries.length - _maxEntries; i++) {
          _memory.remove(entries[i].key);
        }
      }
      final out = <String, dynamic>{
        for (final e in _memory.entries) e.key: e.value.toJson(),
      };
      await prefs.setString(_prefsKey, jsonEncode(out));
    } catch (e) {
      AppLog.instance.log('[PlayCtx] 写入失败: $e');
    }
  }

  /// 清空（设置页「清除播放缓存」类操作可调用）。
  Future<void> clear() async {
    _memory.clear();
    _persistTimer?.cancel();
    await _ensureLoaded();
    try {
      await _prefs?.remove(_prefsKey);
    } catch (_) {}
  }
}
