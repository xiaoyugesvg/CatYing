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
import * as cheerioNs from 'cheerio';
import CryptoJS from 'crypto-js';
import dayjs from 'dayjs';
import bigInt from 'big-integer';
import * as pako from 'pako';
import iconv from 'iconv-lite';

const cheerio = cheerioNs.default ?? cheerioNs;

/**
 * 允许 MusicFree 插件 require 的模块（白名单）。
 *
 * ── 2026-10-21 扩容（第一阶段：插件运行时补全）────────────────
 * 原来只有 axios / he ⇒ 用 `require('cheerio')` 解析 HTML 的插件会直接
 * 抛「脚本不允许 require('cheerio')」，只能被下架（见 Dart 侧
 * `BuiltinSourcesService._blockedNames` 的历史注释）。
 *
 * 现在按 MusicFree 生态的常用模块补齐 —— **全部是项目里已有的真包**，
 * 不新增依赖；`fs` / `child_process` / `process` / `vm` 依然拒绝：
 *   · cheerio       —— HTML 解析（相声评书 / 172Mix / 电音阁 等 6 个源）
 *   · crypto-js     —— MD5 / AES（大量站点的签名参数）
 *   · dayjs         —— 日期（榜单、播放量筛选）
 *   · big-integer   —— QQ 系 `songmid` 转换
 *   · pako          —— zlib/gzip 响应解压
 *   · iconv-lite    —— GBK 页面解码（老站点）
 */
export const MUSICFREE_MODULES = {
    axios,
    he: { decode: decodeHTML, decodeHTML },
    cheerio,
    'crypto-js': CryptoJS,
    cryptoJs: CryptoJS,
    dayjs,
    'big-integer': bigInt,
    bigInt,
    pako,
    'iconv-lite': iconv,
    iconv,
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
export async function loadMusicFreePlugin(script, loadScript, variables) {
    const loaded = await loadScript(script, {
        modules: MUSICFREE_MODULES,
        // 2026-10-21 第三期：插件变量 → sandbox.env.getUserVariables()
        variables: variables && typeof variables === 'object' ? variables : {},
    });
    if (!loaded.ok) {
        return { ok: false, error: loaded.error };
    }
    // ⚠️ loadScript 会把 module.exports 里的函数平铺进 handlers，
    // 但 MusicFree 插件还需要**非函数字段**（platform / supportedSearchType /
    // hints / userVariables），所以这里把原始导出也带出去。
    const actions = loaded.actions || [];
    return {
        ok: true,
        actions,
        handlers: loaded.handlers,
        exports: (loaded.handlers && loaded.handlers.__exports) || null,
        loaded,
    };
}

/**
 * 取插件声明的**用户变量**（`userVariables: [{key,name,hint}]`）。
 *
 * 这是「登录变量」页要渲染的字段 —— 例如 B 站插件的 `biliCookie`、
 * Apple Music 的 `appleMediaUserToken`、聚合源的 `hywCardKey`。
 *
 * @param {object|null} exports 插件的原始 module.exports
 * @returns {Array<{key:string,name:string,hint:string}>}
 */
export function pluginUserVariables(exports) {
    const raw = exports && exports.userVariables;
    if (!Array.isArray(raw)) return [];
    const out = [];
    for (const v of raw) {
        if (!v || typeof v !== 'object') continue;
        const key = str(v.key).trim();
        if (!key) continue;
        out.push({
            key,
            name: str(v.name || v.label || key),
            hint: str(v.hint || v.description || ''),
        });
    }
    return out;
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
        // ── 2026-10-21 补齐（第一阶段：插件运行时补全）──────────────
        // 这些是 MusicFree 插件生态里的标准导出，补齐后插件才算一个
        // 完整平台（榜单 / 推荐歌单 / 歌单详情 / 歌手作品），
        // 而不是只能给"某首歌"取播放地址。
        topLists: ['getTopLists'],
        topListDetail: ['getTopListDetail'],
        recommendSheetTags: ['getRecommendSheetTags'],
        recommendSheets: ['getRecommendSheetsByTag'],
        sheetInfo: ['getMusicSheetInfo'],
        artistWorks: ['getArtistWorks'],
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

// ============================================================
// 列表类 action 的归一化（2026-10-21 第一阶段新增）
// ============================================================

/**
 * MusicFree 的通用分页壳。
 *
 * 各插件的返回形态不统一，实测有这几种：
 *   · `{ isEnd, data: [item, …] }`      —— 标准
 *   · `{ isEnd, data: { list: [...] } }`
 *   · `[item, …]`                        —— 早期插件
 */
function unwrapList(raw) {
    if (raw == null) return { arr: [], isEnd: true };
    if (Array.isArray(raw)) return { arr: raw, isEnd: false };
    if (typeof raw === 'object') {
        if (Array.isArray(raw.data)) {
            return { arr: raw.data, isEnd: raw.isEnd === true };
        }
        if (raw.data && Array.isArray(raw.data.list)) {
            return {
                arr: raw.data.list,
                isEnd: raw.isEnd === true || raw.data.isEnd === true,
            };
        }
        if (Array.isArray(raw.list)) {
            return { arr: raw.list, isEnd: raw.isEnd === true };
        }
    }
    return { arr: [], isEnd: true };
}

/** 单条音乐项 → 本 App 的字段名（与 normalizeSearchResult 同语义） */
export function mapMusicItem(it) {
    if (!it || typeof it !== 'object') return null;
    const id = it.id != null ? String(it.id) : '';
    if (!id) return null;
    return {
        id,
        // 插件取址常读 songmid（QQ 系），保留
        songmid: str(it.songmid || it.mid || id),
        name: str(it.title || it.name || it.songName),
        artist: str(it.artist || it.artists || it.singer),
        artists: str(it.artist || it.artists || it.singer),
        album: str(it.album || it.albumName),
        albumId: str(it.albumId || ''),
        cover: str(it.artwork || it.coverUrl || it.cover || it.picUrl),
        duration: Number(it.duration) || 0,
        fee: 0,
        // `_src` 必须原样带出（酷狗等插件只从它取源，见 normalizeSearchResult）
        ...(it._src && typeof it._src === 'object' ? { _src: it._src } : {}),
    };
}

/** 单条歌单 / 专辑项归一化 */
function mapSheetItem(it) {
    if (!it || typeof it !== 'object') return null;
    const id = it.id != null ? String(it.id) : '';
    if (!id) return null;
    return {
        id,
        name: str(it.title || it.name),
        cover: str(it.artwork || it.coverImg || it.cover || it.picUrl),
        description: str(it.description || it.desc),
        worksNum: Number(it.worksNum || it.worksNumber || it.trackCount) || 0,
        playCount: Number(it.playCount) || 0,
        artist: str(it.artist || it.artists || it.singer),
        date: str(it.date || ''),
        // ── 🔴 `_raw` 必须原样带出（2026-10-21 修 "未知榜单: undefined"）──
        //
        // 插件详情接口 `getTopListDetail(topListItem)` / `getMusicSheetInfo(
        // sheetItem)` 读的是**它自己那套字段**（例如酷狗插件要 `topId`、
        // 有的要 `_src`）。我们归一化后只保留 id/name/cover ⇒ 回传过去
        // 插件认不出来，直接报「未知榜单: undefined」。
        // 所以把原始对象随条目一起带给 Dart，点进详情时**原样回传**。
        _raw: it,
    };
}

/**
 * `getTopLists()` —— 榜单分组。
 * MusicFree 形状：`[{ title: '平台榜', data: [{id, title, coverImg, …}] }]`
 */
export function normalizeTopLists(raw) {
    const { arr } = unwrapList(raw);
    const out = [];
    for (const g of arr) {
        if (!g || typeof g !== 'object') continue;
        const items = Array.isArray(g.data) ? g.data : [];
        out.push({
            name: str(g.title || g.name),
            list: items.map(mapSheetItem).filter(Boolean),
        });
    }
    // 没有分组壳、直接给一组榜单的插件：兜一层
    if (out.length === 0) {
        const direct = arr.map(mapSheetItem).filter(Boolean);
        if (direct.length) out.push({ name: '榜单', list: direct });
    }
    return { ok: true, list: out };
}

/**
 * `getRecommendSheetTags()` —— 推荐歌单的标签分组。
 * 形状：`{ data: [{ title: '语种', data: ['华语', …] }] }`
 */
export function normalizeSheetTags(raw) {
    // 🔴 2026-10-21：必须同时读 `pinned`。
    //   MusicFree 规范里 getRecommendSheetTags 返回
    //     { data: [{ title, data: [tag] }], pinned: [tag] }
    //   汽水插件把**全部**标签放在 pinned 里、data 恒为空
    //   ⇒ 只读 data 时这个源的「推荐歌单」整块消失（用户看到的空页面）。
    //
    //   tag 有两种形态：
    //     · 字符串（网易/酷狗等大多数插件）—— 直接把字符串交给 getRecommendSheetsByTag
    //     · 对象 { id, title }（汽水：id 是频道号）—— 必须原样回传对象，
    //       转成 String 后插件拿不到 id，会请求到空列表
    //   ⇒ 这里保留 `value`（原始形态），Dart 侧只负责显示 `title`+原样带回。
    const out = [];
    const seen = new Set();
    const collect = (name, items) => {
        const tags = [];
        for (const t of Array.isArray(items) ? items : []) {
            let title = '';
            let value = t;
            if (typeof t === 'string') {
                title = t.trim();
                value = t;
            } else if (t && typeof t === 'object') {
                title = str(t.title || t.name);
                value = t;
            }
            if (!title || seen.has(title)) continue;
            seen.add(title);
            tags.push({ title, value });
        }
        if (tags.length) out.push({ name: str(name) || '标签', tags });
    };

    if (Array.isArray(raw)) {
        for (const g of raw) {
            if (!g || typeof g !== 'object') continue;
            collect(g.title || g.name, g.data);
        }
        return { ok: true, list: out };
    }
    if (raw && typeof raw === 'object') {
        collect('推荐', raw.pinned);
        const groups = Array.isArray(raw.data)
            ? raw.data
            : Array.isArray(raw.list)
              ? raw.list
              : [];
        for (const g of groups) {
            if (!g || typeof g !== 'object') continue;
            collect(g.title || g.name, g.data);
        }
    }
    return { ok: true, list: out };
}

/**
 * `getRecommendSheetsByTag(tag, page)` —— 某个标签下的推荐歌单。
 */
export function normalizeSheets(raw) {
    const { arr, isEnd } = unwrapList(raw);
    const list = arr.map(mapSheetItem).filter(Boolean);
    // 有的插件用 `hasMore` 表示还有下一页（汽水），不读它就会一直显示「加载更多」
    const hasMore =
        raw && typeof raw === 'object' && !Array.isArray(raw)
            ? raw.hasMore !== undefined
                ? raw.hasMore
                : raw.data && typeof raw.data === 'object'
                  ? raw.data.hasMore
                  : undefined
            : undefined;
    return {
        ok: true,
        list,
        isEnd: isEnd || list.length === 0 || hasMore === false,
    };
}

/**
 * `getMusicSheetInfo(sheetItem, page)` —— 歌单详情（含歌曲）。
 * 形状：`{ isEnd, sheetInfo: {...}, musicList: [musicItem] }`
 * 少数插件把两者塞在 `data` 里。
 */
export function normalizeSheetInfo(raw) {
    if (raw == null) return { ok: true, sheet: null, list: [], isEnd: true };
    const body = raw && typeof raw === 'object' && raw.data ? raw.data : raw;
    const sheet =
        body && typeof body === 'object'
            ? mapSheetItem(body.sheetInfo || body.info || body.sheet || body)
            : null;
    const musicList = Array.isArray(body && body.musicList)
        ? body.musicList
        : Array.isArray(body && body.data)
          ? body.data
          : [];
    const list = musicList.map(mapMusicItem).filter(Boolean);
    return {
        ok: true,
        sheet,
        list,
        isEnd: (body && body.isEnd === true) || list.length === 0,
    };
}

/**
 * `getTopListDetail(topListItem)` —— 榜单详情（歌曲列表）。
 *
 * ⚠️ 实测各插件返回形状不同（2026-10-21 修"榜单点进去 0 首"）：
 *   · 酷狗插件：`{ isEnd, musicList: [...], topListItem: {...} }`
 *   · 其它插件：`{ isEnd, data: [...] }` / 裸数组
 * 原来的 `normalizeSearchResult` 只认 `data` ⇒ 酷狗榜单全空 ✗。
 */
export function normalizeTopListDetail(raw) {
    if (raw == null) return { ok: true, list: [], isEnd: true };
    let arr = null;
    if (Array.isArray(raw)) {
        arr = raw;
    } else if (typeof raw === 'object') {
        if (Array.isArray(raw.musicList)) arr = raw.musicList;
        else if (raw.data && Array.isArray(raw.data.musicList)) arr = raw.data.musicList;
        else if (Array.isArray(raw.data)) arr = raw.data;
        else if (Array.isArray(raw.list)) arr = raw.list;
    }
    const list = (arr || []).map(mapMusicItem).filter(Boolean);
    return {
        ok: true,
        list,
        isEnd: (raw && raw.isEnd === true) || list.length === 0,
    };
}

/**
 * `search(query, page, type)` 的**分类**归一化（2026-10-21 补歌手/专辑）。
 *
 * MusicFree 的 type：'music' | 'album' | 'sheet' | 'artist'
 *   · music  —— 走原来的 normalizeSearchResult（歌曲）
 *   · artist —— `{id, name, avatar}`
 *   · album  —— `{id, title/name, artwork/cover, artist, worksNum}`
 *   · sheet  —— 歌单，复用 mapSheetItem
 *
 * ⚠️ 歌手/专辑的 id 也可能是**字符串**，Dart 侧会把它原样保留在原始 Map 里，
 * 点进详情时再回传给插件（见 `_raw` 的说明）—— 所以这里不强行转数字。
 */
export function normalizePluginSearch(raw, type = 'music') {
    if (!type || type === 'music') return normalizeSearchResult(raw);
    const { arr, isEnd } = unwrapList(raw);
    const list = [];
    for (const it of arr) {
        if (!it || typeof it !== 'object') continue;
        const id = it.id != null ? String(it.id) : '';
        if (!id) continue;
        if (type === 'artist') {
            list.push({
                id,
                name: str(it.name || it.title || it.artist),
                avatar: str(it.avatar || it.artwork || it.cover || it.picUrl),
                raw: it,
            });
        } else if (type === 'album') {
            list.push({
                ...mapSheetItem(it),
                raw: it,
            });
        } else {
            // sheet / 其它：按歌单条目给
            list.push({ ...mapSheetItem(it), raw: it });
        }
    }
    return { ok: true, list, isEnd: isEnd || list.length === 0 };
}

/**
 * `getAlbumInfo(albumItem)` —— 专辑详情（含曲目）。
 *
 * 插件返回形状：`{ isEnd, albumItem: {...}, musicList: [...] }`
 * 也可能只给 `{ data: [...] }`。
 */
export function normalizeAlbumInfo(raw) {
    if (raw == null) return { ok: true, album: null, list: [], isEnd: true };
    const body = raw && typeof raw === 'object' && raw.data ? raw.data : raw;
    const album =
        body && typeof body === 'object'
            ? mapSheetItem(body.albumItem || body.album || body)
            : null;
    const musicList = Array.isArray(body && body.musicList)
        ? body.musicList
        : Array.isArray(body && body.data)
          ? body.data
          : [];
    const list = musicList.map(mapMusicItem).filter(Boolean);
    return {
        ok: true,
        album,
        list,
        isEnd: (body && body.isEnd === true) || list.length === 0,
    };
}

/**
 * `getArtistWorks(artistItem, page, type)` —— 歌手作品。
 * type = 'music' → 单曲列表；'album' → 专辑列表。
 */
export function normalizeArtistWorks(raw, type = 'music') {
    const { arr, isEnd } = unwrapList(raw);
    const list =
        type === 'album'
            ? arr.map(mapSheetItem).filter(Boolean)
            : arr.map(mapMusicItem).filter(Boolean);
    return { ok: true, list, isEnd: isEnd || list.length === 0 };
}

/**
 * `getMusicInfo(musicItem)` —— 补充元信息（封面 / 时长 / 专辑）。
 * 返回形状通常是**单条 musicItem**，也可能是 `{ data: musicItem }`。
 */
export function normalizeMusicInfo(raw) {
    const body = raw && typeof raw === 'object' && raw.data ? raw.data : raw;
    const it = mapMusicItem(body);
    return { ok: true, item: it };
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
