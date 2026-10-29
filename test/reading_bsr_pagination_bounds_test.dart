// B08 修复验证：书源阅读器「仿真翻页 + 切章 / 旋屏」越界崩溃（blocker）。
//
// 崩溃链路（复核报告 B08 blocker 条）：
//   1. `_paginate()` 在循环里用**只排了第一批**的 `out` 覆盖 `_pages`，
//      而 `_pageIndex` 要到整章排完才归零 → 短列表配旧页号；
//   2. 渲染层 `_pages[_pageIndex]`（仿真翻页分支）没有上界检查 →
//      `RangeError: Invalid value: Not in inclusive range 0..N`。
//
// 为什么不去 `pumpWidget(BookSourceReaderPage(...))` 直接测：
//   这个页面在 `initState` 里就 `_loadChapter()` → 走**真实书源引擎**
//   （`BookSourceDartEngine.instance` 是**进程单例**，没有注入点）
//   → 测试里拿不到正文、排不出多页 ✓，而"页面由 5 页变 2 页"这个场景
//   必须有**真实多页分页结果**才有意义。硬造需要把引擎/网络/私有字段
//   全开个口子 —— 那与"最小改动、不重构"的约束冲突。
//
// 所以这里测**修复的判定核心**：
//   · `clampPageIndexToPages` —— 从 State 里抽出来的**纯函数**（无副作用、无依赖），
//     `_safePageIndex()` 与 `_paginate()` 循环里的每批夹取都走它 ✓；
//   · 真实 `BookPaginator` 产出的页列表（5 页）+ 旧页号（4）→ 缩到 2 页，
//     断言夹取后**一定**落在合法下标、且**永不抛异常** ✓；
//   · 反向断言：旧写法 `i.clamp(0, len - 1)` 在缩到 0 页时**真会抛** ✓
//     （证明这层保护不是多余 ✓）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/reading/models/book_content.dart';
import 'package:tvbox/reading/pages/book_source_reader_page.dart';
import 'package:tvbox/reading/services/book_paginator.dart';

/// 用真实分页器排 [paragraphs] 段，返回页列表（复刻 `_paginate()` 里的调用姿势）。
List<BookPage> _paginateReally(List<String> paragraphs, {double pageHeight = 220}) {
  final paginator = BookPaginator(
    blocks: <BookBlock>[
      BookBlock.heading('第 1 章', 1),
      ...paragraphs.map(BookBlock.paragraph),
    ],
    viewportWidth: 360,
    viewportHeight: pageHeight,
    typo: const BookTypography(
      fontSize: 18,
      lineHeight: 1.9,
      padding: 20,
      verticalPadding: 16,
      fontFamily: null,
    ),
    chapterStarts: const {0},
  );
  final out = <BookPage>[];
  while (!paginator.finished) {
    paginator.stepInto(out, chunk: 60);
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ── A1 对话气泡：渲染高度绝不能超出页高（"气泡出整个屏幕"回归）──────
  //
  // 用户实测：开了对话气泡后，气泡连同里面的文字**溢出屏幕**。
  // 根因：气泡把对话行缩到 ~72% 屏宽 + 加 12/8 内衬 ✗，而分页器原来一律按
  //       **正文全宽**度量 ✓ ⇒ 渲染比量出来多折很多行 ⇒ 页底溢出 ✗。
  // 这里做**独立复算**（不复用分页器内部记账）：按"渲染会怎么画"重新量每页
  // 高度，断言 ≤ 页高；并用**旧行为**（分页不感知气泡）做反向断言，证明这个
  // 修复不是多余的 —— 旧行为下**必然**有页溢出 ✓。
  group('A1 对话气泡不得溢出页高', () {
    // 与 `book_source_reader_page.dart` 的 A1 常量一致（渲染与分页同一真源）
    const kBubbleWidthFactor = 0.72;
    const kBubblePadH = 12.0;
    const kBubblePadV = 8.0;
    const kBubbleBorder = 1.0;

    const viewportW = 360.0;
    const viewportH = 300.0;
    const typo = BookTypography(
      fontSize: 18,
      lineHeight: 1.9,
      padding: 20,
      verticalPadding: 16,
      fontFamily: null,
    );
    // 与分页器同一套页高换算（BookPaginator._pageHeight）
    // （`typo.xxx` 不是 const 表达式 ⇒ 这里必须用 final）
    final pageH = viewportH - typo.verticalPadding * 2 - 4.0;
    final contentW = viewportW - typo.padding * 2;

    /// 复刻阅读器侧的气泡内宽：内容区与 `0.72×视口` 取小，再扣左右内衬+边框
    double bubbleTextW() {
      final factorW = viewportW * kBubbleWidthFactor;
      final maxW = contentW < factorW ? contentW : factorW;
      return maxW - (kBubblePadH + kBubbleBorder) * 2;
    }

    double textH(String text, TextStyle style, StrutStyle strut, double maxW) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: style),
        strutStyle: strut,
        textScaler: TextScaler.noScaling,
        textHeightBehavior: const TextHeightBehavior(),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: maxW);
      final h = tp.height;
      tp.dispose();
      return h;
    }

    /// 按"渲染实际占用"复算一页内容总高。
    /// [asBubble] = 该页是否按气泡渲染（等价于阅读器开了对话气泡）。
    /// 末条之后**不计**段间距（分页器是先判 `totalH` 放得下、再扣间距的）✓
    double renderedPageH(BookPage page, List<BookBlock> blocks, bool asBubble) {
      var h = 0.0;
      for (var i = 0; i < page.entries.length; i++) {
        final e = page.entries[i];
        final b = e.block;
        if (b is HeadingBlock) {
          h += textH(e.partialText ?? b.text, typo.headingStyle(b.level),
                  typo.headingStrut(b.level), contentW) +
              4.0;
        } else if (b is ParagraphBlock) {
          final text = e.partialText ?? b.text;
          // 🔴 用**整段**判定（书签/分页下标 → 原始块），与分页器和渲染器同源 ✓
          final full = (e.blockIndex >= 0 && e.blockIndex < blocks.length)
              ? blocks[e.blockIndex]
              : b;
          final dialogue =
              full is ParagraphBlock && paragraphKindOf(full.text) == ParagraphKind.dialogue;
          final isBubble = asBubble && dialogue;
          h += textH(text, typo.paragraphStyle(), typo.paragraphStrut,
              isBubble ? bubbleTextW() : contentW);
          if (isBubble) h += (kBubblePadV + kBubbleBorder) * 2;
        }
        if (i != page.entries.length - 1) h += typo.blockSpacing;
      }
      return h;
    }

    /// 一整章**全是长对话**（一定被识别成 dialogue，且跨页切分）
    final blocks = <BookBlock>[
      BookBlock.heading('第 1 章', 1),
      for (var i = 0; i < 10; i++)
        BookBlock.paragraph('“这是一句很长的对话内容，用来把气泡撑到多行。”' * 4),
    ];

    List<BookPage> paginate({required bool bubbleAware}) {
      final p = BookPaginator(
        blocks: blocks,
        viewportWidth: viewportW,
        viewportHeight: viewportH,
        typo: typo,
        chapterStarts: const {0},
        bubbleInnerWidth: bubbleAware ? bubbleTextW() : 0,
        bubbleExtraV: (kBubblePadV + kBubbleBorder) * 2,
      );
      final out = <BookPage>[];
      while (!p.finished) {
        p.stepInto(out, chunk: 60);
      }
      return out;
    }

    test('修复后：每一页按气泡渲染的高度都 ≤ 页高', () {
      final pages = paginate(bubbleAware: true);
      expect(pages.length, greaterThanOrEqualTo(2),
          reason: '内容要足够多，否则证明不了跨页');
      for (var i = 0; i < pages.length; i++) {
        final h = renderedPageH(pages[i], blocks, true);
        expect(h, lessThanOrEqualTo(pageH + 0.01),
            reason: '第 ${i + 1} 页渲染高度 $h 超过页高 $pageH ⇒ 会溢出屏幕');
      }
    });

    test('反向断言：旧行为（分页不感知气泡）确实会溢出 —— 证明修复必要', () {
      final oldPages = paginate(bubbleAware: false);
      final overflowed = oldPages.any(
        (p) => renderedPageH(p, blocks, true) > pageH + 0.01,
      );
      expect(overflowed, isTrue,
          reason: '旧行为下必须能复现溢出，否则这个回归测试是假的');
    });
  });

  group('B08-blocker clampPageIndexToPages', () {
    test('真实分页结果：长章 5 页 → 短章更少，旧页号被夹到合法范围且取页不抛', () {
      // 先造"真实多页"的分页结果（旧排版 / 上一章）
      var longPages = <BookPage>[];
      for (var n = 1; n <= 12; n++) {
        longPages = _paginateReally(
          List<String>.generate(n, (i) => '第 $i 段：' * 40),
          pageHeight: 180,
        );
        if (longPages.length >= 5) break;
      }
      expect(
        longPages.length,
        greaterThanOrEqualTo(5),
        reason: '必须先真的排出 ≥5 页，否则这个用例证明不了"换短列表"',
      );
      const oldIndex = 4; // 用户读到第 5 页
      expect(() => longPages[oldIndex], returnsNormally); // 旧列表上完全合法

      // 新的短列表（切章 / 旋屏后重新分页）：页数一定更少
      final shortPages = _paginateReally(
        <String>['短章正文只有一段'],
        pageHeight: 180,
      );
      expect(
        shortPages.length,
        lessThan(longPages.length),
        reason: '要的正是"比旧列表短"的列表',
      );
      expect(
        shortPages.length,
        lessThanOrEqualTo(oldIndex),
        reason: '旧页号在新列表上必须越界 —— 这正是崩溃条件',
      );

      // 修复前：`_pages[_pageIndex]` → RangeError
      expect(() => shortPages[oldIndex], throwsRangeError);

      // ✅ 修复后：先夹取再取页，永不越界、永不抛
      final clamped = clampPageIndexToPages(oldIndex, shortPages.length);
      expect(clamped, shortPages.length - 1);
      expect(() => shortPages[clamped], returnsNormally);
      // ❌ 这一条是反向断言：修好的路径**绝不能**像上面那样抛
      expect(() => shortPages[clamped], isNot(throwsRangeError));
    });

    test('边界：0 页 / 负下标 / 正好等于长度', () {
      // 0 页（分页失败退化成滚动视图、或循环第一批之前）
      expect(clampPageIndexToPages(0, 0), 0);
      expect(clampPageIndexToPages(4, 0), 0);
      expect(clampPageIndexToPages(999, 0), 0);

      // 负下标（PageController 回调等极端输入）
      expect(clampPageIndexToPages(-1, 5), 0);
      expect(clampPageIndexToPages(-99, 1), 0);

      // 正好越界一格 / 远远越界
      expect(clampPageIndexToPages(5, 5), 4);
      expect(clampPageIndexToPages(9999, 5), 4);

      // 合法值必须原样返回（不误夹，否则会丢阅读位置）
      expect(clampPageIndexToPages(0, 5), 0);
      expect(clampPageIndexToPages(3, 5), 3);
      expect(clampPageIndexToPages(4, 5), 4);
      expect(clampPageIndexToPages(0, 1), 0);
    });

    test('反向断言：旧写法 clamp(0, len-1) 在 0 页时真会抛（证明这层保护必要）', () {
      // 这正是修复前渲染层 `_pages[_pageIndex]` 会踩到的坑：
      // `num.clamp` 在 lowerLimit > upperLimit 时抛 ArgumentError，
      // 在 `test` 里它被包成 TestFailure —— 关键是**它确实抛了**。
      expect(
        () => 4.clamp(0, 0 - 1),
        throwsA(isA<Error>()),
        reason: 'lowerLimit > upperLimit 时 clamp 会抛，所以不能写成 i.clamp(0, len-1)',
      );
      // ✅ 而修好的纯函数同样输入下**安全**：
      expect(clampPageIndexToPages(4, 0), 0);
    });

    test('模拟 _paginate() 的"边分边看"：每批夹一次，全程不越界', () {
      // 复刻 `_paginate()` 循环：out 从 0 页长到 N 页，旧页号 4 一直在
      var pageIndex = 4; // 切章前用户停在第 5 页
      final batches = <int>[]; // 每批的页数
      for (var k = 1; k <= 6; k++) {
        final list = _paginateReally(
          List<String>.generate(k, (i) => '第 $i 段：' * 30),
          pageHeight: 180,
        );
        batches.add(list.length);
        // 修复后循环里的写法：`if (_pages.isNotEmpty) _pageIndex = _safePageIndex();`
        if (list.isNotEmpty) {
          pageIndex = clampPageIndexToPages(pageIndex, list.length);
        }
        // 任何一批渲染时取页都必须合法（原来这里会 RangeError）
        expect(() => list[pageIndex], returnsNormally);
      }
      expect(batches, isNotEmpty);
      expect(pageIndex, greaterThanOrEqualTo(0));
    });
  });
}
