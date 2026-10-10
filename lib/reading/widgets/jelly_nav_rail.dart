import 'package:flutter/material.dart';

import '../../common/floating_nav_spec.dart';
import '../theme/jelly_palette.dart';
import '../theme/jelly_theme.dart';
import 'jelly_nav_bar.dart';

/// **iPad**（宽 ≥ 800 且短边 ≥ 600）下的**左侧竖向悬浮导航栏**。
///
/// ── 为什么加这个 ──────────────────────────────────────────────
/// 参考 cmbok：它宽窗（Windows 版）就是**左侧一列玻璃圆钮**，
/// 窄窗才是底部胶囊栏。我们抄的是这个**响应式形态**：
/// 同一批导航项，宽屏竖到左边 ⇒ 内容区多出整条竖向空间 ✓。
///
/// iPhone **不会用到本组件**（竖屏宽度不够、横屏短边不够，由 `home_page` 判定 ✓），
/// 所以对现有手机布局零影响。
///
/// 与底部栏（[JellyNavBar]）**同源同规格**：同一批 [JellyNavItem]、
/// 同一套取色（[FloatingNavSpec]）⇒ 横竖切换时外观一致，
/// 不会变成"两套风格" ✓。
class JellyNavRail extends StatelessWidget {
  const JellyNavRail({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.onLongPress,
    required this.items,
    this.palette,
  });

  final int currentIndex;
  final void Function(int index) onTap;
  final void Function(int index)? onLongPress;
  final List<JellyNavItem> items;

  /// 取色调色板。为 null 时用阅读自己的 [JellyTheme.palette]（同底栏语义 ✓）。
  final JellyPalette? palette;

  /// 整栏占位宽度（左外边距 + 胶囊 + 右侧留白）—— 调用方据此给内容让位 ✓
  static const double sideMargin = FloatingNavSpec.sideMargin;
  static const double pillWidth = 60;
  static const double gap = 4;
  static const double totalWidth = sideMargin + pillWidth + gap;

  /// 圆钮直径 / 圆钮间距（竖向排列，图标与底栏同尺寸避免抖动 ✓）
  static const double _itemSize = 42;
  static const double _itemGap = 6;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final pal = palette ?? JellyTheme.palette;
    return SizedBox(
      width: totalWidth,
      child: Padding(
        padding: const EdgeInsets.only(
          left: sideMargin,
          top: FloatingNavSpec.bottomMargin,
          right: gap,
          bottom: FloatingNavSpec.bottomMargin,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            // 与底部胶囊栏同一取色 / 圆角 / 阴影 ⇒ 换栏不换风格 ✓
            color: FloatingNavSpec.barColor(isDark, pal),
            borderRadius: BorderRadius.circular(FloatingNavSpec.radius),
            boxShadow: [
              BoxShadow(
                color: Colors.black
                    .withValues(alpha: FloatingNavSpec.shadowAlpha),
                blurRadius: FloatingNavSpec.shadowBlur,
                offset: FloatingNavSpec.shadowOffset,
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                vertical: FloatingNavSpec.innerPadV),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const SizedBox(height: _itemGap),
                  _railItem(items[i], i == currentIndex, isDark, pal, i),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 单个圆钮：选中 = 强调色低透明度圆形底 + 高对比图标（与底栏选中态一致 ✓）。
  /// 栏里放不下文字，标签走 [Tooltip] ✓。
  Widget _railItem(
    JellyNavItem item,
    bool selected,
    bool isDark,
    JellyPalette pal,
    int index,
  ) {
    final fg = selected
        ? FloatingNavSpec.selectedColor(isDark, pal)
        : FloatingNavSpec.unselectedColor(isDark, pal);
    return Tooltip(
      message: item.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onTap(index),
        onLongPress: onLongPress == null ? null : () => onLongPress!(index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          width: _itemSize,
          height: _itemSize,
          decoration: BoxDecoration(
            color: selected
                ? FloatingNavSpec.selectedItemBg(isDark, pal)
                : Colors.transparent,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: item.iconBuilder != null
                ? item.iconBuilder!(fg, FloatingNavSpec.iconSize)
                : item.emoji != null
                    ? Text(
                        item.emoji!,
                        style: TextStyle(
                          fontSize: FloatingNavSpec.iconSize,
                          height: 1.0,
                        ),
                      )
                    : Icon(
                        item.icon,
                        color: fg,
                        size: FloatingNavSpec.iconSize,
                      ),
          ),
        ),
      ),
    );
  }
}
