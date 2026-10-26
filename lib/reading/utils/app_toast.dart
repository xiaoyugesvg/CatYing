import 'package:flutter/material.dart';

import 'package:tvbox/widgets/app_toast.dart' as common;

/// 阅读侧的提示组件 —— **薄委托**到公共的 [common.AppToast]。
///
/// ── 为什么留这一层 ────────────────────────────────────────────
/// `AppToast` 在阅读模块有**大量调用点**（下载完成、保存失败、
/// 剪贴板提示等）。直接把类搬走会让所有调用点都要改 import。
///
/// 这里保留同名类作薄委托：调用点一行不用动，
/// 而真正的实现只有一份（`lib/widgets/app_toast.dart`），
/// 于是"影视/音乐/阅读三套提示各不相同"的根源被消掉了。
///
/// 依赖方向也理顺了：原来组件在 `reading/utils/`，
/// 影视/音乐要用就会形成"底层依赖阅读模块"；提到公共层后三个模块平级。
class AppToast {
  AppToast._();

  /// 在 App 顶层调用一次，注入 `MaterialApp` 的 navigatorKey。
  static void init(GlobalKey<NavigatorState> key) => common.AppToast.init(key);

  /// 显示一条顶部气泡。[title] 超长会被截断，[status] 始终完整显示。
  static void show(String title, String status, {bool isError = false}) =>
      common.AppToast.show(title, status, isError: isError);

  /// 只给一句话（影视/音乐那种一句话提示用）
  static void message(String text, {bool isError = false}) =>
      AppToast.message(text, isError: isError);

  static void success(String text) => common.AppToast.success(text);

  static void error(String text) => common.AppToast.error(text);
}
