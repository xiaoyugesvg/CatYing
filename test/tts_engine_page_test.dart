import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/reading/models/tts_source.dart';
import 'package:tvbox/reading/pages/tts_engine_page.dart';
import 'package:tvbox/reading/services/tts_source_store.dart';
import 'package:tvbox/reading/theme/jelly_theme.dart';

/// 朗读引擎页的**布局回归**（用户 2026-10-29）。
///
/// ── 为什么要有这个文件 ──────────────────────────────────────────
/// 「添加朗读源」那一行是 `Row(图标 + 标题 + Spacer + 长文案)`：右边那句
/// 类型提示在 390pt 宽的机型上会顶破 Row（debug 下黄黑条纹、release 硬裁）。
/// 这种问题 `flutter analyze` 抓不到、也没有异常日志，只有真按窄屏布局一次
/// 才会 `RenderFlex overflowed` 报错。所以这里把它钉成测试。
///
/// 另一条：深色下「哪条在用」的勾/描边原来用 `JellyTheme.primary`(#3A3A3A)，
/// 压在 #2A2A2C 的卡片上等于隐形 —— 这里断言选中标记必须是前景白。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final store = TtsSourceStore.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    for (final s in store.all) {
      await store.remove(s.id);
    }
    await store.setActive('');
  });

  Future<void> pumpPage(WidgetTester tester) async {
    // 390 × 844 = iPhone 14/15 的逻辑尺寸，也是出问题的那档宽度
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(theme: JellyTheme.dark, home: const TtsEnginePage()),
    );
    // initState 里 `TtsSourceStore.init()` 是异步的，多泵两帧让它落地
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('390 宽下「添加朗读源」行不溢出', (tester) async {
    await store.upsert(TtsSource.blank('edge').copyWith(name: 'Edge 朗读'));
    await pumpPage(tester);

    // 溢出会以 FlutterError 的形式冒出来，这里必须为空
    expect(tester.takeException(), isNull);
    expect(find.text('添加朗读源'), findsOneWidget);
    // 提示文案仍在（只是砍短了，不能整句删掉）
    expect(find.text('Edge / MiMo / Azure'), findsOneWidget);
  });

  testWidgets('390 宽下朗读源列表（多条）不溢出', (tester) async {
    for (final t in ['edge', 'mimo', 'easyvoice']) {
      await store.upsert(TtsSource.blank(t));
    }
    await pumpPage(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('朗读源'), findsOneWidget);
  });

  testWidgets('深色下选中标记用前景白，不再和卡片底同色', (tester) async {
    final s = TtsSource.blank('edge').copyWith(name: 'Edge 朗读');
    await store.upsert(s);
    await store.setActive(s.id);
    await pumpPage(tester);

    final check = tester.widget<Icon>(
      find.byIcon(Icons.check_circle_rounded).first,
    );
    expect(check.color, Colors.white);
    // 反面：不能还是 primary（#3A3A3A 压在 #2A2A2C 上等于看不见）
    expect(check.color, isNot(JellyTheme.primary));
  });

  testWidgets('未选中的源显示空心圆，切回系统朗读后勾回到系统那行', (tester) async {
    final s = TtsSource.blank('mimo').copyWith(name: '小米 MiMo');
    await store.upsert(s);
    await store.setActive('');
    await pumpPage(tester);

    // 系统朗读在用 → 有勾；朗读源那条是空心
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);

    await store.setActive(s.id);
    await tester.pump();
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
  });
}
