import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox/common/appearance_sync.dart';
import 'package:tvbox/common/theme.dart';
import 'package:tvbox/common/theme_mode_store.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/reading/services/settings_service.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';
import 'package:tvbox/services/main_tab_controller.dart';

/// 探针：**「全局选了浅色，界面却还是深色」** 的传导链。
///
/// 这个文件只做**测量**，不做断言式"契约"（那些另开文件）。
/// 目的是把 bug 的每一步变成可复现的数值，而不是靠推理。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // GetX 里注册 MainTabController（AppearanceSync 会读它的 selectedTab）
    if (!Get.isRegistered<MainTabController>()) {
      Get.put(MainTabController());
    }
  });

  test('✅ 全局说了算：音乐自己的 mode=dark 不再能覆盖全局浅色', () async {
    // ── 初始状态 ───────────────────────────────────────────────
    await MusicThemeStore.instance.init();
    await MusicThemeStore.instance.setMode(MusicThemeMode.dark);
    // ⚠️ 原来这里是 `MusicTheme.setDark(true)` —— 用来模拟"音乐自己选了深色"。
    // 现在音乐明暗**派生自全局 `AppBrightness`**（该 API 已删除），
    // 结构上不存在"音乐自己的深色"，所以这行没有必要了。
    AppTheme.applyPalette(const JellyPalette.ink(), module: 'video');

    // （音乐明暗桥 `MusicBrightnessBridge` 已删除：明暗只由全局
    //   ThemeModeStore 决定，模块自己的开关改为写回全局，不再反向覆盖。）

    // ── 用户把全局切成浅色 ─────────────────────────────────────
    ThemeModeStore.notifier.value = ThemeMode.light;
    AppBrightness.isLight.value = true;
    print('  ① 用户选浅色后: AppBrightness.isLight=${AppBrightness.isLight.value}');

    // ── 用户切到音乐 tab（AppearanceSync 会按"谁在前台谁说话"重算）──
    MainTabController.instance.selectedTab.value =
        MainTabController.musicTabIndex;

    AppearanceSync.applyForCurrentModule(videoEffectiveLight: true);
    print('  ② 切到音乐 tab 后: AppBrightness.isLight=${AppBrightness.isLight.value}');
    print('     MusicTheme.isDark=${MusicTheme.isDark}（音乐自己的设置，'
        '现在只影响音乐播放器皮肤，不再是全局明暗的来源）');

    // ✅ 改成"全局说了算"之后：音乐自己的 dark **不再**能覆盖全局浅色
    expect(AppBrightness.isLight.value, isTrue,
        reason: '全局选了浅色就该一直是浅色 —— 音乐自己的 mode=dark 不再能覆盖它');
  });

  test('🔴 传导：AppBrightness 变深色后，AppTheme 的静态 getter 立刻变深', () {
    AppTheme.applyPalette(const JellyPalette.ink(), module: 'video');

    AppBrightness.isLight.value = true;
    final lightBg = AppTheme.backgroundPrimary;
    final lightText = AppTheme.textPrimary;

    AppBrightness.isLight.value = false;
    final darkBg = AppTheme.backgroundPrimary;
    final darkText = AppTheme.textPrimary;

    print('  浅色: bg=$lightBg text=$lightText');
    print('  深色: bg=$darkBg text=$darkText');
    expect(lightBg == darkBg, isFalse,
        reason: 'AppTheme 是静态类，读的是 AppBrightness.isLight —— 一旦被改成深色，'
            '所有读 AppTheme.* 的地方都变深，且不会通知 widget');
  });

  test('🔴 关键：AppBrightness 变了，但没 rebuild 的 widget 停在旧色', () {
    AppTheme.applyPalette(const JellyPalette.ink(), module: 'video');
    AppBrightness.isLight.value = true;

    // 模拟"一个在 const 子树上、不会 rebuild 的 widget"
    final frozenWidget = Container(color: AppTheme.backgroundPrimary);

    // 全局被音乐覆盖成深色
    AppBrightness.isLight.value = false;

    // 没有重建 → 它仍然是浅色（"该深的地方还浅"）；
    // 而重建过的 widget 会是深色。两者混在同一屏 → 花屏。
    print('  冻结的 widget 颜色 = ${(frozenWidget.color)}');
    print('  此刻 AppTheme.backgroundPrimary = ${AppTheme.backgroundPrimary}');
    expect((frozenWidget.color) == AppTheme.backgroundPrimary, isFalse,
        reason: '这就是"明明浅色模式结果还是深色背景"的机制：'
            '静态主题 + 不重建 = 同一屏上颜色不一致');
  });

  test('🔴 每个 tab 下 AppearanceSync 算出来的明暗（找出谁是深色的）', () async {
    await MusicThemeStore.instance.init();
    // 音乐保持默认（system）；影视/阅读也设浅色
    final cases = <String, int>{
      '影视(settings=3以外)': MainTabController.videoTabIndex,
      '阅读(books)': MainTabController.booksTabIndex,
      '音乐(music)': MainTabController.musicTabIndex,
    };
    for (final e in cases.entries) {
      MainTabController.instance.selectedTab.value = e.value;
      // 影视自己那套算出的是浅色（用户已选浅色）
      AppearanceSync.applyForCurrentModule(videoEffectiveLight: true);
      print('  ${e.key.padRight(22)} → light=${AppBrightness.isLight.value}'
          '  (音乐isDark=${MusicTheme.isDark}, 阅读isDarkMode=${SettingsService().isDarkMode})');
    }
  });
}
