import 'package:flutter/material.dart';

/// 全局路由深度观察者 —— 用来判断"**现在是不是在根页面**"。
///
/// ── 🔴 为什么需要它（修一个真 bug）────────────────────────────────
///
/// 音乐底栏（`MusicBottomChrome`）的显示规则是：
///   · **根页面**（音乐主 tab）→ 播放条 + **导航栏**
///   · **子页面**（push 上去的）→ **只有播放条**（用户明确要求）
///
/// 原来的判据是 `MusicRootView.isMounted` ——
/// **它永远为 true** ✗，因为 `MusicRootView` 挂在 `ContentView` 的
/// `IndexedStack` 里（`:590`）。`IndexedStack` 会让**所有**子页保持挂载，
/// push 一个子页面时根视图**仍在树里**，`dispose` 永远不会被调用。
///
/// 后果（用户实测反馈）：
///   · 「子页面显示播放条」这个开关关掉了，**子页面照样有导航栏** ✗
///   · push 出来的全屏播放器上**也画着导航栏** ✗
///
/// ── 为什么用 `NavigatorObserver` 而不是别的 ──────────────────────
/// 判断"在不在根页面"本质上是问**路由栈有多深**，而这是导航器自己的状态。
/// 试过但不行的替代方案：
///   · `navigatorKey.currentState.canPop()` —— **没法通知**变化
///     （它是方法不是 Listenable，UI 不会因此重建）
///   · 让子页面自己 `dispose` 时清标记 —— 拿不到"当前是不是最上层"
///     （push B 时 A 不会 dispose；pop 回 A 时 B 才 dispose，时序对不上）
///
/// `NavigatorObserver` 是框架为这件事提供的正解，且**不需要动任何子页面**。
///
/// ── 用法 ────────────────────────────────────────────────────────
/// 把它加进 `app.dart` 的 `navigatorObservers`：
/// ```dart
/// navigatorObservers: [MusicRouteObserver()],
/// ```
/// 然后读 [pushedCount] / [isOnRoot]。
///
/// ⚠️ 用 `ValueNotifier` 而不是裸 `int`：底栏那层是
/// `AnimatedBuilder` + `Listenable.merge`，裸 int 变了**不会触发重建**。
class MusicRouteObserver extends NavigatorObserver {
  MusicRouteObserver();

  /// 当前路由栈**深度**。
  ///
  /// 初值 1 = 只有根路由（`GetMaterialApp.home`）。
  /// push 一次 → 2；再 push → 3；pop 回 → 递减。
  static final ValueNotifier<int> pushedCount = ValueNotifier<int>(1);

  /// **现在是否在根页面**（路由栈里只有根那一条）。
  ///
  /// `<= 1` 而不是 `== 1`：万一某个平台在启动时多压一条（或 observer
  /// 注册得比首帧晚），也不会把根页面误判成子页面。
  static bool get isOnRoot => pushedCount.value <= 1;

  void _inc() => pushedCount.value = pushedCount.value + 1;

  void _dec() {
    // 不让它掉到 1 以下 —— 那样 `isOnRoot` 会一直是 true 之后又永远 false
    if (pushedCount.value > 1) pushedCount.value = pushedCount.value - 1;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _inc();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _dec();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _dec();

  /// `pushReplacement` / `pushAndRemoveUntil` 等：栈深度**不变**
  ///（替换是"一进一出"，所以这里什么都不做）
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {}

  /// **仅测试用**：把深度复位到"只有根路由"。
  ///
  /// 单例状态在测试之间会串（`MusicBottomChrome` 的显示规则依赖它），
  /// 每个测试开头调一下。
  @visibleForTesting
  static void resetForTest() => pushedCount.value = 1;
}
