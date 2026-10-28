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

import 'package:tvbox/services/player_prefs.dart';
import 'package:tvbox/services/play_route.dart';

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
  ///   3. **内置广告守卫** [looksLikeAdUrl]（用户白名单显式放行时跳过）；
  ///   4. 黑名单关键词（小写子串）命中 → 丢弃（切片广告多为 /ads/、/ad/ 等）；
  ///   5. 白名单非空时，必须命中白名单关键词之一。
  ///
  /// [mediaVerified]：地址**没有**影视后缀、但已经由服务端 `Content-Type`
  /// 确认是视频/音频/播放列表（见 `WebSniffService.looksLikeMediaByMime`）。
  /// 这类扩展名被藏起来的直链（`/play?id=…`、`/stream/abc`）很常见，
  /// 只靠后缀会全部漏掉；已验证过就跳过第 2 步，但**黑/白名单与广告守卫照旧生效**。
  static bool acceptSniffUrl(String raw, {bool mediaVerified = false}) {
    final url = raw.trim();
    if (url.isEmpty) return false;
    final lower = url.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return false;
    }
    // 只要影视直链（用户明确要求；后缀清单用户可自定义）
    if (!mediaVerified && !isDirectMedia(url)) return false;

    final prefs = PlayerPrefs.instance;

    // 先算白名单：用户显式放行的地址，允许绕过**内置**广告守卫
    //（但用户黑名单仍然优先，保持原有"黑名单最高"的语义）。
    var whitelisted = false;
    if (prefs.sniffWhitelist.isNotEmpty) {
      for (final kw in prefs.sniffWhitelist) {
        if (kw.isNotEmpty && lower.contains(kw)) {
          whitelisted = true;
          break;
        }
      }
    }

    // 内置广告守卫（用户 2026-10-27：「嗅探要不能嗅探到广告」）。
    // 用户黑名单是"关键词子串"，出厂为空 ⇒ 默认一个广告都挡不住；
    // 这里再叠一层**保守**的内置判定（整域名 / 整路径段），
    // 挡住最常见的贴片广告直链（/ads/、/preroll/、ad_720p.mp4、doubleclick…）。
    if (!whitelisted && looksLikeAdUrl(url)) return false;

    for (final kw in prefs.sniffBlacklist) {
      if (kw.isNotEmpty && lower.contains(kw)) return false;
    }
    if (prefs.sniffWhitelist.isNotEmpty && !whitelisted) return false;
    return true;
  }

  /// 候选地址**排序**：越靠前越可能是"能播完整片"的那个地址。
  ///
  /// 为什么需要（2026-10-28 深挖）：
  ///   · 默认后缀清单里含 `.ts` / `.m4s`，而 HLS 页面会请求**几十个切片**，
  ///     它们全都算"媒体直链"。原生侧若按原顺序取第一个命中，很可能拿到
  ///     只是某一小段 —— 用户看到播几秒就结束；
  ///   · 能播完整片的是**主播放列表**（`.m3u8`），命名常带
  ///     `index` / `master` / `playlist`，值得再提一档；
  ///   · 广告 m3u8 常排在正片前面（先拉贴片），但那条由 [looksLikeAdUrl]
  ///     负责挡，这里只管"整片 vs 切片"。
  ///
  /// 排序**稳定**：同分保持原顺序，不改变"先到先得"的既有语义。
  static List<String> rankCandidates(Iterable<String> urls) {
    final list = urls.toList();
    if (list.length < 2) return list;
    final indexed = <(int, int, String)>[
      for (var i = 0; i < list.length; i++) (candidateRank(list[i]), i, list[i]),
    ];
    indexed.sort((a, b) {
      final byRank = a.$1.compareTo(b.$1);
      return byRank != 0 ? byRank : a.$2.compareTo(b.$2);
    });
    return [for (final e in indexed) e.$3];
  }

  /// 单条候选的"整片可能性"打分，**越小越优先**（见 [rankCandidates]）。
  ///
  /// 公开出来是因为嗅探/解析两侧都需要"边扫边比、别急着交第一个命中"：
  /// `rankCandidates` 只能对一批一起排，而 `WebSniffService` 是逐页扫的，
  /// 需要一个单条打分来决定"要不要继续往下扫"。
  static int candidateRank(String url) {
    final ext = mediaExt(url);
    final lower = url.toLowerCase();
    if (ext == '.m3u8') {
      final looksMaster = lower.contains('master') ||
          lower.contains('index') ||
          lower.contains('playlist');
      return looksMaster ? 0 : 1;
    }
    if (ext == '.mpd') return 2;
    if (ext == '.mp4' || ext == '.flv' || ext == '.mkv' || ext == '.mov') {
      return 3;
    }
    // 切片：单独播只有几秒，排最后
    if (ext == '.ts' || ext == '.m4s') return 5;
    return 4;
  }

  /// 已知广告 / 追踪域名（**后缀**匹配：`x.doubleclick.net` 也算命中）。
  static const List<String> kBuiltinAdHosts = [
    'doubleclick.net',
    'googlesyndication.com',
    'googleadservices.com',
    'adservice.google.com',
    '2mdn.net',
    'adsystem.com',
    'adnxs.com',
    'taboola.com',
    'outbrain.com',
    'criteo.com',
    'criteo.net',
    'moatads.com',
    'amazon-adsystem.com',
    'scorecardresearch.com',
  ];

  /// 路径里**整段**等于这些词的视为广告（注意：是整段相等，不是子串，
  /// 否则 `load` / `road` / `download` 这类正常词会被误杀）。
  static const Set<String> kBuiltinAdSegments = {
    'ad',
    'ads',
    'adv',
    'advert',
    'adverts',
    'advertisement',
    'advertising',
    'preroll',
    'pre-roll',
    'midroll',
    'postroll',
    'vast',
    'vpaid',
    'banner',
    'banners',
    'guanggao',
    'gg',
    'advideo',
    'ad_video',
    'ad-video',
  };

  /// 内置广告直链判定（保守）：命中已知广告域名，或路径里出现广告整段 /
  /// `ad_720p.mp4` 这类广告视频命名。
  ///
  /// 只做**整域名后缀**与**整路径段**匹配 —— 宁可漏掉个别广告，也不能把
  /// 正常正片地址误杀（正片地址被误杀 = 用户看不到内容，比看到广告更糟）。
  static bool looksLikeAdUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    for (final d in kBuiltinAdHosts) {
      if (host == d || host.endsWith('.$d')) return true;
    }
    for (final seg in uri.pathSegments) {
      final s = seg.toLowerCase();
      if (kBuiltinAdSegments.contains(s)) return true;
      // 广告视频常见命名：ad_720p.mp4 / ad-1080p.m3u8
      if (s.startsWith('ad_') || s.startsWith('ad-')) return true;
    }
    return false;
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
