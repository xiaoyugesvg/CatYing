import 'package:get/get.dart';

/// 全局主 Tab 控制器
///
/// 底部悬浮导航栏（首页/历史/收藏/设置）的选中项由本控制器
/// 全局持有，这样：
/// 1. 根 ContentView 的 IndexedStack / 悬浮栏切换 tab；
/// 2. 详情页等 push 出来的全屏路由也能渲染同样的底部悬浮栏，
///    点击后回到根界面并切换对应 tab。
///
/// ── 三个模块的入口索引（重要）─────────────────────────────────
/// 猫影的底栏同时是**三个模块**的入口：
///   · 0~4  影视（首页/史藏/…/设置/直播）
///   · 5    音乐（MusicRootView，自带 4-tab 悬浮栏）
///   · 6    阅读（cmbok HomePage，自带 5-tab 悬浮栏）
///
/// 音乐和阅读各自有独立悬浮栏，所以进入它们时**影视底栏必须隐藏**
/// （否则两条栏会叠在一起）。判断处见 `app.dart`。
///
/// 索引写成这里的常量而不是散落的字面量：
/// 音乐/阅读模块的悬浮栏要加「返回影视」按钮，
/// 那个按钮就得 `select(MainTabController.videoTabIndex)` ——
/// 硬编码 0 在以后调整顺序时会静默失效。
class MainTabController extends GetxController {
  static MainTabController get instance => Get.find<MainTabController>();

  /// 影视首页（也是「返回影视」的目标）
  static const int videoTabIndex = 0;

  /// 「史藏」= 历史 + 收藏（索引 1）。
  /// 阅读里的「已下载」入口要跳到这里 —— 下载好的漫画/图书
  /// 都归在史藏的书架里，没有独立的"下载页"tab。
  static const int bookshelfTabIndex = 1;

  /// 音乐模块
  static const int musicTabIndex = 5;

  /// 阅读模块
  static const int booksTabIndex = 6;

  /// 当前选中的主 tab 索引：0 首页 / 1 历史 / 2 收藏 / 3 设置 / 5 音乐 / 6 阅读
  final RxInt selectedTab = 0.obs;

  /// 切换主 tab
  void select(int index) {
    selectedTab.value = index;
  }

  /// 当前是否在音乐/阅读模块里（这两个模块自带悬浮栏，影视底栏要让位）
  bool get inEmbeddedModule =>
      selectedTab.value == musicTabIndex || selectedTab.value == booksTabIndex;

  /// 回到影视首页
  void backToVideo() => select(videoTabIndex);
}
