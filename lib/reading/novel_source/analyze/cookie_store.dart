/// 书源 Cookie 存储（对应 legado 的 `CookieStore`，在 JS 里暴露为**全局对象
/// `cookie`**，不是 `java.*` 方法）。
///
/// ── 为什么需要它 ─────────────────────────────────────────────
/// 实测 224 条内置书源里，规则串内的 `cookie` 共 6 处，其中 **4 处**用的是
/// legado 的 JS 全局对象：
/// ```js
/// cookie.getKey("http://m.jjwxc.net/...")          // 取该站的登录标识 key
/// cookie.getCookie("https://m.scirym.com/...")     // 取该站的 Cookie 串
/// cookie.setCookie("https://m.scirym.com/...", "…") // 写入 Cookie
/// ```
/// 另外 2 处是 `java.webView(null, url, "document.cookie")`（69书吧），
/// 走的是 WebView 链路（见 `webview_host_*`，尚未实现）。
///
/// **注意**：`java.getCookie` / `java.setCookie` 在这批源里是 **0 处** ——
/// 所以实现目标是**全局 `cookie` 对象**，而不是 `java.*` 方法。
///
/// ── 存储模型 ────────────────────────────────────────────────
/// 按 **host** 分组（`Map<host, Map<name, value>>`），与浏览器/legado 一致：
/// · [getCookie] 按 URL 取该 host 的 `a=b; c=d`；
/// · [setCookie] 接受整串（`a=b; c=d`）或单个 `a=b`，**同 name 覆盖**；
/// · [ingestResponse] 从响应头吸收 `Set-Cookie`（同步 HTTP 桥用）；
/// · [getKey] 是 legado `cookie.getKey(url)` 的**近似实现**（返回 host），
///   用于"同一站点共用登录信息"的键 —— 没逐字对齐 legado 的实现。
///
/// ⚠️ 进程级单例（与 `JsEngine.shared` 的全局 `cookie` 对应）；不持久化到磁盘。
library;

/// 书源 Cookie 存储（进程级单例）。
class SourceCookieStore {
  SourceCookieStore._();
  static final SourceCookieStore instance = SourceCookieStore._();

  /// host → {cookieName: value}
  final Map<String, Map<String, String>> _byHost = <String, Map<String, String>>{};

  /// cookie jar 总开关（对应书源 `enabledCookieJar`）。
  ///
  /// `false` ⇒ **不读、不写、不发送** cookie（对齐 legado 关闭 CookieJar 的
  /// 语义）：[getCookie] 恒返回空串（请求侧据此不再附带 Cookie），
  /// [setCookie]/[ingestResponseHeader]/[removeCookie] 全部 no-op。
  /// 由书源解析入口（`WebBook._bindJsLib`）按**当前源**设置。
  /// 默认 `true` ⇒ 未配置该项的书源行为与从前完全一致。
  bool enabled = true;

  /// 该 host 的 Cookie 是否为空（诊断用）。
  bool isEmptyFor(String url) => (_byHost[_hostOf(url)] ?? const {}).isEmpty;

  void clear() => _byHost.clear();

  /// 当前所有 host（诊断/自测用）。
  List<String> get hosts => _byHost.keys.toList();

  /// 取 [url] 所属 host 的 Cookie 串（`a=b; c=d`；无则空串）。
  String getCookie(String url) {
    if (!enabled) return '';
    final m = _byHost[_hostOf(url)];
    if (m == null || m.isEmpty) return '';
    return m.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// 写入 Cookie。整串（`a=b; c=d`）或单个 `a=b` 都接受。
  ///
  /// 只认含 `=` 且 name 非空且不是 `expires`/`path`/`domain`/`max-age` 这类
  /// **属性片段**（`Set-Cookie` 常用 `; path=/; HttpOnly` 尾巴）。
  void setCookie(String url, String raw) {
    if (!enabled) return;
    if (raw.trim().isEmpty) return;
    final host = _hostOf(url);
    final jar = _byHost.putIfAbsent(host, () => <String, String>{});
    for (final seg in raw.split(';')) {
      final s = seg.trim();
      if (s.isEmpty || !s.contains('=')) continue;
      final i = s.indexOf('=');
      final name = s.substring(0, i).trim();
      final value = s.substring(i + 1).trim();
      if (name.isEmpty) continue;
      final lower = name.toLowerCase();
      if (lower == 'expires' ||
          lower == 'path' ||
          lower == 'domain' ||
          lower == 'max-age' ||
          lower == 'samesite' ||
          lower == 'httponly' ||
          lower == 'secure') {
        continue;
      }
      jar[name] = value;
    }
  }

  /// 从响应头吸收 `Set-Cookie`（可能多条被 `,` 连接，见 [ingestResponseHeader]）。
  void ingestResponseHeader(String url, String? setCookieHeader) {
    if (!enabled) return;
    if (setCookieHeader == null || setCookieHeader.isEmpty) return;
    // 多个 Set-Cookie 常被合并成一个 header，用 ",<name>=" 的形式切分
    final parts = setCookieHeader.split(RegExp(r',(?=\s*[^;=,\s]+=)'));
    for (final p in parts) {
      // 只取第一个 `;` 之前的部分（属性丢弃由 setCookie 处理）
      setCookie(url, p.split(';').first.trim());
    }
  }

  /// 删除该 host 的某个 cookie；[name] 为空则清空该 host。
  void removeCookie(String url, [String? name]) {
    if (!enabled) return;
    final host = _hostOf(url);
    if (name == null || name.isEmpty) {
      _byHost.remove(host);
      return;
    }
    _byHost[host]?.remove(name);
  }

  /// legado `cookie.getKey(url)` 的**近似实现**：返回 host。
  ///
  /// 用途是"同一站点共用登录信息"的键（与 `source.getLoginInfo/putLoginInfo`
  /// 配对）。未逐字对齐 legado 的实现；若某源依赖更细的 key（含路径），
  /// 请以该源的实际期望值为准调整。
  String getKey(String url) {
    final host = _hostOf(url);
    return host.isEmpty ? url : host;
  }

  static String _hostOf(String url) {
    try {
      final u = Uri.parse(url);
      if (u.host.isNotEmpty) return u.host;
    } catch (_) {/* 解析失败 → 落到下面的退化分支 */}
    final m = RegExp(r'^[a-zA-Z][\w+.-]*://([^/?#]+)').firstMatch(url);
    return m?.group(1) ?? url;
  }
}
