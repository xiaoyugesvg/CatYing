/// 本地库管理：多根目录扫描、标签、查重、回收站。
///
/// 扫描范围：
///   · 下载根（设置里的保存目录）/ Books：图书文件
///   · 下载根 / Comics：每本漫画一个文件夹
///   · 用户额外添加的库根（文件夹）
///
/// 回收站放在下载根的 `.recycle_bin/` 下，每个条目一个子目录，
/// 索引写同目录 `index.json`（不依赖 prefs，避免整域丢失）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings_service.dart';

class LocalLibraryEntry {
  const LocalLibraryEntry({
    required this.path,
    required this.name,
    required this.isFolder,
    required this.sizeBytes,
    required this.itemCount,
    required this.modifiedMs,
  });

  final String path;
  final String name;
  final bool isFolder;
  final int sizeBytes;

  /// 漫画文件夹里的图片数量；图书文件 = 1
  final int itemCount;
  final int modifiedMs;
}

class DuplicateGroup {
  const DuplicateGroup({required this.key, required this.entries});

  final String key;
  final List<LocalLibraryEntry> entries;
}

class RecycleEntry {
  const RecycleEntry({
    required this.id,
    required this.name,
    required this.originalPath,
    required this.recyclePath,
    required this.isFolder,
    required this.sizeBytes,
    required this.deletedAtMs,
  });

  final String id;
  final String name;
  final String originalPath;
  final String recyclePath;
  final bool isFolder;
  final int sizeBytes;
  final int deletedAtMs;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'originalPath': originalPath,
        'recyclePath': recyclePath,
        'isFolder': isFolder,
        'sizeBytes': sizeBytes,
        'deletedAtMs': deletedAtMs,
      };

  static RecycleEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = '${raw['id'] ?? ''}';
    final path = '${raw['recyclePath'] ?? ''}';
    if (id.isEmpty || path.isEmpty) return null;
    return RecycleEntry(
      id: id,
      name: '${raw['name'] ?? ''}',
      originalPath: '${raw['originalPath'] ?? ''}',
      recyclePath: path,
      isFolder: raw['isFolder'] == true,
      sizeBytes: (raw['sizeBytes'] as num?)?.toInt() ?? 0,
      deletedAtMs: (raw['deletedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class LocalLibrarySnapshot {
  const LocalLibrarySnapshot({
    required this.books,
    required this.comics,
    required this.duplicateBooks,
    required this.duplicateComics,
    required this.totalBytes,
    required this.roots,
  });

  final List<LocalLibraryEntry> books;
  final List<LocalLibraryEntry> comics;
  final List<DuplicateGroup> duplicateBooks;
  final List<DuplicateGroup> duplicateComics;
  final int totalBytes;
  final List<String> roots;
}

class LocalLibraryService {
  LocalLibraryService._();
  static final LocalLibraryService instance = LocalLibraryService._();

  static const _tagsKey = 'local_library_tags_v1';
  static const _rootsKey = 'local_library_roots_v1';

  static const Set<String> bookExts = {'epub', 'pdf', 'txt'};
  static const Set<String> imageExts = {
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'bmp',
  };

  bool _isImage(String name) {
    final i = name.lastIndexOf('.');
    return i > 0 && imageExts.contains(name.substring(i + 1).toLowerCase());
  }

  bool _isBook(String name) {
    final i = name.lastIndexOf('.');
    return i > 0 && bookExts.contains(name.substring(i + 1).toLowerCase());
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  String formatSize(int bytes) => _fmtSize(bytes);

  // ── 库根 ────────────────────────────────────────────────

  Future<List<String>> roots() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getStringList(_rootsKey) ?? const [];
  }

  Future<void> addRoot(String path) async {
    final p = path.trim();
    if (p.isEmpty) return;
    final sp = await SharedPreferences.getInstance();
    final list = (sp.getStringList(_rootsKey) ?? const []).toList();
    if (!list.contains(p)) list.add(p);
    await sp.setStringList(_rootsKey, list);
  }

  Future<void> removeRoot(String path) async {
    final sp = await SharedPreferences.getInstance();
    final list = (sp.getStringList(_rootsKey) ?? const []).toList()
      ..remove(path);
    await sp.setStringList(_rootsKey, list);
  }

  // ── 标签 ────────────────────────────────────────────────

  Future<Map<String, List<String>>> _tags() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_tagsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final obj = jsonDecode(raw);
      if (obj is! Map) return {};
      return obj.map(
        (k, v) => MapEntry(
          '$k',
          v is List ? v.map((e) => '$e').where((e) => e.isNotEmpty).toList() : <String>[],
        ),
      );
    } catch (_) {
      return {};
    }
  }

  Future<List<String>> tagsOf(String path) async => (await _tags())[path] ?? const [];

  /// 一次性取出全部「路径 → 标签」，供列表过滤/展示用。
  Future<Map<String, List<String>>> tagMap() => _tags();

  Future<void> setTags(String path, List<String> tags) async {
    final sp = await SharedPreferences.getInstance();
    final all = await _tags();
    final clean = tags.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();
    if (clean.isEmpty) {
      all.remove(path);
    } else {
      all[path] = clean;
    }
    await sp.setString(_tagsKey, jsonEncode(all));
  }

  Future<List<String>> allTags() async {
    final all = await _tags();
    final set = <String>{};
    for (final v in all.values) {
      set.addAll(v);
    }
    final list = set.toList()..sort();
    return list;
  }

  // ── 扫描 ────────────────────────────────────────────────

  Future<LocalLibrarySnapshot> scan() async {
    final base = await SettingsService.downloadBaseDir();
    final extraRoots = await roots();
    final books = <LocalLibraryEntry>[];
    final comics = <LocalLibraryEntry>[];

    Future<void> scanBooksDir(Directory dir) async {
      if (!await dir.exists()) return;
      await for (final e in dir.list(followLinks: false)) {
        if (e is! File || !_isBook(e.path)) continue;
        final stat = await e.stat();
        books.add(LocalLibraryEntry(
          path: e.path,
          name: e.path.split(RegExp(r'[/\\]')).last,
          isFolder: false,
          sizeBytes: stat.size,
          itemCount: 1,
          modifiedMs: stat.modified.millisecondsSinceEpoch,
        ));
      }
    }

    Future<void> scanComicsDir(Directory dir) async {
      if (!await dir.exists()) return;
      await for (final e in dir.list(followLinks: false)) {
        if (e is! Directory) continue;
        final entry = await _scanComicFolder(e);
        if (entry != null) comics.add(entry);
      }
    }

    await scanBooksDir(Directory('${base.path}/Books'));
    await scanComicsDir(Directory('${base.path}/Comics'));

    // 用户额外添加的库根：文件按图书，直接子文件夹按漫画（含图片才算）
    for (final root in extraRoots) {
      final d = Directory(root);
      if (!await d.exists()) continue;
      await scanBooksDir(d);
      await scanComicsDir(d);
    }

    books.sort((a, b) => b.modifiedMs.compareTo(a.modifiedMs));
    comics.sort((a, b) => b.modifiedMs.compareTo(a.modifiedMs));

    final dupBooks = await _findDuplicateBooks(books);
    final dupComics = _findDuplicateComics(comics);
    final total = [...books, ...comics].fold<int>(0, (a, b) => a + b.sizeBytes);

    return LocalLibrarySnapshot(
      books: books,
      comics: comics,
      duplicateBooks: dupBooks,
      duplicateComics: dupComics,
      totalBytes: total,
      roots: [base.path, ...extraRoots],
    );
  }

  Future<LocalLibraryEntry?> _scanComicFolder(Directory dir) async {
    var images = 0;
    var size = 0;
    var modified = 0;
    try {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is! File || !_isImage(e.path)) continue;
        images++;
        final stat = await e.stat();
        size += stat.size;
        final ms = stat.modified.millisecondsSinceEpoch;
        if (ms > modified) modified = ms;
      }
    } catch (_) {
      return null;
    }
    if (images == 0) return null;
    return LocalLibraryEntry(
      path: dir.path,
      name: dir.path.split(RegExp(r'[/\\]')).last,
      isFolder: true,
      sizeBytes: size,
      itemCount: images,
      modifiedMs: modified,
    );
  }

  Future<String> _headHash(File f) async {
    RandomAccessFile? raf;
    try {
      raf = await f.open();
      final len = await f.length();
      final n = len > 65536 ? 65536 : len;
      final bytes = await raf.read(n);
      return md5.convert(bytes).toString();
    } catch (_) {
      return '';
    } finally {
      await raf?.close();
    }
  }

  Future<List<DuplicateGroup>> _findDuplicateBooks(
    List<LocalLibraryEntry> books,
  ) async {
    final bySize = <int, List<LocalLibraryEntry>>{};
    for (final b in books) {
      if (b.sizeBytes <= 0) continue;
      bySize.putIfAbsent(b.sizeBytes, () => []).add(b);
    }
    final out = <DuplicateGroup>[];
    for (final group in bySize.values) {
      if (group.length < 2) continue;
      final byHash = <String, List<LocalLibraryEntry>>{};
      for (final b in group) {
        final h = await _headHash(File(b.path));
        if (h.isEmpty) continue;
        byHash.putIfAbsent(h, () => []).add(b);
      }
      for (final e in byHash.entries) {
        if (e.value.length > 1) {
          out.add(DuplicateGroup(key: '${e.value.first.sizeBytes}/${e.key}', entries: e.value));
        }
      }
    }
    out.sort((a, b) => b.entries.length.compareTo(a.entries.length));
    return out;
  }

  List<DuplicateGroup> _findDuplicateComics(List<LocalLibraryEntry> comics) {
    final byKey = <String, List<LocalLibraryEntry>>{};
    for (final c in comics) {
      // 标题去掉 `_local_xxx` 后缀与标点，用于识别同一本漫画的重复目录
      final key = c.name
          .replaceAll(RegExp(r'_local_\d+$'), '')
          .toLowerCase()
          .replaceAll(RegExp(r'[\s_\-·.]+'), '');
      if (key.isEmpty) continue;
      byKey.putIfAbsent(key, () => []).add(c);
    }
    final out = <DuplicateGroup>[];
    for (final e in byKey.entries) {
      if (e.value.length > 1) {
        out.add(DuplicateGroup(key: e.key, entries: e.value));
      }
    }
    out.sort((a, b) => b.entries.length.compareTo(a.entries.length));
    return out;
  }

  // ── 回收站 ──────────────────────────────────────────────

  Future<Directory> _binDir() async {
    final base = await SettingsService.downloadBaseDir();
    final d = Directory('${base.path}/.recycle_bin');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<File> _binIndex() async => File('${(await _binDir()).path}/index.json');

  Future<List<RecycleEntry>> recycleEntries() async {
    try {
      final f = await _binIndex();
      if (!await f.exists()) return <RecycleEntry>[];
      final raw = jsonDecode(await f.readAsString());
      if (raw is! List) return <RecycleEntry>[];
      final list = raw.map(RecycleEntry.fromJson).whereType<RecycleEntry>().toList()
        ..sort((a, b) => b.deletedAtMs.compareTo(a.deletedAtMs));
      return list;
    } catch (_) {
      return <RecycleEntry>[];
    }
  }

  Future<void> _persistRecycle(List<RecycleEntry> list) async {
    final f = await _binIndex();
    await f.writeAsString(jsonEncode(list.map((e) => e.toJson()).toList()));
  }

  Future<void> moveToRecycle(LocalLibraryEntry entry) async {
    final bin = await _binDir();
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final destDir = Directory('${bin.path}/$id');
    await destDir.create(recursive: true);
    final name = entry.name.isEmpty
        ? (entry.isFolder ? 'folder' : 'file')
        : entry.name;
    final target = '${destDir.path}/$name';

    if (entry.isFolder) {
      final src = Directory(entry.path);
      if (await src.exists()) {
        try {
          await src.rename(target);
        } catch (_) {
          await _copyDir(src, Directory(target));
          await src.delete(recursive: true);
        }
      }
    } else {
      final src = File(entry.path);
      if (await src.exists()) {
        try {
          await src.rename(target);
        } catch (_) {
          await src.copy(target);
          await src.delete();
        }
      }
    }

    final list = await recycleEntries();
    list.add(RecycleEntry(
      id: id,
      name: name,
      originalPath: entry.path,
      recyclePath: target,
      isFolder: entry.isFolder,
      sizeBytes: entry.sizeBytes,
      deletedAtMs: DateTime.now().millisecondsSinceEpoch,
    ));
    await _persistRecycle(list);
  }

  Future<void> _copyDir(Directory src, Directory dest) async {
    await dest.create(recursive: true);
    await for (final e in src.list(recursive: false, followLinks: false)) {
      final name = e.path.split(RegExp(r'[/\\]')).last;
      if (e is Directory) {
        await _copyDir(e, Directory('${dest.path}/$name'));
      } else if (e is File) {
        await e.copy('${dest.path}/$name');
      }
    }
  }

  Future<bool> restore(RecycleEntry entry) async {
    try {
      final original = entry.originalPath;
      final parent = Directory(original).parent;
      if (!await parent.exists()) await parent.create(recursive: true);
      var target = original;
      // 原位置已有同名文件/目录 → 加后缀，避免覆盖
      if (await FileSystemEntity.isDirectory(original) ||
          await FileSystemEntity.isFile(original)) {
        target = '$original (restored ${DateTime.now().millisecondsSinceEpoch})';
      }
      if (entry.isFolder) {
        final src = Directory(entry.recyclePath);
        if (!await src.exists()) return false;
        await src.rename(target);
      } else {
        final src = File(entry.recyclePath);
        if (!await src.exists()) return false;
        await src.rename(target);
      }
    } catch (_) {
      return false;
    }
    final list = await recycleEntries();
    list.removeWhere((e) => e.id == entry.id);
    await _persistRecycle(list);
    return true;
  }

  Future<void> purge(RecycleEntry entry) async {
    try {
      final parent = Directory(entry.recyclePath).parent;
      if (entry.isFolder) {
        final d = Directory(entry.recyclePath);
        if (await d.exists()) await d.delete(recursive: true);
      } else {
        final f = File(entry.recyclePath);
        if (await f.exists()) await f.delete();
      }
      if (await parent.exists()) await parent.delete(recursive: true);
    } catch (_) {}
    final list = await recycleEntries();
    list.removeWhere((e) => e.id == entry.id);
    await _persistRecycle(list);
  }

  Future<void> emptyRecycle() async {
    final bin = await _binDir();
    try {
      await for (final e in bin.list(followLinks: false)) {
        if (e.path.endsWith('index.json')) continue;
        await e.delete(recursive: true);
      }
    } catch (_) {}
    await _persistRecycle(const []);
  }

  /// 默认库根（展示用）
  static Future<String> defaultRootLabel() async {
    final docs = await getApplicationDocumentsDirectory();
    return docs.path;
  }
}
