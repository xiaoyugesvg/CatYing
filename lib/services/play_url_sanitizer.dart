// lib/services/play_url_sanitizer.dart
//
// 播放地址规范化 —— 处理 TVBox 社区源的「特殊包裹格式」。
//
// ── 为什么需要（用户 2026-10-28 截图崩溃）────────────────────────
// 部分源把真实播放地址包成 `类型|哈希|真实URL`，例如：
//   tencent|54e33584bba1cad748ffaf1fb00baaa8ad0402848ce0ff930e38dd1a138e69066|https://v.qq.com/x/cover/mzc00200in5doq6/m4102tyliy7.html
//
// 直接把整串交给 `Uri.parse` / WebView 会连环失败（已用 dart 实跑确认）：
//   · `Uri.parse` → `FormatException: Illegal scheme character`（`|` 非法）；
//   · `Uri.tryParse` → null；
//   · 先 `Uri.encodeComponent` 再 parse → `tencent%7C…%7Chttps%3A%2F%2F…`，
//     Dart 把它当成"没有 scheme 的 path"；webview_flutter 的
//     `WebViewController.loadRequest` 在 webview_controller.dart:167 抛
//     `ArgumentError('Missing scheme in uri: …')`；
//   · 该异常被 main.dart 的全局 ErrorWidget 捕成「界面渲染出错」
//     —— 就是用户截图里那整页报错。
//
// 规则：含 `|` 时，从右往左找**第一个** `http(s)://` 开头的片段作为真实地址。
// 找不到就原样返回（交给调用方按"格式不对"给出可操作提示）。
library;

/// 把源给的播放地址还原成 WebView / 播放器能直接用的形态。
///
/// 只处理 `a|b|https://…` 这种"最后一段才是真地址"的包裹格式；
/// 正常地址原样返回（含 query 里的 `|` 不会被误伤，因为只有以 http(s) 开头的
/// 片段才会被采用）。
String sanitizePlayUrl(String raw) {
  final original = raw.trim();
  if (original.isEmpty) return original;

  var s = original;
  // 有些链路上游已经做过一次百分号编码（用户截图里的崩溃串正是
  // `tencent%7C54e3…%7Chttps%3A%2F%2Fv.qq.com%2F…`）。不先还原的话，
  // `|` 检查永远命中不了，编码串会被当成"无 scheme 的 path"继续往下传。
  if (!s.contains('|') && s.toLowerCase().contains('%7c')) {
    try {
      final decoded = Uri.decodeComponent(s);
      if (decoded.contains('|')) s = decoded;
    } catch (_) {
      // 解不开就按原样处理
    }
  }

  if (!s.contains('|')) return original;
  final parts = s.split('|');
  for (var i = parts.length - 1; i >= 0; i--) {
    final p = parts[i].trim();
    if (p.startsWith('http://') || p.startsWith('https://')) return p;
  }
  // 找不到真实地址：返回原始串（调用方会按"格式不对"提示，而不是乱猜）
  return original;
}

/// 规范化后是否 http(s) 地址。
bool isHttpPlayUrl(String raw) {
  final s = sanitizePlayUrl(raw).toLowerCase();
  return s.startsWith('http://') || s.startsWith('https://');
}
