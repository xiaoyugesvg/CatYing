/// 注入到 WebView 的嗅探脚本（≈ cat-catch 的 content-script）。
///
/// 目标：把「页面里真跑起来的 JS」生成的媒体地址捞出来，覆盖四类来源：
///   1. XHR / fetch 请求到的地址（**含没有扩展名、靠 Content-Type 认的流**）；
///   2. `<video>` / `<source>` 的 currentSrc / src；
///   3. `performance` 资源条目里的 .m3u8/.mp4/.m4s/.mpd/.flv/.ts（带 ?query 也认）；
///   4. **播放器对象里的 url 变量 + console 输出**（2026-10-31 新增）。
///
/// 第 4 类为什么必须有：实测 `jx.muiu.site` 那条链，播放器把解密后的地址
/// 存进 JS 变量，交给 hls.js 之前就报 `Unsupported playback format: m3u8`
/// —— **一个网络请求都没发**。只钩 XHR/fetch 会一条都抓不到；真正暴露地址的
/// 是它自己那句 `console.log('解密原始链接：', url)`。
///
/// 命中后通过 JavaScriptChannel `CatSniff` 回传 JSON：{url, kind, via}。
/// 该脚本幂等（`__catSniffInstalled` 守卫），可反复注入。
const String kSnifferHookJs = r'''
(function () {
  if (window.__catSniffInstalled) return;
  window.__catSniffInstalled = true;

  var MEDIA_RE = /\.(m3u8|m4s|mpd|mp4|m4v|mov|flv|ts)(?:[?#]|$)/i;
  var MEDIA_CT_RE = /(mpegurl|dash\+xml|video\/|audio\/|octet-stream|mp2t)/i;
  var seen = {};

  function report(u, kind, via) {
    try {
      if (!u) return;
      u = String(u).trim();
      if (!u) return;
      if (u.indexOf('blob:') === 0 || u.indexOf('data:') === 0) return;
      if (u.indexOf('//') === 0) u = location.protocol + u;
      if (!/^https?:/i.test(u)) return;
      if (seen[u]) return;
      seen[u] = 1;
      if (window.CatSniff && window.CatSniff.postMessage) {
        window.CatSniff.postMessage(JSON.stringify({url: u, kind: kind || '', via: via || ''}));
      } else if (window.console && console.log) {
        // 浏览器控制台测试用：没有 App 的 CatSniff 通道时，退回打印。
        console.log('[CatSniff]', kind || '?', via || '?', u);
      }
    } catch (e) {}
  }

  function classify(u, ct) {
    if (/\.m3u8(?:[?#]|$)/i.test(u) || /mpegurl/i.test(ct || '')) return 'm3u8';
    if (/\.mpd(?:[?#]|$)/i.test(u) || /dash\+xml/i.test(ct || '')) return 'mpd';
    if (/\.(mp4|m4v|mov)(?:[?#]|$)/i.test(u) || /video\//i.test(ct || '')) return 'mp4';
    if (/\.(flv|ts|m4s)(?:[?#]|$)/i.test(u) || /mp2t/i.test(ct || '')) return 'seg';
    return '';
  }

  function maybe(u, ct, via) {
    if (!u) return;
    if (MEDIA_RE.test(u) || MEDIA_CT_RE.test(ct || '')) {
      report(u, classify(u, ct), via);
    }
  }

  // ── ② 变量层（2026-10-31 新增，实测必需）──────────────────────────
  //
  // 有的播放器**根本不发请求**也能拿到地址：它把解密后的地址存在 JS 变量里，
  // 交给 hls.js 之前如果格式不支持就直接报错，网络层一条请求都没有。
  // 用户日志实测的站（789jiexi → Artplayer）就是这样：
  //   控制台：解密原始链接： https://xhyyxx.oxapi.cn/Cache/tx1080/xxx.m3u8
  //   页面：  Unsupported playback format: m3u8     ← 没发请求
  // 所以必须额外读"播放器对象里的 url"，光钩 XHR/fetch 永远拿不到。
  var VAR_NAMES = [
    'config', 'art', 'artplayer', 'player', 'videoObject', 'hls',
    'stray', 'myPlayer', 'dp', 'playerObj', 'videojs', 'dplayer'
  ];
  var URL_KEYS = ['url', 'src', 'file', 'playUrl', 'videoUrl', 'currentSrc', 'm3u8', 'hlsUrl'];

  function maybeVarUrl(u) {
    if (typeof u !== 'string' || !/^https?:/i.test(u)) return;
    if (MEDIA_RE.test(u)) report(u, classify(u, ''), 'var');
  }

  function dig(o, d) {
    if (!o || d > 2) return;
    if (typeof o === 'string') { maybeVarUrl(o); return; }
    if (typeof o !== 'object') return;
    for (var i = 0; i < URL_KEYS.length; i++) {
      try { maybeVarUrl(o[URL_KEYS[i]]); } catch (e) {}
    }
    // 常见嵌套：art.option.url / artplayer.option / player.config
    try { if (o.option) dig(o.option, d + 1); } catch (e) {}
    try { if (o.config) dig(o.config, d + 1); } catch (e) {}
  }

  function scanVars() {
    for (var i = 0; i < VAR_NAMES.length; i++) {
      try { dig(window[VAR_NAMES[i]], 0); } catch (e) {}
    }
  }

  // ── ③ iframe 层（2026-10-31 新增）────────────────────────────────
  //
  // 解析站几乎都是"壳 + iframe 嵌播放器"。主 frame 读不到 iframe 内部的
  // 变量（跨域），但**能读到 iframe 的 src**。把 src 回传给 Dart，
  // 由它把那一层当顶层页重新加载一次 —— 这样就不需要"注入所有 frame"
  // 这种必须改原生的能力了。
  function scanFrames() {
    try {
      var fs = document.querySelectorAll('iframe');
      for (var i = 0; i < fs.length; i++) {
        var s = fs[i].src || fs[i].getAttribute('src') || '';
        if (!s) continue;
        if (s.indexOf('//') === 0) s = location.protocol + s;
        if (!/^https?:/i.test(s)) continue;
        if (seen[s]) continue;
        seen[s] = 1;
        if (window.CatSniff && window.CatSniff.postMessage) {
          window.CatSniff.postMessage(JSON.stringify({ url: s, kind: 'frame', via: 'frame' }));
        }
      }
    } catch (e) {}
  }

  // ── ④ console 层（2026-10-31 新增）───────────────────────────────
  //
  // 不少解析脚本解密完会 `console.log('解密后的地址：', url)`。
  // 实测那个站就是这么暴露的，而它一个网络请求都没发。
  (function hookConsole() {
    if (window.__catConsoleHooked) return;
    window.__catConsoleHooked = true;
    var RE = /https?:\/\/[^\s"'<>\\]+/g;
    function scanArgs(args) {
      try {
        for (var i = 0; i < args.length; i++) {
          var a = args[i];
          if (typeof a !== 'string') continue;
          var m = a.match(RE);
          if (!m) continue;
          for (var j = 0; j < m.length; j++) {
            var u = m[j].replace(/[),.;]+$/, '');
            if (MEDIA_RE.test(u)) report(u, classify(u, ''), 'console');
          }
        }
      } catch (e) {}
    }
    ['log', 'info', 'warn', 'debug'].forEach(function (k) {
      try {
        var o = console[k];
        if (!o) return;
        console[k] = function () {
          scanArgs(arguments);
          return o.apply(console, arguments);
        };
      } catch (e) {}
    });
  })();

  try {
    var XO = XMLHttpRequest.prototype.open;
    var XS = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (m, u) {
      try { this.__catUrl = u; } catch (e) {}
      return XO.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {
      try {
        var self = this;
        this.addEventListener('loadend', function () {
          try {
            var ct = '';
            try { ct = self.getResponseHeader('content-type') || ''; } catch (e) {}
            maybe(self.responseURL || self.__catUrl, ct, 'xhr');
          } catch (e) {}
        });
      } catch (e) {}
      return XS.apply(this, arguments);
    };
  } catch (e) {}

  try {
    var OF = window.fetch;
    if (OF) {
      window.fetch = function () {
        var args = arguments;
        return OF.apply(this, args).then(function (resp) {
          try {
            var ct = '';
            try { ct = (resp.headers && resp.headers.get('content-type')) || ''; } catch (e) {}
            maybe(resp.url, ct, 'fetch');
          } catch (e) {}
          return resp;
        });
      };
    }
  } catch (e) {}

  function scanDom() {
    try {
      var els = document.querySelectorAll('video,source,iframe');
      for (var i = 0; i < els.length; i++) {
        var e = els[i];
        var u = e.currentSrc || e.src || '';
        if (u) maybe(u, '', 'dom');
      }
    } catch (e) {}
  }

  function scanPerf() {
    try {
      if (!window.performance || !performance.getEntriesByType) return;
      var es = performance.getEntriesByType('resource');
      for (var i = 0; i < es.length; i++) {
        var n = es[i].name;
        if (n) maybe(n, '', 'perf');
      }
    } catch (e) {}
  }

  setInterval(function () { scanDom(); scanPerf(); scanFrames(); scanVars(); }, 700);
  window.addEventListener('load', function () { scanDom(); scanPerf(); scanFrames(); scanVars(); });
  setTimeout(function () { scanDom(); scanPerf(); scanFrames(); scanVars(); }, 1500);
})();
''';

/// 让隐形嗅探 WebView **不出声**。
///
/// ── 为什么必须有（2026-10-31）──────────────────────────────────
/// 嗅探要在页面里把播放器真的跑起来才抓得到地址，而播放器一跑就会出声。
/// 探针页是用户主动点的，出声还能接受；但 Phase 2 把它接进正式播放链路后，
/// 用户点「播放」会先听到一段陌生页面的声音 —— 比抓不到地址更糟。
///
/// 做法（三层，任意一层生效就够）：
///   1. 钩 `HTMLMediaElement.prototype.play`，播放前先置 `muted = true`；
///   2. 用 `MutationObserver` + 定时器，把**已经存在**的媒体元素逐个静音；
///   3. `volume = 0` 兜底（某些播放器会自己改回 muted）。
///
/// ⚠️ 只静音，不暂停 —— 暂停了就没有网络请求，也就抓不到地址了。
const String kSilenceMediaJs = r'''
(function () {
  if (window.__catSilentInstalled) return;
  window.__catSilentInstalled = true;

  function hush(el) {
    try {
      if (!el || !el.tagName) return;
      var t = String(el.tagName).toUpperCase();
      if (t !== 'VIDEO' && t !== 'AUDIO') return;
      if (!el.muted) el.muted = true;
      if (el.volume !== 0) el.volume = 0;
    } catch (e) {}
  }

  function hushAll() {
    try {
      var els = document.querySelectorAll('video,audio');
      for (var i = 0; i < els.length; i++) hush(els[i]);
    } catch (e) {}
  }

  try {
    var P = HTMLMediaElement.prototype;
    var OP = P.play;
    if (OP) {
      P.play = function () {
        hush(this);
        return OP.apply(this, arguments);
      };
    }
    var OV = Object.getOwnPropertyDescriptor(P, 'volume');
    if (OV && OV.set) {
      Object.defineProperty(P, 'volume', {
        configurable: true,
        get: OV.get,
        set: function (v) { try { OV.set.call(this, 0); } catch (e) {} }
      });
    }
  } catch (e) {}

  try {
    new MutationObserver(hushAll).observe(document.documentElement, {
      childList: true, subtree: true
    });
  } catch (e) {}

  hushAll();
  setInterval(hushAll, 500);
})();
''';
