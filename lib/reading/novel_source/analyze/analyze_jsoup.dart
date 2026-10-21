/// CSS / Jsoup 风格规则解析器：支持 `@` 链式选择器、`@text/@html/@owntext` 取值方法、
/// 索引过滤（`.0`、`.0:5`、`[-1,0:2]`）、`tag./class./id.` 前缀及 `&&/||/%%` 复合规则。
library;

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';
import 'rule_analyzer.dart';
import 'source_rule.dart';

class AnalyzeByJsoup {
  dynamic content;
  final Element _element;

  AnalyzeByJsoup(this.content) : _element = _parse(content);

  static Element _parse(dynamic doc) {
    if (doc is HtmlNodeTree) return doc.element;
    if (doc is Element) return doc;
    if (doc is Document) return doc.documentElement!;
    if (doc is String) {
      final document = html_parser.parse(doc);
      return document.documentElement!;
    }
    return html_parser.parse('').documentElement!;
  }

  /// jsoup 伪选择器 `:contains(text)` 匹配（`package:html` 的 querySelectorAll
  /// 不支持该伪类，遇到会抛异常）。这里做通用降级：剥离所有 `:contains(...)`
  /// 片段拿到基础 CSS 选择器，先 querySelectorAll，再按元素文本包含过滤。
  /// 这是主流书源格式里最常用的伪选择器（如 `p:contains(作者)`、
  /// `a:contains(下一页)`），支持它可让大量社区书源开箱即用（源即插件）。
  static final RegExp _containsRegex = RegExp(r':contains\(([^)]*)\)');

  /// 安全查询：透明支持 `:has(...)` / `:contains(...)`，其余走标准
  /// querySelectorAll。任何异常（不支持的伪类 / 非法选择器 / 无引号数字
  /// 属性值）都降级处理，避免整条规则失效。
  ///
  /// `:has(...)` 的降级见 [_queryHas]（剥离片段先查宿主、按子元素过滤、
  /// 支持 `+`/`>`/`~`/空格组合器，括号平衡解析在 [_splitHas]）。
  static List<Element> _safeQuery(Element root, String selector) {
    final s = selector.trim();
    if (s.isEmpty) return const [];
    if (s.contains(':has(')) {
      return _queryHas(root, s);
    }
    if (s.contains(':contains(')) {
      return _queryContains(root, s);
    }
    try {
      return root.querySelectorAll(s);
    } catch (_) {
      // 属性值无引号且以数字开头（如 `[color*=008800]`）时，package:html 的
      // CSS 解析器把值当数字 token 抛 FormatException（jsoup 原生
      // 支持）。通用降级：给无引号属性值补引号后重试，仍失败才返回空。
      final repaired = _repairAttrQuotes(s);
      if (repaired != null && repaired != s) {
        try {
          return root.querySelectorAll(repaired);
        } catch (_) {
          return const [];
        }
      }
      return const [];
    }
  }

  /// 给选择器中「无引号属性值」补引号：
  /// `[color*=008800]` → `[color*="008800"]`、`[type=text]` → `[type="text"]`。
  /// 已带引号的值（`[href*="soft"]`）不匹配、原样保留；选择器不含属性段时
  /// 返回 null（表示无需修复）。
  static String? _repairAttrQuotes(String selector) {
    if (!selector.contains('[')) return null;
    var changed = false;
    // 只匹配无引号属性值（值不含引号，用「非 ] 非空白」字符类表达），
    // 已带引号的值（如 [href*="soft"]）不会被误伤。
    final repaired = selector.replaceAllMapped(
      RegExp(r'\[([\w-]+)\s*(\*=|^=|\$=|~=|\|=|=)\s*([^\]\s]+)\]'),
      (m) {
        changed = true;
        return '[${m.group(1)}${m.group(2)}"${m.group(3)}"]';
      },
    );
    return changed ? repaired : null;
  }

  /// 提取选择器中第一个 `:has(...)` 的三段（宿主 / inner / 后续组合器）。
  ///
  /// inner 可能嵌套 `:contains(...)` 等带括号的选择器（如
  /// `p:has(strong font:contains(小说简介)) + p`），须按括号平衡扫描
  /// 而非正则 `[^)]*`（后者会在 inner 内层的 `)` 处提前截断）。
  static (String, String, String)? _splitHas(String selector) {
    final start = selector.indexOf(':has(');
    if (start < 0) return null;
    var depth = 0;
    var inQuote = false;
    for (var i = start + 5; i < selector.length; i++) {
      final c = selector[i];
      if (c == "'" || c == '"') {
        inQuote = !inQuote;
        continue;
      }
      if (inQuote) continue;
      if (c == '(') {
        depth++;
      } else if (c == ')') {
        if (depth == 0) {
          return (
            selector.substring(0, start).trim(),
            selector.substring(start + 5, i).trim(),
            selector.substring(i + 1).trim(),
          );
        }
        depth--;
      }
    }
    return null;
  }

  /// 处理含 `:has(...)` 的选择器（支持逗号分组、`:contains` 嵌套与
  /// `+` / `>` / `~` / 空格组合器）。
  ///
  /// 语义（与 jsoup 一致）：`:has(inner)` 修饰其宿主元素，先按
  /// 宿主选择器查出候选，过滤出「包含匹配 inner 的子元素」的宿主；若
  /// `:has(...)` 后还有组合器（如 `p:has(strong) + p`），再对每个宿主
  /// 应用组合器得到目标元素。
  static List<Element> _queryHas(Element root, String selector) {
    final result = <Element>[];
    for (final group in selector.split(',')) {
      var g = group.trim();
      if (g.isEmpty) continue;
      final parts = _splitHas(g);
      if (parts == null) {
        result.addAll(_safeQuery(root, g));
        continue;
      }
      final (before, inner, after) = parts;

      // 宿主元素：before 为空时（`:has` 位于开头）以全部元素为候选。
      List<Element> hosts;
      if (before.isEmpty) {
        hosts = root.querySelectorAll('*');
      } else {
        hosts = _safeQuery(root, before);
      }
      // 过滤出包含匹配 inner 的子元素的宿主（inner 可含 :contains 等，
      // 递归走 _safeQuery 透明处理）。
      if (inner.isNotEmpty) {
        hosts = hosts.where((el) => _safeQuery(el, inner).isNotEmpty).toList();
      }
      result.addAll(_applyAfterCombinator(hosts, after));
    }
    return result;
  }

  /// 对 `:has(...)` 宿主应用其后的组合器（` + p` / ` > p` / ` ~ p` / ` p`），
  /// 无组合器（after 为空）时原样返回宿主。
  static List<Element> _applyAfterCombinator(
      List<Element> hosts, String after) {
    if (after.isEmpty) return hosts;
    final m = RegExp(r'^([\s]*)([>+~]?)([\s]*)(.+)$').firstMatch(after);
    if (m == null) return hosts;
    final comb = m.group(2) ?? '';
    final target = m.group(4)!.trim();
    final out = <Element>[];
    for (final host in hosts) {
      List<Element> candidates;
      switch (comb) {
        case '+':
          final ns = host.nextElementSibling;
          candidates = ns != null ? [ns] : const [];
          break;
        case '>':
          candidates = host.children;
          break;
        case '~':
          // 一般兄弟组合器：父元素 children 中位于 host 之后的全部元素。
          final parent = host.parent;
          if (parent != null) {
            final siblings = parent.children;
            final idx = siblings.indexOf(host);
            candidates = idx >= 0 && idx < siblings.length - 1
                ? siblings.sublist(idx + 1)
                : const <Element>[];
          } else {
            candidates = const <Element>[];
          }
          break;
        default: // 空格：后代元素
          try {
            candidates = host.querySelectorAll('*');
          } catch (_) {
            candidates = const [];
          }
      }
      for (final c in candidates) {
        if (_matchesSelector(c, target)) out.add(c);
      }
    }
    return out;
  }

  /// 判断元素是否匹配选择器。`package:html` 的 Element 无 matches()，
  /// 用「父元素 querySelectorAll 的结果包含该元素」等价判定；选择器含
  /// `:contains(...)` 时降级为「基础选择器命中 + 文本包含」。
  static bool _matchesSelector(Element el, String selector) {
    final parent = el.parent;
    if (parent == null) return false;
    if (selector.contains(':contains(')) {
      final texts = <String>[];
      final base = selector.replaceAllMapped(_containsRegex, (mm) {
        final t = (mm.group(1) ?? '').trim();
        if (t.isNotEmpty) texts.add(t);
        return '';
      }).trim();
      try {
        final els =
            base.isEmpty ? parent.querySelectorAll('*') : parent.querySelectorAll(base);
        return els.contains(el) && texts.every(el.text.contains);
      } catch (_) {
        return false;
      }
    }
    try {
      return parent.querySelectorAll(selector).contains(el);
    } catch (_) {
      return false;
    }
  }

  /// 处理含 `:contains(...)` 的选择器（支持逗号分组与多个 :contains 叠加）。
  static List<Element> _queryContains(Element root, String selector) {
    final result = <Element>[];
    for (final group in selector.split(',')) {
      var g = group.trim();
      if (g.isEmpty) continue;
      final texts = <String>[];
      g = g.replaceAllMapped(_containsRegex, (m) {
        final t = (m.group(1) ?? '').trim();
        if (t.isNotEmpty) texts.add(t);
        return '';
      }).trim();

      List<Element> base;
      if (g.isEmpty) {
        base = root.querySelectorAll('*');
      } else {
        try {
          base = root.querySelectorAll(g);
        } catch (_) {
          base = const [];
        }
      }
      for (final el in base) {
        final text = el.text;
        if (texts.every(text.contains) && !result.contains(el)) {
          result.add(el);
        }
      }
    }
    return result;
  }

  /// 主入口：获取字符串列表，支持 @ 链式选择器。
  List<String> getStringList(String ruleStr) {
    if (ruleStr.isEmpty) return [];

    // legado 的 `-` 前缀 = 结果倒序（站点常把最新章节排在前面）。
    var rule = ruleStr.trim();
    final reverse = rule.startsWith('-');
    if (reverse) rule = rule.substring(1).trim();
    if (rule.isEmpty) return [];

    final sourceRule = SourceRule(rule);
    final elementsRule = sourceRule.elementsRule;

    if (elementsRule.isEmpty) {
      return [_element.text.trim()];
    }

    final ruleAnalyzer = RuleAnalyzer(elementsRule);
    final ruleStrs = ruleAnalyzer.splitRule(['&&', '||', '%%']);
    final results = <List<String>>[];

    for (final ruleStrX in ruleStrs) {
      final temp = sourceRule.isCss
          ? _getResultLastCss(_element, ruleStrX)
          : _getResultList(ruleStrX);

      if (temp.isNotEmpty) {
        results.add(temp);
        if (ruleAnalyzer.elementsType == '||') break;
      }
    }

    if (results.isEmpty) return [];

    final textS = <String>[];
    if (ruleAnalyzer.elementsType == '%%') {
      for (int i = 0; i < results[0].length; i++) {
        for (final temp in results) {
          if (i < temp.length) {
            textS.add(temp[i]);
          }
        }
      }
    } else {
      for (final temp in results) {
        textS.addAll(temp);
      }
    }

    return reverse ? textS.reversed.toList() : textS;
  }

  List<String> _getResultList(String ruleStr) {
    if (ruleStr.isEmpty) return [];

    var elements = <Element>[_element];
    final rule = RuleAnalyzer(ruleStr);
    rule.trim();
    final rules = rule.splitRule(['@']);
    final last = rules.length - 1;

    for (int i = 0; i < last; i++) {
      final r = rules[i].trim();
      final indexMatch = RegExp(r'^(-?\d+)$').firstMatch(r);
      if (indexMatch != null) {
        final index = int.parse(r);
        final len = elements.length;
        if (index >= 0 && index < len) {
          elements = [elements[index]];
        } else if (index < 0 && len >= -index) {
          elements = [elements[len + index]];
        } else {
          elements = [];
        }
      } else {
        final es = <Element>[];
        for (final elt in elements) {
          es.addAll(_getElementsSingle(elt, r));
        }
        elements = es;
      }
    }

    if (elements.isEmpty) return [];
    return _getResultLast(elements, rules[last]);
  }

  /// 按单步规则获取元素，支持 tag./class./id./text. 前缀及索引过滤。
  List<Element> _getElementsSingle(Element temp, String rule) {
    final trimmed = rule.trim();
    if (trimmed.isEmpty) return [];

    // [PATCH-11] 先摘掉选择器**末尾**的方括号索引（legado 写法：`tag.tr[1:20]`、
    // `tag.a[1]`、`class.x@tag.tr[1:20]@tag.a[1]`）。
    //
    // 为什么必须摘 ✗：下面按 `[.!:]` 找分隔符切 `afterPrefix`，而 `tr[1:20]`
    // 里的 `:` 会被当成索引分隔符 ⇒ `getElementsByTagName('tr[1')` ⇒ **空结果**。
    // 实测：`[N]`/`[a:b]` 写法出现在 **129 个规则字段 / 83 条源**。
    // 只认纯数字/区间/逗号列表的方括号 ⇒ `[property$=chapter_name]` 这类
    // CSS 属性选择器不会被误吃 ✓
    final (bareRule, bracketIndex) = _splitBracketIndex(trimmed);

    // 纯索引选择器（如 "0"、"-1"）
    final indexMatch = RegExp(r'^(-?\d+)$').firstMatch(bareRule);
    if (indexMatch != null) {
      final index = int.parse(bareRule);
      final children = temp.children;
      if (index >= 0 && index < children.length) {
        return [children[index]];
      } else if (index < 0 && children.length >= -index) {
        return [children[children.length + index]];
      }
      return [];
    }

    // Legado 简写 `tag.N`：当前节点下第 N 个 tag 元素。
    // 例：`a.0@href`、`p.2@text`、`ul.2@li`（奇异书网等大量老源在用）。
    // ⚠️ 原样交给 CSS 时 `.0` 是"类名 0"（非法）⇒ 永远 0 个
    //   ⇒ 搜索书的 bookUrl / 目录 chapterUrl 全是空串
    //   （用户 2026-10-21：这个源获取不到章节、也没有封面）。
    final tagIdx = RegExp(r'^([A-Za-z][\w-]*)\.(-?\d+)$').firstMatch(bareRule);
    if (tagIdx != null) {
      final els = temp.getElementsByTagName(tagIdx.group(1)!);
      if (els.isEmpty) return [];
      final n = int.parse(tagIdx.group(2)!);
      final i = n < 0 ? els.length + n : n;
      if (i < 0 || i >= els.length) return [];
      return [els[i]];
    }

    // 带索引的特殊选择器（如 "tag.div.0"、"class.name.-1"）
    // 语法：'':' 分隔索引，'.' 表示选择，'!' 表示排除
    for (final prefix in ['children', 'tag.', 'class.', 'id.', 'text.']) {
      if (bareRule.startsWith(prefix)) {
        List<Element> elements;
        String remaining = '';

        if (prefix == 'children') {
          elements = temp.children;
          remaining = trimmed.substring(8).trim(); // "children" 之后
        } else {
          final afterPrefix = bareRule.substring(prefix.length);
          final sepMatch = RegExp(r'[.!:]').firstMatch(afterPrefix);
          if (sepMatch != null) {
            final sepIndex = sepMatch.start;
            final value = afterPrefix.substring(0, sepIndex);
            remaining = afterPrefix.substring(sepIndex);

            switch (prefix) {
              case 'tag.':
                elements = temp.getElementsByTagName(value);
                break;
              case 'class.':
                elements = temp.getElementsByClassName(value);
                break;
              case 'id.':
                final found = temp.querySelector('#$value');
                elements = found != null ? [found] : [];
                break;
              case 'text.':
                elements = temp.children.where((e) => e.text.contains(value)).toList();
                break;
              default:
                elements = [];
            }
          } else {
            final value = afterPrefix;
            switch (prefix) {
              case 'tag.':
                elements = temp.getElementsByTagName(value);
                break;
              case 'class.':
                elements = temp.getElementsByClassName(value);
                break;
              case 'id.':
                final found = temp.querySelector('#$value');
                elements = found != null ? [found] : [];
                break;
              case 'text.':
                elements = temp.children.where((e) => e.text.contains(value)).toList();
                break;
              default:
                elements = [];
            }
            remaining = '';
          }
        }

        if (bracketIndex.isNotEmpty && elements.isNotEmpty) {
          elements = _applyIndexFilter(elements, '[$bracketIndex]');
        }
        if (remaining.isNotEmpty && elements.isNotEmpty) {
          elements = _applyIndexFilter(elements, remaining);
        }
        return elements;
      }
    }

    // 默认按 CSS 选择器处理（透明支持 :contains(...) 伪选择器）
    var cssHits = _safeQuery(temp, bareRule);
    if (bracketIndex.isNotEmpty && cssHits.isNotEmpty) {
      cssHits = _applyIndexFilter(cssHits, '[$bracketIndex]');
    }
    return cssHits;
  }

  /// 拆分选择器末尾的方括号索引（legado 的 `tag.tr[1:20]` / `tag.a[1]` 写法）。
  ///
  /// 返回 `(去掉方括号的选择器, 方括号内的索引表达式)`；没有可识别的索引时
  /// 第二部分为空串。
  ///
  /// **只认纯数字 / 区间 / 逗号列表**（`[1]`、`[-1]`、`[1:20]`、`[0,1,2]`、
  /// `[0:5:2]`）—— 这样 `[property$=chapter_name]`、`[href]` 这类
  /// **CSS 属性选择器**不会被误当作索引 ✓
  static (String, String) _splitBracketIndex(String s) {
    final m = RegExp(
      r'\[(\s*-?\d+(?:\s*:\s*-?\d+(?:\s*:\s*-?\d+)?)?(?:\s*,\s*-?\d+)*\s*)\]$',
    ).firstMatch(s);
    if (m == null) return (s, '');
    return (s.substring(0, m.start).trim(), m.group(1)!);
  }

  /// 索引过滤：支持 .0、.-1、.0:5、.0:5:2、!0、[0,1,2]、[-1,0:2]
  List<Element> _applyIndexFilter(List<Element> elements, String indexStr) {
    final trimmed = indexStr.trim();
    if (trimmed.isEmpty || elements.isEmpty) return elements;

    bool exclude = false;
    String parseStr = trimmed;

    if (parseStr.startsWith('!')) {
      exclude = true;
      parseStr = parseStr.substring(1).trim();
    }

    if (parseStr.startsWith('[') && parseStr.endsWith(']')) {
      parseStr = parseStr.substring(1, parseStr.length - 1);
    } else if (parseStr.startsWith('.')) {
      parseStr = parseStr.substring(1);
    } else if (parseStr.startsWith(':')) {
      parseStr = parseStr.substring(1);
    }

    if (parseStr.isEmpty) return elements;

    final indices = <int>{};
    bool hasValidIndex = false;
    final parts = parseStr.split(',');

    for (final part in parts) {
      final p = part.trim();
      if (p.isEmpty) continue;

      // 区间（start:end 或 start:end:step）
      if (p.contains(':')) {
        final rangeParts = p.split(':');
        int? start;
        int? end;
        var step = 1;

        if (rangeParts.isNotEmpty && rangeParts[0].isNotEmpty) {
          start = int.tryParse(rangeParts[0]);
        }
        if (rangeParts.length > 1 && rangeParts[1].isNotEmpty) {
          end = int.tryParse(rangeParts[1]);
        }
        if (rangeParts.length > 2 && rangeParts[2].isNotEmpty) {
          step = int.tryParse(rangeParts[2]) ?? 1;
        }

        final len = elements.length;
        start = start ?? 0;
        end = end ?? (len - 1);

        if (start < 0) start += len;
        if (end < 0) end += len;
        start = start.clamp(0, len - 1);
        end = end.clamp(0, len - 1);

        if (step == 0) step = 1;

        if (end > start) {
          for (int i = start; i <= end; i += step) {
            indices.add(i);
            hasValidIndex = true;
          }
        } else {
          for (int i = start; i >= end; i -= step) {
            indices.add(i);
            hasValidIndex = true;
          }
        }
      } else {
        final idx = int.tryParse(p);
        if (idx != null) {
          final len = elements.length;
          if (idx >= 0 && idx < len) {
            indices.add(idx);
            hasValidIndex = true;
          } else if (idx < 0 && len >= -idx) {
            indices.add(idx + len);
            hasValidIndex = true;
          }
        }
      }
    }

    // 未解析到有效索引时返回原列表（可能是格式无效）
    if (!hasValidIndex) return elements;

    if (exclude) {
      final result = <Element>[];
      for (int i = 0; i < elements.length; i++) {
        if (!indices.contains(i)) {
          result.add(elements[i]);
        }
      }
      return result;
    } else {
      final sortedIndices = indices.toList()..sort();
      return sortedIndices.map((i) => elements[i]).toList();
    }
  }

  /// 按最后一步方法获取结果（text/html/owntext/属性名 等）。
  List<String> _getResultLast(List<Element> elements, String method) {
    final result = <String>[];
    final lowerMethod = method.toLowerCase();

    switch (lowerMethod) {
      case 'text':
        for (final el in elements) {
          final text = el.text.trim();
          if (text.isNotEmpty) result.add(text);
        }
        break;
      case 'textnodes':
        for (final el in elements) {
          final nodes = el.nodes
              .whereType<Text>()
              .map((n) => (n).text.trim())
              .where((s) => s.isNotEmpty)
              .toList();
          if (nodes.isNotEmpty) result.add(nodes.join('\n'));
        }
        break;
      case 'owntext':
        for (final el in elements) {
          final text = el.nodes
              .whereType<Text>()
              .map((n) => n.text.trim())
              .where((s) => s.isNotEmpty)
              .join(' ')
              .trim();
          if (text.isNotEmpty) result.add(text);
        }
        break;
      case 'html':
        for (final el in elements) {
          final clone = el.clone(true);
          clone.querySelectorAll('script').forEach((e) => e.remove());
          clone.querySelectorAll('style').forEach((e) => e.remove());
          final html = clone.innerHtml;
          if (html.isNotEmpty) result.add(html);
        }
        break;
      case 'all':
        for (final el in elements) {
          result.add(el.outerHtml);
        }
        break;
      default:
        // 属性提取
        for (final el in elements) {
          final attr = el.attributes[method] ?? '';
          if (attr.isNotEmpty && !result.contains(attr)) result.add(attr);
        }
        break;
    }
    return result;
  }

  /// CSS 规则带结尾 @ 取值方法。
  List<String> _getResultLastCss(Element element, String ruleStr) {
    final lastAt = ruleStr.lastIndexOf('@');
    if (lastAt < 0) {
      final elements = _safeQuery(element, ruleStr);
      return elements.map((e) => e.text.trim()).where((s) => s.isNotEmpty).toList();
    }
    final selector = ruleStr.substring(0, lastAt).trim();
    final extractMethod = ruleStr.substring(lastAt + 1).trim();
    final elements = _safeQuery(element, selector);
    return _getResultLast(elements, extractMethod);
  }

  /// 获取单个字符串（多结果以换行拼接）。
  String getString(String ruleStr) {
    final list = getStringList(ruleStr);
    if (list.isEmpty) return '';
    if (list.length == 1) return list.first;
    return list.join('\n');
  }

  /// 仅取首个字符串（用于 URL 提取）。
  String getString0(String ruleStr) {
    final list = getStringList(ruleStr);
    return list.isEmpty ? '' : list.first;
  }

  /// 获取元素列表（非字符串）。
  List<dynamic> getElements(String ruleStr) {
    if (ruleStr.isEmpty) return [];

    // legado 的 `-` 前缀 = 结果倒序（如 `-id.chapters@class.grid@tag.a`）：
    // 站点把最新章节排在前面，倒序后目录才是正序。原来 `-` 被当成选择器
    // 的一部分 ⇒ `querySelectorAll('-id.chapters')` 抛异常/0 元素 ⇒ 目录空。
    var ruleStrX0 = ruleStr.trim();
    final reverse = ruleStrX0.startsWith('-');
    if (reverse) ruleStrX0 = ruleStrX0.substring(1).trim();
    if (ruleStrX0.isEmpty) return [];

    final sourceRule = SourceRule(ruleStrX0);
    final elementsRule = sourceRule.elementsRule;

    if (elementsRule.isEmpty) return [_element];

    final ruleAnalyzer = RuleAnalyzer(elementsRule);
    final ruleStrs = ruleAnalyzer.splitRule(['&&', '||', '%%']);
    final elementsList = <List<Element>>[];

    for (final ruleStrX in ruleStrs) {
      final elements = sourceRule.isCss
          ? _getElementsCss(_element, ruleStrX)
          : _getElementsNonCss(ruleStrX);

      if (elements.isNotEmpty) {
        elementsList.add(elements);
        if (ruleAnalyzer.elementsType == '||') break;
      }
    }

    if (elementsList.isEmpty) return [];

    final result = <Element>[];
    if (ruleAnalyzer.elementsType == '%%') {
      for (int i = 0; i < elementsList[0].length; i++) {
        for (final elements in elementsList) {
          if (i < elements.length) {
            result.add(elements[i]);
          }
        }
      }
    } else {
      for (final elements in elementsList) {
        result.addAll(elements);
      }
    }

    return reverse ? result.reversed.toList() : result;
  }

  List<Element> _getElementsCss(Element element, String ruleStr) {
    final lastAt = ruleStr.lastIndexOf('@');
    if (lastAt >= 0) {
      return _safeQuery(element, ruleStr.substring(0, lastAt).trim());
    }
    return _safeQuery(element, ruleStr);
  }

  List<Element> _getElementsNonCss(String ruleStr) {
    if (ruleStr.isEmpty) return [];

    var elements = <Element>[_element];
    final rule = RuleAnalyzer(ruleStr);
    rule.trim();
    final rules = rule.splitRule(['@']);

    for (final r in rules) {
      final es = <Element>[];
      for (final elt in elements) {
        es.addAll(_getElementsSingle(elt, r));
      }
      elements = es;
    }

    return elements;
  }

  dynamic getObject(String rule) {
    if (rule.isEmpty) return null;

    final list = getStringList(rule);
    if (list.isEmpty) return null;
    if (list.length == 1) return list.first;

    try {
      final elements = getElements(rule);
      if (elements.isEmpty) return null;
      final el = elements.first;
      if (el is Element) {
        return {
          'text': el.text.trim(),
          'html': el.innerHtml,
          ...el.attributes,
        };
      }
      return el;
    } catch (_) {
      return list.first;
    }
  }
}
