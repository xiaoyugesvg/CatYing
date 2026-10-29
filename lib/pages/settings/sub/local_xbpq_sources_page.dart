/// 设置 → 订阅管理 → XBPQ 规则源
///
/// 用户 2026-10-29：「XBPQ 的管理以及导入还有等等功能，开关都要和本地爬虫一样」。
///
/// 所以这一页与「本地爬虫」「本地JS」**共用同一套布局与交互**：
///   搜索 / 列表·卡片·网格视图 / 时间·名称·频率排序 / 多选批量删除 /
///   长按卡片菜单（改名·分享·删除·改规则）/ 检测（真跑一遍首页）。
/// 唯一的差别在背后的存储：
///   · 规则是**纯文本 JSON**，存在 SharedPreferences（`xbpq_rules_v1`）；
///   · 由内置 **Dart** 引擎解析，不依赖 Node / Python，导入即可用。
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/import_conflict.dart';
import 'package:tvbox/services/xbpq/xbpq_service.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/source_service.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/widgets/card_action_sheet.dart';
import 'package:tvbox/widgets/common_widgets.dart';
import 'package:tvbox/reading/widgets/swipe_action_tile.dart';
import 'package:tvbox/pages/settings/sub/settings_shared.dart';
import 'package:tvbox/pages/settings/sub/local_script_editor_page.dart';

/// 设置 → 订阅管理 → 本地 JS 源
///
/// 用户 2026-10-17：
///   「py 源能不能单独增加单个脚本？不是和既有线路合并，
///     而是单独将所有独自增加的源合并一起的本地线路，可删除管理」
///
/// 用户 2026-10-18：
///   · 导入脚本要能一次多选，选了几个就导入几个；
///   · 去掉单独的 zip 项，合并成「文件导入」（.json / .txt / .zip / 文件夹）；
///   · 脚本统一放 `Documents/local_py`；
///   · 列表要能排序、切视图（列表/卡片/网格/一行 2·3·4），
///     支持左滑编辑/分享/删除、长按多选、清空。
class LocalXbpqSourcesPage extends StatefulWidget {
  const LocalXbpqSourcesPage({super.key});

  @override
  State<LocalXbpqSourcesPage> createState() => _LocalXbpqSourcesPageState();
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

class _LocalXbpqSourcesPageState extends State<LocalXbpqSourcesPage> {
  static const _kViewKey = 'local_xbpq_view_mode';
  static const _kSortKey = 'local_xbpq_sort_mode';

  bool _busy = false;
  _LocalView _view = _LocalView.list;
  _LocalSort _sort = _LocalSort.time;

  bool _selectMode = false;
  final Set<String> _picked = <String>{};

  /// 搜索关键词（用户 2026-10-20：「py 本地源设置里面加个搜索功能」）
  final TextEditingController _searchCtrl = TextEditingController();
  String _keyword = '';

  // ── 检测（2026-10-24：本地 py 源加检测功能）──────────────────
  /// 每个源的检测结果（key → 结果）。没跑过的源不在表里。
  final Map<String, _ProbeResult> _probe = {};

  /// 正在检测的源
  final Set<String> _probing = {};

  /// 全部检测时的进度文案（空 = 没有在批量跑）
  String _probeHint = '';

  @override
  void initState() {
    super.initState();
    _restorePrefs();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
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

  List<XbpqEntry> get _sorted {
    final list = List<XbpqEntry>.of(
      XbpqService.instance.sources,
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

  /// 排序 + 搜索后的可见列表
  List<XbpqEntry> get _visible {
    final all = _sorted;
    final kw = _keyword.trim().toLowerCase();
    if (kw.isEmpty) return all;
    return all
        .where((s) =>
            s.name.toLowerCase().contains(kw) ||
            s.key.toLowerCase().contains(kw))
        .toList();
  }

  // ============================================================
  // 导入
  // ============================================================

  /// 导入规则：**支持一次多选**，选几个导入几个
  Future<void> _import() async {
    if (!_ensureEngine()) return;
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json', 'txt'],
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
        AppToast.error('读不出规则内容');
        return;
      }
      final conflict = await _askConflict(items.map((e) => e.name));
      if (conflict == null) return;
      final r = await XbpqService.instance.importMany(
        items,
        conflict: conflict,
      );
      await _afterChange();
      _reportBatch(r);
    } catch (e) {
      AppToast.error('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 「文件导入」：一个入口同时处理规则文件多选、zip、文件夹
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
                '.json / .txt / .zip，可一次多选，全部导入',
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
                '导入目录内所有 .json / .txt（含子目录）',
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

  /// 同名检测 + 让用户选「替换 / 重命名」。
  ///
  /// 返回 null = 用户取消（这一批都不导入）。
  /// 没有同名时直接返回 [ImportConflict.rename]（此时策略不影响结果）。
  Future<ImportConflict?> _askConflict(Iterable<String> names) async {
    final dup = await XbpqService.instance.conflictingNames(names);
    if (dup.isEmpty) return ImportConflict.rename;
    if (!mounted) return null;
    return SettingsDialogs.askImportConflict(
      context,
      names: dup,
      kind: 'XBPQ',
    );
  }

  Future<void> _importFilesMixed() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.any,
      );
      if (result.isEmpty) return;
      // 规则文件与 zip 里的规则文件 先**全部收集成一份清单**，再统一做同名检测 ——
      // 分开检测会让用户连续弹两次窗。
      final all = <({String name, String code})>[];
      final errors = <String>[];
      for (final f in result) {
        final lower = f.name.toLowerCase();
        final bytes = await f.readAsBytes();
        if (bytes.isEmpty) continue;
        if (lower.endsWith('.json')) {
          all.add((
            name: f.name,
            code: utf8.decode(bytes, allowMalformed: true),
          ));
        } else if (lower.endsWith('.zip')) {
          try {
            all.addAll(XbpqService.instance.scanZipBytes(bytes));
          } catch (e) {
            errors.add('${f.name}: zip 解析失败: $e');
          }
        }
      }
      if (all.isEmpty) {
        AppToast.error(errors.isEmpty ? '没有可导入的规则on / .txt / .zip' : errors.first);
        return;
      }
      final conflict = await _askConflict(all.map((e) => e.name));
      if (conflict == null) return;
      final r = await XbpqService.instance.importMany(
        all,
        conflict: conflict,
      );
      await _afterChange();
      final failed = r.failed + errors.length;
      if (r.imported > 0) {
        final tail = failed > 0 ? '，失败 $failed 个' : '';
        AppToast.message('已导入 ${r.imported} 条规则$tail');
        if (r.errors.isNotEmpty || errors.isNotEmpty) {
          AppLog.instance.w(
            '[LocalPy] 文件导入失败项: ${[...r.errors, ...errors].join(" | ")}',
          );
        }
      } else {
        AppToast.error(r.errors.isEmpty ? '没有可导入的规则on / .txt / .zip' : r.errors.first);
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
        AppToast.message('当前系统文件选择器不支持选择文件夹，请改用「选择文件」多选规则文件on / .txt / .zip');
        return;
      }
      // 先扫描再问「替换 / 重命名」，最后才落盘
      final items = await XbpqService.instance.scanDirectory(path);
      if (items.isEmpty) {
        AppToast.error('目录里没有 .json / .txt 文件');
        return;
      }
      final conflict = await _askConflict(items.map((e) => e.name));
      if (conflict == null) return;
      final r = await XbpqService.instance.importMany(
        items,
        conflict: conflict,
      );
      await _afterChange();
      _reportBatch(r);
    } catch (e) {
      AppToast.error('文件夹导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// XBPQ 规则由**内置 Dart 引擎**解析，不依赖 Node / Python。
  ///
  /// 所以这里没有"引擎没起来"这回事 —— 导入即可用。
  bool _ensureEngine() => true;

  Future<void> _afterChange() async {
    await ApiConfig.instance.reloadLocalVideoSources();
    if (mounted) setState(() {});
  }

  void _reportBatch(({int imported, int failed, List<String> errors}) r) {
    if (r.imported > 0) {
      final tail = r.failed > 0 ? '，失败 ${r.failed} 个' : '';
      AppToast.message('已批量导入 ${r.imported} 个$tail');
      if (r.failed > 0 && r.errors.isNotEmpty) {
        AppLog.instance.w('[Xbpq] 批量导入失败项: ${r.errors.join(" | ")}');
      }
    } else {
      AppToast.error(r.errors.isEmpty ? '没有可导入的规则' : r.errors.first);
    }
  }

  /// 「重新加载」：把规则清单从存储重新读一遍并刷新 ApiConfig。
  Future<void> _reloadEngine() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await XbpqService.instance.ensureLoaded(force: true);
      final n = await XbpqService.instance.registerAll();
      await _afterChange();
      AppToast.message('已重新加载 $n 条规则');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ============================================================
  // 检测（与本地爬虫同一套：真跑一遍首页取分类 + 推荐）
  // ============================================================

  /// 检测一个本地源：真跑一遍 `getSort`（= 首页会走的路径）。
  ///
  /// 这样规则写错、站点挂了、超时，都能在这一步暴露，
  /// 并顺带拿到「分类数 / 首页推荐条数 / 耗时」。
  ///
  /// ⚠️ 必须**串行**：Node 侧只有单实例，且 `loadSource` 会顶掉当前槽位，
  ///    并发检测会互相覆盖，结果全乱。
  Future<void> _probeOne(XbpqEntry src) async {
    if (_probing.contains(src.key)) return;
    if (!_ensureEngine()) return;
    setState(() {
      _probing.add(src.key);
      _probe.remove(src.key);
    });
    final bean = src.toSourceBean();
    final sw = Stopwatch()..start();
    _ProbeResult result;
    try {
      final r = await SourceService.instance
          .getSort(bean)
          .timeout(const Duration(seconds: 25));
      result = _ProbeResult(
        ok: true,
        sorts: r.$1.length,
        home: r.$2.length,
        ms: sw.elapsedMilliseconds,
      );
    } catch (e) {
      result = _ProbeResult(
        ok: false,
        sorts: 0,
        home: 0,
        ms: sw.elapsedMilliseconds,
        error: _shortError(e),
      );
    }
    if (!mounted) return;
    setState(() {
      _probing.remove(src.key);
      _probe[src.key] = result;
    });
  }

  /// 检测当前可见的全部源（串行 + 进度）
  Future<void> _probeAll() async {
    if (_probing.isNotEmpty) return;
    if (!_ensureEngine()) return;
    final list = _visible;
    if (list.isEmpty) return;
    var i = 0;
    for (final src in list) {
      i++;
      if (!mounted) return;
      setState(() => _probeHint = '检测中 $i/${list.length}');
      await _probeOne(src);
    }
    if (!mounted) return;
    setState(() => _probeHint = '');
    final ok = list.where((s) => _probe[s.key]?.ok == true).length;
    AppToast.message('检测完成：$ok/${list.length} 正常');
  }

  String _shortError(Object e) {
    var s = e.toString().replaceFirst('Exception: ', '');
    final i = s.indexOf('\n');
    if (i > 0) s = s.substring(0, i);
    return s.length > 60 ? '${s.substring(0, 60)}…' : s;
  }

  /// 检测结论（列表/网格共用）：正常显示「分类 · 推荐 · 耗时」，失败显示原因
  Widget? _probeLine(String key, {double size = AppTheme.fontFootnote}) {
    if (_probing.contains(key)) {
      return Text(
        '检测中…',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: size, color: const Color(0xFFF0A020)),
      );
    }
    final r = _probe[key];
    if (r == null) return null;
    final text = r.ok
        ? '正常 · ${r.sorts} 分类 · ${r.home} 推荐 · '
            '${(r.ms / 1000).toStringAsFixed(1)}s'
        : '失败 · ${r.error}';
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: size,
        color: r.ok ? const Color(0xFF34C759) : Colors.redAccent,
      ),
    );
  }

  /// 状态点：灰=未检测 / 橙=检测中 / 绿=正常 / 红=失败
  Widget _stateDot(String key) {
    Color c = AppTheme.textTertiary;
    if (_probing.contains(key)) {
      c = const Color(0xFFF0A020);
    } else if (_probe[key]?.ok == true) {
      c = const Color(0xFF34C759);
    } else if (_probe[key] != null) {
      c = Colors.redAccent;
    }
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
    );
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
    final r = await XbpqService.instance.rename(key, name);
    if (!r.ok) {
      AppToast.error(r.message ?? '改名失败');
      return;
    }
    await _afterChange();
  }

  /// 编辑规则内容。
  ///
  /// 与 PY / JS 的「改脚本」同一入口，只是这里改的是规则 JSON。
  /// 原来只能导入 / 改名 / 分享 / 删除，改一行规则得去文件 App 里翻
  /// 保存即写回 SharedPreferences，切源立即生效。
  Future<void> _editScript(XbpqEntry src) async {
    final code = await XbpqService.instance.readCode(src.key);
    if (!mounted) return;
    if (code == null) {
      AppToast.error('找不到规则内容');
      return;
    }
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
      settings: const RouteSettings(name: 'settings:localPyScript'),
      builder: (_) => LocalScriptEditorPage(
        title: src.name,
        filename: '${src.key}',
        initialCode: code,
        language: 'python',
        onSave: (c) => XbpqService.instance.saveCode(src.key, c),
      ),
    ));
    if (saved == true && mounted) await _afterChange();
  }

  Future<void> _shareKey(String key) async {
    final code = await XbpqService.instance.readCode(key);
    if (code == null || code.isEmpty) {
      AppToast.error('找不到规则内容');
      return;
    }
    await Clipboard.setData(ClipboardData(text: code));
    AppToast.message('规则内容已复制到剪贴板');
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
          count == 1 ? '规则会被删除，不可恢复。' : '将删除选中的 $count 条规则，不可恢复。',
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
    await XbpqService.instance.remove(key);
    await _afterChange();
    AppToast.message('已删除');
  }

  Future<void> _deleteKeys(Set<String> keys) async {
    if (keys.isEmpty) return;
    if (!await _confirmDelete(keys.length)) return;
    for (final key in keys.toList()) {
      await XbpqService.instance.remove(key);
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
    final total = XbpqService.instance.sources.length;
    if (total == 0) return;
    if (!await _confirmDelete(total)) return;
    final n = await XbpqService.instance.clearAll();
    if (!mounted) return;
    setState(() {
      _picked.clear();
      _selectMode = false;
    });
    await _afterChange();
    AppToast.message('已清空 $n 个本地源');
  }

  Future<void> _select(XbpqEntry src) async {
    final bean = src.toSourceBean();
    // 用户在管理页明确点了某个本地源 ⇒ 顺手把**XBPQ**那一族的开关打开，
    // 否则主页源会被订阅线路覆盖（用户 2026-10-18 的开关语义）。
    // 2026-10-29：三族各有独立开关，这里不能再去开「本地爬虫」。
    if (!ApiConfig.instance.localXbpqEnabled.value) {
      await ApiConfig.instance.setLocalXbpqEnabled(true);
    }
    await ApiConfig.instance.setHomeSource(bean);
    await XbpqService.instance.bumpUsage(src.key);
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

  void _toggleAll(List<XbpqEntry> list) {
    final all = list.map((e) => e.key).toSet();
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
      title: 'XBPQ 规则源',
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
              title: '导入规则',
              value: _busy ? '处理中…' : '可多选规则文件，全部导入',
              onTap: _busy ? () {} : _import,
            ),
            SettingsRow(
              icon: Icons.folder_open_outlined,
              title: '文件导入',
              value: _busy ? '处理中…' : '.json / .txt / .zip / 文件夹',
              onTap: _busy ? () {} : _showFileImport,
            ),
            SettingsRow(
              icon: Icons.refresh_rounded,
              title: '重新加载到引擎',
              value: _busy ? '处理中…' : '注册全部本地源',
              onTap: _busy ? () {} : _reloadEngine,
            ),
            SettingsRow(
              icon: Icons.network_check_rounded,
              title: '检测全部源',
              value: _probeHint.isNotEmpty
                  ? _probeHint
                  : '跑一遍首页接口，看能不能用',
              onTap: _probeHint.isNotEmpty || _busy ? () {} : _probeAll,
            ),
          ],
        ),
        const SizedBox(height: AppTheme.spacingXXL),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            '规则保存在 App 本地（SharedPreferences），也可从「文件」导入 .json / .txt。'
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
          //
          // ⚠️ 必须读一个**可观察属性**（如 `.length`）：只写
          //    `ApiConfig.instance.localVideoSources;` 不会注册依赖 —— Rx 对象
          //    本身被读取不等于订阅，GetX 会直接抛
          //    "the improper use of a GetX has been detected"，
          //    release 下整个区块变成灰色 ErrorWidget（用户截图里的长灰条）。
          ApiConfig.instance.localVideoSources.length;
          // 空态看**清单**而不是 beans：开关关闭时 list 仍会读取，
          // 管理页要能继续看到并编辑已导入的规则。
          final all = _sorted;
          final list = _visible;
          if (all.isEmpty) {
            // 空态：不要只留一行字（用户 2026-10-18：下面像一条长空白条）
            return Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 28,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.backgroundSecondary,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.terminal_rounded,
                      size: 40,
                      color: AppTheme.textTertiary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '还没有 XBPQ 规则',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '点上面的「导入规则」粘贴或选择 .json / .txt',
                      style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontFootnote,
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _busy ? null : _import,
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('导入规则'),
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
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _searchField(),
              if (_selectMode) _selectBar(list),
              _headerRow(list.length, total: all.length),
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
              else if (_view.isList)
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

  /// 搜索框（用户 2026-10-20：「py 本地源设置里面加个搜索功能」）
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
              child: Icon(
                Icons.cancel,
                size: 15,
                color: AppTheme.textTertiary,
              ),
            ),
        ],
      ),
    );
  }

  Widget _headerRow(int count, {int? total}) {
    final filtered = total != null && count != total;
    return Row(
      children: [
        Text(
          filtered ? '匹配（$count / $total）' : '已导入（$count）',
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

  Widget _selectBar(List<XbpqEntry> list) {
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
            onPressed: () => _toggleAll(list),
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
                      final c = await XbpqService.instance.readCode(key);
                      if (c != null) codes.add(c);
                    }
                    if (codes.isEmpty) return;
                    await Clipboard.setData(
                      ClipboardData(text: codes.join('\n\n# ----\n\n')),
                    );
                    AppToast.message('已复制 ${codes.length} 条规则');
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

  Widget _listRow(XbpqEntry src, {required String? currentKey}) {
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
            // 长按 = 卡片式菜单（编辑 / 分享 / 多选 / 删除），与网格卡一致
            onLongPress: _selectMode ? null : () => _showCardMenu(src),
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
                          isCurrent ? '当前主页源' : '${src.key}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppTheme.fontFootnote,
                            color: isCurrent
                                ? AppTheme.accentColor
                                : AppTheme.textTertiary,
                          ),
                        ),
                        // 检测结论（没检测过就不占行）
                        if (_probeLine(src.key) != null) ...[
                          const SizedBox(height: 2),
                          _probeLine(src.key)!,
                        ],
                      ],
                    ),
                  ),
                  _stateDot(src.key),
                  const SizedBox(width: 6),
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

  Widget _grid(List<XbpqEntry> list, String? currentKey) {
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

  Widget _gridCard(XbpqEntry src, {required String? currentKey}) {
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
      onLongPress: _selectMode ? null : () => _showCardMenu(src),
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
                _stateDot(src.key),
                if (isCurrent) ...[
                  const SizedBox(width: 6),
                  Icon(
                    Icons.check_circle_rounded,
                    size: 16,
                    color: AppTheme.accentColor,
                  ),
                ],
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
            // 有检测结果就顶掉文件名那行（卡片高度固定，不能多一行）
            if (_probing.contains(src.key) || _probe[src.key] != null)
              _probeLine(src.key)!
            else
              Text(
                isCurrent ? '当前主页源' : '${src.key}',
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
    );
  }

  /// 卡片长按菜单：编辑 / 分享 / 多选 / 删除
  ///
  /// 2026-10-20：用户指出「py 本地设置里面那个源长按不是卡片式的呢」——
  /// 原来是一列 ListTile，现在统一走全站同一套 [showCardActions]（一排 2 张卡片）。
  Future<void> _showCardMenu(XbpqEntry src) async {
    await showCardActions(
      context,
      title: src.name,
      subtitle: 'XBPQ · ${src.key}',
      actions: [
        CardAction(
          icon: Icons.network_check_rounded,
          label: '检测',
          onTap: () => _probeOne(src),
        ),
        CardAction(
          icon: Icons.code_rounded,
          label: '改规则',
          onTap: () => _editScript(src),
        ),
        CardAction(
          icon: Icons.drive_file_rename_outline,
          label: '改名',
          onTap: () => _renameKey(src.key, src.name),
        ),
        CardAction(
          icon: Icons.ios_share_rounded,
          label: '分享',
          onTap: () => _shareKey(src.key),
        ),
        CardAction(
          icon: Icons.checklist_rounded,
          label: '多选',
          onTap: () => _enterSelect(src.key),
        ),
        CardAction(
          icon: Icons.delete_outline_rounded,
          label: '删除',
          danger: true,
          onTap: () => _deleteKey(src.key),
        ),
      ],
    );
  }
}

/// 一次检测的结果
class _ProbeResult {
  const _ProbeResult({
    required this.ok,
    required this.sorts,
    required this.home,
    required this.ms,
    this.error,
  });

  final bool ok;

  /// 分类数量
  final int sorts;

  /// 首页推荐条数
  final int home;

  /// 耗时（毫秒）
  final int ms;

  /// 失败原因（ok=false 时才有）
  final String? error;
}
