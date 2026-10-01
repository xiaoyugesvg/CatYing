import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../services/nodejs_manager.dart';
import '../models/models.dart';
import '../models/third_party_source.dart';

/// 播放地址解析结果
class MusicUrlInfo {
  final bool ok;
  final String url;

  /// 业务性失败原因（'no_free_source' = 该曲无免费音源，属正常）
  final String reason;
  final String message;

  /// 码率（bps）
  final int bitrate;

  /// 容器格式（mp3 / flac …）
  final String type;

  const MusicUrlInfo({
    required this.ok,
    this.url = '',
    this.reason = '',
    this.message = '',
    this.bitrate = 0,
    this.type = '',
  });

  bool get playable => ok && url.isNotEmpty;
  bool get noFreeSource => reason == 'no_free_source';

  /// 给用户看的音质说明
  String get qualityText {
    // Dart 的 String 没有 isUpperCase（那是 characters 包的扩展），直接转大写即可
    if (bitrate <= 0) return type.toUpperCase();
    final kbps = (bitrate / 1000).round();
    final label = switch (kbps) {
      >= 1000 => '无损',
      >= 320 => '320K',
      >= 192 => '192K',
      _ => '${kbps}K',
    };
    return '$label ${type.toUpperCase()}'.trim();
  }

  factory MusicUrlInfo.fromJson(Map<String, dynamic> j) => MusicUrlInfo(
        ok: j['ok'] == true,
        url: (j['url'] ?? '').toString(),
        reason: (j['reason'] ?? '').toString(),
        message: (j['error'] ?? j['message'] ?? '').toString(),
        bitrate: (j['br'] as num?)?.toInt() ?? 0,
        type: (j['type'] ?? '').toString(),
      );
}

/// 歌词结果
class MusicLyric {
  final String? lyric;
  final String? translation;

  const MusicLyric({this.lyric, this.translation});
}

/// 第三方音源解析结果
class MusicResolveResult {
  final bool ok;
  final String url;

  /// 'keyword' | 'script'
  final String kind;
  final String message;

  const MusicResolveResult({
    required this.ok,
    this.url = '',
    this.kind = '',
    this.message = '',
  });
}

/// 分页列表结果
class MusicListResult<T> {
  final bool ok;
  final List<T> list;
  final String message;
  const MusicListResult({required this.ok, this.list = const [], this.message = ''});
}

/// 音乐接口客户端 —— 对应 Beans 的 `NetEaseAPI.swift`（**只保留公开接口**）。
///
/// 所有请求都走 Node 的 `/music/api`（见 `assets/nodejs-project/src/music_source.js`）。
/// 放在 Node 侧的原因：网易云要求特定 UA + Referer，集中管理更可靠；
/// 与项目既有做法（影视源、书源都走 Node）一致。
///
/// ⚠️ 刻意不做：登录、扫码、weapi/eapi 加密、Cookie 持久化。
/// 需要登录态的接口（用户歌单/收藏/红心/FM）**不在这里**。
class MusicApi {
  MusicApi._();
  static final MusicApi instance = MusicApi._();

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 20),
  ));

  bool _loggedPortWarned = false;

  Future<dynamic> _call(Map<String, dynamic> body) async {
    final port = NodeJSManager.instance.managementPort;
    if (port <= 0) {
      if (!_loggedPortWarned) {
        _loggedPortWarned = true;
        debugPrint('[MusicApi] Node 管理端口未就绪');
      }
      return {'ok': false, 'error': '后台服务未就绪，请稍后重试'};
    }
    try {
      final res = await _dio.post(
        'http://127.0.0.1:$port/music/api',
        data: body,
        options: Options(contentType: Headers.jsonContentType),
      );
      return res.data;
    } catch (e) {
      return {'ok': false, 'error': '请求失败：${_short(e)}'};
    }
  }

  String _short(Object e) {
    if (e is DioException) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return '网络超时';
      }
      return e.message ?? e.toString();
    }
    return e.toString();
  }

  Map<String, dynamic> _asMap(dynamic raw) =>
      raw is Map ? raw.cast<String, dynamic>() : <String, dynamic>{};

  List<Map<String, dynamic>> _listOf(dynamic raw, String key) {
    final m = _asMap(raw);
    final l = m[key];
    if (l is! List) return const [];
    return l.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  // ============================================================
  // 搜索
  // ============================================================

  Future<MusicListResult<Song>> search(String keyword, {int limit = 30, int offset = 0}) async {
    if (keyword.trim().isEmpty) {
      return const MusicListResult(ok: false, message: '请输入关键词');
    }
    final r = await _call({'action': 'search', 'keyword': keyword, 'limit': limit, 'offset': offset});
    final m = _asMap(r);
    if (m['ok'] != true) {
      return MusicListResult(ok: false, message: (m['error'] ?? '搜索失败').toString());
    }
    return MusicListResult(
      ok: true,
      list: _listOf(r, 'list').map(Song.fromJson).toList(),
    );
  }

  Future<MusicListResult<Artist>> searchArtists(String keyword, {int limit = 30}) async {
    final r = await _call({'action': 'searchArtists', 'keyword': keyword, 'limit': limit});
    final m = _asMap(r);
    if (m['ok'] != true) return MusicListResult(ok: false, message: (m['error'] ?? '').toString());
    return MusicListResult(
      ok: true,
      list: _listOf(r, 'list')
          .map((e) => Artist(
                id: (e['id'] as num?)?.toInt() ?? 0,
                name: (e['name'] ?? '').toString(),
                avatarUrl: e['avatarUrl']?.toString(),
              ))
          .toList(),
    );
  }

  Future<MusicListResult<Album>> searchAlbums(String keyword, {int limit = 30}) async {
    final r = await _call({'action': 'searchAlbums', 'keyword': keyword, 'limit': limit});
    final m = _asMap(r);
    if (m['ok'] != true) return MusicListResult(ok: false, message: (m['error'] ?? '').toString());
    return MusicListResult(
      ok: true,
      list: _listOf(r, 'list')
          .map((e) => Album(
                id: (e['id'] as num?)?.toInt() ?? 0,
                name: (e['name'] ?? '').toString(),
                coverUrl: (e['cover'] ?? e['picUrl'])?.toString(),
                artist: e['artist']?.toString(),
              ))
          .toList(),
    );
  }

  /// 热门搜索词
  Future<List<String>> hotSearch() async {
    final r = await _call({'action': 'hotSearch'});
    final m = _asMap(r);
    final l = m['list'];
    if (l is! List) return const [];
    return l.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
  }

  /// 搜索建议（Beans 的搜索页有这项，用热门词兜底）
  Future<List<String>> searchSuggest(String keyword) async {
    final r = await MusicListResult(ok: true, list: await hotSearch());
    if (keyword.trim().isEmpty) return r.list;
    return r.list.where((e) => e.contains(keyword)).toList();
  }

  // ============================================================
  // 播放地址 / 歌词
  // ============================================================

  Future<MusicUrlInfo> songUrl(int id, {AudioQuality? quality}) async {
    final q = quality ?? AudioQuality.exhigh;
    final r = await _call({'action': 'url', 'id': id, 'quality': q.level});
    return MusicUrlInfo.fromJson(_asMap(r));
  }

  Future<MusicLyric?> lyric(int id) async {
    final r = await _call({'action': 'lyric', 'id': id});
    final m = _asMap(r);
    if (m['ok'] != true) return null;
    return MusicLyric(
      lyric: m['lyric']?.toString(),
      translation: m['tlyric']?.toString(),
    );
  }

// ============================================================
  // 第三方音源
  // ============================================================

  /// 用一个第三方音源解析播放地址。
  ///
  /// 解析逻辑在 Node 侧（模板法 / 脚本法，见 `source_resolver.js`）：
  ///   · 模板法：把歌名/歌手/ID 填进模板 URL，请求后按 `urlPath` 取值
  ///   · 脚本法：在沙箱里跑用户的 LX 脚本（8s 超时，不给 fs/process）
  ///
  /// 音源列表的事实来源是 Dart 的 [ThirdPartySourceStore]，
  /// 所以这里把源**整体**传过去，Node 不囤一份。
  Future<MusicResolveResult> resolveBySource(
    ThirdPartySource source,
    Song song,
  ) async {
    final r = await _call({
      'action': 'resolveBySource',
      'source': source.toJson(),
      'song': {
        'id': song.id,
        'name': song.name,
        'artists': song.artists,
        'album': song.album,
      },
    });
    final m = _asMap(r);
    return MusicResolveResult(
      ok: m['ok'] == true && (m['url'] ?? '').toString().isNotEmpty,
      url: (m['url'] ?? '').toString(),
      kind: (m['kind'] ?? '').toString(),
      message: (m['error'] ?? '').toString(),
    );
  }

  /// LX 引擎自检：验证沙箱与超时真的生效（音源管理页可调）
  Future<Map<String, dynamic>> lxSelfTest() async {
    final r = await _call({'action': 'lxSelfTest'});
    return _asMap(r);
  }

  // ============================================================
  // 发现页
  // ============================================================

  /// 榜单列表
  Future<List<TopList>> topLists() async {
    final r = await _call({'action': 'topLists'});
    return _listOf(r, 'list')
        .map((e) => TopList(
              id: (e['id'] as num?)?.toInt() ?? 0,
              name: (e['name'] ?? '').toString(),
              coverUrl: e['cover']?.toString(),
              updateFrequency: e['updateFrequency']?.toString(),
            ))
        .toList();
  }

  /// 推荐歌单（首页"推荐歌单"）
  Future<List<Playlist>> personalized({int limit = 20}) async {
    final r = await _call({'action': 'personalized', 'limit': limit});
    return _listOf(r, 'list').map(Playlist.fromJson).toList();
  }

  /// 歌单广场
  Future<List<Playlist>> playlistSquare({
    String cat = '全部',
    String order = 'hot',
    int limit = 12,
  }) async {
    final r = await _call({
      'action': 'playlistSquare', 'cat': cat, 'order': order, 'limit': limit,
    });
    return _listOf(r, 'list').map(Playlist.fromJson).toList();
  }

  /// 歌单分类名
  Future<List<String>> playlistCatlist() async {
    final r = await _call({'action': 'playlistCatlist'});
    return _listOf(r, 'list')
        .map((e) => (e['name'] ?? '').toString())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// 新歌速递
  Future<List<Song>> newSongs({int limit = 10}) async {
    final r = await _call({'action': 'newSongs', 'limit': limit});
    return _listOf(r, 'list').map(Song.fromJson).toList();
  }

  /// 歌单详情（含歌曲）；返回 (歌单元信息, 歌曲列表)
  Future<(Playlist?, List<Song>)> playlistDetail(int id) async {
    final r = await _call({'action': 'playlistDetail', 'id': id});
    final m = _asMap(r);
    if (m['ok'] != true) return (null, const <Song>[]);
    final p = m['playlist'];
    final pl = p is Map
        ? Playlist(
            id: (p['id'] as num?)?.toInt() ?? id,
            name: (p['name'] ?? '').toString(),
            coverUrl: p['cover']?.toString(),
            trackCount: (p['trackCount'] as num?)?.toInt() ?? 0,
            description: p['description']?.toString(),
            creator: p['creator']?.toString(),
          )
        : null;
    return (pl, _listOf(r, 'list').map(Song.fromJson).toList());
  }

  /// 相似歌曲
  Future<List<Song>> simiSongs(int id) async {
    final r = await _call({'action': 'simiSongs', 'id': id});
    return _listOf(r, 'list').map(Song.fromJson).toList();
  }

  /// 歌曲评论
  Future<List<SongComment>> comments(int id, {int limit = 30, int offset = 0}) async {
    final r = await _call({'action': 'comments', 'id': id, 'limit': limit, 'offset': offset});
    return _listOf(r, 'list').map(SongComment.fromJson).toList();
  }

  // ============================================================
  // 歌手 / 专辑
  // ============================================================

  Future<List<Song>> artistSongs(int artistId, {int limit = 120}) async {
    final r = await _call({'action': 'artistSongs', 'id': artistId, 'limit': limit});
    return _listOf(r, 'list').map(Song.fromJson).toList();
  }

  Future<List<Album>> artistAlbums(int artistId, {int limit = 50}) async {
    final r = await _call({'action': 'artistAlbums', 'id': artistId, 'limit': limit});
    return _listOf(r, 'list')
        .map((e) => Album(
              id: (e['id'] as num?)?.toInt() ?? 0,
              name: (e['name'] ?? '').toString(),
              coverUrl: e['cover']?.toString(),
              artist: e['artist']?.toString(),
            ))
        .toList();
  }

  Future<List<Song>> albumSongs(int albumId) async {
    final r = await _call({'action': 'albumSongs', 'id': albumId});
    return _listOf(r, 'list').map(Song.fromJson).toList();
  }
}
