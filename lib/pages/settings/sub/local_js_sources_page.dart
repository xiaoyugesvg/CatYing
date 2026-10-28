import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/local_js_source.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/local_js_sources.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/widgets/card_action_sheet.dart';
import 'package:tvbox/widgets/common_widgets.dart';
import 'package:tvbox/pages/settings/sub/settings_shared.dart';
import 'package:tvbox/pages/settings/sub/local_script_editor_page.dart';
import 'package:tvbox/services/nodejs_manager.dart';

/// 设置 → 订阅管理 → 本地 JS 源
///
/// 用户 2026-10-27：
///   「不是有个 py 本地源吗？这种加个 JS 本地源撒」
///
/// 与本地 Python 源同一套语义：单独导入、单独成组、可改名/分享/删除、
/// 切订阅不丢。区别是引擎换成 Node（CatVod / drpy / TVBox type=3 脚本），
/// 选中后由 SpiderService 按需把 `.js` 载入 Node 槽位。
class LocalJsSourcesPage extends StatefulWidget {
  const LocalJsSourcesPage({super.key});

  @override
  State<LocalJsSourcesPage> createState() => _LocalJsSourcesPageState();
}

class _LocalJsSourcesPageState extends State<LocalJsSourcesPage> {
  bool _busy = false;
  final TextEditingController _searchCtrl = TextEditingController();
  String _keyword = '';

  @override
  void initState() {
    super.initState();
    // 首次进入先把清单读出来（不依赖设置页是否已 reload）
    LocalJsSources.instance.load(force: true).then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<LocalJsSource> get _visible {
    final all = List<LocalJsSource>.of(LocalJsSources.instance.sources)
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    final kw = _keyword.trim().toLowerCase();
    if (kw.isEmpty) return all;
    return all
        .where((s) =>
            s.name.toLowerCase().contains(kw) || s.key.toLowerCase().contains(kw))
        .toList();
  }

  // ============================================================
  // 导入
  // ============================================================

  Future<void> _import() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['js'],
      );
      if (result.isEmpty) return;
      final items = <({String name, String code})>[];
      for (final f in result) {
        final bytes = await f.readAsBytes();
        if (bytes.isEmpty) continue;
        items.add((
          name: f.name,
          code: utf8.decode(bytes, allowMalformed: true),
        ));
      }
      if (items.isEmpty) {
        AppToast.error('读不出脚本内容');
        return;
      }
      final r = await LocalJsSources.instance.importMany(items);
      await _afterChange();
      _reportBatch(r);
    } catch (e) {
      AppToast.error('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 「文件导入」：一个入口同时处理 .js 多选、zip、文件夹
  Future<void> _showFileImport() async {
    if (_busy) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.textTertiary.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            const SizedBox(height: 14),
            ListTile(
              leading: Icon(Icons.file_open_outlined, color: AppTheme.textPrimary),
              title: Text('选择文件', style: TextStyle(color: AppTheme.textPrimary)),
              subtitle: Text(
                '.js / .zip，可一次多选，全部导入',
                style: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
              ),
              onTap: () => Navigator.pop(ctx, 'files'),
            ),
            ListTile(
              leading: Icon(Icons.folder_open_outlined, color: AppTheme.textPrimary),
              title: Text('选择文件夹', style: TextStyle(color: AppTheme.textPrimary)),
              subtitle: Text(
                '导入目录内所有 .js（含子目录）',
                style: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
              ),
              onTap: () => Navigator.pop(ctx, 'folder'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == 'files') {
      await _importFilesMixed();
    } else if (action == 'folder') {
      await _importFolder();
    }
  }

  Future<void> _importFilesMixed() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await FilePicker.pickFiles(type: FileType.any);
      if (result.isEmpty) return;
      final jsItems = <({String name, String code})>[];
      var imported = 0;
      var failed = 0;
      final errors = <String>[];
      for (final f in result) {
        final lower = f.name.toLowerCase();
        final bytes = await f.readAsBytes();
        if (bytes.isEmpty) continue;
        if (lower.endsWith('.js')) {
          jsItems.add((
            name: f.name,
            code: utf8.decode(bytes, allowMalformed: true),
          ));
        } else if (lower.endsWith('.zip')) {
          final r = await LocalJsSources.instance.importZip(bytes);
          imported += r.imported;
          failed += r.failed;
          errors.addAll(r.errors);
        }
      }
      if (jsItems.isNotEmpty) {
        final r = await LocalJsSources.instance.importMany(jsItems);
        imported += r.imported;
        failed += r.failed;
        errors.addAll(r.errors);
      }
      await _afterChange();
      if (imported > 0) {
        final tail = failed > 0 ? '，失败 $failed 个' : '';
        AppToast.message('已导入 $imported 个脚本$tail');
        if (errors.isNotEmpty) {
          AppLog.instance.w('[LocalJs] 文件导入失败项: ${errors.join(" | ")}');
        }
      } else {
        AppToast.error(errors.isEmpty ? '没有可导入的 .js / .zip' : errors.first);
      }
    } catch (e) {
      AppToast.error('文件导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importFolder() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final path = await FilePicker.getDirectoryPath();
      if (path == null || path.isEmpty) {
        AppToast.message('当前系统文件选择器不支持选择文件夹，请改用「选择文件」多选 .js / .zip');
        return;
      }
      final r = await LocalJsSources.instance.importDirectory(path);
      await _afterChange();
      _reportBatch(r);
    } catch (e) {
      AppToast.error('文件夹导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _afterChange() async {
    await ApiConfig.instance.reloadLocalVideoSources();
    if (mounted) setState(() {});
  }

  void _reportBatch(({int imported, int failed, List<String> errors}) r) {
    if (r.imported > 0) {
      final tail = r.failed > 0 ? '，失败 ${r.failed} 个' : '';
      AppToast.message('已批量导入 ${r.imported} 个$tail');
      if (r.failed > 0 && r.errors.isNotEmpty) {
        AppLog.instance.w('[LocalJs] 批量导入失败项: ${r.errors.join(" | ")}');
      }
    } else {
      AppToast.error(r.errors.isEmpty ? '没有可导入的 .js' : r.errors.first);
    }
  }

  // ============================================================
  // 单条操作
  // ============================================================

  Future<void> _select(LocalJsSource src) async {
    final bean = src.toSourceBean();
    // 与本地 Python 源一致：点了本地源就打开「本地爬虫」开关，
    // 否则主页源会被订阅线路覆盖。
    if (!ApiConfig.instance.localSourcesEnabled.value) {
      await ApiConfig.instance.setLocalSourcesEnabled(true);
    }
    await ApiConfig.instance.setHomeSource(bean);
    await LocalJsSources.instance.bumpUsage(src.key);
    if (mounted) setState(() {});
    AppToast.message('已切换到「${src.name}」');
  }

  /// 编辑脚本内容（2026-10-28）。
  ///
  /// 保存后若改的正是**当前源**，顺手让 Node 重新载入这份脚本 ——
  /// JS 是单源槽位架构，不 reload 的话 Node 里跑的还是旧代码。
  Future<void> _editScript(LocalJsSource src) async {
    final code = await LocalJsSources.instance.readCode(src.key);
    if (!mounted) return;
    if (code == null) {
      AppToast.error('找不到脚本文件');
      return;
    }
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
      settings: const RouteSettings(name: 'settings:localJsScript'),
      builder: (_) => LocalScriptEditorPage(
        title: src.name,
        filename: '${src.key}.js',
        initialCode: code,
        language: 'javascript',
        onSave: (c) => LocalJsSources.instance.saveCode(src.key, c),
      ),
    ));
    if (saved != true || !mounted) return;
    final active = ApiConfig.instance.homeSourceBean.value?.key == src.sourceKey;
    if (active) {
      try {
        await NodeJSManager.instance.loadSource(src.api);
        AppLog.instance.log('[LocalJs] 当前源已重新载入 ${src.api}');
      } catch (e) {
        AppLog.instance.w('[LocalJs] 重新载入失败: $e');
      }
    }
    await _afterChange();
  }

  Future<void> _rename(LocalJsSource src) async {
    final ctrl = TextEditingController(text: src.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text(
          '重命名',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontHeadline,
          ),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: AppTheme.textPrimary),
          decoration: const InputDecoration(hintText: '显示名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final r = await LocalJsSources.instance.rename(src.key, name);
    if (!r.ok) {
      AppToast.error(r.message ?? '改名失败');
      return;
    }
    await _afterChange();
  }

  Future<void> _share(LocalJsSource src) async {
    final code = await LocalJsSources.instance.readCode(src.key);
    if (code == null || code.isEmpty) {
      AppToast.error('找不到脚本文件');
      return;
    }
    await Clipboard.setData(ClipboardData(text: code));
    AppToast.message('脚本内容已复制到剪贴板');
  }

  Future<void> _delete(LocalJsSource src) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text(
          '删除本地源？',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontHeadline,
          ),
        ),
        content: Text(
          '将删除脚本文件，不可恢复。',
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: AppTheme.fontSubhead,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await LocalJsSources.instance.remove(src.key);
    await _afterChange();
    AppToast.message('已删除');
  }

  Future<void> _clearAll() async {
    final total = LocalJsSources.instance.sources.length;
    if (total == 0) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text(
          '清空全部？',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontHeadline,
          ),
        ),
        content: Text(
          '将删除全部 $total 个本地 JS 源，不可恢复。',
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: AppTheme.fontSubhead,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final n = await LocalJsSources.instance.clearAll();
    await _afterChange();
    AppToast.message('已清空 $n 个本地源');
  }

  Future<void> _showCardMenu(LocalJsSource src) async {
    await showCardActions(
      context,
      title: src.name,
      subtitle: '本地 JS · ${src.key}.js',
      actions: [
        CardAction(
          icon: Icons.play_circle_outline_rounded,
          label: '设为当前',
          onTap: () => _select(src),
        ),
        CardAction(
          icon: Icons.code_rounded,
          label: '改脚本',
          onTap: () => _editScript(src),
        ),
        CardAction(
          icon: Icons.drive_file_rename_outline,
          label: '改名',
          onTap: () => _rename(src),
        ),
        CardAction(
          icon: Icons.ios_share_rounded,
          label: '分享',
          onTap: () => _share(src),
        ),
        CardAction(
          icon: Icons.delete_outline_rounded,
          label: '删除',
          danger: true,
          onTap: () => _delete(src),
        ),
      ],
    );
  }

  // ============================================================
  // UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final currentKey = ApiConfig.instance.homeSourceBean.value?.key;
    final all = List<LocalJsSource>.of(LocalJsSources.instance.sources);
    final list = _visible;

    return SettingsSubPage(
      title: '本地 JS 源',
      children: [
        SettingsGroup(
          children: [
            SettingsRow(
              icon: Icons.add_circle_outline_rounded,
              title: '导入脚本',
              value: _busy ? '处理中…' : '可多选 .js，全部导入',
              onTap: _busy ? () {} : _import,
            ),
            SettingsRow(
              icon: Icons.folder_open_outlined,
              title: '文件导入',
              value: _busy ? '处理中…' : '.js / .zip / 文件夹',
              onTap: _busy ? () {} : _showFileImport,
            ),
          ],
        ),
        const SizedBox(height: AppTheme.spacingXXL),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '脚本保存在 App「文件」的 Documents/local_js 目录（可直接拷贝 .js 进去）。'
            '适用于 CatVod / drpy / TVBox 的 JS 脚本源；选中后由 Node 引擎按需载入。'
            '这些源与订阅线路分开保存：切换订阅不会丢。',
            style: TextStyle(
              fontSize: AppTheme.fontCaption,
              color: AppTheme.textTertiary,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: AppTheme.spacingMD),
        if (all.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
              decoration: BoxDecoration(
                color: AppTheme.backgroundSecondary,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.code_rounded,
                    size: 40,
                    color: AppTheme.textTertiary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '还没有本地 JS 源',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '点上面的「导入脚本」选择 .js 文件',
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontFootnote,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy ? null : _import,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('导入脚本'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.accentColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          )
        else ...[
          _searchField(),
          Row(
            children: [
              Text(
                '已导入（${list.length}${list.length != all.length ? " / ${all.length}" : ""}）',
                style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: _clearAll,
                child: const Text(
                  '清空',
                  style: TextStyle(
                    fontSize: AppTheme.fontSubhead,
                    color: Colors.redAccent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  '未找到匹配的源',
                  style: TextStyle(color: AppTheme.textTertiary),
                ),
              ),
            )
          else
            ...list.map((s) => _row(s, currentKey: currentKey)),
          const SizedBox(height: AppTheme.spacingXXL),
        ],
      ],
    );
  }

  Widget _searchField() {
    return Container(
      height: 36,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.borderLight, width: 0.5),
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 16, color: AppTheme.textTertiary),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _keyword = v.trim()),
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontSubhead,
              ),
              decoration: InputDecoration(
                hintText: '搜索源名称…',
                hintStyle: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontSubhead,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 9),
              ),
            ),
          ),
          if (_keyword.isNotEmpty)
            GestureDetector(
              onTap: () {
                _searchCtrl.clear();
                setState(() => _keyword = '');
              },
              child: Icon(Icons.cancel, size: 15, color: AppTheme.textTertiary),
            ),
        ],
      ),
    );
  }

  Widget _row(LocalJsSource src, {required String? currentKey}) {
    final isCurrent = src.sourceKey == currentKey;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppTheme.backgroundSecondary,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _select(src),
          onLongPress: () => _showCardMenu(src),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Row(
              children: [
                Icon(
                  Icons.code_rounded,
                  size: 22,
                  color: isCurrent ? AppTheme.accentColor : AppTheme.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        src.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isCurrent ? '当前主页源' : '${src.key}.js',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTheme.fontFootnote,
                          color:
                              isCurrent ? AppTheme.accentColor : AppTheme.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isCurrent)
                  Icon(
                    Icons.check_circle_rounded,
                    size: 18,
                    color: AppTheme.accentColor,
                  ),
                PopupMenuButton<String>(
                  icon: Icon(
                    Icons.more_vert_rounded,
                    size: 20,
                    color: AppTheme.textTertiary,
                  ),
                  onSelected: (v) {
                    switch (v) {
                      case 'rename':
                        _rename(src);
                      case 'share':
                        _share(src);
                      case 'delete':
                        _delete(src);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('重命名')),
                    PopupMenuItem(value: 'share', child: Text('分享')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
