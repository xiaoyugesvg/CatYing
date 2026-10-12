// lib/services/dio_factory.dart
//
// 构造带上 hosts/DoH 解析能力的 Dio。
//
// 关键：只把 **socket 连接目标** 换成 HostResolver 解析出的 IP，
// URI 本身保持不变 → Host 头 / TLS SNI / 证书校验仍用原始域名，不破坏 HTTPS。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import 'host_resolver.dart';

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

  if (!HostResolver.instance.hasRules) {
    return dio;
  }

  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () => HttpClient()
      ..connectionFactory = (uri, proxyHost, proxyPort) async {
        final ip = await HostResolver.instance.resolve(uri.host);
        if (ip == null || ip.isEmpty) {
          // 没有规则命中 / 解析失败 → 回退系统 DNS
          return Socket.startConnect(uri.host, uri.port);
        }
        // 只换连接目标；uri.host 仍用于 Host 头与 TLS SNI/证书校验
        return Socket.startConnect(ip, uri.port);
      },
  );
  return dio;
}
