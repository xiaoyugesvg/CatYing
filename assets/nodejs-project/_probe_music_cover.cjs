// 探针：实测音乐接口返回的封面字段（判断"没封面"是后端没给还是前端没读）
// 跑法： node _probe_music_cover.cjs
const fs = require('fs'), os = require('os'), path = require('path');
const { spawn } = require('child_process');
const SRC = path.join(__dirname, 'dist', 'main.js');
const NM = path.join(__dirname, 'node_modules');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'musicprobe-'));
fs.copyFileSync(SRC, path.join(tmp, 'main.cjs'));
try { fs.symlinkSync(NM, path.join(tmp, 'node_modules'), 'junction'); }
catch (_) { fs.cpSync(NM, path.join(tmp, 'node_modules'), { recursive: true }); }

async function call(port, body) {
  const r = await fetch('http://127.0.0.1:' + port + '/music/api', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  return r.json();
}

/** 递归找出对象里所有像"封面地址"的字段 */
function findCoverFields(obj, prefix = '', out = {}, depth = 0) {
  if (!obj || typeof obj !== 'object' || depth > 3) return out;
  if (Array.isArray(obj)) {
    if (obj.length) findCoverFields(obj[0], prefix + '[0]', out, depth + 1);
    return out;
  }
  for (const [k, v] of Object.entries(obj)) {
    const key = prefix ? prefix + '.' + k : k;
    if (/cover|pic|img|image|avatar/i.test(k) && (typeof v === 'string' || v === null)) {
      out[key] = v;
    } else if (v && typeof v === 'object') {
      findCoverFields(v, key, out, depth + 1);
    }
  }
  return out;
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

  // 先拿一个榜单 id，用来测 playlistDetail
  let topId = null;
  try {
    const tl = await call(port, { action: 'topLists' });
    topId = tl?.list?.[0]?.id ?? null;
    console.log('  榜单 id = ' + topId);
  } catch (_) {}
  console.log('');

  const cases = [
    ['playlistDetail(榜单一)', { action: 'playlistDetail', id: topId }],
    ['topLists', { action: 'topLists' }],
    ['personalized', { action: 'personalized', limit: 3 }],
    ['playlistSquare', { action: 'playlistSquare', cat: '全部', order: 'hot', limit: 3 }],
    ['search', { action: 'search', keyword: '情话小姐', limit: 3 }],
    ['newSongs', { action: 'newSongs', limit: 3 }],
  ];

  for (const [name, body] of cases) {
    try {
      const r = await call(port, body);
      const covers = findCoverFields(r);
      const entries = Object.entries(covers);
      const empty = entries.filter(([, v]) => !v || String(v).trim() === '');
      console.log('  ── ' + name + ' ──');
      console.log('     ok=' + r.ok + (r.error ? '  error=' + r.error : ''));
      console.log('     找到封面字段 ' + entries.length + ' 个，其中**空值 ' + empty.length + ' 个**');
      for (const [k, v] of entries.slice(0, 6)) {
        console.log('       ' + k.padEnd(34) + ' = ' + String(v).slice(0, 62));
      }
      if (entries.length === 0) {
        console.log('       ⚠️ 压根没有封面字段。返回的顶层键: ' +
          Object.keys(r).slice(0, 12).join(', '));
      }
    } catch (e) {
      console.log('  ── ' + name + ' ── 抛异常: ' + e.message);
    }
    console.log('');
  }

  // ── 关键：把每个接口返回的**完整封面 URL** 逐个下载验证 ──────
  console.log('  ══ 每个接口的完整封面 URL 可下载性 ══');
  for (const [name, body] of [
    ['playlistDetail.list[0]', { action: 'playlistDetail', id: topId }],
    ['topLists', { action: 'topLists' }],
    ['personalized', { action: 'personalized', limit: 1 }],
    ['playlistSquare', { action: 'playlistSquare', cat: '全部', order: 'hot', limit: 1 }],
    ['search', { action: 'search', keyword: '情话小姐', limit: 1 }],
    ['newSongs', { action: 'newSongs', limit: 1 }],
  ]) {
    try {
      const r = await call(port, body);
      const covers = Object.entries(findCoverFields(r));
      for (const [k, url] of covers) {
        if (!url) continue;
        try {
          const resp = await fetch(url);
          const buf = Buffer.from(await resp.arrayBuffer());
          const ct = resp.headers.get('content-type') || '';
          const isImg = /^image\//i.test(ct);
          console.log('     ' + name.padEnd(24) + ' ' + String(url).slice(0, 46).padEnd(48) +
            ' HTTP ' + resp.status + ' ' + String(buf.length).padStart(7) + 'B ' +
            (isImg ? 'IMAGE ✅' : '⚠️ ' + ct));
        } catch (e) {
          console.log('     ' + name.padEnd(24) + ' ' + String(url).slice(0, 46).padEnd(48) +
            ' 抛异常 ' + e.message.slice(0, 40));
        }
      }
    } catch (e) { console.log('     ' + name + ' 失败: ' + e.message); }
  }
  console.log('');

  try { child.kill(); } catch (_) {}
  try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (_) {}
  setTimeout(() => process.exit(0), 300);
})().catch((e) => { console.error('  [ERR] ' + e.message); process.exit(1); });
