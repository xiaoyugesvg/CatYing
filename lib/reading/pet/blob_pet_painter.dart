import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'pet_models.dart';

/// 「熊猫」桌宠（2026-10-25 重绘，替换上一版蓝色团子兽）。
///
/// 用户参照物是**熊猫**：黑耳朵、黑眼罩、白脸白身、黑手脚。
/// 为了保留「图鉴里每只不一样」，墨色不写死成黑，而是取
/// `species.palette[2]`（小Q 深蓝 / 小秀 玫红 / 书呆 墨绿），
/// 白色身体用 `palette[1]` 提亮 —— 于是每只都是"同款版型、不同配色"的熊猫。
///
/// 动效克制：呼吸缩放 + 上下浮动 + 轻微摇摆 + 每 4 秒眨眼，
/// 心情低时眼罩下垂、嘴变成倒弧。
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
  /// 2026-10-25：桌宠的头改用 GIF（用户指定的熊猫动图），身体仍用矢量，
  /// 这时传 `false` —— 只留身体/四肢，头由 `PetView` 叠上去。
  final bool drawHead;

  /// 是否由画笔自己做呼吸/浮动/摇摆。
  ///
  /// 叠 GIF 头时必须是 `false`：否则身体晃、头不晃，会错位。
  /// 改由 `PetView` 把整只（身体 + GIF 头）一起做同一个变换。
  final bool animate;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 100.0;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final cycle = t * 2 * math.pi;

    // 墨色（耳朵/眼罩/手脚）与毛色（脸/身）
    final ink = species.palette[2];
    final fur = Color.lerp(species.palette[1], Colors.white, 0.72)!;

    final bob = animate ? math.sin(cycle) * 1.7 * s : 0.0;
    final breathe = animate ? 1 + math.sin(cycle * 2) * 0.011 : 1.0;
    final sway = animate ? math.sin(cycle + 0.8) * 0.02 : 0.0;

    final blinkPhase = (t / 4.0) % 1.0;
    final blink = blinkPhase > 0.955;
    final happy = mood >= 65;
    final sad = mood < 38;

    canvas.save();
    canvas.translate(cx, cy + bob);
    canvas.rotate(sway);
    canvas.scale(breathe);

    final inkPaint = Paint()..color = ink;
    final furPaint = Paint()..color = fur;
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8 * s
      ..color = ink.withValues(alpha: 0.18);

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
      oval(0, 43, 44, 8,
          Paint()
            ..color = Colors.black.withValues(alpha: 0.09)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3.0 * s));
    }

    // ── 身体（白）─────────────────────────────────────────
    if (!headOnly) {
      // 后腿
      for (final side in const [-1.0, 1.0]) {
        oval(side * 14, 36, 21, 13, inkPaint);
      }
      // 肚子
      oval(0, 17, 52, 45, furPaint, stroked: true);
      // 手臂（随呼吸轻摆，稍微包住身体）
      final swing = math.sin(cycle * 2) * 0.9;
      for (final side in const [-1.0, 1.0]) {
        oval(
          side * 22,
          18 + swing * side,
          12,
          17,
          inkPaint,
          rotate: side * 0.30,
        );
      }
    }

    // ── 头 ────────────────────────────────────────────────
    // 用 GIF 头时到此为止：身体已经画完，头由上层叠上去。
    if (!drawHead) {
      canvas.restore();
      return;
    }
    final headY = headOnly ? 4.0 : -14.0;
    final r = headOnly ? 31.0 : 26.0;

    // 耳朵（黑，压在头后面）
    for (final side in const [-1.0, 1.0]) {
      oval(side * r * 0.66, headY - r * 0.70, r * 0.72, r * 0.70, inkPaint);
    }
    // 脸（白）
    oval(0, headY, r * 2.0, r * 1.84, furPaint, stroked: true);

    // ── 眼罩（熊猫标志）───────────────────────────────────
    // 角度只给 ±10°：太斜会变成浣熊。宽度收窄、高度拉长，靠近鼻梁。
    final eyeY = headY + r * 0.14;
    final eyeDx = r * 0.36;
    final patchW = r * 0.54;
    final patchH = sad ? r * 0.56 : r * 0.80;

    for (final side in const [-1.0, 1.0]) {
      oval(
        side * eyeDx,
        eyeY,
        patchW,
        patchH,
        inkPaint,
        rotate: side * 0.18,
      );

      // 眼睛：睁开 = 白点 + 黑瞳；闭眼 = 一道弧
      if (blink || sad) {
        final p = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3 * s
          ..strokeCap = StrokeCap.round
          ..color = fur;
        final path = Path()
          ..moveTo((side * eyeDx - 3.2) * s, eyeY * s)
          ..quadraticBezierTo(
            side * eyeDx * s,
            (eyeY + (sad ? 1.8 : -1.8)) * s,
            (side * eyeDx + 3.2) * s,
            eyeY * s,
          );
        canvas.drawPath(path, p);
      } else {
        oval(side * eyeDx, eyeY, 5.4, 5.8,
            Paint()..color = Colors.white.withValues(alpha: 0.96));
        oval(side * eyeDx, eyeY + 0.4, 3.6, 4.0, Paint()..color = ink);
        // 高光
        oval(side * eyeDx - 0.9, eyeY - 1.1, 1.4, 1.4,
            Paint()..color = Colors.white);
      }
    }

    // ── 腮红（固定暖粉，不跟配色走，否则蓝宠会出来两块"白斑"）──
    for (final side in const [-1.0, 1.0]) {
      oval(
        side * (r * 0.78),
        eyeY + r * 0.46,
        r * 0.30,
        r * 0.17,
        Paint()..color = const Color(0xFFF2A0B4).withValues(alpha: 0.34),
      );
    }

    // ── 鼻子（压在眼罩下缘之下，别被盖住）─────────────────
    final noseY = headY + r * 0.60;
    oval(0, noseY, r * 0.24, r * 0.16, inkPaint);

    // ── 嘴：鼻下一个短竖 + 两段弧（熊猫经典 w 形）──────────
    final mouth = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.15 * s
      ..strokeCap = StrokeCap.round
      ..color = ink.withValues(alpha: 0.85);
    final my = noseY + r * 0.16;
    final path = Path();
    if (happy) {
      path
        ..moveTo(-0.1 * s, (noseY + r * 0.07) * s)
        ..lineTo(-0.1 * s, my * s)
        ..moveTo(-3.0 * s, my * s)
        ..quadraticBezierTo(-1.4 * s, (my + 2.4) * s, 0, my * s)
        ..quadraticBezierTo(1.4 * s, (my + 2.4) * s, 3.0 * s, my * s);
    } else if (sad) {
      path
        ..moveTo(-2.6 * s, (my + 1.6) * s)
        ..quadraticBezierTo(0, (my - 1.2) * s, 2.6 * s, (my + 1.6) * s);
    } else {
      path
        ..moveTo(-2.4 * s, my * s)
        ..quadraticBezierTo(0, (my + 1.4) * s, 2.4 * s, my * s);
    }
    canvas.drawPath(path, mouth);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant BlobPetPainter old) =>
      old.t != t ||
      old.mood != mood ||
      old.headOnly != headOnly ||
      old.species.id != species.id;
}
