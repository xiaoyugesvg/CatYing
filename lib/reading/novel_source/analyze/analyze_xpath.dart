/// XPath 规则解析器（真 XPath）：基于 `xpath_selector` + `xpath_selector_html_parser`
/// （html 包容错解析），支持完整 XPath 1.0 语法——谓词 `[@class='x']`、
/// `[contains()]`、位置 `[1]`、轴 `ancestor::`/`following-sibling::`、
/// `/@attr`、`/text()` 等。对齐原版 cmbok（package:xpath_selector）。
library;

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
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
  XPathResult<Node> _query(HtmlXPath xp, String rule) {
    var r = rule.trim();
    final textMatch = RegExp(r'/text\(\)\s*$').firstMatch(r);
    if (textMatch != null) r = r.substring(0, textMatch.start);
    try {
      return xp.query(r);
    } catch (_) {
      return XPathResult(const [], const []);
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
    final attrs = q.attrs.where((a) => a != null && a!.isNotEmpty).toList();
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
