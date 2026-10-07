import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart' show IOHttpClientAdapter;
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

  /// 播放该地址**必须**带的请求头。
  ///
  /// 例如喜马拉雅：集自带 https 直链，但**没有 User-Agent 就被服务端拒**。
  /// 不把它透传给播放器，表现就是"地址拿到了但播不了 / 403"。
  final Map<String, String> headers;

  const MusicUrlInfo({
    required this.ok,
    this.url = '',
    this.reason = '',
    this.message = '',
    this.bitrate = 0,
    this.type = '',
    this.headers = const {},
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
        // Node 侧 `url` 动作可以回一个 headers（喜马拉雅就是靠它带 UA）
        headers: j['headers'] is Map
            ? (j['headers'] as Map)
                .map((k, v) => MapEntry(k.toString(), v.toString()))
            : const {},
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

  /// 'keyword'（模板法）| 'script'（LX 脚本）| 'musicfree'（MusicFree 插件）
  final String kind;
  final String message;

  /// 播放该地址**必须带的请求头**。
  ///
  /// 🔴 很多第三方源（尤其 MusicFree 插件）返回
  ///   `{ url, headers: { 'User-Agent': …, 'Referer': … } }`
  /// 而**不带这些头就拿不到流**（表现为"地址拿到了但播不了 / 403"）。
  ///
  /// 这个字段原来缺失 → Node 侧 `normalizeMedia` 解析出来的 headers
  /// 在这里被**丢掉**，插件要求 headers 的源等于白解析。
  final Map<String, String> headers;

  const MusicResolveResult({
    required this.ok,
    this.url = '',
    this.kind = '',
    this.message = '',
    this.headers = const {},
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

  /// 把一批歌曲 JSON 补上**真实来源平台**，再交给 [Song.fromJson]。
  ///
  /// ── 🔴 为什么必须有这个（修一个"播错歌"的真 bug）─────────────────
  ///
  /// `Song.source` 有两个**决定性的**作用（`models.dart` 里有详述）：
  ///   1. `identityKey` = `'${source.platform}-$id'`
  ///      —— 收藏 / 下载 / 队列 / 最近播放**都按它去重**
  ///   2. 播放时用它选平台：`songUrl(song.id, source: song.source)`
  ///
  /// 而 **Node 侧的 QQ 实现不回 `source`**：
  ///   · `qq_source.js` 的 `mapSong` 返回 `{id, name, artist, album, albumId,
  ///     cover, duration, fee, songmid, mediaMid, artistMid}` —— **没有 source**
  ///   · `music_source.js` 的 QQ 分支是 `return qq.searchSongs(...)` /
  ///     `qq.topListSongs(...)` / `qq.playlistSongs(...)` **直通**，不补字段
  ///  （酷狗的 `mapSong` **有** `source`，所以酷狗那条路本来就对）
  ///
  /// 于是没兜底的地方 `SongSource.fromKey(null)` → 落到 **netease** ✗
  ///
  /// **后果（真实可复现）**：QQ 榜单/歌单里的歌被标成网易云，
  /// 而 **QQ 和网易云的数字 id 区间高度重叠** →
  /// `songUrl(QQ的id, source: netease)` 会去网易云查这个 id，
  /// 命中就是**完全不同的一首歌** → **播错歌** ✗
  /// 第三方源也会按 `wy`（网易云）分派，同样是错的平台约定。
  ///
  /// ⚠️ 只有**确实缺 `source`** 时才注入：Node 回了真实来源就尊重它
  ///（例如酷狗、喜马拉雅、以及将来跨平台聚合的结果）。
  List<Song> _songsWithSource(dynamic r, SongSource source) => _listOf(r, 'list')
      .map((j) => Song.fromJson(
            j['source'] == null ? {...j, 'source': source.key} : j,
          ))
      .toList();


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

  Future<MusicListResult<Song>> search(
    String keyword, {
    int limit = 30,
    int offset = 0,
    SongSource source = SongSource.netease,
  }) async {
    if (keyword.trim().isEmpty) {
      return const MusicListResult(ok: false, message: '请输入关键词');
    }
    final r = await _call({
      'action': 'search',
      'keyword': keyword,
      'limit': limit,
      'offset': offset,
      // 多平台：Node 侧按 `source` 分派（不传时默认 netease，行为不变）
      'source': source.key,
    });
    final m = _asMap(r);
    if (m['ok'] != true) {
      return MusicListResult(ok: false, message: (m['error'] ?? '搜索失败').toString());
    }
    return MusicListResult(
      ok: true,
      // 结果必须带上**真实来源**：`Song.source` 决定后面用哪个平台解析播放地址
      // （`identityKey` 也靠它避免"网易云的 123"和"酷狗的 123"撞车）。
      // Node 侧若没回 `source` 就用本次请求的平台兜底。
      list: _songsWithSource(r, source),
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

  /// 热门搜索词。
  ///
  /// ⚠️ 这次是**语义补齐**：以前"请求失败"和"真的没有热词"**都返回空列表** ✗
  /// → `warmUpMusicData()` 于是**永远以为预热成功** → 首页那条
  /// 「音乐数据加载失败 · 点击重试」提示条是**死 UI** ✗
  ///（`_doCall` 把一切异常吞成 `{ok:false}`，不抛异常，所以 try/catch 永远 catch 不到 ✓）。
  /// 现在把 `ok` 单独带出来 ✓；`hotSearch()` 保持原样，既有调用方不受影响 ✓。
  Future<({bool ok, List<String> list, String error})> hotSearchResult({
    SongSource source = SongSource.netease,
  }) async {
    final r = await _call({'action': 'hotSearch', 'source': source.key});
    final m = _asMap(r);
    final ok = m['ok'] != false; // Node 侧失败会带 ok:false
    final list = parseHotKeywords(m['list']);
    return (
      ok: ok && list.isNotEmpty,
      list: list,
      error: ok ? '' : (m['error'] ?? '热门搜索获取失败').toString(),
    );
  }

  /// 热门搜索词
  Future<List<String>> hotSearch({SongSource source = SongSource.netease}) async {
    final r = await _call({'action': 'hotSearch', 'source': source.key});
    return parseHotKeywords(_asMap(r)['list']);
  }

  /// 把 Node 的 `hotSearch` 结果统一成**关键词字符串**列表。
  ///
  /// ── 🔴 为什么要专门一个函数（真实 bug）──────────────────────
  /// Node 侧 `hotSearch` **两条分支返回的形状不一样**：
  ///   · 网易云：`{ok:true, list:['周杰伦','林俊杰',…]}`      —— 字符串数组
  ///   · QQ    ：`{ok:true, list:[{id:'0',name:'我们的歌'},…]}` —— **对象数组**
  ///     （见 `qq_source.js` 的 `hotSearch`：`{ id: String(i), name: k }`）
  ///
  /// 这里原来是 `l.map((e) => e.toString())` —— 对字符串没问题，
  /// 但 `Map.toString()` 会产出
  ///     **`"{id: 0, name: 我们的歌}"`**
  /// 于是 QQ 音乐的热搜格子里直接显示了这串 Dart Map 字面量 ✗
  ///（用户实测截图就是这个）。
  ///
  /// 现在：字符串直接用；Map 则按 `name`/`k`/`key`/`keyword` 取值；
  /// 一个 key 都没命中就**丢弃**（不退回 `toString()`，那正是 bug 根源）。
  ///
  /// [raw] 是 Node 返回的 `list` 字段（`List`，元素可能是 String 或 Map）。
  static List<String> parseHotKeywords(dynamic raw) {
    if (raw is! List) return const [];
    const nameKeys = ['name', 'k', 'key', 'keyword', 'word', 'first'];
    final out = <String>[];
    for (final e in raw) {
      String v;
      if (e is String) {
        v = e;
      } else if (e is Map) {
        v = '';
        for (final k in nameKeys) {
          final got = e[k];
          if (got is String && got.trim().isNotEmpty) {
            v = got;
            break;
          }
        }
        // ⚠️ 一个 key 都没命中时**直接丢弃**，不要退回 toString()
        // —— 那正是会显示成 "{id: 0, name: …}" 的根源
        if (v.isEmpty) continue;
      } else {
        v = e?.toString() ?? '';
      }
      v = v.trim();
      if (v.isNotEmpty) out.add(v);
    }
    return out;
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

  // ============================================================
  // 喜马拉雅（有声书 / 播客）：专辑 → 单集
  // ============================================================
  //
  // ⚠️ 与网易云/酷狗不同：它**不是单曲平台**。
  //   · 搜索/分类返回的是**专辑**（`kind == 'album'`）→ 点进去进专辑页
  //   · 必须先调 `ximalayaAlbum()` 拿到单集列表，Node 侧才会**填充直链缓存**；
  //     直接播搜索到的专辑 id 是拿不到地址的（这是数据源的既定取舍）。

  /// 分类列表（有声书 / 儿童 / 相声 / 历史…）
  Future<List<({String id, String name})>> ximalayaCategories() async {
    final r = await _call({'action': 'ximalayaCategories', 'source': 'ximalaya'});
    final m = _asMap(r);
    final l = m['list'];
    if (l is! List) return const [];
    return l
        .whereType<Map>()
        .map((e) => (
              id: (e['id'] ?? '').toString(),
              name: (e['name'] ?? '').toString(),
            ))
        .where((e) => e.id.isNotEmpty)
        .toList();
  }

  /// 某分类下的专辑（分页）
  Future<MusicListResult<Song>> ximalayaCategory(
    String categoryId, {
    int page = 1,
  }) async {
    final r = await _call({
      'action': 'ximalayaCategory',
      'source': 'ximalaya',
      'categoryId': categoryId,
      'page': page,
    });
    final m = _asMap(r);
    if (m['ok'] != true) {
      return MusicListResult(
          ok: false, message: (m['error'] ?? '加载失败').toString());
    }
    return MusicListResult(
      ok: true,
      list: _listOf(r, 'list').map(_xmSong).toList(),
    );
  }

  /// 专辑详情 → 单集列表。
  ///
  /// 返回 `skipped`（没有直链、被数据源过滤掉的集数）与 `message`
  /// （整张专辑都不可播时的原因），让 UI 能如实告知而不是显示空列表。
  Future<
      ({
        bool ok,
        String message,
        List<Song> songs,
        int skipped,
        String albumName,
      })> ximalayaAlbum(String albumId) async {
    final r = await _call({
      'action': 'ximalayaAlbum',
      'source': 'ximalaya',
      'id': albumId,
    });
    final m = _asMap(r);
    if (m['ok'] != true) {
      return (
        ok: false,
        message: (m['error'] ?? '加载失败').toString(),
        songs: const <Song>[],
        skipped: 0,
        albumName: '',
      );
    }
    final album = m['album'] is Map
        ? (m['album'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    return (
      ok: true,
      message: (m['message'] ?? '').toString(),
      songs: _listOf(r, 'list').map(_xmSong).toList(),
      skipped: asInt(m['skipped']),
      albumName: (album['name'] ?? '').toString(),
    );
  }

  /// 喜马拉雅的专辑/单集统一走这里。
  ///
  /// ⚠️ 同时补 `artists`：Node 侧（沿用 `mapTrack` 的习惯）用的是单数 `artist`，
  /// 而 `Song.fromJson` 读的是 `artists` —— 不补的话**歌手/主播会显示为空**。
  static Song _xmSong(Map<String, dynamic> j) => Song.fromJson({
        ...j,
        'source': 'ximalaya',
        'artists': j['artists'] ?? j['artist'] ?? '',
      });

  // ============================================================
  // 博看听书（有声书）：纯 Dart 直连官方接口（不走 Node）
  // ============================================================
  //
  // 与喜马拉雅（Node 引擎）的实现路线不同：博看 5 个端点全是公开
  // https JSON 接口，Dart 直接用 Dio 打即可，**不需要动 Node 侧**。
  // 单集直链（`file` 字段）在 `bookanAlbum()` 时直接填进 `Song.directUrl`，
  // 播放器解析地址时优先使用（见 `player_manager` 的直链优先分支）。

  static const _bkApiHost = 'https://api.bookan.com.cn';
  static const _bkSearchHost = 'https://es.bookan.com.cn';
  static const _bkInstanceId = '25304';
  static const _bkUa =
      'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36';

  /// 固定分类（博看官方实例的 11 个分类，按首页 forceOrder 排序）
  static const bookanCategories = <({String id, String name})>[
    (id: '1319', name: '相声评书'),
    (id: '1320', name: '国学经典'),
    (id: '1303', name: '故事会'),
    (id: '1312', name: '历史小说'),
    (id: '1317', name: '音乐戏剧'),
    (id: '1307', name: '青春励志'),
    (id: '1305', name: '少年读物'),
    (id: '1304', name: '儿童文学'),
    (id: '1306', name: '文艺少年'),
    (id: '1309', name: '育儿心经'),
    (id: '1310', name: '心理哲学'),
  ];

  static Dio? _bkDio;
  static Dio get _bookanDio => _bkDio ??= Dio(BaseOptions(
        headers: {'User-Agent': _bkUa, 'Accept': 'application/json, text/plain, */*'},
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 20),
      ));

  /// 博看 GET JSON（容错：非 200 / 解析失败一律返回 null）
  Future<Map<String, dynamic>?> _bookanGet(String url) async {
    try {
      final r = await _bookanDio.get<dynamic>(url);
      if (r.statusCode != 200) return null;
      final d = r.data;
      return d is Map ? d.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  static String _bkUrl(String host, String path, Map<String, String> params) {
    final q = params.entries
        .map((e) => '${Uri.encodeQueryComponent(e.key)}='
            '${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return '$host$path${q.isEmpty ? '' : '?$q'}';
  }

  /// 分类下的专辑列表（分页）。
  ///
  /// 返回的是**专辑卡片**（Song：id=albumId、name=专辑名、coverUrl=封面、
  /// artists=作者），点击进 [BookanAlbumPage] 再拿单集。
  Future<MusicListResult<Song>> bookanCategory(
    String categoryId, {
    int page = 1,
    int limit = 24,
  }) async {
    final url = _bkUrl(_bkApiHost, '/voice/book/list', {
      'instance_id': _bkInstanceId,
      'page': '$page',
      'category_id': categoryId,
      'num': '$limit',
    });
    final d = await _bookanGet(url);
    final list = d?['data'] is Map ? (d!['data'] as Map)['list'] : null;
    if (list is! List) {
      return const MusicListResult(ok: false, message: '博看分类接口无数据');
    }
    final songs = <Song>[];
    for (final e in list) {
      if (e is! Map) continue;
      final m = e.cast<String, dynamic>();
      final id = (m['id'] ?? '').toString().trim();
      if (id.isEmpty) continue;
      final baseId = int.tryParse(id) ?? id.hashCode;
      songs.add(Song(
        id: baseId,
        name: (m['name'] ?? m['title'] ?? '').toString(),
        artists: (m['author'] ?? '').toString(),
        album: (m['name'] ?? m['title'] ?? '').toString(),
        coverUrl: (m['cover'] ?? '').toString().isNotEmpty
            ? (m['cover'] ?? '').toString()
            : null,
        source: SongSource.bookan,
      ));
    }
    return MusicListResult(ok: true, list: songs);
  }

  /// 专辑详情 → 单集列表（含音频直链）。
  ///
  /// 单集 `file` 字段即直链，直接填进 `Song.directUrl`（带 UA）。
  /// id 用 `albumId*100000 + 序号` 保证跨专辑不撞（identityKey 唯一）。
  Future<
      ({
        bool ok,
        String message,
        String albumName,
        String? coverUrl,
        String? author,
        List<Song> songs,
      })> bookanAlbum(String albumId) async {
    final albumBase = int.tryParse(albumId) ?? albumId.hashCode;

    // 专辑详情（标题/封面/作者/简介）
    var albumName = '';
    String? coverUrl;
    String? author;
    final infoUrl = _bkUrl(_bkApiHost, '/voice/album/get', {'album_id': albumId});
    final info = await _bookanGet(infoUrl);
    if (info?['data'] is Map) {
      final a = (info!['data'] as Map).cast<String, dynamic>();
      albumName = (a['title'] ?? a['name'] ?? '').toString();
      coverUrl = (a['cover'] ?? '').toString();
      author = (a['author'] ?? '').toString();
    }

    // 单集列表（每页 200，自动翻页聚合）
    final songs = <Song>[];
    var page = 1;
    var total = 0;
    while (page <= 20) {
      final unitsUrl = _bkUrl(_bkApiHost, '/voice/album/units', {
        'album_id': albumId,
        'page': '$page',
        'num': '200',
        'order': '1',
      });
      final d = await _bookanGet(unitsUrl);
      final data = d?['data'];
      final list = data is Map ? data['list'] : null;
      if (list is! List || list.isEmpty) break;
      final batch = list.cast<dynamic>();
      for (var i = 0; i < batch.length; i++) {
        final e = batch[i];
        if (e is! Map) continue;
        final m = e.cast<String, dynamic>();
        final file = (m['file'] ?? '').toString().trim();
        if (file.isEmpty) continue;
        final title = (m['title'] ?? '').toString().trim();
        // 单集自带的专辑名/封面兜底（album/get 时常返回空）
        if (albumName.isEmpty) {
          albumName = (m['album_title'] ?? '').toString().trim();
        }
        if (coverUrl == null || coverUrl!.isEmpty) {
          final c = (m['cover'] ?? '').toString().trim();
          if (c.isNotEmpty) coverUrl = c;
        }
        songs.add(Song(
          id: albumBase * 100000 + page * 200 + i + 1,
          name: title.isEmpty ? '第${songs.length + 1}集' : title,
          artists: author ?? '',
          album: albumName,
          coverUrl: coverUrl,
          source: SongSource.bookan,
          directUrl: file,
          directHeaders: const {'User-Agent': _bkUa},
        ));
      }
      final rawTotal = data is Map ? data['total'] : null;
      total = int.tryParse('$rawTotal') ?? 0;
      if (list.length < 200) break;
      page++;
    }
    if (songs.isEmpty) {
      return (
        ok: false,
        message: '这张专辑没有可播放的单集',
        albumName: albumName,
        coverUrl: coverUrl,
        author: author,
        songs: const <Song>[],
      );
    }
    return (
      ok: true,
      message: '',
      albumName: albumName,
      coverUrl: coverUrl,
      author: author,
      songs: songs,
    );
  }

  /// 博看关键词搜索（返回专辑列表）
  Future<MusicListResult<Song>> bookanSearch(
    String keyword, {
    int page = 1,
    int limit = 20,
  }) async {
    final url = _bkUrl(_bkSearchHost, '/api/v3/voice/book', {
      'instanceId': _bkInstanceId,
      'keyword': keyword,
      'pageNum': '$page',
      'limitNum': '$limit',
    });
    final d = await _bookanGet(url);
    final data = d?['data'];
    final list = data is Map ? data['list'] : null;
    if (list is! List) {
      return const MusicListResult(ok: false, message: '博看搜索无结果');
    }
    final songs = <Song>[];
    for (final e in list) {
      if (e is! Map) continue;
      final m = e.cast<String, dynamic>();
      final id = (m['id'] ?? '').toString().trim();
      if (id.isEmpty) continue;
      songs.add(Song(
        id: int.tryParse(id) ?? id.hashCode,
        name: (m['name'] ?? m['title'] ?? '').toString(),
        artists: (m['author'] ?? '').toString(),
        album: (m['name'] ?? m['title'] ?? '').toString(),
        coverUrl: (m['cover'] ?? '').toString().isNotEmpty
            ? (m['cover'] ?? '').toString()
            : null,
        source: SongSource.bookan,
      ));
    }
    return MusicListResult(ok: true, list: songs);
  }

  /// 首页推荐：按分类顺序遍历，取各分类第一页合并（上限 30 条）。
  ///
  /// 与喜马拉雅的"取第一个分类"不同：博看首页希望看到多个类别的头部内容，
  /// 所以遍历所有分类、各取第一页，凑成"热门推荐"。
  Future<List<Song>> bookanHome({int perCategory = 12, int max = 30}) async {
    final out = <Song>[];
    for (final c in bookanCategories) {
      if (out.length >= max) break;
      final r = await bookanCategory(c.id, page: 1, limit: perCategory);
      if (!r.ok) continue;
      for (final s in r.list) {
        out.add(s);
        if (out.length >= max) break;
      }
    }
    return out;
  }

  // ============================================================
  // 275听书（i275.com）：HTML 站 + PHP 会话 + lrts 懒人听书解析
  // ============================================================
  //
  // 与博看不同：275 是**页面站点**，需要：
  //   1. **PHPSESSID 会话** —— 首次访问首页拿 Set-Cookie，后续请求带 Cookie
  //   2. **HTML 正则解析** —— 首页/搜索/分类/详情/播放页全是页面
  //   3. **lrts token 解析** —— 播放页 `audio.url` 可能是 `lrts$…`，
  //      需调 m.lrts.me 的 getPlayPath/getListenPath 换真实音频直链
  // ⚠️ 275 的 TLS 证书链含自签名证书（本机实测 verify 失败）→ 专用
  //    Dio **跳过证书校验**（只对这一个源生效，其余请求不受影响）。

  static const _b275Site = 'https://www.i275.com';
  static const _b275Host = 'www.i275.com';
  static const _b275DefaultCover = '$_b275Site/uploads/bookcover.png';
  static const _b275Ua =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  /// 275 固定分类（latest=最近上架，其余按站内搜索词映射）
  static const book275Categories = <({String id, String name})>[
    (id: 'latest', name: '最近上架'),
    (id: 'xuanhuan', name: '玄幻'),
    (id: 'xiuxian', name: '修仙'),
    (id: 'dushi', name: '都市'),
    (id: 'yanqing', name: '言情'),
    (id: 'chuanyue', name: '穿越'),
    (id: 'chongsheng', name: '重生'),
    (id: 'xuanyi', name: '悬疑'),
    (id: 'lingyi', name: '灵异'),
    (id: 'lishi', name: '历史'),
    (id: 'wuxia', name: '武侠'),
    (id: 'kehuan', name: '科幻'),
    (id: 'wangyou', name: '网游'),
    (id: 'guanchang', name: '官场'),
    (id: 'junshi', name: '军事'),
    (id: 'pingshu', name: '评书'),
    (id: 'ertong', name: '儿童'),
    (id: 'xiangsheng', name: '相声'),
    (id: 'guangboju', name: '广播剧'),
    (id: 'qita', name: '其他'),
  ];

  static const _b275CatQuery = <String, String>{
    'xuanhuan': '玄幻', 'xiuxian': '修仙', 'dushi': '都市',
    'yanqing': '言情', 'chuanyue': '穿越', 'chongsheng': '重生',
    'xuanyi': '悬疑', 'lingyi': '灵异', 'lishi': '历史',
    'wuxia': '武侠', 'kehuan': '科幻', 'wangyou': '网游',
    'guanchang': '官场', 'junshi': '军事', 'pingshu': '评书',
    'ertong': '儿童', 'xiangsheng': '相声', 'guangboju': '广播剧',
    'qita': '其他',
  };

  /// PHPSESSID 等会话 cookie（只存 275 域名的）
  static final Map<String, String> _b275CookieJar = {};

  static Dio? _b275Dio;
  static Dio get _book275Dio => _b275Dio ??= _build275Dio();

  static Dio _build275Dio() {
    final d = Dio(BaseOptions(
      headers: {
        'User-Agent': _b275Ua,
        'Accept':
            'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        'Referer': '$_b275Site/',
      },
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 25),
    ));
    // 275 证书链含自签名 → 跳过校验（仅此源；其余请求仍走默认信任链）
    final adapter = d.httpClientAdapter;
    if (adapter is IOHttpClientAdapter) {
      adapter.createHttpClient = () {
        final client = HttpClient(context: SecurityContext(withTrustedRoots: false));
        client.badCertificateCallback = (cert, host, port) => true;
        return client;
      };
    }
    return d;
  }

  static String _b275Abs(String value, [String base = '$_b275Site/']) {
    final text = (value ?? '').toString().trim();
    if (text.isEmpty) return '';
    try {
      return Uri.parse(text).resolve(base).toString();
    } catch (_) {
      return text;
    }
  }

  static String _b275Clean(String value) {
    final s = (value ?? '').toString()
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), '');
    return s
        .replaceAllMapped(RegExp(r'&#x([0-9a-f]+);', caseSensitive: false),
            (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)))
        .replaceAllMapped(RegExp(r'&#(\d+);'),
            (m) => String.fromCharCode(int.parse(m.group(1)!)))
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll(RegExp(r'[ \t\r\f\v]+'), ' ')
        .trim();
  }

  /// GET 275 页面文本（带 cookie 记忆 + 403/429 重试一次）
  Future<String> _b275Get(String path, {Map<String, String>? extraHeaders}) async {
    final url = _b275Abs(path);
    final cookie = _b275CurrentCookie(url);
    var lastStatus = 0;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final r = await _book275Dio.get<String>(
          url,
          options: Options(
            headers: {
              ...?extraHeaders,
              if (cookie.isNotEmpty) 'Cookie': cookie,
            },
            responseType: ResponseType.plain,
          ),
        );
        lastStatus = r.statusCode ?? 0;
        _b275RememberCookies(r.headers, url);
        if ((lastStatus == 403 || lastStatus == 429) && attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 1100));
          continue;
        }
        if (lastStatus != 200) return '';
        return r.data ?? '';
      } catch (_) {
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 1100));
          continue;
        }
        return '';
      }
    }
    return '';
  }

  static void _b275RememberCookies(Headers headers, String url) {
    try {
      if (Uri.parse(url).host != _b275Host) return;
    } catch (_) {
      return;
    }
    final raw = headers['set-cookie'];
    if (raw == null) return;
    for (final item in raw) {
      for (final part in item.split(RegExp(r',(?=\s*[^;,=\s]+=[^;]*)'))) {
        final first = part.split(';').first.trim();
        final idx = first.indexOf('=');
        if (idx <= 0) continue;
        _b275CookieJar[first.substring(0, idx).trim()] =
            first.substring(idx + 1).trim();
      }
    }
  }

  static String _b275CurrentCookie(String url) {
    try {
      if (Uri.parse(url).host != _b275Host) return '';
    } catch (_) {
      return '';
    }
    return _b275CookieJar.entries
        .map((e) => '${e.key}=${e.value}')
        .join('; ');
  }

  /// 首页/搜索/分类共用的卡片解析：`<a href="/book/(id).html">…<img src>…`
  List<Song> _b275ParseBooks(String html) {
    final out = <Song>[];
    final seen = <String>{};
    // 对齐 JS 版正则：<a href="/book/{id}.html" ...>...</a>
    final re = RegExp(
        r'''<a\s+href=["']/book/(\d+)\.html["'][^>]*>([\s\S]*?)</a>''',
        caseSensitive: false);
    for (final m in re.allMatches(html ?? '')) {
      final id = m.group(1)!;
      final block = m.group(2) ?? '';
      if (seen.contains(id)) continue;
      // 封面图：<img src="...">
      final img = RegExp(r'''<img[^>]+src=["']([^"']+)["']''', caseSensitive: false)
          .firstMatch(block);
      // 标题：优先 <h3>，回退 "font-medium text-sm" 类名，再回退 img alt
      final titleM = RegExp(r'<h3[^>]*>([\s\S]*?)</h3>', caseSensitive: false)
              .firstMatch(block) ??
          RegExp(
                  r'''<div[^>]+class=["'][^"']*font-medium[^"']*["'][^>]*>([\s\S]*?)</div>''',
                  caseSensitive: false)
              .firstMatch(block);
      final altM = RegExp(r'''<img[^>]+alt=["']([^"']+)["']''', caseSensitive: false)
          .firstMatch(block);
      final title = _b275Clean(titleM?.group(1) ?? altM?.group(1) ?? '');
      if (title.isEmpty) continue;
      // 演播者：优先 ">演播</span> xxx"，回退 "text-xs text-gray-500" 类名
      final speakerM = RegExp(r'>演播<\/span>\s*([^<\r\n]+)', caseSensitive: false)
              .firstMatch(block) ??
          RegExp(
                  r'''<div[^>]+class=["'][^"']*text-xs[^"']*["'][^>]*>([\s\S]*?)</div>''',
                  caseSensitive: false)
              .firstMatch(block);
      seen.add(id);
      // 封面：有图用图，没图用默认占位（JS 版 parseBooks 会跳过无图的，
      // 但 275 列表页有些书只有文字没图，全跳过就啥也不剩了）。
      // 这里改为：有图用真实图，无图用站点默认封面兜底。
      final cover = img != null
          ? _b275CoverOrNull(img.group(1)!)
          : null;
      out.add(Song(
        id: int.tryParse(id) ?? id.hashCode,
        name: title,
        artists: _b275Clean(speakerM?.group(1) ?? ''),
        album: title,
        coverUrl: cover ?? _b275DefaultCover,
        source: SongSource.book275,
      ));
    }
    return out;
  }

  String? _b275CoverOrNull(String src) {
    final u = _b275Abs(src);
    if (u.contains('bookcover.png')) return null;
    return u;
  }

  /// 275 首页（最近上架 + 分类）
  Future<List<Song>> book275Home() async {
    final html = await _b275Get('/');
    return _b275ParseBooks(html);
  }

  /// 275 分类（latest=首页，其余走站内搜索词）
  Future<MusicListResult<Song>> book275Category(
    String categoryId, {
    int page = 1,
  }) async {
    final html = categoryId == 'latest'
        ? await _b275Get('/')
        : await _b275Get('$_b275Site/search.php?q=${Uri.encodeQueryComponent(_b275CatQuery[categoryId] ?? categoryId)}');
    final list = _b275ParseBooks(html);
    return MusicListResult(ok: true, list: list);
  }

  /// 275 搜索
  Future<MusicListResult<Song>> book275Search(String keyword) async {
    if (keyword.trim().isEmpty) {
      return const MusicListResult(ok: true, list: []);
    }
    final html =
        await _b275Get('$_b275Site/search.php?q=${Uri.encodeQueryComponent(keyword)}');
    return MusicListResult(ok: true, list: _b275ParseBooks(html));
  }

  /// 275 专辑详情 → 单集列表（directUrl = 播放页 URL）。
  Future<
      ({
        bool ok,
        String message,
        String albumName,
        String? coverUrl,
        String? author,
        String? speaker,
        List<Song> songs,
      })> book275Album(String bookId) async {
    final html = await _b275Get('/book/$bookId.html');
    if (html.isEmpty) {
      return (ok: false, message: '275 详情页无数据', albumName: '',
          coverUrl: null as String?, author: null as String?,
          speaker: null as String?, songs: const <Song>[]);
    }
    // 标题：<h1 class="text-2xl font-bold text-gray-800">
    // （Tailwind 类名顺序可能变，用"包含关键字"匹配）
    final titleM = RegExp(
            r'''<h1[^>]+class=["'][^"']*text-2xl[^"']*["'][^>]*>([\s\S]*?)</h1>''',
            caseSensitive: false)
        .firstMatch(html);
    final albumName = _b275Clean(titleM?.group(1) ?? '');

    String field(String label) {
      final esc = RegExp.escape(label);
      final m = RegExp(
              '<p>\\s*$esc：\\s*<span[^>]*>([\\s\\S]*?)</span>',
              caseSensitive: false)
          .firstMatch(html);
      return _b275Clean(m?.group(1) ?? '');
    }

    final author = field('作者');
    final speaker = field('演播');
    final cover = _b275ExtractCover(html);

    final songs = <Song>[];
    // 章节列表：<a href="/play/{bookId}/{chapterId}.html">...<span class="text-sm text-gray-700 truncate">章节名</span>
    // 对齐 JS 版的 chapterPattern。注意 [\s\S]*? 是非贪婪，
    // 必须确保 href 和 span 在同一个 <a> 标签内部匹配。
    final chapterRe = RegExp(
        r'''href=["']/play/(\d+)/(\d+)\.html["'][\s\S]*?<span[^>]+class=["'][^"']*truncate[^"']*["'][^>]*>([\s\S]*?)</span>''',
        caseSensitive: false);
    var i = 0;
    for (final m in chapterRe.allMatches(html)) {
      final playUrl = '$_b275Site/play/${m.group(1)}/${m.group(2)}.html';
      final name = _b275Clean(m.group(3) ?? '')
          .replaceAll('\$', '￥')
          .replaceAll('#', '﹟');
      if (name.isEmpty) continue;
      i++;
      songs.add(Song(
        id: (int.tryParse(bookId) ?? bookId.hashCode) * 100000 + i,
        name: name,
        artists: speaker.isNotEmpty ? speaker : (author ?? ''),
        album: albumName,
        coverUrl: cover ?? _b275DefaultCover,
        source: SongSource.book275,
        directUrl: playUrl,
      ));
    }
    if (songs.isEmpty) {
      return (ok: false, message: '这本书没有解析到章节', albumName: albumName,
          coverUrl: cover, author: author as String?, speaker: speaker as String?,
          songs: const <Song>[]);
    }
    return (ok: true, message: '', albumName: albumName, coverUrl: cover,
        author: author as String?, speaker: speaker as String?, songs: songs);
  }

  static String? _b275ExtractCover(String html) {
    final m = RegExp(
            r'''<div class=["']w-32 h-44[\s\S]*?<img[^>]+src=["']([^"']+)''', caseSensitive: false)
            .firstMatch(html) ??
        RegExp(r'''<img[^>]+src=["']([^"']*/uploads/[^"']+)["']''', caseSensitive: false)
            .firstMatch(html);
    if (m == null) return null;
    final u = _b275Abs(m.group(1)!);
    return u.contains('bookcover.png') ? null : u;
  }

  static String _b275BookReferer(String playUrl) {
    final m = RegExp(r'/play/(\d+)/').firstMatch(playUrl);
    return m == null ? '$_b275Site/' : '$_b275Site/book/${m.group(1)}.html';
  }

  /// 解析 lrts 懒人听书 token → 真实音频直链
  Future<String> _b275ResolveLrts(String token) async {
    final parts = token.split('#');
    final entityM = RegExp(r'^lrts\$(\d+)$').firstMatch(parts.first);
    if (entityM == null || parts.length < 3) return '';
    final entityId = entityM.group(1)!;
    final id = parts[1];
    final section = parts[2];
    if (!RegExp(r'^\d+$').hasMatch(id) || !RegExp(r'^\d+$').hasMatch(section)) {
      return '';
    }
    for (final endpoint in ['getPlayPath', 'getListenPath']) {
      final query = 'entityId=$entityId&entityType=3&opType=1&sections=[$section]&type=0&id=$id&section=$section';
      try {
        final r = await _book275Dio.get<String>(
          'https://m.lrts.me/ajax/$endpoint?$query',
          options: Options(
            headers: {'Referer': 'https://m.lrts.me/', 'User-Agent': _b275Ua},
            responseType: ResponseType.plain,
          ),
        );
        final payload = r.data ?? '';
        final status = RegExp(r'"status"\s*:\s*(\d+)').firstMatch(payload);
        final path = endpoint == 'getPlayPath'
            ? RegExp(r'"path"\s*:\s*"([^"]+)"').firstMatch(payload)?.group(1)
            : RegExp(r'"data"\s*:\s*\{[\s\S]*?"path"\s*:\s*"([^"]+)"').firstMatch(payload)?.group(1);
        if (status != null && status.group(1) == '0' && path != null &&
            RegExp(r'^https?://').hasMatch(path)) {
          return path;
        }
      } catch (_) {
        continue;
      }
    }
    return '';
  }

  /// 解析 275 播放页 → 真实音频直链（含会话初始化 + lrts token）
  Future<MusicUrlInfo> book275Resolve(String playUrl) async {
    // 会话未初始化时先访问首页拿 PHPSESSID
    if (_b275CookieJar['PHPSESSID'] == null) {
      await _b275Get('/');
      await Future<void>.delayed(const Duration(milliseconds: 1050));
    }
    final html = await _b275Get(playUrl,
        extraHeaders: {'Referer': _b275BookReferer(playUrl)});
    if (html.isEmpty) {
      return const MusicUrlInfo(ok: false, message: '275 播放页加载失败');
    }

    // 按优先级尝试多种音频 URL 提取模式（对齐 JS 版 + 额外兜底）：
    //   1. audio: [{ url: "..." }] （标准 JS 版模式）
    //   2. "url":"..." 附近有 .mp3/.m4a/.aac 后缀
    //   3. <audio src="..."> 标签
    //   4. 任何 "https://...mp3" / "https://...m4a" 直链
    String? audioUrl;

    // 模式 1：audio: [{ ... url: "..." }]（JS 原版模式）
    final m1 = RegExp(
            r'''audio\s*:\s*\[\s*\{[\s\S]*?url\s*:\s*["']([^"']+)["']''',
            caseSensitive: false)
        .firstMatch(html);
    if (m1 != null) audioUrl = m1.group(1);

    // 模式 2：找 url 字段值里带音频后缀的
    if (audioUrl == null || audioUrl!.isEmpty) {
      final m2 = RegExp(
              r'''url\s*:\s*["']([^"']+\.(?:mp3|m4a|aac|wav|ogg|flac)[^"']*)["']''',
              caseSensitive: false)
          .firstMatch(html);
      if (m2 != null) audioUrl = m2.group(1);
    }

    // 模式 3：<audio src="...">
    if (audioUrl == null || audioUrl!.isEmpty) {
      final m3 = RegExp(
              r'''<audio[^>]+src=["']([^"']+)["']''',
              caseSensitive: false)
          .firstMatch(html);
      if (m3 != null) audioUrl = m3.group(1);
    }

    // 模式 4：兜底抓 https 音频直链
    if (audioUrl == null || audioUrl!.isEmpty) {
      final m4 = RegExp(
              r'''(https?://[^"'\s<>]+\.(?:mp3|m4a|aac)(?:\?[^"'\s<>]*)?)''',
              caseSensitive: false)
          .firstMatch(html);
      if (m4 != null) audioUrl = m4.group(1);
    }

    if (audioUrl == null || audioUrl!.isEmpty) {
      return const MusicUrlInfo(ok: false, message: '播放页没有找到音频地址');
    }

    // HTML 实体解码 + JS 转义的斜杠还原
    var url = audioUrl!
        .replaceAll(r'\/', '/')
        .replaceAll('&amp;', '&')
        .replaceAll('&#39;', "'")
        .replaceAll('&quot;', '"')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');
    url = _b275Clean(url);

    var referer = playUrl;
    // lrts 懒人听书 token 解析
    if (url.startsWith('lrts\$')) {
      final real = await _b275ResolveLrts(url);
      if (real.isEmpty) {
        return const MusicUrlInfo(ok: false, message: '懒人听书音频解析失败');
      }
      url = real;
      referer = 'https://m.lrts.me/';
    }
    // http → https 升级
    if (url.startsWith('http://')) {
      url = 'https://${url.substring(7)}';
    }
    if (!RegExp(r'^https?://').hasMatch(url)) {
      return MusicUrlInfo(
          ok: false, message: '解析出的地址不是有效链接: $url');
    }
    return MusicUrlInfo(
      ok: true,
      url: url,
      type: '275听书',
      headers: {'User-Agent': _b275Ua, 'Referer': referer},
    );
  }

  Future<MusicUrlInfo> songUrl(
    int id, {
    AudioQuality? quality,
    SongSource source = SongSource.netease,
  }) async {
    final q = quality ?? AudioQuality.exhigh;
    final r = await _call({
      'action': 'url',
      'id': id,
      'quality': q.level,
      // ⚠️ 必须带上**这首歌自己的**平台：用酷狗的 id 去查网易云是查不到的
      //（`player_manager` 传的就是 `song.source.key`）。
      'source': source.key,
    });
    return MusicUrlInfo.fromJson(_asMap(r));
  }

  Future<MusicLyric?> lyric(
    int id, {
    SongSource source = SongSource.netease,
  }) async {
    final r = await _call({'action': 'lyric', 'id': id, 'source': source.key});
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
        // ── 🔴 必须带 `source`（这是修的一个真 bug）────────────────
        //
        // Node 侧 `source_resolver.js` 用
        //   `providerCodeOf(song && song.source)`
        // 推导 LX 平台码（wy/tx/kg/kw/mg），**脚本靠它分派**：
        //   · 星海音乐源：`if (!MUSIC_QUALITIES[source]) throw`
        //   · 很多脚本：`payload.source === 'tx' ? QQ接口 : 网易接口`
        //
        // 而这里原来**没有这个字段** → `providerCodeOf(undefined)` 走
        // `return s || 'wy'` → **永远返回 'wy'**。
        //
        // 后果：**QQ / 酷狗 / 喜马拉雅的歌走第三方源时，脚本以为自己在处理
        // 网易云的歌**，于是拿"QQ 的 id"去查"网易云的接口" —— 必然查不到。
        // 只有网易云的歌（本来就该是 wy）刚好不受影响，所以问题被掩盖了。
        'source': song.source.key,
        // ── 🔴 必须带 `songmid`（这是修的一个真 bug）────────────────
        //
        // 很多平台的**真实标识是字符串**，数字 id 换不到地址：
        //   · QQ：`songmid` 形如 `0039MnYb0qxYhV`
        //   · 酷狗：`hash`
        //
        // 实测（元力音源 v1.2.1 的 `getMediaSource`）：
        //     `GET …/qq_kw.php?id=${musicItem.songmid}&type=json&level=…`
        // 插件读的是 **`songmid`**。我们原来只给数字 id →
        // 那个换源后端查不到 → 返回空 → **"QQ 的歌播不了"** ✗
        // 补上之后同一后端正常返回真实音频地址 ✓
        'songmid': song.songmid,
      },
    });
    final m = _asMap(r);
    return MusicResolveResult(
      ok: m['ok'] == true && (m['url'] ?? '').toString().isNotEmpty,
      url: (m['url'] ?? '').toString(),
      kind: (m['kind'] ?? '').toString(),
      message: (m['error'] ?? '').toString(),
      // ⚠️ **必须带上 headers**：MusicFree 插件（以及部分 LX 源）会返回
      // `{ url, headers }`，不给播放器带上就播不了（403 / 空流）。
      // Node 侧 `normalizeMedia` 已经归一化过，这里只做类型收口。
      headers: m['headers'] is Map
          ? (m['headers'] as Map)
              .map((k, v) => MapEntry(k.toString(), v.toString()))
          : const {},
    );
  }

  /// LX 引擎自检：验证沙箱与超时真的生效（音源管理页可调）
  Future<Map<String, dynamic>> lxSelfTest() async {
    final r = await _call({'action': 'lxSelfTest'});
    return _asMap(r);
  }

  // ============================================================
  // MusicFree 插件的 search / getLyric
  // ============================================================

  /// 用 **MusicFree 插件**搜索。
  ///
  /// ⚠️ 只对 `kind: 'musicfree'` 的源有效 —— LX 脚本没有 `search()` 概念
  ///（它的能力面是 `musicUrl`/`lyric`/`pic`）。传别的 kind，Node 侧会
  /// 返回**明确的错误**而不是空列表（否则上层会以为"没搜到"）。
  ///
  /// [type]：MusicFree 的 `'music' | 'album' | 'sheet' | 'artist'`，
  /// 默认 `'music'`。
  Future<MusicListResult<Song>> searchByMusicFree(
    ThirdPartySource source,
    String keyword, {
    int page = 1,
    String type = 'music',
  }) async {
    if (keyword.trim().isEmpty) {
      return const MusicListResult(ok: false, message: '请输入关键词');
    }
    final r = await _call({
      'action': 'searchByMusicFree',
      'source': source.toJson(),
      'keyword': keyword,
      'page': page,
      'type': type,
    });
    final m = _asMap(r);
    if (m['ok'] != true) {
      return MusicListResult(ok: false, message: (m['error'] ?? '').toString());
    }
    // Node 侧 `normalizeSearchResult` 已经把 MusicFree 的字段名
    // （title/artist/artwork）映射成本 App 的（name/artists/cover），
    // 所以这里可以直接走 Song.fromJson。
    return MusicListResult<Song>(
      ok: true,
      list: _listOf(r, 'list').map(Song.fromJson).toList(),
    );
  }

  /// 用 **MusicFree 插件**取歌词。
  ///
  /// 返回 null 表示"拿不到"（插件不支持 / 该曲无歌词 / 服务端限流）——
  /// 调用方应静默降级（没有歌词不算错误）。
  Future<MusicLyric?> lyricByMusicFree(
    ThirdPartySource source,
    Song song,
  ) async {
    final r = await _call({
      'action': 'lyricByMusicFree',
      'source': source.toJson(),
      'song': {
        'id': song.id,
        'name': song.name,
        'artists': song.artists,
        'album': song.album,
        'duration': song.duration,
      },
    });
    final m = _asMap(r);
    if (m['ok'] != true) return null;
    final lyric = (m['lyric'] ?? '').toString();
    if (lyric.trim().isEmpty) return null;
    return MusicLyric(lyric: lyric, translation: (m['tlyric'] ?? '').toString());
  }

  // ============================================================
  // 发现页
  // ============================================================

  /// 榜单列表（带 `ok`）。
  ///
  /// ⚠️ 原版 `topLists()` **失败与"真的没有榜单"都返回 `[]`** ✗ →
  /// `library_page` 的 `if (_tops.isNotEmpty)` 在 Node 后台未就绪时会让
  /// 「榜单」**整块静默消失** ✗（无提示、无重试）→ 用户以为这个模块没有榜单 ✓。
  /// 这个变体把成败带出来；原方法保留不动，既有调用方零影响 ✓。
  Future<({bool ok, List<TopList> list, String error})> topListsResult(
      {SongSource source = SongSource.netease}) async {
    final r = await _call({'action': 'topLists', 'source': source.key});
    final m = _asMap(r);
    final list = _listOf(r, 'list')
        .map((e) => TopList(
              id: asInt(e['id']),
              name: (e['name'] ?? '').toString(),
              coverUrl: e['cover']?.toString(),
              updateFrequency: e['updateFrequency']?.toString(),
            ))
        .toList();
    return (
      // 成功但确实没内容，对界面来说同样是"没得显示" → 计为失败以便触发重试 ✓
      ok: m['ok'] != false && list.isNotEmpty,
      list: list,
      error: (m['error'] ?? '榜单获取失败').toString(),
    );
  }

  /// 榜单列表
  Future<List<TopList>> topLists({SongSource source = SongSource.netease}) async {
    final r = await _call({'action': 'topLists', 'source': source.key});
    return _listOf(r, 'list')
        .map((e) => TopList(
              id: asInt(e['id']),
              name: (e['name'] ?? '').toString(),
              coverUrl: e['cover']?.toString(),
              updateFrequency: e['updateFrequency']?.toString(),
            ))
        .toList();
  }

  /// **热门歌手（带真头像）** —— 只有 QQ 支持（其它平台没这个接口）。
  ///
  /// ── 为什么是"从榜单派生"而不是歌手列表接口 ────────────────────
  /// QQ 免登录**没有**歌手列表接口（实测 `GetSingerList` 返回
  /// `code=500003`、`fcg_v8_singer_track_cp` 404）；
  /// 但**歌手头像模板是通的**，而歌曲里带着 `singerMid` ——
  /// 所以 Node 侧从榜单歌曲里收集去重歌手并拼出头像 URL。
  ///
  /// ⚠️ 头像 URL 是 **150x150**（不是 300）—— 界面只显示 64 的圆圈，
  ///    用 150 省流量。
  ///
  /// [topId] 用来决定"从哪个榜取歌手"（不传用热歌榜 26）。
  Future<List<({String name, String avatar, String mid})>> topArtists({
    int topId = 26,
    int limit = 14,
    SongSource source = SongSource.qq,
  }) async {
    final r = await _call({
      'action': 'topArtists',
      'id': topId,
      'limit': limit,
      'source': source.key,
    });
    final m = _asMap(r);
    if (m['ok'] != true) return const [];
    return _listOf(r, 'list')
        .map((e) => (
              name: (e['name'] ?? '').toString(),
              avatar: (e['avatar'] ?? '').toString(),
              mid: (e['mid'] ?? '').toString(),
            ))
        .where((a) => a.name.isNotEmpty && a.avatar.isNotEmpty)
        .toList();
  }

  /// **榜单里的歌曲**（QQ 需要走 `topListSongs`，网易云/酷狗用 `playlistDetail`）。
  ///
  /// ── 🔴 为什么必须区分（QQ 特有）──────────────────────────────
  /// QQ 的"榜单 id"（topId，如 62）**不是歌单 id**：
  ///   · 拿它去查 `playlistDetail`（歌单接口）→ 查不到（列表为空）
  ///   · 必须走 `musicToplist.ToplistInfoServer/GetDetail`
  /// 网易云/酷狗的榜单 id 恰好也能当歌单 id 用，所以只有 QQ 需要这条分支。
  ///
  /// [ok] 带出来是为了区分"接口失败"和"榜单确实没歌"（同 [topListsResult] 的理由）。
  Future<({bool ok, List<Song> list, String error})> topListSongs(
    int id, {
    int limit = 100,
    SongSource source = SongSource.qq,
  }) async {
    final r = await _call({
      'action': 'topListSongs',
      'id': id,
      'limit': limit,
      'source': source.key,
    });
    final m = _asMap(r);
    final list = _songsWithSource(r, source);
    return (
      ok: m['ok'] != false && list.isNotEmpty,
      list: list,
      error: (m['error'] ?? '榜单歌曲获取失败').toString(),
    );
  }

  /// 推荐歌单（首页"推荐歌单"）
  Future<List<Playlist>> personalized({int limit = 20, SongSource source = SongSource.netease}) async {
    final r = await _call({'action': 'personalized', 'limit': limit, 'source': source.key});
    return _listOf(r, 'list').map(Playlist.fromJson).toList();
  }

  /// 歌单广场
  Future<List<Playlist>> playlistSquare({
    String cat = '全部',
    String order = 'hot',
    int limit = 12,
    SongSource source = SongSource.netease,
  }) async {
    final r = await _call({
      'action': 'playlistSquare', 'cat': cat, 'order': order, 'limit': limit, 'source': source.key,
    });
    return _listOf(r, 'list').map(Playlist.fromJson).toList();
  }

  /// 歌单分类名
  Future<List<String>> playlistCatlist({SongSource source = SongSource.netease}) async {
    final r = await _call({'action': 'playlistCatlist', 'source': source.key});
    return _listOf(r, 'list')
        .map((e) => (e['name'] ?? '').toString())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  /// 新歌速递
  Future<List<Song>> newSongs({int limit = 10, SongSource source = SongSource.netease}) async {
    final r = await _call({'action': 'newSongs', 'limit': limit, 'source': source.key});
    return _songsWithSource(r, source);
  }

  /// 歌单详情（含歌曲）；返回 (歌单元信息, 歌曲列表)
  Future<(Playlist?, List<Song>)> playlistDetail(int id, {SongSource source = SongSource.netease}) async {
    final r = await _call({'action': 'playlistDetail', 'id': id, 'source': source.key});
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
    return (pl, _songsWithSource(r, source));
  }

  /// 相似歌曲
  Future<List<Song>> simiSongs(int id) async {
    final r = await _call({'action': 'simiSongs', 'id': id});
    // ⚠️ 这个 action 没带 `source` 参数 → Node 侧走网易云默认分支，
    //    所以兜底也用 netease（见 `_songsWithSource` 的说明）
    return _songsWithSource(r, SongSource.netease);
  }

  /// 歌曲评论（带 `ok`）。
  ///
  /// ⚠️ 原版 `comments()` **完全不看 `ok`** ✗ → 接口失败时返回空列表 ✗ →
  /// `comment_sheet` 一路走到「**还没有评论**」✗ ——
  /// 把"**请求失败**"显示成了"没有评论" ✓；而且翻页失败会把已加载的
  /// 整页评论**替换成错误页** ✗。
  /// 这个变体把成败带出来；原方法保留不动，既有调用方零影响 ✓。
  Future<({bool ok, List<SongComment> list, String error})> commentsResult(
      int id,
      {int limit = 30, int offset = 0}) async {
    final r = await _call(
        {'action': 'comments', 'id': id, 'limit': limit, 'offset': offset});
    final m = _asMap(r);
    final list = _listOf(r, 'list').map(SongComment.fromJson).toList();
    return (
      // ⚠️ **空列表不算失败** —— 这首歌真的可能没有评论 ✓
      // 只有 Node 明确回 ok:false 才是失败 ✓（这正是原版分不清的那件事）
      ok: m['ok'] != false,
      list: list,
      error: (m['error'] ?? '评论获取失败').toString(),
    );
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
    // ⚠️ 同上：没带 `source` → 网易云默认分支
    return _songsWithSource(r, SongSource.netease);
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
    // ⚠️ 同上：没带 `source` → 网易云默认分支
    return _songsWithSource(r, SongSource.netease);
  }
}

/// 缓存条目：数据 + 过期时刻
class _CacheEntry {
  _CacheEntry(this.data, this.expireAt);
  final dynamic data;
  final DateTime expireAt;
  bool get isExpired => DateTime.now().isAfter(expireAt);
}
