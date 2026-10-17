import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 听书的锁屏 / 控制中心媒体控制（iOS）。
///
/// 与音乐共用 `MPNowPlayingInfoCenter`，但走独立 channel：
///   · `activate()` 时注册远程命令并写入元数据
///   · `deactivate()` 时移除命令并清空信息
/// 其它平台 / 未注册原生通道时全部静默降级，不影响朗读。
class TtsNowPlaying {
  TtsNowPlaying._();
  static final TtsNowPlaying instance = TtsNowPlaying._();

  static const _ch = MethodChannel('tvbox/tts_now_playing');

  bool _initialized = false;
  bool _active = false;

  String title = '听书';
  String subtitle = '';
  int position = 0;
  int duration = 0;
  bool playing = false;

  /// 远程按键回调（由 TtsService 注入）
  void Function(String action)? onRemote;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method != 'remote') return null;
      final args = call.arguments;
      final action = args is Map ? '${args['action'] ?? ''}' : '';
      if (action.isNotEmpty) onRemote?.call(action);
      return null;
    });
  }

  Future<void> activate() async {
    await init();
    _active = true;
    try {
      await _ch.invokeMethod('activate');
    } on MissingPluginException {
      // 非 iOS / 未注册：忽略
    } catch (e) {
      debugPrint('[TtsNowPlaying] activate 失败: $e');
    }
  }

  Future<void> deactivate() async {
    if (!_active) return;
    _active = false;
    try {
      await _ch.invokeMethod('deactivate');
    } catch (_) {}
  }

  Future<void> update({
    String? title,
    String? subtitle,
    int? position,
    int? duration,
    bool? playing,
  }) async {
    if (title != null) this.title = title;
    if (subtitle != null) this.subtitle = subtitle;
    if (position != null) this.position = position;
    if (duration != null) this.duration = duration;
    if (playing != null) this.playing = playing;
    if (!_active) return;
    try {
      await _ch.invokeMethod('update', {
        'title': this.title,
        'subtitle': this.subtitle,
        'position': this.position,
        'duration': this.duration,
        'playing': this.playing,
      });
    } catch (_) {
      // 原生未注册时忽略
    }
  }

  Future<void> setPlaying(bool value) => update(playing: value);

  Future<void> clear() async {
    try {
      await _ch.invokeMethod('clear');
    } catch (_) {}
  }
}
