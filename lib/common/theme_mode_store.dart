import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme.dart';

/// 全局主题模式：dark / light / system（设置页可改）
class ThemeModeStore {
  static final ValueNotifier<ThemeMode> notifier =
      ValueNotifier(ThemeMode.dark);

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

  /// 跟随系统时调用（View 平台亮度变化）
  static void syncFromPlatform(bool platformLight) {
    if (notifier.value == ThemeMode.system) {
      AppBrightness.isLight.value = platformLight;
    }
  }
}
