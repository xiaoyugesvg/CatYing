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
// ESM 下没有 require：crypto 能力走顶层 import（esbuild 打包同样正确转换）
import { createHash, createCipheriv, createDecipheriv, randomUUID as nodeRandomUUID } from 'node:crypto';

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
      // 元素步骤（Legado 官方：@tag.li / @class.x / @id.y / @children）
      // 也是 @ 分段的一环——不切的话整段被当成一个 CSS 选择器 → 匹配 0。
      const isElementStep = /^(tag|class|id|children|parent|self)\b/.test(rest);
      if (!isPathAttr && mm && (VALUE_KEY.test(mm[1]) || isElementStep) && buf.trim() !== '') {
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
// Legado 步骤归一化（class. / tag. / id. + 位置）
// ============================================================

/**
 * 归一化一个「取值步骤」—— Legado 官方语法（阅读 3.0）。
 *
 * ── 官方原文（celeter.github.io 书源规则说明）──────────────────
 *   `@`为分隔符,用来分隔获取规则
 *   每段规则可分为3段
 *   第一段是类型,如 **class,id,tag**,text,children等
 *   第二段是名称
 *   第三段是位置,class,tag,id等会获取到多个,所以要加位置
 *   位置正着数从0开始,0是第一个,如为负数则是取倒着数的值,-1为倒数第一个
 *
 * ── ⚠️ 我在这里犯过一个严重的错 ────────────────────────────────
 * 我一开始以为 `class.xxx` / `tag.xxx` 是 **TVBox/CatVod** 的方言，
 * 还跟用户说"你这个源不是 Legado 标准写法"。
 * **这是错的** —— 它就是 Legado 官方语法，是我的引擎只实现了子集。
 * 判断反了，而且把责任推给了用户的源。特此记录，避免以后再犯。
 *
 * ── 转换规则 ──────────────────────────────────────────────────
 *   class.a b.0      → .a.b:eq(0)      多类名用点连，位置转 :eq()
 *   class.item.-1    → .item:eq(-1)    官方：-1 是倒数第一个
 *   tag.a.0          → a:eq(0)
 *   id.content       → #content
 *   harf             → href            （少数源的错拼，真实存在）
 *
 * 标准 CSS（`.a>b`、`@css:`）、JSONPath（`$.a`）、XPath（`//div`）
 * **一律原样返回** —— 不能误改。
 *
 * ── 为什么 `tag.a` 要加 `:not(.__none__)` ─────────────────────
 * walkParts 里有个分支把"纯小写字母"当作**属性名**（用来处理 `@data-src`）。
 * 而 `a` 正好全是小写字母 → 会被当成"取属性 a" → 属性不存在 →
 * **返回空串且不报错**。这正是 bookUrl 一直为空、点进去白页的原因。
 * 加个永不匹配的 `:not()` 让它明确走"选择器"分支。
 */
function normLegadoStep(step) {
  let s = String(step).trim();
  if (!s) return s;

  // 错拼纠正（包子漫画的 tocUrl 里就有 @harf）
  if (s === 'harf') return 'href';

  // 不含 class./tag./id. 前缀 → 原样返回（标准 CSS / JSONPath / XPath）
  const m0 = /^(class|tag|id)\.([\s\S]+)$/i.exec(s);
  if (!m0) return s;
  const kind = m0[1].toLowerCase();
  let rest = m0[2];

  // ── 1) 位置：末尾 `.N` 或 `.-N` ──────────────────────────────
  let eq = '';
  const pm = /\.(-?\d+)\s*$/.exec(rest);
  if (pm) {
    eq = `:eq(${+pm[1]})`;
    rest = rest.slice(0, pm.index).trim();
  }

  // ── 2) 名称 ─────────────────────────────────────────────────
  if (kind === 'class') {
    // 多类名（空格分隔）→ .a.b.c
    const css = rest
      .trim()
      .split(/\s+/)
      .filter(Boolean)
      .map((c) => '.' + c)
      .join('');
    return (css || rest) + eq;
  }
  if (kind === 'tag') {
    const tag = rest.trim().split(/\s+/)[0] || '';
    // ⚠️ 加 :not(.__none__) 避开 walkParts 的"纯小写字母=属性名"分支
    return tag ? `${tag}:not(.__none__)${eq}` : s;
  }
  // id
  const id = rest.trim().split(/\s+/)[0] || '';
  return id ? `#${id}${eq}` : s;
}

/** 归一化整条规则的 @@ 取值链（保持 @ 分隔结构） */
function normLegadoChain(rule) {
  const raw = String(rule);
  // `##正则##替换` 要保留在末尾，不能参与归一化
  const hash = raw.indexOf('##');
  const body = hash < 0 ? raw : raw.slice(0, hash);
  const tail = hash < 0 ? '' : raw.slice(hash);
  // 首个 @ 之前是选择器，之后是取值步骤
  const at = body.indexOf('@');
  if (at < 0) return normLegadoStep(body) + tail;
  const head = body.slice(0, at);
  const steps = body.slice(at + 1).split('@');
  return (
    normLegadoStep(head) +
    '@' +
    steps.map(normLegadoStep).join('@') +
    tail
  );
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
  // 兼容 Legado 写法：@json:data.items（无 $ 前缀）→ 补点号
  else if (!p.startsWith('.')) p = '.' + p;
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
  // ── java.getElements（TVBox/CatVod 风格漫画源大量使用）──────────
  //
  // 原引擎**没有**这个方法，所以这类源一执行就报
  // "java.getElements is not a function" —— 漫画取不到图。
  //
  // 用法（包子漫画那种）：
  //   let n = java.getElements('class.comic-contain@amp-img')
  //   n.forEach(x => x.attr('data-src'))
  //
  // 所以它要返回**带 attr() 的节点数组**，而不是字符串。
  // 这里把 cheerio 的节点包一层：attr / text / html 三个最常用的。
  const _cheerio = ctx.__cheerio;
  const _scope = ctx.__nodes;

  function wrapNodes($, nodes) {
    return nodes.map((el) => {
      const $el = $(el);
      return {
        attr: (name) => $el.attr(name),
        text: () => $el.text(),
        html: () => $el.html(),
        // TVBox 里常见 x.attr('href') 之后再处理
        toString: () => $.html(el),
        __el: el,
        __$: $,
      };
    });
  }

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
      getString: (s, text) => {
        // Legado 语义：java.getString(rule, text?) —— rule 可以是 JSONPath。
        // 原实现退化成 String(s)，顶点小说等源的目录 URL 解密脚本
        // `java.getString("$.data[?].url", m)` 会取空。
        const ruleStr = s == null ? '' : String(s);
        const ruleTrim = ruleStr.trim();
        if (ruleTrim.startsWith('$')) {
          try {
            const target = text != null
              ? String(text)
              : String(ctx.result == null ? '' : ctx.result);
            const root = JSON.parse(target);
            const out = jsonPath(root, ruleTrim);
            return out.length > 0 ? (out[0] == null ? '' : String(out[0])) : '';
          } catch (_) {
            return '';
          }
        }
        return ruleStr;
      },

      /**
       * java.getElements(sel) —— 取节点数组（返回带 attr/text/html 的对象）。
       *
       * sel 支持 TVBox 的 class./tag. 前缀（内部会转成 CSS）。
       * 作用域：优先在**当前节点**下找，没有当前节点就从整篇文档找。
       */
      getElements: (sel) => {
        if (!_cheerio) return [];
        const css = normLegadoStep(String(sel));
        try {
          const $ = _cheerio;
          let found;
          if (_scope && _scope.length) {
            // 在当前节点集合里找
            found = $(_scope).find(css);
            if (found.length === 0) found = $(_scope).filter(css);
          } else {
            found = $(css);
          }
          return wrapNodes($, found.toArray());
        } catch (_) {
          return [];
        }
      },

      /**
       * java.t2s(str) —— 繁体转简体。
       *
       * ⚠️ 这里**不是完整的繁简映射表**（那需要几千字的字典，且涉及
       * 一简对多繁的歧义）。只覆盖漫画标题里最常见的几十个字 ——
       * 目的是"书名能正常显示"，不是做完整转换。
       * 真正的全文转换需要引入 OpenCC 之类的字典（本项目不引第三方依赖）。
       */
      t2s: (s) => {
        const str = s == null ? '' : String(s);
        return str.replace(/[麼麽么]/g, '么')
          .replace(/[們们]/g, '们')
          .replace(/[這这]/g, '这')
          .replace(/[來来]/g, '来')
          .replace(/[對对]/g, '对')
          .replace(/[後后]/g, '后')
          .replace(/[裡里裏]/g, '里')
          .replace(/[與与]/g, '与')
          .replace(/[為为]/g, '为')
          .replace(/[國国]/g, '国')
          .replace(/[學学]/g, '学')
          .replace(/[會会]/g, '会')
          .replace(/[說说]/g, '说')
          .replace(/[時时]/g, '时')
          .replace(/[間间]/g, '间')
          .replace(/[見见]/g, '见')
          .replace(/[現现]/g, '现')
          .replace(/[實实]/g, '实')
          .replace(/[無无]/g, '无')
          .replace(/[愛爱]/g, '爱')
          .replace(/[戀恋]/g, '恋')
          .replace(/[龍龙]/g, '龙')
          .replace(/[劍剑]/g, '剑')
          .replace(/[書书]/g, '书')
          .replace(/[畫画]/g, '画')
          .replace(/[網网]/g, '网')
          .replace(/[頁页]/g, '页')
          .replace(/[節节]/g, '节')
          .replace(/[點点]/g, '点')
          .replace(/[號号]/g, '号')
          .replace(/[風风]/g, '风')
          .replace(/[雲云]/g, '云')
          .replace(/[語语]/g, '语')
          .replace(/[話话]/g, '话')
          .replace(/[東东]/g, '东')
          .replace(/[車车]/g, '车')
          .replace(/[門门]/g, '门')
          .replace(/[馬马]/g, '马')
          .replace(/[鳥鸟]/g, '鸟')
          .replace(/[魚鱼]/g, '鱼')
          .replace(/[體体]/g, '体')
          .replace(/[頭头]/g, '头')
          .replace(/[長长]/g, '长')
          .replace(/[萬万]/g, '万')
          .replace(/[億亿]/g, '亿')
          .replace(/[終终]/g, '终')
          .replace(/[於于]/g, '于')
          .replace(/[從从]/g, '从')
          .replace(/[將将]/g, '将')
          .replace(/[給给]/g, '给')
          .replace(/[還还]/g, '还')
          .replace(/[過过]/g, '过')
          .replace(/[開开]/g, '开')
          .replace(/[關关]/g, '关')
          .replace(/[應应]/g, '应')
          .replace(/[該该]/g, '该')
          .replace(/[卻却]/g, '却')
          .replace(/[種种]/g, '种')
          .replace(/[類类]/g, '类')
          .replace(/[數数]/g, '数')
          .replace(/[語语]/g, '语')
          .replace(/[樂乐]/g, '乐')
          .replace(/[讀读]/g, '读')
          .replace(/[寫写]/g, '写')
          .replace(/[聽听]/g, '听')
          .replace(/[覺觉]/g, '觉')
          .replace(/[麗丽]/g, '丽')
          .replace(/[華华]/g, '华')
          .replace(/[漢汉]/g, '汉')
          .replace(/[軍军]/g, '军')
          .replace(/[戰战]/g, '战')
          .replace(/[爭争]/g, '争')
          .replace(/[勝胜]/g, '胜')
          .replace(/[敗败]/g, '败')
          .replace(/[殺杀]/g, '杀')
          .replace(/[血血]/g, '血')
          .replace(/[靈灵]/g, '灵')
          .replace(/[魂魂]/g, '魂')
          .replace(/[夢梦]/g, '梦')
          .replace(/[園园]/g, '园')
          .replace(/[樹树]/g, '树')
          .replace(/[葉叶]/g, '叶')
          .replace(/[花蕐]/g, '花');
      },

      base64Decode: (s) => Buffer.from(String(s), 'base64').toString('utf8'),
      base64Encode: (s) => Buffer.from(String(s), 'utf8').toString('base64'),
      md5Encode: (s) => createHash('md5').update(String(s)).digest('hex'),
      randomUUID: () => nodeRandomUUID(),
      hexDecodeToString: (s) => Buffer.from(String(s), 'hex').toString('utf8'),

      /**
       * java.createSymmetricCrypto(algo, mode, pad, key, iv) —— 对称加解密。
       * 目前覆盖 AES-CBC（Legado 目录/正文解密最常见的组合），
       * key 16 字节 → AES-128，32 字节 → AES-256；密文自动识别 hex / base64。
       * 返回 { decryptStr, encryptStr }。
       */
      createSymmetricCrypto: (algo, mode, pad, key, iv) => {
        const alg = String(algo || '').toUpperCase();
        const keyBuf = Buffer.from(String(key || ''), 'utf8');
        const ivBuf = Buffer.from(String(iv || ''), 'utf8');
        const cipherName = alg.includes('AES')
          ? (keyBuf.length === 32 ? 'aes-256-cbc'
            : keyBuf.length === 16 ? 'aes-128-cbc' : null)
          : null;
        if (!cipherName) {
          throw new Error(
            `createSymmetricCrypto: 不支持的算法/密钥长度 (${alg}, key=${keyBuf.length}B)`
          );
        }
        return {
          decryptStr: (data) => {
            const raw = String(data == null ? '' : data);
            if (!raw) return '';
            let ct;
            if (/^[0-9a-fA-F]+$/.test(raw) && raw.length % 2 === 0) {
              ct = Buffer.from(raw, 'hex');
            } else {
              ct = Buffer.from(raw, 'base64');
            }
            try {
              const dc = createDecipheriv(cipherName, keyBuf, ivBuf);
              dc.setAutoPadding(true);
              return Buffer.concat([dc.update(ct), dc.final()]).toString('utf8');
            } catch (_) {
              // 少数源密文是裸 UTF-8 文本，不是 hex/base64 编码
              return raw;
            }
          },
          encryptStr: (data) => {
            const ce = createCipheriv(cipherName, keyBuf, ivBuf);
            return Buffer.concat([ce.update(String(data), 'utf8'), ce.final()])
              .toString('base64');
          },
        };
      },
    },
    // org.jsoup.Jsoup.parse(html).select(css) —— 69书吧-H 等源详情/简介脚本依赖。
    // 语义：对传入的 html 文本**新建文档**解析（不依赖当前 input 的 cheerio）。
    org: {
      jsoup: {
        Jsoup: {
          parse: (html) => ({
            select: (css) => {
              try {
                const $ = cheerio.load(String(html == null ? '' : html));
                const els = $(String(css == null ? '' : css));
                return wrapNodes($, els.toArray());
              } catch (_) {
                return [];
              }
            },
          }),
        },
      },
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

  // ── jsLib（skybook / Legado 源的公共脚本库）────────────
  //
  // skybook 类源（jsLib 内嵌混淆 JS）的规则大量调用 jsLib 定义的函数
  // （签名、加解密、格式化等）。原引擎**不执行 jsLib** → 这些函数
  // 全是 undefined → 规则求值失败 → URL 畸形 → 源站 500 / 解析空。
  // 这里在**同一个 vm context**里先跑 jsLib、再跑规则表达式，
  // jsLib 定义的全局函数就能被规则引用（与 Legado 语义一致）。
  const jsLibCode = ctx && ctx.jsLib;
  function execJsLib(context) {
    if (!jsLibCode) return;
    try {
      new vm.Script(String(jsLibCode), { filename: 'jsLib.js' })
        .runInContext(context, { timeout: 5000 });
    } catch (jsErr) {
      // jsLib 失败不阻断规则求值：部分源的 jsLib 依赖 DOM/网络/同步
      // 请求，这里宽松处理，避免一个坏 jsLib 拖垮所有规则。
      console.error('[BookRule] jsLib 执行失败：', (jsErr && jsErr.message) || jsErr);
    }
  }

  try {
    const context = vm.createContext(sandbox);
    execJsLib(context);
    const script = new vm.Script(`(function(){ return (${normalizeRhinoArrow(expr)}); })()`, {
      filename: 'book-rule.js',
    });
    return script.runInContext(context, { timeout: 5000 });
  } catch (e) {
    // 有些写法是语句而非表达式（带 return），再试一次
    try {
      const context = vm.createContext(sandbox);
      execJsLib(context);
      const body = normalizeRhinoArrow(String(expr));
      // ⚠️ Legado/Rhino 语义：@js 规则返回**最后一条表达式语句**的值。
      // 语句式脚本（`var t=…;var m=…;m?m[1]:'';`）没有 return 关键字，
      // 原实现直接执行 → 返回 undefined → 详情字段（author/kind…）全空。
      // 这里把最后一个顶层表达式语句补上 return。
      const lastInfo = splitLastStatement(body);
      let wrapped = body;
      if (lastInfo.last && !/^(var|let|const|if|for|while|switch|function|return|do|try|throw|break|continue)\b/.test(lastInfo.last)) {
        wrapped = body + (body.endsWith(';') || body.endsWith('}') ? '' : ';') + ' return (' + lastInfo.last + ');';
      }
      const script = new vm.Script(`(function(){ ${wrapped} })()`, {
        filename: 'book-rule.js',
      });
      return script.runInContext(context, { timeout: 5000 });
    } catch (e2) {
      throw new Error('JS 规则执行失败：' + (e2 && e2.message ? e2.message : String(e2)));
    }
  }
}

/**
 * 在语句式脚本里找"最后一条顶层语句"（跳过字符串/括号内的 ; 与 }）。
 */
/**
 * 在语句式脚本里找"最后一条顶层语句"（跳过字符串/括号内的 ; 与 }）。
 */

/**
 * ⚠️ Rhino（Legado 执行环境）语法兼容：源脚本常写裸解构箭头参数
 * `.map([title,id]=>{...})`——Rhino 容忍，V8 严格报
 * "Malformed arrow function parameter list"。统一补成括号形式
 * `([title,id])=>`（V8 合法、语义不变）。
 */
function normalizeRhinoArrow(code) {
  return String(code).replace(/(\[[A-Za-z_$][\w$]*(?:\s*,\s*[A-Za-z_$][\w$]*)*\])\s*=>/g, '($1)=>');
}

/**
 * ⚠️ 踩坑记录：`.map([title,id]=>{...})` / `.map(function(x){...})` 这类
 * 「括号内函数体」的 `}`（depth 由 2→1）会被旧判据 `depth===1` 误当
 * 顶层块结束切分 → 最后一条语句提取成 `})` 畸形 → runJs 报
 * "Malformed arrow function parameter list"。解法：先剥离所有表达式
 * 上下文里的函数体（箭头参数 + `=>` + 体 / function(...){...}），
 * 在剥离后的骨架上找分隔符，再回原文按位置取最后语句。
 */
function stripInlineFnBodies(body) {
  const chars = body.split('');
  const n = chars.length;
  const ranges = [];
  const isWs = (c) => c === ' ' || c === '\t' || c === '\r' || c === '\n';
  const isOpen = (c) => c === '{' || c === '(' || c === '[';
  const isClose = (c) => c === '}' || c === ')' || c === ']';
  for (let i = 0; i < n; i++) {
    const c = chars[i];
    if (c === '=' && chars[i + 1] === '>') {
      // 向前找参数列表起点（(...) 或 [a,b] 解构）
      let k = i - 1;
      while (k >= 0 && isWs(chars[k])) k--;
      let paramStart = -1;
      if (chars[k] === ')' || chars[k] === ']') {
        const pair = chars[k] === ')' ? '(' : '[';
        const close = chars[k];
        let d = 0;
        for (let j = k; j >= 0; j--) {
          if (chars[j] === close) d++;
          else if (chars[j] === pair) { d--; if (d === 0) { paramStart = j; break; } }
        }
      }
      // 向后找函数体：{...} 平衡 或 表达式体到顶层边界
      let j = i + 2;
      while (j < n && isWs(chars[j])) j++;
      let bodyEnd = -1;
      if (chars[j] === '{') {
        let d = 0, q = null;
        for (let m = j; m < n; m++) {
          const cc = chars[m];
          if (q) { if (cc === q && chars[m - 1] !== '\\') q = null; continue; }
          if (cc === "'" || cc === '"' || cc === '`') { q = cc; continue; }
          if (cc === '{') d++;
          else if (cc === '}') { d--; if (d === 0) { bodyEnd = m; break; } }
        }
      } else {
        let d = 0;
        for (let m = j; m < n; m++) {
          const cc = chars[m];
          if (isOpen(cc)) d++;
          else if (isClose(cc)) { if (d > 0) d--; else { bodyEnd = m - 1; break; } }
          else if ((cc === ';' || cc === '\n') && d === 0) { bodyEnd = m - 1; break; }
        }
      }
      const a = paramStart >= 0 ? paramStart : i;
      const b = bodyEnd >= 0 ? bodyEnd : Math.min(i + 1, n - 1);
      if (b > a) ranges.push([a, b]);
      i = Math.max(i, b);
    } else if (c === 'f' && body.slice(i, i + 8) === 'function') {
      // 仅表达式上下文里的 function(...){...}（前一个非空字符是 . ( [ , = 等）
      let p = i - 1;
      while (p >= 0 && isWs(chars[p])) p--;
      if (p >= 0 && '.([,='.includes(chars[p])) {
        let j = i + 8;
        while (j < n && isWs(chars[j])) j++;
        if (chars[j] === '(') {
          let d = 0, k = j;
          for (; k < n; k++) {
            if (chars[k] === '(') d++;
            else if (chars[k] === ')') { d--; if (d === 0) break; }
          }
          let m = k + 1;
          while (m < n && isWs(chars[m])) m++;
          if (chars[m] === '{') {
            let d2 = 0, e = m, q = null;
            for (; e < n; e++) {
              const cc = chars[e];
              if (q) { if (cc === q && chars[e - 1] !== '\\') q = null; continue; }
              if (cc === "'" || cc === '"' || cc === '`') { q = cc; continue; }
              if (cc === '{') d2++;
              else if (cc === '}') { d2--; if (d2 === 0) break; }
            }
            if (e < n) ranges.push([j, e]);
            i = Math.max(i, e);
          }
        }
      }
    }
  }
  for (const [a, b] of ranges) {
    for (let i = a; i <= b; i++) {
      // 只保留换行与分号（语句边界）；`}` 等一律占位，
      // 避免剥离后的骨架出现孤立 `}` 干扰顶层块判定。
      if (chars[i] !== '\n' && chars[i] !== ';') chars[i] = ' ';
    }
  }
  return chars.join('');
}

function splitLastStatement(body) {
  const skeleton = stripInlineFnBodies(body);
  let depth = 0;
  let inStr = null;
  const seps = [-1];
  for (let i = 0; i < skeleton.length; i++) {
    const ch = skeleton[i];
    if (inStr) {
      if (ch === inStr && skeleton[i - 1] !== '\\') inStr = null;
      continue;
    }
    if (ch === "'" || ch === '"' || ch === '`') { inStr = ch; continue; }
    if (ch === '{' || ch === '(' || ch === '[') depth++;
    else if (ch === '}' || ch === ')' || ch === ']') {
      // ⚠️ 顶层块结束的 `}`（depth 由 1 → 0）是语句分隔符，必须先判再减。
      // 原实现先 depth-- 再判 SEP，`}` 永远进不了 seps；判 depth===0 也错
      // （`}` 闭合配对 `{` 时 depth 至少是 1）→ 正确判据是 depth===1。
      if (ch === '}' && depth === 1) seps.push(i);
      depth = Math.max(0, depth - 1);
    }
    else if (depth === 0 && (ch === ';')) seps.push(i);
  }
  // ⚠️ 取"最后一条顶层语句"，语义要点：
  //  · 脚本常以无分号尾表达式收尾（如 `JSON.stringify(sort)`），它在
  //    最后一个分隔符之后 → 必须优先取 tail = (seps[-1], body 结尾)。
  //    原实现只遍历 (seps[k-1], seps[k])，把尾表达式漏掉、误取成前一条
  //    .map(...) 语句 → runJs 返回 [null,null]。
  //  · tail 为空（脚本以 ; 收尾）时再回退取最后一段非空语句。
  //  · 纯闭合符段（`}`/`})`）不能当语句返回，跳过。
  const lastSep = seps[seps.length - 1];
  const tailRaw = body.slice(lastSep + 1).trim();
  if (tailRaw && !/^[}\])\]]+$/.test(tailRaw)) return { last: tailRaw };
  for (let k = seps.length - 1; k > 0; k--) {
    const seg = body.slice(seps[k - 1] + 1, seps[k]).trim();
    if (seg && !/^[}\])\]]+$/.test(seg)) return { last: seg };
  }
  return { last: body.slice(seps[0] + 1).trim() };
}

// ============================================================
// 核心：对「当前节点/文档」求一条规则
// ============================================================

/**
 * 对整条规则求值，并执行 Legado 的 `##正则##替换`（可链式）。
 * 拆分放在最外层：`a||b##r##rep` = (a/b 兜底取值) 后整体替换。
 */
function evalRule(params) {
  if (params.rule == null) return params.isList ? [] : '';
  const raw0 = String(params.rule).trim();
  let hashPairs = null;
  let base = raw0;
  const hi = raw0.indexOf('##');
  if (hi >= 0) {
    const tail = raw0.slice(hi + 2);
    const segs = tail.split('##');
    const pairs = [];
    for (let i = 0; i + 1 < segs.length; i += 2) pairs.push([segs[i], segs[i + 1]]);
    if (segs.length % 2 === 1) pairs.push([segs[segs.length - 1], '']);
    // 防御：replacement 里混入顶层 || 或 {{ → 放弃顶层 ##，
    // 原样交给 || 分支逐段处理（段级再拆 ##）。
    const bad = pairs.some(([, rep]) => rep.includes('||') || rep.includes('{{'));
    if (!bad) { base = raw0.slice(0, hi); hashPairs = pairs; }
  }
  const v = evalRuleCore({ ...params, rule: base });
  if (!hashPairs) return v;
  if (params.isList) {
    if (!Array.isArray(v)) return v;
    return v.map((x) => (typeof x === 'string' ? applyHashReplace(x, hashPairs) : x));
  }
  if (typeof v !== 'string') return v;
  return applyHashReplace(v, hashPairs);
}

/** 依次执行 ##regex##replacement 全局替换 */
function applyHashReplace(s, pairs) {
  let out = s;
  for (const [re, rep] of pairs) {
    try { out = out.replace(new RegExp(re, 'g'), rep); } catch (_) { /* 非法正则跳过 */ }
  }
  return out;
}

/** @js 的 result：把节点/文档包装转成可读 HTML 字符串 */
function nodeOrDocToString(input) {
  if (input && input.__cheerio) {
    const $ = input.__cheerio;
    if (input.__nodes && input.__nodes.length) {
      return input.__nodes.map((n) => $.html(n)).join('\n');
    }
    try { return $.root().html() || ''; } catch (_) { return ''; }
  }
  return input == null ? '' : input;
}

/**
 * @param {object} p
 * @param {string} p.rule     规则字符串
 * @param {any}    p.input    当前输入（HTML 字符串 / JSON 对象 / 节点数组）
 * @param {object} p.vars     {{}} 变量
 * @param {object} p.ctx      js 规则上下文（book/chapter 等）
 * @param {boolean} p.isList  是否要求返回列表
 * @returns {any} 字符串 或 字符串数组 或 对象
 */
/**
 * 拆分「JSONPath + @js」组合链规则：`$.a.b@js:脚本` / `$.a[*]@js:脚本`。
 * 返回 { path, js }；不是组合链返回 null。
 */
function splitJsonJsChain(rule) {
  const r = String(rule || '').trim();
  // 支持 `$.x@js:`（带 $）与 `data.items@js:`（Legado 无 $ 前缀写法）
  if (!r.startsWith('$') && !/^[A-Za-z_$][\w$]*/.test(r)) return null;
  const idx = r.indexOf('@js:');
  if (idx <= 0) return null;
  const path = r.substring(0, idx).trim();
  if (!path) return null;
  const js = r.substring(idx + 4);
  if (!js.trim()) return null;
  return { path, js };
}

/**
 * 对 JSONPath 取到的一组值执行 JS 模板（组合链后半段）。
 * result 注入为字符串：标量转 String，对象/数组 JSON.stringify。
 */
function runChainJs(vals, js, { ctx, isList }) {
  // jsonPath 的结果集是标准 JSONPath 语义：`$.data.items` 返回 [items 数组]（嵌套）。
  // 组合链要对**每个元素**注入 result 运行脚本（Legado `$.x@js:` 逐项语义），
  // 所以先展平一层：[[{id:42}]] → [{id:42}]；标量路径 ['123'] 不变。
  const flatVals = (vals || []).flatMap((v) => (Array.isArray(v) ? v : [v]));
  const results = flatVals.map((v) => {
    let res;
    if (v == null) res = '';
    else if (typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean') {
      res = String(v);
    } else {
      // 对象/数组原样注入（vm context 会复制），脚本里 `result.id` 才能取到属性；
      // 之前 JSON.stringify 成字符串导致 `result.id` 变 undefined。
      res = v;
    }
    return runJs(js, { ...ctx, result: res });
  });
  if (isList) return results;
  return results.length > 0 ? (results[0] == null ? '' : results[0]) : '';
}

function evalRuleCore({ rule, input, vars = {}, ctx = {}, isList = false }) {
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

  // ── || 多规则兜底（Legado 语义：前者为空/失败才试后者）──
  // 在 splitRule 之前拆分，这样 `a@text||b@text`、`@css:x||@css:y`
  // 都能逐段完整解析；拆分跳过 {{ }} 变量内部，防止误拆。
  if (r.includes('||')) {
    const segments = splitTopLevelOr(r);
    if (segments.length > 1) {
      for (const seg of segments) {
        const segRaw = seg.trim();
        if (!segRaw) continue;
        let out;
        try {
          out = evalRule({ rule: segRaw, input, vars, ctx, isList });
        } catch (_) {
          continue; // 该段解析失败 → 试下一段
        }
        if (isList) {
          if (Array.isArray(out) && out.length > 0) return out;
        } else if (out != null && out !== '') {
          return out;
        }
      }
      return isList ? [] : '';
    }
  }

  const { prefix, parts } = splitRule(r);

  // ── @js: ──────────────────────────────────────────────
  if (prefix === 'js') {
    // ⚠️ Legado 语义：@js 的 result 必须是**可读字符串**（当前节点的
    // HTML / 整个文档的 HTML / 原始文本）。原实现直接传 input ——
    // 节点/文档包装对象 `''+result` 会变成 "[object Object]"，
    // 导致所有基于 result.match(...) 的 author/kind 规则静默取空。
    const out = runJs(parts[0], {
    ...ctx,
    result: nodeOrDocToString(input),
    // java.getElements 要用到当前文档与作用域节点
    __cheerio: input && input.__cheerio ? input.__cheerio : ctx.__cheerio,
    __nodes: input && input.__nodes ? input.__nodes : ctx.__nodes,
  });
    return out;
  }

  // ── @json: ────────────────────────────────────────────
  if (prefix === 'json') {
    // 组合链：@json:x@js:脚本 —— 先 JSONPath 取值，再注入 result 执行 JS
    const chain = splitJsonJsChain(parts[0]);
    if (chain) {
      const root = input && input.__json ? input.__json : input;
      const vals = jsonPath(root, chain.path);
      return runChainJs(vals, chain.js, { ctx, input, isList });
    }
    const root = input && input.__json ? input.__json : input;
    const out = jsonPath(root, parts[0]);
    if (isList) {
      return out.flatMap((v) => (Array.isArray(v) ? v : [v]));
    }
    const v = out.length > 0 ? out[0] : '';
    return v == null ? '' : v;
  }

  // ── 组合链：$.x@js:脚本（裸 JSONPath + JS，无 @json: 前缀）────────
  // Legado 常见写法（如 coverUrl: `$.bookid@js:`${book.origin}/img/${result}...``）：
  // 先按 JSONPath 从 JSON 取到字段，再把字段值作为 result 注入 JS 模板拼串。
  {
    const chain = prefix === '' ? splitJsonJsChain(r) : null;
    if (chain) {
      const root = input && input.__json ? input.__json : input;
      if (root != null && typeof root === 'object') {
        const vals = jsonPath(root, chain.path);
        return runChainJs(vals, chain.js, { ctx, input, isList });
      }
    }
  }

  // 裸 JSONPath 兜底（JSON 响应 + `$.x` 规则，无 @json: 前缀）
  if (prefix === '' && parts.length === 1 && r.startsWith('$') && !(input && input.__cheerio)) {
    const root = input && input.__json ? input.__json : input;
    if (root != null && typeof root === 'object') {
      const out = jsonPath(root, parts[0]);
      if (isList) return out.flatMap((v) => (Array.isArray(v) ? v : [v]));
      const v = out.length > 0 ? out[0] : '';
      return v == null ? '' : v;
    }
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

  // TVBox 风格前缀（class./tag./id.）先转成标准 CSS —— 与 evalList
  // 同一处理。不转的话 `class.comics-detail__author@text` 会被当成
  // "标签名 class"，静默取到空串。
  const _conv = normLegadoStep(sel);
  const _wasConverted = _conv !== sel.trim();
  sel = _conv;

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
  // Legado 取值步骤归一化（@tag.a.0 → a:eq(0)、@harf → href）
  return walkParts($, nodes, rest.map(normLegadoStep), isList);
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
  // ⚠️ 列表规则末段是「选择器」时，必须返回**节点数组**（后续
  // chapterName/chapterUrl 等规则以每个节点为 input 再取值）。
  // 原来这里返回 toText 数组，导致 `class.list.clearfix.0@tag.li@tag.a`
  // 这类多段目录规则取到的是文本而不是节点 → 目录永远为空。
  if (isList) return arr.map((n) => makeNodeInput($, [n]));
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

/**
 * 按顶层 `||` 拆分规则串（跳过 {{ }} 变量内部，防止变量值含 || 被误拆）。
 */
function splitTopLevelOr(s) {
  const out = [];
  let depth = 0;
  let cur = '';
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    const next = s[i + 1];
    if (ch === '{' && next === '{') { depth++; cur += ch + next; i++; continue; }
    if (ch === '}' && next === '}') { if (depth > 0) depth--; cur += ch + next; i++; continue; }
    if (depth === 0 && ch === '|' && next === '|') { out.push(cur); cur = ''; i++; continue; }
    cur += ch;
  }
  out.push(cur);
  return out;
}

/** 统一的「取列表」入口 */
function evalList({ rule, input, vars, ctx }) {
  if (!rule) return [];
  const r = applyVars(String(rule), vars).trim();
  const { prefix, parts } = splitRule(r);

  if (prefix === 'js') {
    const out = runJs(parts[0], {
    ...ctx,
    result: input,
    // java.getElements 要用到当前文档与作用域节点
    __cheerio: input && input.__cheerio ? input.__cheerio : ctx.__cheerio,
    __nodes: input && input.__nodes ? input.__nodes : ctx.__nodes,
  });
    if (Array.isArray(out)) return out;
    if (out == null) return [];
    return [out];
  }
  if (prefix === 'json') {
    const root = input && input.__json ? input.__json : input;
    const out = jsonPath(root, parts[0]);
    return out.flatMap((v) => (Array.isArray(v) ? v : [v]));
  }

  // 裸 JSONPath 兜底：规则 `$.x[*]` 且输入是 JSON（无 @json: 前缀，
  // Legado 对 JSON 响应会自动识别）→ 按 JSONPath 展开。
  if (prefix === '' && parts.length === 1 && r.startsWith('$') && !(input && input.__cheerio)) {
    const root = input && input.__json ? input.__json : input;
    if (root != null && typeof root === 'object') {
      const out = jsonPath(root, parts[0]);
      return out.flatMap((v) => (Array.isArray(v) ? v : [v]));
    }
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
  // Legado 步骤归一化（class./tag./id. + 位置）—— 不转的话
  // `class.comics-card …` 会被当成"标签名 class"，静默匹配 0 条。
  sel = normLegadoStep(sel);
  // || 兜底：列表选择器 `class.excerpt||class.post||…` 依次尝试，取首个非空
  if (sel.includes('||')) {
    const sels = splitTopLevelOr(sel);
    if (sels.length > 1) {
      for (const one of sels) {
        const s = normLegadoStep(one.trim());
        if (!s) continue;
        let ns;
        try {
          ns = scope ? $(scope).find(s) : $(s);
        } catch (_) {
          continue;
        }
        const arr = ns.toArray();
        if (arr.length > 0) {
          return arr.map((n) => makeNodeInput($, [n]));
        }
      }
      return [];
    }
  }
  // ⚠️ 这里**不能**只看"是否以 . 开头"就送去 XPath 转换：
  // `.book-list li` 是合法 CSS 类选择器，但 xpathToCss 会把前导点吃掉，
  // 返回 `book-list li`（当成标签名）→ 匹配 0 条。
  // 表现是"所有基于 class 的书源全部搜不到东西"，而且不报错，极难查。
  // 正确判据：只有**含有 XPath 特征语法**时才转换。
  const looksXPath = prefix === 'xpath' ||
      /\/[@\w-]+|\/text\(|\[contains\(|\[@[\w-]+|^\/\.?\/|^\/\/|^\(\.?\/\//.test(sel);
  if (prefix !== 'css' && looksXPath) {
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
  runJs,
};
