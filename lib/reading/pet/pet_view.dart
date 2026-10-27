import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'package:tvbox/reading/pet/pet_models.dart';
import 'package:tvbox/reading/pet/blob_pet_painter.dart';
import 'package:tvbox/reading/pet/pet_outfit_painter.dart';

// ══════════════════════════════════════════════════════════════
// 宠物绘制 —— 本文件是 library 根，只放「对外三个组件」
// ══════════════════════════════════════════════════════════════
//
// 2026-10-27 拆分（用户：重构宠物系统）。原来一个 2097 行的
// pet_view.dart 塞了 8 个类，改物种美术要滚过抠图/换装/头像代码。
// 现在按职责分 5 个文件，全是同一个 library 的 part：
//
//   pet_view.dart           对外组件（PetView / CustomPetImage / InkPetAvatar）
//   pet_cutout.dart         图片宠物：去背景抠图 + 裁切 + 图片换装
//   pet_painter.dart        矢量画笔骨架（状态 + paint 主流程 + 头像模式）
//   pet_painter_body.dart   矢量「身体零件」：耳朵/角/冠羽/尾/花纹/脸
//   pet_painter_outfit.dart 矢量「穿戴」适配层（真绘制在 pet_outfit_painter.dart）
//
// ⚠️ 所有绘制方法体是**逐字节原样搬的**（拆分时对每一段做了 sha256 比对，
//    并在新文件里做子串校验，全部命中）。唯一的外壳变化：两个 mixin 取代
//    `class` —— 因为 Dart 不允许一个 class 跨 part 文件（实测报
//    `Expected to find '}'`）。

part 'pet_cutout.dart';
part 'pet_painter.dart';
part 'pet_painter_body.dart';
part 'pet_painter_outfit.dart';

/// 手绘 Q 版桌宠（CustomPainter，无图片素材依赖）。
///
/// QQ 企鹅（`species.qq`，小Q/小秀/书呆）：整只矢量企鹅——
/// 圆胖身子 + 大头 + 白肚皮 + 橙嘴橙脚 + 红围巾，配色取自物种 `palette`，
/// 每帧呼吸/眨眼/摆翅膀。2026-10-26 由上一版的熊猫团子兽改回企鹅，
/// 去掉了外部 GIF 头依赖。
///
/// 之所以用矢量绘制：宠物要每帧呼吸/眨眼/摆手臂，单张 PNG 做不到；
/// 企鹅与生肖头像共用同一套 `PetView` 入口，按 `species.qq` 分派画笔。
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
    this.peek = 0,
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

  /// 贴边「门后探头」：`-1` 扒左边缘 / `+1` 扒右边缘 / `0` 正常站立。
  /// 只有矢量宠物支持（图片宠物还是走老的贴边姿态）。
  final int peek;

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
    // 圆团桌宠（`species.isBlob`）：整只矢量绘制（一颗圆团 + 按动物的装饰），
    // 不再依赖外部 GIF。老的 QQ 企鹅（`qq=true`）也走这一支，
    // 视觉与新版 6 只统一（见 BlobPetPainter）。
    if (species.isBlob) {
      return headOnly ? _buildPenguinHead() : _buildPenguin();
    }
    // 其它物种：保留原来的水墨画笔
    return SizedBox(
      width: size,
      height: size,
      // 宠物每帧都在呼吸/眨眼，独立成图层后只重绘这一块，
      // 不会连带周边列表/文字一起重绘（视觉完全一致，纯性能）。
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _InkPetPainter(
            species: species,
            outfit: outfit,
            outfits: _equipped,
            t: t,
            mood: mood,
            headOnly: headOnly,
          ),
        ),
      ),
    );
  }

  /// 只显示企鹅头（列表头像 / 聊天小头像）
  Widget _buildPenguinHead() {
    return SizedBox(
      width: size,
      height: size,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: BlobPetPainter(
            species: species,
            outfits: _equipped,
            t: t,
            mood: mood,
            headOnly: true,
            animate: true,
          ),
        ),
      ),
    );
  }

  /// 全身：整只矢量企鹅，外层做呼吸/浮动/摇摆（与画笔内部 animate 二选一）。
  Widget _buildPenguin() {
    // 探头姿态：门框不能跟着呼吸/摇摆一起动，所以外层的位移动效全部关掉，
    // 只留画笔内部对脑袋的轻微浮动。
    if (peek != 0) {
      return SizedBox(
        width: size,
        height: size,
        child: RepaintBoundary(
          child: CustomPaint(
            size: Size.square(size),
            painter: BlobPetPainter(
              species: species,
              outfits: _equipped,
              t: t,
              mood: mood,
              peek: peek,
              animate: true,
            ),
          ),
        ),
      );
    }
    final cycle = t * 2 * math.pi;
    final s = size / 100.0;
    final bob = math.sin(cycle) * 1.7 * s;
    final breathe = 1 + math.sin(cycle * 2) * 0.011;
    final sway = math.sin(cycle + 0.8) * 0.02;
    return SizedBox(
      width: size,
      height: size,
      child: RepaintBoundary(
        child: Transform.translate(
          offset: Offset(0, bob),
          child: Transform.rotate(
            angle: sway,
            child: Transform.scale(
              scale: breathe,
              child: CustomPaint(
                size: Size.square(size),
                painter: BlobPetPainter(
                  species: species,
                  outfits: _equipped,
                  t: t,
                  mood: mood,
                  drawHead: true,
                  animate: false,
                ),
              ),
            ),
          ),
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
                  // 穿戴交给 _CutoutPetView：它在抠图后知道宠物的真实落点，
                  // 配饰才能贴着轮廓叠（2026-10-27 换装重做）
                  child: _CutoutPetView(
                    cacheKey: 'asset:$asset',
                    loader: () async =>
                        (await rootBundle.load(asset)).buffer.asUint8List(),
                    size: size,
                    outfits: _equipped,
                    fallback: Image.asset(
                      asset,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
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
            outfits: outfits,
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
        // GIF 保留原样（逐帧动画无法做静态抠图）；静态图同样做
        // 「去白底 + 裁到本体」，换装也跟着本体落点走。
        child: Stack(
          fit: StackFit.expand,
          children: [
            image,
            // GIF 拿不到本体落点，只能按整幅画面的常见构图估算
            if (isGif && outfits.isNotEmpty)
              CustomPaint(painter: _ImageOutfitPainter(outfits)),
          ],
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
