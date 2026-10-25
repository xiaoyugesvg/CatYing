// Telegram 源（MTProto / gramjs）
// ============================================================
// 为什么走内置 Node 而不是纯 HTTP 解析 t.me：
//   1. 私有群 / 私有频道 t.me/s 拿不到
//   2. t.me embed 页对超大文件不给 <video>，且 token 有时效
//   3. 需要真正的 Range 流式播放（拖进度条）
//
// 设计约束：
//   · 只做「协议 + 数据」，UI 全在 Flutter（本文件不产生任何 UI 概念）
//   · 会话落盘加密由 Dart 传入路径，Node 不猜沙盒目录
//   · 登录只支持扫码（QR）：不需要验证码、不需要 2FA 密码（除非账号强制 2FA）
//   · 所有对外方法返回纯 JSON 可序列化对象
//
// 失败模式：
//   · FLOOD_WAIT_X —— 全局限速，透传给 UI 让用户等
//   · FILE_REFERENCE_EXPIRED —— 缓存作废，重新取消息
//   · AUTH_KEY_UNREGISTERED —— 会话被吊销，要求重新扫码

import fs from 'fs';
import path from 'path';
import { TelegramClient, Api } from 'telegram';
import { StringSession } from 'telegram/sessions/index.js';
import { ConnectionTCPFull } from 'telegram/network/index.js';
import QRCode from 'qrcode';

// ── 全局状态 ────────────────────────────────────────────────
const st = {
    apiId: 0,
    apiHash: '',
    proxy: null,
    sessionPath: '',
    client: null,
    connecting: null,
    me: null,
    // 扫码登录状态机：idle | waiting | need_password | done | error
    login: { phase: 'idle', url: '', png: '', expires: 0, error: '', hint: '' },
    passwordResolver: null,
    loginTask: null,
    lastError: '',
};

// 消息缓存（避免每次 Range 请求都回源查消息）
// key: `${peer}|${id}` → { msg, ts }
const msgCache = new Map();
const MSG_TTL = 10 * 60 * 1000;

function now() { return Date.now(); }

function logErr(where, e) {
    const m = e && e.stack ? e.stack : (e && e.message ? e.message : String(e));
    st.lastError = `${where}: ${m}`;
    console.error(`[tg] ${where}:`, m);
}

function errText(e) {
    if (!e) return '未知错误';
    const raw = e.errorMessage || e.message || String(e);
    return String(raw);
}

/** 把 gramjs 的错误码翻成人话（UI 直接展示） */
function friendly(e) {
    const t = errText(e);
    if (/FLOOD_WAIT_(\d+)/.test(t)) {
        const s = Number(RegExp.$1);
        const mins = Math.ceil(s / 60);
        return `Telegram 限流，请等待约 ${mins} 分钟（FLOOD_WAIT_${s}）`;
    }
    if (/AUTH_KEY_UNREGISTERED|SESSION_REVOKED|USER_DEACTIVATED/.test(t)) {
        return '登录会话已失效，请重新扫码登录';
    }
    if (/FILE_REFERENCE_EXPIRED/.test(t)) return '文件引用过期，请重试';
    if (/CHANNEL_PRIVATE/.test(t)) return '无权访问该频道（未加入或已被封禁）';
    if (/USERNAME_NOT_OCCUPIED|Cannot find any entity/.test(t)) return '找不到该群/频道，检查用户名或 ID';
    if (/API_ID_INVALID|API_ID_PUBLISHED_FLOOD/.test(t)) return 'api_id / api_hash 无效';
    if (/PHONE_NUMBER|PASSWORD_HASH_INVALID/.test(t)) return '账号凭据无效';
    if (/CONNECT_TIMEOUT|CONNECTION|ECONNREFUSED|ETIMEDOUT|ENOTFOUND|socket/i.test(t)) {
        return '连不上 Telegram（网络被阻断）。请开启代理，或在上方填写 SOCKS5 代理地址';
    }
    return t;
}

// ── 配置 ────────────────────────────────────────────────────
export function configure(cfg = {}) {
    const id = parseInt(String(cfg.apiId || '0'), 10);
    if (id > 0) st.apiId = id;
    if (typeof cfg.apiHash === 'string' && cfg.apiHash.trim()) st.apiHash = cfg.apiHash.trim();
    if (typeof cfg.sessionPath === 'string' && cfg.sessionPath.trim()) st.sessionPath = cfg.sessionPath.trim();
    // 没给路径（远程引擎 / Docker 部署时 Dart 不会传）→ 落到进程工作目录，
    // 保证登录态能持久化；本地运行时 Dart 一定会传 Documents 下的路径。
    if (!st.sessionPath) {
        try {
            st.sessionPath = path.join(process.cwd(), '.tg-session.txt');
        } catch (_) {}
    }
    if (cfg.proxy !== undefined) {
        const p = cfg.proxy;
        const next = (p && p.host && p.port)
            ? {
                socksType: 5,
                ip: String(p.host),
                port: parseInt(String(p.port), 10),
                username: p.username || undefined,
                password: p.password || undefined,
                timeout: 15,
            }
            : null;
        // 代理变了 ⇒ 丢掉旧连接（下一次请求按新代理重建）。
        // 否则用户"换了个代理"，已登录的客户端还挂在旧线路上，看起来像没生效。
        const changed =
            JSON.stringify(next) !== JSON.stringify(st.proxy);
        st.proxy = next;
        if (changed && st.client) {
            try { st.client.disconnect().catch(() => {}); } catch (_) {}
            st.client = null;
            st.me = null;
        }
    }
    return {
        ok: true,
        configured: !!(st.apiId && st.apiHash),
        hasSession: !!readSession(),
        proxy: st.proxy ? `${st.proxy.ip}:${st.proxy.port}` : '',
    };
}

function readSession() {
    try {
        if (!st.sessionPath) return '';
        if (!fs.existsSync(st.sessionPath)) return '';
        const s = fs.readFileSync(st.sessionPath, 'utf8').trim();
        return s || '';
    } catch (_) { return ''; }
}

function saveSession(str) {
    try {
        if (!st.sessionPath || !str) return;
        const dir = path.dirname(st.sessionPath);
        if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
        // 先写临时文件再 rename：避免断电/被杀留下半截 session（半截 = 必须重新登录）
        const tmp = st.sessionPath + '.tmp';
        fs.writeFileSync(tmp, str, { mode: 0o600 });
        fs.renameSync(tmp, st.sessionPath);
    } catch (e) { logErr('saveSession', e); }
}

function clearSession() {
    try { if (st.sessionPath && fs.existsSync(st.sessionPath)) fs.unlinkSync(st.sessionPath); } catch (_) {}
}

// ── 客户端生命周期 ───────────────────────────────────────────
function buildClient() {
    const session = new StringSession(readSession());
    const opts = {
        connectionRetries: 2,
        retryDelay: 1500,
        autoReconnect: true,
        // ⚠️ 必须显式指定：Node 22 有全局 WebSocket，gramjs 会误判为浏览器
        // 环境，转而连 149.154.x.x:80 的 WebSocket，结果是必然超时。
        // 原生 TCP 才是 MTProto 在 iOS/Node 上的正确传输。
        connection: ConnectionTCPFull,
        useWSS: false,
        deviceModel: 'CatYing',
        systemVersion: 'iOS',
        appVersion: '1.0.0',
        langCode: 'zh',
    };
    if (st.proxy) opts.proxy = st.proxy;
    return new TelegramClient(session, st.apiId, st.apiHash, opts);
}

/** 连接超时（毫秒）：网络被墙时不能无限等，UI 要能快速拿到失败原因 */
const CONNECT_TIMEOUT = 25000;

/** 幂等连接：并发调用共享同一个 Promise，避免重复建连 */
export async function ensureConnected() {
    if (!st.apiId || !st.apiHash) {
        const e = new Error('未配置 api_id / api_hash');
        e.friendly = '请先填写 api_id / api_hash（my.telegram.org 免费申请）';
        throw e;
    }
    if (st.client && st.client.connected) return st.client;
    if (st.connecting) return st.connecting;

    st.connecting = (async () => {
        const c = st.client || buildClient();
        st.client = c;
        try {
            // 裸 connect() 在「墙内无代理」时会一直重试到操作系统超时（每个 DC 20s+），
            // 前端只能干等。这里强制给一个上限，失败就把原因说清楚。
            await Promise.race([
                c.connect(),
                new Promise((_, rej) => setTimeout(() => rej(new Error('CONNECT_TIMEOUT')), CONNECT_TIMEOUT)),
            ]);
            return c;
        } catch (e) {
            // 超时后客户端可能还在后台重连，直接丢弃，下次重新建
            try { await c.disconnect(); } catch (_) {}
            st.client = null;
            st.connecting = null;
            throw e;
        } finally {
            st.connecting = null;
        }
    })();

    try { return await st.connecting; }
    finally { st.connecting = null; }
}

/** 粗粒度登录态：不发网络请求（冷启动秒回） */
export function statusLocal() {
    return {
        ok: true,
        configured: !!(st.apiId && st.apiHash),
        hasSession: !!readSession(),
        sessionPath: st.sessionPath,
        login: { phase: st.login.phase, hint: st.login.hint || '' },
        me: st.me ? { id: st.me.id ? st.me.id.toString() : '', name: displayName(st.me) } : null,
        proxy: st.proxy ? `${st.proxy.ip}:${st.proxy.port}` : '',
        lastError: st.lastError,
    };
}

function displayName(u) {
    if (!u) return '';
    const n = [u.firstName, u.lastName].filter(Boolean).join(' ').trim();
    return n || u.username || (u.title || '');
}

/** 真正握手 + 校验授权（会走网络） */
export async function status() {
    const base = statusLocal();
    try {
        const c = await ensureConnected();
        const authed = await c.checkAuthorization();
        if (authed) {
            try {
                const me = await c.getMe();
                st.me = me;
                base.me = { id: me.id ? me.id.toString() : '', name: displayName(me) };
            } catch (_) {}
        }
        return { ...base, ok: true, authorized: authed, connected: true, login: { phase: authed ? 'done' : st.login.phase, hint: st.login.hint || '' } };
    } catch (e) {
        return { ...base, ok: false, authorized: false, connected: false, error: friendly(e) };
    }
}

// ── 扫码登录 ────────────────────────────────────────────────
/**
 * 启动扫码登录。返回首张二维码（可能还没生成，用轮询拿）。
 * 真正的登录流程在后台跑，结果通过 qrPoll() 读取。
 */
export async function startQrLogin() {
    if (!st.apiId || !st.apiHash) {
        return { ok: false, error: '请先填写 api_id / api_hash（my.telegram.org 免费申请）' };
    }
    if (st.loginTask && (st.login.phase === 'waiting' || st.login.phase === 'need_password')) {
        return qrPoll();
    }
    st.login = { phase: 'waiting', url: '', png: '', expires: 0, error: '', hint: '' };

    st.loginTask = (async () => {
        try {
            const c = await ensureConnected();
            if (await c.checkAuthorization()) {
                st.login.phase = 'done';
                return;
            }
            await c.signInUserWithQrCode(
                { apiId: st.apiId, apiHash: st.apiHash },
                {
                    qrCode: async (code) => {
                        // gramjs 每约 30 秒换一次 token，这里跟着刷新二维码
                        const url = `tg://login?token=${code.token.toString('base64url')}`;
                        st.login.url = url;
                        st.login.expires = code.expires ? Number(code.expires) * 1000 : now() + 30000;
                        try {
                            // 深色底 + 白块，和 App 主题一致
                            st.login.png = await QRCode.toDataURL(url, {
                                margin: 1,
                                width: 320,
                                color: { dark: '#FFFFFFFF', light: '#00000000' },
                                errorCorrectionLevel: 'M',
                            });
                        } catch (e) { logErr('qr.encode', e); }
                        if (st.login.phase !== 'need_password') st.login.phase = 'waiting';
                    },
                    password: async (hint) => {
                        // 账号开了两步验证：挂起等 UI 传密码
                        st.login.phase = 'need_password';
                        st.login.hint = hint || '';
                        return await new Promise((resolve) => { st.passwordResolver = resolve; });
                    },
                    onError: (e) => { throw e; },
                },
            );
            // 扫码成功
            st.me = await c.getMe().catch(() => null);
            saveSession(c.session.save());
            st.login.phase = 'done';
            st.login.error = '';
        } catch (e) {
            logErr('qrLogin', e);
            st.login.phase = 'error';
            st.login.error = friendly(e);
        } finally {
            st.passwordResolver = null;
        }
    })();

    // 给二维码生成留一点时间，避免首帧空白
    for (let i = 0; i < 20 && !st.login.png && st.login.phase === 'waiting'; i++) {
        await new Promise((r) => setTimeout(r, 150));
    }
    return qrPoll();
}

export function qrPoll() {
    return {
        ok: st.login.phase !== 'error',
        phase: st.login.phase,          // waiting | need_password | done | error
        url: st.login.url,
        png: st.login.png,
        expires: st.login.expires,
        hint: st.login.hint || '',
        error: st.login.error || '',
        me: st.me ? { id: st.me.id ? st.me.id.toString() : '', name: displayName(st.me) } : null,
    };
}

/** 提交两步验证密码 */
export function submitPassword(pw) {
    if (st.login.phase !== 'need_password' || !st.passwordResolver) {
        return { ok: false, error: '当前不需要两步验证密码' };
    }
    const r = st.passwordResolver;
    st.passwordResolver = null;
    st.login.phase = 'waiting';
    r(String(pw || ''));
    return { ok: true };
}

export async function logout() {
    try {
        if (st.client) { await st.client.logout().catch(() => {}); await st.client.disconnect().catch(() => {}); }
    } catch (_) {}
    st.client = null;
    st.me = null;
    msgCache.clear();
    clearSession();
    st.login = { phase: 'idle', url: '', png: '', expires: 0, error: '', hint: '' };
    return { ok: true };
}

// ── 会话列表（群 / 频道）────────────────────────────────────
/**
 * 返回用户账号可见的群和频道，供 UI 直接选，避免手填 ID 填错。
 */
export async function dialogs(limit = 100) {
    try {
        const c = await ensureConnected();
        const res = await c.invoke(new Api.messages.GetDialogs({
            offsetPeer: new Api.InputPeerEmpty(),
            offsetDate: 0,
            offsetId: 0,
            limit: Math.min(Math.max(limit, 1), 200),
            hash: 0,
        }));
        const chats = new Map();
        for (const ch of (res.chats || [])) {
            chats.set(String(ch.id), ch);
        }
        const out = [];
        for (const d of (res.dialogs || [])) {
            const p = d.peer;
            let id = null;
            if (p instanceof Api.PeerChannel) id = String(p.channelId);
            else if (p instanceof Api.PeerChat) id = String(p.chatId);
            if (!id) continue;
            const ch = chats.get(id);
            if (!ch) continue;
            out.push({
                id,
                // 可直接回传给后端当作 peer（channel id 走 -100xxx 格式最稳）
                peer: (ch.className === 'Channel' ? '-100' : '-') + id,
                username: ch.username || '',
                title: ch.title || '',
                type: ch.className === 'Channel'
                    ? (ch.megagroup ? 'group' : 'channel')
                    : 'chat',
                count: ch.participantsCount || 0,
            });
        }
        return { ok: true, items: out };
    } catch (e) {
        logErr('dialogs', e);
        return { ok: false, error: friendly(e), items: [] };
    }
}

// ── 频道内的视频 / 文件列表 ─────────────────────────────────
const VIDEO_EXT = ['mp4', 'mkv', 'avi', 'mov', 'm4v', 'ts', 'm2ts', 'flv', 'wmv', 'webm', 'rmvb'];

function docFileName(doc) {
    for (const a of (doc.attributes || [])) {
        if (a instanceof Api.DocumentAttributeFilename) return a.fileName || '';
    }
    return '';
}

function docVideoAttr(doc) {
    for (const a of (doc.attributes || [])) {
        if (a instanceof Api.DocumentAttributeVideo) return a;
    }
    return null;
}

function isPlayable(doc) {
    if (!doc || doc.className !== 'Document') return false;
    const mime = (doc.mimeType || '').toLowerCase();
    if (mime.startsWith('video/')) return true;
    const name = docFileName(doc).toLowerCase();
    const ext = name.includes('.') ? name.split('.').pop() : '';
    return VIDEO_EXT.includes(ext);
}

function titleOf(msg, fallback) {
    const cap = (msg.message || '').trim();
    if (cap) {
        const first = cap.split('\n').map((s) => s.trim()).filter(Boolean)[0] || '';
        if (first) return first.slice(0, 120);
    }
    const fn = fallback || '';
    if (fn) {
        const noExt = fn.replace(/\.[a-z0-9]{2,5}$/i, '');
        return noExt.slice(0, 120);
    }
    return `消息 ${msg.id}`;
}

function toItem(msg, doc) {
    const v = docVideoAttr(doc);
    const size = doc.size ? parseInt(doc.size.toString(), 10) : 0;
    return {
        id: msg.id,
        title: titleOf(msg, docFileName(doc)),
        fileName: docFileName(doc),
        size,
        duration: v && v.duration ? Number(v.duration) : 0,
        mime: doc.mimeType || '',
        date: msg.date ? Number(msg.date) : 0,
    };
}

/**
 * 拉取频道内视频列表（按消息从新到旧）
 * @param {string} peer  频道：@username / -100xxx / https://t.me/xxx
 * @param {number} offsetId 上一页最后一条消息 id（首页传 0）
 */
export async function videos(peer, offsetId = 0, limit = 30) {
    try {
        if (!peer) return { ok: false, error: '缺少 peer（频道地址或 ID）', items: [], next: 0 };
        const c = await ensureConnected();
        const entity = await c.getInputEntity(normalizePeer(peer));
        const res = await c.invoke(new Api.messages.GetHistory({
            peer: entity,
            offsetId: parseInt(String(offsetId || 0), 10),
            offsetDate: 0,
            addOffset: 0,
            limit: Math.min(Math.max(limit, 1), 100),
            maxId: 0,
            minId: 0,
            hash: 0,
        }));
        const items = [];
        let lastId = 0;
        for (const m of (res.messages || [])) {
            if (m.className !== 'Message') continue;
            const media = m.media;
            if (!(media instanceof Api.MessageMediaDocument)) continue;
            const doc = media.document;
            if (!isPlayable(doc)) continue;
            items.push(toItem(m, doc));
            lastId = Math.min(lastId || m.id, m.id);
        }
        return {
            ok: true,
            items,
            next: items.length >= 1 ? lastId : 0,   // 传给下一页
            total: res.count || 0,
        };
    } catch (e) {
        logErr('videos', e);
        return { ok: false, error: friendly(e), items: [], next: 0 };
    }
}

function normalizePeer(peer) {
    let p = String(peer || '').trim();
    if (!p) return p;
    // https://t.me/xxx / t.me/xxx → @xxx
    p = p.replace(/^https?:\/\//i, '').replace(/^t\.me\//i, '').replace(/^telegram\.me\//i, '');
    if (p.startsWith('s/')) p = p.slice(2);
    if (/^-100\d+$/.test(p) || /^-\d+$/.test(p) || /^\d+$/.test(p)) return p;
    if (!p.startsWith('@')) p = '@' + p;
    return p;
}

// ── 取消息对应的文件位置 ────────────────────────────────────
async function getDoc(peer, id, force = false) {
    const key = `${peer}|${id}`;
    const hit = msgCache.get(key);
    if (hit && !force && now() - hit.ts < MSG_TTL) return hit.doc;
    const c = await ensureConnected();
    const entity = await c.getInputEntity(normalizePeer(peer));
    const arr = await c.getMessages(entity, { ids: [parseInt(String(id), 10)] });
    const m = arr && arr[0];
    if (!m) throw new Error('消息不存在');
    const media = m.media;
    if (!(media instanceof Api.MessageMediaDocument)) throw new Error('该消息不是文件');
    const doc = media.document;
    if (!doc || doc.className !== 'Document') throw new Error('文件已被删除');
    msgCache.set(key, { doc, ts: now() });
    return doc;
}

/**
 * Range 流：把播放器的 bytes=start-end 翻成 TG 的 offset/limit 分片。
 * @returns {{size:number, mime:string}}
 */
export async function streamTo(req, res, peer, id, fileName) {
    let doc;
    try {
        doc = await getDoc(peer, id);
    } catch (e) {
        // 引用过期 → 强制回源一次
        try { doc = await getDoc(peer, id, true); }
        catch (e2) {
            logErr('stream.getDoc', e2);
            res.writeHead(404, { 'Content-Type': 'application/json; charset=utf-8' });
            res.end(JSON.stringify({ error: friendly(e2) }));
            return;
        }
    }

    const size = doc.size ? parseInt(doc.size.toString(), 10) : 0;
    const mime = doc.mimeType || 'video/mp4';
    const name = fileName || docFileName(doc) || `tg-${id}.mp4`;

    // 解析 Range
    let start = 0;
    let end = size > 0 ? size - 1 : 0;
    let partial = false;
    const rng = req.headers.range;
    if (rng) {
        const m = /bytes=(\d*)-(\d*)/.exec(String(rng));
        if (m) {
            partial = true;
            if (m[1] !== '') start = parseInt(m[1], 10);
            if (m[2] !== '') end = parseInt(m[2], 10);
            else if (size > 0) end = size - 1;
        }
    }
    if (size > 0) {
        if (end >= size) end = size - 1;
        if (start > end) start = end;
    }
    const len = size > 0 ? (end - start + 1) : 0;

    const headers = {
        'Content-Type': mime,
        'Accept-Ranges': 'bytes',
        'Cache-Control': 'no-store',
        'Content-Disposition': `inline; filename*=UTF-8''${encodeURIComponent(name)}`,
    };
    if (size > 0) {
        headers['Content-Length'] = String(len);
        if (partial) headers['Content-Range'] = `bytes ${start}-${end}/${size}`;
    }
    res.writeHead(partial ? 206 : 200, headers);

    if (req.method === 'HEAD') { res.end(); return; }

    try {
        // gramjs 的 iterDownload 支持 offset，但一次只吐 chunkSize；
        // 我们按需累加，凑够 len 就停（不把整个文件读进内存）。
        const it = st.client.iterDownload({
            file: doc,
            offset: start,
            requestSize: 256 * 1024,
            chunkSize: 256 * 1024,
            fileSize: size || undefined,
        });
        let sent = 0;
        let closed = false;
        res.on('close', () => { closed = true; });
        for await (const chunk of it) {
            if (closed) break;
            if (!chunk || !chunk.length) continue;
            const take = len > 0 ? Math.min(chunk.length, len - sent) : chunk.length;
            if (take <= 0) break;
            const buf = take === chunk.length ? chunk : chunk.subarray(0, take);
            const okWrite = res.write(buf);
            sent += take;
            if (len > 0 && sent >= len) break;
            if (!okWrite) {
                // 背压：等 drain，避免内存暴涨
                await new Promise((r) => res.once('drain', r));
            }
        }
        res.end();
    } catch (e) {
        logErr('stream', e);
        try { res.destroy(); } catch (_) {}
    }
}

/** 封面缩略图（频道列表用）—— 直接吐图片字节 */
export async function thumbTo(res, peer, id) {
    try {
        let doc = null;
        let msg = null;
        const hit = msgCache.get(`${peer}|${id}`);
        if (hit) msg = hit.msg;
        if (!msg) {
            const c = await ensureConnected();
            const entity = await c.getInputEntity(normalizePeer(peer));
            const arr = await c.getMessages(entity, { ids: [parseInt(String(id), 10)] });
            msg = arr && arr[0];
        }
        if (msg && msg.media instanceof Api.MessageMediaDocument) {
            const d = msg.media.document;
            if (d && d.thumbs && d.thumbs.length) doc = d.thumbs[d.thumbs.length - 1];
        }
        if (!doc) {
            res.writeHead(404); res.end(); return;
        }
        const buf = await st.client.downloadMedia(doc, {});
        if (!buf || !buf.length) { res.writeHead(404); res.end(); return; }
        res.writeHead(200, {
            'Content-Type': 'image/jpeg',
            'Cache-Control': 'public, max-age=86400',
            'Content-Length': String(buf.length),
        });
        res.end(buf);
    } catch (e) {
        logErr('thumb', e);
        try { res.writeHead(404); res.end(); } catch (_) {}
    }
}

export function _debug() { return { ...st, client: !!st.client }; }
