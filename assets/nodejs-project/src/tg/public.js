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
 */
export async function listPublic(channel, before = 0) {
    const ch = normalizeChannel(channel);
    if (!ch) return { ok: false, error: '缺少频道名', items: [], next: 0 };
    const url = `https://t.me/s/${encodeURIComponent(ch)}` +
        (before > 0 ? `?before=${before}` : '');
    let html;
    try {
        const r = await http.get(url);
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

        // 只保留"能播"的：视频播放器 / 文档附件
        const hasVideo = node.find('.tgme_widget_message_video_player').length > 0 ||
            node.find('.tgme_widget_message_roundvideo_player').length > 0 ||
            node.find('video').length > 0;
        const docTitle = node.find('.tgme_widget_message_document_title').first().text().trim();
        const hasDoc = docTitle.length > 0;
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

        const text = node.find('.tgme_widget_message_text').first().text().trim();
        const title = (text.split('\n').map((s) => s.trim()).filter(Boolean)[0] || '')
            .slice(0, 120) || docTitle.slice(0, 120) || `消息 ${id}`;

        const durText = node.find('.tgme_widget_message_video_duration').first().text().trim();
        const duration = durText ? toSeconds(durText) : 0;

        const extra = node.find('.tgme_widget_message_document_extra').first().text().trim();
        const size = extra ? toBytes(extra) : 0;

        const dateStr = node.find('time').first().attr('datetime') || '';
        const date = dateStr ? Math.floor(Date.parse(dateStr) / 1000) || 0 : 0;

        items.push({ id, title, fileName: docTitle, size, duration, date, thumb });
        if (!minId || id < minId) minId = id;
    });

    // t.me/s 是「从新到旧」，统一按 id 倒序更稳
    items.sort((a, b) => b.id - a.id);

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
        const r = await http.get(url);
        html = r.data;
    } catch (e) {
        return { ok: false, error: '解析失败：' + ((e && e.message) || String(e)) };
    }
    const s = typeof html === 'string' ? html : String(html || '');

    // 直接把 <video src> 抓出来；mp4 与 m3u8 都可能是这个位置
    const src = pick(s, /<video[^>]+src="([^"]+)"/i)
        || pick(s, /<source[^>]+src="([^"]+)"/i);
    if (!src) {
        return { ok: false, error: '该帖子没有可直接播放的视频（可能是文档或超大文件）' };
    }
    return { ok: true, url: src.replace(/&amp;/g, '&') };
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
