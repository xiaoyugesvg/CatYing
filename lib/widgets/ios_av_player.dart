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

  IosAvPlayer({super.config}) {
    _channel.setMethodCallHandler(_onNativeCall);
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
    await _channel.invokeMethod('setRate', rate);
    stream.addRate(rate);
  }

  @override
  Future<void> setVolume(double v) async {
    await _channel.invokeMethod('setVolume', v.clamp(0.0, 100.0) / 100.0);
  }

  @override
  Future<void> dispose() async {
    try {
      await _channel.invokeMethod('pause');
    } catch (_) {}
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
  double get rate => 1.0;
  @override
  double get volume => 100;
  @override
  double get width => 0;
  @override
  double get height => 0;
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
