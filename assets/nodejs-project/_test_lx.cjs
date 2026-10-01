// LX 引擎自检：真实启动 Node，POST /music/api {action:'lxSelfTest'}
const fs = require('fs'), os = require('os'), path = require('path');
const { spawn } = require('child_process');
const SRC = path.join(__dirname, 'dist', 'main.js');
const NM = path.join(__dirname, 'node_modules');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lxtest-'));
fs.copyFileSync(SRC, path.join(tmp, 'main.cjs'));
try { fs.symlinkSync(NM, path.join(tmp, 'node_modules'), 'junction'); }
catch (_) { fs.cpSync(NM, path.join(tmp, 'node_modules'), { recursive: true }); }

(async () => {
  const child = spawn(process.execPath, [path.join(tmp, 'main.cjs')], { stdio: ['ignore','pipe','pipe'] });
  let out = '', done = false;
  const port = await new Promise((res, rej) => {
    const to = setTimeout(() => rej(new Error('启动超时\n' + out.slice(-400))), 25000);
    const on = (b) => { out += b.toString();
      const m = out.match(/(?:mgmt)?[Ss]erver listening on port (\d+)/);
      if (m && !done) { done = true; clearTimeout(to); setTimeout(() => res(+m[1]), 400); } };
    child.stdout.on('data', on); child.stderr.on('data', on);
    child.on('exit', (c) => { if (!done) { done = true; clearTimeout(to); rej(new Error('退出 ' + c)); } });
  });
  const r = await (await fetch('http://127.0.0.1:' + port + '/music/api', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ action: 'lxSelfTest' }),
  })).json();

  console.log('  引擎配置: 超时 ' + r.info.timeoutMs + 'ms, 脚本上限 ' +
    (r.info.maxScriptChars/1024) + 'KB, 沙箱=' + r.info.sandboxed);
  console.log('  已禁用: ' + r.info.denied.join(' / '));
  console.log('');
  for (const c of r.cases) {
    console.log('  ' + (c.pass ? '[OK]  ' : '[FAIL]') + ' ' + c.name.padEnd(30) + c.ms + 'ms' +
      (c.error ? '   ' + c.error.slice(0, 60) : ''));
  }
  console.log('\n  结果: ' + r.pass + '/' + r.total + (r.allPass ? '  ✅ 沙箱与超时全部生效' : '  ❌ 有失败'));
  // 退出码由断言决定。清理/杀子进程都是 best-effort，
  // 失败不能影响结论（Windows 上删 junction 常被占用）。
  const code = r.allPass ? 0 : 1;
  try { child.kill(); } catch (_) {}
  try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (_) {}
  console.log(code === 0 ? '' : '');
  setTimeout(() => process.exit(code), 400);
})().catch((e) => { console.error('  [ERR] ' + e.message); process.exit(1); });
