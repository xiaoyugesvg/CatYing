import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/theme/music_theme.dart';

/// 音乐首页「墨律」三件套（2026-10-31）。
///
/// ── 为什么单独抽出来 ──────────────────────────────────────────
/// 设计稿 `outputs/music_ui/01_首页.png` 的结构是三块：
///   ① 每日推荐 **hero 大卡**（徽标 + 大标题 + 副标题 + 圆形播放键）
///   ② 今日推荐 **3 张方卡**
///   ③ 榜单热歌 **01/02/03 编号列表**
///
/// 原来首页是「区块标题 + 横滑货架」一整套，推荐、网易、汽水、第三方插件
/// 各有各的拼法，改一次要动好几处。现在把三块做成**只吃数据、不管来源**的
/// 纯展示组件：QQ / 网易 / 酷狗 / 汽水 / 咪咕 / B站 / 第三方插件
/// 全都套同一套，视觉自然一致。
///
/// ⚠️ 颜色一律走 [MusicTheme] + 调用方传进来的 [accent]，
///    不写死琥珀色 —— 音乐模块有 10 套主题，写死会跟主题打架。

/// ① 每日推荐 hero 大卡
class MoLvHeroCard extends StatelessWidget {
  const MoLvHeroCard({
    super.key,
    required this.badge,
    required this.title,
    required this.subtitle,
    required this.accent,
    this.coverUrl,
    this.onPlay,
    this.onTap,
  });

  final String badge;
  final String title;
  final String subtitle;
  final Color accent;
  final String? coverUrl;
  final VoidCallback? onPlay;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // 渐变：左上角偏亮（accent 掺一点），右下角回到卡片色
    final base = dark ? const Color(0xFF1B1611) : const Color(0xFFF3EDE3);
    final glow = Color.alphaBlend(accent.withValues(alpha: dark ? 0.30 : 0.20), base);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap ?? onPlay,
          borderRadius: BorderRadius.circular(18),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [glow, base],
              ),
              border: Border.all(
                color: accent.withValues(alpha: 0.22),
                width: 1,
              ),
            ),
            child: SizedBox(
              height: 128,
              child: Stack(
                children: [
                  // 右下角的大圆：设计稿里那层"光晕"
                  Positioned(
                    right: -30,
                    bottom: -46,
                    child: Container(
                      width: 168,
                      height: 168,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            accent.withValues(alpha: 0.34),
                            accent.withValues(alpha: 0.0),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _badge(dark),
                              const SizedBox(height: 10),
                              Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: MusicTheme.label,
                                  fontSize: 19,
                                  height: 1.22,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.2,
                                ),
                              ),
                              const SizedBox(height: 7),
                              Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: MusicTheme.secondary,
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        _playButton(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _badge(bool dark) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: dark ? 0.22 : 0.16),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          badge,
          style: TextStyle(
            color: accent,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      );

  Widget _playButton() => Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: accent,
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: 0.36),
              blurRadius: 16,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Icon(
          Icons.play_arrow_rounded,
          size: 28,
          color: _onAccent(accent),
        ),
      );

  /// 圆键上的图标颜色：跟着 accent 的亮度走，深色底用白、浅色底用黑
  static Color _onAccent(Color c) =>
      c.computeLuminance() > 0.55 ? const Color(0xFF17130F) : Colors.white;
}

/// ② 今日推荐 · 3 张方卡
class MoLvRecGrid extends StatelessWidget {
  const MoLvRecGrid({
    super.key,
    required this.songs,
    required this.accent,
    this.onTap,
    this.maxCount = 3,
  });

  final List<Song> songs;
  final Color accent;
  final void Function(int index)? onTap;
  final int maxCount;

  @override
  Widget build(BuildContext context) {
    final list = songs.take(maxCount).toList();
    if (list.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < list.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            Expanded(child: _cell(context, list[i], i)),
          ],
          // 不足 3 张时补空位，避免两张卡拉满整行显得突兀
          for (var i = list.length; i < maxCount; i++) ...[
            const SizedBox(width: 10),
            const Expanded(child: SizedBox.shrink()),
          ],
        ],
      ),
    );
  }

  Widget _cell(BuildContext context, Song s, int i) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // 每张卡给不同的低饱和渐变（设计稿里是棕 / 紫 / 绿 / 蓝轮着来）
    const tints = [
      Color(0xFF8A6A46),
      Color(0xFF6C5A86),
      Color(0xFF4E7A63),
      Color(0xFF4A6B86),
    ];
    final t = tints[i % tints.length];
    return GestureDetector(
      onTap: () => onTap?.call(i),
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: dark
                      ? [t.withValues(alpha: 0.55), t.withValues(alpha: 0.16)]
                      : [t.withValues(alpha: 0.34), t.withValues(alpha: 0.12)],
                ),
                image: (s.coverUrl ?? '').isEmpty
                    ? null
                    : DecorationImage(
                        image: NetworkImage(s.coverUrl!),
                        fit: BoxFit.cover,
                        colorFilter: dark
                            ? const ColorFilter.mode(
                                Color(0x33000000), BlendMode.darken)
                            : null,
                      ),
              ),
              child: (s.coverUrl ?? '').isEmpty
                  ? Center(
                      child: Icon(
                        Icons.music_note_rounded,
                        size: 26,
                        color: Colors.white.withValues(alpha: 0.55),
                      ),
                    )
                  : null,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            s.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: MusicTheme.label,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            s.artists.isEmpty ? '未知歌手' : s.artists,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: MusicTheme.secondary, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

/// ③ 榜单热歌 · 01/02/03 编号列表
class MoLvChartList extends StatelessWidget {
  const MoLvChartList({
    super.key,
    required this.songs,
    required this.accent,
    this.playingKey,
    this.isPlaying = false,
    this.onTap,
    this.maxCount = 5,
  });

  final List<Song> songs;
  final Color accent;
  final String? playingKey;
  final bool isPlaying;
  final void Function(int index)? onTap;
  final int maxCount;

  @override
  Widget build(BuildContext context) {
    final list = songs.take(maxCount).toList();
    if (list.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
      child: Column(
        children: [
          for (var i = 0; i < list.length; i++) _row(context, list[i], i),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, Song s, int i) {
    final active = playingKey != null && s.identityKey == playingKey;
    final no = (i + 1).toString().padLeft(2, '0');
    return InkWell(
      onTap: () => onTap?.call(i),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: Text(
                no,
                style: TextStyle(
                  color: i < 3 ? accent : MusicTheme.secondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 40,
                height: 40,
                child: (s.coverUrl ?? '').isEmpty
                    ? Container(
                        color: MusicTheme.fill,
                        child: Icon(Icons.music_note_rounded,
                            size: 18, color: MusicTheme.secondary),
                      )
                    : Image.network(s.coverUrl!, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                              color: MusicTheme.fill,
                              child: Icon(Icons.music_note_rounded,
                                  size: 18, color: MusicTheme.secondary),
                            )),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: active ? accent : MusicTheme.label,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    s.artists.isEmpty ? '未知歌手' : s.artists,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: MusicTheme.secondary, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (active && isPlaying)
              Icon(Icons.graphic_eq_rounded, size: 16, color: accent)
            else
              Text(
                _dur(s.duration),
                style: TextStyle(
                  color: MusicTheme.secondary,
                  fontSize: 11,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _dur(double sec) {
    final t = sec.round();
    if (t <= 0) return '--:--';
    final m = t ~/ 60;
    final r = t % 60;
    return '$m:${r.toString().padLeft(2, '0')}';
  }
}

/// 区块标题（「今日推荐 · 全部 ›」这种）
///
/// 和 `MeiSectionHeader` 的差别：这个没有底部 padding、字号略小，
/// 专门给「墨律」那三块用，避免和 Mei 那套的间距打架。
class MoLvSectionTitle extends StatelessWidget {
  const MoLvSectionTitle({
    super.key,
    required this.title,
    this.trailing,
    this.onMore,
  });

  final String title;
  final String? trailing;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              color: MusicTheme.label,
              fontSize: AppTheme.fontSubhead,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Text(
              trailing!,
              style: TextStyle(color: MusicTheme.secondary, fontSize: 11),
            ),
          ],
          const Spacer(),
          if (onMore != null)
            GestureDetector(
              onTap: onMore,
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  Text('全部',
                      style: TextStyle(
                          color: MusicTheme.secondary, fontSize: 11.5)),
                  Icon(Icons.chevron_right_rounded,
                      size: 16, color: MusicTheme.secondary),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
