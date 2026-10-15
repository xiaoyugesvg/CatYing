/// 嗅探 / 解析 规则过滤 —— 单一事实来源。
///
/// 用户 2026-10-15：
///   「嗅探只要 m3u8、MP4、flv 等等影视链接」
///   「增加不嗅探哪些链接、指定嗅探哪些链接，有助去掉广告」
///   「解析也是解析哪些类型的网页的」
///
/// 规则全部存在 [PlayerPrefs]（播放设置 → 嗅探设置里编辑），本文件只负责
/// 判定，不持有状态：
///   · [acceptSniffUrl] —— 嗅探到的链接要不要：**必须是影视直链后缀**，
///     再过黑名单（子串命中丢弃）/ 白名单（非空时只放行命中的）；
///   · [shouldParse] —— 这个网页地址要不要先过解析接口：内置主流站点清单
///     （[kParseFirstHosts]）+ 用户追加域名，减去用户屏蔽域名。
library;

import 'player_prefs.dart';
import 'play_route.dart';

class SniffFilter {
  SniffFilter._();

  /// **当前生效的影视直链后缀清单**。
  ///
  /// 用户在「嗅探设置 → 影视直链后缀」里可增删（例如加 `.m4a`）；存空则用
  /// [kDefaultMediaExtensions]（= 出厂清单，避免用户误清空后所有直链都不认）。
  static List<String> get mediaExtensions {
    final custom = PlayerPrefs.instance.mediaExtensions;
    return custom.isEmpty ? kDefaultMediaExtensions : custom;
  }

  /// 该地址是否是可交给播放器的**影视直链**（按当前生效清单判定）。
  ///
  /// 全项目应统一用这个入口，不要再各自调 `looksLikeDirectMedia`（那样会
  /// 忽略用户自定义的后缀清单）。
  static bool isDirectMedia(String url) =>
      looksLikeDirectMedia(url, exts: mediaExtensions);

  /// 该地址的媒体后缀（按当前生效清单；非清单内返回空串）。
  static String mediaExt(String url) =>
      mediaExtOf(url, exts: mediaExtensions);

  /// 当前清单拼成的**正则候选串**（如 `m3u8|mp4|flv`），供嗅探 JS 正则与
  /// 解析侧的媒体直链正则共用 —— 全项目只有这一处生成，不允许各处写死。
  ///
  /// ⚠️ 只保留字母数字：这段串会被拼进正则字面量，用户若填了 `+` `*` `(` 之类
  /// 的元字符会把正则拼坏（JS 侧尤其致命），2026-10-15 加固。
  static String get mediaExtAlternation {
    final exts = mediaExtensions
        .map((e) => e.replaceFirst('.', '').trim().toLowerCase())
        .map((e) => e.replaceAll(RegExp(r'[^a-z0-9]'), ''))
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    return exts.isEmpty ? 'm3u8|mp4|flv' : exts.join('|');
  }

  /// 嗅探结果是否接受。
  ///
  /// 判定顺序（任一不过即丢弃）：
  ///   1. 必须 http(s)（嗅探发生在 WebView 里，rtmp/rtsp 走不到这条链路）；
  ///   2. 必须带**当前生效清单**里的影视后缀（用户可自定义，见 [mediaExtensions]）；
  ///   3. 黑名单关键词（小写子串）命中 → 丢弃（切片广告多为 /ads/、/ad/ 等）；
  ///   4. 白名单非空时，必须命中白名单关键词之一。
  static bool acceptSniffUrl(String raw) {
    final url = raw.trim();
    if (url.isEmpty) return false;
    final lower = url.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return false;
    }
    // 只要影视直链（用户明确要求；后缀清单用户可自定义）
    if (!isDirectMedia(url)) return false;

    final prefs = PlayerPrefs.instance;
    for (final kw in prefs.sniffBlacklist) {
      if (kw.isNotEmpty && lower.contains(kw)) return false;
    }
    if (prefs.sniffWhitelist.isNotEmpty) {
      var ok = false;
      for (final kw in prefs.sniffWhitelist) {
        if (kw.isNotEmpty && lower.contains(kw)) {
          ok = true;
          break;
        }
      }
      if (!ok) return false;
    }
    return true;
  }

  /// 该网页地址是否要先过解析接口。
  ///
  /// 域名边界匹配（`a.com` 命中 `a.com` / `x.a.com`，不命中 `evil-a.com`）：
  ///   · 命中**屏蔽名单** → 直接 false（优先级最高，可用来剔除内置站点）；
  ///   · 命中内置清单 [kParseFirstHosts] 或用户**追加名单** → true；
  ///   · 其余 → false（直接嗅探/播放，省一次解析请求）。
  static bool shouldParse(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return false;

    final prefs = PlayerPrefs.instance;
    if (_hostMatches(host, prefs.parseHostsBlock)) return false;

    if (_hostMatches(host, kParseFirstHosts)) return true;
    return _hostMatches(host, prefs.parseHostsExtra);
  }

  /// host 是否被域名清单命中（边界匹配，忽略前导 `.`）。
  static bool _hostMatches(String host, Iterable<String> domains) {
    for (final raw in domains) {
      final d = raw.trim().toLowerCase().replaceFirst(RegExp(r'^\*+\.?'), '');
      if (d.isEmpty) continue;
      if (host == d || host.endsWith('.$d')) return true;
    }
    return false;
  }
}
