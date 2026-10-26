import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox/reading/models/book.dart';

/// 图书收藏服务（本地持久化 via SharedPreferences）
/// 单例 + ChangeNotifier，UI 用 ListenableBuilder 监听变化。
/// 对应漫画 FavoritesService，独立存储图书收藏。
class BookFavoritesService extends ChangeNotifier {
  BookFavoritesService._();
  static final BookFavoritesService _instance = BookFavoritesService._();
  factory BookFavoritesService() => _instance;

  static const _key = 'book_favorites';

  final List<Book> _books = [];
  List<Book> get books => List.unmodifiable(_books);

  /// 初始化：从本地加载已收藏图书
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_key) ?? [];
      _books
        ..clear()
        ..addAll(
          list.map((s) {
            try {
              return Book.fromJson(jsonDecode(s) as Map<String, dynamic>);
            } catch (_) {
              return null;
            }
          }).whereType<Book>(),
        );
      _log('已加载 ${_books.length} 本收藏图书');
    } catch (e) {
      _log('加载图书收藏失败: $e');
    }
    notifyListeners();
  }

  bool isFavorite(String id) => _books.any((b) => b.id == id);

  /// 切换收藏状态
  Future<void> toggle(Book book) async {
    if (isFavorite(book.id)) {
      _books.removeWhere((b) => b.id == book.id);
      _log('取消收藏: ${book.title}');
    } else {
      _books.insert(0, book);
      _log('添加收藏: ${book.title}');
    }
    await _persist();
    notifyListeners();
  }

  /// 批量取消收藏（按 id 集合，一次持久化 + 一次通知）
  Future<void> removeMany(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    final idSet = ids.toSet();
    _books.removeWhere((b) => idSet.contains(b.id));
    _log('批量取消收藏: ${idSet.length} 本');
    await _persist();
    notifyListeners();
  }

  /// ⚡ **写盘串行化**（本次修复 ✓）：原来每次 `toggle` / `removeMany` 都各发一次
  /// `setStringList` ✗，而它们**并发**执行 ✓ → 快速双击收藏时，
  /// **先发的那次可能后落地** ✗✗ → 磁盘上留下**过期状态** ✓
  /// （表现：界面显示"已取消收藏"，重进却又回来了 ✗ —— 用户可见的错误状态 ✓）。
  /// ✓ 现在把每次写盘**接到上一次之后**（`_writeChain` ✓）：顺序 = 调用顺序 ✓，
  ///   且 `_books` 是在**真正写入时**才编码 ✓ → **最后一次写入必然带最终状态** ✓✓。
  /// ⚠️ `catch` 放在**链内** ✓ —— 否则一次失败会**断掉整条链** ✗，
  ///   导致之后所有收藏都写不进去 ✗✗。
  /// ⚠️ 返回值仍是"这一次写盘"的 Future ✓ → 调用方 `await toggle(...)` 的
  ///   "已保存"语义**完全不变** ✓（见 `toggle` / `removeMany` ✓）。
  Future<void> _writeChain = Future<void>.value();

  Future<void> _persist() {
    _writeChain = _writeChain.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final list = _books.map((b) => jsonEncode(b.toJson())).toList();
        await prefs.setStringList(_key, list);
      } catch (e) {
        _log('保存图书收藏失败: $e');
      }
    });
    return _writeChain;
  }

  void _log(String msg) {
    if (kDebugMode) debugPrint('[BookFavorites] $msg');
  }
}
