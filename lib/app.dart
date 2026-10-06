import 'dart:io';

// ⚠️ `kIsWeb` 在 **`foundation.dart`** ✓ —— 我原以为 `material.dart` 会一并导出 ✗
//（实测报 `Undefined name 'kIsWeb'` ✗ ⇒ `error=1` ✓）⇒ 必须显式导入 ✓
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'music/widgets/floating_play_button.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'common/theme.dart';
import 'services/app_log.dart';
import 'services/background_service.dart';
import 'router/app_pages.dart';
import 'services/detail_page_controller.dart';
import 'services/player_fullscreen_controller.dart';
import 'widgets/video_player_pip.dart';
import 'common/appearance_sync.dart';
import 'common/theme_mode_store.dart';
import 'services/main_tab_controller.dart';
import 'pages/content_view.dart';
// ✅ **隐藏 WebView 的挂载点**（本轮 ✓）—— 见下方根 builder 里的说明 ✓
import 'reading/source/webview_image_fetcher.dart';

/// 上一次打过的外观签名 —— 用**顶层变量**而不是实例字段：
/// 日志去重本身是"进程级"的（同一时刻只会有一个 App 实例在跑）。
String? _lastAppearanceSig;

class TVBoxApp extends StatefulWidget {
  const TVBoxApp({super.key});

  @override
  State<TVBoxApp> createState() => _TVBoxAppState();
}

/// ⚠️ 为什么是 StatefulWidget 而不是 StatelessWidget：
///
/// 本 widget 是 `runApp` 的根，位于 `WidgetsApp` / `MediaQuery` **之上**。
/// 系统亮暗变化时 Flutter 只会重建 `MediaQuery` 以下的子树，
/// **不会**重跑根 widget 的 build —— 而"跟随系统"恰恰要靠 build 里读一次
/// `platformBrightness` 来决定明暗。原来这里是 StatelessWidget，
/// 于是用户选「跟随系统」后，在系统设置里切深色**界面不会变**，
/// 必须重启 App 才生效。
/// 现在实现 [WidgetsBindingObserver.didChangePlatformBrightness] 并 setState，
/// 系统亮暗一变就重算整棵外观链。
class _TVBoxAppState extends State<TVBoxApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();

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

    // 外观协调：必须在 MainTabController 注册之后（start 里读它判断当前 tab）。
    // 原来这行在 `main()` 里，那时 MainTabController 还没注册，
    // `start()` 直接在守卫处 return —— 阅读侧的明暗监听从未生效。
    AppearanceSync.start();

    // 系统亮暗变化（「跟随系统」模式要用）
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    // 只需触发重建：build 里会现读 platformBrightness，
    // 再经 ThemeModeStore.syncFromPlatform + AppearanceSync 落地。
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
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
            // ⚠️ 明暗的**唯一**真源就是 `AppBrightness.isLight`（= isLightNow）。
            //
            // 不要在这里另外拿 `themeMode` + `platformLight` 再算一遍：
            // `platformLight` 是外层 builder 捕获的，只在 [ThemeModeStore]
            // 变化时刷新；系统亮度变化只改 `AppBrightness`，外层不会重建，
            // 于是算出来的 effectiveLight 会是**过期值**，导致
            // "MaterialApp 用旧主题、AppTheme 取色用新值"这种自相矛盾
            //（用户实测截图：皎月白壁纸 + 白字）。
            //
            // 现在 `AppBrightness` 由三处共同维护、且都写同一个值：
            //   · `ThemeModeStore.set/load`      → `_syncBrightness`
            //   · `ThemeModeStore.syncFromPlatform`（system 模式，上面刚调过）
            //   · `AppearanceSync.applyForCurrentModule`（下面的微任务兜底）
            final effectiveLight = isLightNow;

            // 兜底再对齐一次（微任务，避免在 build 中直接改 notifier 触发重入）
            {
              final target = effectiveLight;
              Future<void>.microtask(() {
                AppearanceSync.applyForCurrentModule(
                  videoEffectiveLight: target,
                );
              });
            }
            // 只在明暗真的变化时打一条日志（build 极其频繁，全打会刷屏）
            {
              final sig = '$themeMode|$platformLight|$effectiveLight';
              if (sig != _lastAppearanceSig) {
                _lastAppearanceSig = sig;
                AppLog.instance.log(
                    '[Appearance] themeMode=$themeMode platformLight=$platformLight '
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
                // iOS 风格转场：所有 Get 路由右滑进入 / 左滑返回（丝滑不僵硬）
                defaultTransition: Transition.cupertino,
                transitionDuration: const Duration(milliseconds: 320),
                // 把 NavigatorState 暴露给 VideoPlayerPip，让画中画能插入到顶层 Overlay
                navigatorKey: VideoPlayerPip.navigatorKey,
                // ── ⚠️ 这里原来会**换 key 销毁重建整个 ContentView** ──────
                //
                //   key: ValueKey('root-$effectiveLight-$paletteRev')
                //
                // 理由（旧注释）是：`AppTheme` 是静态类，颜色 getter 读
                // `AppBrightness.isLight` / `_palette`，改了**不通知任何 widget**；
                // 而 `ContentView` 是 const 实例，父级重建时 Flutter 判定
                // "widget 完全相同"会**跳过它的 build**，于是首页里那些不在
                // Obx 内的部分一直用旧颜色（"切了外观但筛选背景没变"）。
                //
                // 但**代价太大**：换 key 会把 `ContentView` 连同它下面
                // 5 个 tab 页**整体销毁重建**（用户实测"主题切换卡顿"）。
                //
                // 现在改成**收窄到真正需要变色的地方**（见 `content_view.dart`）：
                //   · `IndexedStack` 的 key 拼了 `isLight + paletteRev`
                //   · 底部悬浮栏自己监听 `paletteRevision` 并换 key
                //   · 搜索浮层 key 拼了 `isLight`
                // 这三处覆盖了 `ContentView` 里所有读 `AppTheme` 的地方，
                // 所以外层**不再需要**换 key。
                //
                // ⚠️ 若将来在 `content_view.dart` 的 IndexedStack/悬浮栏
                // **之外**新增读 `AppTheme` 的 widget，记得也给它加监听/换 key，
                // 否则它会停在旧色。
                home: const ContentView(),
                getPages: AppPages.pages,
                debugShowCheckedModeBanner: false,
                builder: (context, child) {
                  Widget out = child ?? const SizedBox.shrink();
                  // ✅ **把 1px 隐藏 WebView 挂到根 Stack**（本轮修复 ✓ 关键 ✓）
                  //
                  // 依据 ✓：`webview_image_fetcher.dart:11` 的设计原文就是
                  //   「全局单例：持 WebViewController，通过 **buildHiddenWebView()**
                  //     在**根 Stack** 挂 1px 隐藏 WebView」✓
                  // 而实测 ✗：**全仓库没有任何地方调用 `buildHiddenWebView()`** ✗
                  //   （只有 `:11` 注释 ✓ 与 `:83` 定义 ✓）
                  //   ⇒ 于是所有依赖它的能力**实际是死的** ✗✓：
                  //     · 配置了 `use_webview_fetch` 的**漫画源** ✗
                  //     · 书源里写 `{"webView":true}` 的源 ✗（Legado 常见 ✓）
                  //     · 引擎报的「该源的搜索需要浏览器内核（webView），当前不支持」✗
                  //   ⇒ 挂上之后才能真的拿到"**渲染后的 HTML**" ✓（真浏览器栈 ✓
                  //     反爬 / Cloudflare 挑战 / JS 渲染站能过 ✓）
                  //
                  // ⚠️ **桌面端必须跳过** ✓：`webview_image_fetcher.dart:54` 明确写了
                  //   「桌面端无对应 WebViewPlatform，构造 `WebViewController` 会触发断言 ✗」
                  //   ⇒ 只在 iOS / Android 挂 ✓（`kIsWeb` 由 `material.dart` 一并导出 ✓）
                  //
                  // ℹ️ 只有 1px 且在最上层 ✓（原设计如此 ✓）⇒ **不影响任何交互与观感** ✓
                  if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
                    out = Stack(
                      children: [out, WebViewImageFetcher().buildHiddenWebView()],
                    );
                  }
                  if (scale > 0 && (scale - 1.0).abs() >= 0.001) {
                    out = MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(textScaler: TextScaler.linear(scale)),
                      child: out,
                    );
                  }
                  // ── ⚠️ 这里原来会换 key 强制重建整棵树 ──────────────────
                  //
                  //   KeyedSubtree(key: ValueKey('appearance-$isLight-$paletteRev'))
                  //
                  // 当时的理由是"弹窗 / 底部弹窗挂在根 Overlay 上，它们内部的
                  // AppTheme.* 颜色是在打开那一刻取值并缓存的，外观一变就会
                  // 停在旧色（筛选背景没变）"。
                  //
                  // 但 `child` 就是**根 Navigator** —— 换 key 会把整个路由栈
                  // 连同下面 7 个 tab 页的 State 全部销毁重建。这正是
                  // "主题切换卡顿"和"在阅读里切个明暗就跳回默认首页"
                  // （tab 状态丢失）的根因。
                  //
                  // 现在改为依赖两条**非破坏性**的传播路径：
                  //   1. `theme` / `themeMode` 变化 → Material 的 `Theme`
                  //      InheritedWidget 通知所有 `Theme.of(context)` 依赖者重建
                  //      （对话框/底部弹窗里的 Material 部件都属于此类）；
                  //   2. `content_view.dart` 在明暗/配色变化时构造**新的**
                  //      tab 页实例 → 子页 rebuild 而 Element/State 复用。
                  //
                  // 残留（已知）：若某个**已经打开**的弹窗内部显式写了
                  // `AppTheme.xxx` 且完全不依赖 `Theme.of`，外观变化后它会停在
                  // 旧色，重新打开即正常。要彻底消除需要把 `AppTheme.*` 静态取色
                  // 迁到 `Theme.of(context)` —— 那是全工程级重构。
                  // ── 全局壁纸层必须在 Navigator **之上** ────────────────────
                  //
                  // 🔴 原来这一层画在 `ContentView` 内部（它是 `home`，也就是
                  // Navigator 的**第一条路由**）。而 `MaterialPageRoute` 是
                  // **opaque** 的 —— 路由转场结束后 Flutter 只绘制最上层路由，
                  // 下面那条（ContentView）根本不会被绘制。
                  //
                  // 后果：所有 `Get.to(...)` 推入的页面（设置子页、阅读阅读器、
                  // 数据源/播放器/弹幕/元数据/缓存/关于…）的 Scaffold 都是
                  // `Colors.transparent`（见 `settings_shared.dart` 的说明），
                  // 它们**谁也透不到壁纸**，于是整页渲染成**纯黑**
                  // （用户实测截图：设置主页面是灰的，点进去的子页全黑）。
                  //
                  // 放到这里之后：壁纸在 Navigator 之下、所有路由之上，
                  // 任何透明 Scaffold 都能透出它，深浅两套场景也由
                  // `BackgroundService` 按 `AppBrightness` 自动选。
                  return Stack(
                    fit: StackFit.expand,
                    // 用非方向性的 Alignment：避免依赖 Directionality
                    //（builder 这一层的位置在各 Flutter 版本间略有差异）
                    alignment: Alignment.topLeft,
                    children: [
                      BackgroundService.instance.buildBackground(
                        overlayAlpha: 0.3,
                      ),
                      out,
                      // ── 悬浮播放球（方案 C）──────────────────────────
                      // 可拖动、点击进播放页；没有在播的歌时它自己隐藏。
                      // 挂在这一层 → **一处挂载覆盖所有路由**（含 push 出去的
                      // 歌单详情/喜马拉雅专辑/本地音乐，那些页面**没有**迷你
                      // 播放器，所以以前"点歌后除了声音没有任何反馈"）。
                      const MusicFloatingPlayButton(),
                    ],
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
