import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/background_service.dart';
import '../services/prefs_mirror.dart';
import 'theme.dart';

/// 全局主题模式：dark / light / system（设置页可改）
///
/// ── 单一真源 ────────────────────────────────────────────────────
/// 实际明暗（`AppBrightness.isLight`）**只**由本类的 [mode] + 平台亮度推出：
///   · [set] / [load] 时按模式直接定
///   · [syncFromPlatform] 时按平台亮度定（仅 `system` 模式）
///   · `app.dart` 构建时经 `AppearanceSync.applyForCurrentModule` 再对齐一次
///
/// 壁纸（[BackgroundService]）**只读**这个结果来决定渲染深色还是浅色那一套
/// 场景（见其 `isLight` / `_sceneKeyForCurrentAppearance`），**不再反向写入**。
/// 方向统一为「外观 → 壁纸」。
///
/// ── 三模块全局同步 ──────────────────────────────────────────────
/// 改 [set] 时，会通过 [GlobalThemeSync] 同步推给音乐和阅读模块，
/// 做到"一个开关，三处同时变"。
/// 音乐 / 阅读模块自己的开关如果被用户拨动，也会通过
/// [notifyModuleChanged] 回写到这里，保持全局一致。
///
/// ── 历史：为什么删掉了 `_followBackground` ──────────────────────
/// 这里曾有一个 `_followBackground` 标志，语义是"文字明暗跟随壁纸"。
/// 它由 [applyLightFromBackground]（壁纸回调）**无条件置真**，且不持久化。
/// 一旦置真就会：
///   · 让 [syncFromPlatform] 永远提前返回 → **「跟随系统」彻底失效**
///   · 让 `app.dart` 里 `themeMode == ThemeMode.system` 分支变成死代码
///   · 每次冷启动 `main.dart` 调 `setAppearanceMode` 都会把它重新闩死，
///     而三个设置入口都是「先 set() 清闩 → 再 setAppearanceMode() 上闩」，
///     于是用户选「跟随系统」后闩锁恒为真
/// 而壁纸场景本身已经通过 `AppBrightness` 跟随明暗，那个反向推送纯属多余。
/// 故连同 `followBackground` getter 一并删除。
class ThemeModeStore {
  /// ⚠️ 初始值必须是 `system`（用户 2026-10-07：「整个软件第一次打开，
  ///   默认的外观应该是跟随系统」）✗→✓
  /// 原来初始值写死 `ThemeMode.dark` ✗ —— 一旦 `load()` 里 SharedPreferences
  /// 读取抛异常（走 catch 分支），模式就永远停在深色 ✗。
  static ValueNotifier<ThemeMode> notifier =
      ValueNotifier(ThemeMode.system);

  /// 防止递归：同步到模块 → 模块回调 notifyModuleChanged → 再 set 回去
  static bool _syncing = false;

  static ThemeMode get mode => notifier.value;

  /// 按模式把明暗写进全局开关。
  ///
  /// `system` 分支**现读一次平台亮度**，不能写死 false ——
  /// 否则用户在浅色系统下选「跟随系统」的瞬间会先闪一下深色，
  /// 直到别的重建路径把它纠正回来。
  static void _syncBrightness(ThemeMode m) {
    final light = switch (m) {
      ThemeMode.light => true,
      ThemeMode.dark => false,
      ThemeMode.system =>
        PlatformDispatcher.instance.platformBrightness == Brightness.light,
    };
    AppBrightness.isLight.value = light;
  }

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // ✅ 首次打开（prefs 里还没有 `theme_mode`）默认 **跟随系统** ✓
      //    原来是 `?? 'dark'` ✗ —— 新装用户一进来就是深色，
      //    哪怕系统是浅色。用户 2026-10-07 明确要求改成跟随系统 ✓
      final v = prefs.getString('theme_mode') ?? 'system';
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

  static Future<void> set(ThemeMode m, {String? origin}) async {
    if (notifier.value == m) return;
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
      // 与其它设置项一致：改完立刻落盘 + 写镜像快照。原来漏挂这个钩子 ⇒
      // 「改完明暗马上划掉 App」时改动不在镜像里，重启可能被旧值回退。
      PrefsMirror.snapshotSoon();
    } catch (e) {
      /* ignore */
    }
    // 同步到音乐和阅读模块（全局统一开关）
    if (!_syncing) {
      _syncing = true;
      try {
        GlobalThemeSync.pushToModules(m, except: origin);
      } finally {
        _syncing = false;
      }
    }
  }

  /// 由音乐/阅读模块的开关回调（用户在模块内改了明暗），
  /// 回写到全局存储，保持三处一致。
  ///
  /// [origin] 是发起模块（`GlobalThemeSync.music` / `.reading`）：
  /// 只跳过它自己，**其余模块照常同步**。
  static Future<void> notifyModuleChanged(ThemeMode m, {String? origin}) async {
    // `_syncing` 为真 = 正在把变更推给各模块，此时模块的回声要忽略（防递归）
    if (_syncing) return;
    if (notifier.value == m) return;
    // ⚠️ 不要把 [set] 包在 `_syncing = true` 里。
    //
    // 原来这里先置 `_syncing = true` 再 `await set(m)`，而 `set` 内部是
    // `if (!_syncing) pushToModules(...)` —— 于是从模块发起的变更
    // **一个模块都不会被通知**："音乐里改明暗，阅读不跟着变"，
    // 与"一个开关，三处同时变"的承诺相反。
    // 现在改由 [origin] 精确跳过发起方。
    await set(m, origin: origin);
  }

  /// 平台亮度变化 / 需要重新对齐时调用。
  ///
  /// 只有 `system` 模式才由平台亮度决定明暗；其它模式以用户选择为准。
  static void syncFromPlatform(bool platformLight) {
    if (notifier.value != ThemeMode.system) return;
    if (AppBrightness.isLight.value == platformLight) return;
    // 改 `AppBrightness` 就会触发外观相关重建（app.dart 内层
    // ValueListenableBuilder 监听的正是它），不需要再动 notifier。
    AppBrightness.isLight.value = platformLight;

    // ── ⚠️ 还要推给音乐 / 阅读 ──────────────────────────────────
    //
    // `set()` 那条路径本来就会推，但系统亮度变化**不走 set()**。
    // 不推的话：选「跟随系统」时用户在系统设置里切了深色，App 整体明暗
    // 跟着变了（AppTheme 会变），但**音乐自己的皮肤不会变** ——
    // `MusicTheme._isDark` 停在旧值，于是浅色页面里配着深色文字。
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

  /// 模块来源标识（用于"推给别人、跳过自己"）
  static const String video = 'video';
  static const String music = 'music';
  static const String reading = 'reading';

  static void Function(ThemeMode mode)? _pushMusic;
  static void Function(ThemeMode mode)? _pushReading;

  /// 由 main.dart 注册音乐模块的明暗设置回调
  static void registerMusic(void Function(ThemeMode mode) fn) =>
      _pushMusic = fn;

  /// 由 main.dart 注册阅读模块的明暗设置回调
  static void registerReading(void Function(ThemeMode mode) fn) =>
      _pushReading = fn;

  /// 把新的模式推给所有已注册的模块。
  ///
  /// [except] 传发起模块的标识即可跳过它自己（避免回声），
  /// 其余模块仍会收到通知。
  static void pushToModules(ThemeMode mode, {String? except}) {
    if (except != music) _pushMusic?.call(mode);
    if (except != reading) _pushReading?.call(mode);
  }
}
