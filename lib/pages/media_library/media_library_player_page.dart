import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../models/player_engine.dart';
import '../../models/vod_info.dart';
import '../../pages/detail/controller.dart';
import '../../services/player_prefs.dart';
import '../../widgets/app_player.dart';
import '../../widgets/ios_av_player.dart';
import '../../widgets/ks_player.dart';
import '../../widgets/mpv_app_player.dart';
import '../../widgets/video_player.dart';

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
      p.open(AppMedia(url, httpHeaders: widget.headers ?? const {}, start: start));
    }
  }

  String _resolvedUrl() {
    final parsed = widget.controller.playUrl.value;
    if (parsed != null && parsed.isNotEmpty) return parsed;
    final eps = _episodes;
    if (eps.isEmpty) return '';
    return eps[_currentIndex.clamp(0, eps.length - 1)].url;
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
        if (player == null) {
          return Center(
            child: CircularProgressIndicator(color: AppTheme.accentColor),
          );
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
          headers: widget.headers?.isEmpty ?? true ? null : widget.headers,
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
}
