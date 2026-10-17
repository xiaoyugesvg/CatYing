/// Venera `ComicSource` 兼容运行时 —— JS 侧垫片。
///
/// Venera-Plus 的源脚本约定（见其 `doc/api/comic_source.zh.md`）：
///   · 顶层声明 `class Xxx extends ComicSource { ... }`
///   · 用 `search.load / comic.loadInfo / comic.loadEp` 返回 Promise
///   · 通过全局 `sendMessage({method:...})` 调用宿主能力
///   · 通过 `Network.* / Convert.* / HtmlDocument / Comic / ComicDetails` 等全局对象工作
///
/// 本文件是**按该 API 契约自行实现**的垫片（不复制 Venera-Plus 的 GPL 源码）：
/// `sendMessage` 走 quickjs_engine 的同步 channel（Dart 返回 Map/List/Uint8List，
/// 如果是 Future 则 JS 侧得到 Promise），因此 `Convert`/`HtmlDocument` 是同步的，
/// `Network.*` 拿到的是真正的 Promise。
library;

const String veneraJsPrelude = r'''
(function () {
  'use strict';

  var __nativeSend = globalThis.sendMessage;

  // ────────────────────────── 二进制工具 ──────────────────────────
  function utf8Encode(str) {
    str = String(str);
    var out = [];
    for (var i = 0; i < str.length; i++) {
      var c = str.charCodeAt(i);
      if (c < 0x80) {
        out.push(c);
      } else if (c < 0x800) {
        out.push(0xC0 | (c >> 6), 0x80 | (c & 63));
      } else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < str.length) {
        var c2 = str.charCodeAt(i + 1);
        if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
          var cp = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00);
          out.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 63),
                   0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
          i++;
        } else {
          out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        }
      } else {
        out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      }
    }
    return new Uint8Array(out);
  }

  function utf8Decode(u8) {
    var out = '';
    for (var i = 0; i < u8.length;) {
      var c = u8[i++];
      if (c < 0x80) {
        out += String.fromCharCode(c);
      } else if (c < 0xE0) {
        out += String.fromCharCode(((c & 31) << 6) | (u8[i++] & 63));
      } else if (c < 0xF0) {
        out += String.fromCharCode(((c & 15) << 12) |
          ((u8[i++] & 63) << 6) | (u8[i++] & 63));
      } else {
        var cp = ((c & 7) << 18) | ((u8[i++] & 63) << 12) |
                 ((u8[i++] & 63) << 6) | (u8[i++] & 63);
        cp -= 0x10000;
        out += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 1023));
      }
    }
    return out;
  }

  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  function b64encode(value) {
    var u8 = toU8(value);
    var out = '';
    var i;
    for (i = 0; i + 2 < u8.length; i += 3) {
      var n = (u8[i] << 16) | (u8[i + 1] << 8) | u8[i + 2];
      out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] +
             B64[(n >> 6) & 63] + B64[n & 63];
    }
    var rem = u8.length - i;
    if (rem === 1) {
      var n1 = u8[i] << 16;
      out += B64[(n1 >> 18) & 63] + B64[(n1 >> 12) & 63] + '==';
    } else if (rem === 2) {
      var n2 = (u8[i] << 16) | (u8[i + 1] << 8);
      out += B64[(n2 >> 18) & 63] + B64[(n2 >> 12) & 63] +
             B64[(n2 >> 6) & 63] + '=';
    }
    return out;
  }

  function b64decode(str) {
    str = String(str).replace(/[^A-Za-z0-9+/=]/g, '');
    var pad = 0;
    if (str.slice(-2) === '==') pad = 2;
    else if (str.slice(-1) === '=') pad = 1;
    var len = str.length;
    var u8 = new Uint8Array(Math.floor(len / 4) * 3 - pad);
    var p = 0;
    for (var i = 0; i < len; i += 4) {
      var c1 = B64.indexOf(str[i]);
      var c2 = B64.indexOf(str[i + 1]);
      var c3 = B64.indexOf(str[i + 2]);
      var c4 = B64.indexOf(str[i + 3]);
      if (c1 < 0) c1 = 0;
      if (c2 < 0) c2 = 0;
      if (c3 < 0) c3 = 0;
      if (c4 < 0) c4 = 0;
      var n = (c1 << 18) | (c2 << 12) | (c3 << 6) | c4;
      if (p < u8.length) u8[p++] = (n >> 16) & 255;
      if (p < u8.length) u8[p++] = (n >> 8) & 255;
      if (p < u8.length) u8[p++] = n & 255;
    }
    return u8.buffer;
  }

  function toU8(v) {
    if (v == null) return new Uint8Array(0);
    if (typeof v === 'string') return utf8Encode(v);
    if (v instanceof ArrayBuffer) return new Uint8Array(v);
    if (ArrayBuffer.isView(v)) {
      return new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
    }
    if (Array.isArray(v)) return new Uint8Array(v);
    if (typeof v === 'object' && typeof v.__bytes === 'string') {
      return new Uint8Array(b64decode(v.__bytes));
    }
    return new Uint8Array(0);
  }

  // ────────────────────────── 宿主调用 ──────────────────────────
  // 同步能力（convert/html/storage）返回普通值；
  // 网络能力返回 Future → quickjs_engine 会把它变成 JS Promise。
  function host(message) {
    var m = message;
    if (m && m.data != null &&
        (m.data instanceof ArrayBuffer || ArrayBuffer.isView(m.data))) {
      m = {};
      for (var k in message) m[k] = message[k];
      m.data = { __bytes: b64encode(message.data) };
    }
    return __nativeSend('venera', JSON.stringify(m));
  }

  // Venera 源脚本调用的是单参数 sendMessage({...})；
  // 引擎内部的 console/setTimeout 用的是两参数版本 → 原样转发。
  globalThis.sendMessage = function (a, b) {
    if (arguments.length >= 2) return __nativeSend(a, b);
    return host(a);
  };

  // ────────────────────────── Convert ──────────────────────────
  var Convert = {
    encodeUtf8: function (str) { return utf8Encode(str).buffer; },
    decodeUtf8: function (v) { return utf8Decode(toU8(v)); },
    encodeGbk: function (str) {
      return host({ method: 'convert', type: 'gbk', isEncode: true, value: String(str) });
    },
    decodeGbk: function (v) {
      return host({ method: 'convert', type: 'gbk', isEncode: false, value: { __bytes: b64encode(v) } });
    },
    encodeBase64: function (v) { return b64encode(v); },
    decodeBase64: function (s) { return b64decode(s); },
    encodeGzip: function (v) {
      return host({ method: 'convert', type: 'gzip', isEncode: true, value: { __bytes: b64encode(v) } });
    },
    decodeGzip: function (v) {
      return host({ method: 'convert', type: 'gzip', isEncode: false, value: { __bytes: b64encode(v) } });
    },
    md5: function (v) { return hashOf('md5', v); },
    sha1: function (v) { return hashOf('sha1', v); },
    sha256: function (v) { return hashOf('sha256', v); },
    sha512: function (v) { return hashOf('sha512', v); },
    hmac: function (key, value, hash) {
      return host({
        method: 'convert', type: 'hmac', hash: hash,
        key: { __bytes: b64encode(key) },
        value: { __bytes: b64encode(value) },
        isEncode: true
      });
    },
    hmacString: function (key, value, hash) {
      return host({
        method: 'convert', type: 'hmac', hash: hash,
        key: { __bytes: b64encode(key) },
        value: { __bytes: b64encode(value) },
        isEncode: true, isString: true
      });
    },
    encryptAesEcb: function (v, k) {
      return aesOf('aes-ecb', v, k, null, true);
    },
    decryptAesEcb: function (v, k) {
      return aesOf('aes-ecb', v, k, null, false);
    },
    encryptAesCbc: function (v, k, iv) {
      return aesOf('aes-cbc', v, k, iv, true);
    },
    decryptAesCbc: function (v, k, iv) {
      return aesOf('aes-cbc', v, k, iv, false);
    },
    encryptAesCfb: function (v, k, iv, blockSize) {
      return aesOf('aes-cfb', v, k, iv, true);
    },
    decryptAesCfb: function (v, k, iv, blockSize) {
      return aesOf('aes-cfb', v, k, iv, false);
    },
    encryptAesOfb: function (v, k, blockSize) {
      return aesOf('aes-ofb', v, k, null, true);
    },
    decryptAesOfb: function (v, k, blockSize) {
      return aesOf('aes-ofb', v, k, null, false);
    },
    decryptRsa: function () {
      throw new Error('Venera 兼容层暂不支持 RSA 解密');
    },
    hexEncode: function (bytes) {
      var u8 = toU8(bytes);
      var s = '';
      for (var i = 0; i < u8.length; i++) {
        var h = u8[i].toString(16);
        s += h.length === 1 ? '0' + h : h;
      }
      return s;
    }
  };

  function hashOf(type, value) {
    return host({
      method: 'convert', type: type,
      value: { __bytes: b64encode(value) }, isEncode: true
    });
  }

  function aesOf(type, value, key, iv, isEncode) {
    var m = {
      method: 'convert', type: type,
      value: { __bytes: b64encode(value) },
      key: { __bytes: b64encode(key) },
      isEncode: isEncode
    };
    if (iv != null) m.iv = { __bytes: b64encode(iv) };
    return host(m);
  }

  // ────────────────────────── Network ──────────────────────────
  var Network = {
    sendRequest: function (method, url, headers, data, extra) {
      return Promise.resolve(host({
        method: 'http', http_method: method, url: url,
        headers: headers, data: data, extra: extra
      })).then(function (r) {
        if (r && r.error) throw new Error(r.error);
        return r;
      });
    },
    fetchBytes: function (method, url, headers, data, extra) {
      return Promise.resolve(host({
        method: 'http', http_method: method, bytes: true, url: url,
        headers: headers, data: data, extra: extra
      })).then(function (r) {
        if (r && r.error) throw new Error(r.error);
        return r;
      });
    },
    get: function (url, headers, extra) {
      return this.sendRequest('GET', url, headers, null, extra);
    },
    post: function (url, headers, data, extra) {
      return this.sendRequest('POST', url, headers, data, extra);
    },
    put: function (url, headers, data, extra) {
      return this.sendRequest('PUT', url, headers, data, extra);
    },
    patch: function (url, headers, data, extra) {
      return this.sendRequest('PATCH', url, headers, data, extra);
    },
    delete: function (url, headers, extra) {
      return this.sendRequest('DELETE', url, headers, null, extra);
    },
    setCookies: function (url, cookies) {
      return host({ method: 'cookie', function: 'set', url: url, cookies: cookies });
    },
    getCookies: function (url) {
      return host({ method: 'cookie', function: 'get', url: url });
    },
    deleteCookies: function (url) {
      return host({ method: 'cookie', function: 'delete', url: url });
    }
  };

  globalThis.fetch = function (url, options) {
    var method = 'GET';
    var headers = {};
    var data = null;
    if (options) {
      method = options.method || method;
      headers = options.headers || headers;
      data = options.body || data;
    }
    return Network.fetchBytes(method, url, headers, data).then(function (result) {
      return {
        ok: result.status >= 200 && result.status < 300,
        status: result.status,
        statusText: '',
        url: url,
        headers: result.headers || {},
        arrayBuffer: function () { return Promise.resolve(result.body); },
        text: function () { return Promise.resolve(Convert.decodeUtf8(result.body)); },
        json: function () {
          return Promise.resolve(JSON.parse(Convert.decodeUtf8(result.body)));
        }
      };
    });
  };

  // ────────────────────────── HTML DOM ──────────────────────────
  function HtmlDocument(html) {
    this.key = host({ method: 'html', function: 'parse', data: String(html) });
  }
  HtmlDocument.prototype.querySelector = function (q) {
    var k = host({ method: 'html', function: 'querySelector', key: this.key, query: q });
    return k == null ? null : new HtmlElement(k);
  };
  HtmlDocument.prototype.querySelectorAll = function (q) {
    var ks = host({ method: 'html', function: 'querySelectorAll', key: this.key, query: q }) || [];
    var out = [];
    for (var i = 0; i < ks.length; i++) out.push(new HtmlElement(ks[i]));
    return out;
  };
  HtmlDocument.prototype.getElementById = function (id) {
    var k = host({ method: 'html', function: 'getElementById', key: this.key, id: id });
    return k == null ? null : new HtmlElement(k);
  };
  HtmlDocument.prototype.dispose = function () {
    host({ method: 'html', function: 'dispose', key: this.key });
  };

  function HtmlElement(key) { this.key = key; }
  HtmlElement.prototype._get = function (fn, extra) {
    var m = { method: 'html', function: fn, key: this.key };
    if (extra) for (var k in extra) m[k] = extra[k];
    return host(m);
  };
  Object.defineProperty(HtmlElement.prototype, 'text', {
    get: function () { return this._get('getText') || ''; }
  });
  Object.defineProperty(HtmlElement.prototype, 'attributes', {
    get: function () { return this._get('getAttributes') || {}; }
  });
  Object.defineProperty(HtmlElement.prototype, 'innerHTML', {
    get: function () { return this._get('getInnerHTML') || ''; }
  });
  Object.defineProperty(HtmlElement.prototype, 'children', {
    get: function () {
      var ks = this._get('getChildren') || [];
      var out = [];
      for (var i = 0; i < ks.length; i++) out.push(new HtmlElement(ks[i]));
      return out;
    }
  });
  Object.defineProperty(HtmlElement.prototype, 'nodes', {
    get: function () {
      var ks = this._get('getNodes') || [];
      var out = [];
      for (var i = 0; i < ks.length; i++) out.push(new HtmlNode(ks[i]));
      return out;
    }
  });
  Object.defineProperty(HtmlElement.prototype, 'parent', {
    get: function () {
      var k = this._get('getParent');
      return k == null ? null : new HtmlElement(k);
    }
  });
  Object.defineProperty(HtmlElement.prototype, 'classNames', {
    get: function () { return this._get('getClassNames') || []; }
  });
  Object.defineProperty(HtmlElement.prototype, 'id', {
    get: function () { return this._get('getId'); }
  });
  Object.defineProperty(HtmlElement.prototype, 'localName', {
    get: function () { return this._get('getLocalName') || ''; }
  });
  Object.defineProperty(HtmlElement.prototype, 'previousElementSibling', {
    get: function () {
      var k = this._get('getPreviousSibling');
      return k == null ? null : new HtmlElement(k);
    }
  });
  Object.defineProperty(HtmlElement.prototype, 'nextElementSibling', {
    get: function () {
      var k = this._get('getNextSibling');
      return k == null ? null : new HtmlElement(k);
    }
  });
  HtmlElement.prototype.querySelector = function (q) {
    var k = this._get('domQuerySelector', { query: q });
    return k == null ? null : new HtmlElement(k);
  };
  HtmlElement.prototype.querySelectorAll = function (q) {
    var ks = this._get('domQuerySelectorAll', { query: q }) || [];
    var out = [];
    for (var i = 0; i < ks.length; i++) out.push(new HtmlElement(ks[i]));
    return out;
  };

  function HtmlNode(key) { this.key = key; }
  Object.defineProperty(HtmlNode.prototype, 'text', {
    get: function () { return host({ method: 'html', function: 'node_text', key: this.key }) || ''; }
  });
  Object.defineProperty(HtmlNode.prototype, 'type', {
    get: function () { return host({ method: 'html', function: 'node_type', key: this.key }) || 'unknown'; }
  });
  HtmlNode.prototype.toElement = function () {
    var k = host({ method: 'html', function: 'node_toElement', key: this.key });
    return k == null ? null : new HtmlElement(k);
  };

  // ────────────────────────── 数据模型 ──────────────────────────
  function Comic(o) {
    o = o || {};
    this.id = o.id;
    this.title = o.title;
    this.subtitle = o.subtitle;
    this.subTitle = o.subTitle;
    this.cover = o.cover;
    this.tags = o.tags;
    this.description = o.description;
    this.maxPage = o.maxPage;
    this.language = o.language;
    this.favoriteId = o.favoriteId;
    this.stars = o.stars;
  }

  function ComicDetails(o) {
    o = o || {};
    this.title = o.title;
    this.subtitle = o.subtitle != null ? o.subtitle : o.subTitle;
    this.cover = o.cover;
    this.description = o.description;
    this.tags = o.tags;
    this.chapters = o.chapters;
    this.isFavorite = o.isFavorite;
    this.subId = o.subId;
    this.thumbnails = o.thumbnails;
    this.recommend = o.recommend;
    this.commentCount = o.commentCount;
    this.likesCount = o.likesCount;
    this.isLiked = o.isLiked;
    this.uploader = o.uploader;
    this.updateTime = o.updateTime;
    this.uploadTime = o.uploadTime;
    this.url = o.url;
    this.stars = o.stars;
    this.maxPage = o.maxPage;
    this.comments = o.comments;
  }

  function Comment(o) {
    o = o || {};
    for (var k in o) this[k] = o[k];
  }

  function ImageLoadingConfig(o) {
    o = o || {};
    this.url = o.url;
    this.method = o.method;
    this.data = o.data;
    this.headers = o.headers;
    this.onResponse = o.onResponse;
    this.modifyImage = o.modifyImage;
    this.onLoadFailed = o.onLoadFailed;
  }

  function Image() {
    throw new Error('Venera 兼容层暂不支持 Image 对象');
  }

  // ────────────────────────── ComicSource 基类 ──────────────────────────
  function ComicSource() {
    this.name = '';
    this.key = '';
    this.version = '';
    this.minAppVersion = '';
    this.url = '';
    this.translation = {};
  }
  ComicSource.sources = {};
  ComicSource.prototype.loadData = function (dataKey) {
    return host({ method: 'load_data', key: this.key, data_key: dataKey });
  };
  ComicSource.prototype.loadSetting = function (k) {
    var v = host({ method: 'load_setting', key: this.key, setting_key: k });
    if ((v === null || v === undefined) && this.settings &&
        this.settings[k] && this.settings[k]['default'] !== undefined) {
      return this.settings[k]['default'];
    }
    return v;
  };
  ComicSource.prototype.saveData = function (dataKey, data) {
    return host({ method: 'save_data', key: this.key, data_key: dataKey, data: data });
  };
  ComicSource.prototype.deleteData = function (dataKey) {
    return host({ method: 'delete_data', key: this.key, data_key: dataKey });
  };
  Object.defineProperty(ComicSource.prototype, 'isLogged', {
    get: function () { return host({ method: 'isLogged', key: this.key }) === true; }
  });
  ComicSource.prototype.translate = function (k) {
    var t = this.translation && (this.translation['zh_CN'] || this.translation.zh);
    return (t && t[k] != null) ? t[k] : k;
  };
  ComicSource.prototype.init = function () {};

  // ────────────────────────── 杂项 ──────────────────────────
  globalThis.APP = { version: '9.9.9', locale: 'zh_CN', isDebug: false };

  globalThis.log = function (level, title, content) {
    try { console.log('[' + title + '] ' + content); } catch (e) {}
  };

  globalThis.UI = {
    showMessage: function (message) {
      host({ method: 'ui', function: 'showMessage', message: String(message) });
    },
    showDialog: function (title, content, actions) {
      host({
        method: 'ui', function: 'showDialog',
        title: String(title), content: String(content)
      });
      return Promise.resolve();
    },
    launchUrl: function (url) {
      host({ method: 'ui', function: 'launchUrl', url: String(url) });
    },
    showLoading: function () { return 0; },
    hideLoading: function () {},
    showInputDialog: function () { return Promise.resolve(null); }
  };

  globalThis.randomInt = function (min, max) {
    min = Math.floor(min);
    max = Math.floor(max);
    if (max < min) { var t = min; min = max; max = t; }
    return Math.floor(Math.random() * (max - min + 1)) + min;
  };
  globalThis.randomDouble = function (min, max) {
    return Math.random() * (max - min) + min;
  };
  globalThis.createUuid = function () {
    var s = '';
    for (var i = 0; i < 36; i++) {
      if (i === 8 || i === 13 || i === 18 || i === 23) {
        s += '-';
      } else if (i === 14) {
        s += '4';
      } else {
        var r = Math.floor(Math.random() * 16);
        if (i === 19) r = (r & 3) | 8;
        s += r.toString(16);
      }
    }
    return s;
  };

  globalThis.setInterval = function (callback, delay) {
    var handle = { on: true };
    function tick() {
      if (!handle.on) return;
      try { callback(); } catch (e) {}
      setTimeout(tick, delay);
    }
    setTimeout(tick, delay);
    return handle;
  };
  globalThis.clearInterval = function (h) { if (h) h.on = false; };
  globalThis.clearTimeout = function (h) { if (h) h.on = false; };

  // ────────────────────────── 任务执行器 ──────────────────────────
  // 入口方法都是 async；Dart 侧轮询 __veneraJobState 取结果。
  globalThis.__veneraJobState = 'idle';
  globalThis.__veneraJobValue = null;
  globalThis.__veneraJobError = null;

  globalThis.__veneraErr = function (e) {
    if (e == null) return 'unknown error';
    return (e && e.message) ? (e.message + '') : ('' + e);
  };

  globalThis.__veneraExploreInfo = function () {
    var s = globalThis.__veneraSrc;
    var ex = s && s.explore;
    var out = [];
    if (!ex || !ex.length) return out;
    for (var i = 0; i < ex.length; i++) {
      out.push({ index: i, title: (ex[i] && ex[i].title) ? ('' + ex[i].title) : ('列表 ' + (i + 1)) });
    }
    return out;
  };

  // search.optionList 的默认值：Venera 用 "value-Label" 字符串或对象描述选项。
  function optionValue(o) {
    if (o == null) return '';
    if (typeof o === 'string') return o.split('-')[0];
    if (typeof o === 'object') {
      if (o.value !== undefined) return o.value;
      if (o.default !== undefined) return o.default;
      if (typeof o.text === 'string') return o.text.split('-')[0];
    }
    return '';
  }

  globalThis.__veneraDefaultOptions = function () {
    var s = globalThis.__veneraSrc;
    var list = s && s.search && s.search.optionList;
    var out = [];
    if (!list || !list.length) return out;
    for (var i = 0; i < list.length; i++) {
      var d = list[i] || {};
      if (d['default'] !== undefined) {
        out.push(d['default']);
      } else if (d.type === 'switch') {
        out.push(false);
      } else if (d.type === 'text') {
        out.push('');
      } else if (d.options && d.options.length) {
        out.push(optionValue(d.options[0]));
      } else {
        out.push('');
      }
    }
    return out;
  };

  globalThis.__veneraDispatch = function (kind, a) {
    var s = globalThis.__veneraSrc;
    if (!s) throw new Error('Venera 源未初始化');
    if (kind === 'init') {
      return (typeof s.init === 'function') ? s.init() : null;
    }
    if (kind === 'search') {
      var opts = a.options;
      if (!Array.isArray(opts) || opts.length === 0) {
        opts = globalThis.__veneraDefaultOptions();
      }
      if (s.search && typeof s.search.load === 'function') {
        return s.search.load(a.query, opts, a.page || 1);
      }
      // 少数源（如 ehentai）只实现游标翻页；这里只支持第一页
      if (s.search && typeof s.search.loadNext === 'function') {
        if ((a.page || 1) > 1) return { comics: [], maxPage: 1 };
        return s.search.loadNext(a.query, opts, null);
      }
      throw new Error('该源不支持搜索（缺少 search.load）');
    }
    if (kind === 'explore') {
      var ex = s.explore && s.explore[a.index || 0];
      if (ex && typeof ex.load === 'function') {
        return ex.load(a.page || 1);
      }
      if (ex && typeof ex.loadNext === 'function') {
        if ((a.page || 1) > 1) return { comics: [], maxPage: 1 };
        return ex.loadNext(null);
      }
      return { comics: [], maxPage: 1 };
    }
    if (kind === 'info') {
      if (!s.comic || typeof s.comic.loadInfo !== 'function') {
        throw new Error('该源缺少 comic.loadInfo');
      }
      return s.comic.loadInfo(a.id);
    }
    if (kind === 'ep') {
      if (!s.comic || typeof s.comic.loadEp !== 'function') {
        throw new Error('该源缺少 comic.loadEp');
      }
      return s.comic.loadEp(a.comicId, a.epId);
    }
    if (kind === 'imageConfigs') {
      var fn = s.comic && s.comic.onImageLoad;
      var urls = a.urls || [];
      if (typeof fn !== 'function') return {};
      var result = {};
      var chain = Promise.resolve();
      urls.forEach(function (u) {
        chain = chain.then(function () {
          return Promise.resolve(fn(u, a.comicId, a.epId, null)).then(function (cfg) {
            if (cfg) result[u] = cfg;
          }, function () {});
        });
      });
      return chain.then(function () { return result; });
    }
    if (kind === 'thumbConfigs') {
      var tfn = s.comic && s.comic.onThumbnailLoad;
      var turls = a.urls || [];
      if (typeof tfn !== 'function') return {};
      var tres = {};
      var tchain = Promise.resolve();
      turls.forEach(function (u) {
        tchain = tchain.then(function () {
          return Promise.resolve(tfn(u)).then(function (cfg) {
            if (cfg) tres[u] = cfg;
          }, function () {});
        });
      });
      return tchain.then(function () { return tres; });
    }
    throw new Error('未知的调用类型: ' + kind);
  };

  globalThis.__veneraRun = function (kind, args) {
    globalThis.__veneraJobState = 'pending';
    globalThis.__veneraJobValue = null;
    globalThis.__veneraJobError = null;
    var p;
    try {
      p = globalThis.__veneraDispatch(kind, args || {});
    } catch (e) {
      globalThis.__veneraJobError = globalThis.__veneraErr(e);
      globalThis.__veneraJobState = 'err';
      return;
    }
    Promise.resolve(p).then(function (v) {
      globalThis.__veneraJobValue = v;
      globalThis.__veneraJobState = 'ok';
    }, function (e) {
      globalThis.__veneraJobError = globalThis.__veneraErr(e);
      globalThis.__veneraJobState = 'err';
    });
  };

  // ────────────────────────── 导出到全局 ──────────────────────────
  globalThis.Convert = Convert;
  globalThis.Network = Network;
  globalThis.Cookie = function (o) {
    o = o || {};
    this.name = o.name;
    this.value = o.value;
    this.domain = o.domain;
  };
  globalThis.HtmlDocument = HtmlDocument;
  globalThis.HtmlElement = HtmlElement;
  globalThis.HtmlNode = HtmlNode;
  globalThis.Comic = Comic;
  globalThis.ComicDetails = ComicDetails;
  globalThis.Comment = Comment;
  globalThis.ImageLoadingConfig = ImageLoadingConfig;
  globalThis.Image = Image;
  globalThis.ComicSource = ComicSource;
})();
''';
