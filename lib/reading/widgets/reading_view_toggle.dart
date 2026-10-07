import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../services/reading_layout.dart';
import '../theme/jelly_theme.dart';

/// 阅读模块统一的**视图切换按钮**（漫画 / 图书 / 书源 共用）。
///
/// 用户 2026-10-07 要求：
///   · 三个页面都要"宫格 / 列表"切换
///   · 宫格还要能选"一排 3 个 / 4 个 / 5 个"
///
/// 交互：点按钮弹出选择表 —— 列表 / 宫格·3列 / 宫格·4列 / 宫格·5列。
/// 这样"宫格↔列表"与"列数"是**同一组互斥选项**，不会出现
/// "既是列表又选了列数"的歧义状态。
class ReadingViewToggle extends StatelessWidget {
  const ReadingViewToggle({
    super.key,
    required this.isDark,
    required this.isGrid,
    required this.onChanged,
    this.tooltip = '切换视图',
  });

  final bool isDark;

  /// 当前是否宫格
  final bool isGrid;

  /// 选择回调：isGrid=是否宫格；columns=宫格列数（列表时忽略）
  final void Function(bool isGrid, int columns) onChanged;

  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openSheet(context),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // 与漫画页原按钮同款：浅色=黑圆白图标；深色=白圆深图标
              color: isDark ? Colors.white : const Color(0xFF17181C),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.14),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Center(
              child: Icon(
                isGrid ? Icons.grid_view_rounded : Icons.view_list_rounded,
                size: 20,
                color: isDark ? const Color(0xFF17181C) : Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openSheet(BuildContext context) async {
    final cols = ReadingLayout().columns;
    final picked = await showModalBottomSheet<Object>(
      context: context,
      backgroundColor: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        Widget tile({
          required IconData icon,
          required String label,
          required bool selected,
          required VoidCallback onTap,
        }) {
          return ListTile(
            leading: Icon(icon,
                color: selected ? JellyTheme.primary : JellyTheme.textSecondary),
            title: Text(
              label,
              style: TextStyle(
                fontSize: AppTheme.fontBody,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected
                    ? JellyTheme.primary
                    : (isDark ? Colors.white : JellyTheme.textPrimaryLight),
              ),
            ),
            trailing: selected
                ? Icon(Icons.check_rounded, color: JellyTheme.primary)
                : null,
            onTap: onTap,
          );
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                child: Row(
                  children: [
                    Icon(Icons.dashboard_customize_outlined,
                        size: 18, color: JellyTheme.textSecondary),
                    const SizedBox(width: 8),
                    Text('视图',
                        style: TextStyle(
                          fontSize: AppTheme.fontSubhead,
                          fontWeight: FontWeight.w700,
                          color: isDark
                              ? Colors.white
                              : JellyTheme.textPrimaryLight,
                        )),
                  ],
                ),
              ),
              tile(
                icon: Icons.view_list_rounded,
                label: '列表',
                selected: !isGrid,
                onTap: () => Navigator.pop(ctx, false),
              ),
              for (final n in const [3, 4, 5])
                tile(
                  icon: Icons.grid_view_rounded,
                  label: '宫格 · 一排 $n 个',
                  selected: isGrid && cols == n,
                  onTap: () => Navigator.pop(ctx, n),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (picked == null) return;
    if (picked is bool) {
      onChanged(false, ReadingLayout().columns);
    } else if (picked is int) {
      onChanged(true, picked);
    }
  }
}
