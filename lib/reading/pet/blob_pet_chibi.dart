import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:tvbox/reading/pet/pet_models.dart';
import 'package:tvbox/reading/pet/pet_outfit_painter.dart';

/// 二头身 Q 版绘制（熊猫 / 少年 / 少女）。
///
/// 与 [BlobPetPainter] 的「一颗圆团当身子兼脸」不同，这三只是
/// **大脑袋 + 小身子**：头占整体 2/3、脑袋比身子大一圈、四肢短圆。
///
/// 造型规格（用户 2026-10-27 原文）：
///   · 熊猫：米白 `#F8F8F8` + 纯黑 `#000000`，头顶两侧半圆黑耳、
///     一对**大圆角不规则椭圆**黑眼圈（不是正圆）、短粗黑爪子、
///     脸颊 `#FFC8D0` 淡腮红；表情呆萌。
///   · 少女：圆脸、圆圆的大眼睛、柔和中短发、低饱和浅色穿搭、浅粉腮红、微笑。
///   · 少年：圆脸圆眼、利落短发、低饱和蓝灰穿搭、温和微笑。
/// 三者共同点：**无描边、扁平纯色块、无渐变、无毛发纹理**。
///
/// 坐标系：单位坐标（原点 = 画布中心，1 单位 = 画布宽/100），
/// 由调用方先把画布 `scale(s)` 好 —— 与 [PetOutfitPainter] 完全一致，
/// 所以帽檐/镜片/领口可以直接套团子那套几何。
void paintChibi({
  required Canvas canvas,
  required double s,
  required String kind,
  required Map<PetOutfitSlot, String> outfits,
  required bool headOnly,
  required bool blink,
  required bool sad,
  required double cycle,
  required bool animate,
}) {
  final isPanda = kind == 'panda';
  final isGirl = kind == 'girl';

  // ── 配色（纯色块，不描边、不渐变）──────────────────────────
  const fur = Color(0xFFF8F8F8);
  const inkBlack = Color(0xFF000000);
  const skin = Color(0xFFFDE8DA);
  const blush = Color(0xFFFFC8D0);
  const mouthInk = Color(0xFFB5654F);

  final ink = isPanda ? inkBlack : const Color(0xFF332E2B);
  final hair = isGirl ? const Color(0xFFCBA98F) : const Color(0xFF574F47);
  final cloth = isGirl ? const Color(0xFFEFDCD6) : const Color(0xFFA9B7C4);
  final clothDeep = isGirl ? const Color(0xFFDCC4BE) : const Color(0xFF8E9DAB);

  final headColor = isPanda ? fur : skin;
  final bodyColor = isPanda ? fur : cloth;

  // ── 几何 ──────────────────────────────────────────────────
  final headW = headOnly ? 68.0 : 72.0;
  final headH = headOnly ? 64.0 : 66.0;
  final headY = headOnly ? 0.0 : -8.0;
  final headGeo = BlobGeo(w: headW, h: headH, y: headY);
  // 小身子只有 32 单位高：领口要浅（两侧提到 25.8、正面只压到 30.6），
  // 否则圆团那套 0.02/0.34 会把衣服切成身体最下面的一条边。
  final bodyGeo = BlobGeo(
    w: 46,
    h: 32,
    y: 29,
    neckSide: -0.10,
    neckCenter: 0.06,
  );

  // 眼睛比圆团动物更高更大（Q 版大眼），所以位置要显式传给穿戴画笔，
  // 否则眼镜会按圆团的比例落在眼球内侧。
  final eyeY = headY - headH * 0.04;
  final eyeDx = headW * 0.20;
  final mouthY = headY + headH * 0.21;

  final dress = PetOutfitPainter(
    outfits: outfits,
    geo: headGeo,
    eyeY: eyeY,
    eyeDx: eyeDx,
  );
  final bodyDress = PetOutfitPainter(outfits: outfits, geo: bodyGeo);

  canvas.save();
  canvas.scale(s);

  void oval(
    double dx,
    double dy,
    double w,
    double h,
    Color col, {
    double rot = 0,
  }) {
    canvas.save();
    canvas.translate(dx, dy);
    if (rot != 0) canvas.rotate(rot);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: w, height: h),
      Paint()..color = col,
    );
    canvas.restore();
  }

  void strokePath(Path p, Color col, double w) {
    canvas.drawPath(
      p,
      Paint()
        ..color = col
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  // ── 地面影子 / 脚 / 身子 / 手 ─────────────────────────────
  if (!headOnly) {
    oval(0, 46, 46, 8, Colors.black.withValues(alpha: 0.08));
    final footCol = isPanda ? inkBlack : clothDeep;
    for (final side in const [-1.0, 1.0]) {
      // 间距拉开一点：贴在一起会连成一块黑饼
      oval(side * 11, 43, 13, 9, footCol);
    }
    // 小小的扁圆身子（比脑袋小一圈）
    oval(0, 29, 46, 32, bodyColor);
    final handCol = isPanda ? inkBlack : skin;
    final swing = animate ? math.sin(cycle * 2) * 0.8 : 0.0;
    for (final side in const [-1.0, 1.0]) {
      oval(
        side * 25,
        27 + swing * side * 0.2,
        11,
        16,
        handCol,
        rot: side * 0.22,
      );
    }
    // 衣服：贴小身子的椭圆（U 形领口那套），画完再让脑袋压住领口上沿
    bodyDress.paintClothes(canvas);
  }

  // ── 耳朵（熊猫：画在脑袋之前，露出来的正好是半圆）──────────
  if (isPanda) {
    for (final side in const [-1.0, 1.0]) {
      oval(
        side * headW * 0.34,
        headY - headH * 0.40,
        headW * 0.35,
        headW * 0.35,
        inkBlack,
      );
    }
  }

  // ── 大脑袋 ────────────────────────────────────────────────
  oval(0, headY, headW, headH, headColor);

  // ── 头发（少年 / 少女）：贴头顶的"帽子" + 两侧 ────────────
  if (!isPanda) {
    canvas.drawPath(
      headGeo.capAbove(headY - headH * (isGirl ? 0.13 : 0.18), grow: 0.6),
      Paint()..color = hair,
    );
    for (final side in const [-1.0, 1.0]) {
      oval(
        side * headW * 0.41,
        headY - headH * (isGirl ? 0.02 : 0.11),
        headW * (isGirl ? 0.19 : 0.14),
        headH * (isGirl ? 0.46 : 0.26),
        hair,
      );
    }
    if (isGirl) {
      // 呆毛：一小撮翘起来的头发，别太长，超过 -50 就被画布裁了
      canvas.drawPath(
        Path()
          ..moveTo(-1.2, headY - headH * 0.47)
          ..quadraticBezierTo(3.2, headY - headH * 0.585, 6.8, headY - headH * 0.51)
          ..quadraticBezierTo(3.0, headY - headH * 0.49, 1.0, headY - headH * 0.44)
          ..close(),
        Paint()..color = hair,
      );
    }
  }

  // ── 黑眼圈（大圆角椭圆，微微外八，不是正圆）──────────────
  if (isPanda) {
    for (final side in const [-1.0, 1.0]) {
      oval(
        side * eyeDx * 0.96,
        eyeY + 1.2,
        headW * 0.34,
        headH * 0.44,
        inkBlack,
        rot: side * 0.20,
      );
    }
  }

  // ── 眼睛 ─────────────────────────────────────────────────
  final eyeR = isPanda ? 3.3 : 6.2;
  for (final side in const [-1.0, 1.0]) {
    if (blink) {
      strokePath(
        Path()
          ..moveTo(side * eyeDx - 3.6, eyeY)
          ..quadraticBezierTo(
            side * eyeDx,
            eyeY + (sad ? 1.8 : -1.8),
            side * eyeDx + 3.6,
            eyeY,
          ),
        isPanda ? Colors.white : ink,
        1.3,
      );
      continue;
    }
    if (isPanda) {
      // 黑眼圈里放白眼球 + 黑瞳 + 高光，才看得出"眼睛"
      oval(side * eyeDx, eyeY, eyeR * 2.05, eyeR * 2.25, Colors.white);
      oval(side * eyeDx, eyeY + 0.3, eyeR * 1.15, eyeR * 1.25, inkBlack);
      oval(side * eyeDx - 0.9, eyeY - 1.1, 1.5, 1.5, Colors.white);
    } else {
      oval(side * eyeDx, eyeY, eyeR * 1.92, eyeR * 2.06, ink);
      oval(
        side * eyeDx - eyeR * 0.36,
        eyeY - eyeR * 0.44,
        eyeR * 0.64,
        eyeR * 0.64,
        Colors.white,
      );
      if (isGirl) {
        // 上睫毛：一小段，别画成浓妆
        strokePath(
          Path()
            ..moveTo(side * eyeDx - eyeR * 0.98, eyeY - eyeR * 0.82)
            ..quadraticBezierTo(
              side * eyeDx,
              eyeY - eyeR * 1.28,
              side * eyeDx + eyeR * 0.98,
              eyeY - eyeR * 0.82,
            ),
          ink,
          1.1,
        );
      }
    }
  }

  // ── 腮红 ─────────────────────────────────────────────────
  for (final side in const [-1.0, 1.0]) {
    oval(
      side * headW * 0.33,
      eyeY + headH * 0.21,
      headW * 0.16,
      headH * 0.09,
      blush.withValues(alpha: 0.55),
    );
  }

  // ── 鼻子 / 嘴 ────────────────────────────────────────────
  if (isPanda) {
    oval(0, mouthY - 3.4, 7.0, 5.0, inkBlack);
    strokePath(
      Path()
        ..moveTo(-2.6, mouthY + 0.6)
        ..quadraticBezierTo(0, mouthY + 2.6, 2.6, mouthY + 0.6),
      inkBlack,
      1.1,
    );
  } else {
    strokePath(
      Path()
        ..moveTo(-3.4, mouthY)
        ..quadraticBezierTo(0, mouthY + (sad ? -0.4 : 3.4), 3.4, mouthY),
      mouthInk,
      1.3,
    );
  }

  // ── 眼镜 / 头饰（最后画）──────────────────────────────────
  dress.paintGlasses(canvas);
  dress.paintHat(canvas);

  canvas.restore();
}
