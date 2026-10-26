import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';

/// 长按菜单里的一项（**名称尽量 2 个字**，卡片式，一行两个）。
class CardAction {
  final IconData icon;
  final String label;
  final bool danger;

  /// 面板关闭后执行（调用方不用自己 pop）
  final VoidCallback onTap;

  const CardAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });
}

/// 通用「长按操作」面板 —— **一排 2 张卡片**。
///
/// 影视 / 程序 / 海阔 / 直播 / RSS 的源切换与列表共用同一套版式：
///   · 顶部：标题（源名）+ 可选副标题
///   · 中间：2 列卡片（图标 + 2 字名称），危险项红色
///   · 点卡片 → 先关面板，再执行对应动作
Future<void> showCardActions(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<CardAction> actions,
}) async {
  if (actions.isEmpty) return;
  final index = await showModalBottomSheet<int>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) => DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border.all(color: AppTheme.borderLight, width: 0.5),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if ((subtitle ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle!.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                mainAxisExtent: 58,
              ),
              itemCount: actions.length,
              itemBuilder: (_, i) {
                final a = actions[i];
                return _ActionCard(
                  action: a,
                  onTap: () => Navigator.of(ctx).pop(i),
                );
              },
            ),
          ],
        ),
      ),
    ),
  );
  if (index == null || index < 0 || index >= actions.length) return;
  actions[index].onTap();
}

class _ActionCard extends StatelessWidget {
  final CardAction action;
  final VoidCallback onTap;

  const _ActionCard({required this.action, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final fg = action.danger ? Colors.redAccent : AppTheme.textPrimary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: action.danger
              ? Colors.redAccent.withValues(alpha: 0.08)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: action.danger
                ? Colors.redAccent.withValues(alpha: 0.3)
                : AppTheme.borderLight,
            width: 0.6,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              action.icon,
              size: 18,
              color: action.danger ? Colors.redAccent : AppTheme.textSecondary,
            ),
            const SizedBox(width: 8),
            Text(
              action.label,
              style: TextStyle(
                color: fg,
                fontSize: AppTheme.fontSubhead,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 卡片右上角的拖动把手：**长按把手拖动排序**（长按卡片本身 = 打开菜单）。
///
/// 与阅读模块书源仓同一套交互（用户 2026-10-18 认可）：长按整卡与拖动冲突，
/// 所以排序统一走把手，菜单仍留给整卡长按。
class CardDragHandle extends StatelessWidget {
  final Object data;

  /// 拖动时跟随手指的小卡片文案
  final String label;

  final Color? background;
  final Color? foreground;

  /// 把手图标颜色（彩色卡片上传白色，默认次级文字色）
  final Color? iconColor;

  const CardDragHandle({
    super.key,
    required this.data,
    required this.label,
    this.background,
    this.foreground,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final bg = background ?? AppTheme.backgroundSecondary;
    final fg = foreground ?? AppTheme.textPrimary;
    return LongPressDraggable<Object>(
      data: data,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: AppTheme.fontSubhead,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(
          Icons.drag_indicator_rounded,
          size: 15,
          color: iconColor ?? AppTheme.textTertiary,
        ),
      ),
    );
  }
}
