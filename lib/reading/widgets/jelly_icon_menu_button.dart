import 'package:flutter/material.dart';

import '../theme/jelly_theme.dart';

/// 顶栏「聚合菜单」按钮：一个图标按钮，点击在按钮**正下方**展开
/// **一列竖排圆形图标**（纯图标，一行一个圆，对齐 cmbok 顶栏样式）。
///
/// 漫画页（源/历史/收藏/下载）、图书页（历史/收藏/下载/豆瓣排行）都收敛成
/// 这一个按钮 —— 从按钮往下展开的竖列图标菜单（不再是底部弹出的横排面板）。
class JellyIconMenuButton extends StatelessWidget {
  const JellyIconMenuButton({
    super.key,
    required this.isDark,
    required this.actions,
    this.icon = Icons.more_horiz_rounded,
    this.tooltip = '更多',
    this.size = 36,
    this.menuWidth = 68,
  });

  final bool isDark;

  /// 菜单项：图标 + 点击动作（竖排，每个一行圆形图标；tooltip 做悬停提示）
  final List<({IconData icon, String tooltip, VoidCallback onTap})> actions;

  final IconData icon;
  final String tooltip;
  final double size;
  final double menuWidth;

  void _openMenu(BuildContext context) {
    if (actions.isEmpty) return;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final box = context.findRenderObject() as RenderBox?;
    if (overlay == null || box == null) return;
    // 按钮右下角坐标：菜单右缘对齐按钮右缘，从按钮正下方往下展开
    final pos = box.localToGlobal(Offset(box.size.width, box.size.height));
    showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(
        pos.dx - menuWidth,
        pos.dy + 6,
        overlay.size.width - pos.dx,
        0,
      ),
      color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      elevation: 12,
      shadowColor: Colors.black.withValues(alpha: 0.18),
      items: [
        for (final a in actions)
          PopupMenuItem<void>(
            height: 50,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            onTap: a.onTap,
            child: Tooltip(
              message: a.tooltip,
              child: Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // 参考样式：黑色实心圆 + 白色图标；深色模式反转为白圆 + 深色图标
                  color: isDark ? Colors.white : const Color(0xFF17181C),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.14),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Icon(
                  a.icon,
                  size: 21,
                  color: isDark ? const Color(0xFF17181C) : Colors.white,
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // 参考样式：黑色实心圆 + 白色图标（浅色）；深色模式白圆 + 深色图标
    final filled = isDark ? Colors.white : const Color(0xFF17181C);
    final fg = isDark ? const Color(0xFF17181C) : Colors.white;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openMenu(context),
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: filled,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.14),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Center(
              child: Icon(icon, size: 20, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}
