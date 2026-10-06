// 书源仓库（Nexhub 引擎接入）：参考漫画源仓库（source_repo_page）样式。
// 顶部「导入区」：粘贴文本（JSON/XML/NDJSON）、导入本地文件、导出明文；
// 下方列出所有书源，可启用/停用、编辑名称/分组/注释、删除。// 启用源参与书源页聚搜与浏览（见 shuyuan_page）。
import 'dart:io';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../novel_source/model/book_source.dart';
import '../novel_source/shuyuan_source_service.dart';
import '../services/shuyuan_source_store.dart';
import '../../common/theme.dart';
import '../theme/jelly_theme.dart';
import 'book_source_editor_page.dart';
import 'book_source_health_page.dart';
import 'book_source_login_page.dart';
import 'shuyuan_source_edit_page.dart';

class ShuyuanSourceRepoPage extends StatefulWidget {
  const ShuyuanSourceRepoPage({super.key});

  @override
  State<ShuyuanSourceRepoPage> createState() => _ShuyuanSourceRepoPageState();
}

class _ShuyuanSourceRepoPageState extends State<ShuyuanSourceRepoPage> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _importFromClipboard() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('粘贴书源'),
        content: TextField(
          controller: ctrl,
          maxLines: 8,
          minLines: 4,
          decoration: const InputDecoration(
            hintText: '粘贴书源 JSON / XML / NDJSON 文本',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    await _doImport(text);
  }

  Future<void> _importFromFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.any,
      allowedExtensions: const ['json', 'txt', 'xml'],
    );
    if (result == null || result.isEmpty) return;
    final path = result.single.path;
    if (path == null) return;
    final content = await Future.sync(() async {
      final f = await File(path).readAsString();
      return f;
    }).catchError((_) => '');
    if (content.isEmpty) {
      _toast('读取文件失败');
      return;
    }
    await _doImport(content);
  }

  Future<void> _doImport(String text) async {
    setState(() => _busy = true);
    try {
      final r = await ShuyuanSourceStore.instance.importText(text);
      _toast('导入成功 ${r.count} 个，跳过 ${r.skipped} 个');
    } catch (e) {
      _toast('导入失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    final json = ShuyuanSourceStore.instance.exportJson();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导出书源'),
        content: Text(
          '已将 ${ShuyuanSourceStore.instance.allSources.length} 个书源导出为明文 JSON，复制到剪贴板？',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('澶嶅埗'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        // ignore: deprecated_member_use
        await Clipboard.setData(ClipboardData(text: json));
        _toast('已复制到剪贴板');
      } catch (_) {
        _toast('澶嶅埗澶辫触');
      }
    }
  }

/// 全部启用 / 全部停用。
  Future<void> _setAllEnabled(bool enabled) async {
    setState(() => _busy = true);
    await ShuyuanSourceStore.instance.setAllEnabled(enabled);
    if (mounted) {
      setState(() => _busy = false);
      _toast(enabled ? '已全部启用' : '已全部停用');
    }
  }

/// 清空全部书源（确认后执行）。
  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空书源'),
        content: Text(
          '确定清空全部 ${ShuyuanSourceStore.instance.allSources.length} 个书源？此操作不可撤销。',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('娓呯┖'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    await ShuyuanSourceStore.instance.clearAll();
    if (mounted) {
      setState(() => _busy = false);
      _toast('已清空全部书源');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Scaffold(
      backgroundColor: isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
      appBar: AppBar(
        backgroundColor: isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: titleColor),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          '书源仓库',
          style: TextStyle(
            fontSize: AppTheme.fontHeadline,
            fontWeight: FontWeight.w600,
            color: titleColor,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '书源体检',
            icon: Icon(
              Icons.shield_outlined,
              size: 20,
              color: titleColor,
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const BookSourceHealthPage(),
                ),
              );
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: ShuyuanSourceStore.instance,
        builder: (context, _) {
          final all = ShuyuanSourceStore.instance.allSources;
          // 懒加载：固定头（导入区/标题/批量行）用 SliverToBoxAdapter；          // 源卡片用 SliverList.builder
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildImportCard(isDark),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        '已启用书源（${all.length}）· 关闭后不参与聚搜',
                        style: TextStyle(
                          fontSize: 12,
                          color: JellyTheme.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 批量操作：全部启用 / 全部停用 / 清空
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: all.isEmpty || _busy
                                ? null
                                : () => _setAllEnabled(true),
                            icon: const Icon(Icons.done_all_rounded, size: 16),
                            label: const Text('全部启用'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: all.isEmpty || _busy
                                ? null
                                : () => _setAllEnabled(false),
                            icon: const Icon(Icons.block_rounded, size: 16),
                            label: const Text('全部关闭'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: all.isEmpty || _busy ? null : _clearAll,
                            style: OutlinedButton.styleFrom(
                              foregroundColor:
                                  Theme.of(context).colorScheme.error,
                            ),
                            icon: const Icon(Icons.delete_sweep_rounded,
                                size: 16),
                            label: const Text('娓呯┖'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (all.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 40),
                        child: Center(
                          child: Column(
                            children: [
                              Icon(
                                Icons.library_books_outlined,
                                size: 48,
                                color: JellyTheme.textSecondary,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                '还没有书源，点击上方「粘贴导入」或\n导入本地书源文件',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: JellyTheme.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
                ),
              if (all.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  sliver: SliverList.builder(
                    itemCount: all.length,
                    itemBuilder: (context, i) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _buildSourceCard(isDark, all[i]),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildImportCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '导入书源',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '支持 阅读 3.0 / Nexhub 格式的 JSON、XML、NDJSON 文本',
            style: TextStyle(fontSize: 12, color: JellyTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _importFromClipboard,
                  icon: const Icon(Icons.content_paste_rounded, size: 18),
                  label: const Text('粘贴导入'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _importFromFile,
                  icon: const Icon(Icons.file_open_rounded, size: 18),
                  label: const Text('导入文件'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _export,
              icon: const Icon(Icons.ios_share_rounded, size: 16),
              label: const Text('导出明文'),
              style: TextButton.styleFrom(foregroundColor: JellyTheme.primary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceCard(bool isDark, ShuyuanSource src) {
    final enabled = src.enabled;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          _buildSourceIcon(src),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        src.bookSourceName,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: isDark
                              ? Colors.white
                              : JellyTheme.textPrimaryLight,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  src.bookSourceGroup?.isNotEmpty == true
                      ? '${src.bookSourceGroup} 路 ${src.bookSourceUrl}'
                      : src.bookSourceUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '编辑',
            iconSize: 20,
            icon: Icon(
              Icons.edit_outlined,
              color: JellyTheme.textSecondary,
            ),
            onPressed: () async {
              final edited = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => BookSourceEditorPage(source: src),
                ),
              );
              if (edited == true && mounted) setState(() {});
            },
          ),
          IconButton(
            tooltip: '鐧诲綍',
            iconSize: 20,
            icon: Icon(
              Icons.login_rounded,
              color: JellyTheme.textSecondary,
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => BookSourceLoginPage(
                    source: src.toBookSource(),
                  ),
                ),
              );
            },
          ),
          IconButton(
            tooltip: '删除',
            iconSize: 20,
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('删除书源'),
                  content: Text('确定删除「${src.bookSourceName}」？'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('删除'),
                    ),
                  ],
                ),
              );
              if (ok == true) {
                await ShuyuanSourceStore.instance.removeSource(
                  src.bookSourceUrl,
                );
              }
            },
          ),
          Switch(
            value: enabled,
            activeThumbColor: JellyTheme.primary,
            onChanged: (v) async {
              await ShuyuanSourceStore.instance.setEnabled(
                src.bookSourceUrl,
                v,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSourceIcon(ShuyuanSource src) {
    const size = 40.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: JellyTheme.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        src.bookSourceName.isNotEmpty ? src.bookSourceName[0] : '?',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: JellyTheme.primary,
        ),
      ),
    );
  }
}

