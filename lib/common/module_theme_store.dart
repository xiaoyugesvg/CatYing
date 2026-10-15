import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../reading/theme/jelly_palette.dart';
import '../services/prefs_mirror.dart';

/// 每个模块用哪套配色方案。
///
/// ── 为什么要"分模块"存，而不是全局一套 ──────────────────────────
/// 影视、直播、音乐、阅读是四种**信息密度和用眼场景都不同**的界面：
///   · 影视：缩略图为主，适合中性底色
///   · 音乐：大面积封面 + 播放控件，适合暖一点
///   · 阅读：长时间看字，必须低对比
/// 所以用户很可能希望"影视用蓝色海洋、阅读用水墨书香"。
/// 一个全局开关做不到这件事，于是这里按模块各存一个 presetId。
///
/// ── 与阅读模块的关系（重要）───────────────────────────────────
/// 阅读模块**已经有自己的主题存储**（`SettingsService.themePreset`，
/// 还支持自定义主题、背景动画、图片背景）。这里**不接管**它 ——
/// 否则用户在阅读设置里改的东西会被这个新存储覆盖掉，等于把已有功能弄坏。
/// 本存储只负责**影视 / 直播 / 音乐**三个模块，
/// 阅读那一格只是"把用户导向阅读已有的主题页"。
///
/// ── 取值 ─────────────────────────────────────────────────────
/// * `presetId` 对应 `JellyPalette.fromPreset()` 认的 id
///   （ink/jelly/pink/green/ocean/sunset/sky）。
/// * `""`（空串）= 「跟随阅读」：直接用阅读当前的主题，
///   这样用户只调一处，全 App 统一。
class ModuleThemeStore {
  ModuleThemeStore._();
  static final ModuleThemeStore instance = ModuleThemeStore._();

  /// 模块 key
  static const String video = 'video';
  static const String live = 'live';
  static const String music = 'music';

  static const _kPrefix = 'module_theme_';

  /// 「跟随阅读」的哨兵值（不是合法 presetId）
  static const String followReading = '';

  final Map<String, String> _presets = {
    video: followReading,
    live: followReading,
    music: followReading,
  };

  /// 变更通知：UI 与本模块主题都监听它重建
  final revision = ValueNotifier<int>(0);

  /// 阅读模块当前的主题 id（由 main.dart 从 SettingsService 同步进来）。
  ///
  /// 为什么不直接读 `SettingsService().themePreset`：
  /// 那会把 `lib/reading` 的服务依赖拖进 `lib/common`，
  /// 而影视侧本来是独立的一层。这里用"同步一个值"的方式解耦。
  String _readingPreset = 'ink';
  String get readingPreset => _readingPreset;

  /// 由 main.dart 在阅读主题变化时调用
  void syncReadingPreset(String id) {
    if (id == _readingPreset) return;
    _readingPreset = id;
    revision.value++;
  }

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final k in _presets.keys) {
        final v = prefs.getString('$_kPrefix$k');
        if (v != null) _presets[k] = v;
      }
    } catch (e) {
      debugPrint('[ModuleTheme] 加载失败: $e');
    }
    revision.value++;
  }

  /// 某个模块当前**实际生效**的 presetId（解析"跟随阅读"）
  String effectivePreset(String module) {
    final v = _presets[module] ?? followReading;
    return v == followReading ? _readingPreset : v;
  }

  /// 某个模块**用户设置**的值（可能是 followReading）
  String rawPreset(String module) => _presets[module] ?? followReading;

  bool isFollowingReading(String module) =>
      rawPreset(module) == followReading;

  /// 该模块当前生效的调色板
  JellyPalette paletteFor(String module) =>
      JellyPalette.fromPreset(effectivePreset(module));

  Future<void> setPreset(String module, String presetId) async {
    if (_presets[module] == presetId) return;
    _presets[module] = presetId;
    revision.value++;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('$_kPrefix$module', presetId);
      // 与其它设置项一致：改完立刻落盘 + 写镜像快照（见 PrefsMirror 顶部说明）。
      PrefsMirror.snapshotSoon();
    } catch (e) {
      debugPrint('[ModuleTheme] 保存失败: $e');
    }
  }

  /// 全部恢复「跟随阅读」
  Future<void> resetAll() async {
    for (final k in _presets.keys) {
      _presets[k] = followReading;
    }
    revision.value++;
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final k in _presets.keys) {
        await prefs.remove('$_kPrefix$k');
      }
      PrefsMirror.snapshotSoon();
    } catch (_) {}
  }
}
