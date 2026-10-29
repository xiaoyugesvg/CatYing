import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/music/models/models.dart';

/// 逐字歌词（YRC）解析测试。
///
/// ── 为什么必须测 ────────────────────────────────────────────────
/// 高亮是按 `LyricLine.text` 的**字符下标**切的
/// （见 `LyricLine.charIndexAt`），所以：
///   `words.map((w) => w.text).join()` **必须严格等于** `line.text`
/// 一旦不等，高亮就会跑到别的字上（而且是"看起来能跑"的那种错）。
///
/// 这个不变量很容易被正则/切片的小改动破坏，所以用测试钉死。
void main() {
  group('YRC 逐字歌词解析', () {
    test('基本解析：字与行文本严格对齐', () {
      // 网易云 YRC 真实形状：[行起,行长](字起,字长,保留)字
      const yrc = '[15600,300](15600,120,0)你(15720,180,0)好';
      final lines = LyricParser.parseYrc(yrc);

      expect(lines.length, 1, reason: '一行');
      final l = lines.first;
      expect(l.time, const Duration(milliseconds: 15600));
      expect(l.text, '你好', reason: '行文本');
      expect(l.hasWords, isTrue, reason: '应识别为逐字歌词');

      // 关键不变量：拼接与行文本一字不差
      expect(l.words.map((w) => w.text).join(), l.text,
          reason: '⚠️ 字的拼接必须等于行文本，否则高亮下标会错位');
    });

    test('多行 + 多字', () {
      const yrc = '[0,200](0,100,0)一(100,100,0)二\n'
          '[1000,300](1000,150,0)三(1150,150,0)四';
      final lines = LyricParser.parseYrc(yrc);

      expect(lines.length, 2);
      expect(lines[0].text, '一二');
      expect(lines[1].text, '三四');
      expect(lines[0].time, Duration.zero);
      expect(lines[1].time, const Duration(milliseconds: 1000));
      for (final l in lines) {
        expect(l.words.map((w) => w.text).join(), l.text);
      }
    });

    test('排序：乱序输入也应按时间排好', () {
      const yrc = '[5000,100](5000,100,0)后\n'
          '[1000,100](1000,100,0)前';
      final lines = LyricParser.parseYrc(yrc);
      expect(lines.first.text, '前');
      expect(lines.last.text, '后');
    });

    test('空/非 YRC 输入返回空列表（不抛异常）', () {
      expect(LyricParser.parseYrc(null), isEmpty);
      expect(LyricParser.parseYrc(''), isEmpty);
      expect(LyricParser.parseYrc('   '), isEmpty);
      // 标准 LRC 不是 YRC → 不解析（调用方会回落到 parse）
      expect(LyricParser.parseYrc('[00:12.34]普通歌词'), isEmpty);
    });

    test('纯标签无文本的行被跳过', () {
      const yrc = '[0,0]\n[100,200](100,200,0)有词';
      final lines = LyricParser.parseYrc(yrc);
      expect(lines.length, 1);
      expect(lines.first.text, '有词');
    });

    group('charIndexAt：高亮到第几个字', () {
      final line = LyricParser.parseYrc(
        '[0,1000](0,500,0)你(500,500,0)好',
      ).first;

      test('行开始前 → 0（还没唱）', () {
        expect(line.charIndexAt(const Duration(milliseconds: -1)), 0);
      });

      test('第一个字唱到一半 → 高亮到该字中间', () {
        // 第一字 0~500ms，250ms 时是它的一半 → "你"高亮 0.5 字（round → 1）
        final n = line.charIndexAt(const Duration(milliseconds: 250));
        expect(n, greaterThanOrEqualTo(0));
        expect(n, lessThanOrEqualTo(1),
            reason: '250ms 时最多只应高亮第一个字');
      });

      test('第一个字唱完 → 高亮 1 个字', () {
        // 500ms 正好是第一字结束，第二字开始
        expect(line.charIndexAt(const Duration(milliseconds: 500)), 1);
      });

      test('两个字都唱完 → 整行高亮', () {
        expect(line.charIndexAt(const Duration(milliseconds: 1000)), 2);
        expect(line.charIndexAt(const Duration(seconds: 10)), 2,
            reason: '超出范围也应封顶在整行长度');
      });

      test('无逐字数据时整行高亮（回落到 LRC 行为）', () {
        final plain = LyricParser.parse('[00:01.00]普通一行').first;
        expect(plain.hasWords, isFalse);
        expect(plain.charIndexAt(const Duration(seconds: 5)), plain.text.length);
      });
    });
  });
}
