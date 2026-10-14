// 封面落地缓存：加密（AES）/base64 站的封面 URL 无法直接显示
// （CachedNetworkImage 拿到的是密文/文本），下载还原后存本地缓存目录，
// 返回本地绝对路径。按 URL 哈希缓存，同 URL 只下一次；失败记入 _failed
// 本次运行内不再重试（调用方保留原 URL 兜底，展示端显示占位图）。

import 'dart:convert' show base64, utf8;
import 'dart:io' show Directory, File, Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'image_restore.dart';
import 'site_config.dart';
import 'global_proxy.dart';

void _log(String message) {
  if (kDebugMode) {
    debugPrint('[SourceCoverCache] $message');
  }
}

class SourceCoverCache {
  SourceCoverCache._();
  static final SourceCoverCache instance = SourceCoverCache._();

  /// 构造封面下载用的 Dio，并**挂上「网络代理」**（本轮接上 ✓）。
  ///
  /// ✅ **本处与"UA 工厂"那个坑无关** ✓✓：它的 UA 是写在 **`BaseOptions.headers`** 里 ✓
  ///   （**不是**自定义 `createHttpClient` 适配器 ✓）—— headers 属于 **Dio 选项层** ✓，
  ///   而 `applyGlobalProxy` 只换 **socket 层适配器** ✓ → **两者互不干扰** ✓✓（UA 不会丢 ✓）。
  ///   这与 `download_service` 那种"适配器里设 UA"的情况**不同** ✓（那里必须传工厂 ✓）。
  /// · 代理**关闭** ✓ → 返回 false ✓ **一字不改** ✓（与从前完全一致 ✓✓）
  static Dio _createDio() {
    final dio = Dio(
      BaseOptions(
        responseType: ResponseType.bytes,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        },
      ),
    );
    applyGlobalProxy(dio);
    return dio;
  }

  final Dio _dio = _createDio();

  /// 进行中的下载（同 URL 去重并发）
  final Map<String, Future<String?>> _pending = {};

  /// 本次运行已失败的 URL，不再重试
  final Set<String> _failed = {};

  Future<Directory> get _dir async {
    final dir = Directory(
      '${(await getTemporaryDirectory()).path}/cover_cache',
    );
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// ✅ **缓存目录（公开只读入口）** ✓ —— 供「缓存上限」按 GB 淘汰复用 ✓。
  ///
  /// 为什么需要它 ✗：设置里的 `onlineComicCacheGb`（在线漫画图片缓存上限 ✓）
  /// **全模块 0 个读取点** ✗ → 拨了没有任何效果 ✓；而容量淘汰必须有目录 ✓。
  /// ✅ 现在由 `CacheCapacity.evictToLimit(await SourceCoverCache().dir, 上限字节)` ✓
  /// 直接在**设置页**完成淘汰 ✓（`_dir` 本身保持私有 ✓，不扩大可变面 ✓）。
  Future<Directory> get dir => _dir;

  /// 封面落地：下载还原后存缓存目录，返回本地绝对路径。
  /// 站点未配还原（非加密/base64）或下载失败返回 null。
  Future<String?> localize(String url, SiteConfig site) async {
    if (!url.startsWith('http')) return null;
    if (!needsRestore(site)) return null;
    if (_failed.contains(url)) return null;
    final running = _pending[url];
    if (running != null) return running;
    final f = _doLocalize(url, site);
    _pending[url] = f;
    try {
      return await f;
    } finally {
      _pending.remove(url);
    }
  }

  /// 站点封面是否需要落地还原（AES 加密或 base64 文本）
  static bool needsRestore(SiteConfig site) =>
      site.imgAesKey.isNotEmpty || site.imgBodyBase64;

  Future<String?> _doLocalize(String url, SiteConfig site) async {
    try {
      final dir = await _dir;
      final key = _cacheKey(url);
      // 已缓存（扩展名未知，逐一探测）
      for (final ext in const ['.jpg', '.png', '.webp', '.gif']) {
        final f = File('${dir.path}${Platform.pathSeparator}$key$ext');
        if (await f.exists()) return f.path;
      }
      final resp = await _dio.get<List<int>>(
        url,
        options: Options(headers: {'Referer': site.url}),
      );
      var bytes = resp.data ?? const <int>[];
      if (bytes.isEmpty) throw Exception('空响应');
      if (site.imgBodyBase64) {
        // 响应体是 base64 文本（bytes 即 ASCII）
        final text = utf8.decode(bytes, allowMalformed: true);
        bytes = base64.decode(text.replaceAll(RegExp(r'\s'), ''));
      }
      final out = restoreImageBytes(bytes, aesKeyBytes(site.imgAesKey));
      final file = File(
        '${dir.path}${Platform.pathSeparator}$key${imageExtOf(out)}',
      );
      await file.writeAsBytes(out, flush: true);
      return file.path;
    } catch (e) {
      _failed.add(url);
      _log('封面落地失败 $url: $e');
      return null;
    }
  }

  /// 缓存键：URL 的 **FNV-1a 64 位**内容哈希（十六进制）。
  ///
  /// 🔴 2026-10-14 改：原来用 `url.hashCode & 0x7fffffff`（有效仅 **31 位**）。
  ///   而 `_doLocalize` 的逻辑是"**文件在就直接返回**"⇒ 两个不同 URL 一旦撞到
  ///   同一个键，第二本漫画会**直接显示第一本的封面** ✗（几千张时约 0.6% 概率）。
  ///   换成 64 位内容哈希后碰撞概率可忽略；键与 URL 内容一一对应、跨运行稳定。
  /// ⚠️ 副作用：升级后旧键文件成为孤儿（在 Caches 里，会被系统回收），封面会
  ///   重下一遍 —— 纯粹是缓存，无数据风险。
  String _cacheKey(String url) {
    var hash = 0xcbf29ce484222325; // FNV-1a 64 位 offset basis
    for (final b in utf8.encode(url)) {
      hash ^= b;
      hash = hash * 0x100000001b3; // 溢出按 64 位回绕（Dart int 语义）
    }
    // 取 63 位非负：`toRadixString` 对负数会输出 '-' 前缀，直接去掉会让
    // `x` 与 `-x` 落到同一个键（反而制造碰撞）⇒ 这里先抹掉符号位。
    final h = hash & 0x7FFFFFFFFFFFFFFF;
    return h.toRadixString(16).padLeft(16, '0');
  }
}
