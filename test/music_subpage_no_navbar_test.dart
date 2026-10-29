import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/common/module_theme_store.dart';
import 'package:tvbox/music/pages/music_bottom_chrome.dart';
import 'package:tvbox/music/pages/root_view.dart';
import 'package:tvbox/music/services/route_observer.dart';
import 'package:tvbox/music/services/settings_store.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/reading/widgets/jelly_nav_bar.dart';
import 'package:tvbox/services/main_tab_controller.dart';
import 'package:tvbox/services/nodejs_manager.dart';
import 'package:tvbox/widgets/video_player_pip.dart';

/// 回归测试：**子页面不能有悬浮导航栏**（用户实测反馈的核心问题）。
///
/// ── 用户原话 ────────────────────────────────────────────────────
/// 「我关闭了子页面有悬浮导航栏，结果也还是不行呢？」
///（设置里那个「子页面显示播放条」开关关了，子页面**照样有导航栏**）
///
/// ── 根因 ────────────────────────────────────────────────────────
/// 判断"根页面 vs 子页面"的判据原来是
/// **`MusicRootView.isMounted`** —— 而它**永远为 true** ✗：
/// `MusicRootView` 挂在 `ContentView` 的 `IndexedStack` 里，
/// `IndexedStack` 让**所有**子页保持挂载 → push 子页面时根视图仍在树里
/// → `dispose` 永远不调用 → 标记永远 true → **子页面被当成主页** → 导航栏照画。
///
/// ── 修法 ────────────────────────────────────────────────────────
/// 改用 `MusicRouteObserver`（`NavigatorObserver`）读**导航器真实的路由栈深度**：
/// 深度 1 = 在根页面；> 1 = 有子页面被 push 上来。
///
/// ⚠️ 这个测试**必须**覆盖"路由深度 > 1"这一侧 ——
///    之前所有测试都只测了根页面，所以那个 bug 全都没抓到。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // `MusicRootView` 预热 Node 时会读 Documents 目录；测试环境没有
    // path_provider 实现 → 抛 MissingPluginException（未被捕获 → 用例失败）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => Directory.systemTemp.path,
    );
    MusicPaletteBridge.register(
        () => ModuleThemeStore.instance.paletteFor(ModuleThemeStore.music));
    await ModuleThemeStore.instance.init();
    await MusicThemeStore.instance.init();
    MusicRouteObserver.resetForTest();
    if (!Get.isRegistered<MainTabController>()) {
      Get.put(MainTabController(), permanent: true);
    }
    await SettingsStore.instance.setBottomBarOnSubPages(true);
  });

  tearDown(() => MusicRouteObserver.resetForTest());

  /// 渲染 `MusicRootView` 会在 `initState` 里预热 Node（`_warmUp`）——
  /// 测试环境会真的 bind 一个本地 HTTP server，其 `idleTimeout`（2 分钟
  /// 周期定时器）会让 flutter_test 报 "A Timer is still pending"。
  /// `tearDown` 太晚（校验在它之前跑），必须在用例体里等 bind 完再停。
  Future<void> shutdownNode(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0;
          i < 40 && NodeJSManager.instance.nativeServerPort == 0;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    NodeJSManager.instance.stopNodeJS();
    await tester.pump();
  }

  Future<void> pumpChrome(WidgetTester tester) async {
    MainTabController.instance.select(MainTabController.musicTabIndex);
    await tester.pumpWidget(MaterialApp(
      navigatorKey: VideoPlayerPip.navigatorKey,
      home: const Scaffold(
        body: Stack(children: [
          MusicRootView(),
          Positioned(
              left: 0, right: 0, bottom: 0, child: MusicBottomChrome()),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 60));
    await shutdownNode(tester);
  }

  testWidgets('🔴 路由深度 > 1（有子页面）→ **不许有导航栏**', (tester) async {
    tester.view.physicalSize = const Size(1284, 2778);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await pumpChrome(tester);

    // 根页面：导航栏在（先确认基线，否则下面的断言等于没测）
    expect(find.byType(JellyNavBar), findsOneWidget,
        reason: '路由深度 1 = 根页面，应该有导航栏');

    // 模拟"push 了一个子页面"（`didPush(sub, root)` 会让 pushedFrom +1）
    MusicRouteObserver.debugEnterSubPage();
    await tester.pump(const Duration(milliseconds: 60));

    // ignore: avoid_print
    print('[probe] 子页面 → 导航栏=${find.byType(JellyNavBar).evaluate().length}');

    expect(find.byType(JellyNavBar), findsNothing,
        reason: '在子页面时**不能**有悬浮导航栏 —— '
            '这正是用户反馈的"关闭了子页面浮动导航栏结果还是不行"。\n'
            '检查 `MusicBottomChrome.build` 里的 `onRoot`：\n'
            '它必须读 `MusicRouteObserver.isOnRoot`（路由栈深度），\n'
            '**不能**读 `MusicRootView.isMounted` ——\n'
            '后者在 IndexedStack 里永远为 true。');

    // 回根页面 → 导航栏回来
    MusicRouteObserver.debugBackToRoot();
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byType(JellyNavBar), findsOneWidget,
        reason: '回到根页面后导航栏应该回来');
  });

  testWidgets('🔴 MusicRootView.isMounted **不能**再作为判据（它会永远为 true）',
      (tester) async {
    tester.view.physicalSize = const Size(1284, 2778);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await pumpChrome(tester);

    // 这个测试把"坑为什么这么深"钉下来：
    // `MusicRootView` 挂上后 `isMounted` 就是 true，而且**不会**因为
    // "push 了子页面"而变 false（IndexedStack 不销毁它）。
    expect(MusicRootView.isMounted, isTrue,
        reason: 'MusicRootView 挂在 IndexedStack 里，挂载后一直为 true');

    // 而路由深度**能**正确反映"进子页面"
    MusicRouteObserver.debugEnterSubPage();
    await tester.pump(const Duration(milliseconds: 60));
    expect(MusicRootView.isMounted, isTrue,
        reason: 'push 子页面**不会**让 MusicRootView 变 false —— '
            '所以 `isMounted` 判断"在不在根页面"是错的');
    expect(MusicRouteObserver.isOnRoot, isFalse,
        reason: '路由深度才是对的判据');
    expect(find.byType(JellyNavBar), findsNothing);
  });
}
