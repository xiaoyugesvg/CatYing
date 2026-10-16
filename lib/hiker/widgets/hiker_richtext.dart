// 海阔**富文本**的解析与降级 —— 全模块唯一一份。
//
// ── 官方约定 ────────────────────────────────────────────────
// 标题开头的**弯引号串**表示"后面是 HTML"：
//   · `‘’‘’<b><font color="#FF69B4">分類</font></b>`  用来标"当前选中"
//   · `““””<b><font color=#FFFFFF>🔥 AI短剧</font></b>` 另一种写法
// 实测内置 115 个源：`““””`（U+201C×2 U+201D×2）出现 **165 次**，
// `‘‘’’`（U+2018×2 U+2019×2）出现 80 次 —— **两种都要认**。
//
// ── 为什么单独一个文件 ──────────────────────────────────────
// [hiker_blocks.dart] 与 [hiker_widgets.dart] 都要用它（卡片标题 / 分类 chip /
// 设置项），放在任一边都会形成循环 import，所以抽出来。
//
// 用户 2026-10-16：
//   「分类名称里面不要出现各种符号之类的，也不要代码外露了」
library;

import 'package:flutter/material.dart';

/// 富文本标记（单引号写法；双引号写法见 [stripHikerRichMark]）
const String kHikerRichMark = '‘‘’’';

/// 标题**开头**的富文本标记：一串弯引号（≥2 个）。
/// 要求 ≥2 是为了不误伤正常标题 —— 中文书名常见的单个 `“我知女人心”` 要保留。
final RegExp _kRichMarkRe = RegExp('[‘’“”]{2,}');

/// 剥掉标题两端的富文本标记（两种写法都吃）。
///
/// 有些源把标记**拆成两半**写（`'““' + html + '””'`），所以吃掉了开头的
/// 还要顺手吃掉结尾的同类引号串（同样 ≥2 个，避免误伤单个书名号）。
String stripHikerRichMark(String raw) {
  var s = raw.trimLeft();
  final m = _kRichMarkRe.matchAsPrefix(s);
  if (m == null) return s;
  s = s.substring(m.end).trimRight();
  return s.replaceFirst(RegExp(r'[‘’“”]{2,}$'), '');
}

/// 是否是"高亮/选中"样式（开头带标记，或带 `<b>` / `<strong>` / `<font`）
bool hikerRichIsActive(String raw) {
  final s = raw.trimLeft();
  return _kRichMarkRe.matchAsPrefix(s) != null ||
      s.startsWith(kHikerRichMark) ||
      s.contains('<b>') ||
      s.contains('<strong>') ||
      s.contains('<font');
}

/// 剥掉富文本标记与所有 HTML 标签，取纯文本（卡片标题、分类 chip、列表项用）
String hikerPlainText(String raw) {
  var s = stripHikerRichMark(raw);
  s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ');
  s = s.replaceAll(RegExp(r'<[^>]+>'), '');
  return s.trim();
}

/// 富文本 → TextSpan（认 `<b>/<strong> <i>/<em> <font|span color> <br>`，其余标签剥掉）
List<TextSpan> hikerRichSpans(String raw, TextStyle base) {
  var s = stripHikerRichMark(raw);
  final spans = <TextSpan>[];
  // 任何标签都吃掉：`<b>`/`<strong>` 加粗、`<i>`/`<em>` 斜体、
  // `<font>`/`<span>` 取颜色、`<br>` 当一个空格，其余（`<p>` `<div>` `<a>`
  // `<center>` …）只剥标签、保留文字。
  //
  // ⚠️ 必须"吃掉**所有**标签"：原来只认 b/i/font，源里极常见的 `<strong>`
  // 会**原样显示在界面上**。用户 2026-10-16 截到的就是这个 ——
  // 源里 `strong: function(txt, color){ return '‘‘’’<strong><font color=#' + color + '>' + txt + '</font></strong>' }`，
  // 「程序设置」那行就渲染成了 `<strong>程序设置</strong>` 一坨原文。
  final re = RegExp(r'<\s*(/?)\s*([a-zA-Z][a-zA-Z0-9]*)([^>]*)>');
  final colorRe = RegExp(r'''color\s*=\s*["']?\s*(#[0-9a-fA-F]{3,8})''');
  var bold = false;
  var italic = false;
  Color? color;
  var idx = 0;
  void push(String text) {
    if (text.isEmpty) return;
    spans.add(TextSpan(
      text: text,
      style: base.copyWith(
        fontWeight: bold ? FontWeight.w700 : base.fontWeight,
        fontStyle: italic ? FontStyle.italic : base.fontStyle,
        color: color ?? base.color,
      ),
    ));
  }

  for (final m in re.allMatches(s)) {
    push(s.substring(idx, m.start));
    idx = m.end;
    final closing = (m.group(1) ?? '') == '/';
    final tag = (m.group(2) ?? '').toLowerCase();
    if (tag == 'br') {
      push(' ');
    } else if (tag == 'b' || tag == 'strong') {
      bold = !closing;
    } else if (tag == 'i' || tag == 'em') {
      italic = !closing;
    } else if (tag == 'font' || tag == 'span') {
      if (closing) {
        color = null;
      } else {
        final c = colorRe.firstMatch(m.group(3) ?? '');
        // 认不出颜色就沿用外层：`<font>` 不带 color 时不该把颜色清掉。
        // 极端色（近黑/近白）直接忽略 —— 源是按它自己的底色选的白字/黑字，
        // 落到我们的主题面上会**看不见**（实测「麻豆传媒AI」当前分类是
        // `<font color=#FFFFFF>`，浅色卡上白字 = 隐形）。
        if (c != null && !_isExtremeHex(c.group(1)!)) {
          color = _hexColor(c.group(1)!);
        }
      }
    }
    // 其余标签：只剥标签，文字保留
  }
  push(s.substring(idx));
  if (spans.isEmpty) push(hikerPlainText(raw));
  return spans;
}

/// 极端色判定：近黑（亮度 ≤0.05）或近白（≥0.9）。
///
/// 源里 `#FFFFFF` / `#000000` 这种是**按它自己的底色**选的字色（白字配高亮块），
/// 我们的卡片 / 分类 chip 是主题面，照搬就是隐形文字，所以忽略、回落主题色。
/// 中间的彩色（`#FF69B4` / `#098AC1` / `#777785` …）照旧保留 —— 那是源用来
/// 标"当前选中"的，有意义。
bool _isExtremeHex(String hex) {
  var h = hex.replaceFirst('#', '');
  if (h.length == 3) h = h.split('').map((c) => '$c$c').join();
  if (h.length != 6) return false;
  final r = int.tryParse(h.substring(0, 2), radix: 16);
  final g = int.tryParse(h.substring(2, 4), radix: 16);
  final b = int.tryParse(h.substring(4, 6), radix: 16);
  if (r == null || g == null || b == null) return false;
  final lum = (r * 299 + g * 587 + b * 114) / 255000;
  return lum >= 0.9 || lum <= 0.05;
}

Color? _hexColor(String hex) {
  var h = hex.replaceFirst('#', '');
  if (h.length == 3) {
    h = h.split('').map((c) => '$c$c').join();
  }
  if (h.length == 6) h = 'FF$h';
  final v = int.tryParse(h, radix: 16);
  return v == null ? null : Color(v);
}
