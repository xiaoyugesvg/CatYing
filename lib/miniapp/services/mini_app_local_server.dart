import 'dart:convert';
import 'dart:io';

import 'package:tvbox/miniapp/services/ant_bridge.dart';
import 'package:tvbox/services/app_log.dart';

/// 路径是否落在 [dirPath] 目录内（分隔符归一化 + `..` 解析后再比，防穿越）。
/// 与 `mini_app_web_page.dart` 的 `_withinDir` 同源逻辑，提出来共用。
///
/// 2026-10-30 修：原来只做**字符串前缀**比较 ⇒ `/a/b/../c` 会被判成
/// "在 `/a/b` 内"（虽然调用方通常已 normalizePath，但这个函数是公共的，
/// 自己就该站稳）。现在先用 `Uri.normalizePath` 消掉 `.` / `..` 再比。
bool isWithinDir(String path, String dirPath) {
  String norm(String p) {
    final s = p.replaceAll('\\', '/');
    try {
      return Uri.file(s).normalizePath().toFilePath().replaceAll('\\', '/');
    } catch (_) {
      return s; // 非法路径字符：退回原串，由调用方决定怎么处理
    }
  }

  final p = norm(path);
  var d = norm(dirPath);
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

  /// 正在 bind 中的实例（appId → future）。
  ///
  /// 没有这张表的话，同一个 appId 被并发打开两次（快速连点、页面重建）
  /// 会各自 bind 一个端口：后写入 [_instances] 的胜出，先那个**永远不会被
  /// stop**，端口和 socket 就泄漏了。
  static final Map<String, Future<MiniAppLocalServer>> _starting = {};

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
  }) {
    final existing = _instances[appId];
    if (existing != null) return Future<MiniAppLocalServer>.value(existing);
    final pending = _starting[appId];
    if (pending != null) return pending;
    final future = _startNew(appId, root);
    _starting[appId] = future;
    return future.whenComplete(() => _starting.remove(appId));
  }

  static Future<MiniAppLocalServer> _startNew(String appId, String root) async {
    final server = MiniAppLocalServer._();
    await server._bind(root);
    _instances[appId] = server;
    AppLog.instance.log('[MiniAppLocal] $appId → ${server.baseUrl}（root=$root）');
    return server;
  }

  /// 停止某个小程序的本地服务（页面关闭时调用，释放端口）。
  static Future<void> stop(String appId) async {
    // 还在 bind 中就先等它落地，否则 remove 拿不到、服务会漏在后台
    final pending = _starting.remove(appId);
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        // bind 失败本身没有实例可关，忽略
      }
    }
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
        await _respondText(request, HttpStatus.forbidden, 'forbidden');
        return;
      }

      var file = File(target);
      var contentType = _mimeOf(rel);

      // ── 目录请求 / SPA 深路由：回 index.html ─────────────
      // 仅当「路径不是文件（无扩展名或指向目录）」时才回退，避免把
      // 真 404 的资源请求也吞掉。
      // 2026-10-30 修：原来只找 `<rel>/index.html` ⇒ `/some/spa/route` 这种
      // **前端路由**（目录并不存在）直接 404，SPA 型小程序一刷新就白屏。
      // 现在找不到对应目录的 index.html 就回根 index.html。
      final looksLikeFile = rel.split('/').last.contains('.');
      final isDir = await Directory(target).exists();
      if (isDir || (!looksLikeFile && !await file.exists())) {
        final subIndex =
            '$_root${rel.endsWith('/') ? rel : '$rel/'}index.html';
        if (await File(subIndex).exists()) {
          file = File(subIndex);
          rel = '${rel.endsWith('/') ? rel : '$rel/'}index.html';
        } else {
          file = File('${_root}index.html');
          rel = 'index.html';
        }
        contentType = _mimeOf(rel);
      }

      if (!await file.exists()) {
        await _respondText(request, HttpStatus.notFound, 'not found');
        return;
      }
      final bytes = await file.readAsBytes();

      // ── 服务端注入 ant 桥（仅 HTML）──────────────────────
      // 三级回退（参考 huoyi renderer.dart）：<head> → <html> → 文首。
      // 脚本带 `__antInjected` 守卫，与 onPageFinished 补注入叠加无害。
      if (contentType.startsWith('text/html')) {
        final body = utf8.decode(bytes, allowMalformed: true);
        final injected = _injectBootstrap(body);
        await _respond(
          request,
          HttpStatus.ok,
          utf8.encode(injected),
          contentType: 'text/html; charset=utf-8',
          extraHeaders: {'Cache-Control': 'no-store'},
        );
        return;
      }

      await _respond(
        request,
        HttpStatus.ok,
        bytes,
        contentType: contentType,
        extraHeaders: {'Cache-Control': 'no-store'},
      );
    } catch (e) {
      AppLog.instance.log('[MiniAppLocal] 请求处理失败 ${request.uri.path}: $e');
      try {
        await _respondText(request, HttpStatus.internalServerError, 'server error');
      } catch (_) {}
    }
  }

  /// 把 ant 桥 bootstrap 插进 HTML（`<head>` → `<html>` → 文首三级回退）
  ///
  /// ⚠️ 2026-10-30 修：原来用 `html.indexOf('<head')`，`<header>` 也会命中
  /// （`'<header>'.indexOf('<head') == 0`）⇒ 页面有 `<header>` 而没有 `<head>`
  /// 时，桥脚本会被塞进 `<header>` 内部（虽然还能跑，但位置不对、也容易被
  /// 页面的 DOM 操作覆盖掉）。现在要求标签名后紧跟 `>` 或空白。
  static String _injectBootstrap(String html) {
    const script = '<script>\n${AntBridge.injectScript}\n</script>';
    final headEnd = _openTagEnd(html, 'head');
    if (headEnd >= 0) return html.replaceRange(headEnd, headEnd, script);
    final htmlEnd = _openTagEnd(html, 'html');
    if (htmlEnd >= 0) return html.replaceRange(htmlEnd, htmlEnd, script);
    return '$script\n$html';
  }

  /// 找 `<tag ...>` 开标签 `>` 之后的下标（插入点）；找不到返回 -1。
  ///
  /// 大小写不敏感，且要求标签名后面是 `>`/空白 —— 避免把 `<header>`、
  /// `<htmlx>` 这类同前缀标签当成目标。
  static int _openTagEnd(String html, String tag) {
    final lower = html.toLowerCase();
    var from = 0;
    while (from < lower.length) {
      final at = lower.indexOf('<$tag', from);
      if (at < 0) return -1;
      final after = at + tag.length + 1;
      if (after >= html.length) return -1;
      final c = html[after];
      final isBoundary = c == '>' || c == ' ' || c == '\t' || c == '\n' || c == '\r';
      if (isBoundary) {
        final end = html.indexOf('>', at);
        if (end >= 0) return end + 1;
        return -1; // 开标签没闭合，不能当插入点
      }
      from = at + 1;
    }
    return -1;
  }

  static Future<void> _respondText(
    HttpRequest request,
    int status,
    String text,
  ) {
    return _respond(
      request,
      status,
      utf8.encode(text),
      contentType: 'text/plain; charset=utf-8',
    );
  }

  static Future<void> _respond(
    HttpRequest request,
    int status,
    List<int> body, {
    String? contentType,
    Map<String, String> extraHeaders = const {},
  }) async {
    final response = request.response
      ..statusCode = status
      ..headers.contentType = ContentType.parse(
        contentType ?? 'application/octet-stream',
      );
    extraHeaders.forEach(response.headers.set);
    response.add(body);
    // 必须 await：不 await 的话 handler 提前返回，异常也没法捕获
    await response.close();
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
