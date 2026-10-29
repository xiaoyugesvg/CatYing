import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/pages/detail/simple_image_reader_page.dart';

/// 「下拉自动下一章」的回归（用户 2026-10-16；对齐海阔官方 `pics://` 的
/// 「下拉会尝试执行下一集的动态解析，实现自动下一章」）。
///
/// 这里不真滑（滑动手势在测试里不稳定），直接点底部状态条 —— 走的是**同一个**
/// `_loadNext()`：追加 + 去重 + 到头判定。
void main() {
  testWidgets('续章：把新一页的图追加到同一列，到底后显示「没有下一章了」', (tester) async {
    var calls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SimpleImageReaderPage(
          title: '测试漫画',
          images: const ['https://x/a.jpg', 'https://x/b.jpg'],
          onLoadNextChapter: () async {
            calls++;
            if (calls == 1) {
              // 第 1 次：给下一章的 2 张（其中一张与本章重复，应被去重）
              return (images: const ['https://x/b.jpg', 'https://x/c.jpg'], nextPage: 'np2');
            }
            return (images: const <String>[], nextPage: '');
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.text('2 张'), findsOneWidget);
    expect(find.text('继续下拉加载下一章'), findsOneWidget);

    // 点底部 → 续一章
    await tester.tap(find.text('继续下拉加载下一章'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('3 张'), findsOneWidget, reason: '重复的那张要去掉');

    // 再点一次 → 源返回空 + 无 nextPage ⇒ 到底
    await tester.tap(find.text('继续下拉加载下一章'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('没有下一章了'), findsOneWidget);
    expect(find.text('3 张'), findsOneWidget);
  });

  testWidgets('没给 onLoadNextChapter 时不显示底部状态条（一章就是一页）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SimpleImageReaderPage(
          title: 't',
          images: const ['https://x/a.jpg'],
        ),
      ),
    );
    await tester.pump();
    expect(find.text('继续下拉加载下一章'), findsNothing);
    expect(find.text('没有下一章了'), findsNothing);
  });
}
