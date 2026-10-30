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
  /// 当前默认：跟随主题色的浅色胶囊
  ink('ink', '水墨'),

  /// 磨砂：半透玻璃底 + 顶部高光细边（2026-10-24 重做，取代「液态玻璃」）
  frost('frost', '磨砂'),

  /// 炫彩：主题色渐变，图标纯白
  aurora('aurora', '炫彩'),

  /// 霓虹：深色底 + 发光描边
  neon('neon', '霓虹'),

  /// 反色：底色与界面明暗**相反**（浅色主题下是深胶囊，深色主题下是浅胶囊），
  /// 一眼就能和「水墨」区分开（2026-10-24 新增，取代「描边」）
  reverse('reverse', '反色'),

  /// 实心：几乎不透明的实底 + 主题色实心选中块，最"实"、最不挡字
  ///（2026-10-24 新增，取代「果冻」；用户嫌底栏太透明）
  solid('solid', '实心');

  const FloatingNavStyle(this.id, this.label);

  final String id;
  final String label;

  /// 旧 id 迁移：改版把「液态玻璃 / 描边 / 果冻」换掉了，
  /// 老用户存的是旧 id，直接回落到最接近的新风格，不要跳回水墨。
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
  /// 圆形色块（水墨 / 炫彩）
  blob,

  /// 圆角矩形块（磨砂 / 反色，像 iOS 分段控件）
  pill,

  /// 只有选中项下方一个小圆点（实心，最极简）
  dot,

  /// 选中项下方一条短横线（霓虹）
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
  // 悬浮栏 6 种风格：水墨 / 磨砂 / 炫彩 / 霓虹 / 反色 / 实心。
  // 图标文字色与选中指示器底色都从这里取，底栏与侧栏共用同一套，
  // 避免"自定义了风格但某一处仍是旧配色"。

  /// 图标/文字颜色
  static Color styleContentColor(
    FloatingNavStyle style, {
    required bool selected,
    required bool isDark,
    required JellyPalette palette,
  }) {
    switch (style) {
      case FloatingNavStyle.aurora:
        // 炫彩底现在锚定在主题色上（见 `auroraColorsFor`），锚点可能很亮
        //（「蕉红」「碧青」），也可能很暗（「水墨」墨灰）——
        // 写死白字会在亮渐变上糊掉，所以按锚点亮度取黑/白。
        final onAurora = _onAurora(palette, isDark: isDark);
        return onAurora.withValues(alpha: selected ? 1 : 0.78);
      case FloatingNavStyle.neon:
        return selected ? Colors.white : Colors.white.withValues(alpha: 0.58);
      case FloatingNavStyle.reverse:
        // 底是"反色"的：深色主题里胶囊是浅色 ⇒ 字要黑；
        // 浅色主题里胶囊是深色 ⇒ 字要白。
        if (isDark) {
          return selected
              ? Colors.black
              : Colors.black.withValues(alpha: 0.55);
        }
        return selected ? Colors.white : Colors.white.withValues(alpha: 0.64);
      case FloatingNavStyle.solid:
        // 实心：选中块是主题色 ⇒ 白字；未选中压在实底上，对比度足够
        return selected
            ? Colors.white
            : (isDark
                ? Colors.white.withValues(alpha: 0.62)
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
  /// 描边/果冻两种风格都把主题色本身当前景：墨灰 (#3A3A3A) 压深色底
  /// 会糊掉、亮黄压浅底也会糊 ⇒ 亮度不够就往白/黑偏一档。
  static Color _legibleAccent(bool isDark, JellyPalette palette) {
    final p = palette.primary;
    final l = p.computeLuminance();
    // 深色底需要 0.35 以上的亮度；浅色底需要 0.55 以下
    if (isDark && l < 0.35) return Color.lerp(p, Colors.white, 0.55)!;
    if (!isDark && l > 0.55) return Color.lerp(p, Colors.black, 0.40)!;
    return p;
  }

  // 2026-10-30：这里原来有个写死的 `auroraColors`（紫/粉/青）。
  // 重构炫彩风格时发现它正是"底栏跟主题打架"的根源 ——
  // 用户换成「蕉红」「碧青」后页面全红，底栏还是紫的。
  // 现在改用 [auroraColorsFor]（以主题强调色为锚点），常量已删除。

  /// 霓虹风格的固定主色（描边 / 光晕 / 选中指示器）
  static const Color neonColor = Color(0xFF22D3EE);

  /// 选中指示器底色
  static Color styleIndicatorColor(
    FloatingNavStyle style, {
    required bool isDark,
    required JellyPalette palette,
  }) {
    switch (style) {
      case FloatingNavStyle.aurora:
        return _onAurora(palette, isDark: isDark).withValues(alpha: 0.30);
      case FloatingNavStyle.neon:
        return neonColor.withValues(alpha: 0.30);
      case FloatingNavStyle.solid:
        // 实心：选中项直接是实心主题色块
        return _legibleAccent(isDark, palette);
      case FloatingNavStyle.reverse:
        // 反色底上用"底色的反方向"做高亮：深胶囊里提亮、浅胶囊里压暗
        return isDark
            ? Colors.black.withValues(alpha: 0.10)
            : Colors.white.withValues(alpha: 0.20);
      case FloatingNavStyle.frost:
        // 磨砂：中性高亮，不染主题色，玻璃感更纯
        return isDark
            ? Colors.white.withValues(alpha: 0.16)
            : Colors.black.withValues(alpha: 0.06);
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

  // ── 形态（2026-10-24：用户「你就是换个颜色吗？」）──────────────
  //
  // 六种风格必须在**形状**上也能一眼区分，不能只有底色不同：
  //   ink    水墨：标准胶囊 32 + 圆形指示块
  //   frost  磨砂：更方的 22 + 圆角矩形指示块（iOS 分段感）
  //   aurora 炫彩：胶囊 32 + 圆形指示块
  //   neon   霓虹：小圆角 14 + 底部短横线
  //   reverse反色：满胶囊 999 + 圆角矩形指示块
  //   solid  实心：方润 16 + 底部小圆点

  /// 该风格的胶囊圆角
  static double styleRadius(FloatingNavStyle style) {
    switch (style) {
      case FloatingNavStyle.ink:
      case FloatingNavStyle.aurora:
        return radius; // 32
      case FloatingNavStyle.frost:
        return 22;
      case FloatingNavStyle.neon:
        return 14;
      case FloatingNavStyle.reverse:
        return 999; // 完全胶囊
      case FloatingNavStyle.solid:
        return 16;
    }
  }

  /// 该风格的选中指示器形态
  static NavIndicator styleIndicator(FloatingNavStyle style) {
    switch (style) {
      case FloatingNavStyle.ink:
      case FloatingNavStyle.aurora:
        return NavIndicator.blob;
      case FloatingNavStyle.frost:
      case FloatingNavStyle.reverse:
        return NavIndicator.pill;
      case FloatingNavStyle.neon:
        return NavIndicator.underline;
      case FloatingNavStyle.solid:
        return NavIndicator.dot;
    }
  }

  /// 把整条底栏的底色/渐变按 [opacity] 整体压暗透明度。
  ///
  /// 只在**出口处**统一乘一次 —— 六种风格各自的配色分支不用关心透明度，
  /// 也就不会出现"调了滑杆只有水墨变了、炫彩没反应"。
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
  // 六种风格的**唯一**配色出口（2026-10-30 重构）
  // ============================================================
  //
  // 用户：「那个菜单栏的主题给我除了第一个外，其余 5 个重构」。
  //
  // 重构前的三个毛病：
  //   ① 配色散在两处 —— `jelly_nav_bar._barDecoration`（真底栏）和
  //      `nav_appearance_page._styleCard`（设置里的预览卡）各写一份。
  //      改一边忘另一边，就会"预览跟实际不一样"。
  //   ② 炫彩写死紫/粉/青、霓虹写死青色、实心写死 #17171A。
  //      用户换成「碧青」「蕉红」这类配色时，底栏还是那套紫，跟壁纸打架。
  //   ③ 磨砂/反色/实心的区别只有"底色深浅"，形态上看不出是三种东西。
  //
  // 现在：一个函数出装饰、一个函数出阴影，颜色**全部从 palette 推**，
  // 形态差异（圆角 + 指示器）由 styleRadius / styleIndicator 决定。

  /// 炫彩渐变：以主题强调色为锚点，向紫 / 青各偏一点。
  ///
  /// 不用固定的 `auroraColors` 三色：那套在「蕉红」「碧青」主题下会跟
  /// 整屏颜色打架（底栏紫、页面红）。以 accent 为锚点后，
  /// 无论换哪套配色，底栏都是"这个主题的彩色版"。
  static List<Color> auroraColorsFor(
    JellyPalette palette, {
    required bool isDark,
  }) {
    final base = palette.primary;
    // 深色底要提亮、浅色底要压深，否则渐变两头会糊在一起没有层次
    final anchor = isDark
        ? Color.lerp(base, Colors.white, 0.14)!
        : Color.lerp(base, Colors.black, 0.10)!;
    return [
      Color.lerp(anchor, const Color(0xFF7C4DFF), 0.34)!,
      anchor,
      Color.lerp(anchor, const Color(0xFF22D3EE), 0.30)!,
    ];
  }

  /// 炫彩渐变上"最清楚"的前景色。
  ///
  /// 渐变锚点（中间那色）是主题色的提亮/压深版，亮度跨度很大：
  /// 「水墨」是深墨灰、「蕉红」是亮红。白字在亮红上只有 2:1 左右，
  /// 所以按锚点亮度二选一，而不是一律白字。
  static Color _onAurora(JellyPalette palette, {required bool isDark}) {
    final anchor = auroraColorsFor(palette, isDark: isDark)[1];
    return anchor.computeLuminance() > 0.52 ? Colors.black : Colors.white;
  }

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
        // 磨砂 = 液态玻璃：
        //   · 上亮下暗的玻璃渐变（光源在上方，这是玻璃感的来源）
        //   · 1px 亮边（不是白色纯描边，深色下会像贴纸）
        //   · 顶部再压一道更亮的高光带，模拟玻璃边缘的反光
        deco = BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? [
                    Colors.white.withValues(alpha: 0.26),
                    Colors.white.withValues(alpha: 0.12),
                    Colors.white.withValues(alpha: 0.06),
                  ]
                : [
                    Colors.white.withValues(alpha: 0.90),
                    Colors.white.withValues(alpha: 0.70),
                    Colors.white.withValues(alpha: 0.56),
                  ],
            stops: const [0.0, 0.34, 1.0],
          ),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.22)
                : Colors.white.withValues(alpha: 0.95),
            width: 0.9,
          ),
        );
        break;

      case FloatingNavStyle.aurora:
        // 炫彩：主题色三色渐变 + 白描边（描边让渐变有"边框"，不然边缘发虚）
        deco = BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: auroraColorsFor(palette, isDark: isDark),
          ),
          border: Border.all(color: Colors.white.withValues(alpha: 0.32)),
        );
        break;

      case FloatingNavStyle.neon:
        // 霓虹：深管 + 双层描边（外圈霓虹色、内圈极淡白），像一根发光灯管
        deco = BoxDecoration(
          color: const Color(0xFF0C0D12),
          borderRadius: radius,
          border: Border.all(
            color: neonColor.withValues(alpha: 0.92),
            width: 1.3,
          ),
        );
        break;

      case FloatingNavStyle.reverse:
        // 反色：底色与界面明暗**相反**，但用调色板的卡片色做反色基准
        //（写死 #F3F3F5 / #1E2024 的话，暖色主题下底栏会偏冷，像贴上去的）
        deco = BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isDark
                ? [
                    Color.lerp(palette.cardLight, Colors.white, 0.55)!,
                    Color.lerp(palette.cardLight, Colors.white, 0.30)!,
                  ]
                : [
                    Color.lerp(palette.cardDark, Colors.black, 0.18)!,
                    palette.cardDark,
                  ],
          ),
          border: Border.all(
            color: isDark
                ? Colors.black.withValues(alpha: 0.07)
                : Colors.white.withValues(alpha: 0.12),
            width: 0.7,
          ),
        );
        break;

      case FloatingNavStyle.solid:
        // 实心：用调色板的卡片色做**实底**（不是写死的近白色）
        deco = BoxDecoration(
          color: (isDark ? palette.cardDark : palette.cardLight)
              .withValues(alpha: 0.99),
          borderRadius: radius,
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.07)
                : Colors.black.withValues(alpha: 0.06),
            width: 0.7,
          ),
        );
        break;
    }
    return applyOpacity(deco, opacity ?? defaultOpacity);
  }

  /// 底栏外阴影（炫彩/霓虹带同色光晕，其余是中性投影）。
  static List<BoxShadow> barShadows({
    required FloatingNavStyle style,
    required bool isDark,
    required JellyPalette palette,
  }) {
    switch (style) {
      case FloatingNavStyle.aurora:
        return [
          BoxShadow(
            color: auroraColorsFor(palette, isDark: isDark)[1]
                .withValues(alpha: 0.40),
            blurRadius: 22,
            offset: const Offset(0, 7),
          ),
        ];
      case FloatingNavStyle.neon:
        return [
          BoxShadow(
            color: neonColor.withValues(alpha: 0.42),
            blurRadius: 20,
            spreadRadius: 1,
          ),
        ];
      case FloatingNavStyle.frost:
        return [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.36 : 0.10),
            blurRadius: 26,
            offset: const Offset(0, 8),
          ),
        ];
      case FloatingNavStyle.reverse:
        return [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.26 : 0.16),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ];
      case FloatingNavStyle.solid:
        return [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.40 : 0.12),
            blurRadius: 18,
            offset: const Offset(0, 6),
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
