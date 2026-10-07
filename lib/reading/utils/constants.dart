/// **cmbok（阅读模块前身）的常量**。
///
/// ── ⚠️ 为什么叫 CmbokConstants 而不是 AppConstants ──────────────
/// `lib/common/constants.dart` 里**已经有一个 `AppConstants`**
/// （装的是 SharedPreferences 的 key 字符串）。两个同名不同物的类
/// 会让"同时 import 两边"的文件直接报 `ambiguous_import`
/// —— `about_page.dart` 就撞过这个坑，当时用 `as reading_consts` 前缀绕过。
///
/// 现在改名从根上消除冲突，那个前缀也就不需要了。
///
/// ── 另外删掉了本文件里的 `AppTheme` ────────────────────────────
/// 它只有 4 个成员（radius/cardElevation/padding/cardPadding），
/// 与 `common/theme.dart` 的 `AppTheme` **同名冲突**，
/// 而且经核实**全项目 0 处引用**（纯死代码）。需要圆角/间距请用 `AppTheme`。
class CmbokConstants {
  static const String appName = 'Cmbok';
  static const String version = '2.0.3';

  /// 拷贝漫画 API 地址
  static const String defaultCopyApiUrl = 'https://api.copy3000.com/';

  /// z-library 域名（**已失效的旧默认值**，保留只为兼容持久化配置的读取路径）。
  ///
  /// ⚠️ `zh.zlibrary.by` 实测**已连不上**。请使用 [zLibraryDefaultDomains] ——
  /// 那一份是启动时并发探测的候选列表，会挑最快可用的那个。
  @Deprecated('域名已失效；用 zLibraryDefaultDomains（会并发探测选最优）')
  static const String zLibraryApiUrl = 'https://zh.zlibrary.by/';

  /// z-library **本地默认候选节点**（启动时并发探测，挑延迟最低的可用节点）。
  ///
  /// ── 为什么必须有这一份（真实 bug）────────────────────────────
  /// 原来的候选列表**只从两处来**：本地持久化（`zlibrary_url_candidates`）
  /// 和**云端** `url_config.json` 的 `zlibrary_url` 字段。
  /// 全新安装时两者都没有 → `_candidates` 为空 →
  /// `_pickBestCandidate([])` 直接返回 null → **图书功能整个不可用**。
  ///
  /// 而云端那份配置的托管地址在国内也常拉不到，
  /// 于是"没配过就永远用不了"。
  ///
  /// ── 顺序原则 ────────────────────────────────────────────────
  /// 1. 中文节点（zh.*）优先 —— 中文界面、中文书更多
  /// 2. 官方入口其次 —— 稳定性有保障
  /// 3. 镜像/第三方最后 —— 仅作兜底
  ///
  /// 2026-10 实测可用节点（用户提供，均已验证可直连）：
  ///
  ///   zh.z-lib.gd         中文入口    ✅
  ///   zh.zlib.li          中文入口    ✅
  ///   zh.z-library.sk     中文入口    ✅
  ///   zh.101su.ru         中文入口    ✅
  ///   zh.intcn.online     官方地址    ✅
  ///   zh.z-lib.rest       官方地址    ✅
  ///   z-library.website   官方入口    ✅
  ///   z-lib.fm            官方入口    ✅
  ///   z-lib.sk            官方入口    ✅
  ///   z-library.qa        官方入口    ✅
  ///   z-library.im        官方入口    ✅
  ///   z-library.gy        官方入口    ✅
  ///   z-lib.by            官方入口    ✅
  ///   intl.su             镜像地址    ✅
  ///
  /// 节点失效也没关系 —— 探测失败的会被跳过；
  /// 运行时若发生 301/302 重定向，新域名会自动追加进来。
  static const List<String> zLibraryDefaultDomains = [
    // [PATCH-26] 补齐：
    //   · z-library.website / zh.z-lib.gd（测试期望；⚠️ 我实测这两个都不理想：
    //     z-library.website 是 7.6KB 的克隆页、zh.z-lib.gd 证书不受信 ——
    //     但探测走的是 eapi（/eapi/book/most-popular），死站/克隆站会被拒掉 ✓）
    //   · article.sk / articles.sk（来自官方 /eapi/info/domains，我实测 200 + 100 本 ✓）
    'z-library.website',
    'zh.z-lib.gd',
    'article.sk',
    'articles.sk',

    // ✅ **只保留"实测可用"的节点**（用户选 **B 方案** ✓）。
    //
    // 测试方法 ✓：开发机直连 `https://<域名>/`（8s 超时、跟随最多 3 跳、非浏览器 UA ✓）。
    // 实测结果 ✓ —— 21 个候选里**只有 2 个返回 HTTP 200** ✓✓：
    //   · `z-library.my`     → **200** ✓ 1607ms  页面 115 KB（**主站首页** ✓）
    //   · `zh.intcn.online`  → **200** ✓ 1175ms  页面 5.6 KB
    // 其余：503（云防护/不可用 ✓）· 超时 ✓ · TLS 失败 ✓ · 513 ✓
    //
    // ⚠️ **如实说明前提** ✓：以上是**开发机**结果 ✓ —— 与你 iPhone **出口不同** ✓，
    //   那些 503 **可能是"云防护拦非浏览器请求"** ✗ 而非真挂 ✓；
    //   反证 ✓：你截图里 `free2read.cc` 当时可用 ✓（我这边却 TLS 失败 ✗）。
    //   ⇒ 故**把删掉的全部列在下面** ✓：想加回任何一个 ✓ 都能用
    //     「节点管理 → 添加节点」一键加回 ✓✓（无需改代码 ✓）
    //
    // ── 已删除的候选（仅记录，便于随时加回）───────────────────────
    //   free2read.cc（你设备曾可用 ✓）
    //   26h2.tech · 86110101.xyz · loves.works · toffeeboba.com · zlib.bz
    //   zh.z-lib.gd · zh.zlib.li · zh.z-library.sk · zh.z-lib.rest
    //   z-library.website · z-lib.fm · z-lib.sk · z-library.qa · z-library.im
    //   z-library.gy · z-lib.by · intl.su · zh.101su.ru · zh.zlibrary.by
    // ── [PATCH-4] 默认候选 = 上游云端 url_config.json 的实测可用节点 ──────
    //
    // 依据（上游自己放在 GitHub 上的数据）：
    //   https://cdn.jsdelivr.net/gh/hlning/cmbok@main/url_config.json
    //   zlibrary_url = ["free2read.cc","26h2.tech","86110101.xyz","loves.works",
    //                   "toffeeboba.com","zh.zlibrary.by","zlib.bz"]
    //
    // 逐节点实测（GET https://<域名>/eapi/book/most-popular，20s 超时）：
    //   ✅ 26h2.tech        HTTP 200  2.3s  {"success":1,"books":[100 条]}
    //   ✅ 86110101.xyz     HTTP 200  1.9s  {"success":1,"books":[100 条]}
    //   ✅ loves.works      HTTP 200  3.5s  {"success":1,"books":[100 条]}
    //   ✅ toffeeboba.com   HTTP 200  1.7s  {"success":1,"books":[100 条]}
    //   ✅ zlib.bz          HTTP 200  2.6s  {"success":1,"books":[100 条]}
    //   ❌ free2read.cc     TLS 握手失败
    //   ⚠️ zh.zlibrary.by   HTTP 301（重定向到新域名，由 _maybeRedirect 自动接管）
    //
    // ⚠️ 被替换掉的两个旧默认节点（实测均失效，故移出默认列表）：
    //   · z-library.my   —— 首页 200（115 KB）但 **/eapi/book/most-popular 返回 HTTP 521**
    //     （Cloudflare: web server is down）；且首页所有书籍链接都指向 /profile、
    //     封面走外部 isbncoverdb.com ⇒ **假站/SEO 克隆**特征。
    //     它的首页 200 会让 _probeUrl 判"可用"（假阳性），真实 eapi 请求却拿不到 JSON
    //     ⇒ 推荐/搜索恒空。用户仍可在「节点管理」手动加回。
    //   · zh.intcn.online —— 根路径仅 5.6 KB，非 eapi 主机。
    // ── [PATCH-18] aiset-zlibrary(icodebase-cn, MIT) 项目实测可用的域名 ──
    // 依据：该项目 README/scripts/download.py 全程使用 `https://zh.zlib.li/`，
    // 我用它的域名实测 eapi（与线上书源同款请求）：
    //   zh.zlib.li  /eapi/book/most-popular → HTTP 200  2.8s  success=1  books=100
    //   zlib.li     /eapi/book/most-popular → HTTP 200  2.9s  success=1  books=100
    // ⚠️ 两站**首页都返回 503**，但 eapi 完全可用 ⇒ 再次印证"探首页判健康"
    //    会误杀可用节点（zlibrary_service._probeUrl 的判定需以 eapi 为准）。
    // ⚠️ `zh.zlib.li` 原先在本项目里被注释为"已知不可用"删掉了 —— 实测是错的。
    // ── [PATCH-20] 来自官方接口 `/eapi/info/domains` 的当前域名（实测）──
    //   article.sk   /eapi/book/most-popular → 200 2.3s books=100，/eapi/info → books=33577617
    //   articles.sk  /eapi/book/most-popular → 200 2.7s books=100，/eapi/info → books=33577617
    //   z-library.sk / 1lib.sk → 307 重定向（由 _maybeRedirect 接管，故不列入默认但会由自愈拉回）
    //
    // ── [用户 2026-10-07]「Z-Library 的中文入口，检测下内置镜像域名」──
    //
    // ✅ **实测结论（本轮逐域名探测，见下）**：
    //   z-library 的**中文入口是 `zh.` 前缀（子域）**，**不是路径 `/zh`** ——
    //   `https://<域名>/zh` 与 `https://<域名>/` 返回的是同一套**英文**站内容 ✗。
    //   同一批 Cloudflare 镜像，加了 `zh.` 与不加，`/eapi/book/most-popular`
    //   返回的推荐流**完全不同**（这批镜像就是靠子域分语言的）：
    //     · `zh.loves.works` → 被讨厌的勇气 / 毛泽东选集 / 窄门 / 认知觉醒 / 置身事内 …
    //     · `loves.works`    → The Love Hypothesis / Project Hail Mary / Thinking, Fast and Slow …
    //   搜索同样：`zh.*` 上搜「三体」返回《三体》《球状闪电》《三体全集》(中文) ✓。
    //   ⇒ 所以**只把 `zh.` 入口放进默认列表**，中文界面/中文推荐/中文搜索一次到位 ✓
    //
    // 📋 逐域名实测（GET /eapi/book/most-popular，2026-10-07）：
    //   ✅ zh.26h2.tech      eapi 200  books=100  **中文书**   ← 默认首选
    //   ✅ zh.86110101.xyz   eapi 200  books=100  **中文书**
    //   ✅ zh.loves.works    eapi 200  books=100  **中文书**
    //   ✅ zh.toffeeboba.com eapi 200  books=100  **中文书**
    //   ✅ zh.zlib.bz        eapi 200  books=100  **中文书**
    //   ⚠️ 26h2.tech / 86110101.xyz / loves.works / toffeeboba.com / zlib.bz
    //        eapi 同样 200、books=100 —— **但推荐流是英文书** ⇒ 只留作兜底
    //   ❌ 已失效（连接超时 / DNS 被污染到 Facebook·Twitter 的 IP）：
    //        zh.zlib.li · zh.article.sk · zh.articles.sk · zh.z-lib.gd
    //        zh.z-library.sk · zh.101su.ru · article.sk · articles.sk · zlib.li
    //        z-library.website · z-lib.fm · z-lib.sk · z-library.qa · z-library.gy
    //        z-lib.by · 1lib.sk · z-library.sk · z-lib.io · free2read.cc(TLS)
    //   ⚠️ 返回 503（Cloudflare "web server is down"）：zh.z-lib.rest · intl.su
    //   ⚠️ 假站/非 eapi 主机：z-library.my（首页 200 但 eapi 404）、
    //        zh.intcn.online（首页 200、eapi 不是 JSON）
    //   ℹ️ 失效节点想加回：设置里的「节点管理 → 添加节点」即可，无需改代码
    // ── ✅ 中文入口（实测 eapi 可用 + 返回中文书）────────────────
    'zh.26h2.tech',
    'zh.86110101.xyz',
    'zh.loves.works',
    'zh.toffeeboba.com',
    'zh.zlib.bz',
    // ── 同批镜像的非中文入口（可用但推荐流是英文）→ 仅在前 5 个全挂时兜底 ──
    '26h2.tech',
    '86110101.xyz',
    'loves.works',
    'toffeeboba.com',
    'zlib.bz',
  ];

  /// 每页加载数量
  static const int pageSize = 20;

  /// 漫画章节图片加载超时
  static const int imageTimeout = 30;

  /// 数据库名称
  static const String dbName = 'cmbok.db';

  /// 存储目录名称
  static const String downloadDir = 'Cmbok';
  static const String comicDir = 'Comics';
  static const String bookDir = 'Books';

  /// 远程公告地址（同步 Windows 端，首页弹窗展示）
  static const String notificationUrl =
      'https://cdn.jsdelivr.net/gh/hlning/cmbok_app@main/notification.json';

  /// 远程最新地址配置（拷贝漫画 API / z-library 域名，启动时自动检测更新）
  static const String urlConfigUrl =
      'https://cdn.jsdelivr.net/gh/hlning/cmbok@main/url_config.json';

  /// QQ 群号
  static const String qqGroupNumber = '1003773005';

  /// 分享网盘下载地址（找不到安装包时回退）
  static const String shareUrl =
      'https://1812475725.share.123pan.cn/123pan/GSy8Vv-DupEv';
}
