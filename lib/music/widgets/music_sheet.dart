import 'package:flutter/material.dart';

import 'package:tvbox/music/theme/music_theme.dart';

/// 音乐模块统一"中间弹出"弹窗。
///
/// 替代 `showModalBottomSheet`：不从底部弹出，也不从顶部滑入，
/// 改为**屏幕中间弹出**（用户需求：所有弹窗中间弹出、显示约 4 行、
/// 内容多时内部滚动）。圆角四角，内容高度受限（约 30% 屏高 ≈ 4 行），
/// 超出部分由内容自身滚动（`ListView` / `SingleChildScrollView`）处理。
///
/// - [isScrollControlled]：保留参数以兼容旧调用方，不再放开高度——
///   统一按"4 行左右"上限约束；内容多由内部滚动兜底。
Future<T?> showMusicSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  bool isScrollControlled = false,
}) {
  // 约 30% 屏高 ≈ 4 行列表项高度（内容多时内部滚动）。
  final maxHeight =
      MediaQuery.of(context).size.height * (isScrollControlled ? 0.34 : 0.30);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'close',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, _, __) => Align(
      // 中间弹出：垂直水平都居中
      alignment: Alignment.center,
      child: Material(
        // showGeneralDialog 内容不提供 Material/DefaultTextStyle 上下文，
        // 里面 Text 会触发 Flutter「DefaultTextStyle 缺失」黄色调试线（双黄线）。
        // 包一层透明 Material 补齐（背景仍由下方 Container 绘制）。
        type: MaterialType.transparency,
        child: SafeArea(
          child: Container(
            width: double.infinity,
            constraints: BoxConstraints(maxHeight: maxHeight),
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: backgroundColor ?? MusicTheme.card,
              // 中间弹出：四角统一圆角
              borderRadius: BorderRadius.circular(24),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 24,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: builder(ctx),
          ),
        ),
      ),
    ),
    transitionBuilder: (ctx, anim, _, child) => FadeTransition(
      opacity: anim,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.92, end: 1).animate(
          CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
        ),
        child: child,
      ),
    ),
  );
}
