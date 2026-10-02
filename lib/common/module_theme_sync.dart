import 'dart:async';

import 'package:flutter/material.dart';

import 'module_theme_store.dart';
import 'theme.dart';
import '../reading/theme/jelly_palette.dart';

/// 把 `ModuleThemeStore` 里选好的方案，实际推给各模块的主题入口。
///
/// ── 为什么要有这一层 ──────────────────────────────────────────
/// `ModuleThemeStore` 只**存**用户选了什么（presetId），
/// 它不该知道"影视用 AppTheme、音乐用 MusicTheme"这些细节 ——
/// 否则存储层就和各模块耦死，以后加模块还得改存储。
/// 所以同步逻辑抽在这里：**存储只管数据，这里负责落地**。
///
/// ── 同步了哪些 ────────────────────────────────────────────────
///   1. `AppTheme.applyPalette` —— 影视 + 直播（共用一套）
///   2. 音乐强调色（经 [MusicThemeBridge] 注入，避免反向依赖）
///   3. 阅读**不回写**：它有自己完整的一套（含自定义主题、背景动画、
///      图片背景）。这里只把它的当前值**读**进 store，
///      供"跟随阅读"解析 —— 回写就会覆盖用户在阅读主题页的设置。
Future<void> applyModuleThemes() async {
  final store = ModuleThemeStore.instance;

  // 1) 影视 + 直播：共用一套（两者同 PageView，永不同屏）
  AppTheme.applyPalette(
    store.paletteFor(ModuleThemeStore.video),
    module: ModuleThemeStore.video,
  );

  // 2) 音乐：把该方案的主色作为强调色
  MusicThemeBridge.applyAccent(
    store.paletteFor(ModuleThemeStore.music).primary,
  );

  // 3) ⚠️ 必须通知音乐侧重建。
  //
  // `MusicTheme.palette` / `_customAccent` 都是**静态 getter**，改了不会通知
  // 任何 widget；音乐模块唯一的重建入口是 `MusicThemeStore.instance.revision`。
  // 而负责 bump 它的 `notifyPaletteChanged()` 原来**全仓无人调用** ——
  // 结果在音乐页换配色时，只有选中的圆点移动了，底色/强调色要么不刷新、
  // 要么"新底色配旧强调色"。
  MusicThemeBridge.notifyPaletteChanged();
}

/// 音乐主题的桥接。
///
/// 为什么不直接 `import '../music/theme/music_theme.dart'`：
/// `lib/common` 是影视侧的底层，直接依赖 `lib/music` 会形成反向依赖
/// （音乐将来若独立出去会被这行卡住）。用一个"注入回调"的桥，
/// 依赖方向保持为"上层设置页 → 各模块"，底层干净。
class MusicThemeBridge {
  MusicThemeBridge._();

  /// 由 `main.dart` 注入真实实现（实现写在音乐模块侧）
  static void Function(Color primary)? _apply;

  /// 由 `main.dart` 注入"配色变了 → 重建音乐 UI"的回调
  static void Function()? _notify;

  static void register(void Function(Color primary) fn) => _apply = fn;

  static void registerNotify(void Function() fn) => _notify = fn;

  static void applyAccent(Color primary) => _apply?.call(primary);

  static void notifyPaletteChanged() => _notify?.call();
}

/// 阅读侧当前主题 id 的同步（**只读方向**）。
///
/// 阅读主题变化时调它，把新 id 告诉 store，
/// 这样选了"跟随阅读"的模块能立刻跟着变。
void syncReadingPresetToModules(String presetId) {
  final store = ModuleThemeStore.instance;
  final changed = store.readingPreset != presetId;
  store.syncReadingPreset(presetId);
  if (!changed) return;
  // ⚠️ 必须顺带把调色板重新落地一次。
  //
  // 原来只更新了 store 的 `revision`，而**全仓没有任何地方监听
  // `ModuleThemeStore.revision`** —— `AppTheme._palette` 因此停在旧预设：
  // 阅读页底色走 `Theme.of(context).scaffoldBackgroundColor`（旧调色板），
  // 而控件显式取的 `JellyTheme.*` 已是新调色板 → 同一屏两套配色。
  unawaited(applyModuleThemes());
}

/// 供 UI 展示的内置主题预设（直接转发阅读的列表，避免两处维护）
List<ThemePresetInfo> get readingThemePresets => themePresets;
