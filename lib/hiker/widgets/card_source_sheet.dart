import 'package:flutter/material.dart';

import '../../common/theme.dart';

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

  const CardSourceSheet({
    super.key,
    required this.title,
    required this.items,
    this.searchable = false,
    this.searchHint = '搜索源…',
    this.actionLabel,
    this.onAction,
    this.emptyHint = '没有可用的源',
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
      ),
    );
  }

  @override
  State<CardSourceSheet> createState() => _CardSourceSheetState();
}

class _CardSourceSheetState extends State<CardSourceSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _keyword = '';

  /// 当前分类（'' = 全部）。tab 口径与「海阔源管理」页一致：用源自己的
  /// `groupLabel`，排序后平铺成胶囊；没有分类（或只有一个）时不显示 tab 行。
  String _group = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// 全部分类（去重 + 排序）
  List<String> get _groups {
    final s = <String>{};
    for (final e in widget.items) {
      final g = e.group.trim();
      if (g.isNotEmpty) s.add(g);
    }
    final l = s.toList()..sort();
    return l;
  }

  /// 先按分类过滤，再按关键词过滤（两者叠加）
  List<CardSourceItem> get _list {
    var l = widget.items;
    if (_group.isNotEmpty) {
      l = l.where((e) => e.group.trim() == _group).toList();
    }
    if (_keyword.isNotEmpty) {
      final kw = _keyword.toLowerCase();
      l = l.where((e) => e.title.toLowerCase().contains(kw)).toList();
    }
    return l;
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height;
    final list = _list;
    final groups = _groups;
    // 有副标题时卡片要高一档，否则两行字会被压扁
    final hasSub = widget.items.any((e) => (e.subtitle ?? '').isNotEmpty);

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
                    if (widget.actionLabel != null)
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
                        _groupChip('全部', _group.isEmpty,
                            () => setState(() => _group = '')),
                        for (final g in groups)
                          _groupChip(g, _group == g,
                              () => setState(() => _group = g)),
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
                                fontSize: AppTheme.fontSubhead),
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
                              mainAxisSpacing: 8,
                              crossAxisSpacing: 10,
                              childAspectRatio: hasSub ? 2.9 : 3.4,
                            ),
                            itemCount: list.length,
                            itemBuilder: (_, i) =>
                                _CardTile(item: list[i]),
                          ),
                        ],
                      ),
              ),
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

  const _CardTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final sub = item.subtitle ?? '';
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(item.id),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: item.selected
              ? AppTheme.accentColor.withValues(alpha: 0.12)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: item.selected
                ? AppTheme.accentColor.withValues(alpha: 0.4)
                : AppTheme.borderLight,
            width: item.selected ? 1 : 0.5,
          ),
        ),
        child: Row(
          children: [
            Icon(
              item.selected
                  ? Icons.check_circle
                  : Icons.radio_button_unchecked,
              size: 16,
              color: item.selected
                  ? AppTheme.accentColor
                  : AppTheme.textTertiary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: item.selected
                          ? AppTheme.textPrimary
                          : AppTheme.textSecondary,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight:
                          item.selected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                  if (sub.isNotEmpty)
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: item.warn
                            ? Colors.orange.shade400
                            : AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption,
                      ),
                    ),
                ],
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
                hintStyle:
                    TextStyle(color: AppTheme.textTertiary, fontSize: 12),
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
                child:
                    Icon(Icons.cancel, color: AppTheme.textTertiary, size: 13),
              ),
            ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}
