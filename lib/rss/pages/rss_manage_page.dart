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

class RssManagePage extends StatefulWidget {
  const RssManagePage({super.key});

  @override
  State<RssManagePage> createState() => _RssManagePageState();
}

class _RssManagePageState extends State<RssManagePage> {
  RssStore get store => RssStore.instance;
  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  final _urlCtrl = TextEditingController(); // 导入卡片里的地址框
  final _searchCtrl = TextEditingController(); // 页面内筛选框
  String _query = '';
  bool _busy = false;

  /// 多选模式（勾选后底部浮出操作栏）
  bool _selectMode = false;
  final Set<String> _selected = {};

  /// 选中的分组（null = 全部）
  String? _pickedGroup;

  @override
  void initState() {
    super.initState();
    store.tick.addListener(_refresh);
    _searchCtrl.addListener(() {
      if (mounted) setState(() => _query = _searchCtrl.text.trim());
    });
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

  /// 当前显示（分组筛选 + 关键词筛选）
  List<RssSource> get _visible {
    var all = store.sources;
    if (_pickedGroup != null) {
      all = all.where((s) => _groupOf(s) == _pickedGroup).toList();
    }
    final q = _query.toLowerCase();
    if (q.isEmpty) return all;
    return all
        .where((s) =>
            s.name.toLowerCase().contains(q) ||
            s.group.toLowerCase().contains(q) ||
            s.url.toLowerCase().contains(q))
        .toList();
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
        // 分组胶囊行
        Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: _groupChips(base),
            ),
          ),
        ),
        const SizedBox(height: 4),
        for (final s in list) _tile(s),
      ],
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
                  const SizedBox(width: 5),
                  GestureDetector(
                    onTap: () => _showSourceMenu(s),
                    child: Icon(Icons.info_outline_rounded,
                        size: 16, color: AppTheme.textTertiary),
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
              onLongPress: () => _showSourceMenu(s),
              trailing: Switch(
                value: s.enabled,
                activeThumbColor: AppTheme.accentColor,
                onChanged: (v) => store.setEnabled(s.id, v),
              ),
            ),
          ),
        ],
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
  Widget _avatar(RssSource s) {
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: s.enabled
            ? AppTheme.accentColor.withValues(alpha: 0.15)
            : (_isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.04)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        s.name.isNotEmpty ? s.name.characters.first : '?',
        style: TextStyle(
          fontSize: AppTheme.fontHeadline,
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
