import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/hiker/models/hiker_source.dart';
import 'package:tvbox/hiker/services/hiker_prefs.dart';
import 'package:tvbox/hiker/widgets/hiker_richtext.dart';

/// 海阔条目的网格卡片（主页 / 搜索页 / 收藏共用一套，避免三处各写一遍）
class HikerCard extends StatelessWidget {
  final HikerItem item;

  /// 是否显示简介行（跟随「海阔设置 → 显示简介」）
  final bool showDesc;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const HikerCard({
    super.key,
    required this.item,
    this.showDesc = true,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: double.infinity,
                color: AppTheme.backgroundTertiary,
                child: item.pic.isEmpty
                    ? Center(
                        child: Icon(Icons.movie_outlined,
                            size: 26, color: AppTheme.textTertiary))
                    : CachedNetworkImage(
                        imageUrl: item.pic,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Center(
                          child: Icon(Icons.broken_image_outlined,
                              size: 22, color: AppTheme.textTertiary),
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.title.isEmpty ? '(无标题)' : hikerPlainText(item.title),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontFootnote,
                height: 1.25),
          ),
          if (showDesc && item.desc.isNotEmpty)
            Text(
              hikerPlainText(item.desc),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: AppTheme.textTertiary, fontSize: AppTheme.fontCaption),
            ),
        ],
      ),
    );
  }
}

/// 海阔条目网格（列数 / 简介开关跟随「海阔设置」）
class HikerGrid extends StatelessWidget {
  final List<HikerItem> items;
  final void Function(HikerItem item)? onTap;
  final void Function(HikerItem item)? onLongPress;

  /// 底部额外留白（底栏是悬浮的，要给它让位）
  final double bottomPadding;

  const HikerGrid({
    super.key,
    required this.items,
    this.onTap,
    this.onLongPress,
    this.bottomPadding = 96,
  });

  @override
  Widget build(BuildContext context) {
    final cols = HikerPrefs.instance.columns;
    final showDesc = HikerPrefs.instance.showDesc;
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(16, 2, 16, bottomPadding),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        mainAxisSpacing: 12,
        crossAxisSpacing: 10,
        // 列数越多，卡片越窄 → 高宽比跟着调，保证图片比例稳定
        childAspectRatio: cols == 2 ? 0.72 : (cols == 3 ? 0.58 : 0.52),
      ),
      itemCount: items.length,
      itemBuilder: (_, i) => HikerCard(
        item: items[i],
        showDesc: showDesc,
        onTap: onTap == null ? null : () => onTap!(items[i]),
        onLongPress: onLongPress == null ? null : () => onLongPress!(items[i]),
      ),
    );
  }
}

/// 空/错误/加载 三态占位（主页与搜索页复用）
class HikerStateView extends StatelessWidget {
  final bool loading;
  final String? error;
  final String emptyText;
  final VoidCallback? onRetry;

  const HikerStateView({
    super.key,
    this.loading = false,
    this.error,
    this.emptyText = '没有内容',
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(
            strokeWidth: 2.4,
            valueColor: AlwaysStoppedAnimation(AppTheme.accentOnSurface),
          ),
        ),
      );
    }
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded, size: 34, color: AppTheme.textTertiary),
              const SizedBox(height: 10),
              Text(
                error!,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: AppTheme.fontSubhead,
                    height: 1.5),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 14),
                TextButton(
                  onPressed: onRetry,
                  child: Text('重试', style: TextStyle(color: AppTheme.accentOnSurface)),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Center(
      child: Text(emptyText,
          style: TextStyle(color: AppTheme.textTertiary, fontSize: AppTheme.fontSubhead)),
    );
  }
}

/// 海阔区块标题：左侧主题色竖条 + 加粗标题 + 可选计数徽标 / 右侧说明。
///
/// 用户 2026-10-29：「海阔的整体UI界面和详情页界面能不优化美化呢」——
/// 详情页原来所有小标题都是一模一样的裸文本（「简介」「解析结果」「标签」
/// 「本片剧照」…），层级全靠字号，扫读时抓不到结构。这里统一成一条竖条，
/// 主页 / 详情页 / 搜索页共用同一套观感。
class HikerSectionTitle extends StatelessWidget {
  const HikerSectionTitle(
    this.text, {
    super.key,
    this.count,
    this.trailing,
    this.padding = const EdgeInsets.only(bottom: 8),
  });

  final String text;

  /// 标题右侧的小徽标数字（如「解析结果」有几条）
  final int? count;

  /// 更次要的右侧文案（如当前分类名）
  final String? trailing;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Container(
            width: 3,
            height: 13,
            decoration: BoxDecoration(
              color: AppTheme.accentOnSurface,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: AppTheme.fontSubhead,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: AppTheme.accentSurface,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  color: AppTheme.accentOnSurface,
                  fontSize: AppTheme.fontCaption,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
            ),
          ],
          if (trailing != null) ...[
            const Spacer(),
            Text(
              trailing!,
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 小胶囊标签（来源 / 类型 / 标签词共用）
class HikerPill extends StatelessWidget {
  const HikerPill(
    this.text, {
    super.key,
    this.icon,
    this.accent = false,
    this.maxWidth,
  });

  final String text;
  final IconData? icon;

  /// 强调样式：淡主题色底 + 主题色文字（用于「当前线路」这类关键信息）
  final bool accent;

  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final fg = accent ? AppTheme.accentOnSurface : AppTheme.textSecondary;
    return Container(
      constraints: maxWidth == null
          ? null
          : BoxConstraints(maxWidth: maxWidth!),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: accent ? AppTheme.accentSurface : AppTheme.backgroundTertiary,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: accent ? Colors.transparent : AppTheme.borderLight,
          width: 0.6,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: fg),
            const SizedBox(width: 3),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: fg,
                fontSize: AppTheme.fontCaption,
                fontWeight: accent ? FontWeight.w600 : FontWeight.normal,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 海阔模块的方形 Logo（主页顶栏 / 引导页复用）
///
/// 图标用「海阔视界」App 启动图（assets/icons/hiker.png），与底栏 / 分类
/// 入口完全一致（见 [NavFeature.iconAsset]）。
class HikerLogo extends StatelessWidget {
  final double size;
  const HikerLogo({super.key, this.size = 34});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.34),
      child: Image.asset(
        'assets/icons/hiker.png',
        width: size,
        height: size,
        fit: BoxFit.contain,
      ),
    );
  }
}
