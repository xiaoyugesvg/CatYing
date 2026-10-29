import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox/common/floating_nav_spec.dart';
import 'package:tvbox/common/module_theme_store.dart';
import 'package:tvbox/music/pages/root_view.dart';
import 'package:tvbox/music/pages/music_bottom_chrome.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/reading/widgets/jelly_nav_bar.dart';
import 'package:tvbox/music/services/route_observer.dart';
import 'package:tvbox/services/main_tab_controller.dart';
import 'package:tvbox/services/nodejs_manager.dart';

/// 复核用户实测：**音乐模块打开后底部没有悬浮胶囊导航栏**。
///
/// 把 `MusicRootView` 真的渲染出来，检查 `JellyNavBar` 是否存在于树中、
/// 它的尺寸是多少 —— 这比读代码猜要可靠。
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
    // 按 main.dart 的顺序补齐依赖（测试环境没有启动流程）
    MusicPaletteBridge.register(
        () => ModuleThemeStore.instance.paletteFor(ModuleThemeStore.music));
    await ModuleThemeStore.instance.init();
    await MusicThemeStore.instance.init();
    if (!Get.isRegistered<MainTabController>()) {
      Get.put(MainTabController(), permanent: true);
    }
    // ⚠️ 底栏"根页面 vs 子页面"现在看**路由深度**（`MusicRouteObserver`），
    //    单例状态会跨测试残留 → 每个测试复位成"只有根路由"
    MusicRouteObserver.resetForTest();
    // 每个测试从"播放器关着"开始
  });

  // 渲染 `MusicRootView` 会在 `initState` 里预热 Node（`_warmUp`）——
  // 测试环境会真的 bind 一个本地 HTTP server，其 `idleTimeout`（2 分钟
  // 周期定时器）会让 flutter_test 报 "A Timer is still pending"。
  // `tearDown` 太晚（校验在它之前跑），必须在用例体里等 bind 完再停。
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

  // 底栏（迷你条 + 导航栏）在 `MusicRootView` 自己内部 ——
  // 曾经移出去过（挂到全局层覆盖子页面），后来按用户要求**还原**了。
  // 所以这两个测试**直接渲染 `MusicRootView`** 就能查到导航栏。
  Future<void> pumpRoot(WidgetTester tester) async {
    MainTabController.instance.select(MainTabController.musicTabIndex);
    // ── ⚠️ 导航栏**不在 `MusicRootView` 里** ─────────────────────────
    // 它在 `MusicBottomChrome` 中，由 `app.dart` 的全局 Stack 挂载
    //（覆盖所有路由）。所以这里要**同时**渲染两者 ——
    // 这正是真机 `app.dart` 的组合方式。
    //
    // 而且必须让 `MusicRootView` 真的挂上：全局底栏靠
    // **路由深度**判断"在不在根页面"，从而决定画不画导航栏
  //（原来用的是 `MusicRootView.isMounted`，它在 IndexedStack 里永远为 true）。
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          MusicRootView(),
          Positioned(left: 0, right: 0, bottom: 0, child: MusicBottomChrome()),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await shutdownNode(tester);
  }

  testWidgets('主页应该渲染出 JellyNavBar（悬浮导航栏）', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await pumpRoot(tester);

    // 1) 导航栏组件是否在树里
    final navFinder = find.byType(JellyNavBar);
    // ignore: avoid_print
    print('[probe] JellyNavBar 数量 = ${navFinder.evaluate().length}');

    if (navFinder.evaluate().isEmpty) {
      fail('主页没有 JellyNavBar —— 用户截图"底部无导航栏"属实');
    }

    // 2) 它的实际尺寸（0 高 = 存在但看不见）
    final size = tester.getSize(navFinder);
    // ignore: avoid_print
    print('[probe] JellyNavBar 尺寸 = $size');

    expect(size.height, greaterThan(0), reason: '导航栏高度为 0 → 存在但不可见');
    expect(size.height, greaterThanOrEqualTo(FloatingNavSpec.barHeight),
        reason: '导航栏高度应至少 ${FloatingNavSpec.barHeight}');

    // 3) 它的位置是否在屏幕内（bottom 不能在屏幕外）
    final rect = tester.getRect(navFinder);
    final screenH = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    // ignore: avoid_print
    print('[probe] JellyNavBar rect = $rect  屏幕高=$screenH');
    expect(rect.bottom, lessThanOrEqualTo(screenH + 1),
        reason: '导航栏底边超出屏幕 → 被挤到屏幕外看不见');
    expect(rect.top, greaterThan(0), reason: '导航栏顶边在屏幕上方之外');
  });

  testWidgets('主页：5 个 tab 项都在导航栏里', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await pumpRoot(tester);

    // ⚠️ 2026 改动：`音乐库` → `乐库`、新增 `榜单`、
    //    并把「搜索」挪到「我的」右边（用户要求）。
    for (final label in ['主页', '乐库', '榜单', '我的', '搜索']) {
      expect(find.text(label), findsWidgets,
          reason: '导航栏应显示「$label」文字标签');
    }
  });

  testWidgets('音乐页面背景透明（透出全局壁纸，与阅读模块一致）',
      (tester) async {
    // ── ⚠️ 这条断言在"三模块视觉统一"后**反转了** ──────────────────
    //
    // 原来它断言"音乐页必须有不透明背景"，理由是防止全局壁纸层透上来
    // 冲淡整页。但那个"灰蒙蒙"的真正原因是**别的**：
    //   · 子页被跳过 build，文字停在旧值（白字浅底）
    //   · 浅色模式误用了黑遮罩
    // 这两个都已在别处修好（见 static_theme_stale_test.dart 与
    // background_service 的 overlayColor）。
    //
    // 统一后的契约改为：**页面透明、透出壁纸** ——
    // 阅读侧 41 处页面 Scaffold 都是 `Colors.transparent`，
    // 影视的首页/史藏/设置本来也是透明。音乐原来不透明，
    // 于是"同一个人机界面，一半透壁纸一半不透"，观感像两个 App。
    // ── ⚠️ 导航栏**不在 `MusicRootView` 里** ─────────────────────────
    // 它在 `MusicBottomChrome` 中，由 `app.dart` 的全局 Stack 挂载
    //（覆盖所有路由）。所以这里要**同时**渲染两者 ——
    // 这正是真机 `app.dart` 的组合方式。
    //
    // 而且必须让 `MusicRootView` 真的挂上：全局底栏靠
    // **路由深度**判断"在不在根页面"，从而决定画不画导航栏
  //（原来用的是 `MusicRootView.isMounted`，它在 IndexedStack 里永远为 true）。
    // ⚠️ 这里**只渲染 `MusicRootView`**：本测试只验"音乐页底色透明"，
    //    不涉及导航栏，所以不需要那份全局底栏。
    //
    // ⚠️ 而且**不能**在外面再包一层 `Scaffold`：下面断言的是
    //    "**所有** Scaffold 都透明"，而测试外壳的 `Scaffold` 默认不透明
    //   （`Material` 的默认底色）→ 会把这个断言弄挂。那是**测错了**，
    //    不是产品代码的问题。
    await tester.pumpWidget(const MaterialApp(home: MusicRootView()));
    await tester.pump(const Duration(milliseconds: 100));
    await shutdownNode(tester);

    final scaffolds = tester.widgetList<Scaffold>(find.byType(Scaffold));
    expect(scaffolds, isNotEmpty, reason: '至少要有一个 Scaffold');
    final allTransparent =
        scaffolds.every((s) => (s.backgroundColor?.a ?? 1.0) < 0.01);
    expect(allTransparent, isTrue,
        reason: '音乐页面底应当透明，让全局壁纸层透出来（与阅读一致）。'
            '若这里不透明，音乐 tab 会完全盖住壁纸，与阅读/首页观感割裂。');
  });
}
