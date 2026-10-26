import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:tvbox/models/cache_store.dart';
import 'package:tvbox/models/movie.dart';
import 'package:tvbox/reading/source/global_proxy.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/webhome/webhtv_playback_sync_page.dart';

/// 「观影记录同步」**引擎**（第 7 步 · 块 1，用户 2026-10-15）。
///
/// 协议：WebHomeTV《应用完整开发文档》13.4，版本 `webhtv.playback.v1`
/// （完整协议摘要见 `webhtv_playback_sync_page.dart` 的文档注释）。
///
/// 本文件实现**纯客户端**的两条通道：
///   · **上报**（Webhook）：`reportProgress / reportEnded / reportDeleted`
///   · **拉取合并**：`pull(source)` → 合并进本机历史（`CacheStore.addRecord`）、
///     按三档定位删除（`removeRecord / clearHistory`）
///
/// ── 接线状态 ────────────────────────────────────────────────
///   · 进度/暂停退出/切集切线路前上报 → `detail/view.dart` 的
///     `_saveHistoryForCurrentEpisode`（唯一进度落盘点）已接
///   · 自然完播上报 → `detail/view.dart` 的 `onEnded` 已接
///   · 历史页删除 → `history/controller.dart` 已接
///   · 启动/周期自动 pull → `beginAutoSync()`，由 `main.dart` 调用
class WebhtvPlaybackSyncService {
  WebhtvPlaybackSyncService._() {
    // 配置页改动（总开关 / 源列表 / 周期）后重建自动同步调度。
    // 用回调反向通知，避免 page ↔ service 循环 import。
    WebhtvPlaybackSyncStore.instance.onConfigChanged = () {
      unawaited(restartAutoSync());
    };
  }

  static final WebhtvPlaybackSyncService instance = WebhtvPlaybackSyncService._();

  static const String schema = 'webhtv.playback.v1';

  /// 游标：`<sourceUrl>|<configKey>` → nextSince
  static const String _kCursors = 'webhtv_playback_cursors';
  /// 删除墓碑：`[{"siteKey","vodId","historyKey","scope","deletedAt"}]`（保留 90 天）
  static const String _kTombstones = 'webhtv_playback_tombstones';

  static const int _tombstoneDays = 90;

  Dio _dio() {
    final d = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 20),
      followRedirects: true,
      responseType: ResponseType.plain,
    ));
    applyGlobalProxy(d);
    return d;
  }

  // ============================================================
  // 身份
  // ============================================================

  /// `configKey` = 点播接口 URL 的 SHA256（跨端稳定身份；`cid` 不行）
  static String configKeyOf(String configUrl) =>
      sha256.convert(utf8.encode(configUrl.trim())).toString();

  static String get _currentConfigUrl => ApiConfig.instance.configUrl.value;

  static String get _currentConfigKey => configKeyOf(_currentConfigUrl);

  static String get _currentConfigName {
    final list = ApiConfig.instance.sourceBeanList;
    final cur = ApiConfig.instance.homeSourceBean.value;
    if (cur != null && cur.name.isNotEmpty) return cur.name;
    return list.isNotEmpty ? list.first.name : '';
  }

  /// 播放条目去重 key（**不含 token**）：站点 + 影片 + 线路 + 集
  static String dedupeKey({
    required String siteKey,
    required String vodId,
    required String flag,
    required int episodeIndex,
  }) =>
      sha256
          .convert(utf8.encode('$siteKey|$vodId|$flag|$episodeIndex'))
          .toString();

  /// `historyKey`：本项目历史主键是 `siteKey::vodId`（见 `makeVodBusinessKey`）
  static String historyKeyOf(String siteKey, String vodId) => '$siteKey::$vodId';

  // ============================================================
  // 上报（Webhook）
  // ============================================================

  /// 组装一条事件的 payload（按预设裁剪字段；删除事件不发进度字段）
  static Map<String, dynamic> buildPayload({
    required String event, // playback.progress / playback.ended / playback.deleted
    required String eventId,
    WebhookPreset preset = WebhookPreset.standard,
    String scope = 'item',
    int? deletedAt,
    String siteKey = '',
    String siteName = '',
    String vodId = '',
    String vodName = '',
    String vodPic = '',
    String flag = '',
    String episodeName = '',
    String episodeUrl = '',
    int episodeIndex = 0,
    String sessionId = '',
    String state = 'playing',
    int positionMs = 0,
    int durationMs = 0,
    double speed = 1.0,
    bool completed = false,
    String appVersion = '',
    String clientKey = '',
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final isDelete = event == 'playback.deleted';
    final p = <String, dynamic>{
      'schema': schema,
      'event': event,
      'eventId': eventId,
      'timestamp': now,
      'scope': scope,
      'deletedAt': isDelete ? (deletedAt ?? now) : null,
      'sessionId': sessionId,
      'dedupeKey': dedupeKey(
          siteKey: siteKey, vodId: vodId, flag: flag, episodeIndex: episodeIndex),
      'cid': 1,
      'configKey': _currentConfigKey,
      'configName': _currentConfigName,
      'historyKey': historyKeyOf(siteKey, vodId),
      'siteKey': siteKey,
      'siteName': siteName.isEmpty ? siteKey : siteName,
      'vodId': vodId,
      'vodName': vodName,
      'vodPic': vodPic,
      'flag': flag,
      'episodeName': episodeName,
    };
    if (!isDelete) {
      p.addAll({
        'state': state,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'progress': durationMs > 0 ? positionMs / durationMs : 0.0,
        'speed': speed,
        'completed': completed,
      });
    }
    if (preset != WebhookPreset.basic) {
      p['appVersion'] = appVersion;
      p['client'] = 'mobile';
    }
    if (preset == WebhookPreset.full) {
      p.addAll({
        'episodeUrl': episodeUrl,
        'episodeIndex': episodeIndex,
        'clientKey': clientKey,
      });
    }
    return p;
  }

  /// 上报一条事件到**所有启用**的 Webhook 端点。
  ///
  /// 请求头按文档：`X-WebHTV-Timestamp`(秒) / `-Token` / `-Webhook-Id` /
  /// `-Dedupe-Key` / `-Config-Key` / `-Config-Name` + `Idempotency-Key`(=eventId)。
  Future<void> report(Map<String, dynamic> payload) async {
    final store = WebhtvPlaybackSyncStore.instance;
    if (!store.loaded) await store.load();
    if (!store.enabled) return;
    final hooks = store.webhooks.where((w) => w.enabled).toList();
    if (hooks.isEmpty) return;

    final eventId = (payload['eventId'] ?? const Uuid().v4()).toString();
    final dedupe = (payload['dedupeKey'] ?? '').toString();
    for (final w in hooks) {
      final dio = _dio();
      try {
        await dio.post<dynamic>(
          w.url,
          data: jsonEncode(payload),
          options: Options(
            contentType: 'application/json',
            headers: {
              'X-WebHTV-Timestamp':
                  (DateTime.now().millisecondsSinceEpoch ~/ 1000).toString(),
              if (w.token.isNotEmpty) 'X-WebHTV-Token': w.token,
              'X-WebHTV-Webhook-Id': eventId,
              'X-WebHTV-Dedupe-Key': dedupe,
              'X-WebHTV-Config-Key': _currentConfigKey,
              'X-WebHTV-Config-Name': _currentConfigName,
              'Idempotency-Key': eventId,
            },
          ),
        );
      } catch (e) {
        AppLog.instance.log('[PlaybackSync] 上报失败 ${w.url}: $e');
      } finally {
        dio.close(force: true);
      }
    }
  }

  /// 便捷：进度 / 完播 / 删除
  Future<void> reportProgress({
    required String siteKey,
    required String vodId,
    required String vodName,
    String vodPic = '',
    String flag = '',
    String episodeName = '',
    String episodeUrl = '',
    int episodeIndex = 0,
    int positionMs = 0,
    int durationMs = 0,
    double speed = 1.0,
    String state = 'playing',
    bool ended = false,
  }) async {
    final store = WebhtvPlaybackSyncStore.instance;
    if (!store.loaded) await store.load();
    // 总开关关闭 / 无启用端点 → 直接返回：**热路径（每 5 秒一次）零开销**，
    // 保证本模块在关闭时对影视/直播/阅读等其它模块没有任何影响。
    if (!store.enabled) return;
    final hooks = store.webhooks.where((e) => e.enabled).toList();
    if (hooks.isEmpty) return;
    try {
      // 每个端点用自己的预设组包
      for (final w in hooks) {
        await report(buildPayload(
          event: ended ? 'playback.ended' : 'playback.progress',
          eventId: const Uuid().v4(),
          preset: w.preset,
          siteKey: siteKey,
          vodId: vodId,
          vodName: vodName,
          vodPic: vodPic,
          flag: flag,
          episodeName: episodeName,
          episodeUrl: episodeUrl,
          episodeIndex: episodeIndex,
          positionMs: positionMs,
          durationMs: durationMs,
          speed: speed,
          state: ended ? 'ended' : state,
          completed: ended,
        ));
      }
    } catch (e) {
      // 兜底：绝不让同步异常冒泡影响播放链路
      AppLog.instance.log('[PlaybackSync] reportProgress 异常: $e');
    }
  }

  Future<void> reportDeleted({
    required String siteKey,
    required String vodId,
    String scope = 'item',
  }) async {
    final store = WebhtvPlaybackSyncStore.instance;
    if (!store.loaded) await store.load();
    final now = DateTime.now().millisecondsSinceEpoch;
    // 先记本地墓碑：阻止远端更旧的进度把这条记录"复活"
    await _addTombstone({
      'siteKey': siteKey,
      'vodId': vodId,
      'historyKey': historyKeyOf(siteKey, vodId),
      'scope': scope,
      'deletedAt': now,
    });
    for (final w in store.webhooks.where((e) => e.enabled)) {
      await report(buildPayload(
        event: 'playback.deleted',
        eventId: const Uuid().v4(),
        preset: w.preset,
        scope: scope,
        deletedAt: now,
        siteKey: siteKey,
        vodId: vodId,
      ));
    }
  }

  // ============================================================
  // 墓碑
  // ============================================================

  Future<List<Map<String, dynamic>>> _tombstones() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kTombstones) ?? '[]';
      final l = jsonDecode(raw);
      if (l is! List) return [];
      final cutoff = DateTime.now()
          .subtract(const Duration(days: _tombstoneDays))
          .millisecondsSinceEpoch;
      return l
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .where((e) => ((e['deletedAt'] as num?)?.toInt() ?? 0) >= cutoff)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 串行化 prefs 的「读-改-写」。
  ///
  /// 为什么需要：`beginAutoSync()` 会对多个源**并发** `unawaited(_pullGuarded(s))`，
  /// 每个 pull 结束都要写游标、每条删除都要写墓碑 —— 并发地对同一份 JSON
  /// 「读出来、改一处、整块写回」会**后写覆盖先写**，把另一个源的游标/墓碑吃掉
  ///（现象：某个源反复重复合并同一批记录，或游标卡住不前进）。
  /// 这里把它们串成一条链，逐个执行。
  Future<void> _prefsChain = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() job) {
    final run = _prefsChain.then((_) => job());
    // 链上不保留异常：一次失败不该让后续的写入全部短路
    _prefsChain = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<void> _addTombstone(Map<String, dynamic> t) => _serialized(() async {
        final list = await _tombstones();
        list.add(t);
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_kTombstones, jsonEncode(list));
        } catch (e) {
          AppLog.instance.log('[PlaybackSync] 写墓碑失败: $e');
        }
      });

  /// 这条远端进度是否被本地墓碑挡掉（`deletedAt` 之后才允许复活）
  Future<bool> blockedByTombstone({
    required String siteKey,
    required String vodId,
    required int updatedAt,
  }) async {
    final list = await _tombstones();
    for (final t in list) {
      if ((t['siteKey'] ?? '') != siteKey) continue;
      final scope = (t['scope'] ?? 'item').toString();
      if (scope == 'all') return true;
      if (scope == 'site') return ((t['deletedAt'] as num?)?.toInt() ?? 0) > updatedAt;
      if ((t['vodId'] ?? '') == vodId) {
        return ((t['deletedAt'] as num?)?.toInt() ?? 0) > updatedAt;
      }
    }
    return false;
  }

  // ============================================================
  // 游标
  // ============================================================

  Future<int?> cursorOf(String url) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCursors) ?? '{}';
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final v = m['$url|$_currentConfigKey'];
      return (v as num?)?.toInt();
    } catch (_) {
      return null;
    }
  }

  /// 写游标（同样要串行化，见 [_serialized]）
  Future<void> _saveCursor(String url, int nextSince) => _serialized(() async {
        try {
          final prefs = await SharedPreferences.getInstance();
          final raw = prefs.getString(_kCursors) ?? '{}';
          final m = raw.isEmpty
              ? <String, dynamic>{}
              : Map<String, dynamic>.from(jsonDecode(raw) as Map);
          m['$url|$_currentConfigKey'] = nextSince;
          await prefs.setString(_kCursors, jsonEncode(m));
        } catch (e) {
          AppLog.instance.log('[PlaybackSync] 写游标失败: $e');
        }
      });

  // ============================================================
  // 拉取合并
  // ============================================================

  /// 拉一次并合并；返回 (新增/更新数, 删除数) 供 UI 提示。
  ///
  /// 规则（照文档）：
  ///   · 带 `configKey` 的项若映射不到本机接口 → **跳过**
  ///   · 删除项可能在 `items/changes` 里（`action:delete` / `deleted:true` /
  ///     `event:playback.deleted`）
  ///   · **`deletedAt` 之前的旧进度跳过**（墓碑阻挡）
  ///   · **响应条数 > maxItems 时不推进游标**
  Future<(int, int)> pull(PlaybackRemoteSource source) async {
    final store = WebhtvPlaybackSyncStore.instance;
    if (!store.loaded) await store.load();
    if (!store.enabled) return (0, 0);

    final since = await cursorOf(source.url);
    final dio = _dio();
    var merged = 0;
    var deleted = 0;
    try {
      final resp = await dio.get<dynamic>(
        source.url,
        options: Options(headers: {
          if (source.token.isNotEmpty) 'X-WebHTV-Token': source.token,
          'X-WebHTV-Config-Key': _currentConfigKey,
          'X-WebHTV-Config-Name': _currentConfigName,
          if (since != null) 'X-WebHTV-Since': since.toString(),
          'X-WebHTV-Limit': source.maxItems.toString(),
        }),
      );
      final body = resp.data;
      final Map<String, dynamic> m = body is Map
          ? Map<String, dynamic>.from(body)
          : (jsonDecode(body.toString()) as Map<String, dynamic>);

      final items = (m['items'] ?? m['changes']) is List
          ? List<Map<String, dynamic>>.from(
              (m['items'] ?? m['changes'] as List)
                  .whereType<Map>()
                  .map((e) => Map<String, dynamic>.from(e)))
          : <Map<String, dynamic>>[];
      final dels = <Map<String, dynamic>>[];
      for (final key in const [
        'deleted',
        'deletions',
        'tombstones',
        'removed',
        'deletedItems'
      ]) {
        final l = m[key];
        if (l is List) {
          dels.addAll(l
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e)));
        }
      }
      // 混在 items 里的删除项
      final realItems = <Map<String, dynamic>>[];
      for (final it in items) {
        final isDel = it['action'] == 'delete' ||
            it['deleted'] == true ||
            it['event'] == 'playback.deleted';
        if (isDel) {
          dels.add(it);
        } else {
          realItems.add(it);
        }
      }

      // ① 删除
      for (final d in dels) {
        deleted += await _applyDeletion(d, source);
      }
      // ② 合并
      for (final it in realItems) {
        if (await _applyItem(it, source)) merged++;
      }

      // ③ 游标：超过 maxItems 不推进
      final next = (m['nextSince'] as num?)?.toInt();
      final tooMany = realItems.length + dels.length > source.maxItems;
      if (next != null && !tooMany) {
        await _saveCursor(source.url, next);
      } else if (tooMany) {
        AppLog.instance.log('[PlaybackSync] 本次条数超过 maxItems，不推进游标');
      }
    } catch (e) {
      AppLog.instance.log('[PlaybackSync] 拉取失败 ${source.url}: $e');
      rethrow;
    } finally {
      dio.close(force: true);
    }
    return (merged, deleted);
  }

  /// 应用一条删除（item / site / all 三档）
  Future<int> _applyDeletion(
      Map<String, dynamic> d, PlaybackRemoteSource source) async {
    final siteKey = (d['siteKey'] ?? '').toString();
    final vodId = (d['vodId'] ?? '').toString();
    final scope = (d['scope'] ?? 'item').toString();
    final deletedAt = (d['deletedAt'] as num?)?.toInt() ?? 0;
    await _addTombstone({
      'siteKey': siteKey,
      'vodId': vodId,
      'historyKey': (d['historyKey'] ?? '').toString(),
      'scope': scope,
      'deletedAt': deletedAt,
    });
    if (scope == 'all') {
      // ⚠️ 这里**绝不能**用 `CacheStore.clearHistory()` —— 它清的是整张
      //   `vod_records` 表：其它影视源的记录、以及从没上报过的本地记录
      //   会被**一起清空**（远端推来一条 scope=all 就等于把用户历史全删了，
      //   而且是自动同步触发的，用户毫无操作）。
      //   协议里 scope=all 的语义是「**这个源**做了全量删除」⇒ 只删它管的站点。
      //   源没配 siteKeys 时不知道该删哪些 ⇒ **只落墓碑挡住复活，不做破坏性删除**。
      final keys = source.siteKeys;
      if (keys.isEmpty) {
        AppLog.instance.log('[PlaybackSync] scope=all 但该源没配 siteKeys，仅落墓碑、不删本地记录');
        return 0;
      }
      final hits = CacheStore.instance.records
          .where((r) => keys.contains(r.sourceKey))
          .toList();
      for (final r in hits) {
        await CacheStore.instance.removeRecord(r.vodId, r.sourceKey);
      }
      return hits.length;
    }
    if (scope == 'site') {
      final hits = CacheStore.instance.records
          .where((r) => r.sourceKey == siteKey)
          .toList();
      for (final r in hits) {
        await CacheStore.instance.removeRecord(r.vodId, r.sourceKey);
      }
      return hits.length;
    }
    if (siteKey.isEmpty || vodId.isEmpty) return 0;
    await CacheStore.instance.removeRecord(vodId, siteKey);
    return 1;
  }

  /// 合并一条远端进度到本机历史
  Future<bool> _applyItem(
      Map<String, dynamic> it, PlaybackRemoteSource source) async {
    final siteKey = (it['siteKey'] ?? '').toString();
    final vodId = (it['vodId'] ?? '').toString();
    if (siteKey.isEmpty || vodId.isEmpty) return false;
    // 站点白名单
    if (source.siteKeys.isNotEmpty && !source.siteKeys.contains(siteKey)) {
      return false;
    }
    final updatedAt = (it['updatedAt'] as num?)?.toInt() ?? 0;
    // 墓碑阻挡：删除之后才允许复活
    if (await blockedByTombstone(
        siteKey: siteKey, vodId: vodId, updatedAt: updatedAt)) {
      return false;
    }
    final positionMs = (it['positionMs'] as num?)?.toInt() ?? 0;
    final flag = (it['flag'] ?? '').toString();
    final episodeName = (it['episodeName'] ?? '').toString();
    await CacheStore.instance.addRecord(
      Video(
        id: vodId,
        name: (it['vodName'] ?? '').toString(),
        pic: (it['vodPic'] ?? '').toString(),
        sourceKey: siteKey,
      ),
      episodeName,
      playbackState: VodPlaybackState(
        flag: flag,
        episodeIndex: 0,
        progressSeconds: positionMs / 1000.0,
      ),
    );
    return true;
  }

  // ============================================================
  // 启动 / 周期自动拉取
  // ============================================================

  Timer? _autoTimer;

  /// 每个源上次发起拉取的时间（毫秒），用于 `intervalMinutes` 节流
  final Map<String, int> _lastPullAt = {};

  /// 正在拉取的源 URL，避免同一源并发重入
  final Set<String> _pulling = {};

  /// 启动自动同步（由 `main.dart` 一次性调用）。
  ///
  /// - 总开关关闭 → 什么都不做；
  /// - 勾了 `syncOnStartup` 的源：立即各拉一次（**不 await**，不阻塞启动）；
  /// - 有 `intervalMinutes > 0` 的源：起一个**每分钟**的检查定时器。
  ///
  /// **幂等**：重复调用不会重复起定时器。
  Future<void> beginAutoSync() async {
    final store = WebhtvPlaybackSyncStore.instance;
    if (!store.loaded) await store.load();
    if (!store.enabled) return;
    for (final s in store.remotes.where((e) => e.syncOnStartup)) {
      unawaited(_pullGuarded(s));
    }
    _autoTimer ??= Timer.periodic(const Duration(minutes: 1), (_) => _tickAuto());
  }

  /// 设置页改动（总开关 / 源列表）后调用：重建调度。
  Future<void> restartAutoSync() async {
    _autoTimer?.cancel();
    _autoTimer = null;
    _lastPullAt.clear();
    await beginAutoSync();
  }

  void stopAutoSync() {
    _autoTimer?.cancel();
    _autoTimer = null;
  }

  void _tickAuto() {
    final store = WebhtvPlaybackSyncStore.instance;
    if (!store.enabled) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final s in store.remotes) {
      if (s.intervalMinutes <= 0) continue;
      final last = _lastPullAt[s.url] ?? 0;
      if (now - last >= s.intervalMinutes * 60000) {
        unawaited(_pullGuarded(s));
      }
    }
  }

  /// 带并发保护 + 时间戳记账的拉取（失败已由 [pull] 内部记日志）。
  Future<void> _pullGuarded(PlaybackRemoteSource s) async {
    if (_pulling.contains(s.url)) return;
    _pulling.add(s.url);
    _lastPullAt[s.url] = DateTime.now().millisecondsSinceEpoch;
    try {
      await pull(s);
    } catch (_) {
      // pull 内部已记日志，这里吞掉避免未捕获异常
    } finally {
      _pulling.remove(s.url);
    }
  }
}
