/**
 * 第三方音源解析服务
 *
 * ── 这一层解决什么 ────────────────────────────────────────────
 * 用户导入的音源分两种（见 `lib/music/models/third_party_source.dart`）：
 *
 *   · **模板法** `kind: keyword`
 *     把歌名/歌手/ID 填进模板 URL 的占位符，请求后按 `urlPath`
 *     从响应 JSON 里取出播放地址。实现简单、可读，用户能自己看懂。
 *
 *   · **脚本法** `kind: script`
 *     用户导入一份 LX 脚本（JS），由它自己完成请求+解密+解析。
 *     执行交给 `lx_engine.js`（沙箱 + 8s 超时）。
 *
 * ── 为什么放 Node 侧 ─────────────────────────────────────────
 * 1. 脚本只能在 Node 里跑（沙箱用 `vm`）。
 * 2. 模板法虽然 Dart 也能做，但放这里能**统一错误处理与超时**，
 *    也避免 Dart 侧再写一套 HTTP 头管理。
 * 3. 与项目既有做法一致（音乐/影视/书源都走 Node）。
 */

import axios from 'axios';
import { loadScript, runAction } from './lx_engine.js';

/** 模板法请求超时 */
const TEMPLATE_TIMEOUT_MS = 12000;

/** 播放地址常见的字段名（`urlPath` 没命中时按顺序兜底找） */
const URL_KEYS = ['url', 'src', 'play_url', 'playUrl', 'link', 'location', 'data'];

/** 把模板里的占位符替换成真实值 */
function fillTemplate(template, song, quality) {
    const name = song && song.name ? String(song.name) : '';
    const artist = song && song.artists ? String(song.artists) : '';
    const id = song && song.id != null ? String(song.id) : '';
    const album = song && song.album ? String(song.album) : '';
    return String(template)
        // 支持 {name} / ${name} / {{name}} 三种写法（用户收集来的模板不统一）
        .replace(/\$?\{+name\}+/g, encodeURIComponent(name))
        .replace(/\$?\{+artist\}+/g, encodeURIComponent(artist))
        .replace(/\$?\{+singer\}+/g, encodeURIComponent(artist))
        .replace(/\$?\{+id\}+/g, encodeURIComponent(id))
        .replace(/\$?\{+album\}+/g, encodeURIComponent(album))
        .replace(/\$?\{+quality\}+/g, encodeURIComponent(String(quality || '320k')));
}

/** 按 'data.url' / 'result.playUrl' 这样的路径取值 */
function pickByPath(obj, path) {
    if (!obj || !path) return undefined;
    const parts = String(path).split('.').filter(Boolean);
    let cur = obj;
    for (const p of parts) {
        if (cur == null) return undefined;
        // 支持数组下标：data[0].url 或 data.0.url
        const m = /^(\w+)\[(\d+)\]$/.exec(p);
        if (m) {
            cur = cur[m[1]];
            if (Array.isArray(cur)) cur = cur[parseInt(m[2], 10)];
        } else {
            cur = cur[p];
        }
    }
    return cur;
}

/** 递归找第一个看起来像播放地址的字符串 */
function findUrlDeep(obj, depth = 0) {
    if (depth > 6 || obj == null) return undefined;
    if (typeof obj === 'string') {
        return /^https?:\/\//i.test(obj) ? obj : undefined;
    }
    if (Array.isArray(obj)) {
        for (const it of obj) {
            const r = findUrlDeep(it, depth + 1);
            if (r) return r;
        }
        return undefined;
    }
    if (typeof obj === 'object') {
        // 先按常见字段名找
        for (const k of URL_KEYS) {
            const v = obj[k];
            if (typeof v === 'string' && /^https?:\/\//i.test(v)) return v;
        }
        for (const k of Object.keys(obj)) {
            const r = findUrlDeep(obj[k], depth + 1);
            if (r) return r;
        }
    }
    return undefined;
}

/**
 * 模板法解析播放地址。
 *
 * @param source  ThirdPartySource（JSON）
 * @param song    { id, name, artists, album }
 * @returns {Promise<{ok:boolean, url?:string, error?:string, tried?:string}>}
 */
async function resolveByTemplate(source, song) {
    const template = String(source.template || '').trim();
    if (!template) {
        return { ok: false, error: '音源没有配置模板 URL' };
    }

    const quality = source.quality || '320k';
    const url = fillTemplate(template, song, quality);
    const headers = Object.assign(
        {
            'User-Agent':
                'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
        },
        source.headers || {},
    );
    // quality 是元数据，不该当请求头发出去
    delete headers.quality;
    delete headers.qualities;

    try {
        const res = await axios.get(url, {
            headers,
            timeout: TEMPLATE_TIMEOUT_MS,
            responseType: 'text',
            transformResponse: [(d) => d],
            validateStatus: () => true,
        });

        if (res.status < 200 || res.status >= 300) {
            return { ok: false, error: `音源返回 HTTP ${res.status}`, tried: url };
        }

        const text = typeof res.data === 'string' ? res.data : JSON.stringify(res.data);
        let parsed;
        try {
            parsed = JSON.parse(text);
        } catch (_) {
            // 不是 JSON：有些源直接返回地址纯文本
            const t = text.trim();
            if (/^https?:\/\//i.test(t)) return { ok: true, url: t, tried: url };
            return { ok: false, error: '音源返回的内容不是 JSON，也不像播放地址', tried: url };
        }

        // 1) 优先按用户配的 urlPath 取
        let found = pickByPath(parsed, source.urlPath);
        // 2) 没命中就在常见字段里找
        if (typeof found !== 'string' || !/^https?:\/\//i.test(found)) {
            for (const k of URL_KEYS) {
                const v = pickByPath(parsed, k);
                if (typeof v === 'string' && /^https?:\/\//i.test(v)) {
                    found = v;
                    break;
                }
            }
        }
        // 3) 还找不到就深度搜一个 http(s) 地址
        //
        // ⚠️ 这一步本质是"猜"：音源响应里通常还有封面 / 头像 / 分享页 /
        // 试听片段，深度搜到的**第一个** http 串很可能根本不是音频 ✗
        // 原来直接把它当成功返回 → 上层看到 `ok && url 非空` 就**停止尝试
        // 下一个音源** → 用户看到的是"播放器报错"，而不是"这个源没解析出音频" ✗
        // 所以这里必须做**形状校验**：不像音频就如实返回失败并回显搜到的东西。
        if (typeof found !== 'string' || !/^https?:\/\//i.test(found)) {
            const guess = findUrlDeep(parsed);
            if (typeof guess === 'string' &&
                /^https?:\/\//i.test(guess) &&
                looksAudio(guess)) {
                found = guess;
            } else {
                return {
                    ok: false,
                    error: guess
                        ? `响应里没找到音频地址（深度搜到的 ${String(guess).slice(0, 60)} 不像音频）`
                        : '在响应里没找到播放地址（检查取值路径）',
                    tried: url,
                };
            }
        }

        if (typeof found !== 'string' || !/^https?:\/\//i.test(found)) {
            return { ok: false, error: '在响应里没找到播放地址（检查取值路径）', tried: url };
        }
        return { ok: true, url: found, tried: url };
    } catch (e) {
        const msg =
            e && e.code === 'ECONNABORTED' ? '音源请求超时' : (e && e.message) || String(e);
        return { ok: false, error: msg, tried: url };
    }
}

/**
 * 这个 URL 是否"像音频直链"？（给模板法的深度搜索兜底做形状校验）
 *
 * ⚠️ 只看 **pathname**，不看主机名 —— 否则网易图床
 * `p1.music.126.net/xx.jpg` 会因为主机名里的 `music` 被误判成音频
 *（我第一版就是这么写的，被 `scripts/verify-resolver-audio.mjs` 当场抓出来 ✗）。
 * 导出出来就是为了让那个脚本能直接测真函数，而不是"镜像一份逻辑"。
 */
export function looksAudio(v) {
    let path;
    try {
        path = new URL(String(v)).pathname.toLowerCase();
    } catch (_) {
        path = String(v || '').toLowerCase();
    }
    // 图片扩展名 → 直接否（封面/头像最常见的形态）
    if (/\.(jpg|jpeg|png|webp|gif|bmp|ico|svg)$/.test(path)) return false;
    // 明确的音频 / HLS / 分片扩展名 → 收
    if (/\.(mp3|m4a|aac|flac|wav|ogg|opus|m3u8|mp4|ts)$/.test(path)) return true;
    // 路径里带音频语义（如 `/getPlayUrl`、`/audio/xxx`）→ 收
    return /(audio|play|song|music|stream)/.test(path);
}

/**
 * 脚本法解析播放地址。
 *
 * ── 🔴 解析入口链（移植自 Beans 的 `LXScriptSourceRunner.invokeRequest`）──
 *
 * **关键修正**：LX 音源脚本最常见的写法是注册 **`request`** 事件
 * （`lx.on('request', ...)`），而不是 `musicUrl`。
 * 本引擎原来**只认 `handlers['musicUrl']`** → 看到只注册了 `request` 的脚本
 * 就报「脚本未实现 musicUrl（它提供：request）」——
 * **那是把最常见的合法写法误判成不合法**（用户实测就是这个问题）。
 *
 * Beans 的判定顺序（照抄）：
 *   1. `handlers['request']`            → 直接调它，payload 里带 `action`
 *   2. `module.exports.musicUrl`        → `musicUrl(source, musicInfo, type)`
 *   3. `module.exports.getMusicUrl`     → `getMusicUrl(source, id, type)`
 *   4. 都没有 → 才报"没有可用的音乐地址解析入口"
 *
 * ── payload 结构（照 Beans，比原来丰富得多）──────────────────────
 *   {
 *     action: 'musicUrl',
 *     source: 'wy' | 'tx' | 'kg',       ← 平台码，LX 脚本靠它分派
 *     info: { type: '320k', musicInfo: {…} },
 *     _types: {}, meta: {},             ← LX 脚本会读这两个，不能省
 *     …musicInfo 的字段也平铺一份（很多脚本直接读 payload.id / payload.name）
 *   }
 *
 * 参数 { musicInfo: { id, name, singer }, quality } 的**旧结构保留**，
 * 因为已按那个结构写的脚本不能弄坏（两者同时在 payload 里）。
 */
async function resolveByScript(source, song, action = 'musicUrl') {
    const script = String(source.script || '');
    if (!script.trim()) {
        return { ok: false, error: '音源没有脚本内容' };
    }

    const loaded = await loadScript(script);
    if (!loaded.ok) {
        return { ok: false, error: loaded.error };
    }

    const handlers = loaded.handlers || {};
    const actions = loaded.actions || [];
    if (actions.length === 0) {
        return { ok: false, error: '脚本没有注册任何 action（需用 lx.on 或 module.exports）' };
    }

    // ── 选解析入口（顺序照 Beans）────────────────────────────────
    // 'request' 排第一：它是 LX 脚本最通用的入口，且 payload 里的
    // `action: 'musicUrl'` 已经告诉脚本要做什么。
    let entry = null;
    if (typeof handlers.request === 'function') {
        entry = { kind: 'request', fn: handlers.request };
    } else if (typeof handlers[action] === 'function') {
        entry = { kind: action, fn: handlers[action] };
    } else if (typeof handlers.getMusicUrl === 'function') {
        entry = { kind: 'getMusicUrl', fn: handlers.getMusicUrl };
    }

    if (!entry) {
        return {
            ok: false,
            error:
                `脚本没有可用的音乐地址解析入口（它提供：${actions.join(', ')}）；` +
                `需要 lx.on('request', …)（推荐）或 lx.on('musicUrl', …) 或 module.exports = { musicUrl }`,
        };
    }

    const provider = providerCodeOf(song && song.source);
    const quality = (source && source.quality) || '320k';
    const id = song && song.id != null ? String(song.id) : '';
    const name = song && song.name ? String(song.name) : '';
    const singers = song && song.artists ? String(song.artists) : '';
    const album = song && song.album ? String(song.album) : '';

    const musicInfo = {
        id,
        songId: id,
        musicId: id,
        name,
        songName: name,
        singer: singers,
        artist: singers,
        artists: singers ? singers.split(/[、/,&]/).map((s) => s.trim()).filter(Boolean) : [],
        album,
        albumName: album,
        source: provider,
    };

    // 旧结构（已按 {musicInfo, quality} 写的脚本靠它）
    // + 新结构（Beans / LX 通用写法）
    const payload = Object.assign({}, musicInfo, {
        action: action,
        source: provider,
        quality,
        musicInfo,
        info: { type: quality, musicInfo },
        _types: {},
        meta: {},
    });

    const r = await runAction({ [entry.kind]: entry.fn }, entry.kind, payload);
    if (!r.ok) {
        return { ok: false, error: r.error };
    }

    const url = extractPlayableUrl(r.result);
    if (!url) {
        return {
            ok: false,
            error: '脚本执行成功，但没从返回值里找到播放地址（支持 url/musicUrl/data.url/result.url 等 20+ 种字段）',
        };
    }
    return { ok: true, url };
}

/** 平台码：网易 wy / QQ tx / 酷狗 kg（LX 脚本按这个分派） */
function providerCodeOf(songSource) {
    const s = String(songSource || '').toLowerCase();
    if (s.includes('qq') || s === 'tx') return 'tx';
    if (s.includes('kugou') || s === 'kg') return 'kg';
    if (s.includes('netease') || s === 'wy' || s === '163') return 'wy';
    return s || 'wy';
}

/**
 * 从脚本返回值里挖出播放地址。
 *
 * 移植自 Beans 的 `extractURLString`：它试了 **26 条字段路径**，
 * 而本引擎原来只有 `url / src / play_url` 三条 ——
 * 很多脚本返回 `{ data: { musicUrl } }` 或 `{ result: { url } }`，
 * 原来会误报"脚本没有返回有效的播放地址"。
 *
 * ⚠️ 只在**明确的载荷容器**（data/result/response/body/payload）里递归，
 * 避免把封面 URL 当成播放地址。
 */
function extractPlayableUrl(raw, depth = 0) {
    if (raw == null || depth > 6) return null;

    if (typeof raw === 'string') {
        const s = raw.trim();
        if (/^https?:\/\//i.test(s)) return s;
        if (s.startsWith('//')) return 'https:' + s;
        // 脚本有时返回 JSON 字符串
        if (s.startsWith('{') || s.startsWith('[')) {
            try {
                return extractPlayableUrl(JSON.parse(s), depth + 1);
            } catch (_) {
                return null;
            }
        }
        return null;
    }

    if (Array.isArray(raw)) {
        for (const item of raw) {
            const u = extractPlayableUrl(item, depth + 1);
            if (u) return u;
        }
        return null;
    }

    if (typeof raw === 'object') {
        const paths = [
            'url', 'musicUrl', 'musicurl', 'music', 'play_url', 'playUrl', 'src',
            'audioUrl', 'audio_url', 'link', 'purl',
            'data.url', 'data.musicUrl', 'data.musicurl', 'data.music',
            'data.play_url', 'data.playUrl', 'data.src', 'data.audioUrl',
            'data.audio_url', 'data.link', 'data.purl',
            'result.url', 'result.musicUrl', 'result.musicurl', 'result.music',
            'result.play_url', 'result.playUrl', 'result.src', 'result.audioUrl',
            'result.link', 'result.purl',
        ];
        for (const p of paths) {
            const v = pickByPath(raw, p);
            const u = extractPlayableUrl(v, depth + 1);
            if (u) return u;
        }
        // 只在这几个"载荷容器"里继续找，避免误取封面
        for (const k of ['data', 'result', 'response', 'body', 'payload', 'info']) {
            if (raw[k] !== undefined) {
                const u = extractPlayableUrl(raw[k], depth + 1);
                if (u) return u;
            }
        }
    }
    return null;
}

/**
 * 统一的音源解析入口（先脚本、后模板，按 kind 分派）。
 *
 * @returns {Promise<{ok, url?, error?, kind?}>}
 */
async function resolveSource(source, song) {
    if (!source || typeof source !== 'object') {
        return { ok: false, error: '音源数据无效' };
    }
    if (source.enabled === false) {
        return { ok: false, error: '该音源已停用' };
    }
    const kind = source.kind === 'script' || source.script ? 'script' : 'keyword';
    const r =
        kind === 'script'
            ? await resolveByScript(source, song)
            : await resolveByTemplate(source, song);
    return Object.assign({ kind }, r);
}

export { resolveSource, resolveByTemplate, resolveByScript, fillTemplate, pickByPath };
