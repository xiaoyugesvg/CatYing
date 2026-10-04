import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// 是否展开出「上一首 / 播放暂停 / 下一首」三个键
  bool _open = false;

  void _openPlayer() {
    final nav = VideoPlayerPip.navigatorKey.currentState;
    if (nav == null) return;
    nav.push<void>(
      MaterialPageRoute(builder: (_) => const MusicPlayerPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 自定义样式（图片/GIF）与 tab 判断一起在这里生效
    MusicFloatingBallStyle.instance.init();
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
        final x = pos.dx.clamp(8.0, maxX);
        final y = pos.dy.clamp(80.0, maxY);
        final toLeft = x + _size / 2 < screen.width / 2;

        // 展开的控制条**横向**长出来（朝屏幕中间），所以球的垂直位置不变 ——
        // 这正是为了避免"一展开球就往下跑"。
        // 展开条：**只保留三个键**（用户要求）——
        // 收藏/下载/历史已抽到 `quick_actions.dart`，供迷你播放器等复用。
        final controls = <Widget>[
          _ctrl(Icons.skip_previous_rounded, player.previous),
          _ctrl(
            player.isBuffering.value
                ? Icons.hourglass_bottom_rounded
                : (player.isPlaying.value
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded),
            player.toggle,
            primary: true,
          ),
          _ctrl(Icons.skip_next_rounded, () => player.next()),
        ];

        return Positioned(
          // 贴左时按 left 定位（右侧长出来）；贴右时按 right 定位（左侧长出来）
          left: toLeft ? x : null,
          right: toLeft ? null : (screen.width - x - _size),
          top: y,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: toLeft
                ? [ _ballCircle(player), if (_open) ...controls ]
                : [ if (_open) ...controls, _ballCircle(player) ],
          ),
        );
      },
    );
  }

  /// 圆形控制键（展开条里的小键）
  Widget _ctrl(IconData icon, VoidCallback onTap, {bool primary = false}) {
    final d = primary ? 46.0 : 40.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: d,
          height: d,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: primary
                ? MusicTheme.tint
                : Colors.black.withValues(alpha: 0.55),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.35),
              width: 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(icon, color: Colors.white, size: primary ? 24 : 20),
        ),
      ),
    );
  }

  /// 主球（圆形本体）：**点击展开/收起**，**长按进播放页**，可拖动
  Widget _ballCircle(MusicPlayerManager player) {
    return GestureDetector(
      onPanUpdate: (d) {
        final screen = MediaQuery.of(context).size;
        final pad = MediaQuery.of(context).padding;
        final maxX = (screen.width - _size - 8).clamp(8.0, screen.width);
        final maxY =
            (screen.height - _size - pad.bottom - 8).clamp(90.0, screen.height);
        final cur = _pos ??
            Offset(screen.width - _size - 16, screen.height - pad.bottom - 96);
        setState(() {
          _pos = Offset(
            (cur.dx + d.delta.dx).clamp(8.0, maxX),
            (cur.dy + d.delta.dy).clamp(80.0, maxY),
          );
        });
      },
      // 松手吸附到最近的左右边（半藏式，不挡内容）
      onPanEnd: (_) {
        final screen = MediaQuery.of(context).size;
        final pad = MediaQuery.of(context).padding;
        final maxX = (screen.width - _size - 8).clamp(8.0, screen.width);
        final cur = _pos ??
            Offset(screen.width - _size - 16, screen.height - pad.bottom - 96);
        final toLeft = cur.dx + _size / 2 < screen.width / 2;
        setState(() {
          _pos = Offset(toLeft ? 8 : maxX, cur.dy);
        });
      },
      // 点击 = 展开/收起控制键（用户要求：点一下要能播放/暂停/上下首）
      onTap: () => setState(() => _open = !_open),
      // 长按 = 进播放页（用户要求）
      onLongPress: _openPlayer,
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
          child: ClipOval(
            child: MusicFloatingBallStyle.instance.imagePath.value.isNotEmpty
                ? Image.file(
                    File(MusicFloatingBallStyle.instance.imagePath.value),
                    width: _size,
                    height: _size,
                    fit: BoxFit.cover,
                    // 文件被删/格式不支持 → 回落到默认图标，不留白洞
                    errorBuilder: (_, __, ___) => _ballIcon(player),
                  )
                : _ballIcon(player),
          ),
        ),
      ),
    );
  }

  /// 默认样式：显示当前播放状态的图标
  Widget _ballIcon(MusicPlayerManager player) => Icon(
        // 收起时显示当前播放状态；展开时表示"再点收起"
        _open
            ? Icons.close_rounded
            : (player.isBuffering.value
                ? Icons.hourglass_bottom_rounded
                : (player.isPlaying.value
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded)),
        color: Colors.white,
        size: 26,
      );
}

/// 悬浮球**自定义样式**（用户可以在设置里选一张图片 / GIF）。
///
/// 为什么单独一个小 Store 而不是塞进 `SettingsStore`：
/// 这个能力只服务悬浮球一个组件，塞进那个大 Store 要动它的加载/持久化链路；
/// 独立出来**谁也不影响**，而且路径就这么一个字符串。
///
/// GIF 不需要特殊处理：Flutter 的 `Image.file` 原生就播 GIF 动画 ✓
class MusicFloatingBallStyle {
  MusicFloatingBallStyle._();
  static final MusicFloatingBallStyle instance = MusicFloatingBallStyle._();

  static const String _kKey = 'music.floatingBall.image';

  /// 自定义图片路径；空串 = 用默认图标样式
  final ValueNotifier<String> imagePath = ValueNotifier<String>('');

  SharedPreferences? _prefs;
  bool _inited = false;

  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    try {
      _prefs = await SharedPreferences.getInstance();
      final saved = _prefs!.getString(_kKey) ?? '';
      // 文件可能已被用户删掉 → 存了也不显示（并在下次保存时清掉）
      if (saved.isNotEmpty && !File(saved).existsSync()) {
        await _prefs!.remove(_kKey);
      } else {
        imagePath.value = saved;
      }
    } catch (_) {
      /* 读不出来就用默认样式 */
    }
  }

  Future<void> setImage(String path) async {
    await init();
    imagePath.value = path;
    try {
      await _prefs?.setString(_kKey, path);
    } catch (_) {
      /* 存不下不影响本次显示 */
    }
  }

  Future<void> clear() async {
    await init();
    imagePath.value = '';
    try {
      await _prefs?.remove(_kKey);
    } catch (_) {}
  }
}
