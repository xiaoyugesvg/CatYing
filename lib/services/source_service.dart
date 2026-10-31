import 'package:tvbox/services/app_log.dart';
import 'dart:convert';
import 'dart:io';
import 'package:tvbox/models/movie.dart';
import 'package:tvbox/models/vod_info.dart';
import 'package:tvbox/models/source_bean.dart';
import 'package:tvbox/models/movie_sort.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/services/spider_service.dart';
import 'package:tvbox/services/xbpq/xbpq_service.dart';
import 'package:tvbox/services/network_manager.dart';

/// 源错误枚举
enum SourceError {
  emptyApi,
  parseError,
  unsupportedType,
  invalidApiUrl;

  String message([String? detail]) {
    switch (this) {
      case SourceError.emptyApi:
        return '接口地址为空';
      case SourceError.parseError:
        return '数据解析错误${detail != null ? ': $detail' : ''}';
      case SourceError.unsupportedType:
        return '暂不支持 ${detail ?? "未知"} 类型的数据源，请切换其他源';
      case SourceError.invalidApiUrl:
        return '无效的接口地址${detail != null ? ': $detail' : ''}';
    }
  }
}

/// 视频源数据服务 - 对应 Swift SourceService
/// 负责从各视频源获取分类、列表、详情和搜索数据
class SourceService {
  static final SourceService _instance = SourceService._internal();
  static SourceService get instance => _instance;
  SourceService._internal();

  final NetworkManager _network = NetworkManager.instance;

  // ============================================================
  // 获取分类列表
  // ============================================================

  /// 获取指定源的分类列表和首页推荐 - 对应 Swift getSort
  Future<(List<SortData> sorts, List<Video> homeVideos)> getSort(
      SourceBean sourceBean,
      {String owner = SpiderService.ownerVod}) async {
    final api = sourceBean.api;
    // 对应 Swift: Spider 源不需要检查 api 是否为空
    if (!sourceBean.isSpiderSource && api.isEmpty) {
      throw Exception(SourceError.emptyApi.message());
    }

    if (sourceBean.isSpiderSource) {
      return _getSpiderSort(sourceBean, owner: owner);
    }

    // XBPQ 规则源：本地规则 + 抓站，没有可请求的 api 地址
    if (sourceBean.isXbpqSource) {
      return _xbpqSort(sourceBean);
    }

    if (!sourceBean.isSupportedInSwift) {
      throw Exception(
          SourceError.unsupportedType.message(sourceBean.typeDescription));
    }

    // 本地 JSON 源：没有网络接口，直接从文件里取 class / list
    if (sourceBean.isLocalSource) {
      return _localSort(sourceBean);
    }

    if (!sourceBean.isHttpApi) {
      throw Exception(SourceError.invalidApiUrl.message(api));
    }

    String jsonStr;
    if (sourceBean.type == 0) {
      // XML 接口
      jsonStr = await _network.getString(api);
    } else if (sourceBean.type == 4) {
      // Type 4: 远程接口，需要 extend 和 filter 参数
      // **OmniBox 兼容**：主请求必须带 ac=detail，否则 OmniBox 的
      // type=4 远程接口（tvbox2 订阅）收到 {filter:true} 不带 ac 会返回 500，
      // 导致首页/分类加载失败。getList / getDetail / search 均已带 ac=detail，
      // 这里补齐保持一致。
      final queryParams = <String, String>{
        'ac': 'detail',
        'filter': 'true',
      };
      final ext = sourceBean.ext;
      if (ext != null && ext.isNotEmpty) {
        final extend = await _resolveExtend(ext);
        if (extend.isNotEmpty) queryParams['extend'] = extend;
      }
      jsonStr =
          await _network.getString(_buildURL(api, queryParams));
    } else {
      // JSON 接口 (type=1)
      jsonStr = await _network
          .getString(_buildURL(api, {'ac': 'class'}));
    }

    var result = _parseSort(jsonStr, sourceBean: sourceBean);

    // MacCMS / LunaTV 兼容：标准苹果 CMS 的分类接口是 `ac=list`，
    // 而不是 TVBox JSON 习惯的 `ac=class`。`ac=class` 返回空时自动重试一次，
    // 避免「LunaTV / 影视仓配置整包没有分类和首页」。
    if (result.$1.isEmpty &&
        result.$2.isEmpty &&
        (sourceBean.type == 1 || sourceBean.type == 0)) {
      try {
        final alt = await _network.getString(_buildURL(api, {'ac': 'list'}));
        final altResult = _parseSort(alt, sourceBean: sourceBean);
        if (altResult.$1.isNotEmpty || altResult.$2.isNotEmpty) {
          result = altResult;
          jsonStr = alt;
        }
      } catch (e) {
        AppLog.instance.log('[source_service] MacCMS ac=list 回退失败: $e');
      }
    }

    // 当大多数推荐视频的 vod_pic 为空时，额外请求列表接口获取带完整海报的推荐视频
    final picMissingCount =
        result.$2.where((v) => v.pic.trim().isEmpty).length;
    final needsFallback =
        result.$2.isEmpty || picMissingCount > result.$2.length ~/ 2;

    if (needsFallback &&
        (sourceBean.type == 1 || sourceBean.type == 4)) {
      final listUrl = sourceBean.type == 4
          ? _buildURL(api, {
              'ac': 'detail',
              'filter': 'true',
              'pg': '1',
              'ext': base64Encode(utf8.encode('{}')),
            })
          : _buildURL(api, {'ac': 'videolist', 'pg': '1'});

      try {
        final listStr = await _network.getString(listUrl);
        final fallback = _parseVideoList(listStr,
            sourceKey: sourceBean.key, type: sourceBean.type);
        if (fallback.isNotEmpty) {
          result = (result.$1, fallback);
        }
      } catch (e) {
        AppLog.instance.log('[source_service] swallowed: $e');
      }
    }

    return result;
  }

  (List<SortData> sorts, List<Video> homeVideos) _parseSort(String jsonStr,
      {required SourceBean sourceBean}) {
    List<SortData> sorts = [];
    List<Video> homeVideos = [];

    if (sourceBean.type == 0) {
      sorts = _parseXMLCategories(jsonStr);
    } else {
      try {
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;

        // 解析筛选条件
        final filtersMap = _parseFilters(json['filters']);

        // 解析分类
        if (json['class'] != null) {
          for (final cls in json['class'] as List<dynamic>) {
            final c = cls as Map<String, dynamic>;
            final id = c['type_id'] is int
                ? c['type_id'].toString()
                : c['type_id'] as String? ?? '';
            final name = c['type_name'] as String? ?? '';
            sorts.add(SortData(
              id: id,
              name: name,
              filters: filtersMap[id] ?? [],
            ));
          }
        }

        // 解析首页推荐视频
        homeVideos = _parseVideoListFromJson(
            json['list'], sourceBean.key);
      } catch (e) {
        AppLog.instance.log('[source_service] swallowed: $e');
      }
    }

    return (sorts, homeVideos);
  }

  /// 解析 filters 字段
  ///
  /// 兼容几种常见写法（py / drpy / TVBox 源混用）：
  ///   · `{"分类id": [{key,name,value:[{n,v}]}]}`  —— 标准
  ///   · `[{key,name,value:[...]}]`                —— 整源共用一组筛选
  ///   · `value` / `values` 两种键名；值项 `{n,v}` / `{name,value}` / 纯字符串
  Map<String, List<SortFilter>> _parseFilters(dynamic filtersData) {
    final filtersMap = <String, List<SortFilter>>{};
    if (filtersData == null) return filtersMap;

    if (filtersData is List) {
      final parsed = _parseFilterGroups(filtersData);
      if (parsed.isNotEmpty) filtersMap['*'] = parsed;
      return filtersMap;
    }
    if (filtersData is! Map) return filtersMap;
    for (final entry in filtersData.entries) {
      final parsed = _parseFilterGroups(entry.value);
      if (parsed.isNotEmpty) filtersMap['${entry.key}'] = parsed;
    }
    return filtersMap;
  }

  /// 把一组筛选配置解析成 [SortFilter]（键名/值形状都做兼容）。
  List<SortFilter> _parseFilterGroups(dynamic value) {
    if (value is! List) return const <SortFilter>[];
    final out = <SortFilter>[];
    for (final raw in value) {
      if (raw is! Map) continue;
      final f = Map<String, dynamic>.from(raw);
      final key = (f['key'] ?? f['k'] ?? '').toString();
      if (key.isEmpty) continue;
      final name = (f['name'] ?? f['n'] ?? key).toString();
      final values = <SortFilterValue>[];
      final rawValues = f['value'] ?? f['values'] ?? f['v'];
      if (rawValues is List) {
        for (final v in rawValues) {
          if (v is Map) {
            final vv = Map<String, dynamic>.from(v);
            final n = (vv['n'] ?? vv['name'] ?? vv['v'] ?? '').toString();
            final val = (vv['v'] ?? vv['value'] ?? '').toString();
            if (n.isNotEmpty || val.isNotEmpty) {
              values.add(SortFilterValue(n: n, v: val));
            }
          } else if (v != null) {
            final s = v.toString();
            if (s.isNotEmpty) values.add(SortFilterValue(n: s, v: s));
          }
        }
      } else if (rawValues is Map) {
        // 少数 py 源把选项写成对象：{"内地": "大陆", "全部": ""}
        // 以前只认 List ⇒ 这一组变成「有行、没芯片」，看起来像筛选按钮失效。
        rawValues.forEach((k, v) {
          final n = k.toString();
          final val = v?.toString() ?? '';
          if (n.isNotEmpty) values.add(SortFilterValue(n: n, v: val));
        });
      }
      out.add(SortFilter(key: key, name: name, values: values));
    }
    return out;
  }

  List<SortData> _parseXMLCategories(String xml) {
    final sorts = <SortData>[];
    final regex = RegExp(r'<ty id="(\d+)"[^>]*>([^<]+)</ty>');
    for (final match in regex.allMatches(xml)) {
      sorts.add(SortData(
          id: match.group(1) ?? '', name: match.group(2) ?? ''));
    }
    return sorts;
  }

  // ============================================================
  // 获取分类视频列表
  // ============================================================

  /// 获取分类视频列表 - 对应 Swift getList
  Future<List<Video>> getList(
    SourceBean sourceBean,
    SortData sortData, {
    int page = 1,
    Map<String, String>? filters,
    String owner = SpiderService.ownerVod,
  }) async {
    final api = sourceBean.api;
    // 对应 Swift: Spider 源不需要检查 api 是否为空
    if (!sourceBean.isSpiderSource && api.isEmpty) {
      throw Exception(SourceError.emptyApi.message());
    }

    if (sourceBean.isSpiderSource) {
      return _getSpiderList(sourceBean, sortData,
          page: page, filters: filters, owner: owner);
    }

    if (sourceBean.isXbpqSource) {
      return _xbpqList(sourceBean, sortData, page: page);
    }

    // 本地 JSON 源：按 type_id 过滤 + 内存分页
    if (sourceBean.isLocalSource) {
      return _localList(sourceBean, sortData, page: page);
    }

    if (!sourceBean.isSupportedInSwift) {
      throw Exception(
          SourceError.unsupportedType.message(sourceBean.typeDescription));
    }

    if (!sourceBean.isHttpApi) {
      throw Exception(SourceError.invalidApiUrl.message(api));
    }

    String url;
    if (sourceBean.type == 0) {
      // XML 接口
      url = _buildURL(api, {
        'ac': 'videolist',
        't': sortData.id,
        'pg': page.toString(),
      });
    } else if (sourceBean.type == 4) {
      // Type 4: 远程接口
      final queryParams = <String, String>{
        'ac': 'detail',
        'filter': 'true',
        't': sortData.id,
        'pg': page.toString(),
      };

      // 附加筛选参数（base64 编码）
      if (filters != null && filters.isNotEmpty) {
        final filterStr = jsonEncode(filters);
        queryParams['ext'] = base64Encode(utf8.encode(filterStr));
      } else {
        queryParams['ext'] = base64Encode(utf8.encode('{}'));
      }

      // 加载 extend
      final ext = sourceBean.ext;
      if (ext != null && ext.isNotEmpty) {
        final extend = await _resolveExtend(ext);
        if (extend.isNotEmpty) queryParams['extend'] = extend;
      }
      url = _buildURL(api, queryParams);
    } else {
      // JSON 接口 (type=1)
      final queryParams = <String, String>{
        'ac': 'videolist',
        't': sortData.id,
        'pg': page.toString(),
      };

      // 附加筛选参数
      if (filters != null) {
        queryParams.addAll(filters);
      }
      url = _buildURL(api, queryParams);
    }

    var jsonStr = await _network.getString(url);
    var videos = _parseVideoList(jsonStr,
        sourceKey: sourceBean.key, type: sourceBean.type);

    // MacCMS / LunaTV 兼容：`ac=videolist` 在标准苹果 CMS 上可能为空，
    // 回退到 `ac=list`（同样是 t + pg 参数）。
    if (videos.isEmpty && (sourceBean.type == 0 || sourceBean.type == 1)) {
      try {
        final altUrl = _buildURL(api, {
          'ac': 'list',
          't': sortData.id,
          'pg': page.toString(),
          if (filters != null) ...filters,
        });
        final alt = await _network.getString(altUrl);
        final altVideos = _parseVideoList(alt,
            sourceKey: sourceBean.key, type: sourceBean.type);
        if (altVideos.isNotEmpty) videos = altVideos;
      } catch (e) {
        AppLog.instance.log('[source_service] MacCMS ac=list 列表回退失败: $e');
      }
    }
    return videos;
  }

  // ============================================================
  // 本地 JSON 源（离线）
  // ============================================================
  //
  // 「通用源」里导入一份 MacCMS 格式的 JSON（class + list）时，文件会复制到
  // App 私有目录，`api` 记为 `file://…`。这类源不联网：
  // 分类取 class、列表按 type_id 过滤、详情按 id 找、搜索按名称包含。

  /// 读本地源 JSON；坏文件/不存在都返回 null
  Future<Map<String, dynamic>?> _readLocalJson(String api) async {
    try {
      final path = Uri.parse(api).toFilePath();
      final f = File(path);
      if (!await f.exists()) return null;
      final txt = await f.readAsString();
      final j = jsonDecode(txt);
      return j is Map ? j.cast<String, dynamic>() : null;
    } catch (e) {
      AppLog.instance.log('[source_service] 本地源读取失败: $e');
      return null;
    }
  }

  /// 把原始 list 转成 Video（复用已有解析器，避免两套字段映射）
  List<Video> _localVideos(SourceBean bean, dynamic list) {
    if (list is! List) return const [];
    try {
      return _parseVideoList(jsonEncode({'list': list}),
          sourceKey: bean.key, type: 1);
    } catch (_) {
      return const [];
    }
  }

  Future<(List<SortData>, List<Video>)> _localSort(SourceBean bean) async {
    final j = await _readLocalJson(bean.api);
    if (j == null) throw Exception('本地源文件读不出来（可能已被删除）');
    final sorts = <SortData>[];
    final cls = j['class'] ?? j['classes'];
    if (cls is List) {
      for (final c in cls) {
        if (c is! Map) continue;
        final id = '${c['type_id'] ?? c['typeId'] ?? c['id'] ?? ''}'.trim();
        final name =
            '${c['type_name'] ?? c['typeName'] ?? c['name'] ?? ''}'.trim();
        if (id.isEmpty && name.isEmpty) continue;
        sorts.add(SortData(id: id, name: name.isEmpty ? id : name));
      }
    }
    final all = _localVideos(bean, j['list']);
    return (sorts, all.take(12).toList());
  }

  Future<List<Video>> _localList(
    SourceBean bean,
    SortData sort, {
    int page = 1,
  }) async {
    final j = await _readLocalJson(bean.api);
    if (j == null) throw Exception('本地源文件读不出来（可能已被删除）');
    final raw = j['list'];
    final want = sort.id.trim();
    final items = <dynamic>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map) continue;
        if (want.isNotEmpty && want != '0') {
          final tid =
              '${e['type_id'] ?? e['typeId'] ?? e['tid'] ?? ''}'.trim();
          if (tid != want) continue;
        }
        items.add(e);
      }
    }
    // 文件里是一次性全量，分页在这里切
    const size = 24;
    final from = (page - 1) * size;
    if (from >= items.length) return const [];
    return _localVideos(bean, items.skip(from).take(size).toList());
  }

  Future<VodInfo?> _localDetail(SourceBean bean, String vodId) async {
    final j = await _readLocalJson(bean.api);
    if (j == null) return null;
    final raw = j['list'];
    if (raw is! List) return null;
    for (final e in raw) {
      if (e is! Map) continue;
      final id = '${e['vod_id'] ?? e['id'] ?? ''}'.trim();
      if (id == vodId) {
        return _parseDetail(jsonEncode({'list': [e]}),
            sourceKey: bean.key, type: 1);
      }
    }
    return null;
  }

  Future<List<Video>> _localSearch(SourceBean bean, String keyword) async {
    final j = await _readLocalJson(bean.api);
    if (j == null) return const [];
    final kw = keyword.trim().toLowerCase();
    if (kw.isEmpty) return const [];
    final raw = j['list'];
    if (raw is! List) return const [];
    final hit = <dynamic>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final name = '${e['vod_name'] ?? e['name'] ?? ''}'.toLowerCase();
      if (name.contains(kw)) hit.add(e);
    }
    return _localVideos(bean, hit);
  }

  List<Video> _parseVideoList(String jsonStr,
      {required String sourceKey, required int type}) {
    final videos = <Video>[];

    if (type == 0) {
      return _parseXMLVideoList(jsonStr, sourceKey: sourceKey);
    }

    try {
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      videos.addAll(_parseVideoListFromJson(json['list'], sourceKey));
    } catch (e) {
        AppLog.instance.log('[source_service] swallowed: $e');
      }

    return videos;
  }

  /// 从 JSON list 字段解析视频列表
  List<Video> _parseVideoListFromJson(
      dynamic listData, String sourceKey) {
    final videos = <Video>[];
    if (listData == null) return videos;

    for (final item in listData as List<dynamic>) {
      try {
        var video = Video.fromJson(item as Map<String, dynamic>);
        video = Video(
          id: video.id,
          name: video.name,
          pic: video.pic,
          note: video.note,
          year: video.year,
          area: video.area,
          type: video.type,
          director: video.director,
          actor: video.actor,
          des: video.des,
          sourceKey: sourceKey,
          tid: video.tid,
          last: video.last,
          dt: video.dt,
        );
        videos.add(video);
      } catch (e) {
        AppLog.instance.log('[source_service] swallowed: $e');
      }
    }
    return videos;
  }

  List<Video> _parseXMLVideoList(String xml, {required String sourceKey}) {
    final videos = <Video>[];
    final regex = RegExp(
        r'<video>.*?<id>(\d+)</id>.*?<name><!\[CDATA\[(.+?)\]\]></name>.*?<pic>(.*?)</pic>.*?<note><!\[CDATA\[(.*?)\]\]></note>.*?</video>',
        dotAll: true);
    for (final match in regex.allMatches(xml)) {
      videos.add(Video(
        id: match.group(1) ?? '',
        name: match.group(2) ?? '',
        pic: match.group(3) ?? '',
        note: match.group(4) ?? '',
        sourceKey: sourceKey,
      ));
    }
    return videos;
  }

  // ============================================================
  // 获取详情
  // ============================================================

  /// 获取视频详情 - 对应 Swift getDetail
  Future<VodInfo?> getDetail(SourceBean sourceBean, String vodId,
      {String owner = SpiderService.ownerVod}) async {
    final api = sourceBean.api;
    // 对应 Swift: Spider 源不需要检查 api 是否为空
    if (!sourceBean.isSpiderSource && api.isEmpty) {
      throw Exception(SourceError.emptyApi.message());
    }

    if (sourceBean.isSpiderSource) {
      return _getSpiderDetail(sourceBean, vodId, owner: owner);
    }

    if (sourceBean.isXbpqSource) {
      return _xbpqDetail(sourceBean, vodId);
    }

    // 本地 JSON 源：从文件里找这条
    if (sourceBean.isLocalSource) {
      return _localDetail(sourceBean, vodId);
    }

    if (!sourceBean.isSupportedInSwift) {
      throw Exception(
          SourceError.unsupportedType.message(sourceBean.typeDescription));
    }

    if (!sourceBean.isHttpApi) {
      throw Exception(SourceError.invalidApiUrl.message(api));
    }

    String url;
    if (sourceBean.type == 0) {
      url = _buildURL(api, {'ac': 'videolist', 'ids': vodId});
    } else if (sourceBean.type == 4) {
      // Type 4: 远程接口
      final queryParams = <String, String>{
        'ac': 'detail',
        'ids': vodId,
      };

      // 加载 extend
      final ext = sourceBean.ext;
      if (ext != null && ext.isNotEmpty) {
        final extend = await _resolveExtend(ext);
        if (extend.isNotEmpty) queryParams['extend'] = extend;
      }
      url = _buildURL(api, queryParams);
    } else {
      // JSON 接口 (type=1)
      url = _buildURL(api, {'ac': 'detail', 'ids': vodId});
    }

    final jsonStr = await _network.getString(url);
    return _parseDetail(jsonStr,
        sourceKey: sourceBean.key, type: sourceBean.type);
  }

  VodInfo? _parseDetail(String jsonStr,
      {required String sourceKey, required int type}) {
    if (type == 0) return _parseXMLDetail(jsonStr, sourceKey: sourceKey);

    try {
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final list = json['list'] as List<dynamic>?;
      if (list == null || list.isEmpty) return null;

      final first = list.first as Map<String, dynamic>;
      var video = Video.fromJson(first);
      video = Video(
        id: video.id,
        name: video.name,
        pic: video.pic,
        note: video.note,
        year: video.year,
        area: video.area,
        type: video.type,
        director: video.director,
        actor: video.actor,
        des: video.des,
        sourceKey: sourceKey,
        tid: video.tid,
        last: video.last,
        dt: video.dt,
      );

      final playFrom = first['vod_play_from'] as String? ?? '';
      final playUrl = first['vod_play_url'] as String? ?? '';

      return VodInfo.fromVideo(
        video: video,
        playFrom: playFrom,
        playUrl: playUrl,
      );
    } catch (_) {
      return null;
    }
  }

  // ============================================================
  // 搜索
  // ============================================================

  /// 在指定源中搜索 - 对应 Swift search
  Future<List<Video>> search(SourceBean sourceBean, String keyword,
      {String owner = SpiderService.ownerVod}) async {
    final api = sourceBean.api;
    // 对应 Swift: Spider 源不需要检查 api 是否为空
    if (!sourceBean.isSpiderSource && api.isEmpty) {
      throw Exception(SourceError.emptyApi.message());
    }

    if (sourceBean.isSpiderSource) {
      return _spiderSearch(sourceBean, keyword, owner: owner);
    }

    if (sourceBean.isXbpqSource) {
      return _xbpqSearch(sourceBean, keyword);
    }

    // 本地 JSON 源：在文件里的 list 中做名称包含匹配
    if (sourceBean.isLocalSource) {
      return _localSearch(sourceBean, keyword);
    }

    if (!sourceBean.isSupportedInSwift) {
      throw Exception(
          SourceError.unsupportedType.message(sourceBean.typeDescription));
    }

    if (!sourceBean.isHttpApi) {
      throw Exception(SourceError.invalidApiUrl.message(api));
    }

    String url;
    if (sourceBean.type == 0) {
      url = _buildURL(api, {'wd': keyword});
    } else if (sourceBean.type == 4) {
      // Type 4: 远程接口
      final quickValue =
          sourceBean.isQuickSearchEnabled ? 'true' : 'false';
      final queryParams = <String, String>{
        'wd': keyword,
        'ac': 'detail',
        'quick': quickValue,
      };

      // 加载 extend
      final ext = sourceBean.ext;
      if (ext != null && ext.isNotEmpty) {
        final extend = await _resolveExtend(ext);
        if (extend.isNotEmpty) queryParams['extend'] = extend;
      }
      url = _buildURL(api, queryParams);
    } else {
      // JSON 接口 (type=1)
      url = _buildURL(api, {'wd': keyword});
    }

    final jsonStr = await _network.getString(url);
    final videos = _parseVideoList(jsonStr,
        sourceKey: sourceBean.key, type: sourceBean.type);
    return _filterSearchResults(videos, keyword: keyword);
  }

  /// 多源并发搜索 - 对应 Swift searchAll
  Future<List<Video>> searchAll(String keyword,
      {String owner = SpiderService.ownerVod}) async {
    final sources = ApiConfig.instance.getSearchableSources();
    final validSources =
        sources.where((s) => s.isSupportedInSwift).toList();

    final allResults = <Video>[];
    final futures = <Future<List<Video>>>[];

    for (final source in validSources) {
      futures.add(
          search(source, keyword, owner: owner).catchError((_) => <Video>[]));
    }

    final results = await Future.wait(futures);
    for (final videos in results) {
      allResults.addAll(videos);
    }

    return allResults;
  }

  /// 对源返回结果做本地关键词过滤，规避部分接口返回推荐/无关内容
  List<Video> _filterSearchResults(List<Video> videos,
      {required String keyword}) {
    final tokens = keyword
        .split(RegExp(r'\s+'))
        .map((t) => _normalizeSearchText(t))
        .where((t) => t.isNotEmpty)
        .toList();

    if (tokens.isEmpty) return videos;

    return videos.where((video) {
      final searchableText = _normalizeSearchText([
        video.name,
        video.note,
        video.actor,
        video.director,
        video.type,
        video.area,
        video.year,
      ].join(' '));
      if (searchableText.isEmpty) return false;
      return tokens.every((token) => searchableText.contains(token));
    }).toList();
  }

  /// 规范化搜索文本：移除标点、空白，转小写
  String _normalizeSearchText(String text) {
    final cleaned = text
        .replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '')
        .toLowerCase();
    return cleaned;
  }

  // ============================================================
  // Extend 解析
  // ============================================================

  /// 解析 extend 参数 - 对应 Swift resolveExtend
  Future<String> _resolveExtend(String extend) async {
    if (extend.isEmpty) return '';

    // 非 HTTP URL 直接返回
    if (!extend.startsWith('http://') &&
        !extend.startsWith('https://')) {
      return extend;
    }

    // 从 HTTP URL 加载 extend 内容
    try {
      final content = await _network.getString(extend);
      final trimmed = content.trim();
      // 如果内容过长（>2500），回退到使用原始 URL
      if (trimmed.length > 2500) return extend;
      return trimmed;
    } catch (_) {
      return extend;
    }
  }

  // ============================================================
  // XML 解析
  // ============================================================

  VodInfo? _parseXMLDetail(String xml, {required String sourceKey}) {
    final videoBlock =
        RegExp(r'<video[\s\S]*?</video>').firstMatch(xml);
    if (videoBlock == null) return null;

    final block = videoBlock.group(0)!;
    final vodId = _extractXMLTag('id', block);
    if (vodId.isEmpty) return null;

    final video = Video(
      id: vodId,
      name: _extractXMLTag('name', block),
      pic: _extractXMLTag('pic', block),
      note: _extractXMLTag('note', block),
      year: _extractXMLTag('year', block),
      area: _extractXMLTag('area', block),
      type: _extractXMLTag('type', block),
      director: _extractXMLTag('director', block),
      actor: _extractXMLTag('actor', block),
      des: _extractXMLTag('des', block),
      sourceKey: sourceKey,
    );

    // 解析 XML 的 dd 节点获取播放线路
    final ddNodes = _extractXMLDDNodes(block);
    final playFrom = ddNodes.isEmpty
        ? '默认'
        : ddNodes.map((n) => n.$1).join('\$\$\$');
    final playUrl =
        ddNodes.isEmpty ? '' : ddNodes.map((n) => n.$2).join('\$\$\$');

    return VodInfo.fromVideo(
        video: video, playFrom: playFrom, playUrl: playUrl);
  }

  List<(String, String)> _extractXMLDDNodes(String block) {
    final regex =
        RegExp(r'<dd([^>]*)>([\s\S]*?)</dd>', caseSensitive: false);
    final result = <(String, String)>[];

    for (final match in regex.allMatches(block)) {
      if (match.groupCount < 2) continue;
      final attrs = match.group(1) ?? '';
      final rawUrl = _decodeXMLText(match.group(2) ?? '');
      if (rawUrl.isEmpty) continue;

      final flagMatch =
          RegExp(r'''flag\s*=\s*["']([^"']+)["']''').firstMatch(attrs);
      final flag = flagMatch != null
          ? _decodeXMLText(flagMatch.group(1)!)
          : '线路${result.length + 1}';
      result.add((flag, rawUrl));
    }

    return result;
  }

  String _extractXMLTag(String tag, String content) {
    final escapedTag = RegExp.escape(tag);
    final regex = RegExp('<$escapedTag>\\s*([\\s\\S]*?)\\s*</$escapedTag>',
        caseSensitive: false);
    final match = regex.firstMatch(content);
    final value = match?.group(1) ?? '';
    return _decodeXMLText(value);
  }

  String _decodeXMLText(String raw) {
    var value = raw.trim();
    if (value.startsWith('<![CDATA[') &&
        value.endsWith(']]>') &&
        value.length >= 12) {
      value = value.substring(9, value.length - 3);
    }
    value = value.replaceAll('&amp;', '&');
    value = value.replaceAll('&lt;', '<');
    value = value.replaceAll('&gt;', '>');
    value = value.replaceAll('&quot;', '"');
    value = value.replaceAll('&#39;', "'");
    return value.trim();
  }

  // ============================================================
  // URL 构建
  // ============================================================

  String _buildURL(String base, Map<String, String> queryItems) {
    final trimmedBase = base.trim();
    final uri = Uri.tryParse(trimmedBase);
    if (uri == null) {
      throw Exception(SourceError.invalidApiUrl.message(base));
    }

    final existingParams = uri.queryParameters;
    final mergedParams = {...existingParams, ...queryItems};
    return uri.replace(queryParameters: mergedParams).toString();
  }

  // ============================================================
  // XBPQ 规则源（key 前缀 `localxbpq_`）
  //
  // 取数逻辑全在 `services/xbpq/` 里（纯 Dart、有 187 条离线自检），这里只做
  // 「TVBox 协议 → 本项目的 Video / VodInfo」这一步转换，复用既有解析函数，
  // 因此 XBPQ 源与订阅线路在 UI 上完全同权（分类、搜索、收藏、历史都一样）。
  // ============================================================

  /// 首页：分类 + 第一页列表。
  Future<(List<SortData>, List<Video>)> _xbpqSort(SourceBean bean) async {
    final (classes, videos) = await XbpqService.instance.home(bean.key);
    final sorts = <SortData>[];
    for (final c in classes) {
      final id = (c['type_id'] ?? '').trim();
      final name = (c['type_name'] ?? '').trim();
      if (id.isEmpty && name.isEmpty) continue;
      sorts.add(SortData(id: id, name: name.isEmpty ? id : name));
    }
    return (sorts, _parseVideoListFromJson(videos, bean.key));
  }

  Future<List<Video>> _xbpqList(
    SourceBean bean,
    SortData sort, {
    int page = 1,
  }) async {
    final videos = await XbpqService.instance.category(
      bean.key,
      categoryId: sort.id,
      page: page,
    );
    return _parseVideoListFromJson(videos, bean.key);
  }

  Future<VodInfo?> _xbpqDetail(SourceBean bean, String vodId) async {
    final first = await XbpqService.instance.detail(bean.key, vodId);
    if (first == null) return null;

    final video = Video.fromJson(first);
    return VodInfo.fromVideo(
      video: Video(
        id: video.id,
        name: video.name,
        pic: video.pic,
        note: video.note,
        year: video.year,
        area: video.area,
        type: video.type,
        director: video.director,
        actor: video.actor,
        des: video.des,
        sourceKey: bean.key,
        tid: video.tid,
        last: video.last,
        dt: video.dt,
      ),
      playFrom: first['vod_play_from'] as String? ?? '',
      playUrl: first['vod_play_url'] as String? ?? '',
    );
  }

  Future<List<Video>> _xbpqSearch(SourceBean bean, String keyword) async {
    final videos = await XbpqService.instance.search(bean.key, keyword);
    return _parseVideoListFromJson(videos, bean.key);
  }

  // ============================================================
  // Spider API (type=3) - 对应 Swift Spider 相关方法
  // ============================================================

  /// 设置当前 Spider 并获取首页内容
  /// 对应 Swift getSpiderSort - 调用 setCurrentSpider 设置全局状态
  Future<(List<SortData>, List<Video>)> _getSpiderSort(
      SourceBean sourceBean, {
    String owner = SpiderService.ownerVod,
  }) async {
    final spider = SpiderService.instance;

    // 对应 Swift: key 去掉 nodejs_ 前缀；脚本路由见下方 api/ext 说明
    final key = sourceBean.key.startsWith('nodejs_')
        ? sourceBean.key.substring(7)
        : sourceBean.key;
    // 传**原始 api + ext**：脚本源（.py / drpy2 ext）的路由由 SpiderService 内部
    // 判定 —— 之前在这里把 http URL 的 api 清空成 ''，导致远端 .py 永远进不了
    // Python 引擎（用户 2026-10-13：huahua.json 的 py 源"显示不了影视内容"）。
    final api = sourceBean.api;
    final ext = sourceBean.ext ?? '';

    // 对应 Swift: setCurrentSpider 设置全局状态（供详情页 getPlayUrl 使用）
    spider.setCurrentSpider(key, sourceBean.type, api,
        ext: sourceBean.ext, jar: sourceBean.jar, owner: owner);

    // 初始化 Spider - 对应 Swift: try await spider.initSpider()
    try {
      await spider.initSpider(key, sourceBean.type, api, ext: ext, owner: owner);
    } catch (e) {
        AppLog.instance.log('[source_service] swallowed: $e');
      }

    // 获取首页内容
    final result = await spider.getHomeContent(key, sourceBean.type, api,
        ext: ext, owner: owner);
    if (result == null) {
      // 以前这里直接返回"空分类 + 空列表" ⇒ 首页一片空白，用户只知道"啥都没有"，
      // 根本分不清是引擎没起来、脚本没下下来、脚本报错，还是源站挂了
      //（用户 2026-10-13：「py 源里面没有内容，啥都没有，还显示网络加载失败」）。
      // 现在把真实原因抛出去 → 首页错误态会原样显示，可定位。
      throw Exception(spider.lastError ?? '该源没有返回任何内容');
    }

    final sorts = <SortData>[];
    final homeVideos = <Video>[];

    // 解析筛选条件
    final filtersMap = _parseFilters(result['filters']);

    // 解析分类
    if (result['class'] != null) {
      for (final cls in result['class'] as List<dynamic>) {
        if (cls is! Map) continue;
        final c = Map<String, dynamic>.from(cls);
        // 兼容 type_id/type_name 与 id/name 两种写法（py 源常见后者）
        final rawId = c['type_id'] ?? c['id'] ?? c['tid'];
        final id = rawId?.toString() ?? '';
        if (id.isEmpty) continue;
        final name = (c['type_name'] ?? c['name'] ?? id).toString();
        // 少数源把 filters 直接挂在分类项里；顶层共用组用 '*' 兜底。
        // 个别 py 源的顶层 key 用的是**分类名**而不是 type_id，所以两种都查一遍
        //（用户反馈：py 源在首页看不到筛选按钮）。
        final own = _parseFilters(c['filters'])[id] ?? const <SortFilter>[];
        final byName = _parseFilters(c['filters'])[name];
        final merged = <SortFilter>[
          ...?filtersMap[id],
          ...?filtersMap[name],
          if (byName != null) ...byName,
          ...?filtersMap['*'],
          ...own,
        ];
        sorts.add(SortData(id: id, name: name, filters: merged));
      }
    }

    // 解析首页推荐视频
    homeVideos.addAll(
        _parseVideoListFromJson(result['list'], sourceBean.key));

    return (sorts, homeVideos);
  }

  /// 获取 Spider 分类视频列表
  /// 对应 Swift getSpiderList - 调用 setCurrentSpider 设置全局状态
  Future<List<Video>> _getSpiderList(
    SourceBean sourceBean,
    SortData sortData, {
    int page = 1,
    Map<String, String>? filters,
    String owner = SpiderService.ownerVod,
  }) async {
    final spider = SpiderService.instance;

    // 对应 Swift: key 去掉 nodejs_ 前缀；脚本路由见下方 api/ext 说明
    final key = sourceBean.key.startsWith('nodejs_')
        ? sourceBean.key.substring(7)
        : sourceBean.key;
    final api = sourceBean.api;
    final ext = sourceBean.ext ?? '';

    // 对应 Swift: setCurrentSpider 设置全局状态（按归属者分区，不覆盖别人）
    spider.setCurrentSpider(key, sourceBean.type, api,
        ext: sourceBean.ext, jar: sourceBean.jar, owner: owner);

    // 获取分类内容
    final result = await spider.getCategoryContent(
      key, sourceBean.type, api,
      sortData.id,
      page: page,
      filters: filters?.map((k, v) => MapEntry(k, v)),
      ext: ext,
      owner: owner,
    );

    if (result == null) return [];

    return _parseVideoListFromJson(result['list'], sourceBean.key);
  }

  /// 获取 Spider 详情
  /// 对应 Swift getSpiderDetail - 调用 setCurrentSpider 设置全局状态
  Future<VodInfo?> _getSpiderDetail(SourceBean sourceBean, String vodId,
      {String owner = SpiderService.ownerVod}) async {
    final spider = SpiderService.instance;

    // 对应 Swift: key 去掉 nodejs_ 前缀；脚本路由见下方 api/ext 说明
    final key = sourceBean.key.startsWith('nodejs_')
        ? sourceBean.key.substring(7)
        : sourceBean.key;
    final api = sourceBean.api;
    final ext = sourceBean.ext ?? '';

    // 对应 Swift: setCurrentSpider 设置全局状态（供详情页 getPlayUrl 使用）
    spider.setCurrentSpider(key, sourceBean.type, api,
        ext: sourceBean.ext, jar: sourceBean.jar, owner: owner);

    // 获取详情 - 对应 Swift: getDetail 只发送 id
    final result = await spider.getDetail(key, sourceBean.type, api, vodId,
        ext: ext, owner: owner);
    if (result == null) return null;

    final list = result['list'] as List<dynamic>?;
    if (list == null || list.isEmpty) return null;

    final first = list.first as Map<String, dynamic>;
    var video = Video.fromJson(first);
    video = Video(
      id: video.id,
      name: video.name,
      pic: video.pic,
      note: video.note,
      year: video.year,
      area: video.area,
      type: video.type,
      director: video.director,
      actor: video.actor,
      des: video.des,
      sourceKey: sourceBean.key,
      tid: video.tid,
      last: video.last,
      dt: video.dt,
    );

    final playFrom = first['vod_play_from'] as String? ?? '';
    final playUrl = first['vod_play_url'] as String? ?? '';

    return VodInfo.fromVideo(
        video: video, playFrom: playFrom, playUrl: playUrl);
  }

  /// Spider 搜索 - 对应 Swift spiderSearch
  /// 使用 searchWithSpider 原子操作，避免并发竞态条件
  Future<List<Video>> _spiderSearch(SourceBean sourceBean, String keyword,
      {String owner = SpiderService.ownerVod}) async {
    final spider = SpiderService.instance;

    // 对应 Swift: key 去掉 nodejs_ 前缀；脚本路由见下方 api/ext 说明
    final key = sourceBean.key.startsWith('nodejs_')
        ? sourceBean.key.substring(7)
        : sourceBean.key;
    final api = sourceBean.api;
    final ext = sourceBean.ext ?? '';

    AppLog.instance.log('[SourceService] _spiderSearch: key=$key, type=${sourceBean.type}, api=$api, keyword=$keyword');

    // 对应 Swift searchWithSpider: 原子操作，先 init 再 search
    // 不依赖全局状态，避免并发搜索时竞态条件
    final result = await spider.searchWithSpider(
      spiderKey: key,
      spiderType: sourceBean.type,
      api: api,
      keyword: keyword,
      ext: ext,
      owner: owner,
    );
    if (result == null) {
      AppLog.instance.log('[SourceService] _spiderSearch: searchWithSpider 返回 null');
      return [];
    }

    final list = result['list'];
    AppLog.instance.log('[SourceService] _spiderSearch: 返回 list=${list is List ? list.length : list.runtimeType} items');
    return _parseVideoListFromJson(list, sourceBean.key);
  }
}
