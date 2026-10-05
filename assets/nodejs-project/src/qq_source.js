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

/** 把 client_search_cp 的歌曲条目映射成统一结构 */
function mapSong(item) {
    if (!item || !item.songmid) return null;
    const songid = Number(item.songid) || 0;
    const mid = String(item.songmid);
    const mediaMid = String(
        (item.file && item.file.media_mid) || item.strMediaMid || item.media_mid || ''
    );
    const singers = Array.isArray(item.singer) ? item.singer : [];
    const pay = item.pay || {};
    const fee = Number(item.fee != null ? item.fee : (pay.pay_play != null ? pay.pay_play : (pay.payplay || 0)));
    const m = {
        // 对外 id 用数字 songid（Dart Song.id 是 int）
        id: songid,
        name: String(item.songname || ''),
        artist: singers.map((s) => s && s.name).filter(Boolean).join('、'),
        album: String(item.albumname || item.albumName || ''),
        albumId: String(item.albummid || item.albumMID || ''),
        cover: coverURL(item.albummid || item.albumMID),
        duration: Number(item.interval) || 0,
        fee,
        songmid: mid,
        mediaMid,
    };
    return m;
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
};
