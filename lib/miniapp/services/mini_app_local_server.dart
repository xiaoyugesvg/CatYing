import 'dart:convert';
import 'dart:io';

import 'package:tvbox/miniapp/services/ant_bridge.dart';
import 'package:tvbox/services/app_log.dart';

/// 路径是否落在 [dirPath] 目录内（分隔符归一化后再比，防穿越）。
/// 与 `mini_app_web_page.dart` 的 `_withinDir` 同源逻辑，提出来共用。
bool isWithinDir(String path, String dirPath) {
  final p = path.replaceAll('\\', '/');
  var d = dirPath.replaceAll('\\', '/');
  if (!d.endsWith('/')) d = '$d/';
  return p.startsWith(d);
}

/// 本地小程序静态文件服务（仅 loopback）。
///
/// 参考 huoyi `renderer.dart` 的思路：本地安装的小程序不再用 `file://`
/// 加载，而是起一个**只在本机回环地址**监听的 HTTP 服务，页面 URL 变为
/// `http://127.0.0.1:<port>/<entry>`，两个收益：
///   1. **服务端注入**：响应 HTML 时把 ant 桥脚本直接插进 `<head>` ——
///      页面最早同步脚本就能拿到 `window.ant`；而 `file://` + onPageFinished
///      注入时，load 前跑的脚本拿不到引用（这是第三方裸 HTML 小程序
///      白屏/报 `ant is not defined` 的直接原因）；
///   2. **同源 HTTP**：相对资源与 XHR 走正常 HTTP，不受 `file://`
///      CORS/同源限制。
///
/// 安全：只监听 127.0.0.1、只服务 [root] 目录内文件（路径穿越一律 403）、
/// 端口随机（0 → 内核分配），页面外无从访问。
class MiniAppLocalServer {
  MiniAppLocalServer._();

  /// 一个小程序（appId）对应一个服务实例；页面刷新/内部跳转复用
  static final Map<String, MiniAppLocalServer> _instances = {};

  static MiniAppLocalServer? forApp(String appId) => _instances[appId];

  HttpServer? _server;
  late String _root;
  int _port = 0;

  int get port => _port;

  /// 页面基址（`http://127.0.0.1:<port>/`）
  String get baseUrl => 'http://127.0.0.1:$_port/';

  /// 启动（或复用）某个小程序的本地服务。
  static Future<MiniAppLocalServer> start({
    required String appId,
    required String root,
  }) async {
    final existing = _instances[appId];
    if (existing != null) return existing;
    final server = MiniAppLocalServer._();
    await server._bind(root);
    _instances[appId] = server;
    AppLog.instance.log('[MiniAppLocal] $appId → ${server.baseUrl}（root=$root）');
    return server;
  }

  /// 停止某个小程序的本地服务（页面关闭时调用，释放端口）。
  static Future<void> stop(String appId) async {
    final server = _instances.remove(appId);
    if (server != null) {
      await server._close();
    }
  }

  Future<void> _bind(String root) async {
    _root = root.replaceAll('\\', '/');
    if (!_root.endsWith('/')) _root = '$_root/';
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
    _server!.listen(_handle, onError: (Object e, StackTrace st) {
      AppLog.instance.log('[MiniAppLocal] 服务异常: $e');
    });
  }

  Future<void> _close() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      // ── 路径规范化 + 防穿越 ─────────────────────────────
      var rel = request.uri.path;
      if (rel.startsWith('/')) rel = rel.substring(1);
      if (rel.isEmpty) rel = 'index.html';
      final target = Uri.file('$_root$rel').normalizePath().toFilePath();
      if (!isWithinDir(target, _root)) {
        _respondText(request, HttpStatus.forbidden, 'forbidden');
        return;
      }

      var file = File(target);
      var contentType = _mimeOf(rel);

      // ── 目录请求 / SPA 子路径：回 index.html ─────────────
      // 仅当「路径不是文件（无扩展名或指向目录）」时才回退，避免把
      // 真 404 的资源请求也吞掉。
      final looksLikeFile = rel.split('/').last.contains('.');
      final isDir = await Directory(target).exists();
      if (isDir || (!looksLikeFile && !await file.exists())) {
        file = File('$_root${rel.endsWith('/') ? rel : '$rel/'}index.html');
        rel = '${rel.endsWith('/') ? rel : '$rel/'}index.html';
        contentType = _mimeOf(rel);
      }

      if (!await file.exists()) {
        _respondText(request, HttpStatus.notFound, 'not found');
        return;
      }
      final bytes = await file.readAsBytes();

      // ── 服务端注入 ant 桥（仅 HTML）──────────────────────
      // 三级回退（参考 huoyi renderer.dart）：<head> → <html> → 文首。
      // 脚本带 `__antInjected` 守卫，与 onPageFinished 补注入叠加无害。
      if (contentType.startsWith('text/html')) {
        final body = utf8.decode(bytes, allowMalformed: true);
        final injected = _injectBootstrap(body);
        _respond(
          request,
          HttpStatus.ok,
          utf8.encode(injected),
          contentType: 'text/html; charset=utf-8',
          extraHeaders: {'Cache-Control': 'no-store'},
        );
        return;
      }

      _respond(
        request,
        HttpStatus.ok,
        bytes,
        contentType: contentType,
        extraHeaders: {'Cache-Control': 'no-store'},
      );
    } catch (e) {
      AppLog.instance.log('[MiniAppLocal] 请求处理失败 ${request.uri.path}: $e');
      try {
        _respondText(request, HttpStatus.internalServerError, 'server error');
      } catch (_) {}
    }
  }

  /// 把 ant 桥 bootstrap 插进 HTML（`<head>` → `<html>` → 文首三级回退）
  static String _injectBootstrap(String html) {
    const script = '<script>\n${AntBridge.injectScript}\n</script>';
    final head = html.indexOf('<head');
    if (head >= 0) {
      final end = html.indexOf('>', head);
      if (end >= 0) {
        return html.replaceRange(end + 1, end + 1, script);
      }
    }
    final htmlTag = html.indexOf('<html');
    if (htmlTag >= 0) {
      final end = html.indexOf('>', htmlTag);
      if (end >= 0) {
        return html.replaceRange(end + 1, end + 1, script);
      }
    }
    return '$script\n$html';
  }

  static void _respondText(
    HttpRequest request,
    int status,
    String text,
  ) {
    _respond(
      request,
      status,
      utf8.encode(text),
      contentType: 'text/plain; charset=utf-8',
    );
  }

  static void _respond(
    HttpRequest request,
    int status,
    List<int> body, {
    String? contentType,
    Map<String, String> extraHeaders = const {},
  }) {
    final response = request.response
      ..statusCode = status
      ..headers.contentType = ContentType.parse(
        contentType ?? 'application/octet-stream',
      );
    extraHeaders.forEach(response.headers.set);
    response
      ..add(body)
      ..close();
  }

  static String _mimeOf(String rel) {
    final name = rel.toLowerCase().split('?').first;
    final dot = name.lastIndexOf('.');
    if (dot < 0) return 'application/octet-stream';
    return switch (name.substring(dot)) {
      '.html' || '.htm' => 'text/html',
      '.js' || '.mjs' => 'application/javascript',
      '.css' => 'text/css',
      '.json' => 'application/json',
      '.png' => 'image/png',
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.gif' => 'image/gif',
      '.webp' => 'image/webp',
      '.svg' => 'image/svg+xml',
      '.ico' => 'image/x-icon',
      '.bmp' => 'image/bmp',
      '.avif' => 'image/avif',
      '.woff' => 'font/woff',
      '.woff2' => 'font/woff2',
      '.ttf' => 'font/ttf',
      '.otf' => 'font/otf',
      '.eot' => 'application/vnd.ms-fontobject',
      '.mp3' => 'audio/mpeg',
      '.wav' => 'audio/wav',
      '.ogg' => 'audio/ogg',
      '.m4a' => 'audio/mp4',
      '.mp4' => 'video/mp4',
      '.webm' => 'video/webm',
      '.m3u8' => 'application/vnd.apple.mpegurl',
      '.txt' => 'text/plain; charset=utf-8',
      '.xml' => 'application/xml',
      '.pdf' => 'application/pdf',
      '.zip' => 'application/zip',
      _ => 'application/octet-stream',
    };
  }
}
