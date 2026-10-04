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
    // ⓪ 原版 Cmbok 实测可用节点（用户设备当前节点 86110101.xyz 验证可直连，
    // 候选顺序照抄原版 zlibrary_url_candidates 持久化配置）——**必须排最前**，
    // 否则全新安装会先试下面那些旧节点，全部超时 → 图书页"节点有问题"。
    'free2read.cc',
    '26h2.tech',
    '86110101.xyz',
    'loves.works',
    'toffeeboba.com',
    'zh.zlibrary.by',
    'zlib.bz',
    // ① 中文节点优先（界面中文、中文书更多）
    'zh.z-lib.gd',
    'zh.zlib.li',
    'zh.z-library.sk',
    'zh.101su.ru',
    'zh.intcn.online',
    'zh.z-lib.rest',
    // ② 官方通用入口
    'z-library.website',
    'z-lib.fm',
    'z-lib.sk',
    'z-library.qa',
    'z-library.im',
    'z-library.gy',
    'z-lib.by',
    // ③ 镜像兜底
    'intl.su',
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
}
