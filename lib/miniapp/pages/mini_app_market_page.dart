import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/miniapp/models/mini_app.dart';
import 'package:tvbox/miniapp/services/market_subscription_store.dart';
import 'package:tvbox/miniapp/services/mini_app_service.dart';

/// 市场条目的视图：列表 / 一行 2·3·4 个（用户 2026-10-18）
enum _MarketView {
  list('列表', 0),
  two('一行两个', 2),
  three('一行三个', 3),
  four('一行四个', 4);

  const _MarketView(this.label, this.columns);
  final String label;
  final int columns;

  bool get isList => columns == 0;
}

/// 「程序市场」页（用户 2026-10-18 改版）。
///
/// ── 与旧版的区别 ──────────────────────────────────────────────
/// 旧版市场是「程序」页里的一个 Tab，只能填**一个**市场地址。
/// 现在改成**订阅制**：
///   · 一个订阅 = 一个市场（`{"apps":[…]}` 清单地址）；
///   · 可以添加多个订阅，顶部 chip 切换，各自独立缓存；
///   · 程序主页只显示已安装，市场从顶栏的商店按钮 / 添加弹层进入。
class MiniAppMarketPage extends StatefulWidget {
  const MiniAppMarketPage({super.key, this.initialSubscriptionId});

  /// 打开时默认选中的订阅（空 = 第一条）
  final String? initialSubscriptionId;

  @override
  State<MiniAppMarketPage> createState() => _MiniAppMarketPageState();
}

class _MiniAppMarketPageState extends State<MiniAppMarketPage> {
  final _service = MiniAppService.instance;
  final _store = MarketSubscriptionStore.instance;

  String? _selectedId;
  final Map<String, List<MiniAppMarketEntry>> _cache = {};

  bool _loading = false;
  String? _error;
  int _loadSeq = 0;

  final _installing = <String>{};

  /// 视图（列表 / 2·3·4 列），存 prefs 重启保持
  static const _kViewKey = 'miniapp_market_view_mode';
  _MarketView _view = _MarketView.two;

  @override
  void initState() {
    super.initState();
    _restoreView();
    _bootstrap();
  }

  Future<void> _restoreView() async {
    try {
      final p = await SharedPreferences.getInstance();
      final i = p.getInt(_kViewKey) ?? _MarketView.two.index;
      if (i >= 0 && i < _MarketView.values.length && mounted) {
        setState(() => _view = _MarketView.values[i]);
      }
    } catch (_) {}
  }

  Future<void> _setViewMode(_MarketView v) async {
    setState(() => _view = v);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_kViewKey, v.index);
    } catch (_) {}
  }

  Future<void> _bootstrap() async {
    await _store.load();
    if (!mounted) return;
    final id =
        widget.initialSubscriptionId ??
        (_store.items.isNotEmpty ? _store.items.first.id : null);
    setState(() => _selectedId = id);
    if (id != null) await _loadFor(id);
  }

  MarketSubscription? get _selected {
    final id = _selectedId;
    if (id == null) return null;
    for (final s in _store.items) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<void> _loadFor(String id) async {
    final sub = _store.items.where((e) => e.id == id).firstOrNull;
    if (sub == null) return;
    final seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _service.fetchMarket(sub.url);
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _loading = false;
        _cache[sub.url] = list ?? const [];
        _error = (list == null || list.isEmpty) ? '这个地址不是有效的小程序市场清单' : null;
      });
    } catch (e) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _loading = false;
        _error = '加载失败：$e';
      });
    }
  }

  Future<void> _switchTo(MarketSubscription sub) async {
    if (_selectedId == sub.id) return;
    setState(() {
      _selectedId = sub.id;
      _error = null;
    });
    if (!_cache.containsKey(sub.url)) {
      await _loadFor(sub.id);
    }
  }

  Future<void> _install(MiniAppMarketEntry e) async {
    if (_installing.contains(e.appId)) return;
    setState(() => _installing.add(e.appId));
    final r = await _service.installMarketEntry(e);
    if (!mounted) return;
    setState(() => _installing.remove(e.appId));
    AppToast.message(r.ok ? '已安装「${e.name}」' : (r.error ?? '安装失败'));
    if (r.ok) {
      await _service.ensureLoaded();
      if (mounted) setState(() {});
    }
  }

  // ── 订阅管理 ─────────────────────────────────────────────────

  Future<void> _showSubscriptionDialog({MarketSubscription? existing}) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final urlCtrl = TextEditingController(text: existing?.url ?? '');
    final isEdit = existing != null;
    final ok = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        title: Text(
          isEdit ? '编辑市场订阅' : '添加市场订阅',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: nameCtrl,
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
                decoration: _inputDeco('订阅名称（可选，默认用域名）'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: urlCtrl,
                keyboardType: TextInputType.url,
                autocorrect: false,
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                decoration: _inputDeco('市场清单地址（https://…/apps.json）'),
              ),
              const SizedBox(height: 10),
              Text(
                '一个订阅对应一个市场；可添加多个订阅在顶部切换。',
                style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (isEdit)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'delete'),
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text('删除'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (urlCtrl.text.trim().isEmpty) {
                AppToast.message('市场地址不能为空');
                return;
              }
              Navigator.pop(ctx, 'save');
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (!mounted || ok == null || ok == 'cancel') return;
    if (ok == 'delete' && existing != null) {
      await _store.remove(existing.id);
      if (!mounted) return;
      final next = _store.items.isNotEmpty ? _store.items.first.id : null;
      setState(() => _selectedId = next);
      if (next != null) await _loadFor(next);
      return;
    }
    if (ok != 'save') return;
    final name = nameCtrl.text.trim();
    final url = urlCtrl.text.trim();
    if (url.isEmpty) return;
    if (isEdit) {
      await _store.update(existing.id, name: name, url: url);
      if (!mounted) return;
      setState(() => _selectedId = existing.id);
      await _loadFor(existing.id);
    } else {
      final sub = await _store.add(name: name, url: url);
      if (!mounted) return;
      setState(() => _selectedId = sub.id);
      await _loadFor(sub.id);
    }
  }

  InputDecoration _inputDeco(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(color: AppTheme.textTertiary, fontSize: 12.5),
    isDense: true,
    filled: true,
    fillColor: AppTheme.backgroundTertiary,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
  );

  // ── UI ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundPrimary,
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back_ios_new,
            size: 20,
            color: AppTheme.textPrimary,
          ),
          onPressed: () => Navigator.maybePop(context),
        ),
        centerTitle: true,
        title: Text(
          '程序市场',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontHeadline,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          PopupMenuButton<_MarketView>(
            tooltip: '切换视图',
            initialValue: _view,
            color: AppTheme.backgroundSecondary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            onSelected: _setViewMode,
            itemBuilder: (_) => [
              for (final v in _MarketView.values)
                PopupMenuItem(
                  value: v,
                  child: Row(
                    children: [
                      Icon(_viewIcon(v), size: 17),
                      const SizedBox(width: 8),
                      Text(v.label, style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Icon(
                _viewIcon(_view),
                size: 20,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
          IconButton(
            tooltip: '刷新',
            icon: Icon(Icons.refresh_rounded, color: AppTheme.textSecondary),
            onPressed: _selected == null ? null : () => _loadFor(_selected!.id),
          ),
          IconButton(
            tooltip: '添加订阅',
            icon: Icon(Icons.add_rounded, color: AppTheme.textPrimary),
            onPressed: () => _showSubscriptionDialog(),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListenableBuilder(
        listenable: _store,
        builder: (context, _) {
          final subs = _store.items;
          if (subs.isEmpty) return _emptyNoSubs();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _subscriptionBar(subs),
              const SizedBox(height: 8),
              if (_loading && (_bodyEntries.isEmpty))
                const Expanded(
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                Expanded(child: _body()),
            ],
          );
        },
      ),
    );
  }

  List<MiniAppMarketEntry> get _bodyEntries {
    final sub = _selected;
    if (sub == null) return const [];
    return _cache[sub.url] ?? const [];
  }

  Widget _emptyNoSubs() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppTheme.accentColor.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.storefront_rounded,
                size: 30,
                color: AppTheme.accentOnSurface,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '还没有市场订阅',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '一个订阅对应一个市场，可以添加多个\n在顶部切换不同市场',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontFootnote,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: () => _showSubscriptionDialog(),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('添加订阅'),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.accentColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _subscriptionBar(List<MarketSubscription> subs) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          Expanded(
            child: ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(left: AppTheme.spacingMD),
              buildDefaultDragHandles: false,
              itemCount: subs.length,
              // onReorderItem 的 newIndex 已由框架归一化（移出后重新插入的
              // 最终下标），不要再手动减一。
              onReorderItem: (oldIndex, newIndex) async {
                final ids = subs.map((e) => e.id).toList();
                final moved = ids.removeAt(oldIndex);
                ids.insert(newIndex.clamp(0, ids.length), moved);
                await _store.reorder(ids);
              },
              itemBuilder: (_, i) => Padding(
                key: ValueKey('market-sub-${subs[i].id}'),
                padding: const EdgeInsets.only(right: 8),
                child: ReorderableDelayedDragStartListener(
                  index: i,
                  child: _marketChip(subs[i]),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4, right: AppTheme.spacingMD),
            child: GestureDetector(
              onTap: () => _showSubscriptionDialog(),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.backgroundTertiary,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: AppTheme.borderLight, width: 0.6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.add_rounded,
                      size: 16,
                      color: AppTheme.textSecondary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '订阅',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _marketChip(MarketSubscription sub) {
    final selected = sub.id == _selectedId;
    return GestureDetector(
      // 已选中的再点一次 = 编辑；长按拖动排序
      onTap: selected
          ? () => _showSubscriptionDialog(existing: sub)
          : () => _switchTo(sub),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppTheme.accentColor : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? Colors.transparent : AppTheme.borderLight,
            width: 0.6,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.storefront_rounded,
              size: 15,
              color: selected ? Colors.white : AppTheme.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              sub.name,
              style: TextStyle(
                color: selected ? Colors.white : AppTheme.textSecondary,
                fontSize: 12.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    final err = _error;
    final entries = _bodyEntries;
    if (err != null && entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_rounded,
                size: 40,
                color: AppTheme.textTertiary,
              ),
              const SizedBox(height: 10),
              Text(
                err,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: AppTheme.fontFootnote,
                ),
              ),
              const SizedBox(height: 14),
              TextButton(
                onPressed: _selected == null
                    ? null
                    : () => _loadFor(_selected!.id),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (entries.isEmpty) {
      return Center(
        child: Text(
          _loading ? '加载中…' : '这个市场暂时没有内容',
          style: TextStyle(color: AppTheme.textTertiary, fontSize: 13),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () async {
        final sub = _selected;
        if (sub != null) await _loadFor(sub.id);
      },
      child: _view.isList ? _listBody(entries) : _gridBody(entries),
    );
  }

  IconData _viewIcon(_MarketView v) => switch (v) {
    _MarketView.list => Icons.view_list_rounded,
    _MarketView.two => Icons.grid_view_rounded,
    _MarketView.three => Icons.apps_rounded,
    _MarketView.four => Icons.grid_on_rounded,
  };

  Widget _listBody(List<MiniAppMarketEntry> entries) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.spacingMD,
        4,
        AppTheme.spacingMD,
        40,
      ),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (_, i) => _tile(entries[i]),
    );
  }

  Widget _gridBody(List<MiniAppMarketEntry> entries) {
    final cols = _view.columns;
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.spacingMD,
        4,
        AppTheme.spacingMD,
        40,
      ),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        // 固定行高：2 列留出描述位，4 列紧凑一点但按钮仍可点
        mainAxisExtent: cols == 2 ? 204 : (cols == 3 ? 186 : 170),
      ),
      itemCount: entries.length,
      itemBuilder: (_, i) => _card(entries[i]),
    );
  }

  /// 卡片视图（用户 2026-10-18：市场也要一行 2/3/4 个的卡片）
  Widget _card(MiniAppMarketEntry e) {
    final installed = _service.isInstalled(e.appId);
    final busy = _installing.contains(e.appId);
    final tint = _tintFor(e.appId);
    final initial = e.name.isNotEmpty ? e.name.characters.first : '程';
    final cols = _view.columns;
    final compact = cols >= 4;
    return GestureDetector(
      onTap: busy ? null : () => _install(e),
      child: Container(
        padding: EdgeInsets.all(compact ? 8 : 10),
        decoration: BoxDecoration(
          color: AppTheme.backgroundCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
          // 轻微投影：卡片之间不再是一层平白纸，层级更清楚
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: AppBrightness.isLight.value ? 0.045 : 0.22,
              ),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          // 卡片里图标、名称、版本信息统一居中（用户 2026-10-18）
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      tint.withValues(alpha: 0.95),
                      tint.withValues(alpha: 0.62),
                    ],
                  ),
                  // 图标块也加一层同色柔光，和已安装页的彩色卡片呼应
                  boxShadow: [
                    BoxShadow(
                      color: tint.withValues(alpha: 0.22),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: compact ? 34 : 44,
                      height: compact ? 34 : 44,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.18),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        initial,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: compact ? 16 : 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (installed)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.25),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.check_rounded,
                            size: 12,
                            color: Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SizedBox(height: compact ? 5 : 7),
            SizedBox(
              width: double.infinity,
              child: Text(
                e.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: compact ? 10.5 : 12,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 2),
            SizedBox(
              width: double.infinity,
              child: Text(
                [
                  if (e.version.isNotEmpty) 'v${e.version}',
                  if (e.author.isNotEmpty) e.author,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: compact ? 9 : 10,
                ),
              ),
            ),
            SizedBox(height: compact ? 4 : 7),
            SizedBox(
              width: double.infinity,
              height: compact ? 26 : 30,
              child: FilledButton(
                onPressed: busy ? null : () => _install(e),
                style: FilledButton.styleFrom(
                  backgroundColor: installed
                      ? tint.withValues(alpha: 0.18)
                      : AppTheme.accentColor,
                  foregroundColor: installed ? tint : Colors.white,
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  textStyle: TextStyle(
                    fontSize: compact ? 10 : 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: Text(busy ? '…' : (installed ? '重装' : '安装')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(MiniAppMarketEntry e) {
    final installed = _service.isInstalled(e.appId);
    final busy = _installing.contains(e.appId);
    final tint = _tintFor(e.appId);
    final initial = e.name.isNotEmpty ? e.name.characters.first : '程';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(13),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  tint.withValues(alpha: 0.95),
                  tint.withValues(alpha: 0.65),
                ],
              ),
            ),
            child: Text(
              initial,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  [
                    if (e.version.isNotEmpty) 'v${e.version}',
                    if (e.author.isNotEmpty) e.author,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: 11,
                  ),
                ),
                if (e.description.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    e.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            height: 32,
            child: FilledButton(
              onPressed: busy ? null : () => _install(e),
              style: FilledButton.styleFrom(
                backgroundColor: installed
                    ? tint.withValues(alpha: 0.18)
                    : AppTheme.accentColor,
                foregroundColor: installed ? tint : Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: Text(
                busy ? '…' : (installed ? '重装' : '安装'),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static const _tints = <Color>[
    Color(0xFF4FC3F7),
    Color(0xFF9575CD),
    Color(0xFF66BB6A),
    Color(0xFFFFA726),
    Color(0xFFEF5350),
    Color(0xFF26A69A),
  ];

  Color _tintFor(String id) {
    var h = 0;
    for (final c in id.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return _tints[h % _tints.length];
  }
}
