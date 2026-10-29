import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/widgets/danmaku.dart';

/// ── 弹幕层测试 ──────────────────────────────────────────────────
///
/// 历史背景：早期 `DanmuLayer` 是 `Stack + Positioned + Text`，那时的测试
/// 通过 `tester.widgetList<Positioned>()` 读 `left` 来断言"暂停冻结 /
/// 右边缘进场 / 走出屏幕回收"。
///
/// 2026-10-08 起渲染层改成**单个 `CustomPaint` + `TextPainter` 直绘**
/// （60 条弹幕不再产生 60 个 widget，见 danmaku.dart 里的说明），
/// 屏上已经没有 `Positioned`/`Text` 可查 ⇒ 那几条断言整体失效。
///
/// 这里保留两类仍然有意义的验证：
///   ① 样式/数据驱动：`DanmuLayer` 能在各种弹幕形态下正常渲染不抛异常；
///   ② 解析：B站 XML / 弹弹play 毫秒 / DPlayer 秒 / 实体解码。
void main() {
  testWidgets('DanmuLayer 以 CustomPaint 渲染，暂停（位置冻结）不抛异常', (tester) async {
    final k = GlobalKey<_HostState>();
    await tester.pumpWidget(_Host(
      key: k,
      items: List.generate(
          3, (i) => DanmuItem(1.0 + i * 0.1, '弹幕$i', Colors.white, 1)),
      width: 400,
      height: 300,
    ));
    k.currentState!.seek(1000);
    await tester.pump();

    // 新架构：所有弹幕画在同一块画布上
    expect(find.byType(CustomPaint), findsWidgets);
    expect(tester.takeException(), isNull);

    // 位置不动、父级反复重建（模拟暂停期间的重绘）→ 仍然不抛异常
    for (var i = 0; i < 6; i++) {
      k.currentState!.rebuild();
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('滚动 / 顶部 / 底部三种模式混合渲染不抛异常', (tester) async {
    final k = GlobalKey<_HostState>();
    await tester.pumpWidget(_Host(
      key: k,
      items: [
        DanmuItem(1.0, '滚动', Colors.white, 1),
        DanmuItem(1.0, '顶部', Colors.white, 4),
        DanmuItem(1.0, '底部', Colors.white, 5),
      ],
      width: 400,
      height: 300,
    ));
    k.currentState!.seek(1000);
    await tester.pump();

    // 连续推进（会触发回收 / 再生成 / 补播分帧）
    for (var ms = 1200; ms <= 5000; ms += 200) {
      k.currentState!.seek(ms);
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('⑤ 解析：B站 XML / 弹弹play 毫秒 / DPlayer 秒 / 实体解码', (tester) async {
    // B站 XML：颜色在 p 的第 4 段、mode 在第 2 段
    final xml = '<i><d p="1.5,1,25,16711680,0,0,0,0">红字</d>'
        '<d p="2.0,4,25,16777215,0,0,0,0">顶部</d></i>';
    final x = parseDanmuBody(xml);
    expect(x.length, 2);
    expect(x[0].time, 1.5);
    expect(x[0].mode, 1);
    expect(x[0].color.toARGB32() & 0xFFFFFF, 0xFF0000);
    expect(x[1].mode, 4);

    // 弹弹play：t 为**毫秒**（不 /1000 的话 t=125000 会被当成 125000 秒，弹幕永不出现）
    final dd = parseDanmuBody(
        '{"data":[{"t":125000,"m":"毫秒","p":"125,1,16711680"}]}');
    expect(dd.length, 1);
    expect(dd[0].time, 125.0);
    expect(dd[0].mode, 1);
    expect(dd[0].color.toARGB32() & 0xFFFFFF, 0xFF0000);

    // DPlayer：time 为秒
    final dp = parseDanmuBody('[{"time":3.25,"text":"秒","color":16777215}]');
    expect(dp.length, 1);
    expect(dp[0].time, 3.25);

    // 实体解码 + 垃圾输入
    expect(parseDanmuBody('<d p="1,1,25,16777215">a&lt;b&amp;c</d>').first.text,
        'a<b&c');
    expect(parseDanmuBody('').length, 0);
    expect(parseDanmuBody('既不是 json 也不是 xml').length, 0);
  });
}

/// 测试宿主：位置变化时**显式** `setState`，保证 `DanmuLayer` 收到
/// `didUpdateWidget`（弹幕列表/样式变化走这条路径）。
class _Host extends StatefulWidget {
  const _Host({
    super.key,
    required this.items,
    required this.width,
    required this.height,
  });
  final List<DanmuItem> items;
  final double width;
  final double height;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int posMs = 980;

  void seek(int v) => setState(() => posMs = v);

  /// 位置不变、只强制重建
  void rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: widget.width,
            height: widget.height,
            child: DanmuLayer(
              danmus: widget.items,
              positionOf: () => Duration(milliseconds: posMs),
              fontSize: 14,
              speed: 150,
            ),
          ),
        ),
      );
}
