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
}
