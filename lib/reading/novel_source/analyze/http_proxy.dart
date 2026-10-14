/// 本机同步 HTTP 代理：worker isolate 里的 `SyncHttpClient` 打它，
/// 它用 **Dio 异步**去抓真实 URL，再把结果回传。
///
/// ── 为什么这是**架构必需**，不是优化 ────────────────────────
/// `sync_http` 0.3.1 的实测能力（源码在 pub 缓存里，逐行核过）：
/// ```dart
/// L57:  final RawSynchronousSocket _socket;
/// L61:  _socket = RawSynchronousSocket.connectSync(uri.host, uri.port); // 明文 TCP，无 TLS
/// L267: throw UnsupportedError('chunked transfer is unsupported');      // 请求侧不支持
/// L387: throw UnsupportedError('only identity transfer encoding is accepted'); // 响应侧拒绝
/// _LineDecoder._process: utf8.decoder.convert(line)                    // 只按 UTF-8 解码
/// ```
/// ⇒ 直接用它抓真实站点会**四处受限**：
/// | 限制 | 后果 |
/// |---|---|
/// | 无 TLS | **https 站点全部抓不到**（书源绝大多数是 https） |
/// | 拒绝 chunked | 服务端用 chunked 就抛 `only identity transfer encoding is accepted` |
/// | 只 UTF-8 | GBK/Big5 站点解码抛异常 |
/// | 无超时 | 网络挂死会一直阻塞（只能靠 worker isolate 被超时杀掉兜底） |
///
/// ── 本文件怎么解决 ─────────────────────────────────────────
/// 同步请求改成打 `http://127.0.0.1:<port>/`（明文 + 本机 + **我显式设
/// Content-Length** ⇒ 不触发上面两条限制），由本代理用 Dio **异步**抓真实
/// URL —— TLS/chunked/gzip/重定向/超时全部由 Dio 正常处理 —— 并把正文
/// **按目标站声明的 charset 解码后重新以 UTF-8 回传** ⇒ `sync_http` 的
/// UTF-8 解码拿到的就是正确文本（GBK 也就通了）。
///
/// 这正是上游 2.0.8 的做法（`book_source/engine/sync_http_bridge.dart` +
/// 本机回环服务器）。
///
/// ⚠️ **必须与发起同步请求的 isolate 分开运行**：同步 socket 会阻塞所在
/// isolate 的事件循环，若代理与它同在一个 isolate，代理永远无法响应
/// ⇒ **死锁**（这个坑我在自测里实测撞过：卡满 10 分钟）。
/// 约定：代理跑在**主 isolate**（`BookSourceRunner.run` 里启动并把端口传进
/// worker），同步请求发生在 worker isolate。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:get/get.dart';

import '../../../services/app_log.dart';
import '../../pages/webview_page.dart';
import '../../source/global_proxy.dart';
import '../../source/webview_image_fetcher.dart';

/// 本机同步 HTTP 代理（进程级单例）。
class LegadoHttpProxy {
  LegadoHttpProxy._();

  static int _port = 0;
  static HttpServer? _server;
  static Dio? _dio;

  /// 已启动的端口；0 表示未启动。
  static int get port => _port;

  /// 幂等启动代理，返回端口。
  ///
  /// ⚠️ 必须在**不会**发起同步请求的 isolate 里调用（约定：主 isolate）。
  static Future<int> ensureStarted() async {
    if (_port > 0) return _port;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _port = server.port;
    _dio = Dio(BaseOptions(
      followRedirects: true,
      maxRedirects: 5,
      validateStatus: (_) => true, // 4xx/5xx 也原样回传，交给书源规则判断
      responseType: ResponseType.bytes,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      // 关键：不接受压缩。否则正文是 gzip 字节，而 `sync_http` 不会解压。
      headers: const <String, String>{'accept-encoding': 'identity'},
    ));
    // ⚠️ 必须套**全局网络代理**：这条链路是 JS 规则里 `java.ajax` 的出口
    //   （订阅源的 `sortUrl` / 书源的 `@js` 都走它）。漏了它 ⇒ 用户开了
    //   「设置 → 网络代理」后所有 java.ajax 直连失败，规则表现为"求值为空"
    //   （用户 2026-10-15 排查订阅源时发现）。
    applyGlobalProxy(_dio!);
    server.listen(_handle, onError: (_) {});
    return _port;
  }

  /// 仅供测试/诊断：关闭代理。
  static Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = 0;
  }

  static Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final target = req.headers.value('x-legado-url');
      if (target == null || target.isEmpty) {
        return await _fail(res, 400, 'x-legado-url 头缺失');
      }
      final method = req.headers.value('x-legado-method') ?? 'GET';

      // ── 浏览器栈模式（`x-legado-browser`）──────────────────────
      // 真浏览器栈只能在**主 isolate** 驱动 WebView ⇒ 由本代理代劳 ✓
      //（worker isolate 里的 `AnalyzeUrl` / `java.webView` 只发请求 ✓）
      final browserMode = req.headers.value('x-legado-browser');
      if (browserMode != null && browserMode.isNotEmpty) {
        // 可选：`java.webView(content, url, js)` 的注入 js（base64，见
        // legado_java_prelude.dart 的 `_browser`）—— 非空时回 js 执行结果，
        // 为空时回渲染后 HTML。
        await _handleBrowser(
            res, target, browserMode, req.headers.value('x-legado-js'));
        return;
      }

      // 透传业务头（去掉我们自己的协议头与逐跳头）
      // HttpHeaders 没有 `names`（那是 package:http 的 API）⇒ 用 forEach
      final headers = <String, String>{};
      req.headers.forEach((name, values) {
        final n = name.toLowerCase();
        if (n.startsWith('x-legado-') ||
            n == 'host' ||
            n == 'content-length' ||
            n == 'connection' ||
            n == 'transfer-encoding') {
          return;
        }
        if (values.isNotEmpty) headers[name] = values.first;
      });

      final bodyBytes = await _readAll(req);

      final resp = await _dio!.request<List<int>>(
        target,
        data: bodyBytes.isEmpty ? null : bodyBytes,
        options: Options(method: method, headers: headers),
      );

      final raw = resp.data ?? const <int>[];
      final charset = _charsetOf(resp.headers.value('content-type'));
      final text = _decodeText(raw, charset);

      res.statusCode = resp.statusCode ?? 502;
      // ⚠️ sync_http 的源码里明确写着 `persistence connections are unsupported`：
      //    它读满 Content-Length 后仍会继续 readSync，直到 socket 关闭才返回。
      //    Dart 的 HttpResponse 默认 keep-alive ⇒ 不关就会一直阻塞
      //（实测：测试因此 30s 超时）。所以这里显式要求关闭。
      res.persistentConnection = false;
      resp.headers.forEach((name, values) {
        final n = name.toLowerCase();
        // 逐跳头与长度/编码相关的一律不回传：本代理自己重算 Content-Length，
        // 且必须保证**不是** chunked（sync_http 只认 identity）
        if (n == 'transfer-encoding' ||
            n == 'content-length' ||
            n == 'connection' ||
            n == 'content-encoding') {
          return;
        }
        for (final v in values) {
          try {
            res.headers.add(name, v);
          } catch (_) {/* 非法头名忽略 */}
        }
      });
      try {
        res.headers.set('x-legado-final-url', resp.realUri.toString());
      } catch (_) {}
      if (charset != null) {
        try {
          res.headers.set('x-legado-charset', charset);
        } catch (_) {}
      }

      // 统一以 UTF-8 回传（sync_http 只会按 UTF-8 解）
      final out = utf8.encode(text);
      res.contentLength = out.length; // ← 必须设！否则 Dart 用 chunked 会被拒
      res.add(out);
      await res.close();
    } catch (e) {
      await _fail(res, 502, '$e');
    }
  }

  /// 浏览器栈模式的三种用法：
  ///   · `fetch`      → 真浏览器栈加载目标页，回**渲染后 HTML**（`{webView:true}` /
  ///                    `java.webView` 用；Cloudflare 等反爬站 Dio 拿不到内容）
  ///   · `open`       → 在内置浏览器打开，**立即返回**（`startBrowser`）
  ///   · `open-await` → 同上；语义上应等用户关闭页面，但见下方超时说明
  ///
  /// ⚠️ `open-await` 当前**不真正阻塞**：书源求值跑在 worker isolate 上，
  ///   而 worker 有 **60s 硬超时且超时即杀**（`runner_isolate.defaultTimeout`）✗
  ///   —— 等用户手动登录/过验证很容易超过 60s ⇒ 会把整次求值杀掉、
  ///   连已拿到的结果一起丢 ✗。所以这里只负责“把页面打开给用户”，
  ///   登录完成后的 Cookie 已由 WebView 自身的 Cookie 罐持有（同域请求复用它）✓。
  static Future<void> _handleBrowser(
    HttpResponse res,
    String target,
    String mode, [
    String? jsB64,
  ]) async {
    try {
      String text = '';
      if (mode == 'fetch') {
        // 注入 js（可选）：`java.webView(content, url, js)` 的第三参 ——
        // 非空时返回 js 在页面上下文的执行结果（如 `document.cookie`），
        // 为空时返回渲染后 HTML。
        var js = '';
        if (jsB64 != null && jsB64.isNotEmpty) {
          try {
            js = utf8.decode(base64.decode(jsB64), allowMalformed: true);
          } catch (_) {/* 解码失败 → 降级为「无 js」 */}
        }
        text = await WebViewImageFetcher().fetchHtml(target, js);
      } else {
        _openInAppBrowser(target);
      }
      final out = utf8.encode(text);
      res.persistentConnection = false; // sync_http 不支持 keep-alive
      res.statusCode = 200;
      res.contentLength = out.length;
      res.add(out);
      await res.close();
    } catch (e) {
      await _fail(res, 502, '$e');
    }
  }

  /// 在内置浏览器（全屏 WebView + 左上角返回）打开 [url]，供用户手动登录 /
  /// 通过人机验证。**不阻塞**（见 [_handleBrowser] 的超时说明）。
  static void _openInAppBrowser(String url) {
    try {
      Get.to(
        () => OnlineReaderPage(url: url, title: '书源浏览器'),
      );
      AppLog.instance.log('[书源浏览器] 已打开: $url');
    } catch (e) {
      AppLog.instance.w('[书源浏览器] 打开失败: $e');
    }
  }

  static Future<void> _fail(HttpResponse res, int code, String msg) async {
    // ⚠️ 踩过的坑：直接把 `DioException.toString()` 塞进头会让 `headers.set`
    //    抛异常（含非 ASCII/换行）—— 异常被吞掉后**响应永不关闭**，
    //    客户端（sync_http）就一直阻塞（实测 30s 超时；生产里表现为
    //    `java.ajax` 打挂掉的站会永久卡住 worker）。
    //    ⇒ 错误信息改走 **base64**（纯 ASCII），且 close 一定单独执行。
    try {
      res.persistentConnection = false; // sync_http 不支持 keep-alive
      res.statusCode = code;
      try {
        res.headers.set('x-legado-error-b64', base64.encode(utf8.encode(msg)));
      } catch (_) {/* 连 base64 都塞不进去就只能放弃错误详情 */}
      res.contentLength = 0;
    } catch (_) {}
    try {
      await res.close();
    } catch (_) {}
  }

  static Future<List<int>> _readAll(HttpRequest req) async {
    final b = BytesBuilder(copy: false);
    await for (final chunk in req) {
      b.add(chunk);
    }
    return b.takeBytes();
  }

  static String? _charsetOf(String? contentType) {
    if (contentType == null) return null;
    final m = RegExp(r'charset\s*=\s*"?([\w-]+)"?', caseSensitive: false)
        .firstMatch(contentType);
    return m?.group(1);
  }

  /// 与 `analyze_url.dart` 的 `_decodeBody` 同口径：GBK 系用 GBK 解码，
  /// 其余先严格 UTF-8、失败再容错 UTF-8。
  static String _decodeText(List<int> bytes, String? charset) {
    final cs = (charset ?? '').toLowerCase();
    if (cs.contains('gbk') || cs.contains('gb2312') || cs.contains('gb18030')) {
      try {
        return gbk.decode(bytes);
      } catch (_) {/* 落到 UTF-8 容错 */}
    }
    if (cs.contains('big5')) {
      // big5 不在 fast_gbk 覆盖范围内：先按容错 UTF-8 处理，避免抛异常
      return utf8.decode(bytes, allowMalformed: true);
    }
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }
}
