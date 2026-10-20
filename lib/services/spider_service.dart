import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'app_log.dart';
import 'dio_factory.dart';
import 'drpy_service.dart';
import 'nodejs_manager.dart';
import 'local_python_sources.dart';
import 'python_manager.dart';
import 'python_script_sources.dart';

/// Spider 服务 - 对应 Swift SpiderService
/// 与本地 Node.js Spider 服务通信
///
/// 关键设计：所有方法都接受 key/type/apiBase 参数，不依赖全局状态
/// 这是因为搜索等操作是并发执行的，全局状态会导致竞态条件
class SpiderService {
  static final SpiderService _instance = SpiderService._internal();
  static SpiderService get instance => _instance;

  // 必须可重建：iOS 进入后台/锁屏时，系统的 socket 会被断开，
  // 不重建会导致切回前台后所有请求都失败（点击线路/视频无响应）
  late Dio _dio;

  SpiderService._internal() {
    _dio = _buildDio();
  }

  static Dio _buildDio() {
    return buildDioWithDns(
      connectTimeout: const Duration(seconds: 60),
      receiveTimeout: const Duration(seconds: 60),
    )..interceptors.add(_AppLogInterceptor());
  }

  // ============================================================
  // Spider 端口（从 NodeJSManager 获取）
  // ============================================================

  int get _spiderPort => NodeJSManager.instance.spiderPort;

  bool get isSpiderReady => _spiderPort > 0;

  // ============================================================
  // 路径构建 - 对应 Swift buildSpiderPath
  // ============================================================

  /// 构建 Spider 请求路径
  /// · apiBase 非空（api 自带路径，如 OmniBox 的 `/spider/<key>/<type>`）→ `{apiBase}/{action}`
  /// · apiBase 为空 → `/spider/{key去掉 nodejs_ 前缀}/{type}/{action}`
  String _buildSpiderPath(String key, int type, String apiBase, String action) {
    if (apiBase.isNotEmpty) {
      // api 自带路径基址（如 OmniBox 的 `/spider/<key>/<type>`）→ 直接拼 action
      return '$apiBase/$action';
    }
    // ⚠️ 2026-10-14 修（猫源整包 spider 的线路全 404）：这里原来返回
    //   `/$key/$type/$action`，两处都不对 ——
    //   · 引擎的站点路由在 **`/spider`** 下，根路径下没有它；
    //   · key 带 `nodejs_` 前缀时也不认（那是客户端的显示前缀）。
    //   实测（用户 2026-10-14 日志）：
    //     404 → `POST /nodejs_omnibox_Makka聚合/3/init`
    //     200 → `POST /spider/omnibox_Makka聚合/3/init`
    final k = key.toLowerCase().startsWith('nodejs_')
        ? key.substring('nodejs_'.length)
        : key;
    return '/spider/$k/$type/$action';
  }

  /// 构建完整的 Spider URL
  String _buildSpiderUrl(String key, int type, String apiBase, String action) {
    return 'http://127.0.0.1:$_spiderPort${_buildSpiderPath(key, type, apiBase, action)}';
  }

  // ============================================================
  // 核心 POST 请求 - 对应 Swift postJSON
  // ============================================================

  /// 发送 POST 请求到 Spider 服务 - 对应 Swift postJSON
  /// 使用 ResponseType.plain 手动解析 JSON，接受 200-299 状态码
  /// 关键：iOS 后台/锁屏切回前台时，dio 的 socket 可能处于半死状态（OS
  /// 已标记断开但 dio 还没收到 RST），第一次请求会失败；加 1 次重试可恢复
  static const int _maxPostRetries = 1;
  static const Duration _postRetryDelay = Duration(milliseconds: 300);

  Future<Map<String, dynamic>?> _postJSON(
    String url,
    Map<String, dynamic> body,
  ) async {
    for (var attempt = 0; attempt <= _maxPostRetries; attempt++) {
      try {
        final response = await _dio.post<String>(
          url,
          data: jsonEncode(body),
          options: Options(
            contentType: Headers.jsonContentType,
            responseType: ResponseType.plain,
          ),
        );

        final statusCode = response.statusCode ?? 0;
        final responseBody = response.data ?? '';

        // 对应 Swift: guard (200...299).contains(httpResponse.statusCode)
        if (statusCode >= 200 && statusCode <= 299) {
          try {
            final decoded = jsonDecode(responseBody);
            if (decoded is Map<String, dynamic>) {
              return decoded;
            } else if (decoded is List) {
              // 某些 Spider 响应可能返回数组，包装为对象
              return {'list': decoded};
            }
            AppLog.instance.log(
              '[SpiderService] 响应不是JSON对象: $url, body类型=${decoded.runtimeType}',
            );
            return null;
          } catch (e) {
            AppLog.instance.log(
              '[SpiderService] JSON解析失败: $url, 错误=$e, body=${responseBody.length > 500 ? responseBody.substring(0, 500) : responseBody}',
            );
            return null;
          }
        } else {
          lastHttpStatus = statusCode;
          AppLog.instance.log(
            '[SpiderService] HTTP错误 $statusCode: $url, body=${responseBody.length > 500 ? responseBody.substring(0, 500) : responseBody}',
          );
          return null;
        }
      } on DioException catch (e) {
        // iOS 后台/锁屏切回前台时，dio 的 socket 可能半死（OS 标记断开但
        // 没收到 RST），重试一次通常能恢复
        final isRetriable =
            e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.sendTimeout ||
            e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.unknown;
        if (attempt < _maxPostRetries && isRetriable) {
          AppLog.instance.log(
            '[SpiderService] POST $url 第 ${attempt + 1} 次失败，${_postRetryDelay.inMilliseconds}ms 后重试: ${e.type}/${e.message}',
          );
          await Future.delayed(_postRetryDelay);
          // 重试前重建 dio（确保新 socket）
          try {
            _dio.close(force: true);
          } catch (e) {
            /* ignore */
          }
          _dio = _buildDio();
          continue;
        }
        final code = e.response?.statusCode ?? 0;
        lastHttpStatus = code;
        final respBody = e.response?.data?.toString() ?? '';
        AppLog.instance.log(
          '[SpiderService] POST $url 失败: code=$code, type=${e.type}, message=${e.message}, body=${respBody.length > 500 ? respBody.substring(0, 500) : respBody}',
        );
        return null;
      } catch (e) {
        AppLog.instance.log('[SpiderService] POST $url 未知错误: $e');
        return null;
      }
    }
    return null;
  }

  // ============================================================
  // 脚本源路由（TVBox type=3 脚本源）
  // ============================================================
  // 聚合配置（如 huahua.json）里 type=3 的脚本源有几种写法：
  //   · api = 远端 .py                     → CPython 引擎（下载 + 注册后执行）
  //   · api = py_xxx.py（设置页手动导入）   → CPython 引擎（模块名映射）
  //   · api = drpy2 运行时 + ext = 站点.js  → Node/drpy2（按需把 ext 载入引擎）
  //   · api = 远端 .js / .js.md5           → Node/drpy2（按需把 api 载入引擎）
  //
  // **为什么必须"按需载入"**：两个引擎都是「单源」架构 —— Node 同一时刻只有一份
  // index.js，Python 是「一个 key 一个模块」。所以脚本源只在被访问时才把对应脚本
  // 载入引擎，而不是像「整包就是一个 js spider」的配置那样在启动时统一加载。

  /// 归一化脚本地址：剥掉配置里常见的包裹字符，并把非 ASCII 路径按 URL 规则编码。
  ///
  /// 为什么需要（用户 2026-10-14 给的配置实例）：
  ///     "api": "`https://x.muiu.site/xiaomao/Mayi/js/drpy2.min.js`"
  ///     "ext": "`https://x.muiu.site/xiaomao/Mayi/js/🐱官综.js`"
  /// 两个值都被**反引号包住**（从 JS 模板字符串里复制出来的常见走样）。
  /// 而全项目的判断都以 `startsWith('http')` 为准 ⇒ 反引号开头 ⇒ 认不出是
  /// 远端脚本 ⇒ 被当"相对路径"拦下（报"暂不支持的源协议"），整条线路白给。
  ///
  /// 第二件事：路径里带中文/emoji（`🐱官综.js`）时，直接丢给 Dio/Uri 会抛异常，
  /// 这里用 `Uri.encodeFull` 编码 —— 它保留 `:/?&=` 这些结构字符，只编码非 ASCII，
  /// 正是这种场景要的。
  static String _normalizeScriptUrl(String raw) {
    var u = raw.trim();
    const wraps = ['`', '"', "'"];
    // 1) 成对的首尾包裹，可能叠层（如 `"http://..."` ），循环剥
    var changed = true;
    while (changed && u.length >= 2) {
      changed = false;
      for (final w in wraps) {
        if (u.startsWith(w) && u.endsWith(w)) {
          u = u.substring(1, u.length - 1).trim();
          changed = true;
        }
      }
    }
    // 2) 只剩单边包裹的（配置里偶见残缺）
    while (u.isNotEmpty && wraps.contains(u[0])) {
      u = u.substring(1).trim();
    }
    while (u.isNotEmpty && wraps.contains(u[u.length - 1])) {
      u = u.substring(0, u.length - 1).trim();
    }
    // 3) 远端地址编码：中文/emoji 路径必须编码后才能请求
    if (u.startsWith('http://') || u.startsWith('https://')) {
      try {
        return Uri.encodeFull(u);
      } catch (_) {
        return u;
      }
    }
    return u;
  }

  /// 脚本源实际要载入的脚本地址：ext 优先（drpy2 模式），否则用 api
  static String _scriptUrl(String api, String ext) {
    final e = _normalizeScriptUrl(ext);
    if (e.isNotEmpty) {
      final p = e.toLowerCase().split('?').first;
      if (e.startsWith('http://') ||
          e.startsWith('https://') ||
          p.endsWith('.js') ||
          p.endsWith('.py')) {
        return e;
      }
    }
    return _normalizeScriptUrl(api);
  }

  static bool _isPythonScript(String script) =>
      script.toLowerCase().split('?').first.endsWith('.py');

  /// Node 侧路径基址：api 是 http URL 时退化为 /{key}/{type}/{action}
  static String _nodeBase(String api) {
    // ⚠️ 必须先归一化：配置里的 api 可能被反引号包住（`` `https://…` ``），
    //    不归一化就会 `startsWith('http') == false` → 被当成路径基址 →
    //    拼出 `` `https://…`/play `` 这种非法 URL。
    final a = _normalizeScriptUrl(api);
    // csp_ 占位不是路径基址：拼进 URL 会产出 `csp_xxx/play` 这种非法路径，
    // 必须退化为标准 /{key}/{type}/{action} 形态。
    if (a.toLowerCase().startsWith('csp_')) return '';
    return a.startsWith('http') ? '' : a;
  }

  /// 「主源脚本」地址（整包就是一个 js spider 的配置）：由 AppState 在加载主源时
  /// 登记。用于「打开过程序脚本源后回到主源」时把主源脚本重新载入引擎。
  String mainScriptUrl = '';

  /// 当前已载入 Node 引擎的脚本地址 + 该脚本在引擎里的真实站点 key
  String _loadedScriptUrl = '';
  String _loadedScriptKey = '';

  /// drpy 标准源：已载入的站点脚本地址（`ext`）。
  String _loadedDrpyExt = '';

  /// drpy 主源的运行时地址（`api`）——`isScriptLoaded` 用它判断"还是同一个源"。
  String _mainDrpyApi = '';

  /// drpy 主源的站点规则地址（`ext`）——被顶替后重新载入时要用。
  String _mainDrpyExt = '';

  /// 同一份 ext 的载入只跑一次（并发请求复用一个 Future）。
  final Map<String, Future<String?>> _drpyLoadInFlight = {};

  /// 是否是 drpy 标准源（`api=drpy2.min.js` + `ext=站点.js`）。
  static bool isDrpySource(String api, String ext) =>
      DrpyService.isDrpySource(api, ext);

  /// 本次载入的脚本对应的**候选 key 列表**（按可信度排序，见
  /// [_queryEngineScriptCandidates]）。
  ///
  /// 为什么需要（用户 2026-10-15：TVBox 源"切过去不直接出内容、要刷新几次、
  /// 还播不了"）：引擎是**多模块常驻**的（订阅下发的 `catvod/index.js` 一个包
  /// 里塞了 280 个模块，全是 `type:3`），`/config` 的 sites[] 会同时列出
  /// 新旧脚本的站点；原来"取第一个有 key 的站点"经常拿到**旧脚本的 key**，
  /// 再配上新 type ⇒ `/spider/<旧key>/<新type>/init` ⇒ 404。
  /// ⇒ 现在不再赌一个 key：把候选全列出来，**用响应验证**（404 = key 不对就换
  /// 下一个），全失败才报错并作废缓存。
  List<String> _loadedScriptCandidates = [];

  /// 引擎 `/config` 里各站点**自己声明**的 type（`key → type`）。
  ///
  /// ── 为什么需要（用户 2026-10-15「TVBox 源内容加载不出来 / 播放不了」）───
  /// `/spider/<key>/<type>/<action>` 里的 **type 必须与引擎实际注册的一致**
  /// —— 引擎是按各模块 `meta.type` 挂路由的（见 assets/nodejs-project/src/spider/
  /// 下每个源导出的 `meta`）。而调用方的 type 来自订阅配置的 `sites[].type`，
  /// **两者未必相等**：
  ///   · 实测整包 TVBox 源那条线路声明 `type=4`，引擎按模块 meta 注册的是 `3`
  ///     ⇒ `POST /spider/omnibox_Makka聚合/4/init` 404 `Route ... not found`；
  ///   · key 又是对的、候选只有一个 ⇒ 连"换 key"重试都没有，整条线路直接废掉。
  /// 引擎自己 `/config` 的 sites[] 就是它的注册表 ⇒ 404 时拿它校正 type。
  final Map<String, int> _engineSiteTypes = {};

  /// 最近一次 `_postJSON` 的 HTTP 状态码（0 = 连接层错误）。
  /// 用来判定"404 = 路由不存在 = key 不对"，从而触发换 key 重试。
  int? lastHttpStatus;

  /// Node 槽位里当前驻留的脚本是不是 [url]。
  ///
  /// 为什么需要（洞 E）：Node 是**单源架构**，程序脚本源载入后会顶掉主源。
  /// 上层判断"主源本会话已加载、不用再 loadSource"时必须连这个一起看 ——
  /// 否则会直接去取 `/config`，拿回来的是**那个脚本的站点表**，
  /// 整表替换后线路全错（表现为"切了源但内容不对"）。
  bool isScriptLoaded(String url) {
    final u = url.trim();
    if (u.isEmpty) return false;
    if (_loadedScriptUrl == u) return true;
    // drpy：槽位里驻留的是"运行时 + 站点规则"，主源登记的是运行时地址。
    // 还要确认它没被 CatVod 整包源顶替（_loadedScriptUrl 会变）。
    if (_mainDrpyApi.isNotEmpty &&
        u == _mainDrpyApi &&
        _loadedDrpyExt.isNotEmpty &&
        _loadedScriptUrl == 'drpy::$_loadedDrpyExt') {
      return true;
    }
    return false;
  }

  /// 由 `AppState._loadSpiderSource` 在**主源脚本已载入 Node 槽位**之后调用：
  /// 把"槽位里现在驻留的是谁"如实登记进来。
  ///
  /// 🔴 为什么必须有（用户 2026-10-14：「切订阅要能切完就直接用」）：
  ///   以前只有 `_ensureNodeScript` 会写 `_loadedScriptUrl`，而**主源是走
  ///   `AppState._loadSpiderSource → NodeJSManager.loadSource` 装的**，绕过了
  ///   这里 ⇒ 槽位里明明已经是新脚本，`_loadedScriptUrl` 还停在上一轮那个
  ///   ⇒ 两个后果：
  ///     ① `isScriptLoaded(新 api)` 恒为 false ⇒ 每次切回这个订阅都会
  ///        **重新 loadSource 一遍**（白等 0.5~2s）；
  ///     ② `_dispatchScript` 里 `_loadedScriptUrl != mainScriptUrl` 恒为真
  ///        ⇒ 切订阅后的**第一次点击**又要先"重新载入主脚本"才发请求。
  ///   登记之后这两条都变成"已就绪"，切完即可直接用。
  void markScriptLoaded(String url) {
    final u = url.trim();
    if (u.isEmpty) return;
    _loadedScriptUrl = u;
    // key 留空：真实的站点 key 交给下一次 `_ensureNodeScript`/`/config` 去补问
    //（单脚本 spider 配置的 sites 本来就是 /config 下发的真 key，这里不猜）。
    _loadedScriptKey = '';
  }

  /// 主脚本是否需要"补一次"：
  ///   · 槽位里驻留的不是它（被程序脚本源顶替过 / 切了订阅）；**
  ///     或** · 它的**真实站点 key 还没问到**（[markScriptLoaded] 故意留空的）。
  ///
  /// 走这条分支只会做两件**便宜**的事：`_ensureNodeScript` 命中"同 url"时
  /// **不会重新 loadSource**，只补问一次 `/config` 拿 key ⇒ 不再有
  /// "切完订阅第一次点击白等一次完整脚本载入"的开销。
  bool get _needMainScriptRefresh {
    if (mainScriptUrl.isEmpty) return false;
    // drpy 主源：槽位标记是 `drpy::<ext>`，不是 api 本身
    if (_mainDrpyApi.isNotEmpty && _mainDrpyApi == mainScriptUrl) {
      return _loadedScriptUrl != 'drpy::$_loadedDrpyExt' ||
          _loadedScriptKey.isEmpty;
    }
    return _loadedScriptUrl != mainScriptUrl || _loadedScriptKey.isEmpty;
  }

  /// script → Python 模块 key（去 .py 后缀 + py_ 前缀）
  String _pythonModuleKey(String script) {
    var k = script.trim();
    if (k.toLowerCase().endsWith('.py')) {
      k = k.substring(0, k.length - 3);
    }
    // 去掉路径部分（如 /spider/py_demo）
    final slash = k.lastIndexOf('/');
    if (slash >= 0) k = k.substring(slash + 1);
    if (k.toLowerCase().startsWith('py_')) {
      k = k.substring(3);
    }
    return k.isEmpty ? 'demo' : k;
  }

  /// 最近一次失败的**可读原因**。
  ///
  /// 为什么要暴露出来：这些失败以前只写日志，上层拿到的是 null → 首页/列表
  /// 只是"一片空白"，用户只能看到"啥都没有"（用户 2026-10-13：
  /// 「py 源里面没有内容，啥都没有，还显示网络加载失败」）。
  /// 上层（SourceService）现在会把它抛成错误信息显示出来。
  String? lastError;

  /// 调 Python 引擎执行源方法（module=video.<key>，args 为 kwargs）
  Future<Map<String, dynamic>?> _pythonCall(
    String moduleKey,
    String action,
    Map<String, dynamic> args,
  ) async {
    final r = await PythonManager.instance.call(
      'video.$moduleKey',
      action,
      args,
    );
    if (!r.ok) {
      lastError = 'Python 源执行失败: ${r.error}';
      AppLog.instance.w('[SpiderService] $lastError');
      return null;
    }
    final data = r.json;

    // 🔴 关键：`spider_runner.call()` 内部把异常**包成 JSON** 返回
    //    （`{ok:false, error, trace}`），通道层面 `r.ok` 仍然是 true ⇒
    //    以前这里直接当成"正常结果"返回，上层只看到空列表、完全不知道出错原因。
    //    必须在这里识别并把原因记下来。
    if (data is Map<String, dynamic>) {
      if (data['ok'] == false) {
        lastError = 'Python 源报错: ${data['error'] ?? '未知错误'}';
        AppLog.instance.w(
          '[SpiderService] $lastError'
          '${data['trace'] != null ? "\n${data['trace']}" : ""}',
        );
        return null;
      }
      return data;
    }
    if (data is List) return {'list': data};
    lastError = 'Python 源返回了非预期类型: ${data.runtimeType}';
    return null;
  }

  /// 向引擎 `/config` 问"当前驻留脚本的真实站点 key"（取候选列表里的第一个）。
  ///
  /// 抽成独立方法是为了两处复用（洞 D）：初次载入脚本后问一次；如果当时没问到
  /// （`_loadedScriptKey` 仍为空），**下次再进 `_ensureNodeScript` 时还能再问一次**，
  /// 而不是永远退回 fallback。
  Future<String> _queryEngineScriptKey({
    int? type,
    String preferKey = '',
  }) async {
    final cands = await _queryEngineScriptCandidates(
      type: type,
      preferKey: preferKey,
    );
    _loadedScriptCandidates = cands;
    return cands.isEmpty ? '' : cands.first;
  }

  /// 取"本次载入的脚本"对应的**候选 key 列表**（按可信度排序）。
  ///
  /// 用户 2026-10-15（TVBox 源切换后不出内容 / 要刷新几次 / 播不了）：
  ///   —— 引擎是多模块常驻的，`/config` 的 sites[] 同时列出**新旧脚本**的站点；
  ///      原来"取第一个有 key 的站点"经常拿到旧脚本的 key，配新 type 去请求
  ///      就是 `/spider/<旧key>/<新type>/…` ⇒ 404（日志里 `/4/init not found`）。
  ///   ⇒ 这里不再赌一个 key，而是给出**有序候选**，由调用方"用响应验证"
  ///      （404 = 路由不存在 = key 不对 ⇒ 换下一个），全失败才作废重问。
  ///
  /// 排序依据（从强到弱）：
  ///   ① `preferKey`：聚合配置里该源的 key（不少 host 直接拿源 id 当模块 key）
  ///      —— 但只在其**确实出现在 sites[] 里**时才排第一，免得白打一次 404；
  ///   ② `type` 匹配：站点声明的 type == 本次要用的 type（最像"我们要的那条线路"）；
  ///   ③ 其余站点；
  ///   ④ 兜底：`preferKey`（sites 里没有时仍试一次，保住"单脚本配置"的旧行为）。
  ///
  /// 就绪等待：新脚本刚载入时，`/config` 可能还没把它注册进来 —— 只在
  /// **"判定依据还没出现"**（既没有 preferKey、也没有 type 匹配）时小退避重试，
  /// 最多 5 次 × 400ms；一旦依据出现就立刻返回，正常源零额外等待。
  Future<List<String>> _queryEngineScriptCandidates({
    int? type,
    String preferKey = '',
  }) async {
    final ordered = <String>[];
    final seen = <String>{};
    void push(Object? raw) {
      final v = (raw ?? '').toString().trim();
      if (v.isEmpty || !seen.add(v)) return;
      ordered.add(v);
    }

    final prefer = preferKey.trim();
    List<Map<String, dynamic>> lastSites = const [];
    for (var attempt = 0; attempt < 5; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      final cfg = await getCatConfig();
      final sites = _extractSites(cfg);
      if (sites.isEmpty) continue;

      final keys = <String>[];
      var typedCount = 0;
      for (final s in sites) {
        final k = (s['key'] ?? '').toString().trim();
        if (k.isEmpty) continue;
        keys.add(k);
        final st = _siteType(s);
        // 顺手记下"这个 key 自己声明的 type"——404 时用它校正（见 [_engineSiteTypes]）
        if (st != null) _engineSiteTypes[k] = st;
        if (type != null && st == type) typedCount++;
      }
      if (keys.isEmpty) continue;
      lastSites = sites;
      // 判定依据出现了（preferKey 命中 / 有 type 匹配的站点）⇒ 不用再等
      if ((prefer.isNotEmpty && keys.contains(prefer)) || typedCount > 0) break;
    }

    // 组装：① preferKey（确实在 sites 里才排第一，免得白打一次 404）
    //      ② type 匹配 ③ 其余站点 ④ preferKey 兜底（保住"单脚本配置"的旧行为）
    final srcKeys = <String>[];
    final typedKeys = <String>[];
    for (final s in lastSites) {
      final k = (s['key'] ?? '').toString().trim();
      if (k.isEmpty) continue;
      srcKeys.add(k);
      if (type != null && _siteType(s) == type) typedKeys.add(k);
    }
    if (prefer.isNotEmpty && srcKeys.contains(prefer)) push(prefer);
    for (final k in typedKeys) push(k);
    for (final k in srcKeys) push(k);
    if (prefer.isNotEmpty) push(prefer);
    // ⚠️ 必须**封顶**：聚合包一次能列出 280 个站点，若全当候选，
    //    key 猜错时会连打 280 次请求。取前 6 个足够覆盖
    //    （preferKey / type 匹配 / 前几个站点），剩下的靠"作废后重问"兜。
    if (ordered.length > 6) {
      ordered.removeRange(6, ordered.length);
    }
    return ordered;
  }

  /// 站点声明的 type（/config 的 sites[] 里可能是 int 也可能是字符串）
  static int? _siteType(Map<String, dynamic> s) {
    final t = s['type'];
    if (t is int) return t;
    if (t is String) return int.tryParse(t.trim());
    return null;
  }

  /// 按**候选 (key, type) 组合**依次请求同一个 action；**404（路由不存在）判定为
  /// "这条路由没注册" ⇒ 换下一个组合**，命中即把该 key 记回缓存（自愈）；
  /// 全组合都 404 才失败并作废缓存。
  ///
  /// 组合怎么来：每个候选 key **先用调用方给的 type**（保证现在能用的路径行为
  /// 完全不变），404 时再补一次**引擎 `/config` 里该 key 自己声明的 type**
  /// （见 [_engineSiteTypes]）—— 路由由 key **和** type 一起决定，原来只换 key，
  /// 遇到"key 对、type 不对"就必然 404 且无从自愈。
  ///
  /// 非 404 的失败（超时 / 500 / 连接错误）**不换** —— 那是真的故障，
  /// 换只会把问题掩盖成"多打几次请求"。
  Future<Map<String, dynamic>?> _postSpiderWithKeyFallback({
    required List<String> candidates,
    required String primaryKey,
    required int type,
    required String api,
    required String action,
    required Map<String, dynamic> body,
  }) async {
    final cands = candidates.isEmpty ? <String>[primaryKey] : candidates;
    // ⚠️ 单候选 = 没在"猜 key"（猫源 / 私有协议 / 主源刷新 / 缓存命中）。
    final maySwitchKey = cands.length > 1;

    // 组装实际要试的 (key, type) 序列：
    //   ① 调用方给的 type（排第一 ⇒ 所有现在能用的路径行为不变）
    //   ② 该 key 在引擎 /config 里自己声明的 type（≠① 时）
    // 实测背景见 [_engineSiteTypes]：整包 TVBox 源那条线路声明 type=4，
    // 引擎按模块 meta 注册的是 3 ⇒ `/spider/omnibox_Makka聚合/4/init` 404；
    // key 又恰好是对的、候选只有一个 ⇒ 连原来那套"换 key"都轮不到，
    // 整条线路直接废掉（用户 2026-10-15「内容加载不出来 / 播放不了」）。
    final attempts = <({String key, int type})>[];
    final seenAttempt = <String>{};
    for (final k in cands) {
      final declared = _engineSiteTypes[k];
      for (final t in <int>[type, if (declared != null) declared]) {
        if (seenAttempt.add('$k\u0001$t')) attempts.add((key: k, type: t));
      }
    }
    // 真"换过"才作废缓存 / 换错误文案（单候选且只有一次尝试 ⇒ 维持原行为）
    final mayVary = maySwitchKey || attempts.length > cands.length;

    for (var i = 0; i < attempts.length; i++) {
      final k = attempts[i].key;
      final t = attempts[i].type;
      if (!isSpiderReady) {
        lastError ??= 'Node 引擎未就绪（spider 服务没起来）';
        return null;
      }
      lastHttpStatus = null;
      final url = _buildSpiderUrl(k, t, _nodeBase(api), action);
      AppLog.instance.log('[SpiderService] $action: $url');
      final r = await _postJSON(url, body);
      if (r != null) {
        if (mayVary && k != _loadedScriptKey) {
          _loadedScriptKey = k;
          AppLog.instance.log('[SpiderService] 换 key 命中并记住: $k（$action）');
        }
        return r;
      }
      // 非 404（超时 / 500 / 连接错误）= 真故障：不换 key/type，避免掩盖
      if (lastHttpStatus != 404) return null;
      final next = i + 1 < attempts.length ? attempts[i + 1] : null;
      if (next == null) break;
      AppLog.instance.log(
        next.key == k
            ? '[SpiderService] $action: key=$k type=$t 路由不存在(404)，'
                  '改用引擎声明的 type=${next.type} 再试一次'
            : '[SpiderService] $action: key=$k 路由不存在(404)，'
                  '换下一个候选 key=${next.key}',
      );
    }
    // 单候选且只试过一次（没换过）⇒ 维持原行为：错误文案由 _postJSON 给，
    // 不动缓存（下次进来还能复用，避免把一次偶发 404 放大成"整源作废"）
    if (!mayVary) return null;
    // 换过 key / 校正过 type 仍全 404 ⇒ 缓存不可信，作废，下次重新问
    _loadedScriptKey = '';
    _loadedScriptCandidates = [];
    lastError =
        '脚本源路由未就绪（已尝试 ${attempts.length} 次；'
        '${cands.length} 个候选 key）';
    AppLog.instance.w('[SpiderService] $action: ${lastError}');
    return null;
  }

  /// 同一脚本的载入过程**只跑一次**：并发调用（后台预热 + 用户首次点击）
  /// 复用同一个 Future。
  ///
  /// 为什么必须（用户 2026-10-14：「切订阅要能切完就直接用」）：
  ///   为了"切完就是热的"，切订阅后会在**后台预热**本次订阅的主脚本；
  ///   而用户可能在同一时刻点了那个源 ⇒ 两边同时进 `_ensureNodeScript`
  ///   ⇒ **两次 `loadSource` 往同一个 `index.js` 写** ⇒ 文件被交替写坏、
  ///   源加载失败（与 `AppState._nodeLoadInFlight` 同一类竞态）。
  final Map<String, Future<String?>> _scriptLoadInFlight = {};

  /// 主源加载入口（供 `AppState._loadSpiderSource` 调用）。
  ///
  /// drpy 标准源（`api=drpy2.min.js` + `ext=站点.js`）不能直接 loadSource(api)，
  /// 必须交给 drpy 宿主（运行时会话 + /config + /spider 路由）。
  Future<(bool, String?)> loadSourceSmart(String api, String ext) async {
    if (isDrpySource(api, ext)) {
      _mainDrpyApi = api.trim();
      _mainDrpyExt = ext;
      final k = await _ensureDrpyScript(api, ext, fallback: 'drpy');
      return k == null ? (false, lastError ?? 'drpy 源加载失败') : (true, null);
    }
    _mainDrpyApi = '';
    _mainDrpyExt = '';
    return NodeJSManager.instance.loadSource(api);
  }

  /// 确保 drpy 源已载入宿主，返回站点 key。
  Future<String?> _ensureDrpyScript(
    String api,
    String ext, {
    String fallback = 'drpy',
    int? type,
  }) {
    final extUrl = DrpyService.resolveExt(api, ext);
    if (extUrl.isEmpty) {
      lastError = 'drpy 源缺少 ext 站点规则';
      return Future.value(null);
    }
    // 同一份规则仍驻留在 Node 槽位里才复用：
    // 中途可能被 CatVod 整包源顶替（spiderPort 已指向别的服务）
    if (_loadedDrpyExt == extUrl &&
        _loadedScriptUrl == 'drpy::$extUrl' &&
        _loadedScriptKey.isNotEmpty) {
      _loadedScriptCandidates = [_loadedScriptKey];
      return Future.value(_loadedScriptKey);
    }
    final playing = _drpyLoadInFlight[extUrl];
    if (playing != null) {
      AppLog.instance.log('[SpiderService] drpy 正在载入，复用同一次流程: $extUrl');
      return playing;
    }
    final fut = _ensureDrpyScriptInner(
      api,
      extUrl,
      fallback: fallback,
      type: type,
    );
    _drpyLoadInFlight[extUrl] = fut;
    fut.whenComplete(() {
      if (identical(_drpyLoadInFlight[extUrl], fut)) {
        _drpyLoadInFlight.remove(extUrl);
      }
    });
    return fut;
  }

  Future<String?> _ensureDrpyScriptInner(
    String api,
    String extUrl, {
    String fallback = 'drpy',
    int? type,
  }) async {
    try {
      if (NodeJSManager.instance.managementPort <= 0) {
        final ok = await NodeJSManager.instance.startNodeJS();
        if (!ok) {
          lastError = 'Node 启动失败，drpy 源无法加载';
          return null;
        }
      }
      // 管理端口是 Node 异步通知回来的，最多等 10 秒
      for (
        var i = 0;
        i < 50 && NodeJSManager.instance.managementPort <= 0;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (NodeJSManager.instance.managementPort <= 0) {
        lastError = 'Node 管理端口未就绪，drpy 源无法加载';
        return null;
      }
      final r = await DrpyService.instance.load(
        api: api,
        ext: extUrl,
        key: fallback,
      );
      if (!r.ok) {
        lastError = r.error ?? 'drpy 源加载失败';
        AppLog.instance.w('[SpiderService] drpy 载入失败 $extUrl: $lastError');
        return null;
      }
      _loadedDrpyExt = extUrl;
      _loadedScriptUrl = 'drpy::$extUrl';
      _loadedScriptKey = r.key;
      _loadedScriptCandidates = [r.key];
      // 等 catServerFactory 把 spiderPort 切到**新服务**（旧端口可能还活着）
      for (
        var i = 0;
        i < 50 && r.port > 0 && NodeJSManager.instance.spiderPort != r.port;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await NodeJSManager.instance.waitForSpiderPort();
      AppLog.instance.log('[SpiderService] drpy 已载入 $extUrl（key=${r.key}）');
      return r.key;
    } catch (e) {
      lastError = 'drpy 源加载异常：$e';
      return null;
    }
  }

  /// 确保 [script] 已载入 Node 引擎，返回引擎里的**真实站点 key**（去重入口）。
  ///
  /// [type] 只用于"挑候选 key"（站点声明的 type 与本次请求的 type 一致者优先），
  /// 不影响载入行为；不传（如后台预热）时退化为旧行为。
  Future<String?> _ensureNodeScript(
    String script, {
    required String fallback,
    int? type,
  }) {
    final playing = _scriptLoadInFlight[script];
    if (playing != null) {
      AppLog.instance.log('[SpiderService] 脚本正在载入，复用同一次流程: $script');
      return playing;
    }
    final fut = _ensureNodeScriptInner(script, fallback: fallback, type: type);
    _scriptLoadInFlight[script] = fut;
    fut.whenComplete(() {
      if (identical(_scriptLoadInFlight[script], fut)) {
        _scriptLoadInFlight.remove(script);
      }
    });
    return fut;
  }

  /// 「预热」某个脚本源（切订阅后台调用）——让用户第一次点它时就是热的。
  Future<void> prewarmScript(String script) async {
    final s = script.trim();
    if (s.isEmpty) return;
    // Node 没起来就别为预热单独拉一次（真正要用时前台路径会负责启动）
    if (NodeJSManager.instance.spiderPort <= 0) return;
    try {
      await _ensureNodeScript(s, fallback: '');
    } catch (_) {
      // 预热失败无所谓：前台用到时还会再走一遍
    }
  }

  /// 确保 [script] 已载入 Node 引擎，返回引擎里的**真实站点 key**。
  ///
  /// 真实 key 以引擎 `/config` 返回的站点列表为准 —— 聚合配置里写的 key 是 TVBox
  /// 的 key，和 drpy2 模块自报的 key 未必一致；取不到时退回 [fallback]。
  Future<String?> _ensureNodeScriptInner(
    String script, {
    required String fallback,
    int? type,
  }) async {
    if (_loadedScriptUrl == script) {
      if (_loadedScriptKey.isNotEmpty) {
        // 缓存命中：候选就按"上次命中的那个 key"起步（404 时会自动作废重问）
        _loadedScriptCandidates = [_loadedScriptKey];
        return _loadedScriptKey;
      }
      // 🔴 2026-10-14 修（洞 D：key 缓存降级）：
      //   脚本上次载入过、但当时没能从 /config 问到引擎真实 key
      //   （模块 start() 还没注册完等）。以前这里**直接返回 fallback**，
      //   而 `_loadedScriptUrl` 已经置位 ⇒ 之后永远走这个分支、**再也不会重试**，
      //   那条线路就一直拿错的 key 去请求（404 / 空），永远恢复不了。
      //   现在补一次"重新问 key"，仍拿不到才退回 fallback。
      final retried = await _queryEngineScriptKey(
        type: type,
        preferKey: fallback,
      );
      if (retried.isNotEmpty) {
        _loadedScriptKey = retried;
        AppLog.instance.log('[SpiderService] 补问到引擎真实 key: $retried（$script）');
        return retried;
      }
      return fallback;
    }
    try {
      // Node 已在跑（主源/音乐模块起过）就别再调一次启动
      if (NodeJSManager.instance.spiderPort <= 0) {
        final ok = await NodeJSManager.instance.startNodeJS();
        if (!ok) {
          AppLog.instance.w('[SpiderService] Node 启动失败，脚本源无法加载: $script');
          return null;
        }
      }
      if (!await NodeJSManager.instance.waitForSpiderPort()) {
        AppLog.instance.w('[SpiderService] 等待 spiderPort 超时: $script');
        return null;
      }
      final (loaded, msg) = await NodeJSManager.instance.loadSource(script);
      if (!loaded) {
        AppLog.instance.w('[SpiderService] 脚本载入失败 $script: ${msg ?? "未知错误"}');
        return null;
      }
      _loadedScriptUrl = script;
      _loadedScriptKey = await _queryEngineScriptKey(
        type: type,
        preferKey: fallback,
      );
      AppLog.instance.log(
        '[SpiderService] 脚本已载入 $script，'
        '引擎 key=${_loadedScriptKey.isEmpty ? fallback : _loadedScriptKey}'
        '（候选 ${_loadedScriptCandidates.length} 个）',
      );
      return _loadedScriptKey.isNotEmpty ? _loadedScriptKey : fallback;
    } catch (e) {
      AppLog.instance.w('[SpiderService] 脚本载入异常 $script: $e');
      return null;
    }
  }

  /// 从 /config 响应里取站点列表（兼容 {video:{sites}} 与 {sites}）
  static List<Map<String, dynamic>> _extractSites(Map<String, dynamic>? cfg) {
    if (cfg == null) return const [];
    final video = cfg['video'];
    final dynamic sites = video is Map ? video['sites'] : cfg['sites'];
    if (sites is! List) return const [];
    return sites
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  /// 统一分发：按脚本类型把 [action] 交给 Python 或 Node 引擎执行。
  ///
  /// [nodeArgs] / [pyArgs] 是同名 action 在两个引擎里的参数形状
  /// （Node 用 id/page/filters，Python 用 ids/tid/extend）。
  Future<Map<String, dynamic>?> _dispatchScript({
    required String key,
    required int type,
    required String api,
    required String ext,
    required String action,
    required Map<String, dynamic> nodeArgs,
    required Map<String, dynamic> pyArgs,
  }) async {
    final script = _scriptUrl(api, ext);
    // 每轮清一次：否则上一次失败的旧原因会粘住（`??=` 会保留它），
    // 让用户看到与本次无关的错误。
    lastError = null;

    // ── Python 引擎（.py）────────────────────────────────────
    if (script.isNotEmpty && _isPythonScript(script)) {
      final moduleKey = script.startsWith('http')
          ? await PythonScriptSources.instance.ensureInstalled(script)
          : _pythonModuleKey(script);
      if (moduleKey == null) {
        lastError = PythonScriptSources.instance.lastError ?? 'Python 源准备失败';
        AppLog.instance.w('[SpiderService] $lastError');
        return null;
      }
      final r = await _pythonCall(moduleKey, action, pyArgs);

      // 🔴 2026-10-14 修（用户实测：`ModuleNotFoundError: No module named
      //    'src.spider.video.psrc_xxx'`）：
      //    Dart 侧记录"本会话已注册"，但解释器的 sys.modules 里并没有这个模块
      //    （典型成因：上次 install_source 被超时中断在半路，`sys.modules[...]`
      //     那行没执行到，而 Dart 侧的 `_registered` 集合已经写进去了）。
      //    此时直接返回 null，上层只看到"源没有内容"。
      //    ⇒ 命中该错误就**强制真注册一次**再试，能自愈，不必让用户重进 App。
      if (r == null &&
          script.startsWith('http') &&
          (lastError?.contains('No module named') ?? false)) {
        AppLog.instance.w('[SpiderService] 引擎缺模块 $moduleKey，强制重新注册后重试');
        final retried = await PythonScriptSources.instance.ensureInstalled(
          script,
          force: true,
        );
        if (retried != null) return _pythonCall(retried, action, pyArgs);
      }

      // 本地 Python 源（Documents/local_py/lp_*.py）：冷启动时首页可能比
      // 「本地源注册」更早发起请求，此时解释器里还没有这个模块。
      // 直接从 local_py 重新注册并重试一次，用户不必手动点「重新加载」。
      if (r == null &&
          !script.startsWith('http') &&
          (lastError?.contains('No module named') ?? false)) {
        AppLog.instance.w('[SpiderService] 本地 Python 源缺模块 $moduleKey，重新注册后重试');
        final ok = await LocalPythonSources.instance.ensureRegistered(
          moduleKey,
        );
        if (ok) return _pythonCall(moduleKey, action, pyArgs);
      }
      return r;
    }

    // ── drpy 标准源（api=drpy2.min.js + ext=站点.js）────────────
    // 由 drpy_host.js 提供 /config 与 /spider 路由，这里只负责确保它已载入。
    if (isDrpySource(api, ext)) {
      final k = await _ensureDrpyScript(api, ext, fallback: key, type: type);
      if (k == null) {
        lastError ??= 'drpy 源加载失败：$ext';
        return null;
      }
      return _postSpiderWithKeyFallback(
        candidates: [k],
        primaryKey: k,
        type: type,
        api: api,
        action: action,
        body: nodeArgs,
      );
    }

    // ── Node 引擎（JS / 无脚本地址）──────────────────────────
    var engineKey = key;
    // 🔴 2026-10-14 修（猫源 CatVod 切换不顺）：
    // `csp_xxx` 是「由当前已驻留 spider 脚本内置类处理」的占位 api，
    // 不是脚本地址——把它当脚本 loadSource('csp_xxx') 必然失败，
    // 导致 CatVod /config 下发的所有 csp_ 线路全部加载失败。
    // 非 http 的相对路径也不是可下载脚本，Node 加载不了，直接给明确错误而不是硬塞。
    // ⚠️ 但**必须排除** OmniBox 私有协议 `/spider/<key>/<n>` —— 那是合法形态
    //   （脚本已驻留，见 `_omniBoxProtocolKey`）。上一轮把它一起拦了，
    //   导致整包猫源（CatVod/OmniBox 订阅）的**所有线路**全报"暂不支持的源协议"✗。
    final isCspPlaceholder = script.toLowerCase().startsWith('csp_');
    // OmniBox 私有协议 `/spider/<key>/<type>`：与 csp_ 同类（脚本已驻留，
    // key 由 sites[] 给出），**必须放行** —— 详见 [_omniBoxProtocolKey] 的说明。
    final omniKey = _omniBoxProtocolKey(script);
    final isUnsupportedRelative =
        script.isNotEmpty &&
        !script.startsWith('http') &&
        !_isPythonScript(script) &&
        omniKey == null &&
        !script.toLowerCase().split('?').first.endsWith('.js') &&
        !script.toLowerCase().split('?').first.endsWith('.js.md5') &&
        !RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(script) &&
        !script.startsWith('file://');
    if (isUnsupportedRelative) {
      lastError =
          '该线路使用了暂不支持的源协议（$script），'
          '请换其他线路或改用整包 spider 订阅';
      AppLog.instance.w('[SpiderService] $lastError');
      return null;
    }
    // 本次请求可用的 key 候选。
    // ⚠️ 只有"按需载入脚本"的两条分支才填多候选（它们刚 query 过 /config）；
    //    猫源（OmniBox 私有协议）等路径**保持单候选**，行为与改动前完全一致，
    //    不会因为这次改动多打任何请求。
    var candidates = <String>[];
    if (omniKey != null) {
      // OmniBox 私有协议：脚本已在引擎里驻留，直接用它下发的站点 key 调引擎。
      // ⚠️ **不能**再走 loadSource —— 传进去的是个路径、不是脚本地址，
      //   而且会把已驻留的整包 spider 顶掉。
      engineKey = omniKey;
    } else if (script.isNotEmpty && !isCspPlaceholder) {
      // 聚合配置里的脚本源：按需载入脚本，用引擎自报的真实 key
      final k = await _ensureNodeScript(script, fallback: key, type: type);
      if (k == null) {
        lastError ??= '脚本源加载失败: $script';
        return null;
      }
      engineKey = k;
      candidates = List<String>.of(_loadedScriptCandidates);
    } else if (_needMainScriptRefresh) {
      // 主源（单 js spider 配置）：api 由 /config 下发、通常为空或 csp_ 占位。
      // 若期间被程序脚本源顶替过，这里把主源脚本重新载入。
      // ⚠️ drpy 主源要重新跑 drpy 宿主（api 是运行时，不能当整包脚本载入）。
      final k = _mainDrpyApi.isNotEmpty
          ? await _ensureDrpyScript(
              _mainDrpyApi,
              _mainDrpyExt,
              fallback: key,
              type: type,
            )
          : await _ensureNodeScript(mainScriptUrl, fallback: key, type: type);
      if (k != null) engineKey = k;
      candidates = List<String>.of(_loadedScriptCandidates);
    }

    // ✅ 候选 + 响应验证：404（路由不存在）⇒ 换下一个候选 key 重试（自愈）。
    return _postSpiderWithKeyFallback(
      candidates: candidates,
      primaryKey: engineKey,
      type: type,
      api: api,
      action: action,
      body: nodeArgs,
    );
  }

  // ============================================================
  // Spider API - 所有方法都接受 key/type/api/ext 参数
  //   · api = 原始 api（可能是远端脚本 URL / py_xxx.py / csp_xxx / ''）
  //   · ext = drpy2 模式下的站点脚本地址（普通源为空）
  // 引擎（Node / Python）与 key 的解析全在 _dispatchScript 内部完成。
  // ============================================================

  /// 获取 Spider 配置 - 对应 Swift getCatConfig
  /// 直接请求 Spider 服务器的 /config 端点（全局配置，不需要 key/type）
  Future<Map<String, dynamic>?> getCatConfig() async {
    if (!isSpiderReady) return null;

    final url = 'http://127.0.0.1:$_spiderPort/config';
    AppLog.instance.log('[SpiderService] getCatConfig: $url');

    try {
      final response = await _dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );

      final statusCode = response.statusCode ?? 0;
      final responseBody = response.data ?? '';

      if (statusCode >= 200 && statusCode <= 299) {
        try {
          final decoded = jsonDecode(responseBody);
          if (decoded is Map<String, dynamic>) {
            return decoded;
          }
          AppLog.instance.log(
            '[SpiderService] getCatConfig 响应不是JSON对象: body类型=${decoded.runtimeType}',
          );
          return null;
        } catch (e) {
          AppLog.instance.log(
            '[SpiderService] getCatConfig JSON解析失败: 错误=$e, body=${responseBody.length > 500 ? responseBody.substring(0, 500) : responseBody}',
          );
          return null;
        }
      } else {
        AppLog.instance.log(
          '[SpiderService] getCatConfig HTTP错误 $statusCode: body=${responseBody.length > 500 ? responseBody.substring(0, 500) : responseBody}',
        );
        return null;
      }
    } on DioException catch (e) {
      AppLog.instance.log(
        '[SpiderService] getCatConfig 失败: ${e.type}, ${e.message}',
      );
      return null;
    }
  }

  /// 识别 OmniBox 私有协议 `/spider/<key>/<type>` 并取出其中的 `<key>`。
  ///
  /// ── 为什么这不是"不支持的协议"（2026-10-14 修，用户实测）──────────
  /// 这类 `api` 出现在**整包 spider（CatVod / OmniBox）订阅**下发的 `sites[]` 里。
  /// 它不是可下载的脚本地址，而是"**当前已驻留的那份整包 spider 脚本内部某个
  /// 站点**"的标识 —— 等价于 `csp_` 占位：脚本已经在引擎里，客户端只需拿
  /// `sites[].key` 去调 `{base}/spider/{key}/{type}/{method}` 即可。
  ///
  /// 实测证据（用户 2026-10-14 的 app.log）：
  ///   · 正确形态：`POST /spider/omnibox_Makka聚合/3/init` → **200** ✓
  ///   · 错误形态：`POST /nodejs_omnibox_Makka聚合/3/init` → 404（少了 /spider）
  /// 上一轮把它当"不支持"直接拒绝 ⇒ 整包猫源的**所有线路**全部不可用 ✗。
  ///
  /// 返回：提取到的 key（**去掉 `nodejs_` 前缀**，与引擎路由一致）；非该形态返回 null。
  static String? _omniBoxProtocolKey(String script) {
    final s = script.trim();
    if (s.isEmpty) return null;
    final parts = s.split('/').where((e) => e.isNotEmpty).toList();
    if (parts.length < 2) return null;
    if (parts[0].toLowerCase() != 'spider') return null;
    var k = parts[1].trim();
    if (k.isEmpty) return null;
    if (k.toLowerCase().startsWith('nodejs_')) {
      k = k.substring('nodejs_'.length);
    }
    return k.isEmpty ? null : k;
  }

  /// 初始化 Spider - 对应 Swift initSpider
  ///
  /// Python 源没有 init 概念（引擎里注册即就绪）；JS 脚本源把脚本载入引擎即完成 init。
  Future<Map<String, dynamic>?> initSpider(
    String key,
    int type,
    String api, {
    String ext = '',
  }) async {
    final script = _scriptUrl(api, ext);
    if (script.isNotEmpty && _isPythonScript(script)) return null;

    // drpy 标准源：api 是运行时、ext 是站点规则 ⇒ 交给 drpy 宿主
    if (isDrpySource(api, ext)) {
      final k = await _ensureDrpyScript(api, ext, fallback: key, type: type);
      if (k == null) return null;
      return _postSpiderWithKeyFallback(
        candidates: [k],
        primaryKey: k,
        type: type,
        api: api,
        action: 'init',
        body: <String, dynamic>{},
      );
    }

    // key 的解析必须与 [_dispatchScript] **完全一致** —— 聚合配置里的脚本源
    // 配置 key 和引擎自报 key 不是一回事，这里用配置 key 会 init 404、
    // 而后五个接口却能通（init 失败会被调用方 catch 掉，问题很隐蔽）。
    var engineKey = key;
    var candidates = <String>[];
    // OmniBox 私有协议 `/spider/<key>/<type>`：脚本已驻留，key 由 sites[] 下发，
    // 直接用它；**不要**再 loadSource 一个路径（那会失败并把整包 spider 顶掉）。
    final omniKey = _omniBoxProtocolKey(script);
    if (omniKey != null) {
      engineKey = omniKey;
    } else if (script.isNotEmpty && !script.toLowerCase().startsWith('csp_')) {
      // ⚠️ csp_ 占位源：脚本已随主源驻留引擎，不能当脚本地址去 loadSource
      //    （会 404 白等一次网络往返），直接用配置 key 调引擎即可。
      final k = await _ensureNodeScript(script, fallback: key, type: type);
      if (k != null) engineKey = k;
      candidates = List<String>.of(_loadedScriptCandidates);
    } else if (_needMainScriptRefresh) {
      // 与 [_dispatchScript] 同一套判断（见 `_needMainScriptRefresh` 说明）
      final k = _mainDrpyApi.isNotEmpty
          ? await _ensureDrpyScript(
              _mainDrpyApi,
              _mainDrpyExt,
              fallback: key,
              type: type,
            )
          : await _ensureNodeScript(mainScriptUrl, fallback: key, type: type);
      if (k != null) engineKey = k;
      candidates = List<String>.of(_loadedScriptCandidates);
    }

    // 与内容接口同一套"候选 + 404 换 key"：init 也是 /spider/<key>/<type>/init，
    // key 不对一样是 404（日志里的 `/4/init not found` 就是它）。
    return _postSpiderWithKeyFallback(
      candidates: candidates,
      primaryKey: engineKey,
      type: type,
      api: api,
      action: 'init',
      body: <String, dynamic>{},
    );
  }

  /// 获取首页内容 - 对应 Swift getHomeContent
  Future<Map<String, dynamic>?> getHomeContent(
    String key,
    int type,
    String api, {
    String ext = '',
  }) {
    return _dispatchScript(
      key: key,
      type: type,
      api: api,
      ext: ext,
      action: 'home',
      nodeArgs: const {},
      pyArgs: const {},
    );
  }

  /// 获取分类内容 - 对应 Swift getCategoryContent
  Future<Map<String, dynamic>?> getCategoryContent(
    String key,
    int type,
    String api,
    String id, {
    int page = 1,
    Map<String, dynamic>? filters,
    String ext = '',
  }) {
    return _dispatchScript(
      key: key,
      type: type,
      api: api,
      ext: ext,
      action: 'category',
      nodeArgs: <String, dynamic>{
        'id': id,
        'page': page,
        'filter': filters != null && filters.isNotEmpty,
        'filters': filters ?? {},
      },
      pyArgs: <String, dynamic>{
        'tid': id,
        'pg': page,
        'filter': filters != null && filters.isNotEmpty,
        'extend': filters ?? {},
      },
    );
  }

  /// 获取详情 - 对应 Swift getDetail
  Future<Map<String, dynamic>?> getDetail(
    String key,
    int type,
    String api,
    String id, {
    String ext = '',
  }) {
    return _dispatchScript(
      key: key,
      type: type,
      api: api,
      ext: ext,
      action: 'detail',
      nodeArgs: <String, dynamic>{'id': id},
      pyArgs: <String, dynamic>{'ids': id},
    );
  }

  /// 获取播放 URL - 对应 Swift getPlayUrl
  Future<Map<String, dynamic>?> getPlayUrl(
    String key,
    int type,
    String api,
    String flag,
    String id, {
    String ext = '',
  }) async {
    final r = await _dispatchScript(
      key: key,
      type: type,
      api: api,
      ext: ext,
      action: 'play',
      nodeArgs: <String, dynamic>{'flag': flag, 'id': id},
      pyArgs: <String, dynamic>{'flag': flag, 'id': id},
    );
    return _normalizePlayResult(r);
  }

  /// 统一 `playerContent` 的返回：
  ///
  /// 很多 catvod / TVBox 源把 `header` 写成 **JSON 字符串**
  /// （如 NO视频：`"header": json.dumps({...})`），而播放器/嗅探页要的是
  /// Map —— 不转的话请求头会被静默丢掉，表现为"解析成功却 403/黑屏"。
  Map<String, dynamic>? _normalizePlayResult(Map<String, dynamic>? r) {
    if (r == null) return null;
    // Python 源（T3 规范）返回的是 `playUrl`（见 assets/python-project/.../__init__.py），
    // 而详情页读的是 `url` ⇒ 不转的话 py 源表现为「详情页正常、点播放没反应」。
    final u = r['url'];
    final urlMissing = u == null || (u is String && u.trim().isEmpty);
    if (urlMissing) {
      final alt = r['playUrl'] ?? r['play_url'] ?? r['jx'];
      if (alt is String && alt.trim().isNotEmpty) {
        r['url'] = alt;
      } else if (alt is List && alt.isNotEmpty) {
        r['url'] = alt;
      }
    }
    final h = r['header'];
    if (h is String && h.trim().isNotEmpty) {
      try {
        final m = jsonDecode(h);
        if (m is Map) {
          r['header'] = m.map((k, v) => MapEntry('$k', '$v'));
        }
      } catch (_) {
        // 不是 JSON 就保持原样（少数源确实给的是别的文本）
      }
    } else if (h is Map) {
      r['header'] = h.map((k, v) => MapEntry('$k', '$v'));
    }
    return r;
  }

  /// 搜索 - 对应 Swift search
  Future<Map<String, dynamic>?> search(
    String key,
    int type,
    String api,
    String keyword, {
    int page = 1,
    String ext = '',
  }) {
    return _dispatchScript(
      key: key,
      type: type,
      api: api,
      ext: ext,
      action: 'search',
      nodeArgs: <String, dynamic>{'wd': keyword, 'page': page},
      pyArgs: <String, dynamic>{'wd': keyword, 'pg': page},
    );
  }

  // ============================================================
  // searchWithSpider - 对应 Swift searchWithSpider
  // 原子操作：先 init 再 search，不受并发影响
  // ============================================================

  /// 使用指定 Spider 搜索 - 对应 Swift searchWithSpider
  /// 原子操作：先 init 再 search，不受并发影响
  Future<Map<String, dynamic>?> searchWithSpider({
    required String spiderKey,
    required int spiderType,
    required String api,
    required String keyword,
    int page = 1,
    String ext = '',
  }) async {
    // 先 init（忽略错误），再 search
    try {
      await initSpider(spiderKey, spiderType, api, ext: ext);
    } catch (e) {
      /* ignore */
    }

    return search(spiderKey, spiderType, api, keyword, page: page, ext: ext);
  }

  // ============================================================
  // 兼容旧接口 - 保留 setCurrentSpider 等方法
  // 用于非并发场景（如首页加载、详情页）
  // ============================================================

  /// 当前 Spider 会话（原子替换，避免多字段读到不一致组合）。
  ///
  /// 必须带上 [ext]：drpy2 脚本源的站点脚本在 ext 里（api 只是运行时），
  /// 详情页拿这个上下文调 getPlayUrl 时少了 ext 就会加载错脚本。
  ({String key, int type, String api, String ext})? _currentSpider;

  /// 设置当前 Spider 信息 - 对应 Swift setCurrentSpider
  /// 仅用于非并发场景。[api] 传**原始 api**（可能是远端脚本 URL）。
  void setCurrentSpider(
    String key,
    int type,
    String? api, {
    String? ext,
    String? jar,
  }) {
    _currentSpider = (key: key, type: type, api: api ?? '', ext: ext ?? '');
    AppLog.instance.log(
      '[SpiderService] setCurrentSpider: key=$key, type=$type, api=$api, ext=$ext',
    );
  }

  /// 获取当前 Spider 的 key/type/api/ext
  /// 用于非并发场景（如详情页获取播放 URL）
  /// **2026-09-26 修复**：原实现 `_currentKey!` / `_currentType!` 强解包，
  /// 若用户从未经过首页/分类加载（如从历史/收藏直接进 Spider 源详情），
  /// `_currentKey` 为 null，强解包抛空安全异常 → App 崩溃"像重启一样"。
  /// 改为空安全返回：未设置时返回空值，调用方自行降级。
  ({String key, int type, String api, String ext}) getCurrentSpiderInfo() {
    final s = _currentSpider;
    return (
      key: s?.key ?? '',
      type: s?.type ?? 0,
      api: s?.api ?? '',
      ext: s?.ext ?? '',
    );
  }

  /// 使当前 Spider 会话失效 - 对应 Swift invalidateSession
  /// 关键：必须同时关闭并重建 dio，否则 iOS 后台/锁屏后切回前台时
  /// dio 复用的 socket 已被系统断开，所有请求会静默失败
  void invalidateSession() {
    _currentSpider = null;
    // 引擎侧已载入的脚本状态也一并作废（Node 可能已被系统回收）
    _loadedScriptUrl = '';
    _loadedScriptKey = '';
    _loadedScriptCandidates = [];
    try {
      _dio.close(force: true);
    } catch (e) {
      /* ignore */
    }
    _dio = _buildDio();
  }
}

/// Dio 拦截器 - 记录所有 HTTP 请求到 AppLog
///
/// 关键: iOS 后台/锁屏切回前台时, dio 请求会卡住或失败, 拦截器记录
/// 每个请求的开始时间 + 状态码 + 耗时 + 错误, 帮助定位后台恢复时
/// 哪些 HTTP 请求卡住/失败
class _AppLogInterceptor extends Interceptor {
  static const _startTimeKey = '_appLogStartTime';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_startTimeKey] = DateTime.now();
    final port = _extractPort(options.uri);
    AppLog.instance.http(
      options.method,
      options.uri.toString(),
      port: port,
      caller: 'spider_dio',
    );
    super.onRequest(options, handler);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    final startAt = response.requestOptions.extra[_startTimeKey] as DateTime?;
    final elapsed = startAt == null
        ? null
        : DateTime.now().difference(startAt).inMilliseconds;
    final port = _extractPort(response.requestOptions.uri);
    AppLog.instance.http(
      response.requestOptions.method,
      response.requestOptions.uri.toString(),
      statusCode: response.statusCode,
      elapsedMs: elapsed,
      port: port,
      ok: true,
      caller: 'spider_dio',
    );
    super.onResponse(response, handler);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final startAt = err.requestOptions.extra[_startTimeKey] as DateTime?;
    final elapsed = startAt == null
        ? null
        : DateTime.now().difference(startAt).inMilliseconds;
    final port = _extractPort(err.requestOptions.uri);
    AppLog.instance.http(
      err.requestOptions.method,
      err.requestOptions.uri.toString(),
      statusCode: err.response?.statusCode,
      elapsedMs: elapsed,
      port: port,
      ok: false,
      error: '${err.type.name}/${err.message ?? ''}',
      caller: 'spider_dio',
    );
    super.onError(err, handler);
  }

  /// 从 URI 提取端口 (用于日志)
  int? _extractPort(Uri uri) {
    if (uri.port == 0) return null;
    return uri.port;
  }
}
