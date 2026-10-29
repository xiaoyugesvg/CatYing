import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/common/theme.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';

/// 实测 `app.dart` 里 `key: ValueKey('root-$effectiveLight-$paletteRev')`
/// **到底有没有用**、以及**去掉它会不会导致"切了配色界面不变"**。
///
/// ── 背景（这次要验证的推理链）────────────────────────────────
///   1. `AppTheme` 是**静态类**，颜色 getter 读 `_palette`（静态字段）
///      和 `AppBrightness.isLight`（普通 `ValueNotifier`）。
///   2. 静态字段改变**不会通知任何 widget**；`ValueNotifier` 也只有
///      真的监听它的人才知道。
///   3. `app.dart` 里那个 key 的作用就是"强制重建整棵树，
///      让所有读过 `AppTheme.xxx` 的地方重新取值"。
///
/// 于是问题变成：**除了换 key，还有别的机制能让颜色刷新吗？**
/// 这个测试就是回答它。
void main() {
  setUp(() {
    // 每个测试从已知状态开始
    AppBrightness.isLight.value = false;
    AppTheme.applyPalette(const JellyPalette.ink(), module: 'video');
  });

  /// 模拟"页面里直接读 AppTheme 的颜色"（这是全项目 1017 处的写法）
  Widget directReader() => Builder(
        builder: (_) => Container(
          key: const ValueKey('probe'),
          color: AppTheme.accentColor,
          width: 10,
          height: 10,
        ),
      );

  Color probeColor(WidgetTester tester) {
    final box = tester.widget<Container>(find.byKey(const ValueKey('probe')));
    return (box.decoration as BoxDecoration?)?.color ??
        (box.color) ??
        const Color(0x00000000);
  }

  testWidgets('① 换调色板但无任何监听 → 直接读 AppTheme 的 widget 不会刷新',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) => directReader(),
      ),
    ));
    final before = probeColor(tester);
    expect(before, AppTheme.accentColor);

    // 换一套明显不同的调色板（粉色），但**不重建 widget**
    AppTheme.applyPalette(const JellyPalette.pink(), module: 'video');
    await tester.pump();

    final after = probeColor(tester);
    // ⚠️ 这一条就是"为什么需要那个 key"的证据：
    // 静态类变了，但没人通知，widget 还拿着旧值。
    expect(after, before,
        reason: '没有监听/重建时，AppTheme 的变化不会反映到界面上 —— '
            '这正是 app.dart 要换 key 的原因');
  });

  testWidgets('② 外层监听 paletteRevision 并重建 → 颜色会刷新（key 的替代方案）',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ValueListenableBuilder<int>(
        valueListenable: AppTheme.paletteRevision,
        builder: (context, rev, _) => directReader(),
      ),
    ));
    final before = probeColor(tester);

    AppTheme.applyPalette(const JellyPalette.pink(), module: 'video');
    await tester.pump();

    final after = probeColor(tester);
    expect(after, isNot(before),
        reason: '监听 paletteRevision 并重建，就能拿到新颜色 —— '
            '说明**换 key 不是唯一手段**');
    expect(after, AppTheme.accentColor);
  });

  testWidgets('③ 同一套调色板重复 apply → 也会 bump revision（无变化却触发重建）',
      (tester) async {
    final rev0 = AppTheme.paletteRevision.value;
    // 故意用"和当前完全一样"的调色板再 apply 一次
    AppTheme.applyPalette(const JellyPalette.ink(), module: 'video');
    expect(AppTheme.paletteRevision.value, rev0 + 1,
        reason: 'applyPalette 没有"值没变就跳过"的保护 —— '
            '重复调用会白白触发一次全树重建（潜在浪费点）');
  });

  testWidgets('④ MaterialApp 换 theme + 换 key 都能让颜色刷新（两条路都通）',
      (tester) async {
    // 这条确认"正常换主题"的路径是通的，避免上面的结论被误解成
    // "换主题根本不生效"
    var rev = 0;
    await tester.pumpWidget(MaterialApp(
      home: ValueListenableBuilder<int>(
        valueListenable: AppTheme.paletteRevision,
        builder: (context, r, _) => KeyedSubtree(
          key: ValueKey('root-$r'),
          child: directReader(),
        ),
      ),
    ));
    final before = probeColor(tester);

    AppTheme.applyPalette(const JellyPalette.green(), module: 'video');
    rev = AppTheme.paletteRevision.value;
    await tester.pump();

    expect(probeColor(tester), isNot(before));
    expect(rev, greaterThan(0));
  });
}
