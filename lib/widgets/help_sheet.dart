import 'package:flutter/material.dart';

/// 页面右上角「?」说明系统的**共享实现**。
///
/// ── 为什么单独抽一个文件 ─────────────────────────────────────────
/// 用户 2026-10-30：「AI 管理以及听书管理等页面右上角加个 ? 按钮，
/// 详情说明怎么用每一种方式呢。」
///
/// 说明弹窗一开始只长在设置子页里（`SettingsHelp`，配色写死 `AppTheme`）。
/// 但「听书 / 音乐」用的是另一套配色体系（`JellyTheme` / `MusicTheme`），
/// 直接复用会把一个米白卡片弹到音乐页的深色底上。
///
/// 所以把「长什么样」和「用哪套颜色」拆开：
///   · [HelpItem] 只描述内容；
///   · [HelpPalette] 描述颜色（各模块自己给）；
///   · [showHelpSheet] / [helpAction] 是唯一的渲染入口。
class HelpItem {
  const HelpItem({this.icon, required this.title, required this.body});

  final IconData? icon;
  final String title;
  final String body;
}

/// 说明弹窗的配色。各模块按自己的主题体系构造一份。
@immutable
class HelpPalette {
  const HelpPalette({
    required this.surface,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.border,
    this.iconTint,
    this.radius = 14,
  });

  final Color surface;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  /// 标题图标 / 「知道了」按钮的颜色
  final Color accent;

  final Color border;

  /// 每条说明左侧小方块的底色（默认取 [accent] 的 14% 透明）
  final Color? iconTint;

  final double radius;

  /// 图标方块底色
  Color get tileTint => iconTint ?? accent.withValues(alpha: 0.14);
}

/// 右上角「?」按钮。
Widget helpAction({
  required VoidCallback onPressed,
  required Color color,
  String tooltip = '说明',
}) {
  return IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    icon: Icon(Icons.help_outline_rounded, color: color, size: 22),
  );
}

/// 弹出说明弹窗。
///
/// 用 `AlertDialog` 而不是底部弹窗：说明是"查资料"，不是"做选择"，
/// 弹窗带遮罩更能让人专注读完。
Future<void> showHelpSheet(
  BuildContext context, {
  required String title,
  required List<HelpItem> items,
  required HelpPalette palette,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: palette.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(palette.radius + 4),
      ),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 16, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
      title: Row(
        children: [
          Icon(Icons.help_outline_rounded, size: 22, color: palette.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: items.length,
          separatorBuilder: (_, _) =>
              Divider(color: palette.border, height: 1, thickness: 0.5),
          itemBuilder: (c, i) {
            final it = items[i];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (it.icon != null) ...[
                    Container(
                      width: 30,
                      height: 30,
                      margin: const EdgeInsets.only(top: 1),
                      decoration: BoxDecoration(
                        color: palette.tileTint,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(it.icon, size: 17, color: palette.accent),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          it.title,
                          style: TextStyle(
                            color: palette.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            height: 1.3,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          it.body,
                          style: TextStyle(
                            color: palette.textSecondary,
                            fontSize: 12,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text('知道了', style: TextStyle(color: palette.accent)),
        ),
      ],
    ),
  );
}
