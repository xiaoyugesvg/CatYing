/**
 * 第三方音源解析的端到端测试。
 *
 * ── 为什么要起本地 mock server ────────────────────────────────
 * 不能用真实音源（会变、会挂、可能侵权），所以本地起一个 HTTP 服务
 * 返回**可预期的 JSON**，这样能精确验证：
 *   · 占位符替换（{name}/{artist}/{id}）是否把值填进去了
 *   · `urlPath` 取值是否命中
 *   · urlPath 配错时有没有兜底（深度搜 url）
 *   · 音源返回非 JSON 时能不能识别纯文本地址
 *   · 音源报 HTTP 500 时错误信息是否可读
 *   · 脚本法是否走沙箱并拿到 url
 *   · 脚本没实现 action 时是否给出**可用清单**（而不是干巴巴的"失败"）
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const { spawn } = require('child_process');

const SRC = path.join(__dirname, 'dist', 'main.js');
const NM = path.join(__dirname, 'node_modules');

// ---------- 本地 mock 音源服务 ----------
let lastQuery = '';
function startMock() {
    return new Promise((res) => {
        const srv = http.createServer((req, rep) => {
            lastQuery = req.url;
            const u = new URL(req.url, 'http://x');
            if (u.pathname === '/ok') {
                // 正常：url 藏在 data.playUrl
                rep.writeHead(200, { 'Content-Type': 'application/json' });
                rep.end(JSON.stringify({ code: 0, data: { playUrl: 'https://cdn.example.com/a.mp3' } }));
            } else if (u.pathname === '/deep') {
                // urlPath 配错时的兜底：地址埋在很深的嵌套里
                rep.writeHead(200, { 'Content-Type': 'application/json' });
                rep.end(JSON.stringify({ a: { b: [{ c: { whatever: 'https://cdn.example.com/deep.mp3' } }] } }));
            } else if (u.pathname === '/plain') {
                // 直接返回纯文本地址
                rep.writeHead(200, { 'Content-Type': 'text/plain' });
                rep.end('https://cdn.example.com/plain.mp3');
            } else if (u.pathname === '/empty') {
                rep.writeHead(200, { 'Content-Type': 'application/json' });
                rep.end(JSON.stringify({ code: 0, data: {} }));
            } else {
                rep.writeHead(500, { 'Content-Type': 'text/plain' });
                rep.end('boom');
            }
        });
        srv.listen(0, '127.0.0.1', () => res({ srv, port: srv.address().port }));
    });
}

// ---------- 起被测的 Node 服务 ----------
function startApp() {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'srctest-'));
    fs.copyFileSync(SRC, path.join(tmp, 'main.cjs'));
    try { fs.symlinkSync(NM, path.join(tmp, 'node_modules'), 'junction'); }
    catch (_) { fs.cpSync(NM, path.join(tmp, 'node_modules'), { recursive: true }); }
    return new Promise((res, rej) => {
        const child = spawn(process.execPath, [path.join(tmp, 'main.cjs')], { stdio: ['ignore', 'pipe', 'pipe'] });
        let out = '', done = false;
        const to = setTimeout(() => rej(new Error('启动超时\n' + out.slice(-400))), 25000);
        const on = (b) => {
            out += b.toString();
            const m = out.match(/(?:mgmt)?[Ss]erver listening on port (\d+)/);
            if (m && !done) {
                done = true; clearTimeout(to);
                setTimeout(() => res({ child, port: +m[1], tmp }), 400);
            }
        };
        child.stdout.on('data', on); child.stderr.on('data', on);
        child.on('exit', (c) => { if (!done) { done = true; clearTimeout(to); rej(new Error('退出 ' + c)); } });
    });
}

(async () => {
    const mock = await startMock();
    const app = await startApp();
    const call = async (body) => (await fetch(`http://127.0.0.1:${app.port}/music/api`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
    })).json();

    const SONG = { id: '12345', name: '测试 歌', artists: '歌手A、歌手B', album: '专辑' };
    const M = `http://127.0.0.1:${mock.port}`;

    const cases = [
        {
            name: '模板法：urlPath 命中',
            body: {
                action: 'resolveBySource', song: SONG,
                source: { kind: 'keyword', template: `${M}/ok?q={name}`, urlPath: 'data.playUrl', quality: '320k' },
            },
            check: (r) => r.ok && r.url === 'https://cdn.example.com/a.mp3' && r.kind === 'keyword',
            diag: (r) => r.url || r.error,
        },
        {
            name: '模板法：占位符真的被替换',
            body: {
                action: 'resolveBySource', song: SONG,
                source: { kind: 'keyword', template: `${M}/ok?n={name}&a={artist}&i={id}`, urlPath: 'data.playUrl' },
            },
            check: (r) => {
                // 上个 case 之后 lastQuery 会被本次覆盖，所以这里单独看替换结果
                const q = decodeURIComponent(lastQuery);
                return r.ok && q.includes('测试 歌') && q.includes('歌手A、歌手B') && q.includes('12345');
            },
            diag: () => decodeURIComponent(lastQuery),
        },
        {
            name: '模板法：urlPath 配错也能兜底找到',
            body: {
                action: 'resolveBySource', song: SONG,
                source: { kind: 'keyword', template: `${M}/deep?x=1`, urlPath: 'wrong.path' },
            },
            check: (r) => r.ok && r.url === 'https://cdn.example.com/deep.mp3',
            diag: (r) => r.url || r.error,
        },
        {
            name: '模板法：纯文本地址也能识别',
            body: {
                action: 'resolveBySource', song: SONG,
                source: { kind: 'keyword', template: `${M}/plain`, urlPath: 'url' },
            },
            check: (r) => r.ok && r.url === 'https://cdn.example.com/plain.mp3',
            diag: (r) => r.url || r.error,
        },
        {
            name: '模板法：响应里没地址 → 明确报错',
            body: {
                action: 'resolveBySource', song: SONG,
                source: { kind: 'keyword', template: `${M}/empty`, urlPath: 'data.playUrl' },
            },
            check: (r) => !r.ok && /没找到播放地址/.test(r.error || ''),
            diag: (r) => r.error,
        },
        {
            name: '模板法：HTTP 500 → 可读错误',
            body: {
                action: 'resolveBySource', song: SONG,
                source: { kind: 'keyword', template: `${M}/boom`, urlPath: 'url' },
            },
            check: (r) => !r.ok && /HTTP 500/.test(r.error || ''),
            diag: (r) => r.error,
        },
        {
            name: '脚本法：lx.on 注册并返回地址',
            body: {
                action: 'resolveBySource', song: SONG,
                source: {
                    kind: 'script',
                    script: `
lx.on('musicUrl', async (info) => {
  return { url: 'https://cdn.example.com/script-' + info.musicInfo.id + '.mp3' };
});`,
                },
            },
            check: (r) => r.ok && r.url === 'https://cdn.example.com/script-12345.mp3' && r.kind === 'script',
            diag: (r) => r.url || r.error,
        },
        {
            name: '脚本法：module.exports 写法',
            body: {
                action: 'resolveBySource', song: SONG,
                source: {
                    kind: 'script',
                    script: `module.exports = { musicUrl: async () => ({ url: 'https://cdn.example.com/me.mp3' }) };`,
                },
            },
            check: (r) => r.ok && r.url === 'https://cdn.example.com/me.mp3',
            diag: (r) => r.url || r.error,
        },
        {
            name: '脚本法：没实现 action → 列出可用清单',
            body: {
                action: 'resolveBySource', song: SONG,
                source: { kind: 'script', script: `lx.on('getLyric', () => ({}));` },
            },
            check: (r) => !r.ok && /getLyric/.test(r.error || ''),
            diag: (r) => r.error,
        },
        {
            name: '脚本法：死循环被超时挡住（不卡死）',
            body: {
                action: 'resolveBySource', song: SONG,
                source: { kind: 'script', script: `while(true){}` },
            },
            check: (r) => !r.ok && /超时/.test(r.error || ''),
            diag: (r) => r.error,
            slow: true,
        },
        {
            name: '停用的音源被拒绝',
            body: {
                action: 'resolveBySource', song: SONG,
                source: { kind: 'keyword', enabled: false, template: `${M}/ok`, urlPath: 'data.playUrl' },
            },
            check: (r) => !r.ok && /停用/.test(r.error || ''),
            diag: (r) => r.error,
        },
    ];

    let pass = 0;
    for (const c of cases) {
        const t0 = Date.now();
        let line;
        try {
            const r = await call(c.body);
            const ok = c.check(r);
            if (ok) pass++;
            line = `  ${ok ? '[OK]  ' : '[FAIL]'}${c.name.padEnd(30)}${String(Date.now() - t0).padStart(6)}ms   ${c.diag(r) || ''}`;
        } catch (e) {
            line = `  [ERR] ${c.name.padEnd(30)}${e.message}`;
        }
        console.log(line);
    }

    console.log(`\n  结果: ${pass}/${cases.length}${pass === cases.length ? '  ✅ 音源解析全部正确' : '  ❌ 有失败'}`);

    try { app.child.kill(); } catch (_) {}
    try { mock.srv.close(); } catch (_) {}
    try { fs.rmSync(app.tmp, { recursive: true, force: true }); } catch (_) {}
    const code = pass === cases.length ? 0 : 1;
    setTimeout(() => process.exit(code), 400);
})().catch((e) => { console.error('  [ERR] ' + e.message); process.exit(1); });
