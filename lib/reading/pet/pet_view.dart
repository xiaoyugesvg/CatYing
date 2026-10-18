import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'pet_models.dart';

/// 手绘 Q 版桌宠（CustomPainter，无图片素材依赖）。
///
/// 用户 2026-10-18：
///   · 内置桌宠改成 **QQ 秀风格小人**（小Q / 小秀 / 书呆），可多部位换装；
///   · 十二生肖插画只作为**登录头像**，不再出现在桌宠图鉴里。
///
/// 之所以用矢量绘制：宠物要每帧呼吸/眨眼/摆手臂，单张 PNG 做不到；
/// 人形与生肖头像共用同一套 `PetView` 入口，按 `species.qq` 分派画笔。
class PetView extends StatelessWidget {
  const PetView({
    super.key,
    required this.species,
    required this.outfit,
    required this.t,
    this.size = 120,
    this.mood = 80,
    this.headOnly = false,
    this.outfits = const {},
  });

  final PetSpeciesInfo species;

  /// 旧版单件穿搭（保留兼容）；有 [outfits] 时以多部位为准。
  final String outfit;

  /// 多部位穿搭：`部位名 → 单品 id`（QQ秀式）
  final Map<String, String> outfits;

  /// 动画进度（秒），由外部 AnimationController 推进
  final double t;
  final double size;
  final double mood;

  /// 只画头部（头像用）：把脸放大铺满圆形，不画身体/脚/尾巴。
  final bool headOnly;

  /// 把「部位名 → 单品 id」归一化成枚举键（兼容旧单件）。
  Map<PetOutfitSlot, String> get _equipped {
    final out = <PetOutfitSlot, String>{};
    for (final e in outfits.entries) {
      final slot = PetOutfitSlot.values
          .where((s) => s.name == e.key)
          .firstOrNull;
      final item = PetOutfits.byId(e.value);
      if (slot != null && item != null && item.slot == slot) {
        out[slot] = item.id;
      }
    }
    if (out.isEmpty) {
      final legacy = PetOutfits.byId(outfit);
      if (legacy != null) out[legacy.slot] = legacy.id;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final asset = species.imageAsset;
    if (asset != null && !headOnly) {
      return _buildImagePet(asset);
    }
    // 矢量宠物：默认画**全身**（大脑袋 + 小身体），换装才有的放矢；
    // 头像模式（[headOnly] = true）仍放大头部。
    //
    // QQ 秀风格（用户 2026-10-18）：人形小人 + 多部位换装；
    // 生肖插画只作为登录头像，不再走桌宠绘制。
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: species.qq
            ? _QqPetPainter(
                species: species,
                outfits: _equipped,
                t: t,
                mood: mood,
                headOnly: headOnly,
              )
            : _InkPetPainter(
                species: species,
                outfit: outfit,
                outfits: _equipped,
                t: t,
                mood: mood,
                headOnly: headOnly,
              ),
      ),
    );
  }

  /// 图片皮肤：**去背景 + 只保留宠物本体**，并加更有存在感的动效。
  ///
  /// ── 旧实现的问题（用户 2026-10-18）────────────────────────────
  /// 原来把 3:4 插画塞进一个白色圆形贴纸里（`BoxShape.circle` +
  /// `BoxFit.cover` + 底部对齐），插画自带的白底 + 圆形留白 ⇒
  /// 悬浮在桌面上时"一个大白圆里一只小动物"，又占地方又不好看。
  ///
  /// 现在：把图片丢掉与边缘连通的近白像素（保留宠物身上的白肚皮），
  /// 再裁到宠物本体的包围盒，按原比例绘制 —— 悬浮在桌面上就是一只
  /// 干净的贴纸宠物，没有白底和多余留白。
  Widget _buildImagePet(String asset) {
    // 呼吸 / 摇摆 / 浮动 + 每 6 秒一次小跳（比原来的小幅平移更"活"）
    final cycle = t * 2 * math.pi;
    final breathe = 1 + math.sin(cycle * 2) * 0.018;
    final sway = math.sin(cycle + 0.8) * 0.035;
    final bob = math.sin(cycle) * 2.0 + math.sin(cycle * 0.5) * 1.0;
    final hopPhase = (t % 6.0) / 6.0;
    final hop = math.pow(math.max(0.0, math.sin(hopPhase * math.pi)), 8) * 7.0;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          // 影子：跳起来时收小，落地时铺开
          Positioned(
            bottom: size * 0.015,
            child: Transform.scale(
              scale: (1 - hop / 26).clamp(0.6, 1.0),
              child: Container(
                width: size * 0.46,
                height: size * 0.055,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          ),
          Transform.translate(
            offset: Offset(0, -(bob + hop)),
            child: Transform.rotate(
              angle: sway,
              child: Transform.scale(
                scale: breathe,
                child: SizedBox(
                  width: size,
                  height: size,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_equipped[PetOutfitSlot.background] != null)
                        CustomPaint(
                          painter: _ImageOutfitPainter(
                            _equipped,
                            backgroundOnly: true,
                          ),
                        ),
                      _CutoutPetView(
                        cacheKey: 'asset:$asset',
                        loader: () async =>
                            (await rootBundle.load(asset)).buffer.asUint8List(),
                        size: size,
                        fallback: Image.asset(
                          asset,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                        ),
                      ),
                      if (_equipped.isNotEmpty)
                        CustomPaint(
                          painter: _ImageOutfitPainter(_equipped),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 用户自定义桌宠图片（PNG / GIF）。
///
/// 用户 2026-10-18：「能自定义增加 PNG 或 GIF 图片」。
/// 直接用 `Image.file`：GIF 自动播放；**不裁圆、不套白底贴纸**，
/// 保留原图（自定义图常带透明背景，套底反而难看）。
class CustomPetImage extends StatelessWidget {
  const CustomPetImage({
    super.key,
    required this.path,
    this.size = 120,
    this.bob = 0,
    this.outfits = const {},
  });

  final String path;
  final double size;

  /// 上下浮动像素（由动画进度算好传进来）
  final double bob;

  /// 当前穿戴（自定义图片同样支持换装，叠加位置按常见构图估算）。
  final Map<PetOutfitSlot, String> outfits;

  @override
  Widget build(BuildContext context) {
    final f = File(path);
    if (!f.existsSync()) {
      // 图片被清理 / 换机丢失时别留一个空白桌宠：回退到 QQ 小人
      return PetView(
        species: PetSpecies.qqBoy,
        outfit: PetOutfits.none.id,
        outfits: {
          for (final e in outfits.entries) e.key.name: e.value,
        },
        t: bob / 10,
        size: size,
      );
    }
    final isGif = path.toLowerCase().endsWith('.gif');
    final image = isGif
        ? Image.file(f, fit: BoxFit.contain, gaplessPlayback: true)
        : _CutoutPetView(
            cacheKey: 'file:$path',
            loader: f.readAsBytes,
            size: size,
            fallback: Image.file(
              f,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          );
    return SizedBox(
      width: size,
      height: size,
      child: Transform.translate(
        offset: Offset(0, bob),
        // GIF 保留原样（逐帧动画无法做静态抠图）；
        // 静态图同样做「去白底 + 裁到本体」，自定义图也不会带一圈白。
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (outfits[PetOutfitSlot.background] != null)
              CustomPaint(
                painter: _ImageOutfitPainter(
                  outfits,
                  backgroundOnly: true,
                ),
              ),
            image,
            if (outfits.isNotEmpty)
              CustomPaint(painter: _ImageOutfitPainter(outfits)),
          ],
        ),
      ),
    );
  }
}

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

/// QQ 秀风格人形桌宠（用户 2026-10-18：「直接抄 QQ 秀的」）。
///
/// 与旧生肖团子的区别：
///   · 不再是动物身体 + 耳朵尾巴，而是**大头 Q 版小人**（头发 / 脸 / 上衣 /
///     手臂 / 腿），换装部位按人形坐标落位；
///   · 生肖插画（dog/rat/dragon…）只作为登录头像，不再参与这里的绘制。
class _QqPetPainter extends CustomPainter {
  _QqPetPainter({
    required this.species,
    required this.outfits,
    required this.t,
    required this.mood,
    this.headOnly = false,
  });

  final PetSpeciesInfo species;
  final Map<PetOutfitSlot, String> outfits;
  final double t;
  final double mood;
  final bool headOnly;

  static const Color _ink = Color(0xFF2B2B2B);
  static const Color _skin = Color(0xFFFFDFC4);

  Paint _fill(Color c) => Paint()..color = c;

  Paint _line({double width = 2, Color color = _ink}) => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  // ── 立体感（用户 2026-10-18：「不应该是 3D 虚拟形象吗？」）──────
  //
  // 当前工程是 iOS TrollStore 侧载，不能新增原生插件 / 3D 引擎
  // （flutter_gl / model_viewer 都会引入原生依赖）⇒ 用**2.5D 立体渲染**
  // 模拟 3D 虚拟形象：光源在左上、体积渐变、边缘高光、接触阴影，
  // 再加一个很慢的转身视差（脸/眼镜左右轻移）。
  // 渐变 Paint 只跟颜色有关 ⇒ 按颜色缓存，避免每帧重复 createShader
  //（桌宠悬浮层每帧重绘，60fps 下重复建 shader 会白白增加 GPU/CPU 开销）。
  static final Map<int, Paint> _skinCache = {};
  static final Map<int, Paint> _hairCache = {};
  static final Map<int, Paint> _clothCache = {};
  static final Map<int, Paint> _limbCache = {};

  Paint _skinPaint() => _skinCache.putIfAbsent(
    0,
    () => Paint()
      ..shader = const RadialGradient(
        center: Alignment(-0.38, -0.46),
        radius: 0.95,
        colors: [Color(0xFFFFF4E9), _skin, Color(0xFFE6B48C)],
        stops: [0, 0.55, 1],
      ).createShader(Rect.fromCircle(center: const Offset(50, 36), radius: 25)),
  );

  Paint _hairPaint(Color hair) => _hairCache.putIfAbsent(
    hair.hashCode,
    () => Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.lerp(hair, Colors.white, 0.30)!,
          hair,
          Color.lerp(hair, Colors.black, 0.24)!,
        ],
        stops: const [0, 0.55, 1],
      ).createShader(const Rect.fromLTWH(27, 8, 46, 52)),
  );

  Paint _clothPaint(Color c) => _clothCache.putIfAbsent(
    c.hashCode,
    () => Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.lerp(c, Colors.white, 0.28)!,
          c,
          Color.lerp(c, Colors.black, 0.22)!,
        ],
        stops: const [0, 0.55, 1],
      ).createShader(const Rect.fromLTWH(26, 50, 48, 44)),
  );

  Paint _limbPaint(Color c) => _limbCache.putIfAbsent(
    c.hashCode,
    () => _line(width: 8, color: c)
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.lerp(c, Colors.white, 0.24)!,
          c,
          Color.lerp(c, Colors.black, 0.18)!,
        ],
      ).createShader(const Rect.fromLTWH(24, 58, 52, 26)),
  );

  bool get _girl => species.id == 'qq_girl';
  bool get _scholar => species.id == 'qq_scholar';

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 100.0;
    canvas.scale(s, s);

    final bob = math.sin(t * 2 * math.pi) * 1.4;
    final breathe = 1 + math.sin(t * 2 * math.pi) * 0.012;
    // 调用方传的是 0~4 秒进度；用 4.0 取模，眨眼窗口必须在 4.0 以内，
    // 否则 (t % 4.2) > 4.05 永远不成立（桌宠永远不眨眼）。
    final blinking = t > 0 && (t % 4.0) > 3.86;
    // 很慢的转身：脸 / 眼镜左右轻移，配合渐变产生"立体转身"的错觉。
    // ⚠️ 周期必须整除调用方的 4 秒进度（这里 0.25 = 每 4 秒一个完整来回），
    //    否则 t 从 4 回到 0 时 faceShift 会突然跳一下。
    final turn = math.sin(t * 2 * math.pi * 0.25);
    final faceShift = turn * 2.4;

    final clothes = species.palette[0];
    final hair = species.palette[2];

    if (headOnly) {
      canvas.save();
      canvas.translate(50, 52);
      canvas.scale(1.45, 1.45);
      canvas.translate(-50, -36);
      _hairBack(canvas, hair);
      _head(canvas);
      _hairFront(canvas, hair);
      _face(canvas, clothes, blinking, shift: faceShift);
      _neck(canvas);
      _faceAccessory(canvas, shift: faceShift);
      _hat(canvas, clothes);
      canvas.restore();
      return;
    }

    _background(canvas, clothes);
    canvas.translate(0, bob);

    // 地面阴影（径向渐变，比纯色更有"落地"的体积感）
    final shadowRect = Rect.fromCenter(
      center: const Offset(50, 96),
      width: 56,
      height: 14,
    );
    canvas.drawOval(
      shadowRect,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.black.withValues(alpha: 0.20),
            Colors.black.withValues(alpha: 0.06),
            Colors.transparent,
          ],
          stops: const [0, 0.6, 1],
        ).createShader(shadowRect),
    );

    // 腿 + 鞋（QQ宠物风格：更短更圆的小脚）
    final pants = Color.lerp(clothes, Colors.black, 0.22)!;
    // ⚠️ 腿是 drawRRect **填充**，不能用 _limbPaint（stroke，会把腿画成空心轮廓）
    final legPaint = _clothPaint(pants);
    for (final x in [43.0, 54.0]) {
      // 短粗的小腿
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 84, 6, 8),
          const Radius.circular(3),
        ),
        legPaint,
      );
      // 圆圆的小鞋
      canvas.drawCircle(Offset(x + 3, 93), 4.5, _fill(const Color(0xFF3A3A3A)));
    }

    // 身体（QQ宠物风格：更圆的椭圆形，不是圆角矩形）
    canvas.save();
    canvas.translate(50, 72);
    canvas.scale(1, breathe);
    canvas.translate(-50, -72);
    final body = RRect.fromRectAndRadius(
      const Rect.fromLTWH(32, 58, 36, 28),
      const Radius.circular(14),
    );
    canvas.drawRRect(body, _clothPaint(clothes));
    canvas.drawRRect(body, _line(width: 2));
    // 左缘高光（立体轮廓）
    canvas.drawLine(
      const Offset(36, 62),
      const Offset(34, 76),
      _line(width: 2, color: Colors.white.withValues(alpha: 0.20)),
    );
    canvas.restore();

    // 上衣先画，再画手臂/手 —— 否则卫衣会把两只小手盖掉
    _top(canvas, clothes);

    // 手臂（QQ宠物风格：短手臂 + 圆圆的小手）
    final armSwing = math.sin(t * 2 * math.pi + 1.2) * 1.5;
    final arm = _limbPaint(clothes);
    canvas.drawLine(
      const Offset(36, 66),
      Offset(29, 73 + armSwing),
      arm,
    );
    canvas.drawLine(
      const Offset(64, 66),
      Offset(71, 73 - armSwing),
      arm,
    );
    // 左手（圆球）
    canvas.drawCircle(Offset(29, 74 + armSwing), 5.5, _fill(_skin));
    canvas.drawCircle(Offset(29, 74 + armSwing), 5.5, _line(width: 1.6));
    // 右手（圆球）
    canvas.drawCircle(Offset(71, 74 - armSwing), 5.5, _fill(_skin));
    canvas.drawCircle(Offset(71, 74 - armSwing), 5.5, _line(width: 1.6));

    // 脖子（更短）
    canvas.drawRect(const Rect.fromLTWH(47, 52, 6, 6), _fill(_skin));
    _hairBack(canvas, hair);
    _head(canvas);
    _hairFront(canvas, hair);
    _face(canvas, clothes, blinking, shift: faceShift);

    // 换装：颈饰 → 手持 → 面部 → 头饰（上衣已在手臂前画过）
    _neck(canvas);
    _hand(canvas, clothes);
    _faceAccessory(canvas, shift: faceShift);
    _hat(canvas, clothes);
  }

  void _head(Canvas c) {
    // QQ宠物风格：更大更圆的头
    c.drawCircle(const Offset(50, 36), 24, _skinPaint());
    c.drawCircle(const Offset(50, 36), 24, _line(width: 2));
    // 左上轮廓高光（3D 体积感）
    c.drawArc(
      Rect.fromCircle(center: const Offset(50, 36), radius: 22.2),
      math.pi * 1.02,
      math.pi * 0.46,
      false,
      _line(width: 2.2, color: Colors.white.withValues(alpha: 0.26)),
    );
  }

  void _hairBack(Canvas c, Color hair) {
    // QQ宠物风格：更大的头，头发也跟着大
    c.drawCircle(const Offset(50, 33), 25, _hairPaint(hair));
    if (_girl) {
      // 双马尾（更大更圆）
      for (final x in [23.0, 77.0]) {
        c.drawOval(
          Rect.fromCenter(center: Offset(x, 46), width: 15, height: 34),
          _hairPaint(hair),
        );
        c.drawOval(
          Rect.fromCenter(center: Offset(x, 46), width: 15, height: 34),
          _line(width: 1.8),
        );
        c.drawCircle(Offset(x, 33), 3.8, _fill(const Color(0xFFFF8FB1)));
      }
    }
    if (_scholar) {
      // 小发髻
      c.drawCircle(const Offset(50, 8), 7.5, _hairPaint(hair));
      c.drawCircle(const Offset(50, 8), 7.5, _line(width: 1.6));
    }
  }

  void _hairFront(Canvas c, Color hair) {
    // QQ宠物风格：更大的头，刘海也跟着大
    c.drawArc(
      Rect.fromCenter(center: const Offset(50, 36), width: 48, height: 48),
      math.pi,
      math.pi,
      true,
      _hairPaint(hair),
    );
    final bangs = Path()
      ..moveTo(27, 30)
      ..quadraticBezierTo(34, 12, 50, 13)
      ..quadraticBezierTo(66, 12, 73, 30)
      ..quadraticBezierTo(64, 26, 57, 29)
      ..quadraticBezierTo(52, 23, 47, 29)
      ..quadraticBezierTo(40, 24, 27, 30)
      ..close();
    c.drawPath(bangs, _hairPaint(hair));
    // 鬓角（更大）
    c.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(27, 28, 6, 16),
        const Radius.circular(3),
      ),
      _hairPaint(hair),
    );
    c.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(67, 28, 6, 16),
        const Radius.circular(3),
      ),
      _hairPaint(hair),
    );
  }

  /// [shift]：慢速转身时脸部特征的水平视差（相对头骨轻移，制造 3D 感）。
  void _face(Canvas c, Color accent, bool blinking, {double shift = 0}) {
    // QQ宠物风格：更大更圆的眼睛
    const eyeY = 39.0;
    for (final cx in [41.0 + shift, 59.0 + shift]) {
      if (blinking) {
        c.drawLine(
          Offset(cx - 6, eyeY),
          Offset(cx + 6, eyeY),
          _line(width: 2.4),
        );
      } else {
        // 更大的眼白
        c.drawOval(
          Rect.fromCenter(center: Offset(cx, eyeY), width: 10, height: 12),
          _fill(Colors.white),
        );
        c.drawOval(
          Rect.fromCenter(center: Offset(cx, eyeY), width: 10, height: 12),
          _line(width: 1.6),
        );
        // 更大的瞳孔（水汪汪）
        c.drawCircle(
          Offset(cx + 0.5, eyeY + 1.2),
          3.0,
          _fill(const Color(0xFF232323)),
        );
        // 更大的高光
        c.drawCircle(
          Offset(cx + 1.5, eyeY - 0.8),
          1.2,
          _fill(Colors.white),
        );
      }
    }

    // 腮红（更大更明显）
    final blush = Paint()..color = accent.withValues(alpha: 0.32);
    c.drawOval(
      Rect.fromCenter(
        center: Offset(33 + shift, 48),
        width: 11,
        height: 7,
      ),
      blush,
    );
    c.drawOval(
      Rect.fromCenter(
        center: Offset(67 + shift, 48),
        width: 11,
        height: 7,
      ),
      blush,
    );

    // 嘴：心情低时是平的
    if (mood < 30) {
      c.drawLine(
        Offset(46 + shift, 50),
        Offset(54 + shift, 50),
        _line(width: 1.8),
      );
    } else {
      c.drawPath(
        Path()
          ..moveTo(46 + shift, 49)
          ..quadraticBezierTo(50 + shift, 52.5, 54 + shift, 49),
        _line(width: 1.8),
      );
    }
  }

  void _background(Canvas c, Color accent) {
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

  void _hat(Canvas c, Color accent) {
    switch (outfits[PetOutfitSlot.hat]) {
      case 'hat':
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(33, 15, 34, 4),
            const Radius.circular(2),
          ),
          _fill(const Color(0xFF263238)),
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(41, 4, 18, 12),
            const Radius.circular(3),
          ),
          _fill(const Color(0xFF37474F)),
        );
        break;
      case 'cap':
        c.drawArc(
          Rect.fromCenter(center: const Offset(48, 18), width: 30, height: 24),
          math.pi,
          math.pi,
          true,
          _fill(accent),
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(48, 16, 22, 4),
            const Radius.circular(2),
          ),
          _fill(accent),
        );
        break;
      case 'crown':
        c.drawPath(
          Path()
            ..moveTo(39, 14)
            ..lineTo(43, 5)
            ..lineTo(47, 12)
            ..lineTo(50, 3)
            ..lineTo(53, 12)
            ..lineTo(57, 5)
            ..lineTo(61, 14)
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

  void _faceAccessory(Canvas c, {double shift = 0}) {
    switch (outfits[PetOutfitSlot.face]) {
      case 'glasses':
        final p = _line(width: 1.8, color: const Color(0xFF37474F));
        c.drawCircle(Offset(41 + shift, 39), 7.5, p);
        c.drawCircle(Offset(59 + shift, 39), 7.5, p);
        c.drawLine(
          Offset(48.5 + shift, 39),
          Offset(51.5 + shift, 39),
          p,
        );
        break;
      case 'shades':
        final fill = _fill(const Color(0xFF263238));
        c.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(32 + shift, 34, 17, 9),
            const Radius.circular(3),
          ),
          fill,
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(51 + shift, 34, 17, 9),
            const Radius.circular(3),
          ),
          fill,
        );
        c.drawLine(
          Offset(49 + shift, 38),
          Offset(51 + shift, 38),
          _line(width: 2),
        );
        break;
    }
  }

  void _neck(Canvas c) {
    switch (outfits[PetOutfitSlot.neck]) {
      case 'scarf':
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(31, 52, 38, 8),
            const Radius.circular(4),
          ),
          _fill(const Color(0xFFFF8FA3)),
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(33, 57, 8, 12),
            const Radius.circular(3),
          ),
          _fill(const Color(0xFFFF8FA3)),
        );
        break;
      case 'tie':
        c.drawPath(
          Path()
            ..moveTo(46, 52)
            ..lineTo(54, 52)
            ..lineTo(50, 57)
            ..close(),
          _fill(const Color(0xFFD32F2F)),
        );
        c.drawPath(
          Path()
            ..moveTo(47, 57)
            ..lineTo(53, 57)
            ..lineTo(50, 70)
            ..close(),
          _fill(const Color(0xFFD32F2F)),
        );
        break;
    }
  }

  void _top(Canvas c, Color clothes) {
    switch (outfits[PetOutfitSlot.top]) {
      case 'hoodie':
        final col = Color.lerp(clothes, Colors.white, 0.18)!;
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(28, 58, 44, 28),
            const Radius.circular(11),
          ),
          _fill(col.withValues(alpha: 0.94)),
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(40, 50, 20, 9),
            const Radius.circular(5),
          ),
          _fill(col.withValues(alpha: 0.78)),
        );
        c.drawLine(
          const Offset(50, 60),
          const Offset(50, 84),
          _line(width: 1.2, color: _ink.withValues(alpha: 0.35)),
        );
        break;
      case 'vest':
        final col = species.palette[0].withValues(alpha: 0.9);
        c.drawPath(
          Path()
            ..moveTo(30, 58)
            ..lineTo(47, 58)
            ..lineTo(45, 84)
            ..lineTo(31, 84)
            ..close(),
          _fill(col),
        );
        c.drawPath(
          Path()
            ..moveTo(70, 58)
            ..lineTo(53, 58)
            ..lineTo(55, 84)
            ..lineTo(69, 84)
            ..close(),
          _fill(col),
        );
        break;
    }
  }

  void _hand(Canvas c, Color accent) {
    switch (outfits[PetOutfitSlot.hand]) {
      case 'book':
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(66, 70, 18, 13),
            const Radius.circular(2),
          ),
          _fill(const Color(0xFFF5F0E6)),
        );
        c.drawLine(
          const Offset(75, 70),
          const Offset(75, 83),
          _line(width: 1.4, color: const Color(0xFF8D6E63)),
        );
        break;
      case 'coffee':
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(68, 72, 13, 13),
            const Radius.circular(3),
          ),
          _fill(Colors.white),
        );
        c.drawArc(
          Rect.fromCenter(center: const Offset(83, 78), width: 6, height: 8),
          -math.pi / 2,
          math.pi,
          false,
          _line(width: 1.6, color: Colors.white),
        );
        break;
      case 'balloon':
        c.drawCircle(
          const Offset(76, 46),
          9,
          _fill(accent.withValues(alpha: 0.9)),
        );
        c.drawPath(
          Path()
            ..moveTo(76, 55)
            ..quadraticBezierTo(70, 64, 72, 72),
          _line(width: 0.9, color: accent.withValues(alpha: 0.8)),
        );
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _QqPetPainter old) =>
      old.t != t ||
      old.mood != mood ||
      old.headOnly != headOnly ||
      old.species.id != species.id ||
      old.outfits.length != outfits.length ||
      !old.outfits.entries.every((e) => outfits[e.key] == e.value);
}

class _InkPetPainter extends CustomPainter {
  _InkPetPainter({
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

  // ── 换装（QQ秀式多部位）────────────────────────────────────

  void _drawOutfits(Canvas c, Color main, Color light, Color accent) {
    _drawTop(c, main, accent);
    _drawNeck(c, accent);
    _drawHand(c, accent);
    _drawFaceAccessory(c);
    _drawHat(c, accent);
  }

  /// 背景件（月光 / 星芒）—— 画在身体下面
  void _drawOutfitBackground(Canvas c, Color accent) {
    switch (outfits[PetOutfitSlot.background]) {
      case 'moon':
        c.drawCircle(
          const Offset(50, 46),
          36,
          Paint()..color = accent.withValues(alpha: 0.16),
        );
        c.drawCircle(
          const Offset(50, 46),
          36,
          _line(width: 1.2, color: accent.withValues(alpha: 0.45)),
        );
        break;
      case 'stars':
        final p = _fill(accent.withValues(alpha: 0.65));
        for (final o in const [
          Offset(22, 25),
          Offset(78, 22),
          Offset(84, 64),
          Offset(18, 62),
        ]) {
          _star(c, o, 4.5, p);
        }
        break;
    }
  }

  void _star(Canvas c, Offset center, double r, Paint p) {
    final path = Path();
    for (var i = 0; i < 8; i++) {
      final rr = i.isEven ? r : r * 0.42;
      final a = -math.pi / 2 + i * math.pi / 4;
      final pt = Offset(
        center.dx + math.cos(a) * rr,
        center.dy + math.sin(a) * rr,
      );
      if (i == 0) {
        path.moveTo(pt.dx, pt.dy);
      } else {
        path.lineTo(pt.dx, pt.dy);
      }
    }
    path.close();
    c.drawPath(path, p);
  }

  void _drawHat(Canvas c, Color accent) {
    switch (outfits[PetOutfitSlot.hat]) {
      case 'hat':
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(32, 14, 36, 4),
            const Radius.circular(2),
          ),
          _fill(const Color(0xFF263238)),
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(40, 3, 20, 12),
            const Radius.circular(3),
          ),
          _fill(const Color(0xFF37474F)),
        );
        c.drawRect(const Rect.fromLTWH(40, 11, 20, 3), _fill(accent));
        break;
      case 'cap':
        c.drawArc(
          Rect.fromCenter(center: const Offset(48, 16), width: 30, height: 24),
          math.pi,
          math.pi,
          true,
          _fill(accent),
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(48, 14, 22, 4),
            const Radius.circular(2),
          ),
          _fill(accent),
        );
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
            ..moveTo(66, 16)
            ..lineTo(76, 10)
            ..lineTo(76, 22)
            ..close(),
          _fill(accent),
        );
        c.drawPath(
          Path()
            ..moveTo(66, 16)
            ..lineTo(56, 10)
            ..lineTo(56, 22)
            ..close(),
          _fill(accent),
        );
        c.drawCircle(const Offset(66, 16), 2.6, _fill(accent));
        break;
    }
  }

  void _drawFaceAccessory(Canvas c) {
    switch (outfits[PetOutfitSlot.face]) {
      case 'glasses':
        final p = _line(width: 1.8, color: const Color(0xFF37474F));
        c.drawCircle(const Offset(40, 46), 8, p);
        c.drawCircle(const Offset(60, 46), 8, p);
        c.drawLine(const Offset(48, 46), const Offset(52, 46), p);
        break;
      case 'shades':
        final fill = _fill(const Color(0xFF263238));
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(31, 41, 17, 10),
            const Radius.circular(3),
          ),
          fill,
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(52, 41, 17, 10),
            const Radius.circular(3),
          ),
          fill,
        );
        c.drawLine(
          const Offset(48, 46),
          const Offset(52, 46),
          _line(width: 2, color: const Color(0xFF263238)),
        );
        break;
    }
  }

  void _drawNeck(Canvas c, Color accent) {
    switch (outfits[PetOutfitSlot.neck]) {
      case 'scarf':
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(28, 58, 44, 9),
            const Radius.circular(4.5),
          ),
          _fill(accent),
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(30, 64, 9, 14),
            const Radius.circular(3),
          ),
          _fill(accent),
        );
        break;
      case 'tie':
        c.drawPath(
          Path()
            ..moveTo(46, 58)
            ..lineTo(54, 58)
            ..lineTo(50, 63)
            ..close(),
          _fill(const Color(0xFFD32F2F)),
        );
        c.drawPath(
          Path()
            ..moveTo(47, 63)
            ..lineTo(53, 63)
            ..lineTo(50, 73)
            ..close(),
          _fill(const Color(0xFFD32F2F)),
        );
        break;
    }
  }

  void _drawTop(Canvas c, Color main, Color accent) {
    switch (outfits[PetOutfitSlot.top]) {
      case 'hoodie':
        final col = Color.lerp(main, Colors.white, 0.12)!;
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(24, 63, 52, 25),
            const Radius.circular(10),
          ),
          _fill(col.withValues(alpha: 0.92)),
        );
        c.drawLine(
          const Offset(50, 64),
          const Offset(50, 86),
          _line(width: 1.2, color: accent),
        );
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(40, 56, 20, 9),
            const Radius.circular(5),
          ),
          _fill(col.withValues(alpha: 0.75)),
        );
        break;
      case 'vest':
        final col = accent.withValues(alpha: 0.85);
        c.drawPath(
          Path()
            ..moveTo(24, 64)
            ..lineTo(46, 64)
            ..lineTo(44, 86)
            ..lineTo(26, 86)
            ..close(),
          _fill(col),
        );
        c.drawPath(
          Path()
            ..moveTo(76, 64)
            ..lineTo(54, 64)
            ..lineTo(56, 86)
            ..lineTo(74, 86)
            ..close(),
          _fill(col),
        );
        c.drawCircle(const Offset(50, 68), 1.6, _fill(Colors.white));
        c.drawCircle(const Offset(50, 78), 1.6, _fill(Colors.white));
        break;
    }
  }

  void _drawHand(Canvas c, Color accent) {
    switch (outfits[PetOutfitSlot.hand]) {
      case 'book':
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(66, 68, 18, 13),
            const Radius.circular(2),
          ),
          _fill(const Color(0xFFF5F0E6)),
        );
        c.drawLine(
          const Offset(75, 68),
          const Offset(75, 81),
          _line(width: 1.4, color: const Color(0xFF8D6E63)),
        );
        break;
      case 'coffee':
        c.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(68, 70, 13, 13),
            const Radius.circular(3),
          ),
          _fill(Colors.white),
        );
        c.drawArc(
          Rect.fromCenter(center: const Offset(83, 76), width: 6, height: 8),
          -math.pi / 2,
          math.pi,
          false,
          _line(width: 1.6, color: Colors.white),
        );
        c.drawLine(
          const Offset(71, 67),
          const Offset(72, 62),
          _line(width: 1, color: Colors.white54),
        );
        c.drawLine(
          const Offset(76, 67),
          const Offset(77, 62),
          _line(width: 1, color: Colors.white54),
        );
        break;
      case 'balloon':
        c.drawCircle(
          const Offset(76, 44),
          9,
          _fill(accent.withValues(alpha: 0.9)),
        );
        c.drawPath(
          Path()
            ..moveTo(76, 53)
            ..quadraticBezierTo(70, 62, 72, 70),
          _line(width: 0.9, color: accent.withValues(alpha: 0.8)),
        );
        break;
    }
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
