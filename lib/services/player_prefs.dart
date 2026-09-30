import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/player_engine.dart';
import '../common/constants.dart';

/// 全局播放内核与各内核选项（设置页写入，播放器实时读取）
class PlayerPrefs {
  static final PlayerPrefs instance = PlayerPrefs._();
  PlayerPrefs._();

  /// 当前点播内核
  final vodEngine = PlayerEngine.avplayer.obs;

  /// MPV：解码方式
  final decodeMode = VideoDecodeMode.auto.obs;

  /// MPV：缓冲策略
  final bufferMode = VLCBufferMode.balanced.obs;

  /// AVPlayer：自动播放下一集（预留）
  final avAutoNext = true.obs;

  /// Webview：强制横屏
  final webviewForceLandscape = true.obs;

  /// Webview：允许页面 JS（解析站需要）
  final webviewEnableJs = true.obs;

  /// 静音后台保活 Node（关掉更省电、锁屏无「播放中」，但 Node 可能被冻结）
  final silentKeepAlive = true.obs;

  /// 快进步长（秒）
  final playTimeStep = 10.obs;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    // 旧值迁移：
    // 老枚举 mpv=0, webview=1
    // 新枚举 avplayer=0, mpv=1, webview=2
    final raw = prefs.getInt(AppConstants.playTypeVod);
    int mapped;
    if (raw == null) {
      mapped = PlayerEngine.avplayer.value;
    } else if (raw == 1) {
      // 老 webview=1 / 新 mpv=1 冲突：若从未写过 2，按老 webview 处理
      // 简化：1 → mpv（新），用户可在设置改
      mapped = PlayerEngine.mpv.value;
    } else if (raw == 0) {
      // 老 mpv=0 / 新 avplayer=0：升级为 AVPlayer 主内核
      mapped = PlayerEngine.avplayer.value;
    } else {
      mapped = raw;
    }
    await prefs.setInt(AppConstants.playTypeVod, mapped);
    vodEngine.value = PlayerEngine.fromStoredValue(mapped);

    decodeMode.value =
        VideoDecodeMode.fromStoredValue(prefs.getInt('play_decode_mode') ?? 0);
    bufferMode.value =
        VLCBufferMode.fromStoredValue(prefs.getInt('play_vlc_buffer_mode') ?? 0);
    avAutoNext.value = prefs.getBool('av_auto_next') ?? true;
    webviewForceLandscape.value =
        prefs.getBool('webview_force_landscape') ?? true;
    webviewEnableJs.value = prefs.getBool('webview_enable_js') ?? true;
    final step = prefs.getInt('play_time_step') ?? 0;
    playTimeStep.value = step > 0 ? step : 10;
    silentKeepAlive.value = prefs.getBool('silent_keepalive') ?? true;
  }

  Future<void> setEngine(PlayerEngine e) async {
    vodEngine.value = e;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(AppConstants.playTypeVod, e.value);
  }

  Future<void> setDecodeMode(VideoDecodeMode m) async {
    decodeMode.value = m;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('play_decode_mode', m.value);
  }

  Future<void> setBufferMode(VLCBufferMode m) async {
    bufferMode.value = m;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('play_vlc_buffer_mode', m.value);
  }

  Future<void> setAvAutoNext(bool v) async {
    avAutoNext.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('av_auto_next', v);
  }

  Future<void> setWebviewForceLandscape(bool v) async {
    webviewForceLandscape.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('webview_force_landscape', v);
  }

  Future<void> setWebviewEnableJs(bool v) async {
    webviewEnableJs.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('webview_enable_js', v);
  }

  Future<void> setSilentKeepAlive(bool v) async {
    silentKeepAlive.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('silent_keepalive', v);
  }

  Future<void> setPlayTimeStep(int s) async {
    if (s <= 0) return;
    playTimeStep.value = s;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('play_time_step', s);
  }
}
