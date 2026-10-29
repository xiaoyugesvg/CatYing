// lib/services/xbpq/xbpq_cut.dart
//
// XBPQ 截取引擎 —— 对齐 huoyi `native/core/provider_xbpq.go` 的
// `xbpqCutOnce` / `xbpqConcatCut` / `xbpqApplyStepOnce` / `xbpqFinishSegment`
// / `xbpqParseSteps` / `xbpqTrimModifier` / 锚点匹配 / JSON 模式 / Base64。
//
// 支持：`&&` 前后缀截取、`||` 多组备选、`+` 拼接、`Base64`、
//       `[包含/不包含/替换/序号/排序]` 修饰符、JSON 点路径（j: / $ / 纯点路径）。
// 不包含：`p:` / `jsoup:` 选择器（P2 实现，见 xbpq_selector.dart）。

import 'dart:convert';

import 'package:tvbox/services/xbpq/xbpq_selector.dart';
import 'package:tvbox/services/xbpq/xbpq_util.dart';

/// 一个截取步骤：start&&end + 修饰符。
class _Step {
  String start;
  String end;
  final List<String> contains;
  final List<String> notContains;
  final List<(String, String)> replaces;
  final List<String> order;
  int index;

  _Step({
    this.start = '',
    this.end = '',
    List<String>? contains,
    List<String>? notContains,
    List<(String, String)>? replaces,
    List<String>? order,
    this.index = 0,
  })  : contains = contains ?? <String>[],
        notContains = notContains ?? <String>[],
        replaces = replaces ?? <(String, String)>[],
        order = order ?? <String>[];

  _Step copy() => _Step(
        start: start,
        end: end,
        contains: List<String>.of(contains),
        notContains: List<String>.of(notContains),
        replaces: List<(String, String)>.of(replaces),
        order: List<String>.of(order),
        index: index,
      );
}

/// 编译后的锚点：无通配符时用字面串快路径，否则用惰性正则。
class _Anchor {
  final RegExp? re;
  final String literal;
  const _Anchor({this.re, this.literal = ''});
}

class XbpqCut {
  XbpqCut._();

  // ============================================================
  // 主入口
  // ============================================================

  /// 按 pattern 在 source 上截取第一段；多组用 `||` 依次尝试。
  static String cutOnce(String source, String pattern) {
    if (source.isEmpty || pattern.isEmpty) return '';

    if (pattern.startsWith('p:') || pattern.startsWith('jsoup:')) {
      return XbpqSelector.firstString(source, pattern);
    }
    // 二次截取填 "Base64"：整段只解码。
    if (pattern.trim().toLowerCase() == 'base64') {
      return decodeBase64Segment(source);
    }
    // Base64(a&&b)：截取结果再 Base64 解码。
    final wrapper = base64Wrapper(pattern);
    if (wrapper != null) {
      return decodeBase64Segment(cutOnce(source, wrapper));
    }
    final concat = concatCut(source, pattern);
    if (concat.$2 && concat.$1.trim().isNotEmpty) return concat.$1;

    if (isJsonPattern(pattern) && jsonLikely(source)) {
      return jsonStringValue(source, pattern);
    }
    // 不使用 && 的字段值是「指定字符串」（固定标题/线路标题等）。
    if (!isJsonPattern(pattern) &&
        splitUnescaped(pattern, '&&').length == 1 &&
        !pattern.replaceAll(r'\||', '').contains('||')) {
      return unescape(pattern.trim());
    }

    for (final part in splitUnescaped(pattern, '||')) {
      final steps = _parseSteps(part);
      if (steps.isEmpty) continue;
      var segment = source;
      var ok = true;
      for (final step in steps) {
        final r = _applyStepOnce(segment, step);
        segment = r.$1;
        ok = r.$2;
        if (!ok) break;
      }
      if (ok && segment.trim().isNotEmpty) return segment;
    }
    return '';
  }

  /// 处理 `+` 拼接：含 `&&` 的段作为截取指令，不含的段作为字面量。
  static (String, bool) concatCut(String source, String pattern) {
    if (!pattern.contains('+')) return ('', false);
    final segments = splitTopLevelPlus(pattern);
    if (segments == null || segments.length < 2) return ('', false);

    final fromJson = jsonLikely(source);
    var hasCut = false;
    for (final s in segments) {
      if (s.contains('&&') || (fromJson && isJsonPattern(s.trim()))) {
        hasCut = true;
      }
    }
    if (!hasCut) return ('', false);

    final b = StringBuffer();
    for (var s in segments) {
      s = s.trim();
      if (s.isEmpty) continue;
      // 单引号包裹的是字面量段（json 模式拼接约定）。
      if (s.length >= 2 && s.startsWith("'") && s.endsWith("'")) {
        b.write(s.substring(1, s.length - 1));
        continue;
      }
      if (s.contains('&&')) {
        b.write(cutOnce(source, s));
      } else if (fromJson && isJsonPattern(s)) {
        b.write(jsonStringValue(source, s));
      } else {
        b.write(unescape(s));
      }
    }
    return (b.toString(), true);
  }

  /// 应用一个截取步骤（start → end → 修饰符）。
  static (String, bool) _applyStepOnce(String source, _Step step) {
    if (step.start.isEmpty && step.end.isEmpty) return (source, true);
    var rest = source;
    if (step.start.isNotEmpty) {
      final pos = _matchStart(_compileAnchor(step.start), rest);
      if (pos < 0) return ('', false);
      rest = rest.substring(pos);
    }
    if (step.end.isNotEmpty) {
      final index = _matchEnd(_compileAnchor(step.end), rest);
      if (index < 0) return ('', false);
      rest = rest.substring(0, index);
    }
    return (_finishSegment(rest, step), true);
  }

  static String _finishSegment(String segment, _Step step) {
    if (step.index > 0) {
      final matches = splitNumbered(segment);
      if (step.index <= matches.length) segment = matches[step.index - 1];
    }
    for (final word in step.contains) {
      if (!segment.contains(word)) return '';
    }
    for (final word in step.notContains) {
      if (segment.contains(word)) return '';
    }
    for (final pair in step.replaces) {
      segment = segment.replaceAll(pair.$1, pair.$2);
    }
    return segment.trim();
  }

  /// 按换行 / 制表符切分（[含序号:n] 语义的简化实现）。
  static List<String> splitNumbered(String segment) => segment
      .split(RegExp(r'[\n\t]'))
      .where((e) => e.isNotEmpty)
      .toList();

  /// 按「数组」pattern 迭代抽取全部条目（列表层）。
  ///
  /// 与 [cutOnce] 的区别：cutOnce 只要第一段，这里反复消费直到源耗尽。
  /// 对齐 Go `xbpqList`：`||` 逐个备选试，第一个能出条目的备选胜出；
  /// 该备选的 `[排序:..]` 修饰符会重排结果（线路数组常用）。
  static List<String> list(String source, String pattern) {
    if (source.isEmpty || pattern.isEmpty) return const <String>[];
    if (pattern.startsWith('j:') && jsonLikely(source)) {
      return jsonArrayItems(source, pattern);
    }

    final items = <String>[];
    for (final part in splitUnescaped(pattern, '||')) {
      final steps = _parseSteps(part);
      if (steps.isEmpty) continue;
      final first = steps.first;
      var rest = source;
      while (true) {
        final scanned = _applyStepScan(rest, first);
        var segment = scanned.$1;
        final consumed = scanned.$2;
        if (!scanned.$3) break;

        if (steps.length > 1) {
          var ok = true;
          for (final step in steps.skip(1)) {
            final r = _applyStepOnce(segment, step);
            segment = r.$1;
            ok = r.$2;
            if (!ok) {
              segment = '';
              break;
            }
          }
        }
        if (segment.isNotEmpty) items.add(segment);
        if (consumed >= rest.length) break;
        rest = rest.substring(consumed);
      }
      if (items.isNotEmpty) {
        if (first.order.isNotEmpty) return _orderItems(items, first.order);
        break;
      }
    }
    return items;
  }

  /// 对每个 `||` 备选取**第一步**的扫描结果（`跳转播放链接` 候选收集用）。
  ///
  /// 过滤掉含换行或空格的段 —— 那种基本是整片 HTML，不是链接。
  static List<String> scanSegments(String source, String pattern) {
    final out = <String>[];
    for (final part in splitUnescaped(pattern, '||')) {
      final steps = _parseSteps(part);
      if (steps.isEmpty) continue;
      final scanned = _applyStepScan(source, steps.first);
      if (!scanned.$3) continue;
      final segment = scanned.$1;
      if (segment.contains('\n') || segment.contains(' ')) continue;
      out.add(segment);
    }
    return out;
  }

  /// 找第一个 start&&end 段，返回 (段内容, 消费到的绝对偏移, 是否成功)。
  /// start 截不出内容时自动跳到下一个 start 继续。
  static (String, int, bool) _applyStepScan(String source, _Step step) {    if (step.start.isEmpty) return ('', 0, false);
    final startAnchor = _compileAnchor(step.start);
    final endAnchor = _compileAnchor(step.end);
    var offset = 0;
    while (offset <= source.length) {
      final matched = _matchStartFrom(startAnchor, source, offset);
      final contentStart = matched.$1;
      final matchEnd = matched.$2;
      if (matchEnd < 0) return ('', 0, false);

      var body = source.substring(matchEnd);
      var stop = source.length;
      if (step.end.isNotEmpty) {
        final endIndex = _matchEnd(endAnchor, body);
        if (endIndex < 0) {
          offset = contentStart + 1;
          continue;
        }
        body = body.substring(0, endIndex);
        stop = matchEnd + endIndex;
      }
      final segment = _finishSegment(body, step);
      if (segment.isEmpty) {
        offset = contentStart + 1;
        continue;
      }
      return (segment, stop, true);
    }
    return ('', 0, false);
  }

  /// 按 `[排序:a>b>c]` 的关键词优先级稳定重排（插入排序）。
  static List<String> _orderItems(List<String> items, List<String> order) {
    int rank(String item) {
      for (var i = 0; i < order.length; i++) {
        if (item.contains(order[i])) return i;
      }
      return order.length;
    }

    final out = List<String>.of(items);
    for (var i = 1; i < out.length; i++) {
      for (var j = i; j > 0 && rank(out[j]) < rank(out[j - 1]); j--) {
        final tmp = out[j];
        out[j] = out[j - 1];
        out[j - 1] = tmp;
      }
    }
    return out;
  }

  // ============================================================
  // 切分 / 转义
  // ============================================================

  /// 按分隔符切分，但跳过被反斜杠 `\` 转义的分隔符。
  static List<String> splitUnescaped(String s, String sep) {
    if (sep.isEmpty) return [s];
    final out = <String>[];
    final cur = StringBuffer();
    var i = 0;
    while (i < s.length) {
      if (s[i] == '\\' && i + 1 < s.length) {
        cur
          ..write(s[i])
          ..write(s[i + 1]);
        i += 2;
        continue;
      }
      if (s.startsWith(sep, i)) {
        out.add(cur.toString());
        cur.clear();
        i += sep.length;
        continue;
      }
      cur.write(s[i]);
      i++;
    }
    out.add(cur.toString());
    return out;
  }

  static const Set<String> _unescapeChars = {
    '\$', '#', '&', '*', '[', ']', '\\',
  };

  /// 去掉转义：`\$ \# \& \* \[ \] \\` → 原字符。
  static String unescape(String s) {
    if (!s.contains('\\')) return s;
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (s[i] == '\\' && i + 1 < s.length) {
        final n = s[i + 1];
        if (_unescapeChars.contains(n)) {
          b.write(n);
          i++;
          continue;
        }
      }
      b.write(s[i]);
    }
    return b.toString();
  }

  // ============================================================
  // 锚点（start / end 匹配）
  // ============================================================

  static final Map<String, _Anchor> _anchorCache = {};

  static _Anchor _compileAnchor(String pattern) {
    final cached = _anchorCache[pattern];
    if (cached != null) return cached;
    final a = _buildAnchor(pattern);
    _anchorCache[pattern] = a;
    return a;
  }

  static _Anchor _buildAnchor(String pattern) {
    if (!pattern.contains('*') && !pattern.contains('\\')) {
      return _Anchor(literal: pattern);
    }
    final b = StringBuffer();
    var i = 0;
    while (i < pattern.length) {
      final c = pattern[i];
      if (c == '\\' && i + 1 < pattern.length) {
        b.write(RegExp.escape(pattern[i + 1]));
        i += 2;
        continue;
      }
      if (c == '*') {
        b.write('.*?'); // 惰性：一个字段仅一个通配符
        i++;
        continue;
      }
      b.write(RegExp.escape(c));
      i++;
    }
    try {
      return _Anchor(re: RegExp(b.toString(), dotAll: true));
    } catch (_) {
      return _Anchor(literal: unescape(pattern));
    }
  }

  /// 锚点匹配「结束处」的偏移（内容起点）；找不到 -1。
  static int _matchStart(_Anchor a, String source) =>
      _matchStartFrom(a, source, 0).$2;

  static (int, int) _matchStartFrom(_Anchor a, String source, int offset) {
    if (offset > source.length) return (-1, -1);
    final sub = source.substring(offset);
    if (a.literal.isNotEmpty && a.re == null) {
      final index = sub.indexOf(a.literal);
      if (index < 0) return (-1, -1);
      return (offset + index, offset + index + a.literal.length);
    }
    final m = a.re!.firstMatch(sub);
    if (m == null) return (-1, -1);
    return (offset + m.start, offset + m.end);
  }

  /// 锚点匹配「起始处」的偏移；找不到 -1。
  static int _matchEnd(_Anchor a, String source) {
    if (a.literal.isNotEmpty && a.re == null) {
      return source.indexOf(a.literal);
    }
    final m = a.re!.firstMatch(source);
    if (m == null) return -1;
    return m.start;
  }

  // ============================================================
  // 修饰符
  // ============================================================

  static final RegExp _modifierKeyword =
      RegExp(r'^(包含|不包含|替换|序号|含序号|截右|右截|排序)$');

  /// 从 token 尾部剥出 `[修饰符]` 列表，返回剩余字面与修饰符。
  static (String, List<_Step>) _trimModifier(String token) {
    final mods = <_Step>[];
    var work = token;
    while (true) {
      if (!work.endsWith(']')) break;
      var open = _matchBracket(work);
      if (open < 0) break;

      final body = work.substring(open + 1, work.length - 1);
      final colon = _indexOfAny(body, ':：');
      var word = body;
      var payload = '';
      if (colon >= 0) {
        word = body.substring(0, colon);
        payload = body.substring(colon + 1);
      }
      word = word.trim();
      if (!_modifierKeyword.hasMatch(word)) break;

      var mod = mods.isNotEmpty ? mods[0].copy() : _Step();
      switch (word) {
        case '包含':
          mod.contains.addAll(_splitList(payload));
          break;
        case '不包含':
          mod.notContains.addAll(_splitList(payload));
          break;
        case '替换':
          for (final pair in payload.split('#')) {
            final i = pair.indexOf('>>');
            if (i >= 0) {
              mod.replaces.add((pair.substring(0, i), pair.substring(i + 2)));
            }
          }
          break;
        case '序号':
        case '含序号':
          final n = int.tryParse(payload.trim());
          if (n != null && n >= 1) mod.index = n;
          break;
        case '排序':
          for (var item in splitUnescaped(payload, '>')) {
            item = item.trim();
            if (item.isNotEmpty) mod.order.add(item);
          }
          break;
        default:
          mod.index = -1; // [右截] 等未支持项：保留字面，不再剥
          open = -1;
      }
      if (open < 0) break;
      work = work.substring(0, open).trim();
      mods.insert(0, mod);
    }
    return (work, mods);
  }

  /// 从右往左找与末尾 `]` 配对的 `[`（不嵌套，简单取最右）。
  static int _matchBracket(String token) => XbpqUtil.matchBracket(token);

  static int _indexOfAny(String s, String chars) {
    for (var i = 0; i < s.length; i++) {
      if (chars.contains(s[i])) return i;
    }
    return -1;
  }

  static List<String> _splitList(String payload) =>
      XbpqUtil.splitList(payload);

  /// 把 `A&&B&&C&&D` 拆成截取步骤链：`(A,B)`、`(C,D)`。
  static List<_Step> _parseSteps(String pattern) {
    final steps = <_Step>[];
    final parts = splitUnescaped(pattern, '&&');
    if (parts.length == 1) return const []; // 无 && 的单 token 不构成截取指令

    var i = 0;
    while (i < parts.length) {
      final startTrim = _trimModifier(parts[i].trim());
      final startToken = startTrim.$1;
      final startMods = startTrim.$2;

      var end = '';
      var endMods = <_Step>[];
      if (i + 1 < parts.length) {
        final endTrim = _trimModifier(parts[i + 1].trim());
        end = endTrim.$1;
        endMods = endTrim.$2;
      }

      var step = _Step(start: unescape(startToken), end: unescape(end));
      if (startMods.isNotEmpty) {
        step = startMods[0]
          ..start = unescape(startToken)
          ..end = unescape(end);
        if (endMods.isNotEmpty) {
          step.contains.addAll(endMods[0].contains);
          step.notContains.addAll(endMods[0].notContains);
          step.replaces.addAll(endMods[0].replaces);
          step.order.addAll(endMods[0].order);
          if (endMods[0].index != 0 && step.index == 0) {
            step.index = endMods[0].index;
          }
        }
      } else if (endMods.isNotEmpty) {
        step = endMods[0]
          ..start = unescape(startToken)
          ..end = unescape(end);
      }
      steps.add(step);
      i += 2;
    }
    return steps;
  }

  /// 按 `+` 切分，跳过 `[修饰符]` 内部与被转义的 `+`。
  /// 返回 null 表示没有可切分的顶层 `+`。
  static List<String>? splitTopLevelPlus(String pattern) {
    final out = <String>[];
    final cur = StringBuffer();
    var depth = 0;
    var hasPlus = false;
    var i = 0;
    while (i < pattern.length) {
      if (pattern[i] == '\\' && i + 1 < pattern.length) {
        cur
          ..write(pattern[i])
          ..write(pattern[i + 1]);
        i += 2;
        continue;
      }
      final c = pattern[i];
      if (c == '[') {
        depth++;
      } else if (c == ']') {
        if (depth > 0) depth--;
      } else if (c == '+') {
        if (depth == 0) {
          out.add(cur.toString());
          cur.clear();
          hasPlus = true;
          i++;
          continue;
        }
      }
      cur.write(c);
      i++;
    }
    if (!hasPlus) return null;
    out.add(cur.toString());
    return out;
  }

  // ============================================================
  // JSON 模式
  // ============================================================

  /// source 是否 JSON 文档（首个非空白字符是 `{` 或 `[`）。
  static bool jsonLikely(String source) {
    for (final r in source.runes) {
      if (r == 0x20 || r == 0x0A || r == 0x0D || r == 0x09) continue;
      return r == 0x7B || r == 0x5B;
    }
    return false;
  }

  /// pattern 是否 json 模式（`j:` 前缀、`$` 前缀，或纯点路径）。
  static bool isJsonPattern(String pattern) {
    if (pattern.isEmpty) return false;
    if (pattern.startsWith('j:') || pattern.startsWith(r'$')) return true;
    if (pattern.contains('&') ||
        pattern.contains('"') ||
        pattern.contains("'") ||
        pattern.contains(' ') ||
        pattern.contains('://')) {
      return false;
    }
    if (!pattern.contains('.')) return false;
    for (final r in pattern.runes) {
      if (r == 0x5B || r == 0x5D) continue; // [ ]
      final ok = r == 0x5F ||
          r == 0x2E ||
          (r >= 0x61 && r <= 0x7A) ||
          (r >= 0x41 && r <= 0x5A) ||
          (r >= 0x30 && r <= 0x39);
      if (!ok) return false;
    }
    return true;
  }

  static String jsonStringValue(String source, String path) {
    final value = jsonPathValue(source, path);
    if (!value.$2) return '';
    return XbpqUtil.stringValue(value.$1);
  }

  /// 路径取到的对象/数组序列化回 JSON 文本（二次截取缩小范围用）。
  static String jsonPathRaw(String source, String path) {
    final value = jsonPathValue(source, path);
    if (!value.$2 || value.$1 == null) return '';
    final node = value.$1;
    if (node is String) return node;
    if (node is Map || node is List) {
      try {
        return jsonEncode(node);
      } catch (_) {
        return '';
      }
    }
    return XbpqUtil.stringValue(node);
  }

  /// 路径迭代：数组逐元素序列化；对象返回单条。
  static List<String> jsonArrayItems(String source, String path) {
    final value = jsonPathValue(source, path);
    if (!value.$2) return const <String>[];
    final node = value.$1;
    if (node is! List) {
      try {
        return [jsonEncode(node)];
      } catch (_) {
        return const <String>[];
      }
    }
    final out = <String>[];
    for (final one in node) {
      try {
        out.add(jsonEncode(one));
      } catch (_) {
        continue;
      }
    }
    return out;
  }

  /// 按 json 点路径从 JSON 文本取值。
  static (dynamic, bool) jsonPathValue(String source, String path) {
    path = path.trim();
    if (path.startsWith(r'$')) path = path.substring(1);
    if (path.startsWith('j:')) path = path.substring(2);
    if (source.isEmpty || path.isEmpty) return (null, false);

    dynamic root;
    try {
      root = jsonDecode(source);
    } catch (_) {
      return (null, false);
    }

    dynamic cur = root;
    for (final rawSeg in path.split('.')) {
      final seg = _jsonCutSegment(rawSeg);
      final key = seg.$1;
      final idxText = seg.$2;
      final hasIndex = seg.$3;

      if (key.isNotEmpty) {
        if (cur is Map) {
          final found = _jsonLookupFold(cur, key);
          if (!found.$2) return (null, false);
          cur = found.$1;
        } else if (cur is List) {
          final picked = <dynamic>[];
          for (final one in cur) {
            if (one is Map) {
              final f = _jsonLookupFold(one, key);
              if (f.$2) picked.add(f.$1);
            }
          }
          if (picked.isEmpty) continue;
          cur = picked;
          continue;
        } else {
          return (null, false);
        }
      }
      if (hasIndex) cur = _jsonApplyIndex(cur, idxText);
    }
    return (cur, true);
  }

  static (String, String, bool) _jsonCutSegment(String seg) {
    final open = seg.indexOf('[');
    if (open < 0) return (seg, '', false);
    final key = seg.substring(0, open);
    final close = seg.lastIndexOf(']');
    if (close <= open) return (seg, '', false);
    return (key, seg.substring(open + 1, close), true);
  }

  static (dynamic, bool) _jsonLookupFold(Map obj, String key) {
    if (obj.containsKey(key)) return (obj[key], true);
    final lower = key.toLowerCase();
    for (final k in obj.keys) {
      if (k.toString().toLowerCase() == lower) return (obj[k], true);
    }
    return (null, false);
  }

  /// 对数组应用下标/切片（0-based）：
  /// `""`/`*`→全部；`n`→第 n 个；`a,`→自 a 起；`a-b`/`a:b`→[a,b)。
  static dynamic _jsonApplyIndex(dynamic value, String expr) {
    if (value is! List) return value;
    final arr = value;
    expr = expr.trim();
    if (expr.isEmpty || expr == '*') return arr;

    final single = int.tryParse(expr);
    if (single != null) {
      var n = single;
      if (n < 0) n += arr.length;
      if (n < 0 || n >= arr.length) return null;
      return arr[n];
    }

    final i = expr.indexOf(RegExp(r'[-:,]'));
    if (i >= 0) {
      final left = expr.substring(0, i).trim();
      final right = expr.substring(i + 1).trim();
      var start = 0;
      var end = arr.length;
      if (left.isNotEmpty) {
        final n = int.tryParse(left);
        if (n != null) start = _clamp(n, 0, arr.length);
      }
      if (right.isNotEmpty) {
        final n = int.tryParse(right);
        if (n != null) end = _clamp(n, 0, arr.length);
      }
      if (start >= end) return <dynamic>[];
      return arr.sublist(start, end);
    }
    return arr;
  }

  static int _clamp(int n, int lo, int hi) {
    if (n < lo) return lo;
    if (n > hi) return hi;
    return n;
  }

  // ============================================================
  // Base64
  // ============================================================

  /// Base64 解码（失败返回原串）。
  static String decodeBase64Segment(String s) {
    s = s.trim();
    if (s.isEmpty) return s;
    try {
      final bytes = base64.decode(base64.normalize(s));
      final str = utf8.decode(bytes, allowMalformed: true);
      if (!str.contains('\u0000')) return str;
    } catch (_) {
      // 落到返回原串
    }
    return s;
  }

  /// 识别 `Base64(inner)` 形态。
  static String? base64Wrapper(String pattern) {
    final p = pattern.trim();
    if (!p.toLowerCase().startsWith('base64(') || !p.endsWith(')')) return null;
    return p.substring('Base64('.length, p.length - 1);
  }
}
