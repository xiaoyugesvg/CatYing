/**
 * `/music/api` 分派验证（真实联网）—— 验证"不传 source 时行为与改动前一致"。
 *
 * 跑法：
 *     $env:KUGOU_BRIDGE_PROXY='http://127.0.0.1:10808'; node scripts/verify-dispatch.mjs
 *
 * 只读、不改任何东西；用真实网络比对 netease 与 kugou 两条分支。
 */

const proxy = process.env.KUGOU_BRIDGE_PROXY || process.env.HTTPS_PROXY || '';
if (proxy) process.env.KUGOU_BRIDGE_PROXY = proxy;

const ms = await import('../src/music_source.js');

function hr(t) {
    console.log('\n' + '─'.repeat(72) + '\n' + t + '\n' + '─'.repeat(72));
}
const j = (v) => JSON.stringify(v).slice(0, 400);

hr('A) 默认 source（不传）必须走网易云：与显式 source=netease 逐字节一致');

const a1 = await ms.handleMusicApi({ action: 'search', keyword: '周杰伦', limit: 2, offset: 0 });
const a2 = await ms.handleMusicApi({ action: 'search', keyword: '周杰伦', limit: 2, offset: 0, source: 'netease' });
const a3 = await ms.handleMusicApi({ action: 'search', keyword: '周杰伦', limit: 2, offset: 0, source: 'wy' });
const a4 = await ms.handleMusicApi({ action: 'search', keyword: '周杰伦', limit: 2, offset: 0, source: '' });
const a5 = await ms.handleMusicApi({ action: 'search', keyword: '周杰伦', limit: 2, offset: 0, source: null });

console.log('不传       :', a1.ok, 'n =', (a1.list || []).length, j((a1.list || [])[0]));
console.log('netease    :', a2.ok, 'n =', (a2.list || []).length);
console.log('wy         :', a3.ok, 'n =', (a3.list || []).length);
console.log("''         :", a4.ok, 'n =', (a4.list || []).length);
console.log('null       :', a5.ok, 'n =', (a5.list || []).length);
console.log('未知值 qq  :', (await ms.handleMusicApi({ action: 'search', keyword: '周杰伦', limit: 1, source: 'qq' })).ok, '(应回落 netease)');

// ⚠️ 不能直接比 JSON 全等：网易云搜索结果本身每次都会变（同一首 live 版排序不同），
//    所以"逐字节一致"只能证明**代码路径**一致 —— 比结构（键集合）与行为。
const eq = (x, y) => JSON.stringify(x) === JSON.stringify(y);
const shape = (r) => JSON.stringify((r.list || []).map((x) => Object.keys(x).sort()).slice(0, 1)) + '|ok=' + r.ok + '|total=' + (typeof r.total) + '|listLen=' + (r.list || []).length;
console.log('\n结构一致（不传 vs netease）:', eq(shape(a1), shape(a2)), shape(a1));
console.log('结构一致（不传 vs wy）     :', eq(shape(a1), shape(a3)));
console.log('结构一致（不传 vs ""）     :', eq(shape(a1), shape(a4)));
console.log('结构一致（不传 vs null）   :', eq(shape(a1), shape(a5)));
console.log('结构一致（不传 vs qq 回落）:', eq(shape(a1), shape(await ms.handleMusicApi({ action: 'search', keyword: '周杰伦', limit: 2, source: 'qq' }))));
console.log('结果里没有 source 字段（网易云结构未变）:', !(a1.list || []).some((x) => 'source' in x));

hr('B) source=kugou：分派到酷狗桥接层');
const k1 = await ms.handleMusicApi({ action: 'search', keyword: '周杰伦', limit: 3, offset: 0, source: 'kugou' });
console.log('kugou search ok =', k1.ok, 'total =', k1.total, 'error =', k1.error || '-');
for (const x of (k1.list || []).slice(0, 3)) {
    console.log(`   ${x.name} / ${x.artist} / ${x.duration}s / id=${x.id} / source=${x.source} / hash=${x.hash}`);
}
const k2 = await ms.handleMusicApi({ action: 'search', keyword: '周杰伦', limit: 3, source: 'kg' });
console.log("别名 'kg' 也走酷狗 :", k2.ok && (k2.list || []).every((x) => x.source === 'kugou'));

hr('C) source=kugou：url / lyric');
const first = (k1.list || [])[0];
if (first) {
    const u = await ms.handleMusicApi({ action: 'url', id: first.id, quality: 'exhigh', source: 'kugou' });
    console.log('url(晴天, exhigh) =', j({ ok: u.ok, reason: u.reason, message: u.message, br: u.br, error: u.error }));
    const l = await ms.handleMusicApi({ action: 'lyric', id: first.id, source: 'kugou' });
    console.log('lyric(晴天) ok =', l.ok, 'len =', (l.lyric || '').length, 'error =', l.error || '-');
}
// 免费曲目
const free = await ms.handleMusicApi({ action: 'search', keyword: '卡农 钢琴', limit: 5, source: 'kugou' });
for (const cand of free.list || []) {
    const u = await ms.handleMusicApi({ action: 'url', id: cand.id, quality: 'exhigh', source: 'kugou' });
    console.log(`   url(${cand.name}) = ok=${u.ok} br=${u.br} type=${u.type} url=${String(u.url || '').slice(0, 60)} reason=${u.reason || '-'}`);
    if (u.url) break;
}

hr('D) source=kugou：不支持的接口必须明确返回，不假装成功');
for (const action of ['personalized', 'playlistSquare', 'playlistCatlist', 'comments', 'simiSongs', 'searchArtists', 'searchAlbums', 'artistSongs', 'artistAlbums', 'albumSongs']) {
    const r = await ms.handleMusicApi({ action, keyword: 'x', id: '1', limit: 1, source: 'kugou' });
    console.log(`   ${action.padEnd(16)} -> ok=${r.ok} error=${r.error}`);
}
// 支持的
for (const [action, body] of [['topLists', {}], ['playlistDetail', { id: '8888' }], ['hotSearch', {}], ['newSongs', { limit: 2 }]]) {
    const r = await ms.handleMusicApi(Object.assign({ action, source: 'kugou' }, body));
    console.log(`   ${action.padEnd(16)} -> ok=${r.ok} n=${(r.list || []).length} error=${r.error || '-'}`);
}

hr('E) kugouSelfTest（不联网）');
const st = await ms.handleMusicApi({ action: 'kugouSelfTest' });
console.log('ok =', st.ok, ' deps =', st.deps.map((d) => d.name + ':' + d.ok).join(','), ' device.from =', st.device && st.device.from);

hr('F) 不传 source 时 kugouSelfTest 也能用（不受 source 影响）');
const st2 = await ms.handleMusicApi({ action: 'kugouSelfTest', source: 'netease' });
console.log('ok =', st2.ok);

hr('完成');
process.exit(0);
