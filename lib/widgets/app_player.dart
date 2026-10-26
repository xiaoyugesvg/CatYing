import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import 'package:tvbox/services/media_proxy_service.dart';

/// 封装 video_player（iOS/macOS/Android = AVPlayer）的播放内核。
/// API 对齐 media_kit 的调用面，方便 VideoPlayerWidget / 详情页无感切换。
class AppMedia {
  final String url;
  final Map<String, String>? httpHeaders;
  final Duration? start;

  /// 统一走**本机播放代理**（2026-10-21）：
  ///   · 带请求头（Referer/UA/Cookie）→ 必须代理，播放器内核不一定支持自定义头
  ///   · m3u8 → 代理里把相对路径/密钥/分片改写成代理地址
  /// 不需要代理时（本地文件 / 无头且非 m3u8）直接用原地址。
  factory AppMedia(
    String url, {
    Map<String, String>? httpHeaders,
    Duration? start,
  }) {
    final proxied = MediaProxyService.instance.proxify(
      url,
      headers: httpHeaders,
    );
    if (proxied != null) {
      return AppMedia._(proxied, const {}, start);
    }
    return AppMedia._(url, httpHeaders, start);
  }

  const AppMedia._(this.url, this.httpHeaders, this.start);

  String get uri => url;
}

class AppConfig {
  final String title;
  const AppConfig({this.title = 'TVBox'});
}

/// 内嵌字幕轨（跨内核统一视图）。
class SubtitleTrackInfo {
  /// 内核内部的轨道 id（mpv 的 `1`/`2`、KSPlayer 的 trackID）。
  final String id;

  /// 展示名：优先轨道标题，其次语言名，最后「字幕 N」。
  final String name;

  /// 语言标记（ISO/BCP-47，如 `zh`、`en`）。可能为空。
  final String? language;

  /// 位图字幕（PGS / VobSub / XSUB）：解码器逐帧叠加的图片，样式不可改。
  final bool isImage;

  const SubtitleTrackInfo({
    required this.id,
    required this.name,
    this.language,
    this.isImage = false,
  });

  /// 跨内核匹配键。
  ///
  /// 切换播放核心（MPV ⇄ KSPlayer）后轨道 id 完全不同，靠这个键把用户选中的
  /// 同一条字幕找回来：优先用语言标记（同一片源的语言最稳），
  /// 无语言标记时退化为轨道名。
  String get matchKey {
    final l = language?.trim().toLowerCase() ?? '';
    if (l.isNotEmpty) return 'lang:$l';
    return 'name:${name.trim().toLowerCase()}';
  }
}

/// 用户选定的字幕（引擎热切换后接力还原）。
/// `matchKey == null` 表示「关闭字幕」。
class SubtitleChoice {
  final String? matchKey;
  const SubtitleChoice(this.matchKey);

  /// 关闭字幕
  static const SubtitleChoice off = SubtitleChoice(null);

  bool get isOff => matchKey == null;

  @override
  bool operator ==(Object other) =>
      other is SubtitleChoice && other.matchKey == matchKey;

  @override
  int get hashCode => matchKey.hashCode;
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
  final _subtitleTracks =
      StreamController<List<SubtitleTrackInfo>>.broadcast();

  Stream<bool> get playing => _playing.stream;
  Stream<bool> get buffering => _buffering.stream;
  Stream<Duration> get position => _position.stream;
  Stream<Duration> get duration => _duration.stream;
  Stream<bool> get completed => _completed.stream;
  Stream<String> get error => _error.stream;
  Stream<double> get rate => _rate.stream;
  Stream<List<SubtitleTrackInfo>> get subtitleTracks => _subtitleTracks.stream;

  void addPlaying(bool v) => _playing.add(v);
  void addBuffering(bool v) => _buffering.add(v);
  void addPosition(Duration v) => _position.add(v);
  void addDuration(Duration v) => _duration.add(v);
  void addCompleted(bool v) => _completed.add(v);
  void addError(String v) => _error.add(v);
  void addRate(double v) => _rate.add(v);
  void addSubtitleTracks(List<SubtitleTrackInfo> v) => _subtitleTracks.add(v);

  void dispose() {
    _playing.close();
    _buffering.close();
    _position.close();
    _duration.close();
    _completed.close();
    _error.close();
    _rate.close();
    _subtitleTracks.close();
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

  /// 是否为 iOS 共享 AVPlayer（与系统小窗同一实例）
  bool get isSharedIosAv => false;

  /// mpv 后端可注入自定义画面构建器；AVPlayer 为 null
  Widget Function({BoxFit fit, double? aspectRatio})? mpvVideoBuilder;

  /// iOS UiKitView 等平台画面
  Widget Function({BoxFit fit, double? aspectRatio})? platformViewBuilder;
  bool _disposed = false;
  bool _completedNotified = false;
  bool _ownsController = true;

  // ── 字幕轨（内嵌）────────────────────────────────────────────
  //
  // 默认不支持：AVPlayer 后端（video_player）只能吃 MP4/MOV 的文本轨，
  // 恒返回空列表 → 播放器自动隐藏字幕入口。MPV / KSPlayer 各自 override。

  /// 是否支持内嵌字幕轨枚举 / 切换
  bool get supportsSubtitles => false;

  /// 内核名称（播放信息面板显示），子类覆盖为真实内核。
  String get engineName => 'AVPlayer (video_player)';

  /// 内核特有的运行数据（播放信息面板显示）。
  ///
  /// 各实现按能力补充，比如 MPV 能拿到像素格式 / 缓冲时长 / 音频码率；
  /// 拿不到就返回空 —— 面板只渲染存在项，不会出现「未知」占位。
  Map<String, String> get debugInfo => const {};

  List<SubtitleTrackInfo> _subtitleTracks = const <SubtitleTrackInfo>[];

  /// 当前媒体可用的字幕轨（空 = 无内嵌字幕）
  List<SubtitleTrackInfo> get subtitleTracks => _subtitleTracks;

  int _selectedSubtitleIndex = -1;

  /// 当前生效的字幕轨下标；`-1` = 关闭字幕
  int get selectedSubtitleIndex => _selectedSubtitleIndex;

  /// 字幕轨列表变化（内核就绪后 / 换源后）
  Stream<List<SubtitleTrackInfo>> get subtitleTracksStream =>
      stream.subtitleTracks;

  /// 重新枚举字幕轨（内核就绪后由子类触发）
  Future<void> refreshSubtitleTracks() async {}

  /// 切换字幕轨：`index < 0` 关闭字幕
  Future<void> selectSubtitleTrack(int index) async {}

  /// 子类枚举到字幕轨后广播给 UI
  void publishSubtitleTracks(List<SubtitleTrackInfo> tracks) {
    _subtitleTracks = tracks;
    if (_selectedSubtitleIndex >= tracks.length) _selectedSubtitleIndex = -1;
    if (!_disposed) stream.addSubtitleTracks(tracks);
  }

  /// 子类在原生侧确认当前生效轨后同步
  void setSelectedSubtitleIndex(int index) {
    _selectedSubtitleIndex = index;
  }

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

  /// `open()` 的代次号：用于**并发 / 重入**保护。
  ///
  /// 详情页快速连续换集 / 换线路 / 重试时，两次 `open()` 会交叠：第二次会把
  /// 第一次仍在 `initialize()`（最长 30s）里用着的 controller `dispose` 掉，
  /// 第一次恢复后再 `_attach` + `stream.addPosition`，就作用在**已 dispose 的
  /// controller / 已关闭的 StreamController** 上（`StateError: Cannot add event
  /// after closing`；而且该异常还可能落进 catch 里再 `addError` 一次 →
  /// 未捕获异步异常）。代次号让过期的那一次直接放弃。
  int _openGen = 0;

  Future<void> open(AppMedia media, {bool play = true}) async {
    final gen = ++_openGen;
    _completedNotified = false;
    final old = _vc;
    if (old != null) {
      // 先把引用摘掉：即便下面 `dispose()` 的 await 期间有**并发** open 插进来，
      // 它看到的 `_vc` 已是 null，不会再 dispose 同一个 controller（双重 dispose
      // 在 debug 下会触发 ChangeNotifier 的断言）。
      _vc = null;
      if (_ownsController) {
        try {
          await old.dispose();
        } catch (_) {}
      } else {
        try {
          old.removeListener(_pullState);
        } catch (_) {}
      }
    }
    // 过期（有更新的 open 接管）或播放器已销毁 → 放弃本次
    if (_disposed || gen != _openGen) return;

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
      // ⚠️ 2026-10-14：加超时 —— 挂起型直链（收下请求不发数据也不断开）会让
      //   `initialize()` 的 Future **永久 pending**，其后所有逻辑（seek / 续播
      //   兜底）永不执行，用户点重试还会不断叠加挂起的原生调用。
      await vc.initialize().timeout(const Duration(seconds: 30));
      // 过期/已销毁 → 放弃：此时 vc 或已被更新的 open 覆盖（它会负责 dispose），
      //   或已被 dispose() 释放；这里**不要**再动 stream / listener。
      if (_disposed || gen != _openGen) return;
      _attach(vc);
      _pullState();
      stream.addDuration(vc.value.duration);
      stream.addPosition(vc.value.position);
      if (media.start != null && media.start! > Duration.zero) {
        await vc.seekTo(media.start!);
        if (_disposed || gen != _openGen) return;
        _s.position = media.start!;
        stream.addPosition(_s.position);
      }
      if (play) {
        await vc.play();
        if (_disposed || gen != _openGen) return;
        _s.playing = true;
        stream.addPlaying(true);
      }
    } catch (e) {
      // 已销毁/已过期时绝不能再往已关闭的 stream 上 add
      if (_disposed || gen != _openGen) return;
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
      } else {
        // 共享的 controller 不能 dispose（别人还在用），但必须**停住** ——
        // 否则页面已经关了、声音还在放（用户反馈「像多个播放器在运行」）。
        try {
          await vc.pause();
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
    // mpv 后端
    final mpvBuilder = player.mpvVideoBuilder;
    if (mpvBuilder != null) {
      return mpvBuilder(fit: fit, aspectRatio: aspectRatio);
    }
    // iOS 共享 AVPlayer：UiKitView（与小窗同一 layer）
    final platformBuilder = player.platformViewBuilder;
    if (platformBuilder != null) {
      return platformBuilder(fit: fit, aspectRatio: aspectRatio);
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
