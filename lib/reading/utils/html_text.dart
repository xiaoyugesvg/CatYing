// 阅读模块的 HTML 文本清洗。
//
// ── 为什么需要 ─────────────────────────────────────────────────
// 书源接口（Legado 规则只做"取文本"，不保证是纯文本）经常把
// `<br>`、`<em>`、`<span style="…">`、`&nbsp;` 这类片段直接塞进
// 书名 / 作者 / 章节名 / 简介 ⇒ 原样显示就会看到 `<br>` 这种代码。
//
// 用户 2026-10-13：「书源里面的详情的书籍名称、作者名还有更新日期、
// 简介里面不要有 <br> 这种类似的代码」。
//
// ── 顺序很关键 ─────────────────────────────────────────────────
// **先把换行类标签转成换行、再剥标签** —— 否则 `第一行<br>第二行`
// 会被粘成 `第一行第二行`（分段信息丢了）。
//
// [singleLine] = true 用于书名 / 作者 / 时间这类**必须单行**的字段：
// 最后把换行压成空格，免得一个 `<br>` 把书名劈成两行。

/// 去掉 HTML 标签 / 解码常见实体，并把空白收敛到正常人读的样子。
///
/// 纯函数、无副作用：只处理"显示用的文本"，不参与任何规则匹配。
String stripHtmlText(String raw, {bool singleLine = false}) {
  if (raw.isEmpty) return raw;
  var s = raw;

  // 1) 换行 / 分段标签 → 换行符
  s = s.replaceAll(
      RegExp(r'<\s*br\s*/?\s*>|</\s*(p|div|li|h[1-6])\s*>', caseSensitive: false),
      '\n');

  // 2) 其余标签整体剥掉（<em> <span style="…"> …）
  s = s.replaceAll(RegExp(r'<[^>]*>'), '');

  // 3) 常见 HTML 实体解码（&amp; 放最后：避免把 `&amp;lt;` 解成 `<`）
  s = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&ldquo;', '“')
      .replaceAll('&rdquo;', '”')
      .replaceAll('&hellip;', '…')
      .replaceAll('&mdash;', '—')
      .replaceAll('&middot;', '·')
      .replaceAll('&amp;', '&');

  // 4) 收敛空白：行内连续空白压成一个；连续空行最多留一个；去首尾空行
  final out = <String>[];
  var blank = false;
  for (final line in s.split('\n')) {
    final l = line.replaceAll(RegExp(r'[ \t\u3000]+'), ' ').trim();
    if (l.isEmpty) {
      if (!blank && out.isNotEmpty) out.add('');
      blank = true;
    } else {
      out.add(l);
      blank = false;
    }
  }
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }

  final joined = out.join('\n').trim();
  return singleLine
      ? joined.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim()
      : joined;
}
