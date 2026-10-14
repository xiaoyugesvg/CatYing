/// 浏览器一致的 HTTP 客户端适配器（Dio [HttpClientAdapter] 实现）。
///
/// ## 为什么需要它
/// Dart 自带的 `HttpClient`（Dio 默认 [IOHttpClientAdapter] 的底层）在发起请求时：
/// 1. 把所有请求头名**强制小写**；
/// 2. 把 `Host` 头**固定排在最后**，且顺序无法干预。
///
/// 部分 Cloudflare 站点（如笔趣阁 m.biqubu3.com）会据此做**静态机器指纹拦截**：
/// 只要头名不是浏览器风格的 Title-Case、或 `Host` 不在首行，就直接返回
/// 403「Just a moment...」挑战壳——**即使不带任何 Cookie，浏览器风格的请求也能
/// 直接拿到 200 正文**。因此这类拦截不是「过一次 WebView 验证就能解决」的交互式
/// 挑战，而是请求指纹本身不对；Dio 直连每次都会被重新拦，表现为「验证完仍解析
/// 不到内容 / 一直加载」。
///
/// 本适配器绕过 `HttpClient`，直接用 [SecureSocket]/[Socket] 手写 HTTP/1.1 请求，
/// 完全控制头名大小写与顺序（`Host` 首行 + Title-Case），从而通过上述指纹检测。
///
/// ## 覆盖范围与回落
/// 仅接管 `http`/`https` 直连（无系统代理场景，与书源 [AnalyzeUrl] 现状一致）。
/// 无法处理或出现异常时回落到内置 [IOHttpClientAdapter]，避免破坏既有行为。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:tvbox/services/app_log.dart';

class BrowserFaithfulHttpClientAdapter implements HttpClientAdapter {
  BrowserFaithfulHttpClientAdapter({HttpClientAdapter? fallback})
      : _fallback = fallback ?? IOHttpClientAdapter();

  final HttpClientAdapter _fallback;

  /// [FIX-B03-TLS] 是否允许「坏证书」继续连接。
  ///
  /// **默认 false = 严格校验证书链与主机名**（`onBadCertificate` 传 null）。
  /// 历史行为是无条件 `onBadCertificate: (_) => true`：等于对所有 https 书源
  /// 关闭证书校验且不打任何日志，中间人可透明读取/改写搜索、目录、正文，
  /// 以及书源登录表单里的账号密码。
  ///
  /// 确有证书损坏（自签 / 过期 / 域名不匹配）又愿意承担风险的老源，由调用方
  /// **显式**打开本开关；每次放行都会写一条 WARN 日志（含目标 host 与证书
  /// 主体/有效期）便于追溯。也可在构建期用
  /// `--dart-define=TVBOX_ALLOW_INSECURE_CERT=true` 打开。
  static bool allowInsecureCertificates =
      const bool.fromEnvironment('TVBOX_ALLOW_INSECURE_CERT');

  /// 返回本次连接应使用的 `onBadCertificate` 回调：默认 **null**（Dart 默认
  /// 即校验证书链与主机名），仅当 [allowInsecureCertificates] 打开时放行。
  static bool Function(X509Certificate)? badCertificateHandlerFor(String host) {
    if (!allowInsecureCertificates) return null;
    return (cert) {
      AppLog.instance.w(
        '[书源TLS] 用户已允许不安全证书 host=$host '
        'subject=${cert.subject} issuer=${cert.issuer} '
        'notAfter=${cert.endValidity.toIso8601String()}',
      );
      return true;
    };
  }

  /// 状态码属于「需要跟随的重定向」。
  static const Set<int> _redirectCodes = {301, 302, 303, 307, 308};

  /// 请求头的浏览器规范顺序（`Host` 恒定首行，其余按 Chrome 常见次序）。
  /// 未列出的头统一追加到末尾（保持插入序）。
  static const List<String> _canonicalOrder = <String>[
    'host',
    'connection',
    'user-agent',
    'accept',
    'accept-language',
    'accept-encoding',
    'referer',
    'cookie',
    'content-type',
    'content-length',
  ];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      return _fallback.fetch(options, requestStream, cancelFuture);
    }

    // 收集请求体（POST 等）。
    List<int>? body;
    if (requestStream != null) {
      final chunks = <int>[];
      await for (final c in requestStream) {
        chunks.addAll(c);
      }
      body = chunks;
    }

    // 归一化入参头（小写键便于查找/去重；输出时再 Title-Case）。
    final headers = <String, String>{};
    options.headers.forEach((k, v) {
      if (v != null) headers[k.toString().toLowerCase()] = v.toString();
    });

    final connectTimeout = options.connectTimeout ?? const Duration(seconds: 15);
    final receiveTimeout = options.receiveTimeout ?? const Duration(seconds: 30);
    final maxRedirects = options.followRedirects ? options.maxRedirects : 0;

    try {
      var currentUri = uri;
      var method = options.method.toUpperCase();
      var curBody = body;
      var redirectCount = 0;
      final redirectRecords = <RedirectRecord>[];

      while (true) {
        final resp = await _perform(
          currentUri,
          method,
          headers,
          curBody,
          connectTimeout,
          receiveTimeout,
        );

        final isRedirect = _redirectCodes.contains(resp.status);
        if (isRedirect &&
            resp.location != null &&
            resp.location!.isNotEmpty &&
            redirectCount < maxRedirects) {
          redirectCount++;
          final next = _resolveLocation(currentUri, resp.location!);
          redirectRecords.add(RedirectRecord(resp.status, method, next));
          // 301/302/303 → 浏览器改用 GET 且丢弃请求体，307/308 保持原样。
          if (resp.status == 301 || resp.status == 302 || resp.status == 303) {
            method = 'GET';
            curBody = null;
            headers.remove('content-type');
            headers.remove('content-length');
          }
          headers.remove('host'); // 交给 _perform 按新 host 重算。
          currentUri = next;
          continue;
        }

        return ResponseBody.fromBytes(
          resp.body,
          resp.status,
          headers: resp.headers,
          isRedirect: redirectCount > 0,
          statusMessage: resp.reason,
        )..redirects = redirectRecords;
      }
    } on Object {
      // 任何异常（TLS/解析/超时等）回落到内置适配器，保证不比现状更差。
      //
      // ⚠️ 2026-10-14 修：上面已经把 `requestStream` **读空**了（`await for`），
      //   而它是**单订阅流** —— 原样再交给内置适配器会抛
      //   "Stream has already been listened to"，让"回落"这条兜底在中途失效
      //   （带 body 的 POST 必现；无 body 的 GET 不受影响）。这里用已读到的
      //   字节重建一个单元素流交过去，语义完全等价。
      return _fallback.fetch(
        options,
        body == null
            ? requestStream
            : Stream<Uint8List>.value(Uint8List.fromList(body)),
        cancelFuture,
      );
    }
  }

  Future<_RawResponse> _perform(
    Uri uri,
    String method,
    Map<String, String> headers,
    List<int>? body,
    Duration connectTimeout,
    Duration receiveTimeout,
  ) async {
    final host = uri.host;
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    final Socket socket = uri.scheme == 'https'
        ? await SecureSocket.connect(
            host,
            port,
            timeout: connectTimeout,
            // [FIX-B03-TLS] 默认 null = 正常校验；仅显式开关打开时放行坏证书。
            onBadCertificate: badCertificateHandlerFor(host),
            supportedProtocols: const ['http/1.1'],
          )
        : await Socket.connect(host, port, timeout: connectTimeout);

    try {
      socket.add(_buildRequest(uri, method, headers, body));
      await socket.flush();

      final all = <int>[];
      // 逐块读取直到服务端关闭连接（我们发送 Connection: close）。
      // 用 per-gap 超时兜底，避免坏连接永久挂起。
      // [FIX-B03-TIMEOUT] 超时不再静默 close 后把「半截响应」当完整正文返回：
      // 记下超时交给 _parseResponse 做完整性判定，不完整就抛可重试异常
      // （此前表现为正文少半章 / 列表缺尾部条目，无异常、无日志）。
      var timedOut = false;
      await socket.timeout(receiveTimeout, onTimeout: (sink) {
        timedOut = true;
        sink.close();
      }).forEach(all.addAll);

      return _parseResponse(Uint8List.fromList(all), timedOut: timedOut);
    } finally {
      socket.destroy();
    }
  }

  Uint8List _buildRequest(
    Uri uri,
    String method,
    Map<String, String> headers,
    List<int>? body,
  ) {
    final path = _requestTarget(uri);
    final hostValue = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;

    // 复制一份可消费的头表；强制补齐浏览器风格的必备头。
    final pending = Map<String, String>.from(headers);
    pending['host'] = hostValue;
    pending['connection'] = 'close';
    // 只声明我们能解码的编码，避免服务端用 br/zstd 导致无法解压。
    pending['accept-encoding'] = 'gzip, deflate';
    if (body != null) {
      pending['content-length'] = '${body.length}';
    }

    final sb = StringBuffer()..write('$method $path HTTP/1.1\r\n');
    final written = <String>{};
    void emit(String lowerName) {
      final value = pending[lowerName];
      if (value == null || written.contains(lowerName)) return;
      sb.write('${_titleCase(lowerName)}: $value\r\n');
      written.add(lowerName);
    }

    for (final name in _canonicalOrder) {
      emit(name);
    }
    // 其余自定义头按原插入序追加。
    for (final name in pending.keys) {
      emit(name);
    }
    sb.write('\r\n');

    final headBytes = ascii.encode(sb.toString());
    if (body == null || body.isEmpty) return Uint8List.fromList(headBytes);
    return Uint8List.fromList([...headBytes, ...body]);
  }

  String _requestTarget(Uri uri) {
    final path = uri.path.isEmpty ? '/' : uri.path;
    return uri.query.isEmpty ? path : '$path?${uri.query}';
  }

  /// 解析原始响应字节（头 + 体 + 解块 + 解压）。
  ///
  /// [timedOut] 为 true 表示读取阶段发生过超时（连接是被我们主动断开的）：
  /// 此时只有长度自洽的响应才允许当完整响应返回，否则抛 [HttpException]。
  _RawResponse _parseResponse(Uint8List raw, {bool timedOut = false}) {
    final sep = _indexOfHeaderEnd(raw);
    if (sep < 0) {
      // 没有完整头（异常响应）——当作空体 502 交给上层判定。
      return const _RawResponse(
        502,
        <String, List<String>>{},
        <int>[],
        null,
        'Bad Gateway',
      );
    }
    final headText = latin1.decode(raw.sublist(0, sep));
    List<int> bodyBytes = raw.sublist(sep + 4);

    final lines = headText.split('\r\n');
    final statusLine = lines.isNotEmpty ? lines.first : 'HTTP/1.1 502';
    final statusParts = statusLine.split(' ');
    final status = statusParts.length >= 2 ? int.tryParse(statusParts[1]) ?? 0 : 0;
    final reason =
        statusParts.length >= 3 ? statusParts.sublist(2).join(' ') : null;

    final headers = <String, List<String>>{};
    for (final line in lines.skip(1)) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      final name = line.substring(0, idx).trim().toLowerCase();
      final value = line.substring(idx + 1).trim();
      headers.putIfAbsent(name, () => <String>[]).add(value);
    }

    // Transfer-Encoding: chunked → 先解块。
    // [FIX-B03-TIMEOUT] 顺手做完整性校验：被超时/断流截断的响应不能当完整
    // 正文返回（否则正文少半章、列表缺尾部条目，且没有任何信号）。
    final te = headers['transfer-encoding']?.join(',').toLowerCase() ?? '';
    if (te.contains('chunked')) {
      final (dechunked, complete) = _dechunk(bodyBytes);
      bodyBytes = dechunked;
      if (!complete) {
        throw HttpException(
          '响应被截断：chunked 传输未读到终止块（已收 ${raw.length} 字节）',
        );
      }
    } else {
      final cl = headers['content-length']?.first.trim();
      final expected = cl == null ? null : int.tryParse(cl);
      if (expected != null) {
        if (bodyBytes.length != expected) {
          throw HttpException(
            '响应被截断：正文 ${bodyBytes.length} 字节 != content-length $expected',
          );
        }
      } else if (timedOut) {
        // close 定界的响应没有长度可校验，读取又超时 ⇒ 无法确认正文完整。
        throw HttpException(
          '接收超时且响应无 content-length，正文可能不完整（已收 ${raw.length} 字节）',
        );
      }
    }

    // Content-Encoding: gzip/deflate → 解压。
    final ce = headers['content-encoding']?.join(',').toLowerCase() ?? '';
    if (ce.contains('gzip')) {
      bodyBytes = _tryDecode(() => gzip.decode(bodyBytes), bodyBytes);
    } else if (ce.contains('deflate')) {
      bodyBytes = _tryDecode(
        () => zlib.decode(bodyBytes),
        // 部分服务端发原始 deflate（无 zlib 包裹）→ 退一步用 raw inflate。
        _tryDecode(
          () => ZLibDecoder(raw: true).convert(bodyBytes),
          bodyBytes,
        ),
      );
    }

    final location = headers['location']?.first;
    return _RawResponse(
      status,
      headers,
      bodyBytes,
      location,
      reason,
    );
  }

  List<int> _tryDecode(List<int> Function() decode, List<int> fallback) {
    try {
      return decode();
    } on Object {
      return fallback;
    }
  }

  /// 解 HTTP chunked 传输编码。
  ///
  /// 返回 `(正文, 是否读到终止块)`：终止块缺失说明传输被截断（[FIX-B03-TIMEOUT]）。
  (Uint8List, bool) _dechunk(List<int> data) {
    final out = <int>[];
    var i = 0;
    var complete = false;
    while (i < data.length) {
      // 读取块长度行（十六进制，可能带 `;扩展`）。
      final lineEnd = _indexOfCRLF(data, i);
      if (lineEnd < 0) break;
      final sizeLine = latin1.decode(data.sublist(i, lineEnd));
      final semi = sizeLine.indexOf(';');
      final hex = (semi >= 0 ? sizeLine.substring(0, semi) : sizeLine).trim();
      final size = int.tryParse(hex, radix: 16);
      if (size == null) break;
      i = lineEnd + 2;
      if (size == 0) {
        complete = true; // 终止块。
        break;
      }
      if (i + size > data.length) {
        out.addAll(data.sublist(i));
        break;
      }
      out.addAll(data.sublist(i, i + size));
      i += size + 2; // 跳过块尾 CRLF。
    }
    return (Uint8List.fromList(out), complete);
  }

  int _indexOfHeaderEnd(List<int> data) {
    for (var i = 0; i + 3 < data.length; i++) {
      if (data[i] == 13 &&
          data[i + 1] == 10 &&
          data[i + 2] == 13 &&
          data[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  int _indexOfCRLF(List<int> data, int from) {
    for (var i = from; i + 1 < data.length; i++) {
      if (data[i] == 13 && data[i + 1] == 10) return i;
    }
    return -1;
  }

  Uri _resolveLocation(Uri base, String location) {
    try {
      return base.resolve(location);
    } on Object {
      return base;
    }
  }

  /// 把小写头名转成浏览器风格 Title-Case（如 `user-agent` → `User-Agent`）。
  static String _titleCase(String lower) {
    return lower
        .split('-')
        .map((p) => p.isEmpty ? p : '${p[0].toUpperCase()}${p.substring(1)}')
        .join('-');
  }

  @override
  void close({bool force = false}) => _fallback.close(force: force);
}

class _RawResponse {
  const _RawResponse(
    this.status,
    this.headers,
    this.body,
    this.location,
    this.reason,
  );

  final int status;
  final Map<String, List<String>> headers;
  final List<int> body;
  final String? location;
  final String? reason;
}
