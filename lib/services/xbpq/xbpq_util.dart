// lib/services/xbpq/xbpq_util.dart
//
// XBPQ 公共小工具（rule / cut / selector 共用）。
//
// 放在这一层是为了让 cut 与 selector 都能用、又不互相 import 形成环。

import 'dart:convert';

/// XBPQ 运行期错误（抓取失败 / 规则不可用 / 抽不到条目）。
///
/// 放在 util 这一层是为了让 `xbpq_source` 不必 import 网络层 ——
/// 取数逻辑只依赖注入的 fetcher，可以离线自检。
class XbpqException implements Exception {
  const XbpqException(this.message);

  final String message;

  @override
  String toString() => message;
}

class XbpqUtil {
  XbpqUtil._();

  /// 把 JSON 解出来的任意值转成字符串（对齐 Go `xbpqStringValue`）。
  static String stringValue(dynamic value) {
    if (value == null) return '';
    if (value is String) return value;
    if (value is int) return value.toString();
    if (value is double) {
      if (value.isFinite && value == value.roundToDouble()) {
        return value.toInt().toString();
      }
      return value.toString();
    }
    if (value is bool) return value ? 'true' : 'false';
    try {
      return jsonEncode(value);
    } catch (_) {
      return value.toString();
    }
  }

  /// 从绝对地址提取 `scheme://host`（对齐 Go `xbpqHostOrigin`）。
  static String hostOrigin(String address) {
    final index = address.indexOf('://');
    if (index < 0) return '';
    var rest = address.substring(index + 3);
    final slash = rest.indexOf(RegExp(r'[/?#]'));
    if (slash >= 0) rest = rest.substring(0, slash);
    return address.substring(0, index + 3) + rest;
  }

  /// 从右往左找与末尾 `]` 配对的 `[`（不嵌套，取最右）；找不到 -1。
  /// 对齐 Go `xbpqMatchBracket`。
  static int matchBracket(String token) {
    for (var i = token.length - 2; i >= 0; i--) {
      switch (token[i]) {
        case ']':
          return -1;
        case '[':
          return i;
      }
    }
    return -1;
  }

  /// 按 `,` 切分并 trim，丢弃空项。对齐 Go `xbpqSplitList`。
  static List<String> splitList(String payload) {
    final out = <String>[];
    for (var item in payload.split(',')) {
      item = item.trim();
      if (item.isNotEmpty) out.add(item);
    }
    return out;
  }

  /// 从两端剥掉指定字符（对齐 Go `strings.Trim(s, cutset)`）。
  static String trimBoth(String s, String cutset) {
    var start = 0;
    var end = s.length;
    while (start < end && cutset.contains(s[start])) {
      start++;
    }
    while (end > start && cutset.contains(s[end - 1])) {
      end--;
    }
    return s.substring(start, end);
  }
}
