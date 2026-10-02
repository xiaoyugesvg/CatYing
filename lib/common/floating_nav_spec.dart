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
}
