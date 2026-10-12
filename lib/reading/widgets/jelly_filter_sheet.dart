import 'package:flutter/material.dart';

import '../theme/jelly_theme.dart';
import '../../common/theme.dart';

/// 阅读模块「分类筛选」弹窗的统一视觉件（漫画页 / 图书页 / 书源页共用）。
///
/// ✅ 用户 2026-10-12「筛选分类弹窗太丑」：三个页面原来各写一套
///   （圆角 20 / 标题下压 Divider / 裸 IconButton 关闭 / chip 三种样式）✗。
///   收敛到这里：**24 圆角 + 把手 + 圆形关闭钮 + 统一 chip**
///   （选中 = 主题色实底 + 投影，未选中 = 表面色 + 细边框）。
///   改一处，三个弹窗同步生效。

/// 统一弹窗圆角（顶部 24）
const RoundedRectangleBorder jellySheetShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
);

/// 统一把手颜色（配合 `showDragHandle: true` 使用）
Color jellySheetHandleColor(bool isDark) => isDark
    ? Colors.white.withValues(alpha: 0.22)
    : Colors.black.withValues(alpha: 0.16);

/// 自绘拖拽把手（36×4 圆角小条，水平居中）。
///
/// 🔴 不用 `showDragHandle: true`：`showModalBottomSheet` **没有**
///   `dragHandleColor` 参数（那是 `BottomSheetThemeData` 的属性），
///   默认把手颜色在深色主题下几乎不可见 —— 自绘最可控，还能让
///   三个弹窗的把手位置/尺寸完全一致。
class JellySheetHandle extends StatelessWidget {
  const JellySheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(top: 10, bottom: 8),
        decoration: BoxDecoration(
          color: jellySheetHandleColor(isDark),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// 未选中 chip 底色
Color jellyChipColor(bool isDark) => isDark
    ? Colors.white.withValues(alpha: 0.06)
    : JellyTheme.primary.withValues(alpha: 0.05);

/// 未选中 chip 文字色
Color jellyChipTextColor(bool isDark) =>
    isDark ? Colors.white70 : JellyTheme.textSecondary;

/// 小节标题：主题色竖条 + 加粗小字（弹窗内「维度/分组」标题统一用它）
class JellySheetSectionTitle extends StatelessWidget {
  const JellySheetSectionTitle({
    super.key,
    required this.title,
    required this.isDark,
  });

  final String title;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 12,
          decoration: BoxDecoration(
            color: JellyTheme.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          title,
          style: TextStyle(
            fontSize: AppTheme.fontSubhead,
            fontWeight: FontWeight.w700,
            color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
          ),
        ),
      ],
    );
  }
}

/// 统一筛选 chip：选中 = 主题色实底 + 投影；未选中 = 表面色 + 细边框。
///
/// ✅ 用户 2026-10-12「筛选卡片太大、文字显小」：内边距 14×7 → 10×5、
///   圆角 12 → 10，卡片更紧凑、文字占比更高（三个页面共用，全局生效）。
class JellyFilterChip extends StatelessWidget {
  const JellyFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? JellyTheme.primary : jellyChipColor(isDark),
          borderRadius: BorderRadius.circular(10),
          border: selected
              ? null
              : Border.fromBorderSide(BorderSide(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.12)
                      : Colors.black.withValues(alpha: 0.07),
                )),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: JellyTheme.primary.withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: AppTheme.fontSubhead,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? Colors.white : jellyChipTextColor(isDark),
          ),
        ),
      ),
    );
  }
}

/// 弹窗标题行的圆形动作按钮（关闭 / 刷新等，32 圆底 + 17 图标）
class JellySheetCircleButton extends StatelessWidget {
  const JellySheetCircleButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.isDark = false,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool isDark;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: isDark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.black.withValues(alpha: 0.045),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 32,
          height: 32,
          child: Icon(
            icon,
            size: 17,
            color: isDark ? Colors.white70 : JellyTheme.textSecondary,
          ),
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}
