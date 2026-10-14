import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../reading/pages/general_settings_page.dart' show AppLogPage;
import '../../../widgets/common_widgets.dart';
import 'cache_settings_page.dart';
import 'settings_shared.dart';

/// 设置 → 通用设置（**影视模块专用**）
///
/// 用户 2026-10-13：影视这边的通用设置内容与阅读不同 —— 放
/// 「软件日志 + 缓存管理」：
///   · 「缓存管理」= 设置里原来那个独立入口整块挪进来（不再单独占一格）；
///   · 「引擎管理」（Node / Python 手动加载）挪去**订阅管理**页。
class GeneralSettingsPage extends StatelessWidget {
  const GeneralSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '通用设置',
      children: [
        SettingsGroup(
          children: [
            SettingsRow(
              icon: Icons.receipt_long_rounded,
              title: '软件日志',
              value: '查看 / 清理',
              onTap: () => Get.to(() => const AppLogPage()),
            ),
            SettingsRow(
              icon: Icons.cleaning_services_rounded,
              title: '缓存管理',
              value: '按维度清理',
              onTap: () => Get.to(() => const CacheSettingsPage()),
            ),
          ],
        ),
      ],
    );
  }
}
