// lib/services/xbpq/xbpq_maccms.dart
//
// 苹果CMS 播放页工具 —— 对齐 huoyi `provider_duanju_maccms.go` 的
// `maccmsNormalizePlaybackURL` / `maccmsPlayerURL` / `maccmsPlayerFields`
// / `maccmsDecryptPlayerURL` / `maccmsUnescapeJS` / `maccmsDecodeUnicode`
// / `maccmsIframeBase64URL`。
//
// 为什么 XBPQ 需要这一层：规则的「跳转播放链接」抽不到时，播放页里通常还
// 留着 `player_aaaa = {...}` 的 JSON（含 url + encrypt），或者 mxone 皮肤的
// iframe base64 参数。这是跨站点通用的兜底，比纯正则稳。
//
// 纯 Dart（只用 dart:convert），可离线自检。

import 'dart:convert';

import 'package:tvbox/services/xbpq/xbpq_util.dart';

class XbpqMaccms {
  XbpqMaccms._();

  // ============================================================
  // 播放地址规范化
  // ============================================================

  /// `strings.Trim` 的 cutset：逗号 / 反斜杠 / 中英文标点。
  static const String _trimCharset = ',\\。，;；';

  /// 清掉 JSON 残留与多余符号，并修复「分集目录被 unicode 转义」的 m3u8。
  ///
  /// `p.` / `c1.` 形态（如 `/video/p.abc/\\u7b2c01\\u96c6/index.m3u8`）里
  /// 目录名是转义过的中文，直接请求会 404 —— 解出中文再拼回 `index.m3u8`。
  static String normalizePlaybackUrl(String raw) {
    var value = raw.replaceAll(r'\/', '/').trim();
    value = XbpqUtil.trimBoth(value, _trimCharset);
    value = value.trim();
    if (value.isEmpty) return '';

    if (value.contains('p.') || value.contains('c1.')) {
      final parts = value.split('/');
      if (parts.length >= 3) {
        final base = parts.sublist(0, parts.length - 2).join('/');
        final folder = parts[parts.length - 2];
        final decoded = decodeUnicode(folder);
        if (decoded != folder) {
          return '$base/${Uri.encodeComponent(decoded)}/index.m3u8';
        }
      }
    }
    return value;
  }

  static final RegExp _unicodeEscape = RegExp(r'\\?u([0-9a-fA-F]{4})');

  /// 把 `\u7b2c` / `%u7b2c` 形态还原成字符（Go `maccmsDecodeUnicode`）。
  static String decodeUnicode(String value) {
    return value.replaceAllMapped(_unicodeEscape, (m) {
      final code = int.tryParse(m.group(1)!, radix: 16);
      return code == null ? m.group(0)! : String.fromCharCode(code);
    });
  }

  // ============================================================
  // 播放页取直链
  // ============================================================

  static final RegExp _playerData = RegExp(
    r'player_(?:aaaa|data)\s*=\s*(\{.*?\})\s*(?:</script>|;|$)',
    caseSensitive: false,
    dotAll: true,
  );
  static final RegExp _playerUrlField = RegExp(r'"url"\s*:\s*"([^"]+)"');
  static final RegExp _encryptField = RegExp(r'"encrypt"\s*:\s*"?([0-9])"?');

  static final RegExp _dollarUrl = RegExp(r'\$\.url\s*=\s*"([^"]+)"');
  static final RegExp _jsonMediaUrl =
      RegExp(r'"url"\s*:\s*"([^"]+\.(?:m3u8|mp4)[^"]*)"');
  static final RegExp _bareMediaUrl =
      RegExp(r'''(https?://[^\s"'<>]+\.(?:m3u8|mp4)[^\s"'<>]*)''');

  /// mxone 新版皮肤：`<iframe src="…/url?url=<base64 m3u8>">`。
  static final RegExp _iframeBase64 = RegExp(
    r'<iframe[^>]*?[?&]url=([A-Za-z0-9+/]{20,}={0,2})',
    caseSensitive: false,
    dotAll: true,
  );

  /// 从播放页 HTML 取直链：player_data JSON → 正则兜底 → iframe base64。
  static String playerUrl(String body) {
    final fields = playerFields(body);
    final rawUrl = fields['url'] ?? '';

    if (rawUrl.isNotEmpty) {
      final value = decryptPlayerUrl(rawUrl, fields['encrypt'] ?? '');
      if (value.toLowerCase().startsWith('http')) return value;
    }
    for (final pattern in [_dollarUrl, _jsonMediaUrl, _bareMediaUrl]) {
      final m = pattern.firstMatch(body);
      if (m != null) return m.group(1)!.replaceAll(r'\/', '/');
    }
    if (rawUrl.isNotEmpty) {
      return decryptPlayerUrl(rawUrl, fields['encrypt'] ?? '');
    }
    return iframeBase64Url(body);
  }

  /// 解析 `player_aaaa` / `player_data` 对象里的 url / encrypt / from。
  static Map<String, String> playerFields(String body) {
    final fields = <String, String>{};
    final match = _playerData.firstMatch(body);
    if (match == null) return fields;

    final blob = match.group(1)!.replaceAll(r'\/', '/');
    try {
      final payload = jsonDecode(blob);
      if (payload is Map) {
        for (final key in const ['url', 'encrypt', 'from']) {
          final value = payload[key];
          if (value is String) {
            fields[key] = value.trim();
          } else if (value is num) {
            fields[key] = value.toInt().toString();
          }
        }
      }
    } catch (_) {
      // 落到下面的正则兜底
    }
    if ((fields['url'] ?? '').isEmpty) {
      final inner = _playerUrlField.firstMatch(match.group(1)!);
      if (inner != null) fields['url'] = inner.group(1)!.replaceAll(r'\/', '/');
    }
    if ((fields['encrypt'] ?? '').isEmpty) {
      final inner = _encryptField.firstMatch(match.group(1)!);
      if (inner != null) fields['encrypt'] = inner.group(1)!;
    }
    return fields;
  }

  /// `encrypt` 模式：1 = JS escape 编码，2 = base64（可能再套一层 urlencode）。
  static String decryptPlayerUrl(String raw, String encrypt) {
    switch (encrypt) {
      case '1':
        return unescapeJs(raw);
      case '2':
        final direct = _tryBase64(raw);
        if (direct != null) return unescapeJs(direct);
        // qqys01 式变体：base64 之外还外套一层 urlencode（每个 % 被转成 %25），
        // 直解失败时先 QueryUnescape 再试一次。
        if (raw.contains('%')) {
          try {
            final unescaped = Uri.decodeQueryComponent(raw);
            if (unescaped != raw) {
              final second = _tryBase64(unescaped);
              if (second != null) return unescapeJs(second);
            }
          } catch (_) {
            // 保持原串
          }
        }
        return raw;
      default:
        return raw;
    }
  }

  static String? _tryBase64(String value) {
    try {
      final bytes = base64.decode(base64.normalize(value));
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  static final RegExp _jsUnicodeEscape =
      RegExp(r'%u([0-9a-f]{4})', caseSensitive: false);
  static final RegExp _jsHexEscape = RegExp(r'%([0-9a-fA-F]{2})');

  /// 还原 JS `escape()` 产物。
  ///
  /// 先处理 `%uXXXX`（`Uri.decodeQueryComponent` 不认这种写法），再交给它
  /// 处理 `%XX`；否则路径里的中文会残留 `%u7B2C` 导致 404。
  static String unescapeJs(String value) {
    if (!value.contains('%')) return value;
    var out = value;
    if (out.toLowerCase().contains('%u')) {
      out = out.replaceAllMapped(_jsUnicodeEscape, (m) {
        final code = int.tryParse(m.group(1)!, radix: 16);
        return code == null ? m.group(0)! : String.fromCharCode(code);
      });
    }
    try {
      return Uri.decodeQueryComponent(out);
    } catch (_) {
      return out.replaceAllMapped(_jsHexEscape, (m) {
        final code = int.tryParse(m.group(1)!, radix: 16);
        return code == null ? m.group(0)! : String.fromCharCode(code);
      });
    }
  }

  /// 从 iframe src 的 base64 参数解出真实直链（解码后逗号分隔多源取第一个）。
  static String iframeBase64Url(String body) {
    final match = _iframeBase64.firstMatch(body);
    if (match == null) return '';

    final payload = match.group(1)!;
    var decoded = _tryBase64(payload);
    if (decoded == null) {
      final pad = (4 - payload.length % 4) % 4;
      if (pad > 0) decoded = _tryBase64(payload + '=' * pad);
    }
    if (decoded == null) return '';

    for (var candidate in decoded.split(',')) {
      candidate = candidate.trim();
      if (candidate.toLowerCase().startsWith('http')) return candidate;
    }
    return '';
  }
}
