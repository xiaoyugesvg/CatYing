import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:tvbox/reading/pet/pet_models.dart';
import 'package:tvbox/reading/pet/pet_outfit_painter.dart';
import 'package:tvbox/reading/pet/blob_pet_chibi.dart';

/// 桌宠「纯圆团」画笔（2026-10-27 重构）。
///
/// 用户要求：「宠物 6 个形象走纯圆团风格（换不同动物）」。
///
/// 上一版是**两段式**企鹅（圆身子 + 独立大头 + 红围巾），只有配色不同，
/// 换物种就得重写一份画笔。这一版改成**单一圆团**（一颗大团子当身子兼脸），
/// 物种差异全部收敛到 `species.animal` 上：
///
///   · `penguin` 企鹅 —— 白肚皮 + 橙嘴 + 红围巾（保留招牌）
///   · `cat`     猫   —— 尖三角耳 + 粉鼻子 + 胡须
///   · `dog`     狗   —— 垂耳 + 浅口鼻 + 舌头
///   · `rabbit`  兔   —— 长立耳 + 小门牙
///   · `bear`    熊   —— 小圆耳 + 大口鼻
///   · `fox`     狐   —— 大尖耳 + 白颊 + 蓬松大尾
///
/// 这样"同款版型、不同动物"只需加一个枚举值 + 一段装饰绘制，
/// 不用再为每个物种复制一份画笔。
///
/// 动效仍然克制：呼吸缩放 + 上下浮动 + 轻微摇摆 + 每 4 秒眨眼；
/// 心情低时眼皮下垂、嘴角向下。`headOnly` 只画团子头（列表/聊天小头像）。
///
/// 换装（2026-10-27）：三类（节日头饰 / 眼镜 / 衣服）全部交给
/// [PetOutfitPainter]，位置由 [BlobGeo] 从团子椭圆反解，贴着轮廓画。
class BlobPetPainter extends CustomPainter {
  BlobPetPainter({
    required this.species,
    this.outfits = const <PetOutfitSlot, String>{},
    this.t = 0,
    this.mood = 80,
    this.headOnly = false,
    this.drawHead = true,
    this.animate = true,
    this.peek = 0,
  });

  final PetSpeciesInfo species;
  final Map<PetOutfitSlot, String> outfits;

  /// 动画进度（秒的近似值）
  final double t;

  /// 心情 0~100
  final double mood;

  /// 只画头（头像 / 小卡片）
  final bool headOnly;

  /// 是否自己画头。默认 `true`：整只由本画笔一次画完。
  /// 上层想叠其它头部素材时传 `false`，只留身体/四肢/尾巴。
  final bool drawHead;

  /// 是否由画笔自己做呼吸/浮动/摇摆。
  /// 外层已经做了同一套变换时传 `false`，避免双重位移。
  final bool animate;

  /// 贴边「门后探头」：`-1` 扒左边缘 / `+1` 扒右边缘 / `0` 正常站立。
  ///
  /// 用户 2026-10-27 给的探头造型规格：「扒在白色门框边缘躲在门后面，
  /// 只露出圆圆的脑袋和一小部分肩膀，身体藏在门后；门框是细白色，
  /// 偷偷探头偷看，呆萌好奇」。桌宠贴到屏幕左右边缘时就走这个姿态 ——
  /// 只画脑袋 + 一条细白门框 + 两只扒着门边的小爪子。
  final int peek;

  @override
  void paint(Canvas canvas, Size size) {
    if (peek != 0) {
      _paintPeek(canvas, size);
      return;
    }
    final s = size.width / 100.0;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final cycle = t * 2 * math.pi;

    final animal = species.animal ?? 'penguin';

    // 配色：团子主色取 palette[2]（深），浅色/肚皮由 palette[1] 提亮
    final body = species.palette[2];
    final bodyDeep = Color.lerp(species.palette[2], Colors.black, 0.18)!;
    final bodyLight = Color.lerp(species.palette[2], Colors.white, 0.22)!;
    final belly = Color.lerp(species.palette[1], Colors.white, 0.55)!;
    final muzzle = Color.lerp(species.palette[1], Colors.white, 0.78)!;
    final eyeDark = Color.lerp(species.palette[2], Colors.black, 0.45)!;
    const beak = Color(0xFFFF9A3D);
    const nosePink = Color(0xFFF0879B);
    const scarf = Color(0xFFE74C3C);
    const scarfShade = Color(0xFFC0392B);

    final bob = animate ? math.sin(cycle) * 1.7 * s : 0.0;
    final breathe = animate ? 1 + math.sin(cycle * 2) * 0.012 : 1.0;
    final sway = animate ? math.sin(cycle + 0.8) * 0.02 : 0.0;

    final blinkPhase = (t / 4.0) % 1.0;
    final blink = blinkPhase > 0.955;
    final sad = mood < 38;

    // 团子本体：接近正圆（纯圆团风格的骨架）
    final blobW = headOnly ? 68.0 : 74.0;
    final blobH = headOnly ? 64.0 : 70.0;
    final blobY = headOnly ? 0.0 : 2.0;

    // 穿戴几何：与团子共用同一套椭圆，帽子/眼镜/衣服才可能"贴"上去
    final geo = BlobGeo(w: blobW, h: blobH, y: blobY);
    final dress = PetOutfitPainter(outfits: outfits, geo: geo);

    canvas.save();
    canvas.translate(cx, cy + bob);
    canvas.rotate(sway);
    canvas.scale(breathe);

    // ── 二头身 Q 版（熊猫 / 少年 / 少女）：整套版型都不一样 ──
    if (animal == 'panda' || animal == 'boy' || animal == 'girl') {
      paintChibi(
        canvas: canvas,
        s: s,
        kind: animal,
        outfits: outfits,
        headOnly: headOnly,
        blink: blink,
        sad: sad,
        cycle: cycle,
        animate: animate,
      );
      canvas.restore();
      return;
    }

    final bodyPaint = Paint()..color = body;
    final bellyPaint = Paint()..color = belly;
    final muzzlePaint = Paint()..color = muzzle;
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8 * s
      ..color = bodyDeep.withValues(alpha: 0.22);

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

    void tri(List<Offset> pts, Paint p, {bool stroked = false}) {
      final path = Path()..moveTo(pts[0].dx * s, pts[0].dy * s);
      for (var i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].dx * s, pts[i].dy * s);
      }
      path.close();
      canvas.drawPath(path, p);
      if (stroked) canvas.drawPath(path, outline);
    }

    /// 穿戴件走**单位坐标**（1 单位 = 画布宽/100，与 [BlobGeo] 一致），
    /// 所以临时补一个 `scale(s)`；外面已经做过呼吸缩放，这里只是换算。
    void dressed(void Function(Canvas c) fn) {
      canvas.save();
      canvas.scale(s);
      fn(canvas);
      canvas.restore();
    }

    // ── 地面阴影 ──────────────────────────────────────────
    if (!headOnly) {
      oval(
        0,
        46,
        52,
        9,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.09)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3.0 * s),
      );
    }

    // ── 尾巴（画在身体之前，才会被团子挡住根部）────────────
    if (!headOnly && drawHead) {
      final wag = animate ? math.sin(cycle * 1.6) * 0.10 : 0.0;
      switch (animal) {
        case 'fox':
          oval(34, 20, 26, 34, bodyPaint, rotate: 0.55 + wag, stroked: true);
          oval(40, 30, 16, 18, muzzlePaint, rotate: 0.55 + wag);
          break;
        case 'cat':
          oval(35, 20, 11, 32, bodyPaint, rotate: 0.8 + wag, stroked: true);
          break;
        case 'dog':
          oval(32, 28, 11, 20, bodyPaint, rotate: 0.55 + wag, stroked: true);
          break;
        case 'rabbit':
          oval(31, 32, 14, 14, bodyPaint, stroked: true);
          break;
        default:
          break;
      }
    }

    // ── 脚 ────────────────────────────────────────────────
    if (!headOnly) {
      final footPaint = animal == 'penguin' ? (Paint()..color = beak) : bodyPaint;
      for (final side in const [-1.0, 1.0]) {
        oval(side * 13, 42, 15, 8, footPaint, stroked: animal != 'penguin');
      }
    }

    // ── 圆团主体（一颗大团子，身子兼脸）────────────────────
    if (!headOnly) {
      // 小短手
      final swing = math.sin(cycle * 2) * 0.9;
      for (final side in const [-1.0, 1.0]) {
        oval(
          side * 33,
          8 + swing * side * 0.25,
          12,
          20,
          bodyPaint,
          rotate: side * 0.25,
          stroked: true,
        );
      }
    }

    // 团子本体：接近正圆（纯圆团风格的骨架）
    oval(0, blobY, blobW, blobH, bodyPaint, stroked: true);

    // 肚皮 / 脸盘
    if (!headOnly) {
      oval(0, 14, 42, 36, bellyPaint);
    } else {
      // 头像：脸盘更大，占满整颗团子
      oval(0, 2, 54, 48, muzzlePaint);
    }

    // ── 耳朵（画在团子之后，压在上沿）──────────────────────
    if (drawHead) {
      switch (animal) {
        case 'cat':
          for (final side in const [-1.0, 1.0]) {
            tri([
              Offset(side * 12, blobY - blobH * 0.34),
              Offset(side * 30, blobY - blobH * 0.30),
              Offset(side * 22, blobY - blobH * 0.60),
            ], bodyPaint, stroked: true);
            tri([
              Offset(side * 17, blobY - blobH * 0.38),
              Offset(side * 26, blobY - blobH * 0.36),
              Offset(side * 22, blobY - blobH * 0.53),
            ], Paint()..color = nosePink.withValues(alpha: 0.55));
          }
          break;
        case 'fox':
          for (final side in const [-1.0, 1.0]) {
            tri([
              Offset(side * 10, blobY - blobH * 0.32),
              Offset(side * 34, blobY - blobH * 0.26),
              Offset(side * 30, blobY - blobH * 0.66),
            ], bodyPaint, stroked: true);
            tri([
              Offset(side * 16, blobY - blobH * 0.36),
              Offset(side * 29, blobY - blobH * 0.33),
              Offset(side * 27, blobY - blobH * 0.57),
            ], muzzlePaint);
          }
          break;
        case 'rabbit':
          // ⚠️ 耳朵别太长：团子中心在 y≈2、半径 ~35，耳朵超过 -50 就被画布裁掉。
          // 这里顶到 -45.6，留 4 个单位余量。
          for (final side in const [-1.0, 1.0]) {
            oval(
              side * 14,
              blobY - blobH * 0.48,
              15,
              28,
              bodyPaint,
              rotate: side * -0.10,
              stroked: true,
            );
            oval(
              side * 14,
              blobY - blobH * 0.48,
              7,
              20,
              Paint()..color = nosePink.withValues(alpha: 0.45),
              rotate: side * -0.10,
            );
          }
          break;
        case 'bear':
          for (final side in const [-1.0, 1.0]) {
            oval(side * 25, blobY - blobH * 0.42, 20, 20, bodyPaint,
                stroked: true);
            oval(side * 25, blobY - blobH * 0.42, 10, 10,
                Paint()..color = bodyLight);
          }
          break;
        case 'dog':
          // 垂耳用**更深的同色系**：同色会和团子糊成一块，看不出是耳朵
          for (final side in const [-1.0, 1.0]) {
            oval(
              side * 31,
              blobY - blobH * 0.12,
              16,
              30,
              Paint()..color = bodyDeep,
              rotate: side * 0.42,
              stroked: true,
            );
          }
          break;
        default: // penguin：无耳
          break;
      }
    }

    // drawHead=false 时到此为止：团子/四肢/尾巴已画完，头由上层叠上去
    if (!drawHead) {
      canvas.restore();
      return;
    }

    // ── 口鼻区 ────────────────────────────────────────────
    final eyeY = blobY - blobH * 0.10;
    final eyeDx = blobW * 0.155;
    final eyeR = headOnly ? 6.4 : 5.6;

    switch (animal) {
      case 'bear':
        oval(0, blobY + blobH * 0.20, 26, 19, muzzlePaint);
        break;
      case 'dog':
        oval(0, blobY + blobH * 0.22, 23, 17, muzzlePaint);
        break;
      case 'fox':
        oval(0, blobY + blobH * 0.22, 19, 15, muzzlePaint);
        // 白颊：别太大，否则整张脸像戴了白口罩
        for (final side in const [-1.0, 1.0]) {
          oval(side * blobW * 0.34, blobY + blobH * 0.14, 13, 16, muzzlePaint);
        }
        break;
      case 'cat':
        for (final side in const [-1.0, 1.0]) {
          oval(side * 7, blobY + blobH * 0.21, 11, 9, muzzlePaint);
        }
        break;
      case 'rabbit':
        for (final side in const [-1.0, 1.0]) {
          oval(side * 6, blobY + blobH * 0.20, 10, 8, muzzlePaint);
        }
        break;
      default:
        break;
    }

    // ── 衣服（画在口鼻之后、眼睛之前：领口会盖住下巴）────────
    if (!headOnly) {
      dressed(dress.paintClothes);
    }

    // ── 眼睛 ─────────────────────────────────────────────
    for (final side in const [-1.0, 1.0]) {
      if (blink || sad) {
        final p = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4 * s
          ..strokeCap = StrokeCap.round
          ..color = eyeDark;
        final path = Path()
          ..moveTo((side * eyeDx - 3.6) * s, eyeY * s)
          ..quadraticBezierTo(
            side * eyeDx * s,
            (eyeY + (sad ? 1.8 : -1.8)) * s,
            (side * eyeDx + 3.6) * s,
            eyeY * s,
          );
        canvas.drawPath(path, p);
      } else {
        oval(side * eyeDx, eyeY, eyeR * 1.1, eyeR * 1.25,
            Paint()..color = Colors.white.withValues(alpha: 0.98));
        oval(side * eyeDx, eyeY + 0.4, eyeR * 0.66, eyeR * 0.78,
            Paint()..color = eyeDark);
        oval(side * eyeDx - 1.0, eyeY - 1.2, eyeR * 0.30, eyeR * 0.30,
            Paint()..color = Colors.white);
      }
    }

    // ── 腮红（固定暖粉，不跟配色走，否则蓝宠会出两块"白斑"）──
    for (final side in const [-1.0, 1.0]) {
      oval(
        side * blobW * 0.30,
        eyeY + blobH * 0.20,
        blobW * 0.15,
        blobH * 0.08,
        Paint()..color = const Color(0xFFF2A0B4).withValues(alpha: 0.34),
      );
    }

    // ── 嘴 / 鼻（按动物）─────────────────────────────────
    // 0.26 而不是 0.30：衣服的 U 形领口压到 0.34，嘴留在 0.26 才不会被领口啃掉
    final mouthY = blobY + blobH * 0.26;
    switch (animal) {
      case 'penguin':
        // 橙嘴：小三角
        tri([
          Offset(-3.6, mouthY - 1.0),
          Offset(3.6, mouthY - 1.0),
          Offset(0, mouthY + 3.2),
        ], Paint()..color = beak);
        break;
      case 'cat':
        tri([
          Offset(-2.6, mouthY - 2.6),
          Offset(2.6, mouthY - 2.6),
          Offset(0, mouthY + 0.4),
        ], Paint()..color = nosePink);
        // 胡须
        final w = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.7 * s
          ..strokeCap = StrokeCap.round
          ..color = bodyDeep.withValues(alpha: 0.35);
        for (final side in const [-1.0, 1.0]) {
          for (var i = 0; i < 3; i++) {
            final y = mouthY - 1.0 + i * 2.2;
            canvas.drawLine(
              Offset(side * blobW * 0.20 * s, y * s),
              Offset(side * blobW * 0.40 * s, (y - 1.2 + i * 1.2) * s),
              w,
            );
          }
        }
        break;
      case 'dog':
        oval(0, mouthY - 2.4, 7.4, 5.4, Paint()..color = eyeDark);
        // 舌头
        oval(0, mouthY + 2.6, 5.6, 5.0,
            Paint()..color = nosePink.withValues(alpha: 0.85));
        break;
      case 'bear':
        oval(0, mouthY - 2.2, 8.6, 6.2, Paint()..color = eyeDark);
        break;
      case 'fox':
        tri([
          Offset(-3.0, mouthY - 2.2),
          Offset(3.0, mouthY - 2.2),
          Offset(0, mouthY + 0.8),
        ], Paint()..color = eyeDark);
        break;
      case 'rabbit':
        tri([
          Offset(-2.4, mouthY - 2.4),
          Offset(2.4, mouthY - 2.4),
          Offset(0, mouthY + 0.2),
        ], Paint()..color = nosePink);
        // 小门牙
        final tooth = Paint()..color = Colors.white;
        for (final side in const [-1.0, 1.0]) {
          oval(side * 1.9, mouthY + 3.4, 3.0, 5.0, tooth);
        }
        break;
      default:
        break;
    }

    // ── 红围巾（企鹅招牌，其它动物不戴）──────────────────
    // 圆团没有"脖子"，围巾只能当**横跨下腹的一圈**：用 geo.slice() 取椭圆
    // 在那一层的横切片，两侧自动收进团子轮廓里（旧版画的是矩形，两端会飞出
    // 身体外面；而且旧版的 y 正好压在嘴上，把橙嘴整个盖掉了）。
    if (!headOnly && animal == 'penguin') {
      dressed((c) {
        c.drawPath(
          geo.slice(blobY + blobH * 0.38, blobY + blobH * 0.47, grow: 2.0),
          Paint()..color = scarf,
        );
        // 垂下来的一小段
        final tx = -geo.halfWidth(blobY + blobH * 0.44) * 0.45;
        c.drawPath(
          Path()
            ..moveTo(tx - 4.5, blobY + blobH * 0.42)
            ..lineTo(tx + 4.5, blobY + blobH * 0.42)
            ..lineTo(tx + 3.0, blobY + blobH * 0.55)
            ..lineTo(tx - 3.2, blobY + blobH * 0.53)
            ..close(),
          Paint()..color = scarfShade,
        );
      });
    }

    // ── 眼镜 / 头饰（最后画：压在脸上和耳朵上）────────────
    dressed(dress.paintGlasses);
    dressed(dress.paintHat);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant BlobPetPainter old) =>
      old.t != t ||
      old.mood != mood ||
      old.headOnly != headOnly ||
      old.drawHead != drawHead ||
      old.peek != peek ||
      old.species.id != species.id ||
      old.species.animal != species.animal ||
      // 换装变了必须重绘：头像/列表里 t 是常量，没有这行换衣服不会刷新
      old.outfits.length != outfits.length ||
      !old.outfits.entries.every((e) => outfits[e.key] == e.value);

  /// 贴边「门后探头」姿态。
  ///
  /// 做法：整颗脑袋往屏幕外推 → 用一条**细白色门框**挡住推出去的那半 →
  /// 再在门框内侧画两只小爪子。这样不管宠物贴在左边缘还是右边缘，
  /// 看起来都是「躲在门后面偷偷探头」，而不是「半张贴纸插在屏幕外」。
  void _paintPeek(Canvas canvas, Size size) {
    final s = size.width / 100.0;
    final side = peek < 0 ? -1.0 : 1.0;
    const frameW = 8.0; // 门框宽度（单位）
    final innerUnit = side < 0 ? (-50 + frameW) : (50 - frameW);
    final innerPx = size.width / 2 + innerUnit * s;

    // ① 只露脑袋：整颗往屏幕外推，被门框挡住一部分
    canvas.save();
    if (side < 0) {
      canvas.clipRect(Rect.fromLTRB(innerPx, 0, size.width, size.height));
    } else {
      canvas.clipRect(Rect.fromLTRB(0, 0, innerPx, size.height));
    }
    final bob = animate ? math.sin(t * 2 * math.pi) * 1.6 * s : 0.0;
    canvas.translate(side * 24 * s, bob);
    BlobPetPainter(
      species: species,
      outfits: outfits,
      t: t,
      mood: mood,
      headOnly: true,
      drawHead: drawHead,
      animate: false,
    ).paint(canvas, size);
    canvas.restore();

    // ② 门框：细白条 + 一道浅灰内边（不然纯白底上完全看不见）
    final barRect = side < 0
        ? Rect.fromLTRB(0, 0, frameW * s, size.height)
        : Rect.fromLTRB(size.width - frameW * s, 0, size.width, size.height);
    canvas.drawRect(barRect, Paint()..color = Colors.white);
    final edgeX = side < 0 ? frameW * s : size.width - frameW * s;
    canvas.drawLine(
      Offset(edgeX, 0),
      Offset(edgeX, size.height),
      Paint()
        ..color = const Color(0xFFDCDCE2)
        ..strokeWidth = 1.2 * s,
    );

    // ③ 两只小爪子扒在门框上（压着门框内沿，别画到脸上）
    final paw = Paint()..color = _pawColor;
    final px = side < 0
        ? frameW * 0.95 * s
        : size.width - frameW * 0.95 * s;
    for (final t in const [0.62, 0.76]) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(px, size.height * t),
          width: 11 * s,
          height: 14 * s,
        ),
        paw,
      );
    }
  }

  /// 爪子颜色：熊猫是纯黑，少年/少女是肤色，动物用身体主色。
  Color get _pawColor {
    switch (species.animal) {
      case 'panda':
        return const Color(0xFF000000);
      case 'boy':
      case 'girl':
        return const Color(0xFFFDE8DA);
      default:
        return species.palette[2];
    }
  }
}
