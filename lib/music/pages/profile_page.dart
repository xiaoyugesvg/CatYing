import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../models/third_party_source.dart';
import '../services/settings_store.dart';
import '../theme/music_theme.dart';
import '../widgets/floating_play_button.dart';
import 'source_manager_page.dart';
import '../../common/module_theme_store.dart';
import '../../common/module_theme_sync.dart';
import '../../common/theme_mode_store.dart';
import '../../reading/theme/jelly_palette.dart';
import '../../common/theme.dart';
import '../../widgets/app_toast.dart';

/// 「我的」页 —— 移植自 Beans 的 `ProfileView.swift`（3350 行，取其主干）。
///
/// ── 保留的 Beans 分区 ─────────────────────────────────────────
///   1. **个性化外观**：明暗模式 / 9 种强调色 / 自定义色
///   2. **播放设置**：音质 / 封面形态 / 背景氛围（在播放器设置里也有）
///   3. **音源管理**：导入/启用/删除第三方音源（Beans 的"音源"入口）
///
/// ── 裁掉的部分（说明理由）────────────────────────────────────
/// Beans 的 ProfileView 里最大一块是**账号**（登录/会员/云盘/等级），
/// 还有下载管理、更新检查、日志查看。本项目不做账号，
/// 下载/更新也依赖额外原生能力，故未纳入。
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = SettingsStore.instance;
    final themeStore = MusicThemeStore.instance;

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 170),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Text('我的',
                style: TextStyle(
                    color: MusicTheme.label,
                    fontSize: AppTheme.fontPageTitle,
                    fontWeight: FontWeight.w700)),
          ),

          // ── 外观 ────────────────────────────────────────────
          const _GroupTitle('个性化外观'),
          _groupCard([
          _ModeTile(store: themeStore),
          _AccentPicker(),
          _coverStyleTile(),
          _dustTile(),
          _floatingBallTile(),
          ]),

          // ── 播放 ────────────────────────────────────────────
          const _GroupTitle('播放'),
          _groupCard([
          _qualityTile(store),
          _switchTile(
            // 不叫"第三方音源" —— 用户导入的就是"洛雪音乐源"和"MusicFree 源"，
            // 统称"导入的音乐源"更贴近他的心智模型
            label: '使用导入的音乐源',
            subtitle: '关闭后只用内置的公开接口',
            value: store.useThirdPartySources.value,
            onChanged: (v) => store.setUseThirdPartySources(v),
          ),
          // ⚠️ 「跨平台匹配」开关**已移除**（用户 2026 决定：不要跨平台）。
          //
          // 实测它救不了 VIP 歌（QQ《晴天》在酷狗同名 9 条全 no_free_source，
          // 能播的只有片段/翻唱），而且会让"点歌"多几秒等待。
          // 保留开关只会让人误以为"开了就能听 VIP"，所以直接不给入口。
          //
          // `CrossPlatformMatcher` 实现**保留**（没删代码），
          // `SettingsStore.crossPlatformMatch` 也保留（默认 false）——
          // 以后想恢复只需把上面那个开关加回来。
          ]),

          // ── 音源 ────────────────────────────────────────────
          const _GroupTitle('音源'),
          _groupCard([
          ValueListenableBuilder<int>(
            valueListenable: ThirdPartySourceStore.instance.revision,
            builder: (context, _, __) {
              final all = ThirdPartySourceStore.instance.all;
              // 分类计数：让用户一眼看出两类各有几个
              final lx = all.where((s) => !s.isMusicFree).length;
              final mf = all.where((s) => s.isMusicFree).length;
              final sub = all.isEmpty
                  ? '还没有导入音乐源'
                  : [
                      if (lx > 0) '洛雪 $lx',
                      if (mf > 0) 'MusicFree $mf',
                    ].join(' · ');
              return ListTile(
                leading: _iconBox(Icons.extension_rounded),
                title: Text('音乐源管理',
                    style:
                        TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
                subtitle: Text(
                  sub,
                  style:
                      TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote),
                ),
                trailing: Icon(Icons.chevron_right,
                    size: 18, color: MusicTheme.secondary),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const SourceManagerPage(),
                )),
              );
            },
          ),
          ]),
        ],
      ),
    );
  }

  /// 悬浮球样式：默认图标 / **自定义图片或 GIF**（用户要求能在设置里换）
  Widget _floatingBallTile() => ValueListenableBuilder<String>(
        valueListenable: MusicFloatingBallStyle.instance.imagePath,
        builder: (context, path, _) => ListTile(
          leading: _iconBox(Icons.bubble_chart_rounded),
          title: Text('悬浮球样式',
              style: TextStyle(
                  color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
          subtitle: Text(path.isEmpty ? '默认图标' : '自定义图片 / GIF',
              style: TextStyle(
                  color: MusicTheme.secondary,
                  fontSize: AppTheme.fontFootnote)),
          trailing: Icon(Icons.chevron_right,
              size: 18, color: MusicTheme.secondary),
          onTap: () => _pickFloatingBallStyle(context),
        ),
      );

  Future<void> _pickFloatingBallStyle(BuildContext context) async {
    final style = MusicFloatingBallStyle.instance;
    final act = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: MusicTheme.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.image_rounded, color: MusicTheme.tint),
              title: Text('选择图片 / GIF',
                  style: TextStyle(color: MusicTheme.label)),
              onTap: () => Navigator.pop(ctx, 'pick'),
            ),
            ListTile(
              leading:
                  Icon(Icons.restart_alt_rounded, color: MusicTheme.tint),
              title: Text('恢复默认图标',
                  style: TextStyle(color: MusicTheme.label)),
              onTap: () => Navigator.pop(ctx, 'reset'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (act == 'reset') {
      await style.clear();
      AppToast.show('已恢复默认悬浮球', '');
      return;
    }
    if (act != 'pick') return;
    try {
      // ⚠️ file_picker **13.x** 的 API（项目里早有记录，见
      // `book_source_repo_page.dart:1576`）：
      //   · `FilePicker.pickFiles(...)` 是**静态方法**（旧版是 `.platform.pickFiles`）
      //   · 返回 **`List<PlatformFile>`**（旧版返回 `FilePickerResult?`）
      final files = await FilePicker.pickFiles(type: FileType.image);
      final p = files.isEmpty ? null : files.first.path;
      if (p == null || p.isEmpty) return;
      await style.setImage(p);
      AppToast.show('悬浮球样式已更新', '');
    } catch (e) {
      AppToast.show('选择图片失败', '$e');
    }
  }

  /// 把一组行包成 Beans 式的**分组圆角卡片**（对齐截图④：每组一张卡）。
  ///
  /// ⚠️ 必须用 `Material` 而不是 `Container(color:)`：
  /// `ListTile` 需要 **Material 祖先**来画背景与水波纹，否则框架会抛
  /// "ListTile background color or ink splashes may be invisible."
  /// （这正是 `music_root_view_test` 那 3 个失败的原因 —— IndexedStack 会
  ///   构建所有 tab，一构建到本页就抛断言。）
  /// `clipBehavior: Clip.antiAlias` 让水波纹被圆角裁掉。
  ///
  /// 注意：内部行**保留原有缩进**（Dart 不看缩进），这样这次改动是
  /// "组首组尾各插一行"的最小 diff，不动那一大段既有代码 —— 降低改崩的风险。
  Widget _groupCard(List<Widget> rows) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
        child: Material(
          color: MusicTheme.card,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: Column(children: rows),
        ),
      );

  static Widget _iconBox(IconData icon) => Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: MusicTheme.tint.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 17, color: MusicTheme.tint),
      );

  /// 开关行。
  ///
  /// 🔴 原来用 `StatefulBuilder` + `setLocal(() {})`：那只重建**本行**，
  /// 而 `value` 是**调用时捕获的旧值** → 拨动开关后它立刻**弹回原位** ✗
  ///（设置其实**已经保存**，只是显示不动 → 用户以为"第三方源没打开"）。
  /// 这里改成直接跟随 `SettingsStore.useThirdPartySources` 这个 Notifier，
  /// 拨动后由它推新值，不会再回弹。（本页只有这一个开关，所以直接绑定。）
  Widget _switchTile({
    required String label,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      ValueListenableBuilder<bool>(
        valueListenable: SettingsStore.instance.useThirdPartySources,
        builder: (context, v, _) => SwitchListTile(
          value: v,
          activeThumbColor: MusicTheme.tint,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: Text(label,
              style: TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
          subtitle: subtitle == null
              ? null
              : Text(subtitle,
                  style: TextStyle(
                      color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote)),
          onChanged: onChanged,
        ),
      );

  Widget _qualityTile(SettingsStore store) => ValueListenableBuilder(
        valueListenable: store.audioQuality,
        builder: (context, q, _) => ListTile(
          leading: _iconBox(Icons.high_quality_rounded),
          title:
              Text('音质', style: TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
          subtitle: Text(q.displayName,
              style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote)),
          trailing: Icon(Icons.chevron_right,
              size: 18, color: MusicTheme.secondary),
          onTap: () async {
            final picked = await showModalBottomSheet<dynamic>(
              context: context,
              backgroundColor: MusicTheme.card,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              builder: (ctx) => SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 12),
                    ...List.generate(5, (i) {
                      final e = AudioQuality.values[i];
                      return ListTile(
                        title: Text(e.displayName,
                            style: TextStyle(
                                color: e == q
                                    ? MusicTheme.tint
                                    : MusicTheme.label)),
                        trailing: e == q
                            ? Icon(Icons.check,
                                color: MusicTheme.tint, size: 18)
                            : null,
                        onTap: () => Navigator.pop(ctx, e),
                      );
                    }),
                  ],
                ),
              ),
            );
            if (picked is AudioQuality) await store.setAudioQuality(picked);
          },
        ),
      );

  Widget _coverStyleTile() => ValueListenableBuilder(
        valueListenable: MusicPlayerSkin.instance.coverStyle,
        builder: (context, v, _) => ListTile(
          leading: _iconBox(Icons.album_rounded),
          title: Text('封面形态',
              style: TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
          subtitle: Text(v.label,
              style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote)),
          onTap: () async {
            final picked = await showModalBottomSheet<MusicCoverStyle>(
              context: context,
              backgroundColor: MusicTheme.card,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              builder: (ctx) => SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 12),
                    ...MusicCoverStyle.values.map((e) => ListTile(
                          title: Text(e.label,
                              style: TextStyle(
                                  color: e == v
                                      ? MusicTheme.tint
                                      : MusicTheme.label)),
                          trailing: e == v
                              ? Icon(Icons.check,
                                  color: MusicTheme.tint, size: 18)
                              : null,
                          onTap: () => Navigator.pop(ctx, e),
                        )),
                  ],
                ),
              ),
            );
            if (picked != null) {
              await MusicPlayerSkin.instance.setCoverStyle(picked);
            }
          },
        ),
      );

  Widget _dustTile() => ValueListenableBuilder(
        valueListenable: MusicPlayerSkin.instance.dustMode,
        builder: (context, v, _) => ListTile(
          leading: _iconBox(Icons.blur_on_rounded),
          title: Text('背景氛围',
              style: TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
          subtitle: Text(v.label,
              style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote)),
          onTap: () async {
            final picked = await showModalBottomSheet<MusicDustMode>(
              context: context,
              backgroundColor: MusicTheme.card,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              builder: (ctx) => SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 12),
                    ...MusicDustMode.values.map((e) => ListTile(
                          title: Text(e.label,
                              style: TextStyle(
                                  color: e == v
                                      ? MusicTheme.tint
                                      : MusicTheme.label)),
                          trailing: e == v
                              ? Icon(Icons.check,
                                  color: MusicTheme.tint, size: 18)
                              : null,
                          onTap: () => Navigator.pop(ctx, e),
                        )),
                  ],
                ),
              ),
            );
            if (picked != null) {
              await MusicPlayerSkin.instance.setDustMode(picked);
            }
          },
        ),
      );
}

class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 6),
        child: Text(text,
            style: TextStyle(
                color: MusicTheme.tint,
                fontSize: AppTheme.fontSubhead,
                fontWeight: FontWeight.w700)),
      );
}

/// 明暗模式切换（跟随系统 / 浅色 / 深色）
///
/// 直接读/写全局 ThemeModeStore，通过 GlobalThemeSync 自动同步三模块。
class _ModeTile extends StatelessWidget {
  const _ModeTile({required this.store});
  final MusicThemeStore store;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeModeStore.notifier,
      builder: (context, mode, _) {
        final label = switch (mode) {
          ThemeMode.light => '浅色',
          ThemeMode.dark => '深色',
          ThemeMode.system => '跟随系统',
        };
        final icon = switch (mode) {
          ThemeMode.light => Icons.light_mode_rounded,
          ThemeMode.dark => Icons.dark_mode_rounded,
          ThemeMode.system => Icons.brightness_auto_rounded,
        };
        return ListTile(
          leading: ProfilePage._iconBox(icon),
          title: Text('外观模式',
              style: TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
          subtitle: Text(label,
              style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote)),
          onTap: () async {
            final options = [
              (mode: ThemeMode.light, label: '浅色'),
              (mode: ThemeMode.dark, label: '深色'),
              (mode: ThemeMode.system, label: '跟随系统'),
            ];
            final picked = await showModalBottomSheet<ThemeMode>(
              context: context,
              backgroundColor: MusicTheme.card,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              builder: (ctx) => SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 12),
                    for (final o in options)
                      ListTile(
                        title: Text(o.label,
                            style: TextStyle(
                                color: o.mode == mode
                                    ? MusicTheme.tint
                                    : MusicTheme.label)),
                        trailing: o.mode == mode
                            ? Icon(Icons.check,
                                color: MusicTheme.tint, size: 18)
                            : null,
                        onTap: () => Navigator.pop(ctx, o.mode),
                      ),
                  ],
                ),
              ),
            );
            if (picked == null) return;
            // 改全局 ThemeModeStore —— 内部通过 GlobalThemeSync
            // 自动同步给音乐和阅读，三端一致。
            await ThemeModeStore.set(picked);
            // 壁纸会自动跟着换：`BackgroundService.currentSceneKey` 只读
            // `AppBrightness`，上面这行改完它就切到对应那套场景。
            //（原来还要调 `setAppearanceMode` 写第二份外观状态，已删除。）
          },
        );
      },
    );
  }
}

/// 主题配色选择器（7 套，与阅读/影视统一）
///
/// 直接操作 ModuleThemeStore（音乐模块的配色存在那里），
/// 和统一主题设置页的音乐区块是同一个数据源。
class _AccentPicker extends StatelessWidget {
  const _AccentPicker();

  @override
  Widget build(BuildContext context) {
    final store = ModuleThemeStore.instance;
    return ValueListenableBuilder<int>(
      valueListenable: store.revision,
      builder: (context, _, __) {
        final current = store.rawPreset(ModuleThemeStore.music);
        final presets = themePresets;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('主题配色',
                      style:
                          TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
                  const Spacer(),
                  if (current == ModuleThemeStore.followReading)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: MusicTheme.tint.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('跟随阅读',
                          style: TextStyle(
                              fontSize: AppTheme.fontCaption,
                              fontWeight: FontWeight.w600,
                              color: MusicTheme.tint)),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  // 跟随阅读
                  _buildDot(
                    palette: null,
                    label: '跟随',
                    selected: current == ModuleThemeStore.followReading,
                    onTap: () async {
                      await store.setPreset(
                          ModuleThemeStore.music, ModuleThemeStore.followReading);
                      // ⚠️ 必须落地：`setPreset` 只改 store 的数据。
                      // 不调 `applyModuleThemes()` 的话，注入给音乐的强调色
                      // （`MusicTheme._customAccent`）不会更新，也不会通知
                      // 音乐 UI 重建 —— 表现是"只有圆点的勾移动了，
                      // 底色/强调色不同步或不刷新"。
                      await applyModuleThemes();
                    },
                  ),
                  // 7 套预设
                  for (final p in presets)
                    _buildDot(
                      palette: p.palette,
                      label: p.name,
                      selected: current == p.id,
                      onTap: () async {
                        await store.setPreset(ModuleThemeStore.music, p.id);
                        // 同上：换配色后要把新调色板落地并通知重建
                        await applyModuleThemes();
                      },
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDot({
    required JellyPalette? palette,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Tooltip(
        message: label,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: palette != null
                    ? SweepGradient(colors: [
                        palette.backgroundLight,
                        palette.primary,
                        palette.backgroundDark,
                        palette.accent,
                        palette.backgroundLight,
                      ])
                    : null,
                color: palette == null ? MusicTheme.fill : null,
                border: Border.all(
                  color: selected ? MusicTheme.tint : MusicTheme.divider,
                  width: selected ? 2.5 : 1,
                ),
              ),
              child: selected
                  ? Icon(Icons.check,
                      size: 16,
                      color: palette != null
                          ? palette.backgroundLight.computeLuminance() > 0.5
                              ? Colors.black
                              : Colors.white
                          : MusicTheme.tint)
                  : (palette == null
                      ? Icon(Icons.auto_awesome,
                          size: 14, color: MusicTheme.tint)
                      : null),
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: 52,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppTheme.fontCaption,
                  color: selected ? MusicTheme.tint : MusicTheme.secondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
