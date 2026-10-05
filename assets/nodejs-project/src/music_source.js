/**
 * 音乐数据源（公开接口，无需登录）
 *
 * ── 为什么放在 Node 侧 ────────────────────────────────────────
 * 1. 网易云接口必须带 `Referer: https://music.163.com/` 与特定 UA，
 *    否则会被拒（实测：不带 Referer 拿不到播放地址）。Node 用 axios
 *    设置这些头最可靠，也避免在 Dart 侧再引一套头管理。
 * 2. 所有对外请求集中在这里，方便统一超时/错误处理。
 * 3. 与项目既有做法一致（书源、影视源都走 Node）。
 *
 * ── 能力与限制（用户选的"方案 1：只用公开接口"）────────────────
 *   · 搜索       ✅ 可用（网易云 cloudsearch）
 *   · 播放地址   ⚠️ **只有免费歌能拿到**（fee=8 档）；
 *                VIP/独家版权歌接口返回空 url → 上层要明确提示，
 *                不要静默失败。
 *   · 歌词       ✅ 可用（lyric + 翻译 tlyric）
 *   · 不提供：登录、歌单、收藏、排行榜（那些需要账号）
 *
 * 明确不做：任何账号/加密协议（weapi/eapi）、扫码、Cookie 持久化。
 *
 * ── 多平台（多数据源）─────────────────────────────────────────
 * `handleMusicApi(body)` 现在按 `body.source` 分派：
 *   · 不传 / `'netease'` / `'wy'` → 本文件里的网易云实现（**默认，行为不变**）
 *   · `'kugou'` / `'kg'`        → `kugou_source.js`（第三方库 KuGouMusicApi，MIT）
 *   · `'qq'` / `'tx'`           → `qq_source.js`（协议参考 Beans-Music / wp_MusicApi）
 * 三个平台的返回结构完全一致（见各函数注释与对应 source 文件头）。
 */

import axios from 'axios';
// LX 脚本引擎（沙箱 + 超时，见文件头说明为什么不会像 flutter_tts 那样闪退）
import { loadScript, runAction, engineInfo } from './lx_engine.js';
// 第三方音源解析（模板法 / 脚本法）
import { resolveSource } from './source_resolver.js';
// ── 多平台：酷狗（第三方库 KuGouMusicApi 的 ESM 桥接层）──────────
// 见 `kugou_source.js` 文件头（来源/许可/设备身份 bootstrap）。
// 这里只 import 函数；上游 CJS 代码在桥接层内部用 createRequire 加载。
import * as kugou from './kugou_source.js';
// ── 多平台：喜马拉雅（有声书/播客）──────────────────────────────
// 映射：专辑 → Album，单集 → Song。**播放必须带 UA**（见 ximalaya_source.js）。
import * as ximalaya from './ximalaya_source.js';
// ── 多平台：QQ 音乐（协议参考 Beans-Music / wp_MusicApi 逆向结论）────
// 搜索 client_search_cp（免登录，家庭/移动/数据中心网络均可）；
// 播放 vkey 经 musicu.fcg（VIP 歌返回空，上层按 no_free_source 提示）。
import * as qq from './qq_source.js';

/** 网易云公开接口要求的请求头（缺 Referer 会被拒） */
const NETEASE_HEADERS = {
    'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
    'Referer': 'https://music.163.com/',
    'Cookie': 'appver=8.9.70; os=ios;',
};

/**
 * 把网易云原始 track 对象映射成上层统一结构。
 *
 * 为什么要单独抽出来：网易云不同接口返回的字段名不一致 ——
 * 老接口用 `artists`/`album`/`duration`，新接口用 `ar`/`al`/`dt`。
 * 原有 search 是内联映射的，新加的十来个接口如果各写一遍必然漏字段，
 * 所以统一走这里（字段与 `search` 的输出保持一致）。
 */
function mapTrack(s) {
    if (!s) return null;
    const artists = s.artists || s.ar || [];
    const album = s.album || s.al || {};
    const id = s.id || s.songId;
    if (!id) return null;
    return {
        id: String(id),
        name: s.name || '',
        artist: artists.map((a) => a && a.name).filter(Boolean).join('、'),
        artistIds: artists.map((a) => a && String(a.id)).filter(Boolean),
        album: album.name || '',
        albumId: String(album.id || ''),
        cover: album.picUrl || s.picUrl || '',
        duration: Math.round((s.duration || s.dt || 0) / 1000),
        fee: typeof s.fee === 'number' ? s.fee : -1,
    };
}

const TIMEOUT_MS = 15000;

/** 把 axios 错误转成能看懂的短句（上层直接显示） */
function humanize(e) {
    if (e && e.response) {
        return '接口返回 HTTP ' + e.response.status;
    }
    if (e && e.code === 'ECONNABORTED') {
        return '请求超时';
    }
    return '请求失败：' + ((e && e.message) || String(e));
}

/**
 * 搜索歌曲
 * @returns {Promise<{ok:boolean, list?:Array, total?:number, error?:string}>}
 */
async function search(keyword, limit = 30, offset = 0) {
    const kw = String(keyword || '').trim();
    if (!kw) return { ok: false, error: '请输入关键词' };
    try {
        const r = await axios.get('https://music.163.com/api/cloudsearch/pc', {
            params: {
                s: kw,
                type: 1, // 1=单曲
                limit: Math.min(Math.max(parseInt(limit, 10) || 30, 1), 50),
                offset: Math.max(parseInt(offset, 10) || 0, 0),
            },
            headers: NETEASE_HEADERS,
            timeout: TIMEOUT_MS,
        });
        const songs = (r.data && r.data.result && r.data.result.songs) || [];
        const list = songs.map((s) => {
            const artists = s.artists || s.ar || [];
            const album = s.album || s.al || {};
            return {
                id: String(s.id),
                name: s.name || '',
                // 多歌手用「、」连接，和国内音乐 App 的习惯一致
                artist: artists.map((a) => a.name).filter(Boolean).join('、'),
                artistIds: artists.map((a) => String(a.id)).filter(Boolean),
                album: album.name || '',
                albumId: String(album.id || ''),
                cover: album.picUrl || '',
                // 毫秒 → 秒（上层显示用）
                duration: Math.round((s.duration || s.dt || 0) / 1000),
                // fee 用于给用户预警"这首可能要 VIP"
                fee: typeof s.fee === 'number' ? s.fee : -1,
            };
        });
        return { ok: true, list, total: list.length };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/**
 * 取播放地址
 *
 * ⚠️ 免费歌能拿到 url；VIP/版权受限歌接口会返回 data[0].url = null。
 *    这里**如实把 url 置空返回 ok:true**，让上层显示
 *    「该歌曲无免费音源」而不是报一个看不懂的网络错误。
 */
async function songUrl(id, quality = '320k') {
    const songId = String(id || '').trim();
    if (!songId) return { ok: false, error: '缺少歌曲 id' };

    // br 优先级：无损 > 320k > 192k > 128k（拿不到会自动回落）
    const brMap = { 'hires': 1999000, 'lossless': 999000, '320k': 320000, '192k': 192000, '128k': 128000 };
    const br = brMap[quality] || 320000;

    try {
        const r = await axios.get('https://music.163.com/api/song/enhance/player/url', {
            params: { ids: '[' + songId + ']', br },
            headers: NETEASE_HEADERS,
            timeout: TIMEOUT_MS,
        });
        const d = r.data && Array.isArray(r.data.data) ? r.data.data[0] : null;
        const url = (d && d.url) || '';
        if (!url) {
            return {
                ok: true,
                url: '',
                reason: 'no_free_source',
                message: '该歌曲没有免费音源（可能需要 VIP 或已下架）',
            };
        }
        return {
            ok: true,
            url,
            // 实际拿到的码率（接口会回落，跟请求值可能不同）
            br: (d && d.br) || 0,
            size: (d && d.size) || 0,
            type: (d && d.type) || '',
        };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/**
 * 取歌词（含翻译）
 * @returns {Promise<{ok:boolean, lyric?:string, tlyric?:string, error?:string}>}
 */
async function lyric(id) {
    const songId = String(id || '').trim();
    if (!songId) return { ok: false, error: '缺少歌曲 id' };
    try {
        const r = await axios.get('https://music.163.com/api/song/lyric', {
            params: { id: songId, lv: -1, tv: -1, kv: -1 },
            headers: NETEASE_HEADERS,
            timeout: TIMEOUT_MS,
        });
        return {
            ok: true,
            lyric: (r.data && r.data.lrc && r.data.lrc.lyric) || '',
            tlyric: (r.data && r.data.tlyric && r.data.tlyric.lyric) || '',
        };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/**
 * 统一入口：POST /music/api
 * body: { action: 'search'|'url'|'lyric', keyword?, id?, limit?, offset?, quality? }
 */
/**
 * LX 引擎自检 —— 端到端验证沙箱与超时真的生效。
 *
 * 为什么需要它：LX 脚本是**用户导入的任意 JS**，最坏情况是死循环。
 * Node 与 App 同进程，一旦事件循环被占住，整个 App 卡死（不是闪退，是卡住）。
 * 这个自检用一段"故意死循环"的脚本来证明 timeout 真的能中断它 ——
 * 光看代码不算数，要能实测。
 */
async function lxSelfTest() {
    const out = { info: engineInfo(), cases: [] };

    const run = async (name, script, expectOk) => {
        const t0 = Date.now();
        const r = await loadScript(script);
        const ms = Date.now() - t0;
        const pass = expectOk ? r.ok === true : r.ok === false;
        out.cases.push({
            name,
            pass,
            ms,
            error: r.error || null,
            actions: r.actions || null,
        });
    };

    // 1) 一段正常脚本：用 lx.on 注册
    await run('正常脚本(lx.on)', `
lx.on('musicUrl', async (info) => {
  return { url: 'https://example.com/' + info.musicInfo.id + '.mp3' };
});
`, true);

    // 2) module.exports 写法
    await run('module.exports 写法', `
module.exports = {
  musicUrl: async (info) => ({ url: 'https://x/' + info.musicInfo.id })
};
`, true);

    // 3) **死循环** —— 必须被超时中断，否则整个 App 会卡死
    await run('死循环必须被超时中断', `while (true) {}`, false);

    // 4) 越权访问 fs —— 必须被拒绝
    await run('拒绝 require("fs")', `
const fs = require('fs');
`, false);

    // 5) crypto.md5 可用（很多音源要签名）
    const t0 = Date.now();
    const r5 = await loadScript(`
lx.on('x', () => lx.utils.crypto.md5('abc'));
`);
    let md5ok = false;
    if (r5.ok) {
        const rr = await runAction(r5.handlers, 'x', {});
        md5ok = rr.ok && rr.result === '900150983cd24fb0d6963f7d28e17f72';
    }
    out.cases.push({ name: 'crypto.md5 结果正确', pass: md5ok, ms: Date.now() - t0, error: r5.error || null });

    out.pass = out.cases.filter((c) => c.pass).length;
    out.total = out.cases.length;
    out.allPass = out.pass === out.total;
    return out;
}

/**
 * 用第三方音源解析播放地址。
 *
 * body: { action:'resolveBySource', source:{...}, song:{id,name,artists,album} }
 *
 * Dart 侧负责"从存储里取源、按顺序逐个试"；Node 只做**解析**这一件事。
 * 这样源列表的事实来源只有一个（Dart 的 ThirdPartySourceStore），
 * Node 侧不需要再存一份，避免两边不一致。
 */
async function resolveBySourceAction(source, song) {
    const r = await resolveSource(source, song);
    return r.ok
        ? { ok: true, url: r.url, kind: r.kind }
        : { ok: false, error: r.error, kind: r.kind };
}

/**
 * 平台别名归一化。
 *
 * ⚠️ 为什么要有这个函数（而不是直接在 switch 里比字符串）：
 *   · `source` **可以完全不传** —— 此时必须与改动前**逐字节一致**地走网易云；
 *   · Dart 侧 `MusicApi` 传的是 `SongSource.key`（`'netease'`/`'kugou'`），
 *     但历史/其它调用点可能传 `'wy'`/`'kg'`，这里统一收口。
 * 返回 `'kugou'` 或 `'netease'`（未知值一律回落 netease，保证默认行为不变）。
 */
function normalizeSource(raw) {
    const s = String(raw == null ? '' : raw).trim().toLowerCase();
    if (s === 'kugou' || s === 'kg') return 'kugou';
    if (s === 'ximalaya' || s === 'xmly') return 'ximalaya';
    if (s === 'qq' || s === 'tx') return 'qq';
    return 'netease';
}

/**
 * 酷狗**暂不支持**的接口统一返回。
 * 契约与网易云的失败分支一致（`{ok:false, error}`），上层原样显示 error，
 * 不会"假装成功返回空列表"。
 */
function kugouUnsupported(action) {
    return { ok: false, error: '酷狗暂不支持该接口', action, source: 'kugou' };
}

/**
 * 喜马拉雅的分派（**早返回**，不掺进下面网易云/酷狗的逐条逻辑）。
 *
 * 为什么单独一个函数：喜马拉雅的语义与前两个平台不同 ——
 *   · 搜索返回的是**专辑**（不是单曲）→ 这里映射成 Song 形状，`id` = 专辑 id，
 *     上层点进去再拉专辑单集（`ximalayaAlbum`）。
 *   · 播放地址**随专辑单集列表一起返回**（不需要另外换链），但**必须带 UA**。
 */
async function handleXimalayaAction(action, body) {
    switch (action) {
        case 'search': {
            const r = await ximalaya.ximalayaSearch(body.keyword);
            if (!r.ok) return r;
            // 映射成 Song 形状（`artists` 放主播名），让搜索页能直接渲染；
            // 点进去走 `ximalayaAlbum` 拿单集（见 Dart 侧专辑详情页）。
            const list = (r.list || []).map((a) => ({
                id: a.id,
                name: a.name,
                artist: a.artist || '',
                artistIds: [],
                album: a.name,
                albumId: a.id,
                cover: a.cover,
                duration: 0,
                fee: -1,
                source: 'ximalaya',
                kind: 'album', // 上层据此显示"专辑"并进专辑页
            }));
            return { ok: true, list, total: list.length };
        }
        case 'url':
            return ximalaya.ximalayaUrl(body.id);
        case 'lyric':
            // 有声书没有歌词 —— 明确说，不要静默返回空
            return { ok: false, error: '喜马拉雅是有声书，没有歌词' };
        case 'ximalayaCategories':
            return ximalaya.ximalayaCategories();
        case 'ximalayaCategory':
            return ximalaya.ximalayaCategory(body.categoryId, body.page);
        case 'ximalayaAlbum':
            return ximalaya.ximalayaAlbum(body.id);
        case 'ximalayaSelfTest':
            return ximalaya.ximalayaSelfTest();
        default:
            return {
                ok: false,
                error: '喜马拉雅暂不支持该接口',
                action,
                source: 'ximalaya',
            };
    }
}

async function handleMusicApi(body) {
    const action = String((body && body.action) || '');
    // 默认 netease：不传 source 时下面每条分支都与改动前完全一样
    const source = normalizeSource(body && body.source);
    const isKg = source === 'kugou';
    const isQq = source === 'qq';
    // 喜马拉雅：整条链路独立（语义与"单曲平台"不同），提前返回
    if (source === 'ximalaya') return handleXimalayaAction(action, body);

    // ── 三个"多平台"接口 ────────────────────────────────────
    if (action === 'search') {
        if (isQq) return qq.searchSongs(body.keyword, body.limit, body.offset);
        return isKg
            ? kugou.searchSongs(body.keyword, body.limit, body.offset)
            : search(body.keyword, body.limit, body.offset);
    }
    if (action === 'url') {
        if (isQq) return qq.songUrl(body.id, body.quality);
        return isKg
            ? kugou.songUrl(body.id, body.quality)
            : songUrl(body.id, body.quality);
    }
    if (action === 'lyric') {
        if (isQq) return qq.lyric(body.id);
        return isKg
            ? kugou.lyric(body.id)
            : lyric(body.id);
    }

    // ── 以下接口目前只有网易云实现 ──────────────────────────
    // 传了 kugou 就**明确说"不支持"**，绝不静默回落到网易云
    // （否则用户选了酷狗却看到网易云的内容，是更严重的错）。
    if (isKg) {
        switch (action) {
            case 'topLists':
                return kugou.topLists();
            case 'playlistDetail':
                return kugou.playlistDetail(body.id);
            case 'hotSearch':
                return kugou.hotSearch();
            case 'newSongs':
                return kugou.newSongs(body.limit);
            // ── 酷狗桥接层确实没做的，明确返回不支持 ──
            case 'personalized':
            case 'playlistSquare':
            case 'playlistCatlist':
            case 'comments':
            case 'simiSongs':
            case 'searchArtists':
            case 'searchAlbums':
            case 'artistSongs':
            case 'artistAlbums':
            case 'albumSongs':
            case 'resolveBySource':
                return kugouUnsupported(action);
            default:
                return { ok: false, error: '未知 action: ' + action };
        }
    }

    // ── QQ：热搜走自己实现，其余发现页接口明确不支持（无登录态）──
    if (isQq) {
        switch (action) {
            case 'hotSearch':
                return qq.hotSearch();
            case 'qqSelfTest':
                return qq.selfTest();
            case 'personalized':
            case 'playlistSquare':
            case 'playlistCatlist':
            case 'comments':
            case 'simiSongs':
            case 'searchArtists':
            case 'searchAlbums':
            case 'artistSongs':
            case 'artistAlbums':
            case 'albumSongs':
            case 'resolveBySource':
            case 'topLists':
            case 'playlistDetail':
            case 'newSongs':
                return { ok: false, error: 'QQ 暂不支持该接口（需要登录态）', action, source: 'qq' };
            default:
                return { ok: false, error: '未知 action: ' + action };
        }
    }

    switch (action) {
        case 'search':
            return search(body.keyword, body.limit, body.offset);
        case 'url':
            return songUrl(body.id, body.quality);
        case 'lyric':
            return lyric(body.id);
        // ── 发现页（全部公开接口，无需登录）──────────────
        case 'topLists':
            return topLists();
        case 'playlistDetail':
            return playlistDetail(body.id);
        case 'personalized':
            return personalized(body.limit);
        case 'playlistSquare':
            return playlistSquare(body.cat, body.order, body.limit);
        case 'playlistCatlist':
            return playlistCatlist();
        case 'hotSearch':
            return hotSearch();
        case 'newSongs':
            return newSongs(body.limit);
        case 'comments':
            return comments(body.id, body.limit, body.offset);
        case 'simiSongs':
            return simiSongs(body.id);
        // ── 搜索扩展 / 歌手 / 专辑 ────────────────────────
        case 'searchArtists':
            return searchArtists(body.keyword, body.limit);
        case 'searchAlbums':
            return searchAlbums(body.keyword, body.limit);
        case 'artistSongs':
            return artistSongs(body.id, body.limit);
        case 'artistAlbums':
            return artistAlbums(body.id, body.limit);
        case 'albumSongs':
            return albumSongs(body.id);
        // ── 第三方音源解析（模板法 / 脚本法）─────────────
        case 'resolveBySource':
            return resolveBySourceAction(body.source, body.song);
        // ── LX 引擎自检（沙箱 / 超时 / crypto 是否真的生效）──
        case 'lxSelfTest':
            return lxSelfTest();
        // ── 酷狗桥接层自检（不联网：上游版本 / 依赖 / 模块 / 设备身份）──
        // ⚠️ 放在 netease 分支的 switch 里是**故意的**：
        //    它不依赖 `source`（也不该被 source 影响），任何调用方都能拿到结果。
        case 'kugouSelfTest':
            return kugou.selfTest();
        default:
            return { ok: false, error: '未知 action: ' + action };
    }
}

// ⚠️ 必须用 ESM `export`，不能写 `module.exports`：
// 本项目 package.json 是 type=module，esbuild 会把内部模块编成 ESM，
// 此时 main.js 里 `require()` 拿到的是**空对象**
// （book_source.js / music_lx.js 都踩过这个坑：报 "xxx is not a function"）。
/**
 * ── 发现页所需的公开接口 ────────────────────────────────────────
 * 下面这批对应 Beans-Music `NetEaseAPI.swift` 里的同名方法，
 * **全部无需登录**，所以「发现」页能完整照搬它的内容结构：
 *   榜单 / 每日推荐 / 歌单广场 / 热门搜索 / 新歌速递 /
 *   相似歌曲 / 歌手热门 / 专辑 / 歌单详情 / 评论
 * 登录态才能用的（用户歌单、收藏、红心、FM、日推个性化）**不做**。
 */

/** 通用 GET：带网易云要求的头 */
async function get(url, params) {
    const res = await axios.get(url, {
        params,
        headers: NETEASE_HEADERS,
        timeout: TIMEOUT_MS,
    });
    return res.data;
}

/** 榜单列表 */
async function topLists() {
    try {
        const d = await get('https://music.163.com/api/toplist', {});
        const list = (d.list || []).map((x) => ({
            id: x.id,
            name: x.name,
            cover: x.coverImgUrl || x.coverImgUrl2 || '',
            updateFrequency: x.updateFrequency || '',
        }));
        return { ok: true, list };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/** 榜单/歌单详情（含歌曲） */
async function playlistDetail(id) {
    const pid = parseInt(id, 10);
    if (!pid) return { ok: false, error: '缺少歌单 id' };
    try {
        const d = await get('https://music.163.com/api/v6/playlist/detail', { id: pid, n: 1000 });
        const p = d.playlist || {};
        const tracks = (p.tracks || []).map(mapTrack);
        return {
            ok: true,
            playlist: {
                id: p.id,
                name: p.name || '',
                cover: p.coverImgUrl || '',
                trackCount: p.trackCount || tracks.length,
                description: p.description || '',
                creator: (p.creator && p.creator.nickname) || '',
            },
            list: tracks,
        };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/** 每日推荐歌单（首页"推荐歌单"） */
async function personalized(limit = 20) {
    try {
        const d = await get('https://music.163.com/api/personalized/playlist', { limit });
        const list = (d.result || []).map((x) => ({
            id: x.id,
            name: x.name,
            cover: x.picUrl || '',
            trackCount: x.trackCount || 0,
            description: x.copywriter || '',
        }));
        return { ok: true, list };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/** 歌单广场（按分类） */
async function playlistSquare(cat = '全部', order = 'hot', limit = 12) {
    try {
        const d = await get('https://music.163.com/api/playlist/list', {
            cat, order, limit, offset: 0, total: true,
        });
        const list = (d.playlists || []).map((x) => ({
            id: x.id,
            name: x.name,
            cover: x.coverImgUrl || '',
            trackCount: x.trackCount || 0,
            description: x.description || '',
            creator: (x.creator && x.creator.nickname) || '',
        }));
        return { ok: true, list, more: !!d.more };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/** 歌单分类名列表 */
async function playlistCatlist() {
    try {
        const d = await get('https://music.163.com/api/playlist/catalogue', {});
        const cats = [{ name: '全部', subs: [] }];
        // 官方分类结构：sub（热门）/ categories（全量）
        if (d.sub && d.sub.length) cats.push({ name: '热门', subs: d.sub });
        if (d.categories) {
            Object.keys(d.categories).forEach((k) => {
                cats.push({ name: d.categories[k], subs: [] });
            });
        }
        return { ok: true, list: cats };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/** 热门搜索词 */
async function hotSearch() {
    // ⚠️ `type=1111` 是必需的：不带它接口返回 200 但 hots 为空
    // （表现为"功能可用但永远没数据"，最难查的那种）。
    // Beans 走的是加密 weapi 通道，参数同样是 type:1111；
    // 这里走明文 /api/search/hot，实测同样返回 10 条。
    try {
        const d = await get('https://music.163.com/api/search/hot', { type: 1111 });
        const list = ((d.result && d.result.hots) || [])
            .map((x) => x.first)
            .filter(Boolean);
        return { ok: true, list };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/** 新歌速递 */
async function newSongs(limit = 10) {
    try {
        const d = await get('https://music.163.com/api/personalized/newsong', { limit });
        const list = (d.result || [])
            .map((x) => x.song || x)
            .map(mapTrack)
            .filter(Boolean);
        return { ok: true, list };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/** 歌曲评论 */
async function comments(id, limit = 30, offset = 0) {
    const sid = parseInt(id, 10);
    if (!sid) return { ok: false, error: '缺少歌曲 id' };
    try {
        const d = await get('https://music.163.com/api/v1/resource/comments/R_SO_4_' + sid, {
            limit, offset,
        });
        const list = (d.hotComments && offset === 0 ? d.hotComments : d.comments || []).map((x) => ({
            id: String(x.commentId),
            user: (x.user && x.user.nickname) || '匿名',
            avatarUrl: (x.user && x.user.avatarUrl) || '',
            content: x.content || '',
            likedCount: x.likedCount || 0,
            time: x.time || 0,
        }));
        return { ok: true, list, total: d.total || 0 };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/** 相似歌曲 */
async function simiSongs(id) {
    const sid = parseInt(id, 10);
    if (!sid) return { ok: false, error: '缺少歌曲 id' };
    try {
        const d = await get('https://music.163.com/api/discovery/simiSong', { songid: sid });
        const list = (d.songs || []).map(mapTrack).filter(Boolean);
        return { ok: true, list };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/** 搜索歌手 */
async function searchArtists(keyword, limit = 30) {
    const kw = String(keyword || '').trim();
    if (!kw) return { ok: false, error: '请输入关键词' };
    try {
        const d = await get('https://music.163.com/api/cloudsearch/pc', {
            s: kw, type: 100, limit, offset: 0,
        });
        const list = ((d.result && d.result.artists) || []).map((a) => ({
            id: a.id,
            name: a.name,
            avatarUrl: a.picUrl || a.img1v1Url || '',
        }));
        return { ok: true, list };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/** 搜索专辑 */
async function searchAlbums(keyword, limit = 30) {
    const kw = String(keyword || '').trim();
    if (!kw) return { ok: false, error: '请输入关键词' };
    try {
        const d = await get('https://music.163.com/api/cloudsearch/pc', {
            s: kw, type: 10, limit, offset: 0,
        });
        const list = ((d.result && d.result.albums) || []).map((a) => ({
            id: a.id,
            name: a.name,
            cover: a.picUrl || '',
            artist: (a.artist && a.artist.name) || '',
        }));
        return { ok: true, list };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/** 歌手热门歌曲 */
async function artistSongs(artistId, limit = 120) {
    const aid = parseInt(artistId, 10);
    if (!aid) return { ok: false, error: '缺少歌手 id' };
    try {
        const d = await get('https://music.163.com/api/v1/artist/' + aid, {});
        const hot = (d.hotSongs || []).map(mapTrack).filter(Boolean);
        return { ok: true, list: hot.slice(0, limit) };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/** 歌手专辑 */
async function artistAlbums(artistId, limit = 50) {
    const aid = parseInt(artistId, 10);
    if (!aid) return { ok: false, error: '缺少歌手 id' };
    try {
        const d = await get('https://music.163.com/api/artist/albums/' + aid, { limit, offset: 0 });
        const list = (d.hotAlbums || []).map((a) => ({
            id: a.id,
            name: a.name,
            cover: a.picUrl || '',
            artist: (a.artist && a.artist.name) || '',
        }));
        return { ok: true, list };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/** 专辑歌曲 */
async function albumSongs(albumId) {
    const aid = parseInt(albumId, 10);
    if (!aid) return { ok: false, error: '缺少专辑 id' };
    try {
        const d = await get('https://music.163.com/api/v1/album/' + aid, {});
        const list = (d.songs || []).map(mapTrack).filter(Boolean);
        return { ok: true, list };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

export {
    handleMusicApi, search, songUrl, lyric,
    topLists, playlistDetail, personalized, playlistSquare, playlistCatlist,
    hotSearch, newSongs, comments, simiSongs,
    searchArtists, searchAlbums, artistSongs, artistAlbums, albumSongs,
    lxSelfTest,
    resolveBySourceAction,
};
