/// 页眉 / 页脚「格式串」替换。
///
/// 对齐源阅读的「编辑小组件」：用户写一条模板，里面用变量占位，例如
/// `第c章` / `p/P` / `t` / `b`。这里只做**一次扫描**替换 —— 替换出来的内容
/// 不会再被二次替换（否则章节名里恰好有 `p` 会被误换）。
///
/// 可用变量（由阅读器传入）：
///   # 章节名 · c 章节序号 · C 总章数 · p 本章页码 · P 本章总页数
///   % 进度百分比 · t 时间 · b 电量 · B 书名
///
/// 没定义的字符原样保留；空模板返回空串（调用方据此隐藏该位置）。
String resolveHeaderFooterTemplate(String tpl, Map<String, String> vars) {
  if (tpl.isEmpty) return '';
  final sb = StringBuffer();
  for (final r in tpl.runes) {
    final v = vars[String.fromCharCode(r)];
    if (v != null) {
      sb.write(v);
    } else {
      sb.writeCharCode(r);
    }
  }
  return sb.toString();
}
