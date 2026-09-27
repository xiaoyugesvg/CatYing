import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/vod_info.dart';

/// TMDB 智能刮削：搜索匹配 → 拉详情/演职员 → 回填 VodInfo
class TmdbService extends GetxService {
  static TmdbService get instance => Get.find<TmdbService>();

  static const _keyApiKey = 'tmdb_api_key';
  static const _keyAuto = 'tmdb_auto_scrape';
  static const _base = 'https://api.themoviedb.org/3';
  static const _img = 'https://image.tmdb.org/t/p';

  final apiKey = ''.obs;
  final autoScrape = true.obs;
  final isWorking = false.obs;

  Dio get _dio => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 15),
        queryParameters: {
          'api_key': apiKey.value,
          'language': 'zh-CN',
        },
      ));

  Future<void> loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    apiKey.value = (prefs.getString(_keyApiKey) ?? '').trim();
    autoScrape.value = prefs.getBool(_keyAuto) ?? true;
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
  Future<bool> enrich(VodInfo info) async {
    if (!configured) return false;
    isWorking.value = true;
    try {
      final title = cleanTitle(info.name);
      if (title.isEmpty) return false;
      final year = extractYear(info.note, info.year);

      final movie = await _searchBest(mediaType: 'movie', query: title, year: year);
      final tv = await _searchBest(mediaType: 'tv', query: title, year: year);

      // 简单择优：有年份匹配加分，标题更长更像
      final best = _pickBetter(movie, tv, title, year);
      if (best == null) return false;

      final detail = await _fetchDetail(best.$1, best.$2);
      if (detail == null) return false;
      _apply(info, best.$1, detail);
      return true;
    } catch (e) {
      print('[TmdbService] enrich 失败: $e');
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
      final results = (res.data['results'] as List?) ?? const [];
      if (results.isEmpty) {
        // 放宽：去掉年份再搜一次
        if (year != null) {
          final res2 = await _dio
              .get('$_base/search/$mediaType', queryParameters: {'query': query});
          final r2 = (res2.data['results'] as List?) ?? const [];
          if (r2.isEmpty) return null;
          return Map<String, dynamic>.from(r2.first);
        }
        return null;
      }
      return Map<String, dynamic>.from(results.first);
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
        'append_to_response': 'credits',
      });
      return Map<String, dynamic>.from(res.data as Map);
    } catch (_) {
      return null;
    }
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
    if ((info.note.isEmpty) && d['vote_average'] != null) {
      info.note = 'TMDB ${(d['vote_average'] as num).toDouble().toStringAsFixed(1)} 分';
    }
  }

  /// 磁盘缓存 key（供后续扩展）
  static String cacheKey(String name, String year) =>
      'tmdb_${cleanTitle(name)}_$year';
}
