
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'app_log.dart';
import '../models/cache_store.dart';
import '../models/cache_ttl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/vod_info.dart';

/// TMDB 智能刮削：搜索匹配 → 拉详情/演职员 → 回填 VodInfo
class TmdbService extends GetxService {
  static TmdbService get instance => Get.find<TmdbService>();

  static const _keyApiKey = 'tmdb_api_key';
  static const _keyAuto = 'tmdb_auto_scrape';
  static const _keyShowCast = 'tmdb_show_cast';
  static const _keyShowSimilar = 'tmdb_show_similar';
  static const _keyEnabled = 'tmdb_enabled';
  static const _keyPosterStyle = 'tmdb_poster_style';
  static const _keyApiProxy = 'tmdb_api_proxy';
  static const _keyImgProxy = 'tmdb_img_proxy';
  static const _base = 'https://api.themoviedb.org/3';
  static const _img = 'https://image.tmdb.org/t/p';

  /// 总开关（关掉后完全不走 TMDB）
  final enabled = true.obs;

  /// 海报展示样式：fixed=固定 / random=随机 / rotate=轮播
  final posterStyle = 'fixed'.obs;

  /// API 代理地址（留空用官方 api.themoviedb.org）
  final apiProxy = ''.obs;

  /// 图片代理地址（留空用官方 image.tmdb.org/t/p）
  final imgProxy = ''.obs;

  final apiKey = ''.obs;
  final autoScrape = true.obs;

  /// 实际生效的 API base（代理优先）
  String get effectiveApiBase =>
      apiProxy.value.trim().isNotEmpty ? apiProxy.value.trim() : _base;

  /// 实际生效的图片 base（代理优先）
  String get effectiveImgBase =>
      imgProxy.value.trim().isNotEmpty ? imgProxy.value.trim() : _img;

  /// 详情页是否展示「演职人员」区（默认开）
  final showCast = true.obs;

  /// 详情页是否展示「类似作品」区（默认开）
  final showSimilar = true.obs;

  final isWorking = false.obs;

  Dio? _dioInstance;
  String _dioApiKey = '';

  /// 懒加载单例：apiKey 变化才重建（避免每次刮削新建连接池）
  Dio get _dio {
    if (_dioInstance == null || _dioApiKey != apiKey.value) {
      _dioApiKey = apiKey.value;
      _dioInstance?.close(force: true);
      _dioInstance = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 15),
        queryParameters: {
          'api_key': apiKey.value,
          'language': 'zh-CN',
        },
      ));
    }
    return _dioInstance!;
  }

  Future<void> loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    apiKey.value = (prefs.getString(_keyApiKey) ?? '').trim();
    autoScrape.value = prefs.getBool(_keyAuto) ?? true;
    showCast.value = prefs.getBool(_keyShowCast) ?? true;
    showSimilar.value = prefs.getBool(_keyShowSimilar) ?? true;
    enabled.value = prefs.getBool(_keyEnabled) ?? true;
    posterStyle.value = prefs.getString(_keyPosterStyle) ?? 'fixed';
    apiProxy.value = (prefs.getString(_keyApiProxy) ?? '').trim();
    imgProxy.value = (prefs.getString(_keyImgProxy) ?? '').trim();
  }

  Future<void> setEnabled(bool v) async {
    enabled.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnabled, v);
  }

  /// 海报展示样式：fixed / random / rotate
  Future<void> setPosterStyle(String v) async {
    posterStyle.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPosterStyle, v);
  }

  Future<void> setApiProxy(String v) async {
    apiProxy.value = v.trim();
    _dioInstance?.close(force: true);
    _dioInstance = null; // 代理变了必须重建连接
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyApiProxy, apiProxy.value);
  }

  Future<void> setImgProxy(String v) async {
    imgProxy.value = v.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyImgProxy, imgProxy.value);
  }

  /// 断开连接：清空 Key（代理地址保留，用户可能只是换 Key）
  Future<void> disconnect() async {
    apiKey.value = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyApiKey);
  }

  /// 测试 API 代理是否可用（发一个最轻的请求）
  Future<({bool ok, String message})> testApiProxy() async {
    final base = effectiveApiBase;
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 12),
      ));
      final r = await dio.get('$base/configuration',
          queryParameters: {'api_key': apiKey.value});
      final code = r.statusCode ?? 0;
      if (code == 200) return (ok: true, message: 'API 代理可用（HTTP 200）');
      return (ok: false, message: '返回 HTTP $code');
    } on DioException catch (e) {
      return (ok: false, message: '连接失败：${e.type.name}');
    } catch (e) {
      return (ok: false, message: '连接失败：$e');
    }
  }

  /// 测试图片代理是否可用（取一张已知存在的极小图）
  Future<({bool ok, String message})> testImgProxy() async {
    final base = effectiveImgBase;
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 12),
      ));
      final r = await dio.get('$base/w92/2u7zbn8EudG6kLlBzUYqP8RyFU4.jpg',
          options: Options(responseType: ResponseType.bytes));
      final code = r.statusCode ?? 0;
      if (code == 200) {
        final n = r.data?.length ?? 0;
        return (ok: true, message: '图片代理可用（$n 字节）');
      }
      return (ok: false, message: '返回 HTTP $code');
    } on DioException catch (e) {
      return (ok: false, message: '连接失败：${e.type.name}');
    } catch (e) {
      return (ok: false, message: '连接失败：$e');
    }
  }

  Future<void> saveApiKey(String key) async {
    apiKey.value = key.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyApiKey, apiKey.value);
  }

  Future<void> setAutoScrape(bool v) async {
    autoScrape.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAuto, v);
  }

  Future<void> setShowCast(bool v) async {
    showCast.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyShowCast, v);
  }

  Future<void> setShowSimilar(bool v) async {
    showSimilar.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyShowSimilar, v);
  }

  bool get configured => apiKey.value.isNotEmpty;

  /// 清洗标题：去掉「更新至xx集 / 全xx集 / HD / 蓝光」等噪音
  static String cleanTitle(String raw) {
    var s = raw.trim();
    s = s.replaceAll(
        RegExp(r'(更新至|更新到|全)\s*\d+\s*集', caseSensitive: false), '');
    s = s.replaceAll(
        RegExp(r'(第\s*\d+\s*季|第\s*\d+\s*部)', caseSensitive: false), '');
    s = s.replaceAll(
        RegExp(
            r'(4K|HD|蓝光|超清|高清|独播|国语|粤语|中字|完整版|修正版)',
            caseSensitive: false),
        '');
    s = s.replaceAll(RegExp(r'[\[\]【】（）()]'), ' ');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  static int? extractYear(String note, String yearField) {
    final y = int.tryParse(yearField.trim());
    if (y != null && y > 1900 && y < 2100) return y;
    final m = RegExp(r'(19|20)\d{2}').firstMatch(note);
    return int.tryParse(m?.group(0) ?? '');
  }

  /// 对 VodInfo 做智能刮削并回填（失败静默，返回是否成功）
  /// 手动匹配：返回 movie/tv 各前 5 条候选
  Future<List<(String type, Map<String, dynamic> item)>> searchCandidates(
      String title, int? year) async {
    final out = <(String, Map<String, dynamic>)>[];
    if (!configured) return out;
    for (final type in ['movie', 'tv']) {
      try {
        final qp = <String, dynamic>{'query': title};
        if (year != null) {
          qp[type == 'movie' ? 'year' : 'first_air_date_year'] = '$year';
        }
        final res = await _dio.get('${effectiveApiBase}/search/$type', queryParameters: qp);
        final results = (res.data['results'] as List?) ?? const [];
        for (final r in results.take(5)) {
          out.add((type, Map<String, dynamic>.from(r as Map)));
        }
      } catch (_) {}
    }
    return out;
  }

  /// 手动应用某条候选到 VodInfo
  Future<bool> applyCandidate(
      VodInfo info, String type, Map<String, dynamic> item) async {
    final id = item['id'];
    if (id == null) return false;
    isWorking.value = true;
    try {
      final detail = await _fetchDetail(type, id.toString());
      if (detail == null) return false;
      _apply(info, type, detail);
      final ck = cacheKey(info.name, '');
      await CacheStore.instance.setJsonCache('tmdb:$ck', {
        ...detail,
        '__type': type,
      });
      return true;
    } catch (e) {
      AppLog.instance.log('[TmdbService] applyCandidate fail: $e');
      return false;
    } finally {
      isWorking.value = false;
    }
  }

  Future<bool> enrich(VodInfo info, {bool forceNetwork = false}) async {
    if (!configured) {
      AppLog.instance.log('[TmdbService] enrich 跳过: 未配置 API Key');
      return false;
    }
    isWorking.value = true;
    try {
      final title = cleanTitle(info.name);
      if (title.isEmpty) {
        AppLog.instance.log('[TmdbService] enrich 失败: 清洗后片名为空 (原始="${info.name}")');
        return false;
      }
      final year = extractYear(info.note, info.year);
      final ck = cacheKey(info.name, year?.toString() ?? '');
      AppLog.instance.log(
          '[TmdbService] enrich 开始: 片名="$title" 年份=${year ?? "无"} cacheKey=$ck');

      // 磁盘缓存：详情刮削 30 天
      final cached = forceNetwork
          ? null
          : CacheStore.instance.getJsonCache(
              'tmdb:$ck',
              ttl: CacheTtl.tmdb,
            );
      if (cached != null && cached.isNotEmpty) {
        final type = cached['__type'] as String? ?? 'movie';
        _apply(info, type, cached);
        AppLog.instance.log('[TmdbService] enrich 命中磁盘缓存 (type=$type)');
        return true;
      }

      final movie = await _searchBest(mediaType: 'movie', query: title, year: year);
      final tv = await _searchBest(mediaType: 'tv', query: title, year: year);
      AppLog.instance.log(
          '[TmdbService] 搜索: movie=${movie == null ? "无" : movie['title'] ?? movie['name']} '
          'tv=${tv == null ? "无" : tv['title'] ?? tv['name']}');

      // 简单择优：有年份匹配加分，标题更长更像
      final best = _pickBetter(movie, tv, title, year);
      if (best == null) {
        AppLog.instance.log(
            '[TmdbService] enrich 失败: movie/tv 均无搜索结果（片名="$title" 年份=${year ?? "无"}）');
        return false;
      }

      final detail = await _fetchDetail(best.$1, best.$2);
      if (detail == null) {
        AppLog.instance.log(
            '[TmdbService] enrich 失败: 详情接口无响应 (type=${best.$1} id=${best.$2})');
        return false;
      }
      _apply(info, best.$1, detail);
      AppLog.instance.log(
          '[TmdbService] enrich 成功: type=${best.$1} id=${best.$2} '
          'rating=${info.rating} runtime=${info.runtime} '
          'cast=${info.castList.length} similar=${info.similarList.length}');
      try {
        await CacheStore.instance.setJsonCache('tmdb:$ck', {
          ...detail,
          '__type': best.$1,
        });
      } catch (_) {}
      return true;
    } catch (e) {
      AppLog.instance.log('[TmdbService] enrich 异常: $e');
      return false;
    } finally {
      isWorking.value = false;
    }
  }

  Future<Map<String, dynamic>?> _searchBest({
    required String mediaType,
    required String query,
    int? year,
  }) async {
    try {
      final qp = <String, dynamic>{'query': query};
      if (year != null) {
        qp[mediaType == 'movie' ? 'year' : 'first_air_date_year'] = '$year';
      }
      final res = await _dio.get('${effectiveApiBase}/search/$mediaType', queryParameters: qp);
      var results = (res.data['results'] as List?) ?? const [];
      if (results.isEmpty && year != null) {
        // 放宽：去掉年份再搜一次
        final res2 = await _dio.get('${effectiveApiBase}/search/$mediaType',
            queryParameters: {'query': query});
        results = (res2.data['results'] as List?) ?? const [];
      }
      if (results.isEmpty) return null;
      // 每种类型取前 3 条打分，降低「第一条不是最佳」的误匹配
      final top = results.take(3).toList();
      Map<String, dynamic>? best;
      var bestScore = -1e9;
      for (final item in top) {
        final m = Map<String, dynamic>.from(item as Map);
        var sc = 0.0;
        final t = (m['title'] ?? m['name'] ?? '').toString();
        if (t.toLowerCase() == query.toLowerCase()) sc += 5;
        if (t.toLowerCase().contains(query.toLowerCase())) sc += 2;
        final date = (m['release_date'] ?? m['first_air_date'] ?? '').toString();
        if (year != null && date.startsWith('$year')) sc += 4;
        final pop = (m['popularity'] as num?)?.toDouble() ?? 0;
        sc += (pop / 100.0).clamp(0, 1.5);
        if (sc > bestScore) {
          bestScore = sc;
          best = m;
        }
      }
      return best;
    } catch (_) {
      return null;
    }
  }

  (String, String)? _pickBetter(
    Map<String, dynamic>? movie,
    Map<String, dynamic>? tv,
    String title,
    int? year,
  ) {
    double score(Map<String, dynamic> m, String type) {
      var s = 0.0;
      final t = (m['title'] ?? m['name'] ?? '').toString();
      if (t == title) s += 3;
      if (t.contains(title) || title.contains(t)) s += 2;
      s += ((m['popularity'] ?? 0) as num).toDouble() * 0.01;
      final d = (m['release_date'] ?? m['first_air_date'] ?? '').toString();
      if (year != null && d.startsWith('$year')) s += 4;
      return s;
    }

    final candidates = <(String, String, double)>[];
    if (movie != null && (movie['id'] != null)) {
      candidates.add(('movie', movie['id'].toString(), score(movie, 'movie')));
    }
    if (tv != null && (tv['id'] != null)) {
      candidates.add(('tv', tv['id'].toString(), score(tv, 'tv')));
    }
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) => b.$3.compareTo(a.$3));
    return (candidates.first.$1, candidates.first.$2);
  }

  Future<Map<String, dynamic>?> _fetchDetail(String type, String id) async {
    try {
      final res = await _dio.get('${effectiveApiBase}/$type/$id', queryParameters: {
        // 演职员 + 类似作品/推荐 一次拿全，避免多轮请求。
        // images 只在「随机 / 轮播」时才带上 —— 固定模式不需要候选海报，
        // 多带会显著增大响应体（一部热门片可能有几十张海报）。
        'append_to_response': posterStyle.value == 'fixed'
            ? 'credits,similar,recommendations'
            : 'credits,similar,recommendations,images',
      });
      return Map<String, dynamic>.from(res.data as Map);
    } catch (_) {
      return null;
    }
  }

  /// 解析 similar + recommendations（合并去重，按评分降序，最多 12 条）
  List<VodSimilarItem> _parseSimilar(Map<String, dynamic> d) {
    final seen = <String>{};
    final out = <VodSimilarItem>[];
    for (final key in const ['similar', 'recommendations']) {
      final block = d[key];
      if (block is! Map) continue;
      final list = block['results'];
      if (list is! List) continue;
      for (final raw in list) {
        if (raw is! Map) continue;
        final id = (raw['id'] ?? '').toString();
        if (id.isEmpty || !seen.add(id)) continue;
        final mt = (raw['media_type'] ?? 'movie').toString();
        final title = (raw['title'] ?? raw['name'] ?? '').toString().trim();
        if (title.isEmpty) continue;
        final date =
            (raw['release_date'] ?? raw['first_air_date'] ?? '').toString();
        out.add(VodSimilarItem(
          id: id,
          mediaType: mt,
          title: title,
          voteAverage: (raw['vote_average'] as num?)?.toDouble() ?? 0,
          year: date.length >= 4 ? date.substring(0, 4) : '',
          posterPath: (raw['poster_path'] ?? '').toString(),
        ));
      }
    }
    out.sort((a, b) => b.voteAverage.compareTo(a.voteAverage));
    return out.take(12).toList();
  }

  /// 多张候选海报（来自 TMDB images 接口，或热门作品的 posters 列表）。
  /// key = vodId，避免不同影片互相覆盖。
  final _posterPool = <String, List<String>>{};

  /// 轮播用的下标
  final _posterCursor = <String, int>{};

  /// 记录某部影片的多张海报，供「随机 / 轮播」挑选
  void setPosterPool(String vodId, List<String> urls) {
    final cleaned = urls
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (cleaned.isEmpty) return;
    _posterPool[vodId] = cleaned;
    _posterCursor[vodId] = 0;
  }

  /// 按「海报展示样式」挑一张海报。
  ///
  /// - fixed  ：固定，返回原海报
  /// - random ：随机一张（每次调用都可能不同 → 每次进详情页换一张）
  /// - rotate ：轮播，每次调用顺延到下一张
  ///
  /// 没有候选池（未刮削到多图）时一律回落到原海报，不会显示空白。
  String pickPoster(String vodId, String fallback) {
    final pool = _posterPool[vodId];
    if (pool == null || pool.length < 2) return fallback;
    switch (posterStyle.value) {
      case 'random':
        return pool[_rand.nextInt(pool.length)];
      case 'rotate':
        final i = (_posterCursor[vodId] ?? 0) % pool.length;
        _posterCursor[vodId] = (i + 1) % pool.length;
        return pool[i];
      default:
        return fallback;
    }
  }

  static final _rand = Random();

  /// 从详情响应里收集候选海报，喂给「随机 / 轮播」。
  ///
  /// TMDB 详情默认**不含** images 字段，但如果带了就顺手用上；
  /// 另外把 backdrop 也作为一个候选（有些影片的横图更好看）。
  void _collectPosterPool(
    String vodId,
    Map<String, dynamic> d, {
    String? primary,
  }) {
    final urls = <String>[];
    if (primary != null && primary.isNotEmpty) {
      urls.add('${effectiveImgBase}/w500$primary');
    }
    // images.posters → [{file_path: ...}, ...]
    final images = d['images'];
    if (images is Map) {
      final posters = images['posters'];
      if (posters is List) {
        for (final p in posters) {
          if (p is Map) {
            final fp = p['file_path']?.toString();
            if (fp != null && fp.isNotEmpty) {
              urls.add('${effectiveImgBase}/w500$fp');
            }
          }
        }
      }
    }
    final backdrop = d['backdrop_path']?.toString();
    if (backdrop != null && backdrop.isNotEmpty) {
      urls.add('${effectiveImgBase}/w780$backdrop');
    }
    if (urls.length > 1) setPosterPool(vodId, urls);
  }

  /// 补拉 TMDB images 接口，把候选海报填进池子。
  ///
  /// 只在「随机 / 轮播」模式下调用 —— 固定模式没必要多打一次网络。
  Future<void> ensurePosterPool(
    String vodId,
    String type,
    int tmdbId,
  ) async {
    if (posterStyle.value == 'fixed') return;
    final exist = _posterPool[vodId];
    if (exist != null && exist.length > 1) return;
    try {
      final res = await _dio.get('$effectiveApiBase/$type/$tmdbId/images');
      final posters = res.data['posters'];
      if (posters is List) {
        final urls = <String>[];
        for (final p in posters) {
          if (p is Map) {
            final fp = p['file_path']?.toString();
            if (fp != null && fp.isNotEmpty) {
              urls.add('${effectiveImgBase}/w500$fp');
            }
          }
        }
        if (urls.length > 1) setPosterPool(vodId, urls);
      }
    } catch (e) {
      AppLog.instance.log('[TmdbService] 拉取候选海报失败: $e');
    }
  }

  void _apply(VodInfo info, String type, Map<String, dynamic> d) {
    final poster = d['poster_path']?.toString();
    if (poster != null && poster.isNotEmpty) {
      info.pic = '${effectiveImgBase}/w500$poster';
    }
    // 收集候选海报：详情里若已带 images.posters 就直接用，
    // 保证「随机 / 轮播」有图可换且不必额外请求。
    _collectPosterPool(info.id, d, primary: poster);
    final overview = (d['overview'] ?? '').toString().trim();
    if (overview.isNotEmpty) {
      info.des = overview;
    }
    // 评分（独立字段，不再挤进 note）
    final vote = (d['vote_average'] as num?)?.toDouble() ?? 0;
    if (vote > 0) {
      info.rating = vote;
    }
    // 时长：电影 runtime；剧集 episode_run_time 取首项
    final runtime = (d['runtime'] as num?)?.toInt() ?? 0;
    if (runtime > 0) {
      info.runtime = runtime;
    } else {
      final ert = d['episode_run_time'];
      if (ert is List && ert.isNotEmpty) {
        final v = (ert.first as num?)?.toInt() ?? 0;
        if (v > 0) info.runtime = v;
      }
    }
    final yearStr = (d['release_date'] ?? d['first_air_date'] ?? '').toString();
    if (yearStr.length >= 4) {
      info.year = yearStr.substring(0, 4);
    }
    final genres = (d['genres'] as List?) ?? const [];
    if (genres.isNotEmpty) {
      info.typeName = genres.map((e) => e['name'].toString()).join(' / ');
    }
    final credits = d['credits'] as Map?;
    final cast = (credits?['cast'] as List?) ?? const [];
    // 结构化演职人员（头像 + 角色名）——UI 的「演职人员」区用这份数据
    if (cast.isNotEmpty) {
      info.castList = cast.take(20).map((e) {
        final m = e is Map ? e : const <String, dynamic>{};
        return VodCastMember(
          name: (m['name'] ?? '').toString(),
          character: (m['character'] ?? '').toString(),
          profilePath: (m['profile_path'] ?? '').toString(),
          order: (m['order'] as num?)?.toInt() ?? 0,
        );
      }).where((c) => c.name.isNotEmpty).toList();
    }
    if (cast.isNotEmpty) {
      info.actor =
          cast.take(6).map((e) => (e['name'] ?? '').toString()).join('、');
    }
    final crew = (credits?['crew'] as List?) ?? const [];
    final directors = crew
        .where((e) => (e['job'] ?? '') == 'Director' || (e['job'] ?? '') == 'Creator')
        .map((e) => (e['name'] ?? '').toString())
        .where((e) => e.isNotEmpty)
        .toList();
    if (directors.isNotEmpty) {
      info.director = directors.take(2).join('、');
    }
    // 类似作品
    final similar = _parseSimilar(d);
    if (similar.isNotEmpty) {
      info.similarList = similar;
    }
    if ((info.note.isEmpty) && vote > 0) {
      info.note = 'TMDB ${vote.toStringAsFixed(1)} 分';
    }
  }

  /// 磁盘缓存 key（供后续扩展）
  static String cacheKey(String name, String year) =>
      'tmdb_${cleanTitle(name)}_$year';
}
