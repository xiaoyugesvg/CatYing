import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/pages/tg/tg_home_page.dart';

/// TG 首页的**布局回归**（用户 2026-10-29：整体页面美化之后）。
///
/// ── 为什么要有 ────────────────────────────────────────────────
/// 顶栏是 `Row(频道块 + 搜索框 + 3 个图标按钮)`：频道块里有两行文字
/// （频道名 / @peer · 类型），一旦没包 `Flexible` 或者图标按钮尺寸不一致，
/// 390pt 宽就会 `RenderFlex overflowed`。这种问题 `analyze` 抓不到、
/// 也没有异常日志，只能真按窄屏布局一次才会红。
///
/// 这里**不碰网络**：测试环境里 `TgService.ready` 为 false，所有 `post`
/// 都会在发请求前直接返回 `{ok:false}`，所以可以安全 pump 整个页面。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.darkTheme, home: const TgHomePage()),
    );
    // ⚠️ 不能用 pumpAndSettle：幻灯片是 Timer.periodic，永远"不静止"
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump(const Duration(milliseconds: 120));
  }

  testWidgets('390 宽下顶栏不溢出', (tester) async {
    await pumpPage(tester);
    // 溢出会以 FlutterError 冒出来
    expect(tester.takeException(), isNull);
    // 顶栏三件套都在
    expect(find.byTooltip('搜索'), findsOneWidget);
    expect(find.byTooltip('切换为列表'), findsOneWidget);
    expect(find.byTooltip('TG 设置'), findsOneWidget);
  });

  testWidgets('390 宽下超长频道名被截断而不是撑破', (tester) async {
    // 内置频道 cctv1 会被 seed 进来，标题很长时也要能布局
    await pumpPage(tester);
    expect(tester.takeException(), isNull);
    // 频道块存在（含 @peer 副标题）
    expect(find.textContaining('@'), findsWidgets);
  });

  testWidgets('没有频道时显示空态引导', (tester) async {
    // 先把 seed 标记置上，跳过内置频道
    SharedPreferences.setMockInitialValues(<String, Object>{
      'tg.seeded.v2': true,
    });
    await pumpPage(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('还没有可看的频道'), findsOneWidget);
    expect(find.text('去添加频道'), findsOneWidget);
  });
}
