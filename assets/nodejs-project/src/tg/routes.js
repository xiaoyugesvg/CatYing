// Telegram 源的 HTTP 入口
// ============================================================
// 两条通道：
//   1. POST /tg            { action, ... }  → JSON（登录 / 列表 / 配置）
//   2. GET  /tg/stream     ?peer=&id=       → 二进制流（支持 Range，给播放器）
//      GET  /tg/thumb      ?peer=&id=       → 图片字节（列表封面）
//
// 为什么流式单独一条路：播放器要 206 + Content-Range，不能塞进 JSON。

import * as svc from './service.js';
import * as pub from './public.js';
import { agentOptions, currentProxy, refreshPool, setProxy } from './proxypool.js';
import axios from 'axios';

/** peer/id → 已解析的 mp4 直链（token 有时效，10 分钟就作废重取） */
const resolvedCache = new Map(); // key → { url, at }
const RESOLVE_TTL = 10 * 60 * 1000;

async function resolveCached(peer, id) {
    const key = `${peer}/${id}`;
    const hit = resolvedCache.get(key);
    if (hit && Date.now() - hit.at < RESOLVE_TTL) return hit;
    const r = await pub.resolvePublic(peer, id);
    if (!r.ok) return null;
    const rec = { url: r.url, at: Date.now() };
    if (resolvedCache.size > 200) resolvedCache.clear();
    resolvedCache.set(key, rec);
    return rec;
}

/** telegram 的 CDN 域名白名单（`/tg/raw` 只放行这些，避免变成任意 URL 代理） */
function isTgCdn(u) {
    try {
        const h = new URL(u).hostname.toLowerCase();
        return /(^|\.)(telesco\.pe|telegram\.org|telegram-cdn\.org|cdn-telegram\.org|t\.me)$/.test(h);
    } catch (_) {
        return false;
    }
}

/** 把上游（cdn）的字节按 Range 透传给播放器 */
async function proxyStream(req, res, targetUrl) {
    const headers = {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) ' +
            'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
        // telesco 的直链会校验来源页；少了这个 Referer 常见 403
        Referer: 'https://t.me/',
        Accept: '*/*',
        // 让上游别压缩：Range 播放要求字节偏移一一对应
        'Accept-Encoding': 'identity',
        ...(req.headers.range ? { Range: req.headers.range } : {}),
    };
    let r;
    try {
        r = await axios.get(targetUrl, {
            ...agentOptions(),
            responseType: 'stream',
            timeout: 30000,
            maxRedirects: 5,
            validateStatus: () => true,
            headers,
        });
    } catch (e) {
        json(res, 502, { ok: false, error: '上游拉流失败：' + ((e && e.message) || e) });
        return;
    }
    const ct = String(r.headers['content-type'] || '');
    const isPlaylist = /mpegurl|m3u8/i.test(ct) || /\.m3u8(\?|$)/i.test(targetUrl);

    if (isPlaylist) {
        // 播放列表很小（几 KB），整块读进来改写没问题
        const chunks = [];
        try {
            for await (const c of r.data) chunks.push(Buffer.from(c));
        } catch (_) {}
        const base = targetUrl.split('?')[0];
        const baseDir = base.slice(0, base.lastIndexOf('/') + 1);
        const text = Buffer.concat(chunks).toString('utf8').split('\n').map((line) => {
            const t = line.trim();
            if (!t) return line;
            if (t.startsWith('#')) {
                // #EXT-X-KEY:URI="..."
                return line.replace(/URI="([^"]+)"/, (m, u) => {
                    const abs = u.startsWith('http') ? u : new URL(u, baseDir).toString();
                    return `URI="/tg/raw?u=${encodeURIComponent(abs)}"`;
                });
            }
            const abs = t.startsWith('http') ? t : new URL(t, baseDir).toString();
            return `/tg/raw?u=${encodeURIComponent(abs)}`;
        }).join('\n');
        const out = Buffer.from(text, 'utf8');
        res.writeHead(r.status, {
            'Content-Type': 'application/vnd.apple.mpegurl',
            'Content-Length': out.length,
            'Cache-Control': 'no-store',
        });
        res.end(out);
        return;
    }

    const out = {};
    if (ct) out['Content-Type'] = ct;
    const cl = r.headers['content-length'];
    const cr = r.headers['content-range'];
    const ar = r.headers['accept-ranges'];
    if (cl) out['Content-Length'] = cl;
    if (cr) out['Content-Range'] = cr;
    out['Accept-Ranges'] = ar || 'bytes';
    out['Cache-Control'] = 'no-store';
    try {
        res.writeHead(r.status, out);
    } catch (_) {
        return;
    }
    // 🔴 上游中途断流时必须 **destroy** 而不是 end()（用户 2026-10-29
    //   「加载出来了画面，但是就是超时播放不了」）：
    //   响应头里已经写了 Content-Length，上游少给字节却"正常结束" ⇒
    //   播放器等的是剩下的字节，既不报错也不继续收 ⇒ 一直缓冲到它自己的
    //   超时（App 侧 15s 的「加载超时」）。断连接它才会立刻重试。
    const bail = () => {
        try { r.data.destroy(); } catch (_) {}
        try { res.destroy(); } catch (_) {}
    };
    r.data.on('error', bail);
    r.data.on('aborted', bail);
    // 上游「正常结束但字节不够」也要按断流处理。
    // 监听器注册在 pipe 之前 ⇒ 先于 pipe 的 onend 执行，能抢先把连接断掉。
    let piped = 0;
    const want = parseInt(cl || '0', 10) || 0;
    r.data.on('data', (c) => { piped += c.length; });
    r.data.on('end', () => {
        if (want > 0 && piped < want) {
            console.warn(`[TG] 上游提前结束：${piped}/${want} 字节`);
            bail();
        }
    });
    r.data.pipe(res);
    req.on('close', () => {
        try { r.data.destroy(); } catch (_) {}
    });
}

function readJson(req) {
    return new Promise((resolve) => {
        let body = '';
        let size = 0;
        req.on('data', (c) => {
            size += c.length;
            if (size > 1 << 20) { req.destroy(); resolve({}); return; }  // 1MB 上限，防呆
            body += c;
        });
        req.on('end', () => {
            try { resolve(JSON.parse(body || '{}')); } catch (_) { resolve({}); }
        });
        req.on('error', () => resolve({}));
    });
}

function json(res, code, obj) {
    try {
        res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify(obj));
    } catch (_) {}
}

/** 把 peer/id 拼成可回传给 Dart 的相对地址 */
export function mediaUrl(peer, id) {
    return `/tg/stream?peer=${encodeURIComponent(peer)}&id=${id}`;
}

export function thumbUrl(peer, id) {
    return `/tg/thumb?peer=${encodeURIComponent(peer)}&id=${id}`;
}

export async function handle(req, res, url) {
    // ── 二进制：Range 流 ──────────────────────────────────
    if (url.pathname === '/tg/stream') {
        const peer = url.searchParams.get('peer') || '';
        const id = url.searchParams.get('id') || '';
        const name = url.searchParams.get('name') || '';
        if (!peer || !id) { json(res, 400, { error: 'missing peer/id' }); return; }
        // 没登录：MTProto 一定失败（原来的 500 / 无限转圈就是这么来的）。
        // 公开频道还能走网页直链 ⇒ 先试公开解析，再不行给明确的 401。
        if (!svc.hasSession()) {
            const rec = await resolveCached(peer, parseInt(id, 10));
            if (rec) { await proxyStream(req, res, rec.url); return; }
            json(res, 401, {
                ok: false,
                error: '未登录：登录频道要先扫码；公开频道可以不用登录，'
                    + '但要能连上 t.me（连不上就开内置代理池）',
            });
            return;
        }
        try {
            await svc.streamTo(req, res, peer, id, name);
        } catch (e) {
            // 任何漏网异常都不能变成裸 500（播放器只会转圈），
            // 统一给播放器一个能看见的状态码 + 原因
            try {
                json(res, 502, {
                    ok: false,
                    error: 'TG 取流失败：' + ((e && e.message) || String(e)),
                });
            } catch (_) {}
        }
        return;
    }

    // ── 二进制：封面 ─────────────────────────────────────
    if (url.pathname === '/tg/thumb') {
        const peer = url.searchParams.get('peer') || '';
        const id = url.searchParams.get('id') || '';
        if (!peer || !id) { res.writeHead(400); res.end(); return; }
        await svc.thumbTo(res, peer, id);
        return;
    }

    // ── 公开频道：一律由本机中转播放 ─────────────────────
    //
    // 为什么不再 302 到 cdn（2026-10-25 修「能进播放器但一直转圈」）：
    //   · cdn*.telesco.pe 会挑 UA / Referer，AVPlayer 直接拉多半 403 或挂住；
    //   · 国内网络对 CDN 域名常常连不上，但 t.me 页面本身能打开（差异在域名）；
    //   · 走本机中转还有一个好处：mp4 的 token 由 Node 现取，播放器永远拿到新鲜的。
    // 本机这一跳只剩内存拷贝，代价远小于"打不开"。
    if (url.pathname === '/tg/embed') {
        const peer = url.searchParams.get('peer') || '';
        const id = url.searchParams.get('id') || '';
        if (!peer || !id) { json(res, 400, { error: 'missing peer/id' }); return; }
        res.writeHead(302, {
            Location: `/tg/pubstream?peer=${encodeURIComponent(peer)}&id=${encodeURIComponent(id)}`,
            'Cache-Control': 'no-store',
        });
        res.end();
        return;
    }

    // ── 公开频道：经代理中转的播放流（支持 Range）──────────
    if (url.pathname === '/tg/pubstream') {
        const peer = url.searchParams.get('peer') || '';
        const id = url.searchParams.get('id') || '';
        if (!peer || !id) { json(res, 400, { error: 'missing peer/id' }); return; }
        const rec = await resolveCached(peer, parseInt(id, 10));
        if (rec) { await proxyStream(req, res, rec.url); return; }
        // 网页解析不出来时，登录用户还有 MTProto 这一条路
        //（有些公开频道把视频当文件发，embed 页没有 <video>，但 MTProto 能取）
        if (svc.hasSession()) {
            await svc.streamTo(req, res, peer, id, '');
            return;
        }
        json(res, 404, {
            ok: false,
            error: '解析不出可播放地址：连不上 t.me 时请开「内置代理池」，'
                + '或用公开频道/扫码登录后重试',
        });
        return;
    }

    // ── 公开频道：封面中转（t.me 的图国内也常常拉不下来）──
    if (url.pathname === '/tg/pubimg') {
        const u = url.searchParams.get('u') || '';
        if (!u) { res.writeHead(400); res.end(); return; }
        await proxyStream(req, res, u);
        return;
    }

    // ── HLS 分片 / 密钥中转（m3u8 被上面改写后会指到这里）──
    if (url.pathname === '/tg/raw') {
        const u = url.searchParams.get('u') || '';
        if (!u) { res.writeHead(400); res.end(); return; }
        if (!isTgCdn(u)) { json(res, 403, { error: '只允许 telegram 的 CDN 域名' }); return; }
        await proxyStream(req, res, u);
        return;
    }

    if (url.pathname !== '/tg') { json(res, 404, { error: 'not found' }); return; }

    const data = await readJson(req);
    const action = String(data.action || '');

    try {
        switch (action) {
            // 保存 api_id / api_hash / 代理 / session 路径
            case 'tgConfig':
                // 代理同时交给「网页抓取 + 播放中转」用（gramjs 那边由 svc 管）
                setProxy(data.proxy);
                json(res, 200, svc.configure(data));
                return;

            // t.me 连通性自测（不改配置，按当前代理/系统 VPN 打一次）
            case 'tgNetTest':
                json(res, 200, await pub.probeTme());
                return;

            // 内置免费代理池：拉列表 + 并发测速，返回按延迟排序的可用项
            case 'tgProxyProbe': {
                try {
                    const list = await refreshPool({
                        timeoutMs: parseInt(data.timeoutMs || 10000, 10),
                    });
                    json(res, 200, { ok: true, items: list, total: list.length });
                } catch (e) {
                    json(res, 200, {
                        ok: false,
                        error: (e && e.message) || String(e),
                        items: [],
                    });
                }
                return;
            }

            // 冷启动秒回（不发网络请求）
            case 'tgStatus':
                json(res, 200, svc.statusLocal());
                return;

            // 网络握手 + 授权校验
            case 'tgPing':
                json(res, 200, await svc.status());
                return;

            // 开始扫码登录（返回首张二维码）
            case 'tgQr':
                json(res, 200, await svc.startQrLogin());
                return;

            // 轮询扫码状态
            case 'tgQrPoll':
                json(res, 200, svc.qrPoll());
                return;

            // 两步验证密码
            case 'tgPassword':
                json(res, 200, svc.submitPassword(data.password));
                return;

            case 'tgLogout':
                json(res, 200, await svc.logout());
                return;

            // 我加入的群 / 频道
            case 'tgDialogs':
                json(res, 200, await svc.dialogs(data.limit || 100));
                return;

            // 频道内的视频列表
            case 'tgVideos': {
                const r = await svc.videos(data.peer, data.offsetId || 0, data.limit || 30);
                if (r.ok) {
                    r.items = r.items.map((it) => ({
                        ...it,
                        url: mediaUrl(data.peer, it.id),
                        thumb: thumbUrl(data.peer, it.id),
                    }));
                }
                json(res, 200, r);
                return;
            }

            // ── 公开频道（不需要登录）────────────────────
            // 列表：t.me/s/<频道>?before=<id>
            case 'tgPublicList': {
                const r = await pub.listPublic(data.peer, data.offsetId || 0);
                if (r.ok) {
                    const viaProxy = !!currentProxy();
                    r.items = r.items.map((it) => ({
                        ...it,
                        url: `/tg/embed?peer=${encodeURIComponent(data.peer)}&id=${it.id}`,
                        // 封面也走本机中转：t.me 的图国内常常拉不下来（且会卡列表）
                        thumb: it.thumb && viaProxy
                            ? `/tg/pubimg?u=${encodeURIComponent(it.thumb)}`
                            : it.thumb,
                    }));
                }
                json(res, 200, r);
                return;
            }

            // 单条解析（给"外面想要直链"的场景；正常播放走 /tg/embed）
            case 'tgPublicVideo':
                json(res, 200, await pub.resolvePublic(data.peer, data.id));
                return;

            default:
                json(res, 200, { ok: false, error: '未知 action: ' + action });
        }
    } catch (e) {
        // 复核 R5：以前只回 `e.message`，`X.next is not a function` 这种
        // 打包 / 运行时错误光看一句 message 完全定位不到模块和行号。
        // 现在把 stack + action 一起回给客户端（App 侧写进日志，UI 仍只显 message）。
        const msg = (e && e.message) || String(e);
        const stack = (e && e.stack) || '';
        console.error('[tg] route error:', stack || msg);
        json(res, 500, {
            ok: false,
            error: msg,
            stack,
            action,
            where: 'tg/' + action,
        });
    }
}
