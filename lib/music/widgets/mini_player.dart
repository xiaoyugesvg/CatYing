import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/music_api.dart';
import '../services/player_manager.dart';
import '../theme/music_theme.dart';
import '../widgets/music_components.dart';
import '../pages/player_page.dart';
import '../../common/theme.dart';

/// 迷你播放器的布局常量（#8）。
///
/// 抽成常量是为了让"它和导航栏的间距关系"有个明确的名字 ——
/// 之前是裸的 `6`，看代码看不出来它到底是"和导航栏的间距"
/// 还是"给 Home 指示条留的位置"（后者应该由导航栏的 SafeArea 负责）。
class MusicMiniPlayerLayout {
  MusicMiniPlayerLayout._();

  /// 迷你播放器与悬浮导航栏之间的间距
  static const double gapAboveNavBar = 6;

  /// 左右外边距（与导航栏的 sideMargin 视觉对齐）
  static const double sideMargin = 10;
}

/// 底部迷你播放器 —— 移植自 Beans 的 `MiniPlayerView.swift`（dock 形态）。
///
/// 视觉规格照搬：
///   · 封面 36 / 圆角 7，后面一层 42×42 的强调色光晕（blur 9）
///   · 容器圆角 18，左右内边距，高度紧凑
///   · 左侧封面 + 歌名/歌手（或当前歌词），右侧播放/暂停 + 下一首
///
/// 点整条打开全屏播放器。没有正在播放的歌曲时**整条隐藏**（不占位）。
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final player = MusicPlayerManager.instance;
    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final song = player.currentSong;
        if (song == null) return const SizedBox.shrink();

        return Padding(
          // #8：这里是迷你播放器与**下方悬浮导航栏**之间的间距。
          //
          // 说明清楚：`RootView` 里两者是**同一个 Column 的兄弟**，
          // 顺序是 `[MiniPlayer, _navBar()]`，`Column` 整体
          // `Positioned(bottom: 0)` —— 所以**结构上不可能重叠**，
          // 唯一要保证的就是这个间距（原来写死 6，语义看不出来）。
          //
          // 用具名常量 + 只在"上方与左右"给外边距：
          // 底部**不给**外边距，否则会和导航栏自己的
          // `bottomMargin`（FloatingNavSpec.bottomMargin = 30）叠加。
          padding: const EdgeInsets.fromLTRB(
            MusicMiniPlayerLayout.sideMargin,
            0,
            MusicMiniPlayerLayout.sideMargin,
            MusicMiniPlayerLayout.gapAboveNavBar,
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onOpen,
            child: Container(
              height: 56,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: MusicTheme.card,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: MusicTheme.label.withValues(alpha: 0.07),
                  width: 0.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  // 封面 + 强调色光晕
                  SizedBox(
                    width: 42,
                    height: 42,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: MusicTheme.tint.withValues(alpha: 0.32),
                          ),
                        ),
                        CoverImage(
                            url: song.coverUrl, size: 36, cornerRadius: 7),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: _titleColumn(player, song)),
                  _btn(
                    player.isPlaying.value
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    () => player.toggle(),
                    size: 32,
                    filled: true,
                  ),
                  _btn(Icons.skip_next_rounded, () => player.next(), size: 30),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 标题区：优先显示当前歌词行（Beans 就是这样，比歌手名更有信息量）
  Widget _titleColumn(MusicPlayerManager player, Song song) {
    return ValueListenableBuilder<List<LyricLine>>(
      valueListenable: player.lyrics,
      builder: (context, lines, __) {
        return ValueListenableBuilder<int>(
          valueListenable: player.lyricIndex,
          builder: (context, idx, ___) {
            String sub;
            Color subColor = MusicTheme.secondary;
            if (lines.isNotEmpty && idx >= 0 && idx < lines.length) {
              final l = lines[idx];
              sub = l.translation?.isNotEmpty == true
                  ? '${l.text} · ${l.translation}'
                  : l.text;
              subColor = MusicTheme.tint;
            } else {
              sub = song.artists.isEmpty ? song.album : song.artists;
            }
            return Column(
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
                            color: MusicTheme.label,
                            fontSize: AppTheme.fontBody,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (song.isVIP) ...[
                      const SizedBox(width: 5),
                      const VipBadge(),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: subColor, fontSize: AppTheme.fontFootnote),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _btn(IconData icon, VoidCallback onTap,
      {double size = 32, bool filled = false}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: size + 8,
        height: size + 8,
        alignment: Alignment.center,
        child: filled
            ? Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: MusicTheme.accentGradient,
                  ),
                ),
                child: Icon(icon, color: Colors.white, size: size * 0.62),
              )
            : Icon(icon, color: MusicTheme.label, size: size * 0.8),
      ),
    );
  }
}

/// 全屏播放器入口（声明在 player_page.dart，这里只是转发，
/// 避免 MiniPlayer 直接依赖页面实现细节）
Future<void> openMusicPlayer(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const MusicPlayerPage(),
      ),
    );

/// 供 RootView 复用的「当前是否在播」判断
bool get hasCurrentMusic => MusicPlayerManager.instance.currentSong != null;

/// 预取：进入音乐 tab 时把常用列表拉一次（失败不打扰，但**要能知道**）
///
/// #14：原来返回 `void` 且 `catch (_) {}` **把失败完全吞掉** ——
/// 调用方无法区分"成功"和"网络不通"，于是预热失败时
/// 音乐页就是一片空白，用户不知道是"没数据"还是"加载失败"。
/// 现在返回 bool，由 `RootView` 决定是否给"点击重试"。
Future<bool> warmUpMusicData() async {
  try {
    await MusicApi.instance.hotSearch();
    return true;
  } catch (_) {
    return false;
  }
}
