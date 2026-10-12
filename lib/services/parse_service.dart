import 'dart:convert';

import 'package:dio/dio.dart';

import '../common/constants.dart';
import '../models/app_config.dart';
import 'api_config.dart';
import 'app_log.dart';

/// 播放地址解析（parses 接口）- 单例。
///
/// 使用配置里 `parseBeanList` 中第一个 `type == 1`（解析）接口，
/// 把非直链的播放页面地址换成真正的媒体地址。
/// 所有异常都吞掉并返回 null，绝不向外抛。
class ParseService {
  ParseService._internal();
  static final ParseService instance = ParseService._internal();

  static const Duration _timeout = Duration(seconds: 5);

  Dio? _dio;
  Dio get _client => _dio ??= Dio(BaseOptions(
        connectTimeout: _timeout,
        receiveTimeout: _timeout,
        headers: {'User-Agent': AppConstants.defaultUserAgent},
      ));

  /// 是否存在可用的解析接口（非空且含 type==1）。
  bool get enabled {
    final list = ApiConfig.instance.parseBeanList;
    if (list.isEmpty) return false;
    return list.any((p) => p.type == 1 && p.url.trim().isNotEmpty);
  }

  ParseBean? _firstParser() {
    for (final p in ApiConfig.instance.parseBeanList) {
      if (p.type == 1 && p.url.trim().isNotEmpty) return p;
    }
    return null;
  }

  /// 解析 [url]，成功返回媒体地址，失败/无接口返回 null。
  Future<String?> parse(String url, {Map<String, String>? headers}) async {
    try {
      final target = url.trim();
      if (target.isEmpty) return null;

      final bean = _firstParser();
      if (bean == null) return null;

      final endpoint = _buildEndpoint(bean.url.trim(), target);
      if (endpoint.isEmpty) return null;

      final resp = await _client.get<String>(
        endpoint,
        options: Options(
          responseType: ResponseType.plain,
          headers: headers,
        ),
      );

      final body = resp.data;
      if (body == null || body.isEmpty) {
        AppLog.instance.log('[Parse] 响应为空');
        return null;
      }

      final extracted = _extractUrl(body);
      if (extracted == null) {
        AppLog.instance.log('[Parse] 未从响应中提取到播放地址');
        return null;
      }
      AppLog.instance.log('[Parse] 解析成功');
      return extracted;
    } catch (e) {
      AppLog.instance.log('[Parse] 解析失败: $e');
      return null;
    }
  }

  // ============================================================
  // 内部
  // ============================================================

  /// 兼容三种接口形态：
  /// 1) 含 `{url}` 占位符；2) 含 `url=` 查询参数；3) 无占位直接拼接。
  /// 全部用 [Uri] 正确编码目标地址。
  String _buildEndpoint(String template, String target) {
    if (template.isEmpty) return '';

    if (template.contains('{url}')) {
      return template.replaceAll('{url}', Uri.encodeComponent(target));
    }

    final uri = Uri.tryParse(template);
    if (uri != null && uri.hasScheme) {
      if (template.contains('url=') || uri.queryParameters.containsKey('url')) {
        final params = Map<String, String>.from(uri.queryParameters);
        params['url'] = target;
        return uri.replace(queryParameters: params).toString();
      }
      // 无占位直接拼（编码后拼接）
      return '$template${Uri.encodeComponent(target)}';
    }
    return '$template${Uri.encodeComponent(target)}';
  }

  /// 依次尝试 `url` / `data` / `playUrl` / `video` 字段，再回退到纯文本里的 http 链接。
  String? _extractUrl(String body) {
    final trimmed = body.trim();
    try {
      final decoded = jsonDecode(trimmed);
      final found = _findInJson(decoded);
      if (found != null) return found;
    } catch (_) {
      // 非 JSON，走纯文本
    }
    return _firstHttpUrl(trimmed);
  }

  String? _findInJson(dynamic node, [int depth = 0]) {
    if (depth > 6 || node == null) return null;

    if (node is String) return _asHttpUrl(node);

    if (node is Map) {
      for (final key in const ['url', 'data', 'playUrl', 'video']) {
        final r = _findInJson(node[key], depth + 1);
        if (r != null) return r;
      }
      for (final v in node.values) {
        final r = _findInJson(v, depth + 1);
        if (r != null) return r;
      }
      return null;
    }

    if (node is List) {
      for (final v in node) {
        final r = _findInJson(v, depth + 1);
        if (r != null) return r;
      }
      return null;
    }
    return null;
  }

  String? _asHttpUrl(String s) {
    final v = s.trim();
    if (v.isEmpty) return null;
    if (v.startsWith('http://') || v.startsWith('https://')) return v;
    return _firstHttpUrl(v);
  }

  String? _firstHttpUrl(String text) {
    final m = RegExp(r'''https?://[^\s"'<>]+''').firstMatch(text);
    final v = m?.group(0);
    if (v == null || v.isEmpty) return null;
    return v;
  }
}
