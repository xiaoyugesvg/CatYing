import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../common/constants.dart';
import '../models/app_config.dart';
import 'api_config.dart';
import 'app_log.dart';
import 'parse_store.dart';
import 'play_route.dart';
import 'player_prefs.dart';
import 'sniff_filter.dart';

/// 解析结果：url 为解析得到的地址；direct 表示是否已是可直链播放的媒体。
class ParseOutcome {
  final String url;
  final bool direct;
  final String sourceName;

  /// 解析接口自带的请求头（`ext.header`）——**播放这个地址时必须一起带上**。
  ///
  /// 很多解析站给出来的直链有防盗链（要 Referer / 特定 UA），不带就直接 403。
  /// 之前这里丢了 header，导致"解析明明成功却播不了"（2026-10-15 深挖发现）。
  final Map<String, String>? headers;

  ParseOutcome(
    this.url, {
    required this.direct,
    this.sourceName = '',
    this.headers,
  });
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

  /// 解析结果缓存 TTL。切集 / 重试 / 自动下一集常在短时间内请求**同一个**
  /// 地址，串行重解析既慢又白耗接口配额（用户 2026-10-15 反馈"解析影响播放"）。
  /// 解析站对同一地址的响应短时间内稳定，10 分钟内直接复用。
  static const Duration _cacheTtl = Duration(minutes: 10);
  static const int _cacheMax = 32;

  /// LRU 缓存（LinkedHashMap 插入序，命中后移到末尾）
  final LinkedHashMap<String, _ParseCacheEntry> _cache = LinkedHashMap();

  /// 首选线路（用户手选的 active）的"抢跑窗口"：并发解析时若首选还没回来，
  /// 先等它这么久；超时就用已返回的其它线路结果，避免卡死。
  static const Duration _preferWindow = Duration(milliseconds: 1200);

  Dio? _dio;
  Dio get _client => _dio ??= Dio(BaseOptions(
        connectTimeout: _timeout,
        receiveTimeout: _timeout,
        headers: {'User-Agent': AppConstants.defaultUserAgent},
      ));

  /// 是否允许解析：存在可用接口（url 非空，type 0 或 1）**且**用户没有在
  /// 「播放设置 → 嗅探设置」里关掉解析总开关。
  bool get enabled =>
      PlayerPrefs.instance.parseEnabled.value && _parsers().isNotEmpty;

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

  /// 解析 [url]：**并发**请求可用接口（或仅 [only] 指定的接口），
  /// 成功返回 [ParseOutcome]（含直链判定），全部失败返回 null。
  ///
  /// 两点关键改进（用户 2026-10-15 反馈"解析影响播放"）：
  ///   · **并发**：原来串行遍历，5 个接口各 6 秒超时最坏要等 30 秒才出画面；
  ///     现在同时发出，谁先返回可用结果用谁（首选线路给 [_preferWindow] 抢跑
  ///     窗口，避免"手动选了 A 却用了 B"）。
  ///   · **缓存**：同一地址 10 分钟内直接复用，切集/重试/自动下一集不再重解。
  Future<ParseOutcome?> parseOutcome(
    String url, {
    ParseBean? only,
    Map<String, String>? headers,
  }) async {
    final target = url.trim();
    if (target.isEmpty) return null;

    // 缓存 key 必须带**接口身份**（only.url）：否则用户点「换解析接口」时
    // 会命中上一条线路留下的缓存，看起来"换了没反应"（2026-10-15 深挖发现）。
    final cacheKey = '${only?.url ?? ''}|$target';

    // 缓存命中（LRU：命中后移到末尾）
    final cached = _cache[cacheKey];
    if (cached != null) {
      if (!cached.expired) {
        _cache.remove(cacheKey);
        _cache[cacheKey] = cached;
        AppLog.instance.log('[Parse] 缓存命中 → ${cached.outcome.url}');
        return cached.outcome;
      }
      _cache.remove(cacheKey);
    }

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
    if (beans.isEmpty) return null;

    final outcome = beans.length == 1
        ? await _tryBean(beans.first, target, headers)
        : await _resolveConcurrently(beans, target, headers);
    if (outcome != null) {
      _cache[cacheKey] = _ParseCacheEntry(outcome);
      while (_cache.length > _cacheMax) {
        _cache.remove(_cache.keys.first);
      }
    }
    return outcome;
  }

  /// 让某个**播放地址**的解析缓存失效（用户点「重试」/播放失败时调用）。
  ///
  /// 为什么必须做：解析出的 m3u8 常带时效签名，缓存 10 分钟内可能已经是过期
  /// 地址；若重试还命中同一条缓存，用户会陷入"点重试→同一个坏地址→再失败"
  /// 的死循环，永远恢复不了（2026-10-15 深挖发现）。
  void invalidate(String url) {
    final target = url.trim();
    if (target.isEmpty) return;
    _cache.removeWhere((k, _) => k.endsWith('|$target'));
  }

  /// 清空解析缓存（解析线路被增删改后调用，保证"改完立即生效"）。
  void clearCache() => _cache.clear();

  /// 同时发出的解析请求上限（滑动窗口）。
  ///
  /// 并发把"5 个接口 × 6 秒串行 = 30 秒"压成"≈6 秒"（谁先回来用谁）；
  /// 但用户可能配十几条接口，一次全发容易被解析站限流、失败率反而上升。
  /// 限制在飞数量、多的排队补发 —— 常见场景（接口 ≤ 8 条）行为完全不变。
  static const int _maxConcurrent = 8;

  /// 并发请求所有候选，第一个可用结果即返回（首选线路有抢跑窗口）。
  Future<ParseOutcome?> _resolveConcurrently(
    List<ParseBean> beans,
    String target,
    Map<String, String>? headers,
  ) {
    final completer = Completer<ParseOutcome?>();
    final successes = <int, ParseOutcome>{};
    var finished = 0;
    var started = 0;
    Timer? window;

    void completeFromBest() {
      if (completer.isCompleted || successes.isEmpty) return;
      final best = successes.keys.reduce((a, b) => a < b ? a : b);
      completer.complete(successes[best]);
    }

    /// 按 [_maxConcurrent] 补发请求（有请求完成就再放一个进去）
    void pump() {
      while (!completer.isCompleted &&
          started < beans.length &&
          started - finished < _maxConcurrent) {
        final idx = started++;
        unawaited(_tryBean(beans[idx], target, headers).then((o) {
          if (completer.isCompleted) return;
          finished++;
          if (o != null) {
            successes[idx] = o;
            if (idx == 0) {
              // 首选（用户手选线路 / 列表第一条）成功：立刻采用
              window?.cancel();
              completer.complete(o);
              return;
            }
            // 非首选先到：给首选一个抢跑窗口，超时再用目前最好的
            window ??= Timer(_preferWindow, completeFromBest);
          }
          if (finished == beans.length) {
            window?.cancel();
            if (successes.isEmpty) {
              completer.complete(null);
            } else {
              completeFromBest();
            }
            return;
          }
          pump(); // 空出一个并发位 → 补发下一个
        }));
      }
    }

    pump();
    return completer.future;
  }

  /// 用单个解析接口请求一次（所有异常吞掉，返回 null）。
  Future<ParseOutcome?> _tryBean(
    ParseBean bean,
    String target,
    Map<String, String>? headers,
  ) async {
    try {
      final endpoint = _buildEndpoint(bean.url.trim(), target);
      if (endpoint.isEmpty) return null;

      // 接口自带的 header（ext.header）：既用于请求解析接口本身，
      // 也随 [ParseOutcome] 带出去供**播放**使用（防盗链场景）。
      final beanHeaders = _headerOf(bean);
      final mergedHeaders = <String, String>{
        if (headers != null) ...headers,
        ...?beanHeaders,
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
        return null;
      }

      final extracted = _extractUrl(body);
      if (extracted == null || extracted.isEmpty) {
        AppLog.instance.log('[Parse] 接口「${bean.name}」未提取到地址');
        return null;
      }

      // 解析结果格式筛选（设置页「解析结果的格式」；空 = 不限）：
      // 只对清单内的媒体后缀生效（音频/未知后缀放行），勾了 m3u8 就跳过 .ts。
      final ext = SniffFilter.mediaExt(extracted);
      final wantFormats = PlayerPrefs.instance.parseFormats;
      if (ext.isNotEmpty &&
          wantFormats.isNotEmpty &&
          !wantFormats.contains(ext)) {
        AppLog.instance.log(
            '[Parse] 接口「${bean.name}」结果格式 $ext 不在允许列表，跳过');
        return null;
      }

      AppLog.instance.log(
          '[Parse] 接口「${bean.name}」命中 → ${_isDirectMedia(extracted) ? '直链' : '网页'}: $extracted');
      return ParseOutcome(
        extracted,
        direct: _isDirectMedia(extracted),
        sourceName: bean.name,
        headers: beanHeaders,
      );
    } catch (e) {
      AppLog.instance.log('[Parse] 接口「${bean.name}」失败: $e');
      return null;
    }
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

  /// 从解析接口响应里提取地址。
  ///
  /// ⚠️ 2026-10-15 修复 w3.org 误判（用户点开任何视频都跳进
  /// `http://www.w3.org/1999/xhtml` 的嗅探页）：旧实现对非 JSON 响应
  /// 一律"抓第一个 http 链接"，而解析站返回的 HTML 里几乎必然带着
  /// `xmlns="http://www.w3.org/1999/xhtml"`，于是命名空间地址被当成
  /// 播放结果。新规则：
  ///   ① **JSON 响应**：优先取具名字段（url/data/playUrl/video/play_url），
  ///      字段给的可以是直链也可以是网页播放页（接口明确声明，可信）；
  ///      具名字段没有时，全量兜底扫描**只接受影视直链**。
  ///   ② **JSONP 响应**（`callback({...})`）：抠出花括号里的 JSON 同①。
  ///   ③ **HTML / 纯文本**：只接受带影视后缀（m3u8/mp4/flv…）的直链；
  ///      纯文本里的任意网页 URL 不再采信（w3.org 这类误判即由此杜绝）。
  String? _extractUrl(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return null;

    // ① JSON
    final decoded = _tryDecodeJson(trimmed);
    if (decoded != null) {
      final named = _findInJson(decoded, namedOnly: true);
      if (named != null) return named;
      return _findInJson(decoded, namedOnly: false);
    }

    // ③ 非 JSON：严格只认影视直链（HTML 里扫 m3u8/mp4 也走这条）
    return _firstMediaUrl(trimmed);
  }

  /// 直接 `jsonDecode`，失败再按 JSONP `xxx({...})` 抠花括号内容试一次。
  dynamic _tryDecodeJson(String text) {
    try {
      return jsonDecode(text);
    } catch (_) {}
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start >= 0 && end > start) {
      try {
        return jsonDecode(text.substring(start, end + 1));
      } catch (_) {}
    }
    return null;
  }

  /// 在 JSON 节点里找地址。
  ///
  /// [namedOnly] = true：只看 `url` / `data` / `playUrl` / `video` /
  /// `play_url` 这几个**具名字段**，命中任意 http URL 即返回（网页播放页
  /// 也算 —— 这是接口显式给的结果，调用方按 direct 标志决定嗅探）。
  /// [namedOnly] = false：具名字段落空后的**兜底全量扫描**，此时只接受
  /// 影视直链，避免把说明文字/日志里的任意网址（w3.org 命名空间之类）
  /// 误当播放地址。
  String? _findInJson(dynamic node,
      {required bool namedOnly, int depth = 0}) {
    if (depth > 6 || node == null) return null;

    if (node is String) {
      final v = node.trim();
      if (!v.startsWith('http://') && !v.startsWith('https://')) {
        // 少数接口把地址包在一段文字里，宽松模式允许从中抠媒体直链
        return namedOnly ? null : _firstMediaUrl(v);
      }
      if (namedOnly) return v;
      return _isDirectMedia(v) ? v : _firstMediaUrl(v);
    }

    if (node is Map) {
      if (namedOnly) {
        for (final key in const ['url', 'data', 'playUrl', 'video', 'play_url']) {
          final r = _findInJson(node[key], namedOnly: true, depth: depth + 1);
          if (r != null) return r;
        }
        // 具名字段里也可能嵌着对象/数组，继续向下找具名字段
        for (final v in node.values) {
          final r = _findInJson(v, namedOnly: true, depth: depth + 1);
          if (r != null) return r;
        }
        return null;
      }
      for (final v in node.values) {
        final r = _findInJson(v, namedOnly: false, depth: depth + 1);
        if (r != null) return r;
      }
      return null;
    }

    if (node is List) {
      for (final v in node) {
        final r = _findInJson(v, namedOnly: namedOnly, depth: depth + 1);
        if (r != null) return r;
      }
      return null;
    }
    return null;
  }

  /// 从任意文本里取**第一个影视直链**（必须带媒体后缀）。
  ///
  /// 与旧的 `_firstHttpUrl`（见 git 历史）不同：这里绝不接受
  /// `http://www.w3.org/1999/xhtml` 这类没有媒体后缀的任意网址，
  /// 从根上挡住解析页 HTML 的 xmlns 误判。
  ///
  /// ⚠️ 后缀清单**动态**来自用户设置（[SniffFilter.mediaExtAlternation]），
  /// 不允许写死：否则用户加/删后缀后，这里扫 HTML 里直链的能力不跟着变
  /// （2026-10-15 深挖：这是第 5 处硬编码）。按候选串指纹缓存编译结果。
  static String? _mediaAltCache;
  static RegExp? _mediaReCache;

  static RegExp get _mediaUrlRe {
    final alt = SniffFilter.mediaExtAlternation;
    if (_mediaAltCache != alt || _mediaReCache == null) {
      _mediaAltCache = alt;
      _mediaReCache = RegExp(
        "https?://[^\\s\"'<>\\\\]+?\\.(?:$alt)(?:[?#][^\\s\"'<>\\\\]*)?",
        caseSensitive: false,
      );
    }
    return _mediaReCache!;
  }

  String? _firstMediaUrl(String text) => _mediaUrlRe.firstMatch(text)?.group(0);

  /// 仅供单测：直接喂解析接口响应体，验证 [_extractUrl] 的提取/误判行为
  /// （w3.org xmlns 回归、JSON 具名字段、JSONP、HTML 媒体直链扫描）。
  @visibleForTesting
  String? debugExtractUrl(String body) => _extractUrl(body);

  /// 仅供单测：后缀判定必须与影视端 [looksLikeDirectMedia] 一致
  /// （曾出现"解析结果 .webm/.mpd 被判成网页又送去嗅探"的漂移）。
  @visibleForTesting
  bool debugIsDirectMedia(String url) => _isDirectMedia(url);

  /// 是否是已知直链媒体（后缀命中）——是则无需再嗅探。
  ///
  /// 2026-10-15：统一委托 [SniffFilter.isDirectMedia]（按用户可自定义的
  /// 「影视直链后缀」清单判定）。原来这里只认 6 种，解析接口返回的
  /// `.webm`/`.mpd` 会被判成"网页"→ 白白再送去嗅探一轮。音频后缀
  /// （解析接口也可能返回音乐直链）在影视清单之外，用 [kAudioExtensions] 补判。
  static bool _isDirectMedia(String url) {
    if (url.isEmpty) return false;
    if (SniffFilter.isDirectMedia(url)) return true;
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    for (final ext in kAudioExtensions) {
      if (path.endsWith(ext)) return true;
    }
    return false;
  }
}

/// 解析结果缓存条目（10 分钟过期）
class _ParseCacheEntry {
  final ParseOutcome outcome;
  final DateTime at;
  _ParseCacheEntry(this.outcome) : at = DateTime.now();
  bool get expired => DateTime.now().difference(at) > ParseService._cacheTtl;
}
