/**
 * 小说书源引擎端到端测试。
 *
 * ── 为什么必须测 ──────────────────────────────────────────────
 * 书源引擎要按 Legado 规则去抓任意小说站：CSS 选择器、@text/@html 取值、
 * {{ }} 变量语法、分页。**光能编译不算数**，得真抓下来东西。
 *
 * 所以这里本地起一个 mock 小说站（固定的 HTML 结构），
 * 用一份标准 Legado 书源指向它，验证四个动作：
 *   bsSearch → 搜索结果
 *   bsBookInfo → 书籍详情
 *   bsToc → 目录
 *   bsContent → 正文
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const { spawn } = require('child_process');

const SRC = path.join(__dirname, 'dist', 'main.js');
const NM = path.join(__dirname, 'node_modules');

// ---------- mock 小说站 ----------
// 结构仿常见小说站：搜索页返回 li 列表，详情页有目录，章节页有正文
function startMockSite() {
    return new Promise((res) => {
        const srv = http.createServer((req, rep) => {
            const u = new URL(req.url, 'http://x');
            const html = (s) => { rep.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' }); rep.end(s); };

            if (u.pathname === '/search') {
                const kw = u.searchParams.get('q') || '';
                html(`<html><body><ul class="book-list">
                  <li><a class="name" href="/book/1">${kw} 测试小说</a>
                      <span class="author">测试作者</span></li>
                </ul></body></html>`);
            } else if (u.pathname === '/book/1') {
                html(`<html><body>
                  <h1 class="book-name">测试小说</h1>
                  <div class="author">测试作者</div>
                  <div class="intro">这是一本用于测试的小说。</div>
                  <div class="cover"><img src="/img/cover.jpg"></div>
                  <ul class="chapter-list">
                    <li><a href="/chapter/1">第一章 开始</a></li>
                    <li><a href="/chapter/2">第二章 继续</a></li>
                  </ul>
                </body></html>`);
            } else if (u.pathname === '/user/login') {
                // 登录接口：校验字段后下发 Set-Cookie
                let body = '';
                req.on('data', (c) => { body += c; });
                req.on('end', () => {
                    if (/user=ok/.test(body)) {
                        rep.writeHead(200, {
                            'Content-Type': 'text/html; charset=utf-8',
                            'Set-Cookie': 'PHPSESSID=sess123; Path=/; HttpOnly',
                        });
                        rep.end('<html>登录成功</html>');
                    } else {
                        // 字段不对：不给 Cookie（测试要能区分这两种结果）
                        rep.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
                        rep.end('<html>账号或密码错误</html>');
                    }
                });
            } else if (u.pathname.startsWith('/chapter/')) {
                const n = u.pathname.split('/').pop();
                html(`<html><body>
                  <div id="content">这是第 ${n} 章的正文内容。<br>第二行。<br>第三行。</div>
                </body></html>`);
            } else {
                rep.writeHead(404); rep.end('nope');
            }
        });
        srv.listen(0, '127.0.0.1', () => res({ srv, port: srv.address().port }));
    });
}

function startApp() {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'bstest-'));
    fs.copyFileSync(SRC, path.join(tmp, 'main.cjs'));
    try { fs.symlinkSync(NM, path.join(tmp, 'node_modules'), 'junction'); }
    catch (_) { fs.cpSync(NM, path.join(tmp, 'node_modules'), { recursive: true }); }
    return new Promise((res, rej) => {
        const child = spawn(process.execPath, [path.join(tmp, 'main.cjs')], { stdio: ['ignore','pipe','pipe'] });
        let out = '', done = false;
        const to = setTimeout(() => rej(new Error('启动超时\n' + out.slice(-400))), 30000);
        const on = (b) => {
            out += b.toString();
            const m = out.match(/(?:mgmt)?[Ss]erver listening on port (\d+)/);
            if (m && !done) { done = true; clearTimeout(to); setTimeout(() => res({ child, port: +m[1], tmp }), 400); }
        };
        child.stdout.on('data', on); child.stderr.on('data', on);
        child.on('exit', (c) => { if (!done) { done = true; clearTimeout(to); rej(new Error('退出 ' + c)); } });
    });
}

(async () => {
    const site = await startMockSite();
    const app = await startApp();
    const M = `http://127.0.0.1:${site.port}`;

    const call = async (body) => (await fetch(`http://127.0.0.1:${app.port}/book/source`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
    })).json();

    // 一份标准 Legado 书源，指向 mock 站
    const source = {
        bookSourceName: '测试书源',
        bookSourceUrl: M,
        bookSourceGroup: '测试',
        enabled: true,
        // Legado 标准的顶层字段：搜索 URL 模板（{{key}} 会被替换成关键词）
        searchUrl: M + '/search?q={{key}}',
        ruleSearch: {
            bookList: '.book-list li',
            name: '.name@text',
            author: '.author@text',
            bookUrl: '.name@href',
        },
        ruleBookInfo: {
            name: '.book-name@text',
            author: '.author@text',
            intro: '.intro@text',
            coverUrl: '.cover img@src',
        },
        ruleToc: {
            chapterList: '.chapter-list li',
            chapterName: 'a@text',
            chapterUrl: 'a@href',
        },
        ruleContent: {
            content: '#content@html',
        },
    };

    const cases = [
        {
            name: 'bsSearch 搜索返回结果',
            body: { action: 'bsSearch', source, keyword: '测试', page: 1 },
            check: (r) => r && r.ok !== false && Array.isArray(r.list) && r.list.length > 0,
            diag: (r) => (r.list && r.list[0] ? (r.list[0].name + ' / ' + r.list[0].author) : (r.error || '空')),
        },
        {
            name: 'bsBookInfo 详情',
            body: { action: 'bsBookInfo', source, bookUrl: M + '/book/1' },
            // 注意返回结构是 { ok, info:{ name, author, ... } }
            check: (r) => r && r.ok !== false && r.info && (r.info.name || '').includes('测试小说'),
            diag: (r) => (r.info && r.info.name) || r.error || '空',
        },
        {
            name: 'bsToc 目录',
            body: { action: 'bsToc', source, tocUrl: M + '/book/1' },
            check: (r) => r && r.ok !== false && Array.isArray(r.list) && r.list.length >= 2,
            diag: (r) => (r.list ? r.list.length + ' 章：' + (r.list[0] ? r.list[0].name : '') : (r.error || '空')),
        },
        {
            name: 'bsContent 正文',
            body: { action: 'bsContent', source, chapterUrl: M + '/chapter/1' },
            check: (r) => {
                const c = typeof r === 'string' ? r : (r && (r.content || r.text)) || '';
                return c.includes('第 1 章') || c.includes('正文内容');
            },
            diag: (r) => {
                const c = typeof r === 'string' ? r : (r && (r.content || r.text)) || '';
                return c.slice(0, 40).replace(/\n/g, ' ');
            },
        },
        {
            name: 'bsLogin 表单登录拿到 Cookie',
            body: {
                action: 'bsLogin',
                url: M + '/user/login',
                method: 'POST',
                contentType: 'application/x-www-form-urlencoded',
                body: { user: 'ok', pass: 'pw' },
            },
            check: (r) => r && r.ok === true && /PHPSESSID=sess123/.test(r.cookie || ''),
            diag: (r) => (r.ok ? r.cookie : (r.error || '空')),
        },
        {
            name: 'bsLogin 字段不对时明确说没拿到 Cookie',
            body: {
                action: 'bsLogin',
                url: M + '/user/login',
                method: 'POST',
                contentType: 'application/x-www-form-urlencoded',
                body: { user: 'bad', pass: 'pw' },
            },
            check: (r) => r && r.ok === false && /没有返回 Cookie/.test(r.error || ''),
            diag: (r) => (r.error || '空').slice(0, 60),
        },
        {
            name: '未知 action 明确报错',
            body: { action: 'nope', source },
            check: (r) => r && r.ok === false && /未知 action/.test(r.error || ''),
            diag: (r) => r.error,
        },
    ];

    let pass = 0;
    for (const c of cases) {
        let line;
        try {
            const r = await call(c.body);
            const ok = c.check(r);
            if (ok) pass++;
            line = `  ${ok ? '[OK]  ' : '[FAIL]'}${c.name.padEnd(26)} ${c.diag(r)}`;
        } catch (e) {
            line = `  [ERR] ${c.name.padEnd(26)} ${e.message}`;
        }
        console.log(line);
    }

    console.log(`\n  结果: ${pass}/${cases.length}${pass === cases.length ? '  ✅ 书源引擎可用' : '  ❌ 有失败'}`);

    try { app.child.kill(); } catch (_) {}
    try { site.srv.close(); } catch (_) {}
    try { fs.rmSync(app.tmp, { recursive: true, force: true }); } catch (_) {}
    setTimeout(() => process.exit(pass === cases.length ? 0 : 1), 400);
})().catch((e) => { console.error('  [ERR] ' + e.message); process.exit(1); });
