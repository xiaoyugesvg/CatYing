part of 'pet_view.dart';

/// 矢量宠物「穿戴」绘制（QQ秀式多部位：上衣 → 颈饰 → 手持 → 面部 → 头饰）。
///
/// 方法体自原 pet_view.dart 逐字节搬入。改衣服只动这个文件。
mixin _PetOutfitPaint on _InkPetPainterBase {
  void _drawOutfits(Canvas c, Color main, Color light, Color accent) {
    _drawTop(c, main, accent);
    _drawNeck(c, accent);
    _drawHand(c, accent);
    _drawFaceAccessory(c);
    _drawHat(c, accent);
  }

  /// 背景件（月光 / 星芒）—— 画在身体下面
  void _drawOutfitBackground(Canvas c, Color accent) {
    switch (outfits[PetOutfitSlot.background]) {
      case 'moon':
        c.drawCircle(
          const Offset(50, 46),
          36,
          Paint()..color = accent.withValues(alpha: 0.16),
        );
        c.drawCircle(
          const Offset(50, 46),
          36,
          _line(width: 1.2, color: accent.withValues(alpha: 0.45)),
        );
        break;
      case 'stars':
        final p = _fill(accent.withValues(alpha: 0.65));
        for (final o in const [
          Offset(22, 25),
          Offset(78, 22),
          Offset(84, 64),
          Offset(18, 62),
        ]) {
          _star(c, o, 4.5, p);
        }
        break;
    }
  }

  void _star(Canvas c, Offset center, double r, Paint p) {
    final path = Path();
    for (var i = 0; i < 8; i++) {
      final rr = i.isEven ? r : r * 0.42;
      final a = -math.pi / 2 + i * math.pi / 4;
      final pt = Offset(
        center.dx + math.cos(a) * rr,
        center.dy + math.sin(a) * rr,
      );
      if (i == 0) {
        path.moveTo(pt.dx, pt.dy);
      } else {
        path.lineTo(pt.dx, pt.dy);
      }
    }
    path.close();
    c.drawPath(path, p);
  }

  void _drawHat(Canvas c, Color accent) {
    switch (outfits[PetOutfitSlot.hat]) {
      case 'hat':
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(32, 14, 36, 4),
            const Radius.circular(2),
          ),
          _fill(const Color(0xFF263238)),
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(40, 3, 20, 12),
            const Radius.circular(3),
          ),
          _fill(const Color(0xFF37474F)),
        );
        c.drawRect(const Rect.fromLTWH(40, 11, 20, 3), _fill(accent));
        break;
      case 'cap':
        c.drawArc(
          Rect.fromCenter(center: const Offset(48, 16), width: 30, height: 24),
          math.pi,
          math.pi,
          true,
          _fill(accent),
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(48, 14, 22, 4),
            const Radius.circular(2),
          ),
          _fill(accent),
        );
        break;
      case 'crown':
        c.drawPath(
          Path()
            ..moveTo(38, 12)
            ..lineTo(42, 3)
            ..lineTo(46, 10)
            ..lineTo(50, 1)
            ..lineTo(54, 10)
            ..lineTo(58, 3)
            ..lineTo(62, 12)
            ..close(),
          _fill(const Color(0xFFF2C14E)),
        );
        break;
      case 'bow':
        c.drawPath(
          Path()
            ..moveTo(66, 16)
            ..lineTo(76, 10)
            ..lineTo(76, 22)
            ..close(),
          _fill(accent),
        );
        c.drawPath(
          Path()
            ..moveTo(66, 16)
            ..lineTo(56, 10)
            ..lineTo(56, 22)
            ..close(),
          _fill(accent),
        );
        c.drawCircle(const Offset(66, 16), 2.6, _fill(accent));
        break;
    }
  }

  void _drawFaceAccessory(Canvas c) {
    switch (outfits[PetOutfitSlot.face]) {
      case 'glasses':
        final p = _line(width: 1.8, color: const Color(0xFF37474F));
        c.drawCircle(const Offset(40, 46), 8, p);
        c.drawCircle(const Offset(60, 46), 8, p);
        c.drawLine(const Offset(48, 46), const Offset(52, 46), p);
        break;
      case 'shades':
        final fill = _fill(const Color(0xFF263238));
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(31, 41, 17, 10),
            const Radius.circular(3),
          ),
          fill,
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(52, 41, 17, 10),
            const Radius.circular(3),
          ),
          fill,
        );
        c.drawLine(
          const Offset(48, 46),
          const Offset(52, 46),
          _line(width: 2, color: const Color(0xFF263238)),
        );
        break;
    }
  }

  void _drawNeck(Canvas c, Color accent) {
    switch (outfits[PetOutfitSlot.neck]) {
      case 'scarf':
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(28, 58, 44, 9),
            const Radius.circular(4.5),
          ),
          _fill(accent),
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(30, 64, 9, 14),
            const Radius.circular(3),
          ),
          _fill(accent),
        );
        break;
      case 'tie':
        c.drawPath(
          Path()
            ..moveTo(46, 58)
            ..lineTo(54, 58)
            ..lineTo(50, 63)
            ..close(),
          _fill(const Color(0xFFD32F2F)),
        );
        c.drawPath(
          Path()
            ..moveTo(47, 63)
            ..lineTo(53, 63)
            ..lineTo(50, 73)
            ..close(),
          _fill(const Color(0xFFD32F2F)),
        );
        break;
    }
  }

  void _drawTop(Canvas c, Color main, Color accent) {
    switch (outfits[PetOutfitSlot.top]) {
      case 'hoodie':
        final col = Color.lerp(main, Colors.white, 0.12)!;
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(24, 63, 52, 25),
            const Radius.circular(10),
          ),
          _fill(col.withValues(alpha: 0.92)),
        );
        c.drawLine(
          const Offset(50, 64),
          const Offset(50, 86),
          _line(width: 1.2, color: accent),
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(40, 56, 20, 9),
            const Radius.circular(5),
          ),
          _fill(col.withValues(alpha: 0.75)),
        );
        break;
      case 'vest':
        final col = accent.withValues(alpha: 0.85);
        c.drawPath(
          Path()
            ..moveTo(24, 64)
            ..lineTo(46, 64)
            ..lineTo(44, 86)
            ..lineTo(26, 86)
            ..close(),
          _fill(col),
        );
        c.drawPath(
          Path()
            ..moveTo(76, 64)
            ..lineTo(54, 64)
            ..lineTo(56, 86)
            ..lineTo(74, 86)
            ..close(),
          _fill(col),
        );
        c.drawCircle(const Offset(50, 68), 1.6, _fill(Colors.white));
        c.drawCircle(const Offset(50, 78), 1.6, _fill(Colors.white));
        break;
    }
  }

  void _drawHand(Canvas c, Color accent) {
    switch (outfits[PetOutfitSlot.hand]) {
      case 'book':
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(66, 68, 18, 13),
            const Radius.circular(2),
          ),
          _fill(const Color(0xFFF5F0E6)),
        );
        c.drawLine(
          const Offset(75, 68),
          const Offset(75, 81),
          _line(width: 1.4, color: const Color(0xFF8D6E63)),
        );
        break;
      case 'coffee':
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(68, 70, 13, 13),
            const Radius.circular(3),
          ),
          _fill(Colors.white),
        );
        c.drawArc(
          Rect.fromCenter(center: const Offset(83, 76), width: 6, height: 8),
          -math.pi / 2,
          math.pi,
          false,
          _line(width: 1.6, color: Colors.white),
        );
        c.drawLine(
          const Offset(71, 67),
          const Offset(72, 62),
          _line(width: 1, color: Colors.white54),
        );
        c.drawLine(
          const Offset(76, 67),
          const Offset(77, 62),
          _line(width: 1, color: Colors.white54),
        );
        break;
      case 'balloon':
        c.drawCircle(
          const Offset(76, 44),
          9,
          _fill(accent.withValues(alpha: 0.9)),
        );
        c.drawPath(
          Path()
            ..moveTo(76, 53)
            ..quadraticBezierTo(70, 62, 72, 70),
          _line(width: 0.9, color: accent.withValues(alpha: 0.8)),
        );
        break;
    }
  }
}
