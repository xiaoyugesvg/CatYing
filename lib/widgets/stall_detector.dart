/// 「加载卡死」判定 —— 纯逻辑，**不依赖播放器**，因此可以直接单测。
///
/// ── 为什么需要它（复核发现的严重缺口）────────────────────────────
/// 播放器的媒体加载**完全没有超时**：
///   · 弹幕 HTTP 有 8s/12s 超时，但 `_player.open(...)` 一处都没有
///   · 采集源给的 CDN 直链**挂起**（收下请求但不发数据、也不断开）时，
///     多数播放内核**不会**抛 error 事件 —— 它只是永远不 ready
///   ⇒ `_isBuffering` 永远 true → **转圈无限转**，用户分不清
///     "还在加载"还是"已经坏了" ✗
///   ⇒ 而且详情页的重试按钮挂在 `onError` 上 → 挂起时**连重试都出不来** ✗
///
/// 所以必须自己数时间：**在缓冲 + 位置连续 N 秒没前进** = 卡死。
///
/// ── 为什么把它抽出来 ────────────────────────────────────────────
/// 原来这段逻辑写在 `_VideoPlayerWidgetState` 里，而那个 State 依赖
/// media_kit 原生库（`AppPlayer` 是 `late final`），**测试里构造不出来** ⇒
/// "卡死检测到底会不会触发"根本没法验证 ✗
/// 抽成这个类之后，`tick()` 是纯函数式的状态推进，可以逐秒断言 ✓
class StallDetector {
  /// 连续多少秒没有前进就判为卡死。
  ///
  /// 15s 的取舍：正片首次起播在慢网下偶尔要 8~12s（尤其高码率直链），
  /// 判太早会误报；超过 15s 基本可以确定是源的问题而不是网络抖动。
  final int thresholdSeconds;

  bool _stalled = false;

  /// 上一次"位置有前进"的时刻（由 [markProgress] / [reset] 更新）
  DateTime _lastProgressAt;

  /// 上次用于判断的位置（秒）。只在**整秒变化**时刷新时间戳，
  /// 否则每 20ms 一次的 position 回调都会刷新它（白忙）。
  int _lastSec = -1;

  StallDetector({this.thresholdSeconds = 15, DateTime? now})
      : _lastProgressAt = now ?? DateTime.now();

  /// 当前是否已判定为"卡死"
  bool get stalled => _stalled;

  /// 供调试/测试查看：已经多少秒没有前进
  Duration idleFor(DateTime now) => now.difference(_lastProgressAt);

  /// 新一次加载开始（换集 / 重试 / 新 URL）→ 复位
  void reset({DateTime? now}) {
    _lastProgressAt = now ?? DateTime.now();
    _lastSec = -1;
    _stalled = false;
  }

  /// 播放位置前进时调用。
  ///
  /// [positionSeconds] 用整秒传入即可（内部会去重）——
  /// 只要**秒数变了**就认为"有前进"，刷新时间戳并解除卡死判定。
  void markProgress(int positionSeconds, {DateTime? now}) {
    if (positionSeconds == _lastSec) return;
    _lastSec = positionSeconds;
    _lastProgressAt = now ?? DateTime.now();
    // 位置都前进了，自然不再是卡死（比如用户手动 seek 唤醒了它）
    _stalled = false;
  }

  /// 每秒调一次。返回**是否刚判定为卡死**（true = 调用方该弹提示）。
  ///
  /// [buffering] 不在缓冲 → 一定不是卡死（并解除已有判定）。
  /// [playing] 暂停中也不算（用户自己停的，位置本来就不动）。
  bool tick({
    required bool buffering,
    required bool playing,
    DateTime? now,
  }) {
    final n = now ?? DateTime.now();

    if (!buffering) {
      _stalled = false;
      return false;
    }
    // 暂停中位置不动是正常的，不判卡死
    if (!playing) return false;

    final idle = n.difference(_lastProgressAt).inSeconds;
    if (idle >= thresholdSeconds && !_stalled) {
      _stalled = true;
      return true;
    }
    return false;
  }
}
