/**
 * 验证 dist/main.js 能被真正加载并对外提供 /music/api。
 *
 * 为什么要这样验证：
 *   `assets/nodejs-project/package.json` 是 `"type": "module"`，而 esbuild 产物是 **CJS**。
 *   直接 `node dist/main.js` 会因 ESM/CJS 冲突报
 *   `ReferenceError: require is not defined in ES module scope` ——
 *   但设备上是把 `dist/main.js` 解压到 `<AppSupport>/nodejs/main.js`（那里没有
 *   `"type": "module"` 的 package.json），所以是 CJS 环境。
 *   本脚本照设备的方式：把 main.js 复制到临时目录 + `{"type":"commonjs"}`，再启动。
 *
 * 跑法：node scripts/verify-dist.mjs
 */

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const DIST = path.join(ROOT, 'dist', 'main.js');

if (!fs.existsSync(DIST)) {
    console.error('dist/main.js 不存在，先 npm run build');
    process.exit(1);
}

const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'kgdist-'));
fs.copyFileSync(DIST, path.join(stage, 'main.js'));
fs.writeFileSync(path.join(stage, 'package.json'), JSON.stringify({ type: 'commonjs' }));

const size = fs.statSync(DIST).size;
const md5File = path.join(ROOT, 'dist', 'main.js.md5');
console.log('=== 加载验证 ===');
console.log('dist/main.js      :', size, 'bytes');
console.log('dist/main.js.md5  :', fs.existsSync(md5File) ? fs.readFileSync(md5File, 'utf8').trim() : '(缺失)');
console.log('暂存目录（模拟设备）:', stage);

const env = Object.assign({}, process.env);
if (process.env.KUGOU_BRIDGE_PROXY) env.KUGOU_BRIDGE_PROXY = process.env.KUGOU_BRIDGE_PROXY;
env.DSH_DATA_DIR = path.join(stage, 'data'); // 让设备身份文件落在临时目录，不污染真实数据目录

const child = spawn(process.execPath, [path.join(stage, 'main.js')], {
    cwd: stage,
    env,
    stdio: ['ignore', 'pipe', 'pipe'],
});

let out = '';
const onData = (b) => {
    out += b.toString();
};
child.stdout.on('data', onData);
child.stderr.on('data', onData);

/** 等日志里出现 mgmtServer 端口 */
function waitPort(timeoutMs = 25000) {
    return new Promise((resolve, reject) => {
        const t0 = Date.now();
        const tick = () => {
            const m = out.match(/mgmtServer listening on port (\d+)/);
            if (m) return resolve(Number(m[1]));
            if (Date.now() - t0 > timeoutMs) return reject(new Error('等待 mgmtServer 端口超时；日志：\n' + out.slice(-2000)));
            setTimeout(tick, 200);
        };
        tick();
    });
}

let exitCode = null;
child.on('exit', (c) => {
    exitCode = c;
});

async function post(port, body) {
    const res = await fetch(`http://127.0.0.1:${port}/music/api`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
    });
    return res.json();
}

try {
    const port = await waitPort();
    console.log('mgmtServer 端口    :', port, '（进程已成功加载 bundle 并监听）');

    // 1) kugouSelfTest（不联网）
    const st = await post(port, { action: 'kugouSelfTest' });
    console.log('\n[dist] kugouSelfTest ok =', st.ok,
        '| deps =', (st.deps || []).map((d) => d.name + ':' + d.ok).join(','),
        '| device.from =', st.device && st.device.from);

    // 2) 默认 source（不传）必须还是网易云结构（无 source 字段）
    const ne = await post(port, { action: 'search', keyword: '周杰伦', limit: 1 });
    console.log('[dist] 默认 search(不传 source): ok =', ne.ok, '| 首条键 =', JSON.stringify(Object.keys((ne.list || [])[0] || {})));

    // 3) 酷狗搜索（联网）
    const kg = await post(port, { action: 'search', keyword: '周杰伦', limit: 3, source: 'kugou' });
    console.log('[dist] kugou search: ok =', kg.ok, 'total =', kg.total, 'error =', kg.error || '-');
    for (const x of (kg.list || []).slice(0, 3)) console.log('    ', x.name, '/', x.artist, '/', x.duration + 's', '/ id=' + x.id, '/ source=' + x.source);

    // 4) 酷狗歌词
    if (kg.ok && kg.list[0]) {
        const l = await post(port, { action: 'lyric', id: kg.list[0].id, source: 'kugou' });
        console.log('[dist] kugou lyric: ok =', l.ok, 'len =', (l.lyric || '').length, '前 60 =', JSON.stringify(String(l.lyric || '').slice(0, 60)));
    }

    // 5) 不支持的接口
    const un = await post(port, { action: 'personalized', limit: 1, source: 'kugou' });
    console.log('[dist] kugou personalized（不支持）: ok =', un.ok, 'error =', un.error);
} catch (e) {
    console.error('验证失败：' + ((e && e.message) || e));
} finally {
    child.kill();
    await new Promise((r) => setTimeout(r, 300));
    console.log('\n子进程退出码（被 kill 则非 0 属正常）:', exitCode);
    try {
        fs.rmSync(stage, { recursive: true, force: true });
    } catch {}
}
process.exit(0);
