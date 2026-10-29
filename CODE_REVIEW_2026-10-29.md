# 猫影 TVBox 代码复核（2026-10-29 · 第四轮 · 工作区未提交改动）

> 复核对象：`E:\Dev\New-Tv` 当前工作区（HEAD = `8d889d0 feat(play): 影视模块移除 WebView 内核与网页内嵌播放`）
> 范围：14 个已跟踪文件的改动 + 3 个未跟踪新文件 + 基线回归
> 方法：逐条读 diff → `flutter analyze` → `flutter test` → 交叉验证调用点（详见 §六）

---

## 一、总体结论

本轮工作区是一批**界面收敛型改动**（图标统一、菜单瘦身、说明文字收纳、播放判定放宽），方向没问题、注释写得比代码还清楚。但树里躺着**三处"半成品"**，其中一处会让静态分析直接红掉：

| 级别 | 数量 | 摘要 |
|---|---|---|
| **P0** | 1 | `lib/services/local_js_sources.dart` **语法错误，19 条 error**；且整份文件是孤儿代码，与上一个提交"彻底移除本地 JS 源导入"直接冲突 |
| **P1** | 1 | `flutter test` 由基线 661/661 变成 **630 通过 / 3 失败**（桌宠物种测试与实现脱节） |
| **P2** | 2 | 新写的 `SettingsHelp` 组件 **0 个调用点**（136 行死代码）；`cf_sites_page` 又自造了第三套"说明"交互 |
| **P3** | 4 | 远程引擎卡片双重内边距、海阔图标只换了首页没换设置页、仓库杂物、`local_js` 内部三处小缺陷 |

**没有发现会导致崩溃或数据损坏的缺陷。** `trustMedia` 这处放宽播放判定的改动我按最坏路径推演过（§三·4），结论是安全：真正的网页地址仍会走 `setPlaybackError` 的自动顺延，只是失败反馈慢一点。

---

## 二、验证结果（对比 2026-10-26 基线）

| 指标 | 2026-10-26 基线 | 现在 | 判定 |
|---|---|---|---|
| `flutter analyze lib` | 0 error / 0 warning / 1,663 info | **19 error** / **2 warning** / 1,489 info | ❌ 回归 |
| `flutter test` | 661 / 661 | **630 通过 / 3 失败**（共 633 条） | ❌ 回归 |

> **整改后（2026-10-29 20:55）**：`flutter analyze lib test` → **0 error / 0 warning**（1,560 info）；`flutter test` → **634 / 634 全部通过**。整改明细见 §七。

- 19 条 error **全部**来自 `lib/services/local_js_sources.dart:42`（一个错误的 raw string），属于单点根因。
- 2 条 warning 是 `8d889d0` 移除 WebView 内核的遗留：
  - `lib/miniapp/services/mini_app_service.dart:12` — `unused_import: models/app_config.dart`
  - `lib/pages/detail/view.dart:1118` — `final engine = PlayerPrefs.instance.vodEngine.value;` 已无人使用
- info 从 1,663 降到 1,489，是删代码带来的自然下降，不是质量提升。

> ⚠️ 环境提示：本机 shell 里 `HTTP_PROXY/HTTPS_PROXY` 指向 `127.0.0.1:56513`，会让 `flutter_tester` 的 WebSocket 升级失败，表现为**86 个测试文件全部 "Failed to load"**。这不是代码问题。跑测试要绕开代理：
> `env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY flutter test --no-pub`

---

## 三、问题清单

### 3.1 P0 —— `local_js_sources.dart` 无法编译，且是"复活"的死代码

**事实**：`lib/services/local_js_sources.dart:42`

```dart
final RegExp _reJsStandaloneServer = RegExp(
  r'http\.createServer|express\s*\(|require\([\'"]http[\'"]\)|Fastify\s*\(|createServer',
);
```

raw string（`r'…'`）里**反斜杠不转义**，所以 `\'` 中的 `'` 直接终止了字符串 → 后续整行被当成代码 → 19 条 error 连锁。修法（二选一）：

```dart
// A. 用三引号 raw string，内部可以安全放单双引号
r'''http\.createServer|express\s*\(|require\(['"]http['"]\)|Fastify\s*\(|createServer'''

// B. 改成普通字符串 + 双转义
'http\\.createServer|express\\s*\\(|require\\([\'"]http[\'"]\\)|Fastify\\s*\\(|createServer'
```

**更关键的是它为什么在这儿**：这两个文件（`models/local_js_source.dart` 69 行 + `services/local_js_sources.dart` 572 行）在 `c23852d refactor: 彻底移除嗅探/解析与本地JS源导入` 里被**删除过**，现在又以未跟踪状态出现在工作区，而全仓 `lib/` 里**没有任何一处引用它们**：

```
grep -rn "local_js_source|LocalJsSource|localJsSource" lib/   →  0 命中（除这两个文件自身）
```

也就是说：`SpiderService` 侧对 `ljs_*.js` 的解析仍在（`spider_service.dart:909` 一带），但**导入/管理/UI 入口一个都没有**。这套代码现在既不能编译、也没有入口，属于纯负担。

**建议（需你拍板）**：
- 若"本地 JS 源"确定不做 → `git clean` 掉这两个文件，并顺手删掉 `spider_service` 里那段只剩半边的 `ljs_` 处理；
- 若要恢复这个功能 → 先修 §3.1 的语法错误，再补 UI 入口（源面板「本地 JS」组 + 导入菜单），否则下次谁 import 它谁炸。

顺带：这份"复活"的文件里还留着三处真实缺陷（见 §3.7），说明它是从旧版本整段搬回来的，不是重写。

---

### 3.2 P1 —— 3 条桌宠测试红：测试没跟上 `aaa9588` 的实现改动

`test/pet_species_test.dart` 仍在断言 `qq_boy / qq_girl / qq_scholar` 三款 QQ 秀桌宠、以及"内置插画 10 款"；而 `lib/reading/pet/pet_models.dart:108` 起已换成 `chibi_panda / chibi_boy / chibi_girl` + 十二生肖 + `cat` + `custom`，带图物种变成 **13** 款，兜底物种从 `qq_boy` 变成 `chibi_panda`。

```
桌宠 / 头像物种 必须包含十二生肖与 QQ 秀三款桌宠      → 缺少物种 qq_boy
桌宠 / 头像物种 byId 未命中时回退到默认桌宠（小Q）    → Expected 'qq_boy' / Actual 'chibi_panda'
桌宠 / 头像物种 内置插画 10 款且素材文件真实存在      → Expected 10 / Actual 13
```

实现侧是**有意**改的（`aaa9588 feat(pet): 桌宠只留熊猫/少年/少女三张透明素材`，且 `pet_service.dart:143` 已写了 `qq_boy` 旧 id 的存档迁移），所以该改的是测试：把期望列表换成 `chibi_*`、数量 10→13、兜底 `chibi_panda`。测试文件里的注释（"2026-10-26 更新：兜底物种从 cat 改成了 qq_boy"）也要一并更新，否则下轮复核还会被它误导。

---

### 3.3 P2 —— `SettingsHelp` 写好了但没人用，`cf_sites_page` 又自造第三套交互

你的要求（本轮 `settings_shared.dart:387` 注释里记着）是"卡片里的小字说明别铺在卡片下，改成右上角 ? 图标点开看"。于是新增了 `SettingsHelp` + `SettingsHelpItem` + `SettingsSubPage.help`（136 行）。

但全仓**没有任何一个页面传 `help:`**：

```
grep -rn "SettingsHelp" lib/ | grep -v settings_shared.dart   →  0 命中
```

与此同时 `cf_sites_page.dart:32` 走了另一条路：删掉了卡片里的说明文字，改成 `initState` 里 `addPostFrameCallback` 弹一个**只弹一次**的居中弹窗（`cf_sites_hint_shown_v1`）。结果是同一个 App 里现在并存三套"解释性文案"的呈现方式：

1. `SettingsRow.subtitle`（卡片下方灰字，老的）
2. 一次性居中弹窗（`cf_sites_page`，新的）
3. 右上角 ? → 说明列表（`SettingsHelp`，新的但没人用）

更实际的问题：**一次性弹窗关掉就再也找不回来**。用户在 Cloudflare 页看到 403 时，恰恰是最需要重读那段说明的时候，而那时它已经不会再弹了。按你自己定的规则，这里应该换成 `SettingsSubPage(help: [...])`。

**建议**：`cf_sites_page` 改回"右上角 ? + 常驻可查"，一次性弹窗删掉；然后把 `SettingsHelp` 接到实际页面（数据源、阅读、缓存、播放器等设置子页都适合），否则这 136 行就是下一轮的死代码。

---

### 3.4 P2 —— `trustMedia`：行为正确，但"网页地址"的失败反馈退化了

`play_pipeline.dart:96` 新增的短路分支：

```dart
if (trustMedia && isPlayableShape(candidate) && !_isWebPage(candidate)) {
  return PlayResolution(url: candidate, kind: PlayKind.media, headers: h);
}
```

判定只看"路径是否以 `.html/.htm/.php/.asp/.aspx/.jsp/.shtml` 结尾"。我按最坏情况推了一遍：**安全**，但有一个体验代价。

- 真正的网页地址若**带**这些后缀（`…/vodplay/223052-1-1.html`）→ 仍判 `page` → 立刻 `setPlaybackError(kMovieWebUrlRejected)` → 自动顺延候选/换线路。✅
- 真正的网页地址若**不带**后缀（`…/vodplay/123-1-1/`、`…/?m=vod-play-id-123`）→ 被当媒体丢给播放器 → **白等一次播放器超时**（实测量级 15s）才触发 `setPlaybackError` 顺延。功能不丢（`setPlaybackError:602` 的顺延链仍在），但用户会多等十几秒，且最终文案变成播放器超时，而不是"这是网页不是直链"。

**建议（低成本）**：播放器报错时，如果当前 URL `!looksLikeDirectMedia(url)`，在错误文案后追加一句"该地址可能仍是网页而非视频直链，建议换线路"。这样既不收紧 `trustMedia`（不误杀 token 直链），又把信息补回来。

> **已实现（2026-10-29 21:02，用户同意）**：`detail/controller.dart` 新增 `_spiderTrustedMedia` 标记（Spider 分支按 `resolution.isMedia` 置位，普通 CMS 链路在 `_startPlayback` 复位）+ `_withPageHint()`：报错时若当前地址是 http(s) 且 `!looksLikeDirectMedia()`，在文案后补一行「（这个地址可能仍是网页而不是直链，建议换线路）」。三处刻意不加：非 http(s) 协议、已是 `.m3u8/.mp4`、以及本来就走"网页地址被拒"那条文案。
> 附带处理：`classifyPlaybackError()` 先剥掉这句提示再分类 —— 否则提示里的「地址」二字会把所有播放失败都归成「地址无效」。

---

### 3.5 P3 —— 远程引擎卡片：想"对齐 SettingsRow"，实际多缩进了 14px

`data_source_settings_page.dart:114` 把 `_remoteCard` 从 `AppCard(child: Padding(...))` 改成裸 `Padding(EdgeInsets.fromLTRB(14, 10, 10, 12), child: Column(...))`，调用处 `:350` 是 `_card(_remoteCard())`。

而 `_card` 内部是 `AppCard(dense: true)`，dense 自带 `EdgeInsets.symmetric(horizontal: 12, vertical: 4)`（`common_widgets.dart:330`）。`SettingsRow` 自身**不带**内边距。所以：

- 其它行：左内边距 **12**
- 远程引擎卡片：左内边距 **12 + 14 = 26**

比同级卡片多缩进 14px，恰是这次改动想消除的"和别的卡片不一样"。建议把 `_remoteCard` 的 `Padding` 去掉，直接返回 `Column`（需要的话只保留 `SizedBox(height:)` 做段间距）。

### 3.6 P3 —— 海阔图标：导航侧一致，但「海阔设置」入口还是火箭（**本节已按更正后的结论修复**）

`nav_feature_service.dart` 加了 `NavFeature.hiker => assets/icons/hiker.png`（彩色启动图、不着色），`HikerLogo` 也换成了这张图（512×512，`BoxFit.contain`，尺寸正确）。

> **更正**：本节初稿说「`home_pages_settings_page.dart:26` 仍用火箭」是**看错了** —— 那个 `_iconOf` 只是 `iconAsset == null` 时的兜底（`:601` 起先判 `f.iconAsset != null` 画图），海阔/REX 在那里已经是彩色图。真正还留着火箭的是总设置页的分类入口 `settings/view.dart:175`（「海阔设置」磁贴）。

已改：`_categoryTile` 增加可选 `iconAsset`，海阔入口传 `assets/icons/hiker.png`，与首页/底栏一致。（`cache_settings_page`、`general_settings_page` 里的 `rocket_launch` 是「缓存模块」图标，与品牌无关，保留。）

### 3.7 P3 —— `local_js_sources.dart` 内部三处缺陷（若决定保留该功能才需要修）

| 位置 | 问题 |
|---|---|
| `:471` `rename()` | 重建 `LocalJsSource` 时**漏传 `usage`** → 改个名字把使用次数清零（「频率」排序会跳） |
| `:546` `bumpUsage()` | 没有 `await load()`，`_sources` 未加载时静默 no-op |
| `:495` `clearAll()` | 循环调 `remove()`，每条都 `_save()` 一次 → N 次写盘；应批量后落一次 |

### 3.8 P3 —— 仓库卫生

- `analyze_check.txt`（今天 15:57 生成的临时分析输出）**已被 git 跟踪**，应删除并加进 `.gitignore`；
- `_crop_cord.png` / `_crop_me_top.png` 两张截图素材也被跟踪，留在根目录；
- `docs/` 整个目录在工作区被删空（`docs/drama-module-review-2026-10-29.md`、`docs/duanju-playback-borrow-plan.md`）——如果是误删，`git checkout -- docs/` 即可恢复；如果是有意清理，建议单独一个 commit，别混在 UI 改动里。

---

## 四、建议动作顺序

1. **立刻**：修 `local_js_sources.dart:42` 的 raw string（或直接删掉这两个孤儿文件，二选一），让 `analyze` 回到 0 error。
2. **立刻**：更新 `test/pet_species_test.dart` 到 `chibi_*` 物种体系，让 `test` 回到全绿。
3. **顺手**：清掉 `detail/view.dart:1118` 的 `engine` 和 `mini_app_service.dart:12` 的 import，回到 0 warning。
4. **本轮收尾前**：决定 `SettingsHelp` 是"接上去"还是"删掉"；`cf_sites_page` 的一次性弹窗换成 ? 常驻说明。
5. **有空**：`_remoteCard` 去掉多余 `Padding`；`_iconOf` 改用 `iconAsset`；仓库杂物清理。

---

## 五、做得好的地方（本轮）

- `play_pipeline.dart` 的注释把"为什么放宽"和"放宽到哪为止"都写清楚了（`_isWebPage` 白名单留了逃生口），比单纯加个 `if` 强很多；
- `rex_market_page` 把 4 个 `ListTile` 换成统一 `_buildImportMenuItem`，顺手统一了圆角/阴影/高度，属于正确的收敛方向；
- `reading_settings_page` 把"2026-10-15 加符号"的旧决定**显式标注为被覆盖**，这种"改动留痕"的习惯值得保持；
- `settings_shared.dart` 里 `SettingsHelp` 的组件设计本身是好的（可传 icon/title/body 列表、统一 AlertDialog 风格），只是没接上。

---

## 六、复核方法（可复现）

```bash
cd E:/Dev/New-Tv

# 1. 改动范围
git status --short && git diff --stat

# 2. 静态分析（区分 error / warning / info）
flutter analyze --no-pub lib | grep -E "^\s*(error|warning)"
flutter analyze --no-pub lib | grep -cE "^\s*info"

# 3. 单元测试（必须绕开本机代理，否则 flutter_tester 全部 load 失败）
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY flutter test --no-pub

# 4. 死代码核对
grep -rn "LocalJsSource\|localJsSource" lib/ | grep -v "lib/models/local_js_source.dart\|lib/services/local_js_sources.dart"
grep -rn "SettingsHelp" lib/ | grep -v settings_shared.dart
```

---

## 七、整改记录（2026-10-29 20:50–20:55，本轮已落地）

| # | 问题 | 处理 |
|---|---|---|
| 1 | P0 `local_js_sources.dart:42` 语法错误 + 孤儿代码 | **删除** `lib/services/local_js_sources.dart`、`lib/models/local_js_source.dart`（与 `c23852d`「彻底移除本地 JS 源导入」一致）。文件仍可从 `65d7e65` 取回；`nodejs_platform_ios._resolveLocalJsPath` **保留**（老订阅里若还写着 `ljs_xxx.js`，按需解析仍可用） |
| 2 | P1 3 条桌宠测试红 | 重写 `test/pet_species_test.dart`：图鉴只断言三只 `chibi_*`、插画 10→13、兜底 `qq_boy`→`chibi_panda`，并补 `byId('qq_boy')` 旧 id 回落断言 |
| 3 | P2 `SettingsHelp` 0 调用点 | 接到两处：`cf_sites_page`（右上角 ? 常驻可查，删掉"只弹一次"的居中弹窗与 `cf_sites_hint_shown_v1` 标志）、`data_source_settings_page`（`SettingsSubPage.help`，5 条说明） |
| 4 | P3 远程引擎卡片双重内边距 | 去掉 `_remoteCard` 外层 `Padding(14,10,10,12)`：左缩进 26 → 12，与同级 `SettingsRow` 对齐 |
| 5 | P3 海阔图标 | 总设置「海阔设置」入口改用 `assets/icons/hiker.png`（`_categoryTile` 新增可选 `iconAsset`） |
| 6 | 2 条 warning | 删 `detail/view.dart` 里没人用的 `engine` 局部变量；删 `mini_app_service.dart` 未使用的 `models/app_config.dart` import |
| 7 | 仓库卫生 | `analyze_check.txt` 取消跟踪 + 写进 `.gitignore`；`docs/` 两个被删空的复核文档已 `git checkout` 恢复 |
| 8 | 过时注释 | `api_config.dart:388 / 1582` 里「本地 JS 源子开关」改为「本地爬虫总开关」，并注明 JS 源已随 `c23852d` 移除 |
| 9 | §3.4 `trustMedia` 失败反馈（21:02 追加） | `detail/controller.dart` 加 `_spiderTrustedMedia` 标记 + `_withPageHint()`：无直链特征的地址播放失败时补一句「可能仍是网页」；`classifyPlaybackError` 会先剥掉这句再分类 |

**验证**：`flutter analyze lib test` → 0 error / 0 warning（1,560 info）；`flutter test` → **634 / 634 全部通过**。

**未处理（有意保留）**：

- §3.7 `local_js` 内部三处缺陷（文件已删，随功能一起消失）；
- `_crop_cord.png` / `_crop_me_top.png` 仍在根目录且被跟踪（疑似设计参考图，未替你删）。

**顺手发现（未改，提醒）**：`.gitignore` 里有一条 `test*`，会把**新增**的 `test/` 文件一并忽略（已跟踪的照常）。以后新增测试文件需要 `git add -f`，或把这条规则写精确。
