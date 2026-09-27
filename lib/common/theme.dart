import 'package:flutter/material.dart';

/// 全局明暗：外观模式切换后 AppTheme 颜色跟着变（深色/浅色/跟随系统）
class AppBrightness {
  /// true = 浅色界面
  static final ValueNotifier<bool> isLight = ValueNotifier(false);
}

/// 主题配置 - 匹配 tvbox-Swift 设计系统 + iOS 27 Liquid Glass 玻璃体系
class AppTheme {
  // 颜色（getter 跟随外观模式）
  static const Color accentColor = Color(0xFF5CB67B);
  static const Color accentLightColor = Color(0xFF7DCEA0);
  static Color get backgroundPrimary =>
      AppBrightness.isLight.value ? const Color(0xFFF6F6F7) : const Color(0xFF0F0F0F);
  static Color get backgroundSecondary =>
      AppBrightness.isLight.value ? const Color(0xFFFFFFFF) : const Color(0xFF1A1A1A);
  static Color get backgroundTertiary => AppBrightness.isLight.value
      ? const Color(0x0F000000)
      : const Color(0x0FFFFFFF);
  static Color get backgroundElevated => AppBrightness.isLight.value
      ? const Color(0x14000000)
      : const Color(0x14FFFFFF);

  // ===== 半透明卡片色 =====
  static Color get backgroundCard => AppBrightness.isLight.value
      ? const Color(0xCCFFFFFF)
      : const Color(0xCC1A1A1A);
  static Color get backgroundCardElevated => AppBrightness.isLight.value
      ? const Color(0xE6FFFFFF)
      : const Color(0xE61A1A1A);
  static Color get backgroundNavBar => AppBrightness.isLight.value
      ? const Color(0xCCFFFFFF)
      : const Color(0xCC1C1C1E);

  // ===== iOS 27 Liquid Glass 玻璃体系 =====
  // 玻璃底色: 白 10% tint, 叠加在全局背景层/页面内容上形成磨砂观感
  static const Color glassTint = Color(0x1AFFFFFF);
  // 深色玻璃底: 供列表内高频卡片模拟玻璃 (不开 blur 保性能)
  static const Color glassTintDeep = Color(0x18181A1F);
  /// 浅玻璃底（悬浮栏用）：alpha≈4%，比 glassTintDeep 更透，
  /// 让全局渐变背景透出，悬浮导航栏看起来更"轻"。
  static const Color glassTintLight = Color(0x0A0F1013);
  /// 超浅玻璃底（沉浸式底栏用）：alpha≈2%，几乎全透明只留模糊+描边，
  /// 底栏不再遮挡内容，真正"沉浸式"（2026-09-26 新增）。
  static const Color glassTintClear = Color(0x050F1013);
  // 高光层: 顶部镜面高光 (iOS 27 更亮的 specular highlight)
  static const Color glassHighlightTop = Color(0x2EFFFFFF); // white 18%
  static const Color glassHighlightMid = Color(0x0FFFFFFF); // white 6%
  // 描边: 亮描边增强边缘分离感
  static const Color glassBorder = Color(0x2EFFFFFF); // white 18%
  static const Color glassBorderSoft = Color(0x1FFFFFFF); // white 12%
  // 玻璃圆角
  static const double glassRadius = 24; // 面板/弹窗大圆角
  static const double glassRadiusCard = 16; // 卡片圆角
  // 玻璃模糊强度 (iOS 27 对背景内容扩散更强)
  static const double glassBlurSigma = 28;

  static Color get textPrimary =>
      AppBrightness.isLight.value ? const Color(0xE61A1A1A) : const Color(0xEBEBEBEB);
  static Color get textSecondary =>
      AppBrightness.isLight.value ? const Color(0x8C1A1A1A) : const Color(0x8CFFFFFF);
  static Color get textTertiary =>
      AppBrightness.isLight.value ? const Color(0x591A1A1A) : const Color(0x59FFFFFF);

  static Color get borderLight =>
      AppBrightness.isLight.value ? const Color(0x14000000) : const Color(0x14FFFFFF);
  static Color get borderMedium =>
      AppBrightness.isLight.value ? const Color(0x24000000) : const Color(0x24FFFFFF);

  // 间距
  static const double spacingXS = 4;
  static const double spacingSM = 8;
  static const double spacingMD = 12;
  static const double spacingLG = 16;
  static const double spacingXL = 20;
  static const double spacingXXL = 24;

  // 圆角
  static const double radiusSM = 8;
  static const double radiusMD = 10;
  static const double radiusLG = 14;
  static const double radiusXL = 20;

  // 卡片
  static const double cardRadius = 10;
  static const double cardSpacing = 6;
  static const double cardPadding = 8;

  // 字号
  static const double fontCaption = 11;
  static const double fontFootnote = 12;
  static const double fontSubhead = 13;
  static const double fontBody = 14;
  static const double fontHeadline = 16;
  static const double fontTitle3 = 18;
  static const double fontTitle2 = 20;

  /// 暗色主题

  /// 浅色主题（设置 → 深色/浅色/跟随系统）
  static ThemeData get lightTheme {
    final base = ThemeData.light(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: const Color(0xFFF6F6F7),
      colorScheme: base.colorScheme.copyWith(
        primary: accentColor,
        surface: const Color(0xFFFFFFFF),
        onSurface: const Color(0xFF1A1A1A),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Color(0xFF1A1A1A),
      ),
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: backgroundPrimary,
      colorScheme: const ColorScheme.dark(
        primary: accentColor,
        secondary: accentLightColor,
        surface: backgroundSecondary,
        error: Colors.red,
      ),
      appBarTheme: const AppBarTheme(
        // 透明 + 无 elevation: 让全局背景层透出, 配合页面顶部形成玻璃观感;
        // 需要真实毛玻璃的页面 (detail 等) 自行用 GlassPanel/flexibleSpace
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: fontHeadline,
          fontWeight: FontWeight.bold,
        ),
        iconTheme: IconThemeData(color: textSecondary),
      ),
      cardTheme: CardThemeData(
        color: backgroundSecondary,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(cardRadius),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: backgroundTertiary,
        selectedColor: accentColor.withValues(alpha: 0.15),
        labelStyle: const TextStyle(color: textSecondary, fontSize: fontSubhead),
        side: BorderSide.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Color(0xFF1C1C1E),
        selectedItemColor: accentColor,
        unselectedItemColor: textTertiary,
        type: BottomNavigationBarType.fixed,
        selectedLabelStyle: TextStyle(fontSize: 10, fontWeight: FontWeight.w500),
        unselectedLabelStyle: TextStyle(fontSize: 10),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: backgroundSecondary,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMD),
          borderSide: BorderSide.none,
        ),
        hintStyle: const TextStyle(color: textTertiary, fontSize: fontSubhead),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: spacingLG,
          vertical: spacingMD,
        ),
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
            color: textPrimary, fontSize: 48, fontWeight: FontWeight.w800),
        headlineMedium: TextStyle(
            color: textPrimary, fontSize: fontTitle2, fontWeight: FontWeight.w700),
        headlineSmall: TextStyle(
            color: textPrimary, fontSize: fontTitle3, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(color: textPrimary, fontSize: fontBody),
        bodyMedium: TextStyle(color: textSecondary, fontSize: fontSubhead),
        bodySmall: TextStyle(color: textTertiary, fontSize: fontFootnote),
        labelLarge: TextStyle(
            color: textPrimary, fontSize: fontBody, fontWeight: FontWeight.w600),
        labelMedium: TextStyle(color: textSecondary, fontSize: fontSubhead),
        labelSmall: TextStyle(color: textTertiary, fontSize: fontCaption),
      ),
      useMaterial3: true,
    );
  }
}
