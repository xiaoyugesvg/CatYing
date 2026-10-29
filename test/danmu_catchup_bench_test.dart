// 弹幕「补播」帧率基准测试（用户 2026-10-10：验证补播后的帧率）。
//
// 测三组数据：
//   1. 基线：空弹幕列表的首帧耗时
//   2. 补播尖峰：密集历史弹幕（过去 12s 窗口 600 条 + 未来 5000 条）就绪后
//      首帧（含补播）耗时 —— 应 << 16.6ms 帧预算
//   3. 稳态：补播完成后连续 120 帧（约 2s 播放）每帧平均耗时
//
// ⚠️ 数字是 debug 模式 + CPU 渲染的上界，真机 release 只会更快。
//    关注点：补播那帧是否超出帧预算、稳态每帧是否平滑。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/widgets/danmaku.dart';

Widget _wrap(List<DanmuItem> danmus, double Function() posOf) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 800,
          height: 360,
          child: DanmuLayer(
            danmus: danmus,
            positionOf: () =>
                Duration(milliseconds: (posOf() * 1000).round()),
            speed: 150,
            trackCount: 8,
          ),
        ),
      ),
    ),
  );
}

/// 构造密集弹幕列表：过去 12s 窗口内每 20ms 一条（600 条滚动）+
/// 未来 5000 条，模拟高密度源的最坏情况。
List<DanmuItem> _denseDanmus(double now) {
  final out = <DanmuItem>[];
  for (var i = 0; i < 600; i++) {
    out.add(DanmuItem(now - 12.0 + i * 0.02, '滚动弹幕内容测试 $i',
        const Color(0xFFFFFFFF), 1));
  }
  // 穿插一些顶部/底部固定弹幕
  for (var i = 0; i < 40; i++) {
    out.add(DanmuItem(now - 3.5 + i * 0.08, '顶部固定 $i',
        const Color(0xFFFF5555), 4));
  }
  for (var i = 0; i < 5000; i++) {
    out.add(DanmuItem(now + 0.5 + i * 0.4, '未来弹幕 $i',
        const Color(0xFFFFFFFF), 1));
  }
  return out;
}

void main() {
  testWidgets('baseline: empty list first frame', (tester) async {
    var pos = 0.0;
    final sw = Stopwatch()..start();
    await tester.pumpWidget(_wrap(const [], () => pos));
    await tester.pump();
    sw.stop();
    // ignore: avoid_print
    print('[BENCH] baseline first frame: ${sw.elapsedMicroseconds / 1000} ms');
  });

  testWidgets('catchup: dense past window first frame + steady 120 frames',
      (tester) async {
    var pos = 20.0; // 列表就绪时视频已播到 20s → 触发补播窗口
    final danmus = _denseDanmus(pos);

    final swFirst = Stopwatch()..start();
    await tester.pumpWidget(_wrap(danmus, () => pos));
    await tester.pump(); // 首帧 + postFrame 补播
    swFirst.stop();
    // ignore: avoid_print
    print('[BENCH] catchup first frame: '
        '${swFirst.elapsedMicroseconds / 1000} ms');

    // 稳态：每帧推进 16.6ms 播放位置，连续 120 帧
    final swSteady = Stopwatch()..start();
    var worst = 0;
    for (var f = 0; f < 120; f++) {
      pos += 0.0166;
      final swFrame = Stopwatch()..start();
      await tester.pump(const Duration(milliseconds: 16));
      swFrame.stop();
      if (swFrame.elapsedMicroseconds > worst) {
        worst = swFrame.elapsedMicroseconds;
      }
    }
    swSteady.stop();
    // ignore: avoid_print
    print('[BENCH] steady 120 frames total: '
        '${swSteady.elapsedMicroseconds / 1000} ms, '
        'avg ${swSteady.elapsedMicroseconds / 1000 / 120} ms, '
        'worst ${worst / 1000} ms');
  });
}
