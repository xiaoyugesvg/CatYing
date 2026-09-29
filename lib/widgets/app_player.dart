import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

/// 封装 video_player（iOS/macOS/Android = AVPlayer）的播放内核。
/// API 对齐 media_kit 的调用面，方便 VideoPlayerWidget / 详情页无感切换。
class AppMedia {
  final String url;
  final Map<String, String>? httpHeaders;
  final Duration? start;
  AppMedia(this.url, {this.httpHeaders, this.start});
  String get uri => url;
}

class AppConfig {
  final String title;
  const AppConfig({this.title = 'TVBox'});
}

class _AppPlayerState {
  bool playing = false;
  bool buffering = true;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  double rate = 1.0;
  double volume = 100; // 与 media_kit 一致：0-100
  double width = 0;
  double height = 0;
  String uri = '';
}

class AppPlayerStreams {
  final _playing = StreamController<bool>.broadcast();
  final _buffering = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _completed = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _rate = StreamController<double>.broadcast();

  Stream<bool> get playing => _playing.stream;
  Stream<bool> get buffering => _buffering.stream;
  Stream<Duration> get position => _position.stream;
  Stream<Duration> get duration => _duration.stream;
  Stream<bool> get completed => _completed.stream;
  Stream<String> get error => _error.stream;
  Stream<double> get rate => _rate.stream;

  void addPlaying(bool v) => _playing.add(v);
  void addBuffering(bool v) => _buffering.add(v);
  void addPosition(Duration v) => _position.add(v);
  void addDuration(Duration v) => _duration.add(v);
  void addCompleted(bool v) => _completed.add(v);
  void addError(String v) => _error.add(v);
  void addRate(double v) => _rate.add(v);

  void dispose() {
    _playing.close();
    _buffering.close();
    _position.close();
    _duration.close();
    _completed.close();
    _error.close();
    _rate.close();
  }
}

/// 只读播放状态（API 对齐 media_kit Player.state）
abstract class AppPlayerStateView {
  bool get playing;
  bool get buffering;
  Duration get position;
  Duration get duration;
  double get rate;
  double get volume;
  double get width;
  double get height;
  ({List<AppMedia> medias}) get playlist;
}

class _DefaultPlayerStateView extends AppPlayerStateView {
  final AppPlayer _p;
  _DefaultPlayerStateView(this._p);
  @override
  bool get playing => _p._s.playing;
  @override
  bool get buffering => _p._s.buffering;
  @override
  Duration get position => _p._s.position;
  @override
  Duration get duration => _p._s.duration;
  @override
  double get rate => _p._s.rate;
  @override
  double get volume => _p._s.volume;
  @override
  double get width => _p._s.width;
  @override
  double get height => _p._s.height;
  @override
  ({List<AppMedia> medias}) get playlist =>
      (medias: [if (_p._s.uri.isNotEmpty) AppMedia(_p._s.uri)]);
}

class AppPlayer {
  VideoPlayerController? _vc;
  final AppConfig config;
  final _s = _AppPlayerState();
  final stream = AppPlayerStreams();
  late final AppPlayerStateView _defaultState = _DefaultPlayerStateView(this);
  AppPlayerStateView get state => _defaultState;

  /// mpv 后端可注入自定义画面构建器；AVPlayer 为 null
  Widget Function({BoxFit fit, double? aspectRatio})? mpvVideoBuilder;
  bool _disposed = false;
  bool _completedNotified = false;
  bool _ownsController = true;

  AppPlayer({this.config = const AppConfig()});

  /// 外部注入 controller（详情页复用场景）
  AppPlayer.fromController(VideoPlayerController vc, {this.config = const AppConfig()}) {
    _vc = vc;
    _ownsController = false;
    _attach(vc);
    _pullState();
  }

  VideoPlayerController? get controller => _vc;

  void _attach(VideoPlayerController vc) {
    vc.addListener(_pullState);
  }

  void _pullState() {
    final vc = _vc;
    if (vc == null || _disposed) return;
    final v = vc.value;
    _s.uri = vc.dataSource;
    _s.playing = v.isPlaying;
    _s.buffering = v.isBuffering;
    _s.position = v.position;
    if (v.duration > Duration.zero) _s.duration = v.duration;
    _s.rate = v.playbackSpeed;
    _s.volume = v.volume * 100;
    if (v.size.width > 0) {
      _s.width = v.size.width;
      _s.height = v.size.height;
    }
    if (v.hasError && (v.errorDescription ?? '').isNotEmpty) {
      stream.addError(v.errorDescription!);
    }
    final done = _s.duration > Duration.zero &&
        _s.position >= _s.duration - const Duration(milliseconds: 400);
    if (done && !_completedNotified && _s.playing == false) {
      _completedNotified = true;
      stream.addCompleted(true);
    } else if (!done) {
      _completedNotified = false;
    }
  }

  Future<void> open(AppMedia media, {bool play = true}) async {
    _completedNotified = false;
    final old = _vc;
    if (old != null && _ownsController) {
      try {
        await old.dispose();
      } catch (_) {}
    }
    final vc = VideoPlayerController.networkUrl(
      Uri.parse(media.url),
      httpHeaders: media.httpHeaders ?? const {},
    );
    _vc = vc;
    _ownsController = true;
    _s.uri = media.url;
    _s.buffering = true;
    _s.playing = false;
    _s.position = Duration.zero;
    _s.duration = Duration.zero;
    stream.addBuffering(true);
    try {
      await vc.initialize();
      if (_disposed) {
        await vc.dispose();
        return;
      }
      _attach(vc);
      _pullState();
      stream.addDuration(vc.value.duration);
      stream.addPosition(vc.value.position);
      if (media.start != null && media.start! > Duration.zero) {
        await vc.seekTo(media.start!);
        _s.position = media.start!;
        stream.addPosition(_s.position);
      }
      if (play) {
        await vc.play();
        _s.playing = true;
        stream.addPlaying(true);
      }
    } catch (e) {
      stream.addError(e.toString());
      stream.addPlaying(false);
    }
  }

  Future<void> play() async {
    final vc = _vc;
    if (vc == null) return;
    await vc.play();
    _s.playing = true;
    stream.addPlaying(true);
  }

  Future<void> pause() async {
    final vc = _vc;
    if (vc == null) return;
    await vc.pause();
    _s.playing = false;
    stream.addPlaying(false);
  }

  Future<void> seek(Duration target) async {
    final vc = _vc;
    if (vc == null) return;
    await vc.seekTo(target);
    _s.position = target;
    stream.addPosition(target);
    _completedNotified = false;
  }

  Future<void> setRate(double rate) async {
    final vc = _vc;
    if (vc == null) return;
    await vc.setPlaybackSpeed(rate);
    _s.rate = rate;
    stream.addRate(rate);
  }

  /// 与 media_kit 一致：0-100
  Future<void> setVolume(double v) async {
    final vc = _vc;
    final clamped = v.clamp(0.0, 100.0);
    _s.volume = clamped;
    if (vc == null) return;
    await vc.setVolume(clamped / 100.0);
  }

  Future<void> dispose() async {
    _disposed = true;
    final vc = _vc;
    if (vc != null) {
      try {
        vc.removeListener(_pullState);
      } catch (_) {}
      if (_ownsController) {
        try {
          await vc.dispose();
        } catch (_) {}
      }
    }
    _vc = null;
    stream.dispose();
  }
}

/// AVPlayer 画面（替代 media_kit 的 Video）
class AppVideoView extends StatelessWidget {
  final AppPlayer player;
  final BoxFit fit;
  final double? aspectRatio;
  const AppVideoView({
    super.key,
    required this.player,
    this.fit = BoxFit.contain,
    this.aspectRatio,
  });

  @override
  Widget build(BuildContext context) {
    // mpv 后端：由 mpv_app_player 注入的 [mpvVideoBuilder] 渲染
    final mpvBuilder = player.mpvVideoBuilder;
    if (mpvBuilder != null) {
      final w = mpvBuilder(fit: fit, aspectRatio: aspectRatio);
      return w;
    }
    final vc = player.controller;
    if (vc == null) {
      return const ColoredBox(color: Color(0xFF000000));
    }
    final video = VideoPlayer(vc);
    final box = FittedBox(
      fit: fit,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: vc.value.size.width > 0 ? vc.value.size.width : 16,
        height: vc.value.size.height > 0 ? vc.value.size.height : 9,
        child: video,
      ),
    );
    if (aspectRatio != null) {
      return AspectRatio(aspectRatio: aspectRatio!, child: box);
    }
    return box;
  }
}
