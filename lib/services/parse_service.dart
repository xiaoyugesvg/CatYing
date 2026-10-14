import 'dart:convert';

import 'package:dio/dio.dart';

import '../common/constants.dart';
import '../models/app_config.dart';
import 'api_config.dart';
import 'app_log.dart';
import 'parse_store.dart';

/// 解析结果：url 为解析得到的地址；direct 表示是否已是可直链播放的媒体。
class ParseOutcome {
  final String url;
  final bool direct;
  final String sourceName;
  ParseOutcome(this.url, {required this.direct, this.sourceName = ''});
}

/// 播放地址解析（parses 接口）- 单例。
///
/// 支持 TVBox 两种解析接口类型：
/// - type 1：解析 API（请求拼接后直接返回媒体地址）
/// - type 0：嗅探/通用解析站（返回 m3u8/mp4 直链或带播放器的网页）
/// 遍历 `parseBeanList` 中所有 url 非空的接口（按顺序，第一个成功命中即返回），
/// 每个接口可带自己的 ext.header（UA 等）。所有异常都吞掉，绝不向外抛。
class ParseService {
  ParseService._internal();
  static final ParseService instance = ParseService._internal();

  static const Duration _timeout = Duration(seconds: 6);

  Dio? _dio;
  Dio get _client => _dio ??= Dio(BaseOptions(
        connectTimeout: _timeout,
        receiveTimeout: _timeout,
        headers: {'User-Agent': AppConstants.defaultUserAgent},
      ));

  /// 是否存在可用的解析接口（url 非空，type 0 或 1 均可）。
  bool get enabled => _parsers().isNotEmpty;

  List<ParseBean> _parsers() {
    final list = ApiConfig.instance.parseBeanList;
    return list
        .where((p) => p.url.trim().isNotEmpty && (p.type == 0 || p.type == 1))
        .toList();
  }

  /// 兼容旧调用：返回第一个成功解析到的地址字符串（可能是网页，由调用方判断）。
  Future<String?> parse(String url, {Map<String, String>? headers}) async {
    final o = await parseOutcome(url, headers: headers);
    return o?.url;
  }

  /// 解析 [url]：遍历可用接口（或仅 [only] 指定的接口），
  /// 成功返回 [ParseOutcome]（含直链判定），全部失败返回 null。
  ///
  /// 播放器底栏的「解析」按钮切换线路后，用户选中的那条由 [ParseStore] 记录，
  /// 这里会**优先**用它，失败再自动回退其余线路（选错也不至于播不了）。
  Future<ParseOutcome?> parseOutcome(
    String url, {
    ParseBean? only,
    Map<String, String>? headers,
  }) async {
    final target = url.trim();
    if (target.isEmpty) return null;

    final all = _parsers();
    List<ParseBean> beans;
    if (only != null) {
      beans = [only];
    } else {
      final active = ParseStore.instance.activeBean;
      beans = active == null
          ? all
          : [active, ...all.where((b) => b.url != active.url)];
    }
    for (final bean in beans) {
      try {
        final endpoint = _buildEndpoint(bean.url.trim(), target);
        if (endpoint.isEmpty) continue;

        final mergedHeaders = <String, String>{
          if (headers != null) ...headers,
          ...?_headerOf(bean),
        };

        final resp = await _client.get<String>(
          endpoint,
          options: Options(
            responseType: ResponseType.plain,
            headers: mergedHeaders.isEmpty ? null : mergedHeaders,
          ),
        );

        final body = resp.data;
        if (body == null || body.isEmpty) {
          AppLog.instance.log('[Parse] 接口「${bean.name}」响应为空');
          continue;
        }

        final extracted = _extractUrl(body);
        if (extracted == null || extracted.isEmpty) {
          AppLog.instance.log('[Parse] 接口「${bean.name}」未提取到地址');
          continue;
        }
        AppLog.instance.log(
            '[Parse] 接口「${bean.name}」命中 → ${_isDirectMedia(extracted) ? '直链' : '网页'}: $extracted');
        return ParseOutcome(
          extracted,
          direct: _isDirectMedia(extracted),
          sourceName: bean.name,
        );
      } catch (e) {
        AppLog.instance.log('[Parse] 接口「${bean.name}」失败: $e');
        continue;
      }
    }
    return null;
  }

  /// 从接口 ext 里解出 header（TVBox 常见 `ext.header` 为 JSON 字符串）。
  Map<String, String>? _headerOf(ParseBean bean) {
    final raw = bean.ext?['header'];
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {
      // 非 JSON 直接忽略
    }
    return null;
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
      for (final key in const ['url', 'data', 'playUrl', 'video', 'play_url']) {
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

  /// 是否是已知直链媒体（后缀命中）——是则无需再嗅探。
  static bool _isDirectMedia(String url) {
    if (url.isEmpty) return false;
    final path = Uri.tryParse(url)?.path ?? url;
    final lower = path.toLowerCase();
    for (final ext in const [
      '.m3u8',
      '.mp4',
      '.flv',
      '.ts',
      '.mkv',
      '.m3u',
      '.mp3',
      '.aac',
      '.wav',
    ]) {
      if (lower.endsWith(ext)) return true;
    }
    return false;
  }
}
