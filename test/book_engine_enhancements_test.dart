import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/reading/services/chapter_alignment.dart';
import 'package:tvbox/reading/utils/text_match.dart';
import 'package:tvbox/reading/novel_source/analyze/analyze_rule.dart';
import 'package:tvbox/reading/services/book_source_compatibility.dart';
import 'package:tvbox/reading/models/book_source.dart';
import 'package:tvbox/reading/novel_source/analyze/sync_http_bridge.dart';

void main() {
  group('换源章节对齐', () {
    test('标题完全一致 → 精确命中', () {
      final r = ChapterAlignment.align(
        oldTitles: const ['第一章 开端', '第二章 相遇', '第三章 离别'],
        oldIndex: 1,
        newTitles: const ['第一章 开端', '第二章 相遇', '第三章 离别'],
      );
      expect(r, isNotNull);
      expect(r!.index, 1);
      expect(r.matchedByTitle, isTrue);
      expect(r.score, 1);
    });

    test('章节号一致、标题带装饰 → 命中同一章', () {
      final r = ChapterAlignment.align(
        oldTitles: const ['第12章 夜行', '第13章 天亮'],
        oldIndex: 0,
        newTitles: const ['012、夜行（精校）', '013、天亮（精校）'],
      );
      expect(r, isNotNull);
      expect(r!.index, 0);
      expect(r.matchedByTitle, isTrue);
    });

    test('中文数字章节号（第十二回）', () {
      final r = ChapterAlignment.align(
        oldTitles: const ['第十一回 风起', '第十二回 云涌', '第十三回 雨落'],
        oldIndex: 1,
        newTitles: const ['第10回 前夜', '第11回 风起', '第12回 云涌', '第13回 雨落'],
      );
      expect(r, isNotNull);
      expect(r!.index, 2);
      expect(r.matchedByTitle, isTrue);
    });

    test('标题完全对不上 → 按进度比例兜底', () {
      final r = ChapterAlignment.align(
        oldTitles: const ['a1', 'b2', 'c3', 'd4', 'e5'],
        oldIndex: 2,
        newTitles: const ['x1', 'x2', 'x3', 'x4', 'x5'],
      );
      expect(r, isNotNull);
      expect(r!.ratioFallback, isTrue);
      expect(r.index, 2);
    });

    test('旧下标非法 / 新目录为空 → null', () {
      expect(
        ChapterAlignment.align(
            oldTitles: const ['a'], oldIndex: 3, newTitles: const ['b']),
        isNull,
      );
      expect(
        ChapterAlignment.align(
            oldTitles: const ['a'], oldIndex: 0, newTitles: const []),
        isNull,
      );
    });

    test('进度键格式固定（阅读器与换源共用）', () {
      expect(ChapterAlignment.progressKey('src1', '斗罗大陆'),
          'bsr.progress.src1.斗罗大陆');
    });
  });

  group('聚合搜索三级排序', () {
    test('完全相同 / 包含 / 模糊 / 不相关', () {
      expect(matchRank('斗罗大陆', '斗罗大陆'), 0);
      expect(matchRank('斗罗大陆（精校版）', '斗罗大陆'), 1);
      expect(matchRank('斗罗大陆2绝世唐门', '斗罗大陆'), 1);
      expect(matchRank('完全无关的书', '斗罗大陆'), 3);
    });

    test('归一化：全角/标点/空格不影响匹配', () {
      expect(matchRank('斗罗大陆：终极斗罗', '斗罗大陆 终极斗罗'), 0);
    });
  });

  group('书源兼容性静态分析', () {
    test('缺目录/正文规则 → blocker', () {
      final s = BookSource.fromJson({
        'bookSourceName': '坏源',
        'bookSourceUrl': 'https://example.com',
      })!;
      final r = BookSourceCompatibility.analyze(s);
      expect(r.usable, isFalse);
      expect(
          r.issues.where((e) => e.isBlocker).map((e) => e.field),
          containsAll(['ruleToc.chapterList', 'ruleContent.content']));
    });

    test('完整规则 → 无 blocker', () {
      final s = BookSource.fromJson({
        'bookSourceName': '好源',
        'bookSourceUrl': 'https://example.com',
        'ruleSearch': {'bookList': '.item'},
        'ruleToc': {'chapterList': '.chapter'},
        'ruleContent': {'content': '.content'},
      })!;
      final r = BookSourceCompatibility.analyze(s);
      expect(r.usable, isTrue);
    });

    test('老版 ruleFindUrl 且无 exploreUrl → warning', () {
      final s = BookSource.fromJson({
        'bookSourceName': '老源',
        'bookSourceUrl': 'https://example.com',
        'ruleFindUrl': 'x',
        'ruleToc': {'chapterList': '.c'},
        'ruleContent': {'content': '.t'},
      })!;
      final r = BookSourceCompatibility.analyze(s);
      expect(r.usable, isTrue);
      expect(r.issues.any((e) => e.field == 'ruleFindUrl'), isTrue);
    });
  });

  group('AES 加密/解密往返', () {
    test('aesEncodeToString → aesBase64DecodeToString', () {
      final rule = AnalyzeRule();
      const key = '1234567890abcdef';
      const iv = '1234567890abcdef';
      final enc = rule.aesEncodeToString(
          'hello 世界', key, 'AES/CBC/PKCS7Padding', iv);
      expect(enc.isNotEmpty, isTrue);
      final dec = rule.aesBase64DecodeToString(
          enc, key, 'AES/CBC/PKCS7Padding', iv);
      expect(dec, 'hello 世界');
    });
  });

  group('二进制通道（java.getByteArray）', () {
    test('x:"b64" 标记被解析成 binary 请求', () {
      final n = SyncHttpBridge.pendingRequest(
        '__LEGADO_NEED__{"k":"BIN GET https://x/a.png","m":"GET",'
        '"u":"https://x/a.png","h":null,"b":null,"x":"b64"}',
      );
      expect(n, isNotNull);
      expect(n!.binary, isTrue);
      expect(n.url, 'https://x/a.png');
    });

    test('普通 ajax 请求不会被误判为 binary', () {
      final n = SyncHttpBridge.pendingRequest(
        '__LEGADO_NEED__{"k":"GET https://x/a","m":"GET",'
        '"u":"https://x/a","h":null,"b":null}',
      );
      expect(n, isNotNull);
      expect(n!.binary, isFalse);
    });
  });
}
