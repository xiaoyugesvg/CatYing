// test/xbpq_p2_verify.dart
//
// P2 选择器自检脚本（不属于正式单测，直接 `dart run` 跑）。
// 覆盖：p: / jsoup: 前缀、标签/类/id、属性匹配与取值、
//       后代与 `>`、祖先链、包含/不包含修饰符、文本折叠、script 排除。

import 'package:tvbox/services/xbpq/xbpq_selector.dart';

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

void main() {
  const listPage = '''
<html><head><title>t</title>
<style>.x{color:red}</style>
<script>var a = "<span>js</span>";</script>
</head><body>
<div id="main" class="wrap">
  <ul class="list">
    <li class="item" data-id="7"><a href="/vod/7.html"><span>剧集七</span> 高清</a></li>
    <li class="item ad" data-id="8"><a href="/vod/8.html">广告位</a></li>
    <li class="item" data-id="9"><a href="/vod/9.html">剧集九</a></li>
  </ul>
  <div class="title">热门推荐</div>
</div>
</body></html>
''';

  // ── 基础：标签 / 类 / id ──
  eq('class selector', XbpqSelector.firstString(listPage, 'p:.title'), '热门推荐');
  eq('tag+class', XbpqSelector.firstString(listPage, 'p:div.title'), '热门推荐');
  eq('id selector', XbpqSelector.firstString(listPage, 'p:#main .title'), '热门推荐');
  eq('tag only', XbpqSelector.firstString(listPage, 'p:title'), 't');

  // ── 后代：空格 与 `>` 等价 ──
  eq('descendant space',
      XbpqSelector.firstString(listPage, 'p:.list .item a'), '剧集七 高清');
  eq('descendant gt',
      XbpqSelector.firstString(listPage, 'p:.list > .item > a'), '剧集七 高清');

  // ── 属性：匹配 vs 取值 ──
  eq('attr extract', XbpqSelector.firstString(listPage, 'p:.list a[href]'),
      '/vod/7.html');
  eq('attr equals', XbpqSelector.firstString(listPage, 'p:li[data-id=9] a'),
      '剧集九');
  eq('attr exists', XbpqSelector.firstString(listPage, 'p:li[data-id] a'), '剧集七 高清');
  eq('attr value pick', XbpqSelector.firstString(listPage, 'p:li[data-id=8][href]'),
      ''); // li 没有 href → 空串

  // ── 修饰符（只能挂在选择器**末尾**，Go 也只从尾部剥） ──
  eq('contains', XbpqSelector.firstString(listPage, 'p:.item[包含:高清]'),
      '剧集七 高清');
  eq('contains on target',
      XbpqSelector.firstString(listPage, 'p:.item a[包含:高清]'), '剧集七 高清');
  eq('not contains',
      XbpqSelector.firstString(listPage, 'p:.item[不包含:广告,高清]'), '剧集九');
  eq('contains no match', XbpqSelector.firstString(listPage, 'p:.item[包含:不存在]'),
      '');
  // 非末尾的 `[...]` 不会被当修饰符（会被解析成属性名）——与 Go 行为一致。
  eq('modifier must be trailing',
      XbpqSelector.firstString(listPage, 'p:.item[不包含:广告,高清] a'),
      '剧集七 高清');

  // ── 文本折叠 / script 排除 ──
  eq('text collapse',
      XbpqSelector.firstString('<div><span>a</span><span>b</span></div>', 'p:div'),
      'a b');
  eq('text skip script',
      XbpqSelector.firstString(
          '<div>a<script>bad()</script><style>.c{}</style>b</div>', 'p:div'),
      'a b');

  // ── jsoup: 前缀等价 ──
  eq('jsoup prefix', XbpqSelector.firstString(listPage, 'jsoup:.title'), '热门推荐');

  // ── 多结果 ──
  eq('strings count', XbpqSelector.strings(listPage, 'p:.item').length, 3);
  eq('strings attr all',
      XbpqSelector.strings(listPage, 'p:.list a[href]').join(','),
      '/vod/7.html,/vod/8.html,/vod/9.html');

  // ── 文档顺序 ──
  eq('document order', XbpqSelector.strings(listPage, 'p:.item').first, '剧集七 高清');

  // ── 异常 / 边界 ──
  eq('non selector', XbpqSelector.firstString(listPage, 'class="title"&&"'), '');
  eq('unclosed bracket', XbpqSelector.firstString(listPage, 'p:a[href'), '');
  eq('no match', XbpqSelector.firstString(listPage, 'p:.nothing'), '');
  eq('empty source', XbpqSelector.firstString('', 'p:div'), '');

  // ── parse / selectNodes 直调（P3 会这样用） ──
  final spec = XbpqSelector.parse('p:.list .item');
  eq('parse ok', spec != null, true);
  eq('parse ancestors', spec?.ancestors.length, 1);
  eq('parse target tag', spec?.target.tag, '');
  eq('parse target class', spec?.target.classes.first, 'item');
  final doc = XbpqSelector.parseDocument(listPage);
  eq('selectNodes count', XbpqSelector.selectNodes(doc, spec!).length, 3);

  // ── within：条目内查询（P3 的 item 作用域） ──
  final items = XbpqSelector.selectNodes(doc, spec);
  final inner = XbpqSelector.parse('p:a[href]')!;
  final hits = XbpqSelector.selectNodes(items.first, inner)
      .where((n) => XbpqSelector.within(n, items.first))
      .toList();
  eq('within scoped', hits.length, 1);
  eq('within value', XbpqSelector.valueOf(hits.first, inner), '/vod/7.html');

  print('\n==== $_pass passed, $_fail failed ====');
}
