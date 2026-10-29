import 'package:flutter/material.dart';
import 'package:tvbox/common/theme.dart';
import 'package:tvbox/widgets/glass.dart';

/// 通用加载组件
class AppLoading extends StatelessWidget {
  final String message;
  const AppLoading({super.key, this.message = '加载中...'});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: AppTheme.accentColor),
          const SizedBox(height: AppTheme.spacingMD),
          Text(
            message,
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontSubhead,
            ),
          ),
        ],
      ),
    );
  }
}

/// 通用错误组件
class AppError extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const AppError({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.spacingXXL),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 40,
              color: AppTheme.accentColor,
            ),
            const SizedBox(height: AppTheme.spacingLG),
            Text(
              message,
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontSubhead,
              ),
              textAlign: TextAlign.center,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: AppTheme.spacingLG),
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: AppTheme.accentColor.withValues(alpha: 0.2),
                  side: BorderSide(
                      color: AppTheme.accentColor.withValues(alpha: 0.4)),
                  shape: RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(AppTheme.radiusMD),
                  ),
                ),
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 可选择标签 - 对应 Swift SelectableChip
class SelectableChip extends StatelessWidget {
  final String title;
  final bool isSelected;
  final VoidCallback onTap;

  const SelectableChip({
    super.key,
    required this.title,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // ── 去掉描边（用户要求：不要"描边那一列"，直接用纯灰胶囊）────────
    //
    // 原来选中态是「强调色 14% 底 + 强调色 45% 描边 + 文字加粗」，
    // 未选中是「浅灰底 + 极淡白描边」——
    // 两者都带边框，选中那个在浅色下尤其像"被框起来的一列"。
    //
    // 现在：**两种状态都不画边框**，选中只靠底色深浅区分。
    // 这样一行的芯片看起来是同一套胶囊，只有当前项稍深。
    final light = AppBrightness.isLight.value;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 32,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: isSelected
              // 选中：比未选中深一档的灰（深色模式下用更高的白色透明度）
              ? (light
                  ? Colors.black.withValues(alpha: 0.10)
                  : Colors.white.withValues(alpha: 0.16))
              : (light
                  ? Colors.black.withValues(alpha: 0.045)
                  : Colors.white.withValues(alpha: 0.07)),
          borderRadius: BorderRadius.circular(20),
          // 不设 border —— 见上方注释
        ),
        child: Text(
          title,
          // 定宽单元格（首页筛选 / 分类屏蔽的 3~4 列网格）里必须单行省略，
          // 否则长分类名会折行把 32 高的胶囊撑破（黄黑条）。
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            // 选中不再用强调色（那会带色彩倾向，与黑白灰的水墨调不符），
            // 改用主文字色；未选中用次要文字色
            color: isSelected ? AppTheme.textPrimary : AppTheme.textSecondary,
            fontSize: AppTheme.fontSubhead,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

/// 空状态组件 - 对应 Swift EmptyStateView
class EmptyState extends StatelessWidget {
  final String title;
  final String? message;
  final IconData icon;

  const EmptyState({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.inbox_outlined,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      // ── 空态卡片也去掉液态玻璃 ──────────────────────────────────
      // 原来是 GlassPanel(tint: glassTintDeep + borderColor + highlight)，
      // 浅色下会在页面中央糊出一块发灰的玻璃块。
      // 与 AppCard 统一改成**实底 + 圆角**（水墨书香的做法）。
      child: Container(
        margin: const EdgeInsets.all(
            AppTheme.spacingXXL + AppTheme.spacingLG),
        decoration: BoxDecoration(
          color: AppTheme.backgroundSecondary,
          borderRadius: BorderRadius.circular(30),
        ),
        padding: const EdgeInsets.all(
            AppTheme.spacingXXL + AppTheme.spacingLG),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.accentColor.withValues(alpha: 0.15),
                border: Border.all(
                  color: AppTheme.accentColor.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: Icon(
                icon,
                size: 46,
                color: AppTheme.accentColor,
              ),
            ),
            const SizedBox(height: AppTheme.spacingSM + AppTheme.spacingMD),
            Text(
              title,
              style: TextStyle(
                color: AppTheme.textPrimary.withValues(alpha: 0.9),
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: AppTheme.spacingSM),
              Text(
                message!,
                style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontBody,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 分区标题组件 - 对应 Swift AppSectionHeader
class SectionHeader extends StatelessWidget {
  final String title;
  final IconData? icon;

  const SectionHeader({
    super.key,
    required this.title,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: AppTheme.textSecondary),
          const SizedBox(width: AppTheme.spacingSM),
        ],
        Text(
          title,
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontHeadline,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// 卡片容器 - 对应 Swift AppCard
/// iOS 27 Liquid Glass: 深色半透明玻璃底 + 顶部镜面高光 + 亮描边
/// 页面内低频卡片默认不开 blur (伪玻璃, 保性能); 需要真实毛玻璃时传 [blur] = true
class AppCard extends StatelessWidget {
  final Widget child;
  final double cornerRadius;
  final EdgeInsetsGeometry? padding;
  final bool blur;

  /// 紧凑模式：纵向内边距收到 4，配合更紧的 SettingsRow（行高 38）。
  ///
  /// 默认四周 16 的卡片里放一个设置行 = 行 40 + 卡片 32 = 72px 高，
  /// 列表看起来又高又空。设置类列表统一 dense，密度接近 iOS 设置页。
  final bool dense;

  /// 是否投影。
  ///
  /// 设置类列表**不开**（保持 iOS 设置页的扁平观感）；
  /// 首页/详情等需要"浮起来"的卡片可开，视觉层次更清楚。
  final bool shadow;

  const AppCard({
    super.key,
    required this.child,
    this.cornerRadius = AppTheme.glassRadiusCard,
    this.padding,
    this.blur = false,
    this.dense = false,
    this.shadow = false,
  });

  @override
  Widget build(BuildContext context) {
    // ── 改成**纯色卡片**（水墨书香风格）────────────────────────────
    //
    // 原来这里包的是 `GlassPanel`：
    //   tint: glassTintDeep（墨色 5~12% 透明，叠在页面上就发灰）
    //   borderColor + highlightStrength（玻璃高光与描边）
    //   blur（可选毛玻璃）
    // 结果是浅色模式下卡片灰、还带一圈高光 ——
    // 用户对比截图后明确要求"去掉 iOS27 液态玻璃样式，就按水墨书香来"。
    //
    // 现在改成**实底 + 圆角**，与阅读模块的卡片做法一致
    // （阅读那边等价于 `Material(color: cardLight, borderRadius: 16)`，
    //   没有任何玻璃层）：
    //   浅色 = 纯白卡片浮在宣纸米白底上
    //   深色 = #2A2A2C 卡片浮在墨夜底上
    // 靠"底色差"分层，而不是靠高光/描边 —— 这正是水墨书香的取向。
    //
    // 注：`blur` 参数保留但已不参与渲染（调用方仍可传，不必改签名）。
    final light = AppBrightness.isLight.value;
    final radius = BorderRadius.circular(cornerRadius);
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: radius,
        // 深色下卡片与底的对比本来就弱，留一条极淡描边避免糊在一起；
        // 浅色下不给 —— 白卡片在米白底上已经够分明，
        // 再加边框就又回到"玻璃描边"的观感了。
        border: light ? null : Border.all(color: AppTheme.borderLight, width: 0.8),
        boxShadow: shadow
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: light ? 0.05 : 0.22),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Padding(
          padding: padding ??
              (dense
                  ? const EdgeInsets.symmetric(
                      horizontal: AppTheme.spacingMD,
                      vertical: AppTheme.spacingXS)
                  : const EdgeInsets.all(AppTheme.spacingLG)),
          child: child,
        ),
      ),
    );
  }
}

/// 药丸标签 - 对应 Swift metadataPill
class MetadataPill extends StatelessWidget {
  final String text;

  const MetadataPill({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return GlassPill(
      text: text,
      color: AppTheme.textSecondary,
    );
  }
}

/// 设置行 - 对应 Swift SettingsRow
///
/// 统一样式（对齐参考图）：**图标放进强调色圆角容器**、标题 + 可选副标题、
/// 右侧「值 + 箭头」或开关。
///
/// 这一处升级会同时美化**所有**设置页 —— 之前各页自己实现 `_switchRow`，
/// 样式不一致且难维护，现在都收敛到这里。
class SettingsRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String value;
  final VoidCallback? onTap;
  final Color? iconColor;
  final Color? titleColor;

  /// 副标题（可选）：标题下方的小字说明，对应参考图两行样式
  final String? subtitle;

  /// 右侧开关（与 onTap 互斥优先显示开关）
  final bool trailingSwitch;
  final bool switchValue;
  final ValueChanged<bool>? onSwitchChanged;

  /// 开关是否可交互（false 时置灰，用于必需页面）
  final bool switchEnabled;

  /// 行尾自定义组件（可选）：渲染在 value/开关/箭头之后
  final Widget? trailing;

  const SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.value = '',
    this.onTap,
    this.iconColor,
    this.titleColor,
    this.subtitle,
    this.trailingSwitch = false,
    this.switchValue = false,
    this.onSwitchChanged,
    this.switchEnabled = true,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    // ⚠️ 兜底色用 accentOnSurface 而不是 accentColor：后者取调色板 primary，
    // 默认「水墨书香」是 #3A3A3A 墨灰 —— 暗色下"图标 + 它的淡底"整块看不见
    //（用户 2026-10-15：「晚上完全看不清」）。浅色下两者相同，观感不变。
    final accent = iconColor ?? AppTheme.accentOnSurface;
    // 行高最终 = 图标 36 + 纵向内边距 2×13 = 62，接近 iOS 设置页的呼吸感。
    // （之前是 32 + 2×8 = 48，一屏塞太多行，显得很挤。）
    final child = Padding(
      // 不能是 const：vertical 依赖 subtitle 是否存在
      padding: EdgeInsets.symmetric(
        horizontal: AppTheme.spacingMD,
        vertical: subtitle == null ? 14 : 10,
      ),
      child: Row(
        children: [
          // 图标容器：36×36 圆角 10 + 强调色 14% 底 + 细描边（参考图样式）
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
              border:
                  Border.all(color: accent.withValues(alpha: 0.22), width: 0.5),
            ),
            child: Icon(icon, size: 18, color: accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: titleColor ?? AppTheme.textPrimary,
                    fontSize: AppTheme.fontSubhead + 0.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (value.isNotEmpty)
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontSubhead,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          if (trailingSwitch) ...[
            const SizedBox(width: AppTheme.spacingSM),
            // 统一开关（见 AppSwitch 文档）
            AppSwitch(
              value: switchValue,
              onChanged: switchEnabled ? onSwitchChanged : null,
            ),
          ] else if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right,
              size: 17,
              color: AppTheme.textTertiary.withValues(alpha: 0.7),
            ),
          ],
          if (trailing != null) ...[
            const SizedBox(width: AppTheme.spacingSM),
            trailing!,
          ],
        ],
      ),
    );

    if (onTap != null) {
      // Liquid Glass 按压反馈（缩放 + 加深），替换 Material 水波纹
      return GlassPress(onTap: onTap, pressedScale: 0.985, child: child);
    }
    return child;
  }
}

/// 选择弹窗 - 对应 Swift SelectionModal
class SelectionModal<T> extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<T> items;
  final T? selectedItem;
  final String Function(T) itemTitle;
  final ValueChanged<T> onSelect;
  final VoidCallback onCancel;

  const SelectionModal({
    super.key,
    required this.title,
    required this.icon,
    required this.items,
    required this.selectedItem,
    required this.itemTitle,
    required this.onSelect,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      child: Center(
        child: GlassPanel(
          width: 360,
          radius: AppTheme.glassRadius,
          blur: true,
          tint: AppTheme.glassTintDeep,
          borderColor: AppTheme.glassBorder,
          borderWidth: 1,
          highlightStrength: 0.8,
          shadow: true,
          margin: const EdgeInsets.all(AppTheme.spacingXXL),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppTheme.spacingLG),
                child: Row(
                  children: [
                    Icon(icon, color: AppTheme.accentColor, size: 20),
                    const SizedBox(width: AppTheme.spacingSM),
                    Text(
                      title,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(Icons.close, color: AppTheme.textSecondary, size: 18),
                      onPressed: onCancel,
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: AppTheme.borderLight),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 400),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final isSelected = item == selectedItem;
                    return Material(
                      color: Colors.transparent,
                      child: ListTile(
                        title: Text(
                          itemTitle(item),
                          style: TextStyle(
                            color: isSelected ? AppTheme.accentColor : AppTheme.textPrimary,
                            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                        trailing: isSelected
                            ? Icon(Icons.check_circle, color: AppTheme.accentColor)
                            : null,
                        onTap: () => onSelect(item),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
// 键盘避让
// ============================================================

/// 底部安全内边距：**键盘弹起时等于键盘高度**，否则等于系统底部安全区。
///
/// ── 为什么需要它 ──────────────────────────────────────────────
/// `showModalBottomSheet(isScrollControlled: true)` 的 sheet 是**自己控制高度**的，
/// Flutter 不会替它避让键盘 —— 键盘是从屏幕底部滑上来的，直接盖在 sheet 上，
/// 于是"输入框被挡住、看不见自己打的字"。
///
/// 给 sheet 根节点加 `EdgeInsets.only(bottom: bottomSheetKeyboardInset(context))`
/// 即可让整块内容抬高到键盘之上。
///
/// 注意用 `viewInsets` 而不是 `viewPadding`：后者是刘海/Home 条这类**固定**遮挡，
/// 不会因键盘变化；前者才是键盘。
double bottomSheetKeyboardInset(BuildContext context) {
  final mq = MediaQuery.of(context);
  final keyboard = mq.viewInsets.bottom;
  // 键盘没有时返回 0：底部弹窗**贴到屏幕最底**（Home Indicator 安全区
  // 也覆盖），一屏显示更多内容 —— 用户要求"所有从下往上的弹窗延伸到底"。
  // 原实现退回 `mq.padding.bottom`（留 34px 给小白条），弹窗底部总露一截，
  // 用户实测后要求去掉。
  return keyboard > 0 ? keyboard : 0;
}

/// 把 [child] 包一层键盘避让（给 bottom sheet 用）。
///
/// [extraBottom] 用于在避让之外再加一点呼吸间距，默认 12。
Widget keyboardAwareSheet({
  Key? key,
  required BuildContext context,
  required Widget child,
  double extraBottom = 12,
  double extraTop = 0,
}) {
  return Padding(
    key: key,
    padding: EdgeInsets.only(
      bottom: bottomSheetKeyboardInset(context) + extraBottom,
      top: extraTop,
    ),
    child: child,
  );
}

/// 给 modal bottom sheet 的 builder 结果套键盘避让。
///
/// 用法：把 `showModalBottomSheet(context: c, builder: (ctx) => Foo())`
/// 改成 `builder: (ctx) => kbSheet(Foo())`。
///
/// ── 为什么在 builder 层做，而不是改每个 sheet 内部 ──────────────
/// 全项目 23 个 bottom sheet，根节点有 SafeArea / Container / ListView /
/// AlertDialog 各种写法，逐个改内部结构既费时又容易把布局改坏。
/// 统一在 builder 外面包一层 `Padding(bottom: 键盘高度)` 是**纯位移**：
///   · 不改尺寸 → 不触发 overflow
///   · 键盘收起时 bottom = 系统安全区 → 视觉无变化
///   · 键盘弹起时整体抬高 → 输入框不再被挡
Widget kbSheet(Widget child) => Builder(
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: bottomSheetKeyboardInset(ctx)),
        child: child,
      ),
    );

// ============================================================================
// 卡片式网格（弹层用）
//
// 用户 2026-10-15：「弹窗也太丑了，要卡片式的，一行 2-3 个这种」——
// 原来"切换网页 / 切换订阅源 / 导入菜单"这类弹层都是**一行一个**的 ListTile，
// 项一多就变成一条长长的列表，很占位置。这里统一成**等宽卡片网格**。
//
// 用法：
//   CardGrid(columns: 2, children: [
//     for (final x in list) CardGridItem(title: x.name, subtitle: x.url, ...),
//   ])
// ============================================================================

/// 等宽卡片网格：一行固定 [columns] 个，每格自动等宽（按可用宽度算）。
class CardGrid extends StatelessWidget {
  const CardGrid({
    super.key,
    required this.children,
    this.columns = 2,
    this.gap = 8,
  });

  final List<Widget> children;

  /// 一行几个（2 或 3）
  final int columns;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final n = columns < 1 ? 1 : columns;
        final w = (c.maxWidth - gap * (n - 1)) / n;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final ch in children) SizedBox(width: w, child: ch),
          ],
        );
      },
    );
  }
}

/// 网格里的一张卡片：图标块 + 标题 +（可选）副标题。
///
/// [selected] 只改**描边和图标底色**，卡片底色保持中性（与全项目一致）。
class CardGridItem extends StatelessWidget {
  const CardGridItem({
    super.key,
    this.icon,
    this.leading,
    required this.title,
    this.subtitle,
    this.selected = false,
    this.enabled = true,
    this.onTap,
    this.titleMaxLines = 1,
    this.subtitleMaxLines = 1,
    this.vertical = false,
  });

  final IconData? icon;

  /// 自定义左侧内容（不传 [icon] 时用，比如首字头像）
  final Widget? leading;
  final String title;
  final String? subtitle;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;
  final int titleMaxLines;
  final int subtitleMaxLines;

  /// 竖排（图标在上、标题在下）—— 一行 3 个这种窄格子用，横排会被挤成省略号。
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final accent = AppTheme.accentColor;
    final sub = (subtitle ?? '').trim();
    final iconBox = leading ??
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: 0.18)
                : accent.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon,
              size: 18, color: selected ? accent : AppTheme.textSecondary),
        );
    final titleText = Text(
      title,
      maxLines: titleMaxLines,
      overflow: TextOverflow.ellipsis,
      textAlign: vertical ? TextAlign.center : TextAlign.start,
      style: TextStyle(
        fontSize: AppTheme.fontSubhead,
        fontWeight: FontWeight.w600,
        color: enabled ? AppTheme.textPrimary : AppTheme.textTertiary,
      ),
    );
    final subText = sub.isEmpty
        ? null
        : Text(
            sub,
            maxLines: subtitleMaxLines,
            overflow: TextOverflow.ellipsis,
            textAlign: vertical ? TextAlign.center : TextAlign.start,
            style: TextStyle(
              fontSize: AppTheme.fontCaption,
              color: AppTheme.textTertiary,
            ),
          );

    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Material(
        color: AppTheme.backgroundSecondary,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: enabled ? onTap : null,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? accent : AppTheme.borderLight,
                width: selected ? 1.2 : 0.5,
              ),
            ),
            child: vertical
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      iconBox,
                      const SizedBox(height: 8),
                      titleText,
                      if (subText != null) ...[
                        const SizedBox(height: 2),
                        subText,
                      ],
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      iconBox,
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            titleText,
                            if (subText != null) ...[
                              const SizedBox(height: 2),
                              subText,
                            ],
                          ],
                        ),
                      ),
                      if (selected)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child:
                              Icon(Icons.check_circle, size: 16, color: accent),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// 弹层顶部把手（40×4），弹层统一用它，避免每处自己画一条粗细不一。
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: AppTheme.textTertiary.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(10),
        ),
      );
}

/// 卡片网格里的「首字头像」（源没有图标字段时用它，比灰方块好认）。
class CardGridAvatar extends StatelessWidget {
  const CardGridAvatar(this.name, {super.key, this.selected = false});

  final String name;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final accent = AppTheme.accentColor;
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: selected ? 0.18 : 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        name.isNotEmpty ? name.characters.first : '?',
        style: TextStyle(
          fontSize: AppTheme.fontSubhead,
          fontWeight: FontWeight.bold,
          color: accent,
        ),
      ),
    );
  }
}

/// 全局统一开关。
///
/// 用户 2026-10-29：「设置页面、订阅管理里面这些卡片，开关按钮的样式要一样」。
///
/// 在此之前同一个页面族里并存了 6 种写法 —— 缩放 0.85 / 0.9 / 不缩放、
/// `Switch` 与 `Switch.adaptive` 混用、有的设 `activeThumbColor` 有的不设，
/// 视觉上确实参差不齐。现在全部收敛到这一个组件：
///   · 统一 `Transform.scale(0.85)`（避免撑高行，与 [AppCard] 的
///     `trailingSwitch` 完全一致）；
///   · 统一 `activeThumbColor = AppTheme.accentColor`；
///   · 统一 `materialTapTargetSize.shrinkWrap`（去掉多余的点击留白）。
///
/// 新代码一律用它，不要再直接写 `Switch` / `Switch.adaptive`。
class AppSwitch extends StatelessWidget {
  const AppSwitch({
    super.key,
    required this.value,
    this.onChanged,
    this.scale = 0.85,
  });

  final bool value;

  /// null = 禁用（显示为灰）
  final ValueChanged<bool>? onChanged;

  /// 缩放。默认 0.85；个别「大开关」场景可传 1.0，但**不要**再传 0.9 之类的
  /// 第三种值 —— 那就是这次要消掉的参差。
  final double scale;

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: scale,
      child: Switch(
        value: value,
        onChanged: onChanged,
        activeThumbColor: AppTheme.accentColor,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}
