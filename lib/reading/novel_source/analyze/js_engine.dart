/// JS 沙箱引擎：基于 flutter_js 执行书源内嵌的 `@js` / `<js>` 脚本。
library;

// [PATCH-5] 引擎换成 quickjs_engine（MIT，API 兼容 flutter_js）：
// 它基于 QuickJS-NG、各平台同一引擎，且自带本机 loopback 同步服务器
// （QuickJsService.evaluate 用 SyncHttpClient 同步拿结果），
// 与上游 2.0.8 自 fork 的 quickjs 方案同源。
import 'package:quickjs_engine/quickjs_engine.dart';

import '../novel_chinese_converter.dart';
import '../../../services/app_log.dart';
import 'legado_java_prelude.dart';
import 'js_polyfills.dart';

class JsEngine {
  /// 进程级共享引擎：书源解析（搜索/发现/详情/目录/正文）全程复用同一个
  /// quickjs runtime，避免「每个 AnalyzeRule 各建一个引擎且从不释放」导致
  /// 原生内存/句柄持续泄漏——3907 个书源并发解析时必然闪退。
  ///
  /// 安全性：flutter_js 的 evaluate 是**同步**调用，Dart 单线程内同一时刻
  /// 只有一个 eval 在执行；每次 eval 前都会重新注入 `java/result/baseUrl`
  /// 等绑定，顺序执行语义与独立实例一致。
  static final JsEngine shared = JsEngine();

  JavascriptRuntime? _runtime;

  /// [PATCH-5] 最近一次 eval 的错误信息（`isError` 或抛异常时写入，成功时清空）。
  ///
  /// 为什么需要：原实现在出错时只记日志并返回空串，调用方**看不到错误内容**
  /// ⇒ `java.ajax` 的"需要抓取"标记 `__LEGADO_NEED__{...}` 无从传给 Dart，
  /// 同步重放（`SyncHttpBridge.pendingRequest`）就驱动不起来。
  String? lastError;

  /// 是否已注入全局预置脚本（繁简转换 t2s()/s2t()）。
  bool _preludeInjected = false;

  // ── 按源注入 `jsLib`（修一个真缺陷）──────────────────────────────
  //
  // 现象（真机日志）：
  //   `ReferenceError: qmSearch is not defined`
  //   `ReferenceError: wrCredentials is not defined`
  //   `ReferenceError: getSign is not defined`
  //
  // 根因：书源的 `jsLib` 字段（模型里有，`book_source.dart:21`）
  // **全项目从来没有任何地方使用过它** ⇒ 书源作者写在 jsLib 里的工具函数
  // （搜索签名、凭据计算、解密等）**从来没有进入 JS 上下文** ✗
  // ⇒ 规则里一调用就是 ReferenceError，被 `eval` 吞成空串，表现为"规则不生效"。
  //
  // 修法：**按源维度**把 jsLib 注入同一个 runtime。
  //   · 源变了 → **重建 runtime**（避免 A 源的 jsLib 污染 B 源）✓
  //   · 同一个源重复进入 → **不重复注入** ✓
  //   · jsLib 为空 → 什么都不做（绝大多数源没写 jsLib）✓

  /// 已注入 jsLib 的**源标识**（`bookSourceUrl`，退化时用 `bookSourceName`）
  String? _jsLibSourceId;

  /// 下一次取 [runtime] 时待注入的 jsLib（由 [setActiveSource] 填入）
  String? _pendingJsLib;

  /// 当前生效的源标识（供 `source.getKey()` 之类查询，也便于排查）
  String? get activeSourceId => _jsLibSourceId;

  /// 声明"接下来要解析的书源"。
  ///
  /// ⚠️ **必须在开始解析该源之前调用**（`WebBook` 的 search/bookInfo/toc/content
  ///    四个入口各调一次）—— 只有这样 jsLib 才会**先于**规则执行进入上下文 ✓
  ///
  /// [sourceId] 用 `bookSourceUrl`（同源稳定、跨会话稳定）；
  /// [jsLib] 就是源的 `jsLib` 字段原文。
  void setActiveSource(String? sourceId, String? jsLib) {
    final id = (sourceId ?? '').trim();
    final lib = (jsLib ?? '').trim();

    // ① 同源且已注入过 → 什么都不用做（不重复注入、不重建）
    if (id == _jsLibSourceId && _pendingJsLib == null) return;

    // ② 换源 → 必须重建 runtime，否则上一个源的 jsLib 会**跨源污染** ✗
    final sourceChanged = id != _jsLibSourceId;
    _jsLibSourceId = id;
    _pendingJsLib = lib.isEmpty ? null : lib;

    if (sourceChanged) {
      // 重建：清掉旧 runtime（其全局函数、变量、缓存全部丢弃）
      try {
        _runtime?.dispose();
      } catch (_) {/* dispose 失败不影响后续重建 */}
      _runtime = null;
      _preludeInjected = false;
    }

    // ③ **立即**注入（此时通常还没建 runtime，会顺带建好并注入）
    //    这样即使调用方随后走了不经过 `runtime` getter 的路径，jsLib 也已就位。
    if (_pendingJsLib != null) {
      _applyPendingJsLib();
    }
  }

  /// 把 [_pendingJsLib] 注入运行时，成功后清空 pending。
  void _applyPendingJsLib() {
    final lib = _pendingJsLib;
    if (lib == null) return;
    try {
      final r = runtime; // 确保 runtime + 预置脚本已就绪

      // ── 🔴 必须**在全局作用域**求值（我第一版写错了）──────────────
      //
      // 第一版包成 `(function(){ <jsLib> })();` ✗ ——
      // 于是 jsLib 里的 `function qmSearch(){}` 变成了**该函数作用域的局部声明**，
      // 规则里再调 `qmSearch(key, page)` 就是 `ReferenceError: qmSearch is not defined` ✗
      //（实测日志：注入"成功"了，但规则照样报 is not defined —— 正是这个原因。）
      //
      // 现在**直接顶层求值** ✓：jsLib 里的 `var`/`function` 都是顶层声明，
      // 后续 eval 共享同一个 QuickJS 全局上下文，规则即可直接调用 ✓
      final res = r.evaluate(lib);
      if (res.isError) {
        final msg = res.stringResult;
        // ⚠️ `Packages.*`（Legado/Rhino 的 Java 互操作）在 QuickJS 里**天然不存在** ——
        //    这类 jsLib 不是"我们注入错了"，而是**引擎能力边界**。
        //    单独给一条更准确的日志，免得把排查方向带偏 ✗
        final isJavaInterop = msg.contains('Packages') || msg.contains('java.');
        AppLog.instance.w(isJavaInterop
            ? '[书源JS] jsLib 用到了 Java 互操作（Packages/java.*），'
                'QuickJS 不支持（源=$_jsLibSourceId）: $msg'
            : '[书源JS] jsLib 注入失败（源=$_jsLibSourceId）: $msg');
        // **不清 pending** 没意义（重试还会失败），但要避免每次 eval 都重试：
        // 注入失败也清掉，只报一次错，避免日志刷屏。
      } else {
        AppLog.instance.d('[书源JS] jsLib 已注入（源=$_jsLibSourceId，'
            '${lib.length} 字符）');
      }
    } catch (e) {
      AppLog.instance.w('[书源JS] jsLib 注入异常（源=$_jsLibSourceId）: $e');
    } finally {
      _pendingJsLib = null;
    }
  }

  /// 单次求值的「JS 执行预算」（毫秒）。
  ///
  /// 书源里一个 `while(true){}` / 病态正则会让求值永不返回 —— 本 runtime
  /// 是在主 isolate 上同步 `evaluate` 的，卡住即冻死界面。装上限兜住：
  /// 超时由原生中断处理器打断成可捕获错误（日志里会显示「执行超时」）。
  ///
  /// ⚠️ 只计**脚本自身**耗时，宿主请求（java.ajax 等）的等待不计入，
  /// 所以慢速网络源不会因此被误杀。
  // 2026-10-18：10s → 20s。部分书源的 jsLib 是混淆大脚本（几万行），
  // 首次求值在低端机上会超过 10s，被误判为"规则执行超时"。
  static const int _evalTimeoutMs = 20000;

  /// JS 堆上限（64MB）：防止病态脚本把内存吃爆导致 OOM 崩溃。
  static const int _evalMemoryLimit = 64 * 1024 * 1024;

  JavascriptRuntime get runtime {
    if (_runtime == null) {
      _runtime = getJavascriptRuntime(extraArgs: const {
        'timeout': _evalTimeoutMs,
        'memoryLimit': _evalMemoryLimit,
      });
      _injectPrelude();
      // 预置脚本就绪后补注入 jsLib（首次取 runtime 时 pending 还没消费）
      _applyPendingJsLib();
    }
    return _runtime!;
  }

  /// 注入全局预置脚本：书源 JS 内可直接调用 `t2s(str)` / `s2t(str)`
  /// 做繁简转换（短语级最长匹配 + 字符级回退，与阅读器正文转换同表同语义）。
  /// QuickJS 同一运行时的全局声明跨 eval 持久，注入一次即可。
  void _injectPrelude() {
    if (_preludeInjected) return;
    _preludeInjected = true;
    // ── 标准全局垫片（借鉴 qjs_ultra 的能力面，纯 JS 实现）──────────
    // QuickJS-NG 原生没有 TextEncoder/TextDecoder/Buffer/crypto/URL 等
    // Web 全局，而部分书源脚本（尤其带签名/哈希/编解码的源）依赖它们。
    // 注入 atob/btoa/TextEncoder/TextDecoder(UTF-8)/Buffer/crypto(md5、
    // sha1、sha256、randomBytes、subtle)/URLSearchParams/URL/performance
    // 纯 JS 实现；GBK/GB2312 网络层已自动转 UTF-8，此处显式抛错提示。
    try {
      final polyfillResult = _runtime!.evaluate(jsStandardPolyfills);
      if (polyfillResult.isError) {
        AppLog.instance.w(
            '[书源JS] 标准全局垫片注入失败: ${polyfillResult.stringResult}');
      }
    } catch (e) {
      AppLog.instance.w('[书源JS] 标准全局垫片注入异常: $e');
    }
    try {
      final result = _runtime!.evaluate(chineseConverterJsPrelude);
      if (result.isError) {
        AppLog.instance.w(
            '[书源JS] 繁简转换预置脚本注入失败: ${result.stringResult}');
      }
    } catch (e) {
      AppLog.instance.w('[书源JS] 繁简转换预置脚本注入异常: $e');
    }
    // [PATCH-5] 注入 legado 宿主对象 `java`（纯 JS 实现 + 同步重放协议）。
    // 此前 `java` 是 AnalyzeRule 实例的字符串化结果，任何 java.xxx() 都是
    // TypeError → 规则静默返回空串。现覆盖 put/get/base64/hex/timeFormat/
    // toast，以及 ajax/get/post/head 的"查缓存/抛抓取标记"协议；
    // 需要 Dart 侧规则求值的（getString 变量等）显式抛错并记日志。
    try {
      final javaResult = _runtime!.evaluate(legadoJavaPrelude);
      if (javaResult.isError) {
        AppLog.instance.w('[书源JS] java 宿主预置脚本注入失败: ${javaResult.stringResult}');
      }
    } catch (e) {
      AppLog.instance.w('[书源JS] java 宿主预置脚本注入异常: $e');
    }
  }

  /// 执行 [jsStr]，绑定 [bindings] 为 JS 全局变量。
  ///
  /// 返回值规整（对齐书源脚本语义）：
  /// - 脚本异常 / 返回 `undefined` / `null` → 空串（书源表达式里无意义，
  /// 避免 URL 等场景出现字面量 "null"）；
  /// - QuickJS 把整数表达式返回为 double（`19.0`）时去掉小数位；
  /// - 其余按字符串原样返回。
  ///
  /// 执行失败记录到运行日志（设置 → 高级 → 运行日志），便于真机排查
  /// 「书源 JS 规则不生效」类问题（脚本摘要 + 错误信息）。
  String eval(String jsStr, {Map<String, dynamic>? bindings}) {
    final result = evalResult(jsStr, bindings: bindings);
    if (result == null || result.isError) return '';
    var s = result.stringResult;
    if (s == 'null' || s == 'undefined' || s.isEmpty) return '';
    // 整数结果带 .0（QuickJS 按 double 返回）时规整，避免 URL 拼接出错。
    if (s.length > 2 && RegExp(r'^-?\d+\.0+$').hasMatch(s)) {
      s = s.substring(0, s.indexOf('.'));
    }
    return s;
  }

  /// 与 [eval] 相同，但保留**原始 Dart 类型**（List / Map / num / bool…）。
  ///
  /// 书源的目录/搜索规则经常是 `@js:` 直接返回数组（如
  /// `@js:JSON.parse(result).data.list`）。`stringResult` 对数组/对象只能
  /// 给 `[object Object]` 之类的字符串，调用方再判 `is List` 就会失败，
  /// 表现成「这个源没有返回任何章节」。列表类规则统一走这里。
  JsEvalResult? evalResult(String jsStr, {Map<String, dynamic>? bindings}) {
    try {
      if (bindings != null) {
        for (final entry in bindings.entries) {
          runtime.evaluate('var ${entry.key} = ${_toJsValue(entry.value)};');
        }
      }
      final result = runtime.evaluate(jsStr);
      if (result.isError) {
        lastError = result.stringResult;
        AppLog.instance.w(
            '[书源JS] 执行失败: ${_brief(jsStr)} → ${result.stringResult}');
        return result;
      }
      lastError = null;
      return result;
    } catch (e) {
      lastError = '$e';
      AppLog.instance.w('[书源JS] 执行异常: ${_brief(jsStr)} → $e');
      return null;
    }
  }

  String evalWithResult(String jsStr, {Map<String, dynamic>? bindings}) {
    return eval(jsStr, bindings: bindings);
  }

  /// 截断脚本为单行摘要（日志用，避免长脚本刷屏）。
  static String _brief(String js) {
    final oneLine = js.replaceAll('\n', ' ').trim();
    return oneLine.length > 140 ? '${oneLine.substring(0, 140)}…' : oneLine;
  }

  String _toJsValue(dynamic value) {
    if (value == null) return 'null';
    if (value is String) return '"${_escapeJs(value)}"';
    if (value is num) return value.toString();
    if (value is bool) return value.toString();
    if (value is List) {
      final items = value.map(_toJsValue).join(',');
      return '[$items]';
    }
    if (value is Map) {
      final entries = value.entries.map((e) => '"${_escapeJs(e.key.toString())}":${_toJsValue(e.value)}').join(',');
      return '{$entries}';
    }
    return '"${_escapeJs(value.toString())}"';
  }

  String _escapeJs(String s) {
    return s
        .replaceAll('\\', '\\\\')
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t')
        // JS 行分隔符/段分隔符（正文等文本可能含，直接放入 JS 字符串字面量
        // 会触发 SyntaxError，须按 \u 转义）。
        .replaceAll('\u2028', '\\u2028')
        .replaceAll('\u2029', '\\u2029');
  }

  void dispose() {
    _runtime?.dispose();
    _runtime = null;
    // 运行时重建后需重新注入预置脚本。
    _preludeInjected = false;
  }
}
