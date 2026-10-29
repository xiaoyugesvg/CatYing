import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/common/floating_nav_spec.dart';
import 'package:tvbox/common/module_theme_store.dart';
import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/pages/music_bottom_chrome.dart';
import 'package:tvbox/music/pages/root_view.dart';
import 'package:tvbox/music/services/player_manager.dart';
import 'package:tvbox/music/services/settings_store.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/music/widgets/mini_player.dart';
import 'package:tvbox/reading/widgets/jelly_nav_bar.dart';
import 'package:tvbox/music/services/route_observer.dart';
import 'package:tvbox/services/main_tab_controller.dart';
import 'package:tvbox/services/nodejs_manager.dart';
import 'package:tvbox/widgets/video_player_pip.dart';

/// **量出**音乐底部两条栏的真实位置（用户截图里它们看着叠在一起）。
///
/// ── 这个测试以前做不出来 ────────────────────────────────────────
/// `MusicPlayerManager._player` 是 `late final Player()`（media_kit），
/// 单元测试环境**没有那个原生库** → 一构造就抛
/// `MediaKit.ensureInitialized must be called`。
/// 于是 `currentSong` 永远是 null → 迷你条自己收缩成 0 高 →
/// **两条栏到底重不重叠，测试里根本量不出来**（我为此卡过一次）。
///
/// 现在用 `MusicPlayerManager.debugSetPlayingForTest` 直接进入
/// "正在播放"状态，绕开原生播放器。
///
/// ── 期望位置（屏幕 926 高）──────────────────────────────────────
///   迷你条   [778, 840]   高 62
///   导航栏   [840, 926]   高 86
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
    await SettingsStore.instance.setBottomBarOnSubPages(true);
  });

  Song testSong() => Song(
        id: 99001,
        name: '布局测试歌',
        artists: '布局测试歌手',
        source: SongSource.qq,
      );

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

  /// 渲染底栏。
  ///
  /// `asRoot` **不再**靠"挂不挂 `MusicRootView`"来模拟 ——
  /// 那个判据（`MusicRootView.isMounted`）是错的：它在 `IndexedStack` 里
  /// **永远为 true**，所以子页面也被当成主页（用户实测反馈的那个 bug）。
  ///
  /// 现在"在不在根页面"看**路由深度**（`MusicRouteObserver`）：
  ///   · `asRoot: true`  → `pushedFrom = 0`（根之上没有东西）
  ///   · `asRoot: false` → `pushedFrom = 1`（模拟 push 了一个子页面）
  ///
  /// ⚠️ 两种情况都**挂上** `MusicRootView` —— 真机上它一直在树里
  ///（`IndexedStack` 不销毁），这样才贴合真实场景。
  Future<void> pumpChrome(WidgetTester tester, {required bool asRoot}) async {
    MusicRouteObserver.pushedFrom.value = asRoot ? 0 : 1;
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

  testWidgets('主页：迷你条在导航栏上方，不能叠在一起', (tester) async {
    tester.view.physicalSize = const Size(1284, 2778);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // 进入"正在播放"（绕开 media_kit）
    MusicPlayerManager.instance.debugSetPlayingForTest(testSong());
    await pumpChrome(tester, asRoot: true);

    final screenH = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final mini = find.byType(MiniPlayer);
    final nav = find.byType(JellyNavBar);

    // ignore: avoid_print
    print('[probe] 迷你条=${mini.evaluate().length} 导航栏=${nav.evaluate().length}');
    expect(mini.evaluate(), isNotEmpty,
        reason: '已经进入"正在播放"，迷你条本应渲染出来');
    expect(nav.evaluate(), isNotEmpty, reason: '主页本应有导航栏');

    final miniRect = tester.getRect(mini);
    final navRect = tester.getRect(nav);
    // ignore: avoid_print
    print('[probe] 屏幕高=$screenH');
    // ignore: avoid_print
    print('[probe] 迷你条 rect=$miniRect  高=${miniRect.height}');
    // ignore: avoid_print
    print('[probe] 导航栏 rect=$navRect  高=${navRect.height}');

    // ① 两条**不能重叠** —— 用户截图反映的现象
    expect(miniRect.bottom, lessThanOrEqualTo(navRect.top + 0.5),
        reason: '迷你条底边(${miniRect.bottom}) 压到导航栏顶边(${navRect.top}) '
            '→ 就是截图里"两条叠在一起"的现象');

    // ② 迷你条高度必须是 62（56 容器 + 6 间隙），不能是 0 或被撑大
    expect(miniRect.height, closeTo(MusicMiniPlayerLayout.totalHeight, 1.5),
        reason: '迷你条高度 ${miniRect.height}，期望 '
            '${MusicMiniPlayerLayout.totalHeight}');

    // ③ 导航栏高度必须是 86（20 下边距 + 66 栏高），且贴底
    expect(navRect.height,
        closeTo(FloatingNavSpec.bottomMargin + FloatingNavSpec.barHeight, 1.5),
        reason: '导航栏高度 ${navRect.height} 不对');
    expect(navRect.bottom, lessThanOrEqualTo(screenH + 0.5),
        reason: '导航栏超出屏幕底部');

    // ④ 迷你条不能跑到屏幕外
    expect(miniRect.top, greaterThan(0));
  });

  testWidgets('子页面：没有导航栏，只有迷你条', (tester) async {
    tester.view.physicalSize = const Size(1284, 2778);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    MusicPlayerManager.instance.debugSetPlayingForTest(testSong());
    // asRoot: false → 模拟 push 出去的子页面
    await pumpChrome(tester, asRoot: false);

    final nav = find.byType(JellyNavBar);
    final mini = find.byType(MiniPlayer);
    // ignore: avoid_print
    print('[probe] 子页面 导航栏=${nav.evaluate().length} '
        '迷你条=${mini.evaluate().length}');

    expect(nav.evaluate(), isEmpty,
        reason: '按用户要求，子页面**不该有导航栏**');
    expect(mini.evaluate(), isNotEmpty,
        reason: '正在播放 + 开关打开 → 子页面应该有迷你条');
  });

  testWidgets('子页面：暂停后迷你条收起来（不播放就不显示）', (tester) async {
    tester.view.physicalSize = const Size(1284, 2778);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // 有歌，但**暂停**
    MusicPlayerManager.instance.debugSetPlayingForTest(testSong(), playing: false);
    await pumpChrome(tester, asRoot: false);

    final mini = find.byType(MiniPlayer);
    final h = mini.evaluate().isEmpty ? 0.0 : tester.getSize(mini).height;
    // ignore: avoid_print
    print('[probe] 子页面 暂停时 迷你条数量=${mini.evaluate().length} 高=$h');

    expect(h, 0,
        reason: '用户要求"播放的时候显示，不播放就不显示" → '
            '暂停时子页面的播放条必须收起来');
  });
}
