import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/services/local_js_sources.dart';

/// 「本地 JS 源」导入前校验（whyNotJsSource）的纯逻辑回归。
///
/// 2026-10-27 事故：用户导入「官方聚合.js」（正常 CatVodOpen 源）被误判成
/// HTML 网页 —— 因为源里有一行
/// `/<!doctype html|<html\b|<head\b/i.test(body)` 用来判断响应是不是网页，
/// 旧逻辑「全文出现 `<html` 就判 HTML」把它直接误杀了。
void main() {
  group('whyNotJsSource —— 不误杀字符串里含 HTML 的正常源', () {
    test('正则里含 <html / <!doctype 的 CatVodOpen 源应放行', () {
      const agg = r'''
// 五大平台点播聚合源。
import { createHash, randomUUID } from 'node:crypto';
const isHtml = (body) =>
  /<!doctype html|<html\b|<head\b|<body\b|<iframe\b|<script\b/i.test(body);
export function createSpider(name, config) {
  return { name, config, start() {} };
}
''';
      expect(whyNotJsSource(agg), isNull,
          reason: '入口/导出特征优先，字符串里的 HTML 标记不应判成网页');
    });

    test('CJS module.exports 源放行', () {
      expect(
          whyNotJsSource(
              'module.exports = { homeContent(){}, searchContent(){} };'),
          isNull);
    });

    test('drpy 风格 function homeContent() 放行', () {
      expect(whyNotJsSource('function homeContent(){ return {}; }'), isNull);
    });

    test('ESM export default 放行', () {
      expect(whyNotJsSource('export default { start(){} };'), isNull);
    });

    test('CatVodOpen createSpider 放行', () {
      expect(whyNotJsSource('const s = createSpider("x", {});'), isNull);
    });
  });

  group('whyNotJsSource —— 真正的错误页 / 空内容仍要挡', () {
    test('以 <!DOCTYPE html> 开头的错误页应拒绝', () {
      const html = '<!DOCTYPE html>\n<html><head><title>404</title></head>'
          '<body>Not Found</body></html>';
      expect(whyNotJsSource(html), isNotNull);
    });

    test('以 <html 开头的错误页应拒绝', () {
      expect(whyNotJsSource('<html><body>blocked</body></html>'), isNotNull);
    });

    test('空内容 / 纯文本应拒绝', () {
      expect(whyNotJsSource(''), isNotNull);
      expect(whyNotJsSource('   \n  '), isNotNull);
      expect(whyNotJsSource('hello world, not a script'), isNotNull);
    });
  });
}
