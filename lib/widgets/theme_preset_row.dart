import 'package:flutter/material.dart';

import '../common/theme.dart';

/// 主题预设行 —— **与阅读模块「主题风格」面板同款**：三色点 + 名称 + 右侧单选圈。
///
/// ── 为什么抽出来 ──────────────────────────────────────────────
/// 用户 2026-10-16：「其余模块的主题样式的 UI 能不能也参考弄成阅读那样的」。
/// 影视/直播、音乐原来用的是「色点 Wrap 网格」（34×34 三色环 + 名称在下），
/// 与阅读那套**全宽圆角行**不是一回事。这里收敛成一份，三处共用。
/// （阅读自己的面板交互更重 —— 省电开关 / 动效 / 自定义主题编辑器 / 揭晓动画，
///  没反向改成用它，避免弄坏已经定稿的交互。）
class ThemePresetRow extends StatelessWidget {
  final String name;

  /// 副标题（「跟随阅读」那行用它写一句说明）
  final String? subtitle;

  /// 三色点：一般是 [主色, 强调色, 浅底色]
  final List<Color> dots;

  final bool selected;
  final VoidCallback? onTap;

  /// 右侧图标（默认按选中态显示单选圈；传了就按传的来，例如入口行用箭头）
  final Widget? trailing;

  const ThemePresetRow({
    super.key,
    required this.name,
    required this.dots,
    required this.selected,
    this.subtitle,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          // 选中给一层浅底（与阅读面板同一思路：靠底色差 + 加粗 + 单选圈三处提示）
          color: selected ? AppTheme.backgroundTertiary : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            for (final c in dots)
              Container(
                width: 18,
                height: 18,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppTheme.borderLight),
                ),
              ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                      color: selected
                          ? AppTheme.accentOnSurface
                          : AppTheme.textPrimary,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: AppTheme.fontCaption,
                          color: AppTheme.textTertiary),
                    ),
                ],
              ),
            ),
            trailing ??
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: selected
                      ? AppTheme.accentOnSurface
                      : AppTheme.textTertiary,
                ),
          ],
        ),
      ),
    );
  }
}

/// 打开与阅读同款的「选择主题」底部面板：把手 + 标题 + 行列表。
///
/// [rowsBuilder] 拿的是**面板自己的** BuildContext —— 行里的 onTap 要用它
/// `Navigator.of(sheetCtx).pop()` 收面板。用调用方的 context 收面板是经典坑：
/// 面板已被用户点暗区关掉时，那一下会 pop 掉**底下的页面**（阅读那边踩过，
/// 症状是空栈黑屏）。
Future<void> showThemePresetSheet({
  required BuildContext context,
  required String title,
  String? subtitle,
  required List<Widget> Function(BuildContext sheetCtx) rowsBuilder,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => Container(
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.borderMedium,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                title,
                style: TextStyle(
                  fontSize: AppTheme.fontTitle3,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
            ),
            if (subtitle != null && subtitle.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 2),
                child: Text(
                  subtitle,
                  style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      color: AppTheme.textTertiary),
                ),
              ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.6,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: rowsBuilder(ctx),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}
