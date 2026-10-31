// 守卫测试：换源必须是「切一个就是一个引擎」，不许几个源抢同一个槽位。
//
// ── 用户原话（2026-11-01）──────────────────────────────────────
// 「我不是要所有的分类都同时用，切换一个就切换一个 node 引擎呢，
//   不要它们的串呢？」
//
// ── 事实澄清 ──────────────────────────────────────────────────
// 引擎**本来就是单槽位**：一个 Node 进程、一份 `sourceModule`，
// 「一个源一个引擎」物理上早就成立。串的不是引擎数量，是**写者**：
//
//   ① `setCurrentSpider` 是全局可变单槽，首页/分类/详情/短剧/海阔 五处都在写，
//      谁最后调谁赢，在飞请求带的是别人的 key；
//   ② `app_state._fetchSpiderConfig` 在 `/config` 回来后**无条件**用
//      `sourceBeanList.first` 覆盖 currentSpider —— 日志里的
//      `setCurrentSpider: key=official_aggregate` 就是它，把用户选的本地 JS 顶掉；
//   ③ `_ensureNodeScript` 的并发保护是**按脚本地址分桶**的，
//      不同脚本之间没有全局互斥 ⇒ A 正在 loadSource 时 B 也能 loadSource，
//      引擎里后写的把先写的顶掉。
//
// 这条测试盯着修好的三件事别再被改回去：
//   · 全局写锁 `_loadQueue` / `_enqueueLoad`（写者串行）
//   · 换源代数 `_sessionGeneration`（排队期间换源 ⇒ 过期载入作废）
//   · `/config` 之后用**用户选的源**而不是列表第一条
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String relative) => File(relative).readAsStringSync();

/// 去掉注释，避免"注释里写了关键字"把断言骗过去。
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
  final appState = _stripComments(_read('lib/services/app_state.dart'));

  group('引擎单槽位必须有全局写锁', () {
    test('_loadQueue 存在且是 Future 链', () {
      expect(spider.contains('Future<void> _loadQueue'), isTrue);
    });

    test('_enqueueLoad 把任务串起来（前一个跑完才轮到下一个）', () {
      expect(spider.contains('Future<T> _enqueueLoad<T>('), isTrue);
      expect(spider.contains('final prev = _loadQueue;'), isTrue);
      expect(spider.contains('.then((_) => job())'), isTrue);
      // 失败也要放行，否则一次异常会把整条队列永久卡死
      expect(spider.contains('.catchError((Object _) {})'), isTrue);
    });

    test('Node 脚本载入要进队列', () {
      final i = spider.indexOf('Future<String?> _ensureNodeScript(');
      expect(i, greaterThan(0));
      final seg = spider.substring(i, i + 1400);
      expect(seg.contains('_enqueueLoad('), isTrue);
      expect(seg.contains('_ensureNodeScriptInner('), isTrue);
    });

    test('drpy 载入也要进同一把锁（它也写同一个槽位）', () {
      final i = spider.indexOf('Future<String?> _ensureDrpyScript(');
      expect(i, greaterThan(0));
      final seg = spider.substring(i, i + 1200);
      expect(seg.contains('_enqueueLoad('), isTrue);
      expect(seg.contains('_ensureDrpyScriptInner('), isTrue);
    });

    test('主源载入（loadSourceSmart）不许绕过队列', () {
      final i = spider.indexOf('Future<(bool, String?)> loadSourceSmart(');
      expect(i, greaterThan(0));
      final seg = spider.substring(i, i + 800);
      expect(seg.contains('_enqueueLoad('), isTrue);
      expect(
        seg.contains('return NodeJSManager.instance.loadSource(api);'),
        isFalse,
        reason: '直接 return loadSource 等于绕过写锁，会和其它载入同时写槽位',
      );
    });
  });

  group('换源代数：排队期间换源，过期载入必须作废', () {
    test('_sessionGeneration 存在且可读', () {
      expect(spider.contains('int _sessionGeneration = 0;'), isTrue);
      expect(spider.contains('int get sessionGeneration'), isTrue);
    });

    test('换源 / 引擎重启都要 +1 代数', () {
      final resetCache = spider.indexOf('void resetScriptCache()');
      final resetEngine = spider.indexOf('void resetEngineMemory()');
      expect(resetCache, greaterThan(0));
      expect(resetEngine, greaterThan(0));
      expect(
        spider.substring(resetCache, resetCache + 400).contains('_sessionGeneration++'),
        isTrue,
      );
      expect(
        spider.substring(resetEngine, resetEngine + 400).contains('_sessionGeneration++'),
        isTrue,
      );
    });

    test('载入前比对代数，不一致直接放弃（不许顶掉新源）', () {
      final i = spider.indexOf('Future<String?> _ensureNodeScriptInner(');
      expect(i, greaterThan(0));
      final seg = spider.substring(i, i + 900);
      expect(seg.contains('required int gen'), isTrue);
      expect(seg.contains('gen != _sessionGeneration'), isTrue);
      expect(seg.contains('return null;'), isTrue);
    });

    test('写槽位（loadSource）之前要再比一次 —— 等端口那几秒也会被换源', () {
      final i = spider.indexOf('Future<String?> _ensureNodeScriptInner(');
      final seg = spider.substring(i, spider.indexOf('Future<String?> _ensureDrpyScriptInner(') > i ? spider.length : i + 4000);
      final loadAt = seg.indexOf('NodeJSManager.instance.loadSource(script)');
      expect(loadAt, greaterThan(0));
      final before = seg.substring(0, loadAt);
      // 最后一个 waitForSpiderPort 之后必须还有一次代数比对
      final waitAt = before.lastIndexOf('waitForSpiderPort()');
      expect(waitAt, greaterThan(0));
      expect(before.substring(waitAt).contains('gen != _sessionGeneration'), isTrue);
    });

    test('drpy 载入同样比代数', () {
      final i = spider.indexOf('Future<String?> _ensureDrpyScriptInner(');
      expect(i, greaterThan(0));
      final seg = spider.substring(i, i + 700);
      expect(seg.contains('required int gen'), isTrue);
      expect(seg.contains('gen != _sessionGeneration'), isTrue);
    });
  });

  group('/config 回来不许改掉用户选的源', () {
    test('currentSpider 用 homeSourceBean，不用 sourceBeanList.first', () {
      final i = appState.indexOf('Future<void> _fetchSpiderConfig()');
      expect(i, greaterThan(0));
      final seg = appState.substring(i, i + 3000);
      expect(
        seg.contains('ApiConfig.instance.homeSourceBean.value'),
        isTrue,
        reason: '日志里 setCurrentSpider(official_aggregate) 就是拿列表第一条覆盖用户选择的',
      );
      expect(
        seg.contains('final firstSource = ApiConfig.instance.sourceBeanList.firstOrNull;'),
        isFalse,
        reason: '列表第一条是引擎内部聚合源，不是用户选的源',
      );
      // 首页源为空时才退化成列表第一条
      expect(
        seg.contains('home ?? ApiConfig.instance.sourceBeanList.firstOrNull'),
        isTrue,
      );
    });
  });
}
