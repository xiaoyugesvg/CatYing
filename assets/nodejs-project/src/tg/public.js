// Telegram 公开频道解析（不登录、不用 MTProto）
// ============================================================
// 只走 HTTP + cheerio：
//   · 列表     https://t.me/s/<频道>?before=<帖子id>
//   · 播放直链 https://t.me/<频道>/<id>?embed=1&mode=tme  → <video src="...mp4?token=...">
//
// 适用边界（写在最前面，避免误解）：
//   · 只对**公开频道**有效（频道要开预览，t.me/s 才有内容）
//   · 私有群 / 私有频道必须走 service.js 的 MTProto 登录通道
//   · mp4 里的 token 有时效 ⇒ 播放地址**现取**，不缓存进数据库

import axios from 'axios';
import * as cheerio from 'cheerio';
import { agentOptions, currentProxy } from './proxypool.js';

const UA =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) ' +
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

const http = axios.create({
    timeout: 20000,
    headers: {
        'User-Agent': UA,
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    },
    // t.me 会 302 到区域站点，跟随即可
    maxRedirects: 5,
    validateStatus: (s) => s >= 200 && s < 400,
});

/** @channel / t.me/xxx / https://t.me/s/xxx / -100xxx → 纯频道名 */
export function normalizeChannel(input) {
    let p = String(input || '').trim();
    p = p.replace(/^https?:\/\//i, '')
        .replace(/^(www\.)?(t|telegram)\.me\//i, '')
        .replace(/^s\//i, '')
        .replace(/^@/, '');
    p = p.split(/[/?#]/)[0];
    return p;
}

function pick(text, re) {
    const m = re.exec(text);
    return m ? m[1] : '';
}

/**
 * 频道帖子列表
 * @param {string} channel 频道名
 * @param {number} before  上一页最后一条的 id（首页传 0）
 * @param {number} depth   内部用：整页都被过滤时自动往后翻的次数（最多 3 次）
 */
export async function listPublic(channel, before = 0, depth = 0) {
    const ch = normalizeChannel(channel);
    if (!ch) return { ok: false, error: '缺少频道名', items: [], next: 0 };
    const url = `https://t.me/s/${encodeURIComponent(ch)}` +
        (before > 0 ? `?before=${before}` : '');
    let html;
    try {
        // 走当前代理（没配就是直连）—— 国内直连 t.me 基本不通，
        // 公开频道"列表出不来 / 很慢"多半是这里超时
        const r = await http.get(url, agentOptions());
        html = r.data;
    } catch (e) {
        const code = e && e.response && e.response.status;
        if (code === 404) return { ok: false, error: '频道不存在或未开放网页预览', items: [], next: 0 };
        return { ok: false, error: '抓取失败：' + ((e && e.message) || String(e)), items: [], next: 0 };
    }
    if (typeof html !== 'string') html = String(html || '');
    if (!html.includes('tgme_widget_message')) {
        return {
            ok: false,
            error: '这个频道没有网页预览（私有频道请用登录模式）',
            items: [],
            next: 0,
        };
    }

    const $ = cheerio.load(html);
    const items = [];
    let minId = 0;

    $('.tgme_widget_message').each((_, el) => {
        const node = $(el);
        const post = node.attr('data-post') || '';
        const idStr = post.split('/').pop() || '';
        const id = parseInt(idStr, 10);
        if (!id) return;
        // 游标按**全部**帖子记（不是只记留下的）—— 否则整页都是广告时
        // minId 会是 0，"自动往后翻"和"下一页"都会失效。
        if (!minId || id < minId) minId = id;

        // 只保留"能播的"：视频播放器 / 视频类文档
        //
        // ⚠️ 2026-10-25 收紧：原来"任何文档"都收（hasDoc = 文档标题非空），
        //   公开频道里大量是 .apk / .zip / .pdf 的推广附件 ⇒ 列表被广告刷满
        //   （用户：「TG 不要他么的获取那么多广告」）。现在只认视频扩展名；
        //   纯图片帖、纯文字+链接的广告帖本来就被排除在外。
        const hasVideo = node.find('.tgme_widget_message_video_player').length > 0 ||
            node.find('.tgme_widget_message_roundvideo_player').length > 0 ||
            node.find('video').length > 0;
        const docTitle = node.find('.tgme_widget_message_document_title').first().text().trim();
        const hasDoc = /\.(mp4|mkv|mov|m4v|webm|avi|flv|ts|m3u8)$/i.test(docTitle);
        if (!hasVideo && !hasDoc) return;

        // 封面：优先视频缩略图，其次文档图标背景
        let thumb = '';
        const thumbEl = node.find('.tgme_widget_message_video_thumb').first();
        const style = thumbEl.attr('style') || '';
        thumb = pick(style, /background-image:url\('([^']+)'\)/);
        if (!thumb) {
            const photo = node.find('.tgme_widget_message_photo_wrap').first().attr('style') || '';
            thumb = pick(photo, /background-image:url\('([^']+)'\)/);
        }

        // 标题：把 <br> 还原成换行再取第一行 ——
        // cheerio 的 .text() 会把整段粘连成一行，直接截 120 字会出现
        // 「Signed Gifts. You can now add...August Features1 •」这种一长串。
        const textNode = node.find('.tgme_widget_message_text').first();
        textNode.find('br').replaceWith('\n');
        const rawText = textNode.text().trim();
        const firstLine = rawText
            .split('\n')
            .map((s) => s.trim())
            .filter(Boolean)[0] || '';
        // 标题（2026-10-25 第二轮：不再在 Node 里写死广告词/书名号规则）
        //
        //   · 有「《片名》」→ 取书名号里的文字（保持之前的命名法）
        //   · 没有 → 退回帖子第一行 / 文件名，**原样交给 App**
        //   App 侧有可配置的筛选（默认去掉带 emoji 的名称，用户还能自己加词），
        //   这样以后想放宽/收紧都不用改代码。
        const title = titleFromGuillemets(rawText)
            || titleFromGuillemets(docTitle)
            || firstLine
            || docTitle
            || '视频';

        const durText = node.find('.tgme_widget_message_video_duration').first().text().trim();
        const duration = durText ? toSeconds(durText) : 0;

        const extra = node.find('.tgme_widget_message_document_extra').first().text().trim();
        const size = extra ? toBytes(extra) : 0;

        const dateStr = node.find('time').first().attr('datetime') || '';
        const date = dateStr ? Math.floor(Date.parse(dateStr) / 1000) || 0 : 0;

        items.push({ id, title, fileName: docTitle, size, duration, date, thumb });
    });

    // t.me/s 是「从新到旧」，统一按 id 倒序更稳
    items.sort((a, b) => b.id - a.id);

    // 整页都是广告/图片帖（全被过滤掉）却不等于没有更早的视频 ⇒ 自动再往下翻
    // 一两页，否则客户端会以为"到底了"（收紧过滤后这种情况变多了）。
    if (items.length === 0 && minId > 0 && depth < 3) {
        return listPublic(ch, minId, depth + 1);
    }

    return {
        ok: true,
        items,
        next: items.length > 0 ? minId : 0,
        channel: ch,
    };
}

/**
 * 解析某条帖子的可播直链（mp4 / m3u8）
 * 注意：返回的 URL 带 token，会过期 —— 只能现取现播，不能存库。
 */
export async function resolvePublic(channel, id) {
    const ch = normalizeChannel(channel);
    if (!ch || !id) return { ok: false, error: '缺少频道或消息 id' };
    const url = `https://t.me/${encodeURIComponent(ch)}/${id}?embed=1&mode=tme`;
    let html;
    try {
        const r = await http.get(url, agentOptions());
        html = r.data;
    } catch (e) {
        return { ok: false, error: '解析失败：' + ((e && e.message) || String(e)) };
    }
    const s = typeof html === 'string' ? html : String(html || '');

    // 直接把 <video src> 抓出来；mp4 与 m3u8 都可能是这个位置
    const src = pick(s, /<video[^>]+src="([^"]+)"/i)
        || pick(s, /<source[^>]+src="([^"]+)"/i);
    if (src) return { ok: true, url: src.replace(/&amp;/g, '&') };

    // 文档形态的视频（频道把 mp4 当文件发时没有 <video>，只有一个下载链接）。
    // 列表里已经放行了 .mp4 文档，这里必须同样认出它的 href，否则点播直接 404。
    const docHref = pick(
        s,
        /class="[^"]*tgme_widget_message_document_wrap[^"]*"[^>]*href="([^"]+)"/i,
    ) || pick(
        s,
        /href="([^"]+\.(?:mp4|mkv|mov|m4v|webm|m3u8)(?:\?[^"]*)?)"/i,
    );
    if (docHref) return { ok: true, url: docHref.replace(/&amp;/g, '&') };

    return { ok: false, error: '该帖子没有可直接播放的视频（可能是文档或超大文件）' };
}

/// 广告标题关键词（用户 2026-10-25：「名称带有广告的那种就去掉」）
///
/// 只看**标题**（帖子第一行 / 文件名），不看正文 —— 正文里偶尔出现的
/// 「广告位招租」之类不至于把整条视频丢掉。
/// 想加词直接往数组里补，不必改逻辑。
const AD_WORDS = [
    // 明说自己是广告（注意别放光秃秃的「商务」，会误伤「商务英语」这类正片）
    '广告', '推广', '赞助', '商务合作', '招商', '合作洽谈',
    // 拉人 / 引流
    '加群', '入群', '进群', '交流群', '粉丝群', '福利群', '资源群', '私聊', '私信',
    '引流', '加微信', '加微', '微信号', 'vx', 'v信', 'qq群', '企鹅群', '飞机号', '电报号',
    // 灰产 / 博彩（用户 2026-10-25 追加：贷款、博彩、国际、信誉这类全不要）
    '百家乐', '时时彩', '六合彩', '彩票', '娱乐城', '棋牌', '博彩', '真人荷官', '稳赚',
    '兼职', '日赚', '刷单', '返利', '注册送', '首存', '首充', '返水', '洗码', '优惠券',
    '贷款', '借贷', '网贷', '信用卡', '外汇', '换汇', '信誉', '包网', '代充',
    '国际', '出租', '出售',
    // 渠道类
    '总代理', '招代理', '代理加盟', '招募', '客服', '官网',
];

/// 标题看起来是不是广告
export function looksLikeAd(s) {
    const t = String(s || '').trim();
    if (!t) return false;
    const low = t.toLowerCase();
    for (const w of AD_WORDS) {
        if (low.includes(w)) return true;
    }
    // 纯链接标题（整条只有一个 t.me / http 链接）也算广告位
    if (/^(https?:\/\/|t\.me\/|@)/i.test(t) && t.length < 60) return true;
    return false;
}

/// 从「《片名》」里取片名 —— 用户 2026-10-25 定下的片库命名法：
/// **只收带书名号的帖子**，标题就是书名号里的文字。
///
/// 为什么要这么硬：这些搬运频道的正常片子一律写 `《片名》第 x 集`，
/// 而广告/博彩/贷款帖全是「一堆 emoji + 国际/信誉/贷款…」。
/// 只认书名号比维护关键词表靠谱得多（关键词只作第二道保险）。
export function titleFromGuillemets(s) {
    const m = String(s || '').match(/《([^》]{1,60})》/);
    return m ? m[1].replace(/\s+/g, ' ').trim() : '';
}

/// t.me 连通性自测（用户 2026-10-25：「不能直接用手机自己用的代理吗？」）——
/// **不改任何配置**，只按当前设置（内置代理开/关 + 系统 VPN）打一次 t.me，
/// 把耗时/失败原因原样返回给 UI，省得用户靠"转圈"猜。
export async function probeTme() {
    const t0 = Date.now();
    const viaProxy = !!currentProxy();
    try {
        const r = await http.get('https://t.me/s/cctv1', {
            ...agentOptions(),
            timeout: 12000,
        });
        const body = typeof r.data === 'string' ? r.data : String(r.data || '');
        return {
            ok: body.includes('tgme_widget_message'),
            ms: Date.now() - t0,
            status: r.status,
            bytes: body.length,
            proxy: viaProxy,
            error: body.includes('tgme_widget_message')
                ? ''
                : '能连上 t.me，但返回的不是频道页（可能被劫持/需要代理）',
        };
    } catch (e) {
        return {
            ok: false,
            ms: Date.now() - t0,
            proxy: viaProxy,
            error: (e && e.message) || String(e),
        };
    }
}

function toSeconds(t) {
    const parts = t.split(':').map((x) => parseInt(x, 10)).filter((x) => !isNaN(x));
    if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
    if (parts.length === 2) return parts[0] * 60 + parts[1];
    return 0;
}

function toBytes(t) {
    const m = /([\d.]+)\s*(B|KB|MB|GB|TB)/i.exec(t);
    if (!m) return 0;
    const n = parseFloat(m[1]);
    const unit = m[2].toUpperCase();
    const mul = { B: 1, KB: 1024, MB: 1024 ** 2, GB: 1024 ** 3, TB: 1024 ** 4 }[unit] || 1;
    return Math.round(n * mul);
}
