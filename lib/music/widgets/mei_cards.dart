import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/music/widgets/music_components.dart' show CoverImage;

/// **Mei 风格发现页组件集** —— 严格对齐 `ljyh223/Mei` 的 Compose 实现。
///
/// ── 为什么单独开一个文件 ────────────────────────────────────────
/// 用户 2026-10-30：「推荐、网易这些分页整个要重构，严格按照刚才这个仓库的
/// 界面来」。Mei 的发现页是这套规格（源码 `ui/component/card/ArtworkCard.kt`
/// + `ui/component/MeiSectionTitle.kt` + `ui/component/MeiFilterPill.kt`）：
///
/// | 元素 | Mei 规格 | 本文件 |
/// |---|---|---|
/// | 区块标题 | `headlineSmall` + Bold，右跟「全部 ›」 | [MeiSectionHeader] |
/// | 筛选胶囊 | 圆形，视觉高 32、触摸区 48，13sp | [MeiFilterPill] |
/// | 作品卡 | 封面 **1:1** + 16 圆角 + 8 间距 + 标题 14w500 | [MeiArtworkCard] |
/// | 歌单卡 | 作品卡 + 右上角「耳机 12 + 播放量 11w700」 | [MeiPlaylistCard] |
/// | 榜单行 | 80 封面(14 圆角) + 榜名 + 更新频率 + 前 3 首 | [MeiChartRow] |
///
/// 旧的 `discover_sections.dart`（Beans 规格：108 封面 / 竖排榜单卡 / 2 列网格）
/// **保留不动** —— 听书那几个页还在用它，只有音乐发现页换成这一套。

/// 区块标题 + 右侧「全部 ›」。
///
/// Mei 的 `MeiSectionTitle` 用 `headlineSmall`（24sp）+ Bold。本项目字号体系里
/// 对应 `AppTheme.fontTitle2`(20) —— 24 在 375dp 宽屏上会把「探索歌单」四个字
/// 挤到和「全部」贴边，20 是这套字阶里最接近的档位（见 `theme.dart` 里
/// fontTitle2 的注释：刻意保留了"比正文大两档"的层级）。
class MeiSectionHeader extends StatelessWidget {
  const MeiSectionHeader({
    super.key,
    required this.title,
    this.onShowAll,
    this.showAllLabel = '全部',
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  final String title;
  final VoidCallback? onShowAll;
  final String showAllLabel;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: MusicTheme.label,
                fontSize: AppTheme.fontTitle2,
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
            ),
          ),
          if (onShowAll != null)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onShowAll,
              child: Padding(
                // 触摸区左右各补 8：文字本身太窄，直接点「全部」两个字很容易脱靶
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      showAllLabel,
                      style: TextStyle(
                        color: MusicTheme.secondary,
                        fontSize: AppTheme.fontSubhead,
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded,
                        size: 18, color: MusicTheme.secondary),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 筛选胶囊（分类 / 排序）。
///
/// Mei 的 `MeiFilterPill`：`CircleShape` + 视觉最小高 32 + 触摸区最小 48 +
/// 13sp 文字；选中用 `secondaryContainer`，未选用 `surfaceContainerLow`。
/// 这里映射到 MusicTheme：
///   · 选中 → 主题色实心 + 白字
///   · 未选 → `MusicTheme.fill` + 次要文字色
class MeiFilterPill extends StatelessWidget {
  const MeiFilterPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.accent,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// 选中态主色；不传就用 `MusicTheme.tint`
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final on = accent ?? MusicTheme.tint;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      // 触摸区 48 高（Mei 的 `sizeIn(minHeight = 48.dp)`），视觉胶囊 32 高
      child: SizedBox(
        height: 48,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            constraints: const BoxConstraints(minHeight: 32),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: selected ? on : MusicTheme.fill,
              borderRadius: BorderRadius.circular(999),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? Colors.white : MusicTheme.secondary,
                fontSize: AppTheme.fontSubhead,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                height: 1.35,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 作品卡（歌单 / 专辑 / 榜单封面）。
///
/// 严格照 Mei 的 `ArtworkCard`：
///   · 封面 **1:1**，`RoundedCornerShape(16.dp)`（**只裁图，不裁整卡**）
///   · 图下 8dp 间距
///   · 标题 `bodyMedium` + w500，单行省略
///   · 副标题 `bodySmall` + `onSurfaceVariant`，顶部再 2dp
///
/// [badge] 画在封面内部（Mei 的 `coverContent` 插槽），用来放播放量。
class MeiArtworkCard extends StatelessWidget {
  const MeiArtworkCard({
    super.key,
    required this.coverUrl,
    required this.title,
    required this.width,
    this.subtitle,
    this.onTap,
    this.badge,
    this.cornerRadius = 16,
    this.reserveSubtitleSpace = false,
  });

  final String? coverUrl;
  final String title;
  final double width;
  final String? subtitle;
  final VoidCallback? onTap;

  /// 封面内右下/右上的角标（Mei 的 `coverContent`）
  final Widget? badge;
  final double cornerRadius;

  /// 副标题为空时是否仍占一行（Mei 的 `reserveSubtitleSpace`，避免整排卡片高度跳动）
  final bool reserveSubtitleSpace;

  @override
  Widget build(BuildContext context) {
    final sub = (subtitle ?? '').trim();
    final showSub = reserveSubtitleSpace || sub.isNotEmpty;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(cornerRadius),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CoverImage(url: coverUrl ?? '', fill: true, cornerRadius: cornerRadius),
                    if (badge != null) badge!,
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: MusicTheme.label,
                fontSize: AppTheme.fontBody,
                fontWeight: FontWeight.w500,
                height: 1.3,
              ),
            ),
            if (showSub)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: MusicTheme.secondary,
                    fontSize: AppTheme.fontCaption + 1,
                    height: 1.3,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 歌单卡 = [MeiArtworkCard] + 右上角播放量角标。
///
/// 角标规格照 `PlaylistCard.kt`：`Icon(Headset, 12)` + 2dp 间距 + 11sp w700
/// 白字，带黑色投影（封面浅色时也能看清），整体 padding 6。
class MeiPlaylistCard extends StatelessWidget {
  const MeiPlaylistCard({
    super.key,
    required this.playlist,
    required this.width,
    this.onTap,
    this.subtitle,
  });

  final Playlist playlist;
  final double width;
  final VoidCallback? onTap;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final count = playlist.trackCount;
    return MeiArtworkCard(
      coverUrl: playlist.coverUrl,
      title: playlist.name,
      width: width,
      subtitle: subtitle ??
          (count > 0 ? formatPlayCount(count) : null),
      onTap: onTap,
      badge: count > 0 ? MeiPlayCountBadge(count: count) : null,
    );
  }
}

/// 播放量角标（耳机图标 + 数字）。
class MeiPlayCountBadge extends StatelessWidget {
  const MeiPlayCountBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 6,
      top: 6,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.headset_rounded, size: 12, color: Colors.white),
          const SizedBox(width: 2),
          Text(
            formatPlayCount(count),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              shadows: [
                Shadow(
                  color: Color(0xB3000000),
                  offset: Offset(2, 2),
                  blurRadius: 4,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 榜单行卡（Mei 的 `DiscoverChartRow`）。
///
/// 80 封面（14 圆角）+ 榜名（titleSmall 单行）+ 更新频率（labelSmall）+
/// 前 3 首歌名（bodySmall，`序号 + 空格 + 歌名`）。
class MeiChartRow extends StatelessWidget {
  const MeiChartRow({
    super.key,
    required this.coverUrl,
    required this.name,
    this.updateFrequency = '',
    this.tracks = const [],
    this.onTap,
    this.maxTracks = 3,
  });

  final String? coverUrl;
  final String name;
  final String updateFrequency;
  final List<String> tracks;
  final VoidCallback? onTap;
  final int maxTracks;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 80,
              height: 80,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: CoverImage(url: coverUrl ?? '', fill: true, cornerRadius: 14),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: MusicTheme.label,
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (updateFrequency.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        updateFrequency,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontCaption,
                        ),
                      ),
                    ),
                  for (var i = 0;
                      i < tracks.length && i < maxTracks;
                      i++)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        '${i + 1}  ${tracks[i]}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontCaption + 1,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 播放量格式化 —— 与 Mei 的 `formatDiscoverPlayCount` 一致：
/// ≥1 亿 → `x.x亿`，≥1 万 → `x.x万`，其余原样。
String formatPlayCount(int count) {
  if (count >= 100000000) {
    return '${(count / 100000000).toStringAsFixed(1)}亿';
  }
  if (count >= 10000) {
    return '${(count / 10000).toStringAsFixed(1)}万';
  }
  return count <= 0 ? '0' : '$count';
}
