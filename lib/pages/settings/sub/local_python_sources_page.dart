import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/theme.dart';
import '../../../models/source_bean.dart';
import '../../../services/api_config.dart';
import '../../../services/app_log.dart';
import '../../../services/local_python_sources.dart';
import '../../../services/python_manager.dart';
import '../../../widgets/app_toast.dart';
import '../../../widgets/common_widgets.dart';
import 'settings_shared.dart';

/// 设置 → 订阅管理 → 本地 Python 源
///
/// 用户 2026-10-17：
///   「py 源能不能单独增加单个脚本？不是和既有线路合并，
///     而是单独将所有独自增加的源合并一起的本地线路，可删除管理」
///
/// 所以这里是一套**与订阅解耦**的本地源：
///   · 导入一条 .py → 落盘到 Documents + 注册进 CPython；
///   · 全部本地源单独成组（源切换面板顶部），不写进订阅 sites；
///   · 可改名、可删除、可重新加载，切换订阅不会丢。
class LocalPythonSourcesPage extends StatefulWidget {
  const LocalPythonSourcesPage({super.key});

  @override
  State<LocalPythonSourcesPage> createState() => _LocalPythonSourcesPageState();
}

class _LocalPythonSourcesPageState extends State<LocalPythonSourcesPage> {
  bool _busy = false;

  String _keyOf(SourceBean bean) {
    final api = bean.api.trim();
    return api.toLowerCase().endsWith('.py')
        ? api.substring(0, api.length - 3)
        : api;
  }

  Future<void> _import() async {
    if (!PythonManager.instance.isIOS) {
      AppToast.message('Python 引擎仅支持 iOS');
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['py'],
      );
      if (result.isEmpty) return;
      final f = result.first;
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) {
        AppToast.error('读不出脚本内容');
        return;
      }
      final r = await LocalPythonSources.instance.importBytes(
        bytes,
        displayName: f.name,
      );
      if (!r.ok) {
        AppToast.error(r.message ?? '导入失败');
        return;
      }
      await ApiConfig.instance.reloadLocalVideoSources();
      if (mounted) setState(() {});
      AppToast.message('已导入「${r.source?.name ?? ''}」');
    } catch (e) {
      AppToast.error('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importZipBatch() async {
    if (!PythonManager.instance.isIOS) {
      AppToast.message('Python 引擎仅支持 iOS');
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      );
      if (result.isEmpty) return;
      final bytes = await result.first.readAsBytes();
      if (bytes.isEmpty) {
        AppToast.error('读不出 zip');
        return;
      }
      final r = await LocalPythonSources.instance.importZip(bytes);
      await ApiConfig.instance.reloadLocalVideoSources();
      if (mounted) setState(() {});
      _reportBatch(r);
    } catch (e) {
      AppToast.error('批量导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importFolder() async {
    if (!PythonManager.instance.isIOS) {
      AppToast.message('Python 引擎仅支持 iOS');
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final path = await FilePicker.getDirectoryPath();
      if (path == null || path.isEmpty) return;
      final r = await LocalPythonSources.instance.importDirectory(path);
      await ApiConfig.instance.reloadLocalVideoSources();
      if (mounted) setState(() {});
      _reportBatch(r);
    } catch (e) {
      AppToast.error('批量导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _reportBatch(({int imported, int failed, List<String> errors}) r) {
    if (r.imported > 0) {
      final tail = r.failed > 0 ? '，失败 ${r.failed} 个' : '';
      AppToast.message('已批量导入 ${r.imported} 个$tail');
      if (r.failed > 0 && r.errors.isNotEmpty) {
        AppLog.instance.w('[LocalPy] 批量导入失败项: ${r.errors.join(" | ")}');
      }
    } else {
      AppToast.error(r.errors.isEmpty ? '没有可导入的 .py' : r.errors.first);
    }
  }

  Future<void> _reloadEngine() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final n = await LocalPythonSources.instance.registerAll();
      await ApiConfig.instance.reloadLocalVideoSources();
      if (mounted) setState(() {});
      AppToast.message('已重新加载 $n 个本地源');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rename(SourceBean bean) async {
    final ctrl = TextEditingController(text: bean.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text('重命名',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontHeadline)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: AppTheme.textPrimary),
          decoration: const InputDecoration(hintText: '显示名称'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final r = await LocalPythonSources.instance.rename(_keyOf(bean), name);
    if (!r.ok) {
      AppToast.error(r.message ?? '改名失败');
      return;
    }
    await ApiConfig.instance.reloadLocalVideoSources();
    if (mounted) setState(() {});
  }

  Future<void> _delete(SourceBean bean) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text('删除本地源？',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontHeadline)),
        content: Text(
          '将删除「${bean.name}」的脚本文件并从引擎卸载，不可恢复。',
          style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontSubhead),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    final r = await LocalPythonSources.instance.remove(_keyOf(bean));
    await ApiConfig.instance.reloadLocalVideoSources();
    if (mounted) setState(() {});
    if (!r.ok) {
      AppToast.message(r.message ?? '已删除（重启后彻底生效）');
    } else {
      AppToast.message('已删除');
    }
  }

  Future<void> _select(SourceBean bean) async {
    await ApiConfig.instance.setHomeSource(bean);
    AppToast.message('已切换到「${bean.name}」');
  }

  @override
  Widget build(BuildContext context) {
    final currentKey = ApiConfig.instance.homeSourceBean.value?.key;

    return SettingsSubPage(
      title: '本地 Python 源',
      children: [
        SettingsGroup(
          children: [
            SettingsRow(
              icon: Icons.add_circle_outline_rounded,
              title: '导入 .py 脚本',
              value: _busy ? '处理中…' : '单个文件',
              onTap: _busy ? () {} : _import,
            ),
            SettingsRow(
              icon: Icons.folder_zip_outlined,
              title: '批量导入（zip）',
              value: _busy ? '处理中…' : 'zip 内所有 .py',
              onTap: _busy ? () {} : _importZipBatch,
            ),
            SettingsRow(
              icon: Icons.folder_open_outlined,
              title: '批量导入（文件夹）',
              value: _busy ? '处理中…' : '目录内所有 .py',
              onTap: _busy ? () {} : _importFolder,
            ),
            SettingsRow(
              icon: Icons.refresh_rounded,
              title: '重新加载到引擎',
              value: _busy ? '处理中…' : '注册全部本地源',
              onTap: _busy ? () {} : _reloadEngine,
            ),
          ],
        ),
        const SizedBox(height: AppTheme.spacingXXL),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '这些源与订阅线路分开保存：切换订阅不会丢，也不写进订阅配置。'
            '导入后会出现在「搜索源」面板顶部的「本地 Python」分组里。',
            style: TextStyle(
              fontSize: AppTheme.fontCaption,
              color: AppTheme.textTertiary,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: AppTheme.spacingMD),
        Obx(() {
          final list = ApiConfig.instance.localVideoSources;
          if (list.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text(
                  '还没有本地 Python 源',
                  style: TextStyle(color: AppTheme.textTertiary),
                ),
              ),
            );
          }
          return SettingsGroup(
            title: '已导入（${list.length}）',
            children: [
              for (final src in list)
                SettingsRow(
                  icon: Icons.terminal_rounded,
                  title: src.name,
                  value: src.key == currentKey ? '当前主页源' : src.api,
                  onTap: () => _select(src),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '重命名',
                        icon: Icon(Icons.drive_file_rename_outline,
                            size: 19, color: AppTheme.textSecondary),
                        onPressed: () => _rename(src),
                      ),
                      IconButton(
                        tooltip: '删除',
                        icon: const Icon(Icons.delete_outline,
                            size: 19, color: Colors.redAccent),
                        onPressed: () => _delete(src),
                      ),
                    ],
                  ),
                ),
            ],
          );
        }),
        const SizedBox(height: AppTheme.spacingXXL),
      ],
    );
  }
}
