/// 书源级请求限流 —— 对齐 Legado 的 `concurrentRate` 字段。
///
/// 两种官方格式（见 Legado 开发文档「源规则 → 并发率」）：
///   · `N`     —— 两次请求之间至少间隔 N 毫秒；
///   · `N/M`   —— 任意 M 毫秒窗口内最多 N 次请求。
///
/// 为什么必须有：不少书源站点对短时间连发很敏感（搜索结果翻页、目录分页、
/// 正文多页会连续打十几次），触发后直接 403 / 验证码 ⇒ 用户看到的是
/// 「搜索没结果 / 目录为空」。以前只靠一条固定的 120ms 节流，做不到
/// 「按源配置」。
///
/// 实现要点：
///   · 按 `bookSourceUrl` 分桶（不同源互不影响）；
///   · `acquire` 串行化同一源的请求（并发调用不会绕过限流）；
///   · 解析失败的配置按"不限流"处理，绝不因为配置写法怪异而卡死请求。
library;

import 'dart:async';

class SourceRateLimiter {
  SourceRateLimiter._();
  static final SourceRateLimiter instance = SourceRateLimiter._();

  final Map<String, _Bucket> _buckets = {};

  /// 取到一次请求许可（必要时等待）。[rate] 为源里的 `concurrentRate`。
  Future<void> acquire(String sourceKey, String? rate) async {
    final spec = _parse(rate);
    if (spec == null) return;
    final key = sourceKey.trim().isEmpty ? 'default' : sourceKey.trim();
    final bucket = _buckets.putIfAbsent(key, _Bucket.new);
    // 串行化：同一源的并发请求排队，否则"同时发 5 个"会直接绕过限流。
    final prev = bucket.tail;
    final gate = Completer<void>();
    bucket.tail = gate.future;
    await prev;
    try {
      await _wait(bucket, spec);
    } finally {
      gate.complete();
    }
  }

  Future<void> _wait(_Bucket b, _Spec spec) async {
    if (spec.windowMs > 0) {
      // 窗口模式：N/M
      while (true) {
        final now = DateTime.now().millisecondsSinceEpoch;
        b.hits.removeWhere((t) => now - t >= spec.windowMs);
        if (b.hits.length < spec.count) {
          b.hits.add(now);
          return;
        }
        // 等到窗口里最早那次请求过期
        final waitMs = spec.windowMs - (now - b.hits.first);
        await Future<void>.delayed(Duration(milliseconds: waitMs.clamp(1, spec.windowMs)));
      }
    }
    // 间隔模式：N
    final now = DateTime.now().millisecondsSinceEpoch;
    final waitMs = b.lastMs + spec.intervalMs - now;
    if (waitMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: waitMs));
    }
    b.lastMs = DateTime.now().millisecondsSinceEpoch;
  }

  /// `N` / `N/M` → 规格；空或非法 → null（不限流）
  static _Spec? _parse(String? raw) {
    final s = (raw ?? '').trim();
    if (s.isEmpty) return null;
    final m = RegExp(r'^(\d+)\s*(?:/\s*(\d+))?$').firstMatch(s);
    if (m == null) return null;
    final first = int.tryParse(m.group(1)!) ?? 0;
    final second = m.group(2) == null ? null : int.tryParse(m.group(2)!);
    if (first <= 0) return null;
    if (second == null) {
      return _Spec(intervalMs: first, count: 1, windowMs: 0);
    }
    if (second <= 0) return null;
    return _Spec(intervalMs: 0, count: first, windowMs: second);
  }

  /// 仅供单测
  static String debugDescribe(String? rate) {
    final s = _parse(rate);
    if (s == null) return 'none';
    return s.windowMs > 0
        ? 'window:${s.count}/${s.windowMs}'
        : 'interval:${s.intervalMs}';
  }
}

class _Spec {
  final int intervalMs;
  final int count;
  final int windowMs;

  const _Spec({
    required this.intervalMs,
    required this.count,
    required this.windowMs,
  });
}

class _Bucket {
  int lastMs = 0;
  final List<int> hits = [];
  Future<void> tail = Future<void>.value();
}
