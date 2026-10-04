import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';
import 'music_api.dart';
import 'settings_store.dart';
import '../../services/app_log.dart';

/// 下载状态
enum MusicDownloadStatus { queued, downloading, done, failed }

/// 一条下载记录（同时是"本地音乐"的条目）
class MusicDownload {
  MusicDownload({required this.song, required this.path});

  final Song song;
  String path;
  MusicDownloadStatus status = MusicDownloadStatus.queued;

  /// 0~1；**-1 表示总长未知**（服务端没给 Content-Length）
  double progress = 0;
  int bytes = 0;
  String error = '';

  /// 用 `identityKey`（`source-key`）做唯一键，避免跨平台 id 撞车
  String get id => song.identityKey;

  Map<String, dynamic> toJson() => {
        'song': song.toJson(),
        'path': path,
        'bytes': bytes,
      };

  static MusicDownload? fromJson(Map<String, dynamic> j) {
    final s = j['song'];
    if (s is! Map) return null;
    try {
      final d = MusicDownload(
        song: Song.fromJson(s.cast<String, dynamic>()),
        path: (j['path'] ?? '').toString(),
      );
      d.bytes = (j['bytes'] as num?)?.toInt() ?? 0;
      // 清单里只存"已完成"的，加载后即为 done
      d.status = MusicDownloadStatus.done;
      d.progress = 1;
      return d;
    } catch (_) {
      return null;
    }
  }
}

/// 音乐下载（App 沙盒内的「本地音乐」）。
///
/// ── 设计取舍 ──────────────────────────────────────────────────
/// · **放在 App 沙盒**（`Documents/music/`），不暴露到系统「文件」App ——
///   那需要改 `Info.plist`（`UIFileSharingEnabled`/`LSSupportsOpeningDocumentsInPlace`），
///   属于产品决定，先不做。以后要暴露只需加那两个键。
/// · **串行下载**（同一时刻只跑一个）而不并发：移动端并发下载更容易被限速/失败，
///   而且串行的进度语义对用户最直观。
/// · **按 `identityKey` 去重**：同一个文件不重复下。
/// · **必须把 `MusicUrlInfo.headers` 带上下载**：喜马拉雅的直链没有 UA 会被拒。
class MusicDownloadService extends ChangeNotifier {
  MusicDownloadService._();
  static final MusicDownloadService instance = MusicDownloadService._();

  static const _kManifest = 'music.downloads.v1';

  final List<MusicDownload> _items = [];
  List<MusicDownload> get items => List.unmodifiable(_items);

  /// 已下载完成、可以用来播的歌（「本地音乐」页用）
  List<Song> get localSongs => _items
      .where((d) => d.status == MusicDownloadStatus.done)
      .map((d) => d.song)
      .toList();

  /// 磁盘占用（字节）
  int get totalBytes => _items
      .where((d) => d.status == MusicDownloadStatus.done)
      .fold(0, (a, d) => a + d.bytes);

  SharedPreferences? _prefs;
  bool _busy = false;

  /// 正在进行的初始化。
  ///
  /// 🔴 用**缓存 Future** 而不是 `bool _inited` 闩锁：闩锁会"先置位再 await"，
  /// 于是紧接着调用的 `init()` **立刻返回**，此刻 `_prefs` 仍是 `null` →
  /// `_save()` 里 `if (p == null) return;` 会把**清单写入静默丢掉** ✗
  /// 后果：下载完的记录重启就没了、已下载的歌被当成"没下载"。
  Future<void>? _initFuture;

  Future<void> init() => _initFuture ??= _doInit();

  Future<void> _doInit() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      final raw = _prefs!.getString(_kManifest);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final e in decoded) {
            if (e is! Map) continue;
            final d = MusicDownload.fromJson(e.cast<String, dynamic>());
            if (d == null) continue;
            // 文件被清理掉（重装/系统清理）就从清单里剔除，避免"点了播不了"
            if (d.path.isEmpty || !File(d.path).existsSync()) continue;
            _items.add(d);
          }
        }
      }
    } catch (_) {
      /* 读不出来就当空 */
    }
    notifyListeners();
  }

  MusicDownload? bySong(Song song) {
    for (final d in _items) {
      if (d.id == song.identityKey) return d;
    }
    return null;
  }

  bool isDownloaded(Song song) {
    final d = bySong(song);
    return d != null && d.status == MusicDownloadStatus.done;
  }

  /// 入队。已在清单里（完成/下载中/排队）就忽略；失败的可重来。
  Future<void> enqueue(Song song) async {
    await init();
    final exist = bySong(song);
    if (exist != null) {
      if (exist.status == MusicDownloadStatus.failed) {
        exist.status = MusicDownloadStatus.queued;
        exist.error = '';
        notifyListeners();
        unawaited(_pump());
      }
      return;
    }
    _items.add(MusicDownload(song: song, path: ''));
    notifyListeners();
    unawaited(_pump());
  }

  /// 串行泵：一次只跑一个 queued
  Future<void> _pump() async {
    if (_busy) return;
    _busy = true;
    try {
      while (true) {
        MusicDownload? next;
        for (final d in _items) {
          if (d.status == MusicDownloadStatus.queued) {
            next = d;
            break;
          }
        }
        if (next == null) break;
        await _run(next);
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _run(MusicDownload d) async {
    d.status = MusicDownloadStatus.downloading;
    d.progress = 0;
    d.error = '';
    notifyListeners();
    try {
      final q = SettingsStore.instance.audioQuality.value;
      // 地址 + headers 都要（喜马拉雅的直链必须带 UA）
      final info = await MusicApi.instance
          .songUrl(d.song.id, quality: q, source: d.song.source);
      if (!info.playable) {
        d.status = MusicDownloadStatus.failed;
        d.error = info.message.isEmpty ? '拿不到播放地址' : info.message;
        notifyListeners();
        return;
      }

      final dir = await _dir();
      final file = File(
        '${dir.path}/${d.song.source.key}-${d.song.id}${_ext(info.url, info.type)}',
      );
      // 同名残留先删掉，避免追加写入出一个坏文件
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {}
      }
      d.path = file.path;

      // ⚠️ **必须带超时**：`Dio()` 默认没有 connect/receive 超时 →
      // 遇到"只回 headers 不给 body"的源，这次 await **永不返回**，
      // 而 `_pump()` 的串行循环就卡在这里 → **整个下载队列永久停摆** ✗
      //（用户之后点多少首都不会开始下载，也没有取消入口）。
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 60), // 大文件给足
      ));
      await dio.download(
        info.url,
        file.path,
        options: Options(
          headers: info.headers.isEmpty ? null : info.headers,
        ),
        onReceiveProgress: (got, total) {
          d.bytes = got;
          d.progress = total > 0 ? got / total : -1;
          notifyListeners();
        },
      );

      if (!file.existsSync() || file.lengthSync() <= 0) {
        d.status = MusicDownloadStatus.failed;
        d.error = '下载结果为空文件';
        notifyListeners();
        return;
      }
      d.bytes = file.lengthSync();
      d.status = MusicDownloadStatus.done;
      d.progress = 1;
      await _save();
    } catch (e) {
      d.status = MusicDownloadStatus.failed;
      d.error = _short(e);
      // ⚠️ 失败要**删掉半截文件**：否则它留在 `Documents/music/` 里，
      // 而 `_save()` 只序列化 `done` 条目 → 重启后清单里没有它
      // → **用户永远删不掉这个文件**（`remove/clearAll` 只能删清单里有的）✗
      try {
        if (d.path.isNotEmpty) {
          final f = File(d.path);
          if (f.existsSync()) f.deleteSync();
        }
      } catch (_) {}
      d.path = '';
      d.bytes = 0;
      // 下载失败以前**既不写日志也不提示**（模块里唯一没有日志的失败分支）✗
      AppLog.instance.log('[Music] 下载失败 ${d.song.name}: $e');
    }
    notifyListeners();
  }

  /// 删除一条（连同文件）
  Future<void> remove(Song song) async {
    await init();
    final d = bySong(song);
    if (d == null) return;
    if (d.path.isNotEmpty) {
      try {
        final f = File(d.path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    _items.remove(d);
    await _save();
    notifyListeners();
  }

  /// 清空全部下载（连同文件）
  Future<void> clearAll() async {
    await init();
    for (final d in List.of(_items)) {
      if (d.path.isEmpty) continue;
      try {
        final f = File(d.path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    _items.clear();
    await _save();
    notifyListeners();
  }

  Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/music');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// 扩展名：优先用接口给的 type，其次从 URL 猜，最后 mp3
  static String _ext(String url, String type) {
    const known = {'mp3', 'flac', 'm4a', 'aac', 'wav', 'ogg'};
    final t = type.toLowerCase().trim();
    if (known.contains(t)) return '.$t';
    final path = Uri.tryParse(url)?.path ?? url;
    final dot = path.lastIndexOf('.');
    if (dot > 0 && dot < path.length - 1) {
      final e = path.substring(dot + 1).toLowerCase();
      if (known.contains(e)) return '.$e';
    }
    return '.mp3';
  }

  static String _short(Object e) {
    if (e is DioException) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return '下载超时';
      }
      final code = e.response?.statusCode;
      if (code != null) return '下载失败（HTTP $code）';
      return e.message ?? '下载失败';
    }
    return '下载失败：$e';
  }

  Future<void> _save() async {
    final p = _prefs;
    if (p == null) return;
    try {
      final done = _items
          .where((d) => d.status == MusicDownloadStatus.done)
          .map((d) => d.toJson())
          .toList();
      await p.setString(_kManifest, jsonEncode(done));
    } catch (_) {
      /* 存不下不该影响已下载的文件 */
    }
  }
}
