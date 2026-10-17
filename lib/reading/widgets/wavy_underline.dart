import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 波浪下划线（用于「笔记/划线」的视觉区分）。
///
/// 不用图片、不引依赖：按宽度画正弦折线，颜色跟随笔记自己的颜色。
class WavyUnderline extends StatelessWidget {
  const WavyUnderline({
    super.key,
    required this.color,
    this.height = 5,
    this.amplitude = 1.2,
    this.wavelength = 7,
    this.strokeWidth = 1.4,
  });

  final Color color;
  final double height;
  final double amplitude;
  final double wavelength;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: height,
      child: CustomPaint(
        painter: _WavyPainter(
          color: color,
          amplitude: amplitude,
          wavelength: wavelength,
          strokeWidth: strokeWidth,
        ),
      ),
    );
  }
}

class _WavyPainter extends CustomPainter {
  _WavyPainter({
    required this.color,
    required this.amplitude,
    required this.wavelength,
    required this.strokeWidth,
  });

  final Color color;
  final double amplitude;
  final double wavelength;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    final center = size.height / 2;
    final path = Path();
    final step = math.max(1.0, wavelength / 6);
    var first = true;
    for (double x = 0; x <= size.width; x += step) {
      final y = center + amplitude * math.sin((x / wavelength) * 2 * math.pi);
      if (first) {
        path.moveTo(x, y);
        first = false;
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _WavyPainter old) =>
      old.color != color ||
      old.amplitude != amplitude ||
      old.wavelength != wavelength ||
      old.strokeWidth != strokeWidth;
}
