import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common/theme.dart';
import '../../reading/source/global_proxy.dart';
import '../../reading/widgets/swipe_action_tile.dart';
import '../../services/app_log.dart';
import '../../widgets/app_toast.dart';
import '../models/hiker_source.dart';
import '../services/hiker_builtin.dart';
import '../services/hiker_files.dart';
import '../services/hiker_prefs.dart';
import '../services/hiker_store.dart';

/// 弹出「源配置」编辑框 —— **首页的「去设置」和源管理页共用**。
///
/// 用户 2026-10-18：「去设置就不能直接到源配置吗？」
/// 原来首页提示只会跳到海阔设置首页，用户还得再进「源管理」找到该源、
/// 再点调节图标；现在直接弹这个框，一步到位。
///
/// [prefillDefaults]：打开时就把能推断的默认值填进去（诊断「需填配置」的
/// 「填入默认配置」按钮走这里），用户确认后保存即可。
Future<void> showHikerSourceConfigDialog(
  BuildContext context,
  HikerSource s, {
  bool prefillDefaults = false,
}) async {
  final store = HikerStore.instance;
  final existing = store.configOf(s.id);
  // 从规则里榨出用到的 config 键，给用户一个"要填什么"的提示
  final keys = s.configKeys;
  final defaults = s.defaultConfig;

  Map<String, dynamic> initial = existing;
  if (prefillDefaults) {
    // 默认值打底，已填的值优先（不覆盖用户手填的）
    initial = <String, dynamic>{...defaults, ...existing};
  }
  final ctrl = TextEditingController(
    text: initial.isEmpty
        ? ''
        : const JsonEncoder.withIndent('  ').convert(initial),
  );

  /// 把默认值并进输入框（保留用户已填的键）
  void fillDefaults() {
    final merged = <String, dynamic>{};
    final cur = ctrl.text.trim();
    if (cur.isNotEmpty) {
      try {
        final j = jsonDecode(cur);
        if (j is Map) merged.addAll(Map<String, dynamic>.from(j));
      } catch (_) {
        // 输入框里不是合法 JSON ⇒ 直接按默认值重建
      }
    }
    if (merged.isEmpty) {
      merged.addAll(defaults);
    } else {
      defaults.forEach((k, v) {
        final cur = merged[k];
        if (cur == null || '$cur'.trim().isEmpty) merged[k] = v;
      });
    }
    ctrl.text = const JsonEncoder.withIndent('  ').convert(merged);
    ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
  }

  final saved = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppTheme.backgroundCard,
      title: Text(
        '源配置 · ${s.title}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: AppTheme.textPrimary,
          fontSize: AppTheme.fontHeadline,
        ),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              keys.isEmpty
                  ? '这个源的规则没有用到 config.xxx。'
                  : '规则用到的配置键：${keys.map((k) => 'config.$k').join('、')}',
              style: TextStyle(
                color: keys.isEmpty
                    ? AppTheme.textTertiary
                    : AppTheme.accentOnSurface,
                fontSize: AppTheme.fontCaption,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              maxLines: 6,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontFootnote,
              ),
              decoration: InputDecoration(
                hintText: '{\n  "host": "https://xxx.com"\n}',
                hintStyle: TextStyle(color: AppTheme.textTertiary),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '留空 = 清空该源配置；必须是 JSON 对象。'
              '${keys.isEmpty ? '' : '「填入默认配置」会按规则兜底值和源域名自动补一版。'}',
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (keys.isNotEmpty)
          TextButton(
            onPressed: fillDefaults,
            child: Text(
              '填入默认配置',
              style: TextStyle(color: AppTheme.accentOnSurface),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text('取消', style: TextStyle(color: AppTheme.textSecondary)),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(ctrl.text),
          child: Text('保存', style: TextStyle(color: AppTheme.accentOnSurface)),
        ),
      ],
    ),
  );
  ctrl.dispose();
  if (saved == null) return;
  if (!isJsonObjectText(saved)) {
    AppToast.error('不是合法的 JSON 对象');
    return;
  }
  final t = saved.trim();
  final cfg = t.isEmpty
      ? <String, dynamic>{}
      : Map<String, dynamic>.from(jsonDecode(t) as Map);
  await store.saveConfig(s.id, cfg);
  AppToast.message(cfg.isEmpty ? '已清空该源配置' : '已保存源配置');
}

/// 「海阔源管理」—— 导入 / 启停 / 删除 / 逐源配置。
///
/// 从「海阔设置 → 海阔源管理」进入；本页只动 `HikerStore`，与其它模块无关。
class HikerManagePage extends StatefulWidget {
  const HikerManagePage({super.key});

  @override
  State<HikerManagePage> createState() => _HikerManagePageState();
}

class _HikerManagePageState extends State<HikerManagePage> {
  final _store = HikerStore.instance;
  final _prefs = HikerPrefs.instance;

  bool _busy = false;
  String _group = ''; // 空 = 全部分组
  bool _usableOnly = false;

  /// 搜索（AppBar 的放大镜切换）
  bool _searching = false;
  final TextEditingController _searchCtl = TextEditingController();
  String _query = '';

  /// 视图：0 = 列表（可长按拖动排序）；1 = 两列卡片
  int _view = 0;

  /// 源诊断的输入：随包资源名 + 用户文件区里的文件（相对路径）
  Set<String> _bundledAssets = const {};
  Set<String> _importedFiles = const {};

  /// 诊断结果缓存（key = 源 id）——列表重建时不重复扫规则文本
  final Map<String, List<HikerSourceDiagnosis>> _diagCache = {};

  @override
  void initState() {
    super.initState();
    _store.addListener(_onChanged);
    _prefs.addListener(_onChanged);
    if (!_store.loaded) {
      _store.load().then((_) {
        if (mounted) setState(() {});
      });
    }
    _loadDiagnosisInputs();
  }

  /// 诊断要用的两份清单（随包资源 / 文件区）。
  /// 读失败就保持空集合：宁可少标，也不误报「缺文件」。
  Future<void> _loadDiagnosisInputs() async {
    try {
      final assets = await HikerBuiltin.assetNames();
      final files = await HikerFiles.list();
      if (!mounted) return;
      setState(() {
        _bundledAssets = assets.toSet();
        _importedFiles = files.map((e) => e.path.replaceAll('\\', '/')).toSet();
        _diagCache.clear();
      });
    } catch (e) {
      AppLog.instance.log('[Hiker] 载入诊断清单失败: $e');
    }
  }

  @override
  void dispose() {
    _store.removeListener(_onChanged);
    _prefs.removeListener(_onChanged);
    _searchCtl.dispose();
    super.dispose();
  }

  void _onChanged() {
    // 源 / 配置变了 ⇒ 诊断结果作废（"需填配置"要跟着消失）
    _diagCache.clear();
    if (mounted) setState(() {});
  }

  // ── 导入 ──────────────────────────────────────────────

  Future<void> _doImport(String text, {String from = ''}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final (added, updated, total) = await _store.importFromText(text);
      if (added == 0 && updated == 0) {
        AppToast.error('没解析出任何源（确认是海阔导出的 JSON 数组）');
      } else {
        AppToast.message('导入完成：新增 $added、更新 $updated，共 $total 个');
      }
    } catch (e) {
      AppToast.error('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importFromClipboard() async {
    final text = await _textDialog(
      title: '粘贴海阔小程序 JSON',
      hint: '[{"title":"…","find_rule":"js:…"}]',
      confirm: '导入',
    );
    if (text == null || text.trim().isEmpty) return;
    await _doImport(text, from: '粘贴');
  }

  Future<void> _importFromFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json', 'txt'],
      );
      if (result.isEmpty) return;
      final path = result.first.path;
      if (path == null) {
        AppToast.message('读不出这个文件（没有本地路径）');
        return;
      }
      await _doImport(await File(path).readAsString(), from: '文件');
    } catch (e) {
      AppToast.error('选择文件失败：$e');
    }
  }

  /// 从 URL 导入：海阔的"导出全部"常挂在网盘/图床直链上，直接抓文本再解析。
  /// 走**全局代理**（与项目其它网络请求一致，开代理时也能拉到）。
  Future<void> _importFromUrl() async {
    final url = await _textDialog(
      title: '从网址导入',
      hint: 'https://…/hiker.json',
      confirm: '下载导入',
    );
    if (url == null || url.trim().isEmpty) return;
    if (_busy) return;
    setState(() => _busy = true);
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60),
        responseType: ResponseType.plain,
      ),
    );
    applyGlobalProxy(dio);
    try {
      final resp = await dio.get<String>(url.trim());
      final text = (resp.data ?? '').toString();
      if (text.trim().isEmpty) {
        AppToast.error('下载到的内容是空的');
        return;
      }
      await _doImport(text, from: '网址');
    } catch (e) {
      AppToast.error('下载失败：$e');
    } finally {
      dio.close(force: true);
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── 逐源配置（规则里的 config.xxx）─────────────────────

  Future<void> _editConfig(HikerSource s) =>
      showHikerSourceConfigDialog(context, s);

  // ── 通用小弹窗 ────────────────────────────────────────

  Future<String?> _textDialog({
    required String title,
    required String hint,
    required String confirm,
  }) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundCard,
        title: Text(
          title,
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontHeadline,
          ),
        ),
        content: TextField(
          controller: ctrl,
          maxLines: 6,
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontFootnote,
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: AppTheme.textTertiary),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('取消', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text),
            child: Text(
              confirm,
              style: TextStyle(color: AppTheme.accentOnSurface),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundCard,
        title: Text(
          '清空全部海阔源？',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontHeadline,
          ),
        ),
        content: Text(
          '只影响「海阔」模块，其它模块不受影响。',
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: AppTheme.fontSubhead,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('清空', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _store.clearAll();
    AppToast.message('已清空');
  }

  // ── UI ────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final total = _store.sources.length;
    final list = _visibleSources();
    final groups = _store.groups;

    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundPrimary,
        foregroundColor: AppTheme.textPrimary,
        elevation: 0,
        title: Text(
          '海阔源管理',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontTitle3,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          IconButton(
            tooltip: _searching ? '关闭搜索' : '搜索',
            onPressed: () => _toggleSearch(),
            icon: Icon(
              _searching ? Icons.search_off_rounded : Icons.search_rounded,
              color: _searching
                  ? AppTheme.accentOnSurface
                  : AppTheme.textSecondary,
            ),
          ),
          IconButton(
            tooltip: _view == 0 ? '切换到卡片视图' : '切换到列表视图',
            onPressed: () => setState(() => _view = _view == 0 ? 1 : 0),
            icon: Icon(
              _view == 0 ? Icons.grid_view_rounded : Icons.view_agenda_outlined,
              color: AppTheme.textSecondary,
            ),
          ),
          IconButton(
            tooltip: '清空',
            onPressed: total == 0 ? null : _clearAll,
            icon: Icon(
              Icons.delete_sweep_outlined,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _statsCard(total),
          const SizedBox(height: 12),

          // 三种导入方式
          Row(
            children: [
              Expanded(
                child: _actionButton(
                  icon: Icons.content_paste_rounded,
                  label: '粘贴',
                  onTap: _busy ? null : _importFromClipboard,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _actionButton(
                  icon: Icons.folder_open_rounded,
                  label: '文件',
                  onTap: _busy ? null : _importFromFile,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _actionButton(
                  icon: Icons.link_rounded,
                  label: '网址',
                  onTap: _busy ? null : _importFromUrl,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          if (total > 0 && _searching) ...[
            _searchBar(),
            const SizedBox(height: 10),
          ],

          // 分组筛选 + 仅可用
          if (total > 0) _filterBar(groups, list.length),
          const SizedBox(height: 8),

          if (total == 0)
            _emptyTip()
          else if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text(
                  _query.trim().isEmpty ? '这个筛选下没有源' : '没有匹配的源',
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontSubhead,
                  ),
                ),
              ),
            )
          else
            _sourcesSection(list),
        ],
      ),
    );
  }

  // ── 搜索 / 视图 / 排序 ────────────────────────────────

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _searchCtl.clear();
        _query = '';
      }
    });
  }

  /// 当前可见的源（分组 → 仅可用 → 搜索词）
  List<HikerSource> _visibleSources() {
    var list = _store.filterSources(group: _group);
    if (_usableOnly) list = list.where((s) => s.usable).toList();
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list
          .where(
            (s) =>
                s.title.toLowerCase().contains(q) ||
                s.author.toLowerCase().contains(q) ||
                s.groupLabel.toLowerCase().contains(q),
          )
          .toList();
    }
    return list;
  }

  Widget _searchBar() {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppTheme.backgroundTertiary,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 18, color: AppTheme.textTertiary),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchCtl,
              autofocus: true,
              textInputAction: TextInputAction.search,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontSubhead,
              ),
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: '搜索源名称 / 作者 / 分组',
                hintStyle: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontSubhead,
                ),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          if (_query.isNotEmpty)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _searchCtl.clear();
                setState(() => _query = '');
              },
              child: Icon(
                Icons.close_rounded,
                size: 16,
                color: AppTheme.textTertiary,
              ),
            ),
        ],
      ),
    );
  }

  /// 列表：长按拖动排序（拖动语义与「导入顺序」一致）
  Widget _sourcesSection(List<HikerSource> list) {
    if (_view == 0) {
      return ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        buildDefaultDragHandles: false,
        itemCount: list.length,
        onReorder: (o, n) => _reorderList(list, o, n),
        proxyDecorator: (child, index, animation) =>
            Material(color: Colors.transparent, child: child),
        itemBuilder: (_, i) => Padding(
          key: ValueKey(list[i].id),
          padding: const EdgeInsets.only(bottom: 10),
          child: ReorderableDelayedDragStartListener(
            index: i,
            child: _swipeCard(list[i]),
          ),
        ),
      );
    }
    // 卡片视图：两列，长按拖到另一张卡片上换位
    final cellWidth = (MediaQuery.sizeOf(context).width - 32 - 10) / 2;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        mainAxisExtent: 128,
      ),
      itemCount: list.length,
      itemBuilder: (_, i) => DragTarget<String>(
        onWillAcceptWithDetails: (d) => d.data != list[i].id,
        onAcceptWithDetails: (d) => _moveTo(d.data, list[i].id),
        builder: (_, candidate, _) => LongPressDraggable<String>(
          data: list[i].id,
          feedback: Material(
            color: Colors.transparent,
            child: SizedBox(
              width: cellWidth,
              height: 128,
              child: _gridCard(list[i], dragging: true),
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.35,
            child: _gridCard(list[i]),
          ),
          child: _gridCard(list[i], highlight: candidate.isNotEmpty),
        ),
      ),
    );
  }

  Future<void> _reorderList(
    List<HikerSource> list,
    int oldIndex,
    int newIndex,
  ) async {
    if (newIndex > oldIndex) newIndex -= 1;
    final ids = list.map((e) => e.id).toList();
    if (oldIndex < 0 || oldIndex >= ids.length) return;
    final moved = ids.removeAt(oldIndex);
    ids.insert(newIndex.clamp(0, ids.length), moved);
    await _applyOrder(ids);
  }

  /// 卡片视图：把 [movedId] 插到 [targetId] 的位置
  Future<void> _moveTo(String movedId, String targetId) async {
    final list = _visibleSources();
    final ids = list.map((e) => e.id).toList();
    final from = ids.indexOf(movedId);
    final to = ids.indexOf(targetId);
    if (from < 0 || to < 0 || from == to) return;
    ids.removeAt(from);
    ids.insert(to, movedId);
    await _applyOrder(ids);
  }

  /// 拖动排序必须落在「导入顺序」上，否则 'name' / 'usable' 会立刻把顺序排回去
  Future<void> _applyOrder(List<String> ids) async {
    if (_prefs.sortBy != 'default') await _prefs.setSortBy('default');
    await _store.reorder(ids);
  }

  Future<void> _shareSource(HikerSource s) async {
    final text = const JsonEncoder.withIndent('  ').convert(s.raw);
    await Clipboard.setData(ClipboardData(text: text));
    AppToast.message('已复制「${s.title}」的源 JSON');
  }

  Future<void> _deleteSource(HikerSource s) async {
    await _store.remove(s.id);
    AppToast.message('已删除「${s.title}」');
  }

  Widget _statsCard(int total) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Row(
        children: [
          _stat('源总数', '$total'),
          _stat('可运行', '${_store.usableCount}'),
          _stat('已启用', '${_store.enabledCount}'),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Expanded(
    child: Column(
      children: [
        Text(
          value,
          style: TextStyle(
            color: AppTheme.accentOnSurface,
            fontSize: AppTheme.fontTitle2,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            color: AppTheme.textTertiary,
            fontSize: AppTheme.fontCaption,
          ),
        ),
      ],
    ),
  );

  Widget _filterBar(List<String> groups, int shown) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 30,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              _chip('全部', _group.isEmpty, () => setState(() => _group = '')),
              ...groups.map(
                (g) => _chip(g, _group == g, () => setState(() => _group = g)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              '显示 $shown 个',
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
              ),
            ),
            const Spacer(),
            Text(
              '仅看可用',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontCaption,
              ),
            ),
            Switch(
              value: _usableOnly,
              activeThumbColor: AppTheme.accentColor,
              onChanged: (v) => setState(() => _usableOnly = v),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ],
        ),
      ],
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? AppTheme.accentSurface : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: on ? AppTheme.accentOnSurface : AppTheme.textSecondary,
            fontSize: AppTheme.fontCaption,
            fontWeight: on ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: AppTheme.accentSurface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 17, color: AppTheme.accentOnSurface),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                color: AppTheme.accentOnSurface,
                fontSize: AppTheme.fontSubhead,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyTip() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.backgroundTertiary,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        '还没有海阔源。用上面的「粘贴 / 文件 / 网址」把海阔导出的 JSON（数组）导进来。\n\n'
        '⚠️ 依赖海阔内置页面模块或宿主能力（WebView 抓页）的源会被标记为不可用 —— 这是导入时就判定好的，不会等点了才报错。',
        style: TextStyle(
          color: AppTheme.textSecondary,
          fontSize: AppTheme.fontFootnote,
          height: 1.6,
        ),
      ),
    );
  }

  /// 这个源的诊断结果（带缓存；配置/文件清单变化时由 [_onChanged] 清掉）
  List<HikerSourceDiagnosis> _diagOf(HikerSource s) => _diagCache.putIfAbsent(
    s.id,
    () => s.diagnose(
      bundledAssets: _bundledAssets,
      importedFiles: _importedFiles,
      config: _store.configOf(s.id),
    ),
  );

  /// 列表行外面再包一层左滑操作（编辑 / 分享 / 删除）
  Widget _swipeCard(HikerSource s) {
    return SwipeActionTile(
      backgroundColor: AppTheme.backgroundSecondary,
      borderRadius: BorderRadius.circular(16),
      actions: [
        SwipeAction(
          icon: Icons.edit_outlined,
          label: '编辑',
          color: const Color(0xFF5B8DEF),
          onTap: () => _editConfig(s),
        ),
        SwipeAction(
          icon: Icons.ios_share_rounded,
          label: '分享',
          color: const Color(0xFF3AAE8C),
          onTap: () => _shareSource(s),
        ),
        SwipeAction(
          icon: Icons.delete_outline_rounded,
          label: '删除',
          color: Colors.redAccent,
          onTap: () => _deleteSource(s),
        ),
      ],
      child: _sourceCard(s),
    );
  }

  Widget _sourceCard(HikerSource s) {
    final isCurrent = _store.currentId == s.id;
    final hasCfg = _store.configOf(s.id).isNotEmpty;
    final issues = _diagOf(s);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isCurrent
              ? AppTheme.accentColor.withValues(alpha: 0.55)
              : AppTheme.borderLight,
          width: isCurrent ? 1.4 : 1,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _store.setCurrent(s.id),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          s.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: AppTheme.fontBody,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (isCurrent) ...[
                        const SizedBox(width: 6),
                        _tag(
                          '当前',
                          AppTheme.accentSurface,
                          AppTheme.accentOnSurface,
                        ),
                      ],
                      if (hasCfg) ...[
                        const SizedBox(width: 4),
                        _tag(
                          '已配置',
                          AppTheme.backgroundTertiary,
                          AppTheme.textSecondary,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${s.author}'
                    '${s.version > 0 ? ' · v${s.version}' : ''}'
                    ' · ${s.groupLabel}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption,
                    ),
                  ),
                  _diagTags(s, issues),
                ],
              ),
            ),
          ),
          IconButton(
            tooltip: '源配置（规则里的 config）',
            onPressed: () => _editConfig(s),
            icon: Icon(
              Icons.tune_rounded,
              size: 18,
              color: AppTheme.textSecondary,
            ),
          ),
          Switch(
            value: _store.isEnabled(s),
            activeThumbColor: AppTheme.accentColor,
            onChanged: (v) => _store.setEnabled(s.id, v),
          ),
        ],
      ),
    );
  }

  /// 卡片视图里的紧凑卡片（两列，长按可拖到别的卡片上换位）
  Widget _gridCard(
    HikerSource s, {
    bool highlight = false,
    bool dragging = false,
  }) {
    final isCurrent = _store.currentId == s.id;
    final hasCfg = _store.configOf(s.id).isNotEmpty;
    final issues = _diagOf(s);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 8),
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: highlight
              ? AppTheme.accentColor
              : (isCurrent
                    ? AppTheme.accentColor.withValues(alpha: 0.55)
                    : AppTheme.borderLight),
          width: highlight ? 1.6 : (isCurrent ? 1.4 : 1),
        ),
        boxShadow: dragging
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 16,
                ),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _store.setCurrent(s.id),
                  child: Text(
                    s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 40,
                height: 22,
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: Switch(
                    value: _store.isEnabled(s),
                    activeThumbColor: AppTheme.accentColor,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (v) => _store.setEnabled(s.id, v),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${s.author.isEmpty ? '佚名' : s.author}'
            '${s.version > 0 ? ' · v${s.version}' : ''}'
            ' · ${s.groupLabel}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppTheme.textTertiary,
              fontSize: AppTheme.fontCaption,
            ),
          ),
          const Spacer(),
          Row(
            children: [
              if (isCurrent)
                _tag('当前', AppTheme.accentSurface, AppTheme.accentOnSurface),
              if (isCurrent && hasCfg) const SizedBox(width: 4),
              if (hasCfg)
                _tag(
                  '已配置',
                  AppTheme.backgroundTertiary,
                  AppTheme.textSecondary,
                ),
              if ((isCurrent || hasCfg) && issues.isNotEmpty)
                const SizedBox(width: 4),
              if (issues.isNotEmpty)
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: issues.first.blocking
                          ? Colors.orange.withValues(alpha: 0.14)
                          : AppTheme.backgroundTertiary,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      issues.first.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: issues.first.blocking
                            ? Colors.orange.shade400
                            : AppTheme.textSecondary,
                        fontSize: AppTheme.fontCaption,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 诊断标签行：直接标出「缺 Apollo / 缺 lazy / 缺文件 / 需填配置」…
  /// 点标签看具体说明与补法（不再等点进源才看到一句报错）。
  Widget _diagTags(HikerSource s, List<HikerSourceDiagnosis> issues) {
    if (issues.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Wrap(
        spacing: 6,
        runSpacing: 5,
        children: [
          for (final d in issues)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _showDiagnosis(s, d),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: d.blocking
                      ? Colors.orange.withValues(alpha: 0.14)
                      : AppTheme.backgroundTertiary,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      d.blocking
                          ? Icons.error_outline_rounded
                          : Icons.info_outline_rounded,
                      size: 11,
                      color: d.blocking
                          ? Colors.orange.shade400
                          : AppTheme.textSecondary,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      d.label,
                      style: TextStyle(
                        color: d.blocking
                            ? Colors.orange.shade400
                            : AppTheme.textSecondary,
                        fontSize: AppTheme.fontCaption,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 诊断详情：说明缺什么、去哪儿补
  void _showDiagnosis(HikerSource s, HikerSourceDiagnosis d) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundCard,
        title: Row(
          children: [
            Icon(
              d.blocking
                  ? Icons.error_outline_rounded
                  : Icons.info_outline_rounded,
              size: 18,
              color: d.blocking
                  ? Colors.orange.shade400
                  : AppTheme.textSecondary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${d.label} · ${s.title}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontHeadline,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          d.detail,
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: AppTheme.fontSubhead,
            height: 1.6,
          ),
        ),
        actions: [
          // 「需填配置」直接给一键默认值：打开配置框时就把能推断的值填好，
          // 用户看一眼点保存即可（比"去填一下"再开空白框少绕一圈）。
          if (d.label == '需填配置')
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                showHikerSourceConfigDialog(context, s, prefillDefaults: true);
              },
              child: Text(
                '填入默认配置',
                style: TextStyle(color: AppTheme.accentOnSurface),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              '知道了',
              style: TextStyle(color: AppTheme.accentOnSurface),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tag(String text, Color bg, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(color: fg, fontSize: AppTheme.fontCaption),
    ),
  );
}
