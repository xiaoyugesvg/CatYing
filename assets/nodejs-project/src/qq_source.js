/**
 * QQ 音乐数据源（公开接口，无需登录）
 *
 * ── 协议来源 ───────────────────────────────────────────────
 * 参考 Beans-Music `QQMusicAPI.swift`（MIT，https://github.com/XIaodou0416/Beans-Music）
 * 及其引用的 wp_MusicApi（https://github.com/GitHub-ZC/wp_MusicApi）逆向结论：
 *   · 搜索     → `search_for_qq_cp`（t=0），家庭/移动/数据中心网络均可用；
 *   · 播放地址 → `musicu.fcg` 取 vkey（VIP 歌曲返回空；部分数据中心 IP 会被风控）；
 *   · 歌词     → `fcg_query_lyric_new.fcg`（songmid 直查，nobase64=1 拿明文）。
 *
 * ── 对外结构 ───────────────────────────────────────────────
 * 与 `music_source.js` 里网易云 / 酷狗（kugou_source.js）**完全一致**：
 *   · searchSongs(keyword, limit, offset) → { ok, list:[{id,name,artist,album,cover,duration,fee}], total }
 *   · songUrl(id, quality)                → { ok, url, br, type, size } | no_free_source | { ok:false, error }
 *   · lyric(id)                           → { ok, lyric, tlyric }
 *   · hotSearch()                         → { ok, list:[{id,name}] }
 *
 *   ── 以下**全部免登录**（播放地址才需要登录）──
 *   · topLists()                          → { ok, list:[{id,name,cover,updateFrequency}] }
 *   · topListSongs(topId, limit)          → { ok, list:[Song…], total }
 *   · playlistSquare(catId, limit)        → { ok, list:[{id,name,cover,trackCount,creator}] }
 *   · playlistCategories()                → { ok, list:[{id,name}] }
 *   · recommendPlaylists(limit)           → { ok, list:[…] }（兜底，可能为空）
 *   · playlistSongs(dissId, limit)        → { ok, list:[Song…], total }
 *   · selfTest()                          → { ok, modules:[...] }（不联网）
 *
 * id 契约：Dart 侧 `Song.id` 是 int，所以对外 id = QQ 数字 songid；
 * 歌曲信息（songmid/mediaMid/歌名）在 Node 侧内存索引中反查
 *（与酷狗 album_audio_id 的做法一致）。
 */

import axios from 'axios';

export const SOURCE_NAME = 'qq';

const TIMEOUT_MS = 15000;

/** QQ 官方客户端头（缺 Referer/UA 会被拒或返回空） */
const QQ_HEADERS = {
    'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 QQMusic/9.0.5',
    'Referer': 'https://y.qq.com/portal/player.html',
    'Cookie': 'uin=0; qqmusic_fromtag=66',
};

/** 会话内固定的设备 guid（musicu vkey 必需；QQ 常规格式：1000 + 9 位随机） */
let _guid = '';
function deviceGuid() {
    if (!_guid) {
        const rand = Math.floor(Math.random() * 1e9);
        _guid = '1000' + String(rand).padStart(9, '0');
    }
    return _guid;
}

/** 把 axios 错误转成能看懂的短句（与网易云/酷狗一致） */
function humanize(e) {
    if (e && e.response) {
        return '接口返回 HTTP ' + e.response.status;
    }
    if (e && e.code === 'ECONNABORTED') {
        return '请求超时';
    }
    return '请求失败：' + ((e && e.message) || String(e));
}

// ────────────────────────────────────────────────────────────────
// 搜索（client_search_cp，无需登录）
// ────────────────────────────────────────────────────────────────

/** 单曲搜索 URL（t=0 单曲；t=1/2 歌手/专辑） */
function clientSearchURL(keyword, limit, page, type = 0) {
    const qs = new URLSearchParams({
        format: 'json',
        w: keyword,
        n: String(limit),
        p: String(Math.max(page, 1)),
        t: String(type),
    });
    return 'https://c.y.qq.com/soso/fcgi-bin/search_for_qq_cp?' + qs.toString();
}

/** 封面：专辑 mid → y.gtimg.cn 图床（与 Beans-Music photoURL 一致） */
function coverURL(albumMid, size = '300x300') {
    return albumMid ? `https://y.gtimg.cn/music/photo_new/T002R${size}M000${albumMid}.jpg` : '';
}

/**
 * 把 QQ 各接口的歌曲条目映射成统一结构。
 *
 * ── 🔴 为什么要容忍**两套完全不同的字段名**（实测，不是猜）─────────
 * QQ 不同接口的歌曲结构差别很大：
 *
 *  ① `search_for_qq_cp`（搜索）：
 *     `songid` / `songmid` / `songname` / `singer:[{name}]` /
 *     `albummid` / `interval` / `file.media_mid`
 *
 *  ② `fcg_ucc_getcdinfo_byids_cp`（歌单歌曲）：
 *     `id` / **`mid`** / `name` / `singer:[{name}]` /
 *     `album.mid` / `interval` / `file.media_mid`
 *
 *  ③ `musicToplist...GetDetail`（榜单歌曲）：
 *     `songId` / **没有 mid** / `title` / **`singerName` 是字符串** /
 *     `albumMid` / **没有 interval** / **没有 media mid**
 *
 * 只按 ① 实现时，② 和 ③ 会被 `if (!item.songmid) return null` **全丢掉**
 * —— 实测表现就是 `topListSongs` / `playlistSongs` 返回 `list: []`
 *（接口 ok=true 但一条都没有，最难查的那种）。
 */
function mapSong(item) {
    if (!item || typeof item !== 'object') return null;

    // ① mid：三个接口三种写法
    const mid = String(
        item.songmid || item.mid || (item.file && item.file.media_mid) || ''
    );
    // ② 数字 id：三种写法（榜单只有 songId）
    const songid = Number(item.songid || item.songId || item.id || 0) || 0;
    // ⚠️ 两者都缺 → 这条没法用（vkey 必须要 mid）
    if (!mid && !songid) return null;

    // ③ 歌手：可能是数组（{name}）也可能是**斜杠分隔的字符串**
    let artist = '';
    if (Array.isArray(item.singer)) {
        artist = item.singer.map((s) => s && (s.name || s.title)).filter(Boolean).join('、');
    } else if (typeof item.singerName === 'string') {
        // 榜单：`"Hawk Nelson/Jonathan Steingard"` → 统一成中文顿号
        artist = item.singerName.split('/').map((s) => s.trim()).filter(Boolean).join('、');
    } else if (typeof item.singer === 'string') {
        artist = item.singer;
    }

    // ④ 专辑：可能嵌套对象（歌单）也可能是顶层字段（搜索/榜单）
    const albumObj = (item.album && typeof item.album === 'object') ? item.album : {};
    const albumMid = String(item.albummid || item.albumMID || item.albumMid || albumObj.mid || '');

    const mediaMid = String(
        (item.file && item.file.media_mid) || item.strMediaMid || item.media_mid || ''
    );
    const pay = item.pay || {};
    const fee = Number(
        item.fee != null ? item.fee
            : (pay.pay_play != null ? pay.pay_play : (pay.payplay || 0)),
    );

    return {
        // 对外 id 用数字 id（Dart Song.id 是 int）
        id: songid,
        name: String(item.songname || item.name || item.title || ''),
        artist,
        album: String(item.albumname || item.albumName || albumObj.name || albumObj.title || ''),
        albumId: albumMid,
        cover: coverURL(albumMid),
        duration: Number(item.interval) || 0,
        fee,
        songmid: mid,
        mediaMid,
    };
}

/**
 * 搜索歌曲
 * @returns {Promise<{ok:boolean, list?:Array, total?:number, error?:string}>}
 */
async function searchSongs(keyword, limit = 30, offset = 0) {
    const kw = String(keyword || '').trim();
    if (!kw) return { ok: false, error: '请输入关键词' };

    const size = Math.min(Math.max(parseInt(limit, 10) || 30, 1), 50);
    const off = Math.max(parseInt(offset, 10) || 0, 0);
    // 接口是页式（n/p），offset → 页 + 页内偏移
    const startPage = Math.floor(off / size) + 1;
    const inPageSkip = off % size;

    try {
        const r = await axios.get(clientSearchURL(kw, size, startPage), {
            headers: QQ_HEADERS,
            timeout: TIMEOUT_MS,
        });
        const data = (r.data && r.data.data) || {};
        const song = data.song || {};
        const items = Array.isArray(song.list) ? song.list : [];
        const list = [];
        for (let j = 0; j < items.length; j++) {
            if (j < inPageSkip) continue;
            const m = mapSong(items[j]);
            if (m && !list.some((x) => x && x.id === m.id)) list.push(m);
            if (list.length >= size) break;
        }
        const total = Number(song.totalnum || song.curnum || list.length) || list.length;
        // 记住这批歌：Dart 的 url(id)/lyric(id) 只回传数字 songid，靠这里反查 songmid
        rememberTracks(list);
        return { ok: true, list, total };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

// ────────────────────────────────────────────────────────────────
// 内存曲目索引（数字 songid → songmid / mediaMid / 歌名）
// ────────────────────────────────────────────────────────────────
const trackIndex = new Map();
const TRACK_INDEX_MAX = 500;

/** 记一批曲目（search / hotSearch 等调用后走这里） */
function rememberTracks(list) {
    for (const t of list || []) {
        if (!t || !t.id) continue;
        if (trackIndex.size >= TRACK_INDEX_MAX) {
            const first = trackIndex.keys().next();
            if (!first.done) trackIndex.delete(first.value);
        }
        trackIndex.set(String(t.id), {
            songmid: t.songmid || '',
            mediaMid: t.mediaMid || '',
            name: t.name || '',
            artist: t.artist || '',
            duration: t.duration || 0,
        });
    }
}

/** 反查某首歌的 songmid/mediaMid */
function lookupTrack(id) {
    return trackIndex.get(String(id || '')) || null;
}

// ────────────────────────────────────────────────────────────────
// 播放地址（musicu.fcg vkey；VIP 歌曲返回空）
// ────────────────────────────────────────────────────────────────

/** Dart 音质名 → QQ br 阶梯（F000=flac 无损 / M800·M500=mp3 / C400=m4a） */
function qualityLadder(quality) {
    const q = String(quality || '').toLowerCase();
    if (q === 'lossless' || q === 'hires') return ['F000', 'M800', 'M500', 'C400'];
    if (q === 'exhigh' || q === '320k') return ['M800', 'M500', 'C400'];
    if (q === 'higher' || q === '192k') return ['M500', 'C400'];
    return ['M500', 'C400'];
}

/** br → 扩展名（与 Beans-Music 一致） */
function extOf(br) {
    if (String(br).startsWith('F')) return 'flac';
    if (String(br).startsWith('C')) return 'm4a';
    return 'mp3';
}

/** 单个 vkey 请求（GET musicu.fcg + data JSON） */
async function fetchVkey({ songmid, mediaMid, br, uin = '0', guid }) {
    const ext = extOf(br);
    const preferredMid = mediaMid || songmid;
    // QQ 官方 Web 格式为 br + songmid + media_mid；其余格式兼容不同年代接口
    const filenames = [
        `${br}${songmid}${preferredMid}.${ext}`,
        `${br}${preferredMid}.${ext}`,
        `${br}${songmid}${songmid}.${ext}`,
        `${br}${songmid}.${ext}`,
    ];
    const uniq = [...new Set(filenames)];

    const payload = {
        comm: { uin: 0, format: 'json', ct: 24, cv: 0, g_tk: 0 },
        req: {
            module: 'CDN.SrfCdnDispatchServer',
            method: 'GetCdnDispatch',
            param: { guid, calltype: 0, userip: '' },
        },
        req_0: {
            module: 'vkey.GetVkeyServer',
            method: 'CgiGetVkey',
            param: {
                filename: uniq,
                guid,
                songmid: Array(uniq.length).fill(songmid),
                songtype: Array(uniq.length).fill(0),
                uin,
                loginflag: 0,
                platform: '20',
            },
        },
    };
    const qs = new URLSearchParams({
        format: 'json',
        data: JSON.stringify(payload),
    });
    const r = await axios.get('https://u.y.qq.com/cgi-bin/musicu.fcg?' + qs.toString(), {
        headers: { 'User-Agent': 'Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)', 'Referer': 'https://y.qq.com/' },
        timeout: TIMEOUT_MS,
    });
    const root = (r.data && r.data.req_0 && r.data.req_0.data) || {};
    const sips = Array.isArray(root.sip) ? root.sip.filter(Boolean) : [];
    const urls = Array.isArray(root.midurlinfo) ? root.midurlinfo : [];
    for (const u of urls) {
        const purl = u && typeof u.purl === 'string' && u.purl;
        if (purl && sips.length) {
            return { url: sips[0] + purl, br, type: ext, size: Number(u.size || u.filesize || 0) };
        }
    }
    return null;
}

/**
 * 取播放地址（VIP 歌返回 no_free_source）。
 * 参考 Beans-Music：目标档位不可用时继续向下试兼容档位。
 */
async function songUrl(id, quality = '320k') {
    const remembered = lookupTrack(id);
    const songmid = remembered && remembered.songmid;
    const mediaMid = (remembered && remembered.mediaMid) || '';
    if (!songmid) {
        return { ok: false, error: '缺少歌曲 id（需先搜索/浏览过该歌曲）' };
    }
    const guid = deviceGuid();
    const ladder = qualityLadder(quality);
    let lastErr = null;

    for (const br of ladder) {
        try {
            const got = await fetchVkey({ songmid, mediaMid, br, guid });
            if (got) {
                return { ok: true, url: got.url, br: Number(parseInt(br.replace(/\D/g, '') || '0', 10)) * 1000, type: got.type, size: got.size };
            }
            // 空 purl：该档位无权限/无音源，继续往下试
        } catch (e) {
            lastErr = e;
        }
    }

    if (lastErr && !(lastErr.response)) {
        // 网络层失败才报错；拿到 HTTP 响应但全是空 → 无免费音源
        return { ok: false, error: humanize(lastErr) };
    }
    return {
        ok: true,
        url: '',
        reason: 'no_free_source',
        message: '该歌曲没有免费音源（QQ 音乐需要会员/购买）',
    };
}

// ────────────────────────────────────────────────────────────────
// 歌词（fcg_query_lyric_new，songmid 直查）
// ────────────────────────────────────────────────────────────────

async function lyric(id) {
    const remembered = lookupTrack(id);
    const songmid = remembered && remembered.songmid;
    if (!songmid) {
        return { ok: false, error: '缺少歌曲 id（需先搜索/浏览过该歌曲）' };
    }
    try {
        const qs = new URLSearchParams({
            songmid,
            format: 'json',
            nobase64: '1',
            g_tk: '5381',
        });
        const r = await axios.get('https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?' + qs.toString(), {
            headers: QQ_HEADERS,
            timeout: TIMEOUT_MS,
        });
        const lrc = String((r.data && r.data.lyric) || '');
        return { ok: true, lyric: lrc, tlyric: '' };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

// ────────────────────────────────────────────────────────────────
// 热搜（gethotkey.fcg）
// ────────────────────────────────────────────────────────────────

async function hotSearch() {
    try {
        const r = await axios.get('https://c.y.qq.com/splcloud/fcgi-bin/gethotkey.fcg?format=json', {
            headers: QQ_HEADERS,
            timeout: TIMEOUT_MS,
        });
        const keys = ((r.data && r.data.data && r.data.data.hotkey) || [])
            .map((x) => String(x && (x.k || x.key || '')).trim())
            .filter(Boolean);
        const list = keys.map((k, i) => ({ id: String(i), name: k }));
        return { ok: true, list };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

// ────────────────────────────────────────────────────────────────
// 发现页：排行榜 / 歌单广场 / 推荐歌单 / 榜单歌曲
//
// ⚠️ 这四个都是**免登录**的（实测 HTTP 200）——
//    与"播放地址"不同（那个必须带 QQ 登录 Cookie，
//    见 `songUrl` 的注释与 `no_free_source` 的返回）。
//
// 参考 Beans-Music 的实现：
//   · 排行榜   → `musicToplist.ToplistInfoServer / GetAll`
//   · 歌单广场 → `fcg_get_diss_by_tag.fcg`（按分类）
//   · 推荐歌单 → `music.srfDissInfo.RecommendPlaylist / GetRecommendPlaylist`
//   · 榜单歌曲 → `musicToplist.ToplistInfoServer / GetDetail`
// ────────────────────────────────────────────────────────────────

/** musicu.fcg 统一 POST（免登录也能用） */
async function musicu(payload, timeout = TIMEOUT_MS) {
    const r = await axios.post('https://u.y.qq.com/cgi-bin/musicu.fcg', payload, {
        headers: Object.assign({}, QQ_HEADERS, {
            'Content-Type': 'application/json',
            // musicu 对 UA 敏感：用桌面 IE 的反而稳（Beans 同款）
            'User-Agent': 'Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)',
            Referer: 'https://y.qq.com/',
        }),
        timeout,
    });
    return r.data || {};
}

/** 按路径取值（QQ 的返回嵌套很深且各接口不一致） */
function at(obj, ...path) {
    let cur = obj;
    for (const k of path) {
        if (cur == null || typeof cur !== 'object') return undefined;
        cur = cur[k];
    }
    return cur;
}

/** 歌单封面（QQ 有三个尺寸模板；给空就返回空串，让 Dart 侧走占位图） */
function playlistCover(raw) {
    const s = String(raw || '').trim();
    if (!s) return '';
    if (s.startsWith('http')) return s.replace(/^http:/, 'https:');
    if (s.startsWith('//')) return 'https:' + s;
    // QQ 的 logo 字段常是相对路径
    return 'https://y.gtimg.cn' + (s.startsWith('/') ? '' : '/') + s;
}

/**
 * 排行榜列表（30 个榜单，分 4 组）。
 *
 * 对齐网易云/酷狗的 `topLists()` 返回：
 *   `{ ok, list: [{ id, name, cover, updateFrequency }] }`
 */
async function topLists() {
    try {
        const data = await musicu({
            comm: { ct: 24, cv: 0 },
            req_1: {
                module: 'musicToplist.ToplistInfoServer',
                method: 'GetAll',
                param: {},
            },
        });
        const groups = at(data, 'req_1', 'data', 'group') || [];
        const out = [];
        for (const g of groups) {
            for (const t of (g && g.toplist) || []) {
                const id = Number(t.topId || t.id || 0);
                const name = String(t.topTitle || t.title || '').trim();
                if (!id || !name) continue;
                out.push({
                    id,
                    name,
                    cover: playlistCover(t.frontPicUrl || t.headPicUrl || t.picUrl),
                    // QQ 没有"更新频率"字段，用榜单说明的第一个词兜底
                    updateFrequency: String(t.updateTime || t.listName || 'QQ 峰尖榜'),
                    // ⚠️ 保留原始字段：Dart 侧拿 id 去查榜单歌曲时要用
                    songCount: Number(t.songCnt || 0) || 0,
                });
            }
        }
        return { ok: true, list: out };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/**
 * 榜单里的歌曲（Beans 的 `topListSongs`）。
 *
 * @returns `{ ok, list:[Song…], total }`
 */
async function topListSongs(topId, limit = 30) {
    try {
        const data = await musicu({
            comm: { ct: 24, cv: 0 },
            req_1: {
                module: 'musicToplist.ToplistInfoServer',
                method: 'GetDetail',
                param: {
                    topId: Number(topId),
                    offset: 0,
                    num: Math.min(Math.max(limit, 1), 100),
                    period: '',
                },
            },
        });
        const raw = at(data, 'req_1', 'data', 'data', 'song') || [];
        const list = raw.map(mapSong).filter(Boolean);
        rememberTracks(list);
        return { ok: true, list, total: Number(at(data, 'req_1', 'data', 'data', 'total') || list.length) };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/**
 * 歌单广场（按分类）。
 *
 * @param categoryId 分类 id（`10000000` = 全部）；见 [playlistCategories]
 * @param limit      数量
 */
async function playlistSquare(categoryId = 10000000, limit = 20, sortId = 5) {
    try {
        const n = Math.min(Math.max(limit, 1), 60);
        const url = 'https://c.y.qq.com/splcloud/fcgi-bin/fcg_get_diss_by_tag.fcg'
            + '?format=json&outCharset=utf-8&picmid=1'
            + `&categoryId=${Number(categoryId) || 10000000}`
            + `&sortId=${Number(sortId) || 5}`
            + `&sin=0&ein=${n - 1}`;
        const r = await axios.get(url, {
            headers: Object.assign({}, QQ_HEADERS, { Referer: 'https://y.qq.com/' }),
            timeout: TIMEOUT_MS,
        });
        const raw = at(r.data, 'data', 'list') || [];
        const list = [];
        for (const it of raw) {
            const id = Number(it.dissid || it.diss_id || 0);
            const name = String(it.dissname || it.diss_name || '').trim();
            if (!id || !name) continue;
            list.push({
                id,
                name,
                cover: playlistCover(it.imgurl || it.picurl || it.logo),
                trackCount: Number(it.listennum || it.song_cnt || 0) || 0,
                creator: String(it.creator && it.creator.name ? it.creator.name : '').trim(),
            });
        }
        return { ok: true, list };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/** 歌单广场分类（`[{id, name}]`，第一项固定"全部"） */
async function playlistCategories() {
    try {
        const r = await axios.get(
            'https://c.y.qq.com/splcloud/fcgi-bin/fcg_get_diss_tag_conf.fcg?format=json&outCharset=utf-8',
            { headers: Object.assign({}, QQ_HEADERS, { Referer: 'https://y.qq.com/' }), timeout: TIMEOUT_MS },
        );
        const out = [{ id: 10000000, name: '全部' }];
        const seen = new Set(['10000000']);
        // QQ 的分类是**递归嵌套**的（tags → 子 tags），必须深度遍历
        const walk = (v) => {
            if (v == null) return;
            if (Array.isArray(v)) {
                v.forEach(walk);
                return;
            }
            if (typeof v !== 'object') return;
            const id = Number(v.categoryId || v.category_id || v.tag_id || v.id || 0);
            const name = String(v.categoryName || v.category_name || v.tag_name || v.name || '').trim();
            if (id > 0 && name && !seen.has(String(id))) {
                seen.add(String(id));
                out.push({ id, name });
            }
            Object.values(v).forEach(walk);
        };
        walk(at(r.data, 'data'));
        return { ok: true, list: out.slice(0, 40) };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/**
 * 推荐歌单（musicu）。
 *
 * ── 🔴 实测：**不可用**（2026，免登录）──────────────────────────
 * `music.srfDissInfo.RecommendPlaylist` 返回
 *     `{ req_1: { code: 500003, subcode: 860100001 } }`   ← **无 data**
 * 所以免登录拿不到推荐歌单。保留这个函数只是为了让调用方拿到
 * **明确原因**（而不是空列表让人以为"接口通了但没数据"）。
 *
 * 需要推荐歌单时应该走 [playlistSquare]（那个实测 20 个歌单可用）。
 */
async function recommendPlaylists(limit = 12) {
    try {
        const data = await musicu({
            comm: { ct: 24, cv: 0 },
            req_1: {
                module: 'music.srfDissInfo.RecommendPlaylist',
                method: 'GetRecommendPlaylist',
                param: { uin: 0, lastDissid: 0, songtype: 1, scene: 0 },
            },
        });
        const code = Number(at(data, 'req_1', 'code') || 0);
        if (code !== 0) {
            return { ok: false, error: `QQ 推荐歌单接口不可用（code=${code}，需登录或已风控）` };
        }
        const raw = at(data, 'req_1', 'data', 'v_playlist') || [];
        const list = [];
        for (const it of raw) {
            const id = Number(it.tid || it.dissid || it.id || 0);
            const name = String(it.title || it.dissname || '').trim();
            if (!id || !name) continue;
            list.push({
                id,
                name,
                cover: playlistCover(it.cover || it.pic_url || it.logo),
                trackCount: Number(it.songnum || it.song_cnt || 0) || 0,
                creator: '',
            });
            if (list.length >= limit) break;
        }
        return { ok: true, list };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/** 歌单里的歌曲（fcg_ucc_getcdinfo_byids_cp，免登录可拿普通歌单） */
async function playlistSongs(dissId, limit = 100) {
    try {
        const n = Math.min(Math.max(limit, 1), 300);
        const url = 'https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg'
            + '?type=1&json=1&utf8=1&onlysong=0&new_format=1'
            + `&disstid=${Number(dissId)}`
            + '&loginUin=0&hostUin=0&format=json&inCharset=utf8&outCharset=utf-8'
            + '&notice=0&platform=yqq.json&needNewCode=0';
        const r = await axios.get(url, {
            headers: Object.assign({}, QQ_HEADERS, {
                Referer: 'https://y.qq.com/n/yqq/playlist',
            }),
            timeout: TIMEOUT_MS,
        });
        const cdlist = at(r.data, 'cdlist') || [];
        const raw = at(cdlist[0] || {}, 'songlist') || [];
        const list = [];
        for (const it of raw.slice(0, n)) {
            // 有的返回把歌包在 track_info 里
            const song = mapSong(it.track_info || it);
            if (song) list.push(song);
        }
        rememberTracks(list);
        return { ok: true, list, total: raw.length };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

// ────────────────────────────────────────────────────────────────
// 工具
// ────────────────────────────────────────────────────────────────

/** id 编码：`{songmid}|{mediaMid}`；兼容纯 songmid */
function decodeSongId(id) {
    const s = String(id || '');
    if (!s) return null;
    const [songmid, mediaMid] = s.split('|');
    if (!songmid) return null;
    return { songmid, mediaMid: mediaMid || '' };
}

/** 自检（不联网） */
function selfTest() {
    const out = { ok: true, modules: [] };
    out.modules.push({ name: 'axios', ok: typeof axios.get === 'function' });
    out.modules.push({ name: 'clientSearchURL', ok: typeof clientSearchURL === 'function' });
    out.modules.push({ name: 'deviceGuid', ok: /^1000\d{9}$/.test(deviceGuid()) });
    rememberTracks([{ id: 123, songmid: 'M500001', mediaMid: 'M500002', name: 'x', artist: 'y' }]);
    const d = lookupTrack(123);
    out.modules.push({ name: 'lookupTrack', ok: d && d.songmid === 'M500001' && d.mediaMid === 'M500002' });
    out.modules.push({ name: 'qualityLadder', ok: qualityLadder('lossless')[0] === 'F000' });
    return out;
}

export {
    searchSongs,
    songUrl,
    lyric,
    hotSearch,
    selfTest,
    // ── 发现页（全部免登录）──
    topLists,
    topListSongs,
    playlistSquare,
    playlistCategories,
    recommendPlaylists,
    playlistSongs,
};
