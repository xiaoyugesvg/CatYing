import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/book_content_cache_service.dart';
import '../services/settings_service.dart';
import '../theme/jelly_theme.dart';
import '../../common/theme.dart';
import '../../widgets/app_image_cache.dart';

/// 下载设置页（参考图 IMG_8466~8468）。
/// 结构与「阅读设置」保持一致：分组标题 + 独立小卡片（圆角 16）。
class DownloadSettingsPage extends StatefulWidget {
  const DownloadSettingsPage({super.key});

  @override
  State<DownloadSettingsPage> createState() => _DownloadSettingsPageState();
}

class _DownloadSettingsPageState extends State<DownloadSettingsPage> {
  // 在线书临时缓存统计（磁盘解析缓存）
  int _bookCacheBytes = 0;
  int _bookCacheChapters = 0;
  // 在线漫画图片缓存统计
  int _imageCacheBytes = 0;
  bool _cacheLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadCacheStats();
  }

  Future<void> _loadCacheStats() async {
    final bookBytes = await BookContentCacheService.instance.sizeBytes();
    final chapters = await _bookCacheFileCount();
    var imageBytes = 0;
    try {
      imageBytes = await _imageCacheSize();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _bookCacheBytes = bookBytes;
      _bookCacheChapters = chapters;
      _imageCacheBytes = imageBytes;
      _cacheLoaded = true;
    });
  }

  /// 统计 appImageCacheManager 磁盘缓存（临时目录 cached_network_image_ce）
  Future<int> _imageCacheSize() async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/cached_network_image_ce');
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  Future<int> _bookCacheFileCount() async {
    try {
      final d = await BookContentCacheService.instance.cacheDir();
      if (!await d.exists()) return 0;
      var n = 0;
      await for (final e in d.list(followLinks: false)) {
        if (e is File) n++;
      }
      return n;
    } catch (_) {
      return 0;
    }
  }

  String _fmt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  Future<void> _clearBookCache() async {
    await BookContentCacheService.instance.clear();
    await _loadCacheStats();
  }

  Future<void> _clearImageCache() async {
    try {
      await appImageCacheManager.emptyCache();
    } catch (_) {}
    await _loadCacheStats();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('下载设置')),
      body: ListenableBuilder(
        listenable: SettingsService(),
        builder: (context, _) {
          final s = SettingsService();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // ── 通用 ────────────────────────────────────────
              _sectionTitle('通用'),
              const SizedBox(height: 8),
              _buildSaveLocationCard(context, isDark, s),
              const SizedBox(height: 12),
              _buildSwitchCard(
                isDark: isDark,
                title: '后台下载',
                subtitle: '切到后台或息屏时继续下载',
                value: s.backgroundDownload,
                onChanged: s.setBackgroundDownload,
              ),
              const SizedBox(height: 12),
              _buildSwitchCard(
                isDark: isDark,
                title: '仅 Wi-Fi 下载',
                subtitle: '使用移动网络时自动暂停，回到 Wi-Fi 自动继续',
                value: s.wifiOnlyDownload,
                onChanged: s.setWifiOnlyDownload,
              ),
              const SizedBox(height: 16),

              // ── 图书 · 书源 ────────────────────────────────
              _sectionTitle('图书 · 书源'),
              const SizedBox(height: 8),
              _buildSwitchCard(
                isDark: isDark,
                title: '图书使用内置账号',
                subtitle: '关闭后需登录才能下载',
                value: s.useBuiltinAccount,
                onChanged: s.setUseBuiltinAccount,
              ),
              const SizedBox(height: 12),
              _buildSliderCard(
                isDark: isDark,
                title: '书源下载并发量',
                subtitle: '在线书源任务同时下载的章节数',
                value: s.bookSourceConcurrency,
                min: SettingsService.minBookSourceConcurrency,
                max: SettingsService.maxBookSourceConcurrency,
                onChanged: (v) => s.setBookSourceConcurrency(v.round()),
              ),
              const SizedBox(height: 12),
              _buildSliderCard(
                isDark: isDark,
                title: '图书文件下载并发量',
                subtitle: '允许同时下载的图书文件数',
                value: s.bookFileConcurrency,
                min: SettingsService.minBookFileConcurrency,
                max: SettingsService.maxBookFileConcurrency,
                onChanged: (v) => s.setBookFileConcurrency(v.round()),
              ),
              const SizedBox(height: 12),
              _buildSliderCard(
                isDark: isDark,
                title: '在线书临时缓存',
                subtitle: '超过上限按最久未读章节自动淘汰',
                value: s.onlineBookCacheGb,
                min: SettingsService.minOnlineCacheGb,
                max: SettingsService.maxOnlineCacheGb,
                unit: ' GB',
                onChanged: (v) => s.setOnlineBookCacheGb(v.round()),
              ),
              const SizedBox(height: 12),
              _buildSwitchCard(
                isDark: isDark,
                title: '缓存全本固定保护',
                subtitle: '已下载全本的书不会被临时缓存淘汰',
                value: s.protectFullBookCache,
                onChanged: s.setProtectFullBookCache,
              ),
              const SizedBox(height: 12),
              _buildCacheStatCard(
                isDark: isDark,
                title: '临时缓存',
                text: _cacheLoaded
                    ? '临时 ${_fmt(_bookCacheBytes)} · 固定 0.0 KB · $_bookCacheChapters 章'
                    : '统计中…',
                onClear: _clearBookCache,
              ),
              const SizedBox(height: 16),

              // ── 漫画 ────────────────────────────────────────
              _sectionTitle('漫画'),
              const SizedBox(height: 8),
              _buildSliderCard(
                isDark: isDark,
                title: '下载并发量',
                subtitle: '允许同时下载的章节数',
                value: s.maxConcurrentChapters,
                min: SettingsService.minConcurrentChapters,
                max: SettingsService.maxConcurrentChaptersLimit,
                onChanged: (v) => s.setMaxConcurrentChapters(v.round()),
              ),
              const SizedBox(height: 12),
              _buildSliderCard(
                isDark: isDark,
                title: '图片分片并发量',
                subtitle: '单个章节同时下载的图片数',
                value: s.maxConcurrentImages,
                min: SettingsService.minConcurrentImages,
                max: SettingsService.maxConcurrentImagesLimit,
                onChanged: (v) => s.setMaxConcurrentImages(v.round()),
              ),
              const SizedBox(height: 12),
              _buildSliderCard(
                isDark: isDark,
                title: '在线漫画图片缓存',
                subtitle: '超过上限按最久未看自动淘汰，正式下载文件不受影响',
                value: s.onlineComicCacheGb,
                min: SettingsService.minOnlineCacheGb,
                max: SettingsService.maxOnlineCacheGb,
                unit: ' GB',
                onChanged: (v) => s.setOnlineComicCacheGb(v.round()),
              ),
              const SizedBox(height: 12),
              _buildCacheStatCard(
                isDark: isDark,
                title: '图片缓存',
                text: _cacheLoaded
                    ? '图片 ${_fmt(_imageCacheBytes)} · 目录 ${_fmt(_imageCacheBytes)}'
                    : '统计中…',
                onClear: _clearImageCache,
              ),
              const SizedBox(height: 12),
              _buildInfoCard(isDark, '下载格式', 'EPUB'),
              const SizedBox(height: 12),
              _buildSliderCard(
                isDark: isDark,
                title: '每N话合并为一个章节',
                subtitle: s.mergeChapterToEpub
                    ? (s.mergeChaptersPerEpub >= 101
                        ? '无限：整本合并为一个 EPUB'
                        : '下载时每 ${s.mergeChaptersPerEpub} 话合并成一个 EPUB')
                    : '需先开启「漫画章节合并为 EPUB」',
                value: s.mergeChaptersPerEpub,
                min: SettingsService.minMergeChaptersPerEpub,
                max: SettingsService.maxMergeChaptersPerEpub,
                isInfinite: true,
                infiniteLabel: '101 = 无限（整本）',
                enabled: s.mergeChapterToEpub,
                onChanged: (v) => s.setMergeChaptersPerEpub(v.round()),
              ),
              const SizedBox(height: 12),
              _buildSwitchCard(
                isDark: isDark,
                title: '失败或缺页时暂停合并',
                subtitle: '合并遇到失败或缺页时暂停，等待手动处理',
                value: s.pauseMergeOnError,
                onChanged: s.setPauseMergeOnError,
              ),
              const SizedBox(height: 12),
              _buildSwitchCard(
                isDark: isDark,
                title: '合并后保留图片',
                subtitle: s.mergeChapterToEpub
                    ? '保留原图用于 App 内离线阅读；关闭则仅保留 EPUB'
                    : '需先开启「漫画章节合并为 EPUB」',
                value: s.keepImagesAfterEpub,
                enabled: s.mergeChapterToEpub,
                onChanged: s.setKeepImagesAfterEpub,
              ),
              const SizedBox(height: 12),
              _buildSwitchCard(
                isDark: isDark,
                title: '下载去白边',
                subtitle: '下载时自动裁剪漫画图片四周白边，提升阅读体验',
                value: s.trimWhitespace,
                onChanged: s.setTrimWhitespace,
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '提示：并发量越大，下载越快但越易触发站点风控；'
                  '在线缓存上限按 GB 设置，超出后自动淘汰最久未读章节。',
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 分组标题（与「阅读设置」页一致：fontSubhead/w600）
  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: AppTheme.fontSubhead,
          fontWeight: FontWeight.w600,
          color: JellyTheme.textSecondary,
        ),
      ),
    );
  }

  /// 保存位置卡片
  Widget _buildSaveLocationCard(
    BuildContext context,
    bool isDark,
    SettingsService s,
  ) {
    final custom = s.downloadSavePath;
    final hasCustom = custom != null && custom.isNotEmpty;
    final display = hasCustom ? custom : '默认（应用私有目录）';
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.folder_rounded, color: JellyTheme.primary, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '保存位置',
                  style: TextStyle(
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  display,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (hasCustom)
            IconButton(
              icon: const Icon(Icons.refresh_rounded, size: 20),
              tooltip: '恢复默认',
              onPressed: () => s.setDownloadSavePath(null),
            ),
          IconButton(
            icon: const Icon(Icons.folder_open_rounded, size: 20),
            tooltip: '选择目录',
            onPressed: () => _pickSavePath(context, s),
          ),
        ],
      ),
    );
  }

  Future<void> _pickSavePath(BuildContext context, SettingsService s) async {
    final path = await FilePicker.getDirectoryPath();
    if (path == null) return; // 用户取消
    if (!context.mounted) return;
    // Android SAF 可能返回 content:// URI，无法用 File 直接写入
    if (path.startsWith('content://')) {
      _toast(context, '该目录暂不可用（Android 内容 URI），请选择文件系统目录或使用默认');
      return;
    }
    // 先直接校验可写；不可写时（多为权限不足）申请存储权限后重试
    if (!await _isWritable(path)) {
      final fixed =
          Platform.isAndroid &&
          await _ensureStoragePermission() &&
          await _isWritable(path);
      if (!context.mounted) return;
      if (!fixed) {
        _toast(
          context,
          Platform.isAndroid
              ? '需要「所有文件访问」权限才能写入该目录，请在系统设置中授权后重试'
              : '该目录不可写，请选择其他目录或使用默认',
        );
        return;
      }
    }
    await s.setDownloadSavePath(path);
    if (!context.mounted) return;
    _toast(context, '保存位置已更新');
  }

  /// 校验目录可写：创建目录（若不存在）并写一个临时探针文件
  Future<bool> _isWritable(String path) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final probe = File('${dir.path}/.cmbok_probe');
      await probe.writeAsString('ok');
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Android：请求写入自定义公共目录所需的存储权限
  Future<bool> _ensureStoragePermission() async {
    if (await Permission.manageExternalStorage.isGranted) return true;
    final r = await Permission.manageExternalStorage.request();
    if (r.isGranted) return true;
    if (await Permission.storage.isGranted) return true;
    final r2 = await Permission.storage.request();
    return r2.isGranted;
  }

  void _toast(BuildContext context, String msg) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  /// 开关行卡片（与「阅读设置」一致）
  Widget _buildSwitchCard({
    required bool isDark,
    required String title,
    required String subtitle,
    required bool value,
    required Future<void> Function(bool) onChanged,
    bool enabled = true,
  }) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        decoration: BoxDecoration(
          color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.bold,
                      color:
                          isDark ? Colors.white : JellyTheme.textPrimaryLight,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      height: 1.5,
                      color: JellyTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: value,
              activeColor: JellyTheme.primary,
              onChanged: enabled ? (v) => onChanged(v) : null,
            ),
          ],
        ),
      ),
    );
  }

  /// 滑块卡片（与「阅读设置」页 _buildPreloadCard 一致）
  Widget _buildSliderCard({
    required bool isDark,
    required String title,
    required String subtitle,
    required int value,
    required int min,
    required int max,
    required ValueChanged<double> onChanged,
    String unit = '',
    bool isInfinite = false,
    String infiniteLabel = '',
    bool enabled = true,
  }) {
    final display = isInfinite && value >= max ? '无限' : '$value';
    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        decoration: BoxDecoration(
          color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.bold,
                    color:
                        isDark ? Colors.white : JellyTheme.textPrimaryLight,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: JellyTheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '$display$unit',
                    style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.bold,
                      color: JellyTheme.primary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(
                fontSize: AppTheme.fontFootnote,
                color: JellyTheme.textSecondary,
              ),
            ),
            Slider(
              value: value.toDouble(),
              min: min.toDouble(),
              max: max.toDouble(),
              divisions: max - min,
              activeColor: JellyTheme.primary,
              onChanged: enabled ? onChanged : null,
            ),
            Row(
              children: [
                Text(
                  '$min',
                  style: TextStyle(
                    fontSize: AppTheme.fontCaption,
                    color: JellyTheme.textSecondary,
                  ),
                ),
                const Spacer(),
                Text(
                  isInfinite ? infiniteLabel : '$max',
                  style: TextStyle(
                    fontSize: AppTheme.fontCaption,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 缓存统计 + 清理按钮卡片
  Widget _buildCacheStatCard({
    required bool isDark,
    required String title,
    required String text,
    required VoidCallback onClear,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.data_usage_rounded, color: JellyTheme.primary, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.bold,
                    color:
                        isDark ? Colors.white : JellyTheme.textPrimaryLight,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  text,
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    height: 1.5,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: onClear,
            icon: const Icon(Icons.cleaning_services_rounded, size: 16),
            label: const Text('清理'),
          ),
        ],
      ),
    );
  }

  /// 静态信息卡片（如 下载格式 EPUB）
  Widget _buildInfoCard(bool isDark, String title, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: AppTheme.fontHeadline,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: AppTheme.fontBody,
              fontWeight: FontWeight.w600,
              color: JellyTheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}
