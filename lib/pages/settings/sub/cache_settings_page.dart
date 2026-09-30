import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../common/theme.dart';
import '../../../widgets/common_widgets.dart';
import '../controller.dart';
import 'data_cleanup_page.dart';
import 'settings_shared.dart';

/// 清除应用缓存的粒度
enum _ClearCacheAction { cancel, itemsOnly, all }

/// 设置 → 缓存
///
/// 从原 settings/view.dart 拆出：源文件缓存开关、自动清理周期、
/// 清理源文件 JS、清除应用缓存（两个粒度）。
class CacheSettingsPage extends StatefulWidget {
  const CacheSettingsPage({super.key});

  @override
  State<CacheSettingsPage> createState() => _CacheSettingsPageState();
}

class _CacheSettingsPageState extends State<CacheSettingsPage> {
  SettingsController get controller => Get.find<SettingsController>();

  bool _sourceCacheEnabled = true;
  int _autoCleanIndex = 0;

  static const _autoCleanLabels = ['关闭', '每天', '每周', '每月'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _sourceCacheEnabled =
          prefs.getBool('source_cache_enabled') ?? true;
      _autoCleanIndex = prefs.getInt('source_cache_auto_clean') ?? 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '缓存',
      children: [
        SettingsGroup(
          children: [
            SettingsRow(
              icon: Icons.offline_bolt_outlined,
              title: '源文件缓存',
              value: _sourceCacheEnabled ? '已开启' : '已关闭',
              onTap: () async {
                setState(
                    () => _sourceCacheEnabled = !_sourceCacheEnabled);
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool(
                    'source_cache_enabled', _sourceCacheEnabled);
              },
            ),
            SettingsRow(
              icon: Icons.auto_delete_outlined,
              title: '自动清理缓存',
              value: _autoCleanLabels[_autoCleanIndex],
              onTap: _pickAutoClean,
            ),
            SettingsRow(
              icon: Icons.cleaning_services_outlined,
              title: '清理源文件缓存',
              value: '源 JS',
              onTap: () => controller.clearSourceCache(),
            ),
            Obx(() => SettingsRow(
                  icon: Icons.delete_outline,
                  title: '清除应用缓存',
                  value: controller.cacheSizeString.value,
                  onTap: _confirmClearCache,
                )),
            // 精细清理：按项勾选（缓存 / 用户数据），对应参考图的「数据清理」页
            SettingsRow(
              icon: Icons.checklist,
              title: '数据清理',
              value: '精细',
              onTap: () => Get.to(() => const DataCleanupPage()),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _pickAutoClean() async {
    final i = await SettingsDialogs.pick<int>(
      context: context,
      title: '自动清理缓存',
      options: List<int>.generate(_autoCleanLabels.length, (i) => i),
      selected: _autoCleanIndex,
      labelBuilder: (v) => _autoCleanLabels[v],
    );
    if (i == null) return;
    setState(() => _autoCleanIndex = i);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('source_cache_auto_clean', i);
  }

  /// 清除应用缓存前确认：分项说明清理范围，避免用户担心误清历史/收藏。
  Future<void> _confirmClearCache() async {
    final action = await showDialog<_ClearCacheAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusLG),
        ),
        title: Text('清除应用缓存',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          '「仅清页面数据」：首页列表 / 详情 / 刮削结果（图片保留，最省事）\n\n'
          '「全部清除」：\n'
          '· 图片缓存（内存 + 磁盘）\n'
          '· 视频切片与临时文件\n'
          '· 应用缓存目录\n'
          '· 页面缓存（首页列表 / 详情 / 刮削结果）\n\n'
          '都不会清除：观看历史、收藏、源文件 JS、播放设置\n'
          '清除后相关页面下次会重新联网获取',
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: AppTheme.fontSubhead,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _ClearCacheAction.cancel),
            child: Text('取消',
                style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, _ClearCacheAction.itemsOnly),
            child: Text('仅清页面数据',
                style: TextStyle(color: AppTheme.accentColor)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _ClearCacheAction.all),
            child: Text('全部清除',
                style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    switch (action) {
      case _ClearCacheAction.itemsOnly:
        await controller.clearBusinessCache();
      case _ClearCacheAction.all:
        await controller.clearCache();
      case _ClearCacheAction.cancel:
      case null:
        break;
    }
  }
}
