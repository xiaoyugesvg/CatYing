/**
 * 喜马拉雅（有声书 / 播客）数据源 —— 音乐模块的第三个平台。
 *
 * ── 来源与改写说明 ────────────────────────────────────────────
 * 移植自 OmniBox-Spider 的 `影视/有声/喜马拉雅.js`，但**接口与运行时不兼容**：
 * 那个脚本依赖 `omnibox_sdk` + `spider_runner`（OmniBox 运行时），
 * 本项目没有这两个包。所以这里只**移植它的接口与解析逻辑**，按本工程约定重写。
 *
 * 三个 host（已实测连通，见 scripts/verify-ximalaya.mjs）：
 *   · 分类/专辑：`m.ximalaya.com`      —— /m-revision/page/category/queryCategoryAlbumsByPage
 *   · 专辑单集  ：`mobile.ximalaya.com` —— /mobile/others/ca/album/track/{id}/true/0/200
 *   · 搜索      ：`api.cenguigui.cn`    —— 第三方聚合，**非官方**，会挂会变
 *
 * ⚠️ 播放必须带 UA：集自带的 `playPathAacv164` 是 https 直链，但没 UA 会被拒。
 *    所以 `ximalayaUrl()` 把 headers 一起返回，上层要透传给播放器。
 */
import axios from 'axios';

const UA =
    'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.120 Mobile Safari/537.36';

const HOST = 'https://m.ximalaya.com';
const TRACK_HOST = 'http://mobile.ximalaya.com';
const SEARCH_HOST = 'https://api.cenguigui.cn';

/** 与上游脚本一致：只收免费专辑（vip === 0），避免"点开播不了"。 */
export const XIMALAYA_CATEGORIES = [
    { id: 'youshengshu', name: '有声书' },
    { id: 'ertong', name: '儿童' },
    { id: 'yinyue', name: '音乐' },
    { id: 'xiangsheng', name: '相声' },
    { id: 'yule', name: '娱乐' },
    { id: 'guangbojv', name: '广播' },
    { id: 'lishi', name: '历史' },
    { id: 'waiyu', name: '外语' },
];

const http = axios.create({ timeout: 15000, headers: { 'User-Agent': UA } });

/**
 * trackId → 播放直链。
 *
 * 喜马拉雅的播放地址是**跟着专辑的单集列表一起返回**的（不像酷狗要另外签名换），
 * 所以这里在拿专辑时顺手缓存，播放时直接取。进程内缓存，重启后需要重新进专辑
 * —— 这是本数据源的已知取舍：**搜索结果只给专辑，必须先进专辑才能播**。
 */
const urlCache = new Map();
const albumMeta = new Map(); // albumId → {name, cover, nickname}

function humanize(e) {
    if (e && e.response) return '接口返回 HTTP ' + e.response.status;
    if (e && e.code === 'ECONNABORTED') return '请求超时';
    return '请求失败：' + ((e && e.message) || String(e));
}

function mapAlbum(it) {
    const info = (it && it.albumInfo) || {};
    const cover = String(info.cover || '');
    return {
        id: String(it && it.id ? it.id : ''),
        name: String(info.title || ''),
        // 上游脚本用的是 http://imagev2.xmcdn.com/...；这里统一升级成 https
        //（本项目 ATS 已放行 http，但 https 更稳）
        cover: cover
            ? cover.startsWith('http')
                ? cover
                : `https://imagev2.xmcdn.com/${cover}`
            : '',
        vip: typeof info.albumVipPayType === 'number' ? info.albumVipPayType : -1,
        intro: String(info.intro || ''),
        nickname: String(info.nickname || ''),
    };
}

/** 分类列表（首页/发现用） */
export async function ximalayaCategories() {
    return { ok: true, list: XIMALAYA_CATEGORIES };
}

/** 某个分类下的专辑（分页） */
export async function ximalayaCategory(categoryId, page = 1) {
    const cat = String(categoryId || '').trim();
    if (!cat) return { ok: false, error: '缺少分类' };
    try {
        const r = await http.get(
            `${HOST}/m-revision/page/category/queryCategoryAlbumsByPage`,
            { params: { sort: 0, pageSize: 50, page: Number(page) || 1, categoryCode: cat } },
        );
        const albums = (r.data && r.data.data && r.data.data.albumBriefDetailInfos) || [];
        // ⚠️ **不按 vip 预过滤**（上游脚本的 `vip === 0` 是错的，实测反了）：
        //  - "免费分类里的免费专辑"：单集里 `playPathAacv164/playUrl*` **字段存在但全是空串**
        //    （版权受限）→ 选了也**播不了**；
        //  - 带 vip 标记的专辑：反而**给得出完整 https 直链**。
        // 所以这里全收，把"免费/VIP"只当提示，真正的可播性在**单集层面**判断。
        const list = albums
            .map(mapAlbum)
            .filter((a) => a.id)
            .map((a) => ({ ...a, remark: a.vip === 0 ? '免费' : 'VIP' }));
        return { ok: true, list, total: list.length };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/**
 * 专辑详情：拿全所有单集（上游用 `maxPageId` 分页，必须翻完，
 * 实测一个专辑 `maxPageId=15` —— 只拿第一页会少 200 集之后的全部）。
 * 同时把每集的播放直链塞进 `urlCache`。
 */
export async function ximalayaAlbum(albumId) {
    const aid = String(albumId || '').trim();
    if (!aid) return { ok: false, error: '缺少专辑 id' };
    const base =
        `${TRACK_HOST}/mobile/others/ca/album/track/${aid}/true/0/200?albumId=${aid}`;
    try {
        const first = await http.get(base);
        const j = first.data || {};
        const album = j.album || {};
        const tracks = (j.tracks && j.tracks.list) || [];
        const maxPageId = (j.tracks && j.tracks.maxPageId) || 1;

        const all = tracks.slice();
        for (let p = 2; p <= maxPageId; p++) {
            try {
                const pr = await http.get(base.replace('/0/', `/${p}/`));
                const pt = (pr.data && pr.data.tracks && pr.data.tracks.list) || [];
                all.push(...pt);
            } catch (_) {
                /* 单页失败不放弃整张专辑 */
            }
        }

        const cover = String(album.coverLarge || '');
        albumMeta.set(aid, {
            name: String(album.title || ''),
            cover,
            nickname: String((album.nickname || (album.user && album.user.nickname)) || ''),
        });

        const list = [];
        let skipped = 0; // 没有直链的集数（版权受限）—— 报给上层，别装成功
        for (const t of all) {
            const id = String(t.trackId || t.id || '');
            // ⚠️ 直链字段名**随专辑/接口变体不同**：实测有的专辑给
            // `playPathAacv164`（如"第九特区"），有的那个字段是空的
            //（如"都市狂枭"，导致整张专辑播不了）。所以按常用字段逐个兜底。
            const playUrl = String(
                t.playPathAacv164 ||
                    t.playPathAacv224 ||
                    t.playPath64 ||
                    t.playPath32 ||
                    t.playUrl64 ||
                    t.playUrl32 ||
                    t.src ||
                    t.downloadUrl ||
                    '',
            );
            if (!id) continue;
            // 没有直链的集**不列出来**（否则用户点开只会得到"播不了"）
            if (!playUrl) {
                skipped++;
                continue;
            }
            urlCache.set(id, playUrl);
            list.push({
                // 与网易云/酷狗一致的结构（Dart 侧同一套 Song.fromJson）
                id,
                name: String(t.title || ''),
                artist: String(album.title || ''),
                artistIds: [],
                album: String(album.title || ''),
                albumId: aid,
                cover,
                duration: Math.round((Number(t.duration) || 0) / 1000),
                fee: -1,
                source: 'ximalaya',
            });
        }
        return {
            ok: true,
            album: {
                id: aid,
                name: String(album.title || ''),
                cover,
                nickname: String(album.nickname || ''),
                intro: String(album.intro || ''),
            },
            list,
            total: list.length,
            skipped,
            message: list.length === 0
                ? '该专辑的音频地址为空（通常是版权/会员限制），暂不可播'
                : '',
        };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/**
 * 搜索专辑。
 * ⚠️ 走的是**第三方聚合站** `api.cenguigui.cn`（上游脚本就用它），不是官方接口 ——
 * 它挂了搜索就不可用，但分类/专辑/播放不受影响。
 */
export async function ximalayaSearch(keyword) {
    const kw = String(keyword || '').trim();
    if (!kw) return { ok: false, error: '请输入关键词' };
    try {
        const r = await http.get(`${SEARCH_HOST}/api/music/ximalaya.php`, {
            params: { name: kw },
        });
        const items = (r.data && r.data.data) || [];
        const list = items
            .map((it) => ({
                id: String((it && it.albumId) || ''),
                name: String((it && it.title) || ''),
                cover: String((it && it.cover) || ''),
                artist: String((it && it.nickname) || ''),
            }))
            .filter((a) => a.id);
        return { ok: true, list, total: list.length };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/**
 * 取某一集的播放地址。
 * ⚠️ 依赖 `urlCache` —— 必须先调过 `ximalayaAlbum()`（用户进过专辑）。
 * 直接搜到就播是不行的（搜索接口只回专辑，不回单集直链）。
 */
export async function ximalayaUrl(trackId) {
    const id = String(trackId || '').trim();
    if (!id) return { ok: false, error: '缺少单集 id' };
    const url = urlCache.get(id);
    if (!url) {
        return {
            ok: false,
            error: '没取到这一集的直链：请先进入专辑（地址随专辑列表返回）；'
                + '若进入专辑后仍失败，说明该集只提供会员/加密源',
        };
    }
    return {
        ok: true,
        url,
        type: 'aac',
        // ⚠️ 必须带 UA，否则服务端拒绝 —— 上层要透传给播放器
        headers: { 'User-Agent': UA },
    };
}

/** 自检：不需要联网也能告诉上层"桥接层是否可用" */
export function ximalayaSelfTest() {
    return {
        ok: true,
        platform: 'ximalaya',
        hosts: { category: HOST, track: TRACK_HOST, search: SEARCH_HOST },
        categories: XIMALAYA_CATEGORIES.length,
        cachedUrls: urlCache.size,
        note: '搜索走第三方聚合站（api.cenguigui.cn），非官方接口',
    };
}
