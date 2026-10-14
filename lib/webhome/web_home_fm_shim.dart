// lib/webhome/web_home_fm_shim.dart
//
// `window.fm` 兼容垫片 —— 让"吃 FongMi 桥"的网页在猫影里也能用。
//
// ── 为什么需要（用户 2026-10-14 给的那几个内置 HTML）──────────────
// 4 个内置页里有 3 个（歪比巴卜 / 漫蛙动漫 / 追更助手）是这么写的：
//     if (window.fm && fm.req) { 用宿主发请求 } else { fetch(...) }
// 而 WebView 里页面的 Origin 是 `null`（本地 asset/file）⇒ 跨域 `fetch` 会被
// CORS 直接挡掉 ⇒ 不提供 `fm` 的话这几个页面基本是白屏/报错。
//
// ── 做法：把 FongMi 的 API 薄薄映射到本 App 的 `window.ant`（AntBridge）──
//   · `fm.req(url,{method,headers,body,responseType,timeout})` → `ant.request`
//       · FongMi 返回 `{ok, status, body, error}`（ant 返回 `{statusCode, data, …}`）
//       · ⚠️ FongMi 的 `timeout` 单位是**秒**，ant 是**毫秒**
//   · `fm.play(url,title,{headers})` → `ant.player.open`
//   · `fm.res(url)` → 本 App 没有资源代理 ⇒ 原样返回（尽力而为）
//   · `fm.search` **故意不提供** ⇒ 页面会走它们自己写好的搜索兜底
//
// ⚠️ 注入时机：页面的内联脚本**先**跑、我们的注入在后（onPageFinished）。
//    这几个页面都写了 `waitFm()`（等 `fmsdk` 事件 / 1.6s 超时），所以注入完
//    要主动派发一次 `fmsdk`，它们就会切到宿主通道 ✓。

/// 注入到页面的 `window.fm` 垫片（在 `window.ant` 之后注入）。
const String kWebHomeFmShim = r'''
(function () {
  if (window.fm && window.fm.req) return;
  function hasAnt() { return typeof window.ant !== 'undefined' && !!window.ant; }

  var fm = {
    version: 4,
    // FongMi 的 {ok,status,body,error} ← ant 的 {statusCode,data,headers}
    req: function (url, opt) {
      opt = opt || {};
      if (!hasAnt()) {
        return Promise.resolve({ ok: false, status: 0, body: '', error: 'bridge not ready' });
      }
      var secs = Number(opt.timeout);
      if (!(secs > 0)) secs = 25;
      return window.ant.request({
        url: url,
        method: opt.method || 'GET',
        headers: opt.headers || {},
        data: opt.body,
        responseType: 'text',
        timeout: Math.min(30000, Math.round(secs * 1000))
      }).then(function (r) {
        var st = (r && r.statusCode) || 0;
        return {
          ok: st >= 200 && st < 300,
          status: st,
          body: (r && r.data) || '',
          headers: (r && r.headers) || {},
          error: ''
        };
      }).catch(function (e) {
        return { ok: false, status: 0, body: '', error: String((e && e.message) || e) };
      });
    },
    play: function (url, title, opt) {
      opt = opt || {};
      if (!hasAnt()) return Promise.resolve();
      return window.ant.player.open({
        url: url,
        title: title || '',
        headers: opt.headers || {}
      });
    },
    // 没有资源代理：原样返回（图片能直连就直连）
    res: function (url) { return url; },
    toast: function (m) { try { if (hasAnt()) window.ant.ui.toast(String(m || '')); } catch (e) {} },
    on: function () { return function () {}; },
    off: function () {}
  };

  window.fm = fm;
  // 有些页面只认这个名字（用来判断"跑在原生里"从而切深色/透明底样式）
  if (!window.fongmiBridge) window.fongmiBridge = fm;
  try { document.documentElement.classList.add('fm-native'); } catch (e) {}
  try { window.dispatchEvent(new Event('fmsdk')); } catch (e) {}
})();
''';
