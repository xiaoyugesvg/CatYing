import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';

/// RFW 主题的**色板翻译层**：把 [AppTheme] 的当前配色翻成 `.rfwtxt` 能读的整数色值。
///
/// ── 为什么需要这一层（2026-10-30）────────────────────────────────
/// 用户反馈：「这个 RFW 主题没有贴合我的软件界面。」
///
/// 之前三个内置主题的每个颜色都是**写死的字面量**：
///   · 晨光网格 `#FAF6EE / #C96F2E / #2B2620`
///   · 素影列表 `#F2F2F0 / #2E7D74 / #232323`
///   · 星河横幅 `#0E1424 / #D9A441 / #FFFFFF`
/// 这些跟用户在「主题配色」里选的 24 套调色板**毫无关系** ——
/// 用户在软件里用着「碧青」，切到 RFW 主题首页却变成一块暖米色 + 橙按钮，
/// 等于换了个 App。这就是"不贴合"的根因。
///
/// 现在的做法：**颜色全部由 Dart 侧算好再喂进去**。
/// `.rfwtxt` 里只写 `data.home.theme.bg` / `.accent` 这类 token，
/// 不再出现任何色值字面量 ⇒ 换配色时首页跟软件一起变。
///
/// 三个主题的差异保留在**布局与色调倾向**上，而不是"另一套配色"：
///   · `chenguang` 晨光网格 —— 暖色调偏移（+10% 琥珀），三列海报
///   · `suyu`      素影列表 —— 零偏移，完全跟随软件配色
///   · `xinghe`    星河横幅 —— 强制深色底（深底 + 提亮强调色），横滑大图
class RfwThemePalette {
  const RfwThemePalette({
    required this.isDark,
    required this.bg,
    required this.surface,
    required this.card,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.accentFill,
    required this.onAccent,
    required this.chipBg,
    required this.border,
    required this.scrim,
    required this.onImage,
    required this.glassTint,
    required this.radiusCard,
    required this.radiusCardLg,
    required this.radiusChip,
    required this.radiusPill,
    required this.gap,
    required this.pad,
    required this.headerPadTop,
  });

  /// 该主题是否是深色皮肤（决定 hero 图片上的蒙层浓度）
  final bool isDark;

  /// 页面底色
  final Color bg;

  /// 吸顶头 / 分组标题底（不透明，压住滚动内容）
  final Color surface;

  /// 片单卡片底
  final Color card;

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  /// 强调色 —— **当文字/图标/描边用时用它**（已按当前底色做对比度兜底）
  final Color accent;

  /// 强调色实底（选中胶囊、进度条、carousel 指示器）
  final Color accentFill;

  /// 压在 [accentFill] 上的文字/图标色
  final Color onAccent;

  /// 未选中胶囊/筛选项的底色
  final Color chipBg;

  /// 细描边（1px）
  final Color border;

  /// 图片上的压暗蒙层
  final Color scrim;

  /// 压在图片上的文字
  final Color onImage;

  /// 玻璃头的 tint（带 alpha）
  final Color glassTint;

  final double radiusCard;

  /// 大一号的卡片圆角（横向条目 / 实体卡片块用）。
  ///
  /// `.rfwtxt` 的表达式**不支持算术运算**（写 `radiusCard + 4.0` 会直接
  /// 解析失败：`Unexpected character U+002B`），所以差值必须在 Dart 侧算好
  /// 再作为独立 token 喂进去（2026-10-30 实测踩到）。
  final double radiusCardLg;

  final double radiusChip;
  final double radiusPill;
  final double gap;
  final double pad;
  final double headerPadTop;

  /// 按主题 id 生成色板。
  ///
  /// [themeId] 传 null 或自定义主题（用户导入的 `.rfwtxt`）时，
  /// 按「完全跟随软件配色」处理 —— 自定义主题本来就会自己写颜色，
  /// 这里给的 token 只是它**没写**时的兜底。
  factory RfwThemePalette.of(String? themeId) {
    final light = AppBrightness.isLight.value;
    final baseBg = AppTheme.backgroundPrimary;
    final baseCard = AppTheme.backgroundSecondary;
    final baseAccent = AppTheme.accentOnSurface;

    switch (themeId) {
      case 'chenguang':
        // 暖色调偏移：让"晨光"这个名字成立，但底色仍然从软件配色出发。
        // 10% 是实测的临界值 —— 再多就会把「碧青」这类冷色主题染脏。
        const warm = Color(0xFFFFC98A);
        final bg = Color.lerp(baseBg, warm, light ? 0.10 : 0.07)!;
        final card = Color.lerp(baseCard, warm, light ? 0.08 : 0.06)!;
        return RfwThemePalette._build(
          isDark: !light,
          bg: bg,
          card: card,
          accentBase: baseAccent,
          radiusCard: 10,
          radiusChip: 12,
          radiusPill: 16,
        );
      case 'xinghe':
        // 强制深色：星河是"沉浸看片"皮肤，浅底会失去意义。
        // 深底从强调色里借一点色相，这样「碧青」的星河偏青、
        // 「蕉红」的星河偏红 —— 而不是千篇一律的藏蓝。
        final accentRaw = AppTheme.accentColor;
        final deep = Color.lerp(
          const Color(0xFF0B0F1A),
          accentRaw,
          0.10,
        )!;
        return RfwThemePalette._build(
          isDark: true,
          bg: deep,
          card: Color.lerp(deep, Colors.white, 0.09)!,
          accentBase: accentRaw,
          radiusCard: 12,
          radiusChip: 12,
          radiusPill: 16,
        );
      case 'suyu':
      default:
        // 零偏移：完全跟随软件配色
        return RfwThemePalette._build(
          isDark: !light,
          bg: baseBg,
          card: baseCard,
          accentBase: baseAccent,
          radiusCard: 10,
          radiusChip: 12,
          radiusPill: 16,
        );
    }
  }

  /// 由「底色 + 卡片底 + 强调色基准」推出一整套 token。
  ///
  /// 文字色不直接用 [AppTheme.textPrimary] —— 星河在浅色软件里也要深底，
  /// 而 `textPrimary` 那时是深色字，压上去就看不见了。
  /// 所以统一按**实际底色**推：深底给浅字、浅底给深字。
  factory RfwThemePalette._build({
    required bool isDark,
    required Color bg,
    required Color card,
    required Color accentBase,
    required double radiusCard,
    required double radiusChip,
    required double radiusPill,
  }) {
    final onBg = _readableOn(bg);
    final accent = isDark ? _liftOn(accentBase, bg) : _darkenOn(accentBase, bg);
    final onAccent = _readableOn(accent);

    // 次级文字：在「主文字」和「底色」之间取 62% / 42%，
    // 与 AppTheme 的 textSecondary / textTertiary 关系一致。
    final textSecondary = Color.lerp(onBg, bg, 0.34)!;
    final textTertiary = Color.lerp(onBg, bg, 0.52)!;

    // 未选中胶囊底：浅色下比卡片更白一点，深色下比卡片更亮一点
    final chipBg = isDark
        ? Color.lerp(card, Colors.white, 0.07)!
        : Color.lerp(card, Colors.white, 0.55)!;

    final border = Color.lerp(bg, onBg, isDark ? 0.16 : 0.12)!;

    return RfwThemePalette(
      isDark: isDark,
      bg: bg,
      surface: bg,
      card: card,
      textPrimary: onBg,
      textSecondary: textSecondary,
      textTertiary: textTertiary,
      accent: accent,
      accentFill: accent,
      onAccent: onAccent,
      chipBg: chipBg,
      border: border,
      scrim: Colors.black.withValues(alpha: isDark ? 0.62 : 0.55),
      onImage: Colors.white,
      glassTint: bg.withValues(alpha: isDark ? 0.42 : 0.55),
      radiusCard: radiusCard,
      radiusCardLg: radiusCard + 4,
      radiusChip: radiusChip,
      radiusPill: radiusPill,
      gap: AppTheme.cardSpacing,
      pad: AppTheme.cardPadding,
      headerPadTop: AppTheme.headerTop,
    );
  }

  /// 该底色上"最清楚"的正文色。
  ///
  /// 不按固定亮度阈值分档 —— 底色刚好落在中间灰（例如用户自定义了
  /// 中等明度的背景）时，阈值法会挑到对比度更低的那一边。
  /// 直接两边都算一遍取高的，永远是最优解。
  static Color _readableOn(Color background) {
    final white = Color.lerp(Colors.white, background, 0.06)!;
    final black = Color.lerp(Colors.black, background, 0.10)!;
    return _contrast(white, background) >= _contrast(black, background)
        ? white
        : black;
  }

  /// 把 [c] 提亮到在 [on] 上对比度 ≥ 4.5（深色皮肤用）
  static Color _liftOn(Color c, Color on) {
    var out = c;
    for (var i = 0; i < 16; i++) {
      if (_contrast(out, on) >= 4.5) return out;
      out = Color.lerp(out, Colors.white, i == 0 ? 0.28 : 0.08)!;
    }
    return out;
  }

  /// 把 [c] 压暗到在 [on] 上对比度 ≥ 4.5（浅色皮肤用）
  static Color _darkenOn(Color c, Color on) {
    var out = c;
    for (var i = 0; i < 16; i++) {
      if (_contrast(out, on) >= 4.5) return out;
      out = Color.lerp(out, Colors.black, i == 0 ? 0.30 : 0.08)!;
    }
    return out;
  }

  static double _contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// 压成 `data.home.theme` 这个 map。
  ///
  /// RFW 的颜色解码器只吃 `int`（0xAARRGGBB），所以这里统一转 ARGB32。
  Map<String, Object?> toData() => <String, Object?>{
        'isDark': isDark,
        'bg': _argb(bg),
        'surface': _argb(surface),
        'card': _argb(card),
        'textPrimary': _argb(textPrimary),
        'textSecondary': _argb(textSecondary),
        'textTertiary': _argb(textTertiary),
        'accent': _argb(accent),
        'accentFill': _argb(accentFill),
        'onAccent': _argb(onAccent),
        'chipBg': _argb(chipBg),
        'border': _argb(border),
        'scrim': _argb(scrim),
        'onImage': _argb(onImage),
        'glassTint': _argb(glassTint),
        'radiusCard': radiusCard,
        'radiusCardLg': radiusCardLg,
        'radiusChip': radiusChip,
        'radiusPill': radiusPill,
        'gap': gap,
        'pad': pad,
        'headerPadTop': headerPadTop,
      };

  static int _argb(Color c) => c.toARGB32();
}
