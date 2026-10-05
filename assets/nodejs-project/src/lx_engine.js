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
import zlib from 'zlib';
import axios from 'axios';

/** 脚本硬超时（毫秒）。超时即中断，绝不让它占住事件循环。 */
const SCRIPT_TIMEOUT_MS = 8000;

/**
 * 插件/脚本**异步调用**的超时（毫秒）。
 *
 * ── 🔴 为什么要和 SCRIPT_TIMEOUT_MS 分开（实测踩到）────────────
 * 原来 `runAction` 的外层 `Promise.race` 用的是 `SCRIPT_TIMEOUT_MS`
 *（8 秒），可这 8 秒原本是给 `vm.runInContext` 的**CPU 硬杀**用的 ——
 * 两者语义完全不同：
 *
 *   · `vm.runInContext` 超时 = 脚本**死循环**占住事件循环 → 必须 8s 砍掉
 *   · `runAction` 超时      = 插件在**等网络** → 纯 I/O，不吃 CPU，
 *                             给 8 秒会误杀正常请求
 *
 * 实测（`_probe_mf_timing.cjs`，酷我搜索接口）：
 *   · 光一次 axios 请求在沙箱里就要 **2281 / 3102 / 4932 ms**（波动很大）
 *   · 真实 MusicFree 插件 `search()` 端到端 **1269 / 7295 / 8020 ms**
 *   → 第 3 次直接撞上 8 秒被判"处理超时" ✗
 *     （而同样的请求**直连**永远是 HTTP 200，所以这不是源的问题）
 *
 * 所以：CPU 硬杀保持 8s，异步等待放宽到 20s。
 * 注意 `vm.runInContext` 仍用 [SCRIPT_TIMEOUT_MS] —— 死循环照样被砍。
 */
const ACTION_TIMEOUT_MS = 20000;

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
 * AES 加解密（对齐洛雪官方契约：`utils.crypto.aesEncrypt(buffer, mode, key, iv)`）。
 *
 * ⚠️ 洛雪实现接收 **Buffer** 的 data/key/iv 并返回 **Buffer**（不是字符串/对象）。
 * 旧实现把参数强制转字符串、返回带 toString 方法的对象——脚本若做
 * `Buffer.isBuffer(result)` / `Buffer.from(result)` 会直接出错。
 * 这里兼容两种传参（Buffer 或字符串），返回值对齐洛雪 = 真 Buffer。
 * mode: 'aes-128-cbc' | 'aes-128-ecb' | 'aes-256-cbc' | 'aes-256-ecb'
 */
function aesEncrypt(data, mode, key, iv) {
    const m = String(mode || 'aes-128-cbc').toLowerCase();
    const algo = m.includes('ecb') ? (m.includes('256') ? 'aes-256-ecb' : 'aes-128-ecb')
        : (m.includes('256') ? 'aes-256-cbc' : 'aes-128-cbc');
    const toBuf = (v, enc) => (Buffer.isBuffer(v) ? v : Buffer.from(String(v ?? ''), enc || 'utf8'));
    const keyBuf = toBuf(key);
    const ivBuf = algo.includes('ecb') ? null : toBuf(iv);
    const cipher = crypto.createCipheriv(algo, keyBuf, ivBuf);
    cipher.setAutoPadding(true);
    return Buffer.concat([cipher.update(toBuf(data)), cipher.final()]);
}

function aesDecrypt(data, mode, key, iv) {
    const m = String(mode || 'aes-128-cbc').toLowerCase();
    const algo = m.includes('ecb') ? (m.includes('256') ? 'aes-256-ecb' : 'aes-128-ecb')
        : (m.includes('256') ? 'aes-256-cbc' : 'aes-128-cbc');
    const toBuf = (v, enc) => (Buffer.isBuffer(v) ? v : Buffer.from(String(v ?? ''), enc || 'utf8'));
    const keyBuf = toBuf(key);
    const ivBuf = algo.includes('ecb') ? null : toBuf(iv);
    const decipher = crypto.createDecipheriv(algo, keyBuf, ivBuf);
    decipher.setAutoPadding(true);
    const input = Buffer.isBuffer(data) ? data : Buffer.from(String(data ?? ''), 'base64');
    return Buffer.concat([decipher.update(input), decipher.final()]);
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
 * RSA 加密，对齐**洛雪官方契约**：`rsaEncrypt(buffer, key)`。
 *
 * ⚠️ 洛雪实现是 **RSA_NO_PADDING** + 128 字节定长块（先左补零到 128 字节），
 * 不是 PKCS#1 v1.5。网易 / QQ 类音源接口要求的就是这种"定长块"加密，
 * 用 PKCS1 加密的结果接口会拒（解密后头部对不上）。
 */
function rsaEncrypt(data, key) {
    let buf = Buffer.isBuffer(data) ? data : Buffer.from(String(data ?? ''), 'utf8');
    const pubKey = toPublicKey(key);

    // 🔴 定长块的**长度必须等于密钥模长**（`RSA_NO_PADDING` 的硬要求），
    // **不能写死 128** —— 128 只对 1024 位密钥成立 ✗。
    // 用 2048 位密钥（256 字节）时，补到 128 就会报
    // `error:0200007A:rsa routines::data too small for key size` ✗
    //（这正是 `scripts/verify-lx-engine.mjs` 里 3/3 稳定复现的那个错）。
    // 从密钥本身推导块长，1024/2048/4096 位都能用。
    let blockSize = 128; // 兜底：推导不出来时保持旧行为
    try {
        const ko = typeof pubKey === 'string' ? crypto.createPublicKey(pubKey) : pubKey;
        const bits = ko.asymmetricKeyDetails && ko.asymmetricKeyDetails.modulusLength;
        if (bits) blockSize = Math.ceil(bits / 8);
    } catch (_) {
        /* 保持 128 兜底 */
    }

    if (buf.length < blockSize) {
        buf = Buffer.concat([Buffer.alloc(blockSize - buf.length), buf]);
    } else if (buf.length > blockSize) {
        // 定长块语义：只加密**最后** blockSize 字节
        buf = buf.subarray(buf.length - blockSize);
    }
    return crypto.publicEncrypt(
        { key: pubKey, padding: crypto.constants.RSA_NO_PADDING },
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
    /** ⚠️ 洛雪官方契约里的 `buffer.from(...args)` = Buffer.from（脚本高频使用） */
    from(...args) {
        try {
            return Buffer.from(...args);
        } catch (_) {
            return Buffer.alloc(0);
        }
    },
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

/**
 * ⚠️ 洛雪官方契约里有 `utils.zlib.{inflate,deflate}`（Promise 风格）。
 * 不少音源（尤其混淆包）用 zlib 解压响应/签名负载；缺了会直接
 * `lx.utils.zlib.inflate is not a function`。
 */
const zlibBridge = {
    inflate(buf) {
        return new Promise((resolve, reject) => {
            zlib.inflate(Buffer.isBuffer(buf) ? buf : Buffer.from(String(buf ?? ''), 'base64'), (err, data) => {
                if (err) reject(new Error(err.message));
                else resolve(data);
            });
        });
    },
    deflate(data) {
        return new Promise((resolve, reject) => {
            zlib.deflate(Buffer.isBuffer(data) ? data : Buffer.from(String(data ?? ''), 'utf8'), (err, out) => {
                if (err) reject(new Error(err.message));
                else resolve(out);
            });
        });
    },
};

// ============================================================
// lx.request
// ============================================================

/**
 * 发 HTTP 请求并把响应交给脚本回调（对齐洛雪官方契约：`lx.request(url, options, cb)`）。
 *
 * 回调收到 `(err, resp, body)`：
 *   · err  —— 出错时的 Error（成功传 null）
 *   · resp —— { statusCode, statusMessage, headers, body, raw }（body 会**尝试 JSON.parse**，
 *              parse 失败保持字符串——洛雪就是这种语义，脚本直接读 `resp.body.xxx`）
 *   · body —— 响应体（= resp.body，字符串或已 parse 的对象）
 *
 * 返回值对齐洛雪：**取消函数**（调用即中止请求），不是结果对象。
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

    const controller = new AbortController();
    const promise = axios.request({
        url: String(url),
        method,
        headers,
        data,
        params,
        timeout,
        signal: controller.signal,
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
    promise.then((res) => {
        let body = binary
            ? Buffer.from(res.data)
            : typeof res.data === 'string'
              ? res.data
              : JSON.stringify(res.data);
        // 洛雪语义：响应体尝试 JSON.parse，成功给对象、失败保持字符串
        let parsed = body;
        if (!binary && typeof body === 'string') {
            try {
                parsed = JSON.parse(body);
            } catch (_) { /* 保持字符串 */ }
        }
        const resp = {
            statusCode: res.status,
            statusMessage: res.statusText,
            headers: res.headers || {},
            body: parsed,
            raw: body,
        };
        if (typeof callback === 'function') callback(null, resp, parsed);
    }).catch((e) => {
        if (e && e.name === 'CanceledError') return; // 主动取消：不回调
        const err = new Error((e && e.message) || String(e));
        if (typeof callback === 'function') {
            try {
                callback(err, null, null);
            } catch (cbErr) {
                console.error('[LX] 回调抛错: ' + cbErr.message);
            }
        }
    });
    // ⚠️ 洛雪契约：request 返回**取消函数**
    return () => {
        try { controller.abort(); } catch (_) { /* 忽略 */ }
    };
}

// ============================================================
// 执行
// ============================================================

/**
 * 执行一段 LX 脚本，拿到它注册的 handler。
 *
 * @returns {Promise<{ok:boolean, handlers?:Object, actions?:string[], error?:string}>}
 */
/**
 * 加载并执行一个脚本。
 *
 * @param script 脚本源码
 * @param opts.modules  **按需注入的白名单模块**（默认空 = 纯 LX 沙箱）。
 *   只有 MusicFree 适配层会传 `{ axios, he }`；LX 路径不传，
 *   行为与以前完全一致（require 依然只允许 lx）。
 */
export async function loadScript(script, opts) {
    const extraModules = (opts && opts.modules) || null;
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
        // 缺 group 会让脚本直接抛 `console.group is not a function`（实测 huibq 源）
        group: (...a) => console.log('[LX]', ...a),
        groupEnd: () => {},
        table: (d) => console.log('[LX]', d),
    };

    const lx = {
        EVENT_NAMES: {
            request: 'request',
            inited: 'inited',
            updateAlert: 'updateAlert',
        },
        // ⚠️ 洛雪官方契约：`env` 是**字符串**（'desktop' / 'mobile'），不是对象！
        // 旧实现给对象 → 脚本 `lx.env` 拼 UA / 做平台判断时变成 "[object Object]"。
        // 新版源（flower 等）顶层解构 `env` 直接拼进 User-Agent，必须是字符串。
        env: 'desktop',
        version: '2.0.0',
        request: lxRequest,
        on(event, handler) {
            // ⚠️ 洛雪契约：on 返回 Promise（脚本可能 await lx.on(...)）
            if (typeof event === 'string' && typeof handler === 'function') {
                handlers[event] = handler;
                return Promise.resolve();
            }
            return Promise.reject(new Error('The event is not supported: ' + event));
        },
        send(event, payload) {
            // ⚠️ 洛雪契约：send 返回 Promise；inited 只允许调用一次（重复调用 reject）
            return new Promise((resolve, reject) => {
                if (event === 'inited') {
                    if (lx.__isInited) return reject(new Error('Script is inited'));
                    lx.__isInited = true;
                    handlers.__inited = payload;
                    return resolve();
                }
                if (event === 'updateAlert') {
                    handlers.__updateAlert = payload;
                    return resolve();
                }
                reject(new Error('The event is not supported: ' + event));
            });
        },
        // ⚠️ currentScriptInfo：洛雪宿主全局都会提供（含 description/author）。
        // 新版源（flower / lx 等）在顶层解构 `currentScriptInfo` 并访问
        // `U['version']` / `U['copyrightI']` 等字段——缺 description/author
        // 在部分脚本里会读到 undefined（表现和缺整个对象一样）。
        currentScriptInfo: {
            name: '',
            description: '',
            version: '',
            author: '',
            homepage: '',
            // ⚠️ 正统宿主传 userApi.script = 完整脚本；flower 等源用服务器配置
            // 比对 rawScript 的 hash，截断会导致校验失败抛"服务器异常"。
            rawScript: String(script || ''),
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
            // ⚠️ 洛雪官方契约里有 zlib（inflate/deflate，Promise）——混淆源高频使用
            zlib: zlibBridge,
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
        // ⚠️ 重型混淆壳（lx.js 用 xxHash 解码器）会探测的浏览器全局：
        // Function / Symbol / BigInt / self。洛雪 webview 里全有，
        // 缺失会让解码器内部取 undefined 而崩（报 reading 'length'）。
        Function,
        Symbol,
        BigInt,
        self: null, // 稍后设为 sandbox 自身
        // ⚠️ 洛雪脚本跑在真 webview：window / navigator / location 都存在，
        // 部分混淆源（lx.js 等）顶层会读它们（拼 UA、读 hash 等）。
        // 这里给最小占位，避免 `ReferenceError: navigator is not defined`。
        window: null, // 稍后设为 sandbox 自身（在 vm 上下文里形成循环引用）
        navigator: {
            userAgent:
                'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
            platform: 'iPhone',
            language: 'zh-CN',
            appVersion:
                'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15',
            userLanguage: 'zh-CN',
            // ⚠️ 新版源（pdone 2026 后）高频用 userAgentData 判断移动端/拼 UA。
            // 缺了会读 undefined 的 brands 等属性（报 reading 'version'/别的字段）。
            userAgentData: {
                brands: [
                    { brand: 'Not_A Brand', version: '8' },
                    { brand: 'Chromium', version: '132' },
                    { brand: 'Apple', version: '17.0' },
                ],
                mobile: true,
                platform: 'iOS',
                getHighEntropyValues: async () => ({ platform: 'iOS', formFactor: 'phone' }),
            },
            maxTouchPoints: 5,
            hardwareConcurrency: 8,
            deviceMemory: 4,
        },
        // ⚠️ 部分混淆源顶层会做 `document.createElement` / `document.cookie`
        // 之类的占位探测；缺 document 直接 ReferenceError。给最小占位。
        document: {
            cookie: '',
            title: '',
            referrer: '',
            readyState: 'complete',
            createElement: () => ({}),
            getElementById: () => null,
            getElementsByTagName: () => [],
            querySelector: () => null,
            querySelectorAll: () => [],
            addEventListener: () => {},
            removeEventListener: () => {},
        },
        // ⚠️ screen 尺寸占位（少部分源读它算封面尺寸/拼参数）
        screen: {
            width: 390,
            height: 844,
            availWidth: 390,
            availHeight: 844,
            colorDepth: 24,
            pixelDepth: 24,
        },
        location: {
            href: 'https://localhost/',
            protocol: 'https:',
            origin: 'https://localhost',
            host: 'localhost',
            hostname: 'localhost',
            pathname: '/',
            search: '',
            hash: '',
        },
        // ⚠️ process 最小桩：混淆壳常做 `typeof process==="object"` 或 `process.env`
        // 探测。给空 env，脚本读不到代理/密钥也不会崩。
        process: {
            env: {},
            platform: 'darwin',
            arch: 'x64',
            versions: {},
            cwd: () => '/',
        },
        // ⚠️ atob/btoa：浏览器全局。混淆源（lx.js）会先 `typeof atob==="function"`
        // 探测，缺了就退回自带解码；补上可走更快的原生路径，避免兼容隐患。
        atob: (b64) => Buffer.from(String(b64 ?? ''), 'base64').toString('latin1'),
        btoa: (str) => Buffer.from(String(str ?? ''), 'latin1').toString('base64'),
        // CommonJS 壳子：很多脚本用 `module.exports = {...}` 或
        // `const { ... } = require('...')`，给一个**只返回 lx** 的假 require
        module: { exports: {} },
        exports: {},
        require: (name) => {
            // 只允许脚本"引入"lx 本身；其它一律拒绝（避免拿到 fs 等）
            if (name === 'lx' || name === './lx') return lx;
            // ── MusicFree 适配层：按需注入的**白名单模块** ──────────
            //
            // ⚠️ 默认**空对象** —— 也就是说 LX 脚本的行为**一点没变**
            //（`loadScript(script)` 不传 modules 时，这里和以前完全一样）。
            //
            // 只有 MusicFree 适配层调 `loadScript(script, { modules })`
            // 时才会注入，而且**只注入 axios / he 这两个**：
            //   · axios —— MusicFree 插件几乎都 `require('axios')`
            //   · he    —— 用来解码 HTML 实体（`he.decode()`）
            // fs / child_process / process **依然拒绝**。
            if (extraModules && Object.prototype.hasOwnProperty.call(extraModules, name)) {
                return extraModules[name];
            }
            throw new Error(`脚本不允许 require('${name}')——沙箱只提供 lx API`);
        },
    };
    sandbox.globalThis = sandbox;
    sandbox.global = sandbox;
    sandbox.window = sandbox;
    sandbox.self = sandbox;

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
                // 🔴 把 stack 的**前几帧**也拼进错误信息：
                // 像 `Cannot read properties of undefined (reading 'version')` 这种
                // 报错，光看消息**没法知道是哪个字段/哪一行** ✗ ——
                // 而我们的 shim 到底缺哪个宿主字段，只能从脚本的报错位置反推 ✓
                // 之前 `stack` 只在返回值里，UI 只显示 message → 白瞎 ✓
                : `脚本加载失败：${msg}${
                      e && e.stack
                          ? '\n' + e.stack.split('\n').slice(1, 4).join('\n')
                          : ''
                  }`,
            stack: e && e.stack ? e.stack.split('\n').slice(0, 8).join('\n') : undefined,
        };
    }
}

/**
 * 在已加载的脚本上执行一个 action（如 'musicUrl'）。
 *
 * 这里不重复跑脚本本体（那是 loadScript 的事），只调 handler。
 * handler 可能是 async，所以要 await；同样有超时保护。
 */
export async function runAction(handlers, action, payload, opts) {
    const fn = handlers && handlers[action];
    if (typeof fn !== 'function') {
        return { ok: false, error: `脚本未实现 action: ${action}` };
    }
    try {
        // ── ⚠️ 参数传递方式（两种约定）──────────────────────────────
        // 默认：`fn(payload)` —— **一个**对象参数。
        //   LX 源就是这套：`lx.on('request', async (payload) => …)`，
        //   富对象里有 action/source/info。
        //
        // `opts.spread === true`：把 payload 当**位置参数数组**展开。
        //   MusicFree 插件是这套：`getMediaSource(musicItem, quality)` ——
        //   两个独立的位置参数。不展开的话它收到整个数组
        //   （`musicItem` 变成 `[musicItem, quality]`）→ 必然取不到地址。
        //
        // ⚠️ 默认 false，所以**所有现有 LX 调用的行为一点不变**。
        const invoke = () =>
            (opts && opts.spread === true && Array.isArray(payload))
                ? fn(...payload)
                : fn(payload);
        const result = await Promise.race([
            Promise.resolve(invoke()),
            // ⚠️ 用 ACTION_TIMEOUT_MS（20s）而不是 SCRIPT_TIMEOUT_MS（8s）——
            // 这里是**等插件发网络请求**，属于 I/O 等待，不是 CPU 占用。
            // 见 ACTION_TIMEOUT_MS 的定义处（实测 8s 会误杀正常的搜索请求）。
            new Promise((_, rej) =>
                setTimeout(() => rej(new Error('处理超时')), ACTION_TIMEOUT_MS),
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
