import 'package:flutter/material.dart';

/// 通用整页加载态（三模块共用）。
///
/// 结构统一：居中转圈 + 可选说明文字。
/// 色值由调用方传各自模块的强调色 token
/// （影视 `AppTheme.accentColor` / 音乐 `MusicTheme.tint` / 阅读 `JellyTheme.primary`），
/// **不默认读 `colorScheme.primary`** —— 阅读页没有局部 ThemeData，
/// 全局 `colorScheme.primary` 是影视强调色，会让阅读页的加载转圈变成影视色。
class AppPageLoading extends StatelessWidget {
  const AppPageLoading({super.key, this.color, this.label});

  /// 转圈颜色；null = `Theme.of(context).colorScheme.primary`
  final Color? color;

  /// 可选说明文字（如"正在加载推荐…"）
  final String? label;

  @override
  Widget build(BuildContext context) {
    final primary = color ?? Theme.of(context).colorScheme.primary;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(strokeWidth: 3, color: primary),
          ),
          if (label != null) ...[
            const SizedBox(height: 12),
            Text(
              label!,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.6),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
