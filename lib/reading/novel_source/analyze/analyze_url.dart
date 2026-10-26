/// URL 解析器：处理书源 URL 中的 `{{key}}`/`{{page}}`/`{{...JS...}}` 占位符、
/// `,{"method":"POST","body":"...","charset":"gbk"}` 选项后缀、`<js>`/`@js:` 内嵌脚本，
/// 并执行 HTTP 请求（含 GBK 等字符集解码与重定向跟随）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/reading/novel_source/analyze/analyze_rule.dart';
import 'package:tvbox/reading/novel_source/analyze/source_rate_limiter.dart';
import 'package:tvbox/reading/novel_source/analyze/sync_http_bridge.dart';
import 'package:tvbox/reading/novel_source/analyze/browser_faithful_adapter.dart';
import 'package:tvbox/reading/novel_source/analyze/verification_exception.dart';
import 'package:tvbox/reading/novel_source/analyze/source_variable_store.dart';
import 'package:tvbox/reading/novel_source/model/xiaoshuo_book.dart';
import 'package:tvbox/reading/novel_source/model/xiaoshuo_book_chapter.dart';
import 'package:tvbox/reading/novel_source/model/book_source.dart';

/// 默认 UA（无源 UA / 全局 UA 注册时的兜底）。
const String _kDefaultUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

class AnalyzeUrl {
  String url;
  String? baseUrl;
  XiaoshuoBookSource? source;
  XiaoshuoBook? ruleData;
  XiaoshuoBookChapter? chapter;
  int page;
  String? key;
  String? speakText;
  int? speakSpeed;

  final Map<String, String> headerMap = {};
  String? body;
  String? method;
  String? charset;
  int retry = 0;
  bool useWebView = false;
  String? webJs;
  String? bodyJs;
  String? proxy;
  String? dnsIp;
  String? requestType;
  int webViewDelayTime = 0;

  // 静态 Dio 实例提升性能
  // 2026-10-18：15s/30s → 25s/45s。弱网下书源分类/详情经常在 15s 连接
  // 超时后被判"网络请求失败"，放宽后能显著减少误报。
  static final Dio _dio = Dio()
    ..options.connectTimeout = const Duration(seconds: 25)
    ..options.receiveTimeout = const Duration(seconds: 45)
    ..options.validateStatus =
        ((status) => status != null && status >= 200 && status < 300)
    // 书源直连链路改用浏览器一致的原始请求（Host 首行 + Title-Case
    // 头名）：部分 Cloudflare 站（如笔趣阁）会按 Dart HttpClient 固定的「小写
    // 头名 + Host 排末行」机器指纹直接返回 403 挑战壳，使验证无法通过。
    ..httpClientAdapter = BrowserFaithfulHttpClientAdapter();

  AnalyzeUrl({
    required this.url,
    this.baseUrl,
    this.source,
    this.ruleData,
    this.chapter,
    this.page = 1,
    this.key,
    this.speakText,
    this.speakSpeed,
    Map<String, String>? headerMapF,
  }) {
    if (headerMapF != null) {
      headerMap.addAll(headerMapF);
      if (headerMapF.containsKey('proxy')) {
        proxy = headerMapF['proxy'];
        headerMap.remove('proxy');
      }
    }

    _initUrl();
  }

  void _initUrl() {
    analyzeJs();
    replaceKeyPageJs();
    analyzeUrl();
  }

  void analyzeJs() {
    final jsPattern = RegExp(r'<js>([\w\W]*?)</js>|@js:([\w\W]*)', caseSensitive: false);
    final matches = jsPattern.allMatches(url).toList();
    var start = 0;
    var result = url;

    for (final match in matches) {
      if (match.start > start) {
        final segment = url.substring(start, match.start).trim();
        if (segment.isNotEmpty) {
          result = segment.replaceAll('@result', result);
        }
      }
      final jsCode = match.group(2) ?? match.group(1) ?? '';
      final jsResult = _evalJs(jsCode, result);
      // [PATCH-2] JS 规则求值失败（返回空）时不能静默继续：
      // 空 URL 会经 _getAbsoluteUrl() 回退成 baseUrl（站点首页），把
      // 「规则失败」伪装成「搜索成功」—— 用户会拿到一批与关键词无关的
      // 首页推荐条目（实测：思路客搜「剑来」返回首页推荐）。
      // 仅在「带关键词的 URL」（搜索/分类）上抛错，避免影响正文/下一页
      // 这类「返回空 = 没有下一页」的正常语义。
      if (jsResult.trim().isEmpty &&
          jsCode.trim().isNotEmpty &&
          (key?.isNotEmpty ?? false)) {
        final brief = jsCode.replaceAll('\n', ' ').trim();
        final shown = brief.length > 80 ? brief.substring(0, 80) + '…' : brief;
        throw Exception('书源搜索 JS 规则求值失败（返回空 URL）：$shown');
      }
      result = jsResult;
      start = match.end;
    }

    if (url.length > start) {
      final segment = url.substring(start).trim();
      if (segment.isNotEmpty) {
        result = segment.replaceAll('@result', result);
      }
    }

    url = result;
  }

  void replaceKeyPageJs() {
    if (url.contains('{{') && url.contains('}}')) {
      final jsPattern = RegExp(r'\{\{([\w\W]*?)\}\}');
      url = url.replaceAllMapped(jsPattern, (match) {
        final expr = match.group(1)!;
        if (expr == 'page') {
          return page.toString();
        }
        if (expr == 'key') {
          // 占位符替换为「原始关键词」而非预编码值：编码统一延迟到
          // [analyzeUrl] 之后按源声明的 charset 处理（GBK 站点按 GBK 编码，
          // 其余按 UTF-8），避免 GBK 站点收到 UTF-8 乱码而搜索无结果。
          return key ?? '';
        }
        final jsResult = _evalJs(expr, url);
        return jsResult;
      });
    }

    // 通用书源格式兼容：搜索/发现 URL 普遍使用尖括号占位符
    // `<searchKey>`/`<key>`/`<page>`（部分老源用中文书名号《searchKey》/《page》）。
    // 同样替换为原始关键词，编码延后统一处理。
    if (key != null && key!.isNotEmpty) {
      url = url
          .replaceAll('<searchKey>', key!)
          .replaceAll('<key>', key!)
          .replaceAll('《searchKey》', key!)
          .replaceAll('《key》', key!);
    }
    url = url.replaceAll('<page>', page.toString());
    url = url.replaceAll('《page》', page.toString());

    // 老式扁平书源的 `ruleSearchUrl` 用裸占位符 `searchKey` / `searchPage`
    // （如 `https://m.manhuagui.com/s/searchKey.html`）。漫画链路没有
    // Node 侧的归一化，这里补上，否则扁平源搜索会请求到字面量地址。
    if (key != null && key!.isNotEmpty) {
      url = url.replaceAll('searchKey', key!);
    }
    url = url.replaceAll('searchPage', page.toString());

    // 兜底：确保任何残留的 {{key}}/{{page}} 被替换（极少见，
    // 仅当上面的正则未覆盖时触发）。
    if (key != null && key!.isNotEmpty) {
      url = url.replaceAll('{{key}}', key!);
    }
    url = url.replaceAll('{{page}}', page.toString());
  }

  // ── [PATCH-1] URL 选项宽松解析 ────────────────────────────────
  // 通用书源（legado 系）普遍用单引号写选项：
  //   `...,{'method':'POST','body':'submit=搜索&keyword={{key}}&json=1'}`
  // 严格 json.decode 会抛 FormatException，被上层 catch 静默吞掉 →
  // method/body/charset/headers 全部丢失（POST 降级为 GET，
  // 表现为「搜索永远无结果」或站点直接 404/405）。
  static Map<String, dynamic>? decodeLooseOptionMap(String s) {
    Object? first;
    try {
      first = json.decode(s);
    } catch (_) {
      first = null;
    }
    if (first is Map) {
      return first.map((k, v) => MapEntry(k.toString(), v));
    }
    try {
      final second = json.decode(_singleQuotesToJson(s));
      if (second is Map) {
        return second.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}
    return null;
  }

  /// 把 JS/legado 风格的单引号对象字面量转成合法 JSON。
  /// 只处理引号（不做键名去引号、不做尾逗号），避免过度改写源语义。
  static String _singleQuotesToJson(String s) {
    final sb = StringBuffer();
    var inSingle = false;
    var inDouble = false;
    var escaped = false;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (escaped) {
        sb.write(c);
        escaped = false;
        continue;
      }
      if (c == '\\') {
        sb.write('\\');
        escaped = true;
        continue;
      }
      if (inSingle) {
        if (c == "'") {
          sb.write('"');
          inSingle = false;
        } else if (c == '"') {
          sb.write('\\"');
        } else {
          sb.write(c);
        }
        continue;
      }
      if (inDouble) {
        if (c == '"') inDouble = false;
        sb.write(c);
        continue;
      }
      if (c == "'") {
        sb.write('"');
        inSingle = true;
        continue;
      }
      if (c == '"') {
        inDouble = true;
        sb.write(c);
        continue;
      }
      sb.write(c);
    }
    return sb.toString();
  }

  /// 本机回环专用 Dio：**绝不挂用户代理**（127.0.0.1 若走代理会被劫持 ✗），
  /// 且 WebView 首次加载站点可能较慢 ⇒ receiveTimeout 放宽。
  static final Dio _localDio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 90),
    responseType: ResponseType.plain,
    validateStatus: (_) => true,
  ));

  /// 普通 Dio 请求：发请求 → 按源声明 charset 解码 → 状态码/重定向收尾。
  /// 正文作为返回值（重定向时同步更新本实例的 [url]）。
  Future<String> _requestViaDio(Dio dio, Options options) async {
    final Response<List<int>> response;
    if (method?.toUpperCase() == 'POST') {
      response = await dio.post<List<int>>(
        url,
        data: body,
        options: options,
      );
    } else {
      response = await dio.get<List<int>>(
        url,
        options: options,
      );
    }

    final bytes = Uint8List.fromList(response.data ?? <int>[]);
    final contentType = _extractHeaderValue(
      response.headers['content-type'],
    );
    final effectiveCs = _normalizeCharset(charset) ??
        _extractCharsetFromContentType(contentType) ??
        _extractCharsetFromMeta(bytes);
    final decoded = _decodeBody(bytes, charset, contentType);
    AppLog.instance.d(
        '[书源HTTP] ← ${response.statusCode} ${decoded.length}字符 '
        'charset=${effectiveCs ?? 'utf8-容错'}');

    if (response.statusCode != null && response.statusCode! >= 400) {
      throw Exception('请求失败：HTTP ${response.statusCode}，URL：$url');
    }
    if (response.redirects.isNotEmpty) {
      url = response.redirects.last.location.toString();
    }
    return decoded;
  }

  /// 经**主 isolate 的本机代理**用真浏览器栈抓「渲染后 HTML」。
  ///
  /// 为什么不能直接调 `WebViewImageFetcher`：本类跑在 worker isolate，
  /// 而 WebView 是平台视图（只能在主 isolate 创建/驱动）⇒ 必须转一手。
  /// 通道与 `java.ajax` 完全一致（见 `sync_http_bridge.dart` / `http_proxy.dart`）。
  /// ⚠️ **不抛异常**：任何失败都返回空串，由调用方回退普通请求 ✓
  ///（见请求处的回退分支 —— WebView 不可用不该让整章没内容）。
  Future<String> _fetchViaWebView(String target) async {
    final port = SyncHttpBridge.proxyPort;
    if (port <= 0) {
      AppLog.instance.w('[书源HTTP] webView 跳过：本机代理未就绪');
      return '';
    }
    try {
      final resp = await _localDio.get<String>(
        'http://127.0.0.1:$port/',
        options: Options(headers: <String, String>{
          'x-legado-url': target,
          'x-legado-method': 'GET',
          'x-legado-browser': 'fetch',
        }),
      );
      // 代理把失败原因放在 `x-legado-error-b64`（纯 ASCII 头）
      final errB64 = resp.headers.value('x-legado-error-b64');
      if (errB64 != null && errB64.isNotEmpty) {
        final msg = utf8.decode(base64.decode(errB64), allowMalformed: true);
        AppLog.instance.w('[书源HTTP] webView 失败: $msg');
        return '';
      }
      return resp.data ?? '';
    } catch (e) {
      AppLog.instance.w('[书源HTTP] webView 异常: $e');
      return '';
    }
  }

  void analyzeUrl() {
    final originalUrl = url;
    final paramPattern = RegExp(r',\s*\{');
    final paramMatch = paramPattern.firstMatch(originalUrl);
    final urlNoOption = paramMatch != null ? originalUrl.substring(0, paramMatch.start) : originalUrl;

    // 基础 URL（去选项）：后续选项中的 js 可整体改写 url。
    url = urlNoOption;

    if (paramMatch != null && urlNoOption.length != originalUrl.length) {
      final optionStr = originalUrl.substring(paramMatch.end - 1);
      try {
        final option = decodeLooseOptionMap(optionStr);
        if (option != null) {
          method = option['method']?.toString();
          // body 可为字符串或 JSON 对象/数组（QQ 等 API 源的
          // `"body":{"key":"{{key}}"}` 写法）：对象须按 JSON 序列化，
          // 此前 toString() 产出 Dart Map 字面量 `{key: value}` 导致服务端
          // 解析失败 → API 型源搜索全空。
          final rawBody = option['body'];
          if (rawBody is String) {
            body = rawBody;
          } else if (rawBody != null) {
            body = jsonEncode(rawBody);
          }
          charset = option['charset']?.toString();
          retry = option['retry'] ?? 0;
          // 🔴 legado 的键是 **`webView`**（不是 `useWebView`）—— 实测内置源都写
          //   `,{'webView': true}` / `,{'webView':true}` ✗，原来只读 `useWebView`
          //   ⇒ 这个声明**从未生效**（WebView 抓取形同虚设）✗。两个键都认 ✓
          final wv = option['webView'] ?? option['useWebView'];
          useWebView = wv == true || '${wv ?? ''}'.toLowerCase() == 'true';
          webViewDelayTime =
              int.tryParse('${option['webViewDelayTime'] ?? ''}') ?? 0;
          webJs = option['webJs']?.toString();
          bodyJs = option['bodyJs']?.toString();
          dnsIp = option['dnsIp']?.toString();
          requestType = option['type']?.toString();

          final headers = option['headers'] as Map<String, dynamic>?;
          if (headers != null) {
            for (final entry in headers.entries) {
              headerMap[entry.key.toString()] = entry.value.toString();
            }
          }

          final js = option['js']?.toString();
          if (js != null && js.isNotEmpty) {
            final jsResult = _evalJs(js, urlNoOption);
            url = jsResult;
          }
        }
      } catch (e) {
        // [PATCH-1] 不再静默：选项解析失败意味着 method/body/charset/headers
        // 全丢，必须留痕（设置 → 高级 → 运行日志）。
        AppLog.instance.w('[书源URL] 选项解析异常已忽略: $e');
      }
    }

    // 参数编码必须在 Uri 绝对化**之前**：Dart 的 Uri.parse/resolve 会把 query
    // 中的非 ASCII 字符自动按 UTF-8 百分号转义，之后再编码就拿到了已被错误
    // 编码的值（GBK 站点无法纠正）。先按源声明 charset 编码完，再绝对化。
    _encodeRequestParams();

    url = _getAbsoluteUrl(url);

    if (url.isNotEmpty) {
      try {
        final uri = Uri.parse(url);
        // [FIX-B03-BASEURL] 不再降级成 `scheme://host`：丢掉 path 后，正文/下一页
        // 规则里以 baseUrl 为基准的相对链接会被绝对化到站点根
        // （`link/2.html` → `http://host/link/2.html`，而非 `/dir/link/2.html`），
        // 表现为目录只有第一页 / 正文 404。保留最终 URL 的完整形式（含 path），
        // 与基类 AnalyzeRule 的 `setBaseUrl(最终 URL)` 语义一致。
        baseUrl = uri.toString();
      } catch (_) {}
    }
  }

  /// 按源声明的字符集对请求参数编码（GET query / POST form）。
  ///
  /// 占位符（`{{key}}` 等）替换的是**原始关键词**，编码统一延迟到此处：
  /// - GBK 系站点（charset=gbk/gb2312/gb18030）按 GBK 编码关键词，
  /// 否则按 UTF-8 —— 此前恒定 UTF-8 预编码，GBK 站点收到乱码导致
  /// 「搜索有请求但永远无结果」。
  /// - POST form 补声明 `application/x-www-form-urlencoded`：多数站点
  /// （尤其 PHP `$_POST`）不按该 Content-Type 解析请求体，缺省时整个
  /// 表单体被服务端丢弃 → POST 搜索全部为空。
  /// - 已编码值（合法 `%XX` 序列）不重复编码，避免把预编码源二次转义。
  void _encodeRequestParams() {
    final cs = _normalizeCharset(charset);
    final isPost = method?.toUpperCase() == 'POST';

    if (isPost) {
      final b = body;
      if (b != null && b.isNotEmpty && !_looksLikeStructuredBody(b)) {
        body = _encodeForm(b, cs);
        headerMap.putIfAbsent(
            'Content-Type', () => 'application/x-www-form-urlencoded');
      } else if (b != null && b.isNotEmpty) {
        // JSON/XML 请求体：按原文发送，仅补 JSON 的 Content-Type。
        if (b.trimLeft().startsWith('{')) {
          headerMap.putIfAbsent('Content-Type', () => 'application/json');
        }
      }
      return;
    }

    // GET：仅编码 query 段（path 由源模板给出，保持原样）。
    final qIdx = url.indexOf('?');
    if (qIdx < 0) return;
    final base = url.substring(0, qIdx);
    final query = url.substring(qIdx + 1);
    if (query.isEmpty) return;
    // 全部为可见 ASCII（无中文/空格等需编码字符）时无需处理。
    final needsEncode =
        query.codeUnits.any((c) => c > 0x7e || c < 0x20);
    if (!needsEncode) return;
    url = '$base?${_encodeForm(query, cs)}';
  }

  /// JSON / XML 请求体判定（这类体不做 form 编码，按原文发送）。
  bool _looksLikeStructuredBody(String b) {
    final t = b.trimLeft();
    return t.startsWith('{') || t.startsWith('[') || t.startsWith('<');
  }

  /// form 编码：按 `&`/`=` 拆分键值对，逐个值按 [charsetLower] 编码。
  String _encodeForm(String form, String? charsetLower) {
    final out = <String>[];
    for (final pair in form.split('&')) {
      final eq = pair.indexOf('=');
      if (eq < 0) {
        out.add(_encodeValue(pair, charsetLower));
        continue;
      }
      out.add('${_encodeValue(pair.substring(0, eq), charsetLower)}'
          '=${_encodeValue(pair.substring(eq + 1), charsetLower)}');
    }
    return out.join('&');
  }

  /// 单值编码：已编码值原样保留；GBK 系按 GBK，其余 UTF-8。
  String _encodeValue(String value, String? charsetLower) {
    if (value.isEmpty) return value;
    if (_isAlreadyEncoded(value)) return value;
    final lower = charsetLower?.toLowerCase();
    if (lower == 'gbk' || lower == 'gb2312' || lower == 'gb18030') {
      try {
        return _percentEncodeBytes(gbk.encode(value));
      } catch (_) {
        // GBK 编码失败（生僻字等）回退 UTF-8。
      }
    }
    return Uri.encodeComponent(value);
  }

  /// 已编码判定：仅含未保留字符与合法 `%XX` 序列。
  bool _isAlreadyEncoded(String value) {
    for (var i = 0; i < value.length; i++) {
      final c = value.codeUnitAt(i);
      final unreserved = (c >= 0x30 && c <= 0x39) ||
          (c >= 0x41 && c <= 0x5a) ||
          (c >= 0x61 && c <= 0x7a) ||
          c == 0x2d || // -
          c == 0x2e || // .
          c == 0x5f || // _
          c == 0x7e; // ~
      if (unreserved) continue;
      if (c == 0x25 && // %
          i + 2 < value.length &&
          _isHexDigit(value.codeUnitAt(i + 1)) &&
          _isHexDigit(value.codeUnitAt(i + 2))) {
        i += 2;
        continue;
      }
      return false;
    }
    return true;
  }

  bool _isHexDigit(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x46) ||
      (c >= 0x61 && c <= 0x66);

  /// 字节序列百分号编码（未保留字符保留原样）。
  String _percentEncodeBytes(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      final unreserved = (b >= 0x30 && b <= 0x39) ||
          (b >= 0x41 && b <= 0x5a) ||
          (b >= 0x61 && b <= 0x7a) ||
          b == 0x2d ||
          b == 0x2e ||
          b == 0x5f ||
          b == 0x7e;
      if (unreserved) {
        sb.writeCharCode(b);
      } else {
        sb.write('%');
        sb.write(b.toRadixString(16).toUpperCase().padLeft(2, '0'));
      }
    }
    return sb.toString();
  }

  String _getAbsoluteUrl(String urlStr) {
    if (urlStr.isEmpty) return baseUrl ?? '';
    if (urlStr.startsWith('http')) return urlStr;
    final base = baseUrl;
    if (base == null || base.isEmpty) return urlStr;
    // ── 伪 URL base（如"光遇聚合"，bookSourceUrl 仅作源标识非真实地址）──
    // 无 scheme 时 `Uri.parse(base).resolve(rel)` 会拼出"光遇聚合/search?..."
    // 这种非法请求。JS 聚合源在规则里自己构造完整 URL，相对路径本就无处
    // 可拼 —— 原样返回，让请求层报清晰错误，而不是拼出四不像的 URL。
    if (!base.startsWith('http://') && !base.startsWith('https://')) {
      return urlStr;
    }
    try {
      return Uri.parse(base).resolve(urlStr).toString();
    } catch (_) {
      return urlStr;
    }
  }

  String _evalJs(String jsCode, String currentResult) {
    try {
      final analyzeRule = AnalyzeRule(book: ruleData, chapter: chapter)
        ..setBaseUrl(baseUrl);
      // URL 内 JS 的宿主绑定（对齐 legado AnalyzeUrl.evalJS）：
      // 分页偏移（`page-1`）、关键词处理等表达式依赖 page/key。
      return analyzeRule.evalJs(jsCode, currentResult, extraBindings: {
        'page': page,
        'key': key ?? '',
        'speakText': speakText ?? '',
      });
    } catch (_) {
      return currentResult;
    }
  }

  bool get _isValidHttpUrl {
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return false;
    }
    try {
      final uri = Uri.parse(url);
      return uri.host.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<String> getStrResponse({
    String? jsStr,
    String? sourceRegex,
    Map<String, String>? headers,
  }) async {
    if (!_isValidHttpUrl) {
      throw Exception('Invalid URL: $url');
    }

    // 最终 UA：默认中心化指纹 UA；若源 header 显式声明 UA（如笔趣阁移动端 UA），
    // 则改用源的 UA——移动站点加固反爬后会拒绝桌面 UA。
    final effectiveUa = _kDefaultUa;
    final requestHeaders = <String, String>{
      'User-Agent': effectiveUa,
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Referer': source?.bookSourceUrl ?? baseUrl ?? url,
    };

    if (source?.header != null && source!.header!.isNotEmpty) {
      try {
        final sourceHeader = _parseHeader(source!.header!);
        // 源 header 的 User-Agent 必须生效（尊重「源即插件」：源作者配的 UA 即意图）。
        // 提取后按 host 注册到 HttpFetcher，使 WebView 验证复用同一 UA。
        String? sourceUa;
        for (final key in sourceHeader.keys.toList()) {
          if (key.toLowerCase() == 'user-agent') {
            sourceUa = sourceHeader.remove(key);
            break;
          }
        }
        if (sourceUa != null && sourceUa.isNotEmpty) {
          requestHeaders['User-Agent'] = sourceUa;
        }
        requestHeaders.addAll(sourceHeader);
      } catch (_) {}
    }

    // URL 选项 headers（书源 searchUrl 的 `,{"headers":{...}}` 声明 + POST
    // Content-Type 补全）此前从未并入实际请求，源声明的请求头全部丢失；
    // 此处统一并入（选项头在源 header 之后、显式 headers 参数之前生效）。
    if (headerMap.isNotEmpty) {
      requestHeaders.addAll(headerMap);
    }

    if (headers != null) {
      requestHeaders.addAll(headers);
    }

    // 请求头变量替换：legado 允许头值里写 `{{key}}` / `{{page}}` / `{{变量}}`
    // （变量来自书源级存储 `source.setVariable` / `putConcurrent`）。
    // 此前头值原样发送 ⇒ 含占位符的头（如 `Referer: {{$.url}}`）会被站点拒绝。
    // 无 `{{` 的头值原样返回（未配置该项的源行为完全不变）。
    requestHeaders.updateAll((key, value) => _applyHeaderVars(value));

    String body;
    try {
      // 源级限流（Legado `concurrentRate`）：`N` = 最小间隔 N 毫秒，
      // `N/M` = 任意 M 毫秒内最多 N 次。配置缺省/非法时不做任何等待。
      await SourceRateLimiter.instance.acquire(
        (source?.bookSourceUrl ?? baseUrl ?? '').trim(),
        source?.concurrentRate,
      );
      // 书源链路用独立 Dio，背靠背连发可能触发 Cloudflare 临时挑战；
      // 请求间再做一次短节流（与源级限流互补）。
      await Future<void>.delayed(const Duration(milliseconds: 120));
      AppLog.instance.d('[书源HTTP] ${method?.toUpperCase() ?? 'GET'} $url');

      // 代理：源声明的 proxy 字段此前解析但未使用；此处落地——非空时改用带
      // IOHttpClientAdapter(findProxy) 的临时 Dio 发起本次请求，不影响全局默认 Dio。
      final Dio dio = proxy != null && proxy!.isNotEmpty
          ? (Dio()
            ..httpClientAdapter = IOHttpClientAdapter(
              createHttpClient: () {
                final client = HttpClient();
                client.findProxy = (_) => 'PROXY $proxy';
                return client;
              },
            ))
          : _dio;

      final options = Options(
        headers: requestHeaders,
        responseType: ResponseType.bytes,
        validateStatus: (status) => status != null && status >= 200 && status < 300,
      );

      if (useWebView) {
        // ✅ 源声明了 `,{'webView': true}` ⇒ 先用**真浏览器栈**抓渲染后的 HTML
        //   （Cloudflare / 反爬站用 Dio 直连只能拿到挑战页）。
        //   ⚠️ 本类运行在 **worker isolate**，而 WebView 是平台视图（只能主 isolate
        //   驱动）⇒ 转经本机代理（主 isolate），与 `java.ajax` **同一条通道**
        //   （见 http_proxy.dart 的 `x-legado-browser`）。
        body = await _fetchViaWebView(url);
        AppLog.instance.d('[书源HTTP] ← webView ${body.length}字符 $url');
        // 🔴 **WebView 是增强、不是必需**：未挂载 / 超时 / 失败 / 回空正文时
        //   必须回退普通请求 ✗ —— 否则会把「本来用 Dio 能拿到内容」的站
        //   也一起弄成“无内容”（= 在线阅读白屏）✗
        if (body.trim().isEmpty) {
          AppLog.instance.w('[书源HTTP] webView 无内容，回退普通请求: $url');
          body = await _requestViaDio(dio, options);
        } else if (webJs != null && webJs!.isNotEmpty) {
          // [webJs] URL 选项里的 `webJs` 在 WebView 抓取完成后执行，用于改写
          // HTML（legado 在浏览器 DOM 上执行并取其结果作为正文来源）。
          // ⚠️ 本引擎的 WebView 抓取走本机代理（只回渲染后 HTML），没有把 JS
          //    注入浏览器 DOM 的通道 ⇒ 这里用 QuickJS 以 `result=HTML` 求值做
          //    **尽力近似**；执行失败/返回空则保留原 HTML（对未配置 webJs 的源
          //    零影响）。
          final rewritten = _execWebJs(body);
          if (rewritten.trim().isNotEmpty) {
            body = rewritten;
          } else {
            AppLog.instance.w('[书源HTTP] webJs 执行无结果，保留原 HTML: $url');
          }
        }
      } else {
        body = await _requestViaDio(dio, options);
      }

      // 解码后统一检测「验证/反爬挑战页」（覆盖 Cloudflare、以及 PTCMS 等站点
      // 自带的「系统安全验证」等）。命中则抛 [VerificationRequiredException]，
      // 交由既有 WebView 验证回灌流程过验证，而非静默返回空结果或抛普通异常被上层吞掉。
      if (_looksLikeVerificationChallenge(body)) {
        throw VerificationRequiredException(
          url: url,
          body: body,
          statusCode: 200,
        );
      }
    } on DioException catch (e) {
      AppLog.instance.w('[书源HTTP] Dio异常 ${e.response?.statusCode} $url');
      final status = e.response?.statusCode;
      // 非 2xx 也可能是「验证 / 反爬挑战页」：PTCMS「系统安全验证」常以 403
      // 返回挑战 HTML，此时 validateStatus 已拒收、请求体被丢给上层前必须先过
      // 一遍挑战检测；否则异常类型不对（普通 Exception 而非
      // VerificationRequiredException），验证链路不会触发 → 列表空 + 不跳 WebView。
      final errData = e.response?.data;
      if (errData is List<int> && errData.isNotEmpty) {
        final decoded = _decodeBody(
          Uint8List.fromList(errData),
          charset,
          _extractHeaderValue(e.response?.headers['content-type']),
        );
        if (_looksLikeVerificationChallenge(decoded)) {
          throw VerificationRequiredException(
            url: url,
            body: decoded,
            statusCode: status,
          );
        }
      }
      // 状态码 401/403 一律按验证处理（与 VerificationDetector 语义对齐）：
      // CF 临时挑战可能返回短壳/空体 403，不命中挑战特征也必须进验证流程，
      // 否则从历史/浏览任一入口撞 403 都成死错误（无验证入口、一直加载）。
      if (status == 401 || status == 403) {
        throw VerificationRequiredException(
          url: url,
          body: '',
          statusCode: status,
        );
      }
      throw Exception('网络请求失败[$status]：$url，${e.message}');
    } catch (e) {
      // 关键：验证异常必须原样透传，绝不能包成普通 Exception。否则上层
      // VerificationNavigator.isVerificationError 判定失败 → 不跳 WebView，
      // 列表解析空壳 → 没封面、也不触发验证（幻梦ACG _guard 滑块挑战即此坑）。
      if (e is VerificationRequiredException) rethrow;
      throw Exception('网络请求失败：$url，${e.toString()}');
    }

    if (jsStr != null && jsStr.isNotEmpty) {
      try {
        final analyzeRule = AnalyzeRule(book: ruleData, chapter: chapter)
          ..setContent(body, url)
          ..setBaseUrl(url);
        body = analyzeRule.getString(jsStr);
      } catch (_) {}
    }

    if (sourceRegex != null && sourceRegex.isNotEmpty) {
      try {
        final regex = RegExp(sourceRegex, dotAll: true);
        final match = regex.firstMatch(body);
        if (match != null) {
          if (match.groupCount > 0) {
            body = match.group(1) ?? body;
          } else {
            body = match.group(0) ?? body;
          }
        }
      } catch (_) {}
    }

    _applyLoginCheck(body);

    return body;
  }

  // ── 书源级变量键（`source.*` 存储分组，与 AnalyzeRule._sourceKey 同口径）──
  String get _sourceKey {
    final u = source?.bookSourceUrl;
    if (u != null && u.isNotEmpty) return u;
    return baseUrl ?? '';
  }

  /// 请求头值变量替换：`{{key}}` / `{{page}}` / `{{变量}}` / `{{java.get('x')}}`。
  ///
  /// 变量值取自书源级进程存储（`SourceVariableStore`，由规则里的
  /// `source.setVariable` / `putConcurrent` 写入）；未知变量原样保留（避免把
  /// 不含变量的头改坏）。
  String _applyHeaderVars(String value) {
    if (!value.contains('{{')) return value;
    final box = SourceVariableStore.instance.box(_sourceKey);
    return value.replaceAllMapped(RegExp(r'\{\{([\w\W]*?)\}\}'), (m) {
      final expr = m.group(1)!.trim();
      if (expr == 'key') return key ?? '';
      if (expr == 'page') return page.toString();
      // ⚠️ 必须用三引号原始字符串：正则里的 ['\"] 同时含两种引号，
      // 单引号/双引号 raw string 都会被其中的 " 提前终止（编译期语法错误）。
      final get = RegExp(r'''^java\.get\(\s*['"]([^'"]+)['"]\s*\)$''').firstMatch(expr);
      if (get != null) return box[get.group(1) ?? ''] ?? '';
      if (box.containsKey(expr)) return box[expr] ?? '';
      return m.group(0)!;
    });
  }

  /// 执行 URL 选项里的 `webJs`（以 `result`=抓取到的 HTML 求值）。
  /// 失败/异常返回空串，由调用方回退原 HTML。
  String _execWebJs(String html) {
    final js = webJs;
    if (js == null || js.isEmpty) return '';
    try {
      final analyzeRule = AnalyzeRule(book: ruleData, chapter: chapter)
        ..setContent(html, url)
        ..setBaseUrl(url);
      return analyzeRule.evalJs(js, html, extraBindings: {
        'page': page,
        'key': key ?? '',
      });
    } catch (_) {
      return '';
    }
  }

  /// 登录校验标记：校验 JS 返回串命中任一标记即视为「未登录/登录失效」。
  /// 依据 legado `loginCheckJs` 语义（返回结果含“登录/失效”等字样即失效）。
  static const List<String> _kLoginInvalidMarkers = <String>[
    '登录', '登陆', '失效', '未登录', '请先登录', '重新登录',
  ];

  /// 登录校验（`source.loginCheckJs`）：以 `result`=响应体求值该 JS，
  /// 命中 [_kLoginInvalidMarkers] 时记一条 warn。**仅检测 + 记日志**，不改动
  /// 返回值与流程（引擎侧无登录 UI 挂钩，避免误伤正常请求）。
  void _applyLoginCheck(String body) {
    final js = source?.loginCheckJs;
    if (js == null || js.isEmpty) return;
    try {
      final analyzeRule = AnalyzeRule(book: ruleData, chapter: chapter)
        ..setContent(body, url)
        ..setBaseUrl(url);
      final out = analyzeRule
          .evalJs(js, body, extraBindings: {'page': page, 'key': key ?? ''});
      final lower = out.toLowerCase();
      final invalid =
          _kLoginInvalidMarkers.any((mk) => lower.contains(mk.toLowerCase()));
      if (invalid) {
        final brief = out.replaceAll('\n', ' ').trim();
        AppLog.instance.w('[书源] 登录校验：疑似未登录/登录失效'
            '（源=${source?.bookSourceName}）校验结果='
            '${brief.length > 120 ? '${brief.substring(0, 120)}…' : brief}');
      } else {
        AppLog.instance.d('[书源] 登录校验通过（源=${source?.bookSourceName}）');
      }
    } catch (_) {}
  }

  Map<String, String> _parseHeader(String headerStr) {
    final headers = <String, String>{};
    try {
      final decoded = json.decode(headerStr);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          headers[entry.key.toString()] = entry.value.toString();
        }
        return headers;
      }
    } catch (_) {}

    for (final line in headerStr.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final colonIndex = trimmed.indexOf(': ');
      if (colonIndex > 0) {
        final key = trimmed.substring(0, colonIndex).trim();
        final value = trimmed.substring(colonIndex + 1).trim();
        headers[key] = value;
      }
    }
    return headers;
  }

  /// 字符集解码优先级：
  /// 1. URL 选项中的 charset
  /// 2. HTTP Content-Type 中的 charset
  /// 3. HTML `<meta charset="...">` / `<meta http-equiv="Content-Type" ... charset=...>`
  /// 声明（许多 GBK 系站点只写 meta，Content-Type 不带 charset，缺此探测会
  /// 全部按 UTF-8 容错解码 → 中文乱码）
  /// 4. UTF-8 容错解码
  String _decodeBody(Uint8List bytes, String? optionCharset, String? contentType) {
    final effectiveCharset = _normalizeCharset(optionCharset) ??
        _extractCharsetFromContentType(contentType) ??
        _extractCharsetFromMeta(bytes);

    if (effectiveCharset != null) {
      final lower = effectiveCharset.toLowerCase();
      if (lower == 'gbk' || lower == 'gb2312' || lower == 'gb18030') {
        // [FIX-B03-GBK] fast_gbk 的 decode 是**严格**模式：响应体在双字节序列
        // 中间被截断（chunk 边界/代理/上面的接收超时）或出现非法字节就抛
        // FormatException，异常逃到 getStrResponse 的 catch 后被包成
        // 「网络请求失败」，搜索/目录/正文整条链路失败，且看不出是编码问题。
        // 现改为：先按原路径严格解（正常响应结果不变），失败则降级容错解码，
        // 并留一条 debug 日志（字节数 + 前 16 字节 hex）便于定位。
        try {
          return gbk.decode(bytes);
        } catch (e) {
          AppLog.instance.d(
              '[书源GBK] $lower 严格解码失败已降级容错：${bytes.length} 字节 '
              'head=${_hexPreview(bytes)} ($e)');
          try {
            return gbk.decode(bytes, allowMalformed: true);
          } catch (_) {
            return utf8.decode(bytes, allowMalformed: true);
          }
        }
      }
      if (lower == 'big5') {
        // Dart 内置不支持 Big5，先按 UTF-8 容错解码，避免直接崩溃
        return utf8.decode(bytes, allowMalformed: true);
      }
    }

    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 前 16 字节的 hex（配合 [FIX-B03-GBK] 的降级日志定位非法/截断字节）。
  static String _hexPreview(Uint8List bytes) {
    final n = bytes.length < 16 ? bytes.length : 16;
    return bytes
        .sublist(0, n)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
  }

  /// 从 HTML 头部探测 `<meta charset>` / `http-equiv="Content-Type"` 声明的字符集。
  ///
  /// 只扫描前 4KB（charset 声明总在 <head> 开头），按 ASCII 子集读取原始字节
  /// 避免在未解码前引入额外依赖；扫描区即使含非 ASCII 字节也只会被当作
  /// 乱码字符，不影响 charset 关键字匹配。
  static String? _extractCharsetFromMeta(Uint8List bytes) {
    final limit = bytes.length < 4096 ? bytes.length : 4096;
    // 仅取 ASCII 可读字符拼接，中文/双字节原文会被丢弃（charset 关键字是 ASCII）。
    final buf = StringBuffer();
    for (var i = 0; i < limit; i++) {
      final c = bytes[i];
      if (c >= 0x20 && c < 0x7f) {
        buf.writeCharCode(c);
      }
    }
    final head = buf.toString();
    if (!head.contains('charset', 0)) return null;
    // 双引号字符串转义（raw 字符串里 \' 会提前终止字面量）。
    final m = RegExp(
      "charset\\s*=\\s*[\"']?\\s*([a-zA-Z0-9_-]+)",
      caseSensitive: false,
    ).firstMatch(head);
    return m?.group(1)?.trim().toLowerCase();
  }

  String? _normalizeCharset(String? charset) {
    if (charset == null || charset.trim().isEmpty) {
      return null;
    }
    return charset.trim().toLowerCase();
  }

  /// 从 Content-Type 提取 charset，如 `text/html; charset=gbk` -> `gbk`。
  String? _extractCharsetFromContentType(String? contentType) {
    if (contentType == null || contentType.isEmpty) {
      return null;
    }
    final match = RegExp(r'charset\s*=\s*([^\s;]+)', caseSensitive: false)
        .firstMatch(contentType);
    return match?.group(1)?.trim().toLowerCase();
  }

  String? _extractHeaderValue(List<String>? values) {
    if (values == null || values.isEmpty) {
      return null;
    }
    return values.first;
  }

  /// 识别「验证 / 反爬挑战页」（仅挑战页有、正常内容页绝不会出现的特征）。
  ///
  /// 覆盖两类场景：
  /// 1) Cloudflare 挑战页：用精确主动特征（零误杀），正常小说页不可能包含；
  /// 2) 非 Cloudflare 的站点自带验证系统（如 PTCMS 的「系统安全验证」）：
  /// 用「标题/短体验证信号」综合判定，并对弱信号加长度闸门，避免把正常
  /// 大内容页（含 footer「账号安全验证」链接等）误判为验证页。
  ///
  /// 命中即抛 [VerificationRequiredException]，交由既有 WebView 验证回灌流程过验证，
  /// 而非静默返回空结果或抛普通异常被上层吞掉。
  static bool _looksLikeVerificationChallenge(String body) {
    if (body.isEmpty) return false;
    final lower = body.toLowerCase();

    // 1) 精确 Cloudflare 主动特征（零误杀，正常内容页绝不含）。
    const cfMarkers = <String>[
      'just a moment',
      'enable javascript and cookies to continue',
      'cf-mitigated',
      '__cf_chl',
      'attention required! | cloudflare',
    ];
    if (cfMarkers.any(lower.contains)) return true;

    // 2) 通用验证/反爬挑战页识别。
    final title = _extractTitle(lower);
    final titleHasVerify = title.contains('验证') ||
        title.contains('verify') ||
        title.contains('安全验证');

    // 强特征：基本只出现在验证/反爬挑战页（如 PTCMS「系统安全验证」、geetest 滑块）。
    // 这类特征在正常小说列表页极不可能出现，命中即判，不依赖长度闸门。
    const strongBody = <String>[
      '系统安全验证',
      '请完成安全验证',
      '请滑动完成验证',
      '请拖动滑块',
      '人机验证',
      '滑动验证',
      '滑块验证',
      'verify you are human',
      'confirm you are human',
      'secapi',
      'geetest',
      // PTCMS 系「_guard」滑块反爬：真实返回体只有一行
      // `<script src="/_guard/html.js?js=slider_html"></script>`（HTTP 200，
      // 无标题、无「验证」字样）。裸正文不含任何上述特征，故需单独识别其脚本路径。
      // 用 `_guard/` 而非裸 `_guard`，避免误匹配正常页内 `_guardMode` 之类变量。
      '_guard/',
      'slider_html',
    ];
    if (strongBody.any(lower.contains)) return true;

    // 弱特征：可能出现在正常页 footer（如「账号安全验证」链接），仅在页面较小
    // 且标题也带验证词时才判，避免误伤正常大内容页。
    const weakBody = <String>[
      '安全验证',
      '安全校验',
      '验证系统',
      '请验证',
      '滑块',
    ];
    final weakHits = weakBody.where(lower.contains).length;
    final isSmall = body.length <= 65536; // 64KB 长度闸门
    if (isSmall && titleHasVerify && weakHits >= 1) return true;

    return false;
  }

  /// 从 HTML 中提取 <title> 文本（小写），用于验证页标题特征判定。
  static String _extractTitle(String lowerBody) {
    final start = lowerBody.indexOf('<title');
    if (start < 0) return '';
    final gt = lowerBody.indexOf('>', start);
    if (gt < 0) return '';
    final end = lowerBody.indexOf('</title>', gt);
    if (end < 0) return '';
    return lowerBody.substring(gt + 1, end).trim();
  }
}
