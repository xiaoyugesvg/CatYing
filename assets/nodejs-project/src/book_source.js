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

import { evalRule, evalList, makeInput, jsonPath } from './book_rule.js';

import axios from 'axios';

// 说明：本文件与 main.js 同为 ESM（package.json type=module），
// esbuild 打包成 CJS 时会正确转换 import/export。
// 之前用 module.exports 会被塞进 ESM 模块作用域 → 导出为空对象。


const HTTP_TIMEOUT_MS = 15000;

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
    const cfg = JSON.parse(jsonPart);
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
  const u = String(url || '').trim();
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
function normalizeHeaders(h) {
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
          ctx: { baseUrl: '' },
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

// ============================================================
// 结果规整
// ============================================================

function str(v) {
  if (v == null) return '';
  if (Array.isArray(v)) return v.map((x) => str(x)).join('\n');
  return String(v).trim();
}

// ============================================================
// 搜索
// ============================================================

async function search({ source, keyword, page = 1 }) {
  setProxy(source && source.proxy);
  const base = source.bookSourceUrl || '';
  const state = stateOf(base);
  state.key = keyword;
  state.page = page;

  let rawUrl = source.searchUrl;
  if (!rawUrl) return { ok: false, error: '该源没有配置 searchUrl' };

  // {{key}} {{page}}
  rawUrl = applyLegadoVars(rawUrl, state)
    .replace(/\{\{\s*key\s*\}\}/g, encodeURIComponent(keyword))
    .replace(/\{\{\s*page\s*\}\}/g, String(page))
    .replace(/\{key\}/g, encodeURIComponent(keyword))
    .replace(/\{page\}/g, String(page));

  const opt = splitUrlOptions(rawUrl);
  if (opt.webView) {
    return { ok: false, error: '该源的搜索需要浏览器内核（webView），当前不支持' };
  }

  const url = absolute(opt.url, base);
  const headers = Object.assign({}, normalizeHeaders(source.header), opt.headers || {});

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
    items = evalList({ rule: rule.bookList, input, vars, ctx: { baseUrl: url } });
  } catch (e) {
    return { ok: false, error: 'bookList 规则失败：' + e.message };
  }

  const out = [];
  for (const node of items) {
    const pick = (r) => {
      if (!r) return '';
      try {
        return str(evalRule({ rule: r, input: node, vars, ctx: { baseUrl: url } }));
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
        ctx: { baseUrl: bookUrl, result: bookUrl },
      });
    } catch (_) {/* 忽略 */}
  }

  let input;
  let finalUrl = bookUrl;
  try {
    const resp = await httpGet(bookUrl, normalizeHeaders(source.header));
    input = makeInputSafe(resp.text);
  } catch (e) {
    // 详情页拿不到也不算致命：目录可能仍能取
    input = makeInput('');
  }

  const vars = buildVars(state);
  const pick = (r, dflt = '') => {
    if (!r) return dflt;
    try {
      const v = str(evalRule({ rule: r, input, vars, ctx: { baseUrl: bookUrl } }));
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
    const resp = await httpGet(url, Object.assign({}, normalizeHeaders(source.header), opt.headers || {}));
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

  let items;
  try {
    items = evalList({ rule: rule.chapterList, input, vars, ctx: { baseUrl: url } });
  } catch (e) {
    return { ok: false, error: 'chapterList 规则失败：' + e.message };
  }

  const out = [];
  for (const node of items) {
    const pick = (r) => {
      if (!r) return '';
      try {
        return str(evalRule({ rule: r, input: node, vars, ctx: { baseUrl: url } }));
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

  const opt = splitUrlOptions(chapterUrl);
  const url = absolute(opt.url, base);

  let text = '';
  try {
    const resp = await httpGet(url, Object.assign({}, normalizeHeaders(source.header), opt.headers || {}));
    text = resp.text;
  } catch (e) {
    return { ok: false, error: '正文请求失败：' + (e.message || e) };
  }

  const input = makeInputSafe(text);
  const vars = buildVars(state);
  const ctx = { baseUrl: url, chapterUrl: url };

  let raw = '';
  try {
    const v = evalRule({ rule: rule.content, input, vars, ctx });
    // 规则可能直接返回数组（漫画）
    if (Array.isArray(v)) {
      return {
        ok: true,
        type: 'images',
        images: v.map((u) => absolute(str(u), base)).filter((u) => u),
      };
    }
    raw = str(v);
  } catch (e) {
    return { ok: false, error: 'content 规则失败：' + e.message };
  }

  // 判断是图片列表还是文本：
  //   · 以 [ 开头且能被 JSON.parse → 图片数组
  //   · 或整体全是图片 URL
  const maybeImages = detectImages(raw, base);
  if (maybeImages.length > 0) {
    return { ok: true, type: 'images', images: maybeImages };
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
function parseExploreCategories(raw, state, base) {
  let s = String(raw || '').trim();
  if (!s) return [];
  s = applyLegadoVars(s, state);
  if (s.startsWith('@js:')) {
    try {
      const v = evalRule({
        rule: s,
        input: makeInput(''),
        vars: buildVars(state),
        ctx: { baseUrl: base },
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
  return [];
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
    const raw = source.exploreUrl;
    if (!raw) return { ok: false, error: '该源没有配置 exploreUrl（发现地址）' };
    const cats = parseExploreCategories(raw, state, base);
    if (cats.length === 0) {
      return { ok: false, error: 'exploreUrl 解析失败（需 JSON 分类数组或单个链接）' };
    }
    return { ok: true, categories: cats };
  }

  // 2) 分类书籍列表
  const rule = source.ruleExplore || {};
  if (!rule.bookList) {
    return { ok: false, error: '该源没有配置 ruleExplore.bookList' };
  }

  // 分类 URL 可能带 {{page}} / {{key}} 变量（与 searchUrl 同规则）
  let rawUrl;
  try {
    rawUrl = applyLegadoVars(categoryUrl, state)
      .replace(/\{\{\s*page\s*\}\}/g, String(state.page || 1))
      .replace(/\{page\}/g, String(state.page || 1))
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
      Object.assign({}, normalizeHeaders(source.header), opt.headers || {}),
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
    items = evalList({ rule: rule.bookList, input, vars, ctx: { baseUrl: url } });
  } catch (e) {
    return { ok: false, error: 'ruleExplore.bookList 规则失败：' + e.message };
  }

  const out = [];
  for (const node of items) {
    const pick = (r) => {
      if (!r) return '';
      let v = '';
      try {
        v = str(evalRule({ rule: r, input: node, vars, ctx: { baseUrl: url } }));
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

export { search as bsSearch, bookInfo as bsBookInfo, toc as bsToc, content as bsContent, login as bsLogin, explore as bsExplore, splitUrlOptions, decodeBody };
