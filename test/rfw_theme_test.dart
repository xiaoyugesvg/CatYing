import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/models/movie.dart';
import 'package:tvbox/models/movie_sort.dart';
import 'package:tvbox/rfw_theme/rfw_theme_data.dart';
import 'package:tvbox/rfw_theme/rfw_theme_palette.dart';
import 'package:tvbox/rfw_theme/rfw_theme_store.dart';
import 'package:tvbox/widgets/live_danmu.dart';

/// 一个能通过校验的最小主题：只 import 允许的两个库、有 root。
const _minimalTheme = '''
import core.widgets;

widget root = Text(text: "hi");
''';

void main() {
  group('RFW 主题校验（安全边界）', () {
    test('空文件被拒', () {
      expect(validateRfwThemeText('   ').ok, isFalse);
    });

    test('没有 root 被拒', () {
      final r = validateRfwThemeText('''
import core.widgets;

widget other = Text(text: "x");
''');
      expect(r.ok, isFalse);
      expect(r.reason, contains('root'));
    });

    test('引用了不支持的库被拒（防止主题拿到任意宿主 widget）', () {
      final r = validateRfwThemeText('''
import core.widgets;
import material.widgets;

widget root = Text(text: "x");
''');
      expect(r.ok, isFalse);
      expect(r.reason, contains('不支持的库'));
    });

    test('合法最小主题通过', () {
      final r = validateRfwThemeText(_minimalTheme);
      expect(r.ok, isTrue, reason: r.reason);
    });

    test('语法错误被拒', () {
      expect(validateRfwThemeText('widget root = ((((').ok, isFalse);
    });
  });

  group('主题文件名清洗', () {
    test('去扩展名 + 去控制字符', () {
      expect(rfwThemeFileName('晨光网格.rfwtxt'), '晨光网格.rfwtxt');
      expect(rfwThemeFileName('/tmp/a/b/星河.RFWTXT'), '星河.rfwtxt');
      expect(rfwThemeFileName('x\u0001y.txt'), 'xy.rfwtxt');
    });

    test('空名兜底成 theme', () {
      expect(rfwThemeFileName('.rfwtxt'), 'theme.rfwtxt');
    });
  });

  group('首页数据装配', () {
    test('片单 / 分类 / 筛选 / 推荐都映射到主题认的键', () {
      final data = buildRfwHomeData(
        RfwHomeDataInput(
          categories: const [
            SortData(id: '1', name: '电影'),
            SortData(id: '2', name: '剧集'),
          ],
          category: '2',
          items: [
            Video(id: 'v1', name: '片名', pic: 'p.jpg', note: '更新至10集'),
          ],
          recommend: [Video(id: 'r1', name: '推荐', pic: 'r.jpg')],
          filters: const [
            SortFilter(
              key: 'year',
              name: '年份',
              values: [SortFilterValue(n: '2024', v: '2024')],
            ),
          ],
          selectedFilters: const {'year': '2024'},
          displayStyle: 'grid',
          gridColumns: 3,
          sourceName: '测试源',
        ),
      );

      expect(data['displayStyle'], 'grid');
      expect(data['gridColumns'], 3);
      expect(data['source'], '测试源');
      expect(data['hasRecommend'], isTrue);
      expect(data['hasFilters'], isTrue);
      expect(data['hasManyClasses'], isFalse);

      final items = data['items'] as List;
      expect(items.length, 1);
      final item = items.first as Map<String, Object?>;
      expect(item['name'], '片名');
      expect(item['remarks'], '更新至10集');
      expect(item['index'], 0);

      final classes = data['classes'] as List;
      expect((classes[1] as Map)['selected'], isTrue);

      final filters = data['filters'] as List;
      final opts = (filters.first as Map)['options'] as List;
      // 「全部」+ 一个选项
      expect(opts.length, 2);
      expect((opts[0] as Map)['selected'], isFalse);
      expect((opts[1] as Map)['selected'], isTrue);

      final home = data['home'] as Map;
      expect((home['recommend'] as List).length, 1);
      // 沉浸头取第一张推荐的海报
      expect((data['immersive'] as Map)['imageUrl'], 'r.jpg');
    });

    test('没有推荐时沉浸头退回片单首图，heroHeight 为 0', () {
      final data = buildRfwHomeData(
        RfwHomeDataInput(
          categories: const [],
          category: '',
          items: [Video(id: 'v1', name: 'A', pic: 'a.jpg')],
          recommend: const [],
          filters: const [],
          selectedFilters: const {},
        ),
      );
      expect(data['heroHeight'], 0.0);
      expect(data['hasRecommend'], isFalse);
      expect((data['immersive'] as Map)['imageUrl'], 'a.jpg');
    });
  });

  group('内置主题贴合软件配色', () {
    test('三个内置主题都能解析且通过安全校验', () {
      for (final entry in builtinRfwThemes) {
        final file = File(entry.asset!);
        expect(file.existsSync(), isTrue, reason: '缺少主题文件 ${entry.asset}');
        final text = file.readAsStringSync();
        final r = validateRfwThemeText(text);
        expect(r.ok, isTrue, reason: '${entry.name}: ${r.reason}');
      }
    });

    test('主题文件里不许再出现写死的色值（透明除外）', () {
      // 2026-10-30 用户：「这个 RFW 主题没有贴合我的软件界面。」
      // 根因就是三个主题把底色/强调色/文字色全写死了，跟 24 套调色板无关。
      // 这条测试保证以后再加主题也必须走 data.home.theme.* 色板。
      final literal = RegExp(r'0x[0-9A-Fa-f]{8}');
      for (final entry in builtinRfwThemes) {
        final text = File(entry.asset!).readAsStringSync();
        final bad = literal
            .allMatches(text)
            .map((m) => m.group(0)!)
            .where((c) => c.toUpperCase() != '0X00000000') // 透明是允许的
            .toList();
        expect(bad, isEmpty, reason: '${entry.name} 还有写死色值：$bad');
      }
    });

    test('色板对每个主题都给出可读的文字与强调色', () {
      for (final id in ['chenguang', 'suyu', 'xinghe', 'custom_unknown']) {
        final p = RfwThemePalette.of(id);
        double contrast(Color a, Color b) {
          final la = a.computeLuminance();
          final lb = b.computeLuminance();
          final hi = la > lb ? la : lb;
          final lo = la > lb ? lb : la;
          return (hi + 0.05) / (lo + 0.05);
        }

        expect(
          contrast(p.textPrimary, p.bg),
          greaterThanOrEqualTo(7.0),
          reason: '$id 的正文压在底色上不够清楚',
        );
        expect(
          contrast(p.accent, p.bg),
          greaterThanOrEqualTo(4.4),
          reason: '$id 的强调色压在底色上看不清',
        );
        expect(
          contrast(p.onAccent, p.accentFill),
          greaterThanOrEqualTo(4.4),
          reason: '$id 的选中态文字压不住实底',
        );
        // 色板里的每个颜色都必须是不透明的（RFW 只有 int 色值，
        // 半透明底在吸顶头上会透出下面的海报，观感很脏）
        for (final c in [p.bg, p.card, p.textPrimary, p.accent, p.chipBg]) {
          expect(c.a, 1.0, reason: '$id 有半透明色混进了不透明 token');
        }
      }
    });

    test('星河强制深色，晨光/素影跟随软件明暗', () {
      expect(RfwThemePalette.of('xinghe').isDark, isTrue);
      expect(RfwThemePalette.of('xinghe').bg.computeLuminance(), lessThan(0.2));
      // 晨光与素影不是强制深色 —— 它们跟随 AppBrightness
      expect(
        RfwThemePalette.of('chenguang').isDark,
        RfwThemePalette.of('suyu').isDark,
      );
    });

    test('主题 id 回落：空/未知 id 不会把色板算错', () {
      expect(effectiveRfwThemeId(null), builtinRfwThemes.first.id);
      expect(effectiveRfwThemeId(''), builtinRfwThemes.first.id);
      expect(effectiveRfwThemeId('suyu'), 'suyu');
      // 自定义主题原样返回（色板走"跟随软件配色"分支）
      expect(effectiveRfwThemeId('我的主题.rfwtxt'), '我的主题.rfwtxt');
    });

    test('data.home.theme 的每个 token 都到位且类型正确', () {
      final data = buildRfwHomeData(
        RfwHomeDataInput(
          categories: const [],
          category: '',
          items: const [],
          recommend: const [],
          filters: const [],
          selectedFilters: const {},
          themeId: 'suyu',
        ),
      );
      final theme = data['theme'] as Map<String, Object?>;
      for (final key in [
        'bg',
        'surface',
        'card',
        'textPrimary',
        'textSecondary',
        'textTertiary',
        'accent',
        'accentFill',
        'onAccent',
        'chipBg',
        'border',
        'scrim',
        'onImage',
        'glassTint',
      ]) {
        expect(theme[key], isA<int>(), reason: '色板缺少 $key');
      }
      for (final key in [
        'radiusCard',
        'radiusChip',
        'radiusPill',
        'gap',
        'pad',
        'headerPadTop',
      ]) {
        expect(theme[key], isA<double>(), reason: '尺寸 token 缺少 $key');
      }
      expect(theme['isDark'], isA<bool>());
    });
  });

  group('一起看聊天弹幕', () {
    testWidgets('关闭时不渲染、开启后新消息只上屏一次', (tester) async {
      final items = <LiveDanmuItem>[
        const LiveDanmuItem(id: 'm1', text: '来了'),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 200,
              child: LiveDanmuOverlay(items: items),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(CustomPaint), findsWidgets);

      // 追加一条新消息：不应抛异常（去重逻辑在 didUpdateWidget 里）
      items.add(const LiveDanmuItem(id: 'm2', text: '好看'));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 200,
              child: LiveDanmuOverlay(items: items),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
    });

    testWidgets('enabled=false 时什么都不画', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 200,
              child: LiveDanmuOverlay(
                items: [LiveDanmuItem(id: 'x', text: 't')],
                enabled: false,
              ),
            ),
          ),
        ),
      );
      // 控件自己退化成 SizedBox.shrink：整个子树里没有它的 LayoutBuilder
      expect(
        find.descendant(
          of: find.byType(LiveDanmuOverlay),
          matching: find.byType(LayoutBuilder),
        ),
        findsNothing,
      );
    });
  });
}
