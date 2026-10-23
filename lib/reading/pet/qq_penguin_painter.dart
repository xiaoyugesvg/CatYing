import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'pet_models.dart';

/// 拟人化 QQ 企鹅桌宠（纯矢量绘制，不依赖图片素材）。
///
/// 用户 2026-10-23：「直接用 QQ 的宠物样式，但是拟人化一点」——
/// 所以是一只**站立的企鹅**：黑背白肚、橙嘴橙脚、红围巾（QQ 的招牌），
/// 但给了人形比例（大脑袋、小短手、会挥手/眨眼/歪头），并保留换装部位。
///
/// 和旧 `_QqPetPainter`（人类小孩）的区别：外形是企鹅，不再是 Q 版小人；
/// 换装仍然复用 `PetOutfitSlot`（帽/眼镜/围巾/上衣/手持/背景）。
class QqPenguinPainter extends CustomPainter {
  QqPenguinPainter({
    required this.species,
    required this.outfits,
    required this.t,
    required this.mood,
    this.headOnly = false,
  });

  final PetSpeciesInfo species;
  final Map<PetOutfitSlot, String> outfits;

  /// 动画进度（秒）
  final double t;

  /// 心情 0~100：影响眼睛/眉毛/嘴角
  final double mood;

  /// 只画头部（头像用）
  final bool headOnly;

  // ── 配色 ─────────────────────────────────────────────────────
  static const _ink = Color(0xFF252932);
  static const _inkDeep = Color(0xFF161920);
  static const _belly = Color(0xFFF7F9FD);
  static const _beak = Color(0xFFF6A821);
  static const _beakDeep = Color(0xFFD9830F);
  static const _scarf = Color(0xFFE8452E);
  static const _cheek = Color(0xFFFF8FA0);

  Color get _accent => species.palette[0];
  Color get _accentDeep => species.palette[2];

  /// 每 4.2 秒眨一次眼（0.06 ≈ 250ms）
  bool get _blinking => (t % 4.2) / 4.2 > 0.94;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final cycle = t * 2 * math.pi;

    canvas.save();
    if (headOnly) {
      // 头像：脑袋铺满圆形
      canvas.translate(size.width / 2, size.height * 0.53);
      canvas.scale(size.width / 64);
      _drawHead(canvas, 0, 0);
      canvas.restore();
      return;
    }

    final bob = math.sin(cycle) * 1.4;
    final breathe = 1 + math.sin(cycle * 2) * 0.01;
    final sway = math.sin(cycle + 1.1) * 0.03;

    canvas.translate(size.width / 2, size.height * 0.5 + bob);
    canvas.scale(size.width / 100 * breathe);
    canvas.rotate(sway);

    _drawBackground(canvas);
    _drawShadow(canvas);
    _drawFeet(canvas, cycle);
    _drawArms(canvas, cycle);
    _drawBody(canvas);
    _drawGarment(canvas);
    _drawHead(canvas, 0, -24);
    _drawNeck(canvas, cycle);
    _drawHandItem(canvas, cycle);

    canvas.restore();
  }

  // ── 地面影子 ──────────────────────────────────────────────────
  void _drawShadow(Canvas c) {
    c.drawOval(
      Rect.fromCenter(center: const Offset(0, 45), width: 44, height: 9),
      Paint()..color = Colors.black.withValues(alpha: 0.13),
    );
  }

  // ── 脚（橙色，拟人化的小短腿）────────────────────────────────
  void _drawFeet(Canvas c, double cycle) {
    final swing = math.sin(cycle) * 0.06;
    for (final side in const [-1.0, 1.0]) {
      c.save();
      c.translate(side * 12, 38);
      c.rotate(swing * side);
      final r = RRect.fromRectAndRadius(
        const Rect.fromLTWH(-8, -4, 16, 10),
        const Radius.circular(5),
      );
      c.drawRRect(r, Paint()..color = _beak);
      // 脚趾缝
      final toe = Paint()
        ..color = _beakDeep.withValues(alpha: 0.55)
        ..strokeWidth = 0.9
        ..style = PaintingStyle.stroke;
      for (final dx in const [-3.5, 0.0, 3.5]) {
        c.drawLine(Offset(dx, 1.5), Offset(dx, 5), toe);
      }
      c.restore();
    }
  }

  // ── 身体（黑背 + 白肚）───────────────────────────────────────
  void _drawBody(Canvas c) {
    final bodyRect = Rect.fromCenter(
      center: const Offset(0, 6),
      width: 54,
      height: 72,
    );
    c.drawOval(
      bodyRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_ink, _inkDeep],
        ).createShader(bodyRect),
    );
    // 肚皮
    final bellyRect = Rect.fromCenter(
      center: const Offset(0, 11),
      width: 39,
      height: 56,
    );
    c.drawOval(
      bellyRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white, _belly],
        ).createShader(bellyRect),
    );
    // 左侧高光（让黑身体不糊成一块）
    c.drawOval(
      Rect.fromCenter(center: const Offset(-18, -6), width: 8, height: 34),
      Paint()..color = Colors.white.withValues(alpha: 0.07),
    );
  }

  // ── 两只短手（右侧会挥）──────────────────────────────────────
  void _drawArms(Canvas c, double cycle) {
    // 左
    c.save();
    c.translate(-25, 6);
    c.rotate(0.42);
    c.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 11, height: 27),
      Paint()..color = _ink,
    );
    c.restore();
    // 右（挥手）
    final wave = math.sin(cycle * 2) * 0.34;
    c.save();
    c.translate(25, 4);
    c.rotate(-0.42 + wave);
    c.drawOval(
      Rect.fromCenter(center: Offset.zero, width: 11, height: 28),
      Paint()..color = _ink,
    );
    c.restore();
  }

  // ── 头 + 脸 ──────────────────────────────────────────────────
  void _drawHead(Canvas c, double cx, double cy) {
    final headRect = Rect.fromCenter(
      center: Offset(cx, cy),
      width: 58,
      height: 54,
    );
    c.drawOval(
      headRect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_ink, _inkDeep],
        ).createShader(headRect),
    );
    // 脸盘（白色，企鹅特征）
    c.drawOval(
      Rect.fromCenter(center: Offset(cx, cy + 7), width: 42, height: 34),
      Paint()..color = _belly,
    );

    _drawFace(c, cx, cy);
    _drawFaceWear(c, cx, cy);
    _drawHat(c, cx, cy);
  }

  void _drawFace(Canvas c, double cx, double cy) {
    final eyeY = cy - 1.5;
    final eyeDx = 10.0;
    final happy = mood >= 65;
    final sad = mood < 38;

    for (final side in const [-1.0, 1.0]) {
      final ex = cx + side * eyeDx;
      if (_blinking) {
        // 眨眼：一条下弯的弧
        final p = Path()
          ..moveTo(ex - 4.2, eyeY)
          ..quadraticBezierTo(ex, eyeY + 3.2, ex + 4.2, eyeY);
        c.drawPath(
          p,
          Paint()
            ..color = _inkDeep
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.8
            ..strokeCap = StrokeCap.round,
        );
      } else {
        // 眼白 + 瞳孔 + 高光（大眼是"拟人化"的关键）
        c.drawOval(
          Rect.fromCenter(center: Offset(ex, eyeY), width: 11, height: 12),
          Paint()..color = Colors.white,
        );
        c.drawOval(
          Rect.fromCenter(center: Offset(ex, eyeY + 0.6), width: 8, height: 9),
          Paint()..color = _inkDeep,
        );
        c.drawCircle(
          Offset(ex - 1.6, eyeY - 2.0),
          1.9,
          Paint()..color = Colors.white,
        );
        c.drawCircle(
          Offset(ex + 1.8, eyeY + 2.2),
          0.9,
          Paint()..color = Colors.white.withValues(alpha: 0.7),
        );
      }
      // 眉毛：心情差时往中间压
      final brow = Path();
      if (sad) {
        brow
          ..moveTo(ex - side * 4.4, eyeY - 8.2)
          ..quadraticBezierTo(
              ex, eyeY - 10.2, ex + side * 4.4, eyeY - 6.6);
      } else {
        brow
          ..moveTo(ex - 4.4, eyeY - 7.4)
          ..quadraticBezierTo(ex, eyeY - 9.2, ex + 4.4, eyeY - 7.4);
      }
      c.drawPath(
        brow,
        Paint()
          ..color = _inkDeep.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeCap = StrokeCap.round,
      );
    }

    // 腮红
    for (final side in const [-1.0, 1.0]) {
      c.drawOval(
        Rect.fromCenter(
          center: Offset(cx + side * 15.5, cy + 9),
          width: 8,
          height: 5,
        ),
        Paint()..color = _cheek.withValues(alpha: happy ? 0.42 : 0.26),
      );
    }

    // 嘴（橙色小三角，心情决定张开程度）
    final beakH = happy ? 8.6 : (sad ? 6.0 : 7.4);
    final beak = Path()
      ..moveTo(cx - 6.4, cy + 8)
      ..lineTo(cx + 6.4, cy + 8)
      ..quadraticBezierTo(cx, cy + 8 + beakH, cx - 6.4, cy + 8)
      ..close();
    c.drawPath(beak, Paint()..color = _beak);
    // 嘴缝
    c.drawLine(
      Offset(cx - 4.6, cy + 8.6),
      Offset(cx + 4.6, cy + 8.6),
      Paint()
        ..color = _beakDeep
        ..strokeWidth = 1.1
        ..strokeCap = StrokeCap.round,
    );
  }

  // ── 面部换装（眼镜 / 墨镜）──────────────────────────────────
  void _drawFaceWear(Canvas c, double cx, double cy) {
    final item = outfits[PetOutfitSlot.face];
    if (item == null) return;
    final eyeY = cy - 1.5;
    if (item == 'glasses') {
      final p = Paint()
        ..color = _accentDeep
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4;
      for (final side in const [-1.0, 1.0]) {
        c.drawCircle(Offset(cx + side * 10, eyeY), 7.2, p);
      }
      c.drawLine(Offset(cx - 2.8, eyeY), Offset(cx + 2.8, eyeY), p);
    } else if (item == 'shades') {
      for (final side in const [-1.0, 1.0]) {
        final r = RRect.fromRectAndRadius(
          Rect.fromCenter(
              center: Offset(cx + side * 10, eyeY), width: 15, height: 10),
          const Radius.circular(5),
        );
        c.drawRRect(r, Paint()..color = _inkDeep.withValues(alpha: 0.92));
      }
      c.drawLine(
        Offset(cx - 3, eyeY),
        Offset(cx + 3, eyeY),
        Paint()
          ..color = _inkDeep
          ..strokeWidth = 1.6,
      );
    }
  }

  // ── 头部换装（蝴蝶结 / 礼帽 / 鸭舌帽 / 皇冠）────────────────
  void _drawHat(Canvas c, double cx, double cy) {
    final item = outfits[PetOutfitSlot.hat];
    if (item == null) return;
    final topY = cy - 26.6;
    switch (item) {
      case 'bow':
        for (final side in const [-1.0, 1.0]) {
          final p = Path()
            ..moveTo(cx, topY + 3)
            ..lineTo(cx + side * 11, topY - 4)
            ..lineTo(cx + side * 11, topY + 6)
            ..close();
          c.drawPath(p, Paint()..color = _accent);
        }
        c.drawCircle(Offset(cx, topY + 2), 3, Paint()..color = _accentDeep);
        break;
      case 'hat':
        c.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: Offset(cx, topY + 3), width: 30, height: 4),
            const Radius.circular(2),
          ),
          Paint()..color = _accentDeep,
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: Offset(cx, topY - 5), width: 18, height: 15),
            const Radius.circular(3),
          ),
          Paint()..color = _accent,
        );
        break;
      case 'cap':
        final p = Path()
          ..moveTo(cx - 14, topY + 2)
          ..quadraticBezierTo(cx, topY - 12, cx + 14, topY + 2)
          ..close();
        c.drawPath(p, Paint()..color = _accent);
        c.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: Offset(cx + 9, topY + 3), width: 18, height: 5),
            const Radius.circular(2.5),
          ),
          Paint()..color = _accentDeep,
        );
        break;
      case 'crown':
        final p = Path()
          ..moveTo(cx - 12, topY + 3)
          ..lineTo(cx - 12, topY - 6)
          ..lineTo(cx - 5, topY - 1)
          ..lineTo(cx, topY - 9)
          ..lineTo(cx + 5, topY - 1)
          ..lineTo(cx + 12, topY - 6)
          ..lineTo(cx + 12, topY + 3)
          ..close();
        c.drawPath(p, Paint()..color = const Color(0xFFFFC53D));
        break;
    }
  }

  // ── 脖子（红围巾 / 领结）────────────────────────────────────
  void _drawNeck(Canvas c, double cycle) {
    final item = outfits[PetOutfitSlot.neck];
    if (item == 'tie') {
      for (final side in const [-1.0, 1.0]) {
        final p = Path()
          ..moveTo(0, 1)
          ..lineTo(side * 9, -3)
          ..lineTo(side * 9, 5)
          ..close();
        c.drawPath(p, Paint()..color = _accent);
      }
      c.drawCircle(const Offset(0, 1), 2.6, Paint()..color = _accentDeep);
      return;
    }
    // 默认就是 QQ 的红围巾（item == 'scarf' 或没戴）
    c.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: const Offset(0, -3), width: 46, height: 9),
        const Radius.circular(4.5),
      ),
      Paint()..color = _scarf,
    );
    final flap = math.sin(cycle) * 0.12;
    c.save();
    c.translate(-14, 1);
    c.rotate(0.12 + flap);
    final p = Path()
      ..moveTo(0, 0)
      ..lineTo(9, 0)
      ..lineTo(7.4, 15)
      ..lineTo(1.6, 15)
      ..close();
    c.drawPath(p, Paint()..color = _scarf);
    c.restore();
  }

  // ── 上衣（连帽卫衣 / 小马甲）────────────────────────────────
  void _drawGarment(Canvas c) {
    final item = outfits[PetOutfitSlot.top];
    if (item == null) return;
    final paint = Paint()..color = _accent.withValues(alpha: 0.92);
    if (item == 'hoodie') {
      // 卫衣：盖住上半个肚子，留出下方白肚
      final r = RRect.fromRectAndCorners(
        const Rect.fromLTWH(-22, -6, 44, 26),
        topLeft: const Radius.circular(12),
        topRight: const Radius.circular(12),
        bottomLeft: const Radius.circular(8),
        bottomRight: const Radius.circular(8),
      );
      c.drawRRect(r, paint);
      // 帽子（脖子后面一圈）
      c.drawOval(
        Rect.fromCenter(center: const Offset(0, -8), width: 40, height: 14),
        Paint()..color = _accentDeep.withValues(alpha: 0.85),
      );
      // 抽绳
      final line = Paint()
        ..color = Colors.white.withValues(alpha: 0.8)
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round;
      c.drawLine(const Offset(-5, 2), const Offset(-6, 10), line);
      c.drawLine(const Offset(5, 2), const Offset(6, 10), line);
    } else if (item == 'vest') {
      // 马甲：左右两片，不挡白肚
      for (final side in const [-1.0, 1.0]) {
        final p = Path()
          ..moveTo(side * 8, -6)
          ..lineTo(side * 24, -2)
          ..quadraticBezierTo(side * 27, 12, side * 23, 26)
          ..lineTo(side * 8, 26)
          ..quadraticBezierTo(side * 5, 10, side * 8, -6)
          ..close();
        c.drawPath(p, paint);
      }
      c.drawLine(
        const Offset(0, -5),
        const Offset(0, 24),
        Paint()
          ..color = _accentDeep.withValues(alpha: 0.6)
          ..strokeWidth = 1,
      );
    }
  }

  // ── 手持物（书 / 咖啡 / 气球）────────────────────────────────
  void _drawHandItem(Canvas c, double cycle) {
    final item = outfits[PetOutfitSlot.hand];
    if (item == null) return;
    final wave = math.sin(cycle * 2) * 0.2;
    c.save();
    c.translate(25, 12);
    c.rotate(-0.3 + wave);
    switch (item) {
      case 'book':
        c.save();
        c.rotate(-0.16);
        c.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: const Offset(2, 0), width: 15, height: 19),
            const Radius.circular(2),
          ),
          Paint()..color = _accentDeep,
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: const Offset(0.6, 0), width: 13, height: 17),
            const Radius.circular(2),
          ),
          Paint()..color = Colors.white,
        );
        c.restore();
        break;
      case 'coffee':
        c.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: const Offset(0, 2), width: 12, height: 13),
            const Radius.circular(3),
          ),
          Paint()..color = Colors.white,
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: const Offset(0, 5), width: 12, height: 6),
            const Radius.circular(2),
          ),
          Paint()..color = const Color(0xFF8B5E3C),
        );
        break;
      case 'balloon':
        c.drawLine(
          const Offset(0, 6),
          const Offset(3, 26),
          Paint()
            ..color = _accentDeep.withValues(alpha: 0.7)
            ..strokeWidth = 1,
        );
        c.drawOval(
          Rect.fromCenter(center: const Offset(0, -2), width: 18, height: 21),
          Paint()..color = _accent,
        );
        break;
    }
    c.restore();
  }

  // ── 背景（月光 / 星芒）──────────────────────────────────────
  void _drawBackground(Canvas c) {
    final item = outfits[PetOutfitSlot.background];
    if (item == null) return;
    if (item == 'moon') {
      c.drawCircle(
        const Offset(-30, -34),
        13,
        Paint()..color = const Color(0xFFFFF3C4).withValues(alpha: 0.55),
      );
      c.drawCircle(
        const Offset(-25, -38),
        10,
        Paint()..color = const Color(0xFFFFFDF2).withValues(alpha: 0.35),
      );
    } else if (item == 'stars') {
      final dot = Paint()..color = Colors.white.withValues(alpha: 0.8);
      final line = Paint()
        ..color = Colors.white.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8;
      for (final o in const [
        Offset(-32, -30),
        Offset(28, -34),
        Offset(-26, 18),
        Offset(32, 10),
      ]) {
        final twinkle = 1 + math.sin(t * 3 + o.dx) * 0.25;
        final r = 1.6 * twinkle;
        c.drawCircle(o, r, dot);
        c.drawLine(o - Offset(r * 2.2, 0), o + Offset(r * 2.2, 0), line);
        c.drawLine(o - Offset(0, r * 2.2), o + Offset(0, r * 2.2), line);
      }
    }
  }

  @override
  bool shouldRepaint(covariant QqPenguinPainter old) =>
      old.t != t ||
      old.mood != mood ||
      old.headOnly != headOnly ||
      old.species.id != species.id ||
      old.outfits.length != outfits.length ||
      !old.outfits.entries.every((e) => outfits[e.key] == e.value);
}
