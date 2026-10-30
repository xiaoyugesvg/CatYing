import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/widgets/app_splash_backdrop.dart';
import 'package:tvbox/widgets/circular_logo_progress.dart';

/// **唯一的启动画面**。
///
/// ── 为什么要有这个组件（用户 2026-10-30：「与加载页画同一画面，就不能去掉
///    一个吗？」）────────────────────────────────────────────────
/// 启动期其实有**两个挂载点**：
///   ① `main.dart` 的 `_BootSplash` —— 跑在 `runApp` 之后、服务注册**之前**，
///      这一帧不能碰 GetX（`Get.find` 会直接抛），所以只能是一个纯静态页；
///   ② `AppLoadingView` —— 服务就绪后，影视模块加载配置时显示。
/// 两个挂载点是 GetX 的时序决定的，**删不掉任何一个**（删 ① 就回到"先黑屏
/// 再出加载页"；删 ② 就没法在加载失败时给「重试 / 先进入应用」）。
///
/// 能删掉的是**重复的那份实现** —— 就是这里：背景（[AppSplashBackdrop]）、
/// 前景（[CircularLogoProgress]）、居中与安全区，以前在 `main.dart` 和
/// `app_loading_view.dart` 各写了一遍，改一处忘一处就会出现"两个 logo /
/// 颜色跳变"（这两次踩坑都是这么来的）。
///
/// 现在两处都只画这一个组件 ⇒ 想调启动画面只需要改这个文件。
class AppSplashView extends StatelessWidget {
  /// 中间的进度组件。null = 默认的「Logo + 不确定转圈、无文案」。
  ///
  /// `AppLoadingView` 传自己的（要跟随 `AppState.loadingPhase` 变化）。
  final Widget? progress;

  /// 进度下方的附加内容（加载失败/超时时的说明 + 按钮）。启动首帧不传。
  final Widget? footer;

  const AppSplashView({super.key, this.progress, this.footer});

  @override
  Widget build(BuildContext context) {
    return AppSplashBackdrop(
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              progress ??
                  const CircularLogoProgress(
                    progress: null,
                    percentText: '',
                    caption: '',
                    indeterminate: true,
                  ),
              if (footer != null) ...[
                const SizedBox(height: 28),
                footer!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 启动画面里那句「失败/慢」的说明文案（两处共用同一口径，别各写一句）。
class AppSplashHint extends StatelessWidget {
  const AppSplashHint({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: AppTheme.textSecondary,
          fontSize: AppTheme.fontSubhead,
          height: 1.5,
        ),
      ),
    );
  }
}
