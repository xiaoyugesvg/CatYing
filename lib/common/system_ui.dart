import 'package:flutter/services.dart';

/// 系统 UI 的统一入口：**沉浸模式 + 屏幕方向 + 状态栏图标明暗**。
///
/// ── 为什么需要它（V10）────────────────────────────────────────
/// 原来每个"全屏 / 沉浸"页面各写一遍 `SystemChrome`：
///   · `pages/detail/view.dart`        → `immersive`      ↔ `edgeToEdge`
///   · `pages/live/view.dart`          → `immersiveSticky` ↔ `edgeToEdge`
///   · `reading/pages/book_reader_page.dart` → `manual`（只留底栏）↔ `edgeToEdge`
///   · `reading/pages/reader_page.dart`      → `manual`（只留底栏）↔ `edgeToEdge`
///   · `pages/play/webview_player_page.dart` → 强制横屏，`dispose` 时
///     **无条件**恢复"竖屏 + 左右横屏"
///
/// 由此产生三个问题：
///   1. 隐藏粒度三种、退出时一律 `edgeToEdge`：嵌套（详情页全屏 → 退出）
///      时互相覆盖；
///   2. 退出时**无条件**写死方向，会把别的页面设定的方向锁覆盖掉；
///   3. 谁也不设 `SystemUiOverlayStyle`，状态栏图标明暗完全不受控。
///
/// 本类用**入栈/出栈**记录现场：`enter` 时保存当前状态，`exit` 时恢复
/// **进入前**的状态，而不是写死默认值。同一个 owner 重复 enter 不会重复入栈。
///
/// ⚠️ 方向只在显式传入 [orientations] 时才被改动 —— 详情页全屏的方向
/// 由 `widgets/video_player.dart` 自己管，本类不能去覆盖它。
class SystemUiController {
  SystemUiController._();

  /// App 常态：edge-to-edge + 允许竖屏与左右横屏
  static const SystemUiMode _defaultMode = SystemUiMode.edgeToEdge;
  static const List<DeviceOrientation> _defaultOrientations = [
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  static SystemUiMode _currentMode = _defaultMode;

  /// 当前**显式**设置过的方向；null = 没人设过（保持系统/其它页面的状态）
  static List<DeviceOrientation>? _currentOrientations;

  static SystemUiOverlayStyle? _currentStyle;

  static final List<_SystemUiSnapshot> _stack = [];

  /// 是否处于（任意页面请求的）沉浸态
  static bool get isImmersive => _stack.isNotEmpty;

  /// 进入沉浸/全屏。
  ///
  /// - [mode] 缺省 `immersiveSticky`
  /// - [orientations] **只在需要锁方向时传**（例如网页播放页强制横屏）
  /// - [overlayStyle] 黑底场景传 `SystemUiOverlayStyle.light`
  static Future<void> enter(
    String owner, {
    SystemUiMode mode = SystemUiMode.immersiveSticky,
    List<DeviceOrientation>? orientations,
    SystemUiOverlayStyle? overlayStyle,
    List<SystemUiOverlay>? overlays,
  }) async {
    // 幂等：同一 owner 重复进入只更新最上层，不重复入栈
    _stack.removeWhere((s) => s.owner == owner);
    _stack.add(_SystemUiSnapshot(
      owner: owner,
      mode: _currentMode,
      orientations: _currentOrientations,
      style: _currentStyle,
      overlays: null,
    ));
    await _apply(
      mode: mode,
      orientations: orientations,
      overlayStyle: overlayStyle,
      overlays: overlays,
    );
  }

  /// 退出沉浸/全屏，恢复**进入前**的状态。
  static Future<void> exit(String owner) async {
    final idx = _stack.lastIndexWhere((s) => s.owner == owner);
    if (idx < 0) {
      // 没有现场记录（热重载 / 异常路径）→ 回到默认，避免卡在隐藏状态栏
      await _apply(mode: _defaultMode, orientations: _defaultOrientations);
      _currentOrientations = null;
      return;
    }
    final snap = _stack.removeAt(idx);
    // 进入前没设过方向、但这次设过 → 恢复到 App 默认
    final restoreOrientations = snap.orientations ??
        (_currentOrientations != null ? _defaultOrientations : null);
    await _apply(
      mode: snap.mode,
      orientations: restoreOrientations,
      overlayStyle: snap.style,
      overlays: snap.overlays,
    );
  }

  /// 仅记录/应用图标明暗（不改变栈、不改方向）。
  ///
  /// 供主题系统（`AppBrightness` 变化 / 无 AppBar 页面）使用。
  static void applyOverlayStyle(SystemUiOverlayStyle? style) {
    _currentStyle = style;
    if (style != null) SystemChrome.setSystemUIOverlayStyle(style);
  }

  /// 仅锁定屏幕方向（**不改系统栏模式**）。
  ///
  /// 用于"优先横屏"这类只想转屏、不想碰沉浸状态的场景。
  /// 同一 owner 重复调用幂等（只记第一次的现场）。
  static Future<void> lockOrientations(
    String owner,
    List<DeviceOrientation> orientations,
  ) async {
    _orientationOwners.putIfAbsent(owner, () => _currentOrientations);
    _currentOrientations = orientations;
    await SystemChrome.setPreferredOrientations(orientations);
  }

  /// 还原该 owner 上次 [lockOrientations] 之前的方向。
  ///
  /// 进入前没人设过 → 回到 App 默认（竖屏 + 左右横屏），
  /// 而不是像旧代码那样**无条件**写死一个方向集合。
  static Future<void> unlockOrientations(String owner) async {
    if (!_orientationOwners.containsKey(owner)) return;
    final prev = _orientationOwners.remove(owner);
    _currentOrientations = prev;
    await SystemChrome.setPreferredOrientations(
      prev ?? _defaultOrientations,
    );
  }

  /// 当前记录的图标明暗（供页面自行判断是否需要覆盖）
  static SystemUiOverlayStyle? get currentOverlayStyle => _currentStyle;

  /// 方向锁的 owner → 其锁定前的方向（null = 之前没人显式设过）
  static final Map<String, List<DeviceOrientation>?> _orientationOwners = {};

  static Future<void> _apply({
    required SystemUiMode mode,
    List<DeviceOrientation>? orientations,
    SystemUiOverlayStyle? overlayStyle,
    List<SystemUiOverlay>? overlays,
  }) async {
    _currentMode = mode;
    if (overlayStyle != null) _currentStyle = overlayStyle;

    if (mode == SystemUiMode.manual) {
      await SystemChrome.setEnabledSystemUIMode(
        mode,
        overlays: overlays ?? const [SystemUiOverlay.bottom],
      );
    } else {
      await SystemChrome.setEnabledSystemUIMode(mode);
    }

    // ⚠️ 只有显式传了方向才动它 —— 详情页全屏的方向由 video_player 管
    if (orientations != null) {
      _currentOrientations = orientations;
      await SystemChrome.setPreferredOrientations(orientations);
    }

    if (overlayStyle != null) {
      SystemChrome.setSystemUIOverlayStyle(overlayStyle);
    }
  }
}

class _SystemUiSnapshot {
  _SystemUiSnapshot({
    required this.owner,
    required this.mode,
    required this.orientations,
    required this.style,
    required this.overlays,
  });

  final String owner;
  final SystemUiMode mode;
  final List<DeviceOrientation>? orientations;
  final SystemUiOverlayStyle? style;
  final List<SystemUiOverlay>? overlays;
}
