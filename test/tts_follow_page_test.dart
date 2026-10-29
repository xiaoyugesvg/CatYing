import 'package:flutter/material.dart';
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
}
