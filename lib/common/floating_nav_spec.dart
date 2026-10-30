import 'package:flutter/material.dart';

import 'package:tvbox/reading/theme/jelly_palette.dart';

/// 全 App 悬浮菜单栏的**统一视觉规格**。
///
/// ── 为什么必须集中定义 ────────────────────────────────────────
/// 影视 / 音乐 / 阅读三条底栏原本各写各的，结果三处都不一样：
///
/// |        | 影视      | 音乐      | 阅读        |
/// |--------|-----------|-----------|-------------|
/// | 图标/文字 | 图标+文字 | 图标+文字 | **只有图标** |
/// | 圆角    | 30        | 22        | 32          |
/// | 距底部  | **8**     | 30        | 30          |
/// | 阴影    | 玻璃      | blur 16   | blur 12     |
///
/// 用户一眼就看出来了（"三种悬浮栏外观样子和距离底部的距离也不一样"）。
/// 所以把规格抽到这里：**改一处，三条栏一起变**，
/// 不会再出现"改了阅读忘了音乐"。
///
/// ── 展示形式的选择 ────────────────────────────────────────────
/// 统一为**图标 + 文字**（不是只有图标）。理由：
///   · 音乐与阅读的截图里本来都是图标+文字（还带"影视"入口）
///   · 只有图标的阅读栏是少数派，且纯图标对"阅读/漫画/书架"这类
///     抽象概念辨识度低（用户得先记住位置）
///   · 用户要求"要么都有图标与文字要么只有图标" —— 统一成前者
///     与多数页面一致，改动面最小
///
/// 悬浮底栏的视觉风格（用户 2026-10-18：底栏要能换风格，液态 / 炫彩等）。
///
/// 只用 id 持久化（`nav_style`）；新增风格时在 [fromId] 的 fallback 之外
/// 直接加一个枚举项即可。
enum FloatingNavStyle {
  /// 当前默认：跟随主题色的浅色胶囊（**用户明确要求保留这个不动**）
  ink('ink', '水墨'),

  // ── 下面 5 个是「照着各家系统抄作业」（用户 2026-10-30：
  //    「六种底栏风格的，你找网上 mac、鸿蒙、小米等等风格呢」）──
  //
  // ⚠️ 枚举的 **id 不改**：它是持久化键（`nav_style`），改了老用户的选择会丢。
  //    变的是 label 和实际画法 —— id 只是键名，别按字面理解（`neon` 现在画的是 iOS）。

  /// macOS 玻璃：Dock 式液态玻璃（大圆角 + 上亮下暗玻璃 + 白色高光边）
  frost('frost', 'macOS 玻璃'),

  /// 鸿蒙卡片：HarmonyOS 那种大圆角彩色卡片（主题色浅底 + 同色描边 + 胶囊选中块）
  aurora('aurora', '鸿蒙卡片'),

  /// iOS 液态玻璃：胶囊 + 近白半透 + 发丝线，选中只变色不加块
  neon('neon', 'iOS 液态'),

  /// 澎湃：小米 HyperOS 的实色圆角卡片（干净、边界清楚、几乎不透明）
  reverse('reverse', '澎湃'),

  /// 云母：Windows 11 Mica（淡雅底色 + 顶部 1px 亮线 + 底部指示条）
  solid('solid', '云母 Mica');

  const FloatingNavStyle(this.id, this.label);

  final String id;
  final String label;

  /// 旧 id 迁移：改版把「液态玻璃 / 描边 / 果冻」换掉了，
  /// 老用户存的是旧 id，直接回落到最接近的新风格，不要跳回水墨。
  ///
  /// 2026-10-30 换成各家系统风格时**没有再改 id**，所以这里不需要新增映射 ——
  /// 老用户的 frost/aurora/… 会自动变成对应系统风格（同一个 id，新画法）。
  static const Map<String, FloatingNavStyle> _legacy = {
    'liquid': FloatingNavStyle.frost,
    'outline': FloatingNavStyle.reverse,
    'jelly': FloatingNavStyle.solid,
  };

  static FloatingNavStyle fromId(String? id) {
    final old = _legacy[id];
    if (old != null) return old;
    return values.firstWhere(
      (e) => e.id == id,
      orElse: () => FloatingNavStyle.ink,
    );
  }
}

/// 选中指示器的**形态**（不只是颜色，形状也按风格变）。
enum NavIndicator {
  /// 圆形色块（水墨 / macOS 玻璃）
  blob,

  /// 圆角矩形块（鸿蒙 / iOS 液态 / 澎湃，像 iOS 分段控件）
  pill,

  /// 只有选中项下方一个小圆点（最极简，当前无风格使用）
  dot,

  /// 选中项下方一条短横线（云母 Mica）
  underline,
}

/// 底栏统一视觉规格（几何 / 取色 / 阴影）。
class FloatingNavSpec {
  FloatingNavSpec._();

  // ── 几何 ────────────────────────────────────────────────────

  /// 胶囊总高。66 = 上下内边距 6 + 图标 21 + 间距 3 + 文字 10 ≈ 视觉居中
  ///（2026-10-02 用户要求"悬浮栏高低降低一点点"，由 72 → 66）
  static const double barHeight = 66.0;

  /// 距屏幕底部的距离（**不含** Home Indicator 安全区）
  ///
  /// 2026-10-02 用户要求"所有悬浮栏位置再统一往下移一点"：
  /// 由 30 → 20（胶囊整体下移 10px，更贴底；三条栏一处生效）。
  static const double bottomMargin = 20.0;

  /// 左右屏幕边距
  static const double sideMargin = 12.0;

  /// 胶囊圆角
  static const double radius = 32.0;

  /// 胶囊内水平内边距
  static const double innerPadH = 6.0;

  /// 胶囊内垂直内边距
  static const double innerPadV = 6.0;

  /// 选中项胶囊圆角
  static const double itemRadius = 16.0;

  /// 每项垂直内边距
  static const double itemPadV = 7.0;

  // ── 图标与文字 ──────────────────────────────────────────────

  /// 图标尺寸（未选中/选中同尺寸，避免切换时抖动）
  static const double iconSize = 21.0;

  /// 标签字号
  static const double labelSize = 10.0;

  /// 图标与文字的间距
  static const double iconLabelGap = 3.0;

  // ── 颜色（都是不透明/半透明，跟随明暗由调用方给 palette）──────

  /// 胶囊底色透明度。留 5% 让底下的内容隐约透出 = 玻璃感
  static const double barAlpha = 0.95;

  /// 选中项底色透明度（用强调色）
  static const double itemSelectedAlpha = 0.14;

  /// 阴影
  static const double shadowBlur = 12.0;
  static const Offset shadowOffset = Offset(0, 4);
  static const double shadowAlpha = 0.06;

  /// 遮罩模糊强度（背景动画开启时跳过，见调用方）
  static const double blurSigma = 10.0;

  // ── 取色规则（三条栏必须用同一套，否则"颜色不一样"）──────────────
  //
  // 这些规则原本只写在阅读的 `_JellyNavItem` 里，影视/音乐各写各的，
  // 结果三处颜色不一致。收到这里之后**改一处三条栏一起变**。
  //
  // 为什么长这样（都是踩过的坑）：
  //   · 未选中**不能写死白色** —— 影视栏原来写死 `Colors.white 35%`，
  //     那是"深色底栏"时代的写法；换成浅色胶囊后白图标在白底上
  //     **完全看不见**（表现为底栏图标消失）。
  //   · 选中态在浅色下用 `navSelectedFg`（墨灰），深色下必须换**白色** ——
  //     墨灰在墨夜底栏上会糊成一片。

  /// 未选中项的图标/文字色
  static Color unselectedColor(bool isDark, JellyPalette palette) =>
      isDark ? Colors.white.withValues(alpha: 0.54) : palette.navUnselected;

  /// 选中项的图标/文字色
  static Color selectedColor(bool isDark, JellyPalette palette) =>
      isDark ? Colors.white : palette.navSelectedFg;

  /// 选中项底色（强调色的低透明度）
  static Color selectedItemBg(bool isDark, JellyPalette palette) =>
      palette.primary.withValues(alpha: isDark ? 0.22 : itemSelectedAlpha);

  /// 胶囊底色
  static Color barColor(bool isDark, JellyPalette palette) =>
      (isDark ? palette.cardDark : palette.cardLight)
          .withValues(alpha: barAlpha);

  /// 文字权重（三条栏统一）
  static const FontWeight labelWeight = FontWeight.w600;

  /// 每项垂直内边距。
  ///
  /// ⚠️ 别在调用方另写 8 —— 那会把图标挤压到比另两条栏小 2px
  /// （影视栏当初就是 `vertical: 8` + 与文字同排，图标显得偏小）。
  static const double itemPadH = 10.0;

  // ── 风格取色（2026-10-18 新增）────────────────────────────────
  //
  // 悬浮栏 6 种风格（2026-10-30 换成各家系统）：
  //   水墨 / macOS 玻璃 / 鸿蒙卡片 / iOS 液态 / 澎湃 / 云母 Mica。
  // 图标文字色与选中指示器底色都从这里取，底栏与侧栏共用同一套，
  // 避免"自定义了风格但某一处仍是旧配色"。

  /// 压在 [fill] 上最清楚的文字色（黑或白）。
  ///
  /// 强调色跨度很大（墨灰很暗、柠檬黄很亮），写死白字在亮底上只有 2:1。
  static Color _onFill(Color fill) =>
      fill.computeLuminance() > 0.55 ? Colors.black : Colors.white;

  /// 图标/文字颜色
  static Color styleContentColor(
    FloatingNavStyle style, {
    required bool selected,
    required bool isDark,
    required JellyPalette palette,
  }) {
    switch (style) {
      case FloatingNavStyle.aurora:
        // 鸿蒙卡片：选中压在**实心主题色胶囊**上，未选中压在淡彩卡片上
        return selected
            ? _onFill(palette.primary)
            : (isDark ? Colors.white.withValues(alpha: 0.72) : palette.navUnselected);
      case FloatingNavStyle.neon:
        // iOS：选中只是"变成 tint 色"，没有色块 ⇒ 用主题色本身
        return selected
            ? _legibleAccent(isDark, palette)
            : (isDark
                ? Colors.white.withValues(alpha: 0.56)
                : palette.navUnselected);
      case FloatingNavStyle.reverse:
        // 澎湃：选中压在实心主题色胶囊上
        return selected
            ? _onFill(palette.primary)
            : (isDark
                ? Colors.white.withValues(alpha: 0.64)
                : palette.navUnselected);
      case FloatingNavStyle.solid:
        // 云母：选中变成主题色（下面是细指示条，不是色块）
        return selected
            ? _legibleAccent(isDark, palette)
            : (isDark
                ? Colors.white.withValues(alpha: 0.58)
                : palette.navUnselected);
      case FloatingNavStyle.frost:
      case FloatingNavStyle.ink:
        return selected
            ? selectedColor(isDark, palette)
            : unselectedColor(isDark, palette);
    }
  }

  /// 压在**当前底色**上仍看得清的主题色。
  ///
  /// 墨灰压深色底会糊掉、亮黄压浅底也会糊 ⇒ 亮度不够就往白/黑偏一档。
  static Color _legibleAccent(bool isDark, JellyPalette palette) {
    final p = palette.primary;
    final l = p.computeLuminance();
    // 深色底需要 0.35 以上的亮度；浅色底需要 0.55 以下
    if (isDark && l < 0.35) return Color.lerp(p, Colors.white, 0.55)!;
    if (!isDark && l > 0.55) return Color.lerp(p, Colors.black, 0.40)!;
    return p;
  }

  /// 选中指示器底色
  static Color styleIndicatorColor(
    FloatingNavStyle style, {
    required bool isDark,
    required JellyPalette palette,
  }) {
    switch (style) {
      case FloatingNavStyle.frost:
        // macOS：选中项是一块**更亮的玻璃**（浅色下更白、深色下提亮）
        return Colors.white.withValues(alpha: isDark ? 0.16 : 0.72);
      case FloatingNavStyle.aurora:
        // 鸿蒙：实心主题色胶囊
        return palette.primary.withValues(alpha: 0.92);
      case FloatingNavStyle.neon:
        // iOS：极淡的主题色胶囊（液态玻璃里的那一层）
        return palette.primary.withValues(alpha: isDark ? 0.26 : 0.14);
      case FloatingNavStyle.reverse:
        // 澎湃：实心主题色胶囊
        return palette.primary.withValues(alpha: 0.94);
      case FloatingNavStyle.solid:
        // 云母：底部细指示条，用主题色
        return _legibleAccent(isDark, palette);
      case FloatingNavStyle.ink:
        return isDark ? palette.navSelectedFg : palette.navSelectedBg;
    }
  }

  // ── 全风格不透明度（用户 2026-10-24：「菜单栏太透明了，加个可调整透明度」）──

  /// 可调范围。0.30 已经很透（能看清底下内容），1.0 = 完全不透。
  static const double minOpacity = 0.30;
  static const double maxOpacity = 1.0;
  static const double defaultOpacity = 0.95;

  static double clampOpacity(double v) => v.clamp(minOpacity, maxOpacity);

  // ── 形态：照着各家系统来（2026-10-30 重构）──────────────────
  //
  //   ink     水墨     ：胶囊 32 + 圆形指示块（保持原样）
  //   frost   macOS    ：Dock 圆角 26 + 更亮的玻璃块
  //   aurora  鸿蒙     ：卡片圆角 20 + 实心主题色胶囊
  //   neon    iOS      ：完全胶囊 999 + 极淡主题色胶囊
  //   reverse 澎湃     ：圆角 24 + 实心主题色胶囊
  //   solid   云母Mica ：小圆角 16 + 底部指示条

  /// 该风格的胶囊圆角
  static double styleRadius(FloatingNavStyle style) {
    switch (style) {
      case FloatingNavStyle.ink:
        return radius; // 32
      case FloatingNavStyle.frost:
        return 26;
      case FloatingNavStyle.aurora:
        return 20;
      case FloatingNavStyle.neon:
        return 999; // iOS 完全胶囊
      case FloatingNavStyle.reverse:
        return 24;
      case FloatingNavStyle.solid:
        return 16;
    }
  }

  /// 该风格的选中指示器形态
  static NavIndicator styleIndicator(FloatingNavStyle style) {
    switch (style) {
      case FloatingNavStyle.ink:
      case FloatingNavStyle.frost:
        return NavIndicator.blob;
      case FloatingNavStyle.aurora:
      case FloatingNavStyle.neon:
      case FloatingNavStyle.reverse:
        return NavIndicator.pill;
      case FloatingNavStyle.solid:
        return NavIndicator.underline;
    }
  }

  /// 该风格要不要给底栏加背景模糊（BackdropFilter）。
  ///
  /// 玻璃/云母类都要模糊才有质感；澎湃是实色卡片，模糊纯属白烧一次
  /// 全屏高斯（macOS runner 上尤其明显）。
  static bool usesBlur(FloatingNavStyle style) =>
      style != FloatingNavStyle.reverse;

  /// 把整条底栏的底色/渐变按 [opacity] 整体压暗透明度。
  ///
  /// 只在**出口处**统一乘一次 —— 六种风格各自的配色分支不用关心透明度，
  /// 也就不会出现"调了滑杆只有水墨变了、别的没反应"。
  /// 描边、阴影、图标颜色不参与：描边变淡会让胶囊边缘消失。
  static BoxDecoration applyOpacity(BoxDecoration deco, double opacity) {
    final o = clampOpacity(opacity);
    if (o >= 0.999) return deco;
    Color fade(Color c) => c.withValues(alpha: c.a * o);
    final g = deco.gradient;
    Gradient? gradient = g;
    if (g is LinearGradient) {
      gradient = LinearGradient(
        begin: g.begin,
        end: g.end,
        stops: g.stops,
        colors: [for (final c in g.colors) fade(c)],
      );
    } else if (g is RadialGradient) {
      gradient = RadialGradient(
        center: g.center,
        radius: g.radius,
        colors: [for (final c in g.colors) fade(c)],
      );
    } else if (g is SweepGradient) {
      gradient = SweepGradient(
        startAngle: g.startAngle,
        endAngle: g.endAngle,
        colors: [for (final c in g.colors) fade(c)],
      );
    }
    return deco.copyWith(
      color: deco.color == null ? null : fade(deco.color!),
      gradient: gradient,
    );
  }

  // ============================================================
  // 六种风格的**唯一**配色出口
  // ============================================================
  //
  // 2026-10-30 用户两轮要求：
  //   ①「除第一个外，其余 5 个重构」  ②「找网上 mac、鸿蒙、小米等等风格」
  //
  // 重构前三个毛病：
  //   · 配色写在两处（真底栏 + 设置页预览卡），改一边忘另一边就会
  //     「预览是磨砂、实际却是另一回事」；
  //   · 炫彩写死紫/粉/青、实心写死 #17171A —— 用户换「蕉红」后
  //     页面全红、底栏还是紫的；
  //   · 磨砂/反色/实心看着只差个底色深浅，形态上分不出来。
  //
  // 现在：一个函数出装饰、一个函数出阴影，颜色**全部从 palette 推**，
  // 形态差异（圆角 + 指示器）由 styleRadius / styleIndicator 决定。

  /// 底栏装饰（六种风格）。
  ///
  /// [opacity] 传底栏不透明度（设置里的滑杆）；不传就用默认值。
  static BoxDecoration barDecoration({
    required FloatingNavStyle style,
    required bool isDark,
    required JellyPalette palette,
    double? opacity,
  }) {
    final radius = BorderRadius.circular(styleRadius(style));
    final BoxDecoration deco;
    switch (style) {
      case FloatingNavStyle.ink:
        // 水墨：**保持原样**（用户只说"除第一个外"）。
        deco = BoxDecoration(
          color: barColor(isDark, palette).withValues(alpha: barAlpha),
          borderRadius: radius,
        );
        break;

      case FloatingNavStyle.frost:
        // ── macOS 玻璃（Dock / Liquid Glass）────────────────────
        // 关键在**上亮下暗的三段渐变**：光源在上方，这是玻璃感的来源。
        // 再加一道亮边，边缘才不会糊进壁纸里。
        deco = BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? [
                    Colors.white.withValues(alpha: 0.20),
                    Colors.white.withValues(alpha: 0.11),
                    Colors.white.withValues(alpha: 0.06),
                  ]
                : [
                    Colors.white.withValues(alpha: 0.66),
                    Colors.white.withValues(alpha: 0.46),
                    Colors.white.withValues(alpha: 0.34),
                  ],
            stops: const [0.0, 0.45, 1.0],
          ),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.22)
                : Colors.white.withValues(alpha: 0.95),
            width: 1.0,
          ),
        );
        break;

      case FloatingNavStyle.aurora:
        // ── 鸿蒙卡片（HarmonyOS）────────────────────────────────
        // 大圆角 + 淡彩卡片：卡片底里掺主题色，配同色描边。
        // 不是"渐变炫彩"——那是 iOS 时代的做法，鸿蒙的卡片是**安静**的。
        final card = isDark ? palette.cardDark : palette.cardLight;
        deco = BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(card, palette.primary, isDark ? 0.24 : 0.16)!,
              Color.lerp(card, palette.primary, isDark ? 0.10 : 0.06)!,
            ],
          ),
          border: Border.all(
            color: palette.primary.withValues(alpha: isDark ? 0.42 : 0.34),
            width: 1.0,
          ),
        );
        break;

      case FloatingNavStyle.neon:
        // ── iOS 液态玻璃（Liquid Glass Tab Bar）──────────────────
        // 近乎纯白/纯黑的半透材质 + 一道发丝边，选中只变色不加色块。
        deco = BoxDecoration(
          borderRadius: radius,
          color: isDark
              ? const Color(0xFF1C1C1E).withValues(alpha: 0.74)
              : Colors.white.withValues(alpha: 0.84),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.12)
                : Colors.white.withValues(alpha: 0.55),
            width: 0.8,
          ),
        );
        break;

      case FloatingNavStyle.reverse:
        // ── 澎湃（小米 HyperOS）──────────────────────────────────
        // 实色圆角卡片：干净、边界清楚、几乎不透明（小米就是"不要玻璃"）。
        deco = BoxDecoration(
          borderRadius: radius,
          color: (isDark ? palette.cardDark : palette.cardLight)
              .withValues(alpha: isDark ? 0.96 : 0.98),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.06),
            width: 0.8,
          ),
        );
        break;

      case FloatingNavStyle.solid:
        // ── 云母（Windows 11 Mica）──────────────────────────────
        // 底色里掺一点点主题色（Mica 就是把壁纸"磨"进材质），
        // 顶部 1px 亮线是 Windows 的标志性细节。
        final card = isDark ? palette.cardDark : palette.cardLight;
        deco = BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.lerp(card, Colors.white, isDark ? 0.06 : 0.45)!,
              Color.lerp(card, palette.primary, isDark ? 0.10 : 0.04)!,
            ],
          ),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.12)
                : Colors.white.withValues(alpha: 0.70),
            width: 0.8,
          ),
        );
        break;
    }
    return applyOpacity(deco, opacity ?? defaultOpacity);
  }

  /// 底栏外阴影（玻璃/卡片用大柔光，澎湃/云母用轻投影）。
  static List<BoxShadow> barShadows({
    required FloatingNavStyle style,
    required bool isDark,
    required JellyPalette palette,
  }) {
    switch (style) {
      case FloatingNavStyle.frost:
        // macOS：Dock 那种"浮在桌面上"的大柔光
        return [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.38 : 0.13),
            blurRadius: 28,
            offset: const Offset(0, 9),
          ),
        ];
      case FloatingNavStyle.aurora:
        // 鸿蒙：同色柔光（卡片自身的颜色透出来一点）
        return [
          BoxShadow(
            color: palette.primary.withValues(alpha: isDark ? 0.28 : 0.18),
            blurRadius: 20,
            offset: const Offset(0, 7),
          ),
        ];
      case FloatingNavStyle.neon:
        // iOS：极轻的投影，液态玻璃靠材质而不是阴影
        return [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.26 : 0.08),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ];
      case FloatingNavStyle.reverse:
        // 澎湃：轻投影，卡片感
        return [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.30 : 0.10),
            blurRadius: 16,
            offset: const Offset(0, 5),
          ),
        ];
      case FloatingNavStyle.solid:
        // 云母：浅而散的投影
        return [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.24 : 0.08),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ];
      case FloatingNavStyle.ink:
        return [
          BoxShadow(
            color: Colors.black.withValues(alpha: shadowAlpha),
            blurRadius: shadowBlur,
            offset: shadowOffset,
          ),
        ];
    }
  }
}
