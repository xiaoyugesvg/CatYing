import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../common/theme.dart';
import '../../../models/local_python_source.dart';
import '../../../services/api_config.dart';
import '../../../services/app_log.dart';
import '../../../services/local_python_sources.dart';
import '../../../services/python_manager.dart';
import '../../../widgets/app_toast.dart';
import '../../../widgets/common_widgets.dart';
import '../../../reading/widgets/swipe_action_tile.dart';
import 'settings_shared.dart';

/// 设置 → 订阅管理 → 本地 Python 源
///
/// 用户 2026-10-17：
///   「py 源能不能单独增加单个脚本？不是和既有线路合并，
///     而是单独将所有独自增加的源合并一起的本地线路，可删除管理」
///
/// 用户 2026-10-18：
///   · 导入脚本要能一次多选，选了几个就导入几个；
///   · 去掉单独的 zip 项，合并成「文件导入」（.py / .zip / 文件夹）；
///   · 脚本统一放 `Documents/local_py`；
///   · 列表要能排序、切视图（列表/卡片/网格/一行 2·3·4），
///     支持左滑编辑/分享/删除、长按多选、清空。
class LocalPythonSourcesPage extends StatefulWidget {
  const LocalPythonSourcesPage({super.key});

  @override
  State<LocalPythonSourcesPage> createState() => _LocalPythonSourcesPageState();
}

/// 排序方式（与全站其它排序菜单统一：时间 / 名称 / 频率）
enum _LocalSort {
  time('时间'),
  name('名称'),
  frequency('频率');

  const _LocalSort(this.label);
  final String label;
}

/// 视图：列表 / 卡片 / 网格 / 一行 2·3·4 个
enum _LocalView {
  list('列表', Icons.view_list_rounded, 1),
  card('卡片', Icons.view_agenda_rounded, 1),
  grid('网格', Icons.grid_view_rounded, 2),
  two('一行两个', Icons.apps_rounded, 2),
  three('一行三个', Icons.view_module_rounded, 3),
  four('一行四个', Icons.grid_on_rounded, 4);

  const _LocalView(this.label, this.icon, this.columns);
  final String label;
  final IconData icon;
  final int columns;

  bool get isList => this == _LocalView.list;
}

class _LocalPythonSourcesPageState extends State<LocalPythonSourcesPage> {
  static const _kViewKey = 'local_py_view_mode';
  static const _kSortKey = 'local_py_sort_mode';

  bool _busy = false;
  _LocalView _view = _LocalView.list;
  _LocalSort _sort = _LocalSort.time;

  bool _selectMode = false;
  final Set<String> _picked = <String>{};

  @override
  void initState() {
    super.initState();
    _restorePrefs();
  }

  Future<void> _restorePrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getInt(_kViewKey);
      final s = p.getInt(_kSortKey);
      if (!mounted) return;
      setState(() {
        if (v != null && v >= 0 && v < _LocalView.values.length) {
          _view = _LocalView.values[v];
        }
        if (s != null && s >= 0 && s < _LocalSort.values.length) {
          _sort = _LocalSort.values[s];
        }
      });
    } catch (_) {}
  }

  Future<void> _savePrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_kViewKey, _view.index);
      await p.setInt(_kSortKey, _sort.index);
    } catch (_) {}
  }

  List<LocalPythonSource> get _sorted {
    final list = List<LocalPythonSource>.of(
      LocalPythonSources.instance.sources,
    );
    switch (_sort) {
      case _LocalSort.time:
        list.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      case _LocalSort.name:
        list.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
      case _LocalSort.frequency:
        list.sort((a, b) => b.usage.compareTo(a.usage));
    }
    return list;
  }

  // ============================================================
  // 导入
  // ============================================================

  /// 导入 .py：**支持一次多选**，选几个导入几个
  Future<void> _import() async {
    if (!_ensureEngine()) return;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['py'],
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
      final r = await LocalPythonSources.instance.importMany(items);
      await _afterChange();
      _reportBatch(r);
    } catch (e) {
      AppToast.error('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 「文件导入」：一个入口同时处理 .py 多选、zip、文件夹
  Future<void> _showFileImport() async {
    if (!_ensureEngine()) return;
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
              leading: Icon(
                Icons.file_open_outlined,
                color: AppTheme.textPrimary,
              ),
              title: Text(
                '选择文件',
                style: TextStyle(color: AppTheme.textPrimary),
              ),
              subtitle: Text(
                '.py / .zip，可一次多选，全部导入',
                style: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
              ),
              onTap: () => Navigator.pop(ctx, 'files'),
            ),
            ListTile(
              leading: Icon(
                Icons.folder_open_outlined,
                color: AppTheme.textPrimary,
              ),
              title: Text(
                '选择文件夹',
                style: TextStyle(color: AppTheme.textPrimary),
              ),
              subtitle: Text(
                '导入目录内所有 .py（含子目录）',
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
      final result = await FilePicker.pickFiles(
        type: FileType.any,
      );
      if (result.isEmpty) return;
      final pyItems = <({String name, String code})>[];
      var imported = 0;
      var failed = 0;
      final errors = <String>[];
      for (final f in result) {
        final lower = f.name.toLowerCase();
        final bytes = await f.readAsBytes();
        if (bytes.isEmpty) continue;
        if (lower.endsWith('.py')) {
          pyItems.add((
            name: f.name,
            code: utf8.decode(bytes, allowMalformed: true),
          ));
        } else if (lower.endsWith('.zip')) {
          final r = await LocalPythonSources.instance.importZip(bytes);
          imported += r.imported;
          failed += r.failed;
          errors.addAll(r.errors);
        }
      }
      if (pyItems.isNotEmpty) {
        final r = await LocalPythonSources.instance.importMany(pyItems);
        imported += r.imported;
        failed += r.failed;
        errors.addAll(r.errors);
      }
      await _afterChange();
      if (imported > 0) {
        final tail = failed > 0 ? '，失败 $failed 个' : '';
        AppToast.message('已导入 $imported 个脚本$tail');
        if (errors.isNotEmpty) {
          AppLog.instance.w('[LocalPy] 文件导入失败项: ${errors.join(" | ")}');
        }
      } else {
        AppToast.error(errors.isEmpty ? '没有可导入的 .py / .zip' : errors.first);
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
        // iOS 某些文件选择器不支持选目录 —— 给出明确说明，别静默无反应
        AppToast.message('当前系统文件选择器不支持选择文件夹，请改用「选择文件」多选 .py / .zip');
        return;
      }
      final r = await LocalPythonSources.instance.importDirectory(path);
      await _afterChange();
      _reportBatch(r);
    } catch (e) {
      AppToast.error('文件夹导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _ensureEngine() {
    if (!PythonManager.instance.isIOS) {
      AppToast.message('Python 引擎仅支持 iOS');
      return false;
    }
    return true;
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
      await _afterChange();
      AppToast.message('已重新加载 $n 个本地源');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ============================================================
  // 单条操作
  // ============================================================

  Future<void> _renameKey(String key, String currentName) async {
    final ctrl = TextEditingController(text: currentName);
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
    final r = await LocalPythonSources.instance.rename(key, name);
    if (!r.ok) {
      AppToast.error(r.message ?? '改名失败');
      return;
    }
    await _afterChange();
  }

  Future<void> _shareKey(String key) async {
    final code = await LocalPythonSources.instance.readCode(key);
    if (code == null || code.isEmpty) {
      AppToast.error('找不到脚本文件');
      return;
    }
    await Clipboard.setData(ClipboardData(text: code));
    AppToast.message('脚本内容已复制到剪贴板');
  }

  Future<bool> _confirmDelete(int count) async {
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
          count == 1 ? '将删除脚本文件并从引擎卸载，不可恢复。' : '将删除选中的 $count 个本地源，不可恢复。',
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
    return ok == true;
  }

  Future<void> _deleteKey(String key) async {
    if (!await _confirmDelete(1)) return;
    await LocalPythonSources.instance.remove(key);
    await _afterChange();
    AppToast.message('已删除');
  }

  Future<void> _deleteKeys(Set<String> keys) async {
    if (keys.isEmpty) return;
    if (!await _confirmDelete(keys.length)) return;
    for (final key in keys.toList()) {
      await LocalPythonSources.instance.remove(key);
    }
    if (!mounted) return;
    setState(() {
      _picked.clear();
      _selectMode = false;
    });
    await _afterChange();
    AppToast.message('已删除 ${keys.length} 个本地源');
  }

  Future<void> _clearAll() async {
    final total = LocalPythonSources.instance.sources.length;
    if (total == 0) return;
    if (!await _confirmDelete(total)) return;
    final n = await LocalPythonSources.instance.clearAll();
    if (!mounted) return;
    setState(() {
      _picked.clear();
      _selectMode = false;
    });
    await _afterChange();
    AppToast.message('已清空 $n 个本地源');
  }

  Future<void> _select(LocalPythonSource src) async {
    final bean = src.toSourceBean();
    // 用户在管理页明确点了某个本地源 ⇒ 顺手把「本地爬虫」开关打开，
    // 否则主页源会被订阅线路覆盖（用户 2026-10-18 的开关语义）。
    if (!ApiConfig.instance.localSourcesEnabled.value) {
      await ApiConfig.instance.setLocalSourcesEnabled(true);
    }
    await ApiConfig.instance.setHomeSource(bean);
    await LocalPythonSources.instance.bumpUsage(src.key);
    if (mounted) setState(() {});
    AppToast.message('已切换到「${src.name}」');
  }

  // ============================================================
  // 多选
  // ============================================================

  void _enterSelect(String key) {
    setState(() {
      _selectMode = true;
      _picked.add(key);
    });
  }

  void _togglePick(String key) {
    setState(() {
      if (_picked.contains(key)) {
        _picked.remove(key);
      } else {
        _picked.add(key);
      }
      if (_picked.isEmpty) _selectMode = false;
    });
  }

  void _exitSelect() {
    setState(() {
      _selectMode = false;
      _picked.clear();
    });
  }

  void _toggleAll() {
    final all = _sorted.map((e) => e.key).toSet();
    setState(() {
      if (_picked.length == all.length) {
        _picked.clear();
        _selectMode = false;
      } else {
        _picked
          ..clear()
          ..addAll(all);
      }
    });
  }

  // ============================================================
  // UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final currentKey = ApiConfig.instance.homeSourceBean.value?.key;

    return SettingsSubPage(
      title: '本地 Python 源',
      action: _selectMode
          ? IconButton(
              tooltip: '完成',
              onPressed: _exitSelect,
              icon: Icon(Icons.check_rounded, color: AppTheme.textPrimary),
            )
          : null,
      children: [
        SettingsGroup(
          children: [
            SettingsRow(
              icon: Icons.add_circle_outline_rounded,
              title: '导入脚本',
              value: _busy ? '处理中…' : '可多选 .py，全部导入',
              onTap: _busy ? () {} : _import,
            ),
            SettingsRow(
              icon: Icons.folder_open_outlined,
              title: '文件导入',
              value: _busy ? '处理中…' : '.py / .zip / 文件夹',
              onTap: _busy ? () {} : _showFileImport,
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
            '脚本保存在 App「文件」的 Documents/local_py 目录（可直接拷贝 .py 进去）。'
            '这些源与订阅线路分开保存：切换订阅不会丢，也不写进订阅配置。',
            style: TextStyle(
              fontSize: AppTheme.fontCaption,
              color: AppTheme.textTertiary,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: AppTheme.spacingMD),
        Obx(() {
          // 依赖 localVideoSources，导入/删除后自动刷新。
          // ⚠️ 空态看**清单**而不是 beans：开关关闭时 list 仍会读取，
          //    管理页要能继续看到并编辑已导入的脚本（用户 2026-10-18）。
          ApiConfig.instance.localVideoSources;
          final list = _sorted;
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
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_selectMode) _selectBar(list),
              _headerRow(list.length),
              const SizedBox(height: 6),
              if (_view.isList)
                ...list.map((s) => _listRow(s, currentKey: currentKey))
              else
                _grid(list, currentKey),
              const SizedBox(height: AppTheme.spacingXXL),
            ],
          );
        }),
      ],
    );
  }

  Widget _headerRow(int count) {
    return Row(
      children: [
        Text(
          '已导入（$count）',
          style: TextStyle(
            fontSize: AppTheme.fontSubhead,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
          ),
        ),
        const Spacer(),
        _iconAction(
          icon: Icons.sort_rounded,
          tooltip: '排序',
          onTap: _showSortMenu,
        ),
        _iconAction(
          icon: _view.icon,
          tooltip: '视图',
          onTap: _showViewMenu,
        ),
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
    );
  }

  Widget _iconAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      icon: Icon(icon, size: 20, color: AppTheme.textSecondary),
      onPressed: onTap,
    );
  }

  Future<void> _showSortMenu() async {
    final picked = await showModalBottomSheet<_LocalSort>(
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
            const SizedBox(height: 12),
            for (final m in _LocalSort.values)
              ListTile(
                title: Text(
                  m.label,
                  style: TextStyle(
                    color: m == _sort
                        ? AppTheme.accentColor
                        : AppTheme.textPrimary,
                    fontWeight: m == _sort ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
                trailing: m == _sort
                    ? Icon(
                        Icons.check_rounded,
                        size: 18,
                        color: AppTheme.accentColor,
                      )
                    : null,
                onTap: () => Navigator.pop(ctx, m),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    setState(() => _sort = picked);
    await _savePrefs();
  }

  Future<void> _showViewMenu() async {
    final picked = await showModalBottomSheet<_LocalView>(
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
            const SizedBox(height: 12),
            for (final v in _LocalView.values)
              ListTile(
                leading: Icon(v.icon, size: 20, color: AppTheme.textSecondary),
                title: Text(
                  v.label,
                  style: TextStyle(
                    color: v == _view
                        ? AppTheme.accentColor
                        : AppTheme.textPrimary,
                    fontWeight: v == _view ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
                trailing: v == _view
                    ? Icon(
                        Icons.check_rounded,
                        size: 18,
                        color: AppTheme.accentColor,
                      )
                    : null,
                onTap: () => Navigator.pop(ctx, v),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null) return;
    setState(() => _view = picked);
    await _savePrefs();
  }

  Widget _selectBar(List<LocalPythonSource> list) {
    final all = list.length == _picked.length;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Text(
            '已选 ${_picked.length} 项',
            style: TextStyle(
              fontSize: AppTheme.fontSubhead,
              color: AppTheme.textPrimary,
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: _toggleAll,
            child: Text(
              all ? '取消全选' : '全选',
              style: const TextStyle(fontSize: AppTheme.fontSubhead),
            ),
          ),
          IconButton(
            tooltip: '分享所选',
            onPressed: _picked.isEmpty
                ? null
                : () async {
                    final codes = <String>[];
                    for (final key in _picked) {
                      final c = await LocalPythonSources.instance.readCode(key);
                      if (c != null) codes.add(c);
                    }
                    if (codes.isEmpty) return;
                    await Clipboard.setData(
                      ClipboardData(text: codes.join('\n\n# ----\n\n')),
                    );
                    AppToast.message('已复制 ${codes.length} 个脚本');
                  },
            icon: Icon(
              Icons.ios_share_rounded,
              size: 20,
              color: AppTheme.textSecondary,
            ),
          ),
          IconButton(
            tooltip: '删除所选',
            onPressed: _picked.isEmpty
                ? null
                : () => _deleteKeys(Set.of(_picked)),
            icon: const Icon(
              Icons.delete_outline_rounded,
              size: 20,
              color: Colors.redAccent,
            ),
          ),
        ],
      ),
    );
  }

  Widget _listRow(LocalPythonSource src, {required String? currentKey}) {
    final picked = _picked.contains(src.key);
    final isCurrent = src.toSourceBean().key == currentKey;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SwipeActionTile(
        enabled: !_selectMode,
        backgroundColor: AppTheme.backgroundSecondary,
        actions: [
          SwipeAction(
            icon: Icons.drive_file_rename_outline,
            label: '编辑',
            color: AppTheme.accentColor,
            onTap: () => _renameKey(src.key, src.name),
          ),
          SwipeAction(
            icon: Icons.ios_share_rounded,
            label: '分享',
            color: const Color(0xFF3AA0FF),
            onTap: () => _shareKey(src.key),
          ),
          SwipeAction(
            icon: Icons.delete_outline_rounded,
            label: '删除',
            color: const Color(0xFFFF5A5A),
            onTap: () => _deleteKey(src.key),
          ),
        ],
        child: Material(
          color: AppTheme.backgroundSecondary,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              if (_selectMode) {
                _togglePick(src.key);
              } else {
                _select(src);
              }
            },
            onLongPress: () => _enterSelect(src.key),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(
                children: [
                  Icon(
                    _selectMode
                        ? (picked
                              ? Icons.check_box_rounded
                              : Icons.check_box_outline_blank_rounded)
                        : Icons.terminal_rounded,
                    size: 22,
                    color: _selectMode
                        ? (picked
                              ? AppTheme.accentColor
                              : AppTheme.textTertiary)
                        : AppTheme.accentColor,
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
                          isCurrent ? '当前主页源' : '${src.key}.py',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppTheme.fontFootnote,
                            color: isCurrent
                                ? AppTheme.accentColor
                                : AppTheme.textTertiary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: AppTheme.textTertiary,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _grid(List<LocalPythonSource> list, String? currentKey) {
    final columns = _view.columns;
    final maxWidth = MediaQuery.sizeOf(context).width - 32;
    const spacing = 10.0;
    final itemWidth = (maxWidth - spacing * (columns - 1)) / columns;
    return Wrap(
      spacing: spacing,
      runSpacing: spacing,
      children: [
        for (final src in list)
          SizedBox(
            width: itemWidth,
            child: _gridCard(src, currentKey: currentKey),
          ),
      ],
    );
  }

  Widget _gridCard(LocalPythonSource src, {required String? currentKey}) {
    final picked = _picked.contains(src.key);
    final isCurrent = src.toSourceBean().key == currentKey;
    final height = _view == _LocalView.card ? 96.0 : 92.0;
    return GestureDetector(
      onTap: () {
        if (_selectMode) {
          _togglePick(src.key);
        } else {
          _select(src);
        }
      },
      onLongPress: () => _showCardMenu(src),
      child: Container(
        height: height,
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        decoration: BoxDecoration(
          color: AppTheme.backgroundSecondary,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: picked
                ? AppTheme.accentColor
                : (isCurrent
                      ? AppTheme.accentColor.withValues(alpha: 0.45)
                      : Colors.transparent),
            width: picked || isCurrent ? 1.2 : 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _selectMode
                      ? (picked
                            ? Icons.check_box_rounded
                            : Icons.check_box_outline_blank_rounded)
                      : Icons.terminal_rounded,
                  size: 18,
                  color: _selectMode
                      ? (picked ? AppTheme.accentColor : AppTheme.textTertiary)
                      : AppTheme.accentColor,
                ),
                const Spacer(),
                if (isCurrent)
                  Icon(
                    Icons.check_circle_rounded,
                    size: 16,
                    color: AppTheme.accentColor,
                  ),
              ],
            ),
            const Spacer(),
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
              isCurrent ? '当前主页源' : '${src.key}.py',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: AppTheme.fontFootnote,
                color: isCurrent ? AppTheme.accentColor : AppTheme.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 卡片长按菜单：编辑 / 分享 / 多选 / 删除（与仓库页一致）
  Future<void> _showCardMenu(LocalPythonSource src) async {
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
            const SizedBox(height: 12),
            ListTile(
              leading: Icon(
                Icons.drive_file_rename_outline,
                color: AppTheme.textSecondary,
              ),
              title: Text(
                '编辑（重命名）',
                style: TextStyle(color: AppTheme.textPrimary),
              ),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: Icon(
                Icons.ios_share_rounded,
                color: AppTheme.textSecondary,
              ),
              title: Text(
                '分享脚本',
                style: TextStyle(color: AppTheme.textPrimary),
              ),
              onTap: () => Navigator.pop(ctx, 'share'),
            ),
            ListTile(
              leading: Icon(
                Icons.checklist_rounded,
                color: AppTheme.textSecondary,
              ),
              title: Text('多选', style: TextStyle(color: AppTheme.textPrimary)),
              onTap: () => Navigator.pop(ctx, 'select'),
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline_rounded,
                color: Colors.redAccent,
              ),
              title: const Text(
                '删除',
                style: TextStyle(color: Colors.redAccent),
              ),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    switch (action) {
      case 'edit':
        await _renameKey(src.key, src.name);
      case 'share':
        await _shareKey(src.key);
      case 'select':
        _enterSelect(src.key);
      case 'delete':
        await _deleteKey(src.key);
    }
  }
}
