import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/reading/widgets/jelly_icon_deck.dart';

/// 量「叠图标控件」里**每张卡片实际露出多宽**。
///
/// ── 用户反馈 ────────────────────────────────────────────────────
/// 「不是被挤到屏幕边缘、后面的卡片被裁掉了，是**重叠**吖」
///
/// 即：卡片之间叠得太紧 ⇒ 后面的只露一条细缝 ⇒ 看起来糊成一团/重叠 ✗
///
/// 这个测试把"露出宽度"算出来，用来**选一个合理的 overlap**，
/// 而不是靠眼睛猜。
void main() {
  Future<void> dump(WidgetTester tester, double overlap, double size) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: JellyIconDeck(
            size: size,
            overlap: overlap,
            items: [
              JellyIconDeckItem(
                  icon: Icons.history_rounded, tooltip: '历史', onTap: () {}),
              JellyIconDeckItem(
                  icon: Icons.favorite_rounded, tooltip: '收藏', onTap: () {}),
              JellyIconDeckItem(
                  icon: Icons.download_rounded, tooltip: '下载', onTap: () {}),
              JellyIconDeckItem(
                  icon: Icons.source_rounded, tooltip: '源仓库', onTap: () {}),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();

    // 叠图标整体矩形
    final deck = tester.getRect(find.byType(JellyIconDeck));
    // 每个卡片（Material 圆底）
    final cards = tester
        .widgetList<Material>(find.byType(Material))
        .where((m) => m.shape is CircleBorder)
        .toList();
    final rects = <Rect>[];
    for (final m in cards) {
      rects.add(tester.getRect(find.byWidget(m)));
    }
    rects.sort((a, b) => a.left.compareTo(b.left));

    final gaps = <String>[];
    for (var i = 0; i < rects.length; i++) {
      // 第 i 张露出宽度 = 下一张左缘 - 本张左缘（最后一张露出 = 自身宽度）
      final exposed = i == rects.length - 1
          ? rects[i].width
          : (rects[i + 1].left - rects[i].left);
      gaps.add('${exposed.toStringAsFixed(0)}px');
    }
    // ignore: avoid_print
    print('[probe] size=$size overlap=$overlap 整体宽=${deck.width.toStringAsFixed(0)} '
        '卡片数=${rects.length} 各张露出=[${gaps.join(", ")}]');
  }

  testWidgets('量不同 overlap 下的露出宽度', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // ⚠️ 这里显式传 overlap 只是**为了对比**（看露出的边缘多宽）。
    //    控件默认值已改为 9（4 张共 67px），页面用的就是默认值 ✓
    for (final ov in <double>[6, 9, 12, 14]) {
      await dump(tester, ov, 40);
    }
  });

  testWidgets('🔴 叠图标整体宽度必须与公式一致（size + (n-1)*overlap）',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    const size = 40.0;
    const ov = 22.0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: JellyIconDeck(
            size: size,
            overlap: ov,
            items: [
              JellyIconDeckItem(icon: Icons.history_rounded, tooltip: 'a', onTap: () {}),
              JellyIconDeckItem(icon: Icons.favorite_rounded, tooltip: 'b', onTap: () {}),
              JellyIconDeckItem(icon: Icons.download_rounded, tooltip: 'c', onTap: () {}),
              JellyIconDeckItem(icon: Icons.source_rounded, tooltip: 'd', onTap: () {}),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();
    final deck = tester.getRect(find.byType(JellyIconDeck));
    expect(deck.width, closeTo(size + 3 * ov, 1),
        reason: '收起态总宽 = size + (n-1)*overlap');
  });

  testWidgets('🔴 跟手滑动：拖动时整叠跟着手指走，松手吸附换张', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: JellyIconDeck(
            items: [
              JellyIconDeckItem(icon: Icons.history_rounded, tooltip: '历史', onTap: () {}),
              JellyIconDeckItem(icon: Icons.favorite_rounded, tooltip: '收藏', onTap: () {}),
              JellyIconDeckItem(icon: Icons.download_rounded, tooltip: '下载', onTap: () {}),
              JellyIconDeckItem(icon: Icons.source_rounded, tooltip: '源仓库', onTap: () {}),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();

    double firstLeft() {
      final mats = tester
          .widgetList<Material>(find.byType(Material))
          .where((m) => m.shape is CircleBorder)
          .toList();
      final rects = mats.map((m) => tester.getRect(find.byWidget(m))).toList()
        ..sort((a, b) => a.left.compareTo(b.left));
      return rects.first.left;
    }

    final x0 = firstLeft();
    // 往左拖 30px（不松手）
    final g = await tester.startGesture(tester.getCenter(find.byType(JellyIconDeck)));
    // ⚠️ 必须拖过 Flutter 的 touch slop（约 18px），否则首段位移被吞
    await g.moveBy(const Offset(-45, 0));
    await tester.pump();
    final xDuring = firstLeft();
    // 🔴 断言改为**不跟手**（原来的断言写反了，与本意冲突，一直红着）：
    //    用户 2026-10-12 明确要求「滑动时整叠不要跟着手指移动」✗，
    //    只做"切换最前那个" ⇒ 拖动过程中位置必须**不动** ✓
    expect(xDuring, closeTo(x0, 0.5),
        reason: '拖动中整叠不应跟手位移（用户要求：只切换图标）');

    // 松手：位移超过一格 55% ⇒ 换到下一张
    await g.up();
    await tester.pumpAndSettle();
    final xAfter = firstLeft();
    // ignore: avoid_print
    print('[probe] 松手后 left=$xAfter（应吸附换张，且回到基准附近）');
    expect((xAfter - x0).abs(), lessThan(4),
        reason: '松手后应吸附回基准位置（只是换了最前那张）');
  });

  testWidgets('🔴 下滑展开：其余几个"悬浮在第一个图标下面"，顶栏不许被挤动',
      (tester) async {
    tester.view.physicalSize = const Size(1170, 2532); // 390x844 @3x
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final tapped = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          // 复刻真实顶栏：标题 + Spacer + 叠图标（交叉轴居中）
          child: Row(
            children: [
              const Text('图书'),
              const Spacer(),
              JellyIconDeck(items: [
                JellyIconDeckItem(
                    icon: Icons.history_rounded,
                    tooltip: '历史',
                    onTap: () => tapped.add('历史')),
                JellyIconDeckItem(
                    icon: Icons.favorite_rounded,
                    tooltip: '收藏',
                    onTap: () => tapped.add('收藏')),
                JellyIconDeckItem(
                    icon: Icons.file_download_rounded,
                    tooltip: '下载',
                    onTap: () => tapped.add('下载')),
                JellyIconDeckItem(
                    icon: Icons.source_rounded,
                    tooltip: '源仓库',
                    onTap: () => tapped.add('源仓库')),
              ]),
            ],
          ),
        ),
      ),
    ));
    await tester.pump();

    final deck0 = tester.getRect(find.byType(JellyIconDeck));
    final titleY0 = tester.getCenter(find.text('图书')).dy;
    final first0 = tester.getRect(find.byTooltip('历史'));
    final second0 = tester.getRect(find.byTooltip('收藏'));
    expect(second0.left - first0.left, closeTo(9, 1),
        reason: '收起态是"往右错开一条边"的叠');

    // 下滑展开（⚠️ 必须**分几步**移动：一次 moveBy(0,40) 会被"起始 slop"
    // 吃掉、收不到 update ⇒ `_dragDy` 还是 0，展开不了 ✓）
    final g =
        await tester.startGesture(tester.getCenter(find.byType(JellyIconDeck)));
    for (var i = 0; i < 4; i++) {
      await g.moveBy(const Offset(0, 12));
      await tester.pump();
    }
    await g.up();
    await tester.pumpAndSettle();

    // ① 控件**自身矩形一个像素都没变** ⇒ 顶栏不会变高
    expect(tester.getRect(find.byType(JellyIconDeck)), deck0,
        reason: '展开不许改自身尺寸（以前会从 46 拉到 ~190，把标题顶下去）');
    expect(tester.getCenter(find.text('图书')).dy, closeTo(titleY0, 0.5),
        reason: '顶栏其它内容必须纹丝不动（用户截图的问题）');

    // ② 其余 3 个**正下方悬浮**：左缘对齐、在第一个下面、且画在控件矩形之外
    final first = tester.getRect(find.byTooltip('历史'));
    for (final tip in ['收藏', '下载', '源仓库']) {
      final r = tester.getRect(find.byTooltip(tip));
      expect(r.left, closeTo(first.left, 1), reason: '$tip 要在第一个图标"正下方"');
      expect(r.top, greaterThan(first.bottom - 1), reason: '$tip 要在第一个图标下面');
      expect(r.top, greaterThan(deck0.bottom - 1),
          reason: '$tip 是溢出控件矩形画的（真·悬浮，不是把控件撑高）');
    }

    // ③ 浮层里的图标**能点**（Overlay 的命中测试要跟着 LayerLink 的变换走）
    await tester.tap(find.byTooltip('下载'));
    await tester.pumpAndSettle();
    expect(tapped, contains('下载'), reason: '悬浮出来的图标必须可点');

    // ④ 点完自动收起，回到"往右错开"的叠
    expect(
      tester.getRect(find.byTooltip('收藏')).left -
          tester.getRect(find.byTooltip('历史')).left,
      closeTo(9, 1),
      reason: '收起后应回到原来的叠形态',
    );
  });

  testWidgets('🔴 长按展开后：点空白处收起', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: JellyIconDeck(items: [
            JellyIconDeckItem(
                icon: Icons.history_rounded, tooltip: '历史', onTap: () {}),
            JellyIconDeckItem(
                icon: Icons.favorite_rounded, tooltip: '收藏', onTap: () {}),
            JellyIconDeckItem(
                icon: Icons.download_rounded, tooltip: '下载', onTap: () {}),
            JellyIconDeckItem(
                icon: Icons.source_rounded, tooltip: '源仓库', onTap: () {}),
          ]),
        ),
      ),
    ));
    await tester.pump();

    await tester.longPress(find.byType(JellyIconDeck));
    await tester.pumpAndSettle();
    final first = tester.getRect(find.byTooltip('历史'));
    final floating = tester.getRect(find.byTooltip('收藏'));
    expect(floating.top, greaterThan(first.bottom - 1), reason: '长按也要展开');

    // 点屏幕空白处 → 收起
    await tester.tapAt(const Offset(200, 600));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byTooltip('收藏')).left -
          tester.getRect(find.byTooltip('历史')).left,
      closeTo(9, 1),
      reason: '点空白应收起，回到叠形态',
    );
  });
}
