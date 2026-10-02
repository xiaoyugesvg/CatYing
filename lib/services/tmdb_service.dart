
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
  static const _keyLibraryMode = 'tmdb_library_mode';
  static const _base = 'https://api.themoviedb.org/3';
  static const _img = 'https://image.tmdb.org/t/p';

  /// 内置默认 Key（用户提供；设置页未填写时自动生效，填写则覆盖）
  static const _defaultApiKey = '6d6be1a1b3ab89a859e188abc279760a';

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

  /// 媒体库模式开关（设置 → TMDB 管理）：
  /// 开启后进入视频详情页时切换为媒体库界面（TMDB 数据驱动），
  /// 播放器也切换为媒体库播放器。
  final libraryMode = false.obs;

  /// 最近一次 enrich 失败原因（供媒体库视图引导卡显示精确原因；
  /// 未配置 Key / 搜索无结果 / 网络异常 分开提示）
  final lastEnrichError = RxnString();

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
    if (apiKey.value.isEmpty) {
      // 设置页未填写时用内置默认 Key，保证「配好即用」
      apiKey.value = _defaultApiKey;
    }
    autoScrape.value = prefs.getBool(_keyAuto) ?? true;
    showCast.value = prefs.getBool(_keyShowCast) ?? true;
    showSimilar.value = prefs.getBool(_keyShowSimilar) ?? true;
    enabled.value = prefs.getBool(_keyEnabled) ?? true;
    posterStyle.value = prefs.getString(_keyPosterStyle) ?? 'fixed';
    apiProxy.value = (prefs.getString(_keyApiProxy) ?? '').trim();
    imgProxy.value = (prefs.getString(_keyImgProxy) ?? '').trim();
    libraryMode.value = prefs.getBool(_keyLibraryMode) ?? false;
  }

  Future<void> setEnabled(bool v) async {
    enabled.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnabled, v);
  }

  /// 媒体库模式：开启后详情页/播放器切换为媒体库界面
  Future<void> setLibraryMode(bool v) async {
    libraryMode.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyLibraryMode, v);
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

  /// 刮削数据测试（设置 → TMDB 管理）：
  /// 用真实片名搜索 TMDB，返回是否拿到数据 + 候选列表，
  /// 用于验证 Key/代理/网络整条链路可用。
  Future<
      ({
        bool ok,
        String message,
        List<(String, Map<String, dynamic>)> candidates,
      })> testScrape(String rawTitle) async {
    if (!configured) {
      return (ok: false, message: '未配置 API Key', candidates: const <(String, Map<String, dynamic>)>[]);
    }
    final title = cleanTitle(rawTitle);
    if (title.isEmpty) {
      return (ok: false, message: '片名为空，无法测试', candidates: const <(String, Map<String, dynamic>)>[]);
    }
    try {
      final qp = <String, dynamic>{'query': title};
      final out = <(String, Map<String, dynamic>)>[];
      // 先试电影，无结果再试剧集
      final res = await _dio.get(
        '${effectiveApiBase}/search/movie',
        queryParameters: qp,
      );
      final movieResults = (res.data['results'] as List?) ?? const [];
      for (final r in movieResults.take(3)) {
        out.add(('movie', Map<String, dynamic>.from(r as Map)));
      }
      if (out.isEmpty) {
        final res2 = await _dio.get(
          '${effectiveApiBase}/search/tv',
          queryParameters: qp,
        );
        final tvResults = (res2.data['results'] as List?) ?? const [];
        for (final r in tvResults.take(3)) {
          out.add(('tv', Map<String, dynamic>.from(r as Map)));
        }
      }
      if (out.isEmpty) {
        return (ok: false, message: '搜索无结果（TMDB 可能未收录该片）', candidates: const <(String, Map<String, dynamic>)>[]);
      }
      return (
        ok: true,
        message: '✅ 获取成功，找到 ${out.length} 条候选',
        candidates: out,
      );
    } on DioException catch (e) {
      return (ok: false, message: '请求失败：${e.type.name}（$e）', candidates: const <(String, Map<String, dynamic>)>[]);
    } catch (e) {
      return (ok: false, message: '请求失败：$e', candidates: const <(String, Map<String, dynamic>)>[]);
    }
  }

  /// 详情刮削测试（设置 → TMDB 管理）：
  /// 从「刮削数据测试」选中的候选，跑一遍与媒体库详情页**完全相同**的
  /// enrich 链路（详情 + 演职员 + 类似作品 + 剧集剧照），返回刮削摘要，
  /// 用于验证整条 TMDB 数据链路是否齐全。
  Future<
      ({
        bool ok,
        String message,
        Map<String, dynamic> summary,
      })> testScrapeDetail(String type, Map<String, dynamic> candidate) async {
    if (!configured) {
      return (ok: false, message: '未配置 API Key', summary: const <String, dynamic>{});
    }
    final name = (candidate['title'] ?? candidate['name'] ?? '').toString();
    if (name.isEmpty) {
      return (ok: false, message: '候选片名为空', summary: const <String, dynamic>{});
    }
    final date =
        (candidate['release_date'] ?? candidate['first_air_date'] ?? '')
            .toString();
    final year = date.length >= 4 ? date.substring(0, 4) : '';
    final info = VodInfo(
      id: 'tmdb-test',
      name: name,
      year: year,
      typeName: type == 'tv' ? '剧集' : '电影',
    );
    try {
      final ok = await enrich(info, forceNetwork: true);
      final summary = <String, dynamic>{
        'title': info.tmdbName.isNotEmpty ? info.tmdbName : name,
        'typeName': info.typeName,
        'year': info.year,
        'rating': info.rating,
        'status': info.tmdbStatus,
        'director': info.director,
        'overview': info.des,
        'castCount': info.castList.length,
        'similarCount': info.similarList.length,
        'stillsCount': info.episodeStills.length,
        'episodeCount': info.episodeCount,
        'hasBackdrop': info.backdrop.isNotEmpty,
        'hasPoster': info.pic.isNotEmpty,
      };
      if (!ok) {
        final err = lastEnrichError.value ?? '刮削失败';
        return (ok: false, message: '详情刮削失败：$err', summary: summary);
      }
      return (ok: true, message: '✅ 详情刮削成功（完整链路）', summary: summary);
    } catch (e) {
      return (ok: false, message: '详情刮削异常：$e', summary: const <String, dynamic>{});
    }
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
      // 剧集：拉首季剧照+集标题（媒体库剧集缩略图条用）
      if (type == 'tv') {
        final season = _firstSeasonNumber(detail);
        final stills = await _fetchSeasonStills(id.toString(), season);
        if (stills.isNotEmpty) {
          info.episodeStills = stills.map((k, v) => MapEntry(k, v.still));
          info.episodeTitles = stills.map((k, v) => MapEntry(k, v.title));
          detail['__episode_stills'] = {
            for (final e in stills.entries) '${e.key}': e.value.still,
          };
          detail['__episode_titles'] = {
            for (final e in stills.entries) '${e.key}': e.value.title,
          };
        }
      }
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
      lastEnrichError.value = '未配置 API Key';
      AppLog.instance.log('[TmdbService] enrich 跳过: 未配置 API Key');
      return false;
    }
    isWorking.value = true;
    lastEnrichError.value = null;
    try {
      final title = cleanTitle(info.name);
      if (title.isEmpty) {
        lastEnrichError.value = '片名清洗后为空';
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
      // 重新刮削：先清理旧的缓存条目，再拉取新数据回写
      if (forceNetwork) {
        try {
          await CacheStore.instance.removeCacheItem('tmdb:$ck');
        } catch (_) {}
      }
      if (cached != null && cached.isNotEmpty) {
        final type = cached['__type'] as String? ?? 'movie';
        _apply(info, type, cached);
        // 恢复剧集剧照 + 集标题（缓存里带 __episode_stills / __episode_titles）
        final stills = cached['__episode_stills'];
        if (stills is Map && stills.isNotEmpty) {
          info.episodeStills = stills.map((k, v) =>
              MapEntry(int.tryParse('$k') ?? 0, '$v'));
        }
        final epTitles = cached['__episode_titles'];
        if (epTitles is Map && epTitles.isNotEmpty) {
          info.episodeTitles = epTitles.map(
              (k, v) => MapEntry(int.tryParse('$k') ?? 0, '$v'));
        }
        // 旧缓存（本轮逐集剧照功能上线前刮削的）没有剧照 →
        // 命中缓存时也补拉每一集剧照并回写缓存，保证自动进入就能看到
        if (type == 'tv' && info.episodeStills.isEmpty) {
          final tvId = (cached['id'] ?? '').toString();
          if (tvId.isNotEmpty) {
            final season = _firstSeasonNumber(cached);
            final s2 = await _fetchSeasonStills(tvId, season);
            if (s2.isNotEmpty) {
              info.episodeStills = s2.map((k, v) => MapEntry(k, v.still));
              info.episodeTitles = s2.map((k, v) => MapEntry(k, v.title));
              cached['__episode_stills'] = {
                for (final e in s2.entries) '${e.key}': e.value.still,
              };
              cached['__episode_titles'] = {
                for (final e in s2.entries) '${e.key}': e.value.title,
              };
              try {
                await CacheStore.instance.setJsonCache('tmdb:$ck', cached);
              } catch (_) {}
            }
          }
        }
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
        lastEnrichError.value = 'TMDB 未收录该片（搜索无结果）';
        AppLog.instance.log(
            '[TmdbService] enrich 失败: movie/tv 均无搜索结果（片名="$title" 年份=${year ?? "无"}）');
        return false;
      }

      final detail = await _fetchDetail(best.$1, best.$2);
      if (detail == null) {
        lastEnrichError.value = 'TMDB 详情接口无响应';
        AppLog.instance.log(
            '[TmdbService] enrich 失败: 详情接口无响应 (type=${best.$1} id=${best.$2})');
        return false;
      }
      _apply(info, best.$1, detail);
      // 剧集：拉首季剧照+集标题 → 媒体库「剧集缩略图条」用真实剧照与标题（参考图缺口）
      if (best.$1 == 'tv') {
        final season = _firstSeasonNumber(detail);
        final stills = await _fetchSeasonStills(best.$2, season);
        if (stills.isNotEmpty) {
          info.episodeStills =
              stills.map((k, v) => MapEntry(k, v.still));
          info.episodeTitles =
              stills.map((k, v) => MapEntry(k, v.title));
          detail['__episode_stills'] = {
            for (final e in stills.entries) '${e.key}': e.value.still,
          };
          detail['__episode_titles'] = {
            for (final e in stills.entries) '${e.key}': e.value.title,
          };
        }
      }
      AppLog.instance.log(
          '[TmdbService] enrich 成功: type=${best.$1} id=${best.$2} '
          'rating=${info.rating} runtime=${info.runtime} '
          'cast=${info.castList.length} similar=${info.similarList.length} '
          'stills=${info.episodeStills.length} '
          'epCount=${info.episodeCount} status=${info.tmdbStatus}');
      try {
        await CacheStore.instance.setJsonCache('tmdb:$ck', {
          ...detail,
          '__type': best.$1,
        });
      } catch (_) {}
      lastEnrichError.value = null;
      return true;
    } catch (e) {
      lastEnrichError.value = 'TMDB 连接失败（可检查网络或 API 代理）';
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

  /// 演员/导演相关作品（媒体库「相关推荐」区）：
  /// /person/{id}/combined_credits —— 电影 + 剧集合并、去重、按人气排序，
  /// 最多 20 条。失败静默返回空。
  Future<List<Map<String, dynamic>>> fetchPersonWorks(int personId) async {
    if (!configured || personId <= 0) return const [];
    try {
      final res = await _dio.get(
        '${effectiveApiBase}/person/$personId/combined_credits',
        queryParameters: {'language': 'zh-CN'},
      );
      final data = Map<String, dynamic>.from(res.data as Map);
      final seen = <String>{};
      final out = <Map<String, dynamic>>[];
      void collect(Object? list) {
        if (list is! List) return;
        for (final e in list) {
          if (e is! Map) continue;
          final type = (e['media_type'] ?? '').toString();
          if (type != 'movie' && type != 'tv') continue;
          final id = (e['id'] as num?)?.toInt() ?? 0;
          if (id <= 0) continue;
          final key = '$type-$id';
          if (!seen.add(key)) continue;
          final title = (e['title'] ?? e['name'] ?? '').toString().trim();
          if (title.isEmpty) continue;
          final date =
              (e['release_date'] ?? e['first_air_date'] ?? '').toString();
          out.add({
            'mediaType': type,
            'id': id,
            'title': title,
            'year': date.length >= 4 ? date.substring(0, 4) : '',
            'posterPath': (e['poster_path'] ?? '').toString(),
            'rating': (e['vote_average'] as num?)?.toDouble() ?? 0,
            'role': (e['character'] ?? e['job'] ?? '').toString(),
            'popularity': (e['popularity'] as num?)?.toDouble() ?? 0,
          });
        }
      }

      collect(data['cast']);
      collect(data['crew']);
      out.sort((a, b) {
        final pa = (a['popularity'] as num?)?.toDouble() ?? 0;
        final pb = (b['popularity'] as num?)?.toDouble() ?? 0;
        return pb.compareTo(pa);
      });
      return out.take(20).toList();
    } catch (_) {
      return const [];
    }
  }

  /// 第一个有集的季号；seasons 缺数据时兜底 1
  int _firstSeasonNumber(Map<String, dynamic> detail) {
    final seasons = detail['seasons'];
    if (seasons is List) {
      for (final s in seasons) {
        if (s is Map) {
          final n = (s['season_number'] as num?)?.toInt() ?? 0;
          final cnt = (s['episode_count'] as num?)?.toInt() ?? 0;
          if (n > 0 && cnt > 0) return n;
        }
      }
    }
    return 1;
  }

  /// 拉取某一季的剧集剧照与标题（键 = 集号，值 = still URL + 集标题）。
  /// 供媒体库刮削视图「剧集缩略图条」使用（参考图：缩略图 + 集标题）；
  /// 失败静默，不影响刮削主流程。
  /// 拉取指定季的「每一集」剧照 + 集标题。
  ///
  /// 关键点：TMDB 的 `/tv/{id}/season/{n}` 响应里**没有** still_path，
  /// 每集剧照只能通过 `/tv/{id}/season/{n}/episode/{m}/images` 逐集获取，
  /// 所以这里分两步：先拿集号/集名列表，再对每集并发拉 images（取第一张 still）。
  Future<Map<int, ({String still, String title})>> _fetchSeasonStills(
      String tvId, int season) async {
    final out = <int, ({String still, String title})>{};
    try {
      final res = await _dio.get(
        '${effectiveApiBase}/tv/$tvId/season/$season',
        queryParameters: {'language': 'zh-CN'},
      );
      final data = Map<String, dynamic>.from(res.data as Map);
      final eps = data['episodes'];
      if (eps is! List || eps.isEmpty) return out;
      // 集号 → 集名（缩略图条无图时仍有标题可用）
      final epMeta = <int, String>{};
      for (final e in eps) {
        if (e is! Map) continue;
        final n = (e['episode_number'] as num?)?.toInt() ?? 0;
        if (n <= 0) continue;
        final title = (e['name'] ?? '').toString().trim();
        epMeta[n] = title;
        out[n] = (still: '', title: title);
      }
      // 逐集并发拉剧照（默认 5 路并发，失败的单集保持无图）
      final ns = epMeta.keys.toList()..sort();
      const concurrency = 5;
      var idx = 0;
      while (idx < ns.length) {
        final batch = <Future<void>>[];
        for (var k = 0; k < concurrency && idx < ns.length; k++, idx++) {
          final n = ns[idx];
          batch.add(() async {
            try {
              final r = await _dio.get(
                '${effectiveApiBase}/tv/$tvId/season/$season/episode/$n/images',
              );
              final d = Map<String, dynamic>.from(r.data as Map);
              final stills = d['stills'];
              if (stills is List && stills.isNotEmpty && stills.first is Map) {
                final sp = (stills.first['file_path'] ?? '').toString();
                if (sp.isNotEmpty) {
                  out[n] = (
                    still: '${effectiveImgBase}/w300$sp',
                    title: epMeta[n] ?? '',
                  );
                }
              }
            } catch (e) {
              AppLog.instance
                  .log('[TmdbService] 第$n集剧照失败: $e');
            }
          }());
        }
        await Future.wait(batch);
      }
    } catch (e) {
      AppLog.instance.log('[TmdbService] 拉取剧集剧照失败: $e');
    }
    return out;
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
    // 背景大图（媒体库刮削视图的头图用；backdrop 是横版图）
    final backdrop = d['backdrop_path']?.toString();
    if (backdrop != null && backdrop.isNotEmpty) {
      info.backdrop = '${effectiveImgBase}/w780$backdrop';
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
    // TMDB 官方标题（zh-CN 语言下优先返回中文名）——媒体库刮削视图显示用
    final tmdbTitle =
        (d['title'] ?? d['name'] ?? '').toString().trim();
    if (tmdbTitle.isNotEmpty) {
      info.tmdbName = tmdbTitle;
    }
    // TMDB 原始标题/别名（original_title / original_name——头图副标题）
    final origTitle =
        (d['original_title'] ?? d['original_name'] ?? '').toString().trim();
    if (origTitle.isNotEmpty) {
      info.tmdbOriginalName = origTitle;
    }
    // TMDB 播出日期（完整日期，媒体库视图元数据胶囊显示）
    final dateStr =
        (d['release_date'] ?? d['first_air_date'] ?? '').toString().trim();
    if (dateStr.isNotEmpty) {
      info.releaseDate = dateStr;
    }
    // TMDB 剧集状态（Returning Series / Ended / …，参考图元数据行）
    final status = (d['status'] ?? '').toString().trim();
    if (status.isNotEmpty) {
      info.tmdbStatus = status;
    }
    // TMDB 总集数（参考图 "47 ep"）
    final epCount = (d['number_of_episodes'] as num?)?.toInt() ?? 0;
    if (epCount > 0) {
      info.episodeCount = epCount;
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
          id: (m['id'] as num?)?.toInt() ?? 0,
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
