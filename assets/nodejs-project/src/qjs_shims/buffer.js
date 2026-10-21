/**
 * QuickJS 的 Buffer 垫片（只覆盖书源规则用到的部分）。
 *
 * book_rule.js 里用到：
 *   Buffer.from(str, 'base64'|'hex'|'utf8')
 *   Buffer.from(u8).toString('base64'|'hex'|'utf8')
 *   Buffer.concat([...]).toString('base64'|'utf8')
 * QuickJS 没有 Node 的 Buffer，这里用 Uint8Array 包一层。
 */

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function utf8Encode(str) {
    const s = String(str == null ? '' : str);
    const out = [];
    for (let i = 0; i < s.length; i++) {
        let c = s.charCodeAt(i);
        if (c < 0x80) out.push(c);
        else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
        else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
            const c2 = s.charCodeAt(i + 1);
            if (c2 >= 0xdc00 && c2 <= 0xdfff) {
                const cp = 0x10000 + ((c - 0xd800) << 10) + (c2 - 0xdc00);
                out.push(
                    0xf0 | (cp >> 18),
                    0x80 | ((cp >> 12) & 63),
                    0x80 | ((cp >> 6) & 63),
                    0x80 | (cp & 63),
                );
                i++;
            } else {
                out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
            }
        } else {
            out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        }
    }
    return new Uint8Array(out);
}

function utf8Decode(u8) {
    let out = '';
    for (let i = 0; i < u8.length; ) {
        const c = u8[i++];
        if (c < 0x80) out += String.fromCharCode(c);
        else if (c < 0xe0) out += String.fromCharCode(((c & 31) << 6) | (u8[i++] & 63));
        else if (c < 0xf0) {
            out += String.fromCharCode(((c & 15) << 12) | ((u8[i++] & 63) << 6) | (u8[i++] & 63));
        } else {
            let cp = ((c & 7) << 18) | ((u8[i++] & 63) << 12) | ((u8[i++] & 63) << 6) | (u8[i++] & 63);
            cp -= 0x10000;
            out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 1023));
        }
    }
    return out;
}

function b64encode(u8) {
    let out = '';
    let i = 0;
    for (; i + 2 < u8.length; i += 3) {
        const n = (u8[i] << 16) | (u8[i + 1] << 8) | u8[i + 2];
        out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + B64[(n >> 6) & 63] + B64[n & 63];
    }
    const rem = u8.length - i;
    if (rem === 1) {
        const n = u8[i] << 16;
        out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + '==';
    } else if (rem === 2) {
        const n = (u8[i] << 16) | (u8[i + 1] << 8);
        out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63] + B64[(n >> 6) & 63] + '=';
    }
    return out;
}

function b64decode(str) {
    const s = String(str || '').replace(/[^A-Za-z0-9+/=]/g, '');
    const pad = s.endsWith('==') ? 2 : s.endsWith('=') ? 1 : 0;
    const len = s.length;
    const u8 = new Uint8Array(Math.max(0, Math.floor(len / 4) * 3 - pad));
    // ⚠️ '=' 不在 B64 表里，indexOf 返回 -1；直接参与位运算会把最后一个字节
    // 写成 0xff（AES 密文尾字节被改 → 解密全是乱码/空）。这里按 0 处理。
    const at = (ch) => {
        const k = B64.indexOf(ch);
        return k < 0 ? 0 : k;
    };
    let p = 0;
    for (let i = 0; i < len; i += 4) {
        const n =
            (at(s[i]) << 18) |
            (at(s[i + 1]) << 12) |
            (at(s[i + 2]) << 6) |
            at(s[i + 3]);
        if (p < u8.length) u8[p++] = (n >> 16) & 255;
        if (p < u8.length) u8[p++] = (n >> 8) & 255;
        if (p < u8.length) u8[p++] = n & 255;
    }
    return u8;
}

function hexToBytes(str) {
    const s = String(str || '');
    const u8 = new Uint8Array(Math.floor(s.length / 2));
    for (let i = 0; i < u8.length; i++) {
        u8[i] = parseInt(s.substr(i * 2, 2), 16) || 0;
    }
    return u8;
}

function bytesToHex(u8) {
    let out = '';
    for (let i = 0; i < u8.length; i++) out += u8[i].toString(16).padStart(2, '0');
    return out;
}

class QBuffer {
    constructor(u8) {
        this.bytes = u8 instanceof Uint8Array ? u8 : new Uint8Array(u8 || 0);
        this.length = this.bytes.length;
    }
    toString(enc) {
        const e = String(enc || 'utf8').toLowerCase();
        if (e === 'base64') return b64encode(this.bytes);
        if (e === 'hex') return bytesToHex(this.bytes);
        return utf8Decode(this.bytes);
    }
    slice(a, b) {
        return new QBuffer(this.bytes.slice(a, b));
    }
}

function from(value, enc) {
    if (value instanceof QBuffer) return value;
    if (value instanceof Uint8Array) return new QBuffer(value);
    if (value instanceof ArrayBuffer) return new QBuffer(new Uint8Array(value));
    if (Array.isArray(value)) return new QBuffer(new Uint8Array(value));
    const e = String(enc || 'utf8').toLowerCase();
    const s = String(value == null ? '' : value);
    if (e === 'base64') return new QBuffer(b64decode(s));
    if (e === 'hex') return new QBuffer(hexToBytes(s));
    return new QBuffer(utf8Encode(s));
}

function concat(list) {
    let total = 0;
    for (const it of list) total += it && it.bytes ? it.bytes.length : 0;
    const out = new Uint8Array(total);
    let p = 0;
    for (const it of list) {
        if (!it || !it.bytes) continue;
        out.set(it.bytes, p);
        p += it.bytes.length;
    }
    return new QBuffer(out);
}

const Buffer = {
    from,
    concat,
    alloc: (n) => new QBuffer(new Uint8Array(n)),
    isBuffer: (v) => v instanceof QBuffer,
    byteLength: (v) => (typeof v === 'string' ? utf8Encode(v).length : v && v.length ? v.length : 0),
};

// book_rule.js 直接用裸 `Buffer`，所以也挂到全局
globalThis.Buffer = Buffer;

export { Buffer };
export default { Buffer };
