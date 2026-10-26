import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:tvbox/reading/pet/pet_models.dart';

/// 「QQ 红围巾企鹅」桌宠（2026-10-26 重绘，替换上一版熊猫团子兽）。
///
/// 物种设定从一开始就是企鹅（小Q 红围巾 / 小秀 / 书呆），
/// 上一版临时换成了熊猫、且头用外部 GIF，与设定脱节 —— 这里改回矢量企鹅。
///
/// 造型：圆胖身子 + 大头 + 白肚皮 + 橙嘴橙脚 + 红围巾，
/// 配色取自 `species.palette`（小Q 蓝 / 小秀 粉 / 书呆 绿），
/// 于是每只都是"同款版型、不同配色"的企鹅。
///
/// 动效克制：呼吸缩放 + 上下浮动 + 轻微摇摆 + 每 4 秒眨眼；
/// 心情低时眼皮下垂、嘴变成倒弧。
///
/// 兼容原签名（`outfits` 暂不参与绘制，保持接口稳定）。
class BlobPetPainter extends CustomPainter {
  BlobPetPainter({
    required this.species,
    this.outfits = const <PetOutfitSlot, String>{},
    this.t = 0,
    this.mood = 80,
    this.headOnly = false,
    this.drawHead = true,
    this.animate = true,
  });

  final PetSpeciesInfo species;
  final Map<PetOutfitSlot, String> outfits;

  /// 动画进度（秒的近似值）
  final double t;

  /// 心情 0~100
  final double mood;

  /// 只画头（头像 / 小卡片）
  final bool headOnly;

  /// 是否自己画头。
  ///
  /// 默认 `true`：整只企鹅（含头）由本画笔一次画完。
  /// 当上层想自己叠其它头部素材时可传 `false`，只留身体/四肢。
  final bool drawHead;

  /// 是否由画笔自己做呼吸/浮动/摇摆。
  ///
  /// 外层已经做了同一套变换时传 `false`，避免双重位移。
  final bool animate;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 100.0;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final cycle = t * 2 * math.pi;

    // 身子/头的主色（深）与肚皮/脸的浅色，取自物种调色板
    final body = species.palette[2];
    final belly = Color.lerp(species.palette[1], Colors.white, 0.55)!;
    final face = Color.lerp(species.palette[1], Colors.white, 0.82)!;
    final beak = const Color(0xFFFF9A3D); // 橙嘴橙脚，跨物种一致
    final scarf = const Color(0xFFE74C3C); // 红围巾，QQ 企鹅招牌
    final scarfShade = const Color(0xFFC0392B);

    final bob = animate ? math.sin(cycle) * 1.7 * s : 0.0;
    final breathe = animate ? 1 + math.sin(cycle * 2) * 0.012 : 1.0;
    final sway = animate ? math.sin(cycle + 0.8) * 0.02 : 0.0;

    final blinkPhase = (t / 4.0) % 1.0;
    final blink = blinkPhase > 0.955;
    final sad = mood < 38;

    canvas.save();
    canvas.translate(cx, cy + bob);
    canvas.rotate(sway);
    canvas.scale(breathe);

    final bodyPaint = Paint()..color = body;
    final bellyPaint = Paint()..color = belly;
    final facePaint = Paint()..color = face;
    final beakPaint = Paint()..color = beak;
    final scarfPaint = Paint()..color = scarf;
    final scarfShadePaint = Paint()..color = scarfShade;
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8 * s
      ..color = body.withValues(alpha: 0.16);

    void oval(
      double dx,
      double dy,
      double w,
      double h,
      Paint p, {
      double rotate = 0,
      bool stroked = false,
    }) {
      canvas.save();
      canvas.translate(dx * s, dy * s);
      if (rotate != 0) canvas.rotate(rotate);
      final rect = Rect.fromCenter(
        center: Offset.zero,
        width: w * s,
        height: h * s,
      );
      canvas.drawOval(rect, p);
      if (stroked) canvas.drawOval(rect, outline);
      canvas.restore();
    }

    // ── 地面阴影 ──────────────────────────────────────────
    if (!headOnly) {
      oval(
        0,
        47,
        46,
        8,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.09)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3.0 * s),
      );
    }

    // ── 脚（橙）─────────────────────────────────────────
    if (!headOnly) {
      for (final side in const [-1.0, 1.0]) {
        oval(side * 11, 45, 13, 7, beakPaint);
      }
    }

    // ── 身体 + 翅膀 ─────────────────────────────────────
    if (!headOnly) {
      final swing = math.sin(cycle * 2) * 0.9;
      for (final side in const [-1.0, 1.0]) {
        oval(
          side * 27,
          14 + swing * side * 0.25,
          11,
          22,
          bodyPaint,
          rotate: side * 0.22,
        );
      }
      oval(0, 14, 54, 64, bodyPaint, stroked: true);
      oval(0, 20, 36, 48, bellyPaint);
    }

    // ── 头 ────────────────────────────────────────────────
    // drawHead=false 时到此为止：身体已画完，头由上层叠上去。
    if (!drawHead) {
      canvas.restore();
      return;
    }
    final headY = headOnly ? 2.0 : -14.0;
    final r = headOnly ? 33.0 : 26.0;

    // 头（深色）
    oval(0, headY, r * 2.0, r * 1.9, bodyPaint, stroked: true);
    // 白脸（QQ 企鹅标志性白斑）
    oval(0, headY + r * 0.08, r * 1.5, r * 1.32, facePaint);

    // ── 眼睛 ─────────────────────────────────────────────
    final eyeY = headY - r * 0.05;
    final eyeDx = r * 0.42;
    final eyeR = r * 0.30;
    for (final side in const [-1.0, 1.0]) {
      if (blink || sad) {
        final p = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4 * s
          ..strokeCap = StrokeCap.round
          ..color = body;
        final path = Path()
          ..moveTo((side * eyeDx - 3.4) * s, eyeY * s)
          ..quadraticBezierTo(
            side * eyeDx * s,
            (eyeY + (sad ? 1.8 : -1.8)) * s,
            (side * eyeDx + 3.4) * s,
            eyeY * s,
          );
        canvas.drawPath(path, p);
      } else {
        oval(side * eyeDx, eyeY, eyeR * 1.05, eyeR * 1.2,
            Paint()..color = Colors.white.withValues(alpha: 0.98));
        oval(side * eyeDx, eyeY + 0.4, eyeR * 0.62, eyeR * 0.72,
            Paint()..color = body);
        // 高光
        oval(side * eyeDx - 0.9, eyeY - 1.1, eyeR * 0.28, eyeR * 0.28,
            Paint()..color = Colors.white);
      }
    }

    // ── 腮红（固定暖粉，不跟配色走，否则蓝宠会出两块"白斑"）──
    for (final side in const [-1.0, 1.0]) {
      oval(
        side * (r * 0.85),
        eyeY + r * 0.50,
        r * 0.30,
        r * 0.17,
        Paint()..color = const Color(0xFFF2A0B4).withValues(alpha: 0.34),
      );
    }

    // ── 嘴（橙，小三角）──────────────────────────────────
    final beakY = headY + r * 0.44;
    final beakPath = Path()
      ..moveTo(-3.4 * s, beakY * s)
      ..lineTo(3.4 * s, beakY * s)
      ..lineTo(0, (beakY + 3.0) * s)
      ..close();
    canvas.drawPath(beakPath, beakPaint);

    // ── 红围巾（脖子处一圈 + 垂下的一截）─────────────────
    if (!headOnly) {
      final scarfY = headY + r * 1.15;
      oval(0, scarfY, r * 1.6, r * 0.5, scarfPaint);
      final drop = Path()
        ..moveTo((r * 0.65) * s, scarfY * s)
        ..lineTo((r * 1.1) * s, scarfY * s)
        ..lineTo((r * 0.92) * s, (scarfY + 11) * s)
        ..lineTo((r * 0.5) * s, (scarfY + 9) * s)
        ..close();
      canvas.drawPath(drop, scarfShadePaint);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant BlobPetPainter old) =>
      old.t != t ||
      old.mood != mood ||
      old.headOnly != headOnly ||
      old.drawHead != drawHead ||
      old.species.id != species.id;
}
