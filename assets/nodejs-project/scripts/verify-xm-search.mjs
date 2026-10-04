// 验证：音乐搜索走 source=ximalaya 时，Node 侧返回的"专辑映射成 Song"结构是否正确。
//     cd assets/nodejs-project && node scripts/verify-xm-search.mjs
import * as m from '../src/music_source.js';

const fn = m.handleMusicApi ?? m.default?.handleMusicApi;
if (typeof fn !== 'function') {
    console.log('❌ 找不到 handleMusicApi 导出，实际导出：', Object.keys(m));
    process.exit(1);
}

let bad = 0;
const check = (n, ok, extra = '') => {
    console.log(`${ok ? '✅' : '❌'} ${n}${extra ? '  ' + extra : ''}`);
    if (!ok) bad++;
};

console.log('=== source=ximalaya, action=search, keyword=庆余年 ===');
const r = await fn({ action: 'search', keyword: '庆余年', source: 'ximalaya' });
check('ok', r.ok === true, r.error || '');
const list = r.list || [];
check('有结果', list.length > 0, `${list.length} 条`);
const first = list[0] || {};
const keys = Object.keys(first).sort();
console.log('  首条字段:', keys.join(', '));
check('带 source=ximalaya', first.source === 'ximalaya');
check('带 kind=album（UI 据此进专辑页）', first.kind === 'album');
check('id 是专辑 id', /^\d+$/.test(String(first.id || '')));
console.log('  示例:', JSON.stringify({
    id: first.id, name: (first.name || '').slice(0, 30),
    artist: (first.artist || '').slice(0, 20), cover: (first.cover || '').slice(0, 46),
    kind: first.kind, source: first.source,
}, null, 0));

console.log('\n=== 对照：不传 source（必须仍是网易云）===');
const r2 = await fn({ action: 'search', keyword: '周杰伦', limit: 2 });
check('ok', r2.ok === true, r2.error || '');
const f2 = (r2.list || [])[0] || {};
check('网易云结构没变（无 kind 字段）', f2.kind === undefined,
    `keys=${Object.keys(f2).sort().join(',')}`);

console.log(bad === 0 ? '\n全部通过 ✅' : `\n${bad} 项失败 ❌`);
process.exit(bad === 0 ? 0 : 1);
