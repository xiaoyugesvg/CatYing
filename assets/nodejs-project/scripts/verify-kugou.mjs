/**
 * 酷狗数据源验证脚本（真实联网）
 *
 * 跑法（在本目录，即 assets/nodejs-project）：
 *     node scripts/verify-kugou.mjs
 *
 * 说明：
 *   · 本机验证需要代理：脚本会读 `KUGOU_BRIDGE_PROXY`（或系统 HTTPS_PROXY）
 *     并交给桥接层；设备上不设置它 = 直连。
 *   · 全程只读，不写任何账号/密码/Token。
 */

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');

// 本机没有中国 IP，必须走代理才能访问酷狗；设备上不要设置这个变量
const proxy = process.env.KUGOU_BRIDGE_PROXY || process.env.HTTPS_PROXY || process.env.https_proxy || '';
if (proxy) process.env.KUGOU_BRIDGE_PROXY = proxy;
console.log('=== 环境 ===');
console.log('proxy      :', proxy || '(直连)');
console.log('DSH_DATA_DIR:', process.env.DSH_DATA_DIR || '(未设置，桥接层会退到系统目录)');

const kg = await import('../src/kugou_source.js');

function hr(t) {
    console.log('\n' + '─'.repeat(72) + '\n' + t + '\n' + '─'.repeat(72));
}

// ── 0. selfTest（不联网）────────────────────────────────────────
hr('0) selfTest（不联网）');
const st = kg.selfTest();
console.log('ok        :', st.ok);
console.log('upstream  :', JSON.stringify(st.upstream));
console.log('deps      :', st.deps.map((d) => `${d.name}=${d.ok ? 'ok' : 'MISSING(' + d.error + ')'}`).join(', '));
console.log('modules   :', st.modules.length + ' 个，全部加载=' + st.modules.every((m) => m.ok));
console.log('crypto    :');
for (const c of st.crypto) console.log('   -', c.name, c.ok ? 'OK' : 'FAIL', c.value ? '(' + String(c.value).slice(0, 48) + ')' : c.error ? '(' + c.error + ')' : '');
console.log('device    :', JSON.stringify(st.device));
console.log('deviceFile:', st.deviceFile);
if (st.notes.length) console.log('notes     :', st.notes.join(' | '));

// ── 1. 搜索 ────────────────────────────────────────────────────
hr('1) 搜索「周杰伦」');
const s = await kg.searchSongs('周杰伦', 10, 0);
console.log('ok =', s.ok, ' total =', s.total, ' error =', s.error || '-');
if (s.ok) {
    s.list.slice(0, 3).forEach((x, i) => {
        console.log(`  #${i + 1} 歌名=${x.name}  歌手=${x.artist}  时长=${x.duration}s  id=${x.id}  (hash=${x.hash})`);
    });
    console.log('  第 1 条完整 JSON:', JSON.stringify(s.list[0]));
}

// ── 2. 播放地址 ────────────────────────────────────────────────
hr('2) 播放地址');
async function tryUrl(item, quality) {
    const u = await kg.songUrl(item.id, quality);
    console.log(`  [${item.name} / ${item.artist}] quality=${quality}`);
    console.log('    ->', JSON.stringify({
        ok: u.ok, error: u.error, reason: u.reason, message: u.message,
        br: u.br, size: u.size, type: u.type,
        url80: u.url ? String(u.url).slice(0, 80) : '',
    }));
    return u;
}
let got = null;
if (s.ok && s.list.length) {
    got = await tryUrl(s.list[0], '320k');
    // 免费歌兜底：换成《卡农 (经典钢琴版)》这类免费曲目再试
    if (!got.url) {
        console.log('\n  第一条没有免费音源，换免费曲目再试（搜索「卡农 钢琴」）：');
        const s2 = await kg.searchSongs('卡农 钢琴', 10, 0);
        if (s2.ok) {
            for (const cand of s2.list) {
                const u = await tryUrl(cand, '320k');
                if (u.url) { got = u; break; }
            }
        } else {
            console.log('   搜索失败:', s2.error);
        }
    }
}

// ── 3. 歌词 ────────────────────────────────────────────────────
hr('3) 歌词');
const lyricTarget = (s.ok && s.list[0]) || null;
if (lyricTarget) {
    const l = await kg.lyric(lyricTarget.id);
    console.log(`  目标: ${lyricTarget.name} / ${lyricTarget.artist} (id=${lyricTarget.id}, hash=${lyricTarget.hash})`);
    console.log('  ok =', l.ok, ' error =', l.error || '-', ' tlyric =', JSON.stringify(l.tlyric));
    console.log('  歌词长度 =', (l.lyric || '').length);
    console.log('  前 80 字符 =', JSON.stringify(String(l.lyric || '').replace(/\r?\n/g, '\\n').slice(0, 80)));
    console.log('  前 200 字符原文:\n' + String(l.lyric || '').slice(0, 200));
} else {
    console.log('  没有可用的歌曲 id，跳过');
}

// ── 3b. 其它接口（能不能用都如实打印）─────────────────────────
hr('3b) 其它接口（topLists / playlistDetail / hotSearch / newSongs）');
const top = await kg.topLists();
console.log('topLists: ok =', top.ok, ' error =', top.error || '-', ' n =', (top.list || []).length);
if (top.ok && top.list[0]) console.log('   首条:', JSON.stringify(top.list[0]));
if (top.ok && top.list[0]) {
    const pd = await kg.playlistDetail(top.list[0].id);
    console.log('playlistDetail(榜单 ' + top.list[0].id + '): ok =', pd.ok, ' error =', pd.error || '-', ' tracks =', (pd.list || []).length);
    if (pd.ok) console.log('   playlist:', JSON.stringify(pd.playlist), '\n   首曲:', JSON.stringify((pd.list || [])[0] || null));
}
const hot = await kg.hotSearch();
console.log('hotSearch: ok =', hot.ok, ' error =', hot.error || '-', ' n =', (hot.list || []).length, ' 前 5 =', JSON.stringify((hot.list || []).slice(0, 5)));
const ns = await kg.newSongs(5);
console.log('newSongs: ok =', ns.ok, ' error =', ns.error || '-', ' n =', (ns.list || []).length);
if (ns.ok && ns.list[0]) console.log('   首条:', JSON.stringify(ns.list[0]));

// ── 4. dist 状态 ───────────────────────────────────────────────
hr('4) dist 产物状态');
const distFile = path.join(ROOT, 'dist', 'main.js');
const md5File = path.join(ROOT, 'dist', 'main.js.md5');
if (fs.existsSync(distFile)) {
    const buf = fs.readFileSync(distFile);
    const md5 = crypto.createHash('md5').update(buf).digest('hex');
    const stat = fs.statSync(distFile);
    console.log('dist/main.js      :', buf.length, 'bytes   mtime =', stat.mtime.toISOString());
    console.log('dist/main.js.md5  :', fs.existsSync(md5File) ? fs.readFileSync(md5File, 'utf8').trim() : '(缺失)');
    console.log('实算 md5          :', md5, md5 === (fs.existsSync(md5File) ? fs.readFileSync(md5File, 'utf8').trim() : '') ? '(与 .md5 一致)' : '(与 .md5 不一致！)');
    console.log('是否包含酷狗桥接  :', buf.includes('KG_TAG_RES') || buf.toString('latin1').includes('kugou') ? '是（bundle 内含酷狗相关代码）' : '否');
} else {
    console.log('dist/main.js 不存在');
}

hr('完成');
process.exit(0);
