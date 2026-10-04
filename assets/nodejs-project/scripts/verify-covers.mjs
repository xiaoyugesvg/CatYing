// 封面图**能不能真的拿到**（真联网，逐个平台探测）。
//
//     cd assets/nodejs-project
//     node scripts/verify-covers.mjs
//
// 为什么单独验这个：卡片的排版做得再好，封面 URL 拿不到 / 403 / 空串
// 就是一片占位图 —— 用户看到的是"没有封面"。
import axios from 'axios';
import * as m from '../src/music_source.js';

const fn = m.handleMusicApi;
const UA =
    'Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.120 Mobile Safari/537.36';

let bad = 0;

async function probe(label, url) {
    const u = String(url || '').trim();
    if (!u) {
        console.log(`❌ ${label}: **没有封面 URL**`);
        bad++;
        return;
    }
    if (!/^https?:\/\//.test(u)) {
        console.log(`❌ ${label}: 不是完整 URL → ${u.slice(0, 50)}`);
        bad++;
        return;
    }
    try {
        const r = await axios.get(u, {
            timeout: 15000,
            responseType: 'arraybuffer',
            headers: { 'User-Agent': UA, Referer: 'https://music.163.com/' },
            validateStatus: () => true,
        });
        const n = r.data ? r.data.byteLength : 0;
        const ok = r.status === 200 && n > 500;
        if (!ok) bad++;
        console.log(
            `${ok ? '✅' : '❌'} ${label}: HTTP ${r.status} ${r.headers['content-type'] || '?'} ${n}B  ` +
                `${u.startsWith('https') ? 'https' : 'http '} ${u.slice(0, 58)}`,
        );
    } catch (e) {
        bad++;
        console.log(`❌ ${label}: ${e.message}  ${u.slice(0, 58)}`);
    }
}

console.log('=== 网易云（搜索）===');
const n1 = await fn({ action: 'search', keyword: '周杰伦', limit: 3 });
for (const it of (n1.list || []).slice(0, 3)) await probe('网易云', it.cover);

console.log('\n=== 网易云（推荐歌单 / 排行榜 的封面）===');
const pl = await fn({ action: 'personalized', limit: 2 });
for (const it of (pl.list || []).slice(0, 2)) await probe('推荐歌单', it.cover);
const tl = await fn({ action: 'topLists' });
for (const it of (tl.list || []).slice(0, 2)) await probe('排行榜', it.cover);

console.log('\n=== 酷狗（搜索）===');
const k1 = await fn({ action: 'search', keyword: '周杰伦', limit: 3, source: 'kugou' });
for (const it of (k1.list || []).slice(0, 3)) await probe('酷狗', it.cover);

console.log('\n=== 喜马拉雅（搜索专辑）===');
const x1 = await fn({ action: 'search', keyword: '庆余年', source: 'ximalaya' });
for (const it of (x1.list || []).slice(0, 2)) await probe('喜马拉雅', it.cover);

console.log(bad === 0 ? '\n封面全部可获取 ✅' : `\n${bad} 个封面有问题 ❌`);
process.exit(bad === 0 ? 0 : 1);
