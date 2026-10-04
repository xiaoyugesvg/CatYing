// 诊断：网易云封面为什么加载不出来（酷狗却能）。
//     cd assets/nodejs-project && node scripts/diag-cover-headers.mjs
//
// 思路：同一张封面分别用「无头 / 仅 UA / UA+Referer」请求，看服务端怎么答。
// 若只有带 Referer 才 200 → 说明图床校验来源，App 侧图片加载器没带这个头。
import axios from 'axios';
import * as m from '../src/music_source.js';

const fn = m.handleMusicApi;
const UA =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148';

async function probe(label, url, headers) {
    if (!url) {
        console.log(`❌ ${label}: 没有 URL`);
        return;
    }
    try {
        const r = await axios.get(url, {
            timeout: 15000,
            responseType: 'arraybuffer',
            headers,
            validateStatus: () => true,
        });
        const n = r.data ? r.data.byteLength : 0;
        console.log(
            `${r.status === 200 ? '✅' : '❌'} ${label}: HTTP ${r.status} ` +
                `${r.headers['content-type'] || '?'} ${n}B`,
        );
    } catch (e) {
        console.log(`❌ ${label}: ${e.message}`);
    }
}

const variants = [
    ['无任何头', {}],
    ['仅 User-Agent', { 'User-Agent': UA }],
    ['UA + Referer', { 'User-Agent': UA, Referer: 'https://music.163.com/' }],
];

const n = await fn({ action: 'search', keyword: '周杰伦', limit: 1 });
const nUrl = (n.list || [])[0]?.cover;
console.log('网易云封面 URL:', nUrl);
for (const [label, h] of variants) await probe('网易云 | ' + label, nUrl, h);

const k = await fn({ action: 'search', keyword: '周杰伦', limit: 1, source: 'kugou' });
const kUrl = (k.list || [])[0]?.cover;
console.log('\n酷狗封面 URL:', kUrl);
for (const [label, h] of variants) await probe('酷狗 | ' + label, kUrl, h);

const x = await fn({ action: 'search', keyword: '庆余年', source: 'ximalaya' });
const xUrl = (x.list || [])[0]?.cover;
console.log('\n喜马拉雅封面 URL:', xUrl);
for (const [label, h] of variants) await probe('喜马拉雅 | ' + label, xUrl, h);
