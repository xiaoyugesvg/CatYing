import 'package:flutter/material.dart';

import '../common/theme.dart';
import 'app_toast.dart';

/// 全 App **统一的提示语义层**。
///
/// ── 要解决的问题 ──────────────────────────────────────────────
/// 之前三个模块各显示各的：
///   · **影视**：`ScaffoldMessenger.showSnackBar`（56 处，底部黑条）
///   · **音乐**：`lastError` + SnackBar
///   · **阅读**：`AppToast`（顶部气泡）
///
/// 同一个 App 里"提示"有三种位置和三种长相，用户无法形成肌肉记忆。
///
/// ── 做法：语义统一 + 外观统一 ─────────────────────────────────
/// 1. **语义统一**：所有提示都经过这里的 [info] / [success] / [error] 三个入口，
///    "什么级别的消息用什么颜色/图标"只在这一处定义。
/// 2. **外观统一**：两种承载都做成同一种视觉：
///      · [AppNotice.toast] —— 顶部气泡（浮在所有路由之上，不依赖 Scaffold）
///      · [AppNotice.snack] —— 底部条（需要 Scaffold 上下文时用）
///    `AppTheme.lightTheme/darkTheme` 里已经给 `snackBarTheme` 配了
///    与气泡一致的圆角/底色/文字色，所以**现存 56 处 SnackBar 不改也自动统一了**。
///
/// ── 该用哪个 ──────────────────────────────────────────────────
///   · 有 `BuildContext` 且当前页有 Scaffold → `snack`（更贴近 iOS/Android 习惯）
///   · **没有 context**（如 Service/Controller 里）或**需要浮在 push 页面之上**
///     （下载完成时用户可能已在别的页面）→ `toast`
class AppNotice {
  AppNotice._();

  /// 中性信息
  static void info(BuildContext context, String text) =>
      _snack(context, text, _Kind.info);

  /// 成功
  static void success(BuildContext context, String text) =>
      _snack(context, text, _Kind.success);

  /// 失败 / 错误（红色）
  static void error(BuildContext context, String text) =>
      _snack(context, text, _Kind.error);

  // ── 无 context 时用这几个（内部走 AppToast 顶部气泡）──────────

  static void toastInfo(String text) => AppToast.message(text);

  static void toastSuccess(String text) => AppToast.success(text);

  static void toastError(String text) => AppToast.error(text);

  // ============================================================

  static void _snack(BuildContext context, String text, _Kind kind) {
    if (!context.mounted) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      // 没有 ScaffoldMessenger（罕见）→ 回落到气泡，保证提示不丢
      AppToast.message(text, isError: kind == _Kind.error);
      return;
    }
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            text,
            style: TextStyle(
              fontSize: AppTheme.fontBody,
              color: kind == _Kind.error
                  ? const Color(0xFFE57373)
                  : (isDark ? Colors.white : Colors.black87),
            ),
          ),
          // 三种语义只差**边框色**，底色/圆角/时长完全一致 ——
          // 与顶部气泡（AppToast）保持同一种视觉语言。
          backgroundColor: AppTheme.backgroundCard,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: kind == _Kind.error
                  ? Colors.red.withValues(alpha: 0.4)
                  : (isDark ? Colors.white : Colors.black)
                      .withValues(alpha: 0.06),
            ),
          ),
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          duration: const Duration(seconds: 2),
        ),
      );
  }
}

enum _Kind { info, success, error }
