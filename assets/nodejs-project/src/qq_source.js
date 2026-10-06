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
 * 歌手头像：歌手 mid → y.gtimg.cn 图床。
 *
 * ── 🔴 实测结论（2026，免登录）─────────────────────────────────
 * 这个模板**可用**（HTTP 200 / image/jpeg，150/300/500 三种尺寸都通）：
 *     `https://y.gtimg.cn/music/photo_new/T001R{size}M000{singerMid}.jpg`
 *
 * 而其它"拿歌手列表"的路子**都不可用**（实测）：
 *   · `music.web_singer_list.SingerListServer` → `code=500003` 无数据
 *   · `fcg_v8_singer_track_cp` / `fcg_get_singer_info` → HTTP 404
 * 所以真头像**只能靠"从歌曲里取 singerMid + 这个模板"**。
 */
function artistAvatarURL(singerMid, size = '300x300') {
    return singerMid
        ? `https://y.gtimg.cn/music/photo_new/T001R${size}M000${singerMid}.jpg`
        : '';
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

    // ⑤ 歌手 mid（**给"热门歌手"行取真头像用**）
    //
    // 三个接口的写法都不同：
    //   · 搜索/歌单：`singer:[{mid, name}]`
    //   · 榜单：`singerMid`（字符串，可能是**多个**用 `/` 分隔）
    // 取**第一个**歌手的 mid —— 多歌手的合唱曲，头像只能显示一个。
    let firstSingerMid = '';
    if (Array.isArray(item.singer) && item.singer.length) {
        firstSingerMid = String(item.singer[0] && item.singer[0].mid || '');
    } else if (typeof item.singerMid === 'string') {
        firstSingerMid = item.singerMid.split('/')[0].trim();
    }

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
        // ⚠️ 这个名字是给"热门歌手"行用的（`topArtistsList` 会读它取头像）
        artistMid: firstSingerMid,
        // ── 🔴 必须回 `source`（修一个"播错歌"的真 bug）──────────────
        //
        // `Song.source` 在 Dart 侧决定两件事：
        //   1. `identityKey` = `'${source.platform}-$id'` ——
        //      收藏 / 下载 / 队列 / 最近播放**都按它去重**
        //   2. 播放时选平台：`songUrl(song.id, source: song.source)`
        //
        // 这里原来**没有** `source`（同模块的 `kugou_source.js` 有），
        // 而 `music_source.js` 的 QQ 分支是 `return qq.searchSongs(...)` /
        // `qq.topListSongs(...)` / `qq.playlistSongs(...)` **直通**、不补字段，
        // 于是 Dart 侧 `SongSource.fromKey(null)` → 落到 **netease** ✗
        //
        // 后果：QQ 榜单/歌单的歌被标成网易云，而 **QQ 与网易云的数字 id
        // 区间高度重叠** → 拿 QQ 的 id 去网易云查同一数字 →
        // **命中就是另一首歌** → 播错歌 ✗
        //
        // Dart 侧 `MusicApi._songsWithSource` 也做了兜底（双保险：
        // 那边覆盖所有平台，这里保证 QQ 的原生消费者也拿到正确来源）。
        source: 'qq',
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

const _midCache = new Map();   // songId(number) -> songmid(string)

/**
 * **补 songmid**：榜单/歌单接口只给数字 `songId`，而**所有取址接口都要 songmid**。
 *
 * ── 🔴 为什么必须有这一步（用户报的"QQ 播不了"的最后一环）──────────
 * `musicToplist…GetDetail` 返回的歌曲字段**只有这些**（实测全字段枚举）：
 *     rank, rankType, rankValue, recType, **songId**, vid, albumMid,
 *     title, singerName, singerMid, songType, uuidCnt, cover, mvid
 * —— **没有 songmid、没有 mid**，只有数字 `songId`。
 *
 * 而两个取址路径都**不认数字 id**（实测）：
 *   · 元力音源 `qq_kw.php?id=<songId>` → 歌名空、`url: null` ✗
 *   · QQ 官方 `musicu` 取 vkey 也要 **media_mid**
 * 所以榜单歌曲点播放必然失败 —— 除非把 songmid 补出来。
 *
 * ── 怎么补（实测可行）──────────────────────────────────────────
 * QQ 有个"按数字 id 查详情"的免登录接口：
 *     `music.trackInfo.UniformRuleCtrl / CgiGetTrackInfo`
 *     `param: { ids: [102326316], types: [0] }`
 * 它返回 `mid`。实测 `songId=102326316` → `mid=002a5OfG1VpukL`，
 * 拿这个 mid 去 `qq_kw.php` 查出来正是 **"Sold Out" / "Hawk Nelson" / "Diamonds"**
 *（与榜单里的歌完全吻合）✓
 *
 * ⚠️ 逐个查很慢，所以只对**缺 songmid** 的条目做，并且**缓存**；
 *    失败不影响列表（补不上就留空，播放时自会给出明确原因）。
 */
async function fillSongMids(list) {
    const need = list.filter((s) => !s.songmid && s.id);
    if (!need.length) return list;

    const ids = [];
    for (const s of need) {
        const cached = _midCache.get(s.id);
        if (cached) {
            s.songmid = cached;
        } else if (!ids.includes(s.id)) {
            ids.push(s.id);
        }
    }
    if (!ids.length) return list;

    // ── 用 `pf_song_detail_svr / get_song_detail`（**逐个查**）──────
    //
    // 🔴 接口选择是实测出来的，别再换回去：
    //   · `music.trackInfo.UniformRuleCtrl / CgiGetTrackInfo`
    //     → **code=103901，tracks 为空** ✗（我第一版用了它，白忙）
    //   · `music.pf_song_detail_svr / get_song_detail`
    //     → **code=0，mid 在 `req_1.data.track_info.mid`** ✓
    //
    // ⚠️ 这个接口**只吃单个 `song_id`**（传数组不行），所以只能逐个查。
    //    为了不把列表拖垮，这里：
    //      · 限制一次最多补 [MAX_FILL] 首（其余的播放时再想办法）
    //      · 并发 [FILL_CONCURRENCY] 个请求
    //      · 结果进 [_midCache]
    const MAX_FILL = 30;
    const FILL_CONCURRENCY = 4;
    const todo = ids.slice(0, MAX_FILL);

    let cursor = 0;
    const worker = async () => {
        while (cursor < todo.length) {
            const sid = todo[cursor++];
            try {
                const data = await musicu({
                    comm: { ct: 24, cv: 0 },
                    req_1: {
                        module: 'music.pf_song_detail_svr',
                        method: 'get_song_detail',
                        param: { song_id: sid },
                    },
                });
                // mid 的位置：req_1.data.track_info.mid
                const ti = at(data, 'req_1', 'data', 'track_info');
                const mid = String((ti && (ti.mid || ti.songmid)) || '');
                if (mid) _midCache.set(sid, mid);
            } catch (e) {
                // 单首失败就算了，继续下一首
            }
        }
    };
    await Promise.all(
        Array.from({ length: Math.min(FILL_CONCURRENCY, todo.length) }, worker),
    );

    for (const s of need) {
        const cached = _midCache.get(s.id);
        if (cached) s.songmid = cached;
    }
    return list;
}

/**
 * 榜单里的歌曲（Beans 的 `topListSongs`）。
 *
 * ⚠️ 榜单接口**不给 songmid**（只有数字 songId），所以这里会调
 * [fillSongMids] 补上 —— 否则所有第三方源都拿不到播放地址。
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
        // 🔴 榜单不给 songmid，这里补上（否则第三方源取不到地址）
        await fillSongMids(list);
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

/**
 * **热门歌手**（带真头像）—— 从榜单歌曲里提取去重的歌手。
 *
 * ── 🔴 为什么是"派生"而不是调歌手列表接口 ──────────────────────
 * QQ 没有免登录的歌手列表接口（实测）：
 *   · `music.web_singer_list.SingerListServer` → `code=500003`
 *   · `fcg_v8_singer_track_cp` → HTTP 404
 * 但**歌手头像模板是通的**（`T001R300x300M000{mid}.jpg`），
 * 而歌曲里**带着 singerMid** → 于是"从榜单歌里收集歌手"就能拿到真头像。
 *
 * ⚠️ 头像 URL **不写死尺寸**：Dart 侧显示 64 的圆圈，用 150 就够
 *（省流量），所以这里给 150。
 *
 * @param topId  榜单 id（用榜首的歌手，质量最高）
 * @param limit  取多少个歌手
 * @returns `{ ok, list: [{ name, avatar, mid }] }`
 */
async function topArtistsList(topId, limit = 14) {
    try {
        const n = Math.min(Math.max(limit, 1), 40);
        // 榜单歌曲要多取一些 —— 前 N 首里往往有重复歌手
        const r = await topListSongs(topId || 26, 60);
        if (!r.ok || !r.list.length) {
            return { ok: false, error: r.error || '榜单歌曲为空' };
        }
        const seen = new Set();
        const out = [];
        for (const s of r.list) {
            const mid = String(s.artistMid || '');
            const name = String(s.artist || '').trim();
            if (!mid || !name) continue;
            // 多歌手用顿号拼的，只取第一个（头像只能一张）
            const first = name.split('、')[0].trim();
            if (!first || seen.has(mid)) continue;
            seen.add(mid);
            out.push({ name: first, avatar: artistAvatarURL(mid, '150x150'), mid });
            if (out.length >= n) break;
        }
        return { ok: true, list: out };
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
        // 歌单一般自带 `mid`，但个别条目可能缺 → 同样补齐
        await fillSongMids(list);
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
    topArtistsList,
};
