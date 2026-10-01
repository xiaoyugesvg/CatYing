import 'package:cached_network_image_ce/cached_network_image.dart'
    show CacheManager;
// ⚠️ 必须直接 import **实现文件**而不是走
// `default_cache_manager_factory.dart`：
// 那个工厂是条件导出，在非 io 平台会换成 `default_cache_manager_stub.dart`，
// 而 **stub 版的构造函数没有 `httpInterceptors` 参数**（它只是"不支持的
// 平台"占位，一实例化就 throw）。本项目只出 iOS，走 io 分支，
// 所以直接引实现文件是对的。
// ignore: implementation_imports
import 'package:cached_network_image_ce/src/cache/default_cache_manager.dart';
// ignore: implementation_imports
import 'package:cached_network_image_ce/src/cache/interceptors/http_interceptor.dart';

/// 全 App **统一的图片缓存管理器**（A2 合并的产物）。
///
/// ── 背景：原来有两条平行的图片缓存链 ──────────────────────────
///   · `cached_network_image` 3.3.1      → 音乐 + 阅读（15 个文件）
///   · `cached_network_image_ce` 4.13.1  → 影视 + 直播（8 个文件）
///
/// 两套完整实现同时编译进 App，各自维护磁盘缓存 —— 同一个网络图
/// 在两个模块会**存两份**，缓存池也不共享。
///
/// ── 为什么统一到 `_ce` 而不是反过来 ─────────────────────────────
///   1. `_ce` 版本更新（4.13.1 vs 3.3.1）
///   2. `_ce` 用 **`hive_ce`** 做缓存索引（本项目已经是 `hive_ce` 直接依赖），
///      而 std 版依赖 `flutter_cache_manager`
///   3. `_ce` 提供 **HTTP / Cache 拦截器**机制（下面那个 UA 修复靠它）
///   4. 参数名完全兼容（`imageUrl`/`fit`/`placeholder`/`errorWidget`/
///      `httpHeaders`/`memCacheWidth`/`cacheManager` 都有）
///
/// ── ⚠️ 保住了原来那个 UA 修复（很重要，不能丢）──────────────────
/// 原 `reading/source/image_cache_manager.dart` 的注释记录了原因：
///   `dart:io HttpClient` **跨域重定向时不保留 `req.headers` 里的 User-Agent**，
///   改用 `client.userAgent`。而 `flutter_cache_manager` 只设 `req.headers`，
///   导致重定向后 UA 退化成 `Dart/xxx` → 某些 CDN 判为 bot **直接 403**
///   （实测 lmanhua `g-mh.online` 301 到 `c-nd3-1.6wm.top` 后 403）。
///
/// `_ce` 没有"设置 client.userAgent"的入口，但它有
/// **`HttpInterceptor.onRequest`** —— 每次请求（含重定向后的新请求）
/// 都能改 headers。所以这里用拦截器统一注入浏览器 UA。
///
/// ⚠️ 拦截器**只在调用方没显式给 User-Agent 时才注入** ——
/// 否则会覆盖各漫画源自己配的 UA（有些源必须带特定 UA 才通）。
final DefaultCacheManager appImageCacheManager = DefaultCacheManager(
  httpInterceptors: const [_BrowserUaInterceptor()],
);

/// 给每个图片请求注入浏览器 UA（见文件头说明）
class _BrowserUaInterceptor extends HttpInterceptor {
  const _BrowserUaInterceptor();

  /// 与原先 `comicImageCacheManager` 里的 UA 保持一致
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  @override
  void onRequest(HttpRequestData request, HttpRequestHandler handler) {
    // 大小写不敏感地判断调用方是否已给 UA
    final hasUa = request.headers.keys.any(
      (k) => k.toLowerCase() == 'user-agent',
    );
    if (!hasUa) request.headers['User-Agent'] = _ua;
    handler.next(request);
  }
}
