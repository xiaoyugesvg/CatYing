import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/source_bean.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/services/remote_engine.dart';
import 'package:tvbox/services/source_kind.dart';
import 'package:tvbox/pages/subscription/view.dart';
import 'package:tvbox/pages/subscription/moontv_converter_page.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/widgets/common_widgets.dart';
import 'package:tvbox/widgets/source_kind_badge.dart';
import 'package:tvbox/pages/settings/controller.dart';
import 'package:tvbox/pages/settings/sub/cf_sites_page.dart';
import 'package:tvbox/pages/settings/sub/engine_settings_page.dart';
import 'package:tvbox/pages/settings/sub/local_python_sources_page.dart';
import 'package:tvbox/pages/settings/sub/parse_settings_page.dart';
import 'package:tvbox/pages/settings/sub/settings_shared.dart';
import 'package:tvbox/pages/settings/sub/tg_source_page.dart';

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

  // ── 远程引擎（默认关；开才显示这些字段）─────────────────
  final RemoteEngine _remote = RemoteEngine.instance;
  final TextEditingController _remoteBaseCtrl = TextEditingController();
  final TextEditingController _remoteTokenCtrl = TextEditingController();
  bool _remoteBusy = false;
  String? _remoteMsg;
  bool _remoteOk = false;

  @override
  void initState() {
    super.initState();
    _remote.load().then((_) {
      if (!mounted) return;
      _remoteBaseCtrl.text = _remote.baseUrl;
      _remoteTokenCtrl.text = _remote.token;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _remoteBaseCtrl.dispose();
    _remoteTokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _setRemote({
    bool? enabled,
    bool? useTg,
    bool? usePy,
    bool? useBook,
  }) async {
    await _remote.save(
      enabled: enabled,
      baseUrl: _remoteBaseCtrl.text,
      token: _remoteTokenCtrl.text,
      useTg: useTg,
      usePy: usePy,
      useBook: useBook,
    );
    if (mounted) setState(() {});
  }

  Future<void> _testRemote() async {
    setState(() {
      _remoteBusy = true;
      _remoteMsg = '正在连接…';
      _remoteOk = false;
    });
    // 先落盘地址/Token，再测（测的就是即将使用的那一套）
    await _remote.save(
      baseUrl: _remoteBaseCtrl.text,
      token: _remoteTokenCtrl.text,
    );
    final r = await _remote.test();
    if (!mounted) return;
    setState(() {
      _remoteBusy = false;
      _remoteOk = r.ok;
      _remoteMsg = r.msg;
    });
  }

  // ── 远程引擎卡片（总开关关掉时只显示一行）────────────────
  Widget _remoteCard() {
    return AppCard(
      dense: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_outlined,
                    size: 20, color: AppTheme.textSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('远程引擎',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary)),
                      const SizedBox(height: 2),
                      Text('把源脚本放自己服务器跑；不开就一直用本机',
                          style: TextStyle(
                              fontSize: 11, color: AppTheme.textTertiary)),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: _remote.enabled,
                  onChanged: (v) => _setRemote(enabled: v),
                ),
              ],
            ),
            if (_remote.enabled) ...[
              const SizedBox(height: 10),
              _remoteField(_remoteBaseCtrl, '地址', 'http://192.168.1.10:8080'),
              const SizedBox(height: 8),
              _remoteField(_remoteTokenCtrl, 'Token（可空）', 'X-Token'),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _remoteBusy ? null : _testRemote,
                  icon: const Icon(Icons.wifi_tethering, size: 17),
                  label: Text(_remoteBusy ? '测试中…' : '测试连接'),
                ),
              ),
              if (_remoteMsg != null) ...[
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _remoteOk
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      size: 15,
                      color: _remoteOk ? Colors.green : Colors.orangeAccent,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _remoteMsg!,
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.5,
                          color: _remoteOk
                              ? AppTheme.textSecondary
                              : Colors.orangeAccent,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              _remoteSwitch('TG', '频道列表与播放都指向服务器', _remote.useTg,
                  (v) => _setRemote(useTg: v)),
              _remoteSwitch('书源', 'Legado 规则在服务器上执行', _remote.useBook,
                  (v) => _setRemote(useBook: v)),
              _remoteSwitch('py 源', '需服务端带 Python 桥（本版只保存开关）',
                  _remote.usePy, (v) => _setRemote(usePy: v)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _remoteField(TextEditingController c, String label, String hint) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 4),
          child: Text(label,
              style: TextStyle(fontSize: 10.5, color: AppTheme.textTertiary)),
        ),
        Container(
          decoration: BoxDecoration(
            color: AppTheme.backgroundTertiary,
            borderRadius: BorderRadius.circular(11),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: TextField(
            controller: c,
            style: TextStyle(fontSize: 13, color: AppTheme.textPrimary),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle:
                  TextStyle(fontSize: 12, color: AppTheme.textTertiary),
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 11),
            ),
          ),
        ),
      ],
    );
  }

  Widget _remoteSwitch(
    String title,
    String sub,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: TextStyle(fontSize: 13, color: AppTheme.textPrimary)),
              Text(sub,
                  style:
                      TextStyle(fontSize: 10.5, color: AppTheme.textTertiary)),
            ],
          ),
        ),
        Switch.adaptive(value: value, onChanged: onChanged),
      ],
    );
  }

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
        // 远程引擎：默认关，开了才展开地址/Token/分开关
        _card(_remoteCard()),
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
