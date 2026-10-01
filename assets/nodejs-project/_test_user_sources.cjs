/**
 * 实测用户给的两个真实书源能否跑通。
 *
 * ── 为什么要实测而不是"看代码判断" ────────────────────────────
 * 书源是**外部站点的抓取规则**，能不能用取决于两件事：
 *   ① 引擎支不支持该规则用到的语法（这个可以看代码）
 *   ② **站点今天是否可达、结构是否变了**（这个只能真抓）
 * ②永远猜不出来 —— 所以直接打真网站。
 *
 * 两个源：
 *   A. 若雨中文   bookSourceType=0（小说）→ 走 bsSearch/bsBookInfo/bsToc/bsContent
 *   B. 包子漫画   bookSourceType=2（漫画）→ 正文应返回 {type:'images', images:[...]}
 *
 * 用法：node _test_user_sources.cjs
 */
const path = require('path');
const { spawn } = require('child_process');

const SRC = path.join(__dirname, 'dist', 'main.js');

// ── A. 若雨中文（小说）──────────────────────────────────────────
const RUOYU = {
    bookSourceComment: '作者：纳兰',
    bookSourceName: '若雨中文',
    bookSourceType: 0,
    bookSourceUrl: 'http://www.3yt.info',
    enabled: true,
    enabledCookieJar: true,
    enabledExplore: true,
    exploreUrl: '[{"title":"网络小说","url":"/Book/LN/1079/{{page}}.html","style":{"layout_flexBasisPercent":0.25,"layout_flexGrow":1}}]',
    header: '{"User-Agent":"Mozilla/5.0 (Linux; Android 12; SM-G991B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/110.0.0.0 Mobile Safari/537.36"}',
    ruleBookInfo: {
        author: 'div.block_txt2 p.1@text##作者：',
        coverUrl: 'div.block_img2 img@src',
        intro: 'div.intro_info@text',
        kind: 'div.block_txt2 p.2 a@text',
        lastChapter: 'div.block_txt2 p.5 a@text',
        name: '#bqgmb_h1@text',
    },
    ruleContent: {
        content: '#nr1@html##<div id="content_tip">[\\s\\S]*?<\\/div>|最新网址：m\\.3yt\\.info|第\\d+章[^<]*\\(第\\d+\\/\\d+页\\)',
        nextContentUrl: 'text.下一页@href',
    },
    ruleExplore: {
        author: '.block_txt p.0@text##作者：',
        bookList: '.block',
        bookUrl: '.block_img a@href',
        coverUrl: '.block_img img@src',
        intro: '.block_txt p.1@text',
        name: '.block_txt h2@text',
    },
    ruleSearch: {
        author: 'td.4@text',
        bookList: 'table.table_01 tbody tr',
        bookUrl: "@js:var href = result.select('td').get(1).select('a').attr('href'); href;",
        kind: 'td.0@text',
        lastChapter: 'td.2@text',
        name: 'td.1@text',
    },
    ruleToc: {
        chapterList: 'ul.chapter.1@li@a',
        chapterName: 'text',
        chapterUrl: 'href',
        nextTocUrl: 'select[name=pageselect] option@value',
    },
    searchUrl: '/book/search.aspx?searchkey={{key}}&SeaButton=',
};

// ── B. 包子漫画（漫画）─────────────────────────────────────────
const BAOZI = {
    bookSourceGroup: '漫画书源 🎨',
    bookSourceName: '🎨包子漫画',
    bookSourceType: 2,
    bookSourceUrl: 'https://cn.bzmanga.com',
    enabled: true,
    enabledCookieJar: false,
    enabledExplore: true,
    exploreUrl: '<js>\nvar sort = [];\nsort.push({title:"全部",url:"https://cn.bzmanga.com/api/bzmhq/amp_comic_list?type=all&region=all&filter=&page={{page}}&limit=36&language=cn",style:{layout_flexGrow:1,layout_flexBasisPercent:0.25}});\nJSON.stringify(sort)\n</js>',
    header: '@js:\nJSON.stringify({"Accept-Language": "zh-CN,zh;q=0.9"})',
    ruleBookInfo: {
        author: 'class.comics-detail__author@text',
        coverUrl: 'tag.amp-img.0@src',
        init: '<js>java.t2s(result)</js>',
        intro: 'class.comics-detail__desc overflow-hidden@text',
        kind: 'class.tag-list@text',
        lastChapter: 'class.comics-chapters__item.0@text',
        name: 'class.comics-detail__title@text',
        tocUrl: 'class.pure-u-1-1 pure-u-sm-1-2 pure-u-md-1-3 pure-u-lg-1-4 comics-chapters@tag.a@harf@class.comics-chapters__item@text',
    },
    ruleContent: {
        content: "@js:\nlet n = java.getElements('class.comic-contain@amp-img');\nlet c=[];\nArray.from(n).forEach(x=>{ c.push({link:x.attr('data-src')}) });\nvar imgTags = c.map(item => `<img src=\"${item.link}\">`).join('\\n');\nimgTags;",
        imageStyle: 'FULL',
        title: 'class.title',
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
        kind: 'class.tabs cls@text',
        lastChapter: 'class.comics-chapters__item.0@text',
        name: 'class.comics-card__title text-truncate@text',
    },
    ruleToc: {
        chapterList: '<js>java.t2s(result)</js>\nclass.pure-u-1-1 pure-u-sm-1-2 pure-u-md-1-3 pure-u-lg-1-4 comics-chapters',
        chapterName: 'tag.span@text',
        chapterUrl: 'tag.a@href',
    },
    searchUrl: 'https://cn.bzmanga.com/search?q={{key}}',
};

function startEngine() {
    // ⚠️ 引擎端口是**随机分配**的（main.js 里 listen(0)），
    // 必须从 stdout 的 "listening on port N" 解析 —— 我第一版写死了
    // 18923，结果 fetch 一直 failed，白排查一轮。
    // 起法照抄项目里已有的 _test_book.cjs：先把 dist/main.js 复制成
    // .cjs 到临时目录再起（因为 package.json 是 type:module）。
    const fs = require('fs');
    const os = require('os');
    const NM = path.join(__dirname, 'node_modules');
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'usrc-'));
    fs.copyFileSync(SRC, path.join(tmp, 'main.cjs'));
    try { fs.symlinkSync(NM, path.join(tmp, 'node_modules'), 'junction'); }
    catch (_) { fs.cpSync(NM, path.join(tmp, 'node_modules'), { recursive: true }); }

    return new Promise((res, rej) => {
        const child = spawn(process.execPath, [path.join(tmp, 'main.cjs')],
            { stdio: ['ignore', 'pipe', 'pipe'] });
        let out = '', done = false;
        const to = setTimeout(() => rej(new Error('启动超时\n' + out.slice(-500))), 30000);
        const on = (b) => {
            out += b.toString();
            const m = out.match(/(?:mgmt)?[Ss]erver listening on port (\d+)/);
            if (m && !done) {
                done = true; clearTimeout(to);
                setTimeout(() => res({ p: child, port: +m[1] }), 400);
            }
        };
        child.stdout.on('data', on);
        child.stderr.on('data', on);
        child.on('exit', (c) => { if (!done) { done = true; clearTimeout(to); rej(new Error('退出 ' + c + '\n' + out.slice(-500))); } });
    });
}

(async () => {
    const { p, port } = await startEngine();
    const call = async (body) => {
        try {
            const r = await fetch(`http://127.0.0.1:${port}/book/source`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(body),
                signal: AbortSignal.timeout(25000),
            });
            return await r.json();
        } catch (e) {
            return { ok: false, error: 'fetch: ' + e.message };
        }
    };

    const line = (s) => console.log(s);

    async function testSource(tag, source, keyword) {
        line('');
        line('═'.repeat(70));
        line(`  ${tag}   type=${source.bookSourceType}   ${source.bookSourceUrl}`);
        line('═'.repeat(70));

        // 1) 搜索
        const s = await call({ action: 'bsSearch', source, keyword, page: 1 });
        const sl = s && Array.isArray(s.list) ? s.list : [];
        line(`  [搜索 "${keyword}"]  ${s && s.ok !== false ? '✓' : '✗'}  结果 ${sl.length} 条`);
        if (s && s.error) line(`      错误: ${String(s.error).slice(0, 160)}`);
        if (sl[0]) {
            line(`      首条: ${sl[0].name} / ${sl[0].author || '-'}`);
            line(`      bookUrl: ${String(sl[0].bookUrl || '').slice(0, 100)}`);
        }
        if (!sl.length) return;

        // 2) 详情
        const bi = await call({ action: 'bsBookInfo', source, bookUrl: sl[0].bookUrl });
        line(`  [详情]  ${bi && bi.ok !== false ? '✓' : '✗'}`);
        if (bi && bi.error) line(`      错误: ${String(bi.error).slice(0, 160)}`);
        // ⚠️ bookInfo 返回的是 { ok, info: {...} } —— 我第一版读成
        // bi.name 了，于是"详情全空"，白排查了好几轮。
        const info = (bi && bi.info) || {};
        const tocUrl = info.tocUrl || sl[0].bookUrl;
        if (bi) {
            line(`      书名=${info.name || '-'} 作者=${info.author || '-'}`);
            line(`      分类=${info.kind || '-'} 简介=${String(info.intro || '-').slice(0, 40)}`);
            line(`      封面=${String(info.coverUrl || '-').slice(0, 90)}`);
        }

        // 3) 目录
        const tc = await call({ action: 'bsToc', source, tocUrl });
        const ch = tc && Array.isArray(tc.list) ? tc.list : [];
        line(`  [目录]  ${tc && tc.ok !== false ? '✓' : '✗'}  ${ch.length} 章`);
        if (tc && tc.error) line(`      错误: ${String(tc.error).slice(0, 160)}`);
        if (ch[0]) line(`      首章: ${ch[0].name}`);
        if (!ch.length) return;

        // 4) 正文
        const ct = await call({ action: 'bsContent', source, chapterUrl: ch[0].url });
        line(`  [正文]  ${ct && ct.ok !== false ? '✓' : '✗'}  type=${ct && ct.type}`);
        if (ct && ct.error) line(`      错误: ${String(ct.error).slice(0, 160)}`);
        if (ct && ct.type === 'images') {
            const n = (ct.images || []).length;
            line(`      图片 ${n} 张`);
            if (ct.images && ct.images[0]) line(`      首图: ${String(ct.images[0]).slice(0, 100)}`);
        } else if (ct) {
            const c = String(ct.content || '');
            line(`      正文 ${c.length} 字符`);
            if (c) line(`      开头: ${c.slice(0, 120).replace(/\n/g, ' ')}`);
        }
    }

    // 若雨中文：搜一个不可能没结果的常见词
    await testSource('A. 若雨中文（小说）', RUOYU, '剑');
    // 包子漫画
    await testSource('B. 包子漫画（漫画）', BAOZI, '恋爱');

    line('');
    line('═'.repeat(70));
    line('  完');
    try { p.kill(); } catch (_) {}
    process.exit(0);
})();
