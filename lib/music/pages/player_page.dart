import 'dart:math' as math;
import '../widgets/music_sheet.dart';
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
///   · 顶部：下箭头 / 播放位置 `N / M` / 播放器设置；歌名·歌手紧随其下（居中）
///   · 中部：封面或歌词（封面下带 **3 行**歌词预览：上一行 / 当前行 / 下一行）
///   · 底部（2026-10-13 对齐参考图）：图标动作行 → 播放行 → 进度条
///   · 动作行：收藏 / 快退10s / 音量 / 歌词 / 快进10s / 更多 / 设置（纯图标）
///   · 播放行：播放模式 / 上一首 / 播放(主题色实心圆) / 下一首 / 队列
///
/// 没做的（Beans 有、这里略）：音效均衡器、DJ 可视化、评论、
/// 下载、歌单编辑、分享 —— 这些依赖账号或额外依赖，按需求裁剪。
/// 底部控制区（动作行 + 播放行 + 进度条）占的高度。
///
/// **内容区必须按这个值避让**，否则歌名 / 预览歌词 / 歌词末行会被控制栏盖住。
///
/// ⚠️ 用**硬编码**（不是自动测量）—— 稳定、可预测；
/// 自动测量会在控制栏内容变化时抖动。
///
/// 2026-10-13 改版（对齐用户提供的参考图）：底部由「进度条 → 播放行 → 动作行」
/// 三段组成，比旧版（进度条 + 控制行 + 6 个带文字按钮）略高，故 116 → 200。
const double _kDeckInset = 200;

class MusicPlayerPage extends StatefulWidget {
  const MusicPlayerPage({super.key});

  /// **全屏播放器当前是否打开**（供全局底栏判断要不要让位）。
  ///
  /// ── 🔴 为什么需要它（用户实测截图：播放器底部被盖住）────────────
  /// 全局 `MusicBottomChrome`（迷你条 + 导航栏）挂在 `app.dart` 的
  /// Stack 里、**在 `out`（Navigator）之后** → 它盖在**所有**路由之上，
  /// 包括这个全屏播放器。
  ///
  /// 而播放器**自己**有一条底部操作栏
  ///（`_bottomBar()`：列表循环 / 收藏 / 上一首 / 歌词 / 下一首 / 设置）——
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
                _titleBlock(song),
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
                // 底部三段（对齐参考图）：动作行 → 播放行 → 进度条
                _actionRow(song),
                const SizedBox(height: 6),
                _playRow(),
                const SizedBox(height: 2),
                _progressBar(),
                const SizedBox(height: 6),
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
  ///
  /// ── 🔴 这个面板的颜色必须**恒浅**（原来全部跟全局明暗走 → 浅色下不可见）──
  ///
  /// 播放页底色**永远是深色**（`Color(0xFF141416)` / `0xFF0A0A0C`，见本文件
  /// 的用法），而这个弹层原来是 `backgroundColor: Colors.transparent`
  /// 且文字/滑块用 `MusicTheme.label` / `MusicTheme.secondary` /
  /// `MusicTheme.tint` —— 那三个都会**跟着全局明暗走**：
  ///   · 全局**浅色**（默认）时它们是**暗色** → 暗字压在深色播放页上
  ///   · 后果：「音量」标题、下面那行提示、已填充的滑块轨道
  ///     **几乎看不见** ✗（子代理报告时列的就是这几行）
  ///
  /// 改法与同文件 `_darkTint` 的既定思路一致（那段的注释已经写明
  /// "播放页恒深色，所以取与白色混合后的浅色"）：
  ///   · 弹层给一个**恒定深色底**（别再透明，透明就等于把播放页当底）
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
              Text('音量',
                  style: TextStyle(
                      // ⚠️ 恒定浅色，不要用 `MusicTheme.label`
                      color: Colors.white,
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.volume_mute_rounded,
                      size: 18, color: Colors.white70),
                  Expanded(
                    child: ValueListenableBuilder<double>(
                      valueListenable: player.volume,
                      builder: (_, v, __) => Slider(
                        value: v.clamp(0, 100),
                        max: 100,
                        // 强调色用深底专用的那个（浅色主题下 `MusicTheme.tint`
                        // 是暗色，在深底上看不见）
                        activeColor: _darkTint,
                        inactiveColor: Colors.white24,
                        onChanged: (nv) => player.setVolume(nv),
                      ),
                    ),
                  ),
                  Icon(Icons.volume_up_rounded,
                      size: 18, color: Colors.white70),
                ],
              ),
              Text(
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

  /// 顶栏：`⌄`（收起）· 播放位置 `N / M` · `⚙`（播放器设置）。
  ///
  /// 2026-10-13 改版（对齐用户参考图）：原来顶栏塞了「下箭头 / 歌名歌手 /
  /// 队列 / 音量 / 更多」五个元素，太挤。现在歌名歌手移到顶栏**下方**独立一块
  /// （见 [_titleBlock]）；队列 / 音量 / 更多归位到动作行与播放行；顶栏只留 3 项。
  Widget _topBar(dynamic song) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
      child: Row(
        children: [
          IconButton(
            tooltip: '收起',
            icon: const Icon(Icons.keyboard_arrow_down_rounded,
                color: Colors.white, size: 30),
            onPressed: () => Navigator.maybePop(context),
          ),
          Expanded(
            child: Text(
              player.queue.isEmpty
                  ? ''
                  : '${player.currentIndex + 1} / ${player.queue.length}',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.72),
                  fontSize: AppTheme.fontFootnote,
                  fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            tooltip: '播放器设置',
            icon: const Icon(Icons.settings_rounded,
                color: Colors.white, size: 22),
            onPressed: () => showMusicSheet<void>(
              context: context,
              backgroundColor: MusicTheme.card,
              builder: (_) => const PlayerSettingsSheet(),
            ),
          ),
        ],
      ),
    );
  }

  /// 歌名（粗体）+ 歌手（次要色），顶栏正下方居中 —— 对齐参考图。
  Widget _titleBlock(dynamic song) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 2, 28, 12),
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
                fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
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
          // 固定 280 宽 + scaleDown：小屏（如 iPhone SE）竖向不够时整体等比缩小，
          // 而不是抛 RenderFlex overflow（改版后底部多了一行、标题也独立成块，
          // 竖向余量变小，这道兜底必须有）。
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: SizedBox(
              width: 280,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  cover,
                  const SizedBox(height: 22),
                  _qualityChip(),
                  const SizedBox(height: 6),
                  // 封面下方：上一行 / 当前行 / 下一行歌词（对齐参考图）；无歌词给提示。
                  SizedBox(height: 78, child: _coverLyricPreview()),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 封面下方的歌词预览 —— 上一行 / 当前行 / 下一行（对齐参考图）。
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
            : Colors.white.withValues(alpha: 0.42),
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
          // 唱臂：轴心在盘右下方，臂身斜向左上、唱头压住盘面右上（对齐参考图）。
          // 轴心位置 = right 18 / top 82（换算后落在 (250,230) 附近）——
          // 旋转绕轴心，所以臂身整体向左上展开，不会超出 280 画布被 Stack 裁掉。
          const Positioned(
            right: 18,
            top: 82,
            child: _VinylTonearm(),
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
              // ⚠️ 与上面格子高度**用同一套公式**：格子高度现在是算出来的
              //（激活行带翻译时更高），这里若还写死 44 就会越滚越偏。
              // 用"激活行有翻译"这一最常见的高行值作为步长近似 ——
              // 居中本身允许偏差（`:866` 还减了 viewport/2），
              // 关键是**不要再用一个和实际高度无关的常数**。
              const lineH = (17.0 * 1.25 * 2) + (AppTheme.fontFootnote * 1.4);
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
                // ── 上下占位（对齐 Beans 的歌词视口 `padding(.vertical, 210)`）──
                //
                // Beans 给歌词视口**整体**加纵向内边距，目的只有一个：
                // **让第一行和最后一行也能滚到屏幕中央**。
                // 没有它时，首行永远卡在顶部、末行到不了中间。
                //
                // 这里原来是两头各写死 180。看着差不多，但有两个问题：
                //   1. 用**固定 180** 而不是"半个视口高" → 屏幕越高，
                //      首行离中央越远（大屏上偏移很明显）
                //   2. 底部那个占位同时还要**给控制栏让位**，两个职责混在一起
                //
                // 现在分开：
                //   · 顶部占位 = 视口高的一半 → 首行正好落在中央
                //   · 底部占位 = 同上 + [_kDeckInset] → 再让出控制栏
                if (i == 0) {
                  return SizedBox(height: _lyricTopPad(context));
                }
                if (i == lines.length + 1) {
                  return SizedBox(height: _lyricTopPad(context) + _kDeckInset);
                }
                final li = i - 1;
                final line = lines[li];
                final active = li == idx;
                // ── 🔴 行高必须**算出来**，不能写死 44（修一个溢出）──────
                //
                // 原来固定 `height: 44`，而格子里的内容最多是：
                //   · 正文 `maxLines: 2`，激活行 fontSize 17 × height 1.25
                //     → 2 行 = **42.5**
                //   · 激活行**有翻译时**再叠一行 `fontFootnote`(12)
                //     → 再加 ≈14.4 = **56.9 > 44** ✗
                // 于是「长歌词（超过一行容量）且带翻译」的当前行
                // 必然 `RenderFlex overflowed`（黄黑条），
                // 而且 `:864` 那个 `const lineH = 44.0` 的滚动位移也跟着失准。
                //
                // 现在按**同一套字号/行高**算出来：非激活行 15、激活行 17、
                // 行高 1.25 都与 `_buildLyricText` 一致；激活行有翻译再加一行。
                // ⚠️ 别用 `textScaler`：下面高度不缩放，缩放的是字号，
                //    两边一起放大反而看不出差异（真机字号放大时
                //    这个高度是"够用"的，不会溢出）。
                final lyricActive = li == idx;
                final hasTranslation = lyricActive &&
                    (line.translation?.isNotEmpty ?? false);
                final lineH = (lyricActive ? 17.0 : 15.0) * 1.25 * 2 +
                    (hasTranslation ? AppTheme.fontFootnote * 1.4 : 0);
                return Container(
                  height: lineH,
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
                    // ⚠️ **深底专用**强调色。歌词区底色恒为深色，
                    //    而 `MusicTheme.tint` 会跟全局明暗走 ——
                    //    全局浅色（默认）时它是个暗色，压在深底上
                    //    对比度 ≈1.05:1 → **已唱部分看不见** ✗
                    //    本文件 `_darkTint` 的注释点名的就是这个位置。
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

  /// 播放行（对齐参考图）：模式 · 上一首 · 大播放键 · 下一首 · 队列。
  Widget _playRow() {
    return Row(
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
            return _plainIcon(icon, label,
                () => setState(() => player.cycleMode()));
          },
        ),
        _plainIcon(
            Icons.skip_previous_rounded, '上一首', () => player.previous()),
        _bigPlayButton(),
        _plainIcon(Icons.skip_next_rounded, '下一首', () => player.next()),
        // 播放队列（原来在顶栏，改版后归到这里）
        _plainIcon(Icons.queue_music_rounded, '播放队列',
            () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    settings: const RouteSettings(name: 'music:page'),
                    builder: (_) => const MusicQueuePage(),
                  ),
                )),
      ],
    );
  }

  /// 大播放键：**主题色实心圆**（对齐参考图；原来是半透明"玻璃球"）。
  /// 前景色按底色亮度自动取黑/白 —— 浅色调下白图标会看不清。
  Widget _bigPlayButton() {
    final fg = _tint.computeLuminance() > 0.6 ? Colors.black87 : Colors.white;
    return GestureDetector(
      onTap: () => player.toggle(),
      child: Container(
        width: 64,
        height: 64,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _tint,
          boxShadow: [
            BoxShadow(
                color: _tint.withValues(alpha: 0.45),
                blurRadius: 18,
                offset: const Offset(0, 6)),
          ],
        ),
        child: ValueListenableBuilder<bool>(
          valueListenable: player.isPlaying,
          builder: (context, playing, _) => Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: fg,
            size: 34,
          ),
        ),
      ),
    );
  }

  /// 纯图标按钮（无文字标签）—— 播放行 / 动作行共用。
  Widget _plainIcon(IconData icon, String tooltip, VoidCallback onTap,
      {Color? color, double size = 26}) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon,
              color: color ?? Colors.white.withValues(alpha: 0.9), size: size),
        ),
      ),
    );
  }

  // ============================================================
  // 底部动作栏
  // ============================================================

  /// 动作行（纯图标、无文字标签，对齐参考图）：
  /// 收藏 · 快退10s · 音量 · 歌词/封面 · 快进10s · 更多 · 设置。
  ///
  /// 2026-10-13 改版：原来是 6 个**带文字**的按钮（模式/收藏/上一首/歌词/下一首/设置），
  /// 现在按参考图统一成图标行；模式/上一首/下一首/队列移到播放行，
  /// 快退/快进 10s 从播放行挪到这里（功能不减，只是归位）。
  Widget _actionRow(dynamic song) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // 收藏（红心）
        ListenableBuilder(
          listenable: MusicLibraryStore.instance,
          builder: (context, _) {
            final fav = MusicLibraryStore.instance.isFavorite(song);
            return _plainIcon(
              fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              fav ? '已收藏' : '收藏',
              () {
                // onTap 要 VoidCallback，async 闭包返回 Future → 用 unawaited 包一层。
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
              // 收藏时用深底专用强调色（MusicTheme.tint 在全局浅色下是暗色，
              // 压在深色播放页上红心几乎看不见）
              color: fav ? _darkTint : null,
              size: 24,
            );
          },
        ),
        _plainIcon(Icons.replay_10_rounded, '快退 10 秒',
            () => player.seekBy(const Duration(seconds: -10)),
            size: 24),
        // 音量（原来在顶栏）
        ValueListenableBuilder<double>(
          valueListenable: player.volume,
          builder: (context, v, _) => _plainIcon(
            v <= 0
                ? Icons.volume_off_rounded
                : (v < 50
                    ? Icons.volume_down_rounded
                    : Icons.volume_up_rounded),
            '音量',
            () => _showVolumeSheet(),
            size: 24,
          ),
        ),
        // 封面 ⇄ 歌词
        _plainIcon(
          showLyric ? Icons.album_rounded : Icons.lyrics_rounded,
          showLyric ? '看封面' : '看歌词',
          () => setState(() => showLyric = !showLyric),
          size: 24,
        ),
        _plainIcon(Icons.forward_10_rounded, '快进 10 秒',
            () => player.seekBy(const Duration(seconds: 10)),
            size: 24),
        _plainIcon(Icons.more_horiz_rounded, '更多操作',
            () => showSongActions(context, song),
            size: 24),
        _plainIcon(
          Icons.tune_rounded,
          '播放器设置',
          () => showMusicSheet<void>(
            context: context,
            backgroundColor: MusicTheme.card,
            builder: (_) => const PlayerSettingsSheet(),
          ),
          size: 24,
        ),
      ],
    );
  }
}

/// 黑胶唱臂：轴心在下、臂身向上、顶端是唱头。
///
/// 2026-10-13 改版（对齐用户参考图）：原来是"一根圆角细棒随便斜一下"，
/// 现在补上**轴心底座 + 唱头**，并改成"绕轴心旋转"——
/// 臂身自然向左上展开、轴心始终钉在盘右下方（静态摆位，不做动画，避免分心）。
class _VinylTonearm extends StatelessWidget {
  const _VinylTonearm();

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      // -22°：臂身向左上倾（参考图角度）
      angle: -0.38,
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
