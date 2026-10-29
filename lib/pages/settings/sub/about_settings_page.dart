import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:tvbox/common/app_version.dart';
import 'package:tvbox/common/theme.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/widgets/common_widgets.dart';
import 'package:tvbox/pages/settings/sub/settings_shared.dart';

/// 设置 → 关于
///
/// 从原 settings/view.dart 拆出：版本、站点数量、关于版本弹窗。
class AboutSettingsPage extends StatelessWidget {
  const AboutSettingsPage({super.key});

  /// 版本号来自 `lib/common/app_version.dart`（唯一来源），不再在本文件硬编码。
  static const String appVersion = kAppVersion;

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
            Icon(Icons.play_circle_filled,
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
            child: Text('确定',
                style: TextStyle(color: AppTheme.accentColor)),
          ),
        ],
      ),
    );
  }
}
