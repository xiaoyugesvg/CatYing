import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../common/theme.dart';
import '../../widgets/common_widgets.dart';
import '../../widgets/glass.dart';
import 'controller.dart';
import 'sub/about_settings_page.dart';
import 'sub/unified_theme_settings_page.dart';
import 'sub/cache_settings_page.dart';
import 'sub/danmu_settings_page.dart';
import 'sub/data_source_settings_page.dart';
import 'sub/home_pages_settings_page.dart';
import 'sub/metadata_settings_page.dart';
import 'sub/playback_settings_page.dart';

/// 设置主页面
///
/// 这里**只列分类**，点进各自的子页修改。原来是一个 1800 行的长滚动页，
/// 8 个区块全堆在上面：找一项要滚很久，而且每个区块的弹窗/状态都挤在同一个
/// State 里，改一处容易碰到别处。
///
/// 各分类对应的子页：
/// - 主题与外观   → sub/unified_theme_settings_page.dart
///   ⚠️ 旧 `sub/appearance_settings_page.dart` 已**没有任何导航入口**
///   （全仓库无人 import、无人 `Get.to`）。它独有的「界面字号」「首页主题」
///   两个入口已搬进统一页，原文件仅为参考保留。
/// - 订阅与数据源 → sub/data_source_settings_page.dart
/// - 播放设置     → sub/playback_settings_page.dart
/// - 弹幕         → sub/danmu_settings_page.dart
/// - 元数据刮削   → sub/metadata_settings_page.dart
/// - 缓存         → sub/cache_settings_page.dart
/// - 关于         → sub/about_settings_page.dart
/// - 直播源管理   → 已有独立页（路由 /live/settings）
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
            padding: const EdgeInsets.fromLTRB(
              AppTheme.spacingLG,
              AppTheme.spacingLG,
              AppTheme.spacingLG,
              AppTheme.spacingLG + 96,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
              Center(
                child: Text(
                  '设置',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontTitle3,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: AppTheme.spacingXXL),

              // 主页面只列分类，点进去各页修改（对齐参考图的分类列表样式）
              _categoryTile(
                icon: Icons.brightness_6_outlined,
                // 指向**统一主题页**（影视/直播/音乐 分区可调 + 阅读入口）。
                // 原来的「外观」页只有浅色/深色/跟随系统，**没有配色方案** ——
                // 这就是"外观设置只有三种模式、很单调"的原因。
                title: '主题与外观',
                onTap: () => Get.to(() => const UnifiedThemeSettingsPage()),
              ),
              const SizedBox(height: AppTheme.spacingSM),
              _categoryTile(
                icon: Icons.dashboard_customize_outlined,
                title: '主页页面',
                onTap: () => Get.to(() => const HomePagesSettingsPage()),
              ),
              const SizedBox(height: AppTheme.spacingXXL),

              // 数据源
              _categoryTile(
                icon: Icons.movie_outlined,
                title: '订阅与数据源',
                onTap: () => Get.to(() => const DataSourceSettingsPage()),
              ),
              const SizedBox(height: AppTheme.spacingXXL),

              // 播放
              _categoryTile(
                icon: Icons.play_circle_outline,
                title: '播放设置',
                onTap: () => Get.to(() => const PlaybackSettingsPage()),
              ),
              const SizedBox(height: AppTheme.spacingSM),
              _categoryTile(
                icon: Icons.live_tv_outlined,
                title: '直播源管理',
                onTap: () => Get.toNamed('/live/settings'),
              ),
              const SizedBox(height: AppTheme.spacingXXL),

              // 内容增强
              _categoryTile(
                icon: Icons.subtitles,
                title: '弹幕',
                onTap: () => Get.to(() => const DanmuSettingsPage()),
              ),
              const SizedBox(height: AppTheme.spacingSM),
              _categoryTile(
                icon: Icons.movie_filter_outlined,
                title: '元数据刮削',
                onTap: () => Get.to(() => const MetadataSettingsPage()),
              ),
              const SizedBox(height: AppTheme.spacingXXL),

              // 存储与信息
              _categoryTile(
                icon: Icons.cleaning_services_outlined,
                title: '缓存',
                onTap: () => Get.to(() => const CacheSettingsPage()),
              ),
              const SizedBox(height: AppTheme.spacingSM),
              _categoryTile(
                icon: Icons.info_outline,
                title: '关于',
                onTap: () => Get.to(() => const AboutSettingsPage()),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  }

  // ============================================================
  // 分类入口卡片
  // ============================================================

  /// 分类入口：图标 + 标题 + 副标题 + 右侧箭头。
  ///
  /// 为什么不复用 [SettingsRow]：那是「左标题 + 右侧值」的单行结构，
  /// 而参考图的分类入口是「标题 + 下方说明」两行结构。
  Widget _categoryTile({
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return GlassPress(
      onTap: onTap,
      pressedScale: 0.975,
      child: AppCard(
        dense: true,
        child: Padding(
          // 按你的要求：不要副标题，行内边距也放开一些，别那么紧
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.spacingSM,
            vertical: 15,
          ),
          child: Row(
            children: [
              // 图标放进小圆角容器（Liquid Glass 的应用图标式底板）
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppTheme.accentColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: AppTheme.accentColor.withValues(alpha: 0.22),
                    width: 0.5,
                  ),
                ),
                child: Icon(icon, size: 18, color: AppTheme.accentColor),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontSubhead + 1.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(Icons.chevron_right,
                  size: 18,
                  color: AppTheme.textTertiary.withValues(alpha: 0.7)),
            ],
          ),
        ),
      ),
    );
  }
}
