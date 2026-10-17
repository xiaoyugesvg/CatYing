// lib/services/nodejs_platform_ios.dart
//
// iOS 端 Node.js 实现
// -----------------------------------------------------------------------------
// 通过 platform channel 调 Swift 端 → Swift 端嵌入 NodeMobile.xcframework
//   - 启动：`NodeMobile.start(["node", "main.js", "--native-port", port])`
//   - 停止：调 `node_exit`（NodeMobile 提供）或让进程自然结束
//   - 状态：Swift 端通过 `channel.invokeMethod` 推回 Dart
//
// **运行时不需要下载**：
//   - NodeMobile.xcframework 嵌进 Runner.app
//   - main.js 嵌进 Runner.app/nodejs-project/main.js（workflow 做）
//   - 用户源写到 <Documents>/nodejs-project/src/source/
//
// **HTTP server 还在 Dart 端**：
//   Node.js 通过 `--native-port` 拿到端口，回调 `GET /onCatPawOpenPort` 通知 Dart
//   与 Windows 端共用同一套 dart:io HttpServer

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';
import 'player_prefs.dart';
import 'nodejs_platform.dart';
import '../reading/services/settings_service.dart';

class IOSNodeJSPlatform implements NodeJSPlatform {
  IOSNodeJSPlatform({
    required this.onNodeReadyChanged,
    required this.onManagementPortChanged,
    required this.onSpiderPortChanged,
  });

  final ValueNotifier<bool> onNodeReadyChanged;
  final ValueNotifier<int> onManagementPortChanged;
  final ValueNotifier<int> onSpiderPortChanged;

  /// iOS native platform channel
  /// - 在 Swift 端 [NodeJSBridge] 注册同名 channel
  /// - Method: startNodeJS, stopNodeJS, getStatus
  /// - Swift → Dart callback: onNodeExit, onNodeReady
  static const MethodChannel _channel =
      MethodChannel('com.tvbox/flutter/nodejs');

  // 状态（Dart 端自己维护，HTTP server 收通知时更新）
  bool _isRunning = false;
  bool _isNodeReady = false;

  /// 本地通知鉴权 token（由 NodeJSManager 注入）
  String authToken = '';
  int _nativeServerPort = 0;
  int _managementPort = 0;
  int _spiderPort = 0;

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
  ));

  // ============================================================
  // 带凭据的源地址（HTTP Basic）支持
  // ============================================================

  /// 全局代理（供 Node 引擎注入）。开关关/地址非法 → 空串（引擎直连）。
  static String _globalProxyForNode() {
    final s = SettingsService();
    if (!s.globalProxyEnabled) return '';
    return s.globalProxy.trim();
  }

  /// 取出 URL 里的 `user:pass@` 并生成 Basic 认证头。
  ///
  /// **为什么必须这么做**：订阅型源地址常写成
  /// `https://user:token@host/.../index.js`。但 Dart 的 HttpClient 会**丢弃**
  /// URL 中的 userinfo，Dio 也不会自动把它转成 `Authorization` 头
  /// （实测：requests headers 为空）。结果是服务端返回 401 → 下载静默失败
  /// → `index.js` 永远不存在 → Node 的 `/config` 拿不到 `video.sites`
  /// → `homeSourceBean` 恒为 null → **首页永久空白且没有任何错误提示**。
  ///
  /// 这里把凭据从 URL 剥离并转成标准 Basic 头，同时返回干净的 URL。
  static ({String url, Map<String, String> headers}) _authSplit(String rawUrl) {
    try {
      final uri = Uri.parse(rawUrl);
      final userInfo = uri.userInfo;
      if (userInfo.isEmpty) {
        return (url: rawUrl, headers: const <String, String>{});
      }
      final cleanUrl = uri.replace(userInfo: '').toString();
      final token = base64Encode(utf8.encode(userInfo));
      return (
        url: cleanUrl,
        headers: <String, String>{'Authorization': 'Basic $token'},
      );
    } catch (_) {
      return (url: rawUrl, headers: const <String, String>{});
    }
  }

  /// 组装带鉴权头的请求选项
  static Options _opts(
    Map<String, String> headers, {
    required ResponseType type,
  }) {
    return Options(
      responseType: type,
      headers: headers.isEmpty ? null : headers,
    );
  }

  /// 取文本；失败/非 200 返回 null（md5 只是校验用，拿不到不该影响主流程）。
  Future<String?> _tryGetText(String url, Map<String, String> headers) async {
    try {
      final r = await _dio.get<String>(
        url,
        options: _opts(headers, type: ResponseType.plain),
      );
      return r.statusCode == 200 ? r.data : null;
    } on DioException {
      return null;
    }
  }

  /// 取字节；失败/非 200 返回 null（index.config.js 缺失有默认兜底）。
  Future<List<int>?> _tryGetBytes(String url, Map<String, String> headers) async {
    try {
      final r = await _dio.get<List<int>>(
        url,
        options: _opts(headers, type: ResponseType.bytes),
      );
      return r.statusCode == 200 ? r.data : null;
    } on DioException {
      return null;
    }
  }

  /// 源文件最小有效体积。真实的 catvod 源打包后是几百 KB，
  /// 小于这个值基本可以断定是空文件或 HTML 错误页（401/404 页面）。
  static const int _minValidSourceBytes = 1024;

  @override
  bool get isRunning => _isRunning;
  @override
  bool get isNodeReady => _isNodeReady;
  @override
  int get nativeServerPort => _nativeServerPort;
  @override
  int get managementPort => _managementPort;
  @override
  int get spiderPort => _spiderPort;

  /// 初始化：注册 Swift → Dart callback
  void initialize() {
    _channel.setMethodCallHandler((MethodCall call) async {
      try {
        switch (call.method) {
          case 'onNodeExit':
            final code = call.arguments is int
                ? call.arguments as int
                : (call.arguments is Map ? call.arguments['code'] as int? : null);
            AppLog.instance.log('[IOSNodeJS] Swift 通知: Node.js 退出，code=$code');
            // **关键**：iOS 后台/锁屏过久 embed library 会被系统回收,
            // 此时必须清掉旧端口, 否则 AppState.handleSceneActive 拿旧
            // spiderPort/managementPort 去探测, connection refused 但
            // nodeIsRunning=true 还以为进程在, 错过重启时机.
            _isRunning = false;
            _isNodeReady = false;
            _spiderPort = 0;
            _managementPort = 0;
            onNodeReadyChanged.value = false;
            onManagementPortChanged.value = 0;
            onSpiderPortChanged.value = 0;
            return null;
          case 'onNodeReady':
            AppLog.instance.log('[IOSNodeJS] Swift 通知: Node.js ready');
            AppLog.instance.log('IOSNodeJS onNodeReady 回调');
            _isNodeReady = true;
            onNodeReadyChanged.value = true;
            return null;
          case 'onError':
            final msg = call.arguments is String
                ? call.arguments
                : call.arguments.toString();
            AppLog.instance.log('[IOSNodeJS] Swift 错误: $msg');
            return null;
          default:
            AppLog.instance.log('[IOSNodeJS] 未知 method call from Swift: ${call.method}');
            return null;
        }
      } catch (e, st) {
        AppLog.instance.log('[IOSNodeJS] 处理 Swift callback 异常: $e\n$st');
        return null;
      }
    });
  }

  // ============================================================
  // 路径
  // ============================================================

  @override
  Future<String> getDocumentsSourcePath() async {
    // iOS 端: <Documents>/nodejs-project/src/source
    // 与 tvbox-Swift-main 保持一致
    final docs = await getApplicationDocumentsDirectory();
    final sourcePath =
        '${docs.path}/nodejs-project/src/source';
    final dir = Directory(sourcePath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return sourcePath;
  }

  // ============================================================
  // 启动 / 停止
  // ============================================================

  @override
  Future<bool> startNodeJS() async {
    AppLog.instance.log('IOSNodeJS startNodeJS 开始 (isRunning=$_isRunning)');
    if (_isRunning) return true;

    _isNodeReady = false;
    _spiderPort = 0;
    _managementPort = 0;
    onNodeReadyChanged.value = false;
    onManagementPortChanged.value = 0;
    onSpiderPortChanged.value = 0;

    final sourcePath = await getDocumentsSourcePath();
    final nativePort = _nativeServerPort;

    AppLog.instance.log(
        'IOSNodeJS 调 Swift 启动 Node.js, nativePort=$nativePort, sourcePath=$sourcePath');
    AppLog.instance.log('[IOSNodeJS] 调 Swift 启动 Node.js, nativePort=$nativePort, '
        'sourcePath=$sourcePath');

    try {
      // 调 Swift 端启动
      // Swift 端会:
      //   1. 在 mainBundle 找 nodejs-project/main.js
      //   2. 启动 GCDWebServer（或信任 Dart 端 HTTP server）
      //   3. setenv(NODE_PATH, sourcePath)
      //   4. node_start(["node", "--security-revert=CVE-2023-46809",
      //                  "main.js", "--native-port", "$nativePort"])
      // 全局代理 → Swift 在 node_start 前 setenv 注入 Node 引擎
      // （书源 JS 引擎外站请求只认标准代理环境变量，不注入则 iOS 上
      //   开全局代理对书源无效，表现为大量 500/超时）
      final proxy = _globalProxyForNode();
      final result = await _channel.invokeMethod<bool>('startNodeJS', {
        'nativePort': nativePort,
        'sourcePath': sourcePath,
        'authToken': authToken,
        'keepAlive': PlayerPrefs.instance.silentKeepAlive.value,
        'proxy': proxy,
      });
      AppLog.instance.log('IOSNodeJS Swift invokeMethod 返回: $result');
      if (result == true) {
        _isRunning = true;
        AppLog.instance.log('[IOSNodeJS] Swift 启动成功');
        AppLog.instance.log('IOSNodeJS Swift 启动成功, 等 waitForNodeReady');
        final ready = await waitForNodeReady();
        AppLog.instance.log('IOSNodeJS waitForNodeReady 返回: $ready');
        return ready;
      }
      AppLog.instance.log('[IOSNodeJS] Swift 启动失败');
      AppLog.instance.log('IOSNodeJS Swift 启动失败');
      return false;
    } on PlatformException catch (e) {
      AppLog.instance.log('[IOSNodeJS] startNodeJS PlatformException: ${e.code}/${e.message}');
      AppLog.instance.log('IOSNodeJS startNodeJS PlatformException: ${e.code}/${e.message}');
      return false;
    } catch (e, st) {
      AppLog.instance.log('[IOSNodeJS] startNodeJS 异常: $e');
      AppLog.instance.log('IOSNodeJS startNodeJS 异常: $e\n$st');
      return false;
    }
  }

  @override
  void stopNodeJS() {
    if (!_isRunning) return;
    _isRunning = false;
    _isNodeReady = false;
    _nativeServerPort = 0;
    _spiderPort = 0;
    _managementPort = 0;
    onNodeReadyChanged.value = false;
    onManagementPortChanged.value = 0;
    onSpiderPortChanged.value = 0;

    _channel.invokeMethod('stopNodeJS').catchError((e) {
      AppLog.instance.log('[IOSNodeJS] stopNodeJS 异常: $e');
      return null;
    });
    // 诚实日志：Swift 只清标志位，NodeMobile 无 node_exit，进程可能仍在
    AppLog.instance.log(
        '[IOSNodeJS] 已解绑 Node.js 状态（embed 进程未必退出，仅本端认为不可用）');
  }

  @override
  void forceResetRunningState() {
    _isRunning = false;
    _isNodeReady = false;
    _nativeServerPort = 0;
    _spiderPort = 0;
    _managementPort = 0;
    onNodeReadyChanged.value = false;
    onManagementPortChanged.value = 0;
    onSpiderPortChanged.value = 0;
    AppLog.instance.log('[IOSNodeJS] 强制重置运行状态');
  }

  // ============================================================
  // 状态同步（Dart 端 HTTP server 收到 Node.js 通知时调）
  // ============================================================

  /// HTTP server 收到 Node.js 的 `/onCatPawOpenPort?port=&type=` 时调用
  void onPortReceived(int port, String type) {
    AppLog.instance.log('[IOSNodeJS] 收到端口通知: $port, 类型: $type');
    AppLog.instance.log('IOSNodeJS onPortReceived: port=$port, type=$type');
    if (type == 'management') {
      _managementPort = port;
      onManagementPortChanged.value = port;
      // **iOS SIGKILL 修复**: 同步 mgmt port 给 Swift,
      // Swift 在 app 回前台时主动 ping /check 确认 Node.js 是否被 SIGKILL
      _channel.invokeMethod('setManagementPort', {'port': port}).catchError((e) {
        AppLog.instance.log('[IOSNodeJS] setManagementPort 异常: $e');
        return null;
      });
    } else {
      _spiderPort = port;
      onSpiderPortChanged.value = port;
    }
  }

  /// HTTP server 收到 Node.js 的 `/onMessage` 时调用
  void onMessage(String message) {
    AppLog.instance.log('[IOSNodeJS] 收到 Node.js 消息: $message');
    if (message == 'ready') {
      _isNodeReady = true;
      onNodeReadyChanged.value = true;
    }
  }

  /// 由 NodeJSManager 顶层 HTTP server 启动后设置
  void setNativeServerPort(int port) {
    _nativeServerPort = port;
  }

  @override
  Future<bool> waitForNodeReady() async {
    if (_isNodeReady) return true;
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      if (_isNodeReady) return true;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    AppLog.instance.log('[IOSNodeJS] 等待 Node.js 就绪超时');
    return _isNodeReady;
  }

  @override
  Future<bool> waitForSpiderPort() async {
    if (_spiderPort > 0) return true;
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (DateTime.now().isBefore(deadline)) {
      if (_spiderPort > 0) return true;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    AppLog.instance.log('[IOSNodeJS] 等待 Spider 端口超时');
    return _spiderPort > 0;
  }

  // ============================================================
  // 源管理
  // ============================================================

  @override
  Future<(bool success, String? message)> loadSource(
      String urlString) async {
    if (urlString.isEmpty) return (false, 'URL 为空');

    var normalizedUrl = urlString;
    if (normalizedUrl.endsWith('.js.md5')) {
      normalizedUrl = normalizedUrl.substring(0, normalizedUrl.length - 4);
      AppLog.instance.log('[IOSNodeJS] 规范化 URL（移除 .md5 后缀）: $normalizedUrl');
    }

    final uri = Uri.tryParse(normalizedUrl);
    if (uri == null) return (false, '无效的 URL');
    // 远程源安全：优先 HTTPS；http 明文可被中间人替换 JS（MD5 同通道也能被改）
    // http 源仍可用（很多自建/局域网源是 http），仅告警不拦截
    if (uri.scheme == 'http') {
      AppLog.instance.log('[IOSNodeJS] 警告：http 明文源（建议 https）$normalizedUrl');
    }
    if (uri.scheme != 'https' && uri.scheme != 'http' && uri.scheme != 'file') {
      return (false, '仅支持 http(s) / 本地路径');
    }

    // 每次前台开始加载源就递增代次号 → 在飞的后台刷新会被判定作废
    // （见 _sourceLoadGeneration 的说明）
    _sourceLoadGeneration++;

    final sourcePath = await getDocumentsSourcePath();
    final indexJSPath = '$sourcePath/index.js';
    final indexMd5Path = '$sourcePath/index.js.md5';
    final configJSPath = '$sourcePath/index.config.js';

    // 只判断「文件存在」是不够的：下载失败时（例如订阅源返回 401）
    // 可能写入一个空文件或 HTML 错误页，此后每次启动都会认为「已缓存」
    // 而直接复用坏文件 → 源永远加载不出来且看起来是"缓存命中"。
    // 这里加一个有效性检查：体积过小一律视为无效，强制重新下载。
    var localJSExists = false;
    if (await File(indexJSPath).exists()) {
      final len = await File(indexJSPath).length();
      localJSExists = len >= _minValidSourceBytes;
      if (!localJSExists) {
        AppLog.instance.log(
            '[IOSNodeJS] 本地源文件无效（$len 字节 < $_minValidSourceBytes），强制重新下载');
        try {
          await File(indexJSPath).delete();
        } catch (_) {}
      }
    }
    final localMd5Exists = await File(indexMd5Path).exists();
    AppLog.instance.log('[IOSNodeJS] 缓存检查: index.js 有效=$localJSExists, '
        'index.js.md5 存在=$localMd5Exists');

    if (localJSExists) {
      // **本地缓存优先 (2026-09-27)**：源文件已存在就直接使用, 不等远程 MD5
      // 请求（避免每次启动都显示"正在下载源文件..."）。远程 MD5 校验改为
      // 后台异步执行：若发现源已更新, 后台重新下载并替换。
      AppLog.instance.log('[IOSNodeJS] 本地缓存源存在, 直接使用（后台异步校验更新）');
      _refreshSourceInBackground(normalizedUrl, sourcePath);
      return await _sendLoadCommandToNodeJS(sourcePath);
    }

    try {
      // 凭据订阅源：把 URL 里的 user:pass@ 转成 Basic 头（HttpClient 会丢弃 userinfo）
      final jsAuth = _authSplit(normalizedUrl);
      final configAuth = _authSplit(
          normalizedUrl.replaceAll('/index.js', '/index.config.js'));

      // 🔴 2026-10-14（用户：「接口配置下载源文件好慢」）：三个请求**并发**。
      //   主脚本是长杆（几百 KB ~ 几 MB），而 `.md5` 与 `index.config.js`
      //   都只有几十字节 —— 原来三者**串行**，等于在主脚本下完之后又白等
      //   两个完整往返（首下源文件时最明显，慢网上每次多等 1~3 秒）。
      final jsFuture = _dio.get<List<int>>(
        jsAuth.url,
        options: _opts(jsAuth.headers, type: ResponseType.bytes),
      );
      final md5Future = _tryGetText('${jsAuth.url}.md5', jsAuth.headers);
      final configFuture = _tryGetBytes(configAuth.url, configAuth.headers);

      final jsResponse = await jsFuture;
      final md5Data = (await md5Future)?.trim();
      final configData = await configFuture;

      if (jsResponse.statusCode == 200 && jsResponse.data != null) {
        final jsData = jsResponse.data!;
        AppLog.instance.log('[IOSNodeJS] 主源文件已下载，大小: ${jsData.length} 字节');

        if (md5Data != null && md5Data.isNotEmpty) {
          final actualMd5 = md5.convert(jsData).toString();
          if (actualMd5 != md5Data) return (false, 'MD5 校验失败');
        }

        final sourceDir = Directory(sourcePath);
        if (!await sourceDir.exists()) await sourceDir.create(recursive: true);
        await File(indexJSPath).writeAsBytes(jsData);
        if (md5Data != null && md5Data.isNotEmpty) {
          await File(indexMd5Path).writeAsString(md5Data);
        }
        if (configData != null) {
          await File(configJSPath).writeAsBytes(configData);
        } else {
          await File(configJSPath)
              .writeAsString('module.exports = { color: [] };');
        }

        return await _sendLoadCommandToNodeJS(sourcePath);
      }
      return (false, '下载源文件失败 (状态码: ${jsResponse.statusCode})');
    } on DioException catch (e) {
      return (false, '下载源文件失败: ${e.message}');
    }
  }

  @override
  Future<bool> deleteSource() async {
    final sourcePath = await getDocumentsSourcePath();
    final dir = Directory(sourcePath);
    if (await dir.exists()) {
      try {
        await dir.delete(recursive: true);
      } catch (e) {
        return false;
      }
    }
    // 🔴 只在 Node **没在跑**时才清零端口（用户 2026-10-14「常驻」审查）：
    //   iOS 上 NodeMobile 是 embed library，进程**关不掉**，清了文件它照样活着
    //   （脚本已经 require 进内存，照样能跑）。原来的无条件清零会让上层以为
    //   "Node 未就绪" ⇒ 下次用到时再调 `startNodeJS()` ⇒ **第二次 node_start**
    //   ⇒ 卡死在 V8 二次初始化（nodejs_manager.dart 里为此删过 reset 路径）。
    //   就"清理源文件缓存"这个动作而言：文件删掉即可，运行中的 Node 继续用内存里的
    //   脚本；真需要重新载入时 `loadSource` 会重新下载。
    if (!_isRunning) {
      _spiderPort = 0;
      onSpiderPortChanged.value = 0;
    }
    return true;
  }

  Future<(bool success, String? message)> _sendLoadCommandToNodeJS(
      String path) async {
    if (_managementPort <= 0) {
      return (false, 'Management 端口未就绪，请先启动 Node.js');
    }
    try {
      final response = await _dio.post(
        'http://127.0.0.1:$_managementPort/source/loadPath',
        data: {'path': path},
        options: Options(
          // 关键：mgmtServer 全端点校验 x-auth-token（main.js 的 nativeToken
          // 由 Swift 启动时通过 --native-token argv 注入）。loadPath 之前
          // 用无 token 的 _dio 发 → Node 403 拒绝 → 源永远加载不进 Node →
          // spider 端口永不出现 → 首页永久空白。这里补上与 Node 一致的 token。
          headers: {'x-auth-token': authToken},
          responseType: ResponseType.json,
          contentType: 'application/json',
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
          // 关键：Dio 默认对 4xx/5xx 抛异常，会让下面的 statusCode>=400 分支
          // 变成死代码，并且丢掉 Node 返回的错误详情（例如 403 白名单里的
          // allowedRoots / resolved 路径）。这里放开校验，自己解析 body。
          validateStatus: (_) => true,
        ),
      );
      final code = response.statusCode ?? 0;
      if (code >= 400) {
        // 优先取 Node 返回的 error 字段，便于定位（如 'path not allowed'）
        String detail = 'HTTP $code';
        final data = response.data;
        if (data is Map && data['error'] != null) {
          detail = data['error'].toString();
          if (data['resolved'] != null) {
            detail = '$detail（路径: ${data['resolved']}）';
          }
        }
        AppLog.instance
            .log('[IOSNodeJS] /source/loadPath 失败: $code $detail');
        return (false, '源加载被拒绝: $detail');
      }

      // 关键：Node 的 /source/loadPath 只要收到请求就回 200，
      // 但 loadScript 内部 require(index.js) 失败时异常被吞进 console.error，
      // 表现为「HTTP 200 但 spider 端口永不出现」——最难查的一类故障。
      // Node 侧已把现场写到源目录下的取证文件，这里读出来直接呈现给用户。
      final forensic = await _readLoadForensic(path);
      if (forensic != null) {
        AppLog.instance.log('[IOSNodeJS] 源加载取证: $forensic');
        return (false, '源文件加载失败: $forensic');
      }
      return (true, '源加载成功');
    } on DioException catch (e) {
      return (false, '加载请求失败: ${e.message}');
    }
  }

  /// 读取 Node 写入的源加载取证文件（load-error / loadPath-error）
  Future<String?> _readLoadForensic(String sourcePath) async {
    for (final name in const ['load-error.txt', 'loadPath-error.txt']) {
      try {
        final f = File('$sourcePath/$name');
        if (!await f.exists()) continue;
        final text = (await f.readAsString()).trim();
        if (text.isEmpty) continue;
        // 只取 error= 行，避免把整段环境信息塞进 UI
        final errLine = text
            .split('\n')
            .firstWhere((l) => l.startsWith('error='), orElse: () => '');
        if (errLine.isEmpty) continue;
        try {
          await f.delete();
        } catch (_) {}
        return errLine.substring(6).split('\n').first;
      } catch (_) {}
    }
    return null;
  }

  /// 后台异步刷新源文件：本地缓存存在时, 静默下载远程 MD5 比对,
  /// 发现源已更新则重新下载并替换本地缓存。不阻塞启动、不显示下载文案。
  /// 源加载代次号：**每次前台开始加载源就 +1**。
  ///
  /// 为什么需要（切源竞态，用户 2026-10-14 提的"洞 B"）：
  ///   本地缓存命中时，前台会顺手启动一个**后台刷新**（重新下载 index.js 并替换）。
  ///   如果这期间用户切到了别的源，那份后台下载完成时就会把**旧源的内容写进
  ///   index.js** —— 而 Node 里驻留的已经是新源 ⇒ 脚本与引擎不一致，
  ///   表现为「切了源但内容不对 / 半截文件」。
  /// ⇒ 后台任务记下发起时的号，**写文件之前**校验；不一致就整份丢弃。
  /// （同源并发写内容相同、无害，所以不需要额外加互斥锁。）
  static int _sourceLoadGeneration = 0;

  void _refreshSourceInBackground(String normalizedUrl, String sourcePath) {
    // 记下发起时的代次：期间只要有人开始加载新源，这个号就会变
    final gen = _sourceLoadGeneration;
    unawaited(_refreshSourceAsync(normalizedUrl, sourcePath, gen));
  }

  Future<void> _refreshSourceAsync(
      String normalizedUrl, String sourcePath, int gen) async {
    try {
      final indexJSPath = '$sourcePath/index.js';
      final indexMd5Path = '$sourcePath/index.js.md5';
      final configJSPath = '$sourcePath/index.config.js';

      // 远程 MD5（同样需要 Basic 凭据）
      final jsAuth = _authSplit(normalizedUrl);
      String? remoteMd5;
      try {
        final response = await _dio.get<String>(
          '${jsAuth.url}.md5',
          options: _opts(jsAuth.headers, type: ResponseType.plain),
        );
        if (response.statusCode == 200 && response.data != null) {
          remoteMd5 = response.data!.trim();
        }
      } on DioException catch (e) {
        AppLog.instance.log('[IOSNodeJS] 后台 MD5 获取失败: ${e.message}');
        return;
      }
      if (remoteMd5 == null || remoteMd5.isEmpty) return;

      // 本地 MD5
      if (!await File(indexMd5Path).exists()) {
        // 没有本地 MD5 记录 → 强制更新
      } else {
        final localMd5 = (await File(indexMd5Path).readAsString()).trim();
        if (localMd5 == remoteMd5) {
          AppLog.instance.log('[IOSNodeJS] 后台 MD5 匹配, 源无需更新');
          return;
        }
      }

      AppLog.instance.log('[IOSNodeJS] 后台检测到源已更新, 重新下载...');
      final jsResponse = await _dio.get<List<int>>(
        jsAuth.url,
        options: _opts(jsAuth.headers, type: ResponseType.bytes),
      );
      if (jsResponse.statusCode != 200 || jsResponse.data == null) return;
      final jsData = jsResponse.data!;

      // 校验下载内容 MD5
      final actualMd5 = md5.convert(jsData).toString();
      if (actualMd5 != remoteMd5) {
        AppLog.instance.log('[IOSNodeJS] 后台下载 MD5 校验失败, 丢弃');
        return;
      }

      // 🔴 写之前再校验一次代次号（见 _sourceLoadGeneration）：
      // 下载这段网络时间里用户可能已经切到别的源，这份内容就不能再写进去了，
      // 否则会把新源的脚本覆盖成旧源的。
      if (gen != _sourceLoadGeneration) {
        AppLog.instance.log('[IOSNodeJS] 后台刷新作废（下载期间已切源）');
        return;
      }

      // 写回缓存
      await File(indexJSPath).writeAsBytes(jsData);
      await File(indexMd5Path).writeAsString(remoteMd5);
      try {
        final configAuth = _authSplit(
            normalizedUrl.replaceAll('/index.js', '/index.config.js'));
        final configResponse = await _dio.get<List<int>>(
          configAuth.url,
          options: _opts(configAuth.headers, type: ResponseType.bytes),
        );
        if (configResponse.statusCode == 200 &&
            configResponse.data != null) {
          await File(configJSPath).writeAsBytes(configResponse.data!);
        }
      } on DioException catch (e) {
        AppLog.instance.log('[nodejs_platform_ios] swallowed: $e');
      }
      AppLog.instance.log('[IOSNodeJS] 后台源更新完成');
    } catch (e) {
      AppLog.instance.log('[IOSNodeJS] 后台源刷新异常: $e');
    }
  }

  // ============================================================
  // 运行时检查（iOS 永远 true）
  // ============================================================

  @override
  Future<bool> isNodeRuntimeInstalled() async {
    // iOS: NodeMobile.xcframework 嵌进 bundle，永远 true
    return true;
  }

  @override
  Future<void> downloadAndExtractNodeRuntime(
    NodeDownloadConfig cfg, {
    void Function(double progress)? onProgress,
  }) async {
    // iOS 不需要下载运行时
    if (onProgress != null) onProgress(1.0);
    return;
  }

  // ============================================================
  // 小程序 Node 后端（manifest.json 的 `node`）
  // ============================================================

  /// 让 Node 侧 require 小程序目录里的 `server/index.js` 并 listen。
  ///
  /// 返回 `http://127.0.0.1:<port>`；失败返回 null（具体原因看 Node 日志）。
  /// 走 management 端口，因为只有它知道 Node 进程的实时端口。
  @override
  Future<String?> startMiniAppService({
    required String appId,
    required String dir,
    String entry = 'server/index.js',
    String config = 'server/index.config.js',
  }) async {
    if (_managementPort <= 0) {
      AppLog.instance.log('[IOSNodeJS] 启动小程序 node 失败：management 端口未就绪');
      return null;
    }
    try {
      final r = await _dio.post<dynamic>(
        'http://127.0.0.1:$_managementPort/miniapp/start',
        data: {
          'appId': appId,
          'dir': dir,
          'entry': entry,
          'config': config,
        },
        options: Options(
          responseType: ResponseType.json,
          contentType: Headers.jsonContentType,
        ),
      );
      final m = r.data;
      if (m is Map && m['ok'] == true) {
        final url = (m['url'] ?? '').toString().trim();
        if (url.isNotEmpty) {
          AppLog.instance.log('[IOSNodeJS] 小程序 node 已启动：$appId → $url');
          return url;
        }
      }
      AppLog.instance.log('[IOSNodeJS] 小程序 node 启动失败：$m');
      return null;
    } catch (e) {
      AppLog.instance.log('[IOSNodeJS] /miniapp/start 失败: $e');
      return null;
    }
  }

  @override
  Future<void> stopMiniAppService(String appId) async {
    if (_managementPort <= 0) return;
    try {
      await _dio.post<dynamic>(
        'http://127.0.0.1:$_managementPort/miniapp/stop',
        data: {'appId': appId},
        options: Options(
          responseType: ResponseType.json,
          contentType: Headers.jsonContentType,
        ),
      );
    } catch (e) {
      // 页面已经在退出，停不掉不影响功能（下次 start 会复用/重启）
      AppLog.instance.log('[IOSNodeJS] /miniapp/stop 失败: $e');
    }
  }
}

/// 工具：从 url 解析 host（用于在 iOS 上传 source path 时的归一化）
class IOSNodeJSPlatformHelper {
  /// 从 path 提取文件名
  static String basename(String path) {
    return path.split(Platform.pathSeparator).last;
  }

  /// Node.js HTTP 响应解析
  static Map<String, dynamic> parseResponse(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }
}
