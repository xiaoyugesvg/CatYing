import 'dart:math' as math;
import 'dart:async';
import 'dart:ui';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/player_manager.dart';
import '../theme/music_theme.dart';
import '../widgets/music_components.dart';
import 'player_settings_sheet.dart';
import '../services/library_store.dart';
import 'queue_page.dart';
import '../../common/theme.dart';

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

  /// 给**深底**用的强调色。
  ///
  /// 🔴 播放页底色**永远是深色**（每首歌的深色色调，亮度压到 0.20），
  /// 但 `MusicTheme.tint` 会跟着**全局明暗**走 ✗ →
  /// 全局用浅色主题时 `tint` 是个**暗色** ✗ → 用在深底上时
  /// **歌词（`:1223` 的画笔）、进度条、红心几乎看不见** ✗。
  /// 所以这里统一取"与白色混合后的浅色"✓（只用 `Colors.white`/`Color.lerp`，
  /// 不依赖别的 API —— `MusicAccent.tintLight` 是**实例** getter，静态用不了 ✗）。
  static Color get _darkTint =>
      Color.lerp(Colors.white, MusicTheme.tint, 0.35) ?? MusicTheme.tint;

  /// 封面取色得到的背景色（拿不到就用强调色）
  Color _tint = _darkTint;

  final _lyricScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    );
    // #18：氛围层（浮尘/星点）的脉冲时钟。
    //
    // ── ⚠️ 先说明能做到什么、做不到什么 ─────────────────────────
    // **做不到**：真正"跟随 bass 跳动"。那需要拿到音频频谱
    //   （FFT），而当前链路是 media_kit 直接把音频交给系统输出，
    //   Dart 侧拿不到 PCM 数据。要做必须动原生层，不是这一批的范围。
    //
    // **做到的是**：给粒子一个**呼吸般的节拍脉冲** ——
    //   半径/透明度随时间起伏、整体轻微上下浮动，
    //   暂停时脉冲也停（与 `_spin` 一起同步），
    //   于是"音乐在动 → 画面在动；暂停 → 画面静止"。
    // 观感上比原来完全静止的装饰好很多，且不假装是频谱。
    //
    // 周期 1.6s ≈ 中等速度歌曲的一拍半，呼吸感比较自然。
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
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
    _pulse.dispose();
    _lyricScroll.dispose();
    super.dispose();
  }

  /// #18：氛围层脉冲时钟（见 initState 里的说明）
  late final AnimationController _pulse;

  /// 上一次已处理的歌曲标识（用于"只在换歌时才重建/取色"）
  int _lastSongId = -1;

  /// 播放器变化回调。
  ///
  /// ── ⚠️ 这里原来是 `setState(() {}) + _extractTint()`，有两个问题 ──
  /// `MusicPlayerManager extends ChangeNotifier`，而 `notifyListeners()`
  /// 在**很多**地方被调用 —— 包括**每秒一次的 position 更新**。
  /// 于是：
  ///
  ///   #7  **每秒整页 setState 一次**。这页面里有封面旋转、歌词滚动、
  ///       进度条、氛围层（CustomPaint）—— 全在同一棵树里，
  ///       每秒重建一次纯属浪费。
  ///   #6  **每次变化都调一次 `_extractTint()`**。它内部虽然有 url 判断，
  ///       但每次都要跑一遍函数（还可能命中异步取色）。
  ///
  /// 而本页**已经**为高频项单独做了 `ValueListenableBuilder`：
  ///   position / duration / isPlaying / lyrics / lyricIndex / mode
  /// 所以这里真正需要重建的只剩 **`currentSong` 变了**（换歌）。
  ///
  /// 现在：只有歌曲标识变化时才 setState + 取色。
  /// position 每秒 tick 时这个回调直接 return，不再触发任何重建。
  void _onPlayerChanged() {
    if (!mounted) return;
    final song = player.currentSong;
    final id = song?.id ?? -1;
    if (id == _lastSongId) return; // 同一首歌（进度/缓冲等高频通知）→ 不重建
    _lastSongId = id;
    setState(() {});
    unawaited(_extractTint());
  }

  /// 黑胶旋转：播放时转，暂停时**减速停下**（#17）。
  ///
  /// 原来是 `_spin.stop()` —— **硬停**，像被谁按住了唱片。
  /// 真实黑胶的停转是慢慢减速的，所以这里改成
  /// `animateTo(下一个整圈)` + `Curves.decelerate`：
  /// 从当前角度平滑转到下一个整圈后自然停止（不会倒转、也不会突变）。
  void _syncSpin() {
    // #18：脉冲与唱片同步启停（暂停时画面静止，不空转耗电）
    if (player.isPlaying.value) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
    }
    if (player.isPlaying.value) {
      _spin.repeat();
    } else {
      // 从当前角度减速到"下一个整圈"，视觉上就是转完这一圈慢慢停住
      final v = _spin.value; // 0~1
      final target = v <= 0 ? 0.0 : 1.0;
      _spin.animateTo(
        target,
        duration: const Duration(milliseconds: 900),
        curve: Curves.decelerate,
      );
    }
  }

  /// 从封面图取主色做背景（Beans 的 CoverPalette 思路）。
  /// 失败就退回强调色 —— 不能让取色失败影响播放器可用。
  Future<void> _extractTint() async {
    final url = player.currentSong?.coverUrl;
    if (url == null || url.isEmpty) {
      if (mounted) setState(() => _tint = _darkTint);
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
      if (mounted) setState(() => _tint = _darkTint);
    }
  }

  /// 按歌曲 id 推一个**深色调**（稳定的伪随机，理由见 `build` 里的注释）。
  ///
  /// 亮度压到 0.20：播放页的文字/图标都是**白色系**（约 40 处 `Colors.white`），
  /// 底色必须够深才读得清 —— 所以这是"深色调"而不是彩色。
  static Color _songTone(int id) {
    final hue = ((id.abs() * 2654435761) % 360).toDouble();
    return HSLColor.fromAHSL(1, hue, 0.42, 0.20).toColor();
  }

  @override
  Widget build(BuildContext context) {
    final song = player.currentSong;
    if (song == null) {
      return Scaffold(
        backgroundColor: Colors.transparent,
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
              style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontBody)),
        ),
      );
    }

    // ── 随机色调（**每首歌一个，刻意不跟外观/主题**）────────────────
    // 用户要求：播放器不要一直是黑的 → 改成"随机色调"。
    // 但**不用真随机**：真随机每次重建都会换色，页面会闪。
    // 这里用 `song.id` 推色相 → 同一首歌每次进来颜色一致，换歌才变 ✓
    final tone = _songTone(song.id);

    return Scaffold(
      backgroundColor: tone,
      body: Stack(
        children: [
          // 背景：**该歌的随机色调** + 封面主色渐变（原为黑底 + 主色）
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    // 顶部：随机色调与封面主色混一点，更有层次
                    Color.lerp(tone, _tint, 0.45)!,
                    // 底部：把色调压暗（原来是纯黑，现在是"这一首的颜色"）
                    Color.lerp(tone, Colors.black, 0.55)!,
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
                  // #18：用 AnimatedBuilder 监听脉冲时钟重绘。
                  // 只重绘这一层 CustomPaint —— 不会带动整页重建
                  //（这也是 #7 想达到的效果：高频变化只影响最小范围）。
                  child: AnimatedBuilder(
                    animation: _pulse,
                    builder: (context, ___) => CustomPaint(
                      painter: _AmbientPainter(
                        mode: mode,
                        tint: _tint,
                        seed: player.currentSong?.id ?? 0,
                        pulse: _pulse.value,
                      ),
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

  /// #16：音量面板
  ///
  /// 系统音量键调的是**设备音量**；这里调的是**播放器自身音量**
  /// （`MusicPlayerManager.setVolume`，0~100），两者互不影响。
  /// 用 `player.volume` 作为 ValueListenable 监听，滑动即时生效。
  void _showVolumeSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('音量',
                  style: TextStyle(
                      color: MusicTheme.label,
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.volume_mute_rounded,
                      size: 18, color: MusicTheme.secondary),
                  Expanded(
                    child: ValueListenableBuilder<double>(
                      valueListenable: player.volume,
                      builder: (_, v, __) => Slider(
                        value: v.clamp(0, 100),
                        max: 100,
                        activeColor: MusicTheme.tint,
                        inactiveColor: MusicTheme.secondary
                            .withValues(alpha: 0.3),
                        onChanged: (nv) => player.setVolume(nv),
                      ),
                    ),
                  ),
                  Icon(Icons.volume_up_rounded,
                      size: 18, color: MusicTheme.secondary),
                ],
              ),
              Text(
                '提示：这里调的是播放器音量；手机侧边键调的是系统音量。',
                style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote),
              ),
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );
  }

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
                      fontSize: AppTheme.fontHeadline,
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
                      fontSize: AppTheme.fontFootnote),
                ),
              ],
            ),
          ),
          // #11：播放队列入口。
          // 原来队列只在 manager 内部存在，用户看不到"接下来播什么"。
          IconButton(
            tooltip: '播放队列',
            icon: const Icon(Icons.queue_music_rounded,
                color: Colors.white, size: 24),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const MusicQueuePage(),
              ),
            ),
          ),
          // #16：音量入口。
          //
          // `MusicPlayerManager` 一直有 `volume`（0~100）和 `setVolume()`，
          // 但**播放器页没有任何入口** —— 功能存在却用不到，
          // 用户想调音量只能按物理键（那调的是系统音量，不是播放器音量）。
          IconButton(
            icon: Icon(
              player.volume.value <= 0
                  ? Icons.volume_off_rounded
                  : (player.volume.value < 50
                      ? Icons.volume_down_rounded
                      : Icons.volume_up_rounded),
              color: Colors.white,
              size: 24,
            ),
            onPressed: () => _showVolumeSheet(),
          ),
          IconButton(
            icon: const Icon(Icons.more_horiz, color: Colors.white, size: 24),
            onPressed: () => showSongActions(context, song),          ),
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
              // 封面下方：自动显示当前歌词行（滚动更新）；无歌词时给提示。
              SizedBox(height: 60, child: _coverLyricPreview()),
            ],
          ),
        );
      },
    );
  }

  /// 封面下方的歌词预览 —— 显示当前正在唱的行（最多 2 行，超出省略）。
  /// 点击封面任意处（整块 Expanded 的 GestureDetector）进入全屏歌词。
  Widget _coverLyricPreview() {
    return ValueListenableBuilder<List<LyricLine>>(
      valueListenable: player.lyrics,
      builder: (context, lines, __) {
        if (lines.isEmpty) {
          return Align(
            alignment: Alignment.center,
            child: Text(
              '轻点封面查看全部歌词',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.35),
                  fontSize: AppTheme.fontCaption),
            ),
          );
        }
        return ValueListenableBuilder<int>(
          valueListenable: player.lyricIndex,
          builder: (context, idx, ___) {
            final li = (idx < 0 ? 0 : idx).clamp(0, lines.length - 1);
            final line = lines[li];
            final text = (line.translation != null && line.translation!.isNotEmpty)
                ? '${line.text} · ${line.translation}'
                : line.text;
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: Align(
                key: ValueKey('lyric-preview-$li-$text'),
                alignment: Alignment.center,
                child: Text(
                  text,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.92),
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                  ),
                ),
              ),
            );
          },
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
                color: Colors.white, fontSize: AppTheme.fontCaption, fontWeight: FontWeight.w600),
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
                // V9：原来是 `MusicTheme.isDark ? 深 : 浅`，而本页底色**恒为黑** ——
                // 音乐选浅色时盘面反而变亮，成了"黑底上放一块更亮的盘"。
                // 固定取原**深色档**的值，与整页的黑底/白字自洽。
                color: const Color(0xFF141416),
                // 唱片纹路：几道同心圆描边
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.06),
                    width: 0.8),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
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
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF0A0A0C),
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
                  borderRadius: BorderRadius.circular(10),
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
                // 中心孔（CD 的标志性特征，缩小版）
                Container(
                  width: 28,
                  height: 28,
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

  // ── 封面形态 3：方形 —— 统一改成圆形旋转 CD 盘（原方形形态废弃）──
  Widget _squareCover(dynamic song) {
    return SizedBox(
      width: 280,
      height: 280,
      child: Stack(
        alignment: Alignment.center,
        children: [
          _glow(280, 0.35),
          RotationTransition(
            turns: _spin,
            child: Stack(
              alignment: Alignment.center,
              children: [
                ClipOval(
                  child:
                      CoverImage(url: song.coverUrl, size: 244, circle: true),
                ),
                // 中心孔
                Container(
                  width: 28,
                  height: 28,
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
                child: CachedNetworkImage(
                imageUrl: url,
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
            // 中间小卡也改成圆形旋转 CD 盘
            child: RotationTransition(
              turns: _spin,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  ClipOval(
                    child: CoverImage(
                        url: song.coverUrl, size: 168, circle: true),
                  ),
                  Container(
                    width: 20,
                    height: 20,
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
                        fontSize: AppTheme.fontBody)),
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
                      _buildLyricText(line, active, li, idx),
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
                              fontSize: AppTheme.fontFootnote),
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

  /// 歌词行渲染（#9：支持逐字高亮）。
  ///
  /// ── 三种情况 ──────────────────────────────────────────────────
  ///   1. 非当前行 → 普通 Text（灰）
  ///   2. 当前行但没有逐字数据（普通 LRC）→ 普通 Text（白，整行高亮）
  ///   3. 当前行**且有逐字数据** → 已唱部分主题色、未唱部分白色，
  ///      边界由 `charIndexAt` 按时间比例算到**字内部**
  ///
  /// ── 实现为什么用两段 TextSpan（而不是 ShaderMask/WidgetSpan）──
  /// `WidgetSpan` 会参与布局约束，包在歌词上会**改变换行行为**
  /// （长歌词本该折两行，包了之后可能不折或溢出）。
  /// 而 `charIndexAt` 已经会按时间比例切到**字内部**
  /// （`(w.text.length * ratio).round()`），中文单字即一字符，
  /// 于是"正在唱的字逐渐填色"这个效果天然就有了，
  /// 不需要额外的 ShaderMask。
  Widget _buildLyricText(LyricLine line, bool active, int li, int idx) {
    final baseStyle = TextStyle(
      color: active
          ? Colors.white
          : Colors.white.withValues(alpha: li < idx ? 0.45 : 0.3),
      fontSize: active ? 17 : 15,
      fontWeight: active ? FontWeight.w600 : FontWeight.w400,
      height: 1.25,
    );

    // 情况 1、2：不需要逐字
    if (!active || !line.hasWords) {
      return Text(
        line.text,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: baseStyle,
      );
    }

    // 情况 3：逐字。position 变化要实时重绘，所以在这里再挂一层监听。
    return ValueListenableBuilder<Duration>(
      valueListenable: player.position,
      builder: (context, pos, __) {
        // ⚠️ 偏移必须与 `player.lyricIndex` 的计算一致
        //（`_posSub` 里同样加了 lyricOffset），否则高亮会和"当前行"错位。
        final shifted = pos + Duration(milliseconds: player.lyricOffset.value);
        final n = line.charIndexAt(shifted).clamp(0, line.text.length);
        final sung = line.text.substring(0, n);
        final rest = line.text.substring(n);

        return Text.rich(
          TextSpan(
            style: baseStyle,
            children: [
              if (sung.isNotEmpty)
                TextSpan(
                  text: sung,
                  style: baseStyle.copyWith(
                    color: MusicTheme.tint,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              if (rest.isNotEmpty) TextSpan(text: rest),
            ],
          ),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
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
                                fontSize: AppTheme.fontCaption)),
                        Text(_fmt(totalMs.toDouble()),
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.55),
                                fontSize: AppTheme.fontCaption)),
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
        // #5：收藏（红心）。原来音乐模块**完全没有收藏功能** ——
        // 听到喜欢的歌没法存，下次只能靠记忆搜。
        // 用 ListenableBuilder 监听 store，点一下立刻变实心。
        ListenableBuilder(
          listenable: MusicLibraryStore.instance,
          builder: (context, _) {
            final song = player.currentSong;
            final fav = song != null &&
                MusicLibraryStore.instance.isFavorite(song);
            if (song == null) return const SizedBox.shrink();
            return _actionBtn(
              icon: fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              label: fav ? '已收藏' : '收藏',
              // 收藏时用主题色，未收藏保持默认灰白
              color: fav ? MusicTheme.tint : null,
              onTap: () {
                // 用 unawaited 包一层：onTap 要求 VoidCallback，
                // 不能直接给 async 闭包（返回 Future）。
                unawaited(() async {
                  final now =
                      await MusicLibraryStore.instance.toggleFavorite(song);
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(now ? '已加入我的收藏' : '已取消收藏'),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                }());
              },
            );
          },
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

    /// 图标/文字颜色覆盖（#5：已收藏时用主题色）。
    /// 为 null 时用默认的"白色半透明"，与其它按钮一致。
    Color? color,
  }) {
    final c = color;
    final iconColor =
        c?.withValues(alpha: 0.95) ?? Colors.white.withValues(alpha: 0.75);
    final labelColor =
        c?.withValues(alpha: 0.85) ?? Colors.white.withValues(alpha: 0.45);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: iconColor, size: 22),
            const SizedBox(height: 3),
            Text(label, style: TextStyle(color: labelColor, fontSize: AppTheme.fontCaption)),
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
  _AmbientPainter({
    required this.mode,
    required this.tint,
    required this.seed,
    this.pulse = 0,
  });

  final MusicDustMode mode;
  final Color tint;
  final int seed;

  /// #18：节拍脉冲 0~1（由 `_pulse` 控制器给出，0→1→0 往返）。
  ///
  /// ⚠️ 它**不是音频频谱**（见 `initState` 里那段说明），
  /// 只是一个让粒子"呼吸"的时间函数。
  /// 位置仍然只由 [seed] 决定（同首歌粒子位置稳定），
  /// `pulse` 只影响**半径/透明度/位移**，所以不会"每次重建都在跳"。
  final double pulse;

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

      // #18：脉冲 —— 每颗粒子按自身相位偏移，错开起伏（不会整片一起闪）
      // phase 只由 base 决定（稳定），pulse 提供时间变化。
      final phase = (base + pulse) * 6.28318530718; // 2π
      final wobble = 0.5 + 0.5 * math.sin(phase); // 0~1
      final rP = r * (1.0 + (isStars ? 0.35 : 0.55) * wobble);
      final aP = a * (0.65 + 0.35 * wobble);
      // 轻微上下浮动（幅度按粒子大小走，大颗粒飘得明显些）
      final dy = math.sin(phase * 0.5) * (isStars ? 1.2 : 2.4);

      paint.color = (isStars ? Colors.white : tint).withValues(alpha: aP);
      canvas.drawCircle(Offset(x, y + dy), rP, paint);

      // 星点加一点十字光芒（只给最亮的几颗，避免太花）
      if (isStars && base > 0.86) {
        final sp = Paint()
          ..color = Colors.white.withValues(alpha: aP * 0.7)
          ..strokeWidth = 0.7;
        canvas.drawLine(Offset(x - r * 3, y), Offset(x + r * 3, y), sp);
        canvas.drawLine(Offset(x, y - r * 3), Offset(x, y + r * 3), sp);
      }
    }
  }

  @override
  bool shouldRepaint(_AmbientPainter old) =>
      old.mode != mode ||
      old.tint != tint ||
      old.seed != seed ||
      old.pulse != pulse;
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
