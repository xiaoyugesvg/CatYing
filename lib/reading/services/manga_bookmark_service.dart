import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _log(String message) {
  if (kDebugMode) {
    debugPrint('[MangaBookmark] $message');
  }
}

/// 漫画书签（参考 cmbok「书签」面板：按章节 + 页码定位）
class MangaBookmark {
  final String pathWord;
  final String comicTitle;
  final String chapterId;
  final String chapterTitle;
  final int pageIndex;
  final int pageCount;
  final DateTime createdAt;

  const MangaBookmark({
    required this.pathWord,
    required this.comicTitle,
    required this.chapterId,
    required this.chapterTitle,
    required this.pageIndex,
    required this.pageCount,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'pathWord': pathWord,
        'comicTitle': comicTitle,
        'chapterId': chapterId,
        'chapterTitle': chapterTitle,
        'pageIndex': pageIndex,
        'pageCount': pageCount,
        'createdAt': createdAt.toIso8601String(),
      };

  factory MangaBookmark.fromJson(Map<String, dynamic> json) {
    return MangaBookmark(
      pathWord: json['pathWord']?.toString() ?? '',
      comicTitle: json['comicTitle']?.toString() ?? '',
      chapterId: json['chapterId']?.toString() ?? '',
      chapterTitle: json['chapterTitle']?.toString() ?? '',
      pageIndex: json['pageIndex'] is num
          ? (json['pageIndex'] as num).toInt()
          : 0,
      pageCount: json['pageCount'] is num
          ? (json['pageCount'] as num).toInt()
          : 0,
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

/// 漫画书签服务（单例 + ChangeNotifier）。
///
/// 存储：SharedPreferences `manga_bookmarks` = JSON 数组。
/// 标识：pathWord + chapterId + pageIndex 三元组去重。
class MangaBookmarkService extends ChangeNotifier {
  MangaBookmarkService._();
  static final MangaBookmarkService _instance = MangaBookmarkService._();
  factory MangaBookmarkService() => _instance;

  static const _key = 'manga_bookmarks';
  final List<MangaBookmark> _items = [];
  bool _loaded = false;

  Future<void> init() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        for (final e in list) {
          if (e is Map) {
            _items.add(MangaBookmark.fromJson(Map<String, dynamic>.from(e)));
          }
        }
      }
      _loaded = true;
      _log('已加载书签 ${_items.length} 条');
    } catch (e) {
      _log('加载书签失败: $e');
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key,
        jsonEncode(_items.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      _log('保存书签失败: $e');
    }
  }

  List<MangaBookmark> get all {
    final list = List<MangaBookmark>.from(_items);
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  List<MangaBookmark> bookmarksFor(String pathWord) => all
      .where((b) => b.pathWord == pathWord)
      .toList();

  int countFor(String pathWord) =>
      _items.where((b) => b.pathWord == pathWord).length;

  bool exists(String pathWord, String chapterId, int pageIndex) =>
      _items.any(
        (b) =>
            b.pathWord == pathWord &&
            b.chapterId == chapterId &&
            b.pageIndex == pageIndex,
      );

  /// 切换当前页书签，返回是否已添加（true=新增）
  Future<bool> toggle({
    required String pathWord,
    required String comicTitle,
    required String chapterId,
    required String chapterTitle,
    required int pageIndex,
    required int pageCount,
  }) async {
    final hit = _items.indexWhere(
      (b) =>
          b.pathWord == pathWord &&
          b.chapterId == chapterId &&
          b.pageIndex == pageIndex,
    );
    if (hit >= 0) {
      _items.removeAt(hit);
      notifyListeners();
      await _persist();
      return false;
    }
    _items.add(
      MangaBookmark(
        pathWord: pathWord,
        comicTitle: comicTitle,
        chapterId: chapterId,
        chapterTitle: chapterTitle,
        pageIndex: pageIndex,
        pageCount: pageCount,
        createdAt: DateTime.now(),
      ),
    );
    notifyListeners();
    await _persist();
    return true;
  }

  /// 移除单条书签
  Future<void> remove(MangaBookmark bookmark) async {
    _items.removeWhere(
      (b) =>
          b.pathWord == bookmark.pathWord &&
          b.chapterId == bookmark.chapterId &&
          b.pageIndex == bookmark.pageIndex,
    );
    notifyListeners();
    await _persist();
  }
}
