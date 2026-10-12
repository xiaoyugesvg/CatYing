import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_player.dart';

/// iOS 第四播放核心「FF」：KSPlayer（FFmpeg + Metal）。
///
/// - 原生侧 KSEngine.swift 持有全局唯一的 KSPlayerLayer（本身就是 UIView），
///   应用内画面通过 UiKitView('ks_player_view') 上屏；
/// - 控制走 'ks_player' MethodChannel（open/play/pause/seek/setRate/setVolume）；
/// - 首选 KSMEPlayer（FFmpeg 全格式：MKV/ASS/多音轨…），失败自动回退 KSAVPlayer；
/// - 小窗走 KSPlayer 自带 sample-buffer PiP（layer.isPipActive），不走 AVPlayer 的
///   'pip_manager' startPip 路径（见 VideoPlayerPip.enterIosKs）。
///
/// 结构镜像 IosAvPlayer：原生引擎是单例，Dart 侧「最近 open 的实例」是当前主人，
/// 原生事件只投递给它。
class KSPlayer extends AppPlayer {
  static const _channel = MethodChannel('ks_player');

  /// MethodChannel 处理器全进程只能有一个（原因同 IosAvPlayer）：
  /// 直播页与详情页各自创建实例，后创建者会覆盖处理器。
  static KSPlayer? _activeInstance;
  static bool _handlerInstalled = false;

  static void _ensureHandlerInstalled() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      return _activeInstance?._onNativeCall(call);
    });
  }

  KSPlayer({super.config}) {
    _ensureHandlerInstalled();
    // 抢占「活跃」身份：最近一次 open() 的实例才是共享播放器的当前主人
    _activeInstance = this;
    _startSizePolling();
    platformViewBuilder = ({BoxFit fit = BoxFit.contain, double? aspectRatio}) {
      return KSPlayerView(fit: fit, aspectRatio: aspectRatio);
    };
  }

  String _url = '';
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _buffering = true;
  double _rate = 1.0;
  double _volume = 100;

  /// 是否静音。音量拖到 0 / 点静音都置 true，原生侧据此同时下发 `isMuted`
  /// （仅靠 playbackVolume=0，FF(ME) 内核有时不真正静音）。
  bool _muted = false;

  /// 真实画面分辨率（原生 naturalSize 回传），0 表示未就绪/纯音频
  double _videoWidth = 0;
  double _videoHeight = 0;

  /// 分辨率轮询（与 IosAvPlayer 一致：原生尺寸变化时 Dart 侧无事件，
  /// 每秒拉一次 getState 供播放信息面板显示）
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
      case 'onBuffering':
        _buffering = true;
        stream.addBuffering(true);
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
  AppPlayerStateView get state => _KsState(this);

  @override
  Future<void> open(AppMedia media, {bool play = true, bool live = false}) async {
    // 谁最后 open，谁就是共享 KSEngine 的当前主人 → 事件归它
    _activeInstance = this;
    _url = media.url;
    _buffering = true;
    stream.addBuffering(true);
    // 换台/换集复用同一实例（直播页 _ksPlayer ??= 复用）：旧流的时长/进度
    // 立即清零并广播，避免新流 ready 前 UI 短暂显示上一台的残留时长
    _position = Duration.zero;
    _duration = Duration.zero;
    stream.addPosition(Duration.zero);
    stream.addDuration(Duration.zero);
    await _channel.invokeMethod('open', {
      'url': media.url,
      'headers': media.httpHeaders ?? const <String, String>{},
      'positionMs': (media.start?.inMilliseconds ?? 0),
      // 直播流原生侧 AVPlayer 优先（FFmpeg 拆 DVB 数据轨会野指针闪退，
      // 见 KSEngine.open 的 live 分支注释）
      'live': live,
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
    // 音量为 0 视为静音：原生侧显式置 isMuted，保证 FF 内核真正无声；
    // 取消静音（>0）时同时解除 muted 并恢复该音量。
    _muted = _volume <= 0;
    try {
      await _channel.invokeMethod('setVolume', _muted ? 0.0 : _volume / 100.0);
      await _channel.invokeMethod('setMuted', _muted);
    } catch (_) {
      // 通道不可用时不阻断播放
    }
  }

  @override
  Future<void> dispose() async {
    _sizePoller?.cancel();
    _sizePoller = null;
    try {
      // close：销毁原生 KSPlayerLayer（含 PiP 清理）；仅 pause 会常驻占内存
      await _channel.invokeMethod('close');
    } catch (_) {}
    // 只有自己还是活跃实例时才让位，避免把别人的身份清掉
    if (identical(_activeInstance, this)) {
      _activeInstance = null;
    }
    await super.dispose();
  }
}

/// 只读状态视图（对齐 media_kit Player.state 的读取面）
class _KsState extends AppPlayerStateView {
  final KSPlayer _p;
  _KsState(this._p);
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

/// 应用内画面：UiKitView 嵌 KSEngine 的 KSPlayerLayer
class KSPlayerView extends StatelessWidget {
  final BoxFit fit;
  final double? aspectRatio;
  const KSPlayerView({
    super.key,
    this.fit = BoxFit.contain,
    this.aspectRatio,
  });

  @override
  Widget build(BuildContext context) {
    final view = UiKitView(
      viewType: 'ks_player_view',
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
