/// 播放地址分流工具 —— 影视端（`detail/controller`）与小程序端
/// （`ant.player.open`）共用的**单一事实来源**。
///
/// 分流规则：
///   · **可直接播放的媒体直链**（后缀在 [kDefaultMediaExtensions] /
///     [kAudioExtensions] 内）⇒ 交给原生播放器；
///   · **其它地址**（网页页面、未知协议）⇒ 视为网页地址：影视模块直接拒绝
///     播放（不内嵌 WebView），RSS / 小程序 / 海阔等模块可自行打开网页；
///   · **非视频内容**（漫画 `pics://` / 小说 `novel://`）⇒ 见文件尾部两个
///     协议解析函数，按内容走简易阅读器。
library;

import 'dart:convert';

/// **默认**可直接交给播放器的媒体后缀。
///
/// 固定的出厂清单，各链路判定"是否直链"都以它为准。
const List<String> kDefaultMediaExtensions = [
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

/// **音频直链**后缀：影视后缀清单（[kDefaultMediaExtensions]，用户可自定义）
/// 之外的补充白名单。
///
/// 源偶尔给出纯音频地址（音乐源直链），这几类也交给原生播放器。
/// 集中一处，避免 detail/view 等处各写一份、顺序还不一致
/// （2026-10-15 核对一致性时发现）。
const List<String> kAudioExtensions = [
  '.mp3',
  '.aac',
  '.wav',
  '.ogg',
  '.flac',
  '.m4a',
];

/// 取 URL 的媒体后缀（小写、带点，如 `.m3u8`）；**不在清单内则返回空串**。
///
/// [exts] 不传则用 [kDefaultMediaExtensions]；要看纯音频可传 [kAudioExtensions]。
/// 只看 path 的最后一段（忽略查询串/锚点），与 [looksLikeDirectMedia] 同一口径。
String mediaExtOf(String url, {List<String>? exts}) {
  final list = exts ?? kDefaultMediaExtensions;
  final path = Uri.tryParse(url.trim())?.path.toLowerCase() ?? '';
  final slash = path.lastIndexOf('/');
  final name = slash >= 0 ? path.substring(slash + 1) : path;
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return '';
  final ext = name.substring(dot);
  return list.contains(ext) ? ext : '';
}

/// URL 看起来是不是**可直接播放**的媒体地址。
///
/// [exts] 不传则用 [kDefaultMediaExtensions]（保持纯函数、方便单测）；
/// 业务侧可传 [kAudioExtensions] 之类更宽的清单。
bool looksLikeDirectMedia(String url, {List<String>? exts}) {
  final list = exts ?? kDefaultMediaExtensions;
  final raw = url.trim().toLowerCase();
  if (raw.isEmpty) return false;
  if (!raw.startsWith('http://') &&
      !raw.startsWith('https://') &&
      !raw.startsWith('rtmp://') &&
      !raw.startsWith('rtsp://')) {
    return false;
  }
  final path = Uri.tryParse(raw)?.path.toLowerCase() ?? raw;
  for (final ext in list) {
    if (path.endsWith(ext)) return true;
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
