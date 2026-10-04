// lib/reading/source/global_proxy.dart
//
// 全局网络代理（参考图 IMG_8465 通用设置 → 网络代理）。
// 开关 + "host:port" 存于 SettingsService；
// 书源/漫画源请求时，单源未配代理则回退到全局代理。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../services/settings_service.dart';

/// 把全局代理应用到 [dio]（开启且地址合法时才生效）。
/// 返回是否已应用代理。
bool applyGlobalProxy(Dio dio) {
  final s = SettingsService();
  if (!s.globalProxyEnabled) return false;
  return applyProxy(dio, s.globalProxy);
}

/// 把 "host:port" 代理应用到 [dio]；格式非法返回 false。
bool applyProxy(Dio dio, String proxy) {
  final p = proxy.trim();
  if (p.isEmpty) return false;
  final parts = p.split(':');
  if (parts.length != 2) return false;
  final host = parts[0].trim();
  final port = int.tryParse(parts[1].trim()) ?? 0;
  if (host.isEmpty || port <= 0) return false;
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      final client = HttpClient()
        ..findProxy = (uri) => 'PROXY $host:$port';
      return client;
    },
  );
  return true;
}

/// 当前全局代理的展示文案（开关关闭 → null）
String? globalProxyDisplay() {
  final s = SettingsService();
  if (!s.globalProxyEnabled) return null;
  final p = s.globalProxy.trim();
  return p.isEmpty ? null : p;
}
