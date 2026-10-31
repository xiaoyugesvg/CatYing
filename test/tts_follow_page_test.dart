import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/reading/models/book_content.dart';
import 'package:tvbox/reading/services/book_paginator.dart';

/// 朗读跟随翻页（用户 2026-10-29：「为啥朗读的时候不跟随翻页呢」）
///
/// 这里锁住的是「段落 → 页号」这一步：翻页本身是 PageView 的事，
/// 但**落到哪一页**必须算对，否则朗读一跟就翻错页。
void main() {
  // 造页：每页放 [blocks] 里的块下标
  BookPage pageOf(List<int> blocks) => BookPage(
    firstBlockIndex: blocks.isEmpty ? -1 : blocks.first,
    entries: [
      for (final b in blocks)
        PageEntry(const ParagraphBlock(''), blockIndex: b),
    ],
  );

  group('pageOfBlockInRange', () {
    test('找到块所在的页', () {
      final pages = [
        pageOf([0, 1]),
        pageOf([2, 3]),
        pageOf([4]),
      ];
      expect(BookPaginator.pageOfBlockInRange(pages, 0), 0);
      expect(BookPaginator.pageOfBlockInRange(pages, 3), 1);
      expect(BookPaginator.pageOfBlockInRange(pages, 4), 2);
    });

    test('块不在列表里 → null（不猜）', () {
      final pages = [
        pageOf([0, 1]),
        pageOf([2]),
      ];
      expect(BookPaginator.pageOfBlockInRange(pages, 99), isNull);
    });

    test('限定范围时跳过无缝拼接进来的下一章页', () {
      // 0-1 是本章，2-3 是拼进来的下一章
      final pages = [
        pageOf([0]),
        pageOf([1]),
        pageOf([2]),
      ];
      expect(
        BookPaginator.pageOfBlockInRange(pages, 1, from: 0, to: 2),
        1,
      );
      // 下一章的块 2 在 [0,2) 里找不到
      expect(
        BookPaginator.pageOfBlockInRange(pages, 2, from: 0, to: 2),
        isNull,
      );
      // 放开范围就能找到
      expect(BookPaginator.pageOfBlockInRange(pages, 2), 2);
    });

    test('长段落被切成两块时，前半在后页也能命中', () {
      // 同一个块 5 同时出现在两页（分页器按行断开）
      final pages = [
        pageOf([4, 5]),
        pageOf([5]),
      ];
      // 取**第一处**（用户刚念到这一段时应该先看到它的开头）
      expect(BookPaginator.pageOfBlockInRange(pages, 5), 0);
    });

    test('越界的 from/to 不会抛异常', () {
      final pages = [pageOf([0])];
      expect(
        () => BookPaginator.pageOfBlockInRange(pages, 0, from: 9, to: 99),
        returnsNormally,
      );
      expect(
        BookPaginator.pageOfBlockInRange(pages, 0, from: 9, to: 99),
        isNull,
      );
    });
  });

  group('pageIndexOf 与 pageOfBlockInRange 的分工', () {
    test('pageIndexOf 只保证"不早于"，精确落页要靠 pageOfBlockInRange', () {
      final pages = [
        pageOf([0]),
        pageOf([1]),
      ];
      // 块 1 的首页是第 1 页：两者一致
      expect(BookPaginator.pageIndexOf(pages, 1), 1);
      expect(BookPaginator.pageOfBlockInRange(pages, 1), 1);
      // 但 firstBlockIndex 与 entries 不一致时（分页器未填 blockIndex 的旧数据），
      // pageOfBlockInRange 会诚实返回 null，而不是像 pageIndexOf 那样猜一个页
      final legacy = [
        BookPage(
          firstBlockIndex: 0,
          entries: [PageEntry(const ParagraphBlock(''))], // blockIndex 默认 -1
        ),
      ];
      expect(BookPaginator.pageIndexOf(legacy, 0), 0);
      expect(BookPaginator.pageOfBlockInRange(legacy, 0), isNull);
    });
  });

  // ══════════════════════════════════════════════════════════════
  // 2026-10-31：用户截图「已经播放到下一页了，但是没有自动翻页过去」
  //
  // 根因（读代码定位，不是猜）：
  //   1. `TtsService` 只有 `onDone`（**一整段**念完才 +1），没有段内进度；
  //   2. 阅读器只在 `currentIndex` 变化时触发 `_followTtsSegment`；
  //   3. `_followTtsSegment` 用 `pageOfBlockInRange` —— 恒返回该段的**第一页**。
  // 三条叠加 ⇒ 网文那种半屏长段**跨两页**时：念到第 2 页，`currentIndex` 没变、
  // 目标页还是第 1 页 == 当前页 ⇒ 直接 return ⇒ 画面纹丝不动，直到整段念完。
  //
  // 修法对齐 foliate-js / Legado：朗读位置要能落到"段落内的某一处"，
  // 而不是只能落到"某个段落的开头"。
  // ══════════════════════════════════════════════════════════════

  group('pagesOfBlock：跨页段落要能拿到它覆盖的所有页', () {
    test('段落只在一页时返回单页', () {
      final pages = [
        pageOf([0, 1]),
        pageOf([2, 3]),
      ];
      expect(BookPaginator.pagesOfBlock(pages, 1), [0]);
      expect(BookPaginator.pagesOfBlock(pages, 2), [1]);
    });

    test('段落跨两页时返回两页（这正是原来翻不动的原因）', () {
      // 第 1 段被切成两半：前半在第 0 页、后半在第 1 页
      final pages = [
        pageOf([0, 1]),
        pageOf([1, 2]),
      ];
      expect(
        BookPaginator.pagesOfBlock(pages, 1),
        [0, 1],
        reason: 'pageOfBlockInRange 只会给 0；念到第 1 页时目标页仍是 0 == '
            '当前页 ⇒ 不翻（用户看到的就是"念过去了但画面不动"）',
      );
    });

    test('同一页里同一段出现多个 entry 只记一次', () {
      final pages = [
        BookPage(
          firstBlockIndex: 0,
          entries: [
            PageEntry(const ParagraphBlock('前半'), blockIndex: 5),
            PageEntry(const ParagraphBlock('后半'), blockIndex: 5),
          ],
        ),
      ];
      expect(BookPaginator.pagesOfBlock(pages, 5), [0]);
    });

    test('from/to 范围限制生效（不跟到无缝拼接的下一章）', () {
      final pages = [
        pageOf([0]),
        pageOf([1]),
        pageOf([2]),
      ];
      expect(BookPaginator.pagesOfBlock(pages, 2, from: 0, to: 2), isEmpty);
      expect(BookPaginator.pagesOfBlock(pages, 2, from: 0, to: 3), [2]);
    });

    test('pageOfBlockInRange 行为不变（别处还在用「取第一页」）', () {
      final pages = [
        pageOf([0, 1]),
        pageOf([1, 2]),
      ];
      expect(BookPaginator.pageOfBlockInRange(pages, 1), 0);
    });
  });

  group('TtsService 必须提供段内进度', () {
    String src() => _stripComments(_read('lib/reading/services/tts_service.dart'));

    test('segmentProgress 存在', () {
      expect(
        src().contains('final segmentProgress = 0.0.obs;'),
        isTrue,
        reason: '没有段内进度 ⇒ 阅读器只能"一段一翻"，长段跨页必卡',
      );
    });

    test('每段开念时重置计时', () {
      final s = src();
      expect(s.contains('void _startSegClock('), isTrue);
      final i = s.indexOf('Future<void> _speakCurrent()');
      expect(i, greaterThan(-1));
      expect(
        s.substring(i, i + 900).contains('_startSegClock(seg)'),
        isTrue,
        reason: '系统朗读每段开头要重起表，否则进度会一路累加',
      );
    });

    test('暂停要停表、继续要扣掉暂停时长', () {
      final s = src();
      expect(s.contains('_segPausedAt'), isTrue,
          reason: '不记暂停时刻，暂停 10 分钟再继续会一下跳到段尾');
      expect(s.contains('_segPausedAcc'), isTrue,
          reason: '要把暂停时长从"已念时长"里扣掉');
    });

    test('整章念完要停表（否则 4Hz 空转）', () {
      final s = src();
      expect(s.contains('void _stopSegClock('), isTrue);
      final i = s.indexOf('void _onSegmentDone()');
      expect(i, greaterThan(-1));
      expect(
        s.substring(i, i + 800).contains('_stopSegClock()'),
        isTrue,
      );
    });
  });

  group('阅读器要按段内进度翻页', () {
    test('_followTtsSegment 用 pagesOfBlock，不再用 pageOfBlockInRange', () {
      final s = _stripComments(
          _read('lib/reading/pages/reader_parts/reader_part_03.dart'));
      final i = s.indexOf('void _followTtsSegment()');
      expect(i, greaterThan(-1));
      final body = s.substring(i, i + 1600);
      expect(body.contains('BookPaginator.pagesOfBlock('), isTrue,
          reason: '只用 pageOfBlockInRange 就永远停在该段首页');
      expect(body.contains('pageOfBlockInRange'), isFalse,
          reason: '这里不该再用「取第一页」的旧接口');
      expect(body.contains('segmentProgress'), isTrue,
          reason: '跨页时要用段内进度选页，否则还是不动');
    });

    test('双页模式要把页号换成 spread 号', () {
      final s = _stripComments(
          _read('lib/reading/pages/reader_parts/reader_part_03.dart'));
      final i = s.indexOf('void _jumpToReadingPage(int page)');
      expect(i, greaterThan(-1));
      final body = s.substring(i, i + 900);
      expect(body.contains('_dualPageActive'), isTrue,
          reason: '双页模式下 PageView 的 item 是 spread（[0],(1,2),(3,4)…），'
              '直接把页号当 index 会翻错位置，而且每个 tick 重翻');
      expect(body.contains('(page + 1) ~/ 2'), isTrue,
          reason: '页 → spread 的映射必须与 _contentArea 里构造 spreads 的规则一致');
    });

    test('段内进度也要驱动翻页（不能只监听换段）', () {
      final s = _stripComments(
          _read('lib/reading/pages/reader_parts/reader_part_01.dart'));
      expect(s.contains('_ttsProgressWorker'), isTrue,
          reason: '只监听 currentIndex ⇒ 段内跨页时根本不触发');
      expect(s.contains('ever<double>(_tts.segmentProgress'), isTrue);
      expect(s.contains('_ttsProgressWorker?.dispose()'), isTrue,
          reason: 'TtsService 是单例，不撤监听会一直持有已销毁的 State');
    });

    test('滚动模式：长段要按进度滚，不能钉死在 35%', () {
      final s = _stripComments(
          _read('lib/reading/pages/reader_parts/reader_part_02.dart'));
      final i = s.indexOf('Widget _wrapWithHighlight(int pi, Widget child)');
      expect(i, greaterThan(-1));
      final body = s.substring(i, i + 2800);
      expect(body.contains('segmentProgress'), isTrue,
          reason: '段落比视口高时，固定 alignment 会让段首永远停在同一处');
      expect(body.contains('viewportDimension'), isTrue,
          reason: '要先判「这段是不是比一屏还高」');
    });
  });
}

String _read(String relative) => File(relative).readAsStringSync();

String _stripComments(String src) {
  final noBlock = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  return noBlock
      .split('\n')
      .map((line) {
        final i = line.indexOf('//');
        return i < 0 ? line : line.substring(0, i);
      })
      .join('\n');
}
