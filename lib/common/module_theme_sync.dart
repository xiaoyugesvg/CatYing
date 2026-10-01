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

  static void register(void Function(Color primary) fn) => _apply = fn;

  static void applyAccent(Color primary) => _apply?.call(primary);
}

/// 阅读侧当前主题 id 的同步（**只读方向**）。
///
/// 阅读主题变化时调它，把新 id 告诉 store，
/// 这样选了"跟随阅读"的模块能立刻跟着变。
void syncReadingPresetToModules(String presetId) {
  ModuleThemeStore.instance.syncReadingPreset(presetId);
}

/// 供 UI 展示的内置主题预设（直接转发阅读的列表，避免两处维护）
List<ThemePresetInfo> get readingThemePresets => themePresets;
