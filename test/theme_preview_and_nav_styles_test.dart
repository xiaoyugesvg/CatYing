import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/common/floating_nav_spec.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';
import 'package:tvbox/rfw_theme/rfw_theme_preview.dart';
import 'package:tvbox/rfw_theme/rfw_theme_store.dart';

/// 2026-10-30 的两处改动，各钉一组回归。
///
/// ① **RFW 主题预览**（用户：「RFW 主题加个预览和可视化呢」）
///    主题列表里那张缩略图是真的把首页渲染出来再缩放，不是截图。
///    这里保证：每套内置主题都能渲染出缩略图、示例数据槽位齐全。
///
/// ② **菜单栏 5 个风格重构**（用户：「除第一个外，其余 5 个重构」）
///    重构的落点是把配色从「写死色值」改成「从调色板推」，并把
///    真底栏与设置页预览卡的**两份实现合成一份**。
///    这里保证：六种风格都能出装饰、炫彩会随主题变、五种新风格互不相同。
void main() {
  group('RFW 主题预览', () {
    test('示例数据槽位齐全（分类 / 推荐 / 片单 / 筛选）', () {
      final input = sampleRfwHomeInput(themeId: 'chenguang');
      expect(input.categories.length, 3);
      expect(input.recommend.length, 2);
      expect(input.items.length, 8);
      expect(input.filters, isNotEmpty);
      // 封面一律给空串：预览里不该发网络请求，也不该出现"碎图"图标
      expect(input.items.every((v) => v.pic.isEmpty), isTrue);
    });

    for (final entry in builtinRfwThemes) {
      testWidgets('${entry.name}：缩略图能渲染出来', (tester) async {
        tester.view.physicalSize = const Size(1170, 2532);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(child: RfwThemeThumb(entry: entry)),
            ),
          ),
        );
        // 缩略图要先异步读主题文本，再渲染一整页
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(
          tester.takeException(),
          isNull,
          reason: '${entry.name} 的缩略预览渲染崩了',
        );
        // 主题文本读到之后才会有 RfwThemeScreen
        expect(
          find.byType(RfwThemeScreen),
          findsOneWidget,
          reason: '${entry.name} 的缩略图一直停在占位块（主题文本没读到）',
        );
      });
    }

    testWidgets('预览缩略图不跑轮播计时器（否则设置页永远"没静止"）',
        (tester) async {
      final entry = builtinRfwThemes.first;
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Center(child: RfwThemeThumb(entry: entry)))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // 缩略图里挂了 4 秒周期的自动轮播的话，pumpAndSettle 会一直等下去
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    });
  });

  group('菜单栏风格（重构后）', () {
    final palettes = <String, JellyPalette>{
      'ink': const JellyPalette.ink(),
      'bananaRed': const JellyPalette.bananaRed(),
    };

    test('六种风格在明暗下都能出装饰', () {
      for (final p in palettes.values) {
        for (final isDark in [true, false]) {
          for (final style in FloatingNavStyle.values) {
            final deco = FloatingNavSpec.barDecoration(
              style: style,
              isDark: isDark,
              palette: p,
            );
            expect(
              deco.color != null || deco.gradient != null,
              isTrue,
              reason: '${style.id}（${isDark ? '深' : '浅'}）既没底色也没渐变',
            );
            expect(
              FloatingNavSpec.barShadows(
                style: style,
                isDark: isDark,
                palette: p,
              ),
              isNotEmpty,
              reason: '${style.id} 没有阴影规格',
            );
          }
        }
      }
    });

    test('炫彩跟着主题色走（不再写死紫/粉/青）', () {
      final a = FloatingNavSpec.auroraColorsFor(
        const JellyPalette.ink(),
        isDark: true,
      );
      final b = FloatingNavSpec.auroraColorsFor(
        const JellyPalette.bananaRed(),
        isDark: true,
      );
      expect(a, isNot(equals(b)),
          reason: '换主题色后炫彩渐变没变 ⇒ 还是写死的那套');
    });

    test('除水墨外的 5 个风格互相不同（不是只换了个颜色）', () {
      const p = JellyPalette.ink();
      final seen = <String>{};
      for (final style in FloatingNavStyle.values) {
        if (style == FloatingNavStyle.ink) continue;
        final deco = FloatingNavSpec.barDecoration(
          style: style,
          isDark: true,
          palette: p,
          opacity: 1.0,
        );
        final sig =
            '${deco.color}|${deco.gradient}|${FloatingNavSpec.styleRadius(style)}|'
            '${FloatingNavSpec.styleIndicator(style)}';
        expect(seen.add(sig), isTrue, reason: '${style.id} 和别的风格撞了：$sig');
      }
      expect(seen.length, 5);
    });

    test('底栏不透明度滑杆对每种风格都生效', () {
      const p = JellyPalette.ink();
      for (final style in FloatingNavStyle.values) {
        final full = FloatingNavSpec.barDecoration(
          style: style,
          isDark: true,
          palette: p,
          opacity: 1.0,
        );
        final low = FloatingNavSpec.barDecoration(
          style: style,
          isDark: true,
          palette: p,
          opacity: 0.4,
        );
        final fullAlpha = full.color?.a ?? full.gradient!.colors.first.a;
        final lowAlpha = low.color?.a ?? low.gradient!.colors.first.a;
        expect(lowAlpha, lessThan(fullAlpha),
            reason: '${style.id} 调低不透明度后没变化（滑杆对它无效）');
      }
    });
  });
}
