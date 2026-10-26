import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/common/theme_mode_store.dart';
import 'package:tvbox/services/background_service.dart';
import 'package:tvbox/widgets/common_widgets.dart';
import 'package:tvbox/pages/settings/wallpaper_page.dart';
import 'package:tvbox/pages/settings/sub/settings_shared.dart';

/// 设置 → 外观
///
/// 从原 1807 行的 settings/view.dart 拆出。内容与行为保持一致：
/// 外观模式 / 壁纸与背景 / 界面字号。
class AppearanceSettingsPage extends StatefulWidget {
  const AppearanceSettingsPage({super.key});

  @override
  State<AppearanceSettingsPage> createState() =>
      _AppearanceSettingsPageState();
}

class _AppearanceSettingsPageState extends State<AppearanceSettingsPage> {
  Future<void> _pickThemeMode() async {
    final mode = ThemeModeStore.mode;
    final selected = await SettingsDialogs.pick<ThemeMode>(
      context: context,
      title: '外观模式',
      options: const [ThemeMode.dark, ThemeMode.light, ThemeMode.system],
      selected: mode,
      labelBuilder: (m) => switch (m) {
        ThemeMode.light => '浅色',
        ThemeMode.system => '跟随系统',
        _ => '深色',
      },
    );
    if (selected == null) return;
    await ThemeModeStore.set(selected);
    // 外观模式是唯一来源：它同时决定文字明暗与用哪一套背景
    //（`BackgroundService.currentSceneKey` 只读 `AppBrightness`，
    //  所以这里不需要再额外通知壁纸服务）。
    if (mounted) setState(() {});
  }

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

  @override
  Widget build(BuildContext context) {
    final bg = BackgroundService.instance;

    return SettingsSubPage(
      title: '外观',
      children: [
        SettingsGroup(
          title: '主题',
          children: [
            SettingsRow(
              icon: Icons.brightness_6_outlined,
              title: '外观模式',
              value: switch (ThemeModeStore.mode) {
                ThemeMode.light => '浅色',
                ThemeMode.system => '跟随系统',
                _ => '深色',
              },
              onTap: _pickThemeMode,
            ),
            Obx(() => SettingsRow(
                  icon: Icons.wallpaper_outlined,
                  title: '壁纸与背景',
                  value: bg.wallpaperDisplayName,
                  onTap: () => Get.to(() => const WallpaperSettingsPage()),
                )),
          ],
        ),
        SettingsGroup(
          title: '文字',
          children: [
            Obx(() => SettingsRow(
                  icon: Icons.text_fields,
                  title: '界面字号',
                  value:
                      '${(AppTheme.fontScale.value * 100).round()}%',
                  onTap: _pickFontScale,
                )),
          ],
        ),
      ],
    );
  }
}
