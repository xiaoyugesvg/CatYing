part of 'pet_view.dart';

/// 矢量宠物画笔的**共享状态 + 主流程**。
///
/// 为什么要有 `_InkPetPainterBase`：Dart 不允许一个 class 跨 part 文件
/// （实测 `Expected to find '}'`），所以绘制方法只能挪进 mixin；而 mixin
/// **看不到 `on` 类型的静态成员**（实测 `Undefined name 'x'`），因此
/// `_ink` 提到了库级常量。字段与 `_fill` / `_line` 留在基类，
/// 两个 mixin 靠 `on _InkPetPainterBase` 直接用。

/// 墨线色。原来是 `_InkPetPainter._ink` 静态常量，因 mixin 访问不到
/// 类静态成员而提到库级；`_ImageOutfitPainter` 另有一份同值静态，互不影响。
const Color _ink = Color(0xFF232323);

abstract class _InkPetPainterBase extends CustomPainter {
  _InkPetPainterBase({
    required this.species,
    required this.outfit,
    required this.outfits,
    required this.t,
    required this.mood,
    this.headOnly = false,
  });

  final PetSpeciesInfo species;
  final String outfit;

  /// 多部位穿搭：部位 → 单品 id（QQ秀式）
  final Map<PetOutfitSlot, String> outfits;
  final double t;
  final double mood;
  final bool headOnly;

  Paint _fill(Color c) => Paint()..color = c;

  Paint _line({double width = 2.2, Color? color}) => Paint()
    ..color = color ?? _ink
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
}

class _InkPetPainter extends _InkPetPainterBase
    with _PetBodyPaint, _PetOutfitPaint {
  _InkPetPainter({
    required super.species,
    required super.outfit,
    required super.outfits,
    required super.t,
    required super.mood,
    super.headOnly,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 100.0;
    canvas.save();
    canvas.scale(scale, scale);

    final bob = math.sin(t * 2 * math.pi) * 1.6;
    final breathe = 1 + math.sin(t * 2 * math.pi) * 0.012;
    // 约每 4.2 秒眨一次眼
    // 调用方传的是 0~4 秒进度；用 4.0 取模，眨眼窗口必须在 4.0 以内，
    // 否则 (t % 4.2) > 4.05 永远不成立（桌宠永远不眨眼）。
    final blinking = t > 0 && (t % 4.0) > 3.86;

    final main = species.palette[0];
    final light = species.palette[1];
    final accent = species.palette[2];

    if (headOnly) {
      _paintHeadOnly(canvas, main, light, accent, blinking);
      canvas.restore();
      return;
    }

    // 背景（穿戴「月光 / 星芒」时）画在最底层
    _drawOutfitBackground(canvas, accent);

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

    // 多部位换装（QQ秀式：上衣 → 颈饰 → 手持 → 面部 → 头饰）
    _drawOutfits(canvas, main, light, accent);

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

    // 头像也能戴头饰 / 眼镜 / 围巾（QQ秀式换装在头像上同样可见）
    _drawNeck(c, accent);
    _drawFaceAccessory(c);
    _drawHat(c, accent);

    c.restore();
  }

  @override
  bool shouldRepaint(covariant _InkPetPainter old) =>
      old.t != t ||
      old.mood != mood ||
      old.outfit != outfit ||
      old.headOnly != headOnly ||
      old.species.id != species.id ||
      old.outfits.length != outfits.length ||
      !old.outfits.entries.every((e) => outfits[e.key] == e.value);
}
