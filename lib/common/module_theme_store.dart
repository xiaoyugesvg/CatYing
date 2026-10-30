import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/reading/theme/jelly_palette.dart';
import 'package:tvbox/services/prefs_mirror.dart';

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
///   （内置预设共 24 套，见 `themePresets`；含 ink/jelly/节日/「公认最美」系列）。
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

  /// 自定义主题 id → 调色板（由 main.dart 注入）。
  ///
  /// [JellyPalette.fromPreset] 只认识内置预设，未知 id 一律回退「魅力紫」——
  /// 而自定义主题的 id 是 `custom_xxx`，于是「阅读用自定义主题 + 影视跟随阅读」
  /// 时影视会莫名变成紫色。这里留一个钩子让上层注入真实解析。
  /// 返回 null 表示"不是自定义主题"，继续走内置预设。
  JellyPalette? Function(String id)? customPaletteResolver;

  /// 自定义主题 id → 展示名（由 main.dart 注入）。
  ///
  /// 同理：`custom_1730000000000_0` 这种 id **绝对不能**直接显示给用户。
  /// 返回 null 表示"不是自定义主题 / 已删除"。
  String? Function(String id)? customNameResolver;

  /// 该模块当前生效的调色板
  JellyPalette paletteFor(String module) => paletteOf(effectivePreset(module));

  /// 任意 presetId 的调色板（先查自定义主题，再回退内置预设）。
  ///
  /// 设置页画「三色点」时用的就是它 —— 不能直接
  /// `JellyPalette.fromPreset(id)`，否则自定义主题会显示成紫色色点。
  JellyPalette paletteOf(String id) =>
      customPaletteResolver?.call(id) ?? JellyPalette.fromPreset(id);

  /// 任意 presetId 的展示名（内置名 → 自定义名 → 兜底）。
  ///
  /// 空串 = 「跟随阅读」；未知 id 原样返回（除 `custom_*` 显示为「自定义主题」）。
  String displayNameOf(String id) {
    if (id.isEmpty) return '跟随阅读';
    for (final p in themePresets) {
      if (p.id == id) return p.name;
    }
    final custom = customNameResolver?.call(id);
    if (custom != null && custom.isNotEmpty) return custom;
    return id.startsWith('custom_') ? '自定义主题' : id;
  }

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
