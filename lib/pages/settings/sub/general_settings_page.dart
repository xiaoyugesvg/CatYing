import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/theme.dart';
import '../../../reading/pages/general_settings_page.dart' show AppLogPage;
import '../../../webhome/webhtv_pan_check_page.dart';
import '../../../webhome/webhtv_playback_sync_page.dart';
import '../../../webhome/webhtv_proxy_page.dart';
import '../../../webhome/webhtv_site_health_page.dart';
import '../../../widgets/common_widgets.dart';
import 'cache_settings_page.dart';
import 'settings_shared.dart';

/// 设置 → 通用设置（**影视模块专用**）
///
/// 用户 2026-10-13：影视这边的通用设置内容与阅读不同 —— 放
/// 「软件日志 + 缓存管理」：
///   · 「缓存管理」= 设置里原来那个独立入口整块挪进来（不再单独占一格）；
///   · 「引擎管理」（Node / Python 手动加载）挪去**订阅管理**页。
///
/// 用户 2026-10-16（Webhtv 模块下线后）：原来挂在「Webhtv 设置」里的
/// **4 个跟"网页首页"无关的独立功能**整块搬到这里 —— 网络代理 / 观影同步 /
/// 站点健康排序 / 网盘链接检测。它们本来就不依赖网页首页那套，照旧可用。
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
        const SizedBox(height: AppTheme.spacingXXL),
        SettingsGroup(
          title: '增强功能',
          hint: '这几项与「网页首页」无关，是独立可用的功能',
          children: [
            SettingsRow(
              icon: Icons.vpn_lock_outlined,
              title: '网络代理',
              subtitle: '全局代理地址 + 按域名匹配的代理规则'
                  '（全项目请求 / 书源 / RSS / 嗅探都会跟着走）',
              onTap: () => Get.to(() => const WebhtvProxyPage()),
            ),
            SettingsRow(
              icon: Icons.movie_filter_outlined,
              title: '观影记录同步',
              subtitle: 'Webhook 上报 + 远端增量拉取',
              onTap: () => Get.to(() => const WebhtvPlaybackSyncPage()),
            ),
            SettingsRow(
              icon: Icons.speed_rounded,
              title: '站点健康排序',
              subtitle: '学习搜索 / 详情 / 播放成功率，换源优先用更可用的站点',
              onTap: () => Get.to(() => const WebhtvSiteHealthPage()),
            ),
            SettingsRow(
              icon: Icons.cloud_download_outlined,
              title: '网盘链接检测',
              subtitle: '分享链有效性检测：夸克 / 阿里 / 百度 / UC / 天翼 / 迅雷 / '
                  '123 / 115 / 磁力 / ed2k 等',
              onTap: () => Get.to(() => const WebhtvPanCheckPage()),
            ),
          ],
        ),
      ],
    );
  }
}
