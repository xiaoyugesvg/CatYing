/**
 * 实测「阅读3.0 漫画源」在书源引擎里能否出图。
 *
 * ── 为什么单独立一个探针 ──────────────────────────────────────
 * 漫画源（bookSourceType=2）与小说源走的是**同一条链路**，
 * 但正文的返回形态不同：
 *   小说 → { ok, type:'text',   content:'…' }
 *   漫画 → { ok, type:'images', images:[…] }   ← 关键差别
 *
 * Dart 侧原来只读 `content`，把 `images` 丢了 → 漫画一片空白。
 * 这个探针就是盯住"漫画到底有没有拿到图片 URL"。
 *
 * 用法：node _test_manga_source.cjs
 */
const path = require('path');
const fs = require('fs');
const os = require('os');
const { spawn } = require('child_process');

const SRC = path.join(__dirname, 'dist', 'main.js');
const NM = path.join(__dirname, 'node_modules');

// 包子漫画（阅读3.0 漫画源，bookSourceType=2）
const BAOZI = {
    bookSourceGroup: '漫画书源 🎨',
    bookSourceName: '🎨包子漫画',
    bookSourceType: 2,
    bookSourceUrl: 'https://cn.bzmanga.com',
    enabled: true,
    enabledCookieJar: false,
    enabledExplore: true,
    header: '@js:\nJSON.stringify({"Accept-Language": "zh-CN,zh;q=0.9"})',
    ruleBookInfo: {
        author: 'class.comics-detail__author@text',
        coverUrl: 'tag.amp-img.0@src',
        init: '<js>java.t2s(result)</js>',
        intro: 'class.comics-detail__desc overflow-hidden@text',
        kind: 'class.tag-list@text',
        lastChapter: 'class.comics-chapters__item.0@text',
        name: 'class.comics-detail__title@text',
        // ⚠️ 这是**源原文**（错拼 harf + 断掉的取值链）。
        // 它取到的是「直接看第 1 话」的链接，**不是目录页**。
        tocUrl:
            'class.pure-u-1-1 pure-u-sm-1-2 pure-u-md-1-3 pure-u-lg-1-4 comics-chapters@tag.a@harf@class.comics-chapters__item@text',
    },
    ruleContent: {
        content:
            "@js:\nlet n = java.getElements('class.comic-contain@amp-img');\n" +
            "let c=[];\n" +
            "Array.from(n).forEach(x=>{ c.push({link:x.attr('data-src')}) });\n" +
            "var imgTags = c.map(item => `<img src=\"${item.link}\">`).join('\\n');\n" +
            'imgTags;',
        imageStyle: 'FULL',
    },
    ruleExplore: {
        author: '$.author',
        bookList: '$.items[*]',
        bookUrl: 'https://cn.bzmanga.com/comic/{{$.comic_id}}',
        coverUrl: 'https://static-tw.baozimh.com/cover/{{$.topic_img}}',
        kind: '$.type_names',
        name: '$.name',
    },
    ruleSearch: {
        author: 'class.tags text-truncate@text',
        bookList: 'class.comics-card pure-u-1-2 pure-u-sm-1-2 pure-u-md-1-4 pure-u-lg-1-6',
        bookUrl: 'class.comics-card pure-u-1-2 pure-u-sm-1-2 pure-u-md-1-4 pure-u-lg-1-6@tag.a@href',
        coverUrl: 'tag.amp-img.0@src',
        name: 'class.comics-card__title text-truncate@text',
    },
    ruleToc: {
        chapterList:
            'class.pure-u-1-1 pure-u-sm-1-2 pure-u-md-1-3 pure-u-lg-1-4 comics-chapters@tag.a',
        chapterName: 'tag.span@text',
        chapterUrl: 'href',
    },
    searchUrl: 'https://cn.bzmanga.com/search?q={{key}}',
};

function startEngine() {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'mg-'));
    fs.copyFileSync(SRC, path.join(tmp, 'main.cjs'));
    try { fs.symlinkSync(NM, path.join(tmp, 'node_modules'), 'junction'); }
    catch (_) { fs.cpSync(NM, path.join(tmp, 'node_modules'), { recursive: true }); }

    return new Promise((res, rej) => {
        const child = spawn(process.execPath, [path.join(tmp, 'main.cjs')],
            { stdio: ['ignore', 'pipe', 'pipe'] });
        let out = '', done = false;
        const to = setTimeout(() => rej(new Error('启动超时\n' + out.slice(-400))), 30000);
        const on = (b) => {
            out += b.toString();
            const m = out.match(/(?:mgmt)?[Ss]erver listening on port (\d+)/);
            if (m && !done) {
                done = true; clearTimeout(to);
                setTimeout(() => res({ child, port: +m[1] }), 400);
            }
        };
        child.stdout.on('data', on); child.stderr.on('data', on);
        child.on('exit', (c) => { if (!done) { done = true; clearTimeout(to); rej(new Error('退出 ' + c)); } });
    });
}

(async () => {
    const app = await startEngine();
    const call = async (body) => {
        try {
            const r = await fetch(`http://127.0.0.1:${app.port}/book/source`, {
                method: 'POST', headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body), signal: AbortSignal.timeout(40000),
            });
            return await r.json();
        } catch (e) { return { ok: false, error: 'fetch: ' + e.message }; }
    };
    const L = (s) => console.log('  ' + s);

    console.log('');
    L('═'.repeat(66));
    L('  阅读3.0 漫画源实测（bookSourceType=2）');
    L('═'.repeat(66));

    // 1) 搜索
    const s = await call({ action: 'bsSearch', source: BAOZI, keyword: '恋爱', page: 1 });
    const list = (s && s.list) || [];
    L(`[1/4] 搜索        ${s.ok !== false ? '✓' : '✗'}  ${list.length} 条`);
    if (s.error) L(`      错误：${String(s.error).slice(0, 140)}`);
    if (!list.length) { L('  ✗ 搜索无结果，后续跳过'); app.child.kill(); process.exit(1); }
    L(`      首条：${list[0].name} / ${list[0].author || '-'}`);

    // 2) 详情
    const bi = await call({ action: 'bsBookInfo', source: BAOZI, bookUrl: list[0].bookUrl });
    const info = (bi && bi.info) || {};
    L(`[2/4] 详情        ${bi.ok !== false ? '✓' : '✗'}`);
    L(`      书名=${info.name || '-'}  作者=${info.author || '-'}`);
    L(`      tocUrl=${String(info.tocUrl || '-').slice(0, 90)}`);

    // 3) 目录
    const tc = await call({ action: 'bsToc', source: BAOZI, tocUrl: info.tocUrl || list[0].bookUrl });
    const chs = (tc && tc.list) || [];
    L(`[3/4] 目录        ${tc.ok !== false ? '✓' : '✗'}  ${chs.length} 章`);
    if (tc.warning) L(`      警告：${tc.warning}`);
    if (tc.error) L(`      错误：${String(tc.error).slice(0, 140)}`);
    if (chs[0]) L(`      首章：${chs[0].name}  →  ${String(chs[0].url).slice(0, 80)}`);

    // 4) 正文 —— **这里才是漫画的关键**
    if (chs.length) {
        const ct = await call({ action: 'bsContent', source: BAOZI, chapterUrl: chs[0].url });
        const n = (ct && ct.images && ct.images.length) || 0;
        L(`[4/4] 正文        ${ct.ok !== false ? '✓' : '✗'}  type=${ct.type}  图片 ${n} 张`);
        if (ct.error) L(`      错误：${String(ct.error).slice(0, 160)}`);
        if (n > 0) {
            L(`      首图：${String(ct.images[0]).slice(0, 100)}`);
            if (ct.images[1]) L(`      次图：${String(ct.images[1]).slice(0, 100)}`);
            // 真下第一张，确认图床可达（防盗链能不能过）
            try {
                const r = await fetch(ct.images[0], {
                    headers: { Referer: BAOZI.bookSourceUrl, 'User-Agent': 'Mozilla/5.0' },
                    signal: AbortSignal.timeout(25000),
                });
                const buf = Buffer.from(await r.arrayBuffer());
                L(`      实下首图：HTTP ${r.status}  ${(buf.length / 1024).toFixed(1)} KB  ${r.headers.get('content-type')}`);
            } catch (e) {
                L(`      实下首图 ✗ ${e.message}`);
            }
        }
    } else {
        L('[4/4] 正文        跳过（没有章节）');
    }

    console.log('');
    try { app.child.kill(); } catch (_) {}
    process.exit(0);
})();
