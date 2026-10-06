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

  JavascriptRuntime get runtime {
    if (_runtime == null) {
      _runtime = getJavascriptRuntime();
      _injectPrelude();
    }
    return _runtime!;
  }

  /// 注入全局预置脚本：书源 JS 内可直接调用 `t2s(str)` / `s2t(str)`
  /// 做繁简转换（短语级最长匹配 + 字符级回退，与阅读器正文转换同表同语义）。
  /// QuickJS 同一运行时的全局声明跨 eval 持久，注入一次即可。
  void _injectPrelude() {
    if (_preludeInjected) return;
    _preludeInjected = true;
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
    try {
      if (bindings != null) {
        for (final entry in bindings.entries) {
          runtime.evaluate('var ${entry.key} = ${_toJsValue(entry.value)};');
        }
      }
      final result = runtime.evaluate(jsStr);
      if (result.isError) {
        lastError = result.stringResult; // [PATCH-5] 供同步重放解析抓取标记
        AppLog.instance.w('[书源JS] 执行失败: ${_brief(jsStr)} → ${result.stringResult}');
        return '';
      }
      lastError = null;
      var s = result.stringResult;
      if (s == 'null' || s == 'undefined' || s.isEmpty) return '';
      // 整数结果带 .0（QuickJS 按 double 返回）时规整，避免 URL 拼接出错。
      if (s.length > 2 && RegExp(r'^-?\d+\.0+$').hasMatch(s)) {
        s = s.substring(0, s.indexOf('.'));
      }
      return s;
    } catch (e) {
      AppLog.instance.w('[书源JS] 执行异常: ${_brief(jsStr)} → $e');
      return '';
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
