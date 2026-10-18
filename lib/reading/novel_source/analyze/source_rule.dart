/// 单条书源规则解析（`@css/@xpath/@json/@js` + `##` 正则替换）。
library;

/// 规则模式：默认（CSS/默认）、XPath、JSON、JS、正则。
enum Mode {
  defaultMode,
  xpath,
  json,
  js,
  regex,
}

class SourceRule {
  String rule = '';
  String elementsRule = '';
  Mode mode;
  String replaceRegex = '';
  String replacement = '';
  bool replaceFirst = false;
  final Map<String, String> putMap = {};

  bool isCss = false;

  /// 原始规则（`##` 分割前）。含 `{{...}}` 内嵌表达式时，`##` 可能出现在
  /// 表达式内部（如 `{{$.tag##\\|##、}}`），构造期不能提前分割，须等
  /// 内嵌表达式替换完成后再分割（由规则引擎求值期处理）。
  String rawRule = '';

  /// 是否含 `{{...}}` / `@get:{...}` 内嵌表达式（求值期需替换）。
  bool hasInnerRule = false;

  /// 模板模式：首个 `{{...}}` 位于规则开头、或其前置文本不含 `##` 时，
  /// 内嵌表达式全部替换后的整串即为最终结果（不再走选择器/JSON 解析）。
  /// 通用书源格式的 URL 模板与字段模板（`{{$.a}}分` 等）即此语义。
  bool templateMode = false;

  SourceRule(String ruleStr, [this.mode = Mode.defaultMode, bool isJson = false]) {
    _init(ruleStr, isJson);
  }

  void _init(String ruleStr, bool isJson) {
    if (mode == Mode.js || mode == Mode.regex) {
      rule = ruleStr;
      elementsRule = ruleStr;
      return;
    }

    // 前缀匹配对齐通用书源格式语义：大小写不敏感、冒号后不要求空格
    // （社区源普遍写 `@css:.item` 而非 `@css: .item`，此前要求空格导致
    // 无空格形式整条规则失效 → 列表解析为空）。
    final lower = ruleStr.toLowerCase();
    if (lower.startsWith('@css:')) {
      mode = Mode.defaultMode;
      isCss = true;
      rule = ruleStr.substring(5);
    } else if (lower.startsWith('@jsoup:')) {
      // `@jsoup:` 与 `@css:` **同语义**：jsoup 选择器就是 CSS 选择器加上
      // `:contains(...)` / `:has(...)` 等扩展，后者由 `AnalyzeByJsoup` 的
      // `_safeQuery` 透明支持（见 analyze_jsoup.dart）。此前该前缀未被识别 ⇒
      // 整条规则（含 `@jsoup:` 字面量）被当成 CSS 选择器 ⇒ 匹配 0 个元素。
      mode = Mode.defaultMode;
      isCss = true;
      rule = ruleStr.substring(7);
    } else if (lower.startsWith('@xpath:')) {
      mode = Mode.xpath;
      rule = ruleStr.substring(7);
    } else if (lower.startsWith('@json:')) {
      mode = Mode.json;
      rule = ruleStr.substring(6);
    } else if (lower.startsWith('@js:')) {
      mode = Mode.js;
      rule = ruleStr.substring(4);
    } else if (ruleStr.startsWith('@@')) {
      mode = Mode.defaultMode;
      isCss = true;
      rule = ruleStr.substring(2);
    } else if (isJson || ruleStr.startsWith('\$.') || ruleStr.startsWith('\$[')) {
      mode = Mode.json;
      rule = ruleStr;
    } else if (ruleStr.startsWith('/')) {
      mode = Mode.xpath;
      rule = ruleStr;
    } else {
      rule = ruleStr;
    }

    rule = _splitPutRule(rule);
    // 内嵌表达式检测：`{{...}}`（规则/JS 表达式）与 `@get:{...}`（变量引用）。
    // 含内嵌表达式时 `##` 分割延迟到替换完成后（表达式内部可含 `##` 正则）。
    rawRule = rule;
    final firstInner = _firstInnerRuleIndex(rule);
    hasInnerRule = firstInner != null;
    if (hasInnerRule) {
      // 首个内嵌表达式位于开头、或前置文本不含 ## → 模板模式。
      final prefix = rule.substring(0, firstInner);
      templateMode = prefix.trim().isEmpty || !prefix.contains('##');
      elementsRule = rule;
    } else {
      _splitRegex(rule);
      elementsRule = rule;
      // CSS 判定必须用**去掉正则替换段后的选择器**：`href#^/read/(\d+)/$#…`
      // 里 `https:` 的冒号会被 _looksLikeCss 当成伪类 ⇒ 整条规则被按 CSS
      // 查询（`querySelectorAll('href')` ⇒ 0 个）⇒ 章节地址全空。
      if (mode == Mode.defaultMode && !isCss && !ruleStr.startsWith('@@')) {
        isCss = _looksLikeCss(rule);
      }
    }
  }

  /// 首个内嵌表达式的起始位置；无则返回 null。
  static int? _firstInnerRuleIndex(String ruleStr) {
    int? min;
    final getMatch = RegExp(r'@get:\{').firstMatch(ruleStr);
    if (getMatch != null) min = getMatch.start;
    final jsMatch = RegExp(r'\{\{').firstMatch(ruleStr);
    if (jsMatch != null && (min == null || jsMatch.start < min)) {
      min = jsMatch.start;
    }
    return min;
  }

  /// [PATCH-17] legado 前缀规则**不是 CSS**。
  ///
  /// 为什么必须显式排除 ✗：`class.item` / `tag.div` / `children.0` 里都含
  /// `字母+.`，会被下面的 `RegExp(r'[a-zA-Z][.#]')` 命中而误判成 CSS ⇒
  /// 走 `querySelectorAll('class.item')` ⇒ **0 个元素**。
  ///
  /// 实测影响（本机 fixture 端到端 + 探针）：
  ///   getElements('class.item') = 0（应为 2）        ← 书源 bookList 的典型写法
  ///   getElements('tag.div')    = 0（应为 2）        ← 书源 chapterList 的典型写法
  ///   getElements('children.0') = 0（应为 1）
  ///   getElements('div.item')   = 2 ✓（纯 CSS 不受影响）
  ///   getElements('class.item@tag.a') = 2 ✓（含 @ 提前返回 false，本就正确）
  /// ⇒ 后果：**目录拿不到任何章节、搜索列表退化成只出书名**
  ///   （作者/分类/最新章节为空）—— 这正是"书源不好用"的根因。
  static const List<String> _legadoPrefixes = <String>[
    'class.',
    'tag.',
    'id.',
    'text.',
    'children.',
  ];

  bool _looksLikeCss(String rule) {
    final trimmed = rule.trim();
    if (trimmed.isEmpty) return false;
    if (trimmed.contains('@')) return false;
    // [PATCH-17] 先排除 legado 前缀写法，再走"看起来像 CSS"的判断
    for (final p in _legadoPrefixes) {
      if (trimmed.startsWith(p)) return false;
    }
    if (trimmed.startsWith('.') || trimmed.startsWith('#') || trimmed.startsWith('[')) return true;
    if (trimmed.contains(':') && !trimmed.startsWith('@')) return true;
    if (RegExp(r'[a-zA-Z][.#]').hasMatch(trimmed)) return true;
    if (RegExp(r'[a-zA-Z]\[').hasMatch(trimmed)) return true;
    return false;
  }

  String _splitPutRule(String ruleStr) {
    final putPattern = RegExp(r'@put:\((\{[^}]+?\})\)', caseSensitive: false);
    var vRuleStr = ruleStr;
    var match = putPattern.firstMatch(vRuleStr);
    while (match != null) {
      vRuleStr = vRuleStr.replaceFirst(match.group(0)!, '');
      final jsonStr = match.group(1)!;
      try {
        final decoded = _parseJsonMap(jsonStr);
        putMap.addAll(decoded);
      } catch (_) {}
      match = putPattern.firstMatch(vRuleStr);
    }
    return vRuleStr;
  }

  void _splitRegex(String ruleStr) {
    final parts = ruleStr.split('##');
    if (parts.length > 1) {
      rule = parts[0].trim();
      replaceRegex = parts[1];
      if (parts.length > 2) replacement = parts[2];
      if (parts.length > 3) replaceFirst = true;
      return;
    }
    rule = ruleStr.trim();
    final single = splitSingleHashReplacement(ruleStr);
    if (single == null) return;
    rule = single.$1;
    replaceRegex = single.$2;
    replacement = single.$3;
    replaceFirst = single.$4;
  }

  /// 单 `#` 正则替换兼容（`选择器#正则#替换` / `选择器#正则`）。
  ///
  /// 部分老源（异次元 / 社区书源）把 legado 的 `##正则##替换` 写成单 `#`：
  ///   `href#^/read/(\d+)/$#https://site/read/$1/`
  ///   `class.detail-line.0@text#作者：\s*`（无替换段 = 删除匹配）
  /// 原实现只 split `'##'` ⇒ 整串（含 `#正则#替换`）被当成选择器求值 ⇒
  /// 目录 0 章、作者/分类带着「作者：」前缀、正文 0 图。
  ///
  /// 判据与 Node 引擎 `splitSingleHashReplacement` 一致：`#` 恰好 1 个或 2 个、
  /// 且正则段含正则特征字符才认 —— 这样 CSS 的 `div#main` / `#content`
  /// （`main`、`content` 不含特征字符）不会被误切。
  static (String, String, String, bool)? splitSingleHashReplacement(String raw) {
    final i1 = raw.indexOf('#');
    if (i1 <= 0) return null;
    final i2 = raw.indexOf('#', i1 + 1);
    if (i2 < 0) {
      final base = raw.substring(0, i1).trim();
      final re = raw.substring(i1 + 1);
      if (base.isEmpty || re.isEmpty) return null;
      // 只有 1 个 `#` 时判据更严（无空白 + 含 `^ \ * + ? $`）：
      // 排除 `div#list li:contains(测试)` 这类**带 # 的 CSS 选择器**被误切。
      if (RegExp(r'\s').hasMatch(re)) return null;
      if (!RegExp(r'[\^\\*+?$]').hasMatch(re)) return null;
      return (base, re, '', false);
    }
    if (raw.indexOf('#', i2 + 1) >= 0) return null;
    final base = raw.substring(0, i1).trim();
    final re = raw.substring(i1 + 1, i2);
    final rep = raw.substring(i2 + 1);
    if (base.isEmpty || re.isEmpty) return null;
    if (!_looksLikeRegex(re)) return null;
    return (base, re, rep, false);
  }

  static bool _looksLikeRegex(String re) {
    return RegExp(r'[\^\\\(\)\[\]\|+*?$]').hasMatch(re);
  }


  static Map<String, String> _parseJsonMap(String jsonStr) {
    final result = <String, String>{};
    final inner = jsonStr.trim();
    if (!inner.startsWith('{') || !inner.endsWith('}')) return result;

    final content = inner.substring(1, inner.length - 1);
    final pairs = _splitJsonPairs(content);
    for (final pair in pairs) {
      final colonIndex = pair.indexOf(':');
      if (colonIndex > 0) {
        final key = pair.substring(0, colonIndex).trim().replaceAll('"', '');
        final value = pair.substring(colonIndex + 1).trim().replaceAll('"', '');
        result[key] = value;
      }
    }
    return result;
  }

  static List<String> _splitJsonPairs(String content) {
    final pairs = <String>[];
    int depth = 0;
    int start = 0;
    bool inString = false;

    for (int i = 0; i < content.length; i++) {
      final c = content[i];
      if (c == '"') {
        inString = !inString;
      } else if (!inString) {
        if (c == '{' || c == '[') {
          depth++;
        } else if (c == '}' || c == ']') {
          depth--;
        } else if (c == ',' && depth == 0) {
          pairs.add(content.substring(start, i).trim());
          start = i + 1;
        }
      }
    }
    if (start < content.length) {
      pairs.add(content.substring(start).trim());
    }
    return pairs;
  }
}
