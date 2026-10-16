/**
 * 「海阔」小程序规则引擎（hiker / hipy 兼容层）—— Phase 1（最小可用）
 *
 * ── 背景 ────────────────────────────────────────────────────────────
 * 海阔视界(hiker)的小程序规则与 TVBox/CatVod **完全不同**：
 *   · 规则是 `"find_rule": "js: ..."`，脚本里用**全局 `$`** 而不是 `this`；
 *   · 结果是脚本调 **`setResult(...)` / `setHomeResult(...)`** 交回宿主；
 *   · 抓网页是**同步**的（`$.get(url)` 直接返回字符串、`getResCode()` 直接给当前页 HTML）；
 *   · `$.require('xxx')` 加载**源自带的内联页面模块**（就是源的 `pages` 数组里
 *     每项 `{name, path, rule}` 的 `rule` 源码）；
 *   · 还有一堆 `hiker://` 伪协议与 DOM 选择器 DSL（`body&&tbody[id]`）。
 *
 * ── 同步 HTTP 怎么解决（关键取舍）────────────────────────────────
 * iOS 上 Node 与 App 同进程，且 NodeMobile **没有** worker_threads
 * ⇒ 无法用 `Atomics.wait` 做真正的同步阻塞。
 * 这里用**「重放」桥**：脚本里每个同步网络调用先查缓存，缺失就抛
 * [NeedFetch]；宿主抓住它 → 异步抓这一条 → **用同一份缓存重跑整个脚本**。
 * 因为绝大多数规则的 URL 是由入参（分类/页码/关键词）决定的、与响应无关，
 * 所以「重放」会在「未命中 URL 数 + 1」次内收敛；脚本内自增/随机数会让它不收敛，
 * 这时直接报错（不静默返回空）。
 * ⚠️ 因此本引擎**必须有超时/次数上限**，否则坏规则会一直重放。
 *
 * ── Phase 1 支持范围 ──────────────────────────────────────────────
 *   ✅ `find_rule` / `searchFind` / `detail_find_rule`（`js:` 前缀）
 *   ✅ `$` 基础：`$.get/$.post/$.ajax`、`$.html`（jQuery 风格薄包装）、
 *      `$.md5/$.sha1/$.base64/$.toString/$.toString`、`$.require`
 *   ✅ 老式 API：`getResCode`、`parseDomForArray`、`parseDomForHtml`、`parseDomForHtmlList`
 *   ✅ 结果：`setResult` / `setHomeResult`（数组、`{data:[...]}`、JSON 字符串、
 *      海阔列表 DSL 字符串）
 *   ✅ 变量：`getParam` / `getMyVar` / `setMyVar` / `putMyVar` / `delMyVar`
 *   ✅ `x5://` 前缀剥离、`hiker://empty` 占位
 *   ❌ 未支持（Phase 2/3）：`hiker://page/*` 内置页面模块、`$.aes/$.des/$.rsa`、
 *      `hiker://assets/*`、多级 `pages` 跳转、`setNextPage` 翻页
 */

import * as cheerioNs from 'cheerio';
const cheerio = cheerioNs.default ?? cheerioNs;
import vm from 'node:vm';
import fs from 'node:fs';
import path from 'node:path';
import axios from 'axios';
import iconv from 'iconv-lite';
import CryptoJS from 'crypto-js';
import crypto from 'node:crypto';
import zlib from 'node:zlib';

/** 单次脚本执行的 CPU 上限（死循环保护） */
const SCRIPT_TIMEOUT_MS = 8000;
/** 单条规则最多重放几次（见文件头「重放桥」） */
const MAX_REPLAY = 40;
/** 单次网络请求超时 */
const HTTP_TIMEOUT_MS = 15000;
/** 整条规则的总时间预算（重放桥的兜底闸门，见 runHikerRule） */
const TOTAL_BUDGET_MS = 45000;
/** 单条列表最多返回多少项 */
const MAX_ITEMS = 300;

/**
 * 限制值兜底：不是正数就用 [dft]。
 *
 * ── 为什么需要（用户 2026-10-15「一个都用不了」）────────────────────
 * 实测机型上出现过**模块级常量的绑定丢失**：`MAX_REPLAY` 在运行时是 `undefined`
 * ⇒ 重放循环的守卫 `attempt < maxReplay` 恒为 false ⇒ **循环一次都不跑**
 * ⇒ `pending` 恒空 ⇒ 函数直接落到末尾那句 throw ⇒ **每一条规则都秒失败**，
 *   报错还长这样：「规则重放次数超过上限（undefined 轮，共 0 次请求…）」
 * （本地把产物里那个常量改成 `undefined` 可 1:1 复现这条报错。）
 *
 * ⇒ 所有"限制值"在函数入口都过一遍这里：绑定异常时最坏只是退回出厂默认值，
 *   绝不会把整个引擎打死。
 */
function _limit(v, dft) {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? n : dft;
}

/** 单次读文件上限：规则读到一个大文件（比如 VIDEO/大 SQLite）时不许整块进内存 */
const MAX_READ_BYTES = 8 * 1024 * 1024;

/** 单次 HTTP 响应体上限（对齐 lx_engine 的 MAX_RESPONSE_BYTES）—— 防大响应把 Node 顶爆 */
const MAX_RESPONSE_BYTES = 12 * 1024 * 1024;

/** 同步调用需要网络时的信号（由宿主抓住 → 抓取 → 重放） */
class NeedFetch {
  constructor(url, opts, key) {
    this.url = url;
    this.opts = opts || {};
    this.key = key;
  }
}

/**
 * 需要**真实 WebView** 抓页时的信号（Phase 2）。
 *
 * 海阔的 `fetchCodeByWebView(url, {checkJs})` 会开一个真 WKWebView 打开页面，
 * 等 JS 跑完再把 DOM（或 `checkJs` 的返回值）交回来 —— 很多源**列表/播放地址**
 * 就是靠它（普通 HTTP 抓不到，页面是 JS 渲染的）。
 * Node 里没有 WebView，所以这里抛信号，由**宿主**（Dart 侧）去抓，
 * 我们再拿结果重放（与 [NeedFetch] 同一套机制）。
 */
class NeedWebView {
  constructor(url, opts, key) {
    this.url = url;
    this.opts = opts || {};
    this.key = key;
  }
}

// ============================================================
// 网络
// ============================================================

/**
 * 海阔源的 `ua` 字段是**代号**而不是完整 UA 串（实测 `"ua":"mobile"`）——
 * 直接把 `mobile` 当 User-Agent 发出去会被站点当成爬虫/直接拒（实测 52pojie
 * 只返回 150 字节的安全页）。这里映射成真实 UA。
 */
const UA_MOBILE =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 '
  + '(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
const UA_PC =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
  + '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

function resolveUa(raw) {
  const s = String(raw || '').trim();
  // 没写 ua：海阔本身是手机 App，按移动端算
  if (!s) return UA_MOBILE;
  const low = s.toLowerCase();
  if (low === 'mobile' || low === 'phone' || low === 'ios' || low === 'android') return UA_MOBILE;
  if (low === 'pc' || low === 'desktop' || low === 'computer') return UA_PC;
  return s; // 已是完整 UA 串
}

/** 把任意抛出物渲染成人能看懂的一句话（规则里经常 `throw` 一个对象 → `[object Object]`） */
function describeError(e) {
  if (e == null) return '(空错误)';
  if (typeof e === 'string') return e;
  if (e instanceof Error) return e.message || String(e);
  if (typeof e === 'object') {
    if (typeof e.message === 'string' && e.message) return e.message;
    try {
      const s = JSON.stringify(e);
      return s && s !== '{}' ? s : String(e);
    } catch (_) {
      return String(e);
    }
  }
  return String(e);
}

function cacheKeyOf(url, opts) {
  const o = opts || {};
  return [
    String(url),
    o.method || 'get',
    o.charset || '',
    o.postType || '',
    o.body ? String(o.body) : '',
    JSON.stringify(o.headers || {}),
  ].join('\u0001');
}

/** 一个「运行期」：整条规则的缓存 / cookie / 变量 */
function newRuntime(ctx, kv) {
  return {
    ctx,
    // 文件系统根（由 Dart 侧传入）：`<Documents>/hiker/files` 与 `<Documents>/hiker/builtin`
    filesDir: String((ctx && ctx.filesDir) || ''),
    assetsDir: String((ctx && ctx.assetsDir) || ''),
    kv: kv && typeof kv === 'object' ? { ...kv } : {},
    cache: new Map(),
    cookies: new Map(), // host -> cookie 串
    touchedVars: false,
    lazyIds: new Set(), // 本趟遇到过的 lazyRule id（回报给宿主）
    listeners: {}, // addListener 注册的回调（我们不做事件循环，仅记录）
  };
}

function cookieHeaderFor(rt, url) {
  try {
    const host = new URL(url).host;
    return rt.cookies.get(host) || '';
  } catch (_) {
    return '';
  }
}

function absorbSetCookie(rt, url, headers) {
  try {
    const host = new URL(url).host;
    const raw = headers && (headers['set-cookie'] || headers['Set-Cookie']);
    if (!raw) return;
    const list = Array.isArray(raw) ? raw : [raw];
    const jar = new Map();
    for (const one of list) {
      const first = String(one).split(';')[0];
      const i = first.indexOf('=');
      if (i > 0) jar.set(first.slice(0, i).trim(), first.slice(i + 1).trim());
    }
    if (jar.size) {
      const merged = new Map();
      const old = (rt.cookies.get(host) || '').split(';');
      for (const kv of old) {
        const t = kv.trim();
        const i = t.indexOf('=');
        if (i > 0) merged.set(t.slice(0, i), t.slice(i + 1));
      }
      for (const [k, v] of jar) merged.set(k, v);
      rt.cookies.set(host,
        [...merged.entries()].map(([k, v]) => `${k}=${v}`).join('; '));
    }
  } catch (_) { /* cookie 解析失败不影响主流程 */ }
}

/** 真正发出请求（异步）—— 只在重放循环里被调用 */
async function doHttp(rt, url, opts) {
  const o = opts || {};
  const method = String(o.method || 'get').toLowerCase();
  const headers = { ...(o.headers || {}) };
  const ua = o.ua || rt.ctx.ua;
  if (ua && !headers['User-Agent']) headers['User-Agent'] = ua;
  const ck = cookieHeaderFor(rt, url);
  if (ck && !headers['Cookie']) headers['Cookie'] = ck;

  const req = axios.request({
    url,
    method,
    headers,
    data: o.body != null ? o.body : undefined,
    timeout: HTTP_TIMEOUT_MS,
    maxRedirects: 5,
    responseType: 'arraybuffer',
    // 响应体上限：规则抓到超大内容（被当网页的文件/视频）时别整块驻留内存
    maxContentLength: MAX_RESPONSE_BYTES,
    maxBodyLength: MAX_RESPONSE_BYTES,
    validateStatus: () => true,
    // 让 axios 不要自作主张解析；字符集我们按 hiker 的约定自己解
    transformResponse: [(d) => d],
  });
  // ⚠️ **必须再包一层硬超时**：axios 的 `timeout` 只管 socket 建立之后的
  //   静默期，**DNS 解析阶段不受它约束** —— 遇到过域名不合法（如模板里的
  //   `https://{host}/...`）导致整个请求永久挂住，比报错更糟（前端只看到转圈）。
  const resp = await Promise.race([
    req,
    new Promise((_, rej) => {
      setTimeout(() => rej(new Error(`请求超时（${HTTP_TIMEOUT_MS}ms）：${String(url).slice(0, 80)}`)),
        HTTP_TIMEOUT_MS + 2000);
    }),
  ]);
  absorbSetCookie(rt, url, resp.headers);
  const buf = Buffer.from(resp.data);
  const charset = String(o.charset || '').trim() || sniffCharset(resp.headers, buf) || 'utf-8';
  return decodeBuffer(buf, charset);
}

function sniffCharset(headers, buf) {
  try {
    const ct = (headers && (headers['content-type'] || headers['Content-Type'])) || '';
    const m = /charset=([\w-]+)/i.exec(String(ct));
    if (m) return m[1];
  } catch (_) {}
  // 从 HTML 头部 meta 里猜（GBK 站点常见）
  const head = buf.slice(0, 2048).toString('latin1');
  const m2 = /charset=["']?([\w-]+)/i.exec(head);
  return m2 ? m2[1] : '';
}

function decodeBuffer(buf, charset) {
  const cs = String(charset || 'utf-8').toLowerCase();
  if (cs === 'utf-8' || cs === 'utf8') return buf.toString('utf8');
  try {
    return iconv.decode(buf, cs);
  } catch (_) {
    return buf.toString('utf8');
  }
}

/** 读文本文件（失败/过大返回 null，不抛） */
function readText(file) {
  try {
    const st = fs.statSync(file);
    if (st.isDirectory()) return null;
    // 过大的文件按"读不到"处理：宁可不给，也别把 Node 内存顶爆
    if (st.size > MAX_READ_BYTES) {
      warnOnce(`文件过大被拒绝读取（${(st.size / 1048576).toFixed(1)}MB）：${file}`);
      return null;
    }
    return fs.readFileSync(file, 'utf8');
  } catch (_) {
    return null;
  }
}

/** 显式读文件（`readFile` API）：能区分「没有 / 是目录 / 过大 / 读失败」，给明确原因 */
function readTextChecked(file) {
  let st;
  try {
    st = fs.statSync(file);
  } catch (_) {
    return null;
  }
  if (st.isDirectory()) throw new Error(`'${file}' 是目录，不是文件`);
  if (st.size > MAX_READ_BYTES) {
    throw new Error(
      `文件过大（${(st.size / 1048576).toFixed(1)}MB > ${MAX_READ_BYTES / 1048576}MB），`
      + `拒绝整块读入：${file}`,
    );
  }
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (e) {
    throw new Error(`读文件失败（${file}）：${describeError(e)}`);
  }
}

/** 打过一次就不再重复打（避免坏规则刷屏日志） */
const _warned = new Set();
function warnOnce(msg) {
  const k = String(msg).slice(0, 120);
  if (_warned.has(k)) return;
  _warned.add(k);
  console.warn('[hiker]', msg);
}

/**
 * 把规则给的路径**收敛到允许的目录内**（只读/只写这两个根，防 `..` 穿越）。
 *
 * 为什么必须做：海阔源是从网上导入的**不可信脚本**，
 * `readFile('../../Library/Preferences/x.plist')`、`writeFile('hiker://files/../../x')`
 * 这类写法能读写到 App 容器（甚至 Documents）之外的任意文件。
 * 允许的根只有 [HikerStore.rootDir] 下的两个目录：
 *   · filesDir  → `hiker://files/*`（规则自己的文件区）
 *   · assetsDir → `hiker://assets/*`（App 自带资源）
 * 纯相对路径（没有 hiker:// 前缀）按 filesDir 下的相对路径处理 —— 这样
 * `writeFile('a.txt')` 这类老写法照样能用，但跳不出去。
 */
function safePath(rt, raw) {
  const s = String(raw == null ? '' : raw);
  const isAssets = /^hiker:\/\/assets\//i.test(s);
  const isFiles = /^hiker:\/\/files\//i.test(s);
  const rel = s.replace(/^hiker:\/\/(?:assets|files|page)\//i, '');
  const roots = [isAssets ? rt.assetsDir : rt.filesDir, rt.filesDir, rt.assetsDir]
    .filter((x) => x && String(x).trim());
  // 相对路径的基准：`hiker://assets/*` 落在 assetsDir，其余（含纯相对路径）落在 filesDir
  const base = String((isAssets ? rt.assetsDir : rt.filesDir) || '');
  if (!base) throw new Error('文件系统根未知（宿主没传 filesDir/assetsDir）');
  const target = path.resolve(base, isAssets || isFiles ? rel : s);
  for (const r of roots) {
    const root = path.resolve(r);
    if (target === root || target.startsWith(root + path.sep)) return target;
  }
  throw new Error(
    `路径越界被拒绝（只能读写 hiker 目录下的文件）：${s.slice(0, 120)}`,
  );
}

/** 写文本文件（必要时建目录）；路径先经 [safePath] 收敛，跳不出允许的目录 */
function writeTextFile(rt, p, content) {
  const s = String(p || '');
  if (!s.trim()) throw new Error('writeFile 需要一个路径');
  const file = safePath(rt, s);
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, content == null ? '' : String(content), 'utf8');
    return true;
  } catch (e) {
    throw new Error(`写文件失败（${file}）：${describeError(e)}`);
  }
}

/**
 * `hiker://...` 伪协议的解析 —— **语义按海阔官方文档**
 *（其源码 `app/src/main/assets/help_js.json`）：
 *
 *   · `hiker://page/<名>`   → 源内页面模块的对象字符串
 *      文档原话：`request('hiker://page/detail')` 返回
 *      `'{'name':'详情','path':'detail','rule':'js:xxx'}'`
 *      找不到 ⇒ 是**用户从仓库导入的页**（如 Apollo），源里没带 ⇒ 明确报错
 *   · `hiker://assets/<名>` → **App 自带资源**（`home.js` / `aes.js` …）⇒ 返回**文件内容**
 *      用法实例：`eval(fetch("hiker://assets/home.js"))`
 *   · `hiker://files/<名>`  → 文件系统（`<Documents>/hiker/files`）
 */
function hikerFetch(rt, url) {
  const s = String(url || '');
  const isPage = /^hiker:\/\/page\//i.test(s);
  const key = normalizeModuleName(s);
  const mod = rt.modules && rt.modules.get(key);
  if (isPage && mod) {
    return JSON.stringify({
      name: key,
      path: String(mod.path || key),
      rule: String(mod.rule || ''),
      col_type: String(mod.col_type || ''),
    });
  }
  const rel = s.replace(/^hiker:\/\/(?:files|assets|page)\//i, '');
  // 两个根都经 safePath 收敛（越界会抛出明确原因，而不是静默读到外部文件）
  const fromAssets = readText(safePath(rt, `hiker://assets/${key || rel}`));
  if (fromAssets != null) return fromAssets;
  const fromFiles = readText(safePath(rt, `hiker://files/${rel}`));
  if (fromFiles != null) return fromFiles;
  throw new Error(
    `hiker://${isPage ? 'page' : (s.startsWith('hiker://files') ? 'files' : 'assets')}/${key} 不存在`
    + '（这是海阔 App 自带资源或用户自己导入的页，源里没带 ⇒ 无法提供）',
  );
}

/** 同步取网页（重放桥的发起端） */
function httpSync(rt, url, opts) {
  const u = String(url == null ? '' : url);
  // `hiker://...` 是**宿主资源/文件**，不联网（见 hikerFetch）
  if (/^hiker:\/\//i.test(u)) {
    return hikerFetch(rt, u);
  }
  if (!/^https?:\/\//i.test(u)) {
    // 给出**能看懂**的错误，而不是 axios 的 "Unsupported protocol"
    throw new Error(
      `只支持 http(s) 地址，规则要的是「${u.slice(0, 80) || '(空)'}」`
      + `（hiker:// 内置页面模块 / 动态域名 Phase 1 不支持）`,
    );
  }
  const key = cacheKeyOf(u, opts);
  if (rt.cache.has(key)) return rt.cache.get(key);
  // 记下"这一轮想要抓这个页面"：万一规则内部 `try { fetch() } catch(e) {}`
  // 把 NeedFetch 吞了，引擎仍能据此补抓一轮（见 runHikerRule 每轮之后的补抓闸门）。
  rt.wantFetch = { url: u, key, opts, webview: false };
  throw new NeedFetch(u, opts, key);
}

/** `fetchCodeByWebView` 的同步端（重放桥的第二种信号，见 [NeedWebView]） */
function webViewSync(rt, input, opts) {
  const u = String(input == null ? '' : input);
  if (!/^https?:\/\//i.test(u)) {
    throw new Error(
      `fetchCodeByWebView 只支持 http(s) 地址，收到「${u.slice(0, 80) || '(空)'}」`,
    );
  }
  const key = `wv:${u}|${JSON.stringify(opts || {})}`;
  if (rt.cache.has(key)) return rt.cache.get(key);
  // 同 httpSync：被规则吞掉时也要能补抓（走宿主的 WebView 桥）
  rt.wantFetch = { url: u, key, opts: opts || {}, webview: true };
  throw new NeedWebView(u, opts || {}, key);
}

/** 简易字符串指纹（lazyRule 的 id：同一段函数源码 → 同一个 id，保证第二趟能对上） */
function simpleHash(s) {
  let h = 5381;
  for (let i = 0; i < s.length; i++) {
    h = ((h << 5) + h + s.charCodeAt(i)) >>> 0;
  }
  return h.toString(36);
}

/**
 * 海阔的 `$('').lazyRule(fn)` = **延迟规则**：默认返回一个标记地址，
 * 等用户真的点它时才执行 `fn`（里面通常就是 WebView 抓页这种重活）。
 *
 * 我们实现成**两趟**：第一趟返回 `hiker://lazy#<id>`；宿主拿着 id 再请求一次
 * （`params.lazyId`），第二趟匹配到同一个 id 就直接 `fn()` 取真值。
 * 好处是不必把 JS 上下文常驻在 Node 里 —— 规则是确定性的，重跑结果一致。
 */
function lazyRuleImpl(rt, ctx, fn, args) {
  const a = Array.isArray(args) ? args : [];
  let argSig = '';
  try {
    argSig = JSON.stringify(a);
  } catch (_) {
    argSig = String(a.length);
  }
  const src = (typeof fn === 'function' ? fn.toString() : String(fn)) + '|' + argSig;
  const id = simpleHash(src);
  rt.lazyIds.add(id);
  if (ctx.lazyId && String(ctx.lazyId) === id) {
    return typeof fn === 'function' ? fn(...a) : undefined; // 第二趟：真正执行
  }
  return `hiker://lazy#${id}`;
}

// ============================================================
// DOM 选择器 DSL（海阔的 `A&&B&&C`）
// ============================================================

/**
 * 纯选择器链：逐级 find；无匹配返回 null。
 *
 * ⚠️ 第一段必须用 `$(seg)` 从**文档根**查，不能 `$root.find(seg)` ——
 *   `cheerio.load()` 返回的是一个**函数** `$`，它自己没有 `.find` / `.eq`
 *   （实测报 `$root.eq is not a function`）。后续段才在上一结果里 `find`。
 */
function selectByPath($, pathSegs) {
  let cur = null;
  for (const seg of pathSegs) {
    if (seg === '*') continue;
    try {
      // 第一段从**文档根**查（`$(sel)`）—— `cheerio.load()` 返回的是**函数** `$`，
      // 它自己没有 `.find`/`.eq`（曾实测 `$root.eq is not a function`）
      cur = cur === null ? $(seg) : cur.find(seg);
    } catch (_) {
      return null; // 无效选择器
    }
    if (!cur || cur.length === 0) return null;
  }
  if (cur === null) cur = $('body');
  return cur;
}

/**
 * 解析海阔的 `A&&B&&C` 规则。
 *
 * ── 为什么要「自适应」────────────────────────────────────────────
 * 同一个 DSL 在两种用法下最后一段含义**不同**：
 *   · `parseDomForArray(html,'body&&tbody[id]')` → 最后一段是**选择器**（要元素）
 *   · `parseDomForHtml(tbody,'a&&href')`        → 最后一段是**属性名**（要值）
 *   · `parseDomForHtml(tbody,'.xst&&Text')`     → 最后一段是**取值说明**
 * 分不清就只能先当选择器走一遍：走通了就是前者；**走不通**再把最后一段
 * 当「取值说明」（这一点非常关键 —— 否则 `a&&href` 会被当成找 `<href>` 标签，
 * 实测直接返回空串，规则全军覆没）。
 */
function resolveRule($, rule) {
  const segs = String(rule || '')
    .split('&&')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  if (segs.length === 0) return { nodes: null, value: '' };
  const all = selectByPath($, segs);
  if (all) return { nodes: all, value: '' };
  const nodes = segs.length === 1 ? $('body') : selectByPath($, segs.slice(0, -1));
  if (nodes) return { nodes, value: segs[segs.length - 1] };
  return { nodes: null, value: '' };
}

/** 从单个节点取「取值说明」对应的值（leaf 为空 → 文本） */
function valueOfNode($, el, leaf) {
  const $el = $(el);
  const l = String(leaf || '').trim();
  switch (l.toLowerCase()) {
    case 'text':
      return $el.text().trim();
    case 'html':
      return $el.html() || '';
    case 'outerhtml':
      return $.html($el);
    case 'all':
    case '*':
      return $.html($el);
    case '':
      return $el.text().trim();
    default: {
      const attr = $el.attr(l);
      return attr != null ? String(attr) : $el.text().trim();
    }
  }
}

/**
 * 把 `$.require(...)` 的参数**归一化**成源内 `pages` 的模块名。
 *
 * ⚠️ 实测（用户那份 115 个真实源）：70 个引用了 `hiker://page|assets`，其中
 *    **64 个（91%）的目标就在源自己的 `pages` 里** —— 它不是"海阔内置模块"，
 *    只是用 `hiker://page/xxx` 这种写法指向**自分发**的模块
 *    （`$.require('hiker://page/miss')` ↔ `pages[{name:'miss'}]`）。
 *    之前把这一整片判成"不支持"是误判。
 */
function normalizeModuleName(raw) {
  let k = String(raw || '').trim();
  k = k.replace(/^hiker:\/\/(?:page|assets)\//i, '');
  // 去掉 `#noHistory#?p=fypage` 之类的尾巴 —— 注意**全角问号**也要算
  // （实测有源写成 `hiker://page/funcTools？？rule=xxx`）
  k = k.split(/[#?？]/)[0].trim();
  return k;
}

/** 依次尝试的候选名：原名 → basename → 去掉 `.js` */
function moduleCandidates(raw) {
  const k = normalizeModuleName(raw);
  const out = [k];
  const base = k.split('/').pop() || '';
  if (base && base !== k) out.push(base);
  if (base && /\.js$/i.test(base)) {
    out.push(base.replace(/\.js$/i, ''));
    if (base !== k) out.push(k.replace(/\.js$/i, ''));
  }
  return [...new Set(out.filter((x) => x.length > 0))];
}

// ============================================================
// 结果归一化
// ============================================================

/**
 * 海阔的「二级规则」（**不是** `js:` 的老式写法）：
 *
 *   容器选择器; 标题规则; 链接规则; 图片规则; 描述规则; …
 *   实测样式：`body&&.result; h3&&Text; a&&href; *; .c-abstract&&Text; *`
 *   （`*` 或空 = 该字段不取；`吾爱破解𝔥` 的 searchFind 就是这个）
 *
 * 数据源是**当前页面**（等价于脚本里的 `getResCode()`）。
 */
function parseDomForArrayStr(html, rule) {
  const $ = cheerio.load(String(html || ''));
  const r = resolveRule($, rule);
  const out = [];
  if (r.nodes && r.nodes.length) r.nodes.each((_, el) => out.push($.html(el)));
  return out;
}

function parseDomForHtmlStr(html, rule) {
  const $ = cheerio.load(String(html || ''));
  const r = resolveRule($, rule);
  if (!r.nodes || r.nodes.length === 0) return '';
  return valueOfNode($, r.nodes.get(0), r.value);
}

function runSecondaryRule(html, rule, fallbackColType, maxItems) {
  const parts = String(rule || '')
    .split(';')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  if (parts.length === 0) return [];
  const itemRule = parts[0];
  const fields = parts.slice(1);
  const pick = (frag, r) => {
    const rr = String(r || '').trim();
    if (!rr || rr === '*') return '';
    try {
      return parseDomForHtmlStr(frag, rr);
    } catch (_) {
      return '';
    }
  };
  const out = [];
  for (const frag of parseDomForArrayStr(html, itemRule)) {
    const it = {
      title: pick(frag, fields[0]),
      url: pick(frag, fields[1]),
      pic: pick(frag, fields[2]),
      desc: pick(frag, fields[3]),
    };
    const n = normItem(it, fallbackColType);
    if (n) out.push(n);
    if (out.length >= (maxItems || MAX_ITEMS)) break;
  }
  return out;
}

function normItem(it, fallbackColType) {
  if (!it || typeof it !== 'object') return null;
  const title = String(it.title ?? it.name ?? '').trim();
  let url = String(it.url ?? it.link ?? it.href ?? '').trim();
  if (url.startsWith('x5://')) url = url.slice(5);
  const pic = String(it.pic_url ?? it.pic ?? it.img ?? it.cover ?? '').trim();
  const desc = String(it.desc ?? it.description ?? it.remarks ?? '').trim();
  const colType = String(it.col_type ?? fallbackColType ?? '').trim();
  if (!title && !url) return null;
  return {
    title,
    url,
    pic,
    desc,
    colType,
    // 透传业务字段（pageTitle / searchTerms / hideSetting 等），Phase 1 只做展示
    extra: (it.extra && typeof it.extra === 'object') ? it.extra : undefined,
  };
}

/**
 * 海阔列表 DSL：`title: a; url: b;; title: c; url: d`
 * （字段之间 `;`、条目之间 `;;`）
 */
function parseHikerListDsl(text) {
  const out = [];
  for (const block of String(text).split(';;')) {
    const t = block.trim();
    if (!t) continue;
    const it = {};
    // 用「行内 `;`」切字段；值里可能含 `:`（URL），所以只切第一个冒号
    for (const field of t.split(';')) {
      const f = field.trim();
      if (!f) continue;
      const i = f.indexOf(':');
      if (i <= 0) continue;
      const k = f.slice(0, i).trim();
      const v = f.slice(i + 1).trim();
      if (k) it[k] = v;
    }
    if (Object.keys(it).length) out.push(it);
  }
  return out;
}

function extractItems(raw, fallbackColType, maxItems) {
  const limit = maxItems || MAX_ITEMS;
  if (raw == null) return [];
  // setHomeResult({data:[...]}) / {data:'json 串'}
  let arr = null;
  if (Array.isArray(raw)) {
    arr = raw;
  } else if (typeof raw === 'string') {
    const s = raw.trim();
    if (s.startsWith('[') || s.startsWith('{')) {
      try {
        const j = JSON.parse(s);
        arr = Array.isArray(j) ? j : j.data;
      } catch (_) {
        arr = parseHikerListDsl(s);
      }
    } else {
      arr = parseHikerListDsl(s);
    }
  } else if (typeof raw === 'object') {
    arr = raw.data ?? raw.list ?? raw.items ?? null;
    if (Array.isArray(arr) && arr.length && typeof arr[0] === 'string') {
      // {data:['title: x;; ...']} 这种把 DSL 塞进数组的写法
      const joined = arr.join('');
      return parseHikerListDsl(joined)
        .map((x) => normItem(x, fallbackColType))
        .filter(Boolean)
        .slice(0, limit);
    }
  }
  if (!Array.isArray(arr)) return [];
  return arr
    .map((x) => (typeof x === 'string' ? normItem(parseHikerListDsl(x)[0], fallbackColType) : normItem(x, fallbackColType)))
    .filter(Boolean)
    .slice(0, limit);
}

// ============================================================
// `java.*` —— Rhino 的 Java 互操作（有限 shim）
// ============================================================

/** Java `byte[]` 的类型标记（`java.lang.reflect.Array.newInstance(java.lang.Byte.TYPE, n)` 用） */
const JAVA_BYTE_TYPE = { __javaType: 'byte' };

/** 各种形态 → Buffer（规则里 byte[] 是**有符号**数字数组，字符串按 utf-8） */
function bufOf(v) {
  if (v == null) return Buffer.alloc(0);
  if (Buffer.isBuffer(v)) return v;
  if (typeof v === 'string') return Buffer.from(v, 'utf8');
  if (Array.isArray(v)) {
    return Buffer.from(v.map((b) => (Number(b) || 0) & 0xff));
  }
  if (v instanceof Uint8Array) return Buffer.from(v);
  if (v && Buffer.isBuffer(v.__bytes)) return v.__bytes;
  return Buffer.from(String(v), 'utf8');
}

/** Buffer → Java `byte[]` 的 JS 表示（Rhino 里 byte[] 是**有符号**数字数组） */
function signedBytes(buf) {
  const out = new Array(buf.length);
  for (let i = 0; i < buf.length; i++) out[i] = buf[i] > 127 ? buf[i] - 256 : buf[i];
  return out;
}

function decodeWithCharset(v, charset) {
  const cs = String(charset || 'utf-8').toLowerCase();
  const buf = bufOf(v);
  if (cs === 'utf-8' || cs === 'utf8') return buf.toString('utf8');
  try {
    return iconv.decode(buf, cs);
  } catch (_) {
    return buf.toString('utf8');
  }
}

/** 同步睡眠（Rhino 里 `java.lang.Thread.sleep(ms)` 就是阻塞当前线程） */
function sleepSync(ms) {
  const n = Math.min(Math.max(0, Number(ms) || 0), 5000);
  if (n <= 0) return;
  // Node 主线程允许 Atomics.wait（浏览器不允许），用法与阻塞睡眠一致
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, n);
}

/** 把"整块字节"模拟成 Java InputStream 的最小面（read/available/skip/close） */
function makeInputStream(buf) {
  let pos = 0;
  const api = {
    __bytes: buf,
    read: (target, off, len) => {
      if (target == null) return pos < buf.length ? buf[pos++] : -1;
      const start = typeof off === 'number' ? off : 0;
      const count = typeof len === 'number' ? len : target.length;
      const n = Math.min(count, buf.length - pos);
      if (n <= 0) return -1;
      for (let i = 0; i < n; i++) {
        target[start + i] = buf[pos + i] > 127 ? buf[pos + i] - 256 : buf[pos + i];
      }
      pos += n;
      return n;
    },
    readAllBytes: () => signedBytes(buf.subarray(pos)),
    available: () => buf.length - pos,
    skip: (n) => {
      const k = Math.min(buf.length - pos, Math.max(0, Number(n) || 0));
      pos += k;
      return k;
    },
    markSupported: () => false,
    close: () => {},
    __remaining: () => buf.subarray(pos),
  };
  return api;
}

/** `String.format` 的最小实现（%s/%d/%f/%x/%n，够用即可） */
function javaStringFormat(fmt, args) {
  let i = 0;
  return String(fmt == null ? '' : fmt).replace(/%([sdfxXn])/g, (_, t) => {
    const v = args[i++];
    if (t === 'n') return '\n';
    if (t === 'd' || t === 'x' || t === 'X') {
      const n = Math.trunc(Number(v) || 0);
      return t === 'd' ? String(n) : n.toString(16);
    }
    if (t === 'f') return String(Number(v) || 0);
    return v == null ? 'null' : String(v);
  });
}

/**
 * 构造 `java` 命名空间。
 *
 * ── 为什么需要它（重要）────────────────────────────────────────────
 * 海阔的 JS 引擎是 **Rhino 1.7.13 + ImporterTopLevel**（见官方源码
 * `app/build.gradle` 的 `libs/rhino-1.7.13.jar` 与 `JSEngine.java` 的 import）
 * ⇒ `java.*` / `Packages.*` 是**引擎自带**的 Java 互操作，**不是 Legado 专属**：
 * 海阔自己的源也在用（实测 115 个源里 12 个用到）。
 *
 * 我们的规则跑在 Node 里，没有 Java 运行时 ⇒ 按「源实际用到的类」做**有限 shim**：
 *   java.lang.Thread.sleep / String / StringBuilder / Integer / Byte / Long
 *   java.util.Base64 / UUID / Arrays / HashMap / ArrayList
 *   java.security.MessageDigest
 *   java.io.ByteArrayInputStream / ByteArrayOutputStream / File
 *   java.util.zip.GZIPInputStream      java.lang.reflect.Array
 *
 * 典型场景是**密文核心**（如 JavDB）：
 *   `base64 → ByteArrayInputStream → GZIPInputStream → ByteArrayOutputStream
 *     → new java.lang.String(bytes,'UTF-8') → eval(...)`
 * 这条链现在**能真跑通**（两端都用 Base64 + zlib 实现）。
 *
 * 做不到的：任意 Java 类反射调用（如 `java.lang.reflect` 去调 Android SDK）
 * —— 那类源不支持，会给出明确报错而不是静默出错数据。
 */
function buildJavaNs() {
  const JavaString = function (a, b) {
    let text;
    if (a == null) {
      text = '';
    } else if (typeof a === 'string' && typeof b !== 'string') {
      text = a;
    } else {
      // byte[] + charset（`new java.lang.String(bytes, 'UTF-8')`）
      text = typeof a === 'string' ? a : decodeWithCharset(a, b);
    }
    if (!(this instanceof JavaString)) return text; // 当函数调用 → 原始字符串
    const boxed = new String(text);
    // Java String 的常用**方法**（JS 里没有的），补上以免 "is not a function"
    const methods = {
      getBytes: (cs) => {
        const c = String(cs == null ? 'utf-8' : cs).toLowerCase();
        if (c === 'utf-8' || c === 'utf8') return signedBytes(Buffer.from(text, 'utf8'));
        try {
          return signedBytes(iconv.encode(text, c));
        } catch (_) {
          return signedBytes(Buffer.from(text, 'utf8'));
        }
      },
      toCharArray: () => text.split(''),
      isEmpty: () => text.length === 0,
      equals: (o) => text === String(o),
      equalsIgnoreCase: (o) => text.toLowerCase() === String(o).toLowerCase(),
      contains: (o) => text.includes(String(o)),
      indexOf: (o, from) => text.indexOf(String(o), from == null ? 0 : Number(from)),
      hashCode: () => {
        let h = 0;
        for (let i = 0; i < text.length; i++) h = (h * 31 + text.charCodeAt(i)) | 0;
        return h;
      },
    };
    for (const k of Object.keys(methods)) boxed[k] = methods[k];
    return boxed;
  };
  JavaString.valueOf = (x) => (x == null ? 'null' : String(x));
  JavaString.join = (sep, ...xs) => xs.map((x) => String(x)).join(sep == null ? '' : sep);
  JavaString.format = (fmt, ...args) => javaStringFormat(fmt, args);
  JavaString.CASE_INSENSITIVE_ORDER = 0;

  const JavaStringBuilder = function (s) {
    let buf = s == null ? '' : String(s);
    const api = {
      append: (x) => { buf += (x == null ? 'null' : String(x)); return api; },
      insert: (i, x) => {
        const k = Math.max(0, Number(i) || 0);
        buf = buf.slice(0, k) + (x == null ? 'null' : String(x)) + buf.slice(k);
        return api;
      },
      deleteCharAt: (i) => { const k = Number(i) || 0; buf = buf.slice(0, k) + buf.slice(k + 1); return api; },
      reverse: () => { buf = buf.split('').reverse().join(''); return api; },
      length: () => buf.length,
      toString: () => buf,
    };
    return api;
  };

  const JavaFile = function (p) {
    const full = String(p == null ? '' : p);
    return {
      getPath: () => full,
      getAbsolutePath: () => full,
      getName: () => full.split('/').pop() || '',
      // iOS 上没有 Android 的那些路径 ⇒ 一律"不存在"，比抛错好（源里多见示例代码）
      exists: () => false,
      isFile: () => false,
      isDirectory: () => false,
      length: () => 0,
      listFiles: () => {
        warnOnce(`java.io.File.listFiles 不可用（iOS 沙箱，路径：${full.slice(0, 80)}）`);
        return [];
      },
      mkdirs: () => false,
      delete: () => false,
    };
  };

  // 照 Rhino 语义包成"动态命名空间"（未知类名 → 占位类），见 [lazyJavaNs]
  return lazyJavaNs({
    lang: {
      String: JavaString,
      StringBuilder: JavaStringBuilder,
      Integer: {
        parseInt: (s, radix) => parseInt(String(s), Number(radix) || 10),
        valueOf: (s) => parseInt(String(s), 10),
        toString: (n) => String(Math.trunc(Number(n) || 0)),
        MAX_VALUE: 2147483647,
        MIN_VALUE: -2147483648,
      },
      Long: {
        parseLong: (s) => parseInt(String(s), 10),
        valueOf: (s) => parseInt(String(s), 10),
        MAX_VALUE: Number.MAX_SAFE_INTEGER,
        MIN_VALUE: Number.MIN_SAFE_INTEGER,
      },
      Double: { parseDouble: (s) => parseFloat(String(s)), valueOf: (s) => parseFloat(String(s)), MAX_VALUE: Number.MAX_VALUE },
      Byte: { parseByte: (s) => parseInt(String(s), 10), TYPE: JAVA_BYTE_TYPE, MAX_VALUE: 127, MIN_VALUE: -128 },
      Boolean: { parseBoolean: (s) => String(s) === 'true', TRUE: true, FALSE: false },
      Thread: {
        sleep: (ms) => sleepSync(ms),
        currentThread: () => ({ getName: () => 'hiker-node', sleep: (ms) => sleepSync(ms) }),
      },
      System: {
        currentTimeMillis: () => Date.now(),
        nanoTime: () => Date.now() * 1e6,
        lineSeparator: () => '\n',
        getProperty: () => '',
        arraycopy: (src, sp, dst, dp, len) => {
          for (let i = 0; i < Number(len); i++) dst[Number(dp) + i] = src[Number(sp) + i];
        },
        exit: () => { throw new Error('规则里调用了 java.lang.System.exit()，已忽略'); },
      },
      Math,
      Object,
      Exception: Error,
      RuntimeException: Error,
      reflect: {
        Array: {
          newInstance: (t, len) => new Array(Math.max(0, Number(len) || 0)).fill(0),
          getLength: (a) => (a && typeof a.length === 'number' ? a.length : 0),
        },
      },
    },
    util: {
      Base64: {
        getDecoder: () => ({
          decode: (s) => signedBytes(Buffer.from(String(s == null ? '' : s).replace(/\s+/g, ''), 'base64')),
        }),
        getEncoder: () => ({
          encodeToString: (b) => bufOf(b).toString('base64'),
        }),
        getUrlDecoder: () => ({
          decode: (s) => signedBytes(Buffer.from(
            String(s == null ? '' : s).replace(/-/g, '+').replace(/_/g, '/'), 'base64')),
        }),
        getUrlEncoder: () => ({
          encodeToString: (b) => bufOf(b).toString('base64').replace(/\+/g, '-').replace(/\//g, '_'),
        }),
      },
      UUID: {
        randomUUID: () => {
          const s = crypto.randomUUID();
          return { toString: () => s, getLeastSignificantBits: () => 0, getMostSignificantBits: () => 0 };
        },
      },
      Arrays: {
        asList: (...xs) => xs,
        toString: (a) => JSON.stringify(a == null ? [] : a),
        sort: (a) => { if (Array.isArray(a)) a.sort(); },
        copyOf: (a, n) => (Array.isArray(a) ? a.slice(0, Number(n) || a.length) : []),
      },
      Collections: { sort: (a) => { if (Array.isArray(a)) a.sort(); }, emptyList: () => [] },
      HashMap: function () {
        const m = new Map();
        return {
          put: (k, v) => { m.set(String(k), v); return v; },
          get: (k) => (m.has(String(k)) ? m.get(String(k)) : null),
          containsKey: (k) => m.has(String(k)),
          remove: (k) => m.delete(String(k)),
          keySet: () => [...m.keys()],
          values: () => [...m.values()],
          size: () => m.size,
          isEmpty: () => m.size === 0,
          clear: () => m.clear(),
        };
      },
      ArrayList: function () {
        const a = [];
        return {
          add: (x) => { a.push(x); return true; },
          get: (i) => a[Number(i)],
          set: (i, x) => { a[Number(i)] = x; return x; },
          size: () => a.length,
          isEmpty: () => a.length === 0,
          toArray: () => a,
          clear: () => { a.length = 0; },
          contains: (x) => a.includes(x),
        };
      },
      Date: Date,
      // `java.util.zip.*`（Java 的类名就是 java.util.zip.GZIPInputStream）
      zip: {
        GZIPInputStream: function (bis) {
          const all = bis && typeof bis.__remaining === 'function' ? bis.__remaining() : bufOf(bis);
          let out;
          try {
            out = zlib.gunzipSync(all);
          } catch (e) {
            throw new Error(`GZIP 解压失败（GZIPInputStream）：${describeError(e)}`);
          }
          return makeInputStream(out);
        },
        GZIPOutputStream: function () {
          throw new Error('java.util.zip.GZIPOutputStream 暂不支持（只用到压缩侧才会踩到）');
        },
      },
    },
    io: {
      ByteArrayInputStream: function (bytes) { return makeInputStream(bufOf(bytes)); },
      ByteArrayOutputStream: function () {
        const chunks = [];
        const joined = () => Buffer.concat(chunks);
        return {
          write: (b, off, len) => {
            if (Array.isArray(b) || Buffer.isBuffer(b) || b instanceof Uint8Array) {
              const start = Number(off) || 0;
              const n = len == null ? b.length - start : Number(len);
              const part = Buffer.from(Array.from(b.slice(start, start + n)).map((x) => (Number(x) || 0) & 0xff));
              chunks.push(part);
            } else {
              chunks.push(Buffer.from([(Number(b) || 0) & 0xff]));
            }
          },
          writeBytes: (b) => {
            const part = Buffer.from(Array.from(b).map((x) => (Number(x) || 0) & 0xff));
            chunks.push(part);
          },
          toByteArray: () => signedBytes(joined()),
          toString: (cs) => decodeWithCharset(joined(), cs),
          size: () => joined().length,
          flush: () => {},
          close: () => {},
        };
      },
      File: JavaFile,
      FileOutputStream: function () { throw new Error('java.io.FileOutputStream 不可用（规则不允许写沙箱外文件）'); },
    },
    security: {
      MessageDigest: {
        getInstance: function (alg) {
          const a = String(alg == null ? 'MD5' : alg).toUpperCase().replace(/[^A-Z0-9]/g, '');
          const name = a === 'SHA1' ? 'sha1'
            : a === 'SHA256' ? 'sha256'
              : a === 'SHA384' ? 'sha384'
                : a === 'SHA512' ? 'sha512' : 'md5';
          const parts = [];
          const hex = () => crypto.createHash(name).update(Buffer.concat(parts)).digest('hex');
          const api = {
            update: (d) => {
              parts.push(typeof d === 'string' ? Buffer.from(d, 'utf8') : bufOf(d));
              return api;
            },
            // 有的源直接 digest(bytes) 一次到位
            digest: (d) => {
              if (d != null && typeof d !== 'string') api.update(d);
              else if (typeof d === 'string' && d.length > 0) api.update(d);
              return signedBytes(crypto.createHash(name).update(Buffer.concat(parts)).digest());
            },
            reset: () => { parts.length = 0; return api; },
            toString: () => hex(),
            getAlgorithm: () => a,
            __hex: () => hex(),
          };
          return api;
        },
      },
    },
    // 海阔自定义的繁简转换（实测只有 2 处用到；没有对照表 ⇒ 原样返回 + 提示一次，
    // 比抛错好：抛错会让整条规则在加载期就炸掉）
    t2s: (s) => {
      warnOnce('java.t2s（繁转简）未实现，已原样返回');
      return s == null ? '' : String(s);
    },
    s2t: (s) => {
      warnOnce('java.s2t（简转繁）未实现，已原样返回');
      return s == null ? '' : String(s);
    },
  });
}

/** 占位类：只为让未知的 Java 类名不至于让规则当场炸（`instanceof` / `new` / `.class`） */
function makeMissingJavaClass(name) {
  const f = function () {};
  try {
    Object.defineProperty(f, 'name', { value: String(name || 'JavaClass'), configurable: true });
  } catch (_) { /* 忽略 */ }
  f.class = f;
  f.getName = () => String(name || '');
  f.toString = () => `[JavaClass ${name || ''}]`;
  // 包名也可能是"命名空间"（`java.nio.ByteBuffer`）⇒ 继续给占位，别让属性访问变 undefined
  return new Proxy(f, {
    get(t, p) {
      if (typeof p !== 'string') return t[p];
      if (LAZY_NS_DENY.has(p)) return t[p];
      if (t[p] !== undefined) return t[p];
      const child = makeMissingJavaClass(`${name}.${p}`);
      try {
        Object.defineProperty(t, p, { value: child, writable: true, configurable: true });
      } catch (_) { /* 忽略 */ }
      return child;
    },
    has: () => true,
  });
}

/// 这些属性名**绝不能被"动态解析"**，否则会引起连锁反应
/// （`then` 会把 `await java` 变成 thenable；`toJSON`/`$$typeof` 等同理）
const LAZY_NS_DENY = new Set([
  'then', 'catch', 'finally', 'toJSON', '$$typeof', 'constructor', 'prototype',
  'inspect', 'nodeType', 'valueOf',
]);

/// 已包装过的命名空间（target → proxy）：保证 `java.util === java.util` 恒真
const LAZY_NS_CACHE = new WeakMap();

/**
 * 动态命名空间（照 Rhino 语义）：已知名字给真实现，**未知名字给占位类**。
 *
 * 为什么需要（用户 2026-10-15 实测「小霸王」报
 * `Right-hand side of 'instanceof' is not an object`）：
 * 真海阔跑在 Rhino 上，`java.*` / `Packages.*` 是**动态解析**的 —— 任意类名都能
 * 拿到一个"类对象"，只有真正用它才可能失败；我这边原本是写死的对象 ⇒ 缺一个
 * 名字就是 undefined ⇒ 规则里 `x instanceof java.util.List` 直接抛原生 TypeError
 *（`instanceof` 的右值不是对象就是这个错）。
 *
 * ⚠️ 必须**递归**包装真实的子命名空间（`util` / `zip` …）：只包外层时
 *    `java.util.List` 依然取到 undefined（实测踩过）。
 */
function lazyJavaNs(target) {
  const cached = LAZY_NS_CACHE.get(target);
  if (cached) return cached;
  const proxy = new Proxy(target, {
    get(t, p) {
      if (typeof p !== 'string') return t[p];
      const hit = t[p];
      if (hit !== undefined) {
        // `prototype` / `constructor` 必须原样给：`instanceof` 与 `new` 靠它做
        // 身份比较，包一层会让真实类的 `x instanceof java.lang.String` 静默变 false
        if (p === 'prototype' || p === 'constructor') return hit;
        if (hit !== null && typeof hit === 'object' && !Array.isArray(hit)) {
          return lazyJavaNs(hit);
        }
        return hit;
      }
      if (LAZY_NS_DENY.has(p)) return undefined;
      const ph = makeMissingJavaClass(p);
      try {
        Object.defineProperty(t, p, { value: ph, writable: true, configurable: true });
      } catch (_) { /* 忽略 */ }
      return ph;
    },
    has: () => true,
  });
  LAZY_NS_CACHE.set(target, proxy);
  return proxy;
}

// ============================================================
// 模块作用域（`$.require` / `rc` 共用）
// ============================================================

/**
 * 在**独立函数作用域**里执行模块 / 远端 JS，并把它顶层声明的名字**发布到沙箱**。
 *
 * ── 为什么是这套语义（照官方实现）────────────────────────────────
 * 官方 `JSEngine.require0()` 把模块源码交给 `IdFunctionObject.call(...)` 执行，
 * 于是：
 *   · 模块里的 `const/let/var` 在自己的作用域里 —— 多个模块**不会**撞名
 *     （直接在共享 sandbox 里 eval 会报 "Identifier 'x' has already been declared"）；
 *   · 模块顶层的 `return` 合法（不少模块就写成 `return {...}`）；
 *   · **模块间共享变量仍然可见** —— 实测有源用别的模块定义的 `Apollo` /
 *     `MY_CLASS_URL` / `rc` 这类名字，所以执行完要把顶层名字**回填沙箱**。
 *
 * 返回值 = `wantName` 对应的绑定；模块用 `return xxx` 直接给值时，那个值就是结果。
 *   （这段注释属于 [runInModuleScope] —— 它就写在下面隔一个函数的位置）
 */
/**
 * `$.require(...)` / 裸 `require(...)` 的出口统一处理：
 *   ① 返回值补一个 `.default`（**非枚举**、指向自身）—— 一批海阔模块/规则是按
 *      CommonJS 编译的，消费方写的是 `$.require('x').default`；
 *   ② 真没取到值就**明确报错**，而不是返回 undefined。
 *
 * ② 是用户 2026-10-15 实测「AVbebe」报
 * `Cannot read properties of undefined (reading 'default')` 的根因：
 * 模块没取到值 → 返回 undefined → 规则一取 `.default` 就抛原生 TypeError，
 * 用户只能看到一句没有任何线索的英文错误。现在直接说清"哪个模块、为什么"。
 */
function normalizeModuleValue(v, name) {
  if (v === undefined || v === null) {
    const e = new Error(
      `require('${String(name == null ? '' : name)}') 没取到值 —— `
      + '这个模块可能不在该源的 pages 里，或它没写 `$.exports = ...`'
      + '（若它依赖源配置，去「海阔源管理 → 源配置」补上）',
    );
    e.__hikerModuleError = true;
    throw e;
  }
  if ((typeof v === 'object' || typeof v === 'function') && v.default === undefined) {
    try {
      Object.defineProperty(v, 'default', {
        value: v, enumerable: false, configurable: true, writable: true,
      });
    } catch (_) { /* 冻结/不可扩展的对象：忽略 */ }
  }
  return v;
}

function runInModuleScope(sandbox, code, wantName) {
  const body = stripJsPrefix(code);
  const names = new Set();
  const re = /(?:^|\n)\s*(?:const|let|var|function|class)\s+([A-Za-z_$][\w$]*)/g;
  let m;
  while ((m = re.exec(body)) !== null && names.size < 40) names.add(m[1]);
  const capture = [...names]
    .map((n) => `${n}:(typeof ${n}==="undefined"?undefined:${n})`)
    .join(',');
  const src = `(function(){\n${body}\n;try{return {__hikerCapture:true${capture ? ',' + capture : ''}};}catch(__e){return {};}\n})()`;
  // ⚠️ 海阔的模块导出约定是 `$.exports = xxx;`（CommonJS 风格）——
  //   实测多个源都这样写（`$.exports = fnx;` / `= CRDJ;` / `= engine;`），
  //   而模块名（main / xiu / lsp）跟内部变量名**并不一致**，
  //   所以"按名字查找"永远取不到值 ⇒ 必须优先读 `$.exports`。
  //   每次 require 前先清空，避免拿到上一个模块的 exports（会串数据）。
  const dollar = sandbox.$;
  const hadExports = dollar && Object.prototype.hasOwnProperty.call(dollar, 'exports');
  const prevExports = hadExports ? dollar.exports : undefined;
  if (dollar) dollar.exports = undefined;
  let out;
  let moduleExports;
  try {
    out = vm.runInContext(src, sandbox, { timeout: SCRIPT_TIMEOUT_MS });
    // ⚠️ 必须在 finally 恢复之前把模块写入的 exports 取出来
    moduleExports = dollar ? dollar.exports : undefined;
  } finally {
    if (dollar) {
      if (hadExports) dollar.exports = prevExports;
      else delete dollar.exports;
    }
  }
  if (moduleExports !== undefined) return moduleExports;
  if (!out || typeof out !== 'object' || out.__hikerCapture !== true) {
    // 模块自己 `return` 了值 ⇒ 那就是 require 的结果
    return out;
  }
  for (const n of names) {
    if (out[n] !== undefined) sandbox[n] = out[n];
  }
  if (!wantName) return out;
  if (out[wantName] !== undefined) return out[wantName];
  // 模块名与内部变量名不一致、又没写 `$.exports` 时的兜底：取最后一个有值的顶层绑定
  const vals = [...names].map((n) => out[n]).filter((v) => v !== undefined);
  if (vals.length) return vals[vals.length - 1];
  // 最后才回落到沙箱里的同名绑定（"另一个模块已经定义过"的情况）
  try {
    return sandbox[wantName];
  } catch (_) {
    return undefined;
  }
}

// ============================================================
// 远端 JS 依赖（`rc` / `requireCache`）
// ============================================================

/**
 * `rc(url, hours)` = 官方 `requireCache`：把远端 JS 抓下来、**缓存到本地**再 eval。
 *
 * 官方说明：「临时缓存：`requireCache('http://xxx/t.js', 24)`，那么文件会缓存
 * 24 小时，超过会重新下载，缩写：rc」。
 * 我们落在 `<filesDir>/libs/<md5(url)>.js`（与海阔的 `libs/` 同构）。
 * 过期或缺失时用 [httpSync] 走**重放桥**抓一次 —— 同步语义由重放保证。
 */
function requireRemoteJs(rt, sandbox, url, hours) {
  const u = String(url == null ? '' : url);
  if (!/^https?:\/\//i.test(u)) {
    throw new Error(`rc()/requireCache() 只支持 http(s) 地址：${u.slice(0, 80) || '(空)'}`);
  }
  const ttlMs = (Number(hours) > 0 ? Number(hours) : 24) * 3600 * 1000;
  const file = rt.filesDir
    ? path.join(rt.filesDir, 'libs', `${crypto.createHash('md5').update(u).digest('hex')}.js`)
    : '';
  if (file) {
    try {
      const st = fs.statSync(file);
      if (Date.now() - st.mtimeMs < ttlMs) {
        return runInModuleScope(sandbox, fs.readFileSync(file, 'utf8'), '');
      }
    } catch (_) { /* 没有缓存 / 读失败 → 走网络 */ }
  }
  const code = String(httpSync(rt, u) || ''); // 可能抛 NeedFetch → 宿主抓完重放
  if (file) {
    try {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, code, 'utf8');
    } catch (e) {
      warnOnce(`rc() 缓存写入失败（不影响本次执行）：${describeError(e)}`);
    }
  }
  return runInModuleScope(sandbox, code, '');
}

// ============================================================
// 海阔的加密全局（`AES` / `Data` / `CryptoJS`）
// ============================================================

/**
 * 官方把 `assets/aes.js`（191KB 的 CryptoJS 副本 + AES/Data 封装）**全局注入**到
 * 每条规则的沙箱里 —— 实测 10 个源直接用 `AES.decrypt(...)` /
 * `Data.parseInputStream(...)`，**从不自己加载** aes.js。
 *
 * 我们引擎本来就带 CryptoJS，所以不内置那个大文件，直接用等价实现：
 *   · `AES`  = CryptoJS.AES，额外把 hiker 的 **字符串** mode/padding
 *     （`"AES/CBC/PKCS7Padding"`）翻译成 CryptoJS 的 mode/pad 对象
 *   · `Data` = hiker 的字节助手（`parseInputStream` 把我们 java 字节流读成 WordArray）
 */
function buildCryptoGlobals() {
  const cfg = (c) => {
    if (!c || typeof c !== 'object') return c;
    const out = { ...c };
    const m = String(c.mode || '').toLowerCase();
    if (m) {
      out.mode = m.includes('cbc') ? CryptoJS.mode.CBC
        : m.includes('cfb') ? CryptoJS.mode.CFB
          : m.includes('ofb') ? CryptoJS.mode.OFB
            : m.includes('ctr') ? CryptoJS.mode.CTR
              : m.includes('ecb') ? CryptoJS.mode.ECB
                : CryptoJS.mode.CBC;
      out.padding = m.includes('nopadding') ? CryptoJS.pad.NoPadding
        : m.includes('iso') ? CryptoJS.pad.Iso10126
          : m.includes('ansix923') ? CryptoJS.pad.AnsiX923
            : m.includes('zero') ? CryptoJS.pad.ZeroPadding
              : CryptoJS.pad.Pkcs7;
    }
    return out;
  };
  const _decrypt = CryptoJS.AES.decrypt.bind(CryptoJS.AES);
  const _encrypt = CryptoJS.AES.encrypt.bind(CryptoJS.AES);
  const AES = {
    // 先透传 CryptoJS.AES 的其余成员（lib/…），再覆盖这两个走 hiker 的字符串 cfg
    ...CryptoJS.AES,
    encrypt: (msg, key, c) => _encrypt(msg, key, cfg(c)),
    decrypt: (cipher, key, c) => _decrypt(cipher, key, cfg(c)),
  };
  const Data = {
    /// 把 java 的 InputStream（我们的字节流包装）读成 WordArray
    parseInputStream: (input) => {
      const buf = input && typeof input.__remaining === 'function'
        ? input.__remaining() : bufOf(input);
      return CryptoJS.lib.WordArray.create(new Uint8Array(buf));
    },
    parseHex: (s) => CryptoJS.enc.Hex.parse(String(s == null ? '' : s)),
    parseBase64: (s) => CryptoJS.enc.Base64.parse(String(s == null ? '' : s)),
    parseString: (s) => CryptoJS.enc.Utf8.parse(String(s == null ? '' : s)),
    toString: (w) => (w && typeof w.toString === 'function'
      ? w.toString(CryptoJS.enc.Utf8) : String(w == null ? '' : w)),
  };
  return { AES, Data };
}

// ============================================================
// 沙箱
// ============================================================

function buildSandbox(rt, state, requireModule, evalPrivateJS) {
  const ctx = rt.ctx;

  const g = (url, opts) => httpSync(rt, url, opts);
  const post = (url, body, opts) => httpSync(rt, url, { ...(opts || {}), method: 'post', body });
  const cryptoGlobals = buildCryptoGlobals();

  /** jQuery 风格薄包装（覆盖海阔脚本最常用的那几个） */
  function jq(input) {
    const $ = typeof input === 'string' ? cheerio.load(input) : input;
    return {
      raw: $,
      find: (sel) => jq($.find ? $.find(sel) : $(sel)),
      text: () => (typeof $ === 'function' ? $('body').text() : $.text()).trim(),
      html: () => (typeof $ === 'function' ? $('body').html() : $.html()),
      attr: (n) => (typeof $ === 'function' ? $('body').attr(n) : $.attr(n)),
      eq: (i) => jq($.eq ? $.eq(i) : $),
      toString: () => (typeof $ === 'function' ? $('body').html() : $.html()),
      // `$('').lazyRule(fn)` —— 延迟规则（见 lazyRuleImpl）
      lazyRule: (fn) => lazyRuleImpl(rt, ctx, fn),
      // `$(url).rule(fn, ...args)` —— hiker 的「局部规则」：点它时执行 fn。
      // 与 lazyRule 共用同一套两趟机制（id 里带上参数签名，避免同规则内多次调用撞车）。
      rule: (fn, ...args) => lazyRuleImpl(rt, ctx, fn, args),
      // ── 同族的"生成链接"API（语义照官方 help_js.json）───────────────
      //   `$(url).input(fn)`            生成**输入框弹窗**链接
      //   `$(url).select(fn)`           生成**选择器弹窗**链接
      //   `$(url,headers).image(fn,s1…)` 生成**图片解密**链接（多带若干参数）
      //   `$(url).x5Rule(fn)`           生成 `javascript:` 链接
      // 四者与 lazyRule 完全同构（都是"先给个标记地址、用户点开时再执行"），
      // 所以共用同一套两趟机制 —— 缺了它们源会直接报 "xxx is not a function"。
      input: (fn) => lazyRuleImpl(rt, ctx, fn),
      select: (fn) => lazyRuleImpl(rt, ctx, fn),
      image: (fn, ...args) => lazyRuleImpl(rt, ctx, fn, args),
      x5Rule: (fn) => lazyRuleImpl(rt, ctx, fn),
    };
  }

  const jQueryLike = (input) => jq(typeof input === 'string' ? input : input);

  const javaNs = buildJavaNs();
  const sandbox = {
    // `java.*` / `Packages.*`：Rhino 的 Java 互操作（有限 shim，见 buildJavaNs）。
    //   ⚠️ 两者都必须是**动态命名空间** —— Rhino 里任意类名都解析得出来，
    //   写死对象会让 `x instanceof java.util.List` 抛
    //   "Right-hand side of 'instanceof' is not an object"（用户 2026-10-15「小霸王」）。
    java: javaNs,
    Packages: lazyJavaNs({ java: javaNs }),
    // ── 环境 ─────────────────────────────────────────────
    console,
    JSON,
    Math,
    Date,
    String,
    Number,
    Boolean,
    Array,
    Object,
    RegExp,
    Error,
    parseInt,
    parseFloat,
    isNaN,
    encodeURIComponent,
    decodeURIComponent,
    encodeURI,
    decodeURI,
    atob: (s) => Buffer.from(String(s), 'base64').toString('binary'),
    btoa: (s) => Buffer.from(String(s), 'binary').toString('base64'),
    // 官方文档里的**裸函数**（`js:base64Encode(input)`、`fetch(base64Decode(...))`）
    // ——实测 MissAV / 道长仓库Pro 直接按全局函数调用，只挂 `$.` 上不够
    base64Encode: (s) => Buffer.from(String(s == null ? '' : s), 'utf8').toString('base64'),
    base64Decode: (s) => Buffer.from(String(s == null ? '' : s), 'base64').toString('utf8'),
    // `rc` / `requireCache` 也常有**裸调用**（实测有源直接写 `rc('http://…/x.js', 24)`）
    //   箭头在调用时才执行 ⇒ 这里引用外层的 `sandbox` 是安全的
    rc: (url, hours) => requireRemoteJs(rt, sandbox, url, hours),
    requireCache: (url, hours) => requireRemoteJs(rt, sandbox, url, hours),
    setTimeout,
    clearTimeout,

    // ── 内置变量 ─────────────────────────────────────────
    /// 海阔的加密全局（官方由 assets/aes.js 全局注入，见 buildCryptoGlobals）
    ...cryptoGlobals,
    MY_URL: ctx.url || '',
    MY_NAME: ctx.name || '',
    MY_PAGE: ctx.page || 1,
    MY_CATE: ctx.cateUrl || '',
    /// 页面类型（官方文档：`js: log(MY_TYPE)`，首页打印 home、搜索为 search）
    MY_TYPE: ctx.action === 'search' ? 'search'
      : (ctx.action === 'detail' ? 'detail' : 'home'),
    /// 分类名 / 分类地址（官方：「仅在首页且规则里写了替换词时可用」）
    MY_CLASS_NAME: ctx.cateName || '',
    MY_CLASS_URL: ctx.cateUrl || '',
    HIKER_NAME: ctx.name || '',
    MY_PARAMS: ctx.params || {},
    /// 当前规则原文（实测有源直接读它做判断）
    MY_RULE: ctx.rule || '',
    /// 源首页地址（实测有源用它拼相对地址 / 判域名）
    MY_HOME: ctx.homeUrl || '',
    /// 常用 UA 常量（实测有源直接用 `MOBILE_UA` / `PC_UA`）
    MOBILE_UA: UA_MOBILE,
    PC_UA: UA_PC,

    /// 源配置（海阔里用户可填的 `config`）—— 规则里 `config.host` 读的就是它。
    /// 没有配置时给个空对象，让 `config.x` 得到 undefined 而不是
    /// `config is not defined`（后者会让整条规则在模块加载期就炸掉）。
    config: ctx.config && typeof ctx.config === 'object' ? ctx.config : {},

    // ── 同步网络 ─────────────────────────────────────────
    fetch: (url, opts) => g(url, opts),
    req: (url, opts) => g(url, opts),
    // `request(url, opts)` 是同步抓取的老名字（实测有源在用）
    request: (url, opts) => g(url, opts),
    post: (url, body, opts) => post(url, body, opts),
    get: (url, opts) => g(url, opts),
    // WebView 抓页（Phase 2）：信号式同步 —— Node 里没有 WebView，
    // 抛 NeedWebView 交给宿主（Dart）去抓，再重放（见 webViewSync）
    fetchCodeByWebView: (input, opts) => webViewSync(rt, input, opts),
    lazyRule: (fn) => lazyRuleImpl(rt, ctx, fn),
    // 取网页源码：不传 url = 「当前页面」（`source.url`），老式规则全靠它
    getResCode: (url) => {
      const u = url || ctx.url;
      if (!u) {
        throw new Error(
          '规则调用了 getResCode()，但拿不到地址'
          + '（源的 url 为空，或依赖的 config 里没填对应项）',
        );
      }
      return g(u, { ua: ctx.ua });
    },
    // `getHome()` 在海阔里就是「取首页源码」，与 getResCode() 等价
    getHome: (url) => {
      const u = url || ctx.url;
      if (!u) {
        throw new Error(
          '规则调用了 getHome()，但拿不到地址'
          + '（源的 url 为空，或依赖的 config 里没填对应项 —— 去「海阔源管理 → 源配置」填）',
        );
      }
      return g(u, { ua: ctx.ua });
    },

    // ── 环境读取（老式 API）───────────────────────────────
    getUrl: () => ctx.url || '',
    getMyUrl: () => ctx.url || '',
    getPage: () => ctx.page || 1,
    getKeyword: () => String((ctx.params && ctx.params.keyword) || ''),
    getUa: () => ctx.ua || '',
    getVar: (k, def) => (rt.kv[k] != null ? rt.kv[k] : (def != null ? def : '')),
    setVar: (k, v) => { rt.kv[k] = v; rt.touchedVars = true; },
    putVar: (k, v) => { rt.kv[k] = v; rt.touchedVars = true; },
    clearVar: (k) => { delete rt.kv[k]; rt.touchedVars = true; },
    /// `setItem/getItem/clearItem`：文档说是"规则内持久存储"（值为字符串）。
    /// 我们这套 kv 本来就是"按规则隔离 + 落盘"，语义一致 ⇒ 同一份实现。
    setItem: (k, v) => { rt.kv[k] = v; rt.touchedVars = true; },
    clearItem: (k) => { delete rt.kv[k]; rt.touchedVars = true; },
    /// `storage0`：文档原话是"支持存储 JSON 对象"的同族接口
    ///（putMyVar/getMyVar/putVar/getVar/setItem/getItem/setPublicItem/getPublicItem）。
    /// 我们的 kv 本来就能存任意值 ⇒ 同一份实现，差别只在**不做字符串强转**。
    storage0: {
      putMyVar: (k, v) => { rt.kv[k] = v; rt.touchedVars = true; },
      setMyVar: (k, v) => { rt.kv[k] = v; rt.touchedVars = true; },
      getMyVar: (k, d) => (rt.kv[k] !== undefined ? rt.kv[k] : d),
      putVar: (k, v) => { rt.kv[k] = v; rt.touchedVars = true; },
      getVar: (k, d) => (rt.kv[k] !== undefined ? rt.kv[k] : d),
      setItem: (k, v) => { rt.kv[k] = v; rt.touchedVars = true; },
      getItem: (k, d) => (rt.kv[k] !== undefined ? rt.kv[k] : d),
      // 全局公开（对所有规则可见）⇒ 用 `@p:` 前缀隔离，避免和规则内变量撞名
      setPublicItem: (k, v) => { rt.kv[`@p:${k}`] = v; rt.touchedVars = true; },
      getPublicItem: (k, d) => (rt.kv[`@p:${k}`] !== undefined ? rt.kv[`@p:${k}`] : d),
    },
    joinUrl: (base, rel) => {
      try { return new URL(String(rel), String(base)).toString(); } catch (_) { return rel || ''; }
    },
    urlJoin: (base, rel) => {
      try { return new URL(String(rel), String(base)).toString(); } catch (_) { return rel || ''; }
    },
    getAbsoluteUrl: (rel) => {
      try { return new URL(String(rel), ctx.url).toString(); } catch (_) { return rel || ''; }
    },
    encodeUrl: (s) => encodeURIComponent(String(s)),
    decodeUrl: (s) => decodeURIComponent(String(s)),
    jsonParse: (s) => JSON.parse(s),
    parseJson: (s) => JSON.parse(s),
    jsonStringify: (o) => JSON.stringify(o),
    stringify: (o) => JSON.stringify(o),
    log: (...a) => console.log('[hiker]', ...a),
    print: (...a) => console.log('[hiker]', ...a),

    // ── 结果 ─────────────────────────────────────────────
    setResult: (r) => { state.result = r; },
    setHomeResult: (r) => { state.homeResult = r; },
    setNextPage: (r) => { state.nextPage = r == null ? '' : String(r); },
    setPageTitle: (r) => { state.pageTitle = r == null ? '' : String(r); },
    setError: (r) => { state.error = r == null ? '' : String(r); },
    clearPublicItem: () => {},
    showLoading: () => {},
    hideLoading: () => {},
    longToast: () => {},
    toast: () => {},

    // ── 事件 / 交互 ──────────────────────────────────────────────
    //   `confirm(...)` / `setInterval(...)` 建立在"页面有事件循环"之上，
    //   我们跑的是**一次性规则求值** ⇒ 安全占位（不让规则炸，也不产生假数据）。
    //   `addListener` 不同：它是真 API 且你能真用到，所以**收集起来回放**（见下）。
    // 事件回调：`addListener('onClose', $.toString(() => { 清变量 }))`
    //   海阔里由宿主持有、在**页面生命周期事件**时回放（官方 JSEngine 的
    //   `@JSAnnotation(alias="listen")` → `onFindCallBack.onUpdate(...)`）。
    //   我们是一次性求值 ⇒ 这里把回调**收集**起来随结果返回（result.listeners），
    //   宿主离开页面时再送回来执行（见 runHikerEvents / action:'event'）。
    addListener: (ev, fn) => {
      try {
        const key = String(ev == null ? '' : ev).trim();
        if (!key) return false;
        const code = typeof fn === 'function' ? fn.toString() : String(fn == null ? '' : fn);
        if (!code.trim()) return false;
        const list = state.listeners[key] || (state.listeners[key] = []);
        if (list.length < 8 && !list.includes(code)) list.push(code); // 限 8 条，防规则里循环注册
        return true;
      } catch (_) {
        return false;
      }
    },
    /// 页面刷新（宿主语义：重新拉一次当前页）—— 事件回调里出现时只是个标记，不在这里实现
    refreshPage: () => { state.needRefresh = true; return true; },
    setInterval: () => 0,
    clearInterval: () => {},
    /// `registerTask(id, time, callback)`（官方：注册定时任务）
    ///   —— 需要**常驻事件循环**，我们是一次性求值 ⇒ 安全占位（不让规则炸，
    ///      也不产生假数据；定时逻辑不会触发）
    registerTask: (id) => {
      warnOnce(`registerTask(${String(id).slice(0, 40)}) 不支持（需要常驻事件循环）`);
      return true;
    },
    confirm: () => true,

    // ── 文件存取（文档：`hiker://files/a.txt` = Documents 下 a.txt）────────
    //   路径一律经 safePath 收敛到 hiker 目录内（源是外来脚本，不能读写任意文件）
    readFile: (p) => {
      const s = String(p || '');
      // `hiker://page/x` 是**源内模块**而不是文件，仍走 hikerFetch
      if (/^hiker:\/\/page\//i.test(s)) return hikerFetch(rt, s);
      const t = readTextChecked(safePath(rt, s));
      if (t == null) throw new Error(`readFile('${s}') 读不到文件`);
      return t;
    },
    writeFile: (p, c) => writeTextFile(rt, p, c),
    saveFile: (p, c) => writeTextFile(rt, p, c),

    // ── 其余文档里明确过的 API ────────────────────────────
    /// 前段结果：文档说 `setPreResult` 与 `setResult` 必须**成对且先后固定**
    setPreResult: (r) => { state.preResult = r; },
    /// 当前规则原文（文档别名 `getRule`）
    getRule: () => ctx.rule || '',
    /// `setError` 的缩写（文档：error）
    error: (r) => { state.error = r == null ? '' : String(r); },
    /// `eval(getCryptoJS())` 之后就能用 `CryptoJS.enc.Utf8.parse(...)`：
    /// 我们**直接把 CryptoJS 挂到沙箱**，于是 eval('') 是空操作、CryptoJS 直接可用
    getCryptoJS: () => '',
    CryptoJS,

    // ── DOM 工具（老式 API）─────────────────────────────
    // 以下三个的语义**按海阔官方文档**（其源码 assets/help_js.json）：
    //   · `parseDom`（缩写 `pd`）          → 规则解析 **+ 自动补全链接**（默认基于 MY_URL）
    //   · `parseDomForHtml`（缩写 `pdfh`） → 同 parseDom，但**不**补域名/http 前缀
    //   · `parseDomForArray`（缩写 `pdfa`）→ 取**列表**，返回元素数组
    //   （我之前把 parseDom 当成 pdfh 的别名、把 pd 单独补链接 —— 与文档不符，已纠正）
    parseDom: (html, rule, base) =>
      absolutize(parseDomForHtmlStr(html, rule), base || ctx.url || ctx.homeUrl),
    pd: (html, rule, base) =>
      absolutize(parseDomForHtmlStr(html, rule), base || ctx.url || ctx.homeUrl),
    pdfh: (html, rule) => parseDomForHtmlStr(html, rule),
    parseDomForHtml: (html, rule) => parseDomForHtmlStr(html, rule),
    pdfa: (html, rule) => parseDomForArrayStr(html, rule),
    parseDomForArray: (html, rule) => parseDomForArrayStr(html, rule),
    parseDomForHtmlList: (html, rule) => {
      const $ = cheerio.load(String(html || ''));
      const r = resolveRule($, rule);
      const out = [];
      if (r.nodes && r.nodes.length) {
        r.nodes.each((_, el) => { out.push(valueOfNode($, el, r.value)); });
      }
      return out;
    },

    // ── 变量 / 参数 ──────────────────────────────────────
    getParam: (k) => {
      const p = ctx.params || {};
      return p[k] != null ? String(p[k]) : '';
    },
    getMyVar: (k, def) => (rt.kv[k] != null ? rt.kv[k] : (def != null ? def : '')),
    putMyVar: (k, v) => { rt.kv[k] = v; rt.touchedVars = true; },
    setMyVar: (k, v) => { rt.kv[k] = v; rt.touchedVars = true; },
    delMyVar: (k) => { delete rt.kv[k]; rt.touchedVars = true; },
    listMyVarKeys: () => Object.keys(rt.kv),
    clearMyVar: (k) => {
      if (k == null) {
        rt.kv = {};
      } else {
        delete rt.kv[k];
      }
      rt.touchedVars = true;
    },
    // `getItem(k, def)`：实测读的是"带默认值的配置项"，与 getMyVar 同形
    getItem: (k, def) => (rt.kv[k] != null ? rt.kv[k] : (def != null ? def : '')),

    // ── 上级页面 / 模块 ─────────────────────────────────
    // 出口统一过 [normalizeModuleValue]：补 `.default`、取不到值就明确报错
    // （见其注释：`$.require('x').default` 是常见写法，返回 undefined 会变成
    //  一句没有线索的 "Cannot read properties of undefined (reading 'default')"）
    require: (name) => normalizeModuleValue(requireModule(name), name),
    // 海阔的「执行私有 JS」：多数源里它就等价于 require（同名页面模块），
    // 找不到时再退回源自己的 `private_js` 字段。
    evalPrivateJS: (name) => evalPrivateJS(name),
    $: Object.assign(jQueryLike, {
      get: (url, opts) => g(url, opts),
      post: (url, body, opts) => post(url, body, opts),
      ajax: (o) => {
        const oo = o || {};
        return g(oo.url, {
          method: oo.type || oo.method || 'get',
          body: oo.data,
          headers: oo.headers,
          charset: oo.charset,
        });
      },
      fetch: (url, opts) => g(url, opts),
      fetchCodeByWebView: (input, opts) => webViewSync(rt, input, opts),
      lazyRule: (fn) => lazyRuleImpl(rt, ctx, fn),
      html: (h) => jq(cheerio.load(String(h || ''))),
      md5: (s) => CryptoJS.MD5(String(s)).toString(),
      sha1: (s) => CryptoJS.SHA1(String(s)).toString(),
      base64: (s) => Buffer.from(String(s), 'utf8').toString('base64'),
      atob: (s) => Buffer.from(String(s), 'base64').toString('binary'),
      btoa: (s) => Buffer.from(String(s)).toString('base64'),
      // ⚠️ 函数要返回**源码**：源里 `addListener('onClose', $.toString(() => {…}))`
      //   就是靠它把回调变成字符串存给宿主；原来直接 JSON.stringify(fn) === undefined
      //   ⇒ 回调被静默丢弃（addListener 收到 undefined 就什么也不登记）。
      toString: (o) => {
        if (typeof o === 'function') return o.toString();
        return typeof o === 'string' ? o : JSON.stringify(o);
      },
      stringify: (o) => JSON.stringify(o),
      parseJson: (s) => JSON.parse(s),
      // 官方文档里的**裸函数**（`a&&href.js:base64Decode(input)`、
      // `fetch(base64Decode(MY_PARAMS.u))`）——实测 MissAV / 道长仓库Pro 用到
      base64Encode: (s) => Buffer.from(String(s == null ? '' : s), 'utf8').toString('base64'),
      base64Decode: (s) => Buffer.from(String(s == null ? '' : s), 'base64').toString('utf8'),
      require: (name) => normalizeModuleValue(requireModule(name), name),
      /// 模块导出约定：`$.exports = xxx;`（CommonJS 风格）
      /// —— 海阔的源页面模块就是这么把值交出去的（`main` / `xiu` 等模块名
      ///    与内部变量名常常不一致，只能靠 exports 取），见 [runInModuleScope]
      exports: undefined,
      // `rc(url, hours)` / `requireCache(...)`：**远端 JS 依赖**（官方别名 rc）
      //   文档：`requireCache('http://xxx/t.js', 24)` → 缓存 24 小时，超过重新下载。
      //   实现：本地缓存 `<filesDir>/libs/<md5(url)>.js`；缓存未过期直接 eval，
      //   过期/缺失则走**重放桥**抓一次（httpSync）再落盘 eval。
      requireCache: (url, hours) => requireRemoteJs(rt, sandbox, url, hours),
      rc: (url, hours) => requireRemoteJs(rt, sandbox, url, hours),
      evalPrivateJS: (name) => evalPrivateJS(name),
    }),
  };
  sandbox.globalThis = sandbox;
  sandbox.window = sandbox;
  return sandbox;
}

// ============================================================
// 主流程
// ============================================================

function stripJsPrefix(rule) {
  const s = String(rule || '').trim();
  return s.startsWith('js:') ? s.slice(3) : s;
}

/**
 * 跑一条规则；返回 `{list, playUrl, nextPage, pageTitle, vars}`。
 *
 * @param {object} source  源（含 `pages` 内联模块）
 * @param {object} ctx     `{url, name, page, cateUrl, params, ua, rule}`
 * @param {object} kv      持久化变量（会被回写）
 */
export async function runHikerRule(source, ctx, kv, opts = {}) {
  const rawRule = String(ctx.rule || '');
  const rule = stripJsPrefix(rawRule);
  if (!rule) return { list: [], playUrl: '', nextPage: '', pageTitle: '', vars: kv || {} };

  // ⚠️ 限制值一律**局部化 + 兜底**（见 [_limit]）：模块级常量一旦在产物里绑定
  //    丢失，`attempt < undefined` 会让重放循环一次都不跑 ⇒ 全部规则秒失败。
  const budgetMs = _limit(opts.timeoutMs || TOTAL_BUDGET_MS, 45000);
  const maxItems = _limit(opts.maxItems || MAX_ITEMS, 300);
  const maxReplay = _limit(MAX_REPLAY, 40);

  const rt = newRuntime(ctx, kv);

  // 内联页面模块索引：`$.require('miss')` / `$.require('hiker://page/miss')` /
  // `request('hiker://page/miss')` / 裸 `require(...)` 都查这张表。
  // ⚠️ 必须在**二级规则之前**建好：二级规则路径也会走 httpSync，
  //   而 `hiker://page|assets/...` 现在由 httpSync 直接当宿 host 资源返回。
  const modules = new Map();
  for (const p of (source && Array.isArray(source.pages)) ? source.pages : []) {
    if (!p || typeof p !== 'object') continue;
    for (const rawKey of [p.name, p.path]) {
      if (!rawKey) continue;
      const k = String(rawKey);
      modules.set(k, p);
      const base = k.split('/').pop() || '';
      if (base) {
        modules.set(base, p);
        if (/\.js$/i.test(base)) modules.set(base.replace(/\.js$/i, ''), p);
      }
    }
  }
  rt.modules = modules;

  // ── 二级规则（不是 `js:` 的老式写法：`容器; 标题; 链接; 图片; 描述`）──────
  //   实测 `吾爱破解𝔥` 这类源的 searchFind / detail_find_rule 就是它。
  //   它不需要 JS 沙箱：直接抓当前页面然后用选择器 DSL 按位置取值。
  const isJsRule = /^js:/i.test(rawRule.trim());
  if (!isJsRule && rule.includes(';')) {
    let list = [];
    for (let attempt = 0; attempt < maxReplay; attempt++) {
      try {
        const html = httpSync(rt, ctx.url, { ua: ctx.ua });
        list = runSecondaryRule(html, rule, source && source.col_type, maxItems);
        return {
          list,
          playUrl: list.length === 1 && list[0].url ? list[0].url : '',
          nextPage: '',
          pageTitle: '',
          vars: rt.kv,
          requests: 1,
          lazyIds: [],
        };
      } catch (e) {
        if (e instanceof NeedFetch) {
          rt.cache.set(e.key, await doHttp(rt, e.url, e.opts));
          continue; // 抓到页面后重放
        }
        throw e;
      }
    }
    throw new Error('二级规则抓页重放次数超限');
  }

  const pending = []; // 已抓到的（url,key）→ 供调试
  // 整条规则的**总预算**：重放桥最坏情况是「未命中 URL 数 + 1」次执行 ×N 次请求，
  // 没有总闸门的话坏规则会一直重放（前端只看到转圈）。
  const deadline = Date.now() + budgetMs;

  // 内联页面模块：`$.require('miss')` / `$.require('hiker://page/miss')` / 裸 `require(...)`
  // （索引已在上面建好，并挂在 rt.modules 上给 httpSync 用）

  for (let attempt = 0; attempt < maxReplay; attempt++) {
    if (Date.now() > deadline) {
      throw new Error(
        `规则执行超时（${Math.round(budgetMs / 1000)}s，已发起 ${pending.length} 次请求）`
        + ' —— 该规则可能要抓太多网页，或地址依赖响应内容（Phase 1 不支持）',
      );
    }
    // 每轮复位"被吞掉的抓页意图"（由 httpSync / webViewSync 记录，见下面那道闸门）
    rt.wantFetch = null;
    const state = {
      result: undefined,
      homeResult: undefined,
      error: null,
      nextPage: '',
      pageTitle: '',
      /// setPreResult 的"前段结果"（文档：先返回上半屏、发完请求再补下半屏）
      preResult: undefined,
      /// `addListener(event, code)` 收集到的回调（随结果返回给宿主，见 runHikerEvents）
      listeners: {},
      /// 事件回调里调过 refreshPage()（宿主可据此重拉当前页）
      needRefresh: false,
    };
    const moduleCache = new Map();
    /// 正在加载中的模块（防**自引用 / 循环依赖**把栈打爆 —— 实测有源如此，
    /// 原来报的是 `Maximum call stack size exceeded`，看不出所以然）
    const moduleLoading = new Set();

    /** 造一个"模块级错误"：再往外层套 require 时**原样透传**、不再包一层 */
    const moduleError = (msg) => {
      const e = new Error(msg);
      e.__hikerModuleError = true;
      return e;
    };

    const requireModule = (name) => {
      const cands = moduleCandidates(name);
      const cacheKey = cands[0] || String(name || '');
      if (moduleCache.has(cacheKey)) return moduleCache.get(cacheKey);

      if (cands.length === 0) {
        // 实测：`require(config.依赖)` 在没填源配置时就是这个样子
        throw moduleError(
          'require() 拿到了空名字 —— 通常是 `config.xxx` 没填'
          + '（去「海阔源管理 → 源配置」补上）',
        );
      }

      let mod = null;
      let key = '';
      for (const c of cands) {
        const m = modules.get(c);
        if (m) {
          mod = m;
          key = c;
          break;
        }
      }
      if (!mod) {
        // 内置模块：`$.require('aes?rule=<源名>')` 在官方里指向 App 自带的
        // `assets/aes.js`（CryptoJS + AES/Data 封装）。我们不内置那个 191KB 副本，
        // 直接返回**等价的实现**（见 buildCryptoGlobals）。
        const bare = String(cands[0] || '').replace(/\.js$/i, '').toLowerCase();
        if (bare === 'aes' || bare === 'crypto' || bare === 'cryptojs') {
          const cg = buildCryptoGlobals();
          return {
            ...cg,
            CryptoJS,
            MD5: CryptoJS.MD5,
            SHA256: CryptoJS.SHA256,
            SHA1: CryptoJS.SHA1,
            Base64: CryptoJS.enc.Base64,
            Hex: CryptoJS.enc.Hex,
            Utf8: CryptoJS.enc.Utf8,
          };
        }
        throw moduleError(
          `$.require('${String(name || '')}') 找不到对应的 pages 模块`
          + '（该源依赖海阔内置页面模块 / 宿主文件，暂不支持）',
        );
      }
      let value;
      let modErr = null;
      if (moduleLoading.has(cacheKey)) {
        throw moduleError(
          `模块「${cacheKey}」存在**自引用/循环依赖**，无法加载`
          + '（海阔里这类源通常配合它的内置模块使用，暂不支持）',
        );
      }
      moduleLoading.add(cacheKey);
      try {
        // 模块语义见 [runInModuleScope]：独立函数作用域 + 顶层名字回填沙箱
        //  ⚠️ 整个执行（含调用）都在 runInContext 里，SCRIPT_TIMEOUT_MS 才管得住死循环
        value = runInModuleScope(sandbox, mod.rule, key);
      } catch (e) {
        // 🔴 `NeedFetch` / `NeedWebView` 是**重放桥的信号**，绝不能在这里被吞掉 ——
        //   模块顶层很常见就要抓网页（如 `host: getHome(config.host)`），
        //   吞掉它会让重放循环永远拿不到"该抓哪个 URL"，规则直接失效。
        if (e instanceof NeedFetch || e instanceof NeedWebView) throw e;
        modErr = e;
        value = undefined;
      }
      // 加载结束（成功或失败）都放开"加载中"标记；重放桥的信号直接抛出时
      // 整趟会重来，moduleLoading 也会随之重建，不需要额外清理。
      moduleLoading.delete(cacheKey);
      if (value === undefined && modErr) {
        // 已经是"模块级错误"就**原样抛出**：否则每套一层 require 就再包一层，
        // 实测会滚成"加载源内模块「hxc」失败：加载源内模块「hxc」失败：…"的递归长串。
        if (modErr && modErr.__hikerModuleError) throw modErr;
        throw moduleError(
          `加载源内模块「${key}」失败：${describeError(modErr)}`
          + '（模块里用到了当前不支持的海阔 API，例如 pdfa 播放地址解析）',
        );
      }
      moduleCache.set(cacheKey, value);
      return value;
    };

    /**
     * `evalPrivateJS(name)`：海阔的"执行私有 JS"。
     * 多数源里它就等价于 require 同名页面模块；找不到时再退回源自己的
     * `private_js` 字段（如果有）。
     */
    const evalPrivateJS = (name) => {
      const key = String(name || '').trim();
      if (!key) throw new Error('evalPrivateJS() 需要一个名字');
      try {
        return requireModule(key);
      } catch (e) {
        if (e instanceof NeedFetch || e instanceof NeedWebView) throw e;
        const pj = source && (source.private_js || source.privateJs);
        if (typeof pj === 'string' && pj.trim()) {
          return vm.runInContext(stripJsPrefix(pj), sandbox, { timeout: SCRIPT_TIMEOUT_MS });
        }
        throw e;
      }
    };

    const sandbox = vm.createContext(buildSandbox(rt, state, requireModule, evalPrivateJS));

    try {
      // 不包 IIFE：保持海阔「顶层 var/const/function 即全局」的语义
      new vm.Script(rule, { filename: 'hiker_rule.js' })
        .runInContext(sandbox, { timeout: SCRIPT_TIMEOUT_MS });
    } catch (e) {
      if (e instanceof NeedFetch) {
        const body = await doHttp(rt, e.url, e.opts);
        rt.cache.set(e.key, body);
        pending.push(e.url);
        continue; // 重放
      }
      if (e instanceof NeedWebView) {
        // 交给宿主（Dart）用真 WebView 抓；拿不到桥就明确报错，别静默返回空
        if (typeof opts.fetchWebView !== 'function') {
          throw new Error(
            '规则需要 WebView 抓页（fetchCodeByWebView），但当前没有 WebView 桥'
            + '（宿主未就绪）',
          );
        }
        const html = await opts.fetchWebView(e.url, e.opts);
        rt.cache.set(e.key, html == null ? '' : String(html));
        pending.push(`webview:${e.url}`);
        continue; // 重放
      }
      // ⚠️ 「X is not defined」这类错误**故意不做预加载**：曾试过"把定义了 X 的
      //  pages 模块预先铺进沙箱"，但实测**净效果为负**（重型模块顶层就抓页，
      //  预加载会引入额外请求把一个原本可用的源拖坏：47 → 46）。既然没有收益，
      //  就不留这套机制 —— 这类源需要的是它自己的 Apollo/规则包（属内容缺失）。
      throw e;
    }

    // ── 被规则吞掉的抓页信号（用户 2026-10-15 实测）──────────────────────
    // 规则里常写成 `try { var html = fetch(url) } catch (e) { html = '' }`：
    // NeedFetch 会被**规则自己的 try/catch 吞掉** ⇒ 引擎以为"这轮正常跑完了"，
    // 于是拿着一个**空结果**就返回 —— 实测 `ok:true / list:[] / requests:0 / 3ms`，
    // 用户看到的现象就是"脚本不显示内容"（不报错、也不重试）。
    //
    // 这里补一道闸门：本轮记下的"想要的页面"若还没抓到，就先抓、再重放一轮
    //（这一轮的（空）结果作废）。抓完即进缓存 ⇒ 下一轮 httpSync 直接命中、
    // 不会再记新的 want ⇒ 与既有重放桥一样收敛，不会空转。
    if (rt.wantFetch) {
      const w = rt.wantFetch;
      rt.wantFetch = null;
      if (w.webview) {
        if (typeof opts.fetchWebView !== 'function') {
          throw new Error(
            '规则需要 WebView 抓页（fetchCodeByWebView），但当前没有 WebView 桥'
            + '（宿主未就绪）',
          );
        }
        const html = await opts.fetchWebView(w.url, w.opts);
        rt.cache.set(w.key, html == null ? '' : String(html));
        pending.push(`webview:${w.url}`);
      } else {
        const body = await doHttp(rt, w.url, w.opts);
        rt.cache.set(w.key, body);
        pending.push(w.url);
      }
      continue; // 重放：让规则拿到真页面
    }

    if (state.error) throw new Error(String(state.error));
    const raw = state.homeResult !== undefined ? state.homeResult : state.result;
    let list = extractItems(raw, source && source.col_type, maxItems);
    // setPreResult 的"前段结果"要**排在前面**（文档：先返回上半屏、后面再追加）
    if (state.preResult !== undefined && state.preResult !== null) {
      const pre = extractItems(state.preResult, source && source.col_type, maxItems);
      if (pre.length) list = [...pre, ...list].slice(0, maxItems || MAX_ITEMS);
    }
    // 详情规则常见写法：只 setResult 一条（或直接 setResult('播放地址')）
    let playUrl = '';
    if (typeof raw === 'string') {
      const s = raw.trim();
      if (/^https?:\/\//i.test(s) || s.startsWith('x5://')) {
        playUrl = s.startsWith('x5://') ? s.slice(5) : s;
      }
    }
    if (!playUrl && list.length === 1 && list[0].url) playUrl = list[0].url;
    return {
      list,
      playUrl,
      nextPage: state.nextPage || '',
      pageTitle: state.pageTitle || '',
      vars: rt.kv,
      requests: pending.length,
      lazyIds: [...rt.lazyIds],
      listeners: state.listeners || {},
      needRefresh: state.needRefresh === true,
    };
  }
  // 走到这里 = MAX_REPLAY 轮都没收敛。把**能直接定位**的信息带上：
  // 原来只有一句「该脚本的请求地址依赖响应内容」，既看不出是脚本的问题还是引擎的问题，
  // 也看不到它到底在请求什么（用户 2026-10-15 反馈的不明报错）。
  //   去重地址数 == 请求次数 ⇒ 每轮都在请求**新地址**：脚本用了随机数/时间戳，
  //                            或在沿「下一页」链式爬，40 层不够；
  //   去重地址数 <  请求次数 ⇒ 同一地址反复未命中缓存：是引擎侧的问题，要反馈。
  const uniqUrls = new Set(pending).size;
  const tail = pending.slice(-3).map((u) => String(u).slice(0, 120)).join(' | ');
  throw new Error(
    `规则重放次数超过上限（${maxReplay} 轮，共 ${pending.length} 次请求，`
    + `其中不同地址 ${uniqUrls} 个）—— 该脚本的请求地址依赖响应内容，Phase 1 暂不支持。`
    + (uniqUrls === pending.length
      ? '原因：每轮请求的地址都不同（脚本可能用了随机数/时间戳，或沿链接链式翻页）。'
      : '原因：有地址被重复请求且始终未命中缓存（疑似引擎问题，请反馈）。')
    + (tail ? ` 最近的请求：${tail}` : ''),
  );
}

/**
 * 执行**页面事件回调**（`addListener('onClose', …)` 登记下来的那批）。
 *
 * 海阔里这些回调由宿主持有、在页面生命周期事件（关闭 / 刷新）时由原生回放；
 * 我们是一次性求值 ⇒ 规则把回调随结果返回（result.listeners），宿主**离开页面**
 * 时送回来，在这里用**同一份 vars 上下文**执行 —— 于是"关页面时清变量/清缓存"
 * 这类逻辑能真正生效（实测 115 个源里 13 个源用到，几乎都是 onClose 清理）。
 *
 * 两种形态都吃：
 *   · `() => { … }`（`$.toString(fn)` 的结果）→ 当表达式求值后**调用**
 *   · `refreshPage()` 这类语句串 → 当表达式求值（已执行）；语法不合法时按语句执行
 */
export async function runHikerEvents(source, ctx, kv, codes) {
  const list = Array.isArray(codes)
    ? codes.map((c) => String(c)).filter((c) => c.trim())
    : [];
  if (!list.length) return { vars: kv || {}, ran: 0 };
  const rt = newRuntime(ctx || {}, kv || {});
  const state = {
    result: undefined,
    homeResult: undefined,
    error: null,
    nextPage: '',
    pageTitle: '',
    preResult: undefined,
    listeners: {},
    needRefresh: false,
  };
  // 清理逻辑里通常不需要 require；真要用了给明确原因，而不是静默 undefined
  const noRequire = () => {
    throw new Error('事件回调里不支持 $.require（页面关闭时的清理逻辑一般用不到）');
  };
  const sandbox = vm.createContext(buildSandbox(rt, state, noRequire, noRequire));
  let ran = 0;
  let error = '';
  for (const code of list) {
    try {
      let value;
      let exprOk = true;
      try {
        value = vm.runInContext(`(${code})`, sandbox, { timeout: SCRIPT_TIMEOUT_MS });
      } catch (_) {
        exprOk = false; // 语句串（带 ; 的多行）当表达式不合法 → 退回当脚本执行
      }
      if (!exprOk) {
        vm.runInContext(code, sandbox, { timeout: SCRIPT_TIMEOUT_MS });
      } else if (typeof value === 'function') {
        value();
      }
      ran++;
    } catch (e) {
      error = describeError(e);
      console.warn('[hiker] 事件回调执行失败:', error);
    }
  }
  return { vars: rt.kv, ran, error, needRefresh: state.needRefresh === true };
}

/** `detail_find_rule` / 播放地址解析 */
export async function runHikerDetail(source, ctx, kv) {
  const rule = stripJsPrefix(ctx.rule);
  if (!rule) return { playUrl: '', list: [], vars: kv || {} };
  const r = await runHikerRule(source, { ...ctx, rule }, kv);
  return { playUrl: r.playUrl || '', list: r.list, vars: r.vars };
}

// ============================================================
// 规则 URL 解析（`**`=关键词 / `fypage`=页码 / `;get;UTF-8;{UA@..}`）
// ============================================================

/**
 * URL 字段里的 `.js:` 规则（实测 18AV 那组"动态域名"源就是这么写的）：
 *   `https://{host}/zh/xx/fypage.html.js:input.replace('https://{host}', getVar('18AV'))`
 * 语义：`<base>.js:<code>`，code 里 `input` 是 base，**返回值**就是真正的地址。
 * 典型用途：域名不固定，靠变量（`getVar`）在运行时拼出来。
 */
function evalUrlRule(rawUrl, kv) {
  const s = String(rawUrl || '');
  const i = s.lastIndexOf('.js:');
  if (i < 0) return s;
  const base = s.slice(0, i);
  const code = s.slice(i + 4);
  if (!code.trim()) return base;
  const store = kv && typeof kv === 'object' ? kv : {};
  let out;
  try {
    const box = {
      input: base,
      getVar: (k, d) => (store[k] != null ? store[k] : (d != null ? d : '')),
      getMyVar: (k, d) => (store[k] != null ? store[k] : (d != null ? d : '')),
      putMyVar: (k, v) => { store[k] = v; },
      setMyVar: (k, v) => { store[k] = v; },
      String, Number, JSON, Math, Date, RegExp,
      encodeURIComponent, decodeURIComponent, console,
    };
    box.globalThis = box;
    const ctx = vm.createContext(box);
    out = new vm.Script(code, { filename: 'hiker_url.js' })
      .runInContext(ctx, { timeout: 2000 });
  } catch (e) {
    throw new Error(
      `URL 规则执行失败（${code.slice(0, 60)}…）：${describeError(e)}`,
    );
  }
  const result = out == null ? base : String(out);
  // 校验：动态域名没填时这里会算出 `https:///xx` 这种没有 host 的地址 ——
  // 提前给一句人能看懂的话，而不是让 axios 报一句莫名其妙的错。
  if (!/^https?:\/\/[^/\s]+/i.test(result)) {
    throw new Error(
      `URL 规则算不出有效地址：「${result.slice(0, 80)}」`
      + '（这种"动态域名"源需要在源变量里填域名，例如 getVar(\'18AV\')）',
    );
  }
  return result;
}

/** 把相对路径补成绝对地址（实测 9 个源的 `search_url` 写的是 `/search?q=**`） */
function absolutize(u, base) {
  const s = String(u || '');
  if (!s || /^https?:\/\//i.test(s) || /^hiker:\/\//i.test(s)) return s;
  const b = String(base || '');
  if (!/^https?:\/\//i.test(b)) return s;
  try {
    return new URL(s, b).toString();
  } catch (_) {
    return s;
  }
}

function parseRuleUrl(raw, opt) {
  const o = opt || {};
  const keyword = o.keyword != null ? String(o.keyword) : '';
  const page = o.page || 1;
  let s = String(raw || '').trim();

  // `[firstPage=xxx]`：第一页用另一条地址
  const fp = /\[firstPage=([^\]]*)\]/i.exec(s);
  if (fp) {
    if (page <= 1) s = fp[1];
    else s = s.replace(fp[0], '');
  }

  const parts = s.split(';');
  const urlPart = (parts[0] || '').trim();
  const method = ((parts[1] || 'get').trim() || 'get');
  const charset = (parts[2] || '').trim();
  const headerRaw = parts.slice(3).join(';').trim();

  const headers = {};
  if (headerRaw) {
    const m = /\{([\s\S]*)\}/.exec(headerRaw);
    const body = m ? m[1] : headerRaw;
    for (const line of body.split(/[\n,]/)) {
      const t = line.trim();
      if (!t) continue;
      const i = t.search(/[@:]/);
      if (i <= 0) continue;
      headers[t.slice(0, i).trim()] = t.slice(i + 1).trim();
    }
  }

  const subs = (x) => String(x)
    .replace(/\*\*/g, encodeURIComponent(keyword))
    .replace(/fypage/g, String(page));

  const params = {};
  let url = subs(urlPart);
  if (url.startsWith('hiker://')) {
    const q = url.indexOf('?');
    if (q >= 0) {
      for (const kv of url.slice(q + 1).split('&')) {
        const i = kv.indexOf('=');
        if (i > 0) {
          params[decodeURIComponent(kv.slice(0, i))] = subs(decodeURIComponent(kv.slice(i + 1)));
        }
      }
    }
    const hashSegs = url.split('##').slice(1);
    if (hashSegs.length) params.hiker_hash = hashSegs.map(subs).join('##');
    url = '';
  } else if (url) {
    // ① URL 字段可能带 `.js:` 规则（动态域名）→ 先求值出真地址
    url = evalUrlRule(url, o.kv);
    // ② 相对路径 → 用源的 url 补成绝对地址
    //    （实测 9 个源的 search_url 写的是 `/search?q=**&page=fypage`）
    url = absolutize(url, o.base);
  }
  return { url, method, charset, headers, params };
}

function normalizePages(source) {
  let p = source.pages;
  if (typeof p === 'string') {
    try {
      p = JSON.parse(p);
    } catch (_) {
      p = [];
    }
  }
  source.pages = Array.isArray(p) ? p : [];
  return source;
}

/**
 * 源配置 `config`。
 *
 * 海阔里 `config` 是**用户可填**的源参数（规则里 `config.host` / `config.依赖`
 * 读的就是它）。导出/导入时它可能以字符串（JSON 文本）或对象两种形态出现，
 * 这里统一成对象；调用方也可以显式传 `config` 覆盖（Dart 侧的「源配置」编辑）。
 */
function normalizeConfig(v) {
  if (v && typeof v === 'object') return { ...v };
  if (typeof v === 'string' && v.trim()) {
    try {
      const j = JSON.parse(v);
      if (j && typeof j === 'object') return j;
    } catch (_) { /* 坏数据当空 */ }
  }
  return {};
}

// ============================================================
// 宿主桥（Node → Dart）：让 App 用**真 WebView** 抓页
// ============================================================

/**
 * 宿主的回环端口与 token。
 *
 * Node 是被 App 启动的，argv 里带着 `--native-port` / `--native-token`
 * （Dart 侧 `NodeJSManager` 在回环端口上跑着一个带 token 鉴权的 HttpServer，
 *  Node → Dart 的所有回调都走它）。
 */
function hostBridge() {
  const argv = process.argv || [];
  const pi = argv.indexOf('--native-port');
  const ti = argv.indexOf('--native-token');
  const port = pi !== -1 ? (parseInt(argv[pi + 1], 10) || 0) : 0;
  const token = ti !== -1 ? String(argv[ti + 1] || '') : '';
  return { port, token };
}

/** 让 Dart 侧用真 WebView 打开 url，回传 DOM（或 checkJs 的结果） */
async function fetchViaHostWebView(url, wopts) {
  const { port, token } = hostBridge();
  if (!port) {
    throw new Error('WebView 桥不可用：Node 启动参数里没有 --native-port');
  }
  const timeoutMs = Math.max(3000, Math.min(60000,
    Number(wopts && wopts.timeout) || HTTP_TIMEOUT_MS));
  const resp = await axios.post(
    `http://127.0.0.1:${port}/hiker/webview`,
    {
      url,
      timeoutMs,
      checkJs: (wopts && wopts.checkJs) || '',
      headers: (wopts && wopts.headers) || {},
    },
    {
      // 宿主侧会等页面 JS 跑完，这里比它多留 5s 余量
      timeout: timeoutMs + 5000,
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { 'x-auth-token': token } : {}),
      },
      validateStatus: () => true,
      responseType: 'json',
    },
  );
  const d = (resp && resp.data) || {};
  if (resp.status !== 200 || d.ok !== true) {
    throw new Error(`WebView 抓页失败：${d.error || `HTTP ${resp.status}`}`);
  }
  return d.html == null ? '' : String(d.html);
}

// ============================================================
// HTTP 接口入口
// ============================================================

/**
 * `/hiker/run` 的处理入口。
 *
 * 入参：`{ action:'home'|'search'|'detail', source:{...}, params:{...}, vars:{...} }`
 * 出参：`{ ok, list, playUrl, nextPage, pageTitle, vars, error }`
 */
export async function handleHikerApi(data) {
  const d = data || {};
  const action = String(d.action || 'home');
  const source = normalizePages(d.source && typeof d.source === 'object' ? { ...d.source } : {});
  const params = d.params && typeof d.params === 'object' ? d.params : {};
  const kv = d.vars && typeof d.vars === 'object' ? d.vars : {};
  // 源配置：调用方显式传的优先，否则用源自带的
  const cfg = d.config && typeof d.config === 'object'
    ? { ...d.config }
    : normalizeConfig(source.config);
  // 引擎参数（Dart 侧「海阔设置」可调）
  const rawOpts = d.options && typeof d.options === 'object' ? d.options : {};
  const opts = {
    timeoutMs: Math.max(5000, Math.min(180000, Number(rawOpts.timeoutMs) || TOTAL_BUDGET_MS)),
    maxItems: Math.max(1, Math.min(1000, Number(rawOpts.maxItems) || MAX_ITEMS)),
    // 文件系统根（Dart 侧传入，见 lib/hiker/services/hiker_builtin.dart）：
    //   filesDir  → `hiker://files/*`（Documents/hiker/files，规则可读写）
    //   assetsDir → `hiker://assets/*`（App 自带资源，Documents/hiker/builtin）
    filesDir: String(rawOpts.filesDir || ''),
    assetsDir: String(rawOpts.assetsDir || ''),
  };
  const t0 = Date.now();

  try {
    let rule = '';
    let ctxUrl = '';
    let envParams = { ...params };
    let ua = resolveUa(source.ua);
    // 源的首页地址：既可能是普通 URL，也可能带 `.js:` 规则（动态域名）。
    // 相对路径的 `search_url` 要用它做 base 来补全。
    let homeBase = String(source.url || '');
    try {
      homeBase = evalUrlRule(homeBase, kv);
    } catch (_) {/* base 求不出来不影响其它分支，交给各自的错误提示 */}

    if (action === 'event') {
      // 页面生命周期事件：执行 `addListener(event, code)` 登记下来的回调
      //   body: { action:'event', source:{...}, codes:['() => {…}', …], vars:{...} }
      //   —— 宿主在**离开页面**时调用（见 runHikerEvents）
      const r = await runHikerEvents(
        source,
        {
          url: String(params.url || source.url || ''),
          name: source.title || source.name || '',
          rule: '',
          page: 1,
          params,
          ua,
          config: cfg,
          homeUrl: homeBase,
          filesDir: opts.filesDir,
          assetsDir: opts.assetsDir,
        },
        kv,
        d.codes,
      );
      return {
        ok: true, list: [], playUrl: '', nextPage: '', pageTitle: '',
        vars: r.vars || kv, requests: 0, ranEvents: r.ran || 0,
        eventError: r.error || '', needRefresh: r.needRefresh === true,
        elapsedMs: Date.now() - t0,
      };
    }

    if (action === 'search') {
      const r = parseRuleUrl(source.search_url || source.searchUrl || '', {
        keyword: params.keyword,
        page: params.page || 1,
        kv,
        base: homeBase,
      });
      rule = String(source.searchFind || source.search_find || '');
      ctxUrl = r.url;
      envParams = { ...r.params, ...envParams };
      if (r.headers && r.headers['User-Agent']) ua = r.headers['User-Agent'];
    } else if (action === 'detail') {
      rule = String(source.detail_find_rule || source.detailFind || '');
      ctxUrl = String(params.url || '');
    } else {
      // home / category：`source.url` 是首页地址；分类走传入的 class_url
      const r = parseRuleUrl(params.url || source.url || '', {
        page: params.page || 1,
        kv,
        base: homeBase,
      });
      rule = String(source.find_rule || source.findRule || '');
      ctxUrl = params.url ? ctxUrl : (r.url || '');
      if (!ctxUrl) ctxUrl = r.url || '';
      envParams = { ...r.params, ...envParams };
    }

    if (!rule) {
      // 没有规则：把传入的 url 当播放地址（很多源的列表项本身就是直链/播放页）
      let playUrl = ctxUrl;
      if (playUrl.startsWith('x5://')) playUrl = playUrl.slice(5);
      return {
        ok: true, list: [], playUrl, nextPage: '', pageTitle: '',
        vars: kv, requests: 0, elapsedMs: Date.now() - t0,
      };
    }

    const env = {
      url: ctxUrl,
      name: source.title || source.name || '',
      page: params.page || 1,
      cateUrl: params.cateUrl || '',
      /// 分类名（宿主传入；规则里 `MY_CLASS_NAME` 读它）
      cateName: params.cateName || '',
      /// 本次动作（`MY_TYPE` 用它：home/search/detail）
      action,
      params: envParams,
      ua,
      config: cfg,
      homeUrl: homeBase,
      rule,
      // 延迟规则的第二趟：宿主拿着第一趟返回的 `hiker://lazy#<id>` 再来一次
      lazyId: params.lazyId ? String(params.lazyId) : '',
      // 文件系统根（Dart 侧传入）：
      //   filesDir  → `hiker://files/*`（= Documents 下的 hiker/files）
      //   assetsDir → `hiker://assets/*`（海阔 App 自带资源，我们内置一份）
      filesDir: opts.filesDir || '',
      assetsDir: opts.assetsDir || '',
    };
    const r = await runHikerRule(source, env, kv, {
      ...opts,
      fetchWebView: fetchViaHostWebView,
    });
    return {
      ok: true,
      list: r.list || [],
      playUrl: r.playUrl || '',
      nextPage: r.nextPage || '',
      pageTitle: r.pageTitle || '',
      vars: r.vars || kv,
      requests: r.requests || 0,
      lazyIds: r.lazyIds || [],
      /// `addListener(event, code)` 登记的回调（宿主离开页面时回放，见 action:'event'）
      listeners: r.listeners || {},
      needRefresh: r.needRefresh === true,
      elapsedMs: Date.now() - t0,
    };
  } catch (e) {
    return {
      ok: false,
      error: describeError(e),
      list: [],
      playUrl: '',
      vars: kv,
      elapsedMs: Date.now() - t0,
    };
  }
}
