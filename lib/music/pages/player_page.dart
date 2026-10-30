import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/pages/player_settings_sheet.dart';
import 'package:tvbox/music/pages/queue_page.dart';
import 'package:tvbox/music/services/library_store.dart';
import 'package:tvbox/music/services/player_manager.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/music/widgets/music_components.dart';
import 'package:tvbox/music/widgets/music_sheet.dart';

/// 全屏播放器 —— 2026-10-30 按主流音乐 App 的骨架整体重做。
///
/// ── 这一版对齐的是什么 ───────────────────────────────────────────
/// 参考 Apple Music / Spotify / 网易云三家的**共识结构**（不是抄某一家）：
///
/// ```
///  ⌄           6 / 24           ⋯      顶栏（玻璃圆钮 + 位置胶囊）
///
///          ┌─────────────┐
///          │             │             大封面（随播放状态轻微缩放）
///          │   封面/歌词  │             点一下 ⇄ 全屏歌词
///          │             │
///          └─────────────┘
///             当前歌词三行
///
///  歌名（22 粗）                      ♥   左对齐标题 + 收藏
///  歌手 · 音质
///
///  ━━━━━●───────────────                胶囊进度条（拖动才出圆点）
///  1:23                      3:45
///
///   ⟳    ⏮    ( ▶ )    ⏭    ☰        播放行
///
///   ⟲10  🔊  📄  ⟳10  ⚙              动作行（纯图标，无小字）
/// ```
///
/// ── 与旧版的结构差异（为什么改）────────────────────────────────
///   · 旧版：标题**居中**在顶栏下方、进度条在**最底下**、收藏/音量/设置混在
///     7 个图标里。视觉重心散、底部三行读不出主次。
///   · 新版：标题**左对齐**贴着封面（信息与封面成一组）、进度条紧接标题
///     （"这首歌播到哪"紧跟"这首歌是谁"）、主播放键居中放大、
///     低频动作沉到最下一行。这就是主流音乐 App 的视觉层级。
///   · 背景：纯色调渐变 → **封面模糊底图 + 色调 + 可读性遮罩**三层叠加，
///     有了照片的层次感，同时保证白字始终压得住。
///   · 进度条：Material `Slider`（有默认的拇指/轨道高度/最小触控宽度）
///     → **自绘胶囊**，圆角与整体一致，拖动时才浮出白色圆点。
///
/// ── 保留的旧能力（一个都没删）──────────────────────────────────
///   · 四种封面形态（黑胶 / CD / 方形 / 模糊大图）+ 唱臂落针 + 唱片纹路
///   · 浮尘 / 星点氛围层 + 节拍脉冲
///   · 逐字歌词高亮 + 翻译 + 居中滚动
///   · 封面取色、音量面板、播放器设置、队列、收藏、歌曲更多操作
///
/// 没做的（Beans 有、这里略）：音效均衡器、DJ 可视化、评论、
/// 下载、歌单编辑、分享 —— 这些依赖账号或额外依赖，按需求裁剪。

/// 底部控制区（标题 + 进度 + 播放行 + 动作行）占的高度。
///
/// **内容区必须按这个值避让**，否则歌词末行会被控制栏盖住。
///
/// ⚠️ 用**硬编码**（不是自动测量）—— 稳定、可预测；
/// 自动测量会在控制栏内容变化时抖动。
///
/// 2026-10-30 重做后由四段组成：标题 64 + 进度 46 + 播放行 72 + 动作行 44
/// + 间距 ≈ 230。
const double _kDeckInset = 230;

/// 歌词字号 / 行高 —— **必须只有一处定义**。
///
/// 🔴 历史坑：以前字号写在 `_buildLyricText`（17/15），行高写在 itemBuilder
/// （`44` 与 `(17*1.25*2)+12*1.4` 各写过一次），滚动步长里又写死一次常数。
/// 三处一旦不同步，表现就是"越滚越偏、长歌词溢出黄条"。
/// 现在全部走下面这组常量 + [_lyricExtent]，改字号不会再漏。
const double _kLyricActiveSize = 20;
const double _kLyricIdleSize = 15;
const double _kLyricLineHeight = 1.32;

/// 单行歌词格子的高度（激活行带翻译时更高）。
double _lyricExtent({required bool active, required bool hasTranslation}) =>
    (active ? _kLyricActiveSize : _kLyricIdleSize) * _kLyricLineHeight * 2 +
    (hasTranslation ? AppTheme.fontFootnote * 1.4 : 0);

class MusicPlayerPage extends StatefulWidget {
  const MusicPlayerPage({super.key});

  /// **全屏播放器当前是否打开**（供全局底栏判断要不要让位）。
  ///
  /// ── 🔴 为什么需要它（用户实测截图：播放器底部被盖住）────────────
  /// 全局 `MusicBottomChrome`（迷你条 + 导航栏）挂在 `app.dart` 的
  /// Stack 里、**在 `out`（Navigator）之后** → 它盖在**所有**路由之上，
  /// 包括这个全屏播放器。
  ///
  /// 而播放器**自己**有一条底部操作栏 ——
  /// 于是被迷你条 + 导航栏**压在下面，既看不清也点不到** ✗
  ///
  /// 而且导航栏出现在播放器上本身**语义就不对**：播放器是全屏模态页，
  /// 底部该是"播放控制"，不是"切模块 tab"。
  ///
  /// 所以：播放器打开时，全局底栏**整个隐藏**（见 `MusicBottomChrome`）。
  ///
  /// ⚠️ 用 `ValueNotifier` 而不是裸 `bool`：底栏那层是
  /// `AnimatedBuilder` + `Listenable.merge`，裸 bool 变了**不会触发重建** → 白改。
  static final ValueNotifier<bool> isOpen = ValueNotifier<bool>(false);

  @override
  State<MusicPlayerPage> createState() => _MusicPlayerPageState();
}

class _MusicPlayerPageState extends State<MusicPlayerPage>
    // 必须是 TickerProvider 的**复数版**：本页有 _spin(唱片转动) / _arm(落针) /
    // _pulse(氛围脉冲) 三个 AnimationController，SingleTickerProviderStateMixin
    // 只允许创建一次 ticker，第二个 controller 起就会在 debug 下直接抛断言。
    with TickerProviderStateMixin {
  final player = MusicPlayerManager.instance;

  /// 封面旋转动画
  late final AnimationController _spin;

  /// 黑胶唱臂落针动画（0 = 抬起待机，1 = 落到盘面播放）。
  ///
  /// 之前唱臂是**纯静态**摆件（参考图角度写死 -0.38），用户反馈"指针不能动吗"。
  /// 现在播放时落针、暂停时抬臂 —— 与真实唱机一致，也是黑胶形态最有辨识度的一处动态。
  late final AnimationController _arm;

  /// #18：氛围层（浮尘/星点）的脉冲时钟。
  ///
  /// ── ⚠️ 先说明能做到什么、做不到什么 ─────────────────────────
  /// **做不到**：真正"跟随 bass 跳动"。那需要拿到音频频谱（FFT），
  ///   而当前链路是 media_kit 直接把音频交给系统输出，Dart 侧拿不到 PCM。
  ///
  /// **做到的是**：给粒子一个**呼吸般的节拍脉冲** ——
  ///   半径/透明度随时间起伏、整体轻微上下浮动，
  ///   暂停时脉冲也停（与 `_spin` 一起同步）。
  /// 观感上比完全静止的装饰好很多，且不假装是频谱。
  late final AnimationController _pulse;

  /// true = 显示歌词；false = 显示封面
  bool showLyric = false;

  /// 拖动进度时的临时值（毫秒）。null = 没在拖。
  double? _dragging;

  /// 给**深底**用的强调色。
  ///
  /// 🔴 播放页底色**永远是深色**（每首歌的深色色调 + 遮罩），
  /// 但 `MusicTheme.tint` 会跟着**全局明暗**走 ✗ →
  /// 全局用浅色主题时 `tint` 是个**暗色** ✗ → 用在深底上时
  /// **歌词高亮、进度条、红心几乎看不见** ✗。
  /// 所以这里统一取"与白色混合后的浅色"✓
  static Color get _darkTint =>
      Color.lerp(Colors.white, MusicTheme.tint, 0.35) ?? MusicTheme.tint;

  /// 封面取色得到的背景色（拿不到就用强调色）
  Color _tint = _darkTint;

  final _lyricScroll = ScrollController();

  /// 上一次已处理的歌曲标识（用于"只在换歌时才重建/取色"）
  int _lastSongId = -1;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    );
    // 落针 520ms：比唱片转动快得多，符合"手臂落下"的真实观感
    _arm = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 520),
    );
    // 周期 1.6s ≈ 中等速度歌曲的一拍半，呼吸感比较自然
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    // 告诉全局底栏"让位"（见 `MusicPlayerPage.isOpen` 的说明）
    MusicPlayerPage.isOpen.value = true;
    showLyric = MusicPlayerSkin.instance.showLyricFirst.value;
    player.addListener(_onPlayerChanged);
    player.isPlaying.addListener(_syncSpin);
    _syncSpin();
    unawaited(_extractTint());
  }

  @override
  void dispose() {
    // 关掉播放器 → 全局底栏恢复显示
    MusicPlayerPage.isOpen.value = false;
    player.removeListener(_onPlayerChanged);
    player.isPlaying.removeListener(_syncSpin);
    _spin.dispose();
    _arm.dispose();
    _pulse.dispose();
    _lyricScroll.dispose();
    super.dispose();
  }

  /// 播放器变化回调。
  ///
  /// ── ⚠️ 这里原来是 `setState(() {}) + _extractTint()`，有两个问题 ──
  /// `MusicPlayerManager extends ChangeNotifier`，而 `notifyListeners()`
  /// 在**很多**地方被调用 —— 包括**每秒一次的 position 更新**。
  /// 于是：
  ///   #7  **每秒整页 setState 一次**。这页面里有封面旋转、歌词滚动、
  ///       进度条、氛围层（CustomPaint）—— 全在同一棵树里。
  ///   #6  **每次变化都调一次 `_extractTint()`**。
  ///
  /// 而本页**已经**为高频项单独做了 `ValueListenableBuilder`：
  ///   position / duration / isPlaying / lyrics / lyricIndex / mode / volume
  /// 所以这里真正需要重建的只剩 **`currentSong` 变了**（换歌）。
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
  /// `animateTo(下一个整圈)` + `Curves.decelerate`。
  void _syncSpin() {
    // 落针/抬臂：播放时把唱臂压到盘面，暂停时抬回待机位。
    if (player.isPlaying.value) {
      _arm.forward();
    } else {
      _arm.reverse();
    }
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

  /// 按歌曲 id 推一个**深色调**（稳定的伪随机）。
  ///
  /// 用户要求"播放器不要一直是黑的 → 每首歌一个色调"。
  /// 但**不用真随机**：真随机每次重建都会换色，页面会闪。
  /// 这里用 `song.id` 推色相 → 同一首歌每次进来颜色一致，换歌才变 ✓
  ///
  /// 亮度压到 0.20：播放页的文字/图标都是**白色系**，
  /// 底色必须够深才读得清 —— 所以这是"深色调"而不是彩色。
  static Color _songTone(int id) {
    final hue = ((id.abs() * 2654435761) % 360).toDouble();
    return HSLColor.fromAHSL(1, hue, 0.42, 0.20).toColor();
  }

  @override
  Widget build(BuildContext context) {
    final song = player.currentSong;
    if (song == null) return _emptyScaffold();

    final tone = _songTone(song.id);

    return Scaffold(
      backgroundColor: tone,
      body: Stack(
        children: [
          _backdrop(song, tone),
          _ambientLayer(),
          SafeArea(
            child: Column(
              children: [
                _topBar(),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => showLyric = !showLyric),
                    // ⚠️ 必须用 KeyedSubtree 区分两个 child：
                    // 封面和歌词的根 widget 都是 ValueListenableBuilder，
                    // AnimatedSwitcher 按 runtimeType+key 判定"是否同一个"，
                    // 不加 key 它认为没变 → 切换时**没有过渡动画**。
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: ScaleTransition(
                          scale: Tween<double>(begin: 0.97, end: 1)
                              .animate(anim),
                          child: child,
                        ),
                      ),
                      child: KeyedSubtree(
                        key: ValueKey(showLyric ? 'lyric' : 'cover'),
                        child: showLyric ? _lyricView() : _coverView(song),
                      ),
                    ),
                  ),
                ),
                _deck(song),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 背景
  // ============================================================

  /// 三层背景：**色调渐变 → 封面模糊大图 → 可读性遮罩**。
  ///
  /// 旧版只有第一层（纯色调渐变），观感是"一块有颜色的板"；
  /// 加上模糊封面之后才有音乐 App 那种"整页泡在这首歌里"的感觉。
  ///
  /// 性能：整层包在 `RepaintBoundary` 里，且**不参与任何动画**
  ///（氛围层是另一层）→ 模糊只算一次，之后直接复用图层。
  /// 模糊的 sigma 取 36（不是 60+）：再大在低端机上一次就要几十毫秒。
  Widget _backdrop(Song song, Color tone) {
    final url = (song.coverUrl ?? '').trim();
    return Positioned.fill(
      child: RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ① 底色：这首歌的色调 → 封面主色 → 近黑
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color.lerp(tone, _tint, 0.42)!,
                    Color.lerp(tone, Colors.black, 0.55)!,
                    Colors.black,
                  ],
                  stops: const [0.0, 0.62, 1.0],
                ),
              ),
            ),
            // ② 封面模糊大图（放大 1.2 倍，避免模糊把边缘吃出透明边）
            if (url.isNotEmpty)
              Opacity(
                opacity: 0.42,
                child: Transform.scale(
                  scale: 1.2,
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 36, sigmaY: 36),
                    child: CachedNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            // ③ 可读性遮罩：顶部略压、中部放开、底部压深
            //    （底部压深是为了让控制区的白字在任何封面上都读得清）
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.22),
                    Colors.black.withValues(alpha: 0.08),
                    Colors.black.withValues(alpha: 0.62),
                  ],
                  stops: const [0.0, 0.42, 1.0],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 浮尘 / 星点氛围层 —— 由设置的"背景氛围"决定。
  Widget _ambientLayer() {
    return Positioned.fill(
      child: ValueListenableBuilder<MusicDustMode>(
        valueListenable: MusicPlayerSkin.instance.dustMode,
        builder: (context, mode, __) {
          if (mode == MusicDustMode.none) return const SizedBox.shrink();
          return IgnorePointer(
            // 只重绘这一层 CustomPaint —— 不会带动整页重建
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
    );
  }

  // ============================================================
  // 顶栏
  // ============================================================

  /// 顶栏：`⌄`（收起）· 播放位置胶囊 `N / M` · `⋯`（歌曲更多操作）。
  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
      child: Row(
        children: [
          _glassIcon(
            icon: Icons.keyboard_arrow_down_rounded,
            tooltip: '收起',
            size: 24,
            onTap: () => Navigator.maybePop(context),
          ),
          Expanded(child: Center(child: _positionChip())),
          _glassIcon(
            icon: Icons.more_horiz_rounded,
            tooltip: '更多操作',
            onTap: () {
              final s = player.currentSong;
              if (s != null) showSongActions(context, s);
            },
          ),
        ],
      ),
    );
  }

  /// `6 / 24` —— 玻璃胶囊。队列为空时不占位。
  Widget _positionChip() {
    final q = player.queue;
    if (q.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Text(
        '${player.currentIndex + 1} / ${q.length}',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.82),
          fontSize: AppTheme.fontCaption,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  /// 玻璃圆钮 —— 顶栏 / 标题区共用。
  Widget _glassIcon({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    double size = 20,
    double box = 38,
  }) {
    return Tooltip(
      message: tooltip,
      child: _Pressable(
        onTap: onTap,
        scale: 0.88,
        child: Container(
          width: box,
          height: box,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.12),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.16),
              width: 0.8,
            ),
          ),
          child: Icon(icon, color: Colors.white, size: size),
        ),
      ),
    );
  }

  // ============================================================
  // 底部控制区
  // ============================================================

  /// 底部四段（标题 → 进度 → 播放行 → 动作行）。
  ///
  /// 整块压一层"上透明、下微黑"的渐变：封面上半部再亮，
  /// 控制区的白字也不会糊。
  Widget _deck(Song song) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black.withValues(alpha: 0.30),
          ],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _titleBlock(song),
          _progressBar(),
          const SizedBox(height: 2),
          _playRow(),
          const SizedBox(height: 2),
          _actionRow(),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  /// 歌名（22 粗）+ 歌手 · 音质，**左对齐**；右侧收藏。
  ///
  /// 旧版是居中排版。改成左对齐的原因：居中的长歌名一旦超宽，
  /// 两侧都留白、看着像"没对齐"；左对齐能撑满宽度，也更接近
  /// Apple Music / Spotify 的信息层级（标题是内容，不是标语）。
  Widget _titleBlock(Song song) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  song.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        song.artists.isEmpty ? song.album : song.artists,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.62),
                          fontSize: AppTheme.fontSubhead,
                        ),
                      ),
                    ),
                    if (song.isVIP) ...[
                      const SizedBox(width: 6),
                      const VipBadge(),
                    ],
                    const SizedBox(width: 8),
                    _qualityChip(),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          _favoriteButton(song),
        ],
      ),
    );
  }

  /// 音质 / 音源 小胶囊（有才显示）
  Widget _qualityChip() {
    return ValueListenableBuilder<String>(
      valueListenable: player.qualityText,
      builder: (context, q, _) {
        if (q.isEmpty) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            q,
            style: const TextStyle(
              color: Colors.white,
              fontSize: AppTheme.fontCaption,
              fontWeight: FontWeight.w600,
            ),
          ),
        );
      },
    );
  }

  /// 收藏（红心）—— 从旧的 7 图标动作行里提出来，放到标题右侧。
  ///
  /// 理由：收藏是**对这首歌**的动作，不是"播放控制"，
  /// 和歌名放一起语义最近；也符合主流音乐 App 的放置习惯。
  Widget _favoriteButton(Song song) {
    return ListenableBuilder(
      listenable: MusicLibraryStore.instance,
      builder: (context, _) {
        final fav = MusicLibraryStore.instance.isFavorite(song);
        return _Pressable(
          onTap: () => unawaited(_toggleFavorite(song)),
          scale: 0.86,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            width: 42,
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fav
                  ? _darkTint.withValues(alpha: 0.22)
                  : Colors.white.withValues(alpha: 0.10),
              border: Border.all(
                color: fav
                    ? _darkTint.withValues(alpha: 0.55)
                    : Colors.white.withValues(alpha: 0.14),
                width: 0.9,
              ),
            ),
            child: Icon(
              fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              // 收藏时用深底专用强调色（`MusicTheme.tint` 在全局浅色下是暗色）
              color: fav ? _darkTint : Colors.white,
              size: 21,
            ),
          ),
        );
      },
    );
  }

  Future<void> _toggleFavorite(Song song) async {
    final now = await MusicLibraryStore.instance.toggleFavorite(song);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(now ? '已加入我的收藏' : '已取消收藏'),
        duration: const Duration(seconds: 1),
      ),
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
            final frac =
                totalMs > 0 ? (posMs / totalMs).clamp(0.0, 1.0) : 0.0;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: Column(
                children: [
                  _CapsuleProgress(
                    fraction: frac,
                    dragging: _dragging != null,
                    tint: _tint,
                    onSeek: (f) => setState(() => _dragging = f * totalMs),
                    onSeekEnd: (f) {
                      if (totalMs > 0) {
                        player.seek(
                            Duration(milliseconds: (f * totalMs).round()));
                      }
                      setState(() => _dragging = null);
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _timeText(_fmt(posMs)),
                        _timeText(_fmt(totalMs.toDouble())),
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

  /// 时间文字：等宽数字（`tabularFigures`）——
  /// 否则 1:23 → 1:41 时"3"和"4"宽度不同，数字会左右轻微跳动。
  Widget _timeText(String t) {
    return Text(
      t,
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.55),
        fontSize: AppTheme.fontCaption,
        fontWeight: FontWeight.w500,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }

  String _fmt(double ms) {
    final t = (ms / 1000).round();
    return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
  }

  // ============================================================
  // 播放控制
  // ============================================================

  /// 播放行：模式 · 上一首 · 大播放键 · 下一首 · 队列。
  Widget _playRow() {
    return SizedBox(
      height: 72,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          // 播放模式（列表循环 / 单曲循环 / 随机）
          ValueListenableBuilder<PlayMode>(
            valueListenable: player.mode,
            builder: (context, mode, _) {
              final (icon, label) = switch (mode) {
                PlayMode.list => (Icons.repeat_rounded, '列表循环'),
                PlayMode.single => (Icons.repeat_one_rounded, '单曲循环'),
                PlayMode.shuffle => (Icons.shuffle_rounded, '随机播放'),
              };
              // `setState(player.cycleMode)` —— 直接传 tearoff，
              // 不需要 `() => setState(() => ...)` 这层空转的闭包
              return _plainIcon(icon, label, () => setState(player.cycleMode),
                  size: 22);
            },
          ),
          _plainIcon(Icons.skip_previous_rounded, '上一首', player.previous,
              size: 34),
          _bigPlayButton(),
          _plainIcon(Icons.skip_next_rounded, '下一首', player.next, size: 34),
          _plainIcon(Icons.queue_music_rounded, '播放队列', _openQueue, size: 22),
        ],
      ),
    );
  }

  void _openQueue() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'music:page'),
        builder: (_) => const MusicQueuePage(),
      ),
    );
  }

  /// 大播放键：**强调色渐变实心圆 + 光晕**，按下去有轻微回弹。
  ///
  /// 前景色按底色亮度自动取黑/白 —— 浅色调下白图标会看不清。
  Widget _bigPlayButton() {
    final fg = _tint.computeLuminance() > 0.62 ? Colors.black87 : Colors.white;
    return _Pressable(
      onTap: player.toggle,
      scale: 0.92,
      child: Container(
        width: 70,
        height: 70,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color.lerp(_tint, Colors.white, 0.22)!, _tint],
          ),
          boxShadow: [
            BoxShadow(
              color: _tint.withValues(alpha: 0.45),
              blurRadius: 26,
              spreadRadius: 2,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ValueListenableBuilder<bool>(
          valueListenable: player.isPlaying,
          builder: (context, playing, _) => AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, anim) =>
                ScaleTransition(scale: anim, child: child),
            child: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              key: ValueKey(playing),
              color: fg,
              size: 36,
            ),
          ),
        ),
      ),
    );
  }

  /// 纯图标按钮（无文字标签，只留 tooltip）—— 播放行 / 动作行共用。
  Widget _plainIcon(IconData icon, String tooltip, VoidCallback onTap,
      {Color? color, double size = 26}) {
    return Tooltip(
      message: tooltip,
      child: _Pressable(
        onTap: onTap,
        scale: 0.84,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(
            icon,
            color: color ?? Colors.white.withValues(alpha: 0.92),
            size: size,
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 底部动作栏
  // ============================================================

  /// 动作行（纯图标、**不带小字**）：
  /// 快退10s · 音量 · 歌词/封面 · 快进10s · 播放器设置。
  ///
  /// 收藏移到标题区、队列移到播放行、更多操作移到顶栏 ——
  /// 这一行只留"跟当前这首歌的播放体验直接相关"的五项。
  Widget _actionRow() {
    return SizedBox(
      height: 44,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _plainIcon(Icons.replay_10_rounded, '快退 10 秒',
              () => player.seekBy(const Duration(seconds: -10)),
              size: 22),
          ValueListenableBuilder<double>(
            valueListenable: player.volume,
            builder: (context, v, _) => _plainIcon(
              v <= 0
                  ? Icons.volume_off_rounded
                  : (v < 50
                      ? Icons.volume_down_rounded
                      : Icons.volume_up_rounded),
              '音量',
              _showVolumeSheet,
              size: 22,
            ),
          ),
          // 封面 ⇄ 歌词
          _plainIcon(
            showLyric ? Icons.album_rounded : Icons.lyrics_rounded,
            showLyric ? '看封面' : '看歌词',
            () => setState(() => showLyric = !showLyric),
            // 歌词开着时给强调色，一眼能看出当前在哪个视图
            color: showLyric ? _darkTint : null,
            size: 22,
          ),
          _plainIcon(Icons.forward_10_rounded, '快进 10 秒',
              () => player.seekBy(const Duration(seconds: 10)),
              size: 22),
          _plainIcon(Icons.tune_rounded, '播放器设置', _openPlayerSettings,
              size: 22),
        ],
      ),
    );
  }

  void _openPlayerSettings() {
    showMusicSheet<void>(
      context: context,
      backgroundColor: MusicTheme.card,
      builder: (_) => const PlayerSettingsSheet(),
    );
  }

  // ============================================================
  // 音量面板
  // ============================================================

  /// #16：音量面板
  ///
  /// 系统音量键调的是**设备音量**；这里调的是**播放器自身音量**
  /// （`MusicPlayerManager.setVolume`，0~100），两者互不影响。
  ///
  /// ── 🔴 这个面板的颜色必须**恒浅** ──
  /// 播放页底色**永远是深色**，而弹层原来是透明底 + `MusicTheme.label`
  /// / `secondary` / `tint` —— 那三个都会**跟着全局明暗走**：
  ///   · 全局**浅色**（默认）时它们是**暗色** → 暗字压在深色播放页上
  ///   · 后果：「音量」标题、提示行、已填充的滑块轨道**几乎看不见** ✗
  ///
  /// 改法与同文件 `_darkTint` 的既定思路一致：
  ///   · 弹层给一个**恒定深色底**（别再透明）
  ///   · 文字/图标用**恒定浅色**
  ///   · 强调色用 `_darkTint`
  void _showVolumeSheet() {
    showMusicSheet<void>(
      context: context,
      // 恒定深色底：与播放页同一色系，但不透明（否则文字对比全靠运气）
      backgroundColor: const Color(0xFF1C1C1E),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ⚠️ 恒定浅色，不要用 `MusicTheme.label`（它跟全局明暗走）
              const Text('音量',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(Icons.volume_mute_rounded,
                      size: 18, color: Colors.white70),
                  Expanded(
                    child: ValueListenableBuilder<double>(
                      valueListenable: player.volume,
                      builder: (_, v, __) => Slider(
                        value: v.clamp(0, 100),
                        max: 100,
                        // 强调色用深底专用的那个
                        activeColor: _darkTint,
                        inactiveColor: Colors.white24,
                        onChanged: player.setVolume,
                      ),
                    ),
                  ),
                  const Icon(Icons.volume_up_rounded,
                      size: 18, color: Colors.white70),
                ],
              ),
              const Text(
                '提示：这里调的是播放器音量；手机侧边键调的是系统音量。',
                style: TextStyle(
                    color: Colors.white70, fontSize: AppTheme.fontFootnote),
              ),
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 封面视图
  // ============================================================

  /// 封面区：封面（随皮肤形态）+ 下方三行歌词预览。
  ///
  /// 尺寸按可用空间**算出来**（不再是写死 280 + FittedBox 兜底）：
  /// 大屏上封面能长到 340（写死 280 在 6.7 寸上偏小），
  /// 小屏上自动缩到放得下预览歌词为止。
  Widget _coverView(Song song) {
    return ValueListenableBuilder<MusicCoverStyle>(
      valueListenable: MusicPlayerSkin.instance.coverStyle,
      builder: (context, style, __) {
        return LayoutBuilder(
          builder: (context, c) {
            // 留出：左右各 32 边距、下方 18 间距 + 72 歌词预览
            final byW = c.maxWidth - 64;
            final byH = c.maxHeight - 96;
            final side = math
                .min(math.min(byW, byH), 340.0)
                .clamp(170.0, 340.0);
            final cover = switch (style) {
              MusicCoverStyle.vinyl => _vinylCover(song, side),
              MusicCoverStyle.cd => _cdCover(song, side),
              MusicCoverStyle.square => _squareCover(song, side),
              MusicCoverStyle.blur => _blurCover(song, side),
              MusicCoverStyle.circle => _circleCover(song, side),
            };
            return Center(
              key: const ValueKey('cover'),
              // FittedBox 是最后一道兜底：极端小屏 / 超大字号时整体等比缩小，
              // 而不是抛 RenderFlex overflow（黄黑条）。
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 播放时封面回到 1.0、暂停时略缩 —— 与"唱片停下"呼应
                    ValueListenableBuilder<bool>(
                      valueListenable: player.isPlaying,
                      builder: (context, playing, child) => AnimatedScale(
                        scale: playing ? 1.0 : 0.94,
                        duration: const Duration(milliseconds: 420),
                        curve: Curves.easeOutCubic,
                        child: child,
                      ),
                      child: cover,
                    ),
                    const SizedBox(height: 18),
                    SizedBox(height: 72, child: _coverLyricPreview()),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 封面下方的歌词预览 —— 上一行 / 当前行 / 下一行。
  /// 当前行加粗放大、上下两行压暗；点封面任意处进入全屏歌词。
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
            final cur = (idx < 0 ? 0 : idx).clamp(0, lines.length - 1);
            String at(int i) =>
                (i >= 0 && i < lines.length) ? lines[i].text.trim() : '';
            return Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _lyricPreviewLine(at(cur - 1), active: false),
                _lyricPreviewLine(at(cur), active: true),
                _lyricPreviewLine(at(cur + 1), active: false),
              ],
            );
          },
        );
      },
    );
  }

  /// 预览行：当前行加粗放大、其余压暗。空行给固定占位高度，
  /// 避免歌词滚动时整块高度跳动。
  Widget _lyricPreviewLine(String text, {required bool active}) {
    if (text.isEmpty) {
      return SizedBox(height: active ? 26 : 22);
    }
    return AnimatedDefaultTextStyle(
      duration: const Duration(milliseconds: 220),
      style: TextStyle(
        color: active
            ? Colors.white.withValues(alpha: 0.95)
            : Colors.white.withValues(alpha: 0.40),
        fontSize: active ? AppTheme.fontBody : AppTheme.fontFootnote,
        fontWeight: active ? FontWeight.w700 : FontWeight.w400,
        height: 1.35,
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  // ── 封面形态 1：黑胶（默认）—— 唱片盘面 + 中心标签 + 唱臂 ──
  //
  // 2026-10-14 美化（用户："黑胶唱片那个指针不能动吗？能不能美化一哈"）：
  //   · 盘面：纯色圆片 → **径向渐变** + 斜向高光，转起来有体积感；
  //   · 纹路：一道 border → `_VinylGroovesPainter` 十余道不等距同心圆；
  //   · 中心标签：加一圈细环，与盘面分层；
  //   · 唱臂：静态摆件 → `_arm` 驱动的**落针/抬臂**动画。
  //
  // 2026-10-30：所有尺寸改成按 [side] 等比算（原来是写死 280/246/128），
  // 这样大屏封面能真的变大，小屏也能跟着缩。
  Widget _vinylCover(Song song, double side) {
    final disc = side * 0.88;
    final label = side * 0.46;
    return SizedBox(
      width: side,
      height: side,
      child: Stack(
        alignment: Alignment.center,
        children: [
          _glow(side, 0.45),
          // 盘面
          RotationTransition(
            turns: _spin,
            child: Container(
              width: disc,
              height: disc,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                // 径向渐变：中心受光稍亮、外缘压暗，唱片转起来才看得出层次
                gradient: const RadialGradient(
                  colors: [
                    Color(0xFF232327),
                    Color(0xFF111113),
                    Color(0xFF0A0A0C),
                  ],
                  stops: [0.0, 0.55, 1.0],
                ),
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
                  // 唱片纹路：十几道不等距同心圆
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _VinylGroovesPainter(scale: disc / 246),
                    ),
                  ),
                  // 斜向高光：一笔即可，多了反而像塑料
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Colors.white.withValues(alpha: 0.10),
                              Colors.white.withValues(alpha: 0.0),
                            ],
                            stops: const [0.0, 0.45],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 中心标签（就是封面）：加一圈细环，把标签和盘面分开
                  Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF0F0F11),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.10)),
                    ),
                    child: ClipOval(
                      child: CoverImage(
                          url: song.coverUrl, size: label, circle: true),
                    ),
                  ),
                  // 中心轴孔
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF0A0A0C),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 唱臂：轴心在盘右下方，臂身斜向左上、唱头压住盘面右上。
          // 2026-10-14：由 `_arm` 驱动**落针/抬臂**（原来写死角度、纯静态摆件）。
          Positioned(
            right: side * 0.064,
            top: side * 0.293,
            child: AnimatedBuilder(
              animation: _arm,
              builder: (_, __) => Transform.scale(
                // 唱臂按 side/280 等比缩放，轴心仍在底部中心（旋转支点不跑）
                scale: side / 280,
                alignment: Alignment.bottomCenter,
                child: _VinylTonearm(t: _arm.value),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 封面形态 2：CD —— 透明圆盘 + 中心孔 + 虹彩环 ──
  Widget _cdCover(Song song, double side) {
    final disc = side * 0.87;
    return SizedBox(
      width: side,
      height: side,
      child: Stack(
        alignment: Alignment.center,
        children: [
          _glow(side, 0.4),
          RotationTransition(
            turns: _spin,
            child: Stack(
              alignment: Alignment.center,
              children: [
                ClipOval(
                  child: CoverImage(
                      url: song.coverUrl, size: disc, circle: true),
                ),
                // 虹彩反光环
                Container(
                  width: disc,
                  height: disc,
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
                  width: side * 0.1,
                  height: side * 0.1,
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

  // ── 封面形态 3：方形 —— 静止的圆角封面卡 ──
  //
  // ⚠️ 历史遗留：这里一度被改成"圆形旋转 CD 盘"，于是「方形封面」点出来
  //    和「CD 圆盘」长得一模一样（选项标签在说谎）。现在它是**真正的方形卡**：
  //    圆角矩形封面 + 柔和投影 + 内描边，且**不旋转**（静图才有"方"的稳定感）。
  Widget _squareCover(Song song, double side) {
    final card = side * 0.87;
    final radius = card * 0.09;
    return SizedBox(
      width: side,
      height: side,
      child: Stack(
        alignment: Alignment.center,
        children: [
          _glow(side, 0.35),
          Container(
            width: card,
            height: card,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.45),
                    blurRadius: 26,
                    offset: const Offset(0, 10)),
              ],
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                CoverImage(
                    url: song.coverUrl, size: card, cornerRadius: radius),
                // 内描边：浅色封面上也能看出卡片边界
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(radius),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.12)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 封面形态 5：圆形封面（对齐 Mei 的播放页）──────────────────
  //
  // 用户 2026-10-30：「https://github.com/ljyh223/Mei 音乐模块里面网易这些
  // 分类的页面 UI 界面用这个来，并播放器页面也融入这种风格」。
  //
  // Mei 的播放页（`player1.jpg`）就是**正圆封面 + 整屏模糊背景**：
  //   · 封面是正圆，不是圆角方图，也不带唱片纹路/唱臂那些装饰
  //   · 外面一圈极淡的白色描边（浅色封面上才看得出边界）
  //   · 下方一层柔光，让圆形从背景里浮起来
  //
  // 整屏模糊背景由 `_backdrop()` 提供（所有形态共用），这里只管封面本身。
  Widget _circleCover(Song song, double side) {
    final d = side * 0.88;
    return SizedBox(
      width: side,
      height: side,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 柔光：比封面大一圈、颜色取自封面色调，半径大、透明度低
          Container(
            width: d * 1.08,
            height: d * 1.08,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: _tint.withValues(alpha: 0.28),
                  blurRadius: 60,
                  spreadRadius: 6,
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.35),
                  blurRadius: 30,
                  offset: const Offset(0, 14),
                ),
              ],
            ),
          ),
          Container(
            width: d,
            height: d,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.14),
                width: 1,
              ),
            ),
            child: ClipOval(
              child: CoverImage(url: song.coverUrl, size: d, circle: true),
            ),
          ),
        ],
      ),
    );
  }

  // ── 封面形态 4：模糊大图 —— 铺满的模糊封面 + 中间小 CD ──
  Widget _blurCover(Song song, double side) {
    final url = (song.coverUrl ?? '').toString();
    final h = side * 1.07;
    final inner = side * 0.6;
    return SizedBox(
      width: side,
      height: h,
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
                    width: side,
                    height: h,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox()),
              ),
            ),
          // 压暗一层，让中间的小封面跳出来
          // ⚠️ 必须是 `Positioned.fill` 包一层：`DecoratedBox` 没有 child 时
          // 不会像 `Container` 那样自动撑满，直接放会变成 0×0（等于没画）。
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: Colors.black.withValues(alpha: 0.35),
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 22,
                    offset: const Offset(0, 8)),
              ],
            ),
            // 中间小卡也是圆形旋转 CD 盘
            child: RotationTransition(
              turns: _spin,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  ClipOval(
                    child: CoverImage(
                        url: song.coverUrl, size: inner, circle: true),
                  ),
                  Container(
                    width: inner * 0.12,
                    height: inner * 0.12,
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

  /// 歌词首行/末行的**居中占位高度** = 视口高的一半。
  ///
  /// 为什么取一半：`ListView` 的第一个 item 顶到滚动起点，
  /// 要让**首行落在屏幕中央**，它前面就得有"半个视口"的空白。
  /// 用视口高而不是固定值，才能在各种屏幕尺寸下都居中。
  double _lyricTopPad(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    // 上下各让出一点安全区，避免首行贴到刘海/底部横条
    final safe = MediaQuery.viewPaddingOf(context);
    return (h - safe.top - safe.bottom) / 2;
  }

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
              // ⚠️ 步长与上面格子高度**同一套公式**（`_lyricExtent`）——
              // 以前这里写死常数，改字号后就越滚越偏。
              // 居中本身允许偏差，关键是**不要再用一个和实际高度无关的常数**。
              final step = _lyricExtent(active: true, hasTranslation: true);
              final target = ((idx < 0 ? 0 : idx) * step) -
                  _lyricScroll.position.viewportDimension / 2 +
                  step;
              final clamped = target.clamp(
                0.0,
                _lyricScroll.position.maxScrollExtent,
              );
              _lyricScroll.animateTo(
                clamped,
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutCubic,
              );
            });

            // ShaderMask：上下两端渐隐。
            //
            // 这是"沉浸歌词"的关键一笔 —— 没有它，滚出视口的歌词会在
            // 边界处被硬切一刀，看着像列表；渐隐之后才像"歌词浮在空气里"。
            // 用 `dstIn`：白色区域保留、透明区域擦掉，只影响 alpha 不动颜色。
            return ShaderMask(
              shaderCallback: (rect) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.white,
                  Colors.white,
                  Colors.transparent,
                ],
                stops: [0.0, 0.11, 0.84, 1.0],
              ).createShader(rect),
              blendMode: BlendMode.dstIn,
              child: ListView.builder(
                key: const ValueKey('lyric'),
                controller: _lyricScroll,
                padding: const EdgeInsets.symmetric(horizontal: 28),
                itemCount: lines.length + 2,
                itemBuilder: (c, i) {
                  // ── 上下占位（对齐 Beans 的歌词视口 `padding(.vertical, 210)`）──
                  //
                  // 目的只有一个：**让第一行和最后一行也能滚到屏幕中央**。
                  // 没有它时，首行永远卡在顶部、末行到不了中间。
                  //
                  // 两个占位职责不同：
                  //   · 顶部 = 视口高的一半 → 首行正好落在中央
                  //   · 底部 = 同上 + [_kDeckInset] → 再让出控制栏
                  if (i == 0) {
                    return SizedBox(height: _lyricTopPad(context));
                  }
                  if (i == lines.length + 1) {
                    return SizedBox(
                        height: _lyricTopPad(context) + _kDeckInset);
                  }
                  final li = i - 1;
                  final line = lines[li];
                  final active = li == idx;
                  // ── 🔴 行高必须**算出来**，不能写死 ──
                  // 内容最多是：正文 `maxLines: 2`（激活行 20 × 1.32 → 52.8）
                  // + 激活行有翻译时再叠一行 `fontFootnote`。
                  final hasTranslation =
                      active && (line.translation?.isNotEmpty ?? false);
                  final lineH = _lyricExtent(
                      active: active, hasTranslation: hasTranslation);
                  return Container(
                    height: lineH,
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _buildLyricText(line, active, li, idx),
                        if (hasTranslation)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              line.translation!,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: _darkTint.withValues(alpha: 0.95),
                                  fontSize: AppTheme.fontFootnote),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
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
  /// 于是"正在唱的字逐渐填色"这个效果天然就有了。
  Widget _buildLyricText(LyricLine line, bool active, int li, int idx) {
    final baseStyle = TextStyle(
      color: active
          ? Colors.white
          : Colors.white.withValues(alpha: li < idx ? 0.42 : 0.28),
      fontSize: active ? _kLyricActiveSize : _kLyricIdleSize,
      fontWeight: active ? FontWeight.w700 : FontWeight.w400,
      height: _kLyricLineHeight,
      letterSpacing: active ? 0.3 : 0,
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
                    // ⚠️ **深底专用**强调色。歌词区底色恒为深色，
                    //    而 `MusicTheme.tint` 会跟全局明暗走 ——
                    //    全局浅色（默认）时它是个暗色，压在深底上
                    //    对比度 ≈1.05:1 → **已唱部分看不见** ✗
                    color: _darkTint,
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
  // 空态
  // ============================================================

  Widget _emptyScaffold() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
              child: Row(
                children: [
                  _glassIcon(
                    icon: Icons.keyboard_arrow_down_rounded,
                    tooltip: '收起',
                    size: 24,
                    onTap: () => Navigator.maybePop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.music_note_rounded,
                        size: 44, color: Colors.white.withValues(alpha: 0.22)),
                    const SizedBox(height: 14),
                    Text(
                      '没有正在播放的歌曲',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: AppTheme.fontBody),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// 通用小组件
// ============================================================

/// 按下缩放反馈 —— 纯图标按钮共用。
///
/// 为什么不直接用 `InkWell`：播放页是**满屏渐变**，Material 的水波纹在
/// 深色渐变上几乎看不见（而且 Ink 需要一个 Material 祖先，这里没有）。
/// 按下缩小 8~16% 是 iOS 系音乐 App 的标准反馈，也比水波纹更"轻"。
class _Pressable extends StatefulWidget {
  const _Pressable({
    required this.child,
    required this.onTap,
    this.scale = 0.9,
  });

  final Widget child;
  final VoidCallback onTap;

  /// 按下时缩到多少（1.0 = 不缩放）
  final double scale;

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down == v) return;
    setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1.0,
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// 胶囊进度条 —— Apple Music 那一条。
///
/// ── 为什么不用 `Slider` ────────────────────────────────────────
/// `Slider` 自带最小触控宽度（拇指半径决定轨道两端的留白）、
/// 固定的轨道高度、以及一圈半透明 overlay —— 在满屏渐变上会露出一块
/// 灰蒙蒙的圆斑，且两端永远够不到 0% / 100%。这里只要"一条圆角细线
/// + 拖动时浮出的小白点"，自绘反而更短更准。
class _CapsuleProgress extends StatefulWidget {
  const _CapsuleProgress({
    required this.fraction,
    required this.dragging,
    required this.tint,
    required this.onSeek,
    required this.onSeekEnd,
  });

  /// 0~1 的播放进度
  final double fraction;

  /// 外部是否处于"拖动中"（决定圆点显不显示）
  final bool dragging;

  final Color tint;

  /// 拖动过程回调（只更新 UI，不真的 seek）
  final ValueChanged<double> onSeek;

  /// 松手回调（真正 seek）
  final ValueChanged<double> onSeekEnd;

  @override
  State<_CapsuleProgress> createState() => _CapsuleProgressState();
}

class _CapsuleProgressState extends State<_CapsuleProgress> {
  /// 拖动中的本地进度。
  ///
  /// ⚠️ 不能只依赖 `widget.fraction`：拖动结束（`onHorizontalDragEnd`）
  /// 那一下拿不到坐标，必须记住"最后拖到哪"，否则会 seek 回拖动前的值。
  double? _drag;

  double get _f => (_drag ?? widget.fraction).clamp(0.0, 1.0);

  bool get _active => _drag != null || widget.dragging;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        double at(double dx) => (dx / w).clamp(0.0, 1.0);

        void seek(double f) {
          setState(() => _drag = f);
          widget.onSeek(f);
        }

        void end() {
          final f = _f;
          setState(() => _drag = null);
          widget.onSeekEnd(f);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => seek(at(d.localPosition.dx)),
          onTapUp: (_) => end(),
          onHorizontalDragStart: (d) => seek(at(d.localPosition.dx)),
          onHorizontalDragUpdate: (d) => seek(at(d.localPosition.dx)),
          onHorizontalDragEnd: (_) => end(),
          onHorizontalDragCancel: end,
          child: SizedBox(
            height: 26,
            width: w,
            child: Center(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // 轨道
                  Container(
                    width: w,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  // 已播
                  Container(
                    width: w * _f,
                    height: 4,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Color.lerp(widget.tint, Colors.white, 0.35)!,
                          widget.tint,
                        ],
                      ),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  // 圆点（拖动时浮出）
                  Align(
                    alignment: Alignment(-1 + 2 * _f, 0),
                    child: AnimatedScale(
                      scale: _active ? 1 : 0,
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOut,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.35),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 黑胶唱臂：轴心在下、臂身向上、顶端是唱头。
///
/// 2026-10-13 改版（对齐用户参考图）：原来是"一根圆角细棒随便斜一下"，
/// 现在补上**轴心底座 + 唱头**，并改成"绕轴心旋转"。
///
/// 2026-10-14：由**静态**改成**可动落针**（用户："那个指针不能动吗"）——
/// [t] = 0 抬起待机（臂身近竖直，唱头离开盘面）；
/// [t] = 1 落到盘面（压到参考图角度）。
/// 角度由外层 `_arm` 动画控制器插值，播放 `forward()`、暂停 `reverse()`。
class _VinylTonearm extends StatelessWidget {
  const _VinylTonearm({required this.t});

  /// 0 = 抬起待机，1 = 落到盘面
  final double t;

  /// 抬起时的角度：近竖直，唱头明显离开盘面（不能为 0，否则臂身像插在轴上）
  static const double _liftedAngle = -0.03;

  /// 落针后的角度（对齐参考图）
  static const double _playingAngle = -0.40;

  @override
  Widget build(BuildContext context) {
    final angle = _liftedAngle + (_playingAngle - _liftedAngle) * t;
    return Transform.rotate(
      angle: angle,
      // 绕**底部中心**转 —— 底部中心即轴心
      alignment: Alignment.bottomCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 唱头（压在唱片盘面上的那一端）
          Container(
            width: 15,
            height: 20,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(4),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 6),
              ],
            ),
          ),
          // 臂身
          Container(
            width: 4.5,
            height: 104,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.88),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          // 轴心底座
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.95),
              border: Border.all(color: Colors.black.withValues(alpha: 0.12)),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 唱片纹路：十几道**不等距**同心圆。
///
/// 间距刻意不均匀（越靠外越密），这才是真实唱片"密纹"的观感；
/// 等距圆环看起来像靶纸。全部用极低透明度描边，转动时只留下细腻的纹理感。
///
/// [scale] 让纹路跟着盘面直径缩放（设计基准是 246 的盘面）。
class _VinylGroovesPainter extends CustomPainter {
  const _VinylGroovesPainter({this.scale = 1.0});

  final double scale;

  /// 纹路从中心标签外缘（半径 66）一直铺到接近盘缘（半径 121）
  static const List<double> _radii = [
    68, 71, 75, 80, 86, 92, 97, 101, 104, 107, 109, 111, 112, 113, 114,
    115, 116, 117, 118, 119, 120,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    // 外侧纹路更亮一点点：光源在盘面上方，边缘反射更强
    for (var i = 0; i < _radii.length; i++) {
      final alpha = 0.020 + 0.022 * (i / (_radii.length - 1));
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = i.isEven ? 0.7 : 0.5
        ..color = Colors.white.withValues(alpha: alpha);
      canvas.drawCircle(center, _radii[i] * scale, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _VinylGroovesPainter oldDelegate) =>
      oldDelegate.scale != scale;
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
  /// ⚠️ 它**不是音频频谱**（见文件顶部说明），
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
