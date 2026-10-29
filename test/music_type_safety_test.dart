import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/music/models/models.dart' as music;
import 'package:tvbox/reading/utils/safe_num.dart';

/// 数值类型强转的回归测试。
///
/// ── 这是真机上炸出来的 bug ────────────────────────────────────
/// 音乐搜索页在真机上只显示一行英文：
///     type 'String' is not a subtype of type 'num?' in type cast
/// 根因：Node 引擎的 `mapTrack` 输出 `id: String(id)`（**字符串**），
/// 而 Dart 侧写的是 `(j['id'] as num?)?.toInt()` → 运行时直接抛。
///
/// ── 为什么之前的测试没抓到 ────────────────────────────────────
/// 所有测试的桩数据都用**数字** id（我自己写的，当然按我想的类型给），
/// 而真实引擎给的是字符串。**测试数据和真实数据不一致，等于没测。**
/// 所以这里的用例专门用"引擎实际会返回的类型"。
void main() {
  group('safe_num：能被引擎的任意类型喂饱', () {
    test('int / double / String / null → int', () {
      expect(asInt(42), 42);
      expect(asInt(42.7), 42);
      expect(asInt('42'), 42, reason: '引擎会把 id 转成字符串');
      expect(asInt(' 42 '), 42, reason: '带空白也要能转');
      expect(asInt(null), 0);
      expect(asInt('abc'), 0, reason: '转不了给默认值，不抛');
      expect(asInt(''), 0);
      expect(asInt(true), 1);
    });

    test('int / double / String / null → double', () {
      expect(asDouble(1), 1.0);
      expect(asDouble(1.5), 1.5);
      expect(asDouble('1.5'), 1.5);
      expect(asDouble('3'), 3.0);
      expect(asDouble(null), 0);
      expect(asDouble('x'), 0);
    });

    test('可空版本区分「没有」和「是 0」', () {
      expect(asIntOrNull(null), isNull);
      expect(asIntOrNull(''), isNull);
      expect(asIntOrNull(0), 0, reason: '0 是有效值，不能当没有');
      expect(asIntOrNull('0'), 0);
      expect(asIntOrNull('7'), 7);
      expect(asDoubleOrNull(null), isNull);
      expect(asDoubleOrNull(0), 0.0);
    });

    test('asStr / asBool 宽容处理', () {
      expect(asStr(null), '');
      expect(asStr(5), '5');
      // 配置里用字符串写布尔值很常见
      expect(asBool('true'), isTrue);
      expect(asBool('1'), isTrue);
      expect(asBool('yes'), isTrue);
      expect(asBool(1), isTrue);
      expect(asBool('false'), isFalse);
      expect(asBool('0'), isFalse);
      expect(asBool(null), isFalse);
      expect(asBool(null, fallback: true), isTrue);
    });
  });

  group('Song.fromJson：引擎真实类型不崩（原 bug 复现）', () {
    /// Node mapTrack 的真实输出形态：id 是**字符串**，duration/fee 是数字
    Map<String, dynamic> engineOutput({dynamic id = '186016'}) => {
          'id': id,
          'name': '晴天',
          'artist': '周杰伦',
          'album': '叶惠美',
          'cover': 'https://x/c.jpg',
          'duration': 269, // 秒（引擎已除以 1000）
          'fee': 8,
        };

    test('id 是 String → 不抛，且能解析出正确数值', () {
      final s = music.Song.fromJson(engineOutput());
      expect(s.id, 186016);
      expect(s.name, '晴天');
      expect(s.duration, 269);
      expect(s.fee, 8);
    });

    test('id 是 int（别的接口可能给数字）→ 也能用', () {
      final s = music.Song.fromJson(engineOutput(id: 186016));
      expect(s.id, 186016);
    });

    test('字段缺失 / 类型混乱 → 退化成默认值而不是崩', () {
      final s = music.Song.fromJson({
        'id': 'abc', // 完全不是数字
        'duration': '未知', // 字符串
        'fee': null,
      });
      expect(s.id, 0);
      expect(s.duration, 0);
      expect(s.fee, 0);
      expect(s.name, '', reason: '没名字也不该崩，给空串');
    });

    test('浮点 id / duration（JSON 里 0 与 0.0 混用）不崩', () {
      final s = music.Song.fromJson({
        'id': 12345.0,
        'duration': 269.0,
      });
      expect(s.id, 12345);
      expect(s.duration, 269.0);
    });

    test('往返序列化不丢（列表缓存/恢复播放要用）', () {
      final s = music.Song.fromJson(engineOutput());
      final back = music.Song.fromJson(s.toJson());
      expect(back.id, s.id);
      expect(back.name, s.name);
      expect(back.duration, s.duration);
    });
  });

  group('歌单/榜单的解析口径', () {
    // Playlist 有 fromJson；TopList 没有（在 music_api 里手动构造）。
    // 两者都要能扛住引擎给的字符串数字。
    test('Playlist.fromJson 扛住字符串 id / trackCount', () {
      final p = music.Playlist.fromJson({
        'id': '3778678',
        'name': '热歌榜',
        'trackCount': '200',
      });
      expect(p.id, 3778678);
      expect(p.trackCount, 200);
    });

    test('TopList 用 asInt 解析字符串 id（music_api 的口径）', () {
      final raw = {'id': '19723756', 'name': '飙升榜'};
      final t = music.TopList(
        id: asInt(raw['id']),
        name: (raw['name'] ?? '').toString(),
      );
      expect(t.id, 19723756);
      expect(t.name, '飙升榜');
    });

    test('榜单字段缺失时给默认值而不是崩', () {
      final raw = <String, dynamic>{'name': '飙升榜'};
      final t = music.TopList(
        id: asInt(raw['id']),
        name: (raw['name'] ?? '').toString(),
      );
      expect(t.id, 0);
      expect(t.name, '飙升榜');
    });
  });
}
