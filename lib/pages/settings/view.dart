import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../../common/theme.dart';
import '../../widgets/common_widgets.dart';
import '../../widgets/glass.dart';
import 'controller.dart';
import 'sub/about_settings_page.dart';
import 'sub/appearance_settings_page.dart';
import 'sub/cache_settings_page.dart';
import 'sub/danmu_settings_page.dart';
import 'sub/data_source_settings_page.dart';
import 'sub/metadata_settings_page.dart';
import 'sub/playback_settings_page.dart';

/// 设置主页面
///
/// 这里**只列分类**，点进各自的子页修改。原来是一个 1800 行的长滚动页，
/// 8 个区块全堆在上面：找一项要滚很久，而且每个区块的弹窗/状态都挤在同一个
/// State 里，改一处容易碰到别处。
///
/// 各分类对应的子页：
/// - 外观与壁纸   → sub/appearance_settings_page.dart
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
              Text(
                '设置',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontTitle3,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: AppTheme.spacingXXL),

              // 主页面只列分类，点进去各页修改（对齐参考图的分类列表样式）
              const SectionHeader(title: '外观'),
              const SizedBox(height: AppTheme.spacingSM),
              _categoryTile(
                icon: Icons.brightness_6_outlined,
                title: '外观与壁纸',
                subtitle: '外观模式、壁纸背景、界面字号、首页主题',
                onTap: () => Get.to(() => const AppearanceSettingsPage()),
              ),
              const SizedBox(height: AppTheme.spacingXXL),

              // 数据源
              const SectionHeader(title: '数据源'),
              const SizedBox(height: AppTheme.spacingSM),
              _categoryTile(
                icon: Icons.movie_outlined,
                title: '订阅与数据源',
                subtitle: '点播接口地址、主页数据源、重置配置',
                onTap: () => Get.to(() => const DataSourceSettingsPage()),
              ),
              const SizedBox(height: AppTheme.spacingXXL),

              // 播放
              const SectionHeader(title: '播放'),
              const SizedBox(height: AppTheme.spacingSM),
              _categoryTile(
                icon: Icons.play_circle_outline,
                title: '播放设置',
                subtitle: '播放内核、缓冲解码、快进与跳过片头尾',
                onTap: () => Get.to(() => const PlaybackSettingsPage()),
              ),
              const SizedBox(height: AppTheme.spacingSM),
              _categoryTile(
                icon: Icons.live_tv_outlined,
                title: '直播源管理',
                subtitle: '全局 EPG、屏蔽分类',
                onTap: () => Get.toNamed('/live/settings'),
              ),
              const SizedBox(height: AppTheme.spacingXXL),

              // 内容增强
              const SectionHeader(title: '内容增强'),
              const SizedBox(height: AppTheme.spacingSM),
              _categoryTile(
                icon: Icons.subtitles,
                title: '弹幕',
                subtitle: '弹幕 API、样式、屏蔽关键词',
                onTap: () => Get.to(() => const DanmuSettingsPage()),
              ),
              const SizedBox(height: AppTheme.spacingSM),
              _categoryTile(
                icon: Icons.movie_filter_outlined,
                title: '元数据刮削',
                subtitle: 'TMDB Key、自动刮削、演职员与类似作品',
                onTap: () => Get.to(() => const MetadataSettingsPage()),
              ),
              const SizedBox(height: AppTheme.spacingXXL),

              // 存储与信息
              const SectionHeader(title: '存储与信息'),
              const SizedBox(height: AppTheme.spacingSM),
              _categoryTile(
                icon: Icons.cleaning_services_outlined,
                title: '缓存',
                subtitle: '源文件缓存、自动清理周期、清除应用缓存',
                onTap: () => Get.to(() => const CacheSettingsPage()),
              ),
              const SizedBox(height: AppTheme.spacingSM),
              _categoryTile(
                icon: Icons.info_outline,
                title: '关于',
                subtitle: '版本信息、站点与解析数量',
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
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return GlassPress(
      onTap: onTap,
      pressedScale: 0.975,
      child: AppCard(
        dense: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppTheme.spacingXS,
            vertical: 8,
          ),
          child: Row(
            children: [
              // 图标放进小圆角容器（Liquid Glass 的应用图标式底板）
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppTheme.accentColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: AppTheme.accentColor.withValues(alpha: 0.22),
                    width: 0.5,
                  ),
                ),
                child: Icon(icon, size: 17, color: AppTheme.accentColor),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontSubhead + 0.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right,
                  size: 17,
                  color: AppTheme.textTertiary.withValues(alpha: 0.7)),
            ],
          ),
        ),
      ),
    );
  }
}
