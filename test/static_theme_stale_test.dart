import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';

/// 验证"静态主题类 + `const` 子页 → 颜色停在旧值"这个真实缺陷，
/// 以及 `IndexedStack` 换 key 能修好它。
///
/// ── 这是音乐页"灰蒙蒙"的机制复现 ──────────────────────────────
/// `MusicTheme` / `AppTheme` 都是**静态类**（颜色 getter 读静态字段，
/// 改了不通知任何 widget）。`IndexedStack(children: const [...])` 里
/// 那些 widget 是**同一实例**，重建时被判定"没变"而跳过 build，
/// 于是子页里的颜色停在旧值，而外层直接读的颜色已经变了
/// → 文字与背景对不上（白字浅底）。
class _FakeStaticTheme {
  static bool isDark = true;
  static Color get label =>
      isDark ? const Color(0xFFEDEDED) : const Color(0xFF1F1F1F);
  static Color get background =>
      isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF7F5F1);
}

/// 模拟一个"页面"：直接读静态主题类的颜色
class _Page extends StatelessWidget {
  const _Page();
  @override
  Widget build(BuildContext context) => Center(
        child: Text('文字',
            key: const ValueKey('txt'),
            style: TextStyle(color: _FakeStaticTheme.label, fontSize: 20)),
      );
}

Color textColor(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('txt'))).style!.color!;

void main() {
  setUp(() => _FakeStaticTheme.isDark = true);

  testWidgets('❌ 复现：const 子页 + 无 key → 主题变了但子页颜色不变',
      (tester) async {
    late StateSetter rebuild;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        rebuild = setState;
        return AnimatedBuilder(
          animation: ValueNotifier<int>(0),
          builder: (context, _) => Scaffold(
            backgroundColor: _FakeStaticTheme.background,
            body: const IndexedStack(
              index: 0,
              children: [_Page()],
            ),
          ),
        );
      }),
    ));
    expect(textColor(tester), const Color(0xFFEDEDED), reason: '初始深色文字');

    // 切到浅色（模拟用户改主题）
    _FakeStaticTheme.isDark = false;
    rebuild(() {});
    await tester.pump();

    // ⚠️ 外层背景已经变成浅色，但子页文字**还是旧的白色** → 白字浅底
    final body = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(body.backgroundColor, const Color(0xFFF7F5F1),
        reason: '外层直接读的颜色立刻变了');
    expect(textColor(tester), const Color(0xFFEDEDED),
        reason: '⚠️ 子页文字停在旧值（白色）—— 这就是"灰蒙蒙"的成因');
  });

  testWidgets('✅ 修法：IndexedStack 换 key → 子页跟着重建、颜色同步',
      (tester) async {
    var rev = 0;
    late StateSetter rebuild;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        rebuild = setState;
        return Scaffold(
          backgroundColor: _FakeStaticTheme.background,
          body: IndexedStack(
            // 与 root_view.dart 里一样的修法
            key: ValueKey('music-tabs-$rev'),
            index: 0,
            children: const [_Page()],
          ),
        );
      }),
    ));
    expect(textColor(tester), const Color(0xFFEDEDED));

    _FakeStaticTheme.isDark = false;
    rev++;
    rebuild(() {});
    await tester.pump();

    expect(textColor(tester), const Color(0xFF1F1F1F),
        reason: '换 key 后子页重建，文字跟着变成深色 —— 与背景一致了');
    final body = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(body.backgroundColor, const Color(0xFFF7F5F1));
  });

  test('JellyPalette 深浅两套的对比度都足够（防止配色本身不可读）', () {
    for (final p in [
      const JellyPalette.ink(),
      const JellyPalette.pink(),
      const JellyPalette.jelly(),
      const JellyPalette.green(),
      const JellyPalette.ocean(),
      const JellyPalette.sunset(),
      const JellyPalette.sky(),
    ]) {
      final darkContrast =
          (p.textPrimaryDark.computeLuminance() - p.backgroundDark.computeLuminance()).abs();
      final lightContrast =
          (p.textPrimaryLight.computeLuminance() - p.backgroundLight.computeLuminance()).abs();
      expect(darkContrast, greaterThan(0.3), reason: '深色对比度不足');
      expect(lightContrast, greaterThan(0.3), reason: '浅色对比度不足');
    }
  });
}
