import 'dart:convert';

import 'package:dio/dio.dart';

import 'package:tvbox/services/app_log.dart';

/// 一张在线壁纸
class WallpaperItem {
  /// 缩略图地址（列表用，务必是小图）
  final String thumbUrl;

  /// 原图地址（设为背景用）
  final String fullUrl;

  final String title;
  final String subtitle;

  const WallpaperItem({
    required this.thumbUrl,
    required this.fullUrl,
    this.title = '',
    this.subtitle = '',
  });
}

/// 壁纸源类型（可插拔）
enum WallpaperProvider {
  /// Bing 每日一图：每天一张、质量高、带中文图说
  bingDaily,

  /// Picsum：海量随机摄影图，可分页
  picsum,

  /// 用户自建 API（返回 JSON，字段可配置）
  custom,
}

/// 在线壁纸源服务
///
/// 为什么是「可插拔」而不是写死一个源：
/// 实测 Wallhaven 在国内直接不可达（HTTP 000），Pexels/Unsplash 需要 Key。
/// 不同网络环境下可用源不同，所以内置两个可达源，并留出 custom 让用户
/// 填自己的 API —— 将来接入自建壁纸库时无需改动 App。
class WallpaperApiService {
  WallpaperApiService._();
  static final WallpaperApiService instance = WallpaperApiService._();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 20),
    headers: {
      // 部分源（Bing）对空 UA 返回 403
      'User-Agent':
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15',
    },
  ));

  /// 抓取壁纸列表。失败返回空列表（不抛，由 UI 显示空态）。
  Future<List<WallpaperItem>> fetch(
    WallpaperProvider provider, {
    int page = 1,
    String customUrl = '',
  }) async {
    try {
      switch (provider) {
        case WallpaperProvider.bingDaily:
          return await _fetchBing();
        case WallpaperProvider.picsum:
          return await _fetchPicsum(page);
        case WallpaperProvider.custom:
          return await _fetchCustom(customUrl, page);
      }
    } catch (e) {
      AppLog.instance.log('[WallpaperApi] fetch($provider, page=$page) 失败: $e');
      return const [];
    }
  }

  /// 带重试的文本 GET。
  ///
  /// 实测 Wallhaven 在国内直接不可达，而 Bing 偶发
  /// `HandshakeException: Connection terminated during handshake`（换个时刻
  /// 重试即成功）。一次性握手抖动不该让用户看到"加载失败"，故重试。
  Future<String> _getText(
    String url, {
    Map<String, dynamic>? query,
    int retries = 2,
  }) async {
    Object? last;
    for (var attempt = 0; attempt <= retries; attempt++) {
      try {
        final res = await _dio.get<String>(
          url,
          queryParameters: query,
          options: Options(responseType: ResponseType.plain),
        );
        return res.data ?? '';
      } catch (e) {
        last = e;
        if (attempt < retries) {
          await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
        }
      }
    }
    AppLog.instance.log('[WallpaperApi] $url 重试 $retries 次仍失败: $last');
    return '';
  }

  // ============================================================
  // Bing 每日一图
  // ============================================================

  /// 响应对应 `images[]`，字段：url(相对) / title / copyright / startdate
  Future<List<WallpaperItem>> _fetchBing() async {
    final body = await _getText(
      'https://www.bing.com/HPImageArchive.aspx',
      query: {'format': 'js', 'idx': '0', 'n': '8', 'mkt': 'zh-CN'},
    );
    if (body.isEmpty) return const [];
    final decoded = jsonDecode(body);
    if (decoded is! Map || decoded['images'] is! List) return const [];

    final items = <WallpaperItem>[];
    for (final raw in decoded['images'] as List) {
      if (raw is! Map) continue;
      final rel = (raw['url'] ?? '').toString();
      if (rel.isEmpty) continue;
      final full = rel.startsWith('http') ? rel : 'https://www.bing.com$rel';
      // ⚠️ Bing 不提供动态缩略图：实测 urlbase + &w=400&h=600、urlbase.jpg、
      // _400x600.jpg 等变体全部 404，只有完整 1920×1080（约 334KB）可取。
      // 故 thumb == full，由列表侧用 memCacheWidth 限制解码尺寸来控制内存。
      items.add(WallpaperItem(
        thumbUrl: full,
        fullUrl: full,
        title: (raw['title'] ?? '').toString(),
        subtitle: (raw['copyright'] ?? '').toString(),
      ));
    }
    AppLog.instance.log('[WallpaperApi] Bing 每日: ${items.length} 张');
    return items;
  }

  // ============================================================
  // Picsum
  // ============================================================

  /// 响应是数组，元素含 id / author / width / height / download_url。
  ///
  /// ⚠️ download_url 是**原图**（常见 5000×3333 ≈ 60MB 解码位图），
  /// 列表缩略图绝不能直接用它，否则 iOS 上极易 OOM。
  /// 这里用 `picsum.photos/id/{id}/400/600` 生成小图。
  Future<List<WallpaperItem>> _fetchPicsum(int page) async {
    final body = await _getText(
      'https://picsum.photos/v2/list',
      query: {'page': '$page', 'limit': '30'},
    );
    if (body.isEmpty) return const [];
    final decoded = jsonDecode(body);
    if (decoded is! List) return const [];

    final items = <WallpaperItem>[];
    for (final raw in decoded) {
      if (raw is! Map) continue;
      final id = (raw['id'] ?? '').toString();
      if (id.isEmpty) continue;
      final w = (raw['width'] as num?)?.toInt() ?? 0;
      final h = (raw['height'] as num?)?.toInt() ?? 0;
      items.add(WallpaperItem(
        // 竖屏壁纸比例取 2:3，与手机屏幕接近，减少设为背景后的裁切
        thumbUrl: 'https://picsum.photos/id/$id/400/600',
        // 原图限制到 1600 宽，兼顾清晰度与内存
        fullUrl: 'https://picsum.photos/id/$id/1600/2400',
        title: (raw['author'] ?? '').toString(),
        subtitle: (w > 0 && h > 0) ? '$w×$h' : '',
      ));
    }
    AppLog.instance.log('[WallpaperApi] Picsum page=$page: ${items.length} 张');
    return items;
  }

  // ============================================================
  // 自定义 API
  // ============================================================

  /// 用户自建壁纸 API。约定返回 JSON：
  ///
  /// ```json
  /// { "list": [ { "thumb": "...", "url": "...", "title": "...", "subtitle": "..." } ] }
  /// ```
  ///
  /// 也兼容顶层直接是数组、以及 `data` / `images` 作为列表字段名，
  /// 图片字段兼容 thumb/thumbnail/small 与 url/full/original/src。
  Future<List<WallpaperItem>> _fetchCustom(String url, int page) async {
    if (url.trim().isEmpty) return const [];
    final target = url.contains('{page}')
        ? url.replaceAll('{page}', '$page')
        : url;
    final body = await _getText(target);
    if (body.isEmpty) return const [];
    final decoded = jsonDecode(body);

    List<dynamic> list;
    if (decoded is List) {
      list = decoded;
    } else if (decoded is Map) {
      final candidate = decoded['list'] ??
          decoded['data'] ??
          decoded['images'] ??
          decoded['results'];
      list = candidate is List ? candidate : const [];
    } else {
      return const [];
    }

    String pick(Map m, List<String> keys) {
      for (final k in keys) {
        final v = m[k];
        if (v is String && v.isNotEmpty) return v;
      }
      return '';
    }

    final items = <WallpaperItem>[];
    for (final raw in list) {
      if (raw is! Map) continue;
      final full = pick(raw, const ['url', 'full', 'original', 'src']);
      if (full.isEmpty) continue;
      final thumb = pick(raw, const ['thumb', 'thumbnail', 'small']);
      items.add(WallpaperItem(
        thumbUrl: thumb.isNotEmpty ? thumb : full,
        fullUrl: full,
        title: pick(raw, const ['title', 'name', 'author']),
        subtitle: pick(raw, const ['subtitle', 'copyright', 'desc']),
      ));
    }
    AppLog.instance.log('[WallpaperApi] custom page=$page: ${items.length} 张');
    return items;
  }
}
