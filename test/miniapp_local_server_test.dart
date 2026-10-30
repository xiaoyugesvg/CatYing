import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/miniapp/services/mini_app_local_server.dart';

/// 小程序本地静态服务（`mini_app_local_server.dart`）的回归。
///
/// 它是"本地安装型小程序"的渲染入口：页面从 `http://127.0.0.1:<port>/` 加载，
/// 服务端负责**注入 ant 桥**。两件事错一件就是事故：
///   ① 注入位置：桥必须在页面最早脚本之前 —— 否则第三方裸 HTML 白屏 /
///      `ant is not defined`（这正是当初从 `file://` 换过来的原因）；
///   ② 目录边界：只许读包内文件 —— 否则一个小程序能读宿主任意文件
///      （`../` 穿越），配合桥就是完整利用链。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String root;

  // flutter_test 默认把 HttpClient 换成"恒回 400"的假实现；
  // 这里测的是真 socket 服务，必须放行真实网络栈。
  setUpAll(() => HttpOverrides.global = null);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('miniapp_srv_');
    root = tmp.path.replaceAll('\\', '/');
    File('$root/index.html').writeAsStringSync(
      '<!DOCTYPE html><html><head><meta charset="utf-8"></head>'
      '<body>hello</body></html>',
    );
    File('$root/app.js').writeAsStringSync('console.log(1)');
    File('$root/style.css').writeAsStringSync('body{color:red}');
    File('$root/logo.png')
        .writeAsBytesSync(<int>[0x89, 0x50, 0x4E, 0x47, 0, 1, 2, 255]);
    Directory('$root/sub').createSync();
    File('$root/sub/index.html')
        .writeAsStringSync('<html><head></head><body>sub</body></html>');
    // 包**外**的机密文件（用来验穿越读不到）
    File('${tmp.parent.path}/miniapp_secret.txt')
        .writeAsStringSync('TOP-SECRET');
  });

  tearDown(() async {
    await MiniAppLocalServer.stop('srv-a');
    await MiniAppLocalServer.stop('srv-b');
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    final secret = File('${tmp.parent.path}/miniapp_secret.txt');
    if (secret.existsSync()) secret.deleteSync();
  });

  /// 用真实 HttpClient 取一个路径，返回状态码 / 正文 / MIME。
  ///
  /// ⚠️ 必须用 `http://host:port$path` 直接拼，不能拼 `baseUrl + path`
  /// （baseUrl 结尾已有 `/`，再拼 `/x` 会变成 `//x`；Dart 的 `Uri.parse`
  /// 会把 `//x` 当成 authority，`request.uri.path` 直接变空串）。
  Future<({int status, String body, String? mime, String cache})> get(
    MiniAppLocalServer server,
    String path, {
    bool binary = false,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final url = 'http://127.0.0.1:${server.port}'
          '${path.startsWith('/') ? path : '/$path'}';
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close();
      final bytes = await res.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      return (
        status: res.statusCode,
        body:
            binary ? base64Encode(bytes) : utf8.decode(bytes, allowMalformed: true),
        mime: res.headers.contentType?.mimeType,
        cache: res.headers.value('cache-control') ?? '',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// 手工发原始请求行，拿状态码与正文。
  ///
  /// 走 socket 而不是 HttpClient：`Uri` 会在构造阶段就把 `/../x` 规范化掉，
  /// 测不到"服务端自己有没有挡住"。
  Future<({int status, String body})> raw(
    MiniAppLocalServer server,
    String rawPath,
  ) async {
    final socket =
        await Socket.connect(InternetAddress.loopbackIPv4, server.port);
    try {
      socket.write('GET $rawPath HTTP/1.1\r\n'
          'Host: 127.0.0.1\r\n'
          'Connection: close\r\n\r\n');
      await socket.flush();
      final bytes = await socket.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      final text = utf8.decode(bytes, allowMalformed: true);
      final lines = text.split('\r\n');
      // "HTTP/1.1 403 Forbidden"
      final status = int.parse(lines.first.split(' ')[1]);
      final sep = text.indexOf('\r\n\r\n');
      return (
        status: status,
        body: sep >= 0 ? text.substring(sep + 4) : '',
      );
    } finally {
      socket.destroy();
    }
  }

  group('只监听回环 + 生命周期', () {
    test('基址是 127.0.0.1 的随机端口', () async {
      final server = await MiniAppLocalServer.start(appId: 'srv-a', root: root);
      expect(server.baseUrl, startsWith('http://127.0.0.1:'));
      expect(server.port, greaterThan(0));
      final other = await MiniAppLocalServer.start(appId: 'srv-b', root: root);
      expect(other.port, isNot(server.port));
    });

    test('同一 appId 重复 start 复用实例（不重复占端口）', () async {
      final a = await MiniAppLocalServer.start(appId: 'srv-a', root: root);
      final b = await MiniAppLocalServer.start(appId: 'srv-a', root: root);
      expect(identical(a, b), isTrue);
      expect(a.port, b.port);
      expect(MiniAppLocalServer.forApp('srv-a'), same(a));
    });

    test('并发 start 只起一个服务（不会漏掉一个实例占着端口）', () async {
      final results = await Future.wait(<Future<MiniAppLocalServer>>[
        MiniAppLocalServer.start(appId: 'srv-a', root: root),
        MiniAppLocalServer.start(appId: 'srv-a', root: root),
        MiniAppLocalServer.start(appId: 'srv-a', root: root),
      ]);
      expect(results.map((e) => e.port).toSet().length, 1);
      expect(results.every((e) => identical(e, results.first)), isTrue);
    });

    test('stop 之后实例消失，端口不再服务', () async {
      final server = await MiniAppLocalServer.start(appId: 'srv-a', root: root);
      expect(MiniAppLocalServer.forApp('srv-a'), isNotNull);
      await MiniAppLocalServer.stop('srv-a');
      expect(MiniAppLocalServer.forApp('srv-a'), isNull);
      await expectLater(
        get(server, '/index.html'),
        throwsA(isA<SocketException>()),
      );
    });

    test('stop 一个不存在的 appId 不抛', () async {
      await MiniAppLocalServer.stop('never-started');
    });

    test('stop 与 start 竞态时也能收干净（不留后台服务）', () async {
      final starting = MiniAppLocalServer.start(appId: 'srv-a', root: root);
      final stopping = MiniAppLocalServer.stop('srv-a');
      await Future.wait<void>(<Future<void>>[
        starting.then((_) {}),
        stopping,
      ]);
      expect(MiniAppLocalServer.forApp('srv-a'), isNull);
    });
  });

  group('ant 桥注入', () {
    test('HTML 响应里带桥脚本，且禁止缓存', () async {
      final server = await MiniAppLocalServer.start(appId: 'srv-a', root: root);
      final r = await get(server, '/index.html');
      expect(r.status, 200);
      expect(r.mime, 'text/html');
      expect(r.body, contains('__antInjected'));
      expect(r.cache, 'no-store');
    });

    test('注入点在 <head> 之后、</head> 之前、<body> 之前', () async {
      final server = await MiniAppLocalServer.start(appId: 'srv-a', root: root);
      final body = (await get(server, '/')).body;
      final headOpen = body.indexOf('<head');
      final headClose = body.indexOf('</head>');
      final bridge = body.indexOf('__antInjected');
      final bodyTag = body.indexOf('<body>');
      expect(headOpen, greaterThan(0));
      expect(headClose, greaterThan(headOpen));
      expect(bridge, greaterThan(headOpen), reason: '桥要插在 head 里面');
      expect(bridge, lessThan(headClose), reason: '桥要在 head 结束之前');
      expect(bridge, lessThan(bodyTag), reason: '桥必须在 body 内容之前');
    });

    test('没有 <head> 但有 <header> 时，不能塞进 <header> 里', () async {
      File('$root/header-only.html').writeAsStringSync(
        '<html><body><header class="bar"><h1>标题</h1></header>'
        '<main>x</main></body></html>',
      );
      final server = await MiniAppLocalServer.start(appId: 'srv-a', root: root);
      final body = (await get(server, '/header-only.html')).body;
      final bridge = body.indexOf('__antInjected');
      final headerOpen = body.indexOf('<header');
      final htmlOpen = body.indexOf('<html>');
      expect(bridge, greaterThan(htmlOpen));
      expect(bridge, lessThan(headerOpen),
          reason: '桥应插在 <html> 之后，而不是 <header> 内部');
      expect(body, contains('标题'));
    });

    test('连 <html> 都没有的碎片 HTML，桥插在文首', () async {
      File('$root/fragment.html').writeAsStringSync('<div>碎片</div>');
      final server = await MiniAppLocalServer.start(appId: 'srv-a', root: root);
      final body = (await get(server, '/fragment.html')).body;
      expect(body.trimLeft(), startsWith('<script>'));
      expect(body, contains('__antInjected'));
      expect(body, contains('<div>碎片</div>'));
    });

    test('非 HTML 不注入（否则会把 JS/图片写坏）', () async {
      final server = await MiniAppLocalServer.start(appId: 'srv-a', root: root);
      final js = await get(server, '/app.js');
      expect(js.body, 'console.log(1)');
      expect(js.body, isNot(contains('__antInjected')));
      expect(js.mime, 'application/javascript');
    });

    test('二进制文件按原字节返回', () async {
      final server = await MiniAppLocalServer.start(appId: 'srv-a', root: root);
      final png = await get(server, '/logo.png', binary: true);
      expect(png.mime, 'image/png');
      expect(
        base64Decode(png.body),
        <int>[0x89, 0x50, 0x4E, 0x47, 0, 1, 2, 255],
      );
    });
  });

  group('路由与 MIME', () {
    late MiniAppLocalServer server;

    setUp(() async {
      server = await MiniAppLocalServer.start(appId: 'srv-a', root: root);
    });

    test('根路径回 index.html', () async {
      final r = await get(server, '/');
      expect(r.status, 200);
      expect(r.body, contains('hello'));
    });

    test('目录路径回该目录的 index.html', () async {
      final r = await get(server, '/sub/');
      expect(r.status, 200);
      expect(r.body, contains('sub'));
      expect(r.body, isNot(contains('hello')));
    });

    test('无扩展名的 SPA 子路径回退到根 index.html', () async {
      final r = await get(server, '/some/spa/route');
      expect(r.status, 200);
      expect(r.body, contains('hello'));
    });

    test('带扩展名但文件不存在 → 404（不吞成 SPA 回退）', () async {
      expect((await get(server, '/missing.js')).status, 404);
      expect((await get(server, '/nope.png')).status, 404);
    });

    test('常见类型 MIME 正确', () async {
      expect((await get(server, '/style.css')).mime, 'text/css');
      expect((await get(server, '/app.js')).mime, 'application/javascript');
      expect((await get(server, '/logo.png')).mime, 'image/png');
      expect((await get(server, '/index.html')).mime, 'text/html');
    });
  });

  group('目录边界：包外文件读不到', () {
    late MiniAppLocalServer server;

    setUp(() async {
      server = await MiniAppLocalServer.start(appId: 'srv-a', root: root);
    });

    // 注：Dart 的 HttpServer 在解析请求行时就会把 `..` / `%2e%2e` 规范化掉，
    // 所以这些请求到不了 `_handle` 的越界分支（404 而不是 403）。这里守的是
    // **最终结果**：包外文件的内容绝不能出现在响应里。
    const attempts = <String>[
      '/../miniapp_secret.txt',
      '/../../miniapp_secret.txt',
      '/a/b/../../../miniapp_secret.txt',
      '/%2e%2e/miniapp_secret.txt',
      '/%2E%2E%2Fminiapp_secret.txt',
      '/..%2fminiapp_secret.txt',
      '/sub/../../miniapp_secret.txt',
    ];

    for (final path in attempts) {
      test('$path 读不到包外文件', () async {
        final r = await raw(server, path);
        expect(r.body, isNot(contains('TOP-SECRET')), reason: path);
      });
    }

    test('越界请求被拒绝（非 200），且包内文件仍正常', () async {
      final r = await raw(server, '/../miniapp_secret.txt');
      expect(r.status, isNot(200));
      expect((await get(server, '/sub/index.html')).status, 200);
    });
  });

  group('isWithinDir 边界判定', () {
    test('同目录下的文件算在内', () {
      expect(isWithinDir('/a/b/c.html', '/a/b'), isTrue);
      expect(isWithinDir('/a/b/sub/c.html', '/a/b/'), isTrue);
    });

    test('前缀相同但不在目录内 → 不算', () {
      // /a/bc 不是 /a/b 的子路径（只差一个斜杠的经典漏洞）
      expect(isWithinDir('/a/bc/x.html', '/a/b'), isFalse);
      expect(isWithinDir('/a/b/../c.html', '/a/b'), isFalse);
    });

    test('反斜杠路径归一化后仍能判对（Windows）', () {
      expect(isWithinDir(r'C:\x\y\z.html', r'C:\x\y'), isTrue);
      expect(isWithinDir(r'C:\x\yy\z.html', r'C:\x\y'), isFalse);
    });
  });
}
