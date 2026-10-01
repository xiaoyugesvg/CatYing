import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/book_source.dart';
import '../services/book_source_service.dart';
import 'book_source_login_page.dart';
import '../theme/jelly_theme.dart';

/// 书源仓库 —— 小说书源（Legado 格式）的导入与管理。
///
/// ── 界面参照 ──────────────────────────────────────────────────
/// 按 **cmbok V2.0.7** 的书源页重做（用户提供截图）：
///   · 标题「书源」+ 右侧搜索框「搜索书源图书」
///   · 空态：「还没有书源 / 用地址、口令或本地文件导入书源」+「+ 去导入书源」
///   · 导入三种方式：**地址 / 口令 / 本地文件**（截图原文）
///
/// ── 为什么早期判断失误（记下来免得再错）────────────────────────
/// 开源仓库 hlning/cmbok_app 的快照停在 **V2.0.3**，而书源仓库是
/// **V2.0.7** 新增的功能（其更新说明明确列出"书源仓库：多选删除、分享"、
/// "书源页/仓库：分组功能"、"书源体检"、"书源编辑"、"书源变量"），
/// 之后源码不再开源 —— 所以源码里搜不到，但发布版里确实有。
/// **教训：判断某功能是否存在，不能只看开源快照，要看发布说明。**
///
/// ── 与「漫画源仓库」的关系 ────────────────────────────────────
/// 两个**独立**页面，不共用任何代码：
///   · 漫画源仓库 = SiteConfig（取图片）+ SourceConfigStore
///   · 本页       = Legado BookSource（取文字）+ BookSourceStore
class BookSourceRepoPage extends StatefulWidget {
  const BookSourceRepoPage({super.key});

  @override
  State<BookSourceRepoPage> createState() => _BookSourceRepoPageState();
}

class _BookSourceRepoPageState extends State<BookSourceRepoPage> {
  final store = BookSourceStore.instance;
  final _searchCtrl = TextEditingController();
  /// 顶部导入卡片的地址输入框
  final _urlCtrl = TextEditingController();
  bool _busy = false;
  bool _selectMode = false;
  bool _searching = false;
  String _keyword = '';
  bool _autoImportHandled = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    if (store.isEmpty) store.init();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 带 {action:'import'} 进入时直接弹导入（供"去导入书源"类入口复用）。
    // 只用一次，避免每次依赖变化都弹。
    if (_autoImportHandled) return;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map && args['action'] == 'import') {
      _autoImportHandled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showImportSheet();
      });
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _card => _isDark ? JellyTheme.cardDark : JellyTheme.cardLight;
  Color get _titleColor =>
      _isDark ? Colors.white : JellyTheme.textPrimaryLight;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
  }

  /// 搜索过滤结果
  List<BookSource> get _visible {
    final all = store.sorted();
    if (_keyword.isEmpty) return all;
    final k = _keyword.toLowerCase();
    return all
        .where((s) =>
            s.name.toLowerCase().contains(k) ||
            s.url.toLowerCase().contains(k) ||
            s.group.toLowerCase().contains(k))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
          _isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
      appBar: _buildAppBar(),
      body: ListenableBuilder(
        listenable: store.revision,
        builder: (context, _) {
          final list = _visible;
          return Column(
            children: [
              // 导入卡片**常驻页面顶部**（不藏进弹层）。
              // 按 cmbok V2.0.7 截图：地址输入框 + 三个并排按钮就在页面上，
              // 用户一眼看到"能怎么导"。
              _importCard(),
              if (_selectMode) _selectBar(store.sorted()),
              Expanded(
                child: store.isEmpty
                    ? _emptyState()
                    : (list.isEmpty ? _noMatchState() : _sourceList(list)),
              ),
            ],
          );
        },
      ),
      floatingActionButton: _selectMode && _selected.isNotEmpty
          ? FloatingActionButton.extended(
              onPressed: _deleteSelected,
              icon: const Icon(Icons.delete_outline),
              label: const Text('删除选中'),
              backgroundColor: Colors.redAccent,
            )
          : null,
    );
  }

  // ============================================================
  // 导入卡片（按截图：标题 + 说明 + 地址框 + 三个并排按钮）
  // ============================================================

  Widget _importCard() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('导入书源',
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: _titleColor)),
          const SizedBox(height: 3),
          Text(
            // 截图原文。这句很重要：用户最怕"导入会不会把我已有的源冲掉"
            '导入按地址合并去重，不会覆盖已有的源',
            style: TextStyle(fontSize: 12, color: JellyTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlCtrl,
            style: TextStyle(fontSize: 13.5, color: _titleColor),
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              hintText: '书源地址（json / zip / 仓库索引）',
              hintStyle:
                  TextStyle(fontSize: 13.5, color: JellyTheme.textSecondary),
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
                  onPressed: _busy ? null : _importByFile,
                  style: _outlineStyle(),
                  child: const Text('导入文件', style: TextStyle(fontSize: 13.5)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy ? null : _importByCode,
                  style: _outlineStyle(),
                  child: const Text('口令导入', style: TextStyle(fontSize: 13.5)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : _importByUrlFromField,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('从地址导入',
                          style: TextStyle(fontSize: 13.5)),
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
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        foregroundColor: _titleColor,
      );

  // ============================================================
  // AppBar：标题「书源仓库」（居中）+ 分享 + 体检（按截图）
  // ============================================================

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      centerTitle: true,
      title: _searching
          ? TextField(
              controller: _searchCtrl,
              autofocus: true,
              style: TextStyle(fontSize: 15, color: _titleColor),
              decoration: InputDecoration(
                hintText: '搜索书源',
                hintStyle:
                    TextStyle(fontSize: 15, color: JellyTheme.textSecondary),
                border: InputBorder.none,
                isDense: true,
              ),
              onChanged: (v) => setState(() => _keyword = v.trim()),
            )
          : Text(
              _selectMode ? '已选 ${_selected.length}' : '书源仓库',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w600,
                color: _titleColor,
              ),
            ),
      actions: [
        // 分享（截图右上第一个）：导出全部书源 JSON
        IconButton(
          tooltip: '分享书源',
          icon: Icon(Icons.ios_share_rounded, color: _titleColor),
          onPressed: store.isEmpty ? null : _shareAll,
        ),
        // 体检（截图右上第二个，盾牌带 +）：V2.0.7 的「书源体检」
        IconButton(
          tooltip: '书源体检',
          icon: _healthChecking
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(Icons.verified_user_rounded, color: _titleColor),
          onPressed:
              (store.isEmpty || _healthChecking) ? null : _runHealthCheck,
        ),
        // 搜索 + 多选放在体检之后（截图里没有，但少了不好用）
        IconButton(
          tooltip: _searching ? '关闭搜索' : '搜索书源',
          icon: Icon(_searching ? Icons.close_rounded : Icons.search_rounded),
          onPressed: () => setState(() {
            _searching = !_searching;
            if (!_searching) {
              _searchCtrl.clear();
              _keyword = '';
            }
          }),
        ),
        if (!store.isEmpty)
          IconButton(
            tooltip: _selectMode ? '退出多选' : '多选',
            icon: Icon(
                _selectMode ? Icons.done_rounded : Icons.checklist_rounded),
            onPressed: () => setState(() {
              _selectMode = !_selectMode;
              _selected.clear();
            }),
          ),
        const SizedBox(width: 4),
      ],
    );
  }

  /// 分享全部书源：复制 JSON 到剪贴板（并提示可粘贴给他人）
  Future<void> _shareAll() async {
    final json =
        BookSourceService.instance.exportSources(store.sorted());
    await Clipboard.setData(ClipboardData(text: json));
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('已复制书源', style: TextStyle(fontSize: 16)),
        content: Text(
          '${store.all.length} 个书源的 JSON 已复制到剪贴板，'
          '可直接粘贴分享给别人。\n\n'
          '对方用「口令导入」粘贴即可导入。',
          style: const TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 从顶部地址栏导入
  Future<void> _importByUrlFromField() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      _toast('请先填写书源地址');
      return;
    }
    await _fetchAndImport(url);
  }


  Widget _selectBar(List<BookSource> list) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Row(
        children: [
          TextButton(
            onPressed: () => setState(() {
              if (_selected.length == list.length) {
                _selected.clear();
              } else {
                _selected
                  ..clear()
                  ..addAll(list.map((e) => e.id));
              }
            }),
            child: Text(_selected.length == list.length ? '取消全选' : '全选'),
          ),
          const Spacer(),
          TextButton(
            onPressed: () {
              for (final id in _selected.toList()) {
                store.setEnabled(id, true);
              }
              _toast('已启用 ${_selected.length} 个');
            },
            child: const Text('启用'),
          ),
          TextButton(
            onPressed: () {
              for (final id in _selected.toList()) {
                store.setEnabled(id, false);
              }
              _toast('已停用 ${_selected.length} 个');
            },
            child: const Text('停用'),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 空态（照截图：还没有书源 / 用地址、口令或本地文件导入书源 / 去导入书源）
  // ============================================================

  Widget _emptyState() => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.menu_book_outlined,
                  size: 56,
                  color: JellyTheme.textSecondary.withValues(alpha: 0.55)),
              const SizedBox(height: 20),
              Text('还没有书源',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: _titleColor)),
              const SizedBox(height: 8),
              Text('用上面的地址、口令或本地文件导入',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 13, color: JellyTheme.textSecondary)),
              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: _busy ? null : _showImportSheet,
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('去导入书源'),
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                ),
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
                size: 42,
                color: JellyTheme.textSecondary.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            Text('没有匹配「$_keyword」的书源',
                style: TextStyle(fontSize: 13, color: JellyTheme.textSecondary)),
          ],
        ),
      );

  // ============================================================
  // 列表
  // ============================================================

  Widget _sourceList(List<BookSource> list) {
    final groups = <String, List<BookSource>>{};
    for (final s in list) {
      groups.putIfAbsent(s.group, () => []).add(s);
    }
    final out = <Widget>[];
    final on = list.where((e) => e.enabled).length;
    out.add(Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
      child: Row(
        children: [
          // 截图只显示「共 N 个」；启用数放在按钮文案里体现
          // （"全部停用"就意味着当前全启用），不再挤在同一行
          Text('共 ${list.length} 个',
              style: TextStyle(fontSize: 12.5, color: JellyTheme.textSecondary)),
          const Spacer(),
          if (!_selectMode) ...[
            TextButton(
              onPressed: () => store.setAllEnabled(on != list.length),
              child: Text(on == list.length ? '全部停用' : '全部启用',
                  style: const TextStyle(fontSize: 12)),
            ),
          ],
        ],
      ),
    ));

    if (groups.length <= 1) {
      out.addAll(list.map(_sourceTile));
    } else {
      groups.forEach((g, items) {
        out.add(Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
          child: Text('$g（${items.length}）',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: JellyTheme.primary)),
        ));
        out.addAll(items.map(_sourceTile));
      });
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
      children: out,
    );
  }

  Widget _sourceTile(BookSource s) {
    final sel = _selected.contains(s.id);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: sel ? Border.all(color: JellyTheme.primary, width: 1.2) : null,
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(14, 2, 6, 2),
        leading: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: JellyTheme.primary.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(Icons.menu_book_rounded,
              size: 19, color: JellyTheme.primary),
        ),
        title: Text(
          s.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: s.enabled ? _titleColor : JellyTheme.textSecondary,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              s.url.isEmpty ? s.group : s.url,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: JellyTheme.textSecondary),
            ),
            // 体检过就在卡片上标出来，不用点进去看
            if (_health[s.id] != null) _healthBadge(_health[s.id]!),
          ],
        ),
        onTap: _selectMode
            ? () => setState(() {
                  if (sel) {
                    _selected.remove(s.id);
                  } else {
                    _selected.add(s.id);
                  }
                })
            : () => _showDetail(s),
        trailing: _selectMode
            ? Icon(
                sel ? Icons.check_circle : Icons.circle_outlined,
                color: sel ? JellyTheme.primary : JellyTheme.textSecondary,
                size: 22,
              )
            : Switch(
                value: s.enabled,
                activeThumbColor: JellyTheme.primary,
                onChanged: (v) => store.setEnabled(s.id, v),
              ),
      ),
    );
  }

  // ============================================================
  // 导入：地址 / 口令 / 本地文件（截图原文的三种方式）
  // ============================================================

  Future<void> _showImportSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: JellyTheme.textSecondary.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Text('导入书源',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: _titleColor)),
              const SizedBox(height: 6),
              Text('用地址、口令或本地文件导入书源',
                  style: TextStyle(
                      fontSize: 12.5, color: JellyTheme.textSecondary)),
              const SizedBox(height: 18),
              _importOption(
                icon: Icons.link_rounded,
                title: '地址导入',
                subtitle: '填书源列表网址，自动拉取',
                onTap: () {
                  Navigator.pop(ctx);
                  _importByUrl();
                },
              ),
              _importOption(
                icon: Icons.key_rounded,
                title: '口令导入',
                subtitle: '粘贴分享口令或书源 JSON',
                onTap: () {
                  Navigator.pop(ctx);
                  _importByCode();
                },
              ),
              _importOption(
                icon: Icons.folder_open_rounded,
                title: '本地文件导入',
                subtitle: '选择 .json / .txt 书源文件',
                onTap: () {
                  Navigator.pop(ctx);
                  _importByFile();
                },
              ),
              const SizedBox(height: 18),
            ],
          ),
        ),
      ),
    );
  }

  Widget _importOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) =>
      ListTile(
        onTap: onTap,
        leading: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: JellyTheme.primary.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(icon, size: 20, color: JellyTheme.primary),
        ),
        title: Text(title,
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: _titleColor)),
        subtitle: Text(subtitle,
            style: TextStyle(fontSize: 12, color: JellyTheme.textSecondary)),
        trailing: Icon(Icons.chevron_right_rounded,
            color: JellyTheme.textSecondary),
      );

  /// 地址导入
  Future<void> _importByUrl() async {
    final ctrl = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('地址导入',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _titleColor)),
                const SizedBox(height: 4),
                Text('支持 http(s) 链接；返回内容为书源 JSON',
                    style: TextStyle(
                        fontSize: 12, color: JellyTheme.textSecondary)),
                const SizedBox(height: 10),
                TextField(
                  controller: ctrl,
                  style: const TextStyle(fontSize: 13),
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    hintText: 'https://example.com/booksource.json',
                    hintStyle: TextStyle(
                        fontSize: 13, color: JellyTheme.textSecondary),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 12),
                  ),
                ),
                const SizedBox(height: 14),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () async {
                      final url = ctrl.text.trim();
                      if (url.isEmpty) {
                        _toast('请先填写网址');
                        return;
                      }
                      Navigator.pop(ctx);
                      await _fetchAndImport(url);
                    },
                    child: const Text('拉取并导入'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    ctrl.dispose();
  }

  /// 口令导入（粘贴）
  Future<void> _importByCode() async {
    final ctrl = TextEditingController();
    var error = '';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          top: false,
          child: Padding(
            padding:
                EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('口令导入',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: _titleColor)),
                  const SizedBox(height: 4),
                  Text('粘贴分享口令或书源 JSON（单个 / 数组 / {"sources":[…]} 都行）',
                      style: TextStyle(
                          fontSize: 12, color: JellyTheme.textSecondary)),
                  const SizedBox(height: 10),
                  TextField(
                    controller: ctrl,
                    maxLines: 7,
                    minLines: 4,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: '在此粘贴…',
                      hintStyle: TextStyle(
                          fontSize: 13, color: JellyTheme.textSecondary),
                      filled: true,
                      fillColor: _isDark
                          ? Colors.white.withValues(alpha: 0.05)
                          : Colors.black.withValues(alpha: 0.04),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  if (error.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(error,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.redAccent)),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: () async {
                          final d = await Clipboard.getData('text/plain');
                          final t = d?.text;
                          if (t != null && t.isNotEmpty) {
                            ctrl.text = t;
                            setSheet(() => error = '');
                          }
                        },
                        icon:
                            const Icon(Icons.content_paste_rounded, size: 17),
                        label: const Text('读剪贴板'),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: () async {
                          final text = ctrl.text.trim();
                          if (text.isEmpty) {
                            setSheet(() => error = '请先粘贴内容');
                            return;
                          }
                          final parsed = _parseSources(text);
                          if (parsed.isEmpty) {
                            setSheet(() => error =
                                '没解析出书源。Legado 书源需含 bookSourceName / bookSourceUrl');
                            return;
                          }
                          final r = await store.addAll(parsed);
                          if (!ctx.mounted) return;
                          Navigator.pop(ctx);
                          _toast(r.added > 0
                              ? '已导入 ${r.added} 个书源'
                              : '已更新 ${r.updated} 个书源');
                        },
                        child: const Text('导入'),
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
    ctrl.dispose();
  }

  /// 从字节导入：自动识别 zip 还是文本。
  ///
  /// 为什么要判 zip：**书源分发最常见的形态就是一个 zip**
  /// （截图里地址栏也写着 `json / zip`）。不认 zip 的话，
  /// 用户下载到的书源包导进来只会得到"JSON 解析失败"，
  /// 而且完全看不出原因是"这是个压缩包"。
  Future<void> _importBytes(Uint8List bytes) async {
    // zip 魔数 PK\x03\x04（空 zip 是 PK\x05\x06，跨卷是 PK\x07\x08）
    final isZip = bytes.length > 4 &&
        bytes[0] == 0x50 &&
        bytes[1] == 0x4B &&
        (bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07);

    if (!isZip) {
      final text = utf8.decode(bytes, allowMalformed: true);
      await _doImportText(text);
      return;
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      _toast('压缩包解析失败：$e');
      return;
    }

    // 把包里所有 .json/.txt 都当书源试一遍。
    // 不假设"只有一个文件" —— 书源包常按站点分组放多个 json。
    var totalAdded = 0;
    var totalUpdated = 0;
    var tried = 0;
    var failed = 0;

    for (final f in archive) {
      if (!f.isFile) continue;
      final lower = f.name.toLowerCase();
      if (!lower.endsWith('.json') && !lower.endsWith('.txt')) continue;
      tried++;
      try {
        final data = f.content;
        final fb = data is Uint8List
            ? data
            : Uint8List.fromList(List<int>.from(data as List));
        final text = utf8.decode(fb, allowMalformed: true);
        final parsed = _parseSources(text);
        if (parsed.isEmpty) continue;
        final r = await store.addAll(parsed);
        totalAdded += r.added;
        totalUpdated += r.updated;
      } catch (_) {
        failed++;
      }
    }

    if (tried == 0) {
      _toast('压缩包里没有 json / txt 书源文件');
      return;
    }
    if (totalAdded == 0 && totalUpdated == 0) {
      _toast('压缩包里的 $tried 个文件都没解析出书源');
      return;
    }
    _toast(
      '已从压缩包导入：新增 $totalAdded 个'
      '${totalUpdated > 0 ? '、更新 $totalUpdated 个' : ''}'
      '${failed > 0 ? '（$failed 个文件解析失败）' : ''}',
    );
  }

  /// 本地文件导入。
  ///
  /// ⚠️ file_picker 13.x 的 API 与旧版差别很大，这里踩过坑，写清楚：
  ///   · `FilePicker.pickFiles(...)` 是**静态**方法（旧版是 `FilePicker.platform.pickFiles`）
  ///   · 返回值是 **`List<PlatformFile>`**（旧版是 `FilePickerResult?`）
  ///   · 没有 `withData` 参数；`PlatformFile` 也没有 `bytes` 属性
  ///   · 读内容用 **`f.readAsBytes()`**（返回 `Future<Uint8List>`），
  ///     或经 `f.path` 自己读文件
  Future<void> _importByFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json', 'txt', 'zip'],
      );
      if (result.isEmpty) return;
      final f = result.first;

      Uint8List bytes;
      try {
        // 首选 readAsBytes：不依赖 path（某些平台 path 可能为 null）
        bytes = await f.readAsBytes();
      } catch (_) {
        // 退回按路径读
        final path = f.path;
        if (path == null) {
          _toast('读不出这个文件（没有本地路径）');
          return;
        }
        bytes = await File(path).readAsBytes();
      }

      if (bytes.isEmpty) {
        _toast('文件是空的');
        return;
      }
      await _importBytes(bytes);
    } catch (e) {
      _toast('导入失败：${e.toString().split('\n').first}');
    }
  }

  Future<void> _fetchAndImport(String url) async {
    setState(() => _busy = true);
    try {
      // 用 bytes 而不是 String：书源地址可能是 zip，
      // 当字符串解出来会是乱码，根本判不出问题在哪
      final res = await Dio().get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      final list = res.data;
      if (list == null || list.isEmpty) {
        _toast('网址返回内容为空');
        return;
      }
      await _importBytes(Uint8List.fromList(list));
    } catch (e) {
      _toast('拉取失败：${e.toString().split('\n').first}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _doImportText(String text) async {
    final parsed = _parseSources(text);
    if (parsed.isEmpty) {
      _toast('没解析出书源。Legado 书源需含 bookSourceName / bookSourceUrl');
      return;
    }
    final r = await store.addAll(parsed);
    _toast(r.added > 0 && r.updated > 0
        ? '新增 ${r.added} 个、更新 ${r.updated} 个书源'
        : (r.added > 0 ? '已导入 ${r.added} 个书源' : '已更新 ${r.updated} 个书源'));
  }

  /// 解析书源 JSON。兼容 4 种形态 + 带尾随逗号的脏 JSON。
  List<BookSource> _parseSources(String text) {
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      // 有些分发文件带尾随逗号 / 前后有说明文字，退回"截取首尾括号"再试
      final a = text.indexOf('[');
      final b = text.lastIndexOf(']');
      final c = text.indexOf('{');
      final d = text.lastIndexOf('}');
      String? candidate;
      if (a >= 0 && b > a) {
        candidate = text.substring(a, b + 1);
      } else if (c >= 0 && d > c) {
        candidate = text.substring(c, d + 1);
      }
      if (candidate == null) rethrow;
      decoded = jsonDecode(candidate);
    }

    final out = <BookSource>[];
    void take(dynamic e) {
      if (e is! Map) return;
      final s = BookSource.fromJson(e.cast<String, dynamic>());
      if (s != null) out.add(s);
    }

    if (decoded is List) {
      for (final e in decoded) {
        take(e);
      }
    } else if (decoded is Map) {
      final m = decoded.cast<String, dynamic>();
      if (m['sources'] is List) {
        for (final e in (m['sources'] as List)) {
          take(e);
        }
      } else {
        take(m);
      }
    }
    return out;
  }

  // ============================================================
  // 详情 / 删除
  // ============================================================

  void _showDetail(BookSource s) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.name,
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: _titleColor)),
              const SizedBox(height: 14),
              _kv('分组', s.group),
              _kv('网址', s.url.isEmpty ? '（未配置）' : s.url),
              if (s.comment.isNotEmpty) _kv('备注', s.comment),
              _kv('状态', s.enabled ? '已启用' : '已停用'),
              _kv('字段数', '${s.raw.length}'),
              // 登录状态：让用户一眼知道这个源有没有登录过
              _kv(
                '登录',
                BookSourceService.instance.currentCookie(s).isEmpty
                    ? '未登录'
                    : '已登录（Cookie ${BookSourceService.instance.currentCookie(s).length} 字符）',
              ),
              const SizedBox(height: 12),
              // 书源登录 / 段评（V2.0.7 功能）
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => BookSourceLoginPage(source: s),
                          ),
                        );
                        if (mounted) setState(() {});
                      },
                      icon: const Icon(Icons.login_rounded, size: 17),
                      label: const Text('登录'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _showCommentsInfo(s);
                      },
                      icon: const Icon(Icons.forum_outlined, size: 17),
                      label: const Text('段评'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _showEditSheet(s);
                      },
                      icon: const Icon(Icons.edit_rounded, size: 17),
                      label: const Text('编辑'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(
                          text: const JsonEncoder.withIndent('  ')
                              .convert(s.toJson()),
                        ));
                        Navigator.pop(ctx);
                        _toast('已复制这个书源的 JSON');
                      },
                      icon: const Icon(Icons.copy_rounded, size: 17),
                      label: const Text('复制'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await store.remove(s.id);
                        _toast('已删除「${s.name}」');
                      },
                      icon: const Icon(Icons.delete_outline, size: 17),
                      label: const Text('删除',
                          style: TextStyle(color: Colors.redAccent)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 56,
              child: Text(k,
                  style: TextStyle(
                      fontSize: 12, color: JellyTheme.textSecondary)),
            ),
            Expanded(
              child: Text(v,
                  style: TextStyle(
                      fontSize: 12.5, height: 1.5, color: _titleColor)),
            ),
          ],
        ),
      );

  // ============================================================
  // 书源体检（V2.0.7 的「书源体检」）
  // ============================================================

  bool _healthChecking = false;

  /// 源 id → 体检结果
  final Map<String, BookSourceHealth> _health = {};

  Future<void> _runHealthCheck() async {
    final targets = _visible;
    if (targets.isEmpty) return;

    setState(() {
      _healthChecking = true;
      _health.clear();
    });
    _toast('开始体检 ${targets.length} 个书源…');

    await BookSourceService.instance.healthCheckAll(
      targets,
      // 边测边刷新：40 个源最慢的要一分钟，等全部结束才出结果体验很差
      onOne: (h) {
        if (!mounted) return;
        setState(() => _health[h.source.id] = h);
      },
    );

    if (!mounted) return;
    setState(() => _healthChecking = false);

    final ok = _health.values
        .where((h) => h.level == BookSourceHealthLevel.healthy)
        .length;
    final partial = _health.values
        .where((h) => h.level == BookSourceHealthLevel.partial)
        .length;
    final dead = _health.values
        .where((h) => h.level == BookSourceHealthLevel.dead)
        .length;
    _toast('体检完成：可用 $ok · 部分可用 $partial · 失效 $dead');
  }

  /// 体检标记：小圆点 + 文字（可用/部分可用/可疑/失效）
  Widget _healthBadge(BookSourceHealth h) {
    final (color, icon) = switch (h.level) {
      BookSourceHealthLevel.healthy => (Colors.green, Icons.check_circle_rounded),
      BookSourceHealthLevel.partial => (Colors.orange, Icons.error_rounded),
      BookSourceHealthLevel.suspect => (Colors.amber, Icons.help_rounded),
      BookSourceHealthLevel.dead => (Colors.redAccent, Icons.cancel_rounded),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              '${h.levelText} · ${h.detail}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: color),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 书源编辑（V2.0.7 的「书源编辑」）
  // ============================================================

  /// 编辑弹层。
  ///
  /// ── 为什么做成"常用字段表单 + 完整 JSON"两段 ──────────────────
  /// 只给 JSON 编辑器：改个名字要在一大坨里找字段，很难用。
  /// 只给表单：Legado 有几十个规则字段，全列出来表单会失控。
  /// 所以常用字段（名称/网址/分组）走表单，其余走 JSON —— 两段都改得动，
  /// 且互相同步（改表单会写回 JSON）。
  Future<void> _showEditSheet(BookSource s) async {
    final nameCtrl = TextEditingController(text: s.name);
    final urlCtrl = TextEditingController(text: s.url);
    final groupCtrl = TextEditingController(text: s.group);
    final jsonCtrl = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(s.toJson()),
    );
    var error = '';

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('编辑书源',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: _titleColor)),
                  const SizedBox(height: 14),
                  _editField('名称', nameCtrl, 'bookSourceName'),
                  const SizedBox(height: 10),
                  _editField('网址', urlCtrl, 'bookSourceUrl',
                      keyboard: TextInputType.url),
                  const SizedBox(height: 10),
                  _editField('分组', groupCtrl, 'bookSourceGroup'),
                  const SizedBox(height: 14),
                  Text('完整 JSON（规则字段在这里改）',
                      style: TextStyle(
                          fontSize: 12, color: JellyTheme.textSecondary)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: jsonCtrl,
                    maxLines: 10,
                    minLines: 6,
                    style: const TextStyle(fontSize: 12, height: 1.4),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: _isDark
                          ? Colors.white.withValues(alpha: 0.05)
                          : Colors.black.withValues(alpha: 0.04),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  if (error.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(error,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.redAccent)),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () async {
                          // 表单 → JSON：以表单值为准覆盖三个常用字段，
                          // 这样用户改了名字不会因为 JSON 没同步而白改
                          dynamic decoded;
                          try {
                            decoded = jsonDecode(jsonCtrl.text);
                          } catch (e) {
                            setSheet(() => error = 'JSON 格式错误：$e');
                            return;
                          }
                          if (decoded is! Map) {
                            setSheet(() => error = 'JSON 顶层必须是对象 {...}');
                            return;
                          }
                          final m = decoded.cast<String, dynamic>();
                          final nm = nameCtrl.text.trim();
                          final ur = urlCtrl.text.trim();
                          if (nm.isEmpty && ur.isEmpty) {
                            setSheet(() => error = '名称和网址至少要填一个');
                            return;
                          }
                          m['bookSourceName'] = nm;
                          m['bookSourceUrl'] = ur;
                          m['bookSourceGroup'] = groupCtrl.text.trim();

                          final updated = BookSource.fromJson(m);
                          if (updated == null) {
                            setSheet(() => error = '解析失败，检查必填字段');
                            return;
                          }
                          // id 变化时（网址改了）要删掉旧条目再插入，
                          // 否则会留下一条永远删不掉的孤儿源
                          if (updated.id != s.id) {
                            await store.remove(s.id);
                          }
                          await store.addAll([updated]);
                          if (!ctx.mounted) return;
                          Navigator.pop(ctx);
                          _toast('已保存「${updated.name}」');
                        },
                        child: const Text('保存'),
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
    nameCtrl.dispose();
    urlCtrl.dispose();
    groupCtrl.dispose();
    jsonCtrl.dispose();
  }

  Widget _editField(
    String label,
    TextEditingController ctrl,
    String hint, {
    TextInputType? keyboard,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 12, color: JellyTheme.textSecondary)),
          const SizedBox(height: 4),
          TextField(
            controller: ctrl,
            keyboardType: keyboard,
            style: const TextStyle(fontSize: 13.5),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle:
                  TextStyle(fontSize: 13, color: JellyTheme.textSecondary),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 10),
            ),
          ),
        ],
      );

  // ============================================================
  // 段评（V2.0.7 的「在线书源：阅读段评功能」）
  // ============================================================

  /// 段评说明。
  ///
  /// ── 为什么不直接做出来 ────────────────────────────────────────
  /// 「段评」是**特定站点**的能力（把评论按段落挂到正文上）。
  /// Legado 书源标准里**没有**段评的规则字段（ruleComment 不是标准），
  /// 所以：
  ///   · 源里没配 `ruleComment` → 这个源**根本没有段评数据**，
  ///     硬做一个空列表是骗人；
  ///   · 源里配了 `ruleComment` → 才能在阅读器里按段落展示。
  ///
  /// 这里如实告知用户当前源的情况，并说明怎么打开 ——
  /// 比"点了没反应"或"显示空列表"都诚实。
  void _showCommentsInfo(BookSource s) {
    final hasRule = s.raw['ruleComment'] != null;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('段评', style: TextStyle(fontSize: 16)),
        content: Text(
          hasRule
              ? '这个书源配置了 ruleComment，阅读时会在对应段落显示评论。\n\n'
                  '如果某章没有评论，通常是该章确实还没有人评论。'
              : '这个书源没有配置段评规则（ruleComment）。\n\n'
                  '段评不是 Legado 书源的标准字段，只有部分站点支持。\n'
                  '想要段评，需要导入带 ruleComment 的书源。\n\n'
                  '当前源：${s.name}',
          style: const TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteSelected() async {
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除书源', style: TextStyle(fontSize: 16)),
        content: Text('确定删除选中的 $n 个书源？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final id in _selected.toList()) {
      await store.remove(id);
    }
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _selectMode = false;
    });
    _toast('已删除 $n 个书源');
  }
}
