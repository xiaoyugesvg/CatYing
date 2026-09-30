import 'package:flutter/material.dart';
import '../common/theme.dart';
import 'glass.dart';

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
          const CircularProgressIndicator(color: AppTheme.accentColor),
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
            const Icon(
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 32,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.accentColor.withValues(alpha: 0.14)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? AppTheme.accentColor.withValues(alpha: 0.45)
                : Colors.white.withValues(alpha: 0.06),
            width: isSelected ? 1 : 0.5,
          ),
        ),
        child: Text(
          title,
          style: TextStyle(
            color: isSelected ? AppTheme.accentColor : AppTheme.textSecondary,
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
      child: GlassPanel(
        margin: const EdgeInsets.all(
            AppTheme.spacingXXL + AppTheme.spacingLG),
        radius: 30,
        blur: false,
        tint: AppTheme.glassTintDeep,
        borderColor: AppTheme.glassBorderSoft,
        borderWidth: 0.8,
        highlightStrength: 0.5,
        shadow: false,
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
    return GlassPanel(
      radius: cornerRadius,
      blur: blur,
      tint: AppTheme.glassTintDeep,
      borderColor: AppTheme.glassBorderSoft,
      borderWidth: 0.8,
      highlightStrength: blur ? 0.8 : 0.5,
      shadow: shadow,
      padding: padding ??
          (dense
              ? const EdgeInsets.symmetric(
                  horizontal: AppTheme.spacingMD,
                  vertical: AppTheme.spacingXS)
              : const EdgeInsets.all(AppTheme.spacingLG)),
      child: child,
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
  });

  @override
  Widget build(BuildContext context) {
    final accent = iconColor ?? AppTheme.accentColor;
    final child = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacingXS,
        vertical: 8,
      ),
      child: Row(
        children: [
          // 图标容器：32×32 圆角 9 + 强调色 14% 底 + 细描边（参考图样式）
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(9),
              border:
                  Border.all(color: accent.withValues(alpha: 0.22), width: 0.5),
            ),
            child: Icon(icon, size: 17, color: accent),
          ),
          const SizedBox(width: 12),
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
            Transform.scale(
              scale: 0.85, // 开关略收，避免撑高行
              child: Switch(
                value: switchValue,
                onChanged: switchEnabled ? onSwitchChanged : null,
                activeColor: AppTheme.accentColor,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ] else if (onTap != null) ...[
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right,
              size: 17,
              color: AppTheme.textTertiary.withValues(alpha: 0.7),
            ),
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
                            ? const Icon(Icons.check_circle, color: AppTheme.accentColor)
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
