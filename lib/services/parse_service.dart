import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:tvbox/common/constants.dart';
import 'package:tvbox/models/app_config.dart';
import 'package:tvbox/reading/source/global_proxy.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/parse_store.dart';
import 'package:tvbox/services/play_route.dart';
import 'package:tvbox/services/player_prefs.dart';
import 'package:tvbox/services/sniff_filter.dart';

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

  Dio? _dio;
  Dio get _client => _dio ??= _createDio();

  /// 🔴 必须套全局代理（2026-10-28 深挖）。
  ///
  /// 全项目 60 多处 Dio 都调了 `applyGlobalProxy`，**唯独这里漏了** ——
  /// 后果是：用户一开代理，解析接口的请求走直连，解析站基本都连不上，
  /// 表现为「解析线路全部失败，关了代理就好」。嗅探侧
  /// （`WebSniffService`）一直是套着的，所以只有解析会挂，很难联想到一起。
  static Dio _createDio() {
    final dio = Dio(BaseOptions(
      connectTimeout: _timeout,
      receiveTimeout: _timeout,
      headers: {'User-Agent': AppConstants.defaultUserAgent},
    ));
    try {
      applyGlobalProxy(dio);
    } catch (e) {
      AppLog.instance.log('[Parse] 代理配置失败: $e');
    }
    return dio;
  }

  /// 是否允许解析：存在可用接口（url 非空，type 0 或 1）**且**用户没有在
  /// 「播放设置 → 嗅探设置」里关掉解析总开关。
  bool get enabled =>
      PlayerPrefs.instance.parseEnabled.value && _parsers().isNotEmpty;

  /// 是否**配置了**可用解析接口（不看用户的解析总开关）。
  ///
  /// 详情页用它实现「打开网页链接就自动解一次」：用户不必先去设置里把
  /// 「解析总开关」打开（2026-10-28 用户明确反感被开关卡住）。
  /// 没有配置任何接口时返回 false —— 不会无意义地发请求。
  bool get hasParsers => _parsers().isNotEmpty;

  List<ParseBean> _parsers() {
    final list = ApiConfig.instance.parseBeanList;
    return list
        .where((p) =>
            p.url.trim().isNotEmpty &&
            (p.type == 0 || p.type == 1) &&
            p.enabled)
        .toList();
  }

  /// 兼容旧调用：返回第一个成功解析到的地址字符串（可能是网页，由调用方判断）。
  Future<String?> parse(String url, {Map<String, String>? headers}) async {
    final o = await parseOutcome(url, headers: headers);
    return o?.url;
  }

  /// 解析 [url]：**串行**遍历可用接口（或仅 [only] 指定的接口），
  /// 第一个成功即返回；全部失败返回 null。
  ///
  /// 2026-10-29 对齐 huoyi：去掉并发 / 缓存 / 直链探针，行为简单可预期
  /// （多接口时最坏串行 N×6s，换取代码量与失败面的收敛）。
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
      // 选中线路被禁用（或已被删除）→ 视为"自动"（禁用选中项回自动）
      beans = (active == null || !active.enabled)
          ? all
          : [active, ...all.where((b) => b.url != active.url)];
    }

    for (final bean in beans) {
      final outcome = await _tryBean(bean, target, headers);
      if (outcome != null) return outcome;
    }
    return null;
  }

  /// 兼容保留：V1 已去掉解析缓存，此处为空实现（UI / 设置页仍在调用）。
  void invalidate(String url) {}

  /// 兼容保留：V1 已去掉解析缓存，此处为空实现。
  void clearCache() {}

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
        ...?headers,
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

      // ── 302 链路：最终地址 ≠ 请求地址 ─────────────────────────
      //
      // dio 默认跟随重定向，`resp.data` 是**最终**响应的 body，但地址仍是
      // `endpoint`。解析接口的常见形态是 302 到 CDN 直链（防盗链/负载
      // 均衡），如果拿请求地址当播放地址/解析 base：
      //   · 相对路径（`/hls/x/index.m3u8`）会按错误 base 补全；
      //   · 部分服务器只对最终地址放行（校验 Host/签名）。
      // dio 的 `resp.redirects` 记录了整条重定向链，取最后一跳。
      final finalUrl = resp.redirects.isNotEmpty
          ? resp.redirects.last.location.toString()
          : endpoint;

      // ── 响应体**本身就是 m3u8 播放列表** ──────────────────────────
      //
      // 很多解析站（典型就是内置「牛马」那种 `xxx/nm_free.php?url=…`）
      // 不返回 JSON，而是**直接把 m3u8 文本吐出来** —— 这时"播放地址"
      // 就是请求地址本身，AVPlayer 播它没问题。
      //
      // 原来这里一律走 `_extractUrl`，而纯文本分支只认**带媒体后缀的绝对
      // 地址**：正文里若是相对路径（`/hls/xxx/1.ts`、`seg-1.ts`）就一个都
      // 提不出来 → 整条线路被判"未提取到地址"→ 解析等于没做。
      // 这是「解析明明配了却永远失败」的常见原因（2026-10-28 深挖）。
      if (_looksLikeM3u8Body(body)) {
        AppLog.instance.log(
            '[Parse] 接口「${bean.name}」直接返回 m3u8 文本 → 用请求地址播放');
        return ParseOutcome(
          finalUrl,
          direct: true,
          sourceName: bean.name,
          headers: beanHeaders,
        );
      }

      final extracted = _extractUrl(body, base: finalUrl);
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
  /// 响应体是不是一段 **HLS 播放列表**（`#EXTM3U` / `#EXTINF` 开头）。
  ///
  /// 用来识别"解析站直接吐 m3u8 文本"的形态 —— 这种情况下播放地址就是
  /// 请求地址本身，不需要再从正文里抠 URL。
  static bool _looksLikeM3u8Body(String body) {
    final head = body.trimLeft();
    if (head.isEmpty) return false;
    return head.startsWith('#EXTM3U') || head.startsWith('#EXTINF');
  }

  String? _extractUrl(String body, {String? base}) {
    var trimmed = body.trim();
    // 少数接口会带 UTF-8 BOM（`\uFEFF`）—— Dart 的 trim() 不认为它是空白，
    // 留着会让下面的 `_looksLikeJsonBody` 判不出 JSON（2026-10-28 深挖）。
    if (trimmed.isNotEmpty && trimmed.codeUnitAt(0) == 0xFEFF) {
      trimmed = trimmed.substring(1).trimLeft();
    }
    if (trimmed.isEmpty) return null;

    // ① JSON / JSONP —— **只在响应确实像 JSON 时**才走这条路。
    //
    // 原来无条件先 `_tryDecodeJson`（内部取"第一个 `{` 到最后一个 `}`"），
    // 于是**网页**里那段内联 JS 对象也会被当成接口响应解析：
    // `{"url":"/static/logo.png"}` 之类一旦被认成具名字段，就会把图标/页面
    // 当成播放结果（2026-10-28 深挖）。
    if (_looksLikeJsonBody(trimmed)) {
      final decoded = _tryDecodeJson(trimmed);
      if (decoded != null) {
        final named = _findInJson(decoded, namedOnly: true, base: base);
        if (named != null) return named;
        final loose = _findInJson(decoded, namedOnly: false, base: base);
        if (loose != null) return loose;
      }
    }

    // ③ 非 JSON：严格只认影视直链（HTML 里扫 m3u8/mp4 也走这条）
    return _bestMediaUrl(trimmed);
  }

  /// 响应体是否**看起来**是 JSON / JSONP（而不是夹着 JS 对象的网页）。
  ///
  /// 判据很窄：以 `{` / `[` 开头，或以 `标识符(` 开头（JSONP）。
  /// 网页永远以 `<!DOCTYPE` / `<html` / `<` 开头，一眼就能排掉。
  static bool _looksLikeJsonBody(String text) {
    if (text.isEmpty) return false;
    final c = text.codeUnitAt(0);
    if (c == 0x7B /* { */ || c == 0x5B /* [ */) return true;
    // JSONP：`callback({...})` / `jQuery123_456({...})`
    final head = text.length > 64 ? text.substring(0, 64) : text;
    return RegExp(r'^[A-Za-z_$][\w$.]*\s*\(\s*[\{\[]').hasMatch(head);
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
  ///
  /// [base] 是解析接口地址，用来把**相对路径**补成绝对地址 —— 有些接口
  /// 返回 `{"url":"/hls/xxx/index.m3u8"}`（2026-10-28 深挖）。
  String? _findInJson(dynamic node,
      {required bool namedOnly, String? base, int depth = 0}) {
    if (depth > 6 || node == null) return null;

    if (node is String) {
      final v = node.trim();
      final abs = _absoluteUrl(v, base);
      if (abs != null) {
        if (namedOnly) return abs;
        return _isDirectMedia(abs) ? abs : _bestMediaUrl(abs);
      }
      // 少数接口把地址包在一段文字里，宽松模式允许从中抠媒体直链
      return namedOnly ? null : _bestMediaUrl(v);
    }

    if (node is Map) {
      if (namedOnly) {
        for (final key in const ['url', 'data', 'playUrl', 'video', 'play_url']) {
          final r = _findInJson(node[key],
              namedOnly: true, base: base, depth: depth + 1);
          if (r != null) return r;
        }
        // 具名字段里也可能嵌着对象/数组，继续向下找具名字段
        for (final v in node.values) {
          final r =
              _findInJson(v, namedOnly: true, base: base, depth: depth + 1);
          if (r != null) return r;
        }
        return null;
      }
      for (final v in node.values) {
        final r = _findInJson(v, namedOnly: false, base: base, depth: depth + 1);
        if (r != null) return r;
      }
      return null;
    }

    if (node is List) {
      for (final v in node) {
        final r = _findInJson(v,
            namedOnly: namedOnly, base: base, depth: depth + 1);
        if (r != null) return r;
      }
      return null;
    }
    return null;
  }

  /// 把接口返回的地址规整成**绝对地址**；不该采信的返回 null。
  ///
  /// 采信范围：
  ///   · `http(s)://…` —— 原样；
  ///   · `//cdn/x.m3u8` —— 补 `https:`；
  ///   · 相对路径 —— **必须带媒体后缀**才补成绝对地址。
  ///
  /// 最后一条很关键：解析站返回的 JSON 里常有 `"logo":"/static/a.png"`、
  /// `"url":"/about"` 这类相对路径，无脑补全会把图标/页面当成播放结果
  /// （2026-10-28 深挖）。
  static String? _absoluteUrl(String raw, String? base) {
    if (raw.isEmpty) return null;
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    if (raw.startsWith('//')) return 'https:$raw';
    final b = base ?? '';
    if (b.isEmpty) return null;
    if (!_isDirectMedia(raw)) return null;
    try {
      final resolved = Uri.parse(b).resolveUri(Uri.parse(raw)).toString();
      return resolved.startsWith('http') ? resolved : null;
    } catch (_) {
      return null;
    }
  }

  /// 从任意文本里取**最可能是整片**的影视直链（必须带媒体后缀）。
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
      // ① 影视后缀清单（用户可自定义）+ 音频直链后缀：
      //    解析接口也可能返回音乐直链（音乐源），原来自定义清单不含音频
      //    时这些地址扫不出来（2026-10-28 深挖）。
      // ② 兼容协议相对地址 `//cdn/x.m3u8`：解析站 HTML 里也常见，
      //    原来只认 http(s)://，`//` 开头的一个都扫不到。
      final exts = <String>{
        ...alt.split('|'),
        ...kAudioExtensions.map((e) => e.replaceFirst('.', '').toLowerCase()),
      }.where((e) => e.isNotEmpty).join('|');
      _mediaReCache = RegExp(
        "(?:https?:)?//[^\\s\"'<>\\\\]+?\\.(?:$exts)(?:[?#][^\\s\"'<>\\\\]*)?",
        caseSensitive: false,
      );
    }
    return _mediaReCache!;
  }

  /// 文本里**最可播**的那条媒体直链（没有则 null）。
  ///
  /// 2026-10-28 深挖：原来是 `firstMatch` —— 取正文里**第一个**命中的地址。
  /// 解析站返回的 HTML/内联 JS 常常先列出几十条 `.ts` 切片（播放器分片表），
  /// `.m3u8` 主列表在更后面；取第一个命中就等于把"某一小段"当成了整片，
  /// 用户看到的是「解析成功但播几秒就结束」。现在收集全部命中再按
  /// [SniffFilter.rankCandidates] 排序取最优（m3u8 主列表 > m3u8 > mpd >
  /// mp4 类 > 未知 > ts/m4s 切片）。
  ///
  /// 同时先做 `\/` → `/` 反转义：地址常藏在 `<script>` 的 JSON 字符串里，
  /// 写作 `"https:\/\/cdn\/x\/index.m3u8"`，反转义前一个都扫不出来。
  static String? _bestMediaUrl(String text) {
    final src = text.contains('\\/') ? text.replaceAll('\\/', '/') : text;
    final hits = <String>[];
    for (final m in _mediaUrlRe.allMatches(src)) {
      final u = m.group(0);
      if (u != null && u.isNotEmpty && !hits.contains(u)) hits.add(u);
    }
    if (hits.isEmpty) return null;
    return SniffFilter.rankCandidates(hits).first;
  }

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
