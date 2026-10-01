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
///
/// ── 三模块全局同步 ──────────────────────────────────────────────
/// 改 [set] 时，会通过 [GlobalThemeSync] 同步推给音乐和阅读模块，
/// 做到"一个开关，三处同时变"。
/// 音乐 / 阅读模块自己的开关如果被用户拨动，也会通过
/// [notifyModuleChanged] 回写到这里，保持全局一致。
class ThemeModeStore {
  static ValueNotifier<ThemeMode> notifier =
      ValueNotifier(ThemeMode.dark);

  /// true = 文字明暗由壁纸/背景自动推导（方案 A），此时忽略平台亮度同步。
  ///
  /// 不能复用 [ThemeMode.system] 表达"跟随背景"——那样 [syncFromPlatform]
  /// 会立刻把明暗改回系统亮度，背景推导结果会被覆盖掉。
  static bool get followBackground => _followBackground;
  static bool _followBackground = false;

  /// 防止递归：同步到模块 → 模块回调 notifyModuleChanged → 再 set 回去
  static bool _syncing = false;

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
    if (notifier.value == m && !_followBackground) return;
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
    // 同步到音乐和阅读模块（全局统一开关）
    if (!_syncing) {
      _syncing = true;
      try {
        GlobalThemeSync.pushToModules(m);
      } finally {
        _syncing = false;
      }
    }
  }

  /// 由音乐/阅读模块的开关回调（用户在模块内改了明暗），
  /// 回写到全局存储，保持三处一致。
  static Future<void> notifyModuleChanged(ThemeMode m) async {
    if (_syncing) return;
    if (notifier.value == m && !_followBackground) return;
    _syncing = true;
    try {
      await set(m);
    } finally {
      _syncing = false;
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

    // ── ⚠️ 还要推给音乐 / 阅读 ──────────────────────────────────
    //
    // 这里原先只改了 `AppBrightness` 和 notifier，**没有通知模块**。
    // 后果：选「跟随系统」时，用户在系统设置里切了深色，App 的整体明暗
    // 跟着变了（AppTheme 会变），但**音乐自己的皮肤不会变** ——
    // `MusicTheme._isDark` 停在旧值，于是浅色页面里配着深色文字。
    //
    // `set()` 那条路径本来就会推，但系统亮度变化**不走 set()**。
    if (!_syncing) {
      _syncing = true;
      try {
        GlobalThemeSync.pushToModules(ThemeMode.system);
      } finally {
        _syncing = false;
      }
    }
  }

  /// 外观亮度监听（App 外层包一层，浅/深色 getter 变更后整体重建）
  static ValueNotifier<bool> get brightnessListenable => AppBrightness.isLight;
}

/// 全局主题同步桥。
///
/// 把 [ThemeModeStore] 的明暗变更推给音乐和阅读模块，
/// 做到"一个开关，三处同时变"。
///
/// 为什么用回调桥：
///   · `lib/common` 不该直接依赖 `lib/music` / `lib/reading`
///   · 由 `main.dart` 在启动时注册真实实现
///   · 依赖方向保持：上层 → 各模块，底层干净
class GlobalThemeSync {
  GlobalThemeSync._();

  static void Function(ThemeMode mode)? _pushMusic;
  static void Function(ThemeMode mode)? _pushReading;

  /// 由 main.dart 注册音乐模块的明暗设置回调
  static void registerMusic(void Function(ThemeMode mode) fn) =>
      _pushMusic = fn;

  /// 由 main.dart 注册阅读模块的明暗设置回调
  static void registerReading(void Function(ThemeMode mode) fn) =>
      _pushReading = fn;

  /// 把新的模式推给所有已注册的模块
  static void pushToModules(ThemeMode mode) {
    _pushMusic?.call(mode);
    _pushReading?.call(mode);
  }
}
