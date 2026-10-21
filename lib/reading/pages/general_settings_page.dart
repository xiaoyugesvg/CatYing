// lib/reading/pages/general_settings_page.dart
//
// 通用设置页（参考图 IMG_8465）：
//   软件日志（查看 / 清理运行日志）
//   缓存清理（按维度列出并清理缓存文件）
//   同步与备份（WebDAV 配置 + 自动同步开关 + 本地导出导入）
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/bookshelf_service.dart';
import '../services/book_quickjs_engine.dart';
import '../services/settings_service.dart';
import '../services/sync_service.dart';
import '../theme/jelly_theme.dart';
import '../utils/file_browser.dart';
import '../../../services/app_log.dart';
import '../../../services/cache_manager_service.dart';
import '../../common/theme.dart';
import 'translate_settings_page.dart';

/// 通用设置页：分组对齐参考图 IMG_8465。
class GeneralSettingsPage extends StatefulWidget {
  const GeneralSettingsPage({super.key});

  @override
  State<GeneralSettingsPage> createState() => _GeneralSettingsPageState();
}

class _GeneralSettingsPageState extends State<GeneralSettingsPage> {
  bool get _isDark =>
      Theme.of(context).brightness == Brightness.dark;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('通用设置'),
        centerTitle: true,
      ),
      body: ListenableBuilder(
        listenable: SettingsService(),
        builder: (context, _) {
        return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // ── 通用 ────────────────────────────────────────
              _sectionTitle('通用'),
              const SizedBox(height: 8),
              _buildNavCard(
                isDark: _isDark,
                icon: Icons.translate_rounded,
                title: '翻译设置',
                subtitle: '漫画 OCR 翻译 · AI / 百度两种引擎 · 语言与密钥',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const TranslateSettingsPage()),
                ),
              ),
              const SizedBox(height: 12),

              // ── 引擎（2026-10-21）───────────────────────────
              _sectionTitle('引擎'),
              const SizedBox(height: 8),
              ValueListenableBuilder<String>(
                valueListenable: BookQuickJsEngine.instance.mode,
                builder: (context, mode, _) => _buildNavCard(
                  isDark: _isDark,
                  icon: Icons.memory_rounded,
                  title: '书源引擎',
                  subtitle: switch (mode) {
                    'quickjs' => 'QuickJS（实验，失败不回落）',
                    'auto' => '自动：QuickJS 优先，失败回落 Node',
                    _ => 'Node（默认，兼容性最好）',
                  },
                  onTap: _pickBookEngine,
                ),
              ),
              const SizedBox(height: 12),

              // ── 运行维护 ────────────────────────────────────
              _sectionTitle('运行维护'),
              const SizedBox(height: 8),
              _buildNavCard(
                isDark: _isDark,
                icon: Icons.receipt_long_rounded,
                title: '软件日志',
                subtitle: '查看 / 清理运行日志',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AppLogPage()),
                ),
              ),
              const SizedBox(height: 12),
              _buildNavCard(
                isDark: _isDark,
                icon: Icons.cleaning_services_rounded,
                title: '缓存清理',
                subtitle: '按维度选择并清理缓存文件',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const _CacheCleanupPage()),
                ),
              ),
              const SizedBox(height: 12),
              _buildNavCard(
                isDark: _isDark,
                icon: Icons.cloud_sync_rounded,
                title: '同步与备份',
                subtitle: 'WebDAV 备份同步 · 自动同步 · 本地导出导入',
                onTap: _showSyncSheet,
              ),
            ],
          );
        },
      ),
    );
  }

  /// 选择书源执行引擎（Node / 自动 / QuickJS）
  Future<void> _pickBookEngine() async {
    await BookQuickJsEngine.instance.ensureInit();
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) {
        final cur = BookQuickJsEngine.instance.mode.value;
        Widget tile(String value, String title, String subtitle) {
          return RadioListTile<String>(
            value: value,
            groupValue: cur,
            onChanged: (v) => Navigator.pop(ctx, v),
            title: Text(title),
            subtitle: Text(subtitle),
          );
        }

        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              tile('node', 'Node', '默认，兼容性最好'),
              tile('auto', '自动', 'QuickJS 优先，失败自动回落 Node'),
              tile('quickjs', 'QuickJS', '实验引擎：失败不回落（便于对比测试）'),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (picked != null) await BookQuickJsEngine.instance.setMode(picked);
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

  /// 导航行卡片（图标 + 标题 + 副标题 + 右箭头）
  Widget _buildNavCard({
    required bool isDark,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListTile(
        leading: Icon(icon, color: JellyTheme.primary, size: 22),
        title: Text(
          title,
          style: TextStyle(
            fontSize: AppTheme.fontHeadline,
            fontWeight: FontWeight.bold,
            color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(
            fontSize: AppTheme.fontFootnote,
            height: 1.5,
            color: JellyTheme.textSecondary,
          ),
        ),
        trailing: Icon(
          Icons.chevron_right_rounded,
          color: JellyTheme.textSecondary,
        ),
        onTap: onTap,
      ),
    );
  }

  /// 同步与备份面板：WebDAV 配置 + 立即备份/恢复 + 自动同步 + 本地导出导入
  Future<void> _showSyncSheet() async {
    await SyncService.instance.load();
    final c = SyncService.instance.config;
    final urlC = TextEditingController(text: c.webdavUrl);
    final userC = TextEditingController(text: c.webdavUser);
    final passC = TextEditingController(text: c.webdavPass);
    final pathC = TextEditingController(text: c.webdavPath);
    var busy = false;

    void toast(String msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ));
    }

    Future<void> doBackup() async {
      await SyncService.instance.save(SyncConfig(
        webdavUrl: urlC.text.trim(),
        webdavUser: userC.text.trim(),
        webdavPass: passC.text,
        webdavPath: pathC.text.trim(),
      ));
      final json = BookshelfService().exportJson();
      final r = await SyncService.instance.backupBookshelf(json);
      toast(r.ok ? '备份成功（${json.length ~/ 1024} KB）' : '备份失败：${r.error}');
    }

    Future<void> doRestore() async {
      await SyncService.instance.save(SyncConfig(
        webdavUrl: urlC.text.trim(),
        webdavUser: userC.text.trim(),
        webdavPass: passC.text,
        webdavPath: pathC.text.trim(),
      ));
      final r = await SyncService.instance.restoreBookshelf();
      if (r.ok && r.json != null) {
        final n = await BookshelfService().importJson(r.json!);
        toast('恢复成功，导入 $n 项');
      } else {
        toast('恢复失败：${r.error}');
      }
    }

    Future<void> exportLocal() async {
      final json = BookshelfService().exportJson();
      final dir = await getDownloadsDirectory();
      final file = File('${dir?.path ?? ''}/cmbok_bookshelf_backup.json');
      await file.writeAsString(json);
      toast('已导出到 ${file.path}');
    }

    Future<void> importLocal() async {
      final picked = await pickLocalFiles(
        context,
        allowedExtensions: const {'json'},
        allowMultiple: false,
      );
      if (picked == null || picked.isEmpty) return;
      final content = await File(picked.first).readAsString();
      final n = await BookshelfService().importJson(content);
      toast('导入成功，恢复 $n 项');
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                20,
                16,
                20,
                20 + MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '同步与备份',
                    style: TextStyle(
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(ctx).brightness == Brightness.dark
                          ? Colors.white
                          : JellyTheme.textPrimaryLight,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'WebDAV 备份同步 · 自动同步 · 本地导出导入',
                    style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: urlC,
                    decoration: const InputDecoration(
                        labelText: 'WebDAV 服务器地址',
                        border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: userC,
                    decoration: const InputDecoration(
                        labelText: '用户名', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: passC,
                    obscureText: true,
                    decoration: const InputDecoration(
                        labelText: '密码', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: pathC,
                    decoration: const InputDecoration(
                        labelText: '备份路径（默认 NewTv/bookshelf_backup.json）',
                        border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: busy
                              ? null
                              : () async {
                                  setSheet(() => busy = true);
                                  await doBackup();
                                  if (ctx.mounted) {
                                    setSheet(() => busy = false);
                                  }
                                },
                          icon: const Icon(Icons.cloud_upload_outlined,
                              size: 18),
                          label: busy
                              ? const Text('备份中…')
                              : const Text('立即备份'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: busy
                              ? null
                              : () async {
                                  setSheet(() => busy = true);
                                  await doRestore();
                                  if (ctx.mounted) {
                                    setSheet(() => busy = false);
                                  }
                                },
                          icon: const Icon(Icons.cloud_download_outlined,
                              size: 18),
                          label: busy
                              ? const Text('恢复中…')
                              : const Text('从云端恢复'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // ⚠️ **本开关「暂未实现」** ✗（今天**全 `lib` 取证** ✓：
                  //   `autoSyncBackup` 只出现在「本页 UI + settings_service 的键/字段/getter/setter」✗，
                  //   **0 处业务读取** ✗ → 没有任何"启动时/到点自动备份"的触发点 ✓）
                  //   ⇒ 拨它**什么都不会发生** ✗（与下载设置那 5 项同型 ✓，处置方式一致 ✓）
                  //   ✓ 保留行 + 如实标注 ✓："自动同步"是以后要做的能力 ✓（不是笔误 ✗）；
                  //     而上面/下面的「**立即备份**」「**从云端恢复**」是**真的能用** ✓✓（真 WebDAV ✓）
                  SwitchListTile(
                    value: SettingsService().autoSyncBackup,
                    onChanged: (v) => SettingsService().setAutoSyncBackup(v),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动同步（暂未实现 ✗）'),
                    subtitle: const Text('开启后启动时自动备份书架到 WebDAV（当前无效 ✗：无自动触发点）'),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: busy
                              ? null
                              : () async {
                                  setSheet(() => busy = true);
                                  await exportLocal();
                                  if (ctx.mounted) {
                                    setSheet(() => busy = false);
                                  }
                                },
                          icon: const Icon(Icons.save_alt_rounded, size: 18),
                          label: const Text('本地导出'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: busy
                              ? null
                              : () async {
                                  setSheet(() => busy = true);
                                  await importLocal();
                                  if (ctx.mounted) {
                                    setSheet(() => busy = false);
                                  }
                                },
                          icon: const Icon(Icons.file_open_rounded, size: 18),
                          label: const Text('本地导入'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 软件日志页
// ============================================================

/// 软件日志页。
/// ✅ 改成**公开**（`AppLogPage`）——「通用设置」和**「阅读设置」两处入口复用** ✓
///   （原来私有 ⇒ 别的页面要用只能再抄一份，音乐模块就是这么抄出来的 ✗）。
class AppLogPage extends StatefulWidget {
  const AppLogPage({super.key});

  @override
  State<AppLogPage> createState() => _AppLogPageState();
}

class _AppLogPageState extends State<AppLogPage> {
  String _content = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final text = await AppLog.instance.readRecentLines(lines: 800);
    if (!mounted) return;
    setState(() {
      _content = text.trim().isEmpty ? '（暂无日志）' : text;
      _loading = false;
    });
  }

  Future<void> _clear() async {
    await AppLog.instance.clear();
    if (!mounted) return;
    setState(() => _content = '（日志已清空）');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('软件日志'),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: '清空日志',
            icon: const Icon(Icons.delete_sweep_rounded),
            onPressed: _clear,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              child: SingleChildScrollView(
                child: SelectableText(
                  _content,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.5,
                    fontFamily: 'monospace',
                    color: _isDark()
                        ? Colors.white70
                        : JellyTheme.textPrimaryLight,
                  ),
                ),
              ),
            ),
    );
  }

  bool _isDark() => Theme.of(context).brightness == Brightness.dark;
}

// ============================================================
// 缓存清理页（按维度列出并清理，参考图 IMG_8465 缓存清理）
// ============================================================

class _CacheCleanupPage extends StatefulWidget {
  const _CacheCleanupPage();

  @override
  State<_CacheCleanupPage> createState() => _CacheCleanupPageState();
}

class _CacheCleanupPageState extends State<_CacheCleanupPage> {
  List<CacheEntryInfo>? _entries;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final entries = await CacheManagerService.instance.list(
      onSize: () {
        if (mounted) setState(() {});
      },
    );
    if (!mounted) return;
    setState(() => _entries = entries);
  }

  Future<void> _clearOne(CacheEntryInfo e) async {
    setState(() => _busy.add(e.id));
    await e.clear();
    if (mounted) setState(() => _busy.remove(e.id));
    await _reload();
  }

  Future<void> _clearAll() async {
    if (_entries == null) return;
    setState(() => _busy.addAll(_entries!.map((e) => e.id)));
    await CacheManagerService.clearAll(_entries!);
    if (!mounted) return;
    setState(() => _busy.clear());
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('缓存清理'),
        centerTitle: true,
        actions: [
          if (entries != null && entries.isNotEmpty)
            TextButton.icon(
              onPressed: _clearAll,
              icon: const Icon(Icons.cleaning_services_rounded, size: 18),
              label: const Text('全部清理'),
            ),
        ],
      ),
      body: entries == null
          ? const Center(child: CircularProgressIndicator())
          : entries.isEmpty
              ? const Center(child: Text('暂无缓存'))
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final e = entries[i];
                    final clearing = _busy.contains(e.id);
                    return Container(
                      decoration: BoxDecoration(
                        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                      child: Row(
                        children: [
                          Icon(
                            _moduleIcon(e.module),
                            color: JellyTheme.primary,
                            size: 22,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${e.module.label} · ${e.label}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  e.hint,
                                  style: TextStyle(
                                    fontSize: AppTheme.fontCaption,
                                    color: JellyTheme.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            CacheManagerService.formatSize(e.size),
                            style: TextStyle(
                              fontSize: AppTheme.fontCaption,
                              color: JellyTheme.textSecondary,
                            ),
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            tooltip: '清理',
                            onPressed: clearing ? null : () => _clearOne(e),
                            icon: clearing
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : const Icon(Icons.delete_outline_rounded),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }

  IconData _moduleIcon(CacheModule m) {
    switch (m) {
      case CacheModule.video:
        return Icons.movie_rounded;
      case CacheModule.live:
        return Icons.live_tv_rounded;
      case CacheModule.music:
        return Icons.music_note_rounded;
      case CacheModule.reading:
        return Icons.menu_book_rounded;
      case CacheModule.tmdb:
        return Icons.movie_filter_rounded;
      case CacheModule.hiker:
        return Icons.rocket_launch_rounded;
      case CacheModule.playbackSync:
        return Icons.sync_rounded;
      case CacheModule.rss:
        return Icons.rss_feed_rounded;
      case CacheModule.app:
        return Icons.apps_rounded;
    }
  }
}

// ============================================================
// 小组件
// ============================================================
