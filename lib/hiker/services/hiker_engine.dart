import 'dart:convert';

import 'package:dio/dio.dart';

import '../../services/app_log.dart';
import '../../services/nodejs_manager.dart';
import '../models/hiker_source.dart';
import 'hiker_builtin.dart';
import 'hiker_prefs.dart';
import 'hiker_store.dart';
import 'hiker_webview_service.dart';

/// 一次规则求值的结果
class HikerResult {
  final bool ok;
  final String? error;
  final List<HikerItem> list;
  final String playUrl;
  final String nextPage;
  final String pageTitle;

  /// 规则里 `setMyVar` 写回的变量（由调用方决定是否落盘）
  final Map<String, dynamic> vars;

  /// 规则实际发起了几次网页请求（调试 / 设置页展示）
  final int requests;

  /// 引擎侧耗时（毫秒）
  final int elapsedMs;

  /// 本次规则里出现的**延迟规则** id（`$('').lazyRule(fn)`）。
  ///
  /// 列表项 url 形如 `hiker://lazy#<id>` 时，把它带上再请求一次即可拿到真值
  /// （见 [HikerEngine.home] 的 `lazyId`）。
  final List<String> lazyIds;

  /// 规则用 `addListener(event, code)` 登记的**页面事件回调**。
  ///
  /// 海阔里这些回调由宿主持有、在页面生命周期事件时由原生回放；
  /// 我们是一次性求值 ⇒ 引擎把回调原样返回，**离开页面时**由宿主送回去执行
  /// （见 [HikerEngine.runEvents]）。实测 13 个源用到，几乎都是 `onClose` 清理。
  final Map<String, List<String>> listeners;

  /// 事件回调里调过 `refreshPage()`（宿主可据此重拉当前页）
  final bool needRefresh;

  const HikerResult({
    required this.ok,
    this.error,
    this.list = const [],
    this.playUrl = '',
    this.nextPage = '',
    this.pageTitle = '',
    this.vars = const {},
    this.requests = 0,
    this.elapsedMs = 0,
    this.lazyIds = const [],
    this.listeners = const {},
    this.needRefresh = false,
  });

  static HikerResult fail(String msg) => HikerResult(ok: false, error: msg);
}

/// 「海阔」规则执行器 —— 唯一出口是 Node 进程的 `POST /hiker/run`。
///
/// 为什么规则不在 Dart 里跑：海阔规则是 **JS**（全局 `$` / `setResult` /
/// 同步抓网页），而项目里的 JS 沙箱（vm + cheerio）在 Node 侧已有现成基建，
/// Dart 侧没有 JS 引擎。所以这里只做「转发 + 解析」。
///
/// ⚠️ 连的是 `127.0.0.1` ⇒ **不能走全局代理**（走了就连不上本地端口），
///    所以这里用一个干净的 Dio，不调 `applyGlobalProxy`。
class HikerEngine {
  HikerEngine._();
  static final HikerEngine instance = HikerEngine._();

  Dio _dio() {
    // 引擎侧的总预算由「海阔设置 → 执行超时」决定，Dart 侧要多留一点余量
    final budget = HikerPrefs.instance.timeoutSec;
    return Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: Duration(seconds: budget + 20),
      sendTimeout: const Duration(seconds: 20),
      responseType: ResponseType.plain,
    ));
  }

  /// 从 `/hiker/run` 的响应体里抠出 Node 侧给的错误文本。
  ///
  /// Node（`main.js`）在 `handleHikerApi` 抛错时回 **500 + `{ok:false,error:'海阔接口异常：…'}`**，
  /// 请求体过大时回 **413 + 同形状 JSON**。这个 `error` 才是真正的原因 ——
  /// Dio 的 `DioException.toString()` 完全看不到它。
  static String? _errorFromResponseBody(Object? data) {
    if (data == null) return null;
    final text = data.toString().trim();
    if (text.isEmpty) return null;
    try {
      final m = jsonDecode(text);
      if (m is Map) {
        final err = (m['error'] ?? '').toString().trim();
        if (err.isNotEmpty) return err;
      }
    } catch (_) {
      // 不是 JSON（例如网关插入的 HTML 错误页）→ 直接把原文当消息，别把信息丢了
    }
    return text.length > 400 ? '${text.substring(0, 400)}…' : text;
  }

  Future<HikerResult> _post(Map<String, dynamic> payload) async {
    // 注册 Node → Dart 的 WebView 钩子（幂等）：规则里用到
    // fetchCodeByWebView / lazyRule 时，Node 会回调 `/hiker/webview`。
    HikerWebViewService.register();

    // ── 🔴 自己确保 Node 已启动（幂等）──────────────────────────────
    // 与音乐模块同一个坑（见 music/pages/root_view.dart 的说明）：
    // Node 全局只在「配置里有 spider 源」时才被拉起 —— `app_state` 的
    // `_ensureNodeJSAndLoadSource` 在 `hasSpiderSource == false` 时**直接 return**。
    // 于是纯 TVBox 配置（只有 CMS 采集站、没有 jar/js spider）下 Node 从未启动，
    // 海阔这边一切请求都撞「Node 引擎未就绪」。
    // 海阔**不依赖影视源**，所以这里自己拉起一次；已运行/已就绪时幂等返回。
    var port = NodeJSManager.instance.managementPort;
    if (port <= 0) {
      try {
        // 兜个超时：Node 启动若卡住，不能把这次调用（以及界面）永久挂住
        await NodeJSManager.instance
            .startNodeJS()
            .timeout(const Duration(seconds: 30));
      } catch (e) {
        AppLog.instance.log('[Hiker] 启动 Node 失败/超时: $e');
      }
      // 端口是 Node 起来之后**回调**回来的，给它一点时间（最多 ~3s）
      for (var i = 0; i < 15 && port <= 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        port = NodeJSManager.instance.managementPort;
      }
    }
    if (port <= 0) {
      return HikerResult.fail(
          'Node 引擎没能启动（可到「设置 → 通用设置 → 引擎管理」手动加载一次）');
    }
    final dio = _dio();
    try {
      final resp = await dio.post<String>(
        'http://127.0.0.1:$port/hiker/run',
        data: jsonEncode(payload),
        options: Options(headers: {'Content-Type': 'application/json'}),
      );
      final body = (resp.data ?? '').toString();
      if (body.trim().isEmpty) return HikerResult.fail('引擎返回空响应');
      final m = jsonDecode(body);
      if (m is! Map) return HikerResult.fail('引擎返回格式异常');
      final map = Map<String, dynamic>.from(m);
      final ok = map['ok'] == true;
      final list = <HikerItem>[];
      final rawList = map['list'];
      if (rawList is List) {
        for (final e in rawList) {
          if (e is Map) list.add(HikerItem.fromJson(Map<String, dynamic>.from(e)));
        }
      }
      final vars = map['vars'] is Map
          ? Map<String, dynamic>.from(map['vars'] as Map)
          : <String, dynamic>{};
      final lazyIds = <String>[];
      final rawLazy = map['lazyIds'];
      if (rawLazy is List) {
        for (final e in rawLazy) {
          final s = e.toString();
          if (s.isNotEmpty) lazyIds.add(s);
        }
      }
      // 事件回调：`addListener('onClose', code)` 登记的那批（离开页面时回放）
      final listeners = <String, List<String>>{};
      final rawLs = map['listeners'];
      if (rawLs is Map) {
        rawLs.forEach((k, v) {
          final key = k.toString();
          if (v is! List) return;
          final codes = <String>[];
          for (final e in v) {
            final s = e.toString();
            if (s.trim().isNotEmpty) codes.add(s);
          }
          if (codes.isNotEmpty) listeners[key] = codes;
        });
      }
      return HikerResult(
        ok: ok,
        error: ok ? null : (map['error'] ?? '规则执行失败').toString(),
        list: list,
        playUrl: (map['playUrl'] ?? '').toString(),
        nextPage: (map['nextPage'] ?? '').toString(),
        pageTitle: (map['pageTitle'] ?? '').toString(),
        vars: vars,
        requests: (map['requests'] as num?)?.toInt() ?? 0,
        elapsedMs: (map['elapsedMs'] as num?)?.toInt() ?? 0,
        lazyIds: lazyIds,
        listeners: listeners,
        needRefresh: map['needRefresh'] == true,
      );
    } on DioException catch (e) {
      // ── 🔴 为什么要单独接一个 DioException ──────────────────────────────
      // Node 侧 `handleHikerApi` 抛错时，main.js 回的是 **HTTP 500 + JSON 体**
      // `{ok:false, error:'海阔接口异常：<真正的原因>'}`；而 Dio 默认把非 2xx 直接抛
      // DioException ⇒ 那句真正有用的原因（「规则重放次数超过上限」/「$.require 找不到
      // 模块」/「规则执行超时」…）**被整段丢掉**，界面上只剩
      // 「This exception was thrown because the response has a status code of 500 …」
      // 这种几百字的废话（用户 2026-10-15 反馈）。所以这里把响应体解回来。
      final real = _errorFromResponseBody(e.response?.data);
      if (real != null) {
        AppLog.instance.log(
            '[Hiker] /hiker/run 失败 HTTP ${e.response?.statusCode}: $real');
        return HikerResult.fail(real);
      }
      final code = e.response?.statusCode;
      final brief = code == null
          ? '海阔引擎请求失败（${e.type.name}）${e.message ?? ''}'
          : '海阔引擎返回 HTTP $code，且响应体为空';
      AppLog.instance.log('[Hiker] /hiker/run 失败: $brief');
      return HikerResult.fail(brief);
    } catch (e) {
      AppLog.instance.log('[Hiker] /hiker/run 失败: $e');
      return HikerResult.fail('$e');
    } finally {
      dio.close(force: true);
    }
  }

  Future<HikerResult> _run(
    HikerSource source,
    String action, {
    Map<String, dynamic> params = const {},
    Map<String, dynamic> vars = const {},
    Map<String, dynamic>? config,
    String lazyId = '',
  }) async {
    // 文件系统根：规则里的 `hiker://files/*`（可读写）与 `hiker://assets/*`
    // （App 自带资源，见 HikerBuiltin.installAssets）都靠它落地。
    final opts = Map<String, dynamic>.from(HikerPrefs.instance.engineOptions());
    final fDir = await HikerBuiltin.filesDir();
    final aDir = await HikerBuiltin.assetsDir();
    if (fDir.isNotEmpty) opts['filesDir'] = fDir;
    if (aDir.isNotEmpty) opts['assetsDir'] = aDir;
    return _post({
      'action': action,
      'source': source.toEngineJson(),
      'params': {
        ...params,
        // 延迟规则第二趟：带上 id，规则命中后直接执行 fn 拿真值
        if (lazyId.isNotEmpty) 'lazyId': lazyId,
      },
      'vars': vars,
      // 源配置（规则里的 `config.xxx`）：调用方没传就用源仓库里存的
      'config': config ?? HikerStore.instance.configOf(source.id),
      'options': opts,
    });
  }

  /// 首页（`find_rule`）
  Future<HikerResult> home(
    HikerSource source, {
    int page = 1,
    Map<String, dynamic> vars = const {},
    String lazyId = '',
  }) =>
      _run(source, 'home', params: {'page': page}, vars: vars, lazyId: lazyId);

  /// 分类（同 `find_rule`，但把 `class_url` 作为当前页地址传下去）
  ///
  /// 同时把分类地址/分类名传给引擎：规则里 `MY_CATE` / `MY_CLASS_URL` /
  /// `MY_CLASS_NAME` 读的就是它们（官方文档：分类名"仅在首页且写了替换词时可用"）。
  Future<HikerResult> category(
    HikerSource source,
    String cateUrl, {
    String cateName = '',
    int page = 1,
    Map<String, dynamic> vars = const {},
    String lazyId = '',
  }) =>
      _run(source, 'category', params: {
        'url': cateUrl,
        'cateUrl': cateUrl,
        'cateName': cateName,
        'page': page,
      }, vars: vars, lazyId: lazyId);

  /// 搜索（`search_url` 占位符 + `searchFind`）
  Future<HikerResult> search(
    HikerSource source,
    String keyword, {
    int page = 1,
    Map<String, dynamic> vars = const {},
    String lazyId = '',
  }) =>
      _run(source, 'search',
          params: {'keyword': keyword, 'page': page},
          vars: vars,
          lazyId: lazyId);

  /// 详情 / 取播放地址（`detail_find_rule` 为空时，引擎会把传入 url 当播放地址）
  Future<HikerResult> detail(
    HikerSource source,
    String url, {
    Map<String, dynamic> vars = const {},
    String lazyId = '',
  }) =>
      _run(source, 'detail', params: {'url': url}, vars: vars, lazyId: lazyId);

  /// 执行**页面事件回调**（`addListener(event, codes)` 登记的那批，见 [HikerResult.listeners]）。
  ///
  /// 宿主在**离开页面**时调用（fire-and-forget）：回调多半是清理逻辑
  ///（清 MyVar / 清缓存），执行后引擎会把改动过的变量回传，调用方负责落盘。
  Future<HikerResult> runEvents(
    HikerSource source,
    List<String> codes, {
    Map<String, dynamic> vars = const {},
    String url = '',
  }) =>
      _run(source, 'event', params: {'codes': codes, 'url': url}, vars: vars);
}
