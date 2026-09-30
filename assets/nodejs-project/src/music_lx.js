/**
 * 落雪(LX)自定义音源脚本沙箱
 *
 * ── 为什么单独一个文件 ────────────────────────────────────────────
 * main.js 已经 400 行且在管视频源的生命周期；音乐音源是**完全独立**的一块，
 * 放一起只会让两件事互相牵连。这里只导出一个 handleMusicRequest。
 *
 * ── LX 自定义源脚本的协议（关键，照着实现才不会"导入成功但搜不出歌"）──
 * 脚本形态：一个 IIFE 或普通脚本，内部调用
 *
 *     lx.on('request', async ({ action, source, info }) => {
 *       switch (action) {
 *         case 'musicUrl': return await handleGetMusicUrl(source, info)
 *         default:         return await handleSearch(action, info)
 *       }
 *     })
 *
 *   action 取值：
 *     'musicUrl'                → 取播放地址
 *     'search' | 'songList'     → 搜索
 *     'albumList' | 'albumSongList' | 'topList' | 'topListDetail' |
 *     'singerList' | 'singerSongList' | ' lyric' 等 → 其它能力（本实现按需透传）
 *
 *   搜索返回：{ isEnd, total, list: [{ songmid, name, singer, albumName,
 *                                    albumId, source:'kw', interval, img, types }] }
 *   取链返回：string  → 直接是播放地址
 *             | { url }        → 播放地址
 *             | { source }     → 交给 lx.request 兜底
 *             | { type:'local', filePath } → 本地文件
 *
 * ── 安全边界 ────────────────────────────────────────────────────
 * 用 node:vm 跑在独立 context 里，只注入白名单内的全局（console / Buffer /
 * setTimeout 等）。**不注入 require**，所以脚本无法读文件或起进程。
 * 网络只能用我们提供的 lx.request，便于统一超时与错误处理。
 */

const vm = require('node:vm');
const axios = require('axios');

// ── 版本号：部分脚本会据此分支（太老会被判定不支持）────────────
const LX_VERSION = '2.11.0';

// 单次脚本执行的兜底超时（毫秒）。脚本内部自己的请求超时通常更短。
const EXEC_TIMEOUT_MS = 25000;

// 单次 HTTP 请求超时
const HTTP_TIMEOUT_MS = 15000;

/**
 * 构造 lx.utils（脚本最常用的工具集）
 */
function buildUtils() {
  function buffer(...args) {
    if (args.length >= 2 && typeof args[0] === 'string') {
      return Buffer.from(args[0], args[1]);
    }
    return Buffer.from(args[0] ?? '', args[1] ?? 'utf8');
  }

  function str2b64(str) {
    return Buffer.from(String(str), 'utf8').toString('base64');
  }

  function b642str(b64) {
    return Buffer.from(String(b64), 'base64').toString('utf8');
  }

  function md5(str) {
    return require('node:crypto')
      .createHash('md5')
      .update(String(str))
      .digest('hex');
  }

  function sha1(str) {
    return require('node:crypto')
      .createHash('sha1')
      .update(String(str))
      .digest('hex');
  }

  function randomBytes(size) {
    return require('node:crypto').randomBytes(size || 16);
  }

  /** 从 URL / 响应头里取文件名，做后缀判断用 */
  function getFileName(url, headers) {
    if (headers) {
      const cd = headers['content-disposition'] || headers['Content-Disposition'];
      if (cd) {
        const m = /filename\*?=(?:UTF-8'')?"?([^";]+)"?/i.exec(cd);
        if (m && m[1]) return decodeURIComponent(m[1]);
      }
      const ct = headers['content-type'] || headers['Content-Type'] || '';
      if (ct.includes('audio/mpeg')) return 'audio.mp3';
      if (ct.includes('audio/flac')) return 'audio.flac';
      if (ct.includes('audio/mp4') || ct.includes('audio/aac')) return 'audio.m4a';
    }
    try {
      const u = new URL(url);
      const last = u.pathname.split('/').filter(Boolean).pop() || '';
      return last || 'audio.mp3';
    } catch (_) {
      return 'audio.mp3';
    }
  }

  /** 把 { headers, body } 拼成 axios 可用的 config */
  function buildHttpConfig({ url, method = 'get', headers, body, form, params, timeout }) {
    const cfg = {
      url,
      method: String(method).toLowerCase(),
      headers: Object.assign({}, headers || {}),
      timeout: timeout || HTTP_TIMEOUT_MS,
      // 不要跟着 3xx 跑丢 header（部分音源需要 Referer 跳转）
      maxRedirects: 5,
      validateStatus: () => true,
    };
    if (params) cfg.params = params;
    if (form) cfg.data = form;
    else if (body != null) cfg.data = body;
    return cfg;
  }

  /** 极简 mime → 后缀映射（脚本里常用来判断"是不是音频"） */
  const mimeMap = {
    'audio/mpeg': '.mp3',
    'audio/mp3': '.mp3',
    'audio/flac': '.flac',
    'audio/x-flac': '.flac',
    'audio/mp4': '.m4a',
    'audio/aac': '.m4a',
    'audio/wav': '.wav',
    'audio/ogg': '.ogg',
  };

  return {
    buffer,
    str2b64,
    b642str,
    md5,
    sha1,
    randomBytes,
    getFileName,
    buildHttpConfig,
    mimeMap,
    // 一些脚本会调到的杂项
    sizeFormate: (size) => {
      const n = Number(size) || 0;
      if (n < 1024) return n + 'B';
      if (n < 1024 * 1024) return (n / 1024).toFixed(1) + 'KB';
      return (n / 1024 / 1024).toFixed(1) + 'MB';
    },
    formatPlayTime: (sec) => {
      const s = Math.max(0, Math.floor(Number(sec) || 0));
      return String(Math.floor(s / 60)).padStart(2, '0') + ':' +
        String(s % 60).padStart(2, '0');
    },
  };
}

/**
 * 执行一次 LX 脚本调用
 *
 * @param {object} p
 * @param {string} p.script   LX 音源脚本源码（.js 内容）
 * @param {string} p.action   'search' | 'musicUrl' | ...
 * @param {object} p.payload  传给 handler 的参数
 *   - search   : { filter, type, quality? }
 *   - musicUrl : { musicInfo, quality }
 * @returns {Promise<{ok:boolean, data?:any, error?:string}>}
 */
async function handleMusicRequest({ script, action, payload }) {
  if (!script || typeof script !== 'string' || !script.trim()) {
    return { ok: false, error: '音源脚本为空' };
  }
  if (!action) {
    return { ok: false, error: '缺少 action' };
  }

  // ── 收集脚本注册的 handler / 声明的音源 ────────────────────
  let requestHandler = null;
  const otherHandlers = Object.create(null);

  /** 脚本 send(EVENT_NAMES.inited, {sources}) 声明的可用音源 */
  let declaredSources = null;
  /** 脚本上报的提示（版本过低 / 需要更新等） */
  const alerts = [];

  const utils = buildUtils();

  /**
   * ⚠️ EVENT_NAMES 必须与官方 LX 一致。
   *
   * 音源脚本开头就是这么写的：
   *   const { EVENT_NAMES, request, on, send, env } = globalThis.lx;
   *   on(EVENT_NAMES.request, async ({action, source, info}) => {...});
   *   send(EVENT_NAMES.inited, { status: true, sources });
   *
   * 所以 lx 上必须有：**解构出来的这五样** + 名字对得上的 EVENT_NAMES。
   * 少一个就会在脚本第一行抛错（表现为"导入成功但搜不出歌"）。
   */
  const EVENT_NAMES = {
    request: 'request',
    inited: 'inited',
    updateAlert: 'updateAlert',
  };

  /** 网络请求：同时支持 (url, opts) 与 (url, opts, callback) 两种用法 */
  const doRequest = async (url, options = {}, callback) => {
    const cfg = utils.buildHttpConfig({ url, ...options });
    // 脚本常写 timeout: '20s'，axios 不认字符串 → 归一化成毫秒
    const t = options.timeout;
    if (typeof t === 'string') {
      const n = parseInt(t, 10);
      cfg.timeout = Number.isFinite(n)
        ? n * (t.includes('s') ? 1000 : 1)
        : HTTP_TIMEOUT_MS;
    } else if (typeof t === 'number' && t > 0) {
      cfg.timeout = t;
    }
    try {
      const res = await axios(cfg);
      const out = {
        statusCode: res.status,
        status: res.status,
        headers: res.headers || {},
        body: res.data,
        raw: res.data,
      };
      if (typeof callback === 'function') callback(null, out);
      return out;
    } catch (e) {
      // ⚠️ 必须 try/catch：官方宿主在失败时是**回调传 err**，而不是让 Promise
      // 抛出去。直接抛会变成 unhandled rejection，把整个 Node 进程带崩。
      const out = {
        statusCode: e && e.response ? e.response.status : 0,
        status: e && e.response ? e.response.status : 0,
        headers: (e && e.response && e.response.headers) || {},
        body: (e && e.response && e.response.data) || '',
        raw: '',
        error: (e && e.message) || String(e),
      };
      if (typeof callback === 'function') callback(e, out);
      return out;
    }
  };

  const lx = {
    version: LX_VERSION,
    env: { platform: 'mobile', version: LX_VERSION },
    EVENT_NAMES,
    /** 注册事件（request 是主 handler，其余留档） */
    on: (event, handler) => {
      if (event === EVENT_NAMES.request || event === 'request') {
        requestHandler = handler;
      } else {
        otherHandlers[event] = handler;
      }
    },
    /** 脚本上报状态：inited 带 sources，updateAlert 带提示 */
    send: (event, data) => {
      if (event === EVENT_NAMES.inited || event === 'inited') {
        declaredSources = data;
      } else if (event === EVENT_NAMES.updateAlert || event === 'updateAlert') {
        alerts.push(data);
      }
    },
    /** 兼容直接调 lx.request 的脚本 */
    request: doRequest,
    requestHandler: () => {},
    utils,
  };

  // ── 白名单全局：不注入 require / process ────────────────────
  const sandbox = {
    lx,
    console: {
      log: (...a) => console.log('[LX]', ...a),
      warn: (...a) => console.warn('[LX]', ...a),
      error: (...a) => console.error('[LX]', ...a),
      info: (...a) => console.log('[LX]', ...a),
      debug: () => {},
    },
    Buffer,
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
    URL,
    URLSearchParams,
    TextEncoder,
    TextDecoder,
    // 有些脚本用 globalThis 挂变量
    module: { exports: {} },
    exports: {},
  };
  sandbox.globalThis = sandbox;
  sandbox.window = undefined; // 明确不给 window，避免误判为浏览器环境

  const context = vm.createContext(sandbox);

  // ── 1) 执行脚本（注册 handler）──────────────────────────────
  try {
    const compiled = new vm.Script(script, {
      filename: 'lx-source.js',
      // 允许顶层 await 之外的常规脚本
    });
    compiled.runInContext(context, { timeout: EXEC_TIMEOUT_MS });
  } catch (e) {
    return { ok: false, error: '脚本执行失败：' + (e && e.message ? e.message : String(e)) };
  }

  if (!requestHandler) {
    return {
      ok: false,
      error: '脚本没有注册 lx.on("request")，不是合法的落雪音源',
    };
  }

  // ── 2) 调用 handler ────────────────────────────────────────
  try {
    // ⚠️ `source` 在 LX 协议里是**音乐平台代号**（wy 网易 / tx QQ / kw 酷我 /
    // kg 酷狗 / mg 咪咕），**不是**'lx'。脚本第一行就校验：
    //   if (!source || !MUSIC_QUALITIES[source]) throw '不支持的音乐源'
    // 所以必须让 Dart 侧把平台传进来；没传时默认网易云（覆盖面最广）。
    const arg = {
      action,
      source: payload.source || 'wy',
      info: payload.info ?? payload.musicInfo ?? payload.filter ?? null,
      ...payload,
    };
    const result = await Promise.race([
      Promise.resolve(requestHandler(arg)),
      new Promise((_, reject) =>
        setTimeout(() => reject(new Error('脚本执行超时')), EXEC_TIMEOUT_MS)),
    ]);
    return {
      ok: true,
      data: normalize(result),
      // 顺带回传脚本声明的音源与提示，Dart 侧可展示"这个源支持哪些平台"
      sources: declaredSources ? normalize(declaredSources) : null,
      alerts: alerts.length > 0 ? normalize(alerts) : null,
    };
  } catch (e) {
    return { ok: false, error: '调用失败：' + (e && e.message ? e.message : String(e)) };
  }
}

/**
 * 结果规整：脚本可能返回 Buffer / 循环引用对象，
 * 直接 JSON.stringify 会抛，这里统一转成可序列化的普通值。
 */
function normalize(value) {
  if (value == null) return null;
  if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
    return value;
  }
  if (Buffer.isBuffer(value)) {
    return { __buffer: value.toString('base64') };
  }
  if (Array.isArray(value)) {
    return value.map(normalize);
  }
  if (typeof value === 'object') {
    const out = {};
    for (const k of Object.keys(value)) {
      // 跳过函数（脚本常把方法挂在返回对象上）
      if (typeof value[k] === 'function') continue;
      out[k] = normalize(value[k]);
    }
    return out;
  }
  return String(value);
}

module.exports = { handleMusicRequest, LX_VERSION };
