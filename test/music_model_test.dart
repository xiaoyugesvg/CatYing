import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/services/music_api.dart';

/// 音乐模型与解析测试。
///
/// 这些用例原本测的是旧音乐模块的 `MusicLyric` / `MusicTrack` / `MusicUrlResult`；
/// 音乐模块按 Beans 结构重建后（`lib/music/`），**能力必须保持**，
/// 所以这里把用例迁到新 API 上，防止重构把已有的正确行为弄丢：
///   · LRC 多时间标签展开
///   · 翻译按时间戳对齐（容忍毫秒偏差，但不能错配）
///   · 纯文本歌词兜底
///   · 空歌词
///   · 二分查找当前行
///   · VIP 判定
///   · "无免费音源" vs "请求失败" 必须区分
void main() {
  test('LRC 解析：真实数据形态（含多时间标签）', () {
    const raw = '''
[00:00.00] 作词 : 周杰伦
[00:01.00] 作曲 : 周杰伦
[00:12.34]对这个世界 如果你有太多的抱怨
[00:18.00][01:20.00]跌倒了 就不敢继续往前走
[00:25.50]为什么 人要这么的脆弱 堕落
''';
    final l = LyricParser.parse(raw);

    expect(l, isNotEmpty, reason: '不该判成没有歌词');
    expect(l.length, greaterThanOrEqualTo(6), reason: '多时间标签要展开');
    for (var i = 1; i < l.length; i++) {
      expect(l[i].time >= l[i - 1].time, isTrue,
          reason: '第 $i 行时间倒序了');
    }
    final dup = l.where((e) => e.text.contains('跌倒了')).toList();
    expect(dup.length, 2, reason: '[00:18.00][01:20.00] 应展开成两行');
  });

  test('LRC 解析：翻译按时间对齐（容忍毫秒偏差，不错配）', () {
    const raw = '[00:10.00]Hello\n[00:20.00]World';
    const trans = '[00:10.00]你好\n[00:20.10]世界'; // 偏差 100ms
    final l = LyricParser.parse(raw, translation: trans);
    expect(l.length, 2);
    expect(l[0].translation, '你好');
    expect(l[1].translation, '世界', reason: '≤200ms 偏差应对齐');
  });

  test('LRC 解析：偏差过大时不硬配（避免错行）', () {
    const raw = '[00:10.00]Hello\n[00:20.00]World';
    // 第二行翻译差了 2 秒 —— 超过容忍阈值，宁可空着也不要配错
    const trans = '[00:10.00]你好\n[00:22.50]世界';
    final l = LyricParser.parse(raw, translation: trans);
    expect(l[1].translation, isNull, reason: '偏差过大不该硬配');
  });

  test('LRC 解析：纯文本歌词（无时间轴）不当成空', () {
    final l = LyricParser.parse('第一行歌词');
    expect(l, isNotEmpty, reason: '不是 LRC 也要能显示');
    expect(l.first.text, '第一行歌词');
  });

  test('LRC 解析：真的没有歌词时返回空', () {
    expect(LyricParser.parse(''), isEmpty);
    expect(LyricParser.parse('   \n  '), isEmpty);
    expect(LyricParser.parse(null), isEmpty);
  });

  test('indexAt：二分查找当前高亮行', () {
    final l = LyricParser.parse('[00:00.00]a\n[00:10.00]b\n[00:20.00]c');
    expect(LyricParser.indexAt(l, const Duration(seconds: -1)), -1);
    expect(LyricParser.indexAt(l, Duration.zero), 0);
    expect(LyricParser.indexAt(l, const Duration(seconds: 5)), 0);
    expect(LyricParser.indexAt(l, const Duration(seconds: 10)), 1);
    expect(LyricParser.indexAt(l, const Duration(seconds: 15)), 1);
    expect(LyricParser.indexAt(l, const Duration(seconds: 99)), 2);
  });

  test('Song：VIP 判定与时长格式', () {
    // fee=8 是"免费资源"（如翻唱），不该判成 VIP
    const free = Song(id: 1, name: 'a', artists: 'x', fee: 8, duration: 185);
    const vip = Song(id: 2, name: 'b', artists: 'y', fee: 1);
    const paid = Song(id: 3, name: 'c', artists: 'z', fee: 4);
    expect(free.isVIP, isFalse);
    expect(free.likelyFree, isTrue);
    expect(vip.isVIP, isTrue);
    expect(paid.isVIP, isTrue);

    expect(free.formattedDuration, '3:05');
    expect(vip.formattedDuration, '0:00');
  });

  test('Song：跨平台唯一标识', () {
    const a = Song(id: 1, name: 'a', artists: '', source: SongSource.netease);
    const b = Song(id: 1, name: 'a', artists: '', source: SongSource.qq);
    expect(a.identityKey == b.identityKey, isFalse,
        reason: '不同平台相同 id 不能算同一首');
  });

  test('Song：JSON 往返（本地收藏依赖它）', () {
    const s = Song(
      id: 42,
      name: '测试歌',
      artists: '歌手A、歌手B',
      album: '专辑',
      coverUrl: 'http://x/c.jpg',
      duration: 200,
      fee: 8,
    );
    final json = Song.listToJson([s]);
    final back = Song.listFromJson(json);
    expect(back.length, 1);
    expect(back.first.name, '测试歌');
    expect(back.first.artists, '歌手A、歌手B');
    expect(back.first.fee, 8);
    expect(back.first.identityKey, s.identityKey);
  });

  test('MusicUrlInfo：区分"无免费音源"与"失败"', () {
    const noFree = MusicUrlInfo(ok: true, reason: 'no_free_source');
    expect(noFree.playable, isFalse);
    expect(noFree.noFreeSource, isTrue, reason: '这是正常业务结果，不是错误');

    const failed = MusicUrlInfo(ok: false, message: '网络不可达');
    expect(failed.playable, isFalse);
    expect(failed.noFreeSource, isFalse, reason: '失败不该被当成"无免费音源"');

    const ok320 =
        MusicUrlInfo(ok: true, url: 'http://x/a.mp3', bitrate: 320000, type: 'mp3');
    expect(ok320.playable, isTrue);
    expect(ok320.qualityText, contains('320K'));
  });
}
