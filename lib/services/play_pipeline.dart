// lib/services/play_pipeline.dart
//
// 统一播放判定（播放地址路由的**单一事实来源**）。
//
// 判定结果三种：
//   ① 媒体直链 → 交给 App 自己的原生播放器；
//   ② 网页地址 → `PlayKind.page`。**影视模块拿到 page 就拒绝播放**
//      （2026-10-29 用户要求：影视不内嵌 WebView）；小程序等模块可以自行
//      决定怎么用（例如交给网页播放页）。
//   ③ 漫画 / 小说协议 → 交给对应的简易阅读器。
//
// 不做任何地址提取：网页里的播放由网页自己完成。
library;

import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/platform_domains.dart';
import 'package:tvbox/services/play_route.dart';
import 'package:tvbox/services/play_url_sanitizer.dart';

/// 影视模块拒绝网页地址时的统一文案。
///
/// 影视模块（详情页 / 短剧 / 媒体库）只播媒体直链，**不允许**把网页地址
/// 内嵌进 WebView 播放（2026-10-29 用户要求）。其它模块（RSS / 小程序 /
/// 海阔 / 阅读 / 音乐）不受影响，仍可打开网页播放页。
const String kMovieWebUrlRejected =
    '这个地址是网页而不是视频直链，影视模块不支持网页播放，请切换线路或换源';

/// 取址结果的内容形态。
enum PlayKind {
  /// 可直接交给原生播放器
  media,

  /// 网页地址 —— 影视模块会拒绝播放；其它模块可自行处理
  page,

  /// `novel://` 正文
  novel,

  /// `pics://` 图片列表
  pictures,
}

/// 网页地址的**解析选路**：这条地址该按哪种方式去解析。
///
/// ── 为什么需要它（2026-10-31）──────────────────────────────────
/// `MediaResolver` 原来对任何网页地址都「先抓 HTML，再试解析线路」。
/// 对爱奇艺 / 腾讯 / B站 这类 **SPA 页面**，抓 HTML 永远只拿到一个空壳
/// —— 白等 8 秒超时、还要重试 3 轮，才轮到真正能用的解析线路。
/// 选路把这件事提前分开：平台页直接上线路，不浪费预算。
enum PlayRoute {
  /// 已经是媒体直链（或小说 / 图片协议），不需要任何解析
  direct,

  /// 长视频平台页（爱奇艺 / 优酷 / 腾讯 / 芒果 / B站 / PPTV）
  /// —— 页面靠 JS 渲染，抓 HTML 一定空手，只能走解析线路
  platform,

  /// 已经套过解析接口的地址（`jx.xx/?url=<原始地址>`）
  /// —— 它本身就是一条线路，先直接请求它
  parseUrl,

  /// 普通播放页（服务端渲染，HTML 里通常就有地址）
  plainPage,
}

class PlayResolution {
  final String url;
  final PlayKind kind;
  final Map<String, String> headers;

  /// 该地址的解析选路（[PlayKind.page] 时有意义；媒体直链恒为
  /// [PlayRoute.direct]）。
  final PlayRoute route;

  const PlayResolution({
    required this.url,
    required this.kind,
    this.headers = const {},
    this.route = PlayRoute.direct,
  });

  bool get isMedia => kind == PlayKind.media;
  bool get isPage => kind == PlayKind.page;
}

class PlayPipeline {
  PlayPipeline._();
  static final PlayPipeline instance = PlayPipeline._();

  /// 清洗并判定 [rawUrl] 该怎么播。
  ///
  /// [apiBase] 用于把相对播放地址按源站 origin 补全。
  PlayResolution resolve(
    String rawUrl, {
    Map<String, String>? headers,
    String? apiBase,
    bool trustMedia = false,
  }) {
    final h = <String, String>{...?headers};
    final raw = rawUrl.trim();
    if (raw.isEmpty) {
      return PlayResolution(
        url: raw,
        kind: PlayKind.page,
        headers: h,
        route: PlayRoute.plainPage,
      );
    }

    // ① 非视频协议：漫画 / 小说（交给阅读器）
    final novel = parseNovelUrl(raw);
    if (novel != null && novel.content.trim().isNotEmpty) {
      return PlayResolution(url: raw, kind: PlayKind.novel, headers: h);
    }
    final pictures = parseImageListUrl(raw);
    if (pictures != null && pictures.isNotEmpty) {
      return PlayResolution(url: raw, kind: PlayKind.pictures, headers: h);
    }

    // ② 清洗 + 补全
    var candidate = sanitizePlayUrl(raw);
    candidate = absolutize(candidate, apiBase);
    final route = routeFor(candidate);

    // ── 平台页 / 解析接口地址：一定是网页，不能当媒体 ──────────────
    // 这两类地址经常"看起来像直链"，以前会被下面的 trustMedia 分支当成
    // 媒体丢给播放器，结果是白卡 15 秒再报「加载超时」：
    //   · B站 `bilibili.com/video/BVxxx/`、腾讯 cover 页 —— 没有 .html 后缀；
    //   · 解析接口 `jx.xx/?url=...` —— 路径就是个 `/`。
    // ⚠️ 但平台 **CDN** 域名是真媒体（`apd-xxx.v.qq.com/xxx.mp4`，
    // `host.endsWith('.v.qq.com')` 会命中平台规则），所以只在"确实不像
    // 媒体"时才拦。
    if (route == PlayRoute.platform || route == PlayRoute.parseUrl) {
      if (!looksLikeDirectMedia(candidate) && !_hasAudioExt(candidate)) {
        AppLog.instance.log(
          '[PlayPipeline] ${routeLabel(route)}，交给解析: $candidate',
        );
        return PlayResolution(
          url: candidate,
          kind: PlayKind.page,
          headers: h,
          route: route,
        );
      }
    }

    // ── Spider / JS 源已解析出的直链：直接当媒体（用户 2026-10-29 选定）──
    // JS / 爬虫源会把"真实播放地址"解析出来，但形态常无 .m3u8/.mp4 后缀
    // （token / 重定向端点），`looksLikeDirectMedia` 认不出就误判成网页、
    // 被影视模块拒绝。此处 spider 来源时直接当媒体交给原生播放器；但仍排除
    // 明显是 HTML 页面的地址（保留"影视不内嵌 WebView"约定——真网页不会进
    // 播放器，只会因加载失败报错，不会渲染 HTML）。
    if (trustMedia && isPlayableShape(candidate) && !_isWebPage(candidate)) {
      return PlayResolution(url: candidate, kind: PlayKind.media, headers: h);
    }

    // ③ 直链 → 原生播放器
    if (looksLikeDirectMedia(candidate)) {
      return PlayResolution(url: candidate, kind: PlayKind.media, headers: h);
    }
    // 音频直链同样交给原生播放器
    if (_hasAudioExt(candidate)) {
      return PlayResolution(url: candidate, kind: PlayKind.media, headers: h);
    }

    AppLog.instance.log(
      '[PlayPipeline] 判定为网页地址（${routeLabel(route)}）: $candidate',
    );
    return PlayResolution(
      url: candidate,
      kind: PlayKind.page,
      headers: h,
      route: route,
    );
  }

  /// 纯判定、无副作用：这条网页地址该走哪种解析。
  ///
  /// 顺序有讲究 —— `parseUrl` 要在 `platform` 之前判：
  /// `jx.muiu.site/?url=https://v.qq.com/...` 的 host 是解析站，不是平台，
  /// 但里面的 `?url=` 才是平台页；这种地址**整条**就是一次解析请求，
  /// 直接请求它即可，不必再去套一条线路。
  static PlayRoute routeFor(String rawUrl) {
    final u = rawUrl.trim();
    if (u.isEmpty) return PlayRoute.plainPage;
    if (looksLikeParseUrl(u)) return PlayRoute.parseUrl;
    if (isVideoPlatformUrl(u)) return PlayRoute.platform;
    return PlayRoute.plainPage;
  }

  /// 给日志 / 界面提示看的一句话
  static String routeLabel(PlayRoute route) {
    switch (route) {
      case PlayRoute.direct:
        return '直链';
      case PlayRoute.platform:
        return '平台页，走解析线路';
      case PlayRoute.parseUrl:
        return '已套解析接口，直接请求';
      case PlayRoute.plainPage:
        return '普通播放页';
    }
  }

  /// 相对播放地址按源站点的 **origin** 补全（TVBox 既有约定）。
  static String absolutize(String raw, String? apiBase) {
    final s = raw.trim();
    if (s.isEmpty || isPlayableShape(s)) return s;
    final base = (apiBase ?? '').trim();
    if (base.isEmpty) return s;
    final bu = Uri.tryParse(base);
    if (bu == null || !bu.hasScheme) return s;
    try {
      final origin = '${bu.scheme}://${bu.authority}/';
      return Uri.parse(origin).resolve(s).toString();
    } catch (_) {
      return s;
    }
  }

  /// 是否"能交给播放器"的地址形态（有 scheme，含内容协议）。
  static bool isPlayableShape(String url) {
    final raw = url.trim();
    if (raw.isEmpty) return false;
    final lower = raw.toLowerCase();
    for (final p in kPlayablePrefixes) {
      if (lower.startsWith(p)) return true;
    }
    final u = Uri.tryParse(raw);
    return u != null && u.hasScheme;
  }

  /// 明显是 HTML 网页地址（路径以网页后缀结尾）——这类仍按"网页"处理，
  /// 不交给原生播放器，保留"影视不内嵌 WebView"的约定。
  static const List<String> _kWebPageExtensions = [
    '.html', '.htm', '.php', '.asp', '.aspx', '.jsp', '.shtml',
  ];
  static bool _isWebPage(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    for (final ext in _kWebPageExtensions) {
      if (path.endsWith(ext)) return true;
    }
    return false;
  }

  /// 地址里是否含已知音频后缀（m4a / mp3 / aac …）
  static bool _hasAudioExt(String url) {
    final lower = url.toLowerCase();
    for (final ext in kAudioExtensions) {
      if (lower.contains(ext)) return true;
    }
    return false;
  }

  static const List<String> kPlayablePrefixes = [
    'http://', 'https://', 'rtmp://', 'rtsp://', 'mms://',
    'x5://', 'novel://', 'pics://', 'mange://', 'manga://',
    'magnet:', 'ed2k://', 'thunder://', 'ftp://', 'file://',
  ];
}
