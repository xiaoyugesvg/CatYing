import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/widgets/help_sheet.dart';

/// 「?」说明弹窗的回归测试（2026-10-30）。
///
/// 背景：用户要求「AI 管理以及听书管理等页面右上角加个 ? 按钮，
/// 详情说明怎么用每一种方式」。
///
/// 说明系统原本只长在设置子页里、配色写死 AppTheme；
/// 听书/音乐走的是另一套配色（JellyTheme / MusicTheme），
/// 直接复用会把米白卡片弹到墨夜底上。所以拆成
/// `HelpItem`（内容）+ `HelpPalette`（配色）+ `showHelpSheet`（渲染），
/// 这里锁住三件事：内容全渲染、能关掉、配色由调用方决定。
void main() {
  const palette = HelpPalette(
    surface: Color(0xFF1C1C1E),
    textPrimary: Color(0xFFF2F2F2),
    textSecondary: Color(0xFFAAAAAA),
    textTertiary: Color(0xFF777777),
    accent: Color(0xFFD9A441),
    border: Color(0x1AFFFFFF),
  );

  const items = <HelpItem>[
    HelpItem(
      icon: Icons.memory_rounded,
      title: '方式一：系统朗读',
      body: '不用填任何东西，装上系统语音包就能念。',
    ),
    HelpItem(
      icon: Icons.cloud_done_outlined,
      title: '方式二：Edge 内置朗读',
      body: '不用地址、不用 Key，走内置 Node 直连微软 Edge。',
    ),
    HelpItem(title: '没有图标的一条', body: '这一条不传 icon 也不该崩。'),
  ];

  testWidgets('每条说明的标题和正文都渲染出来', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showHelpSheet(
                context,
                title: '朗读引擎怎么用',
                items: items,
                palette: palette,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('朗读引擎怎么用'), findsOneWidget);
    for (final it in items) {
      expect(find.text(it.title), findsOneWidget);
      expect(find.text(it.body), findsOneWidget);
    }
    // 没传 icon 的那条不该崩（icon 为 null 时整块跳过）
    expect(tester.takeException(), isNull);
  });

  testWidgets('点「知道了」能关掉', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showHelpSheet(
                context,
                title: '标题',
                items: items,
                palette: palette,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('标题'), findsNothing);
  });

  testWidgets('弹窗底色用的是调用方给的 palette（不是写死的）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showHelpSheet(
                context,
                title: '标题',
                items: items,
                palette: palette,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
    expect(dialog.backgroundColor, palette.surface);
  });

  test('iconTint 缺省时取强调色的 14% 透明', () {
    expect(palette.tileTint.a, closeTo(0.14, 0.01));
    final custom = HelpPalette(
      surface: Colors.black,
      textPrimary: Colors.white,
      textSecondary: Colors.white70,
      textTertiary: Colors.white38,
      accent: Colors.amber,
      border: Colors.white12,
      iconTint: Colors.red,
    );
    expect(custom.tileTint, Colors.red);
  });
}
