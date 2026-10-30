import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/models/movie.dart';
import 'package:tvbox/models/movie_sort.dart';
import 'package:tvbox/rfw_theme/rfw_theme_data.dart';
import 'package:tvbox/rfw_theme/rfw_theme_host.dart';
import 'package:tvbox/rfw_theme/rfw_theme_store.dart';

/// RFW 主题的**真实渲染**回归测试。
///
/// ── 为什么必须有这一层（2026-10-30）──────────────────────────────
/// 用户截图里顶栏四个按钮全显示成 `?`，同时分类行底部被裁掉一截。
/// 这两件事纯 Dart 层的断言都抓不到：
///
///   · 图标：DSL 写成了 `Icon(icon: args.icon)`。RFW 的 `Icon` 解码器是
///     `ArgumentDecoders.iconData(source, [])` —— 它读的是 **Icon widget
///     自己的** `icon` / `fontFamily` 参数，把整个 map 塞进 `icon` 时
///     取不到 int，于是回落 `Icons.flutter_dash`（0xE2A0，豆腐块）。
///     必须写成 `icon:` + `fontFamily:` 两段。
///   · 高度：`stickyHeaderHeight` 写死 84，实际内容要 89 ⇒ RenderFlex
///     overflow，顶栏底部 5px 被吃掉。
///
/// 所以这里真的把主题渲染出来，检查图标码点、色板落地和溢出。
void main() {
  /// 顶栏四个工具按钮的期望图标（与 `rfw_theme_data.dart` 的 icons 表一致）
  const expectedToolIcons = <IconData>[
    // 换源（2026-10-30）：从分组标题右边的文字链接挪进顶栏按钮排，
    // 用户原话「换源也要在那个按钮边上」——所以它必须出现在顶栏图标里。
    Icons.swap_horiz,
    Icons.search,
    Icons.refresh,
    Icons.grid_view,
    Icons.filter_list,
  ];

  RfwHomeDataInput buildInput(String themeId) => RfwHomeDataInput(
        categories: const [
          SortData(id: '1', name: '韩国'),
          SortData(id: '2', name: '日本'),
          SortData(id: '3', name: '动作片'),
        ],
        category: '1',
        items: [
          for (var i = 0; i < 6; i++)
            Video(id: 'v$i', name: '片名$i', pic: 'p.jpg', note: '更新至10集'),
        ],
        recommend: [
          Video(id: 'r1', name: '推荐一', pic: 'r.jpg', note: '2024'),
        ],
        // 必须给一组筛选：晨光/素影/星河把筛选按钮无条件画出来，但
        // 蓝魔凝光/春日记忆是按 `hasFilters` 条件渲染的 —— 传空数组时
        // 那个按钮根本不存在，断言"五个图标都在"就会误报成豆腐块 bug。
        filters: const [
          SortFilter(
            key: 'year',
            name: '年份',
            values: [SortFilterValue(n: '2024', v: '2024')],
          ),
        ],
        selectedFilters: const {},
        sourceName: 'Makka聚合',
        themeId: themeId,
      );

  Future<void> pumpTheme(WidgetTester tester, String themeId) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final entry = builtinRfwThemes.firstWhere((e) => e.id == themeId);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RfwThemeHost(
            themeText: File(entry.asset!).readAsStringSync(),
            homeData: buildRfwHomeData(buildInput(themeId)),
            onAction: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('顶栏工具图标', () {
    for (final entry in builtinRfwThemes) {
      testWidgets('${entry.name}：顶栏五个工具图标不是豆腐块', (tester) async {
        await pumpTheme(tester, entry.id);

        final icons = tester.widgetList<Icon>(find.byType(Icon)).toList();
        expect(icons, isNotEmpty, reason: '${entry.name} 一个图标都没渲染出来');

        // 不按顺序取：有轮播的主题里 hero 卡片先于 Header 渲染，
        // T4Image 的占位图标会排在前面。改成「按码点找得到」。
        final codepoints = icons.map((i) => i.icon?.codePoint).toList();
        for (final expected in expectedToolIcons) {
          expect(
            codepoints,
            contains(expected.codePoint),
            reason: '${entry.name} 缺少顶栏图标 0x${expected.codePoint.toRadixString(16)}',
          );
        }

        // 每个顶栏图标的 fontFamily 必须还在
        //（2026-10-30 的 bug：fontFamily 丢了 → 字形找不到 → 显示「?」）
        for (final icon in icons) {
          final cp = icon.icon?.codePoint;
          final isTool = expectedToolIcons.any((e) => e.codePoint == cp);
          if (!isTool) continue;
          expect(
            icon.icon?.fontFamily,
            'MaterialIcons',
            reason: '${entry.name} 的顶栏图标缺 fontFamily，会画成豆腐块',
          );
        }

        // 明确排除回落的占位图标
        expect(
          codepoints,
          isNot(contains(Icons.flutter_dash.codePoint)),
          reason: '${entry.name} 有图标回落成了 flutter_dash（说明参数没解出来）',
        );
      });
    }
  });

  group('三个主题的视觉语言互不相同', () {
    test('轮播高度按主题给：星河最大，素影不做轮播', () {
      expect(
        (buildRfwHomeData(buildInput('xinghe'))['heroHeight'] as double),
        greaterThan(
          buildRfwHomeData(buildInput('chenguang'))['heroHeight'] as double,
        ),
      );
      expect(
        buildRfwHomeData(buildInput('chenguang'))['heroHeight'] as double,
        greaterThan(0),
      );
    });

    test('没有推荐位时谁都不占轮播高度', () {
      for (final id in ['chenguang', 'suyu', 'xinghe']) {
        final input = RfwHomeDataInput(
          categories: const [],
          category: '',
          items: const [],
          recommend: const [],
          filters: const [],
          selectedFilters: const {},
          themeId: id,
        );
        expect(buildRfwHomeData(input)['heroHeight'], 0.0, reason: id);
      }
    });

    test('每个主题都有自己的卡片写法（不是同一份复制粘贴）', () {
      // 2026-10-30 用户：「幻灯片、卡片等等应该要和 RWF 的主题样式」
      // 之前三个主题的 PosterItem/RowItem 完全一样，只有颜色不同。
      // 这里锁住"每个主题的卡片语言必须不同"这个契约：
      //   晨光 = 1px 描边（padding 1 + border 色外圈）
      //   素影 = 0.5px 分隔线（无卡片底）
      //   星河 = 标题压在图上（渐变蒙层）
      final marks = <String, String>{
        'chenguang': 'padding: [1.0]',
        'suyu': 'height: 0.5, color: data.home.theme.border',
        'xinghe': '正在热映',
      };
      for (final entry in marks.entries) {
        final theme = builtinRfwThemes.firstWhere((e) => e.id == entry.key);
        final text = File(theme.asset!).readAsStringSync();
        expect(
          text.contains(entry.value),
          isTrue,
          reason: '${theme.name} 丢了它自己的卡片语言标记 `${entry.value}`',
        );
      }
    });
  });

  group('吸顶头高度', () {
    test('留足内容高度，不再卡在 84', () {
      // Header 实际内容 = 工具行 32 + 间距 8 + 分类行 33 = 73，
      // 加 padding 上 12 / 下 4 = 89。84 会溢出 5px。
      final data = buildRfwHomeData(buildInput('chenguang'));
      expect(data['stickyHeaderHeight'] as double, greaterThanOrEqualTo(92.0));
    });

    test('展开筛选后按每组 66 追加（原来按 40 算，差 26/组）', () {
      final input = RfwHomeDataInput(
        categories: const [],
        category: '',
        items: const [],
        recommend: const [],
        filters: const [
          SortFilter(
            key: 'year',
            name: '年份',
            values: [SortFilterValue(n: '2024', v: '2024')],
          ),
          SortFilter(
            key: 'area',
            name: '地区',
            values: [SortFilterValue(n: '韩国', v: '韩国')],
          ),
        ],
        selectedFilters: const {},
        showFilters: true,
      );
      final collapsed = buildRfwHomeData(
        RfwHomeDataInput(
          categories: const [],
          category: '',
          items: const [],
          recommend: const [],
          filters: input.filters,
          selectedFilters: const {},
        ),
      )['stickyHeaderHeight'] as double;
      final expanded = buildRfwHomeData(input)['stickyHeaderHeight'] as double;
      // 两组：2 * 66 + 12 = 144
      expect(expanded - collapsed, closeTo(144.0, 0.01));
    });

    /// 2026-10-30：蓝魔凝光首跑就报 `RenderFlex overflowed by 2.0 pixels`。
    /// 它的 PinnedHeader = 分类栏 58（padding 6+6 + 内框 46）+ 按钮栏 34
    /// （padding 2+2 + 圆钮 30）= 92，而主题里把 pinnedHeight 写成了 90。
    /// 现在改成读这个键：102 基准 + 展开筛选时的面板高。
    test('沉浸式吸顶头 = 94 基准 + 筛选面板高（蓝魔凝光）', () {
      final collapsed = buildRfwHomeData(buildInput('lanmo'))[
          'immersiveStickyHeaderHeight'] as double;
      // 内容实测 92（分类栏 58 + 按钮栏 34），留 2px 余量。
      expect(collapsed, closeTo(94.0, 0.01));

      final expanded = buildRfwHomeData(
        RfwHomeDataInput(
          categories: const [],
          category: '',
          items: const [],
          recommend: const [],
          filters: const [
            SortFilter(
              key: 'year',
              name: '年份',
              values: [SortFilterValue(n: '2024', v: '2024')],
            ),
            SortFilter(
              key: 'area',
              name: '地区',
              values: [SortFilterValue(n: '韩国', v: '韩国')],
            ),
          ],
          selectedFilters: const {},
          showFilters: true,
        ),
      )['immersiveStickyHeaderHeight'] as double;
      // 面板 2 * 66 + 12 = 144，加 padding/边框 12 ⇒ 156
      expect(expanded - collapsed, closeTo(156.0, 0.01));
    });

    testWidgets('蓝魔凝光展开筛选时不溢出', (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      final entry = builtinRfwThemes.firstWhere((e) => e.id == 'lanmo');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RfwThemeHost(
              themeText: File(entry.asset!).readAsStringSync(),
              homeData: buildRfwHomeData(
                RfwHomeDataInput(
                  categories: const [SortData(id: '1', name: '韩国')],
                  category: '1',
                  items: const [],
                  recommend: const [],
                  filters: const [
                    SortFilter(
                      key: 'year',
                      name: '年份',
                      values: [SortFilterValue(n: '2024', v: '2024')],
                    ),
                    SortFilter(
                      key: 'area',
                      name: '地区',
                      values: [SortFilterValue(n: '韩国', v: '韩国')],
                    ),
                  ],
                  selectedFilters: const {},
                  showFilters: true,
                  themeId: 'lanmo',
                ),
              ),
              onAction: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  /// 2026-10-30：用户「RWF 主题的内容加载页面不好看」。
  ///
  /// 加载态以前是正中间一行灰字「加载中…」，整块内容区空着。现在铺骨架卡
  /// （与海报卡同尺寸的圆角灰块）。这里真的把它渲染出来 ——
  /// `empty:` 槽只在**列表为空**时才会被实例化，上面那些用例（都有 6 条数据）
  /// **根本走不到**，DSL 写错了也测不出来。
  group('加载态是骨架屏，不是一行灰字', () {
    for (final entry in builtinRfwThemes) {
      testWidgets('${entry.name}：加载时铺骨架卡且不崩', (tester) async {
        tester.view.physicalSize = const Size(1170, 2532);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: RfwThemeHost(
                themeText: File(entry.asset!).readAsStringSync(),
                homeData: buildRfwHomeData(
                  RfwHomeDataInput(
                    categories: const [SortData(id: '1', name: '电影')],
                    category: '1',
                    items: const [],
                    recommend: const [],
                    filters: const [],
                    selectedFilters: const {},
                    loading: true,
                    sourceName: '测试源',
                    themeId: entry.id,
                  ),
                ),
                onAction: (_) {},
              ),
            ),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull,
            reason: '${entry.name} 的加载态渲染崩了（多半是 Container 同时给了 '
                'color 和 decoration —— RFW 解码成 AnimatedContainer 会断言）');
        expect(find.text('正在加载…'), findsOneWidget,
            reason: '${entry.name} 的加载态没渲染出来');
        // 旧写法的那行灰字必须消失（否则说明 empty 槽还是老实现）
        expect(find.text('加载中…'), findsNothing,
            reason: '${entry.name} 还在用旧的"加载中…"纯文字占位');
      });
    }
  });
}
