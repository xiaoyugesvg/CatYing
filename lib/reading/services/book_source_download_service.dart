import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 书源「下载全书」的本地索引。
///
/// 书源下载（BookSourceDetailPage 的逐章 TXT）不经过 BookDownloadService
/// 任务系统，为了让它出现在「下载记录页」里，这里单独维护一份轻量索引：
/// 每本下载完成的书一条记录（源 id / 源名 / 书 URL / 封面 / 章节数 / 目录 / 时间）。
///
/// 无内存缓存：每次读写 SharedPreferences（记录量小），
/// [revision] 供 UI 监听刷新。
class BookSourceDownloadRecord {
  const BookSourceDownloadRecord({
    required this.sourceId,
    required this.sourceName,
    required this.bookUrl,
    required this.title,
    this.author = '',
    this.cover = '',
    required this.chapterCount,
    required this.dir,
    required this.time,
  });

  final String sourceId;
  final String sourceName;
  final String bookUrl;
  final String title;
  final String author;
  final String cover;
  final int chapterCount;
  final String dir;
  final int time;

  Map<String, dynamic> toJson() => {
        'sourceId': sourceId,
        'sourceName': sourceName,
        'bookUrl': bookUrl,
        'title': title,
        'author': author,
        'cover': cover,
        'chapterCount': chapterCount,
        'dir': dir,
        'time': time,
      };

  static BookSourceDownloadRecord fromJson(Map<String, dynamic> j) =>
      BookSourceDownloadRecord(
        sourceId: (j['sourceId'] ?? '').toString(),
        sourceName: (j['sourceName'] ?? '').toString(),
        bookUrl: (j['bookUrl'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        author: (j['author'] ?? '').toString(),
        cover: (j['cover'] ?? '').toString(),
        chapterCount: (j['chapterCount'] ?? 0) is int
            ? (j['chapterCount'] as int)
            : int.tryParse((j['chapterCount'] ?? '0').toString()) ?? 0,
        dir: (j['dir'] ?? '').toString(),
        time: (j['time'] ?? 0) is int
            ? (j['time'] as int)
            : int.tryParse((j['time'] ?? '0').toString()) ?? 0,
      );
}

class BookSourceDownloadService {
  BookSourceDownloadService._();
  static final BookSourceDownloadService instance =
      BookSourceDownloadService._();

  static const _key = 'bs_book_downloads_v1';

  /// 变更通知（UI 监听）
  final revision = ValueNotifier<int>(0);

  Future<List<BookSourceDownloadRecord>> records() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return const [];
      final list = jsonDecode(raw) as List<dynamic>;
      // 最新下载在前
      return list.reversed
          .map((e) => BookSourceDownloadRecord.fromJson(
              (e as Map).cast<String, dynamic>()))
          .toList();
    } catch (e) {
      debugPrint('[BookSourceDownload] 读取索引失败: $e');
      return const [];
    }
  }

  /// 追加一条记录（同书同源去重置顶），下载完成后调用。
  Future<void> add(BookSourceDownloadRecord rec) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      final list = <Map<String, dynamic>>[];
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        for (final e in decoded) {
          final m = (e as Map).cast<String, dynamic>();
          // 同一源同一本书只保留最新一条（重新下载 → 更新章节数/时间）
          if (m['bookUrl'] == rec.bookUrl &&
              m['sourceId'] == rec.sourceId) {
            continue;
          }
          list.add(m);
        }
      }
      list.add(rec.toJson());
      await prefs.setString(_key, jsonEncode(list));
      revision.value++;
    } catch (e) {
      debugPrint('[BookSourceDownload] 写入索引失败: $e');
    }
  }

  /// 删除一条记录（仅索引，不删已下载文件）。
  Future<void> remove(String sourceId, String bookUrl) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final list = (jsonDecode(raw) as List<dynamic>)
          .where((e) {
            final m = (e as Map).cast<String, dynamic>();
            return !(m['bookUrl'] == bookUrl && m['sourceId'] == sourceId);
          })
          .toList();
      await prefs.setString(_key, jsonEncode(list));
      revision.value++;
    } catch (e) {
      debugPrint('[BookSourceDownload] 删除索引失败: $e');
    }
  }
}
