import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/music/services/semaphore.dart';

/// 并发闸门的单测。
///
/// ── 为什么这个测试值得写 ────────────────────────────────────────
/// `UnblockService.resolveAll` 用 `Semaphore(4)` 把"同时在跑的 Node 源请求"
/// 压到 4 个。原来每个调用**各自**开 4 个 worker，
/// 快速连点两首歌就是 8 个沙箱（注释里声称必须避免的情况）。
///
/// 并发正确性靠读代码不可靠（"移交名额时先减再加会被插队"这类错一眼看不出来），
/// 所以用测试把不变量钉死：
///   · **同时在跑的数量永不超过 limit**
///   · 释放的名额一定**移交**给排队者（不能丢）
///   · body 抛异常也要释放（否则名额泄漏，后续全部卡死）
void main() {
  test('不超过 limit：超出部分排队', () async {
    final s = Semaphore(2);
    await s.acquire();
    await s.acquire();
    expect(s.running, 2);

    // 第三个请求必须排队（future 未完成）
    var thirdDone = false;
    final third = s.acquire().then((_) => thirdDone = true);
    await Future<void>.delayed(Duration.zero);
    expect(thirdDone, isFalse, reason: '第 3 个不该立刻拿到名额');
    expect(s.waiting, 1);
    expect(s.running, 2, reason: 'running 不能超过 limit');

    // 放一个 → 第三个应被唤醒
    s.release();
    await third;
    expect(thirdDone, isTrue);
    expect(s.running, 2, reason: '移交后总数仍应是 2（不是 1 或 3）');
    expect(s.waiting, 0);
  });

  test('释放的名额会移交，不会丢', () async {
    final s = Semaphore(1);
    await s.acquire();
    final order = <int>[];
    final f1 = s.acquire().then((_) => order.add(1));
    final f2 = s.acquire().then((_) => order.add(2));
    expect(s.waiting, 2);

    s.release();
    await f1;
    expect(order, [1], reason: '严格 FIFO：队首先拿到');
    s.release();
    await f2;
    expect(order, [1, 2]);
    expect(s.running, 1);
  });

  test('body 抛异常也必须释放名额（否则名额泄漏）', () async {
    final s = Semaphore(1);
    await expectLater(
      s.run<void>(() async => throw StateError('boom')),
      throwsA(isA<StateError>()),
    );
    expect(s.running, 0, reason: '抛异常后名额必须已释放，否则后续请求全部卡死');

    // 泄漏的话这里会永远挂住 —— 用超时兜住，失败时给明确信息
    await s.run<void>(() async {}).timeout(
          const Duration(seconds: 2),
          onTimeout: () => fail('名额泄漏了：run 之后再 acquire 拿不到'),
        );
  });

  test('并发压测：峰值永不超过 limit', () async {
    const limit = 4;
    final s = Semaphore(limit);
    var live = 0;
    var peak = 0;
    var finished = 0;

    Future<void> one() => s.run<void>(() async {
          live++;
          if (live > peak) peak = live;
          // 让出事件循环若干次，制造重叠
          for (var i = 0; i < 5; i++) {
            await Future<void>.delayed(Duration.zero);
          }
          finished++;
          live--;
        });

    // 20 个任务抢 4 个名额
    await Future.wait(List.generate(20, (_) => one()));

    expect(finished, 20, reason: '20 个任务必须全部跑完');
    expect(peak, lessThanOrEqualTo(limit),
        reason: '峰值并发 $peak 超过了上限 $limit');
    expect(s.running, 0, reason: '全部结束后名额应回到 0');
    expect(s.waiting, 0);
  });

  test('release 多调不会把计数弄成负数（负数会让限流失效）', () {
    final s = Semaphore(2);
    s.release();
    s.release();
    s.release();
    expect(s.running, 0, reason: '计数不该变负');
  });
}
