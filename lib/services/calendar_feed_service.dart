import 'dart:convert';

import 'package:dio/dio.dart';

import 'package:tvbox/services/app_log.dart';

/// 追剧日历的一条数据（来源：MineTrakt 的公开榜单 JSON）。
class CalendarFeedItem {
  final int tmdbId;
  final String title;
  final String posterPath;
  final double rating;
  final int voteCount;
  final int popularity;
  final String releaseDate;
  final String lastUpdateDate;
  final String genre;
  final String region;
  final String mediaType;
  final int heat;
  final int rank;
  final String category;

  const CalendarFeedItem({
    required this.tmdbId,
    required this.title,
    required this.posterPath,
    required this.rating,
    required this.voteCount,
    required this.popularity,
    required this.releaseDate,
    required this.lastUpdateDate,
    required this.genre,
    required this.region,
    required this.mediaType,
    this.heat = 0,
    this.rank = 0,
    this.category = '',
  });

  String posterUrl(String imageBase) {
    if (posterPath.isEmpty) return '';
    // 兜底数据来自豆瓣，posterPath 已经是完整 URL；正常数据是 TMDB 路径
    if (posterPath.startsWith('http')) return posterPath;
    return '$imageBase/w342$posterPath';
  }

  /// 豆瓣图床需要 Referer，否则 418；TMDB 图不需要。
  Map<String, String>? get coverHeaders => posterPath.contains('doubanio.com')
      ? const {
          'Referer': 'https://movie.douban.com/',
          'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
                  'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
                  'Mobile/15E148 Safari/604.1',
        }
      : null;

  bool updatedOn(DateTime day) {
    final d = DateTime.tryParse(lastUpdateDate);
    return d != null &&
        d.year == day.year &&
        d.month == day.month &&
        d.day == day.day;
  }

  bool updatedWithin(DateTime now, int days) {
    final d = DateTime.tryParse(lastUpdateDate);
    if (d == null) return false;
    final diff = now.difference(d).inDays;
    return diff >= 0 && diff <= days;
  }

  bool releasedWithin(DateTime now, int days) {
    final d = DateTime.tryParse(releaseDate);
    if (d == null) return false;
    final diff = now.difference(d).inDays;
    return diff >= 0 && diff <= days;
  }
}

class CalendarFeedBundle {
  final List<CalendarFeedItem> doubanTv;
  final List<CalendarFeedItem> theaterAired;
  final List<CalendarFeedItem> guduoTv;
  final List<CalendarFeedItem> guduoMovie;
  final List<CalendarFeedItem> guduoVariety;
  final List<CalendarFeedItem> guduoAnime;
  final String updatedAt;

  const CalendarFeedBundle({
    required this.doubanTv,
    required this.theaterAired,
    required this.guduoTv,
    required this.guduoMovie,
    required this.guduoVariety,
    required this.guduoAnime,
    this.updatedAt = '',
  });

  bool get isEmpty =>
      doubanTv.isEmpty && theaterAired.isEmpty && guduoTv.isEmpty && guduoMovie.isEmpty;
}

/// 追剧日历数据源 —— 直接复用 MineTrakt（`_worker.js`）用的公开榜单 JSON：
///
///   · 豆瓣热播：`https://widget.v2too.top/data/douban.json`
///   · 平台剧场：`https://widget.v2too.top/data/theater.json`
///   · 骨朵热榜：`https://widget.v2too.top/data/guduo.json`
///
/// 这些 JSON 已经带 TMDB `posterPath` / 评分 / 首播与最近更新日期，
/// 比豆瓣图床稳定得多（不用 Referer、不会被 418），也不需要任何 Key。
class CalendarFeedService {
  CalendarFeedService._();
  static final CalendarFeedService instance = CalendarFeedService._();

  static const String _douban = 'https://widget.v2too.top/data/douban.json';
  static const String _theater = 'https://widget.v2too.top/data/theater.json';
  static const String _guduo = 'https://widget.v2too.top/data/guduo.json';

  static const Duration _ttl = Duration(minutes: 20);
  CalendarFeedBundle? _cache;
  DateTime? _cacheAt;

  Future<CalendarFeedBundle> fetch({
    bool force = false,
    void Function(CalendarFeedBundle partial)? onPartial,
  }) async {
    final cached = _cache;
    final at = _cacheAt;
    if (!force &&
        cached != null &&
        at != null &&
        DateTime.now().difference(at) < _ttl) {
      return cached;
    }
    final dio = Dio(BaseOptions(
      // 三份 JSON 里 theater.json 有 400KB+，蜂窝网络下慢慢传是正常的，
      // 所以 receiveTimeout 只用来判定「卡死」，总时长交给外层兜底。
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 12),
      headers: {
        'User-Agent': 'CatYing/1.0',
        'Accept': 'application/json',
      },
    ));

    // 三份 JSON 各拉各的：任何一份慢/挂都不能拖住另外两份。
    // 用户 2026-10-20：「日历一直转圈加载不出来」—— 原来 `Future.wait`
    // 等全部完成，douban.json 一旦挂起整页就永远 loading。
    final results = <String, dynamic>{};

    CalendarFeedBundle assemble() => CalendarFeedBundle(
          doubanTv: _parseDouban(results['douban']),
          theaterAired: _parseTheater(results['theater']),
          guduoTv: _parseGuduo(results['guduo'], '剧集'),
          guduoMovie: _parseGuduo(results['guduo'], '电影'),
          guduoVariety: _parseGuduo(results['guduo'], '综艺'),
          guduoAnime: _parseGuduo(results['guduo'], '动漫'),
        );

    Future<void> loadOne(String key, String url) async {
      try {
        final r = await dio
            .get<dynamic>(url)
            .timeout(const Duration(seconds: 25));
        results[key] = r.data;
      } catch (e) {
        AppLog.instance.w('[CalendarFeed] $key 失败: $e');
      }
      // 每回来一份就先把已有的喂给页面，避免用户盯着转圈等最慢的那份。
      if (onPartial != null && results.isNotEmpty) {
        try {
          onPartial(assemble());
        } catch (_) {}
      }
    }

    AppLog.instance.log('[CalendarFeed] 开始拉取榜单');
    // 豆瓣直连兜底与三个 JSON 并行：主数据源挂掉时也能出内容。
    final fallbackFuture = _doubanFallback();
    await Future.wait<void>([
      loadOne('douban', _douban),
      loadOne('theater', _theater),
      loadOne('guduo', _guduo),
    ]).timeout(const Duration(seconds: 22), onTimeout: () => const <void>[]);

    final doubanRaw = results['douban'];
    final theaterRaw = results['theater'];
    final guduoRaw = results['guduo'];

    var doubanList = _parseDouban(doubanRaw);
    if (doubanList.isEmpty) {
      doubanList = await fallbackFuture;
    }

    final bundle = CalendarFeedBundle(
      doubanTv: doubanList,
      theaterAired: _parseTheater(theaterRaw),
      guduoTv: _parseGuduo(guduoRaw, '剧集'),
      guduoMovie: _parseGuduo(guduoRaw, '电影'),
      guduoVariety: _parseGuduo(guduoRaw, '综艺'),
      guduoAnime: _parseGuduo(guduoRaw, '动漫'),
      updatedAt: (doubanRaw is Map ? doubanRaw['last_updated'] ?? '' : '')
          .toString(),
    );
    if (bundle.isEmpty && cached != null) return cached;
    _cache = bundle;
    _cacheAt = DateTime.now();
    AppLog.instance.log(
      '[CalendarFeed] 豆瓣 ${bundle.doubanTv.length} / 剧场 ${bundle.theaterAired.length}'
      ' / 骨朵 ${bundle.guduoTv.length + bundle.guduoMovie.length}',
    );
    return bundle;
  }

  /// 豆瓣直连兜底（主 JSON 全部失败时用）。
  ///
  /// 只用于「至少能看到东西」：标题/评分/封面来自豆瓣公开列表，
  /// 没有 TMDB id，也拿不到精确的首播/更新日期 —— 统一按今天算，
  /// 保证 今天 / 本周 / 本月 三个周期都能展示。
  Future<List<CalendarFeedItem>> _doubanFallback() async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 6),
        receiveTimeout: const Duration(seconds: 8),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
                  'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
                  'Mobile/15E148 Safari/604.1',
          'Referer': 'https://movie.douban.com/',
          'Accept': 'application/json',
        },
      ));
      Future<dynamic> one(String type) async {
        try {
          final r = await dio.get<dynamic>(
            'https://movie.douban.com/j/search_subjects',
            queryParameters: {
              'type': type,
              'tag': '热门',
              'page_limit': 30,
              'page_start': 0,
            },
          ).timeout(const Duration(seconds: 8));
          return r.data;
        } catch (e) {
          AppLog.instance.w('[CalendarFeed] 豆瓣兜底 $type 失败: $e');
          return null;
        }
      }

      final now = DateTime.now();
      final today =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final datas = await Future.wait([one('tv'), one('movie')]);
      final out = <CalendarFeedItem>[];
      final seen = <String>{};
      for (var i = 0; i < datas.length; i++) {
        final raw = datas[i];
        final decoded = raw is String ? jsonDecode(raw) : raw;
        if (decoded is! Map || decoded['subjects'] is! List) continue;
        for (final e in decoded['subjects'] as List) {
          if (e is! Map) continue;
          final title = (e['title'] ?? '').toString().trim();
          if (title.isEmpty || !seen.add(title)) continue;
          out.add(CalendarFeedItem(
            tmdbId: 0,
            title: title,
            posterPath: (e['cover'] ?? '').toString(),
            rating: double.tryParse('${e['rate'] ?? ''}') ?? 0,
            voteCount: 0,
            popularity: 0,
            releaseDate: today,
            lastUpdateDate: today,
            genre: '',
            region: '',
            mediaType: i == 0 ? 'tv' : 'movie',
          ));
        }
      }
      AppLog.instance.log('[CalendarFeed] 豆瓣直连兜底 ${out.length} 条');
      return out;
    } catch (e) {
      AppLog.instance.w('[CalendarFeed] 豆瓣直连兜底失败: $e');
      return const [];
    }
  }

  List<CalendarFeedItem> _parseDouban(dynamic raw) {
    if (raw is! Map) return const [];
    final list = raw['tv'];
    if (list is! List) return const [];
    final out = <CalendarFeedItem>[];
    for (final e in list) {
      if (e is! Map) continue;
      final item = _fromMap(Map<String, dynamic>.from(e));
      if (item != null) out.add(item);
    }
    // 热度优先，其次评分；同分按最近更新
    out.sort((a, b) {
      final p = b.popularity.compareTo(a.popularity);
      if (p != 0) return p;
      final r = b.rating.compareTo(a.rating);
      if (r != 0) return r;
      return b.lastUpdateDate.compareTo(a.lastUpdateDate);
    });
    return out;
  }

  List<CalendarFeedItem> _parseTheater(dynamic raw) {
    if (raw is! Map) return const [];
    final out = <CalendarFeedItem>[];
    for (final entry in raw.entries) {
      if (entry.key == 'last_updated') continue;
      final group = entry.value;
      if (group is! Map) continue;
      final aired = group['aired'];
      if (aired is! List) continue;
      for (final e in aired) {
        if (e is! Map) continue;
        final map = Map<String, dynamic>.from(e);
        map['category'] = entry.key;
        final item = _fromMap(map);
        if (item != null) out.add(item);
      }
    }
    out.sort((a, b) => b.popularity.compareTo(a.popularity));
    return out;
  }

  List<CalendarFeedItem> _parseGuduo(dynamic raw, String category) {
    if (raw is! Map) return const [];
    final categories = raw['categories'];
    if (categories is! Map) return const [];
    final list = categories[category];
    if (list is! List) return const [];
    final out = <CalendarFeedItem>[];
    for (final e in list) {
      if (e is! Map) continue;
      final map = Map<String, dynamic>.from(e);
      map['category'] = category;
      final item = _fromMap(map);
      if (item != null) out.add(item);
    }
    out.sort((a, b) {
      final ra = a.rank > 0 ? a.rank : 999;
      final rb = b.rank > 0 ? b.rank : 999;
      return ra.compareTo(rb);
    });
    return out;
  }

  /// 榜单 JSON 里的数字偶尔是字符串（`"7.2"` / `"301494"`），
  /// 直接 `as num?` 会抛 `type 'String' is not a subtype of type 'num?'`。
  static double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim()) ?? 0;
    return 0;
  }

  static int _toInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) {
      final s = v.trim();
      return int.tryParse(s) ?? double.tryParse(s)?.toInt() ?? 0;
    }
    return 0;
  }

  CalendarFeedItem? _fromMap(Map<String, dynamic> j) {
    final title = (j['title'] ?? '').toString().trim();
    if (title.isEmpty) return null;
    return CalendarFeedItem(
      tmdbId: _toInt(j['tmdbId']),
      title: title,
      posterPath: (j['posterPath'] ?? '').toString(),
      rating: _toDouble(j['rating']),
      voteCount: _toInt(j['voteCount']),
      popularity: _toDouble(j['popularity']).round(),
      releaseDate: (j['releaseDate'] ?? '').toString(),
      lastUpdateDate: (j['lastUpdateDate'] ?? '').toString(),
      genre: (j['genreTitle'] ?? '').toString(),
      region: (j['regionTitle'] ?? '').toString(),
      mediaType: (j['mediaType'] ?? 'tv').toString(),
      heat: _toInt(j['heat']),
      rank: _toInt(j['rank']),
      category: (j['category'] ?? '').toString(),
    );
  }
}
