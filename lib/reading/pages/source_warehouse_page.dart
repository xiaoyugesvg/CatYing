import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../common/theme.dart';
import '../models/book_source.dart';
import '../models/source_subscription.dart';
import '../services/source_subscription_store.dart';
import '../source/manga_source.dart';
import '../source/source_config_store.dart';
import '../source/source_definition.dart';
import '../source/source_manager.dart';
import '../theme/jelly_theme.dart';
import '../widgets/swipe_action_tile.dart';
import 'book_source_editor_page.dart';
import 'comic_source_edit_page.dart';

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

/// 排序方式（与全站其它排序菜单统一为：时间 / 名称 / 频率）
enum _SortMode {
  custom('自定义顺序'),
  time('时间'),
  name('名称'),
  frequency('频率');

  const _SortMode(this.label);
  final String label;
}

/// 视图：列表 / 卡片 / 网格 / 一行 2·3·4 个
enum _ViewMode {
  list('列表', Icons.view_list_rounded, 1),
  card('卡片', Icons.view_agenda_rounded, 1),
  grid('网格', Icons.grid_view_rounded, 2),
  two('一行两个', Icons.apps_rounded, 2),
  three('一行三个', Icons.view_module_rounded, 3),
  four('一行四个', Icons.grid_on_rounded, 4);

  const _ViewMode(this.label, this.icon, this.columns);
  final String label;
  final IconData icon;
  final int columns;

  bool get isList => this == _ViewMode.list;
  bool get isCard => this == _ViewMode.card;
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

  /// 排序 & 视图（列表 / 卡片 / 网格 / 一行 2·3·4）
  _SortMode _sort = _SortMode.custom;
  _ViewMode _view = _ViewMode.list;

  /// 多选：长按条目进入；勾选后底部出现操作栏
  bool _selectMode = false;
  final Set<String> _picked = <String>{};

  String get _viewKey => widget.comic
      ? 'reading_warehouse_view_comic'
      : 'reading_warehouse_view_book';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _restoreView();
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
      final sp = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      final pending = _subs
          .where((s) => s.enabled && s.kind.supported && s.count == 0)
          .toList();
      for (final s in pending) {
        if (!mounted) return;
        // 2 分钟冷却：源不可达时 count 会一直是 0，如果没有冷却，
        // 每次进页面都会重新下载并卡很久。
        final k = 'reading_sub_init_${s.id}';
        final last = sp.getInt(k) ?? 0;
        if (now - last < 2 * 60 * 1000) continue;
        await sp.setInt(k, now);
        await _update(s);
      }
      // 旧版本把源记错仓（或 sourceIds 指向已清理的条目）⇒ 自动重拉一次，
      // 否则 tab 里会显示"没有可显示的源"。
      //
      // ⚠️ 必须先等书源仓 / SourceManager 加载完再判断，否则 Venera / 配置源
      //    还没注册 ⇒ 被误判成"sourceIds 失效"，每次进页面都重下 33 个脚本。
      if (_sourceStore.isEmpty) await _sourceStore.init();
      if (!SourceManager().isReady) {
        await SourceManager().init(fetchCloud: false);
      }
      if (!mounted) return;
      final broken = _subs
          .where((s) => s.enabled && s.count > 0 && !_idsResolvable(s))
          .toList();
      if (broken.isNotEmpty) {
        // 10 分钟冷却：同一个订阅自动重拉失败后不要每次进页面都跑网络
        for (final s in broken) {
          if (!mounted) return;
          final k = 'reading_sub_autotime_${s.id}';
          final last = sp.getInt(k) ?? 0;
          if (now - last < 10 * 60 * 1000) continue;
          await sp.setInt(k, now);
          await _update(s);
        }
      }
    });
  }

  bool _idsResolvable(SourceSubscription s) {
    if (s.sourceIds.isEmpty) return false;
    final bookIds = _allSources.map((e) => e.id).toSet();
    final mangaIds = SourceManager().sources.map((e) => e.id).toSet();
    return s.sourceIds.any(
      (id) => bookIds.contains(id) || mangaIds.contains(id),
    );
  }

  Future<void> _restoreView() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final i = sp.getInt(_viewKey);
      if (i != null && i >= 0 && i < _ViewMode.values.length && mounted) {
        setState(() => _view = _ViewMode.values[i]);
      }
    } catch (_) {}
  }

  Future<void> _setViewMode(_ViewMode v) async {
    setState(() => _view = v);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_viewKey, v.index);
    } catch (_) {}
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _label => _isDark ? Colors.white : JellyTheme.textPrimaryLight;
  Color get _card => _isDark ? JellyTheme.cardDark : JellyTheme.cardLight;

  List<SourceSubscription> get _subs => _subStore.items.where((s) {
    return widget.comic ? s.kind.feedsComic : s.kind.feedsNovel;
  }).toList();

  /// 订阅卡片 / tab 的展示顺序（时间 / 名称 / 频率）
  List<SourceSubscription> get _sortedSubs {
    final l = List<SourceSubscription>.from(_subs);
    switch (_sort) {
      case _SortMode.custom:
        break;
      case _SortMode.time:
        l.sort((a, b) => b.lastUpdated.compareTo(a.lastUpdated));
        break;
      case _SortMode.name:
        l.sort((a, b) => a.name.compareTo(b.name));
        break;
      case _SortMode.frequency:
        l.sort((a, b) => b.count.compareTo(a.count));
        break;
    }
    return l;
  }

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

  /// 配置 / API 漫画源（来自 SourceConfigStore，不进 BookSourceStore）
  List<MangaSource> get _allConfigApi => widget.comic
      ? SourceManager().sources
            .where(
              (s) => !s.id.startsWith('venera:') && !s.id.startsWith('legado:'),
            )
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

  List<MangaSource> get _tabConfig {
    final sub = _selectedSub;
    if (sub == null) return _allConfigApi;
    final ids = sub.sourceIds.toSet();
    if (ids.isEmpty) return const [];
    return _allConfigApi.where((s) => ids.contains(s.id)).toList();
  }

  List<BookSource> get _sortedSources {
    final l = List<BookSource>.from(_tabSources);
    switch (_sort) {
      case _SortMode.custom:
      case _SortMode.time:
        break;
      case _SortMode.name:
        l.sort((a, b) => a.name.compareTo(b.name));
        break;
      case _SortMode.frequency:
        // 没有逐源的使用计数：用「启用优先」近似"常用在前"
        l.sort((a, b) {
          if (a.enabled != b.enabled) return a.enabled ? -1 : 1;
          return a.name.compareTo(b.name);
        });
        break;
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

    // Venera 索引属于漫画仓；书源仓加了也不会显示，直接拦住并说明
    final lower = url.toLowerCase();
    if (!widget.comic && lower.contains('venera')) {
      _toast('这是 Venera 漫画源，请在「漫画仓」添加');
      return;
    }
    // 两个仓彻底分开：漫画仓的订阅只喂漫画仓，书源仓只喂书源仓。
    // 只有 Venera 的 index.json 需要单独识别。
    final kind = widget.comic
        ? (lower.contains('venera')
              ? SourceSubscriptionKind.venera
              : SourceSubscriptionKind.comic)
        : SourceSubscriptionKind.novel;

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

  // ── 多选 / 源操作 ───────────────────────────────────────

  List<String> get _visibleIds => [
    for (final s in _sortedSources) s.id,
    for (final s in _tabConfig) s.id,
    for (final s in _tabVenera) s.id,
  ];

  bool get _allPicked {
    final ids = _visibleIds;
    return ids.isNotEmpty && ids.every(_picked.contains);
  }

  void _togglePick(String id) {
    setState(() {
      if (!_picked.remove(id)) _picked.add(id);
      if (_picked.isEmpty) _selectMode = false;
    });
  }

  void _enterSelect(String id) {
    setState(() {
      _selectMode = true;
      _picked.add(id);
    });
  }

  void _exitSelect() {
    setState(() {
      _selectMode = false;
      _picked.clear();
    });
  }

  Future<void> _toggleAll() async {
    if (_allPicked) {
      _exitSelect();
      return;
    }
    setState(() {
      _selectMode = true;
      _picked
        ..clear()
        ..addAll(_visibleIds);
    });
  }

  Future<void> _editEntry(String id) async {
    final books = _sourceStore.all.where((e) => e.id == id).toList();
    if (books.isNotEmpty) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => BookSourceEditorPage(source: books.first),
        ),
      );
      if (!mounted) return;
      await _sourceStore.init();
      if (mounted) setState(() {});
      return;
    }
    final defs = await SourceConfigStore().loadLocal();
    final hit = defs.where((d) => d.id == id).toList();
    if (hit.isEmpty) {
      _toast('找不到该源配置（可能来自旧缓存）');
      return;
    }
    final def = hit.first;
    if (def.type == 'venera') {
      _toast('Venera 源通过「更新订阅」维护，不能单独编辑');
      return;
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ComicSourceEditPage(definition: def),
      ),
    );
    if (!mounted) return;
    await SourceManager().reload();
    if (mounted) setState(() {});
  }

  Future<void> _shareIds(List<String> ids) async {
    if (ids.isEmpty) return;
    final books = _sourceStore.all.where((s) => ids.contains(s.id)).toList();
    final defsAll = await SourceConfigStore().loadLocal();
    final defs = defsAll.where((d) => ids.contains(d.id)).toList();
    if (books.isEmpty && defs.isEmpty) {
      _toast('没有可分享的源');
      return;
    }
    Object payload;
    if (books.isNotEmpty && defs.isEmpty) {
      payload = books.map((b) => b.raw).toList();
    } else if (books.isEmpty) {
      payload = SourceConfigFile(version: 1, sources: defs).toJson();
    } else {
      payload = {
        'bookSources': books.map((b) => b.raw).toList(),
        'sources': SourceConfigFile(
          version: 1,
          sources: defs,
        ).toJson()['sources'],
      };
    }
    final text = const JsonEncoder.withIndent('  ').convert(payload);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _toast('已复制 ${ids.length} 个源，可粘贴导入');
  }

  Future<void> _deleteIds(List<String> ids) async {
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 ${ids.length} 个源？'),
        content: const Text('删除后需要重新导入；订阅下次更新时会再次导入。'),
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
    await _deleteNow(ids);
  }

  Future<void> _deleteNow(List<String> ids) async {
    final bookIds = <String>[];
    for (final id in ids) {
      if (_sourceStore.all.any((e) => e.id == id)) bookIds.add(id);
    }
    for (final id in bookIds) {
      await _sourceStore.remove(id);
    }
    final mangaIds = ids.where((id) => !bookIds.contains(id)).toSet();
    if (mangaIds.isNotEmpty) {
      final store = SourceConfigStore();
      final defs = await store.loadLocal();
      await store.saveLocal(
        defs.where((d) => !mangaIds.contains(d.id)).toList(),
      );
      await SourceManager().reload();
    }
    if (!mounted) return;
    setState(() {
      _picked.removeAll(ids);
      if (_picked.isEmpty) _selectMode = false;
    });
    _toast('已删除 ${ids.length} 个源');
  }

  /// 清空当前仓的所有已导入源（订阅记录保留）
  Future<void> _clearAll() async {
    final ids = <String>[
      for (final s in _allSources) s.id,
      if (widget.comic) ...[
        for (final s in _allConfigApi) s.id,
        for (final s in _allVenera) s.id,
      ],
    ];
    if (ids.isEmpty) {
      _toast('当前仓还没有已导入的源');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('清空${widget.comic ? '漫画源' : '书源'}？'),
        content: Text(
          '将删除 ${ids.length} 个已导入源（订阅链接会保留，更新订阅可重新导入）。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _deleteNow(ids);
  }

  /// 网格里把 [dragId] 移到 [targetId] 的位置（只影响书源的 customOrder）
  Future<void> _moveBookSource(String dragId, String targetId) async {
    final ids = _sortedSources.map((e) => e.id).toList();
    final from = ids.indexOf(dragId);
    final to = ids.indexOf(targetId);
    if (from < 0 || to < 0 || from == to) return;
    final moved = ids.removeAt(from);
    ids.insert(to, moved);
    await _sourceStore.reorder(ids);
    if (mounted) setState(() {});
  }

  /// 网格 / 卡片长按：编辑、分享、删除、多选
  Future<void> _showGridMenu(BookSource s) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: _card,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                child: Text(
                  s.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _label,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              _gridMenuTile(ctx, Icons.edit_outlined, '编辑', 'edit'),
              _gridMenuTile(ctx, Icons.ios_share_rounded, '分享', 'share'),
              _gridMenuTile(ctx, Icons.checklist_rounded, '多选', 'select'),
              _gridMenuTile(
                ctx,
                Icons.delete_outline_rounded,
                '删除',
                'delete',
                danger: true,
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'edit') {
      await _editEntry(s.id);
    } else if (action == 'share') {
      await _shareIds([s.id]);
    } else if (action == 'select') {
      _enterSelect(s.id);
    } else if (action == 'delete') {
      await _deleteIds([s.id]);
    }
  }

  Widget _gridMenuTile(
    BuildContext ctx,
    IconData icon,
    String label,
    String value, {
    bool danger = false,
  }) {
    final color = danger ? Colors.redAccent : _label;
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 20, color: color),
      title: Text(label, style: TextStyle(color: color, fontSize: 14)),
      onTap: () => Navigator.pop(ctx, value),
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
          _selectMode ? '已选 ${_picked.length}' : (widget.comic ? '漫画仓' : '书源仓'),
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: titleColor,
          ),
        ),
        actions: _selectMode
            ? [
                IconButton(
                  tooltip: _allPicked ? '取消全选' : '全选',
                  onPressed: _toggleAll,
                  icon: Icon(
                    _allPicked
                        ? Icons.deselect_rounded
                        : Icons.select_all_rounded,
                  ),
                ),
                IconButton(
                  tooltip: '分享所选',
                  onPressed: _picked.isEmpty
                      ? null
                      : () => _shareIds(_picked.toList()),
                  icon: const Icon(Icons.ios_share_rounded),
                ),
                IconButton(
                  tooltip: '删除所选',
                  onPressed: _picked.isEmpty
                      ? null
                      : () => _deleteIds(_picked.toList()),
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    color: Colors.redAccent,
                  ),
                ),
                IconButton(
                  tooltip: '完成',
                  onPressed: _exitSelect,
                  icon: const Icon(Icons.check_rounded),
                ),
                const SizedBox(width: 4),
              ]
            : [
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
                PopupMenuButton<String>(
                  tooltip: '更多',
                  color: _card,
                  onSelected: (v) {
                    if (v == 'clear') _clearAll();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'clear',
                      child: Text(
                        '清空已导入源',
                        style: TextStyle(color: Colors.redAccent),
                      ),
                    ),
                  ],
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

  /// 顶部订阅卡片：已添加的卡片可拖动排序，「添加订阅」固定在末尾
  Widget _subCards() {
    final subs = _sortedSubs;
    return SizedBox(
      height: 100,
      child: Row(
        children: [
          Expanded(
            child: subs.isEmpty
                ? const SizedBox.shrink()
                : ReorderableListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(left: 14),
                    buildDefaultDragHandles: false,
                    itemCount: subs.length,
                    onReorder: _reorderSubs,
                    itemBuilder: (_, i) => Padding(
                      key: ValueKey('sub-${subs[i].id}'),
                      padding: const EdgeInsets.only(right: 8),
                      child: _subCard(subs[i], i),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 14, 0),
            child: _addSubCard(),
          ),
        ],
      ),
    );
  }

  Future<void> _reorderSubs(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    final ids = _sortedSubs.map((e) => e.id).toList();
    if (oldIndex < 0 || oldIndex >= ids.length) return;
    final moved = ids.removeAt(oldIndex);
    ids.insert(newIndex.clamp(0, ids.length), moved);
    await _subStore.reorder(ids);
    if (mounted && _sort != _SortMode.custom) {
      setState(() => _sort = _SortMode.custom);
    }
  }

  Widget _addSubCard() {
    return GestureDetector(
      onTap: _add,
      child: Container(
        width: 88,
        decoration: BoxDecoration(
          color: JellyTheme.primary.withValues(alpha: _isDark ? 0.10 : 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: JellyTheme.primary.withValues(alpha: 0.35),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: JellyTheme.primary.withValues(alpha: 0.16),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.add_rounded,
                color: JellyTheme.primary,
                size: 19,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '添加订阅',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: _label,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _subCard(SourceSubscription s, int index) {
    final active = s.id == _selectedSubId;
    final busy = _busy.contains(s.id);
    return GestureDetector(
      onTap: () => setState(() => _selectedSubId = s.id),
      // 长按 = 编辑 / 管理（拖动请按卡片右下角的把手）
      onLongPress: () => _editSub(s),
      child: Container(
        width: 176,
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 4),
        decoration: BoxDecoration(
          color: active
              ? JellyTheme.primary.withValues(alpha: _isDark ? 0.16 : 0.10)
              : _card,
          borderRadius: BorderRadius.circular(14),
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
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: _label,
                    ),
                  ),
                ),
                Transform.scale(
                  scale: 0.6,
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
                fontSize: 10.5,
                color: JellyTheme.textSecondary,
              ),
            ),
            const Spacer(),
            Row(
              children: [
                if (busy)
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: Center(
                      child: SizedBox(
                        width: 13,
                        height: 13,
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
                _cardBtn(
                  Icons.tune_rounded,
                  '编辑',
                  () => _editSub(s),
                ),
                const Spacer(),
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.all(5),
                    child: Icon(
                      Icons.drag_indicator_rounded,
                      size: 16,
                      color: JellyTheme.textSecondary.withValues(alpha: 0.7),
                    ),
                  ),
                ),
                _cardBtn(
                  Icons.delete_outline_rounded,
                  '删除',
                  () => _deleteSub(s),
                  danger: true,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 长按 / 编辑按钮：改名称、链接、更新间隔（也可以直接删除）
  Future<void> _editSub(SourceSubscription s) async {
    final nameCtl = TextEditingController(text: s.name);
    final urlCtl = TextEditingController(text: s.url);
    var hours = s.updateHours;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: _card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          title: Text(
            '管理订阅',
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
                  decoration: _inputDeco('订阅名称'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: urlCtl,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  style: TextStyle(color: _label, fontSize: 13),
                  decoration: _inputDeco('订阅链接'),
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
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'delete'),
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text('删除'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'delete') {
      await _deleteSub(s);
      return;
    }
    final url = urlCtl.text.trim();
    if (url.isEmpty) {
      _toast('订阅链接不能为空');
      return;
    }
    final name = nameCtl.text.trim().isEmpty ? s.name : nameCtl.text.trim();
    final changedUrl = url != s.url;
    await _subStore.updateSubscription(
      s.id,
      name: name,
      url: url,
      updateHours: hours,
    );
    if (!mounted) return;
    if (changedUrl) {
      final cur = _subStore.items.firstWhere((e) => e.id == s.id);
      await _update(cur);
    }
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
      for (final s in _sortedSubs) (s.id, s.name),
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
          PopupMenuButton<_ViewMode>(
            tooltip: '切换视图',
            initialValue: _view,
            color: _isDark ? JellyTheme.cardDark : Colors.white,
            onSelected: _setViewMode,
            itemBuilder: (_) => [
              for (final v in _ViewMode.values)
                PopupMenuItem(
                  value: v,
                  child: Row(
                    children: [
                      Icon(
                        v == _view ? Icons.check_rounded : v.icon,
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
                _view.icon,
                size: 20,
                color: JellyTheme.textSecondary,
              ),
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
    final config = _tabConfig;
    final venera = _tabVenera;
    if (sources.isEmpty && config.isEmpty && venera.isEmpty) {
      return _emptyHint();
    }
    final children = <Widget>[];
    if (sources.isNotEmpty) {
      if (_view.isList) {
        children.add(_sourceListCard(sources));
      } else {
        final columns = _view.columns;
        final ratio = _view == _ViewMode.grid
            ? 1.05
            : (_view == _ViewMode.card ? 4.2 : 2.25);
        children.add(
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: ratio,
            ),
            itemCount: sources.length,
            itemBuilder: (_, i) => DragTarget<String>(
              onWillAcceptWithDetails: (d) => d.data != sources[i].id,
              onAcceptWithDetails: (d) =>
                  _moveBookSource(d.data, sources[i].id),
              builder: (_, candidate, _) => _sourceGridCard(
                sources[i],
                highlight: candidate.isNotEmpty,
              ),
            ),
          ),
        );
      }
    }
    if (config.isNotEmpty) {
      children.add(const SizedBox(height: 16));
      children.add(_mangaHeader('配置 / API 源', config.length));
      children.add(const SizedBox(height: 8));
      children.add(_mangaList(config));
    }
    if (venera.isNotEmpty) {
      children.add(const SizedBox(height: 16));
      children.add(_mangaHeader('Venera 源', venera.length));
      children.add(const SizedBox(height: 8));
      children.add(_mangaList(venera));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
      children: children,
    );
  }

  Widget _sourceListCard(List<BookSource> sources) {
    return Container(
      clipBehavior: Clip.antiAlias,
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
            SwipeActionTile(
              enabled: !_selectMode,
              backgroundColor: _card,
              borderRadius: BorderRadius.zero,
              actions: [
                SwipeAction(
                  icon: Icons.edit_outlined,
                  label: '编辑',
                  color: const Color(0xFF5B8DEF),
                  onTap: () => _editEntry(sources[i].id),
                ),
                SwipeAction(
                  icon: Icons.ios_share_rounded,
                  label: '分享',
                  color: const Color(0xFF3AAE8C),
                  onTap: () => _shareIds([sources[i].id]),
                ),
                SwipeAction(
                  icon: Icons.delete_outline_rounded,
                  label: '删除',
                  color: Colors.redAccent,
                  onTap: () => _deleteSource(sources[i]),
                ),
              ],
              child: _SourceRow(
                source: sources[i],
                selectMode: _selectMode,
                picked: _picked.contains(sources[i].id),
                onTap: () {
                  if (_selectMode) _togglePick(sources[i].id);
                },
                onLongPress: () => _enterSelect(sources[i].id),
                onToggle: (v) async {
                  await _sourceStore.setEnabled(sources[i].id, v);
                  if (mounted) setState(() {});
                },
              ),
            ),
          ],
        ],
      ),
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

  Widget _sourceGridCard(BookSource s, {bool highlight = false}) {
    final picked = _picked.contains(s.id);
    return GestureDetector(
      onTap: _selectMode ? () => _togglePick(s.id) : null,
      onLongPress: () => _showGridMenu(s),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: picked
                ? JellyTheme.primary
                : (highlight
                      ? JellyTheme.primary.withValues(alpha: 0.45)
                      : Colors.transparent),
            width: picked || highlight ? 1.2 : 0.5,
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
                      : (widget.comic
                            ? Icons.collections_bookmark_rounded
                            : Icons.auto_stories_rounded),
                  size: 16,
                  color: _selectMode
                      ? (picked ? JellyTheme.primary : JellyTheme.textSecondary)
                      : (s.enabled
                            ? JellyTheme.primary
                            : JellyTheme.textSecondary.withValues(alpha: 0.5)),
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
                // 拖动把手：长按这里可自由移动排序（长按卡片本身 = 菜单）
                if (!_selectMode)
                  LongPressDraggable<String>(
                    data: s.id,
                    feedback: Material(
                      color: Colors.transparent,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: _card,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.2),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Text(
                          s.name,
                          style: TextStyle(
                            color: _label,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.all(3),
                      child: Icon(
                        Icons.drag_indicator_rounded,
                        size: 15,
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
      ),
    );
  }

  Widget _mangaHeader(String label, int count) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Text(
      '$label（$count）',
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: _label,
      ),
    ),
  );

  Widget _mangaList(List<MangaSource> list) {
    return Container(
      clipBehavior: Clip.antiAlias,
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
            SwipeActionTile(
              enabled: !_selectMode,
              backgroundColor: _card,
              borderRadius: BorderRadius.zero,
              actions: [
                if (!list[i].id.startsWith('venera:'))
                  SwipeAction(
                    icon: Icons.edit_outlined,
                    label: '编辑',
                    color: const Color(0xFF5B8DEF),
                    onTap: () => _editEntry(list[i].id),
                  ),
                SwipeAction(
                  icon: Icons.ios_share_rounded,
                  label: '分享',
                  color: const Color(0xFF3AAE8C),
                  onTap: () => _shareIds([list[i].id]),
                ),
                SwipeAction(
                  icon: Icons.delete_outline_rounded,
                  label: '删除',
                  color: Colors.redAccent,
                  onTap: () => _deleteIds([list[i].id]),
                ),
              ],
              child: GestureDetector(
                onTap: _selectMode ? () => _togglePick(list[i].id) : null,
                onLongPress: () => _enterSelect(list[i].id),
                child: SwitchListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                  selected: _picked.contains(list[i].id),
                  selectedTileColor: JellyTheme.primary.withValues(alpha: 0.08),
                  secondary: _selectMode
                      ? Icon(
                          _picked.contains(list[i].id)
                              ? Icons.check_box_rounded
                              : Icons.check_box_outline_blank_rounded,
                          size: 20,
                          color: _picked.contains(list[i].id)
                              ? JellyTheme.primary
                              : JellyTheme.textSecondary,
                        )
                      : null,
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
                    list[i].id.startsWith('venera:')
                        ? 'JS ComicSource · ${list[i].id}'
                        : list[i].id,
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
              ),
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
    this.selectMode = false,
    this.picked = false,
    this.onTap,
    this.onLongPress,
  });

  final BookSource source;
  final ValueChanged<bool> onToggle;
  final bool selectMode;
  final bool picked;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
        child: Row(
          children: [
            Icon(
              selectMode
                  ? (picked
                        ? Icons.check_box_rounded
                        : Icons.check_box_outline_blank_rounded)
                  : Icons.auto_stories_rounded,
              size: selectMode ? 19 : 16,
              color: selectMode
                  ? (picked ? JellyTheme.primary : JellyTheme.textSecondary)
                  : (source.enabled
                        ? JellyTheme.primary.withValues(alpha: 0.85)
                        : JellyTheme.textSecondary.withValues(alpha: 0.5)),
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
          ],
        ),
      ),
    );
  }
}
