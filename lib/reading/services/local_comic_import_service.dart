/// 本地漫画导入：图片多选 / 文件夹 / ZIP / CBZ。
///
/// 落盘位置与「下载漫画」完全一致（DownloadService 的 Comics/<标题>_<pathWord>/<章节>/），
/// 再向 DownloadService 注册完成态任务 ⇒ 现有书架离线阅读、进度、下载记录全部复用。
library;

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';

import 'download_service.dart';

class LocalComicImportResult {
  const LocalComicImportResult({
    required this.pathWord,
    required this.title,
    required this.chapterCount,
    required this.imageCount,
  });

  final String pathWord;
  final String title;
  final int chapterCount;
  final int imageCount;
}

class LocalComicImportService {
  LocalComicImportService._();

  static const Set<String> imageExts = {
    'jpg',
    'jpeg',
    'png',
    'webp',
    'gif',
    'bmp',
  };

  static bool isImage(String name) {
    final i = name.lastIndexOf('.');
    if (i < 0 || i == name.length - 1) return false;
    return imageExts.contains(name.substring(i + 1).toLowerCase());
  }

  /// 自然排序：`第2话` 在 `第10话` 前面（避免纯字典序把 10 排到 2 前）。
  static int naturalCompare(String a, String b) {
    final ra = RegExp(r'(\d+|\D+)').allMatches(a.toLowerCase());
    final rb = RegExp(r'(\d+|\D+)').allMatches(b.toLowerCase());
    final la = ra.map((m) => m.group(0)!).toList();
    final lb = rb.map((m) => m.group(0)!).toList();
    for (var i = 0; i < la.length && i < lb.length; i++) {
      final x = la[i], y = lb[i];
      final nx = int.tryParse(x), ny = int.tryParse(y);
      final c = (nx != null && ny != null) ? nx.compareTo(ny) : x.compareTo(y);
      if (c != 0) return c;
    }
    return la.length.compareTo(lb.length);
  }

  static String _extOf(String name) {
    final i = name.lastIndexOf('.');
    return i < 0 ? '.jpg' : name.substring(i).toLowerCase();
  }

  // ── 选择器 ──────────────────────────────────────────────

  static Future<List<PlatformFile>> pickImages() async {
    final files = await FilePicker.pickFiles(type: FileType.image);
    return files.where((f) => isImage(f.name)).toList();
  }

  static Future<String?> pickFolder() => FilePicker.getDirectoryPath();

  static Future<PlatformFile?> pickArchive() => FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['zip', 'cbz'],
      );

  // ── 导入 ────────────────────────────────────────────────

  /// 多选图片 → 单章「第1话」。
  static Future<LocalComicImportResult> importImages(
    List<PlatformFile> files, {
    required String title,
  }) async {
    final list = files.where((f) => isImage(f.name)).toList()
      ..sort((a, b) => naturalCompare(a.name, b.name));
    if (list.isEmpty) throw Exception('没有选中图片');
    final chapters = [
      _ImportChapter(
        name: '第1话',
        images: [
          for (final f in list) _ImportImage(name: f.name, read: f.readAsBytes),
        ],
      ),
    ];
    return _writeAll(title, chapters);
  }

  /// 文件夹 → 每个含图片的子目录一话；根目录图片单独一话。
  static Future<LocalComicImportResult> importFolder(
    String dirPath, {
    required String title,
  }) async {
    final root = Directory(dirPath);
    if (!await root.exists()) throw Exception('文件夹不存在');
    final grouped = <String, List<File>>{};
    await for (final e in root.list(recursive: true, followLinks: false)) {
      if (e is! File || !isImage(e.path)) continue;
      final rel = e.path.substring(root.path.length).replaceAll('\\', '/');
      final parts = rel.split('/').where((p) => p.isNotEmpty).toList();
      final parent = parts.length >= 2 ? parts[parts.length - 2] : '';
      grouped.putIfAbsent(parent, () => []).add(e);
    }
    if (grouped.isEmpty) throw Exception('文件夹里没有图片');
    final chapters = _buildChapters(
      grouped.map(
        (k, v) => MapEntry(
          k,
          v..sort((a, b) => naturalCompare(a.path, b.path)),
        ),
      ),
      (file) => _ImportImage(
        name: file.path.split(RegExp(r'[/\\]')).last,
        read: () => file.readAsBytes(),
      ),
    );
    return _writeAll(title, chapters);
  }

  /// ZIP / CBZ → 按图片所在子目录分话（单目录则一话）。
  static Future<LocalComicImportResult> importArchive(
    PlatformFile file, {
    required String title,
  }) async {
    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    final grouped = <String, List<ArchiveFile>>{};
    for (final af in archive.files) {
      if (!af.isFile || !isImage(af.name)) continue;
      final parts =
          af.name.replaceAll('\\', '/').split('/').where((p) => p.isNotEmpty).toList();
      final parent = parts.length >= 2 ? parts[parts.length - 2] : '';
      grouped.putIfAbsent(parent, () => []).add(af);
    }
    if (grouped.isEmpty) throw Exception('压缩包里没有图片');
    final chapters = _buildChapters(
      grouped.map(
        (k, v) => MapEntry(
          k,
          v..sort((a, b) => naturalCompare(a.name, b.name)),
        ),
      ),
      (af) => _ImportImage(
        name: af.name.split('/').last,
        read: () async => af.content as List<int>,
      ),
    );
    return _writeAll(title, chapters);
  }

  /// 把「父目录 → 图片列表」变成有序章节。
  static List<_ImportChapter> _buildChapters<T>(
    Map<String, List<T>> grouped,
    _ImportImage Function(T) toImage,
  ) {
    final keys = grouped.keys.toList()
      ..sort((a, b) {
        if (a.isEmpty) return -1;
        if (b.isEmpty) return 1;
        return naturalCompare(a, b);
      });
    final single = keys.length == 1;
    final out = <_ImportChapter>[];
    var n = 0;
    for (final k in keys) {
      n++;
      final name = k.isEmpty
          ? (single ? '第1话' : '第${n}话')
          : k;
      out.add(_ImportChapter(
        name: name,
        images: grouped[k]!.map(toImage).toList(),
      ));
    }
    return out;
  }

  static Future<LocalComicImportResult> _writeAll(
    String title,
    List<_ImportChapter> chapters,
  ) async {
    final cleanTitle = title.trim().isEmpty ? '本地漫画' : title.trim();
    final pathWord = 'local_${DateTime.now().millisecondsSinceEpoch}';
    final inputs = <LocalComicChapterInput>[];
    var cover = '';
    var totalImages = 0;
    var order = 0;

    for (final ch in chapters) {
      if (ch.images.isEmpty) continue;
      final chId = 'c${order + 1}';
      final dir = await DownloadService()
          .prepareLocalComicChapterDir(pathWord, cleanTitle, chId);
      var idx = 0;
      for (final img in ch.images) {
        idx++;
        final target =
            File('${dir.path}/${idx.toString().padLeft(4, '0')}${_extOf(img.name)}');
        final bytes = await img.read();
        await target.writeAsBytes(bytes, flush: false);
        if (cover.isEmpty) cover = target.path;
        totalImages++;
      }
      inputs.add(LocalComicChapterInput(
        id: chId,
        name: ch.name,
        order: order,
        imageCount: ch.images.length,
      ));
      order++;
    }

    if (inputs.isEmpty) throw Exception('没有可导入的图片');
    await DownloadService().registerLocalComic(
      pathWord: pathWord,
      title: cleanTitle,
      cover: cover,
      chapters: inputs,
    );
    return LocalComicImportResult(
      pathWord: pathWord,
      title: cleanTitle,
      chapterCount: inputs.length,
      imageCount: totalImages,
    );
  }
}

class _ImportImage {
  const _ImportImage({required this.name, required this.read});

  final String name;
  final Future<List<int>> Function() read;
}

class _ImportChapter {
  const _ImportChapter({required this.name, required this.images});

  final String name;
  final List<_ImportImage> images;
}
