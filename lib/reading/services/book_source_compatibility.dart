/// 书源导入时的**兼容性静态分析**（不联网、不改源）。
///
/// 目的：导入 600 个源后，用户不应该等到"点开报错"才知道某个源用不了。
/// 这里在入库前扫一遍规则字段和 JS 里的宿主 API，分出：
///   · blocker：缺目录/正文规则，必然跑不通；
///   · warning：需要登录、依赖 WebView 交互、老版发现字段等，可能部分可用。
///
/// 判定刻意保守：**只标明确的问题**，不猜测站点是否失效（那要真跑，属于体检）。
library;

import '../models/book_source.dart';

enum CompatSeverity { warning, blocker }

class CompatIssue {
  const CompatIssue({
    required this.field,
    required this.message,
    this.severity = CompatSeverity.warning,
  });

  /// 涉及的字段/API（展示用）
  final String field;
  final String message;
  final CompatSeverity severity;

  bool get isBlocker => severity == CompatSeverity.blocker;
}

class SourceCompatibility {
  const SourceCompatibility({required this.source, required this.issues});

  final BookSource source;
  final List<CompatIssue> issues;

  bool get usable => !issues.any((e) => e.isBlocker);
  bool get hasWarning => issues.any((e) => !e.isBlocker);
  bool get hasAny => issues.isNotEmpty;
}

class BookSourceCompatibility {
  /// 分析单个源。
  static SourceCompatibility analyze(BookSource source) {
    final issues = <CompatIssue>[];
    if (source.isConfig) {
      // 明文 config 源由 ConfigBookSource 执行，不按 Legado 规则判定
      return SourceCompatibility(source: source, issues: issues);
    }

    final raw = source.raw;

    // ── 必需字段 ──────────────────────────────────────────────
    if (source.url.trim().isEmpty) {
      issues.add(const CompatIssue(
        field: 'bookSourceUrl',
        message: '缺少源地址，无法请求站点',
        severity: CompatSeverity.blocker,
      ));
    }

    // ── 目录 / 正文规则（新旧两种写法）────────────────────────
    final toc = raw['ruleToc'];
    final hasToc = (toc is Map && toc['chapterList'] != null) ||
        raw['ruleChapterList'] != null;
    if (!hasToc) {
      issues.add(const CompatIssue(
        field: 'ruleToc.chapterList',
        message: '没有目录规则，打开后拿不到章节',
        severity: CompatSeverity.blocker,
      ));
    }

    final content = raw['ruleContent'];
    final hasContent = (content is Map && content['content'] != null) ||
        raw['ruleBookContent'] != null;
    if (!hasContent) {
      issues.add(const CompatIssue(
        field: 'ruleContent.content',
        message: '没有正文规则，章节内容为空',
        severity: CompatSeverity.blocker,
      ));
    }

    // ── 搜索（只影响聚搜，不算 blocker）──────────────────────
    final search = raw['ruleSearch'];
    final hasSearch = (search is Map &&
            (search['bookList'] != null || search['searchUrl'] != null)) ||
        raw['ruleSearchList'] != null ||
        raw['ruleSearchUrl'] != null;
    if (!hasSearch) {
      issues.add(const CompatIssue(
        field: 'ruleSearch',
        message: '没有搜索规则，不会出现在聚合搜索里',
      ));
    }

    // ── 发现（书源页主体）──────────────────────────────────
    // 没有 exploreUrl 很常见（很多源只用于搜索），不算问题；
    // 只有**用了老版 ruleFindUrl** 才提示（当前引擎不识别）。
    final exploreUrl = raw['exploreUrl'];
    final hasExplore = (exploreUrl is String && exploreUrl.trim().isNotEmpty) ||
        exploreUrl is Map ||
        exploreUrl is List;
    if (source.enabledExplore &&
        !hasExplore &&
        raw['ruleFindUrl'] != null) {
      issues.add(const CompatIssue(
        field: 'ruleFindUrl',
        message: '老版发现规则（ruleFindUrl）当前引擎不识别，发现页会为空',
      ));
    }

    // ── 登录 ─────────────────────────────────────────────────
    final loginUrl = (raw['loginUrl'] ?? '').toString().trim();
    if (loginUrl.isNotEmpty) {
      issues.add(const CompatIssue(
        field: 'loginUrl',
        message: '需要登录：请先在书源详情里完成登录，否则部分内容会失败',
      ));
    }

    // ── 源类型 ───────────────────────────────────────────────
    if (source.type == '1') {
      issues.add(const CompatIssue(
        field: 'bookSourceType',
        message: '有声源：依赖 TTS/音频播放，正文规则可能与文字源不同',
      ));
    } else if (source.type == '3') {
      issues.add(const CompatIssue(
        field: 'bookSourceType',
        message: '文件源：需要文件下载能力，阅读器仅做基础支持',
      ));
    }

    // ── Python 源 ────────────────────────────────────────────
    if (source.isPythonSource) {
      issues.add(const CompatIssue(
        field: 'pythonKey',
        message: 'Python 书源：需要 iOS Python 引擎就绪（首次使用会自动启动）',
      ));
    }

    // ── JS 里的宿主 API（只扫字符串值）───────────────────────
    final js = _collectStrings(raw).join('\n');
    if (js.contains('java.webView') || js.contains('java.startBrowser')) {
      issues.add(const CompatIssue(
        field: 'java.webView',
        message: '使用 WebView 交互（登录/人机验证）：需要手动打开页面，自动流程可能中断',
      ));
    }
    if (js.contains('Packages.')) {
      issues.add(const CompatIssue(
        field: 'Packages.*',
        message: '使用 Java 互操作（Packages.*）：只兼容常用类，遇到未实现类会报错',
      ));
    }

    return SourceCompatibility(source: source, issues: issues);
  }

  /// 汇总（导入结果弹窗用）。
  static ({int ok, int warning, int blocked}) summarize(
      List<SourceCompatibility> list) {
    var ok = 0, warning = 0, blocked = 0;
    for (final r in list) {
      if (!r.usable) {
        blocked++;
      } else if (r.hasWarning) {
        warning++;
      } else {
        ok++;
      }
    }
    return (ok: ok, warning: warning, blocked: blocked);
  }

  /// 递归收集 JSON 里的所有字符串值（不扫 key）。
  static Iterable<String> _collectStrings(Object? value) sync* {
    if (value is String) {
      if (value.isNotEmpty) yield value;
    } else if (value is Map) {
      for (final v in value.values) {
        yield* _collectStrings(v);
      }
    } else if (value is List) {
      for (final v in value) {
        yield* _collectStrings(v);
      }
    }
  }
}
