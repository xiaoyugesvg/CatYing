import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:file_picker/file_picker.dart';

import '../../../common/theme.dart';
import '../../../models/source_bean.dart';
import '../../../models/subscription.dart';
import '../../../services/api_config.dart';
import '../../../services/python_sources_service.dart';
import '../../subscription/view.dart';
import '../../../widgets/common_widgets.dart';
import '../controller.dart';
import 'settings_shared.dart';
import '../../../widgets/app_toast.dart';

/// 设置 → 数据源
///
/// 从原 settings/view.dart 拆出：点播接口地址（含历史切换/长按移除）、
/// 主页数据源、重置配置。
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
      title: '数据源',
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
            // 把「当前手填的接口地址」一键存成订阅。
            // 否则用户手填了地址，订阅列表一直显示"未添加"，
            // 没有一个明确的转化入口（你截图里就是这个情况）。
            Obx(() {
              final cur = controller.vodApiUrl.value.trim();
              if (cur.isEmpty) return const SizedBox.shrink();
              final already = SubscriptionService.instance.subscriptions.any(
                (s) => s.url.trim() == cur,
              );
              if (already) return const SizedBox.shrink();
              return SettingsRow(
                icon: Icons.playlist_add,
                title: '存为订阅',
                value: '当前地址',
                onTap: _saveCurrentAsSubscription,
              );
            }),
            Obx(
              () => SettingsRow(
                icon: Icons.dns_outlined,
                title: '主页数据源',
                value: ApiConfig.instance.homeSourceBean.value?.name ?? '未选择',
                onTap: _showSourcePicker,
              ),
            ),
            SettingsRow(
              icon: Icons.code_rounded,
              title: '导入 Python 视频源',
              value: '.py 文件 → 注册为线路',
              onTap: _importPythonVideoSource,
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
  // 导入 Python 视频源
  // ============================================================

  /// 选 .py 文件 → 注册进 CPython 引擎（video kind）→ 生成一条线路。
  ///
  /// 生成的 SourceBean：`api = py_<key>.py`（SpiderService 识别 .py 结尾即走
  /// Python 引擎），type=3（脚本源），可直接搜/播。
  Future<void> _importPythonVideoSource() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['py'],
      );
      if (result.isEmpty) return;
      final f = result.first;
      String code;
      try {
        code = await f.readAsString();
      } catch (_) {
        final path = f.path;
        if (path == null) {
          AppToast.message('读不出这个文件（没有本地路径）');
          return;
        }
        code = await File(path).readAsString();
      }
      if (code.trim().isEmpty) {
        AppToast.message('文件是空的');
        return;
      }
      final fileName = f.name.endsWith('.py')
          ? f.name.substring(0, f.name.length - 3)
          : f.name;
      final key = fileName.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
      if (key.isEmpty) {
        AppToast.message('文件名不合法');
        return;
      }
      final installed =
          await PythonSourcesService.instance.installSource('video', key, code);
      if (!installed.ok) {
        AppToast.message('注册失败：${installed.message ?? '未知错误'}');
        return;
      }
      // 加一条线路（重名则先移除旧线路，避免重复）
      final api = 'py_$key.py';
      final beans = ApiConfig.instance.sourceBeanList;
      beans.removeWhere((s) => s.key == key || s.api == api);
      beans.add(SourceBean(
        key: key,
        name: key,
        api: api,
        searchable: 1,
        filterable: 0,
        quickSearch: 0,
        playerType: 0,
        type: 3,
        ext: null,
        indexs: 0,
      ));
      AppToast.message('已导入 Python 视频源「$key」（线路 ${beans.length} 条）');
    } catch (e) {
      AppToast.message('导入失败：${e.toString().split('\n').first}');
    }
  }

  // ============================================================
  // 存为订阅
  // ============================================================

  /// 把手填的接口地址存进订阅列表并设为激活。
  Future<void> _saveCurrentAsSubscription() async {
    final messenger = ScaffoldMessenger.of(context);
    final url = controller.vodApiUrl.value.trim();
    if (url.isEmpty) {
      AppToast.message('还没有接口地址');
      return;
    }
    final svc = SubscriptionService.instance;
    // 带上分类：能按地址识别就识别，识别不出归「未分类」
    final s = await svc.add(url: url, kind: SubscriptionKind.inferKind(url));
    await svc.setActive(s.id);
    AppToast.message('已存为订阅：${s.name}');
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
                    title: Text(
                      source.name,
                      style: TextStyle(
                        color: isHome
                            ? AppTheme.accentColor
                            : AppTheme.textPrimary,
                        fontWeight: isHome
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
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
