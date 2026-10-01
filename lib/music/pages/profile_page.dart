import 'package:flutter/material.dart';

import '../models/models.dart';
import '../models/third_party_source.dart';
import '../services/settings_store.dart';
import '../theme/music_theme.dart';
import 'source_manager_page.dart';

/// 「我的」页 —— 移植自 Beans 的 `ProfileView.swift`（3350 行，取其主干）。
///
/// ── 保留的 Beans 分区 ─────────────────────────────────────────
///   1. **个性化外观**：明暗模式 / 9 种强调色 / 自定义色
///   2. **播放设置**：音质 / 封面形态 / 背景氛围（在播放器设置里也有）
///   3. **音源管理**：导入/启用/删除第三方音源（Beans 的"音源"入口）
///   4. 关于
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
          _AccentPicker(store: themeStore),
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

          // ── 关于 ────────────────────────────────────────────
          const _GroupTitle('关于'),
          ListTile(
            leading: _iconBox(Icons.info_outline_rounded),
            title: Text('关于音乐模块',
                style: TextStyle(color: MusicTheme.label, fontSize: 15)),
            subtitle: Text('界面与功能参照 Beans-Music 重绘',
                style: TextStyle(color: MusicTheme.secondary, fontSize: 12)),
            onTap: () => showAboutDialog(
              context: context,
              applicationName: '猫影 · 音乐',
              applicationVersion: '1.0',
              children: [
                Text(
                  '界面与交互按 Beans-Music（SwiftUI）逐页用 Flutter 重绘。\n\n'
                  '音源使用公开可用的接口，不需要登录；\n'
                  '会员/独家曲目可能没有免费音源，播放器会明确提示。\n\n'
                  '支持导入第三方音源（模板法 / LX 脚本法）。',
                  style: TextStyle(
                      color: MusicTheme.secondary, fontSize: 13, height: 1.6),
                ),
              ],
            ),
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
class _ModeTile extends StatelessWidget {
  const _ModeTile({required this.store});
  final MusicThemeStore store;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: store.revision,
      builder: (context, _, __) {
        final mode = store.currentMode;
        return ListTile(
          leading: ProfilePage._iconBox(
            mode == MusicThemeMode.dark
                ? Icons.dark_mode_rounded
                : mode == MusicThemeMode.light
                    ? Icons.light_mode_rounded
                    : Icons.brightness_auto_rounded,
          ),
          title: Text('外观模式',
              style: TextStyle(color: MusicTheme.label, fontSize: 15)),
          subtitle: Text(mode.label,
              style: TextStyle(color: MusicTheme.secondary, fontSize: 12)),
          onTap: () async {
            final picked = await showModalBottomSheet<MusicThemeMode>(
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
                    ...MusicThemeMode.values.map((e) => ListTile(
                          title: Text(e.label,
                              style: TextStyle(
                                  color: e == mode
                                      ? MusicTheme.tint
                                      : MusicTheme.label)),
                          trailing: e == mode
                              ? Icon(Icons.check,
                                  color: MusicTheme.tint, size: 18)
                              : null,
                          onTap: () => Navigator.pop(ctx, e),
                        )),
                  ],
                ),
              ),
            );
            if (picked != null) await store.setMode(picked);
          },
        );
      },
    );
  }
}

/// 9 种强调色选择器（Beans 的 BeansAccent）
class _AccentPicker extends StatelessWidget {
  const _AccentPicker({required this.store});
  final MusicThemeStore store;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: store.revision,
      builder: (context, _, __) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('强调色',
                  style:
                      TextStyle(color: MusicTheme.label, fontSize: 15)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: MusicAccent.values.map((a) {
                  final active = MusicTheme.accent == a &&
                      MusicTheme.customAccent == null;
                  return GestureDetector(
                    onTap: () => store.setAccent(a),
                    child: Tooltip(
                      message: a.label,
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: a.gradientColors,
                          ),
                          border: active
                              ? Border.all(
                                  color: MusicTheme.label, width: 2)
                              : null,
                        ),
                        child: active
                            ? const Icon(Icons.check,
                                size: 16, color: Colors.white)
                            : null,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        );
      },
    );
  }
}
