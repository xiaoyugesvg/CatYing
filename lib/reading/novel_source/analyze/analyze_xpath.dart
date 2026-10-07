/// XPath 规则解析器（真 XPath）：基于 `xpath_selector` + `xpath_selector_html_parser`
/// （html 包容错解析），支持完整 XPath 1.0 语法——谓词 `[@class='x']`、
/// `[contains()]`、位置 `[1]`、轴 `ancestor::`/`following-sibling::`、
/// `/@attr`、`/text()` 等。对齐原版 cmbok（package:xpath_selector）。
library;

import 'package:html/dom.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:xpath_selector/xpath_selector.dart';
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

class AnalyzeByXPath {
  dynamic content;

  AnalyzeByXPath(this.content);

  HtmlXPath? _xpath;
  bool _tried = false;

  HtmlXPath? _getXpath() {
    if (_tried) return _xpath;
    _tried = true;
    final c = content;
    if (c is HtmlNodeTree) {
      _xpath = HtmlXPath.node(c.element);
    } else if (c is Element) {
      _xpath = HtmlXPath.node(c);
    } else if (c is Document) {
      final root = c.documentElement;
      if (root != null) _xpath = HtmlXPath.node(root);
    } else if (c is String) {
      try {
        _xpath = HtmlXPath.html(c);
      } catch (_) {}
    } else if (c is List && c.isNotEmpty) {
      final first = c.first;
      if (first is HtmlNodeTree) {
        _xpath = HtmlXPath.node(first.element);
      } else if (first is Element) {
        _xpath = HtmlXPath.node(first);
      } else if (first is String) {
        try {
          _xpath = HtmlXPath.html(first);
        } catch (_) {}
      }
    }
    return _xpath;
  }

  /// 查询：剥离结尾 `/text()`（文本用节点 text 取），其余交给 xpath_selector。
  ///
  /// [FIX-XPATH-GROUP] 另兼容 **括号分组 + 位置谓词**：`(//div[@class="book"])[2]//h2`。
  /// 这是标准 XPath 1.0，但 `package:xpath_selector` 不支持这种"先分组再取第 N 个"
  /// 的写法（实测返回空 ⇒ 规则判空 ⇒ 取不到书名）。
  /// 处理办法：先查括号内表达式，取第 N 个节点（XPath 位置谓词是 **1-based**），
  /// 再从这个节点继续查剩余路径。
  XPathResult<Node> _query(HtmlXPath xp, String rule) {
    var r = rule.trim();
    final textMatch = RegExp(r'/text\(\)\s*$').firstMatch(r);
    if (textMatch != null) r = r.substring(0, textMatch.start);

    final direct = _tryQuery(xp, r);
    if (direct != null) return direct;

    // 分组 + 位置谓词
    // [FIX-B03-XPATH-GROUP] 旧实现用整串锚定的**贪婪正则**
    // `^\((.*)\)\s*\[\s*(\d+)\s*\]\s*(.*)$`，两个缺陷：
    //   1) `.*` 会把分组之外的 `)` 一并吞掉：规则
    //      `(//div[@class="book"])[2]//h2 | (//span)[1]` 捕获出
    //      inner='//div[@class="book"])[2]//h2 | (//span' → 子查询必崩 → 静默空；
    //   2) 只认 `[数字]`，`(//ul/li)[last()]` 这类标准写法同样静默判空。
    // 现改为从左扫描做**括号配对**切分，再解析谓词：数字、`last()`、
    // `last()-N` 都能算出下标；算不出的谓词（如 `position()<3` 会选中多个节点）
    // 记一条 WARN，不再静默。
    final group = _splitGroupPosition(r);
    if (group != null) {
      final (inner, predicate, rest) = group;
      final base = _tryQuery(xp, inner);
      if (base != null) {
        final idx = _positionToIndex(predicate, base.nodes.length);
        if (idx == null) {
          AppLog.instance
              .w('[书源XPath] 不支持的分组位置谓词，已跳过回退: [$predicate] rule=$r');
        } else if (idx >= 0 && idx < base.nodes.length) {
          // XPathNode.node 才是真正的 DOM 节点（XPathNode 自身不可直接当 Node 用）
          final raw = base.nodes[idx].node;
          // HtmlXPath 的节点类型就是 package:html 的 Node ⇒ 只可能是 Element/Text
          final Element? el = raw is Element ? raw : null;
          if (el != null) {
            final sub = HtmlXPath.node(el);
            final subRule =
                rest.isEmpty ? '.' : (rest.startsWith('/') ? '.$rest' : rest);
            final got = _tryQuery(sub, subRule);
            if (got != null) return got;
          }
        }
      }
    }
    return XPathResult(const [], const []);
  }

  /// 切出 `(inner)[predicate]rest`；不是该形状返回 null。
  ///
  /// [FIX-B03-XPATH-GROUP] 括号配对扫描（正则无法安全处理嵌套/分组外的括号）。
  (String, String, String)? _splitGroupPosition(String r) {
    if (!r.startsWith('(')) return null;
    var depth = 0;
    var end = -1;
    for (var i = 0; i < r.length; i++) {
      final c = r.codeUnitAt(i);
      if (c == 0x28) {
        depth++;
      } else if (c == 0x29) {
        depth--;
        if (depth == 0) {
          end = i;
          break;
        }
      }
    }
    if (end < 0) return null;
    final after = r.substring(end + 1).trimLeft();
    if (!after.startsWith('[')) return null;
    final close = after.indexOf(']');
    if (close <= 0) return null;
    return (
      r.substring(1, end).trim(),
      after.substring(1, close).trim(),
      after.substring(close + 1).trim(),
    );
  }

  /// 位置谓词 → 0-based 下标；无法映射到单个节点时返回 null（调用方记日志）。
  static int? _positionToIndex(String predicate, int length) {
    final n = int.tryParse(predicate);
    if (n != null) return n - 1;
    if (predicate == 'last()') return length - 1;
    final m = RegExp(r'^last\(\)\s*-\s*(\d+)$').firstMatch(predicate);
    if (m != null) return length - 1 - int.parse(m.group(1)!);
    return null;
  }

  /// 查询一次；**空结果也算失败**（便于上层走"分组回退"），异常同样返回 null。
  XPathResult<Node>? _tryQuery(HtmlXPath xp, String r) {
    if (r.isEmpty) return null;
    try {
      final res = xp.query(r);
      if (res.nodes.isNotEmpty || res.attr != null) return res;
      return null;
    } catch (_) {
      return null;
    }
  }

  String getString(String rule) {
    if (rule.isEmpty) return '';
    final xp = _getXpath();
    if (xp == null) return '';
    final q = _query(xp, rule);
    final attr = q.attr;
    if (attr != null) return attr;
    final node = q.node;
    if (node == null) return '';
    return node.text?.trim() ?? '';
  }

  List<String> getStringList(String rule) {
    if (rule.isEmpty) return [];
    final xp = _getXpath();
    if (xp == null) return [];
    final q = _query(xp, rule);
    final out = <String>[];
    final attrs = q.attrs.where((a) => a != null && a.isNotEmpty).toList();
    if (attrs.isNotEmpty) {
      out.addAll(attrs.cast<String>());
    }
    for (final n in q.nodes) {
      final t = n.text?.trim() ?? '';
      if (t.isNotEmpty) out.add(t);
    }
    return out;
  }

  List<dynamic> getElements(String rule) {
    if (rule.isEmpty) return [];
    final xp = _getXpath();
    if (xp == null) return [];
    final q = _query(xp, rule);
    return q.nodes.cast<dynamic>().toList();
  }

  /// 供 XPath 结果节点继续做相对子查询（返回包装类，可再 getString/...）
  static AnalyzeByXPath of(dynamic node) => AnalyzeByXPath(node);
}
