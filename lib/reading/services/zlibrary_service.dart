import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as html_element;
import 'package:html/parser.dart' as html_parser;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/book.dart';
import '../models/book_category.dart';
import '../models/search_result.dart';
import '../source/webview_image_fetcher.dart';
import '../source/global_proxy.dart';
import '../utils/source_fail_text.dart';
import 'builtin_accounts.dart';
import 'remote_config_service.dart';
import 'settings_service.dart';
import '../utils/constants.dart';

void _log(String message) {
  if (kDebugMode) debugPrint('[Zlibrary] $message');
}

/// z-library 下载链接信息（对应 cmbook Zlibrary.getDownloadLink 返回）
class DownloadLink {
  final String filename;
  final String url;
  final Map<String, String> headers;
  const DownloadLink({
    required this.filename,
    required this.url,
    required this.headers,
  });
}

/// z-library 业务异常
class ZlibraryException implements Exception {
  /// no_account / no_login / unavailable / quota_exceeded / rate_limited / fail
  final String code;
  final String message;
  ZlibraryException(this.code, this.message);
  @override
  String toString() => 'ZlibraryException($code): $message';
}

/// verifyToken 复校结果：valid=token 有效 / invalid=token 失效 / unavailable=地址不可用
enum _TokenState { valid, invalid, unavailable }

/// z-library 登录/注册/搜索/下载链接服务 + 每日限额（单例 ChangeNotifier）
/// 对应 cmbook service/zlibrary_client.py + service/cmbok_service.py 图书部分。
/// 已登录自有账号时优先用自有 token，否则轮询内置账号。
class ZlibraryService extends ChangeNotifier {
  ZlibraryService._() {
    // ── 🔴 懒初始化（修"图书功能开箱即不可用"）──────────────────────
    //
    // 原来 [init] **全项目没有任何调用点**（只在 main.dart 之外被定义），
    // 于是 `_domain` 与 `_candidates` 一直是初始值（空串 / 空表）。
    // 而所有请求都走 `_send()` → `_candidateOrder()`：
    //   候选为空 → 内层 for 一次都不进 → 直接 `_setUnavailable(true)`
    //   → 返回 `{success:false, unavailable:true}`
    //   → UI 显示"所有 z-library 节点不可用，图书功能暂不可用"
    //
    // **图书搜索 / 登录 / 下载全部走这条路，所以整个图书功能都是死的。**
    //
    // 现在：单例一被构造就触发一次（fire-and-forget），
    // 且 `init()` 里会先把本地默认候选写进 `_candidates`，
    // 让"构造完就能发请求"，随后探测结果再替换成最快节点。
    _bootstrap();
  }

  /// 懒初始化入口（只跑一次）。构造时自动调用。
  void _bootstrap() {
    if (_bootstrapped) return;
    _bootstrapped = true;
    // 立即播种：让构造完的**第一个请求**就有域名可用（不等探测）
    if (_candidates.isEmpty) {
      _candidates.addAll(CmbokConstants.zLibraryDefaultDomains);
    }
    if (_domain.isEmpty && _candidates.isNotEmpty) {
      _domain = _candidates.first;
    }
    // 读持久化 + 探测选最优（异步，不阻塞构造）
    unawaited(init());
  }

  static final ZlibraryService _instance = ZlibraryService._();
  factory ZlibraryService() => _instance;

  static const _kDomain = 'zlibrary_domain';
  static const _kEmail = 'zlibrary_email';
  static const _kUsername = 'zlibrary_username';
  static const _kRemixUserid = 'zlibrary_remix_userid';
  static const _kRemixUserkey = 'zlibrary_remix_userkey';
  /// [PATCH-21] 网页登录会话的完整 Cookie 串（留档；登录态本身靠上面两个键）
  static const _kWebSession = 'zlibrary_web_session';

  /// 内置账号全局每日限额 / 自有账号每日限额（对应 cmbook BUILTIN_DAILY_LIMIT / LOGGED_DAILY_LIMIT）
  static const int builtinDailyLimit = 5;
  static const int loggedDailyLimit = 10;
  static const _kBuiltinCount = 'zlibrary_builtin_count'; // JSON {date, count}

  /// 候选节点列表（启动探测写回 + 运行时重定向发现新域名追加；JSON [domain,...]）
  static const _kCandidates = 'zlibrary_url_candidates';
  static const _kCategories =
      'zlibrary_categories'; // JSON [{title,children:[{id,slug,zhName}]}]
  static const _kMaxRetries = 3; // 429/5xx 同域名退避重试次数
  // [PATCH-4] 退避重试的状态码。
  //
  // ⚠️ 必须包含 **Cloudflare 系 5xx**（520/521/522/523/524/525/527）：
  //   镜像挂掉时 Cloudflare 返回的是 **521**（web server is down），而旧集合只有
  //   {429,500,502,503,504} ⇒ 521 不在其中 ⇒ 落到 _send 末尾的"业务响应"分支
  //   （`return _asJsonMap(resp.data)`）⇒ 去解析 Cloudflare 的错误 HTML ⇒ 0 条，
  //   而且**永远不会切到下一个候选**。
  //   实测：旧默认节点 z-library.my 的 /eapi/book/most-popular 正是返回 521。
  //   加入后：521 退避重试到上限，再走 `status != 429` 分支**切下一候选** ✓。
  static const _kRetryStatus = {
    429,
    500, 502, 503, 504,
    520, 521, 522, 523, 524, 525, 527,
  };
  static const _kHealthInterval = Duration(hours: 1);

  static const _browserUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/110.0.0.0 Safari/537.36';

  /// ✅ **创建 z-library 请求用的 Dio，并挂上「全局网络代理」**（本轮接上 ✓）。
  ///
  /// 为什么要有它 ✗：本项目原来**只有** `config_book_source` ✓ 与 `config_manga_source` ✓
  /// 两处挂了代理 ✗，而 **z-library（图书）这一整条链路都是直连** ✗✓ ——
  /// 于是用户开了「网络代理」却发现**图书照样连不上** ✓（"代理没用"的典型体感 ✓）。
  /// 写法**逐字照搬 `config_book_source.dart:86-101`** ✓✓ —— 不发明新机制 ✗。
  /// `applyGlobalProxy` 内部**先看开关** ✓：关着直接返回 false ✓ **连适配器都不换** ✓✓
  /// （也就是"**不影响其他功能及网络**"✓：它是**逐实例**换适配器 ✓，
  ///   不设系统代理 ✗、不用 `HttpOverrides` ✗、影视/音乐完全不受影响 ✓✓）。
  Dio _createDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 30),
        followRedirects: false, // 手动处理 301/302 以更新并持久化域名
        responseType: ResponseType.plain, // 自行 jsonDecode，规避 Cloudflare HTML 页抛异常
        validateStatus: (_) => true, // 不按状态码抛异常，自行判断
      ),
    );
    applyGlobalProxy(dio);
    return dio;
  }

  late final Dio _dio = _createDio();

  String _domain = ''; // 不含 scheme，如 zh.zlibrary.by

  /// 是否已跑过 [init]（懒初始化只跑一次）
  bool _bootstrapped = false;

  /// [_domain] 是否来自**用户的持久化设定**（而非懒初始化播种）。
  /// 只有用户设定过才阻止本地探测选优。
  bool _domainPersisted = false;

  /// 是否启用「定时健康检查」（默认开）。
  ///
  /// widget 测试里请设为 `false` —— 否则 `Timer.periodic` 会在测试结束时报
  /// `A Timer is still pending even after the widget tree was disposed`。
  /// ⚠️ 仅供测试使用，业务代码不要动它。
  @visibleForTesting
  static bool healthTimerEnabled = true;
  String _email = '';
  String _username = '';
  String _remixUserid = '';
  String _remixUserkey = '';

  /// 自有账号服务端每日下载限额（来自 /eapi/user/profile；null=未取到，回退硬编码）
  int? _serverDownloadsLimit;

  /// 自有账号服务端今日已下载数（来自 /eapi/user/profile，纯服务端判定，不落盘）。
  /// 每次重启 App 由 refreshUserProfile() 重新拉取；自登账号不使用本地计数。
  int _serverDownloadsToday = 0;

  /// 分类页书的 eapi 匹配缓存（bookId -> 匹配到的带 eapi hash 的 Book）。
  /// 会话级内存缓存，避免同一本分类书重复点击反复发 eapi 搜索。不落盘。
  final Map<String, Book> _categoryMatchCache = {};

  /// 内置账号 token 缓存（避免每次搜索都重新登录）
  String? _builtinUserid;
  String? _builtinUserkey;

  /// 候选节点列表（启动探测写回 + 运行时重定向发现新域名追加）
  List<String> _candidates = [];

  /// 地址是否不可用（全候选连接失败/404）；仅状态变化才 notify
  bool _unavailable = false;

  /// 定时健康检查（复用本地候选探测，30 分钟一次）
  Timer? _healthTimer;

  /// 已应用的云端 zlibrary_url（去重，避免 RemoteConfig 重复通知触发重复探测）
  Object? _lastAppliedCloud;

  /// 本次取下载链接是否检测到额度用完（disallowDownloadMessage 含 limit）
  bool _quotaExceeded = false;

  String get domain => _domain;

  /// 是否已经配置了可用的服务器地址。
  ///
  /// 为什么要这个判断：cmbok 的域名来自**云端配置下发**
  /// （`RemoteConfigService.cloudZlibraryUrl`），猫影没有那个服务，
  /// 所以首次使用时 `_domain` 是空的 —— 此时所有图书接口都不可用。
  /// 用户必须自己填一个地址才能用（见 `zlibrary_auth_page` 的服务器设置）。
  bool get hasDomain => _domain.trim().isNotEmpty;

  /// 手动设置 Z-Library 服务器地址。
  ///
  /// 接受多种写法：`zh.zlibrary.by` / `https://zh.zlibrary.by/` /
  /// `https://zh.zlibrary.by/somepath` —— 统一归一化成 `host` 形式
  /// （服务内部拼 URL 时用 `https://$_domain$path`）。
  ///
  /// 传空字符串 = 清除（回到"未配置"状态）。
  Future<bool> setDomain(String raw) async {
    var s = raw.trim();
    if (s.isEmpty) {
      _domain = '';
      await _persistDomain();
      notifyListeners();
      return true;
    }
    // 去掉 scheme
    if (s.startsWith('http://')) {
      s = s.substring('http://'.length);
    } else if (s.startsWith('https://')) {
      s = s.substring('https://'.length);
    }
    // 去掉路径与查询
    final slash = s.indexOf('/');
    if (slash >= 0) s = s.substring(0, slash);
    s = s.trim();
    if (s.isEmpty || !s.contains('.')) {
      return false; // 明显不是域名
    }
    _domain = s;
    await _persistDomain();
    notifyListeners();
    return true;
  }

  /// 探测地址是否可达（登录页"测试连接"用）。
  ///
  /// 只做一次 GET，判断能不能拿到 HTML —— 不验证账号，
  /// 目的是区分"地址填错了"和"账号密码错了"，否则用户无法判断问题在哪。
  Future<({bool ok, String message})> probeDomain(String raw) async {
    final saved = _domain;
    final okSet = await setDomain(raw);
    if (!okSet) return (ok: false, message: '地址格式不对（应形如 zh.zlibrary.by）');
    try {
      final res = await _dio.get(
        'https://$_domain/',
        options: Options(
          followRedirects: true,
          validateStatus: (c) => c != null && c < 500,
          receiveTimeout: const Duration(seconds: 12),
          sendTimeout: const Duration(seconds: 12),
        ),
      );
      if (res.statusCode == 200) {
        return (ok: true, message: '连接成功（$_domain）');
      }
      return (ok: false, message: '服务器返回 HTTP ${res.statusCode}');
    } catch (e) {
      _domain = saved; // 探测失败就回滚，别把用户配好的地址弄坏
      await _persistDomain();
      // ✅ **把异常翻成人话**（本轮 ✓）—— 原来直接拼 `e.toString()` ✗，
      //   于是节点面板/登录页显示的就是截图上那句「**连不上：DioException [unknown]: null**」✗
      //   （用户看不懂 ✓ 我们也判断不出是**超时 / 证书 / 连接被拒** ✗）。
      //   ⇒ 复用**统一失败表** ✓（`utils/source_fail_text.dart` ✓）：
      //     与豆瓣那句「连不上豆瓣，可能需要代理或网络受限」**同一种表达习惯** ✓（这就是"统一"✓）；
      //     并把**原文**附在括号里 ✓（便于排查 ✓ 不丢信息 ✓ 与其它页面同款 ✓）
      final fail = describeSourceFail(e, what: 'Cmbok 服务器');
      return (
        ok: false,
        message: '${fail.text}（${e.toString().split('\n').first}）',
      );
    }
  }

  String get email => _email;
  String get username => _username;
  String get remixUserid => _remixUserid;
  bool get isLoggedIn => _remixUserid.isNotEmpty && _remixUserkey.isNotEmpty;

  /// 供在线阅读 WebView 注入登录态：已登录返回 cookie（remix_userid/remix_userkey
  /// + siteLanguageV2），未登录返回空 map（由调用方决定是否降级）。
  Map<String, String> cookiesForWebview() =>
      isLoggedIn ? _cookies(_remixUserid, _remixUserkey) : const {};

  /// 自有账号服务端每日下载限额（未取到时为 null，调用方应回退 loggedDailyLimit）
  int? get serverDownloadsLimit => _serverDownloadsLimit;

  /// 地址是否不可用（全候选连接失败/404）。UI 据此提示「图书功能暂不可用」。
  bool get isUnavailable => _unavailable;

  /// 候选节点列表（只读视图）
  List<String> get candidates => List.unmodifiable(_candidates);

  /// ✅ **一键测试全部节点** ✓（供"节点管理"界面用 ✓）——
  /// 返回每个候选节点的**可用性 + 延迟（秒）+ 最终落地域名** ✓。
  ///
  /// ⚠️ **本方法只读** ✓：**不改 `_domain`** ✗、**不写盘** ✗ —— 切换当前节点仍由
  /// [setDomain] 负责 ✓（测试归测试 ✓，避免"点一下测试就把用户选好的节点换掉" ✗✗）。
  /// · 内部复用现成的 [_probeUrl] ✓（跟随重定向 ✓ 与自动选优用的是同一套逻辑 ✓，**不重写** ✗）
  /// · 候选为空时回退到内置列表 ✓（与 `_probeLocalCandidatesIfNeeded` 的兜底一致 ✓）
  /// · 排序 ✓：**可用的在前 ✓，同组按延迟升序** ✓ → 界面直接按返回顺序展示即可 ✓
  /// · 探测本身有并发与超时保护 ✓（`_probeUrl` 内 ✓），不会长时间卡住界面 ✓
  Future<List<({String domain, bool ok, double? latency, String host})>>
      probeAll() async {
    final list = _candidates.isEmpty
        ? List<String>.from(CmbokConstants.zLibraryDefaultDomains)
        : List<String>.from(_candidates);
    if (list.isEmpty) return const [];
    final results = await Future.wait(list.map((d) => _probeUrl(d)));
    final out = <({String domain, bool ok, double? latency, String host})>[];
    for (var i = 0; i < list.length; i++) {
      final r = results[i];
      out.add((
        domain: list[i],
        ok: r != null,
        latency: r?.latency,
        host: r?.domain ?? '',
      ));
    }
    out.sort((a, b) {
      if (a.ok != b.ok) return a.ok ? -1 : 1;
      return (a.latency ?? 999).compareTo(b.latency ?? 999);
    });
    _log('一键测试节点：${out.where((e) => e.ok).length}/${out.length} 可用');
    return out;
  }


  /// 初始化：加载登录态、域名、每日计数
  ///
  /// ⚠️ **幂等**：重复调用直接返回。
  ///
  /// 原来这个方法每次调用都会 `Timer.periodic(_kHealthInterval, ...)`
  /// —— 而它现在会被**懒初始化**触发（单例构造时），若外部再调一次
  /// 就会建出**第二个周期定时器**（一小时一次的健康检查跑两遍），
  /// 而且在 widget 测试里会留下 pending timer 直接让测试失败
  ///（`A Timer is still pending even after the widget tree was disposed`）。
  bool _inited = false;
  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    final prefs = await SharedPreferences.getInstance();
    // ⚠️ 不能直接用 `_defaultDomain()` 覆盖已有值：懒初始化已经播过种，
    // 而这个方法的默认值来自 `CmbokConstants.zLibraryApiUrl`（**已失效**）。
    final persistedDomain = prefs.getString(_kDomain);
    if (persistedDomain != null && persistedDomain.isNotEmpty) {
      _domain = persistedDomain;
      _domainPersisted = true; // 用户设定过 → 尊重它，不自动改
    } else if (_domain.isEmpty) {
      _domain = _defaultDomain();
    }
    _email = prefs.getString(_kEmail) ?? '';
    _username = prefs.getString(_kUsername) ?? '';
    _remixUserid = prefs.getString(_kRemixUserid) ?? '';
    _remixUserkey = prefs.getString(_kRemixUserkey) ?? '';

    // [PATCH-21] 网页登录会话（仅在登录态成立时恢复）
    _candidates = _decodeCandidates(prefs.getString(_kCandidates));

    // [PATCH-4b] 剔除**已知失效**节点（幂等，每次启动都跑，无需迁移标志）。
    //
    // 为什么必须有 ✗：上面 :341-343 对**持久化过的**域名会 `_domainPersisted = true`
    // 并"尊重它不自动改" —— 于是**老用户**（SharedPreferences 里已存
    // `zlibrary_domain = z-library.my` / 候选表里也有它）即使打了本补丁，
    // 第一个请求仍会打到坏节点上。虽然 PATCH-4 的 521 处理最终会切候选，
    // 但每次都要先白等一轮退避（2+4+8s）。
    //   · 这里在内存里剔除坏节点（不写盘、不改用户手填的其它节点）；
    //   · 当前域名本身是坏节点时清空它 + 取消"用户已设定"标记，
    //     让后面的 _probeLocalCandidatesIfNeeded 重新选优，
    //     成功节点由 _send() 里的 _persistDomain() 写回。
    // 实测依据：z-library.my 的 /eapi/book/most-popular 返回 HTTP 521；
    //          zh.intcn.online 根路径仅 5.6 KB，非 eapi 主机。
    const _kKnownDeadNodes = {'z-library.my', 'zh.intcn.online'};
    _candidates.removeWhere(_kKnownDeadNodes.contains);
    if (_kKnownDeadNodes.contains(_domain)) {
      _log('当前域名 $_domain 属已知失效节点，已清除并改为重新选优');
      _domain = '';
      _domainPersisted = false;
    }

    // ── 🔴 种子候选：本地默认节点（修"开箱即不可用"）────────────────
    //
    // 原来候选只有两个来源：本地持久化 + **云端** `url_config.json`。
    // 全新安装时两者都没有 → `_candidates` 为空 →
    // `_pickBestCandidate([])` 直接返回 null → **图书功能整个不可用**
    //（而云端那份配置的托管地址在国内也常拉不到）。
    //
    // 这里把 `CmbokConstants.zLibraryDefaultDomains` 追加进来做兜底：
    //   · 已有的（持久化/云端/用户手填）**保持在前**，优先级不变
    //   · 只补那些还没在列表里的
    // 于是"探测选优"至少有东西可探，开箱即可用。
    for (final d in CmbokConstants.zLibraryDefaultDomains) {
      if (d.isNotEmpty && !_candidates.contains(d)) _candidates.add(d);
    }
    // 当前域名不在候选里则插最前，确保至少有一个候选可用（兼容手动/老配置）
    if (_domain.isNotEmpty && !_candidates.contains(_domain)) {
      _candidates.insert(0, _domain);
    }
    await _loadCounts();
    _loadCategoriesCache(prefs);
    _log(
      'init: domain=$_domain, candidates=$_candidates, '
      'loggedIn=$isLoggedIn',
    );
    notifyListeners();
    if (isLoggedIn) refreshUserProfile(); // fire-and-forget：校准服务端限额与已下载数

    // ── 定时健康检查：只在**确实有候选节点**时才建 ──────────────────
    //
    // `_healthCheck()` 开头就是 `if (_candidates.isEmpty) return;`
    // —— 没候选时这个定时器什么都不做，纯浪费。
    //
    // 更要紧的是：`ZlibraryService()` 是**懒初始化**的（单例一构造就 init），
    // 而 widget 测试里渲染「我的页」就会构造它。若无条件建周期定时器，
    // 测试结束会报 `A Timer is still pending even after the widget tree
    // was disposed` → 测试失败（这是实测到的回归）。
    //
    // 真实运行时候选列表必然非空（上面刚播过种），所以行为不变。
    //
    // 另外提供一个**显式的测试开关** [healthTimerEnabled]：widget 测试里
    // 渲染「我的页」会构造本单例，而周期定时器会让 `flutter_test` 报
    // `A Timer is still pending even after the widget tree was disposed`。
    // 在库里猜"是不是测试环境"很脏，让测试自己声明更清楚。
    _healthTimer?.cancel();
    if (_candidates.isNotEmpty && healthTimerEnabled) {
      _healthTimer = Timer.periodic(_kHealthInterval, (_) => _healthCheck());
    }
    // 监听云端配置：RemoteConfig 拉到 zlibrary_url 后探测选优
    RemoteConfigService().removeListener(_onRemoteConfigChanged);
    RemoteConfigService().addListener(_onRemoteConfigChanged);
    _applyCloudCandidatesIfAvailable();
    // ── 本地兜底：云端配置拉不到时，用内置候选列表探测选最优 ──
    // （上面已经把 CmbokConstants.zLibraryDefaultDomains 播进 _candidates）
    unawaited(_probeLocalCandidatesIfNeeded());
  }

  /// RemoteConfig 变更回调：云端拉到 zlibrary_url 后探测选优。
  void _onRemoteConfigChanged() {
    _applyCloudCandidatesIfAvailable();
  }

  void _applyCloudCandidatesIfAvailable() {
    final cloud = RemoteConfigService().cloudZlibraryUrl;
    if (cloud == null || cloud == _lastAppliedCloud) return;
    _lastAppliedCloud = cloud;
    applyCloudCandidates(cloud); // fire-and-forget
  }

  /// 用**本地默认候选**做一次探测选优（无云端配置时的兜底）。
  ///
  /// ── 🔴 为什么必须有这一步 ────────────────────────────────────────
  /// 上面把 `CmbokConstants.zLibraryDefaultDomains` 播进了 `_candidates`，
  /// 但**没有任何代码去探测它们** —— `applyCloudCandidates` 只在
  /// `RemoteConfigService().cloudZlibraryUrl != null`（即云端配置拉到了）时才跑。
  ///
  /// 而云端那份配置托管在 GitHub raw / jsDelivr 上，国内经常拉不到，
  /// 所以"有候选但从不选优"= 一直用列表里第一个（可能已失效）。
  ///
  /// 这里补上本地兜底探测：并发探全部候选，挑**延迟最低的可用节点**，
  /// 结果写回 `_domain` 并持久化。探测是并发 + <3s 提前返回，不会拖慢。
  Future<void> _probeLocalCandidatesIfNeeded() async {
    if (_candidates.isEmpty) return;
    // [PATCH-20] 先向官方 eapi 要一次**最新域名列表**（自愈域名漂移），再走选优
    await _discoverDomainsFromEapi();
    // 用户在设置页手填过域名（有持久化记录）就尊重它，不擅自改。
    //
    // ⚠️ 判据必须是"**从 prefs 读出来的**"，不能是 `_candidates.contains(_domain)`
    // —— 懒初始化会把 `_candidates.first` 播进 `_domain`，那种情况下
    // `contains` 恒为 true，探测就被永久跳过了（等于白播种）。
    if (_domainPersisted) {
      _log('已有用户设定的域名 $_domain，跳过本地探测选优');
      return;
    }
    final best = await _pickBestCandidate(_candidates);
    if (best == null) {
      _log('本地候选全不可用（${_candidates.length} 个）');
      _setUnavailable(true);
      return;
    }
    if (best != _domain) {
      _log('本地候选探测选优: $_domain -> $best');
      _domain = best;
      await _persistDomain();
    }
    _setUnavailable(false);
    notifyListeners();
  }

  /// [PATCH-20] 从官方 eapi 拉取**当前域名列表**并合并进候选（自愈域名漂移）。
  ///
  /// 依据（实测 2026-10-06，4 个可用镜像返回**完全一致**）：
  /// ```
  /// GET /eapi/info/domains →
  /// {"success":1,"domains":[
  ///    {"domain":"z-library.sk","contentAvailable":true,"isRedirector":false},
  ///    {"domain":"1lib.sk","contentAvailable":true,"isRedirector":false},
  ///    {"domain":"article.sk","contentAvailable":true,"isRedirector":false},
  ///    {"domain":"articles.sk","contentAvailable":true,"isRedirector":false},
  ///    {"domain":"proxy.zlibraryproxies.workees.dev",…}]}
  /// ```
  /// 这是**官方 Android App 自用**的接口（文档：baroxyton/zlibrary-eapi-documentation）。
  /// 本项目此前只能靠硬编码 + 云端 `url_config.json`（国内常拉不到）
  /// ⇒ 节点一漂移就全灭。有了它就能自愈。
  ///
  /// 附带价值：`/eapi/info` 返回站点真实规模（如 books=33577617）——
  /// **SEO 克隆假站（如 z-library.my）不可能返回这种 JSON** ⇒ 可作"真主机"判据。
  ///
  /// 失败/超时一律静默：不阻塞 init、不影响既有选优流程。
  Future<void> _discoverDomainsFromEapi() async {
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 8),
          followRedirects: true,
          validateStatus: (_) => true,
          headers: {
            'user-agent': _browserUa,
            'accept': 'application/json, text/plain, */*',
          },
        ),
      );
      applyGlobalProxy(dio);
      // 依次问最多 3 个候选（当前域名优先），第一个给出列表就够
      for (final d in _candidateOrder().take(3)) {
        final resp = await dio.get('https://$d/eapi/info/domains');
        if (resp.statusCode != 200) continue;
        final map = _asJsonMap(resp.data);
        if (!_isTruthy(map['success'])) continue;
        final list = map['domains'];
        if (list is! List) continue;
        var added = 0;
        for (final it in list) {
          if (it is! Map) continue;
          final host = '${it['domain'] ?? ''}'.trim();
          if (host.isEmpty) continue;
          // 重定向器留作跳板意义不大（它只做 307），不主动加入候选
          if (it['isRedirector'] == true) continue;
          if (_candidates.contains(host)) continue;
          _candidates.add(host);
          added++;
        }
        if (added > 0) {
          await _persistCandidates();
          _log('官方 eapi 发现 $added 个新域名，候选共 ${_candidates.length} 个');
          notifyListeners();
        } else {
          _log('官方 eapi 未给出新域名（源节点 $d）');
        }
        return;
      }
      _log('官方 eapi 域名发现：候选里没有能应答的节点（忽略）');
    } catch (e) {
      _log('官方 eapi 域名发现失败（忽略）：$e');
    }
  }

  /// [PATCH-21] 把**网页登录会话**回灌为 eapi 登录态。
  ///
  /// 依据（官方 eapi 文档 `baroxyton/zlibrary-eapi-documentation`）：
  /// > In some cases, it may also be necessary to provide the login as the
  /// > cookies `remix_userid` and `remix_userkey`
  /// ⇒ 拿到这两个 Cookie，**无需邮箱密码**即可让所有 eapi 请求进入已登录态
  ///   （本类所有请求的 Cookie 都出自 [_cookies]，所以只要设好这两个字段，
  ///    推荐/搜索/详情/下载就全部自动带上会话 ✓）。
  /// 与 `icodebase-cn/aiset-zlibrary`（MIT）"浏览器登录一次、复用会话"同一思路。
  ///
  /// [cookieHeader] 形如 `a=1; remix_userid=123; remix_userkey=abc`。
  /// 返回 true 表示成功解析并持久化了登录态。
  Future<bool> applyWebSession(String cookieHeader) async {
    final raw = cookieHeader.trim();
    if (raw.isEmpty) return false;
    final jar = <String, String>{};
    for (final part in raw.split(';')) {
      final i = part.indexOf('=');
      if (i <= 0) continue;
      jar[part.substring(0, i).trim().toLowerCase()] =
          part.substring(i + 1).trim();
    }
    final uid = jar['remix_userid'] ?? jar['remix-userid'] ?? '';
    final key = jar['remix_userkey'] ?? jar['remix-userkey'] ?? '';
    if (uid.isEmpty || key.isEmpty) {
      _log('网页登录会话缺少 remix_userid/remix_userkey（可能 HttpOnly），登录态不变');
      return false;
    }
    _remixUserid = uid;
    _remixUserkey = key;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRemixUserid, uid);
    await prefs.setString(_kRemixUserkey, key);
    await prefs.setString(_kWebSession, raw);
    _log('网页登录会话已回灌（remix_userid=${uid.length > 4 ? uid.substring(0, 4) : uid}…）');
    notifyListeners();
    refreshUserProfile(); // fire-and-forget：用 /eapi/user/profile 校验会话是否生效
    return true;
  }

  static String _defaultDomain() => RemoteConfigService().zlibraryDomain;

  Future<void> _persistDomain() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDomain, _domain);
  }

  Future<void> _persistCandidates() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCandidates, jsonEncode(_candidates));
  }

  /// 从 prefs 加载分类目录缓存到 [BookCategories.groups]（启动即有数据，不等网络）。
  void _loadCategoriesCache(SharedPreferences prefs) {
    final raw = prefs.getString(_kCategories);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List;
      final groups = list
          .map((e) => BookCategoryGroup.fromJson(e as Map<String, dynamic>))
          .toList();
      if (groups.isNotEmpty) {
        BookCategories.groups = groups;
        _log('分类缓存加载: ${groups.length} 组');
      }
    } catch (e) {
      _log('分类缓存加载失败: $e');
    }
  }

  Future<void> _persistCategories() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kCategories,
      jsonEncode(BookCategories.groups.map((g) => g.toJson()).toList()),
    );
  }

  /// 候选域名遍历顺序：当前域名在前，其余候选按列表顺序，去重。
  List<String> _candidateOrder() {
    final order = <String>[];
    if (_domain.isNotEmpty) order.add(_domain);
    for (final d in _candidates) {
      if (d.isNotEmpty && !order.contains(d)) order.add(d);
    }
    return order;
  }

  /// 把域名加入候选列表最前并持久化（已存在则提到最前）。供重定向发现新域名时调用。
  void _addCandidate(String? newDomain) {
    if (newDomain == null || newDomain.isEmpty) return;
    _candidates.remove(newDomain);
    _candidates.insert(0, newDomain);
    _persistCandidates();
  }

  /// 标记可用性状态，仅状态变化才 notify（避免无谓重建）。
  void _setUnavailable(bool v) {
    if (_unavailable == v) return;
    _unavailable = v;
    notifyListeners();
  }

  // -------------------- 登录 / 注册 --------------------

  /// 邮箱密码登录（自有账号）。成功保存 token。对应 cmbook Zlibrary.login
  Future<bool> login(String email, String password) async {
    final res = await _post(
      '/eapi/user/login',
      data: {'email': email, 'password': password},
    );
    if (_isSuccess(res) && res['user'] is Map) {
      final user = res['user'] as Map;
      final uid = (user['id'] ?? '').toString();
      final key = (user['remix_userkey'] ?? '').toString();
      if (uid.isEmpty || key.isEmpty) return false;
      _email = email;
      _username = (user['name'] ?? '').toString();
      _remixUserid = uid;
      _remixUserkey = key;
      await _persistAuth();
      _log('登录成功: $email');
      notifyListeners();
      refreshUserProfile(); // fire-and-forget：拉取服务端实际限额与已下载数
      return true;
    }
    _log('登录失败: $res');
    return false;
  }

  /// 发送注册验证码。对应 cmbook Zlibrary.sendCode
  Future<bool> sendCode(String email, String password, String name) async {
    final res = await _post(
      '/papi/user/verification/send-code',
      data: {
        'email': email,
        'password': password,
        'name': name,
        'rx': 215,
        'action': 'registration',
        'site_mode': 'books',
        'isSinglelogin': 1,
      },
    );
    return _isSuccess(res);
  }

  /// 提交验证码完成注册。rpc.php 返回不可靠，注册后用账号登录验证。
  /// 对应 cmbook ZlibraryRegister.run
  Future<bool> register(
    String email,
    String password,
    String name,
    String code,
  ) async {
    await _post(
      '/rpc.php',
      data: {
        'email': email,
        'password': password,
        'name': name,
        'verifyCode': code,
        'rx': 215,
        'action': 'registration',
        'redirectUrl': '',
        'isModa': true,
        'gg_json_mode': 1,
      },
    );
    return login(email, password); // 登录验证注册是否成功
  }

  Future<void> logout() async {
    _email = '';
    _username = '';
    _remixUserid = '';
    _remixUserkey = '';
    _serverDownloadsLimit = null;
    _serverDownloadsToday = 0;
    await _persistAuth();
    _log('退出登录');
    notifyListeners();
  }

  Future<void> _persistAuth() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kEmail, _email);
    await prefs.setString(_kUsername, _username);
    await prefs.setString(_kRemixUserid, _remixUserid);
    await prefs.setString(_kRemixUserkey, _remixUserkey);
  }

  // -------------------- 搜索 --------------------

  /// 搜索图书。已登录自有账号用自有 token，否则轮询内置账号。
  /// 对应 cmbook BookSearch.run + _do_search。
  /// [extensions] 为格式筛选（多选，EPUB/PDF/...），null 或空=不筛选。
  Future<SearchResult<Book>> search(
    String message, {
    List<String>? extensions,
    String? languages,
    int? yearFrom,
    int? yearTo,
    int page = 1,
    int limit = 30,
  }) async {
    // [方案A] 普通搜索优先走网页 HTML 路径（当前镜像 /s/?q=）：
    //   eapi 返回的数字 id + hex hash 在网页上不存在（实测重定向首页），
    //   网页路径能拿到当前镜像的短 id + slug + readOnlineUrl，
    //   使「在线阅读」可以打开正确的书页。网页失败（CF/网络）回退 eapi。
    if (_domain.isNotEmpty) {
      try {
        final web = await _searchWebHtml(
          message,
          extensions,
          languages,
          yearFrom,
          yearTo,
          page,
        );
        if (web != null && web.items.isNotEmpty) return web;
      } catch (e) {
        _log('网页搜索失败，回退 eapi 搜索: $e');
      }
    }
    if (isLoggedIn) {
      final res = await _doSearch(
        message,
        extensions,
        languages,
        yearFrom,
        yearTo,
        page,
        limit,
        _remixUserid,
        _remixUserkey,
      );
      if (_isSuccess(res)) return _parseSearch(res);
      // 失败：区分地址不可用/限流/token 失效/真失败
      if (res['unavailable'] == true) {
        throw ZlibraryException('unavailable', '图书功能暂不可用，请等待恢复');
      }
      if (res['rate_limited'] == true) {
        throw ZlibraryException('rate_limited', '请求过于频繁，请稍后再试');
      }
      final useBuiltin = SettingsService().useBuiltinAccount;
      switch (await _verifyToken()) {
        case _TokenState.unavailable:
          throw ZlibraryException('unavailable', '图书功能暂不可用，请等待恢复');
        case _TokenState.invalid:
          // token 失效：清登录态；开关开则回退内置账号，否则提示重新登录
          await _clearSelfToken();
          if (!useBuiltin) {
            throw ZlibraryException('no_login', '登录已失效，请重新登录');
          }
          _log('自登 token 失效，回退内置账号搜索');
          break;
        case _TokenState.valid:
          if (!useBuiltin) {
            throw ZlibraryException('fail', '搜索失败，请稍后重试');
          }
          _log('自登搜索失败，回退内置账号');
          break;
      }
    }
    // 未登录：默认使用内置账号搜索（不受"使用内置账号"开关限制），以提升体验；
    // 也覆盖已登录自有账号失败且回退内置账号的情况。
    final res = await _searchWithBuiltin(
      message,
      extensions,
      languages,
      yearFrom,
      yearTo,
      page,
      limit,
    );
    if (res['unavailable'] == true) {
      throw ZlibraryException('unavailable', '图书功能暂不可用，请等待恢复');
    }
    if (res['rate_limited'] == true) {
      throw ZlibraryException('rate_limited', '请求过于频繁，请稍后再试');
    }
    if (!_isSuccess(res)) {
      throw ZlibraryException('no_account', '没有可用的内置账号');
    }
    return _parseSearch(res);
  }

  /// [方案A] 网页 HTML 搜索（当前镜像 `/s/?q=`，WebView 过 CF 挑战）。
  ///
  /// 成功且解析出书返回 [SearchResult]；网页不可用/空结果/解析失败返回 null，
  /// 由调用方回退 eapi。解析复用 [_parseCategoryHtml]（z-bookcard → 短 id + slug
  /// + readOnlineUrl），与分类搜索同链路，保证「在线阅读」链接是当前镜像可用的。
  Future<SearchResult<Book>?> _searchWebHtml(
    String message,
    List<String>? extensions,
    String? languages,
    int? yearFrom,
    int? yearTo,
    int page,
  ) async {
    final kw = message.trim();
    if (_domain.isEmpty || kw.isEmpty) return null;
    // 参照分类搜索的 /s/ 端点拼法（支持 year/language/extension 过滤）
    final buf = StringBuffer('https://$_domain/s/?page=$page');
    buf.write('&q=${Uri.encodeQueryComponent(kw)}');
    if (yearFrom != null) buf.write('&yearFrom=$yearFrom');
    if (yearTo != null) buf.write('&yearTo=$yearTo');
    if (languages != null && languages.trim().isNotEmpty) {
      buf.write('&languages=${Uri.encodeQueryComponent(languages.trim())}');
    }
    if (extensions != null) {
      for (final ext in extensions) {
        if (ext.isNotEmpty) buf.write('&extensions%5B%5D=$ext');
      }
    }
    final url = buf.toString();
    _log('网页搜索: $url');
    String? htmlStr;
    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final html = await WebViewImageFetcher().fetchHtml(url);
        if (html.isNotEmpty) {
          htmlStr = html;
          break;
        }
        lastError = StateError('搜索页返回空 HTML');
      } catch (e) {
        lastError = e;
      }
      _log('网页搜索第 $attempt/3 次失败: $lastError');
      if (attempt < 3) {
        await Future.delayed(const Duration(milliseconds: 800));
      }
    }
    if (htmlStr == null) {
      _log('网页搜索 3 次均失败: $lastError');
      return null;
    }
    final result = _parseCategoryHtml(htmlStr, page);
    if (result.items.isEmpty) {
      _log('网页搜索解析到 0 条，交给 eapi 兜底');
      return null;
    }
    return result;
  }

  /// [方案A] 取该书可用的网页在线阅读链接。
  ///
  /// 已有 [Book.readOnlineUrl] 直接用；否则（eapi 数据：推荐流 / 搜索兜底）
  /// 用书名在当前镜像网页搜索，优先取书名完全一致的书，否则取第一条有
  /// 链接的书，返回其网页链接。拿不到返回 null（调用方提示用户）。
  Future<String?> resolveOnlineUrl(Book book) async {
    final explicit = book.readOnlineUrl;
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final title = book.title.trim();
    if (_domain.isEmpty || title.isEmpty) return null;
    try {
      final result = await _searchWebHtml(title, null, null, null, null, 1);
      if (result == null) return null;
      for (final b in result.items) {
        final r = b.readOnlineUrl;
        if (r != null && r.isNotEmpty && b.title.trim() == title) return r;
      }
      for (final b in result.items) {
        final r = b.readOnlineUrl;
        if (r != null && r.isNotEmpty) return r;
      }
    } catch (e) {
      _log('resolveOnlineUrl 失败: $e');
    }
    return null;
  }

  SearchResult<Book> _parseSearch(Map<String, dynamic> res) {
    final books = (res['books'] as List? ?? [])
        .whereType<Map>()
        .map((b) => Book.fromJson(Map<String, dynamic>.from(b)))
        .toList();
    final pag = (res['pagination'] as Map?) ?? {};
    final total = _asInt(pag['total_items']) ?? books.length;
    final totalPages = _asInt(pag['total_pages']) ?? 0;
    final current = _asInt(pag['current']) ?? 1;
    _log(
      '搜索分页: currentPage=$current, totalPages=$totalPages, '
      'total=$total, 返回${books.length}条, hasMore=${current < totalPages}',
    );
    return SearchResult<Book>(
      items: books,
      total: total,
      currentPage: current,
      totalPages: totalPages,
    );
  }

  // -------------------- 分类搜索（WebView 抓 HTML 解析）--------------------
  //
  // z-library /eapi/book/search 端点不支持分类过滤参数（实测 category/categories 等
  // 参数被服务端忽略），HTML 路由 /category/{id}/{slug} 被 Cloudflare JS 挑战拦截，
  // Dio 无法直抓。走 WebViewImageFetcher 单例（已在根树挂 1px 隐藏 WebView），由
  // webview 自动执行 JS 挑战通过 CF，再 runJavaScriptReturningResult 取
  // documentElement.outerHTML，用 html 包解析书籍卡片。

  /// 取分类页书的 eapi 匹配缓存（命中则无需再发搜索）。
  Book? categoryMatchCache(String bookId) => _categoryMatchCache[bookId];

  /// 写入分类页书的 eapi 匹配缓存（匹配成功后调用）。
  void setCategoryMatchCache(Book matched) =>
      _categoryMatchCache[matched.id] = matched;

  /// 按分类搜索图书（走 WebView 抓 HTML，CF 挑战由 webview 自动通过）。
  ///
  /// [category] 为选中的子分类；[keyword] 为空即纯分类浏览，非空即分类内搜索
  /// （URL：/category/{id}/{slug}/s/?q={keyword}&page={page}）。
  /// 失败抛 [ZlibraryException]（unavailable / fail）。
  Future<SearchResult<Book>> searchInCategory(
    BookCategory category, {
    String? keyword,
    int page = 1,
    int? yearFrom,
    int? yearTo,
    List<String>? languages,
    List<String>? extensions,
  }) async {
    if (_domain.isEmpty) {
      throw ZlibraryException('unavailable', '图书功能暂不可用，请等待恢复');
    }
    // 统一走 /s/ 搜索端点（支持 year/language/extension 过滤参数）。
    // `[]` 编码为 %5B%5D；过滤值原样拼入（traditional+chinese 的 + 不编码）。
    final buf = StringBuffer(
      'https://$_domain/category/${category.id}/${category.slug}/s/?page=$page',
    );
    final kw = keyword?.trim() ?? '';
    if (kw.isNotEmpty) buf.write('&q=${Uri.encodeQueryComponent(kw)}');
    if (yearFrom != null) buf.write('&yearFrom=$yearFrom');
    if (yearTo != null) buf.write('&yearTo=$yearTo');
    if (languages != null) {
      for (final lang in languages) {
        if (lang.isNotEmpty) buf.write('&languages%5B%5D=$lang');
      }
    }
    if (extensions != null) {
      for (final ext in extensions) {
        if (ext.isNotEmpty) buf.write('&extensions%5B%5D=$ext');
      }
    }
    final url = buf.toString();
    _log('分类搜索 WebView: $url');
    // WebView 抓取偶发失败（CF 挑战/网络抖动），自动重试 2 次（共 3 次尝试）。
    String? htmlStr;
    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final html = await WebViewImageFetcher().fetchHtml(url);
        if (html.isNotEmpty) {
          htmlStr = html;
          break;
        }
        lastError = StateError('分类搜索返回空 HTML');
      } catch (e) {
        lastError = e;
      }
      _log('分类搜索第 $attempt/3 次失败: $lastError');
      if (attempt < 3) {
        await Future.delayed(const Duration(milliseconds: 800));
      }
    }
    if (htmlStr == null) {
      _log('分类搜索 3 次均失败: $lastError');
      throw ZlibraryException('fail', '分类搜索失败，请稍后重试');
    }
    return _parseCategoryHtml(htmlStr, page);
  }

  /// 解析 z-library 分类页 HTML（书籍卡片 DOM 结构）。
  ///
  /// DOM 结构（用户实测 z-library 分类页）：
  /// - 卡片容器：`<div class="book-item resItemBoxBooks">`
  /// - 卡片元素：`<z-bookcard id="{bookId}" download="{下载URL}" year="..." language="..." extension="..." filesize="...">`
  /// - 封面：`<img src="...">`
  /// - 书名：`<div slot="title">...</div>`
  /// - 作者：`<div slot="authore">...</div>`
  /// bookHash 不在 z-bookcard 属性中，从 download URL（如 /dl/vALK9ZrE4R 或
  /// /book/{hash}/{slug}.html）或 a[href*="/book/"] 提取。
  SearchResult<Book> _parseCategoryHtml(String htmlStr, int page) {
    final doc = html_parser.parse(htmlStr);
    // 单一选择器 z-bookcard（用 .book-item 会与 z-bookcard 重复匹配）
    final rows = doc.querySelectorAll('z-bookcard');
    final books = <Book>[];
    final seenIds = <String>{};
    for (final r in rows) {
      try {
        final book = _parseBookRow(r);
        if (book != null && book.id.isNotEmpty && !seenIds.contains(book.id)) {
          seenIds.add(book.id);
          books.add(book);
        }
      } catch (_) {}
    }
    // 调试：解析到 0 条时输出 HTML 片段，辅助定位 DOM 变化
    if (books.isEmpty) {
      _log('分类页解析到 0 条，HTML 长度=${htmlStr.length}');
      _log(
        'HTML 前 800 字: ${htmlStr.length > 800 ? htmlStr.substring(0, 800) : htmlStr}',
      );
    } else {
      _log(
        '分类页解析到 ${books.length} 条，前两条: '
        '${books.take(2).map((b) => '${b.title}(id=${b.id},hash=${b.hash})').join(", ")}',
      );
    }
    // 解析分页（z-library 桌面端 .pagination 含总页数；老前端是数字 <a>，
    // 新前端可能用 href?page=N，两种都试）。
    var totalPages = 0;
    final pagLinks = doc.querySelectorAll('.pagination a');
    for (final a in pagLinks) {
      final txt = int.tryParse(a.text.trim());
      if (txt != null && txt > totalPages) totalPages = txt;
    }
    // 兜底：取不到数字时按 href 里的 page= 参数最大值
    if (totalPages == 0) {
      for (final a in pagLinks) {
        final href = a.attributes['href'] ?? '';
        final m = RegExp(r'page=(\d+)').firstMatch(href);
        final p = m == null ? null : int.tryParse(m.group(1)!);
        if (p != null && p > totalPages) totalPages = p;
      }
    }
    // 仍取不到 totalPages：按本页条数推断（每页最多 50 条）。
    // 满页 = 还有下一页（totalPages = page+1 使 hasMore 为 true）；
    // 不足 = 末页（totalPages = page 使 hasMore 为 false）。
    const pageSize = 50;
    if (totalPages == 0) {
      totalPages = books.length >= pageSize ? page + 1 : page;
    }
    final total = books.isNotEmpty && totalPages > 0
        ? totalPages * pageSize
        : books.length;
    _log(
      '分类分页: page=$page, totalPages=$totalPages, '
      'pagination链接数=${pagLinks.length}, 返回${books.length}条',
    );
    return SearchResult<Book>(
      items: books,
      total: total,
      currentPage: page,
      totalPages: totalPages,
    );
  }

  // -------------------- 分类目录（/categories 页动态抓取）--------------------

  /// 抓取 `/categories` 页填充 [BookCategories.groups]（主分类 -> 子分类两级树）。
  ///
  /// 走 WebView 抓 HTML（CF 挑战由 webview 自动通过）。成功后写回 groups、
  /// 持久化到 SharedPreferences、notifyListeners。失败抛 [ZlibraryException]。
  /// [force] = true 强制重新抓取（忽略已有缓存）。
  Future<List<BookCategoryGroup>> fetchCategories({bool force = false}) async {
    if (!force && BookCategories.groups.isNotEmpty) {
      return BookCategories.groups;
    }
    if (_domain.isEmpty) {
      throw ZlibraryException('unavailable', '图书功能暂不可用，请等待恢复');
    }
    final url = 'https://$_domain/categories';
    _log('抓取分类目录: $url');
    String? htmlStr;
    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final html = await WebViewImageFetcher().fetchHtml(url);
        if (html.isNotEmpty) {
          htmlStr = html;
          break;
        }
        lastError = StateError('分类页返回空 HTML');
      } catch (e) {
        lastError = e;
      }
      _log('分类页第 $attempt/3 次失败: $lastError');
      if (attempt < 3) {
        await Future.delayed(const Duration(milliseconds: 800));
      }
    }
    if (htmlStr == null) {
      _log('分类页 3 次均失败: $lastError');
      throw ZlibraryException('fail', '分类目录加载失败，请稍后重试');
    }
    final groups = _parseCategoriesHtml(htmlStr);
    if (groups.isEmpty) {
      _log('分类页解析到 0 组，HTML 长度=${htmlStr.length}');
      throw ZlibraryException('fail', '分类目录解析失败');
    }
    BookCategories.groups = groups;
    _persistCategories(); // fire-and-forget
    _log('分类目录更新: ${groups.length} 组');
    notifyListeners();
    return groups;
  }

  /// 解析 `/categories` 页 HTML。
  ///
  /// DOM 结构：每个 `.subcategories-container` 为一个主分类块，
  /// `.category-name a` 文本 = 主分类名（组标题，翻译），
  /// `ul li.subcategory-name a` = 子分类（href 提 id/slug，文本翻译保留计数）。
  /// 主分类本身作为首个子项「全部」加入（id 取主分类 href，slug 用名称 slugify）。
  List<BookCategoryGroup> _parseCategoriesHtml(String htmlStr) {
    final doc = html_parser.parse(htmlStr);
    final containers = doc.querySelectorAll('.subcategories-container');
    final groups = <BookCategoryGroup>[];
    for (final c in containers) {
      // 主分类名：.category-name 下的 a（兜底 .category-name 本身即 a）
      final cn = c.querySelector('.category-name');
      String? mainName;
      String? mainHref;
      if (cn != null) {
        final a = cn.querySelector('a') ?? (cn.localName == 'a' ? cn : null);
        if (a != null) {
          mainName = a.text.trim();
          mainHref = a.attributes['href'];
        } else {
          mainName = cn.text.trim();
        }
      }
      if (mainName == null || mainName.isEmpty) continue;
      final title = BookCategories.translate(mainName);

      // 子分类：li.subcategory-name 下的 a（兜底 .subcategory-name a）
      var subAs = c.querySelectorAll('li.subcategory-name a');
      if (subAs.isEmpty) subAs = c.querySelectorAll('.subcategory-name a');
      final children = <BookCategory>[];

      // 主分类作为「全部」子项
      final mainId = _categoryIdFromHref(mainHref);
      if (mainId != null) {
        children.add(BookCategory(mainId, _slugify(mainName), '全部'));
      }

      for (final a in subAs) {
        final name = a.text.trim();
        final href = a.attributes['href'] ?? '';
        final id = _categoryIdFromHref(href);
        final slug = _categorySlugFromHref(href);
        if (id == null || slug.isEmpty) continue;
        children.add(
          BookCategory(
            id,
            slug,
            BookCategories.translate(name, context: mainName),
          ),
        );
      }
      if (children.isNotEmpty) {
        groups.add(BookCategoryGroup(title, children));
      }
    }
    return groups;
  }

  /// 从分类 href 提取数字 id（`/category/40/Architecture` -> 40；`/category/1` -> 1）。
  int? _categoryIdFromHref(String? href) {
    if (href == null || href.isEmpty) return null;
    final m = RegExp(r'/category/(\d+)').firstMatch(href);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// 从分类 href 提取 slug（`/category/40/Architecture` -> `Architecture`）。
  /// 主分类 href（`/category/1`，无 slug 段）返回空。
  String _categorySlugFromHref(String? href) {
    if (href == null || href.isEmpty) return '';
    final m = RegExp(r'/category/\d+/([^/?#]+)').firstMatch(href);
    return m == null ? '' : m.group(1)!;
  }

  /// 把主分类英文名转成 URL slug。slug 为展示用，服务端按 id 路由，内容无关紧要。
  String _slugify(String name) {
    var s = name.replaceAll('&', 'and');
    s = s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-');
    s = s.replaceAll(RegExp(r'-+'), '-');
    s = s.replaceAll(RegExp(r'^-|-$'), '');
    return s.isEmpty ? 'all' : s;
  }

  /// 从单个 `z-bookcard` 元素解析 [Book]。
  ///
  /// z-bookcard 自带属性：id（bookId 数字）、year、language、extension、filesize、
  /// download（下载 URL，含 hash 片段，如 /dl/vALK9ZrE4R 或 /book/{hash}/{slug}.html）。
  /// bookHash 无专门属性，从 download 或详情链接 URL 中提取。
  Book? _parseBookRow(dynamic rowEl) {
    final row = rowEl as html_element.Element;
    String? cover;
    String? title;
    String? author;
    String? year;
    String? language;
    String? extension;
    String? filesizeString;
    String? id;
    String? hash;

    // id：z-bookcard 的 id 属性（数字 bookId）
    final idAttr = row.attributes['id'];
    if (idAttr != null && idAttr.isNotEmpty && int.tryParse(idAttr) != null) {
      id = idAttr;
    }

    // 元数据：z-bookcard 自带属性 year / language / extension / filesize
    final yearAttr = row.attributes['year'];
    if (yearAttr != null && yearAttr.isNotEmpty) year = yearAttr;
    final langAttr = row.attributes['language'];
    if (langAttr != null && langAttr.isNotEmpty) language = langAttr;
    final extAttr = row.attributes['extension'];
    if (extAttr != null && extAttr.isNotEmpty) extension = extAttr;
    final fsAttr = row.attributes['filesize'];
    if (fsAttr != null && fsAttr.isNotEmpty) filesizeString = fsAttr;

    // hash：分类页 z-bookcard 不暴露 eapi hash（termshash 为空），
    // 改用 download 属性（如 "/dl/xnl1dlgGRJ"）归一为 "dl/{slug}" 存入 hash；
    // 下载侧 getDownloadLink 检测到 dl slug 走 WebView 解析真实下载 URL。
    final dlAttr = row.attributes['download'] ?? '';
    if (dlAttr.isNotEmpty) {
      final m = RegExp(
        r'(?:https?://[^/]+)?/dl/([0-9a-zA-Z_-]+)',
      ).firstMatch(dlAttr);
      if (m != null) {
        hash = 'dl/${m.group(1)}';
      } else {
        hash = dlAttr;
      }
    }
    // 兼容：从详情链接补充 hash（仅 dl 属性缺失时）
    if (hash == null || hash.isEmpty) {
      final link = row.querySelector('a[href*="/book/"]');
      if (link != null) {
        final h = link.attributes['href'] ?? '';
        final m = RegExp(
          r'/book/([0-9a-zA-Z_-]{6,16})(?:/|\.|$)',
        ).firstMatch(h);
        if (m != null) hash = m.group(1);
        final m2 = RegExp(r'/book/\d+/([0-9a-fA-F]{16,})').firstMatch(h);
        if (m2 != null && (hash == null || hash.isEmpty)) hash = m2.group(1);
      }
    }

    // 书名：div[slot="title"]
    final titleEl = row.querySelector('[slot="title"]');
    title = titleEl?.text.trim();
    if (title == null || title.isEmpty) return null;

    // 封面：img
    final img = row.querySelector('img');
    if (img != null) {
      cover = img.attributes['src'] ?? img.attributes['data-src'];
    }
    // 作者：div[slot="author"]（旧版拼为 authore，两个都兼容）
    final authorEl = row.querySelector('[slot="author"], [slot="authore"]');
    if (authorEl != null) author = authorEl.text.trim();

    // [方案A] 网页在线阅读链接：优先 z-bookcard 自带 readOnlineUrl 属性；
    // 否则从详情链接 `/book/<短id>/<slug>.html` 提取并拼当前镜像完整 URL。
    // （eapi 数字 id + hex hash 在网页不存在，不能用来拼在线阅读地址。）
    var readOnline = rowEl.attributes['readOnlineUrl'];
    if (readOnline == null || readOnline.isEmpty) {
      final link = row.querySelector('a[href*="/book/"]');
      if (link != null) {
        final h = link.attributes['href'] ?? '';
        final m = RegExp(r'(/book/[^/?#]+/[^/?#]+\.html)').firstMatch(h);
        if (m != null) {
          readOnline = h.startsWith('http')
              ? h
              : 'https://$_domain${m.group(1)!}';
        }
      }
    }

    return Book(
      id: id ?? '',
      hash: hash ?? '',
      title: title,
      author: author,
      cover: cover,
      year: year,
      language: language,
      extension: extension,
      filesizeString: filesizeString,
      readOnlineUrl:
          (readOnline == null || readOnline.isEmpty) ? null : readOnline,
    );
  }

  Future<Map<String, dynamic>> _searchWithBuiltin(
    String message,
    List<String>? extensions,
    String? languages,
    int? yearFrom,
    int? yearTo,
    int page,
    int limit,
  ) async {
    // 优先复用缓存的内置 token
    if (_builtinUserid != null && _builtinUserkey != null) {
      final res = await _doSearch(
        message,
        extensions,
        languages,
        yearFrom,
        yearTo,
        page,
        limit,
        _builtinUserid!,
        _builtinUserkey!,
      );
      if (_isSuccess(res)) return res;
      // 地址不可用/限流：直接返回（停止轮询，避免加剧 429 / 同地址都失败）
      if (res['unavailable'] == true || res['rate_limited'] == true) return res;
      _builtinUserid = _builtinUserkey = null;
    }
    // 轮询内置账号登录
    for (final acc in kBuiltinAccounts) {
      final token = await _loginForToken(acc.email, acc.password);
      if (token == null) {
        // 登录即不可用：全候选地址不可用，停止轮询
        if (_unavailable) return {'success': false, 'unavailable': true};
        continue;
      }
      _builtinUserid = token.userid;
      _builtinUserkey = token.userkey;
      final res = await _doSearch(
        message,
        extensions,
        languages,
        yearFrom,
        yearTo,
        page,
        limit,
        token.userid,
        token.userkey,
      );
      if (_isSuccess(res)) return res;
      if (res['unavailable'] == true) return res; // 全候选地址不可用，停止轮询
      if (res['rate_limited'] == true) return res; // 限流，停止轮询避免加剧 429
      // 其余失败：试下一个账号（token 若失效，下次 _loginForToken 自动重登）
    }
    return {'success': false};
  }

  Future<Map<String, dynamic>> _doSearch(
    String message,
    List<String>? extensions,
    String? languages,
    int? yearFrom,
    int? yearTo,
    int page,
    int limit,
    String userid,
    String userkey,
  ) async {
    final data = <String, dynamic>{
      'message': message,
      'page': page,
      'limit': limit,
    };
    if (extensions != null && extensions.isNotEmpty) {
      data['extensions[]'] = extensions;
    }
    if (languages != null && languages.isNotEmpty) {
      data['languages[]'] = languages;
    }
    if (yearFrom != null) {
      data['yearFrom'] = yearFrom;
      data['yearTo'] = yearTo ?? yearFrom;
    }
    return _post(
      '/eapi/book/search',
      data: data,
      cookies: _cookies(userid, userkey),
    );
  }

  // -------------------- 首页推荐（热门图书）--------------------

  /// 抓取 z-library 首页热门/推荐图书（图书主页"推荐"数据源）。
  ///
  /// 走**候选镜像域名**（当前域名优先，失败自动切下一个镜像），由 WebView
  /// 自动过 CF 挑战；任一镜像成功即把该节点写回 `_domain` 并持久化。
  /// 全部镜像都失败才抛 [ZlibraryException]（unavailable / fail）。
  /// [languages] 非空时（图书页默认传 `['chinese']`）按目标语言过滤推荐：
  /// ① eapi 中文搜索（最稳）→ ② 榜单端点客户端按 [Book.language] 过滤
  /// → ③ WebView HTML /s/ 路由带 languages%5B%5D（站内行为，确定支持）。
  Future<SearchResult<Book>> fetchHomeRecommendations({
    int page = 1,
    List<String>? languages,
  }) async {
    // ✅ **先走 eapi 接口**（本轮 ✓ —— 与「搜索」同一套传输与解析 ✓✓）
    //
    // 为什么必须改 ✗：原来这里**只有** WebView 抓 `/s/?page=N&dsource=mostpopular` 的
    //   **老式 SSR HTML** ✗（解析 `z-bookcard[dsource="mostpopular"]` ✓），
    //   而新镜像（如 `z-library.my`）那个页是 **JS 渲染** ✗ ⇒
    //   **HTML 抓到了、却解析出 0 条** ✗✗ —— 这正是"搜索能出、推荐死活不显示"的根因 ✓
    //   （搜索走 `/eapi/book/search` ✓ 已在真机验证可用 ✓✓）
    //
    // 策略 ✓：**多端点依次尝试** → 命中即**早返回** ✓；
    //   全部失败/为空才**落到**下面的 WebView+HTML 逻辑 ✓（**原样保留** ✓ 双保险 ✓）。
    // 端点顺序 ✓：`most-popular`（最受欢迎 ✓ 对应你截图的区块）→ `popular` → `recent` ✓
    //   ℹ️ 未知端点会返回 404/空 ✓ 不会误判成成功 ✓（有 `items.isNotEmpty` 这道闸 ✓）
    // ✅ **端点与请求方式都已按官方文档校正**（本轮 ✓ 依据：
    //   https://github.com/baroxyton/zlibrary-eapi-documentation ✓ 这是 z-library Android App
    //   的 eapi 文档 ✓ —— 它明确写着 **`/eapi/book/most-popular`（GET）** ✓✓）：
    //   · `/eapi/book/most-popular`（**GET** ✓）← 首页「**最受欢迎**」✓（你截图那个区块 ✓）
    //   · `/eapi/book/recently`（**GET** ✓）   ← 「最近更新」✓
    //   · `/eapi/user/book/recommended`（**GET** ✓）← 「推荐」（需登录 ✓ 未登录会失败 → 跳过 ✓）
    //   ⚠️ **上轮我写错了两处** ✗（在此更正 ✓）：
    //      ① 用了 `_post(...)`（POST+body）✗ —— 而这三个都是 **GET** ✓ ⇒ 必然失败 ✗✓
    //      ② 猜的 `/eapi/book/popular` ✗ 与 `/eapi/book/recent` ✗ **都不存在** ✓
    //         真实是 `most-popular` ✓ 与 `recently` ✓（差一个字母 ✓）
    //   ℹ️ 文档另注 ✓：请求**必须带 User-Agent** ✓（本服务已有 ✓）；
    //      账号类端点需 `remix-userid`/`remix-userkey` 头 ✓（本服务 `_cookies(...)` 已处理 ✓）
    // ✅ 用户 2026-10-10「默认推荐是中文」——[languages] 非空时三级策略：
    //   ① eapi 中文搜索（内置账号 + 空关键词 + languages[]，中文区量最大最稳）
    //   ② 榜单端点命中后按 Book.language 客户端过滤（全球榜里挑目标语言）
    //   ③ WebView HTML /s/ 路由带 languages%5B%5D（确定支持）
    //   全部落空维持原异常 —— 不静默回退英文榜充数，保持"默认中文"语义 ✓。
    if (languages != null && languages.isNotEmpty) {
      try {
        // eapi search 的 languages[] 是单值参数：取第一个
        //（默认场景只有 'chinese'；'traditional+chinese' 的 + 为字面量，
        //  与分类搜索的拼法一致）
        final res = await _searchWithBuiltin(
            '', null, languages.first, null, null, page, 30);
        if (_isSuccess(res)) {
          final parsed = _parseSearch(res);
          if (parsed.items.isNotEmpty) {
            _log('首页推荐：语言搜索命中 ${parsed.items.length} 条（eapi ✓）');
            return parsed;
          }
          _log('首页推荐：语言搜索返回 0 条');
        }
      } catch (e) {
        _log('首页推荐：语言搜索失败 -> $e（继续榜单链路）');
      }
    }
    for (final path in const [
      '/eapi/book/most-popular',
      '/eapi/book/recently',
      '/eapi/user/book/recommended',
    ]) {
      try {
        final res = await _get(path); // ← **GET**（不是 _post ✗）
        var parsed = _parseSearch(res);
        // 榜单端点的语言参数支持未经验证 → 客户端按 Book.language 过滤。
        // 过滤后为空视为该端点没有目标语言内容，继续下一端点（不用英文充数）。
        if (languages != null && languages.isNotEmpty) {
          final matched = parsed.items
              .where((b) => _bookLangMatch(b, languages))
              .toList();
          if (matched.isEmpty) {
            _log('首页推荐：接口 $path 命中 ${parsed.items.length} 条但无目标语言');
            continue;
          }
          parsed = SearchResult<Book>(
            items: matched,
            total: matched.length,
            currentPage: parsed.currentPage,
            totalPages: parsed.totalPages,
          );
        }
        if (parsed.items.isNotEmpty) {
          _log('首页推荐：接口 $path 命中 ${parsed.items.length} 条（走 eapi ✓）');
          return parsed;
        }
        _log('首页推荐：接口 $path 返回 0 条');
      } catch (e) {
        final f = describeSourceFail(e, what: 'z-library 首页');
        _log('首页推荐：接口 $path 失败 -> ${f.text}（$e）');
      }
    }
    _log('首页推荐：eapi 三个端点都不可用 → 回退 WebView+HTML 老逻辑');

    final order = _candidateOrder();
    if (order.isEmpty) {
      throw ZlibraryException('unavailable', '图书功能暂不可用，请等待恢复');
    }
    Object? lastError;
    // 最多试 3 个镜像（当前节点优先）：每个最多 6s，整体 ~18s 封顶，
    // 避免镜像不可达时 WebView 逐个 30s 超时 → 主页"正在加载"卡几分钟。
    //
    // 直抓「最受欢迎」专用分类页（SSR HTML，比首页 SPA 稳定、无 JS 渲染依赖）：
    //   /s/?page=N&dsource=mostpopular
    // 对应站内排序参数 dsource=mostpopular；解析端 _parseHomeHtml 优先取
    // z-bookcard[dsource="mostpopular"]，缺省回退全量卡片（结构容错）。
    // 语言过滤参数（站内 /s/ 路由确定支持 languages%5B%5D；
    // 'traditional+chinese' 的 + 为字面量不编码，与分类搜索一致）
    final langQuery = (languages == null || languages.isEmpty)
        ? ''
        : languages.map((l) => '&languages%5B%5D=$l').join();
    for (final domain in order.take(3)) {
      final url =
          'https://$domain/s/?page=$page&dsource=mostpopular$langQuery';
      _log('抓取最受欢迎分类页: $url');
      String? htmlStr;
      for (var attempt = 1; attempt <= 2; attempt++) {
        try {
          final html = await WebViewImageFetcher()
              .fetchHtml(url)
              .timeout(const Duration(seconds: 6));
          if (html.isNotEmpty) {
            htmlStr = html;
            break;
          }
          lastError = StateError('首页返回空 HTML');
        } catch (e) {
          lastError = e;
        }
        _log('$domain 第 $attempt/2 次失败: $lastError');
        if (attempt < 2) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
      if (htmlStr == null) {
        _log('节点 $domain 失败，自动切下一镜像');
        continue;
      }
      final books = _parseHomeHtml(htmlStr);
      if (books.isEmpty) {
        _log('$domain 解析到 0 条，HTML 长度=${htmlStr.length}，切下一镜像');
        continue;
      }
      // 节点可用 → 写回 _domain 并持久化
      if (domain != _domain) {
        _domain = domain;
        await _persistDomain();
      }
      _setUnavailable(false);
      _log('首页推荐解析到 ${books.length} 条（$domain），前两条: '
          '${books.take(2).map((b) => b.title).join(", ")}');
      return SearchResult<Book>(
        items: books,
        total: books.length,
        currentPage: page,
        totalPages: 1,
      );
    }
    // 🔴 这里原来无条件 `_setUnavailable(true)` ✗ —— 但本函数的失败其实有两种：
    //   · **拿不到页面** → 节点真的不可达 ✓
    //   · **拿到了页面但解析出 0 条**（DOM 改版 / 选择器失效，见 :1160-1163 ✗）
    // 两者被判成同一件事 ✗ → 界面弹「所有 z-library 节点不可用，图书功能暂不可用」
    // 并**永久隐藏分类入口**（book_search_page.dart:390 ✗），而搜索其实仍然可用 ✓
    // —— 误导用户 + 不会自愈（只有某次搜索成功才会复位 ✗）。
    //
    // 现在本函数**不再擅自判定"节点不可用"** ✓：可达性交给真正能验证的路径
    //（搜索成功会 `_setUnavailable(false)`；失败才置 true ✓）。
    // 这里只如实说明"推荐解析不出来"，不再谎报节点全挂 ✓。
    _log('首页推荐全部失败（节点可达性未知，可能是解析失效）: $lastError');
    throw ZlibraryException(
        'fail', '推荐解析为空：页面结构可能已变更（可稍后重试，或检查节点）');
  }

  /// 客户端语言匹配：[Book.language]（如 'chinese'/'english'）与目标语言值
  /// （'chinese' / 'traditional+chinese' → 按 + 拆分后逐段包含）匹配。
  bool _bookLangMatch(Book book, List<String> langs) {
    final bl = (book.language ?? '').toLowerCase();
    if (bl.isEmpty) return false;
    for (final l in langs) {
      final parts = l.toLowerCase().split('+');
      if (parts.every(bl.contains)) return true;
    }
    return false;
  }

  /// 解析 z-library 首页 HTML（推荐区块，卡片结构与分类页相同）。
  ///
  /// 首页有多个区块（最受欢迎 / 今日图书 / 最新上架等），优先只取
  /// **最受欢迎**（`z-bookcard[dsource="mostpopular"]`，对应站内
  /// `?dsource=mostpopular` 区块）；新版若无 dsource 属性则回退收集全部
  /// `z-bookcard`，按 id 去重，保持 DOM 顺序。
  List<Book> _parseHomeHtml(String htmlStr) {
    final doc = html_parser.parse(htmlStr);
    var rows = doc.querySelectorAll('z-bookcard[dsource="mostpopular"]');
    if (rows.isEmpty) {
      // 兼容旧版 DOM：没有 dsource 属性 → 全量卡片
      rows = doc.querySelectorAll('z-bookcard');
    }
    final books = <Book>[];
    final seenIds = <String>{};
    for (final r in rows) {
      try {
        final book = _parseBookRow(r);
        if (book != null && book.id.isNotEmpty && !seenIds.contains(book.id)) {
          seenIds.add(book.id);
          books.add(book);
        }
      } catch (_) {}
    }
    return books;
  }

  // -------------------- 下载链接 --------------------

  /// 获取下载链接。已登录自有账号用自有 token，否则按 round-robin 起点轮询内置账号。
  /// 失败按原因抛 ZlibraryException：quota_exceeded / no_login / unavailable / no_account / fail。
  /// 对应 cmbook Zlibrary.getDownloadLink + BookDownload._download_with_builtin_account。
  /// [startIndex] 用于内置账号轮询起点（按已用计数均匀分散到各账号）。
  ///
  /// 兼容：[bookHash] 不是 eapi hash（6 位 hex）而是 `/dl/{slug}` 的 slug 形式
  /// 或 `dl/{slug}`（来自分类页 z-bookcard download 属性）时，eapi 端点不可用，
  /// 改走 WebView 加载短链取重定向后的真实 CDN 下载地址。
  Future<DownloadLink> getDownloadLink(
    String bookId,
    String bookHash, {
    int startIndex = 0,
  }) async {
    // 分类页来源：hash 是 /dl/{slug} 或纯 slug（非 6 位 hex eapi hash）
    if (_isDlSlug(bookHash)) {
      _log('检测到 dl slug，走 WebView 解析下载: $bookHash');
      return _getDownloadLinkByDlSlug(bookId, bookHash);
    }
    final useBuiltin = SettingsService().useBuiltinAccount;
    if (isLoggedIn) {
      final link = await _fetchDownloadLink(
        bookId,
        bookHash,
        _remixUserid,
        _remixUserkey,
      );
      if (link != null) return link;
      // 失败：区分额度用完/token 失效/地址不可用/真失败
      switch (await _diagnoseDownloadFailure()) {
        case 'quota_exceeded':
          throw ZlibraryException('quota_exceeded', '账号今日额度已用完');
        case 'unavailable':
          throw ZlibraryException('unavailable', '图书功能暂不可用，请等待恢复');
        case 'no_login':
          await _clearSelfToken();
          throw ZlibraryException('no_login', '登录已失效，请重新登录');
        default:
          if (!useBuiltin) {
            throw ZlibraryException('fail', '获取下载链接失败，请稍后重试');
          }
          _log('自登取链接失败，回退内置账号');
      }
    } else if (!useBuiltin) {
      // 关闭内置账号且未登录：无可用账号
      throw ZlibraryException('no_login', '请先登录账号');
    }
    // 内置账号轮询
    final n = kBuiltinAccounts.length;
    var anyQuotaExceeded = false;
    for (var i = 0; i < n; i++) {
      final acc = kBuiltinAccounts[(startIndex + i) % n];
      final token = await _loginForToken(acc.email, acc.password);
      if (token == null) {
        // 登录即不可用：全候选地址不可用，立即返回（与搜索一致，不遍历全部账号）
        if (_unavailable) {
          throw ZlibraryException('unavailable', '图书功能暂不可用，请等待恢复');
        }
        continue;
      }
      final link = await _fetchDownloadLink(
        bookId,
        bookHash,
        token.userid,
        token.userkey,
      );
      if (link != null) return link;
      if (_quotaExceeded) {
        // 各账号额度独立，记录后试下一个
        anyQuotaExceeded = true;
        continue;
      }
      if (_unavailable) {
        throw ZlibraryException('unavailable', '图书功能暂不可用，请等待恢复');
      }
      // 其余失败：试下一个账号
    }
    // 全部内置账号失败
    if (anyQuotaExceeded) {
      throw ZlibraryException('quota_exceeded', '账号今日额度已用完');
    }
    throw ZlibraryException('no_account', '没有可用的内置账号');
  }

  Future<DownloadLink?> _fetchDownloadLink(
    String bookId,
    String bookHash,
    String userid,
    String userkey,
  ) async {
    _quotaExceeded = false;
    final res = await _get(
      '/eapi/book/$bookId/$bookHash/file',
      cookies: _cookies(userid, userkey),
    );
    if (res['unavailable'] == true) return null; // _unavailable 已由 _send 置位
    if (!_isSuccess(res) || res['file'] is! Map) return null;
    final file = res['file'] as Map;
    if (!_isTruthy(file['allowDownload'])) {
      // 额度用完：disallowDownloadMessage 含 "limit"（z-library 免费账号 10 本/日）
      final msg = (file['disallowDownloadMessage'] ?? '')
          .toString()
          .toLowerCase();
      if (msg.contains('limit')) _quotaExceeded = true;
      return null;
    }
    final ddl = (file['downloadLink'] ?? '').toString();
    if (ddl.isEmpty) return null;
    var filename = (file['description'] ?? '').toString();
    final author = file['author'];
    if (author != null) filename += ' ($author)';
    filename += '.${file['extension'] ?? 'epub'}';
    final headers = <String, String>{'User-Agent': _browserUa};
    try {
      headers['authority'] = ddl.split('/')[2];
    } catch (_) {}
    return DownloadLink(filename: filename, url: ddl, headers: headers);
  }

  /// 判断 [bookHash] 是否是 z-library `/dl/{slug}` 下载短链 slug，
  /// 而非 eapi 的 6 位 hex hash（如 "0ce60f"）。
  /// 规则：含 `/dl/` 前缀、或长度 != 6、或非纯 hex，视为 dl slug。
  bool _isDlSlug(String bookHash) {
    if (bookHash.isEmpty) return false;
    return bookHash.startsWith('dl/') || bookHash.contains('/dl/');
  }

  /// 分类页 /dl/{slug} 短链：用临时 Dio 跟随重定向链，从最终的 URL 取真实 CDN 地址。
  /// `_dio` 主请求禁重定向（用于 eapi），这里临时构造一个 Dio 走 followRedirects。
  /// 登录 cookie 不需要（z-library dl 短链免登录靠 IP 限额），仅带浏览器 UA 头。
  /// 若 Dio 被 CF 拦（返回 HTML 挑战页），回退到 WebView 解析兜底。
  Future<DownloadLink> _getDownloadLinkByDlSlug(
    String bookId,
    String bookHash,
  ) async {
    var slug = bookHash;
    final m = RegExp(r'/?dl/([0-9a-zA-Z_-]+)').firstMatch(slug);
    if (m != null) slug = m.group(1)!;
    final shortUrl = 'https://$_domain/dl/$slug';
    // 临时构造跟随重定向的 Dio
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        followRedirects: true,
        maxRedirects: 5,
        validateStatus: (_) => true,
        headers: {'User-Agent': _browserUa},
      ),
    );
    // ✅ **走全局代理**（本轮接上 ✓，与本文件 `_createDio()` 同款 ✓）——
    //   关着时 `applyGlobalProxy` **直接返回、连适配器都不换** ✓✓（零副作用 ✓）。
    applyGlobalProxy(dio);
    try {
      // 带 z-library 登录 cookie（内置/自登均可，提高成功率）
      final cookies = isLoggedIn ? _cookies(_remixUserid, _remixUserkey) : null;
      final resp = await dio.get<dynamic>(
        shortUrl,
        options: Options(
          headers: cookies != null && cookies.isNotEmpty
              ? {
                  'Cookie': cookies.entries
                      .map((e) => '${e.key}=${e.value}')
                      .join('; '),
                }
              : null,
        ),
      );
      // 跟随后 final URL
      final realUrl = resp.realUri.toString();
      // 防止 CF 挑战页（被拦到 HTML）：判定 URL host 是否在 CDN
      final isCdn = realUrl != shortUrl && Uri.parse(realUrl).host != _domain;
      if (isCdn) {
        _log('解析下载链接成功(dio): $realUrl');
        final headers = <String, String>{'User-Agent': _browserUa};
        try {
          headers['authority'] = realUrl.split('/')[2];
        } catch (_) {}
        return DownloadLink(
          filename: '$bookId.bin',
          url: realUrl,
          headers: headers,
        );
      }
      _log('Dio 未能跨域到 CDN，realUrl=$realUrl，回退 WebView');
    } catch (e) {
      _log('Dio 解析下载链接失败: $e');
    } finally {
      dio.close();
    }
    // 兜底：WebView 拦截重定向
    try {
      final realUrl = await WebViewImageFetcher().resolveDownloadUrl(shortUrl);
      if (realUrl.isNotEmpty) {
        _log('解析下载链接成功(webview): $realUrl');
        final headers = <String, String>{'User-Agent': _browserUa};
        try {
          headers['authority'] = realUrl.split('/')[2];
        } catch (_) {}
        return DownloadLink(
          filename: '$bookId.bin',
          url: realUrl,
          headers: headers,
        );
      }
    } catch (e) {
      _log('WebView 兜底解析失败: $e');
    }
    throw ZlibraryException('fail', '获取下载链接失败，请稍后重试');
  }

  /// 复校 token 是否仍有效（运行时 API 失败时调用，区分 token 失效 vs 真失败）。
  /// 返回 valid=token 有效（按真失败处理）/ invalid=token 失效（需重新登录）/ unavailable=地址不可用。
  /// 对应 cmbook Zlibrary.verifyToken。
  Future<_TokenState> _verifyToken() async {
    final res = await _get(
      '/eapi/user/profile',
      cookies: _cookies(_remixUserid, _remixUserkey),
    );
    if (res['unavailable'] == true) return _TokenState.unavailable;
    if (_isSuccess(res)) return _TokenState.valid;
    return _TokenState.invalid;
  }

  /// 清除自有账号登录态（token 失效时调用，提示用户重新登录）。
  Future<void> _clearSelfToken() async {
    _remixUserid = '';
    _remixUserkey = '';
    _serverDownloadsLimit = null;
    _serverDownloadsToday = 0;
    await _persistAuth();
    _log('自登 token 失效，已清登录态');
    notifyListeners();
  }

  /// 诊断下载链接获取失败的原因（额度用完优先于 token 复校）。
  /// 返回 'quota_exceeded' / 'unavailable' / 'no_login' / 'fail'。
  Future<String> _diagnoseDownloadFailure() async {
    if (_quotaExceeded) return 'quota_exceeded';
    if (_unavailable) return 'unavailable';
    switch (await _verifyToken()) {
      case _TokenState.unavailable:
        return 'unavailable';
      case _TokenState.invalid:
        return 'no_login';
      case _TokenState.valid:
        return 'fail';
    }
  }

  // -------------------- 每日限额（对应 cmbook reserve/release）--------------------

  /// 今日内置账号已下载数（跨日归零）
  int get builtinCountToday {
    final today = _today();
    final d = _builtinCountCache['date'] as String? ?? '';
    return d == today ? (_builtinCountCache['count'] as int? ?? 0) : 0;
  }

  /// 今日自有账号已下载数（纯服务端值，来自 /eapi/user/profile；不使用本地计数）
  int get loggedCountToday => isLoggedIn ? _serverDownloadsToday : 0;

  /// 预留一个内置下载名额（计数+1）。超限返回 null；成功返回轮询起点 index。
  int? reserveBuiltinDownload() {
    final today = _today();
    var count = (_builtinCountCache['date'] == today
        ? (_builtinCountCache['count'] as int? ?? 0)
        : 0);
    if (count >= builtinDailyLimit) return null;
    count++;
    _writeBuiltinCount(today, count);
    return (count - 1) % kBuiltinAccounts.length;
  }

  void releaseBuiltinDownload() {
    final today = _today();
    if (_builtinCountCache['date'] != today) return;
    final count = _builtinCountCache['count'] as int? ?? 0;
    if (count > 0) _writeBuiltinCount(today, count - 1);
  }

  /// 自登账号纯服务端判定：仅按服务端 downloads_today 判断是否还有额度，不自增本地计数。
  /// 实际额度由服务端在下载链接阶段强制（quota_exceeded）；此处仅做前置拦截。
  bool reserveLoggedDownload() {
    if (!isLoggedIn) return false;
    if (_serverDownloadsToday >= (_serverDownloadsLimit ?? loggedDailyLimit)) {
      return false;
    }
    return true;
  }

  /// 自登账号纯服务端判定：不维护本地计数，无需释放。
  void releaseLoggedDownload() {}

  /// 拉取自有账号 profile，取服务端每日下载限额与已下载数。
  /// 自登账号纯服务端判定：不维护本地计数，每次重启 App 后由此方法重新拉取最新值。
  /// 失败静默保留旧值（_log）。对应 z-library /eapi/user/profile。
  Future<void> refreshUserProfile() async {
    if (!isLoggedIn) return;
    final res = await _get(
      '/eapi/user/profile',
      cookies: _cookies(_remixUserid, _remixUserkey),
    );
    if (!_isSuccess(res) || res['user'] is! Map) {
      _log('拉取 profile 失败: $res');
      return;
    }
    final user = res['user'] as Map;
    _serverDownloadsToday = _asInt(user['downloads_today']) ?? 0;
    _serverDownloadsLimit = _asInt(user['downloads_limit']);
    _log(
      'profile: downloads_today=$_serverDownloadsToday, '
      'downloads_limit=$_serverDownloadsLimit',
    );
    notifyListeners();
  }

  // -------------------- HTTP 基础（对应 cmbook __makePostRequest/__makeGetRequest）--------------------

  Map<String, String> _cookies(String userid, String userkey) => {
    'siteLanguageV2': 'zh',
    'remix_userid': userid,
    'remix_userkey': userkey,
  };

  Future<Map<String, dynamic>> _post(
    String path, {
    Map<String, dynamic>? data,
    Map<String, String>? cookies,
  }) => _send('POST', path, data: data, cookies: cookies);

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, dynamic>? params,
    Map<String, String>? cookies,
  }) => _send('GET', path, params: params, cookies: cookies);

  /// 候选感知请求：遍历候选域名，对每域名做 429/5xx 退避重试；
  /// 连接异常（DNS/超时/重置）与 404（域名非 z-library 主机）都切下一个候选；
  /// 重定向到新域名 -> 更新+加候选+在新域名重试一次（followed 防循环）。
  /// 全候选连接失败/全 404 -> 标记 unavailable 返回 {success:false,unavailable:true}。
  /// 对应 cmbook Zlibrary.__request_with_retry + __makePostRequest/__makeGetRequest。
  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? data,
    Map<String, dynamic>? params,
    Map<String, String>? cookies,
  }) async {
    var followed = false;
    DioException? lastConnError;
    var any404 = false;
    for (;;) {
      final order = _candidateOrder();
      var restartForRedirect = false;
      for (final domain in order) {
        try {
          var attempt = 0;
          while (true) {
            _log('$method https://$domain$path');
            final Response<dynamic> resp;
            if (method == 'POST') {
              resp = await _dio.post(
                'https://$domain$path',
                data: data,
                options: Options(
                  headers: _headers(cookies),
                  contentType: Headers.formUrlEncodedContentType,
                ),
              );
            } else {
              resp = await _dio.get(
                'https://$domain$path',
                queryParameters: params,
                options: Options(headers: _headers(cookies)),
              );
            }
            final status = resp.statusCode;
            // 403：被 Cloudflare 拦截（镜像级反爬），切下一候选
            if (status == 403) {
              _log('节点 $domain 返回 403（可能被 Cloudflare 拦截），切下一候选');
              break;
            }
            // 404：域名非 z-library 主机，切下一候选
            if (status == 404) {
              any404 = true;
              _log('节点 $domain 返回 404（非 z-library 主机），切下一候选');
              break;
            }
            // 重定向到新域名：更新+加候选+在新域名重试一次
            final redirected = _maybeRedirect(
              status,
              resp.headers.value('location'),
            );
            if (redirected != null && !followed) {
              _domain = redirected;
              await _persistDomain();
              _addCandidate(redirected);
              _log('域名重定向 -> $_domain');
              followed = true;
              restartForRedirect = true;
              break;
            }
            // 429/5xx：同域名退避重试
            if (status != null && _kRetryStatus.contains(status)) {
              if (attempt >= _kMaxRetries) {
                // 5xx 服务端错误：退避耗尽说明该镜像异常，切下一候选；
                // 429 是全站限流，切镜像无意义，保持 rate_limited 提示
                if (status != 429) {
                  _log('节点 $domain 持续 $status，退避耗尽，切下一候选');
                  break;
                }
                if (domain != _domain) {
                  _domain = domain;
                  await _persistDomain();
                }
                _setUnavailable(false);
                return {
                  'success': false,
                  'rate_limited': true,
                  'error': '请求过于频繁，请稍后再试',
                };
              }
              await _retryWait(resp, attempt);
              attempt++;
              continue;
            }
            // 业务响应（含已跟随重定向/非重定向）
            if (domain != _domain) {
              _domain = domain;
              await _persistDomain();
            }
            _setUnavailable(false);
            return _asJsonMap(resp.data);
          }
          if (restartForRedirect) break; // 重启外层，新域名优先
          // 否则 404 跳出内层 -> 试下一候选
        } on DioException catch (e) {
          // 连接失败（DNS/超时/重置）：切下一候选
          lastConnError = e;
          _log('节点 $domain 不可达: $e，切下一候选');
          continue;
        }
      }
      if (restartForRedirect) continue; // 用新 _domain 重算候选顺序重试
      break; // 全候选耗尽
    }
    // 全候选连接失败 或 全 404
    _setUnavailable(true);
    _log('所有 zlibrary 节点不可达或 404（any404=$any404, err=$lastConnError）');
    return {'success': false, 'unavailable': true, 'error': '图书功能暂不可用'};
  }

  /// 429/5xx 退避：优先 Retry-After，否则指数退避 2/4/8s，上限 8s。
  Future<void> _retryWait(Response<dynamic> resp, int attempt) async {
    var ms = (1 << (attempt + 1)) * 1000; // 2s, 4s, 8s
    final ra = resp.headers.value('retry-after');
    if (ra != null) {
      final v = int.tryParse(ra);
      if (v != null) ms = v * 1000;
    }
    if (ms > 8000) ms = 8000;
    await Future.delayed(Duration(milliseconds: ms));
  }

  /// 301/302/303/307/308 且 Location 指向新域名 -> 返回新域名；否则 null
  String? _maybeRedirect(int? status, String? location) {
    if (status == null || ![301, 302, 303, 307, 308].contains(status))
      return null;
    if (location == null || location.isEmpty) return null;
    final host = Uri.tryParse(location)?.host;
    if (host != null && host.isNotEmpty && host != _domain) return host;
    return null;
  }

  Map<String, String> _headers(Map<String, String>? cookies) {
    final h = <String, String>{
      'User-Agent': _browserUa,
      'accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
      'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8',
    };
    if (cookies != null && cookies.isNotEmpty) {
      h['Cookie'] = cookies.entries
          .map((e) => '${e.key}=${e.value}')
          .join('; ');
    }
    return h;
  }

  bool _isSuccess(dynamic res) => res is Map && _isTruthy(res['success']);

  /// z-library eapi 的成功/允许标志返回的是整数 1 而非布尔 true
  /// （如 success、allowDownload），需按真值判断，对应 Python if res.get('success')。
  bool _isTruthy(dynamic v) => v == true || v == 1;

  Map<String, dynamic> _asJsonMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String && data.isNotEmpty) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return {};
  }

  int? _asInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return int.tryParse('$v');
  }

  /// 内置账号登录取 token（仅内存，不持久化）
  Future<_Token?> _loginForToken(String email, String password) async {
    final res = await _post(
      '/eapi/user/login',
      data: {'email': email, 'password': password},
    );
    if (_isSuccess(res) && res['user'] is Map) {
      final user = res['user'] as Map;
      final uid = (user['id'] ?? '').toString();
      final key = (user['remix_userkey'] ?? '').toString();
      if (uid.isNotEmpty && key.isNotEmpty) return _Token(uid, key);
    }
    return null;
  }

  // -------------------- 计数持久化 --------------------

  Map<String, dynamic> _builtinCountCache = {};

  Future<void> _loadCounts() async {
    final prefs = await SharedPreferences.getInstance();
    _builtinCountCache = _decode(prefs.getString(_kBuiltinCount));
  }

  void _writeBuiltinCount(String today, int count) {
    _builtinCountCache = {'date': today, 'count': count};
    final raw = jsonEncode(_builtinCountCache);
    SharedPreferences.getInstance().then(
      (p) => p.setString(_kBuiltinCount, raw),
    );
  }

  Map<String, dynamic> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final d = jsonDecode(raw);
      if (d is Map) return Map<String, dynamic>.from(d);
    } catch (_) {}
    return {};
  }

  /// 解析持久化的候选节点列表（JSON 数组），异常/空返回 []。
  List<String> _decodeCandidates(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final d = jsonDecode(raw);
      if (d is List) {
        return d
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
    } catch (_) {}
    return [];
  }

  String _today() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }

  // -------------------- 多节点容灾（对应 cmbook StartupCheckThread + ZlibraryHealthCheckThread）--------------------

  /// 应用云端候选节点：归一化 + 并发探测选最优写回 _domain + 写完整候选列表。
  /// 由 RemoteConfigService 拉到云端 zlibrary_url 后调用（启动检测，不阻塞 UI）。
  /// 全不可用仍写候选列表（供定时检测与运行时切换），并标记 unavailable。
  Future<void> applyCloudCandidates(Object? cloud) async {
    final candidates = _normalizeCandidates(cloud);
    if (candidates.isEmpty) return;
    _log('应用云端候选节点: $candidates');
    final best = await _pickBestCandidate(candidates);
    if (candidates != _candidates) {
      _candidates = candidates;
      await _persistCandidates();
    }
    if (best != null && best != _domain) {
      _domain = best;
      await _persistDomain();
    }
    _setUnavailable(best == null);
    _log('启动探测完成: best=$best, unavailable=${best == null}');
    notifyListeners();
  }

  /// 归一化候选列表（去重保序；单字符串 -> 单元素列表）。
  List<String> _normalizeCandidates(Object? raw) {
    final List items;
    if (raw is String) {
      items = [raw];
    } else if (raw is List) {
      items = raw;
    } else {
      return [];
    }
    final seen = <String>{};
    final result = <String>[];
    for (final item in items) {
      final d = item.toString().trim();
      if (d.isNotEmpty && !seen.contains(d)) {
        seen.add(d);
        result.add(d);
      }
    }
    return result;
  }

  /// 并发探测候选节点，返回延迟最低的可用域名（无 scheme）。
  /// 探测到延迟 < 3s 的可用节点即提前返回，不再等其余候选；全不可用返回 null。
  /// 对应 cmbook StartupCheckThread._pick_best_zlibrary_url。
  Future<String?> _pickBestCandidate(List<String> candidates) async {
    if (candidates.isEmpty) return null;
    final completer = Completer<String?>();
    final collected = <_Probe>[];
    var remaining = candidates.length;
    for (final c in candidates) {
      _probeUrl(c).then((r) {
        if (completer.isCompleted) return;
        if (r != null) {
          collected.add(r);
          if (r.latency < 3.0) {
            completer.complete(r.domain); // <3s 提前返回
            return;
          }
        }
        remaining--;
        if (remaining == 0) {
          if (collected.isEmpty) {
            completer.complete(null);
          } else {
            collected.sort((a, b) => a.latency.compareTo(b.latency));
            completer.complete(collected.first.domain);
          }
        }
      });
    }
    return completer.future;
  }

  /// [PATCH-19] eapi 健康探测：`GET {base}/eapi/book/most-popular`。
  ///
  /// 判"可用"的条件（三者必须同时满足）：
  ///   1. HTTP 200（其它状态码说明被 CF 拦或不是 z-library 主机）；
  ///   2. 正文能解析成 JSON 且 `success` 为真（该字段是整数 1，用 `_isTruthy`）；
  ///   3. `books` 是非空数组（镜像没同步数据时会是空/缺失 ⇒ 不算可用）。
  ///
  /// 连接异常重试 1 次（跨境网络抖动），仍失败返回 null 交给首页兜底。
  Future<_Probe?> _probeEapi(Dio dio, String target, String url) async {
    final base =
        target.endsWith('/') ? target.substring(0, target.length - 1) : target;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final sw = Stopwatch()..start();
        final resp = await dio.get(
          '$base/eapi/book/most-popular',
          options: Options(headers: {
            'accept': 'application/json, text/plain, */*',
          }),
        );
        final latency = sw.elapsedMilliseconds / 1000.0;
        if (resp.statusCode == 200) {
          final map = _asJsonMap(resp.data);
          final books = map['books'];
          if (_isTruthy(map['success']) && books is List && books.isNotEmpty) {
            _log('探测器 eapi 判定 $url 可用（${books.length} 条，${latency}s）');
            return _Probe(_finalHostOf(resp, target), latency);
          }
          _log('探测 $url eapi 返回 200 但无有效 books（镜像可能未同步）');
        } else {
          _log('探测 $url eapi 状态码 ${resp.statusCode}');
        }
        return null; // 有响应但内容不合格 ⇒ 交给首页兜底
      } on DioException catch (e) {
        _log('探测 $url eapi 第${attempt + 1}次失败: $e');
        if (attempt == 1) return null;
      } catch (e) {
        _log('探测 $url eapi 异常: $e');
        return null;
      }
    }
    return null;
  }

  /// 跟随重定向后的最终域名；无重定向则用 [target] 的 host。
  String _finalHostOf(Response<dynamic> resp, String target) {
    if (resp.redirects.isNotEmpty) {
      final h = resp.redirects.last.location.host;
      if (h.isNotEmpty) return h;
    }
    return Uri.tryParse(target)?.host ?? target;
  }

  /// 探测单个节点可用性，跟随重定向，返回 (最终落地域名, 延迟秒)；不可用返回 null。
  ///
  /// ── [PATCH-19] 判据从"首页"改成 **eapi 优先** ──────────────────────
  /// 实测依据（2026-10-06）：
  /// ```
  /// zh.zlib.li  首页 → HTTP 503      /eapi/book/most-popular → 200  success=1  books=100
  /// zlib.li     首页 → HTTP 503      /eapi/book/most-popular → 200  success=1  books=100
  /// ```
  /// ⇒ 探首页会把**完全可用**的节点误判为不可用 —— 这正是此前把 `zh.zlib.li`
  ///   从候选里删掉的原因。而本服务后续**所有**请求都走 eapi ⇒ eapi 才是
  ///   正确的健康判据。
  /// 顺序：① eapi（200 且 success 且 books 非空）→ ② 退回首页探测
  ///   （兼容只提供网页、或 eapi 需登录态的镜像；CF 挑战页仍判不可用）。
  /// 对应 cmbook StartupCheckThread._probe_zlibrary_url（其"根路径常返 503"
  /// 的注释恰好说明首页判据不可靠）。
  Future<_Probe?> _probeUrl(String url) async {
    if (url.isEmpty) return null;
    final target = url.startsWith('http://') || url.startsWith('https://')
        ? url
        : 'https://$url';
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        followRedirects: true,
        validateStatus: (_) => true,
        headers: {
          'user-agent': _browserUa,
          'accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
        },
      ),
    );
    // ✅ **走全局代理**（本轮接上 ✓ —— 本文件第 3 个、也是最后一个 Dio ✓）：
    //   至此 **z-library 的每一个请求都受「网络代理」开关控制** ✓✓；
    //   开关关着时 `applyGlobalProxy` **连适配器都不换** ✓（零副作用 ✓ 不影响其它模块 ✓）。
    applyGlobalProxy(dio);

    // ── [PATCH-19] ① 先用 eapi 判健康（首页 503 但 eapi 200 的节点不能被误杀）──
    final eapiProbe = await _probeEapi(dio, target, url);
    if (eapiProbe != null) return eapiProbe;

    // ── ② eapi 不通时退回首页探测（见方法头注释的取舍说明）──
    // 连接异常重试 1 次（对抗跨境网络瞬时抖动，避免单次超时误判不可用）
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final sw = Stopwatch()..start();
        final resp = await dio.get(target);
        final latency = sw.elapsedMilliseconds / 1000.0;
        // 取最终落地域名（跟随重定向后）
        String finalHost;
        if (resp.redirects.isNotEmpty) {
          final h = resp.redirects.last.location.host;
          finalHost = h.isNotEmpty ? h : url;
        } else {
          finalHost = Uri.tryParse(target)?.host ?? url;
        }
        // 业务校验：空响应 / CF 挑战页 / 拦截页不算"可用"，
        // 否则会出现"探测通过但页面拉不到内容"的假象
        final body = resp.data;
        if (body is String) {
          final t = body.toLowerCase();
          if (body.isEmpty ||
              t.contains('just a moment') ||
              t.contains('cf-chl') ||
              t.contains('challenge-platform') ||
              t.contains('__cf_chl')) {
            _log('探测 $url 返回空内容或 Cloudflare 挑战页，判不可用');
            return null;
          }
        }
        return _Probe(finalHost, latency);
      } on DioException catch (e) {
        _log('探测 $url 第${attempt + 1}次失败: $e');
        if (attempt == 1) return null;
      } catch (e) {
        _log('探测 $url 失败: $e');
        return null;
      }
    }
    return null;
  }

  /// 定时健康检查（30 分钟）：先探当前域名，可用则保持；不可用才从候选重新选最优。
  /// 仅状态变化才 notify（_setUnavailable 内部守卫）。对应 cmbook _probe_candidates。
  Future<void> _healthCheck() async {
    // 夜间（23:00~次日 07:00 本地时间）不探测，避免无谓的后台联网唤醒
    final h = DateTime.now().hour;
    if (h < 7 || h >= 23) return;
    if (_candidates.isEmpty) return; // 无候选列表，沿用本地，不误报
    _log('定时健康检查: domain=$_domain, candidates=$_candidates');
    // 先探当前域名：可用则保持
    if (_domain.isNotEmpty) {
      final probe = await _probeUrl(_domain);
      if (probe != null) {
        _setUnavailable(false);
        return;
      }
    }
    // 当前不可用：从候选重新探测选最优
    final best = await _pickBestCandidate(_candidates);
    if (best != null) {
      if (best != _domain) {
        _domain = best;
        await _persistDomain();
      }
      _setUnavailable(false);
    } else {
      _setUnavailable(true);
    }
    notifyListeners();
  }
}

class _Probe {
  final String domain;
  final double latency;
  const _Probe(this.domain, this.latency);
}

class _Token {
  final String userid;
  final String userkey;
  const _Token(this.userid, this.userkey);
}
