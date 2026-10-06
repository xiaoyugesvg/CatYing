import 'package:flutter/material.dart';

import '../../../common/theme.dart';
import '../../../reading/theme/jelly_palette.dart';
import '../theme/music_theme.dart';

/// 发现页的**视觉预设**（对齐 Beans 的 aurora / paper / midnight 三套）。
///
/// ══════════════════════════════════════════════════════════════════
/// 🔴 **预设 ≠ 主题**（这是本文件最重要的约定，别改成"自带配色的皮肤"）
/// ══════════════════════════════════════════════════════════════════
/// 预设**只决定两件事**：
///   1. **背景怎么画**（氛围光斑+粒子 / 纯色 / 深色渐变）
///   2. **卡片用什么材质**（玻璃模糊 / 系统分组色 / 深底玻璃）
///
/// 而**所有颜色都从全局 [MusicTheme]（即 `JellyPalette`）派生** ——
/// 预设里**一个色值都不写死**。
///
/// 为什么必须这样（用户明确要求"整体外观和主题系统统一"）：
///   · 本项目有 **7 套全局主题**（`JellyPalette.fromPreset`），
///     音乐/阅读/影视**共享同一套 palette**（见 `MusicPaletteBridge`）。
///   · 如果预设自带配色，换全局主题时**只有三套预设的颜色不变** →
///     界面上出现"两套色系打架"，正好违反统一。
///   · 而明暗也必须跟随全局（`AppBrightness.isLight`）——
///     用户早就定过"全局说了算，单个模块不能覆盖"。
///
/// 所以三套预设的差异是**材质与构图**，不是配色。Beans 原版也是这个思路：
/// 它的 aurora/paper/midnight 改的是 `BeansGlass` 材质 + 背景层，
/// 强调色仍走主题的 `beansAmber`。
enum DiscoverPreset {
  /// **青碧玻璃**（Beans 默认）：氛围光斑 + 粒子 + 玻璃卡片
  aurora('青碧玻璃'),

  /// **纸感**：纯分组底色 + 实心卡片，无光斑无粒子
  paper('纸感'),

  /// **午夜**：深色渐变舞台 + 深底玻璃卡片
  midnight('午夜');

  const DiscoverPreset(this.label);

  /// 设置页显示的名字
  final String label;

  static DiscoverPreset fromName(String? n) => DiscoverPreset.values.firstWhere(
        (e) => e.name == n,
        orElse: () => DiscoverPreset.aurora,
      );
}

/// 预设展开成的**具体视觉参数**（全部派生，无硬编码色值）
class DiscoverStyle {
  const DiscoverStyle({
    required this.preset,
    required this.primary,
    required this.secondary,
    required this.accent,
    required this.blue,
    required this.cardFill,
    required this.backdrop,
    required this.particles,
    required this.blobs,
    required this.fillAlpha,
  });

  final DiscoverPreset preset;

  /// 主文字色
  final Color primary;

  /// 次要文字色
  final Color secondary;

  /// 主题强调色（选中态、播放键、光斑）
  final Color accent;

  /// 辅助色（第二个光斑、频谱后半段）
  final Color blue;

  /// 卡片填充色
  final Color cardFill;

  /// 背景底色（单色铺底；aurora/midnight 会在它上面再叠光斑/渐变）
  final Color backdrop;

  /// 是否画粒子层
  final bool particles;

  /// 是否画氛围光斑
  final bool blobs;

  /// 卡片不透明度（paper 是实心 1.0，玻璃系偏低）
  final double fillAlpha;

  /// 从**全局主题**派生当前预设的具体参数。
  ///
  /// ⚠️ 明暗只看 [AppBrightness.isLight]（全局唯一事实源）——
  /// 预设自己**不判断明暗**，否则会出现"全局浅色但发现页深色"。
  static DiscoverStyle of(DiscoverPreset preset) {
    final p = MusicTheme.palette;
    final dark = MusicTheme.isDark;

    // 强调色：深色用 primaryLight（深底上更亮），浅色用 primary
    final accent = dark ? p.primaryLight : p.primary;
    final blue = dark ? p.blue : p.blue;

    // 卡片填充：玻璃系靠半透明 + 模糊，paper 用实心卡片色
    final cardBase = dark ? p.cardDark : p.cardLight;

    switch (preset) {
      case DiscoverPreset.aurora:
        return DiscoverStyle(
          preset: preset,
          primary: dark ? p.textPrimaryDark : p.textPrimaryLight,
          secondary: p.textSecondary,
          accent: accent,
          blue: blue,
          cardFill: cardBase,
          backdrop: dark ? p.backgroundDark : p.backgroundLight,
          particles: true,
          blobs: true,
          fillAlpha: dark ? 0.10 : 0.55,
        );

      case DiscoverPreset.paper:
        return DiscoverStyle(
          preset: preset,
          primary: dark ? p.textPrimaryDark : p.textPrimaryLight,
          secondary: p.textSecondary,
          accent: accent,
          blue: blue,
          cardFill: cardBase,
          // paper 的底色刻意和卡片**拉开一点**（Beans 用 systemGroupedBackground
          // 对 secondarySystemGroupedBackground 的关系），否则实心卡片糊在底色上
          backdrop: dark
              ? Color.alphaBlend(Colors.black.withValues(alpha: 0.22), p.backgroundDark)
              : Color.alphaBlend(Colors.black.withValues(alpha: 0.035), p.backgroundLight),
          particles: false,
          blobs: false,
          fillAlpha: 1.0,
        );

      case DiscoverPreset.midnight:
        return DiscoverStyle(
          preset: preset,
          primary: dark ? p.textPrimaryDark : p.textPrimaryLight,
          secondary: p.textSecondary,
          accent: accent,
          blue: blue,
          cardFill: cardBase,
          // ── 🔴 午夜：底色**必须跟着全局明暗走**（修一个"整页不可读"）──
          //
          // 原来这里写的是 `p.backgroundDark`（**恒定深底**），只有压暗的
          // alpha 跟明暗走：
          //   `Color.alphaBlend(Colors.black.withValues(alpha: dark ? 0.45 : 0.18),
          //                     p.backgroundDark)`
          //
          // 而上面的文字色是 `dark ? textPrimaryDark : textPrimaryLight`
          //（浅色下 = `#1F1F1F` 近黑）。于是**全局浅色 + 选「午夜」** 时：
          //   · 底色 ≈ #171719（近黑）
          //   · 问候语/副标题/平台胶囊文字 ≈ #1F1F1F
          //   → 对比度 ≈ 1.05:1，**整页看不见字** ✗
          //
          // 这也**违反了本文件 96-98 行自己的约定**：
          //   "明暗只看 AppBrightness.isLight，预设自己**不判断明暗**，
          //    否则会出现'全局浅色但发现页深色'"
          // aurora（上面）、paper 都按明暗二选一取底色，只有午夜写岔了。
          //
          // 现在与 paper 同构：**基底随明暗**，再叠一层压暗把"午夜"做出来
          //（浅色下压得更重，才看得出"午夜"的氛围；深色下本来就近黑，轻压即可）。
          backdrop: dark
              ? Color.alphaBlend(
                  Colors.black.withValues(alpha: 0.30), p.backgroundDark)
              : Color.alphaBlend(
                  Colors.black.withValues(alpha: 0.55), p.backgroundLight),
          particles: true,
          blobs: true,
          fillAlpha: dark ? 0.14 : 0.35,
        );
    }
  }
}

/// 桌面级调色板快捷访问（避免每个 widget 都写 `MusicTheme.palette`）
extension DiscoverPaletteX on JellyPalette {
  /// 面板色（比卡片略深，用于 chip/输入框底）
  Color get panelLight => backgroundLight;
  Color get panelDark => Color.alphaBlend(
      Colors.white.withValues(alpha: 0.06), cardDark);
}

/// 发现页背景层 —— 按预设画三种不同的底。
///
/// ⚠️ 这一层**不吃触摸**（`IgnorePointer`）：它铺在最底下，
/// 但内容要能正常点击/滚动。
class DiscoverBackdrop extends StatelessWidget {
  const DiscoverBackdrop({super.key, required this.style, this.child});

  final DiscoverStyle style;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Stack(
      children: [
        // ① 底色
        Positioned.fill(
          child: ColoredBox(
            color: style.backdrop,
            child: style.preset == DiscoverPreset.midnight
                // 午夜：从左上到右下的暗色渐变（色由 backdrop 派生，不写死）
                ? DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          style.backdrop,
                          Color.alphaBlend(
                              style.blue.withValues(alpha: 0.10), style.backdrop),
                          Color.alphaBlend(
                              Colors.black.withValues(alpha: 0.30), style.backdrop),
                        ],
                      ),
                    ),
                  )
                : null,
          ),
        ),

        // ② 氛围光斑（aurora / midnight）
        if (style.blobs) ...[
          Positioned(
            left: size.width * 0.55,
            top: -size.width * 0.30,
            child: _blob(
              size: size.width * 0.85,
              color: style.accent.withValues(alpha: 0.14),
            ),
          ),
          Positioned(
            left: -size.width * 0.35,
            top: size.height * 0.32,
            child: _blob(
              size: size.width * 0.75,
              color: style.blue.withValues(alpha: 0.12),
            ),
          ),
        ],

        // ③ 粒子（aurora / midnight）—— 静态点，不做动画
        //
        // ⚠️ 刻意**不做动画**：Beans 原版的粒子在播放时才动，
        // 而这里是"浏览页"，常驻动画会一直吃 GPU（本项目在 iOS 上
        // 已经有很多动画了）。静态点已足够出氛围。
        if (style.particles)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _DotPainter(color: style.accent),
              ),
            ),
          ),

        if (child != null) Positioned.fill(child: child!),
      ],
    );
  }

  Widget _blob({required double size, required Color color}) => IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [color, color.withValues(alpha: 0)],
            ),
          ),
        ),
      );
}

/// 固定位置的淡点（用固定 seed 保证每次重建位置不变 —— 随机位置会在
/// 每次 setState 时"跳一下"，很难看）
class _DotPainter extends CustomPainter {
  _DotPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rnd = _Seeded(20260101);
    final paint = Paint();
    for (var i = 0; i < 26; i++) {
      final x = rnd.next() * size.width;
      final y = rnd.next() * size.height;
      final r = 0.8 + rnd.next() * 1.4;
      paint.color = color.withValues(alpha: 0.05 + rnd.next() * 0.06);
      canvas.drawCircle(Offset(x, y), r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DotPainter old) => old.color != color;
}

/// 极简确定性伪随机（避免 import `dart:math` 的 Random 导致每次重建不同）
class _Seeded {
  _Seeded(this._s);
  int _s;
  double next() {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return _s / 0x7fffffff;
  }
}
