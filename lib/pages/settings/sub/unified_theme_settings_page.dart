import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/module_theme_store.dart';
import '../../../common/module_theme_sync.dart';
import '../../../common/theme.dart';
import '../../../common/theme_mode_store.dart';
import '../../../services/background_service.dart';
import '../../../reading/services/settings_service.dart';
import '../../../reading/theme/jelly_palette.dart';
import '../wallpaper_page.dart';
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

        // ── 壁纸与背景 ────────────────────────────────────────
        //
        // ⚠️ 这个入口**必须留在这里**。
        // 我上一轮把设置页的「外观与壁纸」改指到本页时漏搬了它，
        // 结果壁纸功能代码全在、用户却点不到 ——
        // 表现就是"我原先的壁纸功能呢？"。
        // 统合页面时漏搬入口是典型事故，所以这里单列一张卡 + 加注释。
        _wallpaperCard(),
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
        const SizedBox(height: AppTheme.spacingSM),

        // ── 还原默认主题（#16）────────────────────────────────
        //
        // 和上面那个「恢复跟随阅读」是**两回事**：
        //   · 恢复跟随阅读 = 三个模块都跟着阅读走（阅读自己的配色不动）
        //   · 还原默认主题 = 全部回到出厂状态（水墨书香 + 深色 + 默认壁纸）
        // 原来只有前者，用户改乱了之后没有"一键回出厂"的入口。
        _factoryResetCard(),
      ],
    );
  }

  /// #16：还原默认主题（真·出厂恢复）
  Widget _factoryResetCard() {
    return Align(
      alignment: Alignment.center,
      child: TextButton.icon(
        onPressed: () async {
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('还原默认主题'),
              content: const Text(
                '会把外观恢复到初始状态：\n\n'
                '· 阅读配色 → 水墨书香\n'
                '· 影视 / 直播 / 音乐 → 跟随阅读\n'
                '· 明暗模式 → 深色\n'
                '· 壁纸 → 默认（深邃黑）\n\n'
                '你自己新建的自定义配色**不会被删除**，'
                '只是不再被选中。',
                style: TextStyle(fontSize: 13, height: 1.7),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('还原'),
                ),
              ],
            ),
          );
          if (ok != true) return;
          await _factoryReset();
        },
        icon: const Icon(Icons.settings_backup_restore_rounded, size: 16),
        label: const Text('还原默认主题（出厂状态）'),
      ),
    );
  }

  /// 执行还原：阅读配色 + 各模块跟随 + 明暗 + 壁纸
  ///
  /// 顺序讲究：先改配色（会刷新调色板），再改明暗（会换壁纸那一套），
  /// 最后统一 apply 一次 —— 避免中间态被渲染出来又立刻被覆盖。
  Future<void> _factoryReset() async {
    // 1) 阅读配色回水墨书香（'ink' 是默认 preset id）
    await SettingsService().setThemePreset('ink');
    // 2) 三个模块恢复「跟随阅读」
    await store.resetAll();
    // 3) 明暗回深色（与出厂的默认壁纸「深邃黑」配套）
    await ThemeModeStore.set(ThemeMode.dark);
    await BackgroundService.instance
        .setAppearanceMode(AppearanceMode.dark);
    // 4) 统一把调色板推给 AppTheme + 音乐
    await _afterPresetChanged();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已还原默认主题'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  // ============================================================
  // 明暗模式：浅色 / 跟随系统 / 深色
  // ============================================================

  Widget _modeCard() {
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
          Builder(builder: (context) {
            // ── 三个选项：浅色 / 深色 / 跟随系统 ──────────────────
            //
            // ⚠️ 这里原来**只有两个**（浅色/深色）——
            // 旧版 AppearanceSettingsPage 是有「跟随系统」的，统一页漏了。
            //
            // 而且旧版的「跟随系统」是**假的**：它底层写
            //   `selected == ThemeMode.light ? light : dark`
            // —— ThemeMode.system 会被当成 **dark**（壁纸也跟着错）。
            //
            // 正确做法：`ThemeModeStore` 本来就能存/读 'system'
            // （它的 _syncBrightness 会用平台亮度），
            // 所以这里存 system，并按**当前平台亮度**去选壁纸那一套
            // （AppearanceMode 枚举只有 light/dark —— 壁纸只有两套，
            //   没有"跟随系统"这一套，这是有意的）。
            final m = ThemeModeStore.mode;
            final sel = switch (m) {
              ThemeMode.light => 0,
              ThemeMode.dark => 1,
              ThemeMode.system => 2,
            };
            return _chips(
              labels: const ['浅色', '深色', '跟随系统'],
              selectedIndex: sel,
              onPick: (i) async {
                final target = switch (i) {
                  0 => ThemeMode.light,
                  1 => ThemeMode.dark,
                  _ => ThemeMode.system,
                };
                await ThemeModeStore.set(target);
                // 壁纸那套按"实际该显示的明暗"选：
                //   浅色→light；深色→dark；跟随系统→看平台亮度
                final wantLight = switch (target) {
                  ThemeMode.light => true,
                  ThemeMode.dark => false,
                  ThemeMode.system =>
                    MediaQuery.of(context).platformBrightness ==
                        Brightness.light,
                };
                await BackgroundService.instance.setAppearanceMode(
                  wantLight ? AppearanceMode.light : AppearanceMode.dark,
                );
                if (mounted) setState(() {});
              },
            );
          }),
        ],
      ),
    );
  }

  // ============================================================
  // 壁纸与背景（跳回原壁纸设置页 —— 它有 29KB，含内置渐变/本地图片/
  // 网络图片/自定义接口/不透明度/模糊，不适合搬进来重写）
  // ============================================================

  Widget _wallpaperCard() {
    final bg = BackgroundService.instance;
    return GestureDetector(
      onTap: () => Get.to(() => const WallpaperSettingsPage()),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: AppTheme.backgroundSecondary,
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
        ),
        child: Row(
          children: [
            Icon(Icons.wallpaper_outlined,
                size: 18, color: AppTheme.accentColor),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('壁纸与背景',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary)),
                  const SizedBox(height: 4),
                  // 与旧「外观」页一样显示当前壁纸名（Obx 跟随变化）
                  Obx(() => Text(
                        bg.wallpaperDisplayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: AppTheme.textTertiary),
                      )),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                size: 20, color: AppTheme.textTertiary),
          ],
        ),
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
              // #14：和上面三个「可调」分区区分开。
              // 上面三个分区下面是**配色圆点**（能直接点着改）；
              // 阅读这一块只能**跳转**去它自己的主题页 ——
              // 原来两者长得一样，用户会以为这里也能直接改，
              // 点进去才发现跳页了。
              //
              // 这里加一个明确的「入口」徽标 + 用箭头图标表达"要跳走"。
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.open_in_new_rounded,
                        size: 10, color: AppTheme.accentColor),
                    const SizedBox(width: 3),
                    Text('入口',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.accentColor)),
                  ],
                ),
              ),
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
          // ⚠️ 原来点一下**直接生效**，没有确认 —— 误触就把三个模块的
          // 配色全改了，而且用户不一定记得原来选的是什么。
          // 这里加二次确认，并把"会改什么"写清楚。
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('恢复「跟随阅读」'),
              content: const Text(
                '影视 · 直播 · 音乐 三个模块的配色会全部改为「跟随阅读」，'
                '也就是与阅读当前的配色一致。\n\n'
                '阅读自己的配色不会被改动。',
                style: TextStyle(fontSize: 13, height: 1.6),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('恢复'),
                ),
              ],
            ),
          );
          if (ok != true) return;
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
