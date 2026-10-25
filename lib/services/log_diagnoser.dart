import 'app_log.dart';
import '../reading/services/ai_service.dart';

/// 一类"同源"日志（归一化后聚合），代表一个待排查的问题
class LogCluster {
  LogCluster({
    required this.level,
    required this.category,
    required this.action,
    required this.key,
  });

  final String level;
  final String category;
  final String action;

  /// 归一化后的指纹（同类问题合并用）
  final String key;

  int count = 0;
  String sample = '';
  DateTime? first;
  DateTime? last;

  void add(String msg, DateTime? ts) {
    count++;
    if (sample.isEmpty && msg.isNotEmpty) sample = msg;
    if (ts != null) {
      first ??= ts;
      if (last == null || ts.isAfter(last!)) last = ts;
    }
  }
}

/// 日志摘要（喂给 AI 的就是这个，不是原始日志）
class LogDigest {
  LogDigest({
    required this.total,
    required this.levelCounts,
    required this.clusters,
    this.from,
    this.to,
    required this.slowCount,
  });

  final int total;
  final Map<String, int> levelCounts;
  final List<LogCluster> clusters;
  final DateTime? from;
  final DateTime? to;

  /// elapsedMs > 5s 的条数（性能问题线索）
  final int slowCount;

  bool get isEmpty => total == 0;

  /// 拼成给模型的紧凑文本（**控制长度**，7B 模型也吃得下）
  String toPromptText({int maxChars = 6000}) {
    final b = StringBuffer();
    b.writeln('### 概览');
    b.writeln('总行数 $total  |  '
        '${levelCounts.entries.map((e) => '${e.key} ${e.value}').join(' · ')}'
        '  |  慢操作(>5s) $slowCount');
    if (from != null || to != null) {
      b.writeln('时间范围 ${_fmt(from)} ~ ${_fmt(to)}');
    }
    b.writeln();
    b.writeln('### 问题聚类（按出现次数降序，最多 20 类）');
    final top = clusters.take(20).toList();
    for (var i = 0; i < top.length; i++) {
      final c = top[i];
      b.writeln('${i + 1}. [${c.count} 次] ${c.level} | '
          '${c.category}${c.action.isEmpty ? '' : '/${c.action}'}');
      if (c.first != null) {
        b.writeln('   时间 ${_fmt(c.first)} ~ ${_fmt(c.last)}');
      }
      if (c.sample.isNotEmpty) {
        b.writeln('   样例 ${_clip(c.sample, 240)}');
      }
      if (b.length > maxChars) {
        b.writeln('…（已截断）');
        break;
      }
    }
    return b.toString();
  }

  static String _fmt(DateTime? t) {
    if (t == null) return '-';
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.month}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  static String _clip(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…';
}

/// 日志诊断：**先本地聚合，再让 AI 解读**
///
/// 为什么不直接把日志丢给模型：2MB 日志约 2 万行，超上下文，且 90% 是重复噪音；
/// 聚合后只剩 20 类 × 几行，既能塞进去，又能让模型基于"次数/时间分布"判断。
class LogDiagnoser {
  LogDiagnoser._();

  static const String _systemPrompt = '''
你是这个 Flutter App（影视 + 阅读，内含 Python/Node 爬虫引擎）的稳定性顾问。
下面给你的是**日志聚合结果**，不是原始日志。

请严格遵守：
1. 按影响面（出现次数 × 是否影响核心功能）排序，最多给 5 条；
2. 每条格式：现象 → 可能原因 → 具体修改建议（指明大概在哪个模块/文件）；
3. **只基于给到的数据推断**；证据不足就写"需补充日志"，绝不编造；
4. 中文，每条不超过 4 行，不要客套话。
''';

  /// 读取最近 [lines] 条 JSONL 并聚合
  static Future<LogDigest> digest({int lines = 1000}) async {
    final rows = await AppLog.instance.readRecentJsonl(lines: lines);
    final levelCounts = <String, int>{};
    final map = <String, LogCluster>{};
    DateTime? from;
    DateTime? to;
    var slow = 0;

    for (final r in rows) {
      final level = (r['level'] as String?) ?? 'info';
      levelCounts[level] = (levelCounts[level] ?? 0) + 1;

      final ts = DateTime.tryParse((r['ts'] as String?) ?? '');
      if (ts != null) {
        from ??= ts;
        if (to == null || ts.isAfter(to)) to = ts;
      }
      final elapsed = (r['elapsedMs'] as num?)?.toInt() ?? 0;
      if (elapsed > 5000) slow++;

      // 只聚合 warn / error：info/debug 量太大且通常无诊断价值
      if (level != 'warn' && level != 'error') continue;

      final category = (r['category'] as String?) ?? '';
      final action = (r['action'] as String?) ?? '';
      final msg = (r['msg'] as String?) ?? '';
      final err = (r['error'] as String?) ?? '';
      final text = err.isNotEmpty ? '${msg.isEmpty ? '' : '$msg — '}$err' : msg;
      final norm = _normalize(text);
      final key = '$level|$category|$action|$norm';

      final c = map.putIfAbsent(
        key,
        () => LogCluster(
          level: level,
          category: category,
          action: action,
          key: norm,
        ),
      );
      c.add(text, ts);
    }

    final clusters = map.values.toList()
      ..sort((a, b) => b.count.compareTo(a.count));

    return LogDigest(
      total: rows.length,
      levelCounts: levelCounts,
      clusters: clusters,
      from: from,
      to: to,
      slowCount: slow,
    );
  }

  /// 归一化：把"同类不同参数"的日志合并成一类
  static String _normalize(String s) {
    var t = s;
    t = t.replaceAll(RegExp(r'https?://\S+'), '<url>');
    t = t.replaceAll(RegExp(r'\b[0-9a-fA-F]{8,}\b'), '<hex>');
    t = t.replaceAll(RegExp(r'\b\d+\.\d+\b'), '<num>');
    t = t.replaceAll(RegExp(r'\b\d{2,}\b'), '<num>');
    t = t.replaceAll(RegExp(r'\s+'), ' ');
    t = t.trim();
    return t.length > 160 ? t.substring(0, 160) : t;
  }

  /// 调 AI 生成诊断报告
  static Future<String> diagnose(LogDigest d) async {
    final ai = AiService();
    await ai.init();
    if (!ai.isConfigured) {
      throw '还没配置 AI：请到「AI 管理」填一个 API Key';
    }
    if (d.isEmpty) {
      throw '没有读到日志（应用日志可能已关闭或为空）';
    }
    return ai.chat(
      system: _systemPrompt,
      user: '以下是最近日志的聚合结果：\n\n${d.toPromptText()}',
      timeout: const Duration(seconds: 120),
    );
  }
}
