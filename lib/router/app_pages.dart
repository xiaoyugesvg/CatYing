import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../pages/home/view.dart';
import '../pages/history/view.dart';
import '../pages/favorites/view.dart';
import '../pages/settings/view.dart';
import '../pages/detail/view.dart';
import '../pages/search/view.dart';
import '../pages/dlna/view.dart';
import '../pages/live/view.dart';
import '../pages/live/settings_view.dart';

class AppPages {
  static const String detail = '/detail';
  static const String search = '/search';
  static const String dlna = '/dlna';
  static const String live = '/live';
  static const String liveSettings = '/live/settings';

  /// 统一淡入淡出，避免默认左右推挤与透明底叠影
  static const _fade = CustomTransition(
    transitionDuration: Duration(milliseconds: 220),
    transitionsBuilder: (
      BuildContext context,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
      Widget child,
    ) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      );
    },
  );

  static final pages = [
    GetPage(
      name: detail,
      page: () => DetailPage(),
      transition: Transition.fadeIn,
      transitionDuration: const Duration(milliseconds: 220),
      customTransition: _fade,
    ),
    GetPage(
      name: search,
      page: () => SearchPage(
        // 对应 Swift: 从其他页面传入关键词时自动搜索
        initialKeyword: Get.arguments as String?,
      ),
      transition: Transition.fadeIn,
      transitionDuration: const Duration(milliseconds: 220),
      customTransition: _fade,
    ),
    GetPage(
      name: dlna,
      page: () => const DLNAPage(),
      transition: Transition.fadeIn,
      transitionDuration: const Duration(milliseconds: 220),
      customTransition: _fade,
    ),
    GetPage(
      name: live,
      page: () => const LivePage(),
      transition: Transition.fadeIn,
      transitionDuration: const Duration(milliseconds: 220),
      customTransition: _fade,
    ),
    GetPage(
      name: liveSettings,
      page: () => const LiveSettingsPage(),
      transition: Transition.fadeIn,
      transitionDuration: const Duration(milliseconds: 220),
      customTransition: _fade,
    ),
  ];
}
