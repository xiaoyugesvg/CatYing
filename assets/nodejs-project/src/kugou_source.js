/**
 * 酷狗音乐数据源（KuGou）—— ESM 桥接层
 *
 * ── 这个文件干什么 ────────────────────────────────────────────────
 * 把第三方库 KuGouMusicApi（CommonJS）包成与 `music_source.js` 里网易云实现
 * **完全一致**的对外结构，供 `/music/api` 按 `body.source` 分派调用。
 *
 * 上游：https://github.com/MakcRe/KuGouMusicApi
 *       版本 1.6.2 / commit da5ccfd9304c043085a2fd18e94ebc5c315044ab / MIT
 *       代码原样放在 `assets/nodejs-project/vendor/kugou/`（构建期加载，
 *       不随 App 分发；版权与许可见 vendor/kugou/LICENSE 与 README.md）
 *
 * ── 怎么加载上游的 CJS（踩过两次坑，别改回去）──────────────────
 * 本工程 `package.json` 是 `"type": "module"`，而上游是 CommonJS；
 * `vendor/kugou/package.json` 里写了 `{"type":"commonjs"}` 让它能被 require。
 *
 * ⚠️ 但**不能**用 `createRequire(import.meta.url)` 去 require vendor：
 *   1) esbuild 产物是 `format: 'cjs'`，此时 `import.meta` 为空对象，
 *      `createRequire(undefined)` 会在**模块加载期**抛异常 —— 整个
 *      `dist/main.js` 直接打挂（App 起不来）。esbuild 会明确警告：
 *      "import.meta" is not available with the "cjs" output format。
 *   2) 更隐蔽的：**esbuild 无法静态分析 `createRequire()` 造出来的 require**。
 *      产物里会原样留下 `Cannot find module '../vendor/kugou/util/util.js'`
 *      （设备上没有 `vendor/` 目录）—— 已在 `dist/main.js` 上实测复现。
 *
 * ✅ 正确做法：用**全局 `require()` + 字面量路径**（见 `vendorRequire` /
 *    `depRequire` 里每个 case）。esbuild 会静态解析并把上游代码 inline 进 bundle。
 *    本文件被 `scripts/verify-*.mjs` 当 ESM 直跑时没有全局 require，
 *    由 `require2()` 兜底（`require2` 是普通函数名，esbuild 不会去解析它
 *    内部的字符串，所以不会被误当成外部依赖）。
 *
 * ── 设备身份 bootstrap（关键）────────────────────────────────────
 * 上游 `util/request.js` 从 `options.cookie` 取设备标识：
 *   · `KUGOU_API_MID` —— 设备 mid（请求参数与请求头都带）
 *   · `dfid`          —— 设备指纹，由 `module/register_dev.js` 向
 *                        userservice.kugou.com/risk/v2/r_register_dev 注册得到
 *   · `token`/`userid` —— 登录态（本桥接层**不登录**，恒为空）
 * 上游 `server.js` 的注入逻辑（本文件复刻）：
 *   1. `guid = MD5(uuid4())`         —— 32 位 hex 设备 GUID
 *   2. `mid  = calculateMid(guid)`   —— MD5(guid) 当 16 进制大整数转十进制字符串
 *   3. 首次向酷狗注册拿 `dfid`
 * 这些值**持久化到 App 可写目录**，避免每次启动换 mid 被服务端拒绝：
 *   `<DSH_DATA_DIR>/music/kugou_device.json`
 *   （Dart 侧把数据目录注入为 `DSH_DATA_DIR`；缺失时退到
 *     `%LOCALAPPDATA%` / `~/.local/share` 下的 `NewTv`）
 *
 * ── 不写任何账号/密码/Token ─────────────────────────────────────
 * 本文件与持久化文件里都没有账号凭据；`token`/`userid` 始终为空字符串/0。
 *
 * ── 与网易云的差异（如实说明，不假装）──────────────────────────
 *   · 播放地址：只有**免费曲目**能拿到 url。`song_url` 返回 `url` 数组为空
 *     且带 `fail_process: ['pkg','buy']` 时，按契约返回
 *     `{ok:true, url:'', reason:'no_free_source', message}`（与网易云一致）。
 *   · 搜索结果是**扁平**的（网易云按综合分组），本层统一映射成同一结构。
 *   · 歌词：酷狗没有网易云那种独立的翻译通道，`tlyric` 恒为空字符串。
 *   · `comments` / `simiSongs` / `personalized` 等本层**不实现**，
 *     由 `music_source.js` 对该 source 返回 `{ok:false, error:'酷狗暂不支持该接口'}`。
 *
 * @module kugou_source
 */

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { KUGOU_VENDOR, KUGOU_DEPS } from './kugou_vendor.js';

// ────────────────────────────────────────────────────────────────
// 0. 网络/运行环境准备
//    上游 `util/runtime.js` 只认 `KUGOU_API_PROXY`；设备上必须是直连，
//    所以除非显式给了 `KUGOU_BRIDGE_PROXY`（本机验证脚本会用），否则一律清空，
//
//    ⚠️ 这里**刻意不碰** `NODE_USE_ENV_PROXY`：Node 运行时是
//    **影视 spider / 阅读书源 / 音乐 共用的同一个进程**，而它是**全进程**级开关
//    —— 改它会影响影视与阅读的出网方式（用户明确要求别影响它们）。
//    酷狗自己的代理只需 `KUGOU_API_PROXY`（只有上游 vendor 读它）。
//
//    🔧 修复：酷狗默认直连，但部分网络下酷狗接口会被拒/超时。
//    「有代理就用代理」—— 跟随全局 `HTTP_PROXY`/`HTTPS_PROXY`
//    （用户配了系统代理/环境代理时酷狗自动走代理；没配就直连，
//    行为与之前完全一致）。优先级：KUGOU_BRIDGE_PROXY > 全局代理 > 直连。
// ────────────────────────────────────────────────────────────────
const BRIDGE_PROXY = String(process.env.KUGOU_BRIDGE_PROXY || '').trim();
const GLOBAL_PROXY = String(
    process.env.HTTP_PROXY || process.env.http_proxy ||
    process.env.HTTPS_PROXY || process.env.https_proxy || ''
).trim();
if (BRIDGE_PROXY) {
    process.env.KUGOU_API_PROXY = BRIDGE_PROXY;
} else if (GLOBAL_PROXY) {
    process.env.KUGOU_API_PROXY = GLOBAL_PROXY;
} else {
    delete process.env.KUGOU_API_PROXY;
}
// 标准版（非概念版 lite）：决定签名盐/appid/clientver
process.env.platform = '';

// ────────────────────────────────────────────────────────────────
// 0b. require 通道
//
// esbuild 只会静态解析**字面量** `require('...')`。
//   · 在 CJS bundle 里：`require` 是全局的，下面所有字面量 require 会被 inline；
//   · 在 ESM 直跑（scripts/verify-*.mjs）里：没有全局 `require`，用
//     `require2()` 通过 `node:module` 的 createRequire 现场造一个。
//     （`require2(...)` 是普通函数调用，esbuild 不会去解析里面的字符串，
//      所以不会试图从 bundle 外部加载 vendor —— 那正是我们要避免的。）
// ────────────────────────────────────────────────────────────────

/** ESM 直跑时的 require 实现（CJS bundle 下恒为 null） */

// （原 require2() 已删除：它让 esbuild 看不见 vendor 路径，导致 vendor 既没
//  进 bundle 也没随包发 → 设备上 Cannot find module。现在统一走
//  kugou_vendor.js 的字面量 import。）

/**
 * 加载 `vendor/kugou/util/*.js`（上游 CJS）。
 * ⚠️ 下面每个 `require2('字面量')` 都必须保持字面量，esbuild 才能静态打包。
 */
function vendorRequire(rel) {
    const m = KUGOU_VENDOR[rel];
    if (!m) throw new Error('未登记的上游模块：' + rel);
    return m;
}

/** 第三方依赖（同样必须字面量） */
function depRequire(name) {
    const m = KUGOU_DEPS[name];
    if (!m) throw new Error('未登记的依赖：' + name);
    return m;
}

// 上游版本信息（报告/自检用）
const UPSTREAM = {
    repo: 'https://github.com/MakcRe/KuGouMusicApi',
    version: '1.6.2',
    commit: 'da5ccfd9304c043085a2fd18e94ebc5c315044ab',
    license: 'MIT (c) 2023 MakcRe',
};

/** 依赖清单：上游 util/ 真正 require 的非内置包 */
const REQUIRED_DEPS = ['axios', 'crypto-js', 'node-forge', 'big-integer', 'pako'];

// ────────────────────────────────────────────────────────────────
// 1. 持久化目录
// ────────────────────────────────────────────────────────────────

/**
 * 解析 App 的可写数据目录。
 * 优先用 Dart 注入的 `DSH_DATA_DIR`（`nodejs_manager` 启动 Node 时设置），
 * 否则退到系统常规位置 —— 保证"同一台设备上 mid 不变"。
 */
function resolveDataDir() {
    const fromEnv = String(process.env.DSH_DATA_DIR || '').trim();
    if (fromEnv) return fromEnv;
    if (process.platform === 'win32') {
        return path.join(
            process.env.LOCALAPPDATA || process.env.APPDATA || os.tmpdir(),
            'NewTv',
        );
    }
    if (process.platform === 'darwin') {
        return path.join(process.env.HOME || os.homedir(), 'Library', 'Application Support', 'NewTv');
    }
    return path.join(process.env.XDG_DATA_HOME || path.join(process.env.HOME || os.homedir(), '.local', 'share'), 'NewTv');
}

const DEVICE_DIR = path.join(resolveDataDir(), 'music');
const DEVICE_FILE = path.join(DEVICE_DIR, 'kugou_device.json');

// ────────────────────────────────────────────────────────────────
// 2. 延迟加载上游（CJS）
// ────────────────────────────────────────────────────────────────

/** @type {Record<string, any>|null} */
let upstream = null;

/**
 * 加载上游 util/module。只加载本层真正用到的文件
 * （`vendorRequire` 的每个字面量 require 都会被 esbuild inline 进 bundle）。
 */
function loadUpstream() {
    if (upstream) return upstream;
    upstream = {
        util: vendorRequire('util/util.js'),
        crypto: vendorRequire('util/crypto.js'),
        request: vendorRequire('util/request.js'),
        // 每个接口一个文件；server.js 的调用约定是 module(params, useAxios)
        mod: {
            searchSong: vendorRequire('module/search.js'),
            searchComplex: vendorRequire('module/search_complex.js'),
            registerDev: vendorRequire('module/register_dev.js'),
            songUrl: vendorRequire('module/song_url.js'),
            searchLyric: vendorRequire('module/search_lyric.js'),
            lyric: vendorRequire('module/lyric.js'),
            rankList: vendorRequire('module/rank_list.js'),
            rankAudio: vendorRequire('module/rank_audio.js'),
            rankInfo: vendorRequire('module/rank_info.js'),
            topPlaylist: vendorRequire('module/top_playlist.js'),
            playlistDetail: vendorRequire('module/playlist_detail.js'),
            playlistTrackAll: vendorRequire('module/playlist_track_all.js'),
            searchHot: vendorRequire('module/search_hot.js'),
            topSong: vendorRequire('module/top_song.js'),
        },
    };
    return upstream;
}

/** server.js 里传给每个 module 的请求工厂（这里不注入 IP 透传） */
const useAxios = (config) => loadUpstream().request.createRequest(config);

// ────────────────────────────────────────────────────────────────
// 3. 设备身份：加载 / 生成 / 持久化
// ────────────────────────────────────────────────────────────────

/** 内存中的设备身份（进程级缓存） */
let device = null;

function readDeviceFile() {
    try {
        if (!fs.existsSync(DEVICE_FILE)) return null;
        const raw = JSON.parse(fs.readFileSync(DEVICE_FILE, 'utf8'));
        if (raw && raw.guid && raw.mid) return raw;
        return null;
    } catch {
        return null;
    }
}

function writeDeviceFile(d) {
    try {
        fs.mkdirSync(DEVICE_DIR, { recursive: true });
        const tmp = DEVICE_FILE + '.tmp';
        fs.writeFileSync(tmp, JSON.stringify(d, null, 2), 'utf8');
        fs.renameSync(tmp, DEVICE_FILE);
        return true;
    } catch {
        return false;
    }
}

/**
 * 取设备身份（同步，不联网）：
 *   1. 内存缓存 → 2. 磁盘文件 → 3. 新生成 guid/mid/webgl 并落盘
 * 生成算法与上游 `server.js` 一致：
 *   guid = MD5(randomUUID v4)   `app.js`/`server.js` 用的就是 `cryptoMd5(getGuid())`
 *   mid  = calculateMid(guid)   MD5(guid) 当 16 进制大整数转十进制
 */
function getDevice() {
    if (device) return device;
    const { util, crypto } = loadUpstream();

    const saved = readDeviceFile();
    if (saved) {
        device = {
            guid: String(saved.guid),
            mid: String(saved.mid),
            webgl: String(saved.webgl || util.generateWebGLHash()),
            dev: String(saved.dev || util.randomString(10).toUpperCase()),
            mac: String(saved.mac || '02:00:00:00:00:00'),
            dfid: String(saved.dfid || ''),
            createdAt: saved.createdAt || Date.now(),
            from: 'file',
        };
    } else {
        const guid = crypto.cryptoMd5(util.getGuid());
        device = {
            guid,
            mid: util.calculateMid(guid),
            webgl: util.generateWebGLHash(),
            dev: util.randomString(10).toUpperCase(),
            mac: '02:00:00:00:00:00',
            dfid: '',
            createdAt: Date.now(),
            from: 'generated',
        };
        writeDeviceFile(device);
    }

    // 上游 request.js 通过 process.env.platform 判 lite；device 本身走 cookie
    process.env.KUGOU_API_GUID = device.guid;
    process.env.KUGOU_API_DEV = device.dev;
    process.env.KUGOU_API_MAC = device.mac;
    return device;
}

/** 上游每个请求要吃的 cookie（设备标识 + 登录态占位） */
function baseCookie() {
    const d = getDevice();
    return {
        KUGOU_API_MID: d.mid,
        KUGOU_API_GUID: d.guid,
        KUGOU_API_DEV: d.dev,
        KUGOU_API_MAC: d.mac,
        KUGOU_API_WEBGL: d.webgl,
        dfid: d.dfid || '-',
        // 明确不登录
        token: '',
        userid: 0,
    };
}

/**
 * 首次（或 dfid 失效）时向酷狗注册设备指纹。
 * 必须在"取播放地址/搜索"之前完成，否则酷狗会回 `需要验证`（error_code 152 之类的参数错误）。
 * 失败不抛：退回 dfid='-'，让调用方拿到真实失败原因（不假装成功）。
 */
async function ensureDfid() {
    const d = getDevice();
    if (d.dfid) return d;

    const cookie = baseCookie();
    cookie.dfid = '-';
    try {
        const res = await loadUpstream().mod.registerDev(
            // imei/uuid 用 guid 兜底，与上游 server.js 的 cookie 注入一致
            { cookie, imei: d.guid, uuid: d.guid },
            useAxios,
        );
        const dfid = res && res.body && res.body.data && res.body.data.dfid;
        if (dfid) {
            d.dfid = String(dfid);
            d.dfidAt = Date.now();
            writeDeviceFile(d);
        }
    } catch {
        // 注册失败：保持 dfid 为空，调用方会看到真实的接口报错
    }
    return d;
}

// ────────────────────────────────────────────────────────────────
// 4. 响应归一化 / 错误信息
// ────────────────────────────────────────────────────────────────

/**
 * 上游 `createRequest` 用 `JSON.parse(body.toString())` 解析响应，
 * 但酷狗搜索类接口会返回 `<!--KG_TAG_RES_START-->{...}<!--KG_TAG_RES_END-->`，
 * 于是 `body` 会是一个**字符串**。这里统一剥壳解析。
 */
function bodyOf(res) {
    let b = res && res.body;
    if (typeof b === 'string') {
        const s = b
            .replace(/^\s*<!--KG_TAG_RES_START-->/, '')
            .replace(/<!--KG_TAG_RES_END-->\s*$/, '')
            .trim();
        try {
            b = JSON.parse(s);
        } catch {
            b = null;
        }
    }
    return b && typeof b === 'object' ? b : null;
}

/** 把上游/网络异常转成能看懂的短句（与网易云的 humanize 同风格） */
function humanize(e) {
    // 上游 createRequest 失败时会 reject 一个 {status, body, cookie, headers}
    const b = bodyOf(e);
    if (b) {
        const msg = b.error_msg || b.errmsg || b.msg || b.error;
        if (typeof msg === 'string' && msg) return msg;
        if (b.error_code && b.error_code !== 0) return '酷狗接口错误 ' + b.error_code;
        if (b.status === 0) return '酷狗接口返回失败';
    }
    // 上游网络异常时 answer.body = { status: 0, msg: <Error> }
    const inner = e && e.body && e.body.msg;
    if (inner) {
        if (typeof inner === 'string') return inner;
        if (typeof inner.message === 'string' && inner.message) return '请求失败：' + inner.message;
        if (inner.response && inner.response.status) return '接口返回 HTTP ' + inner.response.status;
    }
    if (e && e.code === 'ECONNABORTED') return '请求超时';
    if (e && e.status === 502) return '酷狗接口返回失败';
    if (e && typeof e.message === 'string' && e.message) return '请求失败：' + e.message;
    return '请求失败';
}

// ────────────────────────────────────────────────────────────────
// 5. 字段映射（→ 与网易云实现完全一致的结构）
// ────────────────────────────────────────────────────────────────

/**
 * 酷狗 /api/v3/search/song 的扁平 item → 统一歌曲结构。
 *
 * `id` 用 **album_audio_id**：它是酷狗侧唯一且稳定的数字 id，
 * 而 Dart 的 `Song.id` 是 `int`、`songUrl(id)` 只把 id 原样回传，
 * 所以 id 必须是能"自解释"的数字（详见 songUrl 的注释）。
 */
function mapSongItem(s) {
    if (!s) return null;
    const id = s.album_audio_id || s.audio_id || s.mixsongid || s.EMixSongID;
    if (!id) return null;

    const authors = Array.isArray(s.authors) ? s.authors : [];
    const artistIds = authors
        .map((a) => a && a.author_id)
        .filter(Boolean)
        .map((x) => String(x));
    const singer = s.singername || s.author_name || s.show_author_name || authors.map((a) => a && a.author_name).filter(Boolean).join('、');

    const cover = (s.trans_param && s.trans_param.union_cover) || s.album_sizable_cover || s.img || s.cover || '';

    // 时长：搜索接口是秒，新歌/榜单是毫秒
    const rawDur = s.duration != null ? Number(s.duration) : Number(s.timelength || s.timelength_128 || 0) / 1000;

    return {
        id: String(id),
        name: s.songname || s.name || '',
        artist: singer || '',
        artistIds,
        album: s.album_name || s.albumname || '',
        albumId: String(s.album_id || ''),
        cover: String(cover).replace('{size}', '240'),
        duration: Math.round(rawDur || 0),
        // 酷狗的付费语义与网易云不同，如实置 -1（"未知"），不编造 fee
        fee: -1,
        // ⚠️ 真实来源：`MusicApi.search` 靠它决定后续用哪个平台解析播放地址
        source: 'kugou',
        // 本层内部用的隐藏字段（Dart 的 Song.fromJson 会忽略未知键）
        hash: s.hash || s.FileHash || '',
    };
}

/**
 * 榜单歌曲 item（`/openapi/kmr/v2/rank/audio` 的 songlist）→ 统一结构。
 *
 * ⚠️ 这个接口的字段是**嵌套**的：
 *   hash     → `audio_info.hash_128`（外层没有 hash 字段）
 *   duration → `audio_info.duration_128`（毫秒）
 *   cover    → `trans_param.union_cover`
 *   album    → `album_info.album_name`
 */
function mapRankAudioItem(s) {
    if (!s) return null;
    const id = s.album_audio_id || s.audio_id || s.mixsongid;
    if (!id) return null;
    const authors = Array.isArray(s.authors) ? s.authors : [];
    const ai = s.audio_info || {};
    const cover = (s.trans_param && s.trans_param.union_cover) || (s.album_info && s.album_info.sizable_cover) || '';
    const durMs = Number(ai.duration_128 || ai.duration_320 || s.timelength || 0);
    return {
        id: String(id),
        name: s.songname || s.name || '',
        artist: s.author_name || authors.map((a) => a && a.author_name).filter(Boolean).join('、'),
        artistIds: authors.map((a) => a && a.author_id).filter(Boolean).map((x) => String(x)),
        album: (s.album_info && s.album_info.album_name) || s.album_name || '',
        albumId: String(s.album_id || ''),
        cover: String(cover).replace('{size}', '240'),
        duration: durMs ? Math.round(durMs / 1000) : Math.round(Number(s.duration || 0)),
        fee: -1,
        source: 'kugou',
        hash: String(ai.hash_128 || ai.hash_320 || '').toLowerCase(),
    };
}

/**
 * 歌单歌曲 item（`/pubsongs/v2/get_other_list_file_nofilt` 的 songs）→ 统一结构。
 * `name` 字段是 "歌手 - 歌名" 的合成串，`singerinfo` 里有结构化歌手信息。
 */
function mapPlaylistTrack(s) {
    if (!s) return null;
    const id = s.mixsongid || s.audio_id || s.album_audio_id;
    if (!id) return null;
    const singers = Array.isArray(s.singerinfo) ? s.singerinfo : [];
    let name = s.name || '';
    let artist = singers.map((a) => a && (a.name || a.singername)).filter(Boolean).join('、');
    if (!artist && name.includes(' - ')) {
        const i = name.lastIndexOf(' - ');
        artist = name.slice(0, i);
        name = name.slice(i + 3);
    }
    const cover = s.cover || (s.trans_param && s.trans_param.union_cover) || (s.albuminfo && s.albuminfo.sizable_cover) || '';
    return {
        id: String(id),
        name,
        artist,
        artistIds: singers.map((a) => a && (a.id || a.singerid)).filter(Boolean).map((x) => String(x)),
        album: (s.albuminfo && s.albuminfo.albumname) || s.album_name || '',
        albumId: String(s.album_id || ''),
        cover: String(cover).replace('{size}', '240'),
        duration: Math.round(Number(s.timelen || 0)),
        fee: -1,
        source: 'kugou',
        hash: String(s.hash || '').toLowerCase(),
    };
}

// ────────────────────────────────────────────────────────────────
// 6. 对外接口（结构与网易云实现一致）
// ────────────────────────────────────────────────────────────────

/**
 * 搜索歌曲。
 *
 * 网易云返回 `{ok,list,total}`，这里保持一致。
 *
 * ⚠️ 为什么不直接用上游 `module/search.js` / `search_complex.js`（实测结论）：
 *   · `/v6/search/complex`（search_complex.js）在**非登录态**下恒返回
 *     `error_code: 152 Parameter Error`，即使带上了 register_dev 拿到的 dfid；
 *   · `/v2/search/song`（search.js，x-router=complexsearch.kugou.com）同样是 152；
 *   · 唯一稳定可用的是 `GET https://gateway.kugou.com/api/v3/search/song`
 *     且**必须**带 `x-router: msearch.kugou.com`（不带就 502）。
 * 所以这里自己发这一条请求 —— 底层依然复用上游 `util/request.js`
 * 的 `createRequest`（签名/cookie/SSA 全由它负责），只是换了个 URL。
 */
async function searchSongs(keyword, limit = 30, offset = 0) {
    const kw = String(keyword || '').trim();
    if (!kw) return { ok: false, error: '请输入关键词' };

    const size = Math.min(Math.max(parseInt(limit, 10) || 30, 1), 50);
    const off = Math.max(parseInt(offset, 10) || 0, 0);
    // 上游接口是页式（page/pagesize），把 offset 换算成起始页 + 页内偏移
    const startPage = Math.floor(off / size) + 1;
    const inPageSkip = off % size;

    await ensureDfid();
    try {
        const { request } = loadUpstream();
        const list = [];
        let total = 0;
        // 最多翻 3 页，避免"要 50 条就狂打接口"
        for (let i = 0; i < 3; i++) {
            const res = await request.createRequest({
                baseURL: 'https://gateway.kugou.com',
                url: '/api/v3/search/song',
                method: 'GET',
                params: {
                    format: 'json',
                    keyword: kw,
                    page: startPage + i,
                    pagesize: size,
                    showtype: 1,
                },
                headers: { 'x-router': 'msearch.kugou.com' },
                encryptType: 'android',
                cookie: baseCookie(),
            });
            const b = bodyOf(res);
            if (!b || b.status !== 1) throw res;
            if (typeof b.data.total === 'number' && b.data.total > total) total = b.data.total;
            const items = (b.data && b.data.info) || [];
            for (let j = 0; j < items.length; j++) {
                if (i === 0 && j < inPageSkip) continue;
                const mapped = mapSongItem(items[j]);
                // 酷狗搜索会返回同一首歌的多个版本条目，按 id 去重，避免列表里出现重复行
                if (mapped && !list.some((x) => x && x.id === mapped.id)) list.push(mapped);
                if (list.length >= size) break;
            }
            if (list.length >= size || items.length < size) break;
        }
        const clean = list.filter(Boolean);
        // 记住这批歌：Dart 的 lyric(id) 只回传 id，需要靠这里反查 hash
        rememberTracks(clean);
        return { ok: true, list: clean, total: total || clean.length };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/**
 * 音质映射：Dart 的 `AudioQuality.level` / 网易云风格 → 酷狗 quality 字符串。
 *
 * Dart 侧实际传的是 `standard|higher|exhigh|lossless|hires`
 * （见 `models.dart` 的 `AudioQuality`），所以两套名字都要认。
 * 与网易云实现一样支持回落：拿不到就往下试，最后如实回 no_free_source。
 */
function qualityLadder(quality) {
    const q = String(quality || '').toLowerCase();
    if (q === 'lossless' || q === 'hires') return ['flac', '320', '128'];
    if (q === 'exhigh' || q === '320k') return ['320', '128'];
    if (q === 'higher' || q === '192k') return ['320', '128'];
    // standard / 128k / 未知
    return ['128', '320'];
}

/** 把 Dart 传来的 id 还原成 (hash?, album_audio_id?) */
function decodeSongId(id) {
    const raw = String(id || '').trim();
    if (!raw) return null;
    // 纯数字：album_audio_id（searchSongs 输出的 id）
    if (/^\d+$/.test(raw)) return { albumAudioId: raw, hash: '', albumId: '' };
    // 32 位 hex：直接当 hash
    if (/^[0-9a-fA-F]{32}$/.test(raw)) return { albumAudioId: '', hash: raw.toLowerCase(), albumId: '' };
    // 兼容性编码：hash:album_audio_id[:album_id]
    const parts = raw.split(':');
    if (parts.length >= 2) {
        return {
            hash: /^[0-9a-fA-F]{32}$/.test(parts[0]) ? parts[0].toLowerCase() : '',
            albumAudioId: /^\d+$/.test(parts[1]) ? parts[1] : '',
            albumId: parts[2] && /^\d+$/.test(parts[2]) ? parts[2] : '',
        };
    }
    return null;
}

/**
 * 取播放地址。
 *
 * 与网易云同一契约：
 *   成功 → `{ok:true, url, br, size, type}`
 *   无免费源 → `{ok:true, url:'', reason:'no_free_source', message}`
 *   其它 → `{ok:false, error}`
 *
 * 酷狗免费曲目在 `song_url` 里返回 `url: [主地址, 备用地址]`（字符串数组），
 * 付费/版权受限曲目 `url` 为空并带 `fail_process: ['pkg','buy']` → 正是 no_free_source。
 */
async function songUrl(id, quality = '320k') {
    const decoded = decodeSongId(id);
    if (!decoded || (!decoded.hash && !decoded.albumAudioId)) {
        return { ok: false, error: '缺少歌曲 id' };
    }

    await ensureDfid();
    const cookie = baseCookie();
    const ladder = qualityLadder(quality);
    let lastErr = null;

    for (const q of ladder) {
        try {
            const res = await loadUpstream().mod.songUrl(
                {
                    hash: decoded.hash,
                    album_id: decoded.albumId || 0,
                    album_audio_id: decoded.albumAudioId || 0,
                    quality: q,
                    cookie,
                },
                useAxios,
            );
            const b = bodyOf(res);
            if (!b) {
                lastErr = res;
                continue;
            }
            const urls = Array.isArray(b.url) ? b.url.filter((u) => typeof u === 'string' && u) : [];
            if (!urls.length) {
                // ⚠️ 酷狗"没有免费音源"时**不是错误**：HTTP 200、`status: 2`、
                // `priv_status: 0`、`fail_process: ['pkg','buy']`，只是 url 为空。
                // 这是完全确定的结果 → 直接返回 no_free_source，
                // 不要再往低音质试（再试也是同一个结论，白打两次网络请求）。
                const fail = Array.isArray(b.fail_process) ? b.fail_process.join(',') : '';
                return {
                    ok: true,
                    url: '',
                    reason: 'no_free_source',
                    message: fail.includes('buy') || fail.includes('pkg')
                        ? '该歌曲没有免费音源（酷狗需要购买/会员）'
                        : '该歌曲没有免费音源（可能需要 VIP 或已下架）',
                };
            }
            return {
                ok: true,
                url: urls[0],
                // 主地址用不了时上层可以拿备用地址
                backupUrl: urls[1] || '',
                br: Number(b.bitRate) || Number(q) * 1000,
                size: Number(b.fileSize) || 0,
                type: String(b.extName || '').replace(/^\./, ''),
            };
        } catch (e) {
            lastErr = e;
        }
    }

    if (lastErr) return { ok: false, error: humanize(lastErr) };
    return {
        ok: true,
        url: '',
        reason: 'no_free_source',
        message: '该歌曲没有免费音源（酷狗需要 VIP 或已下架）',
    };
}

// ────────────────────────────────────────────────────────────────
// 6b. 内存曲目索引（album_audio_id → hash / 歌名 / 时长）
// ────────────────────────────────────────────────────────────────
/**
 * 为什么需要它：
 *   Dart 的 `MusicApi.lyric(int id)` **只传 id**，而酷狗的歌词搜索接口
 *   `lyrics.kugou.com/v1/search` 明确要求 `hash` 或 `keyword`
 *   （只给 album_audio_id 会回 `paramter_error: empty hash and keyword`）。
 *   Dart 侧不许改，所以在 Node 侧记住"刚搜过/刚列过"的曲目信息，
 *   用 album_audio_id 反查 hash —— 一次搜索之后，该歌的歌词就能取到。
 * 纯内存、无持久化、上限 500 条，不涉及任何账号信息。
 */
const trackIndex = new Map();
const TRACK_INDEX_MAX = 500;

/** 记一批曲目（search / 榜单 / 歌单 / 新歌 调用后都会走这里） */
function rememberTracks(list) {
    for (const t of list || []) {
        if (!t || !t.id) continue;
        if (trackIndex.size >= TRACK_INDEX_MAX) {
            // 简单淘汰：删最早插入的一条
            const first = trackIndex.keys().next();
            if (!first.done) trackIndex.delete(first.value);
        }
        trackIndex.set(String(t.id), {
            hash: t.hash || '',
            name: t.name || '',
            artist: t.artist || '',
            duration: t.duration || 0,
        });
    }
}

/** 反查某首歌的 hash/歌名/时长 */
function lookupTrack(id) {
    return trackIndex.get(String(id || '')) || null;
}

/**
 * 取歌词。
 *
 * 酷狗要两步：`lyrics.kugou.com/v1/search` 拿 (id, accesskey)，
 * 再 `lyrics.kugou.com/download` 拿内容；`fmt=lrc&decode=1` 拿到的就是明文 LRC。
 * 定位优先用 hash（最准），退而用 `"歌手 - 歌名"` 关键词。
 * 酷狗没有网易云那种独立翻译通道 → `tlyric` 恒为 ''（如实说明，不假装有）。
 */
async function lyric(id) {
    const decoded = decodeSongId(id);
    if (!decoded) return { ok: false, error: '缺少歌曲 id' };

    const remembered = lookupTrack(decoded.albumAudioId || decoded.hash);
    const hash = decoded.hash || (remembered && remembered.hash) || '';
    const keyword = remembered && remembered.name
        ? (remembered.artist ? remembered.artist + ' - ' + remembered.name : remembered.name)
        : '';
    if (!hash && !keyword) {
        // 没有 hash 也没有关键词：酷狗歌词接口必然报 empty hash and keyword。
        // 按"确实没有"返回，不假装成功。
        return {
            ok: true,
            lyric: '',
            tlyric: '',
            message: '酷狗歌词需要先搜索/浏览过该歌曲（缺少 hash 与关键词）',
        };
    }

    await ensureDfid();
    const cookie = baseCookie();
    try {
        const { mod } = loadUpstream();
        const sres = await mod.searchLyric(
            {
                hash,
                album_audio_id: decoded.albumAudioId || 0,
                keywords: keyword || undefined,
                duration: (remembered && remembered.duration ? remembered.duration * 1000 : 0) || undefined,
                man: 'no',
                cookie,
            },
            useAxios,
        );
        const sb = bodyOf(sres);
        const cand = (sb && Array.isArray(sb.candidates) && sb.candidates[0]) || null;
        if (!cand || !cand.id || !cand.accesskey) {
            return { ok: true, lyric: '', tlyric: '' };
        }

        const lres = await mod.lyric(
            { id: cand.id, accesskey: cand.accesskey, fmt: 'lrc', decode: true, cookie },
            useAxios,
        );
        const lb = bodyOf(lres);
        let text = (lb && (lb.decodeContent || lb.content)) || '';
        if (typeof text !== 'string') text = '';
        // 上游 decode=true 时若 contenttype 非 0 也可能是 base64，这里兜一层
        if (text && !/^\[/.test(text.trim()) && /^[A-Za-z0-9+/=\s]+$/.test(text)) {
            try {
                const decodedText = Buffer.from(text, 'base64').toString('utf8');
                if (/\[/.test(decodedText)) text = decodedText;
            } catch {
                /* 保持原样 */
            }
        }
        return { ok: true, lyric: text, tlyric: '' };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/**
 * 榜单列表。
 * 网易云结构：`{ok, list:[{id,name,cover,updateFrequency}]}`
 * 酷狗用 `/ocean/v6/rank/list`（rankname / imgurl / update_frequency），
 * `id` 取 `rankid`（数字，供 playlistDetail/rankAudio 使用）。
 */
async function topLists() {
    await ensureDfid();
    try {
        const res = await loadUpstream().mod.rankList({ withsong: 0, cookie: baseCookie() }, useAxios);
        const b = bodyOf(res);
        if (!b || b.status !== 1) throw res;
        const arr = (b.data && (b.data.info || b.data.list)) || [];
        const list = arr.map((x) => ({
            id: String(x.rankid || x.rank_id || ''),
            name: x.rankname || '',
            cover: String(x.imgurl || x.img_9 || x.album_img_9 || '').replace('{size}', '240'),
            updateFrequency: x.update_frequency || '',
            rankCid: x.rank_cid || 0,
        })).filter((x) => x.id);
        return { ok: true, list };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/**
 * 榜单/歌单详情。
 * 网易云结构：`{ok, playlist:{id,name,cover,trackCount,description,creator}, list}`
 *
 * 酷狗两条路：
 *   · 纯数字 id → 视作榜单 rankid，走 `/openapi/kmr/v2/rank/audio`
 *   · `collection_x_x_x_x` / 其它 → 视作歌单 global_collection_id，
 *     走 `/playlist/detail`（信息）+ `/playlist/track/all`（歌曲）
 */
async function playlistDetail(id) {
    const raw = String(id || '').trim();
    if (!raw) return { ok: false, error: '缺少歌单 id' };
    await ensureDfid();
    const cookie = baseCookie();

    try {
        const { mod } = loadUpstream();

        if (/^\d+$/.test(raw)) {
            // ── 榜单：歌曲走 rank/audio，名称封面走 rank/info ──
            const [ares, ires] = await Promise.all([
                mod.rankAudio({ rankid: raw, rank_cid: 0, page: 1, pagesize: 100, cookie }, useAxios),
                mod.rankInfo({ rankid: raw, rank_cid: 0, cookie }, useAxios).catch(() => null),
            ]);
            const b = bodyOf(ares);
            if (!b || b.status !== 1) throw ares;
            const data = b.data || {};
            const songs = (data.songlist || []).map(mapRankAudioItem).filter(Boolean);
            rememberTracks(songs);
            const info = (bodyOf(ires) || {}).data || {};
            return {
                ok: true,
                playlist: {
                    id: raw,
                    name: info.rankname || data.rankname || ('排行榜 ' + raw),
                    cover: String(info.imgurl || info.img_9 || '').replace('{size}', '240'),
                    trackCount: Number(data.total) || songs.length,
                    description: info.intro || '',
                    creator: '酷狗音乐',
                },
                list: songs,
            };
        }

        // ── 歌单 ──
        const [dres, firstTracks] = await Promise.all([
            mod.playlistDetail({ ids: raw, cookie }, useAxios),
            mod.playlistTrackAll({ id: raw, page: 1, pagesize: 100, cookie }, useAxios),
        ]);
        const db = bodyOf(dres);
        const tb = bodyOf(firstTracks);
        const info = db && (Array.isArray(db.data) ? db.data[0] : db.data);
        if (!info) throw dres;

        // 歌单可能很大（TOP500 / 大歌单）；最多再翻 2 页（上限 300 首），不无限打接口
        const collected = ((tb && tb.data && tb.data.songs) || []).slice();
        const totalCount = Number(info.count) || collected.length;
        for (let page = 2; page <= 3 && collected.length < totalCount; page++) {
            const next = await mod.playlistTrackAll({ id: raw, page, pagesize: 100, cookie }, useAxios);
            const nb = bodyOf(next);
            const more = (nb && nb.data && nb.data.songs) || [];
            if (!more.length) break;
            collected.push(...more);
        }

        const songs = collected.map(mapPlaylistTrack).filter(Boolean);
        rememberTracks(songs);
        return {
            ok: true,
            playlist: {
                id: raw,
                name: info.name || '',
                cover: String(info.pic || info.imgurl || '').replace('{size}', '240'),
                trackCount: totalCount || songs.length,
                description: info.intro || '',
                creator: info.list_create_username || '',
            },
            list: songs,
        };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/**
 * 热门搜索词。
 * 网易云结构：`{ok, list:[string]}`
 * 酷狗 `search/hot` 返回 `data.list[].keywords[].keyword`。
 */
async function hotSearch() {
    await ensureDfid();
    try {
        const res = await loadUpstream().mod.searchHot({ cookie: baseCookie() }, useAxios);
        const b = bodyOf(res);
        if (!b || b.status !== 1) throw res;
        const groups = (b.data && b.data.list) || [];
        const out = [];
        for (const g of groups) {
            for (const k of g.keywords || []) {
                const w = k.keyword || k.reason || '';
                if (w && !out.includes(w)) out.push(w);
            }
        }
        return { ok: true, list: out.slice(0, 30) };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

/**
 * 新歌速递。
 * 网易云结构：`{ok, list:[track]}`
 * 酷狗走 `/musicadservice/container/v1/newsong_publish`（rank_id 21608 = 新歌速递）。
 */
async function newSongs(limit = 10) {
    const size = Math.min(Math.max(parseInt(limit, 10) || 10, 1), 50);
    await ensureDfid();
    try {
        const res = await loadUpstream().mod.topSong({ pagesize: size, cookie: baseCookie() }, useAxios);
        const b = bodyOf(res);
        if (!b || b.status !== 1) throw res;
        const list = (b.data || []).map(mapSongItem).filter(Boolean);
        rememberTracks(list);
        return { ok: true, list };
    } catch (e) {
        return { ok: false, error: humanize(e) };
    }
}

// ────────────────────────────────────────────────────────────────
// 7. selfTest —— 不联网也能报告桥接层是否可用
// ────────────────────────────────────────────────────────────────

/**
 * 自检：**不发任何网络请求**。
 * 报告：上游版本信息、必需依赖是否齐全、各上游模块是否加载成功、
 *       关键加密函数是否可用（这决定了签名/SSA 指纹能不能算出来）、
 *       设备身份从哪来（文件/新生成）、持久化路径。
 */
function selfTest() {
    const out = {
        ok: false,
        upstream: UPSTREAM,
        deps: [],
        modules: [],
        crypto: [],
        device: null,
        deviceFile: DEVICE_FILE,
        proxy: BRIDGE_PROXY || '(direct, no proxy)',
        notes: [],
    };

    // 依赖：能被 require 解析即算齐全（esbuild 已打进 bundle）
    for (const name of REQUIRED_DEPS) {
        try {
            depRequire(name);
            out.deps.push({ name, ok: true });
        } catch (e) {
            out.deps.push({ name, ok: false, error: String((e && e.message) || e) });
        }
    }

    // 上游模块
    try {
        const { mod, util, crypto, request } = loadUpstream();
        for (const [name, fn] of Object.entries(mod)) {
            out.modules.push({ name, ok: typeof fn === 'function' });
        }
        out.modules.push({ name: 'util.calculateMid', ok: typeof util.calculateMid === 'function' });
        out.modules.push({ name: 'util.getGuid', ok: typeof util.getGuid === 'function' });
        out.modules.push({ name: 'util.generateWebGLHash', ok: typeof util.generateWebGLHash === 'function' });
        out.modules.push({ name: 'request.createRequest', ok: typeof request.createRequest === 'function' });

        // 加密/签名自检（纯计算，不联网）
        const md5 = crypto.cryptoMd5('abc');
        out.crypto.push({ name: 'cryptoMd5', ok: md5 === '900150983cd24fb0d6963f7d28e17f72', value: md5 });
        try {
            const mid = util.calculateMid('550e8400-e29b-41d4-a716-446655440000');
            out.crypto.push({ name: 'calculateMid(big-integer+crypto-js)', ok: /^\d+$/.test(mid), value: mid });
        } catch (e) {
            out.crypto.push({ name: 'calculateMid(big-integer+crypto-js)', ok: false, error: String((e && e.message) || e) });
        }
        try {
            // node-forge 只在 SSA 二次验证（generateSimulate）时才走，这里证明它能加载并做 RSA 运算
            const forge = depRequire('node-forge');
            const keys = forge.pki.rsa.generateKeyPair({ bits: 512, workers: 0 });
            const enc = keys.publicKey.encrypt('ok', 'RSAES-PKCS1-V1_5');
            out.crypto.push({
                name: 'node-forge RSA (SSA 指纹依赖)',
                ok: keys.privateKey.decrypt(enc) === 'ok',
            });
        } catch (e) {
            out.crypto.push({ name: 'node-forge RSA (SSA 指纹依赖)', ok: false, error: String((e && e.message) || e) });
        }
        try {
            const simulate = vendorRequire('util/generate_simulate.js');
            const r = simulate.generateSimulate('1', 0, '-', '1');
            out.crypto.push({ name: 'generateSimulate (edt/sid)', ok: !!r.edt && !!r.sid });
        } catch (e) {
            out.crypto.push({ name: 'generateSimulate (edt/sid)', ok: false, error: String((e && e.message) || e) });
        }
    } catch (e) {
        out.notes.push('上游模块加载失败：' + String((e && e.message) || e));
    }

    // 设备身份（本地文件/生成，不联网）
    try {
        const d = getDevice();
        out.device = { guid: d.guid, mid: d.mid, from: d.from, hasDfid: !!d.dfid, dfid: d.dfid || '' };
    } catch (e) {
        out.notes.push('设备身份初始化失败：' + String((e && e.message) || e));
    }

    out.depsOk = out.deps.every((d) => d.ok);
    out.modulesOk = out.modules.length > 0 && out.modules.every((m) => m.ok);
    out.cryptoOk = out.crypto.length > 0 && out.crypto.every((c) => c.ok);
    out.ok = out.depsOk && out.modulesOk && out.cryptoOk;
    return out;
}

export {
    // 契约函数（与网易云实现同名同结构）
    searchSongs,
    songUrl,
    lyric,
    topLists,
    playlistDetail,
    hotSearch,
    newSongs,
    selfTest,
    // 供 music_source.js 做"不支持"的显式返回 / 诊断
    UPSTREAM,
    DEVICE_FILE,
};
