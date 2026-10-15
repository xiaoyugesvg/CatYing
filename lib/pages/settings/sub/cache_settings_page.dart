import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../common/theme.dart';
import '../../../widgets/common_widgets.dart';
import '../controller.dart';
import 'data_cleanup_page.dart';
import 'settings_shared.dart';
import '../../../services/cache_manager_service.dart';
import '../../../widgets/app_toast.dart';

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

  /// 缓存明细（按模块分类）。null = 还在算
  List<CacheEntryInfo>? _entries;
  /// 清空进行中（防重复点击）
  bool _busy = false;

  static const _autoCleanLabels = ['关闭', '每天', '每周', '每月'];

  @override
  void initState() {
    super.initState();
    _load();
    _reloadEntries();
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
            // 精细清理：按项勾选（缓存 / 用户数据），对应参考图的「数据清理」页
            SettingsRow(
              icon: Icons.checklist,
              title: '数据清理',
              value: '精细',
              onTap: () => Get.to(() => const DataCleanupPage()),
            ),
            // 全清入口保留（含源选择记忆重置）：放在列表末尾，不与分项并列
            Obx(() => SettingsRow(
                  icon: Icons.delete_outline,
                  title: '清空全部缓存',
                  value: controller.cacheSizeString.value,
                  onTap: _confirmClearAll,
                )),
          ],
        ),

        // ── 缓存明细（按模块/分类分组，可单独清）──────────────────
        //
        // 顺序：影视 → 直播 → 音乐 → 阅读 → TMDB 缓存 → 图片 →
        // 数据 → JS → 临时文件。每组一个卡片，组内条目 + 「清空整组」。
        const SizedBox(height: AppTheme.spacingMD),
        _cacheDetailSection(),
      ],
    );
  }

  // ============================================================
  // 缓存明细：按模块分组，每组可单独清空
  // ============================================================

  Widget _cacheDetailSection() {
    if (_entries == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: AppTheme.accentColor),
          ),
        ),
      );
    }
    final all = _entries!;
    // 按 module 分组（保持枚举顺序：app → video → music → reading）
    final groups = <CacheModule, List<CacheEntryInfo>>{};
    for (final e in all) {
      groups.putIfAbsent(e.module, () => []).add(e);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final m in CacheModule.values)
          if ((groups[m] ?? const []).isNotEmpty) ...[
            SettingsGroup(
              title:
                  '${m.label} · ${CacheManagerService.formatSize((groups[m] ?? const []).fold<int>(0, (a, b) => a + (b.size < 0 ? 0 : b.size)))}',
              children: [
                for (final e in groups[m] ?? const []) _entryRow(e),
                // 精细清理：点开底部勾选菜单（与「数据清理」页同一交互）
                SettingsRow(
                  icon: Icons.checklist,
                  title: '精细清理',
                  value: '${(groups[m] ?? const []).length} 项可勾选',
                  onTap: _busy
                      ? null
                      : () => _showFineCleanSheet(m, groups[m] ?? const []),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.spacingMD),
          ],
      ],
    );
  }

  Widget _entryRow(CacheEntryInfo e) {
    return SettingsRow(
      icon: _moduleIcon(e.module),
      title: e.label,
      value: CacheManagerService.formatSize(e.size),
      // 副标题写清"清了会怎样" —— 让用户敢点
      onTap: null,
    );
  }

  IconData _moduleIcon(CacheModule m) => switch (m) {
        CacheModule.video => Icons.movie_outlined,
        CacheModule.live => Icons.live_tv_outlined,
        CacheModule.music => Icons.music_note_outlined,
        CacheModule.reading => Icons.menu_book_outlined,
        CacheModule.tmdb => Icons.movie_filter_outlined,
        CacheModule.hiker => Icons.rocket_launch_outlined,
        CacheModule.webhome => Icons.language_outlined,
        CacheModule.rss => Icons.rss_feed_outlined,
        CacheModule.app => Icons.phone_iphone_rounded,
      };

  /// 精细清理：底部弹出勾选菜单（与「数据清理」页同一交互：
  /// 全选 / 勾选 / 底部「清理选中项」/ 二次确认）。
  Future<void> _showFineCleanSheet(
      CacheModule m, List<CacheEntryInfo> entries) async {
    if (entries.isEmpty) return;
    final selected = <String>{for (final e in entries) e.id}; // 默认全选
    final allIds = entries.map((e) => e.id).toSet();

    final proceed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppTheme.radiusLG),
        ),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final chosen = entries.where((e) => selected.contains(e.id)).toList();
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 标题 + 全选切换
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '精细清理 · ${m.label}',
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: AppTheme.fontTitle3,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => setSheetState(() {
                          if (selected.length == allIds.length) {
                            selected.clear();
                          } else {
                            selected.addAll(allIds);
                          }
                        }),
                        child: Text(
                          selected.length == allIds.length ? '取消全选' : '全选',
                          style: TextStyle(
                            color: AppTheme.accentColor,
                            fontSize: AppTheme.fontSubhead,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '勾选要清理的项，点击底部按钮执行',
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 条目勾选列表（最多 5 项，撑不满屏）
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final e in entries)
                          CheckboxListTile(
                            value: selected.contains(e.id),
                            onChanged: (v) => setSheetState(() {
                              if (v == true) {
                                selected.add(e.id);
                              } else {
                                selected.remove(e.id);
                              }
                            }),
                            activeColor: AppTheme.accentColor,
                            dense: true,
                            title: Text(
                              e.label,
                              style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: AppTheme.fontBody,
                              ),
                            ),
                            subtitle: Text(
                              '${CacheManagerService.formatSize(e.size)} · ${e.hint}',
                              style: TextStyle(
                                color: AppTheme.textTertiary,
                                fontSize: AppTheme.fontCaption,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 底部执行按钮
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.redAccent.withValues(alpha: 0.9),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(22),
                        ),
                      ),
                      onPressed: chosen.isEmpty
                          ? null
                          : () => Navigator.pop(ctx, true),
                      child: Text(
                        '清理选中项（${chosen.length}）',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: AppTheme.fontBody,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (proceed != true) return;

    // 二次确认（与数据清理页一致：说清清理范围与影响）
    final names = entries
        .where((e) => selected.contains(e.id))
        .map((e) => '· ${e.label}')
        .join('\n');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text('清理「${m.label}」选中项',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          '将清理：\n$names\n\n'
          '不会清除：收藏 / 历史 / 订阅 / 设置。\n'
          '清理后相关内容下次会重新联网或重新解析。',
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: AppTheme.fontSubhead,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消',
                style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('清理', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    for (final e in entries.where((x) => selected.contains(x.id))) {
      await e.clear();
    }
    await _reloadEntries();
    if (!mounted) return;
    setState(() => _busy = false);
    AppToast.success('已清理「${m.label}」${selected.length} 项');
  }

  Future<void> _reloadEntries() async {
    final list = await CacheManagerService.instance.list();
    if (!mounted) return;
    setState(() => _entries = list);
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

  /// 清空全部缓存前确认：分项说明清理范围，避免用户担心误清历史/收藏。
  Future<void> _confirmClearAll() async {
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
          '都不会清除：观看历史、收藏、源文件 JS、海阔文件区（含导入的规则包）、'
          '播放设置\n'
          '（源文件 JS 与海阔文件区可在本页**单独**清除）\n'
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
