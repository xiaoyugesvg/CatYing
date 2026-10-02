import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../reading/services/settings_service.dart';
import '../services/main_tab_controller.dart';
import 'theme.dart';
import 'theme_mode_store.dart';

/// 统一"当前该用浅色还是深色"，并把结果写进全局 [AppBrightness]。
///
/// ── 单一真源 ────────────────────────────────────────────────────
/// 明暗**只**由「设置 → 主题与外观 → 明暗模式」的 [ThemeModeStore] 决定：
///   · `light` / `dark`  → 用户显式选择
///   · `system`          → 现读平台亮度
///
/// 音乐 / 阅读模块自己的明暗开关**不在这里覆盖全局** —— 它们经
/// `GlobalThemeSync` 写回 [ThemeModeStore]（见 `music_theme.dart` 的
/// `_syncBackToGlobal` 与 `settings_service.dart` 的 `notifyModuleChanged`），
/// 再走回本类，方向是"模块 → 全局 → 所有模块"。
///
/// ── 历史：为什么删掉了"谁在前台谁说话" ──────────────────────────
/// 本类曾按"当前在哪个 tab"决定用哪套设置（阅读用 `SettingsService.isDarkMode`、
/// 音乐用 `MusicBrightnessBridge`）。它有两个致命问题：
///   1. `AppBrightness.isLight` 是**一根全局开关**，而 `ContentView` 的
///      `IndexedStack` 同时保留 7 个 tab 的 subtree —— 在音乐里切一下 tab
///      就会把全局明暗改掉，所有还活着的 tab 跟着变色；
///   2. 那套"按 tab 覆盖"的分支实际**从未生效**：`start()` 在 `main()` 里
///      调用，那时 `MainTabController` 还没注册（它在 `TVBoxApp.build` 里
///      `Get.put`），`start()` 直接在守卫处 return，监听器从未注册。
/// 故连同 `_moduleOverride` / `isModuleOverride` / `inMusic` /
/// `allowBackgroundDrivenAppearance` / `MusicBrightnessBridge` 一并删除。
class AppearanceSync {
  AppearanceSync._();

  /// 当前生效（已被本类写进 `AppBrightness` 的）明暗
  static bool _current = false;
  static bool get current => _current;

  /// 由 `app.dart` 在算出影视那套的 effectiveLight 后调用（微任务里）。
  ///
  /// [videoEffectiveLight] 是「设置 → 主题与外观」算出来的结果；
  /// `system` 模式下忽略它，现读平台亮度 ——
  /// 否则「跟随系统」会永远停在启动时的那个值。
  static void applyForCurrentModule({required bool videoEffectiveLight}) {
    final light = ThemeModeStore.mode == ThemeMode.system
        ? PlatformDispatcher.instance.platformBrightness == Brightness.light
        : videoEffectiveLight;

    set(light);
  }

  /// 当前是否停在阅读模块
  static bool get inReading => _tabIndex() == MainTabController.booksTabIndex;

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

  /// 由 `TVBoxApp.initState` 调用（**必须在 `MainTabController` 注册之后**）。
  ///
  /// 之前它由 `main()` 调用，那时 `MainTabController` 尚未注册，守卫直接
  /// return —— 阅读侧监听从未生效，这也是"阅读里改明暗不生效"的一个成因。
  static void start() {
    // 阅读设置变化（用户在阅读里拨了跟随系统/明暗开关）立刻生效。
    // 注意：这条边不依赖 tab，先注册，别被下面的守卫挡掉。
    SettingsService().addListener(_onReadingSettingsChanged);

    if (!Get.isRegistered<MainTabController>()) return;
    // 切 tab 时重新协调一次（进入系统模式 / 平台亮度变化后的兜底）
    ever(MainTabController.instance.selectedTab, (_) {
      applyForCurrentModule(videoEffectiveLight: _current);
    });
  }

  static void _onReadingSettingsChanged() {
    if (inReading) applyForCurrentModule(videoEffectiveLight: _current);
  }
}
