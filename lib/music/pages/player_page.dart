import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/player_manager.dart';
import '../theme/music_theme.dart';
import '../widgets/music_components.dart';
import 'player_settings_sheet.dart';

/// 全屏播放器 —— 移植自 Beans 的 `PlayerView.swift`（4447 行，这里取其主干）。
///
/// ── 本页保留的 Beans 特征 ─────────────────────────────────────
///   · **封面 ⇄ 歌词 双视图**：点封面区切换，封面旋转、歌词居中滚动高亮
///   · **封面取色背景**：用封面的主色做整页渐变背景（Beans 的 CoverPalette）
///   · 黑胶/CD 形态的旋转封面 + 唱臂（简化版）
///   · 顶部：下箭头 / 歌名歌手 / 更多
///   · 中部：封面或歌词
///   · 下部：进度条（可拖动）+ 时间 / 播放控制 / 底部动作栏
///   · 底部动作栏：播放模式 / 上一首 / 播放 / 下一首 / 队列
///
/// 没做的（Beans 有、这里略）：音效均衡器、DJ 可视化、评论、
/// 下载、歌单编辑、分享 —— 这些依赖账号或额外依赖，按需求裁剪。
class MusicPlayerPage extends StatefulWidget {
  const MusicPlayerPage({super.key});

  @override
  State<MusicPlayerPage> createState() => _MusicPlayerPageState();
}

class _MusicPlayerPageState extends State<MusicPlayerPage>
    with SingleTickerProviderStateMixin {
  final player = MusicPlayerManager.instance;

  /// 封面旋转动画
  late final AnimationController _spin;

  /// true = 显示歌词；false = 显示封面
  bool showLyric = false;

  /// 拖动进度时的临时值（避免拖动中进度条跳回）
  double? _dragging;

  /// 封面取色得到的背景色（拿不到就用强调色）
  Color _tint = MusicTheme.tint;

  final _lyricScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    );
    showLyric = MusicPlayerSkin.instance.showLyricFirst.value;
    player.addListener(_onPlayerChanged);
    player.isPlaying.addListener(_syncSpin);
    _syncSpin();
    unawaited(_extractTint());
  }

  @override
  void dispose() {
    player.removeListener(_onPlayerChanged);
    player.isPlaying.removeListener(_syncSpin);
    _spin.dispose();
    _lyricScroll.dispose();
    super.dispose();
  }

  void _onPlayerChanged() {
    if (!mounted) return;
    setState(() {});
    unawaited(_extractTint());
  }

  void _syncSpin() {
    if (player.isPlaying.value) {
      _spin.repeat();
    } else {
      _spin.stop();
    }
  }

  /// 从封面图取主色做背景（Beans 的 CoverPalette 思路）。
  /// 失败就退回强调色 —— 不能让取色失败影响播放器可用。
  Future<void> _extractTint() async {
    final url = player.currentSong?.coverUrl;
    if (url == null || url.isEmpty) {
      if (mounted) setState(() => _tint = MusicTheme.tint);
      return;
    }
    try {
      final scheme = await ColorScheme.fromImageProvider(
        provider: NetworkImage(url),
        brightness: Brightness.dark,
      );
      if (!mounted) return;
      if (scheme.primary != _tint) setState(() => _tint = scheme.primary);
    } catch (_) {
      if (mounted) setState(() => _tint = MusicTheme.tint);
    }
  }

  @override
  Widget build(BuildContext context) {
    final song = player.currentSong;
    if (song == null) {
      return Scaffold(
        backgroundColor: MusicTheme.background,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: Icon(Icons.keyboard_arrow_down_rounded,
                color: MusicTheme.label, size: 28),
            onPressed: () => Navigator.maybePop(context),
          ),
        ),
        body: Center(
          child: Text('没有正在播放的歌曲',
              style: TextStyle(color: MusicTheme.secondary, fontSize: 14)),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 背景：黑底 + 封面主色渐变（Beans 的 CoverBlurBackground 简化版）
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color.lerp(Colors.black, _tint, 0.55)!,
                    Colors.black,
                  ],
                  stops: const [0.0, 0.75],
                ),
              ),
            ),
          ),
          // 氛围层（浮尘 / 星点）—— 由设置的"背景氛围"决定。
          // 之前存了 dustMode 却没读，等于设置无效。
          Positioned.fill(
            child: ValueListenableBuilder<MusicDustMode>(
              valueListenable: MusicPlayerSkin.instance.dustMode,
              builder: (context, mode, __) {
                if (mode == MusicDustMode.none) {
                  return const SizedBox.shrink();
                }
                return IgnorePointer(
                  child: CustomPaint(
                    painter: _AmbientPainter(
                      mode: mode,
                      tint: _tint,
                      seed: player.currentSong?.id ?? 0,
                    ),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _topBar(song),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => showLyric = !showLyric),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 260),
                      child: showLyric ? _lyricView() : _coverView(song),
                    ),
                  ),
                ),
                _progressBar(),
                const SizedBox(height: 6),
                _controls(),
                const SizedBox(height: 10),
                _bottomBar(),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 顶部
  // ============================================================

  Widget _topBar(dynamic song) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down_rounded,
                color: Colors.white, size: 30),
            onPressed: () => Navigator.maybePop(context),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  song.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  song.artists,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.more_horiz, color: Colors.white, size: 24),
            onPressed: () => showSongActions(context, song),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 封面视图（旋转黑胶）
  // ============================================================

  Widget _coverView(dynamic song) {
    // 读取用户设置的封面形态 —— 之前存了却没读，等于设置无效。
    return ValueListenableBuilder<MusicCoverStyle>(
      valueListenable: MusicPlayerSkin.instance.coverStyle,
      builder: (context, style, __) {
        final cover = switch (style) {
          MusicCoverStyle.vinyl => _vinylCover(song),
          MusicCoverStyle.cd => _cdCover(song),
          MusicCoverStyle.square => _squareCover(song),
          MusicCoverStyle.blur => _blurCover(song),
        };
        return Center(
          key: const ValueKey('cover'),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              cover,
              const SizedBox(height: 22),
              _qualityChip(),
              const SizedBox(height: 10),
              Text(
                '轻点封面查看歌词',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35), fontSize: 11),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 音质 / 音源 小胶囊（有才显示）
  Widget _qualityChip() {
    return ValueListenableBuilder<String>(
      valueListenable: player.qualityText,
      builder: (context, q, _) {
        if (q.isEmpty) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            q,
            style: const TextStyle(
                color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600),
          ),
        );
      },
    );
  }

  // ── 封面形态 1：黑胶（默认）—— 唱片盘面 + 中心标签 + 唱臂 ──
  Widget _vinylCover(dynamic song) {
    return SizedBox(
      width: 280,
      height: 280,
      child: Stack(
        alignment: Alignment.center,
        children: [
          _glow(280, 0.45),
          // 盘面
          RotationTransition(
            turns: _spin,
            child: Container(
              width: 246,
              height: 246,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF141416),
                // 唱片纹路：几道同心圆描边
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.06), width: 0.8),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 24,
                      offset: const Offset(0, 8)),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 中心标签（就是封面）
                  ClipOval(
                    child:
                        CoverImage(url: song.coverUrl, size: 132, circle: true),
                  ),
                  // 中心轴孔
                  Container(
                    width: 12,
                    height: 12,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF0A0A0C),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 唱臂（不做真实动画，静态摆位即可 —— 动起来反而分心）
          Positioned(
            right: 6,
            top: 10,
            child: Transform.rotate(
              angle: 0.35,
              child: Container(
                width: 5,
                height: 96,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.28),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 封面形态 2：CD —— 透明圆盘 + 中心孔 + 虹彩环 ──
  Widget _cdCover(dynamic song) {
    return SizedBox(
      width: 280,
      height: 280,
      child: Stack(
        alignment: Alignment.center,
        children: [
          _glow(280, 0.4),
          RotationTransition(
            turns: _spin,
            child: Stack(
              alignment: Alignment.center,
              children: [
                ClipOval(
                  child: CoverImage(url: song.coverUrl, size: 244, circle: true),
                ),
                // 虹彩反光环
                Container(
                  width: 244,
                  height: 244,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: SweepGradient(colors: [
                      Colors.white.withValues(alpha: 0.0),
                      Colors.white.withValues(alpha: 0.22),
                      _tint.withValues(alpha: 0.30),
                      Colors.white.withValues(alpha: 0.0),
                    ]),
                  ),
                ),
                // 中心孔（CD 的标志性特征）
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF0A0A0C),
                    border: Border.all(
                        color: Colors.white.withValues(alpha: 0.18),
                        width: 1),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 封面形态 3：方形 —— 不旋转的圆角封面（最"干净"）──
  Widget _squareCover(dynamic song) {
    return SizedBox(
      width: 280,
      height: 280,
      child: Stack(
        alignment: Alignment.center,
        children: [
          _glow(280, 0.35),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 28,
                    offset: const Offset(0, 10)),
              ],
            ),
            child: CoverImage(url: song.coverUrl, size: 244, cornerRadius: 18),
          ),
        ],
      ),
    );
  }

  // ── 封面形态 4：模糊大图 —— 铺满的模糊封面 + 中间小卡 ──
  Widget _blurCover(dynamic song) {
    final url = (song.coverUrl ?? '').toString();
    return SizedBox(
      width: 280,
      height: 300,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (url.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
                child: Image.network(url,
                    width: 280,
                    height: 300,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox()),
              ),
            ),
          // 压暗一层，让中间的小封面跳出来
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: Colors.black.withValues(alpha: 0.35),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 22,
                    offset: const Offset(0, 8)),
              ],
            ),
            child: CoverImage(url: song.coverUrl, size: 168, cornerRadius: 14),
          ),
        ],
      ),
    );
  }

  /// 强调色径向光晕
  Widget _glow(double size, double alpha) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [_tint.withValues(alpha: alpha), Colors.transparent],
          ),
        ),
      );


  // ============================================================
  // 歌词视图
  // ============================================================

  Widget _lyricView() {
    return ValueListenableBuilder<List<LyricLine>>(
      valueListenable: player.lyrics,
      builder: (context, lines, __) {
        if (lines.isEmpty) {
          return Center(
            key: const ValueKey('lyric-empty'),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lyrics_outlined,
                    color: Colors.white.withValues(alpha: 0.3), size: 40),
                const SizedBox(height: 12),
                Text('暂无歌词',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 14)),
              ],
            ),
          );
        }
        return ValueListenableBuilder<int>(
          valueListenable: player.lyricIndex,
          builder: (context, idx, ___) {
            // 让当前行大致居中：向上偏移固定行数
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!_lyricScroll.hasClients) return;
              const lineH = 44.0;
              final target = ((idx < 0 ? 0 : idx) * lineH) -
                  _lyricScroll.position.viewportDimension / 2 +
                  lineH;
              final clamped = target.clamp(
                0.0,
                _lyricScroll.position.maxScrollExtent,
              );
              _lyricScroll.animateTo(
                clamped,
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOut,
              );
            });

            return ListView.builder(
              key: const ValueKey('lyric'),
              controller: _lyricScroll,
              padding: const EdgeInsets.symmetric(horizontal: 28),
              itemCount: lines.length + 2,
              itemBuilder: (c, i) {
                // 上下各留一屏空白，方便"居中"效果
                if (i == 0 || i == lines.length + 1) {
                  return const SizedBox(height: 180);
                }
                final li = i - 1;
                final line = lines[li];
                final active = li == idx;
                return Container(
                  height: 44,
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        line.text,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: active
                              ? Colors.white
                              : Colors.white.withValues(
                                  alpha: li < idx ? 0.45 : 0.3),
                          fontSize: active ? 17 : 15,
                          fontWeight:
                              active ? FontWeight.w600 : FontWeight.w400,
                          height: 1.25,
                        ),
                      ),
                      if (active &&
                          line.translation != null &&
                          line.translation!.isNotEmpty)
                        Text(
                          line.translation!,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: _tint.withValues(alpha: 0.95),
                              fontSize: 12),
                        ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  // ============================================================
  // 进度条
  // ============================================================

  Widget _progressBar() {
    return ValueListenableBuilder<Duration>(
      valueListenable: player.position,
      builder: (context, pos, __) {
        return ValueListenableBuilder<Duration>(
          valueListenable: player.duration,
          builder: (context, dur, ___) {
            final totalMs = dur.inMilliseconds;
            final posMs = _dragging ?? pos.inMilliseconds.toDouble();
            final max = totalMs > 0 ? totalMs.toDouble() : 1.0;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      activeTrackColor: _tint,
                      inactiveTrackColor: Colors.white.withValues(alpha: 0.18),
                      thumbColor: Colors.white,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 14),
                    ),
                    child: Slider(
                      value: posMs.clamp(0, max),
                      max: max,
                      onChanged: (v) => setState(() => _dragging = v),
                      onChangeEnd: (v) {
                        player.seek(Duration(milliseconds: v.round()));
                        setState(() => _dragging = null);
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_fmt(posMs),
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.55),
                                fontSize: 11)),
                        Text(_fmt(totalMs.toDouble()),
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.55),
                                fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  String _fmt(double ms) {
    final t = (ms / 1000).round();
    return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
  }

  // ============================================================
  // 播放控制
  // ============================================================

  Widget _controls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _circleBtn(Icons.replay_10_rounded, () =>
            player.seekBy(const Duration(seconds: -10))),
        const SizedBox(width: 26),
        // 播放/暂停（玻璃球）
        GestureDetector(
          onTap: () => player.toggle(),
          child: Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.14),
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.22), width: 0.8),
            ),
            child: ValueListenableBuilder<bool>(
              valueListenable: player.isPlaying,
              builder: (context, playing, _) => Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: Colors.white,
                size: 34,
              ),
            ),
          ),
        ),
        const SizedBox(width: 26),
        _circleBtn(Icons.forward_10_rounded, () =>
            player.seekBy(const Duration(seconds: 10))),
      ],
    );
  }

  Widget _circleBtn(IconData icon, VoidCallback onTap) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon,
              color: Colors.white.withValues(alpha: 0.85), size: 30),
        ),
      );

  // ============================================================
  // 底部动作栏
  // ============================================================

  Widget _bottomBar() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _actionBtn(
          icon: switch (player.mode.value) {
            PlayMode.list => Icons.repeat_rounded,
            PlayMode.single => Icons.repeat_one_rounded,
            PlayMode.shuffle => Icons.shuffle_rounded,
          },
          label: player.mode.value.label,
          onTap: () => setState(() => player.cycleMode()),
        ),
        _actionBtn(
          icon: Icons.skip_previous_rounded,
          label: '上一首',
          onTap: () => player.previous(),
        ),
        _actionBtn(
          icon: showLyric ? Icons.album_rounded : Icons.lyrics_rounded,
          label: showLyric ? '封面' : '歌词',
          onTap: () => setState(() => showLyric = !showLyric),
        ),
        _actionBtn(
          icon: Icons.skip_next_rounded,
          label: '下一首',
          onTap: () => player.next(),
        ),
        _actionBtn(
          icon: Icons.tune_rounded,
          label: '设置',
          onTap: () => showModalBottomSheet<void>(
            context: context,
            backgroundColor: MusicTheme.card,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            builder: (_) => const PlayerSettingsSheet(),
          ),
        ),
      ],
    );
  }

  Widget _actionBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white.withValues(alpha: 0.75), size: 22),
            const SizedBox(height: 3),
            Text(label,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45), fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

/// 播放器氛围层：浮尘 / 星点。
///
/// 用 `CustomPaint` 而不是叠一堆 widget —— 几十个粒子用 widget 会白白
/// 增加布局开销，而这里只需要画点，painter 便宜得多。
///
/// 位置由 `seed`（歌曲 id）决定：**同一首歌每次进来粒子位置一致**，
/// 换歌才换花样。否则每次重建都在跳，看着很乱。
class _AmbientPainter extends CustomPainter {
  _AmbientPainter({required this.mode, required this.tint, required this.seed});

  final MusicDustMode mode;
  final Color tint;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final isStars = mode == MusicDustMode.stars;
    final count = isStars ? 46 : 30;
    final rnd = _Lcg(seed == 0 ? 20240101 : seed);

    final paint = Paint()..style = PaintingStyle.fill;
    for (var i = 0; i < count; i++) {
      final x = rnd.next() * size.width;
      final y = rnd.next() * size.height;
      final base = rnd.next();
      // 星点更小更亮；浮尘更大更淡
      final r = isStars ? 0.6 + base * 1.1 : 1.2 + base * 2.2;
      final a = isStars ? 0.25 + base * 0.5 : 0.06 + base * 0.10;
      paint.color = (isStars ? Colors.white : tint).withValues(alpha: a);
      canvas.drawCircle(Offset(x, y), r, paint);

      // 星点加一点十字光芒（只给最亮的几颗，避免太花）
      if (isStars && base > 0.86) {
        final sp = Paint()
          ..color = Colors.white.withValues(alpha: a * 0.7)
          ..strokeWidth = 0.7;
        canvas.drawLine(Offset(x - r * 3, y), Offset(x + r * 3, y), sp);
        canvas.drawLine(Offset(x, y - r * 3), Offset(x, y + r * 3), sp);
      }
    }
  }

  @override
  bool shouldRepaint(_AmbientPainter old) =>
      old.mode != mode || old.tint != tint || old.seed != seed;
}

/// 轻量确定性随机（线性同余）。
///
/// 不用 `Random` 是因为它每次构造都要重新播种，而这里要的是
/// "同一个 seed 永远同一串数" —— 这样同首歌的粒子位置才稳定。
class _Lcg {
  _Lcg(int seed) : _s = (seed & 0x7FFFFFFF) | 1;
  int _s;

  double next() {
    _s = (_s * 1103515245 + 12345) & 0x7FFFFFFF;
    return _s / 0x7FFFFFFF;
  }
}
