// lib/rss/pages/rss_manage_page.dart
//
// 「RSS 管理」页（设置 → RSS 管理；RSS 页顶栏的 ⚙ 也是它）。
//
// 版式对齐「书源仓库」(`lib/reading/pages/book_source_repo_page.dart`)：
//   顶栏居中标题 + 右上角「分享 / ⋯」→ 常驻导入卡片 → 计数行 → 胶囊搜索框
//   → 统计 chip 行 → 分组胶囊行 → 源卡片（复选框 / 首字图标 / 状态点 / 标签 / 开关）
//   → 勾选后底部浮出多选操作栏。
//
// 导入支持三种格式（RSS 圈子常见）：
//   · Legado RSS 源 JSON（`{sourceName,sourceUrl,ruleArticles…}`）
//   · **OPML**（RSS 阅读器导出的订阅列表，`<outline xmlUrl=…>`）
//   · 纯文本每行一个地址
//
// ⚠️ 配色统一走 `AppTheme`（跟随影视/直播那套调色板）—— RSS 是和它们并列的
//   顶栏模块；不用阅读模块的 `JellyTheme`（那是另一套可独立切换的调色板）。

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../common/theme.dart';
import '../../reading/pages/book_source_qr_scan_page.dart';
import '../../reading/source/global_proxy.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/card_action_sheet.dart';
import '../../widgets/common_widgets.dart';
import '../models/rss_source.dart';
import '../services/rss_reader.dart';
import '../services/rss_store.dart';
import 'rss_source_edit_page.dart';

/// 列表展示方式（与书源仓 / 漫源仓库同款：列表 / 一行两个）
///
/// ⚠️ 「卡片」（一行一张的大卡片）已按用户要求移除 —— 现在只剩两种视图。
enum _RssView {
  list('列表', Icons.view_list_rounded),
  two('一行两个', Icons.apps_rounded);

  const _RssView(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// 排序方式
enum _RssSort {
  custom('自定义顺序'),
  name('名称'),
  group('分组'),
  enabled('启用优先');

  const _RssSort(this.label);
  final String label;
}

class RssManagePage extends StatefulWidget {
  const RssManagePage({super.key});

  @override
  State<RssManagePage> createState() => _RssManagePageState();
}

class _RssManagePageState extends State<RssManagePage> {
  RssStore get store => RssStore.instance;
  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  static const String _viewKey = 'rss_manage_view';
  static const String _sortKey = 'rss_manage_sort';

  final _urlCtrl = TextEditingController(); // 导入卡片里的地址框
  final _searchCtrl = TextEditingController(); // 页面内筛选框
  String _query = '';
  bool _busy = false;

  /// 正在检测订阅源可用性
  bool _checking = false;

  _RssView _view = _RssView.list;
  _RssSort _sort = _RssSort.custom;

  /// 多选模式（勾选后底部浮出操作栏）
  bool _selectMode = false;
  final Set<String> _selected = {};

  /// 选中的分组（null = 全部）
  String? _pickedGroup;

  @override
  void initState() {
    super.initState();
    _restorePrefs();
    store.tick.addListener(_refresh);
    _searchCtrl.addListener(() {
      if (mounted) setState(() => _query = _searchCtrl.text.trim());
    });
  }

  Future<void> _restorePrefs() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final v = sp.getInt(_viewKey);
      final s = sp.getInt(_sortKey);
      if (!mounted) return;
      setState(() {
        if (v != null && v >= 0 && v < _RssView.values.length) {
          _view = _RssView.values[v];
        }
        if (s != null && s >= 0 && s < _RssSort.values.length) {
          _sort = _RssSort.values[s];
        }
      });
    } catch (_) {}
  }

  Future<void> _setView(_RssView v) async {
    setState(() => _view = v);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_viewKey, v.index);
    } catch (_) {}
  }

  Future<void> _setSort(_RssSort s) async {
    setState(() => _sort = s);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_sortKey, s.index);
    } catch (_) {}
  }

  @override
  void dispose() {
    store.tick.removeListener(_refresh);
    _urlCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  String _groupOf(RssSource s) =>
      s.group.trim().isEmpty ? '未分组' : s.group.trim();

  /// 当前显示（分组筛选 + 关键词筛选 + 排序）
  List<RssSource> get _visible {
    final all = List<RssSource>.of(store.sources);
    var list = all;
    if (_pickedGroup != null) {
      list = list.where((s) => _groupOf(s) == _pickedGroup).toList();
    }
    final q = _query.toLowerCase();
    if (q.isNotEmpty) {
      list = list
          .where((s) =>
              s.name.toLowerCase().contains(q) ||
              s.group.toLowerCase().contains(q) ||
              s.url.toLowerCase().contains(q))
          .toList();
    }
    switch (_sort) {
      case _RssSort.custom:
        break;
      case _RssSort.name:
        list.sort((a, b) => a.name.compareTo(b.name));
        break;
      case _RssSort.group:
        list.sort((a, b) {
          final c = _groupOf(a).compareTo(_groupOf(b));
          return c != 0 ? c : a.name.compareTo(b.name);
        });
        break;
      case _RssSort.enabled:
        list.sort((a, b) {
          if (a.enabled != b.enabled) return a.enabled ? -1 : 1;
          return a.name.compareTo(b.name);
        });
        break;
    }
    return list;
  }

  // ── 页面骨架 ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final list = _visible;
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: _appBar(),
      body: Column(
        children: [
          _importCard(),
          Expanded(
            child: store.sources.isEmpty
                ? _emptyState()
                : (list.isEmpty ? _noMatchState() : _list(list)),
          ),
        ],
      ),
      bottomNavigationBar: _selectMode ? _selectBar() : null,
    );
  }

  PreferredSizeWidget _appBar() {
    return AppBar(
      centerTitle: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      iconTheme: IconThemeData(color: AppTheme.textPrimary),
      title: Text(
        _selectMode ? '已选 ${_selected.length} 项' : 'RSS 管理',
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: AppTheme.fontTitle2,
          fontWeight: FontWeight.w600,
          color: AppTheme.textPrimary,
        ),
      ),
      actions: [
        if (_busy)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppTheme.accentColor),
              ),
            ),
          ),
        if (!_selectMode)
          IconButton(
            tooltip: '检测订阅源',
            onPressed: _checking ? null : _runHealthCheck,
            icon: _checking
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppTheme.accentColor),
                  )
                : Icon(Icons.radar, color: AppTheme.textPrimary),
          ),
        if (!_selectMode)
          _appBarIcon(Icons.ios_share_rounded, '分享全部订阅源', () {
            if (store.sources.isEmpty) return;
            _share(store.sources);
          }),
        _appBarIcon(Icons.menu_rounded, '导入 / 新建', _showImportSheet),
        const SizedBox(width: 2),
      ],
    );
  }

  Widget _appBarIcon(IconData icon, String tooltip, VoidCallback onTap) =>
      IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        icon: Icon(icon, color: AppTheme.textPrimary),
        onPressed: onTap,
      );

  // ── 导入 / 新建菜单（卡片网格）──────────────────────────────────

  /// 六个入口：一行 3 张卡 × 2 行（原来是一行一个的长列表，用户嫌丑且占地）
  static const List<(String, IconData, String)> _importActions = [
    ('new', Icons.add_rounded, '新建源'),
    ('file', Icons.folder_open_rounded, '本地导入'),
    ('net', Icons.cloud_download_outlined, '网络导入'),
    ('qr', Icons.qr_code_scanner_rounded, '二维码导入'),
    ('default', Icons.restore_rounded, '导入默认'),
    ('share', Icons.ios_share_rounded, '分享'),
  ];

  Future<void> _showImportSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetHandle(),
              const SizedBox(height: 14),
              Text('导入订阅源',
                  style: TextStyle(
                      fontSize: AppTheme.fontTitle3,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary)),
              const SizedBox(height: 4),
              Text('支持 JSON / OPML / 纯文本 / 二维码',
                  style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: AppTheme.textTertiary)),
              const SizedBox(height: 16),
              CardGrid(
                columns: 3,
                children: [
                  for (final a in _importActions)
                    CardGridItem(
                      icon: a.$2,
                      title: a.$3,
                      vertical: true,
                      onTap: () {
                        Navigator.pop(ctx);
                        _runImportAction(a.$1);
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _runImportAction(String v) async {
    switch (v) {
      case 'new':
        await _createSource();
      case 'file':
        await _importFile();
      case 'net':
        await _importNet();
      case 'qr':
        await _importQr();
      case 'default':
        final n = await store.restoreBuiltins();
        AppToast.message(n == 0 ? '内置订阅源都在' : '已导入 $n 个内置订阅源');
      case 'share':
        if (store.sources.isEmpty) {
          AppToast.message('还没有订阅源');
          return;
        }
        await _share(store.sources);
    }
  }

  // ── 常驻导入卡片 ────────────────────────────────────────────────

  Widget _importCard() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderLight, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('导入订阅源',
              style: TextStyle(
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary)),
          const SizedBox(height: 3),
          Text('导入按地址合并去重，不会覆盖已有的源',
              style: TextStyle(
                  fontSize: AppTheme.fontFootnote,
                  color: AppTheme.textTertiary)),
          const SizedBox(height: 12),
          TextField(
            controller: _urlCtrl,
            keyboardType: TextInputType.url,
            style: TextStyle(
                fontSize: AppTheme.fontBody, color: AppTheme.textPrimary),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'RSS 地址 / OPML / 站点地址',
              hintStyle: TextStyle(
                  fontSize: AppTheme.fontBody, color: AppTheme.textTertiary),
              filled: true,
              fillColor: _isDark
                  ? Colors.white.withValues(alpha: 0.05)
                  : Colors.black.withValues(alpha: 0.035),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _importFile,
                  style: _outlineStyle(),
                  child: const Text('本地导入',
                      style: TextStyle(fontSize: AppTheme.fontBody)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : _importNet,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('从地址导入',
                      style: TextStyle(fontSize: AppTheme.fontBody)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  ButtonStyle _outlineStyle() => OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 12),
        side: BorderSide(
          color: _isDark
              ? Colors.white.withValues(alpha: 0.22)
              : Colors.black.withValues(alpha: 0.16),
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        foregroundColor: AppTheme.textPrimary,
      );

  // ── 列表 ────────────────────────────────────────────────────────

  Widget _list(List<RssSource> list) {
    final base = store.sources;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
      children: [
        // 共 N 个 + 清空
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 0, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '共 ${base.length} 个源 · 启用 ${store.enabledSources.length} 个',
                  style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: AppTheme.textTertiary),
                ),
              ),
              TextButton(
                onPressed: _clearAll,
                child: const Text('清空',
                    style: TextStyle(fontSize: AppTheme.fontSubhead)),
              ),
            ],
          ),
        ),
        _searchBar(),
        // 统计 chip 行：总数 / 启用 / 停用 / 规则
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: SizedBox(
            height: 32,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: _statChips(base),
            ),
          ),
        ),
        // 分组胶囊行 + 排序 / 视图切换（与书源仓同款按钮）
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: SizedBox(
            height: 34,
            child: Row(
              children: [
                Expanded(
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: _groupChips(base),
                  ),
                ),
                _sortButton(),
                _viewToggleButton(),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        if (_view == _RssView.list)
          for (final s in list) _dragWrap(s, _tile(s))
        else
          GridView.builder(
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              mainAxisExtent: 142,
            ),
            itemCount: list.length,
            itemBuilder: (_, i) => _dragWrap(list[i], _gridTile(list[i])),
          ),
      ],
    );
  }

  // ── 拖动排序（三种视图通用：长按条目任意位置直接拖）─────────────

  Widget _dragWrap(RssSource s, Widget child) {
    if (_selectMode) return child;
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) => d.data != s.id,
      onAcceptWithDetails: (d) => _moveSource(d.data, s.id),
      builder: (_, candidate, __) {
        final tile = LongPressDraggable<String>(
          data: s.id,
          feedback: _dragFeedback(s),
          childWhenDragging: Opacity(opacity: 0.35, child: child),
          child: child,
        );
        if (candidate.isEmpty) return tile;
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.accentColor, width: 1.6),
          ),
          child: tile,
        );
      },
    );
  }

  Widget _dragFeedback(RssSource s) => Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: AppTheme.backgroundSecondary,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Text(
            s.name,
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontSubhead,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );

  Future<void> _moveSource(String fromId, String toId) async {
    if (fromId == toId) return;
    // 拖动时强制回到「自定义顺序」，否则按名称/分组排序后看起来没动
    if (_sort != _RssSort.custom) await _setSort(_RssSort.custom);
    // 只重排当前可见的这一批（分组/搜索筛选时不影响隐藏的源）
    final ids = _visible.map((s) => s.id).toList();
    final from = ids.indexOf(fromId);
    final to = ids.indexOf(toId);
    if (from < 0 || to < 0) return;
    final moved = ids.removeAt(from);
    ids.insert(to.clamp(0, ids.length), moved);
    await store.reorderWithin(ids);
  }

  // ── 排序 / 视图切换 ─────────────────────────────────────────────

  Widget _sortButton() {
    return PopupMenuButton<_RssSort>(
      tooltip: '排序',
      initialValue: _sort,
      color: AppTheme.backgroundSecondary,
      onSelected: _setSort,
      itemBuilder: (_) => [
        for (final v in _RssSort.values)
          PopupMenuItem(
            value: v,
            child: Row(
              children: [
                Icon(
                  v == _sort ? Icons.check_rounded : Icons.sort_rounded,
                  size: 17,
                  color: v == _sort
                      ? AppTheme.accentColor
                      : AppTheme.textSecondary,
                ),
                const SizedBox(width: 8),
                Text(
                  v.label,
                  style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    color: v == _sort
                        ? AppTheme.accentColor
                        : AppTheme.textPrimary,
                  ),
                ),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Icon(Icons.sort_rounded,
            size: 19, color: AppTheme.textSecondary),
      ),
    );
  }

  /// 视图切换：点一下按 列表 → 卡片 → 一行两个 → 列表 轮换
  Widget _viewToggleButton() {
    final next = _RssView.values[(_view.index + 1) % _RssView.values.length];
    return Tooltip(
      message: '视图：${_view.label}（点击切换为${next.label}）',
      child: GestureDetector(
        onTap: () => _setView(next),
        child: Container(
          width: 30,
          height: 30,
          margin: const EdgeInsets.only(left: 2),
          decoration: BoxDecoration(
            color: _isDark
                ? Colors.white.withValues(alpha: 0.07)
                : Colors.black.withValues(alpha: 0.04),
            shape: BoxShape.circle,
          ),
          child: Icon(next.icon, size: 15, color: AppTheme.textSecondary),
        ),
      ),
    );
  }

  /// 胶囊搜索框（透明底 + 一根发丝边框，贴在任何底色上都自适应）
  Widget _searchBar() {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppTheme.borderLight, width: 0.5),
      ),
      child: TextField(
        controller: _searchCtrl,
        textAlignVertical: TextAlignVertical.center,
        style: TextStyle(
            fontSize: AppTheme.fontSubhead, color: AppTheme.textPrimary),
        decoration: InputDecoration(
          isDense: true,
          filled: false,
          hintText: '筛选已订阅的源',
          hintStyle: TextStyle(
              fontSize: AppTheme.fontSubhead, color: AppTheme.textTertiary),
          prefixIcon:
              Icon(Icons.search_rounded, size: 20, color: AppTheme.textTertiary),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 40, minHeight: 40),
          suffixIcon: _searchCtrl.text.isEmpty
              ? null
              : IconButton(
                  icon: Icon(Icons.clear_rounded,
                      size: 18, color: AppTheme.textTertiary),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _query = '');
                  },
                ),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
      ),
    );
  }

  List<Widget> _statChips(List<RssSource> base) {
    final enabled = base.where((s) => s.enabled).length;
    final stats = <(IconData, int)>[
      (Icons.rss_feed, base.length),
      (Icons.check_circle_outline, enabled),
      (Icons.block, base.length - enabled),
      (Icons.flag, base.where((s) => s.hasRules).length),
    ];
    return [
      for (var i = 0; i < stats.length; i++) ...[
        if (i > 0) const SizedBox(width: 8),
        _statChip(stats[i].$1, stats[i].$2),
      ],
      const SizedBox(width: 8),
    ];
  }

  Widget _statChip(IconData icon, int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: _isDark
            ? Colors.white.withValues(alpha: 0.07)
            : Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: AppTheme.textTertiary),
          const SizedBox(width: 5),
          Text('$count',
              style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary)),
        ],
      ),
    );
  }

  List<Widget> _groupChips(List<RssSource> base) {
    final counts = <String, int>{};
    for (final s in base) {
      final g = _groupOf(s);
      counts[g] = (counts[g] ?? 0) + 1;
    }
    // 「内置」排最前，其余按名称
    final keys = counts.keys.toList()
      ..sort((a, b) {
        if (a == '内置') return -1;
        if (b == '内置') return 1;
        return a.compareTo(b);
      });
    return [
      _groupChip('全部', base.length, _pickedGroup == null,
          () => setState(() => _pickedGroup = null)),
      for (final k in keys) ...[
        const SizedBox(width: 8),
        _groupChip(k, counts[k]!, _pickedGroup == k,
            () => setState(() => _pickedGroup = k)),
      ],
      const SizedBox(width: 8),
    ];
  }

  Widget _groupChip(String label, int count, bool on, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on
              ? AppTheme.accentColor
              : (_isDark
                  ? Colors.white.withValues(alpha: 0.07)
                  : Colors.black.withValues(alpha: 0.04)),
          borderRadius: BorderRadius.circular(20),
          border: on ? null : Border.all(color: AppTheme.borderLight, width: 0.5),
        ),
        child: Text(
          '$label $count',
          style: TextStyle(
            fontSize: AppTheme.fontSubhead,
            fontWeight: on ? FontWeight.w600 : FontWeight.normal,
            color: on ? Colors.white : AppTheme.textSecondary,
          ),
        ),
      ),
    );
  }

  /// 一个订阅源卡片
  Widget _tile(RssSource s) {
    final sel = _selected.contains(s.id);
    final cur = s.id == store.selectedId;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: BorderRadius.circular(14),
        border: sel
            ? Border.all(color: AppTheme.accentColor, width: 1.2)
            : Border.all(
                color: cur
                    ? AppTheme.accentColor.withValues(alpha: 0.5)
                    : AppTheme.borderLight,
                width: cur ? 1 : 0.5,
              ),
      ),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 10),
            child: GestureDetector(
              onTap: () => _togglePick(s.id),
              child: Icon(
                sel ? Icons.check_box : Icons.check_box_outline_blank,
                size: 22,
                color: sel ? AppTheme.accentColor : AppTheme.textTertiary,
              ),
            ),
          ),
          Expanded(
            child: ListTile(
              contentPadding: const EdgeInsets.fromLTRB(8, 2, 6, 2),
              leading: _avatar(s),
              title: Row(
                children: [
                  Icon(
                    s.enabled ? Icons.check_circle : Icons.block,
                    size: 14,
                    color: s.enabled ? Colors.green : AppTheme.textTertiary,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.w600,
                        color: s.enabled
                            ? AppTheme.textPrimary
                            : AppTheme.textTertiary,
                      ),
                    ),
                  ),
                ],
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        if (cur) _tag('当前', highlight: true),
                        _tag(_groupOf(s)),
                        if (s.hasRules) _tag('规则'),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      s.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: AppTheme.fontCaption,
                          color: AppTheme.textTertiary),
                    ),
                  ),
                ],
              ),
              onTap: () => _togglePick(s.id),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _menuBtn(s),
                  const SizedBox(width: 2),
                  Switch(
                    value: s.enabled,
                    activeThumbColor: AppTheme.accentColor,
                    onChanged: (v) => store.setEnabled(s.id, v),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 统一的「更多」按钮（长按已用于拖动排序，菜单收在这里）
  Widget _menuBtn(RssSource s, {double size = 18}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showSourceMenu(s),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(
          Icons.more_horiz_rounded,
          size: size,
          color: AppTheme.textTertiary,
        ),
      ),
    );
  }

  Widget _pickIcon(RssSource s, {double size = 22}) {
    final sel = _selected.contains(s.id);
    return GestureDetector(
      onTap: () => _togglePick(s.id),
      child: Icon(
        sel ? Icons.check_box : Icons.check_box_outline_blank,
        size: size,
        color: sel ? AppTheme.accentColor : AppTheme.textTertiary,
      ),
    );
  }

  BoxDecoration _cardDecoration(RssSource s) {
    final sel = _selected.contains(s.id);
    final cur = s.id == store.selectedId;
    return BoxDecoration(
      color: AppTheme.backgroundSecondary,
      borderRadius: BorderRadius.circular(14),
      border: sel
          ? Border.all(color: AppTheme.accentColor, width: 1.2)
          : Border.all(
              color: cur
                  ? AppTheme.accentColor.withValues(alpha: 0.5)
                  : AppTheme.borderLight,
              width: cur ? 1 : 0.5,
            ),
    );
  }

  /// 一行两个：紧凑卡片
  ///
  /// 布局（用户 2026-10-21）：
  ///   左上 = 选择框   右上 = ⋮
  ///   中间 = 只显示名称（**不显示链接**），水平居中
  ///   右下 = 开关；标签留在左下
  Widget _gridTile(RssSource s) {
    final cur = s.id == store.selectedId;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _togglePick(s.id),
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
        decoration: _cardDecoration(s),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                _pickIcon(s, size: 20),
                const SizedBox(width: 5),
                _avatar(s, size: 28),
                const Spacer(),
                _menuBtn(s, size: 18),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              s.name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.15,
                fontWeight: FontWeight.w600,
                color:
                    s.enabled ? AppTheme.textPrimary : AppTheme.textTertiary,
              ),
            ),
            const Spacer(),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Flexible(
                  child: Wrap(
                    spacing: 3,
                    runSpacing: 3,
                    children: [
                      if (cur) _tag('当前', highlight: true),
                      _tag(_groupOf(s)),
                    ],
                  ),
                ),
                // 开关放右下角
                SizedBox(
                  width: 40,
                  height: 26,
                  child: FittedBox(
                    child: Switch(
                      value: s.enabled,
                      activeThumbColor: AppTheme.accentColor,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      onChanged: (v) => store.setEnabled(s.id, v),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _tag(String text, {bool highlight = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
        decoration: BoxDecoration(
          color: highlight
              ? AppTheme.accentColor.withValues(alpha: 0.16)
              : (_isDark
                  ? Colors.white.withValues(alpha: 0.07)
                  : Colors.black.withValues(alpha: 0.045)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppTheme.fontCaption,
            color: highlight ? AppTheme.accentColor : AppTheme.textSecondary,
            fontWeight: highlight ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      );

  /// 首字头像（源没有图标字段 ⇒ 用名称首字，比灰方块好认）
  Widget _avatar(RssSource s, {double size = 40}) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: s.enabled
            ? AppTheme.accentColor.withValues(alpha: 0.15)
            : (_isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.04)),
        borderRadius: BorderRadius.circular(size >= 40 ? 10 : 8),
      ),
      child: Text(
        s.name.isNotEmpty ? s.name.characters.first : '?',
        style: TextStyle(
          fontSize: size >= 40 ? AppTheme.fontHeadline : 15,
          fontWeight: FontWeight.bold,
          color: s.enabled ? AppTheme.accentColor : AppTheme.textTertiary,
        ),
      ),
    );
  }

  void _togglePick(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
      _selectMode = _selected.isNotEmpty;
    });
  }

  // ── 空态 ────────────────────────────────────────────────────────

  Widget _emptyState() => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.rss_feed,
                  size: 48,
                  color: AppTheme.textTertiary.withValues(alpha: 0.55)),
              const SizedBox(height: 20),
              Text('还没有订阅源',
                  style: TextStyle(
                      fontSize: AppTheme.fontTitle3,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textPrimary)),
              const SizedBox(height: 8),
              Text('用上面的地址导入，或从本地 OPML / JSON 文件导入',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      height: 1.6,
                      color: AppTheme.textTertiary)),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _busy ? null : _importNet,
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('去导入订阅源'),
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 22, vertical: 12)),
              ),
            ],
          ),
        ),
      );

  Widget _noMatchState() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded,
                size: 42, color: AppTheme.textTertiary.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text(
              _query.isNotEmpty ? '没有匹配「$_query」的源' : '这个分组下没有源',
              style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  color: AppTheme.textTertiary),
            ),
          ],
        ),
      );

  // ── 多选操作栏 ──────────────────────────────────────────────────

  Widget _selectBar() {
    final all = _visible;
    final allPicked =
        _selected.length == all.length && all.isNotEmpty;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.borderLight, width: 0.5),
      ),
      child: Row(
        children: [
          Text('已选 ${_selected.length} 项',
              style: TextStyle(
                  fontSize: AppTheme.fontBody,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary)),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => setState(() {
              if (allPicked) {
                _selected.clear();
                _selectMode = false;
              } else {
                _selected
                  ..clear()
                  ..addAll(all.map((e) => e.id));
                _selectMode = true;
              }
            }),
            child: Text(allPicked ? '取消全选' : '全选',
                style: const TextStyle(fontSize: AppTheme.fontSubhead)),
          ),
          const Spacer(),
          _barBtn(Icons.toggle_on_outlined, '启用/停用选中', () async {
            final anyOff =
                _selected.any((id) => !(store.byId(id)?.enabled ?? false));
            await store.setEnabledAll(_selected, anyOff);
            if (mounted) setState(() {});
          }),
          _barBtn(Icons.ios_share_rounded, '分享选中', () {
            final picked = store.sources
                .where((s) => _selected.contains(s.id))
                .toList();
            if (picked.isEmpty) return;
            _share(picked);
          }),
          _barBtn(Icons.delete_outline_rounded, '删除选中', () async {
            final n = _selected.length;
            final ok = await _confirm('删除订阅源', '将删除选中的 $n 个订阅源，不可恢复。');
            if (ok != true) return;
            await store.removeAll(_selected);
            if (!mounted) return;
            setState(() {
              _selected.clear();
              _selectMode = false;
            });
            AppToast.message('已删除 $n 个订阅源');
          }),
          _barBtn(Icons.close_rounded, '退出多选', () => setState(() {
                _selected.clear();
                _selectMode = false;
              })),
        ],
      ),
    );
  }

  Widget _barBtn(IconData icon, String tooltip, VoidCallback onTap) => Tooltip(
        message: tooltip,
        child: IconButton(
          onPressed: onTap,
          visualDensity: VisualDensity.compact,
          icon: Icon(icon, size: 21, color: AppTheme.textSecondary),
        ),
      );

  // ── 检测订阅源 ──────────────────────────────────────────────────

  /// 逐个抓第一页：能出文章 = 可用；403/503 走内嵌网页 = 网页型；
  /// 其余（异常 / 0 篇）= 失效。检测完可一键停用失效源。
  Future<void> _runHealthCheck() async {
    if (_checking || _busy) return;
    final targets = store.enabledSources;
    if (targets.isEmpty) {
      AppToast.message('没有启用的订阅源可检测');
      return;
    }
    setState(() => _checking = true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        content: Row(
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                  strokeWidth: 2.5, color: AppTheme.accentColor),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                '正在检测 ${targets.length} 个订阅源…',
                style: TextStyle(color: AppTheme.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );

    final failed = <String, String>{};
    final webOnly = <String>{};
    // 限并发 4：部分源会跑 JS 规则，一次性全开容易互相拖到超时。
    var next = 0;
    Future<void> worker() async {
      while (next < targets.length) {
        final s = targets[next++];
        try {
          final r = await RssReader.fetchArticles(s, ignoreCache: true)
              .timeout(const Duration(seconds: 20));
          if (r.siteLike) {
            webOnly.add(s.id);
          } else if (r.articles.isEmpty) {
            failed[s.id] = '没有抓到文章（站点改版或规则失效）';
          }
        } catch (e) {
          failed[s.id] = _short(e);
        }
      }
    }

    final workers = targets.length < 4 ? targets.length : 4;
    await Future.wait(List.generate(workers, (_) => worker()));
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    setState(() => _checking = false);

    final ok = targets.length - failed.length - webOnly.length;
    if (failed.isEmpty) {
      AppToast.message(webOnly.isEmpty
          ? '检测完成：${targets.length} 个源全部可用'
          : '检测完成：$ok 个可用，${webOnly.length} 个需网页模式');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text(
          '检测完成：$ok 可用 / ${failed.length} 失败',
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
              if (webOnly.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    '另有 ${webOnly.length} 个源会自动用内嵌网页打开',
                    style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      color: AppTheme.textTertiary,
                    ),
                  ),
                ),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final e in failed.entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              store.byId(e.key)?.name ?? e.key,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                            Text(
                              e.value,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: AppTheme.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await store.setEnabledAll(failed.keys, false);
              if (ctx.mounted) Navigator.pop(ctx);
              AppToast.message('已停用 ${failed.length} 个失效源');
            },
            child: const Text('停用失败源'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // ── 源菜单 / 分享 / 清空 ────────────────────────────────────────

  Future<void> _showSourceMenu(RssSource s) async {
    await showCardActions(
      context,
      title: s.name,
      subtitle: s.url,
      actions: [
        if (s.id != store.selectedId)
          CardAction(
            icon: Icons.radio_button_checked,
            label: '当前',
            onTap: () async {
              await store.select(s.id);
              AppToast.message('已切换到「${s.name}」');
            },
          ),
        CardAction(
          icon: Icons.tune_rounded,
          label: '编辑',
          onTap: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => RssSourceEditPage(source: s),
              ),
            );
            if (mounted) setState(() {});
          },
        ),
        CardAction(
          icon: Icons.edit_rounded,
          label: '改名',
          onTap: () async {
            final n = await _askText(
              title: '重命名订阅源',
              hint: '名称',
              initial: s.name,
            );
            if (n != null && n.trim().isNotEmpty) {
              await store.rename(s.id, n);
            }
          },
        ),
        CardAction(
          icon: Icons.ios_share_rounded,
          label: '分享',
          onTap: () async {
            await Clipboard.setData(
              ClipboardData(text: encodeRssSources([s])),
            );
            AppToast.message('已复制，可直接分享给别人');
          },
        ),
        CardAction(
          icon: Icons.folder_outlined,
          label: '分组',
          onTap: () => _pickGroup(s),
        ),
        if (s.showWebLog)
          CardAction(
            icon: Icons.article_outlined,
            label: '日志',
            onTap: () => _showWebLogs(s),
          ),
        CardAction(
          icon: Icons.delete_outline_rounded,
          label: '删除',
          danger: true,
          onTap: () async {
            final ok = await _confirm('删除订阅源', '确定删除「${s.name}」吗？');
            if (ok == true) await store.remove(s.id);
          },
        ),
      ],
    );
  }

  /// 修改分组（含新建）
  Future<void> _pickGroup(RssSource s) async {
    final groups = <String>{
      for (final e in store.sources)
        if (e.group.trim().isNotEmpty) e.group.trim(),
    }.toList()..sort();
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '移动到分组',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: SingleChildScrollView(
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _groupChoice(
                        '未分组',
                        s.group.trim().isEmpty,
                        () => Navigator.of(ctx).pop(''),
                      ),
                      for (final g in groups)
                        _groupChoice(
                          g,
                          s.group.trim() == g,
                          () => Navigator.of(ctx).pop(g),
                        ),
                      _groupChoice(
                        '＋ 新建',
                        false,
                        () => Navigator.of(ctx).pop('__new__'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    var target = picked;
    if (target == '__new__') {
      final name = await _askText(
        title: '新建分组',
        hint: '分组名称',
        initial: '',
      );
      if (name == null || name.trim().isEmpty || !mounted) return;
      target = name.trim();
    }
    await store.setGroup(s.id, target);
    if (mounted) setState(() {});
  }

  Widget _groupChoice(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppTheme.accentColor : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.borderLight, width: 0.5),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : AppTheme.textSecondary,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  /// `showWebLog=true` 源的 JS 运行日志（`source.log` / `console.log`）。
  Future<void> _showWebLogs(RssSource s) async {
    final lines = RssReader.webLogs(s);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SheetHandle(),
              const SizedBox(height: 14),
              Row(
                children: [
                  Text('JS 日志',
                      style: TextStyle(
                          fontSize: AppTheme.fontTitle3,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary)),
                  const Spacer(),
                  TextButton(
                    onPressed: () {
                      RssReader.clearWebLogs(s);
                      Navigator.pop(ctx);
                    },
                    child: const Text('清空'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (lines.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 26),
                  child: Text('还没有日志 —— 跑一次分类/列表后再来看',
                      style: TextStyle(
                          fontSize: AppTheme.fontSubhead,
                          color: AppTheme.textTertiary)),
                )
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final l in lines)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: SelectableText(
                              l,
                              style: TextStyle(
                                  fontSize: AppTheme.fontCaption,
                                  height: 1.5,
                                  color: AppTheme.textSecondary),
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
    );
  }

  /// 分享（复制 JSON 到剪贴板）
  Future<void> _share(List<RssSource> list) async {
    await Clipboard.setData(ClipboardData(text: encodeRssSources(list)));
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text('已复制 ${list.length} 个订阅源',
            style: TextStyle(
                fontSize: AppTheme.fontHeadline, color: AppTheme.textPrimary)),
        content: Text(
          'JSON 已复制到剪贴板，可直接粘贴分享给别人。\n\n'
          '对方用「本地导入 / 网络导入」收下即可。',
          style: TextStyle(
              fontSize: AppTheme.fontSubhead,
              height: 1.6,
              color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
        ],
      ),
    );
  }

  Future<void> _clearAll() async {
    final n = store.sources.length;
    if (n == 0) return;
    final ok = await _confirm('清空订阅源', '将删除全部 $n 个订阅源，不可恢复。');
    if (ok != true) return;
    await store.removeAll(store.sources.map((s) => s.id));
    if (!mounted) return;
    setState(() => _pickedGroup = null);
    AppToast.message('已清空');
  }

  // ── 导入 ────────────────────────────────────────────────────────

  Future<void> _createSource() async {
    final name = await _askText(title: '新建订阅源', hint: '名称', initial: '');
    if (name == null || name.trim().isEmpty) return;
    if (!mounted) return;
    final url = await _askText(
        title: '新建订阅源', hint: 'RSS 地址或站点地址', initial: '');
    if (url == null || url.trim().isEmpty) return;
    final r = await store
        .addAll([RssSource.fromUrl(url.trim(), name: name.trim())]);
    AppToast.message(r.added > 0 ? '已添加「${name.trim()}」' : '这个地址已经在列表里了');
  }

  /// 从地址导入：优先用导入卡片里填的地址，没填就弹框要一个
  Future<void> _importNet() async {
    var url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      if (!mounted) return;
      final input = await _askText(
          title: '网络导入', hint: '订阅地址（JSON / OPML / 文本）', initial: '');
      if (input == null || input.trim().isEmpty) return;
      url = input.trim();
    }
    setState(() => _busy = true);
    try {
      await _absorb(await _fetchText(url));
    } catch (e) {
      AppToast.error('导入失败：${_short(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 二维码导入：复用书源仓库那个纯扫码页（扫到文本即返回）
  Future<void> _importQr() async {
    final text = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const BookSourceQrScanPage()),
    );
    if (text == null || text.trim().isEmpty) return;
    if (!mounted) return;
    setState(() => _busy = true);
    try {
      final raw = text.trim();
      // 扫到的是**单个网址**（常见：二维码里放订阅列表的下载地址）：
      // 先把网址内容下载下来按 JSON/OPML 源列表解析；下载失败、或内容
      // 根本不是源列表（网址本身就是一个 RSS 订阅页）时，回退为直接
      // 订阅这个网址，避免「只导入了网址本身」的问题（2026-10-15）。
      if (_isBareHttpUrl(raw)) {
        String? body;
        try {
          body = await _fetchText(raw);
        } catch (_) {}
        if (body != null &&
            body.trim().isNotEmpty &&
            parseRssSources(body).isNotEmpty) {
          await _absorb(body);
          return;
        }
      }
      await _absorb(raw);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 是否是**单行** http(s) 网址（JSON / OPML 内容不会命中）。
  bool _isBareHttpUrl(String s) {
    if (s.isEmpty || s.contains('\n') || s.contains('\r')) return false;
    return s.startsWith('http://') || s.startsWith('https://');
  }

  /// 下载文本（套全局代理）——网络导入 / 二维码导入共用。
  Future<String> _fetchText(String url) async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      responseType: ResponseType.plain,
      headers: {'User-Agent': 'Mozilla/5.0'},
    ));
    try {
      // ⚠️ 必须套全局代理（漏了它开了代理就必然 DioException unknown）
      applyGlobalProxy(dio);
      final resp = await dio.get<String>(url);
      return resp.data ?? '';
    } finally {
      dio.close(force: true);
    }
  }

  Future<void> _importFile() async {
    try {
      final res = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json', 'opml', 'xml', 'txt'],
        // file_picker 13.x：`pickFiles()` 默认就支持多选（`allowMultiple`
        // 参数已移除），返回 List<PlatformFile>；这里遍历全部文件。
      );
      if (res.isEmpty) return;
      setState(() => _busy = true);
      final all = <RssSource>[];
      for (final f in res) {
        String text;
        try {
          // ⚠️ 必须 utf8.decode：String.fromCharCodes 会把中文源名变成乱码
          text = utf8.decode(await f.readAsBytes(), allowMalformed: true);
        } catch (_) {
          final p = f.path;
          if (p == null) continue;
          text = await File(p).readAsString();
        }
        all.addAll(parseRssSources(text));
      }
      if (!mounted) return;
      await _absorbList(all);
    } catch (e) {
      AppToast.error('导入失败：${_short(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 解析文本 → 入库。
  Future<void> _absorb(String text) async {
    final list = parseRssSources(text);
    if (list.isEmpty) {
      AppToast.error('没解析出订阅源（支持 JSON / OPML / 每行一个地址）');
      return;
    }
    await _absorbList(list);
  }

  /// 已解析好的源批量入库（多文件导入时合并成一次写盘）。
  Future<void> _absorbList(List<RssSource> list) async {
    if (list.isEmpty) {
      AppToast.error('没解析出订阅源（支持 JSON / OPML / 每行一个地址）');
      return;
    }
    final r = await store.addAll(list);
    AppToast.message(r.added == 0
        ? '这些源都已经有了（跳过 ${r.skipped}）'
        : '已导入 ${r.added} 个源${r.skipped > 0 ? '，跳过重复 ${r.skipped}' : ''}');
  }

  // ── 小工具 ──────────────────────────────────────────────────────

  String _short(Object e) {
    final s = e.toString().replaceAll('\n', ' ');
    return s.length > 70 ? s.substring(0, 70) : s;
  }

  Future<bool?> _confirm(String title, String content) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.backgroundSecondary,
          title: Text(title,
              style: TextStyle(
                  fontSize: AppTheme.fontHeadline, color: AppTheme.textPrimary)),
          content: Text(content,
              style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  color: AppTheme.textSecondary)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('删除',
                    style: TextStyle(color: Colors.redAccent))),
          ],
        ),
      );

  Future<String?> _askText({
    required String title,
    required String hint,
    required String initial,
  }) async {
    final ctrl = TextEditingController(text: initial);
    try {
      return await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.backgroundSecondary,
          title: Text(title,
              style: TextStyle(
                  fontSize: AppTheme.fontHeadline, color: AppTheme.textPrimary)),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            style: TextStyle(
                fontSize: AppTheme.fontSubhead, color: AppTheme.textPrimary),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(
                  fontSize: AppTheme.fontSubhead, color: AppTheme.textTertiary),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text),
                child: const Text('确定')),
          ],
        ),
      );
    } finally {
      ctrl.dispose();
    }
  }
}
