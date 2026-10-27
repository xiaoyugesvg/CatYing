/**
 * CatVodOpen 插件兼容层
 * ============================================================
 *
 * 背景（用户 2026-10-27 明确要求）：
 *   「这个官方聚合是你修改了脚本？不是用代码去兼容吗？」
 *
 * 官方那批 `.js` 源是 **CatVodOpen 的 fastify 插件**形态：
 *   · ESM 语法：`import ... from 'node:crypto'` / `'../../util/req.js'`
 *   · `export default function createSpider(name, config)`，返回
 *     `{ meta, api: async (fastify) => { fastify.post('/home', …) }, check }`
 * 而本 App 的 Node 引擎走 CommonJS：`require(index.js)` 后调
 * `module.exports.start(config)`。两者不兼容 ⇒ 直接 `require` 必抛
 * `Cannot use import statement outside a module`。
 *
 * 以前的做法是**人工把脚本转成 CJS**（改 import、内联 util、替换 fastify 路由）——
 * 那只是绕路：只解决那一个文件，用户下次拿到别的官方插件照样炸。
 * 本模块改成**宿主侧兼容**，原始文件不改一个字节即可导入。
 *
 * 三层：
 *   ① ESM→CJS 载入层   —— 源码内存转换后写到脚本目录下的 `.cjs` 再 require
 *   ② 虚拟模块注册表   —— `../../util/xxx.js` 映射到宿主实现（临时 patch Module._load）
 *   ③ fastify 插件适配 —— 迷你 fastify shim 收集路由，转成
 *                         `/config` + `/spider/<key>/<type>/<action>` 契约
 *
 * 边界（**故意失败而不是假装成功**）：
 *   用了 fastify 插件嵌套 `register()`、`addHook()` 生命周期钩子、
 *   `reply.raw` 流式响应的插件仍然跑不了 —— 这时会抛
 *   `不支持的 fastify 特性：xxx`，宿主把它写进 `load-error.txt`，
 *   UI 上能看到**具体是哪一项**，而不是一句泛化的「脚本源加载失败」。
 *
 * ⚠️ 本文件里的 `require(...)` 依赖项目既有约定（见 main.js 顶部注释）：
 *    esbuild 输出 format=cjs，ESM 源码里的 `require` 调用保持原样、
 *    由 Node 运行时解析（内置模块 / node_modules）。内部模块一律用
 *    `await import('./x.js')`，否则拿到空对象。
 */

// ─────────────────────────────────────────────────────────────
// ① ESM → CJS 源码转换
// ─────────────────────────────────────────────────────────────

/** 转换后代码的头部：ESM 天然是严格模式，且默认导入需要 interop */
const PRELUDE =
    '"use strict";\n' +
    '// [cat-compat] ESM→CJS 自动转换，勿手改\n' +
    'function __catInterop(m){ return (m && m.default !== undefined) ? m.default : m; }\n';

let __uid = 0;
function nextTempName(prefix) {
    __uid += 1;
    return '__cat' + prefix + __uid;
}

/** `a, b as c` → `a, b: c`（解构用） */
function namesToBinding(names) {
    return names
        .split(',')
        .map((s) => s.trim())
        .filter(Boolean)
        .map((s) => {
            const m = s.match(/^([A-Za-z_$][\w$]*)\s+as\s+([A-Za-z_$][\w$]*)$/);
            return m ? m[1] + ': ' + m[2] : s;
        })
        .join(', ');
}

/** 单个 import 子句 → 一条或多条 require 语句 */
function importClauseToCode(clause, spec) {
    const c = clause.trim();
    const req = 'require(' + JSON.stringify(spec) + ')';
    const t = nextTempName('Mod');
    let m;

    // 默认 + 命名空间：import d, * as ns from 'x'
    m = c.match(/^([A-Za-z_$][\w$]*)\s*,\s*\*\s+as\s+([A-Za-z_$][\w$]*)$/);
    if (m) {
        return (
            'const ' + t + ' = ' + req + '; ' +
            'const ' + m[1] + ' = __catInterop(' + t + '); ' +
            'const ' + m[2] + ' = ' + t + ';'
        );
    }
    // 默认 + 命名：import d, { a, b as c } from 'x'
    m = c.match(/^([A-Za-z_$][\w$]*)\s*,\s*\{([\s\S]*)\}$/);
    if (m) {
        return (
            'const ' + t + ' = ' + req + '; ' +
            'const ' + m[1] + ' = __catInterop(' + t + '); ' +
            'const { ' + namesToBinding(m[2]) + ' } = ' + t + ';'
        );
    }
    // 命名空间：import * as ns from 'x'
    m = c.match(/^\*\s+as\s+([A-Za-z_$][\w$]*)$/);
    if (m) return 'const ' + m[1] + ' = ' + req + ';';
    // 命名：import { a, b as c } from 'x'
    m = c.match(/^\{([\s\S]*)\}$/);
    if (m) return 'const { ' + namesToBinding(m[1]) + ' } = ' + req + ';';
    // 纯默认：import d from 'x'
    m = c.match(/^([A-Za-z_$][\w$]*)$/);
    if (m) return 'const ' + m[1] + ' = __catInterop(' + req + ');';

    throw new Error(
        '不支持的 import 语法：`import ' + c + ' from ' + JSON.stringify(spec) + '`'
    );
}

/**
 * 把 ESM 源码转成 CJS。
 * 只做**机械替换**，业务逻辑一行不动；遇到认不出的语法就抛错，
 * 绝不产出"看起来能跑但其实语义变了"的代码。
 *
 * @returns {{code: string, notes: string[]}}
 */
export function transformEsmToCjs(src) {
    const tail = []; // 统一追加到文件末尾的 `module.exports.xxx = xxx`
    const notes = [];
    let code = String(src);

    // ── import { … } from 'x'（含多行）────────────────────────
    // 先处理带花括号的，避免被下面"纯默认"那条抢走。
    // 尾部的 `assert { type: 'json' }` / `with { … }` 直接丢掉：
    // 那只是导入断言元信息，CJS 的 `require('./x.json')` 本来就能读 JSON，
    // 留着反而会变成一句没头没脑的 `Unexpected token '{'`。
    code = code.replace(
        /^([ \t]*)import\s+([^'";]+?)\s+from\s*(['"])([^'"]+)\3(?:\s*(?:assert|with)\s*\{[^}]*\})?[ \t]*;?/gm,
        (m, ind, clause, q, spec) => ind + importClauseToCode(clause, spec)
    );

    // ── import 'x'（纯副作用）─────────────────────────────────
    code = code.replace(
        /^([ \t]*)import\s*(['"])([^'"]+)\2[ \t]*;?/gm,
        (m, ind, q, spec) => ind + 'require(' + JSON.stringify(spec) + ');'
    );

    // ── export default function/class Name ────────────────────
    // 保留外层绑定（`function Name` 而不是 `const x = function Name`），
    // 否则模块内其它地方引用 Name 会 ReferenceError。
    code = code.replace(
        /^([ \t]*)export\s+default\s+((?:async\s+)?function\*?|class)\s+([A-Za-z_$][\w$]*)/gm,
        (m, ind, kind, name) => {
            tail.push('module.exports = ' + name + ';');
            tail.push('module.exports.default = ' + name + ';');
            return ind + kind + ' ' + name;
        }
    );

    // ── export default <表达式>; ──────────────────────────────
    code = code.replace(
        /^([ \t]*)export\s+default\s+(.+);[ \t]*$/gm,
        (m, ind, expr) => {
            const n = nextTempName('Default');
            tail.push('module.exports = ' + n + ';');
            tail.push('module.exports.default = ' + n + ';');
            return ind + 'const ' + n + ' = (' + expr + ');';
        }
    );

    // ── export const/let/var NAME ─────────────────────────────
    code = code.replace(
        /^([ \t]*)export\s+(const|let|var)\s+([A-Za-z_$][\w$]*)/gm,
        (m, ind, kw, name) => {
            tail.push('module.exports.' + name + ' = ' + name + ';');
            return ind + kw + ' ' + name;
        }
    );

    // ── export function/class NAME ────────────────────────────
    code = code.replace(
        /^([ \t]*)export\s+((?:async\s+)?function\*?|class)\s+([A-Za-z_$][\w$]*)/gm,
        (m, ind, kind, name) => {
            tail.push('module.exports.' + name + ' = ' + name + ';');
            return ind + kind + ' ' + name;
        }
    );

    // ── export { a, b as c }; ─────────────────────────────────
    code = code.replace(
        /^([ \t]*)export\s*\{([\s\S]*?)\}[ \t]*;?[ \t]*$/gm,
        (m, ind, names) => {
            for (const raw of names.split(',')) {
                const s = raw.trim();
                if (!s) continue;
                const mm = s.match(
                    /^([A-Za-z_$][\w$]*)\s+as\s+([A-Za-z_$][\w$]*)$/
                );
                if (mm) tail.push('module.exports.' + mm[2] + ' = ' + mm[1] + ';');
                else tail.push('module.exports.' + s + ' = ' + s + ';');
            }
            return ind;
        }
    );

    // ── 兜底检查：还有 import/export 残留 ⇒ 明确报错，不产出坏代码 ──
    // 留一条 import 出去，Node 只会报 `Unexpected token`，看不出是哪一行、
    // 也不知道是我们没转。宁可在这里抛清楚。
    const leftoverImport = code.match(/^[ \t]*(import\s+[^\n]*)/m);
    if (leftoverImport) {
        throw new Error(
            '不支持的 import 语法：`' + leftoverImport[1].trim().slice(0, 120) + '`'
        );
    }
    const leftover = code.match(/^[ \t]*(export\s+[^\n]*)/m);
    if (leftover) {
        throw new Error(
            '不支持的 export 语法：`' + leftover[1].trim().slice(0, 120) + '`'
        );
    }

    if (tail.length) code = code.replace(/\s*$/, '') + '\n' + tail.join('\n') + '\n';
    code = PRELUDE + code;

    return { code, notes };
}

/** 快速判断一段源码是不是 ESM（只认行首的 import/export） */
export function looksLikeEsm(src) {
    return /^[ \t]*(?:import\s|export\s)/m.test(String(src));
}

// ─────────────────────────────────────────────────────────────
// ② 虚拟模块注册表
// ─────────────────────────────────────────────────────────────

/**
 * `../../util/req.js` / `util/home-cache.js` / `./util/misc.js`
 * 都归一成 `util/req.js` 这种 key。
 */
function utilKeyOf(request) {
    if (typeof request !== 'string') return null;
    const m = request.match(/(?:^|\/)util\/([\w.\-]+\.js)$/);
    return m ? 'util/' + m[1] : null;
}

/**
 * 临时接管 `Module._load`，把 util/*.js 请求直接返回宿主实现。
 *
 * 为什么必须拦截而不是在磁盘上补文件：
 *   官方插件写的是 `../../util/req.js`，相对路径取决于脚本被放在哪 ——
 *   补文件既污染用户目录，也会随缓存目录变化而失效。拦截是**按名字**认的，
 *   放在哪都一样。
 *
 * @param {Record<string, any>} modules  key = 'util/req.js' 形式
 * @returns {() => void} 还原函数（必须 finally 调用）
 */
export function installUtilResolver(modules) {
    const Module = require('module');
    const origLoad = Module._load;
    const keys = Object.keys(modules);

    Module._load = function (request, parent, isMain) {
        const key = utilKeyOf(request);
        if (key && Object.prototype.hasOwnProperty.call(modules, key)) {
            return modules[key];
        }
        return origLoad.apply(this, arguments);
    };

    return function restore() {
        Module._load = origLoad;
    };
}

/** 给模块对象挂一个**不可枚举**的 default（interop 用，且不污染 JSON 序列化） */
function withDefault(mod) {
    if (mod && typeof mod === 'object' && !('default' in mod)) {
        try {
            Object.defineProperty(mod, 'default', {
                value: mod,
                enumerable: false,
                configurable: true,
            });
        } catch (_) {}
    }
    return mod;
}

/** `util/home-cache.js`：宿主原本没有，按官方语义补一份 */
export function createHomeCacheModule() {
    const store = new Map();
    const HOME_CACHE_TTL = {
        semiStatic: 10 * 60 * 1000,
        dynamic: 60 * 1000,
    };

    function buildHomeCacheKey(key, request) {
        let extra = '';
        try {
            extra = JSON.stringify((request && request.body) || request || {});
        } catch (_) {
            extra = '';
        }
        return String(key) + '::' + extra;
    }

    function getHomeCache(k) {
        const hit = store.get(k);
        if (!hit) return null;
        if (Date.now() > hit.expireAt) {
            store.delete(k);
            return null;
        }
        return hit.value;
    }

    function setHomeCache(k, value, ttl) {
        store.set(k, {
            value,
            expireAt: Date.now() + (ttl || HOME_CACHE_TTL.dynamic),
        });
        // 简单的容量上限：官方实现是 LRU，这里只要保证不无限涨
        while (store.size > 64) {
            const first = store.keys().next();
            if (first.done) break;
            store.delete(first.value);
        }
    }

    return withDefault({
        getHomeCache,
        setHomeCache,
        buildHomeCacheKey,
        HOME_CACHE_TTL,
    });
}

/**
 * 按需装载宿主自己的 util 实现。
 * `req` 用现成的 `src/util/req.js`；其余同名映射。
 * 全部走 `await import()`（项目约定，见 main.js 顶部注释）。
 */
async function loadHostUtilModules(names) {
    const out = {};
    const hostMap = {
        'util/req.js': () => import('./util/req.js'),
        'util/misc.js': () => import('./util/misc.js'),
        'util/network.js': () => import('./util/network.js'),
        'util/chunk.js': () => import('./util/chunk.js'),
        'util/ali.js': () => import('./util/ali.js'),
        'util/pan.js': () => import('./util/pan.js'),
        'util/quark.js': () => import('./util/quark.js'),
        'util/uc.js': () => import('./util/uc.js'),
    };

    for (const name of names) {
        try {
            if (name === 'util/home-cache.js') {
                out[name] = createHomeCacheModule();
                continue;
            }
            const loader = hostMap[name];
            if (!loader) continue; // 宿主没有同名实现 → 留给 Node 正常解析
            const mod = await loader();
            // ESM 命名空间 → 摊平成普通对象，并保证 `.default` 可被 interop 取到
            const flat = {};
            for (const k of Object.keys(mod)) flat[k] = mod[k];
            if (mod.default !== undefined && !('default' in flat)) {
                Object.defineProperty(flat, 'default', {
                    value: mod.default,
                    enumerable: false,
                    configurable: true,
                });
            }
            out[name] = flat;
        } catch (e) {
            console.log('[cat-compat] 宿主 util 装载失败 ' + name + ': ' + (e && e.message));
        }
    }
    return out;
}

/** 从转换后的代码里扫出它 require 了哪些 util/*.js */
function collectUtilDeps(code) {
    const found = new Set();
    const re = /require\(\s*(['"])((?:\.\.?\/)*util\/[\w.\-]+\.js)\1\s*\)/g;
    let m;
    while ((m = re.exec(code))) {
        const key = utilKeyOf(m[2]);
        if (key) found.add(key);
    }
    return Array.from(found);
}

// ─────────────────────────────────────────────────────────────
// ③ fastify 插件适配
// ─────────────────────────────────────────────────────────────

/** 不支持的特性：统一抛这个，宿主会原样写进 load-error.txt */
function unsupported(what) {
    return new Error('不支持的 fastify 特性：' + what);
}

function createFastifyShim(pluginName) {
    const routes = new Map(); // 'POST /home' → handler
    const requestDecorators = {};
    const replyDecorators = {};
    const log = {
        info() {},
        warn() {},
        error() {},
        debug() {},
        trace() {},
        fatal() {},
        child() {
            return log;
        },
    };

    function recorder(method) {
        return function (path, handler) {
            if (typeof handler !== 'function') {
                throw unsupported(
                    method.toUpperCase() + ' ' + path + ' 的 handler 不是函数'
                );
            }
            routes.set(method.toUpperCase() + ' ' + path, handler);
            return shim;
        };
    }

    const shim = {
        get: recorder('get'),
        post: recorder('post'),
        put: recorder('put'),
        patch: recorder('patch'),
        delete: recorder('delete'),
        head: recorder('head'),
        options: recorder('options'),
        log,
        // 装饰：真的挂上去，很多插件靠它把工具函数传给 handler
        decorate(name, value) {
            shim[name] = value;
            return shim;
        },
        decorateRequest(name, value) {
            requestDecorators[name] = value;
            return shim;
        },
        decorateReply(name, value) {
            replyDecorators[name] = value;
            return shim;
        },
        // 以下都是**明确不支持**的：宁可报清楚，也别让用户对着白屏猜
        register() {
            throw unsupported('register()（插件嵌套注册）');
        },
        addHook(name) {
            throw unsupported('addHook(' + name + ')（生命周期钩子）');
        },
        setErrorHandler() {
            throw unsupported('setErrorHandler()');
        },
        setNotFoundHandler() {
            throw unsupported('setNotFoundHandler()');
        },
        addContentTypeParser() {
            throw unsupported('addContentTypeParser()');
        },
    };

    return { shim, routes, requestDecorators, replyDecorators, log };
}

function makeReply(res) {
    let sent = false;
    let statusCode = 200;
    const headers = {};

    function send(payload) {
        if (sent || res.writableEnded) return;
        sent = true;
        let body;
        if (payload === undefined || payload === null) body = '';
        else if (typeof payload === 'string' || Buffer.isBuffer(payload)) body = payload;
        else {
            try {
                body = JSON.stringify(payload);
            } catch (e) {
                body = JSON.stringify({
                    error: '响应序列化失败: ' + ((e && e.message) || e),
                });
            }
            if (!headers['Content-Type'] && !headers['content-type']) {
                headers['Content-Type'] = 'application/json; charset=utf-8';
            }
        }
        try {
            res.writeHead(statusCode, headers);
            res.end(body);
        } catch (_) {}
    }

    const reply = {
        get sent() {
            return sent;
        },
        code(n) {
            statusCode = n;
            return reply;
        },
        status(n) {
            statusCode = n;
            return reply;
        },
        header(k, v) {
            headers[k] = v;
            return reply;
        },
        headers(obj) {
            Object.assign(headers, obj || {});
            return reply;
        },
        type(t) {
            headers['Content-Type'] = t;
            return reply;
        },
        send,
        // 少数插件会读 reply.raw 设 header；真正流式写入仍不支持（下面会兜底报错）
        raw: res,
        redirect() {
            throw unsupported('reply.redirect()');
        },
    };
    return reply;
}

/**
 * 把 fastify 插件包成本 App 的「本地 JS 源」契约：
 *   GET  /config                        → { video: { sites: [...] } }
 *   POST /spider/<key>/<type>/<action>  → 转发到插件注册的 POST /<action>
 *
 * 路由只认**路径最后一段**是不是已注册的 action，所以
 * `/spider/xxx/3/home`、`/home` 两种形态都能吃。
 */
function buildAdapter({ plugin, key, name, site, routes, requestDecorators, log }) {
    const http = require('http');
    let server = null;

    function findHandler(method, action) {
        const exact = routes.get(method + ' /' + action);
        if (exact) return exact;
        // 有的插件把路由挂在 `/v1/home` 这类前缀下：按后缀兜一次
        for (const [k, h] of routes) {
            const [m, p] = k.split(' ');
            if (m === method && (p === '/' + action || p.endsWith('/' + action))) return h;
        }
        return null;
    }

    function sendJson(res, obj, code) {
        if (res.writableEnded) return;
        let body;
        try {
            body = JSON.stringify(obj == null ? {} : obj);
        } catch (e) {
            body = JSON.stringify({ error: '响应序列化失败: ' + ((e && e.message) || e) });
        }
        res.writeHead(code || 200, {
            'Content-Type': 'application/json; charset=utf-8',
        });
        res.end(body);
    }

    function readBody(req) {
        return new Promise((resolve) => {
            let raw = '';
            req.on('data', (c) => {
                raw += c;
                if (raw.length > 16 * 1024 * 1024) raw = raw.slice(0, 16 * 1024 * 1024);
            });
            req.on('end', () => {
                if (!raw) return resolve({});
                try {
                    resolve(JSON.parse(raw));
                } catch (_) {
                    resolve({});
                }
            });
            req.on('error', () => resolve({}));
        });
    }

    async function handle(req, res) {
        if (req.method === 'OPTIONS') {
            res.writeHead(204);
            res.end();
            return;
        }
        const u = new URL(req.url || '/', 'http://127.0.0.1');

        if (u.pathname === '/config') {
            sendJson(res, { video: { sites: [site] } });
            return;
        }

        const segs = u.pathname.split('/').filter(Boolean);
        const action = segs.length ? segs[segs.length - 1] : '';
        const handler = action ? findHandler('POST', action) : null;
        if (!handler) {
            sendJson(
                res,
                {
                    error: 'not found: ' + u.pathname,
                    actions: Array.from(routes.keys()),
                },
                404
            );
            return;
        }

        const body = await readBody(req);
        const query = {};
        for (const [k, v] of u.searchParams) query[k] = v;
        // 原文件里的 handler 都按 fastify 的 `request.body` 取参，这里补成同形状
        const request = Object.assign(
            {
                body,
                query,
                params: {},
                method: req.method,
                url: req.url,
                headers: req.headers,
                log,
            },
            requestDecorators
        );
        const reply = makeReply(res);
        const out = await handler(request, reply);
        // fastify 支持「handler 直接 return 数据」，这里等价处理
        if (!reply.sent && !res.writableEnded) {
            if (out !== undefined) reply.send(out);
            else
                sendJson(
                    res,
                    {
                        error:
                            '插件没有返回数据，也没有调用 reply.send()' +
                            '（可能用了不支持的流式响应 reply.raw.write/end）',
                    },
                    500
                );
        }
    }

    return {
        start(config) {
            const handler = (req, res) => {
                handle(req, res).catch((e) => {
                    const msg = (e && e.message) || String(e);
                    console.error('[cat-compat] ' + name + ' 处理失败: ' + msg);
                    sendJson(res, { error: msg }, 500);
                });
            };
            server = globalThis.catServerFactory
                ? globalThis.catServerFactory(handler)
                : http.createServer(handler);
            server.listen(0, '127.0.0.1');
            console.log('[cat-compat] ' + name + ' 已启动，路由 ' + Array.from(routes.keys()).join(', '));
            return { key, name };
        },
        stop() {
            try {
                if (server) server.close();
            } catch (_) {}
        },
    };
}

// ─────────────────────────────────────────────────────────────
// 对外主入口
// ─────────────────────────────────────────────────────────────

/**
 * 尝试把 `index.js` 当作 CatVodOpen 插件载入。
 *
 * @param {object} opts
 * @param {string} opts.dir      脚本所在目录（index.js 的父目录）
 * @param {string} opts.file     index.js 绝对路径
 * @param {string} opts.text     index.js 源码
 * @param {object} opts.config   index.config.js 导出的配置
 * @returns {Promise<{module: object, kind: string, key: string, name: string}>}
 */
export async function loadCatVodPlugin({ dir, file, text, config }) {
    const path = require('path');
    const fs = require('fs');

    // ── ① 转成 CJS 并落到同目录的 .cjs ──────────────────────────
    // 为什么用 .cjs：脚本目录里若存在 `package.json {"type":"module"}`，
    // `.js` 会被当成 ESM，我们这份 CJS 就白写了；`.cjs` 永远是 CJS。
    const { code, notes } = transformEsmToCjs(text);
    const tmpPath = path.join(dir, '.cat_compat_index.cjs');
    fs.writeFileSync(tmpPath, code, 'utf8');

    // ── ② 装虚拟 util 模块 ────────────────────────────────────
    const deps = collectUtilDeps(code);
    const utilModules = await loadHostUtilModules(deps);
    const provided = Object.keys(utilModules);
    const restore = installUtilResolver(utilModules);

    let mod;
    try {
        try {
            delete require.cache[require.resolve(tmpPath)];
        } catch (_) {}
        mod = require(tmpPath);
    } finally {
        // 必须还原：否则后面载入的普通 CJS 源也会被这套 util 规则影响
        restore();
    }

    if (notes.length) console.log('[cat-compat] ' + notes.join('; '));
    if (provided.length) console.log('[cat-compat] 已提供宿主 util: ' + provided.join(', '));

    // ── ③ 判定形态 ────────────────────────────────────────────
    const candidate = mod && mod.default !== undefined ? mod.default : mod;

    // 普通 CJS 源（有 start）：原样返回，走老路
    if (mod && typeof mod.start === 'function') {
        return { module: mod, kind: 'cjs', key: '', name: '' };
    }

    const fallbackKey =
        (config && (config.key || config.name)) ||
        path.basename(dir) ||
        'catvod_plugin';

    let plugin = candidate;
    if (typeof candidate === 'function') {
        // `export default function createSpider(name, config)`
        plugin = candidate(String(fallbackKey), config || {});
    }

    if (!plugin || typeof plugin !== 'object' || typeof plugin.api !== 'function') {
        throw new Error(
            '这个脚本既没有导出 `start(config)`（本 App 的本地 JS 源契约），' +
                '也没有导出 CatVodOpen 插件（需要 `api` 方法）'
        );
    }

    // ── fastify 插件：建 shim，让它把路由注册进来 ──────────────
    const meta = (plugin.meta && typeof plugin.meta === 'object' && plugin.meta) || {};
    const key = String(meta.key || meta.name || fallbackKey);
    const name = String(meta.name || key);
    const site = Object.assign({}, meta, {
        key,
        name,
        type: Number.isFinite(Number(meta.type)) ? Number(meta.type) : 3,
        // `csp_` 前缀是 Dart 侧的约定：识别为「不是路径基址」，
        // 从而退化成标准 `/spider/<key>/<type>/<action>`（见 spider_service.dart
        // 的 `_nodeBase`）。写成别的值会拼出非法路径。
        api: 'csp_' + key,
        ext: meta.ext != null ? meta.ext : '',
        searchable: meta.searchable != null ? meta.searchable : 1,
        quickSearch: meta.quickSearch != null ? meta.quickSearch : 1,
        filterable: meta.filterable != null ? meta.filterable : 1,
    });

    const { shim, routes, requestDecorators, log } = createFastifyShim(name);
    await plugin.api(shim);
    if (routes.size === 0) {
        throw unsupported('插件没有注册任何路由');
    }

    const adapter = buildAdapter({
        plugin,
        key,
        name,
        site,
        routes,
        requestDecorators,
        log,
    });

    return { module: adapter, kind: 'catvod-plugin', key, name };
}
