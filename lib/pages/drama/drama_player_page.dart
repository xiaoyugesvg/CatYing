import 'dart:async';
import 'dart:io';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import 'package:tvbox/common/system_ui.dart';
import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/cache_store.dart';
import 'package:tvbox/models/movie.dart';
import 'package:tvbox/models/player_engine.dart';
import 'package:tvbox/models/vod_info.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/services/player_prefs.dart';
import 'package:tvbox/widgets/app_player.dart';
import 'package:tvbox/widgets/ios_av_player.dart';
import 'package:tvbox/widgets/ks_player.dart';
import 'package:tvbox/widgets/mpv_app_player.dart';
import 'package:tvbox/widgets/parse_sniff_sheet.dart';
import 'package:tvbox/pages/detail/controller.dart';

/// 短剧专用播放页（2026-10-23 重做）。
///
/// ── 为什么不再走详情页 ────────────────────────────────────────
/// 原来从短剧点进去是 `/detail`：先渲染一屏详情布局、再切竖屏全屏，
/// 用户看到的是「闪一下详情」。而且换集要等详情页重建。
///
/// 这个页面**没有详情布局**：一进来就是黑底 + 封面，取到地址立刻播；
/// 上滑/下滑整页翻动切集（PageView 垂直滚动，抖音那种）。
///
/// ── 为什么视频层是固定的 ──────────────────────────────────────
/// iOS 的 AVPlayer 是 UiKitView（平台视图），跟着 PageView 滚动会黑屏/撕裂。
/// 所以视频固定在底层，PageView 只负责"翻页手势 + 封面层"：
/// 滑动时下一集的封面整屏推上来盖住画面，视觉上与抖音一致。
class DramaPlayerPage extends StatefulWidget {
  const DramaPlayerPage({
    super.key,
    required this.video,
    this.initialIndex = 0,
    this.startFromHistory = true,
  });

  final Video video;

  /// 从影视播放器「短」按钮进来时，定位到当前正在播的那一集
  final int initialIndex;

  /// 是否按观看历史续播（短剧 tab 进来要续播；从影视播放器点「短」进来
  /// 就留在当前那一集，否则会被历史拽到别的集）
  final bool startFromHistory;

  @override
  State<DramaPlayerPage> createState() => _DramaPlayerPageState();
}

class _DramaPlayerPageState extends State<DramaPlayerPage> {
  late final DetailController _c = _createController();
  final _pageCtrl = PageController();

  AppPlayer? _player;
  Worker? _urlWorker;
  Timer? _tickTimer;
  Timer? _waitTimer;
  Timer? _uiTimer;

  int _index = 0;
  bool _ui = true;
  bool _switching = false; // 正在切换集/解析地址

  /// 等地址超时的提示（详情页有 15 秒兜底，这里同样不能无限转圈）
  String? _timeoutHint;

  /// 是否已收藏（右上星标状态）
  bool _collected = false;

  /// 当前倍速
  double _speed = 1.0;

  /// 观看历史落盘节流：上次写入的秒数
  int _lastSavedSec = -1;

  /// 简介是否展开
  bool _descExpanded = false;

  /// 进度只走 ValueNotifier —— 每 500ms 一次 setState 会把整个 PageView
  /// 重建一遍，滑动时会闪。
  final _prog = ValueNotifier<({Duration pos, Duration dur, bool playing})>(
    (pos: Duration.zero, dur: Duration.zero, playing: false),
  );

  static DetailController _createController() {
    // ⚠️ 刻意**不用** Get.put：DetailController 是影视详情页的全局单例，
    //    put 会先 Get.delete 掉详情页正在用的那个实例（用户从详情页切去看
    //    短剧再返回，详情页的剧集/播放状态就全没了）。
    //    这里自己 new 一个，手动跑 onInit / onClose，用完即弃。
    final c = DetailController();
    c.onInit();
    return c;
  }

  @override
  void initState() {
    super.initState();
    _collected = CacheStore.instance
        .isCollected(widget.video.id, widget.video.sourceKey);
    _speed = PlayerPrefs.instance.defaultSpeed.value;
    unawaited(SystemUiController.enter(
      'dramaPlayer',
      mode: SystemUiMode.immersiveSticky,
      orientations: const [DeviceOrientation.portraitUp],
      overlayStyle: SystemUiOverlayStyle.light,
    ));

    // 播放地址变化（切集/线路解析完成）→ 立刻换源
    _urlWorker = ever<String?>(_c.playUrl, (url) {
      if (!mounted || url == null || url.isEmpty) return;
      _open(url);
    });

    // 进度条 + 观看历史（每 10 秒落一次盘，见 _saveHistory）
    _tickTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final p = _player;
      if (p == null || !mounted) return;
      _prog.value = (
        pos: p.state.position,
        dur: p.state.duration,
        playing: p.state.playing,
      );
      _saveHistory();
    });

    _boot();
    // 进页面 4 秒后自动收起控件，让画面干净（点一下再唤出）
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _ui = false);
    });
  }

  Future<void> _boot() async {
    _armWaitTimeout();
    await _c.loadDetail(widget.video);
    if (!mounted) return;
    final eps = _c.currentEpisodes;
    if (eps.isEmpty) return;

    var start = widget.initialIndex.clamp(0, eps.length - 1);

    // 短剧 tab 进来：按观看历史续播。原来走详情页时是详情页负责 restore 的，
    // 现在绕过详情页，这里不补上就每次从第 1 集重播。
    // 从影视播放器点「短」进来则不续播（要留在当前那一集）。
    VodPlaybackState? saved;
    if (widget.startFromHistory) {
      saved = CacheStore.instance.getPlaybackState(
        widget.video.id,
        widget.video.sourceKey,
      );
      if (saved != null &&
          (saved.episodeIndex < 0 || saved.episodeIndex >= eps.length)) {
        saved = null;
      }
    }

    if (saved != null) start = saved.episodeIndex;
    if (start > 0) {
      setState(() => _index = start);
      _syncPageTo(start);
    }
    if (saved != null) {
      _lastSavedSec = saved.progressSeconds.toInt();
      _c.applyPlaybackState(saved);
    } else {
      _c.selectEpisode(start);
    }
  }

  /// 把 PageView 定位到第 [i] 页（续播跳集必须成功，否则会盖住画面）。
  ///
  /// 为什么不能只跳一次：续播时 `itemCount` 可能还停在 1（剧集刚解析出来），
  /// `jumpToPage(i)` 会被夹到 0；老代码只 post-frame 跳一次，没成功就再没人
  /// 纠正 ⇒ PageView 停在第 1 页、`_index` 却是第 4 集，
  /// 当前页判定成"不是当前集"→ 一直铺着「第 1 集」封面，
  /// 表现就是**有声音没画面**（用户 2026-10-23 反馈）。
  void _syncPageTo(int i) {
    var tries = 0;
    void attempt() {
      if (!mounted) return;
      if (!_pageCtrl.hasClients) {
        if (tries++ < 10) {
          WidgetsBinding.instance.addPostFrameCallback((_) => attempt());
        }
        return;
      }
      _pageCtrl.jumpToPage(i);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_pageCtrl.hasClients && _pageCtrl.page?.round() == i) return;
        if (tries++ < 10) {
          Future<void>.delayed(const Duration(milliseconds: 80), attempt);
        }
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => attempt());
  }

  /// 写观看历史（每 10 秒一次，切集/退出时强制写）。
  ///
  /// 短剧页是独立播放器，不走详情页那套 `_saveHistoryForCurrentEpisode`，
  /// 所以历史必须自己落盘 —— 否则「继续观看」里根本看不到短剧。
  void _saveHistory({bool force = false}) {
    final p = _player;
    final info = _c.vodInfo.value;
    if (p == null || info == null) return;
    final pos = p.state.position;
    final sec = pos.inSeconds;
    if (sec <= 0) return;
    if (!force && (sec - _lastSavedSec).abs() < 10) return;
    _lastSavedSec = sec;
    final epName = info.currentEpisode?.name.trim() ?? '';
    final label =
        epName.isEmpty ? '第${_c.selectedEpisodeIndex.value + 1}集' : epName;
    // 注意：`VodInfo.toVideo()` 是 detail/view.dart 里的扩展，这里不能 import
    // （会跟 view.dart → drama_player_page.dart 形成循环），所以就地构造。
    final video = Video(
      id: info.id,
      name: info.name,
      pic: info.pic,
      note: info.note,
      year: info.year,
      area: info.area,
      director: info.director,
      actor: info.actor,
      des: info.des,
      sourceKey: info.sourceKey,
    );
    CacheStore.instance.addRecord(
      video,
      '$label ${_fmt(pos)}',
      playbackState: VodPlaybackState(
        flag: _c.selectedFlag.value,
        episodeIndex: _c.selectedEpisodeIndex.value,
        progressSeconds: sec.toDouble(),
      ),
    );
  }

  void _armWaitTimeout() {
    _waitTimer?.cancel();
    _waitTimer = Timer(const Duration(seconds: 25), () {
      if (!mounted) return;
      if ((_c.playUrl.value ?? '').isEmpty &&
          _c.errorMessage.value == null) {
        setState(() {
          _timeoutHint = '25 秒还没拿到播放地址，可能这条线路失效了，试试下一集';
        });
      }
    });
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _waitTimer?.cancel();
    _uiTimer?.cancel();
    _urlWorker?.dispose();
    _pageCtrl.dispose();
    _saveHistory(force: true);
    _prog.dispose();
    final p = _player;
    _player = null;
    if (p != null) unawaited(p.dispose());
    // 独立实例，必须自己收尾（移除生命周期观察者等）
    _c.onClose();
    unawaited(SystemUiController.exit('dramaPlayer'));
    super.dispose();
  }

  AppPlayer _newPlayer() {
    final engine = PlayerPrefs.instance.vodEngine.value;
    if (engine == PlayerEngine.mpv) {
      return MpvAppPlayer(config: const AppConfig(title: '短剧'));
    }
    if (engine == PlayerEngine.ksplayer && Platform.isIOS) {
      return KSPlayer(config: const AppConfig(title: '短剧'));
    }
    if (Platform.isIOS) {
      return IosAvPlayer(config: const AppConfig(title: '短剧'));
    }
    return AppPlayer(config: const AppConfig(title: '短剧'));
  }

  void _open(String url) {
    _player ??= _newPlayer();
    final headers = _c.playHeaders;
    // 续播位置：从「继续观看」/历史进来时，第一集要直接跳回上次看到的地方；
    // 用掉就清零，免得切下一集又从中间开始
    final resume = _c.resumeSeconds.value;
    final start = resume > 0 ? Duration(seconds: resume.toInt()) : null;
    _player!.open(
      AppMedia(
        url,
        httpHeaders: headers.isEmpty ? null : headers,
        start: start,
      ),
    );
    if (start != null) _c.resumeSeconds.value = 0;
    if (_speed != 1.0) _player!.setRate(_speed);
    _waitTimer?.cancel();
    if (_switching || _timeoutHint != null) {
      setState(() {
        _switching = false;
        _timeoutHint = null;
      });
    }
  }

  void _switchTo(int i) {
    final eps = _c.currentEpisodes;
    if (i < 0 || i >= eps.length) return;
    if (i == _index) return;
    // 切集前把当前集进度落盘（否则这一集的进度就丢了）
    _saveHistory(force: true);
    setState(() {
      _index = i;
      _switching = true;
    });
    _prog.value = (pos: Duration.zero, dur: Duration.zero, playing: false);
    _c.selectEpisode(i);
    _armWaitTimeout();
    _bumpUi();
  }

  /// 按钮/选集面板切集：先让页面翻过去（滑动由 onPageChanged 收口）
  void _jumpTo(int i) {
    final eps = _c.currentEpisodes;
    if (i < 0 || i >= eps.length) return;
    if (!_pageCtrl.hasClients) {
      _switchTo(i);
      return;
    }
    _pageCtrl.animateToPage(
      i,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  /// 点击画面：显示控件，5 秒后自动隐藏
  void _bumpUi() {
    setState(() => _ui = true);
    // 必须是单一定时器：连点两下时旧写法会留下两个 5 秒任务，
    // 第二个还没到就先把控件收掉了（点一下马上就消失）。
    _uiTimer?.cancel();
    _uiTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _ui = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Obx(() {
        final info = _c.vodInfo.value;
        final eps = _c.currentEpisodes;
        final url = _c.playUrl.value;
        final count = eps.isEmpty ? 1 : eps.length;
        final ready = url != null && url.isNotEmpty && _player != null;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _ui = !_ui),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // ── 视频层（固定）────────────────────────────────
              if (ready && !_switching)
                Positioned.fill(
                  // contain：竖屏视频本来就是满屏；横版视频也不会被裁掉两边
                  child: AppVideoView(player: _player!, fit: BoxFit.contain),
                ),

              // ── 翻页层（只画封面与滑动）──────────────────────
              // ⚠️ 必须有 key：视频层/控件层是按需插入删除的，
              //    没 key 时 PageView 在 children 里的下标一变就会被当成
              //    "新组件"重建 → 滚动位置回到第 1 页（续播集数对不上，
              //    画面被第 1 集的封面盖住 = 有声音没画面）。
              PageView.builder(
                key: const ValueKey('drama-pages'),
                controller: _pageCtrl,
                scrollDirection: Axis.vertical,
                itemCount: count,
                onPageChanged: _switchTo,
                itemBuilder: (_, i) {
                  // 当前页有画面时不铺封面，露出底层视频
                  final showCover = i != _index || !ready || _switching;
                  return IgnorePointer(
                    child: showCover
                        ? _coverLayer(eps, i)
                        : const SizedBox.shrink(),
                  );
                },
              ),

              // ── 顶部返回 + 剧名 ─────────────────────────────
              if (_ui)
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: _topBar(info, eps),
                ),

              // ── 左下：来源 / 剧名 / 简介（抖音式）────────────
              if (_ui)
                Positioned(
                  left: 14,
                  right: 86,
                  bottom: 108,
                  child: _infoPanel(info),
                ),

              // ── 右侧竖排（封面 / 引擎 / 选集 / 收藏 / 弹幕 / 上下集）─
              if (_ui)
                Positioned(
                  right: 10,
                  bottom: 108,
                  child: _sideActions(info),
                ),

              // ── 底部：进度 + 播放 + 倍速 + 跳过片头片尾 ──────
              if (_ui && ready) _bottomBar(),

              // ── 加载/错误 ───────────────────────────────────
              if (!ready) _statusLayer(),
            ],
          ),
        );
      }),
    );
  }

  Widget _coverLayer(List<Episode> eps, int i) {
    final pic = widget.video.pic;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (pic.isNotEmpty)
          CachedNetworkImage(
            imageUrl: pic,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const ColoredBox(color: Colors.black),
          )
        else
          const ColoredBox(color: Color(0xFF101012)),
        // 压暗：封面只是过渡态，别抢眼
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x99000000), Color(0xCC000000)],
            ),
          ),
        ),
        if (eps.isNotEmpty)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '第 ${i + 1} 集',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  eps[i].name,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.72),
                    fontSize: AppTheme.fontFootnote,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _topBar(VodInfo? info, List<Episode> eps) {
    final title = info?.name ?? widget.video.name;
    final epName = eps.isNotEmpty && _index < eps.length ? eps[_index].name : '';
    return Container(
      padding: EdgeInsets.fromLTRB(
          4, MediaQuery.of(context).padding.top + 4, 12, 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xB3000000), Colors.transparent],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                size: 18, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title.isEmpty ? '短剧' : title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600),
                ),
                if (epName.isNotEmpty)
                  Text(
                    '${_index + 1}/${eps.length} · $epName',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.66),
                        fontSize: AppTheme.fontCaption),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 右侧竖排（抖音式）────────────────────────────────────────

  /// 从下往上：封面、引擎、选集、收藏、弹幕、上一集、下一集。
  Widget _sideActions(VodInfo? info) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _coverAvatar(),
        const SizedBox(height: 14),
        _pill(label: _engineLabel(), onTap: _pickEngine),
        const SizedBox(height: 12),
        _pill(icon: Icons.grid_view_rounded, onTap: _openPicker),
        const SizedBox(height: 12),
        _pill(
          icon: _collected ? Icons.star_rounded : Icons.star_border_rounded,
          highlight: _collected,
          onTap: _toggleCollect,
        ),
        const SizedBox(height: 12),
        _pill(icon: Icons.forum_outlined, onTap: _showDanmuTip),
        const SizedBox(height: 12),
        // 嗅探（2026-10-28）：短剧源也可能返回网页播放页，单独成按钮，
        // 无论设置开关是否打开都常驻显示（与详情页底栏「嗅」对称）。
        _pill(
          label: '嗅',
          onTap: () => ParseSniffSheet.show(
            context,
            section: ParseSniffSection.sniff,
            onSniff: _c.openSniff,
          ),
        ),
        const SizedBox(height: 12),
        // 解析（2026-10-28）
        _pill(
          label: '解',
          onTap: () => ParseSniffSheet.show(
            context,
            section: ParseSniffSection.parse,
            onPickLine: (url) => _c.selectParseLine(url),
          ),
        ),
        const SizedBox(height: 12),
        _pill(
          icon: Icons.keyboard_arrow_up_rounded,
          onTap: _index > 0 ? () => _jumpTo(_index - 1) : null,
        ),
        const SizedBox(height: 12),
        _pill(
          icon: Icons.keyboard_arrow_down_rounded,
          onTap: _index < _c.currentEpisodes.length - 1
              ? () => _jumpTo(_index + 1)
              : null,
        ),
      ],
    );
  }

  /// 圆形封面（抖音的头像位）
  Widget _coverAvatar() {
    final pic = widget.video.pic;
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.9), width: 1.6),
        color: Colors.white.withValues(alpha: 0.12),
      ),
      child: ClipOval(
        child: pic.isEmpty
            ? const Icon(Icons.movie_rounded, size: 20, color: Colors.white70)
            : CachedNetworkImage(
                imageUrl: pic,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Icon(Icons.movie_rounded,
                    size: 20, color: Colors.white70),
              ),
      ),
    );
  }

  /// 圆形操作按钮：图标或文字（引擎用 "AV" 这类短标签）
  Widget _pill({
    IconData? icon,
    String? label,
    bool highlight = false,
    VoidCallback? onTap,
  }) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: enabled ? 0.38 : 0.18),
          shape: BoxShape.circle,
          border: Border.all(
            color: highlight
                ? Colors.amber.withValues(alpha: 0.9)
                : Colors.white.withValues(alpha: 0.16),
            width: highlight ? 1.4 : 1,
          ),
        ),
        child: icon != null
            ? Icon(icon,
                size: 21,
                color: highlight
                    ? Colors.amber
                    : Colors.white.withValues(alpha: enabled ? 0.92 : 0.3))
            : Text(
                label ?? '',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: enabled ? 0.92 : 0.3),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
      ),
    );
  }

  String _engineLabel() {
    return switch (PlayerPrefs.instance.vodEngine.value) {
      PlayerEngine.mpv => 'MPV',
      PlayerEngine.ksplayer => 'KS',
      _ => 'AV',
    };
  }

  // ── 左下信息 ──────────────────────────────────────────────────

  Widget _infoPanel(VodInfo? info) {
    final title = info?.name ?? widget.video.name;
    final desc = (info?.des ?? widget.video.des).trim();
    final srcName = _sourceName(info);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (srcName.isNotEmpty)
          Text('@$srcName',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: AppTheme.fontFootnote,
                  fontWeight: FontWeight.w600,
                  shadows: const [Shadow(blurRadius: 5, color: Colors.black87)])),
        if (srcName.isNotEmpty) const SizedBox(height: 5),
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: AppTheme.fontHeadline,
            fontWeight: FontWeight.w700,
            height: 1.25,
            shadows: [Shadow(blurRadius: 6, color: Colors.black87)],
          ),
        ),
        if (desc.isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(
            desc,
            maxLines: _descExpanded ? 8 : 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.82),
              fontSize: AppTheme.fontFootnote,
              height: 1.45,
              shadows: const [Shadow(blurRadius: 5, color: Colors.black87)],
            ),
          ),
          if (desc.length > 36)
            GestureDetector(
              onTap: () => setState(() => _descExpanded = !_descExpanded),
              child: Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  _descExpanded ? '收起' : '展开',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: AppTheme.fontCaption,
                    fontWeight: FontWeight.w600,
                    shadows: const [Shadow(blurRadius: 5, color: Colors.black87)],
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }

  String _sourceName(VodInfo? info) {
    final key = info?.sourceKey ?? widget.video.sourceKey;
    if (key.isEmpty) return '';
    try {
      return ApiConfig.instance.getSource(key)?.name ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 底部：进度条 + 播放/暂停 + 倍速 + 跳过片头/片尾 + 集数
  Widget _bottomBar() {
    final eps = _c.currentEpisodes;
    final skipIntro = _c.skipIntroSeconds.value;
    final skipOutro = _c.skipOutroSeconds.value;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(
            14, 28, 14, MediaQuery.of(context).padding.bottom + 8),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0xB3000000), Colors.transparent],
          ),
        ),
        child: ValueListenableBuilder<({Duration pos, Duration dur, bool playing})>(
          valueListenable: _prog,
          builder: (_, v, __) {
            final total = v.dur.inMilliseconds;
            final value = total <= 0
                ? 0.0
                : (v.pos.inMilliseconds / total).clamp(0.0, 1.0).toDouble();
            final posSec = v.pos.inSeconds;
            final durSec = v.dur.inSeconds;
            final showIntro =
                skipIntro > 0 && posSec > 0 && posSec < skipIntro;
            final showOutro =
                skipOutro > 0 && durSec > 0 && posSec > durSec - skipOutro;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 进度
                Row(
                  children: [
                    Text(_fmt(v.pos),
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 11,
                            fontFamily: 'monospace')),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(99),
                        child: LinearProgressIndicator(
                          value: value,
                          minHeight: 3,
                          backgroundColor:
                              Colors.white.withValues(alpha: 0.24),
                          valueColor:
                              const AlwaysStoppedAnimation(Colors.white),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(_fmt(v.dur),
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 11,
                            fontFamily: 'monospace')),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    GestureDetector(
                      onTap: _togglePlay,
                      child: Icon(
                        v.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 26,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 14),
                    _textChip('${_speedLabel(_speed)}x', _pickSpeed),
                    if (showIntro) ...[
                      const SizedBox(width: 8),
                      _textChip('跳过片头', () => _seekTo(skipIntro)),
                    ],
                    if (showOutro) ...[
                      const SizedBox(width: 8),
                      _textChip('跳过片尾',
                          () => _seekTo((durSec - 2).clamp(0, durSec))),
                    ],
                    const Spacer(),
                    Text(
                      eps.isEmpty ? '' : '${_index + 1}/${eps.length}',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.72),
                          fontSize: 11),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _textChip(String text, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(text,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
        ),
      );

  void _togglePlay() {
    final p = _player;
    if (p == null) return;
    if (p.state.playing) {
      p.pause();
    } else {
      p.play();
    }
    _bumpUi();
  }

  void _seekTo(num seconds) {
    _player?.seek(Duration(milliseconds: (seconds * 1000).round()));
    _bumpUi();
  }

  static String _speedLabel(double v) {
    // 1.0 → "1"，1.25 → "1.25"，0.75 → "0.75"
    final s = v.toStringAsFixed(2);
    return s.endsWith('0') ? s.substring(0, s.length - 1) : s;
  }

  Future<void> _pickSpeed() async {
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    final picked = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            const Text('播放速度',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            for (final s in speeds)
              ListTile(
                dense: true,
                title: Text('${_speedLabel(s)}x',
                    style: TextStyle(
                        color: s == _speed ? Colors.white : Colors.white70,
                        fontWeight:
                            s == _speed ? FontWeight.w700 : FontWeight.w400)),
                trailing: s == _speed
                    ? const Icon(Icons.check_rounded, size: 18, color: Colors.white)
                    : null,
                onTap: () => Navigator.pop(ctx, s),
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _speed = picked);
    _player?.setRate(picked);
    _bumpUi();
  }

  // ── 收藏 / 引擎 / 弹幕 ───────────────────────────────────────

  Future<void> _toggleCollect() async {
    final id = widget.video.id;
    final key = widget.video.sourceKey;
    if (_collected) {
      await CacheStore.instance.removeCollect(id, key);
    } else {
      await CacheStore.instance.addCollect(widget.video);
    }
    if (!mounted) return;
    setState(() =>
        _collected = CacheStore.instance.isCollected(id, key));
    _bumpUi();
  }

  Future<void> _pickEngine() async {
    final cur = PlayerPrefs.instance.vodEngine.value;
    final picked = await showModalBottomSheet<PlayerEngine>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            const Text('播放内核',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            for (final e in const [
              PlayerEngine.avplayer,
              PlayerEngine.mpv,
              PlayerEngine.ksplayer,
            ])
              ListTile(
                dense: true,
                title: Text(
                  switch (e) {
                    PlayerEngine.mpv => 'MPV（兼容性最好）',
                    PlayerEngine.ksplayer => 'KSPlayer（硬解）',
                    _ => 'AVPlayer（系统默认）',
                  },
                  style: TextStyle(
                      color: e == cur ? Colors.white : Colors.white70,
                      fontWeight:
                          e == cur ? FontWeight.w700 : FontWeight.w400),
                ),
                trailing: e == cur
                    ? const Icon(Icons.check_rounded,
                        size: 18, color: Colors.white)
                    : null,
                onTap: () => Navigator.pop(ctx, e),
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (picked == null || picked == cur || !mounted) return;
    PlayerPrefs.instance.vodEngine.value = picked;
    _reopenWithEngine();
    _bumpUi();
  }

  /// 换内核：释放旧实例、按当前进度重建，画面无缝续上
  void _reopenWithEngine() {
    final url = _c.playUrl.value;
    final old = _player;
    final pos = old?.state.position ?? Duration.zero;
    final playing = old?.state.playing ?? true;
    setState(() => _player = null);
    unawaited(old?.dispose());
    if (url == null || url.isEmpty) return;
    final headers = _c.playHeaders;
    final p = _newPlayer();
    _player = p;
    p.open(
      AppMedia(
        url,
        httpHeaders: headers.isEmpty ? null : headers,
        start: pos,
      ),
      play: playing,
    );
    if (_speed != 1.0) p.setRate(_speed);
    setState(() {});
  }

  void _showDanmuTip() {
    _bumpUi();
    Get.snackbar(
      '弹幕',
      '短剧源没有弹幕数据，影视详情页才有弹幕',
      snackPosition: SnackPosition.BOTTOM,
      backgroundColor: Colors.black.withValues(alpha: 0.82),
      colorText: Colors.white,
      duration: const Duration(seconds: 2),
      margin: const EdgeInsets.all(12),
    );
  }

  Widget _statusLayer() {
    final err = _c.errorMessage.value ?? _timeoutHint;
    return IgnorePointer(
      // 只有"转圈"时整层不拦点击；报错时要能点「重试」
      ignoring: err == null,
      child: Container(
        color: Colors.black.withValues(alpha: 0.45),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (err == null) ...[
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white70),
                ),
                const SizedBox(height: 12),
                Text('正在取播放地址…',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: AppTheme.fontFootnote)),
              ] else ...[
                const Icon(Icons.error_outline_rounded,
                    color: Colors.white70, size: 26),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(err,
                      maxLines: 3,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.75),
                          fontSize: AppTheme.fontFootnote,
                          height: 1.5)),
                ),
                const SizedBox(height: 14),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                  ),
                  onPressed: () => _c.selectEpisode(_index),
                  child: const Text('重试'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openPicker() async {
    final eps = _c.currentEpisodes;
    if (eps.isEmpty) return;
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            const Text('选集',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Flexible(
              child: GridView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.all(12),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 5,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 1.6,
                ),
                itemCount: eps.length,
                itemBuilder: (_, i) {
                  final on = i == _index;
                  return GestureDetector(
                    onTap: () => Navigator.pop(ctx, i),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: on
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('${i + 1}',
                          style: TextStyle(
                              color: on ? Colors.black : Colors.white70,
                              fontSize: AppTheme.fontFootnote,
                              fontWeight:
                                  on ? FontWeight.w700 : FontWeight.w400)),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (picked != null) _jumpTo(picked);
  }

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
