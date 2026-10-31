import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:tvbox/pages/cf_verify_page.dart';
import 'package:tvbox/widgets/video_player_pip.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/models/source_bean.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/play_context_store.dart';
import 'package:tvbox/services/cf_session.dart';
import 'package:tvbox/services/dio_factory.dart';
import 'package:tvbox/services/drpy_service.dart';
import 'package:tvbox/services/nodejs_manager.dart';
import 'package:tvbox/services/local_python_sources.dart';
import 'package:tvbox/services/python_manager.dart';
import 'package:tvbox/services/python_script_sources.dart';

/// 把**回环** URL 的端口换成 [port]（其它主机 / 非法 URL 原样返回）。
///
/// 单独提出来是为了可测：这是"引擎重启换了端口，重试要打到新端口"的核心
/// 判断，写成私有方法就只能靠人肉验证（用户 2026-10-30 报的
/// `connectionError ... port: 61083` 正是这里没换端口导致的）。
@visibleForTesting
String rewriteLoopbackPort(String url, int port) {
  if (port <= 0) return url;
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  if (uri.host != '127.0.0.1' && uri.host != 'localhost') return url;
  if (uri.port == port) return url;
  return uri.replace(port: port).toString();
}

/// `api` 里**自带的路径基址**（OmniBox 私有协议那种），其余一律空串。
///
/// ── 这里曾经把「本地 JS 源」整条链路打断（用户 2026-10-30：
///    「本地JS还是没有内容」「订阅里全是那个本地JS的内容」）──────────
/// 原实现只有两条规则：`csp_` 开头 → 空；`http` 开头 → 空；**其余原样返回**。
/// 而本地 JS 源的 api 是 `ljs_xxxx.js` —— 既不 http 也不 csp_ ⇒ 被当成路径基址
/// ⇒ 拼出来的请求是：
///     `POST http://127.0.0.1:<port>/ljs_xxxx.js/home`
/// 而引擎的真实路由是 `/spider/<key>/<type>/<action>` ⇒ **必然 404**
/// ⇒ 本地 JS 永远"没有内容"。
/// 更糟的是：404 会触发 `_dispatchScript` 的「强制重载」自愈，而重载的
/// 还是那个本地脚本 ⇒ 引擎槽位**反复被本地 JS 占着**，于是订阅线路
/// （api 为空 / csp_ 占位）也全都落到它身上 ⇒「订阅里全是本地 JS 的内容」。
///
/// 所以：**脚本地址不是路径基址**。`.js` / `.js.md5` / 本地文件路径一律返回空串，
/// 退化成标准 `/spider/<key>/<type>/<action>`。
@visibleForTesting
String spiderApiBase(String api) {
  // ⚠️ 必须先归一化：配置里的 api 可能被反引号包住（`` `https://…` ``），
  //    不归一化就会 `startsWith('http') == false` → 被当成路径基址 →
  //    拼出 `` `https://…`/play `` 这种非法 URL。
  final a = SpiderService._normalizeScriptUrl(api);
  if (a.isEmpty) return '';
  // csp_ 占位不是路径基址：拼进 URL 会产出 `csp_xxx/play` 这种非法路径，
  // 必须退化为标准 /{key}/{type}/{action} 形态。
  if (a.toLowerCase().startsWith('csp_')) return '';
  if (a.startsWith('http')) return '';
  final path = a.toLowerCase().split('?').first;
  // 本地 JS 源 / 用户导入的 .js / file:// / Windows 绝对路径 —— 都是**脚本地址**
  if (path.endsWith('.js') || path.endsWith('.js.md5')) return '';
  if (a.startsWith('file://')) return '';
  if (RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(a)) return '';
  // 剩下的才是 OmniBox 那种真正的路径基址（`/spider/<key>/<type>`）
  return a;
}

/// 拼出 `/spider/<key>/<type>/<action>` 形态的路径（`apiBase` 非空时以它打头）。
@visibleForTesting
String composeSpiderPath(
  String key,
  int type,
  String apiBase,
  String action,
) {
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

/// 本地 JS 源脚本（`ljs_xxx.js`）在引擎里的**站点 key 兜底**。
///
/// 引擎侧 `spider_compat` 的 key 取 `meta.key || meta.name || config.key ||
/// config.name || 目录名`。本地源是我们自己写进缓存目录的，
/// `_loadLocalJsFile` 会把 `key` 写进 `index.config.js`（= 文件名去 `.js`），
/// 所以正常情况下引擎 key 就是 `ljs_xxx`。
/// 但 `/config` 不一定把这个站点列出来（单文件脚本常常没有 /config），
/// 那时 Dart 侧只能靠猜 —— 猜「文件名」比猜「UI 里的 sourceKey
/// （`localjs_ljs_xxx`）」准得多。
///
/// 返回 null 表示不是本地 JS 脚本标识。
@visibleForTesting
String? localScriptKeyOf(String script) {
  final s = script.trim();
  final m = RegExp(r'^(ljs_[A-Za-z0-9]+)\.js$').firstMatch(s);
  return m?.group(1);
}

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
    // 引擎重启会换端口 ⇒ 槽位里的脚本/key 全没了，必须作废记忆。
    // （只在**端口真的变了**时清，避免引擎启动过程中反复清空）
    try {
      NodeJSManager.instance.spiderPortListenable.addListener(
        _onEnginePortChanged,
      );
    } catch (e) {
      // 纯 Dart 单测里没有 platform channel（NodeJSManager 构造会碰
      // MethodChannel）—— 端口监听只是自愈优化，注册不上不影响功能。
      AppLog.instance.log('[SpiderService] 端口监听注册失败（可忽略）: $e');
    }
  }

  /// 上次已知的引擎端口（用来判断"这次通知是不是真换了端口"）。
  int _lastKnownPort = 0;

  void _onEnginePortChanged() {
    final p = _spiderPort;
    // 0 = 引擎正在停/重启，等新端口回来再说（此时清也没意义）
    if (p <= 0) return;
    if (p == _lastKnownPort) return;
    _lastKnownPort = p;
    // 端口变了 = 换了一个引擎实例 ⇒ 连 `/config` 注册表一起作废（见
    // resetScriptCache 的说明：换源只清脚本槽位，重启才清注册表）。
    resetEngineMemory();
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
  String _buildSpiderPath(
    String key,
    int type,
    String apiBase,
    String action,
  ) => composeSpiderPath(key, type, apiBase, action);

  /// 构建完整的 Spider URL
  String _buildSpiderUrl(String key, int type, String apiBase, String action) {
    return 'http://127.0.0.1:$_spiderPort${_buildSpiderPath(key, type, apiBase, action)}';
  }

  // ============================================================
  // 核心 POST 请求 - 对应 Swift postJSON
  // ============================================================

  /// 发送 POST 请求到 Spider 服务 - 对应 Swift postJSON
  /// 使用 ResponseType.plain 手动解析 JSON，接受 200-299 状态码
  static const int _maxPostRetries = 1;
  static const Duration _postRetryDelay = Duration(milliseconds: 300);

  /// 把回环 URL 里的端口换成**当前**的 spider 端口。
  ///
  /// ── 为什么需要（用户 2026-10-30：切「官方聚合」首页报
  /// 「引擎请求失败：DioExceptionType.unknown（动作 home）」，
  /// 紧接着一条 `connectionError ... port: 61083`）────────────────
  /// 引擎**重启会换端口**（Node 侧通过 `/onCatPawOpenPort` 回传新端口），
  /// 而 URL 是在发请求**之前**用 `_spiderPort` 拼死的字符串。
  /// 于是"引擎刚好在这一次请求前后重启"时：
  ///   · 请求打到**已经关掉的旧端口** ⇒ `connectionError`；
  ///   · 重试仍然用那个**旧的 URL 字符串** ⇒ 再失败一次 ⇒ 整页报错；
  ///   · 而此刻新端口早就回来了，用户点一下「重试」就好了 ——
  ///     这正是"必须手动重试才出内容"的来源。
  /// 重试前调这里，端口变了就换成新的重发。
  String _withCurrentPort(String url) => rewriteLoopbackPort(url, _spiderPort);

  Future<Map<String, dynamic>?> _postJSON(
    String url,
    Map<String, dynamic> body,
  ) async {
    var target = url;
    for (var attempt = 0; attempt <= _maxPostRetries; attempt++) {
      try {
        final response = await _dio.post<String>(
          target,
          data: jsonEncode(body),
          options: Options(
            contentType: Headers.jsonContentType,
            responseType: ResponseType.plain,
            // ── 🔴 本地引擎请求**不复用连接**（2026-10-30）──────────────
            // 原来复用 keep-alive：iOS 从后台切回来时，复用的那条 socket
            // 已经被系统单方面关掉（半死：没收到 RST），第一次请求必然失败。
            // 当时的"解法"是失败后 `_dio.close(force: true)` 重建客户端 ——
            // 但那是**全进程共享的 dio**，关闭会**连带取消所有正在飞的请求**
            // （dio 的报错原文就是 `Connection attempt cancelled`，用户截图里
            //  那条 `connectionError` 正是被别的请求重试时误杀的）。
            // 本地回环建连只要亚毫秒，不复用连接既没成本又彻底断掉这个坑。
            persistentConnection: false,
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
            _lastPostFailure = '返回的不是 JSON 对象（${decoded.runtimeType}）';
            AppLog.instance.log(
              '[SpiderService] 响应不是JSON对象: $target, body类型=${decoded.runtimeType}',
            );
            return null;
          } catch (e) {
            _lastPostFailure = '返回内容无法按 JSON 解析（${responseBody.length} 字节）';
            AppLog.instance.log(
              '[SpiderService] JSON解析失败: $target, 错误=$e, body=${responseBody.length > 500 ? responseBody.substring(0, 500) : responseBody}',
            );
            return null;
          }
        } else {
          lastHttpStatus = statusCode;
          _lastPostFailure = 'HTTP $statusCode';
          AppLog.instance.log(
            '[SpiderService] HTTP错误 $statusCode: $target, body=${responseBody.length > 500 ? responseBody.substring(0, 500) : responseBody}',
          );
          return null;
        }
      } on DioException catch (e) {
        final isRetriable =
            e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.sendTimeout ||
            e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.unknown;
        if (attempt < _maxPostRetries && isRetriable) {
          // ① 端口变了（引擎重启）→ 直接换新端口，不必等
          final fresh = _withCurrentPort(target);
          if (fresh != target) {
            AppLog.instance.log(
              '[SpiderService] 引擎端口已变，改用新端口重试：$target ⇒ $fresh',
            );
            target = fresh;
            continue;
          }
          // ② 端口没变（半死 socket / 引擎忙）→ 稍等再发一次。
          //    ⚠️ **不 close dio**：它是共享实例，关掉会连带取消其它在飞的请求。
          AppLog.instance.log(
            '[SpiderService] POST $target 第 ${attempt + 1} 次失败，${_postRetryDelay.inMilliseconds}ms 后重试: ${e.type}/${e.message}',
          );
          await Future.delayed(_postRetryDelay);
          continue;
        }
        final code = e.response?.statusCode ?? 0;
        lastHttpStatus = code;
        final respBody = e.response?.data?.toString() ?? '';
        _lastPostFailure =
            '${e.type}'
            '${code > 0 ? ' HTTP $code' : ''}'
            '${e.message == null ? '' : '（${e.message}）'}';
        AppLog.instance.log(
          '[SpiderService] POST $target 失败: code=$code, type=${e.type}, message=${e.message}, body=${respBody.length > 500 ? respBody.substring(0, 500) : respBody}',
        );
        return null;
      } catch (e) {
        _lastPostFailure = '$e';
        AppLog.instance.log('[SpiderService] POST $target 未知错误: $e');
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
  static String _nodeBase(String api) => spiderApiBase(api);

  /// 「主源脚本」地址（整包就是一个 js spider 的配置）：由 AppState 在加载主源时
  /// 登记。用于「打开过程序脚本源后回到主源」时把主源脚本重新载入引擎。
  String mainScriptUrl = '';

  /// **换主页源时把"引擎槽位里驻留着谁"的记忆全部作废**（2026-10-30）。
  ///
  /// ── 为什么必须（用户原话）──────────────────────────────────────
  /// 「订阅JS脚本源为啥和本地JS这个切换总是出问题了，本地JS加载不出来，
  ///   但是在订阅JS这个里面又出现了，并且订阅里面所有的全是这个本地JS的内容」
  ///
  /// 根因是**一组单槽位缓存**（[_loadedScriptUrl] / [_loadedScriptKey] /
  /// [mainScriptUrl]）只描述"上一次载入了什么"，而 Node 引擎本身是**单源**
  /// 的：换源、切订阅、引擎重启、别的模块（音乐/阅读）借 Node 跑脚本，
  /// 任何一件事都会让槽位内容变掉，但这份记忆不会跟着变。
  ///
  /// 于是出现两个互相纠缠的症状：
  ///   · 切到本地 JS：缓存说"已经载入过了"⇒ 跳过 loadSource ⇒ 请求打到
  ///     引擎里**还驻留着的订阅脚本**上 ⇒ key 不认识 ⇒ 404 ⇒「本地JS加载不出来」；
  ///   · 切回订阅：`_tryDeriveMainScript` 又把本地 JS 当成主源脚本推导出来 ⇒
  ///     key 正好命中引擎里的本地 JS ⇒ 订阅页面上**全是本地 JS 的内容**。
  ///
  /// 换源是用户主动动作，此时唯一正确的假设是"我不知道槽位里是什么"，
  /// 下次请求老老实实按新源重新判断 + 重新载入。
  ///
  /// ── 2026-10-30 再修：**只清"载入了谁"，不清"引擎里有什么"** ────────
  /// 用户发来的 `app_2026-10-30.log` 里同一秒内出现：
  ///   21:53:37.088  setCurrentSpider(localjs_…) + 「换源 ⇒ 作废脚本记忆」
  ///   21:53:37.364  setCurrentSpider(omnibox_短剧聚合)      ← 短剧页并发改全局源
  ///   21:53:37.380  「引擎端口 ⇒ 52697，作废脚本/端口记忆」  ← 换源把引擎重启了
  ///   21:53:37.361  POST /spider/omnibox_短剧聚合/3/category → 打旧端口 52448 失败
  /// 三个页面（影视首页 / 短剧 / 详情）**共用一份单槽位记忆**，任何一方换源都把
  /// 别人的记忆清掉 ⇒ 各自重新载入 ⇒ 抢同一个引擎槽位 ⇒ 谁最后载入谁的内容
  /// 就显示在所有人页面上，这就是用户说的「串」；重启后只剩一个页面在跑，所以正常。
  ///
  /// 所以这里按"作废的是什么"拆开：
  ///   · [resetScriptCache]（换源）：引擎**没换**，只清"载入了哪个脚本"。
  ///     `_engineSiteTypes` 是引擎自己的注册表，换源后照样有效 —— 清掉它会让
  ///     key/type 校正直接退化，本来能通的路由被判 404。
  ///   · [resetEngineMemory]（端口变了 / 引擎重启）：连注册表一起清。
  ///
  /// 两者都**不清** `_scriptLoadInFlight` / `_drpyLoadInFlight`：那是"正在飞的
  /// 载入"，清掉会让下一次请求再起一次 `loadSource`，两边同时往同一个
  /// `index.js` 写 ⇒ 文件被交替写坏（见 [_scriptLoadInFlight] 的注释）。
  /// 作废"记忆"和"取消在飞的载入"是两件事。
  void resetScriptCache() {
    _clearScriptSlot();
    _cancelHandBack();
    // 换源 ⇒ 还在排队/在飞的载入全部作废（见 [_sessionGeneration]）。
    _sessionGeneration++;
    AppLog.instance.log('[SpiderService] 换源 ⇒ 作废脚本记忆（端口不动，引擎还在跑），下次请求重新载入');
  }

  /// 引擎换了实例（重启换端口）：槽位和注册表都不可信了。
  void resetEngineMemory() {
    _clearScriptSlot();
    _engineSiteTypes.clear();
    _cancelHandBack();
    _sessionGeneration++;
    AppLog.instance.log('[SpiderService] 引擎端口 ⇒ $_spiderPort，作废脚本/端口记忆');
  }

  /// 只清"上一次载入了什么"，不碰引擎侧状态、不碰在飞的载入。
  void _clearScriptSlot() {
    _loadedScriptUrl = '';
    _loadedScriptKey = '';
    _loadedScriptCandidates = [];
    _loadedDrpyExt = '';
    _mainDrpyApi = '';
    _mainDrpyExt = '';
    mainScriptUrl = '';
  }

  /// 把 Dart 这份「槽位里是谁」与**引擎侧唯一真源**对齐。
  ///
  /// ── 为什么需要（用户 2026-10-31：「不要再串了」）────────────────
  /// Node 是单槽位，但"现在驻留的是谁"原先有两份记录：引擎里的
  /// `sourceModule`，和这里的 [_loadedScriptUrl]。两份一旦不一致，
  /// 请求就会带着 A 的 key 打到 B 的服务上 —— 404，或者「切了源内容没变 /
  /// 全是另一个源的内容」，这就是用户说的"串"。
  ///
  /// 造成不一致的路径是**绕开 [_ensureNodeScript] 直接换槽位**：
  /// `AppState.manualLoadNodeEngine` 直接调 `NodeJSManager.loadSource()`，
  /// 换了槽位却没人更新这里。现在引擎侧会把"载入成功的源标识"记下来
  /// （`NodeJSPlatform.loadedScriptId`），每次判定前对齐一次即可根治。
  ///
  /// 只在**引擎明确报出一个不同的 id** 时纠正，两种例外保持原样：
  ///   · 引擎返回空串（还没载入 / 平台不支持）= 不知道，保留 Dart 侧记录；
  ///   · 当前记录是 drpy 标记（`drpy::<ext>`）= drpy 宿主不走 `loadSource`，
  ///     引擎侧看到的还是上一个 catvod 包，据此纠正会误伤 drpy 的缓存命中。
  void _syncSlotFromEngine() {
    // 引擎从没起过 ⇒ 谈不上"槽位里驻留了谁"，直接返回。
    //
    // 绝不能为了读一下状态就去拿 `NodeJSManager.instance`：那是懒加载单例，
    // 构造里会 initialize 平台通道 —— 等于「查一次缓存」把整个 Node 引擎拉起来
    // （几百 MB + 端口），在没有 WidgetsBinding 的测试里还会直接抛断言。
    final mgr = NodeJSManager.existing;
    if (mgr == null) return;
    final resident = mgr.loadedScriptId;
    if (resident.isEmpty) return;
    if (_loadedScriptUrl == resident) return;
    if (_loadedScriptUrl.startsWith('drpy::')) return;
    AppLog.instance.log(
      '[SpiderService] 槽位对齐（引擎侧为准）: '
      '"$_loadedScriptUrl" → "$resident"',
    );
    _loadedScriptUrl = resident;
    // key / 候选都属于**另一个包**，必须重问，不能沿用
    _loadedScriptKey = '';
    _loadedScriptCandidates = [];
  }

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
  /// —— 引擎是按各模块 `meta.type` 挂路由的（见 Node 侧 spider 源导出的
  /// `meta`）。而调用方的 type 来自订阅配置的 `sites[].type`，
  /// **两者未必相等**：
  ///   · 实测整包 TVBox 源那条线路声明 `type=4`，引擎按模块 meta 注册的是 `3`
  ///     ⇒ `POST /spider/omnibox_Makka聚合/4/init` 404 `Route ... not found`；
  ///   · key 又是对的、候选只有一个 ⇒ 连"换 key"重试都没有，整条线路直接废掉。
  /// 引擎自己 `/config` 的 sites[] 就是它的注册表 ⇒ 404 时拿它校正 type。
  final Map<String, int> _engineSiteTypes = {};

  /// 最近一次 `_postJSON` 的 HTTP 状态码（0 = 连接层错误）。
  /// 用来判定"404 = 路由不存在 = key 不对"，从而触发换 key 重试。
  int? lastHttpStatus;

  /// 最近一次 `_postJSON` 失败的**具体原因**（HTTP 码 / 非 JSON / 连接异常）。
  ///
  /// 为什么单独记：单候选路径（本地源 / 私有协议 / 主源刷新）失败时
  /// `_postSpiderWithKeyFallback` 原来**不设 lastError** 就直接 return null，
  /// 上层只能抛笼统的「该源没有返回任何内容」—— 用户看到这句话时，
  /// 根本分不清是端口打错（连接被拒）、路由 404、脚本 500，还是返回了 HTML。
  /// 记下现场后由 [_describeSpiderFailure] 拼成可读文案。
  String? _lastPostFailure;

  /// 把最近一次失败拼成一句用户能看懂的话。
  String _describeSpiderFailure(String action) {
    final detail = _lastPostFailure;
    if (detail == null || detail.isEmpty) return '引擎没有响应（原因未知）';
    return '引擎请求失败：$detail（动作 $action）';
  }

  /// Node 槽位里当前驻留的脚本是不是 [url]。
  ///
  /// 为什么需要（洞 E）：Node 是**单源架构**，程序脚本源载入后会顶掉主源。
  /// 上层判断"主源本会话已加载、不用再 loadSource"时必须连这个一起看 ——
  /// 否则会直接去取 `/config`，拿回来的是**那个脚本的站点表**，
  /// 整表替换后线路全错（表现为"切了源但内容不对"）。
  bool isScriptLoaded(String url) {
    final u = url.trim();
    if (u.isEmpty) return false;
    // 判定前先和引擎对齐一次，别拿失真的缓存去回答"已载入了吗"
    _syncSlotFromEngine();
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

  /// `mainScriptUrl` 未登记时（聚合订阅/多线路配置里第一个 spider 线路的
  /// api 为空，`AppState._loadSpiderSource` 会提前 return），从订阅源列表
  /// 推导「主脚本」并登记 —— 否则切回订阅线路时引擎槽位还驻留着本地 JS 源，
  /// 请求落到旧脚本上表现为「切不过来 / 还是本地 JS 的内容」。
  ///
  /// 只认真正能下载进 Node 槽位的脚本（http(s) URL 或相对 .js），
  /// csp_ 占位 / 空 / .py / jar 一律跳过；找不到时保持空，
  /// 后续请求由 `_dispatchScript` 给出明确错误而不是静默 404。
  void _tryDeriveMainScript() {
    if (mainScriptUrl.isNotEmpty) return;
    try {
      // 🔴 2026-10-30：**先看用户当前选中的线路**，再退回列表顺序。
      //   与 `AppState._loadSpiderSource` 同一套口径 —— 两处都按"列表第一个"
      //   推导的话，切到订阅里第二条 spider 线路后，主源脚本仍指向第一条，
      //   `api` 为空 / `csp_` 占位的线路会被派到旧脚本上（切了源内容不变）。
      final api = ApiConfig.instance;
      final home = api.homeSourceBean.value;
      final beans = <SourceBean>[
        if (home != null) home,
        ...api.sourceBeanList,
      ];
      for (final s in beans) {
        if (!s.isSpiderSource || s.isPythonScriptSource) continue;
        if (s.key.startsWith('app_')) continue;
        // 🔴 本地 JS 源**不是**订阅主脚本（2026-10-30）。
        //
        // 它的 `scriptUrl` 是 `ljs_xxxx.js` 这种**相对标识**，落在
        // `<Documents>/local_js/` 里，是用户自己导进来的"程序脚本源"。
        // 之前这里只排除了 `app_` 前缀，于是本地 JS 源会被当成"订阅主源脚本"
        // 登记进 `mainScriptUrl` —— 而它在引擎里的 key 恰好正驻留着，
        // 后续所有"api 为空"的订阅线路请求都会命中它 ⇒
        // 订阅页面**整页都是本地 JS 的内容**（用户 2026-10-30 报的就是这个）。
        if (s.isLocalJsSource) continue;
        // 同理：api 是 `ljs_xxx.js` / 本地绝对路径的线路（用户自己在源管理里
        // 加的本地脚本）也不是订阅主源脚本。
        if (s.isLocalScriptApi) continue;
        final u = s.scriptUrl.trim();
        if (u.isEmpty) continue;
        final lower = u.toLowerCase();
        if (lower.startsWith('csp_')) continue; // 占位不是脚本地址
        final path = lower.split('?').first;
        if (path.startsWith('ljs_')) continue; // 兜底：相对标识一律不认
        if (!lower.startsWith('http') && !path.endsWith('.js')) continue;
        mainScriptUrl = u;
        AppLog.instance.log(
          '[SpiderService] 兜底登记主源脚本: $u（源 ${s.key}）',
        );
        return;
      }
    } catch (e) {
      AppLog.instance.w('[SpiderService] 推导主源脚本失败: $e');
    }
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

  /// 从错误文本里提取 `CF_CHALLENGE:<host>`（Python 侧抛的标记）
  static String? _cfHostOf(String? err) {
    if (err == null) return null;
    final i = err.indexOf('CF_CHALLENGE:');
    if (i < 0) return null;
    final rest = err.substring(i + 'CF_CHALLENGE:'.length);
    return RegExp(r'^[A-Za-z0-9.\-]+').firstMatch(rest)?.group(0);
  }

  /// 弹一次 CF 验证页（用全局 navigator，service 层没有 context）
  ///
  /// 走到这里说明"本来就该有缓存却没通过"⇒ 旧 cookie 已失效，先清掉再验。
  Future<bool> _askCfVerify(String host) async {
    final nav = VideoPlayerPip.navigatorKey.currentState;
    if (nav == null) return false;
    await CfSession.instance.invalidate(host);
    final ok = await nav.push<bool>(
      MaterialPageRoute(
        builder: (_) => CfVerifyPage(url: 'https://$host/', host: host),
      ),
    );
    return ok == true;
  }

  /// 调 Python 引擎执行源方法（module=video.<key>，args 为 kwargs）
  ///
  /// 命中 Cloudflare 挑战时：弹一次验证页 → 成功则自动重试一次（不再反复打扰）。
  Future<Map<String, dynamic>?> _pythonCall(
    String moduleKey,
    String action,
    Map<String, dynamic> args, {
    bool retried = false,
  }) async {
    final r = await PythonManager.instance.call(
      'video.$moduleKey',
      action,
      args,
    );
    // 取出错误文本（通道错误 / runner 把异常包成 {ok:false, error}）
    String? errText;
    if (!r.ok) {
      errText = r.error;
    } else {
      final j = r.json;
      if (j is Map && j['ok'] == false) {
        errText = '${j['error'] ?? ''}\n${j['trace'] ?? ''}';
      }
    }
    // Cloudflare 挑战：**弹一次让用户点**，成功后自动重试（只重试一次）
    final cfHost = _cfHostOf(errText);
    if (cfHost != null && cfHost.isNotEmpty && !retried) {
      AppLog.instance.w('[SpiderService] 命中 CF 挑战 $cfHost，弹验证');
      final ok = await _askCfVerify(cfHost);
      if (ok) {
        return _pythonCall(moduleKey, action, args, retried: true);
      }
    }
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
      _lastPostFailure = null;
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
      if (lastHttpStatus != 404) {
        lastError ??= _describeSpiderFailure(action);
        return null;
      }
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
    // 单候选且只试过一次（没换过）⇒ 维持原行为：不动缓存
    // （下次进来还能复用，避免把一次偶发 404 放大成"整源作废"）。
    // ⚠️ 但**必须把失败原因带上**：这条路径覆盖了本地 JS/PY 源、OmniBox 私有协议、
    //    主源刷新 —— 都是最常用的一批源。原来 lastError 为 null 就 return，
    //    上层只能抛「该源没有返回任何内容」，把"端口打错 / 404 / 500 / 非 JSON"
    //    全糊成一句，完全没法定位（2026-10-30 用户报「官方聚合用不了」即此）。
    if (!mayVary) {
      lastError ??= _describeSpiderFailure(action);
      return null;
    }
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

  /// 引擎**只有一个槽位**（一个 Node 进程、一份 `sourceModule`）。
  ///
  /// ── 为什么要有这把锁（用户 2026-11-01：「切换一个就切换一个引擎，
  ///    不要它们串」）────────────────────────────────────────────────
  /// 上面那个 [_scriptLoadInFlight] 是**按脚本地址分桶**的：A 脚本正在
  /// `loadSource` 时，B 脚本照样能同时进来 `loadSource` —— 引擎里后写的把
  /// 先写的**顶掉**，两个请求还各自带着"我以为槽位里是我"的 key 继续发，
  /// 结果就是 A 的页面显示 B 的内容（"串"）。
  ///
  /// 用户要的"一个源一个引擎"物理上早就成立（本来就是一个进程），
  /// 缺的是**写者串行**：这把锁把所有 `loadSource` / drpy `load` 排成一队，
  /// 同一时刻只有一个在写槽位。
  Future<void> _loadQueue = Future<void>.value();

  /// 源会话代数：用户换源 / 引擎重启时 +1。
  ///
  /// 排队等锁的请求可能是在**换源之前**发起的；轮到它时用户已经切到别的源，
  /// 它再 `loadSource` 就等于把新源顶掉 —— 又变回"串"。
  /// 所以每个请求入队时记下代数，真正执行前比对，不一致就**直接放弃**，
  /// 而不是"排队排到最后把别人覆盖掉"。
  int _sessionGeneration = 0;
  int get sessionGeneration => _sessionGeneration;

  // ============================================================
  // 槽位归属者（方案 B，用户 2026-11-01「走 B」）
  // ============================================================
  //
  // 引擎只有一个槽位，但**谁在用**必须说得清。以前只有一个
  // `_loadedScriptUrl`，它只回答"载入的是哪个脚本"，不回答"这个脚本是谁要的"
  // ⇒ 短剧页把槽位换成自己的脚本后，影视首页的请求照样往里打，两边互相顶。
  //
  // 现在每次载入都登记 owner：
  //   · 同 owner + 同脚本 ⇒ 命中，不重新载入（不抖）；
  //   · 不同 owner ⇒ 排队换槽位（不串）；
  //   · 槽位空闲 [_kHandBackDelay] 后，自动把**影视主源**的脚本装回去，
  //     这样用户从短剧/海阔回到影视首页时不用再等一次 loadSource。

  /// 影视模块（默认归属者，也是空闲归还的目标）。
  static const String ownerVod = 'vod';

  /// 短剧模块。
  static const String ownerDrama = 'drama';

  /// 小程序 / 海阔 / RSS 共用的播放与列表页。
  static const String ownerMiniApp = 'miniapp';

  /// 阅读模块。
  static const String ownerReading = 'reading';

  /// 槽位当前属于谁（空 = 不知道 / 已作废）。
  String _slotOwner = '';
  String get slotOwner => _slotOwner;

  /// 每个归属者最后一次用的脚本（空闲归还时把 [ownerVod] 的那条装回去）。
  final Map<String, String> _ownerScript = {};

  Timer? _handBackTimer;

  /// 槽位空闲多久把主源装回去。
  ///
  /// 太短会在「影视 ↔ 短剧」来回切时反复 loadSource（每次 0.5~2s，明显卡）；
  /// 太长又等于没还。8 秒够用户看完一次翻页，也够在切回影视前还完。
  static const Duration _kHandBackDelay = Duration(seconds: 8);

  /// 登记「这次载入是谁要的」，并安排空闲归还。
  void _noteSlotOwner(String owner, String script) {
    _slotOwner = owner;
    _ownerScript[owner] = script;
    _handBackTimer?.cancel();
    _handBackTimer = null;
    // 影视主源本来就该常驻，不用归还
    if (owner == ownerVod) return;
    final primary = _ownerScript[ownerVod];
    if (primary == null || primary.isEmpty) return;
    _handBackTimer = Timer(_kHandBackDelay, () {
      if (_slotOwner == ownerVod) return;
      if (_slotOwner != owner) return; // 期间又被别人占了，让它自己还
      AppLog.instance.log('[SpiderService] 槽位空闲 ⇒ 归还主源: $primary');
      // 归还**不动代数**：它只是把槽位装回主源，不该作废别人在飞的请求。
      unawaited(
        _ensureNodeScript(primary, fallback: '', owner: ownerVod),
      );
    });
  }

  /// 取消空闲归还（换源 / 引擎重启时调用）。
  void _cancelHandBack() {
    _handBackTimer?.cancel();
    _handBackTimer = null;
    _slotOwner = '';
  }

  /// 把一次"写引擎槽位"的操作排进全局队列。
  ///
  /// 队列本身用 Future 链实现（不引入额外依赖）：前一个跑完（无论成败）
  /// 才轮到下一个；[gate] 保证失败也不会把整条链卡死。
  Future<T> _enqueueLoad<T>(Future<T> Function() job) {
    final prev = _loadQueue;
    final gate = Completer<void>();
    _loadQueue = gate.future;
    return prev
        .catchError((Object _) {})
        .then((_) => job())
        .whenComplete(() {
          if (!gate.isCompleted) gate.complete();
        });
  }

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
    // 这条是「载入主源」= 一次换源动作：
    //   · 先 +1 代数，让所有在排队/在飞的其它脚本载入作废；
    //   · 再进全局队列，避免和它们同时写同一个槽位。
    _sessionGeneration++;
    return _enqueueLoad(() => NodeJSManager.instance.loadSource(api));
  }

  /// 确保 drpy 源已载入宿主，返回站点 key。
  Future<String?> _ensureDrpyScript(
    String api,
    String ext, {
    String fallback = 'drpy',
    int? type,
    String owner = ownerVod,
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
      _noteSlotOwner(owner, 'drpy::$extUrl');
      return Future.value(_loadedScriptKey);
    }
    final playing = _drpyLoadInFlight[extUrl];
    if (playing != null) {
      AppLog.instance.log('[SpiderService] drpy 正在载入，复用同一次流程: $extUrl');
      _noteSlotOwner(owner, 'drpy::$extUrl');
      return playing;
    }
    final gen = _sessionGeneration;
    final fut = _enqueueLoad(
      () => _ensureDrpyScriptInner(
        api,
        extUrl,
        fallback: fallback,
        type: type,
        gen: gen,
      ),
    );
    _drpyLoadInFlight[extUrl] = fut;
    fut.then(
      (k) {
        if (k != null) _noteSlotOwner(owner, 'drpy::$extUrl');
      },
      onError: (Object _) {},
    );
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
    required int gen,
  }) async {
    // 排队期间换源 ⇒ 作废（drpy 的 `load` 同样会顶掉引擎槽位）
    if (gen != _sessionGeneration) {
      AppLog.instance.log(
        '[SpiderService] 换源了（代数 $gen → $_sessionGeneration），丢弃过期 drpy 载入: $extUrl',
      );
      lastError = '已切换线路，本次载入作废';
      return null;
    }
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
    String owner = ownerVod,
  }) {
    final playing = _scriptLoadInFlight[script];
    if (playing != null) {
      AppLog.instance.log('[SpiderService] 脚本正在载入，复用同一次流程: $script');
      _noteSlotOwner(owner, script);
      return playing;
    }
    // 入队前记下代数：排队期间用户换源了，这一趟就该作废
    final gen = _sessionGeneration;
    final fut = _enqueueLoad(
      () => _ensureNodeScriptInner(
        script,
        fallback: fallback,
        type: type,
        gen: gen,
      ),
    );
    _scriptLoadInFlight[script] = fut;
    // 载入成功才登记归属者：失败/作废的那一趟不配占用槽位。
    // ⚠️ 必须带 onError：`then` 会派生一个新 Future，没人监听时错误会变成
    //    未捕获异步异常（Flutter 里直接进 zone error）。这里只关心成功值。
    fut.then(
      (k) {
        if (k != null) _noteSlotOwner(owner, script);
      },
      onError: (Object _) {},
    );
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
    required int gen,
  }) async {
    // 排队等锁期间用户换源了 ⇒ 这一趟是"上一个源"的残留，绝不能写槽位。
    // 直接放弃（返回 null 会让调用方报"加载失败"，比顶掉新源好得多）。
    if (gen != _sessionGeneration) {
      AppLog.instance.log(
        '[SpiderService] 换源了（代数 $gen → $_sessionGeneration），丢弃过期载入: $script',
      );
      lastError = '已切换线路，本次载入作废';
      return null;
    }
    // 命中判定前先对齐：引擎里可能已经被别的路径换成了另一个包
    // （手动加载引擎 / 未来的新入口），不对齐就会「缓存说 A、引擎里是 B」⇒ 串。
    _syncSlotFromEngine();
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
      // 等端口这几秒里也可能被换源 ⇒ 落盘前再比一次代数，
      // 否则"用户已经切到 B 了，这里又把 A 写回槽位"。
      if (gen != _sessionGeneration) {
        AppLog.instance.log(
          '[SpiderService] 换源了（代数 $gen → $_sessionGeneration），'
          '放弃写入槽位: $script',
        );
        lastError = '已切换线路，本次载入作废';
        return null;
      }
      final (loaded, msg) = await NodeJSManager.instance.loadSource(script);
      if (!loaded) {
        // 用户 2026-10-27（「脚本源加载失败:ljs_xxx.js 这是为啥？」）：
        // 原来这里把 Node 侧的真实原因（load-error.txt 里的
        // `Cannot use import statement outside a module` /
        // `Cannot find module '../../util/req.js'`）**只写进日志**，
        // 上层 `_dispatchScript` 又 `??=` 覆盖成一句「脚本源加载失败: 文件名」，
        // 用户完全看不出为什么。这里把真实原因存进 lastError 透传到 UI。
        final detail = (msg ?? '').trim();
        lastError = detail.isEmpty
            ? '脚本源加载失败：$script'
            : '脚本源加载失败：$script\n$detail';
        AppLog.instance.w('[SpiderService] 脚本载入失败 $script: $detail');
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
      lastError = '脚本源载入异常：$e';
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
    String owner = ownerVod,
  }) async {
    final script = _scriptUrl(api, ext);
    // 每轮清一次：否则上一次失败的旧原因会粘住（`??=` 会保留它），
    // 让用户看到与本次无关的错误。
    lastError = null;
    // 下面 `_needMainScriptRefresh` / `_ensureNodeScript` 的判定全依赖
    // "槽位里现在是谁"，先和引擎侧唯一真源对齐一次，避免带着 A 的 key
    // 打到 B 的服务上（"串"）。
    _syncSlotFromEngine();

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
      final k = await _ensureDrpyScript(api, ext, fallback: key, type: type, owner: owner);
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
      final k = await _ensureNodeScript(script, fallback: key, type: type, owner: owner);
      if (k == null) {
        lastError ??= '脚本源加载失败: $script';
        return null;
      }
      engineKey = k;
      candidates = List<String>.of(_loadedScriptCandidates);
      // ── 本地 JS 源的 key 兜底（2026-10-30）─────────────────────
      // 单文件脚本常常没有 /config ⇒ `_loadedScriptCandidates` 为空，
      // 于是退回 `key`（= UI 里的 `localjs_ljs_xxx`）—— 那个前缀引擎根本不认，
      // 必然 404 ⇒「本地JS还是没有内容」。
      // 引擎真实 key 是脚本文件名去 `.js`（见 `_loadLocalJsFile` 写的
      // index.config.js），这里补上：候选为空时**直接用它**，否则排到最后兜底。
      final localKey = localScriptKeyOf(script);
      if (localKey != null) {
        if (candidates.isEmpty) {
          engineKey = localKey;
          candidates = [localKey];
        } else if (!candidates.contains(localKey)) {
          candidates = [...candidates, localKey];
        }
      }
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
              owner: owner,
            )
          : await _ensureNodeScript(mainScriptUrl, fallback: key, type: type, owner: owner);
      if (k != null) engineKey = k;
      candidates = List<String>.of(_loadedScriptCandidates);
    } else {
      // script 空 / csp_ 占位的订阅线路：请求必须落到「订阅主脚本」上。
      // 🔴 2026-10-29 兜底（用户：「本地JS和订阅切换的时候，没切换过来」）：
      //   聚合订阅 / 多线路配置里第一个 spider 线路 api 往往为空，
      //   `AppState._loadSpiderSource` 提前 return ⇒ `mainScriptUrl` 没登记 ⇒
      //   `_needMainScriptRefresh` 恒 false ⇒ 直接用线路 key 打引擎 ——
      //   而引擎槽位已被本地 JS 源（ljs_*.js）顶替 ⇒ 404，表现为
      //   「切回订阅还是本地 JS 的内容 / 切不过来」。
      //   这里先尝试从订阅列表推导主脚本登记；仍拿不到就给明确错误。
      _tryDeriveMainScript();
      if (_needMainScriptRefresh) {
        final k = _mainDrpyApi.isNotEmpty
            ? await _ensureDrpyScript(
                _mainDrpyApi,
                _mainDrpyExt,
                fallback: key,
                type: type,
                owner: owner,
              )
            : await _ensureNodeScript(mainScriptUrl, fallback: key, type: type, owner: owner);
        if (k != null) engineKey = k;
        candidates = List<String>.of(_loadedScriptCandidates);
      } else if (mainScriptUrl.isEmpty) {
        lastError =
            '该线路是订阅脚本线路，但当前没有可载入的主源脚本，'
            '请重新加载订阅或在「设置 → 引擎管理」里手动加载 Node 源';
        AppLog.instance.w('[SpiderService] $lastError（key=$key）');
        return null;
      }
    }

    // ✅ 候选 + 响应验证：404（路由不存在）⇒ 换下一个候选 key 重试（自愈）。
    final first = await _postSpiderWithKeyFallback(
      candidates: candidates,
      primaryKey: engineKey,
      type: type,
      api: api,
      action: action,
      body: nodeArgs,
    );
    if (first != null) return first;

    // ── 404 的最后一道自愈：强制重载脚本再试一次（2026-10-30）──────────
    //
    // 缓存说"这个脚本已经载入了"，但 Node 是**单槽位**：换源、引擎重启、
    // 音乐/阅读模块借 Node 跑脚本，都会把槽位换成别的东西，而
    // `_loadedScriptUrl` 不会跟着变。此时请求会落到**另一个脚本**上，
    // 表现就是「切了源内容没变」「本地JS加载不出来」。
    //
    // 404 = 路由不存在 = 引擎里那个脚本根本不认识这条 action。
    // 这是唯一能确认"缓存撒谎了"的信号，所以只对它重载一次
    // （连接错误 / 500 不重载：那是真故障，重载只会白等一遍）。
    //
    // ⚠️ OmniBox 私有协议（`omniKey != null`）**必须排除**：它的脚本是
    //    整包驻留的，重载会把整包顶掉，反而把本来能用的源弄坏。
    if (lastHttpStatus == 404 &&
        omniKey == null &&
        !isCspPlaceholder &&
        script.isNotEmpty) {
      AppLog.instance.w(
        '[SpiderService] $action 404 ⇒ 判定槽位与缓存不一致，强制重载后重试: $script',
      );
      _loadedScriptUrl = '';
      _loadedScriptKey = '';
      _loadedScriptCandidates = [];
      final k = await _ensureNodeScript(script, fallback: key, type: type, owner: owner);
      if (k != null) {
        final retry = await _postSpiderWithKeyFallback(
          candidates: List<String>.of(_loadedScriptCandidates),
          primaryKey: k,
          type: type,
          api: api,
          action: action,
          body: nodeArgs,
        );
        if (retry != null) return retry;
      }
    }
    return null;
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
    String owner = ownerVod,
  }) async {
    final script = _scriptUrl(api, ext);
    if (script.isNotEmpty && _isPythonScript(script)) return null;

    // drpy 标准源：api 是运行时、ext 是站点规则 ⇒ 交给 drpy 宿主
    if (isDrpySource(api, ext)) {
      final k = await _ensureDrpyScript(api, ext, fallback: key, type: type, owner: owner);
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
      final k = await _ensureNodeScript(script, fallback: key, type: type, owner: owner);
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
              owner: owner,
            )
          : await _ensureNodeScript(mainScriptUrl, fallback: key, type: type, owner: owner);
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
    String owner = ownerVod,
  }) {
    return _dispatchScript(
      key: key,
      type: type,
      api: api,
      ext: ext,
      action: 'home',
      nodeArgs: const {},
      pyArgs: const {},
      owner: owner,
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
    String owner = ownerVod,
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
      owner: owner,
    );
  }

  /// 获取详情 - 对应 Swift getDetail
  Future<Map<String, dynamic>?> getDetail(
    String key,
    int type,
    String api,
    String id, {
    String ext = '',
    String owner = ownerVod,
  }) {
    return _dispatchScript(
      key: key,
      type: type,
      api: api,
      ext: ext,
      action: 'detail',
      nodeArgs: <String, dynamic>{'id': id},
      pyArgs: <String, dynamic>{'ids': id},
      owner: owner,
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
    String owner = ownerVod,
  }) async {
    final r = await _dispatchScript(
      key: key,
      type: type,
      api: api,
      ext: ext,
      action: 'play',
      nodeArgs: <String, dynamic>{'flag': flag, 'id': id},
      pyArgs: <String, dynamic>{'flag': flag, 'id': id},
      owner: owner,
    );
    return _normalizePlayResult(r);
  }

  /// 统一 `playerContent` 的返回：
  ///
  /// 很多 catvod / TVBox 源把 `header` 写成 **JSON 字符串**
  /// （如 NO视频：`"header": json.dumps({...})`），而播放器要的是
  /// Map —— 不转的话请求头会被静默丢掉，表现为"取到地址却 403/黑屏"。
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
    String owner = ownerVod,
  }) {
    return _dispatchScript(
      key: key,
      type: type,
      api: api,
      ext: ext,
      owner: owner,
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
    String owner = ownerVod,
  }) async {
    // 先 init（忽略错误），再 search
    try {
      await initSpider(spiderKey, spiderType, api, ext: ext, owner: owner);
    } catch (e) {
      /* ignore */
    }

    return search(spiderKey, spiderType, api, keyword,
        page: page, ext: ext, owner: owner);
  }

  // ============================================================
  // 兼容旧接口 - 保留 setCurrentSpider 等方法
  // 用于非并发场景（如首页加载、详情页）
  // ============================================================

  /// 当前 Spider 会话，**按归属者分区**（原子替换，避免多字段读到不一致组合）。
  ///
  /// 必须带上 [ext]：drpy2 脚本源的站点脚本在 ext 里（api 只是运行时），
  /// 详情页拿这个上下文调 getPlayUrl 时少了 ext 就会加载错脚本。
  ///
  /// ── 为什么从单值改成 Map（用户 2026-11-01「走 B」）──────────────
  /// 以前是**一个全局变量**：影视首页 setCurrentSpider(A) 之后，短剧页
  /// 并发 setCurrentSpider(B) ⇒ 详情页 `getCurrentSpiderInfo()` 拿到 B 的
  /// api/ext，用 B 的上下文去请求 A 的播放地址 ⇒ 404 或"内容串了"。
  /// 现在各模块写各自的分区，互不覆盖：
  ///   `setCurrentSpider(..., owner: ownerDrama)` / `getCurrentSpiderInfo(owner: ...)`。
  final Map<String, ({String key, int type, String api, String ext})>
      _spiderByOwner = {};

  /// 设置当前 Spider 信息 - 对应 Swift setCurrentSpider
  /// 仅用于非并发场景。[api] 传**原始 api**（可能是远端脚本 URL）。
  void setCurrentSpider(
    String key,
    int type,
    String? api, {
    String? ext,
    String? jar,
    String owner = ownerVod,
  }) {
    _spiderByOwner[owner] =
        (key: key, type: type, api: api ?? '', ext: ext ?? '');
    // 落一份到持久化仓库：进程被杀 / 会话失效 / 从历史直接进详情时，
    // 详情页可以按源 key 把这个上下文原样恢复（见 play_context_store.dart）。
    PlayContextStore.instance.rememberSpider(
      key: key,
      type: type,
      api: api ?? '',
      ext: ext ?? '',
      jar: jar ?? '',
    );
    AppLog.instance.log(
      '[SpiderService] setCurrentSpider[$owner]: key=$key, type=$type, api=$api, ext=$ext',
    );
  }

  /// 获取当前 Spider 的 key/type/api/ext
  /// 用于非并发场景（如详情页获取播放 URL）
  /// **2026-09-26 修复**：原实现 `_currentKey!` / `_currentType!` 强解包，
  /// 若用户从未经过首页/分类加载（如从历史/收藏直接进 Spider 源详情），
  /// `_currentKey` 为 null，强解包抛空安全异常 → App 崩溃"像重启一样"。
  /// 改为空安全返回：未设置时返回空值，调用方自行降级。
  ({String key, int type, String api, String ext}) getCurrentSpiderInfo({
    String owner = ownerVod,
  }) {
    final s = _spiderByOwner[owner];
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
    _spiderByOwner.clear();
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
