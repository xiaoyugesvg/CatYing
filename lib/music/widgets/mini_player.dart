import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/music_api.dart';
import '../services/player_manager.dart';
import '../theme/music_theme.dart';
import '../widgets/music_components.dart';
import '../pages/player_page.dart';
import '../pages/queue_page.dart';
import '../widgets/quick_actions.dart';
import '../../common/floating_nav_spec.dart';
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

  /// 迷你播放器**容器高度**（对应 `Container(height: 56)`）。
  ///
  /// ⚠️ 提升成常量是为了让**悬浮播放球**能算出"迷你条上方"的位置：
  /// 播放球原来固定距底 96，而迷你条占
  /// `86(导航栏) + 62(迷你条) ~ 148` —— 于是球**压在迷你条上**
  ///（用户实测反馈）。两边用同一组常量，以后改迷你条高度
  /// 播放球会**自动跟着让位**。
  static const double barHeight = 56;

  /// 迷你播放器**整条占的高度**（含它自己那层底部 padding）。
  ///
  /// ⚠️ 实测结构（别想当然）：外层是
  ///     `padding: EdgeInsets.fromLTRB(sideMargin, 0, sideMargin, gapAboveNavBar)`
  /// 即**底部就是 `gapAboveNavBar`(6)**，**没有**独立的 vertical padding。
  /// 所以整条占 = `barHeight + gapAboveNavBar` = 62。
  ///
  /// 布局链：`Column[ MiniPlayer, JellyNavBar ]`（贴底）
  ///   → 导航栏自身 `bottomMargin(20) + barHeight(66)` = 86
  ///   → 迷你条底部 padding 6，容器 56
  ///   → **迷你条顶边距屏幕底 = 86 + 6 + 56 = 148**
  static const double totalHeight = barHeight + gapAboveNavBar;

  /// 迷你播放器**顶边**距屏幕底部的距离（**不含**系统安全区）
  static const double topFromBottom = FloatingNavSpec.bottomMargin +
      FloatingNavSpec.barHeight +
      totalHeight;

  /// 左右外边距（与导航栏的 sideMargin 视觉对齐）
  ///
  /// 用 `FloatingNavSpec.sideMargin`（=12）而不是自己写 10 ——
  /// 悬浮导航栏（JellyNavBar）左右边距就是 12，迷你播放器
  /// 要与它**完全同宽**，边距必须取同一个值，否则两边对不齐。
  static const double sideMargin = FloatingNavSpec.sideMargin;
}

/// 底部迷你播放器 —— 移植自 Beans 的 `MiniPlayerView.swift`（dock 形态）。
///
/// 视觉规格照搬：
///   · 封面 36 / 圆角 7，后面一层 42×42 的强调色光晕（blur 9）
///   · 容器圆角 18，左右内边距，高度紧凑
///   · 左侧封面 + 歌名/歌手（或当前歌词），右侧播放/暂停 + 下一首
///
/// 点整条打开全屏播放器。没有正在播放的歌曲时**整条隐藏**（不占位）。
class MiniPlayer extends StatefulWidget {
  const MiniPlayer({
    super.key,
    required this.onOpen,
    this.bottomInset = 0,
  });

  /// 除 [MusicMiniPlayerLayout.gapAboveNavBar] 之外，**再往下垫多少**。
  ///
  /// · `RootView` 里传 **0** —— 那时它是导航栏的 Column 兄弟，位置已排好。
  /// · 全局悬浮用法传**导航栏高度**（在音乐主页面时）或 **0**（子页面贴底），
  ///   见 `app.dart` 的 `_GlobalMiniPlayer`。
  final double bottomInset;

  final VoidCallback onOpen;

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer>
    with SingleTickerProviderStateMixin {
  /// 封面旋转动画（与播放器页同一周期，播放转 / 暂停停）
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    );
    MusicPlayerManager.instance.isPlaying.addListener(_syncSpin);
    _syncSpin();
  }

  void _syncSpin() {
    final p = MusicPlayerManager.instance;
    if (p.isPlaying.value) {
      _spin.repeat();
    } else {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    MusicPlayerManager.instance.isPlaying.removeListener(_syncSpin);
    _spin.dispose();
    super.dispose();
  }

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
          //
          // ── ⚠️ `bottomInset` 是给**全局悬浮用法**加的（用户 2026 要求）──
          // 「只要在播放，每个页面都要有迷你条」→ 迷你条被挂到 `app.dart`
          // 的全局 Stack 里（和悬浮播放球同一层，覆盖所有路由）。
          //
          // 但那种情况下它**不在** `RootView` 的 Column 里了，必须自己
          // 定位到底部 —— 而且：
          //   · 在音乐主页面：要把导航栏的 86 让出来
          //   · 在 push 出去的子页：下面没有导航栏，贴底（+ 安全区）
          // 所以这里用一个参数表达"还要再往下垫多少"，
          // 由调用方决定（`RootView` 里传 0，因为 Column 已经排好了）。
          padding: EdgeInsets.fromLTRB(
            MusicMiniPlayerLayout.sideMargin,
            0,
            MusicMiniPlayerLayout.sideMargin,
            MusicMiniPlayerLayout.gapAboveNavBar + widget.bottomInset,
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onOpen,
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
                  // 封面 + 强调色光晕（封面为圆形旋转 CD 盘）
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
                        RotationTransition(
                          turns: _spin,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              ClipOval(
                                child: CoverImage(
                                    url: song.coverUrl,
                                    size: 36,
                                    circle: true),
                              ),
                              // CD 中心孔
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: const Color(0xFF0A0A0C),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: _titleColumn(player, song)),
                  const SizedBox(width: 2),
                  // 功能快捷排：上一集 / 歌单 / 下载 / 历史 / 收藏
                  _iconBtn(Icons.skip_previous_rounded, () => player.previous()),
                  _iconBtn(Icons.queue_music_rounded, () => _openQueue(context)),
                  _iconBtn(
                      Icons.download_rounded, () => musicEnqueueDownload(song)),
                  _iconBtn(Icons.history_rounded, () => showRecentSongsSheet()),
                  _iconBtn(
                      Icons.favorite_border_rounded,
                      () => musicToggleFavorite(song)),
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

  /// 打开播放队列（歌单）
  void _openQueue(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const MusicQueuePage()),
    );
  }

  /// 小功能图标键（上一集/歌单/下载/历史/收藏）—— 30×30 点击区
  Widget _iconBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        child: Icon(icon, color: MusicTheme.secondary, size: 19),
      ),
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
