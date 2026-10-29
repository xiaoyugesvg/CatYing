import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/services/file_export_service.dart';

void main() {
  group('FileExportService.zipDirectory', () {
    late Directory work;
    late Directory outBase;

    setUp(() async {
      work = await Directory.systemTemp.createTemp('export_src_');
      outBase = await Directory.systemTemp.createTemp('export_out_');
    });

    tearDown(() async {
      for (final d in [work, outBase]) {
        try {
          if (await d.exists()) await d.delete(recursive: true);
        } catch (_) {}
      }
    });

    test('目录压成 ZIP，层级与文件都保留', () async {
      Directory('${work.path}/第1话').createSync(recursive: true);
      File('${work.path}/第1话/0001.jpg').writeAsBytesSync([1, 2, 3]);
      File('${work.path}/第1话/0002.jpg').writeAsBytesSync([4, 5, 6]);
      File('${work.path}/info.txt').writeAsStringSync('hello');

      final zipPath = await FileExportService.zipDirectory(
        work,
        archiveName: '测试漫画',
        outputDir: outBase,
      );

      expect(zipPath, isNotNull);
      expect(zipPath!.endsWith('测试漫画.zip'), isTrue);
      final f = File(zipPath);
      expect(f.existsSync(), isTrue);
      expect(f.lengthSync(), greaterThan(0));

      final archive = ZipDecoder().decodeBytes(f.readAsBytesSync());
      final names = archive.files.map((e) => e.name).toList();
      expect(names, contains('info.txt'));
      expect(
        names.any((n) => n.endsWith('0001.jpg')),
        isTrue,
        reason: '章节子目录里的图片必须进包: $names',
      );
    });

    test('目录不存在返回 null', () async {
      final missing = Directory('${work.path}/nope');
      final zipPath = await FileExportService.zipDirectory(
        missing,
        outputDir: outBase,
      );
      expect(zipPath, isNull);
    });

    test('文件名净化：非法字符不进入 zip 名', () async {
      File('${work.path}/a.txt').writeAsStringSync('x');
      final zipPath = await FileExportService.zipDirectory(
        work,
        archiveName: 'a/b:c*?',
        outputDir: outBase,
      );
      expect(zipPath, isNotNull);
      final name = zipPath!.split(RegExp(r'[/\\]')).last;
      expect(name.contains('/'), isFalse);
      expect(name.contains(':'), isFalse);
      expect(name.contains('*'), isFalse);
    });
  });
}
