import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/player_manager.dart';
import '../theme/music_theme.dart';

/// 音乐模块的通用 UI 组件 —— 对应 Beans 的 `Components.swift` / `SongCell.swift`。
///
/// 这里统一封装封面、VIP 角标、歌曲行、玻璃卡片，
/// 避免各页面各写一套导致视觉不一致（Beans 也是这么收敛的）。

// ============================================================
// 封面
// ============================================================

/// 歌曲/歌单封面。取不到图时给一个带音符的渐变占位，
/// **不留空白格** —— Bean 的做法也是必给占位。
///
/// ── 用 CachedNetworkImage 而不是 Image.network（性能关键）────────
/// `Image.network` **只有内存缓存，没有磁盘缓存**：
///   · 退出页面 → 内存缓存被清 → 再进列表**所有封面重新下载**
///   · 音乐库/搜索列表滚动时反复重建 → 每次都发请求
/// 表现就是"滚动卡、流量还费"。封面图恰恰是最不该重复下载的东西
/// （同一首歌的封面永远是同一张）。
/// 项目里阅读模块早就在用 `cached_network_image`，这里统一过来。
class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    this.url,
    this.size = 46,
    this.cornerRadius = 10,
    this.circle = false,
  });

  final String? url;
  final double size;
  final double cornerRadius;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    final radius = circle ? size / 2 : cornerRadius;
    Widget child;
    final u = (url ?? '').trim();
    if (u.isEmpty) {
      child = _placeholder(radius);
    } else {
      child = CachedNetworkImage(
        imageUrl: u,
        width: size,
        height: size,
        fit: BoxFit.cover,
        // 加载失败也退回占位，而不是显示破图图标
        errorWidget: (_, __, ___) => _placeholder(radius),
        placeholder: (_, __) => _placeholder(radius),
        // 淡入让"图从无到有"不那么突兀（列表滚动时尤其明显）
        fadeInDuration: const Duration(milliseconds: 180),
        // 网易云的封面有多个尺寸后缀，缓存键用完整 URL 即可
        memCacheWidth: (size * MediaQuery.devicePixelRatioOf(context))
            .round()
            .clamp(1, 2048),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(width: size, height: size, child: child),
    );
  }

  Widget _placeholder(double radius) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              MusicTheme.tint.withValues(alpha: 0.75),
              MusicTheme.tint.withValues(alpha: 0.35),
            ],
          ),
        ),
        alignment: Alignment.center,
        child: Icon(Icons.music_note_rounded,
            size: size * 0.45, color: Colors.white.withValues(alpha: 0.9)),
      );
}

// ============================================================
// VIP 角标（Beans: 红色胶囊 + 白字 9pt）
// ============================================================

class VipBadge extends StatelessWidget {
  const VipBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: const Color(0xFFED4038),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Text(
        'VIP',
        style: TextStyle(
          color: Colors.white,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          height: 1.2,
        ),
      ),
    );
  }
}

// ============================================================
// 歌曲行（Beans SongCell）
// ============================================================

/// 歌曲列表行。
///
/// 视觉规格照搬 Beans `SongCell`：
///   · 封面 46 / 圆角 10
///   · 歌名 15pt；**播放中的那首用强调色 + 半粗**
///   · 歌手 12pt 次要色；歌手为空时退回显示专辑名
///   · VIP 曲目在歌名后跟红色胶囊角标
///   · 右侧三个点菜单（默认给「下一首播放 / 加入队列」）
class SongCell extends StatelessWidget {
  const SongCell({
    super.key,
    required this.song,
    this.showCover = true,
    this.playbackContext,
    this.onTap,
    this.trailing,
    this.index,
  });

  final Song song;
  final bool showCover;

  /// 点击时用整个列表作为播放队列（这样才有"下一首"）
  final List<Song>? playbackContext;
  final VoidCallback? onTap;

  /// 自定义右侧内容；不传则用内置的省略号菜单
  final Widget? trailing;

  /// 序号（榜单/专辑列表用）
  final int? index;

  @override
  Widget build(BuildContext context) {
    final player = MusicPlayerManager.instance;
    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final isCurrent = player.isCurrent(song);
        final titleColor = isCurrent ? MusicTheme.tint : MusicTheme.label;

        return InkWell(
          onTap: onTap ?? () => _defaultTap(player),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                if (index != null)
                  SizedBox(
                    width: 26,
                    child: Text(
                      '${index! + 1}',
                      style: TextStyle(
                        color: isCurrent
                            ? MusicTheme.tint
                            : MusicTheme.secondary,
                        fontSize: 13,
                        fontWeight:
                            isCurrent ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                if (showCover) ...[
                  CoverImage(url: song.coverUrl, size: 46, cornerRadius: 10),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              song.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: titleColor,
                                fontSize: 15,
                                fontWeight: isCurrent
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                          if (song.isVIP) ...[
                            const SizedBox(width: 6),
                            const VipBadge(),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        song.artists.isEmpty ? song.album : song.artists,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: MusicTheme.secondary, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (trailing != null) trailing! else _defaultTrailing(context, player),
              ],
            ),
          ),
        );
      },
    );
  }

  void _defaultTap(MusicPlayerManager player) {
    final ctx = playbackContext;
    if (ctx != null && ctx.isNotEmpty) {
      final i = ctx.indexWhere((s) => s.identityKey == song.identityKey);
      player.playQueue(ctx, index: i < 0 ? 0 : i);
    } else {
      player.playSong(song);
    }
  }

  Widget _defaultTrailing(BuildContext context, MusicPlayerManager player) {
    return IconButton(
      tooltip: '更多',
      icon: Icon(Icons.more_horiz, color: MusicTheme.secondary, size: 20),
      onPressed: () => showSongActions(context, song, playbackContext),
    );
  }
}

/// 歌曲操作菜单（Beans 的行内菜单含"下一首/加队列/收藏/下载"，
/// 账号相关的收藏/下载本项目不做）
Future<void> showSongActions(
  BuildContext context,
  Song song, [
  List<Song>? playbackContext,
]) {
  final player = MusicPlayerManager.instance;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: MusicTheme.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                CoverImage(url: song.coverUrl, size: 44, cornerRadius: 10),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(song.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: MusicTheme.label,
                              fontSize: 15,
                              fontWeight: FontWeight.w600)),
                      Text(song.artists,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: MusicTheme.secondary, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: Icon(Icons.playlist_play_rounded, color: MusicTheme.tint),
            title: Text('下一首播放', style: TextStyle(color: MusicTheme.label)),
            onTap: () {
              player.playNext(song);
              Navigator.pop(ctx);
            },
          ),
          ListTile(
            leading: Icon(Icons.queue_music_rounded, color: MusicTheme.tint),
            title: Text('加入播放队列', style: TextStyle(color: MusicTheme.label)),
            onTap: () {
              player.addToQueue(song);
              Navigator.pop(ctx);
            },
          ),
          ListTile(
            leading: Icon(Icons.person_outline_rounded, color: MusicTheme.tint),
            title: Text('查看歌手', style: TextStyle(color: MusicTheme.label)),
            subtitle: Text(song.artists,
                style: TextStyle(color: MusicTheme.secondary, fontSize: 12)),
            onTap: () => Navigator.pop(ctx),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

// ============================================================
// 玻璃卡片 / 分区标题
// ============================================================

/// 半透明玻璃卡片（Beans 的 `.glassRow` 风格）。
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.radius = 16,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: MusicTheme.glassFill,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: MusicTheme.label.withValues(alpha: 0.06),
          width: 0.5,
        ),
      ),
      child: child,
    );
    if (onTap == null) return content;
    return InkWell(
      borderRadius: BorderRadius.circular(radius),
      onTap: onTap,
      child: content,
    );
  }
}

/// 分区标题（Beans 各处 "推荐歌单 / 榜单 / 新歌" 的标题行）
class SectionTitle extends StatelessWidget {
  const SectionTitle({super.key, required this.title, this.action, this.onAction});

  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 15,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: MusicTheme.accentGradient),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(title,
              style: TextStyle(
                  color: MusicTheme.label,
                  fontSize: 17,
                  fontWeight: FontWeight.w700)),
          const Spacer(),
          if (action != null)
            GestureDetector(
              onTap: onAction,
              child: Row(
                children: [
                  Text(action!,
                      style:
                          TextStyle(color: MusicTheme.secondary, fontSize: 13)),
                  Icon(Icons.chevron_right,
                      size: 16, color: MusicTheme.secondary),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 横向卡片列表（推荐歌单 / 榜单用）
class HorizontalCards extends StatelessWidget {
  const HorizontalCards({
    super.key,
    required this.itemCount,
    required this.height,
    required this.itemBuilder,
    this.itemWidth = 120,
  });

  final int itemCount;
  final double height;
  final double itemWidth;
  final Widget Function(BuildContext, int) itemBuilder;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: itemCount,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (c, i) => SizedBox(width: itemWidth, child: itemBuilder(c, i)),
      ),
    );
  }
}

/// 网格封面卡（歌单/专辑）
class CoverCard extends StatelessWidget {
  const CoverCard({
    super.key,
    this.coverUrl,
    required this.title,
    this.subtitle,
    this.onTap,
    this.badge,
    this.width = 120,
  });

  final String? coverUrl;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final String? badge;
  final double width;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            children: [
              CoverImage(url: coverUrl, size: width, cornerRadius: 12),
              if (badge != null)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(badge!,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: MusicTheme.label, fontSize: 12, height: 1.3)),
          if (subtitle != null)
            Text(subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: MusicTheme.secondary, fontSize: 11)),
        ],
      ),
    );
  }
}
