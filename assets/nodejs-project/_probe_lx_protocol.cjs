// A2 探针：用**真实引擎**验证「脚本未实现 musicUrl」的两种情形。
//
// 不是读代码猜 —— 是真的起 Node、真的 POST /music/api。
// 跑法： node _probe_lx_protocol.cjs
const fs = require('fs'), os = require('os'), path = require('path');
const { spawn } = require('child_process');
const SRC = path.join(__dirname, 'dist', 'main.js');
const NM = path.join(__dirname, 'node_modules');

const SONG = { id: '12345', name: '九月', artists: '测试歌手', album: '测试专辑' };

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lxprobe-'));
fs.copyFileSync(SRC, path.join(tmp, 'main.cjs'));
try { fs.symlinkSync(NM, path.join(tmp, 'node_modules'), 'junction'); }
catch (_) { fs.cpSync(NM, path.join(tmp, 'node_modules'), { recursive: true }); }

/** 一个自定义音源的完整生命周期测试 */
async function call(port, body) {
  const r = await fetch('http://127.0.0.1:' + port + '/music/api', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  return r.json();
}

(async () => {
  const child = spawn(process.execPath, [path.join(tmp, 'main.cjs')],
    { stdio: ['ignore', 'pipe', 'pipe'] });
  let out = '', done = false;
  const port = await new Promise((res, rej) => {
    const to = setTimeout(() => rej(new Error('启动超时\n' + out.slice(-400))), 25000);
    const on = (b) => {
      out += b.toString();
      const m = out.match(/(?:mgmt)?[Ss]erver listening on port (\d+)/);
      if (m && !done) { done = true; clearTimeout(to); setTimeout(() => res(+m[1]), 400); }
    };
    child.stdout.on('data', on); child.stderr.on('data', on);
    child.on('exit', (c) => { if (!done) { done = true; clearTimeout(to); rej(new Error('退出 ' + c)); } });
  });

  // ── A. 用户的脚本形状：注册 request（LX 最通用的写法）──────────
  // 移植 Beans 的入口链后，这个**应该能通**了
  const userShape = `
lx.on('request', async (payload) => {
  // LX 脚本从 payload.action 判断要做什么
  if (payload.action !== 'musicUrl') return null;
  return { url: 'https://cdn.example.com/lx-' + payload.musicInfo.id + '.mp3' };
});
`;
  const A = await call(port, {
    action: 'resolveBySource', song: SONG,
    source: { kind: 'script', script: userShape },
  });
  console.log('  A. lx.on(\'request\') —— LX 最通用写法');
  console.log('     ok=' + A.ok + '  url=' + JSON.stringify(A.url) + '  error=' + JSON.stringify(A.error));

  // ── A2. request 里用 payload.source / payload.info.type 分派 ──
  const userShape2 = `
lx.on('request', async (payload) => {
  if (payload.action !== 'musicUrl') return null;
  const plat = payload.source;        // wy / tx / kg
  const q = payload.info.type;        // 320k ...
  return { data: { musicUrl: 'https://cdn.example.com/' + plat + '-' + q + '-' + payload.id + '.mp3' } };
});
`;
  const A2 = await call(port, {
    action: 'resolveBySource',
    song: Object.assign({}, SONG, { source: 'tx' }),
    source: { kind: 'script', script: userShape2, quality: '320k' },
  });
  console.log('  A2. request + 平台/音质分派 + 返回 {data:{musicUrl}}');
  console.log('     ok=' + A2.ok + '  url=' + JSON.stringify(A2.url) + '  error=' + JSON.stringify(A2.error));

  // ── A3. 旧结构（{musicInfo, quality}）不能弄坏 ────────────────
  const legacy = `
lx.on('musicUrl', async (info) => {
  return { url: 'https://cdn.example.com/legacy-' + info.musicInfo.id + '.mp3' };
});
`;
  const A3 = await call(port, {
    action: 'resolveBySource', song: SONG,
    source: { kind: 'script', script: legacy },
  });
  console.log('  A3. 旧结构 lx.on(\'musicUrl\')（兼容性）');
  console.log('     ok=' + A3.ok + '  url=' + JSON.stringify(A3.url) + '  error=' + JSON.stringify(A3.error));

  // ── A4. 返回 result.url 嵌套（原来会误报"没返回地址"）────────
  const nested = `
lx.on('request', async (payload) => {
  return { result: { url: 'https://cdn.example.com/nested-' + payload.musicInfo.id + '.mp3' } };
});
`;
  const A4 = await call(port, {
    action: 'resolveBySource', song: SONG,
    source: { kind: 'script', script: nested },
  });
  console.log('  A4. 返回 {result:{url}}（20+ 字段路径兜底）');
  console.log('     ok=' + A4.ok + '  url=' + JSON.stringify(A4.url) + '  error=' + JSON.stringify(A4.error));

  // ── B. 引擎期望的写法1：lx.on('musicUrl') ─────────────────────
  const goodOn = `
lx.on('musicUrl', async (info) => {
  return { url: 'https://cdn.example.com/' + info.musicInfo.id + '.mp3' };
});
`;
  const B = await call(port, {
    action: 'resolveBySource', song: SONG,
    source: { kind: 'script', script: goodOn },
  });
  console.log('  B. lx.on(\'musicUrl\') 写法');
  console.log('     ok=' + B.ok + '  url=' + JSON.stringify(B.url) + '  error=' + JSON.stringify(B.error));

  // ── C. 引擎期望的写法2：module.exports ───────────────────────
  const goodExports = `
module.exports = {
  musicUrl: async (info) => ({ url: 'https://cdn.example.com/m/' + info.musicInfo.id })
};
`;
  const C = await call(port, {
    action: 'resolveBySource', song: SONG,
    source: { kind: 'script', script: goodExports },
  });
  console.log('  C. module.exports 写法');
  console.log('     ok=' + C.ok + '  url=' + JSON.stringify(C.url) + '  error=' + JSON.stringify(C.error));

  // ── D. 用 lx.request 真的去请求（演示"能发网络请求但仍需注册 musicUrl"）──
  const withRequest = `
lx.on('musicUrl', async (info) => {
  const res = await new Promise((resolve, reject) => {
    lx.request('https://httpbin.org/json', {}, (err, resp) => err ? reject(err) : resolve(resp));
  });
  return { url: 'https://cdn.example.com/net-' + info.musicInfo.id + '.mp3' };
});
`;
  const D = await call(port, {
    action: 'resolveBySource', song: SONG,
    source: { kind: 'script', script: withRequest },
  });
  console.log('  D. lx.request + lx.on(\'musicUrl\') 组合（真实脚本应该长这样）');
  console.log('     ok=' + D.ok + '  url=' + JSON.stringify(D.url) + '  error=' + JSON.stringify(D.error));

  console.log('');
  console.log('  ── 结论 ──');
  console.log('  A ' + (A.ok ? 'PASS ✅ request 入口已支持' : 'FAIL') +
    '  A2 ' + (A2.ok ? 'PASS' : 'FAIL') + '  A3 ' + (A3.ok ? 'PASS' : 'FAIL') +
    '  A4 ' + (A4.ok ? 'PASS' : 'FAIL'));
  console.log('  B ' + (B.ok ? 'PASS' : 'FAIL') + '  C ' + (C.ok ? 'PASS' : 'FAIL') +
    '（两种合法写法都可用）');
  console.log('  D ' + (D.ok ? 'PASS' : 'FAIL') + '（合法写法里可以正常用 lx.request 发网络请求）');

  try { child.kill(); } catch (_) {}
  try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (_) {}
  setTimeout(() => process.exit(0), 300);
})().catch((e) => { console.error('  [ERR] ' + e.message); process.exit(1); });
