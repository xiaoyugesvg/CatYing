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
 *   ✅ 翻页：`setNextPage`（结果里的 `nextPage`；首页/搜索用它"加载更多"，
 *      看图页用它做"下拉自动下一章" —— 见 simple_image_reader_page.dart）
 *   ✅ `x5://` 前缀剥离、`hiker://empty` 占位
 *   ❌ 未支持（Phase 2/3）：`hiker://page/*` 内置页面模块、`$.aes/$.des/$.rsa`、
 *      `hiker://assets/*`、多级 `pages` 跳转
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
const SCRIPT_TIMEOUT_MS = 12000;
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
    // 以下几个开关会改变**返回值形状**（JSON/hex/只取头）⇒ 必须参与缓存键，
    // 否则 `fetch(u)` 与 `fetch(u,{withHeaders:true})` 会互相拿到对方的缓存。
    o.withHeaders ? 'h' : '',
    o.withStatusCode ? 's' : '',
    o.onlyHeaders ? 'o' : '',
    o.toHex ? 'x' : '',
    o.redirect === false ? 'r' : '',
    o.ua === UA_PC ? 'pc' : '',
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
    /// 抓取**失败**过的地址（key → Error）：重放时把这些失败当异常抛回规则，
    /// 让源自己的 `try/catch`（多线路容错）能生效，见 [httpSync]。
    failedFetches: new Map(),
    cookies: new Map(), // host -> cookie 串
    touchedVars: false,
    lazyIds: new Set(), // 本趟遇到过的 lazyRule id（回报给宿主）
    listeners: {}, // addListener 注册的回调（我们不做事件循环，仅记录）
    /// 「重放期间的时间/随机数冻结」（见 [makeFrozenDate] / [pseudoRandom]）：
    /// 一条规则要重放好几轮，每轮都从头跑；若每轮 `Date.now()` / `Math.random()`
    /// 都不同，带时间戳/随机机器码的请求**每轮都是新缓存键** ⇒ 永远不命中、
    /// 40 轮耗尽（实测内置源「网页吃瓜」就是这个：请求头 `timestamp` + 随机 machine_code）。
    frozenNow: Date.now(),
    randSeed: ((Date.now() ^ (Math.random() * 0xffffffff)) >>> 0) || 1,
    randSeq: 0,
  };
}

/**
 * 冻结的 `Date`：`Date.now()` 返回**本次运行**固定的时间，`new Date()` 同理。
 *
 * 为什么必须冻结：重放桥是「每轮重跑整条规则」，而真实时间每轮都在走
 * ⇒ 只要规则把时间戳放进请求（签名/timestamp 头），缓存键每轮都变，
 * 规则永远收敛不了（用户看到的报错就是"重放次数超过上限"）。
 * 冻结在"运行开始时刻"不影响正常语义（一次页面加载本来也就几秒）。
 */
function makeFrozenDate(rt) {
  const base = Number(rt.frozenNow) || Date.now();
  function FrozenDate(...args) {
    if (!(this instanceof FrozenDate)) return new Date(base).toString();
    return args.length ? new Date(...args) : new Date(base);
  }
  FrozenDate.now = () => base;
  FrozenDate.parse = (...a) => Date.parse(...a);
  FrozenDate.UTC = (...a) => Date.UTC(...a);
  FrozenDate.prototype = Date.prototype;
  return FrozenDate;
}

/**
 * 冻结的 `Math.random()`：同一轮里第 n 次调用永远给同一个值
 * （`randSeq` 每轮重放前归零 ⇒ 各轮随机序列完全一致 ⇒ 缓存键稳定）。
 */
function pseudoRandom(rt) {
  const seq = Number(rt.randSeq) || 0;
  let x = ((Number(rt.randSeed) || 1) ^ Math.imul(seq + 1, 0x9e3779b9)) >>> 0;
  x ^= x << 13; x >>>= 0;
  x ^= x >>> 17;
  x ^= x << 5; x >>>= 0;
  rt.randSeq = seq + 1;
  return (x % 1000000) / 1000000;
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

/** 真正发出请求（异步）—— 只在重放循环里被调用
 *  [asBuffer] = true 时**不解码字符集**，直接把原始字节返回（`$.image` 用）。 */
async function doHttp(rt, url, opts, asBuffer = false) {
  const o = opts || {};
  const method = String(o.method || 'get').toLowerCase();
  // ⚠️ TVBox/海阔老写法是 `{ header: {...} }`（单数，无 s），新版才是 `headers`。
  //    只认复数会让请求头被**静默丢掉**（实测「✨91Porn✨」的 `request(input,
  //    {header:{'User-Agent':'91appnew'}})` 直接 403）。两种都吃。
  const headers = { ...(o.headers || o.header || {}) };
  const ua = o.ua || rt.ctx.ua;
  if (ua && !headers['User-Agent']) headers['User-Agent'] = ua;
  const ck = cookieHeaderFor(rt, url);
  if (ck && !headers['Cookie']) headers['Cookie'] = ck;

  // ── 请求体 / Content-Type（照官方 HttpHelper 的口径）──────────────
  //   · body 是**字符串**且形如 `{…}` / `[…]` → 自动 `application/json`
  //   · body 是对象 → JSON 字符串 + `application/json`
  //   · 其它字符串 → 表单（`a=1&b=2`）
  // 少了这一步，服务端（Spring）会当空 body 处理，返回 `data:null`
  //（实测「探色视频」的 config 接口）。
  const isBodyMethod = method === 'post' || method === 'put' || method === 'patch';
  let reqData = o.body != null ? o.body : undefined;
  const hasContentType = Object.keys(headers).some((k) => k.toLowerCase() === 'content-type');
  if (isBodyMethod && reqData != null) {
    if (typeof reqData !== 'string') {
      try { reqData = JSON.stringify(reqData); } catch (_) { reqData = String(reqData); }
      if (!hasContentType) headers['Content-Type'] = 'application/json;charset=utf-8';
    } else {
      const t = reqData.trim();
      const looksJson = (t.startsWith('{') && t.endsWith('}'))
        || (t.startsWith('[') && t.endsWith(']'));
      if (!hasContentType) {
        headers['Content-Type'] = looksJson
          ? 'application/json;charset=utf-8'
          : 'application/x-www-form-urlencoded;charset=utf-8';
      }
    }
  }

  const req = axios.request({
    url,
    method,
    headers,
    data: reqData,
    // 文档：`{timeout:5000}`（毫秒，默认 10 秒）；这里再夹一层上下限防呆
    timeout: Math.max(1000, Math.min(Number(o.timeout) || HTTP_TIMEOUT_MS, 60000)),
    maxRedirects: o.redirect === false ? 0 : 5,
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
  const reqTimeout = Math.max(1000, Math.min(Number(o.timeout) || HTTP_TIMEOUT_MS, 60000));
  const resp = await Promise.race([
    req,
    new Promise((_, rej) => {
      setTimeout(() => rej(new Error(`请求超时（${reqTimeout}ms）：${String(url).slice(0, 80)}`)),
        reqTimeout + 2000);
    }),
  ]);
  absorbSetCookie(rt, url, resp.headers);
  const buf = Buffer.from(resp.data);
  if (asBuffer) return buf; // 二进制通道（图片）：不做字符集解码
  const charset = String(o.charset || '').trim() || sniffCharset(resp.headers, buf) || 'utf-8';
  // ── 文档里的返回形状开关 ──────────────────────────────
  //   onlyHeaders：只要响应头；toHex：byte[] → 16 进制串；
  //   withHeaders / withStatusCode：返回 `{body,headers,statusCode}` 的 **JSON 字符串**
  const body = o.onlyHeaders === true
    ? ''
    : (o.toHex === true ? buf.toString('hex') : decodeBuffer(buf, charset));
  if (o.withHeaders === true || o.withStatusCode === true) {
    return JSON.stringify({
      body,
      headers: resp.headers || {},
      statusCode: resp.status,
    });
  }
  return body;
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
  let s = String(raw == null ? '' : raw);
  // 安卓绝对路径（`file:///storage/emulated/0/Android/data/<pkg>/files/Documents/newPlan.html`
  // 这类）在 iOS 上不存在：统一映射到 filesDir 下的**同名文件**。
  // 「我的主页」模板（assets/home.js）的 htmlUrl 就是这种写法，不映射会直接写失败。
  if (/^file:\/\//i.test(s) || /^[A-Za-z]:[\\/]/.test(s)
      || /^\/(?:storage|sdcard|data)\//i.test(s)) {
    const baseName = s.split(/[\\/]/).filter(Boolean).pop() || 'file';
    s = `hiker://files/${baseName}`;
  }
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
  // 宿主内置伪页（`hiker://collection` / `hiker://history` …）：
  // 「我的主页」模板（assets/home.js）会 fetch 它们来显示"收藏/历史"卡片。
  // 我们没有这些数据源 ⇒ 返回空数组/空串，让模板正常渲染其余部分，
  // 而不是整页报「hiker://assets/hiker://collection 不存在」。
  const pseudo = s.replace(/^hiker:\/\//i, '').split(/[?#]/)[0].toLowerCase();
  if (['collection', 'history', 'download', 'bookmark'].includes(pseudo)) return '[]';
  if (['home', 'tools', 'explore', 'search', 'localmedia'].includes(pseudo)) return '';
  const isPage = /^hiker:\/\/page\//i.test(s);
  const key = normalizeModuleName(s);
  const mod = rt.modules && rt.modules.get(key);
  if (isPage && mod) {
    return JSON.stringify({
      name: key,
      path: String(mod.path || key),
      // ⚠️ 源里最常见的写法是
      //     `eval(JSON.parse(request('hiker://page/aes')).rule)`
      //   然后在**同一函数**里直接用模块里的 `let image = …` / `const x = …`。
      //   ES 的 eval 里 `let/const` 只活在 eval 自己那段代码里（函数外看不到），
      //   而 Rhino 的 `let` 是函数作用域 ⇒ 官方能跑、我们会 `image is not defined`。
      //   服务出去之前统一改成 `var`，让直接 eval 把它提升到调用方函数作用域。
      rule: evalFriendlyModule(String(mod.rule || '')),
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

/**
 * 把页面模块里的 `let` / `const` 改成 `var`（只在 `hiker://page/*` 服务出去时用）。
 *
 * 原因：海阔（Rhino）里 `let` 是**函数作用域**，所以
 *   `eval(request('hiker://page/aes').rule)` 之后同一函数里能直接用模块的 `image`；
 * 而 ES 的 eval 里 `let/const` 只在 eval 代码内部可见 ⇒ 会报 `image is not defined`。
 * 改成 `var` 后，直接 eval 会把它提升到调用方函数作用域，与官方一致。
 */
function evalFriendlyModule(code) {
  return String(code || '')
    // 只处理"语句开头"的声明，避免误伤字符串里的单词
    .replace(/(^|[;{}\n])([ \t]*)(let|const)(\s+)/g, '$1$2var$4');
}

/**
 * `fileExist(path)` / `fileExists` / `existsFile` 的共用实现。
 *
 * 两种路径都认：
 *   · `hiker://page/x` → 查源自己的 pages 模块（不算文件）
 *   · 其余（`hiker://files/...` / 相对路径）→ 查文件区里是否真的有这个文件
 *
 * 永远不会抛错（源把它当布尔判断用，抛错会让整条规则中断）。
 */
function sandboxFileExist(rt, p) {
  const s = String(p == null ? '' : p);
  try {
    if (/^hiker:\/\/page\//i.test(s)) {
      const key = normalizeModuleName(s);
      const base = key.split('/').pop() || '';
      return !!(rt.modules
        && (rt.modules.has(key) || (base && rt.modules.has(base))));
    }
    return fs.existsSync(safePath(rt, s));
  } catch (_) {
    return false;
  }
}

/** 同步取网页（重放桥的发起端） */
function httpSync(rt, url, opts) {
  let u = String(url == null ? '' : url);
  // `hiker://...` 是**宿主资源/文件**，不联网（见 hikerFetch）
  if (/^hiker:\/\//i.test(u)) {
    const raw = hikerFetch(rt, u);
    // 官方语义：`request/fetch('hiker://page/X')` 返回的是
    //   `{"rule":"<模块源码>"}` 这样的 **JSON 字符串**（源里普遍写
    //   `JSON.parse(request('hiker://page/home')).rule` 再 eval）；
    // 而 `$.require('hiker://page/X')` 走的是模块求值，另一个入口。
    // 以前这里直接返回裸源码 ⇒ JSON.parse 必然炸 / .rule 拿不到东西
    // （115 个源里这种写法共 175 处）。
    if (/^hiker:\/\/page\//i.test(u)) {
      try {
        JSON.parse(raw);
        return raw; // 本来就是 JSON（配置页），原样返回
      } catch (_) {/* 不是 JSON ⇒ 包一层 */}
      const code = raw.replace(/^\s*js:\s*/i, '');
      return JSON.stringify({ rule: code });
    }
    return raw;
  }
  // 相对路径（`/api/x`、`config.json`）按当前页面地址补全：
  // 模块里常见 `request('/xxx/config')`，官方会自动拼上源域名。
  if (!/^https?:\/\//i.test(u) && u && !/^[a-z][\w+.-]*:/i.test(u)) {
    const base = String((rt.ctx && (rt.ctx.url || rt.ctx.homeUrl)) || '');
    if (/^https?:\/\//i.test(base)) {
      try {
        u = new URL(u, base).toString();
      } catch (_) { /* 保持原样，走下面的明确报错 */ }
    }
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
  // ⚠️ 这个地址**这一趟已经抓失败过** ⇒ 把失败**当成异常抛给规则**（海阔里
  //   `fetch` 失败就是抛错，源的 `try { fetch(u) } catch(e) { 换下一个域名 }`
  //   全靠它）。原来这里是让错误直接冲出规则（见 runHikerRule 里 doHttp 的
  //   catch）⇒ 源头写的多线路容错全部失效（实测「91短剧」4 个域名里死 1 个
  //   就整条规则崩，永远走不到还活着的域名）。
  if (rt.failedFetches && rt.failedFetches.has(key)) {
    throw rt.failedFetches.get(key);
  }
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
  // 同 httpSync：失败过就把失败当异常抛回规则（源自己会兜底）
  if (rt.failedFetches && rt.failedFetches.has(key)) {
    throw rt.failedFetches.get(key);
  }
  // 同 httpSync：被规则吞掉时也要能补抓（走宿主的 WebView 桥）
  rt.wantFetch = { url: u, key, opts: opts || {}, webview: true };
  throw new NeedWebView(u, opts || {}, key);
}

/** 把"抓页失败"包装成**规则能看懂的异常**（重放时抛回规则，见 [httpSync]） */
function fetchFailureError(url, err) {
  const msg = (err && err.message) ? String(err.message) : String(err);
  const e = new Error(`抓取失败：${String(url).slice(0, 90)}（${msg}）`);
  return e;
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
 *
 * ⚠️ 第二趟的产物**以这段 fn 为准**：海阔点"分类/详情/立即播放"时**只跑那一段**，
 *   而我们是重跑整条规则 ⇒ 外层规则随后自己的 `setResult(首页列表)` 会把 fn 里
 *   `setResult(详情内容)` 盖掉（实测「91短剧」点剧集进详情永远拿到首页）。
 *   所以这里把产物记到 `rt.lazyOutcome`，由 [runHikerRule] 优先采用。
 */
function lazyRuleImpl(rt, ctx, fn, args) {
  const a = Array.isArray(args) ? args : [];
  let argSig = '';
  try {
    // ⚠️ 签名里的 **域名要归一化**：多镜像站（实测 91短剧 在 91crdjai.com / aicrdj3.com /
    //   udhxjenp.cc 之间跳）同一集在不同趟会拿到不同域名的 URL ⇒ 按原始 args 算 id
    //   会对不上，"点播放却什么都没执行"。参数本身照原样传给 fn，只有算 id 时替换。
    argSig = JSON.stringify(a).replace(/https?:\/\/[^"'\s/]+/gi, 'HOST');
  } catch (_) {
    argSig = String(a.length);
  }
  const src = (typeof fn === 'function' ? fn.toString() : String(fn)) + '|' + argSig;
  const id = simpleHash(src);
  rt.lazyIds.add(id);
  // 第二趟：真正执行。`lazyIds` 是**父→子**的链条（海阔的 lazy URL 自带 JS，
  // 点嵌套条目只跑那一段；我们靠"把父 id 一起带上、逐层执行"来等价实现）：
  //   例：分类(icon) → 详情 → 立即播放 = [分类id, 详情id, 播放id]
  const want = Array.isArray(ctx.lazyIds) && ctx.lazyIds.length
    ? ctx.lazyIds
    : (ctx.lazyId ? [String(ctx.lazyId)] : []);
  if (want.includes(id)) {
    // 期间 `setResult` 的产物单独收一份（见沙箱里的 setResult）
    const prevIn = rt.inLazyFn;
    const prevCollected = rt.lazyCollected;
    rt.inLazyFn = true;
    rt.lazyCollected = undefined;
    rt.lazyDepth = (Number(rt.lazyDepth) || 0) + 1;
    const myDepth = rt.lazyDepth;
    let out;
    // 海阔里"条目地址 + lazyRule"这种写法：fn 里的 `input` 就是前面那截地址
    const swapInput = ctx.lazyInput ? String(ctx.lazyInput) : '';
    if (swapInput && typeof rt.setInput === 'function') rt.setInput(swapInput);
    try {
      out = typeof fn === 'function' ? fn(...a) : undefined;
    } finally {
      if (swapInput && typeof rt.setInput === 'function') rt.setInput(rt.inputBase);
      rt.lazyDepth = myDepth - 1;
      rt.inLazyFn = prevIn;
      // 只留**最内层**（嵌套最深）那次的产物：外层规则的 setResult 会盖掉内层，
      // 而真正想要的是"用户点的那一条"的结果
      if (!rt.lazyOutcome || myDepth >= rt.lazyOutcome.depth) {
        rt.lazyOutcome = { returned: out, result: rt.lazyCollected, depth: myDepth };
      }
      rt.lazyCollected = prevCollected;
    }
    return out;
  }
  return `hiker://lazy#${id}`;
}

// ============================================================
// DOM 选择器 DSL（海阔的 `A&&B&&C`）
// ============================================================

/**
 * 把 jsoup 的 `:matches(正则)` / `:matchesOwn(正则)` 从选择器里拆出来。
 *
 * 返回 `{ sel, filters }`：
 *   · `sel`     —— 去掉这些伪类后、cheerio 能执行的选择器
 *   · `filters` —— `[{ re, negate }]`，选完元素后按**文本**过滤
 *
 * 支持 `:not(:matches(...))` 的取反写法（海阔源里最常见的用法）。
 */
function splitMatchesPseudo(selRaw) {
  const filters = [];
  let s = String(selRaw || '');
  const mk = (rx) => {
    try {
      return new RegExp(String(rx));
    } catch (_) {
      return /$^/; // 坏正则 ⇒ 永不命中（比抛错让整条规则崩掉好）
    }
  };
  s = s.replace(/:not\(\s*:matches(?:Own)?\(((?:[^()\\]|\\.)*)\)\s*\)/g, (_, rx) => {
    filters.push({ re: mk(rx), negate: true });
    return '';
  });
  s = s.replace(/:matches(?:Own)?\(((?:[^()\\]|\\.)*)\)/g, (_, rx) => {
    filters.push({ re: mk(rx), negate: false });
    return '';
  });
  return { sel: s.trim(), filters };
}

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
    // jsoup 专有伪类（`:matches(正则)` / `:matchesOwn`）cheerio 不认识：
    //   正着写会**静默返回 0 条**，写在 `:not(...)` 里则完全不生效。
    //   这里拆出来，选完再按元素文本做正则过滤（实测「午夜影院」的
    //   `li:not(:has(a[target])):not(:matches(黑鬼|媚黑|…))` 就靠它）。
    const { sel, filters } = splitMatchesPseudo(seg);
    const useSel = sel.length > 0 ? sel : '*';
    try {
      cur = cur === null ? $(useSel) : cur.find(useSel);
    } catch (_) {
      // 还有别的 jsoup 伪类（`:containsOwn` 等）不被认识 → 退化到前半段选择器
      try {
        const rough = useSel.split(':')[0].trim() || '*';
        cur = cur === null ? $(rough) : cur.find(rough);
      } catch (_) {
        return null; // 无效选择器
      }
    }
    if (!cur || cur.length === 0) return null;
    if (filters.length) {
      cur = cur.filter((_, el) => filters.every((f) => {
        const hit = f.re.test($(el).text());
        return f.negate ? !hit : hit;
      }));
      if (!cur || cur.length === 0) return null;
    }
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
  const rawUrl = it.url ?? it.link ?? it.href ?? '';
  // 官方允许条目 url 直接放**播放地址对象**（`url: {urls:['…m3u8']}`，实测探色视频）；
  // 直接 String() 会变成 "[object Object]"，播放页就永远打不开。
  let url;
  if (rawUrl && typeof rawUrl === 'object') {
    try {
      url = JSON.stringify(rawUrl).trim();
    } catch (_) {
      url = String(rawUrl).trim();
    }
  } else {
    url = String(rawUrl).trim();
  }
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
 * 海阔「播放地址」的**合法形态** —— 按官方 `assets/help_link.json`，
 * 详情/选集产出的"播放地址"远不止 http：
 *   · `pics://图1&&图2`    多图模式（类似漫画），下拉自动下一章
 *   · `novel://{…}`        正文（项目内 TVBox 约定）
 *   · `x5Play://http://…`  强制用播放器播该地址
 *   · `video://https://…`  进播放器自动提取视频
 * 原来只认 `http(s)`/`x5://` ⇒ 漫画源、小说源的"立即播放"永远拿不到地址
 * （点下去没反应），实测被丢弃的就是这一批。
 */
const PLAY_ADDR_SCHEMES = [
  'pics://', 'mange://', 'pic://', 'image://', 'images://',
  'novel://', 'book://', 'txt://', 'video://', 'x5play://',
];

function isPlayableAddr(s) {
  const t = String(s || '').trim();
  if (!t) return false;
  if (/^https?:\/\//i.test(t)) return true;
  const low = t.toLowerCase();
  return PLAY_ADDR_SCHEMES.some((p) => low.startsWith(p));
}

/** 剥掉官方"外壳协议"（语义等同"就播/就看它"的那几个） */
function stripOuterScheme(s) {
  const t = String(s || '').trim();
  const low = t.toLowerCase();
  if (low.startsWith('x5play://')) return t.slice(9);
  if (low.startsWith('x5://')) return t.slice(5);
  return t;
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
  // Node（含 iOS 的 nodejs-mobile）主线程允许 Atomics.wait，用法与阻塞睡眠一致。
  // 实测 Node 18.20.4（= iOS 端同一个版本）可用；万一某个运行时禁掉了
  // SharedArrayBuffer/Atomics，也不能让规则直接炸 —— 退化成忙等（规则里
  // sleep 一般都是几十~几百毫秒的节流）。
  try {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, n);
    return;
  } catch (_) { /* 下面走忙等 */ }
  const end = Date.now() + n;
  while (Date.now() < end) { /* 忙等兜底 */ }
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

/**
 * `javax.crypto.Cipher` 的最小实现（**真加解密**）。
 *
 * ⚠️ 刻意用**纯 JS 的 CryptoJS**（引擎本来就自带，`buildCryptoGlobals` 也用它），
 *   而不是 `node:crypto` —— iOS 的 nodejs-mobile 是裁剪过的运行时，
 *   `main.js` 里那句 `builtinModules.forEach` 是**逐模块 try/catch 跳过缺失内建**的
 *   （即 crypto 是否可用没人保证过）。走 CryptoJS 就没有这个风险，跨平台行为一致。
 *
 * 实测用到它的内置源：野果短剧 / 91短剧（封面与首页数据都是 `AES/CBC/PKCS5Padding` 密文）。
 * 语义按 Java：`getInstance("AES/CBC/PKCS5Padding")` → `init(mode, keySpec, ivSpec)`
 * → `doFinal(bytes)`，返回**有符号 byte[]**（Rhino 里 byte[] 就是有符号数字数组）。
 */
function makeCipher(transformation) {
  const parts = String(transformation == null ? 'AES/ECB/PKCS5Padding' : transformation).split('/');
  const alg = String(parts[0] || 'AES').trim().toUpperCase();
  const mode = String(parts[1] || 'ECB').trim().toUpperCase();
  const pad = String(parts[2] || 'PKCS5Padding').trim().toUpperCase();
  let keyBuf = null;
  let ivBuf = null;
  let opMode = 0;

  const hexOf = (b) => CryptoJS.enc.Hex.parse(Buffer.from(b).toString('hex'));
  const modeOf = () => {
    const m = {
      ECB: CryptoJS.mode.ECB, CBC: CryptoJS.mode.CBC, CTR: CryptoJS.mode.CTR,
      CFB: CryptoJS.mode.CFB, OFB: CryptoJS.mode.OFB,
    }[mode];
    if (!m) throw new Error(`AES 模式不支持：${mode}`);
    return m;
  };
  const padOf = () => {
    if (pad === 'NOPADDING') return CryptoJS.pad.NoPadding;
    if (pad === 'PKCS5PADDING' || pad === 'PKCS7PADDING') return CryptoJS.pad.Pkcs7;
    if (pad === 'ISO10126PADDING') return CryptoJS.pad.Iso10126;
    if (pad === 'ZEROPADDING') return CryptoJS.pad.ZeroPadding;
    // 流模式（CTR/CFB/OFB）按 Java 语义本来是 NoPadding
    return (mode === 'CTR' || mode === 'CFB' || mode === 'OFB')
      ? CryptoJS.pad.NoPadding
      : CryptoJS.pad.Pkcs7;
  };

  const run = (data) => {
    if (alg !== 'AES') throw new Error(`javax.crypto.Cipher 只实现了 AES（收到 ${alg}）`);
    if (!keyBuf || !keyBuf.length) throw new Error('javax.crypto.Cipher 还没 init（没有密钥）');
    const bits = keyBuf.length * 8;
    if (![128, 192, 256].includes(bits)) throw new Error(`AES 密钥长度不合法：${bits} bit`);
    const needIv = mode !== 'ECB';
    if (needIv && (!ivBuf || ivBuf.length !== 16)) throw new Error(`${alg}/${mode} 需要一个 16 字节 IV`);
    const cfg = { mode: modeOf(), padding: padOf() };
    if (needIv) cfg.iv = hexOf(ivBuf);
    const key = hexOf(keyBuf);
    const msg = hexOf(bufOf(data));
    // Java 的 ENCRYPT_MODE=1 / DECRYPT_MODE=2
    if (opMode === 2) {
      const dec = CryptoJS.AES.decrypt({ ciphertext: msg }, key, cfg);
      return signedBytes(Buffer.from(dec.toString(CryptoJS.enc.Hex), 'hex'));
    }
    const enc = CryptoJS.AES.encrypt(msg, key, cfg);
    return signedBytes(Buffer.from(enc.ciphertext.toString(CryptoJS.enc.Hex), 'hex'));
  };

  return {
    init: (m, keySpec, ivSpec) => {
      opMode = Number(m) || 0;
      keyBuf = bufOf(keySpec && (keySpec.__key || keySpec.secret || keySpec));
      const iv = ivSpec && (ivSpec.__iv || ivSpec.iv || ivSpec);
      if (iv != null) ivBuf = bufOf(iv);
      return undefined;
    },
    doFinal: run,
    update: run,
    getIV: () => (ivBuf ? signedBytes(ivBuf) : []),
    getAlgorithm: () => `${alg}/${mode}/${pad}`,
    toString: () => `Cipher(${alg}/${mode}/${pad})`,
  };
}

/** `android.util.Base64` 的 flags（照 Android 常量表） */
const ANDROID_B64 = { DEFAULT: 0, NO_PADDING: 1, NO_WRAP: 2, CRLF: 4, URL_SAFE: 8, NO_CLOSE: 16 };

function androidB64Decode(str, flags) {
  const f = Number(flags) || 0;
  let s = String(str == null ? '' : str).replace(/\s+/g, '');
  if (f & ANDROID_B64.URL_SAFE) s = s.replace(/-/g, '+').replace(/_/g, '/');
  s = s.replace(/=+$/, '');
  const pad = s.length % 4;
  if (pad) s += '='.repeat(4 - pad);
  return Buffer.from(s, 'base64');
}

function androidB64Encode(v, flags) {
  const f = Number(flags) || 0;
  let s = bufOf(v).toString('base64');
  if (f & ANDROID_B64.URL_SAFE) s = s.replace(/\+/g, '-').replace(/\//g, '_');
  if (f & ANDROID_B64.NO_PADDING) s = s.replace(/=+$/, '');
  return s;
}

// ============================================================
// `$.image(fn, …)` —— 封面/图片解密（**懒执行**）
// ============================================================
//
// 海阔里 `$(url, headers).image(fn)` 的语义是**生成一个"图片解密链接"**
// （官方 help_js.json 原话就是"生成链接"）：fn 里能拿到 Java InputStream 形态的
// 图片字节（全局 `input`，`input.read(buf)` 循环读），返回处理后的图。
// 典型用途就是**封面是密文** —— 真人短剧站几乎都这么干
// （实测 91短剧 / 野果短剧 / 麻豆传媒AI / 新吾爱吃瓜网）。
//
// 我们按同样的语义做：
//   · 规则里只**登记**一个任务（url + headers + fn 源码），返回本机地址
//     `http://127.0.0.1:<mgmt>/hiker/image/<token>`；
//   · 宿主渲染到那张图时才来取 → 这时才真去抓原图、跑 fn 解密、把字节吐回去。
//
// 为什么不"规则里就把图抓回来"（第一版就是那样，实测不行）：
//   · 一屏 50 张封面 = 50 次抓图 + 50 次解密**全压在列表加载上**
//     （实测 野果短剧：25 次请求 / 13 秒才出列表），而宿主根本没用到那么多张；
//   · 官方就是这样懒执行的（点开/滚动到才解），列表才能秒出。
//
// 顺带的好处：需要 Referer/UA 的图也能显示（是 Node 带着源给的 headers 去抓的），
// 而且不用把几百 KB 的 base64 塞进列表 JSON。

/** 单张图上限（超过就退回原图地址，别把内存撑爆） */
const MAX_IMAGE_BYTES = 4 * 1024 * 1024;
/** 已解好的图：条数 + 总字节双上限（LRU 淘汰最旧的） */
const MAX_IMAGE_CACHE_ITEMS = 48;
const MAX_IMAGE_CACHE_BYTES = 12 * 1024 * 1024;
/** 待解任务上限 / 存活时间（页面重跑会不断产生新 token） */
const MAX_IMAGE_TASKS = 400;
const IMAGE_TASK_TTL_MS = 30 * 60 * 1000;

/** token → { url, headers, src, args, at }（规则里登记，取图时执行） */
const IMAGE_TASKS = new Map();
/** token → { bytes, mime }（解好的图，重复取直接命中） */
const IMAGE_CACHE = new Map();
let IMAGE_CACHE_BYTES = 0;
let IMAGE_PORT = 0;
let IMAGE_SEQ = 0;

/** 抓原图用的"假运行时"（doHttp 只用到 ctx.ua 与 cookies） */
const IMAGE_FETCH_RT = { ctx: { ua: UA_MOBILE }, cookies: new Map() };

/** main.js 在 mgmtServer 监听成功后把端口同步进来（拼图片地址要用） */
export function setHikerImagePort(port) {
  const n = Number(port) || 0;
  if (n > 0) IMAGE_PORT = n;
}

/** 规则里登记一张"待解密的图"，返回宿主可直接渲染的地址 */
function registerImageTask(url, headers, fn, extra, modulesPlain) {
  const token = `${++IMAGE_SEQ}t${Date.now().toString(36)}`;
  IMAGE_TASKS.set(token, {
    url: String(url),
    headers: headers || {},
    src: typeof fn === 'function' ? fn.toString() : '',
    args: Array.isArray(extra) ? extra : [],
    /// 源自己的页面模块源码（`$.require('xxx')` 要用，见 [runImageFn]）：
    /// 多个 task 共享**同一个对象**（一次运行只建一份），不额外占内存
    modules: modulesPlain || null,
    at: Date.now(),
  });
  while (IMAGE_TASKS.size > MAX_IMAGE_TASKS) {
    IMAGE_TASKS.delete(IMAGE_TASKS.keys().next().value);
  }
  return token;
}

/**
 * main.js 的 `/hiker/image/<token>` 用它取图：
 * 抓原图 → 跑 fn 解密 → 返回 { bytes, mime }；解密/抓取失败返回
 * `{ redirect: 原始地址 }`（让宿主去试原图，总比空白好）；token 不认识返回 null。
 */
export async function resolveHikerImage(token) {
  const key = String(token || '');
  const cached = IMAGE_CACHE.get(key);
  if (cached) return { bytes: cached.bytes, mime: cached.mime };
  const task = IMAGE_TASKS.get(key);
  if (!task) return null;
  if (Date.now() - task.at > IMAGE_TASK_TTL_MS) {
    IMAGE_TASKS.delete(key);
    return null;
  }
  let raw;
  try {
    raw = await doHttp(IMAGE_FETCH_RT, task.url, { headers: task.headers }, true);
  } catch (e) {
    warnOnce(`$.image 抓图失败（${describeError(e)}），已回退原图`);
    return { redirect: task.url };
  }
  if (!raw || !raw.length || raw.length > MAX_IMAGE_BYTES) return { redirect: task.url };
  let bytes = raw;
  if (task.src) {
    const decrypted = runImageFn(task.src, raw, task.args, task.modules);
    if (decrypted && decrypted.length) bytes = decrypted;
  }
  const mime = imageMimeOf(bytes);
  // 认不出图片格式 ⇒ 多半是解密没成：让宿主去试原图地址
  if (!mime) return { redirect: task.url };
  IMAGE_CACHE.set(key, { bytes, mime });
  IMAGE_CACHE_BYTES += bytes.length;
  while (IMAGE_CACHE.size > MAX_IMAGE_CACHE_ITEMS
      || (IMAGE_CACHE_BYTES > MAX_IMAGE_CACHE_BYTES && IMAGE_CACHE.size > 1)) {
    const oldest = IMAGE_CACHE.keys().next().value;
    const gone = IMAGE_CACHE.get(oldest);
    IMAGE_CACHE.delete(oldest);
    IMAGE_CACHE_BYTES -= gone ? gone.bytes.length : 0;
  }
  return { bytes, mime };
}

/**
 * 在**最小沙箱**里跑图片解密函数。
 *
 * 给的是：`java.* / javax.* / android.* + input + 基础 JS 全局 + $.require(...)`。
 * `$.require('common')` 这种很常见（实测 新吾爱吃瓜网：解密器写在源自己的
 * 「公共模块」里，`.image(fn, 'common')` 把模块名当额外参数传进来）——
 * 所以这里把源的页面模块源码也带过来，按需就地求值（不联网、不重跑整条规则）。
 * 用到更重的东西（`fetch` / `getResCode` / 规则上下文变量）就会抛错 ⇒
 * 上层退回原图地址，不会把整个列表搞挂。
 */
function runImageFn(src, buf, args, modulesPlain) {
  try {
    const javaNs = buildJavaNs();
    const inputStream = makeInputStream(buf);
    const canNot = () => { throw new Error('图片解密函数里用不了 $.xxx（只支持 $.require）'); };
    const box = {
      input: inputStream,
      java: javaNs,
      javax: javaNs.javax,
      android: buildAndroidNs(),
      console,
      JSON, Math, Date, String, Number, Boolean, Array, Object, RegExp, Error,
      parseInt, parseFloat, isNaN, encodeURIComponent, decodeURIComponent,
      atob: (s) => Buffer.from(String(s), 'base64').toString('binary'),
      btoa: (s) => Buffer.from(String(s), 'binary').toString('base64'),
      $: canNot,
    };

    /** `$.require('xxx')`：在同一个最小沙箱里就地求值源自己的页面模块 */
    const modCache = new Map();
    function imageRequire(name) {
      const key = String(name == null ? '' : name)
        .replace(/^hiker:\/\/page\//i, '')
        .replace(/\.js$/i, '')
        .trim()
        .toLowerCase();
      if (!key) throw new Error('$.require() 拿到了空名字');
      if (modCache.has(key)) return modCache.get(key);
      let code = '';
      if (modulesPlain) {
        for (const n of Object.keys(modulesPlain)) {
          if (n.toLowerCase() === key || n.replace(/\.js$/i, '').toLowerCase() === key) {
            code = modulesPlain[n];
            break;
          }
        }
      }
      if (!code) throw new Error(`图片解密函数要的模块「${key}」不在源的 pages 里`);
      // 海阔的模块导出约定是 `$.exports = xxx;`（见 [runInModuleScope]），
      // 所以这里必须**跑完再读 `$.exports`**；读不到就退回"沙箱顶层绑定"（var/function）。
      const exportsBox = {};
      const dollar = Object.assign(canNot, { require: imageRequire });
      const sub = { ...box, $: dollar, exports: exportsBox };
      dollar.exports = undefined;
      vm.runInContext(code, vm.createContext(sub), { timeout: SCRIPT_TIMEOUT_MS });
      const value = dollar.exports !== undefined
        ? dollar.exports
        : (Object.keys(exportsBox).length ? exportsBox : sub);
      modCache.set(key, value);
      return value;
    }
    box.$ = Object.assign(canNot, { require: imageRequire });

    const ctx = vm.createContext(box);
    const fn = vm.runInContext(`(${src})`, ctx, { timeout: SCRIPT_TIMEOUT_MS });
    if (typeof fn !== 'function') return null;
    const out = fn(inputStream, ...(args || []));
    if (typeof out === 'string') {
      const s = out.trim();
      if (!s) return null;
      if (/^(https?:|data:|hiker:)/i.test(s)) return null; // 源自己换了地址 → 走兜底
      return tryImageBase64(s);
    }
    return bytesOfImageResult(out);
  } catch (e) {
    warnOnce(`图片解密函数执行失败（${describeError(e)}），已回退原图`);
    return null;
  }
}

/** 从魔数认图片类型（认不出来返回 ''，调用方据此判断"解密是不是失败了"） */
function imageMimeOf(buf) {
  if (!buf || buf.length < 4) return '';
  if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'image/jpeg';
  if (buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) return 'image/png';
  if (buf[0] === 0x47 && buf[1] === 0x49 && buf[2] === 0x46 && buf[3] === 0x38) return 'image/gif';
  if (buf[0] === 0x42 && buf[1] === 0x4d) return 'image/bmp';
  if (buf.length >= 12 && buf.slice(8, 12).toString('ascii') === 'WEBP') return 'image/webp';
  return '';
}

/** fn 的返回值 → Buffer（InputStream / byte[] / Buffer 三种形态） */
function bytesOfImageResult(v) {
  if (v == null) return null;
  if (Buffer.isBuffer(v)) return v;
  if (Buffer.isBuffer(v.__bytes)) return v.__bytes; // makeInputStream
  if (Array.isArray(v)) return bufOf(v);
  if (v instanceof Uint8Array) return Buffer.from(v);
  return null;
}

/** 源直接返回 base64 的情况（认得出来才算图） */
function tryImageBase64(s) {
  const t = String(s).replace(/\s+/g, '');
  if (t.length < 32 || !/^[A-Za-z0-9+/_-]+={0,2}$/.test(t)) return null;
  try {
    const buf = androidB64Decode(t, /[-_]/.test(t) ? ANDROID_B64.URL_SAFE : 0);
    return imageMimeOf(buf) ? buf : null;
  } catch (_) {
    return null;
  }
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
    // `javax.crypto.*`（AES 加解密；见 [makeCipher]）
    javax: {
      crypto: {
        Cipher: Object.assign(
          function () { throw new Error('javax.crypto.Cipher 请用 Cipher.getInstance(...)'); },
          {
            ENCRYPT_MODE: 1,
            DECRYPT_MODE: 2,
            WRAP_MODE: 3,
            UNWRAP_MODE: 4,
            getInstance: (t) => makeCipher(t),
          },
        ),
        spec: {
          SecretKeySpec: function (bytes, algorithm) {
            return { __key: bufOf(bytes), algorithm: String(algorithm == null ? '' : algorithm) };
          },
          IvParameterSpec: function (bytes) {
            return { __iv: bufOf(bytes) };
          },
          GCMParameterSpec: function (tagLen, iv) {
            return { __iv: bufOf(iv), __tagLen: Number(tagLen) || 0 };
          },
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

/**
 * `android.*` 的 shim（海阔规则里常见的 Android 专属 API）。
 *
 * 实测用到：野果短剧 —— `android.util.Base64.decode(text, android.util.Base64.DEFAULT)`
 * 解出 AES 密文（它的首页/正文数据都是密文）。缺了它整条规则会
 * `android is not defined` 直接炸。
 */
function buildAndroidNs() {
  const Base64 = {
    ...ANDROID_B64,
    decode: (s, flags) => signedBytes(androidB64Decode(s, flags)),
    encode: (b, flags) => Buffer.from(androidB64Encode(b, flags), 'utf8'),
    encodeToString: (b, flags) => androidB64Encode(b, flags),
  };
  return lazyJavaNs({
    util: { Base64 },
    text: { TextUtils: { isEmpty: (s) => s == null || String(s).length === 0 } },
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
  // 先做 Rhino 语法兼容，再把"语句开头的 let/const"降成 var：
  // Rhino 允许同作用域重复声明（`let key` 出现两次），V8 会报
  // "Identifier 'key' has already been declared"（公共库 `f` 就是这样）。
  const body = evalFriendlyModule(fixRhinoLexical(stripJsPrefix(code)));
  const names = new Set();
  const re = /(?:^|\n)\s*(?:const|let|var|function|class)\s+([A-Za-z_$][\w$]*)/g;
  let m;
  // ⚠️ 上限不能太小：公共库 `f` 有两百多个顶层函数，`imgDec` 在第 4852 行，
  //    原来卡 40 个 ⇒ 它不会被复制进沙箱，源调用时就是 "imgDec is not defined"。
  while ((m = re.exec(body)) !== null && names.size < 600) names.add(m[1]);
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
  // ⚠️ 默认必须是**对象**：大量模块写 `$.exports.xxx = ...`（而不是整体赋值），
  //    原来默认 undefined 会报 "Cannot set properties of undefined"，
  //    整条源在加载模块时直接失败（实测 探色视频 / 摸鱼日报）。
  if (dollar) dollar.exports = {};
  let out;
  let moduleExports;
  try {
    out = vm.runInContext(src, sandbox, { timeout: SCRIPT_TIMEOUT_MS });
    // ⚠️ 必须在 finally 恢复之前把模块写入的 exports 取出来
    moduleExports = dollar ? dollar.exports : undefined;
  } finally {
    if (dollar) {
      if (hadExports) dollar.exports = prevExports;
      else dollar.exports = {};
    }
  }
  // 只有模块**真的往里塞了东西**才算导出；否则继续走"按名字取绑定"的老路
  if (moduleExports !== undefined && moduleExports !== null) {
    const empty = typeof moduleExports === 'object'
      && Object.keys(moduleExports).length === 0;
    if (!empty) return moduleExports;
  }
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
    if (sandbox[wantName] !== undefined) return sandbox[wantName];
  } catch (_) { /* 忽略 */ }
  // 模块确实存在、也正常跑完了，但没有任何导出 —— 典型是"只做副作用"的模块
  //（实测「探色视频」的 homelei：把 host 写进 item 后 refreshPage，源码里
  //  `$.require("homelei")` 只当语句用）。官方这里就是 undefined；我们返回
  // 空对象，避免 normalizeModuleValue 抛"没取到值"把整条规则打断。
  warnOnce(`模块「${wantName || '?'}」没有导出值（按空对象处理）`);
  return {};
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
  // ⚠️ `CryptoJS` 必须一起给：官方是把整份 `assets/aes.js`（CryptoJS 副本 + AES/Data
  //    封装）**全局注入**的，源里除了 `AES.encrypt(...)` 还会直接写
  //    `CryptoJS.MD5(...)` / `CryptoJS.enc.Base64` —— 少了它照样 "CryptoJS is not defined"。
  //    DES / TripleDES 同族，一起暴露（社区源常用 `$.des` / `DES.encrypt`）。
  const _desDecrypt = CryptoJS.DES.decrypt.bind(CryptoJS.DES);
  const _desEncrypt = CryptoJS.DES.encrypt.bind(CryptoJS.DES);
  const DES = {
    ...CryptoJS.DES,
    encrypt: (msg, key, c) => _desEncrypt(msg, key, cfg(c)),
    decrypt: (cipher, key, c) => _desDecrypt(cipher, key, cfg(c)),
  };
  const _tdesDecrypt = CryptoJS.TripleDES.decrypt.bind(CryptoJS.TripleDES);
  const _tdesEncrypt = CryptoJS.TripleDES.encrypt.bind(CryptoJS.TripleDES);
  const TripleDES = {
    ...CryptoJS.TripleDES,
    encrypt: (msg, key, c) => _tdesEncrypt(msg, key, cfg(c)),
    decrypt: (cipher, key, c) => _tdesDecrypt(cipher, key, cfg(c)),
  };
  return { AES, Data, CryptoJS, DES, TripleDES };
}

/**
 * `rsa` 兼容层（社区源里 `$.rsa.encrypt(明文, 公钥)` / `rsa.decrypt(密文, 私钥)`）。
 *
 * CryptoJS **没有** RSA ⇒ 用 Node 自带 `crypto` 实现。默认 PKCS#1 v1.5
 * （最常用的"公钥加密、Base64 输出"），可传 `{padding:'oaep'}` 切 OAEP。
 */
function buildRsa() {
  const padOf = (o) => {
    const p = String((o && o.padding) || 'pkcs1').toLowerCase();
    return p.includes('oaep')
      ? crypto.constants.RSA_PKCS1_OAEP_PADDING
      : crypto.constants.RSA_PKCS1_PADDING;
  };
  const out = (buf, o) =>
    String((o && o.output) || 'base64').toLowerCase() === 'hex'
      ? buf.toString('hex')
      : buf.toString('base64');
  return {
    encrypt: (msg, key, o) => out(
      crypto.publicEncrypt(
        { key: String(key == null ? '' : key), padding: padOf(o) },
        Buffer.from(String(msg == null ? '' : msg), 'utf8'),
      ),
      o,
    ),
    // 私钥解密：`data` 默认按 Base64 解（与 encrypt 的默认输出对称）
    decrypt: (data, key, o) => {
      const s = String(data == null ? '' : data);
      const buf = String((o && o.input) || 'base64').toLowerCase() === 'hex'
        ? Buffer.from(s, 'hex')
        : Buffer.from(s, 'base64');
      return crypto.privateDecrypt(
        { key: String(key == null ? '' : key), padding: padOf(o) },
        buf,
      ).toString('utf8');
    },
  };
}

/**
 * 官方 `aesEncode/aesDecode`（`utils/encrypt/AesUtil.java`）：
 *   · AES / ECB / PKCS5Padding，Base64 输出（NO_WRAP）
 *   · 密钥按**字符数**补 `'0'` 到 32 位（不足才补，超了不截断）
 *
 * ⚠️ 与 `$.aes.encrypt(明文, key)` 不是一回事：那个是社区版参数顺序
 *    （数据在前），这里是官方的 `(key, data)`。
 */
function aesKey32(key) {
  const s = String(key == null ? '' : key);
  return s.length < 32 ? s + '0'.repeat(32 - s.length) : s;
}

function aesEncodeDoc(key, data) {
  try {
    const k = CryptoJS.enc.Utf8.parse(aesKey32(key));
    return CryptoJS.AES.encrypt(String(data == null ? '' : data), k, {
      mode: CryptoJS.mode.ECB,
      padding: CryptoJS.pad.Pkcs7,
    }).toString();
  } catch (_) {
    return '';
  }
}

function aesDecodeDoc(key, base64Data) {
  try {
    const k = CryptoJS.enc.Utf8.parse(aesKey32(key));
    const dec = CryptoJS.AES.decrypt(String(base64Data == null ? '' : base64Data), k, {
      mode: CryptoJS.mode.ECB,
      padding: CryptoJS.pad.Pkcs7,
    });
    return dec.toString(CryptoJS.enc.Utf8);
  } catch (_) {
    return '';
  }
}

/**
 * 官方 `decodeStr/encodeStr`（`HttpParser.decodeUrl/encodeUrl`）：
 *   本质是 **URL 百分号编解码 + 指定字符集**（GBK/GB2312 站点常用），
 *   而不是"乱码二次解码"。
 *
 * 官方对 `UTF-8` / `*` / 空字符集**直接原样返回**（见 HttpParser.encodeUrl）。
 */
function decodeStrDoc(str, charset) {
  const s = String(str == null ? '' : str);
  const cs = String(charset == null ? '' : charset).trim();
  if (!cs || cs === '*' || /^utf-?8$/i.test(cs)) return s;
  const fixed = s.replace(/%(?![0-9a-fA-F]{2})/g, '%25').replace(/\+/g, '%2B');
  const bytes = [];
  for (let i = 0; i < fixed.length; i++) {
    if (fixed[i] === '%' && /^[0-9a-fA-F]{2}$/.test(fixed.slice(i + 1, i + 3))) {
      bytes.push(parseInt(fixed.slice(i + 1, i + 3), 16));
      i += 2;
    } else {
      for (const b of iconv.encode(fixed[i], cs)) bytes.push(b);
    }
  }
  try {
    return iconv.decode(Buffer.from(bytes), cs);
  } catch (_) {
    return s;
  }
}

function encodeStrDoc(str, charset) {
  const s = String(str == null ? '' : str);
  const cs = String(charset == null ? '' : charset).trim();
  if (!cs || cs === '*' || /^utf-?8$/i.test(cs)) return s;
  let bytes;
  try {
    bytes = iconv.encode(s, cs);
  } catch (_) {
    return s;
  }
  let out = '';
  for (const b of bytes) {
    const c = String.fromCharCode(b);
    if (/[A-Za-z0-9._*-]/.test(c)) out += c;
    else if (c === ' ') out += '+';
    else out += `%${b.toString(16).toUpperCase().padStart(2, '0')}`;
  }
  return out;
}

/**
 * 官方 `rsaEncrypt/rsaDecrypt(data, key, options)`。
 *
 * options（都可省）：`{config:"RSA/ECB/PKCS1Padding", type:1, long:1, block:true}`
 *   · type 1 = 公钥加密 / 私钥解密（默认）；2 = 私钥加密 / 公钥解密
 *   · long 1 = 普通；2 = 分段（按密钥长度切块）
 *   · block false = 加密固定 117 字节；true = 自动
 */
function rsaDocOptions(options) {
  const o = options && typeof options === 'object' ? options : {};
  const config = String(o.config || 'RSA/ECB/PKCS1Padding');
  const padding = /OAEP/i.test(config)
    ? crypto.constants.RSA_PKCS1_OAEP_PADDING
    : crypto.constants.RSA_PKCS1_PADDING;
  return {
    padding,
    type: Number(o.type) === 2 ? 2 : 1,
    long: Number(o.long) === 2 ? 2 : 1,
    block: o.block !== false,
  };
}

function rsaKeyBytes(key, isPrivate) {
  try {
    const k = isPrivate ? crypto.createPrivateKey(String(key)) : crypto.createPublicKey(String(key));
    const bits = (k.asymmetricKeyDetails && k.asymmetricKeyDetails.modulusLength) || 2048;
    return Math.floor(bits / 8);
  } catch (_) {
    return 256;
  }
}

function rsaEncryptDoc(data, key, options) {
  const s = String(data == null ? '' : data);
  const k = String(key == null ? '' : key);
  const opt = rsaDocOptions(options);
  const buf = Buffer.from(s, 'utf8');
  const isPrivate = opt.type === 2;
  const keyBytes = rsaKeyBytes(k, isPrivate);
  const chunk = opt.block
    ? Math.max(1, keyBytes - (opt.padding === crypto.constants.RSA_PKCS1_OAEP_PADDING ? 42 : 11))
    : 117;
  try {
    if (opt.long !== 2) {
      return (isPrivate
        ? crypto.privateEncrypt({ key: k, padding: opt.padding }, buf)
        : crypto.publicEncrypt({ key: k, padding: opt.padding }, buf)).toString('base64');
    }
    const parts = [];
    for (let i = 0; i < buf.length; i += chunk) {
      const one = buf.subarray(i, i + chunk);
      parts.push(isPrivate
        ? crypto.privateEncrypt({ key: k, padding: opt.padding }, one)
        : crypto.publicEncrypt({ key: k, padding: opt.padding }, one));
    }
    return Buffer.concat(parts).toString('base64');
  } catch (_) {
    return '';
  }
}

function rsaDecryptDoc(base64Data, key, options) {
  const s = String(base64Data == null ? '' : base64Data).trim();
  if (!s) return '';
  const k = String(key == null ? '' : key);
  const opt = rsaDocOptions(options);
  const buf = Buffer.from(s, 'base64');
  const isPublic = opt.type === 2; // type 2 = 私钥加密 ⇒ 公钥解密
  const keyBytes = rsaKeyBytes(k, !isPublic);
  const chunks = opt.long === 2 && buf.length > keyBytes
    ? (() => {
        const out = [];
        for (let i = 0; i < buf.length; i += keyBytes) out.push(buf.subarray(i, i + keyBytes));
        return out;
      })()
    : [buf];
  try {
    const out = chunks.map((one) => (isPublic
      ? crypto.publicDecrypt({ key: k, padding: opt.padding }, one)
      : crypto.privateDecrypt({ key: k, padding: opt.padding }, one)));
    return Buffer.concat(out).toString('utf8');
  } catch (_) {
    return '';
  }
}

/** `post(url, obj)`：官方会把普通对象自动转成 `a=xx&b=1` */
function formEncode(obj) {
  if (!obj || typeof obj !== 'object' || Array.isArray(obj)) return obj;
  return Object.keys(obj)
    .filter((k) => obj[k] !== undefined && obj[k] !== null)
    .map((k) => `${encodeURIComponent(k)}=${encodeURIComponent(String(obj[k]))}`)
    .join('&');
}

/**
 * 官方文档里的 `http.fetch(url).success(...).error(...).start()` 链式 AJAX 封装。
 *
 * 我们的 fetch 是**同步**的（重放桥），所以 `.start()` 当场执行并回调，
 * 链式调用的写法与官方一致（不需要真的异步）。
 */
function makeHttpChain(g, postFn) {
  const make = (method, url, initial) => {
    let u = String(url || '');
    let opts = { ...(initial || {}), method };
    let onOk = null;
    let onErr = null;
    const c = {
      headers(h) {
        if (h && typeof h === 'object') opts.headers = { ...(opts.headers || {}), ...h };
        return c;
      },
      success(fn) { onOk = typeof fn === 'function' ? fn : null; return c; },
      error(fn) { onErr = typeof fn === 'function' ? fn : null; return c; },
      start() {
        try {
          let data = method === 'post' ? postFn(u, opts) : g(u, opts);
          // 文档：返回 JSON 会自动 JSON.parse 成对象
          try {
            const t = String(data).trim();
            if (t.startsWith('{') || t.startsWith('[')) data = JSON.parse(t);
          } catch (_) {}
          if (onOk) onOk(data);
        } catch (e) {
          if (onErr) onErr(e && e.message ? e.message : String(e));
        }
        return c;
      },
      fetch(u2, o2) { u = String(u2 || ''); opts = { ...(o2 || {}), method: 'get' }; onOk = null; onErr = null; return c; },
      get(u2, o2) { return c.fetch(u2, o2); },
      post(u2, o2) { u = String(u2 || ''); opts = { ...(o2 || {}), method: 'post' }; onOk = null; onErr = null; return c; },
      request(u2, o2) { return c.fetch(u2, o2); },
      response() { return c; },
    };
    return c;
  };
  return {
    fetch: (url, o) => make('get', url, o),
    get: (url, o) => make('get', url, o),
    request: (url, o) => make('get', url, o),
    post: (url, o) => make('post', url, o),
  };
}

/** JS 的**遗留** `escape` / `unescape`（Node 的 vm 沙箱里默认没有）。 */
function jsUnescape(s) {
  return String(s == null ? '' : s).replace(
    /%u([0-9a-fA-F]{4})|%([0-9a-fA-F]{2})/g,
    (_, u, h) => String.fromCharCode(parseInt(u || h, 16)),
  );
}

function jsEscape(s) {
  return String(s == null ? '' : s).replace(/[^@*_+\-.\/0-9A-Za-z]/g, (c) => {
    const code = c.charCodeAt(0);
    return code < 256
      ? `%${code.toString(16).toUpperCase().padStart(2, '0')}`
      : `%u${code.toString(16).toUpperCase().padStart(4, '0')}`;
  });
}

/// 官方文档里的**裸加密函数**（hiker `assets/help_js.json`「md5」节）：
///   `const a = md5('xxx')`；取文件 MD5：`md5('hiker://files/xxx.zip')`
///
/// ⚠️ 这是**引擎缺口**，不是源的问题：少了裸 `md5`，源在"取 token / 签名"那一步
///    就抛 `md5 is not defined`，整条规则中断 —— 表现在界面上正好是
///    "首页/分类能出，点进去拿不到详情和地址"（实测日志见 2026-10-16 审核）。
///    `sha1/sha256/sha512` 同一族，一起给上（都是 CryptoJS 现成的）。
const BARE_HASH_FNS = {
  md5: 'MD5',
  sha1: 'SHA1',
  sha256: 'SHA256',
  sha512: 'SHA512',
};

function bareHashHex(algo, input, rt) {
  const s = String(input == null ? '' : input);
  const fn = CryptoJS[BARE_HASH_FNS[algo]];
  if (!fn) return '';
  // `hiker://files/…` → 按**文件字节**算（官方文档写法）
  if (s.startsWith('hiker://files/')) {
    try {
      const p = path.join(
          rt && rt.filesDir ? rt.filesDir : '',
          s.slice('hiker://files/'.length));
      const buf = fs.readFileSync(p);
      return fn(CryptoJS.lib.WordArray.create(new Uint8Array(buf))).toString();
    } catch (_) {/* 文件不存在就走字符串分支 */}
  }
  return fn(s).toString();
}

// ============================================================
// 沙箱
// ============================================================

function buildSandbox(rt, state, requireModule, evalPrivateJS) {
  const ctx = rt.ctx;

  const g = (url, opts) => httpSync(rt, url, opts);
  /// 官方 `post(url, 数据, options)`：
  ///   · `post(url, 'a=1&b=2')`            → 原样当表单
  ///   · `post(url, {a:'1', b:'2'})`        → 自动转成 `a=1&b=2`
  ///   · `post(url, {body:{…}, headers:{…}})` → 第二参数其实是整个 options
  const post = (url, body, opts) => {
    if (body && typeof body === 'object' && !Array.isArray(body) &&
        ('body' in body || 'headers' in body || 'header' in body ||
         'method' in body || 'charset' in body)) {
      const merged = { ...(opts || {}), ...body, method: 'post' };
      if (merged.body && typeof merged.body === 'object' && !Array.isArray(merged.body)) {
        merged.body = formEncode(merged.body);
      }
      return g(url, merged);
    }
    return g(url, {
      ...(opts || {}),
      method: 'post',
      body: formEncode(body),
    });
  };
  const cryptoGlobals = buildCryptoGlobals();
  const rsaGlobals = buildRsa();

  /**
   * 写变量的统一入口（官方 JSEngine 的 `putVar/putMyVar` 语义）：
   *   · 非字符串值用 **JSON.stringify** 存（`putMyVar('a', {x:1})` → `'{"x":1}'`；
   *     「探色视频」把域名数组存进 vodhost，后面用 `getMyVar('vodhost').split('"')[1]`
   *     取 URL —— 存成数组对象就会 `split is not a function`）
   *   · 兼容 `putVar({key:'x', value:'1'})` 的对象写法（漫小肆的排序按钮就长这样）
   *   · `storage0.*` 例外：官方明确它用来存 JSON 对象，见下方 storage0
   */
  const kvStr = (v) => (typeof v === 'string' ? v : JSON.stringify(v));
  const kvPut = (k, v) => {
    if (k && typeof k === 'object' && !Array.isArray(k)) {
      const key = k.key ?? k.name;
      const val = k.value ?? k.val;
      if (key == null || val === undefined) return;
      rt.kv[String(key)] = kvStr(val);
      rt.touchedVars = true;
      return;
    }
    if (v === undefined) return;
    rt.kv[String(k)] = kvStr(v);
    rt.touchedVars = true;
  };

  /**
   * `bf(list)` —— 社区源里的"批量抓取"惯例：传 `[{url}]` 或字符串数组，
   * 按**同序**返回每条的响应体（失败给空串）。
   *
   * ⚠️ 每次 fetch 都要引擎重跑整条规则一轮（重放桥），上限 40 轮 ⇒ 这里**封顶 16 条**，
   *    多出来的直接给空串（宁缺不炸，避免整页只出个错误）。
   */
  function batchFetch(list) {
    const arr = Array.isArray(list) ? list : [list];
    const out = [];
    for (let i = 0; i < arr.length; i++) {
      // 文档：数组超过 16 项自动分批；同步实现里超出部分返回空串
      if (i >= 16) {
        out.push('');
        continue;
      }
      const it = arr[i];
      const u = typeof it === 'string' ? it : String((it && (it.url || it.link)) || '');
      // 文档格式：`{url, options:{headers,body,method}}`；也兼容直接把选项摊平
      const oo = (it && typeof it === 'object')
        ? (it.options && typeof it.options === 'object' ? it.options : it)
        : {};
      try {
        out.push(g(u, oo));
      } catch (_) {
        out.push('');
      }
    }
    return out;
  }

  /**
   * `$(url, headers).image(fn, …)` —— **只登记任务**，这里不抓任何东西
   * （见模块顶部 `$.image` 那节：抓图+解密发生在宿主真的来取这张图的时候）。
   */
  function imageRuleImpl(url, headers, fn, extra) {
    const u = String(url == null ? '' : url);
    if (!/^https?:\/\//i.test(u)) return u; // data:/hiker:///空 → 原样
    if (IMAGE_PORT <= 0) return u;          // 还没拿到 mgmt 端口 → 退回原图
    // 源的页面模块源码：一次运行只建一份，多个图片任务共享（供 fn 里的 $.require 用）
    if (!rt.modulesPlain && rt.modules) {
      const plain = {};
      rt.modules.forEach((m, k) => { plain[k] = String((m && m.rule) || ''); });
      rt.modulesPlain = plain;
    }
    const token = registerImageTask(u, headers, fn, extra, rt.modulesPlain);
    return `http://127.0.0.1:${IMAGE_PORT}/hiker/image/${token}`;
  }

  /** jQuery 风格薄包装（覆盖海阔脚本最常用的那几个） */
  function jq(input, headers) {
    const $ = typeof input === 'string' ? cheerio.load(input) : input;
    const asUrl = typeof input === 'string' ? input : '';
    return {
      raw: $,
      find: (sel) => jq($.find ? $.find(sel) : $(sel)),
      text: () => (typeof $ === 'function' ? $('body').text() : $.text()).trim(),
      html: () => (typeof $ === 'function' ? $('body').html() : $.html()),
      attr: (n) => (typeof $ === 'function' ? $('body').attr(n) : $.attr(n)),
      eq: (i) => jq($.eq ? $.eq(i) : $),
      toString: () => (typeof $ === 'function' ? $('body').html() : $.html()),
      // `$('').lazyRule(fn)` —— 延迟规则（见 lazyRuleImpl）
      lazyRule: (fn, ...args) => lazyRuleImpl(rt, ctx, fn, args),
      // `$(url).rule(fn, ...args)` —— hiker 的「局部规则」：点它时执行 fn。
      // 与 lazyRule 共用同一套两趟机制（id 里带上参数签名，避免同规则内多次调用撞车）。
      rule: (fn, ...args) => lazyRuleImpl(rt, ctx, fn, args),
      // ── 同族的"生成链接"API（语义照官方 help_js.json）───────────────
      //   `$(url).input(fn)`            生成**输入框弹窗**链接
      //   `$(url).select(fn)`           生成**选择器弹窗**链接
      //   `$(url,headers).image(fn,s1…)` 生成**图片解密**链接（多带若干参数）
      //   `$(url).x5Rule(fn)`           生成 `javascript:` 链接
      // input/select/x5Rule 与 lazyRule 完全同构（"先给标记地址、点开时再执行"），
      // 共用两趟机制 —— 缺了它们源会直接报 "xxx is not a function"。
      // ⚠️ 只有 `image` 不一样：它**必须当场出结果**（返回图片地址）。
      //   做成延迟规则会让封面变成 `hiker://lazy#…` ⇒ 列表里封面全空
      //   （见上方 `$.image` 那节说明）。
      input: (fn, ...args) => lazyRuleImpl(rt, ctx, fn, args),
      select: (fn, ...args) => lazyRuleImpl(rt, ctx, fn, args),
      image: (fn, ...args) => imageRuleImpl(asUrl, headers, fn, args),
      x5Rule: (fn, ...args) => lazyRuleImpl(rt, ctx, fn, args),
    };
  }

  const jQueryLike = (input, headers) => jq(input, headers);

  const javaNs = buildJavaNs();
  const sandbox = {
    // `java.*` / `Packages.*`：Rhino 的 Java 互操作（有限 shim，见 buildJavaNs）。
    //   ⚠️ 两者都必须是**动态命名空间** —— Rhino 里任意类名都解析得出来，
    //   写死对象会让 `x instanceof java.util.List` 抛
    //   "Right-hand side of 'instanceof' is not an object"（用户 2026-10-15「小霸王」）。
    java: javaNs,
    // `javax.*` 在 Rhino 里是**与 java.\* 平级**的顶层包（源里直接写
    // `javax.crypto.Cipher.getInstance(...)`）—— 少了它这些源会
    // `javax is not defined` 直接炸（实测 野果短剧 / 91短剧）。
    javax: javaNs.javax,
    // `android.*`（Android 专属 API，见 [buildAndroidNs]）
    android: buildAndroidNs(),
    Packages: lazyJavaNs({ java: javaNs }),
    // Rhino 的 importPackage / importClass（公共库 `f` 用 `javaImport.importPackage(...)`）
    // 只是"导入后可以用短类名"，我们的 java shim 已按全限定名支持 ⇒ 空实现即可
    javaImport: {
      importPackage: () => {},
      importClass: () => {},
    },
    importPackage: () => {},
    importClass: () => {},
    // ── 环境 ─────────────────────────────────────────────
    console,
    JSON,
    // ⚠️ `Math` / `Date` 必须是**冻结版**：重放桥每轮重跑整条规则，
    //   若时间/随机数每轮都变，带 timestamp/随机机器码的请求永远不命中缓存
    //   （实测内置源「网页吃瓜」重放 40 轮耗尽）。见 [makeFrozenDate] / [pseudoRandom]。
    //   注意不能写 `{...Math}` —— Math 的属性**不可枚举**，展开是空对象，
    //   那样 `Math.floor` 直接变 undefined（整批源全挂）。
    Math: Object.assign(Object.create(Math), { random: () => pseudoRandom(rt) }),
    Date: makeFrozenDate(rt),
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
    // 官方文档的**裸加密函数**（`const a = md5('xxx')`，见 help_js.json「md5」节）
    // —— 实测有源直接裸调；少了它整条规则在取 token / 签名那步就炸，
    //    表现就是"首页分类能出、点进去拿不到详情和地址"（见 [bareHashHex]）
    md5: (s) => bareHashHex('md5', s, rt),
    sha1: (s) => bareHashHex('sha1', s, rt),
    sha256: (s) => bareHashHex('sha256', s, rt),
    sha512: (s) => bareHashHex('sha512', s, rt),
    // ── 解码兼容层（社区源常用，缺了就是 ReferenceError 整条规则中断）──
    //   `escape/unescape`：JS 遗留函数，vm 沙箱默认没有；
    //     实测「✨91Porn✨」直接 `eval(unescape(…))` 解播放页里的编码串。
    escape: jsEscape,
    unescape: jsUnescape,
    //   `strencode2/strdecode2`：TVBox 血统的 URL 编码对（与 encodeURIComponent 同义）
    strencode2: (s) => encodeURIComponent(String(s == null ? '' : s)),
    strdecode2: (s) => decodeURIComponent(String(s == null ? '' : s)),
    // ── 官方文档「JS里面编解码」的四个裸函数 ─────────────────────
    //   decodeStr/encodeStr 是 **URL 百分号编解码 + 指定字符集**（GBK 站点常用）
    decodeStr: (s, cs) => decodeStrDoc(s, cs),
    encodeStr: (s, cs) => encodeStrDoc(s, cs),
    //   aesEncode/aesDecode：AES/ECB/PKCS5，Base64，密钥补 '0' 到 32 位
    aesEncode: (key, data) => aesEncodeDoc(key, data),
    aesDecode: (key, data) => aesDecodeDoc(key, data),
    //   rsaEncrypt/rsaDecrypt：官方 (data, key, options) 参数顺序
    rsaEncrypt: (data, key, o) => rsaEncryptDoc(data, key, o),
    rsaDecrypt: (data, key, o) => rsaDecryptDoc(data, key, o),
    //   批量抓取（见 [batchFetch]）
    bf: (list) => batchFetch(list),
    // ── RSA（社区源 `$.rsa` / 裸 `rsa` 两种写法都认）──
    rsa: rsaGlobals,
    RSA: rsaGlobals,
    /// 官方文档：16 进制串 → Uint8Array（常搭配 `fetch(url,{toHex:true})`）
    hexToBytes: (h) => {
      const s = String(h == null ? '' : h);
      const out = new Uint8Array(Math.floor(s.length / 2));
      for (let i = 0; i < out.length; i++) {
        out[i] = parseInt(s.substr(i * 2, 2), 16) || 0;
      }
      return out;
    },
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
    /// 搜索关键词（海阔文档里的 `KEY`；实测「91短剧」的 `search()` 第一选择就是它 ——
    /// 少了它源会走到"请输入关键词"分支，搜索永远出不了结果）
    KEY: ctx.action === 'search' ? String(ctx.keyword || '') : '',
    KEYWORD: ctx.action === 'search' ? String(ctx.keyword || '') : '',

    /// 源配置（海阔里用户可填的 `config`）—— 规则里 `config.host` 读的就是它。
    /// 没有配置时给个空对象，让 `config.x` 得到 undefined 而不是
    /// `config is not defined`（后者会让整条规则在加载期就炸掉）。
    config: ctx.config && typeof ctx.config === 'object' ? ctx.config : {},

    /// `input` —— 海阔里"当前输入/当前条目地址"。
    ///
    /// 两个常见用法（实测）：
    ///   · 列表项 url 写成 `条目地址 + $('').lazyRule(fn)`（AVbebe / 7MMTV）⇒
    ///     点它时 fn 里 `fetch(input)` 拿到的就是**前面那截地址**；
    ///   · 输入框规则（`col_type: input`）⇒ fn 里读用户输入的文字。
    /// 以前沙箱里**没有这个全局** ⇒ 这类源点了就报"只支持 http(s) 地址，规则要的是「(空)」"。
    input: ctx.input == null ? '' : String(ctx.input),

    // ── 同步网络 ─────────────────────────────────────────
    fetch: (url, opts) => g(url, opts),
    req: (url, opts) => g(url, opts),
    // `request(url, opts)` 是同步抓取的老名字（实测有源在用）
    request: (url, opts) => g(url, opts),
    post: (url, body, opts) => post(url, body, opts),
    get: (url, opts) => g(url, opts),
    /// 文档：`fetchPC` / `postPC` = 用**电脑端 UA** 的 fetch / post
    fetchPC: (url, opts) => g(url, { ...(opts || {}), ua: UA_PC }),
    postPC: (url, body, opts) => post(url, body, { ...(opts || {}), ua: UA_PC }),
    /// 文档：`fetchCookie(url, options)` → 返回 Set-Cookie 数组的 **JSON 字符串**
    fetchCookie: (url, opts) => {
      try {
        const raw = g(url, { ...(opts || {}), withHeaders: true });
        const j = JSON.parse(raw);
        const h = j.headers || {};
        const ck = h['set-cookie'] || h['Set-Cookie'] || [];
        return JSON.stringify(Array.isArray(ck) ? ck : [ck]);
      } catch (_) {
        return '[]';
      }
    },
    /// 文档：`http.fetch(url).success(fn).error(fn).start()` 链式 AJAX
    http: makeHttpChain(g, post),
    // WebView 抓页（Phase 2）：信号式同步 —— Node 里没有 WebView，
    // 抛 NeedWebView 交给宿主（Dart）去抓，再重放（见 webViewSync）
    fetchCodeByWebView: (input, opts) => webViewSync(rt, input, opts),
    lazyRule: (fn, ...args) => lazyRuleImpl(rt, ctx, fn, args),
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
    setVar: (k, v) => kvPut(k, v),
    putVar: (k, v) => kvPut(k, v),
    /// `putVar2/getVar2`：官方「我的主页」模板（assets/home.js）与大量社区源在用，
    /// 语义与 putVar/getVar 相同（海阔里 2 只是"能存 JSON 字符串"的变体）。
    putVar2: (k, v) => kvPut(k, v),
    getVar2: (k, def) => (rt.kv[k] != null ? rt.kv[k] : (def != null ? def : '')),
    /// `initConfig({host: ...})`：prerule 里写"源配置默认值"的唯一入口。
    /// 用户手填过的键优先（不动用户在「源配置」里改过的值）。
    initConfig: (obj) => {
      if (!obj || typeof obj !== 'object') return;
      if (!ctx.config || typeof ctx.config !== 'object') ctx.config = {};
      for (const k of Object.keys(obj)) {
        if (ctx.config[k] == null || ctx.config[k] === '') ctx.config[k] = obj[k];
      }
    },
    clearVar: (k) => { delete rt.kv[k]; rt.touchedVars = true; },
    /// `setItem/getItem/clearItem`：文档说是"规则内持久存储"（值为字符串）。
    /// 我们这套 kv 本来就是"按规则隔离 + 落盘"，语义一致 ⇒ 同一份实现。
    setItem: (k, v) => kvPut(k, v),
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
    /// `buildUrl(base, {a:1,b:2})` → 拼查询参数（社区源常用）
    buildUrl: (base, params) => {
      const u = String(base == null ? '' : base);
      if (!params || typeof params !== 'object') return u;
      const qs = Object.keys(params)
        .filter((k) => params[k] !== undefined && params[k] !== null)
        .map((k) => `${encodeURIComponent(k)}=${encodeURIComponent(String(params[k]))}`)
        .join('&');
      if (!qs) return u;
      return u + (u.includes('?') ? '&' : '?') + qs;
    },
    /// Android Base64 标志位（crypto-java 垫片会读 `_base64.NO_WRAP`）
    _base64: { NO_WRAP: 2, NO_PADDING: 1, CRLF: 4, URL_SAFE: 8, DEFAULT: 0 },
    /// `updateItem(key, patch)`：官方用于**原地更新已渲染的条目**。
    /// 我们是一次性求值，没有可更新的列表实例 ⇒ 安全占位（返回 true），
    /// 至少不让 `updateItem is not defined` 把整条源打死。
    updateItem: () => true,
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
    setResult: (r) => { state.result = r; if (rt.inLazyFn) rt.lazyCollected = r; },
    setHomeResult: (r) => { state.homeResult = r; if (rt.inLazyFn) rt.lazyCollected = r; },
    /// 文档：`setSearchResult` 与 setResult 等价（软件自动识别回调类型）
    setSearchResult: (r) => { state.result = r; if (rt.inLazyFn) rt.lazyCollected = r; },
    setNextPage: (r) => { state.nextPage = r == null ? '' : String(r); },
    setPageTitle: (r) => { state.pageTitle = r == null ? '' : String(r); },
    setError: (r) => { state.error = r == null ? '' : String(r); },
    clearPublicItem: () => {},
    showLoading: () => {},
    hideLoading: () => {},
    longToast: () => {},
    toast: () => {},
    /// 文档：`alert(文本)` — 弹提示（我们没有原生对话框，落到日志）
    alert: (...a) => console.log('[hiker]', ...a),

    // ── 页面列表的**原地操作**（官方 RuleBean / JSEngine 那批）──────────
    //
    // 我们的规则是**一次性求值**，没有常驻的列表实例，所以这些接口只能做
    // "安全占位" —— 但**必须有**：实测 115 个源里 `deleteItemByCls` 用了 50 次、
    // `deleteItem` 74 次、`addItemBefore` 51 次，几乎都在规则末尾清 loading 占位。
    // 少了它们 → `xxx is not defined` → 整条规则中断（列表出不来）。
    deleteItem: () => true,
    deleteItemByCls: () => true,
    addItem: () => true,
    addItemBefore: () => true,
    addItemAfter: () => true,
    // 读已渲染条目：没有实例 ⇒ 返回空（调用方通常只做兜底/判断）
    findItem: () => null,
    findItemsByCls: () => [],

    // ── 剪贴板 / 云剪贴板（社区源做"分享导入"用）────────────────
    copy: () => true,
    /// `getPastes()` 官方返回 JSON 数组（可同步的云剪贴板列表）⇒ 无实现给空数组
    getPastes: () => [],
    /// `parsePaste(口令)` → 解析后的规则文本；没有云剪贴板 ⇔ 返回空串
    parsePaste: () => '',
    /// `sharePaste(内容, 剪贴板)` → 分享后的地址；没有云剪贴板 ⇔ 返回空串
    sharePaste: () => '',

    // ── 页面元信息 / 导航（文档「JS里面常用方法」）────────────────
    getPageTitle: () => state.pageTitle || '',
    setPagePicUrl: () => true,
    setPageParams: (p) => { state.pageParams = p; return true; },
    /// 二级页动态设置"最新章节"规则：只记录，收藏页由宿主另走
    setLastChapterRule: (r) => { state.lastChapterRule = r == null ? '' : String(r); return true; },
    /// 关闭当前页（文档：二级页面才有效）—— 宿主没有回传通道 ⇒ 返回 false
    back: () => false,
    closeMe: () => true,
    /// 选择器弹窗（官方弹原生选择框）：无 UI ⇒ 占位成功
    showSelectOptions: () => true,
    /// 打开外部 App（迅雷等）：本模块不调起第三方 App
    openAppIntent: () => false,

    // ── 规则/版本信息（文档）────────────────────────────────
    getAppVersion: () => 1800,
    getRuleCount: () => '1',
    getColTypes: () => [],
    getLastRules: () => [],
    getHomeSub: () => [],
    hasHomeSub: () => false,

    // ── 缓存 / 文件 / 网络杂项（社区源高频）──────────────────────
    /// `cacheM3u8(url)` 官方会下到本地再返回本地地址；我们无法在同步规则里下载，
    /// 直接返回原地址（播放链路仍然可用，只是没有本地缓存）
    cacheM3u8: (url) => String(url == null ? '' : url),
    clearM3u8Ad: () => true,
    deleteCache: () => true,
    fetchCache: () => '',
    downloadFile: () => false,
    /// `deleteFile(path)` → 真删（收敛在 hiker 目录内）
    deleteFile: (p) => {
      try {
        const f = safePath(rt, String(p == null ? '' : p));
        if (fs.existsSync(f)) fs.unlinkSync(f);
        return true;
      } catch (_) {
        return false;
      }
    },
    /// `saveImage(url, path)` 依赖异步下载 ⇒ 占位失败（不中断规则）
    saveImage: () => false,
    /// 全局代理读取（部分源用它拼提示；本模块代理由宿主统一应用）
    getProxy: () => '',
    requireDownload: () => false,
    /// DNS 相关：Node 走系统 DNS，注册/探测做成无副作用的安全实现
    registerDNS: () => true,
    ipping: () => true,
    findReachableIP: (ips) => (Array.isArray(ips) && ips.length ? String(ips[0]) : ''),
    unRegisterTask: () => true,
    /// 规则里常见的 `sleep(ms)`；同步求值里不能真睡（会卡死 Node 事件循环的最后机会）
    sleep: () => {},

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
      // ⚠️ 文件**不存在**不是错误（首次运行、可选配置、缓存文件都这样）。
      //    原来在这里抛异常，导致「阅漫君 / 阅动漫」这种在规则顶部直接
      //    `readFile('newWindow')` 的源一打开就整条崩（2026-10-17 实测）。
      //    目录 / 过大 / 权限问题仍由 readTextChecked 抛出，不掩盖真错误。
      if (t == null) return '';
      return t;
    },
    /// `fileExist(path)`：文件 / 源内页面模块是否存在（社区源常用作首次运行判断）
    fileExist: (p) => sandboxFileExist(rt, p),
    fileExists: (p) => sandboxFileExist(rt, p),
    existsFile: (p) => sandboxFileExist(rt, p),
    /// `getPath('hiker://files/x')` → **真实文件系统路径**（官方带 `file://` 前缀）
    ///
    /// 源里的常见写法是 `getPath(...).replace(/^file:\/\//, '')` 或 `.slice(7)`，
    /// 再交给 `java.io.File(...)` / `require(...)` 用 —— 所以这里必须返回
    /// `file://` + 绝对路径（少这个函数会让「聚图库 / 星集Media / 某聚合 /
    /// MyField」这类源在第一步就 `getPath is not defined`）。
    getPath: (p) => {
      try {
        return `file://${safePath(rt, String(p == null ? '' : p))}`;
      } catch (_) {
        return '';
      }
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
    getParam: (k, def) => {
      const p = ctx.params || {};
      if (p[k] != null) return String(p[k]);
      try {
        const u = new URL(String(ctx.url || ''));
        if (u.searchParams.has(String(k))) return String(u.searchParams.get(k));
      } catch (_) {}
      return def != null ? def : '';
    },
    getMyVar: (k, def) => (rt.kv[k] != null ? rt.kv[k] : (def != null ? def : '')),
    putMyVar: (k, v) => kvPut(k, v),
    setMyVar: (k, v) => kvPut(k, v),
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
      lazyRule: (fn, ...args) => lazyRuleImpl(rt, ctx, fn, args),
      html: (h) => jq(cheerio.load(String(h || ''))),
      md5: (s) => CryptoJS.MD5(String(s)).toString(),
      sha1: (s) => CryptoJS.SHA1(String(s)).toString(),
      sha256: (s) => CryptoJS.SHA256(String(s)).toString(),
      // ── 加解密别名（社区源三种写法都有：`$.aes` / `$.AES` / 裸 `AES`）──
      //   语义与官方 aes.js 注入的全局完全一致（含 `"AES/CBC/PKCS7Padding"` 字符串配置）
      aes: cryptoGlobals.AES,
      AES: cryptoGlobals.AES,
      des: cryptoGlobals.DES,
      DES: cryptoGlobals.DES,
      tripledes: cryptoGlobals.TripleDES,
      TripleDES: cryptoGlobals.TripleDES,
      rsa: rsaGlobals,
      RSA: rsaGlobals,
      CryptoJS: cryptoGlobals.CryptoJS,
      escape: jsEscape,
      unescape: jsUnescape,
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
      /// 模块导出约定：`$.exports = xxx;` 或 `$.exports.xxx = ...`
      /// —— 海阔的源页面模块就是这么把值交出去的（`main` / `xiu` 等模块名
      ///    与内部变量名常常不一致，只能靠 exports 取），见 [runInModuleScope]
      ///
      /// ⚠️ 默认必须是对象：大量模块写 `$.exports.fn = ...`，默认 undefined
      ///    会直接报 "Cannot set properties of undefined"（探色视频 / 摸鱼日报）。
      exports: {},
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
  // 执行某段 lazyRule 时，宿主会把"条目地址"（`URL + hiker://lazy#id` 里前面那截）
  // 作为 `lazyInput` 传进来，这里临时替换全局 `input`（见 [lazyRuleImpl]）
  rt.inputBase = ctx.input == null ? '' : String(ctx.input);
  rt.setInput = (v) => {
    sandbox.input = v == null ? '' : String(v);
  };
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
 * Rhino 语法兼容：单语句上下文里的 `let/const`。
 *
 * Rhino 的 `let` 是**函数作用域**，所以 `if (x) let y = …;` 合法；
 * V8 会直接报 "Lexical declaration cannot appear in a single-statement context"。
 * 实测 mistywater/hiker 的公共库 `f`（`libs/bf286…js`）里就有这种写法，
 * 不修的话 `rc()` 一加载就 SyntaxError，整个源报废。
 *
 * 只把 `) let/const` 与 `else let/const` 换成 `var`（语义按 Rhino 的函数作用域，
 * 反而更接近）；正常的 `for (let i…)` / `{ let x }` 不会被命中。
 */
function fixRhinoLexical(code) {
  let s = String(code == null ? '' : code);
  // 论坛复制来的规则常夹带**零宽字符**（U+200B..200F / 202A..202E / 2060..206F / FEFF），
  // Rhino 容忍、V8 直接 "Invalid or unexpected token"。实测公共库 `f` 的
  // `Math.ceil` 中间就夹了 U+200C。
  s = s.replace(/[\u200B-\u200F\u202A-\u202E\u2060-\u206F\uFEFF]/g, '');
  s = s.replace(/([)\]]\s*)(let|const)\s+/g, '$1var ');
  s = s.replace(/(\belse\s+)(let|const)\s+/g, '$1var ');
  return s;
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
  // ⚠️ 海阔导出的 `pages` 是**JSON 字符串**（而不是数组）—— Dart 侧已解开，
  //    但引擎也要能吃字符串，否则 `$.require('er')` / `hiker://page/lunbo`
  //    全部查不到（实测漫小肆的目录页就是这种情况）。
  let pageList = source && source.pages;
  if (typeof pageList === 'string') {
    try { pageList = JSON.parse(pageList); } catch (_) { pageList = []; }
  }
  for (const p of Array.isArray(pageList) ? pageList : []) {
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
          try {
            rt.cache.set(e.key, await doHttp(rt, e.url, e.opts));
          } catch (err) {
            rt.failedFetches.set(e.key, fetchFailureError(e.url, err));
          }
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
    // 每轮复位"被吞掉的抓页意图"（由 httpSync / webViewSync 记录，见下面那道闸门），
    // 随机数序列也归零 —— 这样各轮走到同一行代码时拿到的随机值一致（见 [pseudoRandom]）
    rt.wantFetch = null;
    rt.randSeq = 0;
    // 每轮复位"这一趟执行的 lazyRule 产物"（见 [lazyRuleImpl]）
    rt.lazyOutcome = null;
    rt.lazyCollected = undefined;
    rt.lazyDepth = 0;
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
      /// 是否走了"名字对不上、用唯一模块兜底"这条路
      /// （兜底时按名字取绑定必然取不到 ⇒ 要返回**整个导出对象**）
      let nameFallback = false;
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
        // `$.require('hiker://assets/xxx.js')` / `hiker://files/...`：
        // 官方允许直接 require 一个 JS 文件（例如 `crypto-java.js`）。
        // 之前只查源内 pages ⇒ 这类源在第一步就失败。
        // ⚠️ 必须用**原始** name（moduleCandidates 会把 hiker://assets/ 前缀剥掉）
        const rawName = String(name || '').trim();
        if (/^hiker:\/\/(?:assets|files)\//i.test(rawName)) {
          try {
            const code = hikerFetch(rt, rawName);
            return normalizeModuleValue(
              runInModuleScope(sandbox, code, ''), rawName);
          } catch (e) {
            throw moduleError(
              `$.require('${rawName}') 加载失败：${describeError(e)}`);
          }
        }
        // 兼容：社区源偶尔把模块名写错（「声阅APP」`$.require('hanshu')`，
        // 但它的 pages 里只有一个叫「函数」的模块，模块本身导出的对象里
        // 确实有规则要调的 `tuijian1`）。只有一个模块时直接用它 ——
        // 总比一句"找不到模块"让整条源报废合理。
        if (modules.size === 1) {
          const only = modules.entries().next().value;
          if (only) {
            mod = only[1];
            key = only[0];
            nameFallback = true;
          }
        }
        if (!mod) {
          throw moduleError(
            `$.require('${String(name || '')}') 找不到对应的 pages 模块`
            + '（该源依赖海阔内置页面模块 / 宿主文件，暂不支持）',
          );
        }
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
        //  ⚠️ 名字兜底时 wantName 传空：按错误的名字取绑定必然取不到，
        //     传空才会返回**整个导出对象**（`require('x').fn()` 才能拿到 fn）。
        value = runInModuleScope(sandbox, mod.rule, nameFallback ? '' : key);
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
      // ⚠️ 模块自己把抓页异常 try/catch 吞了（源头常见的
      //   `try { var html = getResCode() } catch(e) { … return; }`）⇒ 模块返回 undefined。
      //   这时**不能直接报"没取到值"**：那一页本来就还没抓，引擎的 wantFetch 闸门
      //   会在本轮结束后补抓并重放。先给个空对象让规则跑完这一轮（实测漫小肆的
      //   目录模块 `er` 正是这种写法）。
      if (value === undefined && rt.wantFetch) {
        moduleCache.set(cacheKey, {});
        return {};
      }
      // 同理：延迟规则**已经拿到结果**时，外层模块后续的报错不该把结果作废
      //（典型场景：第二趟解章节图时，目录模块又去抓详情页，网络抖一下 →
      //  本来已经拿到的 `pics://` 被一句"没取到值"顶掉）
      if (value === undefined && rt.lazyOutcome
          && rt.lazyOutcome.returned !== undefined
          && rt.lazyOutcome.returned !== null) {
        moduleCache.set(cacheKey, {});
        return {};
      }
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
          return vm.runInContext(fixRhinoLexical(stripJsPrefix(pj)), sandbox,
            { timeout: SCRIPT_TIMEOUT_MS });
        }
        throw e;
      }
    };

    const sandbox = vm.createContext(buildSandbox(rt, state, requireModule, evalPrivateJS));

    try {
      // 不包 IIFE：保持海阔「顶层 var/const/function 即全局」的语义
      new vm.Script(fixRhinoLexical(rule), { filename: 'hiker_rule.js' })
        .runInContext(sandbox, { timeout: SCRIPT_TIMEOUT_MS });
    } catch (e) {
      if (e instanceof NeedFetch) {
        // ⚠️ 抓失败**不要直接冲出去**：记下来、重放一轮，让规则自己的
        //   `try { fetch(...) } catch(e) { 换线路/兜底 }` 能生效（见 [httpSync]）
        try {
          rt.cache.set(e.key, await doHttp(rt, e.url, e.opts));
        } catch (err) {
          rt.failedFetches.set(e.key, fetchFailureError(e.url, err));
        }
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
        try {
          const html = await opts.fetchWebView(e.url, e.opts);
          rt.cache.set(e.key, html == null ? '' : String(html));
        } catch (err) {
          rt.failedFetches.set(e.key, fetchFailureError(e.url, err));
        }
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
        try {
          const html = await opts.fetchWebView(w.url, w.opts);
          rt.cache.set(w.key, html == null ? '' : String(html));
        } catch (err) {
          rt.failedFetches.set(w.key, fetchFailureError(w.url, err));
        }
        pending.push(`webview:${w.url}`);
      } else {
        try {
          rt.cache.set(w.key, await doHttp(rt, w.url, w.opts));
        } catch (err) {
          rt.failedFetches.set(w.key, fetchFailureError(w.url, err));
        }
        pending.push(w.url);
      }
      continue; // 重放：让规则拿到真页面（或看到抓取失败的异常）
    }

    if (state.error) throw new Error(String(state.error));
    let raw = state.homeResult !== undefined ? state.homeResult : state.result;
    // 这一趟是"执行某个 lazyRule"（带 lazyId 的那次）⇒ **产物以那段 JS 为准**：
    //   海阔点分类/详情/立即播放时只跑那一段，而我们是重跑整条规则，
    //   外层规则随后自己的 setResult(首页列表) 会把它盖掉（实测「91短剧」点剧集拿不到详情）。
    const lo = rt.lazyOutcome;
    if (lo) {
      const ret = lo.returned;
      const retLooksNoop = typeof ret === 'string'
        && (ret.trim() === '' || ret.trim().startsWith('hiker://empty') || ret.trim().startsWith('hiker://lazy#'));
      if (ret !== undefined && ret !== null && !retLooksNoop) {
        raw = ret;
      } else if (lo.result !== undefined && lo.result !== null) {
        raw = lo.result;
      }
    }
    let list = extractItems(raw, source && source.col_type, maxItems);
    // setPreResult 的"前段结果"要**排在前面**（文档：先返回上半屏、后面再追加）
    if (state.preResult !== undefined && state.preResult !== null) {
      const pre = extractItems(state.preResult, source && source.col_type, maxItems);
      if (pre.length) list = [...pre, ...list].slice(0, maxItems || MAX_ITEMS);
    }
    // 详情规则常见写法：只 setResult 一条（或直接 setResult('播放地址')）
    let playUrl = '';
    let playHeaders = null;
    let playUrlExtra = [];
    // 官方允许 lazyRule/详情规则**直接 return 一个对象**（实测「探色视频」：
    //   `return {urls:[…]}`）。对象进不了下面的字符串分支 ⇒ 播放地址被丢掉，
    //   现象是"点进去什么都没发生"。有 urls/url 就先转成 JSON 串统一处理。
    if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
      const ou = Array.isArray(raw.urls) ? raw.urls : (raw.url ? [raw.url] : []);
      if (ou.length) raw = JSON.stringify(raw);
    }
    if (typeof raw === 'string') {
      const s = raw.trim();
      if (isPlayableAddr(s)) {
        // `x5://` / `x5Play://` 只剥外壳；`pics://` / `novel://` 原样交给宿主分流
        playUrl = stripOuterScheme(s);
      } else if (s.startsWith('{')) {
        // 海阔的「播放地址」JSON 约定（实测 91短剧 / 野果短剧 的 playRule() 都返回它）：
        //   {"urls":["…m3u8","备用"],"names":["HLS"],"headers":{"Referer":"…"},"parse":0}
        // 原来只认纯 http 字符串 ⇒ 这类源的"立即播放"永远拿不到地址（点下去没反应）。
        try {
          const o = JSON.parse(s);
          const urls = Array.isArray(o.urls) ? o.urls : (o.url ? [o.url] : []);
          const first = urls.find((u) => isPlayableAddr(u));
          if (first) playUrl = stripOuterScheme(String(first));
          // 备用清晰度也带上，播放失败时可换（宿主会顺延同集其它候选）
          if (urls.length > 1) {
            playUrlExtra = urls.slice(1).map((u) => String(u)).filter((u) => isPlayableAddr(u));
          }
          if (o.headers && typeof o.headers === 'object') {
            playHeaders = {};
            for (const k of Object.keys(o.headers)) playHeaders[k] = String(o.headers[k]);
          }
        } catch (_) { /* 不是 JSON 就当普通文本，交给下面的兜底 */ }
      }
    }
    if (!playUrl && list.length === 1 && list[0].url) playUrl = list[0].url;
    return {
      list,
      playUrl,
      playHeaders,
      playUrlExtra,
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

/**
 * 执行条目地址里的**内联规则**：`url#flags#@rule=js:<code>` / `@lazyRule=.js:<code>`。
 *
 * 海阔的「二级页面」很多不是独立页面，而是把 JS 挂在条目地址上：
 *   漫画条目 → `章节页 + '@rule=js:$.require("er")'`
 *   章节条目 → `图片页 + 'hiker://lazy#id'`（id 来自同一次执行里的 `解析` 模块）
 *
 * 我们把它当成一次普通规则执行：
 *   · `input` / `MY_URL` = 去掉 `@rule=` 尾巴的原始地址
 *   · 预加载 `lazy` 模块（很多二级页直接引用 `lazy` 变量却不 require 它）
 *   · 支持 `lazyIds` 第二趟（解析章节里的图片列表）
 */
export async function runHikerInline(source, ctx, kv, opts = {}) {
  const code = String(ctx.code || '')
    .replace(/^\s*(?:\.js|js):\s*/i, '')
    .trim();
  if (!code) {
    return { list: [], playUrl: '', nextPage: '', pageTitle: '', vars: kv || {} };
  }
  const base = String(ctx.url || '');
  // ⚠️ 第二趟的 `input` 是**章节页**（lazy fn 里 fetch(input) 要抓的那一页），
  //    不是条目自身地址 —— 两者混用会让漫画的 lazy 规则去抓详情页、抓不出图。
  const swapInput = String(ctx.lazyInput || '');
  const prelude = "try { $.require('lazy'); } catch (__e) {}\n";
  return await runHikerRule(source, {
    ...ctx,
    url: base,
    input: base,
    rule: `js:${prelude}${code}`,
    action: 'detail',
    lazyInput: swapInput,
    lazyIds: Array.isArray(ctx.lazyIds) ? ctx.lazyIds : [],
  }, kv, opts);
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

  // fy* 占位符（海阔/TVBox 风格的筛选位）：`fyclass` 用当前选中分类，
  // 没选就是空；`fyarea/fyyear/fysort` 同理。之前一律原样留着，
  // 地址里就会出现字面量 "fyclass"，站点必然 404（实测多个源因此首页为空）。
  const cate = o.cate != null ? String(o.cate) : '';
  const subs = (x) => String(x)
    .replace(/\*\*/g, encodeURIComponent(keyword))
    .replace(/fypage/g, String(page))
    .replace(/fyclass/g, cate)
    .replace(/fyarea|fyyear|fysort/g, '');

  const params = {};
  let url = subs(urlPart);
  let rawOut = '';
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
    // `MY_URL` 要保留**规则原文**（含 `hiker://empty##`）：
    //   大量源写 `MY_URL.replace('hiker://empty##', host)` 拼真地址，
    //   剥掉伪协议后规则拿到空串 ⇒ fetch('') 直接失败（实测 20+ 个源）。
    rawOut = url;
    url = '';
  } else if (url) {
    // ① URL 字段可能带 `.js:` 规则（动态域名）→ 先求值出真地址
    url = evalUrlRule(url, o.kv);
    // ② 相对路径 → 用源的 url 补成绝对地址
    //    （实测 9 个源的 search_url 写的是 `/search?q=**&page=fypage`）
    url = absolutize(url, o.base);
    rawOut = url;
  }
  return { url, raw: rawOut, method, charset, headers, params };
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

    // ── 前置规则 `prerule`（海阔打开源时先执行，然后才跑 find_rule）────────
    //   典型写法：抓发布页找最新域名 → `setItem('link', …)` 记住 →
    //   `initConfig({host: …})` 写进配置。主规则里的 `config.host`、
    //   以及 `getVar('18AV')` 这类动态域名全靠它。
    //   ⚠️ 必须在 `evalUrlRule(homeBase)` **之前**跑：动态域名源的 URL 规则
    //      依赖 prerule 写下的变量（否则算出 `https:///zh/…` 直接判死）。
    //   失败不阻断主规则（海阔里它只是"准备域名/配置"）。
    const preRule = String(source.preRule || source.pre_rule || source.prerule || '').trim();
    if (preRule && action !== 'event' && action !== 'inline') {
      try {
        const preRun = await runHikerRule(source, {
          url: String(source.url || ''),
          name: source.title || source.name || '',
          page: 1,
          cateUrl: '',
          cateName: '',
          keyword: '',
          lazyInput: '',
          action: 'home',
          params: {},
          ua,
          config: cfg,
          homeUrl: String(source.url || ''),
          rule: /^\s*js:/i.test(preRule) ? preRule : (`js:${preRule}`),
          filesDir: opts.filesDir,
          assetsDir: opts.assetsDir,
        }, kv, {
          ...opts,
          timeoutMs: Math.min(opts.timeoutMs, 20000),
          maxItems: 1,
          fetchWebView: fetchViaHostWebView,
        });
        // runHikerRule 内部是 kv 的**副本**，要把 prerule 写的变量并回调用方的 kv
        if (preRun && preRun.vars && typeof preRun.vars === 'object') {
          Object.assign(kv, preRun.vars);
        }
      } catch (e) {
        console.log('[hiker] prerule 跳过：' + describeError(e));
      }
    }

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

    if (action === 'inline') {
      // 条目地址里的内联规则：`@rule=js:<code>` / `@lazyRule=.js:<code>`
      //   body: { action:'inline', source, params:{ url, code, lazyIds?, lazyInput? }, vars }
      const r = await runHikerInline(
        source,
        {
          url: String(params.url || ''),
          lazyInput: String(params.lazyInput || ''),
          code: String(params.code || ''),
          name: source.title || source.name || '',
          page: params.page || 1,
          ua,
          config: cfg,
          homeUrl: homeBase,
          filesDir: opts.filesDir,
          assetsDir: opts.assetsDir,
          lazyIds: Array.isArray(params.lazyIds) ? params.lazyIds.map(String) : [],
        },
        kv,
        { timeoutMs: opts.timeoutMs, maxItems: opts.maxItems },
      );
      return {
        ok: true,
        list: r.list || [],
        playUrl: r.playUrl || '',
        playHeaders: r.playHeaders || null,
        playUrlExtra: r.playUrlExtra || [],
        nextPage: r.nextPage || '',
        pageTitle: r.pageTitle || '',
        vars: r.vars || kv,
        requests: r.requests || 0,
        lazyIds: r.lazyIds || [],
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
      // 搜索地址也可能是 `hiker://empty##search/**/fypage/`（MY_URL 由规则拼）
      ctxUrl = r.raw || r.url;
      envParams = { ...r.params, ...envParams };
      if (r.headers && r.headers['User-Agent']) ua = r.headers['User-Agent'];
    } else if (action === 'detail') {
      rule = String(source.detail_find_rule || source.detailFind || '');
      ctxUrl = String(params.url || '');
    } else {
      // home / category：`source.url` 是首页地址；分类走传入的 class_url
      // ⚠️ `MY_URL` 必须保留**规则原文**（含 `hiker://empty##` 前缀）——
      //    大量源靠 `MY_URL.replace('hiker://empty##', config.host)` 拼地址。
      //    分类地址是相对片段时（`page` / `category/xx`）也按同样格式拼回去。
      const cateRaw = params.url ? String(params.url) : '';
      const r = parseRuleUrl(cateRaw || source.url || '', {
        page: params.page || 1,
        kv,
        base: homeBase,
        cate: cateRaw,
      });
      rule = String(source.find_rule || source.findRule || '');
      if (cateRaw) {
        ctxUrl = /^(?:https?|hiker):\/\//i.test(cateRaw)
          ? cateRaw
          : `hiker://empty##${cateRaw}`;
      } else {
        ctxUrl = r.raw || r.url || '';
      }
      envParams = { ...r.params, ...envParams };
    }

    if (!rule) {
      // 没有规则：把传入的 url 当播放地址（很多源的列表项本身就是直链/播放页）
      let playUrl = stripOuterScheme(ctxUrl);
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
      /// 搜索关键词（规则里 `KEY` 读它，见沙箱里的 KEY / KEYWORD）
      keyword: String(params.keyword || ''),
      /// 这条 lazyRule 的"输入"（海阔里 `条目地址 + hiker://lazy#id` 的前面那截）
      lazyInput: String(params.lazyInput || ''),
      /// 本次动作（`MY_TYPE` 用它：home/search/detail）
      action,
      params: envParams,
      ua,
      /// 延迟规则链条：`[父id, …, 目标id]`（宿主点嵌套条目时把链条带上，
      /// 引擎逐层执行，见 [lazyRuleImpl]）。老的单 id 写法继续支持。
      lazyIds: (() => {
        const out = [];
        if (Array.isArray(params.lazyIds)) {
          for (const x of params.lazyIds) {
            const s = String(x || '').trim();
            if (s) out.push(s);
          }
        }
        if (!out.length && params.lazyId) out.push(String(params.lazyId).trim());
        return out;
      })(),
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
      /// 播放请求头（海阔播放 JSON 里的 `headers`，防盗链要用）
      playHeaders: r.playHeaders || null,
      /// 同集备用地址（同 JSON 里的 urls[1..]，播放失败时可顺延）
      playUrlExtra: r.playUrlExtra || [],
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
