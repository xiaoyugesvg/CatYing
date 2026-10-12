import 'dart:convert';
import 'package:dio/dio.dart';
import 'app_log.dart';
import 'dio_factory.dart';
import 'nodejs_manager.dart';
import 'python_manager.dart';

/// Spider 服务 - 对应 Swift SpiderService
/// 与本地 Node.js Spider 服务通信
///
/// 关键设计：所有方法都接受 key/type/apiBase 参数，不依赖全局状态
/// 这是因为搜索等操作是并发执行的，全局状态会导致竞态条件
class SpiderService {
  static final SpiderService _instance = SpiderService._internal();
  static SpiderService get instance => _instance;

  // 必须可重建：iOS 进入后台/锁屏时，系统的 socket 会被断开，
  // 不重建会导致切回前台后所有请求都失败（点击线路/视频无响应）
  late Dio _dio;

  SpiderService._internal() {
    _dio = _buildDio();
  }

  static Dio _buildDio() {
    return buildDioWithDns(
      connectTimeout: const Duration(seconds: 60),
      receiveTimeout: const Duration(seconds: 60),
    )..interceptors.add(_AppLogInterceptor());
  }

  // ============================================================
  // Spider 端口（从 NodeJSManager 获取）
  // ============================================================

  int get _spiderPort => NodeJSManager.instance.spiderPort;

  bool get isSpiderReady => _spiderPort > 0;

  // ============================================================
  // 路径构建 - 对应 Swift buildSpiderPath
  // ============================================================

  /// 构建 Spider 请求路径
  /// 当 apiBase 不为空时，路径为 {apiBase}/{action}
  /// 当 apiBase 为空时，路径为 /{key}/{type}/{action}
  String _buildSpiderPath(String key, int type, String apiBase, String action) {
    if (apiBase.isNotEmpty) {
      return '$apiBase/$action';
    }
    return '/$key/$type/$action';
  }

  /// 构建完整的 Spider URL
  String _buildSpiderUrl(String key, int type, String apiBase, String action) {
    return 'http://127.0.0.1:$_spiderPort${_buildSpiderPath(key, type, apiBase, action)}';
  }

  // ============================================================
  // 核心 POST 请求 - 对应 Swift postJSON
  // ============================================================

  /// 发送 POST 请求到 Spider 服务 - 对应 Swift postJSON
  /// 使用 ResponseType.plain 手动解析 JSON，接受 200-299 状态码
  /// 关键：iOS 后台/锁屏切回前台时，dio 的 socket 可能处于半死状态（OS
  /// 已标记断开但 dio 还没收到 RST），第一次请求会失败；加 1 次重试可恢复
  static const int _maxPostRetries = 1;
  static const Duration _postRetryDelay = Duration(milliseconds: 300);

  Future<Map<String, dynamic>?> _postJSON(
    String url,
    Map<String, dynamic> body,
  ) async {
    for (var attempt = 0; attempt <= _maxPostRetries; attempt++) {
      try {
        final response = await _dio.post<String>(
          url,
          data: jsonEncode(body),
          options: Options(
            contentType: Headers.jsonContentType,
            responseType: ResponseType.plain,
          ),
        );

        final statusCode = response.statusCode ?? 0;
        final responseBody = response.data ?? '';

        // 对应 Swift: guard (200...299).contains(httpResponse.statusCode)
        if (statusCode >= 200 && statusCode <= 299) {
          try {
            final decoded = jsonDecode(responseBody);
            if (decoded is Map<String, dynamic>) {
              return decoded;
            } else if (decoded is List) {
              // 某些 Spider 响应可能返回数组，包装为对象
              return {'list': decoded};
            }
            AppLog.instance.log('[SpiderService] 响应不是JSON对象: $url, body类型=${decoded.runtimeType}');
            return null;
          } catch (e) {
            AppLog.instance.log('[SpiderService] JSON解析失败: $url, 错误=$e, body=${responseBody.length > 500 ? responseBody.substring(0, 500) : responseBody}');
            return null;
          }
        } else {
          AppLog.instance.log('[SpiderService] HTTP错误 $statusCode: $url, body=${responseBody.length > 500 ? responseBody.substring(0, 500) : responseBody}');
          return null;
        }
      } on DioException catch (e) {
        // iOS 后台/锁屏切回前台时，dio 的 socket 可能半死（OS 标记断开但
        // 没收到 RST），重试一次通常能恢复
        final isRetriable = e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.sendTimeout ||
            e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.unknown;
        if (attempt < _maxPostRetries && isRetriable) {
          AppLog.instance.log('[SpiderService] POST $url 第 ${attempt + 1} 次失败，${_postRetryDelay.inMilliseconds}ms 后重试: ${e.type}/${e.message}');
          await Future.delayed(_postRetryDelay);
          // 重试前重建 dio（确保新 socket）
          try {
            _dio.close(force: true);
          } catch (e) { /* ignore */ }
          _dio = _buildDio();
          continue;
        }
        final code = e.response?.statusCode ?? 0;
        final respBody = e.response?.data?.toString() ?? '';
        AppLog.instance.log('[SpiderService] POST $url 失败: code=$code, type=${e.type}, message=${e.message}, body=${respBody.length > 500 ? respBody.substring(0, 500) : respBody}');
        return null;
      } catch (e) {
        AppLog.instance.log('[SpiderService] POST $url 未知错误: $e');
        return null;
      }
    }
    return null;
  }

  // ============================================================
  // Python 源分支（T3 Python spider：每站一个 .py，走 CPython 引擎）
  // ============================================================
  // 识别：apiBase 以 .py 结尾（TVBox type=3 Python 源惯例，api=py_xxx.py）
  //       或 key 以 py_ 开头。
  // 模块映射：`py_demo.py` / `py_demo` → `demo`（对应 src/spider/video/demo.py）
  // 返回格式与 Node spider 服务同构（{class,list} / {list} / {parse,playUrl}），
  // 调用方 source_service 无需感知引擎差异。

  bool _isPythonSource(String key, int type, String apiBase) {
    if (type != 3) return false;
    if (apiBase.toLowerCase().endsWith('.py')) return true;
    return key.toLowerCase().startsWith('py_');
  }

  /// apiBase → Python 模块 key（去 .py 后缀 + py_ 前缀）
  String _pythonModuleKey(String apiBase) {
    var k = apiBase;
    if (k.toLowerCase().endsWith('.py')) {
      k = k.substring(0, k.length - 3);
    }
    // 去掉路径部分（如 /spider/py_demo）
    final slash = k.lastIndexOf('/');
    if (slash >= 0) k = k.substring(slash + 1);
    if (k.toLowerCase().startsWith('py_')) {
      k = k.substring(3);
    }
    return k.isEmpty ? 'demo' : k;
  }

  /// 调 Python 引擎执行源方法（module=video.<key>，args 为 kwargs）
  Future<Map<String, dynamic>?> _pythonCall(
    String moduleKey,
    String action,
    Map<String, dynamic> args,
  ) async {
    final r = await PythonManager.instance.call(
      'video.$moduleKey',
      action,
      args,
    );
    if (!r.ok) {
      AppLog.instance
          .w('[SpiderService] Python 源 $moduleKey.$action 失败: ${r.error}');
      return null;
    }
    final data = r.json;
    if (data is Map<String, dynamic>) return data;
    if (data is List) return {'list': data};
    return null;
  }

  // ============================================================
  // Spider API - 所有方法都接受 key/type/apiBase 参数
  // ============================================================

  /// 获取 Spider 配置 - 对应 Swift getCatConfig
  /// 直接请求 Spider 服务器的 /config 端点（全局配置，不需要 key/type）
  Future<Map<String, dynamic>?> getCatConfig() async {
    if (!isSpiderReady) return null;

    final url = 'http://127.0.0.1:$_spiderPort/config';
    AppLog.instance.log('[SpiderService] getCatConfig: $url');

    try {
      final response = await _dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );

      final statusCode = response.statusCode ?? 0;
      final responseBody = response.data ?? '';

      if (statusCode >= 200 && statusCode <= 299) {
        try {
          final decoded = jsonDecode(responseBody);
          if (decoded is Map<String, dynamic>) {
            return decoded;
          }
          AppLog.instance.log('[SpiderService] getCatConfig 响应不是JSON对象: body类型=${decoded.runtimeType}');
          return null;
        } catch (e) {
          AppLog.instance.log('[SpiderService] getCatConfig JSON解析失败: 错误=$e, body=${responseBody.length > 500 ? responseBody.substring(0, 500) : responseBody}');
          return null;
        }
      } else {
        AppLog.instance.log('[SpiderService] getCatConfig HTTP错误 $statusCode: body=${responseBody.length > 500 ? responseBody.substring(0, 500) : responseBody}');
        return null;
      }
    } on DioException catch (e) {
      AppLog.instance.log('[SpiderService] getCatConfig 失败: ${e.type}, ${e.message}');
      return null;
    }
  }

  /// 初始化 Spider - 对应 Swift initSpider
  Future<Map<String, dynamic>?> initSpider(String key, int type, String apiBase) async {
    if (!isSpiderReady) return null;

    final url = _buildSpiderUrl(key, type, apiBase, 'init');
    AppLog.instance.log('[SpiderService] initSpider: $url');

    return _postJSON(url, <String, dynamic>{});
  }

  /// 获取首页内容 - 对应 Swift getHomeContent
  Future<Map<String, dynamic>?> getHomeContent(String key, int type, String apiBase) async {
    if (_isPythonSource(key, type, apiBase)) {
      return _pythonCall(_pythonModuleKey(apiBase), 'home', {});
    }
    if (!isSpiderReady) return null;

    final url = _buildSpiderUrl(key, type, apiBase, 'home');
    AppLog.instance.log('[SpiderService] getHomeContent: $url');

    return _postJSON(url, <String, dynamic>{});
  }

  /// 获取分类内容 - 对应 Swift getCategoryContent
  Future<Map<String, dynamic>?> getCategoryContent(
    String key, int type, String apiBase,
    String id, {
    int page = 1,
    Map<String, dynamic>? filters,
  }) async {
    if (_isPythonSource(key, type, apiBase)) {
      return _pythonCall(_pythonModuleKey(apiBase), 'category', {
        'tid': id,
        'pg': page,
        'filter': filters != null && filters.isNotEmpty,
        'extend': filters ?? {},
      });
    }
    if (!isSpiderReady) return null;

    final url = _buildSpiderUrl(key, type, apiBase, 'category');
    AppLog.instance.log('[SpiderService] getCategoryContent: $url, id=$id, page=$page');

    final body = <String, dynamic>{
      'id': id,
      'page': page,
      'filter': filters != null && filters.isNotEmpty,
      'filters': filters ?? {},
    };

    return _postJSON(url, body);
  }

  /// 获取详情 - 对应 Swift getDetail
  Future<Map<String, dynamic>?> getDetail(String key, int type, String apiBase, String id) async {
    if (_isPythonSource(key, type, apiBase)) {
      return _pythonCall(_pythonModuleKey(apiBase), 'detail', {'ids': id});
    }
    if (!isSpiderReady) return null;

    final url = _buildSpiderUrl(key, type, apiBase, 'detail');
    AppLog.instance.log('[SpiderService] getDetail: $url, id=$id');

    return _postJSON(url, {'id': id});
  }

  /// 获取播放 URL - 对应 Swift getPlayUrl
  Future<Map<String, dynamic>?> getPlayUrl(
      String key, int type, String apiBase, String flag, String id) async {
    if (_isPythonSource(key, type, apiBase)) {
      return _pythonCall(_pythonModuleKey(apiBase), 'play', {'flag': flag, 'id': id});
    }
    if (!isSpiderReady) return null;

    final url = _buildSpiderUrl(key, type, apiBase, 'play');
    AppLog.instance.log('[SpiderService] getPlayUrl: $url, flag=$flag, id=$id');

    return _postJSON(url, {'flag': flag, 'id': id});
  }

  /// 搜索 - 对应 Swift search
  Future<Map<String, dynamic>?> search(
      String key, int type, String apiBase, String keyword, {int page = 1}) async {
    if (_isPythonSource(key, type, apiBase)) {
      return _pythonCall(_pythonModuleKey(apiBase), 'search', {
        'wd': keyword,
        'pg': page,
      });
    }
    if (!isSpiderReady) return null;

    final url = _buildSpiderUrl(key, type, apiBase, 'search');
    AppLog.instance.log('[SpiderService] search: $url, keyword=$keyword, page=$page');

    return _postJSON(url, {'wd': keyword, 'page': page});
  }

  // ============================================================
  // searchWithSpider - 对应 Swift searchWithSpider
  // 原子操作：先 init 再 search，不受并发影响
  // ============================================================

  /// 使用指定 Spider 搜索 - 对应 Swift searchWithSpider
  /// 原子操作：先 init 再 search，不受并发影响
  Future<Map<String, dynamic>?> searchWithSpider({
    required String spiderKey,
    required int spiderType,
    required String apiBase,
    required String keyword,
    int page = 1,
  }) async {
    if (!isSpiderReady) return null;

    // 对应 Swift: 先 init（忽略错误），再 search
    try {
      await initSpider(spiderKey, spiderType, apiBase);
    } catch (e) { /* ignore */ }

    return search(spiderKey, spiderType, apiBase, keyword, page: page);
  }

  // ============================================================
  // 兼容旧接口 - 保留 setCurrentSpider 等方法
  // 用于非并发场景（如首页加载、详情页）
  // ============================================================

  /// 当前 Spider 会话（原子替换，避免多字段读到不一致组合）
  ({String key, int type, String apiBase})? _currentSpider;

  /// 设置当前 Spider 信息 - 对应 Swift setCurrentSpider
  /// 仅用于非并发场景
  void setCurrentSpider(String key, int type, String? apiBase,
      {String? ext, String? jar}) {
    _currentSpider = (key: key, type: type, apiBase: apiBase ?? '');
    AppLog.instance.log('[SpiderService] setCurrentSpider: key=$key, type=$type, apiBase=$apiBase');
  }

  /// 获取当前 Spider 的 key/type/apiBase
  /// 用于非并发场景（如详情页获取播放 URL）
  /// **2026-09-26 修复**：原实现 `_currentKey!` / `_currentType!` 强解包，
  /// 若用户从未经过首页/分类加载（如从历史/收藏直接进 Spider 源详情），
  /// `_currentKey` 为 null，强解包抛空安全异常 → App 崩溃"像重启一样"。
  /// 改为空安全返回：未设置时返回 ('', 0, '')，调用方自行降级。
  (String, int, String) getCurrentSpiderInfo() {
    final s = _currentSpider;
    return (s?.key ?? '', s?.type ?? 0, s?.apiBase ?? '');
  }

  /// 使当前 Spider 会话失效 - 对应 Swift invalidateSession
  /// 关键：必须同时关闭并重建 dio，否则 iOS 后台/锁屏后切回前台时
  /// dio 复用的 socket 已被系统断开，所有请求会静默失败
  void invalidateSession() {
    _currentSpider = null;
    try {
      _dio.close(force: true);
    } catch (e) { /* ignore */ }
    _dio = _buildDio();
  }
}

/// Dio 拦截器 - 记录所有 HTTP 请求到 AppLog
///
/// 关键: iOS 后台/锁屏切回前台时, dio 请求会卡住或失败, 拦截器记录
/// 每个请求的开始时间 + 状态码 + 耗时 + 错误, 帮助定位后台恢复时
/// 哪些 HTTP 请求卡住/失败
class _AppLogInterceptor extends Interceptor {
  static const _startTimeKey = '_appLogStartTime';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_startTimeKey] = DateTime.now();
    final port = _extractPort(options.uri);
    AppLog.instance.http(
      options.method,
      options.uri.toString(),
      port: port,
      caller: 'spider_dio',
    );
    super.onRequest(options, handler);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final startAt = response.requestOptions.extra[_startTimeKey] as DateTime?;
    final elapsed = startAt == null
        ? null
        : DateTime.now().difference(startAt).inMilliseconds;
    final port = _extractPort(response.requestOptions.uri);
    AppLog.instance.http(
      response.requestOptions.method,
      response.requestOptions.uri.toString(),
      statusCode: response.statusCode,
      elapsedMs: elapsed,
      port: port,
      ok: true,
      caller: 'spider_dio',
    );
    super.onResponse(response, handler);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final startAt = err.requestOptions.extra[_startTimeKey] as DateTime?;
    final elapsed = startAt == null
        ? null
        : DateTime.now().difference(startAt).inMilliseconds;
    final port = _extractPort(err.requestOptions.uri);
    AppLog.instance.http(
      err.requestOptions.method,
      err.requestOptions.uri.toString(),
      statusCode: err.response?.statusCode,
      elapsedMs: elapsed,
      port: port,
      ok: false,
      error: '${err.type.name}/${err.message ?? ''}',
      caller: 'spider_dio',
    );
    super.onError(err, handler);
  }

  /// 从 URI 提取端口 (用于日志)
  int? _extractPort(Uri uri) {
    if (uri.port == 0) return null;
    return uri.port;
  }
}
