// 书架/收藏「更新角标」状态服务 —— 把设置里一直空置的
// 「启动时自动检查书架更新」（checkShelfUpdateOnStart）真正接上。
//
// 数据模型（每本漫画两个数，SharedPreferences 持久化）：
//   fresh：最近一次检查到的最新总章节数（检查更新时写入）
//   ack  ：用户最近一次打开详情页时确认的总章节数（视为已阅）
//   角标数 = max(0, fresh - ack)，即「更新了多少话」。
//
// 扫描（scanShelfAndFavorites）：
//   · 仅设置开关开启时执行（默认关，不偷偷耗流量）；
//   · 合并「收藏全集 + 书架条目 meta 快照」去重 pathWord 后扫描；
//   · 并发 3、单本 20s 超时、单本失败静默跳过（下轮再试）；
//   · 10 分钟冷却 + 扫描互斥，防止页签来回切导致连环轰炸。
//   · 全部完成后一次性 notifyListeners（避免逐本全列表 rebuild）。
//
// 图书（zlibrary 电子书）是整本无章节更新语义，不走本服务；
// 书源页的「更新到 N 章」角标由 latestChapterTitle 本地解析，零网络。

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/reading/models/bookshelf.dart';
import 'package:tvbox/reading/models/comic.dart';
import 'package:tvbox/reading/source/adapter.dart';
import 'package:tvbox/reading/source/source_manager.dart';
import 'package:tvbox/reading/services/bookshelf_service.dart';
import 'package:tvbox/reading/services/favorites_service.dart';
import 'package:tvbox/reading/services/settings_service.dart';

class ShelfUpdateService extends ChangeNotifier {
  ShelfUpdateService._();
  static final ShelfUpdateService instance = ShelfUpdateService._();

  static const _freshPrefix = 'shelfUpdate.fresh.';
  static const _ackPrefix = 'shelfUpdate.ack.';

  /// 漫画的更新状态 key（pathWord 全局唯一）
  static String keyForComic(String pathWord) => 'comic:$pathWord';

  final Map<String, int> _fresh = {};
  final Map<String, int> _ack = {};
  bool _loaded = false;
  Future<void>? _loadFuture;

  Future<void> _load() async {
    if (_loaded) return;
    final f = _loadFuture ??= () async {
      final sp = await SharedPreferences.getInstance();
      for (final k in sp.getKeys()) {
        if (k.startsWith(_freshPrefix)) {
          final v = sp.getInt(k);
          if (v != null) _fresh[k.substring(_freshPrefix.length)] = v;
        } else if (k.startsWith(_ackPrefix)) {
          final v = sp.getInt(k);
          if (v != null) _ack[k.substring(_ackPrefix.length)] = v;
        }
      }
      _loaded = true;
    }();
    await f;
    _loadFuture = null;
  }

  Future<void> _persist(String key) async {
    final sp = await SharedPreferences.getInstance();
    final f = _fresh[key];
    final a = _ack[key];
    if (f == null) {
      await sp.remove(_freshPrefix + key);
    } else {
      await sp.setInt(_freshPrefix + key, f);
    }
    if (a == null) {
      await sp.remove(_ackPrefix + key);
    } else {
      await sp.setInt(_ackPrefix + key, a);
    }
  }

  /// 角标数：fresh - ack（fresh 未扫到或无更新 → 0）
  int newChapters(String key) =>
      math.max(0, (_fresh[key] ?? 0) - (_ack[key] ?? 0));

  /// 用户打开详情页 = 确认看到当前全部章节
  Future<void> ack(String key, int totalChapters) async {
    if (totalChapters <= 0) return;
    await _load();
    if (_ack[key] == totalChapters && (_fresh[key] ?? 0) <= totalChapters) {
      return;
    }
    _ack[key] = totalChapters;
    // 源站章节被重排/回退导致 fresh < ack 时夹住，避免负数态
    if ((_fresh[key] ?? 0) < totalChapters) _fresh[key] = totalChapters;
    await _persist(key);
    notifyListeners();
  }

  /// 清除某本的更新状态（如移出书架/收藏时可选调用）
  Future<void> clear(String key) async {
    await _load();
    if (!_fresh.containsKey(key) && !_ack.containsKey(key)) return;
    _fresh.remove(key);
    _ack.remove(key);
    await _persist(key);
    notifyListeners();
  }

  // ========== 扫描 ==========

  DateTime? _lastScanAt;
  bool _scanning = false;

  /// 扫描收藏 + 书架全部漫画，刷新 fresh。有变化时通知监听方。
  Future<void> scanShelfAndFavorites() async {
    if (_scanning) return;
    if (!SettingsService().checkShelfUpdateOnStart) return;
    final now = DateTime.now();
    if (_lastScanAt != null &&
        now.difference(_lastScanAt!) < const Duration(minutes: 10)) {
      return;
    }
    _scanning = true;
    _lastScanAt = now;
    try {
      // 收集扫描目标：收藏全集 + 书架条目 meta 快照，按 pathWord 去重
      final targets = <String, Comic>{};
      for (final c in FavoritesService().comics) {
        if (c.pathWord.isNotEmpty) targets[c.pathWord] = c;
      }
      for (final it in BookshelfService().items) {
        if (it.type != BookshelfItemType.comic || it.meta == null) continue;
        try {
          final c = Comic.fromJson(
            jsonDecode(it.meta!) as Map<String, dynamic>,
          );
          if (c.pathWord.isNotEmpty) targets[c.pathWord] ??= c;
        } catch (_) {
          // 单条 meta 损坏跳过
        }
      }
      if (targets.isEmpty) return;

      var changed = false;
      var idx = 0;
      final keys = targets.keys.toList(growable: false);
      Future<void> worker() async {
        while (idx < keys.length) {
          final pathWord = keys[idx++];
          final c = targets[pathWord]!;
          try {
            final sourceId = c.sourceId;
            if (sourceId == null || sourceId.isEmpty) continue;
            final source = SourceManager().getSource(sourceId);
            if (source == null) continue;
            final d = await source
                .getMangaDetailsAndChapters(comicToCManga(c, source.id))
                .timeout(const Duration(seconds: 20));
            // 优先 detail 的 totalChapters（常缺失），回退分组章节之和
            var total = cmangaToComic(d.manga).totalChapters;
            if (total == null || total <= 0) {
              total = cchaptersToGroups(d.chapters)
                  .fold<int>(0, (s, g) => s + g.chapters.length);
            }
            if (total > 0) {
              final key = keyForComic(pathWord);
              await _load();
              if (_fresh[key] != total) {
                _fresh[key] = total;
                changed = true;
                await _persist(key);
              }
            }
          } catch (_) {
            // 单本失败静默跳过，下轮扫描再试
          }
        }
      }

      await Future.wait([worker(), worker(), worker()]);
      if (changed) notifyListeners();
    } finally {
      _scanning = false;
    }
  }
}
