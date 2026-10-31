import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/theme/music_theme.dart';

/// 「墨律」设计稿里**乐库 / 榜单 / 我的**三屏要用的组件（2026-10-31）。
///
/// ── 为什么不塞进 `mo_lv_blocks.dart` ───────────────────────────
/// 那个文件是「首页三件套」（hero / 方卡 / 编号列表），只吃 `List<Song>`；
/// 这里这几个吃的是**歌单、音源、开关项**，语义完全不同。混在一起会变成
/// 一个大杂烩，找起来反而慢。
///
/// 三屏对应设计稿：
///   · `02_乐库.png` —— 歌单**横滑方卡** + 最近播放**行列表**
///   · `03_榜单.png` —— 平台**胶囊行** + 编号榜单行
///   · `08_我的.png` —— 顶部**本地模式卡**
///
/// ⚠️ 颜色一律走 [MusicTheme]，不写死 —— 音乐模块有 10 套主题。

// ============================================================
// 横滑方卡（乐库「我的歌单」）
// ============================================================

/// 一张方卡要展示的东西（和具体数据源无关）。
class MoLvShelfItem {
  const MoLvShelfItem({
    required this.title,
    required this.subtitle,
    this.coverUrl,
    this.tint,
  });

  final String title;

  /// 卡片下方那行小字（设计稿是「24 首」）
  final String subtitle;

  final String? coverUrl;

  /// 没有封面时的渐变基色。不传就按位置轮换（棕 / 紫 / 绿 / 蓝）。
  final Color? tint;
}

/// 横滑方卡货架。
///
/// 尺寸对齐设计稿：卡宽 96、圆角 18、卡下两行文字、卡间距 14。
/// 卡宽固定而不是等分 —— 等分在「只有 1 张」时会拉成一整块大板子，
/// 和设计稿里"一小张一小张"的节奏完全不同。
class MoLvShelf extends StatelessWidget {
  const MoLvShelf({
    super.key,
    required this.items,
    this.onTap,
    this.width = 96,
  });

  final List<MoLvShelfItem> items;
  final void Function(int index)? onTap;
  final double width;

  /// 设计稿里方卡轮换的四种低饱和色
  static const List<Color> tints = [
    Color(0xFF8A6A46),
    Color(0xFF6C5A86),
    Color(0xFF4E7A63),
    Color(0xFF4A6B86),
  ];

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final dark = Theme.of(context).brightness == Brightness.dark;
    // ⚠️ 高度必须随字号伸缩，不能写死 `width + 44`：
    //    系统大字号（2.0×）下那两行文字会撑破固定高度 → 黄黑条。
    //    本项目在音乐底栏已经踩过一次同样的坑。
    final ts = MediaQuery.textScalerOf(context);
    final textH = ts.scale(12.5) * 1.35 + 2 + ts.scale(11) * 1.35;
    return SizedBox(
      height: width + 8 + textH + 2,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (c, i) {
          final it = items[i];
          final t = it.tint ?? tints[i % tints.length];
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onTap?.call(i),
            child: SizedBox(
              width: width,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: width,
                    height: width,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: dark
                                ? [
                                    t.withValues(alpha: 0.55),
                                    t.withValues(alpha: 0.14),
                                  ]
                                : [
                                    t.withValues(alpha: 0.34),
                                    t.withValues(alpha: 0.10),
                                  ],
                          ),
                          image: (it.coverUrl ?? '').isEmpty
                              ? null
                              : DecorationImage(
                                  image: NetworkImage(it.coverUrl!),
                                  fit: BoxFit.cover,
                                ),
                        ),
                        child: (it.coverUrl ?? '').isEmpty
                            ? Center(
                                child: Icon(
                                  Icons.queue_music_rounded,
                                  size: 26,
                                  color: Colors.white.withValues(alpha: 0.5),
                                ),
                              )
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    it.title,
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
                    it.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: MusicTheme.secondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ============================================================
// 行列表（乐库「最近播放」/「正在播放」/「我的收藏」）
// ============================================================

/// 单行：封面 + 歌名/歌手 + 右侧时长。
///
/// 和 `SongCell` 的差别：`SongCell` 带序号、带右侧「更多」菜单、行高更大，
/// 适合**详情页里的完整歌单**；这里是**首页概览**，一行只放最必要的信息，
/// 更紧凑（设计稿 02 的「最近播放」就是这种）。
class MoLvTrackRow extends StatelessWidget {
  const MoLvTrackRow({
    super.key,
    required this.song,
    this.onTap,
    this.trailing,
    this.active = false,
    this.accent,
  });

  final Song song;
  final VoidCallback? onTap;

  /// 覆盖右侧内容（默认显示时长）
  final Widget? trailing;

  /// 正在播放这一首（歌名走 accent + 显示跳动图标）
  final bool active;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final a = accent ?? MusicTheme.tint;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: SizedBox(
                width: 46,
                height: 46,
                child: (song.coverUrl ?? '').isEmpty
                    ? Container(
                        color: MusicTheme.fill,
                        child: Icon(Icons.music_note_rounded,
                            size: 20, color: MusicTheme.secondary),
                      )
                    : Image.network(
                        song.coverUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: MusicTheme.fill,
                          child: Icon(Icons.music_note_rounded,
                              size: 20, color: MusicTheme.secondary),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    song.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: active ? a : MusicTheme.label,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artists.trim().isEmpty ? '未知歌手' : song.artists,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: MusicTheme.secondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            trailing ??
                (active
                    ? Icon(Icons.graphic_eq_rounded, size: 16, color: a)
                    : Text(
                        formatDuration(song.duration),
                        style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: 11,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      )),
          ],
        ),
      ),
    );
  }
}

/// 一组行（自带左右不留白 —— 行自己带 padding）
class MoLvTrackList extends StatelessWidget {
  const MoLvTrackList({
    super.key,
    required this.songs,
    this.onTap,
    this.maxCount = 4,
    this.playingKey,
    this.accent,
  });

  final List<Song> songs;
  final void Function(int index)? onTap;
  final int maxCount;
  final String? playingKey;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final list = songs.take(maxCount).toList();
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (var i = 0; i < list.length; i++)
          MoLvTrackRow(
            song: list[i],
            accent: accent,
            active: playingKey != null && list[i].identityKey == playingKey,
            onTap: onTap == null ? null : () => onTap!(i),
          ),
      ],
    );
  }
}

/// 秒 → `m:ss`（0 / 负数 / NaN / 无穷 → `--:--`）
///
/// ⚠️ 必须先判 `isFinite`：`double.nan.round()` 会抛
/// `UnsupportedError`，而时长字段来自第三方接口，`nan` 是真会出现的。
String formatDuration(double sec) {
  if (!sec.isFinite || sec <= 0) return '--:--';
  final t = sec.round();
  if (t <= 0) return '--:--';
  return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
}

// ============================================================
// 胶囊（榜单页的平台 / 分类榜）
// ============================================================

/// 单个胶囊。选中态：accent 淡底 + accent 描边 + accent 文字。
class MoLvChip extends StatelessWidget {
  const MoLvChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final a = MusicTheme.tint;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? a.withValues(alpha: 0.13)
              : MusicTheme.label.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? a : MusicTheme.label.withValues(alpha: 0.08),
            width: selected ? 1 : 0.5,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? a : MusicTheme.secondary,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// 横滑胶囊行
class MoLvChipRow extends StatelessWidget {
  const MoLvChipRow({
    super.key,
    required this.labels,
    this.selectedIndex,
    this.onTap,
    this.padding = const EdgeInsets.fromLTRB(16, 2, 16, 2),
  });

  final List<String> labels;
  final int? selectedIndex;
  final void Function(int index)? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    if (labels.isEmpty) return const SizedBox.shrink();
    // 同上：胶囊高度跟着字号走，别写死 34
    final ts = MediaQuery.textScalerOf(context);
    return SizedBox(
      height: ts.scale(12) * 1.35 + 16,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding,
        itemCount: labels.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (c, i) => MoLvChip(
          label: labels[i],
          selected: selectedIndex == i,
          onTap: onTap == null ? null : () => onTap!(i),
        ),
      ),
    );
  }
}

// ============================================================
// 榜单行（编号 + 封面 + 歌名/歌手 + 时长）
// ============================================================

/// 榜单里的一行：`01` 编号（前三名 accent）+ 封面 + 歌名/歌手 + 时长。
///
/// 设计稿 03 右侧是「↑3 / ↓2」的排名升降箭头 —— **本 App 没有排名快照**，
/// 编不出来就不编（假数据比没有更糟），右侧仍然显示时长。
class MoLvRankRow extends StatelessWidget {
  const MoLvRankRow({
    super.key,
    required this.song,
    required this.index,
    this.onTap,
    this.active = false,
    this.accent,
  });

  final Song song;
  final int index;
  final VoidCallback? onTap;
  final bool active;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final a = accent ?? MusicTheme.tint;
    final no = (index + 1).toString().padLeft(2, '0');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: Text(
                no,
                style: TextStyle(
                  color: index < 3 ? a : MusicTheme.secondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 42,
                height: 42,
                child: (song.coverUrl ?? '').isEmpty
                    ? Container(
                        color: MusicTheme.fill,
                        child: Icon(Icons.music_note_rounded,
                            size: 18, color: MusicTheme.secondary),
                      )
                    : Image.network(
                        song.coverUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: MusicTheme.fill,
                          child: Icon(Icons.music_note_rounded,
                              size: 18, color: MusicTheme.secondary),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    song.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: active ? a : MusicTheme.label,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artists.trim().isEmpty ? '未知歌手' : song.artists,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: MusicTheme.secondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (active)
              Icon(Icons.graphic_eq_rounded, size: 16, color: a)
            else
              Text(
                formatDuration(song.duration),
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
}

// ============================================================
// 我的页：本地模式卡
// ============================================================

/// 顶部「本地模式」卡：圆形头像 + 标题 + 副标题 + 右箭头。
///
/// 设计稿 08 的这张卡说的是「不需要账号，收藏与歌单都存在本机」——
/// 正好是本项目的真实形态，所以照做；但它**不是**账号入口，
/// 点它跳到「本地音乐」比弹一个假登录框诚实。
class MoLvUserCard extends StatelessWidget {
  const MoLvUserCard({
    super.key,
    required this.title,
    required this.subtitle,
    this.badge = '猫',
    this.onTap,
  });

  final String title;
  final String subtitle;
  final String badge;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final a = MusicTheme.tint;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Material(
        color: MusicTheme.card,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: a.withValues(alpha: 0.16),
                    border: Border.all(color: a.withValues(alpha: 0.35)),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    badge,
                    style: TextStyle(
                      color: a,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 13),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: MusicTheme.label,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: 11.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded,
                    size: 20, color: MusicTheme.secondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
