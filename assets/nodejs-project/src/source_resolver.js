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
// MusicFree 插件适配层（独立一套入口，不影响上面的 LX 路径）
import { looksLikeMusicFree, loadMusicFreePlugin, pickMediaGetter, normalizeMedia,
         pickAction, normalizeSearchResult, normalizeLyric } from './musicfree_adapter.js';

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
 * **MusicFree 插件**法解析播放地址。
 *
 * ── 与 LX 脚本法的区别（为什么单独一个函数）──────────────────────
 * | | LX 源 | MusicFree 插件 |
 * |---|---|---|
 * | 注册 | `lx.on('request')` / `module.exports.musicUrl` | `module.exports.getMediaSource` |
 * | 参数 | `(payload)` 富对象 | **`(musicItem, quality)` 两个位置参数** |
 * | 依赖 | 纯脚本 | 几乎都 `require('axios')` |
 * | 返回 | `{url}` | `string` / `{url}` / `{url,headers}` / 数组 |
 *
 * ⚠️ **调用约定必须用位置参数**：MusicFree 的签名是
 * `getMediaSource(musicItem, quality)`，传一个富对象进去它是读不到的。
 *
 * @returns {Promise<{ok, url?, headers?, error?}>}
 */
async function resolveMusicFree(source, song) {
    const script = String(source.script || '');
    if (!script.trim()) {
        return { ok: false, error: '插件没有内容' };
    }

    const loaded = await loadMusicFreePlugin(script, loadScript);
    if (!loaded.ok) {
        return { ok: false, error: loaded.error };
    }
    const getter = pickMediaGetter(loaded.handlers);
    if (!getter) {
        return {
            ok: false,
            error:
                '不是可用的 MusicFree 插件：没找到 getMediaSource / getMusicUrl ' +
                `（它提供：${(loaded.actions || []).join(', ') || '无'}）`,
        };
    }

    // ── musicItem 构造 ────────────────────────────────────────────
    //
    // 🔴 `source` **不能写死**（原来写死 'kw'，是"播放出错 Failed to open
    //    …/kw.php?id=…" 的根因，详见 detectMusicFreePlatform 的注释）。
    //    优先用**插件的真实平台**（从它源码里认），认不出来才退回
    //    歌曲自己的平台。
    const pluginPlatform = detectMusicFreePlatform(script);
    const songPlatform = providerCodeOf(song && song.source);
    const platform = pluginPlatform || songPlatform || 'kw';

    // ── 🔴 `songmid` 用**平台原生字符串 id**，不要拿数字 id 顶替 ──────
    //
    // 这是"QQ 的歌播不了"的第二个根因。实测元力音源 v1.2.1 的取址逻辑：
    //     `GET …/qq_kw.php?id=${musicItem.songmid}&type=json&level=…`
    // 它读的是 **`songmid`**（QQ 的字符串 mid，形如 `0039MnYb0qxYhV`）。
    // 我们原来把数字 songid 塞进 `songmid` → 那个后端查不到 → 返回空
    // → `normalizeMedia` 拿不到 url → **播放失败**。
    //
    // 补上真实 songmid 后，同一后端正常返回真实音频地址。
    //
    // ⚠️ 兜底顺序：songmid → id。前者是平台原生标识（优先），
    //    后者留给"模板法那种只认数字 id"的源。
    const nativeMid = (song && song.songmid ? String(song.songmid) : '').trim();
    const numericId = song && song.id != null ? String(song.id) : '';
    const midForPlugin = nativeMid || numericId;

    // ── 空 id 直接失败，别拿去查 ────────────────────────────────
    //
    // ⚠️ 原来没有这个检查：`songmid` 为空串时会请求
    //    `…/qq_kw.php?id=&type=json` → 后端可能**返回一首随机的歌**
    //    （或空）→ 用户听到**别人的歌**（最糟的失败方式：不报错但是错的）。
    // 宁可明确失败，也不要播错。
    if (!midForPlugin) {
        return {
            ok: false,
            error: '这首歌没有可用的 id（缺 songmid，换源接口无法识别）',
        };
    }

    const buildItem = (id, extra) => {
        const v = id != null ? String(id) : '';
        return {
            id: v,
            // ── 🔴 同一个原生 id 要塞进**所有**常见字段名 ──────────────
            //
            // 各家插件读的字段名不一样（实测）：
            //   · 元力音源   → `musicItem.songmid`
            //   · 星海音乐源 → 报错文案就是"**缺少 songmid 或 hash**"
            //                 → 它**两个都认**，但必须有一个有值
            //   · 酷狗系插件 → `hash`
            // 所以这里把同一个值同时写进 songmid / hash / mid，
            // **不要**只写一个 —— 那会让"换个插件就播不了"。
            //（代价只是几个重复字段，换来跨插件兼容。）
            songmid: v,
            hash: v,
            mid: v,
            name: song && song.name ? String(song.name) : '',
            singer: song && song.artists ? String(song.artists) : '',
            artist: song && song.artists ? String(song.artists) : '',
            album: song && song.album ? String(song.album) : '',
            source: platform,
            ...(extra || {}),
        };
    };

    // 首选 item：**原生 mid 给 songmid**，数字 id 也给 id（两派都满足）
    const musicItem = buildItem(midForPlugin);
    const quality = (source && source.quality) || '320k';

    const invoke = (item) => runAction(
        { [getter.name]: getter.fn },
        getter.name,
        [item, quality],
        // ⚠️ **必须 spread**：MusicFree 签名是 `(musicItem, quality)`
        // 两个位置参数，不是 LX 那样的单个富对象。
        { spread: true },
    );

    let r = await invoke(musicItem);
    let usedSelfSearch = false;

    // ── 自搜回退（🔴 让"跨平台的源"能真的用起来）──────────────────
    //
    // 场景：用户播 **QQ** 的歌，而他的源是**酷我专源**插件。
    // 直接把 QQ 的 id 交给酷我后端 → 查不到（id 不通用）。
    // 但插件**自己有 search** → 用它搜出**酷我自己的 id** → 再解析。
    //
    // ⚠️ 这与"跨平台匹配用户明确关掉"不冲突：
    //    那条指的是"**App 自己去别的平台找歌**"（CrossPlatformMatcher）；
    //    这里是"**这一个源自己决定怎么服务这首歌**"，仍然只在这个源内部，
    //    不引入任何别的源，也不弹额外界面。
    //
    // 只在第一轮失败时做，且要求插件确实有 search（没有就保持原错误）。
    // ── 判断"这个结果可信吗"────────────────────────────────────────
    //
    // ⚠️ **不能只看 `r.ok`**：惰性插件（只拼 URL）无论 id 对不对都返回
    //    `ok:true`。所以跨平台时**真的探一次地址**，看它是否返回音频。
    //
    // 只在**平台不匹配**时探测（= 很可能拿到坏 URL 的唯一情形）：
    //   · 插件是酷我，歌来自酷我 → id 通用，不必多一次请求
    //   · 插件是酷我，歌来自 QQ  → id 不通用 → 必须探
    const crossPlatform = !!pluginPlatform && !!songPlatform &&
        pluginPlatform !== songPlatform;

    let needFallback = !r.ok;
    if (!needFallback && crossPlatform) {
        const media0 = normalizeMedia(r.result);
        if (media0 && media0.url) {
            const alive = await probePlayable(media0.url, media0.headers);
            if (!alive) {
                needFallback = true;
            }
        }
    }

    if (needFallback && (song && song.name)) {
        const sp = pickAction(loaded.handlers, 'search');
        if (sp) {
            try {
                // ── 先试"歌名 + 歌手"，不行再试"只要歌名" ──────────
                // 加了歌手反而搜不到的情况很常见（歌手名写法不一致）
                const tries = [
                    [song.name, song.artists].filter(Boolean).join(' ').trim(),
                    String(song.name).trim(),
                ];
                for (const keyword of tries) {
                    if (!keyword) continue;
                    const sr = await runAction(
                        { [sp.name]: sp.fn }, sp.name,
                        [keyword, 1, 'music'], { spread: true },
                    );
                    if (!sr.ok) continue;
                    const cand = normalizeSearchResult(sr.result).list || [];
                    // 逐个候选试（第一首未必对，但通常前几个里就有）
                    for (const c of cand.slice(0, 3)) {
                        const alt = buildItem(c.id, {
                            name: c.name || (song && song.name) || '',
                            singer: c.artist || (song && song.artists) || '',
                            artist: c.artist || (song && song.artists) || '',
                            album: c.album || (song && song.album) || '',
                        });
                        const r2 = await invoke(alt);
                        if (!r2.ok) continue;
                        const m2 = normalizeMedia(r2.result);
                        if (!m2 || !m2.url) continue;
                        // 自搜出来的地址**也要探**（同一个后端，同样会 404）
                        if (!(await probePlayable(m2.url, m2.headers))) continue;
                        r = r2;
                        usedSelfSearch = true;
                        break;
                    }
                    if (usedSelfSearch) break;
                }
            } catch (e) {
                // 自搜失败不该盖掉原始错误 —— 原始错误更有诊断价值
            }
        }
    }

    if (!r.ok) {
        return { ok: false, error: r.error };
    }

    const media = normalizeMedia(r.result);
    if (!media) {
        return {
            ok: false,
            error: '插件没返回可用的播放地址（支持 string / {url} / {url,headers} / 数组）',
        };
    }
    return { ok: true, url: media.url, headers: media.headers };
}

/**
 * MusicFree 插件的**非取址 action**（搜索 / 歌词）。
 *
 * ── 为什么单独一个函数而不是塞进 resolveMusicFree ────────────────
 * 两者签名与返回形态完全不同：
 *   · `getMediaSource(musicItem, quality)` -> `{url, headers}`
 *   · `search(query, page, type)`          -> `{isEnd, data:[musicItem]}`
 *   · `getLyric(musicItem)`                -> `{lyric, tlyric}`
 * 混在一起会让"参数怎么传"变得不可读（位置参数个数都不一样）。
 *
 * @param action 'search' | 'lyric'
 * @param args   该 action 的位置参数
 */
async function resolveMusicFreeAction(source, action, args) {
    const script = String(source.script || '');
    if (!script.trim()) return { ok: false, error: '插件没有内容' };

    const loaded = await loadMusicFreePlugin(script, loadScript);
    if (!loaded.ok) return { ok: false, error: loaded.error };

    const picked = pickAction(loaded.handlers, action);
    if (!picked) {
        const want = action === 'search' ? 'search' : 'getLyric';
        return {
            ok: false,
            error:
                `该 MusicFree 插件不支持 ${action}（缺 ${want}）` +
                `；它提供：${(loaded.actions || []).join(', ') || '无'}`,
        };
    }

    const r = await runAction({ [picked.name]: picked.fn }, picked.name, args, {
        spread: true,
    });
    if (!r.ok) return { ok: false, error: r.error };

    if (action === 'search') {
        const n = normalizeSearchResult(r.result);
        return { ok: true, list: n.list, isEnd: n.isEnd };
    }
    if (action === 'lyric') {
        const n = normalizeLyric(r.result);
        return { ok: true, lyric: n.lyric, tlyric: n.tlyric };
    }
    return { ok: false, error: '未知 action: ' + action };
}

/**
 * MusicFree 插件的**搜索**。
 * 签名：`search(query, page, type)` —— `type` 默认 'music'。
 */
export async function searchByMusicFree(source, keyword, page = 1, type = 'music') {
    return resolveMusicFreeAction(source, 'search', [String(keyword || ''), page, type]);
}

/**
 * MusicFree 插件的**歌词**。
 * 签名：`getLyric(musicItem)`。
 */
export async function lyricByMusicFree(source, song) {
    const musicItem = {
        id: song && song.id != null ? String(song.id) : '',
        title: song && song.name ? String(song.name) : '',
        artist: song && song.artists ? String(song.artists) : '',
        album: song && song.album ? String(song.album) : '',
        duration: (song && song.duration) || 0,
    };
    return resolveMusicFreeAction(source, 'lyric', [musicItem]);
}

/** 判断一份脚本是否该走 MusicFree 适配层 */
export function isMusicFreeScript(script) {
    return looksLikeMusicFree(script);
}

/**
 * 快速判断一个播放地址**真的能取到音频**吗。
 *
 * ── 🔴 为什么必须有这一步（关键）────────────────────────────────
 * 很多插件（如裤佬SVIP）的 `getMediaSource` 是**惰性的**：
 * 它**只拼 URL 字符串**，不做任何请求 —— 所以无论 id 对不对，
 * 它都**返回成功**（`ok:true` + 一个 URL）。
 *
 * 实测：
 *   QQ 歌 id 102326316 交给酷我插件
 *   → 返回 `https://music.nxinxz.com/kw.php?id=102326316&…`
 *   → **那个地址 GET 回来是 HTTP 404**
 *
 * 于是"用 `r.ok` 判断成功"是**看不出来的**，自搜回退也永远不会触发。
 * 所以跨平台时**必须真的探一下**这个地址。
 *
 * 用 `Range: bytes=0-1` 只取 2 字节：既能确认服务端有音频，
 * 又不会把整首歌拉下来（几 MB 变几千字节）。
 */
async function probePlayable(url, headers) {
    try {
        const r = await axios.get(url, {
            headers: { ...(headers || {}), Range: 'bytes=0-1' },
            timeout: 8000,
            responseType: 'arraybuffer',
            // 404/403 交给下面判断，不抛到外面（这是"探测"，不是"取数据"）
            validateStatus: null,
            maxRedirects: 5,
        });
        const status = r.status || 0;
        // 206 = 服务端接受了 Range（说明是真实文件流）；200 = 也接受
        if (status < 200 || status >= 300) return false;

        const ct = String((r.headers && r.headers['content-type']) || '').toLowerCase();

        // ── 🔴 实测：同一个后端对不同歌返回**不同 content-type** ────────
        //   id=6353348 → `application/octet-stream`（**能播**，2590774 字节）
        //   id=228908 → `audio/mpeg`            （能播，4317292 字节）
        // 所以 `octet-stream` **必须算通过** —— 它正是"这是二进制流"的
        // 显式声明。原来只认 audio/* 或魔数，把 octet-stream 判成了失败
        //（结果：明明能播的歌走了自搜回退，白白多花几秒）。
        if (/audio|octet-stream|mpeg|mp3|flac|m4a|aac|ogg/.test(ct)) return true;

        // ── 明确是网页/错误页 → 失败 ──────────────────────────────
        // 这个后端查不到歌时就是回 404，有的还会回 html 错误页
        if (/text\/html|application\/json|text\/plain/.test(ct)) return false;

        // ── content-type 缺失或没见过的：看字节特征 ────────────────
        const buf = Buffer.from(r.data || []);
        if (buf.length >= 2) {
            const isMp3 = buf[0] === 0xff && (buf[1] & 0xe0) === 0xe0;
            const isId3 = buf.slice(0, 3).toString() === 'ID3';
            const isFlac = buf.slice(0, 4).toString() === 'fLaC';
            const isOgg = buf.slice(0, 4).toString() === 'OggS';
            if (isMp3 || isId3 || isFlac || isOgg) return true;
        }
        // 2xx + Range 生效（有 Content-Range）= 服务端当文件在服务
        if (r.headers && r.headers['content-range']) return true;
        return false;
    } catch (e) {
        return false;
    }
}

/**
 * 从 MusicFree 插件**源码**里认它属于哪个平台。
 *
 * ── 🔴 为什么必须认（这是一个真实的播放失败原因）───────────────
 * 插件拿到的是 `musicItem`，而 `musicItem.source` 决定它去**哪个平台**
 * 查这首歌。原来这里**写死 `'kw'`（酷我）**，于是：
 *   · 用户播一首 **QQ 的**《Sold Out》(id 102326316)
 *   · 插件被当成酷我请求：`music.nxinxz.com/kw.php?id=102326316`
 *   · **酷我里没有这个 id** → 后端 HTTP 404
 *   · 表现：`播放出错：Failed to open https://…/kw.php?id=…` ✗
 * 用户看到的是"播放失败"，但根因是**平台给错了**。
 *
 * ── 怎么认（实测的插件写法）──────────────────────────────────
 * 酷我专源插件（裤佬SVIP）里长这样：
 *     `const API_PATHS = { kw: '/kw.php', … }`
 *     `const url = \`https://music.ninxz.com${API_PATHS.kw}?id=…\``
 * 即**平台码出现在 API 路径里**。所以按"出现次数最多"投票，
 * 而不是只看第一个命中（插件里往往同时出现多个平台码）。
 *
 * @returns 'kw' | 'wy' | 'tx' | 'kg' | 'mg'，认不出来时返回 ''
 */
function detectMusicFreePlatform(script) {
    const s = String(script || '');
    if (!s) return '';
    // 平台码 → 该码在源码里出现的次数
    const score = {};
    // ① API 路径形式：'/kw.php' / '/wy.php' / 'API_PATHS.kg'
    for (const m of s.matchAll(/[/.]\s*(kw|wy|tx|kg|mg)\s*(?:\.php|\.json)?/gi)) {
        const k = m[1].toLowerCase();
        score[k] = (score[k] || 0) + 1;
    }
    // ② 显式平台名：'kuwo' / 'netease' / 'qq' / 'kugou'
    const named = { kuwo: 'kw', netease: 'wy', qq: 'tx', kugou: 'kg', migu: 'mg' };
    for (const [word, code] of Object.entries(named)) {
        const n = (s.match(new RegExp(word, 'gi')) || []).length;
        if (n > 0) score[code] = (score[code] || 0) + n;
    }
    let best = '', bestN = 0;
    for (const [code, n] of Object.entries(score)) {
        if (n > bestN) { best = code; bestN = n; }
    }
    return best;
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
        // ── 🔴 原生标识必须进 musicInfo（这是"星海报缺少 songmid 或 hash"
        //    的根因）────────────────────────────────────────────────
        //
        // LX 脚本读的是 **`musicInfo.hash` / `musicInfo.songmid`**：
        //   星海音乐源 v2.3.14 的原话就是「缺少 songmid 或 hash」，
        //   酷狗的歌必须给 `hash`（它的原生标识不是数字 id）。
        //
        // 这个对象原来**只有 `id`** —— 于是：
        //   · QQ 歌：脚本拿不到 songmid（数字 id 没用）
        //   · 酷狗歌：脚本拿不到 hash → 直接抛「缺少 songmid 或 hash」
        // 而 MusicFree 那条路早就带上了，**只有 LX 这条路漏了**。
        //
        // 同一个值写三个名字（songmid / hash / mid），因为各家脚本读法不同；
        // 有 `song.songmid`（Dart 已把各平台原生 id 统一进这个字段）就用它，
        // 否则退回数字 id。
        songmid: (song && song.songmid) ? String(song.songmid) : id,
        hash: (song && song.songmid) ? String(song.songmid) : id,
        mid: (song && song.songmid) ? String(song.songmid) : id,
        name,
        songName: name,
        // 有的脚本读 `title`
        title: name,
        singer: singers,
        artist: singers,
        artists: singers ? singers.split(/[、/,&]/).map((s) => s.trim()).filter(Boolean) : [],
        album,
        albumName: album,
        // 时长（秒）—— 部分脚本用它做匹配/校验
        duration: (song && song.duration) || 0,
        interval: (song && song.duration) || 0,
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
    // ── 三种 kind 分派 ────────────────────────────────────────────
    //   'musicfree' —— MusicFree 插件（走独立适配层，注入 axios/he）
    //   'script'    —— LX 脚本（纯沙箱，**不注入任何模块**）
    //   'keyword'   —— 模板法
    //
    // ⚠️ 显式 kind 优先；没写 kind 时按"像不像 MusicFree 插件"自动判定，
    // 但**只有看起来像才走适配层** —— LX 源的行为一点不变。
    const isScript = source.kind === 'script' || (!source.kind && source.script && !looksLikeMusicFree(source.script));
    const isMusicFree = source.kind === 'musicfree' ||
        (!source.kind && source.script && looksLikeMusicFree(source.script));
    const kind = isMusicFree ? 'musicfree' : (isScript ? 'script' : 'keyword');
    const r =
        kind === 'musicfree'
            ? await resolveMusicFree(source, song)
            : (kind === 'script'
                ? await resolveByScript(source, song)
                : await resolveByTemplate(source, song));
    return Object.assign({ kind }, r);
}

// ⚠️ searchByMusicFree / lyricByMusicFree 已经在声明处 `export async function`
// 导出过了 —— 不要在这里重复列出（重复导出是 SyntaxError）。
export { resolveSource, resolveByTemplate, resolveByScript, fillTemplate, pickByPath };
