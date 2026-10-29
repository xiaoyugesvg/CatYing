// lib/services/xbpq/xbpq_play.dart
//
// XBPQ 详情 + 分集 + 取播放地址 —— 对齐 huoyi `provider_xbpq.go` 的
// `xbpqDetail` / `xbpqEpisodes` / `xbpqAlternateRoutes` / `xbpqResolveMedia`
// / `xbpqResolveOne` / `xbpqJumpValue` / `xbpqJumpCandidates` / `dedupeStrings`。
//
// 输出同样是 TVBox JSON 协议：详情返回 `{list:[{... vod_play_from, vod_play_url}]}`，
// 取址返回 `{url, parse, header}` —— 与现有 `SpiderService.getDetail/getPlayUrl`
// 的消费方式一致，P5 直接转过去即可。
//
// 与 Go 的取舍（有意为之，不是遗漏）：
//   · Go 的 `maccmsDetailCandidates` / `maccmsDetailTitle/Intro/Cover/Category`
//     那套「苹果CMS 通用猜详情」没有移植 —— XBPQ 规则的「简介/封面/类型」已经
//     是第一优先级，缺字段时用 h1/h2、og:image 兜底足够；再叠一层 MacCMS 猜测
//     只会让取值来源不可预期。
//   · Go 的 `prepareWebProviderMedia`（下载器/代理准备）不在本层：CatYing 的
//     `PlayPipeline` 已经负责这件事，P4 只负责「拿到地址并判定 parse 0/1」。

import 'package:html/dom.dart';

import 'package:tvbox/services/xbpq/xbpq_cut.dart';
import 'package:tvbox/services/xbpq/xbpq_maccms.dart';
import 'package:tvbox/services/xbpq/xbpq_rule.dart';
import 'package:tvbox/services/xbpq/xbpq_selector.dart';
import 'package:tvbox/services/xbpq/xbpq_source.dart';
import 'package:tvbox/services/xbpq/xbpq_url.dart';
import 'package:tvbox/services/xbpq/xbpq_util.dart';

/// 一集。
class XbpqEpisode {
  const XbpqEpisode({required this.title, required this.url});

  final String title;
  final String url;
}

/// 分集解析结果：集数最多的线路 + 全部线路（多线路切换用）。
class XbpqEpisodes {
  const XbpqEpisodes({
    required this.best,
    required this.routes,
    required this.routeTitles,
  });

  const XbpqEpisodes.empty()
      : best = const [],
        routes = const [],
        routeTitles = const [];

  final List<XbpqEpisode> best;
  final List<List<XbpqEpisode>> routes;
  final List<String> routeTitles;

  bool get isEmpty => routes.isEmpty;
}

class XbpqPlay {
  XbpqPlay({required this.source});

  final XbpqSource source;

  // ============================================================
  // 分集解析
  // ============================================================

  /// 播放串 → 线路 → 分集 → `标题$链接`。
  ///
  /// 规则写了「线路数组」时，按该 pattern 循环截取每个线路容器、用 `$$$`
  /// 拼成多组；未写时退回「播放数组」单次截取。
  static XbpqEpisodes episodes(String body, String pageUrl, XbpqRule rule) {
    final arrayPattern = rule.field(const ['播放数组']);
    if (arrayPattern.isEmpty) return const XbpqEpisodes.empty();

    var raw = '';
    final routeArray = rule.field(const ['线路数组']);
    if (routeArray.isNotEmpty) {
      final segments = XbpqCut.list(body, routeArray);
      if (segments.isNotEmpty) raw = segments.join(r'$$$');
    }
    if (raw.isEmpty) raw = XbpqCut.cutOnce(body, arrayPattern);
    if (raw.isEmpty) return const XbpqEpisodes.empty();

    raw = raw.replaceAll('\r\n', '#');
    if (raw.contains(r'\/')) raw = raw.replaceAll(r'\/', '/');

    var listSplit = rule.field(const ['播放列表']);
    if (listSplit.isEmpty || listSplit == '&&') listSplit = '#';

    final titlePattern = rule.field(const ['播放标题']);
    final linkPattern = rule.field(const ['播放链接']);
    final routePattern = rule.field(const ['线路标题']);

    var best = <XbpqEpisode>[];
    final routes = <List<XbpqEpisode>>[];
    final routeTitles = <String>[];

    List<XbpqEpisode> parseItems(String group, String separator) {
      final entries = <XbpqEpisode>[];
      for (var item in group.split(separator)) {
        item = item.trim();
        if (item.isEmpty) continue;

        var name = item;
        var address = '';
        final cut = item.indexOf(r'$');
        if (cut >= 0) {
          name = item.substring(0, cut);
          address = item.substring(cut + 1);
        }
        if (titlePattern.isNotEmpty) {
          final value = XbpqCut.cutOnce(item, titlePattern);
          if (value.isNotEmpty) name = value;
        }
        if (linkPattern.isNotEmpty) {
          final value = XbpqCut.cutOnce(item, linkPattern);
          if (value.isNotEmpty) address = value;
        }
        if (address.startsWith(r'$')) continue;

        address = XbpqMaccms.normalizePlaybackUrl(address.trim());
        name = XbpqSource.cleanText(name);
        if (name.isEmpty && address.contains('://')) {
          name = '第${entries.length + 1}集';
        }
        if (name.isEmpty || address.isEmpty) continue;
        entries.add(XbpqEpisode(title: name, url: address));
      }
      return entries;
    }

    for (final rawGroup in raw.split(r'$$$')) {
      final group = rawGroup.trim();
      if (group.isEmpty) continue;

      var entries = parseItems(group, listSplit);
      // 分隔符自适应（模板兜底安全网）：模板给的唯一分隔符可能与该站容器不符
      // ——典型是容器里 `<a>` 连排却按 `<li` 切，整段会塌成 1 集。判据用
      // 「只切出 ≤1 段、且这段里含 ≥2 个 href」：单集电影页只有 1 个 href，
      // 不会误触发。
      if (entries.length <= 1 && _countOf(group, 'href=') >= 2) {
        final alternate = parseItems(group, '<a');
        if (alternate.length > entries.length) entries = alternate;
      }
      if (entries.length > best.length) best = entries;
      if (entries.isNotEmpty) {
        routes.add(entries);
        routeTitles.add(_routeTitle(group, routePattern, routes.length));
      }
    }

    // 相对播放地址（如仅数字 ID）用链接补全；纯文字条目丢弃。
    List<XbpqEpisode> absolutize(List<XbpqEpisode> group) {
      final fixed = <XbpqEpisode>[];
      for (final entry in group) {
        var link = entry.url;
        if (!link.contains('://') && !link.startsWith('/')) continue;
        if (!link.startsWith('http')) link = XbpqUrl.absolute(pageUrl, link);
        if (link.isEmpty) continue;
        fixed.add(XbpqEpisode(title: entry.title, url: link));
      }
      return fixed;
    }

    final fixedRoutes = <List<XbpqEpisode>>[];
    final fixedTitles = <String>[];
    for (var i = 0; i < routes.length; i++) {
      final fixed = absolutize(routes[i]);
      if (fixed.isEmpty) continue;
      fixedRoutes.add(fixed);
      fixedTitles.add(routeTitles[i]);
    }
    return XbpqEpisodes(
      best: absolutize(best),
      routes: fixedRoutes,
      routeTitles: fixedTitles,
    );
  }

  /// 收集同一集在其它线路上的播放页地址，供播放时切换线路。
  /// 同序号即视为同一集；标题不一致的线路整条跳过，避免集数不同导致错位。
  static List<String> alternateRoutes(
    List<List<XbpqEpisode>> groups,
    int index,
    XbpqEpisode main,
    String mainLink,
    String pageUrl,
  ) {
    if (groups.length < 2) return const [];

    final out = <String>[];
    final seen = <String>{mainLink};
    for (final group in groups) {
      if (index >= group.length) continue;
      final entry = group[index];
      if (entry.title.isNotEmpty &&
          main.title.isNotEmpty &&
          entry.title != main.title) {
        continue;
      }
      final link = XbpqUrl.joinLink(pageUrl, entry.url);
      if (link.isEmpty || seen.contains(link)) continue;
      seen.add(link);
      out.add(link);
    }
    return out;
  }

  static int _countOf(String source, String needle) {
    if (needle.isEmpty) return 0;
    var count = 0;
    var index = source.indexOf(needle);
    while (index >= 0) {
      count++;
      index = source.indexOf(needle, index + needle.length);
    }
    return count;
  }

  /// Go 里「线路标题」是空实现（只留了个 if）。CatYing 需要 `vod_play_from`
  /// 给线路起名，所以这里真的用它对线路容器取值，取不到退回「线路N」。
  static String _routeTitle(String group, String pattern, int index) {
    if (pattern.isNotEmpty) {
      final title = XbpqSource.cleanText(XbpqCut.cutOnce(group, pattern));
      if (title.isNotEmpty) return title;
    }
    return '线路$index';
  }

  // ============================================================
  // 详情
  // ============================================================

  /// 详情页 → TVBox 详情 JSON。
  Future<Map<String, dynamic>> detail({
    required XbpqRule rule,
    required String base,
    required String sourceId,
  }) async {
    var pageUrl = XbpqUrl.linkFromId(sourceId);
    if (pageUrl.isEmpty) {
      final template = rule.field(const ['详情url', '详情页url']);
      pageUrl = XbpqUrl.render(template, base, {'id': sourceId});
    }
    if (pageUrl.isEmpty) throw const XbpqException('无法定位详情页地址');

    final body = await _fetch(pageUrl, '$base/', rule.userAgent);
    final document = XbpqSelector.parseDocument(body);
    final item = XbpqItem(text: body, doc: document);

    String pick(List<String> names) {
      for (final name in names) {
        final pattern = rule.field([name]);
        if (pattern.isEmpty) continue;
        final value = XbpqSource.itemField(item, pattern);
        if (value.isNotEmpty) return XbpqSource.cleanText(value);
      }
      return '';
    }

    // 详情标题优先用规则「影片名称」（「标题」是列表层语义，不借用）。
    var title = pick(const ['影片名称', 'name']);
    if (title.isEmpty) title = _firstHeading(document);

    final intro = pick(const ['简介']);
    var cover = '';
    final coverPattern = rule.field(const ['封面', '图片']);
    if (coverPattern.isNotEmpty) {
      cover = XbpqUrl.joinLink(
        pageUrl,
        XbpqSource.itemField(item, coverPattern),
      );
    }
    if (cover.isEmpty) cover = _ogImage(document, pageUrl);

    final parsed = episodes(body, pageUrl, rule);
    if (parsed.isEmpty) throw const XbpqException('规则未解析到分集');

    final playUrl = parsed.routes
        .map((group) => group
            .map((e) => '${e.title}\$${e.url}')
            .join('#'))
        .join(r'$$$');

    return {
      'list': [
        {
          'vod_id': sourceId,
          'vod_name': title,
          'vod_pic': cover,
          'vod_content': intro,
          'type_name': pick(const ['类型']),
          'vod_remarks': pick(const ['状态', '影片状态']),
          'vod_play_from': parsed.routeTitles.join(r'$$$'),
          'vod_play_url': playUrl,
        }
      ],
    };
  }

  /// h1 → h2 兜底（长度 2~60 才算标题）。
  static String _firstHeading(Document document) {
    for (final name in const ['h1', 'h2']) {
      final nodes = document.querySelectorAll(name);
      if (nodes.isEmpty) continue;
      final text = XbpqSource.cleanText(XbpqSelector.text(nodes.first));
      if (text.length >= 2 && text.length <= 60) return text;
      break;
    }
    final h1 = document.querySelectorAll('h1');
    if (h1.isNotEmpty) return XbpqSource.cleanText(XbpqSelector.text(h1.first));
    return '';
  }

  static String _ogImage(Document document, String pageUrl) {
    for (final selector in const [
      'meta[property="og:image"]',
      'meta[name="og:image"]',
    ]) {
      final node = document.querySelector(selector);
      final content = node?.attributes['content'] ?? '';
      if (content.isEmpty) continue;
      final link = XbpqUrl.joinLink(pageUrl, content);
      if (link.isNotEmpty) return link;
    }
    return '';
  }

  // ============================================================
  // 取播放地址
  // ============================================================

  /// 播放页 → `{url, parse, header}`。
  ///
  /// 顺序：地址本身是直链 → 规则「跳转播放链接」（含二级页再取一次）→
  /// 播放页 player_data / iframe base64 → 都不是就把原页面交回去，
  /// 由调用方按网页播放兜底。
  Future<Map<String, dynamic>> playUrl({
    required XbpqRule rule,
    required String base,
    required String pageUrl,
    String referer = '',
  }) async {
    final page = pageUrl.trim();
    final ref = referer.trim().isEmpty ? '$base/' : referer.trim();
    if (page.isEmpty) throw const XbpqException('播放地址为空');

    if (_looksLikeMedia(page)) return _direct(page, ref);

    final body = await _fetch(page, ref, rule.userAgent);

    final jump = rule.field(const ['跳转播放链接']);
    if (jump.isNotEmpty) {
      for (var candidate in jumpCandidates(body, jump)) {
        candidate = XbpqMaccms.normalizePlaybackUrl(
          XbpqUrl.joinLink(page, candidate),
        );
        if (_looksLikeMedia(candidate)) return _direct(candidate, page);
        if (!candidate.startsWith('http')) continue;

        // 跳转到二级播放页：再取一次。
        try {
          final second = await _fetch(candidate, page, rule.userAgent);
          var inner = jumpValue(second, jump);
          if (inner.isEmpty) continue;
          inner = XbpqMaccms.normalizePlaybackUrl(inner);
          if (_looksLikeMedia(inner)) return _direct(inner, candidate);
        } on XbpqException {
          continue;
        }
      }
    }

    var media = XbpqMaccms.playerUrl(body);
    if (media.isNotEmpty) {
      media = XbpqMaccms.normalizePlaybackUrl(media);
      if (_looksLikeMedia(media)) return _direct(media, page);
    }

    // 规则与通用兜底都没拿到直链：把原页面交回去（网页播放兜底）。
    return {'url': page, 'parse': 1, 'header': {'Referer': ref}};
  }

  /// 取 `跳转播放链接` 的第一个值（截断换行后 trim）。
  static String jumpValue(String body, String jump) {
    var value = XbpqCut.cutOnce(body, jump);
    if (value.isEmpty) return '';
    final index = value.indexOf(RegExp(r'[\r\n]'));
    if (index >= 0) value = value.substring(0, index);
    return value.trim();
  }

  /// 收集 `跳转播放链接` 的所有候选（去重、保序）。
  static List<String> jumpCandidates(String body, String jump) {
    final out = <String>[];
    final value = jumpValue(body, jump);
    if (value.isNotEmpty) out.add(value);
    out.addAll(XbpqCut.scanSegments(body, jump));

    final seen = <String>{};
    final deduped = <String>[];
    for (final item in out) {
      if (item.isEmpty || seen.contains(item)) continue;
      seen.add(item);
      deduped.add(item);
    }
    return deduped;
  }

  /// P4 内部用于决定「要不要再抓一层」；本处只做后缀粗判。
  static final RegExp _mediaSuffix =
      RegExp(r'\.(m3u8|mp4|flv|mkv|mov|m4s|mpd|ts)(\?|#|$)',
          caseSensitive: false);

  static bool _looksLikeMedia(String url) => _mediaSuffix.hasMatch(url);

  static Map<String, dynamic> _direct(String url, String referer) => {
        'url': url,
        'parse': 0,
        'header': {'Referer': referer},
      };

  Future<String> _fetch(String url, String referer, String agent) async {
    try {
      return await source.fetcher(url, referer, agent);
    } on XbpqException {
      rethrow;
    } catch (e) {
      throw XbpqException('$e');
    }
  }
}
