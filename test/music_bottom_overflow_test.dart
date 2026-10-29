import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/common/module_theme_store.dart';
import 'package:tvbox/music/pages/music_bottom_chrome.dart';
import 'package:tvbox/music/pages/root_view.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/reading/widgets/jelly_nav_bar.dart';
import 'package:tvbox/music/services/route_observer.dart';
import 'package:tvbox/services/main_tab_controller.dart';
import 'package:tvbox/services/nodejs_manager.dart';
import 'package:tvbox/widgets/video_player_pip.dart';

/// 诊断 + 回归：**音乐底栏不能有 RenderFlex 溢出**。
///
/// ── 为什么（用户实测截图）──────────────────────────────────────
/// 用户截图上，导航栏每个标签（主页/乐库/榜单/我的/搜索）文字下面
/// 都有**两条黄线**，而黄线的颜色是
/// **`Color(0xFFFFFF00)` 叠在底色上** —— 那正是 Flutter
/// `RenderFlex` 溢出指示条的专用颜色（`debug_overflow_indicator.dart`）。
///
/// 也就是说：**底栏里有东西溢出了**。
///
/// ⚠️ 溢出指示条本身只在 debug/profile 画，所以这里用
/// **`tester.takeException()`** 抓"有没有 overflow 异常"——
/// 那是 debug 下必现的，能可靠证明溢出存在。
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

  /// 在指定屏幕上渲染底栏，返回渲染期间抛出的异常
  Future<void> pumpAt(WidgetTester tester, Size logical) async {
    tester.view.physicalSize = Size(logical.width * 3, logical.height * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

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

  testWidgets('🔴 导航栏不该溢出（五种典型机型都试）', (tester) async {
    // iPhone SE1 最窄 / SE3 / 14(用户机) / 14 Pro Max 最宽
    const sizes = <String, Size>{
      'iPhone SE1 320×568': Size(320, 568),
      'iPhone SE3 375×667': Size(375, 667),
      'iPhone 14 390×844': Size(390, 844),
      'iPhone 14PM 430×932': Size(430, 932),
      '用户机 428×926': Size(428, 926),
    };

    final failures = <String>[];
    for (final e in sizes.entries) {
      await pumpAt(tester, e.value);
      expect(find.byType(JellyNavBar), findsOneWidget,
          reason: '${e.key}：导航栏该在');

      // 清掉 pump 期间攒下的所有异常，逐个判断是不是 overflow
      final errs = <Object>[];
      for (var ex = tester.takeException(); ex != null;
          ex = tester.takeException()) {
        errs.add(ex);
      }
      for (final err in errs) {
        final s = err.toString();
        if (s.contains('overflowed') || s.contains('RenderFlex')) {
          failures.add('${e.key}: $s');
        }
      }
      // ignore: avoid_print
      print('[probe] ${e.key} → 异常 ${errs.length} 个'
          '${errs.isEmpty ? "" : "（含 overflow: ${errs.where((x) => x.toString().contains("overflow")).length}）"}');
    }

    expect(failures, isEmpty,
        reason: '导航栏/迷你条在下列机型上**溢出了**（就是用户截图里'
            '文字下面那两条黄线的来源）:\n${failures.join("\n\n")}');
  });

  testWidgets('🔴 系统大字号下导航栏标签也不能溢出（黄线来源）', (tester) async {
    // 用户截图里每个标签文字下面都有两条黄线，颜色是
    // Flutter 的 `0xFFFFFF00` 叠在底色上 —— 那是**文字/布局溢出标记**。
    //
    // 而 `JellyNavBar` 的标签是 `maxLines: 1` + `overflow: ellipsis`，
    // 正是 Flutter 会画这种标记的场景。这里把系统字号放大复现。
    final scales = <double>[1.0, 1.15, 1.3, 1.5, 1.8, 2.0];
    final failures = <String>[];

    for (final s in scales) {
      tester.view.physicalSize = const Size(1284, 2778);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      MainTabController.instance.select(MainTabController.musicTabIndex);
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(s)),
          child: MaterialApp(
            navigatorKey: VideoPlayerPip.navigatorKey,
            home: const Scaffold(
              body: Stack(children: [
                MusicRootView(),
                Positioned(
                    left: 0, right: 0, bottom: 0, child: MusicBottomChrome()),
              ]),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 60));
      await shutdownNode(tester);

      final errs = <Object>[];
      for (var ex = tester.takeException(); ex != null;
          ex = tester.takeException()) {
        errs.add(ex);
      }
      final ov = errs.where((x) => x.toString().contains('overflow')).toList();
      // ignore: avoid_print
      print('[probe] 字号 x$s → 异常 ${errs.length}（overflow ${ov.length}）');
      for (final o in ov) {
        failures.add('x$s: ${o.toString().split("\n").first}');
      }
    }

    expect(failures, isEmpty,
        reason: '导航栏/迷你条在**系统大字号**下溢出了（这就是黄线的来源）:\n'
            '${failures.join("\n")}');
  });
}
