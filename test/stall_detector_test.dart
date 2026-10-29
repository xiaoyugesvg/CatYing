import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/widgets/stall_detector.dart';

/// 「加载卡死」判定测试。
///
/// ── 为什么值得专门测（复核发现的严重缺口）────────────────────────
/// 播放器的**媒体加载完全没有超时**：`_player.open(...)` 一处超时都没设。
/// 采集源的 CDN 直链**挂起**时，播放内核**不会**抛 error 事件 ——
/// 它只是永远不 ready ⇒ 转圈无限转，用户分不清"加载中"还是"坏了" ✗
/// 而且详情页的重试按钮挂在 `onError` 上 → 挂起时**连重试都出不来** ✗
///
/// 这里的判定就是那个缺口的第一道闸。
///
/// ⚠️ 判定逻辑**必须抽成纯类**才能这样测 —— 它在
///    `_VideoPlayerWidgetState` 里时，那个 State 依赖 media_kit 原生库
///    （`AppPlayer` 是 `late final`），测试里根本构造不出来。
void main() {
  /// 固定一个基准时刻，后面都用 now = base + N 秒，保证可重复
  final base = DateTime(2026, 1, 1, 12, 0, 0);
  DateTime at(int sec) => base.add(Duration(seconds: sec));

  test('🔴 缓冲中且位置长时间不前进 → 到阈值判为卡死', () {
    final d = StallDetector(thresholdSeconds: 15, now: base);

    // 前 14 秒：还没到阈值，不该报
    for (var s = 0; s < 15; s++) {
      final just = d.tick(buffering: true, playing: true, now: at(s));
      expect(just, isFalse, reason: '第 $s 秒还不该判卡死（阈值 15s）');
      expect(d.stalled, isFalse);
    }
    // 第 15 秒：到阈值 → 第一次返回 true
    expect(d.tick(buffering: true, playing: true, now: at(15)), isTrue,
        reason: '缓冲中 15 秒没有前进，必须判为卡死（这正是"转圈无限转"的场景）');
    expect(d.stalled, isTrue);

    // 继续 tick 不该反复报（调用方只该弹一次提示）
    expect(d.tick(buffering: true, playing: true, now: at(20)), isFalse,
        reason: '已经判定过了，不该每秒钟都返回 true（否则会反复弹提示）');
    expect(d.stalled, isTrue);
  });

  test('✅ 位置有前进 → 不判卡死（哪怕缓冲一直为 true）', () {
    final d = StallDetector(thresholdSeconds: 15, now: base);
    // 每秒都在前进（整秒变化）
    for (var s = 0; s <= 30; s++) {
      d.markProgress(s, now: at(s));
      final just = d.tick(buffering: true, playing: true, now: at(s));
      expect(just, isFalse,
          reason: '位置每分钟都在走，绝不能判卡死（否则好片子会被误报）');
    }
    expect(d.stalled, isFalse);
  });

  test('🔴 暂停中不算卡死（用户自己停的，位置本来就不动）', () {
    final d = StallDetector(thresholdSeconds: 5, now: base);
    // 停 60 秒，但 playing=false
    for (var s = 0; s <= 60; s++) {
      final just = d.tick(buffering: true, playing: false, now: at(s));
      expect(just, isFalse, reason: '暂停中位置不动是正常的，不能判卡死');
    }
    expect(d.stalled, isFalse,
        reason: '若这里为 true，用户一暂停就会被弹"加载超时"');
  });

  test('缓冲结束（buffering=false）→ 解除已有判定', () {
    final d = StallDetector(thresholdSeconds: 5, now: base);
    expect(d.tick(buffering: true, playing: true, now: at(5)), isTrue);
    expect(d.stalled, isTrue);

    // 缓冲结束了 → 自动解除
    d.tick(buffering: false, playing: true, now: at(6));
    expect(d.stalled, isFalse, reason: '缓冲结束就不该再显示"加载超时"');
  });

  test('位置恢复前进 → 解除卡死判定', () {
    final d = StallDetector(thresholdSeconds: 5, now: base);
    expect(d.tick(buffering: true, playing: true, now: at(5)), isTrue);
    expect(d.stalled, isTrue);

    // 卡了 10 秒后位置突然前进（网络恢复 / 用户 seek 唤醒）
    d.markProgress(3, now: at(10));
    expect(d.stalled, isFalse,
        reason: '位置一旦前进就该解除卡死（否则提示会一直挂着）');
  });

  test('reset() 用于换集/重试：清掉上一集的判定与计时', () {
    final d = StallDetector(thresholdSeconds: 5, now: base);
    expect(d.tick(buffering: true, playing: true, now: at(5)), isTrue);

    // 换集
    d.reset(now: at(6));
    expect(d.stalled, isFalse, reason: '换集后不能带着上一集的"卡死"状态');

    // 新一集刚开始 4 秒 → 还不该报（说明计时确实被复位了）
    expect(d.tick(buffering: true, playing: true, now: at(10)), isFalse,
        reason: 'reset 应把计时归零；否则新一集一开播就立刻误报');
    // 再过 1 秒到 5 秒阈值 → 才报
    expect(d.tick(buffering: true, playing: true, now: at(11)), isTrue);
  });

  test('markProgress 按整秒去重：同一秒重复调用不刷新计时', () {
    final d = StallDetector(thresholdSeconds: 5, now: base);
    // 同一秒（3）内调 10 次，时间仍从 base 起算
    for (var i = 0; i < 10; i++) {
      d.markProgress(3, now: at(0));
    }
    // 到第 5 秒仍未"前进"（因为秒数一直没变）→ 应判卡死
    expect(d.tick(buffering: true, playing: true, now: at(5)), isTrue,
        reason: '同一秒内的重复回调不该被当成"有前进"，否则 position 每 20ms '
            '一次的频率会让计时永远被刷新、卡死永远检测不到');
  });

  test('idleFor 如实反映"已经多久没前进"', () {
    final d = StallDetector(thresholdSeconds: 15, now: base);
    d.markProgress(0, now: at(0));
    expect(d.idleFor(at(7)).inSeconds, 7);
    d.markProgress(1, now: at(7));
    expect(d.idleFor(at(7)).inSeconds, 0);
  });

  /// 用户 2026-10-29：「TG 视频加载出来画面了，但就是超时播放不了」
  ///
  /// 根因之一：TG 源每个分片都要回一趟 Telegram 机房，首块 + 缓冲的延迟
  /// 天然比 CDN 直链高，**15s 的通用阈值会把"慢"误判成"坏"** ——
  /// 画面已经出来（首帧解码成功），位置还没开始走，就被判「加载超时」
  /// 盖了一层提示，看着就像"播不了"。
  ///
  /// 所以 `VideoPlayerWidget.stallSeconds` 开放出来，TG 传 45。
  /// 这条测试把两种阈值的**行为差异**钉住，防止以后又被改回一刀切。
  test('TG 慢源：15s 会误报，45s 阈值下同样的等待不算卡死', () {
    // 通用阈值：第 15 秒就报（对 TG 就是误报）
    final fast = StallDetector(thresholdSeconds: 15, now: base);
    expect(fast.tick(buffering: true, playing: true, now: at(15)), isTrue,
        reason: '15s 阈值在 TG 上就是误报来源');

    // TG 阈值：同样的 15 秒、甚至 44 秒都不该报
    final tg = StallDetector(thresholdSeconds: 45, now: base);
    for (final s in [15, 30, 44]) {
      expect(tg.tick(buffering: true, playing: true, now: at(s)), isFalse,
          reason: 'TG 源第 $s 秒还在正常缓冲，不该弹「加载超时」');
    }
    // 真的超过 45s 才报（该报的时候还是要报，别把真故障也放过）
    expect(tg.tick(buffering: true, playing: true, now: at(45)), isTrue,
        reason: '45s 都没动静就是真卡了，必须提示可重试');
  });

  test('TG 阈值下位置一旦前进，立刻解除卡死判定', () {
    final tg = StallDetector(thresholdSeconds: 45, now: base);
    expect(tg.tick(buffering: true, playing: true, now: at(45)), isTrue);
    tg.markProgress(3, now: at(46));
    expect(tg.stalled, isFalse, reason: '开始播了就不该再挂着「加载超时」');
  });
}
