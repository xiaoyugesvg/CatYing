import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/player_engine.dart';
import 'package:tvbox/models/vod_info.dart';
import 'package:tvbox/pages/detail/controller.dart';
import 'package:tvbox/services/player_prefs.dart';
import 'package:tvbox/widgets/app_player.dart';
import 'package:tvbox/widgets/ios_av_player.dart';
import 'package:tvbox/widgets/ks_player.dart';
import 'package:tvbox/widgets/mpv_app_player.dart';
import 'package:tvbox/widgets/parse_sniff_sheet.dart';
import 'package:tvbox/widgets/video_player.dart';
import 'package:tvbox/widgets/playback_surface.dart';

/// 媒体库播放器页（独立模块 `lib/pages/media_library/`）
///
/// 与默认详情页播放器完全隔离：单独修改本文件不影响默认播放器。
/// - 播放内核与默认一致（跟随设置里的引擎：iOS 默认 AVPlayer / mpv 备用）；
/// - 选集/换线路复用 `DetailController.selectEpisode`（含 Spider 源地址解析），
///   切集时重建 Player 实例（`ObjectKey(_player)`）保证纹理干净重载；
/// - 全屏 / 短剧 / 抖音 / 跳转能力复用 `VideoPlayerWidget`。
class MediaLibraryPlayerPage extends StatefulWidget {
  final DetailController controller;
  final VodInfo info;

  /// 起始播放集索引（0 起）
  final int startIndex;

  /// 播放请求头（换源/防盗链时透传）
  final Map<String, String>? headers;

  const MediaLibraryPlayerPage({
    super.key,
    required this.controller,
    required this.info,
    this.startIndex = 0,
    this.headers,
  });

  @override
  State<MediaLibraryPlayerPage> createState() => _MediaLibraryPlayerPageState();
}

class _MediaLibraryPlayerPageState extends State<MediaLibraryPlayerPage> {
  AppPlayer? _player;
  bool _ownsPlayer = false;

  /// 用户已选的字幕（跨内核热切换接力，见 VideoPlayerWidget.subtitleChoice）
  SubtitleChoice? _subtitleChoice;
  int _currentIndex = 0;

  /// 已 open 过的地址，避免 Obx 重建重复 open
  String _lastOpenedUrl = '';

  List<Episode> get _episodes => widget.info.currentEpisodes;

  bool get _canNext => _currentIndex < _episodes.length - 1;
  bool get _canPrev => _currentIndex > 0;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.startIndex;
    // ⚠️ 关键：先让 DetailController 解析当前集。
    // Spider / 本地 py 源的「集地址」是 id（如 `/vodplay/150215-1-1`），
    // 不是可播放 URL；以前这里直接拿它 open，播放器只会报
    // `stream error: unsupported URL`，然后卡满 15 秒「加载超时」。
    widget.controller.selectEpisode(_currentIndex);
    _rebuildPlayer();
  }

  AppPlayer _newPlayer() {
    final engine = PlayerPrefs.instance.vodEngine.value;
    if (engine == PlayerEngine.mpv) {
      return MpvAppPlayer(config: const AppConfig(title: 'TVBox'));
    }
    if (engine == PlayerEngine.ksplayer && Platform.isIOS) {
      return KSPlayer(config: const AppConfig(title: 'TVBox'));
    }
    if (Platform.isIOS) {
      return IosAvPlayer(config: const AppConfig(title: 'TVBox'));
    }
    return AppPlayer(config: const AppConfig(title: 'TVBox'));
  }

  Future<void> _rebuildPlayer({Duration? start}) async {
    final old = _player;
    if (old != null && _ownsPlayer) {
      // ⚠️ 2026-10-19：必须 await dispose —— KSPlayer 的 close 是异步的，
      //   不 await 就创建新实例会导致旧引擎未死透、新引擎就 open，
      //   表现为「黑屏但有声音」（音频已起、视频层没挂上）。
      await old.dispose();
    }
    final p = _newPlayer();
    _player = p;
    _ownsPlayer = true;
    _lastOpenedUrl = '';
    // 用当前已解析地址开播；未解析则用集直链兜底
    final url = _resolvedUrl();
    if (url.isNotEmpty) {
      _lastOpenedUrl = url;
      // 用 controller 的最新请求头：解析刚完成时 playHeaders 才被写入，
      // 构造页面时传进来的 widget.headers 可能还是上一集的（防盗链会 403）。
      final headers = widget.controller.playHeaders.isNotEmpty
          ? Map<String, String>.from(widget.controller.playHeaders)
          : (widget.headers ?? const <String, String>{});
      p.open(AppMedia(url, httpHeaders: headers, start: start));
    }
  }

  String _resolvedUrl() {
    // controller.playUrl 只会在**解析成功且形态合法**后写入
    final parsed = widget.controller.playUrl.value;
    if (parsed != null && parsed.isNotEmpty) return parsed;
    final eps = _episodes;
    if (eps.isEmpty) return '';
    final raw = eps[_currentIndex.clamp(0, eps.length - 1)].url.trim();
    // 集地址可能是 `id`（无 scheme）—— 绝不能交给播放器兜底，
    // 否则就是 unsupported URL / 15 秒加载超时。
    final u = Uri.tryParse(raw);
    return (u != null && u.hasScheme) ? raw : '';
  }

  /// 内嵌网页兜底时的嗅探状态浮层（与详情页 `_withSniffOverlay` 同款）：
  /// 后台嗅探中 → 底部渐变条「正在嗅探视频地址…」；
  /// 嗅探放弃（未命中）→ 转「未嗅探到直链」info 提示 + 「换线路」入口。
  Widget _withSniffOverlay(Widget child) {
    return Obx(() {
      final sniffing = widget.controller.isWebSniffing.value;
      final gaveUp = widget.controller.sniffGaveUp.value;
      if (!sniffing && !gaveUp) return child;
      return Stack(
        children: [
          child,
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.75),
                  ],
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (sniffing) ...[
                    const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Flexible(
                      child: Text(
                        '正在嗅探视频地址…',
                        style: TextStyle(color: Colors.white, fontSize: 12.5),
                      ),
                    ),
                  ] else ...[
                    const Icon(
                      Icons.info_outline_rounded,
                      size: 15,
                      color: Colors.white70,
                    ),
                    const SizedBox(width: 8),
                    const Flexible(
                      child: Text(
                        '未嗅探到直链，可换线路或直接观看网页',
                        style: TextStyle(color: Colors.white, fontSize: 12.5),
                      ),
                    ),
                  ],
                  const SizedBox(width: 10),
                  // 嗅探不出结果时，用户不必等失败才能换线路。
                  GestureDetector(
                    onTap: () => ParseSniffSheet.show(
                      context,
                      section: ParseSniffSection.parse,
                      onPickLine: (url) =>
                          widget.controller.selectParseLine(url),
                    ),
                    child: const Text(
                      '换线路',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.underline,
                        decorationColor: Colors.white70,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    });
  }

  void _switchTo(int index) {
    final eps = _episodes;
    if (eps.isEmpty) return;
    final clamped = index.clamp(0, eps.length - 1);
    if (clamped == _currentIndex) return;
    setState(() => _currentIndex = clamped);
    // 复用 DetailController：spider 源异步解析播放地址 → playUrl 变化
    // 由下方 Obx 监听触发 _rebuildPlayer
    widget.controller.selectEpisode(clamped);
    _rebuildPlayer();
  }

  @override
  void dispose() {
    if (_ownsPlayer) {
      final p = _player;
      if (p != null) unawaited(p.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final title = info.tmdbName.isNotEmpty ? info.tmdbName : info.name;
    final eps = _episodes;
    final episodeNames = eps.map((e) => e.name).toList();

    return Scaffold(
      backgroundColor: Colors.black,
      body: Obx(() {
        // 解析地址变化（spider 异步解析完成 / 换线路）→ 重建 Player 实例
        final parsed = widget.controller.playUrl.value;
        if (parsed != null && parsed.isNotEmpty && parsed != _lastOpenedUrl) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _rebuildPlayer();
          });
        }
        final url = _resolvedUrl();
        final player = _player;
        if (player == null || url.isEmpty) {
          final err = widget.controller.errorMessage.value;
          return Center(
            child: (err != null && err.isNotEmpty)
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      err,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                  )
                : CircularProgressIndicator(color: AppTheme.accentColor),
          );
        }
        // 网页播放页（非直链媒体）→ 内嵌 WebView 兜底：避免原生播放器黑屏，
        // 后台嗅探到直链后由 onMediaFound 写回 playUrl，本页同页切原生
        // （复用下面 playUrl 变化的既有重建逻辑）。2026-10-28 修复（审计 P0-1）。
        if (PlaybackSurface.needsWebFallback(url)) {
          return _withSniffOverlay(PlaybackSurface.webFallback(
            url: url,
            title: title,
            embedded: true,
            // 网页兜底播放没有底栏 → 右上角补「嗅探 / 解析」两个入口（2026-10-28）
            onSniff: () => ParseSniffSheet.show(
              context,
              section: ParseSniffSection.sniff,
              onSniff: () => widget.controller.openSniff(),
            ),
            onSwitchParse: () => ParseSniffSheet.show(
              context,
              section: ParseSniffSection.parse,
              onPickLine: (url) => widget.controller.selectParseLine(url),
            ),
            onMediaFound: widget.controller.onWebviewMediaFound,
            // 后台嗅探进行中 → 播放区显示「正在嗅探视频地址…」
            onSniffState: (active) =>
                widget.controller.isWebSniffing.value = active,
            // 后台嗅探放弃（未命中）→ 浮层转「未嗅探到直链」静态提示
            onSniffGaveUp: widget.controller.onWebviewSniffGaveUp,
          ));
        }
        return VideoPlayerWidget(
          key: ObjectKey(player),
          player: player,
          // 字幕选择接力：热切换重建后按 matchKey 还原同一条字幕
          subtitleChoice: _subtitleChoice,
          onSubtitleChoiceChanged: (c) => _subtitleChoice = c,
          // 核心热切换：记住当前进度，按新偏好重建播放器续播
          // ⚠️ 2026-10-19：必须等 _rebuildPlayer 的 dispose 完成后再继续，
          //   否则旧引擎未死透就创建新实例，导致「黑屏但有声音」。
          onEngineChanged: (_) async {
            // 先暂停再取进度：dispose 是异步的，期间继续播放会导致进度落后
            if (_player?.state.playing == true) {
              await _player?.pause();
            }
            final pos = _player?.state.position;
            await _rebuildPlayer(
              start: (pos != null && pos > Duration.zero) ? pos : null,
            );
          },
          url: url,
          headers: _currentHeaders(),
          initialVideoFit: VideoFitType.contain,
          videoTitle: title,
          currentEpisodeName: _currentEpisodeName(),
          episodeNames: episodeNames,
          selectedEpisodeIndex: _currentIndex,
          canPlayNext: _canNext,
          canPlayPrevious: _canPrev,
          showAudioModeButton: true,
          // 媒体库播放器：顶栏往下挪（避开状态栏）、底栏往上挪一点
          topBarTopPadding: 28,
          bottomBarBottomPadding: 16,
          // 嗅探 / 解析：常驻按钮（2026-10-28），复用详情页控制器重解当前集。
          onSniff: () => ParseSniffSheet.show(
            context,
            section: ParseSniffSection.sniff,
            onSniff: () => widget.controller.openSniff(),
          ),
          onSwitchParse: () => ParseSniffSheet.show(
            context,
            section: ParseSniffSection.parse,
            onPickLine: (url) => widget.controller.selectParseLine(url),
          ),
          onPlayNext: () => _switchTo(_currentIndex + 1),
          onPlayPrevious: () => _switchTo(_currentIndex - 1),
          onSelectEpisode: (index) => _switchTo(index),
          onEnded: () {
            if (_canNext) _switchTo(_currentIndex + 1);
          },
          onBack: () => Get.back(),
        );
      }),
    );
  }

  String? _currentEpisodeName() {
    final eps = _episodes;
    if (eps.isEmpty) return null;
    return eps[_currentIndex.clamp(0, eps.length - 1)].name;
  }

  /// 请求头：优先用 controller 的最新值（解析完成后才写入），否则用页面参数。
  Map<String, String>? _currentHeaders() {
    final live = widget.controller.playHeaders;
    if (live.isNotEmpty) return Map<String, String>.from(live);
    return (widget.headers?.isEmpty ?? true) ? null : widget.headers;
  }
}
