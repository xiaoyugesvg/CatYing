// lib/services/xbpq/xbpq_http.dart
//
// XBPQ 抓取层 —— 对齐 huoyi `provider_xbpq.go` 的
// `xbpqFetch` / `xbpqDecodeBody` / `xbpqAgent`。
//
// 规则里的地址可以带方法后缀：`url;post;body`。第二段是 post 就发 POST
// （搜索接口常用），否则 GET。规格的拆/拼在 `XbpqUrl`（纯 Dart），
// 本文件只负责真的发请求。
//
// GBK：不少苹果CMS站是 GBK/GB2312，按 `<meta charset>` 探测后转码；
// 复用项目里 O(n) 的 `decodeGbk`，不用 gbk_codec 那个 O(n²) 的实现。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'package:tvbox/common/constants.dart';
import 'package:tvbox/reading/services/gbk_fast.dart';
import 'package:tvbox/services/dio_factory.dart';
import 'package:tvbox/services/xbpq/xbpq_url.dart';
import 'package:tvbox/services/xbpq/xbpq_util.dart';

class XbpqHttp {
  XbpqHttp._();

  /// GBK/GB2312/GB18030 页面转 UTF-8。
  static String decodeBody(Uint8List bytes) {
    if (bytes.isEmpty) return '';

    final headLength = bytes.length > 4096 ? 4096 : bytes.length;
    final head = latin1.decode(bytes.sublist(0, headLength), allowInvalid: true);
    if (!_charsetPattern.hasMatch(head)) {
      return utf8.decode(bytes, allowMalformed: true);
    }
    try {
      final decoded = decodeGbk(bytes);
      return decoded.trim().isEmpty
          ? utf8.decode(bytes, allowMalformed: true)
          : decoded;
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  static final RegExp _charsetPattern =
      RegExp(r'''charset\s*=\s*["' ]?(gbk|gb2312|gb18030)''', caseSensitive: false);

  /// 按规则抓取页面文本。失败抛 [XbpqException]。
  static Future<String> fetch(
    String raw, {
    String referer = '',
    String agent = '',
  }) async {
    final spec = XbpqUrl.splitSpec(raw);
    if (spec.address.isEmpty) {
      throw const XbpqException('规则地址为空');
    }

    final headers = <String, String>{
      'User-Agent':
          agent.trim().isEmpty ? AppConstants.defaultUserAgent : agent.trim(),
    };
    if (referer.trim().isNotEmpty) headers['Referer'] = referer.trim();
    if (spec.isPost) {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
    }

    final dio = buildDioWithDns(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
    );

    try {
      final response = await dio.request<List<int>>(
        spec.address,
        data: spec.isPost ? spec.body : null,
        options: Options(
          method: spec.isPost ? 'POST' : 'GET',
          headers: headers,
          responseType: ResponseType.bytes,
          followRedirects: true,
          validateStatus: (status) => status != null && status < 400,
        ),
      );
      final data = response.data;
      if (data == null) throw const XbpqException('响应为空');
      return decodeBody(
        data is Uint8List ? data : Uint8List.fromList(data),
      );
    } on XbpqException {
      rethrow;
    } on DioException catch (e) {
      throw XbpqException(_describe(e));
    } catch (e) {
      throw XbpqException('请求失败：$e');
    }
  }

  static String _describe(DioException e) {
    final status = e.response?.statusCode;
    if (status != null) return 'HTTP $status';
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return '请求超时';
      case DioExceptionType.connectionError:
        return '连接失败';
      case DioExceptionType.cancel:
        return '请求已取消';
      case DioExceptionType.badResponse:
      case DioExceptionType.badCertificate:
      case DioExceptionType.unknown:
        return e.message ?? '请求失败';
    }
  }
}
