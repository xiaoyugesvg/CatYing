import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import '../models/third_party_source.dart';
import '../../services/app_log.dart';

/// **音源记忆** —— 记住"哪首歌是靠哪个源播成功的"，下次直接用。
///
/// ── 为什么要有它（用户 2026 要求）──────────────────────────────
/// 用户的场景：VIP 歌靠第三方源播成功后，退出去、重新点这首歌 ——
/// 希望**直接用它上次成功的那个源**，而不是再"试全部源 + 弹窗选一遍"。
///
/// 原来的体验：
///   点歌 → 内置接口失败 → **并发试 N 个源（几秒）** → 弹窗让用户选
/// 现在（命中记忆时）：
///   点歌 → 内置失败 → **只试记住的那一个源** → 成功就直接播
///
/// ── 🔴 为什么不能只存 URL（只存"记住"是不够的）─────────────────
/// 第三方源给的播放地址**几乎都是签名限时的**：
///   `https://car-er.kuwo.cn/<签名>/6ac3c102/resource/...`
/// 那个 `<签名>` 和路径里的时间戳**会过期**，过期后取回来是 403/404。
/// 所以**只能记"源"，不能记"URL"** —— 每次重新向那个源要一个新地址。
///
/// 也正因为地址会失效，命中记忆时**必须验证**（`UnblockService.testOne`），
/// 失败就**静默回退**到"试全部源"，不能因为记忆而播不了 ✗。
///
/// ── 持久化格式 ────────────────────────────────────────────────
/// `SharedPreferences` 里存一个 `Map<String, String>`：
///   键 = `Song.identityKey`（`平台-数字id`，跨平台不撞车）
///   值 = `ThirdPartySource.id`
///
/// 用 `identityKey` 而不是歌名：同名歌（原版/Live/翻唱）ID 不同，
/// 按歌名记会把它们混成一个，导致"记住的源对不上这首歌"。
class SourceMemory {
  SourceMemory._();
  static final SourceMemory instance = SourceMemory._();

  static const _kMap = 'music.sourceMemory.v1';

  /// **最多记多少首**。
  ///
  /// 不设上限的话这个 map 会随听歌量无限增长（一天几百首），
  /// 而 `SharedPreferences` 每次读写都是**整份序列化** ——
  /// 攒到几千条时每次点歌都要序列化一大坨，越用越卡。
  ///
  /// 200 条足够覆盖"最近常听的那些"，超出就丢最早的。
  static const int _maxEntries = 200;

  /// 内存镜像（读的时候不用等 SharedPreferences）
  final Map<String, String> _map = {};

  /// 正在进行的初始化。
  ///
  /// ── 🔴 为什么是 `Future?` 而不是 `bool _inited` 闩锁（修"记不住"）──
  ///
  /// 原来写的是：
  /// ```dart
  /// bool _inited = false;
  /// Future<void> init() async {
  ///   if (_inited) return;          // ← 闩锁
  ///   final prefs = await SharedPreferences.getInstance();   // ← 这里让出事件循环
  ///   ...
  ///   _inited = true;               // ← 置位在 await **之后**
  /// }
  /// ```
  /// 问题：`init()` **一开始就不 await** 直接把 Future 交出去了 ——
  /// 但只有在**第一次**调用时才会走进去。真正的坑在下面这个交错：
  ///
  ///   1. 启动时 `SettingsStore.init()` 调 `SourceMemory.init()`（还没读完盘）
  ///   2. 用户立刻点了一首歌、第三方源成功 → `remember()` → 它内部
  ///      `await init()` → **又进一次 init()**，此时 `_inited` 还是 false！
  ///   3. 两次 `init()` 并发：先完成的那次读到的盘上数据**覆盖** `_map`，
  ///      把第 2 步刚 `remember` 进去的值**冲掉** ✗
  ///
  /// 表现正是用户反馈的「**用了第三方源，退出再点又播不了**」——
  /// 记忆写进去了，但被并发的那次 load 覆盖回旧状态。
  ///
  /// 现在用 `_initFuture`：所有调用者 `await` **同一个 Future**，
  /// 初始化只跑一次、且"跑完之前谁也别想读/写 `_map`"。
  /// 这与 `library_store.dart` / `download_service.dart` 的做法一致
  ///（那边注释记录了同一段教训，这里是漏改的第三处）。
  Future<void>? _initFuture;

  Future<void> init() => _initFuture ??= _doInit();

  Future<void> _doInit() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kMap) ?? const [];
      for (final line in raw) {
        // 用 `key\u0001value` 拼成一行存 —— 比存 JSON 省一次编解码，
        // 而且不会被引号/转义问题坑到。
        final i = line.indexOf('\u0001');
        if (i <= 0) continue;
        // ⚠️ `putIfAbsent`：万一在 init 完成前已经有并发 `remember` 写进来，
        //    保留内存里那份（更新），不要让盘上的旧值盖掉它。
        _map.putIfAbsent(line.substring(0, i), () => line.substring(i + 1));
      }
      count.value = _map.length;
      AppLog.instance.log('[Music] 音源记忆载入 ${_map.length} 条');
    } catch (e) {
      // 失败也**不要把 Future 置空**：否则每次点歌都重试一遍
      AppLog.instance.log('[Music] 音源记忆载入失败: $e');
    }
  }

  /// 这首歌上次是用哪个源播成功的？没有就返回 null。
  String? sourceIdFor(Song song) => _map[song.identityKey];

  /// 记住"这首歌用这个源成功了"。
  ///
  /// ⚠️ 只在**播放真的成功**之后调用（见 `player_manager`）——
  /// 记住一个失败过的源会让下次点歌白等一次。
  Future<void> remember(Song song, String sourceId) async {
    if (sourceId.isEmpty) return;
    await init();
    final key = song.identityKey;
    // 值没变就不写盘（省一次整份序列化）
    if (_map[key] == sourceId) return;
    _map[key] = sourceId;
    // 超上限 → 丢最早的（Dart 的 Map 保持插入顺序，所以 first key 就是最早的）
    while (_map.length > _maxEntries) {
      _map.remove(_map.keys.first);
    }
    count.value = _map.length;
    await _save();
  }

  /// 忘掉这首歌的记忆（解析失败时调用，避免下次又白试一次）。
  Future<void> forget(Song song) async {
    await init();
    if (_map.remove(song.identityKey) != null) {
      count.value = _map.length;
      await _save();
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _kMap,
        [for (final e in _map.entries) '${e.key}\u0001${e.value}'],
      );
    } catch (e) {
      AppLog.instance.log('[Music] 音源记忆保存失败: $e');
    }
  }

  /// 已记住多少首（**可监听**，设置页直接绑它）。
  ///
  /// 用 `ValueNotifier` 而不是 `int get count`：设置页是
  /// `StatelessWidget`（没有 `setState`），清空后要让那一行自己刷新。
  final ValueNotifier<int> count = ValueNotifier<int>(0);

  /// **清空全部记忆**（设置页的入口）。
  ///
  /// 为什么需要给用户这个按钮：记忆是"自动学"的，用户看不见它记了什么。
  /// 如果某次记错了（比如他当时手滑选了一个音质很差的源），
  /// 之后每次点这首都会自动用那个源 —— **没有出口就永远改不掉** ✗。
  Future<void> clear() async {
    await init();
    _map.clear();
    count.value = 0;
    await _save();
    AppLog.instance.log('[Music] 音源记忆已清空');
  }

  /// 把记住的源 id 解析成**实际还启用的**音源对象。
  ///
  /// 返回 null 的两种情况（都要静默回退到"试全部源"）：
  ///   · 那个源被用户**删了**
  ///   · 那个源被用户**禁用了**
  /// 否则会拿一个不存在的源去解析，必然失败。
  ThirdPartySource? resolveSource(Song song) {
    final id = sourceIdFor(song);
    if (id == null) return null;
    for (final s in ThirdPartySourceStore.instance.enabled) {
      if (s.id == id) return s;
    }
    return null;
  }
}
