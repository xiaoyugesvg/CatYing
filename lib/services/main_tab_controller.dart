import 'package:get/get.dart';

/// 全局主 Tab 控制器
///
/// 底部悬浮导航栏（首页/历史/收藏/设置）的选中项由本控制器
/// 全局持有，这样：
/// 1. 根 ContentView 的 IndexedStack / 悬浮栏切换 tab；
/// 2. 详情页等 push 出来的全屏路由也能渲染同样的底部悬浮栏，
///    点击后回到根界面并切换对应 tab。
class MainTabController extends GetxController {
  static MainTabController get instance => Get.find<MainTabController>();

  /// 当前选中的主 tab 索引：0 首页 / 1 历史 / 2 收藏 / 3 设置
  final RxInt selectedTab = 0.obs;

  /// 切换主 tab
  void select(int index) {
    selectedTab.value = index;
  }
}
