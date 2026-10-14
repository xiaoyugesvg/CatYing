import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:get/get.dart';
import '../models/source_bean.dart';
import 'api_config.dart';
import 'ad_filter_service.dart';
import 'app_log.dart';
import 'nodejs_manager.dart';
import 'python_manager.dart';
import 'python_script_sources.dart';
import 'python_sources_service.dart';
import 'scene_recovery.dart';
import 'spider_service.dart';

/// 加载阶段 - 对应 Swift LoadingPhase
enum LoadingPhase {
  idle,
  loadingConfig,
  startingNodeJS,
  downloadingNodeJS,
  downloadingSource,
  verifyingMD5,
  loadingSource,
  waitingSpiderPort,
  fetchingSpiderConfig,
  initializingSpider,
  reconnecting,
  completed,
  failed,
}

/// 加载阶段描述 - 对应 Swift LoadingPhase.displayText
extension LoadingPhaseDesc on LoadingPhase {
  String get description {
    switch (this) {
      case LoadingPhase.idle:
        return '';
      case LoadingPhase.loadingConfig:
        return '正在加载配置...';
      case LoadingPhase.startingNodeJS:
        return '正在启动 Node.js 运行时...';
      case LoadingPhase.downloadingNodeJS:
        return '首次启动需要下载 Node.js 运行时...';
      case LoadingPhase.downloadingSource:
        return '正在下载源文件...';
      case LoadingPhase.verifyingMD5:
        return '正在校验文件完整性...';
      case LoadingPhase.loadingSource:
        return '正在加载 Spider 源...';
      case LoadingPhase.waitingSpiderPort:
        return '等待 Spider 服务就绪...';
      case LoadingPhase.fetchingSpiderConfig:
        return '正在获取线路配置...';
      case LoadingPhase.initializingSpider:
        return '正在初始化 Spider...';
      case LoadingPhase.reconnecting:
        return '正在重连服务...';
      case LoadingPhase.completed:
        return '加载完成';
      case LoadingPhase.failed:
        return '加载失败';
    }
  }

  /// 是否正在加载 - 对应 Swift LoadingPhase.isLoading
  bool get isLoading =>
      this != LoadingPhase.idle &&
      this != LoadingPhase.completed &&
      this != LoadingPhase.failed;

  /// 是否失败 - 对应 Swift LoadingPhase.isFailed
  bool get isFailed => this == LoadingPhase.failed;
}

/// 应用状态控制器 - 对应 Swift AppState
/// 管理整个配置加载生命周期
class AppState extends GetxController {
  /// main() 里**同步**读到的「已保存的点播接口地址」——给首帧用。
  ///
  /// 为什么要有它（用户 2026-10-13：「打开软件会闪一哈，相当于第一次打开那个
  /// 填入订阅页面重新加载一遍」）：
  ///   `shared_preferences` 只有异步 API，而 `ContentView._hasSavedConfig`
  ///   初值是 false、要等 `_loadSavedConfig()` 跑完才变 true ⇒ 冷启动时
  ///   **第一帧先渲染「填入订阅」页**，紧接着才切成加载页 → 视觉上"闪一哈"。
  ///   而 main() 早就 await 过 prefs 并读到了这个值 ⇒ 顺手静态存一份，
  ///   ContentView 首帧就知道"用户有配置"，那一帧设置页根本不会渲染。
  static String startupSavedApiUrl = '';

  final loadingPhase = LoadingPhase.idle.obs;
  final isConfigLoaded = false.obs;
  final currentSourceKey = ''.obs;
  final configLoadError = Rx<String?>(null);
  final isRetryingConfig = false.obs;
  final pendingSearchKeyword = Rx<String?>(null);
  final showAboutOnLaunch = false.obs;

  String _lastVodUrl = '';
  bool _nodeJSStarted = false;

  /// 本次会话已成功加载过 Spider 源（Node.js 已持有源脚本）。
  /// 再次启动加载流程时直接复用, 不再走"下载源文件"检查与提示。
  bool _sourceLoadedThisSession = false;

  /// 本次会话已载入 Node 的主源脚本 api（与 [_sourceLoadedThisSession] 配套）。
  ///
  /// 为什么必须按 api 记忆而不是一个裸 bool：切换订阅后新订阅的主源 api
  /// 变了，若仍凭「本会话加载过」跳过 loadSource，Node 引擎里驻留的还是
  /// **上一个订阅的脚本**，随后 /config 拿回旧线路表并整表替换——
  /// 表现为「切订阅后线路还是旧的/全乱了」（用户 2026-10-14：
  /// 花蚁 py 聚合、OmniBox tvbox、猫源 catvod 三种互切都不顺）。
  String _loadedSpiderApi = '';

  /// 重入 guard - 避免 lifecycle 抖动导致 handleSceneActive 嵌套跑
  /// 第二次及以后的调用直接跳过, 不浪费 CPU 也不互相覆盖 loadingPhase
  bool _isHandleSceneActiveRunning = false;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  @override
  void onInit() {
    super.onInit();
    _setupNetworkRestoredAutoRetry();
  }

  @override
  void onClose() {
    _connectivitySubscription?.cancel();
    NodeJSManager.instance.stopNodeJS();
    super.onClose();
  }

  /// 加载阶段显示文本（合并错误信息）- 对应 Swift LoadingPhase.displayText
  /// Swift 中 failed 携带关联值，Dart 通过 configLoadError 补全
  String get phaseDisplayText {
    if (loadingPhase.value == LoadingPhase.failed &&
        configLoadError.value != null) {
      return '加载失败: ${configLoadError.value}';
    }
    return loadingPhase.value.description;
  }

  /// 是否正在加载
  bool get isLoading => loadingPhase.value.isLoading;

  /// 是否加载失败
  bool get isFailed => loadingPhase.value.isFailed;

  // ============================================================
  // 配置加载主流程 - 对应 Swift loadConfig
  // ============================================================

  /// 加载配置 - 对应 Swift loadConfig(url:）
  Future<void> loadConfig({required String vodUrl}) async {
    final trimmedVod = vodUrl.trim();
    if (trimmedVod.isEmpty) return;

    _lastVodUrl = trimmedVod;
    configLoadError.value = null;
    loadingPhase.value = LoadingPhase.loadingConfig;

    try {
      await ApiConfig.instance.loadConfigs(vodApiUrl: trimmedVod);
      await _ensureNodeJSAndLoadSource();
      // Python 引擎（T3 Python spider / 书源）：惰性启动 + 用户源同步，
      // 不阻塞主流程（增量能力，Node 失败不影响 Python 源）
      unawaited(_ensurePythonSource());
      // 切订阅后的**后台预热**：把本次订阅会用到的脚本提前下好/注册好，
      // 让"切完就能直接用、不用重启软件"（详见 _prewarmCurrentSubscription 注释）。
      unawaited(_prewarmCurrentSubscription());
      loadingPhase.value = LoadingPhase.completed;
      applyLoadedConfigState();
    } catch (e) {
      configLoadError.value = e.toString();
      loadingPhase.value = LoadingPhase.failed;
    }
  }

  /// 兼容入口：setup 页调用。直播 lives 已在 ApiConfig.loadConfigs 内交给 LiveService。
  Future<void> loadConfigWithLive({required String vodUrl}) async {
    await loadConfig(vodUrl: vodUrl);
  }

  /// 应用已加载的配置状态 - 对应 Swift applyLoadedConfigState
  void applyLoadedConfigState() {
    isConfigLoaded.value = true;
    configLoadError.value = null;
    currentSourceKey.value =
        ApiConfig.instance.homeSourceBean.value?.key ?? '';
    // 配置加载完成 → 重建视频广告过滤规则（ads / rules）
    unawaited(_reloadAdFilterRules());
    // 不再弹免责声明（用户要求去掉首次打开的责任弹窗）
  }

  /// 把配置里的 ads / rules 交给 AdFilterService。
  ///
  /// 🔴 2026-10-14 修（用户：「接口配置下载源文件好慢」）：
  ///   旧实现是**把整份配置再下一次**（`NetworkManager.getString(configUrl)`）
  ///   再自己 jsonDecode 一遍 —— 而且它没走 `ApiConfig._fetchConfigText` 的
  ///   20s 原始文本缓存，等于**每次都实打实重新拉一遍整个配置**。
  ///   大配置（几 MB）下：白耗一倍流量，还和首页首屏请求抢带宽。
  ///   ApiConfig 现在把解析好的 ads / rules 直接暴露出来，这里读现成的即可，
  ///   **不再有任何额外网络请求**。
  Future<void> _reloadAdFilterRules() async {
    try {
      AdFilterService.instance.load(
        ads: ApiConfig.instance.lastAds,
        rules: ApiConfig.instance.lastRules,
      );
    } catch (e) {
      AppLog.instance.log('[AdFilter] 规则加载失败: $e');
      try {
        AdFilterService.instance.load();
      } catch (_) {
        // ignore
      }
    }
  }

  // ============================================================
  // Spider 源加载 - 对应 Swift ensureNodeJSAndLoadSource
  // ============================================================

  /// 确保 Python 引擎已启动并把用户导入的 .py 源同步进引擎
  /// （视频/书源 Python 源都在此注册，重启后依然可用）。
  ///
  /// ── 🔴 2026-10-14 改：**按脚本判，不按订阅**（用户的原话）──────────
  /// 「其实不同订阅里面都有 py 脚本或者猫源脚本，应该**根据脚本来启动引擎**，
  ///   不是根据订阅」—— 完全正确，Node 侧本来就是这么判的
  /// （见 `_ensureNodeJSAndLoadSourceInner` 的 `hasSpiderSource`：扫 sites[] 里
  ///  有没有 js/jar 脚本源）；**只有 Python 这侧以前是无条件启动**：
  /// 每次加载配置都 `ensureStarted`，哪怕这个订阅里一个 .py 都没有
  /// （纯猫源 / 纯 CMS 订阅）⇒ 白白吃掉 CPython 的启动时间与内存，
  /// 也让"惰性启动"名不副实。
  ///
  /// 现在改成同一个口径：**扫 sites[] 里有没有 .py 源**，有才启动。
  ///   · 纯 js 订阅 → 不碰 Python；
  ///   · 纯 py 订阅 → 不碰 Node（那条判断在 Node 侧）；
  ///   · 混合订阅 → 两个都起（各自独立，互不影响）；
  ///   · **书源**用的 py 模块（Legado + pythonKey）走
  ///     `PythonSourcesService.ensureInstalled` 按需启动，不受这里影响。
  Future<void> _ensurePythonSource() async {
    if (!PythonManager.instance.isIOS) return;
    // 按**脚本**判：本次配置里有没有 .py 源
    final hasPySource =
        ApiConfig.instance.sourceBeanList.any((s) => s.isPythonScriptSource);
    if (!hasPySource) {
      AppLog.instance.log('[AppState] 本次配置没有 .py 源，跳过 Python 引擎启动（按脚本判）');
      return;
    }
    try {
      final ok = await PythonManager.instance.ensureStarted();
      if (ok) {
        await PythonSourcesService.instance.syncToEngine();
      }
    } catch (e) {
      AppLog.instance.w('[AppState] Python 引擎启动异常（可忽略）: $e');
    }
  }

  /// 确保 Node.js 已启动并加载 Spider 源 - 对应 Swift ensureNodeJSAndLoadSource
  /// 公开方法，供 SettingsController 调用
  Future<void> ensureNodeJSAndLoadSource() async {
    await _ensureNodeJSAndLoadSource();
  }

  // ============================================================
  // 订阅切换后的「后台预热」——让切完就能直接用
  // ============================================================

  /// 同时只跑一条预热流程（切订阅很频繁，避免叠加）。
  static Future<void>? _prewarmInFlight;

  /// 预热上限：一次最多下这么多个 .py 源。
  /// 不设上限时，一个 50 条 py 线路的订阅会在后台同时开 50 个下载，
  /// **抢首屏带宽**（本意是让首屏更快，结果反而更慢）。
  static const int _kPrewarmMaxPySources = 12;

  /// 切订阅后的**后台预热**：把本次订阅要用到的脚本提前下载 / 注册好。
  ///
  /// ── 为什么是"预热"，而不是"切换引擎"（用户 2026-10-14 的问题）──────
  /// iOS 上这两个引擎都是**进程级单例、启动后不可回收**：
  ///   · Node = NodeMobile 的 V8 单例 —— 第二次 `node_start` 会卡在 V8 init
  ///     （见 nodejs_manager.dart 里删掉的那段说明）；
  ///   · Python = 嵌入的 CPython，`Py_Finalize` 在有线程/模块驻留时并不安全。
  /// ⇒ 所以 **不存在"关掉 A 再开 B"这条路**。正确的模型是：
  ///   ① 引擎**惰性启动、启动后常驻**（两个可以同时活着，互不干扰）；
  ///   ② 切订阅只换**数据源**（Node 换 index.js 槽位 / Python 按 key 注册模块），
  ///      不重启引擎；
  ///   ③ 真正决定"切完能不能直接用"的是**脚本有没有提前下好** —— 就是这个方法。
  ///
  /// Node 侧：单槽位，主源脚本在 [_loadSpiderSource] 里已经（同步）载入；
  ///          这里只额外预热「主页源」那条 js 脚本（若它不是主源）。
  /// Python 侧：多源（按 key 注册模块），可以安全地后台逐个预热。
  Future<void> _prewarmCurrentSubscription() {
    final inFlight = _prewarmInFlight;
    if (inFlight != null) return inFlight;
    final fut = _prewarmCurrentSubscriptionInner();
    _prewarmInFlight = fut;
    fut.whenComplete(() => _prewarmInFlight = null);
    return fut;
  }

  Future<void> _prewarmCurrentSubscriptionInner() async {
    // ── ① Node：预热主页源的 js 脚本（与前台点击共享同一次载入，见 prewarmScript）
    try {
      final home = ApiConfig.instance.homeSourceBean.value;
      if (home != null &&
          home.isSpiderSource &&
          !home.isPythonScriptSource &&
          home.scriptUrl.trim().isNotEmpty) {
        await SpiderService.instance.prewarmScript(home.scriptUrl);
      }
    } catch (e) {
      AppLog.instance.log('[AppState] Node 脚本预热异常: $e');
    }

    // ── ② Python：把本次订阅里的 .py 源逐个下载 + 注册（主页源排最前）
    try {
      if (!PythonManager.instance.isIOS) return;
      final homeKey = ApiConfig.instance.homeSourceBean.value?.key ?? '';
      final urls = <String>[];
      final seen = <String>{};
      void add(SourceBean? s) {
        if (s == null || !s.isPythonScriptSource) return;
        final u = s.scriptUrl.trim();
        if (u.isEmpty || !seen.add(u)) return;
        urls.add(u);
      }

      // 主页源优先（用户最可能立刻点的就是它）
      add(ApiConfig.instance.homeSourceBean.value);
      for (final s in ApiConfig.instance.sourceBeanList) {
        if (s.key == homeKey) continue;
        add(s);
      }
      if (urls.isEmpty) return;

      final take = urls.length > _kPrewarmMaxPySources
          ? urls.sublist(0, _kPrewarmMaxPySources)
          : urls;
      AppLog.instance.log('[AppState] 后台预热 ${take.length}/${urls.length} 个 Python 源…');
      var ok = 0;
      for (final u in take) {
        final key = await PythonScriptSources.instance.ensureInstalled(u);
        if (key != null) ok++;
      }
      AppLog.instance.log('[AppState] Python 源预热完成 $ok/${take.length}');
    } catch (e) {
      AppLog.instance.log('[AppState] Python 源预热异常: $e');
    }
  }

  // ============================================================
  // 手动加载引擎（设置 → 引擎管理）
  // ============================================================

  /// 手动加载 Node 引擎。返回一句可直接展示的结果文案。
  ///
  /// 与启动流程的区别：
  ///   · **始终**尝试拉起 Node 进程（不再要求配置里必须有 js/jar 源）——
  ///     用户按这个按钮就是想强制把引擎拉起来，不该被前置条件挡住；
  ///   · 有主 js/jar spider 源且本次会话尚未载入时，顺带把它载入并刷新线路清单；
  ///   · **不改动 loadingPhase**，避免在设置页里搅乱主界面的加载态。
  Future<String> manualLoadNodeEngine() async {
    try {
      if (!_nodeJSStarted || !NodeJSManager.instance.isRunning) {
        final started = await NodeJSManager.instance.startNodeJS();
        if (!started) return 'Node 引擎启动失败（详见 App 日志）';
        _nodeJSStarted = true;
      }
      final portOk = await NodeJSManager.instance.waitForSpiderPort();
      if (!portOk) return 'Node 已启动，但 spider 端口未就绪';

      // 有主 js/jar spider 源且本次尚未载入 → 载入并刷新线路清单
      final main = ApiConfig.instance.sourceBeanList.firstWhereOrNull((s) =>
          s.isSpiderSource &&
          !s.key.startsWith('app_') &&
          !s.isPythonScriptSource);
      if (main != null && main.api.isNotEmpty && !_sourceLoadedThisSession) {
        final (loadOk, msg) =
            await NodeJSManager.instance.loadSource(main.api);
        if (!loadOk) return 'Node 已就绪，但源加载失败：${msg ?? "未知错误"}';
        SpiderService.instance.mainScriptUrl = main.api;
        _sourceLoadedThisSession = true;
        // 记下"请求发起时"的配置地址：/config 回来时若已不是它，说明期间切了源
        // → 这份线路表作废（见 updateSourceBeansFromSpiderConfig 的竞态校验）
        final cfgUrlAtRequest = ApiConfig.instance.configUrl.value;
        final cfg = await SpiderService.instance.getCatConfig();
        if (cfg != null) {
          await ApiConfig.instance
              .updateSourceBeansFromSpiderConfig(cfg, cfgUrlAtRequest);
        }
      }
      return 'Node 引擎已就绪（端口 ${NodeJSManager.instance.spiderPort}）';
    } catch (e) {
      return 'Node 引擎加载异常：$e';
    }
  }

  /// 手动加载 Python 引擎。返回一句可直接展示的结果文案。
  ///
  /// 启动 CPython 解释器并把已导入的 .py 源同步进引擎；非 iOS 直接提示不支持。
  /// 🔴 2026-10-14：如果引擎处于「卡死」态（上次执行没被中断、原生队列堵住），
  ///    先尝试 [PythonManager.recover] 救回来 —— 这样用户不必重启 App，
  ///    点一下「加载」就能恢复（根因已在 Python 侧兜住，见 spider_runner）。
  Future<String> manualLoadPythonEngine() async {
    if (!PythonManager.instance.isIOS) return 'Python 引擎仅支持 iOS';
    try {
      if (PythonManager.instance.isStuck) {
        final recovered = await PythonManager.instance.recover();
        if (!recovered) {
          return 'Python 引擎仍被上次执行占住（原生队列堵塞）。'
              '已开始自动恢复，请稍等几秒再点一次「加载」。';
        }
        return 'Python 引擎已从「卡死」中恢复';
      }
      final ok = await PythonManager.instance.ensureStarted();
      if (!ok) {
        return PythonManager.instance.lastError.value ?? 'Python 引擎启动失败';
      }
      await PythonSourcesService.instance.syncToEngine();
      return 'Python 引擎已就绪';
    } catch (e) {
      return 'Python 引擎加载异常：$e';
    }
  }

  /// Node 加载流程的并发锁（洞 F，2026-10-14）。
  ///
  /// 问题：快速连切两个源时，两次 `_ensureNodeJSAndLoadSource` 会**并发**跑
  /// `loadSource`，同时往**同一个 `index.js`** 写 → 文件被交替写坏 → 源加载失败。
  ///
  /// 做法：同一时刻只允许一条流程在跑；后来的**复用前一条的 Future**
  /// （而不是直接丢弃）—— 这样调用方仍然会等到加载真正结束。
  /// `finally` 里清位是必须的：否则任何一次异常都会让锁永久 latch，
  /// 变成"Node 引擎再也加载不了"，比并发写坏文件严重得多。
  static Future<void>? _nodeLoadInFlight;

  /// 确保 Node.js 已启动并加载 Spider 源 - 对应 Swift ensureNodeJSAndLoadSource
  Future<void> _ensureNodeJSAndLoadSource() async {
    final inFlight = _nodeLoadInFlight;
    if (inFlight != null) {
      AppLog.instance.log('[AppState] Node 加载流程已在跑，复用同一条流程（不并发）');
      return inFlight;
    }
    final fut = _ensureNodeJSAndLoadSourceInner();
    _nodeLoadInFlight = fut;
    try {
      await fut;
    } finally {
      _nodeLoadInFlight = null;
    }
  }

  /// 真正的加载流程 —— 并发锁由外层 [_ensureNodeJSAndLoadSource] 负责。
  Future<void> _ensureNodeJSAndLoadSourceInner() async {
    // 🔴 2026-10-13 修（用户：「导入猫源还有 tvbox 源后导入 py 源，重启后订阅里
    // 面全空了，并且这些猫源还有 tvbox 源全部没有内容」）：
    //
    // 上一版这里只判断 `isSingleScriptSpider`（= 点播接口地址本身就是 .js/jar）
    // 才启动 Node —— 那把 **CatVod 那类聚合配置**漏了：它们的 sites[] 里是
    // `csp_xxx` 线路，实现**必须**由 Node 的 jar/js spider 提供，Node 一不启动
    // 就全部线路没内容（看起来像"订阅空了"）。聚合 TVBox 配置同理。
    //
    // 现在改回「只要有 **js** 脚本源就启动 Node」，但**排除 .py**
    //（.py 走 CPython，见 isPythonScriptSource；把 .py 当 index.js 交给 Node
    //  会载入失败 → /config 空 → 首页报错，那是上一版修掉的问题）。
    //
    // ✅ 口径与 `_ensurePythonSource` 一致：**扫 sites[] 按脚本判，不按订阅** ——
    //    同一个订阅里既有 py 也有猫源脚本时，两个引擎都会按需起来（互不影响）。
    // 另外「整表替换线路」只对单 spider 配置生效（见 api_config.dart 里
    // `if (isSingleScriptSpider.value)`），所以这里放开**不会**冲掉聚合配置的线路。
    final hasSpiderSource = ApiConfig.instance.sourceBeanList
        .any((s) => s.isSpiderSource && !s.isPythonScriptSource);
    if (!hasSpiderSource) {
      AppLog.instance.log('[AppState] 无 js/jar spider 源，跳过 Node 启动/加载流程');
      return;
    }

    if (!_nodeJSStarted) {
      // iOS: Node.js 运行时内嵌（NodeMobile.xcframework）, 无需下载
      AppLog.instance.log('phase=startingNodeJS');
      loadingPhase.value = LoadingPhase.startingNodeJS;
      try {
        AppLog.instance.log('调 startNodeJS');
        final success = await NodeJSManager.instance.startNodeJS();
        AppLog.instance.log('startNodeJS 返回: $success');
        if (success) {
          _nodeJSStarted = true;
          AppLog.instance.log('调 _loadSpiderSource');
          await _loadSpiderSource();
        } else {
          loadingPhase.value = LoadingPhase.failed;
          configLoadError.value = 'Node.js 启动失败';
          AppLog.instance.log('[AppState] Node.js 启动失败');
          AppLog.instance.log('Node.js 启动失败');
        }
      } catch (e, st) {
        AppLog.instance.log('startNodeJS 异常: $e\n$st');
        loadingPhase.value = LoadingPhase.failed;
        configLoadError.value = 'Node.js 启动异常: $e';
        AppLog.instance.log('[AppState] Node.js 启动异常: $e');
      }
    } else {
      await _loadSpiderSource();
    }
  }

  /// 加载 Spider 源 - 对应 Swift loadSpiderSource
  Future<void> _loadSpiderSource() async {
    // 「程序」模块的 spider 源（key 前缀 app_）不走全局加载链路：
    // 它们由程序详情页惰性加载（Node 引擎单源架构，全局加载会触发
    // /config 线路替换并覆盖主源），这里只加载主订阅源里的蜘蛛源。
    final spiderSource = ApiConfig.instance.sourceBeanList.firstWhereOrNull(
        (s) => s.isSpiderSource && !s.key.startsWith('app_') && !s.isPythonScriptSource);
    if (spiderSource == null || spiderSource.api.isEmpty) return;

    // **会话级复用**: 本次启动已成功加载过**同一个**源（api 一致）才复用；
    // 切订阅后 api 变了必须重新 loadSource，否则 Node 驻留旧脚本、
    // /config 拿回旧线路表并整表替换 → 新订阅线路被旧订阅冲掉。
    if (_sourceLoadedThisSession &&
        _loadedSpiderApi == spiderSource.api &&
        // 🔴 2026-10-14 修（洞 E）：还要确认 **Node 槽位里驻留的仍是这个主源脚本**。
        // Node 是单源架构，中途可能被"程序脚本源"（_ensureNodeScript）顶替过；
        // 那时直接去取 /config 会拿到**那个脚本的站点表**，整表替换后线路全错。
        // 脚本已不在槽位里 → 老老实实重新 loadSource。
        SpiderService.instance.isScriptLoaded(spiderSource.api)) {
      AppLog.instance.log('[AppState] 源已在本次会话加载, 跳过下载阶段');
      loadingPhase.value = LoadingPhase.waitingSpiderPort;
      final portReady = await NodeJSManager.instance.waitForSpiderPort();
      if (!portReady) {
        loadingPhase.value = LoadingPhase.failed;
        configLoadError.value = '等待 Spider 服务超时';
        return;
      }
      await _fetchSpiderConfig();
      return;
    }

    loadingPhase.value = LoadingPhase.downloadingSource;
    final (loadSuccess, loadMessage) =
        await NodeJSManager.instance.loadSource(spiderSource.api);

    if (!loadSuccess) {
      loadingPhase.value = LoadingPhase.failed;
      configLoadError.value = 'Spider 源加载失败';
      AppLog.instance.log('[AppState] Spider 源加载失败: ${loadMessage ?? "未知错误"}');
      return;
    }
    // 登记「主源脚本」：程序脚本源按需载入时会把 Node 的单源槽位顶替掉，
    // 回到主源时 SpiderService 需要靠它把主源脚本重新载入。
    SpiderService.instance.mainScriptUrl = spiderSource.api;
    // 🔴 还要告诉 SpiderService「槽位里现在驻留的就是它」——否则它记的还是上一轮
    //    那个脚本，`isScriptLoaded` / `_dispatchScript` 都会误判成"需要重新载入"，
    //    表现为每次切订阅后的第一次点击白等一次 loadSource（用户 2026-10-14）。
    SpiderService.instance.markScriptLoaded(spiderSource.api);
    AppLog.instance.log('[AppState] Spider 源加载成功');
    _sourceLoadedThisSession = true;
    _loadedSpiderApi = spiderSource.api;

    loadingPhase.value = LoadingPhase.waitingSpiderPort;
    final portReady = await NodeJSManager.instance.waitForSpiderPort();
    if (!portReady) {
      loadingPhase.value = LoadingPhase.failed;
      configLoadError.value = '等待 Spider 服务超时';
      AppLog.instance.log('[AppState] 等待 spiderPort 超时');
      return;
    }

    await _fetchSpiderConfig();
  }

  /// 获取 Spider 配置 - 对应 Swift fetchSpiderConfig
  Future<void> _fetchSpiderConfig() async {
    final spiderPort = NodeJSManager.instance.spiderPort;
    if (spiderPort <= 0) {
      loadingPhase.value = LoadingPhase.failed;
      configLoadError.value = 'Spider 端口为 0';
      AppLog.instance.log('[AppState] spiderPort 为 0，无法获取线路配置');
      return;
    }

    loadingPhase.value = LoadingPhase.fetchingSpiderConfig;

    // 对应 Swift: getCatConfig 不需要 setCurrentSpider
    // /config 是全局端点，不需要 key/type
    try {
      // 请求发起时的源快照（供 updateSourceBeansFromSpiderConfig 做切源竞态校验）
      final cfgUrlAtRequest = ApiConfig.instance.configUrl.value;
      final config = await SpiderService.instance.getCatConfig();
      if (config == null) {
        loadingPhase.value = LoadingPhase.failed;
        configLoadError.value = '获取线路配置失败';
        return;
      }
      await ApiConfig.instance
          .updateSourceBeansFromSpiderConfig(config, cfgUrlAtRequest);

      // 对应 Swift: 用第一个源设置 currentSpider 并初始化
      final firstSource = ApiConfig.instance.sourceBeanList.firstOrNull;
      if (firstSource != null) {
        loadingPhase.value = LoadingPhase.initializingSpider;
        // 传**原始 api**（SpiderService 内部再决定走 Node 还是 Python 引擎）
        SpiderService.instance.setCurrentSpider(
          firstSource.key,
          firstSource.type,
          firstSource.api,
          ext: firstSource.ext,
          jar: firstSource.jar,
        );
        // 对应 Swift try? await - 忽略初始化错误
        try {
          await SpiderService.instance.initSpider(
              firstSource.key, firstSource.type, firstSource.api,
              ext: firstSource.ext ?? '');
        } catch (e) {
        AppLog.instance.log('[app_state] swallowed: $e');
      }
      }
    } catch (e) {
      loadingPhase.value = LoadingPhase.failed;
      configLoadError.value = '获取线路配置失败';
      AppLog.instance.log('[AppState] 获取 Spider 配置失败: $e');
    }
  }

  // ============================================================
  // 网络恢复自动重试 - 对应 Swift setupNetworkRestoredAutoRetry
  // ============================================================

  void _setupNetworkRestoredAutoRetry() {
    _connectivitySubscription = Connectivity()
        .onConnectivityChanged
        .listen((List<ConnectivityResult> results) {
      final isConnected = results.any((r) => r != ConnectivityResult.none);
      if (isConnected &&
          !isConfigLoaded.value &&
          _lastVodUrl.isNotEmpty) {
        isRetryingConfig.value = true;
        loadConfig(vodUrl: _lastVodUrl).then((_) {
          isRetryingConfig.value = false;
        });
      }
    });
  }

  // ============================================================
  // 应用恢复前台处理 - 对应 Swift handleSceneActive
  // ============================================================

  /// 应用恢复前台时检查服务状态 - 对应 Swift handleSceneActive
  ///
  /// **回退到 0199b73 行为**（用户测试 0199b73 能正常恢复锁屏切回）:
  /// 1. 立即重建 dio（恢复 iOS 后台断开的 socket）
  /// 2. 真实 HTTP 探测 verifySourceLoaded（2s 超时，验证 sourceLoaded=true）
  ///    **2026-07-08 修复**: 旧版用 spiderPort (9988) 调 /source/status 永远 404,
  ///    改用 managementPort (e.g. 52274). /source/status 是 mgmtServer 端点,
  ///    不是 spiderServer 端点.
  /// 3. 失败时主动 reloadSourceViaManagementPort 让 Node.js 重新 loadScript
  /// 4. 等新 spiderPort（reload 后源会重新 listen 端口）
  /// 5. 失败兜底走 _recoverSpiderService（4 次重试）
  ///
  /// **不**用 verifyManagementPort (0b59c5f 引入) - 用户反映
  /// verifyManagementPort=false 走 forceReset + 完整重启路径反而
  /// 导致不能恢复, 而 0199b73 走 reload 源 + 兜底 4 次重试能恢复.
  /// iOS 后台冻住 Node.js 进程时, Node.js 实际还能响应 (iOS 唤醒
  /// 时 process 解冻), _recoverSpiderService 4 次重试 (8s 窗口)
  /// 内能 reload 成功.
  ///
  /// **不**用 forceResetRunningState (0b59c5f 引入) - 即使 1c5ecf7
  /// 修了 forceReset 不调 _stopHttpServer, forceReset 整体路径在
  /// 用户环境上仍破坏恢复. 79177e1 行为是兜底, 不破坏 notify 链路.
  Future<void> handleSceneActive() async {
    if (!isConfigLoaded.value) return;
    final hasSpiderSource =
        ApiConfig.instance.sourceBeanList.any((s) => s.isSpiderSource);
    if (!hasSpiderSource) return;

    // **重入 guard**: 避免 lifecycle 抖动 (resumed→inactive→hidden→paused
    // 间隔 12ms/3ms/0ms) 导致 handleSceneActive 嵌套跑.
    // cid_1 卡在 reload 125.8 秒时, 第二次 handleSceneActive 进来 (cid_2)
    // 浪费 CPU 跑完整 4 次重试, 并可能覆盖 loadingPhase.
    if (_isHandleSceneActiveRunning) {
      AppLog.instance.entry(LogEntry(
        category: 'GUARD',
        action: 'handleSceneActive_skip',
        level: LogLevel.warn,
        message: 'handleSceneActive already running, skip duplicate call',
        fields: {'reason': 'already running'},
      ));
      return;
    }
    _isHandleSceneActiveRunning = true;

    try {
      await _handleSceneActiveImpl();
    } finally {
      _isHandleSceneActiveRunning = false;
    }
  }

  /// handleSceneActive 实际逻辑 — 委托 SceneRecovery
  Future<void> _handleSceneActiveImpl() async {
    final rec = SceneRecovery(
      markNodeStarted: () => _nodeJSStarted = true,
      setReconnecting: () => loadingPhase.value = LoadingPhase.reconnecting,
      setCompleted: () => loadingPhase.value = LoadingPhase.completed,
      setFailed: (msg) {
        loadingPhase.value = LoadingPhase.failed;
        configLoadError.value = msg;
      },
    );
    await rec.recover();
  }

  // ============================================================
  // 全屏控制（桌面端）- 对应 Swift enterPlayerFullScreen / exitPlayerFullScreen
  // ============================================================

  bool _isPlayerFullScreen = false;

  bool get isPlayerFullScreen => _isPlayerFullScreen;

  /// 进入播放器全屏 - 对应 Swift enterPlayerFullScreen
  void enterPlayerFullScreen() {
    _isPlayerFullScreen = true;
  }

  /// 退出播放器全屏 - 对应 Swift exitPlayerFullScreen
  void exitPlayerFullScreen() {
    _isPlayerFullScreen = false;
  }

  // ============================================================
  // 辅助方法
  // ============================================================

  /// 重置状态
  void reset() {
    loadingPhase.value = LoadingPhase.idle;
    configLoadError.value = null;
  }
}
