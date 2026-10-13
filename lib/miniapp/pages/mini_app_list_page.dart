import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/glass.dart';
import '../models/builtin_apps.dart';
import '../models/mini_app.dart';
import '../services/mini_app_service.dart';
import 'mini_app_detail_page.dart';
import 'mini_app_maiyou_page.dart';
import 'mini_app_web_page.dart';

/// 「程序」tab 主页：已安装小程序网格 + 导入入口。
///
/// 作为影视悬浮导航栏的独立分类页使用（NavFeature.apps / tabIndex 7），
/// 也是设置页「小程序」管理入口的目标页。
class MiniAppListPage extends StatefulWidget {
  const MiniAppListPage({super.key});

  @override
  State<MiniAppListPage> createState() => _MiniAppListPageState();
}

class _MiniAppListPageState extends State<MiniAppListPage> {
  MiniAppService get service => MiniAppService.instance;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    service.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        color: Colors.transparent,
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              // ── 顶栏 ──────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppTheme.spacingMD,
                  AppTheme.spacingMD,
                  AppTheme.spacingMD,
                  0,
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 48),
                    Expanded(
                      child: Center(
                        child: Text(
                          '程序',
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: AppTheme.fontTitle3,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    // 添加程序
                    InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: _showAddSheet,
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Icon(
                          Icons.add_circle_outline,
                          size: 22,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppTheme.spacingMD),

              Expanded(
                child: Obx(() {
                  final apps = service.apps;
                  // 网格第一个位置固定是内置「新影视库」，后面是已导入程序
                  return _buildGrid(apps);
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 内置应用卡（官方市场/预置小程序）──────────────────────
  Widget _builtinCard(BuiltinMiniApp app) {
    final tint = app.tint ?? AppTheme.accentColor;
    return GlassPanel(
      radius: 16,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => Get.to(() => MiniAppWebPage(assetRoot: app.assetRoot)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      tint.withValues(alpha: 0.85),
                      tint.withValues(alpha: 0.45),
                    ],
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(app.icon, size: 26, color: Colors.white),
              ),
              const Spacer(),
              Text(
                app.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                app.tag,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 网格 ──────────────────────────────────────────────────────
  Widget _buildGrid(List<MiniApp> apps) {
    final builtins = builtinMiniApps;
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.spacingMD,
        0,
        AppTheme.spacingMD,
        110,
      ),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 140,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.78,
      ),
      itemCount: builtins.length + apps.length,
      itemBuilder: (context, index) {
        if (index < builtins.length) {
          return _builtinCard(builtins[index]);
        }
        final app = apps[index - builtins.length];
        if (app.isMaiyou) {
          return _MiniAppCard(
            app: app,
            tag: '直播订阅 · 麦优',
            onTap: () => Get.to(() => MiniAppMaiyouPage(appId: app.id)),
            onLongPress: () => _confirmRemove(app),
          );
        }
        final parsed = app.parsed;
        final videoCount =
            parsed.cmsSites.length + parsed.spiderSites.length;
        final liveCount = parsed.liveGroups
            .fold<int>(0, (sum, g) => sum + g.channels.length);
        final tags = <String>[
          if (videoCount > 0) '影视 $videoCount',
          if (liveCount > 0) '频道 $liveCount',
          if (parsed.hasInlineSpider) '内嵌脚本',
        ];
        return _MiniAppCard(
          app: app,
          tag: tags.join(' · '),
          onTap: () => Get.to(() => MiniAppDetailPage(appId: app.id)),
          onLongPress: () => _confirmRemove(app),
        );
      },
    );
  }

  void _confirmRemove(MiniApp app) {
    Get.dialog(
      AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text('删除程序',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
        content: Text(
          '删除「${app.name}」？其影视源会从视频源列表移除。',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Get.back();
              await service.remove(app);
              AppToast.message('已删除');
            },
            child: Text('删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  // ── 添加 ──────────────────────────────────────────────────────
  void _showAddSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppTheme.textSecondary.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                '添加程序',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontTitle3,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: AppTheme.spacingLG),
              _AddTile(
                icon: Icons.link,
                title: '网络导入',
                subtitle: '输入 TVBox 配置 JSON 地址',
                onTap: () {
                  Get.back();
                  _importFromUrlDialog();
                },
              ),
              const SizedBox(height: AppTheme.spacingMD),
              _AddTile(
                icon: Icons.content_paste,
                title: '粘贴 JSON',
                subtitle: '手动粘贴配置内容',
                onTap: () {
                  Get.back();
                  _importFromTextDialog();
                },
              ),
              const SizedBox(height: AppTheme.spacingMD),
              _AddTile(
                icon: Icons.folder_open,
                title: '本地文件',
                subtitle: '选择 .json 配置文件导入',
                onTap: () {
                  Get.back();
                  _importFromFile();
                },
              ),
              const SizedBox(height: AppTheme.spacingMD),
              _AddTile(
                icon: Icons.live_tv,
                title: '麦优直播订阅',
                subtitle: '输入麦优分类接口地址（json.txt）',
                onTap: () {
                  Get.back();
                  _importMaiyouDialog();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _importMaiyouDialog() async {
    final controller = TextEditingController();
    final ok = await Get.dialog<bool>(
      AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text('添加麦优直播订阅',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.url,
              style: TextStyle(color: AppTheme.textPrimary),
              decoration: InputDecoration(
                hintText: '如 http://api.maiyoux.com:81/mf/json.txt',
                hintStyle: TextStyle(color: AppTheme.textSecondary),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppTheme.borderMedium),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '订阅后以独立应用打开：分类浏览 → 频道播放',
              style: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Get.back(result: false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Get.back(result: true),
              child: const Text('添加')),
        ],
      ),
    );
    if (ok != true) return;
    final url = controller.text.trim();
    if (url.isEmpty) {
      AppToast.message('订阅地址不能为空');
      return;
    }
    await _run(() => MiniAppService.instance.importMaiyou(url));
  }

  Future<void> _importFromUrlDialog() async {
    final controller = TextEditingController();
    final ok = await Get.dialog<bool>(
      AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text('网络导入',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          style: TextStyle(color: AppTheme.textPrimary),
          decoration: InputDecoration(
            hintText: 'https://…/tvbox.json',
            hintStyle: TextStyle(color: AppTheme.textSecondary),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: AppTheme.borderMedium),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Get.back(result: false), child: const Text('取消')),
          TextButton(onPressed: () => Get.back(result: true), child: const Text('导入')),
        ],
      ),
    );
    if (ok != true) return;
    final url = controller.text.trim();
    if (url.isEmpty) {
      AppToast.message('地址不能为空');
      return;
    }
    await _run(() => service.importFromUrl(url));
  }

  Future<void> _importFromTextDialog() async {
    final controller = TextEditingController();
    final ok = await Get.dialog<bool>(
      AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text('粘贴 JSON',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
        content: SizedBox(
          height: 220,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: null,
            expands: true,
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              hintText: '{ "name": "…", "sites": […], "lives": […] }',
              hintStyle: TextStyle(color: AppTheme.textSecondary),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: AppTheme.borderMedium),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Get.back(result: false), child: const Text('取消')),
          TextButton(onPressed: () => Get.back(result: true), child: const Text('导入')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => service.importFromText(controller.text));
  }

  Future<void> _importFromFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json', 'txt'],
      );
      if (result.isEmpty) return;
      final f = result.first;
      final path = f.path;
      if (path == null) {
        AppToast.message('读不出这个文件（没有本地路径）');
        return;
      }
      await _run(() => service.importFromFile(path));
    } catch (e) {
      AppToast.message('选择文件失败: $e');
    }
  }

  Future<void> _run(
      Future<({bool ok, String? error})> Function() task) async {
    if (_busy) return;
    _busy = true;
    try {
      final result = await task();
      if (result.ok) {
        AppToast.message('导入成功');
      } else {
        AppToast.message(result.error ?? '导入失败');
      }
    } finally {
      _busy = false;
    }
  }
}

// ── 卡片 ────────────────────────────────────────────────────────
class _MiniAppCard extends StatelessWidget {
  final MiniApp app;
  final String tag;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _MiniAppCard({
    required this.app,
    required this.tag,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.palette;
    final color = palette.primary;
    final initial = app.name.isNotEmpty ? app.name.characters.first : '程';
    return GlassPanel(
      radius: 16,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 图标：圆角渐变块 + 首字
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      color.withValues(alpha: 0.85),
                      color.withValues(alpha: 0.55),
                    ],
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  initial,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                app.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                tag,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _AddTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        child: Row(
          children: [
            Icon(icon, size: 22, color: AppTheme.textPrimary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12)),
                ],
              ),
            ),
            Icon(Icons.chevron_right,
                size: 18, color: AppTheme.textSecondary),
          ],
        ),
      ),
    );
  }
}
