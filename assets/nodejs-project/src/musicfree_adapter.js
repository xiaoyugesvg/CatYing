/**
 * MusicFree 插件适配层（**独立于 LX 引擎**）
 *
 * ── 为什么要独立一层（而不是塞进 lx_engine）────────────────────
 * LX 源和 MusicFree 插件是**两种完全不同的脚本形态**：
 *
 *   LX 源：`lx.on('request', ...)` 或 `module.exports = { musicUrl }`
 *          入口是 `musicUrl`；靠 `payload.source`（wy/tx/kg）分派。
 *   而且是**纯脚本**，不需要任何外部模块。
 *
 *   MusicFree 插件：`module.exports = { platform, search, getMediaSource, ... }`
 *          入口是 **`getMediaSource(musicItem, quality)`**；
 *          而且**几乎都 `require('axios')` / `require('he')`**。
 *
 * 两者混进一套入口链会互相干扰（比如 `module.exports.musicUrl` 的探测
 * 会把 MusicFree 插件的 `search` 误当 action）。所以：
 *   · LX 路径 —— `loadScript(script)`（**不注入任何模块**，行为不变）
 *   · MusicFree 路径 —— `loadScript(script, { modules })`（注入白名单）
 *
 * ── 注入的是什么（安全性）──────────────────────────────────────
 * **只注入 axios 和 he**，而且都是项目 node_modules 里已有的真包：
 *   · axios —— HTTP 客户端。⚠️ **这不增加攻击面**：LX 沙箱本来就提供
 *     `lx.request`，脚本想发请求早就能发。这里只是换个 API 名字。
 *   · he —— HTML 实体解码（`he.decode`）；用 `entities` 包实现
 *     （`he` 本身就是 `entities` 的移植版，`decodeHTML` 等价）。
 * `fs` / `child_process` / `process` / `vm` **依然拒绝** —— 见 lx_engine
 * 里 require 的白名单逻辑。
 */

import axios from 'axios';
import { decodeHTML } from 'entities';

/** 允许 MusicFree 插件 require 的模块（白名单，就这两个） */
export const MUSICFREE_MODULES = {
    axios,
    he: { decode: decodeHTML, decodeHTML },
};

/**
 * 判断一份脚本是不是 MusicFree 插件。
 *
 * 判据（够严，不会把 LX 源误判）：
 *   · 有 `platform` 导出（MusicFree 插件的身份标识）
 *   · 且声明了取播放地址的方法
 *
 * ⚠️ 不看 `getMediaSource` 这种"导出名"的静态文本（可能被压缩改名），
 * 而是**真的加载一次**后看 `module.exports` 的形状 —— 见 detectMusicFree。
 */
export function looksLikeMusicFree(script) {
    const s = String(script || '');
    if (!s.trim()) return false;
    // 快速预筛：MusicFree 插件的典型特征（避免对每个 LX 源都跑一次加载）
    const hasPlatform = /platform\s*:/.test(s);
    const hasMediaGetter =
        /getMediaSource|getMusicUrl|getMusicInfo/.test(s);
    const hasAxios = /require\s*\(\s*['"]axios['"]\s*\)/.test(s);
    return hasPlatform && (hasMediaGetter || hasAxios);
}

/**
 * 加载 MusicFree 插件并取出它的导出对象。
 *
 * @returns {{ok:boolean, plugin?:object, error?:string, actions?:string[]}}
 */
export async function loadMusicFreePlugin(script, loadScript) {
    const loaded = await loadScript(script, { modules: MUSICFREE_MODULES });
    if (!loaded.ok) {
        return { ok: false, error: loaded.error };
    }
    // ⚠️ loadScript 会把 module.exports 里的函数平铺进 handlers，
    // 但 MusicFree 插件还需要**非函数字段**（platform / supportedSearchType /
    // hints），所以这里直接读 handlers 里的函数 + 让调用方用 actions 判断。
    const actions = loaded.actions || [];
    return { ok: true, actions, handlers: loaded.handlers, loaded };
}

/**
 * 找 MusicFree 插件的「取播放地址」方法。
 *
 * MusicFree 生态里这个方法名不统一（不同作者/不同年代）：
 *   · `getMediaSource(musicItem, quality)`   —— 最常见（当前 MusicFree 标准）
 *   · `getMusicUrl(musicItem, quality)`      —— 早期版本
 *   · `getMusicInfo(musicItem)`              —— 少数插件
 */
export function pickMediaGetter(handlers) {
    if (!handlers) return null;
    for (const name of ['getMediaSource', 'getMusicUrl', 'getMusicInfo']) {
        if (typeof handlers[name] === 'function') {
            return { name, fn: handlers[name] };
        }
    }
    return null;
}

/**
 * 找 MusicFree 插件的**其它 action**（搜索 / 歌词 / 专辑信息）。
 *
 * ── MusicFree 的标准签名（照它的插件生态）──────────────────────
 *   `search(query, page, type)`   —— type ∈ 'music'|'album'|'sheet'|'artist'
 *   `getLyric(musicItem)`         —— 返回 `{ lyric, tlyric? }` 或字符串
 *   `getAlbumInfo(albumItem)`     —— 返回 `{ coverUrl?, description?, … }`
 *   `getMusicInfo(musicItem)`     —— 补充封面等元信息
 *
 * ⚠️ 这些都是**可选的**：插件只实现自己支持的那几个。
 * 缺了返回 null，由调用方给出"该插件不支持 xxx"的明确提示，
 * 而不是静默失败。
 */
export function pickAction(handlers, action) {
    if (!handlers) return null;
    const map = {
        search: ['search'],
        lyric: ['getLyric', 'getLyricNew'],
        albumInfo: ['getAlbumInfo', 'getAlbumInfoNew'],
        musicInfo: ['getMusicInfo'],
    };
    for (const name of map[action] || []) {
        if (typeof handlers[name] === 'function') {
            return { name, fn: handlers[name] };
        }
    }
    return null;
}

/**
 * 把 MusicFree `search()` 的返回值归一化成统一结构。
 *
 * MusicFree 的 search 返回形态（不同插件/版本）：
 *   · `{ isEnd: false, data: [musicItem, …] }`   —— **当前标准**
 *   · `[musicItem, …]`                            —— 早期
 *   · `{ data: { list: [...] } }`
 *
 * musicItem 字段（照 MusicFree）：
 *   `{ id, title, artist, album, duration(秒), artwork, url? }`
 *
 * ⚠️ 这里把 MusicFree 的字段名映射成**本 App 的字段名**
 *（`title`→`name`、`artist`→`artists`、`artwork`→`cover`），
 * 这样 Dart 侧不用再区分两套模型。
 */
export function normalizeSearchResult(raw) {
    if (raw == null) return { ok: true, list: [], isEnd: true };

    let arr = null;
    let isEnd = false;
    if (Array.isArray(raw)) {
        arr = raw;
    } else if (typeof raw === 'object') {
        if (Array.isArray(raw.data)) {
            arr = raw.data;
            isEnd = raw.isEnd === true;
        } else if (raw.data && Array.isArray(raw.data.list)) {
            arr = raw.data.list;
            isEnd = raw.isEnd === true || raw.data.isEnd === true;
        } else if (Array.isArray(raw.list)) {
            arr = raw.list;
        }
    }
    if (!arr) return { ok: true, list: [], isEnd: true };

    const out = [];
    for (const it of arr) {
        if (!it || typeof it !== 'object') continue;
        const id = it.id != null ? String(it.id) : '';
        if (!id) continue;
        out.push({
            id,
            // ⚠️ `songmid` 也要带出来 —— 很多插件取址读的是它，**不是** `id`。
            // 实测元力音源 v1.2.1：`getMediaSource` 里用的是
            // `musicItem.songmid`。少了它，**自搜回退拿到的候选也没法播**。
            songmid: str(it.songmid || it.mid || id),
            name: str(it.title || it.name || it.songName),
            // ⚠️ 两套字段名都给：Dart 的 `Song.fromJson` 优先读**单数** `artist`
            //（Node 其它接口发的就是单数），这里保持一致的语义。
            artist: str(it.artist || it.artists || it.singer),
            artists: str(it.artist || it.artists || it.singer),
            album: str(it.album || it.albumName),
            cover: str(it.artwork || it.coverUrl || it.cover || it.picUrl),
            // ⚠️ MusicFree 的 duration 是**秒**，本 App 也是秒 → 不换算
            duration: Number(it.duration) || 0,
            fee: 0,
            // ── 🔴 `_src` 必须**原样保留**（修一个"MusicFree 插件全失败"）──
            //
            // 很多插件（如 `kugou-source.plugin`）的取址入口**不是**顶层字段，
            // 而是 `musicItem._src`：
            // ```js
            // var srcMap = musicItem._src || {};      // ← 它只从这取
            // var order  = pickCandidates(srcMap, quality);
            // ```
            // 插件 `search()` 产出的 item 长这样：
            //   `{ id, title, …, _src: { kugou: { hash, hash320, hashSq, hashHires } } }`
            // 我们原来是**手挑字段**重建对象 —— 手挑就意味着**一定会漏**，
            // 而 `_src` 正是被漏掉的那个 → 自搜回退拿到的候选**同样播不了** ✗
            //
            // 所以这里把 `_src` 原样带出来（`source_resolver` 会把它透传给
            // 插件的 `getMediaSource`）。这样"自搜回退"才真的有用。
            ...(it._src && typeof it._src === 'object' ? { _src: it._src } : {}),
        });
    }
    return { ok: true, list: out, isEnd: isEnd || out.length === 0 };
}

/**
 * 把 MusicFree `getLyric()` 的返回值归一化。
 * @returns {{lyric:string, tlyric:string}}
 */
export function normalizeLyric(raw) {
    if (raw == null) return { lyric: '', tlyric: '' };
    if (typeof raw === 'string') return { lyric: raw, tlyric: '' };
    if (typeof raw === 'object') {
        return {
            lyric: str(raw.lyric || raw.rawLrc || raw.lrc),
            tlyric: str(raw.tlyric || raw.translation),
        };
    }
    return { lyric: '', tlyric: '' };
}

function str(v) {
    return v == null ? '' : String(v);
}

/**
 * 把 MusicFree 插件的返回值归一化成播放地址。
 *
 * 插件返回形态很多（实测与社区文档）：
 *   · `'https://...'`                       裸字符串
 *   · `{ url: '...' }`
 *   · `{ url: '...', headers: {...} }`      **要带 headers 才能播**
 *   · `{ data: { url } }`
 *   · `[{ url }, { url }]`                  多音质候选，取第一个可用
 *   · `{ url: '...', quality: '320k' }`
 *
 * @returns {{url:string, headers:Object}|null}
 */
export function normalizeMedia(getterResult) {
    if (getterResult == null) return null;

    if (typeof getterResult === 'string') {
        const s = getterResult.trim();
        if (/^https?:\/\//i.test(s)) return { url: s, headers: {} };
        if (s.startsWith('//')) return { url: 'https:' + s, headers: {} };
        return null;
    }

    if (Array.isArray(getterResult)) {
        for (const item of getterResult) {
            const n = normalizeMedia(item);
            if (n) return n;
        }
        return null;
    }

    if (typeof getterResult === 'object') {
        // headers 可能挂在这一层，也可能挂在 data 里
        const ownHeaders =
            getterResult.headers && typeof getterResult.headers === 'object'
                ? stringifyHeaders(getterResult.headers)
                : {};
        for (const key of ['url', 'musicUrl', 'src', 'play_url', 'playUrl']) {
            const v = getterResult[key];
            if (typeof v === 'string' && /^https?:\/\//i.test(v.trim())) {
                return { url: v.trim(), headers: ownHeaders };
            }
        }
        if (getterResult.data !== undefined) {
            const n = normalizeMedia(getterResult.data);
            if (n) {
                return {
                    url: n.url,
                    headers: Object.keys(ownHeaders).length
                        ? ownHeaders
                        : n.headers,
                };
            }
        }
    }
    return null;
}

/** headers 的值可能是非字符串（插件里常见 number/undefined），统一成字符串 */
function stringifyHeaders(h) {
    const out = {};
    for (const [k, v] of Object.entries(h)) {
        if (v != null) out[String(k)] = String(v);
    }
    return out;
}
