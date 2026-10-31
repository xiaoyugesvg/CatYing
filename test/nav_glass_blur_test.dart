// 底栏「玻璃模糊」回归（2026-10-31）
//
// ── 这条测试是为什么写的 ────────────────────────────────────────
// `jelly_nav_bar.dart` 里那层模糊原本是这样写的：
//
//     BackdropFilter(filter: JellyTheme.glassFilter)
//     // 注释：「不要 child：只把背景模糊掉，底色由内容层画」
//
// **这个注释是错的。** `BackdropFilter` 一旦没有 child，整层模糊会被
// 直接丢弃 —— 不是"模糊了但看不见"，是根本不执行。六种风格因此从来
// 没模糊过，玻璃全成了"平的半透明色块"。用户看完的评语是
// 「你看看你写的什么玩意」。
//
// 实测数据（sigma=20，红/蓝两块拼色，取交界上方 8px 的红通道）：
//   · 无 child            ⇒ 255（原封不动，完全没模糊）
//   · child = 全透明 ColoredBox ⇒ 164（交界被摊成渐变）
//   · 四种层结构（裸的 / +ClipRRect / +内层 RepaintBoundary /
//     两者都有）结果全是 164 ⇒ **只有 child 有无才致命**
//
// 所以这里钉两条：
//   ① 结构：树里每个 BackdropFilter 都必须有 child（直接钉死这个坑）
//   ② 行为：开/关模糊必须真的让像素不一样（防止以后又静默失效）
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/common/floating_nav_spec.dart';
import 'package:tvbox/reading/services/settings_service.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';
import 'package:tvbox/reading/widgets/jelly_nav_bar.dart';

const double _w = 390;
const double _h = 220;

final GlobalKey _shotKey = GlobalKey();

const List<JellyNavItem> _items = <JellyNavItem>[
  JellyNavItem(icon: Icons.live_tv_rounded, label: '影视'),
  JellyNavItem(icon: Icons.music_note_rounded, label: '音乐'),
  JellyNavItem(icon: Icons.menu_book_rounded, label: '阅读'),
  JellyNavItem(icon: Icons.collections_bookmark_rounded, label: '书架'),
  JellyNavItem(icon: Icons.person_rounded, label: '我的'),
];

/// 两块高对比色：模糊有没有生效，全看交界会不会被摊开
Widget _striped() {
  return const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(child: ColoredBox(color: Color(0xFFE8467C))),
      Expanded(child: ColoredBox(color: Color(0xFF23A6F0))),
    ],
  );
}

Widget _scene(JellyPalette palette) {
  return Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: const MediaQueryData(size: Size(_w, _h), devicePixelRatio: 2),
      child: Theme(
        data: ThemeData(useMaterial3: true, brightness: Brightness.dark),
        child: Material(
          type: MaterialType.transparency,
          child: RepaintBoundary(
            key: _shotKey,
            child: SizedBox(
              width: _w,
              height: _h,
              child: Stack(
                children: [
                  Positioned.fill(child: _striped()),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: JellyNavBar(
                      floating: true,
                      currentIndex: 0,
                      onTap: (_) {},
                      items: _items,
                      palette: palette,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 拍一张底栏区域的原始像素
Future<Uint8List> _capture(WidgetTester tester, JellyPalette palette) async {
  await tester.pumpWidget(_scene(palette));
  await tester.pump(const Duration(milliseconds: 600));
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_shotKey));
  final img = await tester.runAsync(() => boundary.toImage(pixelRatio: 2));
  expect(img, isNotNull);
  final raw = await tester.runAsync(
    () => img!.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  expect(raw, isNotNull);
  return raw!.buffer.asUint8List();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('玻璃模糊', () {
    const palette = JellyPalette.jelly();

    /// 这条栏现在该不该挂模糊层（和组件里同一套判据）
    bool expectedBlur(FloatingNavStyle style) {
      final deco = FloatingNavSpec.barDecoration(
        style: style,
        isDark: true,
        palette: palette,
        opacity: SettingsService().navBarOpacity,
      );
      return FloatingNavSpec.needsBlur(style, deco);
    }

    testWidgets('挂出来的每个 BackdropFilter 都必须有 child', (tester) async {
      tester.view.physicalSize = const Size(_w * 2, _h * 2);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      // 关掉背景动画 = 允许上模糊
      await SettingsService().setBackgroundAnimation(false);

      for (final style in FloatingNavStyle.values) {
        await SettingsService().setNavStyle(style.id);
        await tester.pumpWidget(_scene(palette));
        await tester.pump(const Duration(milliseconds: 600));

        final filters =
            tester.widgetList<BackdropFilter>(find.byType(BackdropFilter));
        for (final f in filters) {
          expect(
            f.child,
            isNotNull,
            reason: '${style.id} 的 BackdropFilter 没有 child ⇒ '
                '整层模糊会被直接丢弃（不是看不见，是不执行）',
          );
        }
        if (expectedBlur(style)) {
          expect(filters, isNotEmpty,
              reason: '${style.id} 够透、应该上模糊，却没挂模糊层');
        } else {
          expect(filters, isEmpty,
              reason: '${style.id} 栏体几乎不透明（模糊看不见），不该白烧一次全屏高斯');
        }
      }
    });

    testWidgets('把不透明度拉低后，水墨也会开始模糊', (tester) async {
      tester.view.physicalSize = const Size(_w * 2, _h * 2);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      await SettingsService().setBackgroundAnimation(false);
      await SettingsService().setNavStyle(FloatingNavStyle.ink.id);

      await tester.pumpWidget(_scene(palette));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(BackdropFilter), findsNothing,
          reason: '默认不透明度下水墨是实心的，不该模糊');

      await SettingsService().setNavBarOpacity(0.4);
      addTearDown(() => SettingsService().setNavBarOpacity(0.95));
      await tester.pumpWidget(_scene(palette));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(BackdropFilter), findsOneWidget,
          reason: '不透明度 0.4 时底下已经透出来了，必须模糊');
    });

    // 只有这两种是**设计上就半透明**的（macOS 玻璃 0.34~0.66 / iOS 0.55~0.62），
    // 其余风格默认接近实色，模糊本来就透不出来 —— 它们由上面那条
    // "该不该挂"的结构断言覆盖。
    for (final style in [FloatingNavStyle.frost, FloatingNavStyle.neon]) {
      testWidgets('${style.label}：开模糊后底栏像素必须真的变', (tester) async {
        tester.view.physicalSize = const Size(_w * 2, _h * 2);
        tester.view.devicePixelRatio = 2.0;
        addTearDown(tester.view.reset);
        await SettingsService().setNavStyle(style.id);

        // 背景动画开 ⇒ 跳过模糊（纯色底）；关 ⇒ 上模糊。
        // 两者**只差这一层**，所以像素一样就说明模糊层是死的。
        await SettingsService().setBackgroundAnimation(true);
        final sharp = await _capture(tester, palette);
        await SettingsService().setBackgroundAnimation(false);
        final blurred = await _capture(tester, palette);

        expect(sharp.length, blurred.length);
        var diff = 0;
        var maxDiff = 0;
        for (var i = 0; i < sharp.length; i += 4) {
          // 只比 RGB，alpha 恒为 255
          final d = (sharp[i] - blurred[i]).abs() +
              (sharp[i + 1] - blurred[i + 1]).abs() +
              (sharp[i + 2] - blurred[i + 2]).abs();
          if (d > 12) diff++;
          if (d > maxDiff) maxDiff = d;
        }
        expect(
          diff,
          greaterThan(400),
          reason: '${style.label} 开/关模糊的像素几乎一致（$diff 个像素有差异，'
              '最大差 $maxDiff）⇒ 模糊层没生效，玻璃退化成平的半透明色块',
        );
      });
    }
  });

  group('三种系统风格的选中块不能长一样', () {
    // 默认「水墨」配色的 primary 是 0xFF3A3A3A（近黑灰），
    // 原来鸿蒙/澎湃/云母都拿 primary 画实心块 ⇒ 三个风格同一个黑胶囊，
    // 六种里三种看不出区别。现在改成：鸿蒙=淡彩、澎湃=中性、云母=实心。
    for (final entry in <String, JellyPalette>{
      '水墨': const JellyPalette.ink(),
      '靛蓝': const JellyPalette.jelly(),
    }.entries) {
      test('${entry.key}配色下，鸿蒙 / 澎湃 / 云母 的选中块互不相同', () {
        for (final isDark in [true, false]) {
          final colors = <FloatingNavStyle, Color>{
            for (final s in [
              FloatingNavStyle.aurora,
              FloatingNavStyle.reverse,
              FloatingNavStyle.solid,
            ])
              s: FloatingNavSpec.styleIndicatorColor(
                s,
                isDark: isDark,
                palette: entry.value,
              ),
          };
          final sigs = colors.values
              .map((c) => '${c.toARGB32()}')
              .toSet();
          expect(
            sigs.length,
            3,
            reason: '${entry.key}配色 / ${isDark ? '深色' : '浅色'} 下 '
                '有风格撞了：$colors',
          );
        }
      });
    }
  });
}
