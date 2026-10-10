/// 书源体检**服务层**（从 `pages/book_source_health_page.dart` 抽出来的可复用逻辑）。
///
/// ── 为什么要有这一层 ─────────────────────────────────────────
/// 体检原本只有「页面 + `BookSourceService.healthCheckAll`」两个落点 ✓，
/// 结果是：**批量筛选内置源 / 落盘 JSON / 无人值守跑一遍**都做不到 ✗
/// （想跑就得开 UI ✓）。这里把「逐条真跑 + 聚合 + 落盘」抽成**纯服务** ✓：
///   · 页面（`book_source_health_page.dart` ✓）调 [analyze]
///   · headless（`main.dart` 的 `TVBOX_SOURCE_SCAN=1` ✓）也调 [analyze]（同一份逻辑 ✓）
///
/// ── 执行链路（**一行都不绕过**）────────────────────────────────
/// 体检**不自己发请求** ✗，一律走 [BookSourceService] 的公开入口 ✓
/// （`searchOne` / `bookInfoChecked` / `toc` / `content` ✓）——
/// 而它的 `_call` 正是「**Dart 引擎优先 → 未接管/空结果/异常 → 回落 Node**」✓
/// （`book_source_service.dart` 的 `[PATCH-9]` + `[PATCH-24-REVERT]`）。
/// ⇒ 本服务**天然继承** Dart 优先 + Node 兜底 ✓，也在 `flutter test` 里可注入假服务 ✓
/// （见 [HealthSearchCallbacks] / `searchOverride`）。
///
/// ── 字段对齐 ─────────────────────────────────────────────────
/// 结果 JSON 字段与参考实现（新阅读软件的 `tool_source_scan.dart`）**逐字对齐** ✓：
/// `name / url / ok / hits / ms / keyword / blocked / error`。字段**只增不改** ✓
/// （本服务额外多两个**新增**字段：`stage` / `enabled`，供 UI 分组与"停用死源"用）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;

import '../models/book_source.dart' as src;
// 失败判据**只从这一个出口拿** ✓（`SourceFailKind` / `describeSourceFail`）——
// 本文件不自己写第二份"网络还是解析"的判据 ✗（历史上两份手写判据把 223 个源全判成解析失败 ✗）。
import '../utils/source_fail_text.dart';
import 'book_source_service.dart';

/// 体检判活用的关键字（**至少两个**：第一轮 0 条再试下一个，减少误杀 ✓）。
///
/// 选大众书名的理由：几乎所有中文书源都有 ✓，搜 0 条基本可判"规则/站点坏了"✓，
/// 而不是"这个词太冷"✗。
const List<String> kHealthKeywords = <String>['剑来', '斗罗大陆'];

/// 单条书源的体检超时（参考实现用 40s ✓）。
const Duration kHealthPerSourceTimeout = Duration(seconds: 40);

/// 明确**未实现的宿主 API**：用了它们的源必然失败 ✓，先标出来便于分类
/// （与参考实现同一套 regexp ✓）。
final List<RegExp> kHealthHostApiBlockers = <RegExp>[
  RegExp(r'java\.webView'),
  RegExp(r'java\.startBrowser'),
  RegExp(r'java\.getByteArray'),
  RegExp(r'java\.aesEncodeToString'),
  RegExp(r'java\.refreshCookie'),
];

/// 命中 [kHealthHostApiBlockers] 时的统一错因（写进结果 JSON 的 `error`）。
const String kBlockedReason =
    '用了未实现的宿主 API（webView/startBrowser/getByteArray/aesEncode/refreshCookie）';

// ============================================================
// 结果模型
// ============================================================

/// 单条书源的体检结果。
class SourceCheckResult {
  const SourceCheckResult({
    required this.source,
    required this.name,
    required this.url,
    required this.ok,
    required this.hits,
    required this.ms,
    required this.keyword,
    required this.blocked,
    required this.error,
    this.stage = '',
    this.enabled = true,
  });

  /// 原始书源（UI 要拿 id / group 等；**不参与 JSON** ✓）。
  final src.BookSource source;
  final String name;
  final String url;

  /// 是否可用（**至少一个关键字命中 > 0 条** ✓）。
  final bool ok;

  /// 命中数（最后一个试的关键字的结果 ✓，与参考实现一致 ✓）。
  final int hits;

  /// 本轮耗时（毫秒；取**最后试的那个关键字**的耗时 ✓）。
  final int ms;

  /// 判活时用的关键字（**一个都没跑**——例如被 blocked 短路——时为空串 ✓）。
  final String keyword;

  /// 是否命中"未实现的宿主 API"黑名单（提前判死，不真跑 ✓）。
  final bool blocked;

  /// 错因（成功时为空串 ✓）。
  final String error;

  /// 失败发生在哪一级（`'搜索'` / `'详情'` / `'目录'` / `'正文'` / `''`）——
  /// **本服务新增字段** ✓，UI 用它把"网络/源站异常"和"解析失败"分开展示。
  final String stage;

  /// 体检时该源是否处于启用状态（**新增字段** ✓，供"停用死源"生成清单）。
  final bool enabled;

  /// 写进 JSON 的字段（**顺序/命名与参考实现对齐** ✓，再追加 stage/enabled）。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'url': url,
        'ok': ok,
        'hits': hits,
        'ms': ms,
        'keyword': keyword,
        'blocked': blocked,
        'error': error,
        // ── 以下为本服务**新增**字段（不是参考实现里的 ✓）──
        'stage': stage,
        'enabled': enabled,
      };

  Map<String, dynamic> toReportJson() => toJson();

  /// 给 `BookSourceHealth`（UI 展示用）的详细文案。
  String get detail {
    if (ok) {
      final parts = <String>['搜索 $hits 条'];
      return parts.join('，');
    }
    if (error.isEmpty) return '搜索「${keyword.isEmpty ? kHealthKeywords.first : keyword}」返回 0 条';
    return error;
  }

  /// 是否属于「网络 / 源站类」失败（超时、拒连、403/401、404/5xx ✓）。
  ///
  /// 判据**不在这里重写** ✗ —— 统一走 `describeSourceFail`（`utils/source_fail_text.dart` ✓），
  /// 与页面/服务的口径完全一致 ✓（历史上"两份手写判据"曾把 223 个源全判成解析失败 ✗）。
  bool get isNetworkish =>
      ok ? false : _isNetworkStage(stage) || _isNetworkErrorText(error);

  @override
  String toString() => 'SourceCheckResult($name, ok=$ok, hits=$hits)';
}

/// 体检进度（**回调给 UI / 日志** ✓）。
class HealthProgress {
  const HealthProgress({
    required this.done,
    required this.total,
    required this.ok,
  });

  final int done;
  final int total;

  /// 已完成里「可用」的条数。
  final int ok;

  double get ratio => total <= 0 ? 0 : done / total;

  @override
  String toString() => '$done/$total 可用 $ok';
}

/// 一次批量体检的汇总。
class HealthRunResult {
  const HealthRunResult({
    required this.results,
    required this.cancelled,
    required this.elapsed,
  });

  /// 与输入**同序**的结果（`null` = 被取消、没跑到 ✓）。
  final List<SourceCheckResult?> results;
  final bool cancelled;
  final Duration elapsed;

  /// 只留跑完的那部分结果。
  List<SourceCheckResult> get finished =>
      results.whereType<SourceCheckResult>().toList();

  int get usableCount => finished.where((r) => r.ok).length;
  int get deadCount => finished.where((r) => !r.ok).length;

  @override
  String toString() =>
      'HealthRunResult(可用 $usableCount/${finished.length}, 取消=$cancelled)';
}

/// 可注入的执行入口（单测用；生产不传 ⇒ 走 [BookSourceService.instance] ✓）。
class HealthSearchCallbacks {
  const HealthSearchCallbacks({
    required this.searchOne,
    required this.bookInfoChecked,
    required this.toc,
    required this.content,
  });

  /// 同 `BookSourceService.searchOne` 的签名。
  final Future<({bool ok, String? error, List<BookSourceResult> list})> Function(
      src.BookSource source, String keyword) searchOne;

  /// 同 `BookSourceService.bookInfoChecked` 的签名。
  final Future<({Map<String, dynamic>? info, String? error})> Function(
      src.BookSource source, String bookUrl) bookInfoChecked;

  /// 同 `BookSourceService.toc` 的签名。
  final Future<({bool ok, String? error, List<BookSourceChapter> list})>
      Function(src.BookSource source, String tocUrl) toc;

  /// 同 `BookSourceService.content` 的签名。
  final Future<({bool ok, String? error, String content, List<String> images})>
      Function(src.BookSource source, String chapterUrl) content;
}

// ============================================================
// 纯函数：筛选 / 聚合（**单测覆盖**，不联网）
// ============================================================

/// 结果排序：可用的排前面，其间按命中数降序（与参考实现一致 ✓）。
List<SourceCheckResult> sortByUsability(List<SourceCheckResult> input) {
  final out = List<SourceCheckResult>.of(input);
  out.sort((a, b) {
    final ao = a.ok ? 0 : 1;
    final bo = b.ok ? 0 : 1;
    if (ao != bo) return ao - bo;
    final h = b.hits.compareTo(a.hits);
    if (h != 0) return h;
    return a.name.compareTo(b.name);
  });
  return out;
}

/// **本次体检里被判死的源 id**（"停用死源"的筛选逻辑 ✓）。
///
/// 只认「**已跑完且不可用**」✓：被取消/没跑到的不算 ✗（否则会把没体检的源误停 ✗）。
/// [onlyEnabled] 为 true（默认 ✓）时跳过本来就已停用的源 —— 它们**已经是停用态** ✓，
/// 再写一次纯属无用的落盘 ✗。
List<String> deadSourceIds(
  List<SourceCheckResult?> results, {
  bool onlyEnabled = true,
}) {
  final out = <String>[];
  final seen = <String>{};
  for (final r in results) {
    if (r == null) continue;
    if (r.ok) continue;
    if (onlyEnabled && !r.enabled) continue;
    final id = r.source.id;
    if (id.isEmpty || !seen.add(id)) continue;
    out.add(id);
  }
  return out;
}

/// 统计摘要（纯逻辑 ✓，供 UI 与报告用）。
class HealthSummary {
  const HealthSummary({
    required this.total,
    required this.tested,
    required this.usable,
    required this.dead,
    required this.blocked,
    required this.untested,
  });

  final int total;
  final int tested;
  final int usable;
  final int dead;
  final int blocked;
  final int untested;

  factory HealthSummary.of(List<SourceCheckResult?> results) {
    var tested = 0, usable = 0, dead = 0, blocked = 0, untested = 0;
    for (final r in results) {
      if (r == null) {
        untested++;
        continue;
      }
      tested++;
      if (r.ok) {
        usable++;
      } else {
        dead++;
        if (r.blocked) blocked++;
      }
    }
    return HealthSummary(
      total: results.length,
      tested: tested,
      usable: usable,
      dead: dead,
      blocked: blocked,
      untested: untested,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'total': total,
        'tested': tested,
        'usable': usable,
        'dead': dead,
        'blocked': blocked,
        'untested': untested,
      };

  @override
  String toString() =>
      '可用 $usable / 判死 $dead / 未测 $untested（共 $total）';
}

/// 从一个书源 raw JSON 里**收集全部规则文本**（供 blocked 检测 ✓）。
///
/// 覆盖 `ruleSearch/ruleExplore/ruleBookInfo/ruleToc/ruleContent` 的全部取值
/// + `exploreUrl/loginUrl/loginCheckJs`（与参考实现同一口径 ✓）。
String collectSourceRules(Map<String, dynamic> raw) {
  final b = StringBuffer();
  for (final k in <String>[
    'ruleSearch',
    'ruleExplore',
    'ruleBookInfo',
    'ruleToc',
    'ruleContent',
  ]) {
    final o = raw[k];
    if (o is Map) {
      for (final v in o.values) {
        for (final x in (v is List ? v : <dynamic>[v])) {
          if (x is String) b.writeln(x);
        }
      }
    }
  }
  for (final k in <String>['exploreUrl', 'loginUrl', 'loginCheckJs']) {
    final v = raw[k];
    if (v is String) b.writeln(v);
  }
  return b.toString();
}

/// 该源是否命中"未实现的宿主 API"（纯逻辑 ✓）。
bool isHostApiBlocked(Map<String, dynamic> raw) {
  final rules = collectSourceRules(raw);
  return kHealthHostApiBlockers.any((rx) => rx.hasMatch(rules));
}

bool _isNetworkStage(String stage) =>
    stage == '搜索' || stage == '详情' || stage == '目录' || stage == '正文';

bool _isNetworkErrorText(String text) {
  if (text.trim().isEmpty) return false;
  switch (describeSourceFail(text, what: '该源').kind) {
    case SourceFailKind.network:
    case SourceFailKind.denied:
    case SourceFailKind.apiBroken:
      return true;
    case SourceFailKind.parseFail:
    case SourceFailKind.unknown:
      return false;
  }
}

// ============================================================
// 服务
// ============================================================

/// 书源体检服务（进程级单例；可构造出**独立实例**做单测 ✓）。
class BookSourceHealthService {
  BookSourceHealthService({
    BookSourceService? service,
    HealthSearchCallbacks? searchOverride,
    List<String> keywords = kHealthKeywords,
    Duration perSourceTimeout = kHealthPerSourceTimeout,
    bool Function()? isCancelled,
  })  : _svc = service ?? BookSourceService.instance,
        _override = searchOverride,
        keywords = List<String>.unmodifiable(keywords),
        perSourceTimeout = perSourceTimeout,
        _isCancelled = isCancelled;

  static final BookSourceHealthService instance = BookSourceHealthService();

  final BookSourceService _svc;
  final HealthSearchCallbacks? _override;

  /// 判活关键字（**按序重试** ✓：第一个 0 条才试下一个 ✓）。
  final List<String> keywords;

  /// 单条超时。
  final Duration perSourceTimeout;

  /// 外部取消信号（headless 用 `SIGINT` 之类；为 null 表示只看 [stop] 流 ✓）。
  final bool Function()? _isCancelled;

  final StreamController<void> _stopCtrl = StreamController<void>.broadcast();

  bool _running = false;

  /// 是否有体检正在跑。
  bool get isRunning => _running;

  /// 取消信号（分析中途任意时刻 [add] 一下就停 ✓）。
  Stream<void> get onStop => _stopCtrl.stream;

  /// 请求取消（**下一条开始前生效**；已在跑的那条等它超时/结束 ✓）。
  void cancel() {
    if (!_stopCtrl.isClosed) _stopCtrl.add(null);
  }

  // ── 单条：搜索判活（多关键字重试）───────────────────────────

  /// 单条源"能不能搜出书"的一次尝试。
  Future<({bool ok, int hits, int ms, String error})> _probeOnce(
    src.BookSource source,
    String keyword,
  ) async {
    final sw = Stopwatch()..start();
    try {
      final r = await (_override?.searchOne ?? _svc.searchOne)(source, keyword)
          .timeout(perSourceTimeout);
      final ms = sw.elapsedMilliseconds;
      if (!r.ok) {
        return (ok: false, hits: 0, ms: ms, error: describeSourceFail(r.error, what: '该源').text);
      }
      final n = r.list.length;
      return (ok: n > 0, hits: n, ms: ms, error: n > 0 ? '' : '搜索「$keyword」返回 0 条');
    } on TimeoutException {
      return (
        ok: false,
        hits: 0,
        ms: sw.elapsedMilliseconds,
        error: '单条体检超时（${perSourceTimeout.inSeconds}s）：请检查网络/代理后重试，或换源',
      );
    } catch (e) {
      return (
        ok: false,
        hits: 0,
        ms: sw.elapsedMilliseconds,
        error: describeSourceFail(e, what: '该源').text,
      );
    }
  }

  /// 逐条体检（**多关键字重试** ✓）：命中即停，全 0 条才判死。
  Future<SourceCheckResult> checkOne(
    src.BookSource source, {
    List<String>? keywords,
  }) async {
    final picked = keywords ?? this.keywords;
    final kws = picked.isEmpty ? kHealthKeywords : picked;
    final blocked = isHostApiBlocked(source.raw);
    if (blocked) {
      return SourceCheckResult(
        source: source,
        name: source.name,
        url: source.url,
        ok: false,
        hits: 0,
        ms: 0,
        keyword: '',
        blocked: true,
        error: kBlockedReason,
        stage: '规则',
        enabled: source.enabled,
      );
    }

    var hits = 0;
    var ms = 0;
    var error = '';
    var used = '';
    var ok = false;
    for (final kw in kws) {
      final p = await _probeOnce(source, kw);
      used = kw;
      ms = p.ms;
      hits = p.hits;
      error = p.error;
      if (p.ok) {
        ok = true;
        error = '';
        break;
      }
    }
    return SourceCheckResult(
      source: source,
      name: source.name,
      url: source.url,
      ok: ok,
      hits: hits,
      ms: ms,
      keyword: used,
      blocked: false,
      error: error,
      stage: ok ? '' : '搜索',
      enabled: source.enabled,
    );
  }

  // ── 单条：完整链路（UI 的「取书→详情→目录→正文」）────────────

  /// 搜索通了以后继续跑 详情→目录→正文（页面的分级依据 ✓）。
  ///
  /// 与 [checkOne] **同一条链路** ✓（都经 `BookSourceService` 的公开入口 ✓），
  /// 只是多走三级 ⇒ 页面能显示"搜索通了但正文是空的"这种半可用源 ✓。
  Future<BookSourceHealth> fullChainCheck(src.BookSource source) async {
    final sw = Stopwatch()..start();
    final notes = <String>[];
    final kw = keywords.isEmpty ? kHealthKeywords.first : keywords.first;
    final search = _override?.searchOne ?? _svc.searchOne;
    final info = _override?.bookInfoChecked ?? _svc.bookInfoChecked;
    final toc = _override?.toc ?? _svc.toc;
    final content = _override?.content ?? _svc.content;

    BookSourceHealth fail(String stage, String err) => BookSourceHealth(
          source: source,
          level: _isNetworkErrorText(err)
              ? BookSourceHealthLevel.dead
              : BookSourceHealthLevel.partial,
          detail: '$stage${_isNetworkErrorText(err) ? '网络不通' : '解析失败'}：'
              '${err.trim().isEmpty ? '规则无效' : err}',
          elapsed: sw.elapsed,
        );

    try {
      // 1) 搜索：取书
      final s = await search(source, kw).timeout(perSourceTimeout);
      if (!s.ok) return fail('搜索', s.error ?? '');
      if (s.list.isEmpty) {
        return BookSourceHealth(
          source: source,
          level: BookSourceHealthLevel.partial,
          detail: '解析失败：搜索「$kw」返回 0 条',
          elapsed: sw.elapsed,
        );
      }
      notes.add('搜索 ${s.list.length} 条');
      final first = s.list.first;

      // 2) 详情
      final r = await info(source, first.bookUrl).timeout(perSourceTimeout);
      if (r.info == null) return fail('详情', r.error ?? '');
      notes.add('详情 OK');

      // 3) 目录
      final tocUrl = (r.info!['tocUrl'] ?? first.bookUrl).toString();
      final t = await toc(source, tocUrl).timeout(perSourceTimeout);
      if (!t.ok || t.list.isEmpty) return fail('目录', t.error ?? '');
      notes.add('目录 ${t.list.length} 章');

      // 4) 正文
      final c = await content(source, t.list.first.url).timeout(perSourceTimeout);
      if (!c.ok || c.content.trim().isEmpty) {
        // 漫画源正文是图片列表（content 为空是正常的 ✓）
        if (c.ok && c.images.isNotEmpty) {
          notes.add('正文 ${c.images.length} 图');
        } else {
          return fail('正文', c.error ?? '正文为空');
        }
      } else {
        notes.add('正文 ${c.content.length} 字');
      }
    } on TimeoutException {
      return BookSourceHealth(
        source: source,
        level: BookSourceHealthLevel.dead,
        detail: '体检超时（${perSourceTimeout.inSeconds}s）：请检查网络/代理后重试，或换源',
        elapsed: sw.elapsed,
      );
    } catch (e) {
      return BookSourceHealth(
        source: source,
        level: BookSourceHealthLevel.dead,
        detail: '体检异常：${describeSourceFail(e, what: '该源').text}',
        elapsed: sw.elapsed,
      );
    }
    sw.stop();
    return BookSourceHealth(
      source: source,
      level: BookSourceHealthLevel.healthy,
      detail: notes.join('，'),
      elapsed: sw.elapsed,
    );
  }

  /// 把搜索结果桥成页面用的 [BookSourceHealth]（搜索结果 + 链路结论合成）。
  BookSourceHealth toHealth(SourceCheckResult r, {BookSourceHealth? chain}) {
    if (chain != null) {
      if (r.ok && chain.level == BookSourceHealthLevel.healthy) return chain;
      if (!r.ok) {
        // 搜索就没过：以判活结果为准（含 blocked / 超时文案 ✓）
        return BookSourceHealth(
          source: r.source,
          level: BookSourceHealthLevel.dead,
          detail: r.error.isEmpty ? '搜索失败' : r.error,
          elapsed: Duration(milliseconds: r.ms),
        );
      }
      return chain; // 搜索过了、链路某级坏了 → partial（链路自己已分好级 ✓）
    }
    if (r.ok) {
      return BookSourceHealth(
        source: r.source,
        level: BookSourceHealthLevel.healthy,
        detail: r.detail,
        elapsed: Duration(milliseconds: r.ms),
      );
    }
    return BookSourceHealth(
      source: r.source,
      level: BookSourceHealthLevel.dead,
      detail: r.error.isEmpty ? '搜索失败' : r.error,
      elapsed: Duration(milliseconds: r.ms),
    );
  }

  // ── 批量（并发 N + 进度 + 可取消）────────────────────────────

  /// 并发 [concurrency] 条逐个体检，**每完成一条就回调** [onProgress]。
  ///
  /// · 并发数固定成 `workers`（与参考实现"每个 worker 自己按步长取任务"同款 ✓）——
  ///   好处是**没有共享 pending 队列** ✓ ⇒ 不会出现"两边同时抢一条"的竞态 ✓。
  /// · [shouldStop] 返回 true（或 [cancel] 被调用）⇒ 下一条开始前退出 ✓，
  ///   返回的 [HealthRunResult.results] 里未跑的条目是 `null` ✓。
  Future<HealthRunResult> analyze(
    List<src.BookSource> sources, {
    int concurrency = 8,
    void Function(HealthProgress p)? onProgress,
    void Function(src.BookSource source, SourceCheckResult r)? onOne,
    bool Function()? shouldStop,
    bool fullChain = false,
  }) async {
    final total = sources.length;
    final results = List<SourceCheckResult?>.filled(total, null);
    final workers = concurrency.clamp(1, 32);
    final sw = Stopwatch()..start();
    final doneFutures = <Future<void>>[];
    var done = 0;
    var okCount = 0;
    var cancelled = false;

    _running = true;
    unawaited(_emit(onProgress, HealthProgress(done: 0, total: total, ok: 0)));

    bool isStopped() {
      if (_isCancelled?.call() ?? false) return true;
      if (shouldStop?.call() ?? false) return true;
      return false;
    }

    Future<void> worker(int start) async {
      for (var i = start; i < total; i += workers) {
        if (isStopped()) {
          // 只记一次"取消"✓（多个 worker 可能同时命中 ✓）
          cancelled = true;
          break;
        }
        SourceCheckResult r;
        try {
          r = await checkOne(sources[i]);
          if (fullChain && r.ok) {
            final chain = await fullChainCheck(sources[i]);
            if (chain.level != BookSourceHealthLevel.healthy) {
              r = SourceCheckResult(
                source: r.source,
                name: r.name,
                url: r.url,
                ok: false,
                hits: r.hits,
                ms: r.ms + chain.elapsed.inMilliseconds,
                keyword: r.keyword,
                blocked: false,
                error: chain.detail,
                stage: '链路',
                enabled: r.enabled,
              );
            }
          }
        } catch (e) {
          r = SourceCheckResult(
            source: sources[i],
            name: sources[i].name,
            url: sources[i].url,
            ok: false,
            hits: 0,
            ms: 0,
            keyword: '',
            blocked: false,
            error: describeSourceFail(e, what: '该源').text,
            stage: '搜索',
            enabled: sources[i].enabled,
          );
        }
        if (isStopped()) {
          cancelled = true;
          break;
        }
        results[i] = r;
        done++;
        if (r.ok) okCount++;
        try {
          onOne?.call(sources[i], r);
        } catch (_) {}
        // 进度回调**串行等待** ⇒ 调用方的 setState 不会重入 ✓
        await _emit(
          onProgress,
          HealthProgress(done: done, total: total, ok: okCount),
        );
      }
    }

    for (var i = 0; i < workers && i < total; i++) {
      doneFutures.add(worker(i));
    }
    // 取消后不无限等：给在跑的请求一个收尾窗口 ✓（它们自身也有单条超时 ✓）
    try {
      await Future.wait(doneFutures).timeout(const Duration(seconds: 60));
    } on TimeoutException {
      cancelled = true;
    } finally {
      _running = false;
    }
    sw.stop();
    return HealthRunResult(
      results: List<SourceCheckResult?>.unmodifiable(results),
      cancelled: cancelled,
      elapsed: sw.elapsed,
    );
  }

  /// 单人入口：**没人监听时也不阻塞** ✓（UI 退出页面后进度只丢回调、体检照跑 ✓）。
  Future<void> _emit(
    void Function(HealthProgress p)? cb,
    HealthProgress p,
  ) async {
    if (cb == null) return;
    try {
      cb(p);
    } catch (_) {}
  }

  // ── 落盘（字段与参考实现对齐）──────────────────────────────

  /// 结果 → JSON 文本（**indent 1 空格**，与参考实现同款 ✓）。
  String encodeReport(List<SourceCheckResult> results) => const JsonEncoder.withIndent(
        ' ',
      ).convert(sortByUsability(results).map((r) => r.toJson()).toList());

  // ── 页面兼容层（薄适配）──────────────────────────────────────
  //
  // `book_source_health_page.dart` 用的是一套更早的入口名（`healthCache` +
  // `healthCheckAll`），而本服务重写时换成了 `checkOne`/`analyze` ✗ ⇒ 页面报
  // "getter/method isn't defined"。这里给出**薄适配**（复用 [checkOne] ✓，
  // 不复制判活逻辑 ✓），让页面与 headless 两条路径共用同一套探测 ✓。

  /// 页面用的结果缓存（key = `source.id`）。退出页面不中断时结果仍写这里 ✓。
  final Map<String, BookSourceHealth> healthCache = <String, BookSourceHealth>{};

  /// 页面入口：对 [sources] 并发 [concurrency] 条逐个判活，每完成一条回调 [onOne]。
  ///
  /// · 与 [analyze] 走**同一条** [checkOne] 链路 ✓；
  /// · [cancel] / [onStop] 在"下一条开始前"生效 ✓（正在跑的那条等它自己结束 ✓）；
  /// · 结果**总是**写进 [healthCache] ✓，与页面是否还在前台无关 ✓。
  Future<void> healthCheckAll(
    List<src.BookSource> sources, {
    int concurrency = 4,
    void Function(BookSourceHealth health)? onOne,
  }) async {
    if (sources.isEmpty) return;
    final n = concurrency < 1 ? 1 : concurrency;
    var next = 0;
    var cancelled = false;
    final sub = onStop.listen((_) => cancelled = true);
    _running = true;
    Future<void> worker() async {
      while (!cancelled) {
        final i = next++;
        if (i >= sources.length) return;
        // 转成页面用的 BookSourceHealth（服务里已有 [toHealth] ✓，不重复造 ✓）
        final h = toHealth(await checkOne(sources[i]));
        healthCache[h.source.id] = h;
        if (onOne != null) {
          try {
            onOne(h);
          } catch (_) {}
        }
      }
    }

    try {
      await Future.wait(
        List<Future<void>>.generate(n > sources.length ? sources.length : n, (_) => worker()),
      );
    } finally {
      _running = false;
      await sub.cancel();
    }
  }

  /// 写 `source_scan_report.json`（+ 可选汇总 `source_scan_summary.json`）。
  ///
  /// 返回写出的报告文件路径；**写失败返回 null** ✓（不抛 —— headless 里不该因
  /// 落盘失败整段崩掉 ✗）。
  Future<String?> writeReport(
    List<SourceCheckResult> results, {
    String path = 'source_scan_report.json',
  }) async {
    try {
      final f = File(path);
      await f.writeAsString(encodeReport(results));
      return f.path;
    } catch (_) {
      return null;
    }
  }
}
