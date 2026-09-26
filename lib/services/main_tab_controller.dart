import 'package:get/get.dart';
import '../pages/live/controller.dart';

/// 全局主 Tab 控制器
///
/// 底部悬浮导航栏（首页/直播/历史/收藏/设置）的选中项由本控制器
/// 全局持有，这样：
/// 1. 根 ContentView 的 IndexedStack / 悬浮栏切换 tab；
/// 2. 详情页等 push 出来的全屏路由也能渲染同样的底部悬浮栏，
///    点击后回到根界面并切换对应 tab。
///
/// 原实现把 _selectedTab 放在 _ContentViewState 私有字段里，
/// 详情页（Get.toNamed 独立路由）无法触达，导致详情页没有底部悬浮菜单栏。
class MainTabController extends GetxController {
  static MainTabController get instance => Get.find<MainTabController>();

  /// 当前选中的主 tab 索引：0 首页 / 1 直播 / 2 历史 / 3 收藏 / 4 设置
  final RxInt selectedTab = 0.obs;

  /// 切换主 tab；index == 1（直播）时同时恢复直播页可见与播放，
  /// 切走时暂停直播播放（与 ContentView._navItem 原逻辑保持一致）。
  void select(int index) {
    final prev = selectedTab.value;
    selectedTab.value = index;
    if (Get.isRegistered<LiveController>()) {
      final liveController = Get.find<LiveController>();
      if (index == 1) {
        liveController.isLivePageVisible.value = true;
        liveController.resumePlayback();
      } else if (prev == 1) {
        liveController.isLivePageVisible.value = false;
        liveController.pausePlayback();
      }
    }
  }
}
