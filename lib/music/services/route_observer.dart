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

  /// **现在是否在根页面**（没有子页面压在根路由之上）。
  ///
  /// ── 🔴 为什么不能数"路由总数"（这是我上一版犯的错）────────────────
  /// 原来写的是「总数 <= 1」，而 `didPush` **无条件 +1**。
  ///
  /// 但 `GetMaterialApp` 启动时**不止一条根路由** ——
  /// 还有 GetX 自己的初始化路由等，都会触发 `didPush`。
  /// 于是总数变成 2、3… → `isOnRoot` **恒为 false**
  /// → **音乐主页的导航栏和播放条被整体隐藏** ✗
  ///（用户实测反馈：「音乐为啥不显示悬浮导航栏和播放条了？」）
  ///
  /// ── 正确判据 ───────────────────────────────────────────────────
  /// 真正要问的是"**有没有路由压在根路由上面**"，而不是"一共几条"。
  ///
  /// `didPush(route, previousRoute)` 的 `previousRoute` 正好表达这件事：
  ///   · `previousRoute == null` → 这是**第一个**路由（根），不算"压上去"
  ///   · `previousRoute != null` → 它是被 push 到某个已有路由**上面**的
  ///
  /// 所以只统计 `previousRoute != null` 的 push 次数（[pushedFrom]），
  /// 它**天然忽略**启动阶段那些平级的根路由。
  ///
  /// ── 🔴 为什么还要过滤 `music:page` 标记（另一个真 bug）──────────
  /// 光靠 `previousRoute != null` 还不够：在**影视/阅读**里深推一个
  /// 详情页（也满足 `previousRoute != null`），再切到**音乐 tab**
  ///（`ContentView` 的 `IndexedStack` 切 tab **不会弹路由**）——
  /// `pushedFrom` 还停在 1 → 音乐主页被判成"子页面"
  /// → 导航栏 + 播放条**又整条消失** ✗
  ///
  /// 修法：只统计**带 `music:page` 标记**的子页面（音乐模块自己的
  /// push 都带 `settings: RouteSettings(name: 'music:page')`）。
  /// 其他模块深推多少层都不影响音乐主页判定。
  static bool get isOnRoot => pushedFrom.value <= 0;

  /// 被 push 到**其它路由之上**的次数（= 根之上压了几层）。
  ///
  /// 显示规则依赖它，所以底栏会监听它（必须是 `Listenable`）。
  /// ⚠️ 只统计带 [musicRouteTag] 标记的子页面（见 [isOnRoot]）。
  static final ValueNotifier<int> pushedFrom = ValueNotifier<int>(0);

  /// 音乐子页面路由标记：push 时给 `MaterialPageRoute` 传
  /// `settings: const RouteSettings(name: MusicRouteObserver.musicRouteTag)`，
  /// observer 只统计**这些**路由 —— 其他模块（影视/阅读）的深推
  /// 不会污染音乐主页的判定。
  static const String musicRouteTag = 'music:page';

  bool _isMusicRoute(Route<dynamic> route) =>
      route.settings.name?.startsWith(musicRouteTag) ?? false;

  /// 路由**总数**。只用于日志/调试 —— **不要**拿它判"在不在根页面"
  ///（见 [isOnRoot] 的说明）。
  static final ValueNotifier<int> pushedCount = ValueNotifier<int>(1);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushedCount.value = pushedCount.value + 1;
    // 只有"压在别的路由之上"（previousRoute != null）**且带音乐标记**
    // 才算进了音乐子页面；启动根路由和其他模块深推都不计入
    if (previousRoute != null && _isMusicRoute(route)) {
      pushedFrom.value = pushedFrom.value + 1;
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (pushedCount.value > 1) pushedCount.value = pushedCount.value - 1;
    // 被 pop 的这条原本"压在别的路由之上" → 少一层
    if (previousRoute != null && _isMusicRoute(route) && pushedFrom.value > 0) {
      pushedFrom.value = pushedFrom.value - 1;
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (pushedCount.value > 1) pushedCount.value = pushedCount.value - 1;
    // ⚠️ 这里用 `previousRoute != null` 而不是"总数 > 1"：
    //    `pushAndRemoveUntil` 移除的可能是**根**（previousRoute 为 null），
    //    那不是"退出子页面"，不该 -> decrement
    if (previousRoute != null && _isMusicRoute(route) && pushedFrom.value > 0) {
      pushedFrom.value = pushedFrom.value - 1;
    }
  }

  /// `pushReplacement` / `pushAndRemoveUntil` 等：层级**不变**
  ///（替换是"一进一出"，所以这里什么都不做）
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {}

  /// **仅测试用**：复位到"在根页面、只有一条路由"。
  ///
  /// 单例状态会跨测试残留（`MusicBottomChrome` 的显示规则依赖它），
  /// 每个测试开头调一下。
  @visibleForTesting
  static void resetForTest() {
    pushedCount.value = 1;
    pushedFrom.value = 0;
  }

  /// **仅测试用**：模拟"进了子页面"（等价于一次 `didPush(sub, root)`）。
  @visibleForTesting
  static void debugEnterSubPage() => pushedFrom.value = pushedFrom.value + 1;

  /// **仅测试用**：模拟"回到根页面"。
  @visibleForTesting
  static void debugBackToRoot() => pushedFrom.value = 0;
}
