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
// gramjs 的 iterDownload 对 offset / fileSize 做的是 big-integer 运算
//（.add / .divide / .subtract），传普通 number 会抛 "o.add is not a function"
import bigInt from 'big-integer';
import { TelegramClient, Api } from 'telegram';
import { StringSession } from 'telegram/sessions/index.js';
import { ConnectionTCPFull } from 'telegram/network/index.js';
import QRCode from 'qrcode';
import { titleFromGuillemets } from './public.js';
import { parseRange, requestSizeFor } from './range.js';

// ── 全局状态 ────────────────────────────────────────────────
// 内置应用凭据（Telegram Desktop 公开的一组）：Dart 侧没推配置时也能直接扫码，
// 免得"没进过设置页 ⇒ 提示未配置"。
const DEFAULT_API_ID = 2040;
const DEFAULT_API_HASH = 'b18441a1ff607e10a989891a5462e627';

const st = {
    apiId: DEFAULT_API_ID,
    apiHash: DEFAULT_API_HASH,
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
        //
        // ⚠️ **只重建连接，不动登录态**：会话字符串一直在 sessionPath 里，
        //   下次 ensureConnected 用同一个 StringSession 重新握手 ⇒ 不需要重新扫码。
        //   只有 logout() 才会删会话文件。
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

/** 有没有本地会话（不发网络请求，给路由层做"能不能走 MTProto"的判断） */
export function hasSession() {
    return !!readSession();
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
        // 播放器经常一次发多个 Range 请求，容易撞 FLOOD_WAIT。
        // 让 gramjs 自己等（60s 以内），而不是直接把 404 甩给播放器（那就是转圈）。
        floodSleepThreshold: 60,
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
        e.friendly = '应用凭据缺失（内置凭据异常，去高级设置里填一组）';
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
    // 与公开频道同一套（2026-10-25 第二轮：Node 不再写死广告词）：
    //   《片名》优先 → 帖子第一行 → 文件名 → '视频'
    // 广告/表情过滤挪到 App（可配置），这里只负责"尽量给出一个像样的名字"。
    const cap = (msg.message || '').trim();
    const firstLine = cap
        .split('\n')
        .map((s) => s.trim())
        .filter(Boolean)[0] || '';
    return titleFromGuillemets(cap)
        || titleFromGuillemets(fallback)
        || firstLine
        || fallback
        || '视频';
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
 * @param {number} depth 内部用：整页都被过滤时自动往后翻的次数（最多 3 次）
 */
export async function videos(peer, offsetId = 0, limit = 30, depth = 0) {
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
        let minId = 0;
        for (const m of (res.messages || [])) {
            if (m.className !== 'Message') continue;
            // 游标按**全部**消息记：整页都是广告时也要能继续往下翻
            if (!minId || m.id < minId) minId = m.id;
            const media = m.media;
            if (!(media instanceof Api.MessageMediaDocument)) continue;
            const doc = media.document;
            if (!isPlayable(doc)) continue;
            // 顺手把消息缓存下来：列表里每张封面都要 getMessages 一次
            // ⇒ 12 个卡片就是 12 个 RPC，慢且容易 404（"登录的没封面"）
            msgCache.set(`${peer}|${m.id}`, { doc, msg: m, ts: now() });
            const item = toItem(m, doc);
            items.push(item);
        }
        // 整页都被过滤，但可能还有更早的视频 ⇒ 自动再往后翻
        if (items.length === 0 && minId > 0 && depth < 3) {
            return videos(peer, minId, limit, depth + 1);
        }
        return {
            ok: true,
            items,
            next: items.length > 0 ? minId : 0,   // 传给下一页
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
    // 必须连 msg + doc 一起命中：取流要传 msg.media，封面要用 msg；
    // 只有 msg 没有 doc 的缓存是 thumbTo 塞的，取流不能直接用（doc 会取到 null）
    if (hit && !force && now() - hit.ts < MSG_TTL && hit.msg && hit.doc) return hit;
    const c = await ensureConnected();
    const entity = await c.getInputEntity(normalizePeer(peer));
    const arr = await c.getMessages(entity, { ids: [parseInt(String(id), 10)] });
    const m = arr && arr[0];
    if (!m) throw new Error('消息不存在');
    const media = m.media;
    if (!(media instanceof Api.MessageMediaDocument)) throw new Error('该消息不是文件');
    const doc = media.document;
    if (!doc || doc.className !== 'Document') throw new Error('文件已被删除');
    // 顺手把 msg 一起缓存：封面/取流都要用（原来只存 doc，`hit.msg` 永远是
    // undefined ⇒ 每张封面都重新 getMessages 一次，列表一屏十几个多余 RPC）
    const entry = { doc, msg: m, ts: now() };
    msgCache.set(key, entry);
    return entry;
}

/**
 * Range 流：把播放器的 bytes=start-end 翻成 TG 的 offset/limit 分片。
 * @returns {{size:number, mime:string}}
 */
export async function streamTo(req, res, peer, id, fileName) {
    // 没登录就别去连了：ensureConnected 会白等 25 秒，播放器只能转圈
    //（用户 2026-10-25 日志：未登录点登录频道 ⇒ 一直缓冲/500）。
    if (!readSession()) {
        res.writeHead(401, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({
            ok: false,
            error: '未登录：登录频道需要先扫码登录；公开频道可不用登录，但要能连上 t.me（可开内置代理）',
        }));
        return;
    }
    let entry;
    try {
        entry = await getDoc(peer, id);
    } catch (e) {
        // 引用过期 → 强制回源一次
        try { entry = await getDoc(peer, id, true); }
        catch (e2) {
            logErr('stream.getDoc', e2);
            res.writeHead(404, { 'Content-Type': 'application/json; charset=utf-8' });
            res.end(JSON.stringify({ error: friendly(e2) }));
            return;
        }
    }
    const doc = entry.doc;

    const size = doc.size ? parseInt(doc.size.toString(), 10) : 0;
    const mime = doc.mimeType || 'video/mp4';
    const name = fileName || docFileName(doc) || `tg-${id}.mp4`;

    // 解析 Range（后缀区间 / 总长未知 / 不可满足 ⇒ 见 range.js 的注释）
    const spec = parseRange(req.headers.range, size);
    if (spec.unsatisfiable) {
        // 416 必须带 `Content-Range: bytes */size`，播放器才知道真实长度、
        // 才能改发一个合法区间。原来这里是「夹成 1 个字节」⇒ 错位数据。
        res.writeHead(416, {
            'Content-Range': `bytes */${size}`,
            'Accept-Ranges': 'bytes',
            'Cache-Control': 'no-store',
        });
        res.end();
        return;
    }
    const { start, end, len, partial } = spec;

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
    if (req.method === 'HEAD') {
        res.writeHead(partial ? 206 : 200, headers);
        res.end();
        return;
    }

    // ⚠️ 先抓到第一块再写响应头。
    //   否则「FLOOD_WAIT / 无权访问 / 文件被删」这类错误是在 **200 已发出之后**
    //   才发生的 ⇒ 播放器收到一个 Content-Length 正常的空响应，然后一直转圈。
    //   先抓一块，失败就返回 502 + 错误 JSON，播放器立刻能报错。
    let it;
    let first = null;
    // 本次单块字节数：小请求（探流 2 字节）只取 4KB，别为了 2 字节拖 256KB
    const chunkBytes = requestSizeFor(len);
    try {
        // ⚠️ 这里必须重新 ensureConnected：getDoc 命中 msgCache 时**不会建连**，
        //   直接 `st.client.iterDownload` 会在 client 为 null 时抛 TypeError
        //   （用户日志里 /tg/stream 秒回 500 就是这个）。
        const c = await ensureConnected();
        // 🔴 2026-10-26 修复（用户报错：Cannot cast Document to any kind of
        //   InputFileLocation）：`iterDownload` 内部走 `utils.getFileInfo(file)`，
        //   它只认 InputFileLocation / Message / MessageMediaDocument / Photo ——
        //   直接丢**裸 Document** 会在这里强转失败，于是点开就报错。
        //   传 `msg.media`（MessageMediaDocument）才会被拆成
        //   InputDocumentFileLocation，并且顺带拿到正确的 dcId（跨机房文件）。
        const stream = c.iterDownload({
            file: entry.msg.media,
            // ⚠️ 这两个必须是 big-integer：gramjs 内部对它们调 .add/.divide，
            //   传 number 就是 "o.add is not a function"（用户 2026-10-26）
            offset: bigInt(start),
            // 播放器探流只发 `bytes=0-1`（要 2 字节），原来固定 256KB ⇒
            // 为了回 2 字节先从 Telegram 拖 256KB，慢网下这一下就超时。
            // 按实际区间收窄（下限 4KB），起播/拖进度都明显更快。
            requestSize: chunkBytes,
            chunkSize: chunkBytes,
            fileSize: size > 0 ? bigInt(size) : undefined,
            // 长视频中途 fileReference 会过期：带上 [inputChat, msgId]，
            // gramjs 能自己重新拉一次消息换取新引用（和 downloadMedia 内部一致）
            msgData: entry.msg.inputChat
                ? [entry.msg.inputChat, entry.msg.id]
                : undefined,
        });
        // 🔴 2026-10-26（用户报错 "m.next is not a function"）：
        //   gramjs 的 RequestIter 实例**自身没有 next()**，它只实现了
        //   `[Symbol.asyncIterator]()`，调用后返回一个 { next } 对象。
        //   直接 `stream.next()` 必然报错；要先取异步迭代器。
        it = stream[Symbol.asyncIterator]();
        // 手动 next()：`for await` 里 break 会 close 掉生成器，后面就没得读了
        while (true) {
            const r = await it.next();
            if (r.done) break;
            if (r.value && r.value.length) {
                first = r.value;
                break;
            }
        }
    } catch (e) {
        logErr('stream.first', e);
        res.writeHead(502, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ error: friendly(e) }));
        return;
    }
    if (!first) {
        // 一个字节都没取到：若已声明 Content-Length，**必须**断连接而不是 end()
        res.writeHead(partial ? 206 : 200, headers);
        if (len > 0) {
            logErr('stream.empty', new Error(`没取到字节（期望 ${len}）`));
            try { res.destroy(); } catch (_) {}
            return;
        }
        res.end();
        return;
    }

    res.writeHead(partial ? 206 : 200, headers);
    let sent = 0;
    let closed = false;
    res.on('close', () => { closed = true; });
    try {
        const head = len > 0 && first.length > len ? first.subarray(0, len) : first;
        res.write(head);
        sent += head.length;
        // gramjs 的 iterDownload 支持 offset，但一次只吐 chunkSize；
        // 我们按需累加，凑够 len 就停（不把整个文件读进内存）。
        while (!closed && !(len > 0 && sent >= len)) {
            const r = await it.next();
            if (r.done) break;
            const chunk = r.value;
            if (!chunk || !chunk.length) continue;
            const take = len > 0 ? Math.min(chunk.length, len - sent) : chunk.length;
            if (take <= 0) break;
            const buf = take === chunk.length ? chunk : chunk.subarray(0, take);
            const okWrite = res.write(buf);
            sent += take;
            if (!okWrite) {
                // 背压：等 drain，避免内存暴涨
                await new Promise((r2) => res.once('drain', r2));
            }
        }
        // 🔴 用户 2026-10-29「加载出来了画面，但是就是超时播放不了」：
        //   上游提前耗尽（TG 侧 done、FLOOD_WAIT 后中途放弃）时，原来直接
        //   `res.end()` —— 但响应头里已经写了 `Content-Length: len`，
        //   播放器等的是剩下的字节，**连接却是"正常结束"** ⇒ 它既不报错
        //   也不继续收，就一直缓冲到自己的超时（15s 的"加载超时"）。
        //   字节没发够就必须 destroy，让播放器立刻看到网络中断并自己重试。
        if (len > 0 && sent < len) {
            logErr('stream.short', new Error(`只发出 ${sent}/${len} 字节`));
            try { res.destroy(); } catch (_) {}
            return;
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
        let thumb = null;
        let doc = null;
        let msg = null;
        const hit = msgCache.get(`${peer}|${id}`);
        // ⚠️ 只用缓存里的 msg，别拿 hit.doc —— 那是**完整视频**文档，
        //   一旦走到 downloadMedia 就会把整个视频拉下来当封面。
        if (hit) msg = hit.msg;
        if (!msg) {
            const c = await ensureConnected();
            const entity = await c.getInputEntity(normalizePeer(peer));
            const arr = await c.getMessages(entity, { ids: [parseInt(String(id), 10)] });
            msg = arr && arr[0];
            if (msg) msgCache.set(`${peer}|${id}`, { doc: hit ? hit.doc : null, msg, ts: now() });
        }
        if (msg && msg.media instanceof Api.MessageMediaDocument) {
            doc = msg.media.document;
            // 视频文件有时只有 `videoThumbs`（VideoSize），`thumbs` 为空 ⇒
            // 之前直接 404，列表里就是一片"没有封面"（用户 2026-10-25）
            const cands = [
                ...(doc && Array.isArray(doc.thumbs) ? doc.thumbs : []),
                ...(doc && Array.isArray(doc.videoThumbs) ? doc.videoThumbs : []),
            ];
            if (cands.length) thumb = cands[cands.length - 1];
        }
        if (!thumb) {
            res.writeHead(404); res.end(); return;
        }

        const c2 = await ensureConnected();

        // 🔴 2026-10-26 修复（用户日志：登录的频道列表封面全空）：
        //   原来 `downloadMedia(thumb, {})` 传的是**裸 PhotoSize / VideoSize** ——
        //   它们没有 accessHash / fileReference，gramjs 拿不到文件引用 ⇒ 必然失败
        //   → 列表封面 404 一片灰。缩略图必须走 Telegram 的**官方路径**：
        //   `upload.GetFile` + `InputDocumentFileLocation`（thumbSize 用缩略图 type）。
        let buf = null;
        // 内联缩略图（CachedSize / Progressive / Stripped）自带字节，零 RPC 直接返回
        const inline = thumb &&
            (thumb instanceof Api.PhotoCachedSize ||
             thumb instanceof Api.PhotoSizeProgressive ||
             thumb instanceof Api.PhotoStrippedSize) &&
            thumb.bytes && thumb.bytes.length;
        if (inline) {
            buf = Buffer.from(thumb.bytes);
        } else if (doc) {
            try {
                const loc = new Api.InputDocumentFileLocation({
                    id: doc.id,
                    accessHash: doc.accessHash,
                    fileReference: doc.fileReference,
                    thumbSize: String(thumb.type || 'm'),
                });
                // 文件可能存放在别的机房（dcId 不同）⇒ 必须指定 dcId，
                // 否则 upload.GetFile 会回 FILE_MIGRATE_X（invoke 不会自动换机房）
                const r = await c2.invoke(new Api.upload.GetFile({
                    location: loc,
                    offset: 0,
                    limit: 1024 * 1024,
                }), doc.dcId || undefined);
                buf = Buffer.from(r.bytes || []);
            } catch (e2) {
                // 引用过期 / 缩略图不存在 → 给 404，App 显示占位图
                logErr('thumb.GetFile', e2);
                res.writeHead(404); res.end(); return;
            }
        }
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
