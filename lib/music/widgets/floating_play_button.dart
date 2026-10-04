import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../pages/player_page.dart';
import '../services/player_manager.dart';
import '../theme/music_theme.dart';
import '../../services/main_tab_controller.dart';
import '../../widgets/video_player_pip.dart';

/// **可拖动的悬浮播放球**（音乐模块）。
///
/// ── 它解决什么问题 ────────────────────────────────────────────
/// 迷你播放器只挂在音乐根视图（`root_view.dart:195`），**被 push 出去的页面**
///（歌单详情 / 喜马拉雅专辑 / 本地音乐 / 队列）**没有播放条** —— 在那些页面
/// 点歌之后除了声音没有任何反馈。这个球浮在上层：
///   · **可拖动**：手指拖到顺手的位置，松手**吸附到最近的左右边**
///   · **点击** → 进播放页（全屏播放器）
///   · **没有正在播放的歌时自动隐藏**（不占屏幕、不干扰）
///
/// ── 为什么挂在 app 级 Stack 而不是各页面 ──────────────────────
/// 挂在 `MaterialApp.builder` 的那层 Stack 上（与壁纸同一层），
/// **一处挂载就覆盖所有路由**（含 push 出去的页面）——
/// 否则要给 4 个页面各加一遍，还容易漏。
/// 代价：音乐在播时它也会浮在影视/阅读之上（可接受，拖动即让开）。
///
/// ⚠️ 那一层在 **Navigator 之上**，所以 `Navigator.of(context)` 拿不到 ——
/// 必须用全局 `VideoPlayerPip.navigatorKey` 来 push（`AppToast` 也是这么做的）。
class MusicFloatingPlayButton extends StatefulWidget {
  const MusicFloatingPlayButton({super.key});

  @override
  State<MusicFloatingPlayButton> createState() =>
      _MusicFloatingPlayButtonState();
}

class _MusicFloatingPlayButtonState extends State<MusicFloatingPlayButton> {
  static const double _size = 54;

  /// 拖动后的位置；null = 用默认位置（右下、迷你播放器上方）
  Offset? _pos;

  void _openPlayer() {
    final nav = VideoPlayerPip.navigatorKey.currentState;
    if (nav == null) return;
    nav.push<void>(
      MaterialPageRoute(builder: (_) => const MusicPlayerPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    // ── 只在**音乐模块**里显示 ──────────────────────────────────────
    // 音乐本身是一个主 tab（`MainTabController.musicTabIndex`），而
    // **push 音乐子页面不会改变当前 tab** —— 所以：
    //   · 歌单详情 / 喜马拉雅专辑 / 本地音乐 / 队列 里它照样在 ✓
    //   · 切到影视 / 直播 / 阅读 tab 时**自动隐藏** ✓
    // 这样就不必给 5 个页面各挂一次（那种做法还容易漏）。
    return Obx(() {
      if (!Get.isRegistered<MainTabController>() ||
          MainTabController.instance.selectedTab.value !=
              MainTabController.musicTabIndex) {
        return const SizedBox.shrink();
      }
      return _ball(context);
    });
  }

  Widget _ball(BuildContext context) {
    final player = MusicPlayerManager.instance;
    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        // 没有正在播放的歌 → 整个隐藏（空状态不要留个球在屏幕上）
        final song = player.currentSong;
        if (song == null) return const SizedBox.shrink();

        final screen = MediaQuery.of(context).size;
        final pad = MediaQuery.of(context).padding;
        final maxX = (screen.width - _size - 8).clamp(8.0, screen.width);
        final maxY =
            (screen.height - _size - pad.bottom - 8).clamp(90.0, screen.height);

        // 默认：右下、避开底部导航与迷你播放器
        final pos = _pos ??
            Offset(screen.width - _size - 16, screen.height - pad.bottom - 96);

        return Positioned(
          left: pos.dx.clamp(8.0, maxX),
          top: pos.dy.clamp(80.0, maxY),
          child: GestureDetector(
            onPanUpdate: (d) {
              setState(() {
                _pos = Offset(
                  (pos.dx + d.delta.dx).clamp(8.0, maxX),
                  (pos.dy + d.delta.dy).clamp(80.0, maxY),
                );
              });
            },
            // 松手吸附到最近的左右边（半藏式体验，不挡内容）
            onPanEnd: (_) {
              final p = _pos;
              if (p == null) return;
              final toLeft = p.dx + _size / 2 < screen.width / 2;
              setState(() {
                _pos = Offset(toLeft ? 8 : maxX, p.dy);
              });
            },
            onTap: _openPlayer,
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: _size,
                height: _size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: MusicTheme.tint,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.22),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.5),
                    width: 1.2,
                  ),
                ),
                child: Icon(
                  // 正在播 → 暂停态图标（点开播放页可以暂停）；缓冲时给个沙漏感
                  player.isBuffering.value
                      ? Icons.hourglass_bottom_rounded
                      : (player.isPlaying.value
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded),
                  color: Colors.white,
                  size: 26,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
