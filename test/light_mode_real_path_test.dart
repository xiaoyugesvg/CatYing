import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox/common/appearance_sync.dart';
import 'package:tvbox/common/theme.dart';
import 'package:tvbox/common/theme_mode_store.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';
import 'package:tvbox/reading/services/settings_service.dart';

/// 模拟**用户真实操作路径**：设置 → 主题与外观 → 点「浅色」。
///
/// 上轮那个探针是**手动给 `AppBrightness.isLight` 赋值**测的 ——
/// 那只证明"赋值后 getter 会变"，**没证明用户点「浅色」真的会把它变成 true**。
/// 用户实测：选了浅色，底色还是全黑。所以必须测完整链路。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppTheme.applyPalette(const JellyPalette.ink(), module: 'video');
  });

  test('🔴 用户点「浅色」后，AppBrightness 与页面底色到底是什么', () async {
    await MusicThemeStore.instance.init();
    GlobalThemeSync.registerMusic(
        (m) => MusicThemeStore.instance.applyFromGlobal(m));
    GlobalThemeSync.registerReading(
        (m) => SettingsService().applyThemeModeFromGlobal(m));

    print('  ── 起始 ──');
    print('     isLight=${AppBrightness.isLight.value}  '
        'bg=${AppTheme.backgroundPrimary}');

    // 用户在「主题与外观」点了「浅色」
    await ThemeModeStore.set(ThemeMode.light);
    print('  ── ThemeModeStore.set(light) 之后 ──');
    print('     notifier=${ThemeModeStore.notifier.value}  '
        'isLight=${AppBrightness.isLight.value}');
    print('     页面底色 AppTheme.backgroundPrimary = ${AppTheme.backgroundPrimary}');

    // app.dart 会在 build 里调这一句
    AppearanceSync.applyForCurrentModule(videoEffectiveLight: true);
    print('  ── AppearanceSync.applyForCurrentModule 之后 ──');
    print('     isLight=${AppBrightness.isLight.value}  '
        'bg=${AppTheme.backgroundPrimary}');

    // 期望：浅色模式下页面底色应该是浅的
    expect(AppBrightness.isLight.value, isTrue,
        reason: '用户点了「浅色」，AppBrightness 必须是 light');
    expect(AppTheme.backgroundPrimary, const JellyPalette.ink().backgroundLight,
        reason: '浅色模式下页面底色必须是 backgroundLight(#F7F5F1)，'
            '否则就是"选了浅色但底色还是黑"');
  });

  test('🔴 每个 tab 下用户点浅色后是否都能保持浅色', () async {
    await MusicThemeStore.instance.init();
    await ThemeModeStore.set(ThemeMode.light);

    for (final entry in {
      '影视': 0,
      '书架': 1,
      '设置': 3,
      '直播': 4,
      '音乐': 5,
      '阅读': 6,
    }.entries) {
      AppearanceSync.applyForCurrentModule(videoEffectiveLight: true);
      print('  ${entry.key.padRight(4)} → isLight=${AppBrightness.isLight.value}'
          '  bg=${AppTheme.backgroundPrimary}');
    }
  });
}
