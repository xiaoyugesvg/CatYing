/// 书籍名/章节名的**轻量文本匹配**工具（纯函数，可单测）。
///
/// 只服务两处：
///   · 聚合搜索的「三级排序」——书名与关键词的匹配等级；
///   · 换源章节对齐——章节标题相似度。
///
/// 不引入任何第三方依赖：全角归一 + 标点去除 + bigram Dice。
library;

/// 全角 → 半角、小写、去空白/标点/符号。
String normalizeForMatch(String s) {
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    var c = s.codeUnitAt(i);
    if (c >= 0xFF01 && c <= 0xFF5E) c -= 0xFEE0;
    if (c == 0x3000) c = 0x20;
    b.writeCharCode(c);
  }
  return b
      .toString()
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');
}

/// 字符 bigram 的 Dice 系数（0~1）。
double diceSimilarity(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 1;
  if (a.length < 2 || b.length < 2) {
    return a.contains(b) || b.contains(a) ? 0.8 : 0;
  }
  final sa = <String>{};
  for (var i = 0; i + 1 < a.length; i++) {
    sa.add(a.substring(i, i + 2));
  }
  final sb = <String>{};
  for (var i = 0; i + 1 < b.length; i++) {
    sb.add(b.substring(i, i + 2));
  }
  if (sa.isEmpty || sb.isEmpty) return 0;
  var inter = 0;
  for (final g in sa) {
    if (sb.contains(g)) inter++;
  }
  return 2 * inter / (sa.length + sb.length);
}

/// 书名相对搜索词的匹配等级：**数字越小越靠前**。
///
/// 0 = 归一化后完全相同（书名+作者完全一致的合并结果也落在这里）
/// 1 = 互相包含（「斗罗大陆」vs「斗罗大陆（精校版）」）
/// 2 = 相似度 ≥ 0.55（模糊匹配）
/// 3 = 不相关
int matchRank(String name, String keyword) {
  final n = normalizeForMatch(name);
  final k = normalizeForMatch(keyword);
  if (n.isEmpty || k.isEmpty) return 3;
  if (n == k) return 0;
  if (n.contains(k) || k.contains(n)) return 1;
  return diceSimilarity(n, k) >= 0.55 ? 2 : 3;
}

/// 相似度（0~1），聚合排序同分时做次级比较。
double nameSimilarity(String name, String keyword) =>
    diceSimilarity(normalizeForMatch(name), normalizeForMatch(keyword));
