/// 注入到 WebView 的嗅探脚本（≈ cat-catch 的 content-script）。
///
/// 目标：把「页面里真跑起来的 JS」生成的媒体地址捞出来，覆盖三类来源：
///   1. XHR / fetch 请求到的地址（**含没有扩展名、靠 Content-Type 认的流**）；
///   2. `<video>` / `<source>` 的 currentSrc / src；
///   3. `performance` 资源条目里的 .m3u8/.mp4/.m4s/.mpd/.flv/.ts（带 ?query 也认）。
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

  setInterval(function () { scanDom(); scanPerf(); }, 700);
  window.addEventListener('load', function () { scanDom(); scanPerf(); });
  setTimeout(function () { scanDom(); scanPerf(); }, 1500);
})();
''';
