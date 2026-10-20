import 'package:dio/dio.dart';

import 'app_log.dart';

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

  String posterUrl(String imageBase) =>
      posterPath.isEmpty ? '' : '$imageBase/w342$posterPath';

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
      doubanTv.isEmpty && guduoTv.isEmpty && guduoMovie.isEmpty;
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

  Future<CalendarFeedBundle> fetch({bool force = false}) async {
    final cached = _cache;
    final at = _cacheAt;
    if (!force &&
        cached != null &&
        at != null &&
        DateTime.now().difference(at) < _ttl) {
      return cached;
    }
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: {
        'User-Agent': 'CatYing/1.0',
        'Accept': 'application/json',
      },
    ));

    dynamic doubanRaw, theaterRaw, guduoRaw;
    await Future.wait([
      dio.get<dynamic>(_douban).then((r) => doubanRaw = r.data).catchError(
        (e) {
          AppLog.instance.w('[CalendarFeed] douban.json 失败: $e');
          return null;
        },
      ),
      dio.get<dynamic>(_theater).then((r) => theaterRaw = r.data).catchError(
        (e) {
          AppLog.instance.w('[CalendarFeed] theater.json 失败: $e');
          return null;
        },
      ),
      dio.get<dynamic>(_guduo).then((r) => guduoRaw = r.data).catchError(
        (e) {
          AppLog.instance.w('[CalendarFeed] guduo.json 失败: $e');
          return null;
        },
      ),
    ]);

    final bundle = CalendarFeedBundle(
      doubanTv: _parseDouban(doubanRaw),
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

  CalendarFeedItem? _fromMap(Map<String, dynamic> j) {
    final title = (j['title'] ?? '').toString().trim();
    if (title.isEmpty) return null;
    return CalendarFeedItem(
      tmdbId: (j['tmdbId'] as num?)?.toInt() ?? 0,
      title: title,
      posterPath: (j['posterPath'] ?? '').toString(),
      rating: (j['rating'] as num?)?.toDouble() ?? 0,
      voteCount: (j['voteCount'] as num?)?.toInt() ?? 0,
      popularity: (j['popularity'] as num?)?.toDouble().round() ?? 0,
      releaseDate: (j['releaseDate'] ?? '').toString(),
      lastUpdateDate: (j['lastUpdateDate'] ?? '').toString(),
      genre: (j['genreTitle'] ?? '').toString(),
      region: (j['regionTitle'] ?? '').toString(),
      mediaType: (j['mediaType'] ?? 'tv').toString(),
      heat: (j['heat'] as num?)?.toInt() ?? 0,
      rank: (j['rank'] as num?)?.toInt() ?? 0,
      category: (j['category'] ?? '').toString(),
    );
  }
}
