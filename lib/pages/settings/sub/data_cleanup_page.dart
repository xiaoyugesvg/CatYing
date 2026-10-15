import 'dart:io';

import 'package:flutter/material.dart';

import '../../../services/api_config.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../common/constants.dart';
import '../../../common/theme.dart';
import '../../../models/cache_store.dart';
import '../../../models/subscription.dart';
import '../../../services/app_log.dart';
import '../../../services/prefs_mirror.dart';
import '../../../widgets/app_toast.dart';
import '../../../services/cache_manager_service.dart';

/// 可清理的数据项
enum CleanTarget {
  // ---- 缓存 ----
  imageCache('image_cache', '图片缓存', CleanGroup.cache),
  tempFiles('temp_files', '临时文件', CleanGroup.cache),
  syncCache('sync_cache', '同步缓存', CleanGroup.cache),
  logs('logs', '日志', CleanGroup.cache),

  // ---- 用户数据 ----
  playHistory('play_history', '播放历史', CleanGroup.user),
  playProgress('play_progress', '播放进度', CleanGroup.user),
  lastEpisode('last_episode', '上次集数', CleanGroup.user),
  favorites('favorites', '收藏', CleanGroup.user),
  searchHistory('search_history', '搜索历史', CleanGroup.user),
  subscriptionList('subscription_list', '订阅列表', CleanGroup.user),
  subscriptionConfig('subscription_config', '订阅配置', CleanGroup.user),
  sitePrefs('site_prefs', '站点偏好', CleanGroup.user),
  tmdbMatch('tmdb_match', 'TMDB 匹配', CleanGroup.user),
  skipIntro('skip_intro', '片头片尾', CleanGroup.user),
  catpawData('catpaw_data', 'catpaw 实例数据', CleanGroup.user),
  appSettings('app_settings', '应用设置', CleanGroup.user);

  const CleanTarget(this.id, this.label, this.group);

  final String id;
  final String label;
  final CleanGroup group;
}

enum CleanGroup { cache, user }

/// 设置 → 数据清理
///
/// 对应参考图：勾选要清理的项目 → 点底部「清理选中项」。
/// 硬约束：**执行前必须二次确认**，因为这些项里包含"收藏 / 订阅列表 / 应用设置"
/// 这类删掉无法恢复的数据。
class DataCleanupPage extends StatefulWidget {
  const DataCleanupPage({super.key});

  @override
  State<DataCleanupPage> createState() => _DataCleanupPageState();
}

class _DataCleanupPageState extends State<DataCleanupPage> {
  final selected = <CleanTarget>{};
  bool busy = false;

  bool get allSelected => selected.length == CleanTarget.values.length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text(
          '数据清理',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontTitle3,
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.spacingLG,
                AppTheme.spacingSM,
                AppTheme.spacingLG,
                16,
              ),
              children: [
                Text(
                  '勾选要清理的项目，点击底部按钮执行。',
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption,
                  ),
                ),
                const SizedBox(height: 12),

                // ---- 全选 ----
                _row(
                  label: '全选',
                  checked: allSelected,
                  onTap: () => setState(() {
                    if (allSelected) {
                      selected.clear();
                    } else {
                      selected.addAll(CleanTarget.values);
                    }
                  }),
                ),
                const SizedBox(height: 18),

                // ---- 缓存 ----
                _groupHeader('缓存', CleanGroup.cache),
                for (final t in CleanTarget.values.where(
                  (e) => e.group == CleanGroup.cache,
                ))
                  _row(
                    label: t.label,
                    checked: selected.contains(t),
                    onTap: () => _toggle(t),
                  ),
                const SizedBox(height: 18),

                // ---- 用户数据 ----
                _groupHeader('用户数据', CleanGroup.user),
                for (final t in CleanTarget.values.where(
                  (e) => e.group == CleanGroup.user,
                ))
                  _row(
                    label: t.label,
                    checked: selected.contains(t),
                    onTap: () => _toggle(t),
                  ),
              ],
            ),
          ),
          // ---- 底部执行 ----
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.spacingLG,
                8,
                AppTheme.spacingLG,
                12,
              ),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: (selected.isEmpty || busy) ? null : _confirmAndRun,
                child: Container(
                  height: 50,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected.isEmpty
                        ? AppTheme.backgroundTertiary
                        : Colors.redAccent.withValues(alpha: 0.22),
                    borderRadius: BorderRadius.circular(
                      AppTheme.glassRadiusSmall,
                    ),
                    border: Border.all(
                      color: selected.isEmpty
                          ? AppTheme.borderLight
                          : Colors.redAccent.withValues(alpha: 0.55),
                      width: 0.8,
                    ),
                  ),
                  child: busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(
                          selected.isEmpty
                              ? '清理选中项'
                              : '清理选中项（${selected.length}）',
                          style: TextStyle(
                            color: selected.isEmpty
                                ? AppTheme.textTertiary
                                : Colors.redAccent,
                            fontSize: AppTheme.fontHeadline,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _toggle(CleanTarget t) {
    setState(() {
      if (selected.contains(t)) {
        selected.remove(t);
      } else {
        selected.add(t);
      }
    });
  }

  Widget _groupHeader(String title, CleanGroup g) {
    final color = g == CleanGroup.cache
        ? AppTheme.accentColor
        : AppTheme.accentColor;
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          color: color,
          fontSize: AppTheme.fontCaption,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// 复选框行（对应参考图的方框 + 文案）
  Widget _row({
    required String label,
    required bool checked,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: AppTheme.backgroundCard,
            borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
            border: Border.all(
              color: checked
                  ? AppTheme.accentColor.withValues(alpha: 0.5)
                  : AppTheme.glassBorderSoft,
              width: checked ? 1 : 0.6,
            ),
          ),
          child: Row(
            children: [
              // 方形勾选框
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(5),
                  color: checked ? AppTheme.accentColor : Colors.transparent,
                  border: Border.all(
                    color: checked
                        ? AppTheme.accentColor
                        : AppTheme.borderMedium,
                    width: 1.6,
                  ),
                ),
                child: checked
                    ? const Icon(Icons.check, size: 14, color: Colors.white)
                    : null,
              ),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontSubhead + 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 执行
  // ============================================================

  Future<void> _confirmAndRun() async {
    final names = selected.map((e) => e.label).join('、');
    final danger = selected.any(
      (e) =>
          e == CleanTarget.favorites ||
          e == CleanTarget.subscriptionList ||
          e == CleanTarget.appSettings,
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.glassRadius),
        ),
        title: Text(
          '清理 ${selected.length} 项',
          style: TextStyle(color: AppTheme.textPrimary),
        ),
        content: Text(
          '将清理：$names\n\n'
          '${danger ? "⚠️ 其中包含「收藏 / 订阅列表 / 应用设置」，删除后无法恢复。\n\n" : ""}'
          '确定继续？',
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: AppTheme.fontSubhead,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清理', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => busy = true);
    var done = 0;
    final failed = <String>[];
    for (final t in selected.toList()) {
      try {
        await _run(t);
        done++;
      } catch (e) {
        failed.add('${t.label}（$e）');
        AppLog.instance.log('[DataCleanup] ${t.label} 清理失败: $e');
      }
    }
    if (!mounted) return;
    setState(() {
      busy = false;
      selected.clear();
    });
    AppToast.message(
      failed.isEmpty ? '已清理 $done 项' : '已清理 $done 项，失败 ${failed.length} 项',
    );
  }

  /// 按 [CacheManagerService] 的 entry id 清理（单一来源）
  Future<void> _clearCacheById(List<String> ids) async {
    final all = await CacheManagerService.instance.list();
    for (final e in all) {
      if (ids.contains(e.id)) {
        try {
          await e.clear();
        } catch (_) {
          /* 单项失败不影响其它项 */
        }
      }
    }
  }

  Future<void> _run(CleanTarget t) async {
    final prefs = await SharedPreferences.getInstance();
    switch (t) {
      // ── 缓存三项：**委托给 [CacheManagerService]**（C 类重复的第 2 处）──
      //
      // 原来这里自己清了「内存图片 + DefaultCacheManager 磁盘 +
      // getTemporaryDirectory + Hive 业务缓存」，而 `SettingsController.clearCache()`
      // 里**又写了一遍类似的清单** —— 两份迟早走偏
      //（事实上就偏了：两处都没覆盖音乐和阅读的缓存）。
      //
      // 现在"什么算缓存、怎么清"只在 `CacheManagerService` 一处定义，
      // 这里只是按用户勾选的项去挑对应的那几条。
      case CleanTarget.imageCache:
        // ⚠️ 这里的 id 必须与 CacheManagerService.list() 的真实 id 一致
        //    （原先是 'app_image_memory' / 'app_image_disk' —— 不存在 ⇒ 空操作）
        await _clearCacheById(['image_memory', 'image_disk']);
        break;

      case CleanTarget.tempFiles:
        // 同上：真实 id 是 temp_files（'app_temp' 不存在 ⇒ 空操作）
        await _clearCacheById(['temp_files']);
        break;

      case CleanTarget.syncCache:
        await _clearCacheById(['video_biz']);
        break;

      case CleanTarget.logs:
        await AppLog.instance.clear();
        break;

      case CleanTarget.playHistory:
        await CacheStore.instance.clearHistory();
        break;

      case CleanTarget.playProgress:
        // 播放进度存在 records 的 playNote/dataJson 与播放状态里
        for (final r in CacheStore.instance.records.toList()) {
          await CacheStore.instance.removeRecord(r.vodId, r.sourceKey);
        }
        break;

      case CleanTarget.lastEpisode:
        // 「上次集数」= 详情页记住的选集下标
        final keys = prefs.getKeys().where(
          (k) =>
              k.contains('last_episode') ||
              k.contains('selected_episode') ||
              k.contains('episode_index'),
        );
        for (final k in keys.toList()) {
          await prefs.remove(k);
        }
        break;

      case CleanTarget.favorites:
        for (final f in CacheStore.instance.favorites.toList()) {
          await CacheStore.instance.removeCollect(f.vodId, f.sourceKey);
        }
        break;

      case CleanTarget.searchHistory:
        await prefs.remove(AppConstants.searchHistory);
        break;

      case CleanTarget.subscriptionList:
        await prefs.remove('subscriptions_v1');
        await prefs.remove('active_subscription_id');
        // 🔴 2026-10-14 修：必须连**文件备份**一起删。
        //   订阅的 load() 在"prefs 空"时会从 `subscriptions.bak` 恢复
        //   （日志实证：`[Subscription] prefs 丢失/损坏，已从文件备份恢复 1 条`）
        //   ⇒ 只删 prefs 两个键的话，重启后订阅**原样全回来**，清理等于没清。
        await SubscriptionService.clearBackup();
        break;

      case CleanTarget.subscriptionConfig:
        // 订阅当前的接口地址与主页源选择
        await prefs.remove(AppConstants.apiUrl);
        // 接口地址的文件备份一起清（否则清理后重启被恢复回来）
        await ApiConfig.clearApiUrlBackup();
        await prefs.remove(AppConstants.homeApi);
        break;

      case CleanTarget.sitePrefs:
        // 站点偏好：正则/解析/寻址等按站点记的键
        final keys = prefs.getKeys().where(
          (k) =>
              k.startsWith('site_') ||
              k.startsWith('source_pref') ||
              k.contains('parse_pref'),
        );
        for (final k in keys.toList()) {
          await prefs.remove(k);
        }
        break;

      case CleanTarget.tmdbMatch:
        // TMDB 匹配缓存：刮削结果落盘
        await CacheStore.instance.clearItemsCache();
        final keys = prefs.getKeys().where((k) => k.startsWith('tmdb_match'));
        for (final k in keys.toList()) {
          await prefs.remove(k);
        }
        break;

      case CleanTarget.skipIntro:
        await prefs.remove('skip_intro_seconds');
        await prefs.remove('skip_outro_seconds');
        break;

      case CleanTarget.catpawData:
        // 「catpaw 实例数据」= Node 侧的运行期数据。
        //
        // 注意：catpaw 本身只是 Node 回调 Dart 的接口名
        //（main.js → /onCatPawOpenPort），**不是**目录名。
        // Node 真正落盘的是 <Documents>/nodejs-project/：
        //   src/source/        ← 源 JS 缓存（换源后会重新下载，可安全清）
        //   load-error.txt 等  ← 加载失败的取证文件
        try {
          final docs = await getApplicationDocumentsDirectory();
          final nodeDir = Directory('${docs.path}/nodejs-project');
          if (nodeDir.existsSync()) {
            await _clearDir(Directory('${nodeDir.path}/src/source'));
            for (final name in const ['load-error.txt', 'loadPath-error.txt']) {
              final f = File('${nodeDir.path}/$name');
              if (f.existsSync()) {
                try {
                  f.deleteSync();
                } catch (_) {
                  /* ignore */
                }
              }
            }
          }
        } catch (e) {
          AppLog.instance.log('[DataCleanup] catpaw 数据清理失败: $e');
        }
        break;

      case CleanTarget.appSettings:
        // 应用设置：清掉所有 play_/ui_/nav_ 前缀的设置（保留免责声明确认位）
        final keep = {
          'has_accepted_disclaimer',
          'show_about_on_launch',
        };
        final keys = prefs.getKeys().where(
          (k) =>
              (k.startsWith('play_') ||
                  k.startsWith('ui_') ||
                  k.startsWith('nav_') ||
                  k.startsWith('wallpaper_') ||
                  k.startsWith('appearance_') ||
                  k.startsWith('tmdb_')) &&
              !keep.contains(k),
        );
        for (final k in keys.toList()) {
          await prefs.remove(k);
        }
        break;
    }
    // 🔴 2026-10-14 修（清理与镜像冲突）：
    //   上面删的都是 prefs 键，但 **<Documents>/prefs_mirror.json 里还留着**。
    //   若清理后 App 被崩溃/信号杀掉（这个 App 上很常见，没走到 paused 快照），
    //   下次启动 `restoreIfLost` 会把刚删掉的键**当"缺失"补回来** ⇒ 清理白清。
    //   ⇒ 清理一结束就把镜像刷成"删除后"的状态（snapshotSoon 会立刻写）。
    PrefsMirror.snapshotSoon();
  }

  /// 清空目录内容（保留目录本身）
  Future<void> _clearDir(Directory dir) async {
    if (!dir.existsSync()) return;
    await for (final e in dir.list()) {
      try {
        await e.delete(recursive: true);
      } catch (err) {
        AppLog.instance.log('[DataCleanup] 删除 ${e.path} 失败: $err');
      }
    }
  }
}
