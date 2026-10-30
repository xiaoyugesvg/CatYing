import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/miniapp/services/ant_bridge.dart';
import 'package:tvbox/models/source_bean.dart';
import 'package:tvbox/services/api_config.dart';

/// 小程序 ant 桥（`lib/miniapp/services/ant_bridge.dart`）的**契约回归**。
///
/// 这个文件守的是"小程序能做什么、不能做什么"——桥是 WebView 里任意第三方
/// JS 的唯一出口，写错一行就是越权/SSRF/串数据：
///   ① 协议形状：`{id, ok, result|error}`，JS 侧 `__antResolve` 靠它分发；
///   ② 权限门禁：manifest 没声明的能力必须**抛 PERMISSION_DENIED**，
///      而不是"没实现就静默返回 null"（那等于默认全开）；
///   ③ 网络闸门：回环/内网必须拦住（含 IPv6 与 IPv4-mapped 写法），
///      白名单按 host 精确匹配；
///   ④ 存储分区：不同 appId 之间必须完全隔离，`clear` 不能误伤别人。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 桥是全局静态状态（appId / permissions / networkAllowlist / 服务地址表），
  // 用例之间必须重置，否则前一个用例给的权限会漏到后一个。
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AntBridge.configure(appId: 'testapp');
    AntBridge.onExitRequested = null;
  });

  /// 走一次真实入口（WebView 里也是这个函数），返回解析后的响应体。
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    final raw = await AntBridge.handleMessage(
      jsonEncode(<String, dynamic>{'id': 1, 'method': method, 'args': args}),
    );
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  String? codeOf(Map<String, dynamic> r) =>
      (r['error'] as Map?)?['code'] as String?;

  group('协议形状', () {
    test('成功时回 {id, ok:true, result}，id 原样回传', () async {
      final r = await call('env.getSystemInfo');
      expect(r['id'], 1);
      expect(r['ok'], isTrue);
      expect(r.containsKey('result'), isTrue);
      expect(r.containsKey('error'), isFalse);
    });

    test('id 是字符串时也原样回传（JS 侧用自增数字或 uuid 都行）', () async {
      final raw = await AntBridge.handleMessage(
        jsonEncode(<String, dynamic>{
          'id': 'req-abc',
          'method': 'env.getSystemInfo',
        }),
      );
      expect((jsonDecode(raw) as Map)['id'], 'req-abc');
    });

    test('失败时回 {id, ok:false, error:{code,message}}，不带 result', () async {
      final r = await call('nope.notExist');
      expect(r['id'], 1);
      expect(r['ok'], isFalse);
      expect(r.containsKey('result'), isFalse);
      expect(codeOf(r), 'UNKNOWN_API');
      expect((r['error'] as Map)['message'], isA<String>());
    });

    test('完全不是 JSON 时不崩，按未知方法拒绝', () async {
      final raw = await AntBridge.handleMessage('这不是 json {{{');
      final r = jsonDecode(raw) as Map<String, dynamic>;
      expect(r['ok'], isFalse);
      expect(codeOf(r), 'UNKNOWN_API');
    });

    test('JSON 合法但不是对象（数组/数字）也不崩', () async {
      for (final body in <String>['[]', '1', '"x"', 'null']) {
        final r = jsonDecode(await AntBridge.handleMessage(body)) as Map;
        expect(r['ok'], isFalse, reason: body);
        expect((r['error'] as Map)['code'], 'UNKNOWN_API', reason: body);
      }
    });

    test('args 不是对象时当空 map 处理，不抛类型错误', () async {
      final raw = await AntBridge.handleMessage(
        jsonEncode(<String, dynamic>{
          'id': 1,
          'method': 'miniapp.resolveService',
          'args': 'oops',
        }),
      );
      final r = jsonDecode(raw) as Map<String, dynamic>;
      // 走了正常路径（不是 INTERNAL_ERROR 的解析崩溃），只是找不到服务
      expect(codeOf(r), 'SERVICE_NOT_FOUND');
    });
  });

  group('权限门禁：没声明就拒绝，不能默认放行', () {
    // 方法族 → 需要的权限
    const table = <String, String>{
      'storage.get': 'storage',
      'storage.set': 'storage',
      'storage.keys': 'storage',
      'request': 'network',
      'requestJson': 'network',
      'player.getState': 'player',
      'player.open': 'player',
      'source.list': 'source',
      'source.home': 'source',
      'source.search': 'source',
      'ui.toast': 'ui',
      'ui.confirm': 'ui',
      'clipboard.set': 'ui',
      'clipboard.get': 'ui',
    };

    table.forEach((method, perm) {
      test('$method 未声明 $perm → PERMISSION_DENIED', () async {
        final r = await call(method);
        expect(codeOf(r), 'PERMISSION_DENIED',
            reason: '$method 应该被 $perm 权限挡住');
        expect((r['error'] as Map)['message'], contains(perm));
      });
    });

    test('只声明了 storage，其它族仍然拒绝', () async {
      AntBridge.configure(appId: 'testapp', permissions: <String>['storage']);
      expect(codeOf(await call('request', {'url': 'https://a.com'})),
          'PERMISSION_DENIED');
      expect(codeOf(await call('source.list')), 'PERMISSION_DENIED');
      // 声明了的能过（key 合法就会真的读写 prefs）
      final ok = await call('storage.set', {'key': 'k', 'value': 'v'});
      expect(ok['ok'], isTrue);
    });

    test('env.getSystemInfo / exitMiniApp / resolveService 不需要权限', () async {
      expect((await call('env.getSystemInfo'))['ok'], isTrue);
      expect((await call('exitMiniApp'))['ok'], isTrue);
      // 只是没有服务，不是没权限
      expect(codeOf(await call('miniapp.resolveService')),
          'SERVICE_NOT_FOUND');
    });

    test('权限是集合语义：重复声明不报错，不区分顺序', () async {
      AntBridge.configure(
        appId: 'testapp',
        permissions: <String>['storage', 'storage', 'network'],
      );
      expect(AntBridge.permissions, <String>{'storage', 'network'});
    });

    test('重新 configure 会**整体替换**权限（不残留上一个小程序的）', () async {
      AntBridge.configure(appId: 'a', permissions: <String>['storage']);
      expect((await call('storage.keys'))['ok'], isTrue);
      AntBridge.configure(appId: 'b');
      expect(codeOf(await call('storage.keys')), 'PERMISSION_DENIED');
    });
  });

  group('网络白名单：按 host 规范化后精确匹配', () {
    test('scheme / 端口 / 路径 / 大小写都剥掉', () {
      AntBridge.configure(
        appId: 'testapp',
        networkAllowlist: <String>[
          'https://api.example.com:8443/v1/list',
          'HTTP://Foo.COM',
          '  cdn.test.io  ',
          'http://x.com?q=1',
          'http://y.com#frag',
        ],
      );
      expect(
        AntBridge.networkAllowlist,
        <String>{'api.example.com', 'foo.com', 'cdn.test.io', 'x.com', 'y.com'},
      );
    });

    test('空串 / 纯空白被丢弃（否则会变成"匹配空 host"）', () {
      AntBridge.configure(
        appId: 'testapp',
        networkAllowlist: <String>['', '   ', 'https://'],
      );
      expect(AntBridge.networkAllowlist, isEmpty);
    });

    test('声明了白名单 → 不在名单的 host 被拒', () async {
      AntBridge.configure(
        appId: 'testapp',
        permissions: <String>['network'],
        networkAllowlist: <String>['api.example.com'],
      );
      final r = await call('request', {'url': 'https://evil.test/x'});
      expect(codeOf(r), 'DENIED_BY_ALLOWLIST');
    });

    test('没声明白名单 → 不拦（保持旧包兼容）', () async {
      AntBridge.configure(appId: 'testapp', permissions: <String>['network']);
      // 命中"内网拦截"而不是"白名单"，说明白名单确实没参与
      final r = await call('request', {'url': 'http://10.1.2.3/x'});
      expect(codeOf(r), 'FORBIDDEN_HOST');
    });
  });

  group('网络闸门：回环 / 内网 / IPv6 变体必须拦住（SSRF）', () {
    const forbidden = <String>[
      'http://127.0.0.1/x',
      'http://127.0.0.1:8080/x',
      'http://localhost/x',
      'http://LOCALHOST:9000/x',
      'http://0.0.0.0/x',
      'http://10.0.0.1/x',
      'http://192.168.1.1/x',
      'http://169.254.169.254/latest/meta-data/', // 云元数据
      'http://172.16.0.1/x',
      'http://172.31.255.255/x',
      // IPv6：Uri.host 不带方括号
      'http://[::1]/x',
      'http://[::1]:8080/x',
      'http://[::]/x',
      'http://[fe80::1]/x',
      'http://[fc00::1]/x',
      'http://[fd12:3456::1]/x',
      // IPv4-mapped IPv6：等价于 IPv4 本身
      'http://[::ffff:127.0.0.1]/x',
      'http://[::ffff:10.0.0.1]/x',
      'http://[::ffff:192.168.1.1]:8080/x',
    ];

    for (final url in forbidden) {
      test('拦 $url', () async {
        AntBridge.configure(appId: 'testapp', permissions: <String>['network']);
        final r = await call('request', {'url': url});
        expect(codeOf(r), 'FORBIDDEN_HOST', reason: url);
      });
    }

    test('172.32.x 不在私有段 16~31 内，不该被当内网', () async {
      // 用白名单把它挡在发请求之前，从而区分"内网拦截"与"白名单拦截"
      AntBridge.configure(
        appId: 'testapp',
        permissions: <String>['network'],
        networkAllowlist: <String>['api.example.com'],
      );
      final r = await call('request', {'url': 'http://172.32.0.1/x'});
      expect(codeOf(r), 'DENIED_BY_ALLOWLIST');
    });

    test('公网 host 能通过闸门（不是被 FORBIDDEN/ALLOWLIST 拦下）', () async {
      AntBridge.configure(
        appId: 'testapp',
        permissions: <String>['network'],
        networkAllowlist: <String>['example.invalid'],
      );
      final r = await call(
        'request',
        {'url': 'https://example.invalid/x', 'timeout': 1000},
      );
      // ⚠️ flutter_test 会把 HttpClient 接管（所有请求恒回 400），所以这里
      // 只验"没被校验层拦下"；具体状态码不是本用例关心的事。
      expect(codeOf(r), isNot('FORBIDDEN_HOST'));
      expect(codeOf(r), isNot('DENIED_BY_ALLOWLIST'));
    });

    test('url 为空 / 相对路径 / 非 http(s) 协议分别报错', () async {
      AntBridge.configure(appId: 'testapp', permissions: <String>['network']);
      expect(codeOf(await call('request', <String, dynamic>{})), 'INVALID_PARAMS');
      expect(codeOf(await call('request', {'url': '/relative'})), 'INVALID_URL');
      expect(codeOf(await call('request', {'url': 'ftp://a.com/x'})),
          'INVALID_URL');
      expect(codeOf(await call('request', {'url': 'javascript:alert(1)'})),
          'INVALID_URL');
    });
  });

  group('存储：按 appId 分区，clear 不误伤', () {
    setUp(() {
      AntBridge.configure(appId: 'appA', permissions: <String>['storage']);
    });

    test('set / get 往返，get 缺省值生效', () async {
      await call('storage.set', {'key': 'token', 'value': 'abc'});
      expect((await call('storage.get', {'key': 'token'}))['result'], 'abc');
      expect(
        (await call('storage.get', {'key': 'missing', 'def': 'fallback'}))
            ['result'],
        'fallback',
      );
    });

    test('setJSON / getJSON 往返，坏数据回退 def 而不是抛', () async {
      await call('storage.setJSON', {
        'key': 'cfg',
        'value': {'a': 1, 'b': [1, 2]},
      });
      final got = (await call('storage.getJSON', {'key': 'cfg'}))['result'];
      expect(got, {'a': 1, 'b': [1, 2]});

      // 塞一段非 JSON（模拟老版本/被外部写坏）
      await call('storage.set', {'key': 'broken', 'value': 'not-json'});
      expect(
        (await call('storage.getJSON', {'key': 'broken', 'def': 42}))['result'],
        42,
      );
    });

    test('keys 只列出本分区的键', () async {
      AntBridge.configure(appId: 'appA', permissions: <String>['storage']);
      await call('storage.set', {'key': 'k1', 'value': '1'});
      await call('storage.set', {'key': 'k2', 'value': '2'});
      AntBridge.configure(appId: 'appB', permissions: <String>['storage']);
      await call('storage.set', {'key': 'k3', 'value': '3'});

      AntBridge.configure(appId: 'appA', permissions: <String>['storage']);
      final keys = (await call('storage.keys'))['result'] as List;
      expect(keys.toSet(), <String>{'k1', 'k2'});

      AntBridge.configure(appId: 'appB', permissions: <String>['storage']);
      final keysB = (await call('storage.keys'))['result'] as List;
      expect(keysB.toSet(), <String>{'k3'});
    });

    test('同键名在不同 appId 下互不可见', () async {
      AntBridge.configure(appId: 'appA', permissions: <String>['storage']);
      await call('storage.set', {'key': 'same', 'value': 'A'});
      AntBridge.configure(appId: 'appB', permissions: <String>['storage']);
      await call('storage.set', {'key': 'same', 'value': 'B'});

      AntBridge.configure(appId: 'appA', permissions: <String>['storage']);
      expect((await call('storage.get', {'key': 'same'}))['result'], 'A');
      AntBridge.configure(appId: 'appB', permissions: <String>['storage']);
      expect((await call('storage.get', {'key': 'same'}))['result'], 'B');
    });

    test('clear 只清自己的分区', () async {
      AntBridge.configure(appId: 'appB', permissions: <String>['storage']);
      await call('storage.set', {'key': 'keep', 'value': 'B'});
      AntBridge.configure(appId: 'appA', permissions: <String>['storage']);
      await call('storage.set', {'key': 'gone', 'value': 'A'});

      await call('storage.clear');
      expect((await call('storage.keys'))['result'], isEmpty);

      AntBridge.configure(appId: 'appB', permissions: <String>['storage']);
      expect((await call('storage.get', {'key': 'keep'}))['result'], 'B');
    });

    test('remove 单键', () async {
      await call('storage.set', {'key': 'x', 'value': '1'});
      await call('storage.remove', {'key': 'x'});
      expect((await call('storage.get', {'key': 'x'}))['result'], isNull);
    });

    test('key 为空或超长 → INVALID_KEY', () async {
      expect(codeOf(await call('storage.get', <String, dynamic>{})),
          'INVALID_KEY');
      expect(codeOf(await call('storage.get', {'key': '   '})), 'INVALID_KEY');
      expect(
        codeOf(await call('storage.get', {'key': 'k' * 257})),
        'INVALID_KEY',
      );
      // 256 是允许的上界
      expect((await call('storage.get', {'key': 'k' * 256}))['ok'], isTrue);
    });
  });

  group('反向服务地址表', () {
    test('未登记 → SERVICE_NOT_FOUND（页面能据此提示"没有后端"）', () async {
      final r = await call('miniapp.resolveService');
      expect(codeOf(r), 'SERVICE_NOT_FOUND');
    });

    test('登记后返回地址；空 name 用当前 appId', () async {
      AntBridge.registerService('testapp', 'http://127.0.0.1:1234');
      expect((await call('miniapp.resolveService'))['result'],
          'http://127.0.0.1:1234');
    });

    test('miniapp:// 前缀会被剥掉，可跨小程序查', () async {
      AntBridge.registerService('other', 'http://127.0.0.1:2222');
      final r = await call(
        'miniapp.resolveService',
        {'name': 'miniapp://other'},
      );
      expect(r['result'], 'http://127.0.0.1:2222');
    });

    test('传 null / 空串 = 注销（页面 dispose 时走这条路）', () async {
      AntBridge.registerService('testapp', 'http://127.0.0.1:1234');
      expect((await call('miniapp.resolveService'))['ok'], isTrue);
      AntBridge.registerService('testapp', null);
      expect(codeOf(await call('miniapp.resolveService')),
          'SERVICE_NOT_FOUND');
    });

    test('空 appId 归一成 "app"（与 configure 一致）', () async {
      AntBridge.configure(appId: '');
      expect(AntBridge.appId, 'app');
      AntBridge.registerService('', 'http://127.0.0.1:3333');
      expect((await call('miniapp.resolveService'))['result'],
          'http://127.0.0.1:3333');
    });
  });

  group('env / 生命周期', () {
    test('getSystemInfo 带上 appId、权限、SDK 版本', () async {
      AntBridge.configure(
        appId: 'demo',
        permissions: <String>['storage', 'network'],
      );
      final info = (await call('env.getSystemInfo'))['result'] as Map;
      expect(info['appId'], 'demo');
      expect(info['appName'], '猫影');
      expect(info['sdkVersion'], AntBridge.sdkVersion);
      expect(info['sdkVersion'], 4);
      expect((info['permissions'] as List).toSet(),
          <String>{'storage', 'network'});
      expect(info['platform'], isA<String>());
      expect((info['platform'] as String), isNotEmpty);
      expect(info['appVersion'], isA<String>());
    });

    test('player.getState 目前恒为未播放（宿主未接播放器状态）', () async {
      AntBridge.configure(appId: 'testapp', permissions: <String>['player']);
      expect((await call('player.getState'))['result'], {'active': false});
    });

    test('exitMiniApp 会触发宿主回调，且回调异常不影响返回', () async {
      var hit = 0;
      AntBridge.onExitRequested = () => hit++;
      final r = await call('exitMiniApp');
      expect(r['ok'], isTrue);
      await Future<void>.delayed(Duration.zero); // 回调在微任务里
      expect(hit, 1);

      AntBridge.onExitRequested = () => throw StateError('宿主炸了');
      final r2 = await call('exitMiniApp');
      expect(r2['ok'], isTrue);
      await Future<void>.delayed(Duration.zero);
    });

    test('没注入回调时 exitMiniApp 也不崩（在线站点型没有宿主页）', () async {
      final r = await call('exitMiniApp');
      expect(r['ok'], isTrue);
    });
  });

  group('source.* 形状：小程序只认 key/name/type/searchable', () {
    setUp(() {
      Get.reset();
      Get.put(ApiConfig());
      AntBridge.configure(appId: 'testapp', permissions: <String>['source']);
    });

    tearDown(Get.reset);

    test('source.list 过滤空 key，name 缺省回退 key', () async {
      ApiConfig.instance.sourceBeanList.assignAll(<SourceBean>[
        const SourceBean(key: 'a', name: 'A 源', type: 1, searchable: 1),
        const SourceBean(key: '', name: '无 key 的脏数据'),
        const SourceBean(key: 'b', name: '', type: 3, searchable: 0),
      ]);
      final list = (await call('source.list'))['result'] as List;
      expect(list.length, 2);
      expect(list[0], {
        'key': 'a',
        'name': 'A 源',
        'type': 1,
        'searchable': 1,
      });
      expect(list[1]['name'], 'b', reason: 'name 为空时用 key 兜底');
      expect(list[1]['searchable'], 0);
    });

    test('找不到源 → SITE_NOT_FOUND（不是空列表，JS 能区分"没这个源"）',
        () async {
      ApiConfig.instance.sourceBeanList.clear();
      for (final m in <String>[
        'source.home',
        'source.category',
        'source.search',
        'source.detail',
        'source.play',
      ]) {
        expect(codeOf(await call(m, {'siteKey': 'ghost'})), 'SITE_NOT_FOUND',
            reason: m);
      }
    });

    test('source.search 关键词为空直接回空列表，不打源', () async {
      ApiConfig.instance.sourceBeanList
          .assignAll(<SourceBean>[const SourceBean(key: 'a', name: 'A')]);
      expect((await call('source.search', {'siteKey': 'a', 'wd': ''}))['result'],
          {'list': <Object?>[]});
    });

    test('source.play：CMS 直链原样返回，parse=0', () async {
      ApiConfig.instance.sourceBeanList.assignAll(
          <SourceBean>[const SourceBean(key: 'cms', name: 'CMS', type: 1)]);
      final r = (await call('source.play', {
        'siteKey': 'cms',
        'flag': '线路1',
        'id': 'https://cdn.test/a.m3u8',
      }))['result'] as Map;
      expect(r['url'], 'https://cdn.test/a.m3u8');
      expect(r['playUrl'], 'https://cdn.test/a.m3u8');
      expect(r['parse'], 0);
      expect(r['flag'], '线路1');
      expect(r['key'], 'cms');
    });

    test('source.play：非 URL 的剧集 id 标 parse=1（交给解析）', () async {
      ApiConfig.instance.sourceBeanList.assignAll(
          <SourceBean>[const SourceBean(key: 'cms', name: 'CMS', type: 1)]);
      final r = (await call('source.play', {
        'siteKey': 'cms',
        'flag': 'f',
        'id': '12345',
      }))['result'] as Map;
      expect(r['parse'], 1);
      expect(r['url'], '12345');
    });

    test('source.recent 的 limit 被夹在 1~100', () async {
      // 只验参数边界不炸（记录为空时列表就是空）
      for (final limit in <Object>[0, -5, 9999, 'bad']) {
        final r = await call('source.recent', {'limit': limit});
        expect(r['ok'], isTrue, reason: 'limit=$limit');
        expect((r['result'] as Map)['list'], isA<List>());
      }
    });
  });
}
