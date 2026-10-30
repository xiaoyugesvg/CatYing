import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/services/parse_lines.dart';

/// 解析线路（订阅 `parses`）的**行为回归**。
///
/// 用户 2026-10-30 反馈「解析切换线路没有完善吗？」+ 截图里
/// 「订阅线路 0 条」，而那份订阅里实际有 56 条。这里钉住三件事：
///   ① 订阅 `parses` 能被完整读出来（不再按 type 误杀）
///   ② `ext.header` 里的 UA 要跟着线路走（否则接口不认）
///   ③ 原样拼接 / URL 编码两种形式都要能生成（各分支约定不统一）
void main() {
  group('ParseLine.apply', () {
    test('模板含 {url} → 替换成编码后的地址', () {
      const l = ParseLine(id: 'x', name: 'n', url: 'https://jx/?u={url}');
      expect(l.apply('https://a.com/p?x=1&y=2'),
          'https://jx/?u=https%3A%2F%2Fa.com%2Fp%3Fx%3D1%26y%3D2');
    });

    test('模板不含 {url} → 直接拼在后面（TVBox type=0 惯例）', () {
      const l = ParseLine(id: 'x', name: 'n', url: 'https://jx/?url=');
      expect(l.apply('https://a.com/p'), 'https://jx/?url=https://a.com/p');
    });

    test('🔴 applyEncoded 一定是编码版（和 apply 不同）', () {
      const l = ParseLine(id: 'x', name: 'n', url: 'https://jx/?url=');
      final raw = l.apply('https://a.com/p?x=1&y=2');
      final enc = l.applyEncoded('https://a.com/p?x=1&y=2');
      expect(raw, contains('&y=2'));
      expect(enc, isNot(raw));
      expect(enc, contains('%26y%3D2'));
    });

    test('模板含 {url} 时两种写法都走替换，结果一致', () {
      const l = ParseLine(id: 'x', name: 'n', url: 'https://jx/?u={url}');
      expect(l.applyEncoded('https://a.com/p'), l.apply('https://a.com/p'));
    });
  });

  group('ParseLine.headers', () {
    test('默认空', () {
      const l = ParseLine(id: 'x', name: 'n', url: 'https://jx/');
      expect(l.headers, isEmpty);
    });

    test('copyWith 不丢请求头（改名不该把 UA 弄丢）', () {
      const l = ParseLine(
        id: 'x',
        name: 'n',
        url: 'https://jx/',
        headers: {'user-agent': 'UA'},
      );
      final c = l.copyWith(name: 'new');
      expect(c.name, 'new');
      expect(c.headers['user-agent'], 'UA');
    });
  });

  group('订阅 parses → 线路', () {
    test('🔴 type=0 / type=1 都要保留（只排除 web）', () {
      // 真实订阅（huahua.json）里的写法：type 是数字 0
      final store = ParseLineStore.instance;
      store.syncFromParses(const [
        {'name': '盘古', 'type': 0, 'url': 'https://a.com/?url='},
        {'name': 'json 线路', 'type': 1, 'url': 'https://b.com/jx?url='},
        {'name': '浏览器', 'type': 'web', 'url': 'https://c.com/web'},
        {'name': '没有地址', 'type': 0},
        {'name': '非 http', 'type': 0, 'url': 'ftp://d.com'},
      ]);
      final names = store.subscriptionLines.map((l) => l.name).toList();
      expect(names, ['盘古', 'json 线路']);
    });

    test('🔴 ext.header 要带进线路（盘古那条的 UA）', () {
      final store = ParseLineStore.instance;
      store.syncFromParses(const [
        {
          'name': '盘古',
          'type': 0,
          'url': 'https://a.com/?url=',
          'ext': {
            'header': {'user-agent': 'Mozilla/5.0 Android'}
          },
        },
      ]);
      expect(store.subscriptionLines.single.headers['user-agent'],
          'Mozilla/5.0 Android');
    });

    test('ext 直接写成 header map 的变体也认', () {
      final store = ParseLineStore.instance;
      store.syncFromParses(const [
        {
          'name': 'x',
          'type': 0,
          'url': 'https://a.com/',
          'ext': {'referer': 'https://a.com/'},
        },
      ]);
      expect(store.subscriptionLines.single.headers['referer'], 'https://a.com/');
    });

    test('名字为空时给「解析 N」兜底（不能出现空行）', () {
      final store = ParseLineStore.instance;
      store.syncFromParses(const [
        {'type': 0, 'url': 'https://a.com/'},
      ]);
      expect(store.subscriptionLines.single.name, '解析 1');
    });
  });
}
