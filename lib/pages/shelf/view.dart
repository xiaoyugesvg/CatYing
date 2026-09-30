import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../models/cache_store.dart';
import '../../models/movie.dart';
import '../../services/player_prefs.dart';
import '../../widgets/common_widgets.dart';
import '../../widgets/vod_card.dart';
import 'controller.dart';
import '../favorites/controller.dart';
import '../favorites/view.dart' show deleteFavoriteItems;
import '../history/controller.dart';
import '../history/view.dart' show deleteHistoryItems;

/// 「史藏」页 —— **历史 + 收藏 的统一页**
///
/// 为什么不再用两个子页（IndexedStack）：
///   1. 两个子页同时活着 → 各自持有搜索词 → 搜索会同时命中两边；
///   2. 搜索 / 清空 / 布局按钮分散在各自的工具栏里，父页只有「编辑」，
///      视觉上就变成两处按钮，点起来也乱；
///   3. 布局切换写在子页的 LayoutBuilder 里，改列数不会重建。
///
/// 现在：**一个工具栏 + 一份数据分支**，tab 只决定"读哪份数据、用什么列数"。
class ShelfPage extends StatefulWidget {
  const ShelfPage({super.key});

  @override
  State<ShelfPage> createState() => _ShelfPageState();
}

class _ShelfPageState extends State<ShelfPage> {
  final c = ShelfController.instance;
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();

  HistoryController get _his => Get.put(HistoryController());
  FavoritesController get _fav => Get.put(FavoritesController());

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            _buildTabBar(),
            // 工具栏：搜索 / 清空 / 编辑 / 切换布局（按你要求的顺序）
            _buildToolbar(),
            Obx(() => c.searching.value ? _buildSearchField() : const SizedBox.shrink()),
            Expanded(child: _buildGrid()),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 顶栏：历史 / 收藏 + 编辑
  // ============================================================

  Widget _buildTabBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingXL, AppTheme.spacingLG, AppTheme.spacingXL, 0),
      child: Row(
        children: [
          Obx(() => _tabLabel('历史', c.tab.value == 0, () => c.switchTab(0))),
          const SizedBox(width: 22),
          Obx(() => _tabLabel('收藏', c.tab.value == 1, () => c.switchTab(1))),
          const Spacer(),
          // 编辑模式下的：全选 / 删除(N) / 完成
          Obx(() {
            if (!c.editing.value) return const SizedBox.shrink();
            final n = c.selected.length;
            final keys = _visibleKeys();
            final allSelected = keys.isNotEmpty && n >= keys.length;
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _actionText(allSelected ? '取消全选' : '全选',
                    () => c.setAll(keys, !allSelected)),
                if (n > 0) ...[
                  const SizedBox(width: 14),
                  _actionText('删除($n)', _confirmDeleteSelected,
                      danger: true),
                ],
                const SizedBox(width: 14),
                _actionText('完成', c.exitEdit),
              ],
            );
          }),
        ],
      ),
    );
  }

  /// 工具栏：搜索 / 清空 / 编辑 / 切换布局（依序，一行放完）
  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingXL, AppTheme.spacingSM, AppTheme.spacingXL, 4),
      child: Row(
        children: [
          // 1) 搜索
          Obx(() => _iconBtn(
                c.searching.value ? Icons.search_off : Icons.search,
                c.searching.value ? '收起搜索' : '搜索',
                c.toggleSearching,
                active: c.searching.value,
              )),
          const SizedBox(width: 4),
          // 2) 清空
          _iconBtn(Icons.delete_sweep_outlined, '清空', _confirmClearAll),
          const Spacer(),
          // 3) 收藏排序（仅收藏 tab 显示，历史不需要）
          Obx(() {
            if (c.tab.value != 1) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(right: 4),
              child: _iconBtn(Icons.sort, '排序', _pickFavSort),
            );
          }),
          // 4) 编辑
          Obx(() => _iconBtn(
                c.editing.value ? Icons.done : Icons.checklist,
                c.editing.value ? '完成' : '编辑',
                () => c.toggleEdit(),
                active: c.editing.value,
              )),
          const SizedBox(width: 4),
          // 5) 切换布局
          _iconBtn(Icons.grid_view_rounded, '切换布局', _openLayoutSheet),
        ],
      ),
    );
  }

  Widget _iconBtn(IconData icon, String tip, VoidCallback onTap,
      {bool active = false}) {
    return Tooltip(
      message: tip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active
                ? AppTheme.accentColor.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon,
              size: 19,
              color: active ? AppTheme.accentColor : AppTheme.textSecondary),
        ),
      ),
    );
  }

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingXL, 4, AppTheme.spacingXL, AppTheme.spacingSM),
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          color: AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppTheme.glassBorder, width: 0.8),
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
            Icon(Icons.search, size: 15, color: AppTheme.textTertiary),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                focusNode: _searchFocus,
                autofocus: true,
                cursorColor: AppTheme.accentColor,
                cursorWidth: 2,
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontSubhead),
                // 只写当前 tab 的词 —— 不再区分 history/fav 两套
                onChanged: c.setKeyword,
                decoration: InputDecoration(
                  hintText: '搜索片名',
                  hintStyle: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontSubhead),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            if (_searchCtrl.text.isNotEmpty)
              GestureDetector(
                onTap: () {
                  _searchCtrl.clear();
                  c.setKeyword('');
                },
                child: Icon(Icons.cancel,
                    size: 15, color: AppTheme.textTertiary),
              ),
            const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }

  Widget _tabLabel(String text, bool selected, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              style: TextStyle(
                color:
                    selected ? AppTheme.accentColor : AppTheme.textSecondary,
                fontSize: AppTheme.fontTitle3,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
            const SizedBox(height: 6),
            AnimatedContainer(
              duration: AppTheme.motionFast,
              curve: AppTheme.motionCurve,
              width: selected ? 26 : 0,
              height: 2.5,
              decoration: BoxDecoration(
                color: AppTheme.accentColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionText(String text, VoidCallback onTap, {bool danger = false}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Text(
          text,
          style: TextStyle(
              color: danger ? Colors.redAccent : AppTheme.accentColor,
              fontSize: AppTheme.fontSubhead,
              fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  // ============================================================
  // 数据
  // ============================================================

  /// 当前 tab 的完整列表（未过滤）
  List<Object> get _allItems =>
      c.tab.value == 0
          ? CacheStore.instance.records.toList()
          : _fav.favoritesList;

  /// 按当前搜索词过滤后的列表
  List<Object> _filtered() {
    final kw = c.keyword.value.toLowerCase();
    final all = _allItems;
    if (kw.isEmpty) return all;
    return all.where((e) {
      final name = e is VodRecord ? e.vodName : (e as VodCollect).vodName;
      return name.toLowerCase().contains(kw);
    }).toList();
  }

  List<String> _visibleKeys() {
    final src = c.tab.value == 0 ? 'history' : 'fav';
    return _filtered().map((e) {
      final id = e is VodRecord ? e.vodId : (e as VodCollect).vodId;
      return ShelfController.keyOf(src, id);
    }).toList();
  }

  int get _columns {
    final p = PlayerPrefs.instance;
    return (c.tab.value == 0
            ? p.historyGridColumns.value
            : p.favGridColumns.value)
        .clamp(2, 6);
  }

  Future<void> _setColumns(int n) async {
    final p = PlayerPrefs.instance;
    if (c.tab.value == 0) {
      await p.setHistoryGridColumns(n);
    } else {
      await p.setFavGridColumns(n);
    }
  }

  // ============================================================
  // 网格
  // ============================================================

  Widget _buildGrid() {
    return Obx(() {
      final items = _filtered();
      final isFav = c.tab.value == 1;
      final kw = c.keyword.value;

      if (items.isEmpty) {
        if (kw.isNotEmpty) {
          return const EmptyState(
            title: '没有匹配的结果',
            message: '试试换个关键词',
            icon: Icons.search_off,
          );
        }
        return EmptyState(
          title: isFav ? '暂无收藏' : '暂无历史记录',
          message: isFav ? '收藏影片后会显示在这里' : '观看影片后会自动记录',
          icon: isFav ? Icons.favorite_border : Icons.history,
        );
      }

      // ⚠️ Obx 必须包住 LayoutBuilder：否则改列数（_columns 变了）时
      // builder 不会重建，布局切换看起来"没生效"。
      final cols = _columns;
      return LayoutBuilder(
        builder: (context, constraints) {
          final cardWidth =
              (constraints.maxWidth - AppTheme.cardSpacing * (cols - 1)) /
                  cols;
          // 图片约 1.5 倍高，与 VodCard.posterHeightRatio 配套
          final aspect = cardWidth / (cardWidth * 1.015 + 30);

          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.spacingLG,
              AppTheme.spacingSM,
              AppTheme.spacingLG,
              100, // 底部预留悬浮导航栏
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              childAspectRatio: aspect,
              crossAxisSpacing: AppTheme.cardSpacing,
              mainAxisSpacing: AppTheme.cardSpacing,
            ),
            itemCount: items.length,
            itemBuilder: (context, index) => _card(items[index], isFav),
          );
        },
      );
    });
  }

  Widget _card(Object item, bool isFav) {
    final shelf = ShelfController.instance;
    // 用模式匹配取出各字段，避免一遍遍 `as` 强转
    final (String vodId, String vodName, String vodPic, String sourceKey,
        String note) = switch (item) {
      VodRecord r => (r.vodId, r.vodName, r.vodPic, r.sourceKey, r.playNote),
      VodCollect f => (f.vodId, f.vodName, f.vodPic, f.sourceKey, ''),
      _ => ('', '', '', '', ''),
    };
    final key = ShelfController.keyOf(isFav ? 'fav' : 'history', vodId);

    return Obx(() {
      final editing = shelf.editing.value;
      return VodCard(
        video: Video(
          id: vodId,
          name: vodName,
          pic: vodPic,
          sourceKey: sourceKey,
          // 历史用 playNote 做角标（"第01集 00:20"）；收藏没有进度就不显示
          note: note,
        ),
        posterHeightRatio: 1.015,
        editMode: editing,
        selected: shelf.isSelected(key),
        onToggleSelect: () => shelf.toggleSelect(key),
        onDelete: () => switch (item) {
          VodRecord r => _his.deleteItem(r),
          VodCollect f => _fav.removeItem(f),
          _ => null,
        },
        onTap: editing
            ? () => shelf.toggleSelect(key)
            : () => switch (item) {
                  VodRecord r => _his.openHistory(r),
                  VodCollect f => _openFavorite(f),
                  _ => null,
                },
      );
    });
  }

  void _openFavorite(VodCollect item) {
    Get.toNamed('/detail', arguments: Video(
      id: item.vodId,
      name: item.vodName,
      pic: item.vodPic,
      sourceKey: item.sourceKey,
    ));
  }

  // ============================================================
  // 菜单 / 交互
  // ============================================================

  /// 切换布局：底部弹窗，**一行两个**（原来是一列）
  Future<void> _openLayoutSheet() async {
    final cur = _columns;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
              child: Text('每行显示',
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Text('${c.tab.value == 0 ? "历史" : "收藏"}的布局与另一页独立保存',
                  style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption)),
            ),
            // 一行两个：用 Row 分成两列
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                children: [
                  for (var row = 0; row < 4; row += 2)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        children: [
                          Expanded(child: _layoutCell(cur, row + 2, ctx)),
                          const SizedBox(width: 10),
                          Expanded(
                            child: row + 3 <= 7
                                ? _layoutCell(cur, row + 3, ctx)
                                : const SizedBox.shrink(),
                          ),
                        ],
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

  /// 布局选项格子（2~7 列，一行两个）
  Widget _layoutCell(int cur, int n, BuildContext ctx) {
    final selected = cur == n;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        Navigator.pop(ctx);
        await _setColumns(n);
        if (mounted) setState(() {}); // 立刻重算列数
      },
      child: Container(
        height: 62,
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.accentColor.withValues(alpha: 0.14)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
          border: Border.all(
            color: selected
                ? AppTheme.accentColor.withValues(alpha: 0.7)
                : AppTheme.glassBorderSoft,
            width: selected ? 1.2 : 0.6,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 用 n 个小方块直观示意列数
            for (var i = 0; i < n && i < 4; i++)
              Container(
                width: 9,
                height: 13,
                margin: const EdgeInsets.symmetric(horizontal: 1.5),
                decoration: BoxDecoration(
                  color: selected
                      ? AppTheme.accentColor
                      : AppTheme.textTertiary.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            const SizedBox(width: 10),
            Text('$n 列',
                style: TextStyle(
                    color: selected
                        ? AppTheme.accentColor
                        : AppTheme.textSecondary,
                    fontSize: AppTheme.fontSubhead,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.normal)),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFavSort() async {
    final v = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 18),
            for (final e in const [
              (0, '最近收藏在前'),
              (1, '最早收藏在前'),
              (2, '按片名排序'),
            ])
              ListTile(
                title: Text(e.$2,
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontSubhead)),
                trailing: Obx(() => c.favSort.value == e.$1
                    ? Icon(Icons.check,
                        size: 18, color: AppTheme.accentColor)
                    : const SizedBox.shrink()),
                onTap: () => Navigator.pop(ctx, e.$1),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (v == null) return;
    c.setFavSort(v);
    _fav.favSortMode.value = switch (v) {
      1 => FavSort.timeAsc,
      2 => FavSort.nameAsc,
      _ => FavSort.timeDesc,
    };
  }

  Future<void> _confirmClearAll() async {
    final isFav = c.tab.value == 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.glassRadius)),
        title: Text(isFav ? '清空收藏' : '清空历史',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(isFav ? '将取消全部收藏，确定？' : '将删除全部观看记录，确定？',
            style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消',
                style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (isFav) {
      await _fav.clearAll();
    } else {
      await _his.clearAll();
    }
    c.exitEdit();
  }

  Future<void> _confirmDeleteSelected() async {
    final n = c.selected.length;
    if (n == 0) return;
    final isFav = c.tab.value == 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.glassRadius)),
        title:
            Text('删除 $n 项', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(isFav ? '确定取消收藏选中的影片？' : '确定删除选中的观看记录？',
            style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消',
                style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final keys = c.selected.toList();
    if (isFav) {
      await deleteFavoriteItems(keys);
    } else {
      await deleteHistoryItems(keys);
    }
    c.exitEdit();
  }
}
