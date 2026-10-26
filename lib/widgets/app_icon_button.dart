import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';

/// 顶栏圆形图标按钮 —— **全 App 统一的一种**。
///
/// ── 为什么抽出来（B 档：图标按钮统一）──────────────────────────
/// 之前同一个概念有 **4 份独立的私有实现**，分散在：
///   · `reading/pages/bookshelf_page.dart`
///   · `reading/pages/book_search_page.dart`
///   · `reading/pages/favorites_page.dart`
///   · `reading/pages/me_page.dart`
/// 全是 `_buildCircleIcon({isDark, icon, tooltip, onTap, ...})`，
/// 实现逐字雷同 —— 改一处不会影响其它三处。
///
/// 同时还有**另外两种风格**混在同一个顶栏里：
///   · `_buildBoltButton` —— 深色下白 92% 实心圆（比别的抢眼得多）
///   · `_buildSearchButton` —— 主题色 + `elevation: 4`
/// 于是"书架"一个顶栏里可能同时出现三种不同质感的圆按钮。
///
/// 现在统一到这一个：**淡圆底 + 单色图标**（水墨书香的调性），
/// 需要"更显眼"的用 [filled] 参数，而不是另写一份。
///
/// ── 为什么用 Material 而不是 Container ─────────────────────────
/// `Material` + `InkWell` 才有 iOS/Android 一致的**按压水波 + 涟漪裁剪**，
/// 而且 `clipBehavior: Clip.antiAlias` 能把水波裁在圆内。
class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.onLongPress,
    this.isDark = false,
    this.size = 36,
    this.iconSize = 20,

    /// true = 实心强调（深色下白底深图标，浅色下主题色底白图标）。
    /// 用于"导入/导出"这类需要被看见的入口。
    /// 默认 false = 淡圆底（白 10% / 黑 5%）。
    this.filled = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool isDark;
  final double size;
  final double iconSize;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    if (filled) {
      // 深色下用"近白实心 + 深图标"（与"推荐"标签同色系）；
      // 浅色下用主题色 + 白图标。
      bg = isDark
          ? Colors.white.withValues(alpha: 0.92)
          : Theme.of(context).colorScheme.primary;
      // ⚠️ 这里**不能**用跟随明暗的 `AppTheme.textPrimary`：该分支的底是
      // "近白实心圆"（深色档），深色下 textPrimary 取到的是近白 → 白上白。
      // 所以固定取"浅色档前景墨色"（原来是写死的 0xFF1C1C1E）。
      fg = isDark ? AppTheme.palette.textPrimaryLight : Colors.white;
    } else {
      bg = isDark
          ? Colors.white.withValues(alpha: 0.10)
          : Colors.black.withValues(alpha: 0.05);
      // 原来是写死的 0xFF1F1F1F（= ink 的 textPrimaryLight）。
      fg = isDark ? Colors.white : AppTheme.textPrimary;
    }

    return Material(
      color: bg,
      shape: const CircleBorder(),
      // 实心那种给一点阴影，淡圆底不给（避免四个按钮各带一圈灰边）
      elevation: filled ? 2 : 0,
      shadowColor: Colors.black.withValues(alpha: 0.25),
      clipBehavior: Clip.antiAlias,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: Icon(icon, size: iconSize, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}
