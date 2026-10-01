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
        bitrate: asInt(j['br']),
        type: (j['type'] ?? '').toString(),
      );
}

/// 歌词结果
class MusicLyric {
  final String? lyric;
  final String? translation;

  /// 逐字歌词（YRC）。
  ///
  /// #9：接口**本来就返回这个字段**，但之前只取了 `lyric`/`tlyric`，
  /// 于是永远只能整行高亮。有 yrc 时优先用它（逐字高亮）。
  final String? yrc;

  const MusicLyric({this.lyric, this.translation, this.yrc});

  /// 有逐字数据
  bool get hasYrc => yrc != null && yrc!.trim().isNotEmpty;
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
    // 复用连接：首页要连发 5~6 个请求（推荐/新歌/榜单…），
    // 每次新建 TCP+TLS 握手会明显拖慢首屏
    persistentConnection: true,
  ));

  bool _loggedPortWarned = false;

  // ============================================================
  // 响应缓存 + 并发去重
  // ============================================================

  /// 缓存条目：数据 + 写入时间
  final Map<String, _CacheEntry> _cache = {};

  /// 进行中的同 key 请求（并发去重）
  ///
  /// ── 为什么必须要这个 ──────────────────────────────────────────
  /// 发现页会同时拉「推荐歌单 / 新歌速递 / 榜单」，而这些接口彼此独立；
  /// 但用户来回切换 Tab 时，**同一个请求会在上一发还没回来时再发一次**。
  /// 没有去重就会看到：网络请求数翻倍、后到的旧响应把新响应覆盖掉。
  /// 这里让同 key 的第二个调用直接复用第一个的 Future。
  final Map<String, Future<dynamic>> _inflight = {};

  /// 哪些 action 值得缓存、缓存多久。
  ///
  /// 判断依据是**数据变化速度**：
  ///   · 排行榜/歌单/专辑/歌手信息：分钟级甚至天级才变 → 缓存收益大
  ///   · 搜索/歌曲URL/评论：必须实时（尤其 URL 会过期）→ 绝不缓存
  static const Map<String, Duration> _cacheTtl = {
    'topLists': Duration(minutes: 10),
    'personalized': Duration(minutes: 5),
    'playlistCatlist': Duration(hours: 6),
    'playlistDetail': Duration(minutes: 5),
    'playlistSquare': Duration(minutes: 5),
    'hotSearch': Duration(minutes: 30),
    'newSongs': Duration(minutes: 10),
    'artistAlbums': Duration(minutes: 30),
    'albumSongs': Duration(minutes: 30),
    'artistSongs': Duration(minutes: 30),
    'searchArtists': Duration(minutes: 10),
    'searchAlbums': Duration(minutes: 10),
  };

  /// 缓存容量上限。
  /// 不设上限的话，长时间用下来会把所有歌单详情都留在内存里。
  static const int _cacheLimit = 60;

  String _cacheKey(Map<String, dynamic> body) {
    // body 很小（action + 几个 id/limit），排序后拼串即可稳定做 key
    final keys = body.keys.toList()..sort();
    return keys.map((k) => '$k=${body[k]}').join('&');
  }

  Future<dynamic> _call(Map<String, dynamic> body) async {
    final action = (body['action'] ?? '').toString();
    final ttl = _cacheTtl[action];
    final key = ttl == null ? null : _cacheKey(body);

    // 1) 命中缓存
    if (key != null) {
      final hit = _cache[key];
      if (hit != null && !hit.isExpired) return hit.data;
      if (hit != null) _cache.remove(key); // 过期就丢掉，别留着占内存
    }

    // 2) 并发去重：同一个请求已经在路上，直接等它
    if (key != null) {
      final running = _inflight[key];
      if (running != null) return running;
    }

    final future = _doCall(body, key, ttl);
    if (key != null) {
      _inflight[key] = future;
      // 无论成功失败都要清掉，否则失败的请求会永远"在途"
      future.whenComplete(() => _inflight.remove(key));
    }
    return future;
  }

  Future<dynamic> _doCall(
    Map<String, dynamic> body,
    String? cacheKey,
    Duration? ttl,
  ) async {
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
      final data = res.data;
      // 只缓存成功结果。失败的（网络抖动/接口临时挂）不缓存 ——
      // 否则用户点"重试"会拿到同一个失败结果，以为永远好不了。
      if (cacheKey != null && ttl != null && _isOk(data)) {
        _putCache(cacheKey, data, ttl);
      }
      return data;
    } catch (e) {
      return {'ok': false, 'error': '请求失败：${_short(e)}'};
    }
  }

  bool _isOk(dynamic data) {
    if (data is! Map) return false;
    return data['ok'] != false;
  }

  void _putCache(String key, dynamic data, Duration ttl) {
    _cache[key] = _CacheEntry(data, DateTime.now().add(ttl));
    // 超容量时丢掉最早过期的那批（简单 LRU 近似，够用且便宜）
    if (_cache.length > _cacheLimit) {
      final sorted = _cache.entries.toList()
        ..sort((a, b) => a.value.expireAt.compareTo(b.value.expireAt));
      for (var i = 0; i < sorted.length - _cacheLimit; i++) {
        _cache.remove(sorted[i].key);
      }
    }
  }

  /// 手动清缓存（下拉刷新时调用）
  void clearCache() => _cache.clear();


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
                id: asInt(e['id']),
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
                id: asInt(e['id']),
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
      // #9：逐字歌词字段（网易云叫 yrc，有的实现叫 klyric）
      yrc: (m['yrc'] ?? m['klyric'])?.toString(),
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
              id: asInt(e['id']),
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
            id: asInt(p['id']),
            name: (p['name'] ?? '').toString(),
            coverUrl: p['cover']?.toString(),
            trackCount: asInt(p['trackCount']),
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
              id: asInt(e['id']),
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

/// 缓存条目：数据 + 过期时刻
class _CacheEntry {
  _CacheEntry(this.data, this.expireAt);
  final dynamic data;
  final DateTime expireAt;
  bool get isExpired => DateTime.now().isAfter(expireAt);
}
