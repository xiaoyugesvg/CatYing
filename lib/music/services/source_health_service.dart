import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../models/third_party_source.dart';
import 'semaphore.dart';
import 'unblock_service.dart';

/// 单条音源体检结果。
///
/// 「测活」用的是**真实解析链路**（[UnblockService.testOne]）：能拿到播放
/// 地址才算可用。只 ping 域名是查不出"能搜不能播"的。
class SourceHealth {
  final bool ok;

  /// 耗时（毫秒）—— 用户可以据此给源排序
  final int ms;

  /// 失败原因（成功时为空）
  final String message;

  final DateTime at;

  const SourceHealth({
    required this.ok,
    required this.ms,
    this.message = '',
    required this.at,
  });

  Map<String, dynamic> toJson() => {
        'ok': ok,
        'ms': ms,
        'message': message,
        'at': at.millisecondsSinceEpoch,
      };

  factory SourceHealth.fromJson(Map<String, dynamic> j) => SourceHealth(
        ok: j['ok'] == true,
        ms: (j['ms'] as num?)?.toInt() ?? 0,
        message: (j['message'] ?? '').toString(),
        at: DateTime.fromMillisecondsSinceEpoch(
            (j['at'] as num?)?.toInt() ?? 0),
      );
}

/// 音源可用性体检 —— 批量测活、记录结果、一键禁用失效源。
///
/// ── 为什么要单独一层 ──────────────────────────────────────────
/// 结果要**跨页面/跨启动**保留：用户体检完关掉页面，列表里的红色标记不能
/// 消失，否则下次又要重跑一遍（几十个源 × 每个几秒）。
///
/// ── 判定口径 ──────────────────────────────────────────────────
/// 用一个固定的探针曲目走 [UnblockService.testOne]。固定输入才能横向比较
/// 不同音源 —— 否则"这个源失败"到底是源坏了还是这首歌它没有，说不清。
/// 单源超时 [_timeout]：脚本源可能死循环，不设上限会把整轮体检拖死。
class SourceHealthService {
  SourceHealthService._();
  static final SourceHealthService instance = SourceHealthService._();

  static const _key = 'music.sourceHealth.v1';
  static const _concurrency = 3;
  static const _timeout = Duration(seconds: 15);

  /// 探针曲目（与音源管理页的「测试」按钮保持一致）
  static const Song probeSong = Song(
    id: 347230,
    name: '海阔天空',
    artists: 'Beyond',
    album: '乐与怒',
  );

  final Map<String, SourceHealth> _map = {};
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  bool _loaded = false;

  /// 是否正在批量体检
  bool checking = false;
  int done = 0;
  int total = 0;

  Map<String, SourceHealth> get results => Map.unmodifiable(_map);

  SourceHealth? of(String id) => _map[id];

  bool isFailed(String id) => _map[id]?.ok == false;

  bool get hasResults => _map.isNotEmpty;

  /// 首次进入管理页时从磁盘恢复
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final obj = jsonDecode(raw);
      if (obj is! Map) return;
      obj.forEach((k, v) {
        if (v is Map) {
          _map[k.toString()] = SourceHealth.fromJson(v.cast<String, dynamic>());
        }
      });
      revision.value++;
    } catch (e) {
      debugPrint('[SourceHealth] 读取失败: $e');
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final obj = <String, dynamic>{};
      _map.forEach((k, v) => obj[k] = v.toJson());
      await prefs.setString(_key, jsonEncode(obj));
    } catch (e) {
      debugPrint('[SourceHealth] 保存失败: $e');
    }
  }

  /// 记录一次结果（单源「测试」按钮也走这里，列表标记立刻更新）
  void record(String id,
      {required bool ok, required int ms, String message = ''}) {
    _map[id] = SourceHealth(
      ok: ok,
      ms: ms,
      message: message,
      at: DateTime.now(),
    );
    revision.value++;
    _persist();
  }

  /// 体检单个源，结果自动落库
  Future<SourceHealth> checkOne(ThirdPartySource s,
      {Song? probe}) async {
    final song = probe ?? probeSong;
    final sw = Stopwatch()..start();
    SourceResolveResult r;
    try {
      r = await UnblockService.instance.testOne(s, song).timeout(_timeout);
    } on TimeoutException {
      r = SourceResolveResult(
          ok: false, error: '超时（${_timeout.inSeconds} 秒无响应）');
    } catch (e) {
      r = SourceResolveResult(ok: false, error: '$e');
    }
    sw.stop();
    final health = SourceHealth(
      ok: r.ok,
      ms: sw.elapsedMilliseconds,
      message: r.ok ? '' : (r.error.isEmpty ? '未返回播放地址' : r.error),
      at: DateTime.now(),
    );
    _map[s.id] = health;
    revision.value++;
    return health;
  }

  /// 批量体检；返回可用数量。
  ///
  /// [onProgress] 每完成一个回调一次（UI 画进度条用）。
  Future<int> checkAll(
    List<ThirdPartySource> sources, {
    Song? probe,
    void Function(int done, int total)? onProgress,
  }) async {
    if (checking || sources.isEmpty) return 0;
    checking = true;
    done = 0;
    total = sources.length;
    revision.value++;

    var okCount = 0;
    final sem = Semaphore(_concurrency);
    await Future.wait(sources.map((s) => sem.run(() async {
          final h = await checkOne(s, probe: probe);
          if (h.ok) okCount++;
          done++;
          onProgress?.call(done, total);
          revision.value++;
        })));

    await _persist();
    checking = false;
    revision.value++;
    return okCount;
  }

  /// 一键禁用所有「已启用但体检失败」的源；返回禁用数量。
  Future<int> disableFailed() async {
    final store = ThirdPartySourceStore.instance;
    var n = 0;
    for (final s in store.all) {
      if (s.enabled && isFailed(s.id)) {
        await store.setEnabled(s.id, false);
        n++;
      }
    }
    return n;
  }

  /// 清空体检结果（源全换了一批时用）
  Future<void> clear() async {
    _map.clear();
    revision.value++;
    await _persist();
  }
}
