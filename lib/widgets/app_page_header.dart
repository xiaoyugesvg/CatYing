import 'package:flutter/material.dart';

import '../common/theme.dart';
import '../reading/theme/jelly_theme.dart';

/// 页面顶栏的**大标题** —— 全 App 统一的一种写法。
///
/// ── 为什么抽这个（C 档：抽公共顶栏）────────────────────────────
/// 阅读模块有 8 个页面**各自手写顶栏**，A 档已经把它们的边距收进了
/// [AppTheme.headerSide] 等常量，但**标题本身的写法还是各写各的**：
///
///   search_page      : Text('漫画', style: TextStyle(fontSize: fontPageTitle,
///                        fontWeight: bold, color: isDark ? white : textPrimaryLight))
///   bookshelf_page   : 同上（'书架'）
///   favorites_page   : 同上（'收藏'）
///   book_search_page : 同上（'图书'）—— 但它后面跟的是 `SizedBox(width: 4)`
///   me_page          : 同上（'我的'）—— 但包了一层 `Padding(left: 4)`
///
/// 四处**逐字雷同**、另有两处轻微不一致。以后改标题字号/颜色要动 5 个文件。
///
/// ── 为什么不是"整个顶栏"组件 ─────────────────────────────────
/// 这 8 个页面的顶栏内部差异很大（有的要分段胶囊、有的要滑动图标组、
/// 有的要拉绳、有的要搜索框），强行抽成一个组件会变成
/// "参数比代码还长"。**风险最低、收益最大的切法**是抽**标题**这一个
/// 反复雷同的部分，各页保留自己的 children 编排。
///
/// ⚠️ 后续若要继续收口，可以在此之上做 `AppPageHeader`（含 Positioned
/// + Row + 间距），但那会动到 8 个页面的结构，建议单独一批做。
class AppPageTitle extends StatelessWidget {
  const AppPageTitle(
    this.text, {
    super.key,
    this.isDark,
    this.color,
  });

  final String text;

  /// 深色模式。不传则读当前 `Theme.of(context).brightness`。
  final bool? isDark;

  /// 显式指定颜色（如 `me_page` 用自己算的 `titleColor`）。
  /// 不传则用统一规格：深色下白 / 浅色下 `JellyTheme.textPrimaryLight`。
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final dark = isDark ?? Theme.of(context).brightness == Brightness.dark;
    return Text(
      text,
      style: TextStyle(
        fontSize: AppTheme.fontPageTitle,
        fontWeight: FontWeight.bold,
        color: color ?? (dark ? Colors.white : JellyTheme.textPrimaryLight),
      ),
    );
  }
}
