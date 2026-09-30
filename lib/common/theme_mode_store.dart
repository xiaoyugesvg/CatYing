import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/background_service.dart';
import 'theme.dart';

/// 全局主题模式：dark / light / system（设置页可改）
///
/// 与 [BackgroundService] 的「壁纸 + 外观联动」关系：
/// - 背景决定文字明暗（方案 A）：选到皎月白这类浅色底时自动切浅色文字。
///   推导由 BackgroundService 负责，结果通过 [applyLightFromBackground] 推过来。
/// - 用户手动选 = 打开手动覆盖标记，之后背景变化不再自动改文字颜色。
class ThemeModeStore {
  static ValueNotifier<ThemeMode> notifier =
      ValueNotifier(ThemeMode.dark);

  /// true = 文字明暗由壁纸/背景自动推导（方案 A），此时忽略平台亮度同步。
  ///
  /// 不能复用 [ThemeMode.system] 表达"跟随背景"——那样 [syncFromPlatform]
  /// 会立刻把明暗改回系统亮度，背景推导结果会被覆盖掉。
  static bool get followBackground => _followBackground;
  static bool _followBackground = false;

  static ThemeMode get mode => notifier.value;

  static void _syncBrightness(ThemeMode m, {bool? systemLight}) {
    final light = switch (m) {
      ThemeMode.light => true,
      ThemeMode.dark => false,
      ThemeMode.system => systemLight ?? false,
    };
    AppBrightness.isLight.value = light;
  }

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString('theme_mode') ?? 'dark';
      notifier.value = switch (v) {
        'light' => ThemeMode.light,
        'system' => ThemeMode.system,
        _ => ThemeMode.dark,
      };
      _syncBrightness(notifier.value);
    } catch (e) {
      /* ignore */
    }
  }

  static Future<void> set(ThemeMode m) async {
    _followBackground = false;
    notifier.value = m;
    _syncBrightness(m);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'theme_mode',
        switch (m) {
          ThemeMode.light => 'light',
          ThemeMode.system => 'system',
          _ => 'dark',
        },
      );
    } catch (e) {
      /* ignore */
    }
  }

  /// 由壁纸/背景推导结果驱动文字明暗（方案 A）。
  ///
  /// 不走 [set]：这是"跟随背景"而非用户手动选择 —— 保留 [themeMode] 原值
  /// 以免下次关闭跟随背景时丢掉用户上次的手动选择，只切实际明暗。
  static void applyLightFromBackground(bool isLight) {
    _followBackground = true;
    AppBrightness.isLight.value = isLight;
  }

  /// 跟随系统时调用（View 平台亮度变化）
  static void syncFromPlatform(bool platformLight) {
    // 背景推导优先：此时明暗由壁纸决定，不能被系统亮度覆盖
    if (_followBackground) return;
    if (notifier.value != ThemeMode.system) return;
    if (AppBrightness.isLight.value == platformLight) return;
    AppBrightness.isLight.value = platformLight;
    // 触发 ValueListenableBuilder / 外观相关重建
    notifier.value = ThemeMode.system;
  }

  /// 外观亮度监听（App 外层包一层，浅/深色 getter 变更后整体重建）
  static ValueNotifier<bool> get brightnessListenable => AppBrightness.isLight;
}
