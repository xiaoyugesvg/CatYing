/// 海阔分享口令识别（参考 huoyi `clipboard_rule_match.dart` 移植）。
///
/// 社区分享海阔源时最常见三种格式：
///   1. `￥home_rule…￥` 口令（`home_rule` = 明文 JSON、`home_rule_v2` = base64 压缩、
///      `home_rule_url` / `home_sub` = 远程规则地址）；
///   2. 直接粘贴的海阔小程序 JSON（`[{...}]`）；
///   3. 一个 https 链接（远程规则 / 网盘直链）。
/// 命中后由页面弹确认框，走现有的导入链路，不新造轮子。
library;

import 'dart:convert';

enum ClipboardMatchKind {
  /// 海阔小程序规则文本（JSON，可直接解析导入）
  hikerRuleText,

  /// 远程规则地址（需先下载文本再导入）
  remoteRule,

  /// 小程序 zip 包链接（走「程序市场」导入，不在海阔页处理）
  antPackageLink,

  /// 云码（`云xxx/xxx`，需要配套云服务，本版仅识别不消费）
  cloudCode,
}

class ClipboardRuleMatch {
  const ClipboardRuleMatch({required this.kind, required this.payload});

  final ClipboardMatchKind kind;
  final String payload;

  /// 用户可读的命中说明（确认弹窗的副标题）
  String get label => switch (kind) {
    ClipboardMatchKind.hikerRuleText => '海阔小程序规则文本',
    ClipboardMatchKind.remoteRule => '海阔远程规则地址',
    ClipboardMatchKind.antPackageLink => '小程序安装包链接',
    ClipboardMatchKind.cloudCode => '云码（需云服务）',
  };
}

/// 海阔分享口令的标识段（`￥标识￥` 里的标识）
const _passwordIdentifiers = {
  'home_rule',
  'home_rule_v2',
  'home_rule_url',
  'home_sub',
};

/// 识别一段剪贴板文本是不是海阔分享格式；不是返回 null。
ClipboardRuleMatch? matchClipboardRule(String? text) {
  if (text == null) return null;
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;

  // ── 1. `￥…￥` 口令（原版海阔的分享格式）────────────────
  if (trimmed.contains('￥')) {
    final parts = trimmed.split('￥');
    if (parts.length >= 3) {
      final identifier = parts[1].trim();
      if (_passwordIdentifiers.contains(identifier)) {
        final payload = parts.sublist(2).join('￥').trim();
        switch (identifier) {
          case 'home_rule':
            return ClipboardRuleMatch(
              kind: ClipboardMatchKind.hikerRuleText,
              payload: payload,
            );
          case 'home_rule_v2':
            final decoded = decodeHomeRuleV2(payload);
            if (decoded == null) return null;
            return ClipboardRuleMatch(
              kind: ClipboardMatchKind.hikerRuleText,
              payload: decoded,
            );
          case 'home_rule_url':
          case 'home_sub':
            return ClipboardRuleMatch(
              kind: ClipboardMatchKind.remoteRule,
              payload: payload,
            );
        }
      }
    }
  }

  // ── 2. 云码（`云xxx/xxx`）──────────────────────────────
  if (isCloudCodeShape(trimmed)) {
    return ClipboardRuleMatch(
      kind: ClipboardMatchKind.cloudCode,
      payload: trimmed,
    );
  }

  // ── 3. 直接是海阔小程序 JSON（`[{...}]`）────────────────
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is List && decoded.isNotEmpty) {
        // 列表里得有像海阔源的条目（title / find_rule），否则不认
        final first = decoded.first;
        if (first is Map &&
            ((first['title'] as String?)?.isNotEmpty ?? false)) {
          return ClipboardRuleMatch(
            kind: ClipboardMatchKind.hikerRuleText,
            payload: trimmed,
          );
        }
      }
    } catch (_) {
      return null;
    }
  }

  // ── 4. https 链接 ──────────────────────────────────────
  if (trimmed.startsWith('https://')) {
    final path = trimmed.split(RegExp(r'[?#]')).first;
    if (path.toLowerCase().endsWith('.zip')) {
      return ClipboardRuleMatch(
        kind: ClipboardMatchKind.antPackageLink,
        payload: trimmed,
      );
    }
    return ClipboardRuleMatch(
      kind: ClipboardMatchKind.remoteRule,
      payload: trimmed,
    );
  }
  return null;
}

/// 云码形状：`云` 开头、含 `/`、无空白、短文本
bool isCloudCodeShape(String text) {
  if (text.length > 200) return false;
  if (!text.startsWith('云')) return false;
  if (!text.contains('/')) return false;
  if (text.contains(' ') ||
      text.contains('\n') ||
      text.contains('\r') ||
      text.contains('\t')) {
    return false;
  }
  return true;
}

/// `home_rule_v2` 的解码：`前缀@base64`（可选 `base64://` 头），@ 后是 base64 原文
String? decodeHomeRuleV2(String payload) {
  var rest = payload;
  if (rest.startsWith('base64://')) {
    rest = rest.substring('base64://'.length);
  }
  final at = rest.lastIndexOf('@');
  if (at < 0) return null;
  final encoded = rest.substring(at + 1).trim();
  if (encoded.isEmpty) return null;
  try {
    return utf8.decode(base64Decode(encoded));
  } catch (_) {
    return null;
  }
}
