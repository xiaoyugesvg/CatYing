import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/theme.dart';
import '../../../models/source_bean.dart';
import '../../../services/api_config.dart';
import '../../../services/source_kind.dart';
import '../../subscription/view.dart';
import '../../subscription/moontv_converter_page.dart';
import '../../../widgets/app_toast.dart';
import '../../../widgets/common_widgets.dart';
import '../../../widgets/source_kind_badge.dart';
import '../controller.dart';
import 'cf_sites_page.dart';
import 'engine_settings_page.dart';
import 'local_python_sources_page.dart';
import 'parse_settings_page.dart';
import 'settings_shared.dart';
import 'tg_source_page.dart';

/// 设置 → 订阅管理
///
/// 从原 settings/view.dart 拆出：订阅列表、主页数据、本地爬虫、解析线路、
/// 引擎管理、影视转换、重置配置。
/// （用户 2026-10-18：去掉「点播接口地址」与「RSS 管理」卡片；
///  每一项单独一张卡片，顺序按上面排列。）
class DataSourceSettingsPage extends StatefulWidget {
  const DataSourceSettingsPage({super.key});

  @override
  State<DataSourceSettingsPage> createState() => _DataSourceSettingsPageState();
}

class _DataSourceSettingsPageState extends State<DataSourceSettingsPage> {
  /// 复用主设置页注册的 SettingsController；**没有就自己注册**。
  ///
  /// ⚠️ 不能直接 `Get.find`：本页还有一个入口是启动页的「更换源」
  /// （`app_loading_view.dart`），那条路径**从未构建过 SettingsPage** →
  /// `SettingsController` 不存在 → `Get.find` 抛异常 → 整个第二个分组
  /// 被 ErrorWidget（release 下是一块灰色长板）取代，用户看到的就是
  /// 「订阅管理页下面一大块灰色空白」。
  SettingsController get controller => Get.isRegistered<SettingsController>()
      ? Get.find<SettingsController>()
      : Get.put(SettingsController());

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '订阅管理',
      children: [
        // 每一项都是**独立卡片**（不再是一整张大卡片里塞多行）
        _card(
          SettingsRow(
            icon: Icons.rss_feed,
            title: '订阅管理',
            onTap: () => Get.to(() => const SubscriptionPage()),
          ),
        ),
        Obx(
          () => _card(
            SettingsRow(
              icon: Icons.dns_outlined,
              title: '主页数据',
              value: ApiConfig.instance.homeSourceBean.value?.name ?? '未选择',
              onTap: _showSourcePicker,
            ),
          ),
        ),
        Obx(
          () => _card(
            SettingsRow(
              icon: Icons.terminal_rounded,
              title: '本地爬虫',
              subtitle: ApiConfig.instance.localSourcesEnabled.value
                  ? '已启用：本地源会出现在源面板 / 搜索里'
                  : '已关闭：优先使用订阅激活的源',
              value: '${ApiConfig.instance.localVideoSources.length} 个',
              trailingSwitch: true,
              switchValue: ApiConfig.instance.localSourcesEnabled.value,
              onSwitchChanged: (v) async {
                await ApiConfig.instance.setLocalSourcesEnabled(v);
                if (mounted) setState(() {});
              },
              onTap: () async {
                await Get.to(() => const LocalPythonSourcesPage());
                if (mounted) setState(() {});
              },
            ),
          ),
        ),
        Obx(
          () => _card(
            SettingsRow(
              icon: Icons.link_rounded,
              title: '解析线路',
              value: '${ApiConfig.instance.parseBeanList.length} 条',
              onTap: () => Get.to(() => const ParseSettingsPage()),
            ),
          ),
        ),
        _card(
          SettingsRow(
            icon: Icons.memory_outlined,
            title: '引擎管理',
            value: 'Node / Python',
            onTap: () => Get.to(() => const EngineSettingsPage()),
          ),
        ),
        // Cloudflare 站点验证：用户手动点一次，之后所有模块自动复用
        _card(
          SettingsRow(
            icon: Icons.shield_outlined,
            title: 'Cloudflare 验证',
            subtitle: '验证一次后自动复用，不再重复弹窗',
            onTap: () => Get.to(() => const CfSitesPage()),
          ),
        ),
        // Telegram 源：扫码登录后用自己加入的频道当片库（内置 Node 跑 MTProto）
        _card(
          SettingsRow(
            icon: Icons.telegram,
            title: 'Telegram 源',
            subtitle: '扫码登录，用自己加入的群 / 频道当片库',
            onTap: () => Get.to(() => const TgSourcePage()),
          ),
        ),
        // 影视仓转换器：MoonTV / LunaTV 的 video.json → TVBox 站点
        _card(
          SettingsRow(
            icon: Icons.swap_horiz_rounded,
            title: '影视转换',
            value: 'MoonTV video.json',
            onTap: () => Get.to(() => const MoonTvConverterPage()),
          ),
        ),
        _card(
          SettingsRow(
            icon: Icons.restart_alt,
            iconColor: Colors.redAccent,
            title: '重置配置',
            titleColor: Colors.redAccent,
            value: '回到初始',
            onTap: _showResetConfigDialog,
          ),
        ),
      ],
    );
  }

  /// 单项卡片（卡片之间留 10px，视觉上是一条条独立的）
  Widget _card(Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(dense: true, child: child),
    );
  }

  // ============================================================
  // 主页数据源选择
  // ============================================================

  void _showSourcePicker() {
    // 本地 Python 源单独成组，但这里也一并列出（置顶），方便直接切主页源。
    // 仅在「本地爬虫」开关打开时列出（用户 2026-10-18：默认优先订阅）。
    final sources = <SourceBean>[
      if (ApiConfig.instance.localSourcesEnabled.value)
        ...ApiConfig.instance.localVideoSources,
      ...ApiConfig.instance.sourceBeanList,
    ];
    if (sources.isEmpty) {
      AppToast.message('还没有可用源，请先在「订阅管理」里添加并加载订阅');
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        title: Text('主页数据', style: TextStyle(color: AppTheme.textPrimary)),
        content: Obx(() {
          final homeKey = ApiConfig.instance.homeSourceBean.value?.key;
          return ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 400),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: sources.length,
              itemBuilder: (context, index) {
                final source = sources[index];
                final isHome = homeKey == source.key;
                return Material(
                  color: Colors.transparent,
                  child: ListTile(
                    dense: true,
                    title: Row(
                      children: [
                        SourceKindBadge(
                          kind: inferMediaKind(source.name, api: source.api),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            source.name,
                            style: TextStyle(
                              color: isHome
                                  ? AppTheme.accentColor
                                  : AppTheme.textPrimary,
                              fontWeight: isHome
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    trailing: isHome
                        ? Icon(
                            Icons.check_circle,
                            color: AppTheme.accentColor,
                            size: 16,
                          )
                        : null,
                    onTap: () {
                      ApiConfig.instance.setHomeSource(source);
                      Navigator.pop(ctx);
                    },
                  ),
                );
              },
            ),
          );
        }),
      ),
    );
  }

  // ============================================================
  // 重置配置
  // ============================================================

  /// 与拆出前行为一致：确认 → 执行 resetConfig → 再弹一个「请重启」提示。
  /// 不自动跳转：重置只是清数据，界面留在原处，让用户自己决定何时重启。
  Future<void> _showResetConfigDialog() async {
    final ok = await SettingsDialogs.confirm(
      context: context,
      title: '重置配置',
      message:
          '将清除已保存的接口配置、接口历史以及已下载的源缓存。\n\n'
          '播放器、主题、字体等本地设置会保留。\n\n'
          '重置后请重启应用，下次打开将回到初始设置界面。',
      confirmText: '重置',
    );
    if (!ok || !mounted) return;

    await controller.resetConfig();
    if (!mounted) return;

    await showDialog<void>(
      context: context,
      builder: (ctx2) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, color: AppTheme.accentColor, size: 48),
            const SizedBox(height: 12),
            Text(
              '配置已重置',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '请退出应用后重新打开，\n配置将从零开始重新加载。',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontSubhead,
                height: 1.5,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx2),
            child: Text('知道了', style: TextStyle(color: AppTheme.accentColor)),
          ),
        ],
      ),
    );
  }
}
