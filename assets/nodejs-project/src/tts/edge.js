// 内置 Edge-TTS 客户端（免费、无需 Key）
// ============================================================
// 为什么自己实现而不是把 EasyVoice 整个塞进来：
//   · EasyVoice 是 Next.js + pnpm monorepo + ffmpeg，整包几百 MB，
//     nodejs-mobile 跑 Next.js 风险很高；
//   · 它底层就是微软 Edge 的「大声朗读」接口（Edge-TTS）。我们只要发音，
//     直接说这个协议就够了 —— 零额外进程、随 App 打包即可离线使用。
//
// 协议要点（微软的网页朗读用的就是这一套）：
//   1. GET  voices/list 拿音色表（可选，UI 里预置了常用音色）
//   2. WS   .../edge/v1?TrustedClientToken=…&Sec-MS-GEC=…  ← 必须带 DRM 令牌
//      Sec-MS-GEC 是 v2 令牌（自定义哈希），算法见 edge_drm.js
//   3. 先发 speech.config（要 mp3 格式），再发 ssml 帧
//   4. 服务端回二进制帧：2 字节头长度 + 头文本 + 音频字节；`Path:turn.end` 表示结束

import crypto from 'crypto';
import WebSocket from 'ws';
import { generateSecMsGec, TRUSTED_CLIENT_TOKEN } from './edge_drm.js';

const CHROMIUM_VERSION = '143.0.3650.75';
const SEC_MS_GEC_VERSION = `2-${CHROMIUM_VERSION}`;
const WS_BASE = 'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1';

function uuidHex() {
    return crypto.randomBytes(16).toString('hex');
}

function ts() {
    return new Date().toISOString().replace(/[-:.]/g, (m) => (m === '.' ? '.' : ''));
}

function escapeXml(s) {
    return String(s || '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&apos;');
}

/**
 * 语速 / 音调归一化。
 *
 * SSML 的 prosody 要求**带符号**：`+20%` / `-10Hz`。
 * 传 `20` 或 `20%` 这种裸值微软会直接拒，所以这里兜一层：
 *   '20' → '+20%'     '-10' → '-10%'     '+5%' → '+5%'
 */
function normalizeProsody(v, unit, zero) {
    if (v == null || v === '') return zero;
    let s = String(v).trim();
    if (s === '0' || s === '0%' || s === '0Hz') return zero;
    if (!s.endsWith(unit)) s += unit;
    if (!/^[+-]/.test(s)) s = `+${s}`;
    return s;
}

/**
 * 合成一段文本 → mp3 字节
 *
 * @param {object} opt
 * @param {string} opt.text    要念的文字（纯文本）
 * @param {string} [opt.voice] 音色，默认晓晓
 * @param {string} [opt.rate]  语速，如 +20% / -10%（裸数字也认）
 * @param {string} [opt.pitch] 音调，如 +10Hz / -20Hz（裸数字也认）
 * @param {string} [opt.volume] 音量，如 +0%
 * @param {number} [opt.timeoutMs] 超时，默认 20s
 * @returns {Promise<Buffer>}
 */
export function synthesize(opt) {
    const text = String(opt.text || '');
    if (!text.trim()) return Promise.reject(new Error('文本为空'));
    const voice = opt.voice || 'zh-CN-XiaoxiaoNeural';
    const rate = normalizeProsody(opt.rate, '%', '+0%');
    const pitch = normalizeProsody(opt.pitch, 'Hz', '+0Hz');
    const volume = normalizeProsody(opt.volume, '%', '+0%');
    const timeoutMs = opt.timeoutMs || 20000;
    const format = opt.format || 'audio-24khz-48kbitrate-mono-mp3';

    const url = `${WS_BASE}?TrustedClientToken=${TRUSTED_CLIENT_TOKEN}` +
        `&ConnectionId=${uuidHex()}` +
        `&Sec-MS-GEC=${generateSecMsGec()}` +
        `&Sec-MS-GEC-Version=${SEC_MS_GEC_VERSION}`;

    return new Promise((resolve, reject) => {
        const chunks = [];
        let done = false;
        const ws = new WebSocket(url, {
            headers: {
                // 微软按 Edge 扩展的 Origin 放行；不带会被 403
                Origin: 'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold',
                'User-Agent': `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${CHROMIUM_VERSION.split('.')[0]}.0.0.0 Safari/537.36 Edg/${CHROMIUM_VERSION.split('.')[0]}.0.0.0`,
                Pragma: 'no-cache',
                'Cache-Control': 'no-cache',
                'Accept-Language': 'zh-CN,zh;q=0.9',
            },
        });
        ws.binaryType = 'nodebuffer';

        const timer = setTimeout(() => finish(new Error('合成超时')), timeoutMs);
        function finish(err) {
            if (done) return;
            done = true;
            clearTimeout(timer);
            try { ws.close(); } catch (_) {}
            if (err) reject(err);
            else if (!chunks.length) reject(new Error('服务没有返回音频'));
            else resolve(Buffer.concat(chunks));
        }

        ws.on('unexpected-response', (_req, res) => {
            finish(new Error(`握手失败 HTTP ${res.statusCode}`));
        });
        ws.on('error', (e) => finish(e));
        ws.on('close', () => { if (!done) finish(new Error('连接被服务端关闭')); });

        ws.on('open', () => {
            const config = JSON.stringify({
                context: {
                    synthesis: {
                        audio: {
                            metadataoptions: {
                                sentenceBoundaryEnabled: 'false',
                                wordBoundaryEnabled: 'false',
                            },
                            outputFormat: format,
                        },
                    },
                },
            });
            ws.send(
                `X-Timestamp:${ts()}\r\n` +
                'Content-Type:application/json; charset=utf-8\r\n' +
                'Path:speech.config\r\n\r\n' + config,
            );

            const ssml =
                "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>" +
                `<voice name='${voice}'>` +
                `<prosody pitch='${pitch}' rate='${rate}' volume='${volume}'>` +
                escapeXml(text) +
                '</prosody></voice></speak>';
            ws.send(
                `X-RequestId:${uuidHex()}\r\n` +
                'Content-Type:application/ssml+xml\r\n' +
                `X-Timestamp:${ts()}Z\r\n` +
                'Path:ssml\r\n\r\n' + ssml,
            );
        });

        ws.on('message', (data, isBinary) => {
            if (isBinary) {
                // 2 字节头长度 + 头文本 + 音频
                if (data.length < 2) return;
                const headerLen = data.readUInt16BE(0);
                const header = data.slice(2, 2 + headerLen).toString('utf8');
                if (/Path:\s*audio/i.test(header)) chunks.push(data.slice(2 + headerLen));
                return;
            }
            const s = data.toString('utf8');
            if (/Path:\s*turn\.end/i.test(s)) finish(null);
        });
    });
}

/** 常用中文音色（UI 里的下拉直接用这个，省一次网络请求） */
export const VOICES = [
    { id: 'zh-CN-XiaoxiaoNeural', name: '晓晓（女·通用）' },
    { id: 'zh-CN-XiaoyiNeural', name: '晓伊（女·活泼）' },
    { id: 'zh-CN-YunxiNeural', name: '云希（男·阳光）' },
    { id: 'zh-CN-YunjianNeural', name: '云健（男·沉稳）' },
    { id: 'zh-CN-YunyangNeural', name: '云扬（男·播报）' },
    { id: 'zh-CN-YunxiaNeural', name: '云夏（男·少年）' },
    { id: 'zh-CN-liaoning-XiaobeiNeural', name: '晓北（东北话）' },
    { id: 'zh-CN-shaanxi-XiaoniNeural', name: '晓妮（陕西话）' },
    { id: 'zh-HK-HiuMaanNeural', name: '曉曼（粤语·女）' },
    { id: 'zh-TW-HsiaoChenNeural', name: '曉臻（台湾·女）' },
];

/** HTTP 入口：GET /tts/edge?text=&voice=&rate=&pitch=&volume= */
export async function handle(req, res, url) {
    const q = url.searchParams;
    const text = q.get('text') || '';
    if (!text.trim()) {
        res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ ok: false, error: 'text 为空' }));
        return;
    }
    try {
        const buf = await synthesize({
            text,
            voice: q.get('voice') || undefined,
            rate: q.get('rate') != null ? q.get('rate') : undefined,
            pitch: q.get('pitch') != null ? q.get('pitch') : undefined,
            volume: q.get('volume') != null ? q.get('volume') : undefined,
            timeoutMs: parseInt(q.get('timeoutMs') || '20000', 10),
        });
        res.writeHead(200, {
            'Content-Type': 'audio/mpeg',
            'Content-Length': buf.length,
            'Cache-Control': 'no-store',
        });
        res.end(buf);
    } catch (e) {
        res.writeHead(502, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ ok: false, error: (e && e.message) || String(e) }));
    }
}
