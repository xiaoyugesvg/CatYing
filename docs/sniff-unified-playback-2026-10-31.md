# 嗅探统一方案（影视 / 海阔 / 小程序 / RSS 四端同一条路）

> 2026-10-31。触发问题：探针页「点击播放」能出地址、能播，正片点了却提示
> 「这条线路播不了」。用户原话：**「影视模块现在的解析线路和嗅探完全不是
> 现在测试的这种，我不满意」**。
>
> 结论：**不是嗅探能力不够，是入口没接上。** 能力全都在，四个播放入口走了
> 四条不同的路。本文把四条路合成一条。

---

## 一、问题定性：同一个地址，两条路，两个结果

改之前，App 里同时存在两条「网页地址 → 媒体地址」的路：

| | 探针页「点击播放」 | 影视模块正片 |
|---|---|---|
| 入口 | `dev/sniffer_probe_page._sniffAndPlay` | `detail/controller._sniffPageForMedia` |
| 顺序 | **纯嗅探优先** | **HTTP 优先**，嗅探只兜底 |
| 嗅探预算 | 20s 全给嗅探 | `22s − 12s = HTTP 10s` 之后剩多少给多少 |
| 4 层 iframe | 跟得完（实测 12.3~19.3s） | **第 4 层刚开始就被总预算砍断** |

日志实证（`app_2026-10-31(7).log`，21:38:08 那次）：总耗时 12.2 秒，第 4 层
只跑了 **0.56 秒** 就被砍断，候选 0 条 → 判「播不了」。同一条地址在探针页
能一路跟到 `api-api.789jiexi.net`、解出 `xhyyxx.oxapi.cn` 的 m3u8（200、73KB、
938 分片）。

所以修法不是「再加强嗅探」，而是**让正片走探针页那条路**。

---

## 二、统一后的链路（一条，四端共用）

```
播放地址
  │
  ├─ 已是媒体直链（m3u8/mp4/flv/mkv…）──────────────→ 原生播放器
  │
  └─ 是网页
       │
       ├─ ① 嗅探优先（MediaSniffService，离屏 WebView，最多 4 层）
       │     命中 → 原生播放器 ✅
       │
       ├─ ② 没命中 → HTTP 抓页面 + 解析线路逐条试（原有逻辑，不变）
       │     命中 → 原生播放器 ✅
       │
       └─ ③ 都没命中 → 内嵌网页播放器兜底（用户自己点）
```

三条原则：

1. **顺序一致**：四端都是「先嗅探」。顺序反了就会出现「测试能播、正片播不了」。
2. **降级一致**：嗅探失败不报错，继续走 HTTP；HTTP 也失败才进网页兜底。
   所以这条路**只会比原来多抓，不会比原来少抓**。
3. **预算一致**：嗅探预留 20s（4 层 × 5s 保守估计），总预算 30s。

### 预算为什么是 30s / 20s

```
defaultBudget   30s   ← 上限，命中即返回（szctv 那种 3.2s 就出）
_sniffReserve   20s   ← 嗅探最多吃这么多
_minHttpBudget   8s   ← HTTP 兜底至少留这么多
```

- 4 层实测 12.3~19.3s ⇒ 12s 不够，必须 ≥ 20s。
- 30s 只是上限：绝大多数地址 3~8 秒就出结果，只有全链路空手才等满。
- 嗅探优先跑过之后不再兜底嗅探第二次（`sniffAllowed = false`），避免白等两轮。

---

## 三、四个入口怎么接的

### 1. 影视模块（主链路）

`lib/pages/detail/controller.dart` → `_sniffPageForMedia()`

```dart
final found = await MediaResolver.instance.resolve(
  pageUrl,
  headers: headers,
  sniffFirst: true,          // ← 关键一行
  onProgress: (msg) => _resolveHint.value = msg,
);
```

- 两个调用点都走这里：Spider 返回网页（1014 行附近）、普通线路返回网页（1276 行附近）。
- 解析过程只在播放区上方显示一行小字（`_resolveHint`），不弹窗、不遮画面。
- 嗅探用**离屏** WebView：不占屏、不进导航栈，跑完即销毁。
  （原来注释写「不起 WebView」，改成嗅探优先后这句不准确了，已改正。）

### 2. 海阔

`lib/hiker/pages/hiker_detail_page.dart` → `_resolveAndPlay()`

改之前：`PlayKind.page` **直接** `_pushWeb`，完全不嗅探 —— 海阔源给的多是
解析站/播放站页面，等于把「在广告里找播放按钮」丢回给用户。

改之后新增 `_sniffThenPlay()`：

```dart
case PlayKind.page:
  final sniffed = await _sniffThenPlay(resolution.url, resolution.headers);
  if (sniffed) return;                    // 进原生播放器
  return _pushWeb(...);                   // 兜底
```

用的是**同一个** `MediaResolver.resolve(sniffFirst: true)`，保证海阔里点播放
和探针页测出来能播的地址结果一致。

### 3. 小程序 `player.open`

`lib/miniapp/services/ant_bridge.dart` → `_playerOpen()`

改之前：`isPage` → 直接 `PlaybackSurface.webFallback`。
改之后：先嗅探，命中就进 `MiniAppPlayerPage`，返回值里 `sniff: true` 如实回报
（小程序侧可以据此区分「直链」和「嗅探得到」）。

```dart
return {'route': 'player', 'url': direct, 'sniff': true, ...};
```

### 4. RSS

`lib/rss/pages/rss_article_page.dart` → `_playEpisode()`

RSS 原来**根本不经过 `PlayPipeline`**：`RssReader.resolvePlayUrl` 拿不到直链
就直接 `webFallback`。改成分三段：

```
① 直链        → 原生播放器
② 非直链/空   → 嗅探优先（MediaResolver，sniffFirst: true）
③ 嗅探也没出  → 内嵌网页兜底
```

嗅探期间卡片里的小转圈继续转（`_resolving` 保持 true），不会出现「点了没反应」。

> 注：`_openPlayPage()`（「在线播放 · 打开原网页选线路/集数」）**故意不改**。
> 那是详情页，页面上没有播放器，嗅探必然空手；它的用途就是让用户去选线路。

---

## 四、防回归：接线守卫

这类 bug 单测抓不到（每段代码单独看都对），只能静态盯着。新增
`test/sniff_first_wiring_test.dart`（11 条）：

| 断言 | 防的是什么 |
|---|---|
| 四个入口文件都含 `sniffFirst: true` | 以后新增播放入口（投屏 / TV 版 / 车机）忘了接线 |
| 四个入口都引用 `MediaResolver` | 有人绕过统一链路自己写一套 |
| 探针页「先嗅探、后 HTTP」的顺序 | 有人把探针页也改成 HTTP 优先，两边又对不上 |
| `_sniffReserve ≥ _maxHops × _minHop` | 有人把 `_maxHops` 提到 5 却没加预算 ⇒ 最后一层又被砍 |
| `defaultBudget > _sniffReserve` | 嗅探优先吃满后没有 HTTP 兜底余量 |

实现细节：读源码时先剥掉 `//` 和 `/* */` 注释，避免「注释里写了
`sniffFirst: true`」就让测试误绿（`sniffer_hook_test` 踩过这个坑）。

---

## 五、验证方法（不用等正片）

1. 打开探针页，粘一个之前播不了的地址 →「点击播放」→ 记下出不出地址、耗时。
2. 去影视模块同一个源、同一集 → 点播放。
3. 看日志两条关键行：

```
[Resolve] 嗅探优先，预算 20s（和探针页同一条路）
[Resolve] 嗅探优先命中: https://…/xxx.m3u8
```

如果正片日志里出现的是 `HTTP 预算 10s，嗅探兜底=开`，说明 `sniffFirst`
没传到（接线断了），守卫测试会先红。

---

## 六、还没做的（按优先级）

| # | 事项 | 说明 |
|---|---|---|
| 1 | **网页兜底里也挂嗅探** | 现在进 `webFallback` 后页面自己在 WebView 里播，抓到的地址不外传。可以让兜底页也挂 hook，抓到就切原生播放器（画质/倍速/投屏全解锁） |
| 2 | **预解析下一集** | 详情页进来自动后台跑一次嗅探，用户点播放时直接命中缓存（`MediaResolver._cache` 已支持） |
| 3 | **失败候选落盘** | 把「哪个域名、卡在第几层、有没有被 302 带走」写进日志文件，用户反馈时不用再靠猜 |
| 4 | **`PlaybackSurface.webFallback` 统一入口** | 现在多处各自 `Navigator.push`，没法统一加嗅探/广告拦截 |

---

## 七、涉及文件

```
lib/services/media_resolver.dart          嗅探优先分支 + 预算 30s/20s
lib/services/media_sniff_service.dart     _maxHops=4（沿用）
lib/services/sniffer_hook_js.dart         注入 JS（响应体扫描、xyplay、ad/player）
lib/pages/detail/controller.dart          影视模块接线
lib/hiker/pages/hiker_detail_page.dart    海阔接线（_sniffThenPlay）
lib/miniapp/services/ant_bridge.dart      小程序 player.open 接线
lib/rss/pages/rss_article_page.dart       RSS 分集播放接线
test/sniff_first_wiring_test.dart         接线守卫（新增，11 条）
```
