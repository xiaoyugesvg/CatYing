/// 换源章节对齐（标题相似度 + 序号比例双对齐）。
///
/// 场景：读者在 A 源读到第 N 章，换到 B 源后 B 源的目录编号/章节名和 A 源
/// 不完全一致（有的少一章"番外"，有的把"第12章"写成"012 冲突"）。
/// 直接按 index 跳会错位，直接跳第 0 章又等于丢失进度。
///
/// 这里的做法（纯函数，可单测）：
///   1. 先找**归一化后标题完全相同**的章节；
///   2. 再按「章节序号 + 标题相似度」打分取最优；
///   3. 标题都对不上时，按**进度比例**兜底（oldIndex / oldLen ≈ newIndex / newLen）。
///
/// 只做定位，不改任何书源/目录数据。
library;

import 'package:tvbox/reading/utils/text_match.dart';

/// 对齐结果。
class ChapterAlignment {
  const ChapterAlignment({
    required this.index,
    required this.score,
    required this.matchedByTitle,
    required this.ratioFallback,
  });

  /// 新目录里的章节下标（已 clamp 到合法范围）。
  final int index;

  /// 匹配得分（0~1）；比例兜底时固定为 0。
  final double score;

  /// true = 命中了标题/章节序号；false = 只按比例估算。
  final bool matchedByTitle;

  /// true = 走了比例兜底。
  final bool ratioFallback;

  /// `BookSourceReaderPage` 的进度键（**唯一格式来源**）。
  ///
  /// 阅读器与换源对齐都用它读写，避免两边各写一份字符串导致键不一致。
  static String progressKey(String sourceId, String bookName) =>
      'bsr.progress.$sourceId.$bookName';

  /// 把 [oldIndex]（旧目录中的位置）对齐到 [newTitles]。
  ///
  /// [oldTitles] / [newTitles] 传章节名列表（纯文本，已去 HTML）。
  /// 旧下标非法或新目录为空时返回 null（调用方保持原行为）。
  static ChapterAlignment? align({
    required List<String> oldTitles,
    required int oldIndex,
    required List<String> newTitles,
  }) {
    if (newTitles.isEmpty) return null;
    if (oldIndex < 0 || oldIndex >= oldTitles.length) return null;

    final oldTitle = _normalize(oldTitles[oldIndex]);
    final oldNum = _chapterNumber(oldTitle);

    // ── 1) 标题完全一致 ────────────────────────────────────────
    if (oldTitle.isNotEmpty) {
      for (var i = 0; i < newTitles.length; i++) {
        if (_normalize(newTitles[i]) == oldTitle) {
          return ChapterAlignment(
            index: i,
            score: 1,
            matchedByTitle: true,
            ratioFallback: false,
          );
        }
      }
    }

    // ── 2) 序号 + 标题相似度打分 ───────────────────────────────
    var bestIdx = -1;
    var bestScore = 0.0;
    final oldProgress =
        oldTitles.length <= 1 ? 0.0 : oldIndex / (oldTitles.length - 1);

    for (var i = 0; i < newTitles.length; i++) {
      final raw = newTitles[i];
      final norm = _normalize(raw);
      final num = _chapterNumber(norm);

      // 两边都有明确章节号：不同号直接跳过（避免"第12章"匹配到"第21章"）
      if (oldNum != null && num != null && oldNum != num) continue;

      final numScore = (oldNum != null && num != null && oldNum == num)
          ? 1.0
          : (oldNum == null || num == null)
              ? 0.0
              : 0.0;
      final sim = _dice(_stripChapterNoise(oldTitle), _stripChapterNoise(norm));
      final titleScore = (oldNum != null && num != null)
          ? 0.6 * numScore + 0.4 * sim
          : sim;

      // 进度比例：只作为轻微加权，防止"同名章节"跨度过大
      final p = newTitles.length <= 1 ? 0.0 : i / (newTitles.length - 1);
      final ratioScore = 1.0 - (p - oldProgress).abs().clamp(0.0, 1.0);
      final total = 0.88 * titleScore + 0.12 * ratioScore;

      if (total > bestScore) {
        bestScore = total;
        bestIdx = i;
      }
    }

    final strongNumMatch =
        oldNum != null && bestIdx >= 0 && _chapterNumber(_normalize(newTitles[bestIdx])) == oldNum;
    if (bestIdx >= 0 && (bestScore >= 0.62 || (strongNumMatch && bestScore >= 0.45))) {
      return ChapterAlignment(
        index: bestIdx,
        score: bestScore,
        matchedByTitle: true,
        ratioFallback: false,
      );
    }

    // ── 3) 比例兜底 ────────────────────────────────────────────
    final ratioIdx = oldTitles.length <= 1
        ? 0
        : (((oldIndex + 0.5) * newTitles.length / oldTitles.length).floor())
            .clamp(0, newTitles.length - 1);
    return ChapterAlignment(
      index: ratioIdx,
      score: 0,
      matchedByTitle: false,
      ratioFallback: true,
    );
  }

  // ============================================================
  // 纯文本工具（全部 static，方便单测）
  // ============================================================

  /// 全角 → 半角、小写、去空白/标点/符号。
  static String _normalize(String s) => normalizeForMatch(s);

  /// 去掉章节号/序号后的"标题正文"，用于相似度比较。
  static String _stripChapterNoise(String normalized) {
    var s = normalized;
    s = s.replaceAll(RegExp(r'第[0-9零一二三四五六七八九十百千万两]+[章节回卷话集篇]'), '');
    s = s.replaceAll(RegExp(r'^(?:chapter|chap)\d+'), '');
    s = s.replaceAll(RegExp(r'^\d+'), '');
    return s;
  }

  /// 从章节名里提取章节号；提取不到返回 null。
  ///
  /// 支持：`第12章`、`第十二回`、`Chapter 12`、`012、标题`、`12 标题`。
  static int? _chapterNumber(String normalized) {
    if (normalized.isEmpty) return null;

    // 第X章 / 第X回 / 第X节 / 第X卷 / 第X话 / 第X集 / 第X篇
    final m1 = RegExp(r'第([0-9零一二三四五六七八九十百千万两]+)[章节回卷话集篇]')
        .firstMatch(normalized);
    if (m1 != null) {
      final raw = m1.group(1)!;
      final n = int.tryParse(raw) ?? _chineseNumber(raw);
      if (n != null) return n;
    }

    // Chapter 12 / Chap.12
    final m2 = RegExp(r'(?:chapter|chap)(\d+)').firstMatch(normalized);
    if (m2 != null) return int.tryParse(m2.group(1)!);

    // 开头纯数字：012冲突 / 12.标题 / 12标题
    final m3 = RegExp(r'^(\d{1,6})').firstMatch(normalized);
    if (m3 != null) return int.tryParse(m3.group(1)!);

    return null;
  }

  /// 中文数字 → int（覆盖 0~99999，足够章节号）。
  static int? _chineseNumber(String s) {
    const digits = {
      '零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4,
      '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
    };
    const units = {'十': 10, '百': 100, '千': 1000, '万': 10000};
    var total = 0;
    var section = 0;
    var number = 0;
    var seen = false;
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (digits.containsKey(ch)) {
        number = digits[ch]!;
        seen = true;
      } else if (units.containsKey(ch)) {
        final u = units[ch]!;
        if (u == 10000) {
          section = (section + number) * u;
          total += section;
          section = 0;
        } else {
          section += (number == 0 ? 1 : number) * u;
        }
        number = 0;
        seen = true;
      } else {
        return null;
      }
    }
    if (!seen) return null;
    return total + section + number;
  }

  /// 字符 bigram 的 Dice 系数（0~1）。
  static double _dice(String a, String b) => diceSimilarity(a, b);
}
