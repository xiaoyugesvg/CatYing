/// 书源 JS 引擎的标准全局垫片（纯 JS，一次性注入 QuickJS 全局）。
///
/// 背景（2026-10-12，用户要求评估 qjs_ultra 移植）：现有 `quickjs_engine`
/// 已具备超时中断（10s）/64MB 堆上限/繁简转换/java 宿主对象，但缺少
/// Legado/TVBox 书源脚本常用的标准全局：TextEncoder/TextDecoder(utf-8)、
/// Buffer、crypto(md5/sha1/sha256)、URL/URLSearchParams、atob/btoa 兜底。
/// 这些以**纯 JS 垫片**注入（MIT 干净、不碰 C 桥、不碰打包），
/// 对齐 qjs_ultra 内置 C 能力的常用子集。
///
/// ⚠️ GBK/GB2312 解码**不在 JS 层处理**：书源抓取层（xiaoshuo_http.dart）
///    已按响应字符集自动转 UTF-8，脚本拿到的是已解码文本；
///    显式 `new TextDecoder('gbk')` 的场景抛错提示，避免伪解码。
library;

/// 书源 JS 标准全局垫片源码（顶层 IIFE，带 typeof 防御，幂等可重注入）。
const String jsStandardPolyfills = r'''
(function () {
  'use strict';
  var hasOwn = Object.prototype.hasOwnProperty;

  // ── atob / btoa（QuickJS 通常内置，缺了就补一份）──────────────────
  // ⚠️ base64 编解码函数提到 IIFE 顶层：'use strict' 下块内 function 声明
  //    是块级作用域，Buffer 垫片也要用它们，放块内会 ReferenceError。
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function b64Encode(u8) {
    var out = '', i = 0;
    for (; i + 2 < u8.length; i += 3) {
      var n = (u8[i] << 16) | (u8[i + 1] << 8) | u8[i + 2];
      out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + B64[(n >> 6) & 63] + B64[n & 63];
    }
    var rest = u8.length - i;
    if (rest === 1) {
      var n1 = u8[i] << 16;
      out += B64[(n1 >> 18) & 63] + B64[(n1 >> 12) & 63] + '==';
    } else if (rest === 2) {
      var n2 = (u8[i] << 16) | (u8[i + 1] << 8);
      out += B64[(n2 >> 18) & 63] + B64[(n2 >> 12) & 63] + B64[(n2 >> 6) & 63] + '=';
    }
    return out;
  }
  function b64Decode(s) {
    s = String(s).replace(/[^A-Za-z0-9+/=]/g, '');
    var out = [], buf = 0, bits = 0;
    for (var i = 0; i < s.length; i++) {
      if (s[i] === '=') break;
      buf = (buf << 6) | B64.indexOf(s[i]);
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out.push((buf >> bits) & 255);
      }
    }
    return out;
  }
  if (typeof atob !== 'function') {
    globalThis.atob = function (s) {
      var bytes = b64Decode(s);
      var t = '';
      for (var i = 0; i < bytes.length; i++) t += String.fromCharCode(bytes[i]);
      return t;
    };
  }
  if (typeof btoa !== 'function') {
    globalThis.btoa = function (s) {
      var bytes = [];
      s = String(s);
      for (var i = 0; i < s.length; i++) bytes.push(s.charCodeAt(i) & 255);
      return b64Encode(bytes);
    };
  }

  // ── TextEncoder / TextDecoder（utf-8）───────────────────────────────
  if (typeof TextEncoder === 'undefined') {
    globalThis.TextEncoder = function () {};
    TextEncoder.prototype.encode = function (str) {
      str = String(str == null ? '' : str);
      var bytes = [];
      for (var i = 0; i < str.length; i++) {
        var c = str.charCodeAt(i);
        if (c < 0x80) {
          bytes.push(c);
        } else if (c < 0x800) {
          bytes.push(0xc0 | (c >> 6), 0x80 | (c & 63));
        } else if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
          var lo = str.charCodeAt(i + 1);
          if (lo >= 0xdc00 && lo <= 0xdfff) {
            var cp = 0x10000 + ((c - 0xd800) << 10) + (lo - 0xdc00);
            bytes.push(
              0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63),
              0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
            i++;
          } else {
            bytes.push(0xef, 0xbf, 0xbd);
          }
        } else if (c >= 0xd800 && c <= 0xdfff) {
          bytes.push(0xef, 0xbf, 0xbd);
        } else if (c < 0x10000) {
          bytes.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        } else {
          bytes.push(
            0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63),
            0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        }
      }
      return new Uint8Array(bytes);
    };
  }

  if (typeof TextDecoder === 'undefined') {
    globalThis.TextDecoder = function (label) {
      var lab = String(label || 'utf-8').toLowerCase().replace(/[^a-z0-9]/g, '');
      if (lab === 'gbk' || lab === 'gb2312' || lab === 'gb18030') {
        throw new Error('TextDecoder(GBK/GB2312) 不在 JS 层支持：书源抓取层已按响应字符集自动转 UTF-8');
      }
    };
    TextDecoder.prototype.decode = function (input) {
      var bytes = input instanceof Uint8Array ? input : new Uint8Array(input || []);
      var out = '', i = 0;
      while (i < bytes.length) {
        var b = bytes[i];
        if (b < 0x80) {
          out += String.fromCharCode(b);
          i++;
        } else if (b >= 0xc2 && b < 0xe0 && i + 1 < bytes.length) {
          out += String.fromCharCode(((b & 31) << 6) | (bytes[i + 1] & 63));
          i += 2;
        } else if (b >= 0xe0 && b < 0xf0 && i + 2 < bytes.length) {
          out += String.fromCharCode(((b & 15) << 12) | ((bytes[i + 1] & 63) << 6) | (bytes[i + 2] & 63));
          i += 3;
        } else if (b >= 0xf0 && b < 0xf5 && i + 3 < bytes.length) {
          var cp = ((b & 7) << 18) | ((bytes[i + 1] & 63) << 12) | ((bytes[i + 2] & 63) << 6) | (bytes[i + 3] & 63);
          out += String.fromCharCode(0xd800 + ((cp - 0x10000) >> 10), 0xdc00 + ((cp - 0x10000) & 1023));
          i += 4;
        } else {
          out += '\ufffd';
          i++;
        }
      }
      return out;
    };
  }

  // ── Buffer（Node 风格精简：from/toString/concat/alloc/byteLength）───
  if (typeof Buffer === 'undefined') {
    function qjsBuffer(data, encoding) {
      if (data == null) {
        this._d = new Uint8Array(0);
      } else if (typeof data === 'string') {
        this._d = qjsBufferStr(data, encoding);
      } else if (data instanceof Uint8Array) {
        this._d = new Uint8Array(data);
      } else if (Array.isArray(data)) {
        this._d = new Uint8Array(data);
      } else {
        this._d = new Uint8Array(0);
      }
      Object.defineProperty(this, 'length', { get: function () { return this._d.length; } });
    }
    function qjsBufferStr(s, encoding) {
      var enc = String(encoding || 'utf8').toLowerCase();
      if (enc === 'base64') {
        var bytes = b64Decode(s);
        return new Uint8Array(bytes);
      }
      if (enc === 'hex') {
        var h = String(s).replace(/[^0-9a-fA-F]/g, '');
        var out = new Uint8Array(h.length >> 1);
        for (var i = 0; i < out.length; i++) {
          out[i] = parseInt(h.substr(i * 2, 2), 16);
        }
        return out;
      }
      if (enc === 'utf8' || enc === 'utf-8') {
        return new TextEncoder().encode(s);
      }
      // 其它编码按 Latin-1 兜底
      var out2 = new Uint8Array(s.length);
      for (var j = 0; j < s.length; j++) out2[j] = s.charCodeAt(j) & 255;
      return out2;
    }
    qjsBuffer.prototype.toString = function (encoding) {
      var enc = String(encoding || 'utf8').toLowerCase();
      var d = this._d;
      if (enc === 'base64') return b64Encode(d);
      if (enc === 'hex') {
        var hx = '';
        for (var i = 0; i < d.length; i++) {
          var v = d[i].toString(16);
          hx += v.length < 2 ? '0' + v : v;
        }
        return hx;
      }
      return new TextDecoder().decode(d);
    };
    qjsBuffer.from = function (data, encoding) { return new qjsBuffer(data, encoding); };
    qjsBuffer.alloc = function (n) { var b = new qjsBuffer(null); b._d = new Uint8Array(n); return b; };
    qjsBuffer.concat = function (list) {
      var total = 0;
      for (var i = 0; i < list.length; i++) total += list[i]._d.length;
      var out = new Uint8Array(total);
      var off = 0;
      for (var j = 0; j < list.length; j++) {
        out.set(list[j]._d, off);
        off += list[j]._d.length;
      }
      var b = new qjsBuffer(null);
      b._d = out;
      return b;
    };
    qjsBuffer.byteLength = function (s, encoding) {
      return qjsBufferStr(s, encoding).length;
    };
    qjsBuffer.isBuffer = function (o) { return o instanceof qjsBuffer; };
    globalThis.Buffer = qjsBuffer;
  }

  // ── crypto：createHash(md5/sha1/sha256).update().digest() + randomBytes ──
  if (typeof globalThis.crypto === 'undefined' ||
      typeof globalThis.crypto.createHash !== 'function') {
    var C = globalThis.crypto || {};
    globalThis.crypto = C;

    function utf8Bytes(input) {
      if (input == null) return [];
      // 跨块引用全局 Buffer（不能直接引用 Buffer 块内的局部 qjsBuffer）
      if (typeof Buffer !== 'undefined' && input instanceof Buffer) {
        return Array.prototype.slice.call(input._d);
      }
      if (input instanceof Uint8Array) return Array.prototype.slice.call(input);
      if (typeof input === 'string') return Array.prototype.slice.call(new TextEncoder().encode(input));
      return Array.prototype.slice.call(new TextEncoder().encode(String(input)));
    }

    // ── MD5 ─────────────────────────────────────────────────────────
    function md5Bytes(bytes) {
      var s = new Uint8Array(bytes.length + 72);
      s.set(bytes);
      var bitLen = bytes.length * 8;
      var ml = bytes.length + 1;
      var rem = ml % 64;
      // 0x80 + 填充零 后总长必须 ≡ 56 (mod 64)，再拼 8 字节长度
      var padLen = rem <= 56 ? 57 - rem : 121 - rem;
      s[bytes.length] = 0x80;
      var i;
      for (i = 1; i < padLen; i++) s[bytes.length + i] = 0;
      // ⚠️ JS 移位对位移 ≥32 取模 32（`bitLen >>> 32` === `bitLen >>> 0`），
      //    高位字节必须用除法取整，不能直接移位。
      for (i = 0; i < 8; i++) {
        s[bytes.length + padLen + i] = Math.floor(bitLen / Math.pow(2, 8 * i)) % 256;
      }
      var n = (bytes.length + padLen + 8) / 64;
      var a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
      function f(x, y, z) { return (x & y) | (~x & z); }
      function g(x, y, z) { return (x & z) | (y & ~z); }
      function h(x, y, z) { return x ^ y ^ z; }
      function i2(x, y, z) { return y ^ (x | ~z); }
      function rotl(x, c) { return (x << c) | (x >>> (32 - c)); }
      var K = [
        0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a,
        0xa8304613, 0xfd469501, 0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
        0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821, 0xf61e2562, 0xc040b340,
        0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
        0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8,
        0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
        0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70, 0x289b7ec6, 0xeaa127fa,
        0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
        0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92,
        0xffeff47d, 0x85845dd1, 0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
        0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391
      ];
      var S = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
      ];
      function M(i2, j) {
        var off = i2 * 64 + j * 4;
        return (s[off] | (s[off + 1] << 8) | (s[off + 2] << 16) | (s[off + 3] << 24)) >>> 0;
      }
      for (var blk = 0; blk < n; blk++) {
        var A = a0, B = b0, Cc = c0, D = d0;
        var round = 0;
        for (; round < 16; round++) {
          var t = rotl((A + f(B, Cc, D) + M(blk, round) + K[round]) >>> 0, S[round]);
          A = D; D = Cc; Cc = B; B = (B + t) >>> 0;
        }
        for (; round < 32; round++) {
          var rr = (5 * round + 1) & 15;
          t = rotl((A + g(B, Cc, D) + M(blk, rr) + K[round]) >>> 0, S[round]);
          A = D; D = Cc; Cc = B; B = (B + t) >>> 0;
        }
        for (; round < 48; round++) {
          var rr2 = (3 * round + 5) & 15;
          t = rotl((A + h(B, Cc, D) + M(blk, rr2) + K[round]) >>> 0, S[round]);
          A = D; D = Cc; Cc = B; B = (B + t) >>> 0;
        }
        for (; round < 64; round++) {
          var rr3 = (7 * round) & 15;
          t = rotl((A + i2(B, Cc, D) + M(blk, rr3) + K[round]) >>> 0, S[round]);
          A = D; D = Cc; Cc = B; B = (B + t) >>> 0;
        }
        a0 = (a0 + A) >>> 0; b0 = (b0 + B) >>> 0; c0 = (c0 + Cc) >>> 0; d0 = (d0 + D) >>> 0;
      }
      function le32(x) {
        return [x & 255, (x >>> 8) & 255, (x >>> 16) & 255, (x >>> 24) & 255];
      }
      return le32(a0).concat(le32(b0), le32(c0), le32(d0));
    }

    // ── SHA-1 ────────────────────────────────────────────────────────
    function sha1Bytes(bytes) {
      var ml = bytes.length;
      var s = new Uint8Array(((ml + 8) >> 6) * 64 + 64);
      s.set(bytes);
      s[ml] = 0x80;
      var bitLen = ml * 8;
      // ⚠️ 移位 ≥32 会被 JS 取模 32，64 位长度的高位字节用除法取整
      for (var i = 0; i < 8; i++) {
        s[s.length - 1 - i] = Math.floor(bitLen / Math.pow(2, 8 * i)) % 256;
      }
      var h0 = 0x67452301, h1 = 0xefcdab89, h2 = 0x98badcfe, h3 = 0x10325476, h4 = 0xc3d2e1f0;
      function rol(x, c) { return (x << c) | (x >>> (32 - c)); }
      for (var blk = 0; blk < s.length / 64; blk++) {
        var w = [];
        for (var j = 0; j < 16; j++) {
          var off = blk * 64 + j * 4;
          w[j] = ((s[off] << 24) | (s[off + 1] << 16) | (s[off + 2] << 8) | s[off + 3]) >>> 0;
        }
        for (var k = 16; k < 80; k++) w[k] = rol((w[k - 3] ^ w[k - 8] ^ w[k - 14] ^ w[k - 16]) >>> 0, 1);
        var a = h0, b = h1, c = h2, d = h3, e = h4;
        for (var t = 0; t < 80; t++) {
          var f, kt;
          if (t < 20) { f = (b & c) | (~b & d); kt = 0x5a827999; }
          else if (t < 40) { f = b ^ c ^ d; kt = 0x6ed9eba1; }
          else if (t < 60) { f = (b & c) | (b & d) | (c & d); kt = 0x8f1bbcdc; }
          else { f = b ^ c ^ d; kt = 0xca62c1d6; }
          var tmp = (rol(a, 5) + f + e + kt + w[t]) >>> 0;
          e = d; d = c; c = rol(b, 30); b = a; a = tmp;
        }
        h0 = (h0 + a) >>> 0; h1 = (h1 + b) >>> 0; h2 = (h2 + c) >>> 0;
        h3 = (h3 + d) >>> 0; h4 = (h4 + e) >>> 0;
      }
      function be32(x) {
        return [(x >>> 24) & 255, (x >>> 16) & 255, (x >>> 8) & 255, x & 255];
      }
      return be32(h0).concat(be32(h1), be32(h2), be32(h3), be32(h4));
    }

    // ── SHA-256 ──────────────────────────────────────────────────────
    function sha256Bytes(bytes) {
      var ml = bytes.length;
      var s = new Uint8Array(((ml + 8) >> 6) * 64 + 64);
      s.set(bytes);
      s[ml] = 0x80;
      var bitLenHi = 0, bitLenLo = ml * 8;
      if (bitLenLo > 0xffffffff) { bitLenHi = Math.floor(bitLenLo / 0x100000000); bitLenLo = bitLenLo >>> 0; }
      for (var i = 0; i < 4; i++) s[s.length - 8 + i] = (bitLenHi >>> (24 - i * 8)) & 255;
      for (var j = 0; j < 4; j++) s[s.length - 4 + j] = (bitLenLo >>> (24 - j * 8)) & 255;
      var K = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
        0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
        0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
      ];
      var h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a,
          h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;
      function rotr(x, c) { return (x >>> c) | (x << (32 - c)); }
      for (var blk = 0; blk < s.length / 64; blk++) {
        var w = [];
        for (var t = 0; t < 16; t++) {
          var off = blk * 64 + t * 4;
          w[t] = ((s[off] << 24) | (s[off + 1] << 16) | (s[off + 2] << 8) | s[off + 3]) >>> 0;
        }
        for (var t2 = 16; t2 < 64; t2++) {
          var s0 = rotr(w[t2 - 15], 7) ^ rotr(w[t2 - 15], 18) ^ (w[t2 - 15] >>> 3);
          var s1 = rotr(w[t2 - 2], 17) ^ rotr(w[t2 - 2], 19) ^ (w[t2 - 2] >>> 10);
          w[t2] = (w[t2 - 16] + s0 + w[t2 - 7] + s1) >>> 0;
        }
        var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
        for (var t3 = 0; t3 < 64; t3++) {
          var S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
          var ch = (e & f) ^ (~e & g);
          var temp1 = (h + S1 + ch + K[t3] + w[t3]) >>> 0;
          var S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
          var maj = (a & b) ^ (a & c) ^ (b & c);
          var temp2 = (S0 + maj) >>> 0;
          h = g; g = f; f = e; e = (d + temp1) >>> 0; d = c; c = b; b = a; a = (temp1 + temp2) >>> 0;
        }
        h0 = (h0 + a) >>> 0; h1 = (h1 + b) >>> 0; h2 = (h2 + c) >>> 0; h3 = (h3 + d) >>> 0;
        h4 = (h4 + e) >>> 0; h5 = (h5 + f) >>> 0; h6 = (h6 + g) >>> 0; h7 = (h7 + h) >>> 0;
      }
      function be32(x) {
        return [(x >>> 24) & 255, (x >>> 16) & 255, (x >>> 8) & 255, x & 255];
      }
      return be32(h0).concat(be32(h1), be32(h2), be32(h3), be32(h4), be32(h5), be32(h6), be32(h7));
    }

    function toHex(bytes) {
      var hx = '';
      for (var i = 0; i < bytes.length; i++) {
        var v = bytes[i].toString(16);
        hx += v.length < 2 ? '0' + v : v;
      }
      return hx;
    }

    function Hash(alg) {
      this._alg = alg;
      this._buf = [];
    }
    Hash.prototype.update = function (data) {
      this._buf = this._buf.concat(utf8Bytes(data));
      return this;
    };
    Hash.prototype.digest = function (encoding) {
      var raw;
      if (this._alg === 'md5') raw = md5Bytes(this._buf);
      else if (this._alg === 'sha1') raw = sha1Bytes(this._buf);
      else if (this._alg === 'sha256') raw = sha256Bytes(this._buf);
      else throw new Error('不支持的摘要算法: ' + this._alg);
      var enc = String(encoding || 'hex').toLowerCase();
      if (enc === 'base64') return b64Encode(raw);
      if (enc === 'hex') return toHex(raw);
      var u8 = new Uint8Array(raw);
      return u8;
    };
    C.createHash = function (alg) {
      return new Hash(String(alg).toLowerCase());
    };
    C.randomBytes = function (n) {
      var out = new Uint8Array(n);
      for (var i = 0; i < n; i++) out[i] = (Math.random() * 256) & 255;
      return out;
    };
    // WebCrypto 风格最常用两个方法
    C.subtle = C.subtle || {
      digest: function (algo, data) {
        var name = (algo && algo.name || String(algo)).toLowerCase();
        var raw = utf8Bytes(data);
        var out;
        if (name === 'sha-1') out = sha1Bytes(raw);
        else if (name === 'sha-256') out = sha256Bytes(raw);
        else if (name === 'md5') out = md5Bytes(raw);
        else return Promise.reject(new Error('不支持的摘要: ' + name));
        return Promise.resolve(new Uint8Array(out));
      }
    };
  }

  // ── URLSearchParams + URL（精简 polyfill）──────────────────────────
  if (typeof URLSearchParams === 'undefined') {
    function qjsURLSearchParams(init) {
      this._pairs = [];
      if (typeof init === 'string') {
        var q = String(init).replace(/^[?#]/, '');
        if (q) {
          var parts = q.split('&');
          for (var i = 0; i < parts.length; i++) {
            if (!parts[i]) continue;
            var eq = parts[i].indexOf('=');
            if (eq < 0) this._pairs.push([decodeURIComponent(parts[i].replace(/\+/g, ' ')), '']);
            else this._pairs.push([
              decodeURIComponent(parts[i].slice(0, eq).replace(/\+/g, ' ')),
              decodeURIComponent(parts[i].slice(eq + 1).replace(/\+/g, ' '))
            ]);
          }
        }
      } else if (init && typeof init === 'object') {
        if (typeof init.forEach === 'function') {
          var self = this;
          init.forEach(function (v, k) { self._pairs.push([String(k), String(v)]); });
        } else {
          var self2 = this;
          Object.keys(init).forEach(function (k) {
            var v = init[k];
            if (Array.isArray(v)) v.forEach(function (x) { self2._pairs.push([k, String(x)]); });
            else self2._pairs.push([k, String(v)]);
          });
        }
      }
    }
    function spEncode(s) { return encodeURIComponent(String(s)).replace(/%20/g, '+'); }
    qjsURLSearchParams.prototype.append = function (k, v) { this._pairs.push([String(k), String(v)]); };
    qjsURLSearchParams.prototype.set = function (k, v) {
      k = String(k);
      for (var i = 0; i < this._pairs.length; i++) {
        if (this._pairs[i][0] === k) {
          this._pairs[i][1] = String(v); // 保持原位置，仅替换值（对齐标准行为）
          return;
        }
      }
      this._pairs.push([k, String(v)]);
    };
    qjsURLSearchParams.prototype.get = function (k) {
      for (var i = 0; i < this._pairs.length; i++) {
        if (this._pairs[i][0] === String(k)) return this._pairs[i][1];
      }
      return null;
    };
    qjsURLSearchParams.prototype.getAll = function (k) {
      var out = [];
      for (var i = 0; i < this._pairs.length; i++) {
        if (this._pairs[i][0] === String(k)) out.push(this._pairs[i][1]);
      }
      return out;
    };
    qjsURLSearchParams.prototype.has = function (k) {
      for (var i = 0; i < this._pairs.length; i++) {
        if (this._pairs[i][0] === String(k)) return true;
      }
      return false;
    };
    qjsURLSearchParams.prototype.delete = function (k) {
      for (var i = this._pairs.length - 1; i >= 0; i--) {
        if (this._pairs[i][0] === String(k)) this._pairs.splice(i, 1);
      }
    };
    qjsURLSearchParams.prototype.forEach = function (fn) {
      for (var i = 0; i < this._pairs.length; i++) fn(this._pairs[i][1], this._pairs[i][0]);
    };
    qjsURLSearchParams.prototype.toString = function () {
      var out = [];
      for (var i = 0; i < this._pairs.length; i++) {
        out.push(spEncode(this._pairs[i][0]) + '=' + spEncode(this._pairs[i][1]));
      }
      return out.join('&');
    };
    globalThis.URLSearchParams = qjsURLSearchParams;
  }

  if (typeof URL === 'undefined') {
    function qjsURL(input, base) {
      var s = String(input || '').trim();
      var baseStr = base ? String(base).trim() : '';
      if (!/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(s) && baseStr) {
        var bi = baseStr.indexOf('?');
        if (bi >= 0) baseStr = baseStr.slice(0, bi);
        if (/^\//.test(s)) {
          var m = baseStr.match(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^\/]+/);
          if (m) s = m[0] + s;
        } else {
          var m2 = baseStr.match(/^(.*\/)/);
          s = (m2 ? m2[1] : baseStr + '/') + s;
        }
      }
      this._href = s;
      var proto = s.match(/^([a-zA-Z][a-zA-Z0-9+.-]*):/);
      this._protocol = proto ? proto[1] + ':' : '';
      var rest = proto ? s.slice(this._protocol.length) : s;
      var hashIdx = rest.indexOf('#');
      this._hash = hashIdx >= 0 ? rest.slice(hashIdx) : '';
      if (hashIdx >= 0) rest = rest.slice(0, hashIdx);
      var qIdx = rest.indexOf('?');
      this._search = qIdx >= 0 ? rest.slice(qIdx) : '';
      var path = qIdx >= 0 ? rest.slice(0, qIdx) : rest;
      var m3 = rest.match(/^\/\/([^\/?#]*)/);
      if (m3) {
        var hostPort = m3[1];
        var colon = hostPort.lastIndexOf(':');
        if (colon > 0 && /^\d+$/.test(hostPort.slice(colon + 1))) {
          this._hostname = hostPort.slice(0, colon);
          this._port = hostPort.slice(colon + 1);
        } else {
          this._hostname = hostPort;
          this._port = '';
        }
        // 标准 URL.host = hostname + ':' + port（无端口时就是 hostname）
        this._host = this._port ? this._hostname + ':' + this._port : this._hostname;
        this._origin = this._protocol + '//' + this._host;
      } else {
        this._host = '';
        this._hostname = '';
        this._port = '';
        this._origin = 'null';
      }
      this._pathname = m3 ? (path.length > m3[0].length ? path.slice(m3[0].length) : '/') : path;
      if (!this._pathname) this._pathname = '/';
      this._searchParams = new URLSearchParams(this._search);
    }
    qjsURL.prototype.toString = function () {
      var sp = this._searchParams.toString();
      var search = sp ? (this._search.indexOf('?') >= 0 ? '?' + sp : this._search) : this._search;
      return this._protocol + (this._host ? '//' + this._host : '') +
        this._pathname + search + this._hash;
    };
    qjsURL.prototype.toJSON = function () { return this.toString(); };
    Object.defineProperty(qjsURL.prototype, 'href', {
      get: function () { return this.toString(); },
      set: function (v) { this._href = String(v); }
    });
    qjsURL.prototype.get = function (name) { return this[name]; };
    qjsURL.prototype.set = function (name, v) { this['_' + name] = String(v); };
    Object.defineProperty(qjsURL.prototype, 'search', {
      get: function () {
        var sp = this._searchParams.toString();
        return sp ? '?' + sp : '';
      }
    });
    Object.defineProperty(qjsURL.prototype, 'searchParams', { get: function () { return this._searchParams; } });
    ['protocol', 'host', 'hostname', 'port', 'pathname', 'hash', 'origin'].forEach(function (n) {
      Object.defineProperty(qjsURL.prototype, n, {
        get: function () { return this['_' + n]; },
        set: function (v) { this['_' + n] = String(v); }
      });
    });
    globalThis.URL = qjsURL;
  }

  // ── performance（Date.now 兜底，部分脚本会读）──────────────────────
  if (typeof globalThis.performance === 'undefined') {
    globalThis.performance = { now: function () { return Date.now(); } };
  }
})();
''';
