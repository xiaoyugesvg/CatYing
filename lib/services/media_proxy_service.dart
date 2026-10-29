// lib/services/media_proxy_service.dart
//
// 本机播放代理（2026-10-21 第一批）。
//
// ── 为什么需要 ────────────────────────────────────────────────
//   · 很多源的播放地址带防盗链：必须带 Referer / UA / Cookie
//   · m3u8 的子清单、密钥、分片经常是**相对路径**，直接丢给播放器会 404
//   · 投屏 / 部分播放器内核拿不到自定义请求头
//
// ── 做法 ──────────────────────────────────────────────────────
// 起一个只监听 127.0.0.1 的 HttpServer，把「原始 URL + 请求头」编码进路径：
//
//   http://127.0.0.1:<port>/mp/<base64url({"u":url,"h":headers})>
//
// 代理收到请求后：
//   1. 用保存的请求头去取上游（Range / If-Range 原样透传）
//   2. 是 m3u8 → 读成文本，把子清单/密钥/分片全部改写成代理地址再返回
//   3. 其它 → 以流的方式原样转发（不整段读进内存）
//
// ⚠️ 只监听 loopback，不对外网开放；投屏（DLNA/AirPlay）用的是局域网 IP，
//    拿不到 127.0.0.1，所以投屏链路会跳过代理。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'package:tvbox/reading/source/global_proxy.dart';
import 'package:tvbox/services/m3u8_ad_filter.dart';

class MediaProxyService {
  MediaProxyService._();
  static final MediaProxyService instance = MediaProxyService._();

  HttpServer? _server;
  Future<void>? _starting;
  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 30),
    followRedirects: true,
  ));

  bool get isRunning => _server != null;
  int get port => _server?.port ?? 0;

  /// 启动代理（幂等）。App 启动时调一次即可。
  Future<void> start() {
    return _starting ??= _doStart();
  }

  Future<void> _doStart() async {
    if (_server != null) return;
    try {
      // 跟随「通用设置 → 网络代理」：代理自己取上游时也要走它
      applyGlobalProxy(_dio);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      debugPrint('[MediaProxy] 已启动 127.0.0.1:${server.port}');
      server.listen(_handle, onError: (e) {
        debugPrint('[MediaProxy] 监听异常: $e');
      });
    } catch (e) {
      debugPrint('[MediaProxy] 启动失败: $e');
    }
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _starting = null;
    await s?.close(force: true);
  }

  /// 把播放地址包成代理地址。
  ///
  /// 返回 null = 不需要/不能代理（调用方直接用原地址）：
  ///   · 非 http(s)（本地文件、content:// 等）
  ///   · 已经是本机地址
  ///   · 既没有请求头、也不是 m3u8（代理没有收益，反而多一跳）
  String? proxify(String url, {Map<String, String>? headers}) {
    if (_server == null) return null;
    final u = url.trim();
    if (u.isEmpty) return null;
    final lower = u.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return null;
    }
    if (lower.contains('127.0.0.1') || lower.contains('localhost')) return null;
    final h = <String, String>{};
    headers?.forEach((k, v) {
      if (k.trim().isEmpty || v.trim().isEmpty) return;
      h[k] = v;
    });
    final isM3u8 = _looksLikeM3u8(u);
    if (h.isEmpty && !isM3u8) return null;
    final id = _putSession(u, h);
    return 'http://127.0.0.1:$port/mp/$id';
  }

  static bool _looksLikeM3u8(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    return path.endsWith('.m3u8') || path.endsWith('.m3u');
  }

  // ── 会话表 ──────────────────────────────────────────────────
  //
  // 原始地址 + 请求头**存在服务端**，URL 里只放一个短 id。
  // 之前把整份 JSON 编码进路径，m3u8 每个分片都带一份 → URL 爆炸到几百 KB，
  // 而且 Cookie 会出现在 URL 里（容易被日志/截图带出去）。
  final Map<String, Map<String, dynamic>> _sessions = {};
  int _seq = 0;
  static const int _maxSessions = 1024;

  String _putSession(String url, Map<String, String> headers) {
    final id = (_seq++).toRadixString(36);
    _sessions[id] = {'u': url, 'h': headers};
    if (_sessions.length > _maxSessions) {
      _sessions.remove(_sessions.keys.first);
    }
    return id;
  }

  Map<String, dynamic>? _getSession(String id) => _sessions[id];

  Future<void> _handle(HttpRequest request) async {
    try {
      final segs = request.uri.pathSegments;
      if (segs.length < 2 || segs.first != 'mp') {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        return;
      }
      final data = _getSession(segs[1]);
      final target = (data?['u'] ?? '').toString();
      if (target.isEmpty) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      final headers = <String, String>{};
      final h = data?['h'];
      if (h is Map) {
        h.forEach((k, v) => headers[k.toString()] = v.toString());
      }
      // 播放器自己的 Range / If-Range 优先透传
      for (final name in const ['range', 'if-range', 'user-agent']) {
        final v = request.headers.value(name);
        if (v != null && v.isNotEmpty) {
          if (name == 'user-agent' && headers.keys.any(
              (k) => k.toLowerCase() == 'user-agent')) {
            continue;
          }
          headers[name] = v;
        }
      }
      await _forward(request, target, headers);
    } catch (e) {
      debugPrint('[MediaProxy] 转发失败: $e');
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> _forward(
    HttpRequest request,
    String target,
    Map<String, String> headers,
  ) async {
    final method = request.method.toUpperCase();
    final resp = await _dio.request<ResponseBody>(
      target,
      options: Options(
        method: method == 'HEAD' ? 'HEAD' : 'GET',
        headers: headers,
        responseType: ResponseType.stream,
        validateStatus: (_) => true,
      ),
    );

    final upstream = resp.data;
    final out = request.response;
    out.statusCode = resp.statusCode ?? HttpStatus.badGateway;

    final ctype = (resp.headers.value('content-type') ?? '').toLowerCase();
    final isM3u8 = ctype.contains('mpegurl') || _looksLikeM3u8(target);
    final hasEncoding = resp.headers.value('content-encoding') != null;

    const skipBase = {
      'transfer-encoding',
      'connection',
      'keep-alive',
      'content-encoding',
    };
    resp.headers.forEach((name, values) {
      final key = name.toLowerCase();
      if (skipBase.contains(key)) return;
      // m3u8 会被改写、gzip 会被 Dio 解开 —— 这两种情况下长度已经不对了。
      // 其它情况**必须保留 content-length**：mpv 靠它判断 VOD 可 seek 范围。
      if (key == 'content-length' && (isM3u8 || hasEncoding)) return;
      if (values.isEmpty) return;
      out.headers.set(name, values.join(','));
    });

    if (upstream == null) {
      await out.close();
      return;
    }
    if (isM3u8) {
      final bytes = <int>[];
      await for (final chunk in upstream.stream) {
        bytes.addAll(chunk);
      }
      final text = utf8.decode(bytes, allowMalformed: true);
      final rewritten = _rewriteM3u8(text, target, headers);
      out.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/vnd.apple.mpegurl',
      );
      out.write(rewritten);
      await out.close();
      return;
    }
    await out.addStream(upstream.stream);
    await out.close();
  }

  /// 改写 m3u8：子清单 / 密钥 / 分片 / 初始化段全部走代理，相对路径补全
  String _rewriteM3u8(
    String text,
    String baseUrl,
    Map<String, String> headers,
  ) {
    // 先做**分片级去广告**（插播片段），再做地址改写 ——
    // 顺序不能反：清洗要按原始 URL 算「来源指纹」，改写成 127.0.0.1 之后
    // 所有分片都同源了，就再也分辨不出哪几条是插播。
    var src = text;
    if (M3u8AdFilter.enabled.value) {
      final r = M3u8AdFilter.filter(text, baseUrl);
      if (r.removed > 0) src = r.text;
    }

    final base = Uri.tryParse(baseUrl);
    String px(String ref) {
      final r = ref.trim();
      if (r.isEmpty) return r;
      final parsed = Uri.tryParse(r);
      final abs = (parsed != null && parsed.hasScheme)
          ? r
          : (base?.resolve(r).toString() ?? r);
      return 'http://127.0.0.1:$port/mp/${_putSession(abs, headers)}';
    }

    final uriAttr = RegExp(r'URI="([^"]+)"');
    const uriTags = [
      '#EXT-X-KEY:',
      '#EXT-X-SESSION-KEY:',
      '#EXT-X-MEDIA:',
      '#EXT-X-MAP:',
      '#EXT-X-I-FRAME-STREAM-INF:',
      '#EXT-X-PART:',
      '#EXT-X-PRELOAD-HINT:',
      '#EXT-X-RENDITION-REPORT:',
    ];

    final out = StringBuffer();
    for (final line in const LineSplitter().convert(src)) {
      final t = line.trim();
      if (t.isEmpty) {
        out.writeln(line);
        continue;
      }
      if (t.startsWith('#')) {
        final hit = uriTags.any((p) => t.startsWith(p));
        out.writeln(hit
            ? t.replaceAllMapped(uriAttr, (m) => 'URI="${px(m.group(1)!)}"')
            : line);
        continue;
      }
      out.writeln(px(t));
    }
    return out.toString();
  }
}
