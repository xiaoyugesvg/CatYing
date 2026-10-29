// test/xbpq_p3_verify.dart
//
// P3 取数层自检脚本（不属于正式单测，直接 `dart run` 跑）。
// 覆盖：URL 渲染/域名重写/空段清洗、链接↔ID、内置模板、
//       分类解析、条目抽取（截取/选择器/JSON）、列表与搜索端到端。
//
// 全部离线：注入假 fetcher，不碰网络。

import 'package:tvbox/services/xbpq/xbpq_cut.dart';
import 'package:tvbox/services/xbpq/xbpq_rule.dart';
import 'package:tvbox/services/xbpq/xbpq_source.dart';
import 'package:tvbox/services/xbpq/xbpq_template.dart';
import 'package:tvbox/services/xbpq/xbpq_url.dart';
import 'package:tvbox/services/xbpq/xbpq_util.dart';

int _pass = 0;
int _fail = 0;

void eq(String name, Object? actual, Object? expected) {
  if (actual == expected) {
    _pass++;
    print('PASS  $name');
  } else {
    _fail++;
    print('FAIL  $name\n      expected: $expected\n      actual  : $actual');
  }
}

void ok(String name, bool condition) => eq(name, condition, true);

const _listHtml = '''
<html><body>
<ul class="myui-vodlist">
  <li><a class="myui-vodlist__thumb" href="/voddetail/101.html" title="剧集一"><img data-original="/img/1.jpg"><span class="pic-text text-right">更新至12集</span></a></li>
  <li><a class="myui-vodlist__thumb" href="/voddetail/102.html" title="剧集二"><img data-original="/img/2.jpg"><span class="pic-text text-right">全24集</span></a></li>
</ul>
</body></html>
''';

/// 一个标准 MacCMS 规则（只写 主页url + 分类url + 分类，其余靠内置模板）。
const _maccmsRule = '{"主页url":"https://demo.test",'
    '"分类url":"https://demo.test/index.php/vod/show/id/{cateId}/page/{catePg}.html",'
    '"分类":"电影\$1#电视剧\$2#1--动作片\$5#喜剧片\$6",'
    '"详情url":"/index.php/vod/detail/id/{id}.html"}';

void main() async {
  // ══════════════════════════════════════════════════════════
  // URL 渲染
  // ══════════════════════════════════════════════════════════
  eq('render fill+absolute',
      XbpqUrl.render('/vod/{id}.html', 'https://a.com', {'id': '7'}),
      'https://a.com/vod/7.html');
  eq('render host rewrite',
      XbpqUrl.render('https://old.com/x/{id}', 'https://new.com', {'id': '1'}),
      'https://new.com/x/1');
  // `//host` 先补 https，再被域名重写拉回站源域名 —— 与 Go 行为一致
  // （重写规则对请求模板无条件生效）。
  eq('render protocol relative',
      XbpqUrl.render('//cdn.com/a.js', 'https://a.com', {}),
      'https://a.com/a.js');
  eq('render strip comment',
      XbpqUrl.render('https://a.com/x;;作者注释', 'https://a.com', {}),
      'https://a.com/x');
  // 无 host 的绝对地址直接判无效。
  eq('render empty host', XbpqUrl.render('https:///x', 'https://a.com', {}), '');

  // ── 链接转绝对 ──
  // `href=` 只剥前缀，不剥引号（Go 同款）；真实链路里 pattern `href="&&"`
  // 抽出来的值本来就不带引号。
  eq('joinLink href=',
      XbpqUrl.joinLink('https://a.com/d/1.html', 'href=/vod/2.html'),
      'https://a.com/vod/2.html');
  eq('joinLink plus literals',
      XbpqUrl.joinLink('https://a.com/d/1.html', '"/vod/"+"3"+".html"'),
      'https://a.com/vod/3.html');
  eq('joinLink reject json', XbpqUrl.joinLink('https://a.com/', r'$.vod_id'), '');
  eq('joinLink empty', XbpqUrl.joinLink('https://a.com/', '  '), '');

  // ── 链接 ↔ ID ──
  eq('idFromLink path', XbpqUrl.idFromLink('https://a.com/voddetail/101.html', true),
      '101');
  eq('idFromLink glued', XbpqUrl.idFromLink('https://a.com/vod101.html', true),
      '101');
  eq('idFromLink fallback numeric off',
      XbpqUrl.idFromLink('https://a.com/voddetail/101.html', false),
      'uhttps%3A%2F%2Fa.com%2Fvoddetail%2F101.html');
  final opaque = XbpqUrl.idFromLink('https://a.com/drama/xyz.html', false);
  eq('linkFromId round trip', XbpqUrl.linkFromId(opaque),
      'https://a.com/drama/xyz.html');
  eq('linkFromId reject numeric', XbpqUrl.linkFromId('101'), '');

  // ── 空筛选段清洗 ──
  eq('clean path segment',
      XbpqUrl.cleanEmptySegments('https://a.com/vodshow/1/area//id/2.html'),
      'https://a.com/vodshow/1/id/2.html');
  eq('clean tail segment',
      XbpqUrl.cleanEmptySegments('https://a.com/vodshow/1/year/.html'),
      'https://a.com/vodshow/1.html');
  eq('clean query',
      XbpqUrl.cleanEmptySegments('https://a.com/s?wd=x&area=&year='),
      'https://a.com/s?wd=x');
  eq('clean query keep braces',
      XbpqUrl.cleanEmptySegments('https://a.com/s?wd={wd}&area='),
      'https://a.com/s?wd={wd}');

  // ══════════════════════════════════════════════════════════
  // 内置模板
  // ══════════════════════════════════════════════════════════
  final rule = XbpqRule.parse(_maccmsRule)!;
  ok('template filled 数组', rule.field(['数组']).isNotEmpty);
  ok('template filled 播放数组', rule.field(['播放数组']).isNotEmpty);
  eq('template 搜索url {host}',
      rule.field(['搜索url']), 'https://demo.test/index.php/vod/search.html?wd={wd}');
  eq('template 详情url kept',
      rule.field(['详情url']), '/index.php/vod/detail/id/{id}.html');
  eq('template marked', rule.fields['模板已套用'], '1');

  final fields = <String, String>{'分类url': 'https://a.com/vodshow/1.html',
    '标题': '自定义标题pattern'};
  final order = <String>['分类url', '标题'];
  XbpqTemplate.apply(fields, order);
  eq('template no overwrite', fields['标题'], '自定义标题pattern');
  ok('template added 链接', (fields['链接'] ?? '').isNotEmpty);
  final orderLength = order.length;
  XbpqTemplate.apply(fields, order);
  eq('template idempotent', order.length, orderLength);

  // ══════════════════════════════════════════════════════════
  // 分类
  // ══════════════════════════════════════════════════════════
  final categories = XbpqSource.categories(rule);
  eq('categories count', categories.length, 4);
  eq('categories first', '${categories[0]['type_id']}/${categories[0]['type_name']}',
      '1/电影');
  eq('categories sub', '${categories[3]['type_id']}/${categories[3]['type_name']}',
      '5/动作片');

  eq('categoryUrl paging',
      XbpqSource.categoryUrl(rule, 'https://demo.test', '2', 3),
      'https://demo.test/index.php/vod/show/id/2/page/3.html');

  // ══════════════════════════════════════════════════════════
  // 条目抽取（截取模式）
  // ══════════════════════════════════════════════════════════
  final source = XbpqSource(
    fetcher: (raw, referer, agent) async => _listHtml,
  );

  final items = await source.extractItems(
      rule, 'https://demo.test', 'https://demo.test/index.php/vod/show/id/1/page/1.html', '列表');
  eq('extractItems count', items.length, 2);
  eq('item title', XbpqSource.cleanText(XbpqSource.itemField(items[0], 'title="&&"')),
      '剧集一');
  eq('item link', XbpqSource.itemField(items[0], 'href="&&"'),
      '/voddetail/101.html');
  eq('item remark',
      XbpqSource.cleanText(
          XbpqSource.itemField(items[0], 'pic-text text-right">&&</span>')),
      '更新至12集');

  // ══════════════════════════════════════════════════════════
  // 列表端到端
  // ══════════════════════════════════════════════════════════
  final content = await source.categoryContent(
    rule: rule,
    base: 'https://demo.test',
    category: '1',
    page: 1,
  );
  final list = (content['list'] as List).cast<Map<String, dynamic>>();
  eq('list count', list.length, 2);
  eq('list name', list[0]['vod_name'], '剧集一');
  eq('list id numeric', list[0]['vod_id'], '101');
  eq('list pic absolute', list[0]['vod_pic'], 'https://demo.test/img/1.jpg');
  eq('list remark', list[0]['vod_remarks'], '更新至12集');
  eq('list page', content['page'], 1);
  eq('list second name', list[1]['vod_name'], '剧集二');

  // ── 空分类取第一个分类 ──
  final auto = await source.categoryContent(
      rule: rule, base: 'https://demo.test', page: 1);
  eq('auto category', (auto['list'] as List).length, 2);

  // ══════════════════════════════════════════════════════════
  // 搜索（含 POST 规格）
  // ══════════════════════════════════════════════════════════
  String? lastSpec;
  final searchSource = XbpqSource(fetcher: (raw, referer, agent) async {
    lastSpec = raw;
    return _listHtml;
  });

  final searched = await searchSource.search(
      rule: rule, base: 'https://demo.test', query: '剧');
  final hits = (searched['list'] as List).cast<Map<String, dynamic>>();
  eq('search count', hits.length, 2);
  eq('search name', hits[0]['vod_name'], '剧集一');
  eq('search spec encoded', lastSpec,
      'https://demo.test/index.php/vod/search.html?wd=%E5%89%A7');

  // POST 形态
  final postRule = XbpqRule.parse('{"主页url":"https://p.test",'
      '"分类url":"https://p.test/list/1.html",'
      '"搜索url":"https://p.test/api/search;post;wd={wd}"}')!;
  String? postSpec;
  final postSource = XbpqSource(fetcher: (raw, referer, agent) async {
    postSpec = raw;
    return _listHtml;
  });
  await postSource.search(rule: postRule, base: 'https://p.test', query: '剧');
  eq('search post spec', postSpec,
      'https://p.test/api/search;POST;wd=%E5%89%A7');

  // ══════════════════════════════════════════════════════════
  // 条目抽取（选择器模式）
  // ══════════════════════════════════════════════════════════
  const selectorHtml = '<html><body>'
      '<div class="item"><a href="/d/1.html"><span class="n">甲</span></a></div>'
      '<div class="item"><a href="/d/2.html"><span class="n">乙</span></a></div>'
      '</body></html>';
  final selectorRule = XbpqRule.parse('{"主页url":"https://s.test",'
      '"分类url":"https://s.test/index.php/vod/show/id/{cateId}.html",'
      '"数组":"p:.item","标题":"p:.n","链接":"p:a[href]"}')!;
  final selectorSource =
      XbpqSource(fetcher: (raw, referer, agent) async => selectorHtml);
  final nodes = await selectorSource.extractItems(
      selectorRule, 'https://s.test', 'https://s.test/index.php/vod/show/id/1.html', '列表');
  eq('selector items', nodes.length, 2);
  ok('selector item has node', nodes[0].node != null);
  eq('selector title', XbpqSource.itemField(nodes[0], 'p:.n'), '甲');
  eq('selector href', XbpqSource.itemField(nodes[0], 'p:a[href]'), '/d/1.html');
  final selectorContent = await selectorSource.categoryContent(
      rule: selectorRule, base: 'https://s.test', category: '1');
  final selectorList =
      (selectorContent['list'] as List).cast<Map<String, dynamic>>();
  eq('selector list name', selectorList[0]['vod_name'], '甲');
  eq('selector list link absolute', selectorList[0]['vod_pic'], '');
  ok('selector list opaque id',
      (selectorList[0]['vod_id'] as String).startsWith('u'));

  // ══════════════════════════════════════════════════════════
  // 条目抽取（JSON 模式）
  // ══════════════════════════════════════════════════════════
  const jsonHtml = '<html><body><script>var d = '
      '[{"vod_name":"丙","vod_id":9},{"vod_name":"丁","vod_id":10}];</script>'
      '</body></html>';
  final jsonRule = XbpqRule.parse('{"主页url":"https://j.test",'
      '"分类url":"https://j.test/api/list?page={catePg}"}')!;
  final jsonSource =
      XbpqSource(fetcher: (raw, referer, agent) async => jsonHtml);
  final jsonItems = await jsonSource.extractItems(
      jsonRule, 'https://j.test', 'https://j.test/api/list?page=1', '');
  eq('json fallback items', jsonItems.length, 2);
  ok('json item is json', jsonItems[0].text.contains('vod_name'));
  eq('json field title',
      XbpqSource.itemField(jsonItems[0], '"vod_name":"&&"'), '丙');
  eq('json field number',
      XbpqSource.itemField(jsonItems[0], '"vod_id":"&&"'), '9');

  // ══════════════════════════════════════════════════════════
  // 错误路径
  // ══════════════════════════════════════════════════════════
  final noCategoryUrl = XbpqRule.parse('{"主页url":"https://n.test"}')!;
  String? error;
  try {
    await source.categoryContent(rule: noCategoryUrl, base: 'https://n.test');
  } on XbpqException catch (e) {
    error = e.message;
  }
  eq('missing 分类url', error, '规则缺少分类url');

  final mismatchRule = XbpqRule.parse('{"主页url":"https://m.test",'
      '"分类url":"https://m.test/index.php/vod/show/id/{cateId}.html",'
      '"数组":"<div class=\\"nope\\"&&</div>"}')!;
  final emptySource = XbpqSource(
      fetcher: (raw, referer, agent) async => '<html><body><p>x</p></body></html>');
  String? mismatchError;
  try {
    await emptySource.categoryContent(
        rule: mismatchRule, base: 'https://m.test', category: '1');
  } on XbpqException catch (e) {
    mismatchError = e.message;
  }
  ok('mismatch hint mentions 数组', (mismatchError ?? '').contains('数组'));

  String? fetchError;
  final brokenSource =
      XbpqSource(fetcher: (raw, referer, agent) async {
    throw const XbpqException('HTTP 403');
  });
  try {
    await brokenSource.categoryContent(
        rule: rule, base: 'https://demo.test', category: '1');
  } on XbpqException catch (e) {
    fetchError = e.message;
  }
  ok('fetch error surfaced', (fetchError ?? '').contains('HTTP 403'));

  // ══════════════════════════════════════════════════════════
  // 多段截取 / JSON 工具
  // ══════════════════════════════════════════════════════════
  eq('cut list count',
      XbpqCut.list('<li>a</li><li>b</li><li>c</li>', '<li&&</li>').join(','),
      '>a,>b,>c');
  eq('cut list order',
      XbpqCut.list('<li>线路B</li><li>线路A</li>', '<li&&</li>[排序:A>B]').join(','),
      '>线路A,>线路B');
  eq('cut list no match', XbpqCut.list('<p>x</p>', '<li&&</li>').length, 0);

  const jsonDoc = '{"data":{"list":[{"a":1},{"a":2}],"name":"n"}}';
  eq('jsonArrayItems count', XbpqCut.jsonArrayItems(jsonDoc, 'j:data.list').length, 2);
  eq('jsonPathRaw object', XbpqCut.jsonPathRaw(jsonDoc, 'j:data'),
      '{"list":[{"a":1},{"a":2}],"name":"n"}');
  eq('jsonPathRaw missing', XbpqCut.jsonPathRaw(jsonDoc, 'j:nope'), '');

  // ── 规格解析 ──
  final getSpec = XbpqUrl.splitSpec('https://a.com/x');
  eq('splitSpec get', '${getSpec.address}|${getSpec.method}', 'https://a.com/x|');
  final postSpec2 = XbpqUrl.splitSpec('https://a.com/x;post;a=1;b=2');
  eq('splitSpec post', '${postSpec2.address}|${postSpec2.method}|${postSpec2.body}',
      'https://a.com/x|POST|a=1;b=2');
  eq('composeSpec', XbpqUrl.composeSpec('https://a.com/x', 'POST', 'a=1'),
      'https://a.com/x;POST;a=1');

  print('\n==== $_pass passed, $_fail failed ====');
  if (_fail > 0) throw StateError('P3 verification failed');
}
