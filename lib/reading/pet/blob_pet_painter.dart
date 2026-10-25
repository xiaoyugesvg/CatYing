import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'pet_models.dart';

/// 「团子兽」——圆润的小生物（替换原来的 QQ 企鹅）。
///
/// 设计取向（用户 2026-10-25：原形象太丑）：
///   · 大头小身，2.5 头身，轮廓全是圆和椭圆，没有硬边；
///   · 主色取自 `species.palette`，上亮下深做柔和渐变，描边用深色 12% 透明；
///   · 眼睛占比大 + 白色高光，腮红淡粉，属于"看一眼就想捏"的比例；
///   · 动效只用呼吸缩放 + 上下浮动 + 轻微摇摆 + 周期眨眼，不做夸张动作。
///
/// 兼容原调用签名（species / outfits / t / mood / headOnly），
/// 所以 `pet_view` 只换类名即可。`outfits` 暂不参与绘制（保持接口稳定）。
class BlobPetPainter extends CustomPainter {
  BlobPetPainter({
    required this.species,
    this.outfits = const <PetOutfitSlot, String>{},
    this.t = 0,
    this.mood = 80,
    this.headOnly = false,
  });

  final PetSpeciesInfo species;
  final Map<PetOutfitSlot, String> outfits;

  /// 动画进度（秒的近似值，由外部不断递增）
  final double t;

  /// 心情 0~100
  final double mood;

  /// 只画头（列表/小卡片用）
  final bool headOnly;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 100.0;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final cycle = t * 2 * math.pi;

    final main = species.palette[0];
    final light = species.palette[1];
    final dark = species.palette[2];

    final bob = math.sin(cycle) * 1.9 * s;
    final breathe = 1 + math.sin(cycle * 2) * 0.012;
    final sway = math.sin(cycle + 0.8) * 0.022;

    // 每 4 秒眨一次眼（用 t 的小数部分判断，不依赖额外 state）
    final blinkPhase = (t / 4.0) % 1.0;
    final blink = blinkPhase > 0.955;

    final happy = mood >= 65;
    final sad = mood < 38;

    canvas.save();
    canvas.translate(cx, cy + bob);
    canvas.rotate(sway);
    canvas.scale(breathe);

    void oval(
      double dx,
      double dy,
      double w,
      double h,
      Paint p,
    ) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(dx * s, dy * s),
          width: w * s,
          height: h * s,
        ),
        p,
      );
    }

    // ── 配色 ──────────────────────────────────────────────
    final bodyPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.lerp(light, main, 0.35)!,
          main,
          Color.lerp(main, dark, 0.22)!,
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(
        Rect.fromLTWH(-40 * s, -50 * s, 80 * s, 100 * s),
      );
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9 * s
      ..color = dark.withValues(alpha: 0.22);
    final bellyPaint = Paint()..color = light.withValues(alpha: 0.92);
    final darkPaint = Paint()..color = dark;

    // ── 地面阴影 ──────────────────────────────────────────
    if (!headOnly) {
      final shadow = Paint()
        ..color = Colors.black.withValues(alpha: 0.10)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3.2 * s);
      oval(0, 42, 46, 9, shadow);
    }

    // ── 尾巴（身后的小团）────────────────────────────────
    if (!headOnly) {
      oval(23, 24, 16, 12, bodyPaint);
      oval(23, 24, 16, 12, stroke);
    }

    // ── 脚 ────────────────────────────────────────────────
    if (!headOnly) {
      for (final side in const [-1.0, 1.0]) {
        oval(side * 13, 38, 17, 9.5, Paint()..color = dark.withValues(alpha: 0.85));
      }
    }

    // ── 身体 ──────────────────────────────────────────────
    if (!headOnly) {
      oval(0, 16, 56, 50, bodyPaint);
      oval(0, 16, 56, 50, stroke);
      // 肚子
      oval(0, 24, 30, 28, bellyPaint);
    }

    // ── 手（随呼吸轻摆）─────────────────────────────────
    if (!headOnly) {
      final handSwing = math.sin(cycle * 2) * 1.4;
      for (final side in const [-1.0, 1.0]) {
        oval(
          side * 27,
          16 + handSwing * side,
          12,
          14,
          bodyPaint,
        );
        oval(side * 27, 16 + handSwing * side, 12, 14, stroke);
      }
    }

    // ── 耳朵（画在头后面）───────────────────────────────
    final headY = headOnly ? 6.0 : -18.0;
    final headR = headOnly ? 30.0 : 27.0;
    for (final side in const [-1.0, 1.0]) {
      oval(
        side * headR * 0.72,
        headY - headR * 0.62,
        15,
        15,
        bodyPaint,
      );
      oval(side * headR * 0.72, headY - headR * 0.62, 15, 15, stroke);
    }

    // ── 头 ────────────────────────────────────────────────
    oval(0, headY, headR * 2, headR * 1.86, bodyPaint);
    oval(0, headY, headR * 2, headR * 1.86, stroke);

    // 头顶高光（一道柔和的弧）
    final gloss = Paint()..color = Colors.white.withValues(alpha: 0.45);
    canvas.save();
    canvas.translate(0, headY * s);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(-headR * 0.28 * s, -headR * 0.48 * s),
        width: headR * 0.9 * s,
        height: headR * 0.46 * s,
      ),
      gloss,
    );
    canvas.restore();

    // ── 脸 ────────────────────────────────────────────────
    final eyeY = headY + 1.0;
    final eyeDx = headR * 0.42;
    final eyeW = happy ? 8.4 : 9.2;
    final eyeH = happy ? 9.4 : 11.0;

    for (final side in const [-1.0, 1.0]) {
      final ex = side * eyeDx;
      if (blink || sad) {
        // 闭眼/难过：一条弧
        final p = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5 * s
          ..strokeCap = StrokeCap.round
          ..color = dark;
        final path = Path()
          ..moveTo((ex - 4) * s, eyeY * s)
          ..quadraticBezierTo(ex * s, (eyeY + (sad ? 2.2 : -2.2)) * s, (ex + 4) * s, eyeY * s);
        canvas.drawPath(path, p);
      } else {
        // 睁眼：椭圆 + 白高光
        oval(ex, eyeY, eyeW, eyeH, darkPaint);
        oval(ex - eyeW * 0.16, eyeY - eyeH * 0.22, eyeW * 0.34, eyeH * 0.30,
            Paint()..color = Colors.white.withValues(alpha: 0.9));
      }
      // 腮红
      oval(
        side * (eyeDx + 6.5),
        eyeY + 7.5,
        8.6,
        5.0,
        Paint()..color = main.withValues(alpha: 0.34),
      );
    }

    // 嘴
    final mouth = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3 * s
      ..strokeCap = StrokeCap.round
      ..color = dark.withValues(alpha: 0.85);
    final my = (eyeY + 8.2) * s;
    final path = Path();
    if (happy) {
      path
        ..moveTo(-3.2 * s, my)
        ..quadraticBezierTo(0, my + 3.0 * s, 3.2 * s, my);
    } else if (sad) {
      path
        ..moveTo(-3.0 * s, my + 1.6 * s)
        ..quadraticBezierTo(0, my - 1.6 * s, 3.0 * s, my + 1.6 * s);
    } else {
      path
        ..moveTo(-2.4 * s, my)
        ..quadraticBezierTo(0, my + 1.6 * s, 2.4 * s, my);
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
