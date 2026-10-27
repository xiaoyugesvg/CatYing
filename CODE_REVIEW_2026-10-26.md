# 猫影 TVBox 代码复核报告（2026-10-26 · 重构版）

> **复核对象**：`New-Tv`（Flutter 跨平台 TVBox 播放器）
> **复核时间**：2026-10-26
> **代码规模**：**568** 个 Dart 文件 / **311,857** 行
> **静态分析**：`dart analyze lib` → **0 error / 0 warning / 1,663 info**（`lib` + `test/` 合计 **1,744**）
> **单元测试**：`flutter test` → **659 / 659 全部通过**
>
> **本版说明（重构）**
> ① 已修复的条目不再作为"问题"罗列，统一收进 §六「已完成的整改」仅作追溯；
> ② 新增 §三「本轮新发现的问题」——用自研扫描器 + 人工逐行核实做了系统性深挖；
> ③ 新增 §四「深挖已排除的项」——记录**查过并确认没问题**的地方，避免重复排查；
> ④ **更正上一版的两处错误结论**：附录里"637 通过 / 8 失败"已过期（实测 645 全过，现 659 全过）；"0 warning"也不成立（拆分实际引入了 149 条，本轮已修，见 N0）；
> ⑤ **§3.1 的 4 处 P2 缺陷已全部修复并回归验证**（详见各条末尾「修复记录」），当前**无未修的 P2**。

---

## 一、总体结论

这是一个**工程纪律明显强于同类项目**的代码库：静态分析零 error 零 warning、lint 规则比 `flutter_lints` 默认严格得多、关键基础设施（日志、DNS、桥接权限、prefs 镜像）都针对真实踩过的坑做过设计。

上一版报告指出的结构性债务（15,858 行巨型文件、明文密钥、空 catch 吞异常）**已经处理完毕**。因此本轮复核的重点转向**更深层的系统级缺陷**：资源生命周期、跨平台行为、文件名/路径边界、死代码。

**深挖结论：没有发现会导致崩溃或数据损坏的严重缺陷。** 但找到 **1 处由我们自己的拆分引入的回归（已修）**、**4 处真实缺陷（P2，已全部修复）**、**4 处规范/隐患（P3，仍开着）**。

其中两处属于"**同一个仓库里别的模块做对了、只有这一处漏了**"的不一致型缺陷（N2、N3）——修法有现成参照，成本极低、风险极小，本轮已按参照实现补齐。

> **当前状态**：P2 已清零（4/4 修复，`dart analyze` 0 error / 0 warning，`flutter test` 659/659 回归通过）；剩余待办只有 §3.2 的 3 处 P3（N5/N6/N8），以及 §五 中按你决策保留的项。
>
> **P3 需要区别对待（2026-10-27 复核影响面后）**：N7 已修；剩余三项中 **只有 N8（健康检查并发 12）有真实用户可见后果**——超时被误判会导致可用源被自动停用；N5/N6 的实际影响约等于零（父控制器已释放、订阅已 cancel），属规范项；N7 是"Hive 没有 PrefsMirror 那样的兜底"的设计不对称。

---

## 二、当前基线

| 指标 | 数值 | 说明 |
|---|---|---|
| Dart 文件 | 568 | 含 P0.1 拆分新增的 7 个 part |
| 代码行数 | 311,857 | — |
| `dart analyze lib` | **0 error / 0 warning / 1,663 info** | info 全部为 lint 建议 |
| `flutter test` | **659 / 659 通过** | 0 失败（新增 14 条：音乐订阅迁移 7 + CacheStore 生命周期 7） |
| 启用 lint | 40+ 条 | 含 `cancel_subscriptions`、`avoid_slow_async_io`、`always_use_package_imports` 等 |

**规模分布**（行）：

| 模块 | 行数 | 占比 |
|---|---|---|
| `reading/` | 150,778 | 48.3% |
| `pages/` | 46,461 | 14.9% |
| `music/` | 27,920 | 9.0% |
| `services/` | 24,070 | 7.7% |
| `widgets/` | 15,650 | 5.0% |
| `hiker/` | 10,396 | 3.3% |
| 其余 9 个目录 | ~36,582 | 11.8% |

---

## 三、本轮新发现的问题

### 3.0 P2｜拆分引入 149 条分析器 warning（**本轮已修**）

**这是上一版报告的错误来源。** 上一版声称 P0.1 拆分后 `dart analyze` 仍是"0 error / 0 warning"，但本轮全量复测发现 **149 条 warning**，且全部集中在同一个文件：

```
149 条，全部位于 reading/pages/book_source_reader_page.dart
  ├─ 130 × unused_element
  └─  19 × unused_element_parameter
```

**根因**（拆分方案的固有代价，不是死代码）

P0.1 采用"顺序无关"方案：基类 `_BookSourceReaderPageState` 保留全部 269 个抽象方法签名，方法体分散在 7 个 `mixin _ReaderPartNN on _BookSourceReaderPageState` 里。

当一个方法**只被它自己所在的那个 mixin 调用**时，该调用点解析到的是 **mixin 自己的实现**，基类那份抽象声明就再没有任何引用点 → 分析器判定"未被引用"。跨 part 调用（A 调 B 里的方法）不受影响，因为 A 里没有 B 的实现，只能解析到基类声明。

**为什么上一版会误判**：拆分后第一次跑分析时命中冷缓存，第二次运行时 part 文件已全部链接、`unused_element` 未复现，于是被当成"冷缓存假象"记了下来。**这个判断是错的**——警告是稳定存在的。

**修法**（已应用，零行为变更）

在 `book_source_reader_page.dart` 顶部加文件级豁免 + 说明：

```dart
// ⚠️ 本文件的 269 个抽象方法声明是「跨 part 调用」的类型契约，不是死代码。
//    方法体已按 P0.1 拆到 reader_parts/ 下 7 个 mixin 里；基类必须保留全部
//    签名，任意 part 才能调用任意方法（顺序无关）。副作用：若某方法只被
//    「它自己所在的 mixin」调用，分析器会判定基类声明未被引用 → 报
//    unused_element / unused_element_parameter。逐条删除会破坏跨 part 调用，
//    故统一豁免。
// ignore_for_file: unused_element, unused_element_parameter
```

**修复后实测**：`0 error / 0 warning / 1,664 info`（本轮再删除 N4 死链后为 **1,663**，少的那条是加载页被删掉的双下划线 lambda）。

> 遗留提醒：这个豁免会一并掩盖该文件里**将来**真正产生的 `unused_element`。因为该文件现在只剩"声明 + 2 个小类"，风险可接受；若以后往里加业务代码，建议改为逐条 `// ignore:`。

**能否不要豁免？（2026-10-27 用探针实测过三种写法）**

| 写法 | 结果 |
|---|---|
| 现在：签名放基类 + `// ignore_for_file` | 0 条 warning；盲区 = 该文件全部 |
| 把 269 个签名挪进独立 `abstract class _ReaderApi`，基类 `implements _ReaderApi` | **仍然 0 条 warning，但探针证明它连"真·死代码"也一并放过**（声明在接口、实现在 mixin、全仓无人调用的方法不会被报）→ 只是换个姿势的 ignore，**换不来精度** |
| 逐条 `// ignore: unused_element` | 能真正缩小盲区到"只有这 269 个签名"，代价 149 行注释，且重新拆分时必须重新生成 |

结论：**保持现状**。补充两点事实 —— ① `ignore_for_file` 不跨 `part`，7 个 part 文件**没有**豁免，它们的死代码照常会被报；② 该文件现在只剩 import、`part` 指令、2 个小类和 269 个纯签名，往里加业务代码的概率很低。


---

### 3.1 P2 —— 真实缺陷（**4 处已全部修复**，保留成因分析供追溯）

#### N1｜阅读器两个 `TextEditingController` 永不释放 ✅

**位置**
- 声明：`lib/reading/pages/book_source_reader_page.dart:513`、`:516`
- `dispose()`：`lib/reading/pages/reader_parts/reader_part_01.dart:574-613`

```dart
// book_source_reader_page.dart:513
final TextEditingController _ttsNarratorCtl = TextEditingController();
// :516
final TextEditingController _ttsDialogueCtl = TextEditingController();
```

`dispose()` 里释放了 `_scrollReadCtrl`（:587）和 `_pageCtrl`（:612），**唯独漏了这两个**。全仓 `grep` 确认**没有任何一处**调用它们的 `.dispose()`。

**影响**
每进出阅读器一次泄漏 2 个 `TextEditingController`（各自持有一个 `ValueNotifier` 和变更监听）。频繁"进书 → 退出 → 换书"会线性累积。属于慢速内存泄漏，不会立刻崩，但 TV 盒子常年不关机，长会话下会持续增长。

**修法**（两行，零风险）
```dart
// reader_part_01.dart 的 dispose() 内，_pageCtrl.dispose() 旁
_ttsNarratorCtl.dispose();
_ttsDialogueCtl.dispose();
```

**修复记录（已完成）**
`reader_parts/reader_part_01.dart` 的 `dispose()` 里，在 `_pageCtrl.dispose()` 之后补上两行，并附注释说明"每进出一次泄漏 2 个、TV 盒子常年不关机属累积型泄漏"。两个控制器只被阅读器自己的 TTS 音色弹层使用（`reader_part_06.dart:439/443`），随页面销毁释放安全。

---

#### N2｜局域网传书：文件名净化不全，Windows 收文件会失败 ✅

**位置**：`lib/reading/services/peer_transfer_service.dart:923-926`

```dart
String _sanitizeFilename(String name) {
  final clean = name.replaceAll(RegExp(r'[/\\]'), '_').trim();
  return clean.isEmpty ? 'file.bin' : clean;
}
```

**只替换了 `/` 和 `\`**，未处理 Windows 另外 7 个非法字符 `: * ? " < > |`，也没过滤控制字符、没有长度上限。

**影响**
对端传一个名为 `第1章:开端.epub` 的文件过来，落盘时 `File.write` 在 Windows 上直接抛 `FileSystemException`，**接收失败，用户只看到"失败"两个字，日志里也看不出是文件名的问题**。

**这是典型的"不一致型"缺陷**——同一个仓库里其他 4 处文件名净化都做对了：

| 位置 | 处理方式 |
|---|---|
| `services/download_service.dart:394` | 全非法字符 + 尾部点空格 + `maxLen` |
| `reading/services/book_download_service.dart:367` | 全非法字符 + 尾部点空格 + `maxBytes: 180` |
| `services/file_export_service.dart:84` | 全非法字符 + 尾部点空格 |
| `music/services/download_service.dart:316` | 全非法字符 + 控制字符 |
| **`reading/services/peer_transfer_service.dart:923`** | **仅 `/` `\`** ← 漏 |

**修法**：直接对齐 `file_export_service._safeName` 的实现即可。

**修复记录（已完成）**
`peer_transfer_service.dart` 的 `_sanitizeFilename` 重写为与 `book_download_service._sanitize` 同一套规则：
① 非法字符 `[<>:"/\|?*\x00-\x1f]` → `_`；② 去尾部点/空格（Windows 会静默吃掉）；③ 挡掉 `.` / `..` 与空名（兜底 `file.bin`）；④ **按 UTF-8 字节**截断到 180 字节并**保留扩展名**，截断点回退到多字节字符首字节，避免截出半个汉字。

独立脚本验证 11 组边界（含 `第1章:开端.epub` → `第1章_开端.epub`、`../../etc/passwd` → `.._.._etc_passwd`、尾部点/空格、控制字符、200 个汉字的超长名）全部符合预期；超长名截断后 179 字节、无 `U+FFFD`。

---

#### N3｜章节导出文件名无长度上限、未去尾部点 ✅

**位置**：`lib/reading/pages/book_source_detail_page.dart:1032-1033`

```dart
String _safeFileName(String s) =>
    s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
```

非法字符处理到位，但缺三样：

1. **没有长度上限** —— 网文常见超长章节名（60+ 汉字 ≈ 180+ 字节），叠加目录路径后可能突破 Windows 260 字符上限 → 导出失败；
2. **没有去尾部 `.` 和空格** —— 章节名以句号结尾（`第12章 结束.`）时，Windows 会静默截掉尾部点，导致"文件存在但名字对不上"，后续按名查找失败；
3. 没过滤 `\x00-\x1f` 控制字符（从 HTML 解析来的标题偶尔带）。

**对比**：`book_download_service._sanitize(s, maxBytes: 180)` 三样都做了，注释里还写明了原因。同一功能存在两套实现，其中一套退化。

**修复记录（已完成）**
`book_source_detail_page.dart` 的 `_safeFileName` 补齐三项：过滤 `\x00-\x1f`、去尾部点/空格、按 UTF-8 字节截断到 180 字节（留出调用方追加的 `.txt` 与上层目录余量），空名/`.`/`..` 兜底成 `chapter`，截断点同样回退到多字节边界。
独立脚本验证：超长章节名截断后 180 字节、拼接 `.txt` 后 184 字节，**未出现半个汉字**；`'   '` → `chapter`，`'第一章...'` → `'第一章'`。

---

#### N4｜Node 运行时下载链路是死代码；非 iOS 平台仍构造 iOS 实现 ✅

**位置**
- `lib/services/nodejs_manager.dart:90-104`（构造函数）
- `lib/services/nodejs_manager.dart:522`（`downloadAndExtractNodeRuntime`）
- `assets/nodejs-runtime/version.json`
- `lib/widgets/app_loading_view.dart:142,146`（唯一消费方）

**事实链**

1. 全仓 `grep "extends NodeJSPlatform"` **只有 1 处**：`nodejs_platform_ios.dart:34`。
2. 但构造函数**无条件**创建 iOS 实现并初始化，只打一行日志：

```dart
NodeJSManager._internal() {
  if (!Platform.isIOS) {
    AppLog.instance.nodejs('unsupported_platform',
        fields: {'os': Platform.operatingSystem});
  }
  final ios = IOSNodeJSPlatform(...);   // ← 非 iOS 平台照样构造
  ios.initialize();                     // ← 并初始化（MethodChannel 缺失时靠内部 try/catch 兜）
  _platform = ios;
}
```

3. `downloadAndExtractNodeRuntime`（:522）**没有任何调用方**；`loadNodeDownloadConfigPublic`（:752）同样无调用方。
4. 唯一读这两个状态的是加载页进度条：

```dart
// app_loading_view.dart:142
valueListenable: mgr.nodeDownloadProgress,   // 永远不会从 null 变化
valueListenable: mgr.nodeDownloadStatus,
```

**影响**
- **功能层**：Windows / Android 上无法运行嵌入 Node，依赖 Node 的 JS 书源实际不可用。这一限制注释里有写，不算隐瞒。
- **维护层**：`version.json` + 两个 `ValueNotifier` + 下载方法 + 公开读取函数构成一整套"看起来在用的下载子系统"，但整条链路无人调用。后来者会误以为 Windows 支持 Node，白花时间排查。**这类死代码比缺功能更贵。**

**建议**：二选一——
① 补齐 Windows 实现（`Process.start(node.exe)` + SHA-256 校验），把链路接上；
② 或明确删除 `version.json`、下载方法、进度条绑定，并在 README 写明"仅 iOS 支持嵌入 Node"。

**修复记录（已完成，选方案 ②）**

补齐 Windows 实现需要写完整进程管理 + SHA-256 校验 + 解压 + 跨平台测试，成本远高于本次范围，且无法在当前环境验证；删除死代码是零行为变更的收敛，故选 ②。

| 删除对象 | 位置 |
|---|---|
| `nodeDownloadProgress` / `nodeDownloadStatus` 两个 `ValueNotifier` | `nodejs_manager.dart` |
| `nodeDownloadConfig` getter（恒为 `null`）、`loadNodeDownloadConfigStatic()`、`loadNodeDownloadConfigPublic()` | `nodejs_manager.dart` |
| `isNodeRuntimeInstalled()`、`downloadAndExtractNodeRuntime()` | `nodejs_manager.dart` / `nodejs_platform.dart` / `nodejs_platform_ios.dart` |
| `NodeDownloadConfig` 整个类 | `nodejs_platform.dart` |
| `LoadingPhase.downloadingNodeJS` 及其 `description` 分支 | `app_state.dart` |
| 加载页那个永远走不到的下载进度条分支 + 随之无用的 `NodeJSManager` import | `app_loading_view.dart` |
| `assets/nodejs-runtime/version.json` 及 `pubspec.yaml` 声明 | 资源 / 配置 |

同时补了一处**真正的行为收敛**：`NodeJSManager.startNodeJS()` 现在在非 iOS 平台**显式短路**返回 `false` 并记 `start_skipped_unsupported_platform`。原来它会先 bind 一个本地 HTTP server（白占端口/资源），再走一个不存在的 MethodChannel，靠 iOS 实现的 `catch` 兜成 `false` —— 结果虽相同，但日志里全是 `startNodeJS 异常`，排查时极具误导性。

文件头注释同步改写为"**当前只有 iOS 真正实现了嵌入 Node**"，并说明 Windows/Android 未实现，避免后来者再被误导。

---

### 3.2 P3 —— 规范性与隐患（**影响面已逐条核实**，2026-10-27 修订）

> 本节原先把 4 项并列，容易被读成"都有隐患"。逐行核实代码后必须区分开：
> **只有 N8 有真实、用户可见的后果；N5/N6 的实际影响约等于零；N7 是一个"兜底不对称"的设计缺口。**

| 项 | 具体影响什么 | 真实严重度 |
|---|---|---|
| **N5** `CurvedAnimation` 未 dispose | 不影响任何功能。三处的 `AnimationController` 都在 `dispose()` 里释放了，父控制器一销毁，`CurvedAnimation` 挂在它上面的监听随之清空 | 纯规范（≈0） |
| **N6** `close_sinks` 未启用 | 不是"现在漏了"，而是"**以后漏了没人提醒**"。唯一实例 `_stopCtrl` 的订阅方在 `finally` 里 `sub.cancel()` 了，是干净的 | 防线缺口（≈0） |
| **N7** Hive 只开不关 | ✅ **已修**：补 `flush()`（切后台）+ `close()`（退出）+ `_closed` 守卫；影响 `CacheStore` 三个箱：影视收藏、观看记录、缓存条目 | 已消解 |
| **N8** 健康检查并发 12 | **体检超时被误判成"源挂了" → 体检结束自动停用该源** ⇒ 用户可用的源被悄悄关掉。这是四项里唯一有用户可见后果的 | **真实（中）** |

#### N5｜`CurvedAnimation` 未 dispose（3 处）

| 文件 | 行 | 说明 |
|---|---|---|
| `reading/widgets/book_page_cover.dart` | 67 | `_anim = CurvedAnimation(parent: _ctrl, ...)` |
| `reading/widgets/book_page_curl.dart` | 99 | 同上 |
| `reading/widgets/staggered_entrance.dart` | 31 | `_fade = CurvedAnimation(...)` |

三处都正确 dispose 了 `AnimationController`，但**派生出的 `CurvedAnimation` 没 dispose**。Flutter 3.13 起 `CurvedAnimation.dispose()` 是官方推荐做法，不调用会在 parent 上残留状态监听。

**影响面（已核实，比原文更弱）**：这三处的 `parent` 都是**本 widget 自己持有并已 dispose** 的 `AnimationController`（`book_page_cover.dart:74`、`book_page_curl.dart:106`、`staggered_entrance.dart:44`）。`AnimationController.dispose()` 会清掉自身的监听列表 ⇒ `CurvedAnimation` 挂上去的那条也随之释放，`CurvedAnimation` 对象本身在 State 被丢弃后即可回收。**所以这里不存在可观测的内存增长**，属于"官方推荐姿势没跟上"的规范项，不是隐患。

> 顺带记录一个更值得注意的点：`staggered_entrance.dart:38` 用了 `Future.delayed(...)` 做瀑布延迟，这个定时器**没有取消**。它内部有 `if (mounted)` 守卫，所以不会崩；但快速滚动的长列表会积压若干 pending timer（widget 测试里这类残留会报 "Timer still pending"）。真要收拾，优先修这条而不是 `CurvedAnimation`。

---

#### N6｜`close_sinks` lint 未启用 → `StreamController` 泄漏无静态防线

`analysis_options.yaml` 启用了 `cancel_subscriptions`（效果显著：全仓 `StreamSubscription` **零遗漏**，`dart analyze` 0 warning 就是证据），但**没启用 `close_sinks`**。

后果：`StreamController` 从不 close 的情况静态检查发现不了。实例：

```dart
// reading/services/book_source_health_service.dart:401
final StreamController<void> _stopCtrl = StreamController<void>.broadcast();
// 全仓无 _stopCtrl.close()
```

该服务是单例常驻，实际影响可忽略；但**防线缺一条**是系统性问题——新写的代码不会有人提醒。

**补充核实（2026-10-27）**：唯一的订阅点 `healthCheckAll()` 里 `final sub = onStop.listen(...)`，在 `finally { await sub.cancel(); }` 里**确实取消了**（`book_source_health_service.dart:804`）。所以现在既没有监听器泄漏、也没有控制器泄漏 —— 这条纯粹是"缺静态防线"，不是现存缺陷。

**建议**：`analysis_options.yaml` 加一行 `- close_sinks`，一次性把这类隐患纳入 CI 门禁。加之前要先给 `_stopCtrl` 补 `close()` 或加 `// ignore:`，否则会新增 1 条 warning。

---

#### N7｜Hive box 只开不关 ✅

**位置**：`lib/models/cache_store.dart:182-184`（原始代码）

```dart
_collectsBox   = await Hive.openBox(_collectsBoxName);
_recordsBox    = await Hive.openBox(_recordsBoxName);
_cacheItemsBox = await Hive.openBox(_cacheItemsBoxName);
```

全仓无 `Hive.close()`。

**评估**：单例常驻、桌面端影响可忽略，**不算缺陷**。但值得知道一点：iOS 上 App 被信号直接杀死时，未 flush 的 Hive 写入可能丢——项目已经为 `SharedPreferences` 单独做了 `PrefsMirror` 镜像兜底（见 `prefs_mirror.dart`），**Hive 没有对应机制**。如果缓存里的收藏/观看记录对用户重要，这个不对称值得补。

**修复记录（已完成，2026-10-27）**

修的时候先确认了一件事：**光加 `Hive.close()` 并不能防丢数据**。`close()` 释放的是文件句柄（进程退出时本来也会释放），真正让写入变持久的是 `flush()`。所以按场景拆成两个动作：

| 时机 | 动作 | 为什么 |
|---|---|---|
| `AppLifecycleState.paused`（切后台） | `flush()` | 这是**真正防丢**的那一步。Hive 的 `put` 是"先进写队列、再落盘"，切后台时刷一次，几毫秒换"数据已落盘" |
| `AppLifecycleState.detached` | `close()` | 引擎即将脱离宿主，移动端能拿到的最后时机 |
| `didRequestAppExit()`（桌面关窗） | `close()` | **唯一可靠**的"退出前"钩子；移动端系统直接杀进程，不会调到这里 |

`CacheStore` 侧改动：
- 新增 `flush()` / `close()`（均幂等）与 `isClosed`；
- `close()` 先 `flush()` 再 `close()`，逐个箱 try/catch，单箱失败不影响其它；
- 新增 `_closed` 守卫：关闭后**所有读写静默跳过**。不加这个守卫，退出流程里任何一次写入都会抛 `Box has already been closed` —— 而那个位置没人接得住，只会变成一条难查的崩溃日志；
- `init()` 改为 `if (_initialized && !_closed) return;` 并复位 `_closed`，避免关箱后卡在"已关闭"死状态；
- 顺手把**三次串行 `openBox` 改成 `Future.wait` 并行**（三个箱互不依赖，原来白等两次磁盘往返）。

> 注：没有做"文件镜像"那种重兜底。查了 hive_ce 的默认行为，箱是 `crashRecovery: true`（带写前日志，写一半被杀能恢复），加上 `paused` 时 flush，丢数据的窗口已经很小；再叠一层镜像属于过度设计。


---

#### N8｜书源健康检查并发默认 12 —— 真正的后果是"误停用可用源"

**位置**：`lib/reading/pages/book_source_health_page.dart:51`

```dart
int _concurrency = 12;   // 默认值
```

**原文写"该值可被用户调整，但没有 clamp"，这句不准确，更正如下：**

- 用户**不能自由输入**，只能从固定档位里点选：`1 / 2 / 3 / 4 / 6 / 8 / 12`（`:404-417` 的 chip 列表）⇒ 上限就是 12，不存在"用户填 999"的路径。
- 服务侧 `analyze()` **有** clamp：`concurrency.clamp(1, 32)`（`book_source_health_service.dart:642`）。
- 真正的缺口在**另一个入口** `healthCheckAll()`（`:777`）：`final n = concurrency < 1 ? 1 : concurrency;` —— **只挡下界，没挡上界**。两个入口策略不一致，目前只因唯一调用方传的是页面那个 ≤12 的值才没出事。

**真正的后果（这才是该关心的）**：`_start()` 结束后会**自动停用**所有 `level != healthy` 的源（`:192-206`，用户 2026-10-20 的要求）。而"健康"判定依赖网络请求在超时内返回 —— 12 路并发在低端盒子 / 弱网 / 源站限流时，**大面积超时会被判成 `networkFail` ⇒ 用户本来能用的源被自动关掉**，且提示只有一句"已自动停用 N 个失效源"。用户不会意识到是并发太高导致的误判，只会觉得"源怎么都没了"。

**建议**（按优先级）：
1. 默认值从 12 降到 **4~6**（对判活准确率更有利；体检本来就是低频操作，慢一点无所谓）；
2. `healthCheckAll()` 补上界 clamp，与 `analyze()` 对齐；
3. 自动停用前加一道"**只有连续 2 次判定失败才停用**"或"停用前列出清单让用户确认"，避免单次超时误伤。


---

## 四、深挖已排除的项（阴性结论）

以下都是本轮**重点怀疑并逐行核实过、确认没问题**的地方。记录下来，避免以后重复排查。

| 怀疑点 | 核实方式 | 结论 |
|---|---|---|
| `WidgetsBindingObserver` 注册后忘记注销 | 全仓比对 `addObserver(this)` / `removeObserver(this)` | **8 处全部成对**：`app.dart:89/98`、`content_view.dart:83/128`、`detail/controller.dart:306/311`、`reading_pet_overlay.dart:48/64`、`video_player.dart:744/2869`、`book_reader_page.dart:278/377`、`pomodoro_button.dart:50/56`、`reader_part_01.dart:419/576` |
| 裸 `HttpClient()` 不关闭导致 socket 耗尽 | 逐个查看 8 处创建点的释放路径 | 全部正确：3 处 `finally { client.close(force: true) }`（`purify_rules_page:344`、`reader_part_01:2168`、`reader_font_service:399`）；3 处交给 Dio adapter 托管（`download_service:192`、`config_manga_source:114`、`analyze_url:672`）；1 处字段在 dispose 关闭（`video_player:1872→2892`）；1 处 try/finally（`cf_session:171`） |
| `StreamSubscription` 泄漏 | 依赖 `cancel_subscriptions` lint + 抽样核对 | **零遗漏**。`peer_transfer_service`、`room_lan_server`、`sync_service`、`app_state`、`tts_service` 均正确 cancel |
| `Timer` 未取消 | 自研扫描器找出 40+ 个 `Timer` 字段，逐个看 dispose | State 类**全部**在 dispose 中 cancel（阅读器一处补了 `_ttsTimerHandle`、`_repaginateDebounce`、`_tapTimer` 等共 7 个）；服务类定时器属常驻设计，非泄漏 |
| `addListener` 多于 `removeListener`（30 个文件） | 逐个看注册对象的所有权 | 全部良性：要么是**自持有**的 `TextEditingController` / `FocusNode` / `ScrollController`（随 dispose 一起释放），要么是单例上的常驻监听 |
| 动画控件（`jelly_*`、`book_page_*`、`staggered_entrance`）泄漏 `AnimationController` | 看 initState / dispose 配对 | 全部正确 dispose；仅 `CurvedAnimation` 派生对象未释放（见 N5） |
| 下载并发无上限 | 看 `book_download_service` 队列调度 | 有上限：`while (_runningCount < max)`，`max = maxConcurrentChapters`，且 `maxConcurrentChaptersLimit = 5` 硬钳 |
| 音乐模块并发无上限 | 看 `Semaphore` 使用 | 有上限：`unblock_service` 4、`source_health_service` 3，且是**跨调用共享**信号量（注释专门说明了为什么不能用 `List.generate` 每次新开） |
| 下载文件名非法字符 | 全仓 `grep` 净化函数 | 5 处中 4 处完整，仅 `peer_transfer_service` 漏（见 N2） |
| 子进程僵尸 | 查 `Process.start` / `.kill()` | 全仓**无** Dart 侧 `Process.start`；Node 走原生 channel，`app_state.dart:138` 在 `onClose` 调 `stopNodeJS()` |
| `jsonDecode` 崩溃 | 统计 276 处 | 绝大多数在 `try` 内；抽样未见裸奔的网络解析 |
| `OverlayEntry` 不移除 | 查 `zlibrary_auth_page` / `AppToast` | `zlibrary_auth_page:86-99` 的 dispose 调 `_removeEmailOverlay()`；`AppToast` 用 `remove()` 而非 `dispose()`，正确 |

> **扫描方法**：自研静态扫描器 `E:\Dev\_tools\bugscan\scan.dart`（正则 + 花括号配平，覆盖 20 类需显式释放的资源），扫描 568 个文件，**原始命中 133 处 / 65 文件**，逐条人工甄别后**确认真实缺陷 4 处**，其余为"外部持有 / 单例常驻 / 已正确释放"的误报。
>
> 误报率高恰恰说明代码在这块写得很规范——扫描器只能看到"字段类型"，看不到所有权归属。

---

## 五、仍存在但按你的决策保留

以下问题**技术上成立**，但你已明确要求暂不处理。列此备忘，**不建议本轮改动**。

| 项 | 内容 | 你的决策 |
|---|---|---|
| ~~P1~~ | ~~Node 运行时下载**无 SHA-256 校验**~~ → **已随 N4 删除死链而消失**（该下载链路整体移除，不再存在"下载但不校验"的路径） | 已消解 |
| P1 | **硬编码明文 HTTP** 默认地址（用户自填源属生态现状可接受；代码里写死的那批应改 https） | 暂不动 |
| P1 | `main()` 启动期 **49 个串行 await**，拉长白屏（恢复类已加 5s 超时保护，注册类仍串行） | 暂不动 |
| P1 | `debugPrint` 全局重定向写文件（`main.dart:93`），无 lint 阻止 `build()` 内高频调用 | 暂不动 |
| P2 | **176 处同步 IO**（`avoid_slow_async_io`），多在启动期一次性初始化，改 async 收益低、改动面大 | 不动 |
| P2 | 523 处空 catch 中，数据链路的已补 `AppLog.w`，其余"失败也无所谓"的（缓存/广告匹配）保留 | 部分处理 |
| — | **三套阅读器不合并**（`book_source_reader_page` / `book_reader_page` / `reader_page`） | 叫停，维持现状 |
| — | **Z-Library 内置账号原样保留**（`reading/services/builtin_accounts.dart`） | 叫停，写死不碰 |
| ~~—~~ | ~~音乐内置订阅 URL 改为 jsDelivr 后**仅首启种入**，已安装用户需手动删旧订阅再重加~~ → **已修**：新增一次性存量迁移，把 prefs 里旧的 github.io 地址就地改写成 jsDelivr（详见 §六） | 已消解 |

> 补充：`plugin_market_service.dart:209` 的 `_ghPagesBase` 仍是 `github.io`，但运行时会被改写成 jsDelivr，属**转换用基址**，保留是对的。

---

## 五·补充｜启动期 49 个串行 await 的优化评估（2026-10-27）

**结论：能优化，但"把 49 个 await 并行化"几乎没有收益** —— 因为绝大多数 `init()` 根本不是 IO。

### 实测取样（读代码确认，非估计）

| 步骤 | 实际做的事 | 真实成本 |
|---|---|---|
| `ViewMode().init()` | `prefs.getBool(_key)` 一行 | 微秒级（`SharedPreferences.getInstance()` 之后是内存 Map 查询） |
| `ReadingLayout().init()` | `prefs.getInt(_key)` 一行 | 同上 |
| `BookViewMode` / `SourceViewMode` / `ReaderOverride` / `BookFont` / `TrimPreset` | 同上，单键读取 | 同上 |
| `MiniAppService.ensureLoaded()` | prefs + 可选文件备份 | 毫秒级 |
| `ZlibraryService().init()` | prefs + `_loadCounts()`（也是 prefs） | 毫秒级；网络探测是 fire-and-forget |
| `RemoteConfigService().init()` | prefs 读缓存，`_refresh()` 不 await | 毫秒级 |
| `CacheStore.instance.init()` | **3 次 `Hive.openBox`** | 首次开箱要读磁盘索引，**几十毫秒级** |
| `SourceManager().init()` | 逐条实例化源（CPU）+ `SourceConfigStore().loadLocal()` 读 JSON | **随源数量线性增长** |
| `BookSourceStore.instance.init()` | 读书源 JSON（用户可能导入上千条） | **随书源数量增长** |
| `MusicPlayerManager.instance.init()` | 建 media_kit 播放器（原生） | **几十~上百毫秒** |

结论：49 个里**约 35 个是"读一个 prefs 键"**，串行累加也只有几毫秒；真正吃时间的是 4~5 个（Hive 开箱、源实例化、大 JSON 解析、播放器创建）。

### 三条可选路线（按收益/风险排序）

| 路线 | 做法 | 预估收益 | 风险 |
|---|---|---|---|
| **A** | 把 `runApp()` 提前到最小依赖集之后（AppLog / PrefsMirror / 主题 / AppState），其余初始化放到首帧后由 `AppLoadingView` + `AppState.loadingPhase` 驱动 | **最大**（白屏直接消失，改为进度视图） | **高**：`Get.find` 在首帧找不到实例会抛；顺序敏感项多（阅读模块注释明确写了"顺序错会丢状态"） |
| **B** | 只优化 4~5 个重步骤：3 个 Hive box 改 `Future.wait`；`SourceManager().init()` 延迟到首次进漫画/书源页；`BookSourceStore` 大 JSON 改 isolate 解析 | **中**（几十~几百毫秒，视数据量） | **中**：延迟初始化要处理"首次进页面时还在加载"的 UI 态 |
| **C** | 把 49 个 await 按依赖分组 `Future.wait` | **极小**（上表已说明多数是微秒级） | 低，但改动面 49 行、收益接近噪声 |

### 建议

先做**测量**再动手：给上述 4~5 个重步骤加 `Stopwatch` 计时（`--dart-define=STARTUP_PROFILE=true` 时才输出到 AppLog），在真机/盒子上跑一次，拿到真实分布。没有这个数据，A/B/C 三条路都是在猜。测完大概率只需做 B 里的一两项。

> 注：`main()` 里已有 6 处 `unawaited(...)`（订阅自动更新、Webhtv 同步、缓存清理、随机背景图等）—— 这些是**对的**，网络类初始化本来就该 fire-and-forget。


---

## 六、已完成的整改（追溯用，不再是问题）

| 项 | 结果 |
|---|---|
| **P0.1 拆 15,858 行阅读器** | ✅ 主文件 1,307 行 + `reader_parts/` 7 个 mixin part（2,183 / 2,333 / 2,182 / 2,286 / 2,249 / 1,868 / 2,086），最大 2,333 行（降 85%）。顺序无关方案：基类 `abstract` + 269 个方法签名 + 各 part 一个 `mixin ... on 基类` + impl 子类 `with` 全部。**代价：149 条 warning，已用文件级豁免修掉（见 N0）** |
| **TMDB 明文 Key** | ✅ 彻底移除，`_defaultApiKeyLiteral = ''`，仓库零明文，`configured` 默认 false；注入二选一（`--dart-define=TMDB_API_KEY` 或设置页自填） |
| **数据链路空 catch** | ✅ 已补 `AppLog.w`，热路径故意跳过 |
| **import 风格** | ✅ `always_use_package_imports` 2,616 → 0，全项目统一 `package:tvbox/...` |
| **Dio 未走自定义 DNS** | ✅ 改为 `HttpOverrides.global` 一次性覆盖（`dio_factory.installGlobalDnsOverrides()`），Dio / `Image.network` / `WebSocket` / `cached_network_image` 全部生效，并规避了 DoH 自递归、回环改写、代理忽略三个坑 |
| **`onReorder` 语义变更** | ✅ 10 处已按新索引语义人工修正 |
| **宠物形象** | ✅ 重绘为矢量红围巾企鹅（`blob_pet_painter.dart`），去掉外部 GIF 依赖 |
| **音乐模块 github.io 单点** | ✅ `plugin_subscription.dart:69`、`builtin_sources_service.dart:184`（five 源）换 jsDelivr(gcore) |
| **8 个陈旧测试** | ✅ 已修好，本次实测 **659 / 659 全过**（上一版附录"637 通过 / 8 失败"已过期） |
| **N1 阅读器 TTS 控制器泄漏** | ✅ `reader_part_01.dart` 的 `dispose()` 补 `_ttsNarratorCtl` / `_ttsDialogueCtl` 释放（原先每进出阅读器泄漏 2 个） |
| **N2 局域网传书文件名净化** | ✅ `peer_transfer_service._sanitizeFilename` 对齐 `book_download_service._sanitize`：全非法字符 + 尾部点/空格 + 挡 `.`/`..` + 按 UTF-8 字节截断（180B）并保留扩展名 |
| **N3 章节导出文件名** | ✅ `book_source_detail_page._safeFileName` 补控制字符过滤、尾部点/空格、180 字节截断（留 `.txt` 余量），空名兜底 `chapter` |
| **N4 Node 运行时下载死链** | ✅ 删除整条死链（`NodeDownloadConfig` / 下载方法 / 两个进度 `ValueNotifier` / `downloadingNodeJS` 阶段 / 加载页进度条 / `version.json` 资源），并让 `startNodeJS()` 在非 iOS 显式短路；文件头改为"仅 iOS 实现" |
| **N7 Hive 只开不关** | ✅ `CacheStore` 新增 `flush()` / `close()`（幂等）+ `_closed` 守卫（关闭后读写静默跳过，不抛"箱已关闭"）；接线 `paused`→flush、`detached`/`didRequestAppExit`→close；顺带把 3 次串行 `openBox` 改 `Future.wait` 并行 |
| **音乐订阅 github.io 存量迁移** | ✅ `PluginSubscriptionStore.init()` 新增一次性迁移：把 prefs 里旧 `hebijunge.github.io/musicfree-plugins/...` 地址**就地改写**为等价 jsDelivr（路径原样保留），幂等、不碰用户自填地址；新增 `mirrorToJsDelivr()` 纯函数 + 7 条单测。已安装用户不再需要手动删订阅重加 |

---

## 七、做得好的地方（值得保持）

1. **静态分析零 error 零 warning**，lint 比默认严格得多，且 `cancel_subscriptions` 这类"资源泄漏防线"主动开着。
2. **`AppLog` 设计成熟**：背压队列（2000 条上限）、按天轮转、`flush: false` 权衡（避免高频 fsync 伤闪存），注释里连"为什么从 flush:true 改成 false"都记了。
3. **`buildDioWithDns` / `HttpOverrides` 实现正确**：只换 socket 连接目标，保留 Host 头 / TLS SNI / 证书校验——最容易写错的地方；还专门处理了 DoH 自递归死锁与回环地址。
4. **`AntBridge` 有权限门禁 + SSRF 防护**（拦回环 / 内网地址）。
5. **`PrefsMirror` 崩溃恢复**：针对 iOS 被信号杀进程导致 NSUserDefaults 整域丢失，单独做文件镜像——踩过坑才有的设计。
6. **252 个 `StatefulWidget` 的 `mounted` 检查零遗漏**。
7. **并发控制有意识**：下载队列硬上限 5；音乐模块用**跨调用共享**的 `Semaphore`，注释明确写了"不能用 `List.generate` 每次新开"的原因。
8. **隔离与降级做得好**：`SourceManager().init()` 失败只记日志不阻断启动；书源求值走 worker isolate（`BookSourceRunner.enabled = true`），同步抓取不卡 UI；worker 有空闲回收 + 死亡检测 + 60s 超时兜底。
9. **注释质量罕见**：大量注释记录的是"为什么这么改 / 改之前踩了什么坑"，而不是"这行做了什么"——对长期维护的价值远高于代码本身。

---

## 八、附录：验证方法

### 静态分析

```powershell
$env:FLUTTER_ROOT="C:\Users\24647\fvm\versions\3.44.2"
dart analyze lib
# → 0 error / 0 warning / 1,663 info
```

### 单元测试

首次运行会因**本地 HTTP 代理**导致全部失败（`WebSocketException: Invalid WebSocket upgrade request`）——Dart 的 `HttpClient` 默认读 `HTTP_PROXY`，把连 `flutter_tester` 的回环 WS 也送进了代理。清除即可：

```powershell
$env:NO_PROXY="127.0.0.1,localhost,::1"
Remove-Item Env:HTTP_PROXY, Env:HTTPS_PROXY, Env:http_proxy, Env:https_proxy
flutter test
# → 01:07 +659: All tests passed!
```

### 文件名净化边界验证（N2 / N3）

两个净化函数都是 `private`，无法从测试直接调用，故把逻辑等价抽到独立脚本做边界校验（验证算法本身，接线由 `dart analyze` + 全量测试保证）：

```powershell
dart run E:\Dev\_tools\bugscan\sanitize_check.dart
```

覆盖：Windows 保留字符、路径穿越 `../`、纯 `.` / `..`、空串、尾部点/空格、`\x00-\x1f` 控制字符、无扩展名、200 个汉字超长名。
判定：全部符合预期；超长名截断后 **179 / 180 字节**（≤ NAME_MAX），且**不含 `U+FFFD`**（未截出半个汉字）。

### 资源泄漏扫描

```powershell
dart run E:\Dev\_tools\bugscan\scan.dart lib E:\Dev\_tools\bugscan\out.txt
# → 总命中 133，文件数 65，扫描文件 568
```

扫描器覆盖 20 类需显式释放的资源：`Timer`、`StreamSubscription`、`AnimationController`、`TextEditingController`、`ScrollController`、`PageController`、`TabController`、`FocusNode`、`TransformationController`、`ValueNotifier`、`VideoPlayerController`、`AudioPlayer`、`ReceivePort`、`RawDatagramSocket`、`StreamController`、`Isolate`、`HttpClient`、`ImageStream`、`OverlayEntry`、`Animation`。命中项已全部人工甄别（见 §四）。

> 注意：扫描器**不识别所有权**（外部传入的 controller、单例上的 ValueNotifier 都会被算命中），所以 133 → 4 的收敛是人工甄别的结果，不是脚本能自动给出的。
