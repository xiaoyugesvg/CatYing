# 猫影 NewTv · iOS TVBox 全能客户端

> **最终成品：iOS 巨魔 IPA**（[TrollStore](https://github.com/opa334/TrollStore) 安装，无需 Apple 签名）
> **开发机：Windows**（用 `.node.exe` 提前发现 bug，降低 iOS 调试成本）

基于 **Flutter** + **Node.js / CPython 双引擎**的 TVBox 生态客户端，内置 **四套播放内核**。
应用显示名为「猫影」。

---

## ✨ 功能

### 📺 影视点播
- **订阅 / 多源管理**：多订阅切换、订阅上锁、随启动自动同步、订阅二维码导入
- **源类型**：TVBox / CatVod 配置（`sites` / `parses` / `lives`）、`js` 脚本源、`jar` 源、**Python 源**、CSP 占位源
- **搜索 / 首页 / 分类 / 详情 / 播放** 全链路，抖音模式（电影上/下滑切换）
- **收藏 / 观看历史 / 续播**（按集 + 秒级进度落盘）

### 🎬 播放内核（四套，可独立切换并热生效）
| 内核 | 实现 | 适用 |
|---|---|---|
| **AVPlayer**（默认） | `video_player` / 系统 AVPlayer | iOS 主力，支持系统小窗 PiP |
| **FF / KSPlayer** | FFmpeg + Metal（`ks_player` 原生桥） | MKV / ASS / 多音轨等 AVPlayer 吃不下的格式 |
| **MPV** | `media_kit` + libmpv | flv / ts / rtmp 等直播格式、桌面端 |
| **WebView** | `webview_flutter` + WKWebView | 网页播放页 |

- 点播内核与直播内核**分别持久化**，互不干扰
- **嗅探 / 解析系统**：独立的嗅探与解析总开关、嗅探黑白名单、解析域名黑白名单、影视直链后缀可自定义；三层嗅探（JS 注入 → 跨域 iframe 网络层兜底 → HTTP 抓页）
- 切换内核立即重建播放器并从当前进度续播

### 📡 直播
- `lives` / m3u / xtream 源解析、EPG、分类屏蔽
- 按流格式路由内核（m3u8/mp4 优先 AVPlayer，flv/ts/rtmp 优先 FFmpeg）
- 直播源本地独立持久化：切换点播源不会覆盖用户手动增删改的直播源

### 🎵 音乐
- 内置 **洛雪（LX）** 与 **MusicFree** 插件源（+ 自定义导入）
- 音源优先级：本地文件 → 平台固定源 → 其余启用源试播 → 内置接口 → 全源试播后弹窗选择
- 歌词 / 倍速 / 音质 / 播放队列 / 收藏与最近播放 / 下载
- 锁屏与控制中心媒体控制（原生 `MusicNowPlaying`）

### 📚 阅读
- **图书**：书源搜索、书架、阅读进度、听书（TTS）、番茄钟、批量下载、笔记与书签
- **漫画**：多源聚合搜索、阅读器（页翻 / 左右 / 溶解 / 连续）
- **书源引擎**：完整兼容 **Legado（阅读）** 规则（`@jsoup:` / `xpath` / 正则 / `{{}}` 求值 / `jsLib` / `loginUrl`+`loginUi` JS 登录 / 目录与正文分页 / GBK 延迟 / `imageDecode`），并兼容 Rhino Java 互操作 API
- **RSS**：按 Legado 订阅源规范实现（`sortUrl` 规则表达式、`jsLib`、`loginUi` 动态表单、`articleStyle` 分档渲染、`preload` / `cacheFirst`），全局代理生效、字符集自动识别
- **Z-Library**：内置账号 / 自定义账号、节点测试与切换、下载
- 局域网互传（Bonjour/mDNS）、阅读计划、显示设置（列表密度 / 封面圆角 / 卡片信息）

### 🌐 网页（Webhtv）
独立模块，在「设置 → Webhtv」单独管理：
站点注入 · WebHome 扩展（代码/远程/本地文件）· 网盘链接检测（夸克/阿里/百度/UC/天翼/迅雷/123/115/磁力/ed2k）· 站点健康排序 · 域名级代理 · 观影记录同步（`webhtv.playback.v1`：Webhook 上报 + 远端拉取合并 + 删除墓碑）

### 🧩 程序（小程序）
导入 **TVBox 生态小程序**：

| 格式 | 说明 |
|---|---|
| TVBox 配置 | 顶层对象 `{"name":…,"sites":[…],"lives":[…]}` |
| 小程序市场 | 顶层 `{"apps":[…]}`，点击安装 |
| 网页型小程序 | `.zip` 包（含 `manifest.json`）或远端 `manifest.json`（在线站点型） |

> ℹ️ 海阔视界（hiker / hipy）格式**不在「程序」里** —— 它是另一套运行时（全局 `$` / 同步抓取 /
> `hiker://` 伪协议），本项目已为它做了**独立模块**，见下面的「🛰️ 海阔」。

### 🛰️ 海阔（hiker / hipy）
独立模块（**默认不进底栏**，在「设置 → 菜单设置」里开），直接跑**海阔视界**的小程序规则。

- **规则执行**：Node 侧 `src/hiker_engine.js`。海阔的 API 是**同步**的，而 NodeMobile 没有 worker_threads，
  所以用「**重放桥**」：规则里每个同步抓取先查缓存，未命中就抛信号 → 宿主抓完 → 用同一份缓存**重跑**整条规则
  （在"未命中 URL 数 + 1"次内收敛；有次数上限 + 总预算双闸门，坏规则不会空转）
- **兼容面**（逐条对齐官方 `help_js.json` / `JSEngine.java` 的语义）：
  `find_rule` / `searchFind` / `detail_find_rule`；`parseDom` / `pd` / `pdfh` / `pdfa`（CatVod 老三样）；
  `$.require`（`hiker://page` 源内模块 / `hiker://assets` App 自带资源 / `hiker://files` 文件区 /
  `rc()` 远端依赖带小时级缓存）；`$.exports` 模块导出约定（模块名与内部变量名常常不一致，靠它取值）；
  `setResult` / `setHomeResult` / `setPreResult`；`getMyVar` / `setMyVar`（变量按源落盘）；
  `addListener('onClose', …)`（**离开页面时回放**，清变量这类逻辑真的会执行）；
  `lazyRule` / `rule` / `input` / `select` / `image` / `x5Rule`（两趟延迟规则）；
  全局 `AES` / `CryptoJS` / `Data`；`java.*` 常用类（Base64 / MessageDigest / GZIP 与字节流 /
  `Thread.sleep` / UUID / `StringBuilder` / `reflect.Array`）；`WebView 抓页 fetchCodeByWebView`（真 WebView）
- **密文核心**：`base64 → GZIP 流 → eval` 这种内嵌 JS 核心（如 JavDB v3/v5）能直接跑通
  （实测解出 108134 字符、版本号一致）
- **内置源**：随包 25 个**实跑筛出来**的源 —— 拿 115 个源逐个真跑 `home`，只有真出内容的才收进来
- **文件管理**：`海阔设置 → 文件管理（hiker://files）`，导入规则包 zip / 放数据文件。
  有一批源依赖**用户自己导入的规则包**（最典型是 **Apollo**）—— 它**不在海阔 App 里**，原版同样要用户自己装
- **边界**（都给明确原因，不会静默出错数据）：需要用户文件的源、新版海阔的**密文模块引用**
  （`$.require('<加密串>')`）、任意 Java 类反射、`java.t2s/s2t` 繁简转换（无对照表，原样返回）。
  另有一条**已知限制**：源里"不 `require` 就直接用别的模块定义的函数"（裸 `buildUrl()` 这类）不支持 ——
  试过按需预加载 pages，实测**净负**（重型模块顶层就抓页，会引入额外请求，可用数 47 → 46），已回退
- **实测可用率**：115 个源里 **47 个**能出内容（其余构成：31 个需用户文件、5 个站点本身 0 条、4 个网络、7 个模块限制）


### ⚙️ 通用
- 分模块统一主题（影视 / 直播 / 音乐 / 阅读 各选配色）、明暗跟随、自定义壁纸与背景
- 首页幻灯片 8 种布局、底栏功能开关与排序
- **RSS / 网页(Webhtv) / 海阔 默认不进底栏**（在「设置 → 菜单设置」里打开）；开关关着时这三个页面
  也**不做任何预热**（不建 WebView、不发请求）
- **嗅探 / 解析各有独立总开关，出厂均为关闭**（「播放设置 → 嗅探设置」）：关掉后网页地址走内嵌播放器打开，
  不再自动嗅探/送解析接口
- **缓存管理覆盖全部模块**（含海阔文件区/自带资源/远端依赖、网页的同步游标、RSS 响应体）
- TMDB 智能刮削
- 弹幕（Ticker 单 Canvas 直绘，活跃上限 60，支持补播与屏蔽设置）
- 投屏（DLNA/UPnP）
- **设置项落盘兜底**：写完即 `synchronize()` 落 plist + 独立文件镜像（`prefs_mirror.json` / `reading_state.bak`），进程被硬杀也能恢复

---

## 📦 平台支持

| 平台 | 状态 | Node.js 集成方式 | 安装包 |
|---|---|---|---|
| **iOS（巨魔）** | ✅ **主要成品** | 嵌入 [NodeMobile.xcframework](https://github.com/nodejs-mobile/nodejs-mobile) v18.20.4 + CPython 3.12 | TrollStore IPA（ldid 伪签） |
| **Windows** | 🔧 开发机 | `Process.start(node.exe)` + 按需下载 | Inno Setup `.exe` |
| **Android** | ⏳ 架构占位 | 待补 libnode.a + JNI 桥 | — |

> **设计取舍**：iOS 沙盒拒绝任意可执行文件，必须用 Apple 接受的 [NodeMobile](https://github.com/nodejs-mobile/nodejs-mobile) framework；Python 源走 [BeeWare Python-Apple-support](https://github.com/beeware/Python-Apple-support)（3.12-b11）。Windows 用 `.node.exe` 只为在开发机上提前发现 bug（跨端共用同一套 Node.js 业务代码）。

---

## 🏗️ 架构

```
┌──────────────────────────────────────────────────────────────────┐
│  Flutter / Dart（跨端统一）                                        │
│                                                                  │
│  影视 · 直播 · 音乐 · 阅读 · RSS · 网页(Webhtv) · 海阔 · 程序 · 设置   │
│                                                                  │
│  ┌──────────────┐ ┌───────────────┐ ┌──────────────────────────┐ │
│  │ NodeJSManager│ │ PythonManager │ │ 播放内核 (AppPlayer 抽象) │ │
│  │ 平台分派      │ │ 脚本源执行     │ │ AVPlayer/KSPlayer/MPV/Web │ │
│  └──────┬───────┘ └──────┬────────┘ └────────────┬─────────────┘ │
└─────────┼────────────────┼───────────────────────┼───────────────┘
          │ MethodChannel  │ MethodChannel         │ MethodChannel
┌─────────▼────────────────▼───────────────────────▼───────────────┐
│  iOS Runner (Swift)                                              │
│  NodeJSBridge    PythonBridge     KSEngine / AvEngine / PipManager│
│  ↓ node_start()  ↓ Py_Initialize  ↓ KSPlayerLayer / AVPlayer / PiP│
└──────────────────────────────────────────────────────────────────┘
```

iOS 关键原生文件：

- [ios/Runner/NodeJSBridge.swift](ios/Runner/NodeJSBridge.swift) — 调 `node_start(argc, argv)`
- [ios/Runner/PythonBridge.swift](ios/Runner/PythonBridge.swift) — 内嵌解释器 + 看门狗（脚本超时自杀，带 GIL 守卫）
- [ios/Runner/KSEngine.swift](ios/Runner/KSEngine.swift) — FF/KSPlayer 播放层（全局唯一，含构建期补丁加固）
- [ios/Runner/AvEngine.swift](ios/Runner/AvEngine.swift) — AVPlayer 内核
- [ios/Runner/PipManager.swift](ios/Runner/PipManager.swift) — 画中画
- [ios/scripts/add_nodemobile.rb](ios/scripts/add_nodemobile.rb) — ruby `xcodeproj` 自动 link + embed NodeMobile

Dart 端 Node 平台分派：[nodejs_platform.dart](lib/services/nodejs_platform.dart) 及三个实现（[windows](lib/services/nodejs_platform_windows.dart) / [ios](lib/services/nodejs_platform_ios.dart) / android 占位）。

### 双引擎说明

- **Node.js 引擎**：`assets/nodejs-project/src/*` 经 esbuild 打包成 `dist/main.js`，跑 TVBox 爬虫 / 书源 / 音乐插件源（洛雪、MusicFree）/ 网盘工具 / **海阔规则（`hiker_engine.js`）**。**改动只能改 `src/`，`dist/` 由 CI 重新构建**。
- **CPython 引擎**：`assets/python-project/`（`spider_runner.py` + 适配层），把 catvod 风格 Python 源映射到本项目五接口；第三方 C 扩展依赖（lxml / pyquery / pycryptodome）用**纯 Python 垫片**解决。

---

## 🚀 快速开始

### 前置依赖

- Flutter 3.24.0+（[stable channel](https://docs.flutter.dev/release/archive)），Dart 3.12.0+
- **iOS 端额外**：[TrollStore](https://github.com/opa334/TrollStore) 装到设备
- **Windows 端额外**：[Media Player](https://support.microsoft.com/en-us/windows/media-player)（libmpv 运行时需要）

### 本地运行

```bash
flutter pub get
flutter run -d windows      # 开发机调试
flutter run -d ios          # 需要 macOS + Xcode
```

### 第一次使用

1. 启动 App → 若无订阅，进入「设置 → 数据源」填写 TVBox 订阅地址（或扫码 / 本地文件导入）
2. 订阅加载出源列表后选一个主页源即可浏览
3. 直播源随订阅首次导入（之后以本地为准）、小程序在「程序」页导入

---

## 📦 打包

### iOS 巨魔 IPA（CI 自动构建）

触发 [.github/workflows/ios.yml](.github/workflows/ios.yml)：**push 到 `main` / `v*` tag、PR、或手动 `workflow_dispatch`**。

工作流会：

1. checkout → setup Flutter (stable) → `pub get`
2. **esbuild** 打包 `assets/nodejs-project/src/*` → `dist/main.js`（+ `.md5`）
3. 下载并嵌入 **NodeMobile.xcframework**（v18.20.4）
4. 下载并嵌入 **CPython 3.12-b11**（BeeWare Python-Apple-support）
5. `flutter build ios --release --no-codesign`
6. 嵌入 Node / Python 运行时 → `Runner.app`
7. `ldid` 伪签主 app + framework
8. 打包 IPA（`tvbox-ios-<short_sha>.ipa`）→ 上传 artifact

下载 IPA 丢进 TrollStore 即可安装。

### Windows 自包含安装器

```bash
flutter build windows --release
# 安装器工具在 tools/installer/Installer.cs（详见 tools/installer/README.md）
```

---

## 🛠️ 技术栈

| 层级 | 选型 |
|---|---|
| UI 框架 | Flutter 3.24+（Dart 3.12+） |
| 状态管理 | [GetX](https://pub.dev/packages/get) |
| 网络 | [Dio](https://pub.dev/packages/dio) + 全局代理适配 |
| 本地存储 | [Hive CE](https://pub.dev/packages/hive_ce) + `shared_preferences` |
| 播放（iOS 主） | `video_player`（AVPlayer） |
| 播放（全格式） | KSPlayer（FFmpeg + Metal，构建期补丁加固） |
| 播放（备用） | [media_kit](https://github.com/media-kit/media-kit) 1.1 + libmpv |
| 网页/嗅探 | `webview_flutter` |
| 海阔规则引擎 | Node + `node:vm` + cheerio（`assets/nodejs-project/src/hiker_engine.js`，语义对齐官方 hikerView 源码） |
| 书源 JS 引擎 | `quickjs_engine`（vendor 到 `packages/`） |
| Node.js 嵌入 | [NodeMobile](https://github.com/nodejs-mobile/nodejs-mobile) v18.20.4 |
| Python 嵌入 | [BeeWare Python-Apple-support](https://github.com/beeware/Python-Apple-support) 3.12-b11 |
| 巨魔伪签 | [ldid](https://github.com/saurik/ldid) |
| pbxproj 自动化 | ruby [xcodeproj](https://github.com/CocoaPods/Xcodeproj) |

---

## 🤝 贡献

- 修改后 `flutter analyze` 必须 **0 error**
- Node 业务代码只改 `assets/nodejs-project/src/`，**不要手改 `dist/`**（CI 会重新构建）
- 新增阅读设置项时记得同步 [prefs_mirror.dart](lib/services/prefs_mirror.dart) 的白名单前缀
- 涉及原生（iOS）改动请在真机验证

---

## 📜 许可证

[MIT](LICENSE)

---

## 🙏 致谢

- [media_kit](https://github.com/media-kit/media-kit) — Flutter 视频播放
- [KSPlayer](https://github.com/kingslay/KSPlayer) — iOS 全格式播放
- [NodeMobile](https://github.com/nodejs-mobile/nodejs-mobile) — iOS 端 Node.js 嵌入
- [BeeWare Python-Apple-support](https://github.com/beeware/Python-Apple-support) — iOS 端 CPython
- [TrollStore](https://github.com/opa334/TrollStore) — 巨魔 IPA 安装
- [ldid](https://github.com/saurik/ldid) — ad-hoc 伪签
- [Legado（阅读）](https://github.com/gedoor/legado) — 书源 / RSS 规则规范
- [hikerView（海阔视界）](https://github.com/qiusunshine/hikerView) — 海阔小程序的 JS API 语义（`help_js.json`）、
  沙箱约定与 App 自带资源（`home.js` / `theme.js` / `css.js` …）
- [tvbox 社区](https://github.com/qist/tvbox) — TVBox 爬虫生态
