// REX / ForwardWidget 模块宿主（Node 侧）
//
// ── 这是什么 ──────────────────────────────────────────────────
// REX 模块就是一段 JS：顶层给 `WidgetMetadata` 赋值，再定义
// `loadList / loadDetail / loadResource / search` 等函数。
// 宿主只需要提供 `Widget.http`（axios）与 `Widget.html`（cheerio），
// 在 `vm` 沙箱里跑模块，然后把返回值整理成统一的 JSON 给 Dart。
//
// ── 和现有引擎的关系 ──────────────────────────────────────────
// 思路与 lx_engine / hiker_engine 一致：**模块代码不可信**，
// 所以用 vm 上下文隔离、不提供 require/process，网络只能走宿主注入的
// `Widget.http`（带超时与响应体上限）。顶层同步代码有 vm timeout；
// 异步函数用 Promise.race 再兜一层。
//
// ── 协议 ─────────────────────────────────────────────────────
//   { action: 'load'     , url }
//   { action: 'list'     , url, functionName?, params? }
//   { action: 'detail'   , url, link }
//   { action: 'resource' , url, params? | link }
//   { action: 'search'   , url, keyword, page? }
import vm from 'node:vm';
import axios from 'axios';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import * as cheerioNs from 'cheerio';

const cheerio = cheerioNs.default ?? cheerioNs;

const FETCH_TIMEOUT_MS = 20000;
const CALL_TIMEOUT_MS = 30000;
const TOP_LEVEL_TIMEOUT_MS = 8000;
const MAX_SOURCE_BYTES = 4 * 1024 * 1024;
const MAX_HTTP_BYTES = 12 * 1024 * 1024;

const UA =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) ' +
  'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Mobile/15E148 Safari/604.1';

/** url → { meta, fns, ctx } */
const moduleCache = new Map();

function clampInt(v, min, max, fallback) {
  const n = Number(v);
  if (!Number.isFinite(n)) return fallback;
  return Math.max(min, Math.min(max, Math.trunc(n)));
}

function withTimeout(promise, ms, label) {
  let timer = null;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`${label} 超时（${Math.round(ms / 1000)} 秒）`)),
      ms
    );
  });
  return Promise.race([promise, timeout]).finally(() => {
    if (timer) clearTimeout(timer);
  });
}

/**
 * 把 axios / 系统异常翻译成一句人话。
 *
 * 🔴 原来直接把 `e.message` 抛出去：站点返回 500 时用户看到的是
 * 「badResponse (This exception was thrown because the response has a
 * status code of 500 and RequestOptions.validateStatus was configured to
 * throw for this status code…)」整整一屏英文 —— 既看不懂也没法排查。
 * 现在统一成「站点返回 HTTP 500」这类短句。
 */
function friendlyError(e) {
  const raw = String((e && e.message) || e || '');
  const status =
    (e && e.response && e.response.status) ||
    (e && e.status) ||
    (e && e.statusCode);
  if (status) return `站点返回 HTTP ${status}`;
  if (/timeout|timed out/i.test(raw)) return '请求超时';
  if (/ENOTFOUND|EAI_AGAIN|getaddrinfo/i.test(raw)) return '域名解析失败';
  if (/ECONNREFUSED/i.test(raw)) return '连接被拒绝';
  if (/ECONNRESET|socket hang up|network|TLS/i.test(raw)) return '网络连接中断';
  if (/not a function|is not defined|SyntaxError|Unexpected token/i.test(raw)) {
    return `模块代码执行出错：${raw.slice(0, 80)}`;
  }
  return raw.length > 120 ? `${raw.slice(0, 120)}…` : raw;
}

function normalizeHeaders(raw) {
  const out = {};
  if (raw && typeof raw === 'object') {
    for (const [k, v] of Object.entries(raw)) {
      if (v == null) continue;
      out[String(k)] = String(v);
    }
  }
  return out;
}

async function fetchText(url, headers) {
  const res = await axios.get(url, {
    timeout: FETCH_TIMEOUT_MS,
    responseType: 'text',
    maxContentLength: MAX_SOURCE_BYTES,
    headers: { 'User-Agent': UA, ...(headers || {}) },
    validateStatus: (s) => s >= 200 && s < 400,
    transformResponse: [(d) => d],
  });
  return typeof res.data === 'string' ? res.data : String(res.data ?? '');
}

// ── Widget.storage ──────────────────────────────────────────────
// REX 规范里模块可以读写一份**同步**的键值存储（原 App 用 UserDefaults）。
// 我们以前完全没提供 ⇒ 用到它的模块要么每次重取游客 token，要么中文标题
// 缓存永远命中不了（用户 2026-10-31 拿 ONE一个 / SupJav 试出来的）。
//
// ⚠️ 必须是**同步**的：ONE一个 里写的是 `var raw = Widget.storage.get(k)`，
//    不 await；返回 Promise 的话 `typeof raw === 'string'` 永远为假。
//    所以这里用「内存对象 + 异步防抖落盘」，get/set 都是同步返回。
const STORE_ROOT = (() => {
  try {
    const base = process.env['NODE_PATH'] || os.tmpdir() || '.';
    const dir = path.join(base, 'rex_store');
    fs.mkdirSync(dir, { recursive: true });
    return dir;
  } catch (_) {
    return '';
  }
})();

const storeCache = new Map(); // ns → { ns, data, timer }

function storeFile(ns) {
  if (!STORE_ROOT) return '';
  const h = crypto.createHash('sha1').update(ns).digest('hex').slice(0, 16);
  return path.join(STORE_ROOT, `${h}.json`);
}

function storeFor(ns) {
  const key = ns || 'default';
  const hit = storeCache.get(key);
  if (hit) return hit;
  let data = {};
  try {
    const f = storeFile(key);
    if (f && fs.existsSync(f)) {
      const j = JSON.parse(fs.readFileSync(f, 'utf8'));
      if (j && typeof j === 'object' && !Array.isArray(j)) data = j;
    }
  } catch (_) {
    /* 读不出来就当空存储，模块自己会重建 */
  }
  const s = { ns: key, data, timer: null };
  storeCache.set(key, s);
  return s;
}

function flushStore(s) {
  if (s.timer) return;
  s.timer = setTimeout(() => {
    s.timer = null;
    try {
      const f = storeFile(s.ns);
      if (f) fs.writeFileSync(f, JSON.stringify(s.data));
    } catch (_) {
      /* 落盘失败不影响本次会话 */
    }
  }, 400);
  // 别让这个定时器拖住进程退出
  if (s.timer && typeof s.timer.unref === 'function') s.timer.unref();
}

function buildStorage(ns) {
  const s = storeFor(ns);
  return {
    get: (k) => {
      const v = s.data[String(k)];
      return v === undefined ? null : v;
    },
    set: (k, v) => {
      s.data[String(k)] = v === undefined ? null : v;
      flushStore(s);
      return true;
    },
    remove: (k) => {
      delete s.data[String(k)];
      flushStore(s);
      return true;
    },
    clear: () => {
      s.data = {};
      flushStore(s);
      return true;
    },
  };
}

// ── REXENC 加密容器 ────────────────────────────────────────────
// 社区里有一部分模块不是明文 JS，而是这样一段：
//
//   REXENC
//   {"v":2,"mkv":"rex-1","alg":"A256GCM","iv":"<12B>","kb":"<60B>"}
//   <base64 密文>
//
// `kb` = 12 字节 nonce + AES-256-GCM 封好的 32 字节**内容密钥**，
// 用名叫 `rex-1` 的 32 字节主密钥解开；再用内容密钥 + `iv` 解正文。
// 主密钥在 Rex 客户端里，宿主这边只能让用户自己填（见 RexKeys）。
const REXENC_MAGIC = 'REXENC';
const REXENC_NEED_KEY =
  '这是 REXENC 加密模块，需要先在「REX 订阅」页右上角填主密钥';
const REXENC_BAD_KEY = 'REXENC 主密钥不对，解不开这个模块';

function isRexEnc(code) {
  return typeof code === 'string' && code.startsWith(REXENC_MAGIC);
}

function b64buf(s) {
  return Buffer.from(String(s || '').replace(/\s+/g, ''), 'base64');
}

/** AES-256-GCM 拆封；`blob` 末 16 字节是 tag */
function openGcm(key, iv, blob, aad) {
  if (!blob || blob.length <= 16) throw new Error('密文太短');
  const ct = blob.subarray(0, blob.length - 16);
  const tag = blob.subarray(blob.length - 16);
  const d = crypto.createDecipheriv('aes-256-gcm', key, iv);
  if (aad) d.setAAD(aad);
  d.setAuthTag(tag);
  return Buffer.concat([d.update(ct), d.final()]);
}

/** 主密钥接受三种写法：64 位 hex / 44 位 base64 / 32 字节原文 */
function normalizeMasterKey(raw) {
  const s = String(raw || '').trim();
  if (!s) return null;
  if (/^[0-9a-fA-F]{64}$/.test(s)) return Buffer.from(s, 'hex');
  if (s.length === 32) return Buffer.from(s, 'utf8');
  const b = b64buf(s);
  return b.length === 32 ? b : null;
}

/** 只解析头部（Dart 侧的 RexEnvelope 与这里保持同一套规则） */
function parseRexEncHeader(code) {
  const nl1 = code.indexOf('\n');
  const nl2 = nl1 < 0 ? -1 : code.indexOf('\n', nl1 + 1);
  if (nl1 < 0 || nl2 < 0) throw new Error('REXENC 容器损坏：缺少头部');
  let hdr;
  try {
    hdr = JSON.parse(code.slice(nl1 + 1, nl2));
  } catch (_) {
    throw new Error('REXENC 容器损坏：头部不是合法 JSON');
  }
  if (!hdr || typeof hdr !== 'object') {
    throw new Error('REXENC 容器损坏：头部不是对象');
  }
  return { hdr, bodyStart: nl2 + 1 };
}

function decodeRexEnc(code, masterKeyRaw) {
  const { hdr, bodyStart } = parseRexEncHeader(code);
  const v = Number(hdr.v) || 0;
  if (v !== 2) throw new Error(`不支持的 REXENC 版本（v${v}）`);
  const alg = String(hdr.alg || '').toUpperCase();
  if (alg !== 'A256GCM') {
    throw new Error(`不支持的 REXENC 算法（${alg || '未标注'}）`);
  }
  const mk = normalizeMasterKey(masterKeyRaw);
  if (!mk) throw new Error(REXENC_NEED_KEY);

  const kb = b64buf(hdr.kb);
  if (kb.length < 44) throw new Error('REXENC 容器损坏：密钥块太短');
  let contentKey;
  try {
    contentKey = openGcm(mk, kb.subarray(0, 12), kb.subarray(12));
  } catch (_) {
    throw new Error(REXENC_BAD_KEY);
  }
  if (contentKey.length !== 32) throw new Error(REXENC_BAD_KEY);

  const iv = b64buf(hdr.iv);
  if (iv.length !== 12) throw new Error('REXENC 容器损坏：IV 长度不对');
  const body = b64buf(code.slice(bodyStart));
  if (!body.length) throw new Error('REXENC 容器损坏：正文为空');

  // AAD 未在头部标注：先按「无 AAD」解，不行再拿头部原文当 AAD 试一次。
  // GCM 的 tag 校验保证了解错会失败而不是给出乱码，所以多试一次是安全的。
  const aadCandidates = [null, Buffer.from(code.slice(0, bodyStart), 'utf8')];
  for (const aad of aadCandidates) {
    try {
      const plain = openGcm(contentKey, iv, body, aad);
      return plain.toString('utf8');
    } catch (_) {
      /* 换下一个 AAD 猜想 */
    }
  }
  throw new Error('REXENC 内容解密失败：模块文件可能被改动过');
}

/** 模块能用的 `Widget` 对象 */
function buildWidget(storageNs) {
  const request = async (method, url, opts = {}) => {
    const o = opts || {};
    const timeout = clampInt(o.timeout, 1000, 60000, FETCH_TIMEOUT_MS);
    const headers = normalizeHeaders(o.headers);
    if (!headers['User-Agent'] && !headers['user-agent']) {
      headers['User-Agent'] = UA;
    }
    const res = await axios.request({
      url,
      method,
      headers,
      data: o.data ?? o.body,
      timeout,
      maxContentLength: MAX_HTTP_BYTES,
      maxBodyLength: MAX_HTTP_BYTES,
      responseType: 'text',
      validateStatus: () => true,
      transformResponse: [(d) => d],
    });
    let data = res.data;
    // 模块通常自己判断 string/object（Avdb 就是这么写的）；这里能解析就解析
    if (typeof data === 'string') {
      const t = data.trim();
      if (t.startsWith('{') || t.startsWith('[')) {
        try {
          data = JSON.parse(t);
        } catch (_) {
          /* 保持字符串 */
        }
      }
    }
    return { data, status: res.status, headers: res.headers };
  };

  const widget = {
    http: {
      get: (url, opts) => request('get', url, opts),
      post: (url, data, opts) => request('post', url, { ...(opts || {}), data }),
      request: (opts) =>
        request((opts && opts.method) || 'get', opts && opts.url, opts),
    },
    html: {
      load: (html) => cheerio.load(String(html ?? '')),
      parse: (html) => cheerio.load(String(html ?? '')),
    },
    get: (url, opts) => request('get', url, opts),
    post: (url, data, opts) => request('post', url, { ...(opts || {}), data }),
    storage: buildStorage(storageNs),
  };
  return widget;
}

function compileModule(url, code) {
  const widget = buildWidget(url);
  const sandbox = {
    Widget: widget,
    console: {
      log: (...a) => console.log('[REX]', ...a),
      warn: (...a) => console.warn('[REX]', ...a),
      error: (...a) => console.error('[REX]', ...a),
    },
    module: { exports: {} },
    exports: {},
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
    Buffer,
    URL,
    URLSearchParams,
    TextEncoder,
    TextDecoder,
    atob: (s) => Buffer.from(String(s), 'base64').toString('binary'),
    btoa: (s) => Buffer.from(String(s), 'binary').toString('base64'),
    fetch: (u, o) => widget.http.request({ ...(o || {}), url: u }),
  };
  sandbox.globalThis = sandbox;
  sandbox.self = sandbox;
  const ctx = vm.createContext(sandbox);
  new vm.Script(code, { filename: url }).runInContext(ctx, {
    timeout: TOP_LEVEL_TIMEOUT_MS,
  });
  return ctx;
}

function extractModule(url, ctx) {
  const ex = ctx.module && ctx.module.exports ? ctx.module.exports : null;
  let meta = ctx.WidgetMetadata;
  if (!meta && ex) {
    meta = ex.WidgetMetadata || (ex.modules ? ex : null);
  }
  if (!meta || typeof meta !== 'object') {
    throw new Error('不是 REX 模块：找不到 WidgetMetadata');
  }
  const modules = Array.isArray(meta.modules)
    ? meta.modules.map((m) => ({
        id: String((m && m.id) || ''),
        title: String((m && (m.title || m.name)) || ''),
        description: String((m && m.description) || ''),
        functionName: String((m && m.functionName) || ''),
        type: String((m && m.type) || ''),
        params: Array.isArray(m && m.params) ? m.params : [],
      }))
    : [];

  // 收集所有 load*/search* 函数。
  // 🔴 不要只认固定的 7 个名字：社区模块里存在 loadPage / loadCategory /
  //    loadPlaylist / searchVideo 之类的变体，写死名单会把整批模块判成
  //    「模块没有 loadList / search，无法使用」（花花集合里 88 个模块中
  //    光这一类被误杀的就有十几个）。
  const fns = {};
  for (const k of Object.keys(ctx)) {
    if (!/^(load|search)/.test(k)) continue;
    let v;
    try {
      v = ctx[k];
    } catch (_) {
      continue;
    }
    if (typeof v === 'function') fns[k] = v;
  }
  if (ex) {
    for (const k of Object.keys(ex)) {
      if (!/^(load|search)/.test(k)) continue;
      if (typeof ex[k] === 'function' && !fns[k]) fns[k] = ex[k];
    }
  }
  // 一个 load*/search* 都没有 ⇒ 确实不是可用模块。
  // 注意：只导出 loadResource 的「纯播放源」是合法的（挂在影视详情上用），
  // 所以这里不区分类型，一律放行。
  if (Object.keys(fns).length === 0) {
    throw new Error('模块没有可调用的 load* / search* 函数');
  }

  return {
    url,
    meta: {
      id: String(meta.id || url),
      title: String(meta.title || 'REX 模块'),
      description: String(meta.description || ''),
      author: String(meta.author || ''),
      version: String(meta.version || ''),
      site: String(meta.site || ''),
      modules,
      functions: Object.keys(fns),
    },
    fns,
    ctx,
  };
}

/**
 * 取（并缓存）一个模块。
 *
 * [inlineCode] 非空时直接用这段源码 —— 这是「本地 JS 文件」通道：
 * Dart 侧把文件内容随请求一并送来（沙箱里没有 fs，不能自己读盘），
 * `url`（`local://xxx.js`）只作为缓存 key。
 *
 * [masterKey] 只对 `REXENC` 加密模块有用（用户自己填的主密钥）。
 */
async function getModule(url, inlineCode, masterKey) {
  const cached = moduleCache.get(url);
  if (cached) return cached;
  let code;
  const inline = typeof inlineCode === 'string' ? inlineCode : '';
  if (inline.trim()) {
    code = inline;
  } else {
    try {
      code = await fetchText(url);
    } catch (e) {
      throw new Error(`模块下载失败：${friendlyError(e)}`);
    }
  }
  if (!code.trim()) throw new Error('模块内容为空');

  // 加密模块先拆封再编译。拆封失败（没填密钥 / 密钥不对 / 文件被改）
  // 直接抛人话，不能落到下面那句「模块代码无法解析：Unexpected token」。
  if (isRexEnc(code)) code = decodeRexEnc(code, masterKey);

  let ctx;
  try {
    ctx = compileModule(url, code);
  } catch (e) {
    // 语法错误多半是模块本身坏了（例如返回了 Base64/加密内容）
    throw new Error(`模块代码无法解析：${friendlyError(e)}`);
  }
  const mod = extractModule(url, ctx);
  moduleCache.set(url, mod);
  if (moduleCache.size > 40) {
    const first = moduleCache.keys().next().value;
    moduleCache.delete(first);
  }
  return mod;
}

async function callFn(mod, name, args) {
  const fn = mod.fns[name];
  if (typeof fn !== 'function') throw new Error(`模块不支持 ${name}`);
  const run = Promise.resolve().then(() => fn(...args));
  try {
    return await withTimeout(run, CALL_TIMEOUT_MS, name);
  } catch (e) {
    throw new Error(friendlyError(e));
  }
}

/** 把脚本给的封面字段洗成字符串：对象/数组/字面量 "undefined" 一律当没给 */
function cleanUrl(v) {
  if (v == null) return '';
  if (typeof v === 'object') return ''; // 避免 String({}) → "[object Object]"
  const s = String(v).trim();
  if (!s) return '';
  const low = s.toLowerCase();
  if (low === 'undefined' || low === 'null' || low === '[object object]' ||
      low === 'true' || low === 'false') return '';
  return s;
}

// 各家脚本的封面字段名并不统一（ForwardWidget 用 posterPath，影视源习惯
// vod_pic/pic，也有直接给 cover/img 的）—— 全收，别再出现"字段名对不上
// ⇒ 封面整条丢掉"（用户 2026-10-26：REX 加载完播放列表后封面没了）
const COVER_KEYS = [
  'coverUrl', 'posterPath', 'poster', 'pic', 'cover', 'vod_pic', 'vodPic',
  'img', 'imgUrl', 'picUrl', 'image', 'thumb', 'thumbnail',
];

function pickCover(raw) {
  for (const k of COVER_KEYS) {
    const v = cleanUrl(raw[k]);
    if (v) return v;
  }
  return '';
}

function normalizeItem(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const link = String(raw.link ?? raw.id ?? '');
  const cover = pickCover(raw);
  const title = String(raw.title ?? raw.name ?? '');
  if (!title && !link) return null;
  return {
    id: String(raw.id ?? link),
    title,
    link,
    cover,
    // ⚠️ 原来是 `??`：`backdropPath: ''` 不会回退到 cover，头图直接空
    backdrop: cleanUrl(raw.backdropPath) || cleanUrl(raw.backdrop) ||
      cleanUrl(raw.fanart) || cover,
    description: String(raw.description ?? raw.desc ?? ''),
    type: String(raw.type ?? ''),
    mediaType: String(raw.mediaType ?? ''),
    playerType: String(raw.playerType ?? ''),
  };
}

function normalizeItems(raw) {
  let list = raw;
  if (list && !Array.isArray(list)) {
    list = list.list || list.items || list.data || list.videos || [];
  }
  if (!Array.isArray(list)) return [];
  return list.map(normalizeItem).filter(Boolean);
}

function normalizeStreams(raw) {
  let list = raw;
  if (list && !Array.isArray(list)) {
    list = list.list || list.streams || list.urls || list.data || [];
  }
  if (!Array.isArray(list)) list = list ? [list] : [];
  const out = [];
  for (const x of list) {
    if (!x || typeof x !== 'object') continue;
    const url = String(x.url ?? x.playUrl ?? x.src ?? '');
    if (!url) continue;
    out.push({
      name: String(x.name ?? x.title ?? '线路'),
      url,
      headers: normalizeHeaders(x.customHeaders ?? x.headers),
      description: String(x.description ?? ''),
      playerType: String(x.playerType ?? ''),
    });
  }
  return out;
}

export async function handleRexApi(body) {
  const data = body || {};
  const action = String(data.action || '');
  const url = String(data.url || '').trim();
  if (action === 'clearCache') {
    clearRexCache(url);
    return { ok: true };
  }
  if (!url) throw new Error('缺少模块地址');
  const inlineCode = typeof data.code === 'string' ? data.code : '';
  const masterKey =
    typeof data.rexKey === 'string' && data.rexKey.trim()
      ? data.rexKey
      : String(process.env.REX_MASTER_KEY || '');

  if (action === 'load') {
    const mod = await getModule(url, inlineCode, masterKey);
    return { ok: true, meta: mod.meta };
  }

  const mod = await getModule(url, inlineCode, masterKey);

  if (action === 'list') {
    let fn = String(data.functionName || '');
    if (!fn || !mod.fns[fn]) {
      // 模块声明的 functionName 和实际导出名对不上时兜底：
      // 优先 loadList，其次任何「列表类」的 load*（排除 detail/resource/home/search）
      fn = mod.fns.loadList
        ? 'loadList'
        : Object.keys(mod.fns).find(
            (k) =>
              k.startsWith('load') &&
              k !== 'loadDetail' &&
              k !== 'loadResource' &&
              k !== 'loadHome' &&
              k !== 'loadSearch',
          ) || 'loadList';
    }
    const raw = await callFn(mod, fn, [data.params || {}]);
    return { ok: true, items: normalizeItems(raw) };
  }

  if (action === 'detail') {
    const link = String(data.link || '');
    if (!mod.fns.loadDetail) {
      return {
        ok: true,
        item: normalizeItem({ id: link, title: data.title || '', link }),
      };
    }
    const raw = await callFn(mod, 'loadDetail', [link]);
    const item = Array.isArray(raw) ? normalizeItem(raw[0]) : normalizeItem(raw);
    return { ok: true, item };
  }

  if (action === 'resource') {
    if (!mod.fns.loadResource) throw new Error('模块没有 loadResource（不能播放）');
    let params = data.params;
    if (!params || typeof params !== 'object') {
      params = { link: data.link || '', id: data.link || '', url: data.link || '' };
    }
    const raw = await callFn(mod, 'loadResource', [params]);
    return { ok: true, streams: normalizeStreams(raw) };
  }

  if (action === 'search') {
    const keyword = String(data.keyword || '').trim();
    const page = clampInt(data.page, 1, 9999, 1);
    let raw;
    if (mod.fns.search) {
      raw = await callFn(mod, 'search', [{ keyword, page, wd: keyword }]);
    } else if (mod.fns.searchByCode) {
      raw = await callFn(mod, 'searchByCode', [{ keyword, page, wd: keyword }]);
    } else if (mod.fns.loadSearch) {
      raw = await callFn(mod, 'loadSearch', [{ keyword, page, wd: keyword }]);
    } else {
      raw = await callFn(mod, 'loadList', [{ wd: keyword, page: String(page) }]);
    }
    return { ok: true, items: normalizeItems(raw) };
  }

  throw new Error('未知操作：' + action);
}

/** 清掉某个模块的编译缓存（重新导入 / 强制刷新时用） */
export function clearRexCache(url) {
  if (url) moduleCache.delete(url);
  else moduleCache.clear();
  return { ok: true };
}
