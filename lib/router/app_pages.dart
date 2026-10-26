import 'package:get/get.dart';
import 'package:tvbox/pages/detail/view.dart';
import 'package:tvbox/pages/media_library/media_library_detail_page.dart';
import 'package:tvbox/pages/search/view.dart';
import 'package:tvbox/pages/dlna/view.dart';
import 'package:tvbox/pages/live/view.dart';
import 'package:tvbox/pages/live/settings_view.dart';
import 'package:tvbox/services/tmdb_service.dart';

class AppPages {
  static const String detail = '/detail';
  static const String search = '/search';
  static const String dlna = '/dlna';
  static const String live = '/live';
  static const String liveSettings = '/live/settings';

  /// 路由统一不指定 transition —— 继承 `GetMaterialApp.defaultTransition`
  /// （iOS 风格右滑进入/左滑返回，全局丝滑一致）。
  static final pages = [
    GetPage(
      name: detail,
      // 设置 → TMDB 管理 → 媒体库模式：开启后详情页整体切换为媒体库界面
      page: () => TmdbService.instance.libraryMode.value
          ? MediaLibraryDetailPage()
          : DetailPage(),
    ),
    GetPage(
      name: search,
      page: () => SearchPage(
        // 对应 Swift: 从其他页面传入关键词时自动搜索
        initialKeyword: Get.arguments as String?,
      ),
    ),
    GetPage(
      name: dlna,
      page: () => const DLNAPage(),
    ),
    GetPage(
      name: live,
      page: () => const LivePage(),
    ),
    GetPage(
      name: liveSettings,
      page: () => const LiveSettingsPage(),
    ),
  ];
}
