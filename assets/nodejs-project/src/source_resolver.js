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
        if (typeof found !== 'string' || !/^https?:\/\//i.test(found)) {
            found = findUrlDeep(parsed);
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
 * 脚本法解析播放地址。
 *
 * LX 脚本约定的 action 名（Beans 也是这套）：
 *   · musicUrl —— 取播放地址，参数 { musicInfo: { id, name, singer }, quality }
 *     返回 { url } 或 { url, quality }
 *
 * 返回里带 `tried` 便于排错（用户能看到脚本报了什么）。
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

    // 脚本没实现这个 action 时给出**明确的可用清单**，
    // 否则用户只会看到"失败"却不知道脚本支持什么
    if (!loaded.actions || loaded.actions.length === 0) {
        return { ok: false, error: '脚本没有注册任何 action（需用 lx.on 或 module.exports）' };
    }
    if (!loaded.handlers[action]) {
        return {
            ok: false,
            error: `脚本未实现 ${action}（它提供：${loaded.actions.join(', ')}）`,
        };
    }

    const payload = {
        musicInfo: {
            id: song && song.id != null ? String(song.id) : '',
            name: song && song.name ? String(song.name) : '',
            singer: song && song.artists ? String(song.artists) : '',
            album: song && song.album ? String(song.album) : '',
        },
        quality: source.quality || '320k',
    };

    const r = await runAction(loaded.handlers, action, payload);
    if (!r.ok) {
        return { ok: false, error: r.error };
    }

    const out = r.result;
    let url;
    if (typeof out === 'string') {
        url = out;
    } else if (out && typeof out === 'object') {
        url = out.url || out.src || out.play_url || findUrlDeep(out);
    }

    if (typeof url !== 'string' || !/^https?:\/\//i.test(url)) {
        return { ok: false, error: '脚本没有返回有效的播放地址' };
    }
    return { ok: true, url };
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
