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
  /// ── 顺序是**实测**出来的，不是猜的 ──────────────────────────
  /// 2026 实测（`POST /eapi/book/search`，带浏览器 UA，12s 超时）：
  ///
  ///   z-library.website   200  1.09s  {"success":1,"books":[...]}   ✅
  ///   zh.z-lib.gd         200  1.44s  {"success":1,...}             ✅ 中文
  ///   z-library.gy        200  1.79s  {"success":1,...}             ✅
  ///   zh.zlib.li          200  1.98s  {"success":1,...}             ✅ 中文
  ///   z-library.qa        200  2.56s  {"success":1,...}             ✅
  ///   ── 以下根路径可用但 eapi 走 307（应用会跟随重定向）──
  ///   z-library.im                307  0.74s
  ///   z-lib.fm                    307  0.78s
  ///   z-lib.sk                    307  0.82s
  ///   zh.z-library.sk             307  1.28s
  ///   ── 反向对照 ──
  ///   zh.intcn.online     200  1.12s  返回 **HTML 不是 JSON**（不是真 API）
  ///   zh.zlibrary.by      503 15.75s  ❌ 旧默认值，已彻底不可用
  ///
  /// ⚠️ 所以"根路径 200"**不等于能用** —— `zh.intcn.online` 就是反例。
  /// 上面把**实测能返回真数据**的排在前面，307 的排后面，
  /// 已知不可用的 [zLibraryApiUrl] 垫底（保留是为了兼容老配置的读取路径）。
  ///
  /// 节点失效也没关系 —— 探测失败的会被跳过；
  /// 运行时若发生 301/302 重定向，新域名会自动追加进来。
  static const List<String> zLibraryDefaultDomains = [
    // ① 实测能返回真数据（按延迟升序）
    'z-library.website',
    'zh.z-lib.gd',
    'z-library.gy',
    'zh.zlib.li',
    'z-library.qa',
    // ② 根路径可用、eapi 走 307（应用会跟随）
    'z-library.im',
    'z-lib.fm',
    'z-lib.sk',
    'zh.z-library.sk',
    // ③ 已知不可用，仅作最后兜底
    'zh.zlibrary.by',
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

  /// GitHub 仓库地址（关于页 + 检查更新）
  static const String githubUrl = 'https://github.com/hlning/cmbok_app';

  /// 「甜甜的小站」博客地址（我的页 + 更新弹窗）
  static const String blogUrl = 'https://bluemood.xiaomy.net/';

  /// GitHub Releases 最新版本接口（检查更新）
  static const String latestReleaseApiUrl =
      'https://api.github.com/repos/hlning/cmbok_app/releases/latest';

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
