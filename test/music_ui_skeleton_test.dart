import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/music/widgets/music_components.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';

/// 音乐模块「页面骨架」三件套的回归测试（2026-10-30）。
///
/// 背景：用户要求「音乐按你设计的 UI 界面，优化美化每一个分类界面」。
/// 做法是把设计稿（outputs/music_ui/「墨律」）里每页顶部的
/// 「大标题 + 副标题 + 右侧动作」、乐库的统计格、卡片式导航行
/// 抽成三个组件，各页统一换上去。
///
/// 这三条测试锁住的是**容易被后续改动破坏的几何约束**：
///   · 统计格必须等分（2 个两等分、3 个三等分、4 个四等分）——
///     这是用户对「源切换按钮」提过的同一条规则，不能一个宽一个窄；
///   · 标题区必须给副标题和动作留位置（不能溢出）；
///   · 导航行必须是圆角卡片，不是裸 ListTile。
void main() {
  setUpAll(() {
    // MusicTheme 的所有颜色都要经过这个桥接（见 music_theme.dart 的断言）。
    // 生产环境在 main.dart 启动时注册，测试里必须自己注册一次。
    MusicPaletteBridge.register(() => const JellyPalette.ink());
  });

  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 390, child: child),
        ),
      );

  group('MusicStatRow', () {
    for (final n in [2, 3, 4]) {
      testWidgets('$n 个统计格等分', (tester) async {
        await tester.pumpWidget(wrap(
          MusicStatRow(
            stats: [
              for (var i = 0; i < n; i++)
                MusicStat(value: '${(i + 1) * 10}', label: '标签$i'),
            ],
          ),
        ));
        final widths = tester
            .widgetList<Expanded>(find.descendant(
              of: find.byType(MusicStatRow),
              matching: find.byType(Expanded),
            ))
            .map((e) => tester.getSize(find.byWidget(e)).width)
            .toList();
        expect(widths.length, n);
        final first = widths.first;
        for (final w in widths) {
          expect(w, closeTo(first, 0.5), reason: '$n 等分时出现了不等宽格子');
        }
      });
    }

    testWidgets('空列表不占位', (tester) async {
      await tester.pumpWidget(wrap(const MusicStatRow(stats: [])));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('数值与标签都渲染出来', (tester) async {
      await tester.pumpWidget(wrap(
        const MusicStatRow(stats: [MusicStat(value: '128', label: '收藏')]),
      ));
      expect(find.text('128'), findsOneWidget);
      expect(find.text('收藏'), findsOneWidget);
    });
  });

  group('MusicPageHeader', () {
    testWidgets('标题 + 副标题 + 右侧动作同时存在时不溢出', (tester) async {
      await tester.pumpWidget(wrap(
        MusicPageHeader(
          title: '乐库',
          subtitle: '全部存在本机 · 不需要账号',
          action: TextButton(onPressed: () {}, child: const Text('编辑')),
        ),
      ));
      expect(tester.takeException(), isNull);
      expect(find.text('乐库'), findsOneWidget);
      expect(find.text('全部存在本机 · 不需要账号'), findsOneWidget);
      expect(find.text('编辑'), findsOneWidget);
    });

    testWidgets('没有副标题时只占一行', (tester) async {
      await tester.pumpWidget(wrap(const MusicPageHeader(title: '榜单')));
      expect(tester.takeException(), isNull);
      expect(find.text('榜单'), findsOneWidget);
    });
  });

  group('MusicNavTile', () {
    testWidgets('是圆角卡片（Material 有圆角）而不是裸 ListTile', (tester) async {
      await tester.pumpWidget(wrap(
        MusicNavTile(
          icon: Icons.queue_music_rounded,
          title: '我的歌单',
          subtitle: '本地歌单，不需要账号',
          trailingText: '6',
          onTap: () {},
        ),
      ));
      expect(find.byType(ListTile), findsNothing);
      final mat = tester.widget<Material>(find
          .descendant(
            of: find.byType(MusicNavTile),
            matching: find.byType(Material),
          )
          .first);
      final radius = mat.borderRadius as BorderRadius?;
      expect(radius, isNotNull);
      expect(radius!.topLeft.x, greaterThan(8));
      expect(find.text('我的歌单'), findsOneWidget);
      expect(find.text('6'), findsOneWidget);
    });
  });

  group('子页面顶栏统一', () {
    test('MusicTheme.themeData 配了 appBarTheme，子页不再用 Material 默认顶栏', () {
      // 2026-10-30 用户：「音乐按你设计的 UI 界面，优化美化每一个分类界面吧，
      // 还有其余页面。」
      //
      // 之前 themeData() 只配了底色，appBarTheme 为空 —— 本地音乐 / 我的歌单 /
      // 歌单详情 / 源管理 / 插件市场 / 各平台专辑页全都退回 Material 默认顶栏
      // （20 号 Roboto、默认灰底、滚动变色），和手绘的圆角卡片完全不是一个语言。
      final theme = MusicTheme.themeData();
      final bar = theme.appBarTheme;
      expect(bar.backgroundColor, isNotNull);
      expect(bar.elevation, 0);
      expect(bar.scrolledUnderElevation, 0, reason: '滚动时不能变色');
      expect(bar.centerTitle, isFalse, reason: '左对齐才和音乐页大标题一致');
      expect(bar.titleTextStyle?.fontWeight, FontWeight.w700);
      expect(bar.titleTextStyle?.fontSize, greaterThanOrEqualTo(17));
    });

    test('列表项 / 分隔线 / 底部弹层也跟着配色走', () {
      final theme = MusicTheme.themeData();
      expect(theme.listTileTheme.iconColor, MusicTheme.tint);
      expect(theme.dividerTheme.thickness, lessThanOrEqualTo(0.5));
      expect(theme.bottomSheetTheme.backgroundColor, MusicTheme.card);
    });
  });

  // ============================================================
  // 子页面骨架（2026-10-30 第二批）
  // ============================================================
  //
  // push 进来的子页面（本地音乐 / 我的歌单 / 歌单详情 / 插件市场…）
  // 原来都是「AppBar 小标题 + 裸 ListTile」。
  // 现在统一成「返回按钮 + 大标题 + 说明 + 右侧动作」——
  // 但**不能两处都写标题**（AppBar 一个、大标题一个，用户会看到重复两遍）。

  group('子页面骨架', () {
    testWidgets('大标题可以带返回按钮，窄屏也不溢出', (tester) async {
      await tester.pumpWidget(wrap(
        MusicPageHeader(
          leading: const MusicBackButton(),
          title: '本地音乐',
          subtitle: '已下载 12 首 · 占用 84.3 MB',
          action: MusicRoundAction(
            icon: Icons.delete_sweep_outlined,
            tooltip: '清空全部',
            onTap: () {},
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
      expect(find.byType(MusicBackButton), findsOneWidget);
      expect(find.text('本地音乐'), findsOneWidget);
      expect(find.text('已下载 12 首 · 占用 84.3 MB'), findsOneWidget);
    });

    testWidgets('返回按钮真的会 pop', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => Navigator.of(ctx).push(MaterialPageRoute<void>(
                builder: (_) => const Scaffold(
                  body: Center(child: MusicBackButton()),
                ),
              )),
              child: const Text('进入'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('进入'));
      await tester.pumpAndSettle();
      expect(find.byType(MusicBackButton), findsOneWidget);
      await tester.tap(find.byType(MusicBackButton));
      await tester.pumpAndSettle();
      expect(find.byType(MusicBackButton), findsNothing);
      expect(find.text('进入'), findsOneWidget);
    });

    testWidgets('圆形动作按钮：可用时回调，禁用时不响应', (tester) async {
      var taps = 0;
      await tester.pumpWidget(wrap(
        Row(children: [
          MusicRoundAction(
            icon: Icons.add_rounded,
            tooltip: '新建',
            onTap: () => taps++,
          ),
          MusicRoundAction(
            icon: Icons.refresh_rounded,
            tooltip: '刷新',
            onTap: null,
          ),
        ]),
      ));
      await tester.tap(find.byIcon(Icons.add_rounded));
      expect(taps, 1);
      await tester.tap(find.byIcon(Icons.refresh_rounded));
      expect(taps, 1, reason: 'onTap 为 null 时必须真的禁用');
    });
  });

  group('依赖方向', () {
    test('music_skeleton 不许 import 任何页面（否则会形成循环依赖）', () {
      // `music_components` → `playlist_page` → `music_skeleton`：
      // 骨架一旦反过来 import 页面，就成环（能编，但改一个文件牵连另一个）。
      final src = File('lib/music/widgets/music_skeleton.dart').readAsStringSync();
      expect(
        RegExp(r"import\s+'package:tvbox/music/pages/").hasMatch(src),
        isFalse,
        reason: 'music_skeleton.dart 里出现了对 pages/ 的 import',
      );
    });

    test('music_components 转导出了骨架组件（老调用点不用改 import）', () {
      final src =
          File('lib/music/widgets/music_components.dart').readAsStringSync();
      expect(
        src.contains("export 'package:tvbox/music/widgets/music_skeleton.dart';"),
        isTrue,
      );
    });
  });
}
