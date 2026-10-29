// 海阔列表分块渲染的回归测试（用户 2026-10-16：「海阔是将分类作为 tab 的」）
//
// 断言的是"分类按钮 + 图标行 + 文本行"不再被当成图片卡片，且点击语义正确：
//   · scroll_button / icon_* / text_* / input → onTapAction（就地切换分类）
//   · movie_* / pic_*                        → onTapItem（进详情页）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/hiker/models/hiker_source.dart';
import 'package:tvbox/hiker/widgets/hiker_blocks.dart';

HikerItem _it(String title, String colType, {String url = '', String pic = ''}) =>
    HikerItem(title: title, url: url, colType: colType, pic: pic);

/// 有没有"代码外露"：HTML 标签或富文本标记剩在纯文本里（用户 2026-10-16
/// 「分类名称里面不要出现各种符号」「也不要代码外露」的回归判据）
bool findHtmlLeak(String s) {
  final t = hikerPlainText(s);
  return t.contains('<') ||
      t.contains('>') ||
      t.contains('‘') ||
      t.contains('’') ||
      t.contains('“') ||
      t.contains('”');
}

void main() {
  testWidgets('分类按 col_type 分块渲染，点击走"就地切换"', (tester) async {
    // 与引擎真实输出一致（见 _probe_category_flow：分类条目带 hiker://lazy#id，
    // 当前选中项被源标成 `‘‘’’<b>…</b>`）
    final items = <HikerItem>[
      _it('A', 'scroll_button', url: 'hiker://lazy#1'),
      _it('‘‘’’<b>B</b>', 'scroll_button', url: 'hiker://lazy#2'),
      _it('搜索短剧 / 演员', 'input'),
      _it('周榜', 'icon_small_4', url: 'hiker://lazy#3'),
      _it('内容:B', 'text_center_1'),
      _it('剧一', 'movie_3', url: 'https://x/1'),
      _it('剧二', 'movie_3', url: 'https://x/2'),
      _it('', 'blank_block'),
      _it('—— 到底了 ——', 'text_1'),
    ];

    final actions = <String>[];
    final opens = <String>[];
    var searched = 0;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HikerBlocks(
          items: items,
          onTapItem: (it) => opens.add(it.title),
          onTapAction: (it) => actions.add(it.url),
          onTapSearch: () => searched++,
        ),
      ),
    ));
    await tester.pump();

    // 1) 富文本标记要被解析掉（不能把 `‘‘’’<b>` 原样显示出来）
    expect(find.textContaining('‘‘’’', findRichText: true), findsNothing,
        reason: '富文本标记必须被剥掉');
    expect(find.textContaining('A', findRichText: true), findsWidgets);

    // 2) 只有"内容卡片"才带图片占位：本用例里 movie_3 两张（剧一/剧二）
    //    ⇒ text_center_1 / input / 图标行 / 分类按钮都不该出现占位图
    expect(find.byIcon(Icons.movie_outlined), findsNWidgets(2),
        reason: 'text/input/分类类条目不该带图片占位');

    // 3) 分类按钮：点它 → onTapAction，并且带上 lazy 地址
    await tester.tap(find.textContaining('B', findRichText: true).first);
    await tester.pump();
    expect(actions, contains('hiker://lazy#2'),
        reason: '点分类应该走"就地切换"（带 lazy 地址），而不是进详情页');

    // 4) 图标入口同样走 onTapAction
    await tester.tap(find.textContaining('周榜', findRichText: true).first);
    await tester.pump();
    expect(actions, contains('hiker://lazy#3'));

    // 5) 源自带的搜索框可点（趁没滚动，ListView 里顶部的块还在树里）
    await tester.tap(find.textContaining('搜索短剧', findRichText: true).first);
    await tester.pump();
    expect(searched, 1);

    // 6) 内容卡片 → onTapItem（进详情页）
    final card = find.textContaining('剧一', findRichText: true).first;
    await tester.ensureVisible(card);
    await tester.pump();
    await tester.tap(card);
    await tester.pump();
    expect(opens, contains('剧一'));
    expect(actions, isNot(contains('https://x/1')));
  });

  test('splitLeadingNav：把顶部的分类行摘出来固定，其余保持顺序', () {
    final items = <HikerItem>[
      _it('搜索短剧 / 演员', 'input'),
      _it('A', 'scroll_button', url: 'hiker://lazy#A'),
      _it('B', 'scroll_button', url: 'hiker://lazy#B'),
      _it('内容:B', 'text_center_1'),
      _it('剧一', 'movie_3', url: 'https://x/1'),
    ];
    final s = splitLeadingNav(items);
    expect(s.pinned.map((e) => e.title).toList(), ['A', 'B'],
        reason: '顶部的分类行应被摘出来（固定显示）');
    expect(s.rest.map((e) => e.title).toList(), ['搜索短剧 / 演员', '内容:B', '剧一'],
        reason: '其余条目顺序不能变');
  });

  test('splitLeadingNav：先内容后按钮的源不固定', () {
    final items = <HikerItem>[
      _it('剧一', 'movie_3', url: 'https://x/1'),
      _it('A', 'scroll_button', url: 'hiker://lazy#A'),
    ];
    final s = splitLeadingNav(items);
    expect(s.pinned, isEmpty);
    expect(s.rest.length, 2);
  });

  // ── 用户 2026-10-16：「收藏、历史、设置弄成一行」+「设置内容弄成弹窗」──

  testWidgets('text_3 三个工具按钮排成一行（收藏 / 历史 / 设置）', (tester) async {
    final tapped = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HikerBlocks(
          items: [
            _it('♥ 收藏', 'text_3', url: 'hiker://lazy#fav'),
            _it('🕘 历史', 'text_3', url: 'hiker://lazy#his'),
            _it('⚙ 设置', 'text_3', url: 'hiker://lazy#set'),
          ],
          onTapItem: (_) {},
          onTapAction: (it) => tapped.add(it.url),
        ),
      ),
    ));
    await tester.pump();

    double x(String s) =>
        tester.getCenter(find.textContaining(s, findRichText: true).first).dx;
    double y(String s) =>
        tester.getCenter(find.textContaining(s, findRichText: true).first).dy;

    // 官方 `ArticleColTypeEnum`：text_3 = spanCount 4 ⇒ 一行 3 个（同一 y）
    expect(y('历史'), closeTo(y('收藏'), 0.5), reason: 'text_3 必须排在同一行');
    expect(y('设置'), closeTo(y('收藏'), 0.5));
    expect(x('历史'), greaterThan(x('收藏')), reason: '横向排列，不是竖着堆三行');
    expect(x('设置'), greaterThan(x('历史')));

    await tester.tap(find.textContaining('设置', findRichText: true).first);
    await tester.pump();
    expect(tapped, ['hiker://lazy#set']);
  });

  testWidgets('text_2 一行两个、text_4 一行四个（按官方栅格）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HikerBlocks(
          items: [
            _it('甲', 'text_2', url: 'hiker://lazy#a'),
            _it('乙', 'text_2', url: 'hiker://lazy#b'),
            _it('丙', 'text_4', url: 'hiker://lazy#c'),
            _it('丁', 'text_4', url: 'hiker://lazy#d'),
            _it('戊', 'text_4', url: 'hiker://lazy#e'),
            _it('己', 'text_4', url: 'hiker://lazy#f'),
          ],
          onTapItem: (_) {},
          onTapAction: (_) {},
        ),
      ),
    ));
    await tester.pump();

    double y(String s) =>
        tester.getCenter(find.textContaining(s, findRichText: true).first).dy;
    expect(y('乙'), closeTo(y('甲'), 0.5));
    expect(y('丁'), closeTo(y('丙'), 0.5));
    expect(y('戊'), closeTo(y('丙'), 0.5));
    expect(y('己'), closeTo(y('丙'), 0.5));
    expect(y('丙'), greaterThan(y('甲')), reason: 'text_2 与 text_4 是两块');
  });

  testWidgets('textColumns：设置项 text_1 排成一行三个卡片（用户改的口径）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HikerBlocks(
          items: [
            _it('接口域名', 'text_1', url: 'hiker://lazy#1'),
            _it('每页数量', 'text_1', url: 'hiker://lazy#2'),
            _it('列表样式', 'text_1', url: 'hiker://lazy#3'),
            _it('短剧选集排序', 'text_1', url: 'hiker://lazy#4'),
          ],
          textColumns: 3,
          onTapItem: (_) {},
          onTapAction: (_) {},
        ),
      ),
    ));
    await tester.pump();

    double y(String s) =>
        tester.getCenter(find.textContaining(s, findRichText: true).first).dy;
    expect(y('每页数量'), closeTo(y('接口域名'), 0.5), reason: '一行三个');
    expect(y('列表样式'), closeTo(y('接口域名'), 0.5));
    expect(y('短剧选集排序'), greaterThan(y('接口域名')), reason: '第四个换行');
  });

  testWidgets('多列卡片要带上"当前值"（设置项的 desc）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HikerBlocks(
          items: [
            HikerItem(
                title: '接口域名',
                url: 'hiker://lazy#1',
                colType: 'text_1',
                desc: 'https://mdcmai4.xyz'),
          ],
          textColumns: 3,
          onTapItem: (_) {},
          onTapAction: (_) {},
        ),
      ),
    ));
    await tester.pump();
    expect(find.textContaining('mdcmai4.xyz', findRichText: true), findsOneWidget,
        reason: '三列之后一行放不下，值要另起一行显示，不能丢');
  });

  test('stripLeadingShell：弹窗里掐掉页面外壳（搜索框 / 分类 / 那行按钮）', () {
    // 与「麻豆传媒AI」第二轮真实输出同构（n=24 里有 10 条是壳）
    final items = <HikerItem>[
      _it('🔍 搜索视频', 'input'),
      _it('‘‘’’<font color=#777785>🔥 AI短剧</font>', 'scroll_button', url: 'hiker://lazy#c1'),
      _it('♥ 收藏', 'text_3', url: 'hiker://lazy#fav'),
      _it('🕘 历史', 'text_3', url: 'hiker://lazy#his'),
      _it('⚙ 设置', 'text_3', url: 'hiker://lazy#set'),
      _it('', 'blank_block'),
      _it('‘‘’’<strong><font color=#098AC1>程序设置</font></strong>', 'text_center_1'),
      _it('接口域名', 'text_1', url: 'hiker://lazy#1'),
    ];
    final kept = stripLeadingShell(items);
    expect(kept.map((e) => hikerPlainText(e.title)).toList(),
        ['程序设置', '接口域名'],
        reason: '内容从「程序设置」开始，壳全部丢掉');
  });

  test('stripLeadingShell：全是壳时返回空（宿主据此提示"没有内容"）', () {
    final kept = stripLeadingShell(<HikerItem>[
      _it('🔍 搜索', 'input'),
      _it('♥ 收藏', 'text_3', url: 'hiker://lazy#a'),
      _it('', 'blank_block'),
    ]);
    expect(kept, isEmpty);
  });

  // ── 用户 2026-10-16：「分类名称里不要出现各种符号」「不要代码外露」──

  test('第二套富文本标记 ““”” 也要吃（源里比 ‘‘’’ 还多：165 vs 80）', () {
    // 麻豆传媒AI 的当前分类原文
    const raw = '““””<b><font color=#FFFFFF>🔥 AI短剧</font></b>';
    expect(hikerPlainText(raw), '🔥 AI短剧',
        reason: '分类 chip 上不能出现 ““”” 和 HTML 标签');
    expect(findHtmlLeak(raw), isFalse);
    final spans = hikerRichSpans(raw, const TextStyle(color: Colors.black));
    expect(spans.map((s) => s.text).join(), '🔥 AI短剧');
    expect(spans.first.style?.fontWeight, FontWeight.w700, reason: '<b> = 加粗');
  });

  test('极端色（#FFFFFF / #000000）要忽略掉，否则主题面上是隐形字', () {
    final spans = hikerRichSpans(
        '““””<font color=#FFFFFF>白字</font>', const TextStyle(color: Colors.black));
    expect(spans.first.style?.color, Colors.black,
        reason: '源按它自己的底色写的白字，落到浅色卡上会看不见 ⇒ 回落主题色');

    final keep = hikerRichSpans(
        '‘‘’’<font color=#FF69B4>选中</font>', const TextStyle(color: Colors.black));
    expect(keep.first.style?.color, const Color(0xFFFF69B4),
        reason: '中间的彩色是源用来标"当前选中"的，必须保留');
  });

  test('正常标题里的单个引号不能被误伤（“我知女人心”）', () {
    expect(stripHikerRichMark('“我知女人心”（2024）'), '“我知女人心”（2024）');
    expect(hikerPlainText('“我知女人心”'), '“我知女人心”');
  });

  test('标记拆成两半写的也要处理（‘““’ + html + ‘””’）', () {
    expect(hikerPlainText('““<b>成人短剧</b>””'), '成人短剧');
  });

  test('富文本：<strong> 不能被原样显示（源里 strong() 就是这么拼的）', () {
    // 麻豆传媒AI 源：strong(txt,color) → '‘‘’’<strong><font color=#xxx>txt</font></strong>'
    const raw = '‘‘’’<strong><font color=#098AC1>程序设置</font></strong>';
    final spans = hikerRichSpans(raw, const TextStyle());
    expect(spans.map((s) => s.text).join(), '程序设置',
        reason: '<strong> 必须被吃掉；原来只认 b/i/font ⇒ 会把标签显示成文字');
    final styled = spans.firstWhere((s) => s.text == '程序设置');
    expect(styled.style?.fontWeight, FontWeight.w700, reason: '<strong> = 加粗');
    expect(styled.style?.color, const Color(0xFF098AC1));
  });

  test('富文本：未知标签只剥标签、保留文字', () {
    final spans = hikerRichSpans('<div>第一段</div><p>第二段</p>', const TextStyle());
    expect(spans.map((s) => s.text).join(), '第一段第二段');
  });
}
