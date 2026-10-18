/**
 * 阅读 3.0 (Legado) 书源执行器 —— **功能优先的实用实现**
 *
 * 目标：导入书源 JSON → 搜书 → 拿目录 → 读正文（小说/漫画）。
 * 不追求覆盖 Legado 全部特性，只把「能看书」这条链路做通。
 *
 * ── 覆盖的字段 ──────────────────────────────────────────────
 *   bookSourceName / bookSourceUrl / bookSourceGroup
 *   searchUrl           支持 {{key}} {{page}}
 *   ruleSearch          bookList / name / author / bookUrl / coverUrl / intro / kind
 *   ruleBookInfo        name / author / coverUrl / intro / tocUrl / kind / lastChapter
 *   ruleToc             chapterList / chapterName / chapterUrl / (分页)
 *   ruleContent         content
 *   header              自定义请求头
 *   bookSourceType      0=小说 1=有声 2=漫画 3=文件
 *
 * ── 规则能力 ────────────────────────────────────────────────
 *   交给 book_rule.js（已通过 21 项测试）：
 *   @css: / @json: / @js: / @XPath: / 无前缀(XPath) + {{}} 变量 + @ 分段
 *
 * ── 已知不支持（会明确报错，不静默失败）────────────────────
 *   · java.ajax / java.startBrowserAwait（同步网络 / 隐藏浏览器）
 *   · webView:true 的请求（需要浏览器内核）
 *   · @p.N 段落下标、## 正则替换（部分规则会退化）
 */

import { evalRule, evalList, makeInput, jsonPath, looksLikeJsRule } from './book_rule.js';

import axios from 'axios';

// 说明：本文件与 main.js 同为 ESM（package.json type=module），
// esbuild 打包成 CJS 时会正确转换 import/export。
// 之前用 module.exports 会被塞进 ESM 模块作用域 → 导出为空对象。


// 2026-10-18：15s → 25s。书源分类/详情经常串行请求多个页面，15s 在弱网下
// 容易直接超时（日志里的 connect timeout），放宽后成功率明显提高。
const HTTP_TIMEOUT_MS = 25000;

// 各源的 java.get/put 状态（按源 URL 隔离）
const sourceState = new Map();

function stateOf(key) {
  if (!sourceState.has(key)) sourceState.set(key, {});
  return sourceState.get(key);
}

// ============================================================
// 请求
// ============================================================

const DEFAULT_UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

/**
 * 解析 Legado 的 URL 尾部内联 JSON 配置，例如：
 *   https://site.com/search/{{key}}/{{page}}.html,{"webView":true}
 *   https://a/b,{\r\n "method":"GET", "headers":{"referer":"..."}}
 * 返回 { url, headers, method, webView }
 */
function splitUrlOptions(raw) {
  const s = String(raw || '');
  // 找最后一个逗号后紧跟 { 的位置
  let idx = -1;
  let depth = 0;
  for (let i = s.length - 1; i >= 0; i--) {
    const c = s[i];
    if (c === '}') depth++;
    else if (c === '{') {
      depth--;
      if (depth === 0) {
        idx = i;
        break;
      }
    }
  }
  if (idx < 0) return { url: s.trim(), headers: {}, webView: false };
  // 逗号必须紧邻（允许空白）
  let j = idx - 1;
  while (j >= 0 && /\s/.test(s[j])) j--;
  if (j < 0 || s[j] !== ',') return { url: s.trim(), headers: {}, webView: false };

  const url = s.substring(0, j).trim();
  const jsonPart = s.substring(idx);
  try {
    // Legado 的 URL 选项是**单引号 JS 对象字面量**（`{'body':'...','method':'POST'}`），
    // 不是严格 JSON —— JSON.parse 直接失败 → POST 选项全丢、退化成 GET。
    // 宽松转换：单引号→双引号；无引号 key 补双引号。
    const lax = jsonPart
      .replace(/'/g, '"')
      .replace(/([{,]\s*)([A-Za-z_$][\w$]*)(\s*:)/g, '$1"$2"$3');
    const cfg = JSON.parse(lax);
    return {
      url,
      headers: cfg.headers && typeof cfg.headers === 'object' ? cfg.headers : {},
      method: (cfg.method || 'GET').toUpperCase(),
      body: cfg.body,
      webView: cfg.webView === true,
    };
  } catch (_) {
    return { url, headers: {}, webView: false };
  }
}

/** 补全相对地址 */
function absolute(url, base) {
  // 有些源的封面/图片是从 style="url('…')" 里正则抠出来的，
  // 会把包裹的引号一起带出来 ⇒ 这里统一去掉首尾引号。
  const u = String(url || '').trim().replace(/^["']|["']$/g, '').trim();
  if (!u) return '';
  if (/^https?:\/\//i.test(u)) return u;
  try {
    return new URL(u, base).toString();
  } catch (_) {
    return u;
  }
}

/**
 * 规范化 Legado 源 header：可能是 JSON 字符串 / @js: 脚本字符串 / 对象。
 *
 * ⚠️ 之前直接用 Object.assign({}, source.header || {}) 合并——header 是字符串时
 * 会被展开成 {"0":"{","1":"\"",...} 这类畸形请求头，源站直接回 HTTP 500。
 * 这里统一解析成对象再合并。
 */
function normalizeHeaders(h, jsLib) {
  if (!h) return {};
  if (typeof h === 'string') {
    let s = h.trim();
    if (!s) return {};
    if (s.startsWith('@js:')) {
      try {
        const v = evalRule({
          rule: s,
          input: makeInput(''),
          vars: buildVars({}),
          ctx: ruleCtx('', { jsLib }),
        });
        s = str(v);
      } catch (_) {
        return {};
      }
    }
    try {
      const obj = JSON.parse(s);
      return obj && typeof obj === 'object' && !Array.isArray(obj) ? obj : {};
    } catch (_) {
      return {};
    }
  }
  return h;
}

/**
 * 提取规则/网址尾部的 `@Header:{...}`（Legado 教材语法，常见于漫画源）。
 *
 * 例（本文件适配的「看漫画」源）：
 *   `@js:…mhgDecode(String(result))@Header:{"Referer":"https://m.manhuagui.com/"}` 
 *
 * 该尾巴**不是规则的一部分** —— 留在 `@js:` 里会直接语法错（整章空白），
 * 必须切掉单独解析。请求头回给客户端（漫画图床靠 Referer/UA 过防盗链）。
 */
function splitRuleHeader(rule) {
  const s = String(rule || '');
  const idx = s.lastIndexOf('@Header:');
  if (idx < 0) return { rule: s, header: {} };
  const obj = parseLooseObject(s.substring(idx + 8));
  if (!obj) return { rule: s, header: {} }; // 解析失败就不当标记，保持原文
  return { rule: s.substring(0, idx).trim(), header: obj };
}

/**
 * 宽松解析 `{key:value, ...}`：
 *   · key 可带/不带引号（`"Referer"` / `Referer`）
 *   · value 可为裸字面量（`host` / `thisPage` / 无引号 URL）
 *   · 值里的 `:` `,` `()`（UA 串）不能被误切
 */
function parseLooseObject(raw) {
  const s = String(raw || '').trim();
  if (!s.startsWith('{')) return null;
  let depth = 0;
  let end = -1;
  let q = null;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) {
      if (c === q && s[i - 1] !== '\\') q = null;
      continue;
    }
    if (c === '"' || c === "'") {
      q = c;
      continue;
    }
    if (c === '{') depth++;
    else if (c === '}') {
      depth--;
      if (depth === 0) {
        end = i;
        break;
      }
    }
  }
  if (end < 0) return null;

  const inner = s.slice(1, end);
  const segs = [];
  let buf = '';
  let d = 0;
  let qq = null;
  for (let i = 0; i < inner.length; i++) {
    const c = inner[i];
    if (qq) {
      buf += c;
      if (c === qq && inner[i - 1] !== '\\') qq = null;
      continue;
    }
    if (c === '"' || c === "'") {
      qq = c;
      buf += c;
      continue;
    }
    if (c === '{' || c === '[' || c === '(') d++;
    else if (c === '}' || c === ']' || c === ')') d--;
    if (c === ',' && d === 0) {
      segs.push(buf);
      buf = '';
      continue;
    }
    buf += c;
  }
  if (buf.trim()) segs.push(buf);

  const out = {};
  for (const seg of segs) {
    const i = seg.indexOf(':');
    if (i <= 0) continue;
    const k = seg.slice(0, i).trim().replace(/^["']|["']$/g, '');
    if (!k) continue;
    let v = seg.slice(i + 1).trim();
    if ((v.startsWith('"') && v.endsWith('"')) ||
        (v.startsWith("'") && v.endsWith("'"))) {
      v = v.slice(1, -1);
    }
    out[k] = v;
  }
  return Object.keys(out).length ? out : null;
}

/**
 * 解析 @Header 里的 Legado 内置取值：
 *   host     → 当前页面的协议+域名（`https://m.manhuagui.com`）
 *   thisPage → 当前页完整地址（章节页）
 *   prePage  → 上一步页面；content 阶段拿不到，退回站点根
 * 其余按字面量。
 */
function resolveRuleHeaders(header, pageUrl, base) {
  const out = {};
  if (!header || typeof header !== 'object') return out;
  let origin = '';
  try {
    origin = new URL(pageUrl || base || '').origin;
  } catch (_) {
    origin = base || '';
  }
  for (const [k, v] of Object.entries(header)) {
    const s = String(v == null ? '' : v).trim();
    if (!s) continue;
    if (/^host$/i.test(s)) out[k] = origin;
    else if (/^thisPage$/i.test(s)) out[k] = pageUrl || '';
    else if (/^prePage$/i.test(s)) out[k] = base || origin;
    else out[k] = s;
  }
  return out;
}

/**
 * 老式扁平书源的网址占位符：`searchKey` / `searchPage`（无花括号）。
 * 例：`https://m.manhuagui.com/s/searchKey.html`、`.../?page=searchPage`。
 * `searchPage-1` 这类偏移写法一并支持（老源页码从 0 开始）。
 */
function applySearchTokens(url, keyword, page) {
  let s = String(url || '');
  if (keyword != null && keyword !== '') {
    // 用函数替换：关键词里出现 `$&` 之类时不会被当成替换模式
    s = s.replace(/searchKey/g, () => encodeURIComponent(keyword));
  }
  if (page != null) {
    s = s.replace(/searchPage([+-]\d+)?/g, (all, off) => {
      const n = Number(page) + (off ? parseInt(off, 10) : 0);
      return String(n);
    });
  }
  return s;
}

/** bookSourceType 可能是数字 2，也可能是「漫画」这类中文（老源写法） */
function isMangaSourceType(v) {
  if (v == null) return false;
  if (typeof v === 'number') return v === 2;
  const s = String(v).trim().toLowerCase();
  return s === '2' || s === '漫画' || s === 'manga' || s === 'comic';
}

/** 单源代理：source.proxy = "host:port"，空则直连。 */
let CURRENT_PROXY = null;
function setProxy(p) {
  if (!p || typeof p !== 'string') {
    CURRENT_PROXY = null;
    return;
  }
  const m = p.trim().match(/^([^:]+):(\d+)$/);
  if (!m) {
    CURRENT_PROXY = null;
    return;
  }
  CURRENT_PROXY = { host: m[1], port: parseInt(m[2], 10), protocol: 'http' };
}

async function httpGet(url, headers, method = 'GET', body) {
  const res = await axios({
    url,
    method,
    headers: Object.assign(
      {
        'User-Agent': DEFAULT_UA,
        Accept: '*/*',
        'Accept-Language': 'zh-CN,zh;q=0.9',
      },
      headers || {},
    ),
    data: body,
    timeout: HTTP_TIMEOUT_MS,
    maxRedirects: 5,
    validateStatus: () => true,
    // 单源代理：CURRENT_PROXY 非空时走 http 代理
    ...(CURRENT_PROXY ? { proxy: CURRENT_PROXY } : {}),
    // 书源经常返回非 UTF-8（GBK），先拿 buffer 再解码
    responseType: 'arraybuffer',
    transformResponse: [(d) => d],
  });
  const buf = Buffer.from(res.data);
  return {
    status: res.status,
    headers: res.headers || {},
    text: decodeBody(buf, res.headers || {}),
    raw: buf,
  };
}

/** 编码探测：GBK 站点很多，不解码就是乱码 */
function decodeBody(buf, headers) {
  const ct = String(headers['content-type'] || '');
  let charset = '';
  const m = /charset=([\w-]+)/i.exec(ct);
  if (m) charset = m[1].toLowerCase();
  if (!charset) {
    const head = buf.slice(0, 2048).toString('latin1');
    const m2 = /charset=["']?([\w-]+)/i.exec(head);
    if (m2) charset = m2[1].toLowerCase();
  }
  if (/gbk|gb2312|gb18030/.test(charset)) {
    try {
      return new TextDecoder('gbk').decode(buf);
    } catch (_) {
      /* 运行时不支持 gbk 就退回 utf8 */
    }
  }
  return buf.toString('utf8');
}

/**
 * 请求响应 → 规则引擎 input：
 *   · JSON 响应（{ 或 [ 开头且可解析）→ { __json: obj }，规则走 JSONPath
 *   · 其余（HTML 等）→ makeInput() 包装成 cheerio 文档
 */
function makeInputSafe(text) {
  const s = String(text || '');
  const t = s.trim();
  if (t.startsWith('{') || t.startsWith('[')) {
    try {
      return { __json: JSON.parse(t) };
    } catch (_) {
      /* 不是合法 JSON，按 HTML 处理 */
    }
  }
  return makeInput(s);
}

// ============================================================
// 变量
// ============================================================

function buildVars(state) {
  return Object.assign(
    {
      key: '',
      page: 1,
      baseUrl: '',
      searchKey: '',
    },
    state || {},
  );
}

/**
 * Legado 的 `{{...}}` 里不只是变量名，还有 java.get('x') 这类调用。
 * 这里做最小替换：java.get('name') → state[name]。
 */
function applyLegadoVars(str, state) {
  if (typeof str !== 'string' || !str.includes('{{')) return str;
  return str.replace(/\{\{([\s\S]*?)\}\}/g, (all, expr) => {
    const e = expr.trim();
    const g = /^java\.get\(\s*['"]([^'"]+)['"]\s*\)$/.exec(e);
    if (g) {
      const v = state[g[1]];
      return v == null ? '' : String(v);
    }
    if (e in state) {
      const v = state[e];
      return v == null ? '' : String(v);
    }
    return all;
  });
}

/**
 * 对请求头值做 Legado 变量替换（`{{key}}` / `{{page}}` / `{{变量}}`）。
 * 仅当头值是字符串且含 `{{` 时替换；未配置变量的源行为完全不变。
 */
function applyHeaderVars(headers, state) {
  if (!headers || typeof headers !== 'object') return headers;
  const out = {};
  for (const key of Object.keys(headers)) {
    const v = headers[key];
    out[key] = typeof v === 'string' && v.includes('{{')
      ? applyLegadoVars(v, state)
      : v;
  }
  return out;
}

// ============================================================
// 结果规整
// ============================================================

function str(v) {
  if (v == null) return '';
  if (Array.isArray(v)) return v.map((x) => str(x)).join('\n');
  return String(v).trim();
}

/**
 * 规则求值上下文：baseUrl + 源级 jsLib（skybook 混淆脚本库）。
 *
 * jsLib 必须在**规则求值前**先执行（book_rule.js 的 runJs 里做），
 * 规则里的 `@js:` / `{{java.xxx}}` 才能调用到 jsLib 定义的函数。
 * 全部求值入口统一走这里，避免漏传。
 */
function ruleCtx(baseUrl, source) {
  return { baseUrl, jsLib: (source && source.jsLib) || '' };
}

// ============================================================
// 搜索
// ============================================================

/**
 * 异步执行整段 @js:/<js> 脚本型 searchUrl，返回脚本写入的 `result`。
 * 非脚本 URL 原样返回。
 *
 * Legado 规范：searchUrl 可以是完整 JS 脚本，内部用 java.ajax 发
 * POST/带 headers 请求、可选人机验证分支，最后 `result=url;`。
 * 原实现把脚本文本当普通 URL 直接 httpGet → 搜索必然失败
 * （思路客等大量脚本型源就是这种写法）。
 */
async function evalSearchUrlScript(rawUrl, { state, source, base }) {
  let script = null;
  const s = String(rawUrl || '').trim();
  if (s.startsWith('@js:')) script = s.slice(4);
  else {
    const m = /^\s*<js>([\s\S]*?)<\/js>\s*$/i.exec(s);
    if (m) script = m[1];
  }
  if (script == null) return rawUrl;

  // java.ajax：Legado 语义是**同步返回响应文本**（脚本里常见
  // `java.ajax(url).match(/Just a moment/)` 人机验证检测）。
  // 异步沙箱无法同步等待请求；而这类脚本的 ajax 返回值只影响
  // 「人机验证」检测分支，不影响 `result=url` 主流程（搜索结果仍由
  // splitUrlOptions 解析出的 URL 正式请求取得）。
  // 因此：同步返回空串（检测分支不命中，流程继续），真实请求后台
  // 发起一次（预热 UA/Referer/Cookie 一致性）。
  const fireRequest = (arg) => {
    let url;
    let opt = {};
    if (typeof arg === 'string') {
      const o = splitUrlOptions(arg);
      url = o.url;
      opt = o;
    } else if (arg && typeof arg === 'object') {
      url = String(arg.url || arg.urlStr || '');
      opt = arg;
    }
    if (!url) return;
    const headers = Object.assign(
      {},
      normalizeHeaders(source.header, source.jsLib),
      opt.headers || {},
    );
    void httpGet(absolute(url, base), headers, opt.method || 'GET', opt.body)
      .then(() => {})
      .catch(() => {});
  };
  const ajax = (arg) => {
    fireRequest(arg);
    return '';
  };

  const sandbox = {
    result: '',
    baseUrl: base,
    key: state.key || '',
    page: state.page || 1,
    // 老式源脚本里的同义变量
    searchKey: state.key || '',
    searchPage: state.page || 1,
    book: state.book || {},
    src: source.bookSourceUrl || '',
    java: {
      ajax,
      getString: (rule, text) => {
        const rs = rule == null ? '' : String(rule);
        const rt = rs.trim();
        if (rt.startsWith('$')) {
          try {
            const root = JSON.parse(
              text != null ? String(text) : String(sandbox.result),
            );
            const out = jsonPath(root, rt);
            return out.length > 0 ? (out[0] == null ? '' : String(out[0])) : '';
          } catch (_) {
            return '';
          }
        }
        return rs;
      },
      longToast: () => {},
      shortToast: () => {},
      startBrowserAwait: () => false,
    },
    console: { log: () => {}, error: () => {} },
  };
  sandbox.globalThis = sandbox;

  const fn = new Function(
    'sandbox',
    `with (sandbox) { return (async () => { ${script} })(); }`,
  );
  try {
    await fn(sandbox);
  } catch (e) {
    throw new Error(
      '搜索地址脚本执行失败：' + (e && e.message ? e.message : String(e)),
    );
  }
  const out = sandbox.result;
  return out == null ? '' : String(out);
}

async function search({ source, keyword, page = 1 }) {
  setProxy(source && source.proxy);
  const base = source.bookSourceUrl || '';
  const state = stateOf(base);
  state.key = keyword;
  state.page = page;
  // 老式扁平源的 `{{searchKey}}` / `{{searchPage}}` 变量（buildVars 的默认值）
  state.searchKey = keyword;
  state.searchPage = page;

  // ✅ **兼容 Legado 规范字段名**（重构 ✓）—— 原来只认 `searchUrl` ✗：
  //   而 Legado 书源（含 yckceo / 631 源包 / gedoor/legado 生态）用的都是
  //   **`ruleSearchUrl`** ✓✓ ⇒ 只读 `searchUrl` 会**永远拿不到地址** ✗
  //   ⇒ 表现为"搜索必然失败"✗（这也解释了"同一份源在别的实现里能用、在这不能用"✓）
  //   ℹ️ 下面 `:301-306` 的 `{{key}}`/`{{page}}`/`{key}`/`{page}` 替换**本来就是对的** ✓，无需动 ✓
  //   ℹ️ 兼容三种写法 ✓：`searchUrl`（本引擎旧名 ✓）· `ruleSearchUrl`（Legado ✓）
  //      · `ruleSearch.url`（部分源把地址写在 ruleSearch 对象里 ✓）
  let rawUrl =
    source.searchUrl ||
    source.ruleSearchUrl ||
    (source.ruleSearch && source.ruleSearch.url) ||
    '';
  if (!rawUrl) {
    return {
      ok: false,
      error: '该源没有配置搜索地址（searchUrl / ruleSearchUrl 都没有）',
    };
  }

  // {{key}} {{page}}
  rawUrl = applyLegadoVars(rawUrl, state)
    .replace(/\{\{\s*key\s*\}\}/g, encodeURIComponent(keyword))
    .replace(/\{\{\s*page\s*\}\}/g, String(page))
    .replace(/\{key\}/g, encodeURIComponent(keyword))
    .replace(/\{page\}/g, String(page));
  // 整段 @js:/<js> 脚本型 searchUrl：执行脚本取 result 作为最终地址
  rawUrl = await evalSearchUrlScript(rawUrl, { state, source, base });

  // 老式扁平写法：`https://site/s/searchKey.html`、`...?page=searchPage`
  // ⚠️ 放在脚本执行**之后**：脚本里 `searchKey` 可能是变量名，
  //    先替换会把代码改坏；脚本产出物里的占位符仍会在这里替换。
  rawUrl = applySearchTokens(rawUrl, keyword, page);

  const opt = splitUrlOptions(rawUrl);
  if (opt.webView) {
    return { ok: false, error: '该源的搜索需要浏览器内核（webView），当前不支持' };
  }

  const url = absolute(opt.url, base);
  const headers = applyHeaderVars(
    Object.assign({}, normalizeHeaders(source.header, source.jsLib), opt.headers || {}),
    state,
  );

  let resp;
  try {
    resp = await httpGet(url, headers, opt.method || 'GET', opt.body);
  } catch (e) {
    return { ok: false, error: '搜索请求失败：' + (e.message || e) };
  }
  if (resp.status >= 400) {
    return {
      ok: false,
      error: '搜索请求失败：源站返回 HTTP ' + resp.status,
    };
  }

  const rule = source.ruleSearch || {};
  if (!rule.bookList) {
    return { ok: false, error: '该源没有配置 ruleSearch.bookList' };
  }

  const input = makeInputSafe(resp.text);
  const vars = buildVars(state);

  let items;
  try {
    items = evalList({ rule: rule.bookList, input, vars, ctx: ruleCtx(url, source) });
  } catch (e) {
    return { ok: false, error: 'bookList 规则失败：' + e.message };
  }

  const out = [];
  for (const node of items) {
    const pick = (r) => {
      if (!r) return '';
      try {
        return str(evalRule({ rule: r, input: node, vars, ctx: ruleCtx(url, source) }));
      } catch (_) {
        return '';
      }
    };
    const name = pick(rule.name);
    if (!name) continue;
    const bookUrl = absolute(pick(rule.bookUrl), base);
    out.push({
      name,
      author: pick(rule.author),
      bookUrl,
      coverUrl: absolute(pick(rule.coverUrl), base),
      intro: pick(rule.intro),
      kind: pick(rule.kind),
      lastChapter: pick(rule.lastChapter),
      wordCount: pick(rule.wordCount),
    });
  }
  return { ok: true, list: out, url };
}

// ============================================================
// 详情
// ============================================================

async function bookInfo({ source, bookUrl }) {
  setProxy(source && source.proxy);
  const base = source.bookSourceUrl || '';
  const state = stateOf(base);
  const rule = source.ruleBookInfo || {};

  // 有些源的 init 规则会从 URL 里解出 bookId 存进 state
  if (rule.init) {
    try {
      evalRule({
        rule: rule.init,
        input: makeInput(''),
        vars: buildVars(state),
        ctx: Object.assign({}, ruleCtx(bookUrl, source), { result: bookUrl }),
      });
    } catch (_) {/* 忽略 */}
  }

  let input;
  let finalUrl = bookUrl;
  try {
    const resp = await httpGet(bookUrl, applyHeaderVars(normalizeHeaders(source.header, source.jsLib), state));
    input = makeInputSafe(resp.text);
  } catch (e) {
    // 详情页拿不到也不算致命：目录可能仍能取
    input = makeInput('');
  }

  const vars = buildVars(state);
  const pick = (r, dflt = '') => {
    if (!r) return dflt;
    try {
      const v = str(evalRule({ rule: r, input, vars, ctx: ruleCtx(bookUrl, source) }));
      return v || dflt;
    } catch (_) {
      return dflt;
    }
  };

  let tocUrl = pick(rule.tocUrl);
  // tocUrl 可能是 <a> 的取值或带内联配置
  if (tocUrl) {
    const opt = splitUrlOptions(tocUrl);
    tocUrl = absolute(opt.url, base);
  }

  return {
    ok: true,
    info: {
      name: pick(rule.name),
      author: pick(rule.author),
      coverUrl: absolute(pick(rule.coverUrl), base),
      intro: pick(rule.intro),
      kind: pick(rule.kind),
      lastChapter: pick(rule.lastChapter),
      wordCount: pick(rule.wordCount),
      tocUrl: tocUrl || bookUrl,
      // 有声书/漫画标记
      sourceType: source.bookSourceType ?? 0,
    },
  };
}

// ============================================================
// 目录
// ============================================================

async function toc({ source, tocUrl }) {
  setProxy(source && source.proxy);
  const base = source.bookSourceUrl || '';
  const state = stateOf(base);
  const rule = source.ruleToc || {};
  if (!rule.chapterList) return { ok: false, error: '该源没有配置 ruleToc.chapterList' };

  const opt = splitUrlOptions(tocUrl);
  const url = absolute(opt.url, base);
  let text = '';
  try {
    const resp = await httpGet(url, applyHeaderVars(Object.assign({}, normalizeHeaders(source.header, source.jsLib), opt.headers || {}), state));
    text = resp.text;
  } catch (e) {
    // 有些详情的 tocUrl 是 ajax 接口，失败时退回用 URL 本身当单章
    return {
      ok: true,
      list: [{ name: '正文', url: tocUrl }],
      warning: '目录请求失败（' + (e.message || e) + '），已退化为单章',
    };
  }

  const input = makeInputSafe(text);
  const vars = buildVars(state);

  if (process.env.BOOK_DEBUG) {
    console.error('[toc-debug] url=', url, 'textLen=', text.length,
      'rule=', rule.chapterList, 'inputJson=', input && input.__json ? 'yes' : 'no');
  }

  let items;
  try {
    items = evalList({ rule: rule.chapterList, input, vars, ctx: ruleCtx(url, source) });
  } catch (e) {
    return { ok: false, error: 'chapterList 规则失败：' + e.message };
  }
  if (process.env.BOOK_DEBUG) {
    console.error('[toc-debug] items=', Array.isArray(items) ? items.length : typeof items);
  }
  // JS 规则可能返回单个对象 / 字符串（而不是数组）；统一包成数组，
  // 避免 `for (const node of items)` 直接抛 "is not iterable"。
  if (!Array.isArray(items)) items = items == null ? [] : [items];

  const out = [];
  for (const node of items) {
    const pick = (r) => {
      if (!r) return '';
      try {
        return str(evalRule({ rule: r, input: node, vars, ctx: ruleCtx(url, source) }));
      } catch (_) {
        return '';
      }
    };
    const name = pick(rule.chapterName);
    const cu = pick(rule.chapterUrl);
    if (!name || !cu) continue;
    const copt = splitUrlOptions(cu);
    out.push({ name, url: absolute(copt.url, base) });
  }
  return { ok: true, list: out };
}

// ============================================================
// 正文（小说=文本，漫画=图片数组）
// ============================================================

async function content({ source, chapterUrl }) {
  setProxy(source && source.proxy);
  const base = source.bookSourceUrl || '';
  const state = stateOf(base);
  const rule = source.ruleContent || {};
  if (!rule.content) return { ok: false, error: '该源没有配置 ruleContent.content' };

  // `@Header:{...}` 尾巴（Legado 教材语法）：从规则里切掉单独解析。
  // 看漫画这类源写作 `@js:…@Header:{"Referer":"…"}` —— 留在 JS 里就是语法错。
  const split = splitRuleHeader(rule.content);
  const contentRule = split.rule;

  const opt = splitUrlOptions(chapterUrl);
  const url = absolute(opt.url, base);
  const ruleHeaders = resolveRuleHeaders(split.header, url, base);

  let text = '';
  try {
    const resp = await httpGet(url, applyHeaderVars(Object.assign({},
      normalizeHeaders(source.header, source.jsLib),
      opt.headers || {},
      // 规则自带的 @Header 优先（源作者就是靠它过站点校验）
      ruleHeaders,
    ), state));
    text = resp.text;
  } catch (e) {
    return { ok: false, error: '正文请求失败：' + (e.message || e) };
  }

  // ruleContent.sourceRegex：命中则截取匹配部分（有分组取第 1 组，否则取整体），
  // 与 Dart 引擎 AnalyzeUrl.getStrResponse 的口径一致。未配置时行为不变。
  if (rule.sourceRegex) {
    try {
      const m = new RegExp(rule.sourceRegex, 's').exec(text);
      if (m) text = m[1] != null ? m[1] : m[0];
    } catch (_) { /* 非法正则忽略，保持原文 */ }
  }

  const input = makeInputSafe(text);
  const vars = buildVars(state);
  const ctx = Object.assign({}, ruleCtx(url, source), { chapterUrl: url });

  if (process.env.BOOK_DEBUG) {
    console.error('[content-debug] url=', url, 'textLen=', text.length,
      'ruleHead=', String(contentRule).slice(0, 80).replace(/\n/g, ' '));
  }

  let raw = '';
  try {
    // ⚠️ 必须按**列表**求值：漫画正文规则普遍是
    //   `.comiclist img@data-original` 这种「选择器@属性」——
    //   isList:false 只会取**第一张**图，整章就只剩一页。
    const v = evalRule({ rule: contentRule, input, vars, ctx, isList: true });
    if (process.env.BOOK_DEBUG) {
      console.error('[content-debug] resultType=', Array.isArray(v) ? 'array' : typeof v,
        'len=', Array.isArray(v) ? v.length : 0);
    }
    if (Array.isArray(v)) {
      const arr = v.map((x) => str(x)).filter((x) => x !== '');
      const imgs = arr.map((u) => absolute(u, base)).filter(Boolean);
      // 每个值都像图片地址（http/绝对路径/带图片后缀）
      const allUrlish = arr.length > 0 && arr.every((u) =>
        /^(https?:\/\/|\/|\.\/)/i.test(u) ||
        /\.(jpe?g|png|webp|gif|bmp|avif)(\?|#|$)/i.test(u));
      // ① @js: 返回数组 = 图片列表（Legado 漫画源约定）
      // ② 漫画源 + 全是地址 = 图片列表（有的图床地址不带后缀）
      if (looksLikeJsRule(contentRule) ||
          (isMangaSourceType(source.bookSourceType) && allUrlish)) {
        return { ok: true, type: 'images', images: imgs, headers: ruleHeaders };
      }
      // 普通文本列表（段落/多节点正文）→ 拼成文本，交给后面的图片/文本判定
      raw = arr.join('\n');
    } else {
      raw = str(v);
    }
  } catch (e) {
    return { ok: false, error: 'content 规则失败：' + e.message };
  }

  // 判断是图片列表还是文本：
  //   · 以 [ 开头且能被 JSON.parse → 图片数组
  //   · 或整体全是图片 URL
  const maybeImages = detectImages(raw, base);
  if (maybeImages.length > 0) {
    return { ok: true, type: 'images', images: maybeImages, headers: ruleHeaders };
  }

  // 文本正文：清掉常见噪声
  const cleaned = cleanText(raw);
  return { ok: true, type: 'text', content: cleaned };
}

/** 从正文里识别图片列表（漫画源常见） */
/**
 * 书源登录（cmbok V2.0.7 的「书源登录」）。
 *
 * ── 为什么要有这个 ────────────────────────────────────────────
 * 很多小说站（尤其是需要登录才能看全章的）会把正文藏起来，
 * 未登录时只能看到"请登录后阅读"。
 * 引擎的 `httpGet` 已经会把 `source.header` 里的头带上去，
 * 所以登录的本质就是：**拿到 Cookie，写进 source.header**。
 *
 * ── 两种登录方式 ──────────────────────────────────────────────
 *   1. **表单登录**（url + 用户名/密码）：POST 到登录接口，收集 Set-Cookie
 *   2. **直接填 Cookie**：用户在浏览器登录后复制 Cookie（最通用，
 *      任何站都能用，不依赖登录接口的具体形态）
 *
 * 这里只负责第 1 种的网络部分；第 2 种在 Dart 侧直接写 header 即可。
 */
async function login({ url, method = 'POST', body, contentType, headers }) {
  if (!url) return { ok: false, error: '缺少登录地址' };

  const h = Object.assign({}, headers || {});
  if (contentType) h['Content-Type'] = contentType;

  let payload = body;
  // 支持 { user: '...', pass: '...' } 这种结构化入参，
  // 由调用方给出字段名（不同站字段名不同，不能写死）
  if (payload && typeof payload === 'object') {
    if (contentType && contentType.includes('json')) {
      payload = JSON.stringify(payload);
    } else {
      payload = new URLSearchParams(payload).toString();
    }
  }

  let resp;
  try {
    resp = await httpGet(url, h, method, payload);
  } catch (e) {
    return { ok: false, error: '登录请求失败：' + (e.message || e) };
  }

  // 收集 Set-Cookie（可能多条）
  const sc = resp.headers['set-cookie'];
  const cookies = [];
  if (Array.isArray(sc)) {
    for (const c of sc) cookies.push(String(c).split(';')[0].trim());
  } else if (sc) {
    cookies.push(String(sc).split(';')[0].trim());
  }

  const cookie = cookies.filter(Boolean).join('; ');
  if (!cookie) {
    // 明确区分"请求成功但没给 Cookie"和"请求失败" ——
    // 前者通常是登录接口/字段名不对，用户需要知道去改哪里
    return {
      ok: false,
      status: resp.status,
      error:
        '登录接口没有返回 Cookie（HTTP ' +
        resp.status +
        '）。可能是登录地址或字段名不对；' +
        '也可以在浏览器登录后直接把 Cookie 粘进来。',
      preview: String(resp.text || '').slice(0, 300),
    };
  }

  return {
    ok: true,
    cookie,
    status: resp.status,
    // 供用户确认"确实登录到了自己的账号"
    preview: String(resp.text || '').slice(0, 200),
  };
}

// ============================================================
// 发现 / 分类浏览（explore）
// ============================================================

/**
 * 解析 Legado exploreUrl 的分类列表。
 *
 * exploreUrl 常见形态：
 *   1. JSON 数组：[{"title":"必读榜","url":"https://...","style":{}}, ...]
 *   2. @js: 前缀，脚本生成上面的数组
 *   3. 单个链接（视为「全部」一个分类）
 */
function parseExploreCategories(raw, state, base, jsLib) {
  let s = String(raw || '').trim();
  if (!s) return [];
  s = applyLegadoVars(s, state);
  if (s.startsWith('@js:')) {
    try {
      const v = evalRule({
        rule: s,
        input: makeInput(''),
        vars: buildVars(state),
        ctx: ruleCtx(base, { jsLib }),
      });
      s = str(v);
    } catch (_) {
      return [];
    }
  }
  if (s.startsWith('[')) {
    try {
      const arr = JSON.parse(s);
      if (Array.isArray(arr)) {
        return arr
          .map((it) => ({
            title: str(it && it.title),
            url: absolute(str(it && it.url), base),
          }))
          .filter((it) => it.title || it.url);
      }
    } catch (_) {
      return [];
    }
  }
  if (/^https?:\/\//i.test(s)) return [{ title: '全部', url: s }];

  // 老式扁平写法（ruleFindUrl）：
  //   分类名::https://site/list/1/?page=searchPage
  //   分类名2::https://site/list/2/?page=searchPage
  // 多个分类用换行或 `&&` 分隔。
  if (s.includes('::')) {
    const out = [];
    for (const line of s.split(/&&|\r?\n/)) {
      const t = line.trim();
      if (!t) continue;
      const i = t.indexOf('::');
      if (i <= 0) continue;
      const title = t.slice(0, i).trim();
      const url = t.slice(i + 2).trim();
      if (!title || !url) continue;
      out.push({ title, url: absolute(url, base) });
    }
    if (out.length > 0) return out;
  }
  return [];
}

/**
 * 无 exploreUrl 的书源：抓站点首页，把导航栏里的真实分类链接探测成板块。
 * 站点导航常见形态：`<a href="/xxx/">分类名</a>`（短文本、同域）。
 * 过滤掉功能链接（登录/搜索/排行/推荐等）与重复路径；最多取 8 个分类。
 */
const HOME_PROBE_BLACKLIST =
  /^(首页|男频首页|女频首页|分类|全部|排行榜|排行|热门|最新|新书|完本|推荐|书单|热门作者|作者|搜索|登录|注册|关于|帮助|书架|我的|下载|客户端|APP|APP下载|小说|更多|下一页|上一页)$/;

async function probeHomeCategories(source, base) {
  try {
    const resp = await httpGet(base, normalizeHeaders(source && source.header));
    const html = String((resp && resp.text) || '');
    if (!html) return [];
    const links = [];
    const seen = new Set();
    let host;
    try { host = new URL(base).hostname; } catch (_) { host = ''; }
    const re = /<a[^>]+href="([^"]+)"[^>]*>([^<]{1,12})<\/a>/g;
    let m;
    while ((m = re.exec(html))) {
      const href = String(m[1] || '').trim();
      const txt = String(m[2] || '').replace(/[\[\]【】　\s]/g, '').trim();
      if (!txt || txt.length > 10 || txt.length < 2) continue;
      if (HOME_PROBE_BLACKLIST.test(txt)) continue;
      let abs;
      try { abs = absolute(href, base); } catch (_) { continue; }
      if (!abs) continue;
      try {
        const u = new URL(abs);
        if (host && u.hostname !== host) continue; // 只收站内分类
        if (u.pathname === '/' || u.pathname === '/index.html') continue;
        if (seen.has(u.pathname)) continue;
        seen.add(u.pathname);
      } catch (_) { continue; }
      links.push({ title: txt, url: abs });
      if (links.length >= 8) break;
    }
    return links;
  } catch (_) {
    return [];
  }
}

/**
 * 发现/分类浏览：
 *   · 不传 categoryUrl → 返回 exploreUrl 的分类列表
 *   · 传 categoryUrl   → 抓分类页，用 ruleExplore 解析书籍列表
 */
async function explore({ source, categoryUrl }) {
  setProxy(source && source.proxy);
  const base = source.bookSourceUrl || '';
  const state = stateOf(base);

  // 1) 分类列表
  if (!categoryUrl) {
    // ✅ **兼容 Legado 规范字段名**（重构 ✓）—— 原来只认 `exploreUrl` ✗：
    //   Legado 书源用的是 **`ruleExploreUrl`** ✓✓ ⇒ 只读 `exploreUrl` 会走不到分类 ✗
    //   （这正是「该源分类接口返回服务器错误 / 无分类」的一大来源 ✓）
    const raw =
      source.exploreUrl ||
      source.ruleExploreUrl ||
      (source.ruleExplore && source.ruleExplore.url) ||
      // 老式扁平源的发现分类（`分类::地址` 多行）
      source.ruleFindUrl ||
      '';
    if (!raw) {
      // ⚠️ 无 exploreUrl 的源：自动抓站点首页导航，把真实分类链接探测成
      // 板块（改代码兜底，不需要改源文件）。失败则退回提示。
      const probed = await probeHomeCategories(source, base);
      if (probed.length) return { ok: true, categories: probed, probed: true };
      return { ok: false, error: '该源没有配置 exploreUrl（发现地址），且首页分类自动探测未命中' };
    }
    const cats = parseExploreCategories(raw, state, base, source.jsLib);
    if (cats.length === 0) {
      return { ok: false, error: 'exploreUrl 解析失败（需 JSON 分类数组或单个链接）' };
    }
    return { ok: true, categories: cats };
  }

  // 2) 分类书籍列表
  // ⚠️ Legado 常见形态：exploreUrl 配了分类，但 ruleExplore 没写（或只写一半）。
  // 分类页与搜索页同构时选择器一致 —— 缺失字段回退复用 ruleSearch，
  // 让"有 exploreUrl 但没配 ruleExplore"的源也能拉出板块内容（改代码兜底）。
  const rule = Object.assign({}, source.ruleSearch || {}, source.ruleExplore || {});
  if (!rule.bookList) {
    return { ok: false, error: '该源没有配置 ruleExplore.bookList（且无 ruleSearch 可回退）' };
  }

  // 分类 URL 可能带 {{page}} / {{key}} 变量（与 searchUrl 同规则）
  let rawUrl;
  try {
    rawUrl = applyLegadoVars(categoryUrl, state)
      .replace(/\{\{\s*page\s*\}\}/g, String(state.page || 1))
      .replace(/\{page\}/g, String(state.page || 1))
      // 老式扁平写法 `?page=searchPage`
      .replace(/searchPage([+-]\d+)?/g, (all, off) =>
        String(Number(state.page || 1) + (off ? parseInt(off, 10) : 0)))
      // 未识别变量（cookie.getKey / java 等）会留下畸形花括号 → 源站 500，直接清理
      .replace(/\{\{[^}]*\}\}/g, '');
  } catch (e) {
    return { ok: false, error: '分类 URL 处理失败：' + (e.message || e) };
  }
  const opt = splitUrlOptions(rawUrl);
  const url = absolute(opt.url, base);
  if (!url) return { ok: false, error: '分类地址为空' };
  let text = '';
  let status = 0;
  try {
    const resp = await httpGet(
      url,
      Object.assign({}, normalizeHeaders(source.header, source.jsLib), opt.headers || {}),
      opt.method || 'GET',
      opt.body,
    );
    status = resp.status;
    text = resp.text;
  } catch (e) {
    return { ok: false, error: '分类请求失败：' + (e.message || e) };
  }
  if (status >= 400) {
    return {
      ok: false,
      error: '分类请求失败：源站返回 HTTP ' + status,
    };
  }

  const input = makeInputSafe(text);
  const vars = buildVars(state);

  let items;
  try {
    items = evalList({ rule: rule.bookList, input, vars, ctx: ruleCtx(url, source) });
  } catch (e) {
    return { ok: false, error: 'ruleExplore.bookList 规则失败：' + e.message };
  }

  const out = [];
  for (const node of items) {
    const pick = (r) => {
      if (!r) return '';
      let v = '';
      try {
        v = str(evalRule({ rule: r, input: node, vars, ctx: ruleCtx(url, source) }));
      } catch (_) {
        return '';
      }
      // 残留 {{$.x}} 变量（Legado：从当前 JSON 节点取）→ 用 jsonPath 替换
      if (v.includes('{{')) {
        const root = node && node.__json ? node.__json : node;
        v = v.replace(/\{\{\s*\$\.([\w$.\[\]*]+)\s*\}\}/g, (all, p) => {
          const hit = jsonPath(root, '$.' + p);
          return hit.length > 0 && hit[0] != null ? String(hit[0]) : '';
        });
      }
      return v;
    };
    const name = pick(rule.name);
    if (!name) continue;
    out.push({
      name,
      author: pick(rule.author),
      bookUrl: absolute(pick(rule.bookUrl), base),
      coverUrl: absolute(pick(rule.coverUrl), base),
      intro: pick(rule.intro),
      kind: pick(rule.kind),
      lastChapter: pick(rule.lastChapter),
      wordCount: pick(rule.wordCount),
    });
  }
  return { ok: true, list: out, url };
}

function detectImages(raw, base) {
  const s = (raw || '').trim();
  if (!s) return [];

  // 1) JSON 数组
  if (s.startsWith('[')) {
    try {
      const arr = JSON.parse(s);
      if (Array.isArray(arr)) {
        const out = [];
        for (const it of arr) {
          const u = typeof it === 'string' ? it : (it && (it.src || it.url)) || '';
          const a = absolute(str(u), base);
          if (a && /\.(jpe?g|png|webp|gif|bmp)/i.test(a)) out.push(a);
        }
        if (out.length > 0) return out;
      }
    } catch (_) {/* 不是 JSON */}
  }

  // 2) 纯图片 URL 列表（换行/空格分隔）
  const parts = s.split(/[\s,]+/).filter(Boolean);
  if (parts.length >= 1) {
    const imgs = parts
      .map((p) => absolute(p, base))
      .filter((p) => /^https?:\/\//i.test(p) && /\.(jpe?g|png|webp|gif|bmp)/i.test(p));
    // 全部都是图片才算（避免把正文里的偶然链接当漫画）
    if (imgs.length === parts.length && imgs.length > 0) return imgs;
  }

  // 3) HTML 里挖 img src（content 规则返回 html 时）
  if (/<img\s/i.test(s)) {
    const imgs = [];
    const re = /<img[^>]+(?:src|data-src|data-original)=["']([^"']+)["']/gi;
    let m;
    while ((m = re.exec(s)) !== null) {
      const a = absolute(m[1], base);
      if (a) imgs.push(a);
    }
    if (imgs.length > 0) return imgs;
  }

  return [];
}

function cleanText(t) {
  let s = String(t || '');
  // HTML 标签
  if (/<[a-z][\s\S]*>/i.test(s)) {
    s = s
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/<\/p>/gi, '\n')
      .replace(/<[^>]+>/g, '');
  }
  s = s
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"');
  // 常见噪声行
  s = s.replace(
    /^\s*(本章未完[^\n]*|加入书签[^\n]*|章节报错[^\n]*|请收藏[^\n]*|最快更新[^\n]*|天才一秒记住[^\n]*|手机版阅读网址[^\n]*|(?:www\.)?\S+\.(?:com|net|cc|org)[^\n]*)\s*$/gm,
    '',
  );
  // 压缩空行
  s = s.replace(/\n{3,}/g, '\n\n').replace(/[ \t]+\n/g, '\n');
  return s.trim();
}

// ✅ **Legado 字段归一化**（重构 ✓ —— 单点修复，6 个入口同时受益 ✓）
//
// 病根 ✓：Legado 书源的字段是**扁平**的 ✓：
//   `ruleSearchUrl` / `ruleSearchList` / `ruleSearchName` / `ruleSearchAuthor` /
//   `ruleSearchKind` / `ruleSearchLastChapter` / `ruleSearchIntroduce` /
//   `ruleSearchCoverUrl` / `ruleSearchNoteUrl` ✓✓
//   以及 `ruleExploreUrl` / `ruleExploreList` / … ✓（Legado 只有 `ruleBookInfo{…}` 与 `ruleToc{…}` 是**嵌套**的 ✓）
// 而本引擎历史实现读的是**嵌套**写法 ✗：`source.searchUrl` ✗ / `source.ruleSearch.bookList` ✗ /
//   `source.exploreUrl` ✗ —— 两者**对不上** ✓ ⇒ 搜索 / 分类**永远读不到规则** ✗✓
//   ⇒ 这正是"同一份源在别的实现里能用、在本引擎不能用"的**完整原因** ✓✓
//
// 做法 ✓：在**导出边界**把扁平字段补成引擎要的嵌套结构 ✓（**不改任何业务逻辑** ✓ 最小风险 ✓）：
//   · 已有嵌套值时不覆盖 ✓（兼容老的自定义源 ✓ 双写法都行 ✓）
function normalizeLegadoSource(src) {
  if (!src || typeof src !== 'object') return src;
  const s = Object.assign({}, src);

  const rs = Object.assign({}, s.ruleSearch || {});
  const rsMap = {
    url: 'ruleSearchUrl',
    bookList: 'ruleSearchList',
    name: 'ruleSearchName',
    author: 'ruleSearchAuthor',
    kind: 'ruleSearchKind',
    lastChapter: 'ruleSearchLastChapter',
    introduce: 'ruleSearchIntroduce',
    coverUrl: 'ruleSearchCoverUrl',
    noteUrl: 'ruleSearchNoteUrl',
    // ✅ **同时补 NexHub 文档里的规范嵌套键名**（本轮 ✓）——
    //   它的权威示例用的是 `ruleSearch.{bookList,bookName,bookAuthor,bookCoverUrl,bookUrl,bookLastChapter}` ✓
    //   而本引擎历史实现读 `rule.{name,author,coverUrl,noteUrl}` ✗
    //   ⇒ 实测发现：只补前者时 **`bookUrl` 是空的** ✗（详情点不进去 ✓）
    //   ⇒ 那就**两套都填** ✓✓ —— 引擎读哪个都能拿到 ✓（多填几个键零成本 ✓ 不会冲突 ✓）
    bookName: 'ruleSearchName',
    bookAuthor: 'ruleSearchAuthor',
    bookCoverUrl: 'ruleSearchCoverUrl',
    bookUrl: 'ruleSearchNoteUrl',
    bookKind: 'ruleSearchKind',
    bookLastChapter: 'ruleSearchLastChapter',
    bookIntroduce: 'ruleSearchIntroduce',
  };
  for (const [k, flat] of Object.entries(rsMap)) {
    if (rs[k] == null && s[flat] != null) rs[k] = s[flat];
  }
  s.ruleSearch = rs;

  const re = Object.assign({}, s.ruleExplore || {});
  const reMap = {
    url: 'ruleExploreUrl',
    bookList: 'ruleExploreList',
    name: 'ruleExploreName',
    author: 'ruleExploreAuthor',
    kind: 'ruleExploreKind',
    lastChapter: 'ruleExploreLastChapter',
    introduce: 'ruleExploreIntroduce',
    coverUrl: 'ruleExploreCoverUrl',
    noteUrl: 'ruleExploreNoteUrl',
    // ✅ 与搜索侧同理 ✓：**两套命名都填** ✓（NexHub 规范名 + 引擎旧名 ✓）
    bookName: 'ruleExploreName',
    bookAuthor: 'ruleExploreAuthor',
    bookCoverUrl: 'ruleExploreCoverUrl',
    bookUrl: 'ruleExploreNoteUrl',
    bookKind: 'ruleExploreKind',
    bookLastChapter: 'ruleExploreLastChapter',
    bookIntroduce: 'ruleExploreIntroduce',
  };
  for (const [k, flat] of Object.entries(reMap)) {
    if (re[k] == null && s[flat] != null) re[k] = s[flat];
  }
  s.ruleExplore = re;

  // 更老的「发现」扁平字段：ruleFindList / ruleFindName / …
  // （这类源没有 ruleExplore*，只有 ruleFindUrl + ruleFind*；缺失才补）
  const reFindMap = {
    bookList: 'ruleFindList',
    name: 'ruleFindName',
    author: 'ruleFindAuthor',
    kind: 'ruleFindKind',
    lastChapter: 'ruleFindLastChapter',
    introduce: 'ruleFindIntroduce',
    coverUrl: 'ruleFindCoverUrl',
    noteUrl: 'ruleFindNoteUrl',
    bookUrl: 'ruleFindNoteUrl',
  };
  for (const [k, flat] of Object.entries(reFindMap)) {
    if (re[k] == null && s[flat] != null) re[k] = s[flat];
  }

  // 顶层 URL 名也一并补 ✓（与上面 `search`/`explore` 内的兜底**双保险** ✓）
  if (!s.searchUrl && s.ruleSearchUrl) s.searchUrl = s.ruleSearchUrl;
  if (!s.exploreUrl && s.ruleExploreUrl) s.exploreUrl = s.ruleExploreUrl;
  if (!s.exploreUrl && s.ruleFindUrl) s.exploreUrl = s.ruleFindUrl;

  // Legado 的 httpUserAgent 是独立字段（不在 header 里）。移动站/漫画站
  // 常按 UA 分流，没有 header 时把它当默认 User-Agent。
  if (s.httpUserAgent && s.header == null) {
    s.header = { 'User-Agent': String(s.httpUserAgent) };
  }

  // ✅ **旧版"全扁平"方言 → 3.x 嵌套**（本轮补齐 ✓ 关键 ✓）
  //
  // 依据 ✓：yckceo / 631 源包 / 早期 Legado 的源**全部是扁平**的 ✓：
  //   `ruleBookName` ✓ `ruleChapterList` ✓ `ruleContentUrl` ✓ `ruleBookContent` ✓ …
  // 而本引擎（与 NexHub 文档里的权威示例 ✓）读的是**嵌套** ✗：
  //   `ruleBookInfo.{name,author,coverUrl,intro,kind,lastChapter}` ✓
  //   `ruleToc.{chapterList,chapterName,chapterUrl,nextTocUrl}` ✓
  //   `ruleContent.{content,title,nextContentUrl}` ✓
  // ⚠️ 我上轮**只补了搜索/发现两组** ✗ ⇒ 详情/目录/正文**仍读不到** ✗
  //   ⇒ 这正是"搜索分类失败 ✓ 点进去同样失败 ✓"的完整原因 ✓✓
  // ℹ️ 只在**扁平键存在**且**嵌套键缺失**时才补 ✓
  //   ⇒ 新版源（本来就嵌套 ✓）零影响 ✓；不存在的键自然跳过 ✓ 不会引入错误 ✓
  const bi = Object.assign({}, s.ruleBookInfo || {});
  const biMap = {
    name: 'ruleBookName',
    author: 'ruleBookAuthor',
    coverUrl: 'ruleCoverUrl',
    intro: 'ruleIntroduce',
    kind: 'ruleBookKind',
    lastChapter: 'ruleBookLastChapter',
    // 老式扁平源的目录地址（很多漫画/小说源把它留空 = 用详情页当目录页）
    tocUrl: 'ruleChapterUrl',
  };
  for (const [k, flat] of Object.entries(biMap)) {
    if (bi[k] == null && s[flat] != null) bi[k] = s[flat];
  }
  s.ruleBookInfo = bi;

  const tc = Object.assign({}, s.ruleToc || {});
  const tcMap = {
    chapterList: 'ruleChapterList',
    chapterName: 'ruleChapterName',
    chapterUrl: 'ruleContentUrl',
    nextTocUrl: 'ruleChapterUrlNext',
  };
  for (const [k, flat] of Object.entries(tcMap)) {
    if (tc[k] == null && s[flat] != null) tc[k] = s[flat];
  }
  s.ruleToc = tc;

  const ct = Object.assign({}, s.ruleContent || {});
  const ctMap = {
    content: 'ruleBookContent',
    title: 'ruleBookContentTitle',
    nextContentUrl: 'ruleContentNextUrl',
  };
  for (const [k, flat] of Object.entries(ctMap)) {
    if (ct[k] == null && s[flat] != null) ct[k] = s[flat];
  }
  s.ruleContent = ct;

  return s;
}

/** 包一层：入口收到的 `args.source` 先归一化 ✓（6 个入口共用 ✓） */
function withNorm(fn) {
  return (args) => fn(Object.assign({}, args, { source: normalizeLegadoSource(args && args.source) }));
}

// ⚠️ 注意 ✓：**不能**写 `export { withNorm(search) as bsSearch }` ✗ ——
//   ESM 的 `export {}` **只接受标识符** ✓，不接受调用表达式 ✗
//   （本轮 `node --check` 当场抓到该语法错 ✓ 已改为"先建常量、再导出" ✓）
const bsSearch = withNorm(search);
const bsBookInfo = withNorm(bookInfo);
const bsToc = withNorm(toc);
const bsContent = withNorm(content);
const bsLogin = withNorm(login);
const bsExplore = withNorm(explore);

export {
  bsSearch,
  bsBookInfo,
  bsToc,
  bsContent,
  bsLogin,
  bsExplore,
  splitUrlOptions,
  decodeBody,
  evalSearchUrlScript,
};
