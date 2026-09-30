import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import 'controller.dart';
import '../favorites/view.dart';
import '../history/view.dart';

/// 「史藏」页 —— 播放历史 + 我的收藏
///
/// 合并原因：两个页面结构几乎相同（网格 + 搜索 + 布局切换），
/// 分成两个底部导航项时用户要在两处来回切；合并后用顶部 tab 切换。
///
/// ⚠️ 用 IndexedStack 而**不是** TabBarView：
/// TabBarView 会按需重建子页，导致搜索词、滚动位置丢失。
class ShelfPage extends StatefulWidget {
  const ShelfPage({super.key});

  @override
  State<ShelfPage> createState() => _ShelfPageState();
}

class _ShelfPageState extends State<ShelfPage> {
  final c = ShelfController.instance;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            _buildTabBar(),
            Expanded(
              child: IndexedStack(
                index: c.tab.value,
                children: const [HistoryPage(), FavoritesPage()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingXL, AppTheme.spacingLG, AppTheme.spacingXL, 0),
      child: Row(
        children: [
          Obx(() => _tabLabel('播放历史', c.tab.value == 0,
              () => c.tab.value = 0)),
          const SizedBox(width: 22),
          Obx(() => _tabLabel('我的收藏', c.tab.value == 1,
              () => c.tab.value = 1)),
          const Spacer(),
          // 右侧：编辑模式下显示「全选 / 删除(N) / 完成」
          Obx(() {
            if (!c.editing.value) {
              return _actionText('编辑', c.enterEdit);
            }
            final n = c.selected.length;
            final keys = _currentKeys();
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

  /// 当前 tab 下所有可见项的 key（供全选使用）
  List<String> _currentKeys() {
    if (c.tab.value == 0) {
      return historyVisibleKeys();
    }
    return favoritesVisibleKeys();
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

  /// 删除所有选中项（历史 / 收藏分别处理），带二次确认
  Future<void> _confirmDeleteSelected() async {
    final n = c.selected.length;
    if (n == 0) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.glassRadius)),
        title: Text('删除 $n 项',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
            c.tab.value == 0 ? '确定删除选中的观看记录？' : '确定取消收藏选中的影片？',
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
    if (c.tab.value == 0) {
      await deleteHistoryItems(keys);
    } else {
      await deleteFavoriteItems(keys);
    }
    c.exitEdit();
  }
}
