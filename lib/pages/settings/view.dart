import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../common/theme.dart';
import '../../services/api_config.dart';
import '../../services/background_service.dart';
import '../../pages/live/controller.dart';
import '../../models/source_bean.dart';
import '../../models/player_engine.dart';
import '../../widgets/common_widgets.dart';
import 'controller.dart';

/// 设置页 - 对应 Swift SettingsView
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final controller = Get.put(SettingsController());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 透明背景,让 ContentView 全局背景层透出
      backgroundColor: Colors.transparent,
      body: Container(
        color: Colors.transparent,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppTheme.spacingLG),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '设置',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontTitle3,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: AppTheme.spacingXXL),

                // 外观 - 自定义背景 (无主题切换, 始终深色)
                const SectionHeader(title: '外观'),
                const SizedBox(height: AppTheme.spacingSM),
                _buildAppearanceSection(),
                const SizedBox(height: AppTheme.spacingXXL),

                // 数据源
                const SectionHeader(title: '数据源'),
                const SizedBox(height: AppTheme.spacingSM),
                _buildDataSourceSection(),
                const SizedBox(height: AppTheme.spacingXXL),

                // 播放设置
                const SectionHeader(title: '播放设置'),
                const SizedBox(height: AppTheme.spacingSM),
                _buildPlayerSettingsSection(),
                const SizedBox(height: AppTheme.spacingXXL),

                // 缓存
                const SectionHeader(title: '缓存'),
                const SizedBox(height: AppTheme.spacingSM),
                _buildCacheSection(),
                const SizedBox(height: AppTheme.spacingXXL),

                // 关于
                const SectionHeader(title: '关于'),
                const SizedBox(height: AppTheme.spacingSM),
                _buildAboutSection(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 外观 - 自定义背景
  // ============================================================

  Widget _buildAppearanceSection() {
    final bg = BackgroundService.instance;
    return AppCard(
      child: Obx(() => SettingsRow(
            icon: Icons.wallpaper_outlined,
            title: '应用背景',
            value: bg.choice.value == BackgroundChoice.custom
                ? '自定义图片'
                : bg.currentDisplayName,
            onTap: () => _showBackgroundPicker(bg),
          )),
    );
  }

  /// 背景选择弹窗 - 4 个内置渐变 + 相册选择 + 清除自定义
  void _showBackgroundPicker(BackgroundService bg) {
    final previews = BackgroundService.builtinPreviews;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        title: const Text('选择应用背景',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: SizedBox(
          width: 360,
          child: Obx(() => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 4 个内置渐变预览
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 4,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: 0.85,
                    ),
                    itemCount: previews.length,
                    itemBuilder: (_, i) {
                      final p = previews[i];
                      final isSelected = bg.choice.value == p.choice;
                      return _BackgroundPreviewTile(
                        name: p.name,
                        colors: p.colors,
                        isSelected: isSelected,
                        onTap: () async {
                          await bg.setBuiltin(p.choice);
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  // 从相册选择
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppTheme.radiusMD),
                      onTap: () async {
                        // 关闭当前弹窗,异步选择图片
                        Navigator.pop(ctx);
                        await bg.pickFromGallery();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.backgroundTertiary,
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusMD),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.photo_library_outlined,
                                color: AppTheme.accentColor, size: 18),
                            const SizedBox(width: 10),
                            const Text(
                              '从相册选择图片',
                              style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: AppTheme.fontSubhead,
                              ),
                            ),
                            const Spacer(),
                            if (bg.choice.value == BackgroundChoice.custom)
                              const Icon(Icons.check_circle,
                                  color: AppTheme.accentColor, size: 16),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 清除自定义
                  if (bg.choice.value == BackgroundChoice.custom) ...[...]