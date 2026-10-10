/// legado 宿主对象 `java` / `source` 的纯 JS 预置实现（含**两类**宿主协议）。
///
/// ── 为什么需要它 ──────────────────────────────────────────────
/// 通用书源（legado 系）的 `@js` 规则大量调用 `java.*`。实测 224 条内置书源里
/// 共 **475 次 `java.*` 调用 / 33 种方法**，高频前几名：
/// `java.getString`(122 次/26 条源)、`java.log`(70)、`java.get`(52)、
/// `java.ajax`(45)、`java.put`(28)、`java.toast`(16)、`java.base64Encode`(14)、
/// `java.timeFormat`(13)、`java.hexDecodeToString`(13)、`java.toNumChapter`(9)、
/// `java.getElements`(9)、`java.base64Decode`(7)、`java.getElement`(7)、
/// `java.t2s`(7)、`java.base64DecodeToByteArray`(6)、`java.createSymmetricCrypto`(6)、
/// `java.md5Encode`(6)、`java.webView`(5)、`java.encodeURI`(5)…
/// 另有 `source.*` 9 种成员（`getVariable` 16 次、`getKey` 13 次、`setVariable` 5 次…）。
///
/// ── 两类协议（成对文件见括号）────────────────────────────────
/// **① 同步 HTTP**（`sync_http_bridge.dart`）：`java.ajax/get/post/…`
///    JS 查注入的 `httpCache` → 未命中抛 `__LEGADO_NEED__{k,m,u,h,b}`
///    → Dart 用 `SyncHttpClient` 同步抓 → 写缓存 → 重跑。
///
/// **② 宿主调用**（`host_bridge.dart`）：`java.getString/get/md5Encode/…`、`source.*`
///    JS 查注入的 `hostCache` → 未命中抛 `__LEGADO_CALL__{k,o,a}`
///    → Dart 分发（`analyze_rule.dart` 的 `_dispatchHostCall`）→ 写缓存 → 重跑。
///
/// 选"抛标记 + 重跑"而非参考实现（`legado-flutter` 的 `onMessage('java.xxx')`）
/// 的异步回调：本引擎规则求值是**同步**的，异步回调无法在同步栈里还回结果。
///
/// ── 明确未实现（显式抛错，不再静默返回空串）──────────────────
/// `aesEncodeToString`、`getByteArray`（二进制通道，P1）、
/// `webView` / `startBrowser(Await)`（人机验证，P3）、`refreshCookie`。
/// ✅ 已实现：`createSymmetricCrypto` / `cryptoOp` / `aesBase64DecodeToString` /
///    `desBase64DecodeToString`（句柄通道，补丁 0012 —— 不再是未实现项）、
///    `getCookie`/`setCookie` 与 JS 全局 `cookie.*`（`cookie_store.dart`，补丁 0015）。
library;

/// 注入 QuickJS 全局作用域的宿主对象脚本（一次性）。
///
/// 用 `r"""..."""` 包裹，脚本内部**只用单引号**，避免出现 `"""` 终止符。
const String legadoJavaPrelude = r"""
// ════ ② 宿主调用辅助（java 与 source 共用；必须在两者之前定义）════
function _legadoHostCall(op, args) {
  var a = args || [];
  var key = op + '|' + JSON.stringify(a);
  var box = (typeof hostCache !== 'undefined' && hostCache) ? hostCache : {};
  if (Object.prototype.hasOwnProperty.call(box, key)) {
    var v = box[key];
    if (v && typeof v === 'object' && v.__error) {
      throw new Error('java.' + op + ' 失败: ' + v.__error);
    }
    return (v === null || v === undefined) ? '' : v;
  }
  throw new Error('__LEGADO_CALL__' + JSON.stringify({ k: key, o: op, a: a }));
}

// ── legado 宿主对象 java（纯 JS + 两类宿主协议）────────────────
var java = (function () {
  var _vars = {};
  var _NEED = '__LEGADO_NEED__';   // ① 同步 HTTP 协议（sync_http_bridge.dart）
  var _b64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  function _log(msg) {
    try {
      if (typeof console !== 'undefined' && console && console.log) {
        console.log(String(msg));
      }
    } catch (e) { /* 无 console 时静默 */ }
  }

  function _err(msg) { throw new Error(msg); }

  function _call(op, args) { return _legadoHostCall(op, args); }

  // ════ ① 同步 HTTP：查 httpCache → 未命中抛标记 ════
  function _http(method, url, headers, body) {
    var m = String(method || 'GET').toUpperCase();
    var u = String(url);
    var key = m + ' ' + u + (body ? ' #' + String(body) : '');
    var box = (typeof httpCache !== 'undefined' && httpCache) ? httpCache : {};
    if (Object.prototype.hasOwnProperty.call(box, key)) {
      var v = box[key];
      if (v && typeof v === 'object' && v.__error) {
        _err('java.' + m.toLowerCase() + ' 失败: ' + v.__error);
      }
      return (v === null || v === undefined) ? '' : v;
    }
    _err(_NEED + JSON.stringify({
      k: key, m: m, u: u, h: headers || null, b: body || null
    }));
  }

  // ════ ② 浏览器栈（协议同 java.ajax：抛标记 → 主 isolate 代理代劳 → 重放）════
  //   mode: 'fetch' 回渲染后 HTML；'open' 打开内置浏览器（不阻塞）
  function _browser(url, mode) {
    var key = 'BROWSER ' + mode + ' ' + String(url);
    var box = (typeof httpCache !== 'undefined' && httpCache) ? httpCache : {};
    if (Object.prototype.hasOwnProperty.call(box, key)) {
      var v = box[key];
      if (v && typeof v === 'object' && v.__error) {
        _err('java.浏览器调用失败: ' + v.__error);
      }
      return (v === null || v === undefined) ? '' : v;
    }
    _err(_NEED + JSON.stringify({
      k: key, m: 'BROWSER', u: String(url),
      h: { 'x-legado-browser': mode }, b: null
    }));
  }

  // ════ 纯 JS 工具：UTF-8 / base64 / hex ════
  function _utf8Bytes(str) {
    var s = String(str), out = [], i, c;
    for (i = 0; i < s.length; i++) {
      c = s.charCodeAt(i);
      if (c < 0x80) {
        out.push(c);
      } else if (c < 0x800) {
        out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
      } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
        var c2 = s.charCodeAt(++i);
        var cp = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00);
        out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
      } else {
        out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      }
    }
    return out;
  }

  function base64Encode(str) {
    var bytes = _utf8Bytes(str), out = '', i = 0;
    while (i < bytes.length) {
      var b1 = bytes[i++];
      var b2 = i < bytes.length ? bytes[i++] : undefined;
      var b3 = i < bytes.length ? bytes[i++] : undefined;
      out += _b64.charAt(b1 >> 2);
      out += _b64.charAt(((b1 & 3) << 4) | (b2 === undefined ? 0 : b2 >> 4));
      out += b2 === undefined ? '=' : _b64.charAt(((b2 & 15) << 2) | (b3 === undefined ? 0 : b3 >> 6));
      out += b3 === undefined ? '=' : _b64.charAt(b3 & 63);
    }
    return out;
  }

  function _b64ToBytes(str) {
    var s = String(str).replace(/[^A-Za-z0-9+/=]/g, ''), bytes = [], i = 0;
    while (i < s.length) {
      var e1 = _b64.indexOf(s.charAt(i++));
      var e2 = _b64.indexOf(s.charAt(i++));
      var c3 = s.charAt(i++), c4 = s.charAt(i++);
      var e3 = (c3 === '=' || c3 === '') ? -1 : _b64.indexOf(c3);
      var e4 = (c4 === '=' || c4 === '') ? -1 : _b64.indexOf(c4);
      if (e1 < 0 || e2 < 0) break;
      bytes.push((e1 << 2) | (e2 >> 4));
      if (e3 >= 0) bytes.push(((e2 & 15) << 4) | (e3 >> 2));
      if (e4 >= 0) bytes.push(((e3 & 3) << 6) | e4);
    }
    return bytes;
  }

  function _bytesToStr(bytes) {
    var out = '', j = 0;
    while (j < bytes.length) {
      var c = bytes[j++];
      if (c < 0x80) {
        out += String.fromCharCode(c);
      } else if (c < 0xe0) {
        out += String.fromCharCode(((c & 31) << 6) | (bytes[j++] & 63));
      } else if (c < 0xf0) {
        out += String.fromCharCode(((c & 15) << 12) | ((bytes[j++] & 63) << 6) | (bytes[j++] & 63));
      } else {
        var cp = ((c & 7) << 18) | ((bytes[j++] & 63) << 12) | ((bytes[j++] & 63) << 6) | (bytes[j++] & 63);
        cp -= 0x10000;
        out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 1023));
      }
    }
    return out;
  }

  function base64Decode(str) { return _bytesToStr(_b64ToBytes(str)); }

  function hexDecodeToString(str) {
    var s = String(str), out = '';
    for (var i = 0; i + 1 < s.length; i += 2) {
      out += String.fromCharCode(parseInt(s.substr(i, 2), 16));
    }
    return out;
  }

  function _pad2(n) { return n < 10 ? '0' + n : '' + n; }

  function timeFormat(ts, fmt) {
    var d = new Date(Number(ts));
    if (isNaN(d.getTime())) return '';
    var map = {
      yyyy: '' + d.getFullYear(), MM: _pad2(d.getMonth() + 1), dd: _pad2(d.getDate()),
      HH: _pad2(d.getHours()), mm: _pad2(d.getMinutes()), ss: _pad2(d.getSeconds())
    };
    var f = String((fmt === undefined || fmt === null || fmt === '') ? 'yyyy-MM-dd HH:mm:ss' : fmt);
    for (var k in map) { if (map.hasOwnProperty(k)) f = f.split(k).join(map[k]); }
    return f;
  }

  // ════ 元素包装：把宿主给的 {t,h,a} 变成 legado 风格对象 ════
  function _wrapElement(v) {
    if (!v || typeof v !== 'object') {
      v = { t: (v === null || v === undefined) ? '' : String(v), h: '', a: {} };
    }
    return {
      _t: v.t || '', _h: v.h || '', _a: v.a || {},
      text: function () { return this._t; },
      ownText: function () { return this._t; },
      html: function () { return this._h; },
      outerHtml: function () { return this._h; },
      toString: function () { return this._h; },
      attr: function (n) { return this._a[String(n)] || ''; },
      hasAttr: function (n) { return Object.prototype.hasOwnProperty.call(this._a, String(n)); },
      select: function () { return null; },
      children: function () { return []; }
    };
  }

  function _unsupported(name) {
    return function () {
      _err('java.' + name + ' 尚未实现（见 legado_java_prelude.dart 的未实现清单）');
    };
  }

  return {
    // ── 跨规则变量（QuickJS 全局持久；JsEngine.shared 进程级复用）──
    put: function (k, v) { _vars[String(k)] = v; },
    get: function (k) {
      var v = _vars[String(k)];
      return (v === undefined || v === null) ? '' : v;
    },
    androidId: 'cmbok-port-android-id',
    // ── 纯 JS 编解码 ──
    base64Encode: base64Encode,
    base64Decode: base64Decode,
    base64DecodeToByteArray: function (s) { return _b64ToBytes(s); },
    hexDecodeToString: hexDecodeToString,
    hexDecode: hexDecodeToString,
    // ── 时间 ──
    timeFormat: timeFormat,
    timeFormatUTC: function (ts, fmt, sh) { return _call('timeFormatUTC', [ts, fmt, sh]); },
    // ── 提示（宿主无 UI 通道时落运行日志）──
    toast: function (m) { _log('[java.toast] ' + m); },
    longToast: function (m) { _log('[java.longToast] ' + m); },
    log: function (m) { _log('[java.log] ' + m); },
    // ── 繁简（宿主已注入 t2s/s2t 预置脚本；缺失时退回宿主调用）──
    t2s: function (s) { return (typeof t2s === 'function') ? t2s(String(s)) : _call('t2s', [s]); },
    s2t: function (s) { return (typeof s2t === 'function') ? s2t(String(s)) : _call('s2t', [s]); },
    // ── 需要 Dart 侧求值/实现的宿主调用 ──
    getString: function (rule, content) { return _call('getString', [rule, content]); },
    getStringList: function (rule) { return _call('getStringList', [rule]); },
    getElement: function (rule) { return _wrapElement(_call('getElement', [rule])); },
    getElements: function (rule) {
      var arr = _call('getElements', [rule]);
      if (!arr || typeof arr.length !== 'number') return [];
      var out = [];
      for (var i = 0; i < arr.length; i++) out.push(_wrapElement(arr[i]));
      return out;
    },
    setContent: function (c) { return _call('setContent', [c]); },
    md5Encode: function (s) { return _call('md5Encode', [s]); },
    md5Encode16: function (s) { return _call('md5Encode16', [s]); },
    encodeURI: function (s) { return _call('encodeURI', [s]); },
    bytesToStr: function (v) { return _call('bytesToStr', [v]); },
    toNumChapter: function (s) { return _call('toNumChapter', [s]); },
    copyText: function (t) { return _call('copyText', [t]); },
    open: function (u) { return _call('open', [u]); },
    // legado 别名（实测 2 处）：语义同 open
    openUrl: function (u) { return _call('open', [u]); },
    // 标准 v4 UUID（纯 JS，无需宿主）
    randomUUID: function () {
      return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
        var r = Math.random() * 16 | 0;
        var v = c === 'x' ? r : ((r & 0x3) | 0x8);
        return v.toString(16);
      });
    },
    // 以下两个在无 UI/登录通道时按「已忽略」处理（不再抛错中断规则）
    refreshExplore: function () { _log('[java.refreshExplore] 已忽略'); return true; },
    upLoginData: function () { _log('[java.upLoginData] 已忽略（无登录数据通道）'); return true; },
    // ── 同步 HTTP（协议 ①）──
    ajax: function (url) { return _http('GET', url, null, null); },
    get: function (url, headers) { return _http('GET', url, headers, null); },
    post: function (url, body, headers) { return _http('POST', url, headers, body); },
    head: function (url) { return _http('HEAD', url, null, null); },
    getStrResponse: function (url) { return _http('GET', url, null, null); },
    connect: function (url) { return _http('GET', url, null, null); },
    connectStr: function (url) { return _http('GET', url, null, null); },
    getResponse: function (url) { return _http('GET', url, null, null); },
    // 并发取多个 URL 的正文数组（实测 1 处）。本引擎求值是**同步重放**的
    //（见文件头），故按顺序发即可 —— 每次 _http 未命中都会抛
    // __LEGADO_NEED__ 由 Dart 侧取数后重放。
    ajaxAll: function (urls) {
      var out = [];
      if (urls && typeof urls.length === 'number') {
        for (var i = 0; i < urls.length; i++) {
          out.push(_http('GET', String(urls[i]), null, null));
        }
      }
      return out;
    },
    // ── 未实现（显式抛错，留日志线索）──
    getByteArray: _unsupported('getByteArray'),
    // ── 对称加密（句柄通道：createSymmetricCrypto → cryptoOp）──
    // Dart 侧 createSymmetricCrypto 返回 {'__handle': id}，这里取出 id 供后续
    // cryptoOp(handle, op, data) 使用（与 analyze_rule 的既有契约一致）。
    createSymmetricCrypto: function (algorithm, key, iv, mode) {
      var r = _call('createSymmetricCrypto', [algorithm, key, iv, mode]);
      if (r && typeof r === 'object' && r.__handle !== undefined) return r.__handle;
      return r;
    },
    cryptoOp: function (handle, op, data) {
      return _call('cryptoOp', [handle, op, data]);
    },
    aesBase64DecodeToString: function (data, key, mode, iv) {
      return _call('aesBase64DecodeToString', [data, key, mode, iv]);
    },
    desBase64DecodeToString: function (data, key, mode, iv) {
      return _call('desBase64DecodeToString', [data, key, mode, iv]);
    },
    aesEncodeToString: _unsupported('aesEncodeToString'),
    // ── 浏览器栈（实测 10 处 startBrowserAwait + 1 处 webView）──
    // legado 语义：webView(content, url, js) 用 WebView 加载 url（可注入 js）
    // 后返回结果；未传 content 时按 url 加载。
    // ⚠️ 我们回的是**渲染后 HTML**（注入 js 暂不支持 —— 见 http_proxy 的说明）。
    webView: function (content, url, js) {
      var target = (url === null || url === undefined || url === '') ? String(content) : String(url);
      return _browser(target, 'fetch');
    },
    // 打开内置浏览器（登录 / 加群 / 通过人机验证），不阻塞求值。
    // startBrowserAwait 在 legado 里会等用户关闭页面，但本引擎的 worker
    // 有 60s 硬超时（超时即杀）⇒ 真阻塞会把整次求值杀掉，故同样不等。
    startBrowser: function (url, title) { return _browser(url, 'open'); },
    startBrowserAwait: function (url, title) { return _browser(url, 'open'); },
    // 实测 0 处使用，但语义与全局 cookie 对象一致 ⇒ 一并接到同一存储
    getCookie: function (url) { return _legadoHostCall('cookie.getCookie', [url]); },
    setCookie: function (url, c) { return _legadoHostCall('cookie.setCookie', [url, c]); },
    refreshCookie: _unsupported('refreshCookie')
  };
})();

// ── source 对象（书源级变量与身份；实测 9 种成员）────────────
var source = {
  getVariable: function () { return _legadoHostCall('source.getVariable', []); },
  setVariable: function (v) { return _legadoHostCall('source.setVariable', [v]); },
  putVariable: function (v) { return _legadoHostCall('source.setVariable', [v]); },
  putConcurrent: function (k, v) { return _legadoHostCall('source.putConcurrent', [k, v]); },
  getLoginInfo: function () { return _legadoHostCall('source.getLoginInfo', []); },
  putLoginInfo: function (v) { return _legadoHostCall('source.putLoginInfo', [v]); },
  removeLoginInfo: function () { return _legadoHostCall('source.removeLoginInfo', []); },
  getLoginHeader: function () { return _legadoHostCall('source.getLoginHeader', []); },
  putLoginHeader: function (v) { return _legadoHostCall('source.putLoginHeader', [v]); },
  removeLoginHeader: function () { return _legadoHostCall('source.removeLoginHeader', []); },
  // ── 🔴 `getLoginInfoMap()`：Legado 的登录信息 **Map 视图** ──────────
  //
  // 实测缺失导致真实书源直接失效：
  //   书源 jsLib 里（如"微信读书二合一本地源"）：
  //     function wrValue(src, name) {
  //         var info = src.getLoginInfoMap();      // ← 原来是个 undefined ✗
  //         var value = info == null ? null : info.get(name);
  //         return value == null ? "" : String(value).trim();
  //     }
  //   ⇒ `TypeError: not a function` ⇒ 整个 searchUrl 求值失败 ⇒ 搜索不可用 ✗
  //
  // ⚠️ Dart 侧 `source.getLoginInfo` 存的是**字符串**
  //   （`_sourceVariables['__login__']`），所以这里不能只转一道手，
  //   必须把字符串**解析成带 `.get(name)` 的视图**再返回 ✓
  //
  // 兼容三种落盘形态：JSON 对象（`{"k":"v"}`）/ URL 编码（`k=v&k2=v2`）/ 空。
  getLoginInfoMap: function () {
    var raw = _legadoHostCall('source.getLoginInfo', []);
    var obj = {};
    if (raw !== null && raw !== undefined && raw !== '') {
      var s = String(raw);
      var parsed = null;
      // ① JSON 形态
      try { parsed = JSON.parse(s); } catch (e) { parsed = null; }
      if (parsed && typeof parsed === 'object' && !(parsed instanceof Array)) {
        obj = parsed;
      } else {
        // ② URL 编码形态（k=v&k2=v2）；③ 其它情况按空处理
        var parts = s.split('&');
        for (var i = 0; i < parts.length; i++) {
          var seg = parts[i];
          if (!seg) continue;
          var eq = seg.indexOf('=');
          var k = eq < 0 ? seg : seg.substring(0, eq);
          var v = eq < 0 ? '' : seg.substring(eq + 1);
          try { k = decodeURIComponent(k); v = decodeURIComponent(v); } catch (e) {}
          if (k) obj[k] = v;
        }
      }
    }
    // ⚠️ 必须给 `.get(name)` —— jsLib 用的就是它（不是 `obj[name]`）✓
    return {
      get: function (name) {
        var key = String(name);
        if (Object.prototype.hasOwnProperty.call(obj, key)) return obj[key];
        try {
          if (typeof Map !== 'undefined' && obj instanceof Map) return obj.get(key);
        } catch (e) {}
        return null;
      },
      has: function (name) {
        return Object.prototype.hasOwnProperty.call(obj, String(name));
      },
      raw: obj
    };
  },
  getKey: function () { return _legadoHostCall('source.getKey', []); },
  key: function () { return _legadoHostCall('source.getKey', []); },
  get bookSourceUrl() { return _legadoHostCall('source.bookSourceUrl', []); },
  get bookSourceComment() { return _legadoHostCall('source.bookSourceComment', []); },
  get header() { return _legadoHostCall('source.header', []); }
};

// ── cookie 全局对象（legado 的 CookieStore；实测 4 处用法）────────
// 用法形如 `cookie.getKey(url)` / `cookie.getCookie(url)` /
// `cookie.setCookie(url, '…')`。注意**不是** `java.*` 方法。
var cookie = {
  getCookie: function (url) { return _legadoHostCall('cookie.getCookie', [url]); },
  setCookie: function (url, c) { return _legadoHostCall('cookie.setCookie', [url, c]); },
  getKey: function (url) { return _legadoHostCall('cookie.getKey', [url]); },
  removeCookie: function (url, name) { return _legadoHostCall('cookie.removeCookie', [url, name]); }
};
""";
