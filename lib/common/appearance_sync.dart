import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../reading/services/settings_service.dart';
import '../services/main_tab_controller.dart';
import 'theme.dart';
import 'theme_mode_store.dart';

/// 统一"当前该用浅色还是深色"。
///
/// ── 要解决的冲突 ──────────────────────────────────────────────
/// 影视和阅读**各有一套明暗设置**，但全 App 只有一棵 widget 树、
/// 只有一个 `AppBrightness.isLight`：
///   · 影视：设置 → 主题与外观 → 明暗模式（`ThemeModeStore`）
///   · 阅读：我的 → 主题跟随系统 / 明暗（`SettingsService`）
///
/// 原来 `AppBrightness` 只由影视那一套驱动（`app.dart` 里按
/// `ThemeModeStore` + `BackgroundService` 算 effectiveLight）。
/// 于是**阅读的「主题跟随系统」拨了一点反应都没有** ——
/// 它只改了 `SettingsService.isDarkMode`，没人读它去改 AppBrightness。
///
/// ── 协调规则（按"当前在哪个模块"决定谁说了算）──────────────────
///   · 在**阅读**里 → 用 `SettingsService.isDarkMode`
///     （它内部已实现"跟随系统则取系统亮度"，并且
///       `onPlatformBrightnessChanged` 会 notify）
///   · 在**音乐**里 → 用 `MusicThemeStore`（音乐有自己的明暗开关）
///   · 在**影视/直播**里 → 用影视那套（`ThemeModeStore` + 壁纸联动）
///
/// 这样每个模块的开关都真的生效，且不会互相覆盖 ——
/// 谁在前台谁说话。
///
/// ── 为什么要单独一个类 ────────────────────────────────────────
/// `app.dart` 里的 effectiveLight 逻辑还牵着壁纸联动
/// （`BackgroundService` → `ThemeModeStore.applyLightFromBackground`），
/// 直接把阅读/音乐的判断塞进去会把那部分缠在一起。
/// 抽出来之后：`app.dart` 在算完影视的值后调一次 [applyForCurrentModule]，
/// 由这里决定是否让别的模块覆盖。
class AppearanceSync {
  AppearanceSync._();

  /// 当前生效（已被本类写进 `AppBrightness` 的）明暗
  static bool _current = false;
  static bool get current => _current;

  /// 是否正在由"非影视模块"接管明暗。
  /// `app.dart` 用它判断要不要跳过影视那套的写入。
  static bool get isModuleOverride => _moduleOverride;
  static bool _moduleOverride = false;

  /// 由 `app.dart` 在算出影视的 effectiveLight 后调用。
  ///
  /// [videoEffectiveLight] 是「设置 → 主题与外观」那套算出来的结果。
  ///
  /// ── 🔴 这里曾经是「谁在前台谁说话」，已改成「全局说了算」──────
  ///
  /// 旧逻辑：
  ///   在阅读里 → 用 `SettingsService().isDarkMode`
  ///   在音乐里 → 用 `MusicBrightnessBridge.isDark()`
  ///   否则     → 用影视那套
  ///
  /// 它当初是为了修「阅读的主题跟随系统不生效」。但它有个**致命的副作用**：
  /// `AppBrightness.isLight` 是**一根全局开关**，而 `ContentView` 的
  /// `IndexedStack` **同时保留 7 个 tab 的 subtree** ——
  /// 于是"在音乐里切一下 tab"就会把全局明暗改掉，
  /// **所有还活着的 tab 跟着一起变色**。
  ///
  /// 用户实测到的现象：
  ///   全局选了浅色，切到音乐/别的页面 → 一堆界面还是深色
  ///   （音乐自己的 `music.themeMode` 存的是 dark，就把全局覆盖了）
  ///
  /// 现在改成**全局唯一真源**：
  ///   明暗只由「设置 → 主题与外观」的 [ThemeModeStore] 决定。
  ///
  /// ⚠️ 但**必须保留 [PlatformDispatcher] 的读取** ——
  /// 用户选「跟随系统」时，系统亮度变化要能实时反映进来。
  /// 光看 `ThemeModeStore.mode` 是看不出系统当前是明是暗的
  /// （它只知道"要跟随系统"），所以 `system` 分支要现读一次。
  ///
  /// 音乐/阅读自己那套明暗开关经 `GlobalThemeSync` **写回全局**
  /// （`ThemeModeStore.set` → 重新走这里），而不是反过来覆盖全局。
  static void applyForCurrentModule({required bool videoEffectiveLight}) {
    _moduleOverride = false;

    // 跟随系统：现读平台亮度（否则"跟随系统"永远停在启动时的值）
    final light = ThemeModeStore.mode == ThemeMode.system
        ? PlatformDispatcher.instance.platformBrightness == Brightness.light
        : videoEffectiveLight;

    set(light);
  }

  /// 当前是否停在阅读模块
  static bool get inReading => _tabIndex() == MainTabController.booksTabIndex;

  /// 当前是否停在音乐模块
  static bool get inMusic => _tabIndex() == MainTabController.musicTabIndex;

  /// 直接设（供模块内的开关即时生效用，不必等切 tab）
  static void set(bool light) {
    if (_current == light && AppBrightness.isLight.value == light) return;
    _current = light;
    if (AppBrightness.isLight.value != light) {
      AppBrightness.isLight.value = light;
    }
  }

  static int _tabIndex() {
    if (!Get.isRegistered<MainTabController>()) return 0;
    return MainTabController.instance.selectedTab.value;
  }

  /// 由 `main.dart` 在启动时启动监听：
  /// 切 tab 时重新协调（否则从影视切到阅读，明暗还停在影视那套）。
  static void start() {
    if (!Get.isRegistered<MainTabController>()) return;
    ever(MainTabController.instance.selectedTab, (_) {
      // 切到别的模块时，用那次最新的影视值也行 —— 反正非影视 tab
      // 会用模块自己的设置，影视 tab 会走 videoEffectiveLight。
      applyForCurrentModule(videoEffectiveLight: _videoLightFromVideoSettings());
    });
    // 阅读设置变化（用户在阅读里拨了跟随系统/明暗开关）立刻生效
    SettingsService().addListener(_onReadingSettingsChanged);
  }

  static void _onReadingSettingsChanged() {
    if (inReading) applyForCurrentModule(videoEffectiveLight: _current);
  }

  /// 影视那一套当前算出来的明暗（壁纸联动优先）
  static bool _videoLightFromVideoSettings() {
    // 与 app.dart 的 effectiveLight 同义：壁纸联动开启时由壁纸决定
    if (ThemeModeStore.followBackground) {
      return AppBrightness.isLight.value;
    }
    switch (ThemeModeStore.mode) {
      case ThemeMode.light:
        return true;
      case ThemeMode.dark:
        return false;
      case ThemeMode.system:
        return PlatformDispatcher.instance.platformBrightness ==
            Brightness.light;
    }
  }

  /// 让"壁纸联动"在非影视模块下不生效（否则切到阅读会被壁纸改回去）
  static bool get allowBackgroundDrivenAppearance =>
      !inReading && !inMusic;
}

/// 音乐明暗的桥接（避免 `lib/common` 反向依赖 `lib/music`）
class MusicBrightnessBridge {
  MusicBrightnessBridge._();

  static bool Function()? _isDark;

  static void register(bool Function() fn) => _isDark = fn;

  static bool isDark() => _isDark?.call() ?? false;
}
