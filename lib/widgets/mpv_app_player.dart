import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart' as mk;

import '../models/player_engine.dart';
import '../services/app_log.dart';
import 'app_player.dart';

/// media_kit / libmpv 实现的 [AppPlayer] 适配层。
/// 与 AVPlayer 后端共用同一套调用面，供设置里选「MPV」时使用。
class MpvAppPlayer extends AppPlayer {
  late final Player _mpv;
  late final mk.VideoController _mkController;
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _disposed = false;
  bool _completedNotified = false;

  /// 原始字幕轨（保留 media_kit 的 SubtitleTrack 对象，选轨时直接回传内核）。
  List<SubtitleTrack> _rawSubtitleTracks = const [];

  MpvAppPlayer({super.config}) {
    _mpv = Player(
      configuration: PlayerConfiguration(title: config.title),
    );
    _mkController = mk.VideoController(_mpv);
    mpvVideoBuilder = ({BoxFit fit = BoxFit.contain, double? aspectRatio}) {
      return mk.Video(
        controller: _mkController,
        controls: null,
        fit: fit,
        aspectRatio: aspectRatio,
      );
    };
    _bind();
  }

  void _bind() {
    _subs.add(_mpv.stream.playing.listen((v) {
      stream.addPlaying(v);
    }));
    _subs.add(_mpv.stream.buffering.listen((v) {
      stream.addBuffering(v);
    }));
    _subs.add(_mpv.stream.position.listen((v) {
      stream.addPosition(v);
    }));
    _subs.add(_mpv.stream.duration.listen((v) {
      stream.addDuration(v);
    }));
    _subs.add(_mpv.stream.completed.listen((v) {
      if (v && !_completedNotified) {
        _completedNotified = true;
        stream.addCompleted(true);
      } else if (!v) {
        _completedNotified = false;
      }
    }));
    _subs.add(_mpv.stream.error.listen((e) {
      if (e.isNotEmpty) stream.addError(e);
    }));
    _subs.add(_mpv.stream.rate.listen((v) {
      stream.addRate(v);
    }));
    // 字幕轨：tracks 是全量列表（前两条是 media_kit 合成的 auto / no，要滤掉），
    // track 是当前生效轨（no = 已关闭；auto = 内核自行选择，Dart 侧按「未选中」处理）
    _subs.add(_mpv.stream.tracks.listen((t) {
      _rawSubtitleTracks = t.subtitle
          .where((s) => s.id != 'auto' && s.id != 'no')
          .toList(growable: false);
      publishSubtitleTracks(
        _rawSubtitleTracks.map(_toSubtitleInfo).toList(growable: false),
      );
    }));
    _subs.add(_mpv.stream.track.listen((t) {
      final sub = t.subtitle;
      setSelectedSubtitleIndex(
        sub.id == 'auto'
            ? -1
            : _rawSubtitleTracks.indexWhere((s) => s.id == sub.id),
      );
    }));
  }

  @override
  bool get supportsSubtitles => true;

  SubtitleTrackInfo _toSubtitleInfo(SubtitleTrack t) {
    final title = t.title?.trim() ?? '';
    final lang = t.language?.trim() ?? '';
    return SubtitleTrackInfo(
      id: t.id,
      name: title.isNotEmpty
          ? title
          : (lang.isNotEmpty ? lang : '字幕 ${t.id}'),
      language: t.language,
      isImage: t.image == true,
    );
  }

  @override
  Future<void> selectSubtitleTrack(int index) async {
    if (index < 0 || index >= _rawSubtitleTracks.length) {
      await _mpv.setSubtitleTrack(SubtitleTrack.no());
      setSelectedSubtitleIndex(-1);
      return;
    }
    await _mpv.setSubtitleTrack(_rawSubtitleTracks[index]);
    setSelectedSubtitleIndex(index);
  }

  Player get mpv => _mpv;

  @override
  AppPlayerStateView get state => _MpvStateView(_mpv);

  /// 应用 MPV 专有选项（解码 / 缓冲），切换内核后新建实例时调用
  void applyOptions({
    VideoDecodeMode decode = VideoDecodeMode.auto,
    VLCBufferMode buffer = VLCBufferMode.balanced,
  }) {
    void setProp(String k, String v) {
      try {
        final dynamic native = _mpv.platform;
        native.setProperty(k, v);
      } catch (e) {
        AppLog.instance.log('[MpvAppPlayer] setProperty($k) skip: $e');
      }
    }

    setProp('hwdec', decode.mpvHardwareDecodeOption ?? 'auto');
    final c = buffer.cacheConfig(isLive: false);
    setProp('cache', 'yes');
    setProp('demuxer-max-bytes', '${(c.network * 256).clamp(1024 * 512, 1024 * 1024 * 64)}');
    setProp('demuxer-max-back-bytes', '${(c.file * 128).clamp(1024 * 256, 1024 * 1024 * 32)}');
    if (buffer.enableFrameDrop) {
      setProp('framedrop', 'vo');
    }
    AppLog.instance.log(
        '[MpvAppPlayer] applyOptions decode=$decode buffer=$buffer');
  }

  @override
  Future<void> open(AppMedia media, {bool play = true}) async {
    _completedNotified = false;
    // 换源：旧的字幕轨列表立即清空，等新媒体的 tracks 事件回来再填充，
    // 避免 UI 短暂显示上一个源的轨道
    _rawSubtitleTracks = const [];
    publishSubtitleTracks(const <SubtitleTrackInfo>[]);
    setSelectedSubtitleIndex(-1);
    _mpv.open(Media(
      media.url,
      httpHeaders: media.httpHeaders,
      start: media.start,
    ));
    if (!play) {
      // media_kit open 即播，再 pause
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await _mpv.pause();
      stream.addPlaying(false);
    }
  }

  @override
  Future<void> play() async {
    await _mpv.play();
    stream.addPlaying(true);
  }

  @override
  Future<void> pause() async {
    await _mpv.pause();
    stream.addPlaying(false);
  }

  @override
  Future<void> seek(Duration target) async {
    await _mpv.seek(target);
    stream.addPosition(target);
  }

  @override
  Future<void> setRate(double rate) async {
    await _mpv.setRate(rate);
    stream.addRate(rate);
  }

  @override
  Future<void> setVolume(double v) async {
    await _mpv.setVolume(v.clamp(0.0, 100.0));
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    try {
      await _mpv.dispose();
    } catch (_) {}
    // 关闭 stream 等基类资源
    await super.dispose();
  }
}

class _MpvStateView implements AppPlayerStateView {
  final Player _p;
  _MpvStateView(this._p);
  @override
  bool get playing => _p.state.playing;
  @override
  bool get buffering => _p.state.buffering;
  @override
  Duration get position => _p.state.position;
  @override
  Duration get duration => _p.state.duration;
  @override
  double get rate => _p.state.rate;
  @override
  double get volume => _p.state.volume;
  @override
  double get width => (_p.state.width ?? 0).toDouble();
  @override
  double get height => (_p.state.height ?? 0).toDouble();
  @override
  ({List<AppMedia> medias}) get playlist => (
        medias: [
          if (_p.state.playlist.medias.isNotEmpty)
            AppMedia(_p.state.playlist.medias.last.uri)
        ],
      );
}
