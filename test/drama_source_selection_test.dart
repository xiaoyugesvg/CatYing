// 短剧「源白名单」相关规则的单元测试（2026-10-24）。
//
// 覆盖三处共用同一份规则的地方：
//   1. 左上角源切换器能选哪些源：DramaSettings.filterBySelection
//   2. 短剧页当前显示哪个源：DramaSettings.resolveCurrentSource
//   3. 列表扫描 / 搜索用哪些源：DramaSettings.resolveTargets
// 以及它们的持久化读写。

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox/models/source_bean.dart';
import 'package:tvbox/pages/drama/drama_settings.dart';

SourceBean src(String key) => SourceBean(key: key, name: '源-$key');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final all = <SourceBean>[src('a'), src('b'), src('c'), src('d')];

  group('白名单过滤（切换器可选范围）', () {
    test('没勾过（空集合）→ 全部可选', () {
      final out = DramaSettings.filterBySelection(all, <String>{});
      expect(out.map((e) => e.key).toList(), ['a', 'b', 'c', 'd']);
    });

    test('返回的是副本，改动不会污染原列表', () {
      final out = DramaSettings.filterBySelection(all, <String>{});
      out.removeLast();
      expect(all.length, 4);
    });

    test('勾了子集 → 只保留勾选的，且保持原列表顺序', () {
      final out = DramaSettings.filterBySelection(all, {'c', 'a'});
      expect(out.map((e) => e.key).toList(), ['a', 'c']);
    });

    test('勾选里包含已失效的 key → 自动丢弃，不报错', () {
      final out = DramaSettings.filterBySelection(all, {'a', 'ghost'});
      expect(out.map((e) => e.key).toList(), ['a']);
    });

    test('勾的 key 全部失效 → 空列表（调用方据此提示重新选择）', () {
      expect(DramaSettings.filterBySelection(all, {'ghost'}), isEmpty);
    });

    test('本地源混在列表里时同样按 key 过滤', () {
      final mixed = <SourceBean>[...all, src('local_1')];
      final out = DramaSettings.filterBySelection(mixed, {'local_1'});
      expect(out.map((e) => e.key).toList(), ['local_1']);
    });
  });

  group('短剧页当前源解析', () {
    final home = src('home');

    test('挑过的源在白名单内 → 用它', () {
      final s = DramaSettings.resolveCurrentSource(
        all: all,
        keys: {'a', 'c'},
        pickedKey: 'c',
        homeSource: home,
      );
      expect(s?.key, 'c');
    });

    test('挑过的源被取消勾选 → 落到白名单第一个', () {
      final s = DramaSettings.resolveCurrentSource(
        all: all,
        keys: {'b'},
        pickedKey: 'a',
        homeSource: home,
      );
      expect(s?.key, 'b');
    });

    test('挑过的源已被删除 → 落到白名单第一个', () {
      final s = DramaSettings.resolveCurrentSource(
        all: all,
        keys: {'c', 'd'},
        pickedKey: 'ghost',
        homeSource: home,
      );
      expect(s?.key, 'c');
    });

    test('没挑过但勾了源 → 白名单第一个', () {
      final s = DramaSettings.resolveCurrentSource(
        all: all,
        keys: {'d', 'b'},
        pickedKey: '',
        homeSource: home,
      );
      expect(s?.key, 'b');
    });

    test('没勾过 → 跟随首页当前源（不是全部里的第一个）', () {
      final s = DramaSettings.resolveCurrentSource(
        all: all,
        keys: <String>{},
        pickedKey: '',
        homeSource: home,
      );
      expect(s?.key, 'home');
    });

    test('没勾过但记录里挑过源 → 仍用挑过的', () {
      final s = DramaSettings.resolveCurrentSource(
        all: all,
        keys: <String>{},
        pickedKey: 'c',
        homeSource: home,
      );
      expect(s?.key, 'c');
    });

    test('没勾过、也没有首页源 → null', () {
      final s = DramaSettings.resolveCurrentSource(
        all: all,
        keys: <String>{},
        pickedKey: '',
        homeSource: null,
      );
      expect(s, isNull);
    });

    test('勾的源全失效、也没有首页源 → null', () {
      final s = DramaSettings.resolveCurrentSource(
        all: all,
        keys: {'ghost'},
        pickedKey: 'a',
        homeSource: null,
      );
      expect(s, isNull);
    });
  });

  // 2026-10-29：「本地JS和订阅切换的时候，没切换过来」——
  // 短剧页挑过的源不能永久钉死，首页源换了要跟着换。
  group('首页源变化后短剧页跟随切换', () {
    final homeA = src('homeA');
    final homeB = src('homeB');
    final mixed = <SourceBean>[...all, homeA, homeB];

    test('挑的时候首页就是它 → 挑的源继续生效', () {
      final s = DramaSettings.resolveCurrentSource(
        all: mixed,
        keys: <String>{},
        pickedKey: 'c',
        homeSource: homeA,
        pickedHomeKey: 'homeA',
      );
      expect(s?.key, 'c');
    });

    test('首页源换过了 → 跟着新首页源（挑的源还在列表里也不认）', () {
      final s = DramaSettings.resolveCurrentSource(
        all: mixed,
        keys: <String>{},
        pickedKey: 'c',
        homeSource: homeB,
        pickedHomeKey: 'homeA',
      );
      expect(s?.key, 'homeB');
    });

    test('首页源换过了、但新首页源不在白名单 → 落白名单第一个', () {
      final s = DramaSettings.resolveCurrentSource(
        all: mixed,
        keys: {'a', 'b'},
        pickedKey: 'c',
        homeSource: homeB,
        pickedHomeKey: 'homeA',
      );
      expect(s?.key, 'a');
    });

    test('首页源换过了、新首页源在白名单 → 用新首页源（不是白名单第一个）', () {
      final s = DramaSettings.resolveCurrentSource(
        all: mixed,
        keys: {'a', 'homeB'},
        pickedKey: 'a',
        homeSource: homeB,
        pickedHomeKey: 'homeA',
      );
      expect(s?.key, 'homeB');
    });

    test('老数据（没记过 pickedHomeKey）→ 维持旧行为：挑的优先', () {
      final s = DramaSettings.resolveCurrentSource(
        all: mixed,
        keys: <String>{},
        pickedKey: 'c',
        homeSource: homeB,
        pickedHomeKey: '',
      );
      expect(s?.key, 'c');
    });
  });

  group('聚合目标（列表扫描 / 搜索共用）', () {
    final home = src('home');

    test('没勾 → 只扫首页当前源', () {
      final out = DramaSettings.resolveTargets(
        all: all,
        keys: <String>{},
        homeSource: home,
      );
      expect(out.map((e) => e.key).toList(), ['home']);
    });

    test('没勾且没有首页源 → 空（页面提示没有可用源）', () {
      final out = DramaSettings.resolveTargets(
        all: all,
        keys: <String>{},
        homeSource: null,
      );
      expect(out, isEmpty);
    });

    test('勾了 → 按白名单过滤，顺序与原列表一致', () {
      final out = DramaSettings.resolveTargets(
        all: all,
        keys: {'d', 'b'},
        homeSource: home,
      );
      expect(out.map((e) => e.key).toList(), ['b', 'd']);
    });

    test('勾的源全失效 → 空', () {
      final out = DramaSettings.resolveTargets(
        all: all,
        keys: {'ghost'},
        homeSource: home,
      );
      expect(out, isEmpty);
    });
  });

  group('设置持久化', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('勾选的源保存后可读回', () async {
      await DramaSettings.saveSourceKeys({'a', 'b'});
      expect(await DramaSettings.sourceKeys(), {'a', 'b'});
    });

    test('当前源保存后可读回', () async {
      await DramaSettings.savePickedSourceKey('c');
      expect(await DramaSettings.pickedSourceKey(), 'c');
    });

    test('挑源时一并记下首页 key，可读回（用于判断是否已过期）', () async {
      await DramaSettings.savePickedSourceKey('c', homeKey: 'homeA');
      expect(await DramaSettings.pickedSourceKey(), 'c');
      expect(await DramaSettings.pickedHomeKey(), 'homeA');
    });

    test('不传 homeKey → 不动那条记录（向后兼容）', () async {
      await DramaSettings.savePickedSourceKey('c', homeKey: 'homeA');
      await DramaSettings.savePickedSourceKey('d');
      expect(await DramaSettings.pickedSourceKey(), 'd');
      expect(await DramaSettings.pickedHomeKey(), 'homeA');
    });

    test('从未保存过 → 空集合 / 空串（走"不限"分支）', () async {
      expect(await DramaSettings.sourceKeys(), isEmpty);
      expect(await DramaSettings.pickedSourceKey(), '');
    });

    test('保存空集合 → 读回仍为空（清空勾选）', () async {
      await DramaSettings.saveSourceKeys({'a'});
      await DramaSettings.saveSourceKeys(<String>{});
      expect(await DramaSettings.sourceKeys(), isEmpty);
    });
  });
}
