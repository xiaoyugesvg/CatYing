import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../common/theme.dart';
import '../models/book_source.dart';
import '../models/source_subscription.dart';
import '../services/source_subscription_store.dart';
import '../source/manga_source.dart';
import '../source/source_manager.dart';
import '../theme/jelly_theme.dart';

/// 阅读模块的「书源仓 / 漫画仓」（两个独立页面，不再用 Tab 合并）。
///
/// 入口（用户 2026-10-18）：
///   · 书源仓   ← 书源仓库右上角图标
///   · 漫画仓   ← 漫画源仓库右上角图标
/// 不再放在「我的」页的菜单里。
///
/// 版式（用户 2026-10-18 改版）：
///   1. 顶部订阅卡片（第一张永远是「添加订阅」）；
///   2. 下面一行订阅 tab + 排序 / 视图切换按钮；
///   3. 内容区只显示当前 tab 对应的源。
///
/// 数据关系：
///   · 链接记录 → [SourceSubscriptionStore]（含 updateHours / sourceIds）
///   · 源本体   → [BookSourceStore]（和"导入本地文件"共用同一份）
///   · 更新订阅 = 下载 JSON → 按类型过滤 → 写入 BookSourceStore
class SourceWarehousePage extends StatelessWidget {
  const SourceWarehousePage({super.key, this.comic = false});

  /// true = 漫画仓；false = 书源仓
  final bool comic;

  @override
  Widget build(BuildContext context) {
    return _WarehouseTab(comic: comic);
  }
}

/// 排序方式（订阅 tab 右侧的排序按钮）
enum _SortMode {
  normal('默认顺序'),
  nameAsc('名称 A → Z'),
  nameDesc('名称 Z → A');

  const _SortMode(this.label);
  final String label;
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

  /// 当前选中的订阅 tab：null = 「全部」
  String? _selectedSubId;

  /// 排序 & 视图（列表 / 网格）
  _SortMode _sort = _SortMode.normal;
  bool _grid = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _subStore.load().then((_) async {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (_selectedSubId == null && _subs.isNotEmpty) {
          _selectedSubId = _subs.first.id;
        }
      });
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
  Color get _label => _isDark ? Colors.white : JellyTheme.textPrimaryLight;
  Color get _card => _isDark ? JellyTheme.cardDark : JellyTheme.cardLight;

  List<SourceSubscription> get _subs => _subStore.items.where((s) {
    return widget.comic ? s.kind.feedsComic : s.kind.feedsNovel;
  }).toList();

  SourceSubscription? get _selectedSub {
    final id = _selectedSubId;
    if (id == null) return null;
    for (final s in _subs) {
      if (s.id == id) return s;
    }
    return null;
  }

  // 判据统一用 isComicSource（兼容没写 bookSourceType 的漫画脚本），
  // 保证「漫画仓」与「书源仓」不混（用户 2026-10-18）。
  List<BookSource> get _allSources => _sourceStore.all
      .where((s) => widget.comic ? s.isComicSource : !s.isComicSource)
      .toList();

  /// Venera JS 源（直接跑 ComicSource 脚本，不进 BookSourceStore）
  List<MangaSource> get _allVenera => widget.comic
      ? SourceManager().sources
            .where((s) => s.id.startsWith('venera:'))
            .toList()
      : const [];

  /// 当前 tab 的源：选了订阅就只显示这条订阅导入的（sourceIds）
  List<BookSource> get _tabSources {
    final sub = _selectedSub;
    if (sub == null) return _allSources;
    final ids = sub.sourceIds.toSet();
    if (ids.isEmpty) return const [];
    return _allSources.where((s) => ids.contains(s.id)).toList();
  }

  List<MangaSource> get _tabVenera {
    final sub = _selectedSub;
    if (sub == null) return _allVenera;
    if (sub.kind != SourceSubscriptionKind.venera) return const [];
    final ids = sub.sourceIds.toSet();
    if (ids.isEmpty) return const [];
    return _allVenera.where((s) => ids.contains(s.id)).toList();
  }

  List<BookSource> get _sortedSources {
    final l = List<BookSource>.from(_tabSources);
    switch (_sort) {
      case _SortMode.normal:
        break;
      case _SortMode.nameAsc:
        l.sort((a, b) => a.name.compareTo(b.name));
      case _SortMode.nameDesc:
        l.sort((a, b) => b.name.compareTo(a.name));
    }
    return l;
  }

  // ── 更新 / 删除 ──────────────────────────────────────────

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

  Future<void> _copyLink(SourceSubscription s) async {
    await Clipboard.setData(ClipboardData(text: s.url));
    _toast('已复制订阅链接');
  }

  Future<void> _deleteSub(SourceSubscription s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除订阅？'),
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
    if (!mounted) return;
    if (_selectedSubId == s.id) {
      setState(() => _selectedSubId = _subs.isEmpty ? null : _subs.first.id);
    }
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

  // ── 添加订阅 ─────────────────────────────────────────────

  static const _intervals = <(int, String)>[
    (0, '手动更新'),
    (6, '每 6 小时'),
    (12, '每 12 小时'),
    (24, '每天'),
    (72, '每 3 天'),
    (168, '每 7 天'),
  ];

  Future<void> _add() async {
    final nameCtl = TextEditingController();
    final urlCtl = TextEditingController();
    var hours = 24;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: _card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          title: Text(
            '添加订阅',
            style: TextStyle(
              color: _label,
              fontSize: AppTheme.fontHeadline,
              fontWeight: FontWeight.w700,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtl,
                  style: TextStyle(color: _label, fontSize: 14),
                  decoration: _inputDeco('订阅名称（留空用域名）'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: urlCtl,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  style: TextStyle(color: _label, fontSize: 13),
                  decoration: _inputDeco('订阅链接（JSON / 仓库索引）'),
                ),
                const SizedBox(height: 12),
                Text(
                  '自动更新',
                  style: TextStyle(
                    color: JellyTheme.textSecondary,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 6),
                DropdownButtonFormField<int>(
                  initialValue: hours,
                  decoration: _inputDeco(''),
                  items: [
                    for (final o in _intervals)
                      DropdownMenuItem(value: o.$1, child: Text(o.$2)),
                  ],
                  onChanged: (v) => setDlg(() => hours = v ?? hours),
                ),
                const SizedBox(height: 10),
                Text(
                  '订阅一次就会加载一次，源会全部保存；重名时可选择替换或加序号。',
                  style: TextStyle(
                    color: JellyTheme.textSecondary,
                    fontSize: 11,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;

    final url = urlCtl.text.trim();
    if (url.isEmpty) {
      _toast('订阅链接不能为空');
      return;
    }
    var name = nameCtl.text.trim();
    if (name.isEmpty) name = Uri.tryParse(url)?.host ?? url;

    // Venera 的 index.json 只在漫画仓识别；其余按综合源处理（两个仓都能用）
    final lower = url.toLowerCase();
    final kind = widget.comic && lower.contains('venera')
        ? SourceSubscriptionKind.venera
        : SourceSubscriptionKind.legado;

    // 同一个链接已存在 → 直接更新这条，避免重复记录
    final sameUrl = _subStore.items.where((e) => e.url == url).firstOrNull;
    if (sameUrl != null) {
      await _subStore.updateSubscription(
        sameUrl.id,
        name: name,
        url: url,
        kind: kind,
        updateHours: hours,
      );
      if (!mounted) return;
      setState(() => _selectedSubId = sameUrl.id);
      await _update(_subStore.items.firstWhere((e) => e.id == sameUrl.id));
      return;
    }

    // 名称重复 → 弹窗让用户选「替换」还是「加序号」
    SourceSubscription? replaceTarget;
    final dup = _subStore.items.where((e) => e.name == name).toList();
    if (dup.isNotEmpty) {
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _card,
          title: Text('订阅名称重复', style: TextStyle(color: _label)),
          content: Text(
            '已经有名为「$name」的订阅。\n要替换它，还是给新订阅加个序号？',
            style: TextStyle(
              color: JellyTheme.textSecondary,
              height: 1.55,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'number'),
              child: const Text('加序号'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'replace'),
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text('替换'),
            ),
          ],
        ),
      );
      if (choice == null || !mounted) return;
      if (choice == 'replace') {
        replaceTarget = dup.first;
      } else {
        name = _numberedName(name);
      }
    }

    SourceSubscription? sub;
    if (replaceTarget != null) {
      await _subStore.updateSubscription(
        replaceTarget.id,
        name: name,
        url: url,
        kind: kind,
        updateHours: hours,
      );
      sub = _subStore.items.firstWhere((e) => e.id == replaceTarget!.id);
    } else {
      sub = await _subStore.add(
        name: name,
        url: url,
        kind: kind,
        updateHours: hours,
      );
    }
    if (sub == null || !mounted) return;
    setState(() => _selectedSubId = sub!.id);
    await _update(sub);
  }

  /// 「名称 (2)」→「名称 (3)」…，直到不重复
  String _numberedName(String base) {
    var n = 2;
    var name = '$base ($n)';
    final used = _subStore.items.map((e) => e.name).toSet();
    while (used.contains(name)) {
      n++;
      name = '$base ($n)';
    }
    return name;
  }

  InputDecoration _inputDeco(String hint) => InputDecoration(
    hintText: hint.isEmpty ? null : hint,
    hintStyle: TextStyle(color: JellyTheme.textSecondary, fontSize: 12.5),
    isDense: true,
    filled: true,
    fillColor: _isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.04),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
  );

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  // ── UI ──────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final titleColor = _isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: titleColor),
        title: Text(
          widget.comic ? '漫画仓' : '书源仓',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: titleColor,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '全部更新',
            onPressed: _busy.isEmpty ? _updateAll : null,
            icon: _busy.contains('__all__')
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync_rounded),
          ),
          IconButton(
            tooltip: '添加订阅',
            onPressed: _add,
            icon: const Icon(Icons.add_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListenableBuilder(
              listenable: Listenable.merge([_subStore, SourceManager()]),
              builder: (context, _) => ValueListenableBuilder<int>(
                valueListenable: _sourceStore.revision,
                builder: (context, _, _) => _buildBody(),
              ),
            ),
    );
  }

  Widget _buildBody() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        _subCards(),
        const SizedBox(height: 8),
        _tabsRow(),
        const SizedBox(height: 4),
        Expanded(child: _content()),
      ],
    );
  }

  /// 顶部订阅卡片：第一张是「添加订阅」，后面每条订阅一张
  Widget _subCards() {
    return SizedBox(
      height: 150,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        children: [
          _addSubCard(),
          for (final s in _subs) ...[
            const SizedBox(width: 10),
            _subCard(s),
          ],
        ],
      ),
    );
  }

  Widget _addSubCard() {
    return GestureDetector(
      onTap: _add,
      child: Container(
        width: 128,
        decoration: BoxDecoration(
          color: JellyTheme.primary.withValues(alpha: _isDark ? 0.10 : 0.06),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: JellyTheme.primary.withValues(alpha: 0.35),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: JellyTheme.primary.withValues(alpha: 0.16),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.add_rounded, color: JellyTheme.primary),
            ),
            const SizedBox(height: 10),
            Text(
              '添加订阅',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: _label,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _subCard(SourceSubscription s) {
    final active = s.id == _selectedSubId;
    final busy = _busy.contains(s.id);
    return GestureDetector(
      onTap: () => setState(() => _selectedSubId = s.id),
      child: Container(
        width: 232,
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
        decoration: BoxDecoration(
          color: active
              ? JellyTheme.primary.withValues(alpha: _isDark ? 0.16 : 0.10)
              : _card,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: active
                ? JellyTheme.primary.withValues(alpha: 0.45)
                : Colors.transparent,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    s.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: _label,
                    ),
                  ),
                ),
                Transform.scale(
                  scale: 0.72,
                  child: Switch(
                    value: s.enabled,
                    onChanged: (v) => _subStore.setEnabled(s.id, v),
                  ),
                ),
              ],
            ),
            Text(
              '${s.count} 个源 · ${_timeText(s.lastUpdated)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: JellyTheme.textSecondary,
              ),
            ),
            const Spacer(),
            Row(
              children: [
                if (busy)
                  const SizedBox(
                    width: 30,
                    height: 30,
                    child: Center(
                      child: SizedBox(
                        width: 15,
                        height: 15,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                else
                  _cardBtn(Icons.sync_rounded, '刷新', () => _update(s)),
                _cardBtn(
                  Icons.copy_rounded,
                  '复制链接',
                  () => _copyLink(s),
                ),
                const Spacer(),
                _cardBtn(
                  Icons.delete_outline_rounded,
                  '删除',
                  () => _deleteSub(s),
                  danger: true,
                ),
              ],
            ),
            if (s.lastError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  s.lastError,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: Colors.orangeAccent,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _cardBtn(
    IconData icon,
    String tip,
    VoidCallback onTap, {
    bool danger = false,
  }) {
    return Tooltip(
      message: tip,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            icon,
            size: 17,
            color: danger ? Colors.redAccent : JellyTheme.textSecondary,
          ),
        ),
      ),
    );
  }

  String _timeText(int ms) {
    if (ms <= 0) return '从未更新';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String p(int n) => n.toString().padLeft(2, '0');
    return '${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }

  /// tab 行：订阅名 + 右侧排序 / 视图切换
  Widget _tabsRow() {
    final tabs = <(String?, String)>[
      (null, '全部'),
      for (final s in _subs) (s.id, s.name),
    ];
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              children: [
                for (final t in tabs) ...[
                  _tabChip(t.$2, _selectedSubId == t.$1, () {
                    setState(() => _selectedSubId = t.$1);
                  }),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          PopupMenuButton<_SortMode>(
            tooltip: '排序',
            initialValue: _sort,
            color: _isDark ? JellyTheme.cardDark : Colors.white,
            onSelected: (v) => setState(() => _sort = v),
            itemBuilder: (_) => [
              for (final v in _SortMode.values)
                PopupMenuItem(
                  value: v,
                  child: Row(
                    children: [
                      Icon(
                        v == _sort ? Icons.check_rounded : Icons.sort_rounded,
                        size: 17,
                      ),
                      const SizedBox(width: 8),
                      Text(v.label, style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(
                Icons.sort_rounded,
                size: 20,
                color: JellyTheme.textSecondary,
              ),
            ),
          ),
          IconButton(
            tooltip: _grid ? '切换为列表' : '切换为网格',
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _grid = !_grid),
            icon: Icon(
              _grid ? Icons.view_list_rounded : Icons.grid_view_rounded,
              size: 20,
              color: JellyTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabChip(String label, bool on, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on
              ? JellyTheme.primary
              : (_isDark
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.black.withValues(alpha: 0.04)),
          borderRadius: BorderRadius.circular(19),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: on ? FontWeight.w700 : FontWeight.w500,
            color: on ? Colors.white : JellyTheme.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _content() {
    final sources = _sortedSources;
    final venera = _tabVenera;
    if (sources.isEmpty && venera.isEmpty) {
      return _emptyHint();
    }
    if (_grid && sources.isNotEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
        children: [
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 2.25,
            ),
            itemCount: sources.length,
            itemBuilder: (_, i) => _sourceGridCard(sources[i]),
          ),
          if (venera.isNotEmpty) ...[
            const SizedBox(height: 16),
            _veneraHeader(venera.length),
            const SizedBox(height: 8),
            _veneraList(venera),
          ],
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
      children: [
        if (sources.isNotEmpty)
          Container(
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                for (var i = 0; i < sources.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      indent: 14,
                      endIndent: 14,
                      color: JellyTheme.textSecondary.withValues(alpha: 0.12),
                    ),
                  _SourceRow(
                    source: sources[i],
                    onToggle: (v) async {
                      await _sourceStore.setEnabled(sources[i].id, v);
                      if (mounted) setState(() {});
                    },
                    onDelete: () => _deleteSource(sources[i]),
                  ),
                ],
              ],
            ),
          ),
        if (venera.isNotEmpty) ...[
          const SizedBox(height: 16),
          _veneraHeader(venera.length),
          const SizedBox(height: 8),
          _veneraList(venera),
        ],
      ],
    );
  }

  Widget _emptyHint() {
    final sub = _selectedSub;
    final text = sub == null
        ? (widget.comic
              ? '还没有漫画源。点上方「添加订阅」，或从漫画源仓库导入。'
              : '还没有小说源。点上方「添加订阅」，或从书源仓库导入。')
        : (sub.count == 0
              ? '「${sub.name}」还没有加载过，点卡片上的刷新按钮拉取。'
              : '「${sub.name}」没有可显示的源，点刷新重新拉取。');
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.inbox_outlined,
              size: 44,
              color: JellyTheme.textSecondary.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.55,
                color: JellyTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sourceGridCard(BookSource s) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                widget.comic
                    ? Icons.collections_bookmark_rounded
                    : Icons.auto_stories_rounded,
                size: 16,
                color: s.enabled
                    ? JellyTheme.primary
                    : JellyTheme.textSecondary.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  s.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: s.enabled ? _label : JellyTheme.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const Spacer(),
          Row(
            children: [
              Expanded(
                child: Text(
                  s.group.trim().isEmpty ? '未分组' : s.group.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ),
              Transform.scale(
                scale: 0.66,
                child: Switch(
                  value: s.enabled,
                  onChanged: (v) async {
                    await _sourceStore.setEnabled(s.id, v);
                    if (mounted) setState(() {});
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _veneraHeader(int count) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Text(
      'Venera 源（$count）',
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: _label,
      ),
    ),
  );

  Widget _veneraList(List<MangaSource> list) {
    return Container(
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          for (var i = 0; i < list.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                indent: 14,
                endIndent: 14,
                color: JellyTheme.textSecondary.withValues(alpha: 0.12),
              ),
            SwitchListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14),
              title: Text(
                list[i].name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                'JS ComicSource · ${list[i].id}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: JellyTheme.textSecondary,
                ),
              ),
              value: SourceManager().isEnabled(list[i].id),
              onChanged: (v) async {
                await SourceManager().setEnabled(list[i].id, v);
                if (mounted) setState(() {});
              },
            ),
          ],
        ],
      ),
    );
  }
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
          Icon(
            Icons.auto_stories_rounded,
            size: 16,
            color: source.enabled
                ? JellyTheme.primary.withValues(alpha: 0.85)
                : JellyTheme.textSecondary.withValues(alpha: 0.5),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  source.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: source.enabled ? label : JellyTheme.textSecondary,
                  ),
                ),
                Text(
                  source.group.trim().isEmpty ? '未分组' : source.group.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: JellyTheme.textSecondary.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: source.enabled,
            onChanged: onToggle,
          ),
          IconButton(
            tooltip: '删除',
            icon: const Icon(
              Icons.delete_outline_rounded,
              size: 19,
              color: Colors.redAccent,
            ),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
