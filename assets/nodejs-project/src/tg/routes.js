// Telegram 源的 HTTP 入口
// ============================================================
// 两条通道：
//   1. POST /tg            { action, ... }  → JSON（登录 / 列表 / 配置）
//   2. GET  /tg/stream     ?peer=&id=       → 二进制流（支持 Range，给播放器）
//      GET  /tg/thumb      ?peer=&id=       → 图片字节（列表封面）
//
// 为什么流式单独一条路：播放器要 206 + Content-Range，不能塞进 JSON。

import * as svc from './service.js';

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
        await svc.streamTo(req, res, peer, id, name);
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

    if (url.pathname !== '/tg') { json(res, 404, { error: 'not found' }); return; }

    const data = await readJson(req);
    const action = String(data.action || '');

    try {
        switch (action) {
            // 保存 api_id / api_hash / 代理 / session 路径
            case 'tgConfig':
                json(res, 200, svc.configure(data));
                return;

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

            default:
                json(res, 200, { ok: false, error: '未知 action: ' + action });
        }
    } catch (e) {
        console.error('[tg] route error:', (e && e.stack) || e);
        json(res, 500, { ok: false, error: (e && e.message) || String(e) });
    }
}
