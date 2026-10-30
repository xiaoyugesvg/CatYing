import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:tvbox/common/module_theme_store.dart';
import 'package:tvbox/common/module_theme_sync.dart';
import 'package:tvbox/common/theme.dart';
import 'package:tvbox/common/theme_mode_store.dart';
import 'package:tvbox/services/background_service.dart';
import 'package:tvbox/reading/services/settings_service.dart';
import 'package:tvbox/pages/settings/wallpaper_page.dart';
import 'package:tvbox/pages/settings/sub/settings_shared.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/widgets/common_widgets.dart';
import 'package:tvbox/widgets/theme_preset_row.dart';

/// 统一主题设置 —— 一个页面里分别调**影视/直播、音乐、阅读**的风格。
///
/// ── 为什么合并成一个页面 ──────────────────────────────────────
/// 原来"外观"分散在三处、彼此不知道对方存在：
///   · 影视：设置 → 外观（只有浅色/深色/跟随系统，**没有配色方案**）
///   · 音乐：音乐模块 → 我的（自己的 10 种强调色）
///   · 阅读：阅读 → 我的 → 主题风格（24 套完整主题 + 自定义颜色）
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
      help: const [
        SettingsHelpItem(
          icon: Icons.brightness_6_outlined,
          title: '外观模式：浅色 / 深色 / 跟随系统',
          body: '决定整个 App 的底色明暗。「跟随系统」会跟着手机的深色模式开关走，'
              '晚上自动变深色。选完立刻生效，不用重启。',
        ),
        SettingsHelpItem(
          icon: Icons.palette_outlined,
          title: '配色：24 套预设 + 自定义',
          body: '每套预设同时给了浅色底、深色底和一个强调色，'
              '按钮/选中态/图标高亮都跟着它走。'
              '自定义可以自己取一个主色，其余色由它推出来。',
        ),
        SettingsHelpItem(
          icon: Icons.splitscreen_outlined,
          title: '分模块配色：影视 / 阅读 / 音乐 各来一套',
          body: '默认三个模块共用阅读那套配色。想让「影视用碧青、音乐用蕉红」'
              '就分别给它们单独指定 —— 各模块互不影响，'
              '但同一屏只显示一个模块，不会打架。',
        ),
        SettingsHelpItem(
          icon: Icons.restart_alt_rounded,
          title: '一键还原',
          body: '把配色、分模块跟随、明暗、壁纸全部恢复默认。'
              '改乱了、或者觉得哪块颜色不对劲，先点它回到起点再逐项调。',
        ),
        SettingsHelpItem(
          icon: Icons.format_size_rounded,
          title: '界面字号',
          body: '整体缩放所有界面文字（不含视频播放器里的字幕）。'
              '调大后卡片高度会跟着变，排版不会挤在一起。',
        ),
      ],
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

        // ── 文字 ──────────────────────────────────────────────
        //
        // ⚠️ 这个入口原本**只**在 `sub/appearance_settings_page.dart` 里，
        // 而那个页在设置菜单改指到本页之后就再没有任何导航入口了
        //（全仓库无人 import、无人 `Get.to`）——
        // 于是"界面字号"这个已实现的功能在 UI 上**完全点不到**。
        // 与 `_wallpaperCard` 上面那段注释是同一类事故，这里一并搬回来。
        _textCard(),
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
                style: TextStyle(fontSize: AppTheme.fontSubhead, height: 1.7),
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
    // 壁纸会自动切到深色那套（原来的 setAppearanceMode 已删除）
    // 4) 统一把调色板推给 AppTheme + 音乐
    await _afterPresetChanged();
    if (!mounted) return;
    AppToast.message('已还原默认主题', duration: const Duration(seconds: 2));
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
              Icon(
                Icons.brightness_6_outlined,
                size: 18,
                color: AppTheme.accentColor,
              ),
              const SizedBox(width: 8),
              Text(
                '明暗模式',
                style: TextStyle(
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '作用于全 App；阅读模块也跟随它（阅读里另有独立开关）',
            style: TextStyle(
              fontSize: AppTheme.fontFootnote,
              color: AppTheme.textTertiary,
            ),
          ),
          const SizedBox(height: 12),
          Builder(
            builder: (context) {
              // 三个选项：浅色 / 深色 / 跟随系统
              // 由 ThemeModeStore 统一管理，set() 内部会通过 GlobalThemeSync
              // 同步给音乐和阅读模块，做到"一个开关，三处同时变"。
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
                  // 壁纸那套按"实际该显示的明暗"选：
                  // 改全局明暗（内部会自动同步给音乐 / 阅读）。
                  // 壁纸**不需要**单独同步：`BackgroundService.currentSceneKey`
                  // 只读 `AppBrightness`，这里改完它自动切到对应那套场景。
                  await ThemeModeStore.set(target);
                  // 立刻刷新当前页面 UI
                  if (mounted) setState(() {});
                },
              );
            },
          ),
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
            Icon(
              Icons.wallpaper_outlined,
              size: 18,
              color: AppTheme.accentColor,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '壁纸与背景',
                    style: TextStyle(
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // 与旧「外观」页一样显示当前壁纸名（Obx 跟随变化）
                  Obx(
                    () => Text(
                      bg.wallpaperDisplayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTheme.fontFootnote,
                        color: AppTheme.textTertiary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20,
              color: AppTheme.textTertiary,
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 文字（界面字号）
  // ============================================================

  /// 从被孤立的旧「外观」页搬回来的入口（见 build 里的说明）。
  Widget _textCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
      ),
      child: Column(
        children: [
          SettingsRow(
            icon: Icons.text_fields,
            title: '界面字号',
            value: '${(AppTheme.fontScale.value * 100).round()}%',
            onTap: _pickFontScale,
          ),
        ],
      ),
    );
  }

  /// 界面字号（作用于全部界面文字；弹幕字号单独设置不受影响）
  Future<void> _pickFontScale() async {
    var v = AppTheme.fontScale.value;
    final saved = await showDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: AppTheme.backgroundSecondary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusLG),
          ),
          title: Text('界面字号',
              style: TextStyle(color: AppTheme.textPrimary)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${(v * 100).round()}%',
                  style: TextStyle(color: AppTheme.textSecondary)),
              Slider(
                value: v,
                min: 0.85,
                max: 1.30,
                divisions: 9,
                label: '${(v * 100).round()}%',
                onChanged: (nv) => setDialogState(() => v = nv),
              ),
              const SizedBox(height: AppTheme.spacingSM),
              Text(
                '作用于全部界面文字（弹幕字号单独设置不受影响）',
                style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontCaption,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('取消',
                  style: TextStyle(color: AppTheme.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(v),
              child: Text('保存',
                  style: TextStyle(color: AppTheme.accentColor)),
            ),
          ],
        ),
      ),
    );
    if (saved == null) return;
    await AppTheme.setFontScale(saved);
    if (mounted) setState(() {});
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
                Text(
                  title,
                  style: TextStyle(
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const Spacer(),
                Text(
                  _presetName(effective),
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    color: AppTheme.textTertiary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: AppTheme.fontFootnote,
                color: AppTheme.textTertiary,
              ),
            ),
            const SizedBox(height: 12),
            // 与阅读「主题风格」面板同一套：点开底部面板，里面是
            // 「三色点 + 名称 + 右侧单选圈」的全宽圆角行（用户 2026-10-16 要求）
            _pickRow(
              dots: _dotsOf(effective),
              onTap: () =>
                  _pickPreset(module: module, current: current, title: title),
            ),
          ],
        ),
      ),
    );
  }

  /// 模块卡里那一行「选择主题」入口 —— 用阅读面板同款行，右侧给箭头
  Widget _pickRow({required List<Color> dots, required VoidCallback onTap}) {
    return ThemePresetRow(
      name: '选择主题',
      subtitle: '与阅读「主题风格」同一套样式',
      dots: dots,
      selected: false,
      trailing: Icon(Icons.chevron_right_rounded,
          size: 20, color: AppTheme.textTertiary),
      onTap: onTap,
    );
  }

  /// 三色点：主色 / 强调色 / 浅底（与阅读面板上的色点同一取法）
  List<Color> _dotsOf(String presetId) {
    // ⚠️ 必须走 store 的解析（先查自定义主题）：阅读用的是
    // `custom_<时间戳>_<序号>` 这种 id，`JellyPalette.fromPreset` 不认识它 →
    // 回退「魅力紫」，于是"阅读用自定义主题"时这里三个色点显示的是紫色。
    final p = store.paletteOf(presetId);
    return [p.primary, p.accent, p.backgroundLight];
  }

  /// 打开**与阅读同款**的底部面板选主题（用户 2026-10-16 要求）。
  ///
  /// [module] 传 `__reading__` 表示改阅读自己（走 SettingsService，
  /// 它会同步给 ModuleThemeStore）；否则走 store 改该模块。
  Future<void> _pickPreset({
    required String module,
    required String current,
    required String title,
  }) async {
    final readingPreset = SettingsService().themePreset;

    Future<void> pick(String id) async {
      if (module == '__reading__') {
        await SettingsService().setThemePreset(id);
      } else {
        await store.setPreset(module, id);
      }
      await _afterPresetChanged();
    }

    await showThemePresetSheet(
      context: context,
      title: '主题风格',
      subtitle: title,
      rowsBuilder: (sheetCtx) => [
        // 「跟随阅读」也做成同款行（原来是个小胶囊 chip，与阅读面板不一致）
        if (module != '__reading__')
          ThemePresetRow(
            name: '跟随阅读',
            subtitle: '与阅读模块当前配色一致',
            dots: _dotsOf(readingPreset),
            selected: current == ModuleThemeStore.followReading,
            onTap: () {
              Navigator.of(sheetCtx).pop();
              pick(ModuleThemeStore.followReading);
            },
          ),
        for (final p in readingThemePresets)
          ThemePresetRow(
            name: p.name,
            dots: _dotsOf(p.id),
            selected: current == p.id,
            onTap: () {
              Navigator.of(sheetCtx).pop();
              pick(p.id);
            },
          ),
      ],
    );
  }

  // ============================================================
  // 阅读：和影视/音乐一样直接选全部预设主题 + "更多设置"入口
  // ============================================================

  Widget _readingSection() {
    final readingPreset = SettingsService().themePreset;
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
                Icon(
                  Icons.menu_book_outlined,
                  size: 18,
                  color: AppTheme.accentColor,
                ),
                const SizedBox(width: 8),
                Text(
                  '阅读',
                  style: TextStyle(
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const Spacer(),
                Text(
                  _presetName(readingPreset),
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    color: AppTheme.textTertiary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              // 数量**不要写死**：预设从 7 套扩到 24 套后，原来那句
              // "以阅读的 7 套主题为基准"就成了假话。这里直接用列表长度。
              '以阅读的 ${readingThemePresets.length} 套主题为基准；影视、音乐默认跟随阅读',
              style: TextStyle(
                fontSize: AppTheme.fontFootnote,
                color: AppTheme.textTertiary,
              ),
            ),
            const SizedBox(height: 12),
            // 与影视/音乐同款（都是阅读那套行 + 底部面板）
            _pickRow(
              dots: _dotsOf(readingPreset),
              onTap: () => _pickPreset(
                module: '__reading__',
                current: readingPreset,
                title: '阅读',
              ),
            ),
            const SizedBox(height: 10),
            // 阅读独有高级功能的入口
            Row(
              children: [
                TextButton.icon(
                  onPressed: () => Get.to(() => const _ReadingThemeHintPage()),
                  icon: const Icon(Icons.tune, size: 16),
                  label: const Text('更多设置（自定义颜色 / 背景动画 / 图片背景）'),
                ),
              ],
            ),
          ],
        ),
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
                style: TextStyle(fontSize: AppTheme.fontSubhead, height: 1.6),
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

  String _presetName(String id) => store.displayNameOf(id);

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
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: i == selectedIndex
                      ? AppTheme.accentColor
                      : AppTheme.backgroundTertiary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  labels[i],
                  style: TextStyle(
                    fontSize: AppTheme.fontSubhead,
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
            '那里提供 ${readingThemePresets.length} 套预设主题'
            '（水墨书香 / 魅力紫色 / 粉色少女 / 清新护眼 / 蓝色海洋 / 落日余晖 / '
            '蓝色天空 / 节日与「公认最美」系列…）、自定义颜色编辑器，'
            '以及纯色 / 内置动画 / 自定义图片三种背景。',
            style: TextStyle(
              fontSize: AppTheme.fontSubhead,
              height: 1.7,
              color: AppTheme.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
