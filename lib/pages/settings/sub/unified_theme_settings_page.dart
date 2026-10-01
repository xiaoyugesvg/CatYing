import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/module_theme_store.dart';
import '../../../common/module_theme_sync.dart';
import '../../../common/theme.dart';
import '../../../common/theme_mode_store.dart';
import '../../../services/background_service.dart';
import '../../../reading/theme/jelly_palette.dart';
import 'settings_shared.dart';

/// 统一主题设置 —— 一个页面里分别调**影视/直播、音乐、阅读**的风格。
///
/// ── 为什么合并成一个页面 ──────────────────────────────────────
/// 原来"外观"分散在三处、彼此不知道对方存在：
///   · 影视：设置 → 外观（只有浅色/深色/跟随系统，**没有配色方案**）
///   · 音乐：音乐模块 → 我的（自己的 10 种强调色）
///   · 阅读：阅读 → 我的 → 主题风格（7 套完整主题 + 自定义颜色）
/// 用户想"三块风格统一"时得在三处来回翻，而且**改不了一致**。
/// 现在汇总到这里，但仍**分区独立可调**（用户明确要求"能分开调整"）。
///
/// ── 边界（重要）───────────────────────────────────────────────
///   · **影视 + 直播共用一套**：它们在同一 PageView 里，永不同屏，
///     共用没有视觉冲突（详见 AppTheme 里的说明）
///   · **音乐独立**：走 `ModuleThemeStore`
///   · **阅读不在这页改**：它已有完整的主题页（含自定义颜色、背景动画、
///     图片背景）。这里只**给入口 + 显示当前值**，
///     否则会把用户在那边的设置覆盖掉 —— 那等于弄坏已有功能。
class UnifiedThemeSettingsPage extends StatefulWidget {
  const UnifiedThemeSettingsPage({super.key});

  @override
  State<UnifiedThemeSettingsPage> createState() =>
      _UnifiedThemeSettingsPageState();
}

class _UnifiedThemeSettingsPageState extends State<UnifiedThemeSettingsPage> {
  final store = ModuleThemeStore.instance;

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '主题与外观',
      children: [
        // ── 全局：明暗模式（自绘三选一，与下方配色分区同一套视觉）──
        _modeCard(),
        const SizedBox(height: AppTheme.spacingMD),

        // ── 影视 · 直播 ───────────────────────────────────────
        _moduleSection(
          icon: Icons.movie_outlined,
          title: '影视 · 直播',
          subtitle: '两者共用一套配色（不会同屏显示）',
          module: ModuleThemeStore.video,
        ),

        // ── 音乐 ─────────────────────────────────────────────
        _moduleSection(
          icon: Icons.music_note_outlined,
          title: '音乐',
          subtitle: '独立配色，可与其他模块不同',
          module: ModuleThemeStore.music,
        ),

        // ── 阅读（只给入口，不改它的主题）──────────────────────
        _readingSection(),

        const SizedBox(height: AppTheme.spacingMD),
        _resetCard(),
      ],
    );
  }

  // ============================================================
  // 明暗模式：浅色 / 跟随系统 / 深色
  // ============================================================

  Widget _modeCard() {
    final mode = AppBrightness.isLight.value;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.brightness_6_outlined,
                  size: 18, color: AppTheme.accentColor),
              const SizedBox(width: 8),
              Text('明暗模式',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '作用于全 App；阅读模块也跟随它（阅读里另有独立开关）',
            style: TextStyle(fontSize: 12, color: AppTheme.textTertiary),
          ),
          const SizedBox(height: 12),
          _chips(
            labels: const ['浅色', '深色'],
            selectedIndex: mode ? 0 : 1,
            onPick: (i) async {
              // 复用影视既有的外观链路（ThemeModeStore + BackgroundService）：
              // 它同时管"文字明暗"与"用哪套背景"，只改 AppBrightness
              // 会导致壁纸联动失效。
              await ThemeModeStore.set(
                i == 0 ? ThemeMode.light : ThemeMode.dark,
              );
              await BackgroundService.instance.setAppearanceMode(
                i == 0 ? AppearanceMode.light : AppearanceMode.dark,
              );
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 一个模块的配色分区
  // ============================================================

  Widget _moduleSection({
    required IconData icon,
    required String title,
    required String subtitle,
    required String module,
  }) {
    final current = store.rawPreset(module);
    final effective = store.effectivePreset(module);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.spacingMD),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        decoration: BoxDecoration(
          color: AppTheme.backgroundSecondary,
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: AppTheme.accentColor),
                const SizedBox(width: 8),
                Text(title,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary)),
                const Spacer(),
                Text(
                  _presetName(effective),
                  style: TextStyle(fontSize: 12, color: AppTheme.textTertiary),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(subtitle,
                style: TextStyle(fontSize: 12, color: AppTheme.textTertiary)),
            const SizedBox(height: 12),
            // 「跟随阅读」+ 7 套预设
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _followChip(module, current),
                for (final p in readingThemePresets)
                  _presetDot(
                    module: module,
                    presetId: p.id,
                    name: p.name,
                    selected: current == p.id,
                    palette: p.palette,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _followChip(String module, String current) {
    final on = current == ModuleThemeStore.followReading;
    return GestureDetector(
      onTap: () async {
        await store.setPreset(module, ModuleThemeStore.followReading);
        await _afterPresetChanged();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: on
              ? AppTheme.accentColor.withValues(alpha: 0.14)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: on
                ? AppTheme.accentColor
                : AppTheme.borderLight,
          ),
        ),
        child: Text(
          '跟随阅读',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: on ? FontWeight.w600 : FontWeight.normal,
            color: on ? AppTheme.accentColor : AppTheme.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _presetDot({
    required String module,
    required String presetId,
    required String name,
    required bool selected,
    required JellyPalette palette,
  }) {
    return GestureDetector(
      onTap: () async {
        await store.setPreset(module, presetId);
        await _afterPresetChanged();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              // 色块用该预设的"主色 + 浅色底 + 深色底"三色环，像阅读的主题列表
              gradient: SweepGradient(colors: [
                palette.backgroundLight,
                palette.primary,
                palette.backgroundDark,
                palette.accent,
                palette.backgroundLight,
              ]),
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? AppTheme.accentColor : AppTheme.borderLight,
                width: selected ? 2.5 : 1,
              ),
            ),
            child: selected
                ? Icon(Icons.check,
                    size: 16,
                    color: palette.backgroundLight.computeLuminance() > 0.5
                        ? Colors.black
                        : Colors.white)
                : null,
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: 52,
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 9.5,
                color: selected ? AppTheme.accentColor : AppTheme.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 阅读：只给入口（它有自己的完整主题页）
  // ============================================================

  Widget _readingSection() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.menu_book_outlined,
                  size: 18, color: AppTheme.accentColor),
              const SizedBox(width: 8),
              Text('阅读',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary)),
              const Spacer(),
              Text(_presetName(store.readingPreset),
                  style: TextStyle(fontSize: 12, color: AppTheme.textTertiary)),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            // 说清为什么这页不直接改阅读：它那边有更多东西（自定义颜色、
            // 背景动画、图片背景），搬过来会丢功能。
            '阅读有独立主题页（含自定义颜色、背景动画、图片背景），请到「阅读 → 我的 → 主题风格」调整',
            style: TextStyle(
                fontSize: 12, height: 1.5, color: AppTheme.textTertiary),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => Get.to(() => const _ReadingThemeHintPage()),
              icon: const Icon(Icons.open_in_new_rounded, size: 16),
              label: const Text('去阅读主题风格'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resetCard() {
    return Align(
      alignment: Alignment.center,
      child: TextButton.icon(
        onPressed: () async {
          await store.resetAll();
          await _afterPresetChanged();
        },
        icon: const Icon(Icons.restart_alt_rounded, size: 16),
        label: const Text('影视/直播/音乐 全部恢复「跟随阅读」'),
      ),
    );
  }

  /// 切换完统一刷新一次（把新调色板推给 AppTheme + 音乐）
  Future<void> _afterPresetChanged() async {
    await applyModuleThemes();
    if (mounted) setState(() {});
  }

  // ============================================================
  // 小工具
  // ============================================================

  String _presetName(String id) {
    for (final p in readingThemePresets) {
      if (p.id == id) return p.name;
    }
    return id.isEmpty ? '跟随阅读' : id;
  }

  /// 一排胶囊（复用阅读的选中样式：实底 + 反白字）
  Widget _chips({
    required List<String> labels,
    required int selectedIndex,
    required void Function(int) onPick,
  }) {
    return Row(
      children: [
        for (var i = 0; i < labels.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: GestureDetector(
              onTap: () => onPick(i),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: i == selectedIndex
                      ? AppTheme.accentColor
                      : AppTheme.backgroundTertiary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  labels[i],
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: i == selectedIndex
                        ? FontWeight.w600
                        : FontWeight.normal,
                    color: i == selectedIndex
                        ? (AppTheme.accentColor.computeLuminance() > 0.5
                            ? Colors.black
                            : Colors.white)
                        : AppTheme.textSecondary,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 「阅读主题」的跳转占位页。
///
/// 为什么不做成"直接把阅读主题页搬进来"：
/// 阅读主题页 `MePage` → 主题风格弹层里有自定义主题编辑器、
/// 背景图片选择等，那些依赖阅读自己的 context 与状态。
/// 与其复制一份（必然与原页分叉），不如明确引导过去。
class _ReadingThemeHintPage extends StatelessWidget {
  const _ReadingThemeHintPage();

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '阅读主题风格',
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '请通过底部导航进入「阅读」模块，再点「我的 → 主题风格」调整。\n\n'
            '那里提供 7 套预设主题（水墨书香 / 魅力紫色 / 粉色少女 / 清新护眼 / '
            '蓝色海洋 / 落日余晖 / 蓝色天空）、自定义颜色编辑器，'
            '以及纯色 / 内置动画 / 自定义图片三种背景。',
            style: TextStyle(
              fontSize: 13,
              height: 1.7,
              color: AppTheme.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
