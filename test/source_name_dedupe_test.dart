import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/reading/source/source_manager.dart';

void main() {
  group('内置源名称去重', () {
    test('无重名保持原名', () {
      expect(uniqueSourceName('瓜子漫画', ['其他源']), '瓜子漫画');
    });

    test('重名依次追加（2）（3）', () {
      expect(uniqueSourceName('瓜子漫画', ['瓜子漫画']), '瓜子漫画（2）');
      expect(
        uniqueSourceName('瓜子漫画', ['瓜子漫画', '瓜子漫画（2）']),
        '瓜子漫画（3）',
      );
      expect(
        uniqueSourceName('瓜子漫画', ['瓜子漫画', '瓜子漫画（2）', '瓜子漫画（3）']),
        '瓜子漫画（4）',
      );
    });

    test('其它源已有（2）时不会误判', () {
      expect(uniqueSourceName('瓜子漫画', ['其它（2）']), '瓜子漫画');
    });
  });
}
