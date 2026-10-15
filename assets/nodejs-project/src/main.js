// **2026-07-09 临时关闭**: 调试期已结束, node.log 长期写会占用 Documents
// 缓存. 暂时停用, 代码保留, 需时把下方 [NODE_LOG_ENABLED] 改成 true 然后
// 重新跑 esbuild 重新打包 dist/main.js, 再走 iOS build 流程.
//
// **2026-07-08 node.log 诊断**: 启动时立刻解析 --node-log-path argv, 用
// require('fs') 同步追加 console.log/error + uncaughtException 到
// iOS Documents 沙盒 node.log. 必须在 require('http') / require('axios')
// 之前装好, 这样连 require 阶段抛错 / 静默 crash 都能记下 stack.
//
// fs 是 native POSIX, 不依赖 WASM/undici/fetch, iOS NodeMobile 可用.

// **总开关** - false 时整段 log 初始化跳过, console.log 走 OSLog 即可
// (swift --node-log-path 参数还会传过来, 但 src 不接, 等于无操作)
const NODE_LOG_ENABLED = false;

// ── 全局未捕获异常处理：必须**在任何顶层 require / 求值之前**装好 ──────
//
// iOS 的 Node 与 App 是**同一个进程**：未捕获异常会让 Node 退出 = 整个 App 闪退。
// 原来这两个处理器写在文件后段（原第 532 行附近），而前面第 87~95 行已经在顶层
// 执行了 `require('axios')` 与「逐个 require 全部内建模块」——属于"保护装得太晚"：
// 一旦那些顶层语句抛错，处理器根本来不及生效，进程直接死。
//
// ⚠️ 刻意用 `typeof` 守卫 `writeLine`：它是下面 NODE_LOG_ENABLED 块内的局部
//    常量，此处不可见；`typeof` 对不可见标识符返回 'undefined'，不会抛错。
process.on('uncaughtException', function (err) {
    const msg = err && err.stack ? err.stack : (err && err.message ? err.message : String(err));
    console.error('Caught uncaughtException:', msg);
    if (typeof writeLine === 'function') {
        try { writeLine('FATAL_UNCAUGHT', [msg]); } catch (_) {}
    }
});
process.on('unhandledRejection', function (reason) {
    const r = reason && reason.stack ? reason.stack : (reason && reason.message ? reason.message : String(reason));
    console.error('Caught unhandledRejection:', r);
    if (typeof writeLine === 'function') {
        try { writeLine('FATAL_UNHANDLED_REJECTION', [r]); } catch (_) {}
    }
});

// ── 可选功能的模块一律**延迟加载** ────────────────────────────
//
// 教训（踩过两次）：
//   1. 不能用 `require('./xxx.js')`：本项目 package.json 是 type=module，
//      esbuild 会把内部模块编成 ESM，require() 拿到的是**空对象**
//      （报 "xxx is not a function"，功能整个失效）。
//   2. 也不该用顶层 `import`：那样模块（连带它的整个依赖树）会在
//      **Node 启动时立即求值**，顶层任何一次抛错都会让 Node 进程挂掉 ——
//      而 iOS 的 Node 和 App 是**同一个进程**，Node 崩 = App 闪退。
//
// 所以：一律用「路由内 `await import()`」。
//   · esbuild 依然会把它打包进 dist/main.js（不依赖运行时文件系统）
//   · 但只在真正请求对应接口时才求值 → 启动路径零风险

// ── 音乐数据源（公开接口，无需登录）───────────────────────────
let musicSourceCache = null;

/** 延迟加载音乐数据源（见上：只能用 await import()） */
async function getMusicSource() {
    if (musicSourceCache) return musicSourceCache;
    musicSourceCache = await import('./music_source.js');
    return musicSourceCache;
}

// ── 小说书源引擎（Legado 格式）────────────────────────────────
//
// 为什么要惰性加载而不是顶层 import：
// 顶层 import 会在 Node 启动时立刻求值，而 `process.on('uncaughtException')`
// 是后面才装的 —— 万一引擎顶层抛错，Node 会直接挂掉（也就是整个 App 挂掉）。
// 惰性加载把风险限制在"真正请求书源接口"那一刻。
let bookSourceCache = null;

async function getBookSource() {
    if (bookSourceCache) return bookSourceCache;
    bookSourceCache = await import('./book_source.js');
    return bookSourceCache;
}

// ── 「海阔」小程序规则引擎（hiker 兼容层）─────────────────────────
// 同样**延迟加载**（见上：顶层求值一旦抛错 = 整个 App 闪退）。
let hikerEngineCache = null;

async function getHikerEngine() {
    if (hikerEngineCache) return hikerEngineCache;
    hikerEngineCache = await import('./hiker_engine.js');
    return hikerEngineCache;
}

let nodeLogFile = null;
if (NODE_LOG_ENABLED) try {
    const fs = require('fs');
    const path = require('path');
    const logIdx = process.argv.indexOf('--node-log-path');
    const logPath = logIdx !== -1 ? process.argv[logIdx + 1] : null;
    if (logPath) {
        // 确保 runtime 目录存在 (Swift 端已建, 这里再保险一次)
        try { fs.mkdirSync(path.dirname(logPath), { recursive: true }); } catch (e) {}
        nodeLogFile = logPath;
        const util = require('util');
        const fmt = (args) => args.map(a => {
            if (typeof a === 'string') return a;
            if (a instanceof Error) return a.stack || a.message;
            try { return util.inspect(a); } catch (e) { return String(a); }
        }).join(' ');
        const writeLine = (level, args) => {
            const line = '[' + new Date().toISOString() + '] [' + level + '] ' + fmt(args) + '\n';
            try { fs.appendFileSync(nodeLogFile, line); } catch (e) {}
        };
        const origLog = console.log.bind(console);
        const origErr = console.error.bind(console);
        console.log = function () { writeLine('INFO', Array.from(arguments)); origLog.apply(null, arguments); };
        console.error = function () { writeLine('ERROR', Array.from(arguments)); origErr.apply(null, arguments); };
        console.log('=== main.js boot start, pid=' + process.pid + ', argv=' + JSON.stringify(process.argv.slice(2)) + ' ===');
    }
} catch (e) {
    // fs 装不上就放弃, 走原 console.log
}
// NODE_LOG_ENABLED = false 时, 上面的 try { } catch (e) { } 整体不执行,
// nodeLogFile 保持 null, 后续所有 fs.appendFileSync 通过 (nodeLogFile || ...) 兜底,
// console.log 走 OSLog 即可 (iOS 上 OSLog 通过 Console.app 能看).

const { createServer } = require('http');
const axios = require('axios');
const { builtinModules } = require('module');

builtinModules.forEach(mod => {
    if (!['trace_events'].includes(mod)) {
        // 逐个 try：裁剪版 NodeMobile 可能缺个别内建（或它的 native 部分），
        // 顶层抛错会直接杀死同进程的 App，故缺一个就跳过一个、绝不上抛。
        try {
            globalThis[mod] = require(mod);
        } catch (e) {
            // 跳过缺失内建
        }
    }
});
console.log('=== main.js after builtinModules.forEach, nativeServerPort=0 (will be set later) ===');

let addon = null;
let sourceModule = null;
let nativeServerPort = 0;
let nativeToken = '';
let managementPort = 0;
let spiderPort = 0;
let isReady = false;

try {
    addon = process._linkedBinding('myaddon');
} catch (e) {
    addon = null;
}

const nativePortIdx = process.argv.indexOf('--native-port');
if (nativePortIdx !== -1 && process.argv[nativePortIdx + 1]) {
    nativeServerPort = parseInt(process.argv[nativePortIdx + 1], 10);
}
const tokenIdx = process.argv.indexOf('--native-token');
if (tokenIdx !== -1 && process.argv[tokenIdx + 1]) {
    nativeToken = process.argv[tokenIdx + 1];
}
console.log('=== main.js nativeServerPort resolved: ' + nativeServerPort + ' ===');

// token goes in header, never in URL query (queries land in logs)
function nativeNotifyHeaders() {
    return nativeToken ? { 'x-auth-token': nativeToken } : {};
}

globalThis.catServerFactory = (handle) => {
    let port = 0;
    const server = createServer((req, res) => {
        handle(req, res);
    });
    server.on('listening', () => {
        port = server.address().port;
        spiderPort = port;
        if (nativeServerPort > 0) {
            axios.get(`http://127.0.0.1:${nativeServerPort}/onCatPawOpenPort?port=${port}&type=spider`, { headers: nativeNotifyHeaders() }).catch(() => {});
        }
        console.log('Spider server running on ' + port);
    });
    server.on('close', () => {
        console.log('Spider server closed on ' + port);
    });
    return server;
};

globalThis.catDartServerPort = () => nativeServerPort;

// 取证：把源加载失败的原因写到源目录，供 Dart 侧读出来显示。
// iOS 上 console.error 只进 OSLog，用户拿不到 —— 没有这个文件，
// "require(index.js) 失败" 这类问题永远无法诊断。
function writeLoadErrorFile(dir, stage, err) {
    try {
        const fs = require('fs');
        const path = require('path');
        const msg = err && err.stack ? err.stack : String(err);
        const dump = [
            'time=' + new Date().toISOString(),
            'stage=' + stage,
            'dir=' + dir,
            'error=' + msg,
        ].join('\n');
        fs.mkdirSync(dir, { recursive: true });
        fs.writeFileSync(path.join(dir, 'load-error.txt'), dump);
    } catch (e) {
        console.error('failed to write load-error.txt:', e.message);
    }
}

function loadScript(path) {
    console.log('loadScript called with path:', path);
    const indexJSPath = path + '/index.js';
    const indexConfigJSPath = path + '/index.config.js';

    try {
        delete require.cache[require.resolve(indexJSPath)];
    } catch (e) {}

    try {
        delete require.cache[require.resolve(indexConfigJSPath)];
    } catch (e) {}

    try {
        sourceModule = require(indexJSPath);
        console.log('index.js loaded successfully');
    } catch (e) {
        console.error('ERROR loading index.js:', e.message);
        writeLoadErrorFile(path, 'require(index.js)', e);
        throw e;
    }

    let config = {};
    try {
        const configModule = require(indexConfigJSPath);
        config = configModule.default || configModule;
        console.log('Config loaded');
    } catch (e) {
        console.log('Config load skipped:', e.message);
    }

    try {
        const result = sourceModule.start(config);
        if (result && typeof result.then === 'function') {
            result.catch(e => console.error('ERROR in sourceModule.start() async:', e.message));
        }
        console.log('sourceModule.start(config) initiated');
    } catch (e) {
        console.error('ERROR in sourceModule.start(config):', e.message);
        writeLoadErrorFile(path, 'sourceModule.start(config)', e);
        throw e;
    }
}

function sendMessageToNative(message) {
    if (addon && addon.sendMessageToNative) {
        try {
            addon.sendMessageToNative(message);
            return;
        } catch (e) {}
    }
    if (nativeServerPort > 0) {
        axios.post(`http://127.0.0.1:${nativeServerPort}/onMessage`, { message: message }, { headers: nativeNotifyHeaders() }).catch(() => {});
    }
}

function handleNativeMessage(msg) {
    try {
        const data = JSON.parse(msg);
        switch (data.action) {
            case 'run':
                try {
                    if (sourceModule && typeof sourceModule.stop === 'function') {
                        sourceModule.stop();
                    }
                } catch (e) {}
                spiderPort = 0;
                loadScript(data.path);
                break;
            case 'nativeServerPort':
                nativeServerPort = data.port;
                break;
            default:
                break;
        }
    } catch (e) {
        console.log('handleNativeMessage error:', e);
    }
}

if (addon && addon.registerCallback) {
    addon.registerCallback((msg) => {
        handleNativeMessage(msg);
    });
}

const mgmtServer = createServer((req, res) => {
    // CORS：管理面允许任意来源（含 file:// 的 'null'）
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, x-auth-token');

    if (req.method === 'OPTIONS') {
        res.writeHead(204);
        res.end();
        return;
    }

    const url = new URL(req.url, `http://127.0.0.1`);
    // 鉴权已移除：mgmtServer 只监听 127.0.0.1，本机任意进程可调（用户要求）。
    //
    // 背景：Dart 侧 NodeJSManager 的 _localHttpDio 会带 x-auth-token，但
    // IOSNodeJSPlatform 自己那个纯 Dio（用于 /source/loadPath）不带 →
    // 强制校验会 403 掉自己 App 的源加载请求 → 源 JS 永不加载 →
    // spider 端口永不出现 → 首页永久空白。移除后两条路径都能通。
    //
    // 注意：nativeToken 仍用于「本进程 → Dart HTTP server」方向的通知头
    // （见 nativeNotifyHeaders），Dart 侧那条通道仍在做真实校验，不能删。

    if (req.method === 'GET' && url.pathname === '/check') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ run: true, ready: isReady }));
        return;
    }

    if (req.method === 'GET' && url.pathname === '/source/status') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({
            sourceLoaded: sourceModule !== null,
            spiderPort: spiderPort,
            ready: isReady,
        }));
        return;
    }

    if (req.method === 'POST' && url.pathname === '/source/loadPath') {
        let body = '';
        req.on('data', chunk => { body += chunk; });
        req.on('end', () => {
            try {
                const data = JSON.parse(body);
                const sourcePath = data.path;

                if (!sourcePath) {
                    res.writeHead(400, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: 'path is required' }));
                    return;
                }
                // 路径白名单：仅允许 App 文档/临时目录下的源，禁止任意 require
                //
                // ⚠️ 原实现用 `process.env.HOME + '/Documents'`，依赖 HOME 恰好等于
                // iOS 沙盒容器根。但 Swift 侧只 setenv 了 NODE_PATH，从未设置 HOME，
                // 一旦 HOME 为空/为其他值（如 '/var/mobile'），拼出来就是
                // '/Documents' 之类的无效路径 → 白名单不含真实 Documents →
                // 所有源加载被 403 拒绝 → spider 端口永不出现 → 首页永久空白。
                // 这里改为从 Dart 传入的 sourcePath 反推 Documents 根，确保它自身
                // 一定被允许，不再依赖 HOME。
                const path = require('path');
                const resolved = path.resolve(sourcePath);
                const home = process.env.HOME || '';
                const appDocsRoot = resolved.includes(path.sep + 'Documents' + path.sep)
                    ? resolved.substring(
                          0,
                          resolved.indexOf(path.sep + 'Documents' + path.sep) +
                              (path.sep + 'Documents').length)
                    : null;
                const allowedRoots = [
                    home ? path.join(home, 'Documents') : null,
                    home ? path.join(home, 'Library') : null,
                    process.env.TMPDIR || '/tmp',
                    process.cwd(),
                    // 关键：Dart 提供的源目录自身及其 Documents 根
                    resolved,
                    appDocsRoot,
                ].filter(Boolean).map((r) => path.resolve(r));
                const okPath = allowedRoots.some(
                    (root) => resolved === root || resolved.startsWith(root + path.sep));
                if (!okPath) {
                    console.error('loadPath rejected outside allowlist:', resolved,
                        'allowlist=', JSON.stringify(allowedRoots));
                    // 取证：把现场写到源目录下，Dart 侧会读出来显示给用户。
                    // 没有这个文件，这类失败在 iOS 上完全不可见（console 只进 OSLog）。
                    try {
                        const fs = require('fs');
                        const errPath = path.join(resolved, 'loadPath-error.txt');
                        const dump = [
                            'time=' + new Date().toISOString(),
                            'resolved=' + resolved,
                            'HOME=' + JSON.stringify(process.env.HOME),
                            'TMPDIR=' + JSON.stringify(process.env.TMPDIR),
                            'cwd=' + process.cwd(),
                            'argv=' + JSON.stringify(process.argv.slice(2)),
                            'allowedRoots=' + JSON.stringify(allowedRoots),
                        ].join('\n');
                        fs.mkdirSync(resolved, { recursive: true });
                        fs.writeFileSync(errPath, dump);
                    } catch (e) {
                        console.error('failed to write loadPath-error.txt:', e.message);
                    }
                    res.writeHead(403, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({
                        error: 'path not allowed',
                        resolved: resolved,
                        allowedRoots: allowedRoots,
                    }));
                    return;
                }

                try {
                    if (sourceModule && typeof sourceModule.stop === 'function') {
                        sourceModule.stop();
                    }
                } catch (e) {}

                spiderPort = 0;
                loadScript(sourcePath);

                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ success: true, message: 'Source loaded from path' }));
            } catch (e) {
                console.error('ERROR in /source/loadPath:', e.message);
                res.writeHead(500, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: e.message }));
            }
        });
        return;
    }

    if (req.method === 'POST' && url.pathname === '/music/api') {
        // 音乐统一接口（公开接口，无需登录）
        //   body: { action: 'search'|'url'|'lyric', keyword?, id?, limit?, offset?, quality? }
        //
        // 实现放在 music_source.js，用**延迟加载**（见文件头的说明）：
        // 模块只在真正请求时才求值，避免它的顶层代码拖垮 Node 启动。
        let body = '';
        req.on('data', chunk => { body += chunk; });
        req.on('end', async () => {
            try {
                const data = JSON.parse(body || '{}');
                const musicSource = await getMusicSource();
                const r = await musicSource.handleMusicApi(data);
                res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
                res.end(JSON.stringify(r));
            } catch (e) {
                console.error('ERROR in /music/api:', (e && e.stack) || e);
                try {
                    res.writeHead(500, { 'Content-Type': 'application/json; charset=utf-8' });
                    res.end(JSON.stringify({
                        ok: false,
                        error: '音乐接口异常：' + ((e && e.message) || String(e)),
                    }));
                } catch (_) { /* 响应已开始写出，忽略二次写入错误 */ }
            }
        });
        return;
    }

    if (req.method === 'POST' && url.pathname === '/hiker/run') {
        // 「海阔」小程序规则执行（见 hiker_engine.js 顶部说明：同步 HTTP 走「重放桥」）
        //   body: { action:'home'|'search'|'detail', source:{...}, params:{...}, vars:{...} }
        //   ⚠️ 与 /onMessage、/hiker/webview 一样要有**请求体上限**：
        //      不带上限时，一个字段超大的源（pages/规则巨长）会被无限累加再 JSON.parse，
        //      把 Node 内存顶爆（其它模块的在线请求一起挂）。
        const MAX_HIKER_BODY = 2 * 1024 * 1024;
        let body = '';
        let tooLarge = false;
        req.on('error', () => { /* 客户端中断：忽略，避免未处理的 error 事件把进程带崩 */ });
        req.on('data', chunk => {
            if (tooLarge) return;
            body += chunk;
            if (body.length > MAX_HIKER_BODY) {
                tooLarge = true;
                console.error('ERROR in /hiker/run: body 超过上限', MAX_HIKER_BODY);
                try {
                    res.writeHead(413, { 'Content-Type': 'application/json; charset=utf-8' });
                    res.end(JSON.stringify({ ok: false, error: '海阔请求体过大（上限 2MB）' }));
                } catch (_) { /* 响应可能已开始写出 */ }
                req.destroy();
            }
        });
        req.on('end', async () => {
            if (tooLarge) return;
            try {
                const data = JSON.parse(body || '{}');
                const eng = await getHikerEngine();
                const r = await eng.handleHikerApi(data);
                res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
                res.end(JSON.stringify(r));
            } catch (e) {
                console.error('ERROR in /hiker/run:', (e && e.stack) || e);
                try {
                    res.writeHead(500, { 'Content-Type': 'application/json; charset=utf-8' });
                    res.end(JSON.stringify({
                        ok: false,
                        error: '海阔接口异常：' + ((e && e.message) || String(e)),
                    }));
                } catch (_) { /* 响应已开始写出，忽略二次写入错误 */ }
            }
        });
        return;
    }

    if (req.method === 'POST' && url.pathname === '/command') {
        let body = '';
        req.on('data', chunk => { body += chunk; });
        req.on('end', () => {
            try {
                const data = JSON.parse(body);
                handleNativeMessage(JSON.stringify(data));
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ success: true }));
            } catch (e) {
                res.writeHead(400, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: e.message }));
            }
        });
        return;
    }

    // ── 小说书源：搜索 / 详情 / 目录 / 正文 / 登录 / 发现 ──────
    //
    // body: { action:'bsSearch'|'bsBookInfo'|'bsToc'|'bsContent'|'bsLogin'|'bsExplore',
    //         source:{...Legado 书源...}, keyword?, bookUrl?, tocUrl?, chapterUrl?,
    //         url?, method?, body?, contentType?, headers?, categoryUrl?, page? }
    //
    // 执行逻辑全在 book_source.js（Legado 规则求值 + 变量语法），
    // 这里只做转发 —— 与既有做法一致（影视源/音乐都走这条思路）。
    if (req.url === '/book/source') {
        let body = '';
        req.on('data', chunk => { body += chunk; });
        req.on('end', async () => {
            try {
                const data = JSON.parse(body || '{}');
                const bs = await getBookSource();
                const action = String(data.action || '');
                let r;
                switch (action) {
                    case 'bsSearch':
                        r = await bs.bsSearch({
                            source: data.source,
                            keyword: data.keyword,
                            page: data.page || 1,
                        });
                        break;
                    case 'bsBookInfo':
                        r = await bs.bsBookInfo({
                            source: data.source,
                            bookUrl: data.bookUrl,
                        });
                        break;
                    case 'bsToc':
                        r = await bs.bsToc({
                            source: data.source,
                            tocUrl: data.tocUrl,
                        });
                        break;
                    case 'bsContent':
                        r = await bs.bsContent({
                            source: data.source,
                            chapterUrl: data.chapterUrl,
                        });
                        break;
                    // 书源登录：拿到 Cookie 由 Dart 侧写进 source.header
                    case 'bsLogin':
                        r = await bs.bsLogin({
                            url: data.url,
                            method: data.method,
                            body: data.body,
                            contentType: data.contentType,
                            headers: data.headers,
                        });
                        break;
                    // 发现 / 分类浏览（exploreUrl + ruleExplore）
                    case 'bsExplore':
                        r = await bs.bsExplore({
                            source: data.source,
                            categoryUrl: data.categoryUrl,
                        });
                        break;
                    default:
                        r = { ok: false, error: '未知 action: ' + action };
                }
                res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
                res.end(JSON.stringify(r));
            } catch (e) {
                console.error('ERROR in /book/source:', (e && e.stack) || e);
                try {
                    res.writeHead(500, { 'Content-Type': 'application/json; charset=utf-8' });
                    res.end(JSON.stringify({
                        ok: false,
                        error: '书源接口异常：' + ((e && e.message) || String(e)),
                    }));
                } catch (_) { /* 响应已开始写出，忽略二次写入错误 */ }
            }
        });
        return;
    }

    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'not found' }));
});

mgmtServer.listen(0, '127.0.0.1', () => {
    managementPort = mgmtServer.address().port;
    console.log('=== mgmtServer listening on port ' + managementPort + ', nativeServerPort=' + nativeServerPort + ' ===');
    if (nativeServerPort > 0) {
        axios.get(`http://127.0.0.1:${nativeServerPort}/onCatPawOpenPort?port=${managementPort}&type=management`, { headers: nativeNotifyHeaders() })
            .then(() => console.log('=== onCatPawOpenPort(mgmt) sent OK ==='))
            .catch((e) => console.error('=== onCatPawOpenPort(mgmt) FAIL: ' + (e && e.message ? e.message : e) + ' ==='));
    }
    isReady = true;
    console.log('=== before sendMessageToNative(ready) ===');
    sendMessageToNative('ready');
    console.log('=== after sendMessageToNative(ready) ===');
});

// 全局未捕获异常处理已**上移到文件顶部**（必须早于任何顶层 require 才有效），
// 见 `process.on('uncaughtException' / 'unhandledRejection')` 处的说明。
