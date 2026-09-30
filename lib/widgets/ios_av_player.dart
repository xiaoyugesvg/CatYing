import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_player.dart';

/// iOS 专用：与系统小窗共用同一个原生 AVPlayer（AvEngine）。
/// 进/出小窗视频连续，不会「一个播一个停」。
class IosAvPlayer extends AppPlayer {
  static const _channel = MethodChannel('av_engine');
  static final ValueNotifier<bool> needsPlatformView = ValueNotifier(true);

  /// MethodChannel 的处理器**全进程只能有一个**。
  ///
  /// 旧写法在构造函数里 `_channel.setMethodCallHandler(_onNativeCall)`：
  /// 直播页与详情页各自 `??=` 创建一个 IosAvPlayer，后创建的那个会把处理器
  /// 覆盖掉，先创建者从此收不到 onPosition/onError/onCompleted。
  /// 而原生 AvEngine 是全局单例，事件本身就是"共享播放器的事件"，
  /// 只应投递给当前真正在驱动它的那个实例。
  static IosAvPlayer? _activeInstance;
  static bool _handlerInstalled = false;

  static void _ensureHandlerInstalled() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      return _activeInstance?._onNativeCall(call);
    });
  }

  IosAvPlayer({super.config}) {
    _ensureHandlerInstalled();
    // 抢占"活跃"身份：最近一次 open() 的实例才是共享播放器的当前主人
    _activeInstance = this;
    _startSizePolling();
    platformViewBuilder = ({BoxFit fit = BoxFit.contain, double? aspectRatio}) {
      return IosAvPlayerView(
        player: this,
        fit: fit,
        aspectRatio: aspectRatio,
      );
    };
  }

  String _url = '';
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _buffering = true;

  /// 真实倍速/音量（0-100）。
  ///
  /// 旧实现让 `_IosState.rate` 恒返回 1.0、`volume` 恒返回 100，而
  /// video_player.dart 的 initState 用它们初始化 UI 状态 → 每次重建（全屏切换/
  /// 旋转/返回）都把界面上的倍速和音量重置，与原生 AVPlayer 的真实值发散
  /// （界面显示 1X，实际仍在 2 倍速播）。这里保存真实值供 state 读取。
  double _rate = 1.0;
  double _volume = 100;

  /// 真实画面分辨率（由原生 AVPlayerItem.presentationSize 回传）。
  /// 0 表示未就绪/纯音频；video_player.dart 的播放信息面板据此显示。
  double _videoWidth = 0;
  double _videoHeight = 0;

  /// 分辨率轮询：原生的 presentationSize 只在 ready 后才可靠，且 Dart 侧
  /// 没有任何地方调 getState（播放器每秒定时器读的是 state.width/height），
  /// 所以这里自己按秒拉一次，供 _IosState 读取。
  Timer? _sizePoller;

  void _startSizePolling() {
    if (_sizePoller != null) return;
    _sizePoller = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!identical(_activeInstance, this)) return;
      try {
        final st = await _channel.invokeMethod<Map<dynamic, dynamic>>('getState');
        if (st == null) return;
        final w = (st['videoWidth'] as num?)?.toDouble() ?? 0;
        final h = (st['videoHeight'] as num?)?.toDouble() ?? 0;
        if (w > 0 && h > 0 && (w != _videoWidth || h != _videoHeight)) {
          _videoWidth = w;
          _videoHeight = h;
        }
      } catch (_) {
        // 拉取失败不影响播放，下一轮再试
      }
    });
  }

  Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onPlaying':
        _playing = call.arguments == true;
        stream.addPlaying(_playing);
        break;
      case 'onPosition':
        final s = (call.arguments as num?)?.toDouble() ?? 0;
        _position = Duration(milliseconds: (s * 1000).round());
        stream.addPosition(_position);
        break;
      case 'onDuration':
        final s = (call.arguments as num?)?.toDouble() ?? 0;
        _duration = Duration(milliseconds: (s * 1000).round());
        stream.addDuration(_duration);
        break;
      case 'onReady':
        _buffering = false;
        stream.addBuffering(false);
        break;
      case 'onCompleted':
        stream.addCompleted(true);
        break;
      case 'onError':
        stream.addError('${call.arguments}');
        break;
    }
    return null;
  }

  @override
  bool get isSharedIosAv => true;

  @override
  AppPlayerStateView get state => _IosState(this);

  @override
  Future<void> open(AppMedia media, {bool play = true}) async {
    // 谁最后 open，谁就是共享 AvEngine 播放器的当前主人 → 事件归它
    _activeInstance = this;
    _url = media.url;
    _buffering = true;
    stream.addBuffering(true);
    await _channel.invokeMethod('open', {
      'url': media.url,
      'headers': media.httpHeaders ?? const <String, String>{},
      'positionMs': (media.start?.inMilliseconds ?? 0),
    });
    if (!play) {
      await pause();
    } else {
      _playing = true;
      stream.addPlaying(true);
    }
  }

  @override
  Future<void> play() async {
    await _channel.invokeMethod('play');
    _playing = true;
    stream.addPlaying(true);
  }

  @override
  Future<void> pause() async {
    await _channel.invokeMethod('pause');
    _playing = false;
    stream.addPlaying(false);
  }

  @override
  Future<void> seek(Duration target) async {
    await _channel.invokeMethod('seek', target.inMilliseconds);
    _position = target;
    stream.addPosition(target);
  }

  @override
  Future<void> setRate(double rate) async {
    _rate = rate;
    await _channel.invokeMethod('setRate', rate);
    stream.addRate(rate);
  }

  @override
  Future<void> setVolume(double v) async {
    _volume = v.clamp(0.0, 100.0);
    await _channel.invokeMethod('setVolume', _volume / 100.0);
  }

  @override
  Future<void> dispose() async {
    _sizePoller?.cancel();
    _sizePoller = null;
    try {
      await _channel.invokeMethod('pause');
    } catch (_) {}
    // 只有自己还是活跃实例时才让位，避免把别人的身份清掉
    if (identical(_activeInstance, this)) {
      _activeInstance = null;
    }
    await super.dispose();
  }
}

class _IosState extends AppPlayerStateView {
  final IosAvPlayer _p;
  _IosState(this._p);
  @override
  bool get playing => _p._playing;
  @override
  bool get buffering => _p._buffering;
  @override
  Duration get position => _p._position;
  @override
  Duration get duration => _p._duration;
  @override
  double get rate => _p._rate;
  @override
  double get volume => _p._volume;
  @override
  double get width => _p._videoWidth;
  @override
  double get height => _p._videoHeight;
  @override
  ({List<AppMedia> medias}) get playlist => (
        medias: [if (_p._url.isNotEmpty) AppMedia(_p._url)],
      );
}

/// 应用内画面：UiKitView 挂 AvEngine 的唯一 AVPlayerLayer
class IosAvPlayerView extends StatelessWidget {
  final IosAvPlayer player;
  final BoxFit fit;
  final double? aspectRatio;
  const IosAvPlayerView({
    super.key,
    required this.player,
    this.fit = BoxFit.contain,
    this.aspectRatio,
  });

  @override
  Widget build(BuildContext context) {
    final view = UiKitView(
      viewType: 'av_player_view',
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      creationParams: const <String, dynamic>{},
      creationParamsCodec: const StandardMessageCodec(),
    );
    if (aspectRatio != null) {
      return AspectRatio(aspectRatio: aspectRatio!, child: view);
    }
    return view;
  }
}

bool get kUseIosSharedAvPlayer => !kIsWeb && Platform.isIOS;
