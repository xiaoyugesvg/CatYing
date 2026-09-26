import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'common/theme.dart';
import 'models/background_service.dart';
import 'models/app_state.dart';
import 'models/player_fullscreen_controller.dart';
import 'models/main_tab_controller.dart';
import 'pages/home/view.dart';
import 'pages/live/live_view.dart';
import 'pages/history/history_view.dart';
import 'pages/favorites/favorites_view.dart';
import 'pages/settings/view.dart';
import 'pages/search/search_page.dart';
import 'widgets/glass.dart';

/// 主页面 - 对应 Swift ContentView
/// 5 个 tab: 首页 / 直播 / 历史 / 收藏 / 设置
class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  bool _showSearch = false;

  // 5 个 tab 页实例 (IndexedStack 保状态)
  final List<Widget> _tabPages = [
    const HomePage(),
    const LivePage(),
    const HistoryPage(),
    const FavoritesPage(),
    const SettingsPage(),
  ];

  Widget _buildMainTabView() {
    final appState = Get.find<AppState>();

    // 对应 Swift: .sheet(isPresented: $appState.showAboutOnLaunch)
    _handleShowAboutOnLaunch(appState);

    // 悬浮导航栏布局参数:
    // - bottomInset: Home Indicator 安全区（刘海屏/iPad 手势条避让）
    // - 悬浮胶囊离底 8pt, 左右留 32pt
    // - 面板高度 ≈ 内容 35(icon18+3+label14) + 内边距 16 ≈ 51
    final bottomInset = MediaQuery.of(context).padding.bottom;
    const navSideGap = 32.0;
    const navFloatGap = 8.0;
    const navBarHeight = 51.0;
    final navReserve = bottomInset + navFloatGap + navBarHeight + 6.0;

    return Scaffold(
      body: Stack(
        children: [
          // 全局背景层 - 对应 TV-release CustomWallView
          // 4 个内置渐变 + 用户上传自定义图片, 通过 BackgroundService 切换
          // 5 个 tab 页背景透明 (后述) 让其透出
          Positioned.fill(
            child: BackgroundService.instance.buildBackground(overlayAlpha: 0.3),
          ),
          // 5 个 tab 页 (底部预留悬浮导航栏高度, 避免最后一行内容被遮挡)
          // 关键: IndexedStack 的 index 必须包在 Obx 里, 切 tab 才生效
          Padding(
            padding: EdgeInsets.only(bottom: navReserve),
            child: Obx(() => IndexedStack(
                  index: MainTabController.instance.selectedTab.value,
                  children: _tabPages,
                )),
          ),
          // 搜索页 - 对应 Swift .sheet(isPresented: $showSearch)
          if (_showSearch)
            Positioned.fill(
              child: Material(
                // 半透明遮罩, 让 BackgroundService 全局背景层透出
                // (纯黑会盖住玻璃背景层, 搜索页看起来像"死板黑块")
                color: AppTheme.glassTintDeep,
                child: SearchPage(
                  onClose: () {
                    setState(() {
                      _showSearch = false;
                    });
                  },
                ),
              ),
            ),
          // 悬浮导航栏 - 对应 Swift floatingNavBar
          // **2026-07-09**: 全屏时隐藏, 让视频真正铺满屏幕
          // 直播页/详情页 onFullScreenChanged 时调 PlayerFullscreenController
          // .enter/.exit, 这里 Obx 监听后切到 SizedBox.shrink().
          //
          // **关键修复**: 必须放在 body Stack 里而不是 Scaffold 的
          // bottomNavigationBar。Scaffold 会把 body 和 bottomNavigationBar
          // 渲染成上下两个互不重叠的层, BackdropFilter 只能模糊自己下方
          // 已有的内容, bottomNavigationBar 下层只有 Scaffold 纯色背景,
          // 毛玻璃永远透不出 body 里的渐变背景层, 真机上看起来就是
          // "死板半透明深色块"。放进 Stack 后, 面板下方就是全局背景层
          // + 页面内容, 磨砂悬浮效果才真正生效。
          Positioned(
            left: navSideGap,
            right: navSideGap,
            bottom: bottomInset + navFloatGap,
            child: Obx(() {
              if (PlayerFullscreenController.instance.isFullscreen.value) {
                return const SizedBox.shrink();
              }
              // iOS 27 Liquid Glass 悬浮导航条:
              // 真实毛玻璃 (BackdropFilter) + 深色半透明底 + 顶部镜面高光 +
              // 亮描边 + 柔和深投影, 让全局背景层透过形成磨砂观感
              return GlassPanel(
                radius: 30,
                blur: true,
                // **沉浸式底栏**: 用超浅玻璃底 (alpha≈2%) 代替浅玻璃底
                // (alpha≈4%), 只留模糊+描边+高光, 背景几乎全透明,
                // 让全局渐变背景透出, 显示更多内容 (2026-09-26)。
                tint: AppTheme.glassTintClear,
                borderColor: AppTheme.glassBorderSoft,
                borderWidth: 0.8,
                highlightStrength: 0.9,
                shadow: true,
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _navItem(Icons.home_outlined, Icons.home, '首页', 0),
                    _navItem(Icons.tv_outlined, Icons.tv, '直播', 1),
                    _navItem(
                        Icons.schedule_outlined, Icons.schedule, '历史', 2),
                    _navItem(
                        Icons.favorite_border, Icons.favorite, '收藏', 3),
                    _navItem(
                        Icons.settings_outlined, Icons.settings, '设置', 4),
                  ],
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  /// 处理 showAboutOnLaunch - 启动时显示免责声明
  /// 对应 Swift .sheet(isPresented: $appState.showAboutOnLaunch)
  /// 用户可勾选"不再提示", 勾选后持久化到 SharedPreferences
  void _handleShowAboutOnLaunch(AppState appState) {
    if (appState.showAboutOnLaunch.value) {
      appState.showAboutOnLaunch.value = false;
      // 延迟显示，避免在 build 中直接弹窗
      Future.microtask(() {
        if (mounted) {
          _showDisclaimerDialog();
        }
      });
    }
  }

  /// 免责声明弹窗 - 对应 Swift DisclaimerView
  void _showDisclaimerDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          '免责声明',
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 18),
        ),
        content: const Text(
          '本应用仅用于学习和技术研究，所有影视资源均来自第三方接口，'
          '与本应用无关。请遵守当地法律法规，支持正版。',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了', style: TextStyle(color: AppTheme.accentColor)),
          ),
          TextButton(
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('disclaimer_accepted', true);
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('不再提示', style: TextStyle(color: AppTheme.accentColor)),
          ),
        ],
      ),
    );
  }

  Widget _navItem(IconData icon, IconData activeIcon, String label, int index) {
    return Obx(() {
      final selected = MainTabController.instance.selectedTab.value == index;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => MainTabController.instance.switchTab(index),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                selected ? activeIcon : icon,
                size: 20,
                color: selected ? AppTheme.accentColor : AppTheme.textSecondary,
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  color: selected ? AppTheme.accentColor : AppTheme.textSecondary,
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return _buildMainTabView();
  }
}
