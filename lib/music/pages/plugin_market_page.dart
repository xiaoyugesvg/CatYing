// lib/music/pages/plugin_market_page.dart
//
// 「插件市场」页 —— 2026-10-21 第三期。
//
// 条目来自所有**启用订阅**的清单（见 PluginSubscriptionPage）。
// 这里只做三件事：安装 / 更新 / 卸载；插件的登录变量在另一个页面。

import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../../widgets/app_toast.dart';
import '../models/plugin_subscription.dart';
import '../models/third_party_source.dart';
import '../services/plugin_market_service.dart';
import '../theme/music_theme.dart';
import '../widgets/music_components.dart';
import 'plugin_subscription_page.dart';
import 'plugin_variables_page.dart';

class PluginMarketPage extends StatefulWidget {
  const PluginMarketPage({super.key});

  @override
  State<PluginMarketPage> createState() => _PluginMarketPageState();
}

class _PluginMarketPageState extends State<PluginMarketPage> {
  final _market = PluginMarketService.instance;
  final _searchCtrl = TextEditingController();

  bool _loading = true;
  String _query = '';

  /// 正在安装/卸载的文件名（避免重复点击）
  String? _busyFile;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      if (mounted) setState(() => _query = _searchCtrl.text.trim());
    });
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    await _market.init();
    await _market.refresh();
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _install(PluginMarketEntry e) async {
    if (_busyFile != null) return;
    setState(() => _busyFile = e.fileName);
    final err = await _market.install(e);
    if (!mounted) return;
    setState(() => _busyFile = null);
    if (err != null) {
      AppToast.error('安装失败：$err');
    } else {
      AppToast.success('已安装「${e.name}」');
    }
  }

  Future<void> _uninstall(PluginMarketEntry e) async {
    if (_busyFile != null) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MusicTheme.card,
        title: Text('卸载插件', style: TextStyle(color: MusicTheme.label)),
        content: Text(
          '将从音源列表移除「${e.name}」。下次刷新订阅还能再装回来。',
          style: TextStyle(color: MusicTheme.secondary, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: MusicTheme.secondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('卸载', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (yes != true) return;
    setState(() => _busyFile = e.fileName);
    await _market.uninstall(e);
    if (!mounted) return;
    setState(() => _busyFile = null);
  }

  Future<void> _openVariables(PluginMarketEntry e) async {
    final src = ThirdPartySourceStore.instance.byId(e.sourceId);
    if (src == null) return;
    await Navigator.of(context).push<bool>(MaterialPageRoute<bool>(
      settings: const RouteSettings(name: 'music:page'),
      builder: (_) => PluginVariablesPage(source: src),
    ));
  }

  Future<void> _openSubscriptions() async {
    await Navigator.of(context).push<void>(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'music:page'),
      builder: (_) => const PluginSubscriptionPage(),
    ));
    // 订阅页里可能加了新清单 → 回来重新拉一次
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: MusicTheme.themeData(),
      child: Scaffold(
        backgroundColor: MusicTheme.background,
        appBar: AppBar(
          backgroundColor: MusicTheme.background,
          elevation: 0,
          iconTheme: IconThemeData(color: MusicTheme.label),
          title: Text(
            '插件市场',
            style: TextStyle(
              color: MusicTheme.label,
              fontSize: AppTheme.fontHeadline,
            ),
          ),
          actions: [
            IconButton(
              tooltip: '订阅管理',
              icon: Icon(Icons.rss_feed_rounded, color: MusicTheme.tint),
              onPressed: _openSubscriptions,
            ),
            IconButton(
              tooltip: '刷新清单',
              icon: Icon(Icons.refresh_rounded, color: MusicTheme.tint),
              onPressed: _loading ? null : _load,
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: MusicTheme.fill,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.search_rounded,
                        size: 18, color: MusicTheme.secondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _searchCtrl,
                        style: TextStyle(
                          color: MusicTheme.label,
                          fontSize: AppTheme.fontHeadline,
                        ),
                        cursorColor: MusicTheme.tint,
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: '搜索插件',
                          hintStyle: TextStyle(
                            color: MusicTheme.secondary,
                            fontSize: AppTheme.fontBody,
                          ),
                        ),
                      ),
                    ),
                    if (_query.isNotEmpty)
                      GestureDetector(
                        onTap: () {
                          _searchCtrl.clear();
                          setState(() => _query = '');
                        },
                        child: Icon(Icons.cancel,
                            size: 16, color: MusicTheme.secondary),
                      ),
                  ],
                ),
              ),
            ),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: MusicTheme.tint));
    }
    // 只展示**当前启用订阅**里的条目：停用订阅后它的旧清单不再出现
    // （已安装的插件仍然留在音源列表里，不会被静默卸载）
    final activeSubs = PluginSubscriptionStore.instance.enabled
        .map((s) => s.id)
        .toSet();
    final all = _market.entries
        .where((e) => activeSubs.contains(e.subscriptionId))
        .toList();
    final list = _query.isEmpty
        ? all
        : all
            .where((e) => e.name.toLowerCase().contains(_query.toLowerCase()))
            .toList();

    return ValueListenableBuilder<int>(
      valueListenable: ThirdPartySourceStore.instance.revision,
      builder: (context, _, __) {
        // 安装状态在 builder 内算：装/卸一次后标题里的计数要立刻跟上
        final installed = all.where(_market.isInstalled).length;
        final updatable = all.where(_market.canUpdate).length;
        if (all.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                '清单是空的。\n点右上角「订阅管理」添加或刷新订阅地址。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: MusicTheme.secondary,
                  fontSize: AppTheme.fontSubhead,
                  height: 1.6,
                ),
              ),
            ),
          );
        }
        // 已安装的排在前面（顺序 = 音源列表顺序，可拖动调整）；
        // 未安装的按订阅清单原顺序排在后面。
        final storeOrder = <String, int>{};
        final storeAll = ThirdPartySourceStore.instance.all;
        for (var i = 0; i < storeAll.length; i++) {
          storeOrder[storeAll[i].id] = i;
        }
        final installedList = list.where(_market.isInstalled).toList()
          ..sort((a, b) => (storeOrder[a.sourceId] ?? 1 << 20)
              .compareTo(storeOrder[b.sourceId] ?? 1 << 20));
        final others = list.where((e) => !_market.isInstalled(e)).toList();

        if (list.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              '没有找到「$_query」',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: MusicTheme.secondary,
                fontSize: AppTheme.fontSubhead,
              ),
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 18, 8),
              child: Text(
                '共 ${all.length} 个插件 · 已安装 $installed'
                '${updatable > 0 ? ' · $updatable 个可更新' : ''}',
                style: TextStyle(
                  color: MusicTheme.secondary,
                  fontSize: AppTheme.fontFootnote,
                ),
              ),
            ),
            Expanded(
              child: CustomScrollView(
                slivers: [
                  if (installedList.isNotEmpty) ...[
                    const SliverToBoxAdapter(
                      child: SectionTitle(title: '已安装'),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
                      sliver: SliverGrid(
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          mainAxisExtent: 132,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (_, i) => _draggableCard(
                            installedList[i],
                            installedList,
                          ),
                          childCount: installedList.length,
                        ),
                      ),
                    ),
                  ],
                  if (others.isNotEmpty) ...[
                    const SliverToBoxAdapter(
                      child: SectionTitle(title: '未安装'),
                    ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                      sliver: SliverGrid(
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          mainAxisSpacing: 10,
                          crossAxisSpacing: 10,
                          mainAxisExtent: 132,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (_, i) => _entryCard(others[i]),
                          childCount: others.length,
                        ),
                      ),
                    ),
                  ],
                  const SliverToBoxAdapter(child: SizedBox(height: 40)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// 已安装的卡片：长按拖动，拖到另一张卡上即换位（顺序写回音源列表）
  Widget _draggableCard(
    PluginMarketEntry e,
    List<PluginMarketEntry> installed,
  ) {
    final card = _entryCard(e, draggable: true);
    final width = (MediaQuery.of(context).size.width - 42) / 2;
    return DragTarget<String>(
      onWillAcceptWithDetails: (d) => d.data != e.sourceId,
      onAcceptWithDetails: (d) => _moveInstalled(installed, d.data, e.sourceId),
      builder: (context, candidate, rejected) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: candidate.isEmpty
              ? null
              : Border.all(
                  color: MusicTheme.tint.withValues(alpha: 0.7),
                  width: 1.4,
                ),
        ),
        child: LongPressDraggable<String>(
          data: e.sourceId,
          feedback: Material(
            color: Colors.transparent,
            child: SizedBox(
              width: width,
              height: 132,
              child: _entryCard(e, draggable: true),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.35, child: card),
          child: card,
        ),
      ),
    );
  }

  /// 把 [fromId] 插到 [toId] 的位置，并把新顺序写回音源列表
  Future<void> _moveInstalled(
    List<PluginMarketEntry> installed,
    String fromId,
    String toId,
  ) async {
    final ids = installed.map((e) => e.sourceId).toList();
    final from = ids.indexOf(fromId);
    final to = ids.indexOf(toId);
    if (from < 0 || to < 0 || from == to) return;
    ids.removeAt(from);
    ids.insert(to, fromId);
    await ThirdPartySourceStore.instance.reorderSubset(ids);
    if (mounted) setState(() {});
  }

  Widget _entryCard(PluginMarketEntry e, {bool draggable = false}) {
    final installed = _market.isInstalled(e);
    final updatable = _market.canUpdate(e);
    final busy = _busyFile == e.fileName;

    final String status;
    if (!installed) {
      status = '未安装';
    } else if (updatable) {
      status = '可更新 ${e.version}';
    } else {
      status = '已安装${e.version.isEmpty ? '' : ' ${e.version}'}';
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: MusicTheme.card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: MusicTheme.tint.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(Icons.extension_rounded,
                    size: 17, color: MusicTheme.tint),
              ),
              const Spacer(),
              // 已安装的卡片给了拖动把手（长按拖动排序）
              if (draggable)
                Icon(Icons.drag_indicator_rounded,
                    size: 18, color: MusicTheme.secondary),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            e.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: MusicTheme.label,
              fontSize: AppTheme.fontHeadline,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: updatable ? MusicTheme.tint : MusicTheme.secondary,
              fontSize: AppTheme.fontFootnote,
            ),
          ),
          const Spacer(),
          if (busy)
            const SizedBox(
              height: 28,
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            SizedBox(
              height: 28,
              child: Row(
                children: [
                  if (!installed || updatable)
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: MusicTheme.tint,
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 28),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: () => _install(e),
                        child: Text(
                          installed ? '更新' : '安装',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '已安装',
                          style: TextStyle(
                            color: MusicTheme.secondary,
                            fontSize: AppTheme.fontFootnote,
                          ),
                        ),
                      ),
                    ),
                  if (installed) ...[
                    _cardIcon(
                      tooltip: '登录变量',
                      icon: Icons.tune_rounded,
                      onTap: () => _openVariables(e),
                    ),
                    _cardIcon(
                      tooltip: '卸载',
                      icon: Icons.delete_outline_rounded,
                      onTap: () => _uninstall(e),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _cardIcon({
    required String tooltip,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
      icon: Icon(icon, size: 17, color: MusicTheme.secondary),
    );
  }
}
