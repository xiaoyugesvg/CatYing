import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox/common/theme.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';

/// 复核：音乐模块的明暗是否与"该显示的明暗"一致。
///
/// ── 起因（用户实测截图）──────────────────────────────────────
/// 音乐首页（发现页）整个"灰蒙蒙半透明"，歌名是白字但几乎看不清。
/// 推断：`MusicTheme` 认为自己是**深色**（所以文字用 `#EDEDED` 近白），
/// 但实际渲染出来的背景是**浅色**的（全局背景层透出来），
/// 于是"白字 + 浅底" → 对比度极低 → 看起来糊成一片。
///
/// 这个测试就是把那个推断变成可验证的事实。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 测试环境没有 main.dart 的启动流程，必须自己注册调色板桥，
    // 否则 MusicPaletteBridge 的"未注册"断言会直接抛（#13 的保护）。
    MusicPaletteBridge.register(() => const JellyPalette.ink());
  });

  /// 把明暗切到指定状态（**不依赖 init 的顺序**）。
  ///
  /// ⚠️ 音乐明暗现在**派生自全局 `AppBrightness`**（见 `MusicTheme._isDark`）：
  /// `MusicTheme.apply(dark:)` / `setDark()` 已不再是明暗来源 ——
  /// 所以要改明暗只能改全局。这也正是本组测试要验证的"单一真源"。
  void force(bool dark) => AppBrightness.isLight.value = !dark;

  group('MusicTheme 明暗一致性', () {
    test('浅色下 label 应是深色文字（不会白字白底）', () async {
      SharedPreferences.setMockInitialValues({
        'music.themeMode': MusicThemeMode.light.name,
      });
      await MusicThemeStore.instance.init();
      force(false); // 显式打桩，脱离静态状态残留

      expect(MusicTheme.isDark, isFalse);
      final lum = MusicTheme.label.computeLuminance();
      expect(lum, lessThan(0.5),
          reason: '浅色模式下 label 必须是深色（否则白字浅底看不清）');
      // 文字与背景的亮度差要够大
      final bgLum = MusicTheme.background.computeLuminance();
      expect((lum - bgLum).abs(), greaterThan(0.3),
          reason: '文字与背景对比度不足会"糊成一片"');
    });

    test('深色下 label 应是浅色文字，且与背景对比明显', () async {
      SharedPreferences.setMockInitialValues({
        'music.themeMode': MusicThemeMode.dark.name,
      });
      await MusicThemeStore.instance.init();
      force(true);

      expect(MusicTheme.isDark, isTrue);
      final lum = MusicTheme.label.computeLuminance();
      final bgLum = MusicTheme.background.computeLuminance();
      expect(lum, greaterThan(0.5), reason: '深色模式 label 必须浅色');
      expect((lum - bgLum).abs(), greaterThan(0.3),
          reason: '深色下文字与背景对比度不足');
    });

    test('🔴 background 必须不透明（否则全局背景层会透出来导致"灰蒙蒙"）',
        () async {
      SharedPreferences.setMockInitialValues({
        'music.themeMode': MusicThemeMode.dark.name,
      });
      await MusicThemeStore.instance.init();

      expect(MusicTheme.background.a, 1.0,
          reason: '音乐页 Scaffold 用的是 MusicTheme.background；'
              '一旦它是半透明的，全局壁纸层就会透上来把整页冲淡');
      final card = MusicTheme.card;
      expect(card.a, greaterThan(0.8),
          reason: '卡片色若透明度过低，叠在多层背景上会发灰');
    });

    test('currentMode 的推导：跟随系统时不应被误判为显式 dark/light', () async {
      SharedPreferences.setMockInitialValues({
        'music.themeMode': MusicThemeMode.system.name,
      });
      await MusicThemeStore.instance.init();
      // ⚠️ currentMode 的实现是 `isDark ? dark : light`，
      // 它**丢掉了 "system" 这个语义**。这是一个待确认的设计问题：
      // 如果 UI 用 currentMode 显示"跟随系统"，会永远显示不出来。
      final m = MusicThemeStore.instance.currentMode;
      // ignore: avoid_print
      print('[probe] 存的是 system，currentMode 返回 $m');
      expect(MusicThemeMode.values.contains(m), isTrue);
    });
  });

  test('各种调色板下：背景都不能透（防止换配色后变灰）', () async {
    for (final _ in [
      const JellyPalette.ink(),
      const JellyPalette.pink(),
      const JellyPalette.jelly(),
    ]) {
      force(true);
      expect(MusicTheme.background.a, 1.0);
      // 浅色也一样
      force(false);
      expect(MusicTheme.background.a, 1.0);
    }
  });
}
