/// 书源同步 HTTP 桥（对应上游 2.0.8 的 `book_source/engine/sync_http_bridge.dart`）。
///
/// ── 要解决的问题 ─────────────────────────────────────────────
/// legado 规则里的 `java.ajax(url)` 必须**同步**拿到响应体：
///     `<js>java.ajax(baseUrl + "/search.php?q=" + key)</js>`
/// 而 Dart 的常规 HTTP（dio/http）是异步的，同步 JS 求值里拿不到。
///
/// ── 上游怎么做的 ─────────────────────────────────────────────
/// 自 fork 的 quickjs（native 支持同步 XHR）+ 本机 loopback 服务器
/// （`127.0.0.1` + 端口 + 密码），JS 侧 `syncGet(url)` 同步打过去。
///
/// ── 本文件怎么做（等价、且不需要改 native）───────────────────
/// 1. JS 预置脚本里的 `java.ajax(url)` 先查注入的 `httpCache`；
/// 2. 未命中 → `throw '__LEGADO_NEED__' + JSON`（协议见 [pendingRequest]）；
/// 3. 本文件用 `sync_http` 的 `SyncHttpClient` **同步**抓取（纯 Dart 阻塞 socket）；
/// 4. 结果写回 `cache` → 调用方重新 evaluate，直到没有未命中。
///    （调用方见 `analyze_rule.dart` 的 `_evalJs` 重放循环）
///
/// ── ⚠️ 必须有 worker isolate ────────────────────────────────
/// [fetch] 会**阻塞当前 isolate**（同步 socket）。因此书源求值必须跑在
/// worker isolate 里（对应上游 `web_book/runner_pool.dart` +
/// `killable_isolate.dart` 的语义）；否则会卡住 UI。
/// 另外 `sync_http` 不提供超时，网络挂死时唯一兜底是**杀掉该 isolate**
/// （这正是上游为什么要有 `killable_isolate`）。
///
/// ── 与上游的差异（如实标注）─────────────────────────────────
/// · 上游：JS 主动同步拉（native 阻塞）；本实现：Dart 驱动重放（结果等价）。
/// · 上游一次 eval 内可发任意多次 ajax；本实现每轮只处理**一个**未命中 URL，
///   因此含 N 个 ajax 的脚本最多需要 N+1 轮 eval（已按 URL+方法+body 缓存，
///   重复请求不会重复抓）。
library;

import 'dart:convert';

import 'package:sync_http/sync_http.dart';

import 'cookie_store.dart';

/// 默认 UA（与 analyze_url.dart 的兜底 UA 保持一致）。
const String _kDefaultUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/// 兜底超时：`sync_http` 不支持超时，这里只作为日志提示用（见 [fetch] 注释）。
const Duration kSyncHttpTimeoutWarning = Duration(seconds: 30);

/// JS 侧标记前缀（与 `legado_java_prelude.dart` 里的字符串必须完全一致）。
const String kLegadoNeedPrefix = '__LEGADO_NEED__';

/// 一次待抓请求（由 JS 通过标记抛出，Dart 解析得到）。
class SyncNeeds {
  const SyncNeeds({
    required this.key,
    required this.method,
    required this.url,
    required this.headers,
    required this.body,
    this.binary = false,
  });

  /// 缓存键（JS 侧构造，Dart 原样使用，保证两边一致）
  final String key;
  final String method;
  final String url;
  final Map<String, String> headers;
  final String? body;

  /// true = 需要**原始字节**（`java.getByteArray`）：代理回 base64，
  /// 而不是按 charset 解码后的文本。
  final bool binary;

  @override
  String toString() => 'SyncNeeds($method $url)';
}

/// 同步 HTTP 桥（进程级单例）。
///
/// 缓存跨轮次、跨规则复用 —— 同一 URL 在一次书源求值里只会真正抓一次。
class SyncHttpBridge {
  SyncHttpBridge._();
  static final SyncHttpBridge instance = SyncHttpBridge._();

  /// 注入给 JS 的缓存对象：key → 响应体字符串，或 `{'__error': msg}`。
  final Map<String, Object?> cache = <String, Object?>{};

  /// **同步抓取闸门**：只有当前 isolate 是 worker isolate 时才允许真正发请求。
  ///
  /// 为什么默认 false ✗：`SyncHttpClient` 是**阻塞 socket** 调用，在主 isolate 上
  /// 会卡住 UI；最坏情况（网络挂死且 `sync_http` 无超时能力）会触发系统 watchdog
  /// 把 App 杀掉（iOS 0x8badf00d 一类）。因此：
  ///   · 默认 false ⇒ [fetch] **不真发请求**，写入 `{'__error': '需要 worker isolate'}`，
  ///     规则**明确失败并留日志**，不会把 App 卡死；
  ///   · worker isolate 启动后由该 isolate 置为 true
  ///     （对应上游 `web_book/runner_pool.dart` + `killable_isolate.dart` 语义）。
  static bool allowBlockingOnCurrentIsolate = false;

  void clear() => cache.clear();

  /// 从 `JsEngine.lastError` 里解析待抓请求；没有标记时返回 null。
  ///
  /// 协议（JS 侧构造，见 `legado_java_prelude.dart`）：
  ///   `__LEGADO_NEED__{"k":key,"m":method,"u":url,"h":{...},"b":body}`
  static SyncNeeds? pendingRequest(String? errorText) {
    if (errorText == null || errorText.isEmpty) return null;
    final i = errorText.indexOf(kLegadoNeedPrefix);
    if (i < 0) return null;
    final raw = errorText.substring(i + kLegadoNeedPrefix.length).trim();
    // 错误文本可能被 JsEngine 加了前缀/后缀，这里取第一个完整 JSON 对象
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final m = jsonDecode(raw.substring(start, end + 1));
      if (m is! Map) return null;
      final key = m['k']?.toString() ?? '';
      var url = m['u']?.toString() ?? '';
      if (key.isEmpty || url.isEmpty) return null;
      var method = (m['m']?.toString() ?? 'GET').toUpperCase();
      var headers = _asStringMap(m['h']);
      var body = m['b']?.toString();
      // Legado 的 `java.ajax('url,{"method":"POST","body":"a=1"}')` 写法：
      // 地址后面跟请求描述（清渠社的蓝奏云接口就这么写）。以前整串当 URL
      // 直接发给代理 ⇒ 必然失败。
      final spec = _splitSpec(url);
      if (spec != null) {
        url = spec.url;
        if (spec.method.isNotEmpty) method = spec.method;
        if (spec.body.isNotEmpty) body = spec.body;
        headers = {...headers, ...spec.headers};
      }
      return SyncNeeds(
        key: key,
        method: method,
        url: url,
        headers: headers,
        body: body,
        binary: '${m['x'] ?? ''}' == 'b64',
      );
    } catch (_) {
      return null;
    }
  }

  static Map<String, String> _asStringMap(Object? raw) {
    if (raw is! Map) return const {};
    return raw.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
  }

  /// 拆 `地址,{"method":"POST","body":"…","headers":{…}}`（Legado 写法）。
  static ({String url, String method, String body, Map<String, String> headers})?
      _splitSpec(String raw) {
    final m = RegExp(r'^([\s\S]*?),\s*(\{[\s\S]*\})$').firstMatch(raw.trim());
    if (m == null) return null;
    try {
      final d = jsonDecode(m.group(2)!);
      if (d is! Map) return null;
      final hs = <String, String>{};
      final bh = d['headers'] ?? d['header'];
      if (bh is Map) bh.forEach((k, v) => hs['$k'] = '$v');
      // `params` 是 Legado 的另一种写法（GET 拼查询串 / POST 表单），
      // 这里按表单正文处理，避免参数丢失。
      var body = (d['body'] ?? '').toString();
      final params = d['params'];
      if (body.isEmpty && params is Map && params.isNotEmpty) {
        body = params.entries
            .map((e) => '${Uri.encodeQueryComponent('${e.key}')}='
                '${Uri.encodeQueryComponent('${e.value}')}')
            .join('&');
      }
      return (
        url: m.group(1)!.trim(),
        method: (d['method'] ?? '').toString().trim().toUpperCase(),
        body: body,
        headers: hs,
      );
    } catch (_) {
      return null;
    }
  }

  /// **同步**抓取 [need]，结果写入 [cache]（成功=响应体字符串；失败=`{'__error': ...}`）。
  ///
  /// 恒返回 true：即使失败也已写进缓存，目的是让调用方的重放循环前进
  /// （否则同一 URL 会被无限重试）。真正的失败由 JS 侧读到 `__error` 后抛出。
  /// 本机同步代理端口（由 `BookSourceRunner` 在**主 isolate** 启动后传进 worker）。
  ///
  /// 0 表示未就绪 ⇒ **不真发请求**并写入可读错误，而不是直连目标站 ——
  /// 因为 `sync_http` 无法做 TLS/chunked（见 http_proxy.dart 的说明），直连等于必然失败。
  static int proxyPort = 0;

  bool fetch(SyncNeeds need) {
    if (cache.containsKey(need.key)) return true;
    if (!allowBlockingOnCurrentIsolate) {
      // 闸门关闭：不阻塞、不卡 UI，明确失败并留痕（见字段注释）
      cache[need.key] = {
        '__error': '同步抓取被闸门拦截：需在 worker isolate 中求值'
            '（见 sync_http_bridge.dart 的 allowBlockingOnCurrentIsolate）',
      };
      return true;
    }
    if (proxyPort <= 0) {
      cache[need.key] = {
        '__error': '本机同步代理未就绪：需先 LegadoHttpProxy.ensureStarted()'
            '（在主 isolate）并把端口传给 worker',
      };
      return true;
    }
    // ⚠️ 已知限制：sync_http 无超时能力，挂死的 socket 会一直阻塞本 isolate。
    //    但真实请求由主 isolate 的代理用 Dio 完成（connect 15s / receive 30s），
    //    所以正常情况下不会无限等；最后兜底仍是 worker 层的"杀 isolate"。
    try {
      final proxyUri = Uri.parse('http://127.0.0.1:$proxyPort/');
      final req = need.method == 'POST'
          ? SyncHttpClient.postUrl(proxyUri)
          : SyncHttpClient.getUrl(proxyUri);
      // 协议头：目标 URL 与方法（放头里，避免 URL 编码问题）
      req.headers.set('x-legado-url', need.url);
      req.headers.set('x-legado-method', need.method);
      if (need.binary) req.headers.set('x-legado-binary', '1');
      need.headers.forEach((k, v) {
        if (k.trim().isNotEmpty) req.headers.set(k, v);
      });
      if (!need.headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
        req.headers.set('user-agent', _kDefaultUa);
      }
      // [PATCH-15] 未显式带 Cookie 时，带上 cookie 存储里该 host 的 Cookie
      if (!need.headers.keys.any((k) => k.toLowerCase() == 'cookie')) {
        final jar = SourceCookieStore.instance.getCookie(need.url);
        if (jar.isNotEmpty) req.headers.set('cookie', jar);
      }
      final body = need.body;
      if (body != null && body.isNotEmpty) req.write(body);

      final resp = req.close();
      // 代理的错误信息走 base64（头值必须是可见 ASCII）
      final errB64 = resp.headers.value('x-legado-error-b64');
      final proxyErr = (errB64 == null || errB64.isEmpty)
          ? null
          : utf8.decode(base64.decode(errB64), allowMalformed: true);
      // 用**最终 URL**（代理已跟随重定向）落 cookie
      final finalUrl = resp.headers.value('x-legado-final-url') ?? need.url;
      SourceCookieStore.instance.ingestResponseHeader(
          finalUrl, resp.headers['set-cookie']?.join(', '));
      if (proxyErr != null && proxyErr.isNotEmpty) {
        cache[need.key] = {'__error': proxyErr};
        return true;
      }
      // 代理已把正文按目标站 charset 解码并重新以 UTF-8 回传
      // ⇒ sync_http 的 UTF-8 解码拿到的就是正确文本（GBK 站点也通）
      cache[need.key] = resp.body ?? '';
      return true;
    } catch (e) {
      cache[need.key] = {'__error': '$e'};
      return true;
    }
  }}
