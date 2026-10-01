import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'common/theme.dart';
import 'common/constants.dart';
import 'services/app_state.dart';
import 'services/app_log.dart';
import 'services/background_service.dart';
import 'pages/home/view.dart';
import 'pages/shelf/view.dart';
import 'reading/widgets/jelly_nav_bar.dart';
import 'services/nav_feature_service.dart';
import 'pages/live/view.dart';
// cmbok 的 App 骨架入口也叫 HomePage，与影视侧 pages/home/view.dart 的
// HomePage 重名，所以用前缀导入避免歧义。
import 'reading/pages/home_page.dart' as reading_app;
import 'music/pages/root_view.dart';
import 'pages/settings/view.dart';
import 'pages/search/view.dart';
import 'pages/search/controller.dart';
import 'pages/settings/controller.dart';
import 'router/app_pages.dart';
import 'services/detail_page_controller.dart';
import 'services/player_fullscreen_controller.dart';
import 'widgets/video_player_pip.dart';
import 'widgets/disclaimer_dialog.dart';
import 'widgets/app_loading_view.dart';
import 'common/appearance_sync.dart';
import 'common/floating_nav_spec.dart';
import 'common/theme_mode_store.dart';
import 'services/main_tab_controller.dart';

/// 上一次打过的外观签名 —— 用**顶层变量**而不是实例字段：
/// [TVBoxApp] 是 StatelessWidget，不能持有可变状态；
/// 而日志去重本身是"进程级"的（同一时刻只会有一个 App 实例在跑）。
String? _lastAppearanceSig;

class TVBoxApp extends StatelessWidget {
  const TVBoxApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 提前注册全屏状态控制器, 这样详情页 onFullScreenChanged 才能
    // 直接 PlayerFullscreenController.instance.enter/exit 调用.
    Get.put(PlayerFullscreenController(), permanent: true);
    // 全局主 Tab 控制器: 底部悬浮导航选中项全局共享,
    // 详情页也能渲染同样的悬浮栏并切回对应 tab.
    Get.put(MainTabController(), permanent: true);
    // 详情页可见性控制器。
    // ⚠️ 必须在这里**提前注册**：底栏的判断里读 `DetailPageController.instance`，
    // 而 `instance` 是 `Get.find()` —— 没 put 过就抛
    // "DetailPageController not found"。底栏是**每个 tab 页都会构建**的，
    // 所以这个异常会出现在首页，而不是详情页，
    // 排查时会以为是首页的问题。permanent 保证不被自动回收。
    Get.put(DetailPageController(), permanent: true);

    // 外观模式是**唯一来源**（方向已反转：外观主导，背景跟着外观走）。
    // BackgroundService 改变外观时通过回调推给 ThemeModeStore，
    // 避免服务层反向依赖 App 层造成循环依赖。
    final bg = BackgroundService.instance;
    bg.onAppearanceChanged = (isLight) {
      ThemeModeStore.applyLightFromBackground(isLight);
    };
    // 冷启动：直接把持久化的外观模式应用上去
    ThemeModeStore.set(bg.appearanceMode.value == AppearanceMode.light
        ? ThemeMode.light
        : ThemeMode.dark);

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeModeStore.notifier,
      builder: (context, themeMode, _) {
        // 跟随系统：把平台亮度同步给 AppTheme
        final platformLight =
            View.of(context).platformDispatcher.platformBrightness ==
                Brightness.light;
        ThemeModeStore.syncFromPlatform(platformLight);
        // AppTheme 玻璃色等随 isLight 变化，必须监听后整体重建
        return ValueListenableBuilder<bool>(
          valueListenable: ThemeModeStore.brightnessListenable,
          builder: (context, isLightNow, __) {
            // ⚠️ 必须在内层算：外观联动（方案 A）改的是 AppBrightness，
            // 只会触发这一层重建。若在外层算 effectiveLight，外层不重建，
            // MaterialApp.themeMode 会一直用旧值，界面文字颜色不跟着壁纸变。
            final effectiveLight = ThemeModeStore.followBackground
                ? isLightNow
                : (platformLight && themeMode == ThemeMode.system) ||
                    themeMode == ThemeMode.light;
            // ⚠️ 单一真相源：AppTheme 的 textPrimary/backgroundCard 等 getter
            // 读的是 AppBrightness.isLight，而 MaterialApp 用的是 effectiveLight。
            // 两者若不同步，就会出现「背景是浅色、文字却是白色」这类颜色不统一
            // （用户实测截图：皎月白壁纸 + 白字）。
            // 这里在构建前把 AppBrightness 强制对齐到 effectiveLight。
            //
            // ⚠️ 但要先问过 AppearanceSync：在阅读/音乐模块里，明暗该由
            // **那个模块自己的设置**决定。用户实测"阅读的主题跟随系统
            // 不生效"，根因就是 AppBrightness 只被影视这套驱动，
            // 阅读的开关改了 SettingsService 却没人读。
            // sync 会看当前 tab：非影视 tab 用模块设置覆盖这个 target。
            {
              // 用 microtask 避免在 build 中直接改 notifier 触发的重入
              final target = effectiveLight;
              Future<void>.microtask(() {
                AppearanceSync.applyForCurrentModule(
                  videoEffectiveLight: target,
                );
              });
            }
            // ⚠️ 这行原来**每次 build 都打日志**。
            // build 极其频繁（动画/交互/任何 setState 都会触发），
            // 结果是 AppLog 被这行刷屏、日志文件膨胀，而内容和上一次
            // 往往一模一样 —— 排查问题时反而被淹没。
            //
            // 改成**只在明暗真的变化时**打一条（静态字段记住上次的签名）。
            {
              final sig = '$themeMode|$platformLight|'
                  '${ThemeModeStore.followBackground}|$effectiveLight';
              if (sig != _lastAppearanceSig) {
                _lastAppearanceSig = sig;
                AppLog.instance.log(
                    '[Appearance] themeMode=$themeMode platformLight=$platformLight '
                    'followBg=${ThemeModeStore.followBackground} '
                    'isLight(theme)=$isLightNow effectiveLight=$effectiveLight');
              }
            }
            // 全局字号缩放（设置 → 外观 → 界面字号）。
            // #10：字号是外观设置，读 AppTheme.fontScale（ValueNotifier）
            // 而不是 PlayerPrefs —— 后者只是兼容壳。
            // 用 ValueListenableBuilder 监听（ValueNotifier 不能进 Obx）。
            return ValueListenableBuilder<double>(
              valueListenable: AppTheme.fontScale,
              builder: (context, scale, _) {
              // ⚠️ 配色方案版本号必须用 ValueListenableBuilder 监听，
              // **不能**在 Obx 里读 `AppTheme.paletteRevision.value` ——
              // 它是普通 ValueNotifier 而非 GetX observable，
              // Obx 读不到任何 .obs 时会抛
              // "[Get] the improper use of a GetX has been detected"，
              // 整棵子树会被换成 ErrorWidget（也就是大白屏）。
              return ValueListenableBuilder<int>(
                valueListenable: AppTheme.paletteRevision,
                builder: (context, paletteRev, _) => GetMaterialApp(
                title: '猫影',
                theme: AppTheme.lightTheme,
                darkTheme: AppTheme.darkTheme,
                themeMode: effectiveLight ? ThemeMode.light : ThemeMode.dark,
                // 把 NavigatorState 暴露给 VideoPlayerPip，让画中画能插入到顶层 Overlay
                navigatorKey: VideoPlayerPip.navigatorKey,
                // ⚠️ key 必须跟随 exteriorLight 变化：
                // AppTheme 的颜色 getter 读的是 AppBrightness.isLight，不是
                // MaterialApp 的 theme。而 ContentView 是 const 实例 —— 父级重建时
                // Flutter 发现 widget 完全相同就**跳过它的 build**，于是首页里那些
                // 不在 Obx 内的部分（筛选面板、搜索栏等）会一直用旧颜色，
                // 表现为"切了外观但筛选背景没变"。
                // 换 key 强制重建整棵页面树，颜色才会跟着走。
                //
                // paletteRev 同理：切「主题与外观」里的配色方案时，
                // AppTheme 内部换了调色板，但它是静态类不会通知任何人 ——
                // 不把 paletteRevision 拼进 key 就会"选了新配色界面没反应"。
                home: ContentView(
                  key: ValueKey('root-$effectiveLight-$paletteRev'),
                ),
                getPages: AppPages.pages,
                debugShowCheckedModeBanner: false,
                builder: (context, child) {
                  Widget out = child ?? const SizedBox.shrink();
                  if (scale > 0 && (scale - 1.0).abs() >= 0.001) {
                    out = MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(textScaler: TextScaler.linear(scale)),
                      child: out,
                    );
                  }
                  // ⚠️ 再包一层监听外观，并用 key 强制重建：
                  // 弹窗 / 底部弹窗（筛选菜单、布局切换、各设置面板）挂在**根
                  // Overlay** 上，不属于上面被重建的 tab 子树。它们内部的
                  // AppTheme.* 颜色是在打开那一刻取值并缓存的，外观一变就会
                  // 停在旧色（"筛选背景没变"就是这么来的）。
                  // 在 builder 这一层换 key，Overlay 里的内容也会整体重绘。
                  return ValueListenableBuilder<bool>(
                    valueListenable: AppBrightness.isLight,
                    builder: (context, isLight, __) => KeyedSubtree(
                      // paletteRev 也拼进来：配色方案一变，
                      // 连同挂在 Overlay 上的弹窗一起重建。
                      key: ValueKey('appearance-$isLight-$paletteRev'),
                      child: out,
                    ),
                  );
                },
                ),
              );
            });
          },
        );
      },
    );
  }
}
import 'pages/content_view.dart';

