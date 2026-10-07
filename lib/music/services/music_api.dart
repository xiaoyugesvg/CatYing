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
  // 一五听书（ting15.com）：HTML 站 + 播放 API 直链
  // ============================================================
  //
  // 对齐 JS 源（@name Ting15有声 / 一五听书）：
  //   1. 分类 = 站内 URL 路径（/wuxiaxuanhuan/ … 共 10 类）
  //   2. 分类/搜索/详情全是 HTML 页面：列表 `<li> > div.img a` 卡片解析
  //   3. 播放：章节页 `/bookId/0-page.html` → POST `/?s=api-getneoplay`
  //      （bookId & isPay=0 & page）→ JSON `{url: mp3 直链}`
  //   4. API 失败 → 返回失败（不回落嗅探：音乐播放器无嗅探能力）

  static const _t15Site = 'https://www.ting15.com';
  static const _t15Ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// 一五固定分类（站内 URL 路径，与 JS 源一致）
  static const ting15Categories = <({String id, String name})>[
    (id: '/wuxiaxuanhuan/', name: '武侠玄幻'),
    (id: '/kongbulingyi/', name: '恐怖灵异'),
    (id: '/tuilixuanyi/', name: '推理悬疑'),
    (id: '/dushiyanqing/', name: '都市言情'),
    (id: '/jiatinglunli/', name: '家庭伦理'),
    (id: '/wenxuemingzhu/', name: '官场职场'),
    (id: '/jingdianpingshu/', name: '经典评书'),
    (id: '/quyixiqu/', name: '曲艺戏曲'),
    (id: '/xiangshengxiaopin/', name: '相声小品'),
    (id: '/yinyue/', name: '助眠音频'),
  ];

  static Dio? _t15Dio;
  static Dio get _ting15Dio => _t15Dio ??= Dio(BaseOptions(
        headers: {'User-Agent': _t15Ua, 'Referer': _t15Site},
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 25),
      ));

  static String _t15Abs(String value) {
    final u = (value ?? '').toString().trim();
    if (u.isEmpty) return '';
    try {
      return RegExp(r'^https?://', caseSensitive: false).hasMatch(u)
          ? u
          : Uri.parse('$_t15Site$u').toString();
    } catch (_) {
      return u;
    }
  }

  static String _t15Clean(String value) {
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

  /// GET 一五页面文本（失败重试一次）
  Future<String> _t15Get(String url) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final r = await _ting15Dio.get<String>(url,
            options: Options(responseType: ResponseType.plain));
        if (r.statusCode == 200) return r.data ?? '';
      } catch (_) {
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 800));
          continue;
        }
      }
    }
    return '';
  }

  /// 列表卡片解析（分类/搜索/首页共用）：`<li> > div.img a` + img + 最后 p。
  /// 对齐 JS 源：`vod_id = 详情页 URL`、`vod_remarks = 最后一段 p`。
  List<Song> _t15ParseBooks(String html) {
    final out = <Song>[];
    final seen = <String>{};
    final reLi = RegExp(r'<li[\s\S]*?</li>', caseSensitive: false);
    for (final li in reLi.allMatches(html ?? '')) {
      final block = li.group(0)!;
      final aM = RegExp(
              r'''<a[^>]+href=["']([^"']+)["'][^>]*>([\s\S]*?)</a>''',
              caseSensitive: false)
          .firstMatch(block);
      if (aM == null) continue;
      final href = _t15Abs(aM.group(1)!);
      if (href.isEmpty ||
          href == _t15Site ||
          href == '$_t15Site/' ||
          href.contains('/?s=')) continue;
      if (seen.contains(href)) continue;
      // 标题：a 的 title 属性，回退 li 内 h4 > a 文本
      final titleAttr = RegExp(r'''<a[^>]+title=["']([^"']+)["']''',
              caseSensitive: false)
          .firstMatch(block);
      final h4M = RegExp(r'''<h4[^>]*>\s*<a[^>]*>([\s\S]*?)</a>''',
              caseSensitive: false)
          .firstMatch(block);
      final title = _t15Clean(titleAttr?.group(1) ?? h4M?.group(1) ?? '');
      if (title.isEmpty) continue;
      // 封面：li 内 img src（// 开头补 https:）
      final imgM = RegExp(r'''<img[^>]+src=["']([^"']+)["']''',
              caseSensitive: false)
          .firstMatch(block);
      var cover = _t15Clean(imgM?.group(1) ?? '');
      if (cover.startsWith('//')) cover = 'https:$cover';
      // 备注：li 内最后一个 p
      final pList = RegExp(r'<p[^>]*>([\s\S]*?)</p>', caseSensitive: false)
          .allMatches(block)
          .toList();
      final remark = pList.isEmpty ? '' : _t15Clean(pList.last.group(1)!);
      seen.add(href);
      out.add(Song(
        id: href.hashCode,
        name: title,
        artists: remark,
        album: title,
        coverUrl: cover.isEmpty ? null : cover,
        source: SongSource.ting15,
        // 列表歌 directUrl = 详情页 URL（打开专辑用）
        directUrl: href,
      ));
    }
    return out;
  }

  /// 一五首页（最近上架 = 首页列表）
  Future<List<Song>> ting15Home() async {
    final html = await _t15Get('$_t15Site/');
    return _t15ParseBooks(html);
  }

  /// 一五分类内容（第 1 页 BASE+分类路径，第 2 页起 +indexN.html）
  Future<MusicListResult<Song>> ting15Category(
    String categoryId, {
    int page = 1,
  }) async {
    final url = page == 1
        ? '$_t15Site$categoryId'
        : '$_t15Site$categoryId/index$page.html';
    final html = await _t15Get(url);
    return MusicListResult(ok: true, list: _t15ParseBooks(html));
  }

  /// 一五搜索
  Future<MusicListResult<Song>> ting15Search(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return const MusicListResult(ok: true, list: []);
    final url = '$_t15Site/?s=ting-search-wd-${Uri.encodeComponent(kw)}';
    final html = await _t15Get(url);
    return MusicListResult(ok: true, list: _t15ParseBooks(html));
  }

  /// 一五专辑详情 → 单集列表（directUrl = 章节页 URL，播放用）。
  Future<
      ({
        bool ok,
        String message,
        String albumName,
        String? coverUrl,
        String? author,
        String? speaker,
        List<Song> songs,
      })> ting15Album(String detailUrl) async {
    final html = await _t15Get(detailUrl);
    if (html.isEmpty) {
      return (ok: false, message: '一五听书详情页无数据', albumName: '',
          coverUrl: null as String?, author: null as String?,
          speaker: null as String?, songs: const <Song>[]);
    }
    // 标题：h1，回退 h4 > a
    final titleM = RegExp(r'<h1[^>]*>([\s\S]*?)</h1>', caseSensitive: false)
            .firstMatch(html) ??
        RegExp(r'''<h4[^>]*>\s*<a[^>]*>([\s\S]*?)</a>''', caseSensitive: false)
            .firstMatch(html);
    final albumName = _t15Clean(titleM?.group(1) ?? '');
    // 封面：img[alt]，回退第一个 img
    final imgM = RegExp(
            r'''<img[^>]+alt=["'][^"']+["'][^>]*src=["']([^"']+)["']''',
            caseSensitive: false)
            .firstMatch(html) ??
        RegExp(r'''<img[^>]+src=["']([^"']+)["']''', caseSensitive: false)
            .firstMatch(html);
    var cover = _t15Clean(imgM?.group(1) ?? '');
    if (cover.startsWith('//')) cover = 'https:$cover';
    // 简介：.intro
    final introM = RegExp(
            r'''<div[^>]+class=["'][^"']*intro[^"']*["'][^>]*>([\s\S]*?)</div>''',
            caseSensitive: false)
        .firstMatch(html);
    final content = _t15Clean(introM?.group(1) ?? '');

    // 集数：.plist 容器内的 a（href = 章节页 URL /bookId/0-page.html）
    var scope = '';
    final plistM = RegExp(
            r'''<div[^>]+class=["'][^"']*plist[^"']*["'][^>]*>([\s\S]*?)</div>''',
            caseSensitive: false)
        .firstMatch(html);
    if (plistM != null) scope = plistM.group(1)!;
    if (scope.isEmpty) scope = html;
    final songs = <Song>[];
    final seen = <String>{};
    final reA = RegExp(r'''<a[^>]+href=["']([^"']+)["'][^>]*>([\s\S]*?)</a>''',
        caseSensitive: false);
    for (final m in reA.allMatches(scope)) {
      final href = _t15Abs(m.group(1)!);
      if (!RegExp(r'/\d+/0-\d+\.html$').hasMatch(href)) continue;
      if (seen.contains(href)) continue;
      seen.add(href);
      final name = _t15Clean(m.group(2) ?? '');
      if (name.isEmpty) continue;
      songs.add(Song(
        id: href.hashCode,
        name: name,
        artists: content,
        album: albumName,
        coverUrl: cover.isEmpty ? null : cover,
        source: SongSource.ting15,
        directUrl: href,
      ));
    }
    if (songs.isEmpty) {
      return (ok: false, message: '这本书没有解析到章节', albumName: albumName,
          coverUrl: cover.isEmpty ? null : cover, author: null as String?,
          speaker: null as String?, songs: const <Song>[]);
    }
    return (ok: true, message: '', albumName: albumName,
        coverUrl: cover.isEmpty ? null : cover, author: null as String?,
        speaker: null as String?, songs: songs);
  }

  /// 解析一五章节页 → 真实音频直链（POST 播放 API）
  Future<MusicUrlInfo> ting15Resolve(String playUrl) async {
    final m = RegExp(r'/(\d+)/0-(\d+)\.html$').firstMatch(playUrl);
    if (m == null) {
      return const MusicUrlInfo(ok: false, message: '无法识别的章节链接');
    }
    final bookId = m.group(1)!;
    final page = m.group(2)!;
    try {
      final resp = await _ting15Dio.post<String>(
        '$_t15Site/?s=api-getneoplay',
        data: 'bookId=$bookId&isPay=0&page=$page',
        options: Options(
          headers: {
            'Content-Type':
                'application/x-www-form-urlencoded; charset=UTF-8',
            'X-Requested-With': 'XMLHttpRequest',
          },
          responseType: ResponseType.plain,
        ),
      );
      final payload = (resp.data ?? '').toString();
      // JSON: { "url": "https://…mp3" }（兼容单/双引号）
      final urlM = RegExp(r'''"url"\s*:\s*"([^"]+)"''').firstMatch(payload) ??
          RegExp(r"""'url'\s*:\s*'([^']+)'""").firstMatch(payload);
      var url = urlM?.group(1) ?? '';
      url = url.replaceAll(r'\/', '/');
      if (url.startsWith('http://')) url = 'https://${url.substring(7)}';
      if (RegExp(r'^https?://').hasMatch(url)) {
        return MusicUrlInfo(
          ok: true,
          url: url,
          type: '一五听书',
          headers: {'User-Agent': _t15Ua, 'Referer': playUrl},
        );
      }
    } catch (_) {
      // API 失败 → 回落客户端嗅探（把章节页交给播放器解析）
    }
    return MusicUrlInfo(
      ok: false,
      message: '一五听书播放地址解析失败',
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
