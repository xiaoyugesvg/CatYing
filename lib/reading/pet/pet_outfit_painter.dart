import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:tvbox/reading/pet/pet_models.dart';

/// 圆团几何：把「一颗椭圆团子」的常用轮廓一次算好。
///
/// 坐标系是**单位坐标**：原点 = 团子中心，1 单位 = 画布宽 / 100。
/// 调用方负责把画布变换好（`BlobPetPainter` 里先 `scale(s)`，
/// 图片宠物那边按头部包围盒 `scale(k)`）。
///
/// 有了它，帽子/眼镜/衣服的位置全部由团子自己的椭圆反解出来，
/// 不再写死矩形 —— 团子大小/胖瘦一变，穿戴自动跟着走（这才是「贴合」）。
class BlobGeo {
  const BlobGeo({
    this.w = 74,
    this.h = 70,
    this.y = 2,
    this.neckSide = 0.02,
    this.neckCenter = 0.34,
  });

  /// 团子宽 / 高 / 中心纵坐标（原点在团子中心，所以 y 一般是个小偏移）
  final double w;
  final double h;
  final double y;

  /// 衣服领口的两端高度（占团子高的比例，相对团子中心）。
  ///
  /// 默认值是为「一颗圆团当身子兼脸」调的：两侧提到 0.02（贴到最宽处）、
  /// 正面压到 0.34（正好落在嘴下面）。二头身的小身子只有 32 单位高，
  /// 要传更浅的值（见 blob_pet_chibi.dart），否则领口会把衣服切成一条边。
  final double neckSide;
  final double neckCenter;

  Rect rect({double grow = 0}) => Rect.fromCenter(
        center: Offset(0, y),
        width: w + grow * 2,
        height: h + grow * 2,
      );

  /// 高度 [yy] 处的半宽（画帽檐/腰带宽度用）
  double halfWidth(double yy, {double grow = 0}) {
    final ry = h / 2 + grow;
    final dy = ((yy - y) / ry).clamp(-1.0, 1.0);
    return (w / 2 + grow) * math.sqrt(math.max(0.0, 1 - dy * dy));
  }

  /// 高度 [yy] 对应的椭圆参数角（取右侧解）
  double angleAt(double yy, {double grow = 0}) {
    final ry = h / 2 + grow;
    return math.asin(((yy - y) / ry).clamp(-1.0, 1.0));
  }

  Offset pointAt(double a, {double grow = 0}) {
    final r = rect(grow: grow);
    return Offset(
      r.center.dx + r.width / 2 * math.cos(a),
      r.center.dy + r.height / 2 * math.sin(a),
    );
  }

  /// 椭圆被水平线 [yy] 切出的**上半部**（闭合）：帽壳 / 顶盖。
  ///
  /// 从左侧交点沿上弧走到右侧交点 —— 这样帽子的两侧永远落在团子轮廓上，
  /// 不会出现「帽子比头宽、两边悬空」。
  Path capAbove(double yy, {double grow = 0, int steps = 26}) {
    final phi = angleAt(yy, grow: grow);
    final path = Path();
    for (var i = 0; i <= steps; i++) {
      final a = (math.pi - phi) + (math.pi + 2 * phi) * i / steps;
      final p = pointAt(a, grow: grow);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    return path..close();
  }

  /// 椭圆在水平线 [yy] **上方**的那段弧（开放）：发箍 / 头带。
  Path arcAbove(double yy, {double grow = 0, int steps = 26}) {
    final phi = angleAt(yy, grow: grow);
    final path = Path();
    for (var i = 0; i <= steps; i++) {
      final a = (math.pi - phi) + (math.pi + 2 * phi) * i / steps;
      final p = pointAt(a, grow: grow);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    return path;
  }

  /// 椭圆在 [y0, y1] 之间的**横切片**（闭合）：帽檐 / 围巾 / 腰带 / 下摆。
  ///
  /// 边界是「右侧弧 + 下弦 + 左侧弧 + 上弦」——注意上下两边是**直线弦**，
  /// 不能顺着椭圆绕到底部：那样切出来的不是一条带，而是「带之外的大半个
  /// 椭圆」，画帽檐会直接糊满整张画布（踩过这个坑）。
  Path slice(double y0, double y1, {double grow = 0, int steps = 14}) {
    final a0 = angleAt(y0, grow: grow); // 右侧上交点
    final a1 = angleAt(y1, grow: grow); // 右侧下交点
    final path = Path();
    // 右侧弧：上 → 下
    for (var i = 0; i <= steps; i++) {
      final p = pointAt(a0 + (a1 - a0) * i / steps, grow: grow);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    // 下弦：右 → 左
    final l1 = pointAt(math.pi - a1, grow: grow);
    path.lineTo(l1.dx, l1.dy);
    // 左侧弧：下 → 上
    for (var i = 1; i <= steps; i++) {
      final p = pointAt((math.pi - a1) + (a1 - a0) * i / steps, grow: grow);
      path.lineTo(p.dx, p.dy);
    }
    // 上弦由 close() 补上
    return path..close();
  }

  /// 衣服：上沿是 U 形领口（中间低、两侧高），两侧与下摆严格贴轮廓。
  ///
  /// 为什么要 U 形而不是一条横线：圆团没有脖子，一条横线切下去要么盖住嘴，
  /// 要么细得只剩一道边。U 形领口把正面的开口压到嘴下面、两侧提上去包住
  /// "肩"，既贴合又不挡脸。
  Path garment({
    double grow = 1.2,
    double? sideTop,
    double? centerTop,
    int steps = 22,
  }) {
    final y0 = y + h * (sideTop ?? neckSide);
    final y1 = y + h * (centerTop ?? neckCenter);
    final hw = halfWidth(y0, grow: grow);
    final path = Path()
      ..moveTo(-hw, y0)
      ..quadraticBezierTo(-hw * 0.55, y1, 0, y1)
      ..quadraticBezierTo(hw * 0.55, y1, hw, y0);
    final a0 = angleAt(y0, grow: grow);
    for (var i = 0; i <= steps; i++) {
      final a = a0 + (math.pi - 2 * a0) * i / steps;
      final p = pointAt(a, grow: grow);
      path.lineTo(p.dx, p.dy);
    }
    return path..close();
  }

  /// 领口那条 U 形线（开放），给衣服描边用。
  Path neckline({
    double grow = 1.2,
    double? sideTop,
    double? centerTop,
  }) {
    final y0 = y + h * (sideTop ?? neckSide);
    final y1 = y + h * (centerTop ?? neckCenter);
    final hw = halfWidth(y0, grow: grow);
    return Path()
      ..moveTo(-hw, y0)
      ..quadraticBezierTo(-hw * 0.55, y1, 0, y1)
      ..quadraticBezierTo(hw * 0.55, y1, hw, y0);
  }
}

/// 节日穿戴绘制（2026-10-27 重做）。
///
/// 用户：「不要什么服装系统了，就弄各种节日头饰、眼镜和衣服吧，这个要贴合呀」。
///
/// 三类全部由 [BlobGeo] 反解位置，没有一处写死的绝对坐标：
///
///   · **头饰**：`capAbove()` 取椭圆上半部当帽壳，帽檐 `slice()` 跟着头顶弧度
///     走；装饰（绒球/南瓜蒂/绒球尾）挂在帽顶。
///   · **眼镜**：镜片中心 = 眼睛坐标（`eyeY` / `eyeDx`），镜腿拉到椭圆边界。
///   · **衣服**：`garment()` 的 U 形领口 + 下摆贴轮廓；花纹一律 `clipPath`
///     裁进衣服里，绝不溢出到身体外面。
///
/// 三个 `paintXxx` 分开是为了**图层顺序**：衣服要画在口鼻之后、眼睛之前
/// （领口盖住下巴），眼镜和头饰要画在整张脸之后。
class PetOutfitPainter {
  const PetOutfitPainter({
    required this.outfits,
    this.geo = const BlobGeo(),
    this.eyeY,
    this.eyeDx,
  });

  final Map<PetOutfitSlot, String> outfits;
  final BlobGeo geo;

  /// 眼睛坐标覆盖（二头身 Q 版的眼睛比圆团动物更大更高，必须显式传进来，
  /// 否则镜片会落在眼球内侧）
  final double? eyeY;
  final double? eyeDx;

  // ── 配色 ────────────────────────────────────────────────────
  static const _ink = Color(0xFF2B2B2B);
  static const _gold = Color(0xFFF2C14E);
  static const _red = Color(0xFFD64541);
  static const _orange = Color(0xFFE8853A);
  static const _green = Color(0xFF4E8D5B);
  static const _cream = Color(0xFFFBF3E4);
  static const _purple = Color(0xFF6D5A9E);

  Paint _fill(Color c) => Paint()..color = c;

  Paint _stroke(Color c, double w) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  /// 帽檐所在高度：团子上沿往下约 28% 处
  double get _brim => geo.y - geo.h * 0.28;

  /// 眼睛那条线（与 BlobPetPainter 的眼睛坐标一致）
  double get _eyeY => eyeY ?? geo.y - geo.h * 0.10;

  /// 眼睛横向间距
  double get _eyeDx => eyeDx ?? geo.w * 0.155;

  bool get isEmpty =>
      outfits[PetOutfitSlot.hat] == null &&
      outfits[PetOutfitSlot.glasses] == null &&
      outfits[PetOutfitSlot.clothes] == null;

  /// 一次画完（图片宠物用；矢量宠物请分别调用以控制图层顺序）。
  void paintAll(Canvas c) {
    paintClothes(c);
    paintGlasses(c);
    paintHat(c);
  }

  // ═══════════════════════════════════════════════════════════
  // 衣服
  // ═══════════════════════════════════════════════════════════
  void paintClothes(Canvas c) {
    final id = outfits[PetOutfitSlot.clothes];
    if (id == null) return;
    final body = geo.garment();
    final neck = geo.neckline();

    switch (id) {
      case 'tang_suit':
        // 唐装马甲：正红 + 金边领口 + 下摆金边 + 两颗盘扣
        c.drawPath(body, _fill(_red));
        c.drawPath(neck, _stroke(_gold, 2.2));
        c.drawPath(
          geo.slice(geo.y + geo.h * 0.44, geo.y + geo.h * 0.50, grow: 1.6),
          _fill(_gold),
        );
        for (final t in const [0.395, 0.455]) {
          c.drawCircle(
            Offset(0, geo.y + geo.h * t),
            geo.w * 0.022,
            _fill(_gold),
          );
        }
        break;

      case 'sweater':
        // 圣诞毛衣：墨绿 + 米白领口/下摆 + 几颗雪花点
        c.drawPath(body, _fill(const Color(0xFF2F7A52)));
        c.drawPath(neck, _stroke(_cream, 3.0));
        c.drawPath(
          geo.slice(geo.y + geo.h * 0.455, geo.y + geo.h * 0.50, grow: 1.5),
          _fill(_cream),
        );
        final snow = _fill(_cream.withValues(alpha: 0.92));
        for (final p in const [
          Offset(-0.24, 0.375),
          Offset(0.24, 0.395),
          Offset(-0.10, 0.425),
          Offset(0.12, 0.435),
        ]) {
          c.drawCircle(
            Offset(geo.w * p.dx, geo.y + geo.h * p.dy),
            geo.w * 0.020,
            snow,
          );
        }
        break;

      case 'poncho':
        // 南瓜斗篷：暗紫 + 橙色锯齿下摆（锯齿裁进衣服里，不会飞出去）
        c.drawPath(body, _fill(_purple));
        c.drawPath(neck, _stroke(const Color(0xFF8A76C4), 2.4));
        c.save();
        c.clipPath(body);
        final zig = Path();
        final zy = geo.y + geo.h * 0.395;
        final zw = geo.w * 0.42;
        zig.moveTo(-zw, zy);
        const n = 6;
        for (var i = 0; i < n; i++) {
          final x1 = -zw + 2 * zw * (i + 0.5) / n;
          final x2 = -zw + 2 * zw * (i + 1) / n;
          zig.lineTo(x1, zy + geo.h * 0.07);
          zig.lineTo(x2, zy);
        }
        zig
          ..lineTo(zw, geo.y + geo.h * 0.52)
          ..lineTo(-zw, geo.y + geo.h * 0.52)
          ..close();
        c.drawPath(zig, _fill(_orange));
        c.restore();
        break;

      case 'hanfu':
        // 汉服襦裙：月白 + 米白交领 + 一条腰封
        c.drawPath(body, _fill(const Color(0xFFA8C8E8)));
        c.drawPath(neck, _stroke(_cream, 3.4));
        c.drawPath(
          geo.slice(geo.y + geo.h * 0.435, geo.y + geo.h * 0.475, grow: 1.4),
          _fill(const Color(0xFF6E8FB8)),
        );
        break;

      case 'overalls':
        // 背带裤：牛仔蓝 + 前胸方兜 + 两颗铜扣
        c.drawPath(body, _fill(const Color(0xFF5C7CA8)));
        c.drawPath(neck, _stroke(const Color(0xFF47618A), 2.6));
        final bibTop = geo.y + geo.h * 0.345;
        final bibW = geo.w * 0.30;
        c.save();
        c.clipPath(body);
        c.drawPath(
          Path()
            ..moveTo(-bibW, bibTop)
            ..lineTo(bibW, bibTop)
            ..lineTo(bibW * 0.80, geo.y + geo.h * 0.52)
            ..lineTo(-bibW * 0.80, geo.y + geo.h * 0.52)
            ..close(),
          _fill(const Color(0xFF6D8DBA)),
        );
        c.restore();
        for (final s in const [-1.0, 1.0]) {
          c.drawCircle(
            Offset(s * bibW * 0.86, bibTop + geo.h * 0.012),
            geo.w * 0.024,
            _fill(_gold),
          );
        }
        break;
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 眼镜
  // ═══════════════════════════════════════════════════════════
  void paintGlasses(Canvas c) {
    final id = outfits[PetOutfitSlot.glasses];
    if (id == null) return;
    final ey = _eyeY;
    final dx = _eyeDx;
    // 镜腿拉到团子边缘 —— 那里才是"耳朵"的位置
    final edge = geo.halfWidth(ey) * 0.96;
    final temple = _stroke(const Color(0xFF3A3A3A), 1.6);

    void temples(double from) {
      for (final s in const [-1.0, 1.0]) {
        c.drawLine(Offset(s * (dx + from), ey), Offset(s * edge, ey), temple);
      }
    }

    switch (id) {
      case 'round_glasses':
        final rim = _stroke(const Color(0xFF4A4A4A), 1.9);
        final r = geo.w * 0.112;
        for (final s in const [-1.0, 1.0]) {
          c.drawCircle(Offset(s * dx, ey), r, rim);
        }
        temples(r);
        c.drawLine(Offset(-dx + r, ey), Offset(dx - r, ey), rim);
        break;

      case 'shades':
        final lens = _fill(const Color(0xFF263238));
        final half = geo.w * 0.108;
        for (final s in const [-1.0, 1.0]) {
          c.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                center: Offset(s * dx, ey),
                width: half * 2,
                height: geo.h * 0.155,
              ),
              Radius.circular(geo.w * 0.045),
            ),
            lens,
          );
        }
        temples(half);
        c.drawLine(
          Offset(-dx + half, ey),
          Offset(dx - half, ey),
          _stroke(const Color(0xFF263238), 2.0),
        );
        // 镜面高光
        c.drawLine(
          Offset(-dx - half * 0.5, ey - geo.h * 0.02),
          Offset(-dx + half * 0.1, ey - geo.h * 0.055),
          _stroke(Colors.white.withValues(alpha: 0.45), 1.5),
        );
        break;

      case 'star_glasses':
        final rim = _stroke(_gold, 1.8);
        final r = geo.w * 0.125;
        for (final s in const [-1.0, 1.0]) {
          c.drawPath(_star(Offset(s * dx, ey), r), rim);
        }
        temples(r * 0.75);
        break;

      case 'heart_glasses':
        final rim = _stroke(const Color(0xFFE8557E), 1.8);
        final r = geo.w * 0.115;
        for (final s in const [-1.0, 1.0]) {
          c.drawPath(_heart(Offset(s * dx, ey), r), rim);
        }
        temples(r * 0.8);
        break;
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 头饰
  // ═══════════════════════════════════════════════════════════
  void paintHat(Canvas c) {
    final id = outfits[PetOutfitSlot.hat];
    if (id == null) return;
    final brim = _brim;

    switch (id) {
      case 'lion_hat':
        // 狮头帽：贴头顶的红帽壳 + 金帽檐 + 顶上一颗白绒球 + 两侧金铃
        c.drawPath(geo.capAbove(brim, grow: 1.0), _fill(_red));
        c.drawPath(geo.slice(brim - 3.0, brim + 1.2, grow: 1.6), _fill(_gold));
        c.drawCircle(
          Offset(0, geo.y - geo.h * 0.455),
          geo.w * 0.085,
          _fill(_cream),
        );
        for (final s in const [-1.0, 1.0]) {
          c.drawCircle(
            Offset(s * geo.halfWidth(brim) * 0.76, brim + 1.2),
            geo.w * 0.034,
            _fill(_gold),
          );
        }
        break;

      case 'moon_crown':
        // 月桂冠：贴头顶一圈金环 + 中间一枚小月牙 + 两片桂叶
        final bandY = geo.y - geo.h * 0.335;
        c.drawPath(geo.arcAbove(bandY, grow: 1.4), _stroke(_gold, 3.0));
        final cy = geo.y - geo.h * 0.46;
        final r = geo.w * 0.082;
        c.drawPath(
          Path.combine(
            PathOperation.difference,
            Path()..addOval(Rect.fromCircle(center: Offset(0, cy), radius: r)),
            Path()
              ..addOval(
                Rect.fromCircle(
                  center: Offset(r * 0.58, cy - r * 0.22),
                  radius: r * 0.86,
                ),
              ),
          ),
          _fill(_gold),
        );
        for (final s in const [-1.0, 1.0]) {
          c.save();
          c.translate(s * geo.halfWidth(bandY) * 0.68, bandY - geo.h * 0.012);
          c.rotate(s * 0.5);
          c.drawOval(
            Rect.fromCenter(
              center: Offset.zero,
              width: geo.w * 0.055,
              height: geo.w * 0.115,
            ),
            _fill(const Color(0xFF6BA368)),
          );
          c.restore();
        }
        break;

      case 'pumpkin_hat':
        // 南瓜帽：橙色帽壳 + 三道瓜棱 + 南瓜灯脸 + 瓜蒂
        final cap = geo.capAbove(brim, grow: 1.2);
        c.drawPath(cap, _fill(_orange));
        c.save();
        c.clipPath(cap);
        final ridge = _stroke(const Color(0xFFC96A24), 2.2);
        for (final dx in const [-1.0, 0.0, 1.0]) {
          final x = dx * geo.w * 0.20;
          c.drawPath(
            Path()
              ..moveTo(x, brim - geo.h * 0.02)
              ..quadraticBezierTo(
                x * 1.3,
                brim - geo.h * 0.20,
                x * 0.35,
                brim - geo.h * 0.34,
              ),
            ridge,
          );
        }
        c.restore();
        final fy = brim - geo.h * 0.14;
        for (final s in const [-1.0, 1.0]) {
          c.drawPath(
            Path()
              ..moveTo(s * geo.w * 0.055, fy)
              ..lineTo(s * geo.w * 0.135, fy)
              ..lineTo(s * geo.w * 0.095, fy + geo.h * 0.05)
              ..close(),
            _fill(_ink),
          );
        }
        final mouth = Path()
          ..moveTo(-geo.w * 0.11, fy + geo.h * 0.085);
        for (var i = 0; i < 4; i++) {
          mouth.lineTo(
            -geo.w * 0.11 + geo.w * 0.055 * (i + 0.5),
            fy + geo.h * 0.055,
          );
          mouth.lineTo(-geo.w * 0.11 + geo.w * 0.055 * (i + 1), fy + geo.h * 0.085);
        }
        mouth.close();
        c.drawPath(mouth, _fill(_ink));
        c.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(0, geo.y - geo.h * 0.52),
              width: geo.w * 0.075,
              height: geo.h * 0.085,
            ),
            Radius.circular(geo.w * 0.02),
          ),
          _fill(const Color(0xFF4E7A3A)),
        );
        break;

      case 'santa_hat':
        // 圣诞帽：白帽檐贴头顶弧 + 向右耷拉的红色锥筒 + 白绒球
        final hw = geo.halfWidth(brim);
        final tipX = geo.w * 0.26;
        final tipY = brim - geo.h * 0.36;
        c.drawPath(
          Path()
            ..moveTo(-hw * 0.94, brim)
            ..quadraticBezierTo(-hw * 0.35, brim - geo.h * 0.30, tipX, tipY)
            ..quadraticBezierTo(hw * 0.55, brim - geo.h * 0.22, hw * 0.94, brim)
            ..close(),
          _fill(_red),
        );
        c.drawPath(geo.slice(brim - 3.4, brim + 1.4, grow: 1.8), _fill(_cream));
        c.drawCircle(Offset(tipX, tipY), geo.w * 0.075, _fill(_cream));
        break;

      case 'leaf_hat':
        // 粽叶斗笠：深绿锥面 + 叶脉 + 比团子还宽一圈的宽帽檐
        final hw = geo.halfWidth(brim);
        final apex = brim - geo.h * 0.34;
        c.drawPath(
          Path()
            ..moveTo(-hw * 1.02, brim)
            ..lineTo(0, apex)
            ..lineTo(hw * 1.02, brim)
            ..close(),
          _fill(_green),
        );
        final vein = _stroke(const Color(0xFF3A6E45), 1.4);
        for (final s in const [-0.55, 0.0, 0.55]) {
          c.drawLine(Offset(0, apex), Offset(s * hw * 1.85, brim), vein);
        }
        c.drawPath(
          geo.slice(brim - 2.6, brim + 2.2, grow: 4.0),
          _fill(const Color(0xFF5FA06C)),
        );
        break;
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 小工具
  // ═══════════════════════════════════════════════════════════
  Path _star(Offset c, double r) {
    final p = Path();
    for (var i = 0; i < 10; i++) {
      final rr = i.isEven ? r : r * 0.45;
      final a = -math.pi / 2 + i * math.pi / 5;
      final pt = Offset(c.dx + math.cos(a) * rr, c.dy + math.sin(a) * rr);
      if (i == 0) {
        p.moveTo(pt.dx, pt.dy);
      } else {
        p.lineTo(pt.dx, pt.dy);
      }
    }
    return p..close();
  }

  Path _heart(Offset c, double r) {
    return Path()
      ..moveTo(c.dx, c.dy + r * 0.92)
      ..cubicTo(
        c.dx - r * 1.45,
        c.dy - r * 0.15,
        c.dx - r * 0.62,
        c.dy - r * 1.05,
        c.dx,
        c.dy - r * 0.42,
      )
      ..cubicTo(
        c.dx + r * 0.62,
        c.dy - r * 1.05,
        c.dx + r * 1.45,
        c.dy - r * 0.15,
        c.dx,
        c.dy + r * 0.92,
      )
      ..close();
  }
}
