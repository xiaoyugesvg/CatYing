import 'package:flutter/material.dart';
import 'package:tvbox/common/theme.dart';

/// 通用空态视图（三模块共用）。
///
/// 结构统一：居中图标 + 标题 + 可选副标题。
/// 图标色默认取 `colorScheme.primary` 半透明；调用方也可传模块 token。
class AppEmptyView extends StatelessWidget {
  const AppEmptyView({
    super.key,
    required this.title,
    this.subtitle,
    this.icon = Icons.inbox_rounded,
    this.iconColor,
    this.iconSize = 56,
    this.action,
  });

  /// 主标题（如"还没有收藏的歌曲"）
  final String title;

  /// 可选副标题（说明文字）
  final String? subtitle;

  /// 空态图标
  final IconData icon;

  /// 图标颜色；null = `colorScheme.primary` 半透明
  final Color? iconColor;

  final double iconSize;

  /// 可选操作按钮（重试 / 导入 / 去添加等）
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = iconColor ?? scheme.primary.withValues(alpha: 0.5);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: iconSize, color: color),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  height: 1.5,
                  color: scheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
