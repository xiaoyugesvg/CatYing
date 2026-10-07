import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/jelly_theme.dart';

/// 右上角「环形滑动图标组」。
///
/// ── 行为（用户指定）──────────────────────────────────────────
///   · **横向拖动**：图标**循环拨动**（像转盘）—— 拨过最后一个会接回
///     第一个，**没有尽头**，不是滑到头就停
///   · **松手**：吸附到最近的槽位；带水平速度时按惯性多拨几格
///   · **点按**：选中该图标并执行它的动作
///   · **长按**：展开成**竖列**，每个图标变成独立圆形按钮
///   · 空白处点一下 / 再点已选中：收起
///
/// ── 「环形」是怎么做出来的（关键）───────────────────────────
/// 每个图标相对**连续位置**算一个**环形最短距离**：
/// ```
/// d = ((i - spin) mod n)   再折到 [-n/2, n/2)
/// ```
/// `d` 就是"往左/往右拨几格"的最短走法。于是最后一项的左边天然是
/// 第一项，拨动无限循环，**不需要真的复制两份图标**。
///
/// ⚠️ 滑块式的旧实现是 `left = i * (itemSize + gap)`：
/// 宽度随图标数增长、到末尾就停住（用户反馈"应该能循环拨动"）。
///
/// ── 为什么用普通 double 而不是 AnimationController.value ──────
/// `AnimationController` 的 value 会被 **clamp 在 lowerBound..upperBound**。
/// 环形位置要能变成任意实数（拨过头到 -3、+7 都合法）——
/// 所以位置存在普通字段 [_spin] 里，控制器只当**重绘时钟**用。
/// （我第一版就是直接把位置写进 controller.value，被 clamp 卡住。）
///
/// ── 为什么位置/背景/间距都按进度插值 ──────────────────────────
/// 如果横排和竖列各写一套图标，展开时会**瞬间跳变**（旧的消失、新的出现），
/// 看起来像两个无关的控件。这里只创建**一份**图标，
/// `位置 = lerp(环形槽位, 竖列槽位, t)`，于是展开就是同一批图标在连续移动。
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

  /// 未展开时整块的宽度（固定值：环形拨动不改变宽度）
  final double width;
  final double itemSize;

  /// 横排图标之间的间距（环形槽位用它算步长）
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
    with TickerProviderStateMixin {
  // ⚠️ 这里**不能**写成 `late final ... = AnimationController(...)`。
  // 那样是"首次访问才创建"。而 build 在 actions 为空时会提前返回，
  // 于是 controller 从未被创建 —— 等到 dispose() 再访问它，
  // 会去查已经失效的祖先（TickerMode），抛
  // "Looking up a deactivated widget's ancestor is unsafe"。
  // 正确做法：在 initState 里**无条件**创建。
  late final AnimationController _c;

  /// 环形拨动的**连续位置**（可为任意实数，含负数）。
  ///
  /// 0 = 第 0 项在中心；1.7 = 第 1 项向第 2 项拨了 70%。
  /// 存在普通字段里是因为 [AnimationController] 会把 value clamp 到
  /// lowerBound..upperBound，装不下"拨过头"的位置。
  double _spin = 0;

  /// 拖动基准：按下瞬间的 _spin（拖动中用它 + 累计位移）
  double? _dragBase;
  double _dragDelta = 0;

  bool get _expanded => _c.value > 0.5;

  int get _n => widget.actions.length;

  /// 中心是哪一项（环形取模，负数也正确）
  int get _sel {
    if (_n == 0) return 0;
    final r = _spin.round() % _n;
    return r < 0 ? r + _n : r;
  }

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _c.addListener(_onTick);
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _c.removeListener(_onTick);
    _c.dispose();
    super.dispose();
  }

  // ── 展开 / 收起 ──────────────────────────────────────────────

  void _toggle() {
    if (_expanded) {
      _c.reverse();
    } else {
      _c.forward();
    }
  }

  // ── 环形拨动（动画到某个位置）───────────────────────────────

  AnimationController? _spinCtrl;

  /// 从当前位置平滑拨到 [to]
  ///
  /// 用**独立**的临时 controller（每次拨动新建、结束即 dispose）：
  /// 主 `_c` 只管展开进度，两个动画能同时跑（边展开边拨）。
  void _animateSpinTo(double to) {
    _spinCtrl?.dispose();
    final from = _spin;
    if ((to - from).abs() < 0.001) {
      _spin = to;
      if (mounted) setState(() {});
      return;
    }
    // 时长随距离增长（拨 3 格比 1 格慢一点，但不线性）
    final ms = (170 + (to - from).abs() * 70).round().clamp(120, 480);
    final ctrl = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: ms),
    );
    _spinCtrl = ctrl;
    final anim = Tween<double>(begin: from, end: to).animate(
      CurvedAnimation(parent: ctrl, curve: Curves.easeOutCubic),
    );
    anim.addListener(() {
      if (!mounted) return;
      setState(() => _spin = anim.value);
    });
    ctrl.addStatusListener((s) {
      if (s == AnimationStatus.completed || s == AnimationStatus.dismissed) {
        if (identical(_spinCtrl, ctrl)) _spinCtrl = null;
        ctrl.dispose();
      }
    });
    ctrl.forward();
  }

  void _onTap(int index) {
    if (_expanded) {
      widget.actions[index].onPressed();
      _c.reverse();
      return;
    }
    // 未展开：点按 = 拨到这一项并执行它的动作
    widget.actions[index].onPressed();
    // 取环形最近的等价位置（例如当前 0、点第 3 项且 n=4 → 拨 -1 更近）
    _animateSpinTo(_nearestEquivalent(index));
  }

  /// 把 [index] 映射成"离当前 _spin 最近的等价位置"
  ///
  /// n=4、_spin=0、index=3 时：3 和 -1 是同一项，选 -1（只拨 1 格，
  /// 而不是往回拨 3 格）。这就是"环形"在动画上的体现。
  double _nearestEquivalent(int index) {
    if (_n == 0) return _spin;
    final base = _spin.roundToDouble();
    // 在 base 附近找与 index 同余（mod n）的位置
    final k = ((base - index) / _n).round();
    return index + k * _n.toDouble();
  }

  // ── 拖动 ────────────────────────────────────────────────────

  void _onDragStart(DragStartDetails d) {
    _spinCtrl?.dispose();
    _spinCtrl = null;
    _dragBase = _spin;
    _dragDelta = 0;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    final base = _dragBase;
    if (base == null) return;
    final step = widget.itemSize + widget.gap;
    if (step <= 0) return;
    // 手指往左移（primaryDelta < 0）= 内容跟手往前拨
    _dragDelta += -(d.primaryDelta ?? 0) / step;
    setState(() => _spin = base + _dragDelta);
  }

  /// 松手：吸附到最近槽位；有水平速度就按惯性多拨几格
  void _onDragEnd(DragEndDetails d) {
    _dragBase = null;
    final v = d.velocity.pixelsPerSecond.dx;
    final step = widget.itemSize + widget.gap;
    // 惯性格数：速度 / 每格像素，限幅 ±3
    final fling = step <= 0 ? 0 : (-v / 900).round().clamp(-3, 3);
    _animateSpinTo(_spin.roundToDouble() + fling);
  }

  void _onDragCancel() {
    _dragBase = null;
    _animateSpinTo(_spin.roundToDouble());
  }

  // ── 渲染 ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final n = _n;
    // 空列表（例如按权限过滤后没剩动作）：退化成零尺寸，不要渲染空 Stack
    if (n == 0) {
      return const SizedBox(key: Key('jelly-sliding-actions-empty'));
    }

    final itemSize = widget.itemSize;
    final colHeight =
        n * (itemSize + widget.buttonExtra) + (n - 1) * widget.expandedSpacing;
    final width = math.max(widget.width, itemSize + widget.buttonExtra);

    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = Curves.easeOutCubic.transform(_c.value);
        final height = itemSize + (colHeight - itemSize) * t;

        return SizedBox(
          width: width,
          height: height,
          child: GestureDetector(
            behavior: HitTestBehavior.deferToChild,
            onLongPress: _toggle,
            onHorizontalDragStart: _onDragStart,
            onHorizontalDragUpdate: _onDragUpdate,
            onHorizontalDragEnd: _onDragEnd,
            onHorizontalDragCancel: _onDragCancel,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
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
                for (int i = 0; i < n; i++)
                  _buildItem(i, t, n, itemSize, width),
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
    final step = itemSize + widget.gap;
    final half = n / 2;

    // ── 环形槽位 ────────────────────────────────────────────────
    // 相对连续位置 _spin 的环形最短距离，落在 [-half, half)
    //
    // ⚠️ 偶数个图标时"正对面"那一项（dist == ±half）会算到同一个位置，
    // 两个图标重叠。这里加一个 tie-break：**对面统一算到正的一侧**，
    // 于是它只画一次、不会和另一项叠在一起。
    var dist = (i - _spin) % n.toDouble();
    if (dist < 0) dist += n.toDouble();
    if (dist > half) dist -= n.toDouble();

    // ⚠️ 可见性判定必须在 tie-break **之前**。
    // 我第一版先做 tie-break（把 -half 改成 +half）再判可见性：
    // `abs() > half` 于是不再成立（2 > 2 为 false）→ 正对面那一项被画出来，
    // 而且与真正的 +half 那项**位置重合**（测试里表现为 4 个图标全在）。
    //
    // 环形是转盘：一次只看得到**半个环**（含中心）。超出的一律不画 ——
    // 这是"能无限循环拨动"的固有代价，不是 bug。
    if (dist.abs() >= half) return const SizedBox.shrink();

    final collapsedLeft = (width - itemSize) / 2 + dist * step;

    // ── 竖列槽位（右对齐）──
    final expandedLeft = width - btn;
    final expandedTop = i * (btn + widget.expandedSpacing);

    final left = _lerp(collapsedLeft, expandedLeft, t);
    final top = _lerp(0.0, expandedTop, t);

    // ⚠️ 用户 2026-10-07：「滑动的时候是一个个显示，不是三一起显示哈」✗→✓
    //   原来只是"越靠环边缘越淡"、且下限 0.25 ⇒ 收起态会同时露出**三个**图标 ✗
    //   现在：收起态**只留中心那一个**，距中心 ≥0.5 的一律全透明；
    //   0 → 0.5 之间线性淡出，滑动时能看清"交接"过程 ✓
    final slotFade =
        t > 0.5 ? 1.0 : (1.0 - dist.abs() * 2).clamp(0.0, 1.0);

    final bg = Color.lerp(
      _selectedBg(a, i),
      // 展开态：浅色主题取主题深色（白图标可读），深色主题用微亮中性面
      widget.isDark
          ? Colors.white.withValues(alpha: 0.12)
          : JellyTheme.primaryDark,
      t,
    )!;

    return Positioned(
      left: left,
      top: top,
      child: Opacity(
        opacity: slotFade,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius:
                BorderRadius.circular(t > 0.5 ? btn / 2 : itemSize / 2.6),
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
                    : (widget.isDark
                        ? Colors.white
                        : JellyTheme.textPrimaryLight),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 未展开时**只有中心那一项**有底色。
  ///
  /// ⚠️ 旧实现是 `a.icon == widget.actions[_selected].icon` ——
  /// **用图标比较**。一旦两个动作用了同一个图标（很常见，比如两处都
  /// 放"下载"），两个都会亮，`_selected` 指向哪个也说不清。
  /// 现在用**下标**判定，与环形中心一致。
  Color _selectedBg(JellyAction a, int i) {
    if (a.highlight || i == _sel) {
      // 选中底：深色模式微亮中性面，浅色模式主色淡染（图标为深色，仍可读）
      return widget.isDark
          ? Colors.white.withValues(alpha: 0.14)
          : JellyTheme.primary.withValues(alpha: 0.12);
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
