import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/reading/theme/jelly_theme.dart';
import 'package:tvbox/widgets/help_sheet.dart';

/// 阅读 / 听书模块的「?」说明弹窗配色。
///
/// 这一族页面走 [JellyTheme]（24 套调色板），不是设置页的 `AppTheme`。
/// 用错配色会出「米白卡片浮在墨夜底上」那种违和感，所以单独给一份。
HelpPalette get jellyHelpPalette {
  final dark = !AppBrightness.isLight.value;
  return HelpPalette(
    surface: dark ? JellyTheme.cardDark : JellyTheme.cardLight,
    textPrimary: dark ? Colors.white : JellyTheme.textPrimaryLight,
    textSecondary: JellyTheme.textSecondary,
    textTertiary: AppTheme.textTertiary,
    accent: dark ? JellyTheme.primaryLight : JellyTheme.primary,
    border: dark
        ? Colors.white.withValues(alpha: 0.10)
        : JellyTheme.primary.withValues(alpha: 0.14),
    radius: 14,
  );
}

/// 阅读 / 听书页右上角「?」按钮。
Widget readingHelpAction({required VoidCallback onPressed}) {
  return helpAction(
    onPressed: onPressed,
    color: AppBrightness.isLight.value
        ? JellyTheme.textPrimaryLight
        : Colors.white,
  );
}

/// 弹出阅读 / 听书的说明弹窗。
Future<void> showReadingHelp(
  BuildContext context,
  String title,
  List<HelpItem> items,
) {
  return showHelpSheet(
    context,
    title: title,
    items: items,
    palette: jellyHelpPalette,
  );
}
