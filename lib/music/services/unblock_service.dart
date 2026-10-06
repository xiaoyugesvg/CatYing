import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../models/third_party_source.dart';
import '../../services/app_log.dart';
import 'music_api.dart';
import 'semaphore.dart';
import 'source_memory.dart';

/// 音源解析结果
class SourceResolveResult {
  final bool ok;
  final String url;
  final String error;

  /// 'keyword' = 模板法；'script' = 脚本法
  final String kind;

  /// 命中它的那个音源（用于提示"由 XX 音源提供"）
  final ThirdPartySource? source;

  /// 播放该地址**必须带的请求头**（MusicFree 插件/部分 LX 源会返回）。
  /// 🔴 不透传到播放器的话，要求 headers 的源会"地址拿到了但播不了"。
  final Map<String, String> headers;

  const SourceResolveResult({
    required this.ok,
    this.url = '',
    this.error = '',
    this.kind = '',
    this.source,
    this.headers = const {},
  });
}

/// 第三方音源解析服务 —— 对应 Beans 的 `UnblockService.swift`。
///
/// ── 职责边界（重要）───────────────────────────────────────────
/// Dart 侧负责：
///   · 从 [ThirdPartySourceStore] 取**已启用**的音源
///   · 逐个/并发试，记录每个的失败原因
///   · 决定"内置接口失败后要不要回退到音源"
/// Node 侧负责**纯解析**（模板填充 / 脚本沙箱执行）。
///
/// 这样音源列表的**唯一事实来源是 Dart**，Node 不囤一份，
/// 不会出现两边不一致的问题。
///
/// ── 两种用法（区别很重要）────────────────────────────────────
///   · [resolve]    —— 逐个试，**命中第一个就返回**（旧的自动模式）
///   · [resolveAll] —— 试**全部**，返回**所有成功的结果**，
///                    交给用户选（新交互：弹窗让用户决定用哪个）
///
/// 用户 2026 的决定：**用 [resolveAll] + 弹窗**。理由是自己选比程序猜更可靠 ——
/// 同一个源对不同歌的可用性差别很大，程序挑的第一个未必是用户想要的。
class UnblockService {
  UnblockService._();
  static final UnblockService instance = UnblockService._();

  /// 单个音源的解析在 Node 侧也有超时，这里只做整体上限保护
  static const _maxTries = 8;

  /// [resolveAll] 的上限（试太多会明显变慢）
  static const _maxTriesAll = 12;

  /// [resolveAll] 的并发数。
  ///
  /// ⚠️ 必须限流：一次并发 12 个脚本请求会
  ///   · 让 Node 侧同时跑 12 个 vm 沙箱（内存/CPU 尖峰）
  ///   · 被源站当成攻击（风控）
  /// 4 个是"够快又不激进"的平衡点。
  static const _concurrency = 4;

  /// 跨调用的并发闸门（见 `resolveAll` 里的说明）。
  ///
  /// 抽成 `Semaphore`（`services/semaphore.dart`）是为了**能单测** ——
  /// 并发正确性靠读代码不可靠（有 `test/semaphore_test.dart` 钉住）。
  final _gate = Semaphore(_concurrency);

  /// 最近一次解析的逐条失败原因（给"为什么都失败了"提供依据）。
  ///
  /// ── 🔴 每条都**带着它属于哪首歌**（修"失败原因串歌"）────────────
  ///
  /// 原来是一个纯 `List<String>`，而 `resolve` / `resolveAll` 都会先
  /// `lastAttempts.clear()` 再往里 add —— 于是**两次解析重叠时会互相污染**：
  ///
  ///   · 快速连点 A → B：B 的 `clear()` 抹掉 A 的记录（A 的失败原因丢了）
  ///   · A 的请求晚回来：把 A 的失败原因 add 进**已经是 B 的**那个列表
  ///   · 然后 `player_manager` 调 `describeFailure()` 展示 →
  ///     **用户看到的是上一首歌的失败原因** ✗
  ///    （`player_manager._failedSummary` 也是直接数 `lastAttempts.length`，
  ///      同样会把别的歌的条数算进来）
  ///
  /// 现在每条记录带上 `Song.identityKey`，[describeFailure] 只返回**本首歌**的；
  /// 别的歌的记录留着不影响正确性（下次 `clear()` 会清）。
  final attempts = <({String songKey, String text})>[];

  /// 兼容旧用法：只取文本（顺序不变）
  List<String> get lastAttempts =>
      attempts.map((a) => a.text).toList(growable: false);

  /// 记一条失败原因，并绑定到**当前这首歌**
  void _record(Song song, String text) =>
      attempts.add((songKey: song.identityKey, text: text));

  /// 把**本首歌**的失败原因拼成人能看的说明。
  ///
  /// ⚠️ 必须传 [song]：不传就会把别的歌的失败原因也带出来（见 [attempts] 注释）。
  String describeFailureFor(Song song) {
    final mine = attempts
        .where((a) => a.songKey == song.identityKey)
        .map((a) => a.text)
        .toList();
    return _format(mine);
  }

  /// 本首歌有几个源试过但失败了（供 `player_manager._failedSummary` 用）。
  int failedCountFor(Song song) =>
      attempts.where((a) => a.songKey == song.identityKey).length;

  /// 用已启用的第三方音源解析播放地址。
  ///
  /// [onProgress] 用于 UI 显示"正在试第 N 个音源"，因为逐个试可能要几秒，
  /// 不反馈用户会以为卡住了。
  Future<SourceResolveResult> resolve(
    Song song, {
    void Function(int index, int total, String sourceName)? onProgress,
  }) async {
    attempts.clear();

    // ── 把**记住的那个源**排到最前（用户 2026 要求）──────────────
    //
    // `player_manager` 在没命中记忆时才会走到这里（它先单独试记住的源）。
    // 但这里把记住的源排第一仍有意义：
    //   · 弹窗列表里它就在第一行，用户一眼看到"上次就是这个"
    //   · 并发试时它先回来，弹窗更早出现
    //
    // ⚠️ 只是**排序**，不删其它源 —— 记忆失效时用户还能选别的
    //（那正是他重新走到这个弹窗的原因）。
    final all = ThirdPartySourceStore.instance.enabled;
    final memId = SourceMemory.instance.sourceIdFor(song);
    final sources = memId == null
        ? all
        : ([
            ...all.where((s) => s.id == memId),
            ...all.where((s) => s.id != memId),
          ]);
    if (sources.isEmpty) {
      return const SourceResolveResult(ok: false, error: '没有启用中的音源');
    }

    final list = sources.take(_maxTries).toList();
    for (var i = 0; i < list.length; i++) {
      final s = list[i];
      onProgress?.call(i + 1, list.length, s.name);
      try {
        final r = await MusicApi.instance.resolveBySource(s, song);
        if (r.ok && r.url.isNotEmpty) {
          return SourceResolveResult(
            ok: true,
            url: r.url,
            kind: r.kind,
            source: s,
            headers: r.headers, // ← 必须透传（见字段注释）
          );
        }
        // 记下每个源的失败原因 —— 全失败时一起展示，
        // 用户才知道是哪个源坏了、坏在哪
        _record(song,
            '${s.name}：${r.message.isEmpty ? "未返回地址" : r.message}');
      } catch (e) {
        _record(song, '${s.name}：$e');
      }
    }

    return SourceResolveResult(
      ok: false,
      error: failedCountFor(song) == 0 ? '所有音源都没解析出播放地址' : '所有音源都失败了',
    );
  }

  /// **试全部已启用的音源，返回所有成功的结果**（不提前返回）。
  ///
  /// ── 与 [resolve] 的区别（这是用户 2026 要的交互）──────────────
  /// [resolve] 命中第一个就返回 —— **程序替用户选了**。
  /// 但实测同一个源对不同歌的可用性差别很大，程序挑的第一个未必是用户想要的
  ///（比如两个源都能播，但一个音质更好 / 另一个是不同版本）。
  ///
  /// 所以改成：**全都试，把成功的列出来，弹窗让用户决定用哪个。**
  ///
  /// ── 实现要点 ────────────────────────────────────────────────
  /// · **限流并发**（[_concurrency] = 4）：不限流会同时跑 12 个 vm 沙箱
  ///   并把源站当攻击（风控）
  /// · 结果顺序 = **源列表顺序**（用户导入的顺序，前面的他更信任）
  /// · 失败原因仍逐个记进 [lastAttempts]（全失败时展示）
  ///
  /// [onProgress] 报"已试 N/M"，供 UI 显示进度。
  Future<List<SourceResolveResult>> resolveAll(
    Song song, {
    void Function(int done, int total)? onProgress,
  }) async {
    attempts.clear();
    final sources = ThirdPartySourceStore.instance.enabled.take(_maxTriesAll).toList();
    if (sources.isEmpty) return const [];

    // ── 🔴 并发上限必须是**全局跨调用**的（修"连点两首歌 = 8 个沙箱"）──
    //
    // 原来每个 `resolve`/`resolveAll` **各自**开 `_concurrency`(4) 个 worker：
    // 用户快速连点两首歌时 → 两个调用同时在跑 → **最多 8 个 Node vm 沙箱**
    // 同时开，正好是这段注释声称"必须避免"的情况 ✗
    //（被 `epoch` 丢弃的那次调用也会把 4 个 slot 跑满，不会提前退出）
    //
    // 现在用一对 ACME 信号量把"同时进行的源请求总数"压到 `_concurrency`：
    // 后进来的调用会在 `_acquire()` 里排队，而不是直接再开 4 个。
    final slots = List<SourceResolveResult?>.filled(sources.length, null);
    var done = 0;
    var next = 0;

    /// 单个 worker：不断从 next 取下一个源，直到取完
    Future<void> worker() async {
      while (true) {
        final i = next;
        if (i >= sources.length) return;
        next++;
        final s = sources[i];
        await _gate.acquire();
        try {
          final r = await MusicApi.instance.resolveBySource(s, song);
          if (r.ok && r.url.isNotEmpty) {
            slots[i] = SourceResolveResult(
              ok: true,
              url: r.url,
              kind: r.kind,
              source: s,
              headers: r.headers,
            );
          } else {
            // ⚠️ 必须走 `_record`（带上"属于哪首歌"），
            //    直接用 `lastAttempts.add` 会丢歌曲标记
            _record(song,
                '${s.name}：${r.message.isEmpty ? "未返回地址" : r.message}');
          }
        } catch (e) {
          _record(song, '${s.name}：$e');
        } finally {
          _gate.release();
        }
        done++;
        onProgress?.call(done, sources.length);
      }
    }

    await Future.wait(
      List.generate(_concurrency.clamp(1, sources.length), (_) => worker()),
    );

    return slots.whereType<SourceResolveResult>().toList();
  }

  /// 只试某一个音源（音源管理页的"测试"按钮用）
  Future<SourceResolveResult> testOne(ThirdPartySource s, Song song) async {
    try {
      final r = await MusicApi.instance.resolveBySource(s, song);
      if (r.ok && r.url.isNotEmpty) {
        return SourceResolveResult(
          ok: true,
          url: r.url,
          kind: r.kind,
          source: s,
          headers: r.headers,
        );
      }
      return SourceResolveResult(
        ok: false,
        error: r.message.isEmpty ? '未返回播放地址' : r.message,
        kind: r.kind,
      );
    } catch (e) {
      return SourceResolveResult(ok: false, error: '$e');
    }
  }

  /// 汇总失败原因。
  ///
  /// ⚠️ 返回值会被塞进 toast 并**被截断**（用户实测只看到
  /// `内置接口没有免费音源；car_conv2: GD接口失败: Clie...`，看不到真正原因）。
  /// 所以这里**永远**把完整逐条明细写进 `AppLog`（日志页可查），
  /// 返回值仍保持简短，专供 toast 用。
  /// 把一批失败原因拼成人能看的说明。
  ///
  /// ⚠️ 完整原因**同时进日志** —— 气泡会把长文本截断，
  /// 而可排查的信息往往在后半段（用户反馈过"看不到完整的日志"）。
  String _format(List<String> list) {
    if (list.isEmpty) return '';
    final full = list.join('\n');
    debugPrint('[Unblock] 逐个失败原因:\n$full');
    AppLog.instance.log('[Unblock] 音源逐个失败原因:\n$full');
    if (list.length == 1) return list.first;
    return '试了 ${list.length} 个音源都没成功';
  }

  /// ⚠️ **已废弃**：不带歌曲参数 → 会把别的歌的失败原因一起返回
  ///（快速连点两首歌时"显示的是上一首的失败原因"）。
  /// 请改用 [describeFailureFor]。
  @Deprecated('用 describeFailureFor(song) —— 这个方法会串到别的歌上')
  String describeFailure() => _format(lastAttempts);
}
