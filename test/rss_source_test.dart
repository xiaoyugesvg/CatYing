import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/rss/models/rss_source.dart';
import 'package:tvbox/rss/services/rss_reader.dart';
import 'package:tvbox/rss/services/rss_store.dart';
import 'package:tvbox/rss/widgets/rss_login_sheet.dart';

/// RSS 订阅源模块的**纯逻辑**回归测试（不联网）。
///
/// 覆盖三条最容易回归的链路：
///   · `parseRssSources` 能吃四种分享格式（Legado JSON / `{sources:[]}` /
///     数组 / OPML / 裸 URL 纯文本）
///   · `RssSource.channels` 的分类拆分（`名称::url`、多行、`&&`、空兜底）
///   · `RssReader` 的 URL 模板求值与时间格式化
void main() {
  group('parseRssSources —— Legado RSS 源 JSON', () {
    test('单个对象（user 给的「源仓库」singleUrl 型）', () {
      final list = parseRssSources('''
{
    "singleUrl": true,
    "sourceGroup": "1",
    "sourceName": "源仓库(官方纯净)",
    "sourceUrl": "http://yckceo.vip"
}
''');
      expect(list.length, 1);
      expect(list.first.name, '源仓库(官方纯净)');
      expect(list.first.url, 'http://yckceo.vip');
      expect(list.first.group, '1');
      expect(list.first.singleUrl, isTrue);
      expect(list.first.hasRules, isFalse, reason: 'singleUrl 型没有规则 ⇒ 走 XML 链路');
      expect(list.first.channels.single.url, 'http://yckceo.vip',
          reason: '没有 sortUrl ⇒ 用源主页兜底');
    });

    test('单个对象（user 给的「少数派」带规则型）', () {
      // ⚠️ 原始字符串：规则里有 `$.data`，普通字符串会把 `$` 当插值 ✗
      final list = parseRssSources(r'''
{
    "ruleArticles": "$.data",
    "ruleTitle": "$.title",
    "ruleLink": "$.id",
    "ruleNextPage": "page",
    "singleUrl": false,
    "sortUrl": "全部::/api/v1/article/matrix/page/get?offset={{page}}&limit=10",
    "sourceGroup": "资讯",
    "sourceName": "少数派",
    "sourceUrl": "https://sspai.com/"
}
''');
      expect(list.length, 1);
      final s = list.first;
      expect(s.name, '少数派');
      expect(s.group, '资讯');
      expect(s.hasRules, isTrue, reason: '有 ruleArticles/ruleTitle ⇒ 走规则引擎');
      expect(s.channels.length, 1);
      expect(s.channels.first.title, '全部');
      expect(s.channels.first.url,
          '/api/v1/article/matrix/page/get?offset={{page}}&limit=10');
    });

    test('清单对象 {sources:[...]}', () {
      final list = parseRssSources(
          '{"sources":[{"sourceName":"A","sourceUrl":"https://a.com"},'
          '{"sourceName":"B","sourceUrl":"https://b.com"}]}');
      expect(list.map((e) => e.name), ['A', 'B']);
    });

    test('数组 [{...},{...}]', () {
      final list = parseRssSources(
          '[{"name":"A","url":"https://a.com"},{"name":"B","url":"https://b.com"}]');
      expect(list.length, 2);
    });

    test('坏 JSON / 空串 → 空列表（不抛异常）', () {
      expect(parseRssSources(''), isEmpty);
      expect(parseRssSources('hello world'), isEmpty);
      expect(parseRssSources('{ 不是合法 json'), isEmpty);
    });

    test('缺 name / url 的条目被丢弃', () {
      final list = parseRssSources(
          '[{"sourceName":"X"},{"sourceUrl":"https://a.com"},'
          '{"sourceName":"Y","sourceUrl":"https://b.com"}]');
      expect(list.length, 1);
      expect(list.first.name, 'Y');
    });
  });

  group('parseRssSources —— OPML', () {
    test('标准 OPML（含嵌套分组）只取带 xmlUrl 的节点', () {
      const opml = '''<?xml version="1.0" encoding="UTF-8"?>
<opml version="2.0">
  <head><title>我的订阅</title></head>
  <body>
    <outline text="科技" title="科技">
      <outline type="rss" text="小众软件" title="小众软件"
               xmlUrl="https://www.appinn.com/feed/" htmlUrl="https://www.appinn.com/"/>
      <outline type="rss" text="少数派" xmlUrl="https://sspai.com/feed"/>
    </outline>
    <outline type="rss" text="独立博客" xmlUrl="https://blog.example.com/atom.xml"/>
  </body>
</opml>''';
      final list = parseRssSources(opml);
      expect(list.length, 3, reason: '分组节点（无 xmlUrl）不算源');
      expect(list.map((e) => e.name),
          containsAll(['小众软件', '少数派', '独立博客']));
      expect(list.firstWhere((e) => e.name == '少数派').url,
          'https://sspai.com/feed');
    });
  });

  group('parseRssSources —— 纯文本', () {
    test('每行一个裸地址，名称取 host', () {
      final list = parseRssSources('''
# 我的订阅
https://sspai.com/feed
https://www.appinn.com/feed/
''');
      expect(list.length, 2);
      expect(list.first.url, 'https://sspai.com/feed');
      expect(list.first.name, 'sspai.com', reason: '没给名称 ⇒ 用 host 兜底');
    });

    test('名称,地址 形式', () {
      final list = parseRssSources('少数派,https://sspai.com/feed');
      expect(list.single.name, '少数派');
      expect(list.single.url, 'https://sspai.com/feed');
    });
  });

  group('RssSource.channels 分类拆分', () {
    test('多行 + 名称::url', () {
      const s = RssSource(
        id: 'x',
        name: '源',
        url: 'https://a.com',
        sortUrl: '全部::https://a.com/all\n热榜::https://a.com/hot',
      );
      final ch = s.channels;
      expect(ch.length, 2);
      expect(ch[0].title, '全部');
      expect(ch[1].url, 'https://a.com/hot');
    });

    test('`&&` 分隔', () {
      const s = RssSource(
        id: 'x',
        name: '源',
        url: 'https://a.com',
        sortUrl: 'A::https://a.com/a&&B::https://a.com/b',
      );
      expect(s.channels.map((e) => e.title), ['A', 'B']);
    });

    test('sortUrl 为空 ⇒ 用源主页兜底', () {
      const s = RssSource(id: 'x', name: '源名', url: 'https://a.com');
      expect(s.channels.single.title, '源名');
      expect(s.channels.single.url, 'https://a.com');
    });

    test('有名称无 URL 的行被跳过', () {
      const s = RssSource(
        id: 'x',
        name: '源',
        url: 'https://a.com',
        sortUrl: '空行::\n有效::https://a.com/ok',
      );
      expect(s.channels.length, 1);
      expect(s.channels.single.title, '有效');
    });

    test('单地址里的 `&` **不**当分隔符（query 完整保留）', () {
      const s = RssSource(
        id: 'x',
        name: '源',
        url: 'https://a.com',
        sortUrl: '全部::https://a.com/api?offset=0&limit=10&created_at=',
      );
      expect(s.channels.length, 1);
      expect(
          s.channels.single.url, 'https://a.com/api?offset=0&limit=10&created_at=');
    });
  });

  group('规则判定（对齐 Legado 订阅源文档 rss.html）', () {
    test('hasRules 只看 ruleArticles —— 只有 ruleTitle 仍算"标准 RSS 源"', () {
      const onlyTitle = RssSource(
          id: 'x', name: 'S', url: 'https://a.com', ruleTitle: r'$.title');
      expect(onlyTitle.hasRules, isFalse,
          reason: '文档第 3 节：列表规则(ruleArticles) 才是"判断是否是标准RSS的标志"');
      const withArticles = RssSource(
          id: 'x', name: 'S', url: 'https://a.com', ruleArticles: r'$.data');
      expect(withArticles.hasRules, isTrue);
    });

    test('isPagedUrl 认 {{page}} 与 {{(page-1)*10}}，不误判路径里的 page', () {
      expect(RssReader.isPagedUrl('https://a.com/list?p={{page}}'), isTrue);
      expect(
          RssReader.isPagedUrl('https://a.com/api?offset={{(page-1)*10}}'), isTrue);
      expect(RssReader.isPagedUrl('https://a.com/page/2'), isFalse);
      expect(RssReader.isPagedUrl('https://a.com/feed'), isFalse);
    });

    test('站点型判定：singleUrl 且无列表规则 ⇒ isSiteOnly', () {
      // 用户那份 txt 里 5 条（源仓库 / Yiove / 使用文档 / 一键导入 / 喵公子）
      // 都是这种 —— RSS 页要把它们**内嵌网页直开**，而不是报"没抓到内容"。
      const site = RssSource(
          id: 'x', name: '源仓库', url: 'https://yckceo.vip', singleUrl: true);
      expect(site.isSiteOnly, isTrue);

      const feed = RssSource(
          id: 'y', name: '少数派 RSS', url: 'https://sspai.com/feed');
      expect(feed.isSiteOnly, isFalse, reason: '标准 RSS 源不是站点型');

      const rule = RssSource(
          id: 'z',
          name: '少数派',
          url: 'https://sspai.com/',
          singleUrl: true,
          ruleArticles: r'$.data');
      expect(rule.isSiteOnly, isFalse, reason: '有列表规则就按列表抓，不算站点型');
    });
  });

  group('RssReader.resolveUrl 模板求值', () {
    test('{{page}} 直替', () {
      expect(
        RssReader.resolveUrl(
            'https://a.com/list?p={{page}}', 'https://a.com', 3),
        'https://a.com/list?p=3',
      );
    });

    test('{{(page-1)*10}} 算术', () {
      expect(
        RssReader.resolveUrl(
            'https://a.com/api?offset={{(page-1)*10}}&limit=10',
            'https://a.com',
            3),
        'https://a.com/api?offset=20&limit=10',
      );
    });

    test('相对地址拼接源主页', () {
      expect(
        RssReader.resolveUrl('/feed', 'https://a.com/blog/', 1),
        'https://a.com/feed',
      );
    });

    test('空模板回退 base', () {
      expect(RssReader.resolveUrl('', 'https://a.com/feed', 1),
          'https://a.com/feed');
    });
  });

  group('RssReader.friendlyTime 时间格式化', () {
    test('已经是文本 ⇒ 原样返回', () {
      expect(RssReader.friendlyTime('2026-10-15'), '2026-10-15');
      expect(RssReader.friendlyTime(''), '');
    });

    test('unix 秒级时间戳 ⇒ 变成可读时间（非纯数字）', () {
      // 2026-10-15 前后都行：只要求结果不再是 10 位纯数字
      final out = RssReader.friendlyTime('1791993600');
      expect(RegExp(r'^\d{10}$').hasMatch(out), isFalse);
      expect(out, isNotEmpty);
    });
  });

  group('RssReader.parseArticles —— 规则链路（不联网）', () {
    test('HTML：Legado 文档**原样**例子 ruleArticles=id.content@h3', () {
      // 回归：列表若用 getStringList，末段 `h3` 会被当成"取属性 h3" ⇒ 0 条 ✗
      const html = '''
<html><body>
<div id="content">
  <h3><a href="/p/1">标题一</a></h3>
  <h3><a href="/p/2">标题二</a></h3>
</div>
</body></html>
''';
      const src = RssSource(
        id: 'x',
        name: '喵公子',
        url: 'http://a.com/gx.html',
        ruleArticles: 'id.content@h3',
        ruleTitle: 'a@textNodes',
        ruleLink: 'a@href',
      );
      final list = RssReader.parseArticles(src, html, 'http://a.com/gx.html');
      expect(list.length, 2);
      expect(list.map((a) => a.title), ['标题一', '标题二']);
      expect(list.map((a) => a.link), ['http://a.com/p/1', 'http://a.com/p/2']);
    });

    test('JSON：ruleArticles=\$.data + 字段规则（getElements 传 Map）', () {
      // 回归：getStringList 返回 Dart map 字符串（`{title: 甲}`）不是合法 JSON
      // ⇒ $.title 全空；getElements 直接传 Map 才命中 ✓
      const body = '{"data":[{"title":"甲","url":"https://a.com/1"},'
          '{"title":"乙","url":"https://a.com/2"}]}';
      const src = RssSource(
        id: 'x',
        name: '少数派',
        url: 'https://a.com/',
        ruleArticles: r'$.data',
        ruleTitle: r'$.title',
        ruleLink: r'$.url',
      );
      final list = RssReader.parseArticles(src, body, 'https://a.com/');
      expect(list.length, 2);
      expect(list.map((a) => a.title), ['甲', '乙']);
      expect(list.first.link, 'https://a.com/1');
    });

    test('裸 key 规则（name / url，不带 \$ 前缀）也要能命中', () {
      // Legado 里 `ruleArticles` 用 `@js:` 返回对象数组时，字段规则常写成
      // **裸 key**（`name` / `url`）—— 用户那份 txt 的「聚合搜索」就是这种。
      // 回归：确认引擎在 JSON 对象上按裸 key 取值。
      const body = '{"data":[{"name":"夸克搜索","url":"https://q.cn"},'
          '{"name":"必应搜索","url":"https://b.cn"}]}';
      const src = RssSource(
        id: 'x',
        name: '聚合搜索',
        url: 'https://www.baidu.com',
        ruleArticles: r'$.data',
        ruleTitle: 'name',
        ruleLink: 'url',
      );
      final list = RssReader.parseArticles(src, body, 'https://www.baidu.com');
      expect(list.length, 2);
      expect(list.map((a) => a.title), ['夸克搜索', '必应搜索']);
      expect(list.first.link, 'https://q.cn');
    });
  });

  group('RssReader.parseArticles —— 标准 RSS / Atom（无规则）', () {
    test('RSS 2.0：title / link / description / enclosure 图片', () {
      const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel>
  <title>站点</title>
  <item>
    <title>文章一</title>
    <link>https://a.com/1</link>
    <description>&lt;p&gt;摘要一&lt;/p&gt;</description>
    <pubDate>Sat, 11 Oct 2025 10:00:00 GMT</pubDate>
    <enclosure url="https://a.com/1.jpg" type="image/jpeg"/>
  </item>
  <item><title>文章二</title><link>https://a.com/2</link></item>
</channel></rss>''';
      const src = RssSource(id: 'x', name: 'S', url: 'https://a.com/feed');
      final list = RssReader.parseArticles(src, xml, 'https://a.com/feed');
      expect(list.length, 2);
      expect(list.first.title, '文章一');
      expect(list.first.link, 'https://a.com/1');
      expect(list.first.image, 'https://a.com/1.jpg');
      expect(list.first.description, '摘要一');
      expect(list.first.pubDate, 'Sat, 11 Oct 2025 10:00:00 GMT');
    });

    test('Atom：<link rel="alternate" href> 取链接', () {
      const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <title>原子一</title>
    <link rel="alternate" href="https://a.com/atom1"/>
    <summary>摘要</summary>
  </entry>
</feed>''';
      const src = RssSource(id: 'x', name: 'S', url: 'https://a.com/atom.xml');
      final list = RssReader.parseArticles(src, xml, 'https://a.com/atom.xml');
      expect(list.length, 1);
      expect(list.first.title, '原子一');
      expect(list.first.link, 'https://a.com/atom1');
    });
  });

  group('分享 / 导出（encodeRssSources）', () {
    test('编码 → parseRssSources 能原样收回（字段不丢）', () {
      const src = RssSource(
        id: 'x',
        name: '少数派',
        url: 'https://sspai.com/',
        group: '内置',
        sortUrl: '全部::https://sspai.com/feed',
        ruleArticles: r'$.data',
        ruleTitle: r'$.title',
        ruleLink: r'$.id',
        enabledCookieJar: false,
      );
      final text = encodeRssSources([src]);
      final back = parseRssSources(text);
      expect(back.length, 1);
      expect(back.first.name, '少数派');
      expect(back.first.url, 'https://sspai.com/');
      expect(back.first.group, '内置');
      expect(back.first.sortUrl, '全部::https://sspai.com/feed');
      expect(back.first.ruleArticles, r'$.data');
      expect(back.first.enabledCookieJar, isFalse);
      expect(back.first.hasRules, isTrue);
    });
  });

  group('Legado 订阅源规范字段（「影视聚合(资源站)」那种形状）', () {
    test('jsLib / style / articleStyle / searchUrl / loginUrl / loginUi 往返不丢', () {
      const s = RssSource(
        id: 'x',
        name: '影视聚合(资源站)',
        url: '<js></js>',
        group: 'ST',
        sortUrl: '<js>\nlet a=1;\n</js>',
        ruleArticles: r'$.list',
        ruleTitle: r'$.vod_name',
        ruleDescription: '<html><body>{{name}}</body></html>',
        jsLib: 'function upLoginData(f){return true;}',
        style: 'h3{text-align:center}',
        articleStyle: 3,
        searchUrl: '<js>1</js>',
        loginUrl: 'function login(){return true;}',
        loginUi: '[{"name":"选择影视源站"}]',
      );
      final back = parseRssSources(encodeRssSources([s])).first;
      expect(back.jsLib, s.jsLib);
      expect(back.style, s.style);
      expect(back.articleStyle, 3);
      expect(back.searchUrl, s.searchUrl);
      expect(back.loginUrl, s.loginUrl);
      expect(back.loginUi, s.loginUi);
      expect(back.ruleDescription, s.ruleDescription);
    });

    test('preload / cacheFirst / showWebLog 与 loginInfo 往返不丢', () {
      const s = RssSource(
        id: 'x',
        name: 'S',
        url: 'https://a.com',
        preload: true,
        cacheFirst: true,
        showWebLog: true,
        loginInfo: '{"选择影视源站":"1-光速资源","调试模式":true}',
      );
      final back = parseRssSources(encodeRssSources([s])).first;
      expect(back.preload, isTrue);
      expect(back.cacheFirst, isTrue);
      expect(back.showWebLog, isTrue);
      expect(back.loginInfo, s.loginInfo);
      // 默认值：没配的源这三个开关都必须是 false（不能变成"默认开"）
      const plain = RssSource(id: 'y', name: 'T', url: 'https://b.com');
      expect(plain.preload, isFalse);
      expect(plain.cacheFirst, isFalse);
      expect(plain.showWebLog, isFalse);
    });
  });

  group('loginUi 表单解析（登录 / 源站设置）', () {
    test('select / toggle / text 三种字段都能解析，含默认值', () {
      const raw = '[{"name":"选择影视源站","type":"select",'
          '"chars":["0-红牛资源","1-光速资源"],"default":"0-红牛资源"},'
          '{"name":"调试模式","type":"toggle","chars":["🔳关闭","✅开启"],'
          '"default":"🔳关闭"},{"name":"账号","type":"text","default":""}]';
      final f = RssLoginField.parse(raw);
      expect(f.length, 3);
      expect(f[0].name, '选择影视源站');
      expect(f[0].isSelect, isTrue);
      expect(f[0].chars, ['0-红牛资源', '1-光速资源']);
      expect(f[0].defaultValue, '0-红牛资源');
      expect(f[1].isToggle, isTrue);
      expect(f[1].chars, ['🔳关闭', '✅开启']);
      expect(f[2].type, 'text');
    });

    test('空 / 非 JSON / 缺 name → 空表（调用方据此隐藏入口）', () {
      expect(RssLoginField.parse('').isEmpty, isTrue);
      expect(RssLoginField.parse('不是 JSON').isEmpty, isTrue);
      expect(RssLoginField.parse('[{"type":"text"}]').isEmpty, isTrue,
          reason: '没有 name 的字段没法填，直接丢');
    });
  });

  group('sortUrl 规则判定', () {
    test('sortUrl 是「规则」还是「静态清单」的判定', () {
      expect(
          const RssSource(id: 'a', name: 'A', url: 'u', sortUrl: '<js>x</js>')
              .sortUrlIsRule,
          isTrue);
      expect(
          const RssSource(id: 'a', name: 'A', url: 'u', sortUrl: r'$.data')
              .sortUrlIsRule,
          isTrue);
      expect(
          const RssSource(id: 'a', name: 'A', url: 'u', sortUrl: '@css:.x')
              .sortUrlIsRule,
          isTrue);
      expect(
          const RssSource(
                  id: 'a',
                  name: 'A',
                  url: 'u',
                  sortUrl: '全部::https://a.com/feed')
              .sortUrlIsRule,
          isFalse,
          reason: '静态清单不能当规则跑');
      expect(const RssSource(id: 'a', name: 'A', url: 'u').sortUrlIsRule, isFalse,
          reason: 'sortUrl 为空不是规则');
    });
  });

  group('内置源播种', () {
    test('内置 3 条，均已启用且有可抓地址', () {
      expect(kBuiltinRssSources.length, 3);
      for (final s in kBuiltinRssSources) {
        expect(s.enabled, isTrue);
        expect(s.url.startsWith('http'), isTrue);
        expect(s.channels, isNotEmpty);
      }
    });

    test('内置源名称不重复（幂等播种的前提）', () {
      final names = kBuiltinRssSources.map((e) => e.name).toList();
      expect(names.toSet().length, names.length);
    });

    test('内置「少数派（规则版）」的分类地址**保留完整 query**', () {
      // 回归：分类分隔符曾按单个 `&` 拆 ⇒ `?offset=…&limit=10&created_at=` 被截断 ✗
      final s = kBuiltinRssSources.firstWhere((e) => e.hasRules);
      expect(s.channels.length, 1);
      expect(s.channels.first.url, contains('&limit=10&created_at='));
    });
  });
}
