/// JSON 规则解析器：支持 `$.a.b`、`$["key"]`、`$[index]`、`$.a[*].b`（通配后
/// 接字段）、`$..x`（深度扫描）等 JSONPath 风格取值（对齐 jayway JsonPath 在
/// 书源中的常用子集）。
library;

import 'dart:convert';

class AnalyzeByJson {
  dynamic content;

  AnalyzeByJson(this.content);

  dynamic get _jsonData {
    if (content is String) {
      try {
        return json.decode(content as String);
      } catch (_) {
        return null;
      }
    }
    return content;
  }

  String getString(String rule) {
    if (rule.isEmpty) return '';
    // 字段级复合规则（`$.title||$.name` 这类取反规则）同样要拆开求值
    if (_splitComposite(rule).length > 1) return getStringList(rule).join('\n');
    final result = _resolvePath(rule);
    if (result == null) return '';
    if (result is List) {
      return result.map((e) => e.toString()).join('\n');
    }
    return result.toString();
  }

  List<String> getStringList(String rule) {
    if (rule.isEmpty) return [];
    final parts = _splitComposite(rule);
    if (parts.length > 1) {
      final out = <String>[];
      for (final part in parts) {
        if (part.prevOp == '||' && out.isNotEmpty) break;
        out.addAll(getStringList(part.path));
      }
      return out;
    }
    final result = _resolvePath(rule);
    if (result == null) return [];
    if (result is List) {
      return result.map((e) => e.toString()).toList();
    }
    return [result.toString()];
  }

  List<dynamic> getList(String rule) {
    if (rule.isEmpty) return [];
    // `&&` / `||` / `%%` 复合规则：JSON 列表规则里非常常见
    // （例：`$.blocks..models[*]&&$.models[*]` —— Strip 直播这类源）。
    // 以前整串被当成一条 JSONPath ⇒ 末尾 `&&$.…` 被解析成一个"键" ⇒ 0 条结果，
    // 表现正是「没抓到文章」。
    final parts = _splitComposite(rule);
    if (parts.length <= 1) {
      final result = _resolvePath(rule);
      if (result == null) return [];
      if (result is List) return result;
      return [result];
    }
    final out = <dynamic>[];
    final seen = <dynamic>{}; // 按对象身份去重（同一 model 被两条路径命中时只留一份）
    for (final part in parts) {
      // `||`：前面的规则已经取到东西 ⇒ 不再试后面的（Legado 语义）
      if (part.prevOp == '||' && out.isNotEmpty) break;
      final result = _resolvePath(part.path);
      if (result == null) continue;
      final list = result is List ? result : [result];
      for (final e in list) {
        if (seen.add(e)) out.add(e);
      }
    }
    return out;
  }

  /// 顶层 `&&` / `||` / `%%` 切分（跳过引号与 [] () 内的运算符）。
  ///
  /// 返回每段的 `path` 与它**前面**的那个运算符（第一段为空串）。
  static List<({String path, String prevOp})> _splitComposite(String rule) {
    final out = <({String path, String prevOp})>[];
    var depth = 0;
    var quote = false;
    var quoteChar = '';
    var last = 0;
    var op = '';
    for (var i = 0; i < rule.length; i++) {
      final c = rule[i];
      if (quote) {
        if (c == quoteChar) quote = false;
        continue;
      }
      if (c == "'" || c == '"') {
        quote = true;
        quoteChar = c;
        continue;
      }
      if (c == '(' || c == '[') {
        depth++;
        continue;
      }
      if (c == ')' || c == ']') {
        depth--;
        continue;
      }
      if (depth != 0 || i + 1 >= rule.length) continue;
      String? found;
      if (c == '&' && rule[i + 1] == '&') {
        found = '&&';
      } else if (c == '|' && rule[i + 1] == '|') {
        found = '||';
      } else if (c == '%' && rule[i + 1] == '%') {
        found = '%%';
      }
      if (found == null) continue;
      final p = rule.substring(last, i).trim();
      if (p.isNotEmpty) out.add((path: p, prevOp: op));
      op = found;
      i += 1;
      last = i + 1;
    }
    final tail = rule.substring(last).trim();
    if (tail.isNotEmpty) out.add((path: tail, prevOp: op));
    return out;
  }

  dynamic getObject(String rule) {
    if (rule.isEmpty) return null;
    return _resolvePath(rule);
  }

  dynamic _resolvePath(String path) {
    final data = _jsonData;
    if (data == null) return null;

    final tokens = _tokenize(path);
    if (tokens.isEmpty) return data;
    return _navigate(data, tokens);
  }

  /// 路径分词：`.field`、`['key']`、`["key"]`、`[index]`、`[*]`、`..`（深扫）。
  static List<_JsonPathToken> _tokenize(String path) {
    final tokens = <_JsonPathToken>[];
    var i = 0;
    final s = path;

    while (i < s.length) {
      final c = s[i];
      if (c == r'$') {
        i += 1;
      } else if (c == '.') {
        if (i + 1 < s.length && s[i + 1] == '.') {
          tokens.add(const _JsonPathToken(_JsonTokenType.deepScan, ''));
          i += 2;
        } else {
          i += 1;
        }
      } else if (c == '[') {
        final end = _findBracketEnd(s, i);
        if (end < 0) break;
        final inner = s.substring(i + 1, end).trim();
        if (inner.startsWith('?(')) {
          final expr = _extractFilterExpr(inner);
          if (expr != null) {
            tokens.add(_JsonPathToken(_JsonTokenType.filter, expr));
          } else {
            break;
          }
        } else if (inner == '*' || inner.isEmpty) {
          tokens.add(const _JsonPathToken(_JsonTokenType.wildcard, ''));
        } else if ((inner.startsWith("'") && inner.endsWith("'")) ||
            (inner.startsWith('"') && inner.endsWith('"'))) {
          tokens.add(_JsonPathToken(
              _JsonTokenType.key, inner.substring(1, inner.length - 1)));
        } else {
          final idx = int.tryParse(inner);
          if (idx != null) {
            tokens.add(_JsonPathToken(_JsonTokenType.arrayIndex, inner));
          } else {
            tokens.add(_JsonPathToken(_JsonTokenType.key, inner));
          }
        }
        i = end + 1;
      } else if (c == '@' || c == ',') {
        // 未成对的过滤器表达式等不支持的语法：终止分词，按已知前缀求值。
        break;
      } else {
        var j = i;
        while (j < s.length && s[j] != '.' && s[j] != '[') {
          j += 1;
        }
        tokens.add(_JsonPathToken(_JsonTokenType.key, s.substring(i, j)));
        i = j;
      }
    }
    return tokens;
  }

  /// 括号闭合位置（跳过引号内的 `]`）。
  static int _findBracketEnd(String s, int start) {
    var quote = false;
    var quoteChar = '';
    for (var i = start + 1; i < s.length; i++) {
      final c = s[i];
      if (quote) {
        if (c == quoteChar) quote = false;
      } else if (c == "'" || c == '"') {
        quote = true;
        quoteChar = c;
      } else if (c == ']') {
        return i;
      }
    }
    return -1;
  }

  /// 提取过滤器表达式：`[?(@.a==1 && @.b=='x')]` 的 inner 为 `?(@.a==1 && ...)`，
  /// 去掉 `?(...)` 外壳返回内部表达式；括号不配对返回 null。
  static String? _extractFilterExpr(String inner) {
    var depth = 0;
    var quote = false;
    var quoteChar = '';
    for (var i = 0; i < inner.length; i++) {
      final c = inner[i];
      if (quote) {
        if (c == quoteChar) quote = false;
      } else if (c == "'" || c == '"') {
        quote = true;
        quoteChar = c;
      } else if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
        if (depth == 0) {
          final expr = inner.substring(2, i).trim();
          return expr.isEmpty ? null : expr;
        }
      }
    }
    return null;
  }

  /// 逐 token 导航：通配符把当前节点集合展开为全部子元素，后续 token 逐个
  /// 作用于每个元素（`$.rows[*].name` → 所有 rows 元素的 name 列表）。
  dynamic _navigate(dynamic root, List<_JsonPathToken> tokens) {
    var current = <dynamic>[root];
    for (final token in tokens) {
      final next = <dynamic>[];
      for (final node in current) {
        switch (token.type) {
          case _JsonTokenType.key:
            _applyKey(node, token.name, next);
          case _JsonTokenType.arrayIndex:
            if (node is List) {
              final idx = int.tryParse(token.name) ?? -1;
              if (idx >= 0 && idx < node.length) next.add(node[idx]);
            }
          case _JsonTokenType.wildcard:
            if (node is List) {
              next.addAll(node);
            } else if (node is Map) {
              next.addAll(node.values);
            }
          case _JsonTokenType.deepScan:
            _collectAll(node, next);
          case _JsonTokenType.filter:
            if (node is List) {
              for (final item in node) {
                if (_evalFilter(item, token.name)) next.add(item);
              }
            } else if (node is Map) {
              if (_evalFilter(node, token.name)) next.add(node);
            }
        }
      }
      current = next;
    }
    if (current.isEmpty) return null;
    if (current.length == 1) return current.first;
    return current;
  }

  static void _applyKey(dynamic node, String name, List<dynamic> out) {
    if (node is Map) {
      // 不含该键时不追加 null（深度扫描 `$..field` 会遍历大量无关 Map，
      // 追加 null 会把结果污染成 [null, 值, null, ...]）。
      if (node.containsKey(name)) {
        out.add(node[name]);
      }
    } else if (node is List) {
      // 纯数字键作用在数组上等于下标（`$.items.0`）。
      final idx = int.tryParse(name);
      if (idx != null && idx >= 0 && idx < node.length) {
        out.add(node[idx]);
      }
    }
  }

  /// 深度扫描：收集自身与全部后代节点（`$..field` 语义：任意层级的 field）。
  static void _collectAll(dynamic node, List<dynamic> out) {
    out.add(node);
    if (node is Map) {
      for (final v in node.values) {
        _collectAll(v, out);
      }
    } else if (node is List) {
      for (final v in node) {
        _collectAll(v, out);
      }
    }
  }

  /// 过滤器求值（jayway 常用子集）：`@.a=='x'`、`@['a']!=1`、`@.a>10 && @.b`、
  /// `@.a =~ /regex/i`、`!@.a`，支持 `&&`/`||` 连接。
  static bool _evalFilter(dynamic node, String expr) {
    final parts = _splitTopLevel(expr);
    if (parts.isEmpty) return false;
    var result = false;
    var hasValue = false;
    for (final part in parts) {
      final seg = part.trim();
      final isOr = seg.startsWith('||');
      final isAnd = seg.startsWith('&&');
      final trimmed = seg.replaceFirst(RegExp(r'^(&&|\|\|)'), '').trim();
      final v = _evalFilterAtom(node, trimmed);
      if (!hasValue) {
        result = v;
        hasValue = true;
      } else if (isOr) {
        result = result || v;
      } else if (isAnd) {
        result = result && v;
      } else {
        // 无连接符的多个条件（理论不出现）：取最后一个
        result = v;
      }
    }
    return result;
  }

  /// 顶层按 `&&`/`||` 切分（跳过引号与括号内）。
  static List<String> _splitTopLevel(String expr) {
    final out = <String>[];
    var depth = 0;
    var quote = false;
    var quoteChar = '';
    var last = 0;
    for (var i = 0; i < expr.length; i++) {
      final c = expr[i];
      if (quote) {
        if (c == quoteChar) quote = false;
        continue;
      }
      if (c == "'" || c == '"') {
        quote = true;
        quoteChar = c;
        continue;
      }
      if (c == '(' || c == '[') {
        depth++;
        continue;
      }
      if (c == ')' || c == ']') {
        depth--;
        continue;
      }
      if (depth == 0 &&
          i + 1 < expr.length &&
          ((c == '&' && expr[i + 1] == '&') ||
              (c == '|' && expr[i + 1] == '|'))) {
        out.add(expr.substring(last, i));
        i += 1;
        last = i + 1;
      }
    }
    if (last < expr.length) out.add(expr.substring(last));
    return out;
  }

  /// 单条件求值：`!` 取反；比较式（== != > < >= <= =~）；存在性。
  static bool _evalFilterAtom(dynamic node, String expr) {
    final e = expr.trim();
    if (e.isEmpty) return false;
    if (e.startsWith('!')) {
      return !_evalFilterAtom(node, e.substring(1).trim());
    }
    // 正则 =~
    final reMatch = RegExp(r'^(.+?)\s*=\~\s*/([^/]*)/(i?)\s*$').firstMatch(e);
    if (reMatch != null) {
      final lhs = _filterValue(node, reMatch.group(1)!.trim());
      if (lhs == null) return false;
      final re = RegExp(reMatch.group(2)!, caseSensitive: reMatch.group(3) != 'i');
      return re.hasMatch(lhs.toString());
    }
    final opMatch = RegExp(r'^(.+?)\s*(==|!=|>=|<=|>|<)\s*(.+?)$').firstMatch(e);
    if (opMatch != null) {
      final lhs = _filterValue(node, opMatch.group(1)!.trim());
      final rhs = _parseLiteral(opMatch.group(3)!.trim());
      final op = opMatch.group(2)!;
      if (lhs == null || rhs == null) return false;
      switch (op) {
        case '==':
          return lhs.toString() == rhs.toString();
        case '!=':
          return lhs.toString() != rhs.toString();
        case '>':
          return _toNum(lhs) > _toNum(rhs);
        case '<':
          return _toNum(lhs) < _toNum(rhs);
        case '>=':
          return _toNum(lhs) >= _toNum(rhs);
        case '<=':
          return _toNum(lhs) <= _toNum(rhs);
      }
      return false;
    }
    // 存在性：@.field / @['field'] 有值即真
    final v = _filterValue(node, e);
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0;
    return v.toString().isNotEmpty;
  }

  /// 取过滤器表达式左侧值：`@.a.b`、`@['a']`、`@`（整体）、字面量。
  static dynamic _filterValue(dynamic node, String ref) {
    final r = ref.trim();
    if (r == '@') return node;
    if (!r.startsWith('@')) {
      // 字面量（右侧恒等式）
      return _parseLiteral(r);
    }
    var path = r.substring(1).trim();
    if (path.startsWith('.')) path = path.substring(1);
    dynamic cur = node;
    if (path.isEmpty) return cur;
    // 支持裸字段（@.type 剥点后剩 type）、.field、['k']、["k"]、[index]
    final re = RegExp(
        r'''([\w$]+)|\.([\w$]+)|\[\s*'([^']*)'\s*\]|\[\s*"([^"]*)"\s*\]|\[(\d+)\]''');
    var last = 0;
    for (final m in re.allMatches(path)) {
      final seg = m.group(1) ??
          m.group(2) ??
          m.group(3) ??
          m.group(4) ??
          m.group(5);
      if (seg == null) return null;
      if (cur is Map && cur.containsKey(seg)) {
        cur = cur[seg];
      } else if (cur is List) {
        final idx = int.tryParse(seg);
        if (idx != null && idx >= 0 && idx < cur.length) {
          cur = cur[idx];
        } else {
          return null;
        }
      } else {
        return null;
      }
      last = m.end;
    }
    if (last < path.length) return null;
    return cur;
  }

  static dynamic _parseLiteral(String s) {
    if (s == 'null') return null;
    if (s == 'true') return true;
    if (s == 'false') return false;
    if (s.length >= 2 &&
        ((s.startsWith("'") && s.endsWith("'")) ||
            (s.startsWith('"') && s.endsWith('"')))) {
      return s.substring(1, s.length - 1);
    }
    return num.tryParse(s);
  }

  static num _toNum(dynamic v) {
    if (v is num) return v;
    return num.tryParse(v.toString()) ?? 0;
  }
}

enum _JsonTokenType { key, arrayIndex, wildcard, deepScan, filter }

class _JsonPathToken {
  final _JsonTokenType type;
  final String name;

  const _JsonPathToken(this.type, this.name);
}
