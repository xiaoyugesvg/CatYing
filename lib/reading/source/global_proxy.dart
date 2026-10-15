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
///
/// ✅ **[createHttpClient] 透传**（本轮新增 ✓，与 [applyProxy] 保持一致 ✓）——
///   供**自带 UA 工厂**的调用方使用 ✓：最典型的是 `download_service._imageDio` ✓
///   （它设了浏览器 UA ✓，注释写明"不设 UA 会被 c-nd3 等 CDN 拦 403"✗）。
///   传进来后本函数**只叠加 `findProxy`** ✓，**不会把 UA 一起丢掉** ✓✓（代理+UA 兼得 ✓）。
///   不传 = 与从前**完全一致** ✓（书源 ✓ 漫画源 ✓ z-library ✓ 三处**零变化** ✓）。
bool applyGlobalProxy(Dio dio, {HttpClient Function()? createHttpClient}) {
  final s = SettingsService();
  if (!s.globalProxyEnabled) return false;
  // 「APP 代理」域名规则（Webhtv → APP 代理）：
  //   开了「只对规则里的域名走代理」且规则非空 ⇒ 只有命中的域名走代理，其余直连。
  //   没开（默认）= 全部走代理 = 与改动前完全一致 ✓
  final rules = s.proxyDomainRules;
  final limitToDomains = s.proxyDomainOnly && rules.isNotEmpty;
  return applyProxy(
    dio,
    s.globalProxy,
    createHttpClient: createHttpClient,
    shouldProxy: limitToDomains
        ? (host) => SettingsService.hostMatchesProxyRules(host, rules)
        : null,
  );
}

/// 把 "host:port" 代理应用到 [dio]；格式非法返回 false。
///
/// ✅ **[createHttpClient] 可选工厂**（本轮新增 ✓）—— **向后兼容** ✓：
///   不传时行为与从前**完全一致** ✓（内部就是 `HttpClient()` ✓），
///   书源 ✓ / 漫画源 ✓ / z-library ✓ 那几处调用**不受任何影响** ✓✓。
///
/// ⚠️ **为什么需要它** ✗：本函数是**整替换** `dio.httpClientAdapter` ✗，
///   而有的调用方**自带**一个 `createHttpClient` ✓ —— 最典型的是
///   `download_service._imageDio` ✓：它在那里设了**浏览器 UA** ✓
///   （注释写明"不设 UA 会被 c-nd3 等 CDN **拦 403**"✗）。
///   ⇒ 若直接调用本函数，那个 UA 工厂会被**整个丢掉** ✗✗ → 图片下载**重新 403** ✓
///     （**静默回归** ✗，而且不会有任何报错 ✓，最难查 ✓）。
///   ⇒ 所以允许调用方**把自己的工厂传进来** ✓，这里**只叠加 `findProxy`** ✓
///     —— **代理与 UA 兼得** ✓✓，谁都不牺牲 ✓。
bool applyProxy(
  Dio dio,
  String proxy, {
  HttpClient Function()? createHttpClient,
  /// 该域名的请求是否走代理。null = 全部走（原行为）
  bool Function(String host)? shouldProxy,
}) {
  final p = proxy.trim();
  if (p.isEmpty) return false;
  final parts = p.split(':');
  if (parts.length != 2) return false;
  final host = parts[0].trim();
  final port = int.tryParse(parts[1].trim()) ?? 0;
  if (host.isEmpty || port <= 0) return false;
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () {
      // 用调用方的工厂（若有）✓ —— 它可能已设好 UA ✓；否则退回默认 ✓（= 旧行为 ✓ 零变化 ✓）
      // ⚠️ 不能写 `(createHttpClient ?? HttpClient)()` ✗ —— `HttpClient` 是**工厂构造** ✓，
      //   它不是函数值 ✓ → 会报 "expression doesn't evaluate to a function" ✗（本轮闸门当场抓到 ✓✓）。
      final client = createHttpClient != null ? createHttpClient() : HttpClient();
      client.findProxy = (uri) {
        // 域名规则：不命中的直连（不设代理 = 走系统直连）
        if (shouldProxy != null && !shouldProxy(uri.host)) return 'DIRECT';
        return 'PROXY $host:$port';
      };
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
