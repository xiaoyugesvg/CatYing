import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../reading/source/global_proxy.dart';
import 'emby_models.dart';

/// Emby 请求失败（带用户可读信息）。
class EmbyApiException implements Exception {
  EmbyApiException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Emby HTTP 客户端（一个实例对应一台服务器）。
///
/// 只实现浏览/播放所需的最小集合：
///   登录 → 媒体库视图 → 最新/继续观看 → 剧集分集 → 图片/直连播放地址。
class EmbyApi {
  EmbyApi(this.server);

  final EmbyServer server;

  late final Dio _dio = _buildDio();

  Dio _buildDio() {
    final d = Dio(BaseOptions(
      baseUrl: server.normalizedUrl,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 20),
      // 让 4xx/5xx 走 DioException，便于统一翻译错误文案
      validateStatus: (code) => code != null && code >= 200 && code < 400,
    ));
    applyGlobalProxy(d);
    return d;
  }

  String get _authHeader =>
      'MediaBrowser Client="CatMovie", Device="iPhone", '
      'DeviceId="${server.deviceId}", Version="1.0.0"';

  Options get _options => Options(headers: {
        'X-Emby-Authorization': _authHeader,
        if (server.accessToken != null && server.accessToken!.isNotEmpty)
          'X-Emby-Token': server.accessToken!,
      });

  /// 登录并把 token / userId 写回 [EmbyStore]（由调用方负责持久化）。
  Future<({String token, String userId})> authenticate() async {
    if (server.normalizedUrl.isEmpty) {
      throw EmbyApiException('请先填写服务器地址');
    }
    try {
      final res = await _dio.post(
        '/Users/AuthenticateByName',
        data: {'Username': server.username, 'Pw': server.password},
        options: _options,
      );
      final data = res.data;
      final map = data is Map ? Map<String, dynamic>.from(data) : null;
      final token = map?['AccessToken']?.toString() ?? '';
      final user = map?['User'];
      final uid = (user is Map ? user['Id']?.toString() : null) ?? '';
      if (token.isEmpty || uid.isEmpty) {
        throw EmbyApiException('登录响应缺少 AccessToken / UserId');
      }
      return (token: token, userId: uid);
    } on DioException catch (e) {
      throw EmbyApiException(_errorText(e));
    }
  }

  /// 轻量连通性检测（不带登录态也能判断服务是否在线）。
  Future<bool> ping() async {
    try {
      final res = await _dio.get('/System/Info/Public');
      return res.statusCode != null && res.statusCode! < 400;
    } catch (_) {
      return false;
    }
  }

  /// 媒体库视图（电影 / 剧集 / 合集…）。
  Future<List<EmbyItem>> getViews() async {
    final uid = server.userId;
    if (uid == null || uid.isEmpty) throw EmbyApiException('尚未登录');
    return _items('/Users/$uid/Views');
  }

  /// 继续观看（未看完的视频）。
  Future<List<EmbyItem>> getResume() async {
    final uid = server.userId;
    if (uid == null || uid.isEmpty) throw EmbyApiException('尚未登录');
    return _items(
      '/Users/$uid/Items/Resume',
      query: {
        'Limit': 12,
        'MediaTypes': 'Video',
        'Fields': 'Overview,ProductionYear,CommunityRating,RunTimeTicks',
        'ImageTypeLimit': 1,
        'EnableImageTypes': 'Primary',
      },
    );
  }

  /// 某个媒体库的最新条目（电影 + 剧集）。
  Future<List<EmbyItem>> getLatest(String parentId, {int limit = 24}) {
    return _items('/Items', query: {
      'ParentId': parentId,
      'Recursive': true,
      'IncludeItemTypes': 'Movie,Series',
      'SortBy': 'DateCreated',
      'SortOrder': 'Descending',
      'Limit': limit,
      'Fields': 'Overview,ProductionYear,CommunityRating,RunTimeTicks',
      'ImageTypeLimit': 1,
      'EnableImageTypes': 'Primary',
    });
  }

  /// 剧集的所有分集。
  Future<List<EmbyItem>> getEpisodes(String seriesId) async {
    final uid = server.userId;
    if (uid == null || uid.isEmpty) throw EmbyApiException('尚未登录');
    return _items(
      '/Shows/$seriesId/Episodes',
      query: {
        'UserId': uid,
        'Fields': 'Overview,ProductionYear,CommunityRating,RunTimeTicks',
        'ImageTypeLimit': 1,
        'EnableImageTypes': 'Primary',
      },
    );
  }

  /// 单条详情（用于从列表进入后补全简介等字段）。
  Future<EmbyItem?> getItem(String id) async {
    final uid = server.userId;
    if (uid == null || uid.isEmpty) throw EmbyApiException('尚未登录');
    try {
      final res = await _dio.get(
        '/Users/$uid/Items/$id',
        queryParameters: {
          'Fields': 'Overview,ProductionYear,CommunityRating,RunTimeTicks',
        },
        options: _options,
      );
      final data = res.data;
      if (data is Map) {
        return EmbyItem.fromJson(Map<String, dynamic>.from(data));
      }
      return null;
    } on DioException catch (e) {
      throw EmbyApiException(_errorText(e));
    }
  }

  Future<List<EmbyItem>> _items(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    try {
      final res = await _dio.get(
        path,
        queryParameters: query,
        options: _options,
      );
      final data = res.data;
      final list = data is Map ? data['Items'] : null;
      if (list is! List) return const [];
      final out = <EmbyItem>[];
      for (final e in list) {
        if (e is Map) {
          try {
            out.add(EmbyItem.fromJson(Map<String, dynamic>.from(e)));
          } catch (_) {}
        }
      }
      return out;
    } on DioException catch (e) {
      throw EmbyApiException(_errorText(e));
    }
  }

  /// 图片地址（带 token；Emby 的图片接口也接受 `api_key`）。
  String imageUrl(String itemId, {int maxHeight = 480, String? tag}) {
    final t = server.accessToken ?? '';
    final tagPart = (tag == null || tag.isEmpty) ? '' : '&tag=$tag';
    return '${server.normalizedUrl}/Items/$itemId/Images/Primary'
        '?maxHeight=$maxHeight&quality=90$tagPart&api_key=$t';
  }

  /// 直连播放地址（`static=true` 让服务端原样输出文件，不转码）。
  ///
  /// 部分编码（如 HEVC/AC3）客户端播不了时，可把 `static` 去掉走转码：
  /// `/Videos/{id}/stream?VideoCodec=h264&AudioCodec=aac&api_key=…`
  String streamUrl(String itemId, {bool static = true}) {
    final t = server.accessToken ?? '';
    if (static) {
      return '${server.normalizedUrl}/Videos/$itemId/stream'
          '?static=true&api_key=$t';
    }
    return '${server.normalizedUrl}/Videos/$itemId/stream'
        '?VideoCodec=h264&AudioCodec=aac&MaxStreamingBitrate=20000000'
        '&api_key=$t';
  }

  /// 图片请求头（CachedNetworkImage 用）。
  Map<String, String> get imageHeaders =>
      server.accessToken == null ? const {} : {'X-Emby-Token': server.accessToken!};

  String _errorText(DioException e) {
    final code = e.response?.statusCode;
    if (code == 401 || code == 403) {
      return '登录已失效或账号密码错误（HTTP $code）';
    }
    if (code != null) {
      // Emby 错误体通常是纯文本，截断避免弹窗被刷屏
      final body = e.response?.data?.toString() ?? '';
      final brief = body.length > 120 ? '${body.substring(0, 120)}…' : body;
      return '请求失败（HTTP $code）${brief.isEmpty ? '' : '：$brief'}';
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接超时，请检查服务器地址或网络代理';
      case DioExceptionType.connectionError:
        return '无法连接服务器：${server.normalizedUrl}';
      default:
        debugPrint('[Emby] request error: $e');
        return '请求失败：${e.message ?? e.type.name}';
    }
  }
}
