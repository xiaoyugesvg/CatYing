import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

import 'package:tvbox/music/pages/music_bottom_chrome.dart';

/// 回归测试：`MusicBottomChrome`（音乐底栏：播放条 + 导航栏）
/// **必须被挂载在 `lib/app.dart` 的全局层**。
///
/// ── 为什么这个测试长这样（真踩过的坑）────────────────────────────
/// `c50ddd1` 那次提交（本意是改阅读体系）把 `lib/app.dart` 回退到了
/// "加音乐底栏之前"的版本（diff 是 `de9ae4b..822003c`）——
/// `MusicBottomChrome` 的 `Positioned(...)` 挂载点**被连带删掉**，
/// 而组件本身、`MusicTabState`、相关代码**全都还在**。
///
/// 结果：组件成了**孤儿** ——
///   · `dart analyze` 0 error（组件和 import 都合法）
///   · 所有单元测试通过（单测是自己手动挂 `MusicBottomChrome` 的）
///   · **但音乐模块里导航栏和播放条都不显示** ✗（用户实测反馈）
///
/// ── 为什么不能"渲染真个 App 再断言"（试过了，不行）────────────────
/// `pumpWidget(const TVBoxApp())` 时 `find.byType(MusicBottomChrome)` = 0，
/// 但**原因不是**挂载点没了：`ContentView.initState` 里
/// `Get.find<TvSearchController>()` / `Get.find<AppState>()`
/// 在单测里没注册（那需要整条 `main()` 启动链）→ home 渲染失败 →
/// 整个 builder 层都没跑。也就是说**测试环境渲染不出真正的 App 树**。
///
/// 所以这类"东西都在、就是没接上"的 bug 只能靠**源码断言**抓（下面第 1 条）。
void main() {
  test('lib/app.dart 必须挂载 MusicBottomChrome（否则音乐底栏全没了）', () {
    final f = File('lib/app.dart');
    expect(f.existsSync(), isTrue,
        reason: '找不到 lib/app.dart —— 这个测试必须在仓库根目录跑');

    // ⚠️ 先去掉注释行再查：否则"注释里提了一嘴"就算通过
    //   （那段注释里 `MusicBottomChrome` 出现了好几遍）
    final code = f
        .readAsLinesSync()
        .where((l) {
          final s = l.trim();
          return !s.startsWith('//') && !s.startsWith('///');
        })
        .join('\n');

    expect(code.contains('MusicBottomChrome()'), isTrue,
        reason: 'lib/app.dart 里**没有** `MusicBottomChrome()` 的挂载 →\n'
            '  音乐模块的导航栏和播放条都不会显示。\n'
            '  这是真踩过的坑（`c50ddd1` 连带删掉了那个 `Positioned`）：\n'
            '  组件、状态、相关代码都还在，就是没人挂它。\n'
            '  修复：在全局 Stack 里加回\n'
            '    const Positioned(left: 0, right: 0, bottom: 0,\n'
            '        child: MusicBottomChrome()),\n'
            '  （与 `MusicFloatingPlayButton` 同层，Navigator 之外）');

    // 挂载点在 `builder:` 那一层（Navigator 之外）——
    // 这样 push 出去的子页面也能看到底栏
    expect(code.contains('builder:'), isTrue,
        reason: 'app.dart 结构变了，这个测试的假设需要重新检查');
  });

  testWidgets('MusicBottomChrome 在"Navigator 之外"这一层能正常渲染', (tester) async {
    // 复刻 `app.dart` 的挂法：`GetMaterialApp.builder` 里贴底挂一条。
    // 目的：万一哪天 `MusicBottomChrome` 改成"依赖某个页面级祖先"，
    // 这个测试会立刻发现 —— 它是**全局层组件**，不能有页面级依赖。
    tester.view.physicalSize = const Size(1284, 2778);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(GetMaterialApp(
      home: const Scaffold(body: Center(child: Text('page'))),
      builder: (context, child) => Stack(
        fit: StackFit.expand,
        alignment: Alignment.topLeft,
        children: [
          child ?? const SizedBox.shrink(),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: MusicBottomChrome(),
          ),
        ],
      ),
    ));
    await tester.pump(const Duration(milliseconds: 60));

    // 不在音乐 tab → 它自己收缩为 0（不占位、不报错）
    expect(find.byType(MusicBottomChrome), findsOneWidget,
        reason: 'MusicBottomChrome 挂在 Navigator 之外这一层应该能渲染');
  });
}
