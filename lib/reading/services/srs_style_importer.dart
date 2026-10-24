import 'dart:convert';
import 'dart:typed_data';

import '../models/reader_style.dart';

/// 源阅读 `.srs` 样式导入。
///
/// 编码链路（用户 2026 确认，并与解密结果实测一致）：
///   `JSON → Base64 → 逐字节 XOR 0x60`
/// 反过来：每字节 ^0x60 → Base64 解码 → JSON。
///
/// 解出来的 JSON 结构：
/// ```json
/// {
///   "style": {
///     "id": 1632468268.54,
///     "name": "源阅读-古风·侠客江湖",
///     "config": {
///       "textSize": 19, "lineSpacingExtra": 19, "letterSpacing": 0.2,
///       "paragraphSpacing": 19, "paragraphIndent": "\u3000\u3000",
///       "paddingLeft": 25, "paddingRight": 25, "paddingTop": 14,
///       "paddingBottom": 14, "headerPaddingTop": 48, "footerPaddingBottom": 28,
///       "textColor": "#394554", "textColorNight": "#97897A",
///       "bgType": 2, "bgStr": "custom_xxx.png",
///       "titleStyleHtml": "cmt:<div …>章节数</div>…",
///       "titleStyleHtmlNight": "…",
///       "topComponent": {"items":[…]}, "bottomComponent": {"items":[…]}
///     }
///   },
///   "dayBGImageData": "<base64 PNG>",
///   "nightBGImageData": "<base64 PNG>",
///   "fontData": "<base64 字体>"
/// }
/// ```
///
/// 已知取舍：
///   · **字体**（`fontData` + `textFontName`）不导入 —— 阅读器目前不支持自定义字体；
///   · **日/夜两套背景图**只取当前模式那一张（我们的自定义背景是单张）；
///   · 页眉页脚组件按 `alignment`（0 左 / 1 中 / 2 右）归并到我方三个格式串位置，
///     **每个组件的颜色**不保留（统一跟随主题文字色）；
///   · `batteryIcon` 这类"图形组件"无法用文本格式串表达，跳过（保留 `batteryRate`）。
class SrsStyleImporter {
  SrsStyleImporter._();

  /// 把 `.srs` 字节还原成 JSON 文本；也兼容已经是明文 JSON 的 `.decrypted.json`
  static String? decodeToJsonText(List<int> bytes) {
    if (bytes.isEmpty) return null;
    final head = utf8.decode(bytes.take(16).toList(), allowMalformed: true);
    final trimmedHead = head.replaceFirst('\uFEFF', '').trimLeft();
    if (trimmedHead.startsWith('{') || trimmedHead.startsWith('[')) {
      return utf8.decode(bytes, allowMalformed: true);
    }
    // XOR 0x60
    final x = Uint8List(bytes.length);
    for (var i = 0; i < bytes.length; i++) {
      x[i] = bytes[i] ^ 0x60;
    }
    final text = utf8.decode(x, allowMalformed: true).trim();
    if (text.startsWith('{') || text.startsWith('[')) return text;
    try {
      final raw = base64Decode(text.replaceAll(RegExp(r'\s'), ''));
      return utf8.decode(raw, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? parse(List<int> bytes) {
    final text = decodeToJsonText(bytes);
    if (text == null) return null;
    try {
      final map = jsonDecode(text);
      return map is Map ? Map<String, dynamic>.from(map) : null;
    } catch (_) {
      return null;
    }
  }

  /// 内嵌背景图（base64 → 字节），没有返回 null
  static Uint8List? backgroundBytes(
    Map<String, dynamic> json, {
    required bool night,
  }) {
    final v = json[night ? 'nightBGImageData' : 'dayBGImageData'];
    if (v is! String || v.trim().isEmpty) return null;
    try {
      return base64Decode(v.trim());
    } catch (_) {
      return null;
    }
  }

  /// 内嵌字体（base64 TTF/OTF），没有返回 null
  static Uint8List? fontBytes(Map<String, dynamic> json) {
    final v = json['fontData'];
    if (v is! String || v.trim().isEmpty) return null;
    try {
      return base64Decode(v.trim());
    } catch (_) {
      return null;
    }
  }

  /// 字体显示名（config.textFontName，如 `DFPNewChuan-B5`）
  static String? fontName(Map<String, dynamic> json) {
    final s = json['style'];
    if (s is Map) {
      final c = s['config'];
      if (c is Map) {
        final n = c['textFontName'];
        if (n is String && n.trim().isNotEmpty) return n.trim();
      }
    }
    return null;
  }

  /// 转成我们的 [ReaderStyle]。
  ///
  /// [bgImagePath] 是调用方已经把背景图落盘后的本地路径（没有就传 null）。
  static ReaderStyle toReaderStyle(
    Map<String, dynamic> json, {
    required String id,
    required bool night,
    String? bgImagePath,
    String? fontId,
  }) {
    final styleMap = json['style'];
    Map<String, dynamic> cfg = {};
    var name = '源阅读样式';
    if (styleMap is Map) {
      final n = styleMap['name'];
      if (n is String && n.trim().isNotEmpty) name = n.trim();
      final c = styleMap['config'];
      if (c is Map) cfg = Map<String, dynamic>.from(c);
    }

    double d(String k, double fallback) {
      final v = cfg[k];
      if (v is num) return v.toDouble();
      return fallback;
    }

    int? colorOf(String key) {
      final v = cfg[key];
      return v is String ? _hex(v) : null;
    }

    final fs = d('textSize', 19).clamp(12.0, 30.0);
    // 行高：源阅读是"在字号之外额外加多少 px"，这里折成倍数
    final lh = (1 + d('lineSpacingExtra', 0) / fs).clamp(1.05, 3.0);
    // 字距：源阅读是 em（Android Paint.letterSpacing 也是 em）⇒ × 字号
    final ls = (d('letterSpacing', 0) * fs).clamp(-2.0, 8.0);
    // 段距：源阅读是 px，我们的是"字号倍数"
    final ps = (d('paragraphSpacing', 0) / fs).clamp(0.0, 2.0);
    final indentStr = (cfg['paragraphIndent'] as String?) ?? '';
    final indent = indentStr.length.clamp(0, 4).toDouble();

    final bgType = night
        ? ((cfg['bgTypeNight'] as num?)?.toInt() ??
              (cfg['bgType'] as num?)?.toInt() ??
              0)
        : ((cfg['bgType'] as num?)?.toInt() ?? 0);
    final bgStr = (night ? cfg['bgStrNight'] : cfg['bgStr']) as String?;
    final bgColor = bgType == 2 ? null : (bgStr == null ? null : _hex(bgStr));

    final titleHtml = (night
            ? (cfg['titleStyleHtmlNight'] ?? cfg['titleStyleHtml'])
            : cfg['titleStyleHtml']) as String?;
    final cleanHtml = _stripComment(titleHtml);

    final header = _componentFormats(cfg['topComponent']);
    final footer = _componentFormats(cfg['bottomComponent']);

    return ReaderStyle(
      id: id,
      name: name,
      builtin: false,
      bgIndex: night ? 5 : 3,
      dayBgIndex: 3,
      bgColor: bgColor,
      bgColorNight: night ? null : _hexOf(cfg['bgStrNight']),
      fgColor: (night ? colorOf('textColorNight') : colorOf('textColor')),
      fgColorNight: colorOf('textColorNight'),
      bgImagePath: bgImagePath,
      fontSize: fs,
      lineHeight: lh,
      letterSpacing: ls,
      fontWeight: 400 + (d('textBold', 0) * 100).clamp(0, 500),
      fontId: fontId ?? '',
      paraSpacing: ps,
      indent: indent,
      padLeft: d('paddingLeft', 20).clamp(0.0, 80.0),
      padRight: d('paddingRight', 20).clamp(0.0, 80.0),
      padTop: d('paddingTop', 16).clamp(0.0, 120.0),
      padBottom: d('paddingBottom', 40).clamp(0.0, 120.0),
      headerPadTop: d('headerPaddingTop', 0).clamp(0.0, 80.0),
      footerPadBottom: d('footerPaddingBottom', 6).clamp(0.0, 80.0),
      headerL: header.$1,
      headerC: header.$2,
      headerR: header.$3,
      footerL: footer.$1,
      footerC: footer.$2,
      footerR: footer.$3,
      chapterTitleStyle: cleanHtml.isEmpty ? '' : 'custom',
      chapterTitleHtml: cleanHtml,
      titleFontSize: (cfg['titleSize'] as num?)?.toDouble(),
      titleBold: ((cfg['titleBold'] as num?)?.toDouble() ?? 0) >= 0,
      pageMode: 'slide',
    );
  }

  /// 去掉模板开头的 `cmt:` 注释标记（源阅读里表示"这是一条注释/说明"）
  static String _stripComment(String? html) {
    if (html == null) return '';
    var s = html.trim();
    if (s.toLowerCase().startsWith('cmt:')) {
      s = s.substring(4).trimLeft();
    }
    return s;
  }

  /// `#RRGGBB` / `#RGB` → ARGB 整数
  static int? _hex(String raw) {
    var s = raw.trim();
    if (!s.startsWith('#')) return null;
    s = s.substring(1);
    if (s.length == 3) {
      s = s.split('').map((c) => '$c$c').join();
    }
    if (s.length != 6) return null;
    final v = int.tryParse(s, radix: 16);
    return v == null ? null : (0xFF000000 | v);
  }

  static int? _hexOf(Object? v) => v is String ? _hex(v) : null;

  /// 组件列表 → 左 / 中 / 右 三条格式串
  ///
  /// `alignment`：0 左 / 1 中 / 2 右；同位置的多个组件用空格拼接。
  static (String, String, String) _componentFormats(dynamic comp) {
    final slots = <int, List<String>>{0: [], 1: [], 2: []};
    if (comp is Map) {
      final items = comp['items'];
      if (items is List) {
        for (final it in items) {
          if (it is! Map) continue;
          final token = _tokenFor(it);
          if (token.isEmpty) continue;
          final a = (it['alignment'] as num?)?.toInt() ?? 0;
          slots[a.clamp(0, 2)]!.add(token);
        }
      }
    }
    String join(int i) => slots[i]!.join('');
    return (join(0), join(1), join(2));
  }

  /// 单个组件 → 我们的格式串变量（保留 db 里的 `format` 字面文字）
  static String _tokenFor(Map item) {
    final type = (item['type'] as String?) ?? '';
    final format = (item['format'] as String?) ?? '#';
    final token = switch (type) {
      'chapterTitle' => '#',
      'pageNO' => 'p',
      'readProgress' => '%',
      'time' => 't',
      'batteryRate' => 'n',
      'chapterNO' => 'c',
      'chapterCount' => 'C',
      'totalChapterCount' => 'C',
      'bookName' => 'B',
      _ => null,
    };
    if (token == null) {
      // author / 自定义文案：format 本身就是字面文本
      return format == '#' ? '' : format;
    }
    var s = format.replaceAll('#', token);
    // `%` 本身已带百分号（`72%`），db 里 `#%` 的 `%` 是字面量 ⇒ 去掉重复
    if (type == 'readProgress' && s.endsWith('%')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}
