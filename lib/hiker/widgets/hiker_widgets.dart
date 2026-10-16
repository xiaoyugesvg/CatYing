import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../models/hiker_source.dart';
import '../services/hiker_prefs.dart';
import 'hiker_richtext.dart';

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

/// 海阔模块的方形 Logo（主页顶栏 / 引导页复用）
class HikerLogo extends StatelessWidget {
  final double size;
  const HikerLogo({super.key, this.size = 34});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppTheme.accentColor.withValues(alpha: 0.65),
            AppTheme.accentColor,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(size * 0.34),
      ),
      child: Icon(Icons.rocket_launch_rounded, color: Colors.white, size: size * 0.56),
    );
  }
}
