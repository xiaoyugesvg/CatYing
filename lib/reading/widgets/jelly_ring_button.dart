import 'package:flutter/material.dart';

import '../theme/jelly_theme.dart';

/// 顶栏右上角「指环」切换按钮 —— 圆形 + 环状描边，点击弹出切换菜单面板。
///
/// 参考用户截图：顶栏右上角一个"指环"样式的按钮，点开是切换菜单
/// （视图网格/列表、分类筛选、常用操作）。菜单内容由 [menuBuilder] 提供，
/// 各页传入自己的切换项；面板统一用 [JellyRingMenuPanel] 承载。
class JellyRingButton extends StatelessWidget {
  const JellyRingButton({
    super.key,
    required this.isDark,
    required this.menuBuilder,
    this.icon = Icons.tune_rounded,
    this.size = 36,
    this.tooltip = '切换菜单',
  });

  final bool isDark;
  final Widget Function(BuildContext context) menuBuilder;
  final IconData icon;
  final double size;
  final String tooltip;

  void _openMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      isScrollControlled: true,
      builder: (ctx) => SafeArea(top: false, child: menuBuilder(ctx)),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 环：一圈细描边（指环感），浅色用墨色、深色用白色
    final ring = isDark
        ? Colors.white.withValues(alpha: 0.30)
        : JellyTheme.textPrimaryLight.withValues(alpha: 0.45);
    final fg = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: CircleBorder(side: BorderSide(color: ring, width: 1.5)),
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

/// 指环菜单面板容器：顶部圆角 28、JellyTheme 卡片底色、可选标题。
/// 各页把「视图切换 / 分类 / 常用操作」装进来。
class JellyRingMenuPanel extends StatelessWidget {
  const JellyRingMenuPanel({
    super.key,
    required this.isDark,
    this.title,
    this.children = const [],
  });

  final bool isDark;
  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final fg = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          // 拖拽把手
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: fg.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          if (title != null) ...[
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                title!,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: fg,
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

/// 指环菜单里的「标签 + 右侧控件」行（视图切换、分类筛选等用）。
class JellyRingMenuRow extends StatelessWidget {
  const JellyRingMenuRow({
    super.key,
    required this.isDark,
    required this.label,
    required this.child,
  });

  final bool isDark;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final fg = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
          const Spacer(),
          child,
        ],
      ),
    );
  }
}

/// 指环菜单里的「图标操作行」（浏览记录/收藏/下载/源仓库这类入口）。
class JellyRingMenuActions extends StatelessWidget {
  const JellyRingMenuActions({
    super.key,
    required this.isDark,
    required this.actions,
  });

  final bool isDark;
  final List<({IconData icon, String label, VoidCallback onTap})> actions;

  @override
  Widget build(BuildContext context) {
    final fg = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final a in actions)
            InkWell(
              onTap: a.onTap,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: fg.withValues(alpha: 0.18),
                          width: 1.2,
                        ),
                      ),
                      child: Icon(a.icon, size: 20, color: fg),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      a.label,
                      style: TextStyle(
                        fontSize: 11,
                        color: fg.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
