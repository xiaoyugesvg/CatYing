// 音质透传回归验证（**完全离线**，不需要外网、不需要真实音源）
//
// 为什么留这个脚本：
//   用户设置页的「音质」曾经**完全不起作用** —— `player_manager` 手里有
//   `wantQuality`，但往下每一层都没有这个参数，Node 侧最终落回
//   `source.quality || '320k'`。第三方源于是永远 320k，选无损/Hi-Res 等于
//   按了个没接线的开关。这种"参数在半路丢了"的 bug **不会报错**，
//   只会让功能静默失效，所以必须有一个能一键跑出来的断言。
//
// 跑法：
//     cd assets/nodejs-project
//     node scripts/verify-quality-passthrough.mjs
//
import process from 'node:process';
import { clampQuality } from '../src/source_resolver.js';
import { handleMusicApi } from '../src/music_source.js';

// 假 LX 脚本：把**它自己收到的** quality / info.type / _types 回显进 URL。
// 真实音源没法直接观察"脚本看到了什么"，用回显脚本才能把契约钉死。
const ECHO_SCRIPT = `
lx.on('request', async (payload) => {
  const p = payload.payload || payload;
  const seen = encodeURIComponent(JSON.stringify({
    quality: p.quality,
    infoType: p.info && p.info.type,
    types: p._types,
    source: p.source,
  }));
  return { url: 'https://example.com/a.mp3?seen=' + seen };
});
lx.send('inited', {
  status: true,
  sources: { wy: { name: 'wy', type: 'music', actions: ['musicUrl'], qualitys: ['128k', '320k', 'flac'] } },
});
`;

// 源默认档故意设成 320k：用来验证"用户设置 > 源默认档"
const SOURCE = {
  id: 'probe',
  name: 'probe',
  kind: 'script',
  script: ECHO_SCRIPT,
  quality: '320k',
  enabled: true,
};
const SONG = { id: 9, name: 't', artists: 'a', source: 'netease', songmid: 'MID9' };

/** 调一次解析，把脚本实际收到的 payload 解出来 */
async function resolveAndRead(quality) {
  const body = { action: 'resolveBySource', source: SOURCE, song: SONG };
  if (quality !== undefined) body.quality = quality;
  const r = await handleMusicApi(body);
  if (!r.ok) return { ok: false, error: r.error };
  const seen = JSON.parse(decodeURIComponent(new URL(r.url).searchParams.get('seen')));
  return { ok: true, quality: r.quality, seen };
}

// ── ① clampQuality：按源声明的档位降级 ──────────────────────────
const clampCases = [
  ['hires → flac（源最高只到 flac）', clampQuality('hires', ['128k', '320k', 'flac']), 'flac'],
  ['flac 命中直接返回', clampQuality('flac', ['128k', '320k', 'flac']), 'flac'],
  ['320k 降到 128k（源只有 128k）', clampQuality('320k', ['128k']), '128k'],
  ['128k 比所有档都低 → 取最低的', clampQuality('128k', ['320k', 'flac']), '320k'],
  ['源没声明档位 → 不收敛', clampQuality('hires', null), 'hires'],
  ['未传 → 默认 320k', clampQuality(undefined, ['128k', '320k']), '320k'],
  ['hires 在支持列表里 → 保留', clampQuality('hires', ['128k', 'flac24bit', 'hires']), 'hires'],
];
const clampChecks = clampCases.map(([name, got, want]) => [
  `clampQuality：${name}`,
  got === want,
]);

// ── ② 端到端：Dart 的 quality 真的到达脚本 ──────────────────────
const hires = await resolveAndRead('hires');
const low = await resolveAndRead('128k');
const none = await resolveAndRead(undefined);

const e2eChecks = [
  ['hires：脚本收到降级后的 flac', hires.ok && hires.seen.quality === 'flac'],
  ['hires：info.type 同步为 flac', hires.ok && hires.seen.infoType === 'flac'],
  ['hires：_types 里是 flac 档', hires.ok && !!hires.seen.types?.flac],
  ['hires：回传给 Dart 的是 flac（不是 hires）', hires.ok && hires.quality === 'flac'],
  ['128k：脚本收到 128k', low.ok && low.seen.quality === '128k'],
  ['128k：_types 里是 128k 档', low.ok && !!low.seen.types?.['128k']],
  ['不传 quality：落回源默认 320k', none.ok && none.seen.quality === '320k'],
  ['_types 带上了原生 id（hash）', none.ok && none.seen.types?.['320k']?.hash === 'MID9'],
  ['source 平台码透传为 wy', none.ok && none.seen.source === 'wy'],
];

const checks = [...clampChecks, ...e2eChecks];
let bad = 0;
for (const [name, ok] of checks) {
  console.log(`${ok ? '✅' : '❌'} ${name}`);
  if (!ok) bad++;
}
if (bad > 0) {
  console.log('\n实际收到的 payload：');
  console.log('  hires =', JSON.stringify(hires));
  console.log('  128k  =', JSON.stringify(low));
  console.log('  不传  =', JSON.stringify(none));
}
console.log(bad === 0 ? '\n全部通过 ✅' : `\n${bad} 项失败 ❌`);
process.exit(bad === 0 ? 0 : 1);
