import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tvbox/reading/services/cache_capacity.dart';
import 'package:tvbox/reading/services/book_content_cache_service.dart';
import 'package:tvbox/reading/services/settings_service.dart';
import 'package:tvbox/reading/theme/jelly_theme.dart';
import 'package:tvbox/common/theme.dart';
import 'package:tvbox/widgets/app_image_cache.dart';

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
  int _imageCacheCount = 0;
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
    var imageCount = 0;
    try {
      final (b, n) = await _imageCacheStats();
      imageBytes = b;
      imageCount = n;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _bookCacheBytes = bookBytes;
      _bookCacheChapters = chapters;
      _imageCacheBytes = imageBytes;
      _imageCacheCount = imageCount;
      _cacheLoaded = true;
    });
  }

  /// 统计 appImageCacheManager 磁盘缓存（临时目录 cached_network_image_ce）
  /// 返回（字节数, 张数），对应参考图「图片 23.8 MB·56 张·目录 59.7 KB」。
  Future<(int, int)> _imageCacheStats() async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/cached_network_image_ce');
    if (!await dir.exists()) return (0, 0);
    var total = 0;
    var count = 0;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is File) {
        total += await e.length();
        count++;
      }
    }
    return (total, count);
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
              // ⚠️ **下面两个开关目前「暂未实现」** ✗（今天逐条核实 ✓ —— 全模块 0 个读取点 ✗）
              //   · 后台下载：下载服务里**没有** `AppLifecycleState` 处理 ✗
              //     （该 API 只有番茄钟在用 ✓）→ 真要做得接**平台级后台执行** ✓（工作量大 ✓）
              //   · 仅 Wi-Fi：全模块**没有** `connectivity` 依赖或网络类型判断 ✗✗
              //     → 真要做得先加依赖 ✓（pubspec 归你自己管 ✓）
              // ✓ 处置 = **保留行 + 标题如实标注** ✓：这两项是"以后要做的能力" ✓（不是笔误 ✗），
              //   但**不能让用户以为现在拨了就有效** ✗✓
              _buildSwitchCard(
                isDark: isDark,
                title: '后台下载（暂未实现 ✗）',
                subtitle: '切到后台或息屏时继续下载（当前无效 ✗）',
                value: s.backgroundDownload,
                onChanged: s.setBackgroundDownload,
              ),
              const SizedBox(height: 12),
              _buildSwitchCard(
                isDark: isDark,
                title: '仅 Wi-Fi 下载（暂未实现 ✗）',
                subtitle: '使用移动网络时自动暂停（当前无效 ✗：缺网络类型判断）',
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
              // ❌ **这两行已删除**（假开关 ✗ —— 逐条核实过 ✓）：
              //   ① 「书源下载并发量」= `bookSourceConcurrency` ✗
              //      语义「在线书源任务同时下载的**章节数**」✓ 与**本页已有的活键**
              //      `maxConcurrentChapters`（见下面「同时下载量」✓）**完全重复** ✗✓
              //      —— 全模块 0 个读取点 ✗ → 用户拨它**毫无效果** ✗✗
              //   ② 「图书文件下载并发量」= `bookFileConcurrency` ✗
              //      语义独立（图书**文件**级并发 ✓）但**从未实现** ✗（0 读取点 ✓）→
              //      真要做需先给图书文件下载加文件级调度 ✓（属新功能 ✗，不是接线 ✓）
              // ✅ **能力没丢** ✓：真正生效的两项在下面 ——
              //    「同时下载量」`maxConcurrentChapters` ✓ · 「图片分片并发量」
              //    `maxConcurrentImages` ✓（`download_service.dart:600` 真的在用它 ✓✓）
              const SizedBox(height: 12),
              // ⚠️ **本行「暂未实现」** ✗（今天逐条核实 ✓：`onlineBookCacheGb` 全模块 **0 个读取点** ✗）
              //   · 代码里确实有 `_cacheLimit`，但那是**条目数**上限 ✗ ——
              //     `book_source_service:173` = 40 条结果缓存 ✓ ·
              //     `book_source_reader_page:80` = 12 章内存缓存 ✓
              //   · 与这里的「**GB 计量 + 按最久未读淘汰**」**不是一回事** ✗✗ → 后者从未实现 ✓
              //   ℹ️ 紧跟其后的「临时缓存」统计卡（下面 `_buildCacheStatCard` ✓）是**真的** ✓
              //     （真读磁盘字节 ✓）—— 只有这个"上限滑杆"是空的 ✗
              _buildSliderCard(
                isDark: isDark,
                title: '在线书临时缓存',
                // ✅ **不再是"暂未实现 ✗"** —— 本行已真正接上容量淘汰 ✓（下面 onChanged 里执行 ✓）
                subtitle:
                    '超过上限按最久未用自动淘汰（当前 ${CacheCapacity.humanBytes(_bookCacheBytes)}'
                    ' / 上限 ${s.onlineBookCacheGb} GB）',
                value: s.onlineBookCacheGb,
                min: SettingsService.minOnlineCacheGb,
                max: SettingsService.maxOnlineCacheGb,
                unit: ' GB',
                // ✅ **真淘汰** ✓（拖完立刻生效 ✓ 并把统计刷新出来 ✓）：
                //   · `gbToBytes(≤0) = 0` ✓ → `evictToLimit` 遇到 0 **什么都不做** ✓（不会误删空 ✗）
                //   · 目录来自 `BookContentCacheService.cacheDir()` ✓（公开入口 ✓ 今天核对过 ✓）
                //   · 淘汰完**重新量一次体积**写回 `_bookCacheBytes` ✓，于是卡片上的占用**当场变小** ✓✓
                //     （这就是给用户看的"上限真的生效"的证据 ✓）
                onChanged: (v) async {
                  final gb = v.round();
                  await s.setOnlineBookCacheGb(gb);
                  try {
                    final dir =
                        await BookContentCacheService.instance.cacheDir();
                    await CacheCapacity.evictToLimit(
                      dir,
                      CacheCapacity.gbToBytes(gb),
                    );
                    final bytes = await CacheCapacity.dirBytes(dir);
                    if (mounted) setState(() => _bookCacheBytes = bytes);
                  } catch (e) {
                    debugPrint('[DownloadSettings] 缓存淘汰失败（忽略）: $e');
                  }
                },
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
              // ⚠️ **本行「暂未实现」** ✗（与上面「在线书临时缓存」同因 ✓：
              //   `onlineComicCacheGb` 全模块 **0 个读取点** ✗）
              //   · 漫画侧确有回收机制，但走的是**章节/条目**维度 ✗，不是这里的「GB 计量 + 最久未看」✗
              //   ℹ️ 紧随其后的统计卡（下面 `_buildCacheStatCard` ✓）是**真的** ✓（真读磁盘字节 ✓）
              _buildSliderCard(
                isDark: isDark,
                title: '在线漫画图片缓存',
                // ✅ **不再是"暂未实现 ✗"** —— 漫画侧已真正接上容量淘汰 ✓（与上面图书侧同款 ✓）
                subtitle:
                    '超过上限按最久未看自动淘汰（当前 ${CacheCapacity.humanBytes(_imageCacheBytes)}'
                    ' / 上限 ${s.onlineComicCacheGb} GB）',
                value: s.onlineComicCacheGb,
                min: SettingsService.minOnlineCacheGb,
                max: SettingsService.maxOnlineCacheGb,
                unit: ' GB',
                // ✅ 目录与统计卡**用的是同一个**（`_imageCacheStats()` 也读 `cached_network_image_ce` ✓）
                //   ⇒ 淘汰完再量一次体积写回 `_imageCacheBytes` ✓ → 卡片占用**当场变小** ✓✓
                //   · `dart:io` 与 `path_provider` 本页早就 import 了 ✓（`:1` `:5` ✓），**不新增依赖** ✓
                //   · `gbToBytes(≤0) = 0` ✓ → 上限为 0 时 `evictToLimit` 直接返回 ✓ 不误删 ✗
                onChanged: (v) async {
                  final gb = v.round();
                  await s.setOnlineComicCacheGb(gb);
                  try {
                    final tmp = await getTemporaryDirectory();
                    final dir =
                        Directory('${tmp.path}/cached_network_image_ce');
                    await CacheCapacity.evictToLimit(
                      dir,
                      CacheCapacity.gbToBytes(gb),
                    );
                    final bytes = await CacheCapacity.dirBytes(dir);
                    if (mounted) setState(() => _imageCacheBytes = bytes);
                  } catch (e) {
                    debugPrint('[DownloadSettings] 图片缓存淘汰失败（忽略）: $e');
                  }
                },
              ),
              const SizedBox(height: 12),
              _buildCacheStatCard(
                isDark: isDark,
                title: '图片缓存',
                text: _cacheLoaded
                    ? '图片 ${_fmt(_imageCacheBytes)} · $_imageCacheCount 张'
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
                title: '失败或缺页时暂停合并（暂未实现 ✗）',
                subtitle: '合并遇到失败或缺页时暂停，等待手动处理（当前无效 ✗）',
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
              activeThumbColor: JellyTheme.primary,
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
