import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';

/// 启动期**背景**：不透明兜底底色 + 中心略亮的径向渐变。
///
/// ── 为什么单独抽成一个组件（2026-10-30）─────────────────────────
/// 「启动首帧」(`main.dart` 里的 `_BootSplash`) 和「正式加载页」
/// (`AppLoadingView`) **必须画一模一样的背景**，否则两帧之间整块底色会跳。
///
/// 上一版就是栽在这里：为了让用户别再看到"两个 logo"，把首帧的 logo 删了，
/// 只留一块写死的 `#1C1C1E` 纯色 —— 深色模式下那就是**一片黑**，
/// 而加载页是渐变 + logo。于是用户看到的是
/// 「一打开就是黑屏，然后才出加载页」。
///
/// 现在改成：首帧和加载页**用同一个背景组件 + 同一个 logo 组件**，
/// 颜色由 `AppTheme` 统一给出（明暗已在 `runApp` 之前同步预读好）。
/// 两处各写一份渐变迟早会改漏一处，所以这里做成唯一实现。
///
/// ⚠️ 内层 `ColoredBox` 不能省：`backgroundTertiary` 是**半透明**的
///   （alpha 0.06 / 0.10），渐变的中心那一档要靠它垫底才不会透出窗口黑底。
class AppSplashBackdrop extends StatelessWidget {
  const AppSplashBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppTheme.backgroundPrimary,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(0, -0.35),
            radius: 1.3,
            colors: [
              AppTheme.backgroundTertiary,
              AppTheme.backgroundSecondary,
              AppTheme.backgroundPrimary,
            ],
          ),
        ),
        child: child,
      ),
    );
  }
}
