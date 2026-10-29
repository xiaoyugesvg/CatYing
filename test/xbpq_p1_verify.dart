// test/xbpq_p1_verify.dart
//
// P1 截取引擎自检脚本（不属于正式单测，直接 `dart run` 跑）。
// 覆盖：&& / || / + / Base64 / 修饰符 / JSON 路径 / 规则解析。

import 'dart:convert';

import 'package:tvbox/services/xbpq/xbpq_cut.dart';
import 'package:tvbox/services/xbpq/xbpq_rule.dart';

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
  const src1 = '<a href="https://x.com/1.html">t</a>';

  // ── && 截取 ──
  eq('&& cut', XbpqCut.cutOnce(src1, 'href="&&"'), 'https://x.com/1.html');
  eq('&& start-only', XbpqCut.cutOnce(src1, 'href="&&'),
      'https://x.com/1.html">t</a>');

  // ── || 备选 ──
  eq('|| fallback', XbpqCut.cutOnce(src1, 'nope="&&"||href="&&"'),
      'https://x.com/1.html');

  // ── + 拼接 ──
  eq('+ concat',
      XbpqCut.cutOnce('<a href="/vod/123.html">', 'href="/vod/&&.html+-1-1.html'),
      '123-1-1.html');

  // ── Base64 ──
  const url = 'https://cdn.x/a.m3u8';
  final b64 = base64Encode(utf8.encode(url));
  eq('Base64 bare', XbpqCut.cutOnce(b64, 'Base64'), url);
  eq('Base64 wrapper', XbpqCut.cutOnce('pre${b64}post', 'Base64(pre&&post)'),
      url);

  // ── 修饰符 ──
  eq('[替换]', XbpqCut.cutOnce('abc-123', 'abc-&&[替换:1>>X]'), 'X23');
  eq('[包含] pass', XbpqCut.cutOnce('abc-123', 'abc-&&[包含:2]'), '123');
  eq('[不包含] reject', XbpqCut.cutOnce('abc-123', 'abc-&&[不包含:2]'), '');

  // ── JSON 路径 ──
  const json = '{"data":{"list":[{"name":"A"},{"name":"B"}]}}';
  eq('json j: path', XbpqCut.cutOnce(json, 'j:data.list[1].name'), 'B');
  eq('json dot path', XbpqCut.cutOnce(json, 'data.list[0].name'), 'A');
  eq('json array pick', XbpqCut.cutOnce(json, 'data.list.name'), '["A","B"]');

  // ── 字面量 / 通配符 ──
  eq('literal', XbpqCut.cutOnce('anything', '固定标题'), '固定标题');
  eq('wildcard anchor', XbpqCut.cutOnce('<a href="X.html">', 'href="&&.htm*'), 'X');

  // ── 转义 / 切分 ──
  eq('unescape', XbpqCut.unescape(r'a\$b\#c'), 'a\$b#c');
  eq('splitUnescaped', XbpqCut.splitUnescaped(r'a\&&b&&c', '&&').join('|'),
      r'a\&&b|c');

  // ── 规则解析 ──
  final r1 = XbpqRule.parse(
      '{"主页url":"https://www.abc.com/","分类url":"https://www.abc.com/vodshow/{cateId}/page/{catePg}.html"}');
  eq('rule parsed', r1 != null, true);
  eq('rule homeUrl', r1?.homeUrl, 'https://www.abc.com');
  eq('rule field', r1?.field(['分类url']),
      'https://www.abc.com/vodshow/{cateId}/page/{catePg}.html');

  final r2 = XbpqRule.parse('{"分类url":"https://www.abc.com/vodshow/1.html"}');
  eq('rule derive homeUrl', r2?.homeUrl, 'https://www.abc.com');

  final r3 = XbpqRule.parse('{"主页url":"https://a.com",}');
  eq('rule trailing comma', r3?.homeUrl, 'https://a.com');

  final r4 = XbpqRule.parse(
      '{"主页url":"https://a.com","请求头":"User-Agent: Mozilla/5.0"}');
  eq('userAgent', r4?.userAgent, 'Mozilla/5.0');

  final r5 = XbpqRule.parse('[{"主页url":"https://b.com"}]');
  eq('array form', r5?.homeUrl, 'https://b.com');

  eq('non-xbpq null', XbpqRule.parse('{"foo":"bar"}'), null);

  // ── 工具 ──
  eq('normalizeKey', XbpqRule.normalizeKey(' 分 类 〔x〕 '), '分类[x]');
  eq('trimTrailingComma', XbpqRule.trimTrailingComma('{"a":1,}'), '{"a":1}');

  print('\n==== $_pass passed, $_fail failed ====');
  if (_fail > 0) throw StateError('P1 verification failed');
}
