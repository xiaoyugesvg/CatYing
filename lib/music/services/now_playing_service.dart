import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../services/app_log.dart';
import 'player_manager.dart';

/// **锁屏 / 控制中心 / 耳机按键** 的系统媒体控制接入。
///
/// ── 用户原话（2026）─────────────────────────────────────────────
/// 「苹果系统层次不能控制呢？没有实时活动功能？不能在控制中心控制？」
///
/// ── 原状 ────────────────────────────────────────────────────────
/// 全项目 **0 处** `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`
/// → 锁屏和控制中心**完全看不到音乐**，也没法控制 ✗
///
/// 现在补上两件事（原生侧见 `ios/Runner/MusicNowPlaying.swift`）：
///   ① 把「歌名 / 歌手 / 专辑 / 封面 / 时长 / 进度 / 播放态」推给系统
///   ② 接收系统的 播放 / 暂停 / 上一首 / 下一首 / 拖动进度 并转成播放器动作
///
/// ── ⚠️ 哪些不做（如实说明，别被当成"没做完"）──────────────────────
/// **灵动岛 / 实时活动（Live Activities）**：需要 `ActivityKit` +
/// 一个**独立的 Widget Extension target**（`NSSupportsLiveActivities`
/// + `ActivityAttributes` + 一套 SwiftUI 界面），**不是加一个 Swift 文件
/// 就能做到的**，必须改 Xcode 工程结构（新增 target）。
/// 在 TrollStore 侧载场景下这笔改动风险明显更高，所以这里**不做**，
/// 但留了 `liveActivitiesSupported` 这个方法让 UI 能如实告知用户。
///
/// ── ⚠️ 已测与未测（重要）────────────────────────────────────────
/// · **已测**：`dart analyze` 通过、Dart 侧逻辑有单测
///   （`test/music_now_playing_test.dart`）、MethodChannel 缺原生侧时**不崩**
/// · **未测**：真机上锁屏/控制中心**到底显不显示** ——
///   那需要真机 + 侧载环境，我这里做不到。
///   已知 iOS 的策略是"只在系统认为有音频 App 正在播放时"才露出内容，
///   侧载 + 后台进程的组合比 App Store 包更保守，**不保证 100% 显示**。
///   真机上排查用 [debugState]（会写日志）。
class NowPlayingService {
  NowPlayingService._();
  static final NowPlayingService instance = NowPlayingService._();

  static const MethodChannel _ch = MethodChannel('tvbox/music_now_playing');

  bool _started = false;

  /// 上一次成功推送的歌曲标识 —— 用来判断"换歌了"（换歌才重新下载封面）
  String? _lastSongKey;

  /// 封面字节缓存（按 URL）：**同一首歌反复推元数据时不再重新下载**
  final Map<String, Uint8List?> _artworkCache = {};

  /// 进度上传的节流：iOS 会按 `elapsed + rate × 流逝时间` **自己插值**，
  /// 所以不需要每次 position tick 都上报（那会每 200ms 编码一次封面）。
  DateTime _lastPositionPush = DateTime.fromMillisecondsSinceEpoch(0);
  static const _positionPushInterval = Duration(seconds: 5);

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 6),
    receiveTimeout: const Duration(seconds: 10),
    // 封面很多时候要 UA（网易/喜马拉雅都证实过），不带会 403
    headers: const {'User-Agent': 'Mozilla/5.0'},
  ));

  /// 开始跟随播放器（在 `main()` 里调一次；重复调用无害）
  void start() {
    if (_started) return;
    _started = true;

    final p = MusicPlayerManager.instance;

    // ① 换歌 / 播放态变化 / 时长变化 → 推元数据
    p.addListener(_onPlayerChanged);
    p.isPlaying.addListener(_onPlayingChanged);
    p.duration.addListener(_onPlayerChanged);

    // ② 进度只**节流**推（见 `_positionPushInterval` 的说明）
    p.position.addListener(_onPositionChanged);

    // ③ 接系统远程控制
    _ch.setMethodCallHandler(_onNativeCall);

    AppLog.instance.log('[Music] 锁屏/控制中心 媒体控制已启动');
    // 启动时如果已经在播（恢复队列），立刻同步一次
    _onPlayerChanged();
  }

  // ────────────────────────────────────────────────────────────
  // Dart → 原生
  // ────────────────────────────────────────────────────────────

  void _onPlayingChanged() => _push(forceArtwork: false);

  void _onPlayerChanged() => _push(forceArtwork: false);

  void _onPositionChanged() {
    final now = DateTime.now();
    if (now.difference(_lastPositionPush) < _positionPushInterval) return;
    _lastPositionPush = now;
    _push(forceArtwork: false);
  }

  /// 把当前播放状态推给系统。
  ///
  /// [forceArtwork] 只用于**首次**或**换歌**时 —— 封面要先下载再编码，
  /// 不能每次 tick 都做。
  Future<void> _push({required bool forceArtwork}) async {
    final p = MusicPlayerManager.instance;
    final song = p.currentSong;

    if (song == null) {
      await _invoke('clear');
      _lastSongKey = null;
      return;
    }

    final key = song.identityKey;
    final songChanged = key != _lastSongKey;
    if (songChanged) _lastSongKey = key;

    final args = <String, Object?>{
      'title': song.name,
      'artist': song.artists,
      'album': song.album,
      'duration': p.duration.value.inMilliseconds / 1000.0,
      'position': p.position.value.inMilliseconds / 1000.0,
      'playing': p.isPlaying.value,
    };

    // 封面：换歌时重新取（同一首歌用缓存，不再下载/编码）
    if (songChanged || forceArtwork) {
      final bytes = await _artworkBytes(song.coverUrl);
      if (bytes != null && bytes.isNotEmpty) {
        args['artwork'] = bytes;
      }
    }

    await _invoke('update', args);
  }

  /// 下载封面并返回字节（失败返回 null，不影响其余元数据）。
  ///
  /// ⚠️ 这里**在 Dart 侧下载**而不是把 URL 交给原生：
  ///   · 很多音源封面要 UA/Referer，原生直接 GET 会 403
  ///   · 可以复用 App 已有的网络栈与超时策略
  Future<Uint8List?> _artworkBytes(String? url) async {
    final u = (url ?? '').trim();
    if (u.isEmpty) return null;
    if (_artworkCache.containsKey(u)) return _artworkCache[u];

    try {
      final r = await _dio.get<List<int>>(
        u,
        options: Options(responseType: ResponseType.bytes),
      );
      final data = r.data;
      if (data == null || data.isEmpty) {
        _artworkCache[u] = null;
        return null;
      }
      // 上限 2 MB：锁屏封面不需要更大，避免把 MethodChannel 撑爆
      if (data.length > 2 * 1024 * 1024) {
        AppLog.instance.log('[Music] 封面过大（${data.length} 字节），跳过锁屏封面');
        _artworkCache[u] = null;
        return null;
      }
      final bytes = Uint8List.fromList(data);
      // 缓存只留最近 8 张（锁屏封面用不了那么多）
      if (_artworkCache.length >= 8) {
        _artworkCache.remove(_artworkCache.keys.first);
      }
      _artworkCache[u] = bytes;
      return bytes;
    } catch (e) {
      AppLog.instance.log('[Music] 锁屏封面下载失败: $e');
      _artworkCache[u] = null;
      return null;
    }
  }

  /// 调原生；**没有原生侧时静默忽略**（例如在单测 / 桌面跑）
  Future<void> _invoke(String method, [Object? args]) async {
    try {
      await _ch.invokeMethod(method, args);
    } on MissingPluginException {
      // 预期：单测环境没有原生侧
    } catch (e) {
      AppLog.instance.log('[Music] 锁屏控制 $method 失败: $e');
    }
  }

  // ────────────────────────────────────────────────────────────
  // 原生 → Dart（控制中心 / 锁屏 / 耳机按键）
  // ────────────────────────────────────────────────────────────

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method != 'remote') return;
    final m = call.arguments;
    final args = m is Map ? m : const {};
    final action = '${args['action']}';
    AppLog.instance.log('[Music] 收到系统媒体控制: $action');

    final p = MusicPlayerManager.instance;
    switch (action) {
      case 'play':
        await p.resume();
      case 'pause':
        await p.pause();
      case 'toggle':
        await p.toggle();
      case 'next':
        await p.next();
      case 'previous':
        await p.previous();
      case 'seek':
        final sec = args['position'];
        if (sec is num) {
          await p.seek(Duration(milliseconds: (sec * 1000).round()));
        }
      default:
        AppLog.instance.log('[Music] 未知的系统媒体控制: $action');
    }
    // 动作执行完立刻把新状态推回去（否则锁屏按钮图标会停在旧状态）
    await _push(forceArtwork: false);
  }

  // ────────────────────────────────────────────────────────────
  // 排查 / 能力查询
  // ────────────────────────────────────────────────────────────

  /// 问原生"系统现在认为我在放什么"——**真机排查用**（结果写日志）。
  Future<void> debugState() async {
    try {
      final r = await _ch.invokeMethod<Map<dynamic, dynamic>>('debugState');
      AppLog.instance.log('[Music] 锁屏控制状态: $r');
    } on MissingPluginException {
      AppLog.instance.log('[Music] 锁屏控制：无原生侧（预期于单测/桌面）');
    } catch (e) {
      AppLog.instance.log('[Music] 锁屏控制状态查询失败: $e');
    }
  }

  /// **灵动岛 / 实时活动**是否可用。
  ///
  /// ⚠️ 当前**恒为 false**：那需要 `ActivityKit` + 独立 Widget Extension
  /// target（改 Xcode 工程结构），本项目为 TrollStore 侧载、不新增 target，
  /// 所以没有实现。留这个方法是让 UI 能**如实**告知用户，
  /// 而不是给个点了没反应的开关。
  Future<bool> liveActivitiesSupported() async {
    try {
      return await _ch.invokeMethod<bool>('liveActivitiesSupported') ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
