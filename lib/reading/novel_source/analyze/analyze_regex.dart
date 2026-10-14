/// 正则规则解析器：从内容中按正则提取字符串/元素列表。
library;

import 'package:flutter/foundation.dart';

class AnalyzeByRegex {
  static String getString(String content, String rule) {
    if (rule.isEmpty || content.isEmpty) return '';
    if (_isRiskyNesting(rule)) {
      _warnRisky('getString', rule);
      return '';
    }
    try {
      final regex = RegExp(rule, dotAll: true);
      final match = regex.firstMatch(content);
      if (match != null) {
        if (match.groupCount > 0) {
          return match.group(1) ?? match.group(0) ?? '';
        }
        return match.group(0) ?? '';
      }
    } catch (_) {}
    return '';
  }

  static List<String> getStringList(String content, String rule) {
    if (rule.isEmpty || content.isEmpty) return [];
    if (_isRiskyNesting(rule)) {
      _warnRisky('getStringList', rule);
      return [];
    }
    final results = <String>[];
    try {
      final regex = RegExp(rule, dotAll: true);
      for (final match in regex.allMatches(content)) {
        if (match.groupCount > 0) {
          final group = match.group(1);
          if (group != null && group.isNotEmpty) {
            results.add(group);
          }
        } else {
          final group = match.group(0);
          if (group != null && group.isNotEmpty) {
            results.add(group);
          }
        }
      }
    } catch (_) {}
    return results;
  }

  static String? getElement(String content, String rule) {
    final rules = rule.split('&&').where((r) => r.trim().isNotEmpty).toList();
    final sList = _getElementsByRules(content, rules);
    return sList.isEmpty ? null : sList.first;
  }

  static List<String> getElements(String content, String rule) {
    final rules = rule.split('&&').where((r) => r.trim().isNotEmpty).toList();
    return _getElementsByRules(content, rules);
  }

  static List<String> _getElementsByRules(String content, List<String> rules) {
    final resultList = <String>[];
    for (final r in rules) {
      if (_isRiskyNesting(r)) {
        _warnRisky('getElements', r);
        continue;
      }
      try {
        final regex = RegExp(r, dotAll: true);
        for (final match in regex.allMatches(content)) {
          for (int i = 0; i <= match.groupCount; i++) {
            final group = match.group(i);
            if (group != null) {
              resultList.add(group);
            }
          }
        }
      } catch (_) {}
    }
    return resultList;
  }

  // ── ReDoS 静态防护（洞 S，2026-10-14）─────────────────────────
  //
  // 问题：`RegExp(rule)` 是**同步**的，Dart 既没有超时也没有中断手段；
  //   一条 `(a+)+` 形态的规则配上稍长的正文（正文常有几十万字符），回溯次数
  //   指数爆炸 ⇒ 整条求值链卡死。worker isolate 的 60s 硬超时只能在
  //   **worker** 里兜底；而本类也会被主 isolate 路径调用（无超时、直接把
  //   UI 卡成 ANR）。
  //
  // 做法：执行前静态扫描，只拦「**分组内已含量词，且该分组本身又被量词修饰**」
  //   这一个明确的 ReDoS 特征（`(a+)+`、`(\d+)*`、`(?:.+)+`、`((a|b)+)+`…），
  //   命中则**拒绝执行**（返回空 + 留日志），而不是靠超时。
  // 刻意的保守取舍：`(a|b)+`、`(\d+)?` 这类**不拦**（它们不是指数回溯），
  //   以免误伤正常规则 —— 宁可少拦，也不把能用的源弄坏。
  static bool _isRiskyNesting(String rule) {
    final stack = <bool>[]; // 每层分组：组内是否出现过「量词」
    var inClass = false; // 是否在字符类 `[...]` 内（其中的 * + 是字面量）
    for (var i = 0; i < rule.length; i++) {
      final c = rule.codeUnitAt(i);
      if (c == 0x5C) {
        i++; // `\x` 转义：跳过被转义字符
        continue;
      }
      if (inClass) {
        if (c == 0x5D) inClass = false; // ']'
        continue;
      }
      if (c == 0x5B) {
        inClass = true; // '['
        continue;
      }
      if (c == 0x28) {
        stack.add(false); // '('
        continue;
      }
      if (c == 0x29) {
        // ')'
        if (stack.isEmpty) continue;
        final inner = stack.removeLast();
        final q = _quantifierLengthAt(rule, i + 1);
        // 组内含量词 + 组整体又被量词修饰 ⇒ 嵌套量词 ⇒ 指数回溯
        if (q > 0 && inner) return true;
        // 该组整体被量词修饰，对父层而言等同于「内含量词」
        if (stack.isNotEmpty && (inner || q > 0)) {
          stack[stack.length - 1] = true;
        }
        i += q;
        continue;
      }
      if (c == 0x2B || c == 0x2A) {
        // '+' '*'
        if (stack.isNotEmpty) stack[stack.length - 1] = true;
        continue;
      }
      if (c == 0x7B) {
        // '{'
        if (_braceQuantifierLength(rule, i) > 0 && stack.isNotEmpty) {
          stack[stack.length - 1] = true;
        }
        continue;
      }
    }
    return false;
  }

  /// [i] 处是否为量词（`+`/`*`/`{n,m}`）；是则返回其长度，否则 0。
  /// `?` 不单独算量词（`(a+)?` 最多重复一次，不构成 ReDoS）。
  static int _quantifierLengthAt(String rule, int i) {
    if (i >= rule.length) return 0;
    final c = rule.codeUnitAt(i);
    if (c == 0x2B || c == 0x2A) return 1; // '+' '*'
    if (c == 0x7B) return _braceQuantifierLength(rule, i); // '{n,m}'
    return 0;
  }

  /// `rule[i]` 为 `{` 且形如 `{n}` / `{n,}` / `{n,m}` 时返回整段长度，否则 0。
  static int _braceQuantifierLength(String rule, int i) {
    final end = rule.indexOf('}', i + 1);
    if (end < 0) return 0;
    final body = rule.substring(i + 1, end);
    if (!RegExp(r'^\d+(,\d*)?$').hasMatch(body)) return 0;
    return end - i + 1;
  }

  static void _warnRisky(String where, String rule) {
    debugPrint('[AnalyzeByRegex] 跳过有 ReDoS 风险的规则（$where）: '
        '${rule.length > 120 ? "${rule.substring(0, 120)}..." : rule}');
  }
}
