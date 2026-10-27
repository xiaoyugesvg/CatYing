// 全局 DNS 拦截（HttpOverrides.global）的 TLS 回归测试
// -----------------------------------------------------------------------------
// 背景（2026-10-27 事故）：
//   给 `HttpClient` 设置 `connectionFactory` 之后，**dart:io 不再替你套 TLS**
//   —— `http_impl.dart` 里只有 `connectionFactory == null` 那条分支才会
//   `SecureSocket.startConnect(...)`。原实现统一 `Socket.startConnect(...)`
//   （明文），于是**全 App 的 https 都变成「明文 HTTP 打到 443」**：
//   服务端回 `400 The plain HTTP request was sent to HTTPS port`，
//   表现为 Emby / RSS 加载失败、所有 https 封面破图。
//
// 这个测试就是钉死那条回归：起一个**真 TLS 本地服务**，装上全局 override，
// 再用 `HttpClient` 去访问 —— 修复前必然握手失败/拿不到 200。
//
// 证书是 test/fixtures/tls/ 下的自签名证书（CN=localhost, SAN=localhost/127.0.0.1），
// 通过 `SecurityContext.setTrustedCertificates` 加入信任链，
// 顺带验证「调用方的 SecurityContext 会被透传给 SecureSocket.secure」。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/services/dio_factory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late SecurityContext clientContext;

  setUpAll(() async {
    final serverContext = SecurityContext()
      ..useCertificateChain('test/fixtures/tls/cert.pem')
      ..usePrivateKey('test/fixtures/tls/key.pem');
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      serverContext,
    );
    server.listen((req) {
      req.response
        ..statusCode = 200
        ..write('ok:${req.uri.path}')
        ..close();
    });

    clientContext = SecurityContext()
      ..setTrustedCertificates('test/fixtures/tls/cert.pem');
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  test('装了全局 DNS override 之后，https 仍能正常完成 TLS 握手', () async {
    installGlobalDnsOverrides();

    final client = HttpClient(context: clientContext)
      // 本机回环 → 解析器本来就走系统 DNS；显式 DIRECT 是为了排除
      // 运行环境里的 HTTP_PROXY（走代理会由 dart:io 自己套 TLS，掩盖本 bug）
      ..findProxy = (_) => 'DIRECT';

    try {
      final req = await client.getUrl(
        Uri.parse('https://localhost:${server.port}/probe'),
      );
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();

      expect(resp.statusCode, 200,
          reason: '连接工厂必须自己完成 TLS 升级，否则这里是握手失败或 400');
      expect(body, 'ok:/probe');
    } finally {
      client.close(force: true);
    }
  });

  test('ws / wss 的 Uri.port 是 0 —— 这是房间模块连 0 端口的根因', () {
    // 不是"测试我们的代码"，而是钉住一个**容易踩的 SDK 事实**：
    // Dart 的 Uri 只为 http/https 定义了默认端口，ws/wss 给的是 0。
    // 任何把 `uri.port` 直接丢给 Socket.startConnect 的地方都会连到 0 端口
    // （表现为 `SocketException: ... errno = 49, port = 0`）。
    expect(Uri.parse('https://a.com/x').port, 443);
    expect(Uri.parse('http://a.com/x').port, 80);
    expect(Uri.parse('wss://a.com/x').port, 0);
    expect(Uri.parse('ws://a.com/x').port, 0);
  });
}
