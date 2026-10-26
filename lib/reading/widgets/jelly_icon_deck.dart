/// 右上角「叠图标」控件 —— 用户 2026-10-07 明确要求的形态：
///
/// > 看起来只有一个图标，然后这个图标右侧有点其余图标重叠那种，
/// > 就是几个图标重叠滑动，但是图标又不相互全盖住
/// > 展开也是长按后**竖向**展开，**横向不展开**，就是这么一个叠一个图标叠在一起、
/// > **左右滑动切换**的控件
///
/// ── 解决什么 ────────────────────────────────────────────────────
/// 漫画 / 图书 / 书源 三个页面右上角原本是**并排 3 个 IconButton**：
/// 每个都带默认 48px 的 padding + splash 半径 ⇒ 视觉上"占太宽" ✗，
/// 而且三个图标长得像 ⇒ 用户觉得"左右都有隐藏的一样" ✗。
///
/// 现在改成**一叠**：
/// · 收起态宽度 ≈ `size + 2 * overlap`（默认 40 + 2×14 = **68px**，
///   而原来三个并排要 ~144px ✓）；
/// · 每个图标沿 X 轴错开 `overlap`，**互相压住一部分但不全盖住** ✓；
/// · 最前面那个用**深色圆底**强调（截图里那个深色圆底时钟就是这个位置 ✓）；
/// · **左右滑动** ⇒ 循环切换谁在最前（`_front` 变化，带动画 ✓）；
/// · **下滑 / 长按** ⇒ 其余的图标**悬浮在第一个图标下面**（可直接点各图标 ✓），
///   松手/点空白收回 ✓。
///
/// ── ⚠️ 展开必须是"悬浮"，不能改自己的尺寸（用户 2026-10-14）──────
/// 这个控件挂在顶栏里（`Row` / `AppBar.actions`，交叉轴都是**居中**）。
/// 曾经展开时把自己从 46px 拉高到 ~190px ⇒ 整行变高 ⇒ 居中的标题 /
/// 搜索 / 筛选**被整体顶下去**（用户截图："不是这样呀呀呀"）✗。
/// 现在展开的图标挂在 **Overlay** + `CompositedTransformFollower` 上，
/// 自身尺寸**一个像素都不变** ✓ ⇒ 布局稳定、且浮层照样能点 ✓。
///
/// ── 用法 ────────────────────────────────────────────────────────
/// ```dart
/// JellyIconDeck(items: [
///   JellyIconDeckItem(icon: Icons.history_rounded, tooltip: '历史',
///       onTap: () => _openHistory()),
///   JellyIconDeckItem(icon: Icons.download_rounded, tooltip: '下载', onTap: ...),
///   JellyIconDeckItem(icon: Icons.more_horiz_rounded, tooltip: '更多', onTap: ...),
/// ])
/// ```
library;

import 'package:flutter/material.dart';

import 'package:tvbox/reading/theme/jelly_theme.dart';

/// 叠图标里的一项。
class JellyIconDeckItem {
  const JellyIconDeckItem({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
}

class JellyIconDeck extends StatefulWidget {
  const JellyIconDeck({
    super.key,
    required this.items,
    this.size = 40,
    // ⚠️ 叠层步进：**越小叠得越紧**。
    // 原来 14 ⇒ 4 张共 40+3×14 = **82px**，加上左边筛选按钮 40px + 间距，
    // 在手机顶栏一行里放不下 ⇒ 最后一张被屏幕边缘**裁掉** ✗
    // 收到 9 ⇒ 4 张共 **67px**，能完整放下，同时每张仍清楚露出一条边 ✓
    this.overlap = 9,
  }) : assert(items.length > 0, '至少要有一个图标');

  final List<JellyIconDeckItem> items;

  /// 单个图标的热区/圆底尺寸（**≥40** 保证好点 ✓）。
  final double size;

  /// 相邻图标沿 X 轴的重叠步进（越小叠得越紧 ✓）。
  final double overlap;

  @override
  State<JellyIconDeck> createState() => _JellyIconDeckState();
}

class _JellyIconDeckState extends State<JellyIconDeck> {
  /// 谁在最前面。
  int _front = 0;

  /// 是否已展开（另外几个图标正悬浮在第一个图标下面）。
  bool _expanded = false;

  /// 手指横向拖动的累计位移（px）。
  ///
  /// 让卡片**跟手滑动**（而不是"松手才跳一下"）：
  /// 拖动时整叠跟着手指挪，松手按"位移/速度"决定是否换到下一张 ✓
  double _dragDx = 0;

  /// 是否正在横向拖动（拖动中禁用长按，避免两个手势打架）
  bool _dragging = false;

  /// 手指纵向拖动的累计位移（px）：**下滑** → 展开竖列（用户 2026-10-12 新增）。
  double _dragDy = 0;

  /// 展开的那几个图标挂在 **Overlay** 里（真正"悬浮"，见 [build] 的说明）。
  final OverlayPortalController _portal = OverlayPortalController();

  /// 把浮层锚定在**第一个图标**的正下方。
  final LayerLink _link = LayerLink();

  /// 收起态的总宽：第一个占满 size，其余每个只多露 overlap。
  double get _collapsedWidth =>
      widget.size + (widget.items.length - 1) * widget.overlap;

  /// 收起态竖向要留的高度（叠在一起 ⇒ 只要一个 size + 一点阴影余量 ✓）。
  ///
  /// 🔴 展开时**也是这个高度** —— 这是本次修的关键（见 [build]）。
  double get _collapsedHeight => widget.size + 6;

  void _cycle(int delta) {
    if (widget.items.length < 2) return;
    setState(() {
      _front = (_front + delta) % widget.items.length;
      if (_front < 0) _front += widget.items.length;
    });
  }

  /// 展开 / 收起（同时驱动 Overlay）。
  void _setExpanded(bool v) {
    if (v == _expanded || widget.items.length < 2) return;
    setState(() => _expanded = v);
    if (v) {
      _portal.show();
    } else {
      _portal.hide();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 🔴🔴 自身尺寸**恒定**（收起态那点大小），展开时一个像素都不变 ——
    //
    //   这个控件挂在顶栏里（`Row` / `AppBar.actions`），而这两个容器的
    //   交叉轴对齐都是**居中** ✗：以前展开把 `AnimatedContainer` 的高度从
    //   46 拉到 ~190 ⇒ 整行变高 ⇒ 居中的「图书」标题 / 搜索 / 筛选按钮
    //   **被整体顶下去**（用户 2026-10-14 截图："不是这样呀呀呀"）✗。
    //
    //   现在展开的那 3 个图标挂到 **Overlay** 上、并用
    //   `CompositedTransformFollower` 锚在**第一个图标正下方** ⇒
    //   真的是"悬浮在第一个图标下面" ✓：不动布局、不被顶栏裁掉、
    //   而且照样能点（Overlay 的命中测试会跟着变换走 ✓）。
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (_) => _buildFloating(isDark),
      child: SizedBox(
        // ⚠️ 宽也恒定：以前展开时宽度 67 → 40，末尾对齐会**向右窜 27px** ✗
        width: _collapsedWidth,
        height: _collapsedHeight,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // ── 横向拖动：**跟手** + 松手吸附换张 ✓ ──────────────────────
          //
          // 原来只有 `onHorizontalDragEnd` ✗ —— 手指拖的过程中卡片**纹丝不动**，
          // 松手才"跳"一下，手感是"点了个按钮"而不是"在滑动一叠卡片"。
          // 现在拖动时整叠跟着手指走（`_dragDx`），松手再按位移/速度吸附 ✓
          onHorizontalDragStart: (_) => setState(() {
            _dragging = true;
            _dragDx = 0;
          }),
          onHorizontalDragUpdate: (d) => setState(() {
            // 🔴 **限制跟手位移**：原来 `_dragDx` 无上限 ⇒ 一划就把整叠
            // 拖出屏幕（用户实测："能整个滑动走" ✗）。这里夹在半个图标宽内，
            // 只做"跟手反馈"；松手后由 `AnimatedPositioned` 丝滑归位/换张 ✓。
            final maxFollow = widget.size * 0.5;
            _dragDx = (_dragDx + d.delta.dx).clamp(-maxFollow, maxFollow);
          }),
          onHorizontalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            // 换页判据：拖过一格的 55%，或快速甩动（速度够大）
            final step = widget.overlap <= 0 ? 16.0 : widget.overlap;
            final passed = _dragDx.abs() > step * 0.55;
            final fling = v.abs() > 80;
            setState(() {
              _dragging = false;
              _dragDx = 0;
              if (passed || fling) {
                // 往左划（_dragDx<0 / v<0）⇒ 后一张上前
                final dir = (fling ? -v.sign : -_dragDx.sign);
                _cycle(dir >= 0 ? 1 : -1);
              }
            });
          },
          onHorizontalDragCancel: () => setState(() {
            _dragging = false;
            _dragDx = 0;
          }),
          // ── 纵向拖动：**下滑** → 展开（用户 2026-10-12 新增）──
          //   与横向拖动并存：方向不同，手势竞技场自动分流 ✓
          onVerticalDragStart: (_) => setState(() {
            _dragging = true;
            _dragDy = 0;
          }),
          onVerticalDragUpdate: (d) => setState(() {
            _dragDy = (_dragDy + d.delta.dy).clamp(-40, 40);
          }),
          onVerticalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            setState(() => _dragging = false);
            // 下滑（正位移或正速度）→ 展开
            if (_dragDy > 10 || v > 120) _setExpanded(true);
            setState(() => _dragDy = 0);
          },
          onVerticalDragCancel: () => setState(() {
            _dragging = false;
            _dragDy = 0;
          }),
          // 长按 ⇒ 展开 ✓（拖动中不触发，避免手势打架）
          onLongPress: _dragging ? null : () => _setExpanded(true),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              ..._stackedChildren(isDark),
              // 锚点：正好压住"第一个图标"的位置（浮层挂在它下面）
              Positioned(
                left: 0,
                top: 3,
                width: widget.size,
                height: widget.size,
                child: CompositedTransformTarget(
                  link: _link,
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 收起态：一叠（可左右滑动切换、下滑/长按展开）────────────────
  List<Widget> _stackedChildren(bool isDark) {
    final children = <Widget>[];
    // 从后往前画：最前的最后画 ⇒ 压在最上面 ✓
    final order = List<int>.generate(widget.items.length, (i) => i)
      ..sort((a, b) => _depth(a) < _depth(b) ? -1 : 1);
    for (final i in order) {
      final item = widget.items[i];
      final isFront = i == _front;
      // 展开时**只留最前那个**：其余几个正悬浮在它下面 ✓ ——
      // 再画出那几条露出的边，同一批图标就"出现两次"了 ✗。
      if (_expanded && !isFront) continue;
      children.add(
        // 用 AnimatedPositioned：`_front` 变化（滑动/点击切换）时
        // 每个图标**动画**滑到新位置 ⇒ "丝滑切换" ✓（原来是 `Positioned`，
        // 换张是"啪"地跳过去 ✗）。拖动中时长设为 0，保证**跟手**不滞后 ✓。
        AnimatedPositioned(
          duration: _dragging
              ? Duration.zero
              : const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          left: _leftOf(i),
          top: 3,
          child: _button(
            item,
            isDark: isDark,
            isFront: isFront,
            onTap: isFront ? item.onTap : () => _cycle(i > _front ? 1 : -1),
          ),
        ),
      );
    }
    return children;
  }

  /// 收起态里第 i 项的 X 偏移：以 `_front` 为基准环形铺开 ✓。
  double _leftOf(int i) {
    final n = widget.items.length;
    final rel = (i - _front) % n; // 0 = 最前
    // 🔴 用户 2026-10-12：滑动时**整叠不要跟着手指移动** ——
    //   只做"切换图标"即可，不再叠加 `_dragDx` 的跟手位移 ✓
    return rel * widget.overlap;
  }

  /// 画叠层时的深度：越靠前（rel 越小）画得越晚 ✓。
  int _depth(int i) {
    final n = widget.items.length;
    final rel = (i - _front) % n;
    return n - rel;
  }

  // ── 展开态：其余的图标**悬浮**在第一个图标下面（挂在 Overlay 里）──
  //
  //   · **只有"其余的"** —— 第一个图标留在原地当锚点，不画第二遍 ✓
  //   · 一层全屏透明兜底：点空白处收起（同时挡住下面的页面手势，
  //     和弹窗菜单一个行为 ✓）
  //   · 上滑也能收起（下滑展开的对称操作 ✓）
  Widget _buildFloating(bool isDark) {
    final others = <Widget>[];
    // ⚠️ "其余的" = **除当前最前那个之外**的项（不是"除第 0 项之外"✗：
    //    滑动换张之后最前的可能不是第 0 项，那样会漏一个/多一个 ✓）
    for (var i = 0; i < widget.items.length; i++) {
      if (i == _front) continue; // 最前那个留在原地当锚点
      if (others.isNotEmpty) others.add(const SizedBox(height: 8));
      final idx = i;
      others.add(_button(
        widget.items[idx],
        isDark: isDark,
        // 展开出来的都是"其余"图标 ⇒ 用低调圆底（最前那个仍有深色圆底 ✓）
        isFront: false,
        onTap: () {
          _setExpanded(false);
          widget.items[idx].onTap();
        },
      ));
    }
    return SizedBox.expand(
      child: Stack(
        children: [
          // 点空白处收起
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _setExpanded(false),
            ),
          ),
          // 悬浮列：锚在第一个图标（`_link`）的**左下角** → 挂在它下面 ✓
          Positioned(
            left: 0,
            top: 0,
            child: CompositedTransformFollower(
              link: _link,
              targetAnchor: Alignment.bottomLeft,
              followerAnchor: Alignment.topLeft,
              offset: const Offset(0, 6),
              showWhenUnlinked: false,
              child: GestureDetector(
                // 上滑 → 收起
                onVerticalDragEnd: (d) {
                  if ((d.primaryVelocity ?? 0) < -120) _setExpanded(false);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: others,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 单个图标：最前的用深色圆底强调 ✓ ──────────────────────────
  Widget _button(
    JellyIconDeckItem item, {
    required bool isDark,
    required bool isFront,
    required VoidCallback onTap,
  }) {
    // 🔴 选中态**只看 `isFront`** ✗ —— 原来写成 `isFront || item.emphasized`，
    //   而调用方给第一项传了 `emphasized: true` ⇒ **它永远是选中外观** ✗，
    //   滑动切到别的项时前项也亮着 ⇒ 看起来「两个都选中」✗。
    // 深色圆底（截图里最前那个的样子 ✓）：深色外观下用白，浅色外观下用墨黑
    final frontBg = isDark ? Colors.white : const Color(0xFF2B2B2B);
    final frontFg = isDark ? const Color(0xFF1B1B1B) : Colors.white;
    final backBg = isDark
        ? Colors.white.withValues(alpha: 0.14)
        : Colors.black.withValues(alpha: 0.06);
    final backFg = isDark ? Colors.white70 : JellyTheme.textSecondary;

    return Tooltip(
      message: item.tooltip,
      // ⚠️ 必须 manual：Tooltip 在触摸设备上默认是**长按触发** ✗ ——
      //    它会和本控件的长按（= 展开）抢同一个手势，而且**内层的 Tooltip 先赢** ✗
      //    ⇒ 实际按不出来（只有下滑能用，与注释承诺的"长按展开"不符 ✓）。
      //    关掉 Tooltip 的长按，长按就归"展开"用 ✓
      triggerMode: TooltipTriggerMode.manual,
      child: Material(
        color: isFront ? frontBg : backBg,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          // 热区 = size（默认 40 ✓，不小于 40 ✓）
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: Icon(
              item.icon,
              size: widget.size * 0.5,
              color: isFront ? frontFg : backFg,
            ),
          ),
        ),
      ),
    );
  }
}
