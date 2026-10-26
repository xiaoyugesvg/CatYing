import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'package:tvbox/services/app_log.dart';

/// 一个「随机图片源」。
///
/// 这类 API 的特点是：**每次请求返回一张随机图**（要么直接返回图片字节，
/// 要么 302 跳到图片）。所以它们**不能**像 Bing/Picsum 那样"拉一个列表"，
/// 只能"点一次取一张"。
class RandomImageSource {
  const RandomImageSource({
    required this.id,
    required this.name,
    required this.url,
    this.group = '',
    this.note = '',
    /// 实测可用性：true = 直接可用；false = 服务端不稳定（见 [note]）
    this.reliable = true,
  });

  final String id;

  /// 显示名（如「风景大片」）
  final String name;

  /// 随机图 API 地址
  final String url;

  /// 分组（如「樱道随机图」）
  final String group;

  /// 备注（实测情况）
  final String note;

  /// 实测是否稳定
  final bool reliable;
}

/// 随机图片源目录。
///
/// ── 这些地址是**实测**过的（2026），不是照抄列表 ──────────────────
/// 三类行为：
///   ✅ **直接返回图片字节**（`image/jpeg` / `image/webp`）—— 最理想
///   ✅ **302/301 跳到图片** —— 也能用（Dio 跟随重定向后拿到图片）
///   ⚠️ **HTTP 200 + 空响应体** —— 服务端限流/无图时这么返回，**客户端无法修复**
///
/// 实测明细（带浏览器 UA、跟随重定向）：
///   api.elaina.cat/random/mobile      301 → image/jpeg        ✅
///   pic.elvish.me/pe                  302 → image/webp        ✅
///   api.r10086.com/…樱道随机图片…      302 → image/webp        ✅
///   api.zylearning.top/api/wallpaper?lx=*   时而 image/jpeg、
///                                     时而 **200 + 空 HTML**  ⚠️
///
/// ⚠️ zylearning 那 12 个类别是**服务端不稳定**（同一类别连测两次结果不同），
/// 不是本 App 的问题。所以在 [WallpaperRandomService] 里做了**重试**：
/// 空响应/Center 非图片时换一次重试，多数情况下能拿到图。
class RandomImageCatalog {
  RandomImageCatalog._();

  /// 分组名 → 该组下的源
  static const String groupZy = '梓韵壁纸';
  static const String groupR10086 = '樱道随机图';
  static const String groupOther = '其它';

  static const List<RandomImageSource> all = [
    // ── 实测直接可用、且稳定 ──────────────────────────────────
    RandomImageSource(
      id: 'elaina',
      name: 'Elaina',
      url: 'https://api.elaina.cat/random/mobile',
      group: groupOther,
      note: '301 → image/jpeg，实测稳定',
    ),
    RandomImageSource(
      id: 'elvish',
      name: 'Elvish',
      url: 'https://pic.elvish.me/pe',
      group: groupOther,
      note: '302 → image/webp，实测稳定',
    ),

    // ── 梓韵壁纸（12 个类别；服务端偶发返回空响应）──────────────
    RandomImageSource(
        id: 'zy_4k', name: '4K壁纸',
        url: 'https://api.zylearning.top/api/wallpaper?lx=4k', group: groupZy,
        note: '服务端偶发空响应，已加重试', reliable: false),
    RandomImageSource(
        id: 'zy_mnmt', name: '美女模特',
        url: 'https://api.zylearning.top/api/wallpaper?lx=mnmt', group: groupZy,
        note: '服务端偶发空响应，已加重试', reliable: false),
    RandomImageSource(
        id: 'zy_aqmt', name: '爱情美图',
        url: 'https://api.zylearning.top/api/wallpaper?lx=aqmt', group: groupZy,
        note: '服务端偶发空响应，已加重试', reliable: false),
    RandomImageSource(
        id: 'zy_fj', name: '风景大片',
        url: 'https://api.zylearning.top/api/wallpaper?lx=fj', group: groupZy,
        note: '服务端偶发空响应，已加重试', reliable: false),
    RandomImageSource(
        id: 'zy_dm', name: '动漫壁纸',
        url: 'https://api.zylearning.top/api/wallpaper?lx=dm', group: groupZy,
        note: '服务端偶发空响应，已加重试', reliable: false),
    RandomImageSource(
        id: 'zy_mx', name: '明星壁纸',
        url: 'https://api.zylearning.top/api/wallpaper?lx=mx', group: groupZy,
        note: '服务端偶发空响应，已加重试', reliable: false),
    RandomImageSource(
        id: 'zy_dw', name: '萌宠动物',
        url: 'https://api.zylearning.top/api/wallpaper?lx=dw', group: groupZy,
        note: '服务端偶发空响应，已加重试', reliable: false),
    RandomImageSource(
        id: 'zy_yx', name: '游戏壁纸',
        url: 'https://api.zylearning.top/api/wallpaper?lx=yx', group: groupZy,
        note: '服务端偶发空响应，已加重试', reliable: false),
    RandomImageSource(
        id: 'zy_qc', name: '汽车壁纸',
        url: 'https://api.zylearning.top/api/wallpaper?lx=qc', group: groupZy,
        note: '服务端偶发空响应，已加重试', reliable: false),
    RandomImageSource(
        id: 'zy_ss', name: '炫酷时尚',
        url: 'https://api.zylearning.top/api/wallpaper?lx=ss', group: groupZy,
        note: '服务端偶发空响应，已加重试', reliable: false),
    RandomImageSource(
        id: 'zy_ysjz', name: '影视剧照',
        url: 'https://api.zylearning.top/api/wallpaper?lx=ysjz', group: groupZy,
        note: '服务端偶发空响应，已加重试', reliable: false),

    // ── 樱道随机图（URL 里的中文必须百分号编码）──────────────────
    RandomImageSource(
      id: 'r10086_umamusume',
      name: '赛马娘',
      url: 'https://api.r10086.com/%E6%A8%B1%E9%81%93%E9%9A%8F%E6%9C%BA%E5%9B%BE%E7%89%87api%E6%8E%A5%E5%8F%A3.php?%E5%9B%BE%E7%89%87%E7%B3%BB%E5%88%97=%E8%B5%9B%E9%A9%AC%E5%A8%98',
      group: groupR10086,
      note: '302 → image/webp，实测稳定',
    ),
    RandomImageSource(
      id: 'r10086_loli',
      name: '死库水萝莉',
      url: 'https://api.r10086.com/%E6%A8%B1%E9%81%93%E9%9A%8F%E6%9C%BA%E5%9B%BE%E7%89%87api%E6%8E%A5%E5%8F%A3.php?%E5%9B%BE%E7%89%87%E7%B3%BB%E5%88%97=%E6%AD%BB%E5%BA%93%E6%B0%B4%E8%90%9D%E8%8E%89',
      group: groupR10086,
      note: '302 → image/webp，实测稳定',
    ),
    RandomImageSource(
      id: 'r10086_girl',
      name: '少女写真',
      url: 'https://api.r10086.com/%E6%A8%B1%E9%81%93%E9%9A%8F%E6%9C%BA%E5%9B%BE%E7%89%87api%E6%8E%A5%E5%8F%A3.php?%E5%9B%BE%E7%89%87%E7%B3%BB%E5%88%97=%E5%B0%91%E5%A5%B3%E5%86%99%E7%9C%9F1',
      group: groupR10086,
      note: '302 → image/webp，实测稳定',
    ),
    RandomImageSource(
      id: 'r10086_onepiece',
      name: '海贼王',
      url: 'https://api.r10086.com/%E6%A8%B1%E9%81%93%E9%9A%8F%E6%9C%BA%E5%9B%BE%E7%89%87api%E6%8E%A5%E5%8F%A3.php?%E5%9B%BE%E7%89%87%E7%B3%BB%E5%88%97=%E6%B5%B7%E8%B4%BC%E7%8E%8B',
      group: groupR10086,
      note: '302 → image/webp，实测稳定',
    ),
  ];

  static RandomImageSource? byId(String id) {
    for (final s in all) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 按分组返回（保持定义顺序）
  static Map<String, List<RandomImageSource>> grouped() {
    final out = <String, List<RandomImageSource>>{};
    for (final s in all) {
      out.putIfAbsent(s.group, () => []).add(s);
    }
    return out;
  }
}

/// 一次随机取图的结果
class RandomImageResult {
  const RandomImageResult({required this.ok, this.bytes, this.error = ''});
  final bool ok;
  final Uint8List? bytes;
  final String error;
}

/// 随机图片源 ↓ 取图服务。
///
/// ── 为什么不用 `_getText` 那一套 ─────────────────────────────────
/// `WallpaperApiService` 是**列表型**源（Bing/Picsum 返回 JSON），
/// 它用 `ResponseType.plain` 读文本。而随机图源**返回的是二进制图片**，
/// 用文本读会坏掉（而且 Dio 拿到 HTML 空响应时还会当成"成功"）。
///
/// 所以这里单独一套：`ResponseType.bytes` + **Content-Type 校验** + 重试。
class WallpaperRandomService {
  WallpaperRandomService._();
  static final WallpaperRandomService instance = WallpaperRandomService._();

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 25),
    // 跟随 301/302：上面实测有 3 个源靠重定向才拿到图片
    followRedirects: true,
    maxRedirects: 6,
    responseType: ResponseType.bytes,
    validateStatus: (c) => c != null && c < 400,
    headers: {
      // 多个源对空 UA 直接返回空响应
      'User-Agent':
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
              'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
      'Accept': 'image/avif,image/webp,image/jpeg,image/png,*/*;q=0.8',
    },
  ));

  /// 取一张随机图。
  ///
  /// [attempts]：zylearning 那批**服务端偶发返回 200 + 空响应**，
  /// 多试两次多数能拿到图。默认 3 次。
  ///
  /// 校验逻辑（关键）：
  ///   · 响应体为空 → 失败（zylearning 的典型表现）
  ///   · Content-Type 不是 image/* **且** 字节头不是图片魔数 → 失败
  ///     （只看 CT 会误杀：樱道返回 `image/webp` 但有些 CDN 给
  ///      `application/octet-stream`；只看魔数又会把 HTML 错误页当图）
  Future<RandomImageResult> fetchOne(
    RandomImageSource source, {
    int attempts = 3,
  }) async {
    Object? lastErr;
    for (var i = 0; i < attempts; i++) {
      try {
        final res = await _dio.get<List<int>>(source.url);
        final data = res.data;
        if (data == null || data.isEmpty) {
          lastErr = '服务端返回空响应（第 ${i + 1} 次）';
          AppLog.instance.log(
              '[WallpaperRandom] ${source.id} 空响应 attempt=${i + 1}');
          await Future<void>.delayed(Duration(milliseconds: 250 * (i + 1)));
          continue;
        }
        final bytes = Uint8List.fromList(data);
        final ct = (res.headers.value('content-type') ?? '').toLowerCase();
        final looksImage = _looksLikeImage(bytes);
        if (!ct.startsWith('image/') && !looksImage) {
          lastErr = '返回的不是图片（$ct）';
          AppLog.instance.log(
              '[WallpaperRandom] ${source.id} 非图片 ct=$ct attempt=${i + 1}');
          await Future<void>.delayed(Duration(milliseconds: 250 * (i + 1)));
          continue;
        }
        AppLog.instance.log(
            '[WallpaperRandom] ${source.id} OK ${bytes.length} bytes ct=$ct'
            ' attempt=${i + 1}');
        return RandomImageResult(ok: true, bytes: bytes);
      } catch (e) {
        lastErr = e;
        AppLog.instance.log(
            '[WallpaperRandom] ${source.id} 异常 attempt=${i + 1}: $e');
        await Future<void>.delayed(Duration(milliseconds: 300 * (i + 1)));
      }
    }
    return RandomImageResult(ok: false, error: '$lastErr');
  }

  /// 图片魔数检测（覆盖 jpg/png/gif/webp/bmp/avif）
  static bool _looksLikeImage(Uint8List b) {
    if (b.length < 12) return false;
    // JPEG: FF D8 FF
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return true;
    // PNG: 89 50 4E 47
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return true;
    // GIF: 47 49 46 38
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38) return true;
    // BMP: 42 4D
    if (b[0] == 0x42 && b[1] == 0x4D) return true;
    // WEBP: RIFF....WEBP
    if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      return true;
    }
    // AVIF/HEIF: ....ftyp
    if (b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70) return true;
    return false;
  }
}
