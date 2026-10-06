import 'dart:async';

/// 朴素的**异步信号量**：限制"同时进行的操作数"。
///
/// ── 为什么需要它（而不是每个调用各自限流）────────────────────────
/// `UnblockService.resolveAll` 原来用
/// `List.generate(_concurrency, worker)` —— 那是**每次调用**各开 4 个：
/// 用户快速连点两首歌 → 两个调用同时在跑 → **8 个 Node vm 沙箱**同时开，
/// 正好是那段注释声称"必须避免"的情况（内存/CPU 尖峰 + 被源站风控）。
///
/// 抽成独立类是为了**能单测**：并发正确性靠读代码是不可靠的。
///
/// ── 实现要点 ──────────────────────────────────────────────────
/// · 还有余量 → 立即放行（`_running++`）
/// · 满了 → 把 completer 排进队列，等别人 [release] 时**直接移交名额**
///  · 移交时**不先减再加** —— 否则中间可能被别人插队，导致超过上限
class Semaphore {
  Semaphore(this.limit) : assert(limit > 0, 'limit 必须为正');

  final int limit;

  int _running = 0;
  final _waiting = <Completer<void>>[];

  /// 当前真正在跑的数量（测试用）
  int get running => _running;

  /// 在排队的数量（测试用）
  int get waiting => _waiting.length;

  /// 申请一个名额：有余量就立即完成，否则排队。
  Future<void> acquire() {
    if (_running < limit) {
      _running++;
      return Future<void>.value();
    }
    final c = Completer<void>();
    _waiting.add(c);
    return c.future;
  }

  /// 释放一个名额：有人在等就**移交**给它，否则减计数。
  void release() {
    if (_waiting.isNotEmpty) {
      // 直接把名额交给队首（不先减再加，避免被插队）
      _waiting.removeAt(0).complete();
      return;
    }
    // ⚠️ 不让计数掉到负数 —— 负数会让后续 acquire 永远放行（并发失控）
    if (_running > 0) _running--;
  }

  /// 包一层：保证 `release` 一定被调用（即使 body 抛异常）
  Future<T> run<T>(Future<T> Function() body) async {
    await acquire();
    try {
      return await body();
    } finally {
      release();
    }
  }
}
