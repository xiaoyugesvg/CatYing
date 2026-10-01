import 'package:flutter/material.dart';

import '../models/models.dart';
import '../models/third_party_source.dart';
import '../services/settings_store.dart';
import '../theme/music_theme.dart';
import 'source_manager_page.dart';
import '../../common/module_theme_store.dart';
import '../../common/theme_mode_store.dart';
import '../../services/background_service.dart';
import '../../reading/theme/jelly_palette.dart';

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
                    fontSize: 24,
                    fontWeight: FontWeight.w700)),
          ),

          // ── 外观 ────────────────────────────────────────────
          const _GroupTitle('个性化外观'),
          _ModeTile(store: themeStore),
          _AccentPicker(),
          _coverStyleTile(),
          _dustTile(),

          // ── 播放 ────────────────────────────────────────────
          const _GroupTitle('播放'),
          _qualityTile(store),
          _switchTile(
            label: '使用第三方音源',
            subtitle: '关闭后只用内置的公开接口',
            value: store.useThirdPartySources.value,
            onChanged: (v) => store.setUseThirdPartySources(v),
          ),

          // ── 音源 ────────────────────────────────────────────
          const _GroupTitle('音源'),
          ValueListenableBuilder<int>(
            valueListenable: ThirdPartySourceStore.instance.revision,
            builder: (context, _, __) {
              final n = ThirdPartySourceStore.instance.all.length;
              return ListTile(
                leading: _iconBox(Icons.extension_rounded),
                title: Text('音源管理',
                    style:
                        TextStyle(color: MusicTheme.label, fontSize: 15)),
                subtitle: Text(
                  n == 0 ? '还没有导入音源' : '已导入 $n 个音源',
                  style:
                      TextStyle(color: MusicTheme.secondary, fontSize: 12),
                ),
                trailing: Icon(Icons.chevron_right,
                    size: 18, color: MusicTheme.secondary),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const SourceManagerPage(),
                )),
              );
            },
          ),
        ],
      ),
    );
  }

  static Widget _iconBox(IconData icon) => Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: MusicTheme.tint.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Icon(icon, size: 17, color: MusicTheme.tint),
      );

  Widget _switchTile({
    required String label,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      StatefulBuilder(
        builder: (context, setLocal) => SwitchListTile(
          value: value,
          activeThumbColor: MusicTheme.tint,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: Text(label,
              style: TextStyle(color: MusicTheme.label, fontSize: 15)),
          subtitle: subtitle == null
              ? null
              : Text(subtitle,
                  style: TextStyle(
                      color: MusicTheme.secondary, fontSize: 12)),
          onChanged: (v) {
            onChanged(v);
            setLocal(() {});
          },
        ),
      );

  Widget _qualityTile(SettingsStore store) => ValueListenableBuilder(
        valueListenable: store.audioQuality,
        builder: (context, q, _) => ListTile(
          leading: _iconBox(Icons.high_quality_rounded),
          title:
              Text('音质', style: TextStyle(color: MusicTheme.label, fontSize: 15)),
          subtitle: Text(q.displayName,
              style: TextStyle(color: MusicTheme.secondary, fontSize: 12)),
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
              style: TextStyle(color: MusicTheme.label, fontSize: 15)),
          subtitle: Text(v.label,
              style: TextStyle(color: MusicTheme.secondary, fontSize: 12)),
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
              style: TextStyle(color: MusicTheme.label, fontSize: 15)),
          subtitle: Text(v.label,
              style: TextStyle(color: MusicTheme.secondary, fontSize: 12)),
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
                fontSize: 13,
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
              style: TextStyle(color: MusicTheme.label, fontSize: 15)),
          subtitle: Text(label,
              style: TextStyle(color: MusicTheme.secondary, fontSize: 12)),
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
            // 壁纸也跟着换（只有 light/dark 两套壁纸）
            final wantLight = switch (picked) {
              ThemeMode.light => true,
              ThemeMode.dark => false,
              ThemeMode.system =>
                MediaQuery.of(context).platformBrightness == Brightness.light,
            };
            await BackgroundService.instance.setAppearanceMode(
              wantLight ? AppearanceMode.light : AppearanceMode.dark,
            );
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
                          TextStyle(color: MusicTheme.label, fontSize: 15)),
                  const Spacer(),
                  if (current == ModuleThemeStore.followReading)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: MusicTheme.tint.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('跟随阅读',
                          style: TextStyle(
                              fontSize: 10,
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
                    onTap: () => store.setPreset(
                        ModuleThemeStore.music, ModuleThemeStore.followReading),
                  ),
                  // 7 套预设
                  for (final p in presets)
                    _buildDot(
                      palette: p.palette,
                      label: p.name,
                      selected: current == p.id,
                      onTap: () => store.setPreset(ModuleThemeStore.music, p.id),
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
                  fontSize: 9.5,
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
