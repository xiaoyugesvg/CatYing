import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/reading/novel_source/analyze/analyze_rule.dart';
import 'package:tvbox/reading/novel_source/analyze/js_engine.dart';
import 'package:tvbox/reading/novel_source/analyze/source_rate_limiter.dart';
import 'package:tvbox/reading/novel_source/model/book_source.dart';
import 'package:tvbox/reading/novel_source/model/xiaoshuo_book.dart';
import 'package:tvbox/reading/novel_source/web_book/book_info.dart';
import 'package:tvbox/reading/models/book_source.dart' as reader;

/// 书源引擎对齐 Legado 官方文档（dev/source-fields、dev/rule）的回归测试。
///
/// 覆盖三处此前与官方语义不一致的地方：
///   1. `ruleBookInfo.init` 返回 JSON 对象后，字段用 key（a/b/…）取值；
///   2. `canReName` **非空**才允许用详情页书名/作者覆盖（官方 BookInfo.kt）；
///   3. `concurrentRate` 的 `N` / `N/M` 两种限流格式。
void main() {
  XiaoshuoBookSource makeSource({String? canReName, String? init}) {
    return XiaoshuoBookSource.fromJson({
      'bookSourceUrl': 'https://example.com',
      'bookSourceName': '测试源',
      'ruleBookInfo': {
        if (init != null) 'init': init,
        'name': 'h1&&Text',
        if (canReName != null) 'canReName': canReName,
      },
    });
  }

  XiaoshuoBook makeBook() => XiaoshuoBook(
    bookUrl: 'https://example.com/book/1',
    name: '搜索页书名',
    author: '搜索页作者',
  );

  group('bookInfoInit 返回 JSON 对象（官方 a/b/c… key 约定）', () {
    test('Map 内容下，普通规则按 JSON key 取值', () {
      final ar = AnalyzeRule()
        ..setContent(<String, dynamic>{'a': '书名X', 'b': '作者Y'});
      expect(ar.getString('a'), '书名X');
      expect(ar.getString('b'), '作者Y');
      expect(ar.getString('c'), '');
    });

    test('JSON 字符串内容同样按 key 取值', () {
      final ar = AnalyzeRule()..setContent('{"a":"书名X"}');
      expect(ar.getString('a'), '书名X');
    });

    test('init 是 @js 且返回对象时，getElement 必须把对象交给 setContent', () {
      // 缺 quickjs 原生库时跳过（避免变成脆弱测试）
      String probe;
      try {
        probe = JsEngine.shared.eval('1+1');
      } catch (_) {
        return;
      }
      if (probe != '2') return;

      final ar = AnalyzeRule()..setContent('<html><body>raw</body></html>');
      final init = ar.getElement('@js:return {a:"书名X", b:"作者Y"}');
      ar.setContent(init);
      expect(ar.getString('a'), '书名X');
      expect(ar.getString('b'), '作者Y');
    });
  });

  group('canReName（官方：字段非空才允许覆盖）', () {
    test('canReName 非空 ⇒ 用详情页书名/作者覆盖', () {
      final book = makeBook();
      BookInfo.analyzeBookInfo(
        bookSource: makeSource(canReName: 'true'),
        book: book,
        baseUrl: 'https://example.com/book/1',
        redirectUrl: null,
        body: '<h1>详情页书名</h1>',
      );
      expect(book.name, '详情页书名');
    });

    test('canReName 为空 ⇒ 保留搜索页书名', () {
      final book = makeBook();
      BookInfo.analyzeBookInfo(
        bookSource: makeSource(),
        book: book,
        baseUrl: 'https://example.com/book/1',
        redirectUrl: null,
        body: '<h1>详情页书名</h1>',
      );
      expect(book.name, '搜索页书名');
    });
  });

  group('concurrentRate 解析与限流', () {
    test('两种官方格式 + 非法值', () {
      expect(SourceRateLimiter.debugDescribe('1000'), 'interval:1000');
      expect(SourceRateLimiter.debugDescribe('20/60000'), 'window:20/60000');
      expect(SourceRateLimiter.debugDescribe(' 800 '), 'interval:800');
      expect(SourceRateLimiter.debugDescribe(''), 'none');
      expect(SourceRateLimiter.debugDescribe(null), 'none');
      expect(SourceRateLimiter.debugDescribe('abc'), 'none');
      expect(SourceRateLimiter.debugDescribe('0'), 'none');
    });

    test('N：两次请求至少间隔 N 毫秒', () async {
      final sw = Stopwatch()..start();
      await SourceRateLimiter.instance.acquire('test:interval', '80');
      await SourceRateLimiter.instance.acquire('test:interval', '80');
      sw.stop();
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(60));
    });

    test('N/M：窗口内超过 N 次会等待', () async {
      final sw = Stopwatch()..start();
      await SourceRateLimiter.instance.acquire('test:window', '2/150');
      await SourceRateLimiter.instance.acquire('test:window', '2/150');
      await SourceRateLimiter.instance.acquire('test:window', '2/150');
      sw.stop();
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(120));
    });

    test('不同源分桶，互不影响', () async {
      final sw = Stopwatch()..start();
      await SourceRateLimiter.instance.acquire('test:a', '200');
      await SourceRateLimiter.instance.acquire('test:b', '200');
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(180));
    });
  });

  group('书源类型归一化（阅读器按 type == 2 走漫画模式）', () {
    reader.BookSource src(Object type) => reader.BookSource.fromJson({
      'bookSourceName': '看漫画',
      'bookSourceUrl': 'https://m.manhuagui.com',
      'bookSourceType': type,
    })!;

    test('中文「漫画」→ 2（不归一化会按文字渲染 = 整章空白）', () {
      expect(src('漫画').type, '2');
    });

    test('数字字符串与其它中文类型', () {
      expect(src('2').type, '2');
      expect(src(2).type, '2');
      expect(src('小说').type, '0');
      expect(src('有声').type, '1');
      expect(src('文件').type, '3');
    });
  });
}
