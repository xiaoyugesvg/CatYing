part of 'pet_view.dart';

// ══════════════════════════════════════════════════════════════
// 图片宠物：去背景 + 只保留本体
// ══════════════════════════════════════════════════════════════

class _PetCutout {
  const _PetCutout(this.image, this.crop);

  final ui.Image image;

  /// 宠物本体在图片里的包围盒（像素坐标）。
  final ui.Rect crop;
}

/// 同一张图只处理一次（处理结果常驻内存）。
final Map<String, Future<_PetCutout?>> _cutoutCache = {};

Future<_PetCutout?> _cutoutFor(
  String key,
  Future<Uint8List> Function() loader,
) {
  return _cutoutCache.putIfAbsent(key, () async {
    try {
      final bytes = await loader();
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 360);
      final frame = await codec.getNextFrame();
      final src = frame.image;
      final w = src.width;
      final h = src.height;
      final bd = await src.toByteData(format: ui.ImageByteFormat.rawRgba);
      src.dispose();
      if (bd == null || w <= 0 || h <= 0) return null;
      // 复制一份：worker 会原地改写 alpha
      final raw = Uint8List.fromList(bd.buffer.asUint8List());
      final res = await compute(_cutoutWorker, <Object?>[raw, w, h]);
      if (res == null) return null;
      final out = res[0] as Uint8List;
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        out,
        w,
        h,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      final img = await completer.future;
      return _PetCutout(
        img,
        ui.Rect.fromLTRB(
          (res[1] as int).toDouble(),
          (res[2] as int).toDouble(),
          (res[3] as int).toDouble(),
          (res[4] as int).toDouble(),
        ),
      );
    } catch (_) {
      return null;
    }
  });
}

/// [compute] worker：去掉与边缘连通的近白像素，并返回宠物包围盒。
///
/// 只删「与画布边缘连通」的白色 → 宠物肚子/眼睛里的白色不会被误删。
List<Object?>? _cutoutWorker(List<Object?> args) {
  final bytes = args[0] as Uint8List;
  final w = args[1] as int;
  final h = args[2] as int;
  if (w <= 0 || h <= 0) return null;
  final bg = Uint8List(w * h);
  final stack = <int>[];

  bool nearWhite(int idx) {
    final i = idx * 4;
    return bytes[i] >= 230 && bytes[i + 1] >= 230 && bytes[i + 2] >= 224;
  }

  void seed(int x, int y) {
    if (x < 0 || y < 0 || x >= w || y >= h) return;
    final idx = y * w + x;
    if (bg[idx] != 0 || !nearWhite(idx)) return;
    bg[idx] = 1;
    stack.add(idx);
  }

  for (var x = 0; x < w; x++) {
    seed(x, 0);
    seed(x, h - 1);
  }
  for (var y = 0; y < h; y++) {
    seed(0, y);
    seed(w - 1, y);
  }
  while (stack.isNotEmpty) {
    final idx = stack.removeLast();
    final x = idx % w;
    final y = idx ~/ w;
    seed(x - 1, y);
    seed(x + 1, y);
    seed(x, y - 1);
    seed(x, y + 1);
  }

  var minX = w, minY = h, maxX = -1, maxY = -1;
  // 先把背景透明化
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final idx = y * w + x;
      if (bg[idx] == 1) bytes[idx * 4 + 3] = 0;
    }
  }

  // ── 只保留最大的连通块（宠物本体）──────────────────────────
  // 生肖插画顶部还有书法标题「戌狗」和红色印章，它们与宠物不连通；
  // 如果按所有非白像素取包围盒，标题会把画面撑高、宠物又变小。
  final visited = Uint8List(w * h);

  void pushNeighbor(int nx, int ny) {
    if (nx < 0 || ny < 0 || nx >= w || ny >= h) return;
    final n = ny * w + nx;
    if (bg[n] == 1 || visited[n] == 1) return;
    visited[n] = 1;
    stack.add(n);
  }

  var bestCount = 0;
  for (var i = 0; i < w * h; i++) {
    if (bg[i] == 1 || visited[i] == 1) continue;
    visited[i] = 1;
    stack.add(i);
    var count = 0;
    var cMinX = w, cMinY = h, cMaxX = -1, cMaxY = -1;
    while (stack.isNotEmpty) {
      final idx = stack.removeLast();
      count++;
      final x = idx % w;
      final y = idx ~/ w;
      if (x < cMinX) cMinX = x;
      if (y < cMinY) cMinY = y;
      if (x > cMaxX) cMaxX = x;
      if (y > cMaxY) cMaxY = y;
      pushNeighbor(x - 1, y);
      pushNeighbor(x + 1, y);
      pushNeighbor(x, y - 1);
      pushNeighbor(x, y + 1);
    }
    if (count > bestCount) {
      bestCount = count;
      minX = cMinX;
      minY = cMinY;
      maxX = cMaxX;
      maxY = cMaxY;
    }
  }
  if (maxX < minX || maxY < minY) return null;
  return <Object?>[
    bytes,
    math.max(0, minX - 1),
    math.max(0, minY - 1),
    math.min(w, maxX + 2),
    math.min(h, maxY + 2),
  ];
}

/// 把去背后的图片按原比例画在画布上（底部对齐，不裁圆、不留白）。
class _CutoutPetView extends StatelessWidget {
  const _CutoutPetView({
    required this.cacheKey,
    required this.loader,
    required this.size,
    this.fallback,
  });

  final String cacheKey;
  final Future<Uint8List> Function() loader;
  final double size;
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_PetCutout?>(
      future: _cutoutFor(cacheKey, loader),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return SizedBox(width: size, height: size);
        }
        final cut = snap.data;
        if (cut == null) {
          return SizedBox(width: size, height: size, child: fallback);
        }
        return SizedBox(
          width: size,
          height: size,
          child: CustomPaint(painter: _CutoutPainter(cut)),
        );
      },
    );
  }
}

class _CutoutPainter extends CustomPainter {
  _CutoutPainter(this.cut);

  final _PetCutout cut;

  @override
  void paint(Canvas canvas, Size size) {
    final src = cut.crop;
    if (src.width <= 0 || src.height <= 0) return;
    final aspect = src.width / src.height;
    var dw = size.width;
    var dh = dw / aspect;
    if (dh > size.height) {
      dh = size.height;
      dw = dh * aspect;
    }
    canvas.drawImageRect(
      cut.image,
      src,
      Rect.fromLTWH((size.width - dw) / 2, size.height - dh, dw, dh),
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  @override
  bool shouldRepaint(_CutoutPainter old) => old.cut != cut;
}

/// 给**图片宠物**叠加换装（QQ秀式）。
///
/// 图片宠物没法像矢量宠物那样精确知道头/身体坐标，这里按
/// 「图片本体铺满画布、头部在上半部」的常见构图放配饰：
///   头饰 y≈8%、面部 y≈48%、颈饰 y≈74%、手持在右下。
class _ImageOutfitPainter extends CustomPainter {
  _ImageOutfitPainter(this.outfits, {this.backgroundOnly = false});

  final Map<PetOutfitSlot, String> outfits;
  final bool backgroundOnly;

  static const _ink = Color(0xFF232323);

  Paint _fill(Color c) => Paint()..color = c;

  Paint _line({double width = 2, Color color = _ink}) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 100.0;
    canvas.scale(s, s);
    if (backgroundOnly) {
      _background(canvas);
      return;
    }
    _top(canvas);
    _neck(canvas);
    _hand(canvas);
    _face(canvas);
    _hat(canvas);
  }

  void _background(Canvas c) {
    switch (outfits[PetOutfitSlot.background]) {
      case 'moon':
        c.drawCircle(
          const Offset(50, 48),
          38,
          _fill(const Color(0xFFFFE9A8).withValues(alpha: 0.30)),
        );
        c.drawCircle(
          const Offset(50, 48),
          38,
          _line(width: 1.4, color: const Color(0xFFE8C766)),
        );
        break;
      case 'stars':
        final p = _fill(const Color(0xFFFFD54F).withValues(alpha: 0.75));
        for (final o in const [
          Offset(18, 22),
          Offset(82, 20),
          Offset(86, 60),
          Offset(14, 64),
        ]) {
          c.drawCircle(o, 2.4, p);
        }
        break;
    }
  }

  void _hat(Canvas c) {
    switch (outfits[PetOutfitSlot.hat]) {
      case 'hat':
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(34, 20, 32, 4),
            const Radius.circular(2),
          ),
          _fill(const Color(0xFF263238)),
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(42, 8, 16, 12),
            const Radius.circular(3),
          ),
          _fill(const Color(0xFF37474F)),
        );
        break;
      case 'cap':
        c.drawArc(
          Rect.fromCenter(center: const Offset(48, 20), width: 28, height: 22),
          math.pi,
          math.pi,
          true,
          _fill(const Color(0xFF4FC3F7)),
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(48, 18, 20, 4),
            const Radius.circular(2),
          ),
          _fill(const Color(0xFF4FC3F7)),
        );
        break;
      case 'crown':
        c.drawPath(
          Path()
            ..moveTo(38, 18)
            ..lineTo(42, 6)
            ..lineTo(46, 14)
            ..lineTo(50, 4)
            ..lineTo(54, 14)
            ..lineTo(58, 6)
            ..lineTo(62, 18)
            ..close(),
          _fill(const Color(0xFFF2C14E)),
        );
        break;
      case 'bow':
        c.drawPath(
          Path()
            ..moveTo(66, 18)
            ..lineTo(76, 12)
            ..lineTo(76, 24)
            ..close(),
          _fill(const Color(0xFFFF8FA3)),
        );
        c.drawPath(
          Path()
            ..moveTo(66, 18)
            ..lineTo(56, 12)
            ..lineTo(56, 24)
            ..close(),
          _fill(const Color(0xFFFF8FA3)),
        );
        c.drawCircle(const Offset(66, 18), 2.8, _fill(const Color(0xFFFF8FA3)));
        break;
    }
  }

  void _face(Canvas c) {
    switch (outfits[PetOutfitSlot.face]) {
      case 'glasses':
        final p = _line(width: 1.8, color: const Color(0xFF37474F));
        c.drawCircle(const Offset(40, 48), 7, p);
        c.drawCircle(const Offset(60, 48), 7, p);
        c.drawLine(const Offset(47, 48), const Offset(53, 48), p);
        break;
      case 'shades':
        final fill = _fill(const Color(0xFF263238));
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(32, 43, 16, 9),
            const Radius.circular(3),
          ),
          fill,
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(52, 43, 16, 9),
            const Radius.circular(3),
          ),
          fill,
        );
        break;
    }
  }

  void _neck(Canvas c) {
    switch (outfits[PetOutfitSlot.neck]) {
      case 'scarf':
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(30, 72, 40, 8),
            const Radius.circular(4),
          ),
          _fill(const Color(0xFFFF8FA3)),
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(32, 77, 8, 12),
            const Radius.circular(3),
          ),
          _fill(const Color(0xFFFF8FA3)),
        );
        break;
      case 'tie':
        c.drawPath(
          Path()
            ..moveTo(46, 72)
            ..lineTo(54, 72)
            ..lineTo(50, 77)
            ..close(),
          _fill(const Color(0xFFD32F2F)),
        );
        c.drawPath(
          Path()
            ..moveTo(47, 77)
            ..lineTo(53, 77)
            ..lineTo(50, 88)
            ..close(),
          _fill(const Color(0xFFD32F2F)),
        );
        break;
    }
  }

  void _top(Canvas c) {
    switch (outfits[PetOutfitSlot.top]) {
      case 'hoodie':
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(26, 70, 48, 10),
            const Radius.circular(6),
          ),
          _fill(const Color(0xFF64B5F6).withValues(alpha: 0.85)),
        );
        break;
      case 'vest':
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(26, 70, 14, 16),
            const Radius.circular(4),
          ),
          _fill(const Color(0xFF8D6E63).withValues(alpha: 0.85)),
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(60, 70, 14, 16),
            const Radius.circular(4),
          ),
          _fill(const Color(0xFF8D6E63).withValues(alpha: 0.85)),
        );
        break;
    }
  }

  void _hand(Canvas c) {
    switch (outfits[PetOutfitSlot.hand]) {
      case 'book':
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(68, 70, 18, 13),
            const Radius.circular(2),
          ),
          _fill(const Color(0xFFF5F0E6)),
        );
        c.drawLine(
          const Offset(77, 70),
          const Offset(77, 83),
          _line(width: 1.4, color: const Color(0xFF8D6E63)),
        );
        break;
      case 'coffee':
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(70, 72, 13, 13),
            const Radius.circular(3),
          ),
          _fill(Colors.white),
        );
        c.drawArc(
          Rect.fromCenter(center: const Offset(85, 78), width: 6, height: 8),
          -math.pi / 2,
          math.pi,
          false,
          _line(width: 1.6, color: Colors.white),
        );
        break;
      case 'balloon':
        c.drawCircle(
          const Offset(78, 46),
          9,
          _fill(const Color(0xFFFF8FA3).withValues(alpha: 0.9)),
        );
        c.drawPath(
          Path()
            ..moveTo(78, 55)
            ..quadraticBezierTo(72, 64, 74, 72),
          _line(width: 0.9, color: const Color(0xFFFF8FA3)),
        );
        break;
    }
  }

  @override
  bool shouldRepaint(_ImageOutfitPainter old) =>
      old.backgroundOnly != backgroundOnly ||
      old.outfits.length != outfits.length ||
      !old.outfits.entries.every((e) => outfits[e.key] == e.value);
}
