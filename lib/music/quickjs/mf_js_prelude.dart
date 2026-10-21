/// MusicFree 插件的 **QuickJS 运行时垫片**（2026-10-21 实验引擎）。
///
/// 目标：让「只用 axios / he」的插件（占大多数）不依赖 Node 就能跑。
///
/// 提供：
///   · `require('axios')` —— 极简 axios，底层走宿主 `sendMessage('mf_http')`
///     （Dart 返回 Future ⇒ quickjs_engine 会转成 JS Promise）
///   · `require('he')`    —— HTML 实体编解码（常用实体 + 数字实体）
///   · `global.env.getUserVariables()` —— 插件变量（Cookie / 卡密等）
///   · `__mfLoad / __mfRun / __mfStringify` —— 宿主调用的入口
///
/// ⚠️ **故意不支持** `cheerio / crypto-js / dayjs / big-integer / pako /
/// iconv-lite`：这些要么体积大、要么要额外打包。require 它们会抛错，
/// 上层（`MfQuickJsEngine`）捕获后**自动回退 Node 引擎** —— 两条路都可用，
/// 不会因为"换引擎"把插件跑挂。
library;

const String mfJsPrelude = r'''
(function () {
  'use strict';

  var __nativeSend = globalThis.sendMessage;
  globalThis.global = globalThis;
  globalThis.window = globalThis;
  globalThis.self = globalThis;

  var __vars = {};
  globalThis.env = {
    getUserVariables: function () { return __vars; },
    getUserVariable: function (k) { return __vars[String(k)] || ''; }
  };

  // ── Base64（二进制响应）──────────────────────────────────────
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function b64ToBytes(str) {
    str = String(str || '').replace(/[^A-Za-z0-9+/=]/g, '');
    var pad = 0;
    if (str.slice(-2) === '==') pad = 2;
    else if (str.slice(-1) === '=') pad = 1;
    var len = str.length;
    var u8 = new Uint8Array(Math.max(0, Math.floor(len / 4) * 3 - pad));
    var p = 0;
    for (var i = 0; i < len; i += 4) {
      var n = (B64.indexOf(str[i]) << 18) | (B64.indexOf(str[i + 1]) << 12) |
              (B64.indexOf(str[i + 2]) << 6) | B64.indexOf(str[i + 3]);
      if (p < u8.length) u8[p++] = (n >> 16) & 255;
      if (p < u8.length) u8[p++] = (n >> 8) & 255;
      if (p < u8.length) u8[p++] = n & 255;
    }
    return u8.buffer;
  }

  // ── HTTP（宿主执行）──────────────────────────────────────────
  function request(config) {
    config = config || {};
    var headers = {};
    var h = config.headers || {};
    for (var k in h) headers[k] = String(h[k]);

    var body = config.data;
    if (body != null && typeof body !== 'string') {
      try { body = JSON.stringify(body); } catch (e) { body = String(body); }
      if (!headers['Content-Type'] && !headers['content-type']) {
        headers['Content-Type'] = 'application/json';
      }
    }

    var payload = {
      method: String(config.method || 'GET').toUpperCase(),
      url: String(config.url || config.uri || ''),
      headers: headers,
      data: body == null ? '' : String(body),
      responseType: config.responseType === 'arraybuffer' ? 'arraybuffer' : 'text',
      timeoutMs: config.timeout || 15000
    };

    return Promise.resolve(__nativeSend('mf_http', JSON.stringify(payload))).then(function (res) {
      if (!res || typeof res !== 'object') throw new Error('HTTP 无响应');
      var data = payload.responseType === 'arraybuffer'
        ? b64ToBytes(res.bodyBase64 || '')
        : (res.bodyText == null ? '' : res.bodyText);

      // 插件常用 config.transformResponse（默认把 JSON 文本转对象）
      var status = res.status || 0;
      if (typeof config.transformResponse === 'function') {
        try { data = config.transformResponse(data); } catch (e) { /* 忽略 */ }
      } else if (payload.responseType === 'text' && typeof data === 'string') {
        var t = data.trim();
        if (t.charAt(0) === '{' || t.charAt(0) === '[') {
          try { data = JSON.parse(t); } catch (e) { /* 保持文本 */ }
        }
      }

      var validate = config.validateStatus;
      var valid = typeof validate === 'function'
        ? !!validate(status)
        : status >= 200 && status < 300;
      if (!valid) {
        var err = new Error('Request failed with status code ' + status);
        err.response = { status: status, data: data, headers: res.headers || {} };
        err.config = config;
        throw err;
      }
      return { data: data, status: status, statusText: '', headers: res.headers || {}, config: config };
    });
  }

  var axios = function (config) { return request(config); };
  axios.request = request;
  axios.get = function (url, config) {
    config = config || {}; config.url = url; config.method = 'get'; return request(config);
  };
  axios.delete = function (url, config) {
    config = config || {}; config.url = url; config.method = 'delete'; return request(config);
  };
  axios.head = function (url, config) {
    config = config || {}; config.url = url; config.method = 'head'; return request(config);
  };
  axios.post = function (url, data, config) {
    config = config || {}; config.url = url; config.data = data; config.method = 'post';
    return request(config);
  };
  axios.put = function (url, data, config) {
    config = config || {}; config.url = url; config.data = data; config.method = 'put';
    return request(config);
  };
  axios.patch = function (url, data, config) {
    config = config || {}; config.url = url; config.data = data; config.method = 'patch';
    return request(config);
  };
  axios.create = function () { return axios; };
  axios.defaults = { headers: { common: {} } };
  axios.isAxiosError = function () { return false; };
  axios.CancelToken = { source: function () { return { token: {}, cancel: function () {} }; } };
  axios.interceptors = {
    request: { use: function () {}, eject: function () {} },
    response: { use: function () {}, eject: function () {} }
  };

  // ── he（HTML 实体）───────────────────────────────────────────
  var NAMED = {
    amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: '\u00a0',
    copy: '\u00a9', reg: '\u00ae', trade: '\u2122', hellip: '\u2026',
    mdash: '\u2014', ndash: '\u2013', lsquo: '\u2018', rsquo: '\u2019',
    ldquo: '\u201c', rdquo: '\u201d', middot: '\u00b7', times: '\u00d7',
    divide: '\u00f7', deg: '\u00b0', plusmn: '\u00b1', laquo: '\u00ab',
    raquo: '\u00bb', bull: '\u2022', dagger: '\u2020', permil: '\u2030',
    euro: '\u20ac', pound: '\u00a3', yen: '\u00a5', cent: '\u00a2',
    sect: '\u00a7', para: '\u00b6', frac12: '\u00bd', frac14: '\u00bc',
    frac34: '\u00be', sup2: '\u00b2', sup3: '\u00b3', micro: '\u00b5'
  };
  var he = {
    decode: function (input) {
      var s = input == null ? '' : String(input);
      return s.replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);/g, function (m, body) {
        if (body.charAt(0) === '#') {
          var hex = body.charAt(1) === 'x' || body.charAt(1) === 'X';
          var code = parseInt(body.slice(hex ? 2 : 1), hex ? 16 : 10);
          if (!isFinite(code) || code <= 0) return m;
          try { return String.fromCodePoint(code); } catch (e) { return m; }
        }
        var key = body.toLowerCase();
        return Object.prototype.hasOwnProperty.call(NAMED, key) ? NAMED[key] : m;
      });
    },
    decodeHTML: function (s) { return he.decode(s); },
    encode: function (input) {
      var s = input == null ? '' : String(input);
      return s.replace(/[&<>"']/g, function (ch) {
        return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch];
      });
    },
    encodeHTML: function (s) { return he.encode(s); }
  };

  function __require(name) {
    if (name === 'axios') return axios;
    if (name === 'he') return he;
    // 其它模块（cheerio / crypto-js / …）故意不支持 → 上层回退 Node
    throw new Error("QUICKJS_UNSUPPORTED_REQUIRE:" + name);
  }

  globalThis.__mfLoad = function (script, varsJson) {
    try { __vars = JSON.parse(varsJson || '{}') || {}; } catch (e) { __vars = {}; }
    var module = { exports: {} };
    var fn = new Function('module', 'exports', 'require', 'global', script);
    fn(module, module.exports, __require, globalThis);
    globalThis.__mfPlugin = module.exports || {};
    return Object.keys(globalThis.__mfPlugin).join(',');
  };

  globalThis.__mfVariables = function () {
    var uv = (globalThis.__mfPlugin && globalThis.__mfPlugin.userVariables) || [];
    return JSON.stringify(uv);
  };

  var ACTION_NAMES = {
    search: ['search'],
    lyric: ['getLyric', 'getLyricNew'],
    media: ['getMediaSource', 'getMusicUrl', 'getMusicInfo'],
    musicInfo: ['getMusicInfo']
  };

  globalThis.__mfRun = function (kind, argsJson) {
    var plugin = globalThis.__mfPlugin || {};
    var names = ACTION_NAMES[kind] || [];
    var fn = null;
    for (var i = 0; i < names.length; i++) {
      if (typeof plugin[names[i]] === 'function') { fn = plugin[names[i]]; break; }
    }
    if (!fn) return 'NOFN:' + names.join('/');

    var args;
    try { args = JSON.parse(argsJson || '[]'); } catch (e) { args = []; }
    globalThis.__mfState = 'pending';
    globalThis.__mfError = '';
    globalThis.__mfValue = undefined;
    Promise.resolve().then(function () {
      return fn.apply(plugin, args);
    }).then(function (v) {
      globalThis.__mfValue = v;
      globalThis.__mfState = 'ok';
    }, function (e) {
      globalThis.__mfError = String((e && (e.stack || e.message)) || e);
      globalThis.__mfState = 'err';
    });
    return 'OK';
  };

  globalThis.__mfStringify = function (v) {
    try { return JSON.stringify(v); } catch (e) { return ''; }
  };
})();
''';
