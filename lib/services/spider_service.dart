import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'app_log.dart';
import 'dio_factory.dart';
import 'nodejs_manager.dart';
import 'python_manager.dart';
import 'python_script_sources.dart';

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
  // 脚本源路由（TVBox type=3 脚本源）
  // ============================================================
  // 聚合配置（如 huahua.json）里 type=3 的脚本源有几种写法：
  //   · api = 远端 .py                     → CPython 引擎（下载 + 注册后执行）
  //   · api = py_xxx.py（设置页手动导入）   → CPython 引擎（模块名映射）
  //   · api = drpy2 运行时 + ext = 站点.js  → Node/drpy2（按需把 ext 载入引擎）
  //   · api = 远端 .js / .js.md5           → Node/drpy2（按需把 api 载入引擎）
  //
  // **为什么必须"按需载入"**：两个引擎都是「单源」架构 —— Node 同一时刻只有一份
  // index.js，Python 是「一个 key 一个模块」。所以脚本源只在被访问时才把对应脚本
  // 载入引擎，而不是像「整包就是一个 js spider」的配置那样在启动时统一加载。

  /// 脚本源实际要载入的脚本地址：ext 优先（drpy2 模式），否则用 api
  static String _scriptUrl(String api, String ext) {
    final e = ext.trim();
    if (e.isNotEmpty) {
      final p = e.toLowerCase().split('?').first;
      if (e.startsWith('http://') ||
          e.startsWith('https://') ||
          p.endsWith('.js') ||
          p.endsWith('.py')) {
        return e;
      }
    }
    return api.trim();
  }

  static bool _isPythonScript(String script) =>
      script.toLowerCase().split('?').first.endsWith('.py');

  /// Node 侧路径基址：api 是 http URL 时退化为 /{key}/{type}/{action}
  static String _nodeBase(String api) =>
      api.trim().startsWith('http') ? '' : api.trim();

  /// 「主源脚本」地址（整包就是一个 js spider 的配置）：由 AppState 在加载主源时
  /// 登记。用于「打开过程序脚本源后回到主源」时把主源脚本重新载入引擎。
  String mainScriptUrl = '';

  /// 当前已载入 Node 引擎的脚本地址 + 该脚本在引擎里的真实站点 key
  String _loadedScriptUrl = '';
  String _loadedScriptKey = '';

  /// script → Python 模块 key（去 .py 后缀 + py_ 前缀）
  String _pythonModuleKey(String script) {
    var k = script.trim();
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

  /// 确保 [script] 已载入 Node 引擎，返回引擎里的**真实站点 key**。
  ///
  /// 真实 key 以引擎 `/config` 返回的站点列表为准 —— 聚合配置里写的 key 是 TVBox
  /// 的 key，和 drpy2 模块自报的 key 未必一致；取不到时退回 [fallback]。
  Future<String?> _ensureNodeScript(String script,
      {required String fallback}) async {
    if (_loadedScriptUrl == script) {
      return _loadedScriptKey.isNotEmpty ? _loadedScriptKey : fallback;
    }
    try {
      // Node 已在跑（主源/音乐模块起过）就别再调一次启动
      if (NodeJSManager.instance.spiderPort <= 0) {
        final ok = await NodeJSManager.instance.startNodeJS();
        if (!ok) {
          AppLog.instance.w('[SpiderService] Node 启动失败，脚本源无法加载: $script');
          return null;
        }
      }
      if (!await NodeJSManager.instance.waitForSpiderPort()) {
        AppLog.instance.w('[SpiderService] 等待 spiderPort 超时: $script');
        return null;
      }
      final (loaded, msg) = await NodeJSManager.instance.loadSource(script);
      if (!loaded) {
        AppLog.instance.w('[SpiderService] 脚本载入失败 $script: ${msg ?? "未知错误"}');
        return null;
      }
      _loadedScriptUrl = script;
      _loadedScriptKey = '';
      // 脚本自身的站点 key 只有引擎知道：读 /config 取第一个。
      // 模块的 start() 是异步的，载入后首次 /config 可能还没注册完 → 小退避重试。
      for (var attempt = 0; attempt < 4 && _loadedScriptKey.isEmpty; attempt++) {
        if (attempt > 0) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
        final cfg = await getCatConfig();
        for (final s in _extractSites(cfg)) {
          final k = (s['key'] ?? '').toString().trim();
          if (k.isNotEmpty) {
            _loadedScriptKey = k;
            break;
          }
        }
      }
      AppLog.instance.log('[SpiderService] 脚本已载入 $script，'
          '引擎 key=${_loadedScriptKey.isEmpty ? fallback : _loadedScriptKey}');
      return _loadedScriptKey.isNotEmpty ? _loadedScriptKey : fallback;
    } catch (e) {
      AppLog.instance.w('[SpiderService] 脚本载入异常 $script: $e');
      return null;
    }
  }

  /// 从 /config 响应里取站点列表（兼容 {video:{sites}} 与 {sites}）
  static List<Map<String, dynamic>> _extractSites(Map<String, dynamic>? cfg) {
    if (cfg == null) return const [];
    final video = cfg['video'];
    final dynamic sites = video is Map ? video['sites'] : cfg['sites'];
    if (sites is! List) return const [];
    return sites
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// 统一分发：按脚本类型把 [action] 交给 Python 或 Node 引擎执行。
  ///
  /// [nodeArgs] / [pyArgs] 是同名 action 在两个引擎里的参数形状
  /// （Node 用 id/page/filters，Python 用 ids/tid/extend）。
  Future<Map<String, dynamic>?> _dispatchScript({
    required String key,
    required int type,
    required String api,
    required String ext,
    required String action,
    required Map<String, dynamic> nodeArgs,
    required Map<String, dynamic> pyArgs,
  }) async {
    final script = _scriptUrl(api, ext);

    // ── Python 引擎（.py）────────────────────────────────────
    if (script.isNotEmpty && _isPythonScript(script)) {
      final moduleKey = script.startsWith('http')
          ? await PythonScriptSources.instance.ensureInstalled(script)
          : _pythonModuleKey(script);
      if (moduleKey == null) return null;
      return _pythonCall(moduleKey, action, pyArgs);
    }

    // ── Node 引擎（JS / 无脚本地址）──────────────────────────
    var engineKey = key;
    if (script.isNotEmpty) {
      // 聚合配置里的脚本源：按需载入脚本，用引擎自报的真实 key
      final k = await _ensureNodeScript(script, fallback: key);
      if (k == null) return null;
      engineKey = k;
    } else if (mainScriptUrl.isNotEmpty && _loadedScriptUrl != mainScriptUrl) {
      // 主源（单 js spider 配置）：api 由 /config 下发、通常为空。若期间被程序
      // 脚本源顶替过，这里把主源脚本重新载入。
      final k = await _ensureNodeScript(mainScriptUrl, fallback: key);
      if (k != null) engineKey = k;
    }

    if (!isSpiderReady) return null;
    final url = _buildSpiderUrl(engineKey, type, _nodeBase(api), action);
    AppLog.instance.log('[SpiderService] $action: $url');
    return _postJSON(url, nodeArgs);
  }

  // ============================================================
  // Spider API - 所有方法都接受 key/type/api/ext 参数
  //   · api = 原始 api（可能是远端脚本 URL / py_xxx.py / csp_xxx / ''）
  //   · ext = drpy2 模式下的站点脚本地址（普通源为空）
  // 引擎（Node / Python）与 key 的解析全在 _dispatchScript 内部完成。
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
  ///
  /// Python 源没有 init 概念（引擎里注册即就绪）；JS 脚本源把脚本载入引擎即完成 init。
  Future<Map<String, dynamic>?> initSpider(String key, int type, String api,
      {String ext = ''}) async {
    final script = _scriptUrl(api, ext);
    if (script.isNotEmpty && _isPythonScript(script)) return null;

    // key 的解析必须与 [_dispatchScript] **完全一致** —— 聚合配置里的脚本源
    // 配置 key 和引擎自报 key 不是一回事，这里用配置 key 会 init 404、
    // 而后五个接口却能通（init 失败会被调用方 catch 掉，问题很隐蔽）。
    var engineKey = key;
    if (script.isNotEmpty) {
      final k = await _ensureNodeScript(script, fallback: key);
      if (k != null) engineKey = k;
    } else if (mainScriptUrl.isNotEmpty && _loadedScriptUrl != mainScriptUrl) {
      final k = await _ensureNodeScript(mainScriptUrl, fallback: key);
      if (k != null) engineKey = k;
    }
    if (!isSpiderReady) return null;

    final url = _buildSpiderUrl(engineKey, type, _nodeBase(api), 'init');
    AppLog.instance.log('[SpiderService] initSpider: $url');

    return _postJSON(url, <String, dynamic>{});
  }

  /// 获取首页内容 - 对应 Swift getHomeContent
  Future<Map<String, dynamic>?> getHomeContent(String key, int type, String api,
      {String ext = ''}) {
    return _dispatchScript(
      key: key,
      type: type,
      api: api,
      ext: ext,
      action: 'home',
      nodeArgs: const {},
      pyArgs: const {},
    );
  }

  /// 获取分类内容 - 对应 Swift getCategoryContent
  Future<Map<String, dynamic>?> getCategoryContent(
    String key,
    int type,
    String api,
    String id, {
    int page = 1,
    Map<String, dynamic>? filters,
    String ext = '',
  }) {
    return _dispatchScript(
      key: key,
      type: type,
      api: api,
      ext: ext,
      action: 'category',
      nodeArgs: <String, dynamic>{
        'id': id,
        'page': page,
        'filter': filters != null && filters.isNotEmpty,
        'filters': filters ?? {},
      },
      pyArgs: <String, dynamic>{
        'tid': id,
        'pg': page,
        'filter': filters != null && filters.isNotEmpty,
        'extend': filters ?? {},
      },
    );
  }

  /// 获取详情 - 对应 Swift getDetail
  Future<Map<String, dynamic>?> getDetail(
      String key, int type, String api, String id, {String ext = ''}) {
    return _dispatchScript(
      key: key,
      type: type,
      api: api,
      ext: ext,
      action: 'detail',
      nodeArgs: <String, dynamic>{'id': id},
      pyArgs: <String, dynamic>{'ids': id},
    );
  }

  /// 获取播放 URL - 对应 Swift getPlayUrl
  Future<Map<String, dynamic>?> getPlayUrl(String key, int type, String api,
      String flag, String id, {String ext = ''}) {
    return _dispatchScript(
      key: key,
      type: type,
      api: api,
      ext: ext,
      action: 'play',
      nodeArgs: <String, dynamic>{'flag': flag, 'id': id},
      pyArgs: <String, dynamic>{'flag': flag, 'id': id},
    );
  }

  /// 搜索 - 对应 Swift search
  Future<Map<String, dynamic>?> search(String key, int type, String api,
      String keyword, {int page = 1, String ext = ''}) {
    return _dispatchScript(
      key: key,
      type: type,
      api: api,
      ext: ext,
      action: 'search',
      nodeArgs: <String, dynamic>{'wd': keyword, 'page': page},
      pyArgs: <String, dynamic>{'wd': keyword, 'pg': page},
    );
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
    required String api,
    required String keyword,
    int page = 1,
    String ext = '',
  }) async {
    // 先 init（忽略错误），再 search
    try {
      await initSpider(spiderKey, spiderType, api, ext: ext);
    } catch (e) { /* ignore */ }

    return search(spiderKey, spiderType, api, keyword, page: page, ext: ext);
  }

  // ============================================================
  // 兼容旧接口 - 保留 setCurrentSpider 等方法
  // 用于非并发场景（如首页加载、详情页）
  // ============================================================

  /// 当前 Spider 会话（原子替换，避免多字段读到不一致组合）。
  ///
  /// 必须带上 [ext]：drpy2 脚本源的站点脚本在 ext 里（api 只是运行时），
  /// 详情页拿这个上下文调 getPlayUrl 时少了 ext 就会加载错脚本。
  ({String key, int type, String api, String ext})? _currentSpider;

  /// 设置当前 Spider 信息 - 对应 Swift setCurrentSpider
  /// 仅用于非并发场景。[api] 传**原始 api**（可能是远端脚本 URL）。
  void setCurrentSpider(String key, int type, String? api,
      {String? ext, String? jar}) {
    _currentSpider =
        (key: key, type: type, api: api ?? '', ext: ext ?? '');
    AppLog.instance.log(
        '[SpiderService] setCurrentSpider: key=$key, type=$type, api=$api, ext=$ext');
  }

  /// 获取当前 Spider 的 key/type/api/ext
  /// 用于非并发场景（如详情页获取播放 URL）
  /// **2026-09-26 修复**：原实现 `_currentKey!` / `_currentType!` 强解包，
  /// 若用户从未经过首页/分类加载（如从历史/收藏直接进 Spider 源详情），
  /// `_currentKey` 为 null，强解包抛空安全异常 → App 崩溃"像重启一样"。
  /// 改为空安全返回：未设置时返回空值，调用方自行降级。
  ({String key, int type, String api, String ext}) getCurrentSpiderInfo() {
    final s = _currentSpider;
    return (
      key: s?.key ?? '',
      type: s?.type ?? 0,
      api: s?.api ?? '',
      ext: s?.ext ?? '',
    );
  }

  /// 使当前 Spider 会话失效 - 对应 Swift invalidateSession
  /// 关键：必须同时关闭并重建 dio，否则 iOS 后台/锁屏后切回前台时
  /// dio 复用的 socket 已被系统断开，所有请求会静默失败
  void invalidateSession() {
    _currentSpider = null;
    // 引擎侧已载入的脚本状态也一并作废（Node 可能已被系统回收）
    _loadedScriptUrl = '';
    _loadedScriptKey = '';
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
