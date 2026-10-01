import 'package:flutter/material.dart';

import '../theme/jelly_theme.dart';

/// 标题右侧的「拉绳」图标（一根竖线 + 底部一个小圆环）。
///
/// ── 这是什么 ──────────────────────────────────────────────────
/// 按用户截图复刻：漫画页/图书页的大标题右边挂着一根细绳，
/// 绳头是一个小圆环。**点它可以在"阅读 / 书源"两个界面之间切换。**
/// 形状取自"图书馆吊灯/书签绳"的意象，所以它是个**挂着的装饰**，
/// 而不是普通的功能按钮（这也是它长得不像图标的原因）。
///
/// ── 为什么自己画而不是用 Icon ─────────────────────────────────
/// 需要的形状是「细长竖线 + 绳头圆环」，而且圆环是**空心**的。
/// Material 图标里没有这个形状：
///   · `Icons.linear_scale` / `Icons.more_vert` 只有线没有环
///   · `Icons.radio_button_unchecked` 只有环没有线
///   · 拿两个 Widget 叠（Container 画线 + 圆环）也能做，但要在
///     Column 里对像素做手工居中，容易在两个字号的标题旁边错位
/// 直接 CustomPaint 画：一条线 + 一个环，天然对齐、随尺寸缩放。
///
/// ── 尺寸依据 ──────────────────────────────────────────────────
/// 从用户截图放大后量得（原图 1284px 宽，3x 屏）：
///   绳长约 50 逻辑像素、绳粗约 2、圆环外径约 16、环描边约 1.5。
class JellyPullCord extends StatefulWidget {
  const JellyPullCord({
    super.key,
    this.onTap,
    this.tooltip,
    this.enabled = true,
    this.height,
  });

  /// 点击回调（通常是"切换到书源界面"）。为 null 时只作装饰。
  final VoidCallback? onTap;
  final String? tooltip;

  /// 关掉时整根绳变淡（例如当前页没有可切换的目标）
  final bool enabled;

  /// 在**父级**眼里占多高。
  ///
  /// ⚠️ 为 null 时会把绳子的自然高度（50）传给父级 —— 放在标题行的
  /// `Row` 里会把整行撑到 50，导致同排的搜索框/圆图标垂直错位、
  /// 圆环探出到相邻控件上。所以**放进任何 Row 时都应该传这个值**
  /// （一般取同行按钮的高度，例如 40）。
  /// 绳子本身仍按 50 画，超出的部分被裁掉（视觉上就是垂进下面）。
  final double? height;

  @override
  State<JellyPullCord> createState() => _JellyPullCordState();
}

class _JellyPullCordState extends State<JellyPullCord> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 浅灰：#8E8E93 是水墨书香里的次要文字色，绳子和它同色最协调
    final base = JellyTheme.textSecondary.withValues(
      alpha: widget.enabled ? (isDark ? 0.85 : 0.9) : 0.35,
    );

    Widget cord = CustomPaint(
      // 宽度取「绳粗」与「环外径」的较大者。
      // ⚠️ 不能写成 lineWidth + ringSize —— 那是把绳粗和环宽相加，
      // 会多出 2px 空白（圆环居中后左右各空 1px），
      // 在标题旁边表现为"绳子和图标之间莫名多一点缝"。
      size: const Size(_cordWidth, _cordHeight),
      painter: _PullCordPainter(
        color: base,
        // 按下时整根绳微微缩一下，给一点"被拉动"的手感
        scale: _pressed ? 0.92 : 1.0,
      ),
    );

    if (widget.tooltip != null) {
      cord = Tooltip(message: widget.tooltip!, child: cord);
    }

    if (widget.onTap == null) return _constrain(cord);

    return _constrain(GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.enabled ? widget.onTap : null,
      child: cord,
    ));
  }

  /// 把绳子限制在给定高度内。
  ///
  /// ── ⚠️ 这里修的是一个真实的布局 bug ──────────────────────────
  /// `CustomPaint` 的 `size` 是**硬性尺寸**。原来固定 `(16, 50)`，
  /// 放进标题行的 `Row` 里时 —— Row 的高度取最大子项 ——
  /// **整行被强行撑到 50px**，而搜索框、圆形图标按钮都只有 ~40px：
  ///   · 它们被垂直居中到 50px 里 → 与左侧标题基线错位
  ///   · 绳子比行高，圆环探出到相邻控件上 → 表现为"圆环压在搜索框上"
  ///
  /// 修法：**只在本组件内部限制高度**，不把 50px 传给父级。
  /// `ClipRect` 让超出的绳尾自然裁掉（视觉上就是"绳子垂进下面"），
  /// 父级拿到的高度是 [height]。
  Widget _constrain(Widget child) {
    if (widget.height == null) return child;
    return SizedBox(
      height: widget.height,
      child: Align(
        alignment: Alignment.topCenter,
        child: ClipRect(child: child),
      ),
    );
  }
}

// 尺寸常量（理由见类注释：按截图 3x 量得后换算成逻辑像素）
const double _cordHeight = 50;
const double _lineWidth = 2;
const double _ringSize = 16;
const double _ringStroke = 1.5;

/// 组件宽度 = 绳粗与环外径的较大者（环比线粗，所以实际就是环宽）。
/// 单独抽成常量是为了让测试能直接断言，避免以后再写成"两者相加"。
const double _cordWidth = _ringSize > _lineWidth ? _ringSize : _lineWidth;

class _PullCordPainter extends CustomPainter {
  _PullCordPainter({required this.color, required this.scale});

  final Color color;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;

    // 整根绳绕"绳头圆环的中心"缩放 —— 视觉上像绳子被轻轻拽了一下，
    // 而不是整块图形缩小（那样会连位置一起偏）
    final ringCy = size.height - _ringSize / 2;
    canvas.save();
    canvas.translate(cx, ringCy);
    canvas.scale(scale);
    canvas.translate(-cx, -ringCy);

    final linePaint = Paint()
      ..color = color
      ..strokeWidth = _lineWidth
      ..strokeCap = StrokeCap.round;

    // 竖线：从顶端画到圆环上沿（不要画进环里，否则环看起来是实心的）
    final lineBottom = ringCy - _ringSize / 2;
    canvas.drawLine(Offset(cx, 0), Offset(cx, lineBottom), linePaint);

    // 绳头圆环（空心）
    canvas.drawCircle(
      Offset(cx, ringCy),
      (_ringSize - _ringStroke) / 2,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = _ringStroke,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PullCordPainter old) =>
      old.color != color || old.scale != scale;
}
