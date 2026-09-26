import 'package:flutter/material.dart';

/// 全局主题常量 - 对应 Swift Theme 常量
class AppTheme {
  AppTheme._();

  // 颜色
  static const Color accentColor = Color(0xFF3D7BFF);
  static const Color backgroundPrimary = Color(0xFF0B0D12);
  static const Color backgroundSecondary = Color(0xFF14161C);
  static const Color backgroundTertiary = Color(0xFF1C1F27);

  static const Color textPrimary = Color(0xFFF2F3F5);
  static const Color textSecondary = Color(0xFFB0B4BC);
  static const Color textTertiary = Color(0xFF6E737C);

  static const Color borderLight = Color(0x1FFFFFFF);
  static const Color borderMedium = Color(0x33FFFFFF);

  // 玻璃面板
  static const Color glassTint = Color(0x1AFFFFFF);
  static const Color glassTintDeep = Color(0x18181A1F);
  /// 浅玻璃底（悬浮栏用）：alpha≈4%，比 glassTintDeep 更透，
  /// 让全局渐变背景透出，悬浮导航栏看起来更"轻"。
  static const Color glassTintLight = Color(0x0A0F1013);
  static const Color glassBorderSoft = Color(0x1FFFFFFF);
  static const Color glassBorderStrong = Color(0x33FFFFFF);
  static const double glassBlurSigma = 28;

  // 字体大小
  static const double fontCaption = 11;
  static const double fontFootnote = 12;
  static const double fontBody = 14;
  static const double fontTitle3 = 17;
  static const double fontTitle2 = 20;
  static const double fontTitle1 = 24;
  static const double fontTitle0 = 28;

  // 间距
  static const double spacingXS = 4;
  static const double spacingSM = 8;
  static const double spacingMD = 12;
  static const double spacingLG = 16;
  static const double spacingXL = 20;
  static const double spacingXXL = 28;

  // 圆角
  static const double radiusSM = 6;
  static const double radiusMD = 10;
  static const double radiusLG = 16;
  static const double radiusXL = 24;
}
