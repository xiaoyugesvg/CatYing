import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/hiker/models/hiker_source.dart';
import 'package:tvbox/hiker/services/hiker_route.dart';

/// 「海阔小程序」页面模块（`hiker://page/<名>`）的回归测试。
///
/// ── 背景 ────────────────────────────────────────────────────────
/// 海阔的「小程序脚本」不是"一个首页 + 一个详情"，而是一套**多页**：
/// 源的 `pages` 里每个模块（`{name, rule}`）就是一个页面，条目地址写成
/// `hiker://page/<名>`，点开 = 执行那个模块的 rule 再铺一屏。
///
/// 我们原来把 `hiker://page/*` 一律并进「海阔内部页」⇒ 点了只弹
/// 「本版不支持」，整套多页功能等于没移植。这里钉死三件事：
///   ① 能把它从普通 `hiker://` 内部页里**分出来**；
///   ② 模块名 / 参数解析正确（含未编码的中文、全角问号、`#flag` 尾巴）；
///   ③ 源的 `pages` 里到底有没有这个模块（决定"能打开"还是"指向内置页"）。
void main() {
  group('parseHikerPageUrl —— 拆 hiker://page/<名>?参数', () {
    test('只有模块名', () {
      final r = parseHikerPageUrl('hiker://page/detail');
      expect(r, isNotNull);
      expect(r!.module, 'detail');
      expect(r.url, 'hiker://page/detail');
      expect(r.args, isEmpty);
    });

    test('带参数（`?a=b&c=d`）', () {
      final r = parseHikerPageUrl('hiker://page/detail?id=123&type=movie');
      expect(r!.module, 'detail');
      expect(r.args, {'id': '123', 'type': 'movie'});
    });

    test('参数值有未编码的中文也要取出来', () {
      // 源里常直接拼中文（`hiker://page/search?kw=庆余年`），Uri 解析会整条丢掉
      final r = parseHikerPageUrl('hiker://page/search?kw=庆余年');
      expect(r!.module, 'search');
      expect(r.args['kw'], '庆余年');
    });

    test('百分号编码要解码', () {
      final r = parseHikerPageUrl('hiker://page/search?kw=%E5%BA%86%E4%BD%99%E5%B9%B4');
      expect(r!.args['kw'], '庆余年');
    });

    test('坏编码不能把参数丢掉（原样保留）', () {
      final r = parseHikerPageUrl('hiker://page/x?a=%zz');
      expect(r!.args['a'], '%zz');
    });

    test('模块名后面的 #flag 不算名字的一部分', () {
      final r = parseHikerPageUrl('hiker://page/detail#noHistory#');
      expect(r!.module, 'detail');
    });

    test('全角问号也能切开（实测有源这么写）', () {
      final r = parseHikerPageUrl('hiker://page/funcTools？rule=xxx');
      expect(r!.module, 'funcTools');
    });

    test('不是页面模块的一律返回 null', () {
      for (final u in [
        'hiker://page/', // 空名字
        'hiker://setting',
        'hiker://collect',
        'hiker://search?rule=x&s=y', // 搜索深链走另一支
        'hiker://lazy#abc',
        'https://a.com/page/x',
        '',
      ]) {
        expect(parseHikerPageUrl(u), isNull, reason: u);
      }
    });

    test('大小写不敏感（HIker://PAGE/xxx）', () {
      final r = parseHikerPageUrl('HIKER://PAGE/detail');
      expect(r!.module, 'detail');
    });
  });

  group('hikerLinkKind —— 页面模块必须与"内置页"分开', () {
    test('hiker://page/xxx 判成 hikerPageModule，不是 hikerPage', () {
      expect(
        hikerLinkKind('hiker://page/detail'),
        HikerLinkKind.hikerPageModule,
      );
      expect(
        hikerLinkKind('hiker://page/detail'),
        isNot(HikerLinkKind.hikerPage),
      );
    });

    test('官方内置页仍然是 hikerPage（我们没有、也不该有）', () {
      for (final u in [
        'hiker://setting',
        'hiker://collect',
        'hiker://history',
        'hiker://about',
        'hiker://home',
      ]) {
        expect(hikerLinkKind(u), HikerLinkKind.hikerPage, reason: u);
      }
    });

    test('搜索深链的优先级不变（hiker://search 不是页面模块）', () {
      expect(
        hikerLinkKind('hiker://search?rule=聚阅&s=庆余年'),
        HikerLinkKind.search,
      );
    });
  });

  group('describeHikerLink —— 界面文案', () {
    test('页面模块说"打开页面模块"，不再说"本版不支持"', () {
      final d = describeHikerLink('hiker://page/detail');
      expect(d.kind, '小程序页面');
      expect(d.detail, contains('detail'));
      expect(d.detail, isNot(contains('不支持')));
    });

    test('带参数时把参数个数露出来（排查用）', () {
      final d = describeHikerLink('hiker://page/detail?id=1&t=2');
      expect(d.detail, contains('2 个参数'));
    });
  });

  group('HikerSource.hasPageModule —— 源里到底有没有这一页', () {
    HikerSource src(Object? pages) =>
        HikerSource({'title': '测试源', 'find_rule': 'js:1', 'pages': pages});

    test('name 精确命中', () {
      final s = src([
        {'name': 'home', 'rule': 'js:1'},
        {'name': 'detail', 'rule': 'js:2'},
      ]);
      expect(s.hasPageModule('detail'), isTrue);
      expect(s.hasPageModule('nope'), isFalse);
    });

    test('path 的 basename / 去 .js 都认（与引擎 findPageModule 同口径）', () {
      final s = src([
        {'name': '', 'path': 'assets/detail.js', 'rule': 'js:2'},
      ]);
      expect(s.hasPageModule('detail'), isTrue);
      expect(s.hasPageModule('detail.js'), isTrue);
      expect(s.hasPageModule('assets/detail.js'), isTrue);
    });

    test('pages 是 JSON 字符串（海阔导出的真实形态）也要认', () {
      final s = src('[{"name":"home","rule":"js:1"}]');
      expect(s.hasPageModule('home'), isTrue);
    });

    test('空名字 / 没有 pages ⇒ false', () {
      expect(src(null).hasPageModule('x'), isFalse);
      expect(src([]).hasPageModule('x'), isFalse);
      expect(src([{'name': 'x', 'rule': ''}]).hasPageModule(''), isFalse);
    });

    test('小程序脚本判定与页面模块判定互不干扰', () {
      final s = src([
        {'name': 'home', 'rule': 'js:1'},
      ]);
      expect(s.isMiniAppScript, isTrue);
      expect(s.kindLabel, '海阔小程序脚本');
      expect(s.hasPageModule('home'), isTrue);
    });
  });

  group('小程序源：find_rule 空但自带 home 页面模块 ⇒ 仍算可用', () {
    test('没有 find_rule、也没有 home 模块 ⇒ 不可用（缺首页规则）', () {
      final s = HikerSource({'title': 'x', 'find_rule': ''});
      expect(s.usable, isFalse);
      expect(s.unusableReason, '没有 find_rule');
      expect(
        s.diagnose().any((d) => d.label == '无首页规则'),
        isTrue,
      );
    });

    test('没有 find_rule、但有 home 模块 ⇒ 可用（引擎会用那个模块当首页）', () {
      final s = HikerSource({
        'title': 'x',
        'find_rule': '',
        'pages': [
          {'name': 'home', 'rule': 'js:1'},
        ],
      });
      expect(s.usable, isTrue);
      expect(s.unusableReason, '');
      expect(
        s.diagnose().any((d) => d.label == '无首页规则'),
        isFalse,
      );
    });

    test('home 模块叫别的名字不算（`main` / `index` 不兜底）', () {
      final s = HikerSource({
        'title': 'x',
        'find_rule': '',
        'pages': [
          {'name': 'main', 'rule': 'js:1'},
        ],
      });
      expect(s.usable, isFalse);
    });
  });
}
