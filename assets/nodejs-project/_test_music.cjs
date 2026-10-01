/**
 * 端到端测试 /music/api：真实启动 Node 服务，走 HTTP 打接口。
 *
 * ⚠️ 两个坑（都是踩过的）：
 * 1) `main.js` 不 re-export `handleMusicApi`（它是 HTTP 路由暴露的），
 *    所以只能走 HTTP，不能 import 后直接调函数。
 * 2) `dist/main.js` 是 **CJS**（esbuild format:'cjs'），但本项目
 *    package.json 是 `type: module` → 就地启动会被当 ESM，
 *    里面所有 `require("http")` 立刻 ReferenceError。
 *    真机上 NodeMobile 走 `_linkedBinding` 不受影响，
 *    本地测试必须把 bundle 拷到「没有 type:module 的目录」再跑。
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const SRC = process.argv[2] || path.join(__dirname, 'dist', 'main.js');
const NODE_MODULES = path.join(__dirname, 'node_modules');

function prepare() {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'musictest-'));
    fs.copyFileSync(SRC, path.join(tmp, 'main.cjs'));
    // 不写 package.json → 默认 CommonJS，.cjs 更保险
    const nm = path.join(tmp, 'node_modules');
    try {
        fs.symlinkSync(NODE_MODULES, nm, 'junction');
    } catch (_) {
        fs.cpSync(NODE_MODULES, nm, { recursive: true });
    }
    return tmp;
}

function startServer(bundlePath) {
    return new Promise((resolve, reject) => {
        const child = spawn(process.execPath, [bundlePath], { stdio: ['ignore', 'pipe', 'pipe'] });
        let out = '';
        let done = false;
        const timer = setTimeout(() => {
            if (!done) { done = true; try { child.kill(); } catch (_) {} reject(new Error('启动超时\n' + out.slice(-500))); }
        }, 25000);
        const onData = (buf) => {
            out += buf.toString();
            // Dart 侧连的是 NodeJSManager.managementPort，
            // 对应日志里的 mgmtServer（不是主 server）
            const m = out.match(/(?:mgmt)?[Ss]erver listening on port (\d+)/);
            if (m && !done) {
                done = true; clearTimeout(timer);
                setTimeout(() => resolve({ child, port: parseInt(m[1], 10) }), 400);
            }
        };
        child.stdout.on('data', onData);
        child.stderr.on('data', onData);
        child.on('error', (e) => { if (!done) { done = true; clearTimeout(timer); reject(e); } });
        child.on('exit', (c) => { if (!done) { done = true; clearTimeout(timer); reject(new Error('退出 code=' + c + '\n' + out.slice(-700))); } });
    });
}

async function call(port, body) {
    const res = await fetch('http://127.0.0.1:' + port + '/music/api', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
    });
    return res.json();
}

(async () => {
    const tmp = prepare();
    let srv;
    try {
        srv = await startServer(path.join(tmp, 'main.cjs'));
    } catch (e) {
        console.error('  [ERR] 启动失败: ' + e.message);
        try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (_) {}
        process.exit(1);
    }
    console.log('  Node 服务已启动，端口 ' + srv.port + '\n');

    const single = [
        ['search', { keyword: '周杰伦', limit: 3 }],
        ['hotSearch', {}],
        ['topLists', {}],
        ['personalized', { limit: 4 }],
        ['playlistSquare', { cat: '全部', order: 'hot', limit: 4 }],
        ['playlistCatlist', {}],
        ['newSongs', { limit: 4 }],
        ['searchArtists', { keyword: '周杰伦', limit: 3 }],
        ['searchAlbums', { keyword: '周杰伦', limit: 3 }],
    ];

    let pass = 0, fail = 0;
    for (const [action, body] of single) {
        try {
            const r = await call(srv.port, Object.assign({ action }, body));
            const list = (r && r.list) || [];
            if (r && r.ok !== false && list.length > 0) {
                pass++;
                const s = list[0];
                // hotSearch 返回字符串数组，其余返回对象数组
                const label = typeof s === 'string' ? s : ((s && (s.name || s.keyword)) || '');
                console.log('  [OK]   ' + action.padEnd(18) + String(list.length).padStart(4) + ' 条   ' + label);
            } else {
                fail++;
                console.log('  [FAIL] ' + action.padEnd(18) + ((r && r.error) || '空结果'));
            }
        } catch (e) {
            fail++;
            console.log('  [ERR]  ' + action.padEnd(18) + e.message);
        }
    }

    console.log('');
    try {
        const tl = await call(srv.port, { action: 'topLists' });
        if (tl.ok && tl.list.length) {
            let d = await call(srv.port, { action: 'playlistDetail', id: tl.list[0].id });
            if (!d || !d.ok) {
                console.log('  [DIAG] playlistDetail 原始响应: ' + JSON.stringify(d).slice(0, 300));
                // 重试一次（Node 刚跑完 8s 的脚本超时测试，可能还在恢复）
                await new Promise((r) => setTimeout(r, 1500));
                d = await call(srv.port, { action: 'playlistDetail', id: tl.list[0].id });
                console.log('  [DIAG] 重试后: ' + JSON.stringify(d).slice(0, 200));
            }
            const ok = d.ok && d.list && d.list.length > 0;
            ok ? pass++ : fail++;
            console.log('  ' + (ok ? '[OK]  ' : '[FAIL]') + ' playlistDetail    ' + (ok ? d.list.length + ' 首  ' + d.playlist.name : d.error));
            if (ok) {
                const sid = d.list[0].id;
                const lyr = await call(srv.port, { action: 'lyric', id: sid });
                const lok = lyr.ok && (lyr.lyric || '').length > 0;
                console.log('  ' + (lok ? '[OK]  ' : '[WARN]') + ' lyric             ' + (lok ? lyr.lyric.length + ' 字符' : '该曲无歌词（正常）'));
                const cm = await call(srv.port, { action: 'comments', id: sid, limit: 3 });
                console.log('  ' + (cm.ok && cm.list.length ? '[OK]  ' : '[WARN]') + ' comments          ' + (cm.ok ? cm.list.length + ' 条' : cm.error));
                const sim = await call(srv.port, { action: 'simiSongs', id: sid });
                console.log('  ' + (sim.ok && sim.list.length ? '[OK]  ' : '[WARN]') + ' simiSongs         ' + (sim.ok ? sim.list.length + ' 首' : sim.error));
                const aid = (d.list[0].artistIds || [])[0];
                if (aid) {
                    const ad = await call(srv.port, { action: 'artistSongs', id: aid });
                    console.log('  ' + (ad.ok && ad.list.length ? '[OK]  ' : '[WARN]') + ' artistSongs       ' + (ad.ok ? ad.list.length + ' 首' : ad.error));
                }
            }
        }
    } catch (e) {
        console.log('  [ERR]  二级链路 ' + e.message);
    }

    try { srv.child.kill(); } catch (_) {}
    // 清理失败（Windows 上 junction 常被占用）不该影响测试结论
    try { fs.rmSync(tmp, { recursive: true, force: true }); } catch (_) {}
    console.log('\n  结果: ' + pass + ' 通过 / ' + fail + ' 失败');
    process.exitCode = fail > 0 ? 1 : 0;
    setTimeout(() => process.exit(fail > 0 ? 1 : 0), 150);
})();
