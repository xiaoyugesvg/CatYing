/**
 * crypto-java.js —— 海阔官方 `assets/crypto-java.js` 的**纯 JS 垫片**。
 *
 * 官方那份是 CryptoJS + Java 风格 `CryptoUtil` 的封装（源里普遍这样用）：
 *
 *   const CryptoUtil = $.require('hiker://assets/crypto-java.js');
 *   const key = CryptoUtil.Data.parseUTF8('...');
 *   const text = CryptoUtil.Data.parseInputStream(input).toBase64(_base64.NO_WRAP);
 *   const out  = CryptoUtil.AES.decrypt(text, key, { iv, mode: 'AES/CBC/NoPadding' });
 *   return CryptoUtil.Data.parseBase64(out.toBase64(_base64.NO_WRAP)).toInputStream();
 *
 * 我们沙箱里本来就有 CryptoJS，所以这里只补“Java 风格”的包装：
 *   · WordArray → 带 toBase64 / toHex / toInputStream 的包装对象
 *   · mode/padding 字符串（"AES/CBC/NoPadding"）→ CryptoJS 的 mode/pad
 *   · parseInputStream：二进制字符串按 Latin1、看起来像 Base64 的按 Base64
 *
 * 放在 assets/hiker/files/ 下 ⇒ 运行时释放到 `<Documents>/hiker/builtin/`，
 * `hiker://assets/crypto-java.js` 就能 require 到（见 requireModule）。
 */
var CryptoUtil_C = CryptoJS;

function CryptoUtil_wrap(wa) {
    return {
        __wa: wa,
        toBase64: function () { return wa.toString(CryptoUtil_C.enc.Base64); },
        toHex: function () { return wa.toString(CryptoUtil_C.enc.Hex); },
        // 官方 `WordArray.toDigest().sha256()` 风格
        toDigest: function () {
            var self = wa;
            return {
                md5: function () { return CryptoUtil_C.MD5(self).toString(); },
                sha1: function () { return CryptoUtil_C.SHA1(self).toString(); },
                sha256: function () { return CryptoUtil_C.SHA256(self).toString(); },
                sha512: function () { return CryptoUtil_C.SHA512(self).toString(); },
                digest: function (algo) {
                    var f = CryptoUtil_C[String(algo || 'SHA256').toUpperCase()];
                    return f ? f(self).toString() : '';
                },
            };
        },
        toString: function () { return wa.toString(CryptoUtil_C.enc.Utf8); },
        // 官方返回 InputStream；JS 源最终要的多半是明文字符串
        toInputStream: function () { return wa.toString(CryptoUtil_C.enc.Utf8); },
    };
}

function CryptoUtil_cfg(o) {
    o = o || {};
    var out = {};
    var iv = o.iv && o.iv.__wa ? o.iv.__wa : o.iv;
    if (iv) out.iv = iv;
    var m = String(o.mode || '').toLowerCase();
    if (m) {
        out.mode = m.indexOf('cbc') >= 0 ? CryptoUtil_C.mode.CBC
            : m.indexOf('cfb') >= 0 ? CryptoUtil_C.mode.CFB
                : m.indexOf('ofb') >= 0 ? CryptoUtil_C.mode.OFB
                    : m.indexOf('ctr') >= 0 ? CryptoUtil_C.mode.CTR
                        : m.indexOf('ecb') >= 0 ? CryptoUtil_C.mode.ECB
                            : CryptoUtil_C.mode.CBC;
        out.padding = m.indexOf('nopadding') >= 0
            ? CryptoUtil_C.pad.NoPadding
            : CryptoUtil_C.pad.Pkcs7;
    }
    return out;
}

var Data = {
    parseUTF8: function (s) {
        return CryptoUtil_wrap(CryptoUtil_C.enc.Utf8.parse(String(s == null ? '' : s)));
    },
    parseString: function (s) {
        return CryptoUtil_wrap(CryptoUtil_C.enc.Utf8.parse(String(s == null ? '' : s)));
    },
    parseBase64: function (s) {
        return CryptoUtil_wrap(CryptoUtil_C.enc.Base64.parse(String(s == null ? '' : s)));
    },
    parseHex: function (s) {
        return CryptoUtil_wrap(CryptoUtil_C.enc.Hex.parse(String(s == null ? '' : s)));
    },
    parseInputStream: function (input) {
        if (input && input.__wa) return CryptoUtil_wrap(input.__wa);
        var s = String(input == null ? '' : input);
        // Base64 形态（长、字符集干净）按 Base64；其余按 Latin1 原字节
        var isB64 = s.length > 8 && /^[A-Za-z0-9+/=\r\n\s]+$/.test(s);
        var wa = isB64
            ? CryptoUtil_C.enc.Base64.parse(s)
            : CryptoUtil_C.enc.Latin1.parse(s);
        return CryptoUtil_wrap(wa);
    },
};

var AES = {
    decrypt: function (cipher, key, o) {
        var c = cipher && cipher.__wa
            ? cipher.__wa.toString(CryptoUtil_C.enc.Base64)
            : String(cipher == null ? '' : cipher);
        var k = key && key.__wa ? key.__wa : key;
        return CryptoUtil_wrap(CryptoUtil_C.AES.decrypt(c, k, CryptoUtil_cfg(o)));
    },
    encrypt: function (msg, key, o) {
        var m = msg && msg.__wa
            ? msg.__wa.toString(CryptoUtil_C.enc.Utf8)
            : String(msg == null ? '' : msg);
        var k = key && key.__wa ? key.__wa : key;
        return CryptoUtil_wrap(CryptoUtil_C.AES.encrypt(m, k, CryptoUtil_cfg(o)));
    },
};

var DES = {
    decrypt: function (cipher, key, o) {
        var c = cipher && cipher.__wa
            ? cipher.__wa.toString(CryptoUtil_C.enc.Base64)
            : String(cipher == null ? '' : cipher);
        var k = key && key.__wa ? key.__wa : key;
        return CryptoUtil_wrap(CryptoUtil_C.DES.decrypt(c, k, CryptoUtil_cfg(o)));
    },
    encrypt: function (msg, key, o) {
        var m = msg && msg.__wa
            ? msg.__wa.toString(CryptoUtil_C.enc.Utf8)
            : String(msg == null ? '' : msg);
        var k = key && key.__wa ? key.__wa : key;
        return CryptoUtil_wrap(CryptoUtil_C.DES.encrypt(m, k, CryptoUtil_cfg(o)));
    },
};

// 模块导出（见 runInModuleScope：优先读 $.exports）
$.exports = {
    Data: Data,
    AES: AES,
    DES: DES,
    Base64: CryptoUtil_C.enc.Base64,
    Utf8: CryptoUtil_C.enc.Utf8,
    Hex: CryptoUtil_C.enc.Hex,
    MD5: CryptoUtil_C.MD5,
    SHA1: CryptoUtil_C.SHA1,
    SHA256: CryptoUtil_C.SHA256,
};
