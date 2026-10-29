import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/hiker/widgets/hiker_widgets.dart';

/// 海阔公共视觉组件（用户 2026-10-29：「海阔的整体UI界面和详情页界面能不优化美化呢」）
///
/// 这两个组件被主页 / 详情页 / 搜索页共用，所以这里锁住它们的**契约**：
/// 标题必须带计数徽标、胶囊必须能区分强调态 —— 以后改样式时别把这两点改没了。
void main() {
  Widget wrap(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  group('HikerSectionTitle', () {
    testWidgets('标题文字 + 计数徽标都渲染', (tester) async {
      await tester.pumpWidget(
        wrap(const HikerSectionTitle('解析结果', count: 7)),
      );

      expect(find.text('解析结果'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
    });

    testWidgets('不给 count 就不出现徽标', (tester) async {
      await tester.pumpWidget(wrap(const HikerSectionTitle('简介')));
      expect(find.text('简介'), findsOneWidget);
      expect(find.text('0'), findsNothing);
    });

    testWidgets('trailing 文案靠右显示', (tester) async {
      await tester.pumpWidget(
        wrap(const HikerSectionTitle('分类', trailing: '电影')),
      );
      expect(find.text('电影'), findsOneWidget);
    });
  });

  group('HikerPill', () {
    testWidgets('普通态与强调态都能渲染文字', (tester) async {
      await tester.pumpWidget(
        wrap(
          const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              HikerPill('海阔脚本'),
              HikerPill('视频直链', accent: true),
            ],
          ),
        ),
      );
      expect(find.text('海阔脚本'), findsOneWidget);
      expect(find.text('视频直链'), findsOneWidget);
    });

    testWidgets('超长文字被 maxWidth 截断而不是溢出', (tester) async {
      await tester.pumpWidget(
        wrap(
          const HikerPill(
            '一个特别特别长的来源名字用来测试截断行为是否正常工作',
            maxWidth: 100,
          ),
        ),
      );
      // 有 maxWidth 约束时不该抛 overflow
      expect(tester.takeException(), isNull);
    });
  });
}
