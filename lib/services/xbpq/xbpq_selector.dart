// lib/services/xbpq/xbpq_selector.dart
//
// `p:` / `jsoup:` 选择器子集 —— 对齐 huoyi `provider_xbpq.go` 的
// `xbpqParseSelector` / `xbpqParseSelectorPart` / `xbpqPartMatches` /
// `xbpqNodeHasAncestorChain` / `xbpqSelectorNodes` / `xbpqSelectorStrings`
// / `xbpqRenderHTML`，以及 `provider_web.go` 的 `providerHTMLText`
// / `providerHTMLAttr` / `providerHTMLClass` / `providerHTMLNodes`。
//
// 支持语法（**故意只做这个子集**，跟 Go 完全一致）：
//   p:标签.类#id[attr=值][attr2]  后代用空格或 `>` 分隔（两者语义相同）
//   末尾可挂 [包含:词1,词2] / [不包含:词]（只作用于目标节点）
//   `[href]` 形式（无 `=`）表示「取该属性值」，否则取文本
//
// 不支持的（Go 也不支持）：兄弟选择器 `+`/`~`、伪类、属性前缀匹配 `^=` 等。

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:tvbox/services/xbpq/xbpq_util.dart';

/// 选择器里的一段：`标签.类#id[attr=值]`。
class XbpqSelectorPart {
  String tag = '';
  final List<String> classes = <String>[];
  String id = '';

  /// `[key=value]` 形式（value 为空表示「存在即可」）。
  final List<(String, String)> attrs = <(String, String)>[];

  /// `[href]` 形式：取该属性的值（非空时优先于文本提取）。
  String attr = '';

  final List<String> contains = <String>[];
  final List<String> notContains = <String>[];
}

/// 编译后的选择器：祖先链 + 目标节点。
class XbpqSelectorSpec {
  const XbpqSelectorSpec({
    required this.ancestors,
    required this.target,
    this.extract = 'text',
  });

  final List<XbpqSelectorPart> ancestors;
  final XbpqSelectorPart target;

  /// `text` / `html`。当前解析器只会产出 `text`（与 Go 一致）。
  final String extract;
}

class XbpqSelector {
  XbpqSelector._();

  // ============================================================
  // 对外入口
  // ============================================================

  /// 解析选择器并取第一个匹配的文本 / 属性值；解析失败或无匹配返回空串。
  static String firstString(String sourceHtml, String pattern) {
    final values = strings(sourceHtml, pattern);
    if (values.isEmpty) return '';
    return values.first;
  }

  /// 解析选择器并返回所有匹配节点的文本 / 属性值。
  static List<String> strings(String sourceHtml, String pattern) {
    final spec = parse(pattern);
    if (spec == null) return const <String>[];
    final document = parseDocument(sourceHtml);
    return selectNodes(document, spec)
        .map((node) => valueOf(node, spec))
        .toList();
  }

  /// 把 HTML 文本解析成 DOM（P3 复用，避免反复 import parser）。
  static Document parseDocument(String sourceHtml) =>
      html_parser.parse(sourceHtml);

  // ============================================================
  // 解析
  // ============================================================

  /// 编译 `p:` / `jsoup:` 选择器；非该前缀或语法不合法返回 null。
  static XbpqSelectorSpec? parse(String pattern) {
    var body = pattern;
    if (body.startsWith('p:')) {
      body = body.substring(2);
    } else if (body.startsWith('jsoup:')) {
      body = body.substring(6);
    } else {
      return null;
    }

    // 尾部修饰符：只剥 包含 / 不包含，且只作用于目标节点。
    final contains = <String>[];
    final notContains = <String>[];
    while (body.endsWith(']')) {
      final open = XbpqUtil.matchBracket(body);
      if (open < 0) break;
      final inner = body.substring(open + 1, body.length - 1);
      final colon = inner.indexOf(':');
      final word = (colon < 0 ? inner : inner.substring(0, colon)).trim();
      final payload = colon < 0 ? '' : inner.substring(colon + 1);
      if (word == '包含') {
        contains.addAll(XbpqUtil.splitList(payload));
      } else if (word == '不包含') {
        notContains.addAll(XbpqUtil.splitList(payload));
      } else {
        break;
      }
      body = body.substring(0, open).trim();
    }

    // Go 用 FieldsFunc 把空格和 `>` 都当分隔符：`>` 等价于后代。
    final tokens =
        body.split(RegExp(r'[ >]')).where((e) => e.isNotEmpty).toList();
    final parts = <XbpqSelectorPart>[];
    for (final token in tokens) {
      final part = _parsePart(token);
      if (part == null) return null;
      parts.add(part);
    }
    if (parts.isEmpty) return null;

    final target = parts.last
      ..contains.addAll(contains)
      ..notContains.addAll(notContains);
    return XbpqSelectorSpec(
      ancestors:
          parts.length > 1 ? parts.sublist(0, parts.length - 1) : const [],
      target: target,
    );
  }

  /// 解析单个 token：`标签.类#id[attr=值]`。
  static XbpqSelectorPart? _parsePart(String token) {
    final part = XbpqSelectorPart();

    // 先把所有方括号段剥出来，剩下的才是 标签.类#id。
    final brackets = <String>[];
    final base = StringBuffer();
    var index = 0;
    while (index < token.length) {
      if (token[index] == '[') {
        final closing = token.indexOf(']', index);
        if (closing < 0) return null;
        brackets.add(token.substring(index + 1, closing));
        index = closing + 1;
        continue;
      }
      base.write(token[index]);
      index++;
    }

    var name = base.toString();
    final dot = name.indexOf('.');
    if (dot >= 0) {
      for (final cls in name.substring(dot + 1).split('.')) {
        if (cls.isNotEmpty) part.classes.add(cls);
      }
      name = name.substring(0, dot);
    }
    final hash = name.indexOf('#');
    if (hash >= 0) {
      if (name.length > hash + 1) part.id = name.substring(hash + 1);
      name = name.substring(0, hash);
    }
    if (name.isNotEmpty) part.tag = name.toLowerCase();

    for (final bracket in brackets) {
      if (bracket.isEmpty) continue;
      if (bracket.contains('=') || bracket.contains('`')) {
        final trimmed = XbpqUtil.trimBoth(bracket, '`');
        final eq = trimmed.indexOf('=');
        final key = eq < 0 ? trimmed : trimmed.substring(0, eq);
        var value = eq < 0 ? '' : trimmed.substring(eq + 1);
        value = XbpqUtil.trimBoth(value, "'\"");
        part.attrs.add((key.trim().toLowerCase(), value));
        continue;
      }
      // `[href]` / `[data-value]` 简写：取该属性值。
      part.attr = bracket;
    }
    return part;
  }

  // ============================================================
  // 匹配
  // ============================================================

  /// 在 root 子树里执行选择器，返回目标节点（文档顺序）。
  static List<Element> selectNodes(Node root, XbpqSelectorSpec spec) {
    final found = <Element>[];
    // 与 Go providerHTMLNodes 一致：栈式先序遍历，保持文档顺序。
    final pending = <Node>[root];
    while (pending.isNotEmpty) {
      final node = pending.removeLast();
      if (node is Element &&
          _partMatches(node, spec.target) &&
          _hasAncestorChain(node, spec.ancestors)) {
        found.add(node);
      }
      final children = node.nodes;
      for (var i = children.length - 1; i >= 0; i--) {
        pending.add(children[i]);
      }
    }
    return found;
  }

  /// 取节点值：`[attr]` 优先取属性，否则取文本（或 html）。
  static String valueOf(Element node, XbpqSelectorSpec spec) {
    if (spec.target.attr.isNotEmpty) {
      return _attrExact(node, spec.target.attr).trim();
    }
    if (spec.extract == 'html') return renderHtml(node);
    return text(node);
  }

  static bool _partMatches(Element node, XbpqSelectorPart part) {
    if (part.tag.isNotEmpty && node.localName?.toLowerCase() != part.tag) {
      return false;
    }
    if (part.id.isNotEmpty && node.id != part.id) return false;
    for (final cls in part.classes) {
      if (!node.classes.contains(cls)) return false;
    }
    for (final pair in part.attrs) {
      final value = _attrFold(node, pair.$1);
      if (value == null) return false;
      if (pair.$2.isNotEmpty && value != pair.$2) return false;
    }
    if (part.contains.isNotEmpty || part.notContains.isNotEmpty) {
      final content = text(node);
      for (final word in part.contains) {
        if (!content.contains(word)) return false;
      }
      for (final word in part.notContains) {
        if (content.contains(word)) return false;
      }
    }
    return true;
  }

  /// 祖先链是「宽松顺序匹配」：从父节点一路向上，按需命中即可。
  static bool _hasAncestorChain(
    Element node,
    List<XbpqSelectorPart> ancestors,
  ) {
    if (ancestors.isEmpty) return true;
    var need = ancestors.length - 1;
    Node? current = node.parent;
    while (current != null && need >= 0) {
      if (current is Element && _partMatches(current, ancestors[need])) {
        need--;
      }
      current = current.parent;
    }
    return need < 0;
  }

  /// node 是否在 scope 之内（含自身）。P3 用于把字段限定在条目节点里。
  static bool within(Element? node, Element? scope) {
    if (scope == null) return true;
    Node? current = node;
    while (current != null) {
      if (identical(current, scope)) return true;
      current = current.parent;
    }
    return false;
  }

  // ============================================================
  // 文本 / HTML / 属性
  // ============================================================

  /// 取节点纯文本：拼接所有后代文本节点（跳过 script/style），
  /// 空白折叠成单空格。对齐 Go `providerHTMLText`。
  static String text(Element root) {
    final buffer = StringBuffer();
    void walk(Node node) {
      for (final child in node.nodes) {
        if (child is Text) {
          final parent = child.parent;
          if (parent is Element &&
              (parent.localName == 'script' || parent.localName == 'style')) {
            continue;
          }
          buffer
            ..write(child.data)
            ..write(' ');
        } else {
          walk(child);
        }
      }
    }

    walk(root);
    final raw = buffer.toString();
    return raw.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).join(' ');
  }

  /// 序列化节点（对齐 Go `xbpqRenderHTML`）。
  static String renderHtml(Element node) => node.outerHtml;

  /// 属性取值，**大小写敏感**（对齐 Go `providerHTMLAttr`）。
  static String _attrExact(Element node, String name) {
    for (final entry in node.attributes.entries) {
      if (entry.key.toString() == name) return entry.value;
    }
    return '';
  }

  /// 属性取值，大小写不敏感（对齐 Go 的 `strings.EqualFold` 匹配）。
  static String? _attrFold(Element node, String name) {
    final lower = name.toLowerCase();
    for (final entry in node.attributes.entries) {
      if (entry.key.toString().toLowerCase() == lower) return entry.value;
    }
    return null;
  }
}
