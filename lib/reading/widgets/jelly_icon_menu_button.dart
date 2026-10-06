import 'package:flutter/material.dart';

/// 顶栏「聚合菜单」按钮：一个图标按钮，点击在按钮**正下方**展开
/// **一列竖排圆形图标**（纯图标，一行一个圆，对齐 cmbok 顶栏样式）。
///
/// 漫画页（源/历史/收藏/下载）、图书页（历史/收藏/下载/豆瓣排行）都收敛成
/// 这一个按钮 —— 从按钮往下展开的竖列图标菜单（不再是底部弹出的横排面板）。
class JellyIconMenuButton extends StatefulWidget {
  const JellyIconMenuButton({
    super.key,
    required this.isDark,
    required this.actions,
    this.icon = Icons.more_horiz_rounded,
    this.tooltip = '更多',
    this.size = 32,
    this.menuWidth = 32,
  });

  final bool isDark;

  /// 菜单项：图标 + 点击动作（竖排，每个一行圆形图标；tooltip 做悬停提示）
  final List<({IconData icon, String tooltip, VoidCallback onTap})> actions;

  final IconData icon;
  final String tooltip;
  final double size;
  final double menuWidth;

  @override
  State<JellyIconMenuButton> createState() => _JellyIconMenuButtonState();
}

class _JellyIconMenuButtonState extends State<JellyIconMenuButton> {
  /// 挂在实际圆形按钮上，菜单锚点以此为准。
  ///
  /// ⚠️ 不能用 `context.findRenderObject()`：StatelessWidget/State 的
  /// context 没有自己的 RenderObject，findRenderObject 会**下钻到子树里
  /// 第一个 RenderObject**（可能是 Tooltip 内部结构），拿到的全局坐标
  /// 会偏到旁边按钮的位置 —— 表现就是菜单从「筛选」图标下方弹出
  /// 而不是从本按钮正下方弹出。GlobalKey 直接钉住 36×36 的圆。
  final GlobalKey _btnKey = GlobalKey();

  void _openMenu() {
    final actions = widget.actions;
    if (actions.isEmpty) return;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final box = _btnKey.currentContext?.findRenderObject() as RenderBox?;
    if (overlay == null || box == null) return;
    // 按钮右下角全局坐标：菜单右缘对齐按钮右缘、从按钮正下方往下展开
    final pos = box.localToGlobal(Offset.zero);
    showMenu<void>(
      context: context,
      // 语义明确的 RelativeRect.fromRect：菜单矩形 = (按钮右缘-菜单宽,
      // 按钮底部+6, 菜单宽, 初始高 40)，容器 = 整个 overlay
      position: RelativeRect.fromRect(
        Rect.fromLTWH(
          pos.dx + box.size.width - widget.menuWidth,
          pos.dy + box.size.height + 6,
          widget.menuWidth,
          40,
        ),
        Offset.zero & overlay.size,
      ),
      // 菜单框透明：竖排圆图标直接悬浮在页面上（图标自身带阴影），
      // 没有背景框 / 圆角 / 容器阴影
      color: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
      ),
      elevation: 0,
      shadowColor: Colors.transparent,
      items: [
        for (final a in actions)
          PopupMenuItem<void>(
            height: 40,
            padding: EdgeInsets.zero,
            onTap: a.onTap,
            child: Tooltip(
              message: a.tooltip,
              child: Center(
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    // 参考样式：黑色实心圆 + 白色图标；深色模式反转为白圆 + 深色图标
                    color: widget.isDark
                        ? Colors.white
                        : const Color(0xFF17181C),
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
                    size: 17,
                    color: widget.isDark
                        ? const Color(0xFF17181C)
                        : Colors.white,
                  ),
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
    final filled = widget.isDark ? Colors.white : const Color(0xFF17181C);
    final fg = widget.isDark ? const Color(0xFF17181C) : Colors.white;
    return Tooltip(
      message: widget.tooltip,
      child: Material(
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _openMenu,
          child: Container(
            key: _btnKey,
            width: widget.size,
            height: widget.size,
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
              child: Icon(widget.icon, size: 18, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}
