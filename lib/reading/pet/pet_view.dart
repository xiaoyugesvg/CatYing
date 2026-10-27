import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';

import 'package:tvbox/reading/pet/pet_models.dart';

// ══════════════════════════════════════════════════════════════
// 桌宠绘制 —— 本文件是 library 根，只放「对外三个组件」
// ══════════════════════════════════════════════════════════════
//
// 2026-10-27 第二次收缩（用户：「我只要这 3 个，其余全部去掉，也不要服装
// 系统了」）：
//   · 形象只有熊猫 / 少年 / 少女三张**透明背景 PNG**，直接 `Image.asset`；
//   · 手绘的圆团画笔（blob_pet_painter / blob_pet_chibi）、水墨生肖画笔
//     （pet_painter*）、整套换装（pet_outfit_painter）全部删除；
//   · 只剩「图片 + 动效」，所以这个 library 现在只有 pet_view 和 pet_cutout
//     两个 part：前者管对外组件，后者只管**用户自上传图片**的去背景。
//
// 动作表情（开心 / 生气 / 疑惑 / 打招呼 / 谢谢 / 晚安）见 [_PetMoodLayer]：
// 静态插画改不了脸，就用「动作节奏 + emoji 气泡」表达。

part 'pet_cutout.dart';

/// 桌宠组件（图片形象 + 呼吸/动作表情）。
class PetView extends StatelessWidget {
  const PetView({
    super.key,
    required this.species,
    required this.t,
    this.size = 120,
    this.mood = 80,
    this.headOnly = false,
    this.expr,
  });

  final PetSpeciesInfo species;

  /// 动画进度（秒），由外部 AnimationController 推进
  final double t;
  final double size;

  /// 心情值（0~100）：只影响气泡/表情的默认选择，不影响画法。
  final double mood;

  /// 只画头部（小头像用）：裁到脑袋那一块铺满圆形。
  final bool headOnly;

  /// 动作表情；`null` = 平时站着（只有呼吸/浮动）。
  final PetMood? expr;

  @override
  Widget build(BuildContext context) {
    // 找不到图（存档里的老 id 被删了 / 素材缺失）就回落到第一只，
    // 别给用户留一个空白桌宠。
    final asset = species.imageAsset ?? PetSpecies.pets.first.imageAsset!;
    if (headOnly) return _headAvatar(asset);
    return SizedBox(
      width: size,
      height: size,
      child: RepaintBoundary(
        child: Stack(
          alignment: Alignment.center,
          // 表情气泡会飘到宠物外面一点，别被裁掉
          clipBehavior: Clip.none,
          children: [
            _shadow(),
            Transform.translate(
              offset: Offset(0, _idleBob()),
              child: _PetMoodLayer(
                expr: expr,
                t: t,
                size: size,
                palette: species.palette,
                child: Transform.rotate(
                  angle: math.sin(t * 2 * math.pi + 0.8) * 0.03,
                  child: Transform.scale(
                    scale: 1 + math.sin(t * 4 * math.pi) * 0.016,
                    child: Image.asset(
                      asset,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 平时站着时的轻微上下浮（约 2 秒一个来回）
  double _idleBob() => math.sin(t * 2 * math.pi) * 2.0;

  /// 影子：动作表情往上蹦的时候收小一点
  Widget _shadow() {
    final hop = expr == null
        ? 0.0
        : (expr!.motion.dy.abs() * (0.5 + 0.5 * math.sin(t * 2 * math.pi)));
    return Positioned(
      bottom: size * 0.01,
      child: Transform.scale(
        scale: (1 - hop / 30).clamp(0.55, 1.0),
        child: Container(
          width: size * 0.42,
          height: size * 0.05,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
          ),
        ),
      ),
    );
  }

  /// 圆形小头像：立绘取「脑袋」（顶部对齐），生肖那种方图取本体（底部对齐）
  Widget _headAvatar(String asset) {
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
            alignment: species.avatarAlign,
            gaplessPlayback: true,
          ),
        ),
      ),
    );
  }
}

/// 动作表情层：给形象加一套「位移 + 旋转 + 缩放」节奏，再飘一个 emoji 气泡。
///
/// 之所以不换图：三只形象是一张静态插画，脸上改不了表情；用动作 + 气泡
/// 表达情绪，素材只有 3 张也能有 6 种反应，而且加新表情只改一个枚举值。
class _PetMoodLayer extends StatelessWidget {
  const _PetMoodLayer({
    required this.expr,
    required this.t,
    required this.size,
    required this.palette,
    required this.child,
  });

  final PetMood? expr;
  final double t;
  final double size;
  final List<Color> palette;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mood = expr;
    if (mood == null) return child;
    final m = mood.motion;
    final phase = t * m.hz * 2 * math.pi;
    final s = math.sin(phase);
    // 气泡直径：跟着宠物尺寸走，但夹在 18~40 之间（太小看不清、太大压住脑袋）
    final d = (size * 0.30).clamp(18.0, 40.0);
    return Transform.translate(
      offset: Offset(m.dx * s, m.dy * s),
      child: Transform.rotate(
        angle: m.rot * s,
        child: Transform.scale(
          scale: 1 + m.pulse * math.sin(phase * 2),
          child: Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              child,
              Positioned(
                right: -d * 0.22,
                top: -d * 0.10,
                child: _MoodBubble(
                  emoji: mood.emoji,
                  d: d,
                  t: t,
                  accent: palette.length > 2 ? palette[2] : palette.first,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 表情气泡：米白圆角小牌 + emoji，轻轻上下飘。
class _MoodBubble extends StatelessWidget {
  const _MoodBubble({
    required this.emoji,
    required this.d,
    required this.t,
    required this.accent,
  });

  final String emoji;
  final double d;
  final double t;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final float = math.sin(t * 2 * math.pi * 1.4) * d * 0.06;
    return Transform.translate(
      offset: Offset(0, float),
      child: Container(
        width: d,
        height: d,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.94),
          shape: BoxShape.circle,
          border: Border.all(
            color: accent.withValues(alpha: 0.18),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: d * 0.22,
              offset: Offset(0, d * 0.06),
            ),
          ],
        ),
        child: Text(
          emoji,
          style: TextStyle(fontSize: d * 0.56, height: 1.0),
        ),
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
    this.expr,
  });

  final String path;
  final double size;

  /// 上下浮动像素（由动画进度算好传进来）
  final double bob;

  /// 动作表情（自定义图同样支持）
  final PetMood? expr;

  @override
  Widget build(BuildContext context) {
    final f = File(path);
    if (!f.existsSync()) {
      // 图片被清理 / 换机丢失时别留一个空白桌宠：回退到默认形象
      return PetView(species: PetSpecies.pets.first, t: bob / 10, size: size);
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
        child: image,
      ),
    );
  }
}

/// 圆形头像：立绘裁到脑袋 + 米白纸底，自动裁成圆形。
///
/// 用于「我的」页头像、内置头像选择面板；头像**始终是圆的**。
class InkPetAvatar extends StatelessWidget {
  const InkPetAvatar({super.key, required this.speciesId, this.size = 64});

  final String speciesId;
  final double size;

  @override
  Widget build(BuildContext context) {
    final sp = PetSpecies.byId(speciesId);
    final asset = sp.imageAsset;
    if (asset == null) {
      // 没有图片的物种（如「自定义」）画一个色块 + 首字，别空着
      return SizedBox(
        width: size,
        height: size,
        child: ClipOval(
          child: ColoredBox(
            color: const Color(0xFFF7F3EA),
            child: Center(
              child: Text(
                sp.name.isEmpty ? '?' : sp.name[0],
                style: TextStyle(
                  fontSize: size * 0.42,
                  fontWeight: FontWeight.w700,
                  color: sp.palette.last,
                ),
              ),
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
          child: Image.asset(
            asset,
            width: size,
            height: size,
            fit: BoxFit.cover,
            alignment: sp.avatarAlign,
            gaplessPlayback: true,
          ),
        ),
      ),
    );
  }
}
