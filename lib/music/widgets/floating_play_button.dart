import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../pages/player_page.dart';
import 'music_components.dart';
import 'mini_player.dart';
import '../services/player_manager.dart';
import '../theme/music_theme.dart';
import '../../services/app_log.dart';
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

  /// 球与迷你播放条之间的视觉间隙
  ///
  /// 8 是"看得出是两层、又不显得空"的值（和迷你条自己的
  /// `gapAboveNavBar = 6` 同一量级）。
  static const double _bottomGap = 8;

  /// 拖动后的位置；null = 用默认位置（右下、迷你播放器上方）
  Offset? _pos;

  /// 是否展开出「上一首 / 播放暂停 / 下一首 / 关闭」四个键
  bool _open = false;

  /// 用户手动关闭悬浮球后设为 true，球整体隐藏；
  /// 切到新歌（currentSong 变化）时自动重置为 false，球重新出现。
  bool _dismissed = false;
  String? _lastSongKey;

  /// **C 方案**：贴边且收起时把球"半藏"进屏幕边缘（露出约 62%），
  /// 此时**封面不旋转**（静止的半圆在边上更安静）；
  /// 拖动中 / 展开时球全部露出 → 封面旋转 ✓
  bool _tucked = true;

  void _openPlayer() {
    final nav = VideoPlayerPip.navigatorKey.currentState;
    if (nav == null) return;
    nav.push<void>(
      MaterialPageRoute(settings: const RouteSettings(name: 'music:page'),builder: (_) => const MusicPlayerPage()),
    );
  }

  /// 关闭悬浮球：暂停播放 + 收起展开条 + 整体隐藏。
  ///
  /// 球被手动关闭后，**切到新歌时会自动重新出现**
  /// （比如点了另一首歌、队列自动切下一首）——
  /// 这样不会出现"关了之后再也找不到播放器"的情况。
  void _closeFloating() {
    MusicPlayerManager.instance.pause();
    setState(() {
      _open = false;
      _dismissed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 自定义样式（图片/GIF）在这里生效
    MusicFloatingBallStyle.instance.init();

    // ── 🔄 用户 2026 要求：**所有模块都显示**（改成全局悬浮球）────────
    //
    // 原来这里有一道"只在音乐模块显示"的判断：
    // ```dart
    // if (MainTabController.instance.selectedTab.value != musicTabIndex) {
    //   return const SizedBox.shrink();
    // }
    // ```
    // 理由（旧注释）是"切到影视/阅读时自动隐藏"。
    //
    // 用户实测后明确要求：**希望所有模块都显示** ——
    // 这样在影视 / 直播 / 阅读里也能一眼看到"正在放什么"、
    // 直接暂停或点进播放器，不用先切回音乐 tab。
    //
    // 它本来就挂在 `app.dart` 的全局 Stack（`MusicFloatingPlayButton`
    // 与背景层同层）→ **天然覆盖所有路由与所有模块**，
    // 所以这里**只需要把 tab 判断去掉**，不需要改挂载点。
    //
    // ⚠️ 保留的仍是"有歌才显示"（见下面 `_ball` 里
    //    `if (song == null) return SizedBox.shrink();`）——
    //    没在播时屏幕上不该挂个球。
    //
    // ── ⚠️ 但**全屏播放器打开时也要隐藏**（否则球会盖住播放器自己 ──
    //    的操作栏）────────────────────────────────────────────────
    // 播放器是全屏模态页，底部有它自己的操作栏
    //（列表循环 / 收藏 / 上一首 / 歌词 / 下一首 / 设置），
    // 而这个球挂在**所有路由之上**（`app.dart` 全局 Stack）。
    // 球默认停在右下、离底约 96px —— 正好压在那排按钮上。
    //
    // 这是用户已经报过的同一类问题（"播放器底部被全局底栏盖住"），
    // 所以这里用同一个标记让球也让位：`MusicPlayerPage.isOpen`。
    // 播放器里本来就有完整的播放控制，球是多余的。
    return ValueListenableBuilder<bool>(
      valueListenable: MusicPlayerPage.isOpen,
      builder: (context, open, _) =>
          open ? const SizedBox.shrink() : _ball(context),
    );
  }

  Widget _ball(BuildContext context) {
    final player = MusicPlayerManager.instance;
    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        // 没有正在播放的歌 → 整个隐藏（空状态不要留个球在屏幕上）
        final song = player.currentSong;
        if (song == null) return const SizedBox.shrink();

        // 歌曲变化（切歌 / 点了新歌）→ 重置手动关闭状态，球重新出现
        final key = '${song.name}|${song.artists}|${song.coverUrl}';
        if (key != _lastSongKey) {
          _lastSongKey = key;
          if (_dismissed) {
            // 在下一帧 setState，避免 build 过程中修改状态
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _dismissed = false);
            });
          }
        }

        // 用户手动关闭 → 整体隐藏
        if (_dismissed) return const SizedBox.shrink();

        final screen = MediaQuery.of(context).size;
        final pad = MediaQuery.of(context).padding;
        final maxX = (screen.width - _size - pad.right - 4).clamp(pad.left + 4, screen.width);
        final maxY =
            (screen.height - _size - pad.bottom - 8).clamp(90.0, screen.height);

        // ── 默认位置：右下、**让开整个迷你播放条** ──────────────────
        //
        // 🔴 修的真实问题（用户实测反馈）：
        // 原来这里写死 `- 96`，而底部实际占用是
        //     导航栏 86（bottomMargin 20 + barHeight 66）
        //   + 迷你条 62（gap 6 + 容器 56）
        //   = 距底 148 才在迷你条之上
        // → 球在 96 的位置**正好压在迷你条上**（右端被遮）。
        //
        // 现在按 `MusicMiniPlayerLayout.topFromBottom` 算（=148），
        // 再留 8 的视觉间隙 → **156**。
        // ⚠️ 用常量而不是再写一个数字：以后改迷你条高度，
        //    球的位置会**自动跟着让位**，不会又压上去。
        //
        // 迷你条只在本页有正在播放的歌时出现 —— 而本组件同样是
        // "没有正在播放的歌就整体隐藏"（见上面 `song == null`），
        // 所以**两者同生同灭**，不需要再判断一次。
        // 默认位置：屏幕右侧中间（右侧 16px 边距，垂直居中）。
        // 之前默认在底部迷你条上方，现在改到右侧中间，
        // 避免挡歌词/控制区，也更醒目。
        final defaultY = screen.height / 2 - _size / 2;
        final pos = _pos ?? Offset(screen.width - _size - 16, defaultY);
        // 用 `pos` 判断贴哪一侧（不能用 x —— 半藏后 x 可能为负）
        final toLeft = pos.dx + _size / 2 < screen.width / 2;
        // C 方案：**贴边且收起** → 半藏（露出约 62%）；拖动中/展开 → 全露
        final tucked = _tucked && !_open;
        final tuck = _size * 0.38;
        // 展开时：长条**贴边**（吸附到最近边，4px 边距）——
        // 用户要求"操作后化成长条贴边"，不论球之前在中间还是边上。
        final x = _open
            ? (toLeft ? pad.left + 4 : maxX)
            : tucked
                ? (toLeft
                    ? pad.left - tuck
                    : screen.width - _size - pad.right + tuck)
                : pos.dx.clamp(pad.left + 4, maxX);
        final y = pos.dy.clamp(80.0, maxY);

        // 展开时的控制条：上一首 / 播放暂停 / 下一首（共 3 键）
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

        // 展开时：控制条宽度 ≈ 3 键各 40 + 间距
        // 收起时：只有球本身（54）
        // （定位只按球宽 _size 算右缘，见下方 Positioned 注释）

        return Stack(
          children: [
            // 展开时：整屏透明点击层 —— 点任意空白处收起
            if (_open)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => setState(() => _open = false),
                ),
              ),
            Positioned(
              // 贴左时按 left 定位；贴右时按 right 定位
              left: toLeft ? x : null,
              // 🔴 展开条右缘必须对齐**球的右缘**（= screen.width - x - _size），
              //    而不是按展开条宽度（contentWidth）算：
              //    原来写 `screen.width - x - contentWidth`，贴右展开时
              //    150px 的控制条 right = 70 - 150 = **-80** → 溢出屏幕右缘 80px，
              //    用户看到的"展开条贴边/只露出左半截"就是这个 bug。
              //    用球宽（54）算 → right 恒等于球的右边距（16px），
              //    控制条从球的位置**向左**完整展开 ✓
              // 🔴 去掉 clamp：收起半藏时 right 需要是**负值**
              // （球右缘藏进屏幕外露出约 62% 贴边）；上一轮加的
              // `clamp(pad.right + 4, …)` 把负值抬成 4 → 球整个露在
              // 屏幕里、半藏贴边失效（用户反馈"不贴边"就是它）。
              // 全露/展开时 x ≤ maxX → right ≥ pad.right + 4，天然不溢出。
              right: toLeft ? null : screen.width - x - _size,
              top: y,
              // 🔴 展开条在极窄屏 / 系统大字号下会超出屏幕 →
              // 用 `FittedBox(scaleDown)` 整体等比缩小。
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: _open
                    // 展开态：控制条 + 右上角关闭按钮；不显示主球
                    ? _buildExpandedPanel(controls)
                    // 收起态：只显示主球
                    : _ballCircle(player),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 展开态面板：控制条（上一首 / 播放暂停 / 下一首）+ 右上角关闭按钮。
  ///
  /// 布局：关闭按钮浮在右上角，控制条水平居中排布。
  /// 展开时**不显示主球**（用户要求：点击展开后就不要那个悬浮图标了）。
  Widget _buildExpandedPanel(List<Widget> controls) {
    return SizedBox(
      width: 150,
      height: _size + 18, // 给关闭按钮留上方空间
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 关闭按钮（×）：右上角
          Positioned(
            top: 0,
            right: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _closeFloating,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.5),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.3),
                    width: 0.8,
                  ),
                ),
                child: const Icon(
                  Icons.close_rounded,
                  color: Colors.white,
                  size: 14,
                ),
              ),
            ),
          ),
          // 控制条：水平居中，垂直靠下（与球的中心 y 对齐）
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: controls,
            ),
          ),
        ],
      ),
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
      // 拖动一开始就"拔出来"（全露，封面转起来）
      onPanStart: (_) {
        if (_tucked) setState(() => _tucked = false);
      },
      onPanUpdate: (d) {
        final screen = MediaQuery.of(context).size;
        final pad = MediaQuery.of(context).padding;
        final maxX = (screen.width - _size - pad.right - 4).clamp(pad.left + 4, screen.width);
        final maxY =
            (screen.height - _size - pad.bottom - 8).clamp(90.0, screen.height);
        final minX = pad.left + 4;
        // 注：上界 `maxX` 上方已声明（这里不重复声明）；
        // 松手吸附时会用"安全区版本"重新算上界，所以最终落点一定贴边。
        final cur = _pos ??
            Offset(screen.width - _size - 16,
            screen.height - pad.bottom - (MusicMiniPlayerLayout.topFromBottom + _bottomGap));
        setState(() {
          _pos = Offset(
            (cur.dx + d.delta.dx).clamp(minX, maxX),
            (cur.dy + d.delta.dy).clamp(80.0, maxY),
          );
        });
      },
      // 松手：**停在当前位置**（拖动自由、随意停留），
      // 靠边（球中心离左右缘约 40px 内）则半藏贴边。
      onPanEnd: (_) {
        final screen = MediaQuery.of(context).size;
        final pad = MediaQuery.of(context).padding;
        final cur = _pos;
        if (cur == null) return;
        final toLeft = cur.dx + _size / 2 < screen.width / 2;
        final nearEdge = toLeft
            ? cur.dx < pad.left + _size + 40
            : cur.dx > screen.width - _size - pad.right - 40;
        setState(() => _tucked = nearEdge);
      },
      // 点击 = 展开/收起控制键（用户要求：点一下要能播放/暂停/上下首）
      onTap: () => setState(() => _open = !_open),
      // 长按 = 进播放页（用户要求）
      onLongPress: _openPlayer,
      // 🔴 必须显式 opaque：默认 `deferToChild` 时，**只有子组件绘制到的区域**
      // 才接收手势 —— 用户从球的透明边角按下拖动时，整个拖动都不会触发 ✗
      // 这正是"悬浮球拖不动/贴不了边"的原因。
      behavior: HitTestBehavior.opaque,
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
                // ① 用户自定义了图片/GIF → 就用它（GIF 自己会动，不再叠加旋转）
                ? Image.file(
                    File(MusicFloatingBallStyle.instance.imagePath.value),
                    width: _size,
                    height: _size,
                    fit: BoxFit.cover,
                    // 文件被删/格式不支持 → 回落到封面/图标，不留白洞
                    errorBuilder: (_, __, ___) => _ballCover(player),
                  )
                // ② 默认 = **正在播放的封面**，播放时像唱片一样旋转
                : _ballCover(player),
          ),
        ),
      ),
    );
  }

  /// 默认样式：显示当前播放状态的图标。
  ///
  /// 展开/收起时**保持同一个状态图标** —— 不再变成大 × 关闭按钮
  /// （用户反馈：那个关闭按钮太突出）。收起靠「点空白处」或「再点主球」。
  /// 默认样式：**当前歌曲封面**，播放时像唱片一样旋转。
  ///
  /// ⚠️ 旋转角用**播放进度**驱动，不用 `AnimationController`：
  ///   · 不需要 `TickerProvider`（少一套生命周期与 dispose）
  ///   · **暂停时进度不再前进 → 自动停在原角度** ✓
  ///   · 切歌后进度归零 → 从 0 开始转 ✓
  /// 20 秒一圈（唱片观感）。封面取不到 → 回落状态图标（不留白洞）。
  Widget _ballCover(MusicPlayerManager player) {
    final cover = (player.currentSong?.coverUrl ?? '').trim();
    if (cover.isEmpty) return _ballIcon(player);
    // C 方案：半藏（贴边且收起）时**不转**；全露（拖动/展开）时才转
    final spinning = !(_tucked && !_open);
    final angle = spinning
        ? player.position.value.inMilliseconds / 20000 * 2 * math.pi
        : 0.0;
    return Transform.rotate(
      angle: angle,
      child: CoverImage(url: cover, size: _size, cornerRadius: 0),
    );
  }

  Widget _ballIcon(MusicPlayerManager player) => Icon(
        player.isBuffering.value
            ? Icons.hourglass_bottom_rounded
            : (player.isPlaying.value
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded),
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

  /// 正在进行的初始化。
  ///
  /// 🔴 原来这里是 `bool _inited` 闩锁：它**先置 true 再 `await`**，
  /// 于是紧接着调用的 `init()` 会**立刻返回**，而此刻 `_prefs` 还是 `null` →
  /// `setImage()` 里的 `await _prefs?.setString(...)` 被 `?.` **静默跳过** ✗
  /// 表现就是：用户选的图片**当次能显示（内存已改）、重启后消失** ✗
  /// 改成缓存 `Future`，并发/后续调用者会**等它真正完成**。
  Future<void>? _initFuture;

  Future<void> init() => _initFuture ??= _doInit();

  Future<void> _doInit() async {
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
    // 不再用 `?.` 静默吞掉：真的存不下时至少能在日志里看到
    final p = _prefs;
    if (p == null) {
      AppLog.instance.log('[Music] 悬浮球样式写入失败：prefs 未就绪');
      return;
    }
    try {
      await p.setString(_kKey, path);
    } catch (e) {
      AppLog.instance.log('[Music] 悬浮球样式写入失败: $e');
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
