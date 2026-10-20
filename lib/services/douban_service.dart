import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';

/// 一条豆瓣条目（只保留「追剧日历」要展示的字段）。
class DoubanSubject {
  final String id;
  final String title;
  final String cover;
  final double rate;
  final bool isNew;
  final String url;

  const DoubanSubject({
    required this.id,
    required this.title,
    required this.cover,
    required this.rate,
    required this.isNew,
    required this.url,
  });

  factory DoubanSubject.fromJson(Map<String, dynamic> j) {
    final rawRate = j['rate'];
    return DoubanSubject(
      id: (j['id'] ?? '').toString(),
      title: (j['title'] ?? '').toString(),
      cover: (j['cover'] ?? '').toString(),
      rate: rawRate is num
          ? rawRate.toDouble()
          : double.tryParse('${rawRate ?? ''}') ?? 0,
      isNew: j['is_new'] == true,
      url: (j['url'] ?? '').toString(),
    );
  }
}

/// 豆瓣「分类条目」数据源 —— 给「追剧日历」用。
///
/// 参考 <https://github.com/SunMoonWithYou/minetrakt> 里「豆瓣热播 / 最新」
/// 的思路：直接读豆瓣公开的 JSON 列表接口
/// `movie.douban.com/j/search_subjects`，按 type（tv/movie）+ tag（热门/最新/
/// 豆瓣高分…）取一页条目。该接口**不需要 key**，但会校验 UA/Referer；
/// 用户在「设置 → 追剧日历」里填的 Cookie 会一并带上（可选，用于风控较严时）。
class DoubanService {
  DoubanService._();
  static final DoubanService instance = DoubanService._();

  static const String _prefCookie = 'calendar_douban_cookie';
  static const String _base = 'https://movie.douban.com/j/search_subjects';
  static const String _ua =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 '
      'Safari/604.1';

  /// 进程内缓存：key = `type|tag|limit`，10 分钟内不重复请求。
  static const Duration _ttl = Duration(minutes: 10);
  final Map<String, _CacheEntry> _cache = {};

  Dio? _dio;
  String _cookie = '';
  bool _cookieLoaded = false;

  Future<Dio> _client() async {
    if (!_cookieLoaded) {
      _cookieLoaded = true;
      try {
        final prefs = await SharedPreferences.getInstance();
        _cookie = (prefs.getString(_prefCookie) ?? '').trim();
      } catch (_) {}
    }
    final d = _dio ??= Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 10),
        headers: {
          'User-Agent': _ua,
          'Referer': 'https://movie.douban.com/',
          'Accept': 'application/json, text/plain, */*',
          if (_cookie.isNotEmpty) 'Cookie': _cookie,
        },
      ),
    );
    return d;
  }

  /// 保存/清除豆瓣 Cookie（设置页调用）。
  Future<void> saveCookie(String cookie) async {
    _cookie = cookie.trim();
    _cookieLoaded = true;
    _dio?.options.headers['Cookie'] =
        _cookie.isEmpty ? null : _cookie;
    if (_cookie.isEmpty) {
      _dio?.options.headers.remove('Cookie');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefCookie, _cookie);
    } catch (_) {}
    _cache.clear();
  }

  Future<String> loadCookie() async {
    if (_cookieLoaded) return _cookie;
    _cookieLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _cookie = (prefs.getString(_prefCookie) ?? '').trim();
    } catch (_) {}
    return _cookie;
  }

  /// 取一页条目。[type] = tv / movie；[tag] = 热门 / 最新 / 豆瓣高分 …
  Future<List<DoubanSubject>> fetch({
    required String type,
    required String tag,
    int limit = 24,
  }) async {
    final key = '$type|$tag|$limit';
    final hit = _cache[key];
    if (hit != null && DateTime.now().difference(hit.at) < _ttl) {
      return hit.list;
    }
    try {
      final dio = await _client();
      final res = await dio.get<dynamic>(
        _base,
        queryParameters: {
          'type': type,
          'tag': tag,
          'page_limit': limit,
          'page_start': 0,
        },
      );
      final data = res.data;
      final decoded = data is String ? jsonDecode(data) : data;
      final list = <DoubanSubject>[];
      if (decoded is Map && decoded['subjects'] is List) {
        for (final e in decoded['subjects'] as List) {
          if (e is Map) {
            final s = DoubanSubject.fromJson(Map<String, dynamic>.from(e));
            if (s.title.isNotEmpty) list.add(s);
          }
        }
      }
      if (list.isEmpty) {
        AppLog.instance.w('[Douban] 空结果: $type/$tag');
      }
      _cache[key] = _CacheEntry(list, DateTime.now());
      return list;
    } catch (e) {
      AppLog.instance.w('[Douban] 请求失败 $type/$tag: $e');
      // 网络失败时回退到上一次成功结果（过期也比空白好）
      return hit?.list ?? const [];
    }
  }
}

class _CacheEntry {
  final List<DoubanSubject> list;
  final DateTime at;
  _CacheEntry(this.list, this.at);
}
