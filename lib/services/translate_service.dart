import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// 轻量翻译：走 Google 的**免 Key** 端点，不依赖任何 API Key。
///
/// 端点来源：iOS「Scripting」那个翻译脚本（`core/google_engine.ts`）里在用的两条，
/// 实测无需鉴权、无需账号：
///   1. translate.googleapis.com/translate_a/single?client=gtx
///   2. clients5.google.com/translate_a/t?client=dict-chrome-ex
///
/// 只做「外语 → 中文」这一件事：
///   · 原文已经是中文 → 直接原样返回（调用方据此不显示"译"按钮）
///   · 内存缓存最近 300 条，避免列表滚动时反复打网络
class TranslateService {
  TranslateService._();
  static final TranslateService instance = TranslateService._();

  static const int _maxCache = 300;
  static const Duration _timeout = Duration(seconds: 10);

  final Map<String, String> _cache = {};

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: _timeout,
    receiveTimeout: _timeout,
    headers: {
      'User-Agent':
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
              'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
    },
  ));

  /// 中文占比够高就认为不用翻（只判 CJK 字符比例）
  static bool looksChinese(String s) {
    if (s.isEmpty) return false;
    var cjk = 0;
    var letters = 0;
    for (final r in s.runes) {
      if (r < 0x80) {
        if ((r >= 65 && r <= 90) || (r >= 97 && r <= 122)) letters++;
        continue;
      }
      // 基本汉字 + 扩展 A + 兼容区
      if ((r >= 0x4E00 && r <= 0x9FFF) ||
          (r >= 0x3400 && r <= 0x4DBF) ||
          (r >= 0xF900 && r <= 0xFAFF)) {
        cjk++;
      }
    }
    final total = cjk + letters;
    if (total == 0) return false;
    return cjk / total >= 0.3;
  }

  /// 是否需要翻译（有拉丁字母且不是中文）
  static bool needsTranslation(String s) {
    if (s.trim().isEmpty) return false;
    if (looksChinese(s)) return false;
    return RegExp(r'[A-Za-z]').hasMatch(s);
  }

  /// 翻译成中文；失败抛异常（调用方自己 toast）
  Future<String> toZh(String text) async {
    final t = text.trim();
    if (t.isEmpty) return '';
    if (!needsTranslation(t)) return t;

    final hit = _cache[t];
    if (hit != null) return hit;

    final q = Uri.encodeComponent(t.length > 1800 ? t.substring(0, 1800) : t);

    String? out;
    // 端点 1：dict-chrome-ex（实测最稳，返回 [["译文","en"], ...]）
    try {
      final r = await _dio.get<String>(
        'https://clients5.google.com/translate_a/t'
        '?client=dict-chrome-ex&sl=auto&tl=zh-CN&q=$q',
        options: Options(responseType: ResponseType.plain),
      );
      out = _parseDict(r.data);
    } catch (e) {
      debugPrint('[Translate] dict 失败: $e');
    }

    // 端点 2：gtx（返回 [[[译文, 原文, ...], ...], ...]）
    // 实测该端点经常对本机 IP 返回 429，所以放兜底位。
    if (out == null || out.isEmpty) {
      try {
        final r = await _dio.get<String>(
          'https://translate.googleapis.com/translate_a/single'
          '?client=gtx&sl=auto&tl=zh-CN&dt=t&q=$q',
          options: Options(responseType: ResponseType.plain),
        );
        out = _parseGtx(r.data);
      } catch (e) {
        debugPrint('[Translate] gtx 失败: $e');
      }
    }

    if (out == null || out.trim().isEmpty) {
      throw '翻译服务无返回';
    }
    final result = out.trim();
    if (_cache.length >= _maxCache) _cache.clear();
    _cache[t] = result;
    return result;
  }

  String _parseGtx(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    final data = jsonDecode(raw);
    if (data is! List || data.isEmpty) return '';
    final segs = data[0];
    if (segs is! List) return '';
    final buf = StringBuffer();
    for (final s in segs) {
      if (s is List && s.isNotEmpty && s[0] is String) {
        buf.write(s[0] as String);
      }
    }
    return buf.toString();
  }

  String _parseDict(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    final data = jsonDecode(raw);

    // 实际返回（2026-10-25 实测）：
    //   [["奥本海默 4K","en"]]            单句
    //   [["句1","en"],["句2","en"]]       多句
    // 另兼容 ["译文"] / [{"trans":"译文"}] / {"sentences":[...]}
    if (data is List) {
      final buf = StringBuffer();
      for (final e in data) {
        if (e is String) {
          buf.write(e);
        } else if (e is Map && e['trans'] is String) {
          buf.write(e['trans'] as String);
        } else if (e is List && e.isNotEmpty && e.first is String) {
          buf.write(e.first as String);
        }
      }
      return buf.toString();
    }
    if (data is Map && data['sentences'] is List) {
      final buf = StringBuffer();
      for (final s in data['sentences'] as List) {
        if (s is Map && s['trans'] is String) buf.write(s['trans'] as String);
      }
      return buf.toString();
    }
    return '';
  }
}
