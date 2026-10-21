/// 书源 QuickJS 引擎的宿主垫片（2026-10-21 实验）。
///
/// bundle（`assets/js/book_engine_qjs.js`）里的 `axios` 已被 esbuild 别名指到
/// 一个只读 `globalThis.axios` 的 shim；这里负责提供它：
///   · 底层走 `sendMessage('book_http')`（Dart 返回 Future ⇒ JS Promise）
///   · 补 `process`（crypto-js / cheerio 的浏览器包会探测它）
library;

const String bookJsPrelude = r'''
(function () {
  'use strict';

  var __nativeSend = globalThis.sendMessage;
  globalThis.global = globalThis;
  globalThis.window = globalThis;
  globalThis.self = globalThis;

  // cheerio / crypto-js 的浏览器包里有 `typeof process !== 'undefined'` 探测
  if (typeof globalThis.process === 'undefined') {
    globalThis.process = {
      env: {},
      platform: 'quickjs',
      version: 'v18',
      versions: {},
      cwd: function () { return '/'; }
    };
  }

  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function b64ToBytes(str) {
    str = String(str || '').replace(/[^A-Za-z0-9+/=]/g, '');
    var pad = 0;
    if (str.slice(-2) === '==') pad = 2;
    else if (str.slice(-1) === '=') pad = 1;
    var len = str.length;
    var u8 = new Uint8Array(Math.max(0, Math.floor(len / 4) * 3 - pad));
    // '=' 不在索引表里（indexOf 返回 -1），按 0 处理，否则尾字节会被写成 0xff
    var at = function (ch) {
      var k = B64.indexOf(ch);
      return k < 0 ? 0 : k;
    };
    var p = 0;
    for (var i = 0; i < len; i += 4) {
      var n = (at(str[i]) << 18) | (at(str[i + 1]) << 12) |
              (at(str[i + 2]) << 6) | at(str[i + 3]);
      if (p < u8.length) u8[p++] = (n >> 16) & 255;
      if (p < u8.length) u8[p++] = (n >> 8) & 255;
      if (p < u8.length) u8[p++] = n & 255;
    }
    return u8.buffer;
  }

  function queryString(params) {
    if (!params || typeof params !== 'object') return '';
    var parts = [];
    for (var k in params) {
      var v = params[k];
      if (v == null) continue;
      if (Array.isArray(v)) {
        for (var i = 0; i < v.length; i++) {
          parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(String(v[i])));
        }
      } else {
        parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(String(v)));
      }
    }
    return parts.join('&');
  }

  function request(config) {
    config = config || {};
    var url = String(config.url || config.uri || '');
    var qs = queryString(config.params);
    if (qs) url += (url.indexOf('?') >= 0 ? '&' : '?') + qs;

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
      url: url,
      headers: headers,
      data: body == null ? '' : String(body),
      responseType: config.responseType === 'arraybuffer' ? 'arraybuffer' : 'text',
      timeoutMs: config.timeout || 25000
    };

    return Promise.resolve(__nativeSend('book_http', JSON.stringify(payload))).then(function (res) {
      if (!res || typeof res !== 'object') throw new Error('HTTP 无响应');
      var data = payload.responseType === 'arraybuffer'
        ? b64ToBytes(res.bodyBase64 || '')
        : (res.bodyText == null ? '' : res.bodyText);
      var status = res.status || 0;

      if (typeof config.transformResponse === 'function') {
        try { data = config.transformResponse(data); } catch (e) { /* ignore */ }
      } else if (payload.responseType === 'text' && typeof data === 'string') {
        var t = data.trim();
        if (t.charAt(0) === '[') {
          try { data = JSON.parse(t); } catch (e) { /* keep text */ }
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

  globalThis.axios = axios;

  // 宿主调用入口：把 Promise 状态摊平到全局，Dart 侧轮询读取
  globalThis.__bookCall = function (action, payloadJson) {
    globalThis.__bookState = 'pending';
    globalThis.__bookValue = '';
    globalThis.__bookError = '';
    try {
      var p = globalThis.__bookRun(action, payloadJson);
      Promise.resolve(p).then(
        function (v) {
          globalThis.__bookValue = typeof v === 'string' ? v : JSON.stringify(v);
          globalThis.__bookState = 'ok';
        },
        function (e) {
          globalThis.__bookError = String((e && (e.message || e.stack)) || e);
          globalThis.__bookState = 'err';
        }
      );
      return true;
    } catch (e) {
      globalThis.__bookError = String((e && (e.message || e.stack)) || e);
      globalThis.__bookState = 'err';
      return false;
    }
  };
})();
''';
