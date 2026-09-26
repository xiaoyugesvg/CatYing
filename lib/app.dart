import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'dart:ui' show ImageFilter;

import 'common/theme.dart';
import 'common/constants.dart';
import 'models/movie.dart';
import 'services/api_config.dart';
import 'services/app_state.dart';
import 'services/background_service.dart';
import 'services/main_tab_controller.dart';
import 'services/player_fullscreen_controller.dart';
import 'pages/home/view.dart';
import 'pages/history/view.dart';
import 'pages/favorites/view.dart';
import 'pages/settings/view.dart';
import 'widgets/glass.dart';
import 'widgets/common_widgets.dart';

/// 根界面 - 对应 Swift ContentView
/// 悬浮玻璃底栏 + IndexedStack 4 tab (首页/历史/收藏/设置)
class HomeView extends StatefulWidget {
  const HomeView({super.key});

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  final _tabPages = const [
    HomeTabPage(),
    HistoryPage(),
    FavoritesPage(),
    SettingsPage(),
  ];

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    const navSideGap = 32.0;
    const navFloatGap = 8.0;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // 全局背景层（4 个 tab 共享，保证背景一致）
          Positioned.fill(
            child: BackgroundService.instance
                .buildBackground(overlayAlpha: 0.3),
          ),
          // 主内容
          Positioned.fill(
            child: Obx(() {
              return IndexedStack(
                index: MainTabController.instance.selectedTab.value,
                children: _tabPages,
              );
            }),
          ),
          // 底部悬浮导航栏 - 轻玻璃胶囊，悬浮于页面之上，不遮挡内容
          Positioned(
            left: navSideGap,
            right: navSideGap,
            bottom: bottomInset + navFloatGap,
            child: Obx(() {
              final current = MainTabController.instance.selectedTab.value;
              return GlassPanel(
                radius: 30,
                // **轻玻璃悬浮胶囊 (2026-09-26)**：毛玻璃+极薄半透明底色，
                // 悬浮轮廓清晰但内容可透出，不再有厚背景遮挡。
                blur: true,
                tint: Colors.black.withValues(alpha: 0.16),
                borderColor: Colors.white.withValues(alpha: 0.10),
                borderWidth: 0.8,
                highlightStrength: 0.2,
                shadow: true,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _navItem(Icons.home_outlined, Icons.home, '首页', 0, current),
                    _navItem(Icons.schedule_outlined, Icons.schedule, '历史', 1, current),
                    _navItem(Icons.favorite_border, Icons.favorite, '收藏', 2, current),
                    _navItem(Icons.settings_outlined, Icons.settings, '设置', 3, current),
                  ],
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _navItem(
      IconData icon, IconData activeIcon, String label, int index, int current) {
    final isSelected = current == index;
    return GestureDetector(
      onTap: () => MainTabController.instance.select(index),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.accentColor.withValues(alpha: 0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isSelected ? activeIcon : icon,
              size: 18,
              color: isSelected
                  ? AppTheme.accentColor
                  : Colors.white.withValues(alpha: 0.35),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: isSelected
                    ? AppTheme.accentColor
                    : Colors.white.withValues(alpha: 0.35),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 全局根 Widget
class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'TVBox',
      theme: AppTheme.darkTheme,
      debugShowCheckedModeBanner: false,
      initialRoute: '/',
      getPages: [],
      home: const HomeView(),
    );
  }
}
