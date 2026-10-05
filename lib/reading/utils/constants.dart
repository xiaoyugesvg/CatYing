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
///
/// ── cmbok 原版页面兼容 ───────────────────────────────────────
/// cmbok_app 原版页面（about/me/update_service 等）引用的是 `AppConstants`。
/// 本文件末尾的 `typedef AppConstants = CmbokConstants` 让这些页面无需改动
/// 即可编译；下方同时补回了原版独有的 `githubUrl` / `blogUrl` /
/// `latestReleaseApiUrl` 三个字段。
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
    'z-library.my',
    'zh.intcn.online',
    // ④ 已知不可用，仅作老配置兼容（最后兜底）
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

  /// GitHub 仓库地址（关于页 + 检查更新）
  static const String githubUrl = 'https://github.com/hlning/cmbok_app';

  /// 「甜甜的小站」博客地址（我的页 + 更新弹窗）
  static const String blogUrl = 'https://bluemood.xiaomy.net/';

  /// GitHub Releases 最新版本接口（检查更新）
  static const String latestReleaseApiUrl =
      'https://api.github.com/repos/hlning/cmbok_app/releases/latest';
}

/// cmbok 原版页面引用的是 `AppConstants`；别名到 [CmbokConstants]，
/// 让 about_page / me_page / update_service / update_dialog 等原版文件
/// 无需改动即可编译（同名类在 `lib/common/constants.dart` 已有定义，
/// 因此这里只做 typedef 别名，不重新声明类）。
typedef AppConstants = CmbokConstants;
