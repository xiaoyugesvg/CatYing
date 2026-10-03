/**
 * LX 脚本执行引擎（Node 侧）
 *
 * ── 背景：为什么可以用 NodeMobile，不会像 flutter_tts 那样闪退 ──
 * flutter_tts 是 **Flutter 插件**，闪退发生在「插件注册阶段」：原生库没被
 * 链接进二进制 → GeneratedPluginRegistrant 找不到 → SIGABRT。
 *
 * NodeMobile **不是 Flutter 插件**：它是 xcframework，由 CI 注入 pbxproj，
 * Dart 侧通过**本地 HTTP 端口**与它通信（`nodejs_manager.dart` 里没有任何
 * MethodChannel）。LX 脚本是在 Node 里跑的，**完全绕开 Flutter 插件系统**，
 * 所以那个闪退机制在这里不存在。
 *
 * ── 但要防的是另外两件事（与链接无关）──────────────────────────
 * 1. **脚本死循环** —— Node 与 App 同进程，事件循环被占住 = 整个 App 卡死。
 *    对策：`vm.runInNewContext` + `timeout` 硬超时。
 * 2. **脚本越权** —— 用户导入的脚本不该能读文件系统、不该能起进程。
 *    对策：白名单注入，**不提供** `require` / `process` / `fs` / `child_process`。
 *
 * ── 支持的 API（对齐 Beans 的 LXScriptSourceRunner）───────────
 *   globalThis.lx = {
 *     EVENT_NAMES, env, version,
 *     request(url, options, callback),
 *     on(event, handler), send(event, payload),
 *     utils: { buffer, crypto: { md5, aesEncrypt, randomBytes } },
 *   }
 */

import vm from 'vm';
import crypto from 'crypto';
import axios from 'axios';

/** 脚本硬超时（毫秒）。超时即中断，绝不让它占住事件循环。 */
const SCRIPT_TIMEOUT_MS = 8000;

/** 脚本大小上限（字符）。超过直接拒绝，避免解析本身把内存吃爆。 */
const MAX_SCRIPT_CHARS = 512 * 1024;

/** 单次请求超时 */
const REQUEST_TIMEOUT_MS = 12000;

/** 响应体最大字节数（防止脚本拉一个巨大文件） */
const MAX_RESPONSE_BYTES = 8 * 1024 * 1024;

// ============================================================
// lx.utils.crypto
// ============================================================

function md5(value) {
    return crypto.createHash('md5').update(String(value ?? ''), 'utf8').digest('hex');
}

function randomBytes(size) {
    const n = Math.max(1, Math.min(1024, parseInt(size, 10) || 16));
    return crypto.randomBytes(n).toString('hex');
}

/**
 * AES 加解密（对齐 LX 的 `utils.crypto.aesEncrypt(data, mode, key, iv)`）。
 * LX 脚本里很常见（很多音源接口的响应是 AES 加密的）。
 * mode: 'aes-128-cbc' | 'aes-128-ecb' | 'aes-256-cbc' | 'aes-256-ecb'
 */
function aesEncrypt(data, mode, key, iv) {
    const m = String(mode || 'aes-128-cbc').toLowerCase();
    const algo = m.includes('ecb') ? (m.includes('256') ? 'aes-256-ecb' : 'aes-128-ecb')
        : (m.includes('256') ? 'aes-256-cbc' : 'aes-128-cbc');
    const keyBuf = Buffer.from(String(key ?? ''), 'utf8');
    const ivBuf = algo.includes('ecb') ? null : Buffer.from(String(iv ?? ''), 'utf8');
    const cipher = crypto.createCipheriv(algo, keyBuf, ivBuf);
    cipher.setAutoPadding(true);
    return {
        toString: () => Buffer.concat([cipher.update(String(data ?? ''), 'utf8'), cipher.final()]).toString('base64'),
        base64: () => Buffer.concat([cipher.update(String(data ?? ''), 'utf8'), cipher.final()]).toString('base64'),
    };
}

function aesDecrypt(data, mode, key, iv) {
    const m = String(mode || 'aes-128-cbc').toLowerCase();
    const algo = m.includes('ecb') ? (m.includes('256') ? 'aes-256-ecb' : 'aes-128-ecb')
        : (m.includes('256') ? 'aes-256-cbc' : 'aes-128-cbc');
    const keyBuf = Buffer.from(String(key ?? ''), 'utf8');
    const ivBuf = algo.includes('ecb') ? null : Buffer.from(String(iv ?? ''), 'utf8');
    const decipher = crypto.createDecipheriv(algo, keyBuf, ivBuf);
    decipher.setAutoPadding(true);
    const input = Buffer.from(String(data ?? ''), 'base64');
    return Buffer.concat([decipher.update(input), decipher.final()]).toString('utf8');
}

// ============================================================
// lx.utils.crypto 补充：sha1 / sha256 / rsaEncrypt / rsaDecrypt
// ============================================================

function sha1(value) {
    return crypto.createHash('sha1').update(String(value ?? ''), 'utf8').digest('hex');
}

function sha256(value) {
    return crypto.createHash('sha256').update(String(value ?? ''), 'utf8').digest('hex');
}

/** PEM 公钥；也兼容"只有 base64 正文"的写法（很多音源把 PEM 头尾省掉） */
function toPublicKey(key) {
    const s = String(key ?? '').trim();
    if (!s) throw new Error('rsaEncrypt: 缺少公钥');
    if (s.includes('-----BEGIN')) return s;
    return `-----BEGIN PUBLIC KEY-----\n${s.replace(/\s+/g, '')}\n-----END PUBLIC KEY-----`;
}

function toPrivateKey(key) {
    const s = String(key ?? '').trim();
    if (!s) throw new Error('rsaDecrypt: 缺少私钥');
    if (s.includes('-----BEGIN')) return s;
    return `-----BEGIN RSA PRIVATE KEY-----\n${s.replace(/\s+/g, '')}\n-----END RSA PRIVATE KEY-----`;
}

/**
 * RSA 加密（PKCS#1 v1.5），对齐 LX 的 `utils.crypto.rsaEncrypt(data, key)`。
 *
 * ⚠️ 这是**第三方音源脚本最常用的缺口之一**：网易 / QQ 类音源几乎都要 RSA，
 * 而原来 `utils.crypto` 里**没有这个方法** → 脚本一调就抛
 * `TypeError: lx.utils.crypto.rsaEncrypt is not a function`，
 * 用户看到的就是"音源跑不通、只报一句看不懂的错"。
 *
 * 返回 **Buffer**（LX 脚本通常接 `.toString('base64')` 或
 * `lx.utils.buffer.bufToString(...)`）。
 */
function rsaEncrypt(data, key) {
    const buf = Buffer.isBuffer(data) ? data : Buffer.from(String(data ?? ''), 'utf8');
    return crypto.publicEncrypt(
        { key: toPublicKey(key), padding: crypto.constants.RSA_PKCS1_PADDING },
        buf,
    );
}

/** RSA 解密（少数音源用私钥解响应），同样返回 Buffer。 */
function rsaDecrypt(data, key) {
    const buf = Buffer.isBuffer(data)
        ? data
        : Buffer.from(String(data ?? ''), 'base64');
    return crypto.privateDecrypt(
        { key: toPrivateKey(key), padding: crypto.constants.RSA_PKCS1_PADDING },
        buf,
    );
}

// ============================================================
// lx.utils.buffer
// ============================================================

const bufferBridge = {
    /** Buffer -> 字符串（编码支持 utf8 / base64 / hex） */
    bufToString(buf, encoding) {
        try {
            if (buf == null) return '';
            if (typeof buf === 'string') return buf;
            const enc = String(encoding || 'utf8').toLowerCase();
            const b = Buffer.isBuffer(buf) ? buf : Buffer.from(buf);
            if (enc === 'base64') return b.toString('base64');
            if (enc === 'hex') return b.toString('hex');
            if (enc === 'latin1' || enc === 'binary') return b.toString('latin1');
            return b.toString('utf8');
        } catch (_) {
            return '';
        }
    },
    /** 字符串 → **Buffer**（LX 语义）。
     *
     * ⚠️ 原来这里返回的是 **hex 字符串** —— 与 LX 不一致：脚本拿去做
     * `bufConcat` / `rsaEncrypt` / `writeUInt...` 之类会直接报错。
     * 旧的 hex 行为挪到 [stringToHex] 保留。 */
    stringToBuf(str, encoding) {
        try {
            return Buffer.from(String(str ?? ''), String(encoding || 'utf8'));
        } catch (_) {
            return Buffer.alloc(0);
        }
    },
    /** 字符串 → hex 字符串（旧 `stringToBuf` 的行为，保留以免有人依赖） */
    stringToHex(str) {
        try {
            return Buffer.from(String(str ?? ''), 'utf8').toString('hex');
        } catch (_) {
            return '';
        }
    },
    /** 拼接若干 Buffer / 字符串（LX 有这个方法，音源里常见） */
    bufConcat(...args) {
        try {
            const list = args.map((a) =>
                Buffer.isBuffer(a) ? a : Buffer.from(String(a ?? ''), 'utf8'),
            );
            return Buffer.concat(list);
        } catch (_) {
            return Buffer.alloc(0);
        }
    },
};

// ============================================================
// lx.request
// ============================================================

/**
 * 发 HTTP 请求并把响应交给脚本回调（对齐 LX 的 `lx.request(url, options, cb)`）。
 *
 * 回调收到 `(err, resp, body)`：
 *   · err  —— 出错时的 Error（成功传 null）
 *   · resp —— { statusCode, headers, body }
 *   · body —— 响应体（字符串；是 JSON 时脚本自己 parse）
 *
 * ⚠️ 有响应体大小上限，避免脚本拉一个巨大文件把 App 内存吃爆。
 */
async function lxRequest(url, options, callback) {
    const opt = options || {};
    const method = String(opt.method || 'GET').toUpperCase();
    const headers = Object.assign(
        {
            'User-Agent':
                'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
        },
        opt.headers || {},
    );
    const timeout = Math.min(REQUEST_TIMEOUT_MS, parseInt(opt.timeout, 10) || REQUEST_TIMEOUT_MS);

    // ── 补齐 LX 的常用请求形态（三方音源脚本高频使用）────────────
    // ① `form`：表单 POST。原来只认 `body`/`data` → 脚本传 `form` 时请求体为空，
    //    服务端必然报错（表现就是"音源跑不通"）。
    let data = opt.body ?? opt.data;
    if (data == null && opt.form != null) {
        data = opt.form;
        const hasCt = Object.keys(headers).some(
            (k) => k.toLowerCase() === 'content-type',
        );
        if (!hasCt) headers['Content-Type'] = 'application/x-www-form-urlencoded';
    }
    // ② `params`：查询串（axios 风格，LX 脚本也会用）
    const params =
        opt.params && typeof opt.params === 'object' ? opt.params : undefined;
    // ③ 二进制响应：`binary: true` 或 `responseType: 'arraybuffer'`。
    //    原来恒为 text → 要解密/解包的接口拿到的是乱码字符串。
    const binary = opt.binary === true || opt.responseType === 'arraybuffer';

    try {
        const res = await axios.request({
            url: String(url),
            method,
            headers,
            data,
            params,
            timeout,
            responseType: binary ? 'arraybuffer' : 'text',
            // 自己判状态码，4xx/5xx 也要把 body 交给脚本（很多音源靠错误页判断）
            validateStatus: () => true,
            maxContentLength: MAX_RESPONSE_BYTES,
            maxBodyLength: MAX_RESPONSE_BYTES,
            ...(binary ? {} : { transformResponse: [(d) => d] }),
            // ④ 重定向次数（LX 的 follow_max）
            ...(opt.follow_max != null
                ? { maxRedirects: Math.max(0, parseInt(opt.follow_max, 10) || 0) }
                : {}),
        });
        const body = binary
            ? Buffer.from(res.data)
            : typeof res.data === 'string'
              ? res.data
              : JSON.stringify(res.data);
        const resp = {
            statusCode: res.status,
            headers: res.headers || {},
            body,
        };
        if (typeof callback === 'function') callback(null, resp, body);
        return { ok: true, statusCode: res.status, body };
    } catch (e) {
        const err = new Error((e && e.message) || String(e));
        if (typeof callback === 'function') {
            try {
                callback(err, null, null);
                return { ok: false, error: err.message };
            } catch (cbErr) {
                return { ok: false, error: '回调抛错: ' + cbErr.message };
            }
        }
        return { ok: false, error: err.message };
    }
}

// ============================================================
// 执行
// ============================================================

/**
 * 执行一段 LX 脚本，拿到它注册的 handler。
 *
 * @returns {Promise<{ok:boolean, handlers?:Object, actions?:string[], error?:string}>}
 */
export async function loadScript(script) {
    const src = String(script || '');
    if (!src.trim()) return { ok: false, error: '脚本为空' };
    if (src.length > MAX_SCRIPT_CHARS) {
        return { ok: false, error: `脚本过大（${src.length} 字符，上限 ${MAX_SCRIPT_CHARS}）` };
    }

    // 脚本通过 on(event, handler) 注册各 action 的处理函数
    const handlers = {};
    const sandboxConsole = {
        log: (...a) => console.log('[LX]', ...a),
        warn: (...a) => console.warn('[LX]', ...a),
        error: (...a) => console.error('[LX]', ...a),
    };

    const lx = {
        EVENT_NAMES: {
            request: 'request',
            inited: 'inited',
            updateAlert: 'updateAlert',
        },
        env: {
            // 只给"身份标识"，不给任何用户信息（不做账号）
            version: '1.0.0',
            platform: 'ios',
            appName: 'tvbox',
        },
        version: '1.0.0',
        request: lxRequest,
        on(event, handler) {
            if (typeof event === 'string' && typeof handler === 'function') {
                handlers[event] = handler;
            }
        },
        send(event, payload) {
            // LX 用 send('inited', {...}) 回报初始化结果；这里只记录，不需要回传
            if (event === 'inited') {
                handlers.__inited = payload;
            }
        },
        utils: {
            buffer: bufferBridge,
            crypto: {
                md5,
                sha1,
                sha256,
                rsaEncrypt,
                rsaDecrypt,
                aesEncrypt,
                aesDecrypt, // 比 Beans 多一个 —— 很多源要用它解响应
                randomBytes,
            },
            // LX 常用便捷函数：不少音源脚本直接调（缺了会 TypeError）
            str2b64: (str) => Buffer.from(String(str ?? ''), 'utf8').toString('base64'),
            b64toStr: (b64) => Buffer.from(String(b64 ?? ''), 'base64').toString('utf8'),
        },
    };

    // ── 关键：白名单沙箱 ────────────────────────────────────────
    // 不注入 require / process / fs / child_process / global，
    // 所以脚本**拿不到文件系统和进程控制**。
    const sandbox = {
        lx,
        console: sandboxConsole,
        Buffer,
        // 纯计算用的内建对象（不给任何 IO 能力）
        JSON,
        Math,
        Date,
        String,
        Number,
        Boolean,
        Array,
        Object,
        RegExp,
        Error,
        Promise,
        setTimeout,
        clearTimeout,
        encodeURIComponent,
        decodeURIComponent,
        encodeURI,
        decodeURI,
        parseInt,
        parseFloat,
        isNaN,
        isFinite,
        TextEncoder,
        TextDecoder,
        URL,
        URLSearchParams,
        // CommonJS 壳子：很多脚本用 `module.exports = {...}` 或
        // `const { ... } = require('...')`，给一个**只返回 lx** 的假 require
        module: { exports: {} },
        exports: {},
        require: (name) => {
            // 只允许脚本"引入"lx 本身；其它一律拒绝（避免拿到 fs 等）
            if (name === 'lx' || name === './lx') return lx;
            throw new Error(`脚本不允许 require('${name}')——沙箱只提供 lx API`);
        },
    };
    sandbox.globalThis = sandbox;
    sandbox.global = sandbox;

    try {
        // timeout 是硬中断：脚本死循环会在 SCRIPT_TIMEOUT_MS 后被终止，
        // 不会把 Node 事件循环（也就是整个 App）卡死。
        const ctx = vm.createContext(sandbox);
        vm.runInContext(src, ctx, {
            timeout: SCRIPT_TIMEOUT_MS,
            filename: 'lx-source.js',
            displayErrors: true,
        });

        // 兼容两种写法：lx.on(...) 注册 / module.exports = { ... }
        const exported = sandbox.module && sandbox.module.exports;
        if (exported && typeof exported === 'object' && !Array.isArray(exported)) {
            // LX 常见：module.exports = { getMediaSource, search, getLyric, ... }
            for (const k of Object.keys(exported)) {
                if (typeof exported[k] === 'function') handlers[k] = exported[k];
            }
        }

        const actions = Object.keys(handlers).filter((k) => !k.startsWith('__'));
        return {
            ok: true,
            handlers,
            actions,
            inited: handlers.__inited || null,
        };
    } catch (e) {
        const msg = (e && e.message) || String(e);
        // 超时会被 vm 报成 "Script execution timed out"
        const isTimeout = /timed out|timeout/i.test(msg);
        return {
            ok: false,
            error: isTimeout
                ? `脚本执行超时（超过 ${SCRIPT_TIMEOUT_MS}ms）——可能存在死循环`
                : `脚本加载失败：${msg}`,
        };
    }
}

/**
 * 在已加载的脚本上执行一个 action（如 'musicUrl'）。
 *
 * 这里不重复跑脚本本体（那是 loadScript 的事），只调 handler。
 * handler 可能是 async，所以要 await；同样有超时保护。
 */
export async function runAction(handlers, action, payload) {
    const fn = handlers && handlers[action];
    if (typeof fn !== 'function') {
        return { ok: false, error: `脚本未实现 action: ${action}` };
    }
    try {
        const result = await Promise.race([
            Promise.resolve(fn(payload)),
            new Promise((_, rej) =>
                setTimeout(() => rej(new Error('处理超时')), SCRIPT_TIMEOUT_MS),
            ),
        ]);
        return { ok: true, result };
    } catch (e) {
        return { ok: false, error: (e && e.message) || String(e) };
    }
}

/** 供 /music/api 的自检使用 */
export function engineInfo() {
    return {
        timeoutMs: SCRIPT_TIMEOUT_MS,
        maxScriptChars: MAX_SCRIPT_CHARS,
        maxResponseBytes: MAX_RESPONSE_BYTES,
        sandboxed: true,
        denied: ['require(除 lx 外)', 'process', 'fs', 'child_process', 'global'],
    };
}
