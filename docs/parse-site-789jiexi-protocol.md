# 解析站协议存档：`jx.muiu.site` → `789jiexi`（2026-10-31 实测）

> 这套协议是**从线上 JS 里抠出来的**，不是猜的。存下来是因为已经反复
> 重新推导三次了；下次这条链出问题，先对照这里。

## 一、链路（4 层）

```
L1  https://jx.muiu.site/?url=<原页面>
      MUAO 智能解析 X4。页面只是壳，播放器由 include/xyplay.min.js 创建。
      POST api.php?tp=checkPlay&url=<原页面>
        → {"success":1,"code":0,"m":"404","type":"jx","url":"<原页面>"}
      type=jx 表示"要走解析"，于是 jxplay() 插 iframe（**服务端 HTML 里没有**，
      所以纯 HTTP 抓页面看不到 iframe —— 必须嗅探或按规律自己拼下一跳）

L2  https://www.ckplayer.vip/jiexi/?url=<原页面>        (1254B)
      iframe → /jx.php?url=<原页面>

L3  https://www.ckplayer.vip/jx.php?url=<原页面>        (759B)
      iframe → https://api-api.789jiexi.net/jiexi.php?url=<urlencoded>

L4  https://api-api.789jiexi.net/jiexi.php?url=…        (3344B)
      Artplayer 页面。内联 config + stray.start()
```

⚠️ **L2/L3 不带 Referer 会 302 回上一页**（`jx.php` 尤其明显），
App 里必须用 `window.location.href` 跳转才能让 WKWebView 自动带 Referer
（自定义 header 会被 iOS 忽略）。

## 二、L4 的取流协议

页面内联 config（**注意：是 JS 对象，有尾逗号，不能直接 JSON.parse**）：

```js
var config = {
  "url":"https%3A%2F%2Fv.qq.com%2Fx%2Fcover%2F…html",  // 原页面，URL 编码过
  "time":"1793456583",                                  // 时间戳
  "key":"8be98566c98417678837f7eb4798ab9b",             // 32 位 hex
  "api":"https://api.danmu.icu/",
  …
};
stray.start()
```

`artplayer/js/setting.js` 里的 `stray.start()`：

```js
$.post("api.php", {url: config.url, time: config.time, key: config.key}, cb, 'json')
// → {"code":"200","url":"<base64 密文>","type":"m3u8"}
realPlayUrl = decrypt(stray.url).replace(/http:\/\//g, 'https://')
stray.ad = new Artplayer({url: realPlayUrl, type: stray.type, …})
```

解密函数（**原文**，就在 setting.js 里）：

```js
/*播放地址AES-CBC-128解密代码*/
function decrypt(text) {
  let decrypted = CryptoJS.AES.decrypt(text, CryptoJS.Utf8.parse('ARTPLAYERliUlanG'), /*key16位*/ {
    iv: CryptoJS.Utf8.parse('ArtplayerliUlanG'), /*iv16位*/
    mode: CryptoJS.mode.CBC,
    padding: CryptoJS.pad.Pkcs7
  });
  return decrypted.toString(CryptoJS.Utf8)
}
```

- 算法：**AES-128-CBC / Pkcs7**
- key：`ARTPLAYERliUlanG`（16 字节）
- iv：`ArtplayerliUlanG`（16 字节）
- 密文：base64
- 明文里 `http://` 要**全局**换成 `https://`（分片地址也会出现 http）

## 三、本地复现脚本（node）

```js
const crypto = require('crypto');
const KEY = 'ARTPLAYERliUlanG', IV = 'ArtplayerliUlanG';

// ① 拿 L4 页面 → 正则抠 config 的 url/time/key（别 JSON.parse，有尾逗号）
// ② POST https://api-api.789jiexi.net/api.php
//    form: { url, time, key }，Referer: L4
// ③ 解 base64 → AES-128-CBC 解密 → 把 http:// 换成 https://
// ④ GET 这个 m3u8，看 200 + 分片数
```

## 四、App 侧对应实现

| 环节 | 实现 |
|---|---|
| 跟 4 层 iframe | `MediaSniffService._maxHops = 4` |
| 跟帧带 Referer | `_load(..., viaLocation: true)` → `window.location.href` |
| 拿 `stray.ad.option.url` | 注入 JS `dig()` 挖 `ad` / `player` 键 |
| 拿 `console.log` 的明文 | 注入 JS `hookConsole()` |
| 拿 `video.src` | 注入 JS `hookMediaSrc()`（2026-10-31 新增） |
| 视口尺寸 | 390×844（**不是 1×1**，否则播放器不建 `<video>`） |
| 预算 | 35s 总 / 25s 嗅探（4 层实测 12s + L4 解密 3~5s） |

## 五、2026-10-31 22:15 的状态

- **协议全部验证通过**：4 层链路、config 字段、`api.php` 的 POST 参数、
  AES 密钥与模式，全部对得上。
- **但服务端上游挂了**：`api.php` 对**任何**视频都返回
  `{"code":404,"msg":"请求上游解析接口失败"}` —— 用户那一集、腾讯另一部、
  爱奇艺对照组，三条全一样，各重试 4 次。
- 所以此刻「拿不到地址」是**站点侧故障**，不是 App 逻辑问题。
  同一天早些时候同一个接口能返回 `xhyyxx.oxapi.cn/Cache/tx1080/…m3u8`
  （200、73KB、938 分片）。
- 判断依据：如果日志里出现 `api.php` 返回 404 / `code:404`，
  先换一条解析线路验证，别改 App。
