import 'package:flutter/material.dart';

import '../theme/jelly_theme.dart';
import 'jelly_ring_button.dart';

/// 顶栏「聚合菜单」按钮：一个图标按钮，点击弹出**只有图标**的下拉菜单栏。
///
/// 漫画页（源/历史/收藏/下载）、图书页（历史/收藏/下载/豆瓣排行）都收敛成
/// 这一个按钮 —— 菜单项是纯图标（无文字），点图标即执行动作并关闭。
/// 弹层复用 [JellyRingMenuPanel] 的贴底圆角面板，风格与指环菜单统一。
class JellyIconMenuButton extends StatelessWidget {
  const JellyIconMenuButton({
    super.key,
    required this.isDark,
    required this.actions,
    this.icon = Icons.more_horiz_rounded,
    this.tooltip = '更多',
    this.size = 36,
  });

  final bool isDark;

  /// 菜单项：图标 + 点击动作（纯图标，无文字标签）
  final List<({IconData icon, String tooltip, VoidCallback onTap})> actions;

  final IconData icon;
  final String tooltip;
  final double size;

  void _openMenu(BuildContext context) {
    if (actions.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      isScrollControlled: true,
      builder: (ctx) => JellyRingMenuPanel(
        isDark: isDark,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final a in actions)
                  InkWell(
                    onTap: () {
                      Navigator.pop(ctx);
                      a.onTap();
                    },
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: Tooltip(
                        message: a.tooltip,
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isDark
                                ? JellyTheme.primary.withValues(alpha: 0.22)
                                : JellyTheme.primary.withValues(alpha: 0.12),
                          ),
                          child: Icon(
                            a.icon,
                            size: 24,
                            color: isDark
                                ? Colors.white
                                : JellyTheme.textPrimaryLight,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fg = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: CircleBorder(
          side: BorderSide(
            color: fg.withValues(alpha: 0.30),
            width: 1.2,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openMenu(context),
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: Icon(icon, size: 20, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}
