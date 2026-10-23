import 'package:flutter/material.dart';

import '../reading/theme/jelly_palette.dart';

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

  /// 液态玻璃：高透光 + 白色高光描边
  liquid('liquid', '液态玻璃'),

  /// 炫彩：主题色渐变，图标纯白
  aurora('aurora', '炫彩'),

  /// 霓虹：深色底 + 发光描边
  neon('neon', '霓虹'),

  /// 描边：透明底 + 主题色细描边（最轻，几乎不遮挡内容）
  outline('outline', '描边'),

  /// 果冻：主题色半透明底 + 白色高光，选中项是实心主题色
  jelly('jelly', '果冻');

  const FloatingNavStyle(this.id, this.label);

  final String id;
  final String label;

  static FloatingNavStyle fromId(String? id) => values.firstWhere(
        (e) => e.id == id,
        orElse: () => FloatingNavStyle.ink,
      );
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
  // 悬浮栏支持 4 种风格：水墨 / 液态玻璃 / 炫彩 / 霓虹。
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
        return Colors.white.withValues(alpha: selected ? 1 : 0.76);
      case FloatingNavStyle.neon:
        return selected ? Colors.white : Colors.white.withValues(alpha: 0.58);
      case FloatingNavStyle.jelly:
        // 选中项是实心主题色 → 必须白字；未选中用可读的主题色
        return selected
            ? Colors.white
            : _legibleAccent(isDark, palette).withValues(alpha: 0.72);
      case FloatingNavStyle.outline:
        return selected
            ? _legibleAccent(isDark, palette)
            : _legibleAccent(isDark, palette).withValues(alpha: 0.62);
      case FloatingNavStyle.liquid:
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

  /// 炫彩风格的固定渐变色（不跟主题走：主题默认是墨灰，混出来不"炫"）
  static const List<Color> auroraColors = [
    Color(0xFF7C4DFF),
    Color(0xFFFF4D8D),
    Color(0xFF22D3EE),
  ];

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
        return Colors.white.withValues(alpha: 0.26);
      case FloatingNavStyle.neon:
        return neonColor.withValues(alpha: 0.30);
      case FloatingNavStyle.jelly:
        // 果冻：选中项直接是实心主题色块
        return _legibleAccent(isDark, palette);
      case FloatingNavStyle.outline:
        // 描边：选中项用主题色的淡底，不抢描边的视觉
        return _legibleAccent(isDark, palette)
            .withValues(alpha: isDark ? 0.20 : 0.12);
      case FloatingNavStyle.liquid:
        return Colors.white.withValues(alpha: isDark ? 0.20 : 0.62);
      case FloatingNavStyle.ink:
        return isDark ? palette.navSelectedFg : palette.navSelectedBg;
    }
  }
}
