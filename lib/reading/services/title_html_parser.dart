import 'dart:convert';
import 'dart:typed_data';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// 「标题样式」的小型 HTML / CSS 子集解析器。
///
/// 为什么需要它：源阅读的标题样式是一段 HTML（内联 CSS），而 Flutter 没有
/// HTML/CSS 引擎（渲染是自绘 RenderObject，不解析 DOM）。但标题样式用到的
/// CSS 其实只有十来个属性 —— 这里把它们映射成 Widget，并**用同一套样式**
/// 做离线度量（TextPainter），所以分页高度与真实渲染一致。
///
/// 支持的标签：div / p / h1~h6 / span / b / strong / i / em / br
/// （其余标签会被"拍平"：只保留子节点）
///
/// 支持的 CSS：
///   · color / background-color（#rgb、#rrggbb、#rrggbbaa、rgb()、rgba()、常用色名）
///   · background-image（http(s) / data: / asset:）
///   · background-repeat / background-position / background-size（no-repeat / left / auto 100% / contain / cover）
///   · font-size（em / px / %）、font-weight（bold / 100~900 / lighter / normal）
///   · font-style（italic）、line-height（数字 / em）
///   · letter-spacing（em / px）、text-align（left / center / right）
///   · text-decoration（underline）、text-shadow（x y blur color）
///   · margin / padding（1~4 值简写，em / px）
///   · border-radius、border（宽度 + 颜色）、box-shadow（x y blur spread color）
///   · display（inline-block 只影响宽度收缩，Flutter 天然就是收缩的）
///
/// 占位符：文本里的「章节数」→ 章节序号，「章节名」→ 章节标题。
///
/// 不支持的（会被忽略）：position、flex、transform、@media、动画、字体族
/// （Flutter 不能加载任意字体文件；要换字体请在阅读器里设置）。
class TitleHtmlDoc {
  TitleHtmlDoc(this.root);

  final TitleBoxBlock root;

  bool get isEmpty => root.children.isEmpty;
}

/// 一个块（文本 或 容器）
sealed class TitleBlock {
  TitleBlock(this.style);

  final TitleCss style;
}

class TitleTextBlock extends TitleBlock {
  TitleTextBlock(super.style, this.text);

  final String text;
}

class TitleBoxBlock extends TitleBlock {
  TitleBoxBlock(super.style, this.children);

  final List<TitleBlock> children;
}

/// CSS 长度：em 相对**当前元素字号**，其余按逻辑像素
class TitleLen {
  const TitleLen(this.value, {this.isEm = false});

  static const zero = TitleLen(0);

  final double value;
  final bool isEm;

  double resolve(double fontSize) => isEm ? value * fontSize : value;

  bool get isZero => value == 0;
}

class TitleInsets {
  const TitleInsets(this.top, this.right, this.bottom, this.left);

  static const zero = TitleInsets(TitleLen.zero, TitleLen.zero, TitleLen.zero, TitleLen.zero);

  final TitleLen top;
  final TitleLen right;
  final TitleLen bottom;
  final TitleLen left;

  EdgeInsets resolve(double fontSize) => EdgeInsets.fromLTRB(
    left.resolve(fontSize),
    top.resolve(fontSize),
    right.resolve(fontSize),
    bottom.resolve(fontSize),
  );

  bool get isZero =>
      top.isZero && right.isZero && bottom.isZero && left.isZero;
}

/// 解析后的样式（已处理继承）
class TitleCss {
  TitleCss();

  Color? color;
  double fontScale = 1.0;
  double? fontPx;
  FontWeight fontWeight = FontWeight.w400;
  FontStyle fontStyle = FontStyle.normal;
  TextAlign textAlign = TextAlign.left;
  double lineHeight = 1.35;
  TitleLen? letterSpacing;
  List<Shadow>? shadows;
  Color? background;
  String? backgroundImage;
  BoxFit backgroundFit = BoxFit.contain;
  Alignment backgroundAlign = Alignment.centerLeft;
  double borderRadius = 0;

  /// 四边边框宽度（px）。`border` 简写会一次设满四边；
  /// `border-bottom: 1px solid` 这种只设一边。
  double borderTop = 0;
  double borderRight = 0;
  double borderBottom = 0;
  double borderLeft = 0;

  /// 边框颜色（CSS 省略时按 currentColor = 文字颜色）
  Color? borderColor;

  /// `display:inline-block` / `float` ⇒ 盒子宽度收缩到内容；
  /// 其余（div/p/h1~h6 默认 block）⇒ 占满整行（对齐靠 text-align）。
  bool inlineBox = false;

  /// 0 = 不浮动；-1 = float:left（靠左）；1 = float:right（靠右）
  int floatSide = 0;

  TitleInsets margin = TitleInsets.zero;
  TitleInsets padding = TitleInsets.zero;
  List<BoxShadow> boxShadows = const [];
  bool underline = false;

  /// 当前元素的字号（px）= 绝对 px × [pxScale] ?? 基准字号 × 相对倍数
  ///
  /// [pxScale] 用于"整体缩放"：源阅读样式里常写死 `font-size:24px`，换手机
  /// 尺寸后完全不跟着变；由调用方传一个统一系数让 px 也随屏幕/用户设置缩放。
  double fontSize(double base, [double pxScale = 1.0]) =>
      fontPx == null ? base * fontScale : fontPx! * pxScale;

  /// 子节点继承用：只保留 CSS 里**可继承**的属性。
  ///
  /// 关键点：margin / padding / background / border / box-shadow **不可继承**
  /// （原来直接 `copy()` ⇒ 子块会重复画父块的底色和内衬，高度也算错）。
  TitleCss inheritFromParent() => TitleCss()
    ..color = color
    ..fontScale = fontScale
    ..fontPx = fontPx
    ..fontWeight = fontWeight
    ..fontStyle = fontStyle
    ..textAlign = textAlign
    ..lineHeight = lineHeight
    ..letterSpacing = letterSpacing
    ..shadows = shadows
    ..underline = underline;

  bool get hasDecoration =>
      background != null ||
      backgroundImage != null ||
      borderTop > 0 ||
      borderRight > 0 ||
      borderBottom > 0 ||
      borderLeft > 0 ||
      borderRadius > 0 ||
      boxShadows.isNotEmpty ||
      !padding.isZero;

  /// 实际内衬：把边框宽度折进 padding（Flutter 的 border 画在盒子内侧，
  /// 不折进去的话文字会压在边框上；度量与渲染共用这一个值）。
  EdgeInsets resolvedPadding(double fontSizePx) {
    final p = padding.resolve(fontSizePx);
    if (borderTop + borderRight + borderBottom + borderLeft <= 0) return p;
    return EdgeInsets.fromLTRB(
      p.left + borderLeft,
      p.top + borderTop,
      p.right + borderRight,
      p.bottom + borderBottom,
    );
  }
}

/// 编译 / 度量 / 渲染
class TitleHtml {
  TitleHtml._();

  static const _allowedTags = {
    'div',
    'p',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'span',
    'b',
    'strong',
    'i',
    'em',
    'section',
    'article',
    'center',
  };

  /// HTML → 文档树。[chapterNumber] 通常传章节序号（1 起）
  static TitleHtmlDoc compile(
    String source, {
    required String chapterNumber,
    required String chapterName,
  }) {
    final root = TitleBoxBlock(TitleCss(), <TitleBlock>[]);
    var src = source.trim();
    // 源阅读导出的标题样式常以 `cmt:` 开头（注释标记），不能当正文渲染出来
    if (src.toLowerCase().startsWith('cmt:')) {
      src = src.substring(4).trimLeft();
    }
    if (src.isEmpty) return TitleHtmlDoc(root);
    dom.DocumentFragment frag;
    try {
      frag = html_parser.parseFragment(src);
    } catch (_) {
      return TitleHtmlDoc(root);
    }
    root.children.addAll(
      _buildChildren(frag.nodes, root.style, chapterNumber, chapterName),
    );
    return TitleHtmlDoc(root);
  }

  static List<TitleBlock> _buildChildren(
    List<dom.Node> nodes,
    TitleCss parent,
    String number,
    String name,
  ) {
    final out = <TitleBlock>[];
    for (final node in nodes) {
      if (node is dom.Text) {
        // 「章节数」占位符**不渲染**（用户 2026-10-25：阅读界面左上角那枚孤立
        // 数字要去掉）。留空后，外层没装饰的盒子会被下面的空盒逻辑丢掉，
        // 不会多出一段空白。
        final text = _cleanText(node.text)
            .replaceAll('章节数', '')
            .replaceAll('章节名', name);
        if (text.isEmpty) continue;
        out.add(TitleTextBlock(parent.inheritFromParent(), text));
        continue;
      }
      if (node is! dom.Element) continue;
      final tag = node.localName?.toLowerCase() ?? '';
      if (tag == 'script' || tag == 'style' || tag == 'br') {
        if (tag == 'br') {
          out.add(TitleTextBlock(parent.inheritFromParent(), '\n'));
        }
        continue;
      }
      final css = _applyDecls(parent, node.attributes['style'], tag);
      // 「章节名」所在的盒子整体缩到 0.8：
      //   用户要的是"章节名称 + 外框一起小一号"，所以缩放必须作用在**盒子**
      //   的 fontScale 上 —— 内衬/圆角都是 em 推导的，跟着字号一起缩才协调。
      final ownText = node.nodes
          .whereType<dom.Text>()
          .map((t) => t.text)
          .join();
      // 整个盒子只装了「章节数」→ 连盒子一起去掉。
      //   否则像「古风·蓝章」那种给数字加了蓝底圆角的版式，会留下一个空药丸。
      if (ownText.contains('章节数') &&
          ownText.replaceAll('章节数', '').trim().isEmpty) {
        continue;
      }
      if (ownText.contains('章节名')) {
        css.fontScale = css.fontScale * 0.8;
        if (css.fontPx != null) css.fontPx = css.fontPx! * 0.8;
      }
      final kids = _buildChildren(node.nodes, css, number, name);
      if (!_allowedTags.contains(tag)) {
        // 不认识的标签：拍平（只保留子节点），不让样式丢失
        out.addAll(kids);
        continue;
      }
      // 占位符被替换成空串后（例如隐藏「章节数」），盒子里没有任何文字：
      // 直接丢掉，否则 margin / padding 会留下一段空白（右上角那种孤立数字消失后
      // 还会剩一个空行）。有背景/边框的装饰盒保留。
      if (kids.isEmpty &&
          css.background == null &&
          css.backgroundImage == null &&
          !css.hasDecoration) {
        continue;
      }
      out.add(TitleBoxBlock(css, kids));
    }
    return out;
  }

  static String _cleanText(String s) =>
      s.replaceAll(RegExp(r'[\s\u00a0]+'), ' ').trim();

  static Map<String, String> _parseDecls(String? style) {
    final out = <String, String>{};
    if (style == null || style.isEmpty) return out;
    for (final part in style.split(';')) {
      final i = part.indexOf(':');
      if (i <= 0) continue;
      final k = part.substring(0, i).trim().toLowerCase();
      final v = part.substring(i + 1).trim();
      if (k.isEmpty || v.isEmpty) continue;
      out[k] = v;
    }
    return out;
  }

  static TitleCss _applyDecls(TitleCss parent, String? style, String tag) {
    final css = parent.inheritFromParent();
    // 标签默认样式（h1~h6 粗体、p 上下留白）
    if (RegExp(r'^h[1-6]$').hasMatch(tag)) {
      css.fontWeight = FontWeight.w700;
    }
    final d = _parseDecls(style);
    for (final e in d.entries) {
      final k = e.key;
      final v = e.value.toLowerCase();
      switch (k) {
        case 'color':
          css.color = _color(e.value) ?? css.color;
        case 'background-color':
        case 'background':
          final c = _color(e.value);
          if (c != null) css.background = c;
        case 'background-image':
          final url = _url(e.value);
          if (url != null) css.backgroundImage = url;
        case 'background-repeat':
          // no-repeat / repeat 都不影响我们的布局（默认不重复）
          break;
        case 'background-position':
          css.backgroundAlign = v.contains('right')
              ? Alignment.centerRight
              : (v.contains('center')
                    ? Alignment.center
                    : Alignment.centerLeft);
        case 'background-size':
          // ⚠️ `auto 100%` 是标题样式里最常见的写法（高撑满、宽按比例），
          // 对应 Flutter 的 **fitHeight**，不是 contain —— 用 contain 会把整张图
          // 缩进盒子里（宽高都受约束），表现就是"图变小了、位置也不对"。
          css.backgroundFit = v.contains('cover')
              ? BoxFit.cover
              : (v.contains('100%') && v.contains('auto')
                  ? BoxFit.fitHeight
                  : (v.contains('contain')
                      ? BoxFit.contain
                      : BoxFit.fitHeight));
        case 'font-size':
          final m = _numUnit(e.value);
          if (m != null) {
            if (m.$2 == 'px') {
              css.fontPx = m.$1;
            } else if (m.$2 == '%') {
              css.fontScale = parent.fontScale * m.$1 / 100;
              css.fontPx = null;
            } else {
              // em / rem / 无单位
              css.fontScale = parent.fontScale * m.$1;
              css.fontPx = null;
            }
          }
        case 'font-weight':
          css.fontWeight = _weight(v) ?? css.fontWeight;
        case 'font-style':
          css.fontStyle = v.contains('italic')
              ? FontStyle.italic
              : FontStyle.normal;
        case 'text-align':
          css.textAlign = v.contains('center')
              ? TextAlign.center
              : (v.contains('right')
                    ? TextAlign.right
                    : (v.contains('justify') ? TextAlign.justify : TextAlign.left));
        case 'line-height':
          final m = _numUnit(e.value);
          if (m != null) {
            if (m.$2.isEmpty) {
              css.lineHeight = m.$1 <= 4 ? m.$1 : m.$1 / 16;
            } else if (m.$2 == 'px') {
              css.lineHeight = m.$1 / 16;
            } else if (m.$2 == '%') {
              css.lineHeight = m.$1 / 100;
            } else {
              css.lineHeight = m.$1; // em：相对字号
            }
          }
        case 'letter-spacing':
          final m = _numUnit(e.value);
          if (m != null) {
            css.letterSpacing = TitleLen(
              m.$1,
              isEm: m.$2 != 'px',
            );
          }
        case 'text-decoration':
          css.underline = v.contains('underline');
        case 'text-shadow':
          final sh = _textShadow(e.value);
          if (sh != null) css.shadows = [sh];
        case 'margin':
          css.margin = _insets(e.value, css.margin);
        case 'margin-top':
          css.margin = _oneSide(css.margin, e.value, 0);
        case 'margin-right':
          css.margin = _oneSide(css.margin, e.value, 1);
        case 'margin-bottom':
          css.margin = _oneSide(css.margin, e.value, 2);
        case 'margin-left':
          css.margin = _oneSide(css.margin, e.value, 3);
        case 'padding':
          css.padding = _insets(e.value, css.padding);
        case 'padding-top':
          css.padding = _oneSide(css.padding, e.value, 0);
        case 'padding-right':
          css.padding = _oneSide(css.padding, e.value, 1);
        case 'padding-bottom':
          css.padding = _oneSide(css.padding, e.value, 2);
        case 'padding-left':
          css.padding = _oneSide(css.padding, e.value, 3);
        case 'border-radius':
          final m = _numUnit(e.value);
          if (m != null) css.borderRadius = m.$1;
        case 'border':
          final w = _borderWidth(e.value);
          if (w != null) {
            css.borderTop = w;
            css.borderRight = w;
            css.borderBottom = w;
            css.borderLeft = w;
          }
          final c = _color(e.value);
          if (c != null) css.borderColor = c;
        case 'border-top':
        case 'border-bottom':
        case 'border-left':
        case 'border-right':
          final w = _borderWidth(e.value) ?? 0;
          switch (k) {
            case 'border-top':
              css.borderTop = w;
            case 'border-right':
              css.borderRight = w;
            case 'border-bottom':
              css.borderBottom = w;
            case 'border-left':
              css.borderLeft = w;
          }
          final c = _color(e.value);
          if (c != null) css.borderColor = c;
        case 'float':
          if (v.contains('left')) {
            css.inlineBox = true;
            css.floatSide = -1;
          } else if (v.contains('right')) {
            css.inlineBox = true;
            css.floatSide = 1;
          }
        case 'display':
          // inline / inline-block 都按"宽度收缩到内容"处理；
          // block / flex 等仍按块级（占满整行）
          css.inlineBox = v.contains('inline');
        case 'box-shadow':
          final bs = _boxShadows(e.value);
          if (bs.isNotEmpty) css.boxShadows = bs;
      }
    }
    return css;
  }

  // ── 值解析 ────────────────────────────────────────────────

  /// 数值 + 单位（em / px / % / 空）
  static (double, String)? _numUnit(String raw) {
    final m = RegExp(
      r'^(-?[\d.]+)\s*(em|rem|px|%)?$',
    ).firstMatch(raw.trim().toLowerCase());
    if (m == null) return null;
    final n = double.tryParse(m.group(1)!);
    if (n == null) return null;
    final unit = (m.group(2) ?? '').replaceAll('rem', 'em');
    return (n, unit);
  }

  /// 边框宽度（`2px` / `thin` / `medium` / `thick`）
  static double? _borderWidth(String raw) {
    final v = raw.trim().toLowerCase();
    final m = RegExp(r'(-?[\d.]+)\s*px').firstMatch(v);
    if (m != null) return double.tryParse(m.group(1)!);
    if (v.contains('thin')) return 1;
    if (v.contains('medium')) return 3;
    if (v.contains('thick')) return 5;
    // 只写了 `1px` 以外的单位（em）时按 px 估
    final em = RegExp(r'(-?[\d.]+)\s*em').firstMatch(v);
    if (em != null) return (double.tryParse(em.group(1)!) ?? 0) * 16;
    return null;
  }

  static FontWeight? _weight(String v) {
    if (v.contains('bold')) return FontWeight.w700;
    if (v.contains('lighter') || v.contains('light')) return FontWeight.w300;
    if (v.contains('normal')) return FontWeight.w400;
    if (v.contains('bolder')) return FontWeight.w800;
    final n = int.tryParse(RegExp(r'\d{3}').firstMatch(v)?.group(0) ?? '');
    if (n == null) return null;
    return FontWeight.values[((n ~/ 100) - 1).clamp(0, 8)];
  }

  static TitleInsets _insets(String raw, TitleInsets fallback) {
    final parts = raw
        .trim()
        .split(RegExp(r'\s+'))
        .map(_len)
        .whereType<TitleLen>()
        .toList();
    if (parts.isEmpty) return fallback;
    return switch (parts.length) {
      1 => TitleInsets(parts[0], parts[0], parts[0], parts[0]),
      2 => TitleInsets(parts[0], parts[1], parts[0], parts[1]),
      3 => TitleInsets(parts[0], parts[1], parts[2], parts[1]),
      _ => TitleInsets(parts[0], parts[1], parts[2], parts[3]),
    };
  }

  static TitleInsets _oneSide(TitleInsets base, String raw, int side) {
    final l = _len(raw);
    if (l == null) return base;
    return switch (side) {
      0 => TitleInsets(l, base.right, base.bottom, base.left),
      1 => TitleInsets(base.top, l, base.bottom, base.left),
      2 => TitleInsets(base.top, base.right, l, base.left),
      _ => TitleInsets(base.top, base.right, base.bottom, l),
    };
  }

  static TitleLen? _len(String raw) {
    final m = _numUnit(raw);
    if (m == null) return null;
    return TitleLen(m.$1, isEm: m.$2 != 'px');
  }

  static Color? _color(String raw) {
    var s = raw.trim().toLowerCase();
    // 取出第一个像颜色的 token（border / shadow 里混着长度）
    final hex = RegExp(r'#[0-9a-f]{3,8}').firstMatch(s)?.group(0);
    if (hex != null) {
      var h = hex.substring(1);
      if (h.length == 3) {
        h = h.split('').map((c) => '$c$c').join();
      }
      final v = int.tryParse(h, radix: 16);
      if (v == null) return null;
      if (h.length == 6) return Color(0xFF000000 | v);
      // CSS 8 位是 #rrggbbaa；转成 Flutter 的 #aarrggbb
      if (h.length == 8) {
        final a = v & 0xFF;
        final r = (v >> 24) & 0xFF;
        final g = (v >> 16) & 0xFF;
        final b = (v >> 8) & 0xFF;
        return Color.fromARGB(a, r, g, b);
      }
      return null;
    }
    final rgba = RegExp(
      r'rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)(?:\s*,\s*([\d.]+))?\s*\)',
    ).firstMatch(s);
    if (rgba != null) {
      final r = (double.tryParse(rgba.group(1)!) ?? 0).round();
      final g = (double.tryParse(rgba.group(2)!) ?? 0).round();
      final b = (double.tryParse(rgba.group(3)!) ?? 0).round();
      final a = ((double.tryParse(rgba.group(4) ?? '1') ?? 1) * 255)
          .round()
          .clamp(0, 255);
      return Color.fromARGB(a, r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255));
    }
    const named = {
      'white': Color(0xFFFFFFFF),
      'black': Color(0xFF000000),
      'red': Color(0xFFFF0000),
      'green': Color(0xFF008000),
      'blue': Color(0xFF0000FF),
      'gray': Color(0xFF808080),
      'grey': Color(0xFF808080),
      'silver': Color(0xFFC0C0C0),
      'transparent': Color(0x00000000),
      'currentcolor': Color(0xFF1A1A1A),
    };
    for (final e in named.entries) {
      if (s.startsWith(e.key)) return e.value;
    }
    return null;
  }

  static String? _url(String raw) {
    final m = RegExp(r'url\(([^)]*)\)', caseSensitive: false).firstMatch(raw);
    if (m == null) return null;
    var v = m.group(1)!.trim();
    // 去掉引号 / 反引号 / 空白（用户从聊天里复制时常见 `url('`https://…`')`）
    v = v.replaceAll(RegExp(r'''^['"`\s]+|['"`\s]+$'''), '');
    v = v.replaceAll('`', '').trim();
    return v.isEmpty ? null : v;
  }

  /// 取出文本里所有数字（先把 `#rrggbb` 颜色剔掉，否则颜色值会被当成数字）
  static List<double> _numbers(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'#[0-9a-fA-F]{3,8}'), ' ');
    return [
      for (final m in RegExp(r'-?\d+(?:\.\d+)?').allMatches(cleaned))
        double.tryParse(m.group(0)!) ?? 0,
    ];
  }

  static Shadow? _textShadow(String raw) {
    final nums = _numbers(raw);
    if (nums.isEmpty) return null;
    final dx = nums[0];
    final dy = nums.length > 1 ? nums[1] : 0.0;
    final blur = nums.length > 2 ? nums[2] : 0.0;
    final c = _color(raw) ?? const Color(0x66000000);
    return Shadow(offset: Offset(dx, dy), blurRadius: blur, color: c);
  }

  static List<BoxShadow> _boxShadows(String raw) {
    final out = <BoxShadow>[];
    for (final part in raw.split(',')) {
      if (part.trim().isEmpty) continue;
      final nums = _numbers(part);
      if (nums.isEmpty) continue;
      double val(int i) => i < nums.length ? nums[i] : 0;
      out.add(
        BoxShadow(
          offset: Offset(val(0), val(1)),
          blurRadius: val(2),
          spreadRadius: val(3),
          color: _color(part) ?? const Color(0x33000000),
        ),
      );
    }
    return out;
  }

  // ── 度量（与渲染同参，保证分页一致）──────────────────────

  /// 量出整块标题的高度（含 margin / padding）
  ///
  /// [fontFamily]：阅读器当前的自定义字体（源阅读样式里的 `font-family` 我们
  /// 拿不到对应文件，就用阅读器字体兜底 —— 与渲染必须同参）。
  static double measure(
    TitleHtmlDoc doc, {
    required double width,
    required double baseFontSize,
    required TextScaler textScaler,
    String? fontFamily,
    double pxScale = 1.0,
  }) {
    var h = 0.0;
    for (final b in doc.root.children) {
      h += _measureBlock(
        b,
        width,
        baseFontSize,
        textScaler,
        fontFamily,
        pxScale,
      );
    }
    return h;
  }

  static double _measureBlock(
    TitleBlock b,
    double width,
    double base,
    TextScaler textScaler,
    String? fontFamily,
    double pxScale,
  ) {
    final fs = b.style.fontSize(base, pxScale).clamp(base * 0.5, base * 1.4);
    final pad = b.style.resolvedPadding(fs);
    final mar = b.style.margin.resolve(fs);
    final innerW = (width - pad.horizontal - mar.horizontal)
        .clamp(1.0, width)
        .toDouble();
    double contentH;
    if (b is TitleTextBlock) {
      final tp = TextPainter(
        text: TextSpan(
          text: b.text,
          style: b.style.textStyle(fs, fontFamily: fontFamily),
        ),
        strutStyle: StrutStyle(
          fontFamily: fontFamily,
          fontSize: fs,
          height: b.style.lineHeight,
          forceStrutHeight: true,
        ),
        textAlign: b.style.textAlign,
        textScaler: textScaler,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: innerW);
      contentH = tp.height;
    } else {
      contentH = 0;
      for (final c in (b as TitleBoxBlock).children) {
        contentH += _measureBlock(
          c,
          innerW,
          base,
          textScaler,
          fontFamily,
          pxScale,
        );
      }
    }
    return mar.vertical + pad.vertical + contentH;
  }

  // ── 渲染 ──────────────────────────────────────────────────

  static Widget build(
    TitleHtmlDoc doc, {
    required double baseFontSize,
    required Color fallbackColor,
    String? fontFamily,
    double pxScale = 1.0,
  }) {
    return Column(
      // ⚠️ 不能用 stretch：`display:inline-block` 的药丸会被拉满整行。
      // 块级子节点在 [_buildBlock] 里自己撑满宽度（SizedBox infinity）。
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final b in doc.root.children)
          _buildBlock(b, baseFontSize, fallbackColor, fontFamily, pxScale),
      ],
    );
  }

  static Widget _buildBlock(
    TitleBlock b,
    double base,
    Color fallbackColor,
    String? fontFamily,
    double pxScale,
  ) {
    final fs = b.style.fontSize(base, pxScale).clamp(base * 0.5, base * 1.4);
    final pad = b.style.resolvedPadding(fs);
    final mar = b.style.margin.resolve(fs);
    Widget child;
    if (b is TitleTextBlock) {
      child = Text(
        b.text,
        textAlign: b.style.textAlign,
        style: b.style.textStyle(
          fs,
          fallback: fallbackColor,
          fontFamily: fontFamily,
        ),
        strutStyle: StrutStyle(
          fontFamily: fontFamily,
          fontSize: fs,
          height: b.style.lineHeight,
          forceStrutHeight: true,
        ),
      );
    } else {
      child = Column(
        crossAxisAlignment: _cross(b.style.textAlign),
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final c in (b as TitleBoxBlock).children)
            _buildBlock(c, base, fallbackColor, fontFamily, pxScale),
        ],
      );
    }
    final st = b.style;
    final border = _border(st, fallback: st.color ?? fallbackColor);
    if (st.hasDecoration) {
      child = Container(
        padding: pad,
        decoration: BoxDecoration(
          color: st.background,
          borderRadius: st.borderRadius > 0
              ? BorderRadius.circular(st.borderRadius)
              : null,
          border: border,
          boxShadow: st.boxShadows.isEmpty ? null : st.boxShadows,
          image: _bgImage(st),
        ),
        child: child,
      );
    } else if (pad != EdgeInsets.zero) {
      child = Padding(padding: pad, child: child);
    }
    // 浮动的盒子：自己决定靠左/靠右（父级的 text-align 管不到它）
    if (st.floatSide != 0) {
      child = Align(
        alignment: st.floatSide < 0
            ? Alignment.centerLeft
            : Alignment.centerRight,
        child: child,
      );
    } else if (!st.inlineBox && !_looksPill(st) && b is TitleBoxBlock) {
      // 块级元素（div / p / h1~h6 默认值）占满整行 ⇒ 底部边框、居中对齐才正确；
      // inline-block / float 才收缩到文字宽度。
      //
      // 例外：**带圆角的实心盒子**（胶囊/药丸）即便没写 display:inline-block，
      // 也按收缩处理 —— 中文标题样式里大量用 `<h4 style="background:...;
      // border-radius:16px">章节名</h4>` 做药丸，撑满整行会变成一条长条
      // （用户 2026-10-25 截图对比：参考图是收缩胶囊，我们这边被拉成整行）。
      child = SizedBox(width: double.infinity, child: child);
    }
    if (mar != EdgeInsets.zero) child = Padding(padding: mar, child: child);
    return child;
  }

  /// 是否是"圆角实心胶囊"（章节名药丸）。
  ///
  /// 判据：有圆角 + 有背景（色或图）。这类盒子按内容收缩才像药丸；
  /// 撑满整行会变成一条通栏色带（参考图 vs 实际截图的核心差异）。
  static bool _looksPill(TitleCss st) =>
      st.borderRadius > 0 && (st.background != null || st.backgroundImage != null);

  /// 按边生成边框；颜色缺省 = currentColor（文字颜色）
  static Border? _border(TitleCss st, {required Color fallback}) {
    BorderSide side(double w) => w > 0
        ? BorderSide(color: st.borderColor ?? fallback, width: w)
        : BorderSide.none;
    if (st.borderTop <= 0 &&
        st.borderRight <= 0 &&
        st.borderBottom <= 0 &&
        st.borderLeft <= 0) {
      return null;
    }
    return Border(
      top: side(st.borderTop),
      right: side(st.borderRight),
      bottom: side(st.borderBottom),
      left: side(st.borderLeft),
    );
  }

  static CrossAxisAlignment _cross(TextAlign align) => switch (align) {
    TextAlign.center => CrossAxisAlignment.center,
    TextAlign.right || TextAlign.end => CrossAxisAlignment.end,
    _ => CrossAxisAlignment.start,
  };

  static DecorationImage? _bgImage(TitleCss style) {
    final src = style.backgroundImage;
    if (src == null || src.isEmpty) return null;
    final provider = _provider(src);
    if (provider == null) return null;
    return DecorationImage(
      image: provider,
      fit: style.backgroundFit,
      alignment: style.backgroundAlign,
      repeat: ImageRepeat.noRepeat,
    );
  }

  static final Map<String, ImageProvider> _providerCache = {};

  static ImageProvider? _provider(String src) {
    final hit = _providerCache[src];
    if (hit != null) return hit;
    ImageProvider? p;
    if (src.startsWith('data:image')) {
      final i = src.indexOf('base64,');
      if (i > 0) {
        try {
          final bytes = base64Decode(src.substring(i + 7));
          p = MemoryImage(Uint8List.fromList(bytes));
        } catch (_) {}
      }
    } else if (src.startsWith('http://') || src.startsWith('https://')) {
      p = CachedNetworkImageProvider(src);
    } else if (src.startsWith('asset:')) {
      p = AssetImage(src.substring(6));
    } else if (src.startsWith('assets/')) {
      p = AssetImage(src);
    } else {
      p = AssetImage(src);
    }
    if (p != null) _providerCache[src] = p;
    return p;
  }
}

extension on TitleCss {
  TextStyle textStyle(double fs, {Color? fallback, String? fontFamily}) =>
      TextStyle(
        fontFamily: fontFamily,
        fontSize: fs,
        height: lineHeight,
        color: color ?? fallback,
        fontWeight: fontWeight,
        fontStyle: fontStyle,
        letterSpacing: letterSpacing?.resolve(fs),
        shadows: shadows,
        decoration: underline ? TextDecoration.underline : null,
      );
}
