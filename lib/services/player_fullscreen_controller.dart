import 'package:get/get.dart';

/// 全屏状态控制器 - 全局单例
///
/// **背景**: iOS 上 WindowFullScreen.enter() 是 no-op, native fullscreen 不能
/// 覆盖其他 Scaffold. 之前 detail view 自己监听 onFullScreenChanged 来切换
/// immersive (隐藏 AppBar + body 黑色), 但 app.dart 根 Scaffold 的 bottom
/// navigation bar (首页/直播/历史/收藏/设置) 不会感知, 导致直播页全屏时
/// 底栏依然显示.
///
/// **修复**: 任何 video 全屏时, 把自己注册到这个全局 Rx, app.dart 监听
/// 该 Rx 隐藏 bottom navigation bar. detail view 内部已经处理 AppBar 隐藏,
/// 这里只解决"根 Scaffold 的底栏".
class PlayerFullscreenController extends GetxController {
  static PlayerFullscreenController get instance => Get.find();

  /// true = 有视频处于全屏 (app.dart 用它隐藏底栏)
  final isFullscreen = false.obs;

  /// 当前处于全屏的**来源集合**（引用计数）。
  ///
  /// ⚠️ 2026-10-15：原来只有一个 bool，`enter/exit` 完全忽略传入的 `sourceId`。
  ///   而详情页全屏 + 直播页全屏**可以同时存在**（例如详情页全屏时又推入
  ///   直播页全屏）—— 任一方 `exit` 就把 bool 置 false，会让另一个仍在全屏的
  ///   页面底栏**提前恢复显示**。同仓的 `DetailPageController` 已用计数解决
  ///   同类问题，这里对齐。
  final Set<String> _fullscreenSources = <String>{};

  void enter(String sourceId) {
    _fullscreenSources.add(sourceId);
    isFullscreen.value = _fullscreenSources.isNotEmpty;
  }

  void exit(String sourceId) {
    // 移除不存在的 id 是无害的（例如直播页 dispose 时补一次 exit）
    _fullscreenSources.remove(sourceId);
    isFullscreen.value = _fullscreenSources.isNotEmpty;
  }
}
