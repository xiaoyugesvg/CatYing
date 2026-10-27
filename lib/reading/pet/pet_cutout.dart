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
    this.outfits = const {},
    this.fallback,
  });

  final String cacheKey;
  final Future<Uint8List> Function() loader;
  final double size;

  /// 穿戴：交给 [_CutoutPainter] 在**知道图片真实落点之后**再叠，
  /// 这样配饰能贴着宠物的头/身子，而不是按整幅画布瞎猜。
  final Map<PetOutfitSlot, String> outfits;
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
          child: CustomPaint(painter: _CutoutPainter(cut, outfits)),
        );
      },
    );
  }
}

class _CutoutPainter extends CustomPainter {
  _CutoutPainter(this.cut, this.outfits);

  final _PetCutout cut;
  final Map<PetOutfitSlot, String> outfits;

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
    final dest = Rect.fromLTWH((size.width - dw) / 2, size.height - dh, dw, dh);
    canvas.drawImageRect(
      cut.image,
      src,
      dest,
      Paint()..filterQuality = FilterQuality.medium,
    );
    if (outfits.isNotEmpty) _drawOutfits(canvas, dest);
  }

  /// 图片宠物没法知道真实关节坐标，退一步：按**图片实际落点**估一颗虚拟圆团。
  ///
  /// 常见 Q 版插画是 3:4 全身像，头大约占宽度的 50%、纵向 25% 处；
  /// 把这颗"虚拟头团"的尺寸交给 [PetOutfitPainter]，帽檐/镜片/领口的相对
  /// 位置就和矢量宠物完全一致 —— 比旧版按整幅画布百分比摆放准得多。
  void _drawOutfits(Canvas canvas, Rect dest) {
    final headW = dest.width * 0.52;
    final k = headW / 74.0;
    canvas.save();
    canvas.translate(dest.center.dx, dest.top + dest.height * 0.26);
    canvas.scale(k);
    PetOutfitPainter(outfits: outfits).paintAll(canvas);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CutoutPainter old) =>
      old.cut != cut ||
      old.outfits.length != outfits.length ||
      !old.outfits.entries.every((e) => outfits[e.key] == e.value);
}

/// 给**图片宠物**叠加换装（GIF 等拿不到抠图落点的情况）。
///
/// 静态图走 [_CutoutPainter]（能拿到真实落点，配饰贴得准）；GIF 逐帧没法
/// 抠图，只能按「整幅画面 = 宠物本体」的常见构图估算一颗虚拟圆团，
/// 再用同一套 [PetOutfitPainter] 画 —— 至少帽檐/领口的相对位置是一致的。
class _ImageOutfitPainter extends CustomPainter {
  _ImageOutfitPainter(this.outfits);

  final Map<PetOutfitSlot, String> outfits;

  @override
  void paint(Canvas canvas, Size size) {
    if (outfits.isEmpty) return;
    final r = Rect.fromLTWH(0, 0, size.width, size.height);
    final headW = r.width * 0.52;
    final k = headW / 74.0;
    canvas.save();
    canvas.translate(r.center.dx, r.top + r.height * 0.26);
    canvas.scale(k);
    PetOutfitPainter(outfits: outfits).paintAll(canvas);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ImageOutfitPainter old) =>
      old.outfits.length != outfits.length ||
      !old.outfits.entries.every((e) => outfits[e.key] == e.value);
}
