/// 播放地址分流工具 —— 影视端（`detail/controller`）与小程序端
/// （`ant.player.open`）共用的**单一事实来源**。
///
/// 分流规则（2026-10-14 按用户明确要求）：
///   · **主流正版站**（爱奇艺 / 腾讯视频 / 芒果TV / 优酷 / 哔哩哔哩 …）
///     有防盗链与加密，直接嗅探拿到的地址多半播不了 ⇒ **必须先过解析接口**，
///     解析结果再交给嗅探兜底；
///   · **其余站点** ⇒ **直接嗅探**（在 WebView 里抓页面发出的媒体请求），
///     不走解析接口，省一次请求也避免被解歪。
///   · **非视频内容**（漫画 `pics://` / 小说 `novel://`）⇒ 见文件尾部两个
///     协议解析函数，按内容走简易阅读器。
library;

import 'dart:convert';

/// 「必须先解析」的站点域名清单。要加要删都只改这一处。
///
/// 匹配用**域名边界**（`host == 域名` 或 `host.endsWith('.域名')`），
/// 所以 `evil-iqiyi.com` 这类前缀伪造不会被误判。
const Set<String> kParseFirstHosts = {
  'iqiyi.com', // 爱奇艺
  'qq.com', // 腾讯视频（v.qq.com）
  'mgtv.com', // 芒果TV
  'hunantv.com', // 芒果备用域
  'youku.com', // 优酷
  'bilibili.com', // 哔哩哔哩
  'b23.tv', // B站短链
  'acfun.cn', // AcFun
  'le.com', // 乐视
  'sohu.com', // 搜狐视频
  'pptv.com', // PP视频
  '1905.com', // 电影网
  'migu.cn', // 咪咕视频
};

/// 可直接交给播放器的媒体后缀。
const List<String> _kMediaExts = [
  '.m3u8',
  '.mp4',
  '.flv',
  '.mkv',
  '.avi',
  '.mov',
  '.webm',
  '.ts',
  '.m4s',
  '.mpd',
  '.3gp',
  '.rmvb',
  '.wmv',
];

/// URL 看起来是不是**可直接播放**的媒体地址。
bool looksLikeDirectMedia(String url) {
  final raw = url.trim().toLowerCase();
  if (raw.isEmpty) return false;
  if (!raw.startsWith('http://') &&
      !raw.startsWith('https://') &&
      !raw.startsWith('rtmp://') &&
      !raw.startsWith('rtsp://')) {
    return false;
  }
  final path = Uri.tryParse(raw)?.path.toLowerCase() ?? raw;
  for (final ext in _kMediaExts) {
    if (path.endsWith(ext)) return true;
  }
  return false;
}

/// 该地址是否属于「必须先解析」的站点。
bool needParseFirst(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (host.isEmpty) return false;
  for (final h in kParseFirstHosts) {
    if (host == h || host.endsWith('.$h')) return true;
  }
  return false;
}

/// **图片列表协议**的 scheme 前缀（CatVod / TVBox 漫画源约定）。
///
/// 漫画源的 `playerContent` 不返回视频地址，而是把整章图片拼成
/// `pics://图1&&图2&&…`（或 `mange://…`）——播放器拿到它只会黑屏，
/// 所以要**按内容**识别出来走简易看图阅读器。
const List<String> _kImageListSchemes = [
  'pics',
  'mange',
  'pic',
  'image',
  'images',
];

/// 命中图片列表协议时返回图片 URL 列表（已去空、去首尾空格）；否则 null。
///
/// 多张图沿用 TVBox 约定用 `&&` 分隔。
List<String>? parseImageListUrl(String url) {
  final raw = url.trim();
  if (raw.isEmpty) return null;
  final lower = raw.toLowerCase();
  for (final s in _kImageListSchemes) {
    final prefix = '$s://';
    if (!lower.startsWith(prefix)) continue;
    final parts = raw
        .substring(prefix.length)
        .split('&&')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return parts.isEmpty ? null : parts;
  }
  return null;
}

/// **正文协议**的 scheme 前缀（CatVod / TVBox 小说源约定）。
///
/// 小说源的 `playerContent` 不返回视频地址，而是把整章正文塞在
/// `novel://{"title":"第x章","content":"正文…"}` 里 —— 播放器拿到只会黑屏，
/// 所以同样**按内容**识别出来走简易书籍阅读器。
const List<String> _kNovelSchemes = ['novel', 'book', 'txt'];

/// 命中正文协议时返回 (标题, 正文)；否则 null。
///
/// 正文以 JSON 承载（`{"title":…,"content":…}`，字段名兼容 name/text/body）；
/// 若 body 不是 JSON（少数源直接给纯文本），则整体当正文、标题留空。
({String title, String content})? parseNovelUrl(String url) {
  final raw = url.trim();
  if (raw.isEmpty) return null;
  final lower = raw.toLowerCase();
  for (final s in _kNovelSchemes) {
    final prefix = '$s://';
    if (!lower.startsWith(prefix)) continue;
    final body = raw.substring(prefix.length);
    if (body.isEmpty) return null;
    try {
      final j = jsonDecode(body);
      if (j is Map) {
        final title = (j['title'] ?? j['name'] ?? '').toString();
        final content =
            (j['content'] ?? j['text'] ?? j['body'] ?? '').toString();
        if (content.isNotEmpty) {
          return (title: title, content: content);
        }
      }
    } catch (_) {
      // 不是 JSON —— 落到下面当纯文本
    }
    return (title: '', content: body);
  }
  return null;
}
