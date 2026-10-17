import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../services/local_library_service.dart';
import '../theme/jelly_theme.dart';

/// 本地库管理：多库根 / 标签 / 查重 / 回收站。
class LocalLibraryPage extends StatefulWidget {
  const LocalLibraryPage({super.key});

  @override
  State<LocalLibraryPage> createState() => _LocalLibraryPageState();
}

class _LocalLibraryPageState extends State<LocalLibraryPage> {
  final _svc = LocalLibraryService.instance;
  LocalLibrarySnapshot? _snap;
  List<RecycleEntry> _recycle = const [];
  List<String> _tags = const [];
  Map<String, List<String>> _tagMap = const {};
  String? _tagFilter;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final snap = await _svc.scan();
      final recycle = await _svc.recycleEntries();
      final tags = await _svc.allTags();
      final tagMap = await _svc.tagMap();
      if (!mounted) return;
      setState(() {
        _snap = snap;
        _recycle = recycle;
        _tags = tags;
        _tagMap = tagMap;
        if (_tagFilter != null && !tags.contains(_tagFilter)) _tagFilter = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('扫描失败：$e');
    }
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _card => _isDark ? JellyTheme.cardDark : JellyTheme.cardLight;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: IconThemeData(color: AppTheme.textPrimary),
          title: Text(
            '本地库管理',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontTitle3,
            ),
          ),
          actions: [
            IconButton(
              tooltip: '重新扫描',
              onPressed: _loading ? null : _reload,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: '概览'),
              Tab(text: '查重'),
              Tab(text: '回收站'),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  _overviewTab(),
                  _duplicateTab(),
                  _recycleTab(),
                ],
              ),
      ),
    );
  }

  // ── 概览 ────────────────────────────────────────────────

  Widget _overviewTab() {
    final snap = _snap;
    if (snap == null) return const SizedBox.shrink();
    final books = _filter(snap.books);
    final comics = _filter(snap.comics);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              _metric('总占用', _svc.formatSize(snap.totalBytes)),
              _divider(),
              _metric('图书', '${snap.books.length} 个'),
              _divider(),
              _metric('漫画', '${snap.comics.length} 本'),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _sectionTitle('库根'),
        Container(
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              for (final root in snap.roots) ...[
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.folder_outlined, size: 20),
                  title: Text(
                    root,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: _isDark ? Colors.white : JellyTheme.textPrimaryLight,
                    ),
                  ),
                  trailing: snap.roots.length > 1
                      ? IconButton(
                          tooltip: '移除这个库根（不会删除文件）',
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () async {
                            await _svc.removeRoot(root);
                            await _reload();
                          },
                        )
                      : null,
                ),
                Divider(
                  height: 1,
                  indent: 14,
                  endIndent: 14,
                  color: JellyTheme.textSecondary.withValues(alpha: 0.12),
                ),
              ],
              ListTile(
                dense: true,
                leading: const Icon(Icons.add_rounded, size: 20),
                title: const Text('添加库根'),
                onTap: () async {
                  final p = await FilePicker.getDirectoryPath();
                  if (p == null || p.trim().isEmpty) return;
                  await _svc.addRoot(p);
                  await _reload();
                },
              ),
            ],
          ),
        ),
        if (_tags.isNotEmpty) ...[
          const SizedBox(height: 14),
          _sectionTitle('标签'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _tagChip('全部', _tagFilter == null, () {
                setState(() => _tagFilter = null);
              }),
              for (final t in _tags)
                _tagChip(t, _tagFilter == t, () {
                  setState(() => _tagFilter = t);
                }),
            ],
          ),
        ],
        const SizedBox(height: 14),
        _sectionTitle('图书（${books.length}）'),
        if (books.isEmpty)
          _hint('没有本地图书')
        else
          for (final b in books) _entryTile(b),
        const SizedBox(height: 14),
        _sectionTitle('漫画（${comics.length}）'),
        if (comics.isEmpty)
          _hint('没有本地漫画')
        else
          for (final c in comics) _entryTile(c),
      ],
    );
  }

  List<LocalLibraryEntry> _filter(List<LocalLibraryEntry> list) {
    if (_tagFilter == null) return list;
    return list
        .where((e) => (_tagMap[e.path] ?? const []).contains(_tagFilter))
        .toList();
  }

  Widget _entryTile(LocalLibraryEntry e) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: ListTile(
        dense: true,
        leading: Icon(
          e.isFolder ? Icons.collections_bookmark_outlined : Icons.menu_book_outlined,
          size: 20,
          color: JellyTheme.primary,
        ),
        title: Text(
          e.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppTheme.fontSubhead,
            color: _isDark ? Colors.white : JellyTheme.textPrimaryLight,
          ),
        ),
        subtitle: Text(
          [
            _svc.formatSize(e.sizeBytes),
            if (e.isFolder) '${e.itemCount} 张',
            if ((_tagMap[e.path] ?? const []).isNotEmpty)
              _tagMap[e.path]!.map((t) => '#$t').join(' '),
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            color: JellyTheme.textSecondary,
          ),
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'tag') {
              await _editTags(e);
            } else if (v == 'recycle') {
              await _confirmRecycle(e);
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'tag', child: Text('编辑标签')),
            PopupMenuItem(value: 'recycle', child: Text('移入回收站')),
          ],
        ),
      ),
    );
  }

  Future<void> _editTags(LocalLibraryEntry e) async {
    final current = await _svc.tagsOf(e.path);
    if (!mounted) return;
    final ctrl = TextEditingController(text: current.join(', '));
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑标签'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '多个标签用逗号分隔，如：已读, 收藏',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (r == null) return;
    await _svc.setTags(
      e.path,
      r.split(RegExp(r'[,，]')),
    );
    await _reload();
  }

  Future<void> _confirmRecycle(LocalLibraryEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移入回收站？'),
        content: Text('${e.name}\n\n文件会移到本地回收站，可随时恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('移入回收站'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _svc.moveToRecycle(e);
      await _reload();
      _toast('已移入回收站');
    } catch (err) {
      _toast('操作失败：$err');
    }
  }

  // ── 查重 ────────────────────────────────────────────────

  Widget _duplicateTab() {
    final snap = _snap;
    if (snap == null) return const SizedBox.shrink();
    final groups = [...snap.duplicateBooks, ...snap.duplicateComics];
    if (groups.isEmpty) {
      return Center(
        child: Text('没有发现重复文件',
            style: TextStyle(color: JellyTheme.textSecondary)),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        _hint('图书按「大小 + 前 64KB 哈希」判定；漫画按「标题 + 目录」判定。'
            '保留第一个，其余可一键移入回收站。'),
        const SizedBox(height: 10),
        for (final g in groups) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '重复 ${g.entries.length} 份',
                  style: TextStyle(
                    fontSize: AppTheme.fontCaption,
                    fontWeight: FontWeight.w700,
                    color: JellyTheme.primary,
                  ),
                ),
                const SizedBox(height: 6),
                for (var i = 0; i < g.entries.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            g.entries[i].name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              color: _isDark
                                  ? Colors.white
                                  : JellyTheme.textPrimaryLight,
                            ),
                          ),
                        ),
                        Text(
                          _svc.formatSize(g.entries[i].sizeBytes),
                          style: TextStyle(
                            fontSize: 11,
                            color: JellyTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () async {
                      for (final e in g.entries.skip(1)) {
                        await _svc.moveToRecycle(e);
                      }
                      await _reload();
                      _toast('已移入回收站 ${g.entries.length - 1} 份');
                    },
                    child: const Text('保留第一个，其余移入回收站'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // ── 回收站 ──────────────────────────────────────────────

  Widget _recycleTab() {
    if (_recycle.isEmpty) {
      return Center(
        child: Text('回收站是空的',
            style: TextStyle(color: JellyTheme.textSecondary)),
      );
    }
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            itemCount: _recycle.length,
            itemBuilder: (context, i) {
              final e = _recycle[i];
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: ListTile(
                  dense: true,
                  leading: Icon(
                    e.isFolder
                        ? Icons.collections_bookmark_outlined
                        : Icons.menu_book_outlined,
                    size: 20,
                    color: JellyTheme.textSecondary,
                  ),
                  title: Text(
                    e.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      color: _isDark ? Colors.white : JellyTheme.textPrimaryLight,
                    ),
                  ),
                  subtitle: Text(
                    '${_svc.formatSize(e.sizeBytes)} · ${_dateText(e.deletedAtMs)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: JellyTheme.textSecondary,
                    ),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '恢复',
                        icon: const Icon(Icons.restore_rounded, size: 20),
                        onPressed: () async {
                          final ok = await _svc.restore(e);
                          await _reload();
                          _toast(ok ? '已恢复' : '恢复失败（原路径不可写）');
                        },
                      ),
                      IconButton(
                        tooltip: '彻底删除',
                        icon: const Icon(Icons.delete_forever_rounded,
                            size: 20, color: Colors.redAccent),
                        onPressed: () async {
                          await _svc.purge(e);
                          await _reload();
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SizedBox(
              width: double.infinity,
              height: 42,
              child: OutlinedButton(
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('清空回收站？'),
                      content: const Text('所有条目将被彻底删除，无法恢复。'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('取消'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          style: TextButton.styleFrom(
                              foregroundColor: Colors.redAccent),
                          child: const Text('清空'),
                        ),
                      ],
                    ),
                  );
                  if (ok != true) return;
                  await _svc.emptyRecycle();
                  await _reload();
                },
                child: const Text('清空回收站'),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── 小部件 ──────────────────────────────────────────────

  Widget _metric(String label, String value) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: _isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: JellyTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() => Container(
        width: 0.5,
        height: 26,
        color: JellyTheme.textSecondary.withValues(alpha: 0.2),
      );

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: JellyTheme.textSecondary,
          ),
        ),
      );

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            height: 1.5,
            color: JellyTheme.textSecondary,
          ),
        ),
      );

  Widget _tagChip(String text, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? JellyTheme.primary
              : JellyTheme.primary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? Colors.white : JellyTheme.primary,
          ),
        ),
      ),
    );
  }

  String _dateText(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}.${d.month}.${d.day}';
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
  }
}
