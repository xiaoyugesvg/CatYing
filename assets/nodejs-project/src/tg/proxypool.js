// 免费代理池（内置源 + 自动测速）
// ============================================================
// 为什么需要：国内直连 `t.me` / `cdn*.telesco.pe` 基本不通，
//   公开频道的"列表能出来但播放一直转圈 / 解析失败"就是这个原因。
//   这里内置一份公开的 socks5 列表，测速后挑最快的给：
//     · 抓 t.me 网页（public.js）
//     · 中转播放（/tg/pubstream、/tg/pubimg）
//     · MTProto 登录（service.js 的 proxy，由 Dart 侧 tgConfig 传同一份）
//
// 列表源（用户 2026-10-25 指定）：
//   https://gh-proxy.com/raw.githubusercontent.com/watchttvv/free-proxy-list/refs/heads/main/proxy.txt
// 格式：`socks5://ip:port   入库时间：… [家宽] 韩国 首尔`
//   ⚠️ 有些 IP 会被打码成 `219.250.X.130` —— 连不通，直接跳过。
import axios from 'axios';
import { Socks5HttpAgent, Socks5HttpsAgent } from './socks5.js';

export const BUILTIN_PROXY_LIST =
    'https://gh-proxy.com/raw.githubusercontent.com/watchttvv/free-proxy-list/refs/heads/main/proxy.txt';

/** 探活目标：能打开 t.me 的频道预览页，才算真的能用 */
const PROBE_URL = 'https://t.me/s/telegram';

const poolCache = { at: 0, list: [] };
let current = null; // { type, host, port, user, pass, note }
let agentsCache = null;

/** 把一行行文本解析成代理对象（只保留 socks5，去重、跳过打码 IP） */
export function parseProxyList(text) {
    const out = [];
    for (const raw of String(text || '').split(/\r?\n/)) {
        const line = raw.trim();
        if (!line || line.startsWith('#')) continue;
        const m = line.match(
            /^(socks5?|socks4|https?):\/\/(?:([^:@\s]+):([^@\s]+)@)?([\w.-]+):(\d{1,5})/i
        );
        if (!m) continue;
        const scheme = m[1].toLowerCase();
        // gramjs 的 MTProto 代理固定按 socks5 配；http/socks4 混进来只会更乱
        if (scheme !== 'socks5' && scheme !== 'socks') continue;
        const host = m[4];
        const port = parseInt(m[5], 10);
        if (!host || !port) continue;
        // 打码 IP（219.250.X.130 / 94.125.*.115）连不通，跳过
        if (/[xX*]/.test(host)) continue;
        const note = line.replace(m[0], '').replace(/^[\s—\-]+/, '').trim();
        out.push({
            type: 'socks5',
            host,
            port,
            user: m[2] || '',
            pass: m[3] || '',
            note,
        });
    }
    const seen = new Set();
    return out.filter((p) => {
        const k = `${p.host}:${p.port}`;
        if (seen.has(k)) return false;
        seen.add(k);
        return true;
    });
}

async function probeOne(p, timeoutMs) {
    const httpAgent = new Socks5HttpAgent(p);
    const httpsAgent = new Socks5HttpsAgent(p);
    const t0 = Date.now();
    try {
        const r = await axios.get(PROBE_URL, {
            httpAgent,
            httpsAgent,
            proxy: false,
            timeout: timeoutMs,
            maxRedirects: 2,
            validateStatus: () => true,
            // 只要头几 KB：够判断"能通"就行，别把整页拉下来
            headers: { 'User-Agent': 'Mozilla/5.0', Range: 'bytes=0-2048' },
        });
        if (r.status >= 200 && r.status < 400) return Date.now() - t0;
        return -1;
    } catch (_) {
        return -1;
    } finally {
        try { httpAgent.destroy(); } catch (_) {}
        try { httpsAgent.destroy(); } catch (_) {}
    }
}

/** 拉列表 + 并发测速；10 分钟内复用结果（别每次都打一遍） */
export async function refreshPool({ timeoutMs = 10000, concurrency = 8 } = {}) {
    const now = Date.now();
    if (now - poolCache.at < 10 * 60 * 1000 && poolCache.list.length) {
        return poolCache.list;
    }
    const r = await axios.get(BUILTIN_PROXY_LIST, {
        timeout: 20000,
        proxy: false,
        validateStatus: () => true,
        headers: { 'User-Agent': 'Mozilla/5.0' },
    });
    const all = parseProxyList(r.data);
    if (!all.length) throw new Error('代理列表为空或格式不认识');

    const tested = [];
    let i = 0;
    async function worker() {
        while (i < all.length) {
            const p = all[i++];
            const ms = await probeOne(p, timeoutMs);
            if (ms > 0) tested.push({ ...p, ms });
        }
    }
    await Promise.all(
        Array.from({ length: Math.max(1, Math.min(concurrency, all.length)) }, worker)
    );
    tested.sort((a, b) => a.ms - b.ms);
    poolCache.at = Date.now();
    poolCache.list = tested;
    return tested;
}

/** 当前生效的代理（null = 直连） */
export function currentProxy() {
    return current;
}

export function setProxy(p) {
    if (!p || !p.host || !p.port) {
        current = null;
        agentsCache = null;
        return null;
    }
    current = {
        type: 'socks5',
        host: String(p.host),
        port: parseInt(String(p.port), 10) || 1080,
        user: p.user ? String(p.user) : '',
        pass: p.pass ? String(p.pass) : '',
        note: p.note ? String(p.note) : '',
    };
    agentsCache = null;
    return current;
}

function agentsFor(proxy) {
    return {
        httpAgent: new Socks5HttpAgent(proxy),
        httpsAgent: new Socks5HttpsAgent(proxy),
    };
}

/** 给 axios 用的 agent 配置；没配代理就返回 `{ proxy: false }`（禁止走环境变量代理） */
export function agentOptions() {
    if (!current) return { proxy: false };
    if (!agentsCache) agentsCache = agentsFor(current);
    return { ...agentsCache, proxy: false };
}
