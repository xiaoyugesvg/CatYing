import 'dart:convert';

import '../models/book_source.dart';

/// 书源 JSON 解析（**唯一实现**）。
///
/// 原来这段逻辑藏在 `book_source_repo_page.dart` 的私有方法里；
/// 订阅管理也要复用，所以抽出来，避免两份解析逐渐走样。
class BookSourceImportParser {
  BookSourceImportParser._();

  /// 兼容 4 种形态 + 带尾随逗号的脏 JSON：
  ///   · 数组
  ///   · 单个书源对象
  ///   · `{"sources":[...]}`
  ///   · Cmbok 导出包装 `{seq,id,name,json:"<Legado 书源 JSON>"}`
  static List<BookSource> parseSources(String text) {
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      // 有些分发文件带尾随逗号 / 前后有说明文字，退回"截取首尾括号"再试
      final a = text.indexOf('[');
      final b = text.lastIndexOf(']');
      final c = text.indexOf('{');
      final d = text.lastIndexOf('}');
      String? candidate;
      if (a >= 0 && b > a) {
        candidate = text.substring(a, b + 1);
      } else if (c >= 0 && d > c) {
        candidate = text.substring(c, d + 1);
      }
      if (candidate == null) rethrow;
      decoded = jsonDecode(candidate);
    }

    final out = <BookSource>[];
    void take(dynamic e) {
      if (e is! Map) return;
      final m = e.cast<String, dynamic>();
      // Cmbok 导出包装：书源本体在 json 字段（字符串）
      if (m['json'] is String && !m.containsKey('bookSourceName')) {
        try {
          final inner = jsonDecode(m['json'] as String);
          if (inner is List) {
            for (final x in inner) {
              take(x);
            }
            return;
          }
          if (inner is Map) {
            take(inner);
            return;
          }
        } catch (_) {
          // 解包失败就当普通对象继续
        }
      }
      final s = BookSource.fromJson(m);
      if (s != null) out.add(s);
    }

    if (decoded is List) {
      for (final e in decoded) {
        take(e);
      }
    } else if (decoded is Map) {
      final m = decoded.cast<String, dynamic>();
      if (m['sources'] is List) {
        for (final e in (m['sources'] as List)) {
          take(e);
        }
      } else {
        take(m);
      }
    }
    return out;
  }
}
