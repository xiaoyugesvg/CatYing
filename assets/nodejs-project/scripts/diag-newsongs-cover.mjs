// 诊断：网易云 vs 酷狗，「新歌速递」返回的 cover 字段到底是空还是有效 URL。
//     cd assets/nodejs-project && node scripts/diag-newsongs-cover.mjs
import axios from 'axios';
import * as m from '../src/music_source.js';

const fn = m.handleMusicApi;

async function head(url) {
    const u = String(url || '').trim();
    if (!u) return '（空字符串）';
    try {
        const r = await axios.get(u, {
            timeout: 12000,
            responseType: 'arraybuffer',
            validateStatus: () => true,
        });
        return `HTTP ${r.status} ${r.data ? r.data.byteLength : 0}B`;
    } catch (e) {
        return '请求失败: ' + e.message;
    }
}

for (const [label, body] of [
    ['网易云 newSongs', { action: 'newSongs', limit: 5 }],
    ['酷狗   newSongs', { action: 'newSongs', limit: 5, source: 'kugou' }],
    ['网易云 search  ', { action: 'search', keyword: '周杰伦', limit: 5 }],
    ['酷狗   search  ', { action: 'search', keyword: '周杰伦', limit: 5, source: 'kugou' }],
]) {
    const r = await fn(body);
    const list = r.list || [];
    console.log(`\n=== ${label} : ok=${r.ok} 条数=${list.length} ===`);
    for (const it of list) {
        const c = String(it.cover || '');
        console.log(
            `  ${(it.name || '').slice(0, 18).padEnd(20)} cover=${c ? c.slice(0, 52) : '（空）'}`,
        );
    }
    // 只对前 2 条做真实请求，避免刷爆
    for (const it of list.slice(0, 2)) {
        console.log(`  ↳ 实测「${(it.name || '').slice(0, 14)}」的封面: ${await head(it.cover)}`);
    }
}
