// 主题系统回归测试 —— 守住「24 套预设都能正确解析」与「强调色在各底色上看得清」。
//
// 为什么需要这一组：
//   1. `JellyPalette` 的预设从 7 套扩到 24 套，每新增一套都要在 `fromPreset`
//      里注册一个 case。漏注册**不会报错** —— `fromPreset` 会静默回退「魅力紫」，
//      用户在设置页选「春节红」，界面却变成紫色，且没有任何日志。
//   2. 主题色压在底色上看不看得清，是**算出来的**，靠肉眼看截图会漏。
//      2026-10 新增 8 套鲜艳主题时就出现过：春节红在卡片上只有 2.66:1，
//      音乐模块默认主题（水墨书香）深色下强调色只有 2.82:1 —— 都是"灰糊糊"。
//
// 这两条都是"改一行色值就可能悄悄退化"的类型，必须有断言盯着。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/pages/settings/sub/unified_theme_settings_page.dart';
import 'package:tvbox/reading/services/settings_service.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';
import 'package:tvbox/services/background_service.dart';

/// WCAG 相对亮度对比度（1~21）
double _ratio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// 逐字段比较两套调色板（`JellyPalette` 没有 `==` 重载）
void _expectSamePalette(JellyPalette a, JellyPalette b, String reason) {
  final fields = <String, List<Color>>{
    'primary': [a.primary, b.primary],
    'primaryLight': [a.primaryLight, b.primaryLight],
    'primaryDark': [a.primaryDark, b.primaryDark],
    'accent': [a.accent, b.accent],
    'success': [a.success, b.success],
    'warning': [a.warning, b.warning],
    'error': [a.error, b.error],
    'blue': [a.blue, b.blue],
    'backgroundLight': [a.backgroundLight, b.backgroundLight],
    'backgroundDark': [a.backgroundDark, b.backgroundDark],
    'cardLight': [a.cardLight, b.cardLight],
    'cardDark': [a.cardDark, b.cardDark],
    'navSelectedBg': [a.navSelectedBg, b.navSelectedBg],
    'navSelectedFg': [a.navSelectedFg, b.navSelectedFg],
    'navUnselected': [a.navUnselected, b.navUnselected],
    'textPrimaryLight': [a.textPrimaryLight, b.textPrimaryLight],
    'textPrimaryDark': [a.textPrimaryDark, b.textPrimaryDark],
    'textSecondary': [a.textSecondary, b.textSecondary],
  };
  for (final e in fields.entries) {
    expect(e.value[0], e.value[1], reason: '$reason：字段 ${e.key} 不一致');
  }
}

void main() {
  group('预设完整性', () {
    test('每一套预设都能被 fromPreset 原样解析回来（不漏注册 case）', () {
      for (final p in themePresets) {
        final parsed = JellyPalette.fromPreset(p.id);
        _expectSamePalette(parsed, p.palette, '预设 ${p.id}（${p.name}）');
      }
    });

    test('预设数量 ≥ 24 且 id / 名字都不重复', () {
      expect(themePresets.length, greaterThanOrEqualTo(24),
          reason: '新增预设后请同步更新本断言下限');
      expect(themePresets.map((e) => e.id).toSet().length, themePresets.length,
          reason: 'id 重复会让设置页出现两个都选中的行');
      expect(themePresets.map((e) => e.name).toSet().length, themePresets.length,
          reason: '名字重复会让用户无法分辨两套主题');
    });

    test('未知 id 不抛异常且回退到默认主题', () {
      expect(() => JellyPalette.fromPreset('__不存在__'), returnsNormally);
      expect(JellyPalette.fromPreset('__不存在__').primary,
          const JellyPalette.jelly().primary);
    });
  });

  group('强调色可读性（AppTheme.accentOnSurface）', () {
    // 这个颜色 150+ 处用作**文字/图标/细描边**，多数压在卡片上。
    // WCAG AA 正文要 4.5，但强调色是小面积点缀，取 3.0 作为下限（与实现一致）。
    for (final light in [true, false]) {
      test('${light ? '浅色' : '深色'}：全部预设 ≥ 3.0（页面底 + 卡片底）', () {
        AppBrightness.isLight.value = light;
        for (final p in themePresets) {
          AppTheme.applyPalette(p.palette);
          final c = AppTheme.accentOnSurface;
          final onBg = _ratio(c, AppTheme.backgroundPrimary);
          final onCard = _ratio(c, AppTheme.backgroundSecondary);
          expect(onBg, greaterThanOrEqualTo(3.0),
              reason: '${p.id} 强调色在页面底上只有 ${onBg.toStringAsFixed(2)}');
          expect(onCard, greaterThanOrEqualTo(3.0),
              reason: '${p.id} 强调色在卡片底上只有 ${onCard.toStringAsFixed(2)}');
        }
      });
    }
  });

  group('音乐模块强调色', () {
    setUp(() {
      // 模拟 main.dart 的桥接注册（未注册会触发 assert）
      MusicPaletteBridge.register(
        () => ModuleThemeStoreStub.current,
      );
    });

    tearDown(() => AppBrightness.isLight.value = true);

    test('深色：MusicTheme.tint 在卡片上 ≥ 3.0（含默认的水墨书香）', () {
      AppBrightness.isLight.value = false;
      for (final p in themePresets) {
        ModuleThemeStoreStub.current = p.palette;
        MusicTheme.setCustomAccent(p.palette.primary);
        final r = _ratio(MusicTheme.tint, MusicTheme.card);
        expect(r, greaterThanOrEqualTo(3.0),
            reason: '${p.id} 深色强调色在卡片上只有 ${r.toStringAsFixed(2)}');
      }
    });

    test('浅色：MusicTheme.tint 在卡片上 ≥ 4.5（当正文色用）', () {
      AppBrightness.isLight.value = true;
      for (final p in themePresets) {
        ModuleThemeStoreStub.current = p.palette;
        MusicTheme.setCustomAccent(p.palette.primary);
        final r = _ratio(MusicTheme.tint, MusicTheme.card);
        expect(r, greaterThanOrEqualTo(4.5),
            reason: '${p.id} 浅色强调色在卡片上只有 ${r.toStringAsFixed(2)}');
      }
    });

    test('实底按钮：onAccentFill 压在 accentFill 上 ≥ 4.5（白字不再糊）', () {
      for (final light in [true, false]) {
        AppBrightness.isLight.value = light;
        for (final p in themePresets) {
          ModuleThemeStoreStub.current = p.palette;
          MusicTheme.setCustomAccent(p.palette.primary);
          final r = _ratio(MusicTheme.onAccentFill, MusicTheme.accentFill);
          expect(r, greaterThanOrEqualTo(4.5),
              reason: '${p.id}（${light ? '浅' : '深'}）按钮文字只有 '
                  '${r.toStringAsFixed(2)}');
        }
      }
    });
  });

  group('统一主题页文案', () {
    testWidgets('「N 套主题为基准」里的 N 来自真实预设列表，不是写死的 7', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SettingsService().init();
      // 页面里的「壁纸」卡片会读 BackgroundService.instance（GetX 单例）
      Get.put(BackgroundService());
      // 整页很长（影视/直播/音乐/阅读/壁纸/其他），默认 800 高的测试窗口里
      // 后面的分区不会被 ListView 建出来 —— 撑高窗口，避免还要滚动
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester
          .pumpWidget(const MaterialApp(home: UnifiedThemeSettingsPage()));
      await tester.pumpAndSettle();

      // 预设从 7 套扩到 24 套后，这行文案原来还写着 7 —— 用户能直接看到。
      expect(find.textContaining('${themePresets.length} 套主题为基准'),
          findsOneWidget,
          reason: '文案里的套数应与 themePresets.length 一致');
    });
  });
}

/// 测试用的调色板注入桩（代替 main.dart 里的真实实现）
class ModuleThemeStoreStub {
  static JellyPalette current = const JellyPalette.ink();
}
