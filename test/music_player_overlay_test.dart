import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/common/module_theme_store.dart';
import 'package:tvbox/music/pages/music_bottom_chrome.dart';
import 'package:tvbox/music/pages/player_page.dart';
import 'package:tvbox/music/pages/root_view.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/reading/widgets/jelly_nav_bar.dart';
import 'package:tvbox/music/services/route_observer.dart';
import 'package:tvbox/services/main_tab_controller.dart';
import 'package:tvbox/services/nodejs_manager.dart';
import 'package:tvbox/widgets/video_player_pip.dart';

/// 回归测试：**全屏播放器打开时，全局底栏必须隐藏**。
///
/// ── 为什么（用户实测截图）──────────────────────────────────────
/// `MusicBottomChrome`（迷你条 + 导航栏）挂在 `app.dart` 的 Stack 里、
/// **在 `out`（Navigator）之后** → 盖在**所有**路由之上，包括全屏播放器。
///
/// 而播放器**自己**有一条底部操作栏
///（列表循环 / 收藏 / 上一首 / 歌词 / 下一首 / 设置）——
/// 被迷你条 + 导航栏压在下面，**既看不清也点不到** ✗
/// 而且导航栏出现在播放器上本身语义就不对（该是播放控制，不是切 tab）。
///
/// 修法：`MusicPlayerPage.isOpen` 这个 `ValueNotifier`，
/// `initState` 置 true / `dispose` 置 false，底栏监听它并整个隐藏。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    MusicRouteObserver.resetForTest();
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
    if (!Get.isRegistered<MainTabController>()) {
      Get.put(MainTabController(), permanent: true);
    }
    // 每个测试从"播放器关着"开始
    MusicPlayerPage.isOpen.value = false;
  });

  tearDown(() {
    MusicPlayerPage.isOpen.value = false;
  });

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

  testWidgets('播放器关着 → 底栏正常显示（导航栏在）', (tester) async {
    tester.view.physicalSize = const Size(1284, 2778);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await pumpChrome(tester);
    expect(find.byType(JellyNavBar), findsOneWidget,
        reason: '播放器没开，主页应该有导航栏');
  });

  testWidgets('🔴 播放器打开 → 底栏整个隐藏（否则盖住播放器的操作栏）',
      (tester) async {
    tester.view.physicalSize = const Size(1284, 2778);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await pumpChrome(tester);
    // 先确认它本来是显示的（否则下面的断言等于没测）
    expect(find.byType(JellyNavBar), findsOneWidget);

    // 模拟"播放器被打开"
    MusicPlayerPage.isOpen.value = true;
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.byType(JellyNavBar), findsNothing,
        reason: '播放器开着时全局底栏必须隐藏 —— 否则它的迷你条 + 导航栏'
            '会盖住播放器自己的底部操作栏'
            '（列表循环 / 收藏 / 上一首 / 歌词 / 下一首 / 设置），'
            '用户看不清也点不到。检查 `MusicBottomChrome.build` 里那句 '
            '`if (MusicPlayerPage.isOpen.value) return const SizedBox.shrink();`');

    // 关掉播放器 → 恢复
    MusicPlayerPage.isOpen.value = false;
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.byType(JellyNavBar), findsOneWidget,
        reason: '关掉播放器后底栏应该回来');
  });
}
