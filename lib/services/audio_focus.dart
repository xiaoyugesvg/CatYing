import 'package:flutter/foundation.dart';

import 'app_log.dart';

/// 全局音频焦点协调器 —— **保证同一时刻只有一路声音在播**。
///
/// ── 为什么需要它（用户能直接听到的问题）────────────────────────
/// 本 App 里有**三套互相独立的播放器**：
///   1. 影视点播 → `IosAvPlayer`（iOS AVPlayer）
///   2. 直播     → 直播页自己的 media_kit `Player`
///   3. 音乐     → `MusicPlayerManager` 的 media_kit `Player`
///
/// 它们**没有任何互斥**。原来的处理只有一个
/// `LiveService.pauseLivePlayer` 回调，而且**只覆盖了「直播 ⇄ 点播」**：
///   · 看视频时音乐还在响
///   · 听音乐时点开视频 → 两边一起响（双声）
///
/// 现在收口到这里：**谁要出声，先让别家闭嘴**。
///
/// ── 为什么用"回调注册"而不是直接 import 各模块 ────────────────
/// `lib/services` 是底层，直接 import `lib/music` 会形成反向依赖
/// （音乐将来若独立出去会被这行卡住）。所以各模块**自己注册**：
///   · 影视点播：`VideoPlayerWidget` 在 initState 注册
///   · 直播    ：`live/view.dart` 注册（沿用它原来的位置）
///   · 音乐    ：`MusicPlayerManager` 在构造时注册
/// 这条依赖方向始终是「上层模块 → 底层服务」。
///
/// ⚠️ 用 [ChangeNotifier] 而不是 GetX Service：
/// 它是纯逻辑协调器，不需要 `Get.put`，也避免"忘了注册就永远不生效"。
/// （对比 `MusicPaletteBridge` 那种"忘了注册就静默退回默认"的设计，
///   这里的 [pauseOthers] 即使一个都没注册也只是"没人需要暂停"，无害。）
class AudioFocus {
  AudioFocus._();

  /// 谁在出声（用于日志与"是否已有声音"判断）
  static String? _owner;

  /// 各路的暂停回调。「让别家闭嘴」时全部调用（除了 [except]）。
  static final Map<String, Future<void> Function()> _pausers = {};

  /// 注册一路播放器。重复注册同一 [key] 会覆盖。
  static void register(String key, Future<void> Function() pause) {
    _pausers[key] = pause;
  }

  /// 注销（播放器 dispose 时调用，避免持有已销毁对象的回调）。
  ///
  /// ⚠️ 必须注销：不注销的话，切到别的 tab 后点播放会去调一个
  /// 已 dispose 的 controller → 抛异常或静默失败。
  static void unregister(String key) {
    _pausers.remove(key);
    if (_owner == key) _owner = null;
  }

  /// 声明"我要出声了"：[key] 之外的播放器**全部暂停**。
  ///
  /// 在**每次真正开始播放**前调用（不是注册时）。
  /// [key] 的暂停回调会被跳过 —— 否则会出现"刚按下播放又把自己暂停了"。
  static Future<void> request(String key) async {
    _owner = key;
    for (final e in _pausers.entries) {
      if (e.key == key) continue;
      try {
        await e.value();
      } catch (err) {
        // 某一方暂停失败不能影响其它方 —— 记日志但继续
        AppLog.instance.log('[AudioFocus] $key 请求焦点时 '
            '${e.key} 暂停失败: $err');
      }
    }
  }

  /// 主动让出焦点（当前播放器停止/退出时调用）
  static void release(String key) {
    if (_owner == key) _owner = null;
  }

  /// 当前出声的是谁（调试用）
  static String? get owner => _owner;

  /// 已注册的通道（调试用）
  @visibleForTesting
  static List<String> get registeredKeys => _pausers.keys.toList();
}
