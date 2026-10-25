import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 章节正文的**磁盘缓存**（只存纯文字章，不含图片）。
///
/// ── 为什么需要 ────────────────────────────────────────────────
/// 阅读器里那层 `_cache` 是**内存**的：杀进程 / 内存吃紧被回收后，
/// 再从书架点开同一本书，正文又要重新抓一次（慢源上就是好几秒）。
/// 用户 2026-10-25：「书架点开那么慢，一点都不缓存吗？」
///
/// 这里把正文落到 `Documents/reader_text/`：
///   · 10 分钟内命中直接渲染，不再打网络
///   · 带图片的章不缓存（图片 URL 会过期，缓存下来反而更糟）
///   · 「刷新本章」按钮会传 force 跳过它，拿最新内容
///   · 最多留 400 个文件，按 mtime 淘汰
class ChapterTextCache {
  ChapterTextCache._();
  static final ChapterTextCache instance = ChapterTextCache._();

  static const int _maxFiles = 400;
  static const Duration _ttl = Duration(minutes: 10);

  String? _dir;
  bool _ready = false;

  Future<void> _ensureDir() async {
    if (_ready) return;
    _ready = true;
    try {
      final d = await getApplicationDocumentsDirectory();
      final dir = Directory('${d.path}/reader_text');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _dir = dir.path;
    } catch (_) {}
  }

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

  /// 命中返回 `(正文, 图片头)`；过期/没有/损坏返回 null
  Future<(String, Map<String, String>)?> get(String key) async {
    final p = await _path(key);
    if (p == null) return null;
    try {
      final f = File(p);
      if (!f.existsSync()) return null;
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map) return null;
      if ((raw['key'] ?? '') != key) return null;
      final ts = (raw['ts'] as num?)?.toInt() ?? 0;
      final at = DateTime.fromMillisecondsSinceEpoch(ts);
      if (DateTime.now().difference(at) > _ttl) {
        try {
          f.deleteSync();
        } catch (_) {}
        return null;
      }
      final text = (raw['content'] ?? '').toString();
      if (text.trim().isEmpty) return null;
      final h = raw['headers'];
      final headers = <String, String>{};
      if (h is Map) {
        h.forEach((k, v) => headers['$k'] = '$v');
      }
      return (text, headers);
    } catch (_) {
      return null;
    }
  }

  /// 写缓存（只存纯文字章）
  Future<void> put(
    String key,
    String content,
    Map<String, String> headers,
  ) async {
    if (content.trim().isEmpty) return;
    final p = await _path(key);
    if (p == null) return;
    try {
      final payload = {
        'key': key,
        'ts': DateTime.now().millisecondsSinceEpoch,
        'content': content,
        'headers': headers,
      };
      final tmp = File('$p.tmp');
      await tmp.writeAsString(jsonEncode(payload), flush: true);
      await tmp.rename(p);
      await _evict();
    } catch (_) {}
  }

  /// 删掉某个 key 的缓存（刷新本章时用）
  Future<void> remove(String key) async {
    final p = await _path(key);
    if (p == null) return;
    try {
      final f = File(p);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  Future<void> _evict() async {
    final dir = _dir;
    if (dir == null) return;
    try {
      final files = Directory(dir)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList();
      if (files.length <= _maxFiles) return;
      files.sort((a, b) =>
          a.statSync().modified.compareTo(b.statSync().modified));
      for (var i = 0; i < files.length - _maxFiles; i++) {
        try {
          files[i].deleteSync();
        } catch (_) {}
      }
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

  /// 清空全部正文缓存
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
