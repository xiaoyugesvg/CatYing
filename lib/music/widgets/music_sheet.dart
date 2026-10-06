import 'package:flutter/material.dart';

import '../theme/music_theme.dart';

/// 音乐模块统一"顶部下滑"弹窗。
///
/// 替代 `showModalBottomSheet`：不再从底部弹出，改为从顶部滑入
/// （用户需求：弹窗不要从下往上）。圆角翻到容器底部，内容高度受限，
/// 超出部分由内容自身滚动（`ListView` / `SingleChildScrollView`）处理。
///
/// - [isScrollControlled]：为 `true` 时允许更高（约 92% 屏高），
///   对应原来需要全高内容的弹层（评论、源选择等）。
Future<T?> showMusicSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  bool isScrollControlled = false,
}) {
  final maxHeight = MediaQuery.of(context).size.height *
      (isScrollControlled ? 0.92 : 0.75);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'close',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (ctx, _, __) => Align(
      alignment: Alignment.topCenter,
      child: SafeArea(
        bottom: false,
        child: Container(
          width: double.infinity,
          constraints: BoxConstraints(maxHeight: maxHeight),
          margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          decoration: BoxDecoration(
            color: backgroundColor ?? MusicTheme.card,
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(24),
            ),
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
    transitionBuilder: (ctx, anim, _, child) => SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, -1),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}
