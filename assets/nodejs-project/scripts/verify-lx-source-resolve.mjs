// 用**真实第三方音源 + 真实 payload**测"能不能取到播放地址"（= 音乐模块的真实路径）。
//
//     cd assets/nodejs-project
//     node scripts/verify-lx-source-resolve.mjs "https://..../xxx.js" [平台码] [歌曲id] [音质]
//
// payload 形状照 `source_resolver.js:230-237` 的文档（Beans 的做法）：
//   { action:'musicUrl', source:'wy'|'tx'|'kg'|'kw'|'mg',
//     info:{ type, musicInfo:{…} }, _types:{}, meta:{}, …musicInfo 平铺 }
import axios from 'axios';
import { loadScript, runAction } from '../src/lx_engine.js';

const url = process.argv[2] || 'https://zrcdy.dpdns.org/lx/xinghai-music-sourcev2.3.14.js';
const platform = process.argv[3] || 'wy';
const songId = process.argv[4] || '186016'; // 网易云《晴天》
const quality = process.argv[5] || '320k';

const r = await axios.get(url, {
    timeout: 20000,
    responseType: 'text',
    transformResponse: [(v) => v],
    headers: { 'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)' },
    maxRedirects: 5,
    validateStatus: (c) => c >= 200 && c < 400,
});
const src = typeof r.data === 'string' ? r.data : String(r.data);
console.log(`脚本: HTTP ${r.status}，${src.length} 字符`);

const loaded = await loadScript(src);
console.log('加载:', loaded.ok ? '✅ ok' : '❌ ' + loaded.error);
if (!loaded.ok) process.exit(2);
console.log('动作:', JSON.stringify(loaded.actions));

const musicInfo = { id: songId, name: '晴天', singer: '周杰伦', albumName: '叶惠美' };
const payload = {
    action: 'musicUrl',
    source: platform,
    info: { type: quality, musicInfo },
    _types: {},
    meta: {},
    // 平铺一份（很多脚本直接读 payload.id / payload.name）
    ...musicInfo,
};

console.log(`\n调用 request：source=${platform} id=${songId} type=${quality}`);
const t0 = Date.now();
let out;
try {
    // ⚠️ 真实签名是 `runAction(handlers, action, payload)`（三个参数！）
    // 我第一次只传了 (action, payload) → 引擎把 payload 当成了 action 名，
    // 于是报 `脚本未实现 action: [object Object]` ✗（是测试的锅，不是引擎的 ✓）
    out = await runAction(loaded.handlers, 'request', payload);
} catch (e) {
    console.log('❌ 抛异常:', e && e.message);
    process.exit(3);
}
const ms = Date.now() - t0;
console.log(`耗时 ${ms}ms`);
const brief = typeof out === 'object' ? JSON.stringify(out).slice(0, 400) : String(out);
console.log('返回:', brief);

const gotUrl = out && (out.url || (out.data && out.data.url));
if (gotUrl) {
    console.log(`\n✅ **取到地址** → ${String(gotUrl).slice(0, 120)}`);
    process.exit(0);
}
console.log('\n❌ 没取到地址（看上面的 error / 返回结构）');
process.exit(1);
