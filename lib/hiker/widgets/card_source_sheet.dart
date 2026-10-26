import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/widgets/card_action_sheet.dart';

/// 「源切换」面板里的一条源。
class CardSourceItem {
  final String id;
  final String title;

  /// 副标题（作者 / 可用性 / 「当前播放」…）；null 或空串 = 不显示这一行
  final String? subtitle;

  final bool selected;

  /// 副标题用警示色（例如「…· 不可用」）—— 与影视源面板里可用/不可用的区分一致
  final bool warn;

  /// 分类名（顶部 tab 用）。来源各模块自己的口径 ——
  /// 海阔就是 `HikerSource.groupLabel`（与「海阔源管理」页同一个分组）。
  /// 留空 = 不参与分类（分类 tab 会自动隐藏）。
  final String group;

  const CardSourceItem({
    required this.id,
    required this.title,
    this.subtitle,
    this.selected = false,
    this.warn = false,
    this.group = '',
  });
}

/// 「源切换」面板 —— **与影视模块 `SourceSwitchSheet` 同一套版式**：
/// 底部面板 + 把手 + 标题（右上可带一个文字按钮）+ 可选搜索框 + **双排卡片网格**。
///
/// ── 归属 ─────────────────────────────────────────────────────
/// 本组件**只属于海阔模块**（放在 `lib/hiker/widgets/` 下）。
/// 用户 2026-10-16 明确底线：「不要将视图或其它东西扯到影视和阅读模块上去，
/// 所有功能均在它们自己的模块内部增加」。
///
/// ⚠️ 只有海阔在用。用户 2026-10-16 明确「直播「选择直播源」这个不变」，
/// 所以直播那个仍是居中 Dialog + 列表（见 `pages/live/view.dart`）。
///
/// ⚠️ 影视自己的那个面板**没有**改用这个 —— 它带「失效线路 / 定位 /
/// 单列双排切换」三套重交互（见 `widgets/source_switch_sheet.dart`），
/// 硬套会把已有功能弄丢。
class CardSourceSheet extends StatefulWidget {
  final String title;

  /// 每行两列的卡片；`selected` 的那条高亮 + 打勾
  final List<CardSourceItem> items;

  /// 是否显示搜索框（源多时开，比如海阔那几十个内置源）
  final bool searchable;
  final String searchHint;

  /// 右上角文字按钮（「管理」/「添加源」…）；点了会**先关面板再执行**
  final String? actionLabel;
  final VoidCallback? onAction;

  /// 列表为空时的提示
  final String emptyHint;

  /// 长按卡片菜单「编辑源」：一般打开源配置编辑框
  final Future<void> Function(String id)? onEdit;

  /// 长按菜单 / 多选栏「删除」；返回删除后的当前源 id（null = 未处理/失败），
  /// 面板据此移除卡片并把勾标到新的当前源
  final Future<String?> Function(List<String> ids)? onDelete;

  /// 长按菜单 / 多选栏「分享」
  final Future<void> Function(List<String> ids)? onShare;

  /// 按住把手拖动排序：回传重排后的完整 id 顺序
  final Future<void> Function(List<String> ids)? onReorder;

  const CardSourceSheet({
    super.key,
    required this.title,
    required this.items,
    this.searchable = false,
    this.searchHint = '搜索源…',
    this.actionLabel,
    this.onAction,
    this.emptyHint = '没有可用的源',
    this.onEdit,
    this.onDelete,
    this.onShare,
    this.onReorder,
  });

  /// 便捷弹出：返回选中的 id（用户没选 / 直接关掉 → null）
  static Future<String?> show({
    required BuildContext context,
    required String title,
    required List<CardSourceItem> items,
    bool searchable = false,
    String searchHint = '搜索源…',
    String? actionLabel,
    VoidCallback? onAction,
    String emptyHint = '没有可用的源',
    Future<void> Function(String id)? onEdit,
    Future<String?> Function(List<String> ids)? onDelete,
    Future<void> Function(List<String> ids)? onShare,
    Future<void> Function(List<String> ids)? onReorder,
  }) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CardSourceSheet(
        title: title,
        items: items,
        searchable: searchable,
        searchHint: searchHint,
        actionLabel: actionLabel,
        onAction: onAction,
        emptyHint: emptyHint,
        onEdit: onEdit,
        onDelete: onDelete,
        onShare: onShare,
        onReorder: onReorder,
      ),
    );
  }

  @override
  State<CardSourceSheet> createState() => _CardSourceSheetState();
}

class _CardSourceSheetState extends State<CardSourceSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _keyword = '';

  /// 当前选中源的 key —— 弹窗打开时自动滚到它（用户 2026-10-18「加个定位」）
  final GlobalKey _selectedKey = GlobalKey();

  /// 当前分类（'' = 全部）。tab 口径与「海阔源管理」页一致：用源自己的
  /// `groupLabel`，排序后平铺成胶囊；没有分类（或只有一个）时不显示 tab 行。
  String _group = '';

  /// 面板内的源列表 —— 删除后要原地消失，所以用可变副本，不直接读 widget.items
  late final List<CardSourceItem> _items = List.of(widget.items);

  /// 多选模式：点卡片 = 勾选（而不是切源）
  bool _selectMode = false;
  final Set<String> _picked = <String>{};

  bool get _canMulti => widget.onDelete != null || widget.onShare != null;

  @override
  void initState() {
    super.initState();
    // 用户 2026-10-18：「源切换弹窗还是加个定位」——
    // 首次打开自动滚到当前源，几十个源时不用手动翻找。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _selectedKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.35,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  bool get _hasSelected => _items.any((e) => e.selected);

  /// 复制一条并改选中态（删除当前源后要把回落的新当前源标上勾）
  CardSourceItem _withSelected(CardSourceItem e, bool v) => CardSourceItem(
    id: e.id,
    title: e.title,
    subtitle: e.subtitle,
    selected: v,
    warn: e.warn,
    group: e.group,
  );

  /// 右上角「定位」：清掉分类/关键词过滤，再滚到当前选中的源。
  void _locateSelected() {
    if (!_hasSelected) return;
    setState(() {
      _group = '';
      _keyword = '';
      _searchController.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _selectedKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.35,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  /// 全部分类（去重 + 排序）
  List<String> get _groups {
    final s = <String>{};
    for (final e in _items) {
      final g = e.group.trim();
      if (g.isNotEmpty) s.add(g);
    }
    final l = s.toList()..sort();
    return l;
  }

  /// 先按分类过滤，再按关键词过滤（两者叠加）
  List<CardSourceItem> get _list {
    var l = _items;
    if (_group.isNotEmpty) {
      l = l.where((e) => e.group.trim() == _group).toList();
    }
    if (_keyword.isNotEmpty) {
      final kw = _keyword.toLowerCase();
      l = l.where((e) => e.title.toLowerCase().contains(kw)).toList();
    }
    return l;
  }

  // ── 长按菜单 / 多选 ─────────────────────────────────────

  void _togglePick(String id) {
    setState(() {
      if (!_picked.remove(id)) _picked.add(id);
      if (_picked.isEmpty) _selectMode = false;
    });
  }

  void _enterSelectMode([String? first]) {
    setState(() {
      _selectMode = true;
      _picked.clear();
      if (first != null) _picked.add(first);
    });
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _picked.clear();
    });
  }

  Future<void> _confirmDelete(List<CardSourceItem> targets) async {
    final ids = targets.map((e) => e.id).toList();
    if (ids.isEmpty || widget.onDelete == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundCard,
        title: Text(
          ids.length > 1 ? '删除 ${ids.length} 个源？' : '删除这个源？',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontHeadline,
          ),
        ),
        content: Text(
          ids.length > 1
              ? '删除后需要重新导入才能恢复。'
              : '「${targets.first.title}」删除后需要重新导入才能恢复。',
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: AppTheme.fontBody,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              '删除',
              style: TextStyle(color: Colors.redAccent.shade100),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final currentId = await widget.onDelete!(ids);
    if (currentId == null || !mounted) return;
    setState(() {
      _items.removeWhere((e) => ids.contains(e.id));
      _picked.removeAll(ids);
      if (_picked.isEmpty) _selectMode = false;
      // 删掉的可能是当前源 ⇒ 按宿主返回的新当前源重标勾
      for (var i = 0; i < _items.length; i++) {
        _items[i] = _withSelected(_items[i], _items[i].id == currentId);
      }
    });
  }

  /// 长按卡片：多选模式下 = 勾选；否则弹**卡片式**操作菜单（一行两个）
  Future<void> _onLongPress(CardSourceItem item) async {
    if (_selectMode) {
      _togglePick(item.id);
      return;
    }
    final actions = <CardAction>[];
    if (widget.onEdit != null) {
      actions.add(
        CardAction(
          icon: Icons.edit_outlined,
          label: '编辑',
          onTap: () => widget.onEdit?.call(item.id),
        ),
      );
    }
    if (widget.onShare != null) {
      actions.add(
        CardAction(
          icon: Icons.ios_share_rounded,
          label: '分享',
          onTap: () => widget.onShare?.call([item.id]),
        ),
      );
    }
    if (_canMulti) {
      actions.add(
        CardAction(
          icon: Icons.checklist_rounded,
          label: '多选',
          onTap: () => _enterSelectMode(item.id),
        ),
      );
    }
    if (widget.onDelete != null) {
      actions.add(
        CardAction(
          icon: Icons.delete_outline_rounded,
          label: '删除',
          danger: true,
          onTap: () => _confirmDelete([item]),
        ),
      );
    }
    if (actions.isEmpty) return;
    await showCardActions(
      context,
      title: item.title,
      subtitle: item.subtitle,
      actions: actions,
    );
  }

  /// 把手拖到另一张卡片上 → 本地重排 + 回写宿主（[widget.onReorder]）
  Future<void> _moveItem(String fromId, String toId) async {
    if (fromId == toId || widget.onReorder == null) return;
    final from = _items.indexWhere((e) => e.id == fromId);
    final to = _items.indexWhere((e) => e.id == toId);
    if (from < 0 || to < 0) return;
    final item = _items.removeAt(from);
    _items.insert(to, item);
    setState(() {});
    await widget.onReorder!(_items.map((e) => e.id).toList());
  }

  /// 多选底栏：全选 / 已选数 / 分享 / 删除 / 完成
  Widget _selectBar() {
    final list = _list;
    final allPicked =
        list.isNotEmpty && list.every((e) => _picked.contains(e.id));
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: AppTheme.borderLight, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          TextButton(
            onPressed: () => setState(() {
              if (allPicked) {
                _picked.clear();
                _selectMode = false;
              } else {
                _picked.addAll(list.map((e) => e.id));
              }
            }),
            child: Text(
              allPicked ? '取消全选' : '全选',
              style: TextStyle(
                color: AppTheme.accentOnSurface,
                fontSize: AppTheme.fontSubhead,
              ),
            ),
          ),
          Text(
            '已选 ${_picked.length}',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontSubhead,
            ),
          ),
          const Spacer(),
          if (widget.onShare != null)
            IconButton(
              tooltip: '分享',
              onPressed: _picked.isEmpty ? null : _sharePicked,
              icon: Icon(
                Icons.ios_share_rounded,
                size: 20,
                color: _picked.isEmpty
                    ? AppTheme.textTertiary
                    : AppTheme.accentOnSurface,
              ),
            ),
          if (widget.onDelete != null)
            IconButton(
              tooltip: '删除',
              onPressed: _picked.isEmpty ? null : _deletePicked,
              icon: Icon(
                Icons.delete_outline_rounded,
                size: 20,
                color: _picked.isEmpty
                    ? AppTheme.textTertiary
                    : Colors.redAccent.shade100,
              ),
            ),
          TextButton(
            onPressed: _exitSelectMode,
            child: Text(
              '完成',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontSubhead,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _sharePicked() async {
    final targets = _items.where((e) => _picked.contains(e.id)).toList();
    if (targets.isEmpty || widget.onShare == null) return;
    await widget.onShare!(targets.map((e) => e.id).toList());
  }

  Future<void> _deletePicked() async {
    final targets = _items.where((e) => _picked.contains(e.id)).toList();
    if (targets.isEmpty) return;
    await _confirmDelete(targets);
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    final list = _list;
    final groups = _groups;
    // 有副标题时卡片要高一档，否则两行字会被压扁
    final hasSub = _items.any((e) => (e.subtitle ?? '').isNotEmpty);

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: AppTheme.borderLight, width: 0.5),
      ),
      // 顶部避让状态栏：标题不被刘海/状态栏遮住
      child: SafeArea(
        top: true,
        bottom: false,
        child: ConstrainedBox(
          // 只给上限（不给固定高）：源少时面板矮、源多时滚动 —— 与影视那个
          // 固定 40% 屏的面板不同，因为这里常常只有 1~3 条
          constraints: BoxConstraints(maxHeight: h * 0.5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部拖拽指示条
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 4),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.textSecondary.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // 头部：标题（左）+ 可选文字按钮（右）
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (!_selectMode && _hasSelected)
                      IconButton(
                        tooltip: '定位到当前源',
                        visualDensity: VisualDensity.compact,
                        onPressed: _locateSelected,
                        icon: Icon(
                          Icons.my_location_rounded,
                          size: 18,
                          color: AppTheme.accentOnSurface,
                        ),
                      ),
                    if (!_selectMode && _canMulti && _items.isNotEmpty)
                      IconButton(
                        tooltip: '多选',
                        visualDensity: VisualDensity.compact,
                        onPressed: _enterSelectMode,
                        icon: Icon(
                          Icons.checklist_rounded,
                          size: 18,
                          color: AppTheme.accentOnSurface,
                        ),
                      ),
                    if (widget.actionLabel != null && !_selectMode)
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).pop();
                          widget.onAction?.call();
                        },
                        child: Text(
                          widget.actionLabel!,
                          style: TextStyle(
                            color: AppTheme.accentOnSurface,
                            fontSize: AppTheme.fontSubhead,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // 分类 tab：与「海阔源管理」页同一口径（源自己的 group），
              // 只有一个分类时不显示（省一行高度）
              if (groups.length >= 2)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 0, 2),
                  child: SizedBox(
                    height: 30,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        _groupChip(
                          '全部',
                          _group.isEmpty,
                          () => setState(() => _group = ''),
                        ),
                        for (final g in groups)
                          _groupChip(
                            g,
                            _group == g,
                            () => setState(() => _group = g),
                          ),
                      ],
                    ),
                  ),
                ),
              if (widget.searchable)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _SheetSearchField(
                    controller: _searchController,
                    hint: widget.searchHint,
                    keyword: _keyword,
                    onChanged: (v) => setState(() => _keyword = v.trim()),
                  ),
                ),
              const SizedBox(height: 10),
              // 源列表：卡片网格（两列）
              Flexible(
                child: list.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 28),
                        child: Center(
                          child: Text(
                            _keyword.isNotEmpty
                                ? '未找到匹配的源'
                                : (_group.isNotEmpty
                                      ? '这个分类下没有源'
                                      : widget.emptyHint),
                            style: TextStyle(
                              color: AppTheme.textTertiary,
                              fontSize: AppTheme.fontSubhead,
                            ),
                          ),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        shrinkWrap: true,
                        children: [
                          GridView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 2,
                                  mainAxisSpacing: 10,
                                  crossAxisSpacing: 10,
                                  // 卡片式：一排 2 个，给足高度（原来用宽高比会被压成细条）
                                  mainAxisExtent: hasSub ? 96 : 72,
                                ),
                            itemCount: list.length,
                            itemBuilder: (_, i) {
                              final item = list[i];
                              final picked = _picked.contains(item.id);
                              final tile = _CardTile(
                                // 选中项挂 key：弹窗打开时 Scrollable.ensureVisible 用它定位
                                key: item.selected ? _selectedKey : null,
                                item: item,
                                selectMode: _selectMode,
                                picked: picked,
                                dragHandle:
                                    (!_selectMode && widget.onReorder != null)
                                    ? CardDragHandle(
                                        data: item.id,
                                        label: item.title,
                                      )
                                    : null,
                                onTap: () {
                                  if (_selectMode) {
                                    _togglePick(item.id);
                                  } else {
                                    Navigator.of(context).pop(item.id);
                                  }
                                },
                                onLongPress: () => _onLongPress(item),
                              );
                              if (widget.onReorder == null) return tile;
                              return DragTarget<String>(
                                onWillAcceptWithDetails: (d) =>
                                    d.data != item.id,
                                onAcceptWithDetails: (d) =>
                                    _moveItem(d.data, item.id),
                                builder: (_, candidate, _) => AnimatedContainer(
                                  duration: const Duration(milliseconds: 120),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(14),
                                    border: candidate.isEmpty
                                        ? null
                                        : Border.all(
                                            color: AppTheme.accentColor
                                                .withValues(alpha: 0.6),
                                            width: 1.4,
                                          ),
                                  ),
                                  child: tile,
                                ),
                              );
                            },
                          ),
                        ],
                      ),
              ),
              if (_selectMode) _selectBar(),
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );
  }

  /// 分类胶囊（与「海阔源管理」页的 `_chip` 同款：选中 = 强调淡底 + 加粗）
  Widget _groupChip(String label, bool on, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? AppTheme.accentSurface : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: on ? AppTheme.accentOnSurface : AppTheme.textSecondary,
            fontSize: AppTheme.fontCaption,
            fontWeight: on ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// 两列卡片里的一张源（与影视 `_SourceTile` 同款：单选圈 + 名称 + 可选副标题）
class _CardTile extends StatelessWidget {
  final CardSourceItem item;

  /// 多选模式：左侧图标变成复选框，高亮看 [picked] 而不是当前源
  final bool selectMode;
  final bool picked;

  /// 右上角拖动把手（长按它排序）；null = 不显示
  final Widget? dragHandle;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _CardTile({
    super.key,
    required this.item,
    required this.onTap,
    required this.onLongPress,
    this.selectMode = false,
    this.picked = false,
    this.dragHandle,
  });

  @override
  Widget build(BuildContext context) {
    final sub = item.subtitle ?? '';
    final active = selectMode ? picked : item.selected;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: active
              ? AppTheme.accentColor.withValues(alpha: 0.12)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active
                ? AppTheme.accentColor.withValues(alpha: 0.4)
                : AppTheme.borderLight,
            width: active ? 1 : 0.5,
          ),
        ),
        child: Stack(
          children: [
            // 卡片主体：名称 + 副标题都居中（用户 2026-10-18：卡片式、一排 2 个）
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.title,
                      maxLines: sub.isEmpty ? 2 : 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: active
                            ? AppTheme.textPrimary
                            : AppTheme.textSecondary,
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                    if (sub.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: item.warn
                              ? Colors.orange.shade400
                              : AppTheme.textTertiary,
                          fontSize: AppTheme.fontCaption,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // 拖动把手（左上角）：长按它移动排序
            if (dragHandle != null)
              Positioned(top: -2, left: -2, child: dragHandle!),
            // 选中/多选标记放右上角，不挤占居中的文字
            if (selectMode || item.selected)
              Positioned(
                top: 0,
                right: 0,
                child: Icon(
                  selectMode
                      ? (picked
                            ? Icons.check_box_rounded
                            : Icons.check_box_outline_blank_rounded)
                      : Icons.check_circle,
                  size: 16,
                  color: active ? AppTheme.accentColor : AppTheme.textTertiary,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 面板里的搜索框：**超小胶囊**（与影视源面板 / 首页搜索框同规格）
class _SheetSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String keyword;
  final String hint;
  final ValueChanged<String> onChanged;

  const _SheetSearchField({
    required this.controller,
    required this.keyword,
    required this.hint,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: AppTheme.borderLight, width: 0.5),
      ),
      child: Row(
        children: [
          const SizedBox(width: 10),
          Icon(Icons.search, color: AppTheme.textTertiary, size: 14),
          const SizedBox(width: 5),
          Expanded(
            child: TextField(
              controller: controller,
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 12),
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: 12,
                ),
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 6),
              ),
            ),
          ),
          if (keyword.isNotEmpty)
            GestureDetector(
              onTap: () {
                controller.clear();
                onChanged('');
              },
              child: Padding(
                padding: const EdgeInsets.all(5),
                child: Icon(
                  Icons.cancel,
                  color: AppTheme.textTertiary,
                  size: 13,
                ),
              ),
            ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}
