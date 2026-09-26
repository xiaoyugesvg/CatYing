import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'common/theme.dart';
import 'pages/home/controller.dart';
import 'pages/detail/controller.dart';
import 'pages/live/controller.dart';
import 'pages/history/controller.dart';
import 'pages/favorite/controller.dart';
import 'pages/settings/controller.dart';
import 'services/main_tab_controller.dart';
import 'services/config_service.dart';
import 'widgets/glass.dart';
import 'pages/home/view.dart';
import 'pages/live/view.dart';
import 'pages/history/view.dart';
import 'pages/favorite/view.dart';
import 'pages/settings/view.dart';

void main() {
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'TVBox',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      initialBinding: BindingsBuilder(() {
        Get.put(MainTabController(), permanent: true);
      }),
      home: const RootShell(),
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  @override
  void initState() {
    super.initState();
    Get.put(ConfigService(), permanent: true);
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final tab = Get.find<MainTabController>();
      return Scaffold(
        backgroundColor: AppTheme.backgroundPrimary,
        body: Stack(
          children: [
            Positioned.fill(
              child: IndexedStack(
                index: tab.index.value,
                children: const [
                  HomePage(),
                  LivePage(),
                  HistoryPage(),
                  FavoritePage(),
                  SettingsPage(),
                ],
              ),
            ),
            // 底部悬浮导航栏（透明无框）
            Align(
              alignment: Alignment.bottomCenter,
              child: GlassPanel(
                // 彻底去掉玻璃面板的"框/背景"：完全透明，图标文字直接浮于内容上方
                tint: Colors.transparent,
                borderColor: Colors.transparent,
                borderWidth: 0,
                borderRadius: 0,
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).padding.bottom + 6,
                  top: 8,
                  left: 12,
                  right: 12,
                ),
                child: _buildNavBar(tab),
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _buildNavBar(MainTabController tab) {
    final items = tab.navItems;
    return Row(
      children: items.map((item) {
        final selected = tab.index.value == item.id;
        final icon = selected ? item.selectedIcon : item.icon;
        final label = item.label;
        return Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              tab.switchTab(item.id);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  color: selected
                      ? AppTheme.accentColor
                      : Colors.white.withValues(alpha: 0.7),
                  size: 22,
                ),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    color: selected
                        ? AppTheme.accentColor
                        : Colors.white.withValues(alpha: 0.7),
                    fontSize: 10,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}
