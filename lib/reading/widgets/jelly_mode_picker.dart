import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../models/reading_settings.dart';
import '../services/settings_service.dart';

/// 阅读模式选择器里的一项。
class JellyModeItem {
  const JellyModeItem({
    required this.label,
    required this.symbol,
    required this.selected,
    required this.onTap,
  });

  /// 2 字简称（左右 / 上下 / 仿真 / 覆盖 / 无动画 ……）
  final String label;

  /// 文字符号（↔ / ↕ / 📖 / ⬚ / ⚡ ……）—— 用户 2026-10-15：
  /// 「这种文字就行，不用图标」，所以是**文本字符**，不是 IconData。
  final String symbol;

  final bool selected;
  final VoidCallback onTap;
}

/// 阅读模式符号（书源阅读器的 [PageMode]）。
String pageModeSymbol(PageMode m) => switch (m) {
      PageMode.slide => '↔',
      PageMode.scroll => '↕',
      PageMode.curl => '📖',
      PageMode.cover => '⬚',
      PageMode.none => '⚡',
    };

/// 阅读模式符号（图书阅读器的 [BookReadingMode]，语义同 [PageMode]）。
String bookModeSymbol(BookReadingMode m) => switch (m) {
      BookReadingMode.pageTurn => '↔',
      BookReadingMode.vertical => '↕',
      BookReadingMode.simulation => '📖',
      BookReadingMode.cover => '⬚',
      BookReadingMode.none => '⚡',
    };

/// 阅读模式符号（漫画阅读器的 [ReadingMode]）。
String mangaModeSymbol(ReadingMode m) => switch (m) {
      ReadingMode.pageTurn => '⇄',
      ReadingMode.leftToRight => '⇆',
      ReadingMode.dissolve => '✧',
      ReadingMode.continuous => '☰',
      ReadingMode.none => '⚡',
    };

/// 阅读模式选择器（图书 / 书源 / 漫画阅读器共用）。
///
/// 用户 2026-10-15：「左右 / 上下 / 仿真 / 覆盖 / 无动画这些不够好，优化一哈」
/// ⇒ 每个模式从「纯文字 chip」升级为「符号 + 名称」的等宽小块，
///   且**只用文字**（不要 Material 图标）：`↔ 左右`、`⚡ 无动画`。
///   选中态实底 + 描边 + 加粗，四种阅读器共用同一套观感。
class JellyModePicker extends StatelessWidget {
  const JellyModePicker({
    super.key,
    required this.items,
    required this.fg,
    this.gap = 6,
  });

  final List<JellyModeItem> items;

  /// 前景色。阅读器底色是深/浅自适应的，所以由调用方传入，
  /// 内部所有颜色都从它派生（选中 ≈ 实底，未选中 ≈ 半透明淡底）。
  final Color fg;

  /// 块间距
  final double gap;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      if (i > 0) children.add(SizedBox(width: gap));
      children.add(Expanded(child: _tile(items[i])));
    }
    return Row(children: children);
  }

  Widget _tile(JellyModeItem item) {
    final on = item.selected;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: item.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: fg.withValues(alpha: on ? 0.16 : 0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: fg.withValues(alpha: on ? 0.45 : 0.0)),
        ),
        // 窄屏兜底：极少数长标签（`⚡ 无动画`）略微缩一点，不换行、不溢出
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            '${item.symbol} ${item.label}',
            maxLines: 1,
            style: TextStyle(
              fontSize: AppTheme.fontCaption,
              height: 1.1,
              fontWeight: on ? FontWeight.w600 : FontWeight.w500,
              color: fg.withValues(alpha: on ? 1.0 : 0.55),
            ),
          ),
        ),
      ),
    );
  }
}
