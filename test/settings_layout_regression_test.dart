import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/pages/settings/sub/danmu_settings_page.dart';
import 'package:tvbox/pages/settings/sub/data_source_settings_page.dart';
import 'package:tvbox/pages/settings/sub/home_pages_settings_page.dart';
import 'package:tvbox/pages/settings/sub/settings_shared.dart';
import 'package:tvbox/pages/settings/sub/appearance_settings_page.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/services/prefs_mirror.dart';
import 'package:tvbox/widgets/common_widgets.dart';

/// 「设置页长白板」回归测试。
///
/// ── 背景 ──────────────────────────────────────────────────────
/// 曾经踩过一个很隐蔽的坑：设置页里某些 `Obx(() => ...)` 内部**没有读取
/// 任何可观察变量**（比如包着一个普通 `bool` 的开关行）。
/// GetX 检测到后会抛
///   「[Get] the improper use of a GetX has been detected」
/// 该异常让整棵子树被 `ErrorWidget` 取代，而 **ErrorWidget 的高度是
/// 100000px** —— 页面直接变成一块巨大的空白板（用户报的"长白板"）。
///
/// 这个测试就是守住这条：渲染设置页后**不允许出现 ErrorWidget**，
/// 也不允许出现高度失控的组件。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 设置子页在 dispose 里会调 PrefsMirror.snapshotSoon()（400ms 去抖），
  // 每个用例结束后统一停掉，避免「A Timer is still pending」。
  tearDown(() => PrefsMirror.stopAutoSnapshot());

  /// 渲染一个页面并统计 ErrorWidget / 失控高度
  Future<({int errorWidgets, int hugeBoxes, List<String> hugeTypes})>
      renderAndScan(WidgetTester tester, Widget page) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1170, 2532); // 390x844 @3x
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final prev = FlutterError.onError;
    FlutterError.onError = (_) {}; // 把异常收集留给下面的 RenderBox 扫描

    await tester.pumpWidget(MaterialApp(home: page));
    await tester.pumpAndSettle();

    FlutterError.onError = prev;

    var errorWidgets = 0;
    final hugeTypes = <String>[];
    void visit(Element e) {
      if (e.widget is ErrorWidget) errorWidgets++;
      final ro = e.renderObject;
      if (ro is RenderBox && ro.hasSize && ro.size.height > 5000) {
        hugeTypes.add('${e.widget.runtimeType} ${ro.size.height.toStringAsFixed(0)}px');
      }
      e.visitChildren(visit);
    }

    tester.allElements.forEach(visit);

    return (
      errorWidgets: errorWidgets,
      hugeBoxes: hugeTypes.length,
      hugeTypes: hugeTypes,
    );
  }

  testWidgets('弹幕服务设置页：不出现 ErrorWidget / 失控高度', (tester) async {
    final r = await renderAndScan(tester, const DanmuSettingsPage());
    expect(r.errorWidgets, 0,
        reason: '出现 ErrorWidget 说明有 Obx 内部没有可观察变量（长白板根因）');
    expect(r.hugeBoxes, 0, reason: '失控高度: ${r.hugeTypes.take(5).join(", ")}');
    // 设置子页 `dispose` 会调 `PrefsMirror.snapshotSoon()`（400ms 去抖，见
    // settings_shared.dart）⇒ 跑掉它再结束，否则报「A Timer is still pending」。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));
    PrefsMirror.stopAutoSnapshot();
  });

  testWidgets('外观设置页：不出现 ErrorWidget / 失控高度', (tester) async {
    final r = await renderAndScan(tester, const AppearanceSettingsPage());
    // 外观页依赖 ThemeModeStore / BackgroundService 等单例，
    // 测试环境下可能取不到，但**不应该崩成 ErrorWidget 或撑爆高度**。
    expect(r.hugeBoxes, 0, reason: '失控高度: ${r.hugeTypes.take(5).join(", ")}');
  });

  testWidgets('主页页面：首页幻灯片排最前、样式卡片等宽且一行 ≥3 个', (tester) async {
    final r = await renderAndScan(tester, const HomePagesSettingsPage());
    expect(r.errorWidgets, 0,
        reason: '出现 ErrorWidget 说明有 Obx 内部没有可观察变量（长白板根因）');
    expect(r.hugeBoxes, 0, reason: '失控高度: ${r.hugeTypes.take(5).join(", ")}');

    // ① 顺序：这一组必须在「已启用 / 未启用」之前
    expect(
      tester.getTopLeft(find.text('首页幻灯片')).dy,
      lessThan(tester.getTopLeft(find.text('已启用')).dy),
      reason: '首页幻灯片要排在主页页面最前面',
    );

    // ② 名称统一 ≤4 字（旧的「三格海报轨」「双排海报」等已换掉）
    expect(find.text('叠卡堆'), findsNothing);
    expect(find.text('三格海报'), findsNothing);
    expect(find.text('双排海报'), findsNothing);
    expect(find.text('主次三栏'), findsOneWidget);
    expect(find.text('编辑推荐'), findsOneWidget);

    // ③ 全部样式卡片**等宽**
    const labels = [
      '横版大图', '卡片轮播', '沉浸大图', '主次三栏', '交错瀑布',
      '编辑推荐', '高低错落', '走马灯', '扑克牌', '标签页',
    ];
    Finder cardOf(String l) =>
        find.ancestor(of: find.text(l), matching: find.byType(Column)).first;
    final widths = {for (final l in labels) l: tester.getSize(cardOf(l)).width};
    final base = widths[labels.first]!;
    for (final e in widths.entries) {
      expect(e.value, closeTo(base, 0.5),
          reason: '${e.key} 宽 ${e.value} 与其它卡片不一致（基准 $base）');
    }

    // ④ 一行至少 3 个（同 y 上至少 3 张卡）
    final y0 = tester.getTopLeft(cardOf(labels.first)).dy;
    final sameRow = labels
        .where((l) => (tester.getTopLeft(cardOf(l)).dy - y0).abs() < 1)
        .length;
    expect(sameRow, greaterThanOrEqualTo(3), reason: '一行只有 $sameRow 个');

    // ⚠️ 收尾：这页在 `dispose` 里会调 `PrefsMirror.snapshotSoon()`（400ms 去抖）
    //    ⇒ 必须把它跑掉，否则测试结束时报「A Timer is still pending」
    //    （纯测试环境问题，与布局无关）。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));
    PrefsMirror.stopAutoSnapshot();
  });

  testWidgets('订阅管理页：不出现 ErrorWidget / 失控高度（网页 / RSS 管理行）', (tester) async {
    // 用户 2026-10-15：「订阅管理里面这么大长白条」= 这两行原来包了 `Obx`，
    // 而 `WebHomePrefs.sources` / `RssStore.sources` 都是普通 List（非 Rx）
    // ⇒ Obx 抛错 ⇒ ErrorWidget（100000px 灰板），下面所有行一起被吃掉。
    // ⚠️ 这里**故意不注册** SettingsController：本页还有一个入口是启动页的
    //    「更换源」，那条路径从未构建过 SettingsPage ⇒ 控制器不存在。
    //    页内必须自己兜底注册，否则第二个分组会被 ErrorWidget（灰板）吃掉。
    // 这页的「点播接口地址」行读 `ApiConfig`（GetX 单例），不注册会整页塌掉
    Get.put(ApiConfig());
    final r = await renderAndScan(tester, const DataSourceSettingsPage());
    expect(r.errorWidgets, 0,
        reason: '出现 ErrorWidget 说明有 Obx 内部没有可观察变量（长白板根因）');
    expect(r.hugeBoxes, 0, reason: '失控高度: ${r.hugeTypes.take(5).join(", ")}');
    // 「网页管理」已随 WebHTV 下线移除（2026-10）；
    // 「RSS 管理」也已由用户 2026-10-18 要求移除（见
    // data_source_settings_page.dart 顶部注释）——本用例原来还断言它存在，
    // 属于测试没跟上产品变更，这里改断言**当前仍存在的行**。
    expect(find.text('主页数据'), findsOneWidget);
    // 「解析线路」行已随嗅探/解析功能整体移除（2026-10-29），改断言当前存在的行。
    // 2026-10-30：用户要求「本地爬虫」统一改名「本地PY」（引擎其实是 Python）。
    expect(find.text('本地PY'), findsOneWidget);
    // 同日用户要求去掉卡片副标题小字 —— 它和右侧的「N 个」挤在一行，
    // 长文案还会换行，把行高撑乱（截图里「已启用：本地源会出现 155 个 /
    // 在源面板 / 搜索里」就是这么挤出来的）。这里锁住"不再有小字"。
    expect(find.textContaining('已启用：'), findsNothing);
    expect(find.textContaining('已关闭：'), findsNothing);
    // 这两行之后的行也必须还在（原来被 ErrorWidget 吃掉了）
    expect(find.text('引擎管理'), findsOneWidget);
    // 2026-10-29：订阅管理页新增了「本地JS」一行，列表变长，
    // 「重置配置」已滚出首屏 —— ListView 是懒构建的，不滚过去就根本不存在。
    await tester.scrollUntilVisible(
      find.text('重置配置'),
      240,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('重置配置'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));
    PrefsMirror.stopAutoSnapshot();
  });

  testWidgets('SettingsGroup 自身尺寸正常（不依赖任何页面状态）', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 390,
          height: 844,
          child: ListView(
            children: [
              SettingsGroup(
                key: key,
                title: '测试分组',
                children: const [
                  SettingsRow(icon: Icons.info_outline, title: '行一'),
                  SettingsRow(icon: Icons.info_outline, title: '行二'),
                ],
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final size = tester.getSize(find.byKey(key));
    // 两行 + 标题应该是 200 上下；远超说明被撑爆
    expect(size.height, lessThan(400), reason: 'SettingsGroup 高度失控：$size');
    expect(find.byType(ErrorWidget).evaluate(), isEmpty);
  });

  /// 分组标题必须是「主题色竖条 + 12.5 加粗」——
  /// 与 `tg_source_page._section`、TG 首页区块标题同一套。
  ///
  /// 反向验证过：把样式回退成旧的「11 号浅灰、无竖条」这条会红。
  testWidgets('SettingsGroup 标题：竖条 + 12.5 w700 textSecondary', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 390,
          height: 844,
          child: ListView(
            children: const [
              SettingsGroup(
                title: '连接',
                children: [
                  SettingsRow(icon: Icons.info_outline, title: '行一'),
                ],
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 1) 标题文字样式
    final text = tester.widget<Text>(find.text('连接'));
    final style = text.style!;
    expect(style.fontSize, 12.5, reason: '标题字号应与 TG 设置页一致');
    expect(style.fontWeight, FontWeight.w700);
    expect(style.color, AppTheme.textSecondary);

    // 2) 竖条存在：3 宽 / 12 高 / accentOnSurface 底 / 圆角 2
    final bars = tester
        .widgetList<Container>(find.byType(Container))
        .where((c) {
      final d = c.decoration;
      if (d is! BoxDecoration) return false;
      return d.color == AppTheme.accentOnSurface;
    }).toList();
    expect(bars, isNotEmpty, reason: '分组标题缺少主题色竖条');
    final barSize = tester.getSize(find.byWidget(bars.first));
    expect(barSize.width, 3);
    expect(barSize.height, 12);
  });
}
