/// 主流长视频平台的域名识别。
///
/// 用户（本会话）：「线路要能正好对接爱奇艺、优酷、腾讯、芒果、哔哩哔哩、
/// PPTV 这些域名的链接，采用解析线路。」
///
/// 为什么不能只靠后缀判断：这些平台的正片页大多是**网页**，而 B 站等甚至
/// 不带 `.html`（如 `bilibili.com/video/BVxxx/`），单看「有没有 .html / .m3u8」
/// 会漏判成直链、直接丢给播放器白卡。这里按域名显式认，命中就强制走解析线路。
class VideoPlatform {
  /// 中文名（仅用于日志/提示）
  final String name;

  /// 域名后缀列表（匹配 host 本身或其子域）
  final List<String> hosts;

  const VideoPlatform(this.name, this.hosts);
}

const List<VideoPlatform> kVideoPlatforms = [
  VideoPlatform('爱奇艺', ['iqiyi.com', 'iq.com']),
  VideoPlatform('优酷', ['youku.com', 'tudou.com']),
  VideoPlatform('腾讯视频', ['v.qq.com']),
  VideoPlatform('芒果TV', ['mgtv.com']),
  VideoPlatform('哔哩哔哩', ['bilibili.com', 'b23.tv']),
  VideoPlatform('PPTV', ['pptv.com']),
];

/// 命中返回对应平台，否则 null。只认 http(s)。
VideoPlatform? matchVideoPlatform(String url) {
  final u = url.trim();
  if (u.isEmpty) return null;
  Uri uri;
  try {
    uri = Uri.parse(u);
  } catch (_) {
    return null;
  }
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return null;
  for (final p in kVideoPlatforms) {
    for (final h in p.hosts) {
      if (host == h || host.endsWith('.$h')) return p;
    }
  }
  return null;
}

/// 是否属于上述长视频平台的网页链接。
bool isVideoPlatformUrl(String url) => matchVideoPlatform(url) != null;

/// 该 URL 是不是「已经套过解析接口」的地址（`?url=` 的值本身是 http(s)）。
///
/// 用于避免把已经 `jx.xx/?url=...` 的地址再套一层。
bool looksLikeParseUrl(String url) {
  try {
    final uri = Uri.parse(url.trim());
    final q = uri.queryParameters['url'];
    if (q != null && (q.startsWith('http://') || q.startsWith('https://'))) {
      return true;
    }
  } catch (_) {}
  return false;
}
