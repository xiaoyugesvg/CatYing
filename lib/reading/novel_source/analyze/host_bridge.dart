/// legado 宿主调用桥（对应参考实现 `contradiction123/legado-flutter` 的
/// `_callBridge(op, args)` + `_engine.onMessage('java.xxx', ...)` 机制）。
///
/// ── 为什么要它 ───────────────────────────────────────────────
/// 实测 224 条内置书源里的 **475 次 `java.*` 调用 / 33 种方法**，其中
/// 第一名是 `java.getString`（**122 次 / 26 条源**）、`java.get`(52)、
/// `java.put`(28)、`java.getElements`(9)、`java.getElement`(7)、
/// `java.md5Encode`(6)、`java.createSymmetricCrypto`(6)、`java.toNumChapter`(9)、
/// `java.t2s/s2t`(9)、`java.encodeURI`(5)、`java.bytesToStr`(3)…
/// 这些**必须在 Dart 侧求值**（它们要对当前内容跑规则、或用到 Dart 的编解码/加密实现），
/// 而 JS 沙箱里没有这些能力。
///
/// ── 怎么做（与 `sync_http_bridge.dart` 同一套"重放"协议）─────────
/// 1. 宿主在每次 eval 前注入 `var hostCache = {...}`（key → 结果）；
/// 2. JS 侧 `java.xxx(...)` → `_call('xxx', [args])` → 先查 hostCache；
/// 3. 未命中 → `throw new Error('__LEGADO_CALL__' + JSON.stringify({k,o,a}))`；
/// 4. 本文件从 `JsEngine.lastError` 解析出调用 → `AnalyzeRule` 分发执行
///    （见 `analyze_rule.dart` 的 `_dispatchHostCall`）→ 写入 cache → **重新 eval**。
///
/// 选"抛标记 + 重跑"而不是参考实现的异步 `onMessage`：因为本引擎的规则求值是
/// **同步**的（`AnalyzeRule.getString` → `_executeRule` → `_evalJs`），
/// 异步回调无法在同步调用栈里把结果还回去。
///
/// ⚠️ 代价（与 `sync_http_bridge.dart` 相同）：**每轮只处理一个未命中调用**，
/// 因此含 N 个宿主调用的脚本最多需要 N+1 轮 eval。已按 `op + 参数` 缓存，
/// 重复调用不会重复执行。
library;

import 'dart:convert';

/// JS 侧标记前缀（与 `legado_java_prelude.dart` 里的字符串必须完全一致）。
const String kLegadoCallPrefix = '__LEGADO_CALL__';

/// 一次待执行的宿主调用（由 JS 通过标记抛出，Dart 解析得到）。
class HostCall {
  const HostCall({required this.key, required this.op, required this.args});

  /// 缓存键（JS 侧构造：`op + '|' + JSON(参数)`，Dart 原样使用）
  final String key;

  /// 方法名，如 `getString` / `get` / `md5Encode` / `source.getVariable`
  final String op;

  /// 参数列表（JSON 解码后的原始值）
  final List<Object?> args;

  /// 第一个参数（取字符串形式，缺失时为空串）
  String get arg0 => args.isEmpty || args[0] == null ? '' : '${args[0]}';

  /// 第 [i] 个参数（缺失返回 null）
  Object? arg(int i) => i < args.length ? args[i] : null;

  @override
  String toString() => 'HostCall($op, $args)';
}

/// 宿主调用桥（进程级单例）。
class HostBridge {
  HostBridge._();
  static final HostBridge instance = HostBridge._();

  /// 注入给 JS 的缓存对象：key → 结果，或 `{'__error': msg}`。
  final Map<String, Object?> cache = <String, Object?>{};

  void clear() => cache.clear();

  /// 从 `JsEngine.lastError` 里解析待执行调用；没有标记时返回 null。
  ///
  /// 协议（JS 侧构造）：`__LEGADO_CALL__{"k":key,"o":op,"a":[args]}`
  static HostCall? pendingCall(String? errorText) {
    if (errorText == null || errorText.isEmpty) return null;
    final i = errorText.indexOf(kLegadoCallPrefix);
    if (i < 0) return null;
    final raw = errorText.substring(i + kLegadoCallPrefix.length).trim();
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    try {
      final m = jsonDecode(raw.substring(start, end + 1));
      if (m is! Map) return null;
      final key = m['k']?.toString() ?? '';
      final op = m['o']?.toString() ?? '';
      if (key.isEmpty || op.isEmpty) return null;
      final a = m['a'];
      return HostCall(
        key: key,
        op: op,
        args: a is List ? List<Object?>.from(a) : const <Object?>[],
      );
    } catch (_) {
      return null;
    }
  }

  /// 未实现方法的可读错误（JS 侧读到 `__error` 会抛出，最终进运行日志）。
  static Map<String, Object?> unsupported(String op) =>
      {'__error': 'java.$op 尚未实现（见 host_bridge.dart 的方法清单）'};

  /// 归一：任何不可 JSON 化的返回值都转成字符串，避免注入 JS 时崩。
  static Object? normalize(Object? v) {
    if (v == null || v is String || v is num || v is bool) return v;
    if (v is List) return v.map(normalize).toList();
    if (v is Map) {
      return v.map((k, val) => MapEntry('$k', normalize(val)));
    }
    return '$v';
  }
}
