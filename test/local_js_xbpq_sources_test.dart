import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/models/import_conflict.dart';
import 'package:tvbox/services/local_js_sources.dart';
import 'package:tvbox/services/xbpq/xbpq_service.dart';

/// 本地 JS 源 / XBPQ 规则源的**存储与校验**回归。
///
/// 2026-10-29：用户要求「本地JS 管理要和本地爬虫一样」「XBPQ 的导入、开关
/// 也要和本地爬虫一样」。三族共用同一套页面与交互，背后的存储各自独立 ——
/// 这个文件守住最容易回归的两件事：
///   ① 导入时的"这是不是影视源"判定（拦掉独立服务型脚本、垃圾文本）；
///   ② XBPQ 的同名覆盖 / 改名 / 删除 / 重排（页面依赖这些语义）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('本地 JS 源：导入前的形态判定', () {
    test('drpy2 / TVBox 的 var rule = {...} 放行', () {
      expect(
        whyNotJsVideoSource('''
var rule = {
  title: '测试源',
  home: async function () { return []; },
};
export default rule;
'''),
        isNull,
      );
    });

    test('class Spider 放行', () {
      expect(
        whyNotJsVideoSource('''
class Spider {
  async homeContent(filter) { return { list: [] }; }
}
'''),
        isNull,
      );
    });

    test('homeContent 入口放行（catvod 风格）', () {
      expect(
        whyNotJsVideoSource(
          'function homeContent(){ return {class:[],list:[]} }',
        ),
        isNull,
      );
    });

    test('独立服务型脚本被拦下，并说明原因', () {
      final why = whyNotJsVideoSource(
        "const http = require('http');\nhttp.createServer((q,s)=>s.end()).listen(8080);",
      );
      expect(why, isNotNull);
      expect(why, contains('独立服务型'));
    });

    test('既没有 rule 也没有入口函数的文本被拦下', () {
      final why = whyNotJsVideoSource('console.log("hello");');
      expect(why, isNotNull);
      expect(why, contains('不是影视源脚本'));
    });
  });

  group('XBPQ：导入 / 覆盖 / 改名 / 删除 / 重排', () {
    const ruleA = '{"主页url":"https://a.example.com/",'
        '"分类url":"https://a.example.com/vodshow/{cateId}/page/{catePg}.html"}';
    const ruleB = '{"主页url":"https://b.example.com/",'
        '"分类url":"https://b.example.com/vodshow/{cateId}/page/{catePg}.html"}';

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await XbpqService.instance.ensureLoaded(force: true);
      await XbpqService.instance.clearAll();
    });

    test('非法规则被拒绝，且不写进清单', () async {
      final r = await XbpqService.instance
          .importCode('这不是 JSON 规则', displayName: '坏规则');
      expect(r.ok, isFalse);
      expect(XbpqService.instance.sources, isEmpty);
    });

    test('合法规则导入成功并带导入时间', () async {
      final r = await XbpqService.instance
          .importCode(ruleA, displayName: '站点 A');
      expect(r.ok, isTrue);
      final list = XbpqService.instance.sources;
      expect(list.length, 1);
      expect(list.first.name, '站点 A');
      expect(list.first.addedAt, greaterThan(0));
      // key 必须带前缀，源面板靠它分组
      expect(list.first.key, startsWith('localxbpq_'));
    });

    test('同名覆盖沿用旧 key（用户视角是"规则更新了"）', () async {
      final first = await XbpqService.instance
          .importCode(ruleA, displayName: '站点 A');
      final oldKey = first.source!.key;
      final second = await XbpqService.instance.importCode(
        ruleB,
        displayName: '站点 A',
        conflict: ImportConflict.replace,
      );
      expect(second.ok, isTrue);
      final list = XbpqService.instance.sources;
      expect(list.length, 1, reason: '同名覆盖不应产生第二条');
      expect(list.first.key, oldKey, reason: '覆盖必须沿用旧 key');
      expect(list.first.ruleText, contains('b.example.com'));
    });

    test('不同名导入产生两条，且可改名 / 删除', () async {
      await XbpqService.instance.importCode(ruleA, displayName: 'A');
      await XbpqService.instance.importCode(ruleB, displayName: 'B');
      expect(XbpqService.instance.sources.length, 2);

      final keyA = XbpqService.instance.sources
          .firstWhere((e) => e.name == 'A')
          .key;
      final renamed = await XbpqService.instance.rename(keyA, 'A 改名');
      expect(renamed.ok, isTrue);
      expect(
        XbpqService.instance.sources.any((e) => e.name == 'A 改名'),
        isTrue,
      );

      final removed = await XbpqService.instance.remove(keyA);
      expect(removed.ok, isTrue);
      expect(XbpqService.instance.sources.length, 1);
    });

    test('按给定顺序重排', () async {
      await XbpqService.instance.importCode(ruleA, displayName: 'A');
      await XbpqService.instance.importCode(ruleB, displayName: 'B');
      final keys = XbpqService.instance.sources.map((e) => e.key).toList();
      // 反过来排
      await XbpqService.instance
          .reorderWithin(keys.reversed.toList(growable: false));
      expect(
        XbpqService.instance.sources.map((e) => e.name).toList(),
        ['B', 'A'],
      );
    });
  });
}
