// 守卫测试：槽位「归属者」机制（方案 B）。
//
// ── 用户 2026-11-01 ───────────────────────────────────────────
// 「走 B」→「短剧、海阔、RSS 是怎么调用源服务的不管，只是影视模块的」
//
// 也就是说：**只保证影视模块内部是对的**，不碰其它模块的调用方式。
// 因此这里只盯三件事：
//
//   ① 引擎唯一槽位有「归属者」记录（谁要的、对应哪个脚本）；
//   ② 槽位空闲后自动把**影视主源**装回去（回到首页不用再等一次 loadSource）；
//   ③ `currentSpider` 从「全局单值」改成「按归属者分区」——
//      影视模块内部各处（首页/分类/详情）读写同一个 vod 分区，
//      以后再有人从别的模块写，也不会把影视的上下文顶掉。
//
// 默认参数一律是 `ownerVod`，所以**不改任何调用方**，行为对影视模块保持不变。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String relative) => File(relative).readAsStringSync();

String _stripComments(String src) {
  final noBlock = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  return noBlock
      .split('\n')
      .map((line) {
        final i = line.indexOf('//');
        return i < 0 ? line : line.substring(0, i);
      })
      .join('\n');
}

void main() {
  final spider = _stripComments(_read('lib/services/spider_service.dart'));
  final source = _stripComments(_read('lib/services/source_service.dart'));

  group('槽位归属者', () {
    test('四个归属者常量都在，影视是默认', () {
      expect(spider.contains("static const String ownerVod = 'vod';"), isTrue);
      expect(spider.contains("static const String ownerDrama = 'drama';"), isTrue);
      expect(
        spider.contains("static const String ownerMiniApp = 'miniapp';"),
        isTrue,
      );
      expect(
        spider.contains("static const String ownerReading = 'reading';"),
        isTrue,
      );
    });

    test('载入入口默认归属者是影视（不改调用方就不变行为）', () {
      final i = spider.indexOf('Future<String?> _ensureNodeScript(');
      expect(i, greaterThan(0));
      expect(
        spider.substring(i, i + 400).contains('String owner = ownerVod'),
        isTrue,
      );
      final d = spider.indexOf('Future<String?> _ensureDrpyScript(');
      expect(
        spider.substring(d, d + 400).contains('String owner = ownerVod'),
        isTrue,
      );
    });

    test('载入成功才登记归属者（失败/作废不占槽位）', () {
      final i = spider.indexOf('Future<String?> _ensureNodeScript(');
      final seg = spider.substring(i, i + 1200);
      expect(seg.contains('if (k != null) _noteSlotOwner(owner, script);'), isTrue);
      // then 必须带 onError，否则会冒未捕获异步异常
      expect(seg.contains('onError: (Object _) {}'), isTrue);
    });

    test('换源 / 引擎重启要取消空闲归还', () {
      final rc = spider.indexOf('void resetScriptCache()');
      final re = spider.indexOf('void resetEngineMemory()');
      expect(spider.substring(rc, rc + 500).contains('_cancelHandBack()'), isTrue);
      expect(spider.substring(re, re + 500).contains('_cancelHandBack()'), isTrue);
    });

    test('空闲归还只还影视主源，且不动代数', () {
      final i = spider.indexOf('void _noteSlotOwner(');
      expect(i, greaterThan(0));
      final seg = spider.substring(i, i + 1400);
      expect(seg.contains('_kHandBackDelay'), isTrue);
      expect(seg.contains('_ownerScript[ownerVod]'), isTrue);
      expect(seg.contains('owner: ownerVod'), isTrue);
      // 归还只是装回主源，不能作废别人在飞的请求
      expect(
        seg.contains('_sessionGeneration++'),
        isFalse,
        reason: '归还槽位不该改代数，否则会把别人的请求一起作废',
      );
    });
  });

  group('currentSpider 按归属者分区', () {
    test('不再是单个可空变量', () {
      expect(spider.contains('_spiderByOwner'), isTrue);
      expect(
        spider.contains('({String key, int type, String api, String ext})? _currentSpider;'),
        isFalse,
        reason: '单值就是"串"的来源：短剧写一次，影视详情就读到别人的上下文',
      );
    });

    test('读写都带 owner，默认影视', () {
      final setAt = spider.indexOf('void setCurrentSpider(');
      expect(setAt, greaterThan(0));
      expect(
        spider.substring(setAt, setAt + 500).contains('String owner = ownerVod'),
        isTrue,
      );
      final getAt = spider.indexOf('getCurrentSpiderInfo(');
      expect(
        spider.substring(getAt, getAt + 300).contains('String owner = ownerVod'),
        isTrue,
      );
    });

    test('会话失效要清空所有分区', () {
      final i = spider.indexOf('void invalidateSession()');
      expect(
        spider.substring(i, i + 300).contains('_spiderByOwner.clear()'),
        isTrue,
      );
    });
  });

  group('SourceService 透传归属者（默认影视，调用方零改动）', () {
    for (final m in ['getSort', 'getList', 'getDetail', 'search', 'searchAll']) {
      test('$m 有 owner 参数且默认 ownerVod', () {
        final i = source.indexOf(' $m(');
        expect(i, greaterThan(0), reason: '找不到方法 $m');
        expect(
          source.substring(i, i + 400).contains('SpiderService.ownerVod'),
          isTrue,
          reason: '$m 少了默认归属者，影视模块以外的调用会被算到别的分区',
        );
      });
    }

    test('setCurrentSpider / initSpider / getHomeContent 都收到 owner', () {
      expect(source.contains('jar: sourceBean.jar, owner: owner)'), isTrue);
      expect(source.contains('ext: ext, owner: owner)'), isTrue);
      expect(source.contains('owner: owner,'), isTrue);
    });
  });
}
