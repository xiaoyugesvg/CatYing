import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/theme.dart';
import '../../../services/api_config.dart';
import '../../../widgets/common_widgets.dart';
import 'settings_shared.dart';

/// 设置 → 关于
///
/// 从原 settings/view.dart 拆出：版本、站点数量、解析数量、关于版本弹窗。
class AboutSettingsPage extends StatelessWidget {
  const AboutSettingsPage({super.key});

  static const String appVersion = '1.0.0';

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '关于',
      children: [
        SettingsGroup(
          children: [
            const SettingsRow(
              icon: Icons.info_outline,
              title: '版本',
              value: appVersion,
            ),
            Obx(() => SettingsRow(
                  icon: Icons.public,
                  title: '站点数量',
                  value: '${ApiConfig.instance.sourceBeanList.length}',
                )),
            Obx(() => SettingsRow(
                  icon: Icons.auto_fix_high,
                  title: '解析数量',
                  value: '${ApiConfig.instance.parseBeanList.length}',
                )),
            SettingsRow(
              icon: Icons.person_outline,
              title: '关于版本',
              value: '',
              onTap: () => _showAboutDialog(context),
            ),
          ],
        ),
      ],
    );
  }

  void _showAboutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.play_circle_filled,
                color: AppTheme.accentColor, size: 48),
            const SizedBox(height: AppTheme.spacingLG),
            Text(
              'TVBox',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: AppTheme.spacingXS),
            Text(
              '版本 $appVersion',
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
              ),
            ),
            const SizedBox(height: AppTheme.spacingXS),
            Text(
              '软件作者：包子',
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确定',
                style: TextStyle(color: AppTheme.accentColor)),
          ),
        ],
      ),
    );
  }
}
