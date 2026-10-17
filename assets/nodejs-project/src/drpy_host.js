/**
 * drpy 标准源宿主适配层（TVBox / CatVod 生态）
 *
 * ── 解决什么 ────────────────────────────────────────────────────
 * TVBox 里大量 `type:3` 线路写成：
 *   api = …/drpy2.min.js      ← 规则运行时（不是可独立运行的 spider 服务）
 *   ext = …/某某影视.js       ← 站点规则（`var rule = {...}`）
 *
 * 这种组合**不能**直接丢给 `loadSource()`：drpy2.min.js 只是一个模块，
 * 不会注册 `/config` / `/spider/...` 路由。本文件把它包成一个标准
 * CatVod spider 服务：
 *   GET  /config
 *   GET  /proxy?do=js&…
 *   POST /spider/<key>/<type>/{init,home,homeVod,category,detail,play,search}
 *
 * ── 同步 HTTP 怎么解决（关键取舍）────────────────────────────────
 * drpy2 的 `request()` 是**同步**的（它内部调用宿主注入的 `req()`）。
 * iOS 上的 NodeMobile 没有 worker_threads，也没有 spawn，无法真阻塞。
 * 所以这里用与海阔引擎同款的「抓页重放」：
 *   · `req()` 命中缓存 → 直接返回；
 *   · 未命中 → 记录到 pending，先返回空响应让脚本继续跑；
 *   · 脚本跑完后发现 pending 非空 → 异步抓这些地址 → **重跑同一动作**。
 * 因为 URL 基本由入参决定，几轮内必然收敛（有轮数上限兜底）。
 * 相比抛异常，这种方式不会被 drpy 自己的 try/catch 吞掉。
 *
 * ── 依赖注入 ───────────────────────────────────────────────────
 * 运行时本身是 ESM（import cheerio / crypto-js / 模板 / gbk），
 * 这里在加载前把 import/export 改写成普通脚本，并注入：
 *   cheerio（含 jinja2）、CryptoJS、模板{muban,getMubans}、
 *   gbkTool、local（getItem/setItem 存储）、req（同步网络）、joinUrl
 */

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import axios from 'axios';
import * as cheerioNs from 'cheerio';
import CryptoJS from 'crypto-js';
import iconv from 'iconv-lite';
import { JSONPath } from 'jsonpath-plus';

const cheerio = cheerioNs.default ?? cheerioNs;

const MOBILE_UA =
  'Mozilla/5.0 (Linux; Android 11; M2007J3SC Build/RKQ1.200826.002; wv) '
  + 'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/94.0.4606.85 '
  + 'Mobile Safari/537.36';

const MAX_REPLAY = 24;
const FETCH_TIMEOUT_MS = 12000;

/** 当前驻留的 drpy 源（单槽位，与 Node 引擎保持一致） */
let current = null;

// ============================================================
// 代码预处理
// ============================================================

/** 去掉 ESM import，把 `export default{…}` 改成普通变量 */
function prepareRuntime(code) {
  let s = String(code || '');
  // 所有 import 都在文件最前面（以分号结尾）
  s = s.replace(/^(?:\s*import[^;]+;)+/, '');
  s = s.replace(/export\s+default\s*\{/, 'var __DRPY_EXPORT = {');
  // 运行时的 catch 只打 e.message，排查时看不到行号；换成带 stack
  s = s.replace(/console\.log\(e\.message\)/g, 'console.log((e&&e.stack)||e.message)');
  return s;
}

/** 模板库：`export default {muban,getMubans};` → 取对象 */
function prepareMuban(code) {
  let s = String(code || '');
  s = s.replace(/export\s+default\s*\{[^}]*\}\s*;?/, '');
  s += '\n;globalThis.__MUBAN_EXPORT = { muban: muban, getMubans: getMubans };';
  return s;
}

/** 站点脚本：把 `var rule =` 统一改成全局赋值（drpy 的 init 只认这种） */
function normalizeRuleCode(code) {
  return String(code || '').replace(/\b(var|let|const)\s+rule\b/, 'rule');
}

// ============================================================
// 宿主注入的小工具
// ============================================================

/** drpy 的 `cheerio.jinja2(tpl, ctx)`：只做 `{{表达式}}` 替换 */
function jinja2(tpl, ctx) {
  return String(tpl == null ? '' : tpl).replace(/\{\{([\s\S]*?)\}\}/g, (_, expr) => {
    try {
      const keys = Object.keys(ctx || {});
      const fn = new Function(...keys, 'return (' + expr + ');');
      const v = fn(...keys.map((k) => ctx[k]));
      return v == null ? '' : String(v);
    } catch (_) {
      return '';
    }
  });
}

/** gbk 编码/解码（drpy 的 encodeStr/decodeStr 用） */
function makeGbkTool() {
  return () => ({
    encode: (s) => {
      const buf = iconv.encode(String(s == null ? '' : s), 'gbk');
      let out = '';
      for (const b of buf) out += '%' + b.toString(16).toUpperCase().padStart(2, '0');
      return out;
    },
    decode: (s) => {
      const str = String(s == null ? '' : s);
      const bytes = [];
      for (let i = 0; i < str.length; i++) {
        if (str[i] === '%' && /^[0-9A-Fa-f]{2}$/.test(str.slice(i + 1, i + 3))) {
          bytes.push(parseInt(str.slice(i + 1, i + 3), 16));
          i += 2;
        } else {
          bytes.push(...Buffer.from(str[i], 'utf8'));
        }
      }
      return iconv.decode(Buffer.from(bytes), 'gbk');
    },
  });
}

/** 相对地址补全（drpy 的 joinUrl） */
function joinUrl(from, to) {
  const t = String(to == null ? '' : to).trim();
  if (!t) return '';
  if (/^https?:\/\//i.test(t)) return t;
  try {
    return new URL(t, String(from || '')).toString();
  } catch (_) {
    return t;
  }
}

/** 本地键值存储（drpy 的 getItem/setItem → `local`） */
function makeLocal(dataDir) {
  const file = path.join(dataDir || '.', 'drpy_kv.json');
  let db = {};
  try {
    if (fs.existsSync(file)) db = JSON.parse(fs.readFileSync(file, 'utf8')) || {};
  } catch (_) {
    db = {};
  }
  let saveTimer = null;
  const save = () => {
    if (saveTimer) return;
    saveTimer = setTimeout(() => {
      saveTimer = null;
      try {
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(file, JSON.stringify(db));
      } catch (_) { /* 存储失败不影响主流程 */ }
    }, 200);
  };
  return {
    get(ruleKey, k) {
      const bucket = db[String(ruleKey)] || {};
      return Object.prototype.hasOwnProperty.call(bucket, String(k))
        ? bucket[String(k)]
        : undefined;
    },
    set(ruleKey, k, v) {
      const rk = String(ruleKey);
      if (!db[rk]) db[rk] = {};
      db[rk][String(k)] = v;
      save();
    },
    delete(ruleKey, k) {
      const bucket = db[String(ruleKey)];
      if (bucket) {
        delete bucket[String(k)];
        save();
      }
    },
  };
}

// ============================================================
// DOM 解析：drpy 的 pdfh / pdfa / pd（`&&` 取值 DSL）
// ============================================================

function parseParts(rule) {
  return String(rule == null ? '' : rule)
    .split('&&')
    .map((s) => s.trim())
    .filter((s) => s !== '');
}

function selectIn($, sel, scope) {
  let nodes = scope ? scope.find(sel) : $.root().find(sel);
  if (!nodes || nodes.length === 0) {
    // 片段本身就是目标节点（pdfa 返回的是 outerHTML）
    try {
      nodes = $.root().children(sel);
    } catch (_) { /* 选择器非法 */ }
  }
  return nodes;
}

/** 取列表：返回 outerHTML 数组（后续 pdfh 可继续解析） */
function pdfa(html, rule) {
  const parts = parseParts(rule);
  if (parts.length === 0) return [];
  let $;
  try {
    $ = cheerio.load(String(html == null ? '' : html), { decodeEntities: false });
  } catch (_) {
    return [];
  }
  let nodes = null;
  for (const p of parts) {
    if (/^(Text|text|Html|html)$/.test(p)) break;
    nodes = selectIn($, p, nodes);
    if (!nodes || nodes.length === 0) return [];
  }
  return nodes ? nodes.toArray().map((n) => $.html(n)) : [];
}

/** 取单值：`选择器&&选择器&&Text|Html|属性名` */
function pdfh(html, rule) {
  const parts = parseParts(rule);
  if (parts.length === 0) return '';
  let $;
  try {
    $ = cheerio.load(String(html == null ? '' : html), { decodeEntities: false });
  } catch (_) {
    return '';
  }
  let nodes = null;
  let valueKey = '';
  for (const p of parts) {
    if (/^(Text|text)$/.test(p)) {
      valueKey = 'text';
      break;
    }
    if (/^(Html|html)$/.test(p)) {
      valueKey = 'html';
      break;
    }
    if (nodes && nodes.length) {
      // 末段是属性名（src/href/data-src/title…）
      if (/^[a-zA-Z][\w-]*$/.test(p) && !/[.#\[]/.test(p)) {
        let sub = null;
        try {
          sub = nodes.find(p);
        } catch (_) { /* 非法选择器 */ }
        if (sub && sub.length) {
          nodes = sub;
          continue;
        }
        valueKey = p;
        break;
      }
      try {
        nodes = nodes.find(p);
      } catch (_) {
        return '';
      }
    } else {
      nodes = selectIn($, p, null);
    }
    if (!nodes || nodes.length === 0) return '';
  }
  // `Text` 直接打头（没有选择器）时按整个片段取
  if ((!nodes || nodes.length === 0) && valueKey) {
    nodes = $.root();
  }
  if (!nodes || nodes.length === 0) return '';
  const first = nodes.first();
  if (valueKey === 'text') return first.text().replace(/\u00a0/g, ' ').trim();
  if (valueKey === 'html') return first.html() || '';
  if (valueKey) return String(first.attr(valueKey) || '').trim();
  return first.text().replace(/\u00a0/g, ' ').trim();
}

/** 取网址：pdfh 后再按 base 补全 */
function pd(html, rule, base) {
  const v = pdfh(html, rule);
  return v ? joinUrl(base || '', v) : '';
}

/** 简易 os 垫片（少数规则用 readFile；不给真文件系统权限） */
function makeOsStub() {
  return {
    open() {
      throw new Error('drpy 宿主未开放本地文件读取');
    },
    read() {
      throw new Error('drpy 宿主未开放本地文件读取');
    },
    close() {},
  };
}

// ============================================================
// 同步网络：抓页重放
// ============================================================

function reqKey(url, obj) {
  const method = String((obj && obj.method) || 'GET').toUpperCase();
  const body = obj && (obj.body ?? obj.data);
  const cookie = (obj && obj.headers && (obj.headers.Cookie || obj.headers.cookie)) || '';
  const bodyStr = typeof body === 'string' ? body : (body ? JSON.stringify(body) : '');
  return method + '\u0001' + url + '\u0001' + bodyStr + '\u0001' + cookie;
}

function decodeBody(buf, contentType, encoding) {
  const ct = String(contentType || '');
  let charset = String(encoding || '').toLowerCase();
  if (!charset) {
    const m = /charset=([\w-]+)/i.exec(ct);
    charset = m ? m[1].toLowerCase() : '';
  }
  if (/gbk|gb2312|gb18030/.test(charset)) {
    try {
      return iconv.decode(buf, 'gbk');
    } catch (_) { /* 退回 utf8 */ }
  }
  return buf.toString('utf8');
}

async function doFetch(url, obj) {
  const o = obj || {};
  const headers = { 'User-Agent': MOBILE_UA, ...(o.headers || {}) };
  let data = o.body ?? o.data;
  const method = String(o.method || 'GET').toUpperCase();
  if (data && typeof data === 'object') {
    const ct = String(headers['Content-Type'] || headers['content-type'] || '');
    if (ct.includes('json')) {
      data = JSON.stringify(data);
      if (!ct) headers['Content-Type'] = 'application/json';
    } else {
      data = new URLSearchParams(data).toString();
      if (!ct) headers['Content-Type'] = 'application/x-www-form-urlencoded';
    }
  }
  const resp = await axios({
    url,
    method,
    headers,
    data,
    timeout: Number(o.timeout) || FETCH_TIMEOUT_MS,
    maxRedirects: o.redirect === 0 ? 0 : 5,
    validateStatus: () => true,
    responseType: 'arraybuffer',
    transformResponse: [(d) => d],
  });
  const buf = Buffer.from(resp.data || []);
  return {
    content: decodeBody(buf, resp.headers && resp.headers['content-type'], o.encoding),
    headers: resp.headers || {},
    status: resp.status,
  };
}

function makeReq(state) {
  return (url, obj) => {
    const u = String(url || '').trim();
    if (!u) return { content: '', headers: {}, status: 0 };
    const key = reqKey(u, obj);
    if (state.respCache.has(key)) return state.respCache.get(key);
    state.pending.set(key, { url: u, obj: obj || {} });
    // 先给空响应让脚本跑完；外层看到 pending 后会抓取并重跑
    return { content: '', headers: {}, status: 0 };
  };
}

/**
 * 跑一个 drpy 动作，直到没有新的抓页需求。
 * @param {object} state
 * @param {() => any} fn 同步动作（drpy.home/category/…）
 */
async function runReplay(state, fn) {
  let lastErr = null;
  for (let round = 0; round < MAX_REPLAY; round++) {
    state.pending.clear();
    let result;
    try {
      result = fn();
      lastErr = null;
    } catch (e) {
      lastErr = e;
      result = undefined;
    }
    if (state.pending.size === 0) {
      if (lastErr) throw lastErr;
      return result;
    }
    // 抓这一轮缺的地址（并发）
    const tasks = [...state.pending.values()];
    await Promise.all(
      tasks.map(async ({ url, obj }) => {
        const key = reqKey(url, obj);
        try {
          state.respCache.set(key, await doFetch(url, obj));
        } catch (e) {
          state.respCache.set(key, { content: '', headers: {}, status: 0 });
          console.error('[drpy] 抓页失败:', url, e && e.message);
        }
      }),
    );
    // 简单容量控制，避免长会话内存无限增长
    if (state.respCache.size > 200) {
      const keep = [...state.respCache.entries()].slice(-100);
      state.respCache = new Map(keep);
    }
  }
  throw new Error('drpy 规则抓页重放次数超限（可能地址含随机数或站点不可达）');
}

// ============================================================
// 运行时加载
// ============================================================

function parseJsonSafe(v) {
  if (v == null) return {};
  if (typeof v === 'object') return v;
  try {
    const o = JSON.parse(String(v));
    return o == null ? {} : o;
  } catch (_) {
    return {};
  }
}

function readRule(context) {
  try {
    const raw = vm.runInContext(
      'typeof rule === "undefined" ? "{}" : JSON.stringify(rule)',
      context,
      { timeout: 3000 },
    );
    return parseJsonSafe(raw);
  } catch (_) {
    return {};
  }
}

async function buildSource({ runtimeText, extText, mubanText, key, name, dataDir }) {
  // ── 模板库（独立上下文，避免与运行时的 muban 变量打架）──
  let mubanApi = { getMubans: () => ({}), muban: {} };
  if (String(mubanText || '').trim()) {
    try {
      const mctx = vm.createContext({ console });
      vm.runInContext(prepareMuban(mubanText), mctx, { timeout: 10000 });
      mubanApi = mctx.__MUBAN_EXPORT || mubanApi;
    } catch (e) {
      console.error('[drpy] 模板库加载失败（模板源会退化）:', e && e.message);
    }
  }

  const state = {
    key: String(key || 'drpy'),
    name: String((name || '').trim() || 'drpy'),
    respCache: new Map(),
    pending: new Map(),
    port: 0,
    rule: {},
    context: null,
    drpy: null,
  };

  // ⚠️ 不能把宿主的内建构造器（String/JSON/Object…）放进 sandbox：
  //    它们会**遮蔽** vm 自己的全局，导致 `String.prototype.xxx` 补丁打在
  //    宿主 realm 上，而 vm 里的字符串用不到（drpy 的 rstrip 就是这么丢的）。
  const sandbox = {
    console,
    setTimeout, clearTimeout,
    Buffer, URL, URLSearchParams, TextDecoder,
    cheerio,
    CryptoJS,
    gbkTool: makeGbkTool(),
    local: makeLocal(dataDir),
    req: makeReq(state),
    joinUrl,
    // drpy2 运行时把这三个当宿主能力（内部只定义了 jsp: 版本的 pdfh2/pdfa2/pd2）
    pdfh,
    pdfa,
    pd,
    os: makeOsStub(),
    MD5: (s) => CryptoJS.MD5(String(s == null ? '' : s)).toString(),
    // 运行时在 init 里会覆盖它；先给个默认值，避免 init 早期失败时 JSON.parse(undefined)
    rule_fetch_params: {},
    模板: mubanApi,
    getProxy: (flag) => (flag ? `http://127.0.0.1:${state.port}/proxy?do=js` : ''),
  };
  // cheerio.jinja2 / cheerio.jp 是 drpy 官方 cheerio 构建自带的扩展
  try {
    cheerio.jinja2 = jinja2;
    // JSONPath（`json:` 规则用，如 `$.data.list`）
    cheerio.jp = (p, obj) => {
      try {
        return JSONPath({ path: String(p), json: obj, wrap: true });
      } catch (_) {
        return [];
      }
    };
  } catch (_) { /* 冻结对象则忽略 */ }
  sandbox.globalThis = sandbox;

  const context = vm.createContext(sandbox);
  state.context = context;

  // drpy 依赖宿主给 String 加的 rstrip/lstrip/strip（Rhino 扩展）
  const stringPatch = String.raw`
    String.prototype.rstrip = function (c) {
      if (c == null || c === '') return this.replace(/[\s\u3000]+$/g, '');
      var chars = String(c), i = this.length;
      while (i > 0 && chars.indexOf(this.charAt(i - 1)) >= 0) i--;
      return this.slice(0, i);
    };
    String.prototype.lstrip = function (c) {
      if (c == null || c === '') return this.replace(/^[\s\u3000]+/g, '');
      var chars = String(c), i = 0;
      while (i < this.length && chars.indexOf(this.charAt(i)) >= 0) i++;
      return this.slice(i);
    };
    String.prototype.strip = function (c) { return this.lstrip(c).rstrip(c); };
  `;
  try {
    vm.runInContext(stringPatch, context, { timeout: 2000 });
  } catch (e) {
    console.error('[drpy] String 扩展注入失败:', e && e.message);
  }

  const runtimeCode = prepareRuntime(runtimeText);
  try {
    vm.runInContext(runtimeCode, context, { timeout: 20000 });
  } catch (e) {
    throw new Error('drpy 运行时加载失败：' + ((e && e.message) || e));
  }
  const drpy = context.__DRPY_EXPORT;
  if (!drpy || typeof drpy.init !== 'function') {
    throw new Error('drpy 运行时没有导出 init（版本不兼容？）');
  }
  state.drpy = drpy;

  // ── 初始化站点规则（可能触发同步抓页：hostJs / Cookie 地址）──
  await runReplay(state, () => drpy.init(normalizeRuleCode(extText)));
  state.rule = readRule(context);
  if (!state.name || state.name === 'drpy') {
    state.name = String(state.rule.title || state.rule.host || 'drpy');
  }
  return state;
}

// ============================================================
// 动作分发
// ============================================================

async function actionHome(state) {
  const homeObj = parseJsonSafe(await runReplay(state, () => state.drpy.home(false)));
  let list = [];
  try {
    const vodObj = parseJsonSafe(await runReplay(state, () => state.drpy.homeVod({})));
    if (Array.isArray(vodObj.list)) list = vodObj.list;
  } catch (e) {
    console.error('[drpy] homeVod 失败:', e && e.message);
  }
  return { ...homeObj, list };
}

async function actionCategory(state, body) {
  const tid = body.tid ?? body.id ?? body.type_id ?? '';
  const pg = Number(body.pg ?? body.page ?? 1) || 1;
  const filter = body.filter === true || body.filter === 1 || body.filter === '1';
  const extend = body.extend ?? body.filters ?? {};
  return parseJsonSafe(
    await runReplay(state, () => state.drpy.category(String(tid), pg, filter, extend || {})),
  );
}

async function actionDetail(state, body) {
  const id = String(body.id ?? body.ids ?? body.vod_id ?? '');
  return parseJsonSafe(await runReplay(state, () => state.drpy.detail(id)));
}

async function actionSearch(state, body) {
  const wd = String(body.wd ?? body.key ?? body.keyword ?? '');
  const pg = Number(body.pg ?? body.page ?? 1) || 1;
  const quick = body.quick === true || body.quick === 1 || body.quick === '1';
  return parseJsonSafe(await runReplay(state, () => state.drpy.search(wd, quick, pg)));
}

async function actionPlay(state, body) {
  const flag = String(body.flag ?? '');
  const id = String(body.id ?? body.url ?? '');
  const p = parseJsonSafe(await runReplay(state, () => state.drpy.play(flag, id, [])));
  const headers = {};
  if (state.rule && state.rule.headers && typeof state.rule.headers === 'object') {
    for (const k of Object.keys(state.rule.headers)) {
      const v = state.rule.headers[k];
      if (v != null && String(v).trim()) headers[k] = String(v);
    }
  }
  return { ...p, header: headers };
}

// ============================================================
// HTTP 服务（CatVod 契约）
// ============================================================

function readBody(req, limit = 16 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    let body = '';
    let tooLarge = false;
    req.on('data', (c) => {
      if (tooLarge) return;
      body += c;
      if (body.length > limit) {
        tooLarge = true;
        reject(new Error('请求体过大'));
      }
    });
    req.on('end', () => {
      if (!tooLarge) resolve(body);
    });
    req.on('error', reject);
  });
}

function sendJson(res, obj, status = 200) {
  const s = JSON.stringify(obj);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(s),
  });
  res.end(s);
}

async function handleRequest(state, req, res) {
  const u = new URL(req.url, 'http://127.0.0.1');
  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  if (u.pathname === '/config') {
    const r = state.rule || {};
    sendJson(res, {
      video: {
        sites: [{
          key: state.key,
          name: state.name,
          type: 3,
          api: 'csp_drpy',
          ext: '',
          searchable: r.searchUrl ? 1 : 0,
          quickSearch: r.searchUrl ? 1 : 0,
          filterable: r.filter ? 1 : 0,
        }],
      },
    });
    return;
  }

  if (u.pathname === '/proxy') {
    const params = {};
    for (const [k, v] of u.searchParams.entries()) params[k] = v;
    try {
      const out = await runReplay(state, () => state.drpy.proxy(params));
      const arr = Array.isArray(out) ? out : [404, 'text/plain', 'Not Found'];
      const [status, type, data] = arr;
      res.writeHead(Number(status) || 200, { 'Content-Type': String(type || 'text/plain') });
      res.end(data == null ? '' : String(data));
    } catch (e) {
      res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('代理规则错误：' + ((e && e.message) || e));
    }
    return;
  }

  const m = /^\/spider\/([^/]+)\/(\d+)\/([\w-]+)$/.exec(u.pathname);
  if (!m) {
    sendJson(res, { error: 'not found' }, 404);
    return;
  }
  const action = m[3];
  const raw = await readBody(req);
  let body = {};
  try {
    body = raw ? JSON.parse(raw) : {};
  } catch (_) {
    body = {};
  }

  let result;
  switch (action) {
    case 'init':
      result = { ok: true };
      break;
    case 'home':
      result = await actionHome(state);
      break;
    case 'homeVod': {
      const v = parseJsonSafe(await runReplay(state, () => state.drpy.homeVod(body || {})));
      result = v;
      break;
    }
    case 'category':
      result = await actionCategory(state, body);
      break;
    case 'detail':
      result = await actionDetail(state, body);
      break;
    case 'search':
      result = await actionSearch(state, body);
      break;
    case 'play':
      result = await actionPlay(state, body);
      break;
    default:
      sendJson(res, { error: 'unsupported action: ' + action }, 404);
      return;
  }
  sendJson(res, result);
}

async function startServer(state) {
  const handler = (req, res) => {
    handleRequest(state, req, res).catch((e) => {
      console.error('[drpy] 请求处理失败:', (e && e.stack) || e);
      try {
        sendJson(res, { ok: false, error: String((e && e.message) || e) }, 500);
      } catch (_) { /* 响应已开始写出 */ }
    });
  };
  const server = globalThis.catServerFactory
    ? globalThis.catServerFactory(handler)
    : http.createServer(handler);
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      state.port = server.address().port;
      resolve();
    });
  });
  return server;
}

// ============================================================
// 对外 API
// ============================================================

/**
 * 载入一个 drpy 源并启动 spider 服务。
 * 返回 `{ok, port, key, name}`。
 */
export async function loadDrpy(opts) {
  const {
    runtimeText,
    extText,
    mubanText,
    key,
    name,
    dataDir,
  } = opts || {};
  if (!String(extText || '').trim()) {
    throw new Error('缺少站点规则（ext 为空）');
  }
  stopDrpy();
  const state = await buildSource({
    runtimeText,
    extText,
    mubanText,
    key,
    name,
    dataDir,
  });
  const server = await startServer(state);
  state.server = server;
  current = state;
  console.log(`[drpy] 已载入 ${state.name}（${state.key}）@ ${state.port}`);
  return { ok: true, port: state.port, key: state.key, name: state.name };
}

/** 停止当前 drpy 源（不影响其它 CatVod 整包源） */
export function stopDrpy() {
  if (!current) return { stopped: false };
  try {
    if (current.server) current.server.close();
  } catch (_) { /* ignore */ }
  current = null;
  return { stopped: true };
}

/** 当前 drpy 源信息（调试用） */
export function drpyInfo() {
  if (!current) return { loaded: false };
  return {
    loaded: true,
    key: current.key,
    name: current.name,
    port: current.port,
    ruleTitle: current.rule && current.rule.title,
  };
}
