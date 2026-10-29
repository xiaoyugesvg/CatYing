// lib/services/xbpq/xbpq_rule.dart
//
// XBPQ 规则模型 + 解析/归一化。
// 对齐 huoyi `native/core/provider_xbpq.go` 的
// `xbpqRule` / `parseXBPQRule` / `xbpqNormalizeKey` / `xbpqNormalizeValue`
// / `field` / `homeURL` / `userAgent`。
//
// 说明：模板补齐（Go `xbpqApplyTemplate`）见 xbpq_template.dart，在 parse 末尾调用。

import 'dart:convert';

import 'package:tvbox/services/xbpq/xbpq_template.dart';
import 'package:tvbox/services/xbpq/xbpq_util.dart';

class XbpqRule {
  /// 归一化键（去空白、全角括号转半角）→ 值。
  final Map<String, String> fields;

  /// 原始键顺序（导入导出保真用）。
  final List<String> order;

  const XbpqRule(this.fields, this.order);

  /// 归一化字段名：全角方括号转半角、去空白。
  static String normalizeKey(String key) {
    var k = key.trim();
    k = k.replaceAll('〔', '[').replaceAll('〕', ']');
    return k.replaceAll(RegExp(r'[ \t\n\r]'), '');
  }

  static String normalizeValue(String value) =>
      value.replaceAll('〔', '[').replaceAll('〕', ']').trim();

  /// 依次尝试多个字段名（含 XBPQ 常见别名）。
  String field(List<String> names) {
    for (final name in names) {
      final v = fields[normalizeKey(name)];
      if (v != null && v.isNotEmpty) return v;
    }
    return '';
  }

  /// 主页地址（含从 分类url/搜索url 推导站点根）。
  String get homeUrl {
    var value = field(['主页url', '首页url', '请求']);
    if (value.isEmpty) {
      for (final alt in ['分类url', '分类Url', '搜索url']) {
        final category = field([alt]);
        if (category.startsWith('http')) {
          value = XbpqUtil.hostOrigin(category);
          break;
        }
      }
    }
    if (value.isEmpty) return '';
    if (!value.contains('://')) value = 'https://$value';
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty) return '';
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return '${uri.scheme}://${uri.authority}$path';
  }

  /// 请求头里的 UA。
  String get userAgent {
    var value = field(['请求头', 'User-Agent', 'UA']);
    if (value.isEmpty) return '';
    final lower = value.toLowerCase();
    final index = lower.indexOf('user-agent');
    if (index >= 0) {
      value = value.substring(index + 'user-agent'.length).trim();
      value = value.replaceFirst(RegExp(r'^[\$:：=\s]+'), '');
      final parts =
          value.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
      if (parts.length == 1) value = parts.first;
    }
    if (value.isEmpty ||
        value.length > 240 ||
        value.contains(RegExp(r'[\r\n\x00]'))) {
      return '';
    }
    return value;
  }

  /// 解析爬虫 JSON 文本；识别成功返回规则，否则 null。
  ///
  /// 兼容形态：整体对象、`[{对象}]` 数组、`@long-text:` 拼接片段。
  static XbpqRule? parse(String text) {
    var t = text.trim();
    if (t.isEmpty) return null;

    final lt = t.indexOf('@long-text:');
    if (lt >= 0) {
      final head = trimTrailingComma(t.substring(0, lt));
      final tail = t.substring(lt);
      if (_jsonValid(head)) {
        final embedded = _extractLongText(tail);
        if (embedded.isNotEmpty) {
          final merged = _mergeLongText(head, embedded);
          if (merged.isNotEmpty) t = merged;
        }
      }
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(t);
    } catch (_) {
      try {
        decoded = jsonDecode(trimTrailingComma(t));
      } catch (_) {
        return null;
      }
    }

    final fields = <String, String>{};
    final order = <String>[];
    void collect(Map node) {
      node.forEach((key, value) {
        final nk = normalizeKey(key.toString());
        if (nk.isEmpty) return;
        final nv = normalizeValue(XbpqUtil.stringValue(value));
        if (!fields.containsKey(nk)) order.add(nk);
        fields[nk] = nv;
      });
    }

    if (decoded is Map) {
      collect(decoded);
    } else if (decoded is List) {
      for (final e in decoded) {
        if (e is Map) collect(e);
      }
    } else {
      return null;
    }

    final looksXbpq = (fields['主页url'] ?? '').isNotEmpty ||
        (fields['首页url'] ?? '').isNotEmpty ||
        (fields['请求'] ?? '').isNotEmpty ||
        (fields['分类url'] ?? '').isNotEmpty ||
        (fields['分类Url'] ?? '').isNotEmpty;
    if (!looksXbpq) return null;

    // 简写支持：按 分类url 形态补齐内置模板（对齐 jar / Go 同名调用）。
    XbpqTemplate.apply(fields, order);
    return XbpqRule(fields, order);
  }

  static final RegExp _trailingComma = RegExp(r',\s*([}\]])');

  /// 去掉 JSON 尾部多余逗号（爬虫导出里很常见）。
  static String trimTrailingComma(String text) {
    while (true) {
      final cleaned =
          text.replaceAllMapped(_trailingComma, (m) => m.group(1) ?? '');
      if (cleaned == text) return text;
      text = cleaned;
    }
  }

  static final RegExp _longTextPattern =
      RegExp(r'@long-text:\s*"((?:[^"\\]|\\.)*)"\s*;?\s*$', dotAll: true);

  static String _extractLongText(String tail) {
    final m = _longTextPattern.firstMatch(tail.trim());
    if (m == null || m.groupCount < 1) return '';
    final raw = m.group(1);
    if (raw == null) return '';
    try {
      final decoded = jsonDecode('"$raw"');
      return decoded is String ? decoded : '';
    } catch (_) {
      return '';
    }
  }

  static bool _jsonValid(String text) {
    try {
      jsonDecode(text);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 把 long-text 中的附加字段合并进主 JSON（同键以主 JSON 优先）。
  static String _mergeLongText(String head, String embedded) {
    dynamic headNode;
    dynamic embeddedNode;
    try {
      headNode = jsonDecode(head);
    } catch (_) {
      return '';
    }
    try {
      embeddedNode = jsonDecode(embedded);
    } catch (_) {
      return head;
    }
    if (headNode is! Map) return '';
    if (embeddedNode is! Map) return head;
    for (final key in embeddedNode.keys) {
      if (!headNode.containsKey(key)) headNode[key] = embeddedNode[key];
    }
    try {
      return jsonEncode(headNode);
    } catch (_) {
      return head;
    }
  }
}
