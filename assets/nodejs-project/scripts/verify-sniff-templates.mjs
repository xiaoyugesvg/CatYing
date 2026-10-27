// 嗅探注入脚本回归验证（**完全离线**，不需要真机/外网）
//
// 为什么留这个脚本：
//   `sniff_player_page.dart` 里的两个 JS 模板是**裸字符串**，`dart analyze`
//   完全看不见它们 —— 一旦写错一个括号，编译照样通过，而嗅探会在真机上
//   静默失效（页面能打开、就是永远抓不到地址），排查成本极高。
//   这个脚本把模板抽出来做两件事：
//     ① `vm.Script` 语法检查（语法错立刻暴露）；
//     ② 用一个**假 DOM** 跑一遍，断言分桶优先级 / 上报前缀 / Resource Timing
//        补全这些行为真的生效。
//
// 跑法：
//     cd assets/nodejs-project
//     node scripts/verify-sniff-templates.mjs
//
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const dartFile = path.resolve(
    here,
    '../../../lib/pages/play/sniff_player_page.dart',
);
const src = fs.readFileSync(dartFile, 'utf8');

/** 从 Dart 源码里抠出 `static const String NAME = r'''…''';` */
function extractTemplate(name) {
    const re = new RegExp(
        name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + "\\s*=\\s*r'''([\\s\\S]*?)''';",
    );
    const m = re.exec(src);
    if (!m) throw new Error(`在 ${dartFile} 里找不到 ${name}`);
    return m[1];
}

// 用出厂后缀清单（m3u8/mp4/flv）跑，等价于用户没自定义时的情形
const EXTS = 'm3u8|mp4|flv';
const hookJs = extractTemplate('_hookTemplate').replaceAll('@EXT@', EXTS);
const sniffJs = extractTemplate('_sniffTemplate').replaceAll('@EXT@', EXTS);

const checks = [];
const check = (name, ok) => checks.push([name, ok]);

// ── ① 语法检查 ────────────────────────────────────────────────
for (const [name, code] of [['hook 脚本', hookJs], ['轮询脚本', sniffJs]]) {
    try {
        new vm.Script(code);
        check(`${name}语法合法`, true);
    } catch (e) {
        check(`${name}语法合法（${e.message}）`, false);
    }
}

// ── ② 假 DOM 行为验证 ─────────────────────────────────────────
const posted = [];
class Element {
    constructor(tag) { this.tagName = tag; this._a = {}; }
    setAttribute(n, v) { this._a[n] = v; }
    getAttribute(n) {
        return Object.prototype.hasOwnProperty.call(this._a, n) ? this._a[n] : null;
    }
}
class HTMLMediaElement extends Element {}
Object.defineProperty(HTMLMediaElement.prototype, 'src', {
    configurable: true,
    get() { return this._s; },
    set(v) { this._s = v; },
});
class XHR { open(_m, u) { this.u = u; } }

const iframes = [];
// 40 个 `.html` 广告 iframe —— 应被 NOT_MEDIA 直接滤掉
for (let i = 0; i < 40; i++) {
    const f = new Element('IFRAME');
    f.setAttribute('src', `https://ad${i}.example/player.html`);
    iframes.push(f);
}
// 40 个**无后缀**垃圾 iframe —— 应被 MAX_OTHER 限到 12 条
for (let i = 0; i < 40; i++) {
    const f = new Element('IFRAME');
    f.setAttribute('src', `https://junk${i}.example/p`);
    iframes.push(f);
}
// 真地址藏在第 35 个 iframe 的 data-src 里（老实现会被挤出前 30 名而丢掉）
iframes[35].setAttribute('data-src', 'https://cdn.example/real/index.m3u8');

const resources = [
    { name: 'https://cdn.example/stream/abc' }, // 无后缀：只有 Resource Timing 看得见
    { name: 'https://site.example/app.js' },    // 明显不是媒体
    { name: 'https://cdn.example/v.mp4' },
];

const ctx = {
    console,
    setInterval: () => 0, // 别真跑定时器
    clearInterval: () => {},
    performance: { getEntriesByType: (t) => (t === 'resource' ? resources : []) },
    document: {
        querySelectorAll: (sel) => (sel === 'iframe' ? iframes : []),
        documentElement: { outerHTML: '<html><body>no media here</body></html>' },
    },
    Element,
    HTMLMediaElement,
    XMLHttpRequest: XHR,
    fetch: () => {},
    SniffMedia: { postMessage: (m) => posted.push(m) },
};
ctx.window = ctx;
vm.createContext(ctx);

vm.runInContext(hookJs, ctx);
// hook 的三条上报路径
new ctx.XMLHttpRequest().open('GET', 'https://a.example/play?id=1'); // 无后缀 → u:
new ctx.XMLHttpRequest().open('GET', 'https://a.example/x.m3u8');    // 有后缀 → 无前缀
new ctx.XMLHttpRequest().open('GET', 'https://a.example/app.js');    // 非媒体 → 丢
const media = new HTMLMediaElement('VIDEO');
media.src = 'https://a.example/stream/xyz';                         // 元素 → t:
new Element('IMG').setAttribute('src', 'https://a.example/pic.png'); // 非媒体 → 丢

vm.runInContext(sniffJs, ctx);
const all = vm.runInContext('window.__sniff.all()', ctx);

check('XHR 无后缀上报带 u: 前缀', posted.includes('u:https://a.example/play?id=1'));
check('XHR 带后缀不加前缀', posted.includes('https://a.example/x.m3u8'));
check('XHR 非媒体(.js) 不上报', !posted.some((m) => m.includes('app.js')));
check('媒体元素 src 上报带 t: 前缀', posted.includes('t:https://a.example/stream/xyz'));
check('非媒体元素(.png) 不上报', !posted.some((m) => m.includes('pic.png')));

check('iframe 里的真地址没被挤出', all.includes('https://cdn.example/real/index.m3u8'));
check('媒体地址排在最前面', all[0] === 'https://cdn.example/real/index.m3u8');
check('带 .html 的 iframe 被完全滤掉', all.filter((u) => /\.html$/.test(u)).length === 0);
check(
    '无后缀垃圾 iframe 被限到 12 条',
    all.filter((u) => /junk\d+\.example/.test(u)).length === 12,
);
check('Resource Timing 补到无后缀流', all.includes('https://cdn.example/stream/abc'));
check('Resource Timing 的 .js 被滤掉', !all.some((u) => u.endsWith('app.js')));
check('Resource Timing 的 .mp4 进媒体桶', all.includes('https://cdn.example/v.mp4'));

// ── 汇总 ─────────────────────────────────────────────────────
let bad = 0;
for (const [name, ok] of checks) {
    console.log(`${ok ? '✅' : '❌'} ${name}`);
    if (!ok) bad++;
}
if (bad > 0) {
    console.log('\nposted =', JSON.stringify(posted, null, 1));
    console.log('all    =', JSON.stringify(all, null, 1));
}
console.log(bad === 0 ? '\n全部通过 ✅' : `\n${bad} 项失败 ❌`);
process.exit(bad === 0 ? 0 : 1);
