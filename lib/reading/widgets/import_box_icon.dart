import 'package:flutter/material.dart';

/// 阅读模块统一的「导入」图标：**立体盒子 + 向左的箭头**（用户 2026-10-18 提供的样式）。
///
/// 用 CustomPainter 画（Material 里没有完全一致的图标）：
///   · 等距立方体轮廓
///   · 右下角一支指向盒子内部的箭头
class ImportBoxIcon extends StatelessWidget {
  final double size;
  final Color? color;

  const ImportBoxIcon({super.key, this.size = 22, this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _ImportBoxPainter(
          color ?? (Theme.of(context).brightness == Brightness.dark
              ? Colors.white
              : Colors.black87),
          size,
        ),
      ),
    );
  }
}

class _ImportBoxPainter extends CustomPainter {
  final Color color;
  final double s;

  _ImportBoxPainter(this.color, this.s);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.075
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    // ── 立方体（上菱形 + 左侧/右侧立面）──
    final top = Offset(s * 0.50, s * 0.06);
    final leftTop = Offset(s * 0.10, s * 0.28);
    final rightTop = Offset(s * 0.90, s * 0.28);
    final middle = Offset(s * 0.50, s * 0.50);
    final leftBottom = Offset(s * 0.10, s * 0.72);
    final rightBottom = Offset(s * 0.90, s * 0.72);
    final bottom = Offset(s * 0.50, s * 0.94);

    final cube = Path()
      ..moveTo(top.dx, top.dy)
      ..lineTo(rightTop.dx, rightTop.dy)
      ..lineTo(rightBottom.dx, rightBottom.dy)
      ..lineTo(bottom.dx, bottom.dy)
      ..lineTo(leftBottom.dx, leftBottom.dy)
      ..lineTo(leftTop.dx, leftTop.dy)
      ..close();
    canvas.drawPath(cube, p);

    // 顶面与两个立面之间的三条棱
    canvas.drawLine(leftTop, middle, p);
    canvas.drawLine(rightTop, middle, p);
    canvas.drawLine(middle, bottom, p);

    // ── 右下角箭头（指向盒子）──
    final tip = Offset(s * 0.52, s * 0.80);
    final tail = Offset(s * 0.99, s * 0.80);
    canvas.drawLine(tail, tip, p);
    canvas.drawLine(tip, Offset(s * 0.66, s * 0.66), p);
    canvas.drawLine(tip, Offset(s * 0.66, s * 0.94), p);
  }

  @override
  bool shouldRepaint(covariant _ImportBoxPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.s != s;
}
