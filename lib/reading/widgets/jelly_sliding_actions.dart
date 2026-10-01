import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/jelly_theme.dart';

/// 右上角「滑动图标组」。
///
/// ── 行为（用户截图指定）──────────────────────────────────────
///   · **点按**：在图标之间「滑动切换」—— 圆角指示器滑到被点的图标上
///   · **长按**：展开成**竖列**，每个图标变成独立圆形按钮（如截图那样）
///   · 空白处点一下 / 再点已选中的图标：收起
///
/// ── 为什么要做成一整块可以"形变"的东西 ────────────────────────
/// 如果横排和竖列各写一套图标，展开时会**瞬间跳变**（旧的消失、新的出现），
/// 看起来像两个无关的控件。
/// 这里只创建 **一份** 图标，位置/背景/间距全部**按进度插值**：
///   位置 = lerp(横排槽位, 竖列槽位, t)
///   背景 = lerp(指示器胶囊, 实心圆, t)
/// 于是展开/收起就是同一批图标在**连续移动**，和截图里的观感一致。
///
/// 关键点：必须**固定**「横排槽位」的坐标（[width] 要等于未展开时的宽度），
/// 否则展开后宽度变了，收起时会从错误的位置滑回去。
class JellySlidingActions extends StatefulWidget {
  const JellySlidingActions({
    super.key,
    required this.actions,
    required this.isDark,
    this.width = 116,
    this.itemSize = 38,
    this.gap = 4,
    this.buttonExtra = 8,
    this.expandedSpacing = 10,
    this.iconSize = 19,
    this.right = 0,
    this.top = 0,
  });

  final List<JellyAction> actions;
  final bool isDark;

  /// 未展开时整块的宽度（固定值，见上面的说明）
  final double width;
  final double itemSize;

  /// 横排图标之间的基础间距（点按滑动用）
  final double gap;

  /// 每个按钮比图标大出来的部分
  final double buttonExtra;

  /// 展开后竖列图标之间的间距
  final double expandedSpacing;
  final double iconSize;
  final double right;
  final double top;

  @override
  State<JellySlidingActions> createState() => _JellySlidingActionsState();
}

class _JellySlidingActionsState extends State<JellySlidingActions>
    with SingleTickerProviderStateMixin {
  // ⚠️ 这里**不能**写成 `late final ... = AnimationController(...)`。
  // 那样是"首次访问才创建"。而 build 在 actions 为空时会提前返回，
  // 于是 controller 从未被创建 —— 等到 dispose() 再访问它，
  // 会去查已经失效的祖先（TickerMode），抛
  // "Looking up a deactivated widget's ancestor is unsafe"。
  // 正确做法：在 initState 里**无条件**创建。
  late final AnimationController _c;

  int _selected = 0;
  bool get _expanded => _c.value > 0.5;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _toggle() {
    if (_expanded) {
      _c.reverse();
    } else {
      _c.forward();
    }
  }

  void _onTap(int index) {
    if (_expanded) {
      setState(() => _selected = index);
      widget.actions[index].onPressed();
      _c.reverse();
    } else {
      // 未展开：点按 = 滑动切换选中项（并执行它）
      setState(() => _selected = index);
      widget.actions[index].onPressed();
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.actions.length;
    // 空列表（例如按权限过滤后没剩动作）：退化成零尺寸，不要渲染空 Stack
    if (n == 0) {
      return const SizedBox(key: Key('jelly-sliding-actions-empty'));
    }

    final itemSize = widget.itemSize;
    // 图标在未展开时的位置：整块居中排布
    final colHeight = n * (itemSize + widget.buttonExtra) +
        (n - 1) * widget.expandedSpacing;

    // 未展开时的高度用 itemSize（紧凑），展开后要能容纳竖列
    final width = math.max(widget.width, itemSize + widget.buttonExtra);

    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = Curves.easeOutCubic.transform(_c.value);
        // 高度随展开增长（保证父级 Row/Stack 不会把展开的竖列裁掉）
        final height = itemSize + (colHeight - itemSize) * t;

        return SizedBox(
          width: width,
          height: height,
          child: GestureDetector(
            behavior: HitTestBehavior.deferToChild,
            onLongPress: _toggle,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // 展开时点击空白处收起
                if (t > 0.01)
                  Positioned(
                    left: -400,
                    right: -80,
                    top: -20,
                    bottom: -20,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: _toggle,
                      child: const SizedBox.expand(),
                    ),
                  ),
                for (int i = 0; i < n; i++) _buildItem(i, t, n, itemSize, width),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildItem(int i, double t, int n, double itemSize, double width) {
    final a = widget.actions[i];
    final btn = itemSize + widget.buttonExtra;

    // ── 横排槽位 ──
    final collapsedLeft =
        (width - (n * itemSize + (n - 1) * widget.gap)) / 2 + i * (itemSize + widget.gap);
    // ── 竖列槽位（右对齐）──
    final expandedLeft = width - btn;
    final expandedTop = i * (btn + widget.expandedSpacing);

    final left = _lerp(collapsedLeft, expandedLeft, t);
    final top = _lerp(0.0, expandedTop, t);

    final bg = Color.lerp(
      _selectedBg(a),
      widget.isDark ? const Color(0xFF3A3A3C) : const Color(0xFF2C2C2E),
      t,
    )!;

    return Positioned(
      left: left,
      top: top,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(t > 0.5 ? btn / 2 : itemSize / 2.6),
          onTap: () => _onTap(i),
          onLongPress: _toggle,
          child: Container(
            width: t > 0.5 ? btn : itemSize,
            height: t > 0.5 ? btn : itemSize,
            decoration: BoxDecoration(
              color: bg,
              shape: t > 0.5 ? BoxShape.circle : BoxShape.rectangle,
              borderRadius:
                  t > 0.5 ? null : BorderRadius.circular(itemSize / 2.6),
            ),
            child: Icon(
              a.icon,
              size: widget.iconSize,
              color: t > 0.5
                  ? Colors.white
                  : (widget.isDark ? Colors.white : JellyTheme.textPrimaryLight),
            ),
          ),
        ),
      ),
    );
  }

  /// 未展开时：只有选中项有底色（滑动指示器）
  Color _selectedBg(JellyAction a) {
    if (a.highlight || a.icon == widget.actions[_selected].icon) {
      return widget.isDark ? const Color(0xFF3A3A3C) : const Color(0xFFD9D9D9);
    }
    return Colors.transparent;
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;
}

/// 一个动作项
class JellyAction {
  const JellyAction({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.highlight = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;

  /// 未展开时是否也显示底色
  final bool highlight;
}
