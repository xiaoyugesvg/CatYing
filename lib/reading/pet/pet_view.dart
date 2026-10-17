import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'pet_models.dart';

/// 手绘 Q 版桌宠（CustomPainter，无图片素材依赖）。
///
/// 风格：水墨国风「团子」——粗黑描边、圆滚滚的身体、半睁的傲娇眼、
/// 粉腮红、小短腿，与用户给的十二生肖插画一致。
///
/// 之所以用矢量绘制：宠物要每帧呼吸/眨眼/摇尾，单张 PNG 做不到；
/// 所有物种共用一套身体，再按物种补耳朵/角/尾巴，风格统一且体积为零。
class PetView extends StatelessWidget {
  const PetView({
    super.key,
    required this.species,
    required this.outfit,
    required this.t,
    this.size = 120,
    this.mood = 80,
    this.headOnly = false,
  });

  final PetSpeciesInfo species;
  final String outfit;

  /// 动画进度（秒），由外部 AnimationController 推进
  final double t;
  final double size;
  final double mood;

  /// 只画头部（头像用）：把脸放大铺满圆形，不画身体/脚/尾巴。
  final bool headOnly;

  @override
  Widget build(BuildContext context) {
    final asset = species.imageAsset;
    if (asset != null && !headOnly) {
      return _buildImagePet(asset);
    }
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _InkPetPainter(
          species: species,
          outfit: outfit,
          t: t,
          mood: mood,
          headOnly: headOnly,
        ),
      ),
    );
  }

  /// 图片皮肤：用户提供的生肖插画，做成圆角贴纸卡片。
  ///
  /// 插画是 3:4 竖图（顶部带书法标题），这里用 `BoxFit.cover` + 底部对齐，
  /// 只保留动物本体；再叠加轻微上下浮动与摇摆，保证"灵动"。
  Widget _buildImagePet(String asset) {
    final bob = math.sin(t * 2 * math.pi) * 1.6;
    final sway = math.sin(t * 2 * math.pi + 0.8) * 0.012;
    return SizedBox(
      width: size,
      height: size,
      child: Transform.translate(
        offset: Offset(0, bob),
        child: Transform.rotate(
          angle: sway,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(size * 0.16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Image.asset(
              asset,
              width: size,
              height: size,
              fit: BoxFit.cover,
              alignment: Alignment.bottomCenter,
              errorBuilder: (_, _, _) => CustomPaint(
                painter: _InkPetPainter(
                  species: species,
                  outfit: outfit,
                  t: t,
                  mood: mood,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 圆形头像：同一个团子画法 + 米白纸底，自动裁成圆形。
///
/// 用于「我的」页头像、内置头像选择面板；头像**始终是圆的**。
class InkPetAvatar extends StatelessWidget {
  const InkPetAvatar({
    super.key,
    required this.speciesId,
    this.size = 64,
    this.outfit = 'none',
  });

  final String speciesId;
  final double size;
  final String outfit;

  @override
  Widget build(BuildContext context) {
    final sp = PetSpecies.byId(speciesId);
    final asset = sp.imageAsset;
    if (asset != null) {
      // 用户提供的生肖插画：圆形裁切，底部对齐只保留动物本体
      return SizedBox(
        width: size,
        height: size,
        child: ClipOval(
          child: ColoredBox(
            color: const Color(0xFFF7F3EA),
            child: Image.asset(
              asset,
              width: size,
              height: size,
              fit: BoxFit.cover,
              alignment: Alignment.bottomCenter,
            ),
          ),
        ),
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: ColoredBox(
          color: const Color(0xFFF7F3EA),
          child: Padding(
            padding: EdgeInsets.all(size * 0.05),
            child: PetView(
              species: sp,
              outfit: outfit,
              t: 0,
              size: size,
              headOnly: true,
            ),
          ),
        ),
      ),
    );
  }
}

class _InkPetPainter extends CustomPainter {
  _InkPetPainter({
    required this.species,
    required this.outfit,
    required this.t,
    required this.mood,
    this.headOnly = false,
  });

  final PetSpeciesInfo species;
  final String outfit;
  final double t;
  final double mood;
  final bool headOnly;

  static const Color _ink = Color(0xFF232323);

  Paint _fill(Color c) => Paint()..color = c;

  Paint _line({double width = 2.2, Color? color}) => Paint()
    ..color = color ?? _ink
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 100.0;
    canvas.save();
    canvas.scale(scale, scale);

    final bob = math.sin(t * 2 * math.pi) * 1.6;
    final breathe = 1 + math.sin(t * 2 * math.pi) * 0.012;
    // 约每 4.2 秒眨一次眼
    final blinking = t > 0 && (t % 4.2) > 4.05;

    final main = species.palette[0];
    final light = species.palette[1];
    final accent = species.palette[2];

    if (headOnly) {
      _paintHeadOnly(canvas, main, light, accent, blinking);
      canvas.restore();
      return;
    }

    canvas.translate(0, bob);

    // 地面阴影
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(50, 93), width: 62, height: 7),
      Paint()..color = Colors.black.withValues(alpha: 0.10),
    );

    // 身后零件（耳朵 / 角 / 尾巴 / 翅膀 / 壳）
    _drawBackParts(canvas, main, light, accent);

    // 身体 + 头（一个整体团子）
    canvas.save();
    canvas.translate(50, 68);
    canvas.scale(1, breathe);
    canvas.translate(-50, -68);
    final body = Path()
      ..moveTo(20, 58)
      ..cubicTo(16, 33, 26, 15, 50, 15)
      ..cubicTo(74, 15, 84, 33, 80, 58)
      ..cubicTo(78, 82, 66, 90, 50, 90)
      ..cubicTo(34, 90, 22, 82, 20, 58)
      ..close();
    canvas.drawPath(body, _fill(main));
    // 正面米白肚皮 / 脸
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(50, 62), width: 52, height: 54),
      _fill(light),
    );
    canvas.restore();
    // 粗描边最后画，避免被肚皮盖住
    canvas.drawPath(body, _line(width: 2.4));

    // 小短腿
    for (final dx in [36.0, 64.0]) {
      canvas.drawOval(
        Rect.fromCenter(center: Offset(dx, 89), width: 15, height: 7),
        _fill(main),
      );
      canvas.drawOval(
        Rect.fromCenter(center: Offset(dx, 89), width: 15, height: 7),
        _line(width: 1.8),
      );
    }

    // 花纹 / 腮红 / 眼睛 / 嘴
    _drawMarkings(canvas, accent, main);
    _drawFace(canvas, accent, blinking);

    // 前景零件（胡须 / 翅膀 / 尾巴 / 贝壳纹）
    _drawFrontParts(canvas, main, light, accent);

    // 换装配饰
    _drawOutfit(canvas, accent);

    canvas.restore();
  }

  // ── 头像模式：只保留头部，放大铺满圆形 ─────────────────────

  /// 头像专用：不画身体/脚/尾巴，把脸放大到接近铺满圆形。
  ///
  /// 原头部坐标是「中心 (50,38)、半径 22」，这里以 (50,54) 为圆心放大 1.7 倍，
  /// 让脸成为整个头像的主体（用户 2026-10-17：「全圆形，只保留头部」）。
  void _paintHeadOnly(
    Canvas c,
    Color main,
    Color light,
    Color accent,
    bool blinking,
  ) {
    c.save();
    c.translate(50, 56);
    c.scale(1.5, 1.5);
    c.translate(-50, -38);

    _drawHeadEars(c, main, light, accent);

    c.drawCircle(const Offset(50, 38), 22, _fill(main));
    c.drawCircle(const Offset(50, 38), 22, _line(width: 1.5));
    c.drawOval(
      Rect.fromCenter(center: const Offset(50, 42), width: 28, height: 24),
      _fill(light),
    );

    _drawMarkings(c, accent, main);
    _drawFace(c, accent, blinking);
    _drawHeadFront(c, main, light, accent);

    c.restore();
  }

  /// 头部专属的耳朵 / 角 / 冠羽（不包含尾巴与身体零件）。
  void _drawHeadEars(Canvas c, Color main, Color light, Color accent) {
    switch (species.id) {
      case 'cat':
      case 'tiger':
      case 'white_tiger':
        _ear(c, const Offset(30, 24), 10, -0.35, main);
        _ear(c, const Offset(70, 24), 10, 0.35, main);
        break;
      case 'dog':
        c.drawOval(
          Rect.fromCenter(center: const Offset(23, 38), width: 13, height: 24),
          _fill(main),
        );
        c.drawOval(
          Rect.fromCenter(center: const Offset(23, 38), width: 13, height: 24),
          _line(width: 1.5),
        );
        c.drawOval(
          Rect.fromCenter(center: const Offset(77, 38), width: 13, height: 24),
          _fill(main),
        );
        c.drawOval(
          Rect.fromCenter(center: const Offset(77, 38), width: 13, height: 24),
          _line(width: 1.5),
        );
        break;
      case 'rabbit':
        _longEar(c, 38, main, light);
        _longEar(c, 62, main, light);
        break;
      case 'rat':
        _roundEar(c, const Offset(28, 26), 10, main, light);
        _roundEar(c, const Offset(72, 26), 10, main, light);
        break;
      case 'ox':
        c.drawArc(
          Rect.fromCenter(center: const Offset(30, 20), width: 20, height: 16),
          math.pi,
          math.pi * 0.9,
          false,
          _line(width: 2.4, color: const Color(0xFFE8D7B0)),
        );
        c.drawArc(
          Rect.fromCenter(center: const Offset(70, 20), width: 20, height: 16),
          0,
          math.pi * 0.9,
          false,
          _line(width: 2.4, color: const Color(0xFFE8D7B0)),
        );
        break;
      case 'goat':
        c.drawArc(
          Rect.fromCenter(center: const Offset(30, 20), width: 16, height: 20),
          math.pi * 0.9,
          math.pi * 1.1,
          false,
          _line(width: 2.2, color: const Color(0xFFD9C3A0)),
        );
        c.drawArc(
          Rect.fromCenter(center: const Offset(70, 20), width: 16, height: 20),
          -math.pi * 0.1,
          math.pi * 1.1,
          false,
          _line(width: 2.2, color: const Color(0xFFD9C3A0)),
        );
        break;
      case 'dragon':
      case 'qilin':
        _antlers(c, species.id == 'qilin');
        break;
      case 'phoenix':
      case 'fenghuang':
        _crest(c, accent);
        break;
      case 'rooster':
        _comb(c);
        break;
      case 'horse':
        _ear(c, const Offset(38, 24), 8, -0.2, main);
        _ear(c, const Offset(62, 24), 8, 0.2, main);
        break;
      case 'monkey':
        _roundEar(c, const Offset(24, 40), 9, main, light);
        _roundEar(c, const Offset(76, 40), 9, main, light);
        _monkeyTuft(c, accent);
        break;
      case 'pig':
        _ear(c, const Offset(34, 24), 9, -0.5, main);
        _ear(c, const Offset(66, 24), 9, 0.5, main);
        break;
      case 'snake':
        c.drawLine(
          const Offset(42, 18),
          const Offset(39, 12),
          _line(width: 1.6, color: accent),
        );
        c.drawLine(
          const Offset(58, 18),
          const Offset(61, 12),
          _line(width: 1.6, color: accent),
        );
        break;
      case 'xuanwu':
        // 壳沿（头像下缘一小段，保留“玄武”辨识度）
        c.drawArc(
          Rect.fromCenter(center: const Offset(50, 58), width: 50, height: 34),
          0,
          math.pi,
          false,
          _line(width: 1.3, color: accent),
        );
        break;
      default:
        _ear(c, const Offset(32, 23), 9, -0.4, main);
        _ear(c, const Offset(68, 23), 9, 0.4, main);
    }
  }

  /// 头部专属的前景细节（胡须 / 鼻子 / 舌头等，不画翅膀）。
  void _drawHeadFront(Canvas c, Color main, Color light, Color accent) {
    switch (species.id) {
      case 'cat':
      case 'tiger':
      case 'white_tiger':
        final w = _line(width: 1.1, color: accent.withValues(alpha: 0.75));
        c.drawLine(const Offset(20, 49), const Offset(32, 51), w);
        c.drawLine(const Offset(20, 54), const Offset(32, 55), w);
        c.drawLine(const Offset(80, 49), const Offset(68, 51), w);
        c.drawLine(const Offset(80, 54), const Offset(68, 55), w);
        if (species.id == 'cat') {
          c.drawPath(
            Path()
              ..moveTo(48.5, 50)
              ..lineTo(51.5, 50)
              ..lineTo(50, 52)
              ..close(),
            _fill(accent),
          );
        }
        break;
      case 'dog':
        c.drawOval(
          Rect.fromCenter(center: const Offset(50, 52), width: 15, height: 9),
          _fill(light),
        );
        c.drawCircle(const Offset(50, 49.5), 2.2, _fill(_ink));
        break;
      case 'pig':
        c.drawOval(
          Rect.fromCenter(center: const Offset(50, 52), width: 16, height: 11),
          _fill(const Color(0xFFF3A6B7)),
        );
        c.drawCircle(const Offset(47, 52), 1.2, _fill(const Color(0xFF8D4A5A)));
        c.drawCircle(const Offset(53, 52), 1.2, _fill(const Color(0xFF8D4A5A)));
        break;
      case 'horse':
        c.drawOval(
          Rect.fromCenter(center: const Offset(50, 52), width: 14, height: 9),
          _fill(light),
        );
        c.drawCircle(const Offset(47, 51), 1.2, _fill(_ink));
        c.drawCircle(const Offset(53, 51), 1.2, _fill(_ink));
        break;
      case 'rooster':
        c.drawPath(
          Path()
            ..moveTo(46, 49)
            ..lineTo(54, 49)
            ..lineTo(50, 54)
            ..close(),
          _fill(const Color(0xFFF2A33C)),
        );
        break;
      case 'snake':
        c.drawPath(
          Path()
            ..moveTo(47, 56)
            ..lineTo(53, 56)
            ..moveTo(50, 56)
            ..lineTo(50, 60),
          _line(width: 1.4, color: accent),
        );
        break;
      case 'dragon':
        final w = _line(width: 1.4, color: accent);
        c.drawPath(
          Path()
            ..moveTo(38, 52)
            ..quadraticBezierTo(30, 48, 26, 54),
          w,
        );
        c.drawPath(
          Path()
            ..moveTo(62, 52)
            ..quadraticBezierTo(70, 48, 74, 54),
          w,
        );
        break;
      case 'qilin':
        final p = _line(width: 1, color: accent.withValues(alpha: 0.5));
        for (var i = 0; i < 3; i++) {
          c.drawArc(
            Rect.fromCenter(
              center: Offset(40.0 + i * 10, 30),
              width: 8,
              height: 5,
            ),
            0,
            math.pi,
            false,
            p,
          );
        }
        break;
      default:
        break;
    }
  }

  // ── 物种：身后的耳朵 / 角 / 尾巴 ──────────────────────────────

  void _drawBackParts(Canvas c, Color main, Color light, Color accent) {
    switch (species.id) {
      case 'cat':
      case 'tiger':
      case 'white_tiger':
        _ear(c, const Offset(30, 24), 10, -0.35, main);
        _ear(c, const Offset(70, 24), 10, 0.35, main);
        break;
      case 'dog':
        c.drawOval(
          Rect.fromCenter(center: const Offset(23, 38), width: 13, height: 24),
          _fill(main),
        );
        c.drawOval(
          Rect.fromCenter(center: const Offset(23, 38), width: 13, height: 24),
          _line(width: 2),
        );
        c.drawOval(
          Rect.fromCenter(center: const Offset(77, 38), width: 13, height: 24),
          _fill(main),
        );
        c.drawOval(
          Rect.fromCenter(center: const Offset(77, 38), width: 13, height: 24),
          _line(width: 2),
        );
        break;
      case 'rabbit':
        _longEar(c, 38, main, light);
        _longEar(c, 62, main, light);
        break;
      case 'rat':
        _roundEar(c, const Offset(28, 26), 10, main, light);
        _roundEar(c, const Offset(72, 26), 10, main, light);
        break;
      case 'ox':
        c.drawArc(
          Rect.fromCenter(center: const Offset(30, 20), width: 20, height: 16),
          math.pi,
          math.pi * 0.9,
          false,
          _line(width: 3.2, color: const Color(0xFFE8D7B0)),
        );
        c.drawArc(
          Rect.fromCenter(center: const Offset(70, 20), width: 20, height: 16),
          0,
          math.pi * 0.9,
          false,
          _line(width: 3.2, color: const Color(0xFFE8D7B0)),
        );
        break;
      case 'goat':
        c.drawArc(
          Rect.fromCenter(center: const Offset(30, 20), width: 16, height: 20),
          math.pi * 0.9,
          math.pi * 1.1,
          false,
          _line(width: 3, color: const Color(0xFFD9C3A0)),
        );
        c.drawArc(
          Rect.fromCenter(center: const Offset(70, 20), width: 16, height: 20),
          -math.pi * 0.1,
          math.pi * 1.1,
          false,
          _line(width: 3, color: const Color(0xFFD9C3A0)),
        );
        break;
      case 'dragon':
      case 'qilin':
        _antlers(c, species.id == 'qilin');
        _tail(c, main, accent, waggle: (species.id == 'dragon'));
        break;
      case 'phoenix':
      case 'fenghuang':
        _crest(c, accent);
        _phoenixTail(c, accent, main);
        break;
      case 'rooster':
        _comb(c);
        _roosterTail(c, accent, main);
        break;
      case 'horse':
        _ear(c, const Offset(38, 24), 8, -0.2, main);
        _ear(c, const Offset(62, 24), 8, 0.2, main);
        // 鬃毛
        c.drawPath(
          Path()
            ..moveTo(40, 14)
            ..quadraticBezierTo(50, 4, 62, 16)
            ..quadraticBezierTo(56, 12, 50, 16)
            ..quadraticBezierTo(44, 12, 40, 14)
            ..close(),
          _fill(accent),
        );
        _tail(c, accent, accent, waggle: false);
        break;
      case 'monkey':
        _roundEar(c, const Offset(24, 40), 9, main, light);
        _roundEar(c, const Offset(76, 40), 9, main, light);
        _monkeyTuft(c, accent);
        break;
      case 'pig':
        _ear(c, const Offset(34, 24), 9, -0.5, main);
        _ear(c, const Offset(66, 24), 9, 0.5, main);
        _curlyTail(c, accent);
        break;
      case 'snake':
        // 盘在身下
        c.drawPath(
          Path()
            ..moveTo(50, 62)
            ..cubicTo(22, 74, 78, 82, 50, 92)
            ..cubicTo(36, 98, 64, 98, 60, 94),
          _line(width: 9, color: main),
        );
        c.drawLine(
          const Offset(42, 18),
          const Offset(39, 12),
          _line(width: 2, color: accent),
        );
        c.drawLine(
          const Offset(58, 18),
          const Offset(61, 12),
          _line(width: 2, color: accent),
        );
        break;
      case 'xuanwu':
        // 龟壳：从身后探出的弧形壳边
        c.drawArc(
          Rect.fromCenter(center: const Offset(50, 60), width: 74, height: 58),
          math.pi,
          math.pi,
          true,
          _line(width: 2.4),
        );
        _turtleTail(c, accent);
        break;
      default:
        _ear(c, const Offset(32, 23), 9, -0.4, main);
        _ear(c, const Offset(68, 23), 9, 0.4, main);
        _tail(c, main, accent, waggle: false);
    }
  }

  void _ear(Canvas c, Offset center, double r, double lean, Color color) {
    final p = Path()
      ..moveTo(center.dx - r, center.dy + r * 0.75)
      ..lineTo(center.dx + lean * r, center.dy - r)
      ..lineTo(center.dx + r, center.dy + r * 0.75)
      ..close();
    c.drawPath(p, _fill(color));
    c.drawPath(p, _line(width: 2));
  }

  void _longEar(Canvas c, double x, Color main, Color light) {
    final rect = Rect.fromLTWH(x - 6, 2, 12, 30);
    final rr = RRect.fromRectAndRadius(rect, const Radius.circular(6));
    c.drawRRect(rr, _fill(main));
    c.drawRRect(rr, _line(width: 2));
    c.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x - 3, 6, 6, 21),
        const Radius.circular(3),
      ),
      _fill(light),
    );
  }

  void _roundEar(
    Canvas c,
    Offset center,
    double r,
    Color main,
    Color light,
  ) {
    c.drawCircle(center, r, _fill(main));
    c.drawCircle(center, r, _line(width: 2));
    c.drawCircle(center, r * 0.55, _fill(light));
  }

  void _antlers(Canvas c, bool golden) {
    final col = golden ? const Color(0xFFD9A441) : const Color(0xFF8D9B6A);
    final p = _line(width: 2.8, color: col);
    c.drawLine(const Offset(40, 18), const Offset(34, 4), p);
    c.drawLine(const Offset(37, 11), const Offset(30, 7), p);
    c.drawLine(const Offset(60, 18), const Offset(66, 4), p);
    c.drawLine(const Offset(63, 11), const Offset(70, 7), p);
  }

  void _tail(Canvas c, Color main, Color accent, {required bool waggle}) {
    final wag = waggle ? math.sin(t * 4 * math.pi) * 0.25 : 0.0;
    c.save();
    c.translate(74, 74);
    c.rotate(wag);
    final p = Path()
      ..moveTo(0, 0)
      ..quadraticBezierTo(14, 4, 12, 20);
    c.drawPath(p, _line(width: 6, color: main));
    c.restore();
  }

  void _curlyTail(Canvas c, Color accent) {
    c.drawPath(
      Path()
        ..moveTo(76, 76)
        ..cubicTo(90, 74, 88, 88, 78, 84),
      _line(width: 2, color: accent),
    );
  }

  void _turtleTail(Canvas c, Color accent) {
    c.drawPath(
      Path()
        ..moveTo(76, 80)
        ..quadraticBezierTo(86, 78, 84, 88),
      _line(width: 3.4, color: accent),
    );
  }

  void _crest(Canvas c, Color accent) {
    final p = _line(width: 3, color: accent);
    c.drawLine(const Offset(45, 16), const Offset(40, 4), p);
    c.drawLine(const Offset(50, 15), const Offset(50, 2), p);
    c.drawLine(const Offset(55, 16), const Offset(60, 4), p);
  }

  void _phoenixTail(Canvas c, Color accent, Color main) {
    for (var i = 0; i < 3; i++) {
      c.drawPath(
        Path()
          ..moveTo(68, 72)
          ..quadraticBezierTo(86 + i * 2, 60 + i * 8, 74, 92 + i * 2),
        _line(width: 4, color: i.isEven ? accent : main),
      );
    }
  }

  void _roosterTail(Canvas c, Color accent, Color main) {
    for (var i = 0; i < 3; i++) {
      c.drawPath(
        Path()
          ..moveTo(72, 72)
          ..quadraticBezierTo(90 + i * 2, 62 + i * 6, 82, 90 + i * 2),
        _line(width: 3.2, color: i.isEven ? accent : main),
      );
    }
  }

  void _comb(Canvas c) {
    c.drawCircle(const Offset(44, 12), 5, _fill(const Color(0xFFD32F2F)));
    c.drawCircle(const Offset(50, 8), 5.5, _fill(const Color(0xFFD32F2F)));
    c.drawCircle(const Offset(56, 12), 5, _fill(const Color(0xFFD32F2F)));
  }

  void _monkeyTuft(Canvas c, Color accent) {
    c.drawPath(
      Path()
        ..moveTo(46, 14)
        ..quadraticBezierTo(50, 6, 54, 14)
        ..quadraticBezierTo(50, 12, 46, 14)
        ..close(),
      _fill(accent),
    );
  }

  // ── 花纹 ────────────────────────────────────────────────────

  void _drawMarkings(Canvas c, Color accent, Color main) {
    switch (species.id) {
      case 'tiger':
      case 'white_tiger':
        final p = _line(width: 2.2, color: const Color(0xFF3B3B3B));
        // 额头「王」
        c.drawLine(const Offset(44, 26), const Offset(56, 26), p);
        c.drawLine(const Offset(46, 31), const Offset(54, 31), p);
        c.drawLine(const Offset(50, 26), const Offset(50, 38), p);
        // 身体条纹
        c.drawLine(const Offset(24, 66), const Offset(30, 70), p);
        c.drawLine(const Offset(76, 66), const Offset(70, 70), p);
        break;
      case 'monkey':
        // 脸盘
        c.drawOval(
          Rect.fromCenter(center: const Offset(50, 44), width: 36, height: 34),
          _line(width: 1.6, color: const Color(0xFF8D6E63)),
        );
        break;
      case 'qilin':
        final p = _line(width: 1.2, color: accent.withValues(alpha: 0.5));
        for (var i = 0; i < 3; i++) {
          c.drawArc(
            Rect.fromCenter(
              center: Offset(36.0 + i * 14, 72),
              width: 10,
              height: 7,
            ),
            0,
            math.pi,
            false,
            p,
          );
        }
        break;
      default:
        break;
    }
  }

  // ── 脸：半睁眼 / 腮红 / 小嘴 ─────────────────────────────────

  void _drawFace(Canvas c, Color accent, bool blinking) {
    const eyeY = 46.0;
    for (final cx in [40.0, 60.0]) {
      if (blinking) {
        c.drawLine(
          Offset(cx - 6, eyeY),
          Offset(cx + 6, eyeY),
          _line(width: 2.4),
        );
      } else {
        // 眼白
        c.drawOval(
          Rect.fromCenter(center: Offset(cx, eyeY), width: 13, height: 12),
          _fill(Colors.white),
        );
        // 上眼皮（一条压住眼白上部的粗线，形成"生无可恋"）
        c.drawLine(
          Offset(cx - 7, eyeY - 1.5),
          Offset(cx + 7, eyeY - 1.0),
          _line(width: 2.2),
        );
        // 瞳孔靠下
        c.drawCircle(
          Offset(cx + 0.5, eyeY + 2.2),
          1.7,
          _fill(const Color(0xFF1B1B1B)),
        );
      }
    }

    // 眉心小皱纹
    final brow = _line(width: 1.4);
    c.drawLine(const Offset(47, 35), const Offset(50, 38), brow);
    c.drawLine(const Offset(53, 35), const Offset(50, 38), brow);

    // 腮红
    final blush = Paint()..color = accent.withValues(alpha: 0.30);
    c.drawOval(
      Rect.fromCenter(center: const Offset(29, 55), width: 11, height: 7),
      blush,
    );
    c.drawOval(
      Rect.fromCenter(center: const Offset(71, 55), width: 11, height: 7),
      blush,
    );

    // 嘴：小小一个「へ」
    c.drawPath(
      Path()
        ..moveTo(47, 54)
        ..quadraticBezierTo(50, 52.5, 53, 54),
      _line(width: 1.6, color: _ink),
    );
  }

  // ── 物种：前景零件 ──────────────────────────────────────────

  void _drawFrontParts(Canvas c, Color main, Color light, Color accent) {
    switch (species.id) {
      case 'cat':
      case 'tiger':
      case 'white_tiger':
        final w = _line(width: 1.1, color: accent.withValues(alpha: 0.75));
        c.drawLine(const Offset(20, 49), const Offset(32, 51), w);
        c.drawLine(const Offset(20, 54), const Offset(32, 55), w);
        c.drawLine(const Offset(80, 49), const Offset(68, 51), w);
        c.drawLine(const Offset(80, 54), const Offset(68, 55), w);
        if (species.id == 'cat') {
          // 小三角鼻
          c.drawPath(
            Path()
              ..moveTo(48.5, 50)
              ..lineTo(51.5, 50)
              ..lineTo(50, 52)
              ..close(),
            _fill(accent),
          );
        }
        break;
      case 'dog':
        c.drawOval(
          Rect.fromCenter(center: const Offset(50, 52), width: 15, height: 9),
          _fill(light),
        );
        c.drawCircle(const Offset(50, 49.5), 2.2, _fill(_ink));
        break;
      case 'pig':
        c.drawOval(
          Rect.fromCenter(center: const Offset(50, 52), width: 16, height: 11),
          _fill(const Color(0xFFF3A6B7)),
        );
        c.drawCircle(const Offset(47, 52), 1.2, _fill(const Color(0xFF8D4A5A)));
        c.drawCircle(const Offset(53, 52), 1.2, _fill(const Color(0xFF8D4A5A)));
        break;
      case 'horse':
        c.drawOval(
          Rect.fromCenter(center: const Offset(50, 52), width: 14, height: 9),
          _fill(light),
        );
        c.drawCircle(const Offset(47, 51), 1.2, _fill(_ink));
        c.drawCircle(const Offset(53, 51), 1.2, _fill(_ink));
        break;
      case 'rooster':
        c.drawPath(
          Path()
            ..moveTo(46, 49)
            ..lineTo(54, 49)
            ..lineTo(50, 54)
            ..close(),
          _fill(const Color(0xFFF2A33C)),
        );
        break;
      case 'dragon':
        // 龙须
        final w = _line(width: 1.8, color: accent);
        c.drawPath(
          Path()
            ..moveTo(36, 52)
            ..quadraticBezierTo(28, 48, 24, 54),
          w,
        );
        c.drawPath(
          Path()
            ..moveTo(64, 52)
            ..quadraticBezierTo(72, 48, 76, 54),
          w,
        );
        // 小翅膀
        c.drawPath(
          Path()
            ..moveTo(24, 66)
            ..quadraticBezierTo(10, 58, 14, 76)
            ..quadraticBezierTo(22, 72, 24, 66)
            ..close(),
          _fill(light),
        );
        // 背刺
        final spike = _line(width: 2, color: _ink);
        c.drawLine(const Offset(70, 30), const Offset(74, 24), spike);
        c.drawLine(const Offset(74, 36), const Offset(79, 31), spike);
        break;
      case 'qilin':
        c.drawPath(
          Path()
            ..moveTo(24, 66)
            ..quadraticBezierTo(12, 60, 16, 76)
            ..quadraticBezierTo(22, 72, 24, 66)
            ..close(),
          _fill(accent.withValues(alpha: 0.35)),
        );
        break;
      case 'phoenix':
      case 'fenghuang':
        c.drawPath(
          Path()
            ..moveTo(24, 64)
            ..quadraticBezierTo(8, 58, 12, 78)
            ..quadraticBezierTo(21, 72, 24, 64)
            ..close(),
          _fill(accent.withValues(alpha: 0.7)),
        );
        c.drawPath(
          Path()
            ..moveTo(76, 64)
            ..quadraticBezierTo(92, 58, 88, 78)
            ..quadraticBezierTo(79, 72, 76, 64)
            ..close(),
          _fill(accent.withValues(alpha: 0.7)),
        );
        break;
      case 'snake':
        c.drawPath(
          Path()
            ..moveTo(46, 54)
            ..lineTo(50, 58)
            ..lineTo(54, 54),
          _line(width: 1.6, color: accent),
        );
        break;
      case 'xuanwu':
        // 壳纹
        final p = _line(width: 1.6, color: accent.withValues(alpha: 0.65));
        c.drawArc(
          Rect.fromCenter(center: const Offset(50, 62), width: 40, height: 30),
          math.pi,
          math.pi,
          false,
          p,
        );
        for (var i = 0; i < 3; i++) {
          c.drawLine(
            Offset(38.0 + i * 12, 58),
            Offset(38.0 + i * 12, 74),
            p,
          );
        }
        break;
      default:
        break;
    }
  }

  // ── 换装 ────────────────────────────────────────────────────

  void _drawOutfit(Canvas c, Color accent) {
    switch (outfit) {
      case 'hat':
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(40, 1, 20, 12),
            const Radius.circular(3),
          ),
          _fill(const Color(0xFF37474F)),
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(32, 12, 36, 4),
            const Radius.circular(2),
          ),
          _fill(const Color(0xFF263238)),
        );
        break;
      case 'scarf':
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(30, 64, 40, 9),
            const Radius.circular(4.5),
          ),
          _fill(accent),
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(30, 64, 40, 9),
            const Radius.circular(4.5),
          ),
          _line(width: 1.6),
        );
        break;
      case 'glasses':
        final p = _line(width: 1.8, color: const Color(0xFF37474F));
        c.drawCircle(const Offset(40, 46), 8, p);
        c.drawCircle(const Offset(60, 46), 8, p);
        c.drawLine(const Offset(48, 46), const Offset(52, 46), p);
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
            ..moveTo(66, 20)
            ..lineTo(76, 14)
            ..lineTo(76, 26)
            ..close(),
          _fill(accent),
        );
        c.drawPath(
          Path()
            ..moveTo(66, 20)
            ..lineTo(56, 14)
            ..lineTo(56, 26)
            ..close(),
          _fill(accent),
        );
        c.drawCircle(const Offset(66, 20), 2.6, _fill(accent));
        break;
      default:
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _InkPetPainter old) =>
      old.t != t ||
      old.mood != mood ||
      old.outfit != outfit ||
      old.headOnly != headOnly ||
      old.species.id != species.id;
}
