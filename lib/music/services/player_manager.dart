import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../models/models.dart';
import '../models/third_party_source.dart';
import 'music_api.dart';
import 'settings_store.dart';
import 'unblock_service.dart';
import '../../services/audio_focus.dart';

/// 播放模式（对齐 Beans 的循环/随机语义）
enum PlayMode {
  list('列表循环'),
  single('单曲循环'),
  shuffle('随机播放');

  const PlayMode(this.label);
  final String label;
}

/// 音乐播放核心 —— 移植自 Beans-Music 的 `PlayerManager.swift`。
///
/// ── 与影视侧的关系 ────────────────────────────────────────────
/// **完全独立**：自己持有 media_kit Player、自己的队列、自己的进度。
/// 不碰 `BackgroundAudio` / `PipManager`，也不共用 `MusicPlayerController`
/// （那是早期按猫影风格做的，现在按 Beans 的结构重建）。
///
/// ── 为什么用 media_kit 而不是 AVPlayer ────────────────────────
/// media_kit 已在依赖里（影视侧在用），是**纯 Dart API + 已有原生库**，
/// 不需要为音乐再引原生插件；它对音频流的兼容性也好于系统播放器。
class MusicPlayerManager extends ChangeNotifier {
  MusicPlayerManager._();
  static final MusicPlayerManager instance = MusicPlayerManager._();

  late final Player _player;
  bool _inited = false;

  /// 当前歌曲
  Song? get currentSong => _currentSong;
  Song? _currentSong;

  /// 播放队列
  final List<Song> _queue = [];
  List<Song> get queue => List.unmodifiable(_queue);

  int _index = -1;
  int get currentIndex => _index;

  /// 播放状态
  final isPlaying = ValueNotifier<bool>(false);
  final isBuffering = ValueNotifier<bool>(false);

  /// 进度
  final position = ValueNotifier<Duration>(Duration.zero);
  final duration = ValueNotifier<Duration>(Duration.zero);

  /// 音量 0~100
  final volume = ValueNotifier<double>(100);

  /// 播放模式
  final mode = ValueNotifier<PlayMode>(PlayMode.list);

  /// 当前歌词
  final lyrics = ValueNotifier<List<LyricLine>>(const []);

  /// 当前高亮到第几行（-1 = 还没到）
  final lyricIndex = ValueNotifier<int>(-1);

  /// 歌词时间偏移（ms）。有些歌词文件整体偏早/偏晚，给用户手动校正。
  final lyricOffset = ValueNotifier<int>(0);

  /// 失败提示（不要静默失败 —— 用户会以为是卡了）
  final lastError = ValueNotifier<String>('');

  /// 正在回退到第三方音源（逐个试可能要几秒，UI 要显示进度）
  final switching = ValueNotifier<bool>(false);

  /// 播放地址解析结果里带的音质说明（如"320K"）
  final qualityText = ValueNotifier<String>('');

  StreamSubscription? _posSub;
  StreamSubscription? _durSub;
  StreamSubscription? _playSub;
  StreamSubscription? _bufSub;
  StreamSubscription? _compSub;

  /// 歌曲自然播完（用于自动下一首）
  VoidCallback? onCompleted;

  Future<void> init() async {
    // 注册到全局音频焦点协调器：影视/直播要出声时会调这里的 pause()。
    // ⚠️ 不注册的话「看视频时音乐还在响」—— 音乐完全不在互斥体系里。
    AudioFocus.register('music', pause);
    if (_inited) return;
    _inited = true;
    _player = Player();

    _posSub = _player.stream.position.listen((p) {
      position.value = p;
      final idx = LyricParser.indexAt(
        lyrics.value,
        p + Duration(milliseconds: lyricOffset.value),
      );
      if (idx != lyricIndex.value) lyricIndex.value = idx;
    });
    _durSub = _player.stream.duration.listen((d) => duration.value = d);
    _playSub = _player.stream.playing.listen((v) => isPlaying.value = v);
    _bufSub = _player.stream.buffering.listen((v) => isBuffering.value = v);
    _compSub = _player.stream.completed.listen((done) {
      if (!done) return;
      final cb = onCompleted;
      if (cb != null) {
        cb();
      } else {
        next(auto: true);
      }
    });
    notifyListeners();
  }

  // ============================================================
  // 播放
  // ============================================================

  /// 播放单首（替换队列）
  Future<void> playSong(Song song, {List<Song>? fromQueue}) async {
    await init();
    if (fromQueue != null && fromQueue.isNotEmpty) {
      _queue
        ..clear()
        ..addAll(fromQueue);
      _index = _queue.indexWhere((s) => s.identityKey == song.identityKey);
      if (_index < 0) {
        _queue.insert(0, song);
        _index = 0;
      }
    } else {
      _queue
        ..clear()
        ..add(song);
      _index = 0;
    }
    await _load(_index, autoplay: true);
  }

  /// 用整个队列替换并播放第 [index] 首
  Future<void> playQueue(List<Song> songs, {int index = 0}) async {
    await init();
    if (songs.isEmpty) return;
    _queue
      ..clear()
      ..addAll(songs);
    _index = index.clamp(0, _queue.length - 1);
    await _load(_index, autoplay: true);
  }

  /// 插入到下一首播放
  Future<void> playNext(Song song) async {
    await init();
    if (_queue.isEmpty) return playSong(song);
    var at = _index + 1;
    if (at > _queue.length) at = _queue.length;
    _queue.insert(at, song);
    notifyListeners();
  }

  /// 追加到队列尾部
  Future<void> addToQueue(Song song) async {
    await init();
    if (_queue.isEmpty) return playSong(song);
    _queue.add(song);
    notifyListeners();
  }

  Future<void> _load(int index, {required bool autoplay}) async {
    if (index < 0 || index >= _queue.length) return;
    _index = index;
    final song = _queue[index];
    _currentSong = song;
    lastError.value = '';
    qualityText.value = '';
    switching.value = false;
    lyrics.value = const [];
    lyricIndex.value = -1;
    position.value = Duration.zero;
    // song.duration 是秒，Duration 要命名参数
    duration.value = Duration(seconds: song.duration.round());
    notifyListeners();

    // 1) 解析播放地址
    //
    // 顺序：**内置公开接口 → 用户导入的第三方音源**。
    // 内置接口能拿到绝大多数免费歌；拿不到时（VIP/独家/接口变动）
    // 才回退到音源，这样正常播放不会因为用户装了个坏源而变慢。
    var url = '';
    var quality = '';
    var fromSource = '';

    // ⚠️ 必须把用户在设置里选的音质传过去。
    // 之前是 `songUrl(song.id)` —— 它会退到默认 exhigh(320K)，
    // 于是"音质"设置能选能存却**从未生效**（典型的假设置）。
    final wantQuality = SettingsStore.instance.audioQuality.value;
    final r = await MusicApi.instance.songUrl(song.id, quality: wantQuality);
    if (r.ok && r.url.isNotEmpty) {
      url = r.url;
      quality = r.qualityText;
    } else {
      final builtinMsg = r.noFreeSource
          ? '内置接口没有免费音源'
          : (r.message.isNotEmpty ? r.message : '内置接口取地址失败');

      // 回退到第三方音源（仅当开关打开且确有启用的源）
      if (SettingsStore.instance.useThirdPartySources.value &&
          ThirdPartySourceStore.instance.enabled.isNotEmpty) {
        switching.value = true;
        notifyListeners();
        final sr = await UnblockService.instance.resolve(
          song,
          onProgress: (i, total, name) {
            // 逐个试可能要几秒，必须反馈"正在试第 N/M 个"，
            // 否则用户以为卡死了
            lastError.value = '正在尝试音源 $i/$total：$name';
          },
        );
        switching.value = false;
        if (sr.ok && sr.url.isNotEmpty) {
          url = sr.url;
          fromSource = sr.source?.name ?? '';
          quality = sr.source?.quality ?? '';
        } else {
          // 都失败：把「内置为什么失败」+「每个源为什么失败」一起说清楚
          final detail = UnblockService.instance.describeFailure();
          lastError.value = detail.isEmpty
              ? builtinMsg
              : '$builtinMsg；$detail';
          isPlaying.value = false;
          notifyListeners();
          return;
        }
      } else {
        // 没有可用音源时，明确告知 —— 这是正常业务结果（VIP/独家），不是异常
        lastError.value = r.noFreeSource
            ? '这首没有免费音源（可能需要会员）'
            : builtinMsg;
        isPlaying.value = false;
        notifyListeners();
        return;
      }
    }

    qualityText.value = fromSource.isNotEmpty
        ? (quality.isEmpty ? fromSource : '$quality · $fromSource')
        : quality;
    notifyListeners();

    // 2) 播放
    try {
      // 音乐要出声了 → 让影视/直播先闭嘴（互斥的核心：
    // 看视频时音乐还在响 / 听音乐时点视频两边一起响，都是缺这一步）
    if (autoplay) await AudioFocus.request('music');
    await _player.open(Media(url), play: autoplay);
    } catch (e) {
      lastError.value = '播放失败：$e';
      isPlaying.value = false;
      return;
    }

    // 3) 取歌词（失败不影响播放）
    unawaited(_loadLyric(song.id));
  }

  Future<void> _loadLyric(int id) async {
    try {
      final l = await MusicApi.instance.lyric(id);
      if (l == null) return;
      lyrics.value = LyricParser.parse(l.lyric, translation: l.translation);
      lyricIndex.value = LyricParser.indexAt(
        lyrics.value,
        position.value + Duration(milliseconds: lyricOffset.value),
      );
    } catch (_) {
      // 歌词拿不到就不显示，不打扰用户
    }
  }

  // ============================================================
  // 控制
  // ============================================================

  Future<void> toggle() async {
    await init();
    if (_currentSong == null) return;
    await _player.playOrPause();
  }

  Future<void> pause() async {
    await init();
    await _player.pause();
  }

  Future<void> resume() async {
    await init();
    await AudioFocus.request('music');
    await _player.play();
  }

  /// 下一首。[auto] = 自动切歌（单曲循环时不切）
  Future<void> next({bool auto = false}) async {
    await init();
    if (_queue.isEmpty) return;
    if (auto && mode.value == PlayMode.single) {
      await _load(_index, autoplay: true);
      return;
    }
    if (mode.value == PlayMode.shuffle && _queue.length > 1) {
      var n = _index;
      while (n == _index) {
        n = DateTime.now().microsecondsSinceEpoch % _queue.length;
      }
      await _load(n, autoplay: true);
      return;
    }
    final n = _index + 1;
    if (n >= _queue.length) {
      if (auto && mode.value == PlayMode.list) {
        await _load(0, autoplay: true);
      }
      return;
    }
    await _load(n, autoplay: true);
  }

  Future<void> previous() async {
    await init();
    if (_queue.isEmpty) return;
    // 播放超过 3 秒 → 先回到本曲开头（和主流播放器一致）
    if (position.value.inSeconds > 3) {
      await seek(Duration.zero);
      return;
    }
    final p = _index - 1;
    await _load(p < 0 ? _queue.length - 1 : p, autoplay: true);
  }

  Future<void> jumpTo(int index) async {
    await init();
    if (index < 0 || index >= _queue.length) return;
    await _load(index, autoplay: true);
  }

  Future<void> seek(Duration d) async {
    await init();
    await _player.seek(d);
  }

  /// 相对拖动（±15 秒）
  Future<void> seekBy(Duration delta) async {
    final target = position.value + delta;
    await seek(target < Duration.zero ? Duration.zero : target);
  }

  Future<void> setVolume(double v) async {
    await init();
    volume.value = v.clamp(0, 100);
    await _player.setVolume(volume.value);
  }

  void setMode(PlayMode m) {
    mode.value = m;
    notifyListeners();
  }

  void cycleMode() {
    final all = PlayMode.values;
    setMode(all[(all.indexOf(mode.value) + 1) % all.length]);
  }

  /// 从队列移除
  Future<void> removeAt(int index) async {
    if (index < 0 || index >= _queue.length) return;
    final wasCurrent = index == _index;
    _queue.removeAt(index);
    if (_queue.isEmpty) {
      _currentSong = null;
      _index = -1;
      await _player.stop();
      notifyListeners();
      return;
    }
    if (wasCurrent) {
      await _load(index.clamp(0, _queue.length - 1), autoplay: isPlaying.value);
    } else if (index < _index) {
      _index--;
    }
    notifyListeners();
  }

  Future<void> clearQueue() async {
    _queue.clear();
    _index = -1;
    _currentSong = null;
    lyrics.value = const [];
    await _player.stop();
    notifyListeners();
  }

  /// 设置歌词偏移并立刻重算高亮
  void setLyricOffset(int ms) {
    lyricOffset.value = ms;
    lyricIndex.value = LyricParser.indexAt(
      lyrics.value,
      position.value + Duration(milliseconds: ms),
    );
  }

  bool isCurrent(Song s) => _currentSong?.identityKey == s.identityKey;

  @override
  void dispose() {
    AudioFocus.unregister('music');
    _posSub?.cancel();
    _durSub?.cancel();
    _playSub?.cancel();
    _bufSub?.cancel();
    _compSub?.cancel();
    _player.dispose();
    super.dispose();
  }
}
