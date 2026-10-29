# 短剧模块深度复核（2026-10-29）

范围：`lib/pages/drama/` 全部 10 个文件（≈5300 行）+ 依赖 `DetailController`、`DramaSettings`、`card_action_sheet`。
方法：逐文件通读 + 关键路径交叉核对（分类扫描 → 列表分页 → 缓存兜底 → 播放页取址/切集 → 历史落盘）。
结论：**没有编译级/必崩问题**；但有 1 处功能性死路、5 处健壮性/竞态隐患、若干体验细节。以下按严重度列出。

---

## P0 — 功能性死路（用户会卡住）

### P0-1 播放页「重试」在详情加载失败时是空操作
- 位置：`drama_player_page.dart:1120`（`_statusLayer` 的「重试」→ `_c.selectEpisode(_index)`）；`_boot()` 在 `drama_player_page.dart:148` 遇到 `currentEpisodes.isEmpty` 直接 return。
- 现象：详情接口失败 / 源返回空剧集时，页面显示错误，但点「重试」无效——`selectEpisode` 内 `index >= episodes.length` 直接 return（`controller.dart` 的 `selectEpisode` 早退）。
- 修法：抽一个 `_retry()`：`if (_c.currentEpisodes.isEmpty) { _boot(); } else { _c.selectEpisode(_index); }`。`loadDetail` 开头会 `errorMessage.value = null`（`controller.dart:446`），所以重跑 `_boot` 能清错并重新拉详情。

---

## P1 — 健壮性 / 竞态

### P1-1 分页无上限、无去重，坏源会无限追加
- 位置：`view.dart:445` `_hasMore = list.isNotEmpty;`；`_loadPage`（`view.dart:421-492`）直接 `_videos.addAll(list)`。
- 现象：部分 MacCMS 站忽略 `page` 参数，任何页都返回同一批 → `_hasMore` 永远为真，滚动不断追加重复卡片，内存持续涨。
- 修法：追加时按 `id` 去重；若整页都是已存在条目或超过页数上限（如 50）则置 `_hasMore=false`。

### P1-2 分类切换 / 滚动加载 / 刷新存在多请求竞态
- 位置：chip 点击 `view.dart:744` 调 `_loadPage(1)`（不带 `gen`）；`_onScroll`（`view.dart:124`）调 `_loadPage(_page+1)`（不带 `gen`）；`_loadPage` 在 await 前捕获 `g = _groups[_groupIdx]`，await 期间用户换分类/换源，结果仍写回 `_videos`。
- 现象：快速切分类或切源时，慢请求后到会把新分类的列表盖成旧分类的内容。
- 修法：`_loadPage` 增加列表代次（如 `_listGen`），每次切换分类/换源自增；setState 前校验代次；chip 与滚动加载都传当前代次。

### P1-3 刷新失败回落缓存时，chip 与列表可能不一致
- 位置：`view.dart:365-394` `_showCacheFallback`。
- 现象：它把 `_groupIdx` 改成缓存里记录的下标，但当 `_videos` 非空时**不重新加载**（`if (_videos.isEmpty) await _loadPage(...)`）→ 高亮的分类 chip 与下方列表不是同一组。
- 修法：回落后若 `_groupIdx` 变了，强制用缓存里该分类的列表（`cachedList`/`anyCachedList`）刷新 `_videos`。

### P1-4 列表缓存读-改-写无并发保护
- 位置：`drama_settings.dart:244-262` `saveList`（整张 `_kListCache` 读出→改→写回）。
- 现象：两个 `saveList` 并发（换分类/换源快速操作）会互相覆盖，丢掉其中一条缓存，导致下次兜底缺内容。
- 修法：内存里维护一份缓存 Map + 单条写队列（串行 flush），避免并发读改写。

### P1-5 切集不清旧错误/超时提示
- 位置：`_switchTo`（`drama_player_page.dart:347-361`）与 `_armWaitTimeout`（`:251-262`）都不清 `_timeoutHint`；`selectEpisode` 也不清 `errorMessage`。
- 现象：上一集报错/超时后切下一集，新集加载那几秒会闪出上一次的错误文案，看起来像"又失败了"。
- 修法：`_switchTo`/`_armWaitTimeout` 里清 `_timeoutHint`；切换后 `_c.errorMessage.value = null`。

---

## P2 — 体验 / 细节

### P2-1 倍速标签 1.0/2.0 显示成 "1.0x"/"2.0x"
- 位置：`drama_player_page.dart:921-925` `_speedLabel`（`toStringAsFixed(2)` 后只剥一个尾零："1.00"→"1.0"）。
- 修法：整数判断直接返回整数串，或用正则 `0+$` 去尾零。

### P2-2 轮播初始圆点可能与实际页错位
- 位置：`drama_banner.dart:38` `initialPage: 400`、`:42` `_index = 0`、`:93` `i % n`。
- 现象：`n` 不整除 400 时（如 n=3、6），首屏显示的是 `items[400%n]`，但圆点高亮第 0 个。
- 修法：初始化 `_index = 400 % n`（在 `initState`/`didUpdateWidget` 里按 n 校准）。

### P2-3 短剧页换内核会改掉全局默认
- 位置：`drama_player_page.dart:1035` `PlayerPrefs.instance.vodEngine.value = picked;`。
- 现象：在短剧播放页选内核，等于改了全 App 的默认播放内核（可能是有意，但值得确认）。
- 建议：若非有意，改为页面级临时覆盖，退出短剧页还原。

### P2-4 `_autoRescanned` 只在换源时清除
- 位置：`view.dart:77`（字段）、`:543`（仅 `_pickSource` 清除）。
- 现象：某源首次进页面分类失效被自动重扫一次后，若之后站点恢复，也不会再自动重扫（除非手动换源/下拉）。
- 建议：成功拿到列表时 `_autoRescanned.remove(source.key)`。

### P2-5 `resolveCurrentSource` 可能回退到白名单外的源
- 位置：`drama_settings.dart:137-138`。
- 现象：白名单非空但勾选的源全部不可用（被删/停用）时，回退到 `homeSource`，而它可能不在白名单，与"只显示勾选源"的规则不一致。
- 建议：回退前校验 `homeSource` 是否在白名单内。

### P2-6 搜索页 `_total` 在 setState 外赋值
- 位置：`drama_search_page.dart:89` `_total = targets.length;`。
- 现象：首屏进度文案可能晚一拍更新（功能无碍）。
- 建议：并入紧邻的 setState。

---

## 已确认"不是问题"的点（避免误改）

- **源面板长按「用这个」**：`showCardActions` 是先关自身面板再执行 `onTap`（`card_action_sheet.dart:96/106`），所以 `Navigator.pop(context, s)` 正确弹掉的是源面板并回传选中源——不是 bug。
- **短剧页独立 `DetailController`（手动 `onInit/onClose`）**：`onInit` 只做 `loadSkipDurations` / `_loadNonVideoSources` / `addObserver`（`controller.dart:326-334`），不依赖 Get 容器，手动实例化安全。
- **`_syncPageTo` 多次尝试跳页**：`_index` 先于跳页更新，`onPageChanged` 命中 `i == _index` 会早退，不会二次 `selectEpisode`。
