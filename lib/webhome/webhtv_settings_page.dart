import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../common/theme.dart';
import '../pages/settings/sub/settings_shared.dart';
import '../reading/pages/general_settings_page.dart' show AppLogPage;
import '../widgets/common_widgets.dart';
import 'web_home_manage_page.dart';
import 'webhtv_extension_page.dart';
import 'webhtv_pan_check_page.dart';
import 'webhtv_playback_sync_page.dart';
import 'webhtv_proxy_page.dart';
import 'webhtv_site_health_page.dart';
import 'webhtv_site_inject_page.dart';

/// 「Webhtv」**独立模块设置页**（用户 2026-10-15）。
///
/// 背景：WebHomeTV（`github.com/webhtv/webhtv`）把这些能力集中在设置页的
/// 「增强功能」入口，手机端 / 电视端各是一个独立设置页。用户要求本项目
/// **同样独立成模块、在设置里单独管理**，并按顺序逐项补齐（客户端优先）。
///
/// 本页是**骨架**：部分能力本项目已有，直接通到既有页面；尚未接入的项一律进
/// [WebhtvComingSoonPage]，明确写清"未接入"，**不做假 UI**。
class WebhtvSettingsPage extends StatelessWidget {
  const WebhtvSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 16,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text('Webhtv',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          // ── 首页与站点 ────────────────────────────────────────────
          SettingsGroup(
            title: '首页与站点',
            hint: 'Webhtv 的核心：把 CSP 站点首页变成一个可开发的网页应用',
            children: [
              SettingsRow(
                icon: Icons.language_outlined,
                title: '网页源管理',
                subtitle: '内置 / 订阅 / 本地导入；切换与拖动排序',
                onTap: () => Get.to(() => const WebHomeManagePage()),
              ),
              SettingsRow(
                icon: Icons.add_link_rounded,
                title: '站点注入',
                subtitle: '添加自定义 WebHome / CSP 站点：启用状态、插入位置、'
                    '首页 homePage、搜索与换源行为；支持粘贴松散站点 JSON 自动归类',
                onTap: () => Get.to(() => const WebhtvSiteInjectPage()),
              ),
              SettingsRow(
                icon: Icons.extension_outlined,
                title: 'WebHome 扩展',
                subtitle: '给真实网页注入用户脚本（本地文件 / 远程链接 / 直接代码）',
                onTap: () => Get.to(() => const WebhtvExtensionPage()),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.spacingXXL),

          // ── 播放增强 ──────────────────────────────────────────────
          SettingsGroup(
            title: '播放增强',
            children: [
              SettingsRow(
                icon: Icons.cloud_download_outlined,
                title: '网盘链接检测',
                subtitle: '分享链有效性检测：夸克 / 阿里 / 百度 / UC / 天翼 / 迅雷 / '
                    '123 / 115 / 磁力 / ed2k 等',
                onTap: () => Get.to(() => const WebhtvPanCheckPage()),
              ),
              SettingsRow(
                icon: Icons.speed_rounded,
                title: '站点健康排序',
                subtitle: '学习搜索 / 详情 / 播放成功率，换源优先用更可用的站点',
                onTap: () => Get.to(() => const WebhtvSiteHealthPage()),
              ),
              SettingsRow(
                icon: Icons.movie_filter_outlined,
                title: '观影记录同步',
                subtitle: 'Webhook 上报 + 远端增量拉取（已按 WebHomeTV 文档 13.4 对齐协议）',
                onTap: () => Get.to(() => const WebhtvPlaybackSyncPage()),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.spacingXXL),

          // ── 网络 ──────────────────────────────────────────────────
          SettingsGroup(
            title: '网络',
            children: [
              SettingsRow(
                icon: Icons.vpn_lock_outlined,
                title: 'APP 代理',
                subtitle: '按域名匹配的代理规则（代理地址在「通用设置 → 网络代理」）',
                onTap: () => Get.to(() => const WebhtvProxyPage()),
              ),
              SettingsRow(
                icon: Icons.article_outlined,
                title: '调试日志',
                subtitle: '本机查看（局域网查看待接入）',
                onTap: () => Get.to(() => const AppLogPage()),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.spacingXXL),

          // ── 设备互联（iOS 有平台限制，先写清楚）────────────────────
          SettingsGroup(
            title: '设备互联',
            hint: '⚠️ iOS 无法像 Android 那样常驻前台服务保活：App 切到后台后'
                '本机 HTTP 服务会停。所以「一键同步」「局域网管理页」'
                '只在 App 前台时有意义；远程托管靠外部中转服务，不受此限。',
            children: [
              SettingsRow(
                icon: Icons.sync_rounded,
                title: '一键同步',
                subtitle: '同一局域网设备间按项同步',
                onTap: () => Get.to(() => const WebhtvComingSoonPage(
                      title: '一键同步',
                      note: '需要先有"本机 HTTP 服务 + 数据导出/导入协议"：\n'
                          '· 可同步项：配置 / 站源数据 / 登录态 / WebHome 数据 /\n'
                          '  搜索记录 / 观看历史 / 收藏 / 应用设置（每项可单独勾选）\n'
                          '· 设备发现走局域网（本项目已声明本地网络权限）\n'
                          '· ⚠️ iOS 后台会被挂起，仅前台可用',
                    )),
              ),
              SettingsRow(
                icon: Icons.lan_outlined,
                title: '局域网管理页 /m',
                subtitle: '浏览器打开本机管理页（仅 App 前台）',
                onTap: () => Get.to(() => const WebhtvComingSoonPage(
                      title: '局域网管理页 /m',
                      note: '在 App 内起一个本地 HTTP 服务，浏览器访问 /m 管理：\n'
                          '· 文件、登录态、同步目录、站点注入、接口、壳代理、搜索、推送\n'
                          '· ⚠️ iOS 没有前台服务保活，App 一切后台服务即停',
                    )),
              ),
              SettingsRow(
                icon: Icons.cloud_sync_outlined,
                title: '远程托管（客户端）',
                subtitle: '绑定自建中转服务后远程搜索 / 推送 / 配置（服务端需你自建）',
                onTap: () => Get.to(() => const WebhtvComingSoonPage(
                      title: '远程托管（客户端）',
                      note: '用户已确认：**先只做客户端**。\n'
                          '需要你提供中转服务的部署地址（Cloudflare / Deno / Vercel / '
                          'Go / Rust 任选，见 webhtv 仓库 serverless 目录）。\n'
                          '客户端部分：\n'
                          '· 设备绑定与设备状态\n'
                          '· 远程搜索 / 推送 / 接口配置 / 主页设置 / 一键同步 / 最近日志\n'
                          '· Go/Rust 版支持 WebSocket 实时通道，不支持时回退 HTTP 轮询',
                    )),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 尚未接入的能力占位页 —— **明确写清"未接入"**，不做假 UI。
///
/// 每项都写清"要做什么"，方便按顺序逐个补齐时对着做。
class WebhtvComingSoonPage extends StatelessWidget {
  const WebhtvComingSoonPage({super.key, required this.title, this.note});

  final String title;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 16,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text(title,
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
        children: [
          Row(
            children: [
              Icon(Icons.construction_rounded,
                  size: 20, color: AppTheme.textTertiary),
              const SizedBox(width: 8),
              Text('该能力的客户端尚未接入',
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          if (note != null) ...[
            const SizedBox(height: 14),
            Text(note!,
                style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: AppTheme.fontSubhead,
                    height: 1.7)),
          ],
        ],
      ),
    );
  }
}
