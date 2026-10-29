import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/reading/services/local_comic_import_service.dart';

void main() {
  group('本地漫画导入', () {
    test('图片扩展名判定（大小写不敏感）', () {
      expect(LocalComicImportService.isImage('001.jpg'), isTrue);
      expect(LocalComicImportService.isImage('002.JPEG'), isTrue);
      expect(LocalComicImportService.isImage('003.png'), isTrue);
      expect(LocalComicImportService.isImage('004.webp'), isTrue);
      expect(LocalComicImportService.isImage('cover.gif'), isTrue);
      expect(LocalComicImportService.isImage('chapter.cbz'), isFalse);
      expect(LocalComicImportService.isImage('noext'), isFalse);
      expect(LocalComicImportService.isImage('a.txt'), isFalse);
    });

    test('自然排序：第2话在第10话前，001/002/010 顺序正确', () {
      final names = ['第10话', '第2话', '第1话', '第20话', '第3话'];
      names.sort(LocalComicImportService.naturalCompare);
      expect(names, ['第1话', '第2话', '第3话', '第10话', '第20话']);

      final files = ['010.jpg', '002.jpg', '001.jpg', '100.jpg'];
      files.sort(LocalComicImportService.naturalCompare);
      expect(files, ['001.jpg', '002.jpg', '010.jpg', '100.jpg']);
    });
  });
}
