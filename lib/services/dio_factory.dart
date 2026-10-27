// lib/services/dio_factory.dart
//
// 构造带上 hosts/DoH 解析能力的 Dio，并负责把这项能力**全局**接上。
//
// 关键：只把 **socket 连接目标** 换成 HostResolver 解析出的 IP，
// URI 本身保持不变 → Host 头 / TLS SNI / 证书校验仍用原始域名，不破坏 HTTPS。
//
// ---------------------------------------------------------------------------
// 为什么这里有两套入口（2026-10-26 补充）
// ---------------------------------------------------------------------------
// 全项目有 139 个 Dio 创建点（`Dio()` / `Dio(BaseOptions(...))` 各半），
// 原来只有 drpy / epg / spider 三处走 `buildDioWithDns`，其余全直连
// ⇒ 用户在设置里配的 hosts / DoH 对影视、音乐、阅读、RSS **完全无效**。
//
// 逐个改写 139 处不现实（`Dio(BaseOptions(...))` 那 53 处还得把
// connectTimeout / receiveTimeout / headers 一路透传进来，纯机械但极易漏），
// 所以改成在**网络层**统一拦截：
//
//   `HttpOverrides.global` → 每个 `HttpClient()` 都被塞上同一个
//   `connectionFactory` ⇒ 无论谁 new 的 Dio、甚至 `Image.network`、
//   `WebSocket.connect`、`cached_network_image`，全都自动生效。
//
// 这比"收敛到工厂方法"更彻底，而且新增 Dio 时**不需要任何人记得改**。
// `buildDioWithDns` 保留：全局 override 未安装时（单元测试直接 new Dio）
// 它仍提供实例级等价能力，签名与行为对调用方不变。
//
// ⚠️ 与「全局网络代理」的关系：`global_proxy.dart` 只设 `findProxy`，
//    本文件只设 `connectionFactory`，两者叠加不冲突 —— 配了代理时
//    dart:io 会把 `proxyHost/proxyPort` 传给 connectionFactory，
//    本文件据此连代理本身，**不做 IP 替换**（否则 CONNECT 隧道必错）。
//
// ---------------------------------------------------------------------------
// 🔴 2026-10-27 事故：全局 override 让**全 App 的 HTTPS 全部失效**（已修）
// ---------------------------------------------------------------------------
// 现象：Emby / RSS 报 `HTTP 400 The plain HTTP request was sent to HTTPS port`，
//      漫画与 rex 详情页封面全部破图，房间连不上（`errno 49, port = 0`）。
//
// 根因（两条，都在下面这个函数里）：
//   1. **一旦设置 `connectionFactory`，dart:io 就不再替你套 TLS** ——
//      `http_impl.dart` 里只有 `connectionFactory == null` 那条分支才会走
//      `SecureSocket.startConnect(...)`；设了 cf 就直接把 cf 返回的 socket
//      塞进 `_HttpClientConnection`，连 `isSecure` 都不再参与。
//      原实现统一 `Socket.startConnect(...)`（**明文**）⇒ https 变成
//      「明文 HTTP 打到 443」⇒ 服务端回 400（nginx 的报错原文就是上面那句）。
//   2. **Dart 的 `Uri` 不认 `ws`/`wss` 的默认端口**：`Uri.parse('wss://h/x').port == 0`
//      （`https://` 才给 443）。`uri.port` 直接拿去 connect 就是连 0 端口 ⇒
//      `EADDRNOTAVAIL, errno = 49`。房间模块（socket_io → wss）就是这样炸的。
//
// 修法：https/wss 用 `SecureSocket.secure(socket, host: 原域名)` 升级
//      （SNI 与证书校验仍针对域名，IP 替换不影响 TLS）；端口用
//      [_effectivePort] 兜底。两者都用独立脚本实测过：
//      修复前 https 直连 → 400，修复后 → 200；wss 的 0 → 443。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/host_resolver.dart';

/// 该 URI 是否需要用 TLS 连接。
bool _isSecureScheme(Uri uri) =>
    uri.isScheme('https') || uri.isScheme('wss');

/// 真实连接端口。
///
/// `Uri` 只为 http/https 定义了默认端口，`ws`/`wss` 的 `.port` 是 **0**；
/// 而 dart:io 把 wss 改写成 https 时会把这个 0 原样带下来（`https://host:0/…`），
/// 直接拿去 connect 就是 `EADDRNOTAVAIL`。这里统一兜底。
int _effectivePort(Uri uri) {
  final p = uri.port;
  if (p != 0) return p;
  return _isSecureScheme(uri) ? 443 : 80;
}

/// socket 连接目标解析：hosts/DoH 命中则连解析出的 IP，否则原样交给系统 DNS。
///
/// 这是唯一一处真正"换 IP"的地方，[buildDioWithDns] 与全局 override 共用它。
///
/// [tlsContext] 是调用方 `HttpClient` 的 SecurityContext（全局 override 传进来的），
/// 透传给 `SecureSocket.secure` 才能保持"自定义信任链"这类用法不被破坏。
Future<ConnectionTask<Socket>> _connectWithDns(
  Uri uri,
  String? proxyHost,
  int? proxyPort, {
  SecurityContext? tlsContext,
}) async {
  final port = _effectivePort(uri);

  // ① 走代理：目标必须是代理本身。此时替换 IP 会把请求发到源站，
  //    代理形同虚设，且 HTTPS 的 CONNECT 隧道会失败。
  //    ⚠️ 走代理时**不要**自己套 TLS —— dart:io 会在隧道建立后
  //    （`http_impl.dart` 的 `createProxyTunnel`）自己 `SecureSocket.secure`。
  if (proxyHost != null && proxyHost.isNotEmpty) {
    return Socket.startConnect(proxyHost, proxyPort ?? port);
  }

  final resolver = HostResolver.instance;
  var target = uri.host;

  if (resolver.hasRules) {
    if (resolver.shouldUseSystemDns(uri.host)) {
      // ② 回环 / IP 字面量 / DoH 服务器自身 → 只认 hosts 表，绝不发 DoH
      //    （对 DoH 服务器发 DoH 会自递归死锁，见 HostResolver.shouldUseSystemDns）
      target = resolver.lookupHosts(uri.host) ?? uri.host;
    } else {
      // ③ 正常路径：换连接目标，域名仍用于 Host 头 / TLS SNI / 证书校验
      final ip = await resolver.resolve(uri.host);
      if (ip != null && ip.isNotEmpty) target = ip;
    }
  }

  final task = await Socket.startConnect(target, port);

  // ④ 明文协议到此为止
  if (!_isSecureScheme(uri)) return task;

  // ⑤ https / wss：**必须**自己升级成 TLS（见文件头「事故」第 1 条）。
  //    `host:` 用原始域名 ⇒ SNI 与证书校验针对域名，连的却是上面解析出的 IP。
  return ConnectionTask.fromSocket<Socket>(
    task.socket.then(
      (s) => SecureSocket.secure(s, host: uri.host, context: tlsContext),
    ),
    task.cancel,
  );
}

/// 全局 [HttpOverrides]：给每个新建的 `HttpClient` 装上 [_connectWithDns]。
///
/// 必须用 `super.createHttpClient` 而不是再写一次 `HttpClient()` ——
/// 后者会重新走 [HttpOverrides.current] → 命中自己 → **无限递归**。
/// 基类 `HttpOverrides.createHttpClient` 直接构造底层实现，正好绕开这一层。
class _DnsHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    // 把调用方的 SecurityContext 透传下去（自定义信任链的用法才不会被打断）
    client.connectionFactory = (uri, proxyHost, proxyPort) =>
        _connectWithDns(uri, proxyHost, proxyPort, tlsContext: context);
    return client;
  }
}

bool _globalInstalled = false;

/// 是否已安装全局 DNS 拦截（测试里可用来断言/复位）。
bool get isGlobalDnsInstalled => _globalInstalled;

/// 把 hosts/DoH 接到**所有** `HttpClient` 上。幂等，`main()` 里调一次即可。
///
/// 为什么不判断 `HostResolver.hasRules` 再决定装不装：
/// 规则是**配置加载后**才有的，而 Dio/HttpClient 在启动早期就陆续创建了。
/// 安装无条件的 override、在**每次连接时**再判断 hasRules，才能保证
/// "用户后来改了配置也立刻生效"，且没有规则时代价只是一次 map 查空。
void installGlobalDnsOverrides() {
  if (_globalInstalled) return;
  _globalInstalled = true;
  HttpOverrides.global = _DnsHttpOverrides();
  AppLog.instance.log('[DNS] 全局 HttpClient 已接入 hosts/DoH');
}

/// 构造一个 Dio；当配置了 hosts/doh 时，通过 [IOHttpClientAdapter] 的
/// `createHttpClient` 覆盖 socket 连接目标来使用自定义 DNS。
///
/// [HostResolver.hasRules] 为 false（未配置 hosts/doh）时，直接返回普通 Dio，
/// 行为与之前完全一致。
Dio buildDioWithDns({
  Duration? connectTimeout,
  Duration? receiveTimeout,
  Map<String, String>? headers,
}) {
  final dio = Dio(BaseOptions(
    connectTimeout: connectTimeout,
    receiveTimeout: receiveTimeout,
    headers: headers,
  ));

  // 全局 override 已装 ⇒ 默认 IOHttpClientAdapter 创建的 HttpClient
  // 自动带上 connectionFactory，这里再套一层纯属多余（且会重复解析）。
  if (_globalInstalled) return dio;

  // 未装（单元测试 / 未走 main() 的场景）⇒ 退回实例级，行为与改造前一致
  if (!HostResolver.instance.hasRules) {
    return dio;
  }

  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () => HttpClient()..connectionFactory = _connectWithDns,
  );
  return dio;
}
