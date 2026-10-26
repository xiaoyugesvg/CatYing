import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/reading/services/book_source_service.dart';

/// 一份落盘的目录缓存
class CachedToc {
  const CachedToc({
    required this.tocUrl,
    required this.chapters,
    required this.savedAt,
  });

  final String tocUrl;
  final List<BookSourceChapter> chapters;
  final DateTime savedAt;

  int get ageMinutes => DateTime.now().difference(savedAt).inMinutes;
}

/// 目录（章节列表）的**磁盘缓存**。
///
/// ── 为什么需要 ────────────────────────────────────────────────
/// 书架的 `_openSourceBookDirectly` 原来每次点击都要：
///   ① `bookInfo` 抓详情页拿 tocUrl  →  ② `toc` 抓目录页
/// 两个都是网络往返，慢源上就是好几秒，还卡着一个不可关闭的加载框
/// （用户 2026-10-25：「书架点开那么慢，一点都不缓存吗？」）。
///
/// BookSourceService 里那层缓存是**内存 5 分钟**，杀进程就没了；
/// 从书架打开基本都发生在"上次读完、过一会儿再进来"⇒ 必然冷启动。
///
/// 这里把目录落盘：点开先用旧目录**立即进阅读器**，后台再刷新，
/// 目录真变了才提示（不让用户对着转圈等）。
///
/// 存 `Documents/reader_toc/`，按书一个 json，最多留 30 本（按 mtime 淘汰）。
class BookTocCache {
  BookTocCache._();
  static final BookTocCache instance = BookTocCache._();

  static const int _maxBooks = 30;

  String? _dir;
  bool _ready = false;

  Future<void> _ensureDir() async {
    if (_ready) return;
    _ready = true;
    try {
      final d = await getApplicationDocumentsDirectory();
      final dir = Directory('${d.path}/reader_toc');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _dir = dir.path;
    } catch (e) {
      // 目录建不出来 ⇒ 整个目录缓存静默失效（每次进书都重新联网拉目录）。
      // 这个后果用户能感知（进书变慢），必须留痕，否则查不到原因。
      AppLog.instance.w('[目录缓存] 初始化失败，本次会话缓存不可用: $e');
    }
  }

  /// 书 → 文件名（FNV-1a 32 位，稳定且不含路径非法字符）
  String _fileName(String key) {
    var hash = 0x811c9dc5;
    for (final c in key.codeUnits) {
      hash ^= c;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return '${hash.toRadixString(16)}.json';
  }

  Future<String?> _path(String key) async {
    await _ensureDir();
    final dir = _dir;
    if (dir == null) return null;
    return '$dir/${_fileName(key)}';
  }

  /// 读缓存（没有 / 损坏 / 空目录都返回 null）
  Future<CachedToc?> load(String key) async {
    final p = await _path(key);
    if (p == null) return null;
    try {
      final f = File(p);
      if (!f.existsSync()) return null;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map) return null;
      // 换过源/换过书 ⇒ key 变了本来就读不到，这里再核一次防哈希撞车
      if ((raw['key'] ?? '') != key) return null;
      final list = (raw['chapters'] as List?) ?? const [];
      final chapters = <BookSourceChapter>[];
      for (final e in list) {
        if (e is! Map) continue;
        final c = BookSourceChapter.fromJson(Map<String, dynamic>.from(e));
        if (c != null) chapters.add(c);
      }
      if (chapters.isEmpty) return null;
      final at = (raw['savedAt'] as num?)?.toInt() ?? 0;
      return CachedToc(
        tocUrl: (raw['tocUrl'] ?? '').toString(),
        chapters: chapters,
        savedAt: DateTime.fromMillisecondsSinceEpoch(at),
      );
    } catch (_) {
      return null;
    }
  }

  /// 写缓存（成功才写；顺便做一次 LRU 清理）
  Future<void> save(
    String key,
    String tocUrl,
    List<BookSourceChapter> chapters,
  ) async {
    if (chapters.isEmpty) return;
    final p = await _path(key);
    if (p == null) return;
    try {
      final payload = {
        'key': key,
        'tocUrl': tocUrl,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'chapters': [
          for (final c in chapters) {'name': c.name, 'url': c.url},
        ],
      };
      // 先写临时文件再 rename：写到一半被杀也不会留下半个 json
      final tmp = File('$p.tmp');
      await tmp.writeAsString(jsonEncode(payload), flush: true);
      await tmp.rename(p);
      await _evict();
    } catch (_) {}
  }

  Future<void> _evict() async {
    final dir = _dir;
    if (dir == null) return;
    try {
      final d = Directory(dir);
      final files = d
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList();
      if (files.length <= _maxBooks) return;
      files.sort((a, b) =>
          a.statSync().modified.compareTo(b.statSync().modified));
      for (var i = 0; i < files.length - _maxBooks; i++) {
        try {
          files[i].deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 删掉某本书的缓存（换源/删书时用）
  Future<void> remove(String key) async {
    final p = await _path(key);
    if (p == null) return;
    try {
      final f = File(p);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// 当前占用字节数（缓存管理页用）
  Future<int> sizeBytes() async {
    await _ensureDir();
    final dir = _dir;
    if (dir == null) return 0;
    try {
      final d = Directory(dir);
      if (!d.existsSync()) return 0;
      var total = 0;
      for (final f in d.listSync().whereType<File>()) {
        try {
          total += f.lengthSync();
        } catch (_) {}
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 清空全部目录缓存
  Future<void> clear() async {
    await _ensureDir();
    final dir = _dir;
    if (dir == null) return;
    try {
      final d = Directory(dir);
      if (d.existsSync()) d.deleteSync(recursive: true);
      _ready = false;
      _dir = null;
    } catch (_) {}
  }
}
