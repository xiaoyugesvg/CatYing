import 'package:flutter/material.dart';

import '../models/book_source.dart';
import '../models/source_subscription.dart';
import '../services/source_subscription_store.dart';
import '../source/manga_source.dart';
import '../source/source_manager.dart';
import '../theme/jelly_theme.dart';

/// 阅读模块的「书源仓 / 漫画仓」。
///
/// 用户 2026-10-17：
///   · 订阅链接要记录，和本地导入的源放在一起；
///   · 订阅一个加载一个、多个订阅全部加载并显示；
///   · 有专门的管理页，可更新/增删链接；
///   · 分类分组清楚（小说仓 / 漫画仓，仓内按 bookSourceGroup 分组）。
///
/// 数据关系：
///   · 链接记录 → [SourceSubscriptionStore]
///   · 源本体   → [BookSourceStore]（和"导入本地文件"共用同一份）
///   · 更新订阅 = 下载 JSON → 按类型过滤 → 写入 BookSourceStore
class SourceWarehousePage extends StatelessWidget {
  const SourceWarehousePage({super.key, this.startComic = false});

  final bool startComic;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: startComic ? 1 : 0,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text('书源仓 / 漫画仓'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '书源仓'),
              Tab(text: '漫画仓'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _WarehouseTab(comic: false),
            _WarehouseTab(comic: true),
          ],
        ),
      ),
    );
  }
}

class _WarehouseTab extends StatefulWidget {
  const _WarehouseTab({required this.comic});

  final bool comic;

  @override
  State<_WarehouseTab> createState() => _WarehouseTabState();
}

class _WarehouseTabState extends State<_WarehouseTab>
    with AutomaticKeepAliveClientMixin {
  final _subStore = SourceSubscriptionStore.instance;
  final _sourceStore = BookSourceStore.instance;
  final Set<String> _busy = {};
  bool _loading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _subStore.load().then((_) async {
      if (!mounted) return;
      setState(() => _loading = false);
      // 「订阅一个就加载」：首次进入时把还没成功加载过的启用订阅自动更新一轮。
      // 已经加载过的（count > 0）不重复下载，避免每次进页面都跑网络。
      final pending = _subs
          .where((s) => s.enabled && s.kind.supported && s.count == 0)
          .toList();
      for (final s in pending) {
        if (!mounted) return;
        await _update(s);
      }
    });
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  List<SourceSubscription> get _subs => _subStore.items.where((s) {
        return widget.comic ? s.kind.feedsComic : s.kind.feedsNovel;
      }).toList();

  List<BookSource> get _sources => _sourceStore.all
      .where((s) => widget.comic ? s.type == '2' : s.type != '2')
      .toList();

  /// Venera JS 源（直接跑 ComicSource 脚本，不进 BookSourceStore）
  List<MangaSource> get _veneraSources => widget.comic
      ? SourceManager()
          .sources
          .where((s) => s.id.startsWith('venera:'))
          .toList()
      : const [];

  Map<String, List<BookSource>> get _grouped {
    final map = <String, List<BookSource>>{};
    for (final s in _sources) {
      final g = s.group.trim().isEmpty ? '未分组' : s.group.trim();
      map.putIfAbsent(g, () => []).add(s);
    }
    for (final list in map.values) {
      list.sort((a, b) => a.name.compareTo(b.name));
    }
    return Map.fromEntries(
        map.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  }

  Future<void> _update(SourceSubscription s) async {
    if (_busy.contains(s.id)) return;
    setState(() => _busy.add(s.id));
    final r = await _subStore.update(s.id);
    if (!mounted) return;
    setState(() => _busy.remove(s.id));
    _toast(r.ok ? '${s.name}：${r.message}' : '${s.name}：${r.message}');
  }

  Future<void> _updateAll() async {
    if (_busy.isNotEmpty) return;
    final list = _subs.where((s) => s.enabled && s.kind.supported).toList();
    if (list.isEmpty) {
      _toast('没有可更新的订阅');
      return;
    }
    setState(() => _busy.add('__all__'));
    var ok = 0, failed = 0;
    for (final s in list) {
      final r = await _subStore.update(s.id);
      r.ok ? ok++ : failed++;
    }
    if (!mounted) return;
    setState(() => _busy.remove('__all__'));
    _toast('更新完成：成功 $ok 个，失败 $failed 个');
  }

  Future<void> _add() async {
    final nameCtl = TextEditingController();
    final urlCtl = TextEditingController();
    // 综合源对两个仓都有用，默认按当前仓选小说/漫画
    var kind = widget.comic
        ? SourceSubscriptionKind.comic
        : SourceSubscriptionKind.novel;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('添加订阅链接'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtl,
                  decoration: const InputDecoration(
                    labelText: '名称（可选）',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: urlCtl,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '订阅链接（JSON）',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<SourceSubscriptionKind>(
                  value: kind,
                  decoration: const InputDecoration(
                    labelText: '类型',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: SourceSubscriptionKind.values
                      .map((k) => DropdownMenuItem(
                            value: k,
                            child: Text(k.label),
                          ))
                      .toList(),
                  onChanged: (v) => setDlg(() => kind = v ?? kind),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final s = await _subStore.add(
      name: nameCtl.text,
      url: urlCtl.text,
      kind: kind,
    );
    if (!mounted) return;
    if (s == null) {
      _toast('链接不能为空');
      return;
    }
    setState(() {});
    await _update(s);
  }

  Future<void> _deleteSub(SourceSubscription s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除订阅链接？'),
        content: Text('只删除链接记录，已经导入的源仍保留。\n\n${s.name}'),
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
    await _subStore.remove(s.id);
    if (mounted) setState(() {});
  }

  Future<void> _deleteSource(BookSource s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这个源？'),
        content: Text('${s.name}\n\n会从源列表移除；下次更新订阅时会重新导入。'),
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
    await _sourceStore.remove(s.id);
    if (mounted) setState(() {});
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListenableBuilder(
      listenable: Listenable.merge([_subStore, SourceManager()]),
      builder: (context, _) => ValueListenableBuilder<int>(
        valueListenable: _sourceStore.revision,
        builder: (context, _, __) => _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    final grouped = _grouped;
    final totalSources = _sources.length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        // ── 订阅链接 ────────────────────────────────────────────
        _sectionHeader(
          '订阅链接（${_subs.length}）',
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: '全部更新',
                onPressed: _busy.isEmpty ? _updateAll : null,
                icon: _busy.contains('__all__')
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync_rounded, size: 20),
              ),
              IconButton(
                tooltip: '添加订阅',
                onPressed: _add,
                icon: const Icon(Icons.add_rounded, size: 20),
              ),
            ],
          ),
        ),
        if (_subs.isEmpty)
          _hint('还没有订阅链接，点右上角 + 添加')
        else
          for (final s in _subs) ...[
            _SubCard(
              sub: s,
              isDark: _isDark,
              busy: _busy.contains(s.id),
              onUpdate: () => _update(s),
              onDelete: () => _deleteSub(s),
              onToggle: (v) => _subStore.setEnabled(s.id, v),
            ),
            const SizedBox(height: 8),
          ],
        const SizedBox(height: 12),

        // ── 已导入源（按分组）──────────────────────────────────
        _sectionHeader('已导入源（$totalSources）'),
        if (totalSources == 0)
          _hint(widget.comic
              ? '还没有漫画源。更新上面的订阅，或从书源仓库导入。'
              : '还没有小说源。更新上面的订阅，或从书源仓库导入。')
        else
          for (final e in grouped.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 6),
              child: Row(
                children: [
                  Text(
                    e.key,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: _isDark
                          ? Colors.white
                          : JellyTheme.textPrimaryLight,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${e.value.length}',
                    style: TextStyle(
                        fontSize: 12, color: JellyTheme.textSecondary),
                  ),
                ],
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color: _isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < e.value.length; i++) ...[
                    if (i > 0)
                      Divider(
                        height: 1,
                        indent: 14,
                        endIndent: 14,
                        color: JellyTheme.textSecondary
                            .withValues(alpha: 0.12),
                      ),
                    _SourceRow(
                      source: e.value[i],
                      onToggle: (v) async {
                        await _sourceStore.setEnabled(e.value[i].id, v);
                        if (mounted) setState(() {});
                      },
                      onDelete: () => _deleteSource(e.value[i]),
                    ),
                  ],
                ],
              ),
            ),
          ],
        if (widget.comic && _veneraSources.isNotEmpty) ...[
          const SizedBox(height: 12),
          _sectionHeader('Venera 源（${_veneraSources.length}）'),
          Container(
            decoration: BoxDecoration(
              color: _isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                for (var i = 0; i < _veneraSources.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      indent: 14,
                      endIndent: 14,
                      color: JellyTheme.textSecondary.withValues(alpha: 0.12),
                    ),
                  SwitchListTile(
                    dense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 14),
                    title: Text(
                      _veneraSources[i].name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      'JS ComicSource · ${_veneraSources[i].id}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: JellyTheme.textSecondary),
                    ),
                    value: SourceManager().isEnabled(_veneraSources[i].id),
                    onChanged: (v) async {
                      await SourceManager().setEnabled(_veneraSources[i].id, v);
                      if (mounted) setState(() {});
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _sectionHeader(String text, {Widget? action}) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 0, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color:
                      _isDark ? Colors.white : JellyTheme.textPrimaryLight,
                ),
              ),
            ),
            if (action != null) action,
          ],
        ),
      );

  Widget _hint(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: JellyTheme.textSecondary),
        ),
      );
}

class _SubCard extends StatelessWidget {
  const _SubCard({
    required this.sub,
    required this.isDark,
    required this.busy,
    required this.onUpdate,
    required this.onDelete,
    required this.onToggle,
  });

  final SourceSubscription sub;
  final bool isDark;
  final bool busy;
  final VoidCallback onUpdate;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;

  String get _timeText {
    if (sub.lastUpdated <= 0) return '从未更新';
    final d = DateTime.fromMillisecondsSinceEpoch(sub.lastUpdated);
    String p(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final subColor = JellyTheme.textSecondary;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  sub.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: label),
                ),
              ),
              if (sub.builtin)
                _tag('内置', JellyTheme.primary),
              const SizedBox(width: 4),
              _tag(
                sub.kind == SourceSubscriptionKind.novel
                    ? '小说'
                    : sub.kind == SourceSubscriptionKind.comic
                        ? '漫画'
                        : sub.kind == SourceSubscriptionKind.legado
                            ? '综合'
                            : 'Venera',
                sub.kind == SourceSubscriptionKind.venera
                    ? Colors.redAccent
                    : Colors.blueAccent,
              ),
              Switch(value: sub.enabled, onChanged: onToggle),
            ],
          ),
          Text(
            sub.url,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: subColor),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${sub.count > 0 ? '${sub.count} 个源 · ' : ''}$_timeText',
                  style: TextStyle(fontSize: 12, color: subColor),
                ),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.all(10),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  tooltip: '更新',
                  icon: const Icon(Icons.sync_rounded, size: 20),
                  onPressed: onUpdate,
                ),
              IconButton(
                tooltip: '删除',
                icon: const Icon(Icons.delete_outline_rounded,
                    size: 20, color: Colors.redAccent),
                onPressed: onDelete,
              ),
            ],
          ),
          if (sub.lastError.isNotEmpty)
            Text(
              sub.lastError,
              style:
                  const TextStyle(fontSize: 12, color: Colors.orangeAccent),
            ),
        ],
      ),
    );
  }

  Widget _tag(String text, Color color) => Container(
        margin: const EdgeInsets.only(left: 4),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          text,
          style: TextStyle(
              fontSize: 10, color: color, fontWeight: FontWeight.w600),
        ),
      );
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    required this.source,
    required this.onToggle,
    required this.onDelete,
  });

  final BookSource source;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              source.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13.5,
                  color: source.enabled ? label : JellyTheme.textSecondary),
            ),
          ),
          Switch(
            value: source.enabled,
            onChanged: onToggle,
          ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.delete_outline_rounded,
                size: 19, color: Colors.redAccent),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
