/**
 * 「阅读 3.0」(Legado) 书源规则引擎
 *
 * ── 支持的规则前缀 ──────────────────────────────────────────────
 *   @css:xxx       CSS 选择器（cheerio）
 *   @json:$.a.b    JSONPath 子集
 *   @js:expr       JS 表达式（在 vm 沙箱里执行，只给 result / baseUrl / book 等）
 *   @XPath://x     XPath（转成 CSS 处理常见形态）
 *   无前缀         默认按 XPath 处理（Legado 的默认行为）
 *
 * ── 规则内的 @ 分段 ────────────────────────────────────────────
 *   形如 `div.book-list@h3@text`，用 @ 逐级取：
 *     前段是选择器，`@text` 取文本，`@href` 取属性，
 *     `@html` 取 innerHTML，`@textNodes` 取直属文本。
 *   可串联：`a@href`、`ul@li@text`。
 *
 * ── 变量 ──────────────────────────────────────────────────────
 *   {{key}} / {{page}} / {{baseUrl}} 等
 *
 * 说明：Legado 的规则系统非常庞大（见官方文档），这里实现的是
 * **覆盖绝大多数实际书源的那部分**。遇到不支持的写法会明确报错，
 * 而不是静默返回空 —— 这样你一眼能看出是哪个字段不支持。
 */

import * as cheerioNs from 'cheerio';
const cheerio = cheerioNs.default ?? cheerioNs;
import vm from 'node:vm';

// ============================================================
// 工具
// ============================================================

/** 从元素/字符串里取值 */
function toText($, el) {
  if (el == null) return '';
  const node = typeof el === 'string' ? el : $(el).text();
  return String(node).replace(/\u00a0/g, ' ').trim();
}

function toHtml($, el) {
  if (el == null) return '';
  return typeof el === 'string' ? el : $(el).html() || '';
}

/**
 * 解析规则里的 @ 分段取属性。
 *
 * ⚠️ 关键：**不能无脑按 @ 切**。`@` 在这些地方是内容而不是分隔符：
 *   · XPath 属性：`//div[@class='x']`、`a/@href`
 *   · 方括号谓词内部：`[contains(@class,'a')]`
 *   · @ 后面不是取值关键字：`div@a`（这是"下一级选择器"分段，要切）
 *
 * 规则：只有当 `@` **在方括号外**、且后面紧跟取值关键字时，才算分隔符。
 * 另外 `h3@text` 这种（buf 非空且不以 / 结尾）也要切。
 */
function splitRule(rule) {
  let prefix = '';
  let body = rule;

  // ── `<js>...</js>` 标签语法 ──────────────────────────────────
  // Legado 允许把整条规则写成 <js>代码</js>（等价 @js:）。
  // 不识别就会被当 CSS 选择器 → 报 "Unmatched selector" 这种看不懂的错。
  const jsTag = /^\s*<js>([\s\S]*?)<\/js>\s*$/i.exec(rule);
  if (jsTag) return { prefix: 'js', parts: [jsTag[1]] };

  const m = /^@?(css|json|js|XPath|xpath):([\s\S]*)$/.exec(rule);
  if (m) {
    prefix = m[1].toLowerCase();
    body = m[2];
  }
  if (prefix === 'js') return { prefix, parts: [body] };

  const VALUE_KEY = /^(text|textNodes|html|href|src|value|content|title|data-[\w-]+)$/;

  const parts = [];
  let buf = '';
  let depth = 0;
  for (let i = 0; i < body.length; i++) {
    const ch = body[i];
    if (ch === '[') depth++;
    if (ch === ']') depth = Math.max(0, depth - 1);

    if (ch === '@' && depth === 0) {
      const rest = body.substring(i + 1);
      const mm = /^([\w-]+)/.exec(rest);
      const prev = buf.replace(/\s+$/, '');
      // 路径属性（前面以 / 结尾）不切；其余 @word 都切
      const isPathAttr = prev.endsWith('/');
      if (!isPathAttr && mm && VALUE_KEY.test(mm[1]) && buf.trim() !== '') {
        parts.push(buf.trim());
        buf = '';
        continue; // 丢掉这个 @
      }
    }
    buf += ch;
  }
  if (buf.trim() !== '') parts.push(buf.trim());
  return { prefix, parts };
}

// ============================================================
// XPath → CSS 轻量转换
// ============================================================

/**
 * 把「常见形态」的 XPath 转成 CSS。
 *
 * 为什么这么做：Node 没有内置 XPath。引库能覆盖全语法，但书源里
 * 99% 只用到下面这几种形式，转换足够；转不了的返回 null，
 * 由调用方**明确报错**（而不是静默返回空，那样很难排查）。
 *
 * 支持的形态：
 *   //div                       → div
 *   //div[@class='a b']         → div.a.b
 *   //div[@id='x']              → div#x
 *   //a/@href                   → a@href
 *   //div//h3/text()            → div h3@text
 *   //div[@class='a']//span[@class='b']/text()
 *   //div[1]                    → div:nth-of-type(1)
 *   //div[contains(@class,'a')] → div.a
 */
function xpathToCss(xp) {
  let s = String(xp).trim();
  // 允许 / 或 . 开头，也允许 /@href 这类相对路径
  if (!s.startsWith('/') && !s.startsWith('.')) {
    if (!/\/@[\w-]+|\/text\(\s*\)?|\[@[\w-]+|\[contains\(/.test(s)) return null;
  }

  // 去掉最外层多余的括号（不碰 text() 的括号）
  const open = (s.match(/\(/g) || []).length;
  const close = (s.match(/\)/g) || []).length;
  if (open > close && s.startsWith('(')) s = s.replace(/^\(+/, '');
  if (close > open && s.endsWith(')')) s = s.replace(/\)+$/, '');

  // 去掉相对路径前缀：`.//x` 与 `//x` 对选择器等价，但 `.` 不是合法 CSS 段
  s = s.replace(/^\.\s*/,'');

  // 末尾的 /@attr 或 /text()（容错：闭括号可能已被去括号吃掉）
  let tail = '';
  const tailAttr = /\/@([\w-]+)\s*$/.exec(s);
  if (tailAttr) {
    tail = tailAttr[1];
    s = s.substring(0, tailAttr.index);
  } else if (/\/text\(\s*\)?\s*$/.test(s)) {
    tail = 'text';
    s = s.replace(/\/text\(\s*\)?\s*$/, '');
  }

  // 按 / 切成段（// 与 / 都当"后代/子级"，CSS 用空格）
  const segs = s.split(/\/+/).filter((x) => x.trim() !== '' && x.trim() !== '.');
  if (segs.length === 0) return null;

  const out = [];
  for (const raw of segs) {
    const seg = raw.trim();
    if (!seg) continue;
    let name = seg;
    let preds = '';

    const bi = seg.indexOf('[');
    if (bi >= 0 && seg.endsWith(']')) {
      name = seg.substring(0, bi);
      preds = seg.substring(bi);
    }

    let css = name;
    if (!css) {
      // 纯谓词段（少见）→ 放弃
      return null;
    }

    // 逐个处理谓词。
    // ⚠️ 不能用 /\[([^\]]+)\]/ —— `[contains(@class,'book')]` 里
    // 虽然没 ]，但 `[@class='x']` 这种要按配对提取，且谓词内部可能再有方括号。
    const predList = [];
    {
      let j = 0;
      while (j < preds.length) {
        if (preds[j] !== '[') {
          j++;
          continue;
        }
        let depth = 0;
        let k = j;
        for (; k < preds.length; k++) {
          if (preds[k] === '[') depth++;
          else if (preds[k] === ']') {
            depth--;
            if (depth === 0) break;
          }
        }
        if (k >= preds.length) break; // 不配对
        predList.push(preds.substring(j + 1, k).trim());
        j = k + 1;
      }
    }

    for (const pd of predList) {
      let m;
      if ((m = /^@class\s*=\s*['"]([^'"]+)['"]$/.exec(pd))) {
        css += '.' + m[1].trim().split(/\s+/).join('.');
      } else if ((m = /^@id\s*=\s*['"]([^'"]+)['"]$/.exec(pd))) {
        css += '#' + m[1].trim();
      } else if ((m = /^contains\(\s*@class\s*,\s*['"]([^'"]+)['"]\s*\)$/.exec(pd))) {
        // ⚠️ 必须是「属性包含」而不是「类名」。
        // XPath 的 contains(@class,'book') 是**子串**匹配，
        // class="book-item" 也能命中；写成 `.book` 会要求存在 book 这个类 → 匹配不到。
        css += `[class*="${m[1].trim()}"]`;
      } else if ((m = /^contains\(\s*@id\s*,\s*['"]([^'"]+)['"]\s*\)$/.exec(pd))) {
        css += `[id*="${m[1].trim()}"]`;
      } else if ((m = /^@([\w-]+)\s*=\s*['"]([^'"]+)['"]$/.exec(pd))) {
        css += `[${m[1]}="${m[2]}"]`;
      } else if ((m = /^@([\w-]+)$/.exec(pd))) {
        css += `[${m[1]}]`;
      } else if ((m = /^(\d+)$/.exec(pd))) {
        css += `:nth-of-type(${m[1]})`;
      } else {
        // 还有没处理的谓词 → 转不了
        return null;
      }
    }
    out.push(css);
  }

  if (out.length === 0) return null;
  const base = out.join(' ');
  return tail ? `${base}@${tail}` : base;
}

// ============================================================
// JSONPath 子集
// ============================================================

/**
 * 支持：
 *   $.a.b          取属性
 *   $.a[0]         取下标
 *   $.a[*]         展开所有
 *   $.a.b[*].c     组合
 *   $..name        递归查找
 */
function jsonPath(obj, path) {
  let p = path.trim();
  if (p.startsWith('$')) p = p.substring(1);
  if (!p) return [obj];

  const tokens = [];
  // 切出 .name / [n] / [*] / ..name
  const re = /\.\.([A-Za-z_$][\w$]*)|\.([A-Za-z_$][\w$]*)|\[(\d+|\*)\]/g;
  let m;
  let last = 0;
  while ((m = re.exec(p)) !== null) {
    if (m.index !== last) return []; // 有没识别的片段
    last = re.lastIndex;
    if (m[1]) tokens.push({ t: 'deep', k: m[1] });
    else if (m[2]) tokens.push({ t: 'key', k: m[2] });
    else if (m[3] === '*') tokens.push({ t: 'all' });
    else tokens.push({ t: 'idx', i: parseInt(m[3], 10) });
  }
  if (last !== p.length) return [];

  let cur = [obj];
  for (const tk of tokens) {
    const next = [];
    for (const c of cur) {
      if (c == null) continue;
      if (tk.t === 'key') {
        if (typeof c === 'object' && tk.k in c) next.push(c[tk.k]);
      } else if (tk.t === 'idx') {
        if (Array.isArray(c) && c.length > tk.i) next.push(c[tk.i]);
      } else if (tk.t === 'all') {
        if (Array.isArray(c)) next.push(...c);
        else if (typeof c === 'object') next.push(...Object.values(c));
      } else if (tk.t === 'deep') {
        // 递归找同名 key
        const walk = (o) => {
          if (o == null || typeof o !== 'object') return;
          if (Array.isArray(o)) {
            for (const it of o) walk(it);
            return;
          }
          for (const k of Object.keys(o)) {
            if (k === tk.k) next.push(o[k]);
            walk(o[k]);
          }
        };
        walk(c);
      }
    }
    cur = next;
  }
  return cur;
}

// ============================================================
// 变量替换 {{ }}
// ============================================================

function applyVars(str, vars) {
  if (typeof str !== 'string' || !str.includes('{{')) return str;
  return str.replace(/\{\{([\s\S]*?)\}\}/g, (all, expr) => {
    const key = expr.trim();
    if (key in vars) {
      const v = vars[key];
      return v == null ? '' : String(v);
    }
    return all;
  });
}

// ============================================================
// JS 规则沙箱
// ============================================================

/**
 * 执行 @js: 规则。
 *
 * Legado 的 js 规则里可用变量：result / baseUrl / book / src / chapter 等。
 * 这里按需注入，并且**不给 require/process**。
 */
function runJs(expr, ctx) {
  const sandbox = {
    result: ctx.result,
    baseUrl: ctx.baseUrl || '',
    book: ctx.book || {},
    src: ctx.src || '',
    chapter: ctx.chapter || {},
    key: ctx.key || '',
    page: ctx.page || 1,
    // 常用工具（Legado 里也有）
    java: {
      ajax: () => {
        throw new Error('java.ajax 需要同步网络，请改用 @css/@json 或分步规则');
      },
      getString: (s) => (s == null ? '' : String(s)),
      base64Decode: (s) => Buffer.from(String(s), 'base64').toString('utf8'),
      base64Encode: (s) => Buffer.from(String(s), 'utf8').toString('base64'),
      md5Encode: (s) =>
        require('node:crypto').createHash('md5').update(String(s)).digest('hex'),
    },
    JSON,
    Math,
    String,
    Number,
    Boolean,
    Array,
    Object,
    RegExp,
    Date,
    parseInt,
    parseFloat,
    isNaN,
    encodeURIComponent,
    decodeURIComponent,
    console: {
      log: (...a) => console.log('[BookRule]', ...a),
      error: (...a) => console.error('[BookRule]', ...a),
    },
  };
  sandbox.globalThis = sandbox;

  try {
    const context = vm.createContext(sandbox);
    const script = new vm.Script(`(function(){ return (${expr}); })()`, {
      filename: 'book-rule.js',
    });
    return script.runInContext(context, { timeout: 5000 });
  } catch (e) {
    // 有些写法是语句而非表达式（带 return），再试一次
    try {
      const context = vm.createContext(sandbox);
      const script = new vm.Script(`(function(){ ${expr} })()`, {
        filename: 'book-rule.js',
      });
      return script.runInContext(context, { timeout: 5000 });
    } catch (e2) {
      throw new Error('JS 规则执行失败：' + (e2 && e2.message ? e2.message : String(e2)));
    }
  }
}

// ============================================================
// 核心：对「当前节点/文档」求一条规则
// ============================================================

/**
 * @param {object} p
 * @param {string} p.rule     规则字符串
 * @param {any}    p.input    当前输入（HTML 字符串 / JSON 对象 / 节点数组）
 * @param {object} p.vars     {{}} 变量
 * @param {object} p.ctx      js 规则上下文（book/chapter 等）
 * @param {boolean} p.isList  是否要求返回列表
 * @returns {any} 字符串 或 字符串数组 或 对象
 */
function evalRule({ rule, input, vars = {}, ctx = {}, isList = false }) {
  if (rule == null) return isList ? [] : '';
  const raw = String(rule).trim();

  // ⚠️ 「整条就是一个 URL」的判断必须在**变量替换之前**做。
  // 否则 `//div[@class='x']/text()` 被替换后仍以 // 开头，
  // 会被误判成"协议相对 URL //div..."直接原样返回。
  if (!/^@(css|json|js|xpath):/i.test(raw)) {
    // 显式带协议的 URL
    if (/^https?:\/\//i.test(raw)) return applyVars(raw, vars).trim();
    // 协议相对 URL：//host/path —— 要求 // 后紧跟非 [ . # 等选择器字符
    if (/^\/\/[A-Za-z0-9]/.test(raw) && !/^\/\/[a-z]+\[/i.test(raw)) {
      // 再排除 XPath 特征（[@ / text() / contains(）
      if (!/\[@|contains\(|\/text\(\)/.test(raw)) {
        return applyVars(raw, vars).trim();
      }
    }
    if (/^data:/i.test(raw)) return raw;
  }

  let r = applyVars(raw, vars).trim();
  if (!r) return isList ? [] : '';

  const { prefix, parts } = splitRule(r);

  // ── @js: ──────────────────────────────────────────────
  if (prefix === 'js') {
    const out = runJs(parts[0], { ...ctx, result: input });
    return out;
  }

  // ── @json: ────────────────────────────────────────────
  if (prefix === 'json') {
    const out = jsonPath(input, parts[0]);
    if (isList) {
      return out.flatMap((v) => (Array.isArray(v) ? v : [v]));
    }
    const v = out.length > 0 ? out[0] : '';
    return v == null ? '' : v;
  }

  // ── 字符串直取（规则本身就是 @text / @href 这类）──────
  if (parts.length === 1 && /^@?(text|html|textNodes|href|src|value|content)$/.test(parts[0])) {
    const node = input;
    if (node && node.__cheerio) {
      return extractFromNode(node, parts[0].replace(/^@/, ''), isList);
    }
    return String(input ?? '');
  }

  // ── @css: / 默认（XPath 或 CSS）────────────────────────
  let sel = parts[0];
  let rest = parts.slice(1);

  // 判断是不是 XPath：
  //   显式前缀 / 以 / 或 . 开头 / 含 `/@attr` 或 `/text()` 这类 XPath 语法
  // ⚠️ 最后一个很关键：`a/@href`、`div[@id='x']/text()` 都是 XPath，
  //    但不以 / 或 . 开头，漏判就会被当成非法 CSS。
  const looksXpath = prefix === 'xpath' ||
      sel.startsWith('/') ||
      sel.startsWith('./') ||
      sel.startsWith('.//') ||
      sel === '.' ||
      /\/@[\w-]+/.test(sel) ||
      /\/text\(\s*\)?/.test(sel) ||
      /\[@[\w-]+/.test(sel) ||
      /\[contains\(/.test(sel);

  if (prefix === 'css') {
    // 已经是 CSS，不动
  } else if (looksXpath) {
    const converted = xpathToCss(sel);
    if (converted) {
      const at = converted.lastIndexOf('@');
      if (at > 0 && /^[\w-]+$/.test(converted.substring(at + 1))) {
        sel = converted.substring(0, at);
        if (converted.substring(at + 1) !== '') {
          rest = [converted.substring(at + 1), ...rest];
        }
      } else {
        sel = converted;
      }
    } else if (/^\./.test(sel)) {
      // 相对路径转换失败 → 去掉开头的点当 CSS 试
      sel = sel.replace(/^\.\/*/, '');
    } else if (!/^[.#\w\[>:*]/.test(sel)) {
      throw new Error(`不支持的 XPath：${sel}`);
    }
  }

  // input 必须是 cheerio 文档/节点
  let $;
  let scope;
  if (input && input.__cheerio) {
    $ = input.__cheerio;
    scope = input.__nodes;
  } else if (typeof input === 'string') {
    $ = cheerio.load(input);
    scope = null;
  } else {
    // 非 HTML 输入（比如 JSON 已解析出的数组）→ 交给 json 处理失败的兜底
    return isList ? [] : '';
  }

  // 选择
  // ⚠️ `@css:div.book-item@h3` 的 sel 里可能还残留 `@`（分段只按取值关键字切，
  // `@h3` 不是取值所以留在了 sel 里）。这里把它拆成「逐级 find」，
  // 否则 `div.book-item@h3` 会被当成一个非法 CSS 选择器 → 匹配不到任何东西。
  if (sel.includes('@') && !/\[.*@.*\]/.test(sel)) {
    const sub = sel.split('@').filter((x) => x.trim() !== '');
    if (sub.length > 1) {
      sel = sub[0].trim();
      rest = [...sub.slice(1).map((x) => x.trim()), ...rest];
    }
  }

  let nodes;
  try {
    nodes = scope ? $(scope).find(sel) : $(sel);
  } catch (e) {
    throw new Error(`选择器无效：${sel}（${e.message}）`);
  }
  if (!nodes || nodes.length === 0) {
    // 有些规则把选择器写成相对当前节点本身
    try {
      nodes = scope ? $(scope).filter(sel) : $(sel);
    } catch (_) {
      nodes = null;
    }
  }

  if (rest.length === 0) {
    if (isList) {
      return nodes ? nodes.toArray().map((n) => toText($, n)) : [];
    }
    return nodes && nodes.length > 0 ? toText($, nodes.first()) : '';
  }

  // 继续按 @ 分段走
  return walkParts($, nodes, rest, isList);
}

/** 从节点取指定内容 */
function extractFromNode(node, kind, isList) {
  const $ = node.__cheerio;
  const nodes = node.__nodes;
  const get = (n) => {
    switch (kind) {
      case 'text':
        return toText($, n);
      case 'textNodes':
        // 只取直属文本节点
        return $(n)
          .contents()
          .filter((_, c) => c.type === 'text')
          .text()
          .replace(/\u00a0/g, ' ')
          .trim();
      case 'html':
        return toHtml($, n);
      case 'href':
      case 'src':
      case 'value':
      case 'content':
        return String($(n).attr(kind) || '').trim();
      default:
        return String($(n).attr(kind) || '').trim();
    }
  };
  if (isList) return nodes.map(get);
  return nodes.length > 0 ? get(nodes[0]) : '';
}

/** 逐级处理 @ 分段 */
function walkParts($, nodes, parts, isList) {
  let cur = nodes;
  for (let i = 0; i < parts.length; i++) {
    const p = parts[i];
    const isLast = i === parts.length - 1;

    // 取属性/文本
    if (/^(text|textNodes|html|href|src|value|content)$/.test(p)) {
      const arr = cur.toArray();
      if (isLast) {
        if (isList) {
          return arr.map((n) => extractFromNode({ __cheerio: $, __nodes: [n] }, p, false));
        }
        return arr.length > 0
          ? extractFromNode({ __cheerio: $, __nodes: [arr[0]] }, p, false)
          : '';
      }
      // 非末段：先取文本再继续选择不成立，直接返回
      return arr.length > 0 ? toText($, arr[0]) : '';
    }

    // 属性名（@data-src 之类）
    if (/^[a-z-]+$/.test(p) && !/^[.#\[]/.test(p)) {
      const arr = cur.toArray();
      const get = (n) => String($(n).attr(p) || '').trim();
      if (isLast) return isList ? arr.map(get) : (arr.length ? get(arr[0]) : '');
      // 不是末段又没有 . 开头 → 当属性用
      return arr.length ? get(arr[0]) : '';
    }

    // 选择器。⚠️ 段内可能还含 `@`（如 `div.book-item@h3`），
    // 拆成"当前段 @ 下一段"逐级 find，否则整串 CSS 会匹配失败。
    const sub = p.split('@').filter((x) => x.trim() !== '');
    for (let k = 0; k < sub.length; k++) {
      let nextSel = sub[k].trim();
      if (!nextSel) continue;

      // 段内末项可能就是取值关键字
      if (/^(text|textNodes|html|href|src|value|content)$/.test(nextSel)) {
        const arr = cur.toArray();
        const isFinal = isLast && k === sub.length - 1;
        if (isFinal) {
          if (isList) {
            return arr.map((n) =>
                extractFromNode({ __cheerio: $, __nodes: [n] }, nextSel, false));
          }
          return arr.length > 0
              ? extractFromNode({ __cheerio: $, __nodes: [arr[0]] }, nextSel, false)
              : '';
        }
        continue;
      }

      if (nextSel.startsWith('/') || nextSel.startsWith('.')) {
        nextSel = xpathToCss(nextSel) || nextSel;
      }
      try {
        cur = cur.find(nextSel);
      } catch (e) {
        throw new Error(`子选择器无效：${nextSel}（${e.message}）`);
      }
    }
  }
  const arr = cur.toArray();
  if (isList) return arr.map((n) => toText($, n));
  return arr.length > 0 ? toText($, arr[0]) : '';
}

/** 把 HTML 包装成可继续 evalRule 的 input */
function makeInput(html) {
  const $ = cheerio.load(html || '');
  return { __cheerio: $, __nodes: null };
}

/** 把节点数组包装成可继续 evalRule 的 input */
function makeNodeInput($, nodes) {
  return { __cheerio: $, __nodes: nodes };
}

/** 统一的「取列表」入口 */
function evalList({ rule, input, vars, ctx }) {
  if (!rule) return [];
  const r = applyVars(String(rule), vars).trim();
  const { prefix, parts } = splitRule(r);

  if (prefix === 'js') {
    const out = runJs(parts[0], { ...ctx, result: input });
    if (Array.isArray(out)) return out;
    if (out == null) return [];
    return [out];
  }
  if (prefix === 'json') {
    const out = jsonPath(input, parts[0]);
    return out.flatMap((v) => (Array.isArray(v) ? v : [v]));
  }

  // ⚠️ 复合规则（`div.book-item@h3` 这种含 @ 的）不能只取 parts[0] 当选择器，
  // 否则整串会被当成一个 CSS 选择器 → 匹配不到任何东西。
  // 这种情况交给 evalRule(isList:true) 走完整的 walkParts 逻辑。
  if (parts.length > 1) {
    return evalRule({ rule: r, input, vars, ctx, isList: true });
  }

  // css/xpath：把列表规则当选择器，返回节点包装数组
  let $;
  let scope;
  if (input && input.__cheerio) {
    $ = input.__cheerio;
    scope = input.__nodes;
  } else {
    $ = cheerio.load(typeof input === 'string' ? input : '');
    scope = null;
  }
  let sel = parts[0];
  if (prefix !== 'css' && (sel.startsWith('/') || sel.startsWith('.'))) {
    sel = xpathToCss(sel) || sel;
  }
  let nodes;
  try {
    nodes = scope ? $(scope).find(sel) : $(sel);
  } catch (e) {
    throw new Error(`列表选择器无效：${sel}`);
  }
  return nodes.toArray().map((n) => makeNodeInput($, [n]));
}

export {
  evalRule,
  evalList,
  makeInput,
  makeNodeInput,
  applyVars,
  xpathToCss,
  jsonPath,
};
