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
  //   mode: 'fetch' 回渲染后 HTML（或注入 js 的执行结果）；'open' 打开内置浏览器（不阻塞）
  //   js（可选）：legado `java.webView(content, url, js)` 的第三个参数 —— 在页面
  //   上下文里执行的 JS（如 `"document.cookie"`），其**返回值**即本调用结果。
  //   经 base64 走 `x-legado-js` 头（头值必须是可见 ASCII，js 可能含中文/换行）。
  function _browser(url, mode, js) {
    var extra = (js === undefined || js === null || js === '') ? '' : String(js);
    var key = 'BROWSER ' + mode + ' ' + String(url) + (extra ? ' #' + extra : '');
    var box = (typeof httpCache !== 'undefined' && httpCache) ? httpCache : {};
    if (Object.prototype.hasOwnProperty.call(box, key)) {
      var v = box[key];
      if (v && typeof v === 'object' && v.__error) {
        _err('java.浏览器调用失败: ' + v.__error);
      }
      return (v === null || v === undefined) ? '' : v;
    }
    var h = { 'x-legado-browser': mode };
    if (extra) {
      var b64 = base64Encode(extra);
      // 头值过大（本机代理对请求头有尺寸上限）⇒ 放弃注入，退回渲染后 HTML
      if (b64.length <= 4096) h['x-legado-js'] = b64;
    }
    _err(_NEED + JSON.stringify({
      k: key, m: 'BROWSER', u: String(url), h: h, b: null
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

  // ⚠️ legado 语义：hex 是 **UTF-8 字节流**（中文一字 3 字节），必须先转字节数组
  // 再走 _bytesToStr（UTF-8 → UTF-16）。逐字节 String.fromCharCode 会把
  // 中文解成 3 个 Latin-1 乱码字符 —— 聚合源（如"光遇聚合"）的 token/内容
  // 编解码必炸，所以这里不能偷懒。
  function hexDecodeToString(str) {
    var s = String(str).replace(/\s+/g, '');
    var bytes = [];
    for (var i = 0; i + 1 < s.length; i += 2) {
      var b = parseInt(s.substr(i, 2), 16);
      if (isNaN(b)) return '';
      bytes.push(b);
    }
    return _bytesToStr(bytes);
  }

  // java.sleep(ms)：阻塞当前求值 ms 毫秒（legado 语义，同步 JS 环境只能忙等）。
  // 求值跑在 worker isolate，外层 60s 硬超时兜底；负数/非法入参按 0 处理。
  function sleep(ms) {
    var n = Number(ms);
    if (!isFinite(n) || n <= 0) return;
    var end = Date.now() + Math.floor(n);
    while (Date.now() < end) { /* busy-wait */ }
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
    // ── Rhino Java 互操作命名空间（polyfill 在本脚本末尾的全局区）──
    // jsLib 里 `java.util.Base64.encodeToString(...)` 这类深层调用在此接住；
    // getter 惰性求值，避免全局 var 尚未赋值时对象字面量拿到 undefined。
    get util() { return { Base64: JavaBase64 }; },
    get security() { return { MessageDigest: JavaMessageDigest }; },
    // java.lang.String 兼容两种用法：new java.lang.String(bytes,'UTF-8')（Rhino
    // 源最常见）与直接调用 —— 惰性引用全局 JavaLangString（new 时返回包装对象，
    // toString/valueOf 委托字符串，字符串拼接语义与 Java 一致）
    get lang() {
      return {
        String: JavaLangString,
        Integer: {
          parseInt: function (s) {
            var n = parseInt(s, 10);
            if (isNaN(n)) _err('java.lang.Integer.parseInt: ' + s);
            return n;
          }
        },
        Long: {
          parseLong: function (s) {
            var n = parseInt(s, 10);
            return isNaN(n) ? 0 : n;
          }
        }
      };
    },
    get net() {
      return {
        URLEncoder: {
          // Java URLEncoder 是表单编码（空格→+）；与 encodeURIComponent 的差异
          // 对参数值场景可忽略，%20→+ 保证与 Java 行为一致
          encode: function (s) { return encodeURIComponent(String(s)).replace(/%20/g, '+'); }
        },
        URLDecoder: {
          decode: function (s) { return decodeURIComponent(String(s).replace(/\+/g, '%20')); }
        }
      };
    },
    // ── 纯 JS 编解码 ──
    base64Encode: base64Encode,
    base64Decode: base64Decode,
    base64DecodeToByteArray: function (s) { return _b64ToBytes(s); },
    hexDecodeToString: hexDecodeToString,
    hexDecode: hexDecodeToString,
    // ── 阻塞 ──
    sleep: sleep,
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
    // · 传了 js ⇒ 回**该 js 在页面上下文的执行结果**（如 `"document.cookie"` ⇒ cookie 串）
    // · 未传 js ⇒ 回**渲染后 HTML**（Cloudflare 等反爬站用）
    webView: function (content, url, js) {
      var target = (url === null || url === undefined || url === '') ? String(content) : String(url);
      return _browser(target, 'fetch', js);
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

    // ════ Rhino Java 互操作 polyfill（全局区）════
    // legado 跑在 Rhino（JVM），聚合源 jsLib 里常直接调 Java 类库：
    // java.util.Base64 / java.security.MessageDigest / javax.crypto.Mac|Cipher
    // （HMAC 签名、AES 加解密）/ DigestUtils / android.util.Base64。
    // QuickJS 无 JVM —— byte[] 用 JS 数组模拟，算法走宿主 'java.crypto'
    // （Dart crypto/encrypt 包实现）；认识不了的用 Proxy 捕获并抛清晰错误。
    function _cryptoBytesOf(v) {
      if (Array.isArray(v)) {
        var a = [];
        for (var i = 0; i < v.length; i++) a.push(v[i] & 255);
        return a;
      }
      var s = String(v), out = [];
      for (var i2 = 0; i2 < s.length; i2++) {
        var c = s.charCodeAt(i2);
        if (c < 0x80) { out.push(c); }
        else if (c < 0x800) { out.push(0xc0 | (c >> 6), 0x80 | (c & 63)); }
        else if (c >= 0xd800 && c < 0xdc00 && i2 + 1 < s.length) {
          var c2 = s.charCodeAt(++i2);
          var cp = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00);
          out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
        } else { out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63)); }
      }
      return out;
    }
    function _cryptoB64FromBytes(arr) {
      var s = '';
      for (var i = 0; i < arr.length; i++) s += String.fromCharCode(arr[i] & 255);
      var b64 = '', A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      for (var j = 0; j < s.length; j += 3) {
        var b0 = s.charCodeAt(j),
          b1 = j + 1 < s.length ? s.charCodeAt(j + 1) : NaN,
          b2 = j + 2 < s.length ? s.charCodeAt(j + 2) : NaN;
        b64 += A.charAt(b0 >> 2);
        b64 += A.charAt(((b0 & 3) << 4) | ((isNaN(b1) ? 0 : b1) >> 4));
        b64 += isNaN(b1) ? '=' : A.charAt(((b1 & 15) << 2) | ((isNaN(b2) ? 0 : b2) >> 6));
        b64 += isNaN(b2) ? '=' : A.charAt(b2 & 63);
      }
      return b64;
    }
    function _cryptoB64ToBytes(s) {
      var A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      s = String(s).replace(/-/g, '+').replace(/_/g, '/').replace(/[^A-Za-z0-9+/=]/g, '');
      var out = [];
      for (var i = 0; i < s.length; i += 4) {
        var e0 = A.indexOf(s.charAt(i)), e1 = A.indexOf(s.charAt(i + 1)),
          e2 = A.indexOf(s.charAt(i + 2)), e3 = A.indexOf(s.charAt(i + 3));
        out.push((e0 << 2) | (e1 >> 4));
        if (e2 >= 0 && s.charAt(i + 2) !== '=') out.push(((e1 & 15) << 4) | (e2 >> 2));
        if (e3 >= 0 && s.charAt(i + 3) !== '=') out.push(((e2 & 3) << 6) | e3);
      }
      return out;
    }
    function _cryptoHexToBytes(hex) {
      var s = String(hex), out = [];
      for (var i = 0; i + 1 < s.length; i += 2) out.push(parseInt(s.substr(i, 2), 16));
      return out;
    }
    var JavaBase64 = {
      getEncoder: function () {
        return {
          encode: function (b) { return _cryptoB64FromBytes(_cryptoBytesOf(b)); },
          encodeToString: function (b) { return _cryptoB64FromBytes(_cryptoBytesOf(b)); }
        };
      },
      getDecoder: function () {
        return { decode: function (s) { return _cryptoB64ToBytes(s); } };
      },
      getUrlEncoder: function () {
        var ue = {
          encode: function (b) {
            return _cryptoB64FromBytes(_cryptoBytesOf(b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
          }
        };
        ue.encodeToString = ue.encode;
        return ue;
      },
      getUrlDecoder: function () {
        return {
          decode: function (s) { return _cryptoB64ToBytes(String(s).replace(/-/g, '+').replace(/_/g, '/')); }
        };
      }
    };
    function SecretKeySpec(key, alg) { this._raw = _cryptoBytesOf(key); this.algorithm = alg || ''; }
    SecretKeySpec.prototype.getEncoded = function () { return this._raw.slice(); };
    function IvParameterSpec(iv) { this._raw = Array.isArray(iv) ? iv : _cryptoBytesOf(String(iv)); }
    var JavaMessageDigest = {
      getInstance: function (alg) {
        var a = String(alg).toUpperCase().replace(/[^A-Z0-9]/g, '');
        var op = a === 'MD5' ? 'md5' : a === 'SHA1' ? 'sha1'
          : a === 'SHA256' ? 'sha256' : a === 'SHA512' ? 'sha512' : null;
        return {
          digest: function (data) {
            if (!op) { throw new Error('MessageDigest 不支持算法: ' + alg + '（仅 MD5/SHA1/SHA256/SHA512）'); }
            var hex = _legadoHostCall('java.crypto', [op, _cryptoB64FromBytes(_cryptoBytesOf(data))]);
            return _cryptoHexToBytes(hex);
          }
        };
      }
    };
    var DigestUtils = {
      md5Hex: function (d) { return _legadoHostCall('java.crypto', ['md5', _cryptoB64FromBytes(_cryptoBytesOf(d))]); },
      sha1Hex: function (d) { return _legadoHostCall('java.crypto', ['sha1', _cryptoB64FromBytes(_cryptoBytesOf(d))]); },
      sha256Hex: function (d) { return _legadoHostCall('java.crypto', ['sha256', _cryptoB64FromBytes(_cryptoBytesOf(d))]); },
      sha512Hex: function (d) { return _legadoHostCall('java.crypto', ['sha512', _cryptoB64FromBytes(_cryptoBytesOf(d))]); }
    };
    var javax = {
      crypto: {
        spec: { SecretKeySpec: SecretKeySpec, IvParameterSpec: IvParameterSpec },
        Mac: {
          getInstance: function (alg) {
            var a = String(alg).toUpperCase().replace(/[^A-Z0-9]/g, '');
            var op = a.indexOf('HMACSHA256') >= 0 ? 'hmacsha256' : a.indexOf('HMACSHA1') >= 0 ? 'hmacsha1'
              : a.indexOf('HMACSHA512') >= 0 ? 'hmacsha512' : a.indexOf('HMACMD5') >= 0 ? 'hmacmd5' : null;
            var keyRaw = null;
            return {
              init: function (k) {
                keyRaw = (k instanceof SecretKeySpec) ? k._raw : _cryptoBytesOf(k);
                return this;
              },
              doFinal: function (data) {
                if (!op) { throw new Error('javax.crypto.Mac 不支持算法: ' + alg + '（仅 HmacSHA1/256/512、HmacMD5）'); }
                if (keyRaw === null) { throw new Error('javax.crypto.Mac 未 init 密钥'); }
                var hex = _legadoHostCall('java.crypto', [op,
                  _cryptoB64FromBytes(keyRaw), _cryptoB64FromBytes(_cryptoBytesOf(data))]);
                return _cryptoHexToBytes(hex);
              }
            };
          }
        },
        Cipher: {
          ENCRYPT_MODE: 1,
          DECRYPT_MODE: 2,
          getInstance: function (transform) {
            var t = String(transform).toUpperCase();
            var parts = t.split('/');
            var mode = (parts[1] || 'ECB').replace(/[^A-Z]/g, '');
            var keyRaw = null, ivRaw = null, enc = true;
            return {
              init: function (opMode, key, spec) {
                enc = opMode === 1 || String(opMode).toUpperCase().indexOf('ENCRYPT') >= 0;
                keyRaw = (key instanceof SecretKeySpec) ? key._raw : _cryptoBytesOf(key);
                ivRaw = spec ? (spec._raw || _cryptoBytesOf(String(spec))) : null;
                return this;
              },
              doFinal: function (data) {
                if (t.indexOf('AES') < 0) { throw new Error('javax.crypto.Cipher 仅支持 AES，收到: ' + transform); }
                if (keyRaw === null) { throw new Error('javax.crypto.Cipher 未 init 密钥'); }
                var out = _legadoHostCall('java.crypto', ['aes', mode.toLowerCase(), enc ? 'encrypt' : 'decrypt',
                  _cryptoB64FromBytes(keyRaw), ivRaw ? _cryptoB64FromBytes(ivRaw) : '',
                  _cryptoB64FromBytes(_cryptoBytesOf(data))]);
                return _cryptoB64ToBytes(out);
              }
            };
          }
        }
      }
    };
    var android = {
      util: {
        Base64: {
          DEFAULT: 0,
          NO_WRAP: 2,
          NO_CLOSE: 16,
          encodeToString: function (b, flags) { return _cryptoB64FromBytes(_cryptoBytesOf(b)); },
          encode: function (b, flags) { return _cryptoB64FromBytes(_cryptoBytesOf(b)); },
          decode: function (s, flags) { return _cryptoB64ToBytes(s); }
        }
      }
    };
    // 兜底：Packages.* / com.* / org.* 等未知 Java 命名空间 —— Proxy 捕获，
    // 调用时抛清晰错误（而非莫名 ReferenceError），便于按报错逐个补齐
    function _javaProxy(root) {
      try {
        return new Proxy(function () {}, {
          get: function (t, p) {
            if (typeof p !== 'string' || p === 'toString' || p === 'Symbol.toPrimitive') {
              return function () { return root; };
            }
            return _javaProxy(root ? root + '.' + p : p);
          },
          apply: function () {
            throw new Error('该源使用了未支持的 Java 互操作: ' + root + '(...)（QuickJS 无 JVM，需补等价实现）');
          }
        });
      } catch (e) { return function () {}; }
    }
    var Packages = _javaProxy('Packages');
    var com = _javaProxy('com');
    var org = _javaProxy('org');
    // java.lang.String：直接调用返回字符串；new 调用返回包装对象（toString/
    // valueOf 委托），保证 `new java.lang.String(bytes,'UTF-8') + 'x'` 与 Java 一致
    function _cryptoBytesToStr(bytes) {
      var out = '', i = 0;
      while (i < bytes.length) {
        var b = bytes[i] & 255, cp;
        if (b < 0x80) { cp = b; i += 1; }
        else if (b < 0xe0) { cp = ((b & 31) << 6) | (bytes[i + 1] & 63); i += 2; }
        else if (b < 0xf0) {
          cp = ((b & 15) << 12) | ((bytes[i + 1] & 63) << 6) | (bytes[i + 2] & 63);
          i += 3;
        } else {
          cp = ((b & 7) << 18) | ((bytes[i + 1] & 63) << 12) | ((bytes[i + 2] & 63) << 6) | (bytes[i + 3] & 63);
          i += 4;
        }
        if (cp > 0xffff) {
          cp -= 0x10000;
          out += String.fromCharCode(0xd800 | (cp >> 10), 0xdc00 | (cp & 0x3ff));
        } else {
          out += String.fromCharCode(cp);
        }
      }
      return out;
    }
    function JavaLangString(bytes, enc) {
      var s = _cryptoBytesToStr(Array.isArray(bytes) ? bytes : _cryptoBytesOf(bytes));
      if (!(this instanceof JavaLangString)) return s;
      this.__s = s;
      this.toString = function () { return this.__s; };
      this.valueOf = function () { return this.__s; };
    }
    """;
