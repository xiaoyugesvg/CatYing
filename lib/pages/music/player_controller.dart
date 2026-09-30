import 'dart:async';

import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';

import '../../services/app_log.dart';
import '../../services/music_service.dart';

/// 音乐播放器的共享状态（跨页面：播放页、悬浮菜单、全局小条都用它）
///
/// 用 media_kit 的 [Player] 直接放音频 —— 项目已经有 media_kit 依赖，
/// 不必为了放歌再引一个 just_audio。
class MusicPlayerController extends GetxController {
  static MusicPlayerController get instance {
    if (!Get.isRegistered<MusicPlayerController>()) {
      Get.put<MusicPlayerController>(MusicPlayerController(), permanent: true);
    }
    return Get.find<MusicPlayerController>();
  }

  late final Player _player = Player();

  /// 当前播放队列
  final queue = <MusicTrack>[].obs;

  /// 当前下标（-1 = 没有）
  final index = (-1).obs;

  final playing = false.obs;
  final position = Duration.zero.obs;
  final duration = Duration.zero.obs;
  final buffering = false.obs;

  /// 正在取播放地址（LX 脚本要跑几秒）
  final resolving = false.obs;

  /// 最近一次错误
  final error = ''.obs;

  /// 音量 0~1
  final volume = 1.0.obs;

  /// 播放模式：0 顺序 / 1 单曲循环 / 2 随机
  final playMode = 0.obs;

  /// 歌词行（time 秒 + 文本）
  final lyrics = <({double time, String text})>[].obs;

  /// 当前歌词下标
  final lyricIndex = 0.obs;

  StreamSubscription? _posSub;
  StreamSubscription? _durSub;
  StreamSubscription? _playSub;
  StreamSubscription? _bufSub;
  StreamSubscription? _completeSub;

  MusicTrack? get current =>
      (index.value >= 0 && index.value < queue.length)
          ? queue[index.value]
          : null;

  bool get hasTrack => current != null;

  @override
  void onInit() {
    super.onInit();
    _posSub = _player.stream.position.listen((p) {
      position.value = p;
      _syncLyric(p);
    });
    _durSub = _player.stream.duration.listen((d) => duration.value = d);
    _playSub = _player.stream.playing.listen((v) => playing.value = v);
    _bufSub = _player.stream.buffering.listen((v) => buffering.value = v);
    _completeSub = _player.stream.completed.listen((done) {
      if (done) next(auto: true);
    });
  }

  @override
  void onClose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _playSub?.cancel();
    _bufSub?.cancel();
    _completeSub?.cancel();
    _player.dispose();
    super.onClose();
  }

  // ============================================================
  // 播放控制
  // ============================================================

  /// 播放一首（如果它在队列里就直接跳，否则插入当前队列）
  Future<void> playTrack(MusicTrack t, {List<MusicTrack>? list}) async {
    if (list != null && list.isNotEmpty) {
      queue.assignAll(list);
      index.value = queue.indexWhere((e) => e.id == t.id);
      if (index.value < 0) {
        queue.insert(0, t);
        index.value = 0;
      }
    } else {
      final i = queue.indexWhere((e) => e.id == t.id);
      if (i >= 0) {
        index.value = i;
      } else {
        queue.add(t);
        index.value = queue.length - 1;
      }
    }
    await _loadCurrent();
  }

  Future<void> _loadCurrent() async {
    final t = current;
    if (t == null) return;
    resolving.value = true;
    error.value = '';
    lyrics.clear();
    lyricIndex.value = 0;
    try {
      final r = await MusicService.instance.resolveUrl(t);
      if (r.url == null || r.url!.isEmpty) {
        error.value = r.message;
        AppLog.instance.log('[MusicPlayer] 取链失败: ${r.message}');
        return;
      }
      // 把地址回填到队列项，避免重复取链
      queue[index.value] = t.copyWith(audioUrl: r.url);
      queue.refresh();
      await _player.open(Media(r.url!), play: true);
      await _loadLyrics(t);
    } catch (e) {
      error.value = '$e';
      AppLog.instance.log('[MusicPlayer] 播放失败: $e');
    } finally {
      resolving.value = false;
    }
  }

  Future<void> togglePlay() async {
    if (!hasTrack) return;
    if (_player.state.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  Future<void> seek(Duration d) => _player.seek(d);

  Future<void> setVolume(double v) async {
    volume.value = v.clamp(0.0, 1.0);
    await _player.setVolume(volume.value * 100);
  }

  Future<void> next({bool auto = false}) async {
    if (queue.isEmpty) return;
    if (auto && playMode.value == 1) {
      // 单曲循环
      await _player.seek(Duration.zero);
      await _player.play();
      return;
    }
    if (playMode.value == 2 && queue.length > 1) {
      var n = index.value;
      while (n == index.value) {
        n = DateTime.now().microsecondsSinceEpoch % queue.length;
      }
      index.value = n;
    } else {
      index.value = (index.value + 1) % queue.length;
    }
    await _loadCurrent();
  }

  Future<void> prev() async {
    if (queue.isEmpty) return;
    index.value = (index.value - 1 + queue.length) % queue.length;
    await _loadCurrent();
  }

  void cyclePlayMode() => playMode.value = (playMode.value + 1) % 3;

  String get playModeLabel => switch (playMode.value) {
        1 => '单曲循环',
        2 => '随机播放',
        _ => '顺序播放',
      };

  // ============================================================
  // 歌词（LRC）
  // ============================================================

  Future<void> _loadLyrics(MusicTrack t) async {
    // TODO(歌词): 落雪脚本的 lyric action 拿到 LRC 后在这里解析。
    // 现在先只在 audioUrl 里带 lrc 的情况下解析；没有就留空，
    // 播放页会把「词： xxx」那行作为占位显示。
    lyrics.clear();
    lyricIndex.value = 0;
    AppLog.instance.log('[MusicPlayer] 歌词待接入 (${t.title})');
  }

  void _syncLyric(Duration pos) {
    if (lyrics.isEmpty) return;
    final sec = pos.inMilliseconds / 1000.0;
    var i = 0;
    for (var k = 0; k < lyrics.length; k++) {
      if (lyrics[k].time <= sec) {
        i = k;
      } else {
        break;
      }
    }
    if (i != lyricIndex.value) lyricIndex.value = i;
  }

  /// 解析 LRC 文本（供后续歌词源接入时使用）
  static List<({double time, String text})> parseLrc(String lrc) {
    final out = <({double time, String text})>[];
    final re = RegExp(r'\[(\d+):(\d+)(?:[.:](\d+))?\]');
    for (final line in lrc.split('\n')) {
      final m = re.firstMatch(line);
      if (m == null) continue;
      final min = int.tryParse(m.group(1)!) ?? 0;
      final sec = int.tryParse(m.group(2)!) ?? 0;
      final msRaw = m.group(3) ?? '0';
      final ms = int.tryParse(msRaw.padRight(3, '0').substring(0, 3)) ?? 0;
      final text = line.replaceAll(re, '').trim();
      if (text.isEmpty) continue;
      out.add((
        time: min * 60 + sec + ms / 1000.0,
        text: text,
      ));
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  }
}
