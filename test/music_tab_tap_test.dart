import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/common/module_theme_store.dart';
import 'package:tvbox/music/pages/discover_page.dart';
import 'package:tvbox/music/pages/search_page.dart';
import 'package:tvbox/music/pages/root_view.dart';
import 'package:tvbox/music/pages/music_bottom_chrome.dart';
import 'package:tvbox/widgets/video_player_pip.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/reading/widgets/jelly_nav_bar.dart';
import 'package:tvbox/music/services/route_observer.dart';
import 'package:tvbox/services/main_tab_controller.dart';
import 'package:tvbox/services/nodejs_manager.dart';

/// 复现用户报的「**主页导航栏点不了**」。
///
/// 做法：真的把 `MusicRootView` 渲出来，**逐个点** 5 个 tab，
/// 每点一次就检查对应的页面有没有真的显示出来。
///
/// 如果某一步没变化，就把当时的 `IndexedStack.index` 打出来 ——
/// 这样能区分"点击没传进去"和"index 变了但没重建"。
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

  /// 当前 `IndexedStack` 的 index（拿不到就从可见页反推）
  int? currentIndex(WidgetTester tester) {
    final s = tester.widgetList<IndexedStack>(find.byType(IndexedStack));
    if (s.isEmpty) return null;
    return s.first.index;
  }

  testWidgets('🔴 逐个点 5 个 tab —— 主页导航栏必须真的能切', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    MainTabController.instance.select(MainTabController.musicTabIndex);
    // ⚠️ 导航栏**不在 `MusicRootView` 里** —— 它在 `MusicBottomChrome`，
    // 由 `app.dart` 的全局 Stack 挂载。所以这里渲染**真机的组合**：
    //   · `MusicRootView` 必须在（它一挂载就把 `isMounted` 置 true，
    //     全局底栏据此才画导航栏）
    //   · `MusicBottomChrome` 贴底挂一份
    //
    // ⚠️ `MusicBottomChrome` 内部用 `VideoPlayerPip.navigatorKey`
    //（真机由 `main.dart` 注入）。测试环境没有启动流程 →
    // 把它接到 `MaterialApp.navigatorKey` 上，这样
    // "切 tab 前先 popUntil" 那条路径在测试里也真的能走通。
    await tester.pumpWidget(MaterialApp(
      navigatorKey: VideoPlayerPip.navigatorKey,
      home: const Scaffold(
        body: Stack(children: [
          MusicRootView(),
          Positioned(left: 0, right: 0, bottom: 0, child: MusicBottomChrome()),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await shutdownNode(tester);

    final nav = find.byType(JellyNavBar);
    // ignore: avoid_print
    print('[probe] JellyNavBar 数量=${nav.evaluate().length}');
    if (nav.evaluate().isEmpty) fail('主页没有导航栏，无从点击');
    // ignore: avoid_print
    print('[probe] 初始 IndexedStack.index=${currentIndex(tester)}');

    // 期望：点第 i 个 → IndexedStack.index 变成 i，且对应页面可见
    // ⚠️ 顺序必须与 `musicTabs` 一致（用户要求「搜索」在「我的」右边）
    const labels = ['主页', '乐库', '榜单', '我的', '搜索'];
    for (var i = 0; i < labels.length; i++) {
      // 找到导航栏里那个 label 的可点区域
      final target = find.descendant(
        of: nav,
        matching: find.text(labels[i]),
      );
      if (target.evaluate().isEmpty) {
        fail('导航栏里找不到「${labels[i]}」—— 标签没渲染出来');
      }
      await tester.tap(target.first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 350));

      final idx = currentIndex(tester);
      // ignore: avoid_print
      print('[probe] 点「${labels[i]}」→ IndexedStack.index=$idx');

      expect(idx, i,
          reason: '点「${labels[i]}」之后 IndexedStack.index 应该是 $i，'
              '实际 $idx → 这一下"没反应"');
    }

    // 再确认页面真的换了（不是只有 index 变）
    // ⚠️ 循环最后停在的 tab 变了：新顺序里最后一项是「搜索」（索引 4）
    expect(find.byType(SearchPage), findsOneWidget,
        reason: '最后停在「搜索」，SearchPage 应该在树里');
  });

  testWidgets('点「乐库」「榜单」→ 对应页面成为可见那个', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    MainTabController.instance.select(MainTabController.musicTabIndex);
    // ⚠️ 导航栏**不在 `MusicRootView` 里** —— 它在 `MusicBottomChrome`，
    // 由 `app.dart` 的全局 Stack 挂载。所以这里渲染**真机的组合**：
    //   · `MusicRootView` 必须在（它一挂载就把 `isMounted` 置 true，
    //     全局底栏据此才画导航栏）
    //   · `MusicBottomChrome` 贴底挂一份
    //
    // ⚠️ `MusicBottomChrome` 内部用 `VideoPlayerPip.navigatorKey`
    //（真机由 `main.dart` 注入）。测试环境没有启动流程 →
    // 把它接到 `MaterialApp.navigatorKey` 上。
    await tester.pumpWidget(MaterialApp(
      navigatorKey: VideoPlayerPip.navigatorKey,
      home: const Scaffold(
        body: Stack(children: [
          MusicRootView(),
          Positioned(left: 0, right: 0, bottom: 0, child: MusicBottomChrome()),
        ]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await shutdownNode(tester);

    final nav = find.byType(JellyNavBar);
    for (final entry in [
      // ⚠️ 索引跟着 `musicTabs` 的新顺序走
      ('乐库', 1),
      ('榜单', 2),
      ('我的', 3),
      ('搜索', 4),
      ('主页', 0),
    ]) {
      final t = find.descendant(of: nav, matching: find.text(entry.$1));
      await tester.tap(t.first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 350));
      // ignore: avoid_print
      print('[probe] 「${entry.$1}」→ index=${currentIndex(tester)} '
          '(期望 ${entry.$2})');
      expect(currentIndex(tester), entry.$2);
    }

    // 最后停在「主页」→ 应该看到 `DiscoverPage`。
    //
    // ⚠️ **不能**断言"四个页面都在树里"：`IndexedStack` 用
    //    `StackFit` 但只 **build 当前 index 那个子页**（其余保持
    //    element 存活但不在渲染树里可查）。原来那条断言是我写错的。
    expect(find.byType(DiscoverPage), findsOneWidget,
        reason: '回到「主页」后应看到 DiscoverPage');
  });

  testWidgets('🔴 全局 navigatorKey 真的能 push（播放条/导航栏都靠它）',
      (tester) async {
    // ── 这个测试钉住的是**本次修复的地基** ──────────────────────
    // `MusicBottomChrome` 挂在 `app.dart` 的 Stack 里、**Navigator 子树
    // 之外** → 它的 `context` 祖先链里没有 Navigator，
    // `Navigator.of(context)` 会抛 → 导航栏点了没反应、播放条进不了播放器。
    //
    // 所以它必须走全局 `VideoPlayerPip.navigatorKey`
    //（与 `floating_play_button.dart` / `AppToast` 同一约定）。
    // 这里验证"把那个 key 接到 MaterialApp 上之后，push 真的能用"。
    await tester.pumpWidget(MaterialApp(
      navigatorKey: VideoPlayerPip.navigatorKey,
      home: const Scaffold(body: Center(child: Text('home'))),
    ));
    await tester.pump();

    // 模拟 `_openPlayerFromGlobalKey` 做的事
    final nav = VideoPlayerPip.navigatorKey.currentState;
    expect(nav, isNotNull,
        reason: '全局 navigatorKey 没接到 MaterialApp 上 → '
            '`currentState` 为 null → 播放条点了什么都不会发生');
    nav!.push<void>(MaterialPageRoute(
      builder: (_) => const Scaffold(body: Center(child: Text('player'))),
    ));
    await tester.pumpAndSettle();

    expect(find.text('player'), findsOneWidget,
        reason: '通过全局 navigatorKey push 的路由没显示出来');
    expect(find.text('home'), findsNothing);
  });
}
