
import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'app_log.dart';
import '../models/cache_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/vod_info.dart';

/// TMDB 智能刮削：搜索匹配 → 拉详情/演职员 → 回填 VodInfo
class TmdbService extends GetxService {
  static TmdbService get instance => Get.find<TmdbService>();

  static const _keyApiKey = 'tmdb_api_key';
  static const _keyAuto = 'tmdb_auto_scrape';
  static const _keyShowCast = 'tmdb_show_cast';
  static const _keyShowSimilar = 'tmdb_show_similar';
  static const _base = 'https://api.themoviedb.org/3';
  static const _img = 'https://image.tmdb.org/t/p';

  final apiKey = ''.obs;
  final autoScrape = true.obs;

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
        final res = await _dio.get('$_base/search/$type', queryParameters: qp);
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
    if (!configured) return false;
    isWorking.value = true;
    try {
      final title = cleanTitle(info.name);
      if (title.isEmpty) return false;
      final year = extractYear(info.note, info.year);
      final ck = cacheKey(info.name, year?.toString() ?? '');

      // 磁盘缓存：详情刮削 30 天
      final cached = forceNetwork
          ? null
          : CacheStore.instance.getJsonCache(
              'tmdb:$ck',
              ttl: const Duration(days: 30),
            );
      if (cached != null && cached.isNotEmpty) {
        final type = cached['__type'] as String? ?? 'movie';
        _apply(info, type, cached);
        return true;
      }

      final movie = await _searchBest(mediaType: 'movie', query: title, year: year);
      final tv = await _searchBest(mediaType: 'tv', query: title, year: year);

      // 简单择优：有年份匹配加分，标题更长更像
      final best = _pickBetter(movie, tv, title, year);
      if (best == null) return false;

      final detail = await _fetchDetail(best.$1, best.$2);
      if (detail == null) return false;
      _apply(info, best.$1, detail);
      try {
        await CacheStore.instance.setJsonCache('tmdb:$ck', {
          ...detail,
          '__type': best.$1,
        });
      } catch (_) {}
      return true;
    } catch (e) {
      AppLog.instance.log('[TmdbService] enrich 失败: $e');
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
      final res = await _dio.get('$_base/search/$mediaType', queryParameters: qp);
      var results = (res.data['results'] as List?) ?? const [];
      if (results.isEmpty && year != null) {
        // 放宽：去掉年份再搜一次
        final res2 = await _dio
            .get('$_base/search/$mediaType', queryParameters: {'query': query});
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
      final res = await _dio.get('$_base/$type/$id', queryParameters: {
        // 演职员 + 类似作品/推荐 一次拿全，避免多轮请求
        'append_to_response': 'credits,similar,recommendations',
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

  void _apply(VodInfo info, String type, Map<String, dynamic> d) {
    final poster = d['poster_path']?.toString();
    if (poster != null && poster.isNotEmpty) {
      info.pic = '$_img/w500$poster';
    }
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
