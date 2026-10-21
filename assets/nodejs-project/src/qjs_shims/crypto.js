/**
 * QuickJS 的 `node:crypto` 垫片（基于 crypto-js）。
 *
 * book_rule.js 用到：
 *   createHash('md5'|'sha1'|'sha256').update(s).digest('hex')
 *   createCipheriv('aes-128-cbc', key, iv) / createDecipheriv(...)
 *   randomUUID()
 */

import CryptoJS from 'crypto-js';
import { Buffer } from './buffer.js';

function toWordArray(buf) {
    const b = Buffer.from(buf);
    let hex = '';
    for (let i = 0; i < b.bytes.length; i++) {
        hex += b.bytes[i].toString(16).padStart(2, '0');
    }
    return CryptoJS.enc.Hex.parse(hex);
}

function fromWordArray(wa) {
    const hex = CryptoJS.enc.Hex.stringify(wa);
    return Buffer.from(hex, 'hex');
}

export function createHash(algorithm) {
    const alg = String(algorithm || '').toLowerCase();
    let data = '';
    return {
        update(v) {
            data += v == null ? '' : String(v);
            return this;
        },
        digest(enc) {
            let wa;
            if (alg === 'md5') wa = CryptoJS.MD5(data);
            else if (alg === 'sha1') wa = CryptoJS.SHA1(data);
            else if (alg === 'sha256') wa = CryptoJS.SHA256(data);
            else if (alg === 'sha512') wa = CryptoJS.SHA512(data);
            else throw new Error(`QuickJS 不支持 hash: ${algorithm}`);
            if (String(enc || 'hex') === 'hex') return CryptoJS.enc.Hex.stringify(wa);
            return CryptoJS.enc.Base64.stringify(wa);
        },
    };
}

function aesOptions(algorithm, iv) {
    const a = String(algorithm || '').toLowerCase();
    const mode = a.includes('ecb')
        ? CryptoJS.mode.ECB
        : a.includes('cfb')
          ? CryptoJS.mode.CFB
          : a.includes('ctr')
            ? CryptoJS.mode.CTR
            : CryptoJS.mode.CBC;
    const opts = { mode, padding: CryptoJS.pad.Pkcs7 };
    if (mode !== CryptoJS.mode.ECB && iv) opts.iv = toWordArray(iv);
    return opts;
}

export function createCipheriv(algorithm, key, iv) {
    const keyWA = toWordArray(key);
    const opts = aesOptions(algorithm, iv);
    const chunks = [];
    return {
        setAutoPadding() {},
        update(buf) {
            chunks.push(Buffer.from(buf));
            return Buffer.alloc(0);
        },
        final() {
            const plain = Buffer.concat(chunks);
            const encrypted = CryptoJS.AES.encrypt(toWordArray(plain), keyWA, opts);
            return fromWordArray(encrypted.ciphertext);
        },
    };
}

export function createDecipheriv(algorithm, key, iv) {
    const keyWA = toWordArray(key);
    const opts = aesOptions(algorithm, iv);
    const chunks = [];
    return {
        setAutoPadding() {},
        update(buf) {
            chunks.push(Buffer.from(buf));
            return Buffer.alloc(0);
        },
        final() {
            const cipher = Buffer.concat(chunks);
            const decrypted = CryptoJS.AES.decrypt(
                { ciphertext: toWordArray(cipher) },
                keyWA,
                opts,
            );
            return fromWordArray(decrypted);
        },
    };
}

export function randomUUID() {
    const hex = () => Math.floor(Math.random() * 65536).toString(16).padStart(4, '0');
    return `${hex()}${hex()}-${hex()}-4${hex().slice(1)}-a${hex().slice(1)}-${hex()}${hex()}${hex()}`;
}

export default {
    createHash,
    createCipheriv,
    createDecipheriv,
    randomUUID,
};
