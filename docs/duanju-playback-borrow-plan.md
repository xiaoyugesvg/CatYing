# Duanju(火翼) 嗅探 / 解析线路 —— 可借鉴方案

> 背景：用户点播放后「转圈 → 进网页 → 黑屏」，全程无状态提示、看不到嗅探、不能换线路。
> 目标：对照 Duanju(短剧/火翼) 的实现，列出 New-Tv 可借鉴的改造项。
>
> ⚠️ **核验更正（2026-10-28 复读双方源码）**：早期版本有 3 处结论经不起源码核对，已在本版纠正：
> ① Duanju **不是 Go 内核**，也不是纯 Dart，而是「Flutter 壳 + 编译型原生核心（Dart FFI）」；
> ② New-Tv 的**解析「循环全试」已经做了**（并发、首个成功即返回、「自动」模式遍历全部），`P1-1` 不能写成"缺失"；
> ③ New-Tv **已有代际取消**（`_spiderResolveToken` 等），只是没叫 `_generation`。
> 本文所有 Duanju 结论逐一核实自 `hoyittvggfh45/huoyi-source-public` 源码；所有 New-Tv 结论核实自 `E:/Dev/New-Tv/lib` 当前代码。

---

## 1. Duanju 的真实架构与核心做法（逐文件核实）

### 1.1 总体架构：Flutter 壳 + 编译型原生核心（FFI）

Duanju **既不是纯 Dart，也不是 Go 源码可逐行读**。它的解析/取址重活在编译产物里：

- `lib/core_bridge.dart` 通过 **Dart FFI** 调用原生动态库（`libduanju_core.so` / `.dll` / `.dylib`）里的 `DuanjuRequest`，用 JSON 的 `action` 字段分发：`resolve` / `resolveParse` / `fallback` / `selectRoute` / `localPlayback` / `cancelPlayback` / `release` …
- **「解析接口循环全试」在原生库内部**：Dart 只把**全部启用的解析接口** `parseApis`（List<String>）传进去，原生库迭代、`_first success wins`、全失败才报 `解析接口全部失败`。这一层 Dart 侧**看不到源码**，只能从契约推断（这正是它和 New-Tv 最大架构差别）。
- 嗅探 / 恢复 / 错误分类 / 代际取消 / 卡顿检测都是 **Dart 侧**（`lib/playback_*.dart`），可逐行核实。

```dart
// core_bridge.dart 的契约（Dart 侧只传这些）
resolve(drama, chapter, index, quality, route, adBlock, parseApis, sequence, force)
  → PlaybackPlan(url, headers, session, route, routeCount, hasAlternative, ...)
resolveParse(url, headers, parseApis, adBlock, sequence)  // 二次解析
fallback(session, sequence)        // 解析/播放失败回退到备用线路/源
selectRoute(session, route, sequence)  // 在多线路中切到指定 route
```

### 1.2 resolve：解析 + 嗅探 + 广告拦截 + 二次解析的一次性入口

`resolve` 内部把整条链路串起来：站点请求 → 从网页/接口**嗅探**真实直链 → 应用广告拦截 → 调 `parseApis` 做**二次解析**。`resolveParse` 专门对"需要二次解析的地址"再走一遍解析接口。

### 1.3 PlaybackRecovery：两层宽容（refresh → alternative，max 6） —— `lib/playback_recovery.dart`

```dart
static const maxAttempts = 6;
PlaybackRecoveryAction next(PlaybackPlan plan) {
  // 第一层：先在同线路重新解析一次（抗抖动/限流/慢加载）
  if (!_refreshed) { _refreshed = true; return refresh; }
  // 第二层：仍失败且 plan.hasAlternative → 逐条切备用线路
  if (plan.hasAlternative) { return alternative; }
  return stop;
}
```
外加 `PlaybackHealth`（同文件）：`stallTimeout = 20s`，`stalled()` 在**播放进度长时间不前进**时判卡顿 → 触发恢复。这是"转圈卡住不报错"的解药。

### 1.4 PlaybackErrorKind：5 类 + 建议 + 是否建议换线 —— `lib/playback_error.dart`

```dart
enum PlaybackErrorKind { network, source, decode, permission, other }
// 关键词匹配：403/401/未登录/vip → permission；timeout/socket/502 → network；
//              解码/codec → decode；解析失败/空地址/404 → source
bool get suggestRoute => source || decode || permission;  // 这三类才提示换线路
```

### 1.5 SnifferService + SniffWebViewPage：JS 探针嗅探 + 打分 + 候选 UI —— `lib/playback_sniffer.dart`

- `MediaSniffer.probeScript`：注入后 hook `XMLHttpRequest.open` / `window.fetch` / `MutationObserver` / `performance.getEntriesByType`，抓取页面发出的媒体地址；`SniffWebViewPage` 每 2s 轮询 `window.__sniffedMedia`。
- `SnifferService._score`：`m3u8=0 / mpd=1 / mp4=2 / 其它=3`，`preferred` 排序取最优（m3u8 主列表优先）。
- `SniffWebViewPage` 把候选列出来，并给一个「**播放推荐地址**」按钮——嗅探结果对用户**可见、可手动挑**。

### 1.6 PlaybackLoader：代际取消 + fallback/selectRoute 编排 —— `lib/playback_loader.dart`

```dart
Future<PlaybackPlan?> _load(Future<PlaybackPlan> Function() resolve) async {
  final generation = ++_generation;
  await repository.cancelPlayback();           // 取消上一次
  final plan = await resolve();
  if (generation != _generation) {              // 过期结果直接丢弃
    await repository.release(plan.session);
    return null;
  }
  return plan;
}
```
`fallback` / `selectRoute` / `use` 全部走 `_load` → 统一代际管理；`close()` 递增代际并取消。这是切集/快进竞态的根治手段。

---

## 2. New-Tv 现状（逐文件核实，修正早期误判）

### 2.1 解析：ParseService 已经"循环全试"且更细 —— `lib/services/parse_service.dart` + `lib/services/parse_store.dart`

- `parseOutcome()` **并发**请求所有启用的解析接口（`_resolveConcurrently`），首个成功即返回；`ParseStore.activeBean == null` 即「**自动（按顺序尝试）**」模式（`parse_sniff_sheet.dart` 第 316 行）。
- 额外比 Duanju 更细的能力：10 分钟 LRU 缓存、`preferWindow` 首选抢跑窗口、直链探针（401/403/416 按可用处理）、m3u8 文本直出识别、严格后缀/JSON/w3.org 误判防护、`Range: bytes=0-0` 探测。
- **结论：P1-1 的"循环全试"在解析层 New-Tv 已经做到**，甚至比 Duanju 串行更高效。真正的缺口见 §3 P1-1（手选单线失败没回退遍历其余）。

### 2.2 线路（源内多线路）：flag + qualityOptions，且已有候选自动顺延 —— `lib/pages/detail/controller.dart`

- `vodInfo.playUrlMap[flag]` = 源返回的**多线路**（与 Duanju 的 `route`/`routeCount`/`hasAlternative` 同义），`selectFlag()` 切换（`controller.dart:506`）。
- `qualityOptions` = 一条线路内的**多清晰度/多直链候选**；`setPlaybackError → _advanceToNextCandidate`（`controller.dart:660/676`）**自动顺延**到下一条未试过的候选（带 `_failedPlayUrls` 去重），全部试完才写 `errorMessage`。
- `playbackSessionId` = Duanju 的 `session`。
- **缺口**：自动顺延**只限当前 flag 内**；失败**不会自动切到下一个 flag（源内其它线路）**。这正是 Duanju `alternative` 层做的事。

### 2.3 嗅探：SniffPlayerPage + WebviewPlayerPage，且多了跨域兜底 —— `lib/pages/play/sniff_player_page.dart` + `lib/pages/play/webview_player_page.dart`

- 独立嗅探页 `SniffPlayerPage` 同样注入 `hookScript`/`sniffScript`，列候选 + 「播放推荐地址」——与 Duanju `SniffWebViewPage` 基本一致。
- 内嵌网页播放器 `WebviewPlayerPage` **后台嗅探**：JS hook 轮询（1.5s，`webview_player_page.dart:330`） + `SniffMedia` 通道实时上报 + 每 4 轮 MIME 复核（`_mimeFallback`） + **网络层 HTTP 兜底抓跨域 iframe**（`_httpSniffFallback`，Duanju 的 `SniffWebViewPage` 只单 WebView、无 HTTP 兜底，跨域 iframe 会漏）。
- 黑屏根因（早期）已在 **P0 轮修复**：删掉 `if(!sniffEnabled) return` 使后台嗅探无条件跑（`webview_player_page.dart:292`）；新增 `onSniffState` 让详情页显示「正在嗅探视频地址…」；主文档加载失败显示「这个网页打不开」+ 重试。

### 2.4 代际取消：已有（命名不同） —— `lib/pages/detail/controller.dart`

- `_spiderResolveToken` / `_playbackStartToken` / `_detailLoadToken` / `_qualityResolveToken` 全是代际号，过期结果直接 `return` 丢弃（防切集/快进竞态）。**早期对照表"New-Tv 未见明确代际取消"是错的**——它只是没叫 `_generation`。

### 2.5 卡顿检测：缺失

- 只有 `video_player.dart` 的 **15 秒「地址获取超时」**硬兜底；**没有**"播放中进度长时间不前进就触发恢复"的主动卡顿检测（Duanju 的 `PlaybackHealth`）。

---

## 3. 改造清单（按真实缺口）

### P0 —— 链路可见性（**已做**，见 §5）
加载文案 + 嗅探浮层 + 错误态带按钮 + 等待画面常驻「嗅/解/换线路」；主文档失败"这个网页打不开"+重试。已解决"看不出在干嘛 / 停在网页 / 黑屏无入口"。

### P1 —— 真正缺的三块（用户已点名"开搞"）

- **P1-1 解析失败也要遍历全部接口（补"手选单线失败"漏洞）**
  - 落点：`DetailController._resolveSpiderPlayUrl` / `_startPlayback` 里 `parseOutcome(target, only: userForced ? ParseStore.instance.activeBean : null)`（`controller.dart:1058` / `:1308`）。
  - 现状：用户手选某条解析线路（或关掉"优先脚本内置解析"）时 `only` 非空，**只试那一条**；该条失败直接转网页嗅探，可能漏掉本可成功的其它线。
  - 改法：解析失败兜底里若 `only` 非空，先以"自动（遍历全部）"再试一次，仍失败才转嗅探/报界面。复用现有 `ParseService` 并发全试，**不另写循环**。

- **P1-2 轻量自动恢复（借 PlaybackRecovery，复用现有换线路按钮）**
  - 落点：`DetailController.setPlaybackError`（`controller.dart:660`）+ 现有 `selectFlag`（`controller.dart:506`）。
  - 改法：在失败分支接一个 Recovery——先同 flag 重解（refresh），再自动切下一个 flag（alternative），上限 N=6；每次切换在详情页显示「正在换线路重试（第 k/6 次）」。复用现有 `selectFlag` 与候选自动顺延，**不用用户手动一个个试**。

- **P1-3 错误分类（借 PlaybackErrorKind）**
  - 落点：`DetailController.setPlaybackError` 的 `errorMessage` 生成处。
  - 改法：包一层 `classifyPlaybackError`；命中 source/decode/permission 类时**自动弹"换线路"**并把分类建议写进错误态文案。5 类关键词表可直接搬（`playback_error.dart`）。

### P2 —— 体验 / 健壮性

- **P2-1 卡顿检测（借 PlaybackHealth）**：播放中进度 ≥20s 不前进 → 触发 P1-2 的恢复流程（解决"转圈卡住不报错"）。
- **P2-2 嗅探候选打分复用**：New-Tv 已有 `SniffFilter.rankCandidates`（m3u8 主列表 > mp4 > 切片），与 Duanju `_score` 同思路，确认一致即可，无需重写。
- **P2-3 线路建模收敛**：当前 `flag` + `qualityOptions` + `playUrl` 三段已覆盖 Duanju `PlaybackPlan` 的 route/session/url；可补一个显式 `PlaybackPlan`-like 结构把"当前线路/候选/会话"聚拢，便于 P1-2 统一驱动。

---

## 4. 对照表（准确版）

| 能力 | Duanju | New-Tv 现状 | 差距 |
|---|---|---|---|
| 解析循环全试 | 原生库内串行全试，首个成功即返回 | `ParseService` **并发**全试 + "自动"模式遍历全部 + 缓存/探针/误判防护 | **已超越**（仅手选单线失败没回退，见 P1-1） |
| 失败恢复 | 两层：同线重解→自动换线（max 6） | 仅 flag 内候选自动顺延；**失败不自动切源内其它线路** | 缺跨线路自动恢复（P1-2） |
| 错误展示 | 5 类分类 + 建议 + 是否建议换线 | 裸 `errorMessage`，无分类 | 缺分类（P1-3） |
| 嗅探机制 | JS 探针 + 候选列表 + 播放推荐地址（单 WebView，无跨域兜底） | JS 探针 + 候选列表 + 后台嗅探 + **跨域 HTTP 兜底** + 主文档失败重试 | New-Tv 更全面（可见性 P0 已补） |
| 线路建模 | `PlaybackPlan(route/session/hasAlternative)` | `flag` + `qualityOptions` + `playbackSessionId` | 基本覆盖，可收敛（P2-3） |
| 竞态防护 | `_generation` 代际取消 | `_spiderResolveToken` 等多处代际号 | **已有**（命名不同） |
| 卡顿检测 | `PlaybackHealth` 20s 卡顿→恢复 | 仅 15s 地址获取超时硬兜底 | 缺主动卡顿检测（P2-1） |
| 解析接口管理 | `parseApis` 列表 + 启用态 | `ParseStore`（多线路 + 自动 + 内置兜底） | 两者都有 |

---

## 5. 本轮已落地改动（P0 摘要）

| 文件 | 改动 |
|---|---|
| `lib/pages/detail/view.dart` | ① 错误态提前到 url 分支之前（修黑屏吞错误）；② 加载态显示阶段文案 + 常驻「嗅/解/换线路」；③ 新增 `_withSniffOverlay` 在网页兜底上方显示「正在嗅探视频地址…」+ 换线路 |
| `lib/pages/detail/controller.dart` | 新增 `isWebSniffing` 状态位；嗅探命中时复位 |
| `lib/pages/play/webview_player_page.dart` | **删除** `if(!sniffEnabled) return` 使网页兜底无条件后台嗅探（修"停在网页"）；新增 `onSniffState` 回调；主文档失败显示"这个网页打不开"+重试 |
| `lib/widgets/playback_surface.dart` | 透传 `onSniffState` 到 WebviewPlayerPage |

- 状态：**尚未提交**；`flutter analyze` 对这 4 文件 **0 error / 0 warning**（全库另有历史 lint info，与本改动无关）。

---

## 6. 实施顺序

1. 先提交本轮 P0 可见性修复（已 analyze 通过）。
2. **P1-1**：在 `parseOutcome` 失败兜底里，手选单线失败时回退"自动遍历全部"（改 `controller.dart` 两处 `only:` 调用点）。
3. **P1-2**：`setPlaybackError` 失败分支接轻量 Recovery（同 flag 重解→自动切 flag），UI 复用现有换线路按钮，显示重试进度。
4. **P1-3**：包装 `errorMessage` 生成，加 `classifyPlaybackError` + `suggestRoute`，命中 source/decode/permission 自动弹换线路。
5. **P2**：按优先级补（卡顿检测 / 打分确认 / 线路建模收敛）。

---

## 7. 附：Duanju 与我方（New-Tv）架构与功能差异（回答"有哪些不一样"）

**一句话**：Duanju 是把重活（取址/解析/嗅探调度）塞进一个**编译型原生核心（FFI 动态库）**，Dart 只传 `action`+`parseApis` 拿 `PlaybackPlan`；New-Tv 是**纯 Dart**，取址/解析/嗅探/恢复/错误全在 Flutter 侧用 Dio + webview_flutter 实现，且在解析细粒度（缓存/探针/误判防护）和嗅探跨域兜底上比 Duanju 更到位。

| 维度 | Duanju(火翼) | New-Tv | 谁更优 |
|---|---|---|---|
| 内核形态 | Flutter 壳 + 编译型原生核心（`libduanju_core` via FFI） | 纯 Dart（Dio + webview_flutter） | 各有：Duanju 重活下沉原生、性能/反爬强；New-Tv 全 Dart、改起来快、跨端一致 |
| 解析"循环全试"位置 | 原生库内部（Dart 不可见） | Dart 并发全试 + 缓存/探针/误判防护 | **New-Tv**（可见、可调试、更细） |
| 解析接口管理 | `parseApis` 列表（启用态） | `ParseStore`（多线路 + 自动 + 内置兜底 + 手动增删） | **New-Tv**（用户可管、有兜底） |
| 嗅探实现 | JS 探针 + 候选页（单 WebView，**无跨域兜底**） | JS 探针 + 后台嗅探 + **HTTP 抓跨域 iframe** + 主文档失败重试 | **New-Tv**（跨域兜底更实用） |
| 源内多线路 | `route`/`routeCount`/`hasAlternative` + `selectRoute`/`fallback` | `flag`/`playUrlMap` + `selectFlag` | 等价 |
| 失败自动恢复 | 结构化 `PlaybackRecovery`：refresh→alternative（max 6） | 仅 flag 内候选顺延；**无跨线路自动恢复** | **Duanju**（New-Tv 缺 P1-2） |
| 错误分类 | 5 类 + 建议 + 自动换线 | 裸 `errorMessage` | **Duanju**（New-Tv 缺 P1-3） |
| 代际取消竞态防护 | `_generation` | `_spiderResolveToken` 等 | 等价（命名不同） |
| 卡顿检测 | `PlaybackHealth` 20s 卡顿→恢复 | 仅 15s 地址获取超时 | **Duanju**（New-Tv 缺 P2-1） |
| 内容形态识别 | 播放前按 `parse`/`jx` 声明分流 | 同样读 `parse`/`jx`，还额外处理 `novel://`/`pics://` 走阅读器 | 等价偏 New-Tv（多图文分流） |

**结论**：New-Tv 在"解析细粒度"和"嗅探跨域兜底"上已经领先，不必照搬 Duanju 的原生核心思路；真正要补的是 Duanju 那套**失败后的结构化闭环**——跨线路自动恢复（P1-2）、错误分类（P1-3）、卡顿检测（P2-1）。

---

## 8. 附：Duanju「海阔小程序」（lib/hiker_miniapp）功能与对照

### 8.1 Duanju 海阔小程序是什么

Duanju 把"海阔"做成 `lib/hiker_miniapp/`（8 个文件），实现的是**海阔/Hiker(hipy) 规则体系**——和 New-Tv 的 `lib/hiker/` 是**同一套东西**，Duanju 只做了一个轻量子集（2026-10-28 逐文件核实 `hoyittvggfh45/huoyi-source-public`）。

文件与职责：
- `hiker_miniapp_rule.dart`：解析海阔规则 JSON（支持**顶层数组批量导入**）；字段含 `title/url/col_type/find_rule/searchFind/search_url/detail_find_rule/ua/preRule` + 分类 `class_name/url`、地区/排序/年份 `area/sort/year`、分组 `group`、连载末集规则。
- `hiker_miniapp_engine.dart`：动作 `home(list)` / `search` / `detail`，统一走 `run(ruleJson, action, input)` 回调（JS 规则交给**原生/Node 后端**，Dart 只做 UI + 模型 + 调度）。
- `hiker_miniapp_home.dart`：分类 chips + 卡片网格（`col_type` 决定列数/比例）+ 分页（下一页）+ 搜索模式 + 错误重试。
- `hiker_miniapp_models.dart`：卡片/详情分块（`HikerDetailItem` 按 `col_type` 还原：识别「**播放线路：**」多线路、「**标签：**」、`本片剧照`、`text_1/long_text/rich_text`）；`HikerPlayLine` 多播放线路；`playableEpisodes` 过滤可播地址 → `onPlay` 外部播放器。
- `hiker_category_shell.dart` / `hiker_col_type.dart` / `hiker_rule_chain.dart` / `hiker_miniapp_detail.dart`：分类壳、col_type 布局/可播判定、规则链、详情页。

**功能清单**：海阔规则导入解析 · 首页+分类浏览 · 搜索 · 详情（多播放线路/标签/剧照/简介/演员）· 播放（多线路+可播过滤+外部播放器回调）· 自定义 UA/preRule · 地区·排序·年份筛选（**模型已建，引擎主路径只接了分类**）· JS 规则后端执行。

### 8.2 能力对照：New-Tv 海阔（lib/hiker） vs Duanju 海阔小程序（lib/hiker_miniapp）

| 能力 | Duanju 海阔小程序 | New-Tv 海阔（lib/hiker） | 谁更全 |
|---|---|---|---|
| 规则格式 | Hiker/hipy JSON（数组批量导入） | 同格式（`hiker_source.dart` 解析，支持 115 源批量导出） | 等价 |
| 规则执行 | Dart 调 `run()` 回调 → 原生/Node 后端 | Node 进程 `POST /hiker/run`（JS 全局 `$`/`setResult`） | 等价（都后端无关） |
| 首页 + 分类 | 分类 chips + 卡片网格 + 分页 | 同，`hiker_blocks.dart` 按 `col_type` 还原官方布局（含 `scroll_button`/`flex_button` 当分类 tab） | New-Tv 渲染更细 |
| 搜索 | 独立搜索模式 | 同 | 等价 |
| 详情分块 | col_type 分块 + 多播放线路 + 标签/剧照 | 同（`hiker_blocks.dart` 分块 + `hiker_richtext.dart` 富文本） | New-Tv 更细 |
| 多播放线路 | `HikerPlayLine` | `flag`/`playUrlMap`（源内多线路） | 等价 |
| **本地缓存** | 无 | `hiker_cache.dart`（首页/分类结果缓存，省重复十几秒抓页） | **New-Tv** |
| **内置源** | 无（规则全靠导入） | `hiker_builtin.dart`（随包分发内置源 + 资源目录） | **New-Tv** |
| **文件区/规则包** | 无 | `hiker_files.dart`（Apollo 规则包放 `Documents/hiker/files`） | **New-Tv** |
| **设置/源管理页** | 无（引擎层无 UI） | `hiker_settings_page` / `hiker_manage_page`（导入/分组/说明） | **New-Tv** |
| 筛选（地区/排序/年份） | 模型已建，引擎主路径未接 | 视具体源规则自身 | 持平（都靠规则） |
| 规则链 | `hiker_rule_chain.dart` | `hiker_route.dart` / `hiker_store.dart` | 各实现一套 |

**结论**：Duanju 的"海阔小程序"是海阔/Hiker 规则体系的**轻量子集**（核心浏览/搜索/详情/多线路播放齐全），New-Tv 的 `lib/hiker` 是**超集**（多了缓存、内置源、文件区、设置/管理页、更细的 col_type 分块渲染）。两者核心能力等价——**New-Tv 不必从 Duanju 借鉴海阔模块**，反而 New-Tv 的 hiker 更完整。

### 8.3 回到"海阔能否纳入海阔分类"

- Duanju 把海阔做成单一 `hiker_miniapp` 模块；New-Tv 的 `lib/hiker` 即"海阔"模块本身——**两者本就是同一模块**，不存在"纳入"。
- New-Tv 另有一个**独立** `lib/miniapp`（ant 小程序平台：web 页面 + 自带 Node 后端 + `manifest.json`），**与海阔不是一套格式/引擎**。
- 所以真正可考虑合并的是「海阔」与「程序」两个主页入口；但两者引擎/格式不同，**硬合并价值不大**。若想精简主页 tab，更合理是把"程序"入口收进某个分类，而不是动海阔。
