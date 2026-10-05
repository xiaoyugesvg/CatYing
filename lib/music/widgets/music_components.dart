import 'dart:async';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../models/models.dart';
import '../services/player_manager.dart';
import '../services/download_service.dart';
import '../theme/music_theme.dart';
import '../../common/theme.dart';
import '../../widgets/app_toast.dart';
import 'comment_sheet.dart';
import 'quick_actions.dart';
import '../pages/playlist_page.dart';

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
class CoverImage extends StatefulWidget {
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
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  /// 已重试次数。**最多 2 次**（合计最多 3 次请求）——
  /// 再多就说明服务器是真挂了，无限重试只会刷爆请求。
  ///
  /// 依据（实测，不是猜）：这些图床在本网络下**「连续第 2 个请求」会
  /// `ECONNRESET`** —— 我测了 4 个列表（网易云/酷狗的 newSongs 与 search），
  /// **无一例外**都是第 1 条 200、第 2 条 ECONNRESET。这不是随机抖动，
  /// 而是典型的**连接复用**（复用了服务端已关闭的 keep-alive 连接）。
  /// 换一条新连接通常就成功，所以多给两次机会。
  static const int _maxRetries = 2;
  int _attempts = 0;

  /// 与 Node 侧音乐源同款的浏览器 UA。
  ///
  /// 网易云/酷狗图床**对无 UA 的请求可能直接 403/拒载**（喜马拉雅已证实），
  /// `CachedNetworkImage` 默认不带 UA —— 必须显式带上，否则封面就是灰块。
  static const String _ua =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148';

  @override
  void didUpdateWidget(CoverImage old) {
    super.didUpdateWidget(old);
    // 列表滚动时 Element 会被复用但 url 换了：重试状态**必须一起重置**，
    // 否则"上一首重试过"会连累下一首（新歌直接显示占位、不再重试）。
    if (old.url != widget.url) _attempts = 0;
  }

  /// 失败后**退避重试**（400ms → 900ms）：留出时间让那条坏连接先被回收。
  void _scheduleRetry() {
    if (_attempts >= _maxRetries) return;
    _attempts++;
    final delay = Duration(milliseconds: _attempts == 1 ? 400 : 900);
    Future<void>.delayed(delay, () {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.circle ? widget.size / 2 : widget.cornerRadius;
    // 注：这里曾经有一段"把网易云 https 封面降级为 http"的规避代码，**已移除** ——
    // 那个改动是**基于相关性猜的**（"能出图的都是 http"），而真因另有其人：
    // `Playlist.fromJson` 以前只读 `coverUrl`，而 Node 发的是 `cover` →
    // 推荐歌单/歌单广场的封面**根本没有 URL**（不是协议问题）。真因已在模型层修掉。
    // 降级的副作用是"同一张图按 http/https 各存一份缓存"，去掉更好。
    final u = (widget.url ?? '').trim();
    Widget child;
    if (u.isEmpty) {
      child = _placeholder(radius);
    } else {
      // 重试时换一个缓存键：绕过"失败已被缓存记住"的情况
      final imageUrl = _attempts == 0
          ? u
          : (u.contains('?') ? '$u&_retry=$_attempts' : '$u?_retry=$_attempts');
      child = CachedNetworkImage(
        key: ValueKey<String>(imageUrl),
        imageUrl: imageUrl,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        // 图床对无 UA 的请求可能 403/拒载（网易、喜马拉雅都证实过）——
        // CachedNetworkImage 默认不带 UA，必须显式带上浏览器 UA。
        httpHeaders: const {'User-Agent': _ua},
        // 加载失败退回占位（不显示破图图标），并安排一次重试
        errorBuilder: (_, __, ___) {
          _scheduleRetry();
          return _placeholder(radius);
        },
        placeholder: (_, __) => _placeholder(radius),
        // 淡入让"图从无到有"不那么突兀（列表滚动时尤其明显）
        fadeInDuration: const Duration(milliseconds: 180),
        // 网易云的封面有多个尺寸后缀，缓存键用完整 URL 即可
        memCacheWidth:
            (widget.size * MediaQuery.devicePixelRatioOf(context))
                .round()
                .clamp(1, 2048),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(width: widget.size, height: widget.size, child: child),
    );
  }

  Widget _placeholder(double radius) => Container(
        width: widget.size,
        height: widget.size,
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
            size: widget.size * 0.45,
            color: Colors.white.withValues(alpha: 0.9)),
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
          fontSize: AppTheme.fontCaption,
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
          onTap: onTap ?? () => _defaultTap(context, player),
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
                        fontSize: AppTheme.fontSubhead,
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
                                fontSize: AppTheme.fontHeadline,
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
                            color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote),
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

  /// 点一行 → **只播放**（方案 C）。
  ///
  /// 反馈交给**悬浮播放球**（`MusicFloatingPlayButton`，挂在 app 级 Stack）：
  /// 它可拖动、点击进播放页 —— 所以列表点击**不再打断浏览**，
  /// 同时"点了没反馈"的问题也解决了（尤其在以前没有迷你播放器的 push 页面上）。
  void _defaultTap(BuildContext context, MusicPlayerManager player) {
    // 🔴 **把当前页面的 context 交给播放器** —— 内置接口拿不到地址时，
    // 它会弹「选音源」弹窗；弹窗必须挂在**用户当前这个 Navigator** 上，
    // 否则会弹到别的页面后面（用户以为"点了没反应"）。
    //
    // ⚠️ 这里是**最合适**的挂钩点：所有歌曲列表都用 `SongCell`，
    // 一处挂上就覆盖了绝大多数点歌路径，不必改 15 个调用方。
    player.attachContext(context);

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
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
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
                              fontSize: AppTheme.fontHeadline,
                              fontWeight: FontWeight.w600)),
                      Text(song.artists,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // 🔴 收藏：**菜单里原来根本没有这一项**，而音乐库的空态文案却写着
          // "在歌曲右侧菜单里可以收藏" → 用户按提示找不到入口 ✗
          // 现在补上，并复用共用动作（与迷你播放器快捷条、播放页红心同一套逻辑）。
          ListTile(
            leading:
                Icon(Icons.favorite_border_rounded, color: MusicTheme.tint),
            title: Text('收藏', style: TextStyle(color: MusicTheme.label)),
            onTap: () {
              Navigator.pop(ctx);
              musicToggleFavorite(song);
            },
          ),
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
                style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote)),
            onTap: () => Navigator.pop(ctx),
          ),
          ListTile(
            leading: Icon(Icons.playlist_add_rounded, color: MusicTheme.tint),
            title: Text('添加到歌单', style: TextStyle(color: MusicTheme.label)),
            onTap: () {
              Navigator.pop(ctx);
              showAddToPlaylistSheet(context, song);
            },
          ),
          ListTile(
            leading: Icon(Icons.queue_music_rounded, color: MusicTheme.tint),
            title: Text('我的歌单', style: TextStyle(color: MusicTheme.label)),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.of(context).push<void>(
                MaterialPageRoute(builder: (_) => const PlaylistListPage()),
              );
            },
          ),
          ListTile(
            leading: Icon(Icons.mode_comment_outlined, color: MusicTheme.tint),
            title: Text('评论', style: TextStyle(color: MusicTheme.label)),
            subtitle: song.source == SongSource.netease
                ? null
                : Text('${song.source.displayName}暂无评论接口',
                    style: TextStyle(
                        color: MusicTheme.secondary,
                        fontSize: AppTheme.fontFootnote)),
            onTap: () {
              Navigator.pop(ctx);
              // ⚠️ 既有 `MusicApi.comments()` 只走网易云（没有 source 参数）。
              // 对酷狗的歌必须挡住 —— 否则会拿酷狗的 id 去查网易云，必然空。
              if (song.source != SongSource.netease) {
                AppToast.show('${song.source.displayName}暂无评论接口', '');
                return;
              }
              showCommentSheet(context, song);
            },
          ),
          // 下载：入队到 App 沙盒（`Documents/music/`）。
          // 已下载/下载中的会被服务自动忽略；下载完播放会**本地优先**（离线可听）。
          ListTile(
            leading: Icon(Icons.download_rounded, color: MusicTheme.tint),
            title: Text('下载', style: TextStyle(color: MusicTheme.label)),
            onTap: () {
              Navigator.pop(ctx);
              MusicDownloadService.instance.enqueue(song);
              AppToast.show('已加入下载', song.name);
            },
          ),
          ListTile(
            leading: Icon(Icons.ios_share_rounded, color: MusicTheme.tint),
            title: Text('分享', style: TextStyle(color: MusicTheme.label)),
            onTap: () {
              Navigator.pop(ctx);
              unawaited(_shareSong(song));
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// 分享：把「歌名 - 歌手」复制到剪贴板并提示。
///
/// 与阅读模块「分享书源」的既有做法一致（复制到剪贴板 + toast）。
/// **没有引入 `share_plus`** 是有意的：那会新增一个 iOS 原生依赖
/// （要 pod install / 重编），而且我在这里无法验证其构建；
/// 剪贴板方案零依赖、零风险。以后若要系统分享面板再单独引。
Future<void> _shareSong(Song song) async {
  final text = '${song.name} - ${song.artists}';
  await Clipboard.setData(ClipboardData(text: text));
  AppToast.show('已复制，可直接粘贴分享', text);
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
    this.radius = 20,
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
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          const SizedBox(width: 8),
          Text(title,
              style: TextStyle(
                  color: MusicTheme.label,
                  fontSize: AppTheme.fontTitle3,
                  fontWeight: FontWeight.w700)),
          const Spacer(),
          if (action != null)
            GestureDetector(
              onTap: onAction,
              child: Row(
                children: [
                  Text(action!,
                      style:
                          TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontSubhead)),
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
              CoverImage(url: coverUrl, size: width, cornerRadius: 20),
              if (badge != null)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(badge!,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: AppTheme.fontCaption,
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
                  color: MusicTheme.label, fontSize: AppTheme.fontFootnote, height: 1.3)),
          if (subtitle != null)
            Text(subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontCaption)),
        ],
      ),
    );
  }
}
