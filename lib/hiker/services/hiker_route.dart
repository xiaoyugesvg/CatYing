/// 「海阔」链接协议分流 —— **依据海阔官方源码与官方文档**建立。
///
/// 权威来源（本机 hikerView 开源副本）：
///   · `ui/home/ArticleListFragment.java` → `dealWithUrl()`：点条目后的**分流顺序**
///   · `ui/browser/model/UrlDetector.java` → `isImage()` / `isVideoOrMusic()`：判定规则
///   · `app/src/main/assets/help_link.json` → 官方**全部链接协议**清单
///
/// ── 为什么必须单独一层（这是本轮查出来的真实缺口）────────────────
/// 海阔的"播放地址"**根本不只有 http 视频**，官方 `help_link.json` 里明确还有：
///   · `pics://图1&&图2`   —— 多图模式（类似漫画），下拉自动下一章
///   · `toast://文本`      —— 只弹提示
///   · `copy://内容`       —— 复制到剪贴板
///   · `x5Play://http://…` —— 强制用播放器播
///   · `video://https://…` —— 进播放器自动提取视频
///   · `javascript:…` / `web://` / `x5://` —— 各种网页
/// 之前我们只有"直链 / 网页"两分支，于是漫画、小说、提示类条目一律被丢给
/// WebView，表现就是**打开是一片空白或一堆乱码**。
///
/// ── 单一事实来源 ────────────────────────────────────────────
/// 图片列表（`pics://`）与正文（`novel://`）的解析**复用影视侧同一实现**
/// （`play_route.parseImageListUrl` / `parseNovelUrl`），不在这里再写一份，
/// 避免两边漂移。
library;

import 'dart:convert';

import '../../services/play_route.dart' as play_route;
import '../../services/sniff_filter.dart';

/// 链接类别 —— 与官方 [dealWithUrl] 的分支一一对应（顺序也照抄官方）。
enum HikerLinkKind {
  /// `hiker://…` 官方内部页面（二级页面 / 设置 / 搜索 / 收藏…），本模块不支持跳转
  hikerPage,

  /// `javascript:` 官方叫"彩蛋模式"，点击后跳浏览器执行这段 JS
  js,

  /// `pics://图1&&图2` 多图模式（类似漫画）
  pics,

  /// `novel://{title,content}` 正文（项目内 TVBox 约定，与 pics 同一层处理）
  novel,

  /// 图片地址（官方 `UrlDetector.isImage` 的后缀集合）→ 图集/大图预览
  image,

  /// 影视直链（当前生效清单，见 [SniffFilter.isDirectMedia]）→ 原生播放器
  media,

  /// 海阔的**播放地址 JSON**（`{"urls":[…],"headers":{…}}`）—— 见 [hikerPlayJson]。
  /// 里面可能是直链（→ 播放器）也可能是网页（→ 内嵌 WebView）。
  playJson,

  /// `x5://` / `x5WebView://` —— X5 全屏网页
  x5,

  /// `web://` —— 强制网页，忽略二级解析规则
  web,

  /// `x5Play://http://…` —— 强制用播放器播该地址
  x5Play,

  /// `video://https://…` —— 官方行为是进播放器**自动提取**网页里的视频
  videoSniff,

  /// `toast://文本` —— 只弹提示
  toast,

  /// `copy://内容` —— 复制到剪贴板
  copyLink,

  /// `download://http://…` —— 直接下载
  download,

  /// `magnet:` / `thunder` / `ftp` / `ed2k` —— 交给第三方软件
  external,

  /// `.apk` 安装包
  apk,

  /// 普通 http(s) 网页
  http,

  /// 官方兜底也是 `Toast("未知链接：" + url)`
  unknown,
}

/// 官方 `UrlDetector` 的**图片后缀**集合（原样照抄，含它的大小写重复项）。
///
/// ⚠️ 与 [SniffFilter.mediaExtensions] **不重叠**：那是"影视直链"（视频+音频，
/// 用户可自定义）；这里只判"这是不是一张图"，用来决定进图集阅读器还是播放器。
const List<String> kHikerImageExtensions = [
  '.ico',
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
];

/// 该地址是不是图片（官方 `UrlDetector.isImage` 的等价实现）。
///
/// 官方这里有三个前置守卫，照抄：
///   · `x5Play://` 开头 → 不是图片（那是强制播放）
///   · 含 `@rule=` / `@lazyRule=` → 不是图片（那是规则入口，要等规则求值）
///   · 含 `ignoreImg=true` → 主动声明不是图片
bool hikerIsImageUrl(String url) {
  final s = url.trim();
  if (s.isEmpty) return false;
  final lower = s.toLowerCase();
  if (lower.startsWith('x5play://')) return false;
  if (s.contains('@rule=') || s.contains('@lazyRule=')) return false;
  if (s.contains('ignoreImg=true')) return false;
  for (final ext in kHikerImageExtensions) {
    if (lower.contains(ext)) return true;
  }
  return false;
}

/// 多图/漫画链接（`pics://图1&&图2`）→ 图片列表；不是则 null。
///
/// 官方文档原文：
///   「即 pics:// 开头，后面为多张图片地址用 && 连接；
///     视界将会识别为多图模式（类似漫画），下拉会尝试执行下一集的动态解析」
/// 解析复用影视侧同一实现（也兼容 `mange://` 等同族写法）。
List<String>? hikerPicList(String url) => play_route.parseImageListUrl(url);

/// 正文链接（`novel://{title,content}`）→ (标题, 正文)；不是则 null。
({String title, String content})? hikerNovelContent(String url) =>
    play_route.parseNovelUrl(url);

/// 海阔的**播放地址 JSON** —— 官方的播放约定，长这样：
///   `{"urls":["https://hls…/index.m3u8","备用"],"names":["HLS"],
///     "headers":{"Referer":"…"},"parse":0}`
///
/// ⚠️ 以前只在**整条规则的返回值**里解析它（引擎侧），**列表条目**里的这坨 JSON
/// 会原样透到详情页 ⇒ 既不是 http 也不是任何已知协议 ⇒ 被判成"未知链接"，
/// 详情页上一排「提示」按钮点了没反应（用户 2026-10-16 的截图：
/// 选集 1/2/3 的地址就是 `{"urls":["https://hls.tpbbwcc.cn/…m3u8"]}`）。
///
/// 返回 (urls, headers)；不是播放 JSON 则 null。
({List<String> urls, Map<String, String> headers})? hikerPlayJson(String raw) {
  final s = raw.trim();
  if (!s.startsWith('{') || !s.contains('"urls"')) return null;
  try {
    final j = jsonDecode(s);
    if (j is! Map) return null;
    final urls = <String>[];
    final rawUrls = j['urls'];
    if (rawUrls is List) {
      for (final u in rawUrls) {
        final t = u.toString().trim();
        if (t.isNotEmpty) urls.add(t);
      }
    } else if (j['url'] != null) {
      final t = j['url'].toString().trim();
      if (t.isNotEmpty) urls.add(t);
    }
    if (urls.isEmpty) return null;
    final headers = <String, String>{};
    final h = j['headers'];
    if (h is Map) {
      h.forEach((k, v) => headers[k.toString()] = v.toString());
    }
    return (urls: urls, headers: headers);
  } catch (_) {
    return null;
  }
}

/// 按官方 `dealWithUrl()` 的**判定顺序**给链接分类。
///
/// 顺序不能乱 —— 官方就是按这个顺序短路返回的：
///   hiker:// → javascript: → x5:// → web:// → pics:// → 图片 → 直链 → …
/// 例如 `pics://https://a.com/1.jpg` 必须**先**命中 pics（它是多图），
/// 若先判图片后缀就会退化成"单张大图预览"。
HikerLinkKind hikerLinkKind(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return HikerLinkKind.unknown;
  final lower = s.toLowerCase();

  // ① 官方内部页面
  if (lower.startsWith('hiker://')) return HikerLinkKind.hikerPage;

  // ② 彩蛋模式（一段 JS，官方跳浏览器执行）
  if (lower.startsWith('javascript:')) return HikerLinkKind.js;

  // ③ X5 全屏 / 刷新式 X5
  if (lower.startsWith('x5://') || lower.startsWith('x5webview://')) {
    return HikerLinkKind.x5;
  }

  // ④ 强制网页（忽略二级解析规则）
  if (lower.startsWith('web://')) return HikerLinkKind.web;

  // ⑤ 多图模式（类似漫画）—— 必须排在"图片"之前
  if (hikerPicList(s) != null) return HikerLinkKind.pics;

  // ⑥ 正文（小说源约定，与 pics 同一层）
  final novel = hikerNovelContent(s);
  if (novel != null && novel.content.trim().isNotEmpty) {
    return HikerLinkKind.novel;
  }

  // ⑥' 播放地址 JSON —— 必须排在"图片"之前：里面那个 url 可能是 `…/1.jpg`，
  //     先判图片就会把一坨播放 JSON 当成单张大图。
  if (hikerPlayJson(s) != null) return HikerLinkKind.playJson;

  // ⑦ 提示 / 复制 / 下载 / 选择框这类"无页面"协议
  if (lower.startsWith('toast://')) return HikerLinkKind.toast;
  if (lower.startsWith('copy://')) return HikerLinkKind.copyLink;
  if (lower.startsWith('confirm://') ||
      lower.startsWith('input://') ||
      lower.startsWith('select://')) {
    // 官方是弹原生对话框；本模块没有对应交互，按"提示原文"处理，至少不静默
    return HikerLinkKind.toast;
  }
  if (lower.startsWith('download://')) return HikerLinkKind.download;

  // ⑧ 强制播放 / 自动提取视频
  if (lower.startsWith('x5play://')) return HikerLinkKind.x5Play;
  if (lower.startsWith('video://')) return HikerLinkKind.videoSniff;

  // ⑨ 图片（官方 UrlDetector.isImage）
  if (hikerIsImageUrl(s)) return HikerLinkKind.image;

  // ⑩ 影视直链 → 原生播放器（全项目唯一事实来源）
  if (SniffFilter.isDirectMedia(s)) return HikerLinkKind.media;

  // ⑩' 音频直链（音乐源）：影视清单之外的 [kAudioExtensions] 补判 —— 与
  //     `parse_service._isDirectMedia` / `detail/view` 是**同一口径**
  //     （那两处也是这么补的，别在这里自创第三种写法）。
  final path = Uri.tryParse(s)?.path.toLowerCase() ?? '';
  for (final ext in play_route.kAudioExtensions) {
    if (path.endsWith(ext)) return HikerLinkKind.media;
  }

  // ⑪ 交给第三方软件
  if (lower.startsWith('magnet:') ||
      lower.startsWith('thunder') ||
      lower.startsWith('ftp:') ||
      lower.startsWith('ed2k:')) {
    return HikerLinkKind.external;
  }

  // ⑫ 安装包
  if (lower.startsWith('http') && lower.split('?').first.endsWith('.apk')) {
    return HikerLinkKind.apk;
  }

  // ⑬ 普通网页
  if (lower.startsWith('http') || lower.startsWith('file://')) {
    return HikerLinkKind.http;
  }

  return HikerLinkKind.unknown;
}

/// 去掉官方"外壳协议"得到真实地址；没有外壳则原样返回。
///
///   · `x5Play://http://a.com/1.mp4` → `http://a.com/1.mp4`（官方=强制播放它）
///   · `video://https://a.com/p.html` → `https://a.com/p.html`
///   · `x5://` / `x5WebView://` / `web://` → 里面的 http 地址
String hikerStripScheme(String url) {
  final s = url.trim();
  final lower = s.toLowerCase();
  for (final p in const [
    'x5play://',
    'x5webview://',
    'x5://',
    'web://',
    'video://',
    'download://',
  ]) {
    if (lower.startsWith(p)) return s.substring(p.length);
  }
  return s;
}
