import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/theme.dart';
import '../../../models/subscription.dart';
import '../../../services/api_config.dart';
import '../../../services/source_kind.dart';
import '../../../rss/pages/rss_manage_page.dart';
import '../../../rss/services/rss_store.dart';
import '../../../webhome/web_home_manage_page.dart';
import '../../../webhome/web_home_prefs.dart';
import '../../subscription/view.dart';
import '../../../widgets/common_widgets.dart';
import '../../../widgets/source_kind_badge.dart';
import '../controller.dart';
import 'engine_settings_page.dart';
import 'parse_settings_page.dart';
import 'settings_shared.dart';

/// 设置 → 订阅管理
///
/// 从原 settings/view.dart 拆出：订阅列表、点播接口地址（含历史切换/长按移除）、
/// 主页数据源、引擎管理、重置配置。
class DataSourceSettingsPage extends StatefulWidget {
  const DataSourceSettingsPage({super.key});

  @override
  State<DataSourceSettingsPage> createState() => _DataSourceSettingsPageState();
}

class _DataSourceSettingsPageState extends State<DataSourceSettingsPage> {
  /// 复用主设置页注册的 SettingsController（本页只能从设置页进入，
  /// 所以它一定已注册）；用 find 而非 put，避免意外新建实例。
  SettingsController get controller => Get.find<SettingsController>();

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      // 用户 2026-10-13：顶栏「数据源」→「订阅管理」
      title: '订阅管理',
      children: [
        SettingsGroup(
          title: '订阅',
          children: [
            Obx(() {
              final svc = SubscriptionService.instance;
              final a = svc.active;
              return SettingsRow(
                icon: Icons.rss_feed,
                title: '订阅管理',
                // 显示当前激活的订阅名 + 条数，一眼知道在用哪个
                value: a == null
                    ? '未添加'
                    : '${a.name}（${svc.subscriptions.length} 个）',
                onTap: () => Get.to(() => const SubscriptionPage()),
              );
            }),
          ],
        ),
        // 分组之间留出一整段空白：SettingsGroup 自身只在**有 title 时**加 10+6px 内边距，
        // 第二组没 title ⇒ 两块卡片会直接贴在一起、圆角叠成一个怪形状。
        // ⚠️ 只给 16(spacingLG) 用户仍嫌不够（2026-10-13：「距离还他么没加大吗」）
        //    ⇒ 用 24(spacingXXL)，与订阅管理页「组与组之间留一整段空白」同一取值。
        const SizedBox(height: AppTheme.spacingXXL),
        SettingsGroup(
          children: [
            Obx(
              () => SettingsRow(
                icon: Icons.movie_outlined,
                title: '点播接口地址',
                value: controller.vodApiUrl.value.isEmpty
                    ? '未配置'
                    : _truncateUrl(controller.vodApiUrl.value),
                onTap: _showApiEditDialog,
              ),
            ),
            // 「存为订阅」入口已删（用户 2026-10-13：「第一次输入的那个源不要还
            // 他么的存为订阅，而是直接就是存为订阅」）——
            // 现在**输入/加载地址就等于存订阅**，见 _autoSaveAsSubscription()。
            Obx(
              () => SettingsRow(
                icon: Icons.dns_outlined,
                title: '主页数据源',
                value: ApiConfig.instance.homeSourceBean.value?.name ?? '未选择',
                onTap: _showSourcePicker,
              ),
            ),
            // 解析线路管理（用户 2026-10-14）：从订阅拉到的解析线路会**落盘**，
            // 换订阅不再清空；播放器底栏「解析」按钮切的线路也是这里选的。
            Obx(
              () => SettingsRow(
                icon: Icons.link_rounded,
                title: '解析线路管理',
                value: '${ApiConfig.instance.parseBeanList.length} 条',
                onTap: () => Get.to(() => const ParseSettingsPage()),
              ),
            ),
            // 网页管理（用户 2026-10-14）：内置/订阅/本地导入的网页源，
            // 可切换、可拖动排序 —— 与「网页」页顶栏右边的设置按钮是同一页。
            //
            // ⚠️ 这里**不能包 `Obx`**（用户 2026-10-15 报「订阅管理里一条长白条」）：
            //   `WebHomePrefs.sources` 是**普通 List**、不是 Rx，`Obx` 找不到
            //   observable 会直接抛错 ⇒ 该子树塌成 ErrorWidget（就是那条灰白条），
            //   并把下面所有行一起吃掉 ✗。改成「返回本页后 setState 刷新」。
            SettingsRow(
              icon: Icons.language_outlined,
              title: 'Webhtv 管理',
              value: '${WebHomePrefs.instance.sources.length} 个网页',
              onTap: () async {
                await Get.to(() => const WebHomeManagePage());
                if (mounted) setState(() {});
              },
            ),
            // RSS 管理（用户 2026-10-15）：订阅源导入（JSON / OPML / 本地文件）、
            // 启用停用、删除 —— 与「RSS」页顶栏右边的 ⚙ 是同一页。
            // ⚠️ 同「网页管理」：`RssStore.sources` 也不是 Rx，别用 `Obx`。
            SettingsRow(
              icon: Icons.rss_feed_outlined,
              title: 'RSS 管理',
              value: '${RssStore.instance.sources.length} 个订阅源',
              onTap: () async {
                await Get.to(() => const RssManagePage());
                if (mounted) setState(() {});
              },
            ),
            // 引擎管理（Node / Python 手动加载）—— 用户 2026-10-13：
            // 从「通用设置」挪到这里（订阅管理页）
            SettingsRow(
              icon: Icons.memory_outlined,
              title: '引擎管理',
              value: 'Node / Python 手动加载',
              onTap: () => Get.to(() => const EngineSettingsPage()),
            ),
            SettingsRow(
              icon: Icons.restart_alt,
              iconColor: Colors.redAccent,
              title: '重置配置',
              titleColor: Colors.redAccent,
              value: '回到初始',
              onTap: _showResetConfigDialog,
            ),
          ],
        ),
      ],
    );
  }

  // ============================================================
  // 自动存为订阅
  // ============================================================

  /// 输入/加载接口地址 = **自动存为订阅**（不再需要单独的「存为订阅」按钮）。
  ///
  /// 幂等：地址已在订阅列表里就只切激活，不重复添加。
  Future<void> _autoSaveAsSubscription() async {
    final url = controller.vodApiUrl.value.trim();
    if (url.isEmpty) return;
    final svc = SubscriptionService.instance;
    Subscription? exist;
    for (final s in svc.subscriptions) {
      if (s.url.trim() == url) {
        exist = s;
        break;
      }
    }
    if (exist != null) {
      if (svc.activeId.value != exist.id) await svc.setActive(exist.id);
      return;
    }
    // 分类按地址保守推断（.py → PY源；.js/.js.md5/.jar → CatVod 猫源；其余未分类）
    final s = await svc.add(url: url, kind: SubscriptionKind.inferKind(url));
    await svc.setActive(s.id);
  }

  // ============================================================
  // 点播接口地址编辑（含历史记录）
  // ============================================================

  void _showApiEditDialog() {
    final vodController = TextEditingController(
      text: controller.vodApiUrl.value,
    );

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final history = controller.apiHistory.toList();
            return AlertDialog(
              backgroundColor: AppTheme.backgroundSecondary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppTheme.radiusLG),
              ),
              title: Text(
                '点播接口地址',
                style: TextStyle(color: AppTheme.textPrimary),
              ),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (history.isNotEmpty) ...[
                      Text(
                        '切换数据源',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: AppTheme.fontCaption,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 180),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: history.length,
                          itemBuilder: (_, i) {
                            final url = history[i];
                            final selected = url == controller.vodApiUrl.value;
                            return InkWell(
                              borderRadius: BorderRadius.circular(
                                AppTheme.radiusSM,
                              ),
                              onTap: () {
                                vodController.text = url;
                                setDialogState(() {});
                              },
                              onLongPress: () async {
                                final ok = await SettingsDialogs.confirm(
                                  context: context,
                                  title: '移除数据源',
                                  message: _truncateUrl(url),
                                  confirmText: '移除',
                                );
                                if (ok) {
                                  await controller.removeApiHistory(url);
                                  setDialogState(() {});
                                }
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 6,
                                  horizontal: 4,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      selected
                                          ? Icons.radio_button_checked
                                          : Icons.radio_button_off,
                                      size: 18,
                                      color: selected
                                          ? AppTheme.accentColor
                                          : AppTheme.textTertiary,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        _truncateUrl(url),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: selected
                                              ? AppTheme.accentColor
                                              : AppTheme.textPrimary,
                                          fontSize: AppTheme.fontSubhead,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 12),
                      Divider(color: AppTheme.borderLight, height: 1),
                      const SizedBox(height: 12),
                      Text(
                        '手动输入 / 修改',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: AppTheme.fontCaption,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    TextField(
                      controller: vodController,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontSubhead,
                      ),
                      decoration: InputDecoration(
                        hintText: '输入点播接口地址',
                        hintStyle: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontSubhead,
                        ),
                        filled: true,
                        fillColor: AppTheme.backgroundTertiary,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(
                            AppTheme.radiusSM,
                          ),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        isDense: true,
                        prefixIcon: Icon(
                          Icons.movie_outlined,
                          size: 18,
                          color: AppTheme.textTertiary,
                        ),
                      ),
                    ),
                    Obx(() {
                      if (controller.isLoadingConfig.value) {
                        return Padding(
                          padding: const EdgeInsets.only(
                            top: AppTheme.spacingSM,
                          ),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppTheme.accentColor,
                                ),
                              ),
                              const SizedBox(width: AppTheme.spacingSM),
                              Text(
                                '正在加载配置...',
                                style: TextStyle(
                                  color: AppTheme.textSecondary,
                                  fontSize: AppTheme.fontCaption,
                                ),
                              ),
                            ],
                          ),
                        );
                      }
                      if (controller.configError.value != null) {
                        return Padding(
                          padding: const EdgeInsets.only(
                            top: AppTheme.spacingSM,
                          ),
                          child: Text(
                            controller.configError.value!,
                            style: const TextStyle(
                              color: Colors.red,
                              fontSize: AppTheme.fontCaption,
                            ),
                          ),
                        );
                      }
                      if (controller.configSuccess.value) {
                        return Padding(
                          padding: const EdgeInsets.only(
                            top: AppTheme.spacingSM,
                          ),
                          child: Text(
                            '配置加载成功',
                            style: TextStyle(
                              color: AppTheme.accentColor,
                              fontSize: AppTheme.fontCaption,
                            ),
                          ),
                        );
                      }
                      return const SizedBox.shrink();
                    }),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(
                    '取消',
                    style: TextStyle(color: AppTheme.textTertiary),
                  ),
                ),
                Obx(
                  () => TextButton(
                    onPressed: controller.isLoadingConfig.value
                        ? null
                        : () {
                            controller.vodApiUrl.value = vodController.text
                                .trim();
                            // 用户 2026-10-13：输入地址即订阅（不再要点「存为订阅」）
                            _autoSaveAsSubscription();
                            controller.loadConfig();
                            Navigator.pop(ctx);
                          },
                    child: Text(
                      '加载',
                      style: TextStyle(color: AppTheme.accentColor),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ============================================================
  // 主页数据源选择
  // ============================================================

  void _showSourcePicker() {
    final sources = ApiConfig.instance.sourceBeanList;
    if (sources.isEmpty) {
      _showApiEditDialog();
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        title: Text('主页数据源', style: TextStyle(color: AppTheme.textPrimary)),
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
          '将清除已保存的点播接口地址、接口历史以及已下载的源缓存。\n\n'
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
              '请退出应用后重新打开，\n将进入初始设置界面。',
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

  String _truncateUrl(String url) {
    if (url.length <= 30) return url;
    return '${url.substring(0, 27)}...';
  }
}
