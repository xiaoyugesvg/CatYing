// lib/services/nodejs_manager.dart
//
// Node.js 管理器 - **跨平台单例**
// -----------------------------------------------------------------------------
// 三端用各自的 Node.js 嵌入方案：
//   - **Windows**: Process.start(node.exe) + 按需下载 zip
//   - **iOS**:     platform channel → Swift → NodeMobile.xcframework
//   - **Android**: platform channel → Kotlin → libnode（占位，未实现）
//
// 跨端通用的部分（HTTP server 收通知、UI ValueNotifier、源管理 HTTP 调用）留在
// 本文件。各端平台实现在 [nodejs_platform_*.dart] 里。
//
// **目录布局**：
// ```
//   <AppSupport>/node-runtime/     # Windows 专用：node.exe
//   <AppSupport>/nodejs/main.js    # Windows: rootBundle 解压
//   <Documents>/nodejs/source/     # Windows 源目录
//   <Documents>/nodejs-project/src/source/  # iOS 源目录
// ```

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart' show rootBundle;

import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/nodejs_platform.dart';
import 'package:tvbox/services/nodejs_platform_ios.dart';

class NodeJSManager {
  static final NodeJSManager _instance = NodeJSManager._internal();
  static NodeJSManager get instance => _instance;

  // ============================================================
  // 平台实现
  // ============================================================
  late final NodeJSPlatform _platform;
  NodeJSPlatform get platform => _platform;

  // UI ValueNotifier
  final ValueNotifier<double?> nodeDownloadProgress = ValueNotifier(null);
  final ValueNotifier<String?> nodeDownloadStatus = ValueNotifier(null);

  // HTTP server 状态（跨端统一）
  HttpServer? _httpServer;
  int _nativeServerPort = 0;

  /// 本地回环通知鉴权 token（Node 启动时通过 argv 传入，请求需携带）
  final String _localAuthToken =
      DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
          (1000 + DateTime.now().millisecond).toRadixString(36);
  String get localAuthToken => _localAuthToken;

  late final Dio _localHttpDio = () {
    final d = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 2),
      sendTimeout: const Duration(seconds: 2),
      receiveTimeout: const Duration(seconds: 2),
    ));
    // 管理端口校验 x-auth-token（与 main.js mgmtServer 一致）
    d.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        options.headers['x-auth-token'] = _localAuthToken;
        handler.next(options);
      },
    ));
    return d;
  }();
  int get nativeServerPort => _nativeServerPort;

  /// Node → Dart 的「**WebView 抓页**」钩子（由「海阔」模块注册）。
  ///
  /// 入参：`(url, 完整请求体)`；出参：`{'ok': true, 'html': '...'}` 或
  /// `{'ok': false, 'error': '...'}`。
  /// 未注册（模块没装/没启用）时 `/hiker/webview` 回 501，**不报错、不影响别处**。
  static Future<Map<String, dynamic>> Function(
    String url,
    Map<String, dynamic> req,
  )? webViewFetcher;

  // HTTP server 层 → 平台实现的桥接
  final ValueNotifier<bool> _nodeReadyBridge = ValueNotifier(false);
  final ValueNotifier<int> _managementPortBridge = ValueNotifier(0);
  final ValueNotifier<int> _spiderPortBridge = ValueNotifier(0);

  NodeJSManager._internal() {
    if (!Platform.isIOS) {
      // 非 iOS：不支持嵌入 Node，延迟报错到 startNodeJS，构造不崩溃
      AppLog.instance.nodejs('unsupported_platform',
          fields: {'os': Platform.operatingSystem});
    }
    final ios = IOSNodeJSPlatform(
      onNodeReadyChanged: _nodeReadyBridge,
      onManagementPortChanged: _managementPortBridge,
      onSpiderPortChanged: _spiderPortBridge,
    );
    ios.authToken = _localAuthToken;
    ios.initialize();
    _platform = ios;
  }

  // ============================================================
  // 公开 API（透传到 platform 实现）
  // ============================================================

  bool get isRunning => _platform.isRunning;
  bool get isNodeReady => _platform.isNodeReady;
  int get managementPort => _platform.managementPort;
  int get spiderPort => _platform.spiderPort;

  /// 启动 Node.js
  ///
  /// 1. 启动 Dart 端 HTTP server（收 Node.js 通知）
  /// 2. 把 HTTP server 端口注入 platform 实现
  /// 3. 调 platform.startNodeJS()
  Future<bool> startNodeJS() async {
    // 1. 起 HTTP server
    if (_httpServer == null) {
      final started = await _startLocalWebServer();
      if (!started) return false;
    }
    // 2. 注入端口
    _platform.setNativeServerPort(_nativeServerPort);
    // 3. 启动
    return await _platform.startNodeJS();
  }

  /// 解绑 Node.js（**不会**真正杀掉 iOS 上的 embed Node 进程）。
  ///
  /// NodeMobile 只导出 `node_start`，没有 `node_exit`；Swift 侧 `stopNodeJS`
  /// 只能把 isRunning / 端口清掉。App 进程退出时 Node 会随宿主一起被回收。
  /// 调用方不要把它当成「进程已退出」，只是本端不再认为 Node 可用。
  void stopNodeJS() {
    final spider = _platform.spiderPort;
    final mgmt = _platform.managementPort;
    AppLog.instance.nodejs('stopNodeJS_detach', fields: {
      'spiderPort': spider,
      'managementPort': mgmt,
      'note': 'iOS NodeMobile cannot be killed; detach only',
    });
    _platform.stopNodeJS();
    _stopHttpServer();
  }

  // **2026-07-08 删 resetPlatformStateForRestart**:
  // 6988e13 引入的 force_restart 路径 (调本方法清 Swift isRunning + startNodeJS
  // 重启 Node.js) 实测无效. iOS NodeMobile 是 embed library, V8 单例, 第二次
  // node_start 调会卡 V8 init 阶段, node.log 0 行新 boot 记录, 新 Node.js
  // 永远起不来. 而且老 Node.js 通常只是 iOS 后台冻结 (74s 后台不触发 SIGKILL),
  // 实际还活着, 端口冲突让新 Node.js EADDRINUSE 立即失败.
  //
  // 改为: app_state.dart 不再调本方法, 改用 6×10s=60s 长重试给 iOS 自动解冻
  // 老 Node.js 时间. 重试仍 fail 后弹窗让用户手动重启 app.

  void forceResetRunningState() {
    // **关键**: 不停 Dart HTTP server. Node.js 死了之后, iOS 唤醒
    // 触发 handleSceneActive, 如果停掉 Dart HTTP server 然后调
    // startNodeJS 重启 Node.js, Node.js 启动后通过 onCatPawOpenPort
    // 通知 Dart 新端口 — 但 Dart HTTP server 刚停/正在重启, 新连接
    // 进不来, 通知丢失, Dart 永远拿不到新端口, verify 永远失败.
    //
    // HTTP server 必须一直跑, Node.js 任何时候启动都能通知到.
    // 之前 79177e1 行为就是只清状态不停 server, 才是对的.
    AppLog.instance.nodejs('forceReset', fields: {
      'beforeSpiderPort': _platform.spiderPort,
      'beforeMgmtPort': _platform.managementPort,
      'beforeIsRunning': _platform.isRunning,
      'reason': '保留 HTTP server, 只清状态',
    });
    _platform.forceResetRunningState();
    AppLog.instance.nodejs('forceReset_done', fields: {
      'afterSpiderPort': _platform.spiderPort,
      'afterMgmtPort': _platform.managementPort,
      'afterIsRunning': _platform.isRunning,
    });
  }

  Future<bool> waitForNodeReady() => _platform.waitForNodeReady();
  Future<bool> waitForSpiderPort() => _platform.waitForSpiderPort();

  Future<(bool success, String? message)> loadSource(String urlString) =>
      _platform.loadSource(urlString);

  Future<bool> deleteSource() => _platform.deleteSource();

  Future<String> getDocumentsSourcePath() => _platform.getDocumentsSourcePath();

  /// 启动某个小程序自带的 Node 后端（manifest.json 的 `node` 字段）。
  ///
  /// 会先确保 Node 进程 + management 端口就绪（音乐模块/海阔/源引擎共用同一个
  /// Node 进程，通常已经起来了）。返回 `http://127.0.0.1:<port>`，失败返回 null。
  Future<String?> startMiniAppService({
    required String appId,
    required String dir,
    String entry = 'server/index.js',
    String config = 'server/index.config.js',
  }) async {
    if (!isRunning || managementPort <= 0) {
      final ok = await startNodeJS();
      if (!ok) return null;
      await waitForNodeReady();
    }
    // management 端口是 Node 异步通知回来的 ⇒ 再等一小会儿（最多 8 秒）
    for (var i = 0; i < 40 && managementPort <= 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (managementPort <= 0) return null;
    return _platform.startMiniAppService(
      appId: appId,
      dir: dir,
      entry: entry,
      config: config,
    );
  }

  /// 停止某个小程序的 Node 后端（页面关闭时调用）
  Future<void> stopMiniAppService(String appId) =>
      _platform.stopMiniAppService(appId);

  /// 当前平台的 NodeDownloadConfig（iOS 无需下载运行时）
  NodeDownloadConfig? get nodeDownloadConfig => null;

  /// 公开 API：加载 Node.js 下载配置（从 rootBundle 读 version.json）
  ///
  /// **跨端统一**：三端都会读同一个 version.json，但只有 Windows 用得上。
  static Future<NodeDownloadConfig> loadNodeDownloadConfigStatic() async {
    final raw = await rootBundle
        .loadString('assets/nodejs-runtime/version.json');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return NodeDownloadConfig.fromJson(json);
  }

  /// 检查本地端口是否可达
  ///
  /// 用于 `handleSceneActive` 重连判断：spiderPort / managementPort 还活着没。
  Future<bool> checkLocalPort(int port) async {
    if (port <= 0) return false;
    final startAt = DateTime.now();
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 2),
      );
      socket.destroy();
      AppLog.instance.ports(
        'check_local_port_ok',
        ok: true,
        fields: {
          'port': port,
          'elapsedMs': DateTime.now().difference(startAt).inMilliseconds,
        },
      );
      return true;
    } catch (e) {
      AppLog.instance.ports(
        'check_local_port_fail',
        ok: false,
        error: e.toString(),
        fields: {
          'port': port,
          'elapsedMs': DateTime.now().difference(startAt).inMilliseconds,
        },
      );
      return false;
    }
  }

  /// 真实 HTTP 探测 Node.js 源是否已加载
  ///
  /// **关键**：区别于 [checkLocalPort] 只用 Socket.connect 探测端口。
  /// iOS 后台冻结 Node.js 进程时，loopback 端口探测可能假阳性（OS 接受
  /// 新 TCP 连接但 Spider 服务实际不响应），导致 handleSceneActive 误判
  /// "端口通" 直接 return，错过 reload 源的时机。
  ///
  /// 用 dio 发真实 HTTP GET 到 mgmtServer 的 `/source/status` 端点
  /// （main.js 实现），验证返回 `{sourceLoaded:true, ...}` 才算
  /// Node.js 真的健康。
  ///
  /// **2026-07-08 修复端口错 bug**:
  /// 旧版 verifySpiderService(int spiderPort) 调 `http://127.0.0.1:9988/source/status`
  /// 永远 404, 因为 `/source/status` 是 **mgmtServer 端点**, 监听在
  /// managementPort (e.g. 52274), 不是 spiderPort (9988). spiderServer
  /// 是 catServerFactory 创建的, 路由由 source/index.js 注册, 不会暴露
  /// `/source/status`. 改用 managementPort 后 8ms 404 -> 8ms 200,
  /// 消除 10s 兜底 reload_no_new_port.
  /// 2s 超时避免锁屏切回时长时间卡住。
  Future<bool> verifySourceLoaded(int managementPort) async {
    if (managementPort <= 0) {
      AppLog.instance.verify('skip', port: managementPort, ok: false,
          error: 'managementPort <= 0');
      return false;
    }
    final startAt = DateTime.now();
    final url = 'http://127.0.0.1:$managementPort/source/status';
    AppLog.instance.http('GET', url, port: managementPort,
        caller: 'verifySourceLoaded');
    final dio = _localHttpDio;
    try {
      final resp = await dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      final elapsed = DateTime.now().difference(startAt).inMilliseconds;
      if (resp.statusCode != 200) {
        AppLog.instance.http('GET', url, port: managementPort,
            statusCode: resp.statusCode, elapsedMs: elapsed, ok: false,
            caller: 'verifySourceLoaded');
        AppLog.instance.verify('http_non_200', port: managementPort,
            statusCode: resp.statusCode, elapsedMs: elapsed, ok: false,
            error: 'HTTP ${resp.statusCode}');
        return false;
      }
      final body = resp.data ?? '';
      // main.js /source/status 返回 { sourceLoaded: sourceModule !== null, ... }
      var loaded = false;
      try {
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        loaded = decoded['sourceLoaded'] == true;
      } catch (_) {
        // 兼容异常格式，失败则视为未加载
        loaded = false;
      }
      AppLog.instance.http('GET', url, port: managementPort,
          statusCode: resp.statusCode, elapsedMs: elapsed, ok: true,
          caller: 'verifySourceLoaded');
      AppLog.instance.verify('parse', port: managementPort,
          statusCode: resp.statusCode, elapsedMs: elapsed,
          ok: loaded, body: body,
          fields: {'sourceLoaded': loaded});
      return loaded;
    } catch (e) {
      final elapsed = DateTime.now().difference(startAt).inMilliseconds;
      AppLog.instance.http('GET', url, port: managementPort,
          elapsedMs: elapsed, ok: false,
          error: e.toString(),
          caller: 'verifySourceLoaded');
      AppLog.instance.verify('exception', port: managementPort,
          elapsedMs: elapsed, ok: false, error: e.toString());
      return false;
    }
  }

  /// 真实 HTTP 探测 mgmtServer 是否健康
  ///
  /// 用于判断 Node.js 进程是否真的活着. iOS 后台过久 embed library
  /// 可能被 SIGKILL, 但 Swift 端 `_isRunning` 状态卡在 true, Dart
  /// 端 onNodeExit callback 不一定及时触发. **不能信 isRunning**,
  /// 必须发真实 HTTP 请求到 mgmtServer 的 /check 端点.
  Future<bool> verifyManagementPort(int port) async {
    if (port <= 0) {
      AppLog.instance.verify('skip', port: port, ok: false,
          error: 'port <= 0');
      return false;
    }
    final startAt = DateTime.now();
    final url = 'http://127.0.0.1:$port/check';
    AppLog.instance.http('GET', url, port: port,
        caller: 'verifyManagementPort');
    final dio = _localHttpDio;
    try {
      final resp = await dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      final elapsed = DateTime.now().difference(startAt).inMilliseconds;
      if (resp.statusCode != 200) {
        AppLog.instance.http('GET', url, port: port,
            statusCode: resp.statusCode, elapsedMs: elapsed, ok: false,
            caller: 'verifyManagementPort');
        AppLog.instance.verify('http_non_200', port: port,
            statusCode: resp.statusCode, elapsedMs: elapsed, ok: false,
            error: 'HTTP ${resp.statusCode}');
        return false;
      }
      final body = resp.data ?? '';
      // main.js /check 返回 { run: true, ready: isReady }
      // ready=true 表示 mgmtServer listen 完
      final ready = body.contains('"ready":true') ||
          body.contains('"ready": true');
      AppLog.instance.http('GET', url, port: port,
          statusCode: resp.statusCode, elapsedMs: elapsed, ok: true,
          caller: 'verifyManagementPort');
      AppLog.instance.verify('parse', port: port,
          statusCode: resp.statusCode, elapsedMs: elapsed,
          ok: ready, body: body, fields: {'ready': ready});
      return ready;
    } catch (e) {
      final elapsed = DateTime.now().difference(startAt).inMilliseconds;
      AppLog.instance.http('GET', url, port: port,
          elapsedMs: elapsed, ok: false,
          error: e.toString(),
          caller: 'verifyManagementPort');
      AppLog.instance.verify('exception', port: port,
          elapsedMs: elapsed, ok: false, error: e.toString());
      return false;
    }
  }

  Future<bool> reloadSourceViaManagementPort(int port) async {
    if (port <= 0) {
      AppLog.instance.reload('skip', port: port, ok: false,
          error: 'port <= 0');
      return false;
    }
    final startAt = DateTime.now();
    final url = 'http://127.0.0.1:$port/source/loadPath';
    try {
      final sourcePath =
          await _platform.getLastSourceCachePath() ??
              await getDocumentsSourcePath();
      AppLog.instance.reload('start', port: port,
          fields: {'sourcePath': sourcePath, 'url': url});
      final dio = _localHttpDio;
      final resp = await dio.post(
        url,
        data: {'path': sourcePath},
        options: Options(
          contentType: 'application/json',
          responseType: ResponseType.plain,
          // ⚠️ 必须放开校验：Node 在 loadScript 抛异常时回 500 + {"error":...}，
          //    默认 validateStatus 会直接抛 DioException，把真正的失败原因
          //    （require 失败 / start() 异常）整个丢掉，日志里只剩 "500"。
          validateStatus: (_) => true,
        ),
      );
      final code = resp.statusCode ?? 0;
      final ok = code < 400;
      String? detail;
      if (!ok) {
        detail = '${resp.data ?? ''}'.trim();
        if (detail.length > 400) detail = detail.substring(0, 400);
        // Node 还会把完整堆栈写进源目录的 load-error.txt，一并带出来
        final forensic = await _readNodeLoadForensic(sourcePath);
        if (forensic != null && forensic.isNotEmpty) {
          detail = '$detail | $forensic';
        }
        AppLog.instance.w('[NodeJS] /source/loadPath 失败($code): $detail');
      }
      final elapsed = DateTime.now().difference(startAt).inMilliseconds;
      AppLog.instance.http('POST', url, port: port,
          statusCode: code, elapsedMs: elapsed, ok: ok,
          caller: 'reloadSourceViaManagementPort');
      AppLog.instance.reload(ok ? 'ok' : 'fail', port: port,
          statusCode: code, elapsedMs: elapsed, ok: ok,
          error: ok ? null : detail);
      return ok;
    } catch (e) {
      final elapsed = DateTime.now().difference(startAt).inMilliseconds;
      AppLog.instance.http('POST', url, port: port,
          elapsedMs: elapsed, ok: false,
          error: e.toString(),
          caller: 'reloadSourceViaManagementPort');
      AppLog.instance.reload('exception', port: port,
          elapsedMs: elapsed, ok: false, error: e.toString());
      return false;
    }
  }

  /// 读取 Node 在 require / start 失败时写下的取证文件（只取 error= 行）。
  Future<String?> _readNodeLoadForensic(String sourcePath) async {
    for (final name in const ['load-error.txt', 'loadPath-error.txt']) {
      try {
        final f = File('$sourcePath/$name');
        if (!await f.exists()) continue;
        final text = (await f.readAsString()).trim();
        if (text.isEmpty) continue;
        final errLine = text
            .split('\n')
            .firstWhere((l) => l.startsWith('error='), orElse: () => '');
        final body = errLine.isNotEmpty ? errLine.substring(6) : text;
        // 读到了就删掉，避免下次被旧现场误导
        try {
          await f.delete();
        } catch (_) {}
        return body.length > 500 ? body.substring(0, 500) : body;
      } catch (_) {}
    }
    return null;
  }

  /// 强制重新下载并载入 Node 源（用于 reload 500 的自愈）。
  ///
  /// 为什么需要：`/source/loadPath` 500 说明缓存目录里的 `index.js` 本身
  /// require 失败 / `start()` 抛异常（文件损坏、依赖缺失）。光重试 loadPath
  /// 永远失败；把缓存删掉让 `loadSource(url)` 走完整下载分支才有机会恢复。
  Future<(bool success, String? message)> redownloadSource(String url) async {
    if (url.trim().isEmpty) return (false, '源地址为空，无法重新下载');
    try {
      final path = await _platform.getLastSourceCachePath();
      if (path != null && path.isNotEmpty) {
        for (final name in const [
          'index.js',
          'index.js.md5',
          'index.config.js',
          'load-error.txt',
          'loadPath-error.txt',
        ]) {
          try {
            final f = File('$path/$name');
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      }
      AppLog.instance.log('[NodeJS] 重新下载源: $url');
      return await _platform.loadSource(url);
    } catch (e) {
      AppLog.instance.w('[NodeJS] 重新下载源失败: $e');
      return (false, '$e');
    }
  }

  /// Windows 专用：检查 node.exe 是否就绪
  Future<bool> isNodeRuntimeInstalled() => _platform.isNodeRuntimeInstalled();

  /// Windows 专用：下载 + 解压 Node.js runtime
  /// iOS / Android 直接返回
  Future<void> downloadAndExtractNodeRuntime(
    NodeDownloadConfig cfg, {
    void Function(double progress)? onProgress,
  }) =>
      _platform.downloadAndExtractNodeRuntime(
        cfg,
        onProgress: onProgress,
      );

  // ============================================================
  // 本地 HTTP 服务器（跨端统一用 dart:io）
  // ============================================================

  /// 启动本地 HTTP 服务器接收 Node.js 通知
  Future<bool> _startLocalWebServer() async {
    final startAt = DateTime.now();
    AppLog.instance.nodejs('http_server_start');
    try {
      _httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _nativeServerPort = _httpServer!.port;
      AppLog.instance.nodejs('http_server_ok', elapsedMs:
          DateTime.now().difference(startAt).inMilliseconds, fields: {
        'port': _nativeServerPort,
      });
      AppLog.instance.nodejs('see_details');

      _httpServer!.listen((HttpRequest request) {
        _handleRequest(request);
      });
      return true;
    } catch (e) {
      AppLog.instance.nodejs('http_server_fail',
          elapsedMs: DateTime.now().difference(startAt).inMilliseconds,
          ok: false, error: e.toString());
      AppLog.instance.nodejs('see_details');
      return false;
    }
  }

  void _stopHttpServer() {
    if (_httpServer == null && _nativeServerPort == 0) {
      AppLog.instance.nodejs('http_server_stop_skip',
          fields: {'reason': 'already stopped'});
      return;
    }
    AppLog.instance.nodejs('http_server_stop', fields: {
      'beforePort': _nativeServerPort,
    });
    _httpServer?.close(force: true);
    _httpServer = null;
    _nativeServerPort = 0;
    AppLog.instance.nodejs('http_server_stopped');
  }

  void _handleRequest(HttpRequest request) {
    final path = request.uri.path;
    final query = request.uri.queryParameters;
    // 本地回环鉴权：优先 header，query 兼容旧版（勿把 token 打进日志）
    final token = request.headers.value('x-auth-token') ??
        query['token'] ??
        '';
    if (token != _localAuthToken) {
      AppLog.instance.ports('http_request_rejected', ok: false, fields: {
        'path': path,
        'reason': 'bad_token',
      });
      request.response
        ..statusCode = HttpStatus.forbidden
        ..close();
      return;
    }
    final remotePort = request.connectionInfo?.remotePort ?? 0;
    final receivedAt = DateTime.now();
    final safeQuery = Map<String, String>.from(query)..remove('token');

    AppLog.instance.ports('http_request_in', fields: {
      'method': request.method,
      'path': path,
      'query': safeQuery.toString(),
      'remotePort': remotePort,
      'remoteAddress': request.connectionInfo?.remoteAddress.address,
    });

    if (path == '/onCatPawOpenPort' && request.method == 'GET') {
      final portStr = query['port'];
      final typeStr = query['type'] ?? 'spider';
      if (portStr != null) {
        final newPort = int.tryParse(portStr) ?? 0;
        final oldSpider = _platform.spiderPort;
        final oldMgmt = _platform.managementPort;
        AppLog.instance.ports('onCatPawOpenPort_in', fields: {
          'newPort': newPort,
          'type': typeStr,
          'oldSpider': oldSpider,
          'oldMgmt': oldMgmt,
        });
        _platform.onPortReceived(newPort, typeStr);
        AppLog.instance.ports('onCatPawOpenPort_done', fields: {
          'newPort': newPort,
          'type': typeStr,
          'afterSpider': _platform.spiderPort,
          'afterMgmt': _platform.managementPort,
          'elapsedMs': DateTime.now().difference(receivedAt).inMilliseconds,
        });
      }
      request.response
        ..write('OK')
        ..close();
    } else if (path == '/onMessage' && request.method == 'POST') {
      final contentLength = request.contentLength;
      AppLog.instance.ports('onMessage_in', fields: {
        'contentLength': contentLength,
      });
      if (contentLength > 0 && contentLength <= 1024 * 1024) {
        final builder = BytesBuilder();
        request.listen(
          (data) => builder.add(data),
          onDone: () {
            try {
              final body = utf8.decode(builder.toBytes());
              final json = jsonDecode(body) as Map<String, dynamic>;
              final message = json['message'] as String?;
              AppLog.instance.ports('onMessage_done', fields: {
                'message': message,
                'elapsedMs': DateTime.now().difference(receivedAt).inMilliseconds,
              });
              if (message != null) {
                _platform.onMessage(message);
              }
            } catch (e) {
              AppLog.instance.ports('onMessage_parse_fail',
                  ok: false, error: e.toString());
              AppLog.instance.nodejs('see_details');
            }
            request.response
              ..write('OK')
              ..close();
          },
          onError: (e) {
            AppLog.instance.ports('onMessage_read_fail',
                ok: false, error: e.toString());
            AppLog.instance.nodejs('see_details');
            request.response
              ..statusCode = HttpStatus.badRequest
              ..close();
          },
        );
      } else {
        AppLog.instance.ports('onMessage_skip',
            fields: {'reason': 'contentLength=$contentLength 不在范围'});
        request.response
          ..write('OK')
          ..close();
      }
    } else if (path == '/hiker/webview' && request.method == 'POST') {
      // 「海阔」模块的 **WebView 抓页桥**（Phase 2）：
      // Node 侧规则要开一个**真 WebView** 打开页面、等 JS 跑完再回传 DOM
      // （对应 assets/nodejs-project/src/hiker_engine.js 的
      //   fetchCodeByWebView → NeedWebView → 回环调用）。
      //
      // 为什么要做成**可空回调**而不是直接 import 海阔模块：这个回环服务器是
      // **基础设施**，海阔是可插拔模块 —— 两者只通过这一个钩子耦合；
      // 模块没启用时这里直接回 501，不新增任何硬依赖。
      final fetcher = webViewFetcher;
      // 体积上限：与 /onMessage 同样防"超大 body 把内存顶爆"
      // （正常请求体只有 url/checkJs/headers，几 KB 而已）
      if (request.contentLength > 1024 * 1024) {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..close();
        return;
      }
      final builder = BytesBuilder();
      request.listen(
        (data) => builder.add(data),
        onDone: () async {
          Future<void> reply(Map<String, dynamic> body,
              {int code = HttpStatus.ok}) async {
            request.response
              ..statusCode = code
              ..headers.contentType =
                  ContentType('application', 'json', charset: 'utf-8')
              ..write(jsonEncode(body))
              ..close();
          }

          if (fetcher == null) {
            await reply({'ok': false, 'error': '海阔模块未就绪（WebView 桥未注册）'},
                code: HttpStatus.notImplemented);
            return;
          }
          try {
            final raw = utf8.decode(builder.toBytes());
            final req = raw.trim().isEmpty
                ? <String, dynamic>{}
                : Map<String, dynamic>.from(jsonDecode(raw) as Map);
            final url = (req['url'] ?? '').toString();
            if (url.isEmpty) {
              await reply({'ok': false, 'error': '缺少 url'},
                  code: HttpStatus.badRequest);
              return;
            }
            final r = await fetcher(url, req);
            await reply(r);
          } catch (e) {
            await reply({'ok': false, 'error': e.toString()},
                code: HttpStatus.internalServerError);
          }
        },
        onError: (e) {
          request.response
            ..statusCode = HttpStatus.badRequest
            ..close();
        },
      );
    } else {
      AppLog.instance.ports('http_request_unknown', fields: {
        'method': request.method,
        'path': path,
      });
      request.response
        ..statusCode = HttpStatus.notFound
        ..close();
    }
  }
}

/// 公开版本，供 UI 层访问下载配置
///
/// Windows 端使用。其他端直接返回 Windows 端的 version.json（但用不上）
Future<NodeDownloadConfig> loadNodeDownloadConfigPublic() async {
  final raw = await rootBundle
      .loadString('assets/nodejs-runtime/version.json');
  final json = jsonDecode(raw) as Map<String, dynamic>;
  return NodeDownloadConfig.fromJson(json);
}
