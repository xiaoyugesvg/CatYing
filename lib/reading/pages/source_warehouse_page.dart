import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../common/theme.dart';
import '../../widgets/app_toast.dart';
import '../models/book_source.dart';
import '../models/source_subscription.dart';
import '../services/comic_source_importer.dart';
import '../services/source_subscription_store.dart';
import '../source/manga_source.dart';
import '../source/source_config_store.dart';
import '../source/source_definition.dart';
import '../source/source_manager.dart';
import '../source/venera/venera_manga_source.dart';
import '../theme/jelly_theme.dart';
import '../widgets/swipe_action_tile.dart';
import 'book_source_editor_page.dart';
import 'book_source_qr_scan_page.dart';
import 'comic_source_edit_page.dart';
import 'venera_source_edit_page.dart';

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
  bool _healthChecking = false;

  /// 当前选中的订阅 tab：null = 「全部」
  String? _selectedSubId;

  /// 排序 & 视图（列表 / 卡片 / 网格 / 一行 2·3·4）
  _SortMode _sort = _SortMode.custom;
  _ViewMode _view = _ViewMode.list;

  /// 多选：长按条目进入；勾选后底部出现操作栏
  bool _selectMode = false;
  final Set<String> _picked = <String>{};

  /// 源搜索（放在 tab 栏下面的通长胶囊）
  final TextEditingController _searchCtl = TextEditingController();
  String _query = '';

  bool _matchQuery(String name, String id) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) || id.toLowerCase().contains(q);
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

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
      // 默认停在「全部」：订阅下载失败 / sourceIds 为空时，若默认选中某条订阅，
      // 列表会一片空白 —— 用户刚导入的源明明在库里却看不到。
      setState(() => _loading = false);
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

  /// Venera / 配置源也参与「排序」菜单（以前只有订阅卡片和书源会排序）
  List<MangaSource> _sortedManga(List<MangaSource> input) {
    final l = List<MangaSource>.from(input);
    switch (_sort) {
      case _SortMode.custom:
      case _SortMode.time:
        break;
      case _SortMode.name:
        l.sort((a, b) => a.name.compareTo(b.name));
        break;
      case _SortMode.frequency:
        l.sort((a, b) {
          final ea = SourceManager().isEnabled(a.id);
          final eb = SourceManager().isEnabled(b.id);
          if (ea != eb) return ea ? -1 : 1;
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

  /// 自动更新选项：直接铺在弹窗里（向下展开），不弹系统下拉菜单。
  ///
  /// 用户 2026-10-18：原来的 Dropdown 会向上盖住弹窗，而且菜单文字是白字
  /// 配浅色底，看不清。改成常驻 chip 后方向固定、颜色也可控。
  Widget _intervalChips(int hours, ValueChanged<int> onChanged) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final o in _intervals)
          GestureDetector(
            onTap: () => onChanged(o.$1),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: hours == o.$1
                    ? JellyTheme.primary
                    : (_isDark
                          ? Colors.white.withValues(alpha: 0.07)
                          : Colors.black.withValues(alpha: 0.04)),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: hours == o.$1
                      ? JellyTheme.primary
                      : JellyTheme.textSecondary.withValues(alpha: 0.18),
                ),
              ),
              child: Text(
                o.$2,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: hours == o.$1 ? FontWeight.w600 : FontWeight.w400,
                  color: hours == o.$1 ? Colors.white : _label,
                ),
              ),
            ),
          ),
      ],
    );
  }

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
                _intervalChips(hours, (v) => setDlg(() => hours = v)),
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

    // ⚠️ 去重 / 重名判断必须**只看当前这个仓**：
    //   用户 2026-10-18：「不同订阅链接，只是取了一样名称花花」——
    //   原来用 _subStore.items 全表判断，漫画仓的「花花」会把书源仓的
    //   「花花」误判成重复，甚至替换掉另一边的订阅。
    final sideItems = _subStore.items
        .where((e) => widget.comic ? e.kind.feedsComic : e.kind.feedsNovel)
        .toList();

    // 同一个链接已存在 → 直接更新这条，避免重复记录
    final sameUrl = sideItems.where((e) => e.url == url).firstOrNull;
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
    final dup = sideItems.where((e) => e.name == name).toList();
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
    for (final s in _sortedSources)
      if (_matchQuery(s.name, s.id)) s.id,
    for (final s in _tabConfig)
      if (_matchQuery(s.name, s.id)) s.id,
    for (final s in _tabVenera)
      if (_matchQuery(s.name, s.id)) s.id,
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
      await _openVeneraEditor(def);
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

  /// Venera 源：进**脚本编辑页**（名称 / JS 全文都能改）。
  ///
  /// 以前这里只弹一个只读信息框，用户看到的就是"只有一个名称"。
  /// 编辑页菜单里的「测试源 / 源设置 / 重新下载脚本」回来后再执行
  ///（用刚保存过的最新定义）。
  Future<void> _openVeneraEditor(SourceDefinition def) async {
    final action = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => VeneraSourceEditPage(definition: def),
      ),
    );
    if (!mounted) return;
    await SourceManager().reload();
    if (!mounted) return;
    setState(() {});
    if (action == null || action == 'saved') return;
    final defs = await SourceConfigStore().loadLocal();
    final hit = defs.where((d) => d.id == def.id).toList();
    final cur = hit.isEmpty ? def : hit.first;
    switch (action) {
      case 'test':
        await _testVeneraSource(cur);
        break;
      case 'settings':
        await _openVeneraSettings(cur);
        break;
      case 'refresh':
        final url = '${cur.config['scriptUrl'] ?? ''}'.trim();
        if (url.isEmpty) {
          _toast('这个源没有记录脚本地址，无法重新下载');
        } else {
          await _refreshVeneraScript(cur, url);
        }
        break;
    }
  }

  /// 真跑一次 `getPopular()`，把结果 / 真实报错展示出来。
  ///
  /// Venera 源出错时首页只会空白（异常被页面吞掉），加这个入口方便定位：
  /// 是脚本报错、HTTP 403、还是域名不可达。
  Future<void> _testVeneraSource(SourceDefinition def) async {
    final src = SourceManager().unwrappedSource(def.id);
    if (src is! VeneraMangaSource) {
      _toast('源还没加载好，请稍后再试');
      return;
    }
    _toast('正在测试 ${src.name} …');
    String title;
    String body;
    try {
      final page = await src.getPopular();
      title = '源可用';
      body = '首页返回 ${page.items.length} 条';
      if (page.items.isNotEmpty) {
        body += '\n\n示例：\n${page.items.take(3).map((e) => e.title).join('\n')}';
      }
    } catch (e) {
      title = '测试失败';
      body = '$e';
    }
    if (!mounted) return;
    if (body.length > 800) body = '${body.substring(0, 800)}…';
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        title: Text(title, style: TextStyle(color: _label)),
        content: SingleChildScrollView(
          child: SelectableText(
            body,
            style: TextStyle(fontSize: 12, height: 1.5, color: _label),
          ),
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

  /// Venera 源设置面板（select / input / switch）。
  ///
  /// 这些值对应脚本里的 `settings` 清单（如 copy_manga 的 API 地址 / CDN 线路、
  /// wnacg 的站点 URL）。默认值不可用时，用户必须能改，否则源就"永远打不开"。
  Future<void> _openVeneraSettings(SourceDefinition def) async {
    final src = SourceManager().unwrappedSource(def.id);
    if (src is! VeneraMangaSource) {
      _toast('源还没加载好，请稍后再试');
      return;
    }
    List<Map<String, dynamic>> items;
    try {
      items = await src.fetchSettings();
    } catch (e) {
      _toast('读取设置失败：$e');
      return;
    }
    if (!mounted) return;
    if (items.isEmpty) {
      _toast('该源没有可配置项');
      return;
    }
    final values = <String, Object?>{};
    for (final it in items) {
      final k = '${it['key'] ?? ''}';
      if (k.isEmpty) continue;
      try {
        values[k] = await src.readSetting(k);
      } catch (_) {}
    }
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.7,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 16, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '源设置 · ${src.name}',
                          style: TextStyle(
                            fontSize: AppTheme.fontHeadline,
                            fontWeight: FontWeight.w700,
                            color: _label,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: Icon(
                          Icons.close_rounded,
                          color: JellyTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 18),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final it = items[i];
                      final key = '${it['key'] ?? ''}';
                      final type = '${it['type'] ?? 'input'}';
                      final title = '${it['title'] ?? key}';
                      final current = values[key];
                      return InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () async {
                          Navigator.pop(ctx);
                          await _editVeneraSetting(src, it, current);
                          if (mounted) await _openVeneraSettings(def);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 11,
                          ),
                          decoration: BoxDecoration(
                            color: _isDark
                                ? Colors.white.withValues(alpha: 0.05)
                                : Colors.black.withValues(alpha: 0.03),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      title,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: _label,
                                      ),
                                    ),
                                    if ('${it['description'] ?? ''}'
                                        .trim()
                                        .isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Text(
                                          '${it['description']}',
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            color: JellyTheme.textSecondary,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                type == 'switch'
                                    ? (current == true ? '开' : '关')
                                    : _veneraOptionText(it, current),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: JellyTheme.primary,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                Icons.chevron_right_rounded,
                                size: 18,
                                color: JellyTheme.textSecondary,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _veneraOptionText(Map<String, dynamic> it, Object? value) {
    final opts = it['options'];
    if (opts is List) {
      for (final o in opts.whereType<Map>()) {
        if ('${o['value']}' == '$value') return '${o['text'] ?? o['value']}';
      }
    }
    if (value == null) return '${it['default'] ?? ''}';
    return '$value';
  }

  Future<void> _editVeneraSetting(
    VeneraMangaSource src,
    Map<String, dynamic> item,
    Object? current,
  ) async {
    final key = '${item['key'] ?? ''}';
    final type = '${item['type'] ?? 'input'}';
    final title = '${item['title'] ?? key}';
    Object? next;
    if (type == 'switch' || type == 'toggle') {
      next = current != true;
    } else if (type == 'select' && item['options'] is List) {
      final opts = (item['options'] as List).whereType<Map>().toList();
      next = await showDialog<Object?>(
        context: context,
        builder: (ctx) => SimpleDialog(
          backgroundColor: _card,
          title: Text(title, style: TextStyle(color: _label)),
          children: [
            for (final o in opts)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, o['value']),
                child: Row(
                  children: [
                    Icon(
                      '${o['value']}' == '$current'
                          ? Icons.radio_button_checked_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 18,
                      color: '${o['value']}' == '$current'
                          ? JellyTheme.primary
                          : JellyTheme.textSecondary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${o['text'] ?? o['value']}',
                        style: TextStyle(fontSize: 13, color: _label),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
      if (next == null) return;
    } else {
      final ctrl = TextEditingController(text: '$current');
      next = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _card,
          title: Text(title, style: TextStyle(color: _label)),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            style: TextStyle(color: _label),
            decoration: InputDecoration(hintText: '${item['default'] ?? ''}'),
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
      if (next == null) return;
    }
    try {
      await src.saveSetting(key, next);
      _toast('已保存：$title');
    } catch (e) {
      _toast('保存失败：$e');
    }
  }

  Future<void> _refreshVeneraScript(SourceDefinition def, String url) async {
    try {
      final js = await fetchComicSourceText(url);
      if (!js.contains('extends ComicSource')) {
        _toast('下载到的不是 Venera 脚本（可能被代理拦截）');
        return;
      }
      final defs = await SourceConfigStore().loadLocal();
      await SourceConfigStore().saveLocal([
        for (final d in defs)
          if (d.id == def.id)
            SourceDefinition(
              id: d.id,
              type: d.type,
              engine: d.engine,
              needsMagic: d.needsMagic,
              config: {...d.config, 'script': js},
            )
          else
            d,
      ]);
      await SourceManager().reload();
      if (!mounted) return;
      setState(() {});
      _toast('脚本已更新');
    } catch (e) {
      _toast('下载失败：$e');
    }
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
                // 刷新放在最左（用户 2026-10-18：刷新 → 体检 → 导入 → ＋）
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
                // 漫画仓已替代「漫画源仓库」：把它的体检 / 导入入口搬到这里
                if (widget.comic)
                  IconButton(
                    tooltip: '源体检',
                    onPressed: _healthChecking ? null : _runQuickHealthCheck,
                    icon: _healthChecking
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.health_and_safety_rounded),
                  ),
                if (widget.comic)
                  IconButton(
                    tooltip: '导入源',
                    onPressed: _showComicImportDialog,
                    icon: const Icon(Icons.file_open_rounded),
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
        const SizedBox(height: 6),
        _searchBar(),
        const SizedBox(height: 2),
        Expanded(child: _content()),
      ],
    );
  }

  /// tab 栏下面的通长搜索胶囊：按名称 / id 过滤当前仓的源
  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: JellyTheme.textSecondary.withValues(alpha: 0.12),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.search_rounded,
              size: 17,
              color: JellyTheme.textSecondary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _searchCtl,
                textInputAction: TextInputAction.search,
                onChanged: (v) => setState(() => _query = v),
                style: TextStyle(fontSize: 13, color: _label),
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: '搜索源名称',
                  hintStyle: TextStyle(
                    fontSize: 13,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ),
            ),
            if (_query.isNotEmpty)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  _searchCtl.clear();
                  setState(() => _query = '');
                },
                child: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(
                    Icons.cancel_rounded,
                    size: 16,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── 漫画仓：源体检 / 导入源（原「漫画源仓库」顶栏功能）────────

  String _shortErr(String raw) {
    final s = raw.replaceAll('\n', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }

  /// 一键体检：并发探测每个启用源的搜索接口
  Future<void> _runQuickHealthCheck() async {
    if (_healthChecking) return;
    final sources = SourceManager().enabledSources;
    if (sources.isEmpty) {
      _toast('没有可检测的源');
      return;
    }
    setState(() => _healthChecking = true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(width: 16),
            Expanded(child: Text('正在体检漫画源…')),
          ],
        ),
      ),
    );

    final bad = <MangaSource, String>{};
    const t = Duration(seconds: 12);
    await Future.wait(
      sources.map((s) async {
        try {
          final page = await s.search('漫画', page: 0).timeout(t);
          if (page.items.isEmpty) bad[s] = '搜索无结果';
        } catch (e) {
          bad[s] = _shortErr('$e');
        }
      }),
    );
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    setState(() => _healthChecking = false);

    if (bad.isEmpty) {
      _toast('体检完成：${sources.length} 个源全部可用');
      return;
    }
    final ok = sources.length - bad.length;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        title: Text(
          '源体检：$ok 可用 / ${bad.length} 失效',
          style: TextStyle(color: _label),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final e in bad.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.key.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        e.value,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: JellyTheme.textSecondary,
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
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 导入源：网址 / 文件 / 文本 / 二维码
  Future<void> _showComicImportDialog() async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        title: Text(
          '导入源',
          style: TextStyle(
            color: _label,
            fontSize: AppTheme.fontHeadline,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '支持漫画配置源、Legado 漫画脚本、Venera index.json 或单个 .js 脚本',
                style: TextStyle(
                  fontSize: 12,
                  color: JellyTheme.textSecondary,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _importTile('网址', Icons.link_rounded, () {
                      Navigator.pop(ctx, 'url');
                    }),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _importTile('文件', Icons.folder_open_rounded, () {
                      Navigator.pop(ctx, 'file');
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: _importTile('文本', Icons.text_snippet_outlined, () {
                      Navigator.pop(ctx, 'text');
                    }),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _importTile(
                      '二维码',
                      Icons.qr_code_scanner_rounded,
                      () {
                        Navigator.pop(ctx, 'qr');
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'url':
        await _importComicFromUrl();
      case 'file':
        await _importComicFromFile();
      case 'text':
        await _importComicFromText();
      case 'qr':
        await _importComicFromQr();
    }
  }

  Widget _importTile(String label, IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: JellyTheme.primary.withValues(alpha: _isDark ? 0.10 : 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: JellyTheme.primary.withValues(alpha: 0.25),
          ),
        ),
        child: Column(
          children: [
            Icon(icon, size: 22, color: JellyTheme.primary),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: _label,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _importComicFromUrl() async {
    final ctrl = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        title: Text('网址导入', style: TextStyle(color: _label)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: _inputDeco('漫画源 JSON 地址'),
          style: TextStyle(color: _label),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    final u = (url ?? '').trim();
    if (u.isEmpty) return;
    try {
      final text = await fetchComicSourceText(u);
      if (text.trim().isEmpty) {
        _toast('下载内容为空');
        return;
      }
      await _applyComicImport(text, baseUrl: u);
    } catch (e) {
      _toast('下载失败：$e');
    }
  }

  Future<void> _importComicFromText() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        title: Text('文本导入', style: TextStyle(color: _label)),
        content: SizedBox(
          width: double.maxFinite,
          height: 220,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            style: TextStyle(color: _label, fontSize: 12),
            decoration: _inputDeco('粘贴漫画源 JSON'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    final t = (text ?? '').trim();
    if (t.isEmpty) return;
    await _applyComicImport(t);
  }

  Future<void> _importComicFromFile() async {
    try {
      final result = await FilePicker.pickFiles(type: FileType.any);
      if (result.isEmpty) return;
      var ok = 0;
      final errors = <String>[];
      for (final f in result) {
        final bytes = await f.readAsBytes();
        if (bytes.isEmpty) continue;
        // zip：解出里面的 .js / .json 逐个导入（漫画源包常用压缩包分发）
        final isZip =
            f.name.toLowerCase().endsWith('.zip') ||
            (bytes.length > 3 &&
                bytes[0] == 0x50 &&
                bytes[1] == 0x4B &&
                bytes[2] == 0x03 &&
                bytes[3] == 0x04);
        if (isZip) {
          final r = await _importComicZip(bytes);
          ok += r.$1;
          errors.addAll(r.$2);
          continue;
        }
        final r = await importComicSourcesText(
          utf8.decode(bytes, allowMalformed: true),
        );
        if (r.ok) {
          ok++;
        } else {
          errors.add(r.message);
        }
      }
      if (!mounted) return;
      setState(() {});
      if (ok > 0) {
        AppToast.message(
          '已导入 $ok 个文件${errors.isEmpty ? '' : '（${errors.length} 个失败）'}',
        );
      } else {
        AppToast.error(errors.isEmpty ? '文件是空的' : errors.first);
      }
    } catch (e) {
      _toast('导入失败：$e');
    }
  }

  Future<(int, List<String>)> _importComicZip(List<int> bytes) async {
    var ok = 0;
    final errors = <String>[];
    final archive = ZipDecoder().decodeBytes(bytes, verify: false);
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final name = f.name.toLowerCase();
      if (!(name.endsWith('.js') || name.endsWith('.json'))) continue;
      final data = f.content;
      if (data is! List) continue;
      final r = await importComicSourcesText(
        utf8.decode(List<int>.from(data), allowMalformed: true),
      );
      if (r.ok) {
        ok++;
      } else {
        errors.add('${f.name}: ${r.message}');
      }
    }
    return (ok, errors);
  }

  Future<void> _importComicFromQr() async {
    final text = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const BookSourceQrScanPage()),
    );
    if (text == null || text.trim().isEmpty) return;
    await _applyComicImport(text);
  }

  Future<void> _applyComicImport(String text, {String baseUrl = ''}) async {
    var body = text;
    var base = baseUrl;
    // 二维码 / 文本里直接贴了一个源地址：先下载再解析（Venera index.json
    // 还要用它作 baseUrl 解析脚本相对路径）
    final maybeUrl = text.trim();
    if (!maybeUrl.contains('\n') &&
        (maybeUrl.startsWith('http://') || maybeUrl.startsWith('https://'))) {
      try {
        body = await fetchComicSourceText(maybeUrl);
        base = maybeUrl;
      } catch (e) {
        _toast('下载失败：$e');
        return;
      }
    }
    final r = await importComicSourcesText(body, baseUrl: base);
    if (!mounted) return;
    setState(() {});
    if (r.ok) {
      AppToast.message(r.message);
    } else {
      AppToast.error(r.message);
    }
  }

  /// 顶部订阅卡片（与原来的「添加订阅」卡片同尺寸，可长按拖动排序）
  Widget _subCards() {
    final subs = _sortedSubs;
    if (subs.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 100,
      child: ReorderableListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(left: 14, right: 14),
        buildDefaultDragHandles: false,
        itemCount: subs.length,
        onReorder: _reorderSubs,
        itemBuilder: (_, i) => Padding(
          key: ValueKey('sub-${subs[i].id}'),
          padding: const EdgeInsets.fromLTRB(0, 2, 8, 2),
          child: _subCard(subs[i], i),
        ),
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

  /// 订阅卡片（正方形 96×96）：
  ///   左上刷新 / 右上开关 / 中间名称 / 左下更新日期 / 右下源数。
  /// 点击 = 直接打开编辑页（不再弹「修改 / 复制 / 删除」菜单）；
  /// 长按 = 拖动排序。
  Widget _subCard(SourceSubscription s, int index) {
    final active = s.id == _selectedSubId;
    final busy = _busy.contains(s.id);
    final date = _timeText(s.lastUpdated).split(' ').first;
    return ReorderableDelayedDragStartListener(
      index: index,
      child: GestureDetector(
        onTap: () {
          setState(() => _selectedSubId = s.id);
          _editSub(s);
        },
        child: Container(
          width: 96,
          height: 96,
          padding: const EdgeInsets.all(8),
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
            children: [
              Row(
                children: [
                  // 左上：刷新
                  if (busy)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: Center(
                        child: SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  else
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _update(s),
                      child: Padding(
                        padding: const EdgeInsets.all(1),
                        child: Icon(
                          Icons.sync_rounded,
                          size: 16,
                          color: JellyTheme.textSecondary,
                        ),
                      ),
                    ),
                  const Spacer(),
                  // 右上：开关（缩小，避免撑爆卡片）
                  SizedBox(
                    width: 36,
                    height: 20,
                    child: FittedBox(
                      fit: BoxFit.contain,
                      child: Switch(
                        value: s.enabled,
                        onChanged: (v) => _subStore.setEnabled(s.id, v),
                      ),
                    ),
                  ),
                ],
              ),
              // 中间：名称
              Expanded(
                child: Center(
                  child: Text(
                    s.name,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.2,
                      fontWeight: FontWeight.w700,
                      color: _label,
                    ),
                  ),
                ),
              ),
              // 左下日期 / 右下源数
              Row(
                children: [
                  Expanded(
                    child: Text(
                      date,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 9,
                        color: JellyTheme.textSecondary,
                      ),
                    ),
                  ),
                  Text(
                    '${s.count} 个源',
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 9,
                      color: JellyTheme.textSecondary,
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
                _intervalChips(hours, (v) => setDlg(() => hours = v)),
              ],
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          actions: [
            // 复制 / 删除 / 取消 / 保存：一行四个、均匀分布
            SizedBox(
              width: double.maxFinite,
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx, 'copy'),
                      child: const Text('复制'),
                    ),
                  ),
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx, 'delete'),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                      ),
                      child: const Text('删除'),
                    ),
                  ),
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('取消'),
                    ),
                  ),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(ctx, 'save'),
                      style: FilledButton.styleFrom(
                        padding: EdgeInsets.zero,
                      ),
                      child: const Text('保存'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'copy') {
      await _copyLink(s);
      return;
    }
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
          // 清空已导入源：从右上角「…」挪到排序按钮左边（用户 2026-10-18）
          IconButton(
            tooltip: '清空已导入源',
            visualDensity: VisualDensity.compact,
            onPressed: _visibleIds.isEmpty ? null : _clearAll,
            icon: Icon(
              Icons.delete_outline_rounded,
              size: 20,
              color: _visibleIds.isEmpty
                  ? JellyTheme.textSecondary.withValues(alpha: 0.4)
                  : Colors.redAccent,
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
    final sources = _sortedSources
        .where((s) => _matchQuery(s.name, s.id))
        .toList();
    final config = _sortedManga(
      _tabConfig,
    ).where((s) => _matchQuery(s.name, s.id)).toList();
    final venera = _sortedManga(
      _tabVenera,
    ).where((s) => _matchQuery(s.name, s.id)).toList();
    if (sources.isEmpty && config.isEmpty && venera.isEmpty) {
      if (_query.trim().isNotEmpty) {
        return Center(
          child: Text(
            '没有找到「${_query.trim()}」相关的源',
            style: TextStyle(
              fontSize: 13,
              color: JellyTheme.textSecondary,
            ),
          ),
        );
      }
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
      children.add(_view.isList ? _mangaList(config) : _mangaGrid(config));
    }
    if (venera.isNotEmpty) {
      children.add(const SizedBox(height: 16));
      children.add(_mangaHeader('Venera 源', venera.length));
      children.add(const SizedBox(height: 8));
      children.add(_view.isList ? _mangaList(venera) : _mangaGrid(venera));
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
                  if (_selectMode) {
                    _togglePick(sources[i].id);
                  } else {
                    // 点源 = 直接进编辑（Legado 书源就是脚本编辑页）
                    _editEntry(sources[i].id);
                  }
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
              ? '还没有漫画源。点右上角 ＋ 添加订阅，或从漫画源仓库导入。'
              : '还没有小说源。点右上角 ＋ 添加订阅，或从书源仓库导入。')
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

  /// Venera 源的脚本大小（让用户一眼确认"脚本确实导入进来了"，不是只剩一个名称）
  String _veneraScriptInfo(String id) {
    final s = SourceManager().unwrappedSource(id);
    if (s is! VeneraMangaSource) return '脚本未加载';
    final n = s.script.length;
    if (n <= 0) return '脚本缺失';
    return n >= 1024 ? '脚本 ${(n / 1024).toStringAsFixed(1)} KB' : '脚本 $n 字节';
  }

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
                onTap: () {
                  if (_selectMode) {
                    _togglePick(list[i].id);
                  } else {
                    _editEntry(list[i].id);
                  }
                },
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
                        ? 'JS ComicSource · ${_veneraScriptInfo(list[i].id)} · ${list[i].id}'
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

  /// 卡片 / 网格 / 一行 2·3·4 个：Venera / 配置源也要跟着视图切换。
  ///
  /// 之前 `_mangaList` 永远渲染成竖排列表，所以用户点「列表 / 卡片 / 网格」
  /// 看起来完全没反应（用户 2026-10-18）。
  Widget _mangaGrid(List<MangaSource> list) {
    final columns = _view.columns;
    final ratio = switch (_view) {
      _ViewMode.card => 4.2,
      _ViewMode.grid => 1.2,
      _ViewMode.two => 1.5,
      _ViewMode.three => 1.15,
      _ViewMode.four => 0.95,
      _ViewMode.list => 4.2,
    };
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: ratio,
      ),
      itemCount: list.length,
      itemBuilder: (_, i) => _mangaGridCard(list[i]),
    );
  }

  Widget _mangaGridCard(MangaSource src) {
    final picked = _picked.contains(src.id);
    final enabled = SourceManager().isEnabled(src.id);
    return GestureDetector(
      onTap: () {
        if (_selectMode) {
          _togglePick(src.id);
        } else {
          _editEntry(src.id);
        }
      },
      onLongPress: () => _enterSelect(src.id),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: picked
                ? JellyTheme.primary
                : JellyTheme.textSecondary.withValues(alpha: 0.10),
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
                      : Icons.auto_stories_rounded,
                  size: 15,
                  color: _selectMode
                      ? (picked ? JellyTheme.primary : JellyTheme.textSecondary)
                      : JellyTheme.primary,
                ),
                const Spacer(),
                SizedBox(
                  height: 20,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Switch(
                      value: enabled,
                      onChanged: (v) async {
                        await SourceManager().setEnabled(src.id, v);
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
                ),
              ],
            ),
            const Spacer(),
            Text(
              src.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: _label,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              src.id.startsWith('venera:')
                  ? 'JS · ${_veneraScriptInfo(src.id)}'
                  : src.id,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 9.5,
                color: JellyTheme.textSecondary,
              ),
            ),
          ],
        ),
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
