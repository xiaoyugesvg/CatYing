import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/common/theme.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';

/// 量化 `app.dart` 里"换 key 重建整棵树"的代价，并为收窄方案钉死契约。
///
/// ── 要验证的事 ────────────────────────────────────────────────
/// `app.dart` 的 `home: ContentView(key: ValueKey('root-$effectiveLight-$paletteRev'))`
/// 在**换配色**时会让 key 变化 → `ContentView` 被**销毁重建**
/// → 它下面 5 个 tab 页全部重建。
///
/// 但 `ContentView` 里真正需要跟配色变的只有三处：
///   · IndexedStack 的 5 个 tab
///   · 底部悬浮栏（读 `AppTheme.palette`）
///   · 搜索浮层
/// **并不需要销毁 `ContentView` 本身**（它是 StatefulWidget，销毁会丢状态）。
///
/// 这个测试用一个"带状态的子树"模拟 `ContentView`：
/// 换 key 时 State 会被重建（initState 次数 +1），
/// 而不换 key、只换内层 key 时 State 保留。
class _Probe extends StatefulWidget {
  const _Probe({super.key, required this.label});
  final String label;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  static final initCount = <String, int>{};
  @override
  void initState() {
    super.initState();
    initCount[widget.label] = (initCount[widget.label] ?? 0) + 1;
  }

  @override
  Widget build(BuildContext context) => Text(widget.label);
}

void main() {
  setUp(() {
    _ProbeState.initCount.clear();
    AppBrightness.isLight.value = false;
    AppTheme.applyPalette(const JellyPalette.ink(), module: 'video');
  });

  testWidgets('❌ 现状：外层换 key → 整个子树 State 被销毁重建', (tester) async {
    var paletteRev = 0;
    late StateSetter rebuild;

    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        rebuild = setState;
        return _Probe(
          // 与 app.dart 同款：key 拼了 paletteRev
          key: ValueKey('root-$paletteRev'),
          label: 'ContentView',
        );
      }),
    ));
    expect(_ProbeState.initCount['ContentView'], 1);

    // 模拟换配色：paletteRevision 变 → 外层 key 变
    AppTheme.applyPalette(const JellyPalette.pink(), module: 'video');
    paletteRev = AppTheme.paletteRevision.value;
    rebuild(() {});
    await tester.pump();

    // ⚠️ State 被重建了一次 —— 这就是"整棵树重建"的证据
    expect(_ProbeState.initCount['ContentView'], 2,
        reason: '换 key 会销毁并重建子树 State（ContentView 及其下 5 个 tab）');
  });

  testWidgets('✅ 收窄：外层不换 key，只换内层 key → State 保留', (tester) async {
    var innerRev = 0;
    late StateSetter rebuild;

    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        rebuild = setState;
        return Column(
          children: [
            // 外层：稳定的 StatefulWidget（模拟 ContentView，不再换 key）
            const Expanded(child: _Probe(label: 'ContentView')),
            // 内层：只有真正需要跟配色变的子树换 key
            SizedBox(
              height: 20,
              child: _Probe(key: ValueKey('tabs-$innerRev'), label: 'Tabs'),
            ),
          ],
        );
      }),
    ));
    expect(_ProbeState.initCount['ContentView'], 1);
    expect(_ProbeState.initCount['Tabs'], 1);

    // 换配色
    AppTheme.applyPalette(const JellyPalette.green(), module: 'video');
    innerRev = AppTheme.paletteRevision.value;
    rebuild(() {});
    await tester.pump();

    expect(_ProbeState.initCount['ContentView'], 1,
        reason: '✅ 外层 State **保留**（不再销毁整个 ContentView）');
    expect(_ProbeState.initCount['Tabs'], 2,
        reason: '✅ 只有内层需要变色的子树被重建');
  });

  test('paletteRevision 确实在换调色板时递增（收窄方案依赖它）', () {
    final before = AppTheme.paletteRevision.value;
    AppTheme.applyPalette(const JellyPalette.sky(), module: 'video');
    expect(AppTheme.paletteRevision.value, before + 1);
  });
}
